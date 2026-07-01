import XCTest
@testable import HerDesktop

final class VibePluginPackageGeneratorTests: XCTestCase {
    func testPluginIdentifierBuilderCreatesStableNonASCIISlug() {
        let first = PluginIdentifierBuilder.makeSlug(
            name: "天气助手",
            description: "根据请求整理天气信息。",
            existingPluginIDs: []
        )
        let second = PluginIdentifierBuilder.makeSlug(
            name: "天气助手",
            description: "根据请求整理天气信息。",
            existingPluginIDs: []
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("plugin-"))
        XCTAssertFalse(first.contains("天气"))
    }

    func testPluginIdentifierBuilderAvoidsExistingIDs() {
        let slug = PluginIdentifierBuilder.makeSlug(
            name: "Meeting Brief",
            description: "Prepare a compact meeting brief.",
            existingPluginIDs: ["local.meeting-brief", "local.meeting-brief-2"]
        )

        XCTAssertEqual(slug, "meeting-brief-3")
    }

    func testPromptIncludesRequestedKindAndExistingPluginIDs() {
        let messages = VibePluginPackagePromptBuilder().build(
            request: VibePluginPackageRequest(
                name: "Research Scout",
                description: "Summarize a research source through MCP.",
                kind: "mcp",
                requiresApproval: true,
                webServiceURL: "",
                webServiceMethod: "POST",
                mcpEndpointURL: "http://localhost:8765/jsonrpc",
                mcpMethodName: "tools/call",
                mcpToolName: "research.summarize",
                mcpInputSchemaJSON: #"{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]}"#,
                commandPath: "",
                commandArguments: "",
                vibeBrief: "Build this as a reusable research assistant extension from the chat dialog."
            ),
            existingPluginIDs: ["builtin.workspace", "local.news"]
        )

        XCTAssertEqual(messages.map(\.role), ["system", "user"])
        XCTAssertTrue(messages.first?.content?.contains("builtin.workspace") == true)
        XCTAssertTrue(messages.first?.content?.contains("\"inputSchema\"") == true)
        XCTAssertTrue(messages.first?.content?.contains("Her Desktop can render a native form") == true)
        XCTAssertTrue(messages.first?.content?.contains("Built-in-style extensions must still be represented as plugin manifests") == true)
        XCTAssertTrue(messages.first?.content?.contains("Always include README.md and SKILL.md") == true)
        XCTAssertTrue(messages.first?.content?.contains("reusable without this chat history") == true)
        XCTAssertTrue(messages.last?.content?.contains("Capability kind: mcp") == true)
        XCTAssertTrue(messages.last?.content?.contains("MCP JSON-RPC method name, if relevant: tools/call") == true)
        XCTAssertTrue(messages.last?.content?.contains("MCP tool name, if relevant: research.summarize") == true)
        XCTAssertTrue(messages.last?.content?.contains("MCP discovered input schema JSON") == true)
        XCTAssertTrue(messages.last?.content?.contains("Research Scout") == true)
        XCTAssertTrue(messages.last?.content?.contains("reusable research assistant extension") == true)
    }

    func testPromptIncludesUpdateTargetAndExistingPackageContext() {
        let messages = VibePluginPackagePromptBuilder().build(
            request: VibePluginPackageRequest(
                name: "Research Scout",
                description: "Update the installed research helper.",
                kind: "skill",
                requiresApproval: true,
                webServiceURL: "",
                webServiceMethod: "POST",
                mcpEndpointURL: "",
                mcpMethodName: "",
                mcpToolName: "",
                mcpInputSchemaJSON: "",
                commandPath: "",
                commandArguments: "",
                updatePluginID: "local.research-scout",
                existingPackageContext: "SKILL.md says: summarize sources and cite uncertainty.",
                vibeBrief: "Make the existing plugin more careful."
            ),
            existingPluginIDs: ["local.research-scout"]
        )

        XCTAssertTrue(messages.first?.content?.contains("Update target plugin id") == true)
        XCTAssertTrue(messages.first?.content?.contains("manifest.id to that exact local.* id") == true)
        XCTAssertTrue(messages.first?.content?.contains("complete replacement package") == true)
        XCTAssertTrue(messages.last?.content?.contains("Update target plugin id, if this is an update: local.research-scout") == true)
        XCTAssertTrue(messages.last?.content?.contains("Existing package context") == true)
        XCTAssertTrue(messages.last?.content?.contains("summarize sources and cite uncertainty") == true)
    }

