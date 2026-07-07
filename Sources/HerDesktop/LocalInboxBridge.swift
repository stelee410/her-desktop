import Foundation
import Network

struct LocalInboxMessage: Codable, Equatable {
    var source: String
    var sender: String
    var text: String
    var url: String
    var receivedAt: String
    var attachmentPaths: [String]

    init(
        source: String = "local-http",
        sender: String = "",
        text: String,
        url: String = "",
        receivedAt: String = "",
        attachmentPaths: [String] = []
    ) {
        self.source = source
        self.sender = sender
        self.text = text
        self.url = url
        self.receivedAt = receivedAt
        self.attachmentPaths = attachmentPaths
    }
}

enum LocalInboxBridgeStatus: String, Codable, Equatable {
    case stopped
    case starting
    case running
    case failed
}

struct LocalInboxBridgeState: Equatable {
    var status: LocalInboxBridgeStatus = .stopped
    var host: String = "127.0.0.1"
    var port: UInt16 = 8766
    var summary: String = "Stopped"

    var endpoint: String {
        "http://\(host):\(port)/inbox"
    }
}

enum LocalInboxBridgeRequestParser {
    enum ParseError: LocalizedError, Equatable {
        case invalidRequest
        case unsupportedMethod(String)
        case unsupportedPath(String)
        case missingBody
        case invalidJSON
        case missingText

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "Invalid HTTP request."
            case .unsupportedMethod(let method):
                return "Unsupported HTTP method: \(method)."
            case .unsupportedPath(let path):
                return "Unsupported inbox bridge path: \(path)."
            case .missingBody:
                return "Missing request body."
            case .invalidJSON:
                return "Request body is not valid JSON."
            case .missingText:
                return "Missing required text field."
            }
        }
    }

    static func parse(_ data: Data) throws -> LocalInboxMessage {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else {
            throw ParseError.invalidRequest
        }
        let header = String(raw[..<headerEnd.lowerBound])
        let body = String(raw[headerEnd.upperBound...])
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ParseError.invalidRequest
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw ParseError.invalidRequest
        }
        let method = parts[0].uppercased()
        guard method == "POST" else {
            throw ParseError.unsupportedMethod(method)
        }
        let path = parts[1]
        guard ["/inbox", "/v1/inbox/capture"].contains(path) else {
            throw ParseError.unsupportedPath(path)
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.missingBody
        }
        guard let bodyData = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        let text = stringValue(object, keys: ["text", "body", "message", "content"])
        guard !text.isEmpty else {
            throw ParseError.missingText
        }
        return LocalInboxMessage(
            source: stringValue(object, keys: ["source", "platform"], fallback: "local-http"),
            sender: stringValue(object, keys: ["sender", "from", "author"]),
            text: text,
            url: stringValue(object, keys: ["url", "link"]),
            receivedAt: stringValue(object, keys: ["received_at", "receivedAt", "timestamp"]),
            attachmentPaths: stringArrayValue(object, keys: ["attachment_paths", "attachments", "files"])
        )
    }

    static func response(status: Int, body: String) -> Data {
        let reason = status == 200 ? "OK" : "Bad Request"
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var data = Data(header.utf8)
        data.append(payload)
        return data
    }

    private static func stringValue(_ object: [String: Any], keys: [String], fallback: String = "") -> String {
        for key in keys {
            guard let raw = object[key] else { continue }
            let text: String
            if let string = raw as? String {
                text = string
            } else {
                text = String(describing: raw)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallback
    }

    private static func stringArrayValue(_ object: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let raw = object[key] else { continue }
            let values: [String]
            if let array = raw as? [String] {
                values = array
            } else if let array = raw as? [Any] {
                values = array.compactMap { item in
                    if let string = item as? String {
                        return string
                    }
                    if let object = item as? [String: Any] {
                        return stringValue(object, keys: ["path", "file", "file_path", "stored_path", "url"])
                    }
                    return String(describing: item)
                }
            } else {
                values = String(describing: raw)
                    .components(separatedBy: .newlines)
            }
            let cleaned = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return []
    }
}

final class LocalInboxBridgeServer: @unchecked Sendable {
    typealias MessageHandler = @Sendable (LocalInboxMessage) async -> Void

    // `listener` is guarded by `lock`: start/stop run on the main actor
    // while the network queue may observe state — the @unchecked Sendable
    // promise has to actually hold.
    private var listener: NWListener?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "HerDesktop.LocalInboxBridge")

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    func start(port: UInt16, onMessage: @escaping MessageHandler) throws {
        stop()
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 8766
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection, onMessage: onMessage)
        }
        listener.start(queue: queue)
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let active = listener
        listener = nil
        lock.unlock()
        active?.cancel()
    }

    private func handle(connection: NWConnection, onMessage: @escaping MessageHandler) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), onMessage: onMessage)
    }

    private func receive(on connection: NWConnection, buffer: Data, onMessage: @escaping MessageHandler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            var next = buffer
            if let data {
                next.append(data)
            }
            if error != nil {
                connection.cancel()
                return
            }
            if isComplete || self?.hasCompleteHTTPRequest(next) == true {
                self?.process(data: next, connection: connection, onMessage: onMessage)
            } else {
                self?.receive(on: connection, buffer: next, onMessage: onMessage)
            }
        }
    }

    private func process(data: Data, connection: NWConnection, onMessage: @escaping MessageHandler) {
        do {
            let message = try LocalInboxBridgeRequestParser.parse(data)
            Task { await onMessage(message) }
            let body = #"{"ok":true}"#
            connection.send(content: LocalInboxBridgeRequestParser.response(status: 200, body: body), completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            let escaped = error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\"")
            let body = #"{"ok":false,"error":"\#(escaped)"}"#
            connection.send(content: LocalInboxBridgeRequestParser.response(status: 400, body: body), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else {
            return false
        }
        let header = String(raw[..<headerEnd.lowerBound])
        let body = String(raw[headerEnd.upperBound...])
        let length = header.components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame else {
                    return nil
                }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0
        return Data(body.utf8).count >= length
    }
}
