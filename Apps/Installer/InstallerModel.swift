import AppKit
import Observation

/// What the installer window shows and does: install the app that ships inside it, help with the engine, open the app.
@MainActor
@Observable
final class InstallerModel {
    enum Phase: Equatable {
        case welcome
        case installing(AppInstaller.Stage)
        case engine
        case done
        case failed(String)
    }

    /// The engine download, which only starts when the person presses Install the engine.
    enum EngineInstall: Equatable {
        case idle
        case working(EngineInstaller.Stage)
        case failed(String)
    }

    private(set) var phase: Phase = .welcome
    private(set) var setup = EngineSetup(homebrewInstalled: true, openCodeInstalled: false)
    private(set) var engineInstall: EngineInstall = .idle
    private(set) var checkedWithoutLuck = false
    private(set) var copied = false
    /// Ensemble is open from the place it is about to be replaced in.
    private(set) var appIsOpen = false

    let installer: AppInstaller
    let engineInstaller: EngineInstaller
    let version: String?
    let replacingVersion: String?
    let icon: NSImage

    /// `forPictures` draws a first install, whatever is in the destination on the Mac that makes the pictures.
    init(payload: URL, destinationFolder: URL, engineInstaller: EngineInstaller = EngineInstaller(), forPictures: Bool = false) {
        installer = AppInstaller(payload: payload, destinationFolder: destinationFolder)
        self.engineInstaller = engineInstaller
        version = AppInstaller.version(of: payload)
        replacingVersion = forPictures ? nil : AppInstaller.version(of: installer.installedURL)
        let systemIcon = FileManager.default.fileExists(atPath: payload.path)
            ? NSWorkspace.shared.icon(forFile: payload.path)
            : (NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon = Self.flattened(systemIcon, side: 256)
        appIsOpen = forPictures ? false : !runningCopies().isEmpty
    }

    /// The icon as a plain sRGB bitmap. The system's icon image carries a wide colour range, and drawing it as it
    /// comes makes `ImageRenderer` tone down the whole picture.
    private static func flattened(_ image: NSImage, side: Int) -> NSImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let flat = context.makeImage() else { return image }
        return NSImage(cgImage: flat, size: NSSize(width: side, height: side))
    }

    /// For pictures of each screen.
    func show(_ phase: Phase, setup: EngineSetup? = nil, engineInstall: EngineInstall = .idle) {
        self.phase = phase
        if let setup { self.setup = setup }
        self.engineInstall = engineInstall
    }

    var title: String { version.map { "Ensemble \($0)" } ?? "Ensemble" }
    var destinationName: String { (installer.destinationFolder.path as NSString).abbreviatingWithTildeInPath }
    var engineFolderName: String { (engineInstaller.destinationFolder.path as NSString).abbreviatingWithTildeInPath }
    var isInstallingEngine: Bool { if case .working = engineInstall { true } else { false } }

    /// Where OpenCode is looked for: the usual places, plus the folder this installer puts it in.
    private func detectSetup() -> EngineSetup {
        EngineSetup.detect(engineSearchPaths: EngineSetup.engineSearchPaths() + [engineInstaller.destinationFolder.path])
    }

    private func runningCopies() -> [NSRunningApplication] {
        let target = installer.installedURL.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == target }
    }

    func install() {
        guard phase == .welcome || isFailed else { return }
        phase = .installing(.copying)
        let installer = installer
        Task {
            // Replacing an app that is open would leave the old one running, so it is asked to quit first.
            for app in runningCopies() { app.terminate() }
            for _ in 0..<40 where !runningCopies().isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard runningCopies().isEmpty else {
                appIsOpen = true
                phase = .failed("Ensemble is still open. Quit it, then try again.")
                return
            }
            appIsOpen = false
            let result: Result<URL, Error> = await Task.detached {
                Result { try installer.install(progress: { stage in Task { @MainActor in self.advance(to: stage) } }) }
            }.value
            // Long enough to read what happened; the copy itself takes well under a second.
            try? await Task.sleep(for: .milliseconds(700))
            switch result {
            case .success: beginEngineStep()
            case .failure(let error): phase = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func advance(to stage: AppInstaller.Stage) {
        if case .installing = phase { phase = .installing(stage) }
    }

    private func beginEngineStep() {
        setup = detectSetup()
        phase = setup.openCodeInstalled ? .done : .engine
    }

    /// Downloads OpenCode from its own releases, checks it and installs it. Only ever started by the person (the
    /// Install the engine button) or by `--unattended`.
    func installEngine() {
        guard phase == .engine, !isInstallingEngine else { return }
        engineInstall = .working(.finding)
        checkedWithoutLuck = false
        let engineInstaller = engineInstaller
        Task {
            do {
                try await engineInstaller.install { stage in
                    Task { @MainActor in
                        if case .working = self.engineInstall { self.engineInstall = .working(stage) }
                    }
                }
                engineInstall = .idle
                setup = detectSetup()
                setup.openCodeInstalled = true
                phase = .done
            } catch {
                engineInstall = .failed(error.localizedDescription)
            }
        }
    }

    /// Looks every three seconds while the engine step is open, and moves on by itself if OpenCode arrives some
    /// other way (Homebrew, for example).
    func watchForTheEngine() async {
        while !Task.isCancelled, phase == .engine {
            try? await Task.sleep(for: .seconds(3))
            guard phase == .engine, !isInstallingEngine else { continue }
            setup = detectSetup()
            if setup.openCodeInstalled { phase = .done }
        }
    }

    func checkAgain() {
        setup = detectSetup()
        checkedWithoutLuck = !setup.openCodeInstalled
        if setup.openCodeInstalled { phase = .done }
    }

    func setUpLater() {
        guard !isInstallingEngine else { return }
        phase = .done
    }

    func copyHomebrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EngineSetup.openCodeCommand, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    func openEnsemble() {
        NSWorkspace.shared.openApplication(at: installer.installedURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// For `--unattended`: opens Ensemble and reports whether it started.
    func openEnsembleAndWait() async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: installer.installedURL, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                continuation.resume(returning: app != nil)
            }
        }
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([installer.installedURL])
    }
}
