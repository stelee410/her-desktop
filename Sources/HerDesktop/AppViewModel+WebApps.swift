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
        do {
            let manifest = try webAppStore.create(
                name: name,
                description: description,
                html: html,
                backendType: backendType.isEmpty ? nil : backendType,
                backendCode: backendCode.isEmpty ? nil : backendCode,
                widgetHTML: widgetHTML.isEmpty ? nil : widgetHTML,
                widgetHeight: widgetHeight > 0 ? Double(widgetHeight) : nil
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
        do {
            let manifest = try webAppStore.update(
                id: appID,
                html: html,
                name: name.isEmpty ? nil : name,
                description: description.isEmpty ? nil : description,
                backendType: backendType.isEmpty ? nil : backendType,
                backendCode: backendCode.isEmpty ? nil : backendCode,
                widgetHTML: widgetHTML.isEmpty ? nil : widgetHTML,
                widgetHeight: widgetHeight > 0 ? Double(widgetHeight) : nil
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
