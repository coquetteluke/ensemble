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

    /// The first height the frame reports, handed to whoever waits for it.
    @MainActor private final class HeightReport {
        private(set) var value: CGFloat = 0
        private var waiter: CheckedContinuation<CGFloat, Never>?

        func set(_ height: CGFloat) {
            value = height
            finish(height)
        }

        /// The first report, or 0 when none arrives within `timeout`.
        func first(timeout: Duration) async -> CGFloat {
            if value != 0 { return value }
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(0)
            }
            defer { timer.cancel() }
            return await withCheckedContinuation { waiter = $0 }
        }

        private func finish(_ height: CGFloat) {
            waiter?.resume(returning: height)
            waiter = nil
        }
    }

    /// Loads `html` in a widget web view inside a window that is never shown and returns the first height the frame
    /// reports (0 if none arrives within `timeout`). Waits for the report itself: while the test waits, the main run
    /// loop delivers WebKit's messages. The timeout is generous because a loaded machine can take many seconds to start
    /// WebKit's processes.
    private func renderedHeight(_ html: String, timeout: Duration = .seconds(180)) async -> CGFloat {
        _ = NSApplication.shared
        // The page loads only once the network blocker is compiled; check it here so a failure says so.
        guard await WidgetBlocker.shared.rules() != nil else {
            Issue.record("The widget network blocker did not compile")
            return 0
        }
        let report = HeightReport()
        let coordinator = WidgetWebView.Coordinator(height: Binding(get: { report.value }, set: { report.set($0) }))
        let webView = WidgetWebView.makeWebView(coordinator: coordinator, zoom: 1, scrolls: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        coordinator.load(html, into: webView)
        let height = await report.first(timeout: timeout)
        window.close()
        return height
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
