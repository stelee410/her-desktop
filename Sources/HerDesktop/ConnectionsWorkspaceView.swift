import SwiftUI

/// 「连接」工作区：外部聊天平台接入的配置与状态。
/// v1 只有微信（infiniti-weixin-bridge）；Discord / 飞书占位待接。
struct ConnectionsWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel

    @State private var enabled = false
    @State private var bridgeDirectory = ""
    @State private var botNames = ""
    @State private var groupMode = "mention"
    @State private var isSaving = false

    @State private var tgEnabled = false
    @State private var tgToken = ""
    @State private var tgAllowed = ""
    @State private var tgSaving = false

    private var isDirty: Bool {
        enabled != model.config.wechatConnectorEnabled
            || bridgeDirectory != model.config.wechatBridgeDirectory
            || botNames != model.config.wechatBotNames
            || groupMode != model.config.wechatGroupMode
    }

    private var tgDirty: Bool {
        tgEnabled != model.config.telegramConnectorEnabled
            || tgToken != model.config.telegramBotToken
            || tgAllowed != model.config.telegramAllowedChatIDs
    }

    var body: some View {
        WorkspacePage(title: "连接", subtitle: "把微信、Discord、飞书接进 Her——消息进出都落在专属会话里") {
            HStack(spacing: 12) {
                WorkspaceMetric(
                    title: "微信桥",
                    value: model.wechatBridgeProcess != nil ? "运行中" : (model.config.wechatConnectorEnabled ? "未运行" : "未启用"),
                    icon: "message"
                )
                WorkspaceMetric(
                    title: "Telegram",
                    value: model.telegramConnector.isRunning ? "在线" : (model.config.telegramConnectorEnabled ? "未运行" : "未启用"),
                    icon: "paperplane"
                )
                WorkspaceMetric(title: "专属会话", value: "📱 ✈️", icon: "bubble.left.and.bubble.right")
            }

            WorkspacePanel(title: "微信", trailing: model.wechatBridgeProcess != nil ? "在线" : "离线") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用微信桥（infiniti-weixin-bridge）", isOn: $enabled)
                        .toggleStyle(.switch)
                        .tint(AppTheme.coral)

                    TextField("桥目录（含 dist/cli.js）", text: $bridgeDirectory)
                        .textFieldStyle(.roundedBorder)
                    TextField("群聊 @ 触发名（逗号分隔，可留空）", text: $botNames)
                        .textFieldStyle(.roundedBorder)
                    Picker("群聊策略", selection: $groupMode) {
                        Text("忽略群聊").tag("ignore")
                        Text("仅 @ 我时").tag("mention")
                        Text("全部消息").tag("all")
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.wechatBridgeProcess != nil ? Color.green : AppTheme.muted)
                            .frame(width: 7, height: 7)
                        Text(model.wechatConnectorStatus)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            Task {
                                isSaving = true
                                var draft = HerAppConfigDraft(config: model.config)
                                draft.wechatConnectorEnabled = enabled
                                draft.wechatBridgeDirectory = bridgeDirectory
                                draft.wechatBotNames = botNames
                                draft.wechatGroupMode = groupMode
                                await model.saveConfiguration(draft)
                                syncFromConfig()
                                isSaving = false
                            }
                        } label: {
                            Label(isSaving ? "保存中" : "保存并应用", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.coral)
                        .controlSize(.small)
                        .disabled(isSaving || !isDirty)
                    }

                    Text("首次使用先在终端执行 infiniti-weixin-bridge login 扫码登录。消息会进入侧栏「📱 微信」会话——可为它绑定角色卡、单独选模型。语音消息暂以文字婉拒；桥日志在 .her/logs/wechat-bridge.log。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            WorkspacePanel(title: "Telegram", trailing: model.telegramConnector.isRunning ? "在线" : "离线") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用 Telegram Bot", isOn: $tgEnabled)
                        .toggleStyle(.switch)
                        .tint(AppTheme.coral)

                    SecureField("Bot token（@BotFather 提供，形如 123456:ABC…）", text: $tgToken)
                        .textFieldStyle(.roundedBorder)
                    TextField("允许的 chat_id 白名单（逗号分隔，留空=不限）", text: $tgAllowed)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.telegramConnector.isRunning ? Color.green : AppTheme.muted)
                            .frame(width: 7, height: 7)
                        Text(model.telegramConnectorStatus)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            Task {
                                tgSaving = true
                                var draft = HerAppConfigDraft(config: model.config)
                                draft.telegramConnectorEnabled = tgEnabled
                                draft.telegramBotToken = tgToken
                                draft.telegramAllowedChatIDs = tgAllowed
                                await model.saveConfiguration(draft)
                                syncFromConfig()
                                tgSaving = false
                            }
                        } label: {
                            Label(tgSaving ? "保存中" : "保存并应用", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.coral)
                        .controlSize(.small)
                        .disabled(tgSaving || !tgDirty)
                    }

                    Text("在 Telegram 里找 @BotFather → /newbot 建一个 bot，把它给的 token 填进来即可。消息进入侧栏「✈️ Telegram」会话——可绑角色卡、单独选模型。首次给 bot 发 /start 会回你的 chat_id，填进白名单只让自己用。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            WorkspacePanel(title: "更多平台", trailing: "规划中") {
                VStack(spacing: 8) {
                    EmptyWorkspaceLine(icon: "gamecontroller", text: "Discord — 即将支持")
                    EmptyWorkspaceLine(icon: "paperplane", text: "飞书 — 即将支持")
                }
            }
        }
        .onAppear(perform: syncFromConfig)
        .onChange(of: model.config) { _, _ in syncFromConfig() }
    }

    private func syncFromConfig() {
        enabled = model.config.wechatConnectorEnabled
        bridgeDirectory = model.config.wechatBridgeDirectory
        botNames = model.config.wechatBotNames
        groupMode = model.config.wechatGroupMode
        tgEnabled = model.config.telegramConnectorEnabled
        tgToken = model.config.telegramBotToken
        tgAllowed = model.config.telegramAllowedChatIDs
    }
}
