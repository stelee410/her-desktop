import AppKit
import SwiftTerm
import SwiftUI

/// Conversation-facing surface of the embedded terminal, so capabilities
/// can be tested without a live PTY.
@MainActor
protocol TerminalBridging: AnyObject {
    var isRunning: Bool { get }
    func startIfNeeded(workingDirectory: String)
    func screenText() -> String
    func send(text: String)
}

/// Owns the single embedded terminal session: a login shell on a PTY with
/// full TUI emulation (SwiftTerm). The controller outlives the drawer view
/// so hiding the drawer never kills the shell.
@MainActor
final class TerminalController: TerminalBridging {
    let terminalView: LocalProcessTerminalView

    init() {
        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 280))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    var isRunning: Bool {
        terminalView.process?.running ?? false
    }

    func startIfNeeded(workingDirectory: String) {
        guard !isRunning else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // A login shell sources the user's profile, so PATH includes
        // homebrew installs (claude, node, ...) even in a GUI app.
        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: nil,
            currentDirectory: workingDirectory
        )
    }

    /// The currently visible screen (what a user looking at the terminal
    /// sees), trailing blank lines trimmed.
    func screenText() -> String {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    func send(text: String) {
        terminalView.send(txt: text)
    }

    /// Named keys the conversation can press inside TUIs.
    static func controlSequence(for key: String) -> String? {
        switch key.lowercased() {
        case "enter", "return": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return "\u{1b}"
        case "backspace": return "\u{7f}"
        case "space": return " "
        case "up": return "\u{1b}[A"
        case "down": return "\u{1b}[B"
        case "right": return "\u{1b}[C"
        case "left": return "\u{1b}[D"
        case "ctrl-c": return "\u{03}"
        case "ctrl-d": return "\u{04}"
        case "ctrl-z": return "\u{1a}"
        case "ctrl-r": return "\u{12}"
        case "ctrl-l": return "\u{0c}"
        case "shift-tab": return "\u{1b}[Z"
        default: return nil
        }
    }
}

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
