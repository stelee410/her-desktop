import Foundation

enum ProductReadinessLevel: String, Codable, Equatable {
    case ready
    case attention
    case optional
}

enum ProductReadinessAction: String, Codable, Equatable {
    case openSettings
    case checkServices
    case openPluginDirectory
    case openToolsWorkspace
    case openProjectsWorkspace
    case generateReflection
    case startInboxBridge
}

struct ProductReadinessItem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var level: ProductReadinessLevel
    var systemImage: String
    var required: Bool
    var actionTitle: String?
    var action: ProductReadinessAction?
}

struct ProductReadinessSummary: Equatable {
    var title: String
    var detail: String
    var score: String
    var readyRequiredCount: Int
    var requiredCount: Int
    var items: [ProductReadinessItem]

    var isReadyForCoreWork: Bool {
        readyRequiredCount == requiredCount
    }

    func suggestedActions(limit: Int = 3) -> [ProductReadinessItem] {
        Array(items.filter { item in
            item.action != nil && item.actionTitle != nil && item.level != .ready
        }.prefix(max(0, limit)))
    }
}

enum ProductReadinessBuilder {
    static func build(
        config: HerAppConfig,
        serviceHealth: [ServiceHealth],
        plugins: [PluginManifest],
        localInboxBridgeState: LocalInboxBridgeState,
        pendingApprovals: [PendingApproval],
        generatedDrafts: [GeneratedPluginDraft],
        workPlan: WorkPlan?,
        dreamContext: DreamPromptContext?
    ) -> ProductReadinessSummary {
        let items = [
            agentLLMItem(config: config, serviceHealth: serviceHealth),
            agentMemItem(config: config, serviceHealth: serviceHealth),
            pluginRuntimeItem(plugins: plugins),
            identityItem(config: config),
            reviewQueueItem(pendingApprovals: pendingApprovals, generatedDrafts: generatedDrafts),
            workPlanItem(workPlan: workPlan),
            reflectionItem(dreamContext: dreamContext),
            inboxBridgeItem(state: localInboxBridgeState),
            voiceItem(config: config)
        ]
        let required = items.filter(\.required)
        let readyRequired = required.filter { $0.level == .ready }.count
        let attention = items.filter { $0.level == .attention }
        let title: String
        let detail: String
        if readyRequired == required.count && attention.isEmpty {
            title = "Ready"
            detail = "Conversation, memory, plugins, and local continuity are in place."
        } else if readyRequired == required.count {
            title = "Core Ready"
            detail = "\(attention.count) non-blocking item(s) need attention."
        } else {
            title = "Setup Needed"
            detail = "\(required.count - readyRequired) required item(s) need attention before Her is fully useful."
        }
        return ProductReadinessSummary(
            title: title,
            detail: detail,
            score: "\(readyRequired)/\(required.count)",
            readyRequiredCount: readyRequired,
            requiredCount: required.count,
            items: items
        )
    }

    private static func agentLLMItem(config: HerAppConfig, serviceHealth: [ServiceHealth]) -> ProductReadinessItem {
        guard config.hasLLMKey else {
            return item(
                id: "agentllm",
                title: "AgentLLM",
                detail: "Add an AgentLLM API key in Settings.",
                level: .attention,
                systemImage: "sparkles",
                required: true,
                actionTitle: "Settings",
                action: .openSettings
            )
        }
        let health = serviceHealth.first { $0.id == "agentllm" }
        switch health?.state {
        case .online:
            return item(id: "agentllm", title: "AgentLLM", detail: health?.summary ?? "Online", level: .ready, systemImage: "sparkles", required: true)
        case .checking:
            return item(id: "agentllm", title: "AgentLLM", detail: "Health check is running.", level: .attention, systemImage: "arrow.triangle.2.circlepath", required: true)
        case .offline:
            return item(id: "agentllm", title: "AgentLLM", detail: health?.summary ?? "Offline", level: .attention, systemImage: "sparkles", required: true, actionTitle: "Check", action: .checkServices)
        case .unknown, nil:
            return item(id: "agentllm", title: "AgentLLM", detail: "Configured; run Check Services.", level: .attention, systemImage: "sparkles", required: true, actionTitle: "Check", action: .checkServices)
        }
    }

    private static func agentMemItem(config: HerAppConfig, serviceHealth: [ServiceHealth]) -> ProductReadinessItem {
        guard config.hasMemKey else {
            return item(
                id: "agentmem",
                title: "AgentMem",
                detail: "Add an AgentMem memory key in Settings.",
                level: .attention,
                systemImage: "brain.head.profile",
                required: true,
                actionTitle: "Settings",
                action: .openSettings
            )
        }
        let health = serviceHealth.first { $0.id == "agentmem" }
        switch health?.state {
        case .online:
            return item(id: "agentmem", title: "AgentMem", detail: health?.summary ?? "Online", level: .ready, systemImage: "brain.head.profile", required: true)
        case .checking:
            return item(id: "agentmem", title: "AgentMem", detail: "Health check is running.", level: .attention, systemImage: "arrow.triangle.2.circlepath", required: true)
        case .offline:
            return item(id: "agentmem", title: "AgentMem", detail: health?.summary ?? "Offline", level: .attention, systemImage: "brain.head.profile", required: true, actionTitle: "Check", action: .checkServices)
        case .unknown, nil:
            return item(id: "agentmem", title: "AgentMem", detail: "Configured; run Check Services.", level: .attention, systemImage: "brain.head.profile", required: true, actionTitle: "Check", action: .checkServices)
        }
    }

