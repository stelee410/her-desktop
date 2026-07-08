import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject, AuditRecording {
    @Published var config: HerAppConfig
    @Published var connectionState: ConnectionState
    @Published var memorySignal: MemorySignal
    @Published var agentProfile: AgentProfile
    @Published var plugins: [PluginManifest]
    @Published var pendingApprovals: [PendingApproval]
    @Published var generatedPluginDrafts: [GeneratedPluginDraft]

    // MARK: High-frequency state carved into sub-observables (see SubModels.swift)

    /// Service health / tools / running tasks live in their own observable so
    /// health refreshes don't repaint the whole window. The same-named
    /// computed passthroughs below keep all internal call sites unchanged;
    /// only views that display this state observe `serviceStatus`.
    let serviceStatus = ServiceStatusModel()
    /// Audit/interaction/capability/plugin feeds — appended on every tool
    /// step; displayed only by the inspector activity panes and workspaces.
    let activityFeed = ActivityFeedModel()
    /// The transcript/composer/conversation list — the hottest write path of
    /// all (每次流式 flush 都改 messages). Views of the conversation observe
    /// this; the rest of the window no longer repaints per token.
    let conversation = ConversationModel()

    var messages: [ChatMessage] {
        get { conversation.messages }
        set { conversation.messages = newValue }
    }
    var streamingAssistantMessageID: UUID? {
        get { conversation.streamingAssistantMessageID }
        set { conversation.streamingAssistantMessageID = newValue }
    }
    var isLoadingConversation: Bool {
        get { conversation.isLoadingConversation }
        set { conversation.isLoadingConversation = newValue }
    }
    var draft: String {
        get { conversation.draft }
        set { conversation.draft = newValue }
    }
    var pendingAttachments: [MessageAttachment] {
        get { conversation.pendingAttachments }
        set { conversation.pendingAttachments = newValue }
    }
    var conversations: [ConversationSummary] {
        get { conversation.conversations }
        set { conversation.conversations = newValue }
    }
    var activeConversationID: String {
        get { conversation.activeConversationID }
        set { conversation.activeConversationID = newValue }
    }
    var sortedConversations: [ConversationSummary] {
        conversation.sortedConversations
    }

    var runningTasks: [RunningTask] {
        get { serviceStatus.runningTasks }
        set { serviceStatus.runningTasks = newValue }
    }
    var tools: [ToolDescriptor] {
        get { serviceStatus.tools }
        set { serviceStatus.tools = newValue }
    }
    var serviceHealth: [ServiceHealth] {
        get { serviceStatus.serviceHealth }
        set { serviceStatus.serviceHealth = newValue }
    }
    var pluginEvents: [PluginLifecycleEvent] {
        get { activityFeed.pluginEvents }
        set { activityFeed.pluginEvents = newValue }
    }
    var capabilityActivities: [CapabilityActivity] {
        get { activityFeed.capabilityActivities }
        set { activityFeed.capabilityActivities = newValue }
    }
    var auditEvents: [AuditEvent] {
        get { activityFeed.auditEvents }
        set { activityFeed.auditEvents = newValue }
    }
    var interactionEvents: [InteractionEvent] {
        get { activityFeed.interactionEvents }
        set { activityFeed.interactionEvents = newValue }
    }
    var agentJobs: [AgentJob] {
        get { activityFeed.agentJobs }
        set { activityFeed.agentJobs = newValue }
    }
    @Published var webServiceArtifacts: [WebServiceArtifact] {
        didSet { messageScanVersion &+= 1 }
    }
    @Published var dreamContext: DreamPromptContext?
    @Published var workPlan: WorkPlan?
    @Published var mcpDiscoveredTools: [MCPDiscoveredTool]
    @Published var dictationTranscript: String
    @Published var lastError: String?
    @Published var localInboxBridgeState: LocalInboxBridgeState
    @Published var selectedSection: WorkspaceSection
    @Published var highlightedPluginID: String?
    @Published var pendingCapabilityRunTarget: CapabilityRunTarget?
    @Published var isVibePluginComposerPresented: Bool
    @Published var pendingVibePluginComposerPreset: VibePluginComposerPreset?
    /// Identity of the in-flight transcript load. Any path that sets
    /// `messages` directly (delete, new conversation) refreshes this token so
    /// a stale load can neither apply its result nor leave
    /// `isLoadingConversation` stuck true (which would silently disable all
    /// saves — see resetConversationScopedState()).
    var activeTranscriptLoadToken: UUID?
    /// Presentation-only toggles (inspector + drawers) live in their own small
    /// observable so flipping them doesn't invalidate every view that observes
    /// this large view model. See UIChrome.
    let chrome = UIChrome()
    /// Loaded once. SystemPromptBuilder's default parameter re-read the
    /// SOUL/INFINITI docs from disk (6 candidate files) on every single turn.
    let projectPromptDocs = ProjectPromptLoader.load()
    @Published var webApps: [WebAppManifest] {
        didSet { messageScanVersion &+= 1 }
    }
    @Published var selectedWebAppID: String?
    /// Bumped whenever webApps/webServiceArtifacts change; versions the
    /// per-message reference caches below.
    var messageScanVersion: Int = 0
    /// Memoized per-message content scans (web-app references / artifact
    /// links). These ran O(apps × contentLength) for EVERY message on EVERY
    /// render. Keyed by content length: message content only ever grows
    /// (streaming) or is immutable, so (id, length, version) identifies a scan.
    var messageReferenceCache: [UUID: MessageReferenceCacheEntry] = [:]

    struct MessageReferenceCacheEntry {
        var contentLength: Int
        var scanVersion: Int
        var webAppIDs: [String]?
        var artifactIDs: [String]?
    }
    /// When the user flips the drawer's autonomy toggle, browser side-effect
    /// actions skip per-action approval for the session (still visible +
    /// audited). The agent cannot grant this itself.
    @Published var browserAutonomyGranted: Bool
    /// Which browser the capabilities drive: a dedicated-profile Chrome
    /// (sidecar) or the user's everyday Chrome (via the loaded extension).
    @Published var browserTarget: BrowserTarget

    enum BrowserTarget: String, Codable { case sidecar, everyday }

    /// True while a reply is pending but no streamed bubble has appeared yet.
    var isAwaitingAssistantReply: Bool {
        connectionState == .thinking && streamingAssistantMessageID == nil
    }

    /// Items waiting on the user: capability approvals and plugin drafts.
    var pendingActionCount: Int {
        pendingApprovals.count + generatedPluginDrafts.count
    }
    /// Capabilities the user chose to auto-approve for the rest of this
    /// conversation ("一直批准"); cleared when the conversation changes.
    @Published var autoApprovedCapabilities: Set<String> = []

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
    /// Injected (tests) or the system AVSpeechSynthesizer.
    let baseSpeechSynthesizer: NativeSpeechSynthesizing
    /// Server-side TTS via AgentLLM; rebuilt on config changes.
    var agentLLMSpeechSynthesizer: AgentLLMSpeechSynthesizer
    /// The active TTS backend, resolved per config.
    var speechSynthesizer: NativeSpeechSynthesizing {
        config.speechSynthesisProvider == "agentllm" ? agentLLMSpeechSynthesizer : baseSpeechSynthesizer
    }
    /// Injected (tests) or the system SFSpeechRecognizer dictation.
    private let baseSpeechDictation: NativeSpeechDictating
    /// Server-side dictation via AgentLLM; rebuilt on config changes.
    var agentLLMDictationService: AgentLLMDictationService
    /// The active dictation backend, resolved per config.
    var speechDictation: NativeSpeechDictating {
        config.speechRecognitionProvider == "agentllm" ? agentLLMDictationService : baseSpeechDictation
    }
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
    /// The in-flight conversation turn, so the composer's stop button can
    /// cancel generation.
    var currentTurnTask: Task<Void, Never>?
    /// Messages typed while a turn is generating; the running tool loop drains
    /// these each round to steer itself (Codex-style guided mode).
    var steeringQueue: [String] = []
    /// Streaming deltas are buffered and flushed to `messages` on a short
    /// debounce, so the UI updates ~14x/sec instead of once per token
    /// (which re-rendered the whole window and made typing/scrolling lag).
    var streamBufferContent = ""
    var streamBufferReasoning = ""
    var streamFlushTimer: Timer?
    /// Roleplay assets (角色卡 / 世界之书), editable in their workspace
    /// pages and selectable per conversation. See AppViewModel+Roleplay.
    @Published var characterCards: [CharacterCard] = []
    @Published var worldBooks: [WorldBook] = []
    lazy var roleplayStore = RoleplayStore(cwd: runtimeCwd)
    /// Heartbeat: scheduled tasks (reminders / timed agent turns) checked by
    /// a periodic tick. See AppViewModel+Heartbeat.
    @Published var heartbeatTasks: [HeartbeatTask] = []
    var heartbeatTimer: Timer?
    lazy var heartbeatStore = HeartbeatTaskStore(cwd: runtimeCwd)
    /// The single background-job worker draining the queue (see +Jobs).
    var jobWorkerTask: Task<Void, Never>?
    /// In-flight TTS for the last reply; cancelled on conversation switch
    /// and shutdown so a previous conversation doesn't keep speaking.
    var speechTask: Task<Void, Never>?
    /// Live mic level for the composer waveform (own observable so ~15Hz
    /// updates never invalidate the conversation).
    let voiceLevel = VoiceLevelModel()
    /// Push-to-talk (hold Space) state — see AppViewModel+Voice.
    var pushToTalkMonitors: [Any] = []
    var spaceHoldPending = false
    var spaceHoldTask: Task<Void, Never>?
    var isPushToTalking = false
    /// Set by the composer's focus state; Space push-to-talk only engages
    /// when the composer owns focus (or nothing text-y does).
    var composerFocused = false
    /// Set by shutdown(); an already-in-flight heartbeat tick must not
    /// enqueue new jobs (and respawn the worker) after teardown began.
    var isShuttingDown = false
    /// Injected for tests; heartbeat notify tasks fire through this directly.
    let notificationScheduler: NativeNotificationScheduling

    /// True while a turn is generating and can be stopped.
    var isGenerating: Bool {
        connectionState == .thinking || connectionState == .working
    }
    /// finish_reason of the most recent model reply in the tool loop,
    /// used to explain empty replies (e.g. output truncated at "length").
    var lastAssistantFinishReason: String?
    /// Conversation-facing terminal surface; tests inject a fake.
    lazy var terminalBridge: TerminalBridging = terminalControllerInstance
    lazy var terminalControllerInstance = TerminalController()
    /// Track which lazy child-process owners were actually created, so
    /// shutdown() can stop them without instantiating unused ones at quit.
    private var browserControllerCreated = false
    private var browserExtensionServerCreated = false
    /// Conversation-facing browser surface. The dedicated-profile sidecar
    /// and the everyday-Chrome extension both conform to BrowserBridging, so
    /// capabilities are target-agnostic. Tests set `browserBridgeOverride`.
    lazy var browserControllerInstance: BrowserController = {
        browserControllerCreated = true
        return BrowserController(cwd: runtimeCwd)
    }()
    lazy var browserExtensionServer: BrowserExtensionServer = {
        browserExtensionServerCreated = true
        return BrowserExtensionServer()
    }()
    lazy var extensionBrowserBridge = ExtensionBrowserBridge(server: browserExtensionServer)
    var browserBridgeOverride: BrowserBridging?
    var browserBridge: BrowserBridging {
        get {
            browserBridgeOverride
                ?? (browserTarget == .everyday ? extensionBrowserBridge : browserControllerInstance)
        }
        set { browserBridgeOverride = newValue }
    }

    init(
        config explicitConfig: HerAppConfig? = nil,
        cwd: String = HerWorkspacePaths.defaultRuntimeDirectory().path,
        agentLLM: (any AgentLLMChatting)? = nil,
        speechSynthesizer: NativeSpeechSynthesizing = MacSpeechSynthesizer(),
        speechDictation: NativeSpeechDictating = MacSpeechDictationService(),
        notificationScheduler: NativeNotificationScheduling = UserNotificationScheduler(),
        urlSession: URLSession = .shared
    ) {
        let loaded = explicitConfig ?? ConfigLoader.load(cwd: cwd)
        self.runtimeCwd = cwd
        self.config = loaded
        self.agentMem = AgentMemClient(config: loaded, session: urlSession)
        self.agentLLM = agentLLM ?? AgentLLMClient(config: loaded, session: urlSession)
        self.allowsMissingLLMKeyForInjectedClient = agentLLM != nil
        self.pluginRegistry = PluginRegistry(config: loaded, baseDirectory: cwd)
        self.baseSpeechSynthesizer = speechSynthesizer
        self.agentLLMSpeechSynthesizer = AgentLLMSpeechSynthesizer(config: loaded, urlSession: urlSession)
        self.baseSpeechDictation = speechDictation
        self.agentLLMDictationService = AgentLLMDictationService(config: loaded, urlSession: urlSession)
        self.notificationScheduler = notificationScheduler
        self.urlSession = urlSession
        self.capabilityExecutor = CapabilityExecutor(
            registry: pluginRegistry,
            config: loaded,
            baseDirectory: cwd,
            // Resolve explicitly: the init parameter shadows the computed
            // provider-routing property here.
            speechSynthesizer: loaded.speechSynthesisProvider == "agentllm"
                ? agentLLMSpeechSynthesizer
                : speechSynthesizer,
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
        let loadedPlugins = pluginRegistry.loadPlugins()
        let restoredMessages = conversationBootstrap.messages
        let restoredDrafts = (try? pluginDraftStore.loadAll()) ?? []
        let initialHealth = serviceHealthVerifier.initialSnapshot(pluginCount: loadedPlugins.count)
        self.plugins = loadedPlugins
        self.pendingApprovals = []
        self.generatedPluginDrafts = restoredDrafts
        // Loaded by bootstrapRuntime() (refreshWebServiceArtifacts) right
        // after first paint — loading here too was duplicated startup work.
        self.webServiceArtifacts = []
        self.dreamContext = DreamPromptContextLoader.load(cwd: cwd)
        self.workPlan = (try? workPlanStore.load()) ?? nil
        self.mcpDiscoveredTools = []
        self.connectionState = loaded.hasLLMKey ? .ready : .offline
        self.memorySignal = .empty
        self.agentProfile = .empty(userID: loaded.userID)
        self.dictationTranscript = ""
        self.localInboxBridgeState = LocalInboxBridgeState()
        self.selectedSection = .today
        self.highlightedPluginID = nil
        self.pendingCapabilityRunTarget = nil
        self.isVibePluginComposerPresented = false
        self.pendingVibePluginComposerPreset = nil
        self.browserAutonomyGranted = false
        // Default to the user's everyday Chrome (via the extension): it uses
        // the real logged-in profile and trusted CDP input.
        self.browserTarget = .everyday
        if conversationBootstrap.activeTranscriptCorrupt {
            self.lastError = "对话存档无法读取，原文件已备份。新消息会存入全新的存档。"
        }
        // Sub-observable state (computed passthroughs need fully-initialized self).
        serviceStatus.serviceHealth = initialHealth
        serviceStatus.tools = AppViewModel.tools(from: initialHealth, model: loaded.agentLLMModel)
        // Event feeds are NOT loaded here: audit.jsonl (and friends) grow
        // without bound, and decoding them synchronously in init blocked
        // first paint. bootstrapRuntime() populates all three right after
        // launch (refreshAuditEvents / refreshPluginEvents /
        // refreshInteractionEvents).
        conversation.conversations = conversationBootstrap.conversations
        conversation.activeConversationID = conversationBootstrap.activeConversationID
        if conversationBootstrap.activeTranscriptCorrupt {
            conversation.messages = [Self.corruptTranscriptNotice(backup: conversationBootstrap.corruptTranscriptBackup)]
        } else {
            conversation.messages = restoredMessages.isEmpty ? [
                ChatMessage(
                    role: .assistant,
                    content: loaded.hasLLMKey
                        ? "我在这里。今天想从哪里开始？"
                        : Self.firstRunSetupMessage(config: loaded),
                    localOnly: true
                )
            ] : restoredMessages
        }
        rebuildRunningTasks()
    }

    deinit {
        localInboxBridgeServer.stop()
        webAppServer.stop()
        webAppProcessManager.stopAll()
        // BrowserController terminates its sidecar in its own deinit.
    }

    /// Explicit teardown for app quit. The root @StateObject is not reliably
    /// released on termination, so `deinit` never runs then — without this,
    /// node/python backends, the browser sidecar, and loopback listeners
    /// survive as orphan processes across quits. Called from the app
    /// delegate's `applicationWillTerminate`.
    func shutdown() {
        isShuttingDown = true
        removePushToTalkMonitors()
        stopHeartbeat()
        cancelQueuedJobs()
        speechTask?.cancel()
        baseSpeechSynthesizer.stop()
        agentLLMSpeechSynthesizer.stop()
        // Land any queued transcript/index/audit writes before exit.
        conversationStore.flushPendingIO()
        auditStore.flushPendingIO()
        localInboxBridgeServer.stop()
        webAppServer.stop()
        webAppProcessManager.stopAll()
        if browserControllerCreated {
            browserControllerInstance.stop()
        }
        if browserExtensionServerCreated {
            browserExtensionServer.stop()
        }
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
        refreshInteractionEvents()
        refreshWebServiceArtifacts()
        refreshDreamContext()
        startWebAppServerIfNeeded()
        startHeartbeat()
        loadRoleplayAssets()
        installPushToTalkMonitors()
        await reloadPlugins()
        await refreshServiceHealth()
    }

    func saveConfiguration(_ draft: HerAppConfigDraft) async {
        do {
            let updated = try draft.makeConfig()
            _ = try ConfigLoader.saveLocal(updated, cwd: runtimeCwd)
            applyConfiguration(updated)
            messages.append(ChatMessage(role: .assistant, content: configurationSavedMessage(config: updated), localOnly: true))
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
            messages.append(ChatMessage(role: .assistant, content: inlineAgentLLMKeySavedMessage(hasAttachments: !attachments.isEmpty), localOnly: true))
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
        agentLLMDictationService = AgentLLMDictationService(config: updated, urlSession: urlSession)
        agentLLMSpeechSynthesizer = AgentLLMSpeechSynthesizer(config: updated, urlSession: urlSession)
        // Preserve an injected (test) LLM client: rebuilding unconditionally
        // silently swapped a fake for a real network client mid-scenario.
        if !allowsMissingLLMKeyForInjectedClient {
            agentLLM = AgentLLMClient(config: updated, session: urlSession)
        }
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
        let event = AuditEvent(type: type, summary: summary, metadata: metadata)
        // In-memory feed updates immediately; the disk append runs on the
        // store's serial queue (audit fires on every message and tool step —
        // it used to do a synchronous open/seek/write on the main actor).
        auditEvents = Self.recentAuditEvents(from: auditEvents + [event])
        auditStore.enqueueAppend(event) { error in
            Task { @MainActor [weak self] in
                self?.lastError = "Could not write audit log: \(error.localizedDescription)"
            }
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
