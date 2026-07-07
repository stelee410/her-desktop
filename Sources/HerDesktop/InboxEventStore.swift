import Foundation

final class InboxEventStore {
    private let cwd: String
    private let store: JSONLStore<InteractionEvent>

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.store = JSONLStore(
            url: HerWorkspacePaths.inboxDirectory(cwd: cwd).appendingPathComponent("events.jsonl"),
            fileManager: fileManager
        )
    }

    var eventsURL: URL {
        HerWorkspacePaths.inboxDirectory(cwd: cwd)
            .appendingPathComponent("events.jsonl")
    }

    func append(_ event: InteractionEvent) throws {
        try store.append(event)
    }

    func loadAll() throws -> [InteractionEvent] {
        try store.loadAll()
    }
}
