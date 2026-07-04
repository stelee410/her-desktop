import Foundation

struct ConversationSummary: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var pinned: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case pinned
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ConversationIndexFileV1: Codable, Equatable {
    var version: Int
    var activeConversationID: String?
    var conversations: [ConversationSummary]

    enum CodingKeys: String, CodingKey {
        case version
        case activeConversationID = "active_conversation_id"
        case conversations
    }
}

/// Persists multiple conversation transcripts under `.her/conversations/`,
/// one JSON file per conversation plus an `index.json` with titles, pin
/// state, and the active conversation. A legacy single `.her/session.json`
/// is migrated into the first conversation on first load.
final class ConversationStore {
    static let defaultTitle = "新对话"

    private let cwd: String
    private let fileManager: FileManager
    private let legacySessionStore: SessionStore

    init(
        cwd: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default,
        maxToolResultCharacters: Int = 8_000
    ) {
        self.cwd = cwd
        self.fileManager = fileManager
        self.legacySessionStore = SessionStore(
            cwd: cwd,
            fileManager: fileManager,
            maxToolResultCharacters: maxToolResultCharacters
        )
    }

    var directoryURL: URL {
        HerWorkspacePaths.conversationsDirectory(cwd: cwd)
    }

    var indexURL: URL {
        directoryURL.appendingPathComponent("index.json")
    }

    func conversationURL(id: String) -> URL {
        directoryURL.appendingPathComponent("\(Self.fileSafeID(id)).json")
    }

    struct Bootstrap {
        var conversations: [ConversationSummary]
        var activeConversationID: String
        var messages: [ChatMessage]
    }

    /// Loads the index (migrating the legacy single-session file when no
    /// index exists yet), resolves the active conversation, and returns its
    /// transcript. Always yields at least one conversation.
    func bootstrap(now: Date = Date()) -> Bootstrap {
        var index = (try? loadIndex()) ?? nil
        if index == nil {
            index = migrateLegacySessionIfPresent(now: now)
        }
        var conversations = index?.conversations ?? []
        if conversations.isEmpty {
            conversations = [ConversationSummary(
                id: UUID().uuidString,
                title: Self.defaultTitle,
                pinned: false,
                createdAt: now,
                updatedAt: now
            )]
        }
        let activeID: String
        if let stored = index?.activeConversationID, conversations.contains(where: { $0.id == stored }) {
            activeID = stored
        } else {
            activeID = conversations.max(by: { $0.updatedAt < $1.updatedAt })?.id ?? conversations[0].id
        }
        let messages = (try? loadMessages(id: activeID)) ?? []
        try? saveIndex(conversations: conversations, activeConversationID: activeID)
        return Bootstrap(conversations: conversations, activeConversationID: activeID, messages: messages)
    }

    func loadIndex() throws -> ConversationIndexFileV1? {
        guard fileManager.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        let index = try Self.decoder().decode(ConversationIndexFileV1.self, from: data)
        guard index.version == 1 else { return nil }
        return index
    }

    func saveIndex(conversations: [ConversationSummary], activeConversationID: String?) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let index = ConversationIndexFileV1(
            version: 1,
            activeConversationID: activeConversationID,
            conversations: conversations
        )
        try Self.encoder().encode(index).write(to: indexURL, options: .atomic)
    }

    func loadMessages(id: String) throws -> [ChatMessage] {
        let url = conversationURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let file = try Self.decoder().decode(SessionFileV1.self, from: data)
        guard file.version == 1 else { return [] }
        return legacySessionStore.sanitize(file.messages)
    }

    func saveMessages(_ messages: [ChatMessage], id: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let file = SessionFileV1(
            version: 1,
            cwd: cwd,
            sessionID: id,
            messages: legacySessionStore.sanitize(messages)
        )
        try Self.encoder().encode(file).write(to: conversationURL(id: id), options: .atomic)
    }

    func deleteConversationFile(id: String) throws {
        let url = conversationURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Short title candidate from the first user message, or nil while the
    /// conversation has no user content yet.
    static func autoTitle(from messages: [ChatMessage], maxLength: Int = 24) -> String? {
        guard let firstUser = messages.first(where: { $0.role == .user }) else { return nil }
        let collapsed = firstUser.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLength {
            return collapsed
        }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    private func migrateLegacySessionIfPresent(now: Date) -> ConversationIndexFileV1? {
        guard let legacyMessages = try? legacySessionStore.load(), !legacyMessages.isEmpty else {
            return nil
        }
        let id = (try? legacySessionStore.loadSessionID()) ?? UUID().uuidString
        let summary = ConversationSummary(
            id: id,
            title: Self.autoTitle(from: legacyMessages) ?? Self.defaultTitle,
            pinned: false,
            createdAt: legacyMessages.first?.createdAt ?? now,
            updatedAt: legacyMessages.last?.createdAt ?? now
        )
        try? saveMessages(legacyMessages, id: id)
        return ConversationIndexFileV1(version: 1, activeConversationID: id, conversations: [summary])
    }

    private static func fileSafeID(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "conversation" : sanitized
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
