import Foundation

/// One entry of `git config --show-scope -z --list`.
public struct GitConfigEntry: Hashable, Sendable {
    /// `global`, `local`, `worktree`, `command` or `unknown` (system config is never read).
    public var scope: String
    /// Canonical key: section and variable in lower case, subsection as written (`filter.LFS.clean`).
    public var key: String
    public var value: String?

    public init(scope: String, key: String, value: String?) {
        self.scope = scope
        self.key = key
        self.value = value
    }

    /// Section, subsection and variable (`credential.https://example.com.helper` has subsection
    /// `https://example.com`).
    var parts: (section: String, subsection: String?, variable: String) {
        guard let first = key.firstIndex(of: "."), let last = key.lastIndex(of: ".") else { return (key, nil, "") }
        let section = String(key[..<first])
        let variable = String(key[key.index(after: last)...])
        guard first < last else { return (section, nil, variable) }
        return (section, String(key[key.index(after: first)..<last]), variable)
    }

    /// Set by the repository (or a file it includes) rather than by the user's own global config.
    var isRepositoryScoped: Bool { scope != "global" && scope != "command" }
}

/// What keeps a repository's own settings from starting programs when Ensemble runs git in it.
///
/// A folder's `.git/config` and attribute files can name programs git starts on its own: a file system monitor,
/// clean, smudge and process filters (chosen by `.gitattributes` or `.git/info/attributes`), diff text converters
/// and external diff tools, hooks (in the hooks folder or `hook.<name>.command`), a pager, editors, password
/// prompts, credential helpers, signing programs, an SSH command and remote pack programs. `GitRunner` reads the
/// folder's config first (reading runs nothing) and passes overrides that switch every one of these off, or back
/// to the user's own global value where git needs one to work at all (SSH, signing, credentials). System config is
/// never read. Hooks run only for an explicit commit the user asked for (`GitRunner.allowsHooks`).
public enum GitSafety {
    /// Overrides passed on every run as `-c key=value`.
    public static func staticOverrides(allowHooks: Bool) -> [(key: String, value: String)] {
        var pairs: [(String, String)] = [
            ("core.quotePath", "false"),
            ("color.ui", "false"),
            ("core.fsmonitor", "false"),
            ("core.pager", "cat"),
            // Empty fails closed: a diff without --no-ext-diff stops instead of starting a program.
            ("diff.external", ""),
            ("protocol.ext.allow", "never"),
            // git:// is the only transport that uses core.gitProxy, and a repository's proxy entry would win.
            ("protocol.git.allow", "never"),
            ("gc.auto", "0"),
            ("maintenance.auto", "false"),
            ("submodule.recurse", "false"),
            ("diff.ignoreSubmodules", "all"),
            ("status.submoduleSummary", "false"),
        ]
        if !allowHooks { pairs.append(("core.hooksPath", "/dev/null")) }
        return pairs
    }

    /// Environment set on every run, after the caller's own.
    public static let environment: [String: String] = [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        // Empty stops git from asking any password program, core.askPass included.
        "GIT_ASKPASS": "",
        // Editors never open for the commands Ensemble runs; these win over core.editor and sequence.editor.
        "GIT_EDITOR": "true",
        "GIT_SEQUENCE_EDITOR": "true",
        "GIT_PAGER": "cat",
    ]

    /// Program settings a repository may not choose, with git's own default for when the user has none.
    static let replacedKeys: [(key: String, fallback: String)] = [
        ("core.sshcommand", "ssh"),
        ("gpg.program", "gpg"),
        ("gpg.openpgp.program", "gpg"),
        ("gpg.x509.program", "gpgsm"),
        ("gpg.ssh.program", "ssh-keygen"),
    ]

    /// Settings a repository may turn off but not on (turning signing on would start a signing program).
    static let offOnlyKeys = ["commit.gpgsign", "tag.gpgsign", "push.gpgsign"]

    static func isTrue(_ value: String?) -> Bool {
        guard let value else { return true }
        return ["true", "yes", "on", "1"].contains(value.lowercased())
    }

