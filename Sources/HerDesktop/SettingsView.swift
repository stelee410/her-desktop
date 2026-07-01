import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var draft = HerAppConfigDraft(config: .empty)
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AppTheme.coral.opacity(0.14))
                    Text("∞")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(AppTheme.coral)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Her Desktop Settings")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Connect the partner brain, memory, plugins, and voice preferences.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                CredentialStatePill(title: "LLM Key", configured: model.config.hasLLMKey)
                CredentialStatePill(title: "Mem Key", configured: model.config.hasMemKey)
                Spacer()
                Label(model.connectionState.rawValue.capitalized, systemImage: statusIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            Divider()

            ScrollView {
                HerConfigurationFields(draft: $draft, presentation: .settings)
                    .padding(.trailing, 8)
            }

            if let lastError = model.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.coral)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    draft = HerAppConfigDraft(config: model.config)
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(isSaving || draft == HerAppConfigDraft(config: model.config))

                Button {
                    Task { await model.refreshServiceHealth() }
                } label: {
                    Label("Check Services", systemImage: "arrow.clockwise")
                }
                .disabled(isSaving)

                Spacer()

                Button {
                    Task {
                        isSaving = true
                        await model.saveConfiguration(draft)
                        draft = HerAppConfigDraft(config: model.config)
                        isSaving = false
                    }
                } label: {
                    Label(isSaving ? "Saving" : "Save & Check", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(isSaving)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 620, height: 640)
        .background(AppTheme.windowBackground)
        .onAppear {
            draft = HerAppConfigDraft(config: model.config)
        }
        .onChange(of: model.config) { _, newConfig in
            draft = HerAppConfigDraft(config: newConfig)
        }
    }

    private var statusIcon: String {
        switch model.connectionState {
        case .ready: return "checkmark.circle"
        case .listening: return "waveform"
        case .thinking, .working: return "sparkles"
        case .speaking: return "speaker.wave.2"
        case .error: return "exclamationmark.triangle"
        case .offline: return "wifi.slash"
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .ready, .listening, .thinking, .working, .speaking:
            return .green
        case .error:
            return AppTheme.coral
        case .offline:
            return AppTheme.muted
        }
    }
}

struct HerConfigurationFields: View {
    enum Presentation {
        case compact
        case settings
    }

    @Binding var draft: HerAppConfigDraft
    var presentation: Presentation = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            fieldSection("AgentLLM", systemImage: "sparkles") {
                TextField("AgentLLM base URL", text: $draft.agentLLMBaseURL)
                SecureField("AgentLLM API key", text: $draft.agentLLMAPIKey)
                TextField("AgentLLM model", text: $draft.agentLLMModel)
            }

            fieldSection("AgentMem", systemImage: "brain.head.profile") {
                TextField("AgentMem base URL", text: $draft.agentMemBaseURL)
                SecureField("AgentMem API key", text: $draft.agentMemAPIKey)
            }

            fieldSection("Local Labels & Plugins", systemImage: "puzzlepiece.extension") {
                TextField("Local agent label", text: $draft.agentCode)
                TextField("Local user label", text: $draft.userID)
                TextField("Plugin directory", text: $draft.pluginDirectory)
            }

            fieldSection("Voice", systemImage: "waveform") {
                Toggle("Speak assistant replies", isOn: $draft.speakAssistantReplies)
                TextField("Speech voice identifier", text: $draft.speechVoiceIdentifier)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(fieldFont)
    }

    @ViewBuilder
    private func fieldSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation == .settings {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
            }
            content()
        }
    }

    private var sectionSpacing: CGFloat {
        presentation == .settings ? 16 : 8
    }

    private var fieldFont: Font {
        presentation == .settings ? .body : .caption
    }
}
