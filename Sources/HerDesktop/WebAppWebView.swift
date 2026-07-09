import AppKit
import SwiftUI
import WebKit

/// Embeds a loopback-hosted web app page. Reloads when the URL changes.
/// Full pages keep an opaque canvas (apps may rely on the default white
/// background); widgets opt into transparency to blend with their card.
struct WebAppWebView: NSViewRepresentable {
    var url: URL
    var transparent = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        if transparent {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    /// WKWebView has no built-in UI for JavaScript dialogs — without these
    /// three delegate methods, alert()/confirm()/prompt() in generated web
    /// apps silently do nothing (confirm resolves false, prompt nil).
    final class Coordinator: NSObject, WKUIDelegate {
        var loadedURL: URL?

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = Self.makePanel(message: message)
            alert.addButton(withTitle: "好")
            Self.present(alert, over: webView) { _ in completionHandler() }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = Self.makePanel(message: message)
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            Self.present(alert, over: webView) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = Self.makePanel(message: prompt)
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            Self.present(alert, over: webView) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }

        private static func makePanel(message: String) -> NSAlert {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = message
            return alert
        }

        /// Sheet on the hosting window when there is one (embedded widgets
        /// and pages); app-modal fallback keeps the JS promise resolving
        /// even for a not-yet-attached view.
        private static func present(
            _ alert: NSAlert,
            over webView: WKWebView,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }
    }
}
