import SwiftUI

struct QuickCaptureSheet: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var url = ""
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AppTheme.coral.opacity(0.14))
                    Image(systemName: "tray.and.arrow.down")
                        .font(.title3)
                        .foregroundStyle(AppTheme.coral)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick Capture")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Drop a thought, task, link, or external thread into Her's inbox.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(Color.white.opacity(0.58))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($textFocused)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                TextField("Optional URL", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("\(text.trimmingCharacters(in: .whitespacesAndNewlines).count) characters")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button {
                    submit()
                } label: {
                    Label("Capture", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .controlSize(.regular)
        }
        .padding(22)
        .frame(width: 520, height: 430)
        .background(AppTheme.windowBackground)
        .onAppear {
            textFocused = true
        }
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        model.captureQuickInboxMessage(text: text, url: url)
        dismiss()
    }
}

