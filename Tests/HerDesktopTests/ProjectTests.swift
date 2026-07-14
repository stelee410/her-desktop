import XCTest
@testable import HerDesktop

@MainActor
final class ProjectTests: XCTestCase {
    private func makeRoot(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-project-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    func testStoreRoundTripAndTolerantDecoding() throws {
        let root = makeRoot("store")
        let store = ProjectStore(cwd: root.path)
        var project = Project(name: "收音机小工具", goal: "能在线收听全球电台")
        project.plan = WorkPlan(
            goal: "做收音机",
            source: "user",
            steps: [.init(title: "选电台 API"), .init(title: "做播放器", status: .done)],
            risks: [],
            verification: []
        )
        try store.save([project])

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.name), ["收音机小工具"])
        XCTAssertEqual(loaded.first?.plan?.steps.count, 2)
        XCTAssertEqual(loaded.first?.status, .active)

        // A minimal record written by an older build decodes with defaults
        // instead of tripping the corrupt-file path.
        let legacy = """
        {"version":1,"projects":[{"id":"1B0B1E9A-3C63-45E0-9E1B-3A1111111111","name":"老项目"}]}
        """
        try Data(legacy.utf8).write(to: store.fileURL)
        let legacyLoaded = store.load()
        XCTAssertEqual(legacyLoaded.first?.name, "老项目")
        XCTAssertEqual(legacyLoaded.first?.directoryPath, "")
        XCTAssertEqual(legacyLoaded.first?.status, .active)
    }

    func testWorkingDirectoryDefaultAndCustom() throws {
        let root = makeRoot("dir")
        let store = ProjectStore(cwd: root.path)
        var project = Project(name: "报告/初稿:v1")

        // Default: <workspace>/projects/<sanitized>-<id8>, created on demand.
        let defaultURL = try store.ensureDirectory(for: project)
        XCTAssertTrue(defaultURL.path.hasPrefix(root.appendingPathComponent("projects").path))
        XCTAssertFalse(defaultURL.lastPathComponent.contains("/"))
        XCTAssertFalse(defaultURL.lastPathComponent.contains(":"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultURL.path))

        // Custom path wins.
        let custom = root.appendingPathComponent("elsewhere", isDirectory: true)
        project.directoryPath = custom.path
        XCTAssertEqual(store.directoryURL(for: project).path, custom.standardizedFileURL.path)
    }

    func testLegacyWorkPlanMigratesIntoProject() throws {
        let root = makeRoot("migrate")
        let planStore = WorkPlanStore(cwd: root.path)
        _ = try planStore.save(WorkPlan(
            goal: "整理旧计划",
            source: "test",
            steps: [.init(title: "第一步")],
            risks: [],
            verification: []
        ))

        let model = AppViewModel(cwd: root.path)
        model.loadProjects()
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.projects.first?.goal, "整理旧计划")
        XCTAssertEqual(model.projects.first?.plan?.steps.count, 1)

        // Migration is one-time: reloading keeps a single project.
        model.loadProjects()
        XCTAssertEqual(model.projects.count, 1)
    }

    func testPlanRoutingFoundsProjectAndUpdatesBoundOne() {
        let root = makeRoot("route")
        let model = AppViewModel(cwd: root.path)
        let plan = WorkPlan(
            goal: "做一个天气小组件",
            source: "conversation",
            steps: [.init(title: "查天气 API")],
            risks: [],
            verification: []
        )

        // Unbound conversation: the plan founds a project and joins it.
        let note = model.routePlanIntoProject(plan)
        XCTAssertTrue(note.contains("创建"))
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.activeProject?.goal, "做一个天气小组件")

        // Bound conversation: a second plan updates the same project.
        var updated = plan
        updated.steps.append(.init(title: "画界面", status: .inProgress))
        let secondNote = model.routePlanIntoProject(updated)
        XCTAssertTrue(secondNote.contains("更新"))
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.projects.first?.plan?.steps.count, 2)
    }

    func testProjectPromptSectionStates() {
        let root = makeRoot("prompt")
        let model = AppViewModel(cwd: root.path)

        // No project bound → the founding rule is injected.
        XCTAssertTrue(model.projectPromptSection().contains("项目意识"))

        // Bound project → goal, working directory, and plan state.
        let project = model.addProject(name: "口琴练习计划", goal: "三个月学会十二小节布鲁斯")
        model.setProject(project)
        let section = model.projectPromptSection()
        XCTAssertTrue(section.contains("口琴练习计划"))
        XCTAssertTrue(section.contains("三个月学会十二小节布鲁斯"))
        XCTAssertTrue(section.contains("工作目录"))
        XCTAssertTrue(section.contains("workspace.plan"))
    }

    func testConversationBindingSurvivesAndGroups() {
        let root = makeRoot("binding")
        let model = AppViewModel(cwd: root.path)
        let project = model.addProject(name: "股票追踪")
        model.setProject(project)
        XCTAssertEqual(model.conversations(in: project).count, 1)

        model.newConversation(in: project)
        XCTAssertEqual(model.conversations(in: project).count, 2)

        // Deleting the project unbinds its conversations.
        model.deleteProject(project.id)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNil(model.activeProject)
    }
}
