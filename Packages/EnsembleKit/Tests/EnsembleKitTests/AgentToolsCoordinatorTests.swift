#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import EnsembleKit

/// A plain web view in a window that is never shown, standing in for the browser pane's page.
@MainActor
final class AgentToolsTestSurface: AgentBrowserSurface {
    let agentWebView: WKWebView
    let agentWorld = WKContentWorld.world(name: BrowserScripts.worldName)
    var console: [BrowserConsoleLine] = []
    private let window: NSWindow

    init() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        agentWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 700), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = agentWebView
    }

    var agentURL: URL? { agentWebView.url }
    var agentConsole: [BrowserConsoleLine] { console }
    func agentOpen(_ url: URL) { agentWebView.load(URLRequest(url: url)) }

    /// Loads HTML from the test itself under an http origin (nothing is fetched).
    func show(_ html: String, at base: URL) async throws {
        agentWebView.loadHTMLString(html, baseURL: base)
        try await agentToolsWait("the page to load") { !self.agentWebView.isLoading && self.agentWebView.url?.host() == base.host() }
    }

    func close() { window.close() }
}

/// Waits on the main actor until `condition` holds (the run loop keeps delivering WebKit's messages meanwhile).
@MainActor
func agentToolsWait(_ what: String, timeout: Double = 120, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw AgentToolsWaitTimeout(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct AgentToolsWaitTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// The app side, faked: sessions, trust, what was started, sent and logged.
@MainActor
final class AgentToolsTestApp {
    var sessions: [String: AgentToolsEnvironment.Session] = [:]
    var trusted = true
    var surface: AgentToolsTestSurface?
    var logs: [(String, String)] = []
    var started: [SessionProposal] = []
    var sent: [(String, String)] = []
    var shown: [String] = []
    /// Folders with a default mode of their own.
    var folderModes: [String: PermissionMode] = [:]

    func add(_ id: String, folder: String, turn: String = "1", parent: String? = nil, mode: PermissionMode = .ask) {
        sessions[id] = AgentToolsEnvironment.Session(id: id, rootID: parent ?? id, directory: folder, model: nil,
                                                     permissionMode: mode, archived: false, turn: turn)
    }

    func coordinator() -> AgentToolsCoordinator {
        AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { [unowned self] in sessions[$0] },
            browser: { [unowned self] _ in surface },
            isTrusted: { [unowned self] _ in trusted },
            knownFolders: { [unowned self] in sessions.values.map(\.directory) },
            resolveModel: { asked, session in (session.model, "Test model", asked == nil) },
            showBrowser: { [unowned self] in shown.append($0) },
            log: { [unowned self] in logs.append(($0, $1)) },
            startSession: { [unowned self] proposal, _ in
                started.append(proposal)
                return "new-\(started.count)"
            },
            send: { [unowned self] in sent.append(($0, $1)) },
            folderMode: { [unowned self] in folderModes[$0] }))
    }
}

@MainActor
@Suite(.serialized) struct AgentToolsCoordinatorTests {
    static let form = """
    <!doctype html><html><head><title>Sign in to Acme</title></head><body>
    <h1>Acme</h1>
    <form id="f" onsubmit="event.preventDefault(); document.getElementById('out').textContent = 'Hello ' + document.getElementById('user').value;">
      <label for="user">Email</label><input id="user" type="email">
      <label for="pw">Password</label><input id="pw" type="password" value="secret-in-page">
      <label for="card">Card number</label><input id="card" autocomplete="cc-number">
      <input id="file" type="file" aria-label="Avatar">
      <button id="go">Continue</button>
    </form>
    <p id="out"></p>
    </body></html>
    """