    func testRepairPromptIncludesValidationErrorAndInvalidResponse() {
        let messages = VibePluginPackagePromptBuilder().repair(
            request: VibePluginPackageRequest(
                name: "Research Scout",
                description: "Summarize a research source through MCP.",
                kind: "mcp",
                requiresApproval: true,
                webServiceURL: "",
                webServiceMethod: "POST",
                mcpEndpointURL: "http://localhost:8765/jsonrpc",
                mcpMethodName: "tools/call",
                mcpToolName: "research.summarize",
                mcpInputSchemaJSON: "",
                commandPath: "",
                commandArguments: "",
                vibeBrief: "Repair this package from the dialog."
            ),
            existingPluginIDs: ["builtin.workspace"],
            invalidResponse: #"{"manifest":{"id":"local.bad","capabilities":[]}}"#,
            errorMessage: "Plugin package is missing manifest.capabilities."
        )

        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertTrue(messages[2].content?.contains(#""capabilities":[]"#) == true)
        XCTAssertTrue(messages[3].content?.contains("could not be installed") == true)
        XCTAssertTrue(messages[3].content?.contains("Plugin package is missing manifest.capabilities.") == true)
        XCTAssertTrue(messages[3].content?.contains("Return only JSON") == true)
        XCTAssertTrue(messages[3].content?.contains("Previous invalid response") == true)
    }

    func testExtractorDecodesPlainPluginPackageJSON() throws {
        let package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())

        XCTAssertEqual(package.manifest.id, "local.research-scout")
        XCTAssertEqual(package.manifest.capabilities.first?.id, "local.research-scout.run")
        XCTAssertEqual(package.manifest.capabilities.first?.adapter?.type, "skill")
        XCTAssertEqual(package.packageFile(named: "SKILL.md")?.content, "# Research Scout")
    }

    func testExtractorDecodesFencedPluginPackageJSON() throws {
        let text = """
        Here is the package:

        ```json
        \(samplePackageJSON())
        ```
        """

        let package = try PluginPackageJSONExtractor().decodePackage(from: text)

        XCTAssertEqual(package.manifest.name, "Research Scout")
        XCTAssertEqual(package.packageFile(named: "README.md")?.content, "# README")
    }

    func testExtractorReportsMissingJSON() {
        XCTAssertThrowsError(try PluginPackageJSONExtractor().decodePackage(from: "No package here.")) { error in
            XCTAssertEqual(error as? PluginPackageJSONExtractor.ExtractError, .missingJSONObject)
        }
    }

    func testValidatorAcceptsSafeLocalSkillPackage() throws {
        let package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())

        XCTAssertNoThrow(try PluginPackageValidator().validate(package, existingPluginIDs: ["builtin.workspace"]))
    }

