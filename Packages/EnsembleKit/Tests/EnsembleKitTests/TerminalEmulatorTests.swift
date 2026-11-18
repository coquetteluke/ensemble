import Foundation
import Testing
@testable import EnsembleKit

/// The terminal's escape-sequence parser and screen model, without a process: colours and styles, wide
/// characters, line endings, erasing, cursor movement, scroll regions, the alternate screen, the scrollback
/// limit, resizing, replies to programs, and the bytes keys and pastes send.
@Suite struct TerminalEmulatorTests {
    private func emulator(_ columns: Int = 20, _ rows: Int = 5, scrollback: Int = 100) -> TerminalEmulator {
        TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: scrollback)
    }

    private func row(_ terminal: TerminalEmulator, _ index: Int) -> String { terminal.screen[index].text }
    private func cell(_ terminal: TerminalEmulator, _ row: Int, _ column: Int) -> TerminalCell { terminal.screen[row].cells[column] }

    // MARK: Parser

    @Test func parserSplitsSequencesAndCharactersAcrossChunks() {
        var parser = TerminalParser()
        var actions: [TerminalAction] = []
        let bytes = Array("a\u{1B}[1;38:2::10:20:30m\u{1B}]2;Title\u{07}é\u{1B}]7;file://h/tmp\u{1B}\\b".utf8)
        // One byte at a time: nothing may depend on chunk boundaries.
        for byte in bytes { parser.feed([byte]) { actions.append($0) } }
        #expect(actions == [
            .print("a"),
            .csi(TerminalCSI(parameters: [[1], [38, 2, -1, 10, 20, 30]], final: UInt8(ascii: "m"))),
            .osc("2;Title"),
            .print("é"),
            .osc("7;file://h/tmp"),
            .print("b"),
        ])
    }

    @Test func parserReadsPrivateMarkersIntermediatesAndEmptyParameters() {
        var parser = TerminalParser()
        var actions: [TerminalAction] = []
        parser.feed(Array("\u{1B}[?1049h\u{1B}[;5H\u{1B}[2 q\u{1B}(0\u{1B}P+q\u{1B}\\x".utf8)) { actions.append($0) }
        #expect(actions == [
            .csi(TerminalCSI(parameters: [[1049]], privateMarker: UInt8(ascii: "?"), final: UInt8(ascii: "h"))),
            .csi(TerminalCSI(parameters: [[-1], [5]], final: UInt8(ascii: "H"))),
            .csi(TerminalCSI(parameters: [[2]], intermediates: [UInt8(ascii: " ")], final: UInt8(ascii: "q"))),
            .escape(intermediates: [UInt8(ascii: "(")], final: UInt8(ascii: "0")),
            .print("x"),
        ])
    }

    @Test func invalidUTF8BecomesReplacementCharacter() {
        let terminal = emulator()
        terminal.feed([0x61, 0xFF, 0x62, 0xE4, 0xB8, 0x63])
        #expect(row(terminal, 0) == "a\u{FFFD}b\u{FFFD}c")
    }

    // MARK: SGR

    @Test func sgrCombinationsSetAndClearStyles() {
        let terminal = emulator()
        terminal.feed("\u{1B}[1;3;4;31;44mA\u{1B}[22;23;24;39;49mB\u{1B}[2;7;9mC\u{1B}[0mD")
        #expect(cell(terminal, 0, 0).attributes == TerminalAttributes(foreground: .indexed(1), background: .indexed(4),
                                                                      flags: [.bold, .italic, .underline]))
        #expect(cell(terminal, 0, 1).attributes == .plain)
        #expect(cell(terminal, 0, 2).attributes.flags == [.dim, .inverse, .strikethrough])
        #expect(cell(terminal, 0, 3).attributes == .plain)
    }

    @Test func sgr256AndTrueColourInBothForms() {
        let terminal = emulator()
        terminal.feed("\u{1B}[38;5;208;48;5;17mA\u{1B}[38;2;10;20;30mB\u{1B}[38:2::1:2:3;48:5:200mC\u{1B}[38:2:4:5:6mD")
        #expect(cell(terminal, 0, 0).attributes.foreground == .indexed(208))
        #expect(cell(terminal, 0, 0).attributes.background == .indexed(17))
        #expect(cell(terminal, 0, 1).attributes.foreground == .rgb(10, 20, 30))
        #expect(cell(terminal, 0, 1).attributes.background == .indexed(17))
        #expect(cell(terminal, 0, 2).attributes.foreground == .rgb(1, 2, 3))
        #expect(cell(terminal, 0, 2).attributes.background == .indexed(200))
        #expect(cell(terminal, 0, 3).attributes.foreground == .rgb(4, 5, 6))
    }

    @Test func brightColoursResetsAndIgnoredForms() {
        let terminal = emulator()
        terminal.feed("\u{1B}[91;102mA\u{1B}[mB\u{1B}[1m\u{1B}[>4;2mC\u{1B}[4:0mD\u{1B}[4mE\u{1B}[8mF")
        #expect(cell(terminal, 0, 0).attributes == TerminalAttributes(foreground: .indexed(9), background: .indexed(10)))
        #expect(cell(terminal, 0, 1).attributes == .plain)
        // CSI > 4 ; 2 m sets a key mode, not colours.
        #expect(cell(terminal, 0, 2).attributes.flags == [.bold])
        #expect(cell(terminal, 0, 3).attributes.flags == [.bold])
        #expect(cell(terminal, 0, 4).attributes.flags == [.bold, .underline])
        #expect(cell(terminal, 0, 5).attributes.flags.contains(.hidden))
    }

    // MARK: Wide characters

    @Test func wideCharactersAndEmojiTakeTwoCells() {
        let terminal = emulator()
        terminal.feed("a中b😀c")
        let cells = terminal.screen[0].cells
        #expect(cells[0].text == "a")
        #expect(cells[1].text == "中" && cells[1].width == 2)
        #expect(cells[2].width == 0 && cells[2].text.isEmpty)
        #expect(cells[3].text == "b")
        #expect(cells[4].text == "😀" && cells[4].width == 2)
        #expect(cells[5].width == 0)
        #expect(cells[6].text == "c")
        #expect(terminal.cursorColumn == 7)
        #expect(row(terminal, 0) == "a中b😀c")
    }

    @Test func combiningMarksJoinThePreviousCell() {
        let terminal = emulator()
        terminal.feed("e\u{301}x👍\u{1F3FD}")
        #expect(cell(terminal, 0, 0).text == "e\u{301}")
        #expect(cell(terminal, 0, 1).text == "x")
        #expect(terminal.cursorColumn == 6)
    }

    @Test func wideCharacterAtTheLastColumnWraps() {
        let terminal = emulator(5, 3)
        terminal.feed("abcd中")
        #expect(row(terminal, 0) == "abcd")
        #expect(terminal.screen[0].wrapped)
        #expect(cell(terminal, 1, 0).text == "中")
        #expect(terminal.cursorRow == 1 && terminal.cursorColumn == 2)
    }

    @Test func overwritingHalfAWideCharacterBlanksTheOtherHalf() {
        let terminal = emulator()
        terminal.feed("中文\u{1B}[1;2Hx")
        // "中" lost its second half, so the whole character goes; "文" stays.
        #expect(cell(terminal, 0, 0).text == " ")
        #expect(cell(terminal, 0, 1).text == "x")
        #expect(cell(terminal, 0, 2).text == "文")
        terminal.feed("\u{1B}[1;3Hy")
        #expect(cell(terminal, 0, 2).text == "y")
        #expect(cell(terminal, 0, 3).text == " " && cell(terminal, 0, 3).width == 1)
    }

    // MARK: Line endings and basic controls

    @Test func carriageReturnLineFeedBackspaceAndTab() {
        let terminal = emulator()
        terminal.feed("abc\rX")
        #expect(row(terminal, 0) == "Xbc")
        terminal.feed("\nY")
        // LF moves down without going back to the start of the line.
        #expect(row(terminal, 1) == " Y")
        terminal.feed("\r\nabc\u{08}\u{08}Z")
        #expect(row(terminal, 2) == "aZc")
        terminal.feed("\r\na\tb")
        #expect(cell(terminal, 3, 8).text == "b")
    }

    @Test func deferredWrapAtTheRightEdge() {
        let terminal = emulator(10, 4)
        terminal.feed("0123456789")
        // The cursor waits in the last column: a carriage return stays on the same line.
        #expect(terminal.cursorRow == 0 && terminal.cursorColumn == 9)
        terminal.feed("\r\n")
        #expect(terminal.cursorRow == 1)
        terminal.feed("0123456789X")
        #expect(row(terminal, 1) == "0123456789")
        #expect(terminal.screen[1].wrapped)
        #expect(row(terminal, 2) == "X")
        // Copying joins the soft-wrapped lines.
        let start = TerminalPosition(row: terminal.firstStableRow + 1, column: 0)
        let end = TerminalPosition(row: terminal.firstStableRow + 2, column: 0)
        #expect(terminal.text(from: start, to: end) == "0123456789X")
    }

    @Test func lineFeedAtTheBottomScrollsIntoTheScrollback() {
        let terminal = emulator(10, 3)
        terminal.feed("one\r\ntwo\r\nthree\r\nfour")
        #expect(terminal.screenText == "two\nthree\nfour")
        #expect(terminal.scrollback.count == 1)
        #expect(terminal.scrollback[0].text == "one")
        #expect(terminal.documentLineCount == 4)
        #expect(terminal.documentLine(0).text == "one")
    }

    // MARK: Erasing

    @Test func eraseInLineAndDisplay() {
        let terminal = emulator(10, 3)
        terminal.feed("aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc")
        terminal.feed("\u{1B}[2;5H\u{1B}[K")
        #expect(row(terminal, 1) == "bbbb")
        terminal.feed("\u{1B}[1K")
        #expect(row(terminal, 1) == "")
        terminal.feed("\u{1B}[1;3H\u{1B}[1J")
        #expect(row(terminal, 0) == "   aaaaaaa")
        terminal.feed("\u{1B}[3;8H\u{1B}[0J")
        #expect(row(terminal, 2) == "ccccccc")
        terminal.feed("\u{1B}[2J")
        #expect(terminal.screenText == "\n\n")
    }

    @Test func erasingKeepsTheBackgroundColourAndClearsScrollback() {
        let terminal = emulator(6, 2)
        terminal.feed("1\r\n2\r\n3\r\nabcdef\u{1B}[1;3H\u{1B}[44m\u{1B}[2X")
        #expect(terminal.scrollback.count == 2)
        #expect(row(terminal, 0) == "3")
        #expect(cell(terminal, 0, 2).attributes.background == .indexed(4))
        #expect(cell(terminal, 0, 3).attributes.background == .indexed(4))
        #expect(cell(terminal, 0, 4).attributes.background == .default)
        terminal.feed("\u{1B}[3J")
        #expect(terminal.scrollback.isEmpty)
        #expect(row(terminal, 1) == "abcdef")
    }

    @Test func insertAndDeleteCharactersAndInsertMode() {
        let terminal = emulator(8, 2)
        terminal.feed("abcdef\u{1B}[1;3H\u{1B}[2@")
        #expect(row(terminal, 0) == "ab  cdef")
        terminal.feed("\u{1B}[3P")
        #expect(row(terminal, 0) == "abdef")
        terminal.feed("\u{1B}[4hXY\u{1B}[4l")
        #expect(row(terminal, 0) == "abXYdef")
    }

    // MARK: Cursor

    @Test func cursorMovementIsClampedToTheScreen() {
        let terminal = emulator(10, 5)
        terminal.feed("\u{1B}[3;4H")
        #expect(terminal.cursorRow == 2 && terminal.cursorColumn == 3)
        terminal.feed("\u{1B}[10A")
        #expect(terminal.cursorRow == 0)
        terminal.feed("\u{1B}[2B\u{1B}[100C")
        #expect(terminal.cursorRow == 2 && terminal.cursorColumn == 9)
        terminal.feed("\u{1B}[3D")
        #expect(terminal.cursorColumn == 6)
        terminal.feed("\u{1B}[2G\u{1B}[5d")
        #expect(terminal.cursorRow == 4 && terminal.cursorColumn == 1)
        terminal.feed("\u{1B}7\u{1B}[H\u{1B}8")
        #expect(terminal.cursorRow == 4 && terminal.cursorColumn == 1)
        terminal.feed("\u{1B}[s\u{1B}[1;1H\u{1B}[u")
        #expect(terminal.cursorRow == 4 && terminal.cursorColumn == 1)
    }

    @Test func scrollRegionScrollsOnlyItsLines() {
        let terminal = emulator(10, 5)
        terminal.feed("l1\r\nl2\r\nl3\r\nl4\r\nl5")
        terminal.feed("\u{1B}[2;4r")
        #expect(terminal.cursorRow == 0 && terminal.cursorColumn == 0)
        terminal.feed("\u{1B}[4;1H\nnew")
        #expect(terminal.screenText == "l1\nl3\nl4\nnew\nl5")
        // A region that does not start at the top never feeds the scrollback.
        #expect(terminal.scrollback.isEmpty)
        // Reverse index at the top of the region scrolls it down (how `less` scrolls back).
        terminal.feed("\u{1B}[2;1H\u{1B}M")
        #expect(terminal.screenText == "l1\n\nl3\nl4\nl5")
        terminal.feed("\u{1B}[3;1H\u{1B}[L")
        #expect(terminal.screenText == "l1\n\n\nl3\nl5")
        terminal.feed("\u{1B}[2;1H\u{1B}[2M")
        #expect(terminal.screenText == "l1\nl3\n\n\nl5")
    }

    // MARK: Alternate screen

    @Test func alternateScreenKeepsTheMainScreenAndCursor() {
        let terminal = emulator(10, 3)
        terminal.feed("$ less\r\nline")
        #expect(terminal.cursorRow == 1 && terminal.cursorColumn == 4)
        terminal.feed("\u{1B}[?1049h\u{1B}[?1h\u{1B}=")
        #expect(terminal.isAlternateScreen)
        #expect(terminal.applicationCursorKeys)
        #expect(terminal.screenText == "\n\n")
        terminal.feed("\u{1B}[H\u{1B}[7mtop\u{1B}[m\u{1B}[3;1Hbottom\r\nmore\r\nlines")
        // The alternate screen has no scrollback.
        #expect(terminal.scrollback.isEmpty)
        #expect(terminal.documentLineCount == 3)
        terminal.feed("\u{1B}[?1l\u{1B}>\u{1B}[?1049l")
        #expect(!terminal.isAlternateScreen)
        #expect(terminal.screenText == "$ less\nline\n")
        #expect(terminal.cursorRow == 1 && terminal.cursorColumn == 4)
        #expect(!terminal.applicationCursorKeys)
    }

    @Test func modeFlagsProgramsSet() {
        let terminal = emulator()
        terminal.feed("\u{1B}[?2004h\u{1B}[?25l\u{1B}[5 q\u{1B}[?1002h\u{1B}[?1006h")
        #expect(terminal.bracketedPaste)
        #expect(!terminal.cursorVisible)
        #expect(terminal.cursorStyle == .bar)
        #expect(terminal.mouseTracking == .drags)
        #expect(terminal.mouseSGR)
        terminal.feed("\u{1B}[?2004l\u{1B}[?25h\u{1B}[0 q\u{1B}[?1002l")
        #expect(!terminal.bracketedPaste)
        #expect(terminal.cursorVisible)
        #expect(terminal.cursorStyle == .block)
        #expect(terminal.mouseTracking == .off)
    }

    @Test func lineDrawingCharacterSet() {
        let terminal = emulator()
        terminal.feed("\u{1B}(0lqk\u{1B}(Bq")
        #expect(row(terminal, 0) == "┌─┐q")
    }

    // MARK: Scrollback and resize

    @Test func scrollbackKeepsAtMostItsLimit() {
        let terminal = emulator(20, 5, scrollback: 100)
        for number in 1...300 { terminal.feed("line \(number)\r\n") }
        #expect(terminal.scrollback.count == 100)
        #expect(terminal.scrollback.droppedCount == 196)
        #expect(terminal.scrollback[0].text == "line 197")
        #expect(terminal.scrollback[99].text == "line 296")
        // Stable rows survive old lines dropping off.
        let row = terminal.firstStableRow + 50
        #expect(terminal.line(atStableRow: row)?.text == "line 247")
        terminal.feed("more\r\n")
        #expect(terminal.line(atStableRow: row)?.text == "line 247")
    }

    @Test func defaultScrollbackIsTenThousandLines() {
        let terminal = TerminalEmulator(columns: 10, rows: 3)
        #expect(terminal.scrollback.capacity == 10_000)
        terminal.feed(String(repeating: "x\r\n", count: 10_100))
        #expect(terminal.scrollback.count == 10_000)
    }

    @Test func resizeMovesLinesBetweenScreenAndScrollback() {
        let terminal = emulator(10, 4)
        terminal.feed("a\r\nb\r\nc\r\nd")
        terminal.resize(columns: 10, rows: 2)
        #expect(terminal.screenText == "c\nd")
        #expect(terminal.scrollback.count == 2)
        #expect(terminal.cursorRow == 1)
        terminal.resize(columns: 10, rows: 4)
        #expect(terminal.screenText == "a\nb\nc\nd")
        #expect(terminal.scrollback.isEmpty)
        #expect(terminal.cursorRow == 3 && terminal.cursorColumn == 1)
        // Blank lines below the cursor go before any text does.
        terminal.feed("\u{1B}[2J\u{1B}[Hx")
        terminal.resize(columns: 10, rows: 2)
        #expect(terminal.screenText == "x\n")
        #expect(terminal.scrollback.isEmpty)
    }

    @Test func resizeCutsAndPadsColumns() {
        let terminal = emulator(10, 2)
        terminal.feed("abcd中fgh")
        terminal.resize(columns: 5, rows: 2)
        #expect(terminal.columns == 5)
        // The wide character cut in half is dropped.
        #expect(row(terminal, 0) == "abcd")
        #expect(terminal.screen[0].cells.count == 5)
        #expect(terminal.cursorColumn == 4)
        terminal.resize(columns: 12, rows: 3)
        #expect(terminal.screen.allSatisfy { $0.cells.count == 12 })
        #expect(terminal.rows == 3)
    }

    @Test func resizeOnTheAlternateScreenKeepsTheMainCursor() {
        let terminal = emulator(10, 4)
        terminal.feed("1\r\n2\r\n3\r\n4\u{1B}[?1049h\u{1B}[4;1Hx")
        terminal.resize(columns: 10, rows: 2)
        #expect(terminal.isAlternateScreen)
        #expect(terminal.cursorRow == 1)
        terminal.feed("\u{1B}[?1049l")
        #expect(terminal.screenText == "3\n4")
        #expect(terminal.cursorRow == 1 && terminal.cursorColumn == 1)
    }

    // MARK: Replies and text

    @Test func repliesToCursorAndDeviceQueries() {
        let terminal = emulator(30, 10)
        terminal.feed("\u{1B}[4;7H\u{1B}[6n\u{1B}[c\u{1B}[>c\u{1B}[5n\u{1B}[18t")
        let reply = String(decoding: terminal.takeResponses(), as: UTF8.self)
        #expect(reply == "\u{1B}[4;7R\u{1B}[?62;22c\u{1B}[>1;10;0c\u{1B}[0n\u{1B}[8;10;30t")
        #expect(terminal.takeResponses().isEmpty)
    }

    @Test func titleAndReportedFolder() {
        let terminal = emulator()
        terminal.feed("\u{1B}]0;vim notes.txt\u{07}\u{1B}]7;file://mac.local/Users/me/My%20Project\u{1B}\\")
        #expect(terminal.title == "vim notes.txt")
        #expect(terminal.reportedDirectory == "/Users/me/My Project")
    }

    @Test func wordRangeForDoubleClick() {
        let terminal = emulator(40, 2)
        terminal.feed("open ~/Ensemble/docs/PLAN.md (now)")
        let row = terminal.firstStableRow
        let word = terminal.wordRange(at: TerminalPosition(row: row, column: 10))
        #expect(terminal.text(from: word.start, to: word.end) == "~/Ensemble/docs/PLAN.md")
        let paren = terminal.wordRange(at: TerminalPosition(row: row, column: 30))
        #expect(terminal.text(from: paren.start, to: paren.end) == "now")
    }

    @Test func repeatsTheLastCharacter() {
        let terminal = emulator()
        terminal.feed("-\u{1B}[4b|")
        #expect(row(terminal, 0) == "-----|")
    }

    // MARK: Input

    @Test func cursorKeysFollowTheCursorKeyMode() {
        #expect(TerminalInput.bytes(for: .up) == Array("\u{1B}[A".utf8))
        #expect(TerminalInput.bytes(for: .up, applicationCursor: true) == Array("\u{1B}OA".utf8))
        #expect(TerminalInput.bytes(for: .home, applicationCursor: true) == Array("\u{1B}OH".utf8))
        #expect(TerminalInput.bytes(for: .right, modifiers: .shift) == Array("\u{1B}[1;2C".utf8))
        #expect(TerminalInput.bytes(for: .left, modifiers: .option) == Array("\u{1B}b".utf8))
        #expect(TerminalInput.bytes(for: .pageDown) == Array("\u{1B}[6~".utf8))
        #expect(TerminalInput.bytes(for: .forwardDelete) == Array("\u{1B}[3~".utf8))
        #expect(TerminalInput.bytes(for: .tab, modifiers: .shift) == Array("\u{1B}[Z".utf8))
        #expect(TerminalInput.bytes(for: .backspace) == [0x7F])
        #expect(TerminalInput.bytes(for: .escape) == [0x1B])
        #expect(TerminalInput.bytes(for: .function(1)) == Array("\u{1B}OP".utf8))
        #expect(TerminalInput.bytes(for: .function(12)) == Array("\u{1B}[24~".utf8))
    }

    @Test func controlKeys() {
        #expect(TerminalInput.controlByte(for: "c") == 3)
        #expect(TerminalInput.controlByte(for: "D") == 4)
        #expect(TerminalInput.controlByte(for: "[") == 0x1B)
        #expect(TerminalInput.controlByte(for: " ") == 0)
        #expect(TerminalInput.controlByte(for: "é") == nil)
    }

    @Test func pasteIsBracketedWhenTheShellAsks() {
        #expect(TerminalInput.paste("ls\nexit\n", bracketed: false) == Array("ls\rexit\r".utf8))
        let bracketed = String(decoding: TerminalInput.paste("echo hi\u{1B}[201~; rm x\r\n", bracketed: true), as: UTF8.self)
        // The ESC is dropped, so "[201~" is only text and can't end the bracket.
        #expect(bracketed == "\u{1B}[200~echo hi[201~; rm x\r\u{1B}[201~")
    }

    @Test func mouseReports() {
        #expect(TerminalInput.mouseReport(.left, pressed: true, column: 4, row: 2, sgr: true) == Array("\u{1B}[<0;5;3M".utf8))
        #expect(TerminalInput.mouseReport(.left, pressed: false, column: 4, row: 2, sgr: true) == Array("\u{1B}[<0;5;3m".utf8))
        #expect(TerminalInput.mouseReport(.scrollUp, pressed: true, column: 0, row: 0, sgr: false) == [0x1B, 0x5B, 0x4D, 96, 33, 33])
    }

    // MARK: Environment

    @Test func shellEnvironmentLeavesEnsembleSecretsOut() {
        let source = [
            "HOME": "/Users/me", "TMPDIR": "/var/folders/x/T/", "SSH_AUTH_SOCK": "/tmp/agent",
            "OPENCODE_SERVER_PASSWORD": "hunter2", "ANTHROPIC_API_KEY": "sk-test", "DYLD_INSERT_LIBRARIES": "/x.dylib",
            "PATH": "/opt/secret/bin:/usr/bin", "XPC_SERVICE_NAME": "app",
        ]
        let environment = TerminalEnvironment.make(from: source, home: "/Users/me", user: "me", shell: "/bin/zsh",
                                                   localeIdentifier: "en_GB")
        #expect(environment["OPENCODE_SERVER_PASSWORD"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(environment["XPC_SERVICE_NAME"] == nil)
        #expect(environment["PATH"] == TerminalEnvironment.defaultPath)
        #expect(environment["ENSEMBLE_TERMINAL"] == "1")
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["SHELL"] == "/bin/zsh")
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(environment["LANG"] == "en_GB.UTF-8")
        // Only one variable says Ensemble.
        #expect(environment.keys.filter { $0.uppercased().contains("ENSEMBLE") } == ["ENSEMBLE_TERMINAL"])
        let keepsLocale = TerminalEnvironment.make(from: ["LC_ALL": "fr_FR.UTF-8"], home: "/h", user: "u", shell: "/bin/sh",
                                                   localeIdentifier: "nonsense")
        #expect(keepsLocale["LANG"] == nil)
        #expect(TerminalEnvironment.utf8Locale("en_US@rg=gbzzzz") == "en_US.UTF-8")
        #expect(TerminalEnvironment.utf8Locale("zz") == "en_US.UTF-8")
    }
}
