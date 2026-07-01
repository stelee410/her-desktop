import XCTest
@testable import HerDesktop

final class ProjectPromptLoaderTests: XCTestCase {
    func testLoadsSoulAndProjectInstructionsFromDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-desktop-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "测试人格".write(to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try "测试项目说明".write(to: root.appendingPathComponent("INFINITI.md"), atomically: true, encoding: .utf8)

        let docs = ProjectPromptLoader.load(cwd: root)

        XCTAssertEqual(docs.soul, "测试人格")
        XCTAssertEqual(docs.project, "测试项目说明")
    }

    func testFallsBackToBundledPromptDefaults() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-desktop-prompt-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docs = ProjectPromptLoader.load(cwd: root)

        XCTAssertTrue(docs.soul.contains("Mac 原生的 AI 数字合伙人"))
        XCTAssertTrue(docs.soul.contains("温暖，但不表演"))
        XCTAssertTrue(docs.project.contains("Her Desktop 当前架构边界"))
        XCTAssertTrue(docs.project.contains("plugin manifest"))
        XCTAssertTrue(docs.project.contains("vibe coding"))
    }
}
