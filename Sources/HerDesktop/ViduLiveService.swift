import AppKit
import Foundation

/// Vidu-S1 实时数字人通话的 REST + WebSocket 信令层。音视频流本身走
/// 阿里云 RTC（由通话页里的 ARTC Web SDK 负责），这里只管：创建会话、
/// conn_init 握手（video 模式必现 NOT_READY，需指数退避重连）、保活、
/// 挂断与服务端强制断开。协议见 docs/video-call-vidu-s1.md。

struct ViduRTCCredentials: Equatable {
    var appID: String
    var channelID: String
    var userID: String
    var token: String
}

struct ViduLiveInfo: Equatable {
    var id: String
    var status: String
    var liveDurationSeconds: Int
    var callMode: String
}

enum ViduSignal {
    struct CreateLiveResult: Equatable {
        var live: ViduLiveInfo
        var rtc: ViduRTCCredentials
    }

    enum ServerEvent: Equatable {
        case connInitAck(success: Bool, errorCode: String?)
        case hangup(reason: String)
        case other
    }

    /// 网关要求 "Token vda_xxx"；用户可能把前缀一起粘进来。
    static func authorizationHeader(apiKey: String) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("token ") ? trimmed : "Token \(trimmed)"
    }

    static func createLiveBody(
        callMode: String,
        persona: String,
        imageURI: String,
        name: String,
        voice: String
    ) throws -> Data {
        var avatar: [String: Any] = [
            "persona": persona,
            "image_uri": imageURI
        ]
        if !name.isEmpty { avatar["name"] = name }
        if !voice.isEmpty { avatar["voice"] = voice }
        let payload: [String: Any] = [
            "call_mode": callMode,
            "avatar": avatar
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func parseCreateLiveResponse(_ data: Data) -> CreateLiveResult? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let live = root["live"] as? [String: Any],
              let rtc = root["rtc"] as? [String: Any],
              let liveID = stringValue(live["id"]), !liveID.isEmpty,
              let token = stringValue(rtc["token"]), !token.isEmpty else {
            return nil
        }
        return CreateLiveResult(
            live: ViduLiveInfo(
                id: liveID,
                status: stringValue(live["status"]) ?? "waiting",
                liveDurationSeconds: intValue(live["live_duration"]) ?? 600,
                callMode: stringValue(live["call_mode"]) ?? "video"
            ),
            rtc: ViduRTCCredentials(
                appID: stringValue(rtc["app_id"]) ?? "",
                channelID: stringValue(rtc["channel_id"]) ?? "",
                userID: stringValue(rtc["user_id"]) ?? "",
                token: token
            )
        )
    }

    /// 服务端错误体常见形态 {"message": "..."} / {"error": "..."}。
    static func errorMessage(from data: Data, status: Int) -> String {
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["message", "error", "detail"] {
                if let text = stringValue(root[key]), !text.isEmpty { return text }
            }
        }
        return "HTTP \(status)"
    }

    static func connInitMessage(liveID: String, seqID: Int) -> String {
        encode([
            "type": 1,
            "live_id": liveID,
            "seq_id": seqID,
            "payload": ["conn_init": ["version": 1]]
        ])
    }

    static func hangupMessage(liveID: String, seqID: Int) -> String {
        encode([
            "type": 5,
            "live_id": liveID,
            "seq_id": seqID,
            "payload": ["hangup": ["hangup_reason": "user_end"]]
        ])
    }

    static func textMessage(content: String) -> String {
        encode([
            "type": 99,
            "payload": ["text_msg": ["content": content]]
        ])
    }

    static func parseServerEvent(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = intValue(root["type"]) else {
            return nil
        }
        let payload = root["payload"] as? [String: Any] ?? [:]
        switch type {
        case 2:
            guard let ack = payload["conn_init_ack"] as? [String: Any] else { return .other }
            let success = (ack["success"] as? Bool) ?? false
            return .connInitAck(success: success, errorCode: stringValue(ack["error_code"]))
        case 6:
            let hangup = payload["hangup"] as? [String: Any]
            return .hangup(reason: stringValue(hangup?["hangup_reason"]) ?? "unknown")
        default:
            return .other
        }
    }

    static func hangupReasonDescription(_ reason: String) -> String {
        switch reason {
        case "user_end": return "通话已结束"
        case "timeout": return "已到本次通话的时长上限"
        case "credit_insufficient": return "Vidu 积分不足，通话被结束"
        case "audit_violation": return "内容触发风控，通话被结束"
        default: return "通话已结束（\(reason)）"
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// 把本地图片文件编码成 Vidu 接受的 `data:image/…;base64,` URI。
/// Vidu 限制 base64 解码后 < 20MB；超限时先尝试 JPEG 重编码压一轮。
enum ViduAvatarImageEncoder {
    static let maxDecodedBytes = 20 * 1024 * 1024

    enum EncodeError: LocalizedError {
        case unsupportedFormat(String)
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "不支持的图片格式 .\(ext)（支持 PNG/JPG/JPEG/WEBP）"
            case .tooLarge:
                return "图片压缩后仍超过 20MB，请换一张小一点的图"
            case .unreadable:
                return "读不出这张图片，请换一张试试"
            }
        }
    }

    static func mimeType(forPathExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    static func dataURI(contentsOf url: URL) throws -> String {
        guard let mime = mimeType(forPathExtension: url.pathExtension) else {
            throw EncodeError.unsupportedFormat(url.pathExtension)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw EncodeError.unreadable
        }
        return try dataURI(data: data, mimeType: mime)
    }

    static func dataURI(data: Data, mimeType: String) throws -> String {
        if data.count < maxDecodedBytes {
            return "data:\(mimeType);base64,\(data.base64EncodedString())"
        }
        // 超限：用 JPEG 重编码换体积（头像场景画质损失可接受）。
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              jpeg.count < maxDecodedBytes else {
            throw EncodeError.tooLarge
        }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }
}

/// 一次视频通话的状态机。生命周期 = 一次 Vidu live 会话；挂断即废弃。
@MainActor
final class ViduCallModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case creating
        /// RTC 凭证已就绪（WebView 可入会），等数字人 conn_init_ack。
        case waitingAgent(attempt: Int)
        case live
        case ended(message: String)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rtc: ViduRTCCredentials?
    @Published private(set) var live: ViduLiveInfo?
    @Published private(set) var liveStartedAt: Date?

    private let apiKey: String
    private let host: String
    let callMode: String

    private var socket: URLSessionWebSocketTask?
    private var seqID = 0
    private var connectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private static let maxConnInitAttempts = 12

    init(apiKey: String, host: String, callMode: String) {
        self.apiKey = apiKey
        self.host = host
        self.callMode = callMode == "audio" ? "audio" : "video"
    }

    var isActive: Bool {
        switch phase {
        case .creating, .waitingAgent, .live: return true
        case .idle, .ended, .failed: return false
        }
    }

    func start(persona: String, imageURI: String, name: String, voice: String) {
        guard case .idle = phase else { return }
        phase = .creating
        connectTask = Task { [weak self] in
            await self?.run(persona: persona, imageURI: imageURI, name: name, voice: voice)
        }
    }

    func hangUp() {
        let message = ViduSignal.hangupReasonDescription("user_end")
        if let socket, let live {
            seqID += 1
            socket.send(.string(ViduSignal.hangupMessage(liveID: live.id, seqID: seqID))) { _ in }
        }
        finish(.ended(message: message))
    }

    private func run(persona: String, imageURI: String, name: String, voice: String) async {
        let created: ViduSignal.CreateLiveResult
        do {
            created = try await createLive(persona: persona, imageURI: imageURI, name: name, voice: voice)
        } catch {
            finish(.failed(message: "创建数字人会话失败：\(error.localizedDescription)"))
            return
        }
        guard !Task.isCancelled else { return }
        live = created.live
        rtc = created.rtc

        // conn_init 握手；video 模式在数字人就绪前会一直回 NOT_READY。
        var attempt = 0
        while attempt < Self.maxConnInitAttempts, !Task.isCancelled {
            attempt += 1
            phase = .waitingAgent(attempt: attempt)
            switch await performConnInit(liveID: created.live.id) {
            case .ready:
                liveStartedAt = Date()
                phase = .live
                startHeartbeat()
                await listenUntilClosed()
                return
            case .notReady:
                closeSocket()
                let delay = min(8.0, pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            case .fatal(let message):
                finish(.failed(message: message))
                return
            }
        }
        if !Task.isCancelled {
            finish(.failed(message: "数字人一直未就绪，请稍后重试"))
        }
    }

    private enum ConnInitOutcome {
        case ready
        case notReady
        case fatal(String)
    }

    private func performConnInit(liveID: String) async -> ConnInitOutcome {
        guard let url = URL(string: "wss://\(host)/live/ws/live/connect?live_id=\(liveID)") else {
            return .fatal("Vidu host 配置无效：\(host)")
        }
        var request = URLRequest(url: url)
        request.setValue(ViduSignal.authorizationHeader(apiKey: apiKey), forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        seqID += 1
        do {
            try await socket.send(.string(ViduSignal.connInitMessage(liveID: liveID, seqID: seqID)))
        } catch {
            return .notReady
        }
        // 等 ack；期间的其他消息（心跳等）直接跳过。
        do {
            while true {
                let event = ViduSignal.parseServerEvent(try await receiveText(socket))
                switch event {
                case .connInitAck(true, _):
                    return .ready
                case .connInitAck(false, let code) where code == "NOT_READY":
                    return .notReady
                case .connInitAck(false, let code):
                    return .fatal("数字人初始化失败（\(code ?? "unknown")），请重新发起通话")
                case .hangup(let reason):
                    return .fatal(ViduSignal.hangupReasonDescription(reason))
                case .other, .none:
                    continue
                }
            }
        } catch {
            return .notReady
        }
    }

    /// 通话中持续收消息：处理服务端挂断，连接异常断开时兜底结束。
    private func listenUntilClosed() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let event = ViduSignal.parseServerEvent(try await receiveText(socket))
                if case .hangup(let reason) = event {
                    finish(.ended(message: ViduSignal.hangupReasonDescription(reason)))
                    return
                }
            }
        } catch {
            if case .live = phase {
                finish(.ended(message: "连接中断，通话已结束"))
            }
        }
    }

    private func receiveText(_ socket: URLSessionWebSocketTask) async throws -> String {
        switch try await socket.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    /// 服务端 15 秒无消息判死连接；URLSession 会自动回协议层 pong，
    /// 这里再主动 ping 兜底（也覆盖中间层不透传 ping 的情况）。
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let socket = self?.socket else { return }
                socket.sendPing { _ in }
            }
        }
    }

    private func finish(_ terminal: Phase) {
        guard isActive || phase == .idle else { return }
        connectTask?.cancel()
        connectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        closeSocket()
        phase = terminal
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func createLive(
        persona: String,
        imageURI: String,
        name: String,
        voice: String
    ) async throws -> ViduSignal.CreateLiveResult {
        guard let url = URL(string: "https://\(host)/live/v1/lives") else {
            throw ViduError.badHost(host)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 实测 video 模式建会话（按形象图初始化数字人）要 40 秒以上。
        request.timeoutInterval = 120
        request.setValue(ViduSignal.authorizationHeader(apiKey: apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ViduSignal.createLiveBody(
            callMode: callMode,
            persona: persona,
            imageURI: imageURI,
            name: name,
            voice: voice
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ViduError.server(ViduSignal.errorMessage(from: data, status: status))
        }
        guard let result = ViduSignal.parseCreateLiveResponse(data) else {
            throw ViduError.server("响应缺少 live/rtc 字段")
        }
        return result
    }

    enum ViduError: LocalizedError {
        case badHost(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badHost(let host): return "Vidu host 配置无效：\(host)"
            case .server(let message): return message
            }
        }
    }
}
