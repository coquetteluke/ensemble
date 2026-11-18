import Foundation

/// A control sequence (`ESC [ ... final`).
public struct TerminalCSI: Equatable, Sendable {
    /// Each parameter with its colon-separated sub-parameters (`38:2::255:0:0` is one parameter). An empty
    /// parameter is -1, so commands can tell "missing" from 0.
    public var parameters: [[Int]]
    /// `?`, `>`, `<` or `=` right after `ESC [`.
    public var privateMarker: UInt8?
    public var intermediates: [UInt8]
    public var final: UInt8

    public init(parameters: [[Int]] = [], privateMarker: UInt8? = nil, intermediates: [UInt8] = [], final: UInt8) {
        self.parameters = parameters
        self.privateMarker = privateMarker
        self.intermediates = intermediates
        self.final = final
    }

    /// Parameter `index`, or `fallback` when it is missing or empty (and, when `zeroIsDefault`, when it is 0).
    public func parameter(_ index: Int, default fallback: Int, zeroIsDefault: Bool = true) -> Int {
        guard index < parameters.count, let value = parameters[index].first, value >= 0 else { return fallback }
        return zeroIsDefault && value == 0 ? fallback : value
    }
}

/// What the parser found in the byte stream.
public enum TerminalAction: Equatable, Sendable {
    /// A printable character.
    case print(Unicode.Scalar)
    /// A C0 control (BEL, BS, HT, LF, VT, FF, CR, SO, SI).
    case execute(UInt8)
    case csi(TerminalCSI)
    /// `ESC intermediates final`, for example `ESC 7` or `ESC ( 0`.
    case escape(intermediates: [UInt8], final: UInt8)
    /// An operating system command (`ESC ] ... BEL` or `ESC ] ... ESC \`), without the terminator.
    case osc(String)
}

/// Splits a terminal byte stream into characters and control sequences: a VT500-style state machine with UTF-8
/// decoding. Bytes may arrive in any chunks; sequences and characters split across chunks are put back together.
/// Device control strings (DCS), SOS, PM and APC strings are read and dropped.
public struct TerminalParser: Sendable {
    private enum State: Sendable {
        case ground, escape, escapeIntermediate, csiEntry, csiParameter, csiIntermediate, csiIgnore, osc, ignoredString
    }

    /// Longest OSC string kept; longer ones are cut (a title or a folder never needs more).
    static let maxOSCLength = 8192
    private static let maxParameters = 32

    private var state = State.ground
    private var parameters: [[Int]] = []
    private var current: [Int] = []
    private var hasCurrent = false
    private var privateMarker: UInt8?
    private var intermediates: [UInt8] = []
    private var oscBytes: [UInt8] = []
    /// After ESC inside an OSC or ignored string: a backslash ends the string.
    private var stringEscape = false

    // UTF-8 decoding
    private var utf8Value: UInt32 = 0
    private var utf8Remaining = 0
    private var utf8Minimum: UInt32 = 0

