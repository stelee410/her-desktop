import AVFoundation
import Foundation

/// Real-time server-side dictation through the AgentLLM endpoint's
/// DashScope ASR bridge (`WS /v1beta/dashscope/asr/ws`, run-task protocol):
/// 16kHz mono PCM frames go up, incremental sentences come back — live
/// partials just like the system recognizer. Models: fun-asr-realtime /
/// paraformer-realtime-v2. Billed by audio seconds.
@MainActor
final class AgentLLMDictationService: NSObject, NativeSpeechDictating, AudioLevelReporting {
    var onAudioLevel: (@MainActor (CGFloat) -> Void)?

    private let config: HerAppConfig
    private let urlSession: URLSession
    private let audioEngine = AVAudioEngine()
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var onPartial: (@MainActor (String) -> Void)?
    private var finishedSentences: [String] = []
    private var currentSentence = ""
    private var stopTimeoutTask: Task<Void, Never>?
    private var activeTaskID = ""
    private var captureStats: AudioCaptureStats?
    private var captureSampleRate: Double = 16_000

    init(config: HerAppConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    func start(localeIdentifier: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard config.hasLLMKey else {
            throw DictationError.missingAPIKey
        }
        let microphoneGranted = await AVAudioApplication.requestRecordPermission()
        guard microphoneGranted else {
            throw DictationError.microphonePermissionDenied
        }
        teardown(resumeWith: nil)
        self.onPartial = onPartial
        finishedSentences = []
        currentSentence = ""

        // wss://…/v1beta/dashscope/asr/ws?api_key=… (browser-style WS auth).
        var components = URLComponents(url: config.agentLLMBaseURL, resolvingAgainstBaseURL: false)
        components?.scheme = config.agentLLMBaseURL.scheme == "http" ? "ws" : "wss"
        components?.path = "/v1beta/dashscope/asr/ws"
        components?.queryItems = [URLQueryItem(name: "api_key", value: config.agentLLMAPIKey)]
        guard let url = components?.url else {
            throw DictationError.badEndpoint
        }
        let socket = urlSession.webSocketTask(with: url)
        webSocket = socket
        socket.resume()
        startReceiveLoop(socket)

        // Open the microphone BEFORE the server handshake and buffer frames
        // locally — otherwise the first ~1s of speech (WS connect + task
        // confirmation) is lost. The gate holds frames until goLive().
        let gate = AudioFrameGate { data in
            socket.send(.data(data)) { _ in }
        }
        try startMicrophoneStream(into: gate)

        // Kick off the ASR task and wait for task-started before streaming.
        // The task_id must stay stable for the whole session — finish-task
        // with a different id is silently ignored by the server.
        activeTaskID = UUID().uuidString
        let runTask: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": activeTaskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": config.agentLLMASRModel,
                "input": [String: Any](),
                "parameters": [
                    "sample_rate": 16_000,
                    "format": "pcm"
                ]
            ]
        ]
        try await send(json: runTask, over: socket)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.failStartIfPending(DictationError.serverNotReady)
            }
        }

        // Server confirmed: flush everything said so far, then stream live.
        gate.goLive()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        stopMicrophone()
        guard let socket = webSocket, continuation != nil else {
            teardown(resumeWith: nil)
            return
        }
        // Ask the server to flush final results; task-finished resolves us.
        let finishTask: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": activeTaskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [String: Any]()]
        ]
        Task { @MainActor [weak self] in
            try? await self?.send(json: finishTask, over: socket)
        }
        stopTimeoutTask?.cancel()
        stopTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.finish(with: self.accumulatedTranscript())
        }
    }

    // MARK: - Audio

    private func startMicrophoneStream(into gate: AudioFrameGate) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw DictationError.audioFormatUnavailable
        }

        inputNode.removeTap(onBus: 0)
        // Tap runs on the CoreAudio render thread: convert to 16k PCM and
        // hand binary frames to the gate (buffered until the server is ready,
        // then straight to the socket — send is thread-safe).
        nonisolated(unsafe) let tapConverter = converter
        let levelHandler = onAudioLevel
        let levelCounter = TapCounter()
        let stats = AudioCaptureStats()
        captureStats = stats
        captureSampleRate = inputFormat.sampleRate
        let ratio = 16_000.0 / inputFormat.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { @Sendable buffer, _ in
            stats.record(peak: AudioLevelMeter.peak(of: buffer), frames: Int(buffer.frameLength))
            if let levelHandler, levelCounter.shouldSample() {
                let level = AudioLevelMeter.level(of: buffer)
                Task { @MainActor in levelHandler(level) }
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            tapConverter.convert(to: converted, error: nil) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard converted.frameLength > 0, let channel = converted.int16ChannelData else { return }
            let data = Data(bytes: channel[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
            gate.push(data)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopMicrophone() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - WebSocket

    private func startReceiveLoop(_ socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    if case .string(let text) = message {
                        self.handleServerEvent(text)
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    // Socket dropped: fail a pending start, or finish with
                    // whatever was recognized so the text isn't lost.
                    self.failStartIfPending(error)
                    if self.continuation != nil {
                        self.finish(with: self.accumulatedTranscript())
                    }
                    return
                }
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String else {
            return
        }
        switch event {
        case "task-started":
            startContinuation?.resume()
            startContinuation = nil
        case "result-generated":
            let payload = object["payload"] as? [String: Any]
            let output = payload?["output"] as? [String: Any]
            let sentence = output?["sentence"] as? [String: Any]
            guard let sentenceText = sentence?["text"] as? String else { return }
            let ended = sentence?["sentence_end"] as? Bool ?? false
            if ended {
                finishedSentences.append(sentenceText)
                currentSentence = ""
            } else {
                currentSentence = sentenceText
            }
            onPartial?(accumulatedTranscript())
        case "task-finished":
            finish(with: accumulatedTranscript())
        case "task-failed":
            let message = (header["error_message"] as? String) ?? "ASR task failed"
            failStartIfPending(DictationError.serverError(message))
            if continuation != nil {
                // Keep whatever was already recognized.
                finish(with: accumulatedTranscript())
            }
        default:
            break
        }
    }

    private func accumulatedTranscript() -> String {
        (finishedSentences + (currentSentence.isEmpty ? [] : [currentSentence]))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(json: [String: Any], over socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await socket.send(.string(text))
    }

    private func failStartIfPending(_ error: Error) {
        guard let pending = startContinuation else { return }
        startContinuation = nil
        pending.resume(throwing: error)
        teardown(resumeWith: nil)
    }

    private func finish(with transcript: String) {
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        let pending = continuation
        continuation = nil
        let silentMic = transcript.isEmpty
            && captureStats?.capturedOnlySilence(sampleRate: captureSampleRate) == true
        captureStats = nil
        teardown(resumeWith: nil)
        if silentMic {
            // All-zero capture: the mic permission is stale (TCC grant no
            // longer matches the app signature) — surface it instead of
            // quietly returning an empty transcript.
            pending?.resume(throwing: DictationError.silentMicrophone)
        } else {
            pending?.resume(returning: transcript)
        }
    }

    private func teardown(resumeWith _: String?) {
        stopMicrophone()
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        onPartial = nil
    }

    enum DictationError: LocalizedError {
        case missingAPIKey
        case microphonePermissionDenied
        case badEndpoint
        case audioFormatUnavailable
        case serverNotReady
        case serverError(String)
        case silentMicrophone

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "AgentLLM ASR needs an AgentLLM API key (Settings → AgentLLM)."
            case .microphonePermissionDenied:
                return "Microphone permission was not granted."
            case .badEndpoint:
                return "Could not build the AgentLLM ASR endpoint URL."
            case .audioFormatUnavailable:
                return "Could not prepare the 16kHz audio converter for ASR."
            case .serverNotReady:
                return "AgentLLM ASR did not confirm the task in time."
            case .serverError(let message):
                return "AgentLLM ASR failed: \(message)"
            case .silentMicrophone:
                return "麦克风只收到了静音——请在 系统设置 → 隐私与安全性 → 麦克风 中重新为 Her Desktop 授权后再试。"
            }
        }
    }
}

/// Buffers converted PCM frames captured before the ASR server confirms the
/// task, then replays them in order and passes frames straight through.
/// Written from the CoreAudio render thread, flipped live on the main actor;
/// the lock also guarantees flush-before-live ordering.
final class AudioFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [Data] = []
    private var isLive = false
    private let send: @Sendable (Data) -> Void
    /// ~14s at 16k mono Int16 with ~43ms frames — far past the 5s handshake
    /// timeout, so a stuck handshake can't grow memory unbounded.
    private let maxBufferedFrames = 320

    init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
    }

    func push(_ data: Data) {
        lock.lock()
        if isLive {
            lock.unlock()
            send(data)
            return
        }
        if buffered.count < maxBufferedFrames {
            buffered.append(data)
        }
        lock.unlock()
    }

    func goLive() {
        lock.lock()
        defer { lock.unlock() }
        isLive = true
        // Flush under the lock: a concurrent push must not overtake the
        // buffered frames (audio must reach the server in capture order).
        for frame in buffered {
            send(frame)
        }
        buffered = []
    }
}
