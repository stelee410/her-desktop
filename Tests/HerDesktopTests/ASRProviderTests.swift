import XCTest
@testable import HerDesktop

@MainActor
final class ASRProviderTests: XCTestCase {
    func testConfigDefaultsToAppleAndDecodesLegacyFiles() throws {
        // A config file written before the ASR option existed decodes with
        // the Apple default — no migration needed.
        let legacy = """
        {"agentLLMBaseURL":"https://agentllm.linkyun.co","agentLLMAPIKey":"k","agentLLMModel":"m",
         "agentMemBaseURL":"https://agentmem.oyii.ai","agentMemAPIKey":"","agentCode":"her-desktop",
         "userID":"u","pluginDirectory":".her/plugins"}
        """
        let config = try JSONDecoder().decode(HerAppConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.speechRecognitionProvider, "apple")
        XCTAssertEqual(config.agentLLMASRModel, "whisper-1")
    }

    func testDraftNormalizesProviderAndModel() throws {
        var draft = HerAppConfigDraft(config: .empty)
        draft.speechRecognitionProvider = "agentllm"
        draft.agentLLMASRModel = "   "
        let config = try draft.makeConfig()
        XCTAssertEqual(config.speechRecognitionProvider, "agentllm")
        XCTAssertEqual(config.agentLLMASRModel, "whisper-1", "blank model falls back to the default")

        draft.speechRecognitionProvider = "something-weird"
        XCTAssertEqual(try draft.makeConfig().speechRecognitionProvider, "apple",
                       "unknown providers normalize to the system recognizer")
    }

    func testViewModelRoutesDictationByProvider() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-asr-routing-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "test-key"
        let model = AppViewModel(config: config, cwd: root.path)

        XCTAssertFalse(model.speechDictation is AgentLLMDictationService,
                       "apple provider uses the injected/system dictation")

        config.speechRecognitionProvider = "agentllm"
        model.applyConfiguration(config)
        XCTAssertTrue(model.speechDictation is AgentLLMDictationService,
                      "agentllm provider routes to the server-side service")

        config.speechRecognitionProvider = "apple"
        model.applyConfiguration(config)
        XCTAssertFalse(model.speechDictation is AgentLLMDictationService)
    }
}