    public init() {}

    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes, _ emit: (TerminalAction) -> Void) where Bytes.Element == UInt8 {
        for byte in bytes { advance(byte, emit) }
    }

    private mutating func advance(_ byte: UInt8, _ emit: (TerminalAction) -> Void) {
        // A multi-byte UTF-8 character in progress (only in ground state).
        if utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(byte & 0x3F)
                utf8Remaining -= 1
                if utf8Remaining == 0 { emitScalar(utf8Value, emit) }
                return
            }
            utf8Remaining = 0
            emit(.print("\u{FFFD}"))
            // The byte starts something new; fall through.
        }

        switch state {
        case .osc, .ignoredString:
            string(byte, emit)
            return
        default:
            break
        }

        // Controls that work in every state but strings.
        switch byte {
        case 0x18, 0x1A:
            reset()
            return
        case 0x1B:
            reset()
            state = .escape
            return
        default:
            break
        }
        if byte < 0x20 {
            emit(.execute(byte))
            return
        }
        if byte == 0x7F { return }

        switch state {
        case .ground:
            ground(byte, emit)
        case .escape:
            escape(byte, emit)
        case .escapeIntermediate:
            if byte < 0x30 {
                intermediates.append(byte)
            } else {
                emit(.escape(intermediates: intermediates, final: byte))
                reset()
            }
        case .csiEntry, .csiParameter:
            csiParameter(byte, emit)
        case .csiIntermediate:
            if byte < 0x30 {
                intermediates.append(byte)
            } else if byte >= 0x40 {
                dispatchCSI(byte, emit)
            } else {
                state = .csiIgnore
            }
        case .csiIgnore:
            if byte >= 0x40 { reset() }
        case .osc, .ignoredString:
            break
        }
    }

    private mutating func ground(_ byte: UInt8, _ emit: (TerminalAction) -> Void) {
        if byte < 0x80 {
            emit(.print(Unicode.Scalar(byte)))
            return
        }
        switch byte {
        case 0xC2...0xDF:
            utf8Value = UInt32(byte & 0x1F); utf8Remaining = 1; utf8Minimum = 0x80
        case 0xE0...0xEF:
            utf8Value = UInt32(byte & 0x0F); utf8Remaining = 2; utf8Minimum = 0x800
        case 0xF0...0xF4:
            utf8Value = UInt32(byte & 0x07); utf8Remaining = 3; utf8Minimum = 0x10000
        default:
            emit(.print("\u{FFFD}"))
        }
    }

    private mutating func emitScalar(_ value: UInt32, _ emit: (TerminalAction) -> Void) {
        guard value >= utf8Minimum, let scalar = Unicode.Scalar(value) else {
            emit(.print("\u{FFFD}"))
            return
        }
        // C1 controls written as UTF-8 are dropped.
        if value >= 0x80 && value < 0xA0 { return }
        emit(.print(scalar))
    }

    private mutating func escape(_ byte: UInt8, _ emit: (TerminalAction) -> Void) {
        switch byte {
        case UInt8(ascii: "["):
            state = .csiEntry
        case UInt8(ascii: "]"):
            state = .osc
            oscBytes.removeAll(keepingCapacity: true)
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            state = .ignoredString
        case 0x20...0x2F:
            intermediates.append(byte)
            state = .escapeIntermediate
        default:
            emit(.escape(intermediates: [], final: byte))
            reset()
        }
    }

    private mutating func csiParameter(_ byte: UInt8, _ emit: (TerminalAction) -> Void) {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let digit = Int(byte - UInt8(ascii: "0"))
            if hasCurrent, let last = current.last {
                current[current.count - 1] = last < 0 ? digit : min(last * 10 + digit, 65535)
            } else {
                current = [digit]
                hasCurrent = true
            }
            state = .csiParameter
        case UInt8(ascii: ";"):
            finishParameter()
            state = .csiParameter
        case UInt8(ascii: ":"):
            if !hasCurrent {
                current = [-1]
                hasCurrent = true
            }
            current.append(-1)
            state = .csiParameter
        case UInt8(ascii: "<"), UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "?"):
            if state == .csiEntry {
                privateMarker = byte
                state = .csiParameter
            } else {
                state = .csiIgnore
            }
        case 0x20...0x2F:
            intermediates.append(byte)
            state = .csiIntermediate
        case 0x40...0x7E:
            dispatchCSI(byte, emit)
        default:
            state = .csiIgnore
        }
    }

    private mutating func finishParameter() {
        if parameters.count < Self.maxParameters {
            parameters.append(hasCurrent ? current : [-1])
        }
        current = []
        hasCurrent = false
    }

    private mutating func dispatchCSI(_ final: UInt8, _ emit: (TerminalAction) -> Void) {
        if hasCurrent || !parameters.isEmpty { finishParameter() }
        emit(.csi(TerminalCSI(parameters: parameters, privateMarker: privateMarker, intermediates: intermediates, final: final)))
        reset()
    }

    private mutating func string(_ byte: UInt8, _ emit: (TerminalAction) -> Void) {
        if stringEscape {
            stringEscape = false
            let wasOSC = state == .osc
            if wasOSC { emit(.osc(String(decoding: oscBytes, as: UTF8.self))) }
            reset()
            if byte != UInt8(ascii: "\\") {
                // Not a string terminator: the ESC starts a new sequence.
                state = .escape
                advance(byte, emit)
            }
            return
        }
        switch byte {
        case 0x07:
            if state == .osc { emit(.osc(String(decoding: oscBytes, as: UTF8.self))) }
            reset()
        case 0x1B:
            stringEscape = true
        case 0x18, 0x1A:
            reset()
        default:
            if state == .osc, oscBytes.count < Self.maxOSCLength { oscBytes.append(byte) }
        }
    }

    private mutating func reset() {
        state = .ground
        parameters.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
        hasCurrent = false
        privateMarker = nil
        intermediates.removeAll(keepingCapacity: true)
        stringEscape = false
    }
}
