import SwiftUI
import UniformTypeIdentifiers

/// 项目: the list page. Each project is a unit of ongoing work — goal,
/// brief, a plan checklist shared with the agent, a working directory that
/// collects deliverables, and the conversations that belong to it.
struct ProjectsWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var editingProject: Project?

    private var activeProjects: [Project] {
        model.projects.filter { $0.status == .active }
    }

    var body: some View {
        WorkspacePage(title: "项目", subtitle: "一个项目 = 一件要做完的事：目标、计划、相关会话和成果物都聚在这里") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "进行中", value: "\(activeProjects.count)", icon: "hammer")
                WorkspaceMetric(title: "全部", value: "\(model.projects.count)", icon: "folder")
                Spacer()
                WorkspaceActionButton(title: "新建项目", icon: "plus") {
                    editingProject = model.addProject()
                }
            }

            WorkspacePanel(title: "全部项目", trailing: model.projects.isEmpty ? "空" : "\(model.projects.count)") {
                if model.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyWorkspaceLine(icon: "folder.badge.plus", text: "还没有项目。会话是一次聊天，项目是一件要做完的事——比如做一个小工具、写一份材料。")
                        Text("新建一个项目写下目标，或者直接在聊天里说「帮我做个计划」，Her 会自动帮你立项。每个项目有自己的工作目录，成果物都归档在里面。")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.projects) { project in
                            ProjectRow(
                                project: project,
                                conversationCount: model.conversations(in: project).count,
                                onOpen: { editingProject = project },
                                onReveal: { model.revealProjectDirectory(project) },
                                onDelete: { model.deleteProject(project.id) }
                            )
                        }
                    }
                }
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectEditor(project: project) { updated in
                model.updateProject(updated)
            }
        }
    }
}

/// One project in the list. The whole row opens the editor (name, goal,
/// brief, and plan are all edited there); Finder/delete ride on the right.
private struct ProjectRow: View {
    var project: Project
    var conversationCount: Int
    var onOpen: () -> Void
    var onReveal: () -> Void
    var onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(project.emoji.isEmpty ? "📁" : project.emoji)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(project.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        if project.status != .active {
                            Text(project.status.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(AppTheme.muted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.05))
                                .clipShape(Capsule())
                        }
                    }
                    if let next = project.nextStep {
                        Text("下一步：\(next.title)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                    } else if !project.goal.isEmpty {
                        Text(project.goal)
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                    } else {
                        Text("点击填写目标和计划")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted.opacity(0.7))
                    }
                    if project.plan != nil {
                        ProgressView(value: project.progress)
                            .tint(AppTheme.coral)
                            .frame(maxWidth: 220)
                    }
                }
                Spacer()
                if conversationCount > 0 {
                    Label("\(conversationCount)", systemImage: "bubble.left")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .help("归属此项目的会话")
                }
                Button(action: onReveal) {
                    Image(systemName: "folder")
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("在 Finder 中打开工作目录")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("删除项目（工作目录里的成果物会保留）")
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted.opacity(0.6))
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering ? AppTheme.rose.opacity(0.4) : Color.white.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("编辑项目…", action: onOpen)
            Button("在 Finder 中打开工作目录", action: onReveal)
            Button("删除项目…", role: .destructive, action: onDelete)
        }
    }
}

