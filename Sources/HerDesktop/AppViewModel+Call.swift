import Foundation

/// 打电话: starting/ending realtime voice calls, the in-call memo agent,
/// and the post-call summary that lands back in the conversation.
extension AppViewModel {
    func startVoiceCall() {
        guard config.hasRealtimeKey else {
            lastError = "打电话需要 agentRealtime API key，请在设置里填写。"
            return
        }
        guard !callController.isInCall else { return }
        // A call owns the audio path: stop any in-flight TTS first.
        speechTask?.cancel()
        speechTask = nil
        baseSpeechSynthesizer.stop()
        agentLLMSpeechSynthesizer.stop()
        speakingMessageID = nil

        callController.configureVoiceprint(
            voiceprintProfile?.enabled == true ? voiceprintProfile?.embedding : nil
        )

        isCallPresented = true
        callController.start(
            apiKey: config.agentRealtimeAPIKey,
            modelProfile: config.agentRealtimeModelProfile,
            instructions: voiceCallInstructions(),
            voice: config.agentRealtimeVoice
        )
        startCallMemoAgent()
        audit(
            type: "voice.call_started",
            summary: "Started a realtime voice call.",
            metadata: ["character": activeCharacterCard?.name ?? "Her"]
        )
    }

    /// Hangs up; the memo agent then turns the call into a summary message
    /// in the conversation and a long-term memory entry (routing-aware).
    func endVoiceCall() {
        guard isCallPresented else { return }
        callMemoTask?.cancel()
        callMemoTask = nil
        let lines = callController.transcript
        let seconds = Int(callController.duration)
        callController.reset()
        isCallPresented = false

        let name = activeCharacterCard?.name ?? agentProfile.displayName
        audit(
            type: "voice.call_ended",
            summary: "Realtime voice call ended.",
            metadata: ["seconds": String(seconds), "lines": String(lines.count)]
        )
        guard !lines.isEmpty else { return }
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let sessionID = activeConversationID
        Task { [weak self] in
            await self?.summarizeCall(lines: lines, clock: clock, partnerName: name, sessionID: sessionID)
        }
    }

    // MARK: - Post-call summary

    /// One LLM pass over the call transcript → a summary message in the
    /// conversation (visible to later turns, so the chat knows what was said
    /// on the phone) + an AgentMem writeback through the conversation's
    /// normal memory routing (roleplay stays isolated).
    private func summarizeCall(lines: [RealtimeCallController.TranscriptLine], clock: String, partnerName: String, sessionID: String) async {
        let transcript = Self.callTranscriptText(lines: lines, partnerName: partnerName)
        var summary: String?
        if config.hasLLMKey {
            summary = try? await generateCallSummary(transcript: transcript, partnerName: partnerName)
        }
        let content: String
        if let summary, !summary.isEmpty {
            content = "📞 通话总结（\(clock)）\n\n\(summary)"
        } else {
            // No LLM available — keep the raw transcript rather than nothing.
            content = "📞 与 \(partnerName) 通话 \(clock)\n\n\(transcript)"
        }
        guard sessionID == activeConversationID else {
            audit(type: "voice.call_summary_dropped", summary: "Conversation changed before the call summary landed.")
            return
        }
        messages.append(ChatMessage(role: .assistant, content: content))
        saveSessionSnapshot()

        if let summary, !summary.isEmpty {
            await persistCallMemory(summary, sessionID: sessionID)
        }
    }

