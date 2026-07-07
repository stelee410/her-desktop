import XCTest
@testable import HerDesktop

@MainActor
final class AgentJobTests: XCTestCase {
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

    final class FakeNotifier: NativeNotificationScheduling {
        var scheduled: [(title: String, body: String)] = []

        func schedule(title: String, body: String, delaySeconds: TimeInterval) async throws -> String {
            scheduled.append((title, body))
            return "fake-id"
        }
    }

    private func makeModel(
        _ label: String,
        responses: [AgentLLMChatResponse.Choice.Message],
        notifier: FakeNotifier = FakeNotifier()
    ) -> (AppViewModel, FakeLLM) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-jobs-\(label)-\(UUID().uuidString)", isDirectory: true)
        let llm = FakeLLM(responses: responses)
        let model = AppViewModel(cwd: root.path, agentLLM: llm, notificationScheduler: notifier)
        return (model, llm)
    }

    private func waitForJobsFinished(_ model: AppViewModel, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.agentJobs.allSatisfy(\.isFinished), model.jobWorkerTask == nil {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Result cards are delivered asynchronously (they wait out a transcript
    /// load window); poll for the card instead of asserting immediately.
    private func waitForCard(
        _ model: AppViewModel,
        containing text: String,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.messages.contains(where: { $0.content.contains(text) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func plainReply(_ text: String) -> AgentLLMChatResponse.Choice.Message {
        AgentLLMChatResponse.Choice.Message(role: "assistant", content: text)
    }

    private func toolCallReply(function: String, arguments: String) -> AgentLLMChatResponse.Choice.Message {
        AgentLLMChatResponse.Choice.Message(
            role: "assistant",
            content: nil,
            toolCalls: [.init(
                id: UUID().uuidString,
                type: "function",
                function: .init(name: function, arguments: arguments)
            )]
        )
    }

    func testJobRunsInOwnContextAndDeliversSingleResultCard() async {
        let notifier = FakeNotifier()
        let (model, llm) = makeModel("plain", responses: [plainReply("市场没什么大事。")], notifier: notifier)
        let before = model.messages.count

        model.enqueueJob(
            title: "早报",
            prompt: "总结一下今天的市场",
            source: .heartbeat(taskTitle: "早报")
        )
        await waitForJobsFinished(model)

        // Exactly one card lands in the conversation (delivered async).
        let delivered = await waitForCard(model, containing: "后台任务完成 · 早报")
        XCTAssertTrue(delivered)
        XCTAssertEqual(model.messages.count, before + 1)
        let card = model.messages.last?.content ?? ""
        XCTAssertTrue(card.contains("市场没什么大事。"))
        // The user's transcript never gained a fake "user" message.
        XCTAssertFalse(model.messages.contains { $0.role == .user })
        // The job's own context carried the prompt.
        XCTAssertTrue(llm.requests.first?.contains { message in
            message.role == "user" && (message.content?.contains("总结一下今天的市场") ?? false)
        } ?? false)
        XCTAssertEqual(model.agentJobs.first?.state, .done)
        // Heartbeat-sourced jobs notify on completion.
        XCTAssertEqual(notifier.scheduled.count, 1)
        XCTAssertTrue(model.auditEvents.contains { $0.type == "job.finished" })
    }

    func testJobStopsAtApprovalAndParksTheRequest() async {
        // shell.run requires approval; the job must stop, not bypass.
        let (model, _) = makeModel("approval", responses: [
            toolCallReply(function: "shell_run", arguments: #"{"command":"rm","args":["x"]}"#)
        ])

        model.enqueueJob(title: "清理", prompt: "删除临时文件", source: .user)
        await waitForJobsFinished(model)

        XCTAssertEqual(model.agentJobs.first?.state, .needsApproval)
        XCTAssertEqual(model.pendingApprovals.count, 1)
        XCTAssertTrue(model.messages.contains { $0.approvalID != nil },
                      "the approval card must be parked in the conversation")
        let parked = await waitForCard(model, containing: "后台任务待批准")
        XCTAssertTrue(parked)
    }

    func testJobFailsWhenToolRoundBudgetExhausted() async {
        // Model keeps calling a no-approval tool forever; budget must stop it.
        let calls = (0..<10).map { _ in
            toolCallReply(function: "schedule_list", arguments: "{}")
        }
        let (model, _) = makeModel("budget", responses: calls)

        model.enqueueJob(title: "循环", prompt: "不停列任务", source: .user, maxToolRounds: 2)
        await waitForJobsFinished(model)

        XCTAssertEqual(model.agentJobs.first?.state, .failed)
        XCTAssertTrue(model.agentJobs.first?.failureReason?.contains("预算上限") == true)
        let failedCard = await waitForCard(model, containing: "后台任务失败")
        XCTAssertTrue(failedCard)
    }

    func testHeartbeatPromptTaskEnqueuesJobInsteadOfInterruptingConversation() async {
        let (model, _) = makeModel("heartbeat", responses: [plainReply("检查完毕")])
        model.heartbeatTasks = [HeartbeatTask(
            title: "巡检",
            action: .prompt,
            prompt: "检查系统状态",
            schedule: .once(at: Date().addingTimeInterval(-5))
        )]

        await model.heartbeatTick()
        await waitForJobsFinished(model)

        XCTAssertFalse(model.messages.contains { $0.role == .user },
                       "heartbeat must not inject fake user messages")
        let done = await waitForCard(model, containing: "后台任务完成 · 巡检")
        XCTAssertTrue(done)
        XCTAssertNotNil(model.heartbeatTasks.first?.completedAt)
    }

    func testJobWaitsWhileUserTurnIsGenerating() async {
        let (model, _) = makeModel("yield", responses: [plainReply("ok")])
        model.connectionState = .thinking // user turn in flight

        model.enqueueJob(title: "等待", prompt: "test", source: .user)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.agentJobs.first?.state, .queued,
                       "job must yield to the in-flight user turn")

        model.connectionState = .ready
        await waitForJobsFinished(model)
        XCTAssertEqual(model.agentJobs.first?.state, .done)
    }
}
