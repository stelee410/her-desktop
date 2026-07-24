import XCTest
@testable import HerDesktop

final class SettingsPortabilityTests: XCTestCase {
    private func sampleConfig() -> HerAppConfig {
        HerAppConfig(
            agentLLMBaseURL: URL(string: "https://llm.example.com")!,
            agentLLMAPIKey: "llm-secret",
            agentLLMModel: "linkyun-smart",
            agentMemBaseURL: URL(string: "https://mem.example.com")!,
            agentMemAPIKey: "mem-secret",
            agentCode: "her-desktop",
            userID: "stelee",
            pluginDirectory: ".her/plugins",
            telegramConnectorEnabled: true,
            telegramBotToken: "123:ABC"
        )
    }

    func testExportThenImportRoundTrips() throws {
        let config = sampleConfig()
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try SettingsPortability.exportData(config: config, exportedAt: fixedDate)
        let restored = try SettingsPortability.importConfig(from: data)
        XCTAssertEqual(restored, config)
    }

    func testExportedDocumentCarriesEnvelopeMetadata() throws {
        let data = try SettingsPortability.exportData(
            config: sampleConfig(),
            exportedAt: Date(timeIntervalSince1970: 0),
            appVersion: "9.9.9"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "her-desktop-settings")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["appVersion"] as? String, "9.9.9")
        XCTAssertNotNil(object["config"])
    }

    func testImportAcceptsBareConfigJSON() throws {
        // Someone copies their local config.json (no envelope) — still importable.
        let bare = try JSONEncoder().encode(sampleConfig())
        let restored = try SettingsPortability.importConfig(from: bare)
        XCTAssertEqual(restored.agentLLMAPIKey, "llm-secret")
    }

    func testImportRejectsUnrelatedJSON() {
        XCTAssertThrowsError(try SettingsPortability.importConfig(from: Data(#"{"hello":"world"}"#.utf8)))
        XCTAssertThrowsError(try SettingsPortability.importConfig(from: Data("{}".utf8)))
        XCTAssertThrowsError(try SettingsPortability.importConfig(from: Data("not json".utf8)))
    }

    func testImportRejectsNewerVersion() throws {
        var object: [String: Any] = [
            "type": "her-desktop-settings",
            "version": 999,
            "exportedAt": "2026-01-01T00:00:00Z",
            "appVersion": "99.0.0"
        ]
        object["config"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleConfig()))
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try SettingsPortability.importConfig(from: data)) { error in
            guard case SettingsPortability.PortabilityError.tooNew(let v) = error else {
                return XCTFail("expected tooNew, got \(error)")
            }
            XCTAssertEqual(v, 999)
        }
    }

    func testSuggestedFilenameUsesDate() {
        let name = SettingsPortability.suggestedFilename(for: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(name.hasPrefix("Her-Settings-"))
        XCTAssertTrue(name.hasSuffix(".json"))
    }
}
