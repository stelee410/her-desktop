import AppKit
import Foundation
import SwiftUI

/// User-facing copy for recovery, setup, and configuration flows.
extension AppViewModel {
    func conversationalRecoveryMessage(for error: Error) -> String {
        let redactedError = error.localizedDescription
        let nextStep: String
        switch error {
        case ServiceError.missingAPIKey(let service) where service == "AgentLLM":
            nextStep = "现在只需要先配置 AgentLLM API key。打开 Settings 填入 key 后保存，我们就可以继续。"
        case ServiceError.httpStatus(let status, _):
            nextStep = agentLLMHTTPRecoveryStep(status: status)
        case ServiceError.invalidResponse:
            nextStep = "服务返回格式不对。先在 Settings 确认 AgentLLM base URL 指向 OpenAI-compatible 接口，然后点 Save & Check。"
        case ServiceError.decoding:
            nextStep = "我收到了服务响应，但格式和当前客户端不匹配。先确认 AgentLLM model 和线上接口版本，再重新发送这句话。"
        default:
            nextStep = networkRecoveryStep(for: error)
        }
        return """
        我这边连接 AgentLLM 时遇到问题：\(redactedError)

        \(nextStep)

        AgentMem、插件和其他扩展都可以之后再接；现在先把 AgentLLM 聊天通路跑通。
        """
    }

    func configurationSavedMessage(config: HerAppConfig) -> String {
        guard config.hasLLMKey else {
            return Self.firstRunSetupMessage(config: config)
        }
        if config.hasMemKey {
            return "AgentLLM key 已保存。我会先检查聊天通路；AgentMem 也已配置，会作为长期记忆增强使用。"
        }
        return "AgentLLM key 已保存。我会先检查聊天通路；AgentMem 和插件扩展可以之后按需要再接。"
    }

    func inlineAgentLLMKeySavedMessage(hasAttachments: Bool) -> String {
        let attachmentNote = hasAttachments
            ? "\n\n我没有把这条带密钥的消息发给模型；如果附件里还有要处理的任务，请重新发一次任务内容。"
            : ""
        return """
        AgentLLM key 已经保存，我也把聊天记录里的密钥打码了。现在我会检查聊天通路。

        检查通过后，直接发你要做的事就可以开始；AgentMem、插件和 MCP 都不是第一步。\(attachmentNote)
        """
    }

    func readinessGuidanceMessage() -> String {
        let summary = productReadinessSummary
        if !config.hasLLMKey {
            return Self.firstRunSetupMessage(config: config)
        }

        if let llm = summary.items.first(where: { $0.id == "agentllm" }), llm.level == .attention {
            return """
            AgentLLM key 已经配置，但聊天通路还没有确认可用：\(llm.detail)

            下一步先做一件事：在 Settings 里确认 base URL 是服务根地址、API key 没有多余空格、model 是当前可用模型，然后保存并检查。修好后直接把刚才的话再发一次，我会接着做。

            AgentMem、插件和 MCP 先不用处理，它们不会阻塞 MVP 聊天。
            """
        }

        let pluginItem = summary.items.first { $0.id == "plugins" }
        if pluginItem?.level == .attention {
            return """
            现在已经可以开始聊天和工作。插件运行时还有可选项需要注意：\(pluginItem?.detail ?? "")

            这不是第一步阻塞项。你可以直接告诉我想完成什么；等需要某个工具或扩展时，我会在对话里说明缺什么、是否需要生成插件、以及安装前需要你确认什么。
            """
        }

        return """
        核心聊天通路已经准备好。你可以直接把要做的事发给我。

        如果后面需要长期记忆、MCP 工具或新的内置扩展，我会通过对话先解释目的和权限，再生成草稿、等待你确认后安装。
        """
    }

    func agentLLMHTTPRecoveryStep(status: Int) -> String {
        switch status {
        case 401, 403:
            return "这通常是 API key 无效、过期，或没有访问当前模型的权限。打开 Settings 重新粘贴 AgentLLM API key，确认没有多余空格，然后保存。"
        case 404:
            return "这通常是 AgentLLM base URL 或路径不对。Settings 里 base URL 应该填服务根地址，例如 https://agentllm.linkyun.co/，不要带 /v1/chat/completions。"
        case 408, 429:
            return "服务暂时忙或限流。等一会儿再发，或在 Settings 里换一个可用模型后保存。"
        case 500...599:
            return "AgentLLM 服务端暂时不可用。可以先点 Save & Check 复测；如果 health 正常，再重新发送这句话。"
        default:
            return "先在 Settings 检查 AgentLLM base URL、API key 和 model，然后点 Save & Check。我会保留这轮对话，你修好后可以直接重发。"
        }
    }

    func networkRecoveryStep(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return "先在 Settings 检查 AgentLLM base URL、API key 和 model，然后点 Save & Check。我会保留这轮对话，你修好后可以直接重发。"
        }
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            return "请求超时了。先确认网络和 AgentLLM 服务可达；如果服务健康，可以直接重新发送这句话。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet:
            return "我连不上 AgentLLM 地址。先检查网络和 Settings 里的 base URL，然后点 Save & Check。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "TLS 连接没有建立成功。先确认 AgentLLM 地址使用正确的 HTTPS 域名和有效证书。"
        default:
            return "先在 Settings 检查 AgentLLM base URL、API key 和 model，然后点 Save & Check。我会保留这轮对话，你修好后可以直接重发。"
        }
    }
}
