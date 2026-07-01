import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            LaunchReadinessStrip()
                .padding(.horizontal, 54)
                .padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        VoicePresenceView()
                            .padding(.top, 34)

                        ForEach(model.messages) { message in
                            MessageBubble(
                                message: message,
                                artifacts: model.webServiceArtifacts(for: message)
                            )
                                .id(message.id)
                        }

                        if let lastError = model.lastError {
                            Text(lastError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.bottom, 26)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            ComposerView()
                .padding(.horizontal, 54)
                .padding(.bottom, 24)
        }
    }
}

private struct LaunchReadinessStrip: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.openSettings) private var openSettings

    private var summary: ProductReadinessSummary {
        model.productReadinessSummary
    }

    var body: some View {
        let actions = summary.suggestedActions(limit: 3)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: summary.isReadyForCoreWork ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(summary.isReadyForCoreWork ? .green : AppTheme.coral)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(summary.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(summary.score)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(summary.isReadyForCoreWork ? .green : AppTheme.coral)
                }
                Text(summary.detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ForEach(actions) { item in
                if let action = item.action, let title = item.actionTitle {
                    Button(title) {
                        perform(action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(item.detail)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private func perform(_ action: ProductReadinessAction) {
        model.performProductReadinessAction(action) { openSettings() }
    }
}

private struct ToolbarView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        let status = PresenceCopy.serviceStatus(model.serviceHealth)
        HStack(spacing: 20) {
            Picker("Project", selection: .constant(model.config.agentCode)) {
                Text(model.config.agentCode).tag(model.config.agentCode)
            }
            .labelsHidden()
            .frame(width: 180)

            Spacer()

            ToolbarChip(
                icon: "waveform",
                title: model.connectionState == .listening ? "Listening" : "Voice",
                active: model.connectionState == .listening || model.connectionState == .speaking,
                help: "Start or stop voice input"
            ) {
                model.toggleDictation()
            }
            ToolbarChip(
                icon: "scope",
                title: "Focus",
                active: model.selectedSection == .projects,
                help: "Open projects and focus"
            ) {
                model.selectedSection = .projects
            }
            ToolbarChip(
                icon: "shippingbox",
                title: "Tools",
                active: model.selectedSection == .tools,
                help: "Open tools and plugins"
            ) {
                model.selectedSection = .tools
            }

            Spacer()

            Button {
                model.setSpeakAssistantReplies(!model.config.speakAssistantReplies)
            } label: {
                Image(systemName: model.config.speakAssistantReplies ? "speaker.wave.2.fill" : "speaker.slash")
                    .foregroundStyle(model.config.speakAssistantReplies ? AppTheme.coral : AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help(model.config.speakAssistantReplies ? "Disable spoken replies" : "Enable spoken replies")

            Label(status.title, systemImage: status.systemImage)
                .font(.caption)
                .foregroundStyle(color(for: status.tone))
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.muted)
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .background(Color.white.opacity(0.38))
    }

    private func color(for tone: PresenceStatus.Tone) -> Color {
        switch tone {
        case .healthy: return .green
        case .warning: return .orange
        case .muted: return AppTheme.muted
        case .active: return AppTheme.coral
        }
    }
}

private struct ToolbarChip: View {
    var icon: String
    var title: String
    var active: Bool = false
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline)
            .foregroundStyle(active ? AppTheme.coral : AppTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? AppTheme.coral.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct VoicePresenceView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(AppTheme.coral.opacity(0.09), lineWidth: 34)
                    .frame(width: 182, height: 182)
                Circle()
                    .stroke(AppTheme.coral.opacity(0.14), lineWidth: 1)
                    .frame(width: 218, height: 218)
                Circle()
                    .fill(
                        RadialGradient(colors: [AppTheme.coral.opacity(0.72), AppTheme.coral.opacity(0.06)], center: .center, startRadius: 10, endRadius: 86)
                    )
                    .frame(width: 154, height: 154)
                    .blur(radius: 0.4)
                WaveLine()
                    .stroke(Color.white.opacity(0.82), lineWidth: 1.4)
                    .frame(width: 118, height: 36)
            }
            Text(greeting)
                .font(.system(size: 30, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.burgundy)
        }
    }

    private var greeting: String {
        PresenceCopy.greeting(
            connectionState: model.connectionState,
            agentProfile: model.agentProfile
        )
    }
}

private struct WaveLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for x in stride(from: rect.minX, through: rect.maxX, by: 4) {
            let progress = (x - rect.minX) / max(rect.width, 1)
            let y = rect.midY + sin(progress * .pi * 2) * 4
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var model: AppViewModel
    var message: ChatMessage
    var artifacts: [WebServiceArtifact] = []

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.attachments) { attachment in
                            AttachmentChip(attachment: attachment)
                        }
                    }
                }
                if !artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(artifacts) { artifact in
                            MessageArtifactChip(artifact: artifact) {
                                model.openWebServiceArtifact(
                                    path: artifact.primaryLocalImagePath ?? artifact.manifestPath
                                )
                            }
                        }
                    }
                }
                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(message.role == .user ? AppTheme.rose.opacity(0.72) : Color.white.opacity(0.54))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            if message.role != .user { Spacer(minLength: 70) }
        }
    }
}

private struct MessageArtifactChip: View {
    var artifact: WebServiceArtifact
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                preview
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Text("\(artifact.request.status) · \(artifact.artifacts.count) item(s)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open generated artifact")
    }

    private var title: String {
        artifact.primaryLocalImagePath == nil ? "Generated Artifact" : "Generated Image"
    }

    @ViewBuilder
    private var preview: some View {
        if let path = artifact.primaryLocalImagePath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            Image(systemName: artifact.remoteURLs.isEmpty ? "doc.richtext" : "photo")
                .foregroundStyle(AppTheme.coral)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                model.removePendingAttachment(attachment)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }

            HStack(spacing: 12) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.muted)
                .help("Attach files")

                TextField("Ask anything or give a command...", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 15))

                Button {
                    model.toggleDictation()
                } label: {
                    Image(systemName: model.connectionState == .listening ? "stop.circle.fill" : "mic.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.coral)
                .help(model.connectionState == .listening ? "Stop dictation" : "Start dictation")

                Button {
                    Task { await model.sendDraft() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.coral)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty)
            }
            if model.connectionState == .listening, !model.dictationTranscript.isEmpty {
                Label(model.dictationTranscript, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
            }
        }
        .padding(8)
        .background(isDropTargeted ? AppTheme.rose.opacity(0.82) : Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(isDropTargeted ? AppTheme.coral.opacity(0.45) : Color.black.opacity(0.06), lineWidth: 1)
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.attachFiles(urls)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            importDroppedFiles(providers)
        }
    }

    private func importDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in
                    model.attachFiles([url])
                }
            }
        }
        return !providers.isEmpty
    }
}

private struct AttachmentChip: View {
    var attachment: MessageAttachment

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName(for: attachment.kind))
                .foregroundStyle(AppTheme.coral)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Text(byteString(attachment.byteCount))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PendingAttachmentChip: View {
    var attachment: MessageAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: attachment.kind))
                .foregroundStyle(AppTheme.coral)
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private func iconName(for kind: MessageAttachment.Kind) -> String {
    switch kind {
    case .text:
        return "doc.text"
    case .image:
        return "photo"
    case .video:
        return "film"
    case .audio:
        return "waveform"
    case .pdf:
        return "doc.richtext"
    case .archive:
        return "archivebox"
    case .other:
        return "paperclip"
    }
}

private func byteString(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
