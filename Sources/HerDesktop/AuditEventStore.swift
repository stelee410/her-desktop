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

final class AuditEventStore {
    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
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
        return try text
            .split(separator: "\n")
            .map { try decoder.decode(AuditEvent.self, from: Data(String($0).utf8)) }
    }
}
