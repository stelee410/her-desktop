import XCTest
@testable import HerDesktop

final class ConnectorLiveProtocolTests: XCTestCase {
    func testParsesUserInputWithAttachments() {
        let frame = """
        {"type":"USER_INPUT","data":{"line":"你好","attachments":[{"id":"1","name":"照片.jpg","mediaType":"image/jpeg","base64":"","size":10,"kind":"image","capturedAt":"t"}]}}
        """
        guard case .userInput(let line, let attachments)? = ConnectorLiveProtocol.parse(frame) else {
            return XCTFail("expected userInput")
        }
        XCTAssertEqual(line, "你好")
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].name, "照片.jpg")
        XCTAssertEqual(attachments[0].kind, "image")
    }

    func testParsesMicAudioAndUnknownTypes() {
        XCTAssertEqual(
            ConnectorLiveProtocol.parse(#"{"type":"MIC_AUDIO","data":{"audioBase64":"AA==","format":"wav"}}"#),
            .micAudio(format: "wav")
        )
        XCTAssertEqual(ConnectorLiveProtocol.parse(#"{"type":"WHATEVER"}"#), .other)
        XCTAssertNil(ConnectorLiveProtocol.parse("not json"))
    }

    func testAssistantStreamFrameShape() throws {
        let frame = ConnectorLiveProtocol.assistantStreamFrame(fullRaw: "累积的文本", done: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "ASSISTANT_STREAM")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["fullRaw"] as? String, "累积的文本")
        XCTAssertEqual(data["done"] as? Bool, true)
    }

    func testAttachmentDescriptionFoldsIntoOneLine() {
        let text = ConnectorLiveProtocol.describeAttachments([
            .init(name: "报告.pdf", mediaType: "application/pdf", kind: "document", text: nil),
            .init(name: "img.png", mediaType: "", kind: "image", text: "截图里的文字")
        ])
        XCTAssertTrue(text.contains("报告.pdf（application/pdf）"))
        XCTAssertTrue(text.contains("img.png（image）：截图里的文字"))
        XCTAssertEqual(ConnectorLiveProtocol.describeAttachments([]), "")
    }
}

@MainActor
final class ConnectorLiveServerTests: XCTestCase {
    func testUserInputRoundTripOverRealWebSocket() async throws {
        let server = ConnectorLiveServer()
        let port: UInt16 = 18788
        try server.start(port: port) { line, _, reply in
            reply("回声：\(line)", false)
            reply("回声：\(line)！", true)
        }
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        try await task.send(.string(#"{"type":"USER_INPUT","data":{"line":"你好"}}"#))

        var frames: [String] = []
        for _ in 0..<2 {
            if case .string(let text) = try await task.receive() {
                frames.append(text)
            }
        }
        task.cancel(with: .normalClosure, reason: nil)

        XCTAssertTrue(frames[0].contains("ASSISTANT_STREAM"))
        XCTAssertTrue(frames[0].contains("回声：你好"))
        XCTAssertTrue(frames[1].contains("\"done\":true") || frames[1].contains("\"done\" : true"))
    }

    func testMicAudioGetsPoliteDecline() async throws {
        let server = ConnectorLiveServer()
        let port: UInt16 = 18789
        try server.start(port: port) { _, _, _ in
            XCTFail("MIC_AUDIO must not reach the user-input handler")
        }
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        try await task.send(.string(#"{"type":"MIC_AUDIO","data":{"audioBase64":"AA==","format":"wav"}}"#))
        guard case .string(let text) = try await task.receive() else {
            return XCTFail("expected a text frame")
        }
        task.cancel(with: .normalClosure, reason: nil)
        XCTAssertTrue(text.contains("发文字给我吧"))
    }
}
