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

struct AgentMemTaskStatus: Codable {
    var taskID: String
    var taskType: String
    var status: String
    var createdAt: String?
    var startedAt: String?
    var finishedAt: String?
    var result: [String: JSONValue]?
    var error: String?
    var durationMs: Double?

    var isTerminal: Bool {
        status == "succeeded" || status == "failed"
    }

    var auditSummary: String {
        var parts = ["AgentMem task \(status)"]
        if let durationMs {
            parts.append("\(durationMs)ms")
        }
        if let error, !error.isEmpty {
            parts.append(SecretRedactor.redact(error))
        }
        return parts.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case taskType = "task_type"
        case status
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case result
        case error
        case durationMs = "duration_ms"
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
        return try await postJSON(
            url: url,
            body: queryBody(text: text, sessionID: sessionID, topK: topK),
            headers: memoryHeaders()
        )
    }

    func add(userInput: String, agentResponse: String, sessionID: String, metadata: [String: Any] = [:]) async throws -> AgentMemAddResponse {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        let url = config.agentMemBaseURL.appending(path: "/v1/memory/add")
        var headers = memoryHeaders()
        headers["Idempotency-Key"] = "\(sessionID)-\(userInput.hashValue)-\(agentResponse.hashValue)"
        return try await postJSON(
            url: url,
            body: addBody(
                userInput: userInput,
                agentResponse: agentResponse,
                sessionID: sessionID,
                metadata: metadata
            ),
            headers: headers
        )
    }

    func addSummary(_ summary: String, sessionID: String, metadata: [String: Any] = [:]) async throws -> AgentMemAddResponse {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        let url = config.agentMemBaseURL.appending(path: "/v1/memory/add")
        var headers = memoryHeaders()
        headers["Idempotency-Key"] = "\(sessionID)-summary-\(summary.hashValue)"
        return try await postJSON(
            url: url,
            body: summaryBody(summary: summary, sessionID: sessionID, metadata: metadata),
            headers: headers
        )
    }

    func relationship() async throws -> [String: Any] {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        return try await getJSONDictionary(
            url: config.agentMemBaseURL.appending(path: "/v1/memory/relationship"),
            headers: memoryHeaders()
        )
    }

    func emotion() async throws -> [String: Any] {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        return try await getJSONDictionary(
            url: config.agentMemBaseURL.appending(path: "/v1/memory/emotion"),
            headers: memoryHeaders()
        )
    }

    func taskStatus(taskID: String) async throws -> AgentMemTaskStatus {
        guard config.hasMemKey else { throw ServiceError.missingAPIKey("AgentMem") }
        return try await getJSON(
            url: config.agentMemBaseURL.appending(path: "/v1/tasks/\(taskID)"),
            headers: memoryHeaders()
        )
    }

