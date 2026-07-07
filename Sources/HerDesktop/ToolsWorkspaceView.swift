import SwiftUI

struct ToolsWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var runTarget: CapabilityRunTarget?
    @State private var removalCandidate: PluginManifest?

    var body: some View {
        WorkspacePage(title: "Tools", subtitle: "\(model.plugins.count) plugins · \(capabilityCount) capabilities") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "Plugins", value: "\(model.plugins.count)", icon: "puzzlepiece.extension")
                WorkspaceMetric(title: "Capabilities", value: "\(capabilityCount)", icon: "bolt")
                WorkspaceMetric(title: "Drafts", value: "\(model.generatedPluginDrafts.count)", icon: "shippingbox")
                Spacer()
                Button {
                    model.isVibePluginComposerPresented = true
                } label: {
                    Label("Vibe 新插件", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .help("用 AI 生成一个新插件草稿")
            }

            WorkspacePanel(title: "Capability Library", trailing: "\(capabilityCount)") {
                if model.plugins.isEmpty {
                    EmptyWorkspaceLine(icon: "puzzlepiece.extension", text: "Plugins will appear after the registry loads.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.plugins) { plugin in
                            let isHighlighted = model.highlightedPluginID == plugin.id
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(plugin.name, systemImage: plugin.id.hasPrefix("builtin.") ? "seal" : "folder")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    if isHighlighted {
                                        Label("Ready to run", systemImage: "sparkles")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(AppTheme.coral)
                                    }
                                    Spacer()
                                    Text("\(plugin.capabilities.count)")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                    if !plugin.id.hasPrefix("builtin.") {
                                        Button {
                                            model.prepareVibePluginUpdate(for: plugin)
                                        } label: {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(AppTheme.muted)
                                        .help("Update plugin with AI")

                                        Button {
                                            model.exportPlugin(plugin)
                                        } label: {
                                            Image(systemName: "square.and.arrow.up")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(AppTheme.muted)
                                        .help("Export plugin package")

                                        Button {
                                            removalCandidate = plugin
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(AppTheme.muted)
                                        .help("Remove plugin")
                                    }
                                }
                                ForEach(plugin.capabilities) { capability in
                                    let summary = PluginCapabilityDisplaySummary(plugin: plugin, capability: capability)
                                    HStack(spacing: 7) {
                                        Image(systemName: icon(for: capability.kind))
                                            .foregroundStyle(AppTheme.coral)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(capability.title)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(AppTheme.ink)
                                                .lineLimit(1)
                                            Text(summary.detailLine)
                                                .font(.caption2)
                                                .foregroundStyle(AppTheme.muted)
                                                .lineLimit(1)
                                            HStack(spacing: 5) {
                                                PluginCapabilityChip(text: summary.approvalLabel, icon: capability.requiresApproval ? "hand.raised" : "bolt")
                                                PluginCapabilityChip(text: summary.inputLabel, icon: "text.badge.checkmark")
                                            }
                                        }
                                        Spacer()
                                        Button {
                                            runTarget = CapabilityRunTarget(pluginName: plugin.name, capability: capability)
                                        } label: {
                                            Image(systemName: "play.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Run capability")
                                    }
                                    .padding(8)
                                    .background(Color.white.opacity(0.38))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            .padding(10)
                            .background(isHighlighted ? AppTheme.coral.opacity(0.10) : Color.white.opacity(0.34))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            WorkspacePanel(title: "Generated Drafts", trailing: model.generatedPluginDrafts.isEmpty ? "Clear" : "\(model.generatedPluginDrafts.count)") {
                if model.generatedPluginDrafts.isEmpty {
                    EmptyWorkspaceLine(icon: "wand.and.sparkles", text: "Use Vibe Plugin in the command center to generate or stage extensions.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.generatedPluginDrafts.prefix(5)) { draft in
                            let catalogManifests = model.plugins.filter { $0.id != draft.manifest.id } + [draft.manifest]
                            let review = PluginPackageReview(package: draft.package, catalogManifests: catalogManifests)
                            VStack(alignment: .leading, spacing: 8) {
                                WorkspaceEventRow(
                                    icon: "shippingbox",
                                    title: draft.manifest.name,
                                    detail: draft.manifest.description,
                                    time: draft.createdAt
                                )
                                HStack {
                                    Text("\(review.riskLevel.rawValue) risk · \(review.capabilityCount) capability/capabilities · \(review.permissionCount) permission(s) · \(review.fileCount) file(s)")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Discard") {
                                        model.discardGeneratedPluginDraft(draft)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Install") {
                                        Task { await model.installGeneratedPluginDraft(draft) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(AppTheme.coral)
                                }
                                .controlSize(.small)
                                .padding(.horizontal, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(review.installStepSummaries.prefix(2)) { step in
                                        Label(step.detail, systemImage: step.systemImage)
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.muted)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                            .padding(9)
                            .background(Color.white.opacity(0.34))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .sheet(item: $runTarget) { target in
            CapabilityRunSheet(target: target)
                .environmentObject(model)
        }
        .onAppear {
            openPendingCapabilityRun()
        }
        .onChange(of: model.pendingCapabilityRunTarget?.id) { _, _ in
            openPendingCapabilityRun()
        }
        .alert("Remove Plugin?", isPresented: removalBinding) {
            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
            Button("Remove", role: .destructive) {
                if let plugin = removalCandidate {
                    Task { await model.removePlugin(plugin) }
                }
                removalCandidate = nil
            }
        } message: {
            Text(removalCandidate.map { "Remove \($0.name) from the local plugin directory. Built-in plugins are kept read-only." } ?? "")
        }
    }

    private var capabilityCount: Int {
        model.plugins.flatMap(\.capabilities).count
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { removalCandidate != nil },
            set: { visible in
                if !visible {
                    removalCandidate = nil
                }
            }
        )
    }

    private func openPendingCapabilityRun() {
        guard let pending = model.pendingCapabilityRunTarget else { return }
        runTarget = pending
        model.pendingCapabilityRunTarget = nil
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "skill": return "sparkles"
        case "webservice": return "globe"
        case "mcp": return "shippingbox"
        case "command": return "terminal"
        case "native": return "macwindow"
        default: return "bolt"
        }
    }
}
