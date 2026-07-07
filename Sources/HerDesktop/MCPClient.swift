import Foundation

/// Session-aware MCP client. Previously every MCP capability invocation was
/// a bare per-call HTTP POST with no `initialize` handshake and no session —
/// protocol-compliant servers could legitimately reject it.
///
/// One logical session per bridge URL: the MCP lifecycle handshake
/// (`initialize` → `notifications/initialized`) runs once and its outcome is
/// cached. Deliberately tolerant: plain JSON-RPC bridges that don't
/// implement the MCP lifecycle keep working exactly as before — a failed
/// handshake is remembered, not fatal.
///
/// Transport note: HTTP JSON-RPC to loopback bridges only (matching the
/// existing security posture). A stdio transport can slot in behind the same
/// interface later.
actor MCPClient {
    static let shared = MCPClient()

    struct ToolDescriptor: Equatable {
        var name: String
        var description: String
        var inputSchemaJSON: String
    }

    private struct SessionState {
        var handshakeAttempted = false
        var handshakeSucceeded = false
        var protocolVersion: String?
        var tools: [ToolDescriptor]?
    }

    private var sessions: [String: SessionState] = [:]

    /// JSON-RPC call with the session handshake ensured first.
    /// `paramsJSON` is the serialized params value (object or array) — Data
    /// crosses the actor boundary where `Any` cannot.
    /// Returns raw response data and HTTP status.
    func call(
        method: String,
        paramsJSON: Data,
        requestID: String,
        url: URL,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) async throws -> (data: Data, status: Int) {
        await ensureInitialized(url: url, headers: headers, urlSession: urlSession)
        let params = (try? JSONSerialization.jsonObject(with: paramsJSON)) ?? [String: Any]()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params
        ]
        return try await post(body, url: url, headers: headers, urlSession: urlSession)
    }

    /// The server's tool list (`tools/list`), cached per session.
    func tools(
        url: URL,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared,
        forceRefresh: Bool = false
    ) async throws -> [ToolDescriptor] {
        let key = url.absoluteString
        if !forceRefresh, let cached = sessions[key]?.tools {
            return cached
        }
        let (data, _) = try await call(
            method: "tools/list",
            paramsJSON: Data("{}".utf8),
            requestID: "her-tools-list",
            url: url,
            headers: headers,
            urlSession: urlSession
        )
        let parsed = Self.parseTools(data)
        sessions[key, default: SessionState()].tools = parsed
        return parsed
    }

    /// Drop cached session state for a bridge (e.g. after connection errors).
    func reset(url: URL) {
        sessions[url.absoluteString] = nil
    }

    // MARK: - Lifecycle

    /// Perform the MCP `initialize` handshake once per bridge URL. Failure is
    /// recorded but never fatal so pre-MCP JSON-RPC bridges keep working.
    func ensureInitialized(url: URL, headers: [String: String], urlSession: URLSession) async {
        let key = url.absoluteString
        if sessions[key]?.handshakeAttempted == true { return }
        // Mark BEFORE the first await: actors release isolation across
        // suspension, so a reentrant call during the handshake POST would
        // otherwise start a second full handshake (strict MCP servers reject
        // a duplicate initialize).
        sessions[key] = SessionState(handshakeAttempted: true)
        var state = SessionState(handshakeAttempted: true)
        defer { sessions[key] = state }

        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "her-initialize",
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Her Desktop", "version": "1.0"]
            ]
        ]
        guard let (data, status) = try? await post(initialize, url: url, headers: headers, urlSession: urlSession),
              status == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = object["result"] as? [String: Any] else {
            return
        }
        state.handshakeSucceeded = true
        state.protocolVersion = result["protocolVersion"] as? String
        // Best-effort lifecycle notification; servers that ignore it are fine.
        let initialized: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        _ = try? await post(initialized, url: url, headers: headers, urlSession: urlSession)
    }

    // MARK: - Plumbing

    private func post(
        _ body: [String: Any],
        url: URL,
        headers: [String: String],
        urlSession: URLSession
    ) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await urlSession.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func parseTools(_ data: Data) -> [ToolDescriptor] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return []
        }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
            let schemaJSON: String
            if let schema = tool["inputSchema"],
               let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
                schemaJSON = String(data: data, encoding: .utf8) ?? ""
            } else {
                schemaJSON = ""
            }
            return ToolDescriptor(
                name: name,
                description: tool["description"] as? String ?? "",
                inputSchemaJSON: schemaJSON
            )
        }
    }
}
