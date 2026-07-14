import Accelerate
import AVFoundation
import Foundation
import os
import SwiftUI

/// Call-path diagnostics: `log show --predicate 'subsystem == "her.call"'`.
let callLog = Logger(subsystem: "her.call", category: "realtime")

/// URLSession does not guarantee that a WebSocket is open immediately after
/// `resume()`. Route all protocol traffic through the delegate's didOpen
/// callback so a slow handshake cannot race `session.start` / `receive()`.
private final class RealtimeSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    typealias OpenHandler = @Sendable (URLSessionWebSocketTask) -> Void
    typealias CloseHandler = @Sendable (URLSessionWebSocketTask, URLSessionWebSocketTask.CloseCode) -> Void
    typealias FailureHandler = @Sendable (URLSessionWebSocketTask, Error) -> Void

    private let onOpen: OpenHandler
    private let onClose: CloseHandler
    private let onFailure: FailureHandler

    init(onOpen: @escaping OpenHandler, onClose: @escaping CloseHandler, onFailure: @escaping FailureHandler) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onFailure = onFailure
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen(webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose(webSocketTask, closeCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let webSocketTask = task as? URLSessionWebSocketTask else { return }
        onFailure(webSocketTask, error)
    }
}

/// 打电话: one realtime voice call over the agentRealtime WebSocket
/// (wss://agentrealtime.oyii.ai/v1/realtime).
///
/// Protocol (see the service's AsyncAPI doc): JSON text frames are control
/// events, binary frames are raw PCM16 audio. The mic streams up
/// continuously at 16 kHz — the server's VAD decides turns and barge-in —
/// and assistant audio streams back at the sample rate announced by
/// `output_audio.start` (typically 24 kHz).
@MainActor
final class RealtimeCallController: ObservableObject {
    static let serviceURL = URL(string: "wss://agentrealtime.oyii.ai/v1/realtime")!

    enum CallState: Equatable {
        case idle
        case connecting
        case active
        case ended(reason: String?)
    }

