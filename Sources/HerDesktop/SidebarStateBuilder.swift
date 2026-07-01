import Foundation

struct SidebarMemoryRowState: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var systemImage: String
}

struct SidebarStateBuilder {
    private let maxRows: Int

    init(maxRows: Int = 3) {
        self.maxRows = maxRows
    }

    func memoryRows(
        profile: AgentProfile,
        signal: MemorySignal,
        dreamContext: DreamPromptContext?,
        auditEvents: [AuditEvent]
    ) -> [SidebarMemoryRowState] {
        var rows: [SidebarMemoryRowState] = [
            relationshipRow(profile: profile),
            moodRow(signal: signal)
        ]

        if let writeback = MemoryWritebackStatusBuilder(limit: 1).build(from: auditEvents).first {
            rows.append(.init(
                id: "writeback",
                title: "Last writeback",
                subtitle: "\(writeback.status) · \(writeback.taskID)",
                systemImage: writeback.icon
            ))
        } else if let dream = dreamRow(dreamContext) {
            rows.append(dream)
        } else {
            rows.append(.init(
                id: "memory-scope",
                title: profile.known ? "AgentMem profile" : "Memory scope",
                subtitle: profile.memoryID.isEmpty ? "Memory-Key scoped context" : profile.memoryID,
                systemImage: "brain.head.profile"
            ))
        }

        return Array(rows.prefix(maxRows))
    }

    private func relationshipRow(profile: AgentProfile) -> SidebarMemoryRowState {
        SidebarMemoryRowState(
            id: "relationship",
            title: profile.known ? "Relationship" : "Getting acquainted",
            subtitle: profile.relationship,
            systemImage: profile.known ? "heart" : "person.crop.circle.badge.questionmark"
        )
    }

    private func moodRow(signal: MemorySignal) -> SidebarMemoryRowState {
        SidebarMemoryRowState(
            id: "mood",
            title: "Current mood signal",
            subtitle: "\(signal.moodLabel) · trust \(percent(signal.trust))",
            systemImage: "face.smiling"
        )
    }

    private func dreamRow(_ context: DreamPromptContext?) -> SidebarMemoryRowState? {
        guard let context else { return nil }
        let subtitle = context.recentInsight?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? context.longHorizonObjective?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "Compact companion context is active."
        return SidebarMemoryRowState(
            id: "reflection",
            title: "Reflection snapshot",
            subtitle: subtitle,
            systemImage: "moon.stars"
        )
    }

    private func percent(_ value: Double) -> String {
        "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
