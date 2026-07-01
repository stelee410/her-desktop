import XCTest
@testable import HerDesktop

@MainActor
final class AgentMemClientTests: XCTestCase {
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

    func testAddWritesTurnToAgentMemSchema() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her"
        config.userID = "tester"

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://agentmem.test/v1/memory/add")
            XCTAssertEqual(request.timeoutInterval, 12)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Agent-API-Key"), "mem_test")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertNil(object?["agent_code"])
            XCTAssertNil(object?["user_id"])
            XCTAssertEqual(object?["session_id"] as? String, "session-1")
            XCTAssertEqual(object?["user_input"] as? String, "hello")
            XCTAssertEqual(object?["agent_response"] as? String, "hi")
            XCTAssertNil(object?["metadata"])

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"status":"queued","task_id":"task-1"}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.add(
            userInput: "hello",
            agentResponse: "hi",
            sessionID: "session-1",
            metadata: ["surface": "mac"]
        )

        XCTAssertEqual(response.status, "queued")
        XCTAssertEqual(response.taskID, "task-1")
    }

    func testQueryReadsKeyBoundMemoryContext() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her-desktop"
        config.userID = "stelee"

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://agentmem.test/v1/memory/query")
            XCTAssertEqual(request.timeoutInterval, 12)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Agent-API-Key"), "mem_test")

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertNil(object?["agent_code"])
            XCTAssertNil(object?["user_id"])
            XCTAssertEqual(object?["session_id"] as? String, "session-2")
            XCTAssertEqual(object?["query"] as? String, "architecture")
            XCTAssertEqual(object?["top_k"] as? Int, 3)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"injected_context":"User likes direct critique.","retrieved_memories":[{"fact":"direct critique","score":0.82,"layer":"fact"}],"timing_ms":4.2}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.query("architecture", sessionID: "session-2", topK: 3)

        XCTAssertEqual(response.injectedContext, "User likes direct critique.")
        XCTAssertEqual(response.retrievedMemories.first?.fact, "direct critique")
        XCTAssertEqual(response.timingMs, 4.2)
    }

    func testQueryFallsBackToScopedPayloadWhenDevAgentMemRequiresUserID() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her-desktop"
        config.userID = "stelee"

        var attempt = 0
        let session = mockSession { request in
            attempt += 1
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            if attempt == 1 {
                XCTAssertNil(object?["agent_code"])
                XCTAssertNil(object?["user_id"])
                let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"detail":[{"type":"missing","loc":["body","user_id"],"msg":"Field required"}]}"#.utf8))
            }
            XCTAssertEqual(object?["agent_code"] as? String, "her-desktop")
            XCTAssertEqual(object?["user_id"] as? String, "stelee")
            XCTAssertEqual(object?["session_id"] as? String, "session-legacy")
            XCTAssertEqual(object?["query"] as? String, "architecture")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"injected_context":"legacy context","retrieved_memories":[],"timing_ms":9.1}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.query("architecture", sessionID: "session-legacy", topK: 2)

        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(response.injectedContext, "legacy context")
    }

    func testRelationshipUsesMemoryKeyBoundRelationshipEndpoint() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her-desktop"
        config.userID = "stelee"

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/memory/relationship")
            XCTAssertEqual(request.timeoutInterval, 12)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Agent-API-Key"), "mem_test")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"user_id":"stelee","stage":"companion","bond":{"trust":1.5,"familiarity":2.25,"affection":3.0}}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.relationship()

        XCTAssertEqual(response["user_id"] as? String, "stelee")
        XCTAssertEqual(response["stage"] as? String, "companion")
    }

    func testEmotionUsesMemoryKeyBoundEmotionEndpoint() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/memory/emotion")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"memory_id":"mem_123","mood":{"label":"焦虑警觉","mean_valence":-1.8,"mean_arousal":6.4},"state":{"current":"Anxiety","label":"焦虑"}}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.emotion()

        let mood = response["mood"] as? [String: Any]
        XCTAssertEqual(mood?["label"] as? String, "焦虑警觉")
    }

    func testAddFallsBackToScopedPayloadWhenDevAgentMemRequiresUserID() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her-desktop"
        config.userID = "stelee"

        var attempt = 0
        let session = mockSession { request in
            attempt += 1
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            if attempt == 1 {
                XCTAssertNil(object?["agent_code"])
                XCTAssertNil(object?["user_id"])
                let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"detail":[{"type":"missing","loc":["body","user_id"],"msg":"Field required"}]}"#.utf8))
            }
            XCTAssertEqual(object?["agent_code"] as? String, "her-desktop")
            XCTAssertEqual(object?["user_id"] as? String, "stelee")
            XCTAssertEqual(object?["session_id"] as? String, "session-legacy")
            let metadata = object?["metadata"] as? [String: Any]
            XCTAssertEqual(metadata?["surface"] as? String, "mac")
            XCTAssertEqual(object?["user_input"] as? String, "hello")
            XCTAssertEqual(object?["agent_response"] as? String, "hi")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"queued","task_id":"legacy-task"}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.add(
            userInput: "hello",
            agentResponse: "hi",
            sessionID: "session-legacy",
            metadata: ["surface": "mac"]
        )

        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(response.taskID, "legacy-task")
    }

    func testRelationshipFallsBackToIdentityForLegacyAgentMem() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"
        config.agentCode = "her-desktop"
        config.userID = "stelee"

        var paths: [String] = []
        let session = mockSession { request in
            paths.append(request.url?.path ?? "")
            if request.url?.path == "/v1/memory/relationship" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"detail":"not found"}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/v1/me")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"known":true,"display_name":"her","memory_id":"mem_123"}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.relationship()

        XCTAssertEqual(paths, ["/v1/memory/relationship", "/v1/me"])
        XCTAssertEqual(response["display_name"] as? String, "her")
        XCTAssertEqual(response["memory_id"] as? String, "mem_123")
    }

    private func mockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
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
