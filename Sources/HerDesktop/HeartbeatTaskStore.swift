import Foundation

/// A scheduled unit of proactive work the heartbeat engine runs when due.
struct HeartbeatTask: Identifiable, Codable, Equatable {
    /// What firing the task does.
    enum Action: String, Codable {
        /// Post a local macOS notification directly — no LLM turn, no tokens.
        case notify
        /// Wake the agent with `prompt` as a full conversation turn (tools
        /// allowed; normal approval rules apply).
        case prompt
    }

    /// When the task fires.
    enum Schedule: Codable, Equatable {
        /// Fire once at a specific time.
        case once(at: Date)
        /// Fire repeatedly every N seconds (minimum enforced by the engine).
        case every(seconds: TimeInterval)
        /// Fire once per day at hour:minute (local time).
        case daily(hour: Int, minute: Int)

        private enum CodingKeys: String, CodingKey {
            case kind
            case at
            case seconds
            case hour
            case minute
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "once":
                self = .once(at: try container.decode(Date.self, forKey: .at))
            case "every":
                self = .every(seconds: try container.decode(TimeInterval.self, forKey: .seconds))
            case "daily":
                self = .daily(
                    hour: try container.decode(Int.self, forKey: .hour),
                    minute: try container.decode(Int.self, forKey: .minute)
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "unknown schedule kind"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .once(let at):
                try container.encode("once", forKey: .kind)
                try container.encode(at, forKey: .at)
            case .every(let seconds):
                try container.encode("every", forKey: .kind)
                try container.encode(seconds, forKey: .seconds)
            case .daily(let hour, let minute):
                try container.encode("daily", forKey: .kind)
                try container.encode(hour, forKey: .hour)
                try container.encode(minute, forKey: .minute)
            }
        }
    }

    var id: UUID = UUID()
    var title: String
    var action: Action
    /// Notification body (notify) or the agent turn text (prompt).
    var prompt: String
    var schedule: Schedule
    var enabled: Bool = true
    var createdAt: Date = Date()
    var lastFiredAt: Date? = nil
    /// Set when a one-shot task has fired; it stays listed until cleaned up
    /// so the user can see it completed.
    var completedAt: Date? = nil

    /// The next time this task should fire, or nil when it never will again.
    ///
    /// Anchor semantics: recurring schedules anchor on `lastFiredAt`, or on
    /// `createdAt` before the first fire — so "daily at 09:00" created at
    /// 10:00 first fires TOMORROW 09:00 (not immediately), and "every 30
    /// min" first fires 30 minutes after creation. Occurrences missed while
    /// the app was closed still catch up (the computed date is in the past →
    /// due), but never more than once.
    func nextFireDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, completedAt == nil else { return nil }
        let anchor = lastFiredAt ?? createdAt
        switch schedule {
        case .once(let at):
            return at
        case .every(let seconds):
            let interval = max(seconds, HeartbeatEngine.minimumInterval)
            return anchor.addingTimeInterval(interval)
        case .daily(let hour, let minute):
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            return calendar.nextDate(after: anchor, matching: components, matchingPolicy: .nextTime)
        }
    }

    func isDue(at reference: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextFireDate(after: reference, calendar: calendar) else { return false }
        return next <= reference
    }

    var scheduleDescription: String {
        switch schedule {
        case .once(let at):
            return "once at \(HeartbeatTaskStore.displayFormatter.string(from: at))"
        case .every(let seconds):
            let minutes = Int(seconds / 60)
            return minutes >= 1 ? "every \(minutes) min" : "every \(Int(seconds))s"
        case .daily(let hour, let minute):
            return String(format: "daily at %02d:%02d", hour, minute)
        }
    }
}

/// Engine constants shared by the store and the view model.
enum HeartbeatEngine {
    /// How often the heartbeat timer checks for due tasks.
    static let tickInterval: TimeInterval = 30
    /// Floor for recurring tasks so a runaway `every 1s` cannot spin the
    /// agent (and the token budget) into the ground.
    static let minimumInterval: TimeInterval = 60
}

struct HeartbeatFileV1: Codable {
    var version: Int
    var tasks: [HeartbeatTask]
}

/// Persists scheduled tasks at `.her/heartbeat.json`. Same defensive rules
/// as the other stores: atomic writes, corrupt files are backed up (never
/// silently replaced), unknown versions are preserved.
final class HeartbeatTaskStore {
    private let cwd: String
    private let fileManager: FileManager

    init(cwd: String = FileManager.default.currentDirectoryPath, fileManager: FileManager = .default) {
        self.cwd = cwd
        self.fileManager = fileManager
    }

    var fileURL: URL {
        HerWorkspacePaths.localAgentDirectory(cwd: cwd).appendingPathComponent("heartbeat.json")
    }

    func load() -> [HeartbeatTask] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try Self.decoder.decode(HeartbeatFileV1.self, from: data)
            guard file.version == 1 else {
                backUpUnreadableFile()
                return []
            }
            return file.tasks
        } catch {
            backUpUnreadableFile()
            return []
        }
    }

    func save(_ tasks: [HeartbeatTask]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = HeartbeatFileV1(version: 1, tasks: tasks)
        try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    private func backUpUnreadableFile() {
        fileManager.backUpSiblingFile(at: fileURL, suffix: "corrupt-\(Int(Date().timeIntervalSince1970))")
    }

    nonisolated(unsafe) static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

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
