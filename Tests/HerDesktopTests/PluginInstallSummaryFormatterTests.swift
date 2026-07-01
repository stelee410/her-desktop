import XCTest
@testable import HerDesktop

final class PluginInstallSummaryFormatterTests: XCTestCase {
    func testContentIncludesFunctionNameInputsAndApproval() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.image-helper",
                name: "Image Helper",
                version: "0.1.0",
                description: "Generates image prompts.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.image-helper.run",
                        title: "Run Image Helper",
                        kind: "webservice",
                        invocation: "local.image-helper.run",
                        requiresApproval: true,
                        description: "Generate an image prompt.",
                        inputSchema: [
                            "type": .string("object"),
                            "properties": .object([
                                "prompt": .object([
                                    "type": .string("string"),
                                    "description": .string("Prompt to expand.")
                                ]),
                                "size": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("1024x1024"), .string("1536x1024")])
                                ])
                            ]),
                            "required": .array([.string("prompt")])
                        ],
                        adapter: .init(type: "webservice", url: "https://example.com/images", method: "POST")
                    )
                ]
            ),
            files: [.init(path: "SKILL.md", content: "# Skill")]
        )

        let content = PluginInstallSummaryFormatter().content(package: package, source: "test")

        XCTAssertTrue(content.contains("Plugin Installed"))
        XCTAssertTrue(content.contains("Available in the next turn"))
        XCTAssertTrue(content.contains("local.image-helper.run as local_image-helper_run"))
        XCTAssertTrue(content.contains("Quick start"))
        XCTAssertTrue(content.contains("run from Plugin Library or call local_image-helper_run"))
        XCTAssertTrue(content.contains("inputs: prompt*:string, size:string=1024x1024/1536x1024"))
        XCTAssertTrue(content.contains("Callable tool arguments"))
        XCTAssertTrue(content.contains(#"local_image-helper_run {"prompt":"<prompt>","size":"1024x1024"}"#))
        XCTAssertTrue(content.contains("approval required"))
        XCTAssertTrue(content.contains("Package files: 1"))
    }

    func testContentIncludesDefaultRequestArgumentsForFreeTextCapabilities() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.freeform",
                name: "Freeform",
                version: "0.1.0",
                description: "Free text helper.",
                author: "Test",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.freeform.run",
                        title: "Run Freeform",
                        kind: "skill",
                        invocation: "local.freeform.run",
                        requiresApproval: false
                    )
                ]
            ),
            files: []
        )

        let content = PluginInstallSummaryFormatter().content(package: package, source: "test")

        XCTAssertTrue(content.contains(#"local_freeform_run {"request":"<request>"}"#))
        XCTAssertTrue(content.contains("no approval"))
    }
}
