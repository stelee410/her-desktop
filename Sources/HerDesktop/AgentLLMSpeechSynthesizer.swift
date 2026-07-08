import AVFoundation
import Foundation

/// Server-side TTS through the AgentLLM endpoint (OpenAI-compatible
/// `POST /v1/audio/speech`, doubao-tts voices) played back locally.
@MainActor
final class AgentLLMSpeechSynthesizer: NSObject, NativeSpeechSynthesizing, AVAudioPlayerDelegate {
    private let config: HerAppConfig
    private let urlSession: URLSession
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<String, Error>?
    private var utteranceID: String?
    /// Set while the speech request is in flight so stop() can cancel it.
    private var fetchTask: Task<Void, Never>?

    init(config: HerAppConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    func speak(_ text: String, voiceIdentifier: String?) async throws -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { throw SpeechError.emptyText }
        guard config.hasLLMKey else { throw SpeechError.missingAPIKey }
        stop()

        let id = "her-agentllm-tts-\(UUID().uuidString)"
        // The manifest-level voiceIdentifier is the Apple voice; the AgentLLM
        // speaker comes from config unless an agentllm voice was passed.
        let voice = voiceIdentifier?.hasPrefix("zh_") == true || voiceIdentifier?.contains("bigtts") == true
            ? voiceIdentifier!
            : config.agentLLMTTSVoice

        let audio = try await fetchSpeech(text: cleanText, voice: voice)
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        self.player = player
        self.utteranceID = id
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if !player.play() {
                finishSpeech(.failure(SpeechError.couldNotStart))
            }
        }
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        finishSpeech(.success(utteranceID ?? "stopped"))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finishSpeech(.success(self.utteranceID ?? "finished"))
        }
    }

    private func fetchSpeech(text: String, voice: String) async throws -> Data {
        let endpoint = config.agentLLMBaseURL.appending(path: "/v1/audio/speech")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(config.agentLLMAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.agentLLMTTSModel,
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            let detail = String(data: Data(data.prefix(300)), encoding: .utf8) ?? ""
            throw SpeechError.synthesisFailed(status: status, detail: detail)
        }
        return data
    }

    private func finishSpeech(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        player?.delegate = nil
        player = nil
        let id = utteranceID
        utteranceID = nil
        switch result {
        case .success:
            continuation.resume(returning: id ?? "speech-complete")
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    enum SpeechError: LocalizedError {
        case emptyText
        case missingAPIKey
        case couldNotStart
        case synthesisFailed(status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "No text was provided for speech."
            case .missingAPIKey:
                return "AgentLLM TTS needs an AgentLLM API key (Settings → AgentLLM)."
            case .couldNotStart:
                return "Audio playback could not start."
            case .synthesisFailed(let status, let detail):
                return "AgentLLM speech synthesis failed (HTTP \(status)). \(detail)"
            }
        }
    }
}

/// Fetches the selectable speaker list from the AgentLLM endpoint
/// (`GET /v1beta/volc/tts/voices`) for the settings dropdown.
struct AgentLLMVoiceCatalog {
    struct Voice: Identifiable, Equatable {
        var id: String
        var label: String
        var gender: String
    }

    static func fetch(
        baseURL: URL,
        apiKey: String,
        urlSession: URLSession = .shared
    ) async throws -> [Voice] {
        var request = URLRequest(url: baseURL.appending(path: "/v1beta/volc/tts/voices"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [Voice] {
        // Tolerate both a bare array and {"voices":[...]} / {"data":[...]}.
        let object = try? JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let dict = object as? [String: Any] {
            items = (dict["voices"] ?? dict["data"]) as? [[String: Any]] ?? []
        } else {
            items = []
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return Voice(
                id: id,
                label: (item["label"] as? String)?.nilIfEmptyLabel ?? id,
                gender: item["gender"] as? String ?? ""
            )
        }
    }
}

private extension String {
    var nilIfEmptyLabel: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
