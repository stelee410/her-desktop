import SwiftUI

// SwiftUI invalidates EVERY view observing an ObservableObject whenever that
// object emits objectWillChange — regardless of which property changed. With
// all state on the single large AppViewModel, each streamed token, audit
// append, or health probe repainted the sidebar, every message bubble, and
// every inspector card at once.
//
// These small observables carve the highest-frequency write paths out of the
// monolith. AppViewModel keeps same-named computed passthroughs, so internal
// logic is unchanged; views that DISPLAY this state observe the sub-model
// instead and are the only ones invalidated by its writes. (Same pattern as
// UIChrome / BrowserController / TerminalController.)

/// Service health, connected tools, and the derived running-task list.
/// One health refresh used to emit 5 whole-window invalidations.
@MainActor
final class ServiceStatusModel: ObservableObject {
    @Published var serviceHealth: [ServiceHealth] = []
    @Published var tools: [ToolDescriptor] = []
    @Published var runningTasks: [RunningTask] = []
}

/// The audit / interaction / capability activity feeds. The agent tool loop
/// appends to these on every step; only the inspector's activity panes and
/// the workspace pages actually display them.
@MainActor
final class ActivityFeedModel: ObservableObject {
    @Published var auditEvents: [AuditEvent] = []
    @Published var interactionEvents: [InteractionEvent] = []
    @Published var capabilityActivities: [CapabilityActivity] = []
    @Published var pluginEvents: [PluginLifecycleEvent] = []
}

/// The conversation itself — transcript, composer, and conversation list.
/// This is the single highest-frequency write path in the app: every
/// streamed token flush (~14 Hz) mutates `messages`. While these lived on
/// AppViewModel, every flush repainted the sidebar and all inspector cards.
@MainActor
final class ConversationModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var streamingAssistantMessageID: UUID?
    /// True while a switched-to transcript is still decoding off the main
    /// thread; suppresses saves so the transient empty state is never
    /// persisted over the target's real content.
    @Published var isLoadingConversation = false
    @Published var draft = ""
    @Published var pendingAttachments: [MessageAttachment] = []
    @Published var conversations: [ConversationSummary] = [] {
        didSet { sortedConversationsCache = nil }
    }
    @Published var activeConversationID: String = ""

    /// Memoized sort — the sidebar and switcher read this every render.
    private var sortedConversationsCache: [ConversationSummary]?

    var sortedConversations: [ConversationSummary] {
        // Stable creation order (newest first); using a conversation must not
        // reshuffle the list. Pinned ones still float to the top.
        if let cached = sortedConversationsCache { return cached }
        let sorted = conversations.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
        sortedConversationsCache = sorted
        return sorted
    }
}
