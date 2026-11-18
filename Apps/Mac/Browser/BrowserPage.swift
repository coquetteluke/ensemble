import SwiftUI
import AppKit
import WebKit
import EnsembleKit

/// One session's browser: the web view, its address and history, the console, the device width, the element picker,
/// and the dev servers from the session folder's `.ensemble/launch.json`.
///
/// The web view is an ordinary browser for the user's own pages, locked down:
/// - a non-persistent website data store of its own, so no cookies or sign-ins come in or go out;
/// - only `http`, `https` and blank frames load (`BrowserNavigationPolicy`); `file:`, `data:`, `blob:`, `javascript:`
///   and custom schemes are refused, downloads are off, and pop-ups open in the same view;
/// - the only script in the page's world is the console capture, which turns console calls into DOM events; the
///   handlers that pass them on (and the element picker) live in Ensemble's own content world, out of the page's reach;
/// - pages load only from the address bar, a launch entry or the page itself, never from agent text.
@Observable @MainActor
final class BrowserPage {
    /// The session this browser belongs to.
    let owner: String
    /// The session's folder (where `.ensemble/launch.json` is read and servers run).
    var folder: String

    private(set) var url: URL?
    private(set) var title = ""
    var addressText = ""
    var addressError: String?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// A page was asked for (the web view is on screen from then on).
    private(set) var hasPage = false
    /// Why the last page did not load.
    private(set) var loadError: String?

    private(set) var console: [BrowserConsoleLine] = []
    var consoleOpen = false
    var device: BrowserDeviceWidth = .full

    /// Picking an element with the inspector click.
    private(set) var picking = false
    private(set) var picked: PickedElement?

    /// The dev servers file, read when the list is shown.
    private(set) var launch: LaunchConfigLoad = .missing
    /// A start that needs the user to confirm the command.
    var pendingStart: PendingStart?
    var notice: Notice?

    /// Snapshots: a picture of the page in place of the web view (`ImageRenderer` cannot draw web views).
    var snapshotImage: NSImage?

    struct PickedElement: Equatable {
        var summary: String
        var html: String
        var truncated: Bool
    }

    struct PendingStart: Equatable {
        var entry: LaunchEntry
        /// The program's full path.
        var program: String
    }

    enum Notice: Equatable {
        /// The folder is not trusted; the entry the user tried to start.
        case needsTrust(LaunchEntry)
        case portInUse(name: String, url: URL)
        case failed(String)
    }

    static let maxConsoleLines = 1000

    @ObservationIgnored private var storedWebView: WKWebView?
    @ObservationIgnored private var delegate: BrowserWebDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var nextLineID = 0
    @ObservationIgnored let world = WKContentWorld.world(name: BrowserScripts.worldName)

    init(owner: String, folder: String) {
        self.owner = owner
        self.folder = folder
    }

    /// The web view, made on first use.
    var webView: WKWebView {
        if let storedWebView { return storedWebView }
        let made = makeWebView()
        storedWebView = made
        return made
    }

    var hasWebView: Bool { storedWebView != nil }

