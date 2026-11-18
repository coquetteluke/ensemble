#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import EnsembleKit

/// Real programs on a real pseudo-terminal, read through the screen model: `/bin/sh` printing colours, `cd` and
/// `pwd`, job control, exiting and hanging up without leaving processes or zombies behind, and the full-screen
/// programs `less`, `top` and `vim` on the alternate screen. Local programs only, nothing leaves the Mac.
@Suite(.serialized) struct TerminalLiveTests {
    /// What the terminal's callbacks share with the test: the emulator, the exit status and the terminal itself.
    final class Shared: Sendable {
        let emulator: Mutex<TerminalEmulator>
        let exitStatus = Mutex<Int32?>(nil)
        let terminal = Mutex<PseudoTerminal?>(nil)

        init(columns: Int, rows: Int) {
            emulator = Mutex(TerminalEmulator(columns: columns, rows: rows))
        }
    }

    /// A pseudo-terminal feeding an emulator, with replies (cursor position, device attributes) written back.
    final class Session: Sendable {
        let terminal: PseudoTerminal
        private let shared: Shared
        let folder: URL

        init(executable: String, arguments: [String], environment: [String: String] = [:], columns: Int = 80, rows: Int = 24) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-terminal-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let shared = Shared(columns: columns, rows: rows)
            var base = TerminalEnvironment.make(from: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
                                                user: NSUserName(), shell: executable, localeIdentifier: "en_US")
            base.merge(environment) { $1 }
            let configuration = PseudoTerminal.Configuration(executable: executable, arguments: arguments, environment: base,
                                                             directory: folder.path, columns: columns, rows: rows)
            let pty = try PseudoTerminal(configuration: configuration, onOutput: { bytes in
                let replies = shared.emulator.withLock { emulator in
                    emulator.feed(bytes)
                    return emulator.takeResponses()
                }
                if !replies.isEmpty { shared.terminal.withLock { $0 }?.write(replies) }
            }, onExit: { status in
                shared.exitStatus.withLock { $0 = status }
            })
            shared.terminal.withLock { $0 = pty }
            terminal = pty
            self.shared = shared
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        func type(_ text: String) { terminal.write(Array(text.utf8)) }

        func read<T: Sendable>(_ body: (TerminalEmulator) -> T) -> T { shared.emulator.withLock { body($0) } }

        var screenText: String { read { $0.screenText } }

        var exitStatus: Int32? { shared.exitStatus.withLock { $0 } }

        /// Waits up to `seconds` for `condition`.
        @discardableResult
        /// Returns as soon as the condition holds; the ceiling only matters when it never does.
        func wait(_ seconds: Double = TestWait.ceilingSeconds, _ condition: (Session) -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition(self) { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition(self)
        }

        /// The process is gone and was reaped (a zombie would still answer `kill(pid, 0)`).
        var processGone: Bool {
            let pid = terminal.processID
            return kill(pid, 0) == -1 && errno == ESRCH
        }
    }

    private func shell(columns: Int = 80) throws -> Session {
        try Session(executable: "/bin/sh", arguments: ["sh"], environment: ["PS1": "$ ", "ENV": ""], columns: columns)
    }

    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func shellPrintsColoursChangesFolderAndExitsCleanly() async throws {
        // Wide enough for the temporary folder's long path on one line.
        let session = try shell(columns: 240)
        #expect(await session.wait { $0.screenText.contains("$") })
        session.type("printf '\\033[31mred\\033[0m \\033[1;32mgreen\\033[0m \\033[38;5;208mx\\033[0m\\n'\n")
        #expect(await session.wait { $0.screenText.contains("red green x") })
        let attributes = session.read { emulator -> [TerminalAttributes] in
            guard let line = (0..<emulator.rows).map({ emulator.screen[$0] }).first(where: { $0.text.hasPrefix("red green") }) else { return [] }
            return [line.cells[0].attributes, line.cells[4].attributes, line.cells[10].attributes]
        }
        #expect(attributes == [TerminalAttributes(foreground: .indexed(1)),
                               TerminalAttributes(foreground: .indexed(2), flags: .bold),
                               TerminalAttributes(foreground: .indexed(208))])

