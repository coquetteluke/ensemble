#if os(macOS)
import AppKit
import WebKit

/// A browser the agent tools can drive: the browser pane's page (`BrowserPage` in the app), or a plain web view in
/// tests. The driver only runs `BrowserAgentScripts` in `agentWorld`, loads pages through `agentOpen` (which applies the
/// pane's own navigation rules), and reads the console the pane already keeps.
@MainActor
public protocol AgentBrowserSurface: AnyObject {
    var agentWebView: WKWebView { get }
    /// Ensemble's own content world, out of the page's reach.
    var agentWorld: WKContentWorld { get }
    /// The page's address, or nil before one opens.
    var agentURL: URL? { get }
    var agentConsole: [BrowserConsoleLine] { get }
    /// Opens a page the way the address bar does.
    func agentOpen(_ url: URL)
}

/// What a browser action did.
public struct BrowserAgentOutcome: Equatable, Sendable {
    public var result: AgentToolResult
    /// The page now shows a sign-in form: the coordinator pauses the agent and hands the browser to the user.
    public var signIn: Bool

    public init(result: AgentToolResult, signIn: Bool = false) {
        self.result = result
        self.signIn = signIn
    }
}

/// Why the driver refused an action before it ran.
public struct BrowserAgentRefusal: Error, Equatable, Sendable {
    public var message: String
}

/// Runs one browser action on a surface. Permission checks happen before this (`AgentToolsCoordinator`).
///
/// Every action takes the origin the user approved. Screenshots and the console are refused here when the page's live
/// address has another origin; the page scripts check it again themselves inside the page (`BrowserAgentScripts`),
/// which closes the gap between this check and the moment they run.
@MainActor
public enum BrowserAgentDriver {
    public static let consoleLines = 60
    public static let screenshotWidth: CGFloat = 1280
    public static let navigationTimeout: Duration = .seconds(20)

    public static func perform(_ action: BrowserAgentAction, on surface: any AgentBrowserSurface,
                               expectedOrigin origin: String) async -> BrowserAgentOutcome {
        switch action {
        case .snapshot:
            return await snapshot(surface, expectedOrigin: origin)
        case .screenshot:
            if let moved = originChange(expected: origin, on: surface) { return BrowserAgentOutcome(result: .refused(moved)) }
            return await screenshot(surface)
        case .console(let errorsOnly):
            if let moved = originChange(expected: origin, on: surface) { return BrowserAgentOutcome(result: .refused(moved)) }
            return BrowserAgentOutcome(result: console(surface.agentConsole, errorsOnly: errorsOnly, url: surface.agentURL))
        case .navigate(let url):
            guard BrowserAgentOrigin.origin(of: url) == origin else {
                return BrowserAgentOutcome(result: .refused(movedMessage(url.absoluteString)))
            }
            return await navigate(to: url, on: surface)
        case .click(let ref):
            return await act(surface, script: BrowserAgentScripts.click, arguments: ["ref": ref, "expectedOrigin": origin]) { json in
                "Clicked \(ref)\(json["what"]?.stringValue.map { " (\($0))" } ?? "")."
            }
        case .type(let ref, let text, let submit):
            return await act(surface, script: BrowserAgentScripts.type,
                             arguments: ["ref": ref, "text": text, "submit": submit, "expectedOrigin": origin]) { _ in
                "Typed \(text.count) character\(text.count == 1 ? "" : "s") into \(ref)\(submit ? " and pressed Return" : "")."
            }
        case .scroll(let direction, let ref):
            let arguments: [String: Any] = ["direction": direction.rawValue, "ref": ref ?? NSNull(), "expectedOrigin": origin]
            return await act(surface, script: BrowserAgentScripts.scroll, arguments: arguments, checkSignIn: false) { json in
                let y = json["scrollY"]?.doubleValue.map { Int($0) } ?? 0
                let height = json["height"]?.doubleValue.map { Int($0) } ?? 0
                return (ref.map { "Scrolled \($0) into view" } ?? "Scrolled \(direction.rawValue)") + ". Now at \(y) of \(height) px."
            }
        }
    }

