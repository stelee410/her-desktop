import Foundation

/// Drives the user's everyday Chrome through the loaded Her extension,
/// exposing the same BrowserBridging surface as the dedicated-profile
/// sidecar so the browser capabilities are target-agnostic.
@MainActor
final class ExtensionBrowserBridge: BrowserBridging {
    private let server: BrowserExtensionServer

    init(server: BrowserExtensionServer) {
        self.server = server
    }

    var isRunning: Bool { server.isRunning && server.isExtensionConnected }
    private(set) var currentURL: String = ""

    enum BridgeError: LocalizedError {
        case notConnected
        case actionFailed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "The Her Chrome extension is not connected. Load it in Chrome (chrome://extensions → Load unpacked → the browser-extension folder), then open a tab."
            case .actionFailed(let message):
                return message
            }
        }
    }

    func start() async throws {
        if !server.isRunning { try server.start() }
        // Give a freshly loaded extension a moment to check in.
        for _ in 0..<10 {
            if server.isExtensionConnected { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !server.isExtensionConnected { throw BridgeError.notConnected }
    }

    private func run(_ action: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        // Readiness is enforced by start(); here we just enqueue and await
        // (a missing extension surfaces as a timeout).
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        let data = try await server.enqueue(action: action, paramsJSON: paramsJSON)
        let result = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        if let ok = result["ok"] as? Bool, !ok {
            throw BridgeError.actionFailed((result["error"] as? String) ?? "extension error")
        }
        return result
    }

    private func actionResult(_ result: [String: Any]) -> BrowserActionResult {
        currentURL = (result["url"] as? String) ?? currentURL
        var png: Data?
        if let shot = result["screenshot"] as? String {
            let base64 = shot.contains(",") ? String(shot.split(separator: ",").last ?? "") : shot
            png = Data(base64Encoded: base64)
        }
        return BrowserActionResult(url: currentURL, title: (result["title"] as? String) ?? "", screenshotPNG: png)
    }

    func navigate(_ url: String) async throws -> BrowserActionResult {
        actionResult(try await run("navigate", ["url": url]))
    }

    func click(selector: String?, x: Double?, y: Double?, index: Int?) async throws -> BrowserActionResult {
        var params: [String: Any] = [:]
        if let selector { params["selector"] = selector }
        if let index { params["index"] = index }
        return actionResult(try await run("click", params))
    }

    func type(text: String, selector: String?, enter: Bool, index: Int?) async throws -> BrowserActionResult {
        var params: [String: Any] = ["text": text, "enter": enter]
        if let selector { params["selector"] = selector }
        if let index { params["index"] = index }
        return actionResult(try await run("type", params))
    }

    func press(key: String) async throws -> BrowserActionResult {
        actionResult(try await run("key", ["key": key]))
    }

    func read() async throws -> BrowserReadResult {
        let result = try await run("read")
        currentURL = (result["url"] as? String) ?? currentURL
        let links = (result["links"] as? [[String: Any]] ?? []).map {
            (text: ($0["t"] as? String) ?? "", href: ($0["href"] as? String) ?? "")
        }
        let elements = (result["elements"] as? [[String: Any]] ?? []).map {
            BrowserElement(index: ($0["index"] as? Int) ?? 0, tag: ($0["tag"] as? String) ?? "",
                           type: ($0["type"] as? String) ?? "", label: ($0["label"] as? String) ?? "")
        }
        return BrowserReadResult(url: currentURL, title: (result["title"] as? String) ?? "",
                                 text: (result["text"] as? String) ?? "", links: links, elements: elements)
    }

    func screenshotPNG() async throws -> Data {
        let result = try await run("screenshot")
        guard let shot = result["screenshot"] as? String else { throw BridgeError.actionFailed("no screenshot") }
        let base64 = shot.contains(",") ? String(shot.split(separator: ",").last ?? "") : shot
        guard let data = Data(base64Encoded: base64) else { throw BridgeError.actionFailed("bad screenshot") }
        return data
    }

    func detectionReport() async throws -> String {
        // The everyday Chrome has no automation driver, so this is inherently
        // a real human browser.
        "使用你日常的 Chrome（扩展驱动），没有任何自动化驱动程序，navigator.webdriver = false，指纹与你平时完全一致——反检测强度最高。"
    }
}
