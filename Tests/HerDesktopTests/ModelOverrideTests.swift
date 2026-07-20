import XCTest
@testable import HerDesktop

@MainActor
final class ModelOverrideTests: XCTestCase {
    func testCatalogFiltersToAvailableIDsInCuratedOrder() {
        let options = AgentLLMModelCatalog.options(
            availableIDs: ["gemini-3.5-flash", "whisper-1", "claude-sonnet", "unknown-model"]
        )
        XCTAssertEqual(options.map(\.id), ["claude-sonnet", "gemini-3.5-flash"])
        XCTAssertFalse(options[0].tagline.isEmpty)
    }

    func testCatalogEmptyWhenNothingMatches() {
        XCTAssertTrue(AgentLLMModelCatalog.options(availableIDs: ["whisper-1"]).isEmpty)
    }

    func testSummaryDecodesLegacyIndexWithoutModelOverride() throws {
        let json = #"{"id":"abc","title":"t","pinned":false,"created_at":700000000,"updated_at":700000000}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let summary = try decoder.decode(ConversationSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.modelOverride)
    }

    func testActiveModelOverrideIgnoresBlankValues() {
        let model = makeModel()
        XCTAssertNil(model.activeModelOverride)
        model.setModelOverride("  ")
        XCTAssertNil(model.activeModelOverride)
        model.setModelOverride("gemini-3.5-flash")
        XCTAssertEqual(model.activeModelOverride, "gemini-3.5-flash")
        model.setModelOverride(nil)
        XCTAssertNil(model.activeModelOverride)
    }

    private func makeModel() -> AppViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-model-override-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppViewModel(config: .empty, cwd: root.path)
    }
}

@MainActor
final class MessageDeleteTests: XCTestCase {
    private func makeModel() -> AppViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-msg-delete-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppViewModel(config: .empty, cwd: root.path)
    }

    func testDeleteRemovesMessageAndPendingApproval() {
        let model = makeModel()
        let approval = PendingApproval(
            title: "t",
            detail: "d",
            invocation: CapabilityInvocation(
                toolCallID: "1", functionName: "shell_run", capabilityID: "shell.run", arguments: [:]
            )
        )
        model.pendingApprovals = [approval]
        let message = ChatMessage(role: .tool, content: "Approval Required", approvalID: approval.id)
        model.messages = [ChatMessage(role: .user, content: "hi"), message]

        model.deleteMessage(message.id)

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertTrue(model.pendingApprovals.isEmpty)
    }

    func testDeleteIgnoresUnknownAndStreamingMessages() {
        let model = makeModel()
        let streaming = ChatMessage(role: .assistant, content: "typing…")
        model.messages = [streaming]
        model.streamingAssistantMessageID = streaming.id

        model.deleteMessage(streaming.id)
        XCTAssertEqual(model.messages.count, 1, "streaming message must not be deletable")

        model.deleteMessage(UUID())
        XCTAssertEqual(model.messages.count, 1)
    }
}

@MainActor
final class SpeechSanitizerTests: XCTestCase {
    func testStripsFullWidthAndHalfWidthParentheticals() {
        let text = "（沉默了几秒）\n说实话……我就是被你吸引了。(心动值 72)\n（微微低头）好啦。"
        XCTAssertEqual(
            AppViewModel.strippingParentheticals(from: text),
            "说实话……我就是被你吸引了。\n好啦。"
        )
    }

    func testStripsNestedAndKeepsUnpaired() {
        XCTAssertEqual(
            AppViewModel.strippingParentheticals(from: "你好（外层（内层）还有）世界"),
            "你好世界"
        )
        XCTAssertEqual(
            AppViewModel.strippingParentheticals(from: "半个括号 (不配对 保留"),
            "半个括号 (不配对 保留"
        )
    }

    func testAllParentheticalMessageBecomesEmpty() {
        XCTAssertEqual(AppViewModel.strippingParentheticals(from: "（抬头看着你）"), "")
    }
}

@MainActor
final class NewConversationAfterDeleteTests: XCTestCase {
    private func makeModel() -> AppViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-newconv-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppViewModel(config: .empty, cwd: root.path)
    }

    func testNewConversationWorksAfterDeletingActive() async {
        let model = makeModel()
        // 起点：造几个会话
        model.newLocalConversation()
        model.newLocalConversation()
        let baseline = model.conversations.count
        XCTAssertGreaterThanOrEqual(baseline, 2)

        // 删除当前活动会话
        let activeID = model.activeConversationID
        await model.deleteConversation(activeID, compactingIntoMemory: false)
        XCTAssertFalse(model.conversations.contains { $0.id == activeID })
        let afterDelete = model.conversations.count

        // 关键断言：删除后新建仍然能增加一个会话
        model.newLocalConversation()
        XCTAssertEqual(model.conversations.count, afterDelete + 1,
                       "新建对话在删除之后必须仍然创建新会话")
        XCTAssertFalse(model.isLoadingConversation,
                       "删除后不应残留 isLoadingConversation=true 卡住状态")
    }
}
