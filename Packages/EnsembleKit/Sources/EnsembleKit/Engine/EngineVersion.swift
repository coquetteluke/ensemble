import Foundation

/// A dotted version number such as `2.3.0`, parsed from text like `opencode v2.3.0` or `2.3.0-beta.1`.
public struct EngineVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var components: [Int]

    public init(components: [Int]) {
        self.components = components
    }

    /// Finds the first `N.N[.N...]` in the text. Pre-release suffixes are ignored.
    public init?(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if CharacterSet.decimalDigits.contains(scalars[index]) {
                var parts: [Int] = []
                var current = ""
                var cursor = index
                while cursor < scalars.count {
                    let scalar = scalars[cursor]
                    if CharacterSet.decimalDigits.contains(scalar) {
                        current.unicodeScalars.append(scalar)
                    } else if scalar == ".", !current.isEmpty {
                        parts.append(Int(current) ?? 0)
                        current = ""
                    } else {
                        break
                    }
                    cursor += 1
                }
                if !current.isEmpty { parts.append(Int(current) ?? 0) }
                if parts.count >= 2 {
                    self.components = parts
                    return
                }
                index = cursor
            }
            index += 1
        }
        return nil
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public static var minimum: EngineVersion { EngineVersion(EnsembleKit.minimumEngineVersion)! }
}
