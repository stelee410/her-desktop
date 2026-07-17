import Foundation

struct ConversationSummary: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var pinned: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Roleplay selection for this conversation (角色卡 / 世界之书).
    var characterCardID: String?
    var worldBookID: String?
    /// The project this conversation belongs to (at most one).
    var projectID: String?
    /// Per-conversation chat model; nil follows the global config model.
    var modelOverride: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case pinned
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case characterCardID = "character_card_id"
        case worldBookID = "world_book_id"
        case projectID = "project_id"
        case modelOverride = "model_override"
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
/// Holds only immutable config; its path-scoped file operations are safe to
/// run off the main actor so encode/decode of large transcripts doesn't block
/// the UI.
final class ConversationStore: @unchecked Sendable {
    static let defaultTitle = "新对话"

    private let cwd: String
    private let fileManager: FileManager
    private let legacySessionStore: SessionStore
    /// All off-main transcript I/O runs here so saves and loads stay FIFO —
    /// a switch-away save always lands before a later switch-back load.
    private let ioQueue = DispatchQueue(label: "HerDesktop.ConversationStore.io", qos: .userInitiated)

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

    /// Outcome of loading one transcript. A corrupt/undecodable file is NOT
    /// the same as an empty conversation: conflating them once let a
    /// placeholder overwrite real (still recoverable) content. On corruption
    /// the original file is backed up first, so nothing later can destroy it.
    enum TranscriptLoad: Equatable {
        case loaded([ChatMessage])
        case missing
        case corrupt(backupURL: URL?)
    }

    struct Bootstrap {
        var conversations: [ConversationSummary]
        var activeConversationID: String
        var messages: [ChatMessage]
        /// Set when the active conversation's transcript failed to decode;
        /// points at the backup made of the unreadable file.
        var corruptTranscriptBackup: URL?
        var activeTranscriptCorrupt: Bool
    }

    /// Loads the index (migrating the legacy single-session file when no
    /// index exists yet), resolves the active conversation, and returns its
    /// transcript. Always yields at least one conversation.
    func bootstrap(now: Date = Date()) -> Bootstrap {
        var index: ConversationIndexFileV1?
        do {
            index = try loadIndex()
        } catch {
            // A corrupt (or future-versioned) index is not "no index": back
            // the file up, then rebuild from the transcripts actually on disk
            // so existing conversations are not orphaned.
            _ = backUpUnreadableFile(at: indexURL)
            index = rebuildIndexFromTranscripts(now: now)
        }
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
        let load = loadTranscript(id: activeID)
        try? saveIndex(conversations: conversations, activeConversationID: activeID)
        switch load {
        case .loaded(let messages):
            return Bootstrap(
                conversations: conversations, activeConversationID: activeID,
                messages: messages, corruptTranscriptBackup: nil, activeTranscriptCorrupt: false
            )
        case .missing:
            return Bootstrap(
                conversations: conversations, activeConversationID: activeID,
                messages: [], corruptTranscriptBackup: nil, activeTranscriptCorrupt: false
            )
        case .corrupt(let backupURL):
            return Bootstrap(
                conversations: conversations, activeConversationID: activeID,
                messages: [], corruptTranscriptBackup: backupURL, activeTranscriptCorrupt: true
            )
        }
    }

    /// nil = no index yet; throws = index exists but is unreadable (corrupt
    /// or a future format) — callers must not treat that as "start fresh".
    func loadIndex() throws -> ConversationIndexFileV1? {
        guard fileManager.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        let index = try Self.decoder().decode(ConversationIndexFileV1.self, from: data)
        guard index.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return index
    }

