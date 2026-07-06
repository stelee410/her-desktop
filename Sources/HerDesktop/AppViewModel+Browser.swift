import AppKit
import Foundation

/// Conversation ↔ real Chrome: open a persistent-profile browser that
/// reuses the user's logins, read what's on screen, and (with approval)
/// navigate, click, and type. Reads are free; anything with a side effect
/// is approval-gated and surfaces the browser drawer so the user watches.
extension AppViewModel {
    func openBrowserCapability() async -> CapabilityResult {
        isBrowserPresented = true
        do {
            try await browserBridge.start()
        } catch {
            return CapabilityResult(
                title: "Browser Failed to Start",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
        audit(type: "browser.opened", summary: "Opened the browser from the conversation.")
        return CapabilityResult(
            title: "Browser Opened",
            content: "A real Chrome window is ready with your persistent profile (logins reused). Current page: \(browserBridge.currentURL.isEmpty ? "blank" : browserBridge.currentURL). Use browser.navigate / browser.read / browser.click / browser.type.",
            requiresUserApproval: false
        )
    }

    func navigateBrowserCapability(arguments: [String: Any]) async -> CapabilityResult {
        let url = stringArgument(arguments, keys: ["url", "address"], fallback: "")
        guard !url.isEmpty else {
            return CapabilityResult(title: "Browser Navigate Failed", content: "Provide a url.", requiresUserApproval: false)
        }
        return await withStartedBrowser {
            let result = try await self.browserBridge.navigate(url)
            self.audit(type: "browser.navigated", summary: "Navigated the browser.", metadata: ["url": result.url])
            return CapabilityResult(title: "Navigated", content: self.pageBlock(url: result.url, title: result.title), requiresUserApproval: false)
        }
    }

    func readBrowserCapability() async -> CapabilityResult {
        guard browserBridge.isRunning else {
            return CapabilityResult(title: "Browser Not Running", content: "Call browser.open first.", requiresUserApproval: false)
        }
        do {
            let read = try await browserBridge.read()
            audit(type: "browser.read", summary: "Read the browser page.", metadata: ["url": read.url])
            var content = "URL: \(read.url)\nTitle: \(read.title)\n\n\(read.text)"
            if !read.elements.isEmpty {
                let elementLines = read.elements.prefix(80).map { el in
                    let kind = el.type.isEmpty ? el.tag : "\(el.tag)/\(el.type)"
                    return "[\(el.index)] \(kind): \(el.label.isEmpty ? "(no label)" : el.label)"
                }.joined(separator: "\n")
                content += "\n\nInteractive elements (use the [index] with browser.click / browser.type):\n\(elementLines)"
            }
            return CapabilityResult(title: "Browser Page", content: content, requiresUserApproval: false)
        } catch {
            return CapabilityResult(title: "Browser Read Failed", content: error.localizedDescription, requiresUserApproval: false)
        }
    }

    func clickBrowserCapability(arguments: [String: Any]) async -> CapabilityResult {
        let selector = stringArgument(arguments, keys: ["selector", "css"], fallback: "")
        let x = doubleArgument(arguments, keys: ["x"])
        let y = doubleArgument(arguments, keys: ["y"])
        let index = integerArgumentOptional(arguments, keys: ["index", "element", "element_index"])
        guard !selector.isEmpty || (x != nil && y != nil) || index != nil else {
            return CapabilityResult(title: "Browser Click Failed", content: "Provide an element index (from browser.read), a selector, or x/y.", requiresUserApproval: false)
        }
        return await withStartedBrowser {
            let result = try await self.browserBridge.click(selector: selector.isEmpty ? nil : selector, x: x, y: y, index: index)
            self.audit(type: "browser.clicked", summary: "Clicked in the browser.", metadata: ["selector": selector, "url": result.url])
            return CapabilityResult(title: "Clicked", content: self.pageBlock(url: result.url, title: result.title), requiresUserApproval: false)
        }
    }

    func typeBrowserCapability(arguments: [String: Any]) async -> CapabilityResult {
        let text = stringArgument(arguments, keys: ["text", "input"], fallback: "")
        let selector = stringArgument(arguments, keys: ["selector", "css"], fallback: "")
        let key = stringArgument(arguments, keys: ["key"], fallback: "")
        let index = integerArgumentOptional(arguments, keys: ["index", "element", "element_index"])
        let enter = boolArgument(arguments, keys: ["enter", "press_enter", "pressEnter"], fallback: false)
        guard !text.isEmpty || !key.isEmpty else {
            return CapabilityResult(title: "Browser Type Failed", content: "Provide text or a key.", requiresUserApproval: false)
        }
        return await withStartedBrowser {
            let result: BrowserActionResult
            if !key.isEmpty {
                result = try await self.browserBridge.press(key: key)
            } else {
                result = try await self.browserBridge.type(text: text, selector: selector.isEmpty ? nil : selector, enter: enter, index: index)
            }
            self.audit(type: "browser.typed", summary: "Typed in the browser.", metadata: ["characters": String(text.count), "url": result.url])
            return CapabilityResult(title: "Typed", content: self.pageBlock(url: result.url, title: result.title), requiresUserApproval: false)
        }
    }

    func startExtensionServerIfNeeded() {
        guard !browserExtensionServer.isRunning else { return }
        try? browserExtensionServer.start()
    }

    /// Reveal the bundled unpacked extension so the user can load it. The
    /// files ship flattened in the resource bundle, so copy them into a
    /// clean `.her/browser-extension/` folder the user points Chrome at.
    func openBrowserExtensionFolder() {
        let destination = HerWorkspacePaths.localAgentDirectory(cwd: runtimeCwd)
            .appendingPathComponent("browser-extension", isDirectory: true)
        let names = ["manifest.json", "background.js", "options.html", "options.js"]
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in names {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let source = Bundle.module.url(forResource: base, withExtension: ext) else { continue }
            let target = destination.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        audit(type: "browser.extension_folder_opened", summary: "Revealed the unpacked browser extension.")
    }

    /// Port + token the user pastes into the extension's options page.
    var extensionConfig: (port: Int, token: String) {
        (port: Int(browserExtensionServer.port ?? 8799), token: browserExtensionServer.sharedToken)
    }

    var isExtensionConnected: Bool {
        browserExtensionServer.isExtensionConnected
    }

    func detectBrowserCapability() async -> CapabilityResult {
        guard browserBridge.isRunning else {
            return CapabilityResult(title: "Browser Not Running", content: "Call browser.open first.", requiresUserApproval: false)
        }
        do {
            let report = try await browserBridge.detectionReport()
            audit(type: "browser.detect", summary: "Checked browser anti-detection signals.")
            return CapabilityResult(title: "Browser Detection Check", content: report, requiresUserApproval: false)
        } catch {
            return CapabilityResult(title: "Detection Check Failed", content: error.localizedDescription, requiresUserApproval: false)
        }
    }

    private func withStartedBrowser(_ body: () async throws -> CapabilityResult) async -> CapabilityResult {
        isBrowserPresented = true
        do {
            try await browserBridge.start()
            return try await body()
        } catch {
            return CapabilityResult(title: "Browser Action Failed", content: error.localizedDescription, requiresUserApproval: false)
        }
    }

    private func pageBlock(url: String, title: String) -> String {
        "Now on: \(title.isEmpty ? url : title)\nURL: \(url)\n(The browser drawer shows the live page. Call browser.read for the page text.)"
    }

    func doubleArgument(_ arguments: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = arguments[key] as? Double { return value }
            if let value = arguments[key] as? Int { return Double(value) }
            if let value = arguments[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    func integerArgumentOptional(_ arguments: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = arguments[key] as? Int { return value }
            if let value = arguments[key] as? Double { return Int(value) }
            if let value = arguments[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }
}