    // MARK: Web view

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let delegate = BrowserWebDelegate(page: self)
        self.delegate = delegate
        let controller = configuration.userContentController
        // The reader and its handlers in Ensemble's world; the page world only gets the capture shim.
        controller.addUserScript(WKUserScript(source: BrowserScripts.consoleReader, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: BrowserScripts.pageCapture, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.add(delegate, contentWorld: world, name: BrowserScripts.consoleHandler)
        controller.add(delegate, contentWorld: world, name: BrowserScripts.pickHandler)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), configuration: configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        // Safari's Develop menu can inspect the page, as with any local dev page.
        webView.isInspectable = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.urlChanged(view.url) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
        ]
        return webView
    }

    private func urlChanged(_ newURL: URL?) {
        guard let newURL, newURL.absoluteString != "about:blank" else { return }
        url = newURL
        addressText = newURL.absoluteString
        addressError = nil
    }

    // MARK: Navigation

    /// Opens what the user typed.
    func go(_ text: String) {
        switch BrowserAddress.url(from: text) {
        case .success(let target):
            load(target)
        case .failure(let problem):
            addressError = problem.localizedDescription
        }
    }

    /// Opens a page (typed, or from a launch entry).
    func load(_ target: URL) {
        guard BrowserNavigationPolicy.allows(target), target.scheme?.lowercased() != "about" else {
            note("Blocked a \(BrowserNavigationPolicy.schemeName(target)): address. Only http and https pages open here.", level: .warn)
            return
        }
        addressError = nil
        loadError = nil
        hasPage = true
        addressText = target.absoluteString
        if url == nil { url = target }
        webView.load(URLRequest(url: target))
    }

    func goBack() { if hasWebView { webView.goBack() } }
    func goForward() { if hasWebView { webView.goForward() } }

    func reload() {
        guard hasWebView else { return }
        loadError = nil
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    func stopLoading() { if hasWebView { webView.stopLoading() } }

    /// Opens the page in the default browser (http and https only).
    func openExternally() {
        guard let url, BrowserNavigationPolicy.opensExternally(url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Console

    func note(_ text: String, level: BrowserConsoleLine.Level = .info) {
        append(level: level, text: text, source: .browser)
    }

    func append(level: BrowserConsoleLine.Level, text: String, source: BrowserConsoleLine.Source) {
        nextLineID += 1
        console.append(BrowserConsoleLine(id: nextLineID, level: level, text: text, source: source))
        if console.count > Self.maxConsoleLines { console.removeFirst(console.count - Self.maxConsoleLines) }
    }

    func clearConsole() { console.removeAll() }

    var errorCount: Int { console.reduce(0) { $0 + ($1.level == .error ? 1 : 0) } }
    var warningCount: Int { console.reduce(0) { $0 + ($1.level == .warn ? 1 : 0) } }

    // MARK: Element picker

    func startPicking() {
        guard hasWebView, hasPage else { return }
        picked = nil
        picking = true
        webView.evaluateJavaScript(BrowserScripts.startPicking, in: nil, in: world, completionHandler: nil)
    }

    func cancelPicking() {
        picking = false
        if hasWebView { webView.evaluateJavaScript(BrowserScripts.cancelPicking, in: nil, in: world, completionHandler: nil) }
    }

    func clearPicked() { picked = nil }

    fileprivate func receivePick(_ body: Any) {
        guard picking else { return }
        picking = false
        if let result = BrowserScripts.pickResult(body) {
            picked = PickedElement(summary: result.summary, html: result.html, truncated: result.truncated)
        }
    }

    // MARK: Screenshot

    /// A PNG of the page as shown, saved under Application Support for the message.
    func screenshotFile() async throws -> URL {
        let image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserPageError.screenshot
        }
        let folder = Self.screenshotFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.pruneScreenshots(in: folder)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let file = folder.appendingPathComponent("page-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).png")
        try png.write(to: file, options: .atomic)
        return file
    }

    static var screenshotFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/Browser Screenshots", isDirectory: true)
    }

    /// Keeps the newest 50 screenshots.
    private static func pruneScreenshots(in folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.filter { $0.pathExtension == "png" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(49) { try? fm.removeItem(at: file) }
    }

    // MARK: Dev servers

    func reloadLaunchConfig() {
        launch = LaunchConfig.load(folder: folder)
    }

    /// Shows the dev servers in snapshots without reading a folder.
    func setLaunchForSnapshot(_ load: LaunchConfigLoad) { launch = load }

    /// The snapshot check: loads HTML from Ensemble itself under an http origin (nothing is fetched).
    func loadForCheck(html: String, baseURL: URL) {
        hasPage = true
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// Snapshots: a page as if it had loaded, drawn from a picture.
    func showForSnapshot(url: URL, title: String, image: NSImage?, console lines: [BrowserConsoleLine]) {
        self.url = url
        self.title = title
        addressText = url.absoluteString
        hasPage = true
        canGoBack = true
        snapshotImage = image
        console = lines
    }

    /// Snapshots: an element as if it had been picked.
    func pickForSnapshot(summary: String, html: String) {
        picked = PickedElement(summary: summary, html: html, truncated: false)
    }

    func status(_ entry: LaunchEntry, servers: DevServers) -> DevServers.Status {
        servers.status(DevServers.Key(owner: owner, folder: folder, name: entry.name))
    }

    /// Starts a server, or shows what is needed first (trust, the confirmation, a server already on the port).
    func start(_ entry: LaunchEntry, servers: DevServers, confirmed: Bool = false) {
        notice = nil
        switch servers.start(entry, folder: folder, owner: owner, confirmed: confirmed) {
        case .needsTrust:
            pendingStart = nil
            notice = .needsTrust(entry)
        case .portInUse(let url):
            pendingStart = nil
            notice = .portInUse(name: entry.name, url: url)
        case .needsConfirmation(let program):
            pendingStart = PendingStart(entry: entry, program: program)
        case .started:
            pendingStart = nil
            consoleOpen = true
            note("Starting \(entry.name): \(entry.commandLine)")
        case .alreadyRunning:
            pendingStart = nil
            if case .running(let url) = status(entry, servers: servers) { load(url) }
        case .failed(let message):
            pendingStart = nil
            notice = .failed(message)
        }
    }

    func stop(_ entry: LaunchEntry, servers: DevServers) {
        let key = DevServers.Key(owner: owner, folder: folder, name: entry.name)
        Task { await servers.stop(key) }
        note("Stopped \(entry.name).")
    }

    // MARK: From the delegate

    fileprivate func receiveConsole(_ body: Any) {
        guard let message = BrowserConsoleLine.pageMessage(body) else { return }
        append(level: message.level, text: message.text, source: .page)
    }

    fileprivate func navigationStarted() {
        loadError = nil
        if picking { picking = false }
        picked = nil
    }

    fileprivate func navigationFailed(_ error: Error, url failedURL: URL?) {
        let nsError = error as NSError
        // Cancelled loads and loads turned into something else (a refused download) are not failures.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        let address = failedURL?.absoluteString ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? "the page"
        loadError = nsError.localizedDescription
        note("Could not load \(address): \(nsError.localizedDescription)", level: .error)
    }

    fileprivate func processEnded() {
        loadError = "The page stopped responding."
        note("The page stopped responding. Reload to try again.", level: .error)
    }
}

enum BrowserPageError: Error, LocalizedError {
    case screenshot

    var errorDescription: String? { "The screenshot could not be made." }
}

/// The web view's delegates and message handlers. Holds the page weakly (the page owns the web view).
@MainActor
final class BrowserWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var page: BrowserPage?

    init(page: BrowserPage) { self.page = page }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let target = navigationAction.request.url
        if navigationAction.shouldPerformDownload {
            page?.note("Downloads are off in the browser pane: \(target?.absoluteString ?? "")", level: .warn)
            decisionHandler(.cancel)
            return
        }
        guard BrowserNavigationPolicy.allows(target) else {
            page?.note("Blocked a \(BrowserNavigationPolicy.schemeName(target)): address. Only http and https pages open here.", level: .warn)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            page?.note("Downloads are off in the browser pane: \(navigationResponse.response.url?.absoluteString ?? "")", level: .warn)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        page?.navigationStarted()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        page?.navigationFailed(error, url: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        page?.navigationFailed(error, url: webView.url)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        page?.processEnded()
    }

    // Pop-ups and target=_blank links open in the same view (when they are web pages).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let target = navigationAction.request.url, BrowserNavigationPolicy.allows(target),
           target.scheme?.lowercased() != "about" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // Dialogs go to the console instead of blocking the window: alert returns, confirm answers no, prompt answers nothing.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        page?.append(level: .info, text: "alert: \(message)", source: .page)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        page?.append(level: .info, text: "confirm (answered Cancel): \(message)", source: .page)
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        page?.append(level: .info, text: "prompt (answered Cancel): \(prompt)", source: .page)
        completionHandler(nil)
    }

    // File inputs open the standard panel; the user picks the files.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            MainActor.assumeIsolated { completionHandler(response == .OK ? panel.urls : nil) }
        }
    }

    // Camera and microphone stay off.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only Ensemble's own world can post to these handlers; check anyway.
        guard message.world.name == BrowserScripts.worldName else { return }
        switch message.name {
        case BrowserScripts.consoleHandler: page?.receiveConsole(message.body)
        case BrowserScripts.pickHandler where message.frameInfo.isMainFrame: page?.receivePick(message.body)
        default: break
        }
    }
}
