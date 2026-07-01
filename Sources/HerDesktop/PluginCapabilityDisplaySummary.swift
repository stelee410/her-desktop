import Foundation

struct PluginCapabilityDisplaySummary: Equatable {
    var sourceLabel: String
    var approvalLabel: String
    var adapterLabel: String
    var inputLabel: String
    var detailLine: String

    init(plugin: PluginManifest, capability: PluginManifest.Capability) {
        sourceLabel = plugin.id.hasPrefix("builtin.") ? "Built-in" : "Local"
        approvalLabel = capability.requiresApproval ? "Approval" : "Fast run"
        adapterLabel = Self.adapterLabel(for: capability)
        inputLabel = Self.inputLabel(for: capability)
        detailLine = "\(capability.id) · \(adapterLabel)"
    }

    private static func adapterLabel(for capability: PluginManifest.Capability) -> String {
        let adapter = capability.adapter
        let type = adapter?.type ?? capability.kind
        switch type {
        case "webservice":
            let method = adapter?.method ?? "POST"
            return "\(type) \(method)"
        case "mcp":
            if let toolName = adapter?.toolName, !toolName.isEmpty {
                return "\(type) \(toolName)"
            }
            if let methodName = adapter?.methodName, !methodName.isEmpty {
                return "\(type) \(methodName)"
            }
            return type
        case "command":
            if let command = adapter?.command, !command.isEmpty {
                return "\(type) \(URL(fileURLWithPath: command).lastPathComponent)"
            }
            return type
        case "skill":
            if let file = adapter?.skillFile, !file.isEmpty {
                return "\(type) \(file)"
            }
            return type
        default:
            return type
        }
    }

    private static func inputLabel(for capability: PluginManifest.Capability) -> String {
        let fields = CapabilityInputSchema.fields(for: capability)
        guard !fields.isEmpty else { return "Free text" }
        let names = fields.map { field in
            field.required ? "\(field.name)*" : field.name
        }
        return "Inputs: \(names.joined(separator: ", "))"
    }
}