    private func generateCallSummary(transcript: String, partnerName: String) async throws -> String {
        let reply = try await agentLLM.chat(messages: [
            .system("""
            你负责整理一段刚结束的语音通话记录（用户与 \(partnerName) 的对话）。输出一段简洁的中文通话总结：\
            聊了什么、达成的约定或决定、对方和用户提到的值得记住的事。口语化的重复和语气词忽略。\
            控制在 150 字以内，只输出总结正文，不要任何前缀或解释。
            """),
            .user(transcript)
        ])
        return ThinkTagStreamFilter.extract(from: reply.content ?? "").content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Memory routing follows the conversation: character with dedicated key
    /// → the character's own memory; plain conversation → global memory;
    /// roleplay without a key → no write at all.
    private func persistCallMemory(_ summary: String, sessionID: String) async {
        guard let client = memoryClient(forConversation: sessionID) else { return }
        do {
            _ = try await client.addSummary(
                summary,
                sessionID: sessionID,
                metadata: [
                    "surface": "mac",
                    "source": "her-desktop",
                    "writeback_mode": "voice_call_summary"
                ]
            )
            audit(type: "voice.call_memory_saved", summary: "Call summary written to AgentMem.")
        } catch {
            audit(type: "voice.call_memory_failed", summary: error.localizedDescription)
        }
    }

    // MARK: - In-call memo agent

    /// A second agent alongside the call: every ~40s it distills the fresh
    /// part of the transcript into at most 3 one-line facts and injects them
    /// into the realtime session (context.update). Doubao replays facts when
    /// its context rebuilds, so a long call stops forgetting its beginning.
    private func startCallMemoAgent() {
        callMemoTask?.cancel()
        guard config.hasLLMKey else { return }
        callMemoTask = Task { [weak self] in
            var digestedLines = 0
            var isFirstPass = true
            while !Task.isCancelled {
                // First pass joins 10s in so early facts (names, plans
                // mentioned right away) reach the session quickly; later
                // passes batch every 30s.
                try? await Task.sleep(nanoseconds: isFirstPass ? 10_000_000_000 : 30_000_000_000)
                guard let self, !Task.isCancelled, self.callController.isInCall else { return }
                let lines = self.callController.transcript
                let minimumFresh = isFirstPass ? 2 : 4
                isFirstPass = false
                guard lines.count - digestedLines >= minimumFresh else { continue }
                let fresh = Array(lines.suffix(from: digestedLines))
                digestedLines = lines.count
                let excerpt = Self.callTranscriptText(lines: fresh, partnerName: self.activeCharacterCard?.name ?? "她")
                guard let facts = try? await self.extractCallFacts(excerpt: excerpt) else { continue }
                for fact in facts.prefix(3) {
                    self.callController.sendContextFact(fact)
                }
            }
        }
    }

    private func extractCallFacts(excerpt: String) async throws -> [String] {
        let reply = try await agentLLM.chat(messages: [
            .system("""
            从下面这段通话片段里提取值得在后续对话中记住的事实（用户的偏好、约定、提到的具体安排、重要的个人信息）。\
            每条一行、以短句陈述、最多 3 条；没有值得记的就输出空。只输出事实本身，不要编号、前缀或解释。
            """),
            .user(excerpt)
        ])
        let content = ThinkTagStreamFilter.extract(from: reply.content ?? "").content
        return content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 }
    }

    private static func callTranscriptText(lines: [RealtimeCallController.TranscriptLine], partnerName: String) -> String {
        lines
            .map { ($0.role == .user ? "我" : partnerName) + "：" + $0.text }
            .joined(separator: "\n")
    }

    // MARK: - Call instructions

    /// The system prompt for the call: persona (character card), world lore,
    /// and an excerpt of the recent chat so the phone call continues the
    /// conversation instead of starting cold.
    private func voiceCallInstructions() -> String {
        var parts: [String] = []
        if let card = activeCharacterCard,
           !card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(card.prompt)
        } else {
            parts.append("你是 Her，一位温暖、直接、可信赖的中文伙伴，正在陪伴用户。")
        }
        if let book = activeWorldBook {
            let alwaysOn = book.entries.filter { $0.alwaysOn && !$0.content.isEmpty }
            if !alwaysOn.isEmpty {
                let lore = alwaysOn.map(\.content).joined(separator: "\n")
                parts.append("世界设定（当作既定事实）：\n\(String(lore.prefix(900)))")
            }
        }
        let recent = messages
            .filter { !$0.localOnly && !$0.content.isEmpty }
            .suffix(8)
            .map { ($0.role == .user ? "用户" : "你") + "：" + String($0.content.prefix(160)) }
        if !recent.isEmpty {
            parts.append("你们刚才在文字聊天里聊到（通话是这段对话的继续，别当成初次见面）：\n\(recent.joined(separator: "\n"))")
        }
        parts.append("现在你们正在语音通话。像打电话一样说话：口语化、简短自然，一次别说太长，不要念标点、序号或列表符号。")
        return parts.joined(separator: "\n\n")
    }
}
