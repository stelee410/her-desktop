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

/// Immutable config only; file appends run on the internal serial queue so
/// they are ordered and off the main thread.
final class AuditEventStore: @unchecked Sendable {
    private let cwd: String
    private let fileManager: FileManager
    private let ioQueue = DispatchQueue(label: "HerDesktop.AuditEventStore.io", qos: .utility)

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    /// Serialized off-main append. Audit fires on every user message and
    /// every tool step; the synchronous open/seek/write used to run on the
    /// main actor each time.
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

    var auditURL: URL {
        HerWorkspacePaths.logsDirectory(cwd: cwd)
            .appendingPathComponent("audit.jsonl")
    }

    func append(_ event: AuditEvent) throws {
        try fileManager.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)

        if fileManager.fileExists(atPath: auditURL.path) {
            let handle = try FileHandle(forWritingTo: auditURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: auditURL, options: .atomic)
        }
    }

    func loadAll() throws -> [AuditEvent] {
        guard fileManager.fileExists(atPath: auditURL.path) else {
            return []
        }
        let text = try String(contentsOf: auditURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Skip malformed lines instead of throwing: append is not atomic, so
        // one truncated line (crash mid-write) must not make the entire audit
        // history unreadable — it is the forensic record for approvals.
        return text
            .split(separator: "\n")
            .compactMap { try? decoder.decode(AuditEvent.self, from: Data(String($0).utf8)) }
    }
}
