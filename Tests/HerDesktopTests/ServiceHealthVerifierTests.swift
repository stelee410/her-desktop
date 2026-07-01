import XCTest
@testable import HerDesktop

@MainActor
final class ServiceHealthVerifierTests: XCTestCase {
    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    func testInitialSnapshotReflectsConfiguredKeysAndPluginRuntime() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "test-llm-key"
        config.agentMemAPIKey = ""

        let verifier = ServiceHealthVerifier(config: config)
        let snapshot = verifier.initialSnapshot(pluginCount: 3)

        XCTAssertEqual(snapshot.first { $0.id == "agentllm" }?.state, .unknown)
        XCTAssertEqual(snapshot.first { $0.id == "agentmem" }?.state, .offline)
        XCTAssertEqual(snapshot.first { $0.id == "plugins" }?.state, .online)
        XCTAssertEqual(snapshot.first { $0.id == "plugins" }?.summary, "3 installed")
    }

    func testCheckAllWithMissingKeysDoesNotNeedNetwork() async {
        let verifier = ServiceHealthVerifier(config: .empty)
        let checked = await verifier.checkAll(pluginCount: 2)

        XCTAssertEqual(checked.first { $0.id == "agentllm" }?.state, .offline)
        XCTAssertEqual(checked.first { $0.id == "agentllm" }?.summary, "Missing key")
        XCTAssertEqual(checked.first { $0.id == "agentmem" }?.state, .offline)
        XCTAssertEqual(checked.first { $0.id == "agentmem" }?.summary, "Missing key")
        XCTAssertEqual(checked.first { $0.id == "plugins" }?.state, .online)
        XCTAssertEqual(checked.first { $0.id == "plugins" }?.summary, "2 installed")
    }

    func testAgentLLMHealthChecksChatDataPlane() async throws {
        var config = HerAppConfig.empty
        config.agentLLMBaseURL = URL(string: "https://agentllm.test")!
        config.agentLLMAPIKey = "llm_test"
        config.agentLLMModel = "test-model"

        var requests: [String] = []
        let verifier = ServiceHealthVerifier(config: config, session: mockSession { request in
            requests.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            if request.url?.path == "/health" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("ready".utf8))
            }

            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.timeoutInterval, 12)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer llm_test")
            let body = try XCTUnwrap(Self.bodyObject(from: request))
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["max_tokens"] as? Int, 4)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8))
        })

        let checked = await verifier.checkAll(pluginCount: 2)
        let agentLLM = try XCTUnwrap(checked.first { $0.id == "agentllm" })

        XCTAssertEqual(agentLLM.state, .online)
        XCTAssertEqual(agentLLM.summary, "ready · Chat OK")
        XCTAssertEqual(requests, ["GET /health", "POST /v1/chat/completions"])
    }

    func testAgentMemHealthChecksScopedQueryDataPlane() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her-desktop"
        config.userID = "stelee"

        var requests: [String] = []
        let verifier = ServiceHealthVerifier(config: config, session: mockSession { request in
            requests.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            if request.url?.path == "/v1/me" {
                XCTAssertEqual(request.timeoutInterval, 12)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Agent-API-Key"), "mem_test")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"known":true,"display_name":"her","memory_id":"mem_123"}"#.utf8))
            }

            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/memory/query")
            XCTAssertEqual(request.timeoutInterval, 12)
            let body = try XCTUnwrap(Self.bodyObject(from: request))
            XCTAssertEqual(body["agent_code"] as? String, "her-desktop")
            XCTAssertEqual(body["user_id"] as? String, "stelee")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"injected_context":"","retrieved_memories":[],"timing_ms":3.1}"#.utf8))
        })

        let checked = await verifier.checkAll(pluginCount: 4)
        let agentMem = try XCTUnwrap(checked.first { $0.id == "agentmem" })

        XCTAssertEqual(agentMem.state, .online)
        XCTAssertEqual(agentMem.summary, "her · true · Scoped query OK")
        XCTAssertEqual(requests, ["GET /v1/me", "POST /v1/memory/query"])
    }

    func testAgentMemHealthRetriesLegacyQueryWhenScopedFieldsAreRejected() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her-desktop"
        config.userID = "stelee"

        var queryAttempt = 0
        let verifier = ServiceHealthVerifier(config: config, session: mockSession { request in
            if request.url?.path == "/v1/me" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"known":true,"display_name":"her"}"#.utf8))
            }

            queryAttempt += 1
            let body = try XCTUnwrap(Self.bodyObject(from: request))
            if queryAttempt == 1 {
                XCTAssertEqual(body["agent_code"] as? String, "her-desktop")
                XCTAssertEqual(body["user_id"] as? String, "stelee")
                let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"detail":[{"type":"extra_forbidden","loc":["body","agent_code"]},{"type":"extra_forbidden","loc":["body","user_id"]}]}"#.utf8))
            }

            XCTAssertNil(body["agent_code"])
            XCTAssertNil(body["user_id"])
            XCTAssertEqual(body["session_id"] as? String, "her-desktop-health")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"injected_context":"","retrieved_memories":[],"timing_ms":4.2}"#.utf8))
        })

        let checked = await verifier.checkAll(pluginCount: 4)
        let agentMem = try XCTUnwrap(checked.first { $0.id == "agentmem" })

        XCTAssertEqual(agentMem.state, .online)
        XCTAssertEqual(agentMem.summary, "her · true · Legacy query OK")
        XCTAssertEqual(queryAttempt, 2)
    }

    private func mockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyObject(from request: URLRequest) throws -> [String: Any]? {
        guard let data = bodyData(from: request) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}
