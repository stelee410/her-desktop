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
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Agent-API-Key"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertNil(object?["agent_code"])
            XCTAssertNil(object?["user_id"])
            XCTAssertEqual(object?["session_id"] as? String, "session-1")
            XCTAssertEqual(object?["user_input"] as? String, "hello")
            XCTAssertEqual(object?["agent_response"] as? String, "hi")
            let metadata = object?["metadata"] as? [String: Any]
            XCTAssertEqual(metadata?["surface"] as? String, "mac")

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

    func testAddSummaryUsesAgentMemV7SummarySchema() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://agentmem.test/v1/memory/add")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["session_id"] as? String, "session-summary")
            XCTAssertEqual(object?["summary"] as? String, "User prefers concise architecture critique.")
            XCTAssertNil(object?["user_input"])
            XCTAssertNil(object?["agent_response"])
            XCTAssertNil(object?["agent_code"])
            XCTAssertNil(object?["user_id"])
            let metadata = object?["metadata"] as? [String: Any]
            XCTAssertEqual(metadata?["writeback_mode"] as? String, "summary")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"queued","task_id":"task-summary"}"#.utf8))
        }
        let client = AgentMemClient(config: config, session: session)

        let response = try await client.addSummary(
            "User prefers concise architecture critique.",
            sessionID: "session-summary",
            metadata: ["writeback_mode": "summary"]
        )

        XCTAssertEqual(response.taskID, "task-summary")
    }

    func testTaskStatusUsesMemoryKeyTaskEndpoint() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://agentmem.test/v1/tasks/task_123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Agent-API-Key"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (
                response,
                Data(#"{"task_id":"task_123","task_type":"memory_add","status":"succeeded","created_at":"2026-07-01T00:00:00Z","started_at":"2026-07-01T00:00:01Z","finished_at":"2026-07-01T00:00:02Z","result":{"facts_added":2,"timings_ms":{"total_ms":42.5}},"duration_ms":1000.0}"#.utf8)
            )
        }
        let client = AgentMemClient(config: config, session: session)

        let status = try await client.taskStatus(taskID: "task_123")

        XCTAssertEqual(status.taskID, "task_123")
        XCTAssertEqual(status.taskType, "memory_add")
        XCTAssertEqual(status.status, "succeeded")
        XCTAssertEqual(status.durationMs, 1000.0)
        XCTAssertEqual(status.result?["facts_added"], .number(2))
        XCTAssertTrue(status.isTerminal)
    }

    func testWaitForTaskStatusPollsUntilTerminalStatus() async throws {
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test"

        var attempt = 0
        let session = mockSession { request in
            attempt += 1
            XCTAssertEqual(request.url?.path, "/v1/tasks/task_poll")
            let status = attempt == 1 ? "processing" : "succeeded"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (
                response,
                Data(#"{"task_id":"task_poll","task_type":"memory_add","status":"\#(status)","created_at":"2026-07-01T00:00:00Z"}"#.utf8)
            )
        }
        let client = AgentMemClient(config: config, session: session)

        let status = try await client.waitForTaskStatus(
            taskID: "task_poll",
            maxAttempts: 3,
            delayNanoseconds: 1_000
        )

        XCTAssertEqual(status.status, "succeeded")
        XCTAssertEqual(attempt, 2)
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
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Agent-API-Key"))

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

    func testQueryDoesNotFallbackToScopedPayloadWhenAgentMemRejectsMissingUserID() async throws {
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
            XCTFail("AgentMem V7 data-plane calls must not retry with user_id or agent_code.")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = AgentMemClient(config: config, session: session)

        do {
            _ = try await client.query("architecture", sessionID: "session-legacy", topK: 2)
            XCTFail("Expected query to surface the V7 validation error.")
        } catch ServiceError.httpStatus(let status, let body) {
            XCTAssertEqual(status, 422)
            XCTAssertTrue(body.contains("user_id"))
        }

        XCTAssertEqual(attempt, 1)
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
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Agent-API-Key"))

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

    func testAddDoesNotFallbackToScopedPayloadWhenAgentMemRejectsMissingUserID() async throws {
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
            XCTFail("AgentMem V7 data-plane calls must not retry with user_id or agent_code.")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = AgentMemClient(config: config, session: session)

        do {
            _ = try await client.add(
                userInput: "hello",
                agentResponse: "hi",
                sessionID: "session-legacy",
                metadata: ["surface": "mac"]
            )
            XCTFail("Expected add to surface the V7 validation error.")
        } catch ServiceError.httpStatus(let status, let body) {
            XCTAssertEqual(status, 422)
            XCTAssertTrue(body.contains("user_id"))
        }

        XCTAssertEqual(attempt, 1)
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
