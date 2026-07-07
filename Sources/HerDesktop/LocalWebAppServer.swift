import Foundation
import Network

struct WebAppHTTPRequest: Equatable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> WebAppHTTPRequest? {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEndRange.lowerBound], encoding: .utf8) else { return nil }
        let body = Data(data[headerEndRange.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }

        let target = parts[1]
        let pathAndQuery = target.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for item in pathAndQuery[1].split(separator: "&") {
                let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = kv.first?.removingPercentEncoding else { continue }
                query[key] = kv.count == 2 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            }
        }
        return WebAppHTTPRequest(
            method: parts[0].uppercased(),
            path: pathAndQuery.first ?? "/",
            query: query,
            headers: headers,
            body: body
        )
    }

    /// True once the buffered data contains the full request per Content-Length.
    static func isComplete(_ data: Data) -> Bool {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEndRange.lowerBound], encoding: .utf8) else {
            return false
        }
        let length = head.components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2, pair[0].caseInsensitiveCompare("Content-Length") == .orderedSame else {
                    return nil
                }
                return Int(pair[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0
        return data[headerEndRange.upperBound...].count >= length
    }
}

struct WebAppHTTPResponse: Equatable {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ status: Int, _ object: [String: JSONValue]) -> WebAppHTTPResponse {
        let data = (try? JSONEncoder().encode(object)) ?? Data("{}".utf8)
        return WebAppHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func jsonError(_ status: Int, _ message: String) -> WebAppHTTPResponse {
        json(status, ["ok": .bool(false), "error": .string(message)])
    }

    var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        // same-origin referrers only: page URLs carry the app token in the
        // query — same-origin fetches keep sending it (the Referer auth path
        // relies on that), but it never flows to a third-party origin.
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Referrer-Policy: same-origin\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

/// Routes web app HTTP requests: static files from each app's `www/`
/// directory, a token-protected SQLite query API, and a token-protected
/// reverse proxy to the app's backend process. Runs off the main actor
/// on the server queue.
struct LocalWebAppRouter {
    var store: WebAppStore
    var tokenForApp: (String) -> String?
    var processManager: WebAppProcessManager?

    func route(_ request: WebAppHTTPRequest) async -> WebAppHTTPResponse {
        // Reject non-loopback Host headers (DNS rebinding: an attacker page
        // whose domain resolves to 127.0.0.1 arrives with its own Host).
        guard SecurityPrimitives.isLoopbackHost(request.headers["host"]) else {
            return .jsonError(403, "Forbidden host.")
        }
        let segments = request.path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "apps" else {
            return .jsonError(404, "Unknown path.")
        }
        let appID = segments[1]
        guard let manifest = store.manifest(id: appID) else {
            return .jsonError(404, "Unknown web app: \(appID)")
        }
        let remainder = segments.dropFirst(2).joined(separator: "/")

        // Built-in SQLite endpoint.
        if remainder == "api/query" {
            return queryAPI(request: request, appID: appID)
        }
        let isBackendPrefixed = remainder == "backend" || remainder.hasPrefix("backend/")
        // A real static file wins (index.html, css, js…).
        if request.method == "GET", !isBackendPrefixed,
           let fileURL = store.staticFileURL(appID: appID, requestPath: remainder),
           let data = try? Data(contentsOf: fileURL) {
            let contentType = Self.contentType(for: fileURL.pathExtension)
            // Inject a fetch shim into served HTML so the app's own relative
            // requests (api/query, api/quote, backend/…) carry the token
            // automatically — the model never has to thread it.
            let body = contentType.hasPrefix("text/html")
                ? Self.htmlWithTokenShim(data, token: tokenForApp(appID) ?? "")
                : data
            return WebAppHTTPResponse(status: 200, contentType: contentType, body: body)
        }
        // Otherwise, if the app has a backend, proxy to it. This is how a
        // page's fetch reaches the backend — whether it uses the explicit
        // `backend/…` prefix or just calls its own route like `api/quote`.
        if manifest.runtime != nil {
            let backendPath = isBackendPrefixed
                ? String(remainder.dropFirst("backend".count).drop(while: { $0 == "/" }))
                : remainder
            return await proxyBackend(request: request, manifest: manifest, backendPath: backendPath)
        }
        guard request.method == "GET" else {
            return .jsonError(405, "Only GET is supported for static files.")
        }
        return .jsonError(404, "File not found.")
    }

    private func validToken(_ request: WebAppHTTPRequest, appID: String) -> Bool {
        guard let expected = tokenForApp(appID), !expected.isEmpty else { return false }
        // Accept the token from the query, a header, or the referring page's
        // URL — the Referer path is load-bearing: it authenticates the app
        // page's own fetches that the injected shim doesn't catch. Honoring
        // Referer adds no attack surface (a forger would already need the
        // token); the leak vector — token flowing to third-party origins via
        // referrers — is closed by the `Referrer-Policy: same-origin`
        // response header instead. All comparisons are constant-time.
        if SecurityPrimitives.constantTimeEquals(request.query["token"] ?? "", expected) { return true }
        if SecurityPrimitives.constantTimeEquals(request.headers["x-webapp-token"] ?? "", expected) { return true }
        if let referer = request.headers["referer"],
           let comps = URLComponents(string: referer),
           let refererToken = comps.queryItems?.first(where: { $0.name == "token" })?.value,
           SecurityPrimitives.constantTimeEquals(refererToken, expected) {
            return true
        }
        return false
    }

