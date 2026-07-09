import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Disk-image cache for roleplay avatars/backgrounds. Filenames are unique
/// per import, so entries never go stale — a replaced image gets a new key.
enum RoleplayImageCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Runs the shared security-scope dance for a fileImporter pick and imports
/// the image into the workspace; returns the stored filename.
@MainActor
func importPickedRoleplayImage(_ result: Result<URL, Error>, prefix: String, model: AppViewModel) -> String? {
    guard case .success(let url) = result else { return nil }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return model.importRoleplayAsset(from: url, prefix: prefix)
}

// MARK: - 角色卡

struct CharactersWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var editingCard: CharacterCard?

    var body: some View {
        WorkspacePage(title: "角色卡", subtitle: "编辑 Her 可以扮演的角色；在对话工具栏为每个会话选择") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "角色", value: "\(model.characterCards.count)", icon: "theatermasks")
                Spacer()
                WorkspaceActionButton(title: "新建角色", icon: "plus") {
                    editingCard = model.addCharacterCard()
                }
            }

            WorkspacePanel(title: "全部角色", trailing: model.characterCards.isEmpty ? "空" : "\(model.characterCards.count)") {
                if model.characterCards.isEmpty {
                    EmptyWorkspaceLine(icon: "theatermasks", text: "还没有角色卡。新建一个，写下 TA 的性格、说话方式和背景。")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.characterCards) { card in
                            RoleplayAssetRow(
                                emoji: card.emoji,
                                avatarURL: model.roleplayAssetURL(card.avatarPath),
                                name: card.name,
                                summary: card.summary.isEmpty
                                    ? String(card.prompt.prefix(60))
                                    : card.summary,
                                onEdit: { editingCard = card },
                                onDelete: { model.deleteCharacterCard(card.id) }
                            )
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCard) { card in
            CharacterCardEditor(card: card) { updated in
                model.updateCharacterCard(updated)
            }
        }
    }
}

