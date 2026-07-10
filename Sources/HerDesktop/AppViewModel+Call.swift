import Foundation

/// 打电话: starting/ending realtime voice calls and folding the call
/// transcript back into the conversation.
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

        isCallPresented = true
        callController.start(
            apiKey: config.agentRealtimeAPIKey,
            instructions: voiceCallInstructions(),
            voice: config.agentRealtimeVoice
        )
        audit(
            type: "voice.call_started",
            summary: "Started a realtime voice call.",
            metadata: ["character": activeCharacterCard?.name ?? "Her"]
        )
    }

    /// Hangs up and appends the call transcript to the conversation as a
    /// local-only message (visible history, never re-sent to the model).
    func endVoiceCall() {
        guard isCallPresented else { return }
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
        let body = lines
            .map { ($0.role == .user ? "我" : name) + "：" + $0.text }
            .joined(separator: "\n")
        messages.append(ChatMessage(
            role: .assistant,
            content: "📞 与 \(name) 通话 \(clock)\n\n\(body)",
            localOnly: true
        ))
        saveSessionSnapshot()
    }

    /// The system prompt for the call: the active character stays in
    /// persona, and everyone talks like they're on the phone.
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
                parts.append("世界设定（当作既定事实）：\n" + alwaysOn.map(\.content).joined(separator: "\n"))
            }
        }
        parts.append("现在你们正在语音通话。像打电话一样说话：口语化、简短自然，一次别说太长，不要念标点、序号或列表符号。")
        return parts.joined(separator: "\n\n")
    }
}