    private func proxyBackend(
        request: WebAppHTTPRequest,
        manifest: WebAppManifest,
        backendPath: String
    ) async -> WebAppHTTPResponse {
        guard validToken(request, appID: manifest.id) else {
            return .jsonError(401, "Missing or invalid web app token.")
        }
        guard let processManager, manifest.runtime != nil else {
            return .jsonError(404, "This web app has no backend runtime.")
        }
        let port: UInt16
        do {
            let store = self.store
            port = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try processManager.ensureRunning(app: manifest, store: store))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            return .jsonError(502, error.localizedDescription)
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/" + backendPath
        let passthroughQuery = request.query.filter { $0.key != "token" }
        if !passthroughQuery.isEmpty {
            components.queryItems = passthroughQuery.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            return .jsonError(400, "Invalid backend path.")
        }
        var forward = URLRequest(url: url)
        forward.httpMethod = request.method
        forward.timeoutInterval = 30
        if !request.body.isEmpty {
            forward.httpBody = request.body
        }
        if let contentType = request.headers["content-type"] {
            forward.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: forward)
            let http = response as? HTTPURLResponse
            return WebAppHTTPResponse(
                status: http?.statusCode ?? 200,
                contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                body: data
            )
        } catch {
            return .jsonError(502, "Backend request failed: \(error.localizedDescription)")
        }
    }

    private func queryAPI(request: WebAppHTTPRequest, appID: String) -> WebAppHTTPResponse {
        guard request.method == "POST" else {
            return .jsonError(405, "Use POST for /api/query.")
        }
        guard validToken(request, appID: appID) else {
            return .jsonError(401, "Missing or invalid web app token.")
        }
        guard let payload = try? JSONDecoder().decode([String: JSONValue].self, from: request.body),
              case .string(let sql)? = payload["sql"], !sql.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .jsonError(400, "Body must be JSON with a sql field.")
        }
        var params: [JSONValue] = []
        if case .array(let values)? = payload["params"] {
            params = values
        }
        do {
            // Deliberately read-write: the page IS the app's own UI operating
            // its own single-app data.db (generated apps CREATE TABLE and
            // INSERT through here). The token is the write authorization; the
            // blast radius is that one app's database. The *model*-facing
            // read path (webapp.query) stays requireReadOnly — that split is
            // about approval-gating the agent, not the user's own UI.
            let result = try WebAppDatabase.execute(
                sql: sql,
                params: params,
                databaseURL: store.databaseURL(id: appID)
            )
            return .json(200, [
                "ok": .bool(true),
                "columns": .array(result.columns.map { .string($0) }),
                "rows": .array(result.rows.map { .array($0) }),
                "rows_changed": .number(Double(result.rowsChanged)),
                "last_insert_row_id": .number(Double(result.lastInsertRowID))
            ])
        } catch {
            return .jsonError(400, error.localizedDescription)
        }
    }

    /// Prepend a small script that appends `token=` to the app's own relative
    /// fetches, so backend/SQLite calls authenticate without the page code
    /// having to include the token.
    static func htmlWithTokenShim(_ data: Data, token: String) -> Data {
        guard let html = String(data: data, encoding: .utf8), !token.isEmpty else { return data }
        let shim = """
        <script>(function(){var t=\"\(token)\";var f=window.fetch;window.fetch=function(u,o){try{if(typeof u===\"string\"&&!/^[a-z]+:\\/\\//i.test(u)){u+=(u.indexOf(\"?\")>=0?\"&\":\"?\")+\"token=\"+encodeURIComponent(t);}}catch(e){}return f.call(this,u,o);};})();</script>
        """
        if let range = html.range(of: "<head>", options: .caseInsensitive) {
            return Data(html.replacingCharacters(in: range, with: "<head>" + shim).utf8)
        }
        return Data((shim + html).utf8)
    }

    static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

/// Loopback-only HTTP server hosting installed web apps. Binds
/// 127.0.0.1 on an ephemeral port; every app gets a per-launch random
/// token that gates its SQLite query API.
final class LocalWebAppServer: @unchecked Sendable {
    private var listener: NWListener?
    private var router: LocalWebAppRouter?
    private let queue = DispatchQueue(label: "HerDesktop.LocalWebAppServer")
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    private(set) var port: UInt16?

    var isRunning: Bool {
        listener != nil
    }

    func start(store: WebAppStore, processManager: WebAppProcessManager? = nil) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let router = LocalWebAppRouter(
            store: store,
            tokenForApp: { [weak self] appID in
                self?.token(for: appID)
            },
            processManager: processManager
        )
        self.router = router
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        self.listener = listener
        self.port = listener.port?.rawValue
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// Stable per-launch token for one app; tokens are never persisted.
    func token(for appID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = tokens[appID] {
            return existing
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokens[appID] = token
        return token
    }

    func url(for appID: String, page: String = "") -> URL? {
        guard let port else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/apps/\(appID)/" + page
        components.queryItems = [URLQueryItem(name: "token", value: token(for: appID))]
        return components.url
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data {
                next.append(data)
            }
            if error != nil || next.count > 8_388_608 {
                connection.cancel()
                return
            }
            if WebAppHTTPRequest.isComplete(next) || isComplete {
                self.respond(to: next, on: connection)
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func respond(to data: Data, on connection: NWConnection) {
        guard let request = WebAppHTTPRequest.parse(data), let router else {
            let response = WebAppHTTPResponse.jsonError(400, "Invalid HTTP request.")
            connection.send(content: response.serialized, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        Task {
            let response = await router.route(request)
            connection.send(content: response.serialized, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
