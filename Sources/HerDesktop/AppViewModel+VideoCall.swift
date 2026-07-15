import Foundation

/// 视频通话（Vidu 数字人）的上下文与记忆环路 —— 实验性功能：
/// 开场把角色卡/世界书/AgentMem 召回/近期聊天拼进 persona（Vidu 的
/// persona 不限字符数，是唯一的上下文入口）；通话中用并行 ASR 自建
/// 转写（Vidu 的 WS 是纯控制面，不下推任何文本，见
/// docs/video-call-vidu-s1.md 实测）；挂断后总结落会话 + 写 AgentMem。
extension AppViewModel {
    func startVideoCall() {
        guard config.hasViduKey else {
            lastError = "视频通话需要 Vidu API key，请在设置里填写。"
            return
        }
        // 通话独占音频路径：先停掉播报中的 TTS。
        speechTask?.cancel()
        speechTask = nil
        baseSpeechSynthesizer.stop()
        agentLLMSpeechSynthesizer.stop()
        speakingMessageID = nil
        isVideoCallPresented = true
        audit(
            type: "video.call_started",
            summary: "Started a Vidu video call.",
            metadata: ["character": activeCharacterCard?.name ?? "Her"]
        )
    }

    var videoCallDisplayName: String {
        if let name = activeCharacterCard?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let configured = config.viduAvatarName.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? agentProfile.displayName : configured
    }

