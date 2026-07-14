import AppKit
import Foundation

/// 项目: ongoing work units. CRUD, per-conversation binding, the working
/// directory that collects deliverables, and prompt injection.
extension AppViewModel {
    // MARK: - Load / persist / migration

    func loadProjects() {
        projects = projectStore.load()
        migrateLegacyWorkPlanIfNeeded()
    }

    func persistProjects() {
        do {
            try projectStore.save(projects)
        } catch {
            lastError = "项目未能保存：\(error.localizedDescription)"
        }
    }

    /// One-time migration: the old single global work plan becomes the first
    /// project, so nothing already planned gets lost.
    private func migrateLegacyWorkPlanIfNeeded() {
        guard projects.isEmpty, let plan = workPlan else { return }
        let name = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            name: name.isEmpty ? "我的计划" : String(name.prefix(24)),
            goal: plan.goal,
            plan: plan
        )
        projects = [project]
        persistProjects()
        audit(
            type: "project.migrated",
            summary: "Migrated the legacy work plan into a project.",
            metadata: ["project": project.name]
        )
    }

    // MARK: - CRUD

    @discardableResult
    func addProject(name: String = "新项目", goal: String = "") -> Project {
        let project = Project(name: name, goal: goal)
        projects.insert(project, at: 0)
        persistProjects()
        return project
    }

    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.updatedAt = Date()
        projects[index] = updated
        persistProjects()
    }

    /// Removes the project record; its working directory (the deliverables)
    /// is intentionally left on disk.
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for index in conversations.indices where conversations[index].projectID == id.uuidString {
            conversations[index].projectID = nil
        }
        persistProjects()
        persistConversationIndex()
    }

    // MARK: - Conversation binding

    var activeProject: Project? {
        guard let raw = activeConversationSummary?.projectID,
              let id = UUID(uuidString: raw) else { return nil }
        return projects.first { $0.id == id }
    }

    /// Binds the active conversation to a project (nil unbinds).
    func setProject(_ project: Project?) {
        guard let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        conversations[index].projectID = project?.id.uuidString
        persistConversationIndex()
        audit(
            type: "project.conversation_bound",
            summary: project.map { "Conversation joined project \($0.name)." } ?? "Conversation left its project.",
            metadata: ["sessionID": activeConversationID, "project": project?.name ?? "none"]
        )
    }

    func conversations(in project: Project) -> [ConversationSummary] {
        conversations.filter { $0.projectID == project.id.uuidString }
    }

    /// Starts a fresh conversation already belonging to the project.
    func newConversation(in project: Project) {
        newLocalConversation()
        if let index = conversations.firstIndex(where: { $0.id == activeConversationID }) {
            conversations[index].projectID = project.id.uuidString
            persistConversationIndex()
        }
    }

    // MARK: - Working directory

    func projectDirectoryURL(_ project: Project) -> URL {
        projectStore.directoryURL(for: project)
    }

    /// Opens the project's working directory in Finder, creating it first so
    /// the reveal never lands on a missing folder.
    func revealProjectDirectory(_ project: Project) {
        do {
            let url = try projectStore.ensureDirectory(for: project)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            lastError = "无法打开项目目录：\(error.localizedDescription)"
        }
    }

    // MARK: - Plan routing (workspace.plan)

    /// Routes a plan saved via workspace.plan into the project system: a
    /// conversation already in a project updates that project's plan; an
    /// unbound conversation founds a NEW project from the plan and joins it.
    /// That second path is how "主动立项" works end to end — Her proposes,
    /// the user agrees, she calls workspace.plan, and the project exists.
    /// Returns a user-facing description of where the plan landed.
    func routePlanIntoProject(_ plan: WorkPlan) -> String {
        if let project = activeProject {
            var updated = project
            updated.plan = plan
            if updated.goal.isEmpty { updated.goal = plan.goal }
            updateProject(updated)
            return "计划已更新到项目「\(updated.name)」"
        }
        let name = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            name: name.isEmpty ? "新项目" : String(name.prefix(24)),
            goal: plan.goal,
            plan: plan
        )
        projects.insert(project, at: 0)
        persistProjects()
        setProject(project)
        audit(
            type: "project.founded_from_plan",
            summary: "Created project from a saved plan.",
            metadata: ["project": project.name]
        )
        return "已自动创建项目「\(project.name)」并把这段对话归入其中"
    }

    // MARK: - Prompt injection

    /// The project section for the system prompt. With a bound project it
    /// injects goal/brief/working directory/plan state; without one it
    /// injects the founding rule — unless this is a roleplay conversation,
    /// which should never be pestered about projects.
    func projectPromptSection() -> String {
        guard let project = activeProject else {
            if activeCharacterCard != nil { return "" }
            return """
            ## 项目意识
            当这段对话明显在推进一件需要多轮才能完成的具体事情（做一个工具、写一份材料、一个持续的计划），而它还没归属任何项目时：主动提议「要不要把这件事建成一个项目？我来把目标和步骤整理进去」。用户同意后，调用 workspace.plan 保存目标与步骤——系统会自动创建项目并把这段对话归入其中。同一件事只提议一次，用户拒绝就不再提。
            """
        }
        var lines: [String] = ["## 当前项目 · \(project.emoji) \(project.name)（\(project.status.displayName)）"]
        let goal = project.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { lines.append("目标：\(goal)") }
        let brief = project.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty { lines.append("背景：\n\(brief)") }
        lines.append("""
        工作目录：\(projectStore.directoryURL(for: project).path)
        本项目的所有成果物（文件、代码、文档、生成的资源）都保存到这个目录里；引用产物时给出该目录下的路径。
        """)
        if let plan = project.plan, !plan.steps.isEmpty {
            let steps = plan.steps.map { step in
                let mark: String
                switch step.status {
                case .done: mark = "[x]"
                case .inProgress: mark = "[~]"
                case .blocked: mark = "[!]"
                case .pending: mark = "[ ]"
                }
                return "- \(mark) \(step.title)"
            }
            lines.append("计划进度：\n" + steps.joined(separator: "\n"))
            lines.append("完成或调整步骤后调用 workspace.plan 更新计划（它写入本项目，用户在项目页看到同一份）。")
        } else {
            lines.append("本项目还没有计划。请在合适的时机调用 workspace.plan 为它保存一份可执行的步骤计划。")
        }
        return lines.joined(separator: "\n")
    }
}
