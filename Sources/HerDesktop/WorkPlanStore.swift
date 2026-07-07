import Foundation

struct WorkPlanFileV1: Codable, Equatable {
    var version: Int
    var cwd: String
    var plan: WorkPlan
}

final class WorkPlanStore {
    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    var planURL: URL {
        HerWorkspacePaths.workPlanPath(cwd: cwd)
    }

    func load() throws -> WorkPlan? {
        guard fileManager.fileExists(atPath: planURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: planURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(WorkPlanFileV1.self, from: data)
        guard file.version == 1 else {
            // Unknown (future) format: preserve a copy before a later save()
            // can overwrite it, instead of silently discarding the user's plan.
            fileManager.backUpSiblingFile(at: planURL, suffix: "v\(file.version).bak")
            return nil
        }
        return file.plan
    }

    func save(_ plan: WorkPlan) throws -> URL {
        let directory = planURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = WorkPlanFileV1(version: 1, cwd: cwd, plan: plan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: planURL, options: .atomic)
        return planURL
    }
}
