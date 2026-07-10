import AVFoundation
import Foundation
import SwiftUI

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
    @Published var isMuted = false
    @Published private(set) var startedAt: Date?

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
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
    func start(apiKey: String, instructions: String, voice: String) {
        guard !isInCall else { return }
        transcript = []
        openUserLineID = nil
        openAssistantLineID = nil
        assistantSpeaking = false
        isMuted = false
        state = .connecting

        var components = URLComponents(url: Self.serviceURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let task = URLSession.shared.webSocketTask(with: components.url!)
        webSocket = task
        task.resume()

        sendEvent(type: "session.start", payload: [
            "agent_id": "omnia_default",
            "mode": "realtime",
            "model_profile": "realtime_doubao",
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
    }

    func hangUp(reason: String? = nil) {
        guard state != .idle else { return }
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

        switch type {
        case "session.created":
            state = .active
            startedAt = Date()
            // One continuous audio segment for the whole call; the server's
            // VAD segments turns by itself.
            sendEvent(type: "input_audio.start", payload: nil)
            startAudioEngine()

        case "asr.partial", "asr.final":
            let text = payload["text"] as? String ?? ""
            updateLine(id: &openUserLineID, role: .user, text: text)
            if type == "asr.final" { openUserLineID = nil }

        case "assistant.text.delta":
            let delta = payload["text"] as? String ?? ""
            appendToLine(id: &openAssistantLineID, role: .assistant, delta: delta)

        case "output_audio.start":
            assistantSpeaking = true
            let sampleRate = payload["sample_rate"] as? Double ?? 24_000
            preparePlayback(sampleRate: sampleRate)

        case "output_audio.done":
            assistantSpeaking = false
            openAssistantLineID = nil

        case "output_audio.stop":
            // Barge-in: drop everything queued and go quiet immediately.
            assistantSpeaking = false
            openAssistantLineID = nil
            playerNode.stop()

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

    private func startAudioEngine() {
        let input = engine.inputNode
        // AEC: without voice processing the assistant hears herself through
        // the speakers and barge-in fires on her own voice.
        try? input.setVoiceProcessingEnabled(true)

        let hwFormat = input.outputFormat(forBus: 0)
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

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        let socket = webSocket
        let controller = self
        input.installTap(onBus: 0, bufferSize: 2_048, format: hwFormat) { buffer, _ in
            // Audio thread: no main-actor state. Mute is read via the
            // published property snapshot captured through the controller
            // reference (Bool read is tear-free).
            if controller.isMuted { return }
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
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
            guard conversionError == nil,
                  converted.frameLength > 0,
                  let channel = converted.int16ChannelData else { return }
            let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: channel[0], count: byteCount)
            socket?.send(.data(data)) { _ in }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            hangUp(reason: "音频引擎启动失败：\(error.localizedDescription)")
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
        if !playerNode.isPlaying, engine.isRunning {
            playerNode.play()
        }
    }

    private func stopAudioEngine() {
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        playbackFormat = nil
    }
}
