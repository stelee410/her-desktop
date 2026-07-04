import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var config: HerAppConfig
    @Published var messages: [ChatMessage]
    @Published var connectionState: ConnectionState
    @Published var memorySignal: MemorySignal
    @Published var agentProfile: AgentProfile
    @Published var runningTasks: [RunningTask]
    @Published var tools: [ToolDescriptor]
    @Published var serviceHealth: [ServiceHealth]
    @Published var plugins: [PluginManifest]
    @Published var pendingApprovals: [PendingApproval]
    @Published var generatedPluginDrafts: [GeneratedPluginDraft]
    @Published var pluginEvents: [PluginLifecycleEvent]
    @Published var capabilityActivities: [CapabilityActivity]
    @Published var auditEvents: [AuditEvent]
    @Published var interactionEvents: [InteractionEvent]
    @Published var webServiceArtifacts: [WebServiceArtifact]
    @Published var dreamContext: DreamPromptContext?
    @Published var workPlan: WorkPlan?
    @Published var mcpDiscoveredTools: [MCPDiscoveredTool]
    @Published var pendingAttachments: [MessageAttachment]
    @Published var draft: String
    @Published var dictationTranscript: String
    @Published var lastError: String?
    @Published var localInboxBridgeState: LocalInboxBridgeState
    @Published var selectedSection: WorkspaceSection
    @Published var highlightedPluginID: String?
    @Published var pendingCapabilityRunTarget: CapabilityRunTarget?
    @Published var isVibePluginComposerPresented: Bool
    @Published var pendingVibePluginComposerPreset: VibePluginComposerPreset?
    @Published var conversations: [ConversationSummary]
    @Published var activeConversationID: String
    @Published var isInspectorPresented: Bool
    @Published var webApps: [WebAppManifest]
    @Published var selectedWebAppID: String?

    @Published var streamingAssistantMessageID: UUID?

    /// True while a reply is pending but no streamed bubble has appeared yet.
    var isAwaitingAssistantReply: Bool {
        connectionState == .thinking && streamingAssistantMessageID == nil
    }

    /// Items waiting on the user: capability approvals and plugin drafts.
    var pendingActionCount: Int {
        pendingApprovals.count + generatedPluginDrafts.count
    }

    var agentMem: AgentMemClient
    var agentLLM: any AgentLLMChatting
    var pluginRegistry: PluginRegistry
    var capabilityExecutor: CapabilityExecutor
    var conversationStore: ConversationStore
    var webAppStore: WebAppStore
    let webAppServer = LocalWebAppServer()
    let webAppProcessManager: WebAppProcessManager
    var auditStore: AuditEventStore
    var inboxEventStore: InboxEventStore
    var pluginEventStore: PluginEventStore
    var pluginDraftStore: PluginDraftStore
    var webServiceArtifactStore: WebServiceArtifactStore
    var workPlanStore: WorkPlanStore
    var attachmentStore: AttachmentStore
    let interactionEventBus: InteractionEventBus
    let localInboxBridgeServer: LocalInboxBridgeServer
    let speechSynthesizer: NativeSpeechSynthesizing
    let speechDictation: NativeSpeechDictating
    let urlSession: URLSession
    let allowsMissingLLMKeyForInjectedClient: Bool
    var serviceHealthVerifier: ServiceHealthVerifier
    var conversationContextBuilder: ConversationContextBuilder
    let runtimeCwd: String
    var sessionID: String { activeConversationID }
    var dictationTask: Task<Void, Never>?
    var dictationBaseText = ""
    var didBootstrapRuntime = false
    var bootstrapTask: Task<Void, Never>?

    init(
        config explicitConfig: HerAppConfig? = nil,
        cwd: String = HerWorkspacePaths.defaultRuntimeDirectory().path,
        agentLLM: (any AgentLLMChatting)? = nil,
        speechSynthesizer: NativeSpeechSynthesizing = MacSpeechSynthesizer(),
        speechDictation: NativeSpeechDictating = MacSpeechDictationService(),
        urlSession: URLSession = .shared
    ) {
        let loaded = explicitConfig ?? ConfigLoader.load(cwd: cwd)
        self.runtimeCwd = cwd
        self.config = loaded
        self.agentMem = AgentMemClient(config: loaded, session: urlSession)
        self.agentLLM = agentLLM ?? AgentLLMClient(config: loaded, session: urlSession)
        self.allowsMissingLLMKeyForInjectedClient = agentLLM != nil
        self.pluginRegistry = PluginRegistry(config: loaded, baseDirectory: cwd)
        self.speechSynthesizer = speechSynthesizer
        self.speechDictation = speechDictation
        self.urlSession = urlSession
        self.capabilityExecutor = CapabilityExecutor(
            registry: pluginRegistry,
            config: loaded,
            baseDirectory: cwd,
            speechSynthesizer: speechSynthesizer,
            urlSession: urlSession
        )
        let conversationStore = ConversationStore(cwd: cwd)
        self.conversationStore = conversationStore
        let webAppStore = WebAppStore(cwd: cwd)
        self.webAppStore = webAppStore
        self.webAppProcessManager = WebAppProcessManager(cwd: cwd)
        self.webApps = webAppStore.loadAll()
        self.selectedWebAppID = nil
        self.auditStore = AuditEventStore(cwd: cwd)
        self.inboxEventStore = InboxEventStore(cwd: cwd)
        self.pluginEventStore = PluginEventStore(cwd: cwd)
        self.webServiceArtifactStore = WebServiceArtifactStore(cwd: cwd)
        self.workPlanStore = WorkPlanStore(cwd: cwd)
        let pluginDraftStore = PluginDraftStore(cwd: cwd)
        self.pluginDraftStore = pluginDraftStore
        self.attachmentStore = AttachmentStore(cwd: cwd)
        self.interactionEventBus = InteractionEventBus()
        self.localInboxBridgeServer = LocalInboxBridgeServer()
        self.serviceHealthVerifier = ServiceHealthVerifier(config: loaded, session: urlSession)
        self.conversationContextBuilder = ConversationContextBuilder()
        let conversationBootstrap = conversationStore.bootstrap()
        self.conversations = conversationBootstrap.conversations
        self.activeConversationID = conversationBootstrap.activeConversationID
        let loadedPlugins = pluginRegistry.loadPlugins()
        let restoredMessages = conversationBootstrap.messages
        let restoredDrafts = (try? pluginDraftStore.loadAll()) ?? []
        let initialHealth = serviceHealthVerifier.initialSnapshot(pluginCount: loadedPlugins.count)
        self.serviceHealth = initialHealth
        self.plugins = loadedPlugins
        self.pendingApprovals = []
        self.generatedPluginDrafts = restoredDrafts
        self.pluginEvents = AppViewModel.recentPluginEvents(from: (try? pluginEventStore.loadAll()) ?? [])
        self.capabilityActivities = []
        self.auditEvents = AppViewModel.recentAuditEvents(from: (try? auditStore.loadAll()) ?? [])
        self.interactionEvents = AppViewModel.recentInteractionEvents(from: (try? inboxEventStore.loadAll()) ?? [])
        self.webServiceArtifacts = (try? webServiceArtifactStore.loadAll()) ?? []
        self.dreamContext = DreamPromptContextLoader.load(cwd: cwd)
        self.workPlan = (try? workPlanStore.load()) ?? nil
        self.mcpDiscoveredTools = []
        self.pendingAttachments = []
        self.messages = restoredMessages.isEmpty ? [
            ChatMessage(role: .assistant, content: loaded.hasLLMKey
                ? "我在这里。今天想从哪里开始？"
                : Self.firstRunSetupMessage(config: loaded))
        ] : restoredMessages
        self.connectionState = loaded.hasLLMKey ? .ready : .offline
        self.memorySignal = .empty
        self.agentProfile = .empty(userID: loaded.userID)
        self.runningTasks = []
        self.tools = AppViewModel.tools(from: initialHealth, model: loaded.agentLLMModel)
        self.draft = ""
        self.dictationTranscript = ""
        self.localInboxBridgeState = LocalInboxBridgeState()
        self.selectedSection = .today
        self.highlightedPluginID = nil
        self.pendingCapabilityRunTarget = nil
        self.isVibePluginComposerPresented = false
        self.pendingVibePluginComposerPreset = nil
        self.isInspectorPresented = false
        rebuildRunningTasks()
    }

    deinit {
        localInboxBridgeServer.stop()
        webAppServer.stop()
        webAppProcessManager.stopAll()
    }

    /// Launch bootstrap in a model-owned task. SwiftUI `.task` cancels its
    /// child work when the view identity changes during window setup, which
    /// used to abort the launch health check and strand readiness at
    /// "cancelled"; owning the task here detaches it from view lifetime.
    func startBootstrap() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { await bootstrapRuntime() }
    }

    func bootstrapRuntime() async {
        guard !didBootstrapRuntime else { return }
        didBootstrapRuntime = true
        refreshAuditEvents()
        refreshPluginEvents()
        refreshWebServiceArtifacts()
        refreshDreamContext()
        startWebAppServerIfNeeded()
        await reloadPlugins()
        await refreshServiceHealth()
    }

    func saveConfiguration(_ draft: HerAppConfigDraft) async {
        do {
            let updated = try draft.makeConfig()
            _ = try ConfigLoader.saveLocal(updated, cwd: runtimeCwd)
            applyConfiguration(updated)
            messages.append(ChatMessage(role: .assistant, content: configurationSavedMessage(config: updated)))
            audit(
                type: "config.saved",
                summary: "Local service configuration was updated.",
                metadata: [
                    "agentLLMBaseURL": updated.agentLLMBaseURL.absoluteString,
                    "agentLLMModel": updated.agentLLMModel,
                    "agentMemBaseURL": updated.agentMemBaseURL.absoluteString,
                    "hasLLMKey": String(updated.hasLLMKey),
                    "hasMemKey": String(updated.hasMemKey),
                    "pluginDirectory": HerWorkspacePaths.pluginDirectory(config: updated, cwd: runtimeCwd).path
                ]
            )
            saveSessionSnapshot()
            await refreshServiceHealth()
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Configuration Save Failed\n\(error.localizedDescription)"))
            audit(type: "config.save_failed", summary: error.localizedDescription)
            saveSessionSnapshot()
        }
    }

    var productReadinessSummary: ProductReadinessSummary {
        ProductReadinessBuilder.build(
            config: config,
            serviceHealth: serviceHealth,
            plugins: plugins,
            localInboxBridgeState: localInboxBridgeState,
            pendingApprovals: pendingApprovals,
            generatedDrafts: generatedPluginDrafts,
            workPlan: workPlan,
            dreamContext: dreamContext
        )
    }

    func performProductReadinessAction(_ action: ProductReadinessAction, openSettings: (() -> Void)? = nil) {
        switch action {
        case .openSettings:
            openSettings?()
        case .checkServices:
            Task { await refreshServiceHealth() }
        case .openPluginDirectory:
            openPluginDirectory()
        case .openToolsWorkspace:
            selectedSection = .tools
        case .composePlugin:
            selectedSection = .tools
            isVibePluginComposerPresented = true
        case .openProjectsWorkspace:
            selectedSection = .projects
        case .generateReflection:
            generateReflectionSnapshot()
        case .startInboxBridge:
            startLocalInboxBridge()
        case .runDiagnostics:
            Task { await runProductDiagnostics() }
        case .exportDiagnostics:
            Task { await requestProductDiagnosticsExport() }
        }
    }

    func appendReadinessGuidance() {
        messages.append(ChatMessage(role: .assistant, content: readinessGuidanceMessage()))
        saveSessionSnapshot()
    }

    func saveInlineAgentLLMKeyIfPresent(text: String, attachments: [MessageAttachment]) async -> Bool {
        guard !config.hasLLMKey,
              let key = SecretRedactor.firstAgentLLMAPIKey(in: text) else {
            return false
        }

        let redactedText = SecretRedactor.redact(text)
        let normalized = interactionEventBus.userMessage(text: redactedText, attachments: attachments)
        recordInteractionEvent(normalized.event)
        messages.append(ChatMessage(role: .user, content: normalized.displayText, attachments: attachments))

        do {
            var updated = config
            updated.agentLLMAPIKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try ConfigLoader.saveLocal(updated, cwd: runtimeCwd)
            applyConfiguration(updated)
            lastError = nil
            messages.append(ChatMessage(role: .assistant, content: inlineAgentLLMKeySavedMessage(hasAttachments: !attachments.isEmpty)))
            audit(
                type: "config.agentllm_key_saved_from_chat",
                summary: "AgentLLM API key was saved from a redacted chat message.",
                metadata: [
                    "agentLLMBaseURL": updated.agentLLMBaseURL.absoluteString,
                    "agentLLMModel": updated.agentLLMModel,
                    "hasAttachments": String(!attachments.isEmpty)
                ]
            )
            saveSessionSnapshot()
            await refreshServiceHealth()
        } catch {
            lastError = SecretRedactor.redact(error, config: config)
            messages.append(ChatMessage(role: .assistant, content: """
            我识别到了 AgentLLM API key，但保存本地配置时失败了：\(lastError ?? "Unknown error")

            请打开 Settings 保存一次；我不会把这条消息里的 key 明文写进聊天记录。
            """))
            audit(type: "config.agentllm_key_inline_save_failed", summary: lastError ?? error.localizedDescription)
            saveSessionSnapshot()
        }
        return true
    }

    static func firstRunSetupMessage(config: HerAppConfig) -> String {
        """
        我们先把入口收得很小：现在只需要配置 AgentLLM API key，就可以开始和我对话。

        打开 Settings，把 AgentLLM API key 填进去；base URL 保持 \(config.agentLLMBaseURL.absoluteString)，model 保持 \(config.agentLLMModel)，然后保存并检查。

        AgentMem、插件、MCP、语音这些都不是第一步。等聊天通路跑通后，我会在对话里一步步带你接上它们。
        """
    }

    func setSpeakAssistantReplies(_ enabled: Bool) {
        var updated = config
        updated.speakAssistantReplies = enabled
        do {
            _ = try ConfigLoader.saveLocal(updated, cwd: runtimeCwd)
            applyConfiguration(updated)
            messages.append(ChatMessage(
                role: .tool,
                content: enabled ? "Voice Replies Enabled\nAssistant replies will be spoken aloud." : "Voice Replies Disabled\nAssistant replies will stay silent."
            ))
            audit(
                type: "voice.reply_setting_changed",
                summary: enabled ? "Enabled assistant speech replies." : "Disabled assistant speech replies.",
                metadata: ["enabled": String(enabled)]
            )
            saveSessionSnapshot()
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Voice Setting Failed\n\(error.localizedDescription)"))
            audit(type: "voice.reply_setting_failed", summary: error.localizedDescription)
            saveSessionSnapshot()
        }
    }

    func applyConfiguration(_ updated: HerAppConfig) {
        config = updated
        agentMem = AgentMemClient(config: updated, session: urlSession)
        agentLLM = AgentLLMClient(config: updated, session: urlSession)
        pluginRegistry = PluginRegistry(config: updated, baseDirectory: runtimeCwd)
        capabilityExecutor = CapabilityExecutor(
            registry: pluginRegistry,
            config: updated,
            baseDirectory: runtimeCwd,
            speechSynthesizer: speechSynthesizer,
            urlSession: urlSession
        )
        auditStore = AuditEventStore(cwd: runtimeCwd)
        inboxEventStore = InboxEventStore(cwd: runtimeCwd)
        pluginEventStore = PluginEventStore(cwd: runtimeCwd)
        webServiceArtifactStore = WebServiceArtifactStore(cwd: runtimeCwd)
        workPlanStore = WorkPlanStore(cwd: runtimeCwd)
        serviceHealthVerifier = ServiceHealthVerifier(config: updated, session: urlSession)
        plugins = pluginRegistry.loadPlugins()
        serviceHealth = serviceHealthVerifier.initialSnapshot(pluginCount: plugins.count)
        tools = Self.tools(from: serviceHealth, model: updated.agentLLMModel)
        connectionState = updated.hasLLMKey ? .ready : .offline
        agentProfile = .empty(userID: updated.userID)
        refreshDreamContext()
        refreshWebServiceArtifacts()
        workPlan = (try? workPlanStore.load()) ?? nil
        rebuildRunningTasks()
    }

    func refreshPluginHealth() {
        serviceHealth.removeAll { $0.id == "plugins" }
        serviceHealth.append(ServiceHealth(
            id: "plugins",
            name: "Plugin Runtime",
            kind: "extension",
            baseURL: nil,
            state: .online,
            summary: "\(plugins.count) installed",
            checkedAt: Date()
        ))
    }

    func rebuildRunningTasks() {
        let remoteServices = serviceHealth.filter { $0.id == "agentllm" || $0.id == "agentmem" }
        let onlineServices = remoteServices.filter { $0.state == .online }.count
        let serviceProgress = remoteServices.isEmpty ? 0 : Double(onlineServices) / Double(remoteServices.count)
        let capabilityCount = plugins.flatMap(\.capabilities).count
        let draftCount = generatedPluginDrafts.count
        let approvalCount = pendingApprovals.count
        let activeCapabilityCount = capabilityActivities.filter { [.pending, .running].contains($0.status) }.count
        let planProgress = workPlan?.progress ?? 0
        let planState = workPlan?.stateSummary ?? "No current plan"
        let pluginState = draftCount > 0
            ? "\(capabilityCount) capabilities, \(draftCount) draft(s)"
            : "\(capabilityCount) capabilities"
        let capabilityActivityState: String
        if activeCapabilityCount > 0 {
            capabilityActivityState = "\(activeCapabilityCount) active"
        } else if let latest = capabilityActivities.first {
            capabilityActivityState = "\(latest.status.rawValue): \(latest.capabilityID)"
        } else {
            capabilityActivityState = "Idle"
        }

        runningTasks = [
            RunningTask(
                title: "Service connections",
                progress: serviceProgress,
                state: serviceProgress >= 1 ? "Verified" : "\(onlineServices)/\(max(remoteServices.count, 1)) online"
            ),
            RunningTask(
                title: "Plugin runtime",
                progress: plugins.isEmpty ? 0 : 1,
                state: pluginState
            ),
            RunningTask(
                title: "Approval queue",
                progress: approvalCount == 0 ? 1 : 0.45,
                state: approvalCount == 0 ? "Clear" : "\(approvalCount) pending"
            ),
            RunningTask(
                title: "Capability activity",
                progress: activeCapabilityCount == 0 ? 1 : 0.5,
                state: capabilityActivityState
            ),
            RunningTask(
                title: "Current plan",
                progress: workPlan == nil ? 0 : planProgress,
                state: planState
            ),
            RunningTask(
                title: "Local inbox bridge",
                progress: localInboxBridgeState.status == .running ? 1 : 0,
                state: localInboxBridgeState.status == .running ? localInboxBridgeState.endpoint : localInboxBridgeState.summary
            ),
            RunningTask(
                title: "Memory continuity",
                progress: agentProfile.known ? 1 : (config.hasMemKey ? 0.55 : 0.2),
                state: agentProfile.known ? "Known profile" : (config.hasMemKey ? "Ready to learn" : "Needs key")
            )
        ]
    }

    static func tools(from health: [ServiceHealth], model: String) -> [ToolDescriptor] {
        let llm = health.first { $0.id == "agentllm" }
        let mem = health.first { $0.id == "agentmem" }
        let plugins = health.first { $0.id == "plugins" }
        return [
            ToolDescriptor(
                id: "agentmem",
                name: "AgentMem",
                kind: "memory",
                summary: mem?.summary ?? "Unknown",
                enabled: mem?.state == .online || mem?.state == .unknown || mem?.state == .checking
            ),
            ToolDescriptor(
                id: "agentllm",
                name: "AgentLLM",
                kind: "model",
                summary: llm?.state == .online ? model : (llm?.summary ?? "Unknown"),
                enabled: llm?.state == .online || llm?.state == .unknown || llm?.state == .checking
            ),
            ToolDescriptor(id: "mcp", name: "MCP", kind: "extension", summary: "Plugin-ready", enabled: true),
            ToolDescriptor(
                id: "skills",
                name: "Skills",
                kind: "extension",
                summary: plugins?.summary ?? "0 installed",
                enabled: true
            )
        ]
    }

    func audit(type: String, summary: String, metadata: [String: String] = [:]) {
        do {
            let event = AuditEvent(type: type, summary: summary, metadata: metadata)
            try auditStore.append(event)
            auditEvents = Self.recentAuditEvents(from: auditEvents + [event])
        } catch {
            lastError = "Could not write audit log: \(error.localizedDescription)"
        }
    }

    func recordInteractionEvent(_ event: InteractionEvent) {
        interactionEvents = Self.recentInteractionEvents(from: interactionEvents + [event])
        if event.surface == .externalInbox {
            do {
                try inboxEventStore.append(event)
            } catch {
                audit(
                    type: "inbox.event_persist_failed",
                    summary: error.localizedDescription,
                    metadata: ["eventID": event.id.uuidString]
                )
            }
        }
        var metadata = event.payload
        metadata["eventID"] = event.id.uuidString
        metadata["surface"] = event.surface.rawValue
        metadata["kind"] = event.kind.rawValue
        metadata["attachmentCount"] = String(event.attachments.count)
        audit(
            type: "interaction.\(event.kind.rawValue)",
            summary: event.summary,
            metadata: metadata
        )
    }

    func openDirectory(_ url: URL, eventType: String) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
            audit(
                type: eventType,
                summary: "Opened directory in Finder.",
                metadata: ["path": url.path]
            )
        } catch {
            lastError = "Could not open directory: \(error.localizedDescription)"
            audit(
                type: "\(eventType)_failed",
                summary: error.localizedDescription,
                metadata: ["path": url.path]
            )
        }
    }

    func openFile(path: String, eventType: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "File does not exist: \(url.path)"
            audit(
                type: "\(eventType)_failed",
                summary: "File does not exist.",
                metadata: ["path": url.path]
            )
            return
        }
        NSWorkspace.shared.open(url)
        audit(
            type: eventType,
            summary: "Opened file.",
            metadata: ["path": url.path]
        )
    }

    static func recentAuditEvents(from events: [AuditEvent], limit: Int = 12) -> [AuditEvent] {
        Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    static func recentPluginEvents(from events: [PluginLifecycleEvent], limit: Int = 12) -> [PluginLifecycleEvent] {
        Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    static func recentInteractionEvents(from events: [InteractionEvent], limit: Int = 16) -> [InteractionEvent] {
        Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    static func standardizedFilePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }
}
