import XCTest
@testable import HerDesktop

final class DreamPromptContextTests: XCTestCase {
    func testLoadsHerDreamPromptContextBeforeInfinitiFallback() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-dream-context-\(UUID().uuidString)", isDirectory: true)
        let herDreams = root.appendingPathComponent(".her/dreams", isDirectory: true)
        let infinitiDreams = root.appendingPathComponent(".infiniti-agent/dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: herDreams, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: infinitiDreams, withIntermediateDirectories: true)

        try writeDreamContext(
            to: infinitiDreams.appendingPathComponent("prompt-context.json"),
            objective: "Infiniti fallback objective"
        )
        try writeDreamContext(
            to: herDreams.appendingPathComponent("prompt-context.json"),
            objective: "Her native objective"
        )

        let context = try XCTUnwrap(DreamPromptContextLoader.load(cwd: root.path))

        XCTAssertEqual(context.longHorizonObjective, "Her native objective")
    }

    func testFallsBackToInfinitiAgentDreamPromptContext() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-dream-context-fallback-\(UUID().uuidString)", isDirectory: true)
        let infinitiDreams = root.appendingPathComponent(".infiniti-agent/dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: infinitiDreams, withIntermediateDirectories: true)
        try writeDreamContext(
            to: infinitiDreams.appendingPathComponent("prompt-context.json"),
            objective: "Continue the desktop partner migration"
        )

        let context = try XCTUnwrap(DreamPromptContextLoader.load(cwd: root.path))

        XCTAssertEqual(context.longHorizonObjective, "Continue the desktop partner migration")
        XCTAssertTrue(context.promptBlock().contains("Dream Context"))
        XCTAssertTrue(context.promptBlock().contains("compressed context"))
        XCTAssertTrue(context.promptBlock().contains("Behavior guidance"))
    }

    func testEmptyDreamPromptContextIsIgnored() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-dream-context-empty-\(UUID().uuidString)", isDirectory: true)
        let herDreams = root.appendingPathComponent(".her/dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: herDreams, withIntermediateDirectories: true)
        try """
        {
          "updatedAt": "2026-06-30T10:00:00Z",
          "relevantStableMemories": [],
          "behaviorGuidance": [],
          "unresolvedThreads": [],
          "cautions": []
        }
        """.write(to: herDreams.appendingPathComponent("prompt-context.json"), atomically: true, encoding: .utf8)

        XCTAssertNil(DreamPromptContextLoader.load(cwd: root.path))
    }

    private func writeDreamContext(to url: URL, objective: String) throws {
        try """
        {
          "updatedAt": "2026-06-30T10:00:00Z",
          "longHorizonObjective": "\(objective)",
          "recentInsight": "Keep dream context as action summary, not a diary.",
          "relevantStableMemories": ["User prefers architecture-first implementation."],
          "behaviorGuidance": ["Keep boundaries explicit.", "Do not treat hypotheses as facts."],
          "unresolvedThreads": ["External inbox adapter shape"],
          "cautions": ["Verify sensitive claims before saving memory."]
        }
        """.write(to: url, atomically: true, encoding: .utf8)
    }
}
