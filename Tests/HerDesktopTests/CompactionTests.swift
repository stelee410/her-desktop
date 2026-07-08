import XCTest
@testable import HerDesktop

@MainActor
final class CompactionTests: XCTestCase {
    final class FakeLLM: AgentLLMChatting {
        var responses: [AgentLLMChatResponse.Choice.Message]
        var requests: [[AgentLLMMessage]] = []

        init(responses: [AgentLLMChatResponse.Choice.Message]) {
            self.responses = responses
        }

        func chat(
            messages: [AgentLLMMessage],
            tools: [[String: Any]],
            onEvent: @escaping @MainActor (AgentLLMStreamEvent) -> Void
        ) async throws -> AgentLLMChatResponse.Choice.Message {
            requests.append(messages)
            guard !responses.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return responses.removeFirst()
        }
    }

    private func makeModel(
        _ label: String,
        responses: [AgentLLMChatResponse.Choice.Message] = []
    ) -> (AppViewModel, FakeLLM) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-compact-\(label)-\(UUID().uuidString)", isDirectory: true)
        let llm = FakeLLM(responses: responses)
        let model = AppViewModel(cwd: root.path, agentLLM: llm)
        return (model, llm)
    }

    private func seedConversation(_ model: AppViewModel, turns: Int, label: String = "问题") {
        for index in 0..<turns {
            model.messages.append(ChatMessage(role: .user, content: "\(label) \(index)"))
            model.messages.append(ChatMessage(role: .assistant, content: "回答\(label) \(index)"))
        }
    }

    private func recapReply(_ text: String) -> AgentLLMChatResponse.Choice.Message {
        AgentLLMChatResponse.Choice.Message(role: "assistant", content: text)
    }

    func testManualCompactAppendsRecapCard() async {
        let (model, llm) = makeModel("manual", responses: [recapReply("**正在进行**: 桌面端语音")])
        seedConversation(model, turns: 5)

        await model.compactActiveConversation(trigger: .manual)

        let recap = model.messages.last
        XCTAssertEqual(recap?.recap, true)
        XCTAssertEqual(recap?.content, "**正在进行**: 桌面端语音")
        XCTAssertFalse(model.isCompacting)
        // The summarizer saw the transcript, not the system-prompt pipeline.
        XCTAssertEqual(llm.requests.count, 1)
        XCTAssertTrue(llm.requests[0].contains { $0.content?.contains("问题 0") == true })
    }

    func testSlashCommandsAreInterceptedAndShownLocally() {
        let (model, _) = makeModel("commands", responses: [recapReply("回顾")])
        seedConversation(model, turns: 5)

        XCTAssertTrue(model.handleSlashCommand("/compact"))
        XCTAssertTrue(model.messages.contains { $0.content == "/compact" && $0.localOnly })
        XCTAssertFalse(model.handleSlashCommand("普通消息"))
        XCTAssertFalse(model.handleSlashCommand("/unknown"))
    }

    func testRecapAliasTriggersCompaction() async {
        let (model, _) = makeModel("alias", responses: [recapReply("第二种命令")])
        seedConversation(model, turns: 5)

        XCTAssertTrue(model.handleSlashCommand("/recap"))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !model.messages.contains(where: { $0.recap }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(model.messages.contains { $0.recap && $0.content == "第二种命令" })
    }

    func testCompactSkipsWhenTooLittleContent() async {
        let (model, llm) = makeModel("tiny", responses: [recapReply("不该出现")])
        seedConversation(model, turns: 2)

        await model.compactActiveConversation(trigger: .manual)

        XCTAssertFalse(model.messages.contains { $0.recap })
        XCTAssertTrue(llm.requests.isEmpty, "no LLM call for a conversation that small")
        XCTAssertTrue(model.messages.contains { $0.localOnly && $0.content.contains("暂时不需要") })
    }

    func testAutoCompactRunsOnlyPastThreshold() async {
        let (model, llm) = makeModel("auto", responses: [recapReply("自动回顾")])
        seedConversation(model, turns: 10)

        await model.autoCompactIfNeeded()
        XCTAssertTrue(llm.requests.isEmpty, "20 messages stay below the auto threshold")

        seedConversation(model, turns: 10)
        await model.autoCompactIfNeeded()
        XCTAssertTrue(model.messages.contains { $0.recap && $0.content == "自动回顾" })
    }

    func testMessagesSinceLastRecapCountsOnlyNewConversation() {
        let (model, _) = makeModel("count")
        seedConversation(model, turns: 3)
        model.messages.append(ChatMessage(role: .assistant, content: "回顾", recap: true))
        model.messages.append(ChatMessage(role: .assistant, content: "通知", localOnly: true))
        seedConversation(model, turns: 2)

        XCTAssertEqual(model.messagesSinceLastRecap(), 4)
    }

    func testSecondCompactFoldsPreviousRecapIntoSummaryInput() async {
        let (model, llm) = makeModel(
            "cumulative",
            responses: [recapReply("第一次回顾"), recapReply("第二次回顾")]
        )
        seedConversation(model, turns: 5, label: "旧问题")
        await model.compactActiveConversation(trigger: .manual)
        seedConversation(model, turns: 5, label: "新问题")
        await model.compactActiveConversation(trigger: .manual)

        XCTAssertEqual(llm.requests.count, 2)
        XCTAssertTrue(llm.requests[1].contains { $0.content?.contains("第一次回顾") == true },
                      "the previous recap is part of the next summary's input")
        XCTAssertTrue(llm.requests[1].contains { $0.content?.contains("新问题 0") == true })
        XCTAssertFalse(llm.requests[1].contains { $0.content?.contains("旧问题 0") == true },
                       "messages before the previous recap are not re-summarized")
    }

    func testCompactFailureLeavesTranscriptUntouched() async {
        let (model, _) = makeModel("failure", responses: [])
        seedConversation(model, turns: 5)
        let before = model.messages.filter { !$0.localOnly }

        await model.compactActiveConversation(trigger: .manual)

        XCTAssertFalse(model.messages.contains { $0.recap })
        XCTAssertEqual(model.messages.filter { !$0.localOnly }, before)
        XCTAssertTrue(model.messages.contains { $0.localOnly && $0.content.contains("没有成功") })
        XCTAssertFalse(model.isCompacting)
    }

    func testChatMessageRecapFlagDecodesTolerantly() throws {
        let legacy = #"{"role":"assistant","content":"老消息"}"#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.recap)

        let recap = ChatMessage(role: .assistant, content: "回顾", recap: true)
        let roundTripped = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(recap))
        XCTAssertTrue(roundTripped.recap)
    }
}
