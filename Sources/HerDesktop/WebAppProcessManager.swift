import Foundation
import Network

/// Runs and supervises web app backend processes (node / python).
/// Backends are launched on demand, bound to 127.0.0.1 on an assigned
/// port, logged to `.her/logs/webapp-<id>.log`, and killed when the app
/// is stopped, removed, updated, or Her Desktop exits.
final class WebAppProcessManager: @unchecked Sendable {
    enum ProcessError: LocalizedError {
        case runtimeNotInstalled(String)
        case backendDidNotBecomeReady(String)
        case entryMissing(String)

        var errorDescription: String? {
            switch self {
            case .runtimeNotInstalled(let type):
                return "The \(type) runtime was not found on this Mac. Install \(type == "node" ? "Node.js (e.g. brew install node)" : "Python 3") and try again."
            case .backendDidNotBecomeReady(let id):
                return "The backend process for \(id) did not start listening in time. Check .her/logs/webapp-\(id).log."
            case .entryMissing(let entry):
                return "Backend entry script is missing: \(entry)"
            }
        }
    }

    private struct Backend {
        var process: Process
        var port: UInt16
        var logHandle: FileHandle?
    }

    private let cwd: String
    private let lock = NSLock()
    private var backends: [String: Backend] = [:]

    init(cwd: String = FileManager.default.currentDirectoryPath) {
        self.cwd = cwd
    }

    deinit {
        stopAll()
    }

    func backendPort(appID: String) -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        guard let backend = backends[appID], backend.process.isRunning else { return nil }
        return backend.port
    }

    /// Starts the app's backend if it isn't already running and waits until
    /// it accepts TCP connections. Returns the loopback port.
    func ensureRunning(app: WebAppManifest, store: WebAppStore) throws -> UInt16 {
        if let port = backendPort(appID: app.id) {
            return port
        }
        guard let runtime = app.runtime else {
            throw ProcessError.entryMissing("no runtime declared")
        }
        let entryURL = store.appDirectory(id: app.id).appendingPathComponent(runtime.entry)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw ProcessError.entryMissing(runtime.entry)
        }
        let executable = try Self.resolveExecutable(type: runtime.type)
        let port = Self.findFreePort()

        let logURL = HerWorkspacePaths.logsDirectory(cwd: cwd)
            .appendingPathComponent("webapp-\(app.id).log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [entryURL.path]
        process.currentDirectoryURL = store.appDirectory(id: app.id)
        // Minimal allowlisted environment — NEVER the inherited one. Backends
        // run LLM-generated code; the parent environment can carry API keys
        // (HER_AGENT_LLM_API_KEY, OPENAI_API_KEY, AWS_*, …) that generated
        // code could read and exfiltrate.
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "TZ"] {
            environment[key] = inherited[key]
        }
        environment["PORT"] = String(port)
        environment["HER_WEBAPP_ID"] = app.id
        environment["HER_WEBAPP_DIR"] = store.appDirectory(id: app.id).path
        environment["HER_WEBAPP_DB"] = store.databaseURL(id: app.id).path
        process.environment = environment
        if let logHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        try process.run()

        lock.lock()
        backends[app.id] = Backend(process: process, port: port, logHandle: logHandle)
        lock.unlock()

        guard Self.waitForListen(port: port, process: process, timeout: 10) else {
            stop(appID: app.id)
            throw ProcessError.backendDidNotBecomeReady(app.id)
        }
        return port
    }

    func stop(appID: String) {
        lock.lock()
        let backend = backends.removeValue(forKey: appID)
        lock.unlock()
        guard let backend else { return }
        if backend.process.isRunning {
            backend.process.terminate()
        }
        try? backend.logHandle?.close()
    }

    func stopAll() {
        lock.lock()
        let all = backends
        backends = [:]
        lock.unlock()
        for backend in all.values {
            if backend.process.isRunning {
                backend.process.terminate()
            }
            try? backend.logHandle?.close()
        }
    }

    /// GUI apps launch with a minimal PATH, so probe the common install
    /// locations directly before falling back to /usr/bin/env lookup.
    static func resolveExecutable(type: String) throws -> String {
        let candidates: [String]
        switch type {
        case "node":
            candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        case "python":
            candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        default:
            throw ProcessError.runtimeNotInstalled(type)
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ProcessError.runtimeNotInstalled(type)
    }

    /// Asks the kernel for an ephemeral port by binding port 0 on loopback.
    static func findFreePort() -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return UInt16.random(in: 20_000...59_999) }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return UInt16.random(in: 20_000...59_999) }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { return UInt16.random(in: 20_000...59_999) }
        return UInt16(bigEndian: assigned.sin_port)
    }

    private static func waitForListen(port: UInt16, process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard process.isRunning else { return false }
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { return false }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(socketFD)
            if connected == 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }
}
