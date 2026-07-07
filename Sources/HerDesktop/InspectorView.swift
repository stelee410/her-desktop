import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var pane: Pane = .attention

    private enum Pane: String, CaseIterable, Identifiable {
        case attention
        case widgets
        case system
        case activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .attention: return "待办"
            case .widgets: return "小组件"
            case .system: return "系统"
            case .activity: return "活动"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector Pane", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch pane {
                    case .attention:
                        ApprovalQueueCard()
                        BackgroundJobsCard()
                        GeneratedPluginDraftsCard()
                        RunningTasksCard()
                        CapabilityActivityCard()
                        ActivePlanCard()
                    case .widgets:
                        PinnedWebAppsPane()
                    case .system:
                        ProductReadinessCard()
                        ServiceHealthCard()
                        ServiceConfigurationCard()
                        ModelRoutingCard()
                        ConnectedToolsCard()
                        LocalInboxBridgeCard()
                        StateCard()
                    case .activity:
                        AgentLoopCard()
                        InteractionEventsCard()
                        PluginLifecycleCard()
                        WebServiceArtifactsCard()
                        AuditTrailCard()
                    }
                }
                .padding(14)
            }
        }
        .background(Color.white.opacity(0.24))
    }
}
