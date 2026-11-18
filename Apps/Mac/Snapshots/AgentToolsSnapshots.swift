import SwiftUI
import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of Ensemble's agent tools: a proposal card (pending, answered, failed), and the browser pane with the
/// "Agent is using the browser" bar, its permission card (trusted and untrusted folder), and the paused states after
/// Take over and on a sign-in page, each in dark and light at the requested zoom. First drives the real browser pane
/// page offscreen through `BrowserAgentDriver` (read, click, type, refuse a password field, detect the sign-in form, and
/// refuse a click approved just before the page moved to another origin) and prints what it found. Called from
/// `SnapshotRenderer.run`.
@MainActor
enum AgentToolsSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        let check = AgentToolsCheck.run(zoom: zoom)
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        guard let session = store.selected else { return [] }

        let coordinator = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { _ in nil }, browser: { _ in nil }, isTrusted: { _ in true }, knownFolders: { [] },
            resolveModel: { _, session in (session.model, "", false) }, showBrowser: { _ in }, log: { _, _ in },
            startSession: { _, _ in "" }, send: { _, _ in }))
        let center = AgentToolsCenter(server: AgentToolsServer())
        center.installForSnapshot(coordinator)

        let folder = session.directory
        let brief = """
        The footer's year is hard-coded to 2024 in Footer.tsx, and the copyright line overlaps the links below 400 px. \
        Read the year from the current date, let the line wrap on narrow screens, and add a test for both.
        """
        let pending = SessionProposal(sessionID: session.id, title: "Fix the footer year and its narrow layout", brief: brief,
                                      folder: folder, model: session.info.model, modelName: "Claude Sonnet 5")
        var failed = SessionProposal(sessionID: session.id, title: "Remove the unused checkout flags", brief: "Delete the three feature flags for the old checkout and their branches.",
                                     folder: folder + "/web", model: nil, modelName: "Gemini 3.8 Flash", unmatchedModel: "gemini-fast")
        failed.state = .failed("The folder is not trusted yet. Trust it from the session first.")
        var starting = pending
        starting.state = .starting
        var started = SessionProposal(sessionID: session.id, title: "Add a loading state to the projects grid", brief: "", folder: folder,
                                      model: nil, modelName: "Claude Sonnet 5")
        started.state = .started(sessionID: "new-session")
        var here = SessionProposal(sessionID: session.id, title: "Rename fetchTeam to loadTeam", brief: "", folder: folder,
                                   model: nil, modelName: "Claude Sonnet 5")
        here.state = .sentHere

        let address = URL(string: "http://localhost:5173/projects") ?? LaunchEntry.defaultURL(port: 5173)
        let request = BrowserPermissionRequest(sessionID: session.id, tool: .browserClick, summary: "Click button \"Create project\" (e7)",
                                               origin: "http://localhost:5173", address: address.absoluteString, allowsAlways: true)
        let untrusted = BrowserPermissionRequest(sessionID: session.id, tool: .browserSnapshot, summary: "Read the page",
                                                 origin: "http://localhost:5173", address: address.absoluteString, allowsAlways: false)

        func page() -> BrowserPage {
            let page = BrowserPage(owner: session.id, folder: folder)
            page.setLaunchForSnapshot(.missing)
            page.showForSnapshot(url: address, title: "Acme Projects", image: check.image, console: [])
            return page
        }

        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("agent-proposal-card-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                ProposalCardView(proposal: pending, onStart: {}, onDoItHere: {}, onDismiss: {}, onOpen: { _ in })
            }
            written += save("agent-proposal-states-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                VStack(alignment: .leading, spacing: 12) {
                    ProposalCardView(proposal: failed, onStart: {}, onDoItHere: {}, onDismiss: {}, onOpen: { _ in })
                    ProposalCardView(proposal: starting, onStart: {}, onDoItHere: {}, onDismiss: {}, onOpen: { _ in })
                    ProposalCardView(proposal: started, onStart: {}, onDoItHere: {}, onDismiss: {}, onOpen: { _ in })
                    ProposalCardView(proposal: here, onStart: {}, onDoItHere: {}, onDismiss: {}, onOpen: { _ in })
                }
            }
            // A narrow conversation column: the buttons wrap instead of being cut.
            written += save("agent-proposal-card-narrow-\(tone)", to: directory, width: 340, zoom: zoom, scheme: scheme) {
                ProposalCardView(proposal: pending, onStart: {}, onDoItHere: {}, onDismiss: {}, onOpen: { _ in })
            }

            func pane(_ name: String, requests: [BrowserPermissionRequest], state: AgentBrowserState) {
                coordinator.seedForSnapshot(requests: requests, states: [session.id: state])
                written += save("agent-browser-\(name)-\(tone)", to: directory, width: BrowserPane.width, height: 820, zoom: zoom,
                                scheme: scheme) {
                    BrowserPaneWithAgent(page: page(), store: store, session: session, center: center)
                }
            }
            let now = Date()
            pane("permission", requests: [request], state: AgentBrowserState(lastAction: request.summary, lastActivity: now))
            pane("untrusted", requests: [untrusted], state: AgentBrowserState(lastAction: untrusted.summary, lastActivity: now))
            pane("active", requests: [], state: AgentBrowserState(lastAction: "Type 11 characters into textbox \"Project name\" (e4)", lastActivity: now, running: true))
            pane("tookover", requests: [], state: AgentBrowserState(pause: .tookOver, lastAction: "Click e7", lastActivity: now))
            pane("signin", requests: [], state: AgentBrowserState(pause: .signIn, lastAction: "Click e9", lastActivity: now))
            let typing = BrowserPermissionRequest(sessionID: session.id, tool: .browserType,
                                                  summary: "Type 11 characters into textbox \"Project name\" (e4)", origin: "http://localhost:5173",
                                                  address: address.absoluteString, typedText: "Status page", allowsAlways: true)
            coordinator.seedForSnapshot(requests: [typing], states: [:])
            written += save("agent-browser-card-composer-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                AgentBrowserPermissionHost(session: session, center: center)
            }
        }
        return written
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, height: CGFloat? = nil, zoom: CGFloat,
                                      scheme: ColorScheme, @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let h = height.map { $0 * zoom }
        let theme = scheme == .dark ? Theme.dark : Theme.light
        let content = view()
            .padding(height == nil ? 16 * zoom : 0)
            .frame(width: w, height: h, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: h == nil)
            .background(height == nil ? theme.background : theme.panel)
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: h)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }
}

