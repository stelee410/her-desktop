import Foundation

enum ConfigLoader {
    static func load(cwd: String = FileManager.default.currentDirectoryPath) -> HerAppConfig {
        let env = ProcessInfo.processInfo.environment
        var config = HerAppConfig.empty

        if let fileConfig = loadLocalFile(cwd: cwd) {
            config = fileConfig
        }

        config.agentLLMBaseURL = url(
            from: envValue(env, "HER_AGENT_LLM_BASE_URL", "AGENTLLM_BASE_URL", "AGENT_LLM_BASE_URL"),
            fallback: config.agentLLMBaseURL
        )
        config.agentLLMAPIKey = envValue(env, "HER_AGENT_LLM_API_KEY", "AGENTLLM_API_KEY", "AGENT_LLM_API_KEY") ?? config.agentLLMAPIKey
        config.agentLLMModel = envValue(env, "HER_AGENT_LLM_MODEL", "AGENTLLM_MODEL", "AGENT_LLM_MODEL") ?? config.agentLLMModel
        if let rawMaxTokens = envValue(env, "HER_AGENT_LLM_MAX_TOKENS", "AGENTLLM_MAX_TOKENS", "AGENT_LLM_MAX_TOKENS"),
           let maxTokens = Int(rawMaxTokens), maxTokens > 0 {
            config.agentLLMMaxTokens = maxTokens
        }
        config.agentMemBaseURL = url(
            from: envValue(env, "HER_AGENT_MEM_BASE_URL", "AGENTMEM_BASE_URL", "AGENT_MEM_BASE_URL"),
            fallback: config.agentMemBaseURL
        )
        config.agentMemAPIKey = envValue(env, "HER_AGENT_MEM_API_KEY", "AGENTMEM_API_KEY", "AGENT_MEM_API_KEY") ?? config.agentMemAPIKey
        config.agentCode = envValue(env, "HER_AGENT_CODE", "AGENT_CODE") ?? config.agentCode
        config.userID = envValue(env, "HER_USER_ID", "HER_DESKTOP_USER_ID") ?? config.userID
        config.pluginDirectory = envValue(env, "HER_PLUGIN_DIR", "HER_DESKTOP_PLUGIN_DIR") ?? config.pluginDirectory
        if let provider = envValue(env, "HER_ASR_PROVIDER"), ["apple", "agentllm"].contains(provider.lowercased()) {
            config.speechRecognitionProvider = provider.lowercased()
        }
        config.agentLLMASRModel = envValue(env, "HER_ASR_MODEL") ?? config.agentLLMASRModel
        return config
    }

    static func saveLocal(_ config: HerAppConfig, cwd: String = FileManager.default.currentDirectoryPath) throws -> URL {
        let url = preferredWritableLocalConfigURL(cwd: cwd)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func localConfigCandidates(cwd: String = FileManager.default.currentDirectoryPath) -> [URL] {
        localConfigCandidates(cwd: cwd, bundleURL: Bundle.main.bundleURL)
    }

    static func localConfigCandidates(
        cwd: String = FileManager.default.currentDirectoryPath,
        bundleURL: URL?
    ) -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["HER_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            urls.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        urls.append(contentsOf: projectLocalConfigCandidates(cwd: cwd, bundleURL: bundleURL))
        urls.append(applicationSupportConfigURL())
        urls.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".her/desktop/config.json"))
        return uniqueURLs(urls)
    }

    static func preferredWritableLocalConfigURL(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        if let override = ProcessInfo.processInfo.environment["HER_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let projectConfigDir = firstProjectConfigDirectory(cwd: cwd, bundleURL: Bundle.main.bundleURL) {
            return projectConfigDir.appendingPathComponent("her-desktop.local.json")
        }
        return applicationSupportConfigURL()
    }

    private static func loadLocalFile(cwd: String) -> HerAppConfig? {
        let decoder = JSONDecoder()
        for url in localConfigCandidates(cwd: cwd) where FileManager.default.fileExists(atPath: url.path) {
            do {
                return try decoder.decode(HerAppConfig.self, from: Data(contentsOf: url))
            } catch {
                print("Failed to load config at \(url.path): \(error)")
            }
        }
        return nil
    }

    private static func url(from raw: String?, fallback: URL) -> URL {
        guard let raw, let parsed = URL(string: raw), !raw.isEmpty else {
            return fallback
        }
        return parsed
    }

    private static func envValue(_ env: [String: String], _ keys: String...) -> String? {
        for key in keys {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func applicationSupportConfigURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Her Desktop", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func projectLocalConfigCandidates(cwd: String, bundleURL: URL?) -> [URL] {
        let starts = projectSearchStarts(cwd: cwd, bundleURL: bundleURL)
        return starts.flatMap { start in
            ancestorDirectories(from: start).map {
                $0.appendingPathComponent("Config/her-desktop.local.json")
            }
        }
    }

    private static func firstProjectConfigDirectory(cwd: String, bundleURL: URL?) -> URL? {
        for start in projectSearchStarts(cwd: cwd, bundleURL: bundleURL) {
            for directory in ancestorDirectories(from: start) {
                let configDirectory = directory.appendingPathComponent("Config", isDirectory: true)
                if FileManager.default.fileExists(atPath: configDirectory.path) {
                    return configDirectory
                }
            }
        }
        return nil
    }

    private static func projectSearchStarts(cwd: String, bundleURL: URL?) -> [URL] {
        var starts = [URL(fileURLWithPath: cwd, isDirectory: true)]
        if let bundleURL {
            starts.append(bundleURL)
            starts.append(bundleURL.deletingLastPathComponent())
        }
        return uniqueURLs(starts)
    }

    private static func ancestorDirectories(from start: URL) -> [URL] {
        var directories: [URL] = []
        var current = start.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current.deleteLastPathComponent()
        }
        while true {
            directories.append(current)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return directories
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}
