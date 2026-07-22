import Foundation

struct ProjectPromptDocs: Equatable {
    var soul: String
    var project: String
    var soulSource: String = "unspecified"
    var projectSource: String = "unspecified"
}

enum ProjectPromptLoader {
    static func load(cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> ProjectPromptDocs {
        let soul = firstReadable([
            candidate(cwd.appendingPathComponent("SOUL.md"), source: "workspace/SOUL.md"),
            candidate(cwd.appendingPathComponent("AGENTS.md"), source: "workspace/AGENTS.md"),
            candidate(cwd.appendingPathComponent("AGENT.md"), source: "workspace/AGENT.md")
        ] + bundledResources(named: "SOUL", extension: "md")) ?? LoadedPromptDocument(
            text: fallbackSoul,
            source: "fallback/HerDesktop"
        )

        let project = firstReadable([
            candidate(cwd.appendingPathComponent("INFINITI.md"), source: "workspace/INFINITI.md"),
            candidate(cwd.appendingPathComponent("CLAUDE.md"), source: "workspace/CLAUDE.md"),
            candidate(cwd.appendingPathComponent(".claude/CLAUDE.md"), source: "workspace/.claude/CLAUDE.md")
        ] + bundledResources(named: "INFINITI", extension: "md")) ?? LoadedPromptDocument(
            text: "",
            source: "none"
        )

        return ProjectPromptDocs(
            soul: soul.text,
            project: project.text,
            soulSource: soul.source,
            projectSource: project.source
        )
    }

    private struct PromptDocumentCandidate {
        var url: URL
        var source: String
    }

    private struct LoadedPromptDocument {
        var text: String
        var source: String
    }

    private static func candidate(_ url: URL, source: String) -> PromptDocumentCandidate {
        PromptDocumentCandidate(url: url, source: source)
    }

    private static func firstReadable(_ candidates: [PromptDocumentCandidate]) -> LoadedPromptDocument? {
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.url.path) {
            if let text = try? String(contentsOf: candidate.url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return LoadedPromptDocument(text: text, source: candidate.source)
            }
        }
        return nil
    }

    private static func bundledResources(named name: String, extension ext: String) -> [PromptDocumentCandidate] {
        guard let url = Bundle.herResources.url(forResource: name, withExtension: ext) else { return [] }
        return [candidate(url, source: "bundled/\(name).\(ext)")]
    }

    private static let fallbackSoul = """
    You are Her Desktop, a Mac-native AI partner for companionship and serious work.
    You are warm, direct, trustworthy, and concrete. You help the user think, decide, make, and finish.
    """
}
