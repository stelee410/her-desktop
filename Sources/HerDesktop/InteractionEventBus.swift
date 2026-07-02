import Foundation

enum InteractionSurface: String, Codable, Equatable {
    case mac
    case voice
    case files
    case pluginLibrary
    case approval
    case configuration
    case externalInbox
}

enum InteractionEventKind: String, Codable, Equatable {
    case userMessage
    case voiceDictationStarted
    case voiceDictationFinished
    case voiceDictationFailed
    case attachmentsImported
    case attachmentImportFailed
    case manualCapabilityRequested
    case approvalApproved
    case approvalRejected
    case pluginDraftRequested
    case pluginPackageImported
    case localSessionStarted
    case externalInboxCaptured
}

struct InteractionEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var surface: InteractionSurface
    var kind: InteractionEventKind
    var summary: String
    var payload: [String: String]
    var attachments: [MessageAttachment]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        surface: InteractionSurface,
        kind: InteractionEventKind,
        summary: String,
        payload: [String: String] = [:],
        attachments: [MessageAttachment] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.surface = surface
        self.kind = kind
        self.summary = summary
        self.payload = payload
        self.attachments = attachments
    }
}

struct NormalizedInteractionTurn: Equatable {
    var event: InteractionEvent
    var displayText: String
    var contextText: String
}

final class InteractionEventBus {
    func userMessage(
        text: String,
        attachments: [MessageAttachment],
        surface: InteractionSurface = .mac
    ) -> NormalizedInteractionTurn {
        let cleanText = SecretRedactor.redact(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let displayText = cleanText.isEmpty
            ? "Attached \(attachments.count) file(s)."
            : cleanText
        let attachmentContext = attachments.contextDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextText: String
        if displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextText = attachmentContext
        } else if attachmentContext.isEmpty {
            contextText = displayText
        } else {
            contextText = """
            \(displayText)

            \(attachmentContext)
            """
        }
        let event = InteractionEvent(
            surface: surface,
            kind: .userMessage,
            summary: displayText,
            payload: [
                "textCharacters": String(cleanText.count),
                "attachmentCount": String(attachments.count)
            ],
            attachments: attachments
        )
        return NormalizedInteractionTurn(event: event, displayText: displayText, contextText: contextText)
    }

    func event(
        surface: InteractionSurface,
        kind: InteractionEventKind,
        summary: String,
        payload: [String: String] = [:],
        attachments: [MessageAttachment] = []
    ) -> InteractionEvent {
        InteractionEvent(
            surface: surface,
            kind: kind,
            summary: summary,
            payload: payload,
            attachments: attachments
        )
    }
}
