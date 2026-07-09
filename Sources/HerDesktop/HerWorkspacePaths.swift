import Foundation

enum HerWorkspacePaths {
    static let localDirectoryName = ".her"

    static func defaultRuntimeDirectory(
        cwd: String = FileManager.default.currentDirectoryPath,
        bundleURL: URL? = Bundle.main.bundleURL,
        pinnedWorkspaceFile: URL = defaultPinnedWorkspaceFile
    ) -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = envValue(env, "HER_DESKTOP_WORKSPACE_DIR", "HER_WORKSPACE_DIR") {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        if let projectRoot = nearestProjectRoot(cwd: cwd, bundleURL: bundleURL) {
            return projectRoot
        }
        // Installed copies (/Applications) can't find the project by walking
        // up from the bundle; the install step pins the workspace root here.
        if let pinned = pinnedWorkspaceRoot(from: pinnedWorkspaceFile) {
            return pinned
        }
        let current = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        if isWritableUserDirectory(current) {
            return current
        }
        return applicationSupportRuntimeDirectory()
    }

    static var defaultPinnedWorkspaceFile: URL {
        applicationSupportRuntimeDirectory().appendingPathComponent("workspace-root.txt")
    }

    private static func pinnedWorkspaceRoot(from file: URL) -> URL? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let path = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func localAgentDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(localDirectoryName, isDirectory: true)
    }

    static func sessionPath(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("session.json")
    }

    static func conversationsDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    static func webAppsDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("webapps", isDirectory: true)
    }

    static func workspaceDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    static func workPlanPath(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        workspaceDirectory(cwd: cwd)
            .appendingPathComponent("work-plan.json")
    }

    static func pluginExportDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        workspaceDirectory(cwd: cwd)
            .appendingPathComponent("plugin-exports", isDirectory: true)
    }

    static func diagnosticsDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        workspaceDirectory(cwd: cwd)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    static func webServiceArtifactDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        workspaceDirectory(cwd: cwd)
            .appendingPathComponent("webservice-artifacts", isDirectory: true)
    }

    static func logsDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("logs", isDirectory: true)
    }

    static func pluginEventsPath(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        logsDirectory(cwd: cwd)
            .appendingPathComponent("plugin-events.jsonl")
    }

    static func inboxDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    static func dreamsDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("dreams", isDirectory: true)
    }

    static func dreamPromptContextPath(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        dreamsDirectory(cwd: cwd)
            .appendingPathComponent("prompt-context.json")
    }

    static func pluginDraftDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("plugin-drafts", isDirectory: true)
    }

    static func attachmentDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    static func pluginDirectory(config: HerAppConfig, cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        let path = (config.pluginDirectory as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
    }

    static func applicationSupportRuntimeDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Her Desktop", isDirectory: true)
    }

    private static func nearestProjectRoot(cwd: String, bundleURL: URL?) -> URL? {
        for start in projectSearchStarts(cwd: cwd, bundleURL: bundleURL) {
            for directory in ancestorDirectories(from: start) {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
                    || FileManager.default.fileExists(atPath: directory.appendingPathComponent("Config/her-desktop.local.json").path) {
                    return directory
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

    private static func isWritableUserDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path != "/", path.hasPrefix(NSHomeDirectory()) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: path)
    }

    private static func envValue(_ env: [String: String], _ keys: String...) -> String? {
        for key in keys {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
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

struct PromptRuntimeContext: Equatable {
    var cwd: String
    var localAgentDirectory: String
    var sessionPath: String
    var pluginDirectory: String
    var workspaceDirectory: String
    var localTime: String
    var isoTime: String
    var timeZone: String
    var dreamContext: DreamPromptContext? = nil

    static func current(
        config: HerAppConfig,
        cwd: String = FileManager.default.currentDirectoryPath,
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> PromptRuntimeContext {
        _ = calendar

        let localFormatter = DateFormatter()
        localFormatter.locale = locale
        localFormatter.timeZone = timeZone
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        isoFormatter.timeZone = timeZone

        return PromptRuntimeContext(
            cwd: cwd,
            localAgentDirectory: HerWorkspacePaths.localAgentDirectory(cwd: cwd).path,
            sessionPath: HerWorkspacePaths.sessionPath(cwd: cwd).path,
            pluginDirectory: HerWorkspacePaths.pluginDirectory(config: config, cwd: cwd).path,
            workspaceDirectory: HerWorkspacePaths.workspaceDirectory(cwd: cwd).path,
            localTime: localFormatter.string(from: now),
            isoTime: isoFormatter.string(from: now),
            timeZone: timeZone.identifier,
            dreamContext: DreamPromptContextLoader.load(cwd: cwd)
        )
    }
}

struct CompanionPromptContext: Equatable {
    var agentDisplayName: String
    var userDisplayName: String
    var relationship: String
    var knownProfile: Bool
    var memoryMood: String
    var trust: String
    var confidence: String
    var memorySummary: String

    init(profile: AgentProfile, memorySignal: MemorySignal) {
        self.agentDisplayName = profile.displayName
        self.userDisplayName = profile.userDisplayName
        self.relationship = profile.relationship
        self.knownProfile = profile.known
        self.memoryMood = memorySignal.moodLabel
        self.trust = CompanionPromptContext.format(memorySignal.trust)
        self.confidence = CompanionPromptContext.format(memorySignal.confidence)
        self.memorySummary = memorySignal.relationshipSummary
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
