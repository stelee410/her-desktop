import AppKit
import Foundation
import SwiftUI

/// Conversation lifecycle, the send/tool loop, and transcript persistence.
extension AppViewModel {
    var sortedConversations: [ConversationSummary] {
        conversations.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

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

    func switchConversation(to id: String) {
        guard id != activeConversationID, conversations.contains(where: { $0.id == id }) else { return }
        stopDictation()
        saveSessionSnapshot()
        let loaded: [ChatMessage]
        do {
            loaded = try conversationStore.loadMessages(id: id)
        } catch {
            lastError = "Could not open the conversation: \(error.localizedDescription)"
            return
        }
        activeConversationID = id
        messages = loaded.isEmpty
            ? [ChatMessage(role: .assistant, content: "新会话已经准备好。我们从哪里开始？")]
            : loaded
        resetConversationScopedState()
        audit(
            type: "session.switch_conversation",
            summary: "Switched to another local conversation.",
            metadata: ["sessionID": id]
        )
        persistConversationIndex()
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
        } else {
            transcript = (try? conversationStore.loadMessages(id: id)) ?? []
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
                let loaded = (try? conversationStore.loadMessages(id: next.id)) ?? []
                messages = loaded.isEmpty
                    ? [ChatMessage(role: .assistant, content: "新会话已经准备好。我们从哪里开始？")]
                    : loaded
                resetConversationScopedState()
                persistConversationIndex()
            } else {
                newLocalConversation()
            }
        } else {
            persistConversationIndex()
        }
    }

    func resetConversationScopedState() {
        pendingApprovals = []
        capabilityActivities = []
        pendingAttachments = []
        draft = ""
        dictationTranscript = ""
        lastError = nil
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
        let manifestPaths = WebServiceArtifactReferenceExtractor.manifestPaths(in: message.content)
        guard !manifestPaths.isEmpty else { return [] }
        let wanted = Set(manifestPaths.map(Self.standardizedFilePath))
        return webServiceArtifacts.filter { wanted.contains(Self.standardizedFilePath($0.manifestPath)) }
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
        if await saveInlineAgentLLMKeyIfPresent(text: text, attachments: attachments) {
            return
        }

        let normalized = interactionEventBus.userMessage(text: text, attachments: attachments)
        recordInteractionEvent(normalized.event)
        messages.append(ChatMessage(role: .user, content: normalized.displayText, attachments: attachments))
        guard config.hasLLMKey || allowsMissingLLMKeyForInjectedClient else {
            connectionState = .offline
            lastError = ServiceError.missingAPIKey("AgentLLM").localizedDescription
            messages.append(ChatMessage(role: .assistant, content: Self.firstRunSetupMessage(config: config)))
            saveSessionSnapshot()
            return
        }
        connectionState = .thinking
        lastError = nil

        do {
            await refreshAgentMemTurnSignals()
            let memContext = await retrieveMemory(for: normalized.contextText)
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
            Task { await persistTurnMemory(userInput: normalized.contextText, agentResponse: final, attachments: attachments) }
            Task { await speakAssistantReplyIfEnabled(final) }
        } catch {
            discardEmptyStreamedAssistantMessage()
            connectionState = .error
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: conversationalRecoveryMessage(for: error)))
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

    func runAgentToolLoop(
        llmMessages: inout [AgentLLMMessage],
        catalog: CapabilityToolCatalog,
        maxToolRounds: Int = 5
    ) async throws -> String {
        var currentCatalog = catalog
        for round in 0...maxToolRounds {
            streamingAssistantMessageID = nil
            let message = try await agentLLM.chat(
                messages: llmMessages,
                tools: currentCatalog.tools,
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
        guard let id = streamingAssistantMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .reasoningDelta(let delta):
            messages[index].reasoning += delta
        case .contentDelta(let delta):
            messages[index].content += delta
        }
    }

    func finalizeStreamedAssistantReply(with message: AgentLLMChatResponse.Choice.Message) -> String {
        let reply = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let id = streamingAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = reply
        }
        return reply
    }

    func finalizeStreamedToolRoundNarration() {
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
        if requiresApproval(capabilityID: capabilityID) {
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
        let result = await executeCapabilityInvocation(invocation)
        finishCapabilityActivity(activityID, result: result)
        refreshWebServiceArtifacts()
        captureExternalInboxEventIfNeeded(invocation: invocation, result: result)
        let capturedPluginDraft = captureGeneratedPluginDraft(
            from: result,
            source: toolCall.function.name,
            installImmediately: boolArgument(invocation.arguments, keys: ["install_immediately", "installImmediately"], fallback: false)
        )
        captureInstalledPluginIfNeeded(invocation: invocation, result: result, approved: false)
        captureRemovedPluginIfNeeded(invocation: invocation, result: result, approved: false)
        if capturedPluginDraft == nil {
            messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        }
        auditCapabilityExecution(invocation: invocation, result: result, approved: false)
        Task {
            let memoryResult = capturedPluginDraft.map {
                CapabilityResult(title: "Plugin Package Draft", content: $0.content, requiresUserApproval: $0.queuedInstallApproval)
            } ?? result
            await persistCapabilityMemory(invocation: invocation, result: memoryResult, approved: false)
        }
        return ToolCallHandlingResult(
            content: capturedPluginDraft?.content ?? result.content,
            needsApproval: capturedPluginDraft?.queuedInstallApproval ?? false
        )
    }

    func saveSessionSnapshot() {
        // A conversation being deleted is no longer in the index; skip the
        // write so its transcript file is not recreated.
        guard let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        do {
            try conversationStore.saveMessages(messages, id: activeConversationID)
        } catch {
            lastError = "Could not save local session: \(error.localizedDescription)"
        }
        conversations[index].updatedAt = Date()
        if conversations[index].title == ConversationStore.defaultTitle || conversations[index].title.isEmpty,
           let autoTitle = ConversationStore.autoTitle(from: messages) {
            conversations[index].title = autoTitle
        }
        persistConversationIndex()
    }

    func persistConversationIndex() {
        do {
            try conversationStore.saveIndex(
                conversations: conversations,
                activeConversationID: activeConversationID
            )
        } catch {
            lastError = "Could not save the conversation index: \(error.localizedDescription)"
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
        guard config.hasMemKey else {
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
        let recent = visible.suffix(maxMessages)
        let userLines = recent.filter { $0.role == .user }.map { message in
            "- \(String(message.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(700)))"
        }
        let assistantLines = recent.filter { $0.role == .assistant }.map { message in
            "- \(String(message.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))"
        }
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
