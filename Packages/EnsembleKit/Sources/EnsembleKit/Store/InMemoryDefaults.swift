import Foundation

/// A `UserDefaults` that keeps its values in memory and never writes a file. For tests, snapshot renders and SwiftUI
/// previews that hand settings to code taking a `UserDefaults`.
///
/// Use this instead of a suite with a new name per run. Such a suite leaves a `.plist` in `~/Library/Preferences` for
/// good: `removePersistentDomain(forName:)` empties the file but does not delete it.
///
/// Every typed reader and writer (`bool(forKey:)`, `set(_: Int, forKey:)`, `stringArray(forKey:)` and the rest) goes
/// through the three methods overridden here. Two differences from a real suite: values from other domains (the global
/// domain, registered defaults) are not visible, and changes are not announced, so `@AppStorage` does not follow them.
public final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    /// The domain the superclass is opened on. Nothing is read from it or written to it.
    static let unusedDomain = "ensemble.in-memory-defaults"

    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {
        super.init(suiteName: Self.unusedDomain)!
    }

    public override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            // The real class refuses anything a property list cannot hold, so the stand-in does too.
            precondition(PropertyListSerialization.propertyList(value, isValidFor: .binary),
                         "InMemoryDefaults: the value for \(defaultName) is not a property list value")
        }
        lock.withLock { values[defaultName] = value }
    }

    public override func removeObject(forKey defaultName: String) {
        lock.withLock { values[defaultName] = nil }
    }

    /// Only the values set on this object.
    public override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { values }
    }
}
