import Foundation

struct PresenceStatus: Equatable {
    var title: String
    var systemImage: String
    var tone: Tone

    enum Tone: Equatable {
        case healthy
        case warning
        case muted
        case active
    }
}

enum PresenceCopy {
    static func greeting(
        connectionState: ConnectionState,
        agentProfile: AgentProfile,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let name = displayName(agentProfile.userDisplayName)
        switch connectionState {
        case .thinking:
            return "我在整理上下文。"
        case .working:
            return "我在执行工具。"
        case .listening:
            return "我在听。"
        case .speaking:
            return "我在说给你听。"
        case .error:
            return "连接有点不稳。"
        case .offline:
            return "配置好服务后，我就能接上工作。"
        case .ready:
            return "\(daypartGreeting(now: now, calendar: calendar))，\(name)。\n今天我们从哪里开始？"
        }
    }

    static func serviceStatus(_ health: [ServiceHealth]) -> PresenceStatus {
        let remote = health.filter { $0.id == "agentllm" || $0.id == "agentmem" }
        guard !remote.isEmpty else {
            return PresenceStatus(title: "Local", systemImage: "circle.dotted", tone: .muted)
        }
        if remote.contains(where: { $0.state == .checking }) {
            return PresenceStatus(title: "Checking", systemImage: "arrow.triangle.2.circlepath", tone: .active)
        }
        if remote.allSatisfy({ $0.state == .online }) {
            return PresenceStatus(title: "Synced", systemImage: "checkmark.circle", tone: .healthy)
        }
        if remote.contains(where: { $0.state == .offline }) {
            let onlineCount = remote.filter { $0.state == .online }.count
            return PresenceStatus(title: onlineCount == 0 ? "Setup Needed" : "Partial", systemImage: "exclamationmark.circle", tone: .warning)
        }
        return PresenceStatus(title: "Configured", systemImage: "circle.dotted", tone: .muted)
    }

    private static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "there" : trimmed
    }

    private static func daypartGreeting(now: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: now)
        switch hour {
        case 5..<12:
            return "早上好"
        case 12..<18:
            return "下午好"
        case 18..<24:
            return "晚上好"
        default:
            return "还醒着呢"
        }
    }
}
