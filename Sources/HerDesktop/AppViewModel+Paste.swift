import AppKit
import Foundation

/// ⌘V in the composer: when the clipboard holds an image (screenshot, copied
/// picture) or copied files, paste attaches them instead of doing nothing.
/// Plain text keeps the system paste behavior untouched.
extension AppViewModel {
    func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let swallow = MainActor.assumeIsolated {
                self?.consumePasteEvent(event) ?? false
            }
            return swallow ? nil : event
        }
    }

    func removePasteMonitor() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
        }
        pasteMonitor = nil
    }

    /// true = the paste became an attachment and the event must not reach
    /// the text system (which would otherwise paste a file path or nothing).
    func consumePasteEvent(_ event: NSEvent) -> Bool {
        // Plain ⌘V only — ⌘⇧V and friends keep their system meaning.
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return false
        }
        // Same scope as push-to-talk: main window (not sheets), Today section.
        guard event.window?.sheetParent == nil,
              selectedSection == .today,
              !isVibePluginComposerPresented else {
            return false
        }
        let focusedTextView = event.window?.firstResponder as? NSTextView
        guard composerFocused || focusedTextView == nil else { return false }
        return attachFromPasteboard(NSPasteboard.general)
    }

    /// Copied files attach directly; raw image data lands as a PNG
    /// attachment; anything else (text) is not ours to handle.
    func attachFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            attachFiles(urls)
            return true
        }
        guard let data = Self.pngData(from: pasteboard) else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "剪贴板图片-\(formatter.string(from: Date())).png"
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-paste-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let file = temp.appendingPathComponent(name)
            try data.write(to: file)
            attachFiles([file])
            try? FileManager.default.removeItem(at: temp)
            return true
        } catch {
            lastError = "剪贴板图片无法保存：\(error.localizedDescription)"
            return true
        }
    }

    /// PNG straight from the pasteboard when available, otherwise convert
    /// TIFF (what screenshots and most apps put there) to PNG.
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
