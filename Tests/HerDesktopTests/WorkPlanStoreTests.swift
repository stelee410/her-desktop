import XCTest
@testable import HerDesktop

final class WorkPlanStoreTests: XCTestCase {
    func testSaveAndLoadWorkPlanUnderWorkspaceDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-work-plan-store-\(UUID().uuidString)", isDirectory: true)
        let store = WorkPlanStore(cwd: root.path)
        let plan = WorkPlan(
            goal: "Ship durable planning.",
            source: "workspace_plan",
            steps: [
                .init(title: "Add store", status: .done),
                .init(title: "Render UI", status: .inProgress, detail: "Projects workspace panel.")
            ],
            risks: ["Do not treat plan as authority."],
            verification: ["swift test"]
        )

        let url = try store.save(plan)
        let loaded = try store.load()

        XCTAssertEqual(url.path, root.appendingPathComponent(".her/workspace/work-plan.json").path)
        XCTAssertEqual(loaded?.goal, "Ship durable planning.")
        XCTAssertEqual(loaded?.steps.map(\.title), ["Add store", "Render UI"])
        XCTAssertEqual(loaded?.steps.last?.status, .inProgress)
        XCTAssertEqual(loaded?.risks, ["Do not treat plan as authority."])
        XCTAssertEqual(loaded?.verification, ["swift test"])
    }
}
