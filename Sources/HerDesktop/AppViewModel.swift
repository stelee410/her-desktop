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
    @Published var mcpDiscoveredTools: [MCPDiscoveredTool]
    @Published var pendingAttachments: [MessageAttachment]
    @Published var draft: String
    @Published var dictationTranscript: String
    @Published var lastError: String?
    @Published var localInboxBridgeState: LocalInboxBridgeState
    @Published var selectedSection: WorkspaceSection

    private var agentMem: AgentMemClient
    private var agentLLM: any AgentLLMChatting
    private var pluginRegistry: PluginRegistry
    private var capabilityExecutor: CapabilityExecutor
    private var sessionStore: SessionStore
    private var auditStore: AuditEventStore
    private var inboxEventStore: InboxEventStore
    private var pluginEventStore: PluginEventStore
    private var pluginDraftStore: PluginDraftStore
    private var webServiceArtifactStore: WebServiceArtifactStore
    private var attachmentStore: AttachmentStore
    private let interactionEventBus: InteractionEventBus
    private let localInboxBridgeServer: LocalInboxBridgeServer
    private let speechSynthesizer: NativeSpeechSynthesizing
    private let speechDictation: NativeSpeechDictating
    private let urlSession: URLSession
    private var serviceHealthVerifier: ServiceHealthVerifier
    private var conversationContextBuilder: ConversationContextBuilder
    private let runtimeCwd: String
    private let sessionID: String
    private var dictationTask: Task<Void, Never>?
    private var dictationBaseText = ""

    init(
        config explicitConfig: HerAppConfig? = nil,
        cwd: String = FileManager.default.currentDirectoryPath,
        agentLLM: (any AgentLLMChatting)? = nil,
        speechSynthesizer: NativeSpeechSynthesizing = MacSpeechSynthesizer(),
        speechDictation: NativeSpeechDictating = MacSpeechDictationService(),
        urlSession: URLSession = .shared
    ) {
        let loaded = explicitConfig ?? ConfigLoader.load(cwd: cwd)
        self.runtimeCwd = cwd
        self.config = loaded
        self.agentMem = AgentMemClient(config: loaded)
        self.agentLLM = agentLLM ?? AgentLLMClient(config: loaded)
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
        let sessionStore = SessionStore(cwd: cwd)
        self.sessionStore = sessionStore
        self.auditStore = AuditEventStore(cwd: cwd)
        self.inboxEventStore = InboxEventStore(cwd: cwd)
        self.pluginEventStore = PluginEventStore(cwd: cwd)
        self.webServiceArtifactStore = WebServiceArtifactStore(cwd: cwd)
        let pluginDraftStore = PluginDraftStore(cwd: cwd)
        self.pluginDraftStore = pluginDraftStore
        self.attachmentStore = AttachmentStore(cwd: cwd)
        self.interactionEventBus = InteractionEventBus()
        self.localInboxBridgeServer = LocalInboxBridgeServer()
        self.serviceHealthVerifier = ServiceHealthVerifier(config: loaded)
        self.conversationContextBuilder = ConversationContextBuilder()
        self.sessionID = sessionStore.loadOrCreateSessionID()
        let loadedPlugins = pluginRegistry.loadPlugins()
        let restoredMessages = (try? sessionStore.load()) ?? []
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
        self.mcpDiscoveredTools = []
        self.pendingAttachments = []
        self.messages = restoredMessages.isEmpty ? [
            ChatMessage(role: .assistant, content: "我在这里。今天想从哪里开始？")
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
        rebuildRunningTasks()
    }

    deinit {
        localInboxBridgeServer.stop()
    }

    func saveConfiguration(_ draft: HerAppConfigDraft) async {
        do {
            let updated = try draft.makeConfig()
            _ = try ConfigLoader.saveLocal(updated, cwd: runtimeCwd)
            applyConfiguration(updated)
            messages.append(ChatMessage(role: .tool, content: "Configuration Saved\nLocal service configuration was updated."))
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

    func newLocalConversation() {
        stopDictation()
        recordInteractionEvent(interactionEventBus.event(
            surface: .mac,
            kind: .localSessionStarted,
            summary: "Started a new local conversation transcript.",
            payload: ["sessionID": sessionID]
        ))
        messages = [ChatMessage(role: .assistant, content: "新会话已经准备好。我们从哪里开始？")]
        pendingApprovals = []
        capabilityActivities = []
        pendingAttachments = []
        draft = ""
        dictationTranscript = ""
        lastError = nil
        connectionState = config.hasLLMKey ? .ready : .offline
        rebuildRunningTasks()
        audit(
            type: "session.new_conversation",
            summary: "Started a new local conversation transcript.",
            metadata: ["sessionID": sessionID]
        )
        saveSessionSnapshot()
    }

    func clearComposer() {
        draft = ""
        pendingAttachments = []
        dictationTranscript = ""
        lastError = nil
    }

    func openLocalAgentDirectory() {
        openDirectory(HerWorkspacePaths.localAgentDirectory(cwd: runtimeCwd), eventType: "workspace.open_her_directory")
    }

    func openWorkspaceArtifactsDirectory() {
        openDirectory(HerWorkspacePaths.workspaceDirectory(cwd: runtimeCwd), eventType: "workspace.open_artifacts_directory")
    }

    func openWebServiceArtifactDirectory() {
        openDirectory(
            HerWorkspacePaths.webServiceArtifactDirectory(cwd: runtimeCwd),
            eventType: "workspace.open_webservice_artifacts_directory"
        )
    }

    func openWebServiceArtifact(path: String) {
        openFile(path: path, eventType: "workspace.open_webservice_artifact")
    }

    func webServiceArtifacts(for message: ChatMessage) -> [WebServiceArtifact] {
        let manifestPaths = WebServiceArtifactReferenceExtractor.manifestPaths(in: message.content)
        guard !manifestPaths.isEmpty else { return [] }
        let wanted = Set(manifestPaths.map(Self.standardizedFilePath))
        return webServiceArtifacts.filter { wanted.contains(Self.standardizedFilePath($0.manifestPath)) }
    }

    func openPluginDirectory() {
        openDirectory(HerWorkspacePaths.pluginDirectory(config: config, cwd: runtimeCwd), eventType: "workspace.open_plugin_directory")
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        pendingAttachments = []
        await send(text, attachments: attachments)
    }

    func send(_ text: String, attachments: [MessageAttachment] = []) async {
        let normalized = interactionEventBus.userMessage(text: text, attachments: attachments)
        recordInteractionEvent(normalized.event)
        messages.append(ChatMessage(role: .user, content: normalized.displayText, attachments: attachments))
        connectionState = .thinking
        lastError = nil

        do {
            let memContext = try await retrieveMemory(for: normalized.contextText)
            let prompt = SystemPromptBuilder(pluginManifests: plugins).build(
                memoryContext: memContext,
                activeTaskSummary: activeTaskSummary(),
                agentLoopSummary: agentLoopSummary(),
                runtimeContext: PromptRuntimeContext.current(config: config, cwd: runtimeCwd),
                companionContext: companionPromptContext()
            )
            let catalog = CapabilityToolCatalog.build(from: plugins)
            var llmMessages = conversationContextBuilder.build(systemPrompt: prompt, messages: messages)
            let reply = try await runAgentToolLoop(llmMessages: &llmMessages, catalog: catalog)
            let final = reply.isEmpty ? "我收到啦，但这次模型没有返回正文。" : reply
            messages.append(ChatMessage(role: .assistant, content: final))
            connectionState = .ready
            saveSessionSnapshot()
            Task { await persistTurnMemory(userInput: normalized.contextText, agentResponse: final, attachments: attachments) }
            Task { await speakAssistantReplyIfEnabled(final) }
        } catch {
            connectionState = .error
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "我这边连接底座服务时遇到问题：\(error.localizedDescription)"))
            saveSessionSnapshot()
        }
    }

    func attachFiles(_ urls: [URL]) {
        var imported: [MessageAttachment] = []
        var failures: [String] = []
        for url in urls {
            do {
                imported.append(try attachmentStore.importFile(url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !imported.isEmpty {
            recordInteractionEvent(interactionEventBus.event(
                surface: .files,
                kind: .attachmentsImported,
                summary: "Imported \(imported.count) attachment(s).",
                payload: [
                    "count": String(imported.count),
                    "names": imported.map(\.displayName).joined(separator: ", ")
                ],
                attachments: imported
            ))
            pendingAttachments.append(contentsOf: imported)
            let names = imported.map(\.displayName).joined(separator: ", ")
            messages.append(ChatMessage(role: .tool, content: "Attachments Added\n\(names)"))
            audit(
                type: "attachments.imported",
                summary: "Imported \(imported.count) attachment(s).",
                metadata: [
                    "count": String(imported.count),
                    "names": names
                ]
            )
        }

        if !failures.isEmpty {
            recordInteractionEvent(interactionEventBus.event(
                surface: .files,
                kind: .attachmentImportFailed,
                summary: failures.joined(separator: " | "),
                payload: ["count": String(failures.count)]
            ))
            lastError = failures.joined(separator: "\n")
            messages.append(ChatMessage(role: .tool, content: "Attachment Import Failed\n\(lastError ?? "")"))
            audit(
                type: "attachments.import_failed",
                summary: failures.joined(separator: " | "),
                metadata: ["count": String(failures.count)]
            )
        }

        if !imported.isEmpty || !failures.isEmpty {
            saveSessionSnapshot()
        }
    }

    func removePendingAttachment(_ attachment: MessageAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func toggleDictation() {
        if connectionState == .listening {
            stopDictation()
        } else {
            startDictation()
        }
    }

    func startDictation(localeIdentifier: String = Locale.current.identifier) {
        guard connectionState != .listening else { return }
        dictationTask?.cancel()
        dictationBaseText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationTranscript = ""
        connectionState = .listening
        lastError = nil
        audit(
            type: "voice.dictation_started",
            summary: "Started local macOS speech dictation.",
            metadata: ["locale": localeIdentifier]
        )
        recordInteractionEvent(interactionEventBus.event(
            surface: .voice,
            kind: .voiceDictationStarted,
            summary: "Started local macOS speech dictation.",
            payload: ["locale": localeIdentifier]
        ))
        dictationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let final = try await self.speechDictation.start(localeIdentifier: localeIdentifier) { partial in
                    self.applyDictationTranscript(partial)
                }
                self.applyDictationTranscript(final)
                self.audit(
                    type: "voice.dictation_finished",
                    summary: "Finished local macOS speech dictation.",
                    metadata: ["characters": String(final.count)]
                )
                self.recordInteractionEvent(self.interactionEventBus.event(
                    surface: .voice,
                    kind: .voiceDictationFinished,
                    summary: "Finished local macOS speech dictation.",
                    payload: ["characters": String(final.count)]
                ))
            } catch {
                self.lastError = error.localizedDescription
                self.audit(
                    type: "voice.dictation_failed",
                    summary: error.localizedDescription,
                    metadata: ["locale": localeIdentifier]
                )
                self.recordInteractionEvent(self.interactionEventBus.event(
                    surface: .voice,
                    kind: .voiceDictationFailed,
                    summary: error.localizedDescription,
                    payload: ["locale": localeIdentifier]
                ))
            }
            if self.connectionState == .listening {
                self.connectionState = self.config.hasLLMKey ? .ready : .offline
            }
            self.dictationTask = nil
            self.saveSessionSnapshot()
        }
    }

    func stopDictation() {
        speechDictation.stop()
    }

    private func applyDictationTranscript(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationTranscript = clean
        guard !clean.isEmpty else { return }
        draft = dictationBaseText.isEmpty ? clean : "\(dictationBaseText)\n\(clean)"
    }

    private func runAgentToolLoop(
        llmMessages: inout [AgentLLMMessage],
        catalog: CapabilityToolCatalog,
        maxToolRounds: Int = 5
    ) async throws -> String {
        for round in 0...maxToolRounds {
            let message = try await agentLLM.chat(messages: llmMessages, tools: catalog.tools)
            let toolCalls = message.toolCalls ?? []
            guard !toolCalls.isEmpty else {
                return message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            guard round < maxToolRounds else {
                return "我已经连续执行了 \(maxToolRounds) 轮工具调用，先停在这里，避免在没有你确认的情况下继续扩张任务。"
            }

            llmMessages.append(.assistant(content: message.content, toolCalls: toolCalls))
            var needsApproval = false
            for toolCall in toolCalls {
                let result = await handleToolCall(toolCall, catalog: catalog)
                llmMessages.append(.toolResult(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    content: result.content
                ))
                needsApproval = needsApproval || result.needsApproval
            }
            await reloadPlugins()

            if needsApproval {
                return "我已经把需要你批准的操作放进审批队列里。你批准后，我会基于工具结果继续推进。"
            }
        }
        return "我已经到达本轮工具调用上限，先把当前状态停住。"
    }

    private func handleToolCall(
        _ toolCall: AgentLLMChatResponse.Choice.Message.ToolCall,
        catalog: CapabilityToolCatalog
    ) async -> ToolCallHandlingResult {
        let capabilityID = catalog.functionToCapability[toolCall.function.name] ?? toolCall.function.name
        let invocation = CapabilityInvocation(
            toolCallID: toolCall.id,
            functionName: toolCall.function.name,
            capabilityID: capabilityID,
            arguments: parseArguments(toolCall.function.arguments)
        )
        if requiresApproval(capabilityID: capabilityID) {
            let approval = enqueueApproval(for: invocation)
            messages.append(ChatMessage(role: .tool, content: "Approval Required\n\(approval.title)\n\(approval.detail)"))
            return ToolCallHandlingResult(
                content: "Pending user approval in Her Desktop. Approval id: \(approval.id.uuidString).",
                needsApproval: true
            )
        }

        let activityID = beginCapabilityActivity(
            invocation: invocation,
            status: .running,
            summary: "Executing without additional approval."
        )
        let result = await executeCapabilityInvocation(invocation)
        finishCapabilityActivity(activityID, result: result)
        refreshWebServiceArtifacts()
        captureExternalInboxEventIfNeeded(invocation: invocation, result: result)
        captureGeneratedPluginDraft(from: result, source: toolCall.function.name)
        captureInstalledPluginIfNeeded(invocation: invocation, result: result, approved: false)
        captureRemovedPluginIfNeeded(invocation: invocation, result: result, approved: false)
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        auditCapabilityExecution(invocation: invocation, result: result, approved: false)
        Task {
            await persistCapabilityMemory(invocation: invocation, result: result, approved: false)
        }
        return ToolCallHandlingResult(content: result.content, needsApproval: false)
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

    func installGeneratedPluginDraft(_ draft: GeneratedPluginDraft) async {
        do {
            let existingIDs = plugins.map(\.id).filter { $0 != draft.manifest.id }
            try PluginPackageValidator().validate(draft.package, existingPluginIDs: existingIDs)
            let updatingExisting = plugins.contains { $0.id == draft.manifest.id }
            try pluginRegistry.install(package: draft.package, replacingExisting: updatingExisting)
            generatedPluginDrafts.removeAll { $0.id == draft.id }
            try? pluginDraftStore.delete(draft)
            messages.append(ChatMessage(
                role: .tool,
                content: pluginInstalledContent(
                    package: draft.package,
                    source: "generated draft",
                    title: updatingExisting ? "Plugin Updated" : "Plugin Installed",
                    verb: updatingExisting ? "Updated" : "Installed"
                )
            ))
            auditPluginEvent(
                type: updatingExisting ? "plugin.updated" : "plugin.installed",
                package: draft.package,
                summary: updatingExisting ? "Updated generated plugin draft." : "Installed generated plugin draft.",
                metadata: ["source": draft.source]
            )
            saveSessionSnapshot()
            await reloadPlugins()
            rebuildRunningTasks()
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Install Failed\n\(error.localizedDescription)"))
            audit(
                type: "plugin.install_failed",
                summary: error.localizedDescription,
                metadata: ["pluginID": draft.manifest.id, "source": draft.source]
            )
            saveSessionSnapshot()
        }
    }

    func discardGeneratedPluginDraft(_ draft: GeneratedPluginDraft) {
        generatedPluginDrafts.removeAll { $0.id == draft.id }
        try? pluginDraftStore.delete(draft)
        messages.append(ChatMessage(
            role: .tool,
            content: "Plugin Draft Discarded\n\(draft.manifest.name) (\(draft.manifest.id)) was not installed."
        ))
        auditPluginEvent(
            type: "plugin.draft_discarded",
            package: draft.package,
            summary: "Discarded generated plugin draft.",
            metadata: ["source": draft.source]
        )
        rebuildRunningTasks()
        saveSessionSnapshot()
    }

    func stageGeneratedPluginPackage(_ package: PluginPackage, source: String = "plugin.draft") {
        let removedDrafts = generatedPluginDrafts.filter { $0.manifest.id == package.manifest.id }
        removedDrafts.forEach { try? pluginDraftStore.delete($0) }
        generatedPluginDrafts.removeAll { $0.manifest.id == package.manifest.id }
        let draft = GeneratedPluginDraft(package: package, source: source)
        generatedPluginDrafts.append(draft)
        do {
            try pluginDraftStore.save(draft)
        } catch {
            lastError = "Could not persist plugin draft: \(error.localizedDescription)"
            audit(
                type: "plugin.draft_persist_failed",
                summary: error.localizedDescription,
                metadata: ["pluginID": package.manifest.id, "source": source]
            )
        }
        auditPluginEvent(
            type: "plugin.draft_staged",
            package: package,
            summary: "Staged plugin package for review.",
            metadata: ["source": source]
        )
        rebuildRunningTasks()
    }

    func reloadPlugins() async {
        plugins = pluginRegistry.loadPlugins()
        refreshPluginHealth()
        tools = Self.tools(from: serviceHealth, model: config.agentLLMModel)
        rebuildRunningTasks()
    }

    func refreshServiceHealth() async {
        serviceHealth = serviceHealthVerifier.checkingSnapshot(pluginCount: plugins.count)
        tools = Self.tools(from: serviceHealth, model: config.agentLLMModel)
        let checked = await serviceHealthVerifier.checkAll(pluginCount: plugins.count)
        serviceHealth = checked
        tools = Self.tools(from: checked, model: config.agentLLMModel)
        await refreshAgentProfile()
        rebuildRunningTasks()
    }

    func refreshAuditEvents() {
        do {
            auditEvents = Self.recentAuditEvents(from: try auditStore.loadAll())
        } catch {
            lastError = "Could not load audit log: \(error.localizedDescription)"
        }
    }

    func refreshPluginEvents() {
        do {
            pluginEvents = Self.recentPluginEvents(from: try pluginEventStore.loadAll())
        } catch {
            lastError = "Could not load plugin lifecycle log: \(error.localizedDescription)"
        }
    }

    func refreshWebServiceArtifacts() {
        do {
            webServiceArtifacts = try webServiceArtifactStore.loadAll()
        } catch {
            lastError = "Could not load web service artifacts: \(error.localizedDescription)"
        }
    }

    func refreshDreamContext() {
        dreamContext = DreamPromptContextLoader.load(cwd: runtimeCwd)
    }

    func generateReflectionSnapshot() {
        let result = saveReflectionSnapshot(focus: "")
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        saveSessionSnapshot()
    }

    @discardableResult
    private func saveReflectionSnapshot(focus: String) -> CapabilityResult {
        let context = DreamReflectionBuilder().build(
            messages: messages,
            tasks: runningTasks,
            activities: capabilityActivities,
            interactionEvents: interactionEvents,
            pluginEvents: pluginEvents,
            profile: agentProfile,
            memorySignal: memorySignal,
            focus: focus
        )
        do {
            let url = try DreamPromptContextStore.save(context, cwd: runtimeCwd)
            dreamContext = context
            audit(
                type: "dream.reflection_saved",
                summary: "Saved local companion reflection snapshot.",
                metadata: [
                    "path": url.path,
                    "behaviorGuidanceCount": String(context.behaviorGuidance.count),
                    "unresolvedThreadCount": String(context.unresolvedThreads.count),
                    "cautionCount": String(context.cautions.count)
                ]
            )
            return CapabilityResult(
                title: "Reflection Snapshot Saved",
                content: """
                Updated compressed companion context at \(url.path).
                guidance: \(context.behaviorGuidance.count)
                open_threads: \(context.unresolvedThreads.count)
                cautions: \(context.cautions.count)
                """,
                requiresUserApproval: false
            )
        } catch {
            lastError = "Could not save reflection snapshot: \(error.localizedDescription)"
            audit(type: "dream.reflection_save_failed", summary: error.localizedDescription)
            return CapabilityResult(
                title: "Reflection Snapshot Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func startLocalInboxBridge(port: UInt16? = nil) {
        let resolvedPort = port ?? localInboxBridgeState.port
        localInboxBridgeState.status = .starting
        localInboxBridgeState.port = resolvedPort
        localInboxBridgeState.summary = "Starting"
        do {
            try localInboxBridgeServer.start(port: resolvedPort) { [weak self] message in
                await self?.captureLocalInboxBridgeMessage(message)
            }
            localInboxBridgeState.status = .running
            localInboxBridgeState.summary = "Listening on \(localInboxBridgeState.endpoint)"
            audit(
                type: "inbox.bridge_started",
                summary: "Started local HTTP inbox bridge.",
                metadata: ["endpoint": localInboxBridgeState.endpoint]
            )
        } catch {
            localInboxBridgeState.status = .failed
            localInboxBridgeState.summary = error.localizedDescription
            lastError = "Could not start local inbox bridge: \(error.localizedDescription)"
            audit(
                type: "inbox.bridge_start_failed",
                summary: error.localizedDescription,
                metadata: ["port": String(resolvedPort)]
            )
        }
        rebuildRunningTasks()
    }

    func stopLocalInboxBridge() {
        localInboxBridgeServer.stop()
        localInboxBridgeState.status = .stopped
        localInboxBridgeState.summary = "Stopped"
        audit(
            type: "inbox.bridge_stopped",
            summary: "Stopped local HTTP inbox bridge.",
            metadata: ["endpoint": localInboxBridgeState.endpoint]
        )
        rebuildRunningTasks()
    }

    func captureQuickInboxMessage(text: String, url: String = "", source: String = "quick-capture", sender: String = "") {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        captureLocalInboxBridgeMessage(LocalInboxMessage(
            source: source,
            sender: sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? config.userID : sender,
            text: cleanText,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            receivedAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    func refreshAgentProfile() async {
        guard config.hasMemKey else {
            agentProfile = .empty(userID: config.userID)
            memorySignal.relationshipSummary = agentProfile.relationship
            return
        }
        do {
            let object = try await agentMem.relationship()
            let profile = AgentProfile.fromRelationshipPayload(object, fallbackUserID: config.userID)
            agentProfile = profile
            memorySignal.relationshipSummary = profile.relationship
            if profile.known {
                memorySignal.moodLabel = "Familiar"
            }
            rebuildRunningTasks()
        } catch {
            lastError = "Could not refresh AgentMem profile: \(error.localizedDescription)"
        }
    }

    func runCapability(_ capability: PluginManifest.Capability, request: String) async {
        await runCapability(capabilityID: capability.id, request: request)
    }

    func runCapability(capabilityID: String, request: String) async {
        let cleanRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        await runCapability(
            capabilityID: capabilityID,
            arguments: cleanRequest.isEmpty ? [:] : ["request": cleanRequest],
            requestCharacters: cleanRequest.count
        )
    }

    func runCapability(_ capability: PluginManifest.Capability, arguments: [String: Any]) async {
        await runCapability(capabilityID: capability.id, arguments: arguments)
    }

    func runCapability(capabilityID: String, arguments: [String: Any]) async {
        await runCapability(capabilityID: capabilityID, arguments: arguments, requestCharacters: argumentCharacterCount(arguments))
    }

    private func runCapability(capabilityID: String, arguments: [String: Any], requestCharacters: Int) async {
        guard pluginRegistry.capability(id: capabilityID, in: plugins) != nil else {
            let message = "Capability \(capabilityID) is not installed."
            lastError = message
            messages.append(ChatMessage(role: .tool, content: "Capability Missing\n\(message)"))
            saveSessionSnapshot()
            return
        }

        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .manualCapabilityRequested,
            summary: "Manual capability run requested.",
            payload: [
                "capabilityID": capabilityID,
                "requestCharacters": String(requestCharacters)
            ]
        ))
        let invocation = CapabilityInvocation(
            toolCallID: "manual-\(UUID().uuidString)",
            functionName: CapabilityToolCatalog.functionName(for: capabilityID),
            capabilityID: capabilityID,
            arguments: arguments
        )

        if requiresApproval(capabilityID: capabilityID) {
            let approval = enqueueApproval(for: invocation)
            messages.append(ChatMessage(
                role: .tool,
                content: "Approval Required\n\(approval.title)\n\(approval.detail)"
            ))
            saveSessionSnapshot()
            return
        }

        connectionState = .working
        lastError = nil
        let activityID = beginCapabilityActivity(
            invocation: invocation,
            status: .running,
            summary: "Manual run from Plugin Library."
        )
        let result = await executeCapabilityInvocation(invocation)
        finishCapabilityActivity(activityID, result: result)
        refreshWebServiceArtifacts()
        captureExternalInboxEventIfNeeded(invocation: invocation, result: result)
        captureGeneratedPluginDraft(from: result, source: invocation.functionName)
        captureInstalledPluginIfNeeded(invocation: invocation, result: result, approved: false)
        captureRemovedPluginIfNeeded(invocation: invocation, result: result, approved: false)
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        auditCapabilityExecution(invocation: invocation, result: result, approved: false)
        Task {
            await persistCapabilityMemory(invocation: invocation, result: result, approved: false)
        }
        saveSessionSnapshot()
        await reloadPlugins()
        connectionState = .ready
    }

    private func argumentCharacterCount(_ arguments: [String: Any]) -> Int {
        arguments.values.reduce(0) { partial, value in
            partial + String(describing: value).count
        }
    }

    func installDraftPlugin(
        named name: String,
        description: String,
        kind: String = "skill",
        requiresApproval: Bool = true,
        webServiceURL: String = "",
        webServiceMethod: String = "POST",
        mcpEndpointURL: String = "",
        mcpMethodName: String = "",
        mcpToolName: String = "",
        mcpInputSchemaJSON: String = "",
        commandPath: String = "",
        commandArguments: String = ""
    ) async {
        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .pluginDraftRequested,
            summary: "Install local vibe plugin draft.",
            payload: [
                "name": name,
                "kind": kind,
                "requiresApproval": String(requiresApproval)
            ]
        ))
        let package = makeDraftPluginPackage(
            named: name,
            description: description,
            kind: kind,
            requiresApproval: requiresApproval,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            mcpInputSchemaJSON: mcpInputSchemaJSON,
            commandPath: commandPath,
            commandArguments: commandArguments
        )
        do {
            try PluginPackageValidator().validate(package, existingPluginIDs: plugins.map(\.id))
            try pluginRegistry.install(package: package)
            messages.append(ChatMessage(
                role: .tool,
                content: pluginInstalledContent(package: package, source: "the vibe composer")
            ))
            auditPluginEvent(
                type: "plugin.installed",
                package: package,
                summary: "Installed plugin from local vibe composer.",
                metadata: ["source": "vibe-composer"]
            )
            saveSessionSnapshot()
            await reloadPlugins()
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Install Failed\n\(error.localizedDescription)"))
            audit(type: "plugin.install_failed", summary: error.localizedDescription)
            saveSessionSnapshot()
        }
    }

    func removePlugin(_ plugin: PluginManifest) async {
        await removePlugin(pluginID: plugin.id)
    }

    func exportPlugin(_ plugin: PluginManifest) {
        exportPlugin(pluginID: plugin.id)
    }

    func exportPlugin(pluginID: String) {
        do {
            let package = try pluginRegistry.package(pluginID: pluginID)
            let directory = HerWorkspacePaths.pluginExportDirectory(cwd: runtimeCwd)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "\(package.manifest.id).plugin-package.json"
            let destination = directory.appendingPathComponent(fileName)
            try JSONEncoder.pretty.encode(package).write(to: destination, options: .atomic)
            messages.append(ChatMessage(
                role: .tool,
                content: "Plugin Exported\n\(package.manifest.name) (\(package.manifest.id)) was exported to \(destination.path)."
            ))
            auditPluginEvent(
                type: "plugin.exported",
                package: package,
                summary: "Exported local plugin package.",
                metadata: [
                    "path": destination.path,
                    "source": "plugin-library"
                ]
            )
            saveSessionSnapshot()
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Export Failed\n\(error.localizedDescription)"))
            audit(
                type: "plugin.export_failed",
                summary: error.localizedDescription,
                metadata: ["pluginID": pluginID]
            )
            saveSessionSnapshot()
        }
    }

    func removePlugin(pluginID: String) async {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            let message = "Plugin \(pluginID) is not installed."
            lastError = message
            messages.append(ChatMessage(role: .tool, content: "Plugin Remove Failed\n\(message)"))
            audit(type: "plugin.remove_failed", summary: message, metadata: ["pluginID": pluginID])
            saveSessionSnapshot()
            return
        }

        do {
            try pluginRegistry.remove(pluginID: pluginID)
            pendingApprovals.removeAll { $0.invocation.capabilityID.hasPrefix(pluginID + ".") }
            messages.append(ChatMessage(
                role: .tool,
                content: "Plugin Removed\n\(plugin.name) (\(plugin.id)) was removed from the local plugin directory."
            ))
            audit(
                type: "plugin.removed",
                summary: "Removed local plugin \(plugin.name).",
                metadata: [
                    "pluginID": plugin.id,
                    "pluginName": plugin.name,
                    "capabilityCount": String(plugin.capabilities.count)
                ]
            )
            recordPluginLifecycleEvent(
                action: .removed,
                manifest: plugin,
                fileCount: 0,
                source: "plugin-library",
                summary: "Removed local plugin \(plugin.name)."
            )
            saveSessionSnapshot()
            await reloadPlugins()
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Remove Failed\n\(error.localizedDescription)"))
            audit(
                type: "plugin.remove_failed",
                summary: error.localizedDescription,
                metadata: ["pluginID": pluginID]
            )
            saveSessionSnapshot()
        }
    }

    func stageDraftPlugin(
        named name: String,
        description: String,
        kind: String = "skill",
        requiresApproval: Bool = true,
        webServiceURL: String = "",
        webServiceMethod: String = "POST",
        mcpEndpointURL: String = "",
        mcpMethodName: String = "",
        mcpToolName: String = "",
        mcpInputSchemaJSON: String = "",
        commandPath: String = "",
        commandArguments: String = ""
    ) {
        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .pluginDraftRequested,
            summary: "Stage local vibe plugin draft.",
            payload: [
                "name": name,
                "kind": kind,
                "requiresApproval": String(requiresApproval)
            ]
        ))
        let package = makeDraftPluginPackage(
            named: name,
            description: description,
            kind: kind,
            requiresApproval: requiresApproval,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            mcpInputSchemaJSON: mcpInputSchemaJSON,
            commandPath: commandPath,
            commandArguments: commandArguments
        )
        do {
            try PluginPackageValidator().validate(package, existingPluginIDs: plugins.map(\.id))
            stageGeneratedPluginPackage(package, source: "vibe-composer")
            messages.append(ChatMessage(
                role: .tool,
                content: "Plugin Draft Created\nCreated \(package.manifest.name) (\(package.manifest.id)) for review."
            ))
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Draft Failed\n\(error.localizedDescription)"))
            audit(type: "plugin.draft_failed", summary: error.localizedDescription)
        }
        saveSessionSnapshot()
    }

    func discoverMCPTools(endpointURL: String) async {
        let cleanURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .manualCapabilityRequested,
            summary: "Discover local MCP bridge tools.",
            payload: ["url": cleanURL]
        ))
        connectionState = .working
        lastError = nil
        do {
            let response = try await MCPBridgeDiscoveryClient(urlSession: urlSession)
                .discover(rawURL: cleanURL, requestID: "mcp_composer_discover")
            mcpDiscoveredTools = response.tools
            messages.append(ChatMessage(
                role: .tool,
                content: "MCP Tool Discovery Result\n\(response.displayContent)"
            ))
            audit(
                type: "mcp.tools_discovered",
                summary: "Discovered \(response.tools.count) tool(s) from local MCP bridge.",
                metadata: [
                    "url": cleanURL,
                    "toolCount": String(response.tools.count)
                ]
            )
            connectionState = config.hasLLMKey ? .ready : .offline
        } catch {
            mcpDiscoveredTools = []
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "MCP Tool Discovery Failed\n\(error.localizedDescription)"))
            audit(
                type: "mcp.tools_discovery_failed",
                summary: error.localizedDescription,
                metadata: ["url": cleanURL]
            )
            connectionState = .error
        }
        saveSessionSnapshot()
    }

    func clearMCPDiscoveredTools() {
        mcpDiscoveredTools = []
    }

    func stageMCPDiscoveredToolPlugin(
        _ tool: MCPDiscoveredTool,
        endpointURL: String,
        name: String = "",
        description: String = "",
        requiresApproval: Bool = true
    ) {
        let cleanURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else {
            lastError = "MCP endpoint URL is required before drafting a plugin."
            messages.append(ChatMessage(role: .tool, content: "MCP Plugin Draft Failed\n\(lastError ?? "")"))
            saveSessionSnapshot()
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        stageDraftPlugin(
            named: cleanName.isEmpty ? pluginName(forMCPToolName: tool.name) : cleanName,
            description: cleanDescription.isEmpty ? mcpToolDescription(tool) : cleanDescription,
            kind: "mcp",
            requiresApproval: requiresApproval,
            mcpEndpointURL: cleanURL,
            mcpMethodName: "tools/call",
            mcpToolName: tool.name,
            mcpInputSchemaJSON: tool.rawInputSchema
        )
    }

    @discardableResult
    func stagePluginPackageJSON(_ text: String, source: String = "pasted-package") -> Bool {
        do {
            let decoded = try PluginPackageJSONExtractor().decodePackage(from: text)
            let package = PluginPackageReviewDocumenter().documented(decoded)
            let existingIDs = plugins.map(\.id).filter { $0 != package.manifest.id }
            try PluginPackageValidator().validate(package, existingPluginIDs: existingIDs)
            recordInteractionEvent(interactionEventBus.event(
                surface: .pluginLibrary,
                kind: .pluginPackageImported,
                summary: "Imported plugin package JSON.",
                payload: [
                    "source": source,
                    "pluginID": package.manifest.id,
                    "capabilityCount": String(package.manifest.capabilities.count)
                ]
            ))
            stageGeneratedPluginPackage(package, source: source)
            messages.append(ChatMessage(
                role: .tool,
                content: "Plugin Package Imported\nImported \(package.manifest.name) (\(package.manifest.id)) for review."
            ))
            saveSessionSnapshot()
            return true
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Package Import Failed\n\(error.localizedDescription)"))
            audit(
                type: "plugin.package_import_failed",
                summary: error.localizedDescription,
                metadata: ["source": source]
            )
            saveSessionSnapshot()
            return false
        }
    }

    func generateAIDraftPlugin(
        named name: String,
        description: String,
        kind: String = "skill",
        requiresApproval: Bool = true,
        webServiceURL: String = "",
        webServiceMethod: String = "POST",
        mcpEndpointURL: String = "",
        mcpMethodName: String = "",
        mcpToolName: String = "",
        mcpInputSchemaJSON: String = "",
        commandPath: String = "",
        commandArguments: String = "",
        vibeBrief: String = "",
        installImmediately: Bool = false
    ) async {
        guard config.hasLLMKey else {
            lastError = ServiceError.missingAPIKey("AgentLLM").localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "需要先配置 AgentLLM API key，才能用 AI 生成插件草稿。"))
            saveSessionSnapshot()
            return
        }

        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .pluginDraftRequested,
            summary: "Generate AgentLLM vibe plugin draft.",
            payload: [
                "name": name,
                "kind": kind,
                "requiresApproval": String(requiresApproval),
                "installImmediately": String(installImmediately)
            ]
        ))
        connectionState = .thinking
        lastError = nil
        let request = VibePluginPackageRequest(
            name: name,
            description: description,
            kind: kind,
            requiresApproval: requiresApproval,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            mcpInputSchemaJSON: mcpInputSchemaJSON,
            commandPath: commandPath,
            commandArguments: commandArguments,
            vibeBrief: vibeBrief
        )
        let promptBuilder = VibePluginPackagePromptBuilder()
        let existingPluginIDs = plugins.map(\.id)
        let llmMessages = promptBuilder.build(
            request: request,
            existingPluginIDs: existingPluginIDs
        )

        do {
            let response = try await agentLLM.chat(messages: llmMessages, tools: [])
            let content = response.content ?? ""
            let generation = try await validatedAIGeneratedPluginPackage(
                content: content,
                request: request,
                existingPluginIDs: existingPluginIDs,
                promptBuilder: promptBuilder
            )
            let package = generation.package
            let updatingExisting = plugins.contains { $0.id == package.manifest.id }
            if generation.repaired {
                auditPluginEvent(
                    type: "plugin.ai_generation_repaired",
                    package: package,
                    summary: "Repaired AgentLLM-generated plugin package after validation feedback.",
                    metadata: ["source": "agentllm-vibe-composer"]
                )
            }
            if installImmediately {
                try pluginRegistry.install(package: package, replacingExisting: updatingExisting)
                messages.append(ChatMessage(
                    role: .tool,
                    content: pluginInstalledContent(
                        package: package,
                        source: "an AgentLLM-generated package",
                        title: updatingExisting ? "AI Plugin Updated" : "AI Plugin Installed",
                        verb: updatingExisting ? "Updated" : "Installed"
                    )
                ))
                auditPluginEvent(
                    type: updatingExisting ? "plugin.updated" : "plugin.installed",
                    package: package,
                    summary: updatingExisting ? "Updated AgentLLM-generated plugin package." : "Installed AgentLLM-generated plugin package.",
                    metadata: ["source": "agentllm-vibe-composer"]
                )
                await reloadPlugins()
            } else {
                stageGeneratedPluginPackage(package, source: "agentllm-vibe-composer")
                messages.append(ChatMessage(
                    role: .tool,
                    content: generation.repaired
                        ? "AI Plugin Draft Created\nCreated \(package.manifest.name) (\(package.manifest.id)) for review after one repair pass."
                        : "AI Plugin Draft Created\nCreated \(package.manifest.name) (\(package.manifest.id)) for review."
                ))
            }
            connectionState = .ready
            saveSessionSnapshot()
        } catch {
            connectionState = .error
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "AI 生成插件草稿时遇到问题：\(error.localizedDescription)"))
            audit(type: "plugin.ai_generation_failed", summary: error.localizedDescription)
            saveSessionSnapshot()
        }
    }

    private func validatedAIGeneratedPluginPackage(
        content: String,
        request: VibePluginPackageRequest,
        existingPluginIDs: [String],
        promptBuilder: VibePluginPackagePromptBuilder
    ) async throws -> AIGeneratedPluginPackage {
        do {
            return try AIGeneratedPluginPackage(package: validatedPluginPackage(from: content), repaired: false)
        } catch let initialError {
            let repairMessages = promptBuilder.repair(
                request: request,
                existingPluginIDs: existingPluginIDs,
                invalidResponse: content,
                errorMessage: initialError.localizedDescription
            )
            let repairedResponse = try await agentLLM.chat(messages: repairMessages, tools: [])
            let repairedContent = repairedResponse.content ?? ""
            do {
                return try AIGeneratedPluginPackage(package: validatedPluginPackage(from: repairedContent), repaired: true)
            } catch let repairError {
                throw AIPluginGenerationRepairError(
                    initialError: initialError.localizedDescription,
                    repairError: repairError.localizedDescription
                )
            }
        }
    }

    private func validatedPluginPackage(from content: String) throws -> PluginPackage {
        let decoded = try PluginPackageJSONExtractor().decodePackage(from: content)
        let package = PluginPackageReviewDocumenter().documented(decoded)
        let existingIDs = plugins.map(\.id).filter { $0 != package.manifest.id }
        try PluginPackageValidator().validate(package, existingPluginIDs: existingIDs)
        return package
    }

    private func pluginName(forMCPToolName toolName: String) -> String {
        let words = toolName
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(4)
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
        let base = words.isEmpty ? "MCP Tool" : words.joined(separator: " ")
        return "\(base) MCP"
    }

    private func mcpToolDescription(_ tool: MCPDiscoveredTool) -> String {
        let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        return "Calls the \(tool.name) MCP tool through a local bridge."
    }

    private func makeDraftPluginPackage(
        named name: String,
        description: String,
        kind: String,
        requiresApproval: Bool,
        webServiceURL: String,
        webServiceMethod: String,
        mcpEndpointURL: String,
        mcpMethodName: String,
        mcpToolName: String,
        mcpInputSchemaJSON: String,
        commandPath: String,
        commandArguments: String
    ) -> PluginPackage {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Plugin" : name
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A conversationally generated extension." : description
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "skill" : kind.lowercased()
        let effectiveRequiresApproval = cleanKind == "command" ? true : requiresApproval
        let resolvedSlug = PluginIdentifierBuilder.makeSlug(
            name: cleanName,
            description: cleanDescription,
            existingPluginIDs: Set(plugins.map(\.id) + generatedPluginDrafts.map(\.manifest.id))
        )
        let adapter = draftAdapter(
            kind: cleanKind,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            commandPath: commandPath,
            commandArguments: commandArguments
        )
        let manifest = PluginManifest(
            id: "local.\(resolvedSlug)",
            name: cleanName,
            version: "0.1.0",
            description: cleanDescription,
            author: "Vibe coded",
            systemPromptAddendum: "This plugin was created from a conversational design request. Keep behavior narrow and ask for approval before external side effects.",
            capabilities: [
                .init(
                    id: "local.\(resolvedSlug).run",
                    title: "Run \(cleanName)",
                    kind: cleanKind,
                    invocation: "local.\(resolvedSlug).run",
                    requiresApproval: effectiveRequiresApproval,
                    description: cleanDescription,
                    inputSchema: draftInputSchema(kind: cleanKind, mcpInputSchemaJSON: mcpInputSchemaJSON),
                    adapter: adapter
                )
            ]
        )
        let capability = manifest.capabilities[0]
        let contract = draftAdapterDocumentation(capability: capability, adapter: adapter)
        return PluginPackage(
            manifest: manifest,
            files: [
                .init(
                    path: "SKILL.md",
                    content: """
                    # \(cleanName)

                    \(cleanDescription)

                    ## Capability

                    - id: local.\(resolvedSlug).run
                    - kind: \(cleanKind)
                    - approval required: \(effectiveRequiresApproval)

                    ## Adapter Contract

                    \(contract)

                    ## Operating Notes

                    Use this plugin only for the declared capability. Keep the output grounded in the user's request, explain external side effects before they happen, and respect Her Desktop's approval gate.
                    """
                ),
                .init(
                    path: "README.md",
                    content: """
                    # \(cleanName)

                    \(cleanDescription)

                    Generated by Her Desktop's vibe plugin composer.

                    ## Capability Contract

                    \(contract)
                    """
                )
            ]
        )
    }

    private func draftAdapterDocumentation(
        capability: PluginManifest.Capability,
        adapter: PluginManifest.CapabilityAdapter?
    ) -> String {
        var capability = capability
        capability.adapter = adapter
        return PluginCapabilityContractFormatter().documentation(capability: capability)
    }

    private func draftInputSchema(kind: String, mcpInputSchemaJSON: String) -> [String: JSONValue] {
        if kind.lowercased() == "mcp",
           let schema = supportedMCPInputSchema(from: mcpInputSchemaJSON) {
            return schema
        }
        return defaultDraftInputSchema(kind: kind)
    }

    private func defaultDraftInputSchema(kind: String) -> [String: JSONValue] {
        let requestDescription: String
        switch kind.lowercased() {
        case "webservice":
            requestDescription = "Request or payload instructions for the web service."
        case "mcp":
            requestDescription = "Request to send through the local MCP bridge."
        case "command":
            requestDescription = "User input passed into the fixed command template."
        case "native":
            requestDescription = "Request for the native macOS adapter."
        default:
            requestDescription = "User request for this capability."
        }
        return [
            "type": .string("object"),
            "properties": .object([
                "request": .object([
                    "type": .string("string"),
                    "description": .string(requestDescription)
                ])
            ]),
            "required": .array([.string("request")])
        ]
    }

    private func supportedMCPInputSchema(from rawJSON: String) -> [String: JSONValue]? {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let schema = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case let .object(properties)? = schema["properties"],
              !properties.isEmpty else {
            return nil
        }

        let required = requiredFieldNames(from: schema["required"])
        let orderedNames = required + properties.keys.sorted().filter { !required.contains($0) }
        var sanitizedProperties: [String: JSONValue] = [:]
        var sanitizedRequired: [JSONValue] = []

        for name in orderedNames {
            guard isSafeInputFieldName(name),
                  case let .object(fieldSchema)? = properties[name],
                  let field = sanitizedInputFieldSchema(fieldSchema) else {
                continue
            }
            sanitizedProperties[name] = .object(field)
            if required.contains(name) {
                sanitizedRequired.append(.string(name))
            }
        }

        guard !sanitizedProperties.isEmpty else { return nil }
        var result: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(sanitizedProperties)
        ]
        if !sanitizedRequired.isEmpty {
            result["required"] = .array(sanitizedRequired)
        }
        return result
    }

    private func sanitizedInputFieldSchema(_ schema: [String: JSONValue]) -> [String: JSONValue]? {
        guard case let .string(type)? = schema["type"],
              ["string", "number", "integer", "boolean"].contains(type) else {
            return nil
        }
        var result: [String: JSONValue] = ["type": .string(type)]
        if case let .string(description)? = schema["description"], !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["description"] = .string(description)
        }
        if type == "string",
           case let .array(values)? = schema["enum"] {
            let enumValues = values.compactMap { value -> JSONValue? in
                guard case let .string(text) = value,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .string(text)
            }
            if !enumValues.isEmpty {
                result["enum"] = .array(enumValues)
            }
        }
        return result
    }

    private func requiredFieldNames(from value: JSONValue?) -> [String] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap { item in
            guard case let .string(text) = item else { return nil }
            return text
        }
    }

    private func isSafeInputFieldName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    private func draftAdapter(
        kind: String,
        webServiceURL: String,
        webServiceMethod: String,
        mcpEndpointURL: String,
        mcpMethodName: String,
        mcpToolName: String,
        commandPath: String,
        commandArguments: String
    ) -> PluginManifest.CapabilityAdapter? {
        switch kind.lowercased() {
        case "skill":
            return .init(type: "skill", skillFile: "SKILL.md")
        case "webservice":
            return .init(
                type: "webservice",
                url: webServiceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                method: webServiceMethod.uppercased()
            )
        case "mcp":
            return .init(
                type: "mcp",
                url: mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
                methodName: mcpMethodName.trimmingCharacters(in: .whitespacesAndNewlines),
                toolName: mcpToolName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case "command":
            return .init(
                type: "command",
                command: commandPath.trimmingCharacters(in: .whitespacesAndNewlines),
                arguments: commandArguments
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                timeoutSeconds: 20
            )
        case "native":
            return .init(type: "native")
        default:
            return nil
        }
    }

    func approve(_ approval: PendingApproval) async {
        pendingApprovals.removeAll { $0.id == approval.id }
        recordInteractionEvent(interactionEventBus.event(
            surface: .approval,
            kind: .approvalApproved,
            summary: "Approved capability execution.",
            payload: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        ))
        connectionState = .working
        lastError = nil
        let activityID = approval.activityID ?? beginCapabilityActivity(
            invocation: approval.invocation,
            status: .running,
            summary: "Approved by user; executing now."
        )
        updateCapabilityActivity(
            activityID,
            status: .running,
            summary: "Approved by user; executing now."
        )
        rebuildRunningTasks()
        let result = await executeCapabilityInvocation(approval.invocation)
        finishCapabilityActivity(activityID, result: result)
        refreshWebServiceArtifacts()
        captureExternalInboxEventIfNeeded(invocation: approval.invocation, result: result)
        captureInstalledPluginIfNeeded(invocation: approval.invocation, result: result, approved: true)
        captureRemovedPluginIfNeeded(invocation: approval.invocation, result: result, approved: true)
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        audit(
            type: "approval.approved",
            summary: "User approved capability execution.",
            metadata: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        )
        auditCapabilityExecution(invocation: approval.invocation, result: result, approved: true)
        Task {
            await persistCapabilityMemory(invocation: approval.invocation, result: result, approved: true)
        }
        saveSessionSnapshot()
        await reloadPlugins()
        await synthesizeApprovedCapabilityResult(approval: approval, result: result)
        connectionState = .ready
    }

    func reject(_ approval: PendingApproval) {
        pendingApprovals.removeAll { $0.id == approval.id }
        recordInteractionEvent(interactionEventBus.event(
            surface: .approval,
            kind: .approvalRejected,
            summary: "Rejected capability execution.",
            payload: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        ))
        messages.append(ChatMessage(role: .tool, content: "Rejected\n\(approval.title) was not executed."))
        if let activityID = approval.activityID {
            updateCapabilityActivity(
                activityID,
                status: .denied,
                summary: "User rejected this capability. Nothing was executed."
            )
        }
        rebuildRunningTasks()
        audit(
            type: "approval.rejected",
            summary: "User rejected capability execution.",
            metadata: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        )
        saveSessionSnapshot()
    }

    private func executeCapabilityInvocation(_ invocation: CapabilityInvocation) async -> CapabilityResult {
        if invocation.capabilityID == "reflection.snapshot" {
            let focus = stringArgument(
                invocation.arguments,
                keys: ["focus", "request", "summary"],
                fallback: ""
            )
            return saveReflectionSnapshot(focus: focus)
        }
        return await capabilityExecutor.execute(invocation)
    }

    private func retrieveMemory(for text: String) async throws -> String {
        guard config.hasMemKey else { return "" }
        let response = try await agentMem.query(text, sessionID: sessionID)
        if let first = response.retrievedMemories.first {
            memorySignal = MemorySignal(
                trust: min(0.98, max(0.48, first.score)),
                confidence: min(0.96, max(0.42, 0.68 + Double(response.retrievedMemories.count) * 0.03)),
                moodLabel: "Grounded",
                relationshipSummary: "\(response.retrievedMemories.count) memories nearby"
            )
        }
        return response.injectedContext
    }

    private func activeTaskSummary() -> String {
        ActiveWorkSummaryBuilder().build(
            tasks: runningTasks,
            activities: capabilityActivities,
            events: interactionEvents
        )
    }

    private func agentLoopSummary() -> String {
        AgentLoopSummaryBuilder()
            .build(
                events: interactionEvents,
                activities: capabilityActivities,
                pendingApprovals: pendingApprovals,
                generatedDrafts: generatedPluginDrafts,
                connectionState: connectionState
            )
            .map { step in
                "- \(step.phase.rawValue): \(step.status) - \(step.detail)"
            }
            .joined(separator: "\n")
    }

    private func companionPromptContext() -> CompanionPromptContext {
        CompanionPromptContext(profile: agentProfile, memorySignal: memorySignal)
    }

    private func parseArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func requiresApproval(capabilityID: String) -> Bool {
        pluginRegistry.capability(id: capabilityID, in: plugins)?.requiresApproval ?? true
    }

    @discardableResult
    private func enqueueApproval(for invocation: CapabilityInvocation) -> PendingApproval {
        let capability = pluginRegistry.capability(id: invocation.capabilityID, in: plugins)
        let title = capability?.title ?? invocation.capabilityID
        let detail = approvalDetail(for: invocation)
        let activityID = beginCapabilityActivity(
            invocation: invocation,
            status: .pending,
            summary: "Waiting for user approval before execution."
        )
        let approval = PendingApproval(title: title, detail: detail, invocation: invocation, activityID: activityID)
        pendingApprovals.append(approval)
        rebuildRunningTasks()
        audit(
            type: "approval.requested",
            summary: "Capability execution requires user approval.",
            metadata: [
                "approvalID": approval.id.uuidString,
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName
            ]
        )
        return approval
    }

    @discardableResult
    private func beginCapabilityActivity(
        invocation: CapabilityInvocation,
        status: CapabilityActivityStatus,
        summary: String
    ) -> UUID {
        let capability = pluginRegistry.capability(id: invocation.capabilityID, in: plugins)
        let activity = CapabilityActivity(
            capabilityID: invocation.capabilityID,
            functionName: invocation.functionName,
            title: capability?.title ?? invocation.capabilityID,
            status: status,
            summary: summary
        )
        capabilityActivities.insert(activity, at: 0)
        capabilityActivities = Array(capabilityActivities.prefix(20))
        rebuildRunningTasks()
        audit(
            type: "capability.activity_\(status.rawValue)",
            summary: summary,
            metadata: [
                "activityID": activity.id.uuidString,
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName
            ]
        )
        return activity.id
    }

    private func updateCapabilityActivity(
        _ id: UUID,
        status: CapabilityActivityStatus,
        summary: String
    ) {
        guard let index = capabilityActivities.firstIndex(where: { $0.id == id }) else { return }
        capabilityActivities[index].status = status
        capabilityActivities[index].summary = summary
        capabilityActivities[index].updatedAt = Date()
        rebuildRunningTasks()
        audit(
            type: "capability.activity_\(status.rawValue)",
            summary: summary,
            metadata: [
                "activityID": id.uuidString,
                "capabilityID": capabilityActivities[index].capabilityID,
                "functionName": capabilityActivities[index].functionName
            ]
        )
    }

    private func finishCapabilityActivity(_ id: UUID, result: CapabilityResult) {
        let failed = result.requiresUserApproval
            || result.title.localizedCaseInsensitiveContains("failed")
            || result.title.localizedCaseInsensitiveContains("blocked")
            || result.title.localizedCaseInsensitiveContains("missing")
            || result.title.localizedCaseInsensitiveContains("unsupported")
            || result.title.localizedCaseInsensitiveContains("timed out")
        updateCapabilityActivity(
            id,
            status: failed ? .failed : .done,
            summary: "\(result.title): \(String(result.content.prefix(160)))"
        )
    }

    private func approvalDetail(for invocation: CapabilityInvocation) -> String {
        let args = invocation.arguments
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        return args.isEmpty ? "No arguments." : args
    }

    private func stringArgument(_ arguments: [String: Any], keys: [String], fallback: String) -> String {
        for key in keys {
            if let value = arguments[key] {
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
        return fallback
    }

    private func captureGeneratedPluginDraft(from result: CapabilityResult, source: String) {
        guard result.title == "Plugin Package Draft",
              let data = result.content.data(using: .utf8),
              let package = try? JSONDecoder().decode(PluginPackage.self, from: data) else {
            return
        }
        stageGeneratedPluginPackage(package, source: source)
    }

    private func captureInstalledPluginIfNeeded(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) {
        guard invocation.capabilityID == "plugin.install",
              result.title == "Plugin Installed" || result.title == "Plugin Updated",
              let package = pluginPackageArgument(from: invocation.arguments) else {
            return
        }

        let documented = PluginPackageReviewDocumenter().documented(package)
        let removedDrafts = generatedPluginDrafts.filter { $0.manifest.id == documented.manifest.id }
        removedDrafts.forEach { try? pluginDraftStore.delete($0) }
        generatedPluginDrafts.removeAll { $0.manifest.id == documented.manifest.id }
        auditPluginEvent(
            type: result.title == "Plugin Updated" ? "plugin.updated" : "plugin.installed",
            package: documented,
            summary: result.title == "Plugin Updated"
                ? "Updated plugin through plugin.install capability."
                : "Installed plugin through plugin.install capability.",
            metadata: [
                "source": "plugin.install capability",
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName,
                "toolCallID": invocation.toolCallID,
                "approved": String(approved),
                "removedDrafts": String(removedDrafts.count)
            ]
        )
        rebuildRunningTasks()
    }

    private func pluginPackageArgument(from arguments: [String: Any]) -> PluginPackage? {
        let decoder = JSONDecoder()
        if let raw = arguments["package_json"] as? String,
           let data = raw.data(using: .utf8),
           let package = try? decoder.decode(PluginPackage.self, from: data) {
            return package
        }
        if let raw = arguments["manifest_json"] as? String,
           let data = raw.data(using: .utf8),
           let manifest = try? decoder.decode(PluginManifest.self, from: data) {
            return PluginPackage(manifest: manifest, files: [])
        }
        return nil
    }

    private func captureRemovedPluginIfNeeded(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) {
        guard invocation.capabilityID == "plugin.remove",
              result.title == "Plugin Removed" else {
            return
        }
        let pluginID = stringArgument(invocation.arguments, keys: ["plugin_id"], fallback: "")
        guard !pluginID.isEmpty else { return }
        let manifest = plugins.first { $0.id == pluginID }
        pendingApprovals.removeAll { $0.invocation.capabilityID.hasPrefix(pluginID + ".") }
        audit(
            type: "plugin.removed",
            summary: "Removed local plugin \(manifest?.name ?? pluginID) through plugin.remove capability.",
            metadata: [
                "pluginID": pluginID,
                "pluginName": manifest?.name ?? pluginID,
                "capabilityCount": String(manifest?.capabilities.count ?? 0),
                "source": "plugin.remove capability",
                "functionName": invocation.functionName,
                "toolCallID": invocation.toolCallID,
                "approved": String(approved)
            ]
        )
        if let manifest {
            recordPluginLifecycleEvent(
                action: .removed,
                manifest: manifest,
                fileCount: 0,
                source: "plugin.remove capability",
                summary: "Removed local plugin \(manifest.name) through plugin.remove capability.",
                metadata: [
                    "functionName": invocation.functionName,
                    "toolCallID": invocation.toolCallID,
                    "approved": String(approved)
                ]
            )
        }
        rebuildRunningTasks()
    }

    private func captureExternalInboxEventIfNeeded(invocation: CapabilityInvocation, result: CapabilityResult) {
        guard invocation.capabilityID == "inbox.capture",
              result.title == "Inbox Event Captured" else {
            return
        }
        let source = stringArgument(invocation.arguments, keys: ["source"], fallback: "external")
        let sender = stringArgument(invocation.arguments, keys: ["sender"], fallback: "")
        let text = stringArgument(invocation.arguments, keys: ["text", "request", "body", "content"], fallback: "")
        let url = stringArgument(invocation.arguments, keys: ["url"], fallback: "")
        let receivedAt = stringArgument(invocation.arguments, keys: ["received_at", "receivedAt"], fallback: "")
        let summaryPrefix = sender.isEmpty ? source : "\(source) from \(sender)"
        let preview = text.isEmpty ? "External inbox event captured." : String(text.prefix(140))
        var payload: [String: String] = [
            "source": source,
            "sender": sender,
            "textCharacters": String(text.count),
            "toolCallID": invocation.toolCallID
        ]
        if !url.isEmpty {
            payload["url"] = url
        }
        if !receivedAt.isEmpty {
            payload["receivedAt"] = receivedAt
        }
        recordInteractionEvent(interactionEventBus.event(
            surface: .externalInbox,
            kind: .externalInboxCaptured,
            summary: "\(summaryPrefix): \(preview)",
            payload: payload
        ))
    }

    private func captureLocalInboxBridgeMessage(_ message: LocalInboxMessage) {
        let invocation = CapabilityInvocation(
            toolCallID: "inbox-\(UUID().uuidString)",
            functionName: CapabilityToolCatalog.functionName(for: "inbox.capture"),
            capabilityID: "inbox.capture",
            arguments: [
                "source": message.source,
                "sender": message.sender,
                "text": message.text,
                "url": message.url,
                "received_at": message.receivedAt
            ]
        )
        let result = CapabilityResult(
            title: "Inbox Event Captured",
            content: """
            source: \(message.source)
            sender: \(message.sender)
            characters: \(message.text.count)

            \(message.text)
            """,
            requiresUserApproval: false
        )
        captureExternalInboxEventIfNeeded(invocation: invocation, result: result)
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        auditCapabilityExecution(invocation: invocation, result: result, approved: false)
        saveSessionSnapshot()
    }

    private func synthesizeApprovedCapabilityResult(approval: PendingApproval, result: CapabilityResult) async {
        guard config.hasLLMKey else { return }
        connectionState = .thinking
        do {
            let catalog = CapabilityToolCatalog.build(from: plugins)
            let prompt = SystemPromptBuilder(pluginManifests: plugins).build(
                memoryContext: "",
                activeTaskSummary: activeTaskSummary(),
                agentLoopSummary: agentLoopSummary(),
                runtimeContext: PromptRuntimeContext.current(config: config, cwd: runtimeCwd),
                companionContext: companionPromptContext()
            )
            var llmMessages = ApprovedCapabilityFollowUpBuilder(contextBuilder: conversationContextBuilder).build(
                systemPrompt: prompt,
                transcript: messages,
                approval: approval,
                result: result
            )
            let content = try await runAgentToolLoop(llmMessages: &llmMessages, catalog: catalog)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: content))
                saveSessionSnapshot()
                Task { await speakAssistantReplyIfEnabled(content) }
            }
        } catch {
            lastError = "The capability ran, but result synthesis failed: \(error.localizedDescription)"
            messages.append(ChatMessage(
                role: .assistant,
                content: "工具已经执行完成，但我生成总结时遇到问题：\(error.localizedDescription)"
            ))
            saveSessionSnapshot()
        }
    }

    private func saveSessionSnapshot() {
        do {
            try sessionStore.save(messages: messages, sessionID: sessionID)
        } catch {
            lastError = "Could not save local session: \(error.localizedDescription)"
        }
    }

    private func persistTurnMemory(userInput: String, agentResponse: String, attachments: [MessageAttachment] = []) async {
        guard config.hasMemKey else { return }
        do {
            var metadata: [String: Any] = ["surface": "mac", "source": "her-desktop"]
            if !attachments.isEmpty {
                metadata["attachment_count"] = attachments.count
                metadata["attachment_kinds"] = Array(Set(attachments.map { $0.kind.rawValue })).sorted().joined(separator: ",")
                metadata["attachment_names"] = attachments.map(\.displayName).joined(separator: ", ")
            }
            let response = try await agentMem.add(
                userInput: userInput,
                agentResponse: agentResponse,
                sessionID: sessionID,
                metadata: metadata
            )
            audit(
                type: "memory.writeback_succeeded",
                summary: "Turn was submitted to AgentMem.",
                metadata: [
                    "sessionID": sessionID,
                    "status": response.status,
                    "taskID": response.taskID
                ]
            )
        } catch {
            audit(
                type: "memory.writeback_failed",
                summary: error.localizedDescription,
                metadata: ["sessionID": sessionID]
            )
        }
    }

    private func speakAssistantReplyIfEnabled(_ text: String) async {
        guard config.speakAssistantReplies else { return }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        let previousState = connectionState
        connectionState = .speaking
        do {
            let id = try await speechSynthesizer.speak(
                cleanText,
                voiceIdentifier: config.speechVoiceIdentifier.nilIfEmpty
            )
            audit(
                type: "voice.reply_spoken",
                summary: "Assistant reply was spoken aloud.",
                metadata: ["speechID": id, "characters": String(cleanText.count)]
            )
        } catch {
            audit(
                type: "voice.reply_failed",
                summary: error.localizedDescription,
                metadata: ["characters": String(cleanText.count)]
            )
        }
        if connectionState == .speaking {
            connectionState = previousState == .thinking || previousState == .working ? .ready : previousState
        }
    }

    private func persistCapabilityMemory(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) async {
        guard config.hasMemKey else { return }
        let arguments = approvalDetail(for: invocation)
        let userInput = """
        Capability executed: \(invocation.capabilityID)
        Function: \(invocation.functionName)
        Approved by user: \(approved)
        Arguments:
        \(arguments)
        """
        let agentResponse = """
        Result title: \(result.title)
        Result content:
        \(String(result.content.prefix(4000)))
        """

        do {
            let response = try await agentMem.add(
                userInput: userInput,
                agentResponse: agentResponse,
                sessionID: sessionID,
                metadata: [
                    "surface": "mac",
                    "source": "her-desktop",
                    "event": "capability.execution",
                    "capabilityID": invocation.capabilityID,
                    "functionName": invocation.functionName,
                    "approved": String(approved)
                ]
            )
            audit(
                type: "memory.capability_writeback_succeeded",
                summary: "Capability result was submitted to AgentMem.",
                metadata: [
                    "sessionID": sessionID,
                    "status": response.status,
                    "taskID": response.taskID,
                    "capabilityID": invocation.capabilityID,
                    "functionName": invocation.functionName
                ]
            )
        } catch {
            audit(
                type: "memory.capability_writeback_failed",
                summary: error.localizedDescription,
                metadata: [
                    "sessionID": sessionID,
                    "capabilityID": invocation.capabilityID,
                    "functionName": invocation.functionName
                ]
            )
        }
    }

    private func applyConfiguration(_ updated: HerAppConfig) {
        config = updated
        agentMem = AgentMemClient(config: updated)
        agentLLM = AgentLLMClient(config: updated)
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
        serviceHealthVerifier = ServiceHealthVerifier(config: updated)
        plugins = pluginRegistry.loadPlugins()
        serviceHealth = serviceHealthVerifier.initialSnapshot(pluginCount: plugins.count)
        tools = Self.tools(from: serviceHealth, model: updated.agentLLMModel)
        connectionState = updated.hasLLMKey ? .ready : .offline
        agentProfile = .empty(userID: updated.userID)
        refreshDreamContext()
        refreshWebServiceArtifacts()
        rebuildRunningTasks()
    }

    private func pluginInstalledContent(
        package: PluginPackage,
        source: String,
        title: String = "Plugin Installed",
        verb: String = "Installed"
    ) -> String {
        PluginInstallSummaryFormatter().content(
            package: package,
            source: source,
            title: title,
            verb: verb
        )
    }

    private func refreshPluginHealth() {
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

    private func rebuildRunningTasks() {
        let remoteServices = serviceHealth.filter { $0.id == "agentllm" || $0.id == "agentmem" }
        let onlineServices = remoteServices.filter { $0.state == .online }.count
        let serviceProgress = remoteServices.isEmpty ? 0 : Double(onlineServices) / Double(remoteServices.count)
        let capabilityCount = plugins.flatMap(\.capabilities).count
        let draftCount = generatedPluginDrafts.count
        let approvalCount = pendingApprovals.count
        let activeCapabilityCount = capabilityActivities.filter { [.pending, .running].contains($0.status) }.count
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

    private static func tools(from health: [ServiceHealth], model: String) -> [ToolDescriptor] {
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

    private func audit(type: String, summary: String, metadata: [String: String] = [:]) {
        do {
            let event = AuditEvent(type: type, summary: summary, metadata: metadata)
            try auditStore.append(event)
            auditEvents = Self.recentAuditEvents(from: auditEvents + [event])
        } catch {
            lastError = "Could not write audit log: \(error.localizedDescription)"
        }
    }

    private func recordInteractionEvent(_ event: InteractionEvent) {
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

    private func auditPluginEvent(
        type: String,
        package: PluginPackage,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        var merged = metadata
        merged["pluginID"] = package.manifest.id
        merged["pluginName"] = package.manifest.name
        merged["capabilityCount"] = String(package.manifest.capabilities.count)
        merged["fileCount"] = String(package.files.count)
        audit(type: type, summary: summary, metadata: merged)
        if let action = Self.pluginLifecycleAction(for: type) {
            recordPluginLifecycleEvent(
                action: action,
                package: package,
                source: metadata["source"] ?? "unknown",
                summary: summary,
                metadata: metadata
            )
        }
    }

    private func recordPluginLifecycleEvent(
        action: PluginLifecycleAction,
        package: PluginPackage,
        source: String,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        recordPluginLifecycleEvent(
            action: action,
            manifest: package.manifest,
            fileCount: package.files.count,
            source: source,
            summary: summary,
            metadata: metadata
        )
    }

    private func recordPluginLifecycleEvent(
        action: PluginLifecycleAction,
        manifest: PluginManifest,
        fileCount: Int,
        source: String,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        do {
            let event = PluginLifecycleEvent(
                action: action,
                pluginID: manifest.id,
                pluginName: manifest.name,
                version: manifest.version,
                source: source,
                summary: summary,
                capabilityCount: manifest.capabilities.count,
                fileCount: fileCount,
                metadata: metadata
            )
            try pluginEventStore.append(event)
            pluginEvents = Self.recentPluginEvents(from: pluginEvents + [event])
        } catch {
            lastError = "Could not write plugin lifecycle log: \(error.localizedDescription)"
        }
    }

    private static func pluginLifecycleAction(for auditType: String) -> PluginLifecycleAction? {
        switch auditType {
        case "plugin.draft_staged": return .staged
        case "plugin.installed": return .installed
        case "plugin.updated": return .updated
        case "plugin.draft_discarded": return .discarded
        case "plugin.exported": return .exported
        case "plugin.install_failed": return .installFailed
        case "plugin.remove_failed": return .removeFailed
        case "plugin.export_failed": return .exportFailed
        case "plugin.package_import_failed": return .importFailed
        default: return nil
        }
    }

    private func auditCapabilityExecution(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) {
        audit(
            type: "capability.executed",
            summary: result.title,
            metadata: [
                "toolCallID": invocation.toolCallID,
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName,
                "approved": String(approved),
                "resultTitle": result.title
            ]
        )
    }

    private func openDirectory(_ url: URL, eventType: String) {
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

    private func openFile(path: String, eventType: String) {
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

    private static func recentAuditEvents(from events: [AuditEvent], limit: Int = 12) -> [AuditEvent] {
        Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    private static func recentPluginEvents(from events: [PluginLifecycleEvent], limit: Int = 12) -> [PluginLifecycleEvent] {
        Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    private static func recentInteractionEvents(from events: [InteractionEvent], limit: Int = 16) -> [InteractionEvent] {
        Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    private static func standardizedFilePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }
}

private struct ToolCallHandlingResult {
    var content: String
    var needsApproval: Bool
}

private struct AIGeneratedPluginPackage {
    var package: PluginPackage
    var repaired: Bool
}

private struct AIPluginGenerationRepairError: LocalizedError {
    var initialError: String
    var repairError: String

    var errorDescription: String? {
        "Initial plugin package failed validation: \(initialError). Repair attempt also failed: \(repairError)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
