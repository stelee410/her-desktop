import Foundation

/// 会话可选的聊天模型选项：id + 一句话特色。
struct AgentLLMChatModelOption: Identifiable, Equatable {
    var id: String
    var tagline: String
}

/// 从 agentLLM 的 /v1/models 拉全量模型 id，再和这里的精选表求交集 ——
/// 网关上没有的不展示，网关新增了但这里没写文案的也不展示（会话级
/// 覆盖只提供"几个主力"，完整自由度仍在全局设置里手填）。
enum AgentLLMModelCatalog {
    /// 精选主力模型与特色（顺序即菜单顺序）。
    static let curated: [AgentLLMChatModelOption] = [
        .init(id: "linkyun-default", tagline: "默认路由 · 质量/速度/成本均衡"),
        .init(id: "linkyun-smart", tagline: "智能路由 · 难题自动升级更强模型"),
        .init(id: "claude-fable-5", tagline: "Anthropic 旗舰 · 复杂推理与代码最稳"),
        .init(id: "claude-sonnet", tagline: "Anthropic 主力 · 写作/代码/工具调用均衡"),
        .init(id: "claude-haiku", tagline: "Anthropic 轻量 · 快且便宜，适合简单任务"),
        .init(id: "gpt-5.6", tagline: "OpenAI 旗舰 · 通用能力强，创意写作出色"),
        .init(id: "gpt-5-mini", tagline: "OpenAI 轻量 · 日常问答性价比高"),
        .init(id: "gemini-3.1-pro", tagline: "Google 旗舰 · 多模态与长文档理解强"),
        .init(id: "gemini-3.5-flash", tagline: "Google 快速 · 响应快、长上下文、省钱"),
        .init(id: "deepseek-v4-pro", tagline: "DeepSeek · 推理性价比之王"),
        .init(id: "deepseek-reasoner", tagline: "DeepSeek 慢思考 · 数学与逻辑推演强"),
        .init(id: "qwen3.7-max", tagline: "通义旗舰 · 中文理解与创作出色"),
        .init(id: "grok-4.3", tagline: "xAI · 风格直率，时事感强"),
        .init(id: "MiniMax-M2.7", tagline: "MiniMax · 中文对话自然，角色扮演出彩")
    ]

    /// 精选表 ∩ 网关实际存在的 id，保持精选顺序。纯函数，可测。
    static func options(availableIDs: some Collection<String>) -> [AgentLLMChatModelOption] {
        let available = Set(availableIDs)
        return curated.filter { available.contains($0.id) }
    }

    static func fetch(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [AgentLLMChatModelOption] {
        var request = URLRequest(url: baseURL.appending(path: "/v1/models"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct ModelList: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        let ids = try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id)
        return options(availableIDs: ids)
    }
}
