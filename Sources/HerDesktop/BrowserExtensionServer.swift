import Foundation
import Network

/// Loopback bridge between Her and a Chrome extension running in the user's
/// everyday Chrome. Her enqueues a command; the extension long-polls
/// `/ext/next`, executes it in the active tab, and POSTs the result to
/// `/ext/result`. Because the command runs inside the user's own browser,
/// there is no automation driver at all — the strongest anti-detection
/// posture — and the real logged-in profile is used directly.
final class BrowserExtensionServer: @unchecked Sendable {
    struct Command {
        var id: String
        var action: String
        var paramsJSON: Data
    }

    private let token: String
    private let queue = DispatchQueue(label: "HerDesktop.BrowserExtensionServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var pending: [Command] = []
    private var waiters: [String: CheckedContinuation<Data, Error>] = [:]
    private var connectedAt: Date?
    private var counter = 0
    private var version = ""

    private(set) var port: UInt16?

    init(token: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) {
        self.token = token
    }

    var sharedToken: String { token }

    var isExtensionConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let connectedAt else { return false }
        return Date().timeIntervalSince(connectedAt) < 10
    }

    var extensionVersion: String {
        lock.lock(); defer { lock.unlock() }
        return version
    }

    var isRunning: Bool { listener != nil }

    func start(port fixedPort: UInt16 = 8799) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: fixedPort) ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        self.listener = listener
        self.port = listener.port?.rawValue
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        lock.lock()
        let pendingWaiters = waiters
        waiters = [:]
        pending = []
        lock.unlock()
        for waiter in pendingWaiters.values {
            waiter.resume(throwing: CancellationError())
        }
    }

    /// Queue a command (params as JSON) and await the extension's result
    /// (also JSON). The continuation resumes exactly once — via /ext/result
    /// or a timeout — because whichever fires first removes the waiter under
    /// the lock, and the loser finds nothing to resume.
    func enqueue(action: String, paramsJSON: Data, timeout: TimeInterval = 45) async throws -> Data {
        let id: String = {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            return "cmd-\(counter)"
        }()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters[id] = continuation
            pending.append(Command(id: id, action: action, paramsJSON: paramsJSON))
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expireWaiter(id)
            }
        }
    }

    /// Resume a still-pending waiter with a timeout error. Synchronous so the
    /// NSLock is used outside any async context.
    private func expireWaiter(_ id: String) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        lock.unlock()
        waiter?.resume(throwing: BridgeError.timeout)
    }

    enum BridgeError: LocalizedError {
        case timeout
        var errorDescription: String? { "The Chrome extension did not respond in time. Is it installed and is a tab open?" }
    }

    // MARK: - Request handling (pure; also used directly by tests)

    struct Response {
        var status: Int
        var json: [String: Any]
    }

    func handle(method: String, path: String, query: [String: String], body: [String: Any]) -> Response {
        let provided = query["token"] ?? (body["token"] as? String) ?? ""
        guard provided == token else {
            return Response(status: 401, json: ["ok": false, "error": "invalid token"])
        }
        switch (method, path) {
        case ("POST", "/ext/hello"):
            lock.lock(); connectedAt = Date(); lock.unlock()
            return Response(status: 200, json: ["ok": true])
        case ("GET", "/ext/next"):
            lock.lock()
            connectedAt = Date()
            if let v = query["v"], !v.isEmpty { version = v }
            let next = pending.isEmpty ? nil : pending.removeFirst()
            lock.unlock()
            if let next {
                let params = (try? JSONSerialization.jsonObject(with: next.paramsJSON)) ?? [:]
                return Response(status: 200, json: ["ok": true, "command": [
                    "id": next.id, "action": next.action, "params": params
                ]])
            }
            return Response(status: 200, json: ["ok": true, "command": NSNull()])
        case ("POST", "/ext/result"):
            guard let id = body["id"] as? String else {
                return Response(status: 400, json: ["ok": false, "error": "missing id"])
            }
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            connectedAt = Date()
            lock.unlock()
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
            waiter?.resume(returning: data)
            return Response(status: 200, json: ["ok": true])
        default:
            return Response(status: 404, json: ["ok": false, "error": "unknown path"])
        }
    }

    // MARK: - Networking

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            if error != nil { connection.cancel(); return }
            if Self.hasFullRequest(next) || isComplete {
                self.respond(next, on: connection)
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    private func respond(_ data: Data, on connection: NWConnection) {
        let (method, path, query, body) = Self.parse(data)
        let response = handle(method: method, path: path, query: query, body: body)
        let payload = (try? JSONSerialization.data(withJSONObject: response.json)) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: application/json\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Headers: *\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func hasFullRequest(_ data: Data) -> Bool {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return false }
        let length = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        return data[range.upperBound...].count >= length
    }

    static func parse(_ data: Data) -> (String, String, [String: String], [String: Any]) {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8),
              let requestLine = head.components(separatedBy: "\r\n").first else {
            return ("", "", [:], [:])
        }
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? ""
        let target = parts.count > 1 ? parts[1] : "/"
        let split = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = split.first ?? "/"
        var query: [String: String] = [:]
        if split.count == 2 {
            for pair in split[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if let k = kv.first?.removingPercentEncoding {
                    query[k] = kv.count == 2 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
                }
            }
        }
        let bodyData = Data(data[range.upperBound...])
        let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        return (method, path, query, body ?? [:])
    }
}
