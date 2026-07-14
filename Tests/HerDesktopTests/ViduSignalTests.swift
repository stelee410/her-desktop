import XCTest
@testable import HerDesktop

final class ViduSignalTests: XCTestCase {
    func testAuthorizationHeaderAddsTokenPrefixOnce() {
        XCTAssertEqual(ViduSignal.authorizationHeader(apiKey: "vda_abc"), "Token vda_abc")
        XCTAssertEqual(ViduSignal.authorizationHeader(apiKey: "Token vda_abc"), "Token vda_abc")
        XCTAssertEqual(ViduSignal.authorizationHeader(apiKey: "  vda_abc \n"), "Token vda_abc")
    }

    func testCreateLiveBodyOmitsEmptyOptionalFields() throws {
        let data = try ViduSignal.createLiveBody(
            callMode: "video",
            persona: "你是小美",
            imageURI: "https://example.com/a.png",
            name: "",
            voice: ""
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["call_mode"] as? String, "video")
        let avatar = try XCTUnwrap(object["avatar"] as? [String: Any])
        XCTAssertEqual(avatar["persona"] as? String, "你是小美")
        XCTAssertNil(avatar["name"])
        XCTAssertNil(avatar["voice"])
    }

    func testParseCreateLiveResponse() throws {
        let json = """
        {
          "live": {"id": "123456789", "status": "waiting", "live_duration": 600, "call_mode": "video"},
          "rtc": {"app_id": "app", "channel_id": "live-user-123456789",
                  "user_id": "live-user-1001-123456789", "token": "base64-token",
                  "token_expire_at": "1750003600"}
        }
        """
        let result = try XCTUnwrap(ViduSignal.parseCreateLiveResponse(Data(json.utf8)))
        XCTAssertEqual(result.live.id, "123456789")
        XCTAssertEqual(result.live.liveDurationSeconds, 600)
        XCTAssertEqual(result.rtc.userID, "live-user-1001-123456789")
        XCTAssertEqual(result.rtc.token, "base64-token")
    }

    func testParseCreateLiveResponseToleratesNumericLiveID() throws {
        let json = #"{"live": {"id": 42}, "rtc": {"token": "t"}}"#
        let result = try XCTUnwrap(ViduSignal.parseCreateLiveResponse(Data(json.utf8)))
        XCTAssertEqual(result.live.id, "42")
        XCTAssertEqual(result.live.liveDurationSeconds, 600)
    }

    func testParseCreateLiveResponseRejectsMissingToken() {
        let json = #"{"live": {"id": "1"}, "rtc": {"app_id": "a"}}"#
        XCTAssertNil(ViduSignal.parseCreateLiveResponse(Data(json.utf8)))
    }

    func testConnInitMessageShape() throws {
        let text = ViduSignal.connInitMessage(liveID: "99", seqID: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? Int, 1)
        XCTAssertEqual(object["live_id"] as? String, "99")
        XCTAssertEqual(object["seq_id"] as? Int, 1)
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let connInit = try XCTUnwrap(payload["conn_init"] as? [String: Any])
        XCTAssertEqual(connInit["version"] as? Int, 1)
    }

    func testHangupMessageShape() throws {
        let text = ViduSignal.hangupMessage(liveID: "99", seqID: 2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? Int, 5)
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let hangup = try XCTUnwrap(payload["hangup"] as? [String: Any])
        XCTAssertEqual(hangup["hangup_reason"] as? String, "user_end")
    }

    func testParseServerEventAckVariants() {
        XCTAssertEqual(
            ViduSignal.parseServerEvent(#"{"type":2,"payload":{"conn_init_ack":{"success":true}}}"#),
            .connInitAck(success: true, errorCode: nil)
        )
        XCTAssertEqual(
            ViduSignal.parseServerEvent(#"{"type":2,"payload":{"conn_init_ack":{"success":false,"error_code":"NOT_READY"}}}"#),
            .connInitAck(success: false, errorCode: "NOT_READY")
        )
    }

    func testParseServerEventHangupAndUnknown() {
        XCTAssertEqual(
            ViduSignal.parseServerEvent(#"{"type":6,"payload":{"hangup":{"hangup_reason":"timeout"}}}"#),
            .hangup(reason: "timeout")
        )
        XCTAssertEqual(ViduSignal.parseServerEvent(#"{"type":42}"#), .other)
        XCTAssertNil(ViduSignal.parseServerEvent("not-json"))
    }

    func testConfigDecodesLegacyFileWithoutViduSettings() throws {
        let json = """
        {
          "agentLLMBaseURL": "https://agentllm.linkyun.co",
          "agentLLMAPIKey": "k",
          "agentLLMModel": "m",
          "agentMemBaseURL": "https://agentmem.oyii.ai",
          "agentMemAPIKey": "",
          "agentCode": "her-desktop",
          "userID": "u",
          "pluginDirectory": ".her/plugins"
        }
        """
        let config = try JSONDecoder().decode(HerAppConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.hasViduKey)
        XCTAssertEqual(config.viduHost, "api.vidu.cn")
        XCTAssertEqual(config.viduCallMode, "video")
    }

    func testDraftCarriesViduSettingsAndNormalizesHost() throws {
        var draft = HerAppConfigDraft(config: .empty)
        draft.viduAPIKey = " vda_key "
        draft.viduHost = "https://api.vidu.com/some/path"
        draft.viduCallMode = "audio"
        draft.viduAvatarImageURI = "https://example.com/she.png"
        let config = try draft.makeConfig()
        XCTAssertEqual(config.viduAPIKey, "vda_key")
        XCTAssertEqual(config.viduHost, "api.vidu.com")
        XCTAssertEqual(config.viduCallMode, "audio")
        XCTAssertTrue(config.hasViduKey)
    }

    func testAvatarEncoderBuildsDataURIForSmallImages() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let uri = try ViduAvatarImageEncoder.dataURI(data: bytes, mimeType: "image/png")
        XCTAssertEqual(uri, "data:image/png;base64,\(bytes.base64EncodedString())")
    }

    func testAvatarEncoderMimeTypes() {
        XCTAssertEqual(ViduAvatarImageEncoder.mimeType(forPathExtension: "PNG"), "image/png")
        XCTAssertEqual(ViduAvatarImageEncoder.mimeType(forPathExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(ViduAvatarImageEncoder.mimeType(forPathExtension: "webp"), "image/webp")
        XCTAssertNil(ViduAvatarImageEncoder.mimeType(forPathExtension: "gif"))
    }

    func testAvatarEncoderRejectsOversizedGarbage() {
        // 超过 20MB 且无法按图片重编码 → 必须报错而不是把超限 payload 发出去。
        let oversized = Data(count: ViduAvatarImageEncoder.maxDecodedBytes + 1)
        XCTAssertThrowsError(try ViduAvatarImageEncoder.dataURI(data: oversized, mimeType: "image/png"))
    }

    func testJoinPayloadIsValidJSON() throws {
        let payload = CallWebViewJoinPayloadProbe.payload(
            rtc: ViduRTCCredentials(appID: "a", channelID: "c", userID: "u", token: "t"),
            callMode: "audio",
            avatarImageURI: "https://example.com/i.png"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String])
        XCTAssertEqual(object["token"], "t")
        XCTAssertEqual(object["avatar"], "https://example.com/i.png")
    }
}
