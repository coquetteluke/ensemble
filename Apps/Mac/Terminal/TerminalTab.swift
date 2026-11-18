import AppKit
import Synchronization
import EnsembleKit

/// One terminal tab: a login shell on a pseudo-terminal and the screen model it draws into. Output is read on a
/// background queue, collected, and fed to the screen on the main actor in slices, so a flood of output (`cat` of
/// a big file) never freezes the window; reading pauses while the screen catches up.
@MainActor @Observable
final class TerminalTab: Identifiable {
    enum Status: Equatable {
        case running
        /// The shell could not start, or ended right after starting (a broken profile, for example).
        case failed(String)
    }

    let id = UUID()
    /// A name the user gave the tab; nil shows the folder.
    var customTitle: String?
    /// The shell's current folder (followed while it runs).
    private(set) var directory: String
    /// The program in front, when it is not the shell (`top`, `npm`).
    private(set) var runningProgram: String?
    private(set) var status = Status.running
    /// Some text is selected (for Copy and Send to agent).
    private(set) var hasSelection = false

    @ObservationIgnored let emulator: TerminalEmulator
    @ObservationIgnored private var terminal: PseudoTerminal?
    @ObservationIgnored private let inbox = TerminalInbox()
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var statusRefreshScheduled = false
    /// The view showing the tab redraws through this.
    @ObservationIgnored var onScreenChange: (() -> Void)?
    /// The tab list closes the tab when its shell ends.
    @ObservationIgnored var onShellEnded: ((TerminalTab) -> Void)?
    /// Snapshots: what the screen shows, written for a given number of columns and rows instead of a running shell.
    @ObservationIgnored var snapshotScript: ((Int, Int) -> String)?

    /// The selection, in stable rows (see `TerminalEmulator.firstStableRow`).
    @ObservationIgnored private(set) var selection: ClosedRange<TerminalPosition>?
    /// The selected text on screen when the selection was made; output that changes it clears the selection.
    @ObservationIgnored private var selectionScreenText = ""

    /// Bytes read but not yet on screen above which reading pauses.
    private static let backlogLimit = 1 << 20
    /// Most bytes fed to the screen in one main-actor turn (a few milliseconds of work).
    private static let sliceSize = 64 * 1024

