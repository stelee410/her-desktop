import Foundation

/// 角色卡: a persona Her plays in a conversation — freeform prompt text plus
/// an optional opening line.
struct CharacterCard: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var emoji: String = "🎭"
    /// One-line summary shown in lists/pickers.
    var summary: String = ""
    /// The card body injected into the system prompt: persona, personality,
    /// speech style, background, boundaries — freeform.
    var prompt: String = ""
    /// Optional greeting used when a conversation adopts this card.
    var greeting: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
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
    var entries: [Entry] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

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
