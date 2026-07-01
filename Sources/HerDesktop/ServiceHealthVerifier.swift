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
                state: .offline,
                summary: error.localizedDescription,
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
                url: config.agentMemBaseURL.appending(path: "/v1/me"),
                headers: [
                    "X-Memory-API-Key": config.agentMemAPIKey,
                    "X-Agent-API-Key": config.agentMemAPIKey
                ]
            )
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let known = Self.boolSummary(object?["known"]) ?? object?["known"].map { "\($0)" } ?? "known"
            let displayName = object?["display_name"] as? String
            let identitySummary = [displayName, known].compactMap { $0 }.joined(separator: " · ")
            let querySummary = try await checkAgentMemQueryDataPlane()
            let summary = [identitySummary.isEmpty ? "Identity OK" : identitySummary, querySummary]
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
                state: .offline,
                summary: error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    private func checkAgentMemQueryDataPlane() async throws -> String {
        let url = config.agentMemBaseURL.appending(path: "/v1/memory/query")
        let scopedBody: [String: Any] = [
            "agent_code": config.agentCode,
            "user_id": config.userID,
            "session_id": "her-desktop-health",
            "query": "Her Desktop health check",
            "top_k": 1,
            "retrieval_policy": "balanced",
            "min_similarity": 0.08
        ]
        do {
            _ = try await postData(url: url, body: scopedBody, headers: memoryHeaders())
            return "Scoped query OK"
        } catch {
            guard Self.isLegacyAgentMemSchemaError(error) else { throw error }
            let legacyBody: [String: Any] = [
                "session_id": "her-desktop-health",
                "query": "Her Desktop health check",
                "top_k": 1,
                "retrieval_policy": "balanced",
                "min_similarity": 0.08
            ]
            _ = try await postData(url: url, body: legacyBody, headers: memoryHeaders())
            return "Legacy query OK"
        }
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
            "X-Memory-API-Key": config.agentMemAPIKey,
            "X-Agent-API-Key": config.agentMemAPIKey
        ]
    }

    private static func isLegacyAgentMemSchemaError(_ error: Error) -> Bool {
        guard case ServiceError.httpStatus(let status, let body) = error, status == 422 else {
            return false
        }
        return body.contains("extra_forbidden")
            && (body.contains("agent_code") || body.contains("user_id"))
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
}