private struct CharacterCardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppViewModel
    @State var card: CharacterCard
    let onSave: (CharacterCard) -> Void
    @State private var usesDedicatedMemory: Bool
    @State private var pane: Pane = .persona
    @State private var isPickingAvatar = false
    @FocusState private var nameFocused: Bool

    private enum Pane: String, CaseIterable, Identifiable {
        case persona = "人设"
        case greeting = "开场白"
        case memory = "记忆"
        var id: String { rawValue }
    }

    init(card: CharacterCard, onSave: @escaping (CharacterCard) -> Void) {
        _card = State(initialValue: card)
        self.onSave = onSave
        _usesDedicatedMemory = State(initialValue: card.dedicatedMemoryKey != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Compact identity header.
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.rose, AppTheme.rose.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if let url = model.roleplayAssetURL(card.avatarPath),
                       let avatar = RoleplayImageCache.image(at: url) {
                        Image(nsImage: avatar)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(Circle())
                    } else {
                        TextField("🎭", text: $card.emoji)
                            .font(.system(size: 22))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .frame(width: 36)
                    }
                }
                .frame(width: 48, height: 48)
                .overlay(alignment: .bottomTrailing) {
                    Menu {
                        Button(card.avatarPath.isEmpty ? "选择头像图片…" : "更换头像图片…") {
                            isPickingAvatar = true
                        }
                        if !card.avatarPath.isEmpty {
                            Button("移除头像，改用 emoji") { card.avatarPath = "" }
                        }
                    } label: {
                        Image(systemName: "photo.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.coral)
                            .background(Circle().fill(.white))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .offset(x: 5, y: 5)
                    .help("头像图片；未设置时用 emoji")
                }
                .fileImporter(isPresented: $isPickingAvatar, allowedContentTypes: [.image]) { result in
                    if let name = importPickedRoleplayImage(result, prefix: "avatar", model: model) {
                        card.avatarPath = name
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    TextField("角色名", text: $card.name)
                        .font(.system(size: 19, weight: .semibold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(AppTheme.ink)
                        .focused($nameFocused)
                    TextField("一句话介绍这个角色", text: $card.summary)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // Tabs: one full-height panel per section.
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(.bottom, 14)

            Group {
                switch pane {
                case .persona:
                    EditorPane(caption: "性格、说话方式、背景、边界——整段注入系统提示词。") {
                        SoftTextEditor(text: $card.prompt)
                    }
                case .greeting:
                    EditorPane(caption: "选中该角色时由 TA 说出第一句；留空则安静登场。") {
                        SoftTextEditor(text: $card.greeting)
                    }
                case .memory:
                    EditorPane(caption: nil) {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("", selection: $usesDedicatedMemory) {
                                Text("无记忆").tag(false)
                                Text("专属记忆").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)

                            if usesDedicatedMemory {
                                SecureField("该角色专属的 AgentMem Key", text: $card.agentMemAPIKey)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color.black.opacity(0.035))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text("角色拥有独立的记忆身份，与全局记忆互不相通。")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            } else {
                                Text("扮演不会写入你的真实关系记忆。")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.4)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    var saved = card
                    if !usesDedicatedMemory { saved.agentMemAPIKey = "" }
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .keyboardShortcut(.defaultAction)
                .disabled(card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 560)
        .background(AppTheme.cream)
        .onAppear {
            if card.name.isEmpty || card.name == "新角色" { nameFocused = true }
        }
    }
}

/// One tab's full-height editing surface with an optional footnote.
private struct EditorPane<Content: View>: View {
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted.opacity(0.85))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

/// A soft, borderless editing surface (no harsh strokes); fills its pane.
private struct SoftTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 0

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .lineSpacing(2.5)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: minHeight, maxHeight: .infinity)
            .background(Color.black.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 世界之书

struct WorldBooksWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var editingBook: WorldBook?

    var body: some View {
        WorkspacePage(title: "世界之书", subtitle: "世界观设定集：常驻条目始终生效，关键词条目在对话提到时注入") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "世界", value: "\(model.worldBooks.count)", icon: "book.closed")
                Spacer()
                WorkspaceActionButton(title: "新建世界", icon: "plus") {
                    editingBook = model.addWorldBook()
                }
            }

            WorkspacePanel(title: "全部世界", trailing: model.worldBooks.isEmpty ? "空" : "\(model.worldBooks.count)") {
                if model.worldBooks.isEmpty {
                    EmptyWorkspaceLine(icon: "book.closed", text: "还没有世界之书。新建一个，把世界观拆成条目：常驻背景 + 按关键词触发的细节。")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.worldBooks) { book in
                            RoleplayAssetRow(
                                emoji: book.emoji,
                                name: book.name,
                                summary: book.summary.isEmpty
                                    ? "\(book.entries.count) 个条目"
                                    : book.summary,
                                onEdit: { editingBook = book },
                                onDelete: { model.deleteWorldBook(book.id) }
                            )
                        }
                    }
                }
            }
        }
        .sheet(item: $editingBook) { book in
            WorldBookEditor(book: book) { updated in
                model.updateWorldBook(updated)
            }
        }
    }
}

private struct WorldBookEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppViewModel
    @State var book: WorldBook
    let onSave: (WorldBook) -> Void
    @State private var selectedEntryID: UUID?
    @State private var isPickingBackground = false
    @FocusState private var nameFocused: Bool

    init(book: WorldBook, onSave: @escaping (WorldBook) -> Void) {
        _book = State(initialValue: book)
        self.onSave = onSave
        _selectedEntryID = State(initialValue: book.entries.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Compact identity header, same language as the character editor.
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.rose, AppTheme.rose.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    TextField("📖", text: $book.emoji)
                        .font(.system(size: 22))
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .frame(width: 36)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    TextField("世界名", text: $book.name)
                        .font(.system(size: 19, weight: .semibold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(AppTheme.ink)
                        .focused($nameFocused)
                    TextField("一句话描述这个世界", text: $book.summary)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()

                // Chat background: shown behind the transcript of any
                // conversation that adopts this world.
                Menu {
                    Button(book.backgroundPath.isEmpty ? "选择背景图片…" : "更换背景图片…") {
                        isPickingBackground = true
                    }
                    if !book.backgroundPath.isEmpty {
                        Button("移除背景") { book.backgroundPath = "" }
                    }
                } label: {
                    if let url = model.roleplayAssetURL(book.backgroundPath),
                       let backdrop = RoleplayImageCache.image(at: url) {
                        Image(nsImage: backdrop)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )
                    } else {
                        VStack(spacing: 3) {
                            Image(systemName: "photo")
                                .font(.system(size: 13))
                            Text("聊天背景")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(AppTheme.muted)
                        .frame(width: 76, height: 46)
                        .background(Color.black.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("启用这个世界的会话，聊天区会铺上这张背景")
                .fileImporter(isPresented: $isPickingBackground, allowedContentTypes: [.image]) { result in
                    if let name = importPickedRoleplayImage(result, prefix: "backdrop", model: model) {
                        book.backgroundPath = name
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().opacity(0.4)

            // Master–detail: entry list on the left, one full editing panel
            // on the right.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(book.entries) { entry in
                                EntryListRow(
                                    entry: entry,
                                    selected: entry.id == selectedEntryID
                                ) {
                                    selectedEntryID = entry.id
                                }
                            }
                        }
                        .padding(8)
                    }
                    Divider().opacity(0.4)
                    Button {
                        let entry = WorldBook.Entry()
                        book.entries.append(entry)
                        selectedEntryID = entry.id
                    } label: {
                        Label("添加条目", systemImage: "plus")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.coral)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 180)
                .background(Color.black.opacity(0.02))

                Divider().opacity(0.4)

                Group {
                    if let index = book.entries.firstIndex(where: { $0.id == selectedEntryID }) {
                        WorldBookEntryPanel(entry: $book.entries[index]) {
                            let removedID = book.entries[index].id
                            book.entries.remove(at: index)
                            if selectedEntryID == removedID {
                                selectedEntryID = book.entries.first?.id
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 28))
                                .foregroundStyle(AppTheme.muted.opacity(0.5))
                            Text("选择左侧条目，或添加一个新条目")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.4)

            HStack {
                Text("常驻条目始终注入；关键词条目只在对话提到时注入")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted.opacity(0.85))
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(book)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .keyboardShortcut(.defaultAction)
                .disabled(book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 560)
        .background(AppTheme.cream)
        .onAppear {
            if book.name.isEmpty || book.name == "新世界" { nameFocused = true }
        }
    }
}

/// One row in the entry list: title + trigger mode at a glance.
private struct EntryListRow: View {
    var entry: WorldBook.Entry
    var selected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: entry.alwaysOn ? "pin" : "key")
                    .font(.caption2)
                    .foregroundStyle(selected ? AppTheme.coral : AppTheme.muted)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title.isEmpty ? "未命名条目" : entry.title)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Text(entry.alwaysOn ? "常驻" : (entry.keywordList.isEmpty ? "未设关键词" : entry.keywordList.joined(separator: " · ")))
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? AppTheme.rose.opacity(0.6) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The full editing panel for one entry.
private struct WorldBookEntryPanel: View {
    @Binding var entry: WorldBook.Entry
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("条目标题", text: $entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .textFieldStyle(.plain)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Picker("", selection: $entry.alwaysOn) {
                    Text("关键词").tag(false)
                    Text("常驻").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("删除条目")
            }

            if !entry.alwaysOn {
                TextField("触发关键词，逗号分隔（如：宝藏, 骷髅岛）", text: $entry.keywords)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            SoftTextEditor(text: $entry.content)
        }
        .padding(16)
    }
}

// MARK: - Shared row

private struct RoleplayAssetRow: View {
    var emoji: String
    var avatarURL: URL?
    var name: String
    var summary: String
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let avatarURL, let avatar = RoleplayImageCache.image(at: avatarURL) {
                Image(nsImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } else {
                Text(emoji.isEmpty ? "🎭" : emoji)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("编辑", action: onEdit)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(10)
        .background(Color.white.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
