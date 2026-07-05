import SwiftUI

struct SidebarView: View {
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
        .background(.ultraThinMaterial)
    }

    private var conversationListSection: some View {
        DisclosureGroup(isExpanded: $isConversationListExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sortedConversations) { conversation in
                        ConversationListRow(
                            conversation: conversation,
                            selected: conversation.id == model.activeConversationID,
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
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 340)
        } label: {
            HStack {
                Text("对话")
                    .font(.caption)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button {
                    model.newLocalConversation()
                    model.selectedSection = .today
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(AppTheme.coral)
                }
                .buttonStyle(.plain)
                .help("新建对话")
            }
        }
        .tint(AppTheme.muted)
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

    private func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "H" }
        return String(first).uppercased()
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