    func testReviewDocumenterAddsReusableReadmeAndAdapterContract() throws {
        var package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())
        package.files = [.init(path: "SKILL.md", content: "# Existing Skill\n\nUse carefully.")]
        package.manifest.capabilities[0].inputSchema = [
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("Prompt to process.")
                ])
            ]),
            "required": .array([.string("prompt")])
        ]

        let documented = PluginPackageReviewDocumenter().documented(package)
        let readme = try XCTUnwrap(documented.packageFile(named: "README.md")?.content)
        let skill = try XCTUnwrap(documented.packageFile(named: "SKILL.md")?.content)

        XCTAssertTrue(readme.contains("## Capability Contract"))
        XCTAssertTrue(readme.contains("Run Research Scout"))
        XCTAssertTrue(readme.contains("- adapter: skill"))
        XCTAssertTrue(readme.contains("- prompt: string, required - Prompt to process."))
        XCTAssertTrue(readme.contains("## Install Preview"))
        XCTAssertTrue(readme.contains("Install Target"))
        XCTAssertTrue(readme.contains("local.research-scout.run"))
        XCTAssertTrue(readme.contains("## Permission Summary"))
        XCTAssertTrue(readme.contains("Packaged Skill Instructions"))
        XCTAssertTrue(skill.contains("# Existing Skill"))
        XCTAssertTrue(skill.contains("## Adapter Contract"))
        XCTAssertTrue(skill.contains("- prompt: string, required - Prompt to process."))
        XCTAssertTrue(skill.contains("Packaged Skill Instructions"))
        XCTAssertNoThrow(try PluginPackageValidator().validate(documented))
    }

    func testValidatorAcceptsSimpleInputSchema() throws {
        var package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())
        package.manifest.capabilities[0].inputSchema = [
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("Prompt for the generated result.")
                ]),
                "size": .object([
                    "type": .string("string"),
                    "enum": .array([.string("1024x1024"), .string("1536x1024")])
                ]),
                "transparent_background": .object([
                    "type": .string("boolean"),
                    "description": .string("Whether to request transparent output.")
                ])
            ]),
            "required": .array([.string("prompt")])
        ]

        XCTAssertNoThrow(try PluginPackageValidator().validate(package))
    }

    func testValidatorRejectsInputSchemaRequiredUnknownField() throws {
        var package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())
        package.manifest.capabilities[0].inputSchema = [
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string")])
            ]),
            "required": .array([.string("missing")])
        ]

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .invalidAdapter("capability.local.research-scout.run.inputSchema.required references an unknown field")
            )
        }
    }

    func testValidatorRejectsSecretLikeInputSchemaDescription() throws {
        var package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())
        let secretLikeToken = ["sk", "test-secret-value-123456789012345"].joined(separator: "-")
        package.manifest.capabilities[0].inputSchema = [
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("Never embed bearer token \(secretLikeToken)")
                ])
            ]),
            "required": .array([.string("prompt")])
        ]

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .secretLikeContent("capability.local.research-scout.run.inputSchema.properties.prompt.description")
            )
        }
    }

    func testValidatorRejectsDuplicatePluginID() throws {
        let package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())

        XCTAssertThrowsError(try PluginPackageValidator().validate(package, existingPluginIDs: ["local.research-scout"])) { error in
            XCTAssertEqual(error as? PluginPackageValidator.ValidationError, .duplicatePluginID("local.research-scout"))
        }
    }

    func testValidatorRejectsUnsafeFilePath() throws {
        var package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())
        package.files.append(.init(path: "../escape.txt", content: "no"))

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(error as? PluginPackageValidator.ValidationError, .unsafeFilePath("../escape.txt"))
        }
    }

    func testValidatorRejectsRemoteHTTPWebService() throws {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.remote-http",
                name: "Remote HTTP",
                version: "0.1.0",
                description: "Calls an insecure remote service.",
                author: "Vibe coded",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.remote-http.run",
                        title: "Run Remote HTTP",
                        kind: "webservice",
                        invocation: "local.remote-http.run",
                        requiresApproval: true,
                        description: "Calls an insecure remote service.",
                        adapter: .init(type: "webservice", url: "http://example.com/run", method: "POST")
                    )
                ]
            ),
            files: [.init(path: "SKILL.md", content: "# Remote HTTP")]
        )

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(error as? PluginPackageValidator.ValidationError, .invalidWebServiceURL("http://example.com/run"))
        }
    }

    func testValidatorAcceptsAgentLLMConfigPlaceholdersForWebService() {
        let package = PluginPackage(
            manifest: PluginManifest(
                id: "local.agentllm-image",
                name: "AgentLLM Image",
                version: "0.1.0",
                description: "Generates an image through AgentLLM.",
                author: "Vibe coded",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.agentllm-image.run",
                        title: "Run AgentLLM Image",
                        kind: "webservice",
                        invocation: "local.agentllm-image.run",
                        requiresApproval: true,
                        description: "Calls AgentLLM with safe runtime config placeholders.",
                        adapter: .init(
                            type: "webservice",
                            url: "{{agent_llm_base_url}}/v1/images/generations",
                            method: "POST",
                            headers: ["Authorization": "Bearer {{agent_llm_api_key}}"],
                            bodyTemplate: #"{"model":{{json:model|gpt-image-1}},"prompt":{{json:prompt}}}"#
                        )
                    )
                ]
            ),
            files: [.init(path: "SKILL.md", content: "# AgentLLM Image")]
        )

        XCTAssertNoThrow(try PluginPackageValidator().validate(package))
    }

    func testValidatorAcceptsAgentMemV7MemoryKeyPlaceholderForWebService() {
        let package = agentMemWebServicePackage(
            bodyTemplate: #"{"query":{{json:request}},"top_k":6}"#
        )

        XCTAssertNoThrow(try PluginPackageValidator().validate(package))
    }

    func testValidatorRejectsRetiredAgentMemScopedPlaceholdersInAdapterTemplates() {
        let package = agentMemWebServicePackage(
            bodyTemplate: #"{"query":{{json:request}},"user_id":"{{user_id}}"}"#
        )

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .invalidAdapter("capability.local.agentmem-query.run.adapter.bodyTemplate uses retired AgentMem V7 placeholder")
            )
        }
    }

    func testValidatorAcceptsLocalMCPBridgeAdapter() {
        let package = mcpPackage(url: "http://localhost:8765/jsonrpc", methodName: "tools/call", toolName: "research.summarize")

        XCTAssertNoThrow(try PluginPackageValidator().validate(package))
    }

    func testValidatorRejectsRemoteMCPBridgeAdapter() {
        let package = mcpPackage(url: "https://mcp.example.com/jsonrpc", methodName: "tools/call", toolName: "research.summarize")

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .invalidAdapter("mcp url must be a local http bridge endpoint")
            )
        }
    }

    func testValidatorRejectsUnsafeMCPToolName() {
        let package = mcpPackage(url: "http://localhost:8765/jsonrpc", methodName: "tools/call", toolName: "research summarize && rm")

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .invalidAdapter("mcp toolName must be a safe MCP tool identifier")
            )
        }
    }

    func testValidatorAcceptsCommandAdapterWithApproval() {
        let package = commandPackage(requiresApproval: true)

        XCTAssertNoThrow(try PluginPackageValidator().validate(package))
    }

    func testValidatorRejectsCommandAdapterWithoutApproval() {
        let package = commandPackage(requiresApproval: false)

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .invalidAdapter("command capabilities must require approval")
            )
        }
    }

    func testValidatorRejectsNonLocalPluginID() throws {
        var package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())
        package.manifest.id = "builtin.fake"

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(error as? PluginPackageValidator.ValidationError, .invalidPluginID("builtin.fake"))
        }
    }

    func testValidatorRejectsSecretLikeContentInPackageFiles() throws {
        var package = try PluginPackageJSONExtractor().decodePackage(from: samplePackageJSON())
        let secretLikeToken = ["sk", "example-redaction-token-123456789012345"].joined(separator: "-")
        package.files.append(.init(
            path: "config.md",
            content: "Do not ship this: \(secretLikeToken)"
        ))

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .secretLikeContent("files.config.md")
            )
        }
    }

    func testValidatorRejectsSecretLikeContentInAdapter() {
        var package = commandPackage(requiresApproval: true)
        let secretLikeToken = "mem" + "_" + "exampleredactiontoken123456789012345"
        package.manifest.capabilities[0].adapter?.arguments = [
            secretLikeToken
        ]

        XCTAssertThrowsError(try PluginPackageValidator().validate(package)) { error in
            XCTAssertEqual(
                error as? PluginPackageValidator.ValidationError,
                .secretLikeContent("capability.local.command-tool.run.adapter.arguments[0]")
            )
        }
    }

    private func samplePackageJSON() -> String {
        """
        {
          "manifest": {
            "id": "local.research-scout",
            "name": "Research Scout",
            "version": "0.1.0",
            "description": "Summarize a research source.",
            "author": "Vibe coded",
            "systemPromptAddendum": "Keep research summaries sourced.",
            "capabilities": [
              {
                "id": "local.research-scout.run",
                "title": "Run Research Scout",
                "kind": "skill",
                "invocation": "local.research-scout.run",
                "requiresApproval": true,
                "description": "Summarize a research source.",
                "adapter": {
                  "type": "skill",
                  "skillFile": "SKILL.md"
                }
              }
            ]
          },
          "files": [
            {"path": "SKILL.md", "content": "# Research Scout"},
            {"path": "README.md", "content": "# README"}
          ]
        }
        """
    }

    private func agentMemWebServicePackage(bodyTemplate: String) -> PluginPackage {
        PluginPackage(
            manifest: PluginManifest(
                id: "local.agentmem-query",
                name: "AgentMem Query",
                version: "0.1.0",
                description: "Queries AgentMem through the V7 Memory-Key data plane.",
                author: "Vibe coded",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.agentmem-query.run",
                        title: "Run AgentMem Query",
                        kind: "webservice",
                        invocation: "local.agentmem-query.run",
                        requiresApproval: true,
                        description: "Calls AgentMem query with safe runtime config placeholders.",
                        adapter: .init(
                            type: "webservice",
                            url: "{{agent_mem_base_url}}/v1/memory/query",
                            method: "POST",
                            headers: ["X-Memory-API-Key": "{{agent_mem_api_key}}"],
                            bodyTemplate: bodyTemplate
                        )
                    )
                ]
            ),
            files: [.init(path: "SKILL.md", content: "# AgentMem Query")]
        )
    }

    private func mcpPackage(url: String, methodName: String, toolName: String = "") -> PluginPackage {
        PluginPackage(
            manifest: PluginManifest(
                id: "local.mcp-bridge",
                name: "MCP Bridge",
                version: "0.1.0",
                description: "Calls a local MCP JSON-RPC bridge.",
                author: "Vibe coded",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.mcp-bridge.run",
                        title: "Run MCP Bridge",
                        kind: "mcp",
                        invocation: "local.mcp-bridge.run",
                        requiresApproval: true,
                        description: "Calls a local MCP JSON-RPC bridge.",
                        adapter: .init(type: "mcp", url: url, methodName: methodName, toolName: toolName)
                    )
                ]
            ),
            files: [.init(path: "SKILL.md", content: "# MCP Bridge")]
        )
    }

    private func commandPackage(requiresApproval: Bool) -> PluginPackage {
        PluginPackage(
            manifest: PluginManifest(
                id: "local.command-tool",
                name: "Command Tool",
                version: "0.1.0",
                description: "Runs a fixed local command.",
                author: "Vibe coded",
                systemPromptAddendum: nil,
                capabilities: [
                    .init(
                        id: "local.command-tool.run",
                        title: "Run Command Tool",
                        kind: "command",
                        invocation: "local.command-tool.run",
                        requiresApproval: requiresApproval,
                        description: "Runs a fixed local command.",
                        adapter: .init(
                            type: "command",
                            command: "/bin/echo",
                            arguments: ["{{request}}"],
                            timeoutSeconds: 5
                        )
                    )
                ]
            ),
            files: [.init(path: "SKILL.md", content: "# Command Tool")]
        )
    }
}

private extension PluginPackage {
    func packageFile(named name: String) -> PluginPackage.FileItem? {
        files.first { $0.path == name }
    }
}
