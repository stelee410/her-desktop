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
                    Text("Add an AgentLLM API key to start. Memory, plugins, and voice are optional.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                CredentialStatePill(title: "LLM Key", configured: model.config.hasLLMKey)
                if model.config.hasMemKey {
                    CredentialStatePill(title: "Memory", configured: true)
                }
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

/// Speaker dropdown for AgentLLM TTS: loads the live voice catalog from the
/// endpoint (`/v1beta/volc/tts/voices`); falls back to a plain text field
/// when the list can't be fetched (no key yet, offline, …).
struct AgentLLMVoicePicker: View {
    @Binding var draft: HerAppConfigDraft
    @State private var voices: [AgentLLMVoiceCatalog.Voice] = []
    @State private var loadFailed = false
    @State private var isLoading = false

    var body: some View {
        Group {
            if !voices.isEmpty {
                Picker("音色", selection: $draft.agentLLMTTSVoice) {
                    // Keep a stored voice selectable even if it's not in the
                    // fetched list (e.g. a pack the account lost access to).
                    if !voices.contains(where: { $0.id == draft.agentLLMTTSVoice }) {
                        Text(draft.agentLLMTTSVoice).tag(draft.agentLLMTTSVoice)
                    }
                    ForEach(voices) { voice in
                        Text(voiceLabel(voice)).tag(voice.id)
                    }
                }
            } else {
                TextField("TTS 音色 ID（如 zh_female_cancan_mars_bigtts）", text: $draft.agentLLMTTSVoice)
                if isLoading {
                    Text("正在加载可用音色…")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                } else if loadFailed {
                    Text("音色列表加载失败（检查 AgentLLM key/网络），可手动填写音色 ID。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
            }
            TextField("TTS model", text: $draft.agentLLMTTSModel)
        }
        .task(id: draft.agentLLMAPIKey) {
            await loadVoices()
        }
    }

    private func voiceLabel(_ voice: AgentLLMVoiceCatalog.Voice) -> String {
        voice.gender.isEmpty ? voice.label : "\(voice.label)（\(voice.gender)）"
    }

    private func loadVoices() async {
        let key = draft.agentLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              let baseURL = URL(string: draft.agentLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            loadFailed = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await AgentLLMVoiceCatalog.fetch(baseURL: baseURL, apiKey: key)
            voices = fetched
            loadFailed = fetched.isEmpty
        } catch {
            loadFailed = true
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
                TextField("Max reply tokens (default \(HerAppConfig.defaultAgentLLMMaxTokens))", text: $draft.agentLLMMaxTokens)
            }

            fieldSection("Optional Memory", systemImage: "brain.head.profile") {
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
                Picker("语音识别 (ASR)", selection: $draft.speechRecognitionProvider) {
                    Text("系统（Apple，本地/免费）").tag("apple")
                    Text("AgentLLM（服务端转写）").tag("agentllm")
                }
                .pickerStyle(.segmented)
                if draft.speechRecognitionProvider == "agentllm" {
                    TextField("ASR model (如 whisper-1)", text: $draft.agentLLMASRModel)
                    Text("录音结束后整段上传到 AgentLLM 的 audio/transcriptions 转写；没有实时字幕。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }

                Picker("语音播报 (TTS)", selection: $draft.speechSynthesisProvider) {
                    Text("系统（Apple）").tag("apple")
                    Text("AgentLLM（豆包音色）").tag("agentllm")
                }
                .pickerStyle(.segmented)
                if draft.speechSynthesisProvider == "apple" {
                    TextField("Speech voice identifier", text: $draft.speechVoiceIdentifier)
                } else {
                    AgentLLMVoicePicker(draft: $draft)
                }
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
