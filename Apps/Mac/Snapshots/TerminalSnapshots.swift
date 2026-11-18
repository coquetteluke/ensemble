import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of the terminal pane, each in dark and light at the requested zoom:
/// - the window with the pane open on a shell (coloured `ls`, `git status`, a test run) and a second tab running a
///   dev server;
/// - the pane alone with `top` on the alternate screen, with no tabs, and with a shell that failed to start.
/// The screens come from scripts of real escape sequences, laid out for the size the pane gives them, so no shell
/// runs. With `ENSEMBLE_TERMINAL_CHECK=1`, also runs the user's login shell, `top` and `vim` in a real terminal
/// view in a window that is never shown, types into it, and saves what it drew (`checkLive`).
/// Called from `SnapshotRenderer.run`.
@MainActor
enum TerminalSnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        _ = NSApplication.shared
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        let home = NSHomeDirectory()
        let list = TerminalCenter.shared.list(for: PreviewData.mainSessionID)
        let shell = list.newTab(directory: home + "/Ensemble", start: false)
        shell.snapshotScript = Self.shellScript
        let server = list.newTab(directory: home + "/Developer/portfolio-site", start: false)
        server.snapshotScript = Self.devServerScript
        server.showForSnapshot(runningProgram: "node")
        list.select(shell)

        let window = WindowState()
        window.showSidebar = true
        window.showContextPanel = true
        window.openSidePane(.terminal)
        var written: [String] = []

        func save<V: View>(_ name: String, width baseWidth: CGFloat, height baseHeight: CGFloat, scheme: ColorScheme,
                           @ViewBuilder _ view: () -> V) {
            // Whole windows keep their size and zoom their content; single views grow with the zoom.
            let isWindow = baseWidth == 1440
            let width = isWindow ? baseWidth : baseWidth * zoom
            let height = isWindow ? baseHeight : baseHeight * zoom
            let content = view()
                .frame(width: width, height: height, alignment: .topLeading)
                .ensembleTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
                .environment(\.zoom, zoom)
                .environment(SnapshotRenderer.power)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            guard let image = renderer.cgImage else {
                print("Failed to render \(name)")
                return
            }
            if let path = write(image, to: directory.appendingPathComponent(name + suffix + ".png")) { written.append(path) }
        }

        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            save("main-window-terminal-\(tone)", width: 1440, height: 900, scheme: scheme) {
                MainView(store: store, window: window, remoteControlOverride: true, zoomOverride: zoom)
            }
        }

        // `top` in a third tab, the pane on its own.
        let top = list.newTab(directory: home + "/Ensemble", start: false)
        top.snapshotScript = Self.topScript
        top.showForSnapshot(runningProgram: "top")
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            save("terminal-top-\(tone)", width: TerminalPane.width, height: 640, scheme: scheme) {
                TerminalPane(store: store, route: .session, onClose: {}, topInset: 0)
            }
        }

        // A shell whose profile made it exit straight away.
        let failed = list.newTab(directory: home + "/Ensemble", start: false)
        failed.snapshotScript = { _, _ in "zsh: /Users/me/.zprofile: line 4: syntax error near unexpected token `fi'\r\n" }
        failed.showForSnapshot(runningProgram: nil, failure: "The shell exited with status 1")
        save("terminal-failed-dark", width: TerminalPane.width, height: 300, scheme: .dark) {
            TerminalPane(store: store, route: .session, onClose: {}, topInset: 0)
        }

        // A session with no tabs yet.
        store.select("ses_sse_reconnect")
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            save("terminal-empty-\(tone)", width: TerminalPane.width, height: 360, scheme: scheme) {
                TerminalPane(store: store, route: .session, onClose: {}, topInset: 0)
            }
        }

        written += checkQuote()
        written += checkLive(to: directory, suffix: suffix, zoom: zoom)
        return written
    }

    // MARK: Scripts

    private static func prompt(_ folder: String) -> String {
        "\u{1B}[1;36m\(folder)\u{1B}[0m \u{1B}[90m%\u{1B}[0m "
    }

    /// `ls -G` (directories blue, as macOS colours them), `git status`, and a test run.
    static func shellScript(columns: Int, rows: Int) -> String {
        let entries: [(String, Bool)] = [
            ("Apps", true), ("CLAUDE.md", false), ("Config", true), ("LICENSE", false), ("Packages", true),
            ("README.md", false), ("docs", true), ("project.yml", false), ("scripts", true), ("tools", true),
        ]
        var text = prompt("~/Ensemble") + "ls -G\r\n"
        text += lsColumns(entries, columns: columns)
        text += prompt("~/Ensemble") + "git status --short\r\n"
        text += " \u{1B}[31mM\u{1B}[m Apps/Mac/Main/MainView.swift\r\n"
        text += " \u{1B}[31mM\u{1B}[m Apps/Mac/WindowState.swift\r\n"
        text += "\u{1B}[31m??\u{1B}[m Apps/Mac/Terminal/\r\n"
        text += prompt("~/Ensemble") + "swift test --filter Terminal\r\n"
        text += "\u{1B}[1mBuilding for debugging...\u{1B}[0m\r\n"
        text += "[52/52] Linking EnsembleKitPackageTests\r\n"
        text += "Build complete! (14.50s)\r\n"
        text += "\u{1B}[32m\u{2714}\u{1B}[0m Suite TerminalEmulatorTests passed after 0.03 seconds.\r\n"
        text += "\u{1B}[32m\u{2714}\u{1B}[0m Suite TerminalLiveTests passed after 1.89 seconds.\r\n"
        text += "\u{1B}[32m\u{2714}\u{1B}[0m Test run with \u{1B}[1m42 tests\u{1B}[0m in 2 suites passed after 1.89 seconds.\r\n"
        text += prompt("~/Ensemble")
        return text
    }

    /// Names in columns, down then across, as `ls` lays them out.
    private static func lsColumns(_ entries: [(String, Bool)], columns: Int) -> String {
        let longest = entries.map(\.0.count).max() ?? 1
        let width = (longest + 8) & ~7
        let perRow = max(1, columns / width)
        let rowCount = (entries.count + perRow - 1) / perRow
        var text = ""
        for row in 0..<rowCount {
            var line = ""
            for column in 0..<perRow {
                let index = column * rowCount + row
                guard index < entries.count else { continue }
                let (name, isFolder) = entries[index]
                let padding = String(repeating: " ", count: width - name.count)
                line += (isFolder ? "\u{1B}[34m\(name)\u{1B}[39;49m" : name) + (index + rowCount < entries.count ? padding : "")
            }
            text += line + "\r\n"
        }
        return text
    }

    static func devServerScript(columns: Int, rows: Int) -> String {
        var text = prompt("~/Developer/portfolio-site") + "npm run dev\r\n\r\n"
        text += "> portfolio-site@0.4.0 dev\r\n> vite\r\n\r\n\r\n"
        text += "  \u{1B}[1;32mVITE\u{1B}[0m \u{1B}[32mv7.1.2\u{1B}[0m  \u{1B}[2mready in\u{1B}[0m \u{1B}[1m412\u{1B}[0m ms\r\n\r\n"
        text += "  \u{1B}[32m\u{279C}\u{1B}[0m  \u{1B}[1mLocal\u{1B}[0m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[0m\r\n"
        text += "  \u{1B}[32m\u{279C}\u{1B}[0m  \u{1B}[2mNetwork: use \u{1B}[22m\u{1B}[1m--host\u{1B}[22m\u{1B}[2m to expose\u{1B}[0m\r\n"
        return text
    }

    /// A `top` screen on the alternate screen, cut to the width as `top` does.
    static func topScript(columns: Int, rows: Int) -> String {
        let header = [
            "Processes: 618 total, 4 running, 614 sleeping, 3108 threads                     14:32:07",
            "Load Avg: 2.11, 2.38, 2.52  CPU usage: 6.12% user, 4.80% sys, 89.6% idle",
            "SharedLibs: 612M resident, 98M data, 64M linkedit.",
            "MemRegions: 284519 total, 7012M resident, 312M private, 2380M shared.",
            "PhysMem: 23G used (2911M wired, 1203M compressor), 812M unused.",
            "VM: 287T vsize, 4983M framework vsize, 0(0) swapins, 0(0) swapouts.",
            "Networks: packets: 48211940/52G in, 21837261/9G out.",
            "Disks: 18823410/312G read, 9310021/221G written.",
            "",
            "PID    COMMAND          %CPU TIME     #TH    #WQ  #PORT MEM    PURG   CMPRS  PGRP  PPID  STATE",
        ]
        let processes = [
            "41822  Ensemble         12.4 00:41.27 14     5    412   218M   0B     0B     41822 1     sleeping",
            "612    WindowServer     8.3  41:02.11 23     6    3410  412M   2048K  61M    612   1     sleeping",
            "0      kernel_task      4.2  02:11:07 530/12 0    0     13M    0B     0B     0     0     running",
            "41950  top              2.1  00:00.31 1/1    0    27    5264K  0B     0B     41950 41901 running",
            "1043   opencode         1.9  03:12.40 22     1    96    188M   0B     12M    1043  1     sleeping",
            "52110  node             1.2  00:12.03 11     0    40    96M    0B     0B     52110 52098 sleeping",
            "388    mds_stores       0.6  05:23.18 7      4    101   61M    0B     22M    388   1     sleeping",
            "1207   swift-frontend   0.4  00:03.55 3      0    13    312M   0B     0B     1207  1201  sleeping",
            "94     logd             0.3  08:41.02 5      2    1340  21M    0B     4512K  94    1     sleeping",
            "41901  zsh              0.0  00:00.08 1      0    21    1376K  0B     0B     41901 41822 sleeping",
            "310    coreaudiod       0.0  02:10.44 9      2    612   14M    0B     3104K  310   1     sleeping",
            "1      launchd          0.0  01:58.31 4      3    3021  27M    0B     6128K  1     0     sleeping",
            "52098  npm              0.0  00:00.92 9      0    28    44M    0B     0B     52098 52011 sleeping",
            "201    mDNSResponder    0.0  00:31.70 4      2    118   7392K  0B     1024K  201   1     sleeping",
            "455    cfprefsd         0.0  00:14.22 3      2    402   5120K  0B     832K   455   1     sleeping",
            "62     UserEventAgent   0.0  00:09.13 3      1    280   6880K  0B     1520K  62    1     sleeping",
            "741    Finder           0.0  01:02.56 8      2    690   88M    0B     19M    741   1     sleeping",
            "88     fseventsd        0.0  00:44.09 11     1    190   9200K  0B     2048K  88    1     sleeping",
            "533    sharingd         0.0  00:05.71 5      2    233   12M    0B     2304K  533   1     sleeping",
            "120    configd          0.0  00:19.84 7      4    402   8512K  0B     1736K  120   1     sleeping",
        ]
        var text = "\u{1B}[?1049h\u{1B}[?1h\u{1B}=\u{1B}[H\u{1B}[2J"
        for (index, line) in (header + processes).prefix(rows).enumerated() {
            text += "\u{1B}[\(index + 1);1H" + String(line.prefix(columns))
        }
        // top leaves the cursor after the last line it drew.
        let lines = min(header.count + processes.count, rows)
        let last = (header + processes)[lines - 1]
        text += "\u{1B}[\(lines);\(min(last.count, columns - 1) + 1)H"
        return text
    }

    // MARK: Checks

    /// "Send to agent" quotes output in a fence the output cannot close.
    private static func checkQuote() -> [String] {
        let plain = TerminalQuote.message("$ ls\nApps docs\n", folder: NSHomeDirectory() + "/Ensemble")
        let fenced = TerminalQuote.message("```swift\nlet x = 1\n```", folder: "/tmp")
        let ok = plain == "Output from my terminal in ~/Ensemble:\n\n```\n$ ls\nApps docs\n```"
            && fenced.hasPrefix("Output from my terminal in /tmp:\n\n````\n```swift") && fenced.hasSuffix("```\n````")
        print("Terminal quote check: \(ok ? "ok" : "FAILED")")
        return []
    }

    /// The real terminal view with the user's login shell in a throwaway folder, in a window that is never shown:
    /// types `ls -G`, a colour test, `top` and `vim` as key events, saves each screen, and checks every shell ends.
    private static func checkLive(to directory: URL, suffix: String, zoom: CGFloat) -> [String] {
        guard ProcessInfo.processInfo.environment["ENSEMBLE_TERMINAL_CHECK"] == "1" else { return [] }
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("ensemble-terminal-check-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: folder) }
        try? fileManager.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try? "one\ntwo\n".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho hi\n".write(to: folder.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("run.sh").path)

        let tab = TerminalTab(directory: folder.path)
        var tabsRequested = 0
        let surface = TerminalSurface(tab: tab, palette: TerminalPalette(theme: .dark), fontSize: 12 * zoom, focusToken: 1,
                                      actions: TerminalViewActions(newTab: { tabsRequested += 1 }))
        let hosting = NSHostingView(rootView: surface.frame(width: 620 * zoom, height: 520 * zoom))
        let frame = NSRect(x: 0, y: 0, width: 620 * zoom, height: 520 * zoom)
        let offscreen = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.appearance = NSAppearance(named: .darkAqua)
        offscreen.contentView = hosting
        hosting.frame = frame
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { spin(0.05) }
            return condition()
        }
        tab.start()
        spin(0.5)
        func findCanvas(_ view: NSView) -> TerminalCanvas? {
            if let canvas = view as? TerminalCanvas { return canvas }
            for child in view.subviews { if let found = findCanvas(child) { return found } }
            return nil
        }
        guard let canvas = findCanvas(hosting), let pty = tab.pseudoTerminal else {
            print("Terminal live check: FAILED (no terminal view or shell)")
            offscreen.close()
            tab.terminate()
            return []
        }
        func key(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                               windowNumber: offscreen.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            // Command keys go through the window, the way the app delivers key equivalents.
            if modifiers.contains(.command) { _ = offscreen.performKeyEquivalent(with: event) } else { canvas.keyDown(with: event) }
        }
        func type(_ text: String) { for character in text { key(String(character)) } }
        func enter() { key("\r", code: 36) }
        var written: [String] = []
        func capture(_ name: String) {
            hosting.layoutSubtreeIfNeeded()
            spin(0.2)
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let url = directory.appendingPathComponent(name + suffix + ".png")
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil { written.append(url.path) }
        }
        let emulator = tab.emulator
        let prompted = wait(10) { !emulator.screenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Let the profile finish and the prompt settle.
        spin(1.0)
        let sized = emulator.columns == TerminalMetrics(size: 12 * zoom).grid(for: canvas.enclosingScrollView?.contentView.bounds.size ?? .zero).columns
        type("clear; ls -G; printf '\\033[1;31mbold red\\033[0m \\033[3;4;38;2;120;200;255mitalic true colour\\033[0m \\033[7minverse\\033[0m wide: 中文 😀\\n'")
        enter()
        let listed = wait(5) { emulator.screenText.contains("notes.txt") && emulator.screenText.contains("italic true colour") }
        capture("terminal-live-shell")

        type("top -s 1 -n 12")
        enter()
        let topShown = wait(8) { emulator.isAlternateScreen && emulator.screenText.contains("COMMAND") }
        spin(1.2)
        let topBusy = tab.isBusy && pty.foregroundProgramName == "top"
        capture("terminal-live-top")
        type("q")
        let topLeft = wait(5) { !emulator.isAlternateScreen }

        type("vim -u NONE -i NONE -N --cmd 'set ttimeout ttimeoutlen=10' notes.txt")
        enter()
        let vimShown = wait(8) { emulator.isAlternateScreen && emulator.screen.first?.text == "one" }
        type("Gofrom the terminal pane")
        spin(0.3)
        key("\u{1B}", code: 53)
        spin(0.3)
        capture("terminal-live-vim")
        type(":wq")
        enter()
        let vimLeft = wait(5) { !emulator.isAlternateScreen }
        let saved = (try? String(contentsOf: folder.appendingPathComponent("notes.txt"), encoding: .utf8)) == "one\ntwo\nfrom the terminal pane\n"

        key("t", modifiers: .command)
        let commandT = tabsRequested == 1

        tab.terminate()
        let ended = wait(5) { pty.hasExited }
        offscreen.close()
        let results = [("prompt", prompted), ("sized to the view", sized), ("ls and colours", listed), ("top on the alternate screen", topShown),
                       ("top shown as running", topBusy), ("back from top", topLeft), ("vim on the alternate screen", vimShown),
                       ("back from vim", vimLeft), ("vim saved", saved), ("Command-T", commandT), ("shell ended", ended)]
        let failed = results.filter { !$0.1 }.map(\.0)
        print("Terminal live check: " + (failed.isEmpty ? "ok (\(results.map(\.0).joined(separator: ", ")))" : "FAILED: " + failed.joined(separator: ", ")))
        return written
    }

    private static func write(_ image: CGImage, to url: URL) -> String? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }
}