    struct TranscriptLine: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
    }

    @Published private(set) var state: CallState = .idle
    @Published private(set) var transcript: [TranscriptLine] = []
    /// True while assistant audio is streaming — drives the "她在说话" UI.
    @Published private(set) var assistantSpeaking = false
    @Published var isMuted = false {
        didSet { tapShared?.muted = isMuted }
    }
    @Published private(set) var startedAt: Date?

    /// State the audio-thread tap reads. The tap must NEVER touch this
    /// @MainActor object — accessing an isolated property from the render
    /// thread trips the runtime isolation assert (SIGTRAP). Main writes,
    /// audio thread reads; Bool/reference reads are tear-free.
    /// Internal (not private) so tests can drive the tap block off-main.
    final class TapShared: @unchecked Sendable {
        var muted = false
        var socket: URLSessionWebSocketTask?
        var framesSent = 0
        var sendErrorsLogged = 0
        /// Loudest absolute sample seen so far — the mic watchdog reads this
        /// to distinguish "quiet room" from "all-zero broken capture".
        var peakAmplitude: Int16 = 0
        /// Half-duplex anti-echo (no VP on this machine): while assistant
        /// audio plays — plus a short tail — mic chunks are dropped. The
        /// deadline follows LOCAL scheduled playback, not output_audio.done
        /// (that event only means the server finished sending bytes).
        var assistantPlaying = false
        var scheduledPlaybackEnd: TimeInterval = 0
        var gateTailDeadline: TimeInterval = 0
        var voiceprintGate: CallVoiceprintGate?
        static let playbackTail: TimeInterval = 0.75

        func schedulePlayback(duration: TimeInterval, now: TimeInterval) {
            scheduledPlaybackEnd = max(scheduledPlaybackEnd, now) + max(0, duration)
            gateTailDeadline = scheduledPlaybackEnd + Self.playbackTail
        }

        func stopPlayback(now: TimeInterval, tail: TimeInterval) {
            scheduledPlaybackEnd = now
            gateTailDeadline = now + tail
            assistantPlaying = false
        }

        func shouldDropMicrophone(at now: TimeInterval) -> Bool {
            assistantPlaying || now < gateTailDeadline
        }
    }

    private var tapShared: TapShared?
    private var voiceprintEmbedding: [Float]?
    private var playbackChunks = 0
    private var micWatchdog: Task<Void, Never>?
    /// 嘟…嘟… while the session is being established.
    private var ringbackPlayer: AVAudioPlayer?
    /// 反向声波: software AEC used when system voice processing is broken —
    /// the engine's real output is the reference subtracted from the mic.
    private let echoCanceller = CallEchoCanceller()
    /// Once VP proved dead on this machine, every later call — across
    /// launches — skips it directly instead of burning the watchdog delay.
    private var voiceProcessingBroken = UserDefaults.standard.bool(forKey: "call.voiceProcessingBroken") {
        didSet { UserDefaults.standard.set(voiceProcessingBroken, forKey: "call.voiceProcessingBroken") }
    }
    /// Fallback engine-start retries within one call: the discarded VP
    /// engine's VoiceIO unit can hold the audio device for a moment, failing
    /// the fresh engine with -10875 until it's released.
    private var engineStartRetries = 0

    private var webSocket: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?
    private var webSocketDelegate: RealtimeSocketDelegate?
    private var receiveTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var socketCloseGraceTask: Task<Void, Never>?
    private var pendingSessionStartPayload: [String: Any]?
    /// Rebuilt from scratch on the VP fallback: an engine whose voice
    /// processing was toggled keeps a dirty graph and fails to restart
    /// (kAudioUnitErr -10875).
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?
    /// Transcript lines still being streamed into (replaced per partial).
    private var openUserLineID: UUID?
    private var openAssistantLineID: UUID?

    var isInCall: Bool { state == .connecting || state == .active }

    var duration: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    func configureVoiceprint(_ embedding: [Float]?) {
        voiceprintEmbedding = embedding?.isEmpty == false ? embedding : nil
    }

    // MARK: - Lifecycle

    /// Dials: connects the socket, opens the session, and starts streaming
    /// the microphone.
    func start(apiKey: String, modelProfile: String, instructions: String, voice: String) {
        guard !isInCall else { return }
        transcript = []
        openUserLineID = nil
        openAssistantLineID = nil
        assistantSpeaking = false
        isMuted = false
        engineStartRetries = 0
        state = .connecting

        var components = URLComponents(url: Self.serviceURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        pendingSessionStartPayload = [
            "agent_id": "omnia_default",
            "mode": "realtime",
            "model_profile": modelProfile.isEmpty ? "realtime_doubao" : modelProfile,
            "audio": [
                "input_format": "pcm16",
                "output_format": "pcm16",
                "sample_rate": 16_000,
                "channels": 1,
                "frame_duration_ms": 20
            ],
            "instructions": instructions,
            "voice": voice.isEmpty ? nil : voice,
            "client": ["type": "macos", "version": "0.1.0"]
        ]
        let delegate = RealtimeSocketDelegate(
            onOpen: { [weak self] task in
                Task { @MainActor in self?.socketDidOpen(task) }
            },
            onClose: { [weak self] task, code in
                Task { @MainActor in self?.socketDidClose(task, code: code) }
            },
            onFailure: { [weak self] task, error in
                Task { @MainActor in self?.socketDidFail(task, error: error) }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: components.url!)
        webSocketDelegate = delegate
        webSocketSession = session
        webSocket = task
        task.resume()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            self.hangUp(reason: "连接通话服务超时，请检查网络后重试。")
        }
        startRingback()
    }

    private func socketDidOpen(_ task: URLSessionWebSocketTask) {
        guard task === webSocket, state == .connecting, let payload = pendingSessionStartPayload else { return }
        callLog.notice("websocket opened")
        pendingSessionStartPayload = nil
        // Start receiving before session.start. The server can reject a
        // session immediately (for example insufficient credits) and close
        // right after the error frame; sending first loses that real reason.
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
        sendEvent(type: "session.start", payload: payload)
    }

    private func socketDidClose(_ task: URLSessionWebSocketTask, code: URLSessionWebSocketTask.CloseCode) {
        guard task === webSocket, isInCall else { return }
        callLog.error("websocket closed code=\(code.rawValue, privacy: .public)")
        // Give receiveLoop a moment to consume a final structured error frame.
        // If it does, hangUp records that useful message and this task becomes
        // a no-op because the call is already ended.
        socketCloseGraceTask?.cancel()
        socketCloseGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, task === self.webSocket, self.isInCall else { return }
            self.hangUp(reason: "通话服务关闭了连接（代码 \(code.rawValue)），请重试。")
        }
    }

    private func socketDidFail(_ task: URLSessionWebSocketTask, error: Error) {
        guard task === webSocket, isInCall else { return }
        callLog.error("websocket failed: \(error.localizedDescription, privacy: .public)")
        hangUp(reason: Self.friendlyConnectionError(error))
    }

    nonisolated static func friendlyConnectionError(_ error: Error) -> String {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return "连接通话服务超时，请重试。"
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            return "当前网络不可用，请检查网络连接。"
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return "网络连接中断，请重试。"
        default:
            if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
                return "尚未连接到通话服务，请重试。"
            }
            return "连接断开：\(nsError.localizedDescription)"
        }
    }

    /// Injects a one-line fact into the session's working memory
    /// (context.update is non-interrupting; applies from the next reply).
    func sendContextFact(_ fact: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isInCall else { return }
        sendEvent(type: "context.update", payload: ["fact": trimmed])
        callLog.notice("context fact sent (\(trimmed.count, privacy: .public) chars)")
    }

    func hangUp(reason: String? = nil, replacingGenericEndReason: Bool = false) {
        guard state != .idle else { return }
        if case .ended = state {
            // A transport failure and the server's final structured error can
            // arrive on separate URLSession callbacks.  Preserve the later,
            // actionable server reason instead of leaving the user with a
            // generic "socket is not connected" message.
            if replacingGenericEndReason {
                state = .ended(reason: reason)
            }
            return
        }
        state = .ended(reason: reason)
        stopRingback()
        stopAudioEngine()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        socketCloseGraceTask?.cancel()
        socketCloseGraceTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pendingSessionStartPayload = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil
        webSocketDelegate = nil
        assistantSpeaking = false
    }

    func reset() {
        hangUp()
        state = .idle
        startedAt = nil
    }

    // MARK: - Ringback (嘟…嘟…)

    private func startRingback() {
        guard let player = try? AVAudioPlayer(data: Self.ringbackWAV) else { return }
        player.numberOfLoops = -1
        player.volume = 0.35
        player.play()
        ringbackPlayer = player
    }

    private func stopRingback() {
        ringbackPlayer?.stop()
        ringbackPlayer = nil
    }

    /// Standard Chinese ringback cadence: 450 Hz, 1s on / 4s off — rendered
    /// once into a WAV the looping player can own.
    nonisolated private static let ringbackWAV: Data = {
        let sampleRate = 16_000
        let toneSeconds = 1.0
        let silenceSeconds = 4.0
        let toneFrames = Int(Double(sampleRate) * toneSeconds)
        let totalFrames = Int(Double(sampleRate) * (toneSeconds + silenceSeconds))
        var samples = [Int16](repeating: 0, count: totalFrames)
        let fadeFrames = 400
        for frame in 0..<toneFrames {
            let envelope: Double
            if frame < fadeFrames {
                envelope = Double(frame) / Double(fadeFrames)
            } else if frame > toneFrames - fadeFrames {
                envelope = Double(toneFrames - frame) / Double(fadeFrames)
            } else {
                envelope = 1
            }
            let value = sin(2 * .pi * 450 * Double(frame) / Double(sampleRate)) * envelope * 0.5
            samples[frame] = Int16(value * Double(Int16.max))
        }
        var data = Data()
        let byteCount = totalFrames * 2
        func appendLE32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendLE16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)
        appendLE16(1)
        appendLE16(1)
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate * 2))
        appendLE16(2)
        appendLE16(16)
        data.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }()

    // MARK: - Receive loop

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleEvent(text)
                case .data(let data):
                    playAudioChunk(data)
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled, isInCall {
                    hangUp(reason: Self.friendlyConnectionError(error))
                }
                return
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        let payload = object["payload"] as? [String: Any] ?? [:]

        callLog.notice("event \(type, privacy: .public)")
        switch type {
        case "session.created":
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            stopRingback()
            state = .active
            startedAt = Date()
            // One continuous audio segment for the whole call; the server's
            // VAD segments turns by itself.
            sendEvent(type: "input_audio.start", payload: nil)
            startAudioEngine(voiceProcessing: !voiceProcessingBroken)

        case "asr.partial", "asr.final":
            let text = payload["text"] as? String ?? ""
            updateLine(id: &openUserLineID, role: .user, text: text)
            if type == "asr.final" { openUserLineID = nil }

        case "assistant.text.delta":
            let delta = payload["text"] as? String ?? ""
            appendToLine(id: &openAssistantLineID, role: .assistant, delta: delta)

        case "output_audio.start":
            assistantSpeaking = true
            tapShared?.assistantPlaying = true
            let sampleRate = payload["sample_rate"] as? Double ?? 24_000
            preparePlayback(sampleRate: sampleRate)

        case "output_audio.done":
            assistantSpeaking = false
            openAssistantLineID = nil
            // This means the server finished SENDING audio, not that the
            // locally queued player buffers finished. playAudioChunk tracks
            // their real duration and keeps the microphone closed.
            if let shared = tapShared {
                shared.gateTailDeadline = max(
                    shared.gateTailDeadline,
                    Date().timeIntervalSince1970 + 0.5
                )
            }
            tapShared?.assistantPlaying = false

        case "output_audio.stop":
            // Barge-in: drop everything queued and go quiet immediately.
            assistantSpeaking = false
            openAssistantLineID = nil
            playerNode.stop()
            tapShared?.stopPlayback(now: Date().timeIntervalSince1970, tail: 0.3)

        case "error":
            let message = payload["message"] as? String ?? "未知错误"
            let code = payload["code"] as? String ?? "unknown"
            let recoverable = payload["recoverable"] as? Bool ?? false
            callLog.error("server error code=\(code, privacy: .public) recoverable=\(recoverable, privacy: .public) message=\(message, privacy: .public)")
            // A depleted account cannot recover inside this socket even if a
            // backend version labels the event recoverable.  End immediately
            // with the actionable reason before the server's close produces a
            // generic transport error.
            if code == "insufficient_credits" || !recoverable {
                hangUp(
                    reason: code == "insufficient_credits" ? "余额不足，请充值后再试。" : message,
                    replacingGenericEndReason: true
                )
            }

        default:
            break
        }
    }

    // MARK: - Transcript

    private func updateLine(id: inout UUID?, role: TranscriptLine.Role, text: String) {
        guard !text.isEmpty else { return }
        if let lineID = id, let index = transcript.firstIndex(where: { $0.id == lineID }) {
            transcript[index].text = text
        } else {
            let line = TranscriptLine(role: role, text: text)
            transcript.append(line)
            id = line.id
            trimTranscript()
        }
    }

    private func appendToLine(id: inout UUID?, role: TranscriptLine.Role, delta: String) {
        guard !delta.isEmpty else { return }
        if let lineID = id, let index = transcript.firstIndex(where: { $0.id == lineID }) {
            transcript[index].text += delta
        } else {
            let line = TranscriptLine(role: role, text: delta)
            transcript.append(line)
            id = line.id
            trimTranscript()
        }
    }

    private func trimTranscript() {
        // The call UI shows a rolling window; the full text goes back to the
        // conversation on hang-up from whatever survived here.
        if transcript.count > 200 {
            transcript.removeFirst(transcript.count - 200)
        }
    }

    // MARK: - Send helpers

    private func sendEvent(type: String, payload: [String: Any?]?) {
        var envelope: [String: Any] = ["type": type]
        if let payload {
            envelope["payload"] = payload.compactMapValues { $0 }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { _ in }
    }

    // MARK: - Audio: microphone up

    private func startAudioEngine(voiceProcessing: Bool = true) {
        let input = engine.inputNode
        // AEC: without voice processing the assistant hears herself through
        // the speakers. But macOS VP is known to silently deliver all-zero
        // audio in some configurations — the watchdog below detects that and
        // restarts the engine without it.
        do {
            try input.setVoiceProcessingEnabled(voiceProcessing)
            callLog.notice("voice processing set to \(voiceProcessing, privacy: .public)")
        } catch {
            callLog.error("voice processing toggle failed: \(error.localizedDescription, privacy: .public)")
        }

        let hwFormat = input.outputFormat(forBus: 0)
        callLog.notice("input hw format: \(hwFormat.sampleRate, privacy: .public) Hz, \(hwFormat.channelCount, privacy: .public) ch")
        guard hwFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: true
              ),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            hangUp(reason: "无法初始化麦克风")
            return
        }

        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        let shared = TapShared()
        shared.muted = isMuted
        shared.socket = webSocket
        if let voiceprintEmbedding {
            shared.voiceprintGate = CallVoiceprintGate(enrolled: voiceprintEmbedding)
            callLog.notice("voiceprint gate enabled")
        }
        tapShared = shared
        // Software AEC only when the system's voice processing is off; VP
        // does its own echo cancellation.
        let canceller: CallEchoCanceller? = voiceProcessing ? nil : echoCanceller
        canceller?.reset()
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: hwFormat,
            block: Self.makeMicTapBlock(
                shared: shared,
                converter: converter,
                targetFormat: targetFormat,
                sourceSampleRate: hwFormat.sampleRate,
                canceller: canceller
            )
        )
        if let canceller {
            let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            if let referenceFormat = AVAudioFormat(
                   commonFormat: .pcmFormatFloat32,
                   sampleRate: 16_000,
                   channels: 1,
                   interleaved: true
               ),
               let referenceConverter = AVAudioConverter(from: mixerFormat, to: referenceFormat) {
                engine.mainMixerNode.installTap(
                    onBus: 0,
                    bufferSize: 1_024,
                    format: mixerFormat,
                    block: Self.makeOutputTapBlock(
                        canceller: canceller,
                        converter: referenceConverter,
                        referenceFormat: referenceFormat,
                        sourceSampleRate: mixerFormat.sampleRate
                    )
                )
                callLog.notice("software AEC armed (mixer @\(mixerFormat.sampleRate, privacy: .public))")
            }
        }

        engine.prepare()
        do {
            try engine.start()
            callLog.notice("audio engine started (vp=\(voiceProcessing, privacy: .public))")
        } catch {
            callLog.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            if voiceProcessing {
                // VP couldn't even start — go straight to the fallback.
                restartAudioEngineWithoutVoiceProcessing()
            } else if engineStartRetries < 3 {
                // The just-discarded VoiceIO unit may still hold the device;
                // give CoreAudio a beat and try again on a fresh engine.
                engineStartRetries += 1
                callLog.notice("retrying engine start, attempt \(self.engineStartRetries, privacy: .public)")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self, self.isInCall else { return }
                    self.engine = AVAudioEngine()
                    self.playerNode = AVAudioPlayerNode()
                    self.startAudioEngine(voiceProcessing: false)
                }
            } else {
                hangUp(reason: "音频引擎启动失败：\(error.localizedDescription)")
            }
            return
        }

        // Mic watchdog: if voice processing produced literally nothing (no
        // frames, or frames that are all-zero silence — the classic macOS VP
        // failure), tear the engine down and run without it. Echo
        // cancellation lost beats a dead microphone.
        guard voiceProcessing else { return }
        micWatchdog?.cancel()
        micWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.isInCall else { return }
            let sent = self.tapShared?.framesSent ?? 0
            let peak = self.tapShared?.peakAmplitude ?? 0
            callLog.notice("mic watchdog: sent=\(sent, privacy: .public) peak=\(peak, privacy: .public)")
            // Peak is the dead-capture signal; framesSent can legitimately
            // be 0 while the half-duplex gate holds during her greeting.
            if peak == 0 {
                callLog.notice("mic watchdog: capture is dead with VP — restarting without it")
                self.restartAudioEngineWithoutVoiceProcessing()
            }
        }
    }

    /// VP delivered silence — rebuild the audio path with it disabled, on a
    /// FRESH engine: reusing the toggled one fails to start (-10875).
    private func restartAudioEngineWithoutVoiceProcessing() {
        voiceProcessingBroken = true
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        // Release the VoiceIO unit deterministically BEFORE the fresh engine
        // initializes its IO — a lingering VP unit holds the device and
        // fails the new engine with -10875.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        playbackFormat = nil
        startAudioEngine(voiceProcessing: false)
    }

    /// Builds the mic tap callback in a nonisolated context. A closure formed
    /// inside a @MainActor method inherits main-actor isolation (AVFAudio's
    /// tap block isn't @Sendable, so it doesn't opt out), and the runtime
    /// isolation assert then SIGTRAPs the audio thread the moment the tap
    /// fires — even if the body never touches actor state.
    nonisolated static func makeMicTapBlock(
        shared: TapShared,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        sourceSampleRate: Double,
        canceller: CallEchoCanceller?
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            if shared.muted { return }
            let ratio = targetFormat.sampleRate / sourceSampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var pulled = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if pulled {
                    status.pointee = .noDataNow
                    return nil
                }
                pulled = true
                status.pointee = .haveData
                return buffer
            }
            if let conversionError {
                if shared.sendErrorsLogged < 3 {
                    shared.sendErrorsLogged += 1
                    callLog.error("mic convert failed: \(conversionError.localizedDescription, privacy: .public)")
                }
                return
            }
            guard converted.frameLength > 0,
                  let channel = converted.int16ChannelData else {
                if shared.sendErrorsLogged < 3 {
                    shared.sendErrorsLogged += 1
                    callLog.error("mic convert produced no frames (in \(buffer.frameLength, privacy: .public))")
                }
                return
            }
            let frames = Int(converted.frameLength)

            // 反向声波: subtract the predicted speaker echo before anything
            // else judges the chunk.
            var samples = [Float](repeating: 0, count: frames)
            vDSP_vflt16(channel[0], 1, &samples, 1, vDSP_Length(frames))
            var toUnit: Float = 1.0 / 32_768.0
            vDSP_vsmul(samples, 1, &toUnit, &samples, 1, vDSP_Length(frames))
            canceller?.process(&samples)

            var unitPeak: Float = 0
            vDSP_maxmgv(samples, 1, &unitPeak, vDSP_Length(frames))
            let chunkPeak = Int16(min(unitPeak * 32_767, 32_767))
            if chunkPeak > shared.peakAmplitude { shared.peakAmplitude = chunkPeak }

            // Hard half-duplex gate. A loud speaker echo can be louder than
            // deliberate barge-in speech, so amplitude thresholds cannot
            // reliably distinguish them and were the source of self-talk
            // loops. Re-open only after locally scheduled audio + room tail.
            let now = Date().timeIntervalSince1970
            if shared.shouldDropMicrophone(at: now) { return }

            // Back to little-endian PCM16 for the wire.
            var toPCM: Float = 32_767
            vDSP_vsmul(samples, 1, &toPCM, &samples, 1, vDSP_Length(frames))
            var low: Float = -32_768
            var high: Float = 32_767
            vDSP_vclip(samples, 1, &low, &high, &samples, 1, vDSP_Length(frames))
            var pcm = [Int16](repeating: 0, count: frames)
            vDSP_vfix16(samples, 1, &pcm, 1, vDSP_Length(frames))
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            let gated = shared.voiceprintGate?.accept(data)
            if let score = gated?.score {
                callLog.notice("voiceprint decision score=\(score, privacy: .public) accepted=\(!(gated?.rejected ?? true), privacy: .public)")
            }
            let outgoing = gated?.frames ?? [data]
            for frame in outgoing {
                shared.framesSent += 1
                if shared.framesSent == 1 || shared.framesSent % 100 == 0 {
                    callLog.notice("mic sent \(shared.framesSent, privacy: .public) chunks (last \(frame.count, privacy: .public)B)")
                }
                shared.socket?.send(.data(frame)) { error in
                    if let error, shared.sendErrorsLogged < 3 {
                        shared.sendErrorsLogged += 1
                        callLog.error("mic send failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Builds the OUTPUT tap (nonisolated for the same SIGTRAP reason as the
    /// mic tap): converts what is actually playing to 16 kHz mono float and
    /// feeds it to the canceller as the echo reference.
    nonisolated static func makeOutputTapBlock(
        canceller: CallEchoCanceller,
        converter: AVAudioConverter,
        referenceFormat: AVAudioFormat,
        sourceSampleRate: Double
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            let ratio = referenceFormat.sampleRate / sourceSampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: referenceFormat, frameCapacity: capacity) else { return }
            var pulled = false
            converter.convert(to: converted, error: nil) { _, status in
                if pulled {
                    status.pointee = .noDataNow
                    return nil
                }
                pulled = true
                status.pointee = .haveData
                return buffer
            }
            let frames = Int(converted.frameLength)
            guard frames > 0, let channel = converted.floatChannelData else { return }
            canceller.writeReference(UnsafeBufferPointer(start: channel[0], count: frames))
        }
    }

    // MARK: - Audio: assistant down

    private func preparePlayback(sampleRate: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        if playbackFormat?.sampleRate != sampleRate, let format {
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            playbackFormat = format
        } else if playbackFormat == nil {
            playbackFormat = format
        }
    }

    private func playAudioChunk(_ data: Data) {
        guard let format = playbackFormat ?? AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else { return }
        if playbackFormat == nil {
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            playbackFormat = format
        }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            let channel = buffer.floatChannelData![0]
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768
            }
        }
        tapShared?.schedulePlayback(
            duration: Double(frameCount) / format.sampleRate,
            now: Date().timeIntervalSince1970
        )
        playerNode.scheduleBuffer(buffer)
        playbackChunks += 1
        if playbackChunks == 1 || playbackChunks % 50 == 0 {
            callLog.notice("playback chunk \(self.playbackChunks, privacy: .public) (\(frameCount, privacy: .public) frames @\(format.sampleRate, privacy: .public))")
        }
        if !playerNode.isPlaying, engine.isRunning {
            playerNode.play()
            callLog.notice("player started")
        }
    }

    private func stopAudioEngine() {
        micWatchdog?.cancel()
        micWatchdog = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        tapShared?.socket = nil
        tapShared = nil
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        playbackFormat = nil
    }
}

/// Voice catalog of the agentRealtime service (`GET /v1/voices?model=…`),
/// fetched per realtime model so Settings can offer the right音色 list.
enum AgentRealtimeVoiceCatalog {
    struct Voice: Identifiable, Decodable, Equatable {
        var id: String
        var label: String
        var gender: String?
        var provider: String?
    }

    private struct Response: Decodable {
        var voices: [Voice]
    }

    /// The `model` query value for a session model profile.
    static func catalogModel(forProfile profile: String) -> String {
        profile == "realtime_qwen_omni" ? "qwen3-omni-flash-realtime" : "doubao-realtime"
    }

    static func fetch(apiKey: String, modelProfile: String) async throws -> [Voice] {
        var components = URLComponents(string: "https://agentrealtime.oyii.ai/v1/voices")!
        components.queryItems = [URLQueryItem(name: "model", value: catalogModel(forProfile: modelProfile))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).voices
    }
}
