import SwiftTerm
import SwiftUI

/// Hosts the shared terminal view inside SwiftUI.
struct TerminalHostView: NSViewRepresentable {
    var controller: TerminalController
    var workingDirectory: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.startIfNeeded(workingDirectory: workingDirectory)
        return controller.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

/// The bottom drawer: header with title and close, terminal below.
struct TerminalDrawer: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var chrome: UIChrome

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(AppTheme.coral)
                Text("终端")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("对话可以读取屏幕并输入（输入需审批）")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Button {
                    chrome.isTerminalPresented = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("收起终端")
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.white.opacity(0.5))

            TerminalHostView(
                controller: model.terminalControllerInstance,
                workingDirectory: model.runtimeCwd
            )
        }
    }
}
