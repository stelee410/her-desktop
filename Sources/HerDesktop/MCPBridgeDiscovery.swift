import Foundation

struct MCPDiscoveredTool: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var description: String
    var inputSchemaSummary: String
    var rawInputSchema: String
}

struct MCPBridgeDiscoveryResponse: Equatable {
    var url: URL
    var statusCode: Int
    var tools: [MCPDiscoveredTool]
    var rawBody: String

    var displayContent: String {
        let toolLines = tools.isEmpty
            ? "- No tools returned."
            : tools.map { tool in
                let description = tool.description.isEmpty ? "No description" : tool.description
                let inputs = tool.inputSchemaSummary.isEmpty ? "inputs: unknown" : "inputs: \(tool.inputSchemaSummary)"
                return "- \(tool.name): \(description)\n  \(inputs)"
            }.joined(separator: "\n")
        return """
        POST \(url.absoluteString)
        method: tools/list
        status: \(statusCode)
        tool_count: \(tools.count)

        Tools:
        \(toolLines)
        """
    }
}

enum MCPBridgeDiscoveryError: LocalizedError, Equatable {
    case invalidURL(String)
    case blockedURL(String)
    case jsonRPCError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "Invalid MCP bridge URL: \(raw)"
        case .blockedURL(let raw):
            return "MCP discovery only supports local http bridge URLs on localhost, 127.0.0.1, or ::1: \(raw)"
        case .jsonRPCError(let message):
            return "MCP bridge returned JSON-RPC error: \(message)"
        case .invalidResponse:
            return "MCP bridge returned an invalid tools/list response."
        }
    }
}

struct MCPBridgeDiscoveryClient {
    var urlSession: URLSession = .shared

    func discover(rawURL: String, requestID: String = "mcp_tools_list") async throws -> MCPBridgeDiscoveryResponse {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw MCPBridgeDiscoveryError.invalidURL(rawURL)
        }
        guard Self.isAllowedBridgeURL(url) else {
            throw MCPBridgeDiscoveryError.blockedURL(rawURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "tools/list",
            "params": [:]
        ], options: [.sortedKeys])

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawBody = String(data: Data(data.prefix(12_000)), encoding: .utf8) ?? "\(data.count) bytes"
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw MCPBridgeDiscoveryError.invalidResponse
        }
        if let error = dictionary["error"] {
            throw MCPBridgeDiscoveryError.jsonRPCError(Self.renderJSON(error))
        }

        let tools = Self.parseTools(from: dictionary)
        return MCPBridgeDiscoveryResponse(
            url: url,
            statusCode: status,
            tools: tools,
            rawBody: rawBody
        )
    }

    static func isAllowedBridgeURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func parseTools(from dictionary: [String: Any]) -> [MCPDiscoveredTool] {
        let result = dictionary["result"] as? [String: Any]
        let rawTools = (result?["tools"] as? [[String: Any]])
            ?? (dictionary["tools"] as? [[String: Any]])
            ?? []
        return rawTools.compactMap { raw in
            guard let name = clean(raw["name"]), !name.isEmpty else { return nil }
            let inputSchema = raw["inputSchema"] ?? raw["input_schema"] ?? raw["schema"]
            return MCPDiscoveredTool(
                name: name,
                description: clean(raw["description"]) ?? "",
                inputSchemaSummary: inputSchemaSummary(inputSchema),
                rawInputSchema: renderJSON(inputSchema ?? [:])
            )
        }
    }

    private static func inputSchemaSummary(_ raw: Any?) -> String {
        guard let schema = raw as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              !properties.isEmpty else {
            return ""
        }
        let required = schema["required"] as? [String] ?? []
        let ordered = required + properties.keys.sorted().filter { !required.contains($0) }
        return ordered.compactMap { name in
            guard let field = properties[name] as? [String: Any] else { return name }
            let type = clean(field["type"]) ?? "value"
            return required.contains(name) ? "\(name)*:\(type)" : "\(name):\(type)"
        }.joined(separator: ", ")
    }

    private static func clean(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(describing: value)
    }

    private static func renderJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return String(text.prefix(4_000))
    }
}
