import XCTest
@testable import HerDesktop

final class LocalInboxBridgeTests: XCTestCase {
    func testParserAcceptsInboxPostJSONAliases() throws {
        let request = """
        POST /inbox HTTP/1.1\r
        Host: 127.0.0.1:8766\r
        Content-Type: application/json\r
        Content-Length: 99\r
        \r
        {"platform":"oyii","from":"Leo","message":"Look at this","link":"https://example.com/t/1"}
        """

        let message = try LocalInboxBridgeRequestParser.parse(Data(request.utf8))

        XCTAssertEqual(message.source, "oyii")
        XCTAssertEqual(message.sender, "Leo")
        XCTAssertEqual(message.text, "Look at this")
        XCTAssertEqual(message.url, "https://example.com/t/1")
    }

    func testParserRejectsUnsupportedMethodAndPath() {
        let getRequest = """
        GET /inbox HTTP/1.1\r
        Host: 127.0.0.1\r
        \r

        """
        XCTAssertThrowsError(try LocalInboxBridgeRequestParser.parse(Data(getRequest.utf8))) { error in
            XCTAssertEqual(error as? LocalInboxBridgeRequestParser.ParseError, .unsupportedMethod("GET"))
        }

        let wrongPath = """
        POST /other HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        {"text":"hello"}
        """
        XCTAssertThrowsError(try LocalInboxBridgeRequestParser.parse(Data(wrongPath.utf8))) { error in
            XCTAssertEqual(error as? LocalInboxBridgeRequestParser.ParseError, .unsupportedPath("/other"))
        }
    }

    @MainActor
    func testViewModelCapturesMessagePostedToLocalInboxBridge() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-local-inbox-bridge-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("workspace", isDirectory: true)
        let model = AppViewModel(cwd: cwd.path)
        let port = UInt16(Int.random(in: 20_000...50_000))

        model.startLocalInboxBridge(port: port)
        defer { model.stopLocalInboxBridge() }
        XCTAssertEqual(model.localInboxBridgeState.status, .running)

        try await Task.sleep(nanoseconds: 150_000_000)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inbox")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"source":"oyii","sender":"Leo","text":"Please review the inbox bridge."}"#.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        try await waitUntil {
            model.interactionEvents.contains { $0.kind == .externalInboxCaptured }
        }

        let event = try XCTUnwrap(model.interactionEvents.first { $0.kind == .externalInboxCaptured })
        XCTAssertEqual(event.surface, .externalInbox)
        XCTAssertEqual(event.payload["source"], "oyii")
        XCTAssertEqual(event.payload["sender"], "Leo")
        XCTAssertTrue(event.summary.contains("Please review the inbox bridge."))
        XCTAssertTrue(model.messages.contains { $0.content.contains("Inbox Event Captured") })
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_500_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