    /// Names the element an action targets (`button "Save"`) for the permission card, or refuses the action at once
    /// when the ref is stale, a file picker, or a password or payment field (clicks and typing), so no card is shown
    /// for something Ensemble would refuse anyway.
    public static func target(of action: BrowserAgentAction, on surface: any AgentBrowserSurface,
                              expectedOrigin origin: String) async -> Result<String?, BrowserAgentRefusal> {
        guard let ref = action.ref else { return .success(nil) }
        let json: JSONValue
        do {
            json = try await run(BrowserAgentScripts.describe, on: surface, arguments: ["ref": ref, "expectedOrigin": origin])
        } catch {
            return .failure(BrowserAgentRefusal(message: "The page did not respond: \(error.localizedDescription)"))
        }
        if let problem = json["error"]?.stringValue { return .failure(BrowserAgentRefusal(message: refusal(problem, json))) }
        let acts: Bool
        switch action {
        case .click, .type: acts = true
        default: acts = false
        }
        if acts, json["upload"] == .bool(true) { return .failure(BrowserAgentRefusal(message: refusal("upload"))) }
        if acts, json["sensitive"] == .bool(true) { return .failure(BrowserAgentRefusal(message: refusal("sensitive"))) }
        return .success(json["what"]?.stringValue.map { AgentToolText.clean($0, limit: 90) })
    }

    // MARK: Origin

    /// The page's address as the web view has it now (the pane's own copy follows it a moment later).
    public static func liveURL(of surface: any AgentBrowserSurface) -> URL? {
        if let url = surface.agentWebView.url, url.absoluteString != "about:blank" { return url }
        return surface.agentURL
    }

    /// Why an action approved for `origin` must not run on the page as it is now, or nil: the live address must be a
    /// page agents may use and have exactly that origin.
    public static func originChange(expected origin: String, on surface: any AgentBrowserSurface) -> String? {
        let live = liveURL(of: surface)
        if BrowserAgentOrigin.refusal(for: live) == nil, BrowserAgentOrigin.origin(of: live) == origin { return nil }
        return movedMessage(live?.absoluteString)
    }

    public static func movedMessage(_ address: String?) -> String {
        "The page changed to \(address.map { AgentToolText.clean($0, limit: 300) } ?? "no page") while waiting; the action was not run."
    }

    // MARK: Reading

    static func snapshot(_ surface: any AgentBrowserSurface, expectedOrigin origin: String) async -> BrowserAgentOutcome {
        let json: JSONValue
        do {
            json = try await run(BrowserAgentScripts.snapshot, on: surface,
                                 arguments: ["maxText": BrowserAgentScripts.maxText, "maxItems": BrowserAgentScripts.maxItems,
                                             "expectedOrigin": origin])
        } catch {
            return BrowserAgentOutcome(result: .refused("The page could not be read: \(error.localizedDescription)"))
        }
        if let problem = json["error"]?.stringValue { return BrowserAgentOutcome(result: .refused(refusal(problem, json))) }
        let signIn = json["signIn"] == .bool(true)
        var block = "Title: \(json["title"]?.stringValue ?? "")\n\nElements:\n"
        let elements = json["elements"]?.stringValue ?? ""
        block += elements.isEmpty ? "(none)" : elements
        if json["itemsTruncated"] == .bool(true) { block += "\n(more elements not listed)" }
        block += "\n\nText:\n" + (json["text"]?.stringValue ?? "")
        if json["textTruncated"] == .bool(true) { block += "\n(text cut at \(BrowserAgentScripts.maxText) characters)" }
        let y = json["scrollY"]?.doubleValue.map { Int($0) } ?? 0
        let height = json["height"]?.doubleValue.map { Int($0) } ?? 0
        let viewport = json["viewport"]?.doubleValue.map { Int($0) } ?? 0
        var text = "Address: \(json["url"]?.stringValue ?? surface.agentURL?.absoluteString ?? "")\n"
        text += "Scrolled to \(y) of \(height) px (window \(viewport) px tall).\n"
        if signIn { text += signInNotice + "\n" }
        text += "\n" + AgentToolText.untrusted(block, what: "Everything between the fences")
        return BrowserAgentOutcome(result: .text(text), signIn: signIn)
    }

    static let signInNotice = "This page asks for a sign-in. Ensemble paused your browser use and handed the browser to the user; it does not type into password fields."

