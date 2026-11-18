import Foundation

/// A `can_use_tool` control request from the CLI: the agent wants to run a tool that needs approval.
///
/// Why the control protocol and not an MCP permission tool: `--permission-prompt-tool stdio` makes the CLI send each
/// prompt as a `can_use_tool` control request on its own stdout and read the answer from its own stdin, which is what
/// the official Agent SDK does. Nothing listens on a port, no helper program is installed and no config file is
/// written, so no other local process can answer a prompt. The request also carries what an MCP tool call does not:
/// the CLI's rule suggestions, the blocked path, the reason it asks, and a `control_cancel_request` when an interrupt
/// withdraws it. An MCP prompt tool was tried first and its call timed out while the prompt waited for a person.
struct ClaudePermissionPrompt: Equatable, Sendable {
    /// The control request id; Ensemble uses it as the `PermissionRequest` id.
    var requestID: String
    /// The root session (the process that asked).
    var sessionID: String
    var toolName: String
    var input: JSONValue
    var toolUseID: String?
    /// The CLI's own "always allow" proposals (`addRules`, `addDirectories`, `setMode`, ...).
    var suggestions: [JSONValue]
    /// A path the tool would touch that the CLI does not allow on its own. It can be inside the project (a command
    /// that writes a file there in Ask mode) or outside it.
    var blockedPath: String?
    /// `decision_reason_type`: `workingDir` means the tool reaches outside the session's folders.
    var reasonType: String?
    /// The session's project folder.
    var directory: String?
    /// True when the tool reaches outside the project folder.
    var isExternal: Bool
    /// What Ensemble shows.
    var request: PermissionRequest

    init(requestID: String, sessionID: String, body: JSONValue, directory: String?, created: Date = Date()) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.directory = directory
        toolName = body["tool_name"]?.stringValue ?? "tool"
        input = body["input"] ?? .object([:])
        toolUseID = body["tool_use_id"]?.stringValue
        suggestions = body["permission_suggestions"]?.arrayValue ?? []
        blockedPath = body["blocked_path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        reasonType = body["decision_reason_type"]?.stringValue
        if reasonType == "workingDir" {
            isExternal = true
        } else if let blockedPath {
            isExternal = !ClaudePaths.isInside(blockedPath, directory: directory)
        } else {
            isExternal = false
        }
        let kind = isExternal ? "external_directory" : ClaudeFormatting.permissionKind(toolName: toolName)

        var title = ClaudeFormatting.title(name: toolName, input: input, directory: directory)
        if isExternal, let blockedPath, !ClaudeFormatting.shellToolNames.contains(toolName) { title = blockedPath }
        if title == toolName, let explicit = body["title"]?.stringValue, !explicit.isEmpty { title = explicit }

        var detail: [String] = []
        if let description = body["description"]?.stringValue, !description.isEmpty, description != title {
            detail.append(description)
        }
        if ClaudeFormatting.shellToolNames.contains(toolName), let why = input["description"]?.stringValue, !why.isEmpty,
           !detail.contains(why) {
            detail.append(why)
        }
        if let diff = ClaudeFormatting.proposedDiff(toolName: toolName, input: input, directory: directory) {
            detail.append(diff)
        }
        if let blockedPath, blockedPath != title {
            detail.append((isExternal ? "Outside the project: " : "Touches: ") + ClaudeFormatting.displayPath(blockedPath, directory: directory))
        }
        if let reason = body["decision_reason"]?.stringValue, !reason.isEmpty { detail.append(reason) }
        let rules = ClaudePermissionRules.rules(for: toolName, input: input, suggestions: suggestions, isExternal: isExternal)
        detail.append("Always allows: " + ClaudePermissionRules.describe(rules))
        request = PermissionRequest(id: requestID, sessionID: sessionID, kind: kind, title: title,
                                    detail: detail.joined(separator: "\n"), created: created)
    }

