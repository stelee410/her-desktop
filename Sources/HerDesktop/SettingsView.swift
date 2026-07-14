import SwiftUI
import UniformTypeIdentifiers

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
                VStack(alignment: .leading, spacing: 16) {
                    HerConfigurationFields(draft: $draft, presentation: .settings)
                    Divider()
                    VoiceprintSettingsSection()
                }
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

private struct VoiceprintSettingsSection: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("声纹识别（本地）", systemImage: "person.wave.2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            if let profile = model.voiceprintProfile {
                Toggle(
                    "通话时只接受我的声音",
                    isOn: Binding(
                        get: { profile.enabled },
                        set: { model.setVoiceprintEnabled($0) }
                    )
                )
                Text("已录入 · \(profile.createdAt.formatted(date: .abbreviated, time: .shortened)) · 模板仅保存在本机")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            } else {
                Text("尚未录入。录入后，每段语音会先在本机匹配，只有匹配的声音才会发送给通话服务。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
            if model.isEnrollingVoiceprint {
                ProgressView(value: Double(model.voiceprintEnrollmentProgress), total: 100)
                ProgressView(
                    value: min(Double(model.voiceprintEnrollmentLevel) / 1_200, 1),
                    label: { Text("麦克风音量") }
                )
                Text(
                    "\(model.voiceprintEnrollmentProgress)% · "
                    + (model.voiceprintEnrollmentLevel >= EnrollmentCollector.minimumVoiceLevel
                       ? "已检测到说话声"
                       : "声音偏低，请靠近麦克风")
                    + " · 有效语音 \(String(format: "%.1f", Double(model.voiceprintEnrollmentVoicedMilliseconds) / 1_000)) 秒"
                )
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
            HStack {
                Button(model.voiceprintProfile == nil ? "录入声纹" : "重新录入") {
                    Task { await model.enrollVoiceprint() }
                }
                .disabled(model.isEnrollingVoiceprint || model.isCallPresented)
                if model.voiceprintProfile != nil {
                    Button("删除声纹", role: .destructive) { model.clearVoiceprint() }
                        .disabled(model.isEnrollingVoiceprint)
                }
            }
            if !model.voiceprintEnrollmentStatus.isEmpty {
                Text(model.voiceprintEnrollmentStatus)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
            Text("轻量过滤，不属于安全认证，无法防止他人播放你的录音。首次匹配会带来约 1.5 秒延迟。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
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

/// 数字人形象图：本地选图（自动转 base64 data URI，Vidu 要求解码后 <20MB）
/// 或直接粘贴图片 URL；旁边给一个当前值的缩略图预览。
struct ViduAvatarPickerField: View {
    @Binding var draft: HerAppConfigDraft
    @State private var isImporterPresented = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                avatarPreview
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                Button("选择图片…") {
                    isImporterPresented = true
                }
                if !draft.viduAvatarImageURI.isEmpty {
                    Button("清除") {
                        draft.viduAvatarImageURI = ""
                        importError = nil
                    }
                }
            }
            TextField("数字人形象图：上传，或粘贴图片 URL", text: $draft.viduAvatarImageURI)
            if let importError {
                Text(importError)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.coral)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.png, .jpeg, .webP],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                draft.viduAvatarImageURI = try ViduAvatarImageEncoder.dataURI(contentsOf: url)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        let value = draft.viduAvatarImageURI.trimmingCharacters(in: .whitespacesAndNewlines)
        if let image = Self.decodeDataURI(value) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.black.opacity(0.05)
            Image(systemName: "person.crop.rectangle")
                .foregroundStyle(AppTheme.muted)
        }
    }

    private static func decodeDataURI(_ value: String) -> NSImage? {
        guard value.hasPrefix("data:"),
              let comma = value.firstIndex(of: ","),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else {
            return nil
        }
        return NSImage(data: data)
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

            fieldSection("视频通话（Vidu 数字人）", systemImage: "video") {
                SecureField("Vidu API key（vda_…）", text: $draft.viduAPIKey)
                TextField("API host（默认 api.vidu.cn）", text: $draft.viduHost)
                Picker("通话模式", selection: $draft.viduCallMode) {
                    Text("音视频").tag("video")
                    Text("纯语音").tag("audio")
                }
                .pickerStyle(.segmented)
                ViduAvatarPickerField(draft: $draft)
                TextField("数字人名字（默认用角色卡名）", text: $draft.viduAvatarName)
                TextField("音色（默认 Tina）", text: $draft.viduVoice)
                Text("按通话时长计费（约 90 积分/分钟），单次最长 10 分钟。人设优先取当前会话的角色卡。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
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
