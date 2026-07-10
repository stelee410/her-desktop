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
/// 打电话音色: fetched from agentRealtime's /v1/voices for the selected
/// realtime model — the two models have different catalogs, so switching the
/// model reloads the list and drops a voice that no longer applies.
struct AgentRealtimeVoicePicker: View {
    @Binding var draft: HerAppConfigDraft
    @State private var voices: [AgentRealtimeVoiceCatalog.Voice] = []
    @State private var loadFailed = false
    @State private var isLoading = false

    var body: some View {
        Group {
            if !voices.isEmpty {
                Picker("音色", selection: $draft.agentRealtimeVoice) {
                    Text("服务默认").tag("")
                    ForEach(voices) { voice in
                        Text(voiceLabel(voice)).tag(voice.id)
                    }
                }
            } else {
                TextField("音色 ID（留空用服务默认）", text: $draft.agentRealtimeVoice)
                if isLoading {
                    Text("正在加载可用音色…")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                } else if loadFailed, !draft.agentRealtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("音色列表加载失败（检查 key/网络），可手动填写音色 ID。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
            }
        }
        .task(id: draft.agentRealtimeAPIKey + "|" + draft.agentRealtimeModelProfile) {
            await loadVoices()
        }
    }

    private func voiceLabel(_ voice: AgentRealtimeVoiceCatalog.Voice) -> String {
        let gender: String
        switch voice.gender {
        case "male": gender = "男"
        case "female": gender = "女"
        default: gender = ""
        }
        return gender.isEmpty ? voice.label : "\(voice.label)（\(gender)）"
    }

    private func loadVoices() async {
        let key = draft.agentRealtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            voices = []
            loadFailed = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await AgentRealtimeVoiceCatalog.fetch(
                apiKey: key,
                modelProfile: draft.agentRealtimeModelProfile
            )
            voices = fetched
            loadFailed = fetched.isEmpty
            // A voice from the other model's catalog would be rejected by
            // the session; fall back to the service default.
            if !draft.agentRealtimeVoice.isEmpty,
               !fetched.isEmpty,
               !fetched.contains(where: { $0.id == draft.agentRealtimeVoice }) {
                draft.agentRealtimeVoice = ""
            }
        } catch {
            loadFailed = true
        }
    }
}

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

            fieldSection("打电话（agentRealtime）", systemImage: "phone") {
                SecureField("agentRealtime API key（ar_live_…）", text: $draft.agentRealtimeAPIKey)
                Picker("模型", selection: $draft.agentRealtimeModelProfile) {
                    Text("Realtime · 豆包").tag("realtime_doubao")
                    Text("Realtime · Qwen-Omni").tag("realtime_qwen_omni")
                }
                .pickerStyle(.segmented)
                AgentRealtimeVoicePicker(draft: $draft)
                Text("实时语音通话：在会话工具栏点电话图标，和当前角色开始通话。音色按所选模型自动加载。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
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
                    Picker("ASR 模型", selection: $draft.agentLLMASRModel) {
                        Text("fun-asr-realtime（推荐）").tag("fun-asr-realtime")
                        Text("paraformer-realtime-v2").tag("paraformer-realtime-v2")
                    }
                    Text("实时识别（DashScope 协议，边说边出字），按音频时长计费。")
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
