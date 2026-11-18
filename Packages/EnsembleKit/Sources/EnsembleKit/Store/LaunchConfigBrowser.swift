import Foundation

// The browser pane's rules and texts, kept apart from the web view so they can be tested: which addresses and
// navigations are allowed, the console capture scripts, device widths, and the messages sent to an agent.

// MARK: Addresses

/// Turns what the user typed in the address bar into a page address. Only `http` and `https` pages open.
public enum BrowserAddress {
    public enum Problem: Error, LocalizedError, Equatable, Sendable {
        case empty
        case notWeb(String)
        case invalid

        public var errorDescription: String? {
            switch self {
            case .empty: "Type an address."
            case .notWeb(let scheme): "Only http and https pages open here, not \(scheme): addresses."
            case .invalid: "That is not a web address."
            }
        }
    }

    /// `localhost:3000` and `3000` open `http://localhost:3000/`; addresses on this computer or the local network get
    /// `http`, anything else without a scheme gets `https`. `file:`, `data:`, `javascript:` and other schemes are refused.
    public static func url(from text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.contains(where: { $0.isWhitespace }), !trimmed.contains(where: LaunchCommand.isControl) else {
            return .failure(.invalid)
        }
        if let port = Int(trimmed), (1...65535).contains(port) {
            return URL(string: "http://localhost:\(port)/").map { .success($0) } ?? .failure(.invalid)
        }
        if let scheme = explicitScheme(trimmed) {
            guard scheme == "http" || scheme == "https" else { return .failure(.notWeb(scheme)) }
            guard let url = URL(string: trimmed), url.host(percentEncoded: false)?.isEmpty == false else { return .failure(.invalid) }
            return .success(url)
        }
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let host = hostName(of: hostPart)
        guard !host.isEmpty else { return .failure(.invalid) }
        let scheme = isLocal(host) ? "http" : "https"
        guard host.contains(".") || isLocal(host) || host.contains(":"),
              let url = URL(string: "\(scheme)://\(trimmed)"), url.host(percentEncoded: false)?.isEmpty == false else {
            return .failure(.invalid)
        }
        return .success(url)
    }

    /// The scheme when the text names one (`http://...`, `file:...`, `mailto:...`), lowercased. `localhost:3000`
    /// and `example.com:8080/x` have none: what follows the colon there is a port.
    static func explicitScheme(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[..<colon]
        guard let first = candidate.unicodeScalars.first, CharacterSet.letters.contains(first),
              candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return candidate.lowercased() }
        // host:port, optionally followed by a path.
        let portDigits = rest.prefix { $0.isNumber }
        if !portDigits.isEmpty, rest.dropFirst(portDigits.count).first.map({ "/?#".contains($0) }) ?? true { return nil }
        return candidate.lowercased()
    }

    /// The host of `host:port` or `[v6]:port`, without brackets or port.
    static func hostName(of hostPort: String) -> String {
        var text = hostPort
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            return String(text[text.index(after: text.startIndex)..<close])
        }
        return String(text.split(separator: ":", maxSplits: 1).first ?? "").lowercased()
    }

    /// This computer: `localhost`, names ending in `.localhost`, `127.x.x.x` and `::1`.
    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Loopback, `0.0.0.0`, `.local` and `.test` names and private network addresses: typed without a scheme, they get `http`.
    static func isLocal(_ host: String) -> Bool {
        if isLoopback(host) || host == "0.0.0.0" || host.hasSuffix(".local") || host.hasSuffix(".test") || host.hasSuffix(".internal") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

// MARK: Navigation

/// What the browser pane's web view may load in a frame.
public enum BrowserNavigationPolicy {
    /// `http` and `https` in any frame; `about:blank` and `about:srcdoc` (empty and inline frames). Everything else is
    /// refused: `file:`, `data:`, `blob:`, `javascript:` and custom schemes that would open other apps.
    public static func allows(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https": return url.host(percentEncoded: false)?.isEmpty == false
        case "about": return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
        default: return false
        }
    }

    /// The scheme for a refusal line ("file", "mailto"), or "this" when there is none.
    public static func schemeName(_ url: URL?) -> String {
        url?.scheme?.lowercased() ?? "this"
    }

    /// May the page be opened in the default browser: `http` and `https` only.
    public static func opensExternally(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url?.host(percentEncoded: false)?.isEmpty == false
    }
}

// MARK: Console

