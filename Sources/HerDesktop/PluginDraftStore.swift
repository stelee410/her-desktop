import Foundation

final class PluginDraftStore {
    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    var draftsDirectory: URL {
        HerWorkspacePaths.pluginDraftDirectory(cwd: cwd)
    }

    func loadAll() throws -> [GeneratedPluginDraft] {
        guard fileManager.fileExists(atPath: draftsDirectory.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try fileManager.contentsOfDirectory(at: draftsDirectory, includingPropertiesForKeys: nil)
        return try items
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(GeneratedPluginDraft.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ draft: GeneratedPluginDraft) throws {
        try fileManager.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(draft).write(to: draftURL(for: draft.id), options: .atomic)
    }

    func delete(_ draft: GeneratedPluginDraft) throws {
        try delete(id: draft.id)
    }

    func delete(id: UUID) throws {
        let url = draftURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func draftURL(for id: UUID) -> URL {
        draftsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}
