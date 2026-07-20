import Foundation

/// Telegram 连接器：官方 Bot API 的长轮询客户端。纯 HTTP、无外部进程、
/// 无扫码——@BotFather 建个 bot 拿到 token 即可。getUpdates 长轮询收消息，
/// sendMessage 回消息。解析/构造做成纯函数便于测试。
enum TelegramAPI {
    struct IncomingMessage: Equatable {
        var updateID: Int
        var chatID: Int
        var text: String
        var senderName: String
    }

    /// 解析 getUpdates 响应；同时返回下一个 offset（最大 update_id + 1）。
    /// 只保留带文本的消息；命令 /start 等以文本形式一并交给上层。
    static func parseUpdates(_ data: Data) -> (messages: [IncomingMessage], nextOffset: Int?) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["ok"] as? Bool) == true,
              let results = root["result"] as? [[String: Any]] else {
            return ([], nil)
        }
        var messages: [IncomingMessage] = []
        var maxUpdateID: Int?
        for update in results {
            guard let updateID = intValue(update["update_id"]) else { continue }
            maxUpdateID = max(maxUpdateID ?? updateID, updateID)
            guard let message = update["message"] as? [String: Any],
                  let chat = message["chat"] as? [String: Any],
                  let chatID = intValue(chat["id"]),
                  let text = message["text"] as? String,
                  !text.isEmpty else {
                continue
            }
            let from = message["from"] as? [String: Any]
            let name = (from?["first_name"] as? String)
                ?? (from?["username"] as? String)
                ?? "对方"
            messages.append(IncomingMessage(updateID: updateID, chatID: chatID, text: text, senderName: name))
        }
        return (messages, maxUpdateID.map { $0 + 1 })
    }

    static func sendMessageBody(chatID: Int, text: String) -> Data {
        // Telegram 单条上限 4096 字符；超长截断，避免整条发送失败。
        let clipped = text.count > 4000 ? String(text.prefix(4000)) + "…" : text
        let object: [String: Any] = ["chat_id": chatID, "text": clipped]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    static func parseBotUsername(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["ok"] as? Bool) == true,
              let result = root["result"] as? [String: Any] else {
            return nil
        }
        return result["username"] as? String
    }

    /// 白名单解析：逗号分隔的 chat_id。空集合表示不限。
    static func parseAllowedChatIDs(_ raw: String) -> Set<Int> {
        Set(raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}

/// 长轮询运行时：拉起一个后台 Task 反复 getUpdates，收到消息回调到主线程。
final class TelegramConnector: @unchecked Sendable {
    typealias MessageHandler = @MainActor (TelegramAPI.IncomingMessage) -> Void

    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    private let lock = NSLock()
    private var running = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 校验 token，返回 bot 用户名（@xxx_bot）；token 无效抛错。
    func validate(token: String) async throws -> String {
        let (data, response) = try await session.data(from: apiURL(token: token, method: "getMe"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let username = TelegramAPI.parseBotUsername(data) else {
            throw TelegramError.invalidToken
        }
        return username
    }

    func start(token: String, allowedChatIDs: Set<Int>, onMessage: @escaping MessageHandler) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        pollTask = Task { [weak self] in
            guard let self else { return }
            var offset: Int?
            while !Task.isCancelled {
                do {
                    var components = URLComponents(url: self.apiURL(token: token, method: "getUpdates"), resolvingAgainstBaseURL: false)!
                    var items = [
                        URLQueryItem(name: "timeout", value: "30"),
                        URLQueryItem(name: "allowed_updates", value: "[\"message\"]")
                    ]
                    if let offset { items.append(URLQueryItem(name: "offset", value: String(offset))) }
                    components.queryItems = items
                    var request = URLRequest(url: components.url!)
                    request.timeoutInterval = 40
                    let (data, response) = try await self.session.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        continue
                    }
                    let (messages, nextOffset) = TelegramAPI.parseUpdates(data)
                    if let nextOffset { offset = nextOffset }
                    for message in messages {
                        if !allowedChatIDs.isEmpty, !allowedChatIDs.contains(message.chatID) { continue }
                        await onMessage(message)
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    func sendMessage(token: String, chatID: Int, text: String) {
        var request = URLRequest(url: apiURL(token: token, method: "sendMessage"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = TelegramAPI.sendMessageBody(chatID: chatID, text: text)
        session.dataTask(with: request).resume()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        lock.lock(); running = false; lock.unlock()
    }

    private func apiURL(token: String, method: String) -> URL {
        URL(string: "https://api.telegram.org/bot\(token)/\(method)")!
    }

    enum TelegramError: LocalizedError {
        case invalidToken
        var errorDescription: String? { "Telegram token 无效，请检查 @BotFather 给的 token。" }
    }
}
