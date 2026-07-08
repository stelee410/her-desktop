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

    func testTTSConfigDefaultsAndNormalization() throws {
        // Legacy config decodes with Apple TTS defaults.
        let legacy = """
        {"agentLLMBaseURL":"https://agentllm.linkyun.co","agentLLMAPIKey":"k","agentLLMModel":"m",
         "agentMemBaseURL":"https://agentmem.oyii.ai","agentMemAPIKey":"","agentCode":"her-desktop",
         "userID":"u","pluginDirectory":".her/plugins"}
        """
        let config = try JSONDecoder().decode(HerAppConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.speechSynthesisProvider, "apple")
        XCTAssertEqual(config.agentLLMTTSModel, "doubao-tts")
        XCTAssertEqual(config.agentLLMTTSVoice, "zh_female_cancan_mars_bigtts")

        var draft = HerAppConfigDraft(config: .empty)
        draft.speechSynthesisProvider = "agentllm"
        draft.agentLLMTTSVoice = "  "
        draft.agentLLMTTSModel = ""
        let made = try draft.makeConfig()
        XCTAssertEqual(made.speechSynthesisProvider, "agentllm")
        XCTAssertEqual(made.agentLLMTTSModel, "doubao-tts")
        XCTAssertEqual(made.agentLLMTTSVoice, "zh_female_cancan_mars_bigtts")
    }

    func testViewModelRoutesSynthesizerByProvider() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-tts-routing-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "test-key"
        let model = AppViewModel(config: config, cwd: root.path)

        XCTAssertFalse(model.speechSynthesizer is AgentLLMSpeechSynthesizer)

        config.speechSynthesisProvider = "agentllm"
        model.applyConfiguration(config)
        XCTAssertTrue(model.speechSynthesizer is AgentLLMSpeechSynthesizer)

        config.speechSynthesisProvider = "apple"
        model.applyConfiguration(config)
        XCTAssertFalse(model.speechSynthesizer is AgentLLMSpeechSynthesizer)
    }

    func testVoiceCatalogParsesBareArrayAndWrappedShapes() {
        let bare = #"[{"id":"zh_female_cancan_mars_bigtts","label":"灿灿","gender":"female","pack":"mars","resource":"bigtts"}]"#
        let voices = AgentLLMVoiceCatalog.parse(Data(bare.utf8))
        XCTAssertEqual(voices.map(\.id), ["zh_female_cancan_mars_bigtts"])
        XCTAssertEqual(voices.first?.label, "灿灿")

        let wrapped = #"{"voices":[{"id":"v1","label":"","gender":"male"},{"label":"no-id"}]}"#
        let wrappedVoices = AgentLLMVoiceCatalog.parse(Data(wrapped.utf8))
        XCTAssertEqual(wrappedVoices.map(\.id), ["v1"])
        XCTAssertEqual(wrappedVoices.first?.label, "v1", "empty label falls back to the id")

        XCTAssertTrue(AgentLLMVoiceCatalog.parse(Data("not json".utf8)).isEmpty)
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
