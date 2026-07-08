import AppKit
import SwiftUI

/// App-quit teardown. `AppViewModel.deinit` does not reliably run on
/// termination (the root @StateObject is torn down with the process), so
/// child processes and loopback listeners must be stopped explicitly here.
@MainActor
final class HerAppDelegate: NSObject, NSApplicationDelegate {
    static weak var viewModel: AppViewModel?

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            HerAppDelegate.viewModel?.shutdown()
        }
    }
}

@main
struct HerDesktopApp: App {
    @NSApplicationDelegateAdaptor(HerAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel
    @State private var isQuickCapturePresented = false

    init() {
        let model = AppViewModel()
        _viewModel = StateObject(wrappedValue: model)
        HerAppDelegate.viewModel = model
    }

    var body: some Scene {
        WindowGroup("Her Desktop", id: "main") {
            RootView()
                .environmentObject(viewModel)
                .environmentObject(viewModel.chrome)
                .environmentObject(viewModel.serviceStatus)
                .environmentObject(viewModel.activityFeed)
                .environmentObject(viewModel.conversation)
                .environmentObject(viewModel.voiceLevel)
                .frame(minWidth: 1180, minHeight: 760)
                .sheet(isPresented: $isQuickCapturePresented) {
                    QuickCaptureSheet()
                        .environmentObject(viewModel)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Her") {
                Button("New Conversation") {
                    viewModel.newLocalConversation()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Clear Composer") {
                    viewModel.clearComposer()
                }
                .keyboardShortcut(.delete, modifiers: [.command])

                Button("Quick Capture") {
                    isQuickCapturePresented = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Toggle Inspector") {
                    viewModel.chrome.isInspectorPresented.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Divider()

                Button(viewModel.connectionState == .listening ? "Stop Dictation" : "Start Dictation") {
                    viewModel.toggleDictation()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(viewModel.config.speakAssistantReplies ? "Disable Spoken Replies" : "Enable Spoken Replies") {
                    viewModel.setSpeakAssistantReplies(!viewModel.config.speakAssistantReplies)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Check Services") {
                    Task { await viewModel.refreshServiceHealth() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Reload Plugins") {
                    Task { await viewModel.reloadPlugins() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Open .her Directory") {
                    viewModel.openLocalAgentDirectory()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Open Workspace Artifacts") {
                    viewModel.openWorkspaceArtifactsDirectory()
                }

                Button("Open Plugin Directory") {
                    viewModel.openPluginDirectory()
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }

        MenuBarExtra("Her", systemImage: menuBarSystemImage) {
            HerMenuBarView()
                .environmentObject(viewModel)
                .environmentObject(viewModel.serviceStatus)
        }
    }

    private var menuBarSystemImage: String {
        switch viewModel.connectionState {
        case .listening:
            return "waveform.circle.fill"
        case .thinking, .working:
            return "sparkles"
        case .speaking:
            return "speaker.wave.2.circle.fill"
        case .ready:
            return "infinity.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .offline:
            return "infinity.circle"
        }
    }
}
