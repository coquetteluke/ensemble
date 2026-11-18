import SwiftUI
import WebKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Agents can draw inline visuals with a fenced ```widget block (self-contained HTML, SVG, CSS and JS).
// They render in a locked-down web view: no network (Content Security Policy plus a content blocker
// that only lets data:, blob: and about: through), no navigation, no pop-ups, nothing persisted.
// Plain ```svg blocks use the same view with scripts off.

/// The page a widget is shown in: the agent's markup plus the security policy and Ensemble's colours.
public enum WidgetDocument {
    public enum Kind: Sendable { case html, svg }

    /// Content Security Policy for widgets. Scripts may run inline only (never from a URL); nothing can be fetched.
    public static func contentSecurityPolicy(scripts: Bool) -> String {
        [
            "default-src 'none'",
            "script-src \(scripts ? "'unsafe-inline'" : "'none'")",
            "style-src 'unsafe-inline'",
            "img-src data: blob:",
            "font-src data:",
            "media-src data: blob:",
            "connect-src 'none'",
            "frame-src 'none'",
            "worker-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
        ].joined(separator: "; ")
    }

    /// CSS variables agents can use (`var(--fg)`, `var(--accent)`, ...) so widgets match the app.
    public static func themeCSS(_ theme: Theme) -> String {
        """
        :root {
          color-scheme: \(theme.isDark ? "dark" : "light");
          --bg: \(css(theme.background)); --surface: \(css(theme.elevated)); --code-bg: \(css(theme.codeBackground));
          --fg: \(css(theme.textPrimary)); --muted: \(css(theme.textSecondary)); --faint: \(css(theme.textTertiary));
          --border: \(css(theme.border)); --accent: \(css(theme.accent)); --danger: \(css(theme.danger));
          --success: \(css(theme.success)); --warning: \(css(theme.warning));
          --blue: \(css(theme.contextBlue)); --orange: \(css(theme.contextOrange)); --teal: \(css(theme.contextTeal));
          --amber: \(css(theme.contextAmber));
          --font-sans: -apple-system, system-ui, sans-serif; --font-mono: ui-monospace, "SF Mono", monospace;
        }
        html, body { margin: 0; padding: 0; background: \(css(theme.codeBackground)); color: var(--fg);
          font: 14px/1.45 var(--font-sans); -webkit-font-smoothing: antialiased; }
        body { padding: 14px; overflow-y: hidden; }
        svg, img, canvas { max-width: 100%; height: auto; }
        """
    }

