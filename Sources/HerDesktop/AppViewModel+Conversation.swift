import AppKit
import Foundation
import SwiftUI

/// Conversation lifecycle, the send/tool loop, and transcript persistence.
extension AppViewModel {
    func newLocalConversation() {
        stopDictation()
        saveSessionSnapshot()
        let now = Date()
        let summary = ConversationSummary(
            id: UUID().uuidString,
            title: ConversationStore.defaultTitle,
            pinned: false,
            createdAt: now,
            updatedAt: now
        )
        conversations.insert(summary, at: 0)
        activeConversationID = summary.id
        recordInteractionEvent(interactionEventBus.event(
            surface: .mac,
            kind: .localSessionStarted,
            summary: "Started a new local conversation transcript.",
            payload: ["sessionID": sessionID]
        ))
        messages = [ChatMessage(role: .assistant, content: "新会话已经准备好。我们从哪里开始？")]
        resetConversationScopedState()
        audit(
            type: "session.new_conversation",
            summary: "Started a new local conversation transcript.",
            metadata: ["sessionID": sessionID]
        )
        saveSessionSnapshot()
    }

    /// 删除单条消息（气泡上的删除按钮）。同步清理它挂着的待审批项，
    /// 避免留下无处点按的孤儿审批。
    func deleteMessage(_ id: UUID) {
        guard streamingAssistantMessageID != id,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removed = messages.remove(at: index)
        if let approvalID = removed.approvalID {
            pendingApprovals.removeAll { $0.id == approvalID }
        }
        saveSessionSnapshot()
        audit(
            type: "session.message_deleted",
            summary: "Deleted a \(removed.role.rawValue) message from the transcript.",
            metadata: ["sessionID": activeConversationID, "chars": String(removed.content.count)]
        )
    }

    // MARK: - Per-conversation model override

    /// 这个会话的专属模型；nil 跟随全局设置。
    var activeModelOverride: String? {
        let raw = activeConversationSummary?.modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    func setModelOverride(_ modelID: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        conversations[index].modelOverride = modelID
        persistConversationIndex()
        audit(
            type: "session.model_override",
            summary: modelID.map { "Conversation switched to model \($0)." } ?? "Conversation reverted to the global model.",
            metadata: ["sessionID": activeConversationID, "model": modelID ?? "default"]
        )
    }

    /// 顶栏模型菜单的数据源：agentLLM 上实际存在的精选主力模型。
    func refreshChatModelOptions(force: Bool = false) async {
        guard chatModelOptions.isEmpty || force, config.hasLLMKey else { return }
        do {
            chatModelOptions = try await AgentLLMModelCatalog.fetch(
                baseURL: config.agentLLMBaseURL,
                apiKey: config.agentLLMAPIKey,
                session: urlSession
            )
        } catch {
            audit(type: "models.catalog_failed", summary: error.localizedDescription)
        }
    }

    func switchConversation(to id: String) {
        guard id != activeConversationID, conversations.contains(where: { $0.id == id }) else { return }
        stopDictation()
        stopCurrentTurn()
        saveSessionSnapshot()
        activeConversationID = id
        resetConversationScopedState()
        beginTranscriptLoad(id: id)
        audit(
            type: "session.switch_conversation",
            summary: "Switched to another local conversation.",
            metadata: ["sessionID": id]
        )
        persistConversationIndex()
    }

    /// Load a transcript off the main thread and install it as `messages`.
    /// Invariants that keep this path from ever destroying data:
    /// - No placeholder goes into `messages` while loading; a loading flag
    ///   drives the UI and `saveSessionSnapshot` refuses to run.
    /// - A per-load token invalidates stale loads: any path that installs
    ///   `messages` directly (delete, new conversation) refreshes the token,
    ///   so an abandoned load can neither apply nor leave the loading flag
    ///   stuck true (which would silently disable all future saves).
    /// - A corrupt file is not an empty conversation: the store has already
    ///   backed it up; we surface that instead of silently starting fresh.
    func beginTranscriptLoad(id: String) {
        let token = UUID()
        activeTranscriptLoadToken = token
        isLoadingConversation = true
        messages = []
        Task {
            let load = await conversationStore.loadTranscriptAsync(id: id)
            // The user may have switched again, or another path may have
            // installed messages and invalidated this load.
            guard activeTranscriptLoadToken == token, activeConversationID == id else { return }
            switch load {
            case .loaded(let loaded) where !loaded.isEmpty:
                messages = loaded
            case .loaded, .missing:
                messages = [ChatMessage(role: .assistant, content: "新会话已经准备好。我们从哪里开始？")]
            case .corrupt(let backupURL):
                messages = [Self.corruptTranscriptNotice(backup: backupURL)]
                lastError = "对话存档无法读取，原文件已备份。"
                audit(
                    type: "session.transcript_corrupt",
                    summary: "A conversation transcript failed to decode; the file was backed up.",
                    metadata: ["sessionID": id, "backup": backupURL?.path ?? "unavailable"]
                )
            }
            isLoadingConversation = false
            activeTranscriptLoadToken = nil
        }
    }

    static func corruptTranscriptNotice(backup: URL?) -> ChatMessage {
        let location = backup.map { "\n备份位置：\($0.path)" } ?? ""
        return ChatMessage(
            role: .assistant,
            content: "这段对话的存档文件无法读取（可能已损坏），我把原文件备份好了，没有覆盖。\(location)\n接下来的新消息会保存为全新的存档。",
            localOnly: true
        )
    }

    func renameConversation(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].title != trimmed else {
            return
        }
        conversations[index].title = String(trimmed.prefix(60))
        audit(
            type: "session.rename_conversation",
            summary: "Renamed a local conversation.",
            metadata: ["sessionID": id]
        )
        persistConversationIndex()
    }

