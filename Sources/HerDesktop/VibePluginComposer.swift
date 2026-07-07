import SwiftUI

/// Hosts the Vibe plugin composer sheet at the window root so conversational
/// and Tools-driven plugin creation stay reachable while the inspector is
/// hidden.
struct VibePluginComposerHost: ViewModifier {
    @EnvironmentObject private var model: AppViewModel
    @State private var pluginName = ""
    @State private var pluginDescription = ""
    @State private var pluginKind = "skill"
    @State private var pluginRequiresApproval = true
    @State private var pluginURL = ""
    @State private var pluginMethod = "POST"
    @State private var pluginMCPMethod = ""
    @State private var pluginMCPToolName = ""
    @State private var pluginMCPInputSchemaJSON = ""
    @State private var pluginCommandPath = ""
    @State private var pluginCommandArguments = ""
    @State private var pluginPackageJSON = ""
    @State private var pluginUpdateTargetID = ""
    @State private var pluginExistingPackageContext = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingVibePluginComposerPreset?.id) { _, _ in
                applyPendingComposerPreset()
            }
            .sheet(isPresented: $model.isVibePluginComposerPresented) {
                VibePluginComposerSheet(
                    isPresented: $model.isVibePluginComposerPresented,
                    pluginName: $pluginName,
                    pluginDescription: $pluginDescription,
                    pluginKind: $pluginKind,
                    pluginRequiresApproval: $pluginRequiresApproval,
                    pluginURL: $pluginURL,
                    pluginMethod: $pluginMethod,
                    pluginMCPMethod: $pluginMCPMethod,
                    pluginMCPToolName: $pluginMCPToolName,
                    pluginMCPInputSchemaJSON: $pluginMCPInputSchemaJSON,
                    pluginCommandPath: $pluginCommandPath,
                    pluginCommandArguments: $pluginCommandArguments,
                    pluginPackageJSON: $pluginPackageJSON,
                    pluginUpdateTargetID: $pluginUpdateTargetID,
                    pluginExistingPackageContext: $pluginExistingPackageContext
                )
                .environmentObject(model)
            }
    }

    private func applyPendingComposerPreset() {
        guard let preset = model.pendingVibePluginComposerPreset else { return }
        pluginName = preset.pluginName
        pluginDescription = preset.pluginDescription
        pluginKind = preset.pluginKind
        pluginRequiresApproval = preset.pluginRequiresApproval
        pluginURL = preset.pluginURL
        pluginMethod = preset.pluginMethod
        pluginMCPMethod = preset.pluginMCPMethod
        pluginMCPToolName = preset.pluginMCPToolName
        pluginMCPInputSchemaJSON = preset.pluginMCPInputSchemaJSON
        pluginCommandPath = preset.pluginCommandPath
        pluginCommandArguments = preset.pluginCommandArguments
        pluginPackageJSON = preset.pluginPackageJSON
        pluginUpdateTargetID = preset.pluginUpdateTargetID
        pluginExistingPackageContext = preset.pluginExistingPackageContext
        model.clearMCPDiscoveredTools()
        model.pendingVibePluginComposerPreset = nil
        model.isVibePluginComposerPresented = true
    }
}

