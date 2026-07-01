import Foundation

struct PluginInstallSummaryFormatter {
    func content(
        package: PluginPackage,
        source: String,
        title: String = "Plugin Installed",
        verb: String = "Installed"
    ) -> String {
        let catalog = CapabilityToolCatalog.build(from: [package.manifest])
        let functionNamesByCapabilityID = Dictionary(
            uniqueKeysWithValues: catalog.functionToCapability.map { functionName, capabilityID in
                (capabilityID, functionName)
            }
        )
        let capabilities = package.manifest.capabilities
            .map { capabilityLine($0, functionName: functionNamesByCapabilityID[$0.id] ?? CapabilityToolCatalog.functionName(for: $0.id)) }
            .joined(separator: "\n")
        let quickStart = package.manifest.capabilities
            .map { quickStartLine($0, functionName: functionNamesByCapabilityID[$0.id] ?? CapabilityToolCatalog.functionName(for: $0.id)) }
            .joined(separator: "\n")
        let toolArguments = package.manifest.capabilities
            .map { toolArgumentLine($0, functionName: functionNamesByCapabilityID[$0.id] ?? CapabilityToolCatalog.functionName(for: $0.id)) }
            .joined(separator: "\n")

        return """
        \(title)
        \(verb) \(package.manifest.name) (\(package.manifest.id)) from \(source).

        Available after plugin reload:
        \(capabilities.isEmpty ? "- No capabilities declared." : capabilities)

        Quick start:
        \(quickStart.isEmpty ? "- No runnable capabilities declared." : quickStart)

        Callable tool arguments:
        \(toolArguments.isEmpty ? "- No callable arguments available." : toolArguments)

        Package files: \(package.files.count)
        """
    }

    private func capabilityLine(_ capability: PluginManifest.Capability, functionName: String) -> String {
        let approval = capability.requiresApproval ? "approval required" : "no approval"
        let adapter = capability.adapter?.type ?? capability.kind
        return "- \(capability.title): \(capability.id) as \(functionName) [\(adapter), \(approval)]"
    }

    private func quickStartLine(_ capability: PluginManifest.Capability, functionName: String) -> String {
        let approval = capability.requiresApproval ? "approval required" : "no approval"
        return "- \(capability.title): run from Plugin Library or call \(functionName); inputs: \(inputSummary(for: capability)); \(approval)."
    }

    private func toolArgumentLine(_ capability: PluginManifest.Capability, functionName: String) -> String {
        return "- \(functionName) \(sampleArgumentsJSON(for: capability))"
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

    private func sampleArgumentsJSON(for capability: PluginManifest.Capability) -> String {
        let fields = CapabilityInputSchema.fields(for: capability)
        let object: [String: Any]
        if fields.isEmpty {
            object = ["request": "<request>"]
        } else {
            object = Dictionary(uniqueKeysWithValues: fields.map { field in
                (field.name, sampleValue(for: field))
            })
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func sampleValue(for field: CapabilityInputField) -> Any {
        switch field.type {
        case .boolean:
            return false
        case .integer:
            return 0
        case .number:
            return 0
        case .string:
            if let first = field.enumValues.first {
                return first
            }
            return field.required ? "<\(field.name)>" : ""
        }
    }
}
