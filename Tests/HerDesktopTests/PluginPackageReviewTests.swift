import XCTest
@testable import HerDesktop

final class PluginPackageReviewTests: XCTestCase {
    func testSkillPackageIsLowRiskAndSummarizesFiles() {
        let review = PluginPackageReview(package: package(
            kind: "skill",
            adapter: .init(type: "skill", skillFile: "SKILL.md"),
            files: [
                .init(path: "SKILL.md", content: "# Skill\nUse carefully.")
            ]
        ))

        XCTAssertEqual(review.riskLevel, .low)
        XCTAssertTrue(review.riskItems.isEmpty)
        XCTAssertEqual(review.permissionCount, 1)
        XCTAssertEqual(review.permissionSummaries.first?.title, "Packaged Skill Instructions")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "Reads SKILL.md from this plugin package.")
        XCTAssertEqual(review.capabilitySummaries.first?.adapterType, "skill")
        XCTAssertEqual(review.capabilitySummaries.first?.detail, "Skill file: SKILL.md")
        XCTAssertEqual(review.capabilitySummaries.first?.inputFieldCount, 0)
        XCTAssertEqual(review.fileSummaries.first?.path, "SKILL.md")
        XCTAssertEqual(review.fileSummaries.first?.lineCount, 2)
        XCTAssertEqual(review.installStepSummaries.first?.title, "Install Target")
        XCTAssertTrue(review.installStepSummaries.first?.detail.contains("local.review") == true)
        XCTAssertTrue(review.installStepSummaries.contains { step in
            step.title == "Callable Functions"
            && step.detail.contains("local_review_run")
        })
        XCTAssertTrue(review.installStepSummaries.contains { step in
            step.title == "Approval Posture"
            && step.detail.contains("Every capability asks for approval")
        })
    }

    func testCommandPackageIsHighRisk() {
        let review = PluginPackageReview(package: package(
            kind: "command",
            requiresApproval: true,
            adapter: .init(type: "command", command: "/bin/echo", arguments: ["{{request}}"], timeoutSeconds: 20)
        ))

        XCTAssertEqual(review.riskLevel, .high)
        XCTAssertTrue(review.riskItems.contains { $0.contains("Runs a fixed local command") })
        XCTAssertEqual(review.permissionSummaries.first?.title, "Local Command")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "/bin/echo {{request}}")
        XCTAssertEqual(review.permissionSummaries.first?.requiresApproval, true)
        XCTAssertEqual(review.capabilitySummaries.first?.detail, "/bin/echo {{request}}")
    }

    func testWebServiceWithoutApprovalIsMediumRiskAndExplainsWhy() {
        let review = PluginPackageReview(package: package(
            kind: "webservice",
            requiresApproval: false,
            adapter: .init(type: "webservice", url: "https://example.com/run", method: "POST")
        ))

        XCTAssertEqual(review.riskLevel, .medium)
        XCTAssertTrue(review.riskItems.contains("Calls a web service: POST https://example.com/run"))
        XCTAssertTrue(review.riskItems.contains("Runs local.review.run without explicit user approval."))
        XCTAssertEqual(review.permissionSummaries.first?.title, "Network Request")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "POST https://example.com/run")
        XCTAssertEqual(review.permissionSummaries.first?.requiresApproval, false)
    }

    func testNativeMemoryWritePermissionIsExplicit() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.memory",
                name: "Memory",
                version: "0.1.0",
                description: "Memory package.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "agentmem.add",
                        title: "Remember",
                        kind: "native",
                        invocation: "agentmem.add",
                        requiresApproval: true,
                        adapter: .init(type: "native")
                    )
                ]
            ),
            files: []
        )

        let review = PluginPackageReview(package: package)

        XCTAssertEqual(review.permissionSummaries.first?.title, "Memory Write")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "Writes approved conversation or work context into AgentMem.")
        XCTAssertEqual(review.permissionSummaries.first?.systemImage, "square.and.pencil")
        XCTAssertEqual(review.riskLevel, .medium)
    }

    func testWorkspaceWritePermissionIsExplicit() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.workspace-writer",
                name: "Workspace Writer",
                version: "0.1.0",
                description: "Workspace writer package.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "workspace.writeTextFile",
                        title: "Write",
                        kind: "native",
                        invocation: "workspace.writeTextFile",
                        requiresApproval: true,
                        adapter: .init(type: "native")
                    )
                ]
            ),
            files: []
        )

        let review = PluginPackageReview(package: package)

        XCTAssertEqual(review.permissionSummaries.first?.title, "Workspace File Write")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "Writes approved UTF-8 text inside the current workspace.")
        XCTAssertEqual(review.permissionSummaries.first?.requiresApproval, true)
        XCTAssertEqual(review.riskLevel, .medium)
    }

    func testWorkspaceReplacePermissionIsExplicit() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.workspace-replacer",
                name: "Workspace Replacer",
                version: "0.1.0",
                description: "Workspace replacement package.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "workspace.replaceText",
                        title: "Replace",
                        kind: "native",
                        invocation: "workspace.replaceText",
                        requiresApproval: true,
                        adapter: .init(type: "native")
                    )
                ]
            ),
            files: []
        )

        let review = PluginPackageReview(package: package)

        XCTAssertEqual(review.permissionSummaries.first?.title, "Workspace Text Replacement")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "Replaces exact approved text inside a UTF-8 workspace file.")
        XCTAssertEqual(review.permissionSummaries.first?.requiresApproval, true)
        XCTAssertEqual(review.riskLevel, .medium)
    }

    func testPluginListDraftsPermissionIsExplicitAndLowRisk() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.plugin-drafts",
                name: "Plugin Drafts",
                version: "0.1.0",
                description: "Plugin draft package.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "plugin.listDrafts",
                        title: "List Drafts",
                        kind: "native",
                        invocation: "plugin.listDrafts",
                        requiresApproval: false,
                        adapter: .init(type: "native")
                    )
                ]
            ),
            files: [
                .init(path: "README.md", content: "# Plugin Drafts\n\nLists staged plugin drafts.")
            ]
        )

        let review = PluginPackageReview(package: package)

        XCTAssertEqual(review.permissionSummaries.first?.title, "Plugin Draft Review Queue")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "Lists generated plugin drafts waiting for local review.")
        XCTAssertEqual(review.permissionSummaries.first?.systemImage, "list.bullet.clipboard")
        XCTAssertEqual(review.riskLevel, .low)
    }

    func testPluginStagePackagePermissionIsExplicitAndLowRisk() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.plugin-stage-package",
                name: "Plugin Stage Package",
                version: "0.1.0",
                description: "Plugin stage package.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "plugin.stagePackage",
                        title: "Stage Package",
                        kind: "native",
                        invocation: "plugin.stagePackage",
                        requiresApproval: false,
                        adapter: .init(type: "native")
                    )
                ]
            ),
            files: [
                .init(path: "README.md", content: "# Stage Package\n\nStages PluginPackage JSON.")
            ]
        )

        let review = PluginPackageReview(package: package)

        XCTAssertEqual(review.permissionSummaries.first?.title, "Plugin Package Staging")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "Validates a PluginPackage JSON object and stages it for local review.")
        XCTAssertEqual(review.permissionSummaries.first?.systemImage, "tray.and.arrow.down")
        XCTAssertEqual(review.riskLevel, .low)
    }

    func testPluginExportPermissionIsExplicit() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.plugin-exporter",
                name: "Plugin Exporter",
                version: "0.1.0",
                description: "Plugin export package.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "plugin.export",
                        title: "Export Plugin",
                        kind: "native",
                        invocation: "plugin.export",
                        requiresApproval: true,
                        adapter: .init(type: "native")
                    )
                ]
            ),
            files: []
        )

        let review = PluginPackageReview(package: package)

        XCTAssertEqual(review.permissionSummaries.first?.title, "Plugin Package Export")
        XCTAssertEqual(review.permissionSummaries.first?.detail, "Exports an installed local plugin package into the workspace.")
        XCTAssertEqual(review.permissionSummaries.first?.systemImage, "square.and.arrow.up")
        XCTAssertEqual(review.permissionSummaries.first?.requiresApproval, true)
        XCTAssertEqual(review.riskLevel, .medium)
    }

    func testCapabilitySummaryIncludesInputFields() {
        let review = PluginPackageReview(package: package(
            kind: "webservice",
            adapter: .init(type: "webservice", url: "https://example.com/run", method: "POST"),
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string")]),
                    "size": .object([
                        "type": .string("string"),
                        "enum": .array([.string("1024x1024"), .string("1536x1024")])
                    ])
                ]),
                "required": .array([.string("prompt")])
            ]
        ))

        XCTAssertEqual(review.capabilitySummaries.first?.inputFieldCount, 2)
        XCTAssertEqual(review.capabilitySummaries.first?.detail, "POST https://example.com/run")
        XCTAssertEqual(review.capabilitySummaries.first?.inputFields.map(\.name), ["prompt", "size"])
        XCTAssertEqual(review.capabilitySummaries.first?.inputFields.first?.required, true)
        XCTAssertEqual(review.capabilitySummaries.first?.inputFields.last?.enumValues, ["1024x1024", "1536x1024"])
    }

    func testInstallPreviewExplainsFastRunCapabilitiesAndPackageFiles() {
        let review = PluginPackageReview(package: package(
            kind: "webservice",
            requiresApproval: false,
            adapter: .init(type: "webservice", url: "https://example.com/run", method: "POST"),
            files: [
                .init(path: "README.md", content: "# Review"),
                .init(path: "SKILL.md", content: "# Skill")
            ]
        ))

        XCTAssertTrue(review.installStepSummaries.contains { step in
            step.title == "Approval Posture"
            && step.detail.contains("execute immediately")
        })
        XCTAssertTrue(review.installStepSummaries.contains { step in
            step.title == "Package Files"
            && step.detail.contains("2 supporting file(s)")
        })
    }

    private func package(
        kind: String,
        requiresApproval: Bool = true,
        adapter: PluginManifest.CapabilityAdapter,
        inputSchema: [String: JSONValue]? = nil,
        files: [PluginPackage.FileItem] = []
    ) -> PluginPackage {
        PluginPackage(
            manifest: PluginManifest(
                id: "local.review",
                name: "Review",
                version: "0.1.0",
                description: "Review package.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.review.run",
                        title: "Run Review",
                        kind: kind,
                        invocation: "local.review.run",
                        requiresApproval: requiresApproval,
                        description: "Review package.",
                        inputSchema: inputSchema,
                        adapter: adapter
                    )
                ]
            ),
            files: files
        )
    }
}
