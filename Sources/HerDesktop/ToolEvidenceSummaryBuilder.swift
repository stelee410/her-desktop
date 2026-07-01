import Foundation

struct ToolEvidenceSummary: Identifiable, Equatable {
    var id: UUID
    var title: String
    var detail: String
    var createdAt: Date
}

struct ToolEvidenceSummaryBuilder {
    private let limit: Int
    private let maxDetailCharacters: Int

    init(limit: Int = 4, maxDetailCharacters: Int = 180) {
        self.limit = limit
        self.maxDetailCharacters = maxDetailCharacters
    }

    func build(from messages: [ChatMessage]) -> [ToolEvidenceSummary] {
        messages
            .filter { $0.role == .tool && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map(summary(from:))
    }

    private func summary(from message: ChatMessage) -> ToolEvidenceSummary {
        let lines = message.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let title = lines.first ?? "Tool Result"
        let detail = lines.dropFirst().joined(separator: " ")
        return ToolEvidenceSummary(
            id: message.id,
            title: snip(title, limit: 72),
            detail: snip(detail.isEmpty ? title : detail, limit: maxDetailCharacters),
            createdAt: message.createdAt
        )
    }

    private func snip(_ text: String, limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let end = clean.index(clean.startIndex, offsetBy: max(0, limit - 1))
        return "\(clean[..<end])..."
    }
}
