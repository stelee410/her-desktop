import Foundation

struct MemoryWritebackStatus: Identifiable, Equatable {
    var id: UUID
    var title: String
    var detail: String
    var status: String
    var taskID: String
    var createdAt: Date

    var icon: String {
        switch status {
        case "succeeded":
            return "checkmark.seal"
        case "failed", "check failed":
            return "exclamationmark.triangle"
        case "processing":
            return "hourglass"
        case "queued":
            return "clock"
        default:
            return "brain.head.profile"
        }
    }
}

struct MemoryWritebackStatusBuilder {
    private let limit: Int

    init(limit: Int = 4) {
        self.limit = limit
    }

    func build(from events: [AuditEvent]) -> [MemoryWritebackStatus] {
        events
            .filter(Self.isMemoryTaskEvent)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map(Self.status(from:))
    }

    private static func isMemoryTaskEvent(_ event: AuditEvent) -> Bool {
        [
            "memory.writeback_task_status",
            "memory.capability_writeback_task_status",
            "memory.writeback_task_check_failed",
            "memory.capability_writeback_task_check_failed"
        ].contains(event.type)
    }

    private static func status(from event: AuditEvent) -> MemoryWritebackStatus {
        let taskID = event.metadata["taskID"] ?? "unknown"
        let taskStatus = event.metadata["taskStatus"] ?? (event.type.hasSuffix("_failed") ? "check failed" : "unknown")
        let title: String
        if event.type.contains("capability") {
            title = event.metadata["capabilityID"].map { "Capability \($0)" } ?? "Capability writeback"
        } else {
            title = event.metadata["mode"].map { "\($0.capitalized) writeback" } ?? "Conversation writeback"
        }
        let detailParts = [
            event.summary,
            "task \(taskID)"
        ]
        return MemoryWritebackStatus(
            id: event.id,
            title: title,
            detail: detailParts.joined(separator: " · "),
            status: taskStatus,
            taskID: taskID,
            createdAt: event.createdAt
        )
    }
}