    /// 开场简报：数字人接通那一刻就"记得你"。结构与打电话的
    /// voiceCallInstructions 对齐，外加一段 AgentMem 长期记忆召回。
    func videoCallPersona() async -> String {
        var parts: [String] = []
        if let card = activeCharacterCard,
           !card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(card.prompt)
        } else {
            parts.append("你是 \(videoCallDisplayName)，一位温暖、直接、可信赖的中文伙伴，正在陪伴用户\(agentProfile.userDisplayName)。")
        }
        if let book = activeWorldBook {
            let alwaysOn = book.entries.filter { $0.alwaysOn && !$0.content.isEmpty }
            if !alwaysOn.isEmpty {
                let lore = alwaysOn.map(\.content).joined(separator: "\n")
                parts.append("世界设定（当作既定事实）：\n\(String(lore.prefix(900)))")
            }
        }
        // 长期记忆召回：以近期用户消息为查询线索。
        let recentUserText = messages
            .filter { $0.role == .user && !$0.localOnly && !$0.content.isEmpty }
            .suffix(3)
            .map(\.content)
            .joined(separator: "\n")
        let recalled = await retrieveMemory(for: recentUserText.isEmpty ? "用户的近况、偏好和约定" : recentUserText)
        if !recalled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("你对用户的长期记忆（自然地体现在对话里，不要照本宣科）：\n\(String(recalled.prefix(1200)))")
        }
        let recent = messages
            .filter { !$0.localOnly && !$0.content.isEmpty }
            .suffix(8)
            .map { ($0.role == .user ? "用户" : "你") + "：" + String($0.content.prefix(160)) }
        if !recent.isEmpty {
            parts.append("你们刚才在文字聊天里聊到（视频通话是这段对话的继续，别当成初次见面）：\n\(recent.joined(separator: "\n"))")
        }
        parts.append("现在你们正在视频通话。像面对面聊天一样说话：口语化、简短自然，一次别说太长，不要念标点、序号或列表符号。")
        return parts.joined(separator: "\n\n")
    }

    /// 挂断后的收尾：总结落会话（后续文字对话知道通话里聊了什么）+
    /// 按会话的记忆路由写 AgentMem。transcript 为空也落一条通话记录。
    func videoCallDidEnd(transcript: String, seconds: Int) {
        let name = videoCallDisplayName
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let sessionID = activeConversationID
        audit(
            type: "video.call_ended",
            summary: "Vidu video call ended.",
            metadata: ["seconds": String(seconds), "transcriptChars": String(transcript.count)]
        )
        guard seconds > 0 else { return }
        Task { [weak self] in
            await self?.summarizeVideoCall(
                transcript: transcript,
                clock: clock,
                partnerName: name,
                sessionID: sessionID
            )
        }
    }

    private func summarizeVideoCall(transcript: String, clock: String, partnerName: String, sessionID: String) async {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var summary: String?
        if !cleaned.isEmpty, config.hasLLMKey {
            summary = try? await generateVideoCallSummary(transcript: cleaned, partnerName: partnerName)
        }
        let content: String
        if let summary, !summary.isEmpty {
            content = "📹 视频通话总结（\(clock)）\n\n\(summary)"
        } else if !cleaned.isEmpty {
            content = "📹 与 \(partnerName) 视频通话 \(clock)\n\n通话语音转写：\n\(cleaned)"
        } else {
            content = "📹 与 \(partnerName) 视频通话 \(clock)"
        }
        guard sessionID == activeConversationID else {
            audit(type: "video.call_summary_dropped", summary: "Conversation changed before the video call summary landed.")
            return
        }
        // 无转写时只是一条通话痕迹，不该进模型上下文。
        messages.append(ChatMessage(role: .assistant, content: content, localOnly: cleaned.isEmpty))
        saveSessionSnapshot()

        if let summary, !summary.isEmpty {
            await persistVideoCallMemory(summary, sessionID: sessionID)
        }
    }

    private func generateVideoCallSummary(transcript: String, partnerName: String) async throws -> String {
        let reply = try await agentLLM.chat(messages: [
            .system("""
            你负责整理一段刚结束的视频通话录音转写（用户与 \(partnerName) 的对话）。\
            注意：转写来自麦克风单路采集，可能混入了 \(partnerName) 从扬声器播出的声音，无法可靠区分说话人，\
            所以概括对话内容本身即可，不确定是谁说的就不要归属到具体人。\
            输出一段简洁的中文通话总结：聊了什么、达成的约定或决定、值得记住的事。\
            口语化的重复和语气词忽略。控制在 150 字以内，只输出总结正文，不要任何前缀或解释。
            """),
            .user(transcript)
        ])
        return ThinkTagStreamFilter.extract(from: reply.content ?? "").content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistVideoCallMemory(_ summary: String, sessionID: String) async {
        guard let client = memoryClient(forConversation: sessionID) else { return }
        do {
            _ = try await client.addSummary(
                summary,
                sessionID: sessionID,
                metadata: [
                    "surface": "mac",
                    "source": "her-desktop",
                    "writeback_mode": "video_call_summary"
                ]
            )
            audit(type: "video.call_memory_saved", summary: "Video call summary written to AgentMem.")
        } catch {
            audit(type: "video.call_memory_failed", summary: error.localizedDescription)
        }
    }
}

/// 通话期间的并行转写：独立的 DashScope 实时 ASR 会话（不与手动听写
/// 共用实例），从 live 开始录到挂断。macOS 允许多个客户端同时采集
/// 麦克风，所以和 WKWebView 里推 RTC 的 getUserMedia 并不冲突。
/// 已知局限（实验性）：外放时麦克风会拾到数字人的声音，转写会混入
/// 双方语音——总结提示词已按"无法区分说话人"处理。
@MainActor
final class VideoCallTranscriber: ObservableObject {
    @Published private(set) var latestPartial = ""

    private var service: AgentLLMDictationService?
    private var task: Task<String, Never>?

    var isRunning: Bool { service != nil }

    func start(config: HerAppConfig) {
        guard service == nil, config.hasLLMKey else { return }
        let service = AgentLLMDictationService(config: config)
        self.service = service
        task = Task { [weak self] in
            do {
                return try await service.start(localeIdentifier: "zh_CN") { partial in
                    self?.latestPartial = partial
                }
            } catch {
                return ""
            }
        }
    }

    /// 结束采集并返回整通电话的累计转写（ASR 静音/失败时为空串）。
    func finish() async -> String {
        guard let service, let task else { return "" }
        self.service = nil
        self.task = nil
        service.stop()
        return await task.value
    }
}
