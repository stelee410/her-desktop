import Foundation

/// 连接器：把外部聊天平台（微信/Discord/飞书…）桥进 Her。
/// v1 只有微信——托管 infiniti-weixin-bridge 子进程，本地起一个讲
/// infiniti live 协议的 WS 服务端（ConnectorLiveServer），消息进出都
/// 落在一个专属「微信」会话里，在侧栏可见、可绑角色卡。
extension AppViewModel {
    static let wechatConversationID = "connector-wechat"
    static let connectorLivePort: UInt16 = 8788

    // MARK: - Lifecycle

    /// 配置开启时启动（bootstrap 和保存设置后都会调）。幂等。
    func startWeChatConnectorIfEnabled() {
        guard config.wechatConnectorEnabled else {
            stopWeChatConnector()
            return
        }
        guard wechatBridgeProcess == nil else { return }
        let bridgeDirectory = (config.wechatBridgeDirectory as NSString).expandingTildeInPath
        let cli = URL(fileURLWithPath: bridgeDirectory).appendingPathComponent("dist/cli.js")
        guard FileManager.default.fileExists(atPath: cli.path) else {
            wechatConnectorStatus = "桥未找到：\(cli.path)。请确认目录并已构建（npm run build）。"
            return
        }
        guard let node = Self.resolveNodeExecutable() else {
            wechatConnectorStatus = "没有找到 node（需要 ≥22）。"
            return
        }
        do {
            if !connectorLiveServer.isRunning {
                try connectorLiveServer.start(port: Self.connectorLivePort) { [weak self] line, attachments, reply in
                    self?.handleConnectorUserInput(line: line, attachments: attachments, reply: reply)
                }
            }
        } catch {
            wechatConnectorStatus = "本地 live 服务启动失败：\(error.localizedDescription)"
            return
        }

        // 启动前清掉指向本端口的残留桥（app 上次被强杀留下的孤儿）：
        // 两个桥同时轮询会对同一条微信消息各回一遍。
        Self.killStaleBridges()

        // sh 看门狗包一层：app 进程消失（包括崩溃/SIGKILL）后 5 秒内
        // 桥自杀——微信桥绝不能比 Her 活得久。参数走位置变量，免去引号地狱。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let botNames = config.wechatBotNames.trimmingCharacters(in: .whitespacesAndNewlines)
        let watchdogScript = """
        if [ -n "$5" ]; then
          "$1" "$2" start --live-ws "$3" --no-watch-inbox --group-mode "$4" --bot-name "$5" &
        else
          "$1" "$2" start --live-ws "$3" --no-watch-inbox --group-mode "$4" &
        fi
        CHILD=$!
        trap 'kill "$CHILD" 2>/dev/null' TERM INT EXIT
        while kill -0 "$6" 2>/dev/null && kill -0 "$CHILD" 2>/dev/null; do sleep 5; done
        kill "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
        """
        process.arguments = [
            "-c", watchdogScript, "sh",
            node, cli.path,
            "ws://127.0.0.1:\(Self.connectorLivePort)",
            config.wechatGroupMode,
            botNames,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: bridgeDirectory)

        let logURL = HerWorkspacePaths.logsDirectory(cwd: runtimeCwd)
            .appendingPathComponent("wechat-bridge.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wechatBridgeProcess = nil
                if self.config.wechatConnectorEnabled {
                    self.wechatConnectorStatus = "桥已退出（code \(code)）。日志：.her/logs/wechat-bridge.log；若未登录先在终端跑 infiniti-weixin-bridge login。"
                }
            }
        }
        do {
            try process.run()
            wechatBridgeProcess = process
            wechatConnectorStatus = "微信桥运行中（PID \(process.processIdentifier)）"
            audit(type: "connector.wechat_started", summary: "WeChat bridge launched.", metadata: ["pid": String(process.processIdentifier)])
        } catch {
            wechatConnectorStatus = "桥启动失败:\(error.localizedDescription)"
        }
    }

    func stopWeChatConnector() {
        if let process = wechatBridgeProcess {
            process.terminationHandler = nil
            process.terminate()
            wechatBridgeProcess = nil
            // 包装 sh 的 trap 会带走 node；再兜底清一次防信号竞争。
            Self.killStaleBridges()
            audit(type: "connector.wechat_stopped", summary: "WeChat bridge stopped.")
        }
        connectorLiveServer.stop()
        if !config.wechatConnectorEnabled {
            wechatConnectorStatus = "未启用"
        }
    }

    /// 只清理指向我们端口的桥进程，不误伤用户手动跑的其他实例。
    private static func killStaleBridges() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "cli.js start --live-ws ws://127.0.0.1:\(connectorLivePort)"]
        try? process.run()
        process.waitUntilExit()
    }

    private static func resolveNodeExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Inbound turn

    /// 微信来的一条消息 → 专属会话里跑一轮无工具的流式回复。
    /// reply(fullRaw, done)：桥要的是累积文本帧。
    func handleConnectorUserInput(
        line: String,
        attachments: [ConnectorLiveProtocol.InboundAttachment],
        reply: @escaping @Sendable (String, Bool) -> Void
    ) {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentNote = ConnectorLiveProtocol.describeAttachments(attachments)
        if !attachmentNote.isEmpty {
            text = text.isEmpty ? attachmentNote : "\(text)\n\(attachmentNote)"
        }
        guard !text.isEmpty else {
            reply("", true)
            return
        }
        guard config.hasLLMKey else {
            reply("Her 还没配置好模型服务，请先在电脑上完成设置。", true)
            return
        }
        Task { @MainActor [weak self] in
            await self?.runConnectorTurn(text: text, reply: reply)
        }
    }

    private func runConnectorTurn(
        text: String,
        reply: @escaping @Sendable (String, Bool) -> Void
    ) async {
        ensureWeChatConversation()
        let conversationID = Self.wechatConversationID
        var transcript = await loadConnectorTranscript(id: conversationID)
        let userMessage = ChatMessage(role: .user, content: text)
        transcript.append(userMessage)
        appendToConnectorConversation(userMessage, id: conversationID, transcript: transcript)

        let recalled = await retrieveMemory(for: text)
        var llmMessages: [AgentLLMMessage] = [.system(connectorSystemPrompt(recalled: recalled))]
        for message in transcript.suffix(16) where !message.localOnly && !message.content.isEmpty {
            llmMessages.append(message.role == .user ? .user(message.content) : .assistant(content: message.content, toolCalls: []))
        }

        var filter = ThinkTagStreamFilter()
        var streamed = ""
        do {
            let override = conversations.first { $0.id == conversationID }?.modelOverride
            let message = try await agentLLM.chat(
                messages: llmMessages,
                tools: [],
                modelOverride: override
            ) { event in
                if case .contentDelta(let delta) = event {
                    let split = filter.feed(delta)
                    if !split.content.isEmpty {
                        streamed += split.content
                        reply(streamed, false)
                    }
                }
            }
            let final = ThinkTagStreamFilter.extract(from: message.content ?? streamed).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = final.isEmpty ? streamed : final
            reply(finalText, true)
            let assistantMessage = ChatMessage(role: .assistant, content: finalText)
            transcript.append(assistantMessage)
            appendToConnectorConversation(assistantMessage, id: conversationID, transcript: transcript)
            audit(
                type: "connector.wechat_reply",
                summary: "Replied to a WeChat message.",
                metadata: ["chars": String(finalText.count)]
            )
        } catch {
            reply("（出错了：\(error.localizedDescription)）", true)
            audit(type: "connector.wechat_reply_failed", summary: error.localizedDescription)
        }
    }

    private func connectorSystemPrompt(recalled: String) -> String {
        var parts: [String] = []
        let summary = conversations.first { $0.id == Self.wechatConversationID }
        if let raw = summary?.characterCardID,
           let cardID = UUID(uuidString: raw),
           let card = characterCards.first(where: { $0.id == cardID }),
           !card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(card.prompt)
        } else {
            parts.append("你是 \(agentProfile.displayName)，用户 \(agentProfile.userDisplayName) 的中文伙伴。")
        }
        if !recalled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("你对用户的长期记忆（自然运用，不要照本宣科）：\n\(String(recalled.prefix(1200)))")
        }
        parts.append("你正在通过微信和用户聊天。像发微信一样回复：简短、口语化、直接说重点；不要用 markdown 标记（会原样显示）；不要念动作或括号舞台指示。")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Conversation plumbing

    /// 专属会话在侧栏可见，用户可以点开围观、绑角色卡、选模型。
    private func ensureWeChatConversation() {
        guard !conversations.contains(where: { $0.id == Self.wechatConversationID }) else { return }
        conversations.insert(
            ConversationSummary(
                id: Self.wechatConversationID,
                title: "📱 微信",
                pinned: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
            at: 0
        )
        persistConversationIndex()
    }

    private func loadConnectorTranscript(id: String) async -> [ChatMessage] {
        if activeConversationID == id { return messages }
        if case .loaded(let stored) = await conversationStore.loadTranscriptAsync(id: id) {
            return stored
        }
        return []
    }

    private func appendToConnectorConversation(_ message: ChatMessage, id: String, transcript: [ChatMessage]) {
        if activeConversationID == id {
            messages.append(message)
            saveSessionSnapshot()
        } else {
            try? conversationStore.saveMessages(transcript, id: id)
        }
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].updatedAt = Date()
        }
    }
}