/// The project detail editor: identity + working directory in the header,
/// then plan checklist / brief / conversations panes.
private struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppViewModel
    @State var project: Project
    let onSave: (Project) -> Void
    @State private var pane: Pane = .plan
    @State private var isPickingDirectory = false
    @FocusState private var nameFocused: Bool

    private enum Pane: String, CaseIterable, Identifiable {
        case plan = "计划"
        case brief = "背景"
        case conversations = "会话"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Identity header, same language as the roleplay editors.
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
                    TextField("📁", text: $project.emoji)
                        .font(.system(size: 22))
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .frame(width: 36)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    TextField("项目名", text: $project.name)
                        .font(.system(size: 19, weight: .semibold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(AppTheme.ink)
                        .focused($nameFocused)
                    TextField("一句话目标：这个项目做成什么样算完成", text: $project.goal)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Picker("", selection: $project.status) {
                    ForEach(Project.Status.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 10)

            // Working directory: where every deliverable of this project
            // lands. Default is <workspace>/projects/<名>.
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(AppTheme.coral)
                Text(model.projectDirectoryURL(project).path)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("这个项目的工作目录，所有成果物都保存在这里")
                Spacer()
                Button("更改…") { isPickingDirectory = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(AppTheme.coral)
                if !project.directoryPath.isEmpty {
                    Button("恢复默认") { project.directoryPath = "" }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Button {
                    var current = project
                    onSave(current)
                    model.revealProjectDirectory(current)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("在 Finder 中打开")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.025))
            .fileImporter(isPresented: $isPickingDirectory, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    project.directoryPath = url.path
                }
            }

            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(.vertical, 12)

            Group {
                switch pane {
                case .plan:
                    ProjectPlanPane(plan: $project.plan, goal: project.goal)
                case .brief:
                    VStack(alignment: .leading, spacing: 8) {
                        ProjectTextEditor(text: $project.brief)
                        Text("项目背景与约束——整段注入系统提示词，Her 干活时会带着这些上下文。")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted.opacity(0.85))
                    }
                    .padding(.horizontal, 24)
                case .conversations:
                    ProjectConversationsPane(project: project) {
                        onSave(project)
                        dismiss()
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.4)

            HStack {
                Text("计划由你和 Her 共同维护：她通过 workspace.plan 更新的就是这份")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted.opacity(0.85))
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(project)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .keyboardShortcut(.defaultAction)
                .disabled(project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 600)
        .background(AppTheme.cream)
        .onAppear {
            if project.name.isEmpty || project.name == "新项目" { nameFocused = true }
        }
    }
}

/// The editable plan checklist: click the leading mark to cycle a step
/// 待办 → 进行中 → 已完成; add and remove steps freely. The agent writes the
/// same data through workspace.plan.
private struct ProjectPlanPane: View {
    @Binding var plan: WorkPlan?
    var goal: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let planValue = plan, !planValue.steps.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(planValue.steps.indices, id: \.self) { index in
                            ProjectStepRow(
                                step: planValue.steps[index],
                                onCycle: { cycleStep(at: index) },
                                onDelete: { removeStep(at: index) }
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28))
                        .foregroundStyle(AppTheme.muted.opacity(0.5))
                    Text("还没有计划步骤。自己添加，或在聊天里说「帮我做个计划」。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                addStep()
            } label: {
                Label("添加步骤", systemImage: "plus")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.coral)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

    private func ensurePlan() -> WorkPlan {
        plan ?? WorkPlan(
            goal: goal.isEmpty ? "完成项目" : goal,
            source: "user",
            steps: [],
            risks: [],
            verification: []
        )
    }

    private func addStep() {
        var updated = ensurePlan()
        updated.steps.append(WorkPlan.Step(title: "新步骤"))
        updated.updatedAt = Date()
        plan = updated
    }

    private func removeStep(at index: Int) {
        guard var updated = plan, updated.steps.indices.contains(index) else { return }
        updated.steps.remove(at: index)
        updated.updatedAt = Date()
        plan = updated
    }

    private func cycleStep(at index: Int) {
        guard var updated = plan, updated.steps.indices.contains(index) else { return }
        let next: WorkPlanStepStatus
        switch updated.steps[index].status {
        case .pending: next = .inProgress
        case .inProgress: next = .done
        case .done: next = .pending
        case .blocked: next = .pending
        }
        updated.steps[index].status = next
        updated.updatedAt = Date()
        plan = updated
    }
}

private struct ProjectStepRow: View {
    var step: WorkPlan.Step
    var onCycle: () -> Void
    var onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onCycle) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help("点击切换：待办 → 进行中 → 已完成")
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .strikethrough(step.status == .done, color: AppTheme.muted)
                if let detail = step.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                }
            }
            Spacer()
            if step.status == .blocked {
                Text("受阻")
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
            }
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("删除步骤")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
    }

    private var icon: String {
        switch step.status {
        case .pending: return "circle"
        case .inProgress: return "clock"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch step.status {
        case .pending: return AppTheme.muted
        case .inProgress: return AppTheme.coral
        case .done: return Color.green.opacity(0.85)
        case .blocked: return Color.orange
        }
    }
}

/// Conversations that belong to this project, plus starting a new one in it.
private struct ProjectConversationsPane: View {
    @EnvironmentObject private var model: AppViewModel
    var project: Project
    /// Saves pending edits and closes the sheet before jumping to chat.
    var saveAndDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let conversations = model.conversations(in: project)
            if conversations.isEmpty {
                Text("还没有会话归属这个项目。在会话工具栏的「项目」菜单里选择它，或直接从这里开始。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(conversations) { conversation in
                            Button {
                                saveAndDismiss()
                                model.switchConversation(to: conversation.id)
                                model.selectedSection = .today
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "bubble.left")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.muted)
                                    Text(conversation.title)
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppTheme.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(conversation.updatedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                }
                                .padding(8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Button {
                saveAndDismiss()
                model.newConversation(in: project)
                model.selectedSection = .today
            } label: {
                Label("在此项目中新建会话", systemImage: "plus.bubble")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.coral)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }
}

/// A soft, borderless editing surface; fills its pane.
private struct ProjectTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .lineSpacing(2.5)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
