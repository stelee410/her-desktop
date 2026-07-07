import XCTest
@testable import HerDesktop

final class WebAppProcessManagerTests: XCTestCase {
    private static let pythonBackend = """
    import json
    import os
    import sqlite3
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/hello"):
                body = json.dumps({"message": "from backend", "app": os.environ.get("HER_WEBAPP_ID", "")}).encode()
            elif self.path.startswith("/db"):
                connection = sqlite3.connect(os.environ["HER_WEBAPP_DB"])
                connection.execute("CREATE TABLE IF NOT EXISTS pings (id INTEGER PRIMARY KEY)")
                connection.execute("INSERT INTO pings DEFAULT VALUES")
                connection.commit()
                count = connection.execute("SELECT COUNT(*) FROM pings").fetchone()[0]
                connection.close()
                body = json.dumps({"pings": count}).encode()
            else:
                body = b"{}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    HTTPServer(("127.0.0.1", int(os.environ["PORT"])), Handler).serve_forever()
    """

    private func makeBackendApp(_ label: String) throws -> (WebAppStore, WebAppManifest, WebAppProcessManager) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-webapp-process-\(label)-\(UUID().uuidString)", isDirectory: true)
        let store = WebAppStore(cwd: root.path)
        let manifest = try store.create(
            name: "Backend Test",
            description: "",
            html: "<html><body>backend test</body></html>",
            backendType: "python",
            backendCode: Self.pythonBackend
        )
        return (store, manifest, WebAppProcessManager(cwd: root.path))
    }

    func testResolveExecutableFindsPython() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            "python3 is not available on this machine"
        )
        let path = try WebAppProcessManager.resolveExecutable(type: "python")
        XCTAssertTrue(path.hasSuffix("python3"))
        XCTAssertThrowsError(try WebAppProcessManager.resolveExecutable(type: "ruby"))
    }

    func testCreateWithBackendWritesScriptAndRuntimeManifest() throws {
        let (store, manifest, _) = try makeBackendApp("manifest")

        XCTAssertEqual(manifest.runtime?.type, "python")
        XCTAssertEqual(manifest.runtime?.entry, "backend/server.py")
        let script = try String(
            contentsOf: store.appDirectory(id: manifest.id).appendingPathComponent("backend/server.py"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("serve_forever"))
        XCTAssertEqual(store.manifest(id: manifest.id)?.runtime?.type, "python")
    }

    func testEnsureRunningStartsBackendAndStopKillsIt() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            "python3 is not available on this machine"
        )
        let (store, manifest, manager) = try makeBackendApp("lifecycle")
        defer { manager.stopAll() }

        let port = try manager.ensureRunning(app: manifest, store: store)
        XCTAssertEqual(manager.backendPort(appID: manifest.id), port)

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/hello"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["message"] as? String, "from backend")
        XCTAssertEqual(object["app"] as? String, manifest.id)

        // Same app reuses the running process.
        XCTAssertEqual(try manager.ensureRunning(app: manifest, store: store), port)

        manager.stop(appID: manifest.id)
        XCTAssertNil(manager.backendPort(appID: manifest.id))
    }

    func testBackendReachesSQLiteThroughEnvironment() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            "python3 is not available on this machine"
        )
        let (store, manifest, manager) = try makeBackendApp("sqlite")
        defer { manager.stopAll() }

        let port = try manager.ensureRunning(app: manifest, store: store)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/db"))
        let (data, _) = try await URLSession.shared.data(from: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["pings"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL(id: manifest.id).path))
    }

    func testProxyRoutesBackendThroughMainServerWithToken() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            "python3 is not available on this machine"
        )
        let (store, manifest, manager) = try makeBackendApp("proxy")
        defer { manager.stopAll() }
        let server = LocalWebAppServer()
        try server.start(store: store, processManager: manager)
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let token = server.token(for: manifest.id)

        // Without token the proxy refuses.
        let bare = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/apps/\(manifest.id)/backend/hello"))
        let (_, bareResponse) = try await URLSession.shared.data(from: bare)
        XCTAssertEqual((bareResponse as? HTTPURLResponse)?.statusCode, 401)

        // With token it reaches the backend process.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/apps/\(manifest.id)/backend/hello?token=\(token)"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["message"] as? String, "from backend")
    }

    func testPageFetchToBackendRouteWithoutBackendPrefixAuthedByReferer() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            "python3 is not available on this machine"
        )
        let (store, manifest, manager) = try makeBackendApp("apiroute")
        defer { manager.stopAll() }
        let server = LocalWebAppServer()
        try server.start(store: store, processManager: manager)
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let token = server.token(for: manifest.id)
        let pageURL = "http://127.0.0.1:\(port)/apps/\(manifest.id)/?token=\(token)"

        // A page's own fetch('hello') — no 'backend/' prefix, no token in the
        // query — must reach the backend, authenticated by the page Referer
        // (this is exactly the shape the stock app used: fetch('api/quote')).
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/apps/\(manifest.id)/hello")))
        request.setValue(pageURL, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "a bare backend-route fetch should proxy to the backend, not 404 File not found")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["message"] as? String, "from backend")

        // No token anywhere (no query, no referer) is still refused.
        let anon = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/apps/\(manifest.id)/hello"))
        let (_, anonResponse) = try await URLSession.shared.data(from: anon)
        XCTAssertEqual((anonResponse as? HTTPURLResponse)?.statusCode, 401)
    }
}
