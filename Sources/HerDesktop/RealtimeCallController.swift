import AVFoundation
import Foundation
import os
import SwiftUI

/// Call-path diagnostics: `log show --predicate 'subsystem == "her.call"'`.
let callLog = Logger(subsystem: "her.call", category: "realtime")

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
        /// audio plays — plus a short tail — mic chunks are dropped unless
        /// they're loud enough to be deliberate barge-in speech rather than
        /// speaker bleed.
        var assistantPlaying = false
        var gateTailDeadline: TimeInterval = 0
        static let bargeInThreshold: Int16 = 6_000
    }

    private var tapShared: TapShared?
    private var playbackChunks = 0
    private var micWatchdog: Task<Void, Never>?
    /// 嘟…嘟… while the session is being established.
    private var ringbackPlayer: AVAudioPlayer?
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
    private var receiveTask: Task<Void, Never>?
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
        let task = URLSession.shared.webSocketTask(with: components.url!)
        webSocket = task
        task.resume()

        sendEvent(type: "session.start", payload: [
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
        ])

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
        startRingback()
    }

    /// Injects a one-line fact into the session's working memory
    /// (context.update is non-interrupting; applies from the next reply).
    func sendContextFact(_ fact: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isInCall else { return }
        sendEvent(type: "context.update", payload: ["fact": trimmed])
        callLog.notice("context fact sent (\(trimmed.count, privacy: .public) chars)")
    }

    func hangUp(reason: String? = nil) {
        guard state != .idle else { return }
        stopRingback()
        stopAudioEngine()
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        assistantSpeaking = false
        if case .ended = state {} else {
            state = .ended(reason: reason)
        }
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
                    hangUp(reason: "连接断开：\(error.localizedDescription)")
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
            // Keep the mic gated briefly past the end of playback: the tail
            // of her voice is still in the room.
            tapShared?.gateTailDeadline = Date().timeIntervalSince1970 + 0.5
            tapShared?.assistantPlaying = false

        case "output_audio.stop":
            // Barge-in: drop everything queued and go quiet immediately.
            assistantSpeaking = false
            openAssistantLineID = nil
            playerNode.stop()
            tapShared?.gateTailDeadline = Date().timeIntervalSince1970 + 0.3
            tapShared?.assistantPlaying = false

        case "error":
            let message = payload["message"] as? String ?? "未知错误"
            let recoverable = payload["recoverable"] as? Bool ?? false
            if !recoverable {
                hangUp(reason: message)
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
        tapShared = shared
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: hwFormat,
            block: Self.makeMicTapBlock(
                shared: shared,
                converter: converter,
                targetFormat: targetFormat,
                sourceSampleRate: hwFormat.sampleRate
            )
        )

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
        sourceSampleRate: Double
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
            let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: channel[0], count: byteCount)
            // Chunk peak (sparse): feeds the dead-capture watchdog AND the
            // half-duplex gate below.
            var chunkPeak: Int16 = 0
            var index = 0
            let frames = Int(converted.frameLength)
            while index < frames {
                let amplitude = channel[0][index] == Int16.min ? Int16.max : abs(channel[0][index])
                if amplitude > chunkPeak { chunkPeak = amplitude }
                index += 16
            }
            if chunkPeak > shared.peakAmplitude { shared.peakAmplitude = chunkPeak }
            // Anti-echo without VP: while her voice plays (plus a short
            // tail), drop mic chunks unless they're loud enough to be the
            // user deliberately talking over her.
            let now = Date().timeIntervalSince1970
            if shared.assistantPlaying || now < shared.gateTailDeadline {
                if chunkPeak < TapShared.bargeInThreshold { return }
            }
            shared.framesSent += 1
            if shared.framesSent == 1 || shared.framesSent % 100 == 0 {
                callLog.notice("mic sent \(shared.framesSent, privacy: .public) chunks (last \(byteCount, privacy: .public)B)")
            }
            shared.socket?.send(.data(data)) { error in
                if let error, shared.sendErrorsLogged < 3 {
                    shared.sendErrorsLogged += 1
                    callLog.error("mic send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
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