    func togglePinConversation(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned.toggle()
        audit(
            type: conversations[index].pinned ? "session.pin_conversation" : "session.unpin_conversation",
            summary: conversations[index].pinned
                ? "Pinned a local conversation."
                : "Unpinned a local conversation.",
            metadata: ["sessionID": id]
        )
        persistConversationIndex()
    }

    func deleteConversation(_ id: String, compactingIntoMemory: Bool) async {
        guard let summary = conversations.first(where: { $0.id == id }) else { return }
        let transcript: [ChatMessage]
        if id == activeConversationID {
            transcript = messages
        } else if case .loaded(let loaded) = await conversationStore.loadTranscriptAsync(id: id) {
            transcript = loaded
        } else {
            transcript = []
        }
        if compactingIntoMemory {
            await compactConversationIntoMemory(id: id, title: summary.title, transcript: transcript)
        }
        conversations.removeAll { $0.id == id }
        do {
            try conversationStore.deleteConversationFile(id: id)
        } catch {
            lastError = "Could not delete the conversation file: \(error.localizedDescription)"
        }
        audit(
            type: "session.delete_conversation",
            summary: compactingIntoMemory
                ? "Deleted a local conversation after compacting it into memory."
                : "Deleted a local conversation.",
            metadata: ["sessionID": id, "compacted": String(compactingIntoMemory)]
        )
        if id == activeConversationID {
            if let next = sortedConversations.first {
                activeConversationID = next.id
                resetConversationScopedState()
                beginTranscriptLoad(id: next.id)
                persistConversationIndex()
            } else {
                newLocalConversation()
            }
        } else {
            persistConversationIndex()
        }
    }

    func resetConversationScopedState() {
        // Stop the previous conversation's voice mid-sentence.
        speechTask?.cancel()
        speechTask = nil
        baseSpeechSynthesizer.stop()
        agentLLMSpeechSynthesizer.stop()
        pendingApprovals = []
        capabilityActivities = []
        pendingAttachments = []
        autoApprovedCapabilities = []
        messageReferenceCache = [:]
        draft = ""
        dictationTranscript = ""
        lastError = nil
        // Invalidate any in-flight transcript load. Without this, a load
        // abandoned by delete/new-conversation would leave
        // `isLoadingConversation` stuck true and every future save would be a
        // silent no-op (all edits lost on quit).
        activeTranscriptLoadToken = nil
        isLoadingConversation = false
        connectionState = config.hasLLMKey ? .ready : .offline
        rebuildRunningTasks()
    }

    func clearComposer() {
        draft = ""
        pendingAttachments = []
        dictationTranscript = ""
        lastError = nil
    }

