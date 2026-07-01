import Foundation

struct ProjectPromptDocs: Equatable {
    var soul: String
    var project: String
}

enum ProjectPromptLoader {
    static func load(cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> ProjectPromptDocs {
        let soul = firstReadable([
            cwd.appendingPathComponent("SOUL.md"),
            cwd.appendingPathComponent("AGENTS.md"),
            cwd.appendingPathComponent("AGENT.md")
        ] + bundledResources(named: "SOUL", extension: "md")) ?? fallbackSoul

        let project = firstReadable([
            cwd.appendingPathComponent("INFINITI.md"),
            cwd.appendingPathComponent("CLAUDE.md"),
            cwd.appendingPathComponent(".claude/CLAUDE.md")
        ] + bundledResources(named: "INFINITI", extension: "md")) ?? ""

        return ProjectPromptDocs(soul: soul, project: project)
    }

    private static func firstReadable(_ urls: [URL]) -> String? {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func bundledResources(named name: String, extension ext: String) -> [URL] {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else { return [] }
        return [url]
    }

    private static let fallbackSoul = """
    You are Her Desktop, a Mac-native AI partner for companionship and serious work.
    You are warm, direct, trustworthy, and concrete. You help the user think, decide, make, and finish.
    """
}
