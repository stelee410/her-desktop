import Foundation

/// 角色卡: a persona Her plays in a conversation — freeform prompt text plus
/// an optional opening line.
struct CharacterCard: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var emoji: String = "🎭"
    /// Avatar image filename under `.her/roleplay-assets/`. Empty → the
    /// emoji stands in as the avatar.
    var avatarPath: String = ""
    /// One-line summary shown in lists/pickers.
    var summary: String = ""
    /// The card body injected into the system prompt: persona, personality,
    /// speech style, background, boundaries — freeform.
    var prompt: String = ""
    /// Optional greeting used when a conversation adopts this card.
    var greeting: String = ""
    /// Dedicated AgentMem key for this character. Empty means conversations
    /// playing this card DON'T use memory at all — roleplay must never
    /// pollute the real relationship memory. A key gives the character its
    /// own memory identity (AgentMem is memory-key-bound).
    var agentMemAPIKey: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "🎭",
        avatarPath: String = "",
        summary: String = "",
        prompt: String = "",
        greeting: String = "",
        agentMemAPIKey: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.avatarPath = avatarPath
        self.summary = summary
        self.prompt = prompt
        self.greeting = greeting
        self.agentMemAPIKey = agentMemAPIKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding: cards written before a field existed load with
    /// defaults instead of tripping the corrupt-file path.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "角色"
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "🎭"
        avatarPath = try container.decodeIfPresent(String.self, forKey: .avatarPath) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        greeting = try container.decodeIfPresent(String.self, forKey: .greeting) ?? ""
        agentMemAPIKey = try container.decodeIfPresent(String.self, forKey: .agentMemAPIKey) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Non-empty dedicated memory key, if configured.
    var dedicatedMemoryKey: String? {
        let trimmed = agentMemAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 世界之书: lorebook entries injected into the prompt — always-on entries
/// unconditionally, keyword entries only when recent conversation text
/// mentions one of their keywords (classic lorebook behavior).
struct WorldBook: Identifiable, Codable, Equatable {
    struct Entry: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var title: String = ""
        /// Comma/space separated keywords; empty + alwaysOn=false → inert.
        var keywords: String = ""
        var content: String = ""
        var alwaysOn: Bool = false

        var keywordList: [String] {
            keywords
                .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    var id: UUID = UUID()
    var name: String
    var emoji: String = "📖"
    var summary: String = ""
    /// Chat-background image filename under `.her/roleplay-assets/`. Empty →
    /// conversations in this world keep the default backdrop.
    var backgroundPath: String = ""
    var entries: [Entry] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "📖",
        summary: String = "",
        backgroundPath: String = "",
        entries: [Entry] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.summary = summary
        self.backgroundPath = backgroundPath
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding, same contract as CharacterCard: books written
    /// before a field existed load with defaults instead of tripping the
    /// corrupt-file path.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "世界"
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "📖"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        backgroundPath = try container.decodeIfPresent(String.self, forKey: .backgroundPath) ?? ""
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Entries that apply given the recent conversation text: always-on ones
    /// plus keyword entries whose keyword appears (case-insensitive).
    func activeEntries(matching recentText: String) -> [Entry] {
        let haystack = recentText.lowercased()
        return entries.filter { entry in
            if entry.alwaysOn { return !entry.content.isEmpty }
            guard !entry.content.isEmpty else { return false }
            return entry.keywordList.contains { haystack.contains($0.lowercased()) }
        }
    }
}

struct RoleplayFileV1: Codable {
    var version: Int
    var characterCards: [CharacterCard]
    var worldBooks: [WorldBook]
}

/// Persists roleplay assets at `.her/roleplay.json`. Same defensive rules as
/// the other stores: atomic writes, corrupt files backed up first.
final class RoleplayStore {
    private let fileManager: FileManager
    let fileURL: URL

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = HerWorkspacePaths.localAgentDirectory(cwd: cwd)
            .appendingPathComponent("roleplay.json")
    }

    func load() -> (cards: [CharacterCard], books: [WorldBook]) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return ([], []) }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try Self.decoder.decode(RoleplayFileV1.self, from: data)
            guard file.version == 1 else {
                fileManager.backUpSiblingFile(at: fileURL, suffix: "v\(file.version).bak")
                return ([], [])
            }
            return (file.characterCards, file.worldBooks)
        } catch {
            fileManager.backUpSiblingFile(at: fileURL, suffix: "corrupt-\(Int(Date().timeIntervalSince1970))")
            return ([], [])
        }
    }

    /// Where avatar/background images live, next to roleplay.json.
    var assetsDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("roleplay-assets", isDirectory: true)
    }

    /// Copies an image into the workspace under a fresh unique name (so a
    /// replaced avatar never aliases a stale cache entry) and returns the
    /// stored filename. Cards keep working if the source file later moves.
    func importAsset(from source: URL, prefix: String) throws -> String {
        try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let name = "\(prefix)-\(UUID().uuidString).\(ext)"
        try fileManager.copyItem(at: source, to: assetsDirectory.appendingPathComponent(name))
        return name
    }

    /// Resolves a stored filename to a readable URL, or nil when unset/gone.
    func assetURL(named name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        let url = assetsDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func save(cards: [CharacterCard], books: [WorldBook]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = RoleplayFileV1(version: 1, characterCards: cards, worldBooks: books)
        try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    nonisolated(unsafe) private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated(unsafe) private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