struct VibePluginComposerSheet: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var isPresented: Bool
    @Binding var pluginName: String
    @Binding var pluginDescription: String
    @Binding var pluginKind: String
    @Binding var pluginRequiresApproval: Bool
    @Binding var pluginURL: String
    @Binding var pluginMethod: String
    @Binding var pluginMCPMethod: String
    @Binding var pluginMCPToolName: String
    @Binding var pluginMCPInputSchemaJSON: String
    @Binding var pluginCommandPath: String
    @Binding var pluginCommandArguments: String
    @Binding var pluginPackageJSON: String
    @Binding var pluginUpdateTargetID: String
    @Binding var pluginExistingPackageContext: String
    @State private var vibeBrief = ""
    @State private var isPackageImporterPresented = false
    @State private var isSkillImporterPresented = false

    private let kinds = ["skill", "webservice", "mcp", "command", "native"]
    private let methods = ["POST", "GET"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Vibe Plugin Composer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            TextField("Describe the extension in one paragraph...", text: $vibeBrief, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            if isUpdatingPlugin {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(AppTheme.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Updating \(pluginUpdateTargetID)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("AI generation will reuse this local plugin id and treat the installed package as context.")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }
                    Spacer()
                    Button {
                        pluginUpdateTargetID = ""
                        pluginExistingPackageContext = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear update target")
                }
                .padding(10)
                .background(Color.white.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            TextField("Plugin name", text: $pluginName)
                .textFieldStyle(.roundedBorder)

            TextField("What should it do?", text: $pluginDescription, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...7)

            HStack(spacing: 10) {
                Picker("Kind", selection: $pluginKind) {
                    ForEach(kinds, id: \.self) { kind in
                        Label(kind.capitalized, systemImage: icon(for: kind))
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $pluginRequiresApproval) {
                    Image(systemName: "hand.raised")
                }
                .toggleStyle(.button)
                .help("Require approval")
            }

            if pluginKind == "webservice" {
                HStack(spacing: 8) {
                    Picker("Method", selection: $pluginMethod) {
                        ForEach(methods, id: \.self) { method in
                            Text(method).tag(method)
                        }
                    }
                    .frame(width: 92)

                    TextField("https://service.example/run", text: $pluginURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if pluginKind == "mcp" {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("http://localhost:8765/jsonrpc", text: $pluginURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("JSON-RPC method, e.g. tools/call", text: $pluginMCPMethod)
                        .textFieldStyle(.roundedBorder)
                    TextField("MCP tool name, e.g. filesystem.read_file", text: $pluginMCPToolName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            Task { await model.discoverMCPTools(endpointURL: pluginURL) }
                        } label: {
                            Label("Discover Tools", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasMCPURL || isBusy)

                        if !model.mcpDiscoveredTools.isEmpty {
                            Button {
                                model.clearMCPDiscoveredTools()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Clear discovered tools")
                        }
                    }
                    if !model.mcpDiscoveredTools.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(Array(model.mcpDiscoveredTools.prefix(6))) { tool in
                                HStack(spacing: 8) {
                                    Button {
                                        applyMCPTool(tool)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "shippingbox")
                                                .foregroundStyle(AppTheme.coral)
                                                .frame(width: 18)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(tool.name)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(AppTheme.ink)
                                                    .lineLimit(1)
                                                Text(tool.inputSchemaSummary.isEmpty ? "No input schema" : tool.inputSchemaSummary)
                                                    .font(.caption2)
                                                    .foregroundStyle(AppTheme.muted)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help("Use this discovered tool in the composer fields")

                                    Button {
                                        draftMCPTool(tool)
                                    } label: {
                                        Image(systemName: "shippingbox.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Draft a plugin from this discovered MCP tool")
                                    .disabled(!hasMCPURL || isBusy)

                                    Button {
                                        installMCPTool(tool)
                                    } label: {
                                        Image(systemName: "tray.and.arrow.down.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Install this discovered MCP tool as a local plugin")
                                    .disabled(!hasMCPURL || isBusy)
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.42))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }

            if pluginKind == "command" {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("/absolute/path/to/tool or workspace-relative tool", text: $pluginCommandPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Argument templates, one per line. Use {{request}} if needed.", text: $pluginCommandArguments, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                }
            }

            TextField("Paste PluginPackage JSON for review", text: $pluginPackageJSON, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...7)

            HStack {
                Button {
                    if model.stagePluginPackageJSON(pluginPackageJSON, source: "composer-json") {
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label("Stage JSON Package", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!canStagePackageJSON || isBusy)

                Button {
                    isPackageImporterPresented = true
                } label: {
                    Label("Import Package File", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button {
                    isSkillImporterPresented = true
                } label: {
                    Label("Import Skill File", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || isUpdatingPlugin)
                .help(isUpdatingPlugin ? "Clear update mode before importing a standalone skill file." : "Wrap a local text or Markdown skill file as a reviewable plugin draft")
            }

            HStack {
                Button {
                    model.stageDraftPlugin(
                        named: pluginName,
                        description: effectiveDescription,
                        kind: pluginKind,
                        requiresApproval: pluginRequiresApproval,
                        webServiceURL: pluginURL,
                        webServiceMethod: pluginMethod,
                        mcpEndpointURL: pluginURL,
                        mcpMethodName: pluginMCPMethod,
                        mcpToolName: pluginMCPToolName,
                        mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                        commandPath: pluginCommandPath,
                        commandArguments: pluginCommandArguments
                    )
                    reset()
                    isPresented = false
                } label: {
                    Label("Local Draft", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)
                .disabled(!canSubmit || isBusy || isUpdatingPlugin)
                .help(isUpdatingPlugin ? "Use AI Draft or AI Install to update an installed local plugin with package context." : "Stage a local draft from the visible fields")

                Spacer()

                Button {
                    Task {
                        await model.installDraftPlugin(
                            named: pluginName,
                            description: effectiveDescription,
                            kind: pluginKind,
                            requiresApproval: pluginRequiresApproval,
                            webServiceURL: pluginURL,
                            webServiceMethod: pluginMethod,
                            mcpEndpointURL: pluginURL,
                            mcpMethodName: pluginMCPMethod,
                            mcpToolName: pluginMCPToolName,
                            mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                            commandPath: pluginCommandPath,
                            commandArguments: pluginCommandArguments
                        )
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label("Local Install", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(!canSubmit || isBusy || isUpdatingPlugin)
                .help(isUpdatingPlugin ? "Use AI Draft or AI Install to update an installed local plugin with package context." : "Install a local plugin from the visible fields")
            }
            .controlSize(.regular)

            HStack {
                Button {
                    Task {
                        await model.generateAIDraftPlugin(
                            named: pluginName,
                            description: effectiveDescription,
                            kind: pluginKind,
                            requiresApproval: pluginRequiresApproval,
                            webServiceURL: pluginURL,
                            webServiceMethod: pluginMethod,
                            mcpEndpointURL: pluginURL,
                            mcpMethodName: pluginMCPMethod,
                            mcpToolName: pluginMCPToolName,
                            mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                            commandPath: pluginCommandPath,
                            commandArguments: pluginCommandArguments,
                            vibeBrief: vibeBrief,
                            updatePluginID: pluginUpdateTargetID,
                            existingPackageContext: pluginExistingPackageContext,
                            installImmediately: false
                        )
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label(isUpdatingPlugin ? "AI Update Draft" : "AI Draft", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(!canSubmit || isBusy || !model.config.hasLLMKey)

                Spacer()

                Button {
                    Task {
                        await model.generateAIDraftPlugin(
                            named: pluginName,
                            description: effectiveDescription,
                            kind: pluginKind,
                            requiresApproval: pluginRequiresApproval,
                            webServiceURL: pluginURL,
                            webServiceMethod: pluginMethod,
                            mcpEndpointURL: pluginURL,
                            mcpMethodName: pluginMCPMethod,
                            mcpToolName: pluginMCPToolName,
                            mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                            commandPath: pluginCommandPath,
                            commandArguments: pluginCommandArguments,
                            vibeBrief: vibeBrief,
                            updatePluginID: pluginUpdateTargetID,
                            existingPackageContext: pluginExistingPackageContext,
                            installImmediately: true
                        )
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label(isUpdatingPlugin ? "AI Review Update" : "AI Review & Install", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(!canSubmit || isBusy || !model.config.hasLLMKey)
            }
            .controlSize(.regular)
        }
        .padding(22)
        .frame(width: 560)
        .background(AppTheme.windowBackground)
        .fileImporter(
            isPresented: $isPackageImporterPresented,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result,
               let url = urls.first,
               model.stagePluginPackageFile(url, source: "composer-file") {
                reset()
                isPresented = false
            } else if case let .failure(error) = result {
                model.reportPluginPackageImportError(error, source: "composer-file")
            }
        }
        .fileImporter(
            isPresented: $isSkillImporterPresented,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result,
               let url = urls.first,
               model.stageSkillFilePlugin(
                   url,
                   name: pluginName,
                   description: effectiveDescription,
                   requiresApproval: pluginRequiresApproval,
                   source: "composer-skill-file"
               ) {
                reset()
                isPresented = false
            } else if case let .failure(error) = result {
                model.reportSkillFileImportError(error, source: "composer-skill-file")
            }
        }
    }

    private var canSubmit: Bool {
        let hasDescription = !effectiveDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasURL = hasMCPURL
        let hasMCPMethod = !pluginMCPMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMCPToolName = !pluginMCPToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCommand = !pluginCommandPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasDescription
            && (pluginKind != "webservice" || hasURL)
            && (pluginKind != "mcp" || (hasURL && hasMCPMethod && hasMCPToolName))
            && (pluginKind != "command" || hasCommand)
    }

    private var hasMCPURL: Bool {
        !pluginURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool {
        model.connectionState == .thinking || model.connectionState == .working
    }

    private var isUpdatingPlugin: Bool {
        !pluginUpdateTargetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveDescription: String {
        let description = pluginDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = vibeBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty { return brief }
        if brief.isEmpty { return description }
        return """
        \(description)

        Vibe brief:
        \(brief)
        """
    }

    private func reset() {
        vibeBrief = ""
        pluginName = ""
        pluginDescription = ""
        pluginKind = "skill"
        pluginRequiresApproval = true
        pluginURL = ""
        pluginMethod = "POST"
        pluginMCPMethod = ""
        pluginMCPToolName = ""
        pluginMCPInputSchemaJSON = ""
        model.clearMCPDiscoveredTools()
        pluginCommandPath = ""
        pluginCommandArguments = ""
        pluginPackageJSON = ""
        pluginUpdateTargetID = ""
        pluginExistingPackageContext = ""
    }

    private func applyMCPTool(_ tool: MCPDiscoveredTool) {
        pluginKind = "mcp"
        pluginMCPMethod = "tools/call"
        pluginMCPToolName = tool.name
        pluginMCPInputSchemaJSON = tool.rawInputSchema
        if pluginDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pluginDescription = tool.description.isEmpty
                ? "Calls the \(tool.name) MCP tool."
                : tool.description
        }
    }

    private func draftMCPTool(_ tool: MCPDiscoveredTool) {
        model.stageMCPDiscoveredToolPlugin(
            tool,
            endpointURL: pluginURL,
            name: pluginName,
            description: effectiveDescription,
            requiresApproval: pluginRequiresApproval
        )
        reset()
        isPresented = false
    }

    private func installMCPTool(_ tool: MCPDiscoveredTool) {
        Task {
            await model.installMCPDiscoveredToolPlugin(
                tool,
                endpointURL: pluginURL,
                name: pluginName,
                description: effectiveDescription,
                requiresApproval: pluginRequiresApproval
            )
            reset()
            isPresented = false
        }
    }

    private var canStagePackageJSON: Bool {
        !pluginPackageJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "skill": return "sparkles"
        case "webservice": return "globe"
        case "mcp": return "shippingbox"
        case "command": return "terminal"
        case "native": return "macwindow"
        default: return "puzzlepiece.extension"
        }
    }
}
