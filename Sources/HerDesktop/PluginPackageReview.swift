import Foundation

struct PluginPackageReview: Equatable {
    enum RiskLevel: String, Equatable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
    }

    struct CapabilitySummary: Identifiable, Equatable {
        var id: String
        var title: String
        var kind: String
        var adapterType: String
        var requiresApproval: Bool
        var inputFieldCount: Int
        var inputFields: [CapabilityInputField]
        var detail: String
    }

    struct FileSummary: Identifiable, Equatable {
        var id: String { path }
        var path: String
        var byteCount: Int
        var lineCount: Int
    }

    struct PermissionSummary: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var systemImage: String
        var requiresApproval: Bool
    }

    struct InstallStepSummary: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var systemImage: String
    }

    var riskLevel: RiskLevel
    var riskItems: [String]
    var permissionSummaries: [PermissionSummary]
    var capabilitySummaries: [CapabilitySummary]
    var fileSummaries: [FileSummary]
    var installStepSummaries: [InstallStepSummary]

    init(package: PluginPackage) {
        self.capabilitySummaries = package.manifest.capabilities.map(Self.capabilitySummary)
        self.fileSummaries = package.files.map { file in
            let data = file.content.data(using: .utf8) ?? Data()
            return FileSummary(
                path: file.path,
                byteCount: data.count,
                lineCount: file.content.components(separatedBy: .newlines).count
            )
        }
        self.permissionSummaries = Self.permissionSummaries(for: package)
        self.installStepSummaries = Self.installStepSummaries(for: package)
        self.riskItems = Self.riskItems(for: package)
        self.riskLevel = Self.riskLevel(for: package, riskItems: riskItems)
    }

    var capabilityCount: Int { capabilitySummaries.count }
    var fileCount: Int { fileSummaries.count }
    var permissionCount: Int { permissionSummaries.count }

    private static func capabilitySummary(_ capability: PluginManifest.Capability) -> CapabilitySummary {
        let adapter = capability.adapter
        let adapterType = adapter?.type ?? capability.kind
        return CapabilitySummary(
            id: capability.id,
            title: capability.title,
            kind: capability.kind,
            adapterType: adapterType,
            requiresApproval: capability.requiresApproval,
            inputFieldCount: inputFields(for: capability).count,
            inputFields: inputFields(for: capability),
            detail: capabilityDetail(capability: capability, adapter: adapter)
        )
    }

    private static func capabilityDetail(
        capability: PluginManifest.Capability,
        adapter: PluginManifest.CapabilityAdapter?
    ) -> String {
        adapterDetail(adapter: adapter, fallbackKind: capability.kind)
    }

    private static func adapterDetail(adapter: PluginManifest.CapabilityAdapter?, fallbackKind: String) -> String {
        guard let adapter else { return fallbackKind }
        switch adapter.type {
        case "skill":
            return adapter.skillFile.map { "Skill file: \($0)" } ?? "Skill file not declared"
        case "webservice":
            let method = adapter.method ?? "POST"
            return "\(method) \(adapter.url ?? "missing URL")"
        case "mcp":
            let tool = adapter.toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolSuffix = tool?.isEmpty == false ? " tool=\(tool!)" : ""
            return "\(adapter.methodName ?? "missing method")\(toolSuffix) via \(adapter.url ?? "missing bridge")"
        case "command":
            let args = adapter.arguments?.isEmpty == false ? " \(adapter.arguments!.joined(separator: " "))" : ""
            return "\(adapter.command ?? "missing command")\(args)"
        case "native":
            return "Native macOS adapter"
        default:
        return adapter.type
        }
    }

    private static func inputFields(for capability: PluginManifest.Capability) -> [CapabilityInputField] {
        CapabilityInputSchema.fields(for: capability)
    }

    private static func installStepSummaries(for package: PluginPackage) -> [InstallStepSummary] {
        let manifest = package.manifest
        let functionNames = manifest.capabilities
            .map { CapabilityToolCatalog.functionName(for: $0.id) }
            .joined(separator: ", ")
        let approvalDetail: String
        if manifest.capabilities.isEmpty {
            approvalDetail = "No capabilities are declared, so installing this package will not expose runnable tools."
        } else if manifest.capabilities.allSatisfy({ $0.requiresApproval }) {
            approvalDetail = "Every capability asks for approval before execution."
        } else if manifest.capabilities.contains(where: { $0.requiresApproval }) {
            approvalDetail = "Some capabilities ask for approval; fast-run capabilities can execute immediately from chat or the Plugin Library."
        } else {
            approvalDetail = "Capabilities can execute immediately from chat or the Plugin Library."
        }
        let fileDetail = package.files.isEmpty
            ? "No supporting files will be installed with this package."
            : "\(package.files.count) supporting file(s) will be installed inside this plugin package."

        return [
            InstallStepSummary(
                id: "install-target",
                title: "Install Target",
                detail: "\(manifest.name) installs as \(manifest.id) in the local plugin registry; an existing local plugin with the same id is updated.",
                systemImage: "shippingbox"
            ),
            InstallStepSummary(
                id: "callable-functions",
                title: "Callable Functions",
                detail: functionNames.isEmpty
                    ? "No model-callable functions are declared."
                    : "Adds \(functionNames) for chat tool calls and Plugin Library runs.",
                systemImage: "function"
            ),
            InstallStepSummary(
                id: "approval-posture",
                title: "Approval Posture",
                detail: approvalDetail,
                systemImage: manifest.capabilities.contains(where: { $0.requiresApproval }) ? "hand.raised" : "bolt"
            ),
            InstallStepSummary(
                id: "package-files",
                title: "Package Files",
                detail: fileDetail,
                systemImage: "doc.on.doc"
            )
        ]
    }

    private static func permissionSummaries(for package: PluginPackage) -> [PermissionSummary] {
        let summaries = package.manifest.capabilities.map(permissionSummary)
        var seen = Set<String>()
        return summaries.filter { summary in
            let key = "\(summary.title)|\(summary.detail)|\(summary.requiresApproval)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func permissionSummary(for capability: PluginManifest.Capability) -> PermissionSummary {
        let adapter = capability.adapter
        let type = adapter?.type ?? capability.kind
        let approval = capability.requiresApproval
        switch type {
        case "skill":
            return PermissionSummary(
                id: capability.id,
                title: "Packaged Skill Instructions",
                detail: adapter?.skillFile.map { "Reads \($0) from this plugin package." } ?? "Reads packaged skill instructions.",
                systemImage: "doc.text",
                requiresApproval: approval
            )
        case "webservice":
            let method = adapter?.method ?? "POST"
            return PermissionSummary(
                id: capability.id,
                title: "Network Request",
                detail: "\(method) \(adapter?.url ?? "missing URL")",
                systemImage: "network",
                requiresApproval: approval
            )
        case "mcp":
            let method = adapter?.methodName ?? "missing method"
            let tool = adapter?.toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolSuffix = tool?.isEmpty == false ? " tool=\(tool!)" : ""
            return PermissionSummary(
                id: capability.id,
                title: "Local MCP Bridge",
                detail: "\(method)\(toolSuffix) via \(adapter?.url ?? "missing bridge")",
                systemImage: "point.3.connected.trianglepath.dotted",
                requiresApproval: approval
            )
        case "command":
            let args = adapter?.arguments?.isEmpty == false ? " \(adapter!.arguments!.joined(separator: " "))" : ""
            return PermissionSummary(
                id: capability.id,
                title: "Local Command",
                detail: "\(adapter?.command ?? "missing command")\(args)",
                systemImage: "terminal",
                requiresApproval: approval
            )
        case "native":
            return nativePermissionSummary(for: capability, adapter: adapter)
        default:
            return PermissionSummary(
                id: capability.id,
                title: "Custom Adapter",
                detail: "\(type) adapter for \(capability.id)",
                systemImage: "puzzlepiece.extension",
                requiresApproval: approval
            )
        }
    }

    private static func nativePermissionSummary(
        for capability: PluginManifest.Capability,
        adapter: PluginManifest.CapabilityAdapter?
    ) -> PermissionSummary {
        let id = capability.id
        let approval = capability.requiresApproval
        if id == "agentmem.query" {
            return PermissionSummary(
                id: id,
                title: "Memory Read",
                detail: "Queries AgentMem for relevant relationship and work context.",
                systemImage: "brain.head.profile",
                requiresApproval: approval
            )
        }
        if id == "agentmem.add" {
            return PermissionSummary(
                id: id,
                title: "Memory Write",
                detail: "Writes approved conversation or work context into AgentMem.",
                systemImage: "square.and.pencil",
                requiresApproval: approval
            )
        }
        if id == "native.readTextFile" {
            return PermissionSummary(
                id: id,
                title: "Local File Read",
                detail: "Reads an approved UTF-8 text file path.",
                systemImage: "doc.text.magnifyingglass",
                requiresApproval: approval
            )
        }
        if id == "native.inspectAttachment" {
            return PermissionSummary(
                id: id,
                title: "Attachment Inspection",
                detail: "Reads metadata and bounded text from a Her attachment.",
                systemImage: "paperclip",
                requiresApproval: approval
            )
        }
        if id == "native.notify" {
            return PermissionSummary(
                id: id,
                title: "macOS Notification",
                detail: "Posts a local user notification.",
                systemImage: "bell.badge",
                requiresApproval: approval
            )
        }
        if id == "native.speak" {
            return PermissionSummary(
                id: id,
                title: "Speech Output",
                detail: "Speaks text through local macOS speech synthesis.",
                systemImage: "speaker.wave.2",
                requiresApproval: approval
            )
        }
        if id == "plugin.install" {
            return PermissionSummary(
                id: id,
                title: "Plugin Install",
                detail: "Installs or updates a local plugin package after review.",
                systemImage: "shippingbox",
                requiresApproval: approval
            )
        }
        if id == "plugin.installDraft" {
            return PermissionSummary(
                id: id,
                title: "Staged Plugin Install",
                detail: "Installs a generated plugin draft already staged in the local review queue.",
                systemImage: "shippingbox.circle",
                requiresApproval: approval
            )
        }
        if id == "plugin.discardDraft" {
            return PermissionSummary(
                id: id,
                title: "Staged Plugin Draft Discard",
                detail: "Discards a generated plugin draft already staged in the local review queue.",
                systemImage: "xmark.bin",
                requiresApproval: approval
            )
        }
        if id == "mcp.discover" {
            return PermissionSummary(
                id: id,
                title: "MCP Tool Discovery",
                detail: "Lists tools from a local MCP bridge endpoint.",
                systemImage: "point.3.connected.trianglepath.dotted",
                requiresApproval: approval
            )
        }
        if id == "inbox.capture" {
            return PermissionSummary(
                id: id,
                title: "Inbox Capture",
                detail: "Stores an inbound message from the local inbox bridge.",
                systemImage: "tray.and.arrow.down",
                requiresApproval: approval
            )
        }
        if id == "workspace.inspect" {
            return PermissionSummary(
                id: id,
                title: "Workspace Read",
                detail: "Reads local Her workspace state and recent activity.",
                systemImage: "folder",
                requiresApproval: approval
            )
        }
        return PermissionSummary(
            id: id,
            title: "Native macOS Capability",
            detail: adapterDetail(adapter: adapter, fallbackKind: capability.kind),
            systemImage: "desktopcomputer",
            requiresApproval: approval
        )
    }

    private static func riskItems(for package: PluginPackage) -> [String] {
        var items: [String] = []
        for capability in package.manifest.capabilities {
            let adapter = capability.adapter
            let type = adapter?.type ?? capability.kind
            switch type {
            case "command":
                items.append("Runs a fixed local command: \(adapter?.command ?? capability.id)")
            case "mcp":
                items.append("Calls a local MCP bridge: \(adapter?.url ?? capability.id)")
            case "webservice":
                items.append("Calls a web service: \(adapter?.method ?? "POST") \(adapter?.url ?? capability.id)")
            case "native":
                items.append("Uses a native macOS capability: \(capability.id)")
            default:
                break
            }
            if !capability.requiresApproval, ["command", "mcp", "webservice", "native"].contains(type) {
                items.append("Runs \(capability.id) without explicit user approval.")
            }
        }
        if package.files.isEmpty {
            items.append("No supporting package files are included.")
        }
        return Array(NSOrderedSet(array: items)) as? [String] ?? items
    }

    private static func riskLevel(for package: PluginPackage, riskItems: [String]) -> RiskLevel {
        let capabilities = package.manifest.capabilities
        if capabilities.contains(where: { ($0.adapter?.type ?? $0.kind) == "command" }) {
            return .high
        }
        if capabilities.contains(where: { capability in
            let type = capability.adapter?.type ?? capability.kind
            return ["mcp", "webservice", "native"].contains(type) || !capability.requiresApproval
        }) {
            return .medium
        }
        return riskItems.isEmpty ? .low : .medium
    }
}
