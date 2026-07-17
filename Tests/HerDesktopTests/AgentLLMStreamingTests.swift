import XCTest
@testable import HerDesktop

@MainActor
final class AgentLLMStreamingTests: XCTestCase {
    final class StreamingMockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responseBody: Data = Data()
        nonisolated(unsafe) static var statusCode: Int = 200
        /// Non-empty: each request pops the next body (retry-behavior tests).
        nonisolated(unsafe) static var responseQueue: [Data] = []
        nonisolated(unsafe) static var requestCount = 0
        nonisolated(unsafe) static var lastRequestBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestCount += 1
            Self.lastRequestBody = Self.bodyData(of: request)
            let body = Self.responseQueue.isEmpty ? Self.responseBody : Self.responseQueue.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession hands protocols the body as a stream, not httpBody.
        private static func bodyData(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 16384
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    override func setUp() {
        super.setUp()
        StreamingMockURLProtocol.responseQueue = []
        StreamingMockURLProtocol.requestCount = 0
    }

    private func makeClient() -> AgentLLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingMockURLProtocol.self]
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "sk-test-key"
        return AgentLLMClient(config: config, session: URLSession(configuration: configuration))
    }

    func testThinkTagFilterSplitsTagsAcrossChunks() {
        var filter = ThinkTagStreamFilter()
        var content = ""
        var reasoning = ""
        for chunk in ["<th", "ink>let me ", "reason</thi", "nk>final ", "answer"] {
            let split = filter.feed(chunk)
            content += split.content
            reasoning += split.reasoning
        }
        let tail = filter.flush()
        content += tail.content
        reasoning += tail.reasoning
        XCTAssertEqual(content, "final answer")
        XCTAssertEqual(reasoning, "let me reason")
    }

    func testThinkTagExtractOnCompleteText() {
        let extracted = ThinkTagStreamFilter.extract(from: "<think>plan</think>hello")
        XCTAssertEqual(extracted.content, "hello")
        XCTAssertEqual(extracted.reasoning, "plan")

        let plain = ThinkTagStreamFilter.extract(from: "no tags here")
        XCTAssertEqual(plain.content, "no tags here")
        XCTAssertEqual(plain.reasoning, "")
    }

    func testStreamingChatAccumulatesReasoningContentAndToolCalls() async throws {
        StreamingMockURLProtocol.statusCode = 200
        StreamingMockURLProtocol.responseBody = Data("""
        data: {"choices":[{"delta":{"role":"assistant","reasoning_content":"think "}}]}

        data: {"choices":[{"delta":{"reasoning_content":"hard"}}]}

        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"do_thing","arguments":"{\\"a\\":"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}

        data: [DONE]

        """.utf8)

        var contentEvents = ""
        var reasoningEvents = ""
        let message = try await makeClient().chat(messages: [.user("hi")], tools: []) { event in
            switch event {
            case .contentDelta(let delta): contentEvents += delta
            case .reasoningDelta(let delta): reasoningEvents += delta
            }
        }

        XCTAssertEqual(message.content, "Hello")
        XCTAssertEqual(message.reasoningContent, "think hard")
        XCTAssertEqual(contentEvents, "Hello")
        XCTAssertEqual(reasoningEvents, "think hard")
        XCTAssertEqual(message.toolCalls?.count, 1)
        XCTAssertEqual(message.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(message.toolCalls?.first?.function.name, "do_thing")
        XCTAssertEqual(message.toolCalls?.first?.function.arguments, "{\"a\":1}")
    }

    func testStreamingChatRoutesInlineThinkTagsToReasoning() async throws {
        StreamingMockURLProtocol.statusCode = 200
        StreamingMockURLProtocol.responseBody = Data("""
        data: {"choices":[{"delta":{"content":"<think>plan the "}}]}

        data: {"choices":[{"delta":{"content":"reply</think>Hi there"}}]}

        data: [DONE]

        """.utf8)

        let message = try await makeClient().chat(messages: [.user("hi")], tools: []) { _ in }
        XCTAssertEqual(message.content, "Hi there")
        XCTAssertEqual(message.reasoningContent, "plan the reply")
    }

    func testNonStreamJSONFallbackStillReturnsMessage() async throws {
        StreamingMockURLProtocol.statusCode = 200
        StreamingMockURLProtocol.responseBody = Data("""
        {"choices":[{"message":{"role":"assistant","content":"<think>quick</think>plain reply"},"finish_reason":"stop"}]}
        """.utf8)

        var contentEvents = ""
        let message = try await makeClient().chat(messages: [.user("hi")], tools: []) { event in
            if case .contentDelta(let delta) = event { contentEvents += delta }
        }
        XCTAssertEqual(message.content, "plain reply")
        XCTAssertEqual(message.reasoningContent, "quick")
        XCTAssertEqual(contentEvents, "plain reply")
    }
}

extension AgentLLMStreamingTests {
    func testEmptyStreamBodyRetriesOnceThenSucceeds() async throws {
        StreamingMockURLProtocol.statusCode = 200
        StreamingMockURLProtocol.responseQueue = [
            Data(), // 网关瞬时故障：200 空体
            Data("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"好的\"},\"index\":0}]}\n\ndata: [DONE]\n".utf8)
        ]
        let message = try await makeClient().chat(messages: [.user("hi")], tools: []) { _ in }
        XCTAssertEqual(message.content, "好的")
        XCTAssertEqual(StreamingMockURLProtocol.requestCount, 2)
    }

    func testEmptyStreamBodyFailsAfterOneRetry() async {
        StreamingMockURLProtocol.statusCode = 200
        StreamingMockURLProtocol.responseQueue = [Data(), Data()]
        do {
            _ = try await makeClient().chat(messages: [.user("hi")], tools: []) { _ in }
            XCTFail("empty bodies must fail after one retry")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("空响应"), error.localizedDescription)
            XCTAssertEqual(StreamingMockURLProtocol.requestCount, 2)
        }
    }

    func testGatewayErrorJSONInsideHTTP200IsSurfaced() async {
        StreamingMockURLProtocol.statusCode = 200
        StreamingMockURLProtocol.responseBody = Data(#"{"detail":"No route for model gemini-3.5-flash"}"#.utf8)
        do {
            _ = try await makeClient().chat(messages: [.user("hi")], tools: []) { _ in }
            XCTFail("gateway error body must surface as an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No route for model"), error.localizedDescription)
        }
    }
}

extension AgentLLMStreamingTests {
    func testModelOverrideReplacesConfiguredModelInRequestBody() async throws {
        StreamingMockURLProtocol.statusCode = 200
        StreamingMockURLProtocol.responseBody = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"index\":0}]}\n\ndata: [DONE]\n".utf8)
        let client = makeClient()
        _ = try await client.chat(messages: [.user("hi")], tools: [], modelOverride: "claude-sonnet") { _ in }
        let body = try XCTUnwrap(StreamingMockURLProtocol.lastRequestBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-sonnet")

        _ = try await client.chat(messages: [.user("hi")], tools: [], modelOverride: "  ") { _ in }
        let body2 = try XCTUnwrap(StreamingMockURLProtocol.lastRequestBody)
        let object2 = try XCTUnwrap(JSONSerialization.jsonObject(with: body2) as? [String: Any])
        XCTAssertEqual(object2["model"] as? String, HerAppConfig.empty.agentLLMModel)
    }
}