/// A line in the browser pane's console: from the page, from a dev server, or from Ensemble itself.
public struct BrowserConsoleLine: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case log, info, warn, error, debug
    }

    public enum Source: Equatable, Sendable {
        case page
        /// A dev server's output, by entry name.
        case server(String)
        /// Ensemble's own notes (a blocked address, a page that did not load).
        case browser
    }

    public let id: Int
    public var level: Level
    public var text: String
    public var source: Source
    public var date: Date

    public init(id: Int, level: Level, text: String, source: Source, date: Date = Date()) {
        self.id = id
        self.level = level
        self.text = text
        self.source = source
        self.date = date
    }

    public static let maxTextLength = 4000

    /// Reads a message from the console capture: a JSON string `{"level": "...", "text": "..."}`. Anything else is
    /// dropped; the text is cut to `maxTextLength` and cleaned of control characters.
    public static func pageMessage(_ body: Any) -> (level: Level, text: String)? {
        guard let string = body as? String, string.utf8.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any],
              let levelName = object["level"] as? String, let level = Level(rawValue: levelName),
              let text = object["text"] as? String else { return nil }
        var cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ConsoleText.strippingEscapes(String($0)) }.joined(separator: "\n")
        if cleaned.count > maxTextLength { cleaned = String(cleaned.prefix(maxTextLength)) + "\u{2026}" }
        return (level, cleaned)
    }
}

// MARK: Scripts

/// The scripts the browser pane adds to pages. Nothing here gives the page a way to reach Ensemble: the page-world
/// part only turns console calls into DOM events, and the handlers that pass them on live in Ensemble's own content
/// world, which page scripts cannot see.
public enum BrowserScripts {
    /// The content world (`WKContentWorld.world(name:)`) for the reader, the picker and their message handlers.
    public static let worldName = "EnsembleBrowser"
    public static let consoleHandler = "ensembleConsole"
    public static let pickHandler = "ensemblePick"
    /// The DOM event the page-world part sends; a new name each launch.
    public static let eventName = "ensemble-console-" + UUID().uuidString.lowercased()

    /// Page world, at document start, every frame: wraps `console.log/info/warn/error/debug`, uncaught errors, failed
    /// loads and unhandled promise rejections, and sends each as a DOM event with a JSON string. Calls through to the
    /// original console methods.
    public static var pageCapture: String {
        """
        (function () {
          var name = \(jsonString(eventName));
          var send = EventTarget.prototype.dispatchEvent.bind(window);
          var Custom = window.CustomEvent, stringify = JSON.stringify;
          function text(args) {
            var out = [];
            for (var i = 0; i < args.length; i++) {
              var a = args[i];
              try {
                if (typeof a === 'string') { out.push(a); }
                else if (a instanceof Error) { out.push(String(a) + (a.stack ? '\\n' + a.stack : '')); }
                else if (a !== null && typeof a === 'object') { out.push(stringify(a)); }
                else { out.push(String(a)); }
              } catch (e) {
                try { out.push(Object.prototype.toString.call(a)); } catch (e2) { out.push('?'); }
              }
            }
            return out.join(' ');
          }
          function post(level, args) {
            try { send(new Custom(name, { detail: stringify({ level: level, text: text(args).slice(0, 4000) }) })); } catch (e) {}
          }
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
            var original = console[level];
            if (typeof original !== 'function') { return; }
            console[level] = function () { post(level, arguments); return original.apply(this, arguments); };
          });
          window.addEventListener('error', function (e) {
            if (e instanceof ErrorEvent) {
              post('error', [e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')]);
            } else if (e.target && (e.target.src || e.target.href)) {
              post('error', ['Could not load ' + (e.target.src || e.target.href)]);
            }
          }, true);
          window.addEventListener('unhandledrejection', function (e) {
            post('error', ['Unhandled promise rejection: ' + text([e.reason])]);
          });
        })();
        """
    }

    /// Ensemble's content world, at document start, every frame: passes the page-world events to the console handler.
    public static var consoleReader: String {
        """
        (function () {
          window.addEventListener(\(jsonString(eventName)), function (e) {
            if (typeof e.detail === 'string') { window.webkit.messageHandlers.\(consoleHandler).postMessage(e.detail); }
          });
        })();
        """
    }

    public static let maxElementHTML = 20_000

    /// Ensemble's content world, main frame, run on demand: highlights the element under the pointer; a click sends
    /// `{"html": outerHTML, "summary": "button#save.primary", "truncated": bool}` to the pick handler, Escape sends "".
    /// The click itself does not reach the page.
    public static var startPicking: String {
        """
        (function () {
          if (window.__ensemblePick) { return; }
          var box = document.createElement('div');
          box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;box-sizing:border-box;' +
            'border:2px solid #D97757;background:rgba(217,119,87,0.14);border-radius:2px;display:none;';
          (document.body || document.documentElement).appendChild(box);
          var current = null;
          function place(el) {
            var r = el.getBoundingClientRect();
            box.style.display = 'block';
            box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
            box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
          }
          function summary(el) {
            var s = el.tagName.toLowerCase();
            if (el.id) { s += '#' + el.id; }
            if (typeof el.className === 'string' && el.className.trim()) { s += '.' + el.className.trim().split(/\\s+/).slice(0, 4).join('.'); }
            return s.slice(0, 200);
          }
          function block(e) { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); }
          function move(e) { if (e.target && e.target !== box && e.target.nodeType === 1) { current = e.target; place(current); } }
          function click(e) {
            block(e);
            var el = (e.target && e.target.nodeType === 1 && e.target !== box) ? e.target : current;
            if (!el) { return; }
            var html = el.outerHTML || '';
            finish(JSON.stringify({ html: html.slice(0, \(maxElementHTML)), summary: summary(el), truncated: html.length > \(maxElementHTML) }));
          }
          function key(e) { if (e.key === 'Escape') { block(e); finish(''); } }
          var events = [['mousemove', move], ['mouseover', move], ['click', click], ['mousedown', block], ['mouseup', block],
                        ['pointerdown', block], ['pointerup', block], ['keydown', key]];
          function finish(result) {
            events.forEach(function (pair) { window.removeEventListener(pair[0], pair[1], true); });
            if (box.parentNode) { box.parentNode.removeChild(box); }
            window.__ensemblePick = null;
            window.webkit.messageHandlers.\(pickHandler).postMessage(result);
          }
          events.forEach(function (pair) { window.addEventListener(pair[0], pair[1], true); });
          window.__ensemblePick = { cancel: function () { finish(''); } };
        })();
        """
    }