    func waitForTaskStatus(
        taskID: String,
        maxAttempts: Int = 6,
        delayNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> AgentMemTaskStatus {
        let attempts = max(maxAttempts, 1)
        var lastStatus: AgentMemTaskStatus?
        for attempt in 1...attempts {
            let status = try await taskStatus(taskID: taskID)
            lastStatus = status
            if status.isTerminal {
                return status
            }
            if attempt < attempts {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return lastStatus ?? AgentMemTaskStatus(
            taskID: taskID,
            taskType: "unknown",
            status: "unknown",
            createdAt: nil,
            startedAt: nil,
            finishedAt: nil,
            result: nil,
            error: nil,
            durationMs: nil
        )
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

    private func getJSON<T: Decodable>(url: URL, headers: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
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
            "X-Memory-API-Key": config.agentMemAPIKey
        ]
    }

    private func queryBody(text: String, sessionID: String, topK: Int) -> [String: Any] {
        [
            "session_id": sessionID,
            "query": text,
            "top_k": topK,
            "retrieval_policy": "balanced",
            "min_similarity": 0.08
        ]
    }

    private func addBody(
        userInput: String,
        agentResponse: String,
        sessionID: String,
        metadata: [String: Any]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "session_id": sessionID,
            "user_input": userInput,
            "agent_response": agentResponse
        ]
        if !metadata.isEmpty {
            body["metadata"] = metadata
        }
        return body
    }

    private func summaryBody(summary: String, sessionID: String, metadata: [String: Any]) -> [String: Any] {
        var body: [String: Any] = [
            "session_id": sessionID,
            "summary": summary
        ]
        if !metadata.isEmpty {
            body["metadata"] = metadata
        }
        return body
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
            var reasoningContent: String?
            var toolCalls: [ToolCall]?
            /// Why generation stopped ("stop", "length", "tool_calls").
            /// Filled from stream chunks or the enclosing choice.
            var finishReason: String? = nil

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
                case finishReason = "finish_reason"
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

enum AgentLLMStreamEvent {
    case reasoningDelta(String)
    case contentDelta(String)
}

@MainActor
protocol AgentLLMChatting {
    func chat(
        messages: [AgentLLMMessage],
        tools: [[String: Any]],
        onEvent: @escaping @MainActor (AgentLLMStreamEvent) -> Void
    ) async throws -> AgentLLMChatResponse.Choice.Message
}

extension AgentLLMChatting {
    func chat(messages: [AgentLLMMessage], tools: [[String: Any]] = []) async throws -> AgentLLMChatResponse.Choice.Message {
        try await chat(messages: messages, tools: tools, onEvent: { _ in })
    }
}

/// Splits a streamed content channel into visible content and `<think>…</think>`
/// reasoning, holding back partial tags that arrive split across chunks.
struct ThinkTagStreamFilter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var inThink = false

    mutating func feed(_ text: String) -> (content: String, reasoning: String) {
        buffer += text
        var content = ""
        var reasoning = ""
        while true {
            let tag = inThink ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: tag) {
                let before = String(buffer[..<range.lowerBound])
                if inThink { reasoning += before } else { content += before }
                buffer.removeSubrange(..<range.upperBound)
                inThink.toggle()
            } else {
                let hold = Self.partialTagSuffixLength(of: buffer, tag: tag)
                let emitEnd = buffer.index(buffer.endIndex, offsetBy: -hold)
                let emitted = String(buffer[..<emitEnd])
                if inThink { reasoning += emitted } else { content += emitted }
                buffer = String(buffer[emitEnd...])
                break
            }
        }
        return (content, reasoning)
    }

    mutating func flush() -> (content: String, reasoning: String) {
        let rest = buffer
        buffer = ""
        return inThink ? ("", rest) : (rest, "")
    }

    static func extract(from text: String) -> (content: String, reasoning: String) {
        var filter = ThinkTagStreamFilter()
        let fed = filter.feed(text)
        let tail = filter.flush()
        return (fed.content + tail.content, fed.reasoning + tail.reasoning)
    }

    private static func partialTagSuffixLength(of text: String, tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) where text.hasSuffix(String(tag.prefix(length))) {
            return length
        }
        return 0
    }
}

private struct AgentLLMStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCallDelta: Decodable {
                struct FunctionDelta: Decodable {
                    var name: String?
                    var arguments: String?
                }

                var index: Int?
                var id: String?
                var type: String?
                var function: FunctionDelta?
            }

            var role: String?
            var content: String?
            var reasoningContent: String?
            var reasoning: String?
            var toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]?
}

private struct StreamedToolCallAccumulator {
    var id = ""
    var type = "function"
    var name = ""
    var arguments = ""

    func finalized(index: Int) -> AgentLLMChatResponse.Choice.Message.ToolCall? {
        guard !name.isEmpty else { return nil }
        return .init(
            id: id.isEmpty ? "call_\(index)_\(name)" : id,
            type: type.isEmpty ? "function" : type,
            function: .init(name: name, arguments: arguments)
        )
    }
}

@MainActor
final class AgentLLMClient: AgentLLMChatting {
    private let config: HerAppConfig
    private let session: URLSession

    init(config: HerAppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func chat(
        messages: [AgentLLMMessage],
        tools: [[String: Any]],
        onEvent: @escaping @MainActor (AgentLLMStreamEvent) -> Void
    ) async throws -> AgentLLMChatResponse.Choice.Message {
        guard config.hasLLMKey else { throw ServiceError.missingAPIKey("AgentLLM") }
        let url = config.agentLLMBaseURL.appending(path: "/v1/chat/completions")
        var body: [String: Any] = [
            "model": config.agentLLMModel,
            "messages": try messages.map { try $0.jsonObject() },
            "temperature": 0.7,
            "stream": true
        ]
        if config.agentLLMMaxTokens > 0 {
            body["max_tokens"] = config.agentLLMMaxTokens
        }
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.agentLLMAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await streamChat(request: request, onEvent: onEvent)
    }

    private func streamChat(
        request: URLRequest,
        onEvent: @escaping @MainActor (AgentLLMStreamEvent) -> Void
    ) async throws -> AgentLLMChatResponse.Choice.Message {
        let (bytes, response) = try await bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 64_000 { break }
            }
            throw ServiceError.httpStatus(http.statusCode, String(data: bodyData, encoding: .utf8) ?? "")
        }

