import Foundation

/// In-conversation compaction (/compact, /recap): summarize everything said
/// so far into a recap card that stays visible in the transcript. Older
/// messages remain on screen but stop being injected into the model — the
/// recap replaces them in the system prompt — and the same summary is
/// written back to AgentMem (respecting the conversation's memory routing).
extension AppViewModel {
    enum CompactionTrigger: String {
        case manual
        case auto
    }

    /// Messages since the last recap before auto-compaction kicks in.
    /// The context window itself is small; this bounds how much history can
    /// silently fall out of the window before it gets folded into a recap.
    static let autoCompactThreshold = 40
    /// Below this there is nothing worth compacting.
    static let minimumCompactMessages = 6

    /// Intercepts slash commands typed in the composer. Returns true when
    /// the text was a command and must not be sent as a chat message.
    func handleSlashCommand(_ text: String) -> Bool {
        let command = text.lowercased()
        guard command == "/compact" || command == "/recap" else { return false }
        messages.append(ChatMessage(role: .user, content: text, localOnly: true))
        if isGenerating {
            messages.append(ChatMessage(
                role: .assistant,
                content: "当前回合还在进行中，等这轮结束后再输入 \(text) 压缩对话。",
                localOnly: true
            ))
            saveSessionSnapshot()
            return true
        }
        Task { await compactActiveConversation(trigger: .manual) }
        return true
    }

    /// Called after a turn completes: compact automatically once enough new
    /// messages piled up since the last recap.
    func autoCompactIfNeeded() async {
        guard messagesSinceLastRecap() >= Self.autoCompactThreshold else { return }
        await compactActiveConversation(trigger: .auto)
    }

    func compactActiveConversation(trigger: CompactionTrigger) async {
        let hasLLM = config.hasLLMKey || allowsMissingLLMKeyForInjectedClient
        guard !isCompacting, !isGenerating, hasLLM else {
            if !hasLLM {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: "压缩对话需要先配置 AgentLLM API key（Settings → AgentLLM）。",
                    localOnly: true
                ))
                saveSessionSnapshot()
            }
            return
        }
        let conversationID = activeConversationID
        let source = compactableMessages()
        guard source.count >= Self.minimumCompactMessages else {
            if trigger == .manual {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: "上次压缩之后的内容还不多，暂时不需要再压缩。",
                    localOnly: true
                ))
                saveSessionSnapshot()
            }
            return
        }

        isCompacting = true
        defer { isCompacting = false }
        audit(
            type: "conversation.compact_started",
            summary: "Compacting the conversation into a recap (\(trigger.rawValue)).",
            metadata: ["sessionID": conversationID, "messages": String(source.count)]
        )
        do {
            let recapText = try await generateRecap(from: source)
            // The user may have switched conversations while the summary was
            // generating — never deliver a recap into the wrong transcript.
            guard activeConversationID == conversationID else {
                audit(
                    type: "conversation.compact_abandoned",
                    summary: "The conversation changed while compacting; the recap was dropped.",
                    metadata: ["sessionID": conversationID]
                )
                return
            }
            messages.append(ChatMessage(role: .assistant, content: recapText, recap: true))
            saveSessionSnapshot()
            audit(
                type: "conversation.compact_finished",
                summary: "The conversation was compacted into a recap.",
                metadata: ["sessionID": conversationID, "trigger": trigger.rawValue]
            )
            let boundClient = memoryClient(forConversation: conversationID)
            Task { await persistRecapMemory(recapText, sessionID: conversationID, client: boundClient) }
        } catch {
            lastError = error.localizedDescription
            if trigger == .manual {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: "这次压缩没有成功：\(error.localizedDescription)\n对话内容没有变化，你可以稍后再试一次 /compact。",
                    localOnly: true
                ))
                saveSessionSnapshot()
            }
            audit(
                type: "conversation.compact_failed",
                summary: error.localizedDescription,
                metadata: ["sessionID": conversationID, "trigger": trigger.rawValue]
            )
        }
    }

    /// User/assistant messages since (and including) the previous recap —
    /// the previous recap is folded in so summaries stay cumulative.
    private func compactableMessages() -> [ChatMessage] {
        var window = messages[...]
        if let recapIndex = messages.lastIndex(where: { $0.recap }) {
            window = messages[recapIndex...]
        }
        return window.filter {
            !$0.localOnly && ($0.role == .user || $0.role == .assistant || $0.recap)
        }
    }

    func messagesSinceLastRecap() -> Int {
        var window = messages[...]
        if let recapIndex = messages.lastIndex(where: { $0.recap }) {
            window = messages[messages.index(after: recapIndex)...]
        }
        return window.filter { !$0.localOnly && ($0.role == .user || $0.role == .assistant) }.count
    }

    private func generateRecap(from source: [ChatMessage]) async throws -> String {
        let transcript = source.map { message -> String in
            let speaker: String
            if message.recap {
                speaker = "此前的回顾摘要"
            } else {
                speaker = message.role == .user ? "用户" : "助手"
            }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(speaker): \(String(content.prefix(1_500)))"
        }.joined(separator: "\n")
        let reply = try await agentLLM.chat(messages: [
            .system("""
            你负责把一段对话压缩成可继续工作的回顾（recap）。后续对话将只依赖这份回顾理解之前发生的事，\
            所以要保留：正在进行的任务和目标、已经确认的事实与决定、用户的偏好和约束、未完成的事项、\
            重要的结论。忽略寒暄和已经失效的中间过程。如果输入里已包含"此前的回顾摘要"，把它合并进来，\
            不要丢失其中仍然有效的信息。

            用中文输出，格式如下（没有内容的小节可以省略）：
            **正在进行**: …
            **关键事实与决定**: …
            **用户偏好**: …
            **待办**: …
            只输出回顾正文，不要任何前缀、标题或解释。
            """),
            .user(transcript)
        ])
        let content = ThinkTagStreamFilter.extract(from: reply.content ?? "").content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ServiceError.invalidResponse
        }
        return content
    }

    private func persistRecapMemory(_ recap: String, sessionID: String, client: AgentMemClient?) async {
        guard let client else {
            audit(
                type: "memory.recap_writeback_skipped",
                summary: "AgentMem is not configured for this conversation; the recap stayed local.",
                metadata: ["sessionID": sessionID]
            )
            return
        }
        do {
            let response = try await client.addSummary(
                recap,
                sessionID: sessionID,
                metadata: [
                    "surface": "mac",
                    "source": "her-desktop",
                    "writeback_mode": "conversation_recap"
                ]
            )
            audit(
                type: "memory.recap_writeback_succeeded",
                summary: "The conversation recap was written to AgentMem.",
                metadata: ["sessionID": sessionID, "status": response.status, "taskID": response.taskID]
            )
        } catch {
            audit(
                type: "memory.recap_writeback_failed",
                summary: error.localizedDescription,
                metadata: ["sessionID": sessionID]
            )
        }
    }
}
