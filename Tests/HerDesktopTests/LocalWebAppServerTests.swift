import XCTest
@testable import HerDesktop

final class LocalWebAppServerTests: XCTestCase {
    private var server: LocalWebAppServer!
    private var store: WebAppStore!
    private var appID = ""

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-webapp-server-\(UUID().uuidString)", isDirectory: true)
        store = WebAppStore(cwd: root.path)
        appID = try store.create(
            name: "Server Test",
            description: "",
            html: "<html><body>server-test-page</body></html>"
        ).id
        server = LocalWebAppServer()
        try server.start(store: store)
    }

    override func tearDown() {
        server.stop()
    }

    private func baseURL() throws -> URL {
        let port = try XCTUnwrap(server.port)
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    }

    func testServesStaticEntryPage() async throws {
        let url = try baseURL().appendingPathComponent("apps/\(appID)/")
        let (data, response) = try await URLSession.shared.data(from: url)

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(http.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") == true)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("server-test-page") == true)
    }

    func testUnknownAppAndTraversalReturn404() async throws {
        let unknown = try baseURL().appendingPathComponent("apps/nope/")
        let (_, unknownResponse) = try await URLSession.shared.data(from: unknown)
        XCTAssertEqual((unknownResponse as? HTTPURLResponse)?.statusCode, 404)

        var traversal = URLRequest(url: try XCTUnwrap(
            URL(string: try baseURL().absoluteString + "/apps/\(appID)/..%2Fwebapp.json")
        ))
        traversal.httpMethod = "GET"
        let (_, traversalResponse) = try await URLSession.shared.data(for: traversal)
        XCTAssertEqual((traversalResponse as? HTTPURLResponse)?.statusCode, 404)
    }

    func testQueryAPIRequiresToken() async throws {
        var request = URLRequest(url: try baseURL().appendingPathComponent("apps/\(appID)/api/query"))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"sql":"SELECT 1"}"#.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    func testQueryAPIRoundTripWithSQLite() async throws {
        let token = server.token(for: appID)
        func query(_ body: String) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: try baseURL().appendingPathComponent("apps/\(appID)/api/query"))
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "X-WebApp-Token")
            request.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, object)
        }

        let (createStatus, _) = try await query(
            #"{"sql":"CREATE TABLE habits (id INTEGER PRIMARY KEY, name TEXT)"}"#
        )
        XCTAssertEqual(createStatus, 200)

        let (insertStatus, insert) = try await query(
            #"{"sql":"INSERT INTO habits (name) VALUES (?)","params":["morning run"]}"#
        )
        XCTAssertEqual(insertStatus, 200)
        XCTAssertEqual(insert["rows_changed"] as? Double ?? Double(insert["rows_changed"] as? Int ?? 0), 1)

        let (selectStatus, select) = try await query(#"{"sql":"SELECT name FROM habits"}"#)
        XCTAssertEqual(selectStatus, 200)
        let rows = try XCTUnwrap(select["rows"] as? [[Any]])
        XCTAssertEqual(rows.first?.first as? String, "morning run")

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL(id: appID).path))

        let (badStatus, bad) = try await query(#"{"sql":"SELECT * FROM missing_table"}"#)
        XCTAssertEqual(badStatus, 400)
        XCTAssertEqual(bad["ok"] as? Bool, false)
    }

    func testURLForAppIncludesToken() throws {
        let url = try XCTUnwrap(server.url(for: appID))
        XCTAssertTrue(url.absoluteString.contains("/apps/\(appID)/"))
        XCTAssertTrue(url.absoluteString.contains("token="))
        XCTAssertEqual(url.host, "127.0.0.1")
    }
}
