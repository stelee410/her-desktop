import Foundation

struct ApprovedCapabilityFollowUpBuilder {
    var contextBuilder: ConversationContextBuilder = ConversationContextBuilder()
    var maxResultCharacters: Int = 20_000

    func build(
        systemPrompt: String,
        transcript: [ChatMessage],
        approval: PendingApproval,
        result: CapabilityResult,
        availableToolSummaries: [String] = []
    ) -> [AgentLLMMessage] {
        var followUpContextBuilder = contextBuilder
        followUpContextBuilder.maxToolEvidenceMessages = 0
        var messages = followUpContextBuilder.build(systemPrompt: systemPrompt, messages: transcript)
        messages.append(.user(followUpInstruction(
            approval: approval,
            result: result,
            availableToolSummaries: availableToolSummaries
        )))
        return messages
    }

    private func followUpInstruction(
        approval: PendingApproval,
        result: CapabilityResult,
        availableToolSummaries: [String]
    ) -> String {
        """
        The user approved a Her Desktop capability and it has now executed.

        Capability:
        - id: \(approval.invocation.capabilityID)
        - title: \(approval.title)
        - function: \(approval.invocation.functionName)

        Approval detail:
        \(approval.detail)

        Result:
        - title: \(result.title)

        Result content:
        \(truncated(result.content))

        Current available tools after approval:
        \(toolCatalogText(availableToolSummaries))

        Continue the user's workflow from this real approved result. If another available capability is useful, request it through the normal Her Desktop tool channel. If the next step needs approval, let the approval gate pause the work. If no tool is needed, respond with a concise, natural summary and the next useful action.
        """
    }

    private func toolCatalogText(_ summaries: [String]) -> String {
        guard !summaries.isEmpty else {
            return "- No tool catalog summary was provided; continue from the result content and visible transcript."
        }
        return summaries.prefix(80).map { "- \($0)" }.joined(separator: "\n")
    }

    private func truncated(_ content: String) -> String {
        guard content.count > maxResultCharacters else { return content }
        let prefix = content.prefix(maxResultCharacters)
        return "\(prefix)\n\n[Result truncated to \(maxResultCharacters) characters for follow-up synthesis.]"
    }
}
