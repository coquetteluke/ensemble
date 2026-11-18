import SwiftUI
import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of the browser pane (empty with dev servers, a page, the console, phone width, the start confirmation,
/// the trust notice, the dev servers list, and the whole window), each in dark and light at the requested zoom.
/// First runs the real web view offscreen: the console capture, refused `file:` and custom-scheme loads, the element
/// picker, and that the page cannot see Ensemble's handlers. Its pictures of the page stand in for the web view, which
/// `ImageRenderer` cannot draw. Called from `SnapshotRenderer.run`.
@MainActor
enum BrowserSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        let check = BrowserCheck.run(zoom: zoom)
        BrowserCheck.runServer()
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        guard let session = store.selected else { return [] }

        // A trust list of its own (never the app's), with nothing trusted, and no confirmations.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ensemble-browser-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let servers = DevServers(trust: WorkspaceTrust(fileURL: scratch.appendingPathComponent("trust.json")),
                                 approvals: LaunchApprovals(fileURL: nil))
        let launch = LaunchConfigLoad.loaded(sampleConfig)
        let address = URL(string: "http://localhost:5173/projects") ?? LaunchEntry.defaultURL(port: 5173)

        func page(_ configure: (BrowserPage) -> Void) -> BrowserPage {
            let page = BrowserPage(owner: session.id, folder: session.directory)
            page.setLaunchForSnapshot(launch)
            configure(page)
            return page
        }
        let empty = page { _ in }
        let loaded = page { $0.showForSnapshot(url: address, title: "Acme Projects", image: check.fullImage, console: []) }
        let withConsole = page {
            $0.showForSnapshot(url: address, title: "Acme Projects", image: check.fullImage, console: check.consoleForSnapshot)
            $0.consoleOpen = true
        }
        let phone = page {
            $0.showForSnapshot(url: address, title: "Acme Projects", image: check.phoneImage, console: check.consoleForSnapshot)
            $0.device = .phone
            $0.pickForSnapshot(summary: "button#new-project.btn.primary", html: #"<button id="new-project" class="btn primary">New project</button>"#)
        }
        let confirm = page {
            $0.pendingStart = BrowserPage.PendingStart(entry: sampleConfig.entries[0], program: "/opt/homebrew/bin/npm")
        }
        let trust = page { $0.notice = .needsTrust(sampleConfig.entries[0]) }

        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            func pane(_ name: String, _ page: BrowserPage) {
                written += save("browser-\(name)-\(tone)", to: directory, width: BrowserPane.width, height: 900, zoom: zoom, scheme: scheme) {
                    BrowserPane(page: page, store: store, session: session, servers: servers, topInset: 15, onClose: {})
                }
            }
            pane("empty", empty)
            pane("page", loaded)
            pane("console", withConsole)
            pane("phone", phone)
            pane("confirm", confirm)
            pane("trust", trust)
            written += save("browser-devservers-\(tone)", to: directory, width: DevServersPopover.width, height: nil, zoom: zoom, scheme: scheme) {
                DevServersPopover(page: empty, store: store, servers: servers) {}
            }
            let missing = page { $0.setLaunchForSnapshot(.missing) }
            written += save("browser-devservers-missing-\(tone)", to: directory, width: DevServersPopover.width, height: nil, zoom: zoom,
                            scheme: scheme) {
                DevServersPopover(page: missing, store: store, servers: servers) {}
            }
        }

        // The whole window with the browser open on the right.
        let window = WindowState()
        window.showSidebar = true
        window.showContextPanel = true
        window.openSidePane(.browser)
        BrowserCenter.shared.install(withConsole)
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            written += save("main-window-browser-\(tone)", to: directory, width: 1440, height: 900, zoom: zoom, scheme: scheme, window: true) {
                MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
            }
        }
        BrowserCenter.shared.close(owners: [session.id])
        return written
    }

    static let sampleConfig = LaunchConfig(entries: [
        LaunchEntry(name: "web", arguments: ["npm", "run", "dev"], port: 5173),
        LaunchEntry(name: "docs", arguments: ["python3", "-m", "http.server", "8000"], port: 8000,
                    url: URL(string: "http://localhost:8000/docs/")),
    ])

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, height: CGFloat?, zoom: CGFloat,
                                      scheme: ColorScheme, window: Bool = false, @ViewBuilder _ view: () -> V) -> [String] {
        // Whole windows keep their size and zoom their content; single views grow with the zoom.
        let w = window ? width : width * zoom
        let h = window ? height : height.map { $0 * zoom }
        let content = view()
            .frame(width: w, height: h, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: h == nil)
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

/// The real browser web view in a window that is never shown.
@MainActor
enum BrowserCheck {
    struct Result {
        var fullImage: NSImage?
        var phoneImage: NSImage?
        var console: [BrowserConsoleLine]

        /// Server lines first, then what the page logged (or sample lines if the capture caught nothing).
        var consoleForSnapshot: [BrowserConsoleLine] {
            var lines = [
                BrowserConsoleLine(id: 9001, level: .log, text: "> acme-web@0.4.0 dev", source: .server("web")),
                BrowserConsoleLine(id: 9002, level: .log, text: "VITE v5.4.2  ready in 412 ms", source: .server("web")),
                BrowserConsoleLine(id: 9003, level: .log, text: "Local:   http://localhost:5173/", source: .server("web")),
                BrowserConsoleLine(id: 9004, level: .info, text: "web answers at http://localhost:5173/", source: .browser),
            ]
            let page = console.filter { $0.source == .page }
            lines += page.isEmpty ? [BrowserConsoleLine(id: 9005, level: .error, text: "TypeError: projects.map is not a function", source: .page)] : page
            return lines
        }
    }

    /// The sample page: a small project dashboard that logs at each level, throws, and rejects a promise.
    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>Acme Projects</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      * { box-sizing: border-box; }
      body { margin: 0; font: 15px/1.45 -apple-system, system-ui, sans-serif; color: #1f2328; background: #f6f7f9; }
      header { display: flex; align-items: center; gap: 12px; padding: 14px 22px; background: #fff; border-bottom: 1px solid #e3e5e8; }
      .logo { width: 26px; height: 26px; border-radius: 7px; background: linear-gradient(135deg, #5b7cfa, #8a5cf6); }
      header b { font-size: 16px; } nav { margin-left: auto; display: flex; gap: 16px; color: #59636e; font-size: 14px; }
      main { padding: 22px; max-width: 900px; margin: 0 auto; }
      h1 { font-size: 22px; margin: 0 0 4px; } p.sub { margin: 0 0 18px; color: #59636e; }
      .bar { display: flex; gap: 10px; margin-bottom: 18px; flex-wrap: wrap; }
      .btn { border: 1px solid #d0d4d9; background: #fff; border-radius: 8px; padding: 8px 14px; font: inherit; font-size: 14px; }
      .btn.primary { background: #5b7cfa; border-color: #5b7cfa; color: #fff; }
      input { flex: 1; min-width: 160px; border: 1px solid #d0d4d9; border-radius: 8px; padding: 8px 12px; font: inherit; font-size: 14px; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 14px; }
      .card { background: #fff; border: 1px solid #e3e5e8; border-radius: 12px; padding: 16px; }
      .card h2 { font-size: 15px; margin: 0 0 6px; } .card p { margin: 0 0 12px; color: #59636e; font-size: 13.5px; }
      .tag { display: inline-block; font-size: 12px; padding: 2px 8px; border-radius: 99px; background: #eef1fe; color: #3b5bdb; }
      .tag.warn { background: #fff4e5; color: #b35c00; } .tag.ok { background: #e7f6ec; color: #1a7f37; }
      @media (max-width: 500px) { nav { display: none; } main { padding: 16px; } h1 { font-size: 19px; } }
    </style></head><body>
    <header><div class="logo"></div><b>Acme</b><nav><span>Projects</span><span>Team</span><span>Settings</span></nav></header>
    <main>
      <h1>Projects</h1><p class="sub">6 active, 2 need review</p>
      <div class="bar"><input placeholder="Search projects"><button id="new-project" class="btn primary">New project</button><button class="btn">Filter</button></div>
      <div class="grid">
        <div class="card"><h2>Checkout redesign</h2><p>New payment flow and order summary.</p><span class="tag ok">On track</span></div>
        <div class="card"><h2>Search service</h2><p>Move indexing to the new queue.</p><span class="tag warn">Needs review</span></div>
        <div class="card"><h2>Mobile onboarding</h2><p>Three screens and a progress bar.</p><span class="tag">In design</span></div>
        <div class="card"><h2>Billing exports</h2><p>CSV and PDF exports for invoices.</p><span class="tag ok">On track</span></div>
        <div class="card"><h2>Status page</h2><p>Public uptime and incident history.</p><span class="tag warn">Needs review</span></div>
        <div class="card"><h2>Docs site</h2><p>Guides, API reference and search.</p><span class="tag">Planned</span></div>
      </div>
    </main>
    <script>
      console.log('App mounted in 182 ms');
      console.info('Fetching /api/projects');
      console.warn('Each child in a list should have a unique "key" prop.');
      console.error('Failed to load /api/team: 500 Internal Server Error');
      setTimeout(function () { projects.map(function (p) { return p; }); }, 0);
      Promise.reject(new Error('Network request failed'));
    </script>
    </body></html>
    """

    @MainActor private final class Answer {
        var text: String?
        var done = false
    }

    @MainActor private final class Picture {
        var image: NSImage?
        var done = false
    }

    static func run(zoom: CGFloat) -> Result {
        _ = NSApplication.shared
        let page = BrowserPage(owner: "browser-check", folder: NSTemporaryDirectory())
        let webView = page.webView
        let fullSize = NSSize(width: BrowserPane.width * zoom, height: 760 * zoom)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fullSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        webView.frame = NSRect(origin: .zero, size: fullSize)
        webView.pageZoom = zoom
        window.contentView = webView
        defer { window.close() }

        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > deadline { return false }
                spin(0.05)
            }
            return true
        }
        func pageScript(_ source: String) -> String? {
            let answer = Answer()
            webView.evaluateJavaScript(source, in: nil, in: .page) { result in
                MainActor.assumeIsolated {
                    if case .success(let value) = result { answer.text = value as? String }
                    answer.done = true
                }
            }
            _ = wait(5) { answer.done }
            return answer.text
        }

        // The page loads with an http origin (the HTML comes from here; nothing is fetched).
        page.loadForCheck(html: html, baseURL: URL(string: "http://localhost:5173/projects") ?? LaunchEntry.defaultURL(port: 5173))
        let loaded = wait(15) { !webView.isLoading && webView.url?.host() == "localhost" }
        let captured = wait(5) {
            let page = page.console.filter { $0.source == .page }
            return page.contains { $0.text.contains("Network request failed") } && page.contains { $0.text.contains("projects") && $0.level == .error && $0.text.contains("Can't find variable") }
        }
        let pageLines = page.console.filter { $0.source == .page }
        let levels = Set(pageLines.map(\.level))
        let consoleWorks = captured && levels.isSuperset(of: [.log, .info, .warn, .error])
        spin(0.3)
        let fullImage = snapshot(webView, wait: wait)

        // The page's world sees no Ensemble handler.
        let handlerVisible = pageScript("""
        (function () { try { return typeof window.webkit.messageHandlers.\(BrowserScripts.consoleHandler); } catch (e) { return 'undefined'; } })()
        """)
        let bridgeHidden = handlerVisible == "undefined"

        // The element picker: a click on the button is caught before the page sees it.
        _ = pageScript("window.__clicks = 0; document.getElementById('new-project').addEventListener('click', function () { window.__clicks++; }); 'ok'")
        page.startPicking()
        spin(0.3)
        _ = pageScript("document.getElementById('new-project').click(); 'ok'")
        let picked = wait(5) { page.picked != nil }
        let pickSummary = page.picked?.summary ?? ""
        let pageSawClick = pageScript("String(window.__clicks)") != "0"
        let pickerWorks = picked && pickSummary.hasPrefix("button#new-project") && !pageSawClick
        page.clearPicked()

        // file: and custom schemes are refused however they are asked for.
        let before = page.console.count
        page.go("file:///etc/hosts")
        let typedRefused = page.addressError != nil
        webView.load(URLRequest(url: URL(fileURLWithPath: "/etc/hosts")))
        spin(0.5)
        webView.loadFileURL(URL(fileURLWithPath: "/etc/hosts"), allowingReadAccessTo: URL(fileURLWithPath: "/etc"))
        spin(0.5)
        _ = pageScript("location.href = 'file:///etc/hosts'; 'ok'")
        spin(0.5)
        let fileRefused = typedRefused && webView.url?.scheme == "http"
            && page.console.dropFirst(before).filter { $0.text.contains("Blocked a file: address") }.count >= 2
        _ = pageScript("location.href = 'x-ensemble-check://open'; 'ok'")
        spin(0.5)
        let customRefused = webView.url?.scheme == "http" && page.console.contains { $0.text.contains("Blocked a x-ensemble-check: address") }

        // A phone-width picture: 390 CSS pixels across.
        let phoneSize = NSSize(width: 390 * zoom, height: 760 * zoom)
        window.setContentSize(phoneSize)
        webView.frame = NSRect(origin: .zero, size: phoneSize)
        spin(0.4)
        let phoneImage = snapshot(webView, wait: wait)
        let innerWidth = pageScript("String(window.innerWidth)") ?? "?"

        print("Browser check: page loaded \(loaded), console capture \(consoleWorks) (\(pageLines.count) lines: "
              + "\(levels.map(\.rawValue).sorted().joined(separator: ", "))), page cannot see the handlers \(bridgeHidden), "
              + "element picker \(pickerWorks) (\(pickSummary)), file: refused \(fileRefused), custom scheme refused \(customRefused), "
              + "phone width \(innerWidth) px, screenshots \(fullImage != nil && phoneImage != nil)")
        return Result(fullImage: fullImage, phoneImage: phoneImage, console: page.console)
    }

    /// With `ENSEMBLE_BROWSER_SERVER_CHECK=1`, runs a real dev server through the pane's own wiring: a temporary folder
    /// with `.ensemble/launch.json` (python3's http.server on a free port), refused while untrusted, asked about once,
    /// started, the page loaded, server and page lines in the console, a screenshot, stopped, started again without
    /// asking, and stopped by closing the session. Prints one line. Without the variable nothing runs.
    static func runServer() {
        guard ProcessInfo.processInfo.environment["ENSEMBLE_BROWSER_SERVER_CHECK"] == "1" else { return }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ensemble-browser-server-\(UUID().uuidString.prefix(8))")
        let site = root.appendingPathComponent("site")
        defer { try? fm.removeItem(at: root) }
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > deadline { return false }
                spin(0.05)
            }
            return true
        }
        let port = freePort()
        do {
            try fm.createDirectory(at: site.appendingPathComponent(".ensemble"), withIntermediateDirectories: true)
            try Data("<!doctype html><title>Check</title><h1>Served</h1><script>console.error('from the dev page')</script>".utf8)
                .write(to: site.appendingPathComponent("index.html"))
            let launch = #"[{"name": "site", "command": "python3 -u -m http.server \#(port) --bind 127.0.0.1", "port": \#(port)}]"#
            try Data(launch.utf8).write(to: LaunchConfig.fileURL(in: site.path))
        } catch {
            print("Browser server check: could not set up the folder: \(error.localizedDescription)")
            return
        }
        let trust = WorkspaceTrust(fileURL: root.appendingPathComponent("trust.json"), homeDirectory: root.appendingPathComponent("home").path)
        let servers = DevServers(trust: trust, approvals: LaunchApprovals(fileURL: nil))
        let center = BrowserCenter(servers: servers)
        let page = BrowserPage(owner: "server-check", folder: site.path)
        center.install(page)
        // The real pane in a window that is never shown, so its web view is attached by `BrowserWebView`.
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        guard let session = store.selected else { return }
        let pane = BrowserPane(page: page, store: store, session: session, servers: servers, onClose: {})
            .ensembleTheme()
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: BrowserPane.width, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: BrowserPane.width, height: 800)
        defer { window.close() }
        spin(0.5)

        page.reloadLaunchConfig()
        guard let entry = page.launch.entries.first else {
            print("Browser server check: launch.json not read (\(page.launch))")
            return
        }
        page.start(entry, servers: servers)
        let untrustedRefused = page.notice == .needsTrust(entry) && !PortProbe.isListening(port)
        try? trust.trust(site.path)
        page.start(entry, servers: servers)
        let asked = page.pendingStart?.entry == entry && !PortProbe.isListening(port)
        page.start(entry, servers: servers, confirmed: true)
        let loaded = wait(20) { page.url?.port == port && !page.webView.isLoading && page.title == "Check" }
        let inPane = page.webView.window === window && page.webView.frame.width > 100
        let pageLine = wait(5) { page.console.contains { $0.source == .page && $0.text == "from the dev page" } }
        let serverLine = wait(5) { page.console.contains { $0.source == .server("site") && $0.text.contains("Serving HTTP") } }

        @MainActor final class Shot { var file: URL?; var done = false }
        let shot = Shot()
        Task { @MainActor in
            shot.file = try? await page.screenshotFile()
            shot.done = true
        }
        _ = wait(10) { shot.done }
        let screenshot = shot.file.map { fm.fileExists(atPath: $0.path) && (NSImage(contentsOf: $0)?.size.width ?? 0) > 0 } ?? false
        if let file = shot.file { try? fm.removeItem(at: file) }

        page.stop(entry, servers: servers)
        let stopped = wait(6) { !PortProbe.isListening(port) }
        page.start(entry, servers: servers)
        let notAskedAgain = page.pendingStart == nil && wait(20) { page.status(entry, servers: servers).isActive && PortProbe.isListening(port) }
        center.close(owners: [page.owner])
        let closedStops = wait(6) { !PortProbe.isListening(port) }
        servers.stopAllNow()
        print("Browser server check: untrusted refused \(untrustedRefused), asks first \(asked), page loaded \(loaded) in the pane \(inPane), "
              + "page console \(pageLine), server output \(serverLine), screenshot \(screenshot), stop frees the port \(stopped), "
              + "second start without asking \(notAskedAgain), closing the session stops it \(closedStops)")
    }

    /// A port nothing listens on right now.
    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func snapshot(_ webView: WKWebView, wait: (TimeInterval, () -> Bool) -> Bool) -> NSImage? {
        let box = Picture()
        webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
            MainActor.assumeIsolated {
                box.image = image
                box.done = true
            }
        }
        _ = wait(10) { box.done }
        return box.image
    }
}
