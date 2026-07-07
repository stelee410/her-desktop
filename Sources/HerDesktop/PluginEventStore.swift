import Foundation

enum PluginLifecycleAction: String, Codable, Equatable {
    case staged
    case installed
    case updated
    case discarded
    case removed
    case exported
    case importFailed
    case installFailed
    case removeFailed
    case exportFailed

    var title: String {
        switch self {
        case .staged: return "Staged"
        case .installed: return "Installed"
        case .updated: return "Updated"
        case .discarded: return "Discarded"
        case .removed: return "Removed"
        case .exported: return "Exported"
        case .importFailed: return "Import Failed"
        case .installFailed: return "Install Failed"
        case .removeFailed: return "Remove Failed"
        case .exportFailed: return "Export Failed"
        }
    }
}

struct PluginLifecycleEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var action: PluginLifecycleAction
    var pluginID: String
    var pluginName: String
    var version: String
    var source: String
    var summary: String
    var capabilityCount: Int
    var fileCount: Int
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        action: PluginLifecycleAction,
        pluginID: String,
        pluginName: String,
        version: String,
        source: String,
        summary: String,
        capabilityCount: Int,
        fileCount: Int,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.action = action
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.version = version
        self.source = source
        self.summary = summary
        self.capabilityCount = capabilityCount
        self.fileCount = fileCount
        self.metadata = metadata
    }
}

final class PluginEventStore {
    private let cwd: String
    private let store: JSONLStore<PluginLifecycleEvent>

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.store = JSONLStore(
            url: HerWorkspacePaths.pluginEventsPath(cwd: cwd),
            fileManager: fileManager
        )
    }

    var eventsURL: URL {
        HerWorkspacePaths.pluginEventsPath(cwd: cwd)
    }

    func append(_ event: PluginLifecycleEvent) throws {
        try store.append(event)
    }

    func loadAll() throws -> [PluginLifecycleEvent] {
        try store.loadAll()
    }
}