        // cd and pwd, and the folder the app reads for the tab title.
        try FileManager.default.createDirectory(at: session.folder.appendingPathComponent("sub dir"), withIntermediateDirectories: true)
        let expected = realPath(session.folder.appendingPathComponent("sub dir"))
        session.type("cd 'sub dir' && pwd -P\n")
        #expect(await session.wait { $0.screenText.contains(expected) })
        #expect(await session.wait { $0.terminal.currentDirectory == expected })

        // Nothing in front at the prompt; a program in front while it runs.
        #expect(!session.terminal.isRunningProgram)
        session.type("sleep 3\n")
        #expect(await session.wait { $0.terminal.isRunningProgram })
        #expect(session.terminal.foregroundProgramName == "sleep")
        session.type("\u{03}")
        #expect(await session.wait { !$0.terminal.isRunningProgram })

        session.type("exit 0\n")
        #expect(await session.wait { $0.exitStatus != nil })
        #expect(session.exitStatus.map(PseudoTerminal.exitCode(fromStatus:)) == 0)
        #expect(session.terminal.hasExited)
        #expect(session.processGone)
    }

    /// zsh never opens the terminal again itself, so it only gets job control if the terminal is already its
    /// controlling terminal when it starts.
    @Test func zshGetsTheTerminalAsItsControllingTerminal() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let session = try Session(executable: "/bin/zsh", arguments: ["zsh", "-f"], environment: ["PS1": "%# "])
        #expect(await session.wait { $0.screenText.contains("%") })
        #expect(session.terminal.foregroundProcessGroup == session.terminal.processID)
        session.type("tty; sleep 5\r")
        #expect(await session.wait { $0.screenText.contains("/dev/ttys") })
        #expect(await session.wait { $0.terminal.foregroundProgramName == "sleep" })
        // Control-C reaches the program in front, not the shell.
        session.type("\u{03}")
        #expect(await session.wait { !$0.terminal.isRunningProgram })
        session.type("echo SHLVL=$SHLVL\r")
        #expect(await session.wait { $0.screenText.contains("SHLVL=1") })
        session.type("exit\r")
        #expect(await session.wait { $0.processGone })
    }

    @Test func missingProgramIsAnError() {
        let configuration = PseudoTerminal.Configuration(executable: "/no/such/shell", arguments: ["shell"], environment: [:],
                                                         directory: NSTemporaryDirectory(), columns: 80, rows: 24)
        #expect(throws: PseudoTerminal.StartError.self) {
            _ = try PseudoTerminal(configuration: configuration, onOutput: { _ in }, onExit: { _ in })
        }
    }

    @Test func environmentHasNoEnsembleSecrets() async throws {
        let session = try shell()
        #expect(await session.wait { $0.screenText.contains("$") })
        session.type("env | sort | grep -c . ; echo T=$TERM E=$ENSEMBLE_TERMINAL P=${OPENCODE_SERVER_PASSWORD:-none}\n")
        #expect(await session.wait { $0.screenText.contains("T=xterm-256color E=1 P=none") })
        session.type("exit\n")
        #expect(await session.wait { $0.processGone })
    }

    @Test func closingATabHangsUpTheProgramInFront() async throws {
        let session = try shell()
        #expect(await session.wait { $0.screenText.contains("$") })
        session.type("sleep 100\n")
        #expect(await session.wait { $0.terminal.isRunningProgram })
        let sleeper = session.terminal.foregroundProcessGroup ?? 0
        session.terminal.terminate(grace: 2)
        #expect(await session.wait { $0.exitStatus != nil })
        #expect(await session.wait { $0.processGone })
        #expect(await session.wait(3) { _ in kill(sleeper, 0) == -1 })
    }

    @Test func quittingEndsEveryShellEvenOneIgnoringHangups() async throws {
        let polite = try shell()
        let stubborn = try shell()
        #expect(await polite.wait { $0.screenText.contains("$") })
        #expect(await stubborn.wait { $0.screenText.contains("$") })
        stubborn.type("trap '' HUP; echo ready\n")
        #expect(await stubborn.wait { $0.screenText.contains("ready") })
        let started = Date()
        PseudoTerminal.terminateAll([polite.terminal, stubborn.terminal], timeout: 0.3)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(polite.processGone)
        #expect(stubborn.processGone)
    }

    // MARK: Full-screen programs

    private func waitForPrompt(_ session: Session) async -> Bool {
        await session.wait { $0.screenText.contains("$") }
    }

    @Test func lessUsesTheAlternateScreenAndRestoresTheShell() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/less") else { return }
        let session = try shell()
        #expect(await waitForPrompt(session))
        let lines = (1...200).map { "row \($0)" }.joined(separator: "\n")
        try lines.write(to: session.folder.appendingPathComponent("rows.txt"), atomically: true, encoding: .utf8)
        session.type("echo before; less rows.txt\n")
        #expect(await session.wait { $0.read { $0.isAlternateScreen && $0.screenText.contains("row 23") } })
        #expect(session.read { $0.applicationCursorKeys })
        // Page down, then back up a line with the arrow key in application mode.
        session.type(" ")
        #expect(await session.wait { $0.read { $0.screenText.contains("row 46") && !$0.screenText.contains("row 10\n") } })
        session.terminal.write(TerminalInput.bytes(for: .up, applicationCursor: true))
        #expect(await session.wait { $0.read { $0.screen[0].text == "row 23" } })
        session.type("q")
        #expect(await session.wait { $0.read { !$0.isAlternateScreen } })
        #expect(await session.wait { $0.screenText.contains("before") })
        session.type("exit\n")
        #expect(await session.wait { $0.processGone })
    }

    @Test func topDrawsOnTheAlternateScreen() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/top") else { return }
        let session = try shell()
        #expect(await waitForPrompt(session))
        session.type("top -s 1 -n 10\n")
        #expect(await session.wait(15) { $0.read { $0.isAlternateScreen && $0.screenText.contains("PID") && $0.screenText.contains("COMMAND") } })
        // top is set-user-ID root, so its name comes from its path.
        #expect(session.terminal.foregroundProgramName == "top")
        let header = session.read { emulator in emulator.screen.first { $0.text.contains("PID") }?.text ?? "" }
        #expect(header.contains("%CPU"))
        session.type("q")
        #expect(await session.wait { $0.read { !$0.isAlternateScreen } })
        session.type("exit\n")
        #expect(await session.wait { $0.processGone })
    }

    @Test func vimEditsAFileOnTheAlternateScreen() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/vim") else { return }
        let session = try shell()
        #expect(await waitForPrompt(session))
        try "first line\nsecond line\n".write(to: session.folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        // A short key-code timeout so Esc followed by a command is not read as an escape sequence.
        session.type("vim -u NONE -i NONE -N --cmd 'set ttimeout ttimeoutlen=10' notes.txt\n")
        #expect(await session.wait { $0.read { $0.isAlternateScreen && $0.screen[0].text == "first line" } })
        // Insert on the second line, a line above it, and a change in the middle of the first.
        session.type("jIstart ")
        #expect(await session.wait { $0.read { $0.screen[1].text == "start second line" } })
        session.type("\u{1B}")
        try await Task.sleep(for: .milliseconds(150))
        session.type("Onew")
        #expect(await session.wait { $0.read { $0.screen[1].text == "new" } })
        session.type("\u{1B}")
        try await Task.sleep(for: .milliseconds(150))
        session.type("ggwcwFIRST")
        #expect(await session.wait { $0.read { $0.screen[0].text == "first FIRST" } })
        session.type("\u{1B}")
        try await Task.sleep(for: .milliseconds(150))
        #expect(session.read { $0.screen[2].text } == "start second line")
        session.type(":wq\r")
        #expect(await session.wait { $0.read { !$0.isAlternateScreen } })
        let saved = try String(contentsOf: session.folder.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(saved == "first FIRST\nnew\nstart second line\n")
        session.type("exit\n")
        #expect(await session.wait { $0.processGone })
    }
}
#endif
