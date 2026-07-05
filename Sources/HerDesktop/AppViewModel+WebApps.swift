import AppKit
import Foundation
import SwiftUI

/// Local mini web apps: loopback hosting, SQLite-backed, vibe-coded
/// through the webapp.* capabilities.
extension AppViewModel {
    func startWebAppServerIfNeeded() {
        guard !webAppServer.isRunning else { return }
        do {
            try webAppServer.start(store: webAppStore, processManager: webAppProcessManager)
            audit(
                type: "webapp.server_started",
                summary: "Local web app server is listening on loopback.",
                metadata: ["port": webAppServer.port.map(String.init) ?? "unknown"]
            )
        } catch {
            audit(type: "webapp.server_start_failed", summary: error.localizedDescription)
        }
    }

    func refreshWebApps() {
        webApps = webAppStore.loadAll()
        if let selected = selectedWebAppID, !webApps.contains(where: { $0.id == selected }) {
            selectedWebAppID = nil
        }
    }

    func webAppURL(_ id: String) -> URL? {
        startWebAppServerIfNeeded()
        return webAppServer.url(for: id)
    }

    func webAppWidgetURL(_ id: String) -> URL? {
        guard let app = webApps.first(where: { $0.id == id }), let widget = app.widget else {
            return nil
        }
        startWebAppServerIfNeeded()
        return webAppServer.url(for: id, page: widget.entry)
    }

    /// Installed apps a message refers to (via capability results or URLs),
    /// used to attach live widget cards in the conversation.
    func webAppReferences(for message: ChatMessage) -> [WebAppManifest] {
        guard message.role == .tool || message.role == .assistant, !webApps.isEmpty else {
            return []
        }
        return webApps.filter { app in
            message.content.contains("app_id: \(app.id)")
                || message.content.contains("apps/\(app.id)/")
        }
    }

    /// Live widgets only render inside a recent window of the transcript
    /// so long conversations don't accumulate web views.
    func isRecentMessage(_ id: UUID) -> Bool {
        messages.suffix(12).contains { $0.id == id }
    }

    func openWebApp(_ id: String) {
        guard webApps.contains(where: { $0.id == id }) else { return }
        selectedWebAppID = id
        selectedSection = .apps
    }

    func openWebAppInBrowser(_ id: String) {
        guard let url = webAppURL(id) else { return }
        NSWorkspace.shared.open(url)
        audit(type: "webapp.opened_in_browser", summary: "Opened web app in the default browser.", metadata: ["appID": id])
    }

    var pinnedWebApps: [WebAppManifest] {
        webApps.filter(\.isPinned)
    }

    func togglePinWebApp(_ id: String) {
        do {
            let manifest = try webAppStore.togglePin(id: id)
            refreshWebApps()
            audit(
                type: manifest.isPinned ? "webapp.pinned" : "webapp.unpinned",
                summary: manifest.isPinned
                    ? "Pinned web app to the widget panel."
                    : "Unpinned web app from the widget panel.",
                metadata: ["appID": id]
            )
        } catch {
            lastError = "Could not update the pin state: \(error.localizedDescription)"
        }
    }

    func removeWebApp(_ id: String) {
        do {
            webAppProcessManager.stop(appID: id)
            try webAppStore.remove(id: id)
            refreshWebApps()
            audit(type: "webapp.removed", summary: "Removed local web app.", metadata: ["appID": id])
        } catch {
            lastError = "Could not remove the web app: \(error.localizedDescription)"
        }
    }

    // MARK: - Capability implementations

