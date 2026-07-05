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

    final class Coordinator {
        var loadedURL: URL?
    }
}
