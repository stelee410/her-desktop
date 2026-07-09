import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @EnvironmentObject private var session: ConversationModel
    @EnvironmentObject private var model: AppViewModel
    /// Rendered window into the transcript: only the newest messages mount
    /// when a conversation opens; scrolling up widens the window page by
    /// page, so a thousand-message transcript never renders all at once.
    @State private var visibleLimit = ConversationView.initialWindow
    /// Blocks the top sentinel until the opening scroll-to-bottom has run —
    /// ScrollView starts at the top, which would otherwise fire the sentinel
    /// and eagerly load pages the user never asked for.
    @State private var didInitialScroll = false

    private static let initialWindow = 60
    private static let windowStep = 80

    private var visibleMessages: [ChatMessage] {
        let all = session.messages
        guard all.count > visibleLimit else { return all }
        return Array(all.suffix(visibleLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            // In its own subview: ConversationView re-renders per stream
            // flush (~14 Hz), and computing the readiness summary inline ran
            // the whole 9-item builder on every token.
            ReadinessStripContainer()
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy so only visible bubbles render — a plain VStack
                    // built and re-rendered every message in a long transcript.
                    LazyVStack(spacing: 22) {
                        VoicePresenceView()
                            .padding(.top, 34)

                        if session.isLoadingConversation {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在打开对话…")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .padding(.top, 20)
                        }

                        if session.messages.count > visibleLimit {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在加载更早的消息…")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .id("history-loader")
                            .onAppear { expandHistoryWindow(proxy: proxy) }
                        }

                        ForEach(visibleMessages) { message in
                            if message.recap {
                                RecapCard(message: message)
                                    .id(message.id)
                            } else {
                                MessageBubble(
                                    message: message,
                                    artifacts: model.webServiceArtifacts(for: message)
                                )
                                    .id(message.id)
                            }
                        }

                        if session.isCompacting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在压缩对话…")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .id("compacting-indicator")
                        }

                        if model.isAwaitingAssistantReply {
                            TypingIndicatorBubble()
                                .id("typing-indicator")
                        }

                        if let lastError = model.lastError {
                            Text(lastError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.bottom, 26)
                }
                .onAppear {
                    if let last = session.messages.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                        didInitialScroll = true
                    }
                }
                .onChange(of: session.activeConversationID) { _, _ in
                    visibleLimit = Self.initialWindow
                    didInitialScroll = false
                }
                .onChange(of: session.messages.count) { _, _ in
                    if let last = session.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        didInitialScroll = true
                    }
                }
                .onChange(of: session.messages.last.map { $0.content.count + $0.reasoning.count }) { _, _ in
                    if let last = session.messages.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onChange(of: model.isAwaitingAssistantReply) { _, isAwaiting in
                    if isAwaiting {
                        withAnimation { proxy.scrollTo("typing-indicator", anchor: .bottom) }
                    }
                }
            }
            ComposerView()
                .padding(.horizontal, 54)
                .padding(.bottom, 24)
        }
    }

    /// One page of older messages. The previous first message is re-anchored
    /// to the viewport top so the transcript doesn't visually jump when the
    /// older page mounts above it.
    private func expandHistoryWindow(proxy: ScrollViewProxy) {
        guard didInitialScroll else { return }
        let anchorID = visibleMessages.first?.id
        visibleLimit += Self.windowStep
        if let anchorID {
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }
}

/// Isolates the readiness computation from the streaming-hot
/// ConversationView: this container does NOT observe ConversationModel, so
/// the 9-item builder runs only when model/service state publishes —
/// (config/plugins/health changes), not per token. Observing serviceStatus
/// here also fixes readiness going stale after a health refresh.
private struct ReadinessStripContainer: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var serviceStatus: ServiceStatusModel

    var body: some View {
        let readiness = model.productReadinessSummary
        if !readiness.isReadyForCoreWork {
            LaunchReadinessStrip(summary: readiness)
                .padding(.horizontal, 54)
                .padding(.top, 12)
        }
    }
}