    func webServiceArtifacts(for message: ChatMessage) -> [WebServiceArtifact] {
        // Called for every message on every render; skip the content scan
        // entirely when there are no artifacts (the common case).
        guard !webServiceArtifacts.isEmpty, message.role != .user else { return [] }
        // Memoized per (message, content length, artifacts version) — the
        // line-by-line extractor scan is too heavy to repeat per render.
        if let cached = messageReferenceCache[message.id],
           cached.contentLength == message.content.count,
           cached.scanVersion == messageScanVersion,
           let ids = cached.artifactIDs {
            return ids.compactMap { id in webServiceArtifacts.first { $0.id == id } }
        }
        let manifestPaths = WebServiceArtifactReferenceExtractor.manifestPaths(in: message.content)
        let matched: [WebServiceArtifact]
        if manifestPaths.isEmpty {
            matched = []
        } else {
            let wanted = Set(manifestPaths.map(Self.standardizedFilePath))
            matched = webServiceArtifacts.filter { wanted.contains(Self.standardizedFilePath($0.manifestPath)) }
        }
        var entry = cacheEntry(for: message)
        entry.artifactIDs = matched.map(\.id)
        messageReferenceCache[message.id] = entry
        return matched
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        pendingAttachments = []
        if attachments.isEmpty, handleSlashCommand(text) {
            return
        }
        await send(text, attachments: attachments)
    }

