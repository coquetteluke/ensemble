import Foundation

/// Removes secrets from anything the Customizations screen shows from a config or instruction file.
///
/// - Environment variables and HTTP headers are never shown with values: callers keep the names only.
/// - URLs lose their user name and password, every query value and the fragment.
/// - `name=value`, `name: value` and `--name value` lose the value when the name looks secret (`token`, `secret`,
///   `key`, `password`, `auth`, `credential`, `cookie`, `bearer`, `session`, `private`, `signature`, in any case).
/// - `Bearer ...`, `Basic ...` and strings shaped like well-known keys (`sk-...`, `ghp_...`, `github_pat_...`,
///   `xoxb-...`, `AKIA...`, `AIza...`, `glpat-...`, JSON web tokens) or long random-looking strings are masked.
///
/// It errs towards masking: an ordinary value next to a secret-looking name is hidden too.
public enum CustomizationRedaction {
    /// What a removed value is replaced with.
    public static let mask = "•••"

    static let secretWords = ["token", "secret", "key", "password", "passwd", "pwd", "auth", "credential", "cookie",
                              "bearer", "session", "private", "signature"]

    /// True for names whose values are treated as secrets.
    public static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretWords.contains { lower.contains($0) }
    }

    // MARK: URLs

    /// The URL without credentials, query values or fragment. Text that is not a URL goes through `text`.
    public static func url(_ text: String) -> String {
        guard let schemeEnd = text.range(of: "://") else { return maskTokens(text) }
        let scheme = text[..<schemeEnd.lowerBound]
        var rest = String(text[schemeEnd.upperBound...])
        var fragment = false
        if let hash = rest.firstIndex(of: "#") {
            rest = String(rest[..<hash])
            fragment = true
        }
        var query: String?
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = String(rest[..<mark])
        }
        // Credentials sit before the last "@" of the authority (the part before the first "/").
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = String(rest[..<slash])
        var path = String(rest[slash...])
        if let at = authority.lastIndex(of: "@") {
            authority = mask + "@" + authority[authority.index(after: at)...]
        }
        path = maskTokens(path)
        var result = scheme + "://" + authority + path
        if let query {
            let pairs = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                guard let equals = pair.firstIndex(of: "=") else { return pair.isEmpty ? "" : String(pair) + "=" + mask }
                return pair[..<equals] + "=" + mask
            }
            result += "?" + pairs.joined(separator: "&")
        }
        if fragment { result += "#" + mask }
        return result
    }

    // MARK: Command lines

    /// A command and its arguments as one line, with secret values masked.
    public static func command(_ parts: [String]) -> String {
        var shown: [String] = []
        var maskNext = false
        for part in parts {
            if maskNext {
                shown.append(mask)
                maskNext = false
                continue
            }
            if part.hasPrefix("-"), let equals = part.firstIndex(of: "=") {
                let name = String(part[..<equals])
                shown.append(isSecretName(name) ? name + "=" + mask : name + "=" + text(String(part[part.index(after: equals)...])))
                continue
            }
            if part.hasPrefix("-"), part.count > 1, isSecretName(part) {
                shown.append(part)
                maskNext = true
                continue
            }
            if let equals = part.firstIndex(of: "="), equals != part.startIndex,
               part[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                let name = String(part[..<equals])
                shown.append(isSecretName(name) ? name + "=" + mask : name + "=" + text(String(part[part.index(after: equals)...])))
                continue
            }
            shown.append(text(part))
        }
        return shown.map(quoted).joined(separator: " ")
    }

    static func quoted(_ part: String) -> String {
        guard part.isEmpty || part.contains(where: { $0 == " " || $0 == "\t" }) else { return part }
        return "\"" + part + "\""
    }

    // MARK: Free text

    /// Free text (a hook's shell command, a rule's first lines) with URLs, secret-named values and key-shaped strings
    /// masked.
    public static func text(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var output = input
        output = replace(Patterns.url, in: output) { match in url(match[0]) }
        output = replace(Patterns.scheme, in: output) { match in match[1] + " " + mask }
        output = replace(Patterns.pair, in: output) { match in match[1] + match[2] + match[1] + match[3] + mask }
        output = replace(Patterns.flag, in: output) { match in match[1] + match[2] + mask }
        return maskTokens(output)
    }

    /// Masks strings shaped like keys and tokens.
    static func maskTokens(_ input: String) -> String {
        var output = input
        for pattern in Patterns.tokens {
            output = replace(pattern, in: output) { _ in mask }
        }
        return replace(Patterns.longWord, in: output) { match in
            let word = match[0]
            let letters = word.contains { $0.isLetter }, digits = word.contains { $0.isNumber }
            return letters && digits ? mask : word
        }
    }

    private enum Patterns {
        static let words = CustomizationRedaction.secretWords.joined(separator: "|")
        static let url = regex(#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s'"<>`]+"#)
        /// `Bearer abc`, `Basic abc`, `Token abc`.
        static let scheme = regex(#"(?i)\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=\-]{6,}"#)
        /// `name=value`, `name: value`, `"name": "value"` with a secret-looking name.
        static let pair = regex(#"(?i)(["']?)([A-Za-z0-9_.\-]*(?:"# + words + #")[A-Za-z0-9_.\-]*)\1(\s*[:=]\s*)(?:•••(?:\s+•••)?|"[^"]*"|'[^']*'|[^\s,;&"'}\]]+)"#)
        /// `--token value`, `-api-key value`.
        static let flag = regex(#"(?i)(\s|^)(--?[A-Za-z0-9_\-]*(?:"# + words + #")[A-Za-z0-9_\-]*\s+)(?!-)(?:"[^"]*"|'[^']*'|[^\s"']+)"#)
        static let tokens: [NSRegularExpression] = [
            regex(#"\bsk-[A-Za-z0-9_\-]{16,}"#),
            regex(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
            regex(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
            regex(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
            regex(#"\bAKIA[0-9A-Z]{16}\b"#),
            regex(#"\bAIza[0-9A-Za-z_\-]{30,}"#),
            regex(#"\bglpat-[A-Za-z0-9_\-]{20,}"#),
            regex(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*"#),
        ]
        /// 32 or more characters of letters, digits, `_` and `-`; masked when it has both letters and digits.
        static let longWord = regex(#"[A-Za-z0-9_\-]{32,}"#)

        static func regex(_ pattern: String) -> NSRegularExpression {
            // The patterns are constants; a broken one is a programming error caught by the tests.
            try! NSRegularExpression(pattern: pattern)
        }
    }

    /// Replaces every match, from the end so earlier ranges stay valid. `transform` gets the match and its groups
    /// (empty strings for groups that did not take part).
    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: ([String]) -> String) -> String {
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            guard let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: transform(groups))
        }
        return result
    }
}
