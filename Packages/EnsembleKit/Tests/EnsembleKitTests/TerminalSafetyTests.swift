import Foundation
import Testing
@testable import EnsembleKit

/// Pasted text can't escape a bracketed paste or send escape sequences, and combining marks can't grow one cell
/// without bound.
@Suite struct TerminalSafetyTests {
    @Test func nestedEndOfPasteMarkersCannotEndTheBracketEarly() {
        // Removing only the inner marker once would leave a working ESC[201~ behind.
        let nasty = "safe\u{1B}[20\u{1B}[201~1~\rrm -rf ~\r"
        let bytes = TerminalInput.paste(nasty, bracketed: true)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("\u{1B}[200~") && text.hasSuffix("\u{1B}[201~"))
        let inside = text.dropFirst("\u{1B}[200~".count).dropLast("\u{1B}[201~".count)
        #expect(!inside.contains("\u{1B}"), "no ESC survives inside the bracket")
        #expect(bytes.filter { $0 == 0x1B }.count == 2, "only the two bracket markers")
    }

    @Test func controlCharactersAreDroppedFromPastes() {
        let text = "a\u{07}b\u{1B}]0;title\u{07}c\u{7F}d\u{9B}31me\tf\ng"
        let plain = String(decoding: TerminalInput.paste(text, bracketed: false), as: UTF8.self)
        #expect(plain == "ab]0;titlec" + "d" + "31me\tf\rg")
    }

    @Test func combiningMarksAreCappedPerCell() {
        let terminal = TerminalEmulator(columns: 10, rows: 2, scrollbackLimit: 10)
        terminal.feed("e" + String(repeating: "\u{0301}", count: 5_000))
        let cell = terminal.screen[0].cells[0]
        #expect(cell.text.unicodeScalars.count <= TerminalEmulator.maxScalarsPerCell)
        #expect(cell.text.unicodeScalars.first == "e")
        // The next character still lands in the next cell.
        terminal.feed("x")
        #expect(terminal.screen[0].cells[1].text == "x")
    }
}
