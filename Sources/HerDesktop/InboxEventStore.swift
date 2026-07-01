import Foundation

final class InboxEventStore {
    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    var eventsURL: URL {
        HerWorkspacePaths.inboxDirectory(cwd: cwd)
            .appendingPathComponent("events.jsonl")
    }

    func append(_ event: InteractionEvent) throws {
        try fileManager.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)

        if fileManager.fileExists(atPath: eventsURL.path) {
            let handle = try FileHandle(forWritingTo: eventsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: eventsURL, options: .atomic)
        }
    }

    func loadAll() throws -> [InteractionEvent] {
        guard fileManager.fileExists(atPath: eventsURL.path) else {
            return []
        }
        let text = try String(contentsOf: eventsURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text
            .split(separator: "\n")
            .map { try decoder.decode(InteractionEvent.self, from: Data(String($0).utf8)) }
    }
}
