import Foundation

struct AuditEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var type: String
    var summary: String
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        type: String,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.summary = summary
        self.metadata = metadata
    }
}

/// Cross-cutting audit seam. Capability handlers and future extracted
/// services record events through this protocol instead of holding the whole
/// AppViewModel — `self.audit(...)` calls were the number-one edge gluing
/// every subsystem to the god object.
@MainActor
protocol AuditRecording: AnyObject {
    func audit(type: String, summary: String, metadata: [String: String])
}

/// Composes a JSONLStore for the raw file work and adds the serial-queue
/// seam: audit fires on every user message and every tool step, so appends
/// are ordered and kept off the main thread.
final class AuditEventStore: @unchecked Sendable {
    private let cwd: String
    private let store: JSONLStore<AuditEvent>
    private let ioQueue = DispatchQueue(label: "HerDesktop.AuditEventStore.io", qos: .utility)

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.store = JSONLStore(
            url: HerWorkspacePaths.logsDirectory(cwd: cwd).appendingPathComponent("audit.jsonl"),
            fileManager: fileManager
        )
    }

    /// Serialized off-main append.
    func enqueueAppend(_ event: AuditEvent, onFailure: (@Sendable (Error) -> Void)? = nil) {
        ioQueue.async { [self] in
            do {
                try append(event)
            } catch {
                onFailure?(error)
            }
        }
    }

    /// Blocks until queued appends have landed (shutdown + tests).
    func flushPendingIO() {
        ioQueue.sync {}
    }

    /// Tail read for the recent-events feed (audit.jsonl is unbounded).
    func loadRecent(maxBytes: Int = 131_072) throws -> [AuditEvent] {
        try store.loadRecent(maxBytes: maxBytes)
    }

    var auditURL: URL {
        HerWorkspacePaths.logsDirectory(cwd: cwd)
            .appendingPathComponent("audit.jsonl")
    }

    func append(_ event: AuditEvent) throws {
        try store.append(event)
    }

    func loadAll() throws -> [AuditEvent] {
        try store.loadAll()
    }
}