        var role: String?
        var content = ""
        var reasoning = ""
        var finishReason: String?
        var thinkFilter = ThinkTagStreamFilter()
        var toolCalls: [Int: StreamedToolCallAccumulator] = [:]
        var nextImplicitToolIndex = 0
        var sawStreamEvent = false
        var rawFallback = ""

        func emitReasoning(_ delta: String) {
            guard !delta.isEmpty else { return }
            reasoning += delta
            onEvent(.reasoningDelta(delta))
        }

        func emitContent(_ delta: String) {
            guard !delta.isEmpty else { return }
            let split = thinkFilter.feed(delta)
            if !split.reasoning.isEmpty {
                reasoning += split.reasoning
                onEvent(.reasoningDelta(split.reasoning))
            }
            if !split.content.isEmpty {
                content += split.content
                onEvent(.contentDelta(split.content))
            }
        }

        for try await line in bytes.lines {
            if line.hasPrefix("data:") {
                sawStreamEvent = true
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(AgentLLMStreamChunk.self, from: data) else { continue }
                if let reason = chunk.choices?.first?.finishReason, !reason.isEmpty {
                    finishReason = reason
                }
                guard let delta = chunk.choices?.first?.delta else { continue }
                if let deltaRole = delta.role, !deltaRole.isEmpty {
                    role = deltaRole
                }
                emitReasoning(delta.reasoningContent ?? delta.reasoning ?? "")
                emitContent(delta.content ?? "")
                for toolDelta in delta.toolCalls ?? [] {
                    let index = toolDelta.index ?? nextImplicitToolIndex
                    nextImplicitToolIndex = max(nextImplicitToolIndex, index + 1)
                    var accumulator = toolCalls[index] ?? StreamedToolCallAccumulator()
                    if let id = toolDelta.id, !id.isEmpty { accumulator.id = id }
                    if let type = toolDelta.type, !type.isEmpty { accumulator.type = type }
                    if let name = toolDelta.function?.name, !name.isEmpty { accumulator.name += name }
                    if let arguments = toolDelta.function?.arguments { accumulator.arguments += arguments }
                    toolCalls[index] = accumulator
                }
            } else if !sawStreamEvent {
                rawFallback += line
            }
        }

        if !sawStreamEvent {
            return try nonStreamFallbackMessage(rawBody: rawFallback, onEvent: onEvent)
        }

        let tail = thinkFilter.flush()
        if !tail.reasoning.isEmpty {
            reasoning += tail.reasoning
            onEvent(.reasoningDelta(tail.reasoning))
        }
        if !tail.content.isEmpty {
            content += tail.content
            onEvent(.contentDelta(tail.content))
        }

        let finalToolCalls = toolCalls
            .sorted { $0.key < $1.key }
            .compactMap { $0.value.finalized(index: $0.key) }
        return .init(
            role: role ?? "assistant",
            content: content,
            reasoningContent: reasoning.isEmpty ? nil : reasoning,
            toolCalls: finalToolCalls.isEmpty ? nil : finalToolCalls,
            finishReason: finishReason
        )
    }

    /// Some gateways ignore `stream: true` and answer with a plain JSON body.
    private func nonStreamFallbackMessage(
        rawBody: String,
        onEvent: @escaping @MainActor (AgentLLMStreamEvent) -> Void
    ) throws -> AgentLLMChatResponse.Choice.Message {
        let trimmed = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AgentLLMChatResponse.self, from: data) else {
            throw ServiceError.decoding("AgentLLM returned an unrecognized streaming response.")
        }
        var message = decoded.choices.first?.message ?? .init(role: "assistant", content: "")
        if message.finishReason == nil {
            message.finishReason = decoded.choices.first?.finishReason
        }
        let extracted = ThinkTagStreamFilter.extract(from: message.content ?? "")
        message.content = extracted.content
        if message.reasoningContent?.isEmpty != false, !extracted.reasoning.isEmpty {
            message.reasoningContent = extracted.reasoning
        }
        if let reasoningContent = message.reasoningContent, !reasoningContent.isEmpty {
            onEvent(.reasoningDelta(reasoningContent))
        }
        if let content = message.content, !content.isEmpty {
            onEvent(.contentDelta(content))
        }
        return message
    }

    private func bytes(for request: URLRequest, attempts: Int = 2) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await session.bytes(for: request)
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