    /// Recovery path for a corrupt index: rebuild summaries from the
    /// transcript files actually present so no conversation is orphaned.
    private func rebuildIndexFromTranscripts(now: Date) -> ConversationIndexFileV1? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ) else { return nil }
        var summaries: [ConversationSummary] = []
        for url in files where url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            if name == "index" || name.contains(".corrupt-") { continue }
            guard case .loaded(let messages) = loadTranscript(id: name), !messages.isEmpty else { continue }
            summaries.append(ConversationSummary(
                id: name,
                title: Self.autoTitle(from: messages) ?? Self.defaultTitle,
                pinned: false,
                createdAt: messages.first?.createdAt ?? now,
                updatedAt: messages.last?.createdAt ?? now
            ))
        }
        guard !summaries.isEmpty else { return nil }
        let active = summaries.max(by: { $0.updatedAt < $1.updatedAt })?.id
        return ConversationIndexFileV1(version: 1, activeConversationID: active, conversations: summaries)
    }

    /// Serialized off-main index write. Fires on every message/rename/pin;
    /// the synchronous encode+atomic-write used to run on the main actor.
    func enqueueSaveIndex(
        conversations: [ConversationSummary],
        activeConversationID: String?,
        onFailure: (@Sendable (Error) -> Void)? = nil
    ) {
        ioQueue.async { [self] in
            do {
                try saveIndex(conversations: conversations, activeConversationID: activeConversationID)
            } catch {
                onFailure?(error)
            }
        }
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

    /// Core transcript read. Never throws: a missing file and an unreadable
    /// file are distinct outcomes, and an unreadable (or future-versioned)
    /// file is copied to a `.corrupt-<timestamp>` sibling before returning,
    /// so no subsequent save can destroy the only copy.
    func loadTranscript(id: String) -> TranscriptLoad {
        let url = conversationURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let file = try Self.decoder().decode(SessionFileV1.self, from: data)
            guard file.version == 1 else {
                return .corrupt(backupURL: backUpUnreadableFile(at: url))
            }
            return .loaded(legacySessionStore.sanitize(file.messages))
        } catch {
            return .corrupt(backupURL: backUpUnreadableFile(at: url))
        }
    }

    /// Legacy throwing shape kept for tests/tools: missing → [], corrupt → throws.
    func loadMessages(id: String) throws -> [ChatMessage] {
        switch loadTranscript(id: id) {
        case .loaded(let messages): return messages
        case .missing: return []
        case .corrupt: throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func backUpUnreadableFile(at url: URL) -> URL? {
        fileManager.backUpSiblingFile(at: url, suffix: "corrupt-\(Int(Date().timeIntervalSince1970))")
    }

    /// Serialized off-main save; ordered against loadAsync. Failures are
    /// reported (once per call) instead of silently dropped — a save that
    /// doesn't land is data loss the user must hear about.
    func enqueueSave(
        _ messages: [ChatMessage],
        id: String,
        onFailure: (@Sendable (Error) -> Void)? = nil
    ) {
        ioQueue.async { [self] in
            do {
                try saveMessages(messages, id: id)
            } catch {
                onFailure?(error)
            }
        }
    }

    /// Blocks until every queued save/load has completed. Called on app
    /// shutdown so pending writes land before the process exits, and by
    /// tests before asserting on-disk state.
    func flushPendingIO() {
        ioQueue.sync {}
    }

    /// Serialized off-main load; runs after any queued save for the same id.
    func loadTranscriptAsync(id: String) async -> TranscriptLoad {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(returning: loadTranscript(id: id))
            }
        }
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
        // On the serial I/O queue so the delete is ordered AFTER any queued
        // save for the same conversation — otherwise a pending async save
        // could land after the delete and resurrect the file.
        try ioQueue.sync {
            let url = conversationURL(id: id)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
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
        do {
            // Only claim the migration once the new transcript actually
            // landed; on failure the legacy file stays untouched and the
            // migration retries next launch.
            try saveMessages(legacyMessages, id: id)
        } catch {
            return nil
        }
        return ConversationIndexFileV1(version: 1, activeConversationID: id, conversations: [summary])
    }

    private static func fileSafeID(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "conversation" : sanitized
    }

    // Built once: these were constructed per save/load, and saves fire on
    // every message. Configuration is immutable after init, so sharing is safe.
    nonisolated(unsafe) private static let sharedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated(unsafe) private static let sharedDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func encoder() -> JSONEncoder { sharedEncoder }

    private static func decoder() -> JSONDecoder { sharedDecoder }
}
