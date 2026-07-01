import Foundation

struct SessionFileV1: Codable, Equatable {
    var version: Int
    var cwd: String
    var sessionID: String?
    var messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case version
        case cwd
        case sessionID = "session_id"
        case messages
    }
}

final class SessionStore {
    private let cwd: String
    private let fileManager: FileManager
    private let maxToolResultCharacters: Int

    init(
        cwd: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default,
        maxToolResultCharacters: Int = 8_000
    ) {
        self.cwd = cwd
        self.fileManager = fileManager
        self.maxToolResultCharacters = maxToolResultCharacters
    }

    var sessionURL: URL {
        HerWorkspacePaths.sessionPath(cwd: cwd)
    }

    func load() throws -> [ChatMessage] {
        guard fileManager.fileExists(atPath: sessionURL.path) else {
            return []
        }
        let file = try loadFile()
        guard file.version == 1 else {
            return []
        }
        return sanitize(file.messages)
    }

    func loadSessionID() throws -> String? {
        guard fileManager.fileExists(atPath: sessionURL.path) else {
            return nil
        }
        let file = try loadFile()
        return file.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func loadOrCreateSessionID() -> String {
        (try? loadSessionID()) ?? UUID().uuidString
    }

    func save(messages: [ChatMessage], sessionID: String? = nil) throws {
        let directory = sessionURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = SessionFileV1(
            version: 1,
            cwd: cwd,
            sessionID: sessionID,
            messages: sanitize(messages)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: sessionURL, options: .atomic)
    }

    func sanitize(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.compactMap { message in
            if message.role == .assistant && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            if message.role == .tool && message.content.count > maxToolResultCharacters {
                var truncated = message
                let index = message.content.index(message.content.startIndex, offsetBy: maxToolResultCharacters)
                truncated.content = String(message.content[..<index])
                    + "\n...(truncated, original \(message.content.count) characters)"
                return truncated
            }
            return message
        }
    }

    private func loadFile() throws -> SessionFileV1 {
        let data = try Data(contentsOf: sessionURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFileV1.self, from: data)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
