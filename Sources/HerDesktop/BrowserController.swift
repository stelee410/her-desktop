import AppKit
import Foundation

struct BrowserActionResult: Equatable {
    var url: String
    var title: String
    var screenshotPNG: Data?
}

struct BrowserElement: Equatable {
    var index: Int
    var tag: String
    var type: String
    var label: String
}

struct BrowserReadResult: Equatable {
    var url: String
    var title: String
    var text: String
    var links: [(text: String, href: String)]
    var elements: [BrowserElement]

    static func == (lhs: BrowserReadResult, rhs: BrowserReadResult) -> Bool {
        lhs.url == rhs.url && lhs.title == rhs.title && lhs.text == rhs.text
            && lhs.links.map(\.href) == rhs.links.map(\.href) && lhs.elements == rhs.elements
    }
}

/// Conversation-facing surface of the browser, so capabilities are testable
/// without launching Chrome.
@MainActor
protocol BrowserBridging: AnyObject {
    var isRunning: Bool { get }
    var currentURL: String { get }
    func start() async throws
    func navigate(_ url: String) async throws -> BrowserActionResult
    func click(selector: String?, x: Double?, y: Double?, index: Int?) async throws -> BrowserActionResult
    func type(text: String, selector: String?, enter: Bool, index: Int?) async throws -> BrowserActionResult
    func press(key: String) async throws -> BrowserActionResult
    func read() async throws -> BrowserReadResult
    func screenshotPNG() async throws -> Data
    func detectionReport() async throws -> String
}

/// Owns the browser sidecar: a Python (patchright) process that drives the
/// user's real Chrome stable channel with a persistent profile, so logins
/// are reused and automation is hard to detect. Her talks to it over a
/// token-gated loopback HTTP API. The venv and profile live under
/// `.her/browser/`; the process is killed on stop and app exit.
@MainActor
final class BrowserController: ObservableObject, BrowserBridging {
    enum Phase: Equatable {
        case stopped
        case bootstrapping
        case starting
        case running
        case failed(String)
    }

