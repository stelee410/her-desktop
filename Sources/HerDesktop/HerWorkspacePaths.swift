import Foundation

enum HerWorkspacePaths {
    static let localDirectoryName = ".her"

    static func localAgentDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(localDirectoryName, isDirectory: true)
    }

    static func sessionPath(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        localAgentDirectory(cwd: cwd)
            .appendingPathComponent("session.json")
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
