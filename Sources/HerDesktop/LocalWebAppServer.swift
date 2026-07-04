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
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

/// Routes web app HTTP requests: static files from each app's `www/`
/// directory and a token-protected SQLite query API. Runs off the main
/// actor on the server queue.
struct LocalWebAppRouter {
    var store: WebAppStore
    var tokenForApp: (String) -> String?

    func route(_ request: WebAppHTTPRequest) -> WebAppHTTPResponse {
        let segments = request.path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "apps" else {
            return .jsonError(404, "Unknown path.")
        }
        let appID = segments[1]
        guard store.manifest(id: appID) != nil else {
            return .jsonError(404, "Unknown web app: \(appID)")
        }
        let remainder = segments.dropFirst(2).joined(separator: "/")

        if remainder == "api/query" {
            return queryAPI(request: request, appID: appID)
        }
        guard request.method == "GET" else {
            return .jsonError(405, "Only GET is supported for static files.")
        }
        guard let fileURL = store.staticFileURL(appID: appID, requestPath: remainder),
              let data = try? Data(contentsOf: fileURL) else {
            return .jsonError(404, "File not found.")
        }
        return WebAppHTTPResponse(
            status: 200,
            contentType: Self.contentType(for: fileURL.pathExtension),
            body: data
        )
    }

    private func queryAPI(request: WebAppHTTPRequest, appID: String) -> WebAppHTTPResponse {
        guard request.method == "POST" else {
            return .jsonError(405, "Use POST for /api/query.")
        }
        let provided = request.headers["x-webapp-token"] ?? request.query["token"] ?? ""
        guard let expected = tokenForApp(appID), !expected.isEmpty, provided == expected else {
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

    func start(store: WebAppStore) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let router = LocalWebAppRouter(store: store, tokenForApp: { [weak self] appID in
            self?.token(for: appID)
        })
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

    func url(for appID: String) -> URL? {
        guard let port else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/apps/\(appID)/"
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
        let response: WebAppHTTPResponse
        if let request = WebAppHTTPRequest.parse(data), let router {
            response = router.route(request)
        } else {
            response = .jsonError(400, "Invalid HTTP request.")
        }
        connection.send(content: response.serialized, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
