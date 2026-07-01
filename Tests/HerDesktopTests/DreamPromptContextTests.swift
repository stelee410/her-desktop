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

    func testDreamReflectionBuilderCreatesPromptContextFromRuntimeSignals() throws {
        let context = DreamReflectionBuilder().build(
            messages: [
                ChatMessage(role: .assistant, content: "我在这里。"),
                ChatMessage(role: .user, content: "继续把 Her Desktop 做成真正的数字合伙人。")
            ],
            tasks: [
                RunningTask(title: "Plugin runtime", progress: 0.6, state: "1 draft")
            ],
            activities: [
                CapabilityActivity(
                    capabilityID: "plugin.draft",
                    functionName: "plugin_draft",
                    title: "Draft Plugin",
                    status: .failed,
                    summary: "Validator rejected remote MCP URL."
                )
            ],
            interactionEvents: [],
            pluginEvents: [
                PluginLifecycleEvent(
                    action: .staged,
                    pluginID: "local.partner",
                    pluginName: "Partner",
                    version: "0.1.0",
                    source: "agentllm-vibe-composer",
                    summary: "Staged plugin package for review.",
                    capabilityCount: 1,
                    fileCount: 2
                )
            ],
            profile: AgentProfile(
                displayName: "Her",
                userDisplayName: "Leo",
                relationship: "Working partner",
                memoryID: "mem-1",
                known: true
            ),
            memorySignal: MemorySignal(
                trust: 0.8,
                confidence: 0.7,
                moodLabel: "Focused",
                relationshipSummary: "Project continuity"
            ),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(context.longHorizonObjective?.contains("Leo") == true)
        XCTAssertEqual(context.recentInsight, "Recent plugin work: Staged Partner from agentllm-vibe-composer.")
        XCTAssertTrue(context.relevantStableMemories.contains("AgentMem has a known profile for Leo."))
        XCTAssertTrue(context.behaviorGuidance.contains { $0.contains("plugin manifest") })
        XCTAssertTrue(context.unresolvedThreads.contains { $0.contains("Plugin runtime") })
        XCTAssertTrue(context.cautions.contains { $0.contains("memory writes") })
        XCTAssertTrue(context.promptBlock().contains("Dream Context"))
    }

    func testDreamPromptContextStoreSavesLoadableHerContext() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-dream-context-store-\(UUID().uuidString)", isDirectory: true)
        let context = DreamPromptContext(
            updatedAt: "2027-01-15T08:00:00Z",
            longHorizonObjective: "Keep Her Desktop useful.",
            recentInsight: "Reflection snapshots should be compact.",
            relevantStableMemories: ["User wants plugin-first extensibility."],
            behaviorGuidance: ["Be concise."],
            unresolvedThreads: ["Distribution signing"],
            cautions: ["Do not invent completed actions."]
        )

        let url = try DreamPromptContextStore.save(context, cwd: root.path)
        let loaded = try XCTUnwrap(DreamPromptContextLoader.load(cwd: root.path))

        XCTAssertEqual(url.path, root.appendingPathComponent(".her/dreams/prompt-context.json").path)
        XCTAssertEqual(loaded.longHorizonObjective, "Keep Her Desktop useful.")
        XCTAssertEqual(loaded.behaviorGuidance, ["Be concise."])
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