/// The browser pane with the bar host reading a given center (snapshots use their own, never the app's).
private struct BrowserPaneWithAgent: View {
    let page: BrowserPage
    let store: SessionStore
    let session: SessionModel
    let center: AgentToolsCenter

    var body: some View {
        BrowserPane(page: page, store: store, session: session, topInset: 15, agentTools: center, onClose: {})
    }
}

/// Drives the real browser pane page in a window that is never shown, through the same driver the agent tools use.
@MainActor
enum AgentToolsCheck {
    struct Result {
        var image: NSImage?
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>Acme Projects</title>
    <style>
      body { margin: 0; font: 15px/1.45 -apple-system, system-ui, sans-serif; color: #1f2328; background: #f6f7f9; }
      header { display: flex; align-items: center; gap: 12px; padding: 14px 22px; background: #fff; border-bottom: 1px solid #e3e5e8; }
      .logo { width: 26px; height: 26px; border-radius: 7px; background: linear-gradient(135deg, #5b7cfa, #8a5cf6); }
      main { padding: 22px; max-width: 900px; margin: 0 auto; }
      h1 { font-size: 22px; margin: 0 0 14px; }
      form { display: grid; gap: 10px; max-width: 360px; background: #fff; border: 1px solid #e3e5e8; border-radius: 12px; padding: 18px; }
      label { font-size: 13px; color: #59636e; } input { border: 1px solid #d0d4d9; border-radius: 8px; padding: 8px 12px; font: inherit; }
      button { border: 0; background: #5b7cfa; color: #fff; border-radius: 8px; padding: 9px 14px; font: inherit; }
    </style></head><body>
    <header><div class="logo"></div><b>Acme</b></header>
    <main>
      <h1>New project</h1>
      <form id="f" onsubmit="event.preventDefault(); document.getElementById('out').textContent = 'Created ' + document.getElementById('name').value;">
        <label for="name">Project name</label><input id="name" placeholder="Checkout redesign">
        <label for="pw">Deploy password</label><input id="pw" type="password">
        <button id="create">Create project</button>
        <p id="out"></p>
      </form>
    </main>
    </body></html>
    """

    @MainActor final class Surface: AgentBrowserSurface {
        let page: BrowserPage
        init(page: BrowserPage) { self.page = page }
        var agentWebView: WKWebView { page.agentWebView }
        var agentWorld: WKContentWorld { page.agentWorld }
        var agentURL: URL? { page.agentWebView.url }
        var agentConsole: [BrowserConsoleLine] { page.agentConsole }
        func agentOpen(_ url: URL) { page.agentOpen(url) }
    }

    @MainActor private final class Box<T> {
        var value: T?
        var done = false
    }

    static func run(zoom: CGFloat) -> Result {
        _ = NSApplication.shared
        let page = BrowserPage(owner: "agent-tools-check", folder: NSTemporaryDirectory())
        let webView = page.webView
        let size = NSSize(width: BrowserPane.width * zoom, height: 700 * zoom)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        webView.frame = NSRect(origin: .zero, size: size)
        webView.pageZoom = zoom
        window.contentView = webView
        defer { window.close() }

        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait<T>(_ work: @escaping @MainActor () async -> T) -> T? {
            let box = Box<T>()
            Task { @MainActor in
                box.value = await work()
                box.done = true
            }
            let deadline = Date().addingTimeInterval(20)
            while !box.done, Date() < deadline { spin(0.05) }
            return box.value
        }

        page.loadForCheck(html: html, baseURL: URL(string: "http://localhost:5173/new") ?? LaunchEntry.defaultURL(port: 5173))
        let deadline = Date().addingTimeInterval(15)
        while (webView.isLoading || webView.url?.host() != "localhost"), Date() < deadline { spin(0.05) }
        spin(0.2)
        let surface = Surface(page: page)

        let origin = "http://localhost:5173"
        let snapshot = wait { await BrowserAgentDriver.perform(.snapshot, on: surface, expectedOrigin: origin) }
        let text = snapshot?.result.text ?? ""
        func ref(_ label: String) -> String? {
            guard let line = text.split(separator: "\n").first(where: { $0.contains(label) }),
                  let start = line.range(of: "[ref=")?.upperBound, let end = line[start...].firstIndex(of: "]") else { return nil }
            return String(line[start..<end])
        }
        let nameRef = ref("Project name")
        let passwordRef = ref("Deploy password")
        let buttonRef = ref("Create project")
        let fenced = text.contains("untrusted data") && text.contains("```")
        let password = wait { await BrowserAgentDriver.perform(.type(ref: passwordRef ?? "e0", text: "hunter2", submit: false), on: surface, expectedOrigin: origin) }
        let passwordRefused = password?.result.isError == true && password?.result.text.contains("password") == true
        let typed = wait { await BrowserAgentDriver.perform(.type(ref: nameRef ?? "e0", text: "Status page", submit: false), on: surface, expectedOrigin: origin) }
        let clicked = wait { await BrowserAgentDriver.perform(.click(ref: buttonRef ?? "e0"), on: surface, expectedOrigin: origin) }
        let result = wait { () -> String in
            (try? await webView.evaluateJavaScript("document.getElementById('out').textContent + '|' + document.getElementById('pw').value") as? String) ?? ""
        } ?? ""
        let actions = typed?.result.isError == false && clicked?.result.isError == false && result == "Created Status page|"
        let signIn = snapshot?.signIn == true

        // The picture of the page for the pane snapshots.
        let image = wait { () -> NSImage? in try? await webView.takeSnapshot(configuration: WKSnapshotConfiguration()) } ?? nil

        // A click the user approves while the page moves to another origin is not run.
        let coordinator = AgentToolsCoordinator(environment: AgentToolsEnvironment(
            session: { id in
                AgentToolsEnvironment.Session(id: id, rootID: id, directory: NSTemporaryDirectory(), model: nil, permissionMode: .ask,
                                              archived: false, turn: "1")
            },
            browser: { _ in surface }, isTrusted: { _ in true }, knownFolders: { [] },
            resolveModel: { _, session in (session.model, "", false) }, showBrowser: { _ in }, log: { _, _ in },
            startSession: { _, _ in "" }, send: { _, _ in }))
        let call = Task { @MainActor in
            await coordinator.handle(.browser(.click(ref: buttonRef ?? "e0")), caller: AgentToolsCaller(sessionID: "agent-tools-check"))
        }
        var movedDeadline = Date().addingTimeInterval(15)
        while coordinator.permissionRequests.isEmpty, Date() < movedDeadline { spin(0.05) }
        let cardOrigin = coordinator.permissionRequests.first?.origin
        page.loadForCheck(html: "<!doctype html><button onclick=\"window.moved = 'clicked'\">Create project</button>",
                          baseURL: URL(string: "http://127.0.0.1:5174/") ?? LaunchEntry.defaultURL(port: 5174))
        movedDeadline = Date().addingTimeInterval(15)
        while (webView.isLoading || webView.url?.port != 5174), Date() < movedDeadline { spin(0.05) }
        if let request = coordinator.permissionRequests.first { coordinator.answer(request.id, .once) }
        let moved = wait { await call.value }
        let movedClick = wait { () -> String in
            (try? await webView.evaluateJavaScript("String(window.moved)") as? String) ?? ""
        } ?? ""
        let movedRefused = cardOrigin == origin && moved?.isError == true
            && moved?.text.contains("while waiting; the action was not run") == true && movedClick == "undefined"
        print("Agent tools check: snapshot refs \(nameRef != nil && passwordRef != nil && buttonRef != nil ? "ok" : "MISSING"), "
              + "page text fenced \(fenced ? "ok" : "NO"), password field refused \(passwordRefused ? "ok" : "NO"), "
              + "type and click \(actions ? "ok" : "FAILED (\(result))"), sign-in form noticed \(signIn ? "ok" : "NO"), "
              + "click refused after the page moved \(movedRefused ? "ok" : "NO (\(moved?.text ?? "no answer"))")")
        return Result(image: image)
    }
}
