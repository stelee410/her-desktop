import AppKit
import SwiftUI

struct HerMenuBarView: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var isQuickCapturePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Divider()

            Button {
                showMainWindow()
            } label: {
                Label("Show Her Desktop", systemImage: "macwindow")
            }

            Button {
                model.newLocalConversation()
                showMainWindow()
            } label: {
                Label("New Conversation", systemImage: "plus.bubble")
            }

            Button {
                showMainWindow()
                isQuickCapturePresented = true
            } label: {
                Label("Quick Capture", systemImage: "tray.and.arrow.down")
            }

            Button {
                model.toggleDictation()
                showMainWindow()
            } label: {
                Label(model.connectionState == .listening ? "Stop Dictation" : "Start Dictation", systemImage: "waveform")
            }

            Button {
                model.setSpeakAssistantReplies(!model.config.speakAssistantReplies)
            } label: {
                Label(model.config.speakAssistantReplies ? "Disable Spoken Replies" : "Enable Spoken Replies", systemImage: "speaker.wave.2")
            }

            Divider()

            Button {
                Task { await model.refreshServiceHealth() }
            } label: {
                Label("Check Services", systemImage: "arrow.clockwise")
            }

            Button {
                toggleInboxBridge()
            } label: {
                Label(inboxTitle, systemImage: inboxIcon)
            }
            .disabled(model.localInboxBridgeState.status == .starting)

            Divider()

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                model.openPluginDirectory()
            } label: {
                Label("Open Plugins", systemImage: "puzzlepiece.extension")
            }

            Button {
                model.openLocalAgentDirectory()
            } label: {
                Label("Open .her Directory", systemImage: "folder")
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Her Desktop", systemImage: "power")
            }
        }
        .frame(width: 260)
        .padding(.vertical, 6)
        .sheet(isPresented: $isQuickCapturePresented) {
            QuickCaptureSheet()
                .environmentObject(model)
        }
    }

    private var header: some View {
        let status = PresenceCopy.serviceStatus(serviceStatus.serviceHealth)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: status.systemImage)
                    .foregroundStyle(color(for: status.tone))
                Text("Her")
                    .font(.headline)
                Spacer()
                Text(status.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color(for: status.tone))
            }

            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
    }

    private var summaryLine: String {
        switch model.connectionState {
        case .ready:
            return "\(model.config.agentLLMModel) is ready with \(model.plugins.count) plugins."
        case .listening:
            return "Listening from the menu bar."
        case .thinking:
            return "Thinking through the current conversation."
        case .working:
            return "Running an approved capability."
        case .speaking:
            return "Speaking a reply."
        case .error:
            return model.lastError ?? "Something needs attention."
        case .offline:
            return "Open Settings to add an AgentLLM API key."
        }
    }

    private var inboxTitle: String {
        model.localInboxBridgeState.status == .running ? "Stop Inbox Bridge" : "Start Inbox Bridge"
    }

    private var inboxIcon: String {
        model.localInboxBridgeState.status == .running ? "stop.circle" : "tray.and.arrow.down"
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleInboxBridge() {
        if model.localInboxBridgeState.status == .running {
            model.stopLocalInboxBridge()
        } else {
            model.startLocalInboxBridge()
        }
    }

    private func color(for tone: PresenceStatus.Tone) -> Color {
        switch tone {
        case .healthy:
            return .green
        case .warning:
            return AppTheme.coral
        case .muted:
            return AppTheme.muted
        case .active:
            return AppTheme.burgundy
        }
    }
}
