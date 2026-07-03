import XCTest
@testable import HerDesktop

@MainActor
final class AgentLLMStreamingTests: XCTestCase {
    final class StreamingMockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responseBody: Data = Data()
        nonisolated(unsafe) static var statusCode: Int = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
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
