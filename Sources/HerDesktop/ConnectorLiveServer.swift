import Foundation
import Network

/// Connector 的 live WebSocket 服务端：对外讲 infiniti-agent live 协议的
/// 最小子集，让现成的桥（infiniti-weixin-bridge 等）不改一行连上来。
///
/// 入站：USER_INPUT{line, attachments[]}、MIC_AUDIO{audioBase64, format}
/// 出站：ASSISTANT_STREAM{fullRaw 累积文本, done}
/// 一次只有一个在途请求（桥自身串行化），多客户端各自独立。
enum ConnectorLiveProtocol {
    struct InboundAttachment: Equatable {
        var name: String
        var mediaType: String
        var kind: String
        var text: String?
    }

    enum Inbound: Equatable {
        case userInput(line: String, attachments: [InboundAttachment])
        case micAudio(format: String)
        case other
    }

    static func parse(_ text: String) -> Inbound? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = root["type"] as? String else {
            return nil
        }
        let payload = root["data"] as? [String: Any] ?? [:]
        switch type {
        case "USER_INPUT":
            let line = payload["line"] as? String ?? ""
            let attachments = (payload["attachments"] as? [[String: Any]] ?? []).map { raw in
                InboundAttachment(
                    name: raw["name"] as? String ?? "附件",
                    mediaType: raw["mediaType"] as? String ?? "",
                    kind: raw["kind"] as? String ?? "document",
                    text: raw["text"] as? String
                )
            }
            return .userInput(line: line, attachments: attachments)
        case "MIC_AUDIO":
            return .micAudio(format: payload["format"] as? String ?? "")
        default:
            return .other
        }
    }

    static func assistantStreamFrame(fullRaw: String, done: Bool) -> String {
        let object: [String: Any] = [
            "type": "ASSISTANT_STREAM",
            "data": ["fullRaw": fullRaw, "done": done]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 附件在 v1 里不入库，折叠成一行文字进上下文。
    static func describeAttachments(_ attachments: [InboundAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        let parts = attachments.map { attachment in
            var piece = "\(attachment.name)（\(attachment.mediaType.isEmpty ? attachment.kind : attachment.mediaType)）"
            if let text = attachment.text, !text.isEmpty {
                piece += "：\(String(text.prefix(400)))"
            }
            return piece
        }
        return "[对方发来附件] " + parts.joined(separator: "；")
    }
}

/// Loopback WebSocket listener。回调在主线程派发；对每条连接串行发帧。
final class ConnectorLiveServer: @unchecked Sendable {
    typealias UserInputHandler = @MainActor (
        _ line: String,
        _ attachments: [ConnectorLiveProtocol.InboundAttachment],
        _ reply: @escaping @Sendable (String, Bool) -> Void
    ) -> Void

    private let queue = DispatchQueue(label: "HerDesktop.ConnectorLiveServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var onUserInput: UserInputHandler?

    private(set) var port: UInt16?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    func start(port fixedPort: UInt16, onUserInput: @escaping UserInputHandler) throws {
        lock.lock()
        guard listener == nil else { lock.unlock(); return }
        self.onUserInput = onUserInput
        lock.unlock()

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: fixedPort) ?? .any
        )
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        lock.lock()
        self.listener = listener
        self.port = fixedPort
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        let open = connections.values
        self.listener = nil
        self.connections = [:]
        self.onUserInput = nil
        lock.unlock()
        listener?.cancel()
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state { self?.drop(connection) }
            if case .cancelled = state { self?.drop(connection) }
        }
        connection.start(queue: queue)
        receiveNext(connection)
    }

    private func drop(_ connection: NWConnection?) {
        guard let connection else { return }
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty,
               let text = String(data: data, encoding: .utf8),
               context?.protocolMetadata(definition: NWProtocolWebSocket.definition) != nil {
                self.handleFrame(text, on: connection)
            }
            self.receiveNext(connection)
        }
    }

    private func handleFrame(_ text: String, on connection: NWConnection) {
        guard let inbound = ConnectorLiveProtocol.parse(text) else { return }
        let send: @Sendable (String, Bool) -> Void = { [weak self, weak connection] fullRaw, done in
            guard let self, let connection else { return }
            self.sendText(
                ConnectorLiveProtocol.assistantStreamFrame(fullRaw: fullRaw, done: done),
                on: connection
            )
        }
        lock.lock()
        let handler = onUserInput
        lock.unlock()
        switch inbound {
        case .userInput(let line, let attachments):
            guard let handler else { return }
            DispatchQueue.main.async {
                handler(line, attachments, send)
            }
        case .micAudio:
            // v1 不做语音转写：礼貌回绝，避免桥等到超时。
            send("我现在还听不了语音消息，发文字给我吧～", true)
        case .other:
            break
        }
    }

    private func sendText(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}
