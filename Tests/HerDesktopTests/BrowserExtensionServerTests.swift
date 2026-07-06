import XCTest
@testable import HerDesktop

final class BrowserExtensionServerTests: XCTestCase {
    func testEnqueuePollResultRoundTrip() async throws {
        let server = BrowserExtensionServer(token: "tok")

        // Enqueue a command; a background poller plays the extension.
        async let resultData = server.enqueue(
            action: "navigate",
            paramsJSON: Data(#"{"url":"example.com"}"#.utf8)
        )

        // The extension polls for the next command.
        var command: [String: Any] = [:]
        for _ in 0..<50 {
            let next = server.handle(method: "GET", path: "/ext/next", query: ["token": "tok"], body: [:])
            if let cmd = next.json["command"] as? [String: Any] {
                command = cmd
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(command["action"] as? String, "navigate")
        let params = command["params"] as? [String: Any]
        XCTAssertEqual(params?["url"] as? String, "example.com")
        let id = try XCTUnwrap(command["id"] as? String)

        // The extension posts the result back.
        let post = server.handle(method: "POST", path: "/ext/result", query: ["token": "tok"],
                                 body: ["id": id, "ok": true, "url": "https://example.com/", "title": "Example"])
        XCTAssertEqual(post.json["ok"] as? Bool, true)

        let data = try await resultData
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Example")
        XCTAssertEqual(object["url"] as? String, "https://example.com/")
    }

    func testInvalidTokenRejected() {
        let server = BrowserExtensionServer(token: "secret")
        let response = server.handle(method: "GET", path: "/ext/next", query: ["token": "wrong"], body: [:])
        XCTAssertEqual(response.status, 401)
    }

    func testHelloMarksConnected() {
        let server = BrowserExtensionServer(token: "t")
        XCTAssertFalse(server.isExtensionConnected)
        _ = server.handle(method: "POST", path: "/ext/hello", query: ["token": "t"], body: [:])
        XCTAssertTrue(server.isExtensionConnected)
    }

    @MainActor
    func testExtensionBridgeReadParsesResult() async throws {
        let server = BrowserExtensionServer(token: "t")
        _ = server.handle(method: "POST", path: "/ext/hello", query: ["token": "t"], body: [:])
        let bridge = ExtensionBrowserBridge(server: server)

        async let read = bridge.read()

        // Play the extension: deliver a page read result.
        var id = ""
        for _ in 0..<50 {
            let next = server.handle(method: "GET", path: "/ext/next", query: ["token": "t"], body: [:])
            if let cmd = next.json["command"] as? [String: Any], let cid = cmd["id"] as? String {
                id = cid; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(id.isEmpty)
        _ = server.handle(method: "POST", path: "/ext/result", query: ["token": "t"], body: [
            "id": id, "ok": true, "url": "https://x.com/", "title": "X",
            "text": "body text",
            "elements": [["index": 0, "tag": "button", "type": "", "label": "Go"]]
        ])

        let result = try await read
        XCTAssertEqual(result.title, "X")
        XCTAssertEqual(result.text, "body text")
        XCTAssertEqual(result.elements.first?.label, "Go")
    }

    func testEnqueueTimesOutWithoutExtension() async {
        let server = BrowserExtensionServer(token: "t")
        do {
            _ = try await server.enqueue(action: "read", paramsJSON: Data("{}".utf8), timeout: 0.3)
            XCTFail("should time out")
        } catch {
            XCTAssertTrue(error is BrowserExtensionServer.BridgeError)
        }
    }
}