    /// Ensemble's content world: ends picking without a result.
    public static let cancelPicking = "if (window.__ensemblePick) { window.__ensemblePick.cancel(); }"

    /// Reads a pick result: the element's outer HTML, a short summary and whether the HTML was cut. Nil for a cancel.
    public static func pickResult(_ body: Any) -> (html: String, summary: String, truncated: Bool)? {
        guard let string = body as? String, !string.isEmpty, string.utf8.count <= 512 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any],
              let html = object["html"] as? String else { return nil }
        let summary = ConsoleText.strippingEscapes((object["summary"] as? String) ?? "element")
        return (String(html.prefix(maxElementHTML)), String(summary.prefix(200)), (object["truncated"] as? Bool) ?? false)
    }

    static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

// MARK: Device widths

/// The width the page is laid out at: a phone, a tablet, or the whole pane.
public enum BrowserDeviceWidth: String, CaseIterable, Identifiable, Sendable {
    case phone, tablet, full

    public var id: String { rawValue }

    /// CSS pixels across, or nil for the whole pane.
    public var cssWidth: CGFloat? {
        switch self {
        case .phone: 390
        case .tablet: 820
        case .full: nil
        }
    }

    public var label: String {
        switch self {
        case .phone: "Phone (390 px)"
        case .tablet: "Tablet (820 px)"
        case .full: "Full width"
        }
    }

    public var symbol: String {
        switch self {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .full: "rectangle"
        }
    }

    /// The web view's width in points and its page zoom, for `available` points of room at the app's `scale`. A
    /// device narrower than the room is drawn at its size times `scale`; a wider one fits the room and zooms the
    /// page out, so the page still lays out at the device's CSS width.
    public func layout(available: CGFloat, scale: CGFloat) -> (width: CGFloat, pageZoom: CGFloat) {
        let room = max(1, available)
        guard let css = cssWidth else { return (room, scale) }
        let width = min(room, css * scale)
        return (width, width / css)
    }
}

// MARK: Messages to the agent

/// What "Send to agent" sends. Page text goes in fenced blocks that the page cannot close.
public enum BrowserAgentMessage {
    public static let maxConsoleErrors = 50

    public static func screenshot(url: String, width: BrowserDeviceWidth) -> String {
        let at = width.cssWidth.map { " at \(width == .phone ? "phone" : "tablet") width (\(Int($0)) px)" } ?? ""
        return "Screenshot of \(url) in the browser pane\(at)."
    }

    /// The newest errors (at most `maxConsoleErrors`), oldest first, server lines tagged with the server's name.
    public static func consoleErrors(_ lines: [BrowserConsoleLine], url: String?) -> String? {
        let errors = lines.filter { $0.level == .error }.suffix(maxConsoleErrors)
        guard !errors.isEmpty else { return nil }
        let body = errors.map { line -> String in
            switch line.source {
            case .server(let name): "[\(name)] \(line.text)"
            case .browser: "[browser] \(line.text)"
            case .page: line.text
            }
        }.joined(separator: "\n")
        let place = url.map { " at \($0)" } ?? ""
        let count = errors.count == 1 ? "1 console error" : "\(errors.count) console errors"
        return "\(count) from the browser pane\(place). The text comes from the page and its dev server:\n\n" + fenced(body, language: "text")
    }

    public static func element(html: String, summary: String, truncated: Bool, url: String?) -> String {
        let place = url.map { " at \($0)" } ?? ""
        let cut = truncated ? "\n\nThe HTML was cut at \(BrowserScripts.maxElementHTML) characters." : ""
        return "Element `\(summary.replacingOccurrences(of: "`", with: ""))` picked in the browser pane\(place). The HTML comes from the page:\n\n"
            + fenced(html, language: "html") + cut
    }

    /// A fenced code block with a fence longer than any run of backticks in the text.
    public static func fenced(_ text: String, language: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + text + "\n" + fence
    }
}