    /// The rules an "always" answer to this prompt adds.
    var alwaysRules: [ClaudePermissionRules.Rule] {
        ClaudePermissionRules.rules(for: toolName, input: input, suggestions: suggestions, isExternal: isExternal)
    }

    /// The control response that answers this prompt.
    ///
    /// "Always" is answered as a plain allow: the rule is remembered by Ensemble (`ClaudePermissionRules`), never handed
    /// to the CLI as `updatedPermissions`. Ensemble's own matcher is then the only thing that approves later calls
    /// without asking, it never writes the user's settings files, and an answer never switches the permission mode.
    func response(decision: PermissionDecision, message: String?) -> JSONValue {
        let answer: JSONValue
        switch decision {
        case .once, .always:
            answer = ["behavior": "allow", "updatedInput": input]
        case .reject:
            let text = (message?.isEmpty == false ? message : nil) ?? "The user rejected this action."
            answer = ["behavior": "deny", "message": .string(text)]
        }
        return [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": answer],
        ]
    }
}

/// "Always" answers, remembered for one session. A later prompt that matches is approved without asking.
///
/// Rule kinds:
/// - `edit` with no content: file edits inside the project folder, also after resolving symlinks, never outside it
///   and never the files `isProtected` lists (dot paths such as `.git` and `.claude`, build and hook files,
///   `CLAUDE.md` and `CLAUDE.local.md`).
/// - `Bash` with `words:*` or `words *`: one simple command whose first words are exactly these (see
///   `ClaudeShellWords`); any operator, redirection, substitution, expansion, glob or quote trick asks again, and so
///   does a command the CLI flags as reaching outside the project.
/// - `Bash` with other content: exactly that command string. A Bash rule with no content is never made or matched.
/// - `WebFetch` with `domain:host`: that host and its subdomains, for plain http(s) URLs only (`ClaudeWebHosts`).
/// - A path tool with `//abs/path/**` (the CLI's own form) or `//abs/path`: files inside that folder, or that file.
/// - Any other tool with no content: every call of that tool (an MCP tool, WebSearch, ...).
/// Content Ensemble does not understand never matches, so the user is asked.
struct ClaudePermissionRules: Codable, Hashable, Sendable {
    struct Rule: Codable, Hashable, Sendable {
        /// Tool name, or `edit` for every file-editing tool inside the project.
        var tool: String
        var content: String?
    }

    private(set) var rules: [Rule] = []

