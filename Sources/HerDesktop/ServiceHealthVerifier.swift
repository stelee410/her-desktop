import Foundation

@MainActor
final class ServiceHealthVerifier {
    private let config: HerAppConfig
    private let session: URLSession

    init(config: HerAppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func initialSnapshot(pluginCount: Int) -> [ServiceHealth] {
        [
            .init(
                id: "agentllm",
                name: "AgentLLM",
                kind: "model",
                baseURL: config.agentLLMBaseURL,
                state: config.hasLLMKey ? .unknown : .offline,
                summary: config.hasLLMKey ? "Configured" : "Missing key",
                checkedAt: nil
            ),
            .init(
                id: "agentmem",
                name: "AgentMem",
                kind: "memory",
                baseURL: config.agentMemBaseURL,
                state: config.hasMemKey ? .unknown : .offline,
                summary: config.hasMemKey ? "Configured" : "Missing key",
                checkedAt: nil
            ),
            .init(
                id: "plugins",
                name: "Plugin Runtime",
                kind: "extension",
                baseURL: nil,
                state: .online,
                summary: "\(pluginCount) installed",
                checkedAt: Date()
            )
        ]
    }

    func checkingSnapshot(pluginCount: Int) -> [ServiceHealth] {
        initialSnapshot(pluginCount: pluginCount).map { item in
            if item.id == "plugins" { return item }
            var checking = item
            checking.state = .checking
            checking.summary = "Checking..."
            return checking
        }
    }

    func checkAll(pluginCount: Int) async -> [ServiceHealth] {
        return [
            await checkAgentLLM(),
            await checkAgentMem(),
            .init(
                id: "plugins",
                name: "Plugin Runtime",
                kind: "extension",
                baseURL: nil,
                state: .online,
                summary: "\(pluginCount) installed",
                checkedAt: Date()
            )
        ]
    }

    private func checkAgentLLM() async -> ServiceHealth {
        guard config.hasLLMKey else {
            return .init(
                id: "agentllm",
                name: "AgentLLM",
                kind: "model",
                baseURL: config.agentLLMBaseURL,
                state: .offline,
                summary: "Missing key",
                checkedAt: Date()
            )
        }

        do {
            let body = try await getText(url: config.agentLLMBaseURL.appending(path: "/health"), headers: [:])
            let healthSummary = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let chatSummary = try await checkAgentLLMChatDataPlane()
            let summary = [
                healthSummary.isEmpty ? "Health OK" : String(healthSummary.prefix(80)),
                chatSummary
            ].joined(separator: " · ")
            return .init(
                id: "agentllm",
                name: "AgentLLM",
                kind: "model",
                baseURL: config.agentLLMBaseURL,
                state: .online,
                summary: summary,
                checkedAt: Date()
            )
        } catch {
            return .init(
                id: "agentllm",
                name: "AgentLLM",
                kind: "model",
                baseURL: config.agentLLMBaseURL,
                state: Self.isCancellation(error) ? .unknown : .offline,
                summary: Self.isCancellation(error)
                    ? "Check was interrupted; run Check Services."
                    : error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    private func checkAgentLLMChatDataPlane() async throws -> String {
        let url = config.agentLLMBaseURL.appending(path: "/v1/chat/completions")
        let body: [String: Any] = [
            "model": config.agentLLMModel,
            "messages": [
                [
                    "role": "system",
                    "content": "Her Desktop service health check."
                ],
                [
                    "role": "user",
                    "content": "Reply with OK."
                ]
            ],
            "temperature": 0,
            "max_tokens": 4,
            "stream": false
        ]
        _ = try await postData(
            url: url,
            body: body,
            headers: [
                "Authorization": "Bearer \(config.agentLLMAPIKey)"
            ]
        )
        return "Chat OK"
    }

    private func checkAgentMem() async -> ServiceHealth {
        guard config.hasMemKey else {
            return .init(
                id: "agentmem",
                name: "AgentMem",
                kind: "memory",
                baseURL: config.agentMemBaseURL,
                state: .offline,
                summary: "Missing key",
                checkedAt: Date()
            )
        }

        do {
            let data = try await getData(
                url: config.agentMemBaseURL.appending(path: "/v1/memory/relationship"),
                headers: memoryHeaders()
            )
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let relationshipSummary = Self.relationshipSummary(from: object)
            let querySummary = try await checkAgentMemQueryDataPlane()
            let summary = [relationshipSummary, querySummary]
                .joined(separator: " · ")
            return .init(
                id: "agentmem",
                name: "AgentMem",
                kind: "memory",
                baseURL: config.agentMemBaseURL,
                state: .online,
                summary: summary,
                checkedAt: Date()
            )
        } catch {
            return .init(
                id: "agentmem",
                name: "AgentMem",
                kind: "memory",
                baseURL: config.agentMemBaseURL,
                state: Self.isCancellation(error) ? .unknown : .offline,
                summary: Self.isCancellation(error)
                    ? "Check was interrupted; run Check Services."
                    : error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private func checkAgentMemQueryDataPlane() async throws -> String {
        let url = config.agentMemBaseURL.appending(path: "/v1/memory/query")
        let body: [String: Any] = [
            "session_id": "her-desktop-health",
            "query": "Her Desktop health check",
            "top_k": 1,
            "retrieval_policy": "balanced",
            "min_similarity": 0.08
        ]
        _ = try await postData(url: url, body: body, headers: memoryHeaders())
        return "Memory query OK"
    }

    private func getText(url: URL, headers: [String: String]) async throws -> String {
        let data = try await getData(url: url, headers: headers)
        return String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
    }

    private func getData(url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func postData(url: URL, body: [String: Any], headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func data(for request: URLRequest, attempts: Int = 3) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await session.data(for: request)
            } catch {
                if Self.isCancellation(error) {
                    throw error
                }
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 350_000_000)
                }
            }
        }
        throw lastError ?? ServiceError.invalidResponse
    }

    private func memoryHeaders() -> [String: String] {
        [
            "X-Memory-API-Key": config.agentMemAPIKey
        ]
    }

    private static func boolSummary(_ value: Any?) -> String? {
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return nil
    }

    private static func relationshipSummary(from object: [String: Any]?) -> String {
        guard let object else { return "Relationship OK" }
        if let stageLabel = object["stage_label"] as? String, !stageLabel.isEmpty {
            return "relationship \(stageLabel)"
        }
        if let stage = object["stage"] as? String, !stage.isEmpty {
            return "relationship \(stage)"
        }
        if let memoryID = object["memory_id"] as? String, !memoryID.isEmpty {
            return "memory \(memoryID)"
        }
        if let known = boolSummary(object["known"]) {
            return "relationship known \(known)"
        }
        return "Relationship OK"
    }
}