    /// The composer's submit action. While a turn is generating, the typed
    /// message steers the running turn (Codex-style) instead of being blocked;
    /// otherwise it starts a fresh turn. Either way the message appears in the
    /// transcript immediately.
    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        pendingAttachments = []
        if attachments.isEmpty, handleSlashCommand(text) {
            return
        }
        if isGenerating {
            enqueueSteering(text, attachments: attachments)
        } else {
            currentTurnTask = Task { [self] in await runTurn(text, attachments: attachments) }
        }
    }

    /// Add a mid-turn instruction: show it now and queue it so the running
    /// tool loop picks it up at its next round.
    private func enqueueSteering(_ text: String, attachments: [MessageAttachment]) {
        let normalized = interactionEventBus.userMessage(text: text, attachments: attachments)
        recordInteractionEvent(normalized.event)
        messages.append(ChatMessage(role: .user, content: normalized.displayText, attachments: attachments))
        steeringQueue.append(normalized.contextText)
        audit(type: "conversation.steered", summary: "User steered the running turn.")
        saveSessionSnapshot()
    }

    /// Stop the in-flight turn. Cancellation propagates through the LLM
    /// stream; the catch keeps any partial reply and returns to ready.
    func stopCurrentTurn() {
        currentTurnTask?.cancel()
        currentTurnTask = nil
        steeringQueue.removeAll()
    }

    /// One full user turn plus any follow-ups from steering that arrived after
    /// the loop's last injection point (so nothing the user typed is dropped).
    private func runTurn(_ text: String, attachments: [MessageAttachment]) async {
        await send(text, attachments: attachments)
        while !Task.isCancelled, messages.last?.role == .user {
            await runGeneration()
        }
        // Turn is fully settled: fold history into a recap if it grew long.
        if !Task.isCancelled {
            await autoCompactIfNeeded()
        }
    }

    func send(_ text: String, attachments: [MessageAttachment] = []) async {
        if await saveInlineAgentLLMKeyIfPresent(text: text, attachments: attachments) {
            return
        }
        let normalized = interactionEventBus.userMessage(text: text, attachments: attachments)
        recordInteractionEvent(normalized.event)
        messages.append(ChatMessage(role: .user, content: normalized.displayText, attachments: attachments))
        guard config.hasLLMKey || allowsMissingLLMKeyForInjectedClient else {
            connectionState = .offline
            lastError = ServiceError.missingAPIKey("AgentLLM").localizedDescription
            messages.append(ChatMessage(role: .assistant, content: Self.firstRunSetupMessage(config: config), localOnly: true))
            saveSessionSnapshot()
            return
        }
        await runGeneration()
    }

    /// Generate an assistant reply for the current transcript (which already
    /// ends with the user message[s] to answer). Factored out so steering
    /// follow-ups can regenerate without re-appending a user message.
    private func runGeneration() async {
        connectionState = .thinking
        lastError = nil
        let userInput = messages.last(where: { $0.role == .user })?.content ?? ""
        do {
            await refreshAgentMemTurnSignals()
            let memContext = await retrieveMemory(for: userInput)
            let prompt = SystemPromptBuilder(pluginManifests: plugins, projectDocs: projectPromptDocs).build(
                memoryContext: memContext,
                activeTaskSummary: activeTaskSummary(),
                agentLoopSummary: agentLoopSummary(),
                runtimeContext: PromptRuntimeContext.current(config: config, cwd: runtimeCwd),
                companionContext: companionPromptContext(),
                roleplayContext: roleplayPromptSection(),
                activeProjectContext: projectPromptSection()
            )
            let catalog = CapabilityToolCatalog.build(from: plugins)
            var llmMessages = conversationContextBuilder.build(systemPrompt: prompt, messages: messages)
            // This build already reflects the transcript, so drop any stale
            // steering; new mid-turn steering will be injected per round.
            steeringQueue.removeAll()
            let rounds = browserAutonomyGranted ? 20 : 5
            let reply = try await runAgentToolLoop(llmMessages: &llmMessages, catalog: catalog, maxToolRounds: rounds)
            let final: String
            if reply.isEmpty {
                final = lastAssistantFinishReason == "length"
                    ? "这次生成没有完成：模型在思考阶段就用完了输出预算（max tokens），还没来得及写正文或调用工具。你可以对我说「重试，少想多做，直接调用工具」，或者在 Settings 里调大 AgentLLM Max Tokens 后再试。"
                    : "我收到啦，但这次模型没有返回正文。"
            } else {
                final = reply
            }
            deliverAssistantReply(final)
            connectionState = .ready
            saveSessionSnapshot()
            let turnSessionID = sessionID
            let turnMemoryClient = memoryClient(forConversation: turnSessionID)
            Task {
                await persistTurnMemory(
                    userInput: userInput,
                    agentResponse: final,
                    boundSessionID: turnSessionID,
                    boundMemoryClient: turnMemoryClient
                )
            }
            speechTask?.cancel()
            speechTask = Task { await speakAssistantReplyIfEnabled(final) }
        } catch is CancellationError {
            handleTurnCancelled()
        } catch let error as URLError where error.code == .cancelled {
            handleTurnCancelled()
        } catch {
            if Task.isCancelled {
                handleTurnCancelled()
                return
            }
            discardEmptyStreamedAssistantMessage()
            connectionState = .error
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: conversationalRecoveryMessage(for: error)))
            saveSessionSnapshot()
        }
    }

    /// User stopped generation: keep whatever streamed so far, no error.
    private func handleTurnCancelled() {
        flushStreamBuffer()
        finalizeStreamedToolRoundNarration()
        steeringQueue.removeAll()
        connectionState = .ready
        lastError = nil
        saveSessionSnapshot()
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

    func runAgentToolLoop(
        llmMessages: inout [AgentLLMMessage],
        catalog: CapabilityToolCatalog,
        maxToolRounds: Int = 5
    ) async throws -> String {
        var currentCatalog = catalog
        for round in 0...maxToolRounds {
            // Guided mode: fold in any instructions the user typed while this
            // turn was running, so the model course-corrects at this round.
            if !steeringQueue.isEmpty {
                for steer in steeringQueue { llmMessages.append(.user(steer)) }
                steeringQueue.removeAll()
                finalizeStreamedToolRoundNarration()
            }
            streamingAssistantMessageID = nil
            let message = try await agentLLM.chat(
                messages: llmMessages,
                tools: currentCatalog.tools,
                modelOverride: activeModelOverride,
                onEvent: { [weak self] event in
                    self?.applyAssistantStreamEvent(event)
                }
            )
            lastAssistantFinishReason = message.finishReason
            let toolCalls = message.toolCalls ?? []
            guard !toolCalls.isEmpty else {
                return finalizeStreamedAssistantReply(with: message)
            }
            finalizeStreamedToolRoundNarration()

            guard round < maxToolRounds else {
                return "我已经连续执行了 \(maxToolRounds) 轮工具调用，先停在这里，避免在没有你确认的情况下继续扩张任务。"
            }

            llmMessages.append(.assistant(content: message.content, toolCalls: toolCalls))
            var needsApproval = false
            for toolCall in toolCalls {
                let result = await handleToolCall(toolCall, catalog: currentCatalog)
                llmMessages.append(.toolResult(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    content: result.content
                ))
                needsApproval = needsApproval || result.needsApproval
            }
            await reloadPlugins()
            currentCatalog = CapabilityToolCatalog.build(from: plugins)

            if needsApproval {
                return "我已经把需要你批准的操作放进审批队列里。你批准后，我会基于工具结果继续推进。"
            }
        }
        return "我已经到达本轮工具调用上限，先把当前状态停住。"
    }

    func applyAssistantStreamEvent(_ event: AgentLLMStreamEvent) {
        if streamingAssistantMessageID == nil {
            let message = ChatMessage(role: .assistant, content: "")
            messages.append(message)
            streamingAssistantMessageID = message.id
        }
        // Buffer the delta; a debounced flush applies it to `messages` so the
        // whole UI re-renders at most ~14x/sec instead of once per token.
        switch event {
        case .reasoningDelta(let delta):
            streamBufferReasoning += delta
        case .contentDelta(let delta):
            streamBufferContent += delta
        }
        guard streamFlushTimer == nil else { return }
        streamFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushStreamBuffer() }
        }
    }

    func flushStreamBuffer() {
        streamFlushTimer?.invalidate()
        streamFlushTimer = nil
        guard !streamBufferContent.isEmpty || !streamBufferReasoning.isEmpty else { return }
        defer { streamBufferContent = ""; streamBufferReasoning = "" }
        guard let id = streamingAssistantMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if !streamBufferReasoning.isEmpty { messages[index].reasoning += streamBufferReasoning }
        if !streamBufferContent.isEmpty { messages[index].content += streamBufferContent }
    }

    func finalizeStreamedAssistantReply(with message: AgentLLMChatResponse.Choice.Message) -> String {
        flushStreamBuffer()
        let reply = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let id = streamingAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = reply
        }
        return reply
    }

    func finalizeStreamedToolRoundNarration() {
        flushStreamBuffer()
        defer { streamingAssistantMessageID = nil }
        guard let id = streamingAssistantMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let hasVisibleText = !messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !messages[index].reasoning.isEmpty
        if !hasVisibleText {
            messages.remove(at: index)
        }
    }

    /// Routes the final reply into the live streamed bubble when one exists,
    /// otherwise appends a fresh assistant message.
    func deliverAssistantReply(_ final: String) {
        streamFlushTimer?.invalidate(); streamFlushTimer = nil
        streamBufferContent = ""; streamBufferReasoning = ""
        defer { streamingAssistantMessageID = nil }
        if let id = streamingAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = final
        } else {
            messages.append(ChatMessage(role: .assistant, content: final))
        }
        markAgentLLMVerifiedByChat()
    }

    func discardEmptyStreamedAssistantMessage() {
        streamFlushTimer?.invalidate(); streamFlushTimer = nil
        streamBufferContent = ""; streamBufferReasoning = ""
        defer { streamingAssistantMessageID = nil }
        guard let id = streamingAssistantMessageID,
              let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              messages[index].reasoning.isEmpty else { return }
        messages.remove(at: index)
    }

    func handleToolCall(
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
        if requiresApproval(for: invocation) {
            let (approval, isNew) = enqueueApproval(for: invocation)
            if isNew {
                messages.append(ChatMessage(
                    role: .tool,
                    content: "Approval Required\n\(approval.title)\n\(approval.detail)",
                    approvalID: approval.id
                ))
            }
            let guidance = isNew
                ? "Pending user approval in Her Desktop. Approval id: \(approval.id.uuidString). The user now sees an approval card with 批准/拒绝 buttons in the conversation. Tell them to tap 批准 on that card, and do not call this tool again for the same action."
                : "This exact action is already waiting for user approval (approval id: \(approval.id.uuidString)). Do not call the tool again; remind the user to tap 批准 on the existing approval card in the conversation."
            return ToolCallHandlingResult(content: guidance, needsApproval: true)
        }

        let activityID = beginCapabilityActivity(
            invocation: invocation,
            status: .running,
            summary: "Executing without additional approval."
        )
        let outcome = await runInvocation(invocation, activityID: activityID, approved: false)
        return ToolCallHandlingResult(
            content: outcome.pluginDraft?.content ?? outcome.result.content,
            needsApproval: outcome.pluginDraft?.queuedInstallApproval ?? false
        )
    }

    func saveSessionSnapshot() {
        // Never persist while a transcript is still loading — `messages` is a
        // transient empty state that would overwrite the target's real content.
        guard !isLoadingConversation else { return }
        // A conversation being deleted is no longer in the index; skip the
        // write so its transcript file is not recreated.
        guard let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        // Encoding a long transcript (many large tool results) is heavy, so
        // write it off the main thread — this used to beachball on switch.
        // A failed background save is silent data loss; surface it.
        let failedID = activeConversationID
        conversationStore.enqueueSave(messages, id: activeConversationID) { error in
            Task { @MainActor [weak self] in
                self?.lastError = "对话未能保存：\(error.localizedDescription)"
                self?.audit(
                    type: "session.save_failed",
                    summary: "A background transcript save failed.",
                    metadata: ["sessionID": failedID, "error": error.localizedDescription]
                )
            }
        }
        conversations[index].updatedAt = Date()
        if conversations[index].title == ConversationStore.defaultTitle || conversations[index].title.isEmpty,
           let autoTitle = ConversationStore.autoTitle(from: messages) {
            conversations[index].title = autoTitle
        }
        persistConversationIndex()
    }

    func persistConversationIndex() {
        // Off-main, ordered with transcript saves on the store's serial queue.
        conversationStore.enqueueSaveIndex(
            conversations: conversations,
            activeConversationID: activeConversationID
        ) { error in
            Task { @MainActor [weak self] in
                self?.lastError = "Could not save the conversation index: \(error.localizedDescription)"
            }
        }
    }

    func compactConversationIntoMemory(id: String, title: String, transcript: [ChatMessage]) async {
        let visible = transcript.filter { $0.role == .user || $0.role == .assistant }
        guard !visible.isEmpty else {
            audit(
                type: "memory.compact_skipped",
                summary: "The conversation had no user or assistant messages to compact.",
                metadata: ["sessionID": id]
            )
            return
        }
        var summary = fallbackCompactSummary(from: visible, title: title)
        if config.hasLLMKey {
            do {
                let reply = try await agentLLM.chat(messages: [
                    .system("""
                    你负责把一段即将删除的对话压缩成长期记忆。请输出一段中文摘要（250字以内），\
                    保留用户提到的持久事实、偏好、决定、未完成的事项和重要结论，忽略寒暄和一次性细节。\
                    只输出摘要正文，不要任何前缀或解释。
                    """),
                    .user(compactTranscriptText(from: visible, title: title))
                ])
                let content = ThinkTagStreamFilter.extract(from: reply.content ?? "").content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    summary = content
                }
            } catch {
                audit(
                    type: "memory.compact_llm_failed",
                    summary: "LLM compaction failed; falling back to extracted summary. \(error.localizedDescription)",
                    metadata: ["sessionID": id]
                )
            }
        }
        guard let agentMem = memoryClient(forConversation: id) else {
            audit(
                type: "memory.compact_skipped",
                summary: "AgentMem is not configured; the compacted summary was not persisted.",
                metadata: ["sessionID": id]
            )
            return
        }
        do {
            let response = try await agentMem.addSummary(
                summary,
                sessionID: id,
                metadata: [
                    "surface": "mac",
                    "source": "her-desktop",
                    "writeback_mode": "conversation_compact",
                    "conversation_title": title
                ]
            )
            audit(
                type: "memory.compact_writeback_succeeded",
                summary: "The conversation was compacted into AgentMem before deletion.",
                metadata: [
                    "sessionID": id,
                    "status": response.status,
                    "taskID": response.taskID
                ]
            )
        } catch {
            audit(
                type: "memory.compact_writeback_failed",
                summary: error.localizedDescription,
                metadata: ["sessionID": id]
            )
        }
    }

    func compactTranscriptText(from visible: [ChatMessage], title: String, maxMessages: Int = 60) -> String {
        let lines = visible.suffix(maxMessages).map { message in
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = message.role == .user ? "用户" : "助手"
            return "\(speaker): \(String(content.prefix(600)))"
        }
        return """
        对话标题: \(title)

        \(lines.joined(separator: "\n"))
        """
    }

    func fallbackCompactSummary(from visible: [ChatMessage], title: String, maxMessages: Int = 12) -> String {
        let (userLines, assistantLines) = Self.durableCandidateLines(from: visible.suffix(maxMessages))
        return """
        Her Desktop conversation compact (deleted conversation "\(title)").

        User-stated durable candidates:
        \(userLines.joined(separator: "\n"))

        Assistant context:
        \(assistantLines.joined(separator: "\n"))
        """
    }
}

struct ToolCallHandlingResult {
    var content: String
    var needsApproval: Bool
}