    static func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ens-agent-tools-\(UUID().uuidString.prefix(8))")
        // With a subfolder for the folder rule.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("web"), withIntermediateDirectories: true)
        return WorkspaceTrust.resolvedPath(url.path) ?? url.path
    }

    static func ref(_ label: String, in text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains(label) }),
              let start = line.range(of: "[ref=")?.upperBound, let end = line[start...].firstIndex(of: "]") else { return nil }
        return String(line[start..<end])
    }

    @Test func proposalsShowCardsAndNeverStartOnTheirOwn() async throws {
        let app = AgentToolsTestApp()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        app.add("A", folder: folder)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")
        var answers: [Bool] = []
        for index in 1...4 {
            let result = await coordinator.handle(.propose(SessionProposalInput(title: "Task \(index)", brief: "Do \(index)")), caller: caller)
            answers.append(result.isError)
        }
        #expect(answers == [false, false, false, true])
        #expect(coordinator.proposals(for: "A").count == 3)
        #expect(app.started.isEmpty && app.sent.isEmpty)

        // A new message from the user starts a new turn.
        app.add("A", folder: folder, turn: "2")
        #expect(await coordinator.handle(.propose(SessionProposalInput(title: "Task 5", brief: "Do 5")), caller: caller).isError == false)

        // A folder outside the session's is refused; one inside it is fine.
        let inside = folder + "/web"
        app.add("A", folder: folder, turn: "3")
        #expect(await coordinator.handle(.propose(SessionProposalInput(title: "x", brief: "y", folder: "/System")), caller: caller).isError)
        #expect(await coordinator.handle(.propose(SessionProposalInput(title: "In web", brief: "y", folder: inside)), caller: caller).isError == false)

        let cards = coordinator.proposals(for: "A")
        await coordinator.start(cards[0].id)
        #expect(app.started.map(\.title) == ["Task 1"])
        #expect(coordinator.proposals(for: "A")[0].state == .started(sessionID: "new-1"))
        await coordinator.doItHere(cards[1].id)
        #expect(app.sent.count == 1 && app.sent[0].0 == "A" && app.sent[0].1.contains("Do 2"))
        coordinator.dismiss(cards[2].id)
        #expect(!coordinator.proposals(for: "A").contains { $0.id == cards[2].id })
        // Answered cards do not act twice.
        await coordinator.start(cards[0].id)
        #expect(app.started.count == 1)
    }

    @Test func aFolderSwappedThroughALinkDoesNotStart() async throws {
        let app = AgentToolsTestApp()
        let folder = try Self.folder()
        let elsewhere = try Self.folder()
        defer {
            try? FileManager.default.removeItem(atPath: folder)
            try? FileManager.default.removeItem(atPath: elsewhere)
        }
        let fm = FileManager.default
        app.add("A", folder: folder)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")

        // Proposed through a link inside the session: the card keeps (and shows) the real folder.
        try fm.createSymbolicLink(atPath: folder + "/link", withDestinationPath: folder + "/web")
        #expect(await coordinator.handle(.propose(SessionProposalInput(title: "Via link", brief: "b", folder: folder + "/link")), caller: caller).isError == false)
        #expect(coordinator.proposals(for: "A").first?.folder == folder + "/web")

        // The agent then swaps the real folder for a link to somewhere else before the user clicks Start.
        try fm.removeItem(atPath: folder + "/web")
        try fm.createSymbolicLink(atPath: folder + "/web", withDestinationPath: elsewhere)
        let card = try #require(coordinator.proposals(for: "A").first)
        await coordinator.start(card.id)
        #expect(app.started.isEmpty)
        guard case .failed(let message)? = coordinator.proposals(for: "A").first?.state else {
            Issue.record("The card should have failed")
            return
        }
        #expect(message.contains("link in its path changed"))
        #expect(message.contains(elsewhere))

        // A proposal whose folder is the session's own, swapped the same way, fails too.
        try fm.createDirectory(atPath: folder + "/app", withIntermediateDirectories: true)
        app.add("B", folder: folder + "/app")
        #expect(await coordinator.handle(.propose(SessionProposalInput(title: "Here", brief: "b")), caller: AgentToolsCaller(sessionID: "B")).isError == false)
        try fm.removeItem(atPath: folder + "/app")
        try fm.createSymbolicLink(atPath: folder + "/app", withDestinationPath: elsewhere)
        await coordinator.start(try #require(coordinator.proposals(for: "B").first).id)
        #expect(app.started.isEmpty)
    }

    @Test func proposedSessionsStartInAskNotTheProposersMode() async throws {
        let app = AgentToolsTestApp()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        app.add("A", folder: folder, mode: .auto)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")
        _ = await coordinator.handle(.propose(SessionProposalInput(title: "One", brief: "b")), caller: caller)
        let card = try #require(coordinator.proposals(for: "A").first)
        #expect(card.permissionMode == .ask)
        await coordinator.start(card.id)
        #expect(app.started.map(\.permissionMode) == [.ask])

        // A folder's own default is used, except Bypass.
        app.folderModes[folder + "/web"] = .acceptEdits
        _ = await coordinator.handle(.propose(SessionProposalInput(title: "Two", brief: "b", folder: folder + "/web")), caller: caller)
        app.folderModes[folder] = .bypass
        app.add("A", folder: folder, turn: "2", mode: .bypass)
        _ = await coordinator.handle(.propose(SessionProposalInput(title: "Three", brief: "b")), caller: caller)
        let modes = coordinator.proposals(for: "A").map(\.permissionMode)
        #expect(modes == [.ask, .acceptEdits, .ask])
        #expect(ProposalMode.mode(folderDefault: .bypass) == .ask)
        #expect(ProposalMode.mode(folderDefault: nil) == .ask)
    }

    @Test func subagentProposalsGoToTheParent() async throws {
        let app = AgentToolsTestApp()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        app.add("parent", folder: folder)
        app.add("child", folder: folder, parent: "parent")
        let coordinator = app.coordinator()
        _ = await coordinator.handle(.propose(SessionProposalInput(title: "t", brief: "b")), caller: AgentToolsCaller(sessionID: "child"))
        #expect(coordinator.proposals(for: "parent").count == 1)
        #expect(coordinator.proposals(for: "child").isEmpty)
    }

    @Test func otherSitesAreRefusedWithoutACard() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")
        // No page yet.
        #expect(await coordinator.handle(.browser(.snapshot), caller: caller).isError)
        let remote = await coordinator.handle(.browser(.navigate(URL(string: "https://example.com/")!)), caller: caller)
        #expect(remote.isError)
        #expect(remote.text.contains("only use pages on this computer"))
        try await surface.show(Self.form, at: URL(string: "https://example.org/login")!)
        #expect(await coordinator.handle(.browser(.snapshot), caller: caller).isError)
        #expect(coordinator.permissionRequests.isEmpty)
    }

    @Test func everyCallAsksUntilTheSiteIsAllowed() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show(Self.form, at: URL(string: "http://localhost:5173/login")!)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")

        // Deny.
        let denied = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        let request = try #require(coordinator.permissionRequest(for: "A"))
        #expect(request.site == "localhost:5173")
        #expect(request.allowsAlways)
        coordinator.answer(request.id, .deny)
        #expect(await denied.value.isError)

        // Allow once: the next call asks again.
        let once = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        coordinator.answer(try #require(coordinator.permissionRequest(for: "A")).id, .once)
        let read = await once.value
        #expect(!read.isError)
        #expect(read.text.contains("untrusted data"))

        let always = Task { await coordinator.handle(.browser(.console(errorsOnly: false)), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        coordinator.answer(try #require(coordinator.permissionRequest(for: "A")).id, .always)
        #expect(await always.value.isError == false)

        // Allowed for the session now: no card.
        #expect(await coordinator.handle(.browser(.snapshot), caller: caller).isError == false)
        #expect(coordinator.permissionRequests.isEmpty)
        #expect(app.shown.contains("A"))
    }

    @Test func untrustedFoldersRememberNothing() async throws {
        let app = AgentToolsTestApp()
        app.trusted = false
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show(Self.form, at: URL(string: "http://127.0.0.1:8000/")!)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")
        for _ in 0..<2 {
            let call = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
            try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
            let request = try #require(coordinator.permissionRequest(for: "A"))
            #expect(!request.allowsAlways)
            coordinator.answer(request.id, .always)
            #expect(await call.value.isError == false)
        }
        #expect(coordinator.grants.origins(for: "A").isEmpty)
    }

    @Test func passwordPaymentAndFileFieldsAreRefused() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show(Self.form, at: URL(string: "http://localhost:3000/login")!)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")
        let first = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        coordinator.answer(try #require(coordinator.permissionRequest(for: "A")).id, .always)
        let snapshot = await first.value.text
        // The password's value never reaches the agent.
        #expect(!snapshot.contains("secret-in-page"))
        #expect(snapshot.contains(BrowserAgentDriver.signInNotice))
        let password = try #require(Self.ref("\"Password\"", in: snapshot))
        let card = try #require(Self.ref("\"Card number\"", in: snapshot))
        let file = try #require(Self.ref("\"Avatar\"", in: snapshot))
        let email = try #require(Self.ref("\"Email\"", in: snapshot))

        // A sign-in page pauses the agent's actions until the user hands the browser back.
        #expect(coordinator.browserState("A").pause == .signIn)
        #expect(await coordinator.handle(.browser(.type(ref: email, text: "a@b.c", submit: false)), caller: caller).isError)
        coordinator.handBack("A")

        for (ref, text) in [(password, "hunter2"), (card, "4242424242424242")] {
            let typed = await coordinator.handle(.browser(.type(ref: ref, text: text, submit: false)), caller: caller)
            #expect(typed.isError)
            #expect(typed.text.contains("password, one-time code or payment"))
        }
        #expect(await coordinator.handle(.browser(.click(ref: password)), caller: caller).isError)
        #expect(await coordinator.handle(.browser(.click(ref: file)), caller: caller).text.contains("uploads"))
        let values = try await surface.agentWebView.evaluateJavaScript(
            "document.getElementById('pw').value + '|' + document.getElementById('card').value") as? String
        #expect(values == "secret-in-page|")
        #expect(coordinator.permissionRequests.isEmpty)

        // An ordinary field works.
        coordinator.handBack("A")
        let typed = await coordinator.handle(.browser(.type(ref: email, text: "dev@example.test", submit: true)), caller: caller)
        #expect(typed.isError == false)
        let out = try await surface.agentWebView.evaluateJavaScript("document.getElementById('out').textContent") as? String
        #expect(out == "Hello dev@example.test")
    }

    @Test func stopAndTakeOverRefuseCalls() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp", turn: "1")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show("<p>Hi</p>", at: URL(string: "http://localhost:5173/")!)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")

        let waiting = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        coordinator.stop("A")
        #expect(await waiting.value.isError)
        #expect(coordinator.permissionRequests.isEmpty)
        let refused = await coordinator.handle(.browser(.snapshot), caller: caller)
        #expect(refused.text.contains("stopped"))
        #expect(coordinator.permissionRequests.isEmpty)

        // The next turn may ask again.
        app.add("A", folder: "/tmp", turn: "2")
        let again = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        coordinator.takeOver("A")
        #expect(await again.value.isError)
        #expect(await coordinator.handle(.browser(.snapshot), caller: caller).text.contains("took over"))
        coordinator.handBack("A")
        let back = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        coordinator.answer(try #require(coordinator.permissionRequest(for: "A")).id, .once)
        #expect(await back.value.isError == false)
    }

    static let button = """
    <!doctype html><html><head><title>Button</title></head><body>
    <button id="go" onclick="window.clicked = (window.clicked || 0) + 1; document.getElementById('out').textContent = 'clicked'">Go</button>
    <p id="out"></p><p>Local page text</p>
    </body></html>
    """
    static let elsewhere = """
    <!doctype html><html><body><button id="go" onclick="window.clicked = 1">Go</button><p>Other origin secret</p></body></html>
    """

    /// Answers the next card with `answer` once it appears.
    func answerNextCard(_ coordinator: AgentToolsCoordinator, _ answer: BrowserPermissionAnswer) async throws -> BrowserPermissionRequest {
        try await agentToolsWait("a card") { !coordinator.permissionRequests.isEmpty }
        let request = try #require(coordinator.permissionRequests.first)
        coordinator.answer(request.id, answer)
        return request
    }

    @Test func anApprovedActionDoesNotRunAfterThePageMoves() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show(Self.button, at: URL(string: "http://localhost:5173/")!)
        let coordinator = app.coordinator()
        let caller = AgentToolsCaller(sessionID: "A")
        let read = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        _ = try await answerNextCard(coordinator, .once)
        let go = try #require(Self.ref("\"Go\"", in: await read.value.text))

        // The user approves a click on localhost:5173, but while the card waits the page goes to another origin.
        let click = Task { await coordinator.handle(.browser(.click(ref: go)), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        #expect(coordinator.permissionRequests.first?.origin == "http://localhost:5173")
        try await surface.show(Self.elsewhere, at: URL(string: "http://127.0.0.1:8000/")!)
        coordinator.answer(try #require(coordinator.permissionRequests.first).id, .once)
        let clicked = await click.value
        #expect(clicked.isError)
        #expect(clicked.text == "The page changed to http://127.0.0.1:8000/ while waiting; the action was not run.")
        #expect(try await surface.agentWebView.evaluateJavaScript("String(window.clicked)") as? String == "undefined")

        // A read approved for one site never returns another site's text.
        try await surface.show(Self.button, at: URL(string: "http://localhost:5173/")!)
        let snapshot = Task { await coordinator.handle(.browser(.snapshot), caller: caller) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        try await surface.show(Self.elsewhere, at: URL(string: "http://localhost:5174/")!)
        coordinator.answer(try #require(coordinator.permissionRequests.first).id, .once)
        let text = await snapshot.value
        #expect(text.isError)
        #expect(!text.text.contains("Other origin secret"))
    }

    @Test func scriptsCheckTheOriginInsideThePage() async throws {
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        try await surface.show(Self.button, at: URL(string: "http://localhost:5173/")!)
        let read = try await BrowserAgentDriver.run(BrowserAgentScripts.snapshot, on: surface,
                                                    arguments: ["maxText": 2000, "maxItems": 50, "expectedOrigin": "http://localhost:5173"])
        #expect(read["error"] == nil)
        let go = try #require(Self.ref("\"Go\"", in: read["elements"]?.stringValue ?? ""))
        // Another origin than the page's: the script refuses before it touches anything.
        for origin in ["http://localhost:5174", "http://127.0.0.1:5173", "https://localhost:5173", "http://localhost:80"] {
            let refused = try await BrowserAgentDriver.run(BrowserAgentScripts.click, on: surface, arguments: ["ref": go, "expectedOrigin": origin])
            #expect(refused["error"] == "origin")
            #expect(refused["href"] == "http://localhost:5173/")
        }
        let scrolled = try await BrowserAgentDriver.run(BrowserAgentScripts.scroll, on: surface,
                                                        arguments: ["direction": "down", "ref": NSNull(), "expectedOrigin": "http://localhost:9"])
        #expect(scrolled["error"] == "origin")
        let typed = try await BrowserAgentDriver.run(BrowserAgentScripts.type, on: surface,
                                                     arguments: ["ref": go, "text": "x", "submit": false, "expectedOrigin": "http://localhost:9"])
        #expect(typed["error"] == "origin")
        let otherRead = try await BrowserAgentDriver.run(BrowserAgentScripts.snapshot, on: surface,
                                                         arguments: ["maxText": 2000, "maxItems": 50, "expectedOrigin": "http://localhost:9"])
        #expect(otherRead["error"] == "origin" && otherRead["text"] == nil)
        // Through the driver, the refusal is the agent's message.
        let performed = await BrowserAgentDriver.perform(.click(ref: go), on: surface, expectedOrigin: "http://localhost:9")
        #expect(performed.result.text == "The page changed to http://localhost:5173/ while waiting; the action was not run.")
        // Leaving the origin out fails closed.
        await #expect(throws: (any Error).self) {
            _ = try await BrowserAgentDriver.run(BrowserAgentScripts.click, on: surface, arguments: ["ref": go])
        }
        #expect(try await surface.agentWebView.evaluateJavaScript("String(window.clicked)") as? String == "undefined")
        // The matching origin works.
        let ok = await BrowserAgentDriver.perform(.click(ref: go), on: surface, expectedOrigin: "http://localhost:5173")
        #expect(ok.result.isError == false)
        #expect(try await surface.agentWebView.evaluateJavaScript("String(window.clicked)") as? String == "1")
        // Default ports are written out on both sides.
        try await surface.show(Self.button, at: URL(string: "http://localhost/")!)
        let defaultPort = try await BrowserAgentDriver.run(BrowserAgentScripts.snapshot, on: surface,
                                                           arguments: ["maxText": 100, "maxItems": 5, "expectedOrigin": "http://localhost:80"])
        #expect(defaultPort["error"] == nil)
        #expect(BrowserAgentOrigin.origin(of: URL(string: "http://localhost/")) == "http://localhost:80")
    }

    @Test func alwaysCoversOnlyItsOriginAndOnlyExactBridges() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show(Self.button, at: URL(string: "http://localhost:5173/")!)
        let coordinator = app.coordinator()
        let exact = AgentToolsCaller(sessionID: "A")
        let first = Task { await coordinator.handle(.browser(.snapshot), caller: exact) }
        _ = try await answerNextCard(coordinator, .always)
        #expect(await first.value.isError == false)
        #expect(await coordinator.handle(.browser(.snapshot), caller: exact).isError == false)
        #expect(coordinator.permissionRequests.isEmpty)

        // Another port is another site: it asks.
        try await surface.show(Self.button, at: URL(string: "http://localhost:5174/")!)
        let other = Task { await coordinator.handle(.browser(.snapshot), caller: exact) }
        #expect(try await answerNextCard(coordinator, .deny).site == "localhost:5174")
        #expect(await other.value.isError)

        // A bridge not tied to one engine process neither uses nor offers Always.
        try await surface.show(Self.button, at: URL(string: "http://localhost:5173/")!)
        let loose = AgentToolsCaller(sessionID: "A", canUseSiteGrants: false)
        for _ in 0..<2 {
            let call = Task { await coordinator.handle(.browser(.snapshot), caller: loose) }
            let request = try await answerNextCard(coordinator, .always)
            #expect(!request.allowsAlways)
            #expect(await call.value.isError == false)
        }
        #expect(coordinator.grants.origins(for: "A") == ["http://localhost:5173"])
    }

    @Test func openCodeCallersNeverUseAClaudeSessionsGrant() async throws {
        let app = AgentToolsTestApp()
        app.add("claude", folder: "/tmp")
        app.add("ses_open", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show(Self.button, at: URL(string: "http://localhost:5173/")!)
        let coordinator = app.coordinator()
        // The user clicks Always in the Claude session for this site.
        let claude = Task { await coordinator.handle(.browser(.snapshot), caller: AgentToolsCaller(sessionID: "claude")) }
        #expect(try await answerNextCard(coordinator, .always).allowsAlways)
        #expect(await claude.value.isError == false)
        #expect(coordinator.grants.origins(for: "claude") == ["http://localhost:5173"])
        // An OpenCode caller (as the server marks it) still gets a card every time, without Always, saying why.
        let openCode = AgentToolsCaller(sessionID: "ses_open", canUseSiteGrants: false)
        for _ in 0..<2 {
            let call = Task { await coordinator.handle(.browser(.snapshot), caller: openCode) }
            let request = try await answerNextCard(coordinator, .always)
            #expect(!request.allowsAlways)
            #expect(request.alwaysNote == BrowserPermissionRequest.claudeOnlyNote)
            #expect(await call.value.isError == false)
        }
        #expect(coordinator.grants.origins(for: "ses_open").isEmpty)
        // Even an OpenCode caller naming the Claude session never uses its grant.
        let borrowed = Task { await coordinator.handle(.browser(.snapshot), caller: AgentToolsCaller(sessionID: "claude", canUseSiteGrants: false)) }
        _ = try await answerNextCard(coordinator, .deny)
        #expect(await borrowed.value.isError)
    }

    @Test func cancelledCallsCloseTheirCard() async throws {
        let app = AgentToolsTestApp()
        app.add("A", folder: "/tmp")
        let surface = AgentToolsTestSurface()
        defer { surface.close() }
        app.surface = surface
        try await surface.show("<p>Hi</p>", at: URL(string: "http://localhost:5173/")!)
        let coordinator = app.coordinator()
        let call = Task { await coordinator.handle(.browser(.snapshot), caller: AgentToolsCaller(sessionID: "A")) }
        try await agentToolsWait("a card") { coordinator.permissionRequests.count == 1 }
        call.cancel()
        #expect(await call.value.isError)
        try await agentToolsWait("the card to close") { coordinator.permissionRequests.isEmpty }
    }
}
#endif
