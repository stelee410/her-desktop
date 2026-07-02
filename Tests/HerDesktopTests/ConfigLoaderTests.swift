import XCTest
@testable import HerDesktop

final class ConfigLoaderTests: XCTestCase {
    private let serviceEnvKeys = [
        "HER_AGENT_LLM_BASE_URL",
        "AGENTLLM_BASE_URL",
        "AGENT_LLM_BASE_URL",
        "HER_AGENT_LLM_API_KEY",
        "AGENTLLM_API_KEY",
        "AGENT_LLM_API_KEY",
        "HER_AGENT_LLM_MODEL",
        "AGENTLLM_MODEL",
        "AGENT_LLM_MODEL",
        "HER_AGENT_MEM_BASE_URL",
        "AGENTMEM_BASE_URL",
        "AGENT_MEM_BASE_URL",
        "HER_AGENT_MEM_API_KEY",
        "AGENTMEM_API_KEY",
        "AGENT_MEM_API_KEY",
        "HER_AGENT_CODE",
        "AGENT_CODE",
        "HER_USER_ID",
        "HER_DESKTOP_USER_ID",
        "HER_PLUGIN_DIR",
        "HER_DESKTOP_PLUGIN_DIR",
        "HER_DESKTOP_WORKSPACE_DIR",
        "HER_WORKSPACE_DIR"
    ]

    func testSaveLocalWritesProjectConfigWhenConfigDirectoryExists() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-config-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Config", isDirectory: true), withIntermediateDirectories: true)
        var config = HerAppConfig.empty
        config.agentLLMModel = "test-model"
        config.pluginDirectory = ".her/test-plugins"

        let url = try ConfigLoader.saveLocal(config, cwd: root.path)
        let loaded = ConfigLoader.load(cwd: root.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)

        XCTAssertEqual(url.path, root.appendingPathComponent("Config/her-desktop.local.json").path)
        XCTAssertEqual(loaded.agentLLMModel, "test-model")
        XCTAssertEqual(loaded.pluginDirectory, ".her/test-plugins")
        XCTAssertEqual(loaded.speakAssistantReplies, false)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testConfigPathOverrideLoadsAndSavesExplicitFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-config-override-\(UUID().uuidString)", isDirectory: true)
        let override = root.appendingPathComponent("custom-config.json")
        let previous = getenv("HER_CONFIG_PATH").map { String(cString: $0) }
        setenv("HER_CONFIG_PATH", override.path, 1)
        defer {
            if let previous {
                setenv("HER_CONFIG_PATH", previous, 1)
            } else {
                unsetenv("HER_CONFIG_PATH")
            }
        }
        var config = HerAppConfig.empty
        config.agentLLMModel = "override-model"

        let saved = try ConfigLoader.saveLocal(config, cwd: root.path)
        let loaded = ConfigLoader.load(cwd: root.path)