    enum BrowserError: LocalizedError {
        case pythonNotFound
        case venvBootstrapFailed(String)
        case sidecarMissing
        case didNotStart(String)
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "No suitable Python 3.11–3.13 was found. Install it (e.g. brew install python@3.13) and try again."
            case .venvBootstrapFailed(let message):
                return "Could not set up the browser environment: \(message)"
            case .sidecarMissing:
                return "The bundled browser sidecar script is missing."
            case .didNotStart(let message):
                return "The browser did not start: \(message)"
            case .requestFailed(let message):
                return "Browser request failed: \(message)"
            }
        }
    }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var currentURL: String = ""
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var latestScreenshot: Data?

    private let cwd: String
    private let session: URLSession
    private var process: Process?
    private var logHandle: FileHandle?
    private var port: UInt16 = 0
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var starting: Task<Void, Error>?

    init(cwd: String, session: URLSession = .shared) {
        self.cwd = cwd
        self.session = session
    }

    deinit {
        process?.terminate()
        try? logHandle?.close()
    }

    var isRunning: Bool {
        if case .running = phase { return process?.isRunning == true }
        return false
    }

    private var browserDirectory: URL {
        HerWorkspacePaths.localAgentDirectory(cwd: cwd).appendingPathComponent("browser", isDirectory: true)
    }

    private var venvPython: URL {
        browserDirectory.appendingPathComponent("venv/bin/python")
    }

    private var profileDirectory: URL {
        browserDirectory.appendingPathComponent("profile", isDirectory: true)
    }

    func start() async throws {
        if isRunning { return }
        if let starting {
            try await starting.value
            return
        }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        // SwiftPM's .process flattens Resources into the bundle root, so
        // resolve the sidecar script by name rather than by subdirectory.
        guard let sidecar = Bundle.module.url(forResource: "server", withExtension: "py"),
              FileManager.default.fileExists(atPath: sidecar.path) else {
            phase = .failed("sidecar missing")
            throw BrowserError.sidecarMissing
        }
        if !FileManager.default.fileExists(atPath: venvPython.path) {
            phase = .bootstrapping
            try await bootstrapVenv()
        }
        phase = .starting
        let freePort = WebAppProcessManager.findFreePort()
        let logURL = HerWorkspacePaths.logsDirectory(cwd: cwd).appendingPathComponent("browser-sidecar.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)

        let proc = Process()
        proc.executableURL = venvPython
        proc.arguments = [sidecar.path]
        var env = ProcessInfo.processInfo.environment
        env["HER_BROWSER_PORT"] = String(freePort)
        env["HER_BROWSER_TOKEN"] = token
        env["HER_BROWSER_PROFILE"] = profileDirectory.path
        env["HER_BROWSER_CHANNEL"] = "chrome"
        proc.environment = env
        if let handle {
            proc.standardOutput = handle
            proc.standardError = handle
        }
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        do {
            try proc.run()
        } catch {
            phase = .failed(error.localizedDescription)
            throw BrowserError.didNotStart(error.localizedDescription)
        }
        process = proc
        logHandle = handle
        port = freePort

        // Poll /status until the sidecar (and Chrome) are ready.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            guard proc.isRunning else {
                let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.suffix(400).description ?? ""
                phase = .failed("sidecar exited")
                throw BrowserError.didNotStart(tail)
            }
            if let status = try? await request(method: "GET", path: "/status", body: nil) {
                currentURL = (status["url"] as? String) ?? ""
                currentTitle = (status["title"] as? String) ?? ""
                phase = .running
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        proc.terminate()
        phase = .failed("timeout")
        throw BrowserError.didNotStart("Chrome did not become ready in time.")
    }

    private func bootstrapVenv() async throws {
        guard let python = Self.resolveBootstrapPython() else {
            throw BrowserError.pythonNotFound
        }
        try FileManager.default.createDirectory(at: browserDirectory, withIntermediateDirectories: true)
        try await runToCompletion(python, ["-m", "venv", browserDirectory.appendingPathComponent("venv").path])
        try await runToCompletion(venvPython.path, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        try await runToCompletion(venvPython.path, ["-m", "pip", "install", "--quiet", "patchright"])
    }

    private func runToCompletion(_ executable: String, _ args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        // Drains pipes while running: pip's output can exceed the 64 KB pipe
        // buffer, which used to block the child forever mid-bootstrap.
        let output = try await ChildProcessRunner.run(proc, timeout: 600)
        guard output.status == 0 else {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            throw BrowserError.venvBootstrapFailed(String(err.suffix(300)))
        }
    }

    /// Playwright wheels lag the newest CPython, so prefer a proven version.
    static func resolveBootstrapPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3.13", "/usr/local/bin/python3.13",
            "/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12",
            "/opt/homebrew/bin/python3.11", "/usr/local/bin/python3.11"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func stop() {
        starting?.cancel()
        Task { _ = try? await request(method: "POST", path: "/shutdown", body: nil) }
        process?.terminate()
        process = nil
        try? logHandle?.close()
        logHandle = nil
        phase = .stopped
    }

    // MARK: - BrowserBridging

    func navigate(_ url: String) async throws -> BrowserActionResult {
        try await action(path: "/navigate", body: ["url": url])
    }

    func click(selector: String?, x: Double?, y: Double?, index: Int?) async throws -> BrowserActionResult {
        var body: [String: Any] = [:]
        if let selector { body["selector"] = selector }
        if let x { body["x"] = x }
        if let y { body["y"] = y }
        if let index { body["index"] = index }
        return try await action(path: "/click", body: body)
    }

    func type(text: String, selector: String?, enter: Bool, index: Int?) async throws -> BrowserActionResult {
        var body: [String: Any] = ["text": text, "enter": enter]
        if let selector { body["selector"] = selector }
        if let index { body["index"] = index }
        return try await action(path: "/type", body: body)
    }

    func press(key: String) async throws -> BrowserActionResult {
        try await action(path: "/key", body: ["key": key])
    }

    func read() async throws -> BrowserReadResult {
        let object = try await request(method: "GET", path: "/read", body: nil)
        let links = (object["links"] as? [[String: Any]] ?? []).map {
            (text: ($0["t"] as? String) ?? "", href: ($0["href"] as? String) ?? "")
        }
        let elements = (object["elements"] as? [[String: Any]] ?? []).map {
            BrowserElement(
                index: ($0["index"] as? Int) ?? 0,
                tag: ($0["tag"] as? String) ?? "",
                type: ($0["type"] as? String) ?? "",
                label: ($0["label"] as? String) ?? ""
            )
        }
        return BrowserReadResult(
            url: (object["url"] as? String) ?? "",
            title: (object["title"] as? String) ?? "",
            text: (object["text"] as? String) ?? "",
            links: links,
            elements: elements
        )
    }

    func screenshotPNG() async throws -> Data {
        let object = try await request(method: "GET", path: "/screenshot", body: nil)
        guard let base64 = object["screenshot"] as? String, let data = Data(base64Encoded: base64) else {
            throw BrowserError.requestFailed("no screenshot")
        }
        latestScreenshot = data
        return data
    }

    func detectionReport() async throws -> String {
        let object = try await request(method: "GET", path: "/detect", body: nil)
        guard let signals = object["signals"] as? [String: Any] else {
            throw BrowserError.requestFailed("no signals")
        }
        func flag(_ ok: Bool) -> String { ok ? "✓ 人类特征" : "⚠ 可疑" }
        let webdriver = signals["webdriver"] as? Bool ?? true
        let headless = signals["headless_ua"] as? Bool ?? true
        let plugins = signals["plugins"] as? Int ?? 0
        let vendor = signals["webgl_vendor"] as? String ?? "n/a"
        let cores = signals["hardwareConcurrency"] as? Int ?? 0
        let languages = (signals["languages"] as? [String])?.joined(separator: ", ") ?? "?"
        return """
        浏览器反检测自检：
        - navigator.webdriver = \(webdriver) \(flag(!webdriver))
        - HeadlessChrome UA: \(headless) \(flag(!headless))
        - 插件数: \(plugins) \(flag(plugins > 0))
        - WebGL 厂商: \(vendor) \(flag(!vendor.contains("SwiftShader") && vendor != "n/a"))
        - CPU 核心: \(cores) \(flag(cores > 0))
        - 语言: \(languages)
        综合：\(!webdriver && !headless && plugins > 0 ? "呈现为正常真人 Chrome。" : "存在可疑特征，可能被检测。")
        """
    }

    /// Poll the current screen; drives the live drawer preview.
    func refreshScreenshot() async {
        _ = try? await screenshotPNG()
    }

    private func action(path: String, body: [String: Any]) async throws -> BrowserActionResult {
        let object = try await request(method: "POST", path: path, body: body)
        currentURL = (object["url"] as? String) ?? currentURL
        currentTitle = (object["title"] as? String) ?? currentTitle
        var png: Data?
        if let base64 = object["screenshot"] as? String, let data = Data(base64Encoded: base64) {
            png = data
            latestScreenshot = data
        }
        return BrowserActionResult(url: currentURL, title: currentTitle, screenshotPNG: png)
    }

    @discardableResult
    private func request(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard port != 0 else { throw BrowserError.requestFailed("sidecar not started") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue(token, forHTTPHeaderField: "X-Browser-Token")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw BrowserError.requestFailed(message ?? "HTTP error")
        }
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let error = object["error"] as? String, object["ok"] as? Bool == false {
            throw BrowserError.requestFailed(error)
        }
        return object
    }
}
