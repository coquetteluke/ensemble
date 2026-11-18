import Foundation

/// Parsers for the output of `pmset`, `sudo -l` and `ioreg`. Pure, so they are unit tested.
public enum PowerParsing {
    /// `SleepDisabled` from `pmset -g`. The line uses tabs (`" SleepDisabled\t\t1"`), so it is matched
    /// with a whitespace pattern. Returns nil when the line is missing.
    public static func sleepDisabled(fromPMSet output: String) -> Bool? {
        let pattern = /(?im)^\s*SleepDisabled\s+(\d+)/
        guard let match = output.firstMatch(of: pattern) else { return nil }
        return match.1 != "0"
    }

    /// True if `pmset -g ps` says the Mac draws from the battery.
    public static func onBattery(fromPMSetPS output: String) -> Bool {
        output.range(of: "'Battery Power'", options: .caseInsensitive) != nil
    }

    /// True if `ioreg -r -k AppleClamshellState` found an entry.
    public static func hasLid(fromIoreg output: String) -> Bool {
        output.contains("AppleClamshellState")
    }

    /// True if sudo's message says it wanted a password (`sudo -n` without a matching NOPASSWD rule).
    public static func sudoWantedPassword(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("password is required") || text.contains("a terminal is required")
            || text.contains("no tty present")
    }

    /// True if the output of `sudo -n -l` contains a rule that lets this user run both
    /// `pmset disablesleep 1` and `pmset disablesleep 0` as root without a password.
    public static func sudoListingAllowsPMSet(_ listing: String) -> Bool {
        guard let header = listing.range(of: "may run the following commands") else { return false }
        let body = listing[header.upperBound...]
        // Each entry starts on a line beginning with "(runas)"; longer entries wrap onto indented lines.
        var entries: [String] = []
        // The first piece is the rest of the header line (" on <host>:"), which starts no entry.
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("(") {
                entries.append(line)
            } else if !entries.isEmpty {
                entries[entries.count - 1] += " " + line
            }
        }
        return entries.contains(where: entryAllowsPMSet)
    }

    private static func entryAllowsPMSet(_ entry: String) -> Bool {
        guard let close = entry.firstIndex(of: ")") else { return false }
        let runAs = entry[entry.index(after: entry.startIndex)..<close]
        let runAsUser = runAs.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let users = runAsUser.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard users.contains("ALL") || users.contains("root") else { return false }

        var noPassword = false
        var coversOn = false
        var coversOff = false
        let commands = entry[entry.index(after: close)...].split(separator: ",")
        for rawCommand in commands {
            var command = rawCommand.trimmingCharacters(in: .whitespaces)
            // Tags such as "NOPASSWD:" or "SETENV:" apply to this command and the ones after it.
            while let match = command.firstMatch(of: /^([A-Z_]+):\s*/) {
                let tag = String(match.1)
                if tag == "NOPASSWD" { noPassword = true }
                if tag == "PASSWD" { noPassword = false }
                command = String(command[match.range.upperBound...])
            }
            guard noPassword else { continue }
            let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
            if words == ["ALL"] || words == ["/usr/bin/pmset"] || words == ["/usr/bin/pmset", "*"]
                || words == ["/usr/bin/pmset", "disablesleep", "*"] {
                coversOn = true
                coversOff = true
            } else if words == ["/usr/bin/pmset", "disablesleep", "1"] {
                coversOn = true
            } else if words == ["/usr/bin/pmset", "disablesleep", "0"] {
                coversOff = true
            }
        }
        return coversOn && coversOff
    }
}

/// The one-time setup that lets Ensemble run `sudo -n /usr/bin/pmset disablesleep 0|1`.
public enum PowerSudoers {
    /// Where the rule is installed.
    public static let rulePath = "/private/etc/sudoers.d/ensemble-pmset"
    /// The path as people usually write it.
    public static let displayPath = "/etc/sudoers.d/ensemble-pmset"

    /// macOS short user names: letters, digits, dot, underscore, hyphen.
    public static func isValidUserName(_ user: String) -> Bool {
        !user.isEmpty && user.count <= 255 && user.wholeMatch(of: /[A-Za-z0-9._][A-Za-z0-9._-]*/) != nil
    }

    /// The sudoers line: exactly `pmset disablesleep 1` and `pmset disablesleep 0`, only as root, no
    /// password. No wildcard, so no other pmset arguments can ride along.
    public static func ruleLine(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    }

    /// Shell script run as root. It writes the rule to a temporary file next to the target (sudo skips
    /// files with a dot in their name, so a half-written file is never read), checks it with
    /// `visudo -cf`, sets owner root:wheel and mode 0440, moves it into place, then checks the whole
    /// sudo configuration and removes the rule again if that check fails.
    public static func installScript(user: String) -> String? {
        guard isValidUserName(user) else { return nil }
        let folder = (rulePath as NSString).deletingLastPathComponent
        return """
        set -e
        umask 077
        /bin/mkdir -p '\(folder)'
        tmp=$(/usr/bin/mktemp '\(folder)/.ensemble-pmset.XXXXXX')
        trap '/bin/rm -f "$tmp"' EXIT
        /usr/bin/printf '%s\\n' '\(ruleLine(user: user))' > "$tmp"
        /usr/sbin/visudo -cf "$tmp"
        /usr/sbin/chown root:wheel "$tmp"
        /bin/chmod 0440 "$tmp"
        /bin/mv -f "$tmp" '\(rulePath)'
        /usr/sbin/visudo -c > /dev/null || { /bin/rm -f '\(rulePath)'; exit 1; }
        """
    }

    /// Escapes text for an AppleScript string literal.
    public static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// AppleScript for `osascript -e`. macOS shows its own administrator password dialog, so Ensemble
    /// never sees the password.
    public static func appleScript(user: String) -> String? {
        guard let script = installScript(user: user) else { return nil }
        let prompt = "Ensemble wants to add a sudo rule that lets it turn lid lock on and off."
        return "do shell script \(appleScriptQuoted(script)) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"
    }
}
