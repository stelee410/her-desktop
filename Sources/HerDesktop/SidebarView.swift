import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var session: ConversationModel
    @EnvironmentObject private var model: AppViewModel
    @State private var isConversationListExpanded = true
    @State private var conversationPendingDeletion: ConversationSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Text("∞")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(AppTheme.coral)
                Text("Her")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(AppTheme.coral)
            }
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(WorkspaceSection.allCases) { section in
                    NavItem(
                        icon: section.systemImage,
                        title: section.title,
                        selected: model.selectedSection == section
                    ) {
                        model.selectedSection = section
                    }
                }
            }

            Divider().opacity(0.5)

            conversationListSection

            Spacer()

            HStack(spacing: 10) {
                Circle()
                    .fill(AppTheme.coral.opacity(0.2))
                    .frame(width: 34, height: 34)
                    .overlay(Text(initials(model.agentProfile.displayName)).foregroundStyle(AppTheme.coral))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.agentProfile.displayName)
                        .font(.subheadline)
                    Text(model.connectionState.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(model.connectionState == .error ? .red : .green)
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("打开设置")
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 18)
        // A solid tint instead of .ultraThinMaterial: the blur re-sampled the
        // whole sidebar on every re-render and every animation frame, which was
        // the main source of sidebar/open-close lag.
        .background(Color(red: 0.95, green: 0.96, blue: 0.95))
        // 删除确认对话框挂在 SidebarView 最外层，而不是会话列表子树上：
        // macOS 的 confirmationDialog 关闭后会在其所在子树留下一个吞点击
        // 的隐形遮罩——挂在列表子树上会导致删除后「+」新建按钮点不动。
        .confirmationDialog(
            "删除对话",
            isPresented: Binding(
                get: { conversationPendingDeletion != nil },
                set: { if !$0 { conversationPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: conversationPendingDeletion
        ) { conversation in
            Button("Compact 并保存记忆后删除") {
                Task { await model.deleteConversation(conversation.id, compactingIntoMemory: true) }
            }
            Button("直接删除", role: .destructive) {
                Task { await model.deleteConversation(conversation.id, compactingIntoMemory: false) }
            }
            Button("取消", role: .cancel) {}
        } message: { conversation in
            Text("要删除「\(conversation.title)」吗？删除前可以先把这段对话 compact 成摘要写入长期记忆。")
        }
    }

    /// Conversations grouped by project: each project with conversations
    /// gets a small header, everything unassigned goes under 散聊 (header
    /// shown only when project groups exist).
    private var projectGroups: [(project: Project, conversations: [ConversationSummary])] {
        model.projects.compactMap { project in
            let conversations = session.sortedConversations.filter { $0.projectID == project.id.uuidString }
            return conversations.isEmpty ? nil : (project, conversations)
        }
    }

    private var ungroupedConversations: [ConversationSummary] {
        let projectIDs = Set(model.projects.map { $0.id.uuidString })
        return session.sortedConversations.filter { conversation in
            guard let projectID = conversation.projectID else { return true }
            return !projectIDs.contains(projectID)
        }
    }

    private var conversationListSection: some View {
        // 不用 DisclosureGroup：它的 label 会吞掉点击用于折叠，里面的
        // 「+」按钮在 macOS 上收不到点击。改成手动头部——折叠区和按钮
        // 是两个独立控件，各管各的。
        VStack(alignment: .leading, spacing: 0) {
            ConversationListHeader(
                isExpanded: $isConversationListExpanded,
                onNew: {
                    model.newLocalConversation()
                    model.selectedSection = .today
                }
            )

            if isConversationListExpanded {
                ScrollView {
                    // Lazy: only visible rows build; a long history built every
                    // row (with hover/rename state) eagerly.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(projectGroups, id: \.project.id) { group in
                            ProjectGroupHeader(project: group.project) {
                                model.selectedSection = .projects
                            }
                            ForEach(group.conversations) { conversation in
                                conversationRow(conversation)
                                    .padding(.leading, 10)
                            }
                        }
                        if !projectGroups.isEmpty, !ungroupedConversations.isEmpty {
                            ProjectGroupHeader(project: nil, onOpen: nil)
                        }
                        ForEach(ungroupedConversations) { conversation in
                            conversationRow(conversation)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .tint(AppTheme.muted)
    }

    private func conversationRow(_ conversation: ConversationSummary) -> some View {
        ConversationListRow(
            conversation: conversation,
            selected: conversation.id == session.activeConversationID,
            onSelect: {
                model.switchConversation(to: conversation.id)
                model.selectedSection = .today
            },
            onTogglePin: {
                model.togglePinConversation(conversation.id)
            },
            onRename: { newTitle in
                model.renameConversation(conversation.id, to: newTitle)
            },
            onDelete: {
                conversationPendingDeletion = conversation
            }
        )
    }

    private func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "H" }
        return String(first).uppercased()
    }
}

/// A small group header in the conversation list: a project (clickable —
/// jumps to the 项目 page) or 散聊 for unassigned conversations (nil project).
private struct ProjectGroupHeader: View {
    var project: Project?
    var onOpen: (() -> Void)?

    var body: some View {
        Button(action: { onOpen?() }) {
            HStack(spacing: 6) {
                Text(project.map { $0.emoji.isEmpty ? "📁" : $0.emoji } ?? "💬")
                    .font(.system(size: 11))
                Text(project?.name ?? "散聊")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
                if let project, project.plan != nil {
                    Text("\(Int(project.progress * 100))%")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(AppTheme.muted.opacity(0.7))
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .help(project == nil ? "未归属项目的会话" : "打开项目页")
    }
}

private struct ConversationListRow: View {
    var conversation: ConversationSummary
    var selected: Bool
    var onSelect: () -> Void
    var onTogglePin: () -> Void
    var onRename: (String) -> Void
    var onDelete: () -> Void
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        Button(action: { if !isRenaming { onSelect() } }) {
            HStack(spacing: 8) {
                Image(systemName: conversation.pinned ? "pin.fill" : "bubble.left")
                    .font(.caption)
                    .frame(width: 14)
                    .foregroundStyle(conversation.pinned ? AppTheme.coral : AppTheme.muted)
                if isRenaming {
                    TextField("对话名称", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isRenameFieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { isRenaming = false }
                        .onChange(of: isRenameFieldFocused) { _, focused in
                            if !focused, isRenaming { commitRename() }
                        }
                } else {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isHovering, !isRenaming {
                    Button(action: startRename) {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("重命名对话")

                    Button(action: onTogglePin) {
                        Image(systemName: conversation.pinned ? "pin.slash" : "pin")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .help(conversation.pinned ? "取消置顶" : "置顶对话")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("删除对话")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? AppTheme.coral : AppTheme.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? AppTheme.rose.opacity(0.75) : (isHovering ? AppTheme.rose.opacity(0.35) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("重命名…", action: startRename)
            Button(conversation.pinned ? "取消置顶" : "置顶对话", action: onTogglePin)
            Button("删除对话…", role: .destructive, action: onDelete)
        }
    }

    private func startRename() {
        draftTitle = conversation.title
        isRenaming = true
        isRenameFieldFocused = true
    }

    private func commitRename() {
        isRenaming = false
        onRename(draftTitle)
    }
}

/// 「对话」分组头部：折叠开关 + 新建按钮。抽成独立 struct 与 NavItem
/// 同构——内联在 conversationListSection 里的等价按钮收不到点击（疑似
/// SwiftUI 对内联闭包按钮的命中测试问题），抽出后正常。
private struct ConversationListHeader: View {
    @Binding var isExpanded: Bool
    var onNew: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                    Text("对话")
                        .font(.caption)
                        .foregroundStyle(AppTheme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Spacer 在两个按钮之间——不能塞进折叠按钮的 label，否则它撑满
            // 整行、contentShape 盖住 + 的命中区，+ 就永远点不到。
            Spacer()

            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.coral)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.coral.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新建对话")
        }
    }
}

private struct NavItem: View {
    var icon: String
    var title: String
    var selected: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? AppTheme.coral : AppTheme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(selected ? AppTheme.rose.opacity(0.75) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

