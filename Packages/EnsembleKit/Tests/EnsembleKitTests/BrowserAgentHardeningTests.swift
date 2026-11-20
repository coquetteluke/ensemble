#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import EnsembleKit

/// A browser surface whose `agentOpen` plays out a redirect: either it ends up on another origin (`landOn`), or the pane's
/// origin lock blocks it before it loads (`blockTo`). It records the lock the driver set while it opened the page.
@MainActor
final class RedirectingTestSurface: AgentBrowserSurface {
    let agentWebView: WKWebView
    let agentWorld = WKContentWorld.world(name: BrowserScripts.worldName)
    var entries: [AgentBrowserConsoleEntry] = []
    var landOn: URL?
    var blockTo: String?
    private(set) var lock: String?
    private(set) var lockWhileOpening: String?
    private var blocked: String?
    private let window: NSWindow

    init() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        agentWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = agentWebView
    }

    var agentURL: URL? { agentWebView.url }
    var agentConsole: [BrowserConsoleLine] { entries.map(\.line) }
    var agentConsoleEntries: [AgentBrowserConsoleEntry] { entries }
    var agentBlockedNavigationTarget: String? { blocked }

    func agentSetNavigationOriginLock(_ expectedOrigin: String?) {
        lock = expectedOrigin
        if expectedOrigin != nil { blocked = nil }
    }

    func agentOpen(_ url: URL) {
        lockWhileOpening = lock
        if let blockTo {
            blocked = blockTo
            return
        }
        agentWebView.loadHTMLString("<!doctype html><title>Landed</title><p>Landed</p>", baseURL: landOn ?? url)
    }

    func show(at base: URL) async throws {
        agentWebView.loadHTMLString("<!doctype html><title>Start</title><p>Start</p>", baseURL: base)
        try await agentToolsWait("the page to load") { !self.agentWebView.isLoading && self.agentWebView.url?.host() == base.host() }
    }

    func close() { window.close() }
}

/// Regression tests for browser origin isolation (B10) and for "Always for this site" needing a trusted folder (B9).
@Suite(.serialized) @MainActor struct BrowserAgentHardeningTests {
    static let origin = "http://127.0.0.1:8000"

    static func line(_ id: Int, _ text: String, _ level: BrowserConsoleLine.Level = .log) -> BrowserConsoleLine {
        BrowserConsoleLine(id: id, level: level, text: text, source: .page)
    }

    // MARK: Console origin

    @Test func theConsoleOnlyShowsLinesFromTheApprovedOrigin() {
        let entries = [
            AgentBrowserConsoleEntry(line: Self.line(1, "from the other port"), origin: "http://127.0.0.1:9000"),
            AgentBrowserConsoleEntry(line: Self.line(2, "from this page"), origin: Self.origin),
            AgentBrowserConsoleEntry(line: Self.line(3, "error on another site", .error), origin: "http://localhost:8000"),
            AgentBrowserConsoleEntry(line: Self.line(4, "no origin recorded"), origin: nil),
            AgentBrowserConsoleEntry(line: Self.line(5, "error on this page", .error), origin: Self.origin),
        ]
        let all = BrowserAgentDriver.console(entries, expectedOrigin: Self.origin, errorsOnly: false, url: URL(string: Self.origin + "/"))
        #expect(!all.isError)
        #expect(all.text.contains("2 console lines"))
        #expect(all.text.contains("from this page") && all.text.contains("error on this page"))
        #expect(!all.text.contains("other port") && !all.text.contains("another site") && !all.text.contains("no origin"))

        let errors = BrowserAgentDriver.console(entries, expectedOrigin: Self.origin, errorsOnly: true, url: nil)
        #expect(errors.text.contains("1 console line"))
        #expect(errors.text.contains("error on this page"))
        #expect(!errors.text.contains("another site"))

        let none = BrowserAgentDriver.console(entries, expectedOrigin: "http://127.0.0.1:7000", errorsOnly: false, url: nil)
        #expect(none.text == "The console is empty.")
    }

    @Test func theConsoleActionReadsOnlyThePagesOwnOrigin() async throws {
        let surface = RedirectingTestSurface()
        defer { surface.close() }
        try await surface.show(at: URL(string: Self.origin + "/")!)
        surface.entries = [
            AgentBrowserConsoleEntry(line: Self.line(1, "left over from the last site"), origin: "http://127.0.0.1:9000"),
            AgentBrowserConsoleEntry(line: Self.line(2, "this page says hi"), origin: Self.origin),
        ]
        let outcome = await BrowserAgentDriver.perform(.console(errorsOnly: false), on: surface, expectedOrigin: Self.origin)
        #expect(!outcome.result.isError)
        #expect(outcome.result.text.contains("this page says hi"))
        #expect(!outcome.result.text.contains("left over"))
    }

    // MARK: Navigation redirects

    @Test func aNavigationThatEndsOnAnotherLocalPortIsRefused() async throws {
        let surface = RedirectingTestSurface()
        defer { surface.close() }
        try await surface.show(at: URL(string: Self.origin + "/")!)
        surface.landOn = URL(string: "http://127.0.0.1:9000/landing")!

        let outcome = await BrowserAgentDriver.perform(.navigate(URL(string: Self.origin + "/next")!), on: surface,
                                                       expectedOrigin: Self.origin)
        #expect(outcome.result.isError)
        #expect(outcome.result.text.contains("outside the approved origin"))
        #expect(surface.lockWhileOpening == Self.origin)
        #expect(surface.lock == nil, "the lock is cleared after the navigation")
    }

    @Test func aRedirectBlockedByTheOriginLockIsReported() async throws {
        let surface = RedirectingTestSurface()
        defer { surface.close() }
        try await surface.show(at: URL(string: Self.origin + "/")!)
        surface.blockTo = "http://localhost:3000/elsewhere"

        let outcome = await BrowserAgentDriver.perform(.navigate(URL(string: Self.origin + "/next")!), on: surface,
                                                       expectedOrigin: Self.origin)
        #expect(outcome.result.isError)
        #expect(outcome.result.text.contains("Blocked cross-origin redirect to http://localhost:3000/elsewhere"))
        #expect(surface.lockWhileOpening == Self.origin)
        #expect(surface.lock == nil)
    }

    @Test func aNavigationThatStaysOnTheOriginOpens() async throws {
        let surface = RedirectingTestSurface()
        defer { surface.close() }
        try await surface.show(at: URL(string: Self.origin + "/")!)

        let outcome = await BrowserAgentDriver.perform(.navigate(URL(string: Self.origin + "/next")!), on: surface,
                                                       expectedOrigin: Self.origin)
        #expect(!outcome.result.isError, "\(outcome.result.text)")
        #expect(outcome.result.text.hasPrefix("Opened \(Self.origin)/next"))
        #expect(surface.lock == nil)
    }

    // MARK: Trust (B9)

    @Test func revokingTrustStopsUsingAnAlwaysGrant() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show("<!doctype html><title>Local</title><p>Hello</p>", at: URL(string: "http://localhost:5173/")!)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")

        let first = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        coordinator.answer(try #require(coordinator.permissionRequest(for: "A")).id, .always)
        #expect(await first.value.isError == false)
        #expect(await coordinator.handle(.browser(.snapshot), caller: caller).isError == false)
        #expect(coordinator.permissionRequests.isEmpty)

        // The folder is no longer trusted: the grant is not used, and the card does not offer Always.
        app.trusted = false
        let second = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        let request = try #require(coordinator.permissionRequest(for: "A"))
        #expect(!request.allowsAlways)
        coordinator.answer(request.id, .deny)
        #expect(await second.value.isError)
    }
}
#endif
