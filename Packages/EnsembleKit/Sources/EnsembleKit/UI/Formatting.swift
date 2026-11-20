import Foundation

/// Short number, time and path formats used across the UI.
public enum Format {
    /// 463, 10k, 19.2k, 466.9k, 1M, 1.2M.
    public static func tokens(_ value: Int) -> String {
        let n = max(0, value)
        if n < 1000 { return "\(n)" }
        let thousands = (Double(n) / 100).rounded() / 10
        if thousands < 1000 { return trimmed(thousands) + "k" }
        let millions = (Double(n) / 100_000).rounded() / 10
        return trimmed(millions) + "M"
    }

    /// "40.3%" (one decimal).
    public static func percent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "0.0%" }
        let value = (Double(part) / Double(total) * 1000).rounded() / 10
        return String(format: "%.1f%%", value)
    }

    /// "47%" (whole number).
    public static func wholePercent(_ fraction: Double) -> String {
        "\(Int((max(0, fraction) * 100).rounded()))%"
    }

    /// "$0.42". Tiny non-zero amounts show as "<$0.01".
    public static func usd(_ value: Double) -> String {
        if value > 0 && value < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    /// now, 5m, 3h, 2d, 3w, 4mo, 2y.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 30): return "\(Int(seconds / (86_400 * 7)))w"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }

    /// Replaces the home folder with `~`.
    public static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Last path component ("Ensemble" for "/Users/me/Ensemble").
    public static func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Parent folder with `~` ("~" for "/Users/me/Ensemble", "~/Developer" for "/Users/me/Developer/site").
    public static func parentPath(_ path: String) -> String {
        abbreviatedPath((path as NSString).deletingLastPathComponent)
    }

    /// Shows `path` relative to `base` when it is inside it.
    public static func relativePath(_ path: String, base: String) -> String {
        guard !base.isEmpty else { return abbreviatedPath(path) }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return abbreviatedPath(path)
    }

    /// Additions and deletions in a unified diff.
    public static func diffStats(_ diff: String) -> (additions: Int, deletions: Int) {
        var add = 0, del = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { add += 1 } else if line.hasPrefix("-") { del += 1 }
        }
        return (add, del)
    }

    /// Short model name for a label beside an agent's name: the engine's own name when known (without a leading
    /// "Claude "), else a readable form of the id ("claude-opus-5-5" is "Opus 5.5", "gpt-5.5" is "GPT-5.5",
    /// "gemini-2.5-flash" is "Gemini 2.5 Flash"). Ids it does not recognise come back unchanged.
    public static func shortModelName(id: String, knownName: String? = nil) -> String {
        if let knownName, !knownName.isEmpty {
            return knownName.hasPrefix("Claude ") ? String(knownName.dropFirst(7)) : knownName
        }
        var base = id.split(separator: "/").last.map(String.init) ?? id
        var parts = base.split(separator: "-").map(String.init)
        // A trailing release date ("-20251001") says nothing a reader needs.
        if parts.count > 1, let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let first = parts.first?.lowercased() else { return id }
        func word(_ part: String) -> String { part.prefix(1).uppercased() + part.dropFirst() }
        func isNumber(_ part: String) -> Bool { !part.isEmpty && part.allSatisfy(\.isNumber) }
        switch first {
        case "claude":
            let rest = Array(parts.dropFirst())
            let numbers = rest.filter(isNumber)
            let words = rest.filter { !isNumber($0) }
            guard !words.isEmpty, !numbers.isEmpty else { return id }
            return (words.map(word) + [numbers.joined(separator: ".")]).joined(separator: " ")
        case "gpt":
            guard parts.count > 1 else { return id }
            base = "GPT-" + parts[1]
            let rest = parts.dropFirst(2).map(word)
            return ([base] + rest).joined(separator: " ")
        case "gemini":
            guard parts.count > 1 else { return id }
            return (["Gemini"] + parts.dropFirst().map(word)).joined(separator: " ")
        default:
            return id
        }
    }

    private static func trimmed(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}
