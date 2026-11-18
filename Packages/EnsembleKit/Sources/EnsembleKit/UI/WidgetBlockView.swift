import SwiftUI
import WebKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Agents can draw inline visuals with a fenced ```widget block (self-contained HTML, SVG, CSS and JS).
// The agent's markup is never edited or spliced into: Ensemble loads its own wrapper page, whose first
// element is a strict Content Security Policy, and the markup runs inside a sandboxed iframe (`srcdoc`,
// opaque origin, no same-origin access) that inherits that policy. Behind it, a content blocker drops
// every load that is not data:, blob: or about:, the navigation delegate refuses everything but the
// wrapper and its frame, pop-ups are refused, and nothing is persisted.
// Plain ```svg blocks are drawn as images (the same wrapper with scripts off where AppKit cannot decode them).

/// The page a widget is shown in: Ensemble's wrapper with the policy first and the agent's markup in a
/// sandboxed frame, plus Ensemble's colours as CSS variables.
public enum WidgetDocument {
    public enum Kind: Sendable { case html, svg }

    /// Content Security Policy for widgets. Scripts may run inline only (never from a URL); nothing can be
    /// fetched, framed, submitted or used as a base URL.
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
            "child-src 'none'",
            "worker-src 'none'",
            "manifest-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
        ].joined(separator: "; ")
    }

    /// The policy as the first element of a page's head.
    static func policyMeta(scripts: Bool) -> String {
        #"<meta http-equiv="Content-Security-Policy" content="\#(contentSecurityPolicy(scripts: scripts))">"#
    }

    /// CSS variables agents can use (`var(--fg)`, `var(--accent)`, ...) so widgets match the app.
    /// `scrolls` is for a visual opened in its own window; inline ones size to their content instead.
    public static func themeCSS(_ theme: Theme, scrolls: Bool = false) -> String {
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
        body { padding: 14px; overflow-y: \(scrolls ? "auto" : "hidden"); }
        svg, img, canvas { max-width: 100%; height: auto; }
        """
    }

    /// The page to load: Ensemble's wrapper. Its first element is the policy; the agent's markup only
    /// appears, escaped, in the sandboxed frame's `srcdoc`.
    public static func html(for source: String, kind: Kind, theme: Theme, scrolls: Bool = false) -> String {
        let scripts = kind == .html
        let frame = frameDocument(for: source, scripts: scripts, theme: theme, scrolls: scrolls)
        return "<!doctype html><html><head>" + policyMeta(scripts: scripts)
            + #"<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">"#
            + "<style>\(wrapperCSS(theme))</style></head><body>"
            + #"<iframe sandbox="\#(scripts ? "allow-scripts" : "")" title="Visual" srcdoc="\#(escapeAttribute(frame))"></iframe>"#
            + "</body></html>"
    }

    /// The document inside the frame: the policy again, the theme, then the agent's markup as the body.
    /// (A full page from the agent nests harmlessly; the parser folds its html, head and body tags.)
    static func frameDocument(for source: String, scripts: Bool, theme: Theme, scrolls: Bool) -> String {
        "<!doctype html><html><head>" + policyMeta(scripts: scripts) + #"<meta charset="utf-8">"#
            + "<style>\(themeCSS(theme, scrolls: scrolls))</style></head><body>" + source + "</body></html>"
    }

    /// The wrapper only holds the frame, sized to fill the web view.
    static func wrapperCSS(_ theme: Theme) -> String {
        "html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; background: \(css(theme.codeBackground)); "
            + "color-scheme: \(theme.isDark ? "dark" : "light"); } "
            + "iframe { display: block; border: 0; width: 100%; height: 100%; }"
    }

    /// Escapes text for a double-quoted attribute value, so markup cannot end the attribute or the frame.
    static func escapeAttribute(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count + text.utf8.count / 8)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
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
    /// One rule per scheme: content blockers do not accept alternation in `url-filter`.
    static let blockerRules = """
    [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
     {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
     {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}]
    """

    /// The only pages a widget's web view may load: the wrapper and its frame.
    static func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
    }
}

/// An inline visual from a ```widget block, under a "Made a visual" row: the chevron collapses it, the
/// buttons open it in its own window and copy its source.
public struct WidgetBlockView: View {
    let source: String
    /// True while the block may still be arriving (the message is streaming and this is its last block).
    let pending: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var collapsed: Bool
    @State private var height: CGFloat = 120
    @State private var copied = false
    @State private var hovering = false
    #if !os(macOS)
    @State private var showFull = false
    #endif

    public init(source: String, pending: Bool = false, collapsed: Bool = false) {
        self.source = source
        self.pending = pending
        self._collapsed = State(initialValue: collapsed)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            header
            if !collapsed && !pending {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous).fill(theme.codeBackground))
                    .clipShape(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                    .transition(.opacity)
            }
        }
        #if !os(macOS)
        .sheet(isPresented: $showFull) {
            WidgetFullView(source: source, theme: theme) { showFull = false }
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: theme.z(4)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                HStack(spacing: theme.z(8)) {
                    if pending {
                        Spinner(size: 11).frame(width: theme.z(16))
                    } else {
                        Image(systemName: "rectangle.3.group")
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: theme.z(16))
                    }
                    Text(pending ? "Making a visual" : "Made a visual")
                        .font(theme.font(size: 13))
                        .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                    if !pending {
                        Image(systemName: "chevron.down")
                            .font(theme.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                    }
                }
                .frame(minHeight: theme.z(22))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pending)
            .onHover { hovering = $0 }
            .help(collapsed ? "Show the visual" : "Hide the visual")
            .accessibilityLabel(pending ? "Making a visual" : "Made a visual")
            .accessibilityHint(collapsed ? "Shows the visual" : "Hides the visual")

            Spacer(minLength: theme.z(8))

            if !pending {
                MessageActionButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open in a window", enabled: true) {
                    #if os(macOS)
                    WidgetWindows.show(source: source, theme: theme)
                    #else
                    showFull = true
                    #endif
                }
                MessageActionButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy the source", enabled: true) {
                    copyToPasteboard(source)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isSnapshot {
            // Web views cannot be drawn by ImageRenderer; snapshots show the frame only.
            Image(systemName: "rectangle.3.group")
                .font(theme.font(size: 22, weight: .light))
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: theme.z(140))
        } else {
            WidgetWebView(html: WidgetDocument.html(for: source, kind: .html, theme: theme), kind: .html,
                          zoom: theme.scale, scrolls: false, height: $height)
                .frame(height: min(max(height, theme.z(24)), theme.z(1400)))
        }
    }
}

/// A ```svg block drawn as an image. On the Mac it is decoded by AppKit (no scripts, nothing fetched);
/// elsewhere it goes through the widget web view with scripts off.
public struct SVGBlockView: View {
    let source: String
    let pending: Bool
    @Environment(\.theme) private var theme
    @State private var height: CGFloat = 120

    public init(source: String, pending: Bool = false) {
        self.source = source
        self.pending = pending
    }

    public var body: some View {
        if pending {
            HStack(spacing: theme.z(8)) {
                Spinner(size: 11).frame(width: theme.z(16))
                Text("Drawing an image")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(minHeight: theme.z(22))
        } else {
            image
                .contextMenu {
                    Button("Copy SVG") { copyToPasteboard(source) }
                    #if os(macOS)
                    Button("Open in a Window") { WidgetWindows.show(source: source, kind: .svg, theme: theme) }
                    #endif
                }
                .accessibilityLabel("Image")
        }
    }

    @ViewBuilder private var image: some View {
        #if os(macOS)
        if let decoded = SVGImageCache.image(for: source) {
            let size = decoded.size
            Image(nsImage: decoded)
                .resizable()
                .interpolation(.high)
                .aspectRatio(size.width / size.height, contentMode: .fit)
                .frame(maxWidth: theme.z(size.width), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            webImage
        }
        #else
        webImage
        #endif
    }

    private var webImage: some View {
        WidgetWebView(html: WidgetDocument.html(for: source, kind: .svg, theme: theme), kind: .svg,
                      zoom: theme.scale, scrolls: false, height: $height)
            .frame(height: min(max(height, theme.z(24)), theme.z(1400)))
            .clipShape(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous))
    }
}

#if os(macOS)
/// Decoded SVG images by source, so redraws do not parse the markup again.
@MainActor
enum SVGImageCache {
    private static var images: [String: NSImage] = [:]

    static func image(for source: String) -> NSImage? {
        if let cached = images[source] { return cached }
        guard let image = NSImage(data: Data(source.utf8)), image.size.width > 0, image.size.height > 0 else { return nil }
        if images.count > 64 { images.removeAll() }
        images[source] = image
        return image
    }
}

/// Opens a visual in its own resizable window (the same locked-down web view, scrolling allowed).
@MainActor
enum WidgetWindows {
    private static var open: [NSWindow: WindowCloser] = [:]

    static func show(source: String, kind: WidgetDocument.Kind = .html, theme: Theme) {
        let content = WidgetWebView(html: WidgetDocument.html(for: source, kind: kind, theme: theme, scrolls: true), kind: kind,
                                    zoom: theme.scale, scrolls: true, height: .constant(0))
            .frame(minWidth: 320, minHeight: 240)
            .background(theme.codeBackground)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Visual"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 680))
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        let closer = WindowCloser()
        window.delegate = closer
        open[window] = closer
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    fileprivate static func closed(_ window: NSWindow) {
        open[window] = nil
    }

    private final class WindowCloser: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            window.delegate = nil
            WidgetWindows.closed(window)
        }
    }
}
#else
/// The visual filling a sheet, with Done.
struct WidgetFullView: View {
    let source: String
    let theme: Theme
    let done: () -> Void

    var body: some View {
        NavigationStack {
            WidgetWebView(html: WidgetDocument.html(for: source, kind: .html, theme: theme, scrolls: true), kind: .html,
                          zoom: theme.scale, scrolls: true, height: .constant(0))
                .background(theme.codeBackground)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Visual")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                }
        }
    }
}
#endif

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
    /// False inline (the transcript scrolls and the view grows to fit); true in a window of its own.
    var scrolls: Bool = false
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
        let webView = Self.makeWebView(coordinator: context.coordinator, zoom: zoom, scrolls: scrolls)
        context.coordinator.load(html, into: webView)
        return webView
    }

    /// A web view with the widget configuration (nothing stored, no pop-ups, muted media, the size
    /// reporter) wired to `coordinator`. Load pages with `coordinator.load(_:into:)`, which adds the blocker.
    static func makeWebView(coordinator: Coordinator, zoom: CGFloat, scrolls: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Page scripts are governed by the frame: its sandbox and policy allow inline scripts for widgets and
        // none for SVG. (Turning content JavaScript off here would also stop the srcdoc frame loading.)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // The size reporter runs in the app's own script world, in the sandboxed frame, so the page cannot
        // see or change it and its policy and sandbox do not stop it.
        let reporter = WKUserScript(source: Self.sizeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
        configuration.userContentController.addUserScript(reporter)
        configuration.userContentController.add(WeakMessageHandler(coordinator), contentWorld: .defaultClient, name: "ensembleSize")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.pageZoom = zoom
        #if os(macOS)
        webView.alphaValue = 0
        #else
        webView.alpha = 0
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = scrolls
        #endif
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        if context.coordinator.loadedHTML != html { context.coordinator.load(html, into: webView) }
    }

    static func dismantleCoordinator(_ coordinator: Coordinator) {}

    /// Reports the content height from the agent's frame (the wrapper's direct child) only.
    static let sizeScript = """
    (function () {
      if (window.top === window || window.parent !== window.top) { return; }
      function report() {
        var h = document.body ? Math.ceil(document.body.scrollHeight) : 0;
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

        // Only the wrapper and its srcdoc frame may load; links, redirects, form posts and other frames are refused.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let allowed = navigationAction.navigationType == .other && WidgetDocument.allowsNavigation(to: navigationAction.request.url)
            decisionHandler(allowed ? .allow : .cancel)
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
            guard !message.frameInfo.isMainFrame,
                  let value = message.body as? Double ?? (message.body as? Int).map(Double.init) else { return }
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
