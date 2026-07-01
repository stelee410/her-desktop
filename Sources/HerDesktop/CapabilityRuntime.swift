import Foundation

struct CapabilityInvocation: Equatable {
    var toolCallID: String
    var functionName: String
    var capabilityID: String
    var arguments: [String: Any]

    static func == (lhs: CapabilityInvocation, rhs: CapabilityInvocation) -> Bool {
        lhs.toolCallID == rhs.toolCallID
        && lhs.functionName == rhs.functionName
        && lhs.capabilityID == rhs.capabilityID
    }
}

struct CapabilityResult: Equatable {
    var title: String
    var content: String
    var requiresUserApproval: Bool
}

struct PendingApproval: Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var detail: String
    var invocation: CapabilityInvocation
    var activityID: UUID?
    var createdAt: Date = Date()

    static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool {
        lhs.id == rhs.id
    }
}

struct CapabilityToolCatalog {
    let tools: [[String: Any]]
    let functionToCapability: [String: String]

    static func build(from manifests: [PluginManifest]) -> CapabilityToolCatalog {
        var tools: [[String: Any]] = []
        var mapping: [String: String] = [:]

        for capability in manifests.flatMap(\.capabilities) {
            let name = functionName(for: capability.id)
            mapping[name] = capability.id
            tools.append([
                "type": "function",
                "function": [
                    "name": name,
                    "description": capability.description ?? "\(capability.title): \(capability.kind) capability.",
                    "parameters": capability.inputSchema?.mapValues(\.anyValue) ?? defaultSchema(for: capability)
                ]
            ])
        }
        return CapabilityToolCatalog(tools: tools, functionToCapability: mapping)
    }

    static func functionName(for capabilityID: String) -> String {
        let sanitized = capabilityID.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        return String(sanitized.prefix(64))
    }

    private static func defaultSchema(for capability: PluginManifest.Capability) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "request": ["type": "string", "description": "The user-visible request for this capability."]
            ]
        ]
    }
}

@MainActor
final class CapabilityExecutor {
    private let registry: PluginRegistry
    private let config: HerAppConfig
    private let baseDirectory: String
    private let fileManager: FileManager
    private let notificationScheduler: NativeNotificationScheduling
    private let speechSynthesizer: NativeSpeechSynthesizing
    private let attachmentInspector: AttachmentInspector
    private let urlSession: URLSession

    init(
        registry: PluginRegistry,
        config: HerAppConfig = .empty,
        baseDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default,
        notificationScheduler: NativeNotificationScheduling = UserNotificationScheduler(),
        speechSynthesizer: NativeSpeechSynthesizing = MacSpeechSynthesizer(),
        attachmentInspector: AttachmentInspector? = nil,
        urlSession: URLSession = .shared
    ) {
        self.registry = registry
        self.config = config
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.notificationScheduler = notificationScheduler
        self.speechSynthesizer = speechSynthesizer
        self.attachmentInspector = attachmentInspector ?? AttachmentInspector(cwd: baseDirectory, fileManager: fileManager)
        self.urlSession = urlSession
    }

    func execute(_ invocation: CapabilityInvocation) async -> CapabilityResult {
        switch invocation.capabilityID {
        case "workspace.inspect":
            return inspectWorkspace(arguments: invocation.arguments)
        case "workspace.search":
            return searchWorkspace(arguments: invocation.arguments)
        case "workspace.plan":
            return CapabilityResult(
                title: "Workspace Plan",
                content: "Workspace planning is available. I can inspect files and prepare a scoped implementation plan before editing.",
                requiresUserApproval: false
            )
        case "plugin.draft":
            return draftPlugin(arguments: invocation.arguments)
        case "plugin.install":
            return installPlugin(arguments: invocation.arguments)
        case "plugin.installDraft":
            return CapabilityResult(
                title: "Plugin Draft Install Failed",
                content: "Staged draft installation is handled by the Her Desktop app state because drafts live in the generated review queue.",
                requiresUserApproval: false
            )
        case "plugin.discardDraft":
            return CapabilityResult(
                title: "Plugin Draft Discard Failed",
                content: "Staged draft discard is handled by the Her Desktop app state because drafts live in the generated review queue.",
                requiresUserApproval: false
            )
        case "plugin.remove":
            return removePlugin(arguments: invocation.arguments)
        case "native.notify":
            return await executeNativeNotification(arguments: invocation.arguments)
        case "native.readTextFile":
            return executeNativeReadTextFile(arguments: invocation.arguments)
        case "native.speak":
            return await executeNativeSpeak(arguments: invocation.arguments)
        case "native.inspectAttachment":
            return executeNativeInspectAttachment(arguments: invocation.arguments)
        case "inbox.capture":
            return executeInboxCapture(arguments: invocation.arguments)
        case "agentmem.query":
            return await executeAgentMemQuery(arguments: invocation.arguments)
        case "agentmem.add":
            return await executeAgentMemAdd(arguments: invocation.arguments)
        case "mcp.discover":
            return await executeMCPToolDiscovery(arguments: invocation.arguments)
        default:
            return await executeDeclaredCapability(invocation)
        }
    }