    static let editFamily = ClaudeFormatting.editToolNames
    static let pathTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// The rules an "always" answer adds for a prompt.
    static func rules(for toolName: String, input: JSONValue, suggestions: [JSONValue], isExternal: Bool) -> [Rule] {
        if editFamily.contains(toolName), !isExternal { return [Rule(tool: "edit", content: nil)] }
        var result: [Rule] = []
        for suggestion in suggestions where suggestion["type"]?.stringValue == "addRules"
            && (suggestion["behavior"]?.stringValue ?? "allow") == "allow" {
            for rule in suggestion["rules"]?.arrayValue ?? [] {
                // Only rules for the tool that asked, so one answer never grants a different tool.
                guard let tool = rule["toolName"]?.stringValue, tool == toolName else { continue }
                let content = rule["ruleContent"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                if content == nil, ClaudeFormatting.shellToolNames.contains(tool) || isExternal { continue }
                let new = Rule(tool: tool, content: content)
                if !result.contains(new) { result.append(new) }
            }
        }
        if ClaudeFormatting.shellToolNames.contains(toolName) {
            // The exact command the user approved is always included, so a compound command (which no prefix rule
            // matches) is not asked again word for word.
            if let command = input["command"]?.stringValue, !command.isEmpty {
                let exact = Rule(tool: toolName, content: command)
                if !result.contains(exact) { result.insert(exact, at: 0) }
            }
            return result
        }
        if !result.isEmpty { return result }
        if isExternal {
            // Outside the project with no suggestion: only that same file again.
            guard let path = targetPath(input), ClaudePaths.components(path) != nil else { return [] }
            return [Rule(tool: toolName, content: "/" + path)]
        }
        return [Rule(tool: toolName, content: nil)]
    }

    static func describe(_ rules: [Rule]) -> String {
        guard !rules.isEmpty else { return "nothing more (this request only)" }
        return rules.map { rule in
            if rule.tool == "edit" { return "file edits inside the project" }
            guard let content = rule.content, !content.isEmpty else { return "\(rule.tool) in this session" }
            return "\(rule.tool)(\(content))"
        }.joined(separator: ", ")
    }

    mutating func add(_ new: [Rule]) {
        for rule in new where !rules.contains(rule) { rules.append(rule) }
    }

    /// True when a remembered rule approves this prompt.
    func allows(_ prompt: ClaudePermissionPrompt) -> Bool {
        matches(toolName: prompt.toolName, input: prompt.input, directory: prompt.directory, isExternal: prompt.isExternal)
    }

    func matches(toolName: String, input: JSONValue, directory: String?, isExternal: Bool = false) -> Bool {
        rules.contains { rule in
            if rule.tool == "edit" {
                guard Self.editFamily.contains(toolName), !isExternal, let directory, let path = Self.targetPath(input) else {
                    return false
                }
                // As written: when the path is spelt inside the project, that spelling must not name a protected file.
                if let relative = ClaudePaths.relative(path, directory: directory),
                   relative.isEmpty || Self.isProtected(relative: relative, path: path) {
                    return false
                }
                // As resolved, which is what decides: the real file (the deepest existing folder plus the rest, for a
                // new file) must be inside the real project folder, and must not be a protected file either. A
                // dangling link never matches. A session opened through a linked folder still matches real paths.
                guard let realPath = WorkspaceTrust.resolvedPath(path), let realDirectory = WorkspaceTrust.resolvedPath(directory),
                      let realRelative = ClaudePaths.relative(realPath, directory: realDirectory, aliases: false),
                      !realRelative.isEmpty else { return false }
                return !Self.isProtected(relative: realRelative, path: realPath) && !Self.hasIgnorableCharacters(path)
            }
            guard rule.tool == toolName else { return false }
            guard let content = rule.content, !content.isEmpty else {
                // Never "every command"; never every call that reaches outside the project.
                return !ClaudeFormatting.shellToolNames.contains(toolName) && !isExternal
            }
            if ClaudeFormatting.shellToolNames.contains(toolName) {
                guard let command = input["command"]?.stringValue else { return false }
                if toolName == "Bash", let prefix = Self.prefix(of: content) {
                    // A prefix rule covers one simple command only, compared word by word, and never a command the
                    // CLI flagged as reaching outside the project.
                    guard !isExternal, let ruleWords = ClaudeShellWords.simpleCommandWords(prefix), !ruleWords.isEmpty,
                          let words = ClaudeShellWords.simpleCommandWords(command), words.count >= ruleWords.count else { return false }
                    return Array(words.prefix(ruleWords.count)) == ruleWords
                }
                // An exact rule is the very command the user approved.
                return command == content
            }
            if toolName == "WebFetch" {
                guard content.hasPrefix("domain:"), let url = input["url"]?.stringValue, let host = ClaudeWebHosts.host(of: url),
                      let domain = ClaudeWebHosts.domain(String(content.dropFirst(7))) else { return false }
                return host == domain || host.hasSuffix("." + domain)
            }
            if Self.pathTools.contains(toolName) {
                guard let path = Self.targetPath(input) else { return false }
                return Self.pathRule(content, matches: path)
            }
            return false
        }
    }

    /// Whether an "always" edit rule must not cover this path, so each edit asks. The same files Ensemble's Accept edits
    /// and Auto modes protect for OpenCode agents (`PermissionRules`): any path segment that starts with a dot
    /// (`.git`, `.claude`, `.mcp.json`, `.envrc`, `.github`, ...), the build and hook files in
    /// `PermissionRules.protectedFileNames` in any letter case (macOS disks usually ignore case), and names with a
    /// character HFS+ drops from file names (zero-width and direction marks), so `\u{200C}.git` is caught too.
    /// `relative` is the path's components inside the project folder, so a project that itself lives in a dot folder
    /// still works.
    static func isProtected(relative: [String], path: String) -> Bool {
        if hasIgnorableCharacters(path) { return true }
        if relative.contains(where: { $0.hasPrefix(".") }) { return true }
        guard let name = relative.last?.lowercased() else { return true }
        // The agent's own instructions, in any folder: an edit there changes what every later session is told.
        if name == "claude.md" || name == "claude.local.md" { return true }
        return protectedNamePatterns.contains { pattern in
            if pattern.hasPrefix("*") { return name.hasSuffix(pattern.dropFirst()) }
            if pattern.hasSuffix("*") { return name.hasPrefix(pattern.dropLast()) }
            return name == pattern
        }
    }

    static func hasIgnorableCharacters(_ path: String) -> Bool {
        path.unicodeScalars.contains { ignorable.contains($0.value) }
    }

    private static let ignorable: Set<UInt32> = Set(Array(0x200C...0x200F) + Array(0x202A...0x202E) + Array(0x206A...0x206F) + [0xFEFF])
    private static let protectedNamePatterns: [String] = PermissionRules.protectedFileNames.map { $0.lowercased() }

    /// The words before `:*` or ` *`, or nil for a rule that is not a prefix rule.
    static func prefix(of content: String) -> String? {
        if content.hasSuffix(":*") { return String(content.dropLast(2)) }
        if content.hasSuffix(" *") { return String(content.dropLast(2)) }
        return nil
    }

    /// The file or folder a path tool works on.
    static func targetPath(_ input: JSONValue) -> String? {
        for key in ["file_path", "notebook_path", "path"] {
            if let value = input[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    /// `//abs/dir/**` matches paths inside `/abs/dir`; `//abs/file` matches that path. Other forms (relative, `~`,
    /// patterns in the middle) never match.
    static func pathRule(_ content: String, matches path: String) -> Bool {
        guard content.hasPrefix("//") else { return false }
        var target = String(content.dropFirst())
        if target.hasSuffix("/**") {
            target = String(target.dropLast(3))
            guard !target.contains("*"), !target.isEmpty else { return false }
            return ClaudePaths.isInside(path, directory: target)
        }
        guard !target.contains("*"), let rule = ClaudePaths.components(target), let wanted = ClaudePaths.components(path) else {
            return false
        }
        return rule == wanted
    }
}

/// Lexical path checks for permission rules. A path with `..` or a relative path is never inside anything.
enum ClaudePaths {
    static func components(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        if parts.contains("..") { return nil }
        if parts.contains(where: { $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }) { return nil }
        return parts
    }

    /// True when `path` is `directory` or inside it. `/tmp`, `/var` and `/etc` also match their `/private` forms,
    /// which the CLI reports after resolving the macOS links.
    static func isInside(_ path: String, directory: String?) -> Bool {
        relative(path, directory: directory) != nil
    }

    /// The components of `path` below `directory` (empty for the folder itself), or nil when it is not inside.
    /// `aliases` also accepts the `/private` forms of `/tmp`, `/var` and `/etc` (off for paths already resolved).
    static func relative(_ path: String, directory: String?, aliases: Bool = true) -> [String]? {
        guard let directory, let wanted = components(path), let base = components(directory), !base.isEmpty else { return nil }
        for candidate in aliases ? variants(base) : [base]
            where wanted.count >= candidate.count && Array(wanted.prefix(candidate.count)) == candidate {
            return Array(wanted.dropFirst(candidate.count))
        }
        return nil
    }

    private static func variants(_ base: [String]) -> [[String]] {
        var result = [base]
        if let first = base.first, ["tmp", "var", "etc"].contains(first) { result.append(["private"] + base) }
        if base.first == "private", base.count > 1, ["tmp", "var", "etc"].contains(base[1]) { result.append(Array(base.dropFirst())) }
        return result
    }
}

/// Splits a shell command into words, but only when it is a single simple command whose words mean the same in sh,
/// bash and zsh.
///
/// Anything a shell could treat specially makes it return nil, so an "always" prefix rule never approves it and the
/// user is asked instead:
/// - control and invisible format characters (newline, carriage return, NUL, DEL, bidi marks, ...), line and
///   paragraph separators and any space other than a plain space or tab;
/// - operators and redirections (`; & | < >`), substitutions and expansions (`$`, backticks), subshells and braces
///   (`( ) { }`), globs (`* ? [ ]`, zsh `^`), `~`, `!`, `#`, backslash escapes, and these characters are refused even
///   inside quotes;
/// - quote tricks: a quote may only open at the start of a word and close at its end (`'two words'` is fine,
///   `g"it"`, `"a"b` and `--x="y z"` ask), and an unterminated quote;
/// - a word starting with `=` (zsh expands `=cmd` to a path) and a first word with `=` (an environment assignment such
///   as `PATH=/tmp git status`).
enum ClaudeShellWords {
    static let refused: Set<Character> = [";", "&", "|", "<", ">", "(", ")", "$", "`", "{", "}", "*", "?", "[", "]",
                                          "~", "!", "#", "\\", "^"]

    static func simpleCommandWords(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        /// The word was a quoted string that just closed; only a separator may follow.
        var closed = false
        for scalar in command.unicodeScalars {
            if !allowed(scalar) { return nil }
            let character = Character(scalar)
            if refused.contains(character) { return nil }
            if let open = quote {
                if character == open {
                    quote = nil
                    closed = true
                } else {
                    current.append(character)
                }
                continue
            }
            let separator = character == " " || character == "\t"
            if closed && !separator { return nil }
            switch character {
            case "'", "\"":
                if inWord { return nil }
                quote = character
                inWord = true
            case " ", "\t":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                closed = false
            default:
                if !inWord && character == "=" { return nil }
                current.append(character)
                inWord = true
            }
        }
        if quote != nil { return nil }
        if inWord { words.append(current) }
        if let first = words.first, first.contains("=") { return nil }
        return words
    }

    private static func allowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " || scalar == "\t" { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .surrogate, .privateUse, .unassigned:
            return false
        default:
            return true
        }
    }
}

/// Hosts for WebFetch domain rules. A URL that another parser could read differently never matches: the CLI's fetch
/// runs in Node, whose WHATWG parser treats `\` like `/` (so `https://example.com\@evil.com` means different hosts to
/// Foundation and to Node), so backslashes, user info, whitespace and control characters are refused outright.
enum ClaudeWebHosts {
    /// The lower-case IDNA (punycode) host of a plain `http` or `https` URL, without a trailing dot, or nil.
    static func host(of url: String) -> String? {
        guard !url.isEmpty, !url.contains("\\"), !url.unicodeScalars.contains(where: unsafe) else { return nil }
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.user == nil, components.password == nil,
              let separator = url.range(of: "://") else { return nil }
        let authority = url[separator.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        return normalised(components.encodedHost)
    }

    /// A rule's domain in the same form, or nil when it is not a plain host name.
    static func domain(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains(where: { "/\\@:?#[]%".contains($0) }), !text.unicodeScalars.contains(where: unsafe),
              let components = URLComponents(string: "https://" + text) else { return nil }
        return normalised(components.encodedHost)
    }

    private static func normalised(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty, !host.contains("%") else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.hasSuffix(".") else { return nil }
        return host
    }

    private static func unsafe(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }
}
