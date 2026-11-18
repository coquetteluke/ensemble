#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import EnsembleKit

/// The real widget web view: the wrapper loads, the sandboxed frame renders and reports its height,
/// and page scripts run for widgets but not for SVG.
@MainActor
@Suite(.serialized) struct StoreWidgetWebViewTests {
    /// The div is 50 px tall unless the page's script runs and makes it 400 px.
    static let page = """
    <div id="box" style="height:50px;background:var(--accent)"></div>
    <script>document.getElementById('box').style.height = '400px';</script>
    """

    private final class HeightBox {
        var value: CGFloat = 0
    }

    /// Loads `html` in a widget web view inside a window that is never shown and returns the first
    /// height the frame reports (0 if none arrives in time).
    private func renderedHeight(_ html: String) async -> CGFloat {
        _ = NSApplication.shared
        let box = HeightBox()
        let coordinator = WidgetWebView.Coordinator(height: Binding(get: { box.value }, set: { box.value = $0 }))
        let webView = WidgetWebView.makeWebView(coordinator: coordinator, zoom: 1, scrolls: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        coordinator.load(html, into: webView)
        // WebKit answers through the main run loop and the blocker through the main actor; give both turns.
        let deadline = Date().addingTimeInterval(20)
        while box.value == 0, Date() < deadline {
            spin(0.05)
            await Task.yield()
        }
        window.close()
        return box.value
    }

    /// Runs the main run loop (WebKit answers through it) between turns of the main actor.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test func aWidgetRunsItsScriptAndSizesToItsContent() async {
        let height = await renderedHeight(WidgetDocument.html(for: Self.page, kind: .html, theme: .dark))
        // 400 px box plus 14 px padding above and below.
        #expect(abs(height - 428) <= 2, "got \(height)")
    }

    @Test func svgPagesDoNotRunScripts() async {
        let height = await renderedHeight(WidgetDocument.html(for: Self.page, kind: .svg, theme: .dark))
        #expect(abs(height - 78) <= 2, "got \(height)")
    }
}
#endif
