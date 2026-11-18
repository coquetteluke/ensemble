import Foundation

/// One OpenCode permission rule (`Permission.Rule`): `action` is the tool permission (`edit`, `shell`, `read`,
/// `webfetch`, `external_directory`, ...), `resource` a wildcard pattern for what it touches (a path, the
/// scanned shell command, a URL), `effect` is `allow`, `ask` or `deny`. Within a ruleset the last matching rule wins,
/// and session rules are checked after the agent's own rules, so they override them.
public struct PermissionRule: Codable, Hashable, Sendable {
    public var action: String
    public var resource: String
    public var effect: String

    public init(_ action: String, _ resource: String = "*", _ effect: String) {
        self.action = action
        self.resource = resource
        self.effect = effect
    }
}

public enum PermissionRules {
    /// Shell commands Auto mode runs without asking: read-only commands plus common build and test commands.
    /// Every other command asks. This is a convenience list, not a security boundary: build and test commands
    /// run project code.
    ///
    /// OpenCode checks each command of a compound line (`a && b`, `a | b`) on its own, against the scanned
    /// command text. `*` matches anything, and a pattern ending in ` *` also matches the bare command.
    public static let autoAllowedShell: [String] = [
        // Read-only
        "ls *", "pwd", "which *", "cat *", "head *", "tail *", "wc *", "echo *", "grep *", "rg *", "find *",
        "git status *", "git diff *", "git log *", "git show *",
        "git branch", "git branch -a", "git branch -r", "git branch -v", "git branch -vv", "git branch --list",
        "git branch --show-current",
        // Build and test
        "swift build *", "swift test *", "xcodebuild *",
        "npm test *", "npm run *", "pnpm test *", "pnpm run *", "pnpm build *", "yarn test *", "yarn run *", "yarn build *",
        "cargo build *", "cargo test *", "cargo check *", "go build *", "go test *", "go vet *",
        "pytest *", "python -m pytest *", "python3 -m pytest *",
        "make", "make all", "make build", "make test", "make check", "make lint",
    ]

    /// Forms of the allowed commands that can still change things; these ask again (checked after the allow list).
    public static let autoAskAgainShell: [String] = [
        "find * -delete*", "find * -exec*", "find * -execdir*", "find * -ok*", "find * -okdir*",
        "find * -fprint*", "find * -fls*",
        "rg *--pre*",
        "*--output*",
        "*>*",
        "*$(*", "*`*",
    ]

    /// The session ruleset for a permission mode.
    ///
    /// - Ask: edits, commands, web fetches and work outside the project folder ask. OpenCode's own default allows
    ///   every tool (only `.env` reads ask), so the ask rules are explicit.
    /// - Accept edits: file edits run, every command asks.
    /// - Auto: safe commands run, everything else asks. Edits inside the project folder run, the commands in
    ///   `autoAllowedShell` run, every other command, web fetch and anything outside the project folder asks.
    /// - Bypass: everything runs.
    public static func ruleset(for mode: PermissionMode) -> [PermissionRule] {
        switch mode {
        case .ask:
            return [
                PermissionRule("edit", "*", "ask"),
                PermissionRule("shell", "*", "ask"),
                PermissionRule("webfetch", "*", "ask"),
                PermissionRule("external_directory", "*", "ask"),
                PermissionRule("experimental_image_generate", "*", "ask"),
            ]
        case .acceptEdits:
            return [
                PermissionRule("edit", "*", "allow"),
                PermissionRule("shell", "*", "ask"),
                PermissionRule("webfetch", "*", "ask"),
                PermissionRule("external_directory", "*", "ask"),
                PermissionRule("experimental_image_generate", "*", "ask"),
            ]
        case .auto:
            var rules = [
                PermissionRule("*", "*", "allow"),
                PermissionRule("read", "*.env", "ask"),
                PermissionRule("read", "*.env.*", "ask"),
                PermissionRule("read", "*.env.example", "allow"),
                PermissionRule("edit", "*", "allow"),
                PermissionRule("shell", "*", "ask"),
            ]
            rules += autoAllowedShell.map { PermissionRule("shell", $0, "allow") }
            rules += autoAskAgainShell.map { PermissionRule("shell", $0, "ask") }
            rules += [
                PermissionRule("webfetch", "*", "ask"),
                PermissionRule("external_directory", "*", "ask"),
                PermissionRule("experimental_image_generate", "*", "ask"),
            ]
            return rules
        case .bypass:
            return [PermissionRule("*", "*", "allow")]
        }
    }

    /// Best guess of the mode a ruleset came from (for sessions created elsewhere). `nil` when it does not match.
    public static func mode(for rules: [PermissionRule]) -> PermissionMode? {
        if rules.isEmpty { return nil }
        return PermissionMode.allCases.first { ruleset(for: $0) == rules }
    }

    /// What a ruleset decides for one action and resource, using OpenCode's matching: the last matching rule wins,
    /// `*` matches any run of characters (including `/` and spaces), `?` matches one character, and for `shell`
    /// a pattern ending in ` *` also matches the bare command. With no match the engine asks.
    /// Used to preview and test rulesets; the engine makes the real decision.
    public static func effect(action: String, resource: String, rules: [PermissionRule]) -> String {
        var result = "ask"
        for rule in rules where wildcardMatch(rule.action, action) {
            if wildcardMatch(rule.resource, resource)
                || (action == "shell" && rule.resource.hasSuffix(" *") && resource == String(rule.resource.dropLast(2))) {
                result = rule.effect
            }
        }
        return result
    }

    static func wildcardMatch(_ pattern: String, _ value: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let v = Array(value.unicodeScalars)
        var pi = 0, vi = 0
        var starP = -1, starV = 0
        while vi < v.count {
            if pi < p.count, p[pi] == "?" || (p[pi] != "*" && p[pi] == v[vi]) {
                pi += 1
                vi += 1
            } else if pi < p.count, p[pi] == "*" {
                starP = pi
                starV = vi
                pi += 1
            } else if starP >= 0 {
                pi = starP + 1
                starV += 1
                vi = starV
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
