import Foundation

enum ServiceError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse
    case httpStatus(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let service):
            return "\(service) API key is missing."
        case .invalidResponse:
            return "The service returned an invalid response."
        case .httpStatus(let status, let body):
            return "HTTP \(status): \(SecretRedactor.redact(body))"
        case .decoding(let message):
            return "Decoding failed: \(message)"
        }
    }
}

struct AgentMemQueryResponse: Codable {
    struct RetrievedMemory: Codable, Identifiable {
        var id: String { fact + layer }
        var fact: String
        var score: Double
        var layer: String
    }

    var injectedContext: String
    var retrievedMemories: [RetrievedMemory]
    var timingMs: Double?

    enum CodingKeys: String, CodingKey {
        case injectedContext = "injected_context"
        case retrievedMemories = "retrieved_memories"
        case timingMs = "timing_ms"
    }
}

struct AgentMemAddResponse: Codable {
    var status: String
    var taskID: String

    enum CodingKeys: String, CodingKey {
        case status
        case taskID = "task_id"
    }
}

@MainActor
final class AgentMemClient {
    private let config: HerAppConfig
    private let session: URLSession

    init(config: HerAppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func query(_ text: String, sessionID: String, topK: Int = 8) async throws -> AgentMemQueryResponse {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        let url = config.agentMemBaseURL.appending(path: "/v1/memory/query")
        let body: [String: Any] = [
            "agent_code": config.agentCode,
            "user_id": config.userID,
            "session_id": sessionID,
            "query": text,
            "top_k": topK,
            "retrieval_policy": "balanced",
            "min_similarity": 0.08
        ]
        do {
            return try await postJSON(url: url, body: body, headers: memoryHeaders())
        } catch {
            guard Self.shouldRetryWithLegacyPayload(error) else { throw error }
            let legacyBody: [String: Any] = [
                "session_id": sessionID,
                "query": text,
                "top_k": topK,
                "retrieval_policy": "balanced",
                "min_similarity": 0.08
            ]
            return try await postJSON(url: url, body: legacyBody, headers: memoryHeaders())
        }
    }

    func add(userInput: String, agentResponse: String, sessionID: String, metadata: [String: Any] = [:]) async throws -> AgentMemAddResponse {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        let url = config.agentMemBaseURL.appending(path: "/v1/memory/add")
        let body: [String: Any] = [
            "agent_code": config.agentCode,
            "user_id": config.userID,
            "session_id": sessionID,
            "user_input": userInput,
            "agent_response": agentResponse,
            "metadata": metadata.merging([
                "her_user_id": config.userID,
                "her_agent_code": config.agentCode
            ]) { current, _ in current }
        ]
        var headers = memoryHeaders()
        headers["Idempotency-Key"] = "\(sessionID)-\(userInput.hashValue)-\(agentResponse.hashValue)"
        do {
            return try await postJSON(url: url, body: body, headers: headers)
        } catch {
            guard Self.shouldRetryWithLegacyPayload(error) else { throw error }
            let legacyBody: [String: Any] = [
                "user_input": userInput,
                "agent_response": agentResponse
            ]
            return try await postJSON(url: url, body: legacyBody, headers: headers)
        }
    }

    func relationship() async throws -> [String: Any] {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        let url = config.agentMemBaseURL
            .appending(path: "/v1/users/\(config.userID)/relationship")
            .appendingQueryItems(["agent_code": config.agentCode])
        do {
            return try await getJSONDictionary(url: url, headers: memoryHeaders())
        } catch {
            guard Self.shouldRetryRelationshipIdentity(error) else { throw error }
            return try await getJSONDictionary(
                url: config.agentMemBaseURL.appending(path: "/v1/me"),
                headers: memoryHeaders()
            )
        }
    }

    private func postJSON<T: Decodable>(url: URL, body: [String: Any], headers: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    private func getJSONDictionary(url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
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
            // Kept for local/dev AgentMem checkouts that still use the earlier header name.
            "X-Agent-API-Key": config.agentMemAPIKey
        ]
    }

    private static func shouldRetryWithLegacyPayload(_ error: Error) -> Bool {
        guard case ServiceError.httpStatus(let status, let body) = error, status == 422 else {
            return false
        }
        return body.contains("extra_forbidden")
            && (body.contains("agent_code") || body.contains("user_id"))
    }

    private static func shouldRetryRelationshipIdentity(_ error: Error) -> Bool {
        guard case ServiceError.httpStatus(let status, let body) = error else {
            return false
        }
        if status == 404 { return true }
        if status == 422 {
            return body.contains("extra_forbidden")
                || body.contains("agent_code")
                || body.contains("not found")
        }
        return false
    }
}

private extension URL {
    func appendingQueryItems(_ items: [String: String]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: items.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = queryItems
        return components.url ?? self
    }
}

struct AgentLLMChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            struct ToolCall: Codable, Identifiable, Equatable {
                struct FunctionCall: Codable, Equatable {
                    var name: String
                    var arguments: String
                }

                var id: String
                var type: String
                var function: FunctionCall
            }

            var role: String?
            var content: String?
            var toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case toolCalls = "tool_calls"
            }
        }
        var message: Message?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]
}

struct AgentLLMMessage: Codable, Equatable {
    var role: String
    var content: String?
    var name: String?
    var toolCallID: String?
    var toolCalls: [AgentLLMChatResponse.Choice.Message.ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    static func system(_ content: String) -> AgentLLMMessage {
        AgentLLMMessage(role: "system", content: content)
    }

    static func user(_ content: String) -> AgentLLMMessage {
        AgentLLMMessage(role: "user", content: content)
    }

    static func assistant(content: String?, toolCalls: [AgentLLMChatResponse.Choice.Message.ToolCall]? = nil) -> AgentLLMMessage {
        AgentLLMMessage(role: "assistant", content: content, toolCalls: toolCalls)
    }

    static func toolResult(id: String, name: String, content: String) -> AgentLLMMessage {
        AgentLLMMessage(role: "tool", content: content, name: name, toolCallID: id)
    }
}

@MainActor
protocol AgentLLMChatting {
    func chat(messages: [AgentLLMMessage], tools: [[String: Any]]) async throws -> AgentLLMChatResponse.Choice.Message
}

@MainActor
final class AgentLLMClient: AgentLLMChatting {
    private let config: HerAppConfig
    private let session: URLSession

    init(config: HerAppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func chat(messages: [AgentLLMMessage], tools: [[String: Any]] = []) async throws -> AgentLLMChatResponse.Choice.Message {
        guard config.hasLLMKey else { throw ServiceError.missingAPIKey("AgentLLM") }
        let url = config.agentLLMBaseURL.appending(path: "/v1/chat/completions")
        var body: [String: Any] = [
            "model": config.agentLLMModel,
            "messages": try messages.map { try $0.jsonObject() },
            "temperature": 0.7,
            "stream": false
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.agentLLMAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(AgentLLMChatResponse.self, from: data)
        return decoded.choices.first?.message ?? .init(role: "assistant", content: "")
    }

    private func data(for request: URLRequest, attempts: Int = 2) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
                }
            }
        }
        throw lastError ?? ServiceError.invalidResponse
    }
}

private extension Encodable {
    func jsonObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}

func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw ServiceError.httpStatus(http.statusCode, body)
    }
}