    private static func pluginRuntimeItem(plugins: [PluginManifest]) -> ProductReadinessItem {
        let capabilityCount = plugins.flatMap(\.capabilities).count
        guard !plugins.isEmpty, capabilityCount > 0 else {
            return item(
                id: "plugins",
                title: "Plugin Runtime",
                detail: "No installed capabilities were found.",
                level: .attention,
                systemImage: "puzzlepiece.extension",
                required: true,
                actionTitle: "Plugins",
                action: .openPluginDirectory
            )
        }
        return item(
            id: "plugins",
            title: "Plugin Runtime",
            detail: "\(plugins.count) plugin(s), \(capabilityCount) capability item(s).",
            level: .ready,
            systemImage: "puzzlepiece.extension",
            required: true
        )
    }

    private static func identityItem(config: HerAppConfig) -> ProductReadinessItem {
        let agentCode = config.agentCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = config.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = !agentCode.isEmpty && !userID.isEmpty
        return item(
            id: "identity",
            title: "Memory Identity",
            detail: ready ? "\(agentCode) for \(userID)" : "Set agent code and user id for stable memory scope.",
            level: ready ? .ready : .attention,
            systemImage: "person.crop.circle.badge.checkmark",
            required: true,
            actionTitle: ready ? nil : "Settings",
            action: ready ? nil : .openSettings
        )
    }

    private static func reviewQueueItem(
        pendingApprovals: [PendingApproval],
        generatedDrafts: [GeneratedPluginDraft]
    ) -> ProductReadinessItem {
        let count = pendingApprovals.count + generatedDrafts.count
        if count == 0 {
            return item(id: "reviews", title: "Review Queue", detail: "No pending approvals or plugin drafts.", level: .ready, systemImage: "checkmark.shield", required: false)
        }
        return item(
            id: "reviews",
            title: "Review Queue",
            detail: "\(pendingApprovals.count) approval(s), \(generatedDrafts.count) plugin draft(s) waiting.",
            level: .attention,
            systemImage: "hand.raised",
            required: false,
            actionTitle: "Review",
            action: .openToolsWorkspace
        )
    }

    private static func workPlanItem(workPlan: WorkPlan?) -> ProductReadinessItem {
        guard let workPlan else {
            return item(
                id: "workplan",
                title: "Work Plan",
                detail: "Optional; ask Her to create a plan for multi-step work.",
                level: .optional,
                systemImage: "list.bullet.clipboard",
                required: false,
                actionTitle: "Projects",
                action: .openProjectsWorkspace
            )
        }
        return item(id: "workplan", title: "Work Plan", detail: workPlan.stateSummary, level: .ready, systemImage: "list.bullet.clipboard", required: false)
    }

    private static func reflectionItem(dreamContext: DreamPromptContext?) -> ProductReadinessItem {
        guard let dreamContext else {
            return item(
                id: "reflection",
                title: "Reflection Snapshot",
                detail: "Optional; generate one to preserve long-horizon context.",
                level: .optional,
                systemImage: "moon.stars",
                required: false,
                actionTitle: "Snapshot",
                action: .generateReflection
            )
        }
        let objective = dreamContext.longHorizonObjective?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return item(
            id: "reflection",
            title: "Reflection Snapshot",
            detail: objective.isEmpty ? "Compact companion context is active." : objective,
            level: .ready,
            systemImage: "moon.stars",
            required: false
        )
    }

    private static func inboxBridgeItem(state: LocalInboxBridgeState) -> ProductReadinessItem {
        switch state.status {
        case .running:
            return item(id: "inbox", title: "Inbox Bridge", detail: state.endpoint, level: .ready, systemImage: "tray.and.arrow.down", required: false)
        case .failed:
            return item(id: "inbox", title: "Inbox Bridge", detail: state.summary, level: .attention, systemImage: "exclamationmark.triangle", required: false, actionTitle: "Retry", action: .startInboxBridge)
        case .starting:
            return item(id: "inbox", title: "Inbox Bridge", detail: "Starting local bridge.", level: .attention, systemImage: "arrow.triangle.2.circlepath", required: false)
        case .stopped:
            return item(id: "inbox", title: "Inbox Bridge", detail: "Optional external capture is stopped.", level: .optional, systemImage: "tray.and.arrow.down", required: false, actionTitle: "Start", action: .startInboxBridge)
        }
    }

    private static func voiceItem(config: HerAppConfig) -> ProductReadinessItem {
        if config.speakAssistantReplies {
            let voice = config.speechVoiceIdentifier.isEmpty ? "System voice" : config.speechVoiceIdentifier
            return item(id: "voice", title: "Spoken Replies", detail: voice, level: .ready, systemImage: "speaker.wave.2", required: false)
        }
        return item(id: "voice", title: "Spoken Replies", detail: "Optional; local TTS is off.", level: .optional, systemImage: "speaker.slash", required: false, actionTitle: "Settings", action: .openSettings)
    }

    private static func item(
        id: String,
        title: String,
        detail: String,
        level: ProductReadinessLevel,
        systemImage: String,
        required: Bool,
        actionTitle: String? = nil,
        action: ProductReadinessAction? = nil
    ) -> ProductReadinessItem {
        ProductReadinessItem(
            id: id,
            title: title,
            detail: detail,
            level: level,
            systemImage: systemImage,
            required: required,
            actionTitle: actionTitle,
            action: action
        )
    }
}