    func createWebAppCapability(arguments: [String: Any]) -> CapabilityResult {
        let name = stringArgument(arguments, keys: ["name", "title"], fallback: "")
        let html = stringArgument(arguments, keys: ["html", "content"], fallback: "")
        let description = stringArgument(arguments, keys: ["description", "summary"], fallback: "")
        guard !name.isEmpty, !html.isEmpty else {
            return CapabilityResult(
                title: "Web App Creation Failed",
                content: "webapp.create requires name and html arguments.",
                requiresUserApproval: false
            )
        }
        let backendType = stringArgument(arguments, keys: ["backend_type", "backendType", "runtime"], fallback: "")
        let backendCode = stringArgument(arguments, keys: ["backend_code", "backendCode"], fallback: "")
        let widgetHTML = stringArgument(arguments, keys: ["widget_html", "widgetHTML"], fallback: "")
        let widgetHeight = integerArgument(arguments, keys: ["widget_height", "widgetHeight"], fallback: 0)
        let llmsTxt = stringArgument(arguments, keys: ["llms_txt", "llmsTxt"], fallback: "")
        do {
            let manifest = try webAppStore.create(
                name: name,
                description: description,
                html: html,
                backendType: backendType.isEmpty ? nil : backendType,
                backendCode: backendCode.isEmpty ? nil : backendCode,
                widgetHTML: widgetHTML.isEmpty ? nil : widgetHTML,
                widgetHeight: widgetHeight > 0 ? Double(widgetHeight) : nil,
                llmsTxt: llmsTxt.isEmpty ? nil : llmsTxt
            )
            refreshWebApps()
            audit(
                type: "webapp.created",
                summary: "Created local web app \(manifest.name).",
                metadata: [
                    "appID": manifest.id,
                    "htmlBytes": String(html.utf8.count),
                    "runtime": manifest.runtime?.type ?? "static"
                ]
            )
            let url = webAppURL(manifest.id)?.absoluteString ?? "unavailable"
            let backendLine = manifest.runtime.map {
                "backend: \($0.type) process (\($0.entry)); the page reaches it via fetch('backend/...?token=' + token)."
            } ?? "backend: none (static + SQLite API)."
            return CapabilityResult(
                title: "Web App Created",
                content: """
                Created local web app "\(manifest.name)".
                app_id: \(manifest.id)
                local_url: \(url)
                storage: \(webAppStore.appDirectory(id: manifest.id).path)
                \(backendLine)
                Call webapp.open with app_id \(manifest.id) to show it to the user.
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Web App Creation Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func updateWebAppCapability(arguments: [String: Any]) -> CapabilityResult {
        let appID = stringArgument(arguments, keys: ["app_id", "appID", "id"], fallback: "")
        let html = stringArgument(arguments, keys: ["html", "content"], fallback: "")
        guard !appID.isEmpty, !html.isEmpty else {
            return CapabilityResult(
                title: "Web App Update Failed",
                content: "webapp.update requires app_id and html arguments.",
                requiresUserApproval: false
            )
        }
        let name = stringArgument(arguments, keys: ["name", "title"], fallback: "")
        let description = stringArgument(arguments, keys: ["description", "summary"], fallback: "")
        let backendType = stringArgument(arguments, keys: ["backend_type", "backendType", "runtime"], fallback: "")
        let backendCode = stringArgument(arguments, keys: ["backend_code", "backendCode"], fallback: "")
        let widgetHTML = stringArgument(arguments, keys: ["widget_html", "widgetHTML"], fallback: "")
        let widgetHeight = integerArgument(arguments, keys: ["widget_height", "widgetHeight"], fallback: 0)
        let llmsTxt = stringArgument(arguments, keys: ["llms_txt", "llmsTxt"], fallback: "")
        do {
            let manifest = try webAppStore.update(
                id: appID,
                html: html,
                name: name.isEmpty ? nil : name,
                description: description.isEmpty ? nil : description,
                backendType: backendType.isEmpty ? nil : backendType,
                backendCode: backendCode.isEmpty ? nil : backendCode,
                widgetHTML: widgetHTML.isEmpty ? nil : widgetHTML,
                widgetHeight: widgetHeight > 0 ? Double(widgetHeight) : nil,
                llmsTxt: llmsTxt.isEmpty ? nil : llmsTxt
            )
            // Restart on next request so replaced backend code takes effect.
            webAppProcessManager.stop(appID: appID)
            refreshWebApps()
            audit(
                type: "webapp.updated",
                summary: "Updated local web app \(manifest.name).",
                metadata: ["appID": manifest.id, "htmlBytes": String(html.utf8.count)]
            )
            return CapabilityResult(
                title: "Web App Updated",
                content: "Updated \"\(manifest.name)\" (app_id: \(manifest.id)). Existing SQLite data is preserved.",
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Web App Update Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func listWebAppsCapability() -> CapabilityResult {
        refreshWebApps()
        guard !webApps.isEmpty else {
            return CapabilityResult(
                title: "Local Web Apps",
                content: "No web apps are installed yet. Create one with webapp.create.",
                requiresUserApproval: false
            )
        }
        let lines = webApps.map { app in
            let url = webAppURL(app.id)?.absoluteString ?? "unavailable"
            return "- \(app.name) (app_id: \(app.id)): \(app.description.isEmpty ? "no description" : app.description) · \(url)"
        }
        return CapabilityResult(
            title: "Local Web Apps",
            content: lines.joined(separator: "\n"),
            requiresUserApproval: false
        )
    }

    func openWebAppCapability(arguments: [String: Any]) -> CapabilityResult {
        let appID = stringArgument(arguments, keys: ["app_id", "appID", "id"], fallback: "")
        guard webApps.contains(where: { $0.id == appID }) else {
            return CapabilityResult(
                title: "Web App Not Found",
                content: "No installed web app has app_id \(appID). Use webapp.list to see installed apps.",
                requiresUserApproval: false
            )
        }
        openWebApp(appID)
        audit(type: "webapp.opened", summary: "Opened web app in the Apps page.", metadata: ["appID": appID])
        return CapabilityResult(
            title: "Web App Opened",
            content: "\(appID) is now visible in the Apps page.",
            requiresUserApproval: false
        )
    }

    // MARK: - Conversation ↔ app data interop

    /// Read-only SQL against an app's SQLite; writes are rejected at the
    /// statement level so this stays approval-free.
    func queryWebAppCapability(arguments: [String: Any]) -> CapabilityResult {
        runWebAppSQL(arguments: arguments, readOnly: true, title: "Web App Query")
    }

    /// Mutating SQL against an app's SQLite; approval-gated by manifest.
    func executeWebAppSQLCapability(arguments: [String: Any]) -> CapabilityResult {
        runWebAppSQL(arguments: arguments, readOnly: false, title: "Web App Execute")
    }

    private func runWebAppSQL(arguments: [String: Any], readOnly: Bool, title: String) -> CapabilityResult {
        let appID = stringArgument(arguments, keys: ["app_id", "appID", "id"], fallback: "")
        let sql = stringArgument(arguments, keys: ["sql", "query"], fallback: "")
        guard webApps.contains(where: { $0.id == appID }), !sql.isEmpty else {
            return CapabilityResult(
                title: "\(title) Failed",
                content: "Requires app_id of an installed web app (see webapp.list) and a sql argument.",
                requiresUserApproval: false
            )
        }
        var params: [JSONValue] = []
        if let raw = arguments["params"],
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) {
            params = decoded
        }
        do {
            let result = try WebAppDatabase.execute(
                sql: sql,
                params: params,
                databaseURL: webAppStore.databaseURL(id: appID),
                requireReadOnly: readOnly
            )
            audit(
                type: readOnly ? "webapp.data_queried" : "webapp.data_executed",
                summary: readOnly ? "Read web app data from the conversation." : "Modified web app data from the conversation.",
                metadata: ["appID": appID, "rows": String(result.rows.count)]
            )
            let cappedRows = Array(result.rows.prefix(100))
            let payload: [String: JSONValue] = [
                "columns": .array(result.columns.map { .string($0) }),
                "rows": .array(cappedRows.map { .array($0) }),
                "row_count": .number(Double(result.rows.count)),
                "rows_changed": .number(Double(result.rowsChanged)),
                "last_insert_row_id": .number(Double(result.lastInsertRowID))
            ]
            let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let truncationNote = result.rows.count > 100 ? "\n(showing first 100 of \(result.rows.count) rows)" : ""
            return CapabilityResult(
                title: title,
                content: json + truncationNote,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "\(title) Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    /// The app's llms.txt plus live table schemas — everything the model
    /// needs before touching an app's data.
    func inspectWebAppCapability(arguments: [String: Any]) -> CapabilityResult {
        let appID = stringArgument(arguments, keys: ["app_id", "appID", "id"], fallback: "")
        guard let app = webApps.first(where: { $0.id == appID }) else {
            return CapabilityResult(
                title: "Web App Not Found",
                content: "No installed web app has app_id \(appID). Use webapp.list first.",
                requiresUserApproval: false
            )
        }
        var lines = [
            "name: \(app.name)",
            "app_id: \(app.id)",
            "description: \(app.description)",
            "runtime: \(app.runtime.map { "\($0.type) (\($0.entry))" } ?? "static")",
            "widget: \(app.widget != nil ? "yes" : "no")"
        ]
        let schema = (try? WebAppDatabase.execute(
            sql: "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%'",
            databaseURL: webAppStore.databaseURL(id: appID),
            requireReadOnly: true
        )) ?? WebAppDatabase.QueryResult(columns: [], rows: [], rowsChanged: 0, lastInsertRowID: 0)
        if schema.rows.isEmpty {
            lines.append("schema: (no tables yet)")
        } else {
            lines.append("schema:")
            for row in schema.rows {
                if case .string(let ddl) = row.last ?? .null {
                    lines.append("  \(ddl)")
                }
            }
        }
        if let llms = webAppStore.llmsTxt(id: appID) {
            lines.append("llms.txt:\n\(llms)")
        } else {
            lines.append("llms.txt: (none — infer usage from the schema)")
        }
        audit(type: "webapp.inspected", summary: "Inspected web app contract from the conversation.", metadata: ["appID": appID])
        return CapabilityResult(
            title: "Web App Contract",
            content: lines.joined(separator: "\n"),
            requiresUserApproval: false
        )
    }

    /// Calls a route on the app's backend process (starting it if needed).
    func requestWebAppBackendCapability(arguments: [String: Any]) async -> CapabilityResult {
        let appID = stringArgument(arguments, keys: ["app_id", "appID", "id"], fallback: "")
        let path = stringArgument(arguments, keys: ["path", "route"], fallback: "")
        let method = stringArgument(arguments, keys: ["method"], fallback: "GET").uppercased()
        let body = stringArgument(arguments, keys: ["body"], fallback: "")
        guard let app = webApps.first(where: { $0.id == appID }), app.runtime != nil else {
            return CapabilityResult(
                title: "Web App Request Failed",
                content: "App \(appID) is not installed or has no backend runtime.",
                requiresUserApproval: false
            )
        }
        do {
            let store = webAppStore
            let manager = webAppProcessManager
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try manager.ensureRunning(app: app, store: store))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard let url = URL(string: "http://127.0.0.1:\(port)/\(cleanPath)") else {
                return CapabilityResult(title: "Web App Request Failed", content: "Invalid path.", requiresUserApproval: false)
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            if !body.isEmpty {
                request.httpBody = Data(body.utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var text = String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
            if text.count > 6_000 {
                text = String(text.prefix(6_000)) + "\n...(truncated)"
            }
            audit(
                type: "webapp.backend_requested",
                summary: "Called web app backend from the conversation.",
                metadata: ["appID": appID, "path": cleanPath, "status": String(status)]
            )
            return CapabilityResult(
                title: "Web App Backend Response (\(status))",
                content: text,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Web App Request Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func removeWebAppCapability(arguments: [String: Any]) -> CapabilityResult {
        let appID = stringArgument(arguments, keys: ["app_id", "appID", "id"], fallback: "")
        do {
            webAppProcessManager.stop(appID: appID)
            try webAppStore.remove(id: appID)
            refreshWebApps()
            audit(type: "webapp.removed", summary: "Removed local web app.", metadata: ["appID": appID])
            return CapabilityResult(
                title: "Web App Removed",
                content: "Removed web app \(appID) and its local data.",
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Web App Removal Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }
}
