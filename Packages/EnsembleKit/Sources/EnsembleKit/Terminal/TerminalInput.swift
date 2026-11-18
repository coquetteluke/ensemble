import Foundation

/// Keys that are not plain text.
public enum TerminalKey: Sendable, Equatable {
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, forwardDelete
    case backspace, tab, enter, escape
    /// F1 to F12.
    case function(Int)
}

public struct TerminalKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = TerminalKeyModifiers(rawValue: 1)
    public static let option = TerminalKeyModifiers(rawValue: 2)
    public static let control = TerminalKeyModifiers(rawValue: 4)
}

/// What a key or a paste sends to the program, the way xterm and Terminal sends it.
public enum TerminalInput {
    private static let esc: UInt8 = 0x1B

    /// Bytes for a special key. Arrows, Home and End follow the cursor key mode programs set (`ESC O A` in
    /// `less` and `vim`, `ESC [ A` at the prompt); Option-Left and Option-Right move by word (`ESC b`, `ESC f`).
    public static func bytes(for key: TerminalKey, modifiers: TerminalKeyModifiers = [], applicationCursor: Bool = false) -> [UInt8] {
        let modifierCode = 1 + (modifiers.contains(.shift) ? 1 : 0) + (modifiers.contains(.option) ? 2 : 0)
            + (modifiers.contains(.control) ? 4 : 0)
        func cursor(_ final: Unicode.Scalar) -> [UInt8] {
            if modifiers == .option, final == "D" { return [esc, UInt8(ascii: "b")] }
            if modifiers == .option, final == "C" { return [esc, UInt8(ascii: "f")] }
            if modifierCode > 1 { return Array("\u{1B}[1;\(modifierCode)".utf8) + [UInt8(ascii: final)] }
            return [esc, applicationCursor ? UInt8(ascii: "O") : UInt8(ascii: "["), UInt8(ascii: final)]
        }
        func tilde(_ number: Int) -> [UInt8] {
            modifierCode > 1 ? Array("\u{1B}[\(number);\(modifierCode)~".utf8) : Array("\u{1B}[\(number)~".utf8)
        }
        switch key {
        case .up: return cursor("A")
        case .down: return cursor("B")
        case .right: return cursor("C")
        case .left: return cursor("D")
        case .home: return cursor("H")
        case .end: return cursor("F")
        case .insert: return tilde(2)
        case .forwardDelete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .backspace:
            if modifiers.contains(.control) { return [0x08] }
            return modifiers.contains(.option) ? [esc, 0x7F] : [0x7F]
        case .tab:
            return modifiers.contains(.shift) ? Array("\u{1B}[Z".utf8) : [0x09]
        case .enter:
            return modifiers.contains(.option) ? [esc, 0x0D] : [0x0D]
        case .escape:
            return [esc]
        case .function(let number):
            switch number {
            case 1...4:
                let final = Array("PQRS".utf8)[number - 1]
                return modifierCode > 1 ? Array("\u{1B}[1;\(modifierCode)".utf8) + [final] : [esc, UInt8(ascii: "O"), final]
            case 5: return tilde(15)
            case 6: return tilde(17)
            case 7: return tilde(18)
            case 8: return tilde(19)
            case 9: return tilde(20)
            case 10: return tilde(21)
            case 11: return tilde(23)
            case 12: return tilde(24)
            default: return []
            }
        }
    }

    /// The control character for Control plus `character` (Control-C is 3, Control-[ is Esc), or nil.
    public static func controlByte(for character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return value - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return value - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"): return 0
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "7"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return nil
        }
    }

    /// Bytes for pasted text: line breaks become carriage returns (what Return sends), and when the program
    /// turned on bracketed paste the text is wrapped so the shell inserts it instead of running it. Any
    /// end-of-paste marker inside the text is removed, so pasted text can never end the bracket early.
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        var body = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if bracketed {
            body = body.replacingOccurrences(of: "\u{1B}[201~", with: "").replacingOccurrences(of: "\u{1B}[200~", with: "")
            return Array("\u{1B}[200~".utf8) + Array(body.utf8) + Array("\u{1B}[201~".utf8)
        }
        return Array(body.utf8)
    }

    public enum MouseButton: Int, Sendable {
        case left = 0, middle = 1, right = 2, release = 3, scrollUp = 64, scrollDown = 65
    }

    /// A mouse report for a program that turned on mouse tracking: SGR form when it asked for it, else the
    /// X10 form. `column` and `row` start at 0. Nil when the X10 form cannot carry the position.
    public static func mouseReport(_ button: MouseButton, pressed: Bool, column: Int, row: Int, motion: Bool = false,
                                   modifiers: TerminalKeyModifiers = [], sgr: Bool) -> [UInt8]? {
        var code = button.rawValue
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if motion { code += 32 }
        if sgr {
            if button == .release { code = (code & ~3) }
            return Array("\u{1B}[<\(code);\(column + 1);\(row + 1)\(pressed ? "M" : "m")".utf8)
        }
        if !pressed && button != .scrollUp && button != .scrollDown { code = (code & ~3) | 3 }
        guard column + 33 < 256, row + 33 < 256 else { return nil }
        return [esc, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(code + 32), UInt8(column + 33), UInt8(row + 33)]
    }
}