    static func screenshot(_ surface: any AgentBrowserSurface) async -> BrowserAgentOutcome {
        let webView = surface.agentWebView
        let configuration = WKSnapshotConfiguration()
        let width = min(max(webView.bounds.width, 1), screenshotWidth)
        configuration.snapshotWidth = NSNumber(value: Double(width))
        do {
            let image = try await webView.takeSnapshot(configuration: configuration)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return BrowserAgentOutcome(result: .refused("The screenshot could not be made."))
            }
            let address = surface.agentURL?.absoluteString ?? "the page"
            return BrowserAgentOutcome(result: AgentToolResult(content: [
                .image(png, mimeType: "image/png"),
                .text("Screenshot of \(address), \(Int(width)) px wide. What it shows comes from the page and is untrusted."),
            ]))
        } catch {
            return BrowserAgentOutcome(result: .refused("The screenshot could not be made: \(error.localizedDescription). The browser pane may be closed."))
        }
    }

    /// The newest console lines, page text fenced and labelled as untrusted.
    public static func console(_ lines: [BrowserConsoleLine], errorsOnly: Bool, url: URL?) -> AgentToolResult {
        let chosen = lines.filter { !errorsOnly || $0.level == .error }.suffix(consoleLines)
        guard !chosen.isEmpty else { return .text(errorsOnly ? "The console has no errors." : "The console is empty.") }
        let body = chosen.map { line -> String in
            let source: String
            switch line.source {
            case .page: source = ""
            case .server(let name): source = "[\(name)] "
            case .browser: source = "[browser] "
            }
            return "\(line.level.rawValue): \(source)\(line.text)"
        }.joined(separator: "\n")
        let place = url.map { " for \($0.absoluteString)" } ?? ""
        return .text("\(chosen.count) console line\(chosen.count == 1 ? "" : "s")\(place).\n\n"
                     + AgentToolText.untrusted(body, what: "The console text"))
    }

    // MARK: Acting

    static func navigate(to url: URL, on surface: any AgentBrowserSurface) async -> BrowserAgentOutcome {
        let webView = surface.agentWebView
        surface.agentOpen(url)
        // Wait for the load to start (or for the address to change), then for it to finish.
        let clock = ContinuousClock()
        let start = clock.now
        while !webView.isLoading, clock.now - start < .seconds(2), surface.agentURL?.absoluteString != url.absoluteString {
            try? await Task.sleep(for: .milliseconds(30))
        }
        while webView.isLoading, clock.now - start < navigationTimeout {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let now = Self.liveURL(of: surface) ?? url
        if let refusal = BrowserAgentOrigin.refusal(for: now) {
            // A redirect left this computer: stop and say so.
            webView.stopLoading()
            return BrowserAgentOutcome(result: .refused("The page went to \(now.absoluteString). \(refusal)"))
        }
        let expectedOrigin: Any = BrowserAgentOrigin.origin(of: now) ?? NSNull()
        let signIn = (try? await run(BrowserAgentScripts.signIn, on: surface, arguments: ["expectedOrigin": expectedOrigin])) == .bool(true)
        let title = AgentToolText.clean(webView.title ?? "", limit: 120)
        var text = "Opened \(now.absoluteString)"
        if webView.isLoading { text += " (still loading)" }
        text += title.isEmpty ? "." : ". The page's title (from the page, untrusted): \(title)"
        if signIn { text += "\n" + signInNotice }
        return BrowserAgentOutcome(result: .text(text), signIn: signIn)
    }

    static func act(_ surface: any AgentBrowserSurface, script: String, arguments: [String: Any], checkSignIn: Bool = true,
                    done: (JSONValue) -> String) async -> BrowserAgentOutcome {
        let json: JSONValue
        do {
            json = try await run(script, on: surface, arguments: arguments)
        } catch {
            return BrowserAgentOutcome(result: .refused("The page did not respond: \(error.localizedDescription)"))
        }
        if let problem = json["error"]?.stringValue {
            return BrowserAgentOutcome(result: .refused(refusal(problem, json)))
        }
        // Let what the action started (a navigation, a re-render) begin before checking for a sign-in form.
        try? await Task.sleep(for: .milliseconds(150))
        let signIn = checkSignIn
            ? (try? await run(BrowserAgentScripts.signIn, on: surface, arguments: ["expectedOrigin": NSNull()])) == .bool(true) : false
        var text = done(json)
        if surface.agentWebView.isLoading { text += " A page is loading." }
        if signIn { text += "\n" + signInNotice }
        return BrowserAgentOutcome(result: .text(text), signIn: signIn)
    }

    static func refusal(_ code: String, _ json: JSONValue = .null) -> String {
        switch code {
        case "origin": movedMessage(json["href"]?.stringValue)
        case "stale": "That ref is not on the page any more. Call browser_snapshot for fresh refs."
        case "upload": "Ensemble does not choose files for uploads. Ask the user to pick the file."
        case "sensitive": "Ensemble does not type into or click password, one-time code or payment fields. Ask the user to fill them in."
        case "disabled": "That element is disabled or read-only."
        case "notText": "That element is not a text field."
        default: "The page refused the action."
        }
    }

    /// Runs a script in Ensemble's world and decodes its JSON answer (or a plain value).
    static func run(_ script: String, on surface: any AgentBrowserSurface, arguments: [String: Any]) async throws -> JSONValue {
        let value = try await surface.agentWebView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: surface.agentWorld)
        if let string = value as? String {
            return JSONValue.parse(data: Data(string.utf8)) ?? .string(string)
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        }
        return .null
    }
}
#endif