    private func inspectWorkspace(arguments: [String: Any]) -> CapabilityResult {
        let maxFiles = min(max((arguments["max_files"] as? Int) ?? 24, 1), 80)
        let root = workspaceRoot
        let files = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        let listed = files
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
            }
            .map(\.lastPathComponent)
            .sorted()
            .prefix(maxFiles)
            .joined(separator: "\n")
        return CapabilityResult(
            title: "Workspace Inspect",
            content: """
            cwd: \(root.path)
            files:
            \(listed.isEmpty ? "(no top-level files)" : listed)
            """,
            requiresUserApproval: false
        )
    }

    private func searchWorkspace(arguments: [String: Any]) -> CapabilityResult {
        let query = clean(
            arguments["query"] as? String,
            fallback: clean(arguments["request"] as? String, fallback: "")
        )
        guard !query.isEmpty else {
            return CapabilityResult(
                title: "Workspace Search Failed",
                content: "Missing required query.",
                requiresUserApproval: false
            )
        }

        let maxResults = min(max(Int(number(arguments["max_results"], fallback: 20)), 1), 80)
        let includeContent = bool(arguments["include_content"], fallback: true)
        let maxFileBytes = min(max(Int(number(arguments["max_file_bytes"], fallback: 256_000)), 1_024), 1_000_000)
        let root = workspaceRoot.standardizedFileURL
        let lowerQuery = query.localizedLowercase
        var results: [String] = []
        var scannedFiles = 0
        var skippedBinary = 0

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CapabilityResult(
                title: "Workspace Search Failed",
                content: "Could not enumerate workspace: \(root.path)",
                requiresUserApproval: false
            )
        }

        for case let url as URL in enumerator {
            if shouldSkipSearchURL(url, root: root) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                continue
            }
            scannedFiles += 1
            let relativePath = relativePath(for: url, under: root)
            var matchedLines: [String] = []
            let filenameMatches = relativePath.localizedLowercase.contains(lowerQuery)

            if includeContent, (values?.fileSize ?? 0) <= maxFileBytes {
                do {
                    let data = try Data(contentsOf: url)
                    if data.contains(0) {
                        skippedBinary += 1
                    } else if let text = String(data: data, encoding: .utf8) {
                        matchedLines = matchingLines(in: text, query: lowerQuery)
                    }
                } catch {
                    // Search should keep moving when a single file cannot be read.
                }
            }

            guard filenameMatches || !matchedLines.isEmpty else { continue }
            var item = "- \(relativePath)"
            if filenameMatches {
                item += " [filename]"
            }
            if !matchedLines.isEmpty {
                item += "\n" + matchedLines
                    .prefix(3)
                    .map { "  \($0)" }
                    .joined(separator: "\n")
            }
            results.append(item)
            if results.count >= maxResults {
                break
            }
        }

        return CapabilityResult(
            title: "Workspace Search",
            content: """
            cwd: \(root.path)
            query: \(query)
            include_content: \(includeContent)
            scanned_files: \(scannedFiles)
            skipped_binary_files: \(skippedBinary)
            results_returned: \(results.count)

            \(results.isEmpty ? "(no matches)" : results.joined(separator: "\n"))
            """,
            requiresUserApproval: false
        )
    }

    private func draftPlugin(arguments: [String: Any]) -> CapabilityResult {
        let name = clean(arguments["name"] as? String, fallback: "New Plugin")
        let description = clean(arguments["description"] as? String, fallback: "A conversationally generated extension.")
        let kind = clean(arguments["capability_kind"] as? String, fallback: "skill")
        let requiresApproval = arguments["requires_approval"] as? Bool ?? true
        let slug = slugify(name)
        let adapter = adapterForDraft(kind: kind, arguments: arguments)
        let manifest = PluginManifest(
            id: "local.\(slug)",
            name: name,
            version: "0.1.0",
            description: description,
            author: "Vibe coded",
            systemPromptAddendum: "Use this plugin only for its declared capability. Ask before side effects.",
            capabilities: [
                .init(
                    id: "local.\(slug).run",
                    title: "Run \(name)",
                    kind: kind,
                    invocation: "local.\(slug).run",
                    requiresApproval: requiresApproval,
                    description: description,
                    inputSchema: nil,
                    adapter: adapter
                )
            ]
        )
        let package = PluginPackage(
            manifest: manifest,
            files: [
                .init(
                    path: "SKILL.md",
                    content: """
                    # \(name)

                    \(description)

                    ## Capability

                    - id: local.\(slug).run
                    - kind: \(kind)
                    - approval required: \(requiresApproval)

                    ## Runtime Notes

                    This package was created through Her Desktop vibe coding. Keep the behavior narrow, inspect user intent before acting, and ask for explicit approval before side effects.
                    """
                ),
                .init(
                    path: "README.md",
                    content: """
                    # \(name)

                    \(description)

                    This plugin can later be wired to a skill, MCP server, web service, native macOS action, or local command adapter.
                    """
                )
            ]
        )
        let data = (try? JSONEncoder.pretty.encode(package)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return CapabilityResult(
            title: "Plugin Package Draft",
            content: json,
            requiresUserApproval: false
        )
    }

    private func executeDeclaredCapability(_ invocation: CapabilityInvocation) async -> CapabilityResult {
        guard let capability = registry.capability(id: invocation.capabilityID) else {
            return CapabilityResult(
                title: "Capability Missing",
                content: "Capability \(invocation.capabilityID) is not installed.",
                requiresUserApproval: false
            )
        }

        let adapterType = (capability.adapter?.type ?? capability.kind).lowercased()
        switch adapterType {
        case "skill":
            return executeSkill(capability: capability, invocation: invocation)
        case "webservice":
            return await executeWebService(capability: capability, invocation: invocation)
        case "mcp":
            return await executeMCP(capability: capability, invocation: invocation)
        case "command":
            return await executeCommand(capability: capability, invocation: invocation)
        case "native":
            if capability.id == "native.notify" {
                return await executeNativeNotification(arguments: invocation.arguments)
            }
            if capability.id == "native.readTextFile" {
                return executeNativeReadTextFile(arguments: invocation.arguments)
            }
            if capability.id == "native.speak" {
                return await executeNativeSpeak(arguments: invocation.arguments)
            }
            if capability.id == "native.inspectAttachment" {
                return executeNativeInspectAttachment(arguments: invocation.arguments)
            }
            if capability.id == "inbox.capture" {
                return executeInboxCapture(arguments: invocation.arguments)
            }
            if capability.id == "agentmem.query" {
                return await executeAgentMemQuery(arguments: invocation.arguments)
            }
            if capability.id == "agentmem.add" {
                return await executeAgentMemAdd(arguments: invocation.arguments)
            }
            if capability.id == "mcp.discover" {
                return await executeMCPToolDiscovery(arguments: invocation.arguments)
            }
            return bridgePlaceholder(
                title: "Native Adapter Missing",
                capability: capability,
                invocation: invocation,
                detail: "This native capability is declared, but no built-in executor is registered for it yet."
            )
        default:
            return CapabilityResult(
                title: "Unsupported Adapter",
                content: "Capability \(capability.id) requested adapter type \(adapterType). Supported adapters are skill, webservice, mcp, command, and native.",
                requiresUserApproval: true
            )
        }
    }

    private func executeSkill(capability: PluginManifest.Capability, invocation: CapabilityInvocation) -> CapabilityResult {
        guard let manifest = registry.manifest(containing: capability.id) else {
            return CapabilityResult(
                title: "Skill Context Missing",
                content: "Skill capability \(capability.id) has no installable plugin package to read.",
                requiresUserApproval: false
            )
        }

        let skillFile = capability.adapter?.skillFile ?? "SKILL.md"
        do {
            let instructions = try registry.readPluginFile(pluginID: manifest.id, path: skillFile)
            return CapabilityResult(
                title: "Skill Context",
                content: """
                Capability: \(capability.title) (\(capability.id))
                Request:
                \(argumentSummary(invocation.arguments))

                Skill instructions:
                \(instructions)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Skill Context Failed",
                content: "Could not read \(skillFile) for \(capability.id): \(error.localizedDescription)",
                requiresUserApproval: false
            )
        }
    }

    private func executeWebService(capability: PluginManifest.Capability, invocation: CapabilityInvocation) async -> CapabilityResult {
        guard let adapter = capability.adapter,
              let rawURL = adapter.url,
              let url = URL(string: renderConfigurationTemplate(rawURL)) else {
            return CapabilityResult(
                title: "Web Service Not Configured",
                content: "Capability \(capability.id) is a webservice, but no adapter.url is configured.",
                requiresUserApproval: true
            )
        }
        guard isAllowedWebServiceURL(url) else {
            return CapabilityResult(
                title: "Web Service Blocked",
                content: "Only https endpoints or local http endpoints are allowed for plugin web services.",
                requiresUserApproval: true
            )
        }

        let method = (adapter.method ?? "POST").uppercased()
        var requestURL = url
        if method == "GET" {
            requestURL = urlWithQuery(url, arguments: invocation.arguments)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method == "GET" ? "GET" : "POST"
        request.timeoutInterval = 20
        for (key, value) in adapter.headers ?? [:] {
            request.setValue(renderConfigurationTemplate(value), forHTTPHeaderField: key)
        }
        if request.httpMethod == "POST" {
            if let bodyTemplate = adapter.bodyTemplate {
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
                }
                request.httpBody = renderBodyTemplate(bodyTemplate, arguments: invocation.arguments).data(using: .utf8)
            } else {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: jsonCompatible(invocation.arguments), options: [.sortedKeys])
            }
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let artifacts = persistWebServiceArtifactsIfPresent(
                data: data,
                capabilityID: capability.id,
                method: request.httpMethod ?? method,
                requestURL: requestURL,
                status: status
            )
            let body = SecretRedactor.redact(displayBody(for: data, artifacts: artifacts), config: config)
            let artifactBlock = artifacts.resultLines.isEmpty
                ? ""
                : "\n\nArtifacts:\n" + artifacts.resultLines.joined(separator: "\n")
            return CapabilityResult(
                title: "Web Service Result",
                content: """
                \(request.httpMethod ?? method) \(SecretRedactor.redact(requestURL.absoluteString, config: config))
                status: \(status)

                \(body)
                \(artifactBlock)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Web Service Failed",
                content: SecretRedactor.redact(error, config: config),
                requiresUserApproval: false
            )
        }
    }

    private func executeMCP(capability: PluginManifest.Capability, invocation: CapabilityInvocation) async -> CapabilityResult {
        guard let adapter = capability.adapter,
              let rawURL = adapter.url,
              let url = URL(string: rawURL) else {
            return CapabilityResult(
                title: "MCP Bridge Not Configured",
                content: "Capability \(capability.id) is an MCP adapter, but no local adapter.url is configured.",
                requiresUserApproval: true
            )
        }
        guard isAllowedMCPBridgeURL(url) else {
            return CapabilityResult(
                title: "MCP Bridge Blocked",
                content: "MCP bridge adapters may only call local http endpoints on localhost, 127.0.0.1, or ::1.",
                requiresUserApproval: true
            )
        }

        let methodName = clean(adapter.methodName, fallback: "")
        guard !methodName.isEmpty else {
            return CapabilityResult(
                title: "MCP Method Missing",
                content: "Capability \(capability.id) needs adapter.methodName so Her Desktop can create a JSON-RPC request.",
                requiresUserApproval: true
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in adapter.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": invocation.toolCallID,
            "method": methodName,
            "params": mcpParams(adapter: adapter, methodName: methodName, arguments: invocation.arguments)
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = SecretRedactor.redact(
                String(data: Data(data.prefix(6_000)), encoding: .utf8) ?? "\(data.count) bytes",
                config: config
            )
            return CapabilityResult(
                title: "MCP Bridge Result",
                content: """
                POST \(SecretRedactor.redact(url.absoluteString, config: config))
                method: \(methodName)
                tool: \(clean(adapter.toolName, fallback: "(generic JSON-RPC params)"))
                status: \(status)

                \(body)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "MCP Bridge Failed",
                content: SecretRedactor.redact(error, config: config),
                requiresUserApproval: false
            )
        }
    }

    private func executeMCPToolDiscovery(arguments: [String: Any]) async -> CapabilityResult {
        let rawURL = clean(
            arguments["url"] as? String,
            fallback: clean(arguments["request"] as? String, fallback: "")
        )
        guard !rawURL.isEmpty else {
            return CapabilityResult(
                title: "MCP Tool Discovery Failed",
                content: "Missing required local MCP bridge url.",
                requiresUserApproval: false
            )
        }

        do {
            let response = try await MCPBridgeDiscoveryClient(urlSession: urlSession)
                .discover(rawURL: rawURL, requestID: "mcp_discover")
            return CapabilityResult(
                title: "MCP Tool Discovery Result",
                content: response.displayContent,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "MCP Tool Discovery Failed",
                content: SecretRedactor.redact(error, config: config),
                requiresUserApproval: false
            )
        }
    }

    private func mcpParams(
        adapter: PluginManifest.CapabilityAdapter,
        methodName: String,
        arguments: [String: Any]
    ) -> Any {
        let toolName = clean(adapter.toolName, fallback: "")
        guard methodName == "tools/call", !toolName.isEmpty else {
            return jsonCompatible(arguments)
        }
        return [
            "name": toolName,
            "arguments": jsonCompatible(arguments)
        ]
    }

    private func executeCommand(capability: PluginManifest.Capability, invocation: CapabilityInvocation) async -> CapabilityResult {
        guard let adapter = capability.adapter,
              let rawCommand = adapter.command,
              !rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CapabilityResult(
                title: "Command Not Configured",
                content: "Capability \(capability.id) is a command adapter, but no adapter.command executable is configured.",
                requiresUserApproval: true
            )
        }
        guard let commandURL = resolveCommandURL(rawCommand) else {
            return CapabilityResult(
                title: "Command Blocked",
                content: "Command adapters must use an absolute executable path or a safe executable path relative to the current workspace.",
                requiresUserApproval: true
            )
        }
        guard fileManager.isExecutableFile(atPath: commandURL.path) else {
            return CapabilityResult(
                title: "Command Not Executable",
                content: "The configured command is not executable: \(commandURL.path)",
                requiresUserApproval: true
            )
        }
        guard let workingDirectory = resolveCommandWorkingDirectory(adapter.workingDirectory) else {
            return CapabilityResult(
                title: "Command Working Directory Blocked",
                content: "Command working directories must stay inside the current workspace.",
                requiresUserApproval: true
            )
        }

        let arguments = (adapter.arguments ?? []).map { renderCommandArgument($0, arguments: invocation.arguments) }
        let timeout = min(max(adapter.timeoutSeconds ?? 20, 1), 120)
        let process = Process()
        process.executableURL = commandURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let startedAt = Date()
        do {
            let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }
            let timedOut = status == 15 && Date().timeIntervalSince(startedAt) >= timeout - 0.1
            let stdoutText = SecretRedactor.redact(
                String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                config: config
            )
            let stderrText = SecretRedactor.redact(
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                config: config
            )
            return CapabilityResult(
                title: timedOut ? "Command Timed Out" : "Command Result",
                content: """
                command: \(commandURL.path)
                working_directory: \(workingDirectory.path)
                exit_status: \(status)
                timed_out: \(timedOut)

                stdout:
                \(String(stdoutText.prefix(6_000)))

                stderr:
                \(String(stderrText.prefix(6_000)))
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Command Failed",
                content: SecretRedactor.redact(error, config: config),
                requiresUserApproval: false
            )
        }
    }

    private func bridgePlaceholder(
        title: String,
        capability: PluginManifest.Capability,
        invocation: CapabilityInvocation,
        detail: String
    ) -> CapabilityResult {
        CapabilityResult(
            title: title,
            content: """
            \(detail)

            Capability: \(capability.title) (\(capability.id))
            Request:
            \(argumentSummary(invocation.arguments))
            """,
            requiresUserApproval: true
        )
    }

    private func executeNativeNotification(arguments: [String: Any]) async -> CapabilityResult {
        let title = clean(arguments["title"] as? String, fallback: "Her")
        let body = clean(arguments["body"] as? String, fallback: clean(arguments["request"] as? String, fallback: "Reminder"))
        let delay = min(max(number(arguments["delay_seconds"], fallback: 1), 1), 86_400)
        do {
            let id = try await notificationScheduler.schedule(title: title, body: body, delaySeconds: delay)
            return CapabilityResult(
                title: "Notification Scheduled",
                content: """
                Scheduled local macOS notification.
                id: \(id)
                title: \(title)
                delay_seconds: \(Int(delay))
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Notification Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func executeNativeReadTextFile(arguments: [String: Any]) -> CapabilityResult {
        let rawPath = clean(arguments["path"] as? String, fallback: "")
        guard !rawPath.isEmpty else {
            return CapabilityResult(
                title: "Read Text File Failed",
                content: "Missing required path.",
                requiresUserApproval: false
            )
        }

        let maxChars = min(max(Int(number(arguments["max_chars"], fallback: 20_000)), 1), 80_000)
        let url = resolveLocalFilePath(rawPath)
        do {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return CapabilityResult(
                    title: "Read Text File Failed",
                    content: "File does not exist or is a directory: \(url.path)",
                    requiresUserApproval: false
                )
            }
            let data = try Data(contentsOf: url)
            guard !data.contains(0) else {
                return CapabilityResult(
                    title: "Read Text File Failed",
                    content: "File appears to be binary and was not read: \(url.path)",
                    requiresUserApproval: false
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return CapabilityResult(
                    title: "Read Text File Failed",
                    content: "File is not valid UTF-8 text: \(url.path)",
                    requiresUserApproval: false
                )
            }
            let truncated = text.count > maxChars
            let prefix = String(text.prefix(maxChars))
            return CapabilityResult(
                title: "Text File Read",
                content: """
                path: \(url.path)
                characters_returned: \(prefix.count)
                truncated: \(truncated)

                \(prefix)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Read Text File Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func executeNativeSpeak(arguments: [String: Any]) async -> CapabilityResult {
        let text = clean(
            arguments["text"] as? String,
            fallback: clean(arguments["request"] as? String, fallback: "")
        )
        let voice = clean(arguments["voice"] as? String, fallback: "")
        guard !text.isEmpty else {
            return CapabilityResult(
                title: "Speech Failed",
                content: "Missing required text.",
                requiresUserApproval: false
            )
        }
        do {
            let id = try await speechSynthesizer.speak(text, voiceIdentifier: voice.nilIfEmpty)
            return CapabilityResult(
                title: "Speech Played",
                content: """
                Spoke text aloud through macOS speech synthesis.
                id: \(id)
                characters: \(text.count)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Speech Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func executeNativeInspectAttachment(arguments: [String: Any]) -> CapabilityResult {
        let rawPath = clean(arguments["path"] as? String, fallback: clean(arguments["stored_path"] as? String, fallback: ""))
        let maxChars = min(max(Int(number(arguments["max_chars"], fallback: 20_000)), 1), 80_000)
        do {
            let content = try attachmentInspector.inspect(path: rawPath, maxCharacters: maxChars)
            return CapabilityResult(
                title: "Attachment Inspected",
                content: content,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Attachment Inspect Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func executeInboxCapture(arguments: [String: Any]) -> CapabilityResult {
        let source = clean(arguments["source"] as? String, fallback: "external")
        let sender = clean(arguments["sender"] as? String, fallback: "")
        let text = clean(
            arguments["text"] as? String,
            fallback: clean(arguments["request"] as? String, fallback: clean(arguments["body"] as? String, fallback: ""))
        )
        let url = clean(arguments["url"] as? String, fallback: "")
        let receivedAt = clean(arguments["received_at"] as? String, fallback: "")
        let attachmentPaths = commandArgumentTemplates(
            arguments["attachment_paths"] ?? arguments["attachments"] ?? arguments["files"]
        )
        guard !text.isEmpty else {
            return CapabilityResult(
                title: "Inbox Capture Failed",
                content: "Missing required external message text.",
                requiresUserApproval: false
            )
        }
        let senderLine = sender.isEmpty ? "" : "\nsender: \(sender)"
        let urlLine = url.isEmpty ? "" : "\nurl: \(url)"
        let receivedLine = receivedAt.isEmpty ? "" : "\nreceived_at: \(receivedAt)"
        let attachmentLine = attachmentPaths.isEmpty ? "" : "\nattachment_paths: \(attachmentPaths.joined(separator: ", "))"
        return CapabilityResult(
            title: "Inbox Event Captured",
            content: """
            source: \(source)\(senderLine)\(urlLine)\(receivedLine)\(attachmentLine)
            characters: \(text.count)

            \(text)
            """,
            requiresUserApproval: false
        )
    }

    private func executeAgentMemQuery(arguments: [String: Any]) async -> CapabilityResult {
        let query = clean(
            arguments["query"] as? String,
            fallback: clean(arguments["request"] as? String, fallback: "")
        )
        guard !query.isEmpty else {
            return CapabilityResult(
                title: "AgentMem Query Failed",
                content: "Missing required query.",
                requiresUserApproval: false
            )
        }
        let topK = min(max(Int(number(arguments["top_k"], fallback: 8)), 1), 20)
        do {
            let response = try await agentMemClient.query(query, sessionID: sessionIDForCapabilities, topK: topK)
            let memories = response.retrievedMemories.prefix(topK).map { memory in
                "- [\(memory.layer)] \(memory.fact) (score \(formatScore(memory.score)))"
            }
            let memoryBlock = memories.isEmpty ? "- No matching memories returned." : memories.joined(separator: "\n")
            let context = response.injectedContext.trimmingCharacters(in: .whitespacesAndNewlines)
            return CapabilityResult(
                title: "AgentMem Query Result",
                content: """
                query: \(query)
                top_k: \(topK)
                timing_ms: \(formatOptional(response.timingMs))

                Injected context:
                \(context.isEmpty ? "(empty)" : context)

                Retrieved memories:
                \(memoryBlock)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "AgentMem Query Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func executeAgentMemAdd(arguments: [String: Any]) async -> CapabilityResult {
        let userInput = clean(
            arguments["user_input"] as? String,
            fallback: clean(arguments["request"] as? String, fallback: "")
        )
        let agentResponse = clean(arguments["agent_response"] as? String, fallback: "")
        guard !userInput.isEmpty, !agentResponse.isEmpty else {
            return CapabilityResult(
                title: "AgentMem Add Failed",
                content: "Missing required user_input or agent_response.",
                requiresUserApproval: false
            )
        }
        let source = clean(arguments["source"] as? String, fallback: "agentmem.add")
        do {
            let response = try await agentMemClient.add(
                userInput: userInput,
                agentResponse: agentResponse,
                sessionID: sessionIDForCapabilities,
                metadata: [
                    "source": source,
                    "capability_id": "agentmem.add"
                ]
            )
            return CapabilityResult(
                title: "AgentMem Add Result",
                content: """
                status: \(response.status)
                task_id: \(response.taskID)
                source: \(source)
                user_input_characters: \(userInput.count)
                agent_response_characters: \(agentResponse.count)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "AgentMem Add Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func installPlugin(arguments: [String: Any]) -> CapabilityResult {
        guard arguments["confirmed"] as? Bool == true else {
            return CapabilityResult(
                title: "Plugin Install Needs Confirmation",
                content: "I drafted the plugin, but installation needs explicit confirmation. Set confirmed=true only after the user approves.",
                requiresUserApproval: true
            )
        }
        guard let decoded = decodePackage(arguments: arguments) else {
            return CapabilityResult(
                title: "Plugin Install Failed",
                content: "package_json or manifest_json was not a valid plugin payload.",
                requiresUserApproval: false
            )
        }
        let package = PluginPackageReviewDocumenter().documented(decoded)
        do {
            let installedPlugins = registry.loadPlugins()
            let updatingExisting = installedPlugins.contains { $0.id == package.manifest.id }
            let existingIDs = installedPlugins.map(\.id).filter { $0 != package.manifest.id }
            try PluginPackageValidator().validate(package, existingPluginIDs: existingIDs)
            try registry.install(package: package, replacingExisting: updatingExisting)
            return CapabilityResult(
                title: updatingExisting ? "Plugin Updated" : "Plugin Installed",
                content: PluginInstallSummaryFormatter().content(
                    package: package,
                    source: "plugin.install capability",
                    title: updatingExisting ? "Plugin Updated" : "Plugin Installed",
                    verb: updatingExisting ? "Updated" : "Installed"
                ),
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Plugin Install Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func removePlugin(arguments: [String: Any]) -> CapabilityResult {
        guard arguments["confirmed"] as? Bool == true else {
            return CapabilityResult(
                title: "Plugin Remove Needs Confirmation",
                content: "Removing a plugin needs explicit confirmation. Set confirmed=true only after the user approves.",
                requiresUserApproval: true
            )
        }
        let pluginID = clean(arguments["plugin_id"] as? String, fallback: "")
        guard !pluginID.isEmpty else {
            return CapabilityResult(
                title: "Plugin Remove Failed",
                content: "plugin_id is required.",
                requiresUserApproval: false
            )
        }
        guard pluginID.hasPrefix("local.") else {
            return CapabilityResult(
                title: "Plugin Remove Failed",
                content: "Only local plugins can be removed through plugin.remove.",
                requiresUserApproval: false
            )
        }
        let manifest = registry.loadPlugins().first { $0.id == pluginID }
        do {
            try registry.remove(pluginID: pluginID)
            return CapabilityResult(
                title: "Plugin Removed",
                content: "\(manifest?.name ?? pluginID) (\(pluginID)) was removed from the local plugin directory.",
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Plugin Remove Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    private func clean(_ value: String?, fallback: String) -> String {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private func number(_ value: Any?, fallback: Double) -> Double {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string) ?? fallback
        default:
            return fallback
        }
    }

    private func bool(_ value: Any?, fallback: Bool) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1", "on"].contains(normalized) { return true }
            if ["false", "no", "0", "off"].contains(normalized) { return false }
            return fallback
        default:
            return fallback
        }
    }

    private var agentMemClient: AgentMemClient {
        AgentMemClient(config: config, session: urlSession)
    }

    private var sessionIDForCapabilities: String {
        SessionStore(cwd: baseDirectory, fileManager: fileManager).loadOrCreateSessionID()
    }

    private func formatScore(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func formatOptional(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.1f", value)
    }

    private func resolveLocalFilePath(_ rawPath: String) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return workspaceRoot.appendingPathComponent(expanded)
    }

    private func shouldSkipSearchURL(_ url: URL, root: URL) -> Bool {
        let relative = relativePath(for: url, under: root)
        let components = relative.split(separator: "/").map(String.init)
        return components.contains { component in
            [
                ".git",
                ".build",
                ".her",
                ".swiftpm",
                ".codegraph",
                "node_modules",
                "DerivedData"
            ].contains(component)
        }
    }

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func matchingLines(in text: String, query: String) -> [String] {
        text.components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, line in
                guard line.localizedLowercase.contains(query) else { return nil }
                let compacted = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\t", with: " ")
                return "line \(index + 1): \(String(compacted.prefix(180)))"
            }
    }

    private func adapterForDraft(kind: String, arguments: [String: Any]) -> PluginManifest.CapabilityAdapter? {
        switch kind.lowercased() {
        case "skill":
            return .init(type: "skill", skillFile: "SKILL.md")
        case "webservice":
            return .init(
                type: "webservice",
                url: clean(arguments["url"] as? String, fallback: ""),
                method: clean(arguments["method"] as? String, fallback: "POST").uppercased()
            )
        case "mcp":
            return .init(
                type: "mcp",
                url: clean(arguments["url"] as? String, fallback: ""),
                methodName: clean(arguments["method_name"] as? String, fallback: ""),
                toolName: clean(arguments["tool_name"] as? String, fallback: "")
            )
        case "command":
            return .init(
                type: "command",
                command: clean(arguments["command"] as? String, fallback: ""),
                arguments: commandArgumentTemplates(arguments["command_arguments"]),
                timeoutSeconds: number(arguments["timeout_seconds"], fallback: 20)
            )
        case "native":
            return .init(type: "native")
        default:
            return nil
        }
    }

    private func slugify(_ value: String) -> String {
        let slug = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "plugin" : slug
    }

    private func decodePackage(arguments: [String: Any]) -> PluginPackage? {
        let decoder = JSONDecoder()
        if let raw = arguments["package_json"] as? String,
           let data = raw.data(using: .utf8),
           let package = try? decoder.decode(PluginPackage.self, from: data) {
            return package
        }
        if let raw = arguments["manifest_json"] as? String,
           let data = raw.data(using: .utf8),
           let manifest = try? decoder.decode(PluginManifest.self, from: data) {
            return PluginPackage(manifest: manifest, files: [])
        }
        return nil
    }

    private func argumentSummary(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "(no arguments)" }
        return arguments
            .map { "\($0.key): \(String(describing: $0.value))" }
            .sorted()
            .joined(separator: "\n")
    }

    private func jsonCompatible(_ arguments: [String: Any]) -> [String: Any] {
        arguments.mapValues { value in
            switch value {
            case let string as String:
                return string
            case let number as NSNumber:
                return number
            case let int as Int:
                return int
            case let double as Double:
                return double
            case let bool as Bool:
                return bool
            case let array as [Any]:
                return array.map { String(describing: $0) }
            case let object as [String: Any]:
                return object.mapValues { String(describing: $0) }
            default:
                return String(describing: value)
            }
        }
    }

    private func renderBodyTemplate(_ template: String, arguments: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: jsonCompatible(arguments), options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        var rendered = renderTemplateTokens(in: renderConfigurationTemplate(template), arguments: arguments)
            .replacingOccurrences(of: "{{request}}", with: arguments["request"] as? String ?? "")
            .replacingOccurrences(of: "{{arguments_json}}", with: json)
        for (key, value) in arguments {
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: String(describing: value))
        }
        return rendered
    }

    private func renderConfigurationTemplate(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{{agent_llm_base_url}}", with: config.agentLLMBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .replacingOccurrences(of: "{{agent_llm_api_key}}", with: config.agentLLMAPIKey)
            .replacingOccurrences(of: "{{agent_llm_model}}", with: config.agentLLMModel)
            .replacingOccurrences(of: "{{agent_mem_base_url}}", with: config.agentMemBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .replacingOccurrences(of: "{{agent_mem_api_key}}", with: config.agentMemAPIKey)
            .replacingOccurrences(of: "{{agent_code}}", with: config.agentCode)
            .replacingOccurrences(of: "{{user_id}}", with: config.userID)
    }

    private func renderTemplateTokens(in template: String, arguments: [String: Any]) -> String {
        var rendered = template
        let pattern = #"\{\{json:([A-Za-z0-9_\-]+)(?:\|([^}]+))?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return rendered }
        let matches = regex.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered)).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: rendered),
                  let keyRange = Range(match.range(at: 1), in: rendered) else {
                continue
            }
            let key = String(rendered[keyRange])
            let fallback: String? = {
                guard match.range(at: 2).location != NSNotFound,
                      let range = Range(match.range(at: 2), in: rendered) else {
                    return nil
                }
                return String(rendered[range])
            }()
            let value = arguments[key] ?? fallback ?? ""
            rendered.replaceSubrange(fullRange, with: jsonLiteral(value))
        }
        return rendered
    }

    private func jsonLiteral(_ value: Any) -> String {
        if let string = value as? String {
            let data = (try? JSONEncoder().encode(string)) ?? Data("\"\(string)\"".utf8)
            return String(data: data, encoding: .utf8) ?? "\"\(string)\""
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let int = value as? Int {
            return String(int)
        }
        if let double = value as? Double {
            return String(double)
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        let text = String(describing: value)
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\(text)\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\(text)\""
    }

    private func commandArgumentTemplates(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let array = value as? [Any] {
            return array.map { String(describing: $0) }
        }
        if let text = value as? String {
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func renderCommandArgument(_ template: String, arguments: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: jsonCompatible(arguments), options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        var rendered = template
            .replacingOccurrences(of: "{{request}}", with: arguments["request"] as? String ?? "")
            .replacingOccurrences(of: "{{arguments_json}}", with: json)
        for (key, value) in arguments {
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: String(describing: value))
        }
        return rendered
    }

    private func resolveCommandURL(_ rawCommand: String) -> URL? {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.contains("\n") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        guard isSafeRelativePath(expanded) else { return nil }
        return workspaceRoot.appendingPathComponent(expanded)
    }

    private func resolveCommandWorkingDirectory(_ rawDirectory: String?) -> URL? {
        let root = workspaceRoot.standardizedFileURL
        let trimmed = (rawDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return root }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let directory = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : root.appendingPathComponent(expanded).standardizedFileURL
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return directory
    }

    private var workspaceRoot: URL {
        URL(fileURLWithPath: baseDirectory, isDirectory: true)
    }

    private var webServiceArtifactRoot: URL {
        HerWorkspacePaths.webServiceArtifactDirectory(cwd: baseDirectory)
    }

    private struct WebServiceArtifacts {
        var resultLines: [String] = []
        var base64FilesByIndex: [Int: String] = [:]
    }

    private func persistWebServiceArtifactsIfPresent(
        data: Data,
        capabilityID: String,
        method: String,
        requestURL: URL,
        status: Int
    ) -> WebServiceArtifacts {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let items = dictionary["data"] as? [[String: Any]] else {
            return WebServiceArtifacts()
        }

        var imageURLs: [String] = []
        var imageFilesByIndex: [Int: String] = [:]
        var artifactItems: [[String: Any]] = []
        let batchID = "\(slugify(capabilityID))-\(UUID().uuidString)"
        let directory = webServiceArtifactRoot

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, item) in items.enumerated() {
                var artifact: [String: Any] = ["index": index]
                if let remoteURL = item["url"] as? String,
                   URL(string: remoteURL) != nil {
                    imageURLs.append(remoteURL)
                    artifact["url"] = SecretRedactor.redact(remoteURL, config: config)
                    artifact["type"] = "remote_image"
                }
                if let base64 = item["b64_json"] as? String,
                   let imageData = Data(base64Encoded: base64) {
                    let ext = imageFileExtension(for: item["mime_type"] as? String)
                    let imageURL = directory.appendingPathComponent("\(batchID)-image-\(index).\(ext)")
                    try imageData.write(to: imageURL, options: .atomic)
                    imageFilesByIndex[index] = imageURL.path
                    artifact["file"] = imageURL.path
                    artifact["type"] = artifact["type"] ?? "image"
                }
                if artifact.count > 1 {
                    artifactItems.append(artifact)
                }
            }

            guard !artifactItems.isEmpty else {
                return WebServiceArtifacts()
            }

            let responseURL = directory.appendingPathComponent("\(batchID)-response.json")
            try redactedResponseData(data, artifacts: WebServiceArtifacts(base64FilesByIndex: imageFilesByIndex))
                .write(to: responseURL, options: .atomic)

            let manifestURL = directory.appendingPathComponent("\(batchID)-manifest.json")
            let manifest: [String: Any] = [
                "id": batchID,
                "capability_id": capabilityID,
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "request": [
                    "method": method,
                    "url": SecretRedactor.redact(requestURL.absoluteString, config: config),
                    "status": status
                ],
                "response_file": responseURL.path,
                "artifacts": artifactItems
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: manifestURL, options: .atomic)

            var lines = [
                "artifact_manifest: \(manifestURL.path)",
                "response_file: \(responseURL.path)"
            ]
            lines.append(contentsOf: imageURLs.map { "image_url: \(SecretRedactor.redact($0, config: config))" })
            lines.append(contentsOf: imageFilesByIndex.keys.sorted().compactMap { index in
                imageFilesByIndex[index].map { "image_file: \($0)" }
            })
            return WebServiceArtifacts(resultLines: lines, base64FilesByIndex: imageFilesByIndex)
        } catch {
            return WebServiceArtifacts(resultLines: ["artifact_persist_failed: \(error.localizedDescription)"])
        }
    }

    private func displayBody(for data: Data, artifacts: WebServiceArtifacts) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: Data(data.prefix(6_000)), encoding: .utf8) ?? "\(data.count) bytes"
        }
        let sanitized = sanitizeBase64Media(in: object, artifacts: artifacts)
        if JSONSerialization.isValidJSONObject(sanitized),
           let rendered = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: rendered, encoding: .utf8) {
            return String(text.prefix(6_000))
        }
        return String(data: Data(data.prefix(6_000)), encoding: .utf8) ?? "\(data.count) bytes"
    }

    private func redactedResponseData(_ data: Data, artifacts: WebServiceArtifacts) -> Data {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            let sanitized = sanitizeBase64Media(in: object, artifacts: artifacts)
            if JSONSerialization.isValidJSONObject(sanitized),
               let rendered = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: rendered, encoding: .utf8) {
                return Data(SecretRedactor.redact(text, config: config).utf8)
            }
        }
        let text = String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
        return Data(SecretRedactor.redact(text, config: config).utf8)
    }

    private func sanitizeBase64Media(in value: Any, artifacts: WebServiceArtifacts) -> Any {
        if var dictionary = value as? [String: Any] {
            if let base64 = dictionary["b64_json"] as? String {
                let index = dictionary["index"] as? Int
                let file = index.flatMap { artifacts.base64FilesByIndex[$0] }
                dictionary["b64_json"] = file.map { "[saved to \($0)]" } ?? "[base64 image omitted: \(base64.count) chars]"
            }
            return dictionary.mapValues { sanitizeBase64Media(in: $0, artifacts: artifacts) }
        }
        if let array = value as? [Any] {
            return array.enumerated().map { index, element in
                if var dictionary = element as? [String: Any] {
                    dictionary["index"] = dictionary["index"] ?? index
                    return sanitizeBase64Media(in: dictionary, artifacts: artifacts)
                }
                return sanitizeBase64Media(in: element, artifacts: artifacts)
            }
        }
        return value
    }

    private func imageFileExtension(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "png"
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix("/")
            && !trimmed.contains("..")
            && !trimmed.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private func urlWithQuery(_ url: URL, arguments: [String: Any]) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let existing = components.queryItems ?? []
        let added = arguments
            .map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
            .sorted { $0.name < $1.name }
        components.queryItems = existing + added
        return components.url ?? url
    }

    private func isAllowedWebServiceURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func isAllowedMCPBridgeURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
