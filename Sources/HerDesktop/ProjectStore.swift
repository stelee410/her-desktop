import Foundation

/// 项目: a piece of ongoing work — goal, editable brief, a plan checklist
/// shared between the user and the agent, a working directory that collects
/// the deliverables, and the conversations that belong to it.
struct Project: Identifiable, Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case active
        case paused
        case done
        case archived

        var displayName: String {
            switch self {
            case .active: return "进行中"
            case .paused: return "已暂停"
            case .done: return "已完成"
            case .archived: return "已归档"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var emoji: String = "📁"
    /// One-line goal shown in lists and injected into the prompt.
    var goal: String = ""
    /// Editable background/context (Markdown) injected into the prompt.
    var brief: String = ""
    /// The shared plan checklist: the user toggles steps in the detail page,
    /// the agent updates the same data via workspace.plan.
    var plan: WorkPlan?
    var status: Status = .active
    /// Working directory that collects the project's deliverables. Empty →
    /// the default `<workspace>/projects/<name>` is used (created on demand).
    var directoryPath: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "📁",
        goal: String = "",
        brief: String = "",
        plan: WorkPlan? = nil,
        status: Status = .active,
        directoryPath: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.goal = goal
        self.brief = brief
        self.plan = plan
        self.status = status
        self.directoryPath = directoryPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding, same contract as the roleplay assets: projects
    /// written before a field existed load with defaults instead of tripping
    /// the corrupt-file path.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "项目"
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "📁"
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        brief = try container.decodeIfPresent(String.self, forKey: .brief) ?? ""
        plan = try container.decodeIfPresent(WorkPlan.self, forKey: .plan)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .active
        directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var progress: Double { plan?.progress ?? 0 }

    /// The first not-done step — "what's next" for lists and the prompt.
    var nextStep: WorkPlan.Step? {
        plan?.steps.first { $0.status != .done }
    }
}

struct ProjectsFileV1: Codable {
    var version: Int
    var projects: [Project]
}

/// Persists projects at `.her/projects.json` and resolves each project's
/// working directory. Same defensive rules as the other stores: atomic
/// writes, corrupt files backed up first.
final class ProjectStore {
    private let cwd: String
    private let fileManager: FileManager
    let fileURL: URL

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
        self.fileURL = HerWorkspacePaths.localAgentDirectory(cwd: cwd)
            .appendingPathComponent("projects.json")
    }

    func load() -> [Project] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try Self.decoder.decode(ProjectsFileV1.self, from: data)
            guard file.version == 1 else {
                fileManager.backUpSiblingFile(at: fileURL, suffix: "v\(file.version).bak")
                return []
            }
            return file.projects
        } catch {
            fileManager.backUpSiblingFile(at: fileURL, suffix: "corrupt-\(Int(Date().timeIntervalSince1970))")
            return []
        }
    }

    func save(_ projects: [Project]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = ProjectsFileV1(version: 1, projects: projects)
        try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    // MARK: - Working directory

    /// The project's working directory URL. A custom path wins; otherwise
    /// the default `<workspace>/projects/<sanitized name>`. Not created here.
    func directoryURL(for project: Project) -> URL {
        let custom = project.directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(Self.directoryName(for: project), isDirectory: true)
    }

    /// Resolves AND ensures the directory exists — deliverables always have
    /// a landing place by the time anyone asks for it.
    @discardableResult
    func ensureDirectory(for project: Project) throws -> URL {
        let url = directoryURL(for: project)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Filesystem-safe folder name derived from the project name; the id
    /// suffix keeps same-named projects apart.
    static func directoryName(for project: Project) -> String {
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0}")
        let safe = trimmed.components(separatedBy: unsafe).joined(separator: "-")
        let base = safe.isEmpty ? "project" : String(safe.prefix(40))
        return "\(base)-\(project.id.uuidString.prefix(8))"
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
