import XCTest
@testable import HerDesktop

final class WebAppStoreTests: XCTestCase {
    private func makeStore(_ label: String) -> WebAppStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-webapp-store-\(label)-\(UUID().uuidString)", isDirectory: true)
        return WebAppStore(cwd: root.path)
    }

    func testCreateWritesManifestEntryAndHTML() throws {
        let store = makeStore("create")

        let manifest = try store.create(
            name: "Habit Tracker",
            description: "Daily habit check-ins",
            html: "<html><body>hi</body></html>"
        )

        XCTAssertEqual(manifest.id, "habit-tracker")
        XCTAssertEqual(manifest.entry, "index.html")
        let html = try String(
            contentsOf: store.wwwDirectory(id: manifest.id).appendingPathComponent("index.html"),
            encoding: .utf8
        )
        XCTAssertTrue(html.contains("hi"))
        XCTAssertEqual(store.loadAll().map(\.id), ["habit-tracker"])
        XCTAssertEqual(store.manifest(id: "habit-tracker")?.description, "Daily habit check-ins")
    }

    func testCreateRejectsEmptyHTMLAndDeduplicatesIDs() throws {
        let store = makeStore("dedupe")

        XCTAssertThrowsError(try store.create(name: "x", description: "", html: "   "))

        let first = try store.create(name: "Notes", description: "", html: "<p>1</p>")
        let second = try store.create(name: "Notes", description: "", html: "<p>2</p>")
        XCTAssertEqual(first.id, "notes")
        XCTAssertEqual(second.id, "notes-2")
    }

    func testUpdateReplacesHTMLAndKeepsDatabaseFile() throws {
        let store = makeStore("update")
        let manifest = try store.create(name: "Todo", description: "", html: "<p>v1</p>")
        try Data("fake-db".utf8).write(to: store.databaseURL(id: manifest.id))

        let updated = try store.update(id: manifest.id, html: "<p>v2</p>", name: "Todo Plus")

        XCTAssertEqual(updated.name, "Todo Plus")
        let html = try String(
            contentsOf: store.wwwDirectory(id: manifest.id).appendingPathComponent("index.html"),
            encoding: .utf8
        )
        XCTAssertTrue(html.contains("v2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL(id: manifest.id).path))
    }

    func testRemoveDeletesAppDirectory() throws {
        let store = makeStore("remove")
        let manifest = try store.create(name: "Bye", description: "", html: "<p>x</p>")

        try store.remove(id: manifest.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appDirectory(id: manifest.id).path))
        XCTAssertThrowsError(try store.remove(id: manifest.id))
    }

    func testStaticFileURLBlocksPathTraversal() throws {
        let store = makeStore("traversal")
        let manifest = try store.create(name: "Safe", description: "", html: "<p>safe</p>")
        let secret = store.appDirectory(id: manifest.id).appendingPathComponent("webapp.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))

        XCTAssertNotNil(store.staticFileURL(appID: manifest.id, requestPath: ""))
        XCTAssertNotNil(store.staticFileURL(appID: manifest.id, requestPath: "index.html"))
        XCTAssertNil(store.staticFileURL(appID: manifest.id, requestPath: "../webapp.json"))
        XCTAssertNil(store.staticFileURL(appID: manifest.id, requestPath: "..%2Fwebapp.json"))
        XCTAssertNil(store.staticFileURL(appID: manifest.id, requestPath: "../../other-app/www/index.html"))
    }

    func testSlugSanitizesNames() {
        XCTAssertEqual(WebAppStore.slug(from: "My Habit App"), "my-habit-app")
        XCTAssertEqual(WebAppStore.slug(from: "  Spaced__Out.. "), "spaced-out")
        XCTAssertTrue(WebAppStore.slug(from: "习惯打卡").hasPrefix("app-"))
    }
}
