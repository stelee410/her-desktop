import XCTest
@testable import HerDesktop

@MainActor
final class RoleplayTests: XCTestCase {
    private func makeRoot(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-roleplay-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    func testStoreRoundTripAndCorruptBackup() throws {
        let root = makeRoot("store")
        let store = RoleplayStore(cwd: root.path)
        let card = CharacterCard(name: "苏格拉底", summary: "爱提问的老头", prompt: "只用反问回答。")
        let book = WorldBook(name: "雅典", entries: [
            .init(title: "广场", keywords: "广场, agora", content: "城邦的中心。"),
            .init(title: "背景", content: "公元前五世纪。", alwaysOn: true)
        ])
        try store.save(cards: [card], books: [book])

        let loaded = store.load()
        XCTAssertEqual(loaded.cards.map(\.name), ["苏格拉底"])
        XCTAssertEqual(loaded.books.first?.entries.count, 2)

        // Corrupt file → backed up, load returns empty.
        try Data("BROKEN".utf8).write(to: store.fileURL)
        let corrupt = store.load()
        XCTAssertTrue(corrupt.cards.isEmpty)
        let backups = try FileManager.default
            .contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
            .filter { $0.contains("roleplay.corrupt-") }
        XCTAssertFalse(backups.isEmpty)
    }

    func testWorldBookKeywordMatching() {
        let book = WorldBook(name: "w", entries: [
            .init(title: "常驻", content: "always", alwaysOn: true),
            .init(title: "龙", keywords: "龙, dragon", content: "龙怕冷。"),
            .init(title: "空关键词", keywords: "", content: "inert"),
            .init(title: "空内容", keywords: "龙", content: "", alwaysOn: false)
        ])
        let hit = book.activeEntries(matching: "听说山里有一条龙?")
        XCTAssertEqual(hit.map(\.title), ["常驻", "龙"])
        let miss = book.activeEntries(matching: "今天天气不错")
        XCTAssertEqual(miss.map(\.title), ["常驻"])
        // Case-insensitive latin keywords.
        XCTAssertTrue(book.activeEntries(matching: "a DRAGON appears").contains { $0.title == "龙" })
    }

    func testSelectionPersistsAndInjectsIntoPrompt() {
        let root = makeRoot("selection")
        let model = AppViewModel(cwd: root.path)
        let card = model.addCharacterCard()
        var edited = card
        edited.name = "船长"
        edited.prompt = "你是一位暴躁但善良的海盗船长。"
        edited.greeting = "欢迎上船!"
        model.updateCharacterCard(edited)
        let book = model.addWorldBook()
        var editedBook = book
        editedBook.entries = [
            .init(title: "设定", content: "这艘船叫黑珍珠号。", alwaysOn: true),
            .init(title: "宝藏", keywords: "宝藏", content: "宝藏埋在骷髅岛。")
        ]
        model.updateWorldBook(editedBook)

        model.setCharacterCard(edited)
        model.setWorldBook(editedBook)

        // Selection persisted on the conversation summary (survives restart
        // via the index) and the greeting was spoken in character.
        XCTAssertEqual(model.activeConversationSummary?.characterCardID, edited.id.uuidString)
        XCTAssertEqual(model.activeConversationSummary?.worldBookID, editedBook.id.uuidString)
        XCTAssertTrue(model.messages.contains { $0.content == "欢迎上船!" })

        // Prompt injection: card always; world book always-on entry always,
        // keyword entry only when mentioned.
        var section = model.roleplayPromptSection()
        XCTAssertTrue(section.contains("海盗船长"))
        XCTAssertTrue(section.contains("黑珍珠号"))
        XCTAssertFalse(section.contains("骷髅岛"))

        model.messages.append(ChatMessage(role: .user, content: "宝藏在哪里?"))
        section = model.roleplayPromptSection()
        XCTAssertTrue(section.contains("骷髅岛"))

        // Full system prompt carries the section.
        let prompt = SystemPromptBuilder(
            pluginManifests: [],
            projectDocs: ProjectPromptDocs(soul: "s", project: "p")
        ).build(memoryContext: "", activeTaskSummary: "", roleplayContext: section)
        XCTAssertTrue(prompt.contains("角色扮演 · 船长"))
        XCTAssertTrue(prompt.contains("NEVER overrides safety"))

        // Deleting the card clears the conversation's selection.
        model.deleteCharacterCard(edited.id)
        XCTAssertNil(model.activeConversationSummary?.characterCardID)
        XCTAssertTrue(model.roleplayPromptSection().contains("黑珍珠号"), "world book still applies")

        // New conversations start with no roleplay selection.
        model.newLocalConversation()
        XCTAssertNil(model.activeCharacterCard)
        XCTAssertNil(model.activeWorldBook)
    }

    func testMemoryRoutingByCharacterCard() {
        let root = makeRoot("memory-routing")
        var config = HerAppConfig.empty
        config.agentMemAPIKey = "global-mem-key"
        let model = AppViewModel(config: config, cwd: root.path)

        // No card → global memory.
        XCTAssertEqual(model.memoryRouting(forConversation: model.activeConversationID), .global)
        XCTAssertNotNil(model.memoryClient(forConversation: model.activeConversationID))

        // Card WITHOUT its own key → memory disabled, even with a global key.
        let card = model.addCharacterCard()
        model.setCharacterCard(card)
        XCTAssertEqual(model.memoryRouting(forConversation: model.activeConversationID), .disabled)
        XCTAssertNil(model.memoryClient(forConversation: model.activeConversationID),
                     "roleplay without a dedicated key must not touch the real memory")

        // Card WITH its own key → dedicated client.
        var keyed = card
        keyed.agentMemAPIKey = "character-own-key"
        model.updateCharacterCard(keyed)
        XCTAssertEqual(model.memoryRouting(forConversation: model.activeConversationID), .characterScoped)
        let scoped = model.memoryClient(forConversation: model.activeConversationID)
        XCTAssertNotNil(scoped)
        XCTAssertFalse(scoped === model.agentMem, "character memory must not be the global client")

        // Other conversations are unaffected.
        model.newLocalConversation()
        XCTAssertEqual(model.memoryRouting(forConversation: model.activeConversationID), .global)

        // No global key + no card → disabled too.
        var noMem = config
        noMem.agentMemAPIKey = ""
        model.applyConfiguration(noMem)
        XCTAssertNil(model.memoryClient(forConversation: model.activeConversationID))
    }

    func testCardsWithoutMemoryKeyFieldDecodeWithDefaults() throws {
        // Cards persisted before agentMemAPIKey existed must load, not trip
        // the corrupt-file path.
        let legacy = """
        {"version":1,"worldBooks":[],"characterCards":[
          {"id":"1B0B1E9A-3C63-45E0-9E1B-3A1111111111","name":"老卡","emoji":"🎭",
           "summary":"","prompt":"p","greeting":"","createdAt":"2026-07-08T00:00:00Z","updatedAt":"2026-07-08T00:00:00Z"}
        ]}
        """
        let root = makeRoot("legacy-decode")
        let store = RoleplayStore(cwd: root.path)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(legacy.utf8).write(to: store.fileURL)
        let loaded = store.load()
        XCTAssertEqual(loaded.cards.map(\.name), ["老卡"])
        XCTAssertNil(loaded.cards.first?.dedicatedMemoryKey)
    }

    func testRoleplayAssetsSurviveRestart() {
        let root = makeRoot("restart")
        let model = AppViewModel(cwd: root.path)
        let card = model.addCharacterCard()
        model.setCharacterCard(card)

        let restarted = AppViewModel(cwd: root.path)
        restarted.loadRoleplayAssets()
        XCTAssertEqual(restarted.characterCards.map(\.id), [card.id])
        XCTAssertEqual(restarted.activeConversationSummary?.characterCardID, card.id.uuidString)
        XCTAssertEqual(restarted.activeCharacterCard?.id, card.id)
    }
}
