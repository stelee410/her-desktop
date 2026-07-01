import Foundation

struct ConversationContextBuilder {
    var maxMessages: Int = 12

    func build(systemPrompt: String, messages: [ChatMessage]) -> [AgentLLMMessage] {
        let recent = messages
            .compactMap(agentMessage)
            .suffix(maxMessages)
        return [.system(systemPrompt)] + Array(recent)
    }

    private func agentMessage(_ message: ChatMessage) -> AgentLLMMessage? {
        let content = promptContent(for: message)
        guard !content.isEmpty else { return nil }
        switch message.role {
        case .user:
            return .user(content)
        case .assistant:
            return .assistant(content: content)
        case .system, .tool:
            return nil
        }
    }

    private func promptContent(for message: ChatMessage) -> String {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentContext = message.attachments.contextDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return attachmentContext
        }
        if attachmentContext.isEmpty {
            return text
        }
        return """
        \(text)

        \(attachmentContext)
        """
    }
}