private struct LaunchReadinessStrip: View {
    @EnvironmentObject private var model: AppViewModel
    /// Computed once by the parent; recomputing here doubled the work.
    let summary: ProductReadinessSummary

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: summary.isReadyForCoreWork ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(summary.isReadyForCoreWork ? .green : AppTheme.coral)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(summary.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(summary.score)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(summary.isReadyForCoreWork ? .green : AppTheme.coral)
                }
                Text(summary.detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                model.appendReadinessGuidance()
            } label: {
                Label(summary.isReadyForCoreWork ? "Ask Her" : "Guide Me", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Ask Her to explain the next setup step in the conversation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

}

/// Per-conversation 角色卡 / 世界之书 pickers. Observing ConversationModel
/// keeps the selection in sync with conversation switches.
private struct RoleplaySelectors: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var session: ConversationModel

    var body: some View {
        let activeCard = model.activeCharacterCard
        let activeBook = model.activeWorldBook

        Menu {
            Button("无角色") { model.setCharacterCard(nil) }
            if model.characterCards.isEmpty {
                Button("去创建角色卡…") { model.selectedSection = .characters }
            }
            ForEach(model.characterCards) { card in
                Button("\(card.emoji) \(card.name)\(card.id == activeCard?.id ? " ✓" : "")") {
                    model.setCharacterCard(card)
                }
            }
        } label: {
            Label(
                activeCard.map { "\($0.emoji) \($0.name)" } ?? "角色",
                systemImage: "theatermasks"
            )
            .font(.caption)
            .foregroundStyle(activeCard == nil ? AppTheme.muted : AppTheme.coral)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("为这个会话选择角色卡")

        Menu {
            Button("无世界") { model.setWorldBook(nil) }
            if model.worldBooks.isEmpty {
                Button("去创建世界之书…") { model.selectedSection = .worldBooks }
            }
            ForEach(model.worldBooks) { book in
                Button("\(book.emoji) \(book.name)\(book.id == activeBook?.id ? " ✓" : "")") {
                    model.setWorldBook(book)
                }
            }
        } label: {
            Label(
                activeBook.map { "\($0.emoji) \($0.name)" } ?? "世界",
                systemImage: "book.closed"
            )
            .font(.caption)
            .foregroundStyle(activeBook == nil ? AppTheme.muted : AppTheme.coral)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("为这个会话选择世界之书")
    }
}

private struct ToolbarView: View {
    @EnvironmentObject private var session: ConversationModel
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var chrome: UIChrome
    @State private var isStatusPopoverPresented = false

    var body: some View {
        let status = PresenceCopy.serviceStatus(serviceStatus.serviceHealth)
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Picker("Conversation", selection: Binding(
                    get: { session.activeConversationID },
                    set: { model.switchConversation(to: $0) }
                )) {
                    ForEach(session.sortedConversations) { conversation in
                        Text(conversation.pinned ? "📌 \(conversation.title)" : conversation.title)
                            .tag(conversation.id)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .help("切换对话")

                Button {
                    model.newLocalConversation()
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(AppTheme.coral)
                }
                .buttonStyle(.plain)
                .help("新建对话")

                RoleplaySelectors()
            }

            Spacer()

            Button {
                model.setSpeakAssistantReplies(!model.config.speakAssistantReplies)
            } label: {
                Image(systemName: model.config.speakAssistantReplies ? "speaker.wave.2.fill" : "speaker.slash")
                    .foregroundStyle(model.config.speakAssistantReplies ? AppTheme.coral : AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help(model.config.speakAssistantReplies ? "Disable spoken replies" : "Enable spoken replies")

            Button {
                isStatusPopoverPresented.toggle()
            } label: {
                Image(systemName: status.systemImage)
                    .foregroundStyle(color(for: status.tone))
            }
            .buttonStyle(.plain)
            .help(status.title)
            .popover(isPresented: $isStatusPopoverPresented, arrowEdge: .bottom) {
                ServiceStatusPopover()
                    .environmentObject(model)
                    .environmentObject(serviceStatus)
            }

            Button {
                chrome.isBrowserPresented.toggle()
                if chrome.isBrowserPresented { model.onBrowserDrawerOpened() }
            } label: {
                Image(systemName: "globe")
                    .foregroundStyle(chrome.isBrowserPresented ? AppTheme.coral : AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help(chrome.isBrowserPresented ? "收起浏览器" : "打开浏览器")

            Button {
                chrome.isTerminalPresented.toggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .foregroundStyle(chrome.isTerminalPresented ? AppTheme.coral : AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help(chrome.isTerminalPresented ? "收起终端" : "打开终端")

            Button {
                chrome.isInspectorPresented.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(chrome.isInspectorPresented ? AppTheme.coral : AppTheme.muted)
                    .overlay(alignment: .topTrailing) {
                        if model.pendingActionCount > 0 {
                            Text("\(model.pendingActionCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(AppTheme.coral)
                                .clipShape(Capsule())
                                .offset(x: 9, y: -7)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(model.pendingActionCount > 0 ? "\(model.pendingActionCount) 项待处理" : "显示详情面板")
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .background(Color.white.opacity(0.38))
    }

    private func color(for tone: PresenceStatus.Tone) -> Color {
        switch tone {
        case .healthy: return .green
        case .warning: return .orange
        case .muted: return AppTheme.muted
        case .active: return AppTheme.coral
        }
    }
}

private struct ServiceStatusPopover: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(serviceStatus.serviceHealth) { service in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: service.state))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name)
                            .font(.caption.weight(.semibold))
                        if !service.summary.isEmpty {
                            Text(service.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                }
            }
            Divider()
            Button {
                Task { await model.refreshServiceHealth() }
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private func color(for state: ServiceHealthState) -> Color {
        switch state {
        case .online: return .green
        case .checking: return .orange
        case .offline: return .red
        case .unknown: return .gray
        }
    }
}

private struct VoicePresenceView: View {
    @EnvironmentObject private var model: AppViewModel
    /// Core-Animation-driven breathing (repeatForever runs on the render
    /// server — no per-frame SwiftUI body work).
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                // Soft halo: slow breathing scale + opacity.
                Circle()
                    .stroke(AppTheme.coral.opacity(0.09), lineWidth: 34)
                    .frame(width: 182, height: 182)
                    .scaleEffect(breathing ? 1.05 : 0.97)
                    .opacity(breathing ? 1.0 : 0.75)
                // Outer ring breathes slightly out of sync (delayed start)
                // so the motion feels organic rather than mechanical.
                Circle()
                    .stroke(AppTheme.coral.opacity(0.14), lineWidth: 1)
                    .frame(width: 218, height: 218)
                    .scaleEffect(breathing ? 1.025 : 0.995)
                // Gradient core: gentle pulse; glows brighter while active.
                Circle()
                    .fill(
                        RadialGradient(colors: [AppTheme.coral.opacity(0.72), AppTheme.coral.opacity(0.06)], center: .center, startRadius: 10, endRadius: 86)
                    )
                    .frame(width: 154, height: 154)
                    .scaleEffect(breathing ? 1.035 : 0.965)
                    .opacity(isActive ? 1.0 : (breathing ? 0.95 : 0.8))
                    .animation(.easeInOut(duration: 0.5), value: isActive)
                // Flowing wave: a 30fps timeline redraws ONLY this small
                // shape; amplitude reacts to state via an animated y-scale.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    WaveLine(phase: CGFloat(t.truncatingRemainder(dividingBy: 2.8) / 2.8) * .pi * 2)
                        .stroke(Color.white.opacity(0.82), lineWidth: 1.4)
                }
                .frame(width: 118, height: 36)
                .scaleEffect(y: waveScale)
                .animation(.easeInOut(duration: 0.6), value: waveScale)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            Text(greeting)
                .font(.system(size: 30, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.burgundy)
                .animation(.easeInOut(duration: 0.3), value: greeting)
        }
    }

    private var isActive: Bool {
        switch model.connectionState {
        case .listening, .speaking, .thinking, .working: return true
        default: return false
        }
    }

    /// Wave energy by state: calm at rest, lively when listening/speaking.
    private var waveScale: CGFloat {
        switch model.connectionState {
        case .listening: return 2.2
        case .speaking: return 1.9
        case .thinking, .working: return 1.5
        default: return 1.0
        }
    }

    private var greeting: String {
        PresenceCopy.greeting(
            connectionState: model.connectionState,
            agentProfile: model.agentProfile
        )
    }
}

private struct WaveLine: Shape {
    /// Horizontal travel of the wave, 0…2π per cycle.
    var phase: CGFloat = 0

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var started = false
        for x in stride(from: rect.minX, through: rect.maxX, by: 3) {
            let progress = (x - rect.minX) / max(rect.width, 1)
            // Taper toward the ends so the line settles flat at the edges.
            let envelope = sin(progress * .pi)
            let y = rect.midY + sin(progress * .pi * 2 - phase) * 4 * envelope
            if started {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            }
        }
        return path
    }
}

/// A /compact summary: full-width divider card marking the context boundary.
/// Messages above it stay visible but are no longer sent to the model.
private struct RecapCard: View {
    var message: ChatMessage
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.coral)
                    Text("对话已压缩")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("上面的消息不再进入模型上下文")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownMessageView(content: message.content, cachesParses: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.coral.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.coral.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var session: ConversationModel
    @EnvironmentObject private var model: AppViewModel
    var message: ChatMessage
    var artifacts: [WebServiceArtifact] = []

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 8) {
                if !message.reasoning.isEmpty {
                    ReasoningSection(
                        reasoning: message.reasoning,
                        isThinking: message.content.isEmpty
                    )
                }
                if message.role == .assistant {
                    // While this message is still streaming its content grows
                    // every flush — caching those transient parses would miss
                    // every time and grow the cache key set unboundedly.
                    MarkdownMessageView(
                        content: message.content,
                        cachesParses: session.streamingAssistantMessageID != message.id
                    )
                } else {
                    Text(message.content)
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.ink)
                        .textSelection(.enabled)
                }
                if let approvalID = message.approvalID {
                    ApprovalActionRow(approvalID: approvalID)
                }
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.attachments) { attachment in
                            AttachmentChip(attachment: attachment)
                        }
                    }
                }
                if !artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(artifacts) { artifact in
                            MessageArtifactChip(artifact: artifact) {
                                model.openWebServiceArtifact(
                                    path: artifact.primaryLocalImagePath ?? artifact.manifestPath
                                )
                            }
                        }
                    }
                }
                let referencedApps = model.webAppReferences(for: message)
                if !referencedApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(referencedApps) { app in
                            WebAppMessageCard(app: app, live: model.isRecentMessage(message.id))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                    if message.role == .assistant,
                       !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       session.streamingAssistantMessageID != message.id {
                        Button {
                            model.toggleSpeakMessage(message.content)
                        } label: {
                            Image(systemName: model.connectionState == .speaking
                                ? "speaker.wave.2.circle.fill"
                                : "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(model.connectionState == .speaking ? AppTheme.coral : AppTheme.muted)
                        }
                        .buttonStyle(.plain)
                        .help(model.connectionState == .speaking ? "停止播报" : "朗读这条回复")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(message.role == .user ? AppTheme.rose.opacity(0.72) : Color.white.opacity(0.54))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            if message.role != .user { Spacer(minLength: 70) }
        }
    }
}

/// A local web app referenced in the transcript: header with an open
/// action, plus a live embedded widget for recent messages when the app
/// declares one.
private struct WebAppMessageCard: View {
    @EnvironmentObject private var model: AppViewModel
    var app: WebAppManifest
    var live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                    .foregroundStyle(AppTheme.coral)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    if !app.description.isEmpty {
                        Text(app.description)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Button {
                    model.openWebApp(app.id)
                } label: {
                    Label("打开", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            if live, app.widget != nil, let url = model.webAppWidgetURL(app.id) {
                WebAppWebView(url: url, transparent: true)
                    .frame(height: app.widget?.height ?? 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
                    // Widgets are glanceable: a click anywhere opens the full app.
                    .overlay(
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openWebApp(app.id) }
                    )
                    .help("点击打开完整应用")
            }
        }
        .padding(10)
        .frame(minWidth: 320, alignment: .leading)
        .background(Color.white.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ApprovalActionRow: View {
    @EnvironmentObject private var model: AppViewModel
    var approvalID: UUID
    @State private var isExecuting = false

    private var approval: PendingApproval? {
        model.pendingApprovals.first { $0.id == approvalID }
    }

    var body: some View {
        if let approval {
            HStack(spacing: 10) {
                Button {
                    isExecuting = true
                    Task {
                        await model.approve(approval)
                        isExecuting = false
                    }
                } label: {
                    Label("批准", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .controlSize(.small)
                .disabled(isExecuting)

                Button {
                    isExecuting = true
                    Task {
                        await model.approveAlways(approval)
                        isExecuting = false
                    }
                } label: {
                    Label("一直批准", systemImage: "checkmark.circle.badge.questionmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isExecuting)
                .help("本对话中自动批准这类操作（\(approval.invocation.capabilityID)）")

                Button {
                    model.reject(approval)
                } label: {
                    Label("拒绝", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isExecuting)

                if isExecuting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        } else {
            Label("已处理", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
    }
}

private struct TypingIndicatorBubble: View {
    @State private var activeDot = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.coral.opacity(activeDot == index ? 0.85 : 0.28))
                        .frame(width: 7, height: 7)
                        .scaleEffect(activeDot == index ? 1.15 : 1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.54))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            Spacer(minLength: 70)
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                activeDot = (activeDot + 1) % 3
            }
        }
        .accessibilityLabel("正在等待回复")
    }
}

private struct ReasoningSection: View {
    var reasoning: String
    var isThinking: Bool
    @State private var isExpanded = false

    private var isShowingBody: Bool {
        isExpanded || isThinking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                    Text(isThinking ? "正在思考…" : "思维链")
                    Image(systemName: isShowingBody ? "chevron.down" : "chevron.right")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help(isShowingBody ? "收起思维链" : "展开思维链")

            if isShowingBody {
                Text(reasoning)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.muted)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct MessageArtifactChip: View {
    var artifact: WebServiceArtifact
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                preview
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Text("\(artifact.request.status) · \(artifact.artifacts.count) item(s)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open generated artifact")
    }

    private var title: String {
        artifact.primaryLocalImagePath == nil ? "Generated Artifact" : "Generated Image"
    }

    @ViewBuilder
    private var preview: some View {
        if let path = artifact.primaryLocalImagePath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            Image(systemName: artifact.remoteURLs.isEmpty ? "doc.richtext" : "photo")
                .foregroundStyle(AppTheme.coral)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// Live mic waveform shown above the composer during dictation. Observes
/// only VoiceLevelModel, so ~15Hz level updates redraw just these bars.
private struct DictationWaveView: View {
    @EnvironmentObject private var voiceLevel: VoiceLevelModel

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(voiceLevel.samples.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppTheme.coral.opacity(0.85))
                    .frame(width: 3, height: max(3, level * 22))
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.06), value: voiceLevel.samples)
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var session: ConversationModel
    @EnvironmentObject private var model: AppViewModel
    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.connectionState == .listening {
                HStack(spacing: 10) {
                    DictationWaveView()
                    Text(model.isPushToTalking ? "松开空格结束" : "正在聆听…点麦克风结束")
                        .font(.caption)
                        .foregroundStyle(AppTheme.coral)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.pendingAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                model.removePendingAttachment(attachment)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }

            HStack(spacing: 12) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.muted)
                .help("Attach files")

                TextField("Ask anything or give a command...", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.system(size: 15))
                    .focused($isComposerFocused)
                    .onChange(of: isComposerFocused) { _, focused in
                        model.composerFocused = focused
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        // While an input method (e.g. Chinese pinyin) is still
                        // composing, Return must commit the composition, not send.
                        if focusedEditorIsComposingText() {
                            return .ignored
                        }
                        if press.modifiers.contains(.shift) {
                            insertLineBreakInFocusedEditor()
                            return .handled
                        }
                        model.submitDraft()
                        return .handled
                    }

                Button {
                    model.toggleDictation()
                } label: {
                    Image(systemName: model.connectionState == .listening ? "stop.circle.fill" : "mic.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.coral)
                .help(model.connectionState == .listening ? "Stop dictation" : "Start dictation")

                let hasInput = !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !session.pendingAttachments.isEmpty
                // While generating, keep a stop button; the send button stays
                // live so typed text steers the running turn (guided mode).
                if model.isGenerating {
                    Button {
                        model.stopCurrentTurn()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.ink)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: [.command])
                    .help("停止生成（⌘.）")
                }
                Button {
                    model.submitDraft()
                } label: {
                    Image(systemName: model.isGenerating ? "arrow.up.message" : "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(hasInput ? AppTheme.coral : AppTheme.coral.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!hasInput)
                .help(model.isGenerating ? "发送以引导当前对话" : "发送")
            }
            if model.connectionState == .listening, !model.dictationTranscript.isEmpty {
                Label(model.dictationTranscript, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
            }
        }
        .padding(8)
        .background(isDropTargeted ? AppTheme.rose.opacity(0.82) : Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(isDropTargeted ? AppTheme.coral.opacity(0.45) : Color.black.opacity(0.06), lineWidth: 1)
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.attachFiles(urls)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            importDroppedFiles(providers)
        }
    }

    /// Inserts a newline at the cursor via the window's field editor, which is
    /// what actually edits a focused SwiftUI TextField on macOS.
    private func insertLineBreakInFocusedEditor() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        editor.insertNewlineIgnoringFieldEditor(nil)
    }

    /// True while the focused field editor holds an uncommitted input-method
    /// composition (e.g. pinyin candidates that Return should confirm).
    private func focusedEditorIsComposingText() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    private func importDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in
                    model.attachFiles([url])
                }
            }
        }
        return !providers.isEmpty
    }
}

private struct AttachmentChip: View {
    var attachment: MessageAttachment

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName(for: attachment.kind))
                .foregroundStyle(AppTheme.coral)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Text(byteString(attachment.byteCount))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PendingAttachmentChip: View {
    var attachment: MessageAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: attachment.kind))
                .foregroundStyle(AppTheme.coral)
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private func iconName(for kind: MessageAttachment.Kind) -> String {
    switch kind {
    case .text:
        return "doc.text"
    case .image:
        return "photo"
    case .video:
        return "film"
    case .audio:
        return "waveform"
    case .pdf:
        return "doc.richtext"
    case .archive:
        return "archivebox"
    case .other:
        return "paperclip"
    }
}

private func byteString(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