        XCTAssertEqual(saved.path, override.path)
        XCTAssertEqual(loaded.agentLLMModel, "override-model")
        XCTAssertEqual(ConfigLoader.localConfigCandidates(cwd: root.path).first?.path, override.path)
    }

    func testLoadAcceptsServiceEnvironmentAliasesAndHerPrefixWins() {
        withCleanServiceEnvironment {
            setenv("AGENTLLM_BASE_URL", "https://alias-llm.example", 1)
            setenv("AGENTLLM_API_KEY", "alias-llm-key", 1)
            setenv("AGENTLLM_MODEL", "alias-model", 1)
            setenv("AGENTMEM_BASE_URL", "https://alias-mem.example", 1)
            setenv("AGENTMEM_API_KEY", "alias-mem-key", 1)
            setenv("AGENT_CODE", "alias-agent", 1)
            setenv("HER_DESKTOP_USER_ID", "alias-user", 1)
            setenv("HER_DESKTOP_PLUGIN_DIR", ".alias/plugins", 1)
            setenv("HER_AGENT_LLM_API_KEY", "her-llm-key", 1)
            setenv("HER_AGENT_MEM_API_KEY", "her-mem-key", 1)

            let config = ConfigLoader.load(cwd: "/tmp/her-config-alias-\(UUID().uuidString)")

            XCTAssertEqual(config.agentLLMBaseURL.absoluteString, "https://alias-llm.example")
            XCTAssertEqual(config.agentLLMAPIKey, "her-llm-key")
            XCTAssertEqual(config.agentLLMModel, "alias-model")
            XCTAssertEqual(config.agentMemBaseURL.absoluteString, "https://alias-mem.example")
            XCTAssertEqual(config.agentMemAPIKey, "her-mem-key")
            XCTAssertEqual(config.agentCode, "alias-agent")
            XCTAssertEqual(config.userID, "alias-user")
            XCTAssertEqual(config.pluginDirectory, ".alias/plugins")
        }
    }

    func testPreferredWritableConfigFallsBackToApplicationSupportWhenNoProjectConfigDirectory() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-config-no-project-\(UUID().uuidString)", isDirectory: true)
        let previous = getenv("HER_CONFIG_PATH").map { String(cString: $0) }
        unsetenv("HER_CONFIG_PATH")
        defer {
            if let previous {
                setenv("HER_CONFIG_PATH", previous, 1)
            }
        }

        let url = ConfigLoader.preferredWritableLocalConfigURL(cwd: root.path)

        XCTAssertTrue(url.path.contains("Application Support/Her Desktop/config.json"))
    }

    func testDefaultRuntimeDirectoryNeverUsesReadonlyRoot() {
        withCleanServiceEnvironment {
            let runtime = HerWorkspacePaths.defaultRuntimeDirectory(cwd: "/", bundleURL: nil)

            XCTAssertNotEqual(runtime.path, "/")
            XCTAssertTrue(runtime.path.contains("Application Support/Her Desktop"))
            XCTAssertEqual(HerWorkspacePaths.sessionPath(cwd: runtime.path).lastPathComponent, "session.json")
            XCTAssertFalse(HerWorkspacePaths.sessionPath(cwd: runtime.path).path.hasPrefix("/.her"))
        }
    }

    func testDefaultRuntimeDirectoryFindsProjectRootFromDevAppBundle() throws {
        try withCleanServiceEnvironmentThrowing {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("her-dev-runtime-root-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".build/app/HerDesktop.app", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Config", isDirectory: true),
                withIntermediateDirectories: true
            )
            try "".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

            let bundleURL = root.appendingPathComponent(".build/app/HerDesktop.app", isDirectory: true)
            let runtime = HerWorkspacePaths.defaultRuntimeDirectory(cwd: "/", bundleURL: bundleURL)
            let writableConfig = ConfigLoader.preferredWritableLocalConfigURL(cwd: runtime.path)

            XCTAssertEqual(runtime.standardizedFileURL.path, root.standardizedFileURL.path)
            XCTAssertEqual(writableConfig.path, root.appendingPathComponent("Config/her-desktop.local.json").path)
            XCTAssertEqual(HerWorkspacePaths.sessionPath(cwd: runtime.path).path, root.appendingPathComponent(".her/session.json").path)
        }
    }

    func testWorkspaceDirectoryEnvironmentOverrideWins() {
        withCleanServiceEnvironment {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("her-runtime-override-\(UUID().uuidString)", isDirectory: true)
            setenv("HER_DESKTOP_WORKSPACE_DIR", root.path, 1)

            let runtime = HerWorkspacePaths.defaultRuntimeDirectory(cwd: "/", bundleURL: nil)

            XCTAssertEqual(runtime.path, root.path)
        }
    }

    func testDraftRejectsInvalidURLs() {
        var draft = HerAppConfigDraft(config: .empty)
        draft.agentLLMBaseURL = "not a url"

        XCTAssertThrowsError(try draft.makeConfig())
    }

    func testConfigDecodesLegacyFileWithoutSpeechSettings() throws {
        let data = """
        {
          "agentLLMBaseURL": "https://agentllm.linkyun.co",
          "agentLLMAPIKey": "",
          "agentLLMModel": "linkyun-default",
          "agentMemBaseURL": "https://agentmem.oyii.ai",
          "agentMemAPIKey": "",
          "agentCode": "her-desktop",
          "userID": "stelee",
          "pluginDirectory": ".her/plugins"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(HerAppConfig.self, from: data)

        XCTAssertEqual(config.speakAssistantReplies, false)
        XCTAssertEqual(config.speechVoiceIdentifier, "")
    }

    func testDraftCarriesSpeechSettingsIntoConfig() throws {
        var draft = HerAppConfigDraft(config: .empty)
        draft.speakAssistantReplies = true
        draft.speechVoiceIdentifier = "com.apple.speech.synthesis.voice.samantha"

        let config = try draft.makeConfig()

        XCTAssertEqual(config.speakAssistantReplies, true)
        XCTAssertEqual(config.speechVoiceIdentifier, "com.apple.speech.synthesis.voice.samantha")
    }

    private func withCleanServiceEnvironment(_ body: () -> Void) {
        let previous = Dictionary(uniqueKeysWithValues: serviceEnvKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
        serviceEnvKeys.forEach { unsetenv($0) }
        defer {
            for key in serviceEnvKeys {
                if let value = previous[key] ?? nil {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        body()
    }

    private func withCleanServiceEnvironmentThrowing(_ body: () throws -> Void) throws {
        let previous = Dictionary(uniqueKeysWithValues: serviceEnvKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
        serviceEnvKeys.forEach { unsetenv($0) }
        defer {
            for key in serviceEnvKeys {
                if let value = previous[key] ?? nil {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        try body()
    }
}
