import XCTest
@testable import HerDesktop

final class TelegramAPITests: XCTestCase {
    func testParseUpdatesExtractsTextMessagesAndOffset() {
        let json = """
        {"ok":true,"result":[
          {"update_id":100,"message":{"message_id":1,"chat":{"id":555,"type":"private"},"from":{"first_name":"石头","username":"stelee"},"text":"你好","date":1}},
          {"update_id":101,"message":{"message_id":2,"chat":{"id":555,"type":"private"},"from":{"username":"stelee"},"text":"","date":2}},
          {"update_id":102,"edited_message":{"text":"忽略我"}}
        ]}
        """
        let (messages, nextOffset) = TelegramAPI.parseUpdates(Data(json.utf8))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].chatID, 555)
        XCTAssertEqual(messages[0].text, "你好")
        XCTAssertEqual(messages[0].senderName, "石头")
        XCTAssertEqual(nextOffset, 103) // max update_id 102 + 1
    }

    func testParseUpdatesHandlesEmptyAndBad() {
        XCTAssertEqual(TelegramAPI.parseUpdates(Data(#"{"ok":true,"result":[]}"#.utf8)).nextOffset, nil)
        XCTAssertEqual(TelegramAPI.parseUpdates(Data("not json".utf8)).messages.count, 0)
        XCTAssertEqual(TelegramAPI.parseUpdates(Data(#"{"ok":false}"#.utf8)).messages.count, 0)
    }

    func testSendMessageBodyClipsLongText() throws {
        let long = String(repeating: "字", count: 5000)
        let body = TelegramAPI.sendMessageBody(chatID: 42, text: long)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["chat_id"] as? Int, 42)
        let text = try XCTUnwrap(object["text"] as? String)
        XCTAssertLessThanOrEqual(text.count, 4001)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testParseBotUsername() {
        let json = #"{"ok":true,"result":{"id":1,"is_bot":true,"first_name":"Her","username":"her_companion_bot"}}"#
        XCTAssertEqual(TelegramAPI.parseBotUsername(Data(json.utf8)), "her_companion_bot")
        XCTAssertNil(TelegramAPI.parseBotUsername(Data(#"{"ok":false}"#.utf8)))
    }

    func testParseAllowedChatIDs() {
        XCTAssertEqual(TelegramAPI.parseAllowedChatIDs("555, 666  777"), Set([555, 666, 777]))
        XCTAssertTrue(TelegramAPI.parseAllowedChatIDs("").isEmpty)
        XCTAssertEqual(TelegramAPI.parseAllowedChatIDs("abc, 42"), Set([42]))
    }

    func testConfigDecodesLegacyWithoutTelegram() throws {
        let json = """
        {"agentLLMBaseURL":"https://a.co","agentLLMAPIKey":"k","agentLLMModel":"m",
         "agentMemBaseURL":"https://b.co","agentMemAPIKey":"","agentCode":"c","userID":"u","pluginDirectory":".her/plugins"}
        """
        let config = try JSONDecoder().decode(HerAppConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.telegramConnectorEnabled)
        XCTAssertEqual(config.telegramBotToken, "")
    }
}
