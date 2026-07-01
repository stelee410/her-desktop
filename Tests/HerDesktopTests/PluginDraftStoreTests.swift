import XCTest
@testable import HerDesktop

final class PluginDraftStoreTests: XCTestCase {
    func testSaveLoadAndDeleteDraftsUnderHerDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-drafts-\(UUID().uuidString)", isDirectory: true)
        let store = PluginDraftStore(cwd: root.path)
        let first = GeneratedPluginDraft(
            package: samplePackage(id: "local.first", name: "First"),
            source: "test",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let second = GeneratedPluginDraft(
            package: samplePackage(id: "local.second", name: "Second"),
            source: "test",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        try store.save(first)
        try store.save(second)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.manifest.id), ["local.second", "local.first"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".her/plugin-drafts/\(first.id.uuidString).json").path
        ))

        try store.delete(first)

        XCTAssertEqual(try store.loadAll().map(\.manifest.id), ["local.second"])
    }

    private func samplePackage(id: String, name: String) -> PluginPackage {
        PluginPackage(
            manifest: PluginManifest(
                id: id,
                name: name,
                version: "0.1.0",
                description: "Draft package.",
                author: nil,
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "\(id).run",
                        title: "Run \(name)",
                        kind: "skill",
                        invocation: "\(id).run",
                        requiresApproval: false,
                        adapter: .init(type: "skill", skillFile: "SKILL.md")
                    )
                ]
            ),
            files: [.init(path: "SKILL.md", content: "# \(name)")]
        )
    }
}
