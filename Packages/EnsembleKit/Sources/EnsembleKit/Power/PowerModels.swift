import Foundation

/// How much a session or room asks the Mac to stay up. Ordered, so the effective level is the max over holders.
public enum PowerLevel: Int, Codable, Comparable, Sendable, CaseIterable {
    /// Normal sleep behaviour.
    case off = 0
    /// No idle system sleep and no idle display sleep (like `caffeinate -d`).
    case awake = 1
    /// Awake, and `pmset disablesleep 1` so closing the lid does not sleep the Mac.
    case lidLock = 2

    public static func < (lhs: PowerLevel, rhs: PowerLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .awake: "Awake"
        case .lidLock: "Lid lock"
        }
    }

    public var keepAwake: Bool { self >= .awake }
    public var lidLock: Bool { self == .lidLock }

    /// The "Keep Mac awake" switch. Turning it off also turns lid lock off.
    public func settingKeepAwake(_ on: Bool) -> PowerLevel {
        on ? max(self, .awake) : .off
    }

    /// The "Keep running with the lid closed" switch. Turning it on also turns Keep awake on;
    /// turning it off leaves Keep awake on.
    public func settingLidLock(_ on: Bool) -> PowerLevel {
        on ? .lidLock : (self == .lidLock ? .awake : self)
    }
}

/// Who asks for power: a session (engine session id) or a room.
public struct PowerHolderID: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case session
        case room
    }

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func session(_ id: String) -> PowerHolderID { PowerHolderID(kind: .session, id: id) }
    public static func room(_ id: UUID) -> PowerHolderID { PowerHolderID(kind: .room, id: id.uuidString) }

    /// Stable string form used for saving, `session:<id>` or `room:<uuid>`.
    public var key: String { "\(kind.rawValue):\(id)" }

    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(key[..<colon])) else { return nil }
        let id = String(key[key.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        self.init(kind: kind, id: id)
    }

    public var description: String { key }

    /// "session" or "room", for UI text.
    public var noun: String { kind.rawValue }
}

/// Where the current lid lock comes from.
public enum LidLockSource: Equatable, Sendable {
    /// Ensemble is not relying on a lid lock.
    case off
    /// Ensemble ran `pmset disablesleep 1` and will set it back to 0 when nothing needs it.
    case owned
    /// SleepDisabled was already 1 when Ensemble needed it (the `lidlock` tool or anything else).
    /// Ensemble relies on it and never sets it back to 0.
    case external
}

/// Why lid lock is not in effect although a holder asked for it.
public enum LidLockProblem: Equatable, Sendable {
    /// `sudo -n` has no rule for `pmset disablesleep`; the one-time setup installs one.
    case needsSetup
    case failed(String)

    public var message: String {
        switch self {
        case .needsSetup: "Lid lock needs a one-time setup."
        case .failed(let text): text
        }
    }
}

/// Whether `sudo -n /usr/bin/pmset disablesleep` works without a password.
public enum SudoRuleStatus: Equatable, Sendable {
    case unknown
    case ready
    case missing
}

/// Result of running `sudo -n /usr/bin/pmset disablesleep 0|1`.
public enum PowerCommandResult: Equatable, Sendable {
    case ok
    /// sudo asked for a password: no NOPASSWD rule.
    case needsSetup
    case failed(String)
}

/// Result of the one-time sudoers setup.
public enum PowerSetupResult: Equatable, Sendable {
    case installed
    case cancelled
    case failed(String)
}
