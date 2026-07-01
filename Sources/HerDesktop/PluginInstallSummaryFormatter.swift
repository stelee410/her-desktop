import Foundation

struct PluginInstallSummaryFormatter {
    func content(
        package: PluginPackage,
        source: String,
        title: String = "Plugin Installed",
        verb: String = "Installed"
    ) -> String {
        let capabilities = package.manifest.capabilities
            .map(capabilityLine)
            .joined(separator: "\n")
        let quickStart = package.manifest.capabilities
            .map(quickStartLine)
            .joined(separator: "\n")

        return """
        \(title)
        \(verb) \(package.manifest.name) (\(package.manifest.id)) from \(source).

        Available in the next turn:
        \(capabilities.isEmpty ? "- No capabilities declared." : capabilities)

        Quick start:
        \(quickStart.isEmpty ? "- No runnable capabilities declared." : quickStart)

        Package files: \(package.files.count)
        """
    }

    private func capabilityLine(_ capability: PluginManifest.Capability) -> String {
        let functionName = CapabilityToolCatalog.functionName(for: capability.id)
        let approval = capability.requiresApproval ? "approval required" : "no approval"
        let adapter = capability.adapter?.type ?? capability.kind
        return "- \(capability.title): \(capability.id) as \(functionName) [\(adapter), \(approval)]"
    }

    private func quickStartLine(_ capability: PluginManifest.Capability) -> String {
        let functionName = CapabilityToolCatalog.functionName(for: capability.id)
        let approval = capability.requiresApproval ? "approval required" : "no approval"
        return "- \(capability.title): run from Plugin Library or call \(functionName); inputs: \(inputSummary(for: capability)); \(approval)."
    }

    private func inputSummary(for capability: PluginManifest.Capability) -> String {
        let fields = CapabilityInputSchema.fields(for: capability)
        guard !fields.isEmpty else { return "free text request" }
        return fields.map { field in
            let required = field.required ? "*" : ""
            let enumSuffix = field.enumValues.isEmpty ? "" : "=\(field.enumValues.joined(separator: "/"))"
            return "\(field.name)\(required):\(field.type.rawValue)\(enumSuffix)"
        }
        .joined(separator: ", ")
    }
}
