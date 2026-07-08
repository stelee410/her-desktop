import AVFoundation
import Foundation

/// Server-side dictation through the AgentLLM endpoint (OpenAI-compatible
/// `POST {base}/audio/transcriptions`, multipart WAV upload).
///
/// Unlike the Apple recognizer there are no streaming partials: this records
/// the microphone until `stop()`, then uploads once and returns the final
/// transcript. `onPartial` receives a lightweight recording indicator so the
/// composer shows that listening is active.
@MainActor
final class AgentLLMDictationService: NSObject, NativeSpeechDictating {
    private let config: HerAppConfig
    private let urlSession: URLSession
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private var continuation: CheckedContinuation<String, Error>?
    private var recordingLocale = ""

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
        stopRecordingOnly()
        recordingLocale = localeIdentifier

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-dictation-\(UUID().uuidString).wav")
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        audioFile = file
        audioFileURL = url

        inputNode.removeTap(onBus: 0)
        // The tap fires on the CoreAudio render thread; AVAudioFile.write is
        // safe there and the closure must not inherit @MainActor isolation.
        nonisolated(unsafe) let tapFile = file
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            try? tapFile.write(from: buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        onPartial("(录音中……再点一次麦克风结束并转写)")

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        stopRecordingOnly()
        guard let continuation else { return }
        self.continuation = nil
        guard let fileURL = audioFileURL else {
            continuation.resume(returning: "")
            return
        }
        audioFileURL = nil
        let locale = recordingLocale
        Task { @MainActor [config, urlSession] in
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let transcript = try await Self.transcribe(
                    fileURL: fileURL,
                    locale: locale,
                    config: config,
                    urlSession: urlSession
                )
                continuation.resume(returning: transcript)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func stopRecordingOnly() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        // Closing the file flushes the WAV header.
        audioFile = nil
    }

    // MARK: - Upload

    private static func transcribe(
        fileURL: URL,
        locale: String,
        config: HerAppConfig,
        urlSession: URLSession
    ) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        guard !audioData.isEmpty else { return "" }

        let endpoint = config.agentLLMBaseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(config.agentLLMAPIKey)", forHTTPHeaderField: "Authorization")

        let boundary = "her-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", config.agentLLMASRModel)
        // "zh-Hans-CN" → "zh"; the API expects an ISO-639-1 code.
        if let language = locale.split(separator: "-").first.map(String.init)?.lowercased(),
           !language.isEmpty {
            field("language", language)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: Data(data.prefix(300)), encoding: .utf8) ?? ""
            throw DictationError.transcriptionFailed(status: status, detail: detail)
        }
        // OpenAI-compatible: {"text": "..."}; tolerate plain-text bodies.
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum DictationError: LocalizedError {
        case missingAPIKey
        case microphonePermissionDenied
        case transcriptionFailed(status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "AgentLLM ASR needs an AgentLLM API key (Settings → AgentLLM)."
            case .microphonePermissionDenied:
                return "Microphone permission was not granted."
            case .transcriptionFailed(let status, let detail):
                return "AgentLLM transcription failed (HTTP \(status)). \(detail)"
            }
        }
    }
}
