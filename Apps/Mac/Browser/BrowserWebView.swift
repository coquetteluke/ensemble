import SwiftUI
import AppKit
import WebKit
import EnsembleKit

/// Hosts a page's web view. The web view belongs to the page (so switching sessions keeps each page as it was); this
/// view only holds it in a container while it is on screen.
struct BrowserWebView: NSViewRepresentable {
    let page: BrowserPage
    let pageZoom: CGFloat
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let webView = page.webView
        if webView.superview !== container { attach(to: container) }
        if abs(webView.pageZoom - pageZoom) > 0.001 { webView.pageZoom = pageZoom }
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if webView.appearance?.name != appearance?.name { webView.appearance = appearance }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for child in container.subviews where child is WKWebView { child.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let webView = page.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