    init(directory: String, columns: Int = 80, rows: Int = 24) {
        self.directory = directory
        emulator = TerminalEmulator(columns: columns, rows: rows)
    }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return Format.folderName(directory)
    }

    var isRunning: Bool { terminal != nil && status == .running }

    /// A program other than the shell is running in front (asked of the terminal now, not cached).
    var isBusy: Bool { terminal?.isRunningProgram ?? false }

    /// The program in front right now, for confirmations.
    var currentProgramName: String? { terminal?.foregroundProgramName }

    // MARK: Starting and ending

    /// Starts the user's login shell in `directory`.
    func start() {
        guard terminal == nil else { return }
        let configuration = TerminalEnvironment.loginShell(in: directory, columns: emulator.columns, rows: emulator.rows)
        let inbox = inbox
        do {
            terminal = try PseudoTerminal(configuration: configuration, onOutput: { [weak self] bytes in
                guard inbox.append(bytes) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.drain() } }
            }, onExit: { [weak self] exitStatus in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.shellEnded(exitStatus) } }
            })
            directory = configuration.directory
            status = .running
            startedAt = Date()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Starts a new shell after a failed one, keeping what is on screen.
    func restart() {
        terminal?.terminate(grace: 0.5)
        terminal = nil
        emulator.feed("\r\n")
        status = .running
        start()
        onScreenChange?()
    }

    /// Hangs up the shell and whatever runs in it.
    func terminate() {
        terminal?.terminate()
        terminal = nil
    }

    /// For quitting: the terminal, so all of them can be ended together.
    var pseudoTerminal: PseudoTerminal? { terminal }

    private func shellEnded(_ exitStatus: Int32) {
        drain(everything: true)
        guard terminal != nil else { return }
        terminal = nil
        runningProgram = nil
        let code = PseudoTerminal.exitCode(fromStatus: exitStatus)
        if code != 0 && Date().timeIntervalSince(startedAt) < 3 {
            status = .failed("The shell exited with status \(code)")
            onScreenChange?()
        } else {
            onShellEnded?(self)
        }
    }

    // MARK: Output

    private func drain(everything: Bool = false) {
        repeat {
            let (bytes, backlog) = inbox.take(max: Self.sliceSize)
            if !bytes.isEmpty {
                emulator.feed(bytes)
                let replies = emulator.takeResponses()
                if !replies.isEmpty { terminal?.write(replies) }
            }
            terminal?.setReadingPaused(backlog > Self.backlogLimit)
            if backlog == 0 { break }
            if !everything {
                // More waiting: let the window draw and take keys first.
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.drain() } }
                break
            }
        } while true
        checkSelection()
        onScreenChange?()
        scheduleStatusRefresh()
    }

    // MARK: Input

    /// Sends what the user typed.
    func send(_ bytes: [UInt8]) {
        guard isRunning, !bytes.isEmpty else { return }
        terminal?.write(bytes)
        if bytes.contains(0x0D) { scheduleStatusRefresh(after: 0.4) }
    }

    /// Sends text as a paste (bracketed when the program asked for it).
    func paste(_ text: String) {
        send(TerminalInput.paste(text, bracketed: emulator.bracketedPaste))
    }

    /// Resizes the screen and tells the program.
    func resize(columns: Int, rows: Int) {
        guard columns != emulator.columns || rows != emulator.rows else { return }
        emulator.resize(columns: columns, rows: rows)
        terminal?.resize(columns: columns, rows: rows)
        clearSelection()
        onScreenChange?()
    }

    func clearScrollback() {
        emulator.clearScrollback()
        clearSelection()
        onScreenChange?()
    }

    // MARK: Selection

    func select(_ range: ClosedRange<TerminalPosition>?) {
        selection = range
        selectionScreenText = range.map(screenPartText) ?? ""
        if hasSelection != (range != nil) { hasSelection = range != nil }
        onScreenChange?()
    }

    func clearSelection() {
        guard selection != nil else { return }
        select(nil)
    }

    var selectedText: String? {
        guard let selection else { return nil }
        let text = emulator.text(from: selection.lowerBound, to: selection.upperBound)
        return text.isEmpty ? nil : text
    }

    /// Stable row of the first screen line (lines above it are scrollback and never change).
    private var firstScreenRow: Int { emulator.firstStableRow + emulator.documentLineCount - emulator.rows }

    private func screenPartText(_ range: ClosedRange<TerminalPosition>) -> String {
        let first = firstScreenRow
        guard range.upperBound.row >= first else { return "" }
        let start = range.lowerBound.row >= first ? range.lowerBound : TerminalPosition(row: first, column: 0)
        return emulator.text(from: start, to: range.upperBound)
    }

    /// Clears the selection when its text scrolled away or output changed it.
    private func checkSelection() {
        guard let selection else { return }
        if selection.lowerBound.row < emulator.firstStableRow || selection.upperBound.row >= emulator.firstStableRow + emulator.documentLineCount
            || screenPartText(selection) != selectionScreenText {
            select(nil)
        }
    }

    // MARK: Folder and program

    private func scheduleStatusRefresh(after delay: TimeInterval = 0.25) {
        guard !statusRefreshScheduled else { return }
        statusRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.statusRefreshScheduled = false
                self?.refreshStatus()
            }
        }
    }

    /// Snapshots: a program in front and a failure, without a running shell.
    func showForSnapshot(runningProgram program: String?, failure: String? = nil) {
        runningProgram = program
        if let failure { status = .failed(failure) }
    }

    private func refreshStatus() {
        guard let terminal else { return }
        if let folder = terminal.currentDirectory ?? emulator.reportedDirectory, folder != directory { directory = folder }
        let program = terminal.foregroundProgramName
        if program != runningProgram { runningProgram = program }
    }
}

