import Foundation
import SwiftUI

/// Conversation ↔ embedded terminal: open the drawer, read the visible
/// screen, and (with approval) type into whatever is running — a shell
/// prompt or a full TUI like claude.
extension AppViewModel {
    func openTerminalCapability() -> CapabilityResult {
        isTerminalPresented = true
        terminalBridge.startIfNeeded(workingDirectory: runtimeCwd)
        audit(type: "terminal.opened", summary: "Opened the terminal drawer from the conversation.")
        return CapabilityResult(
            title: "Terminal Opened",
            content: currentScreenBlock(),
            requiresUserApproval: false
        )
    }

    func readTerminalCapability() -> CapabilityResult {
        guard terminalBridge.isRunning else {
            return CapabilityResult(
                title: "Terminal Not Running",
                content: "The terminal has not been started yet. Call terminal.open first.",
                requiresUserApproval: false
            )
        }
        audit(type: "terminal.read", summary: "Read the terminal screen from the conversation.")
        return CapabilityResult(
            title: "Terminal Screen",
            content: currentScreenBlock(),
            requiresUserApproval: false
        )
    }

    func sendTerminalCapability(arguments: [String: Any]) async -> CapabilityResult {
        let text = stringArgument(arguments, keys: ["text", "input"], fallback: "")
        let key = stringArgument(arguments, keys: ["key"], fallback: "")
        let pressEnter = boolArgument(arguments, keys: ["enter", "press_enter", "pressEnter"], fallback: false)
        guard !text.isEmpty || !key.isEmpty || pressEnter else {
            return CapabilityResult(
                title: "Terminal Send Failed",
                content: "Provide text to type, a named key, or enter=true.",
                requiresUserApproval: false
            )
        }
        var payload = text
        if !key.isEmpty {
            guard let sequence = TerminalController.controlSequence(for: key) else {
                return CapabilityResult(
                    title: "Terminal Send Failed",
                    content: "Unknown key \"\(key)\". Supported: enter, tab, escape, backspace, space, up, down, left, right, ctrl-c, ctrl-d, ctrl-z, ctrl-r, ctrl-l, shift-tab.",
                    requiresUserApproval: false
                )
            }
            payload += sequence
        }
        if pressEnter {
            payload += "\r"
        }
        // Typing into the terminal always surfaces it, so the user watches
        // exactly what the conversation is doing.
        isTerminalPresented = true
        terminalBridge.startIfNeeded(workingDirectory: runtimeCwd)
        terminalBridge.send(text: payload)
        audit(
            type: "terminal.input_sent",
            summary: "Conversation sent input to the terminal.",
            metadata: [
                "characters": String(text.count),
                "key": key.isEmpty ? "none" : key,
                "enter": String(pressEnter)
            ]
        )
        // Give the program a moment to react so the reply includes fresh output.
        try? await Task.sleep(nanoseconds: 600_000_000)
        return CapabilityResult(
            title: "Terminal Input Sent",
            content: currentScreenBlock(),
            requiresUserApproval: false
        )
    }

    private func currentScreenBlock() -> String {
        var screen = terminalBridge.screenText()
        if screen.count > 6_000 {
            screen = "...(truncated)\n" + String(screen.suffix(6_000))
        }
        return screen.isEmpty
            ? "(screen is empty)"
            : "Current terminal screen:\n```\n\(screen)\n```"
    }
}