    /// Overrides for what the folder's config defines, passed as `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` (no
    /// parsing problems with subsections such as URLs).
    ///
    /// - Every filter driver (any scope): no clean, smudge or process program, and not required.
    /// - Every diff driver: no text converter or diff program.
    /// - Every config-defined hook, unless hooks are allowed: disabled.
    /// - Program keys the repository sets: the user's global value, or git's default.
    /// - Credential helpers the repository adds: the list is reset and the user's global helpers put back.
    /// - Remote pack programs the repository sets: git's own.
    public static func dynamicOverrides(_ entries: [GitConfigEntry], allowHooks: Bool) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        var filters: [String] = []
        var diffDrivers: [String] = []
        var hooks: [String] = []
        func remember(_ name: String, in list: inout [String]) { if !list.contains(name) { list.append(name) } }
        func globalValues(_ key: String) -> [String] {
            entries.filter { $0.scope == "global" && $0.key == key }.compactMap(\.value)
        }

        for entry in entries {
            let (section, subsection, variable) = entry.parts
            guard let subsection else { continue }
            switch section {
            case "filter": remember(subsection, in: &filters)
            case "diff" where variable == "textconv" || variable == "command": remember(subsection, in: &diffDrivers)
            case "hook" where !allowHooks: remember(subsection, in: &hooks)
            default: break
            }
        }
        for name in filters {
            out += [("filter.\(name).clean", ""), ("filter.\(name).smudge", ""), ("filter.\(name).process", ""),
                    ("filter.\(name).required", "false")]
        }
        for name in diffDrivers {
            out += [("diff.\(name).textconv", ""), ("diff.\(name).command", "")]
        }
        for name in hooks {
            out.append(("hook.\(name).enabled", "false"))
        }

        let repository = entries.filter(\.isRepositoryScoped)
        for (key, fallback) in replacedKeys where repository.contains(where: { $0.key == key }) {
            out.append((key, globalValues(key).last ?? fallback))
        }
        for key in offOnlyKeys where repository.contains(where: { $0.key == key && isTrue($0.value) }) {
            out.append((key, globalValues(key).last ?? "false"))
        }
        // There is no default to put back for a key command; without the user's own, signing is off for the run.
        if repository.contains(where: { $0.key == "gpg.ssh.defaultkeycommand" }) {
            if let own = globalValues("gpg.ssh.defaultkeycommand").last {
                out.append(("gpg.ssh.defaultkeycommand", own))
            } else {
                out += [("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("push.gpgsign", "false")]
            }
        }
        var helperKeys: [String] = []
        for entry in repository {
            let (section, subsection, variable) = entry.parts
            if section == "credential", variable == "helper", !helperKeys.contains(entry.key) { helperKeys.append(entry.key) }
            if section == "remote", subsection != nil, variable == "uploadpack" || variable == "receivepack" {
                out.append((entry.key, variable == "uploadpack" ? "git-upload-pack" : "git-receive-pack"))
            }
        }
        for key in helperKeys {
            out.append((key, ""))
            for helper in globalValues(key) { out.append((key, helper)) }
        }
        return out
    }

    /// Parses `git config --show-scope -z --list`: `scope\0key\nvalue\0` per entry (no `\n` for a key without a value).
    public static func parseConfigList(_ data: Data) -> [GitConfigEntry] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [GitConfigEntry] = []
        var i = 0
        while i + 1 < tokens.count {
            let scope = tokens[i]
            let body = tokens[i + 1]
            i += 2
            guard !scope.isEmpty, !body.isEmpty else { continue }
            if let newline = body.firstIndex(of: "\n") {
                entries.append(GitConfigEntry(scope: scope, key: String(body[..<newline]), value: String(body[body.index(after: newline)...])))
            } else {
                entries.append(GitConfigEntry(scope: scope, key: body, value: nil))
            }
        }
        return entries
    }

    /// The folder that holds `.git` for `directory` (the folder itself or one above it), found without running git.
    /// Paths are resolved, so a link and its target give the same answer.
    public static func repositoryFolder(containing directory: String) -> String? {
        guard var folder = WorkspaceTrust.resolvedPath(directory) else { return nil }
        while true {
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) { return folder }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, !parent.isEmpty else { return nil }
            folder = parent
        }
    }
}