/// Output waiting for the main actor, shared with the terminal's read queue.
final class TerminalInbox: Sendable {
    private struct State {
        var bytes: [UInt8] = []
        var scheduled = false
    }
    private let state = Mutex(State())

    /// Adds output. True when the caller must schedule a drain (none is pending).
    func append(_ bytes: [UInt8]) -> Bool {
        state.withLock { state in
            state.bytes.append(contentsOf: bytes)
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
    }

    /// Takes up to `max` bytes; returns them and how many are left. With nothing left, the next `append` schedules
    /// a drain again.
    func take(max: Int) -> ([UInt8], Int) {
        state.withLock { state in
            let count = min(max, state.bytes.count)
            let taken = Array(state.bytes[0..<count])
            state.bytes.removeFirst(count)
            if state.bytes.isEmpty { state.scheduled = false }
            return (taken, state.bytes.count)
        }
    }
}

/// The tabs of one session (or room), in order, with the one on view.
@MainActor @Observable
final class TerminalTabList {
    let key: String
    private(set) var tabs: [TerminalTab] = []
    var selectedID: UUID?
    /// Goes up when the last tab closes, so the pane can close too.
    private(set) var lastTabClosures = 0

    init(key: String) {
        self.key = key
    }

    var selected: TerminalTab? {
        tabs.first { $0.id == selectedID } ?? tabs.last
    }

    /// Opens a tab with a shell in `directory` and shows it.
    @discardableResult
    func newTab(directory: String, start: Bool = true) -> TerminalTab {
        let size = selected.map { ($0.emulator.columns, $0.emulator.rows) } ?? (80, 24)
        let tab = TerminalTab(directory: directory, columns: size.0, rows: size.1)
        tab.onShellEnded = { [weak self] tab in self?.remove(tab) }
        tabs.append(tab)
        selectedID = tab.id
        if start { tab.start() }
        return tab
    }

    /// Ends the tab's shell and removes it; the tab next to it is shown.
    func close(_ tab: TerminalTab) {
        tab.terminate()
        remove(tab)
    }

    private func remove(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedID == tab.id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { lastTabClosures += 1 }
    }

    func select(_ tab: TerminalTab) {
        selectedID = tab.id
    }
}

/// Every terminal tab in the app, by session (or room). Tabs live while the app runs; quitting ends their shells.
@MainActor @Observable
final class TerminalCenter {
    static let shared = TerminalCenter()

    /// Made on first use (also while a view is drawn), so not observed; each list is.
    @ObservationIgnored private(set) var lists: [String: TerminalTabList] = [:]

    func list(for key: String) -> TerminalTabList {
        if let list = lists[key] { return list }
        let list = TerminalTabList(key: key)
        lists[key] = list
        return list
    }

    var allTabs: [TerminalTab] { lists.values.flatMap(\.tabs) }

    /// Tabs with a program running in front.
    var busyTabs: [TerminalTab] { allTabs.filter(\.isBusy) }

    /// Closes a tab, asking first when a program is running in it.
    func requestClose(_ tab: TerminalTab, in list: TerminalTabList, window: NSWindow?) {
        guard tab.isBusy, let window else {
            list.close(tab)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = "\(tab.currentProgramName ?? "A program") is still running in it. Closing the tab ends it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { list.close(tab) }
        }
    }

    /// Asked before the app quits: true to go on. With programs running in terminal tabs it asks once.
    func confirmQuit() -> Bool {
        let busy = busyTabs
        guard !busy.isEmpty else { return true }
        let names = busy.map { tab in "\(tab.currentProgramName ?? "a program") in \(tab.title)" }
        let alert = NSAlert()
        alert.messageText = busy.count == 1 ? "Quit and end the program in your terminal?" : "Quit and end \(busy.count) programs in your terminal?"
        alert.informativeText = "Still running: " + names.joined(separator: ", ") + "."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Ends every shell before the app quits, killing any that ignore the hangup, so none outlive the app.
    func terminateAll() {
        let terminals = allTabs.compactMap(\.pseudoTerminal)
        guard !terminals.isEmpty else { return }
        PseudoTerminal.terminateAll(terminals, timeout: 0.5)
    }
}
