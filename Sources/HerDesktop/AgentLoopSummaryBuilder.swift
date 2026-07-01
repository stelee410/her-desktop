import Foundation

enum AgentLoopPhase: String, CaseIterable, Equatable {
    case observe = "Observe"
    case plan = "Plan"
    case act = "Act"
    case reflect = "Reflect"
}

struct AgentLoopStep: Identifiable, Equatable {
    var id: AgentLoopPhase { phase }
    var phase: AgentLoopPhase
    var status: String
    var detail: String
    var isActive: Bool
}

struct AgentLoopSummaryBuilder {
    func build(
        events: [InteractionEvent],
        activities: [CapabilityActivity],
        pendingApprovals: [PendingApproval],
        generatedDrafts: [GeneratedPluginDraft],
        workPlan: WorkPlan? = nil,
        connectionState: ConnectionState
    ) -> [AgentLoopStep] {
        [
            observeStep(events: events, connectionState: connectionState),
            planStep(
                pendingApprovals: pendingApprovals,
                generatedDrafts: generatedDrafts,
                workPlan: workPlan,
                connectionState: connectionState
            ),
            actStep(activities: activities, connectionState: connectionState),
            reflectStep(events: events, activities: activities)
        ]
    }

    private func observeStep(events: [InteractionEvent], connectionState: ConnectionState) -> AgentLoopStep {
        guard let event = events.first else {
            return .init(
                phase: .observe,
                status: "Idle",
                detail: "Waiting for text, voice, file, or inbox input.",
                isActive: connectionState == .listening
            )
        }
        return .init(
            phase: .observe,
            status: event.surface.rawValue.capitalized,
            detail: compact(event.summary, limit: 96),
            isActive: connectionState == .listening || event.kind == .userMessage
        )
    }

    private func planStep(
        pendingApprovals: [PendingApproval],
        generatedDrafts: [GeneratedPluginDraft],
        workPlan: WorkPlan?,
        connectionState: ConnectionState
    ) -> AgentLoopStep {
        if !pendingApprovals.isEmpty {
            return .init(
                phase: .plan,
                status: "Needs approval",
                detail: "\(pendingApprovals.count) capability request(s) waiting for review.",
                isActive: true
            )
        }
        if !generatedDrafts.isEmpty {
            return .init(
                phase: .plan,
                status: "Draft ready",
                detail: "\(generatedDrafts.count) generated plugin draft(s) ready for review.",
                isActive: true
            )
        }
        if let workPlan {
            return .init(
                phase: .plan,
                status: "Current plan",
                detail: "\(compact(workPlan.goal, limit: 72)) - \(workPlan.stateSummary)",
                isActive: workPlan.progress < 1
            )
        }
        if connectionState == .thinking {
            return .init(
                phase: .plan,
                status: "Thinking",
                detail: "Building the next response or tool plan.",
                isActive: true
            )
        }
        return .init(
            phase: .plan,
            status: "Ready",
            detail: "No pending approvals or generated drafts.",
            isActive: false
        )
    }

    private func actStep(activities: [CapabilityActivity], connectionState: ConnectionState) -> AgentLoopStep {
        if let active = activities.first(where: { $0.status == .running || $0.status == .pending }) {
            return .init(
                phase: .act,
                status: active.status.rawValue.capitalized,
                detail: "\(active.title): \(compact(active.summary, limit: 96))",
                isActive: true
            )
        }
        if let latest = activities.first {
            return .init(
                phase: .act,
                status: latest.status.rawValue.capitalized,
                detail: "\(latest.title): \(compact(latest.summary, limit: 96))",
                isActive: connectionState == .working
            )
        }
        return .init(
            phase: .act,
            status: "Idle",
            detail: "No tool or plugin execution yet.",
            isActive: connectionState == .working
        )
    }

    private func reflectStep(events: [InteractionEvent], activities: [CapabilityActivity]) -> AgentLoopStep {
        if let completed = activities.first(where: { $0.status == .done || $0.status == .failed || $0.status == .denied }) {
            return .init(
                phase: .reflect,
                status: completed.status == .done ? "Captured" : completed.status.rawValue.capitalized,
                detail: compact(completed.summary, limit: 110),
                isActive: false
            )
        }
        if events.contains(where: { $0.kind == .approvalApproved || $0.kind == .approvalRejected }) {
            return .init(
                phase: .reflect,
                status: "Approval logged",
                detail: "Recent approval decision is in the audit trail.",
                isActive: false
            )
        }
        return .init(
            phase: .reflect,
            status: "Ready",
            detail: "Results, memory writeback, and audit notes will collect here.",
            isActive: false
        )
    }

    private func compact(_ text: String, limit: Int) -> String {
        let clean = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let end = clean.index(clean.startIndex, offsetBy: max(0, limit - 1))
        return "\(clean[..<end])..."
    }
}
