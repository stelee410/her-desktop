import AppKit
import SwiftUI

struct WebServiceArtifactsCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Artifacts", trailing: model.webServiceArtifacts.isEmpty ? "Empty" : "\(model.webServiceArtifacts.count)") {
            VStack(alignment: .leading, spacing: 10) {
                if model.webServiceArtifacts.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(AppTheme.muted)
                        Text("Generated images and web service outputs will appear here.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(model.webServiceArtifacts.prefix(6)) { artifact in
                        WebServiceArtifactRow(artifact: artifact)
                    }
                }

                HStack {
                    Button {
                        model.refreshWebServiceArtifacts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Refresh artifacts")

                    Button {
                        model.openWebServiceArtifactDirectory()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.coral)
                }
                .controlSize(.small)
            }
        }
    }
}

struct WebServiceArtifactRow: View {
    @EnvironmentObject private var model: AppViewModel
    var artifact: WebServiceArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                preview

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(artifact.capabilityID)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(artifact.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }

                    Text("\(artifact.request.method) \(artifact.request.status) · \(artifact.artifacts.count) item(s)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)

                    Text(artifact.request.url)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted.opacity(0.88))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 7) {
                Button {
                    model.openWebServiceArtifact(path: artifact.manifestPath)
                } label: {
                    Label("Manifest", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)

                Button {
                    model.openWebServiceArtifact(path: artifact.responseFile)
                } label: {
                    Label("Response", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)

                if let imagePath = artifact.primaryLocalImagePath {
                    Button {
                        model.openWebServiceArtifact(path: imagePath)
                    } label: {
                        Image(systemName: "photo")
                    }
                    .buttonStyle(.bordered)
                    .help("Open generated image")
                }

                if let remoteURL = artifact.remoteURLs.first,
                   let url = URL(string: remoteURL) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.bordered)
                    .help("Open remote artifact URL")
                }
            }
            .controlSize(.small)
        }
        .padding(9)
        .background(Color.white.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var preview: some View {
        if let path = artifact.primaryLocalImagePath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.5))
                Image(systemName: artifact.remoteURLs.isEmpty ? "doc.richtext" : "photo")
                    .foregroundStyle(AppTheme.coral)
            }
            .frame(width: 52, height: 52)
        }
    }
}

struct LocalInboxBridgeCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Local Inbox Bridge", trailing: model.localInboxBridgeState.status.rawValue.capitalized) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.localInboxBridgeState.endpoint)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .textSelection(.enabled)
                        Text(model.localInboxBridgeState.summary)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(9)
                .background(Color.white.opacity(0.42))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(samplePayload)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AppTheme.muted)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .padding(8)
                    .background(Color.white.opacity(0.34))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button {
                        model.stopLocalInboxBridge()
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Stop local inbox bridge")
                    .disabled(model.localInboxBridgeState.status != .running)

                    Button {
                        model.startLocalInboxBridge()
                    } label: {
                        Label(model.localInboxBridgeState.status == .running ? "Restart" : "Start", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.coral)
                }
                .controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch model.localInboxBridgeState.status {
        case .running: return "dot.radiowaves.left.and.right"
        case .starting: return "arrow.triangle.2.circlepath"
        case .failed: return "xmark.octagon"
        case .stopped: return "tray"
        }
    }

    private var color: Color {
        switch model.localInboxBridgeState.status {
        case .running: return .green
        case .starting: return AppTheme.coral
        case .failed: return .red
        case .stopped: return AppTheme.muted
        }
    }

    private var samplePayload: String {
        """
        POST /inbox
        {"source":"oyii","sender":"Leo","text":"Review this thread"}
        """
    }
}

struct ActivePlanCard: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Active Plan", trailing: "\(Int(planProgress * 100))%") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(model.workPlan?.goal ?? "Her Desktop Runtime")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(3)
                    Spacer()
                    Gauge(value: planProgress) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(AppTheme.coral)
                        .frame(width: 44, height: 44)
                }
                if let workPlan = model.workPlan {
                    ForEach(Array(workPlan.steps.prefix(5))) { step in
                        WorkPlanStepLine(step: step)
                    }
                    if workPlan.steps.isEmpty {
                        PlanLine(done: false, title: "No steps saved yet")
                    }
                } else {
                    PlanLine(done: true, title: "Architecture boundaries")
                    PlanLine(done: true, title: "Native app shell")
                    PlanLine(done: liveServicesVerified, title: "Live service verification")
                    PlanLine(done: pluginFlowReady, title: "Plugin install flow")
                    PlanLine(done: memoryReady, title: "Memory continuity")
                }
            }
        }
    }

    private var planProgress: Double {
        if let workPlan = model.workPlan {
            return workPlan.progress
        }
        let checks = [true, true, liveServicesVerified, pluginFlowReady, memoryReady]
        return Double(checks.filter { $0 }.count) / Double(checks.count)
    }

    private var liveServicesVerified: Bool {
        let remote = serviceStatus.serviceHealth.filter { $0.id == "agentllm" || $0.id == "agentmem" }
        return remote.count == 2 && remote.allSatisfy { $0.state == .online }
    }

    private var pluginFlowReady: Bool {
        serviceStatus.serviceHealth.first { $0.id == "plugins" }?.state == .online
    }

    private var memoryReady: Bool {
        model.agentProfile.known || model.config.hasMemKey
    }
}

struct StateCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "State", trailing: model.agentProfile.known ? "Known" : "Local") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MetricBox(title: "Trust", value: model.memorySignal.trust, icon: "heart")
                    MetricBox(title: "Confidence", value: model.memorySignal.confidence, icon: "diamond")
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Mood", systemImage: "face.smiling")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                        Text(model.memorySignal.moodLabel)
                            .font(.caption.weight(.semibold))
                        WaveLineTiny()
                            .stroke(AppTheme.coral, lineWidth: 1.2)
                            .frame(height: 18)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(Color.white.opacity(0.48))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 9) {
                    Image(systemName: model.agentProfile.known ? "checkmark.seal" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(model.agentProfile.known ? .green : AppTheme.muted)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.agentProfile.displayName) · \(model.agentProfile.userDisplayName)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                        Text(model.agentProfile.relationship)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        Task { await model.refreshAgentProfile() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh AgentMem profile")
                }
                .background(Color.white.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