    /// The full HTML document for a widget.
    public static func html(for source: String, kind: Kind, theme: Theme) -> String {
        let head = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(scripts: kind == .html))">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(themeCSS(theme))</style>
        """
        let lower = source.lowercased()
        if kind == .html, lower.contains("<html") {
            // A whole page: put the policy first in its head so it applies before anything else.
            if let range = source.range(of: "<head>", options: .caseInsensitive) {
                return source.replacingCharacters(in: range, with: "<head>" + head)
            }
            if let range = source.range(of: "<html", options: .caseInsensitive),
               let close = source[range.upperBound...].firstIndex(of: ">") {
                let insertAt = source.index(after: close)
                return String(source[..<insertAt]) + "<head>\(head)</head>" + String(source[insertAt...])
            }
        }
        return "<!doctype html><html><head>\(head)</head><body>\(source)</body></html>"
    }

    static func css(_ color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ value: Float) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        if resolved.opacity < 0.999 {
            return "rgba(\(byte(resolved.red)), \(byte(resolved.green)), \(byte(resolved.blue)), \(String(format: "%.2f", resolved.opacity)))"
        }
        return String(format: "#%02X%02X%02X", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
    }

    /// Blocks every request except data:, blob: and about: (defence in depth behind the policy).
    static let blockerRules = """
    [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "^(data|blob|about):"}, "action": {"type": "ignore-previous-rules"}}]
    """
}

/// An inline widget (or SVG image) with a toolbar: Open in browser and Copy.
public struct WidgetBlockView: View {
    let source: String
    let kind: WidgetDocument.Kind
    /// True while the message is still streaming.
    let pending: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var height: CGFloat = 120
    @State private var copied = false

    public init(source: String, kind: WidgetDocument.Kind, pending: Bool = false) {
        self.source = source
        self.kind = kind
        self.pending = pending
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            HLine()
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.codeBackground))
        .clipShape(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
    }

    private var toolbar: some View {
        HStack(spacing: theme.z(12)) {
            Image(systemName: kind == .svg ? "photo" : "rectangle.3.group")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
            Text(kind == .svg ? "SVG" : "Widget")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            #if os(macOS)
            Button {
                openInBrowser()
            } label: {
                Label("Open in browser", systemImage: "safari")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(theme.font(size: 11.5))
            .foregroundStyle(theme.textTertiary)
            .help("Open this widget in your browser")
            .disabled(pending)
            #endif
            Button {
                copyToPasteboard(source)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(theme.font(size: 11.5))
            .foregroundStyle(copied ? theme.success : theme.textTertiary)
            .help("Copy the source")
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(7))
    }

    @ViewBuilder private var content: some View {
        if pending {
            HStack(spacing: theme.z(8)) {
                Spinner(size: 11)
                Text(kind == .svg ? "Drawing" : "Building the widget")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: theme.z(80))
        } else if isSnapshot {
            // Web views cannot be drawn by ImageRenderer; snapshots show the frame only.
            Image(systemName: kind == .svg ? "photo" : "rectangle.3.group")
                .font(theme.font(size: 22, weight: .light))
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: theme.z(140))
        } else {
            WidgetWebView(html: WidgetDocument.html(for: source, kind: kind, theme: theme), kind: kind,
                          zoom: theme.scale, height: $height)
                .frame(height: min(max(height, theme.z(24)), theme.z(1400)))
        }
    }

    #if os(macOS)
    private func openInBrowser() {
        let html = WidgetDocument.html(for: source, kind: kind, theme: theme)
        let name = "ensemble-widget-\(UUID().uuidString.prefix(8)).html"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
    #endif
}

// MARK: - Web view

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// The sandboxed WKWebView behind a widget. Reports its content height so the transcript can size it.
struct WidgetWebView: PlatformViewRepresentable {
    let html: String
    let kind: WidgetDocument.Kind
    let zoom: CGFloat
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = kind == .html
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // The size reporter runs in the app's own script world, so the page cannot see or change it,
        // and the page's policy (scripts off for SVG) does not stop it.
        let reporter = WKUserScript(source: Self.sizeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(reporter)
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), contentWorld: .defaultClient, name: "ensembleSize")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.pageZoom = zoom
        #if os(macOS)
        webView.alphaValue = 0
        #else
        webView.alpha = 0
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        #endif
        context.coordinator.load(html, into: webView)
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        if context.coordinator.loadedHTML != html { context.coordinator.load(html, into: webView) }
    }

    static func dismantleCoordinator(_ coordinator: Coordinator) {}

    static let sizeScript = """
    (function () {
      function report() {
        var h = Math.ceil(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0));
        window.webkit.messageHandlers.ensembleSize.postMessage(h);
      }
      report();
      if (window.ResizeObserver && document.body) { new ResizeObserver(report).observe(document.body); }
      window.addEventListener('load', report);
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var loadedHTML: String?

        init(height: Binding<CGFloat>) { self.height = height }

        func load(_ html: String, into webView: WKWebView) {
            loadedHTML = html
            Task { @MainActor in
                if let rules = await WidgetBlocker.shared.rules() {
                    webView.configuration.userContentController.removeAllContentRuleLists()
                    webView.configuration.userContentController.add(rules)
                    webView.loadHTMLString(html, baseURL: nil)
                }
                // Without the blocker the widget is not shown at all; the policy alone is not trusted.
            }
        }

        // Only the initial document may load; links, redirects and frames are refused.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? "about:blank"
            let initial = navigationAction.navigationType == .other && (url == "about:blank" || url.hasPrefix("about:"))
            decisionHandler(initial ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if os(macOS)
            webView.alphaValue = 1
            #else
            webView.alpha = 1
            #endif
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double ?? (message.body as? Int).map(Double.init) else { return }
            let zoom = message.webView?.pageZoom ?? 1
            let newHeight = CGFloat(value) * zoom
            if abs(height.wrappedValue - newHeight) > 1 { height.wrappedValue = newHeight }
        }
    }
}

/// Avoids the retain cycle between the content controller and the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Compiles the network blocker once and shares it between widgets.
@MainActor
final class WidgetBlocker {
    static let shared = WidgetBlocker()
    private var compiled: WKContentRuleList?
    private var waiting: [CheckedContinuation<WKContentRuleList?, Never>] = []
    private var compiling = false

    func rules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard !compiling else { return }
            compiling = true
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ensemble-widget-blocker", encodedContentRuleList: WidgetDocument.blockerRules
            ) { list, _ in
                MainActor.assumeIsolated {
                    self.compiled = list
                    self.compiling = false
                    let continuations = self.waiting
                    self.waiting.removeAll()
                    for continuation in continuations { continuation.resume(returning: list) }
                }
            }
        }
    }
}
