import SwiftUI

/// 打电话: the in-call surface — who you're talking to, live captions, and
/// the mute / hang-up controls.
struct CallView: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject var call: RealtimeCallController

    private var partnerName: String {
        model.activeCharacterCard?.name ?? model.agentProfile.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                avatar
                    .padding(.top, 36)
                Text(partnerName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                stateLine
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)

            Divider().opacity(0.35)

            // Live captions: user turns and assistant turns as they stream.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(call.transcript) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.role == .user ? "我" : partnerName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(line.role == .user ? AppTheme.muted : AppTheme.coral)
                                    .frame(width: 52, alignment: .trailing)
                                Text(line.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: call.transcript.last?.text) { _, _ in
                    if let last = call.transcript.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.35)

            HStack(spacing: 40) {
                Button {
                    call.isMuted.toggle()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 18))
                            .frame(width: 46, height: 46)
                            .background(call.isMuted ? AppTheme.coral.opacity(0.15) : Color.black.opacity(0.05))
                            .clipShape(Circle())
                        Text(call.isMuted ? "取消静音" : "静音")
                            .font(.caption2)
                    }
                    .foregroundStyle(call.isMuted ? AppTheme.coral : AppTheme.ink)
                }
                .buttonStyle(.plain)

                Button {
                    model.endVoiceCall()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Circle())
                        Text("挂断")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.ink)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.vertical, 18)
        }
        .frame(width: 360, height: 520)
        .background(AppTheme.cream)
    }

    /// The partner's face, with a soft pulsing ring while she speaks.
    private var avatar: some View {
        ZStack {
            if call.assistantSpeaking {
                Circle()
                    .stroke(AppTheme.coral.opacity(0.35), lineWidth: 3)
                    .frame(width: 96, height: 96)
                    .scaleEffect(call.assistantSpeaking ? 1.06 : 1)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: call.assistantSpeaking
                    )
            }
            Group {
                if let card = model.activeCharacterCard,
                   let url = model.roleplayAssetURL(card.avatarPath),
                   let image = RoleplayImageCache.thumbnail(at: url, maxDimension: 160) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(AppTheme.rose.opacity(0.85))
                        Text(model.activeCharacterCard?.emoji.nilIfEmptyEmoji ?? "💗")
                            .font(.system(size: 34))
                    }
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
        }
        .frame(width: 100, height: 100)
    }

    @ViewBuilder
    private var stateLine: some View {
        switch call.state {
        case .idle, .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("接通中…")
            }
            .font(.caption)
            .foregroundStyle(AppTheme.muted)
        case .active:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(call.assistantSpeaking ? "对方正在说话 · \(clock)" : "通话中 · \(clock)")
                    .font(.caption)
                    .foregroundStyle(call.assistantSpeaking ? AppTheme.coral : AppTheme.muted)
            }
        case .ended(let reason):
            Text(reason.map { "通话结束：\($0)" } ?? "通话结束")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var clock: String {
        let seconds = Int(call.duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension String {
    /// Empty emoji field → nil so the fallback heart shows.
    var nilIfEmptyEmoji: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
