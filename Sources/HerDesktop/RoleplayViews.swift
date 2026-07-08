import SwiftUI

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
    @State var card: CharacterCard
    let onSave: (CharacterCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑角色卡")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            HStack(spacing: 8) {
                TextField("表情", text: $card.emoji)
                    .frame(width: 52)
                TextField("角色名", text: $card.name)
            }
            TextField("一句话简介（列表里展示）", text: $card.summary)
            Text("角色设定（性格、说话方式、背景、边界——会注入系统提示词）")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            TextEditor(text: $card.prompt)
                .font(.system(size: 13))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.1)))
            Text("开场白（选择该角色时由 TA 说出，可留空）")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            TextEditor(text: $card.greeting)
                .font(.system(size: 13))
                .frame(minHeight: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.1)))
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(card)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
            }
        }
        .padding(20)
        .frame(width: 520)
        .textFieldStyle(.roundedBorder)
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
    @State var book: WorldBook
    let onSave: (WorldBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑世界之书")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            HStack(spacing: 8) {
                TextField("表情", text: $book.emoji)
                    .frame(width: 52)
                TextField("世界名", text: $book.name)
            }
            TextField("一句话简介", text: $book.summary)

            HStack {
                Text("条目（常驻 = 始终注入；否则对话最近内容提到任一关键词才注入）")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Button {
                    book.entries.append(WorldBook.Entry())
                } label: {
                    Label("加条目", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($book.entries) { $entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("条目标题", text: $entry.title)
                                Toggle("常驻", isOn: $entry.alwaysOn)
                                    .toggleStyle(.checkbox)
                                Button {
                                    book.entries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(AppTheme.muted)
                                }
                                .buttonStyle(.plain)
                            }
                            if !entry.alwaysOn {
                                TextField("触发关键词（逗号/空格分隔）", text: $entry.keywords)
                            }
                            TextEditor(text: $entry.content)
                                .font(.system(size: 12))
                                .frame(minHeight: 60)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 360)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(book)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
            }
        }
        .padding(20)
        .frame(width: 560)
        .textFieldStyle(.roundedBorder)
    }
}

// MARK: - Shared row

private struct RoleplayAssetRow: View {
    var emoji: String
    var name: String
    var summary: String
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(emoji.isEmpty ? "🎭" : emoji)
                .font(.title3)
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
