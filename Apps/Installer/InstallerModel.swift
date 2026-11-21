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

    private(set) var phase: Phase = .welcome
    private(set) var setup = EngineSetup(homebrewInstalled: true, openCodeInstalled: false)
    /// Homebrew was missing when the engine step opened, so its row stays listed (ticked once it is installed).
    private(set) var includeHomebrew = false
    private(set) var checkedWithoutLuck = false
    private(set) var copied: EngineSetup.Step.Kind?
    /// Ensemble is open from the place it is about to be replaced in.
    private(set) var appIsOpen = false

    let installer: AppInstaller
    let version: String?
    let replacingVersion: String?
    let icon: NSImage

    /// `forPictures` draws a first install, whatever is in the destination on the Mac that makes the pictures.
    init(payload: URL, destinationFolder: URL, forPictures: Bool = false) {
        installer = AppInstaller(payload: payload, destinationFolder: destinationFolder)
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
    func show(_ phase: Phase, setup: EngineSetup? = nil, includeHomebrew: Bool = false) {
        self.phase = phase
        if let setup { self.setup = setup }
        self.includeHomebrew = includeHomebrew
    }

    var title: String { version.map { "Ensemble \($0)" } ?? "Ensemble" }
    var destinationName: String { (installer.destinationFolder.path as NSString).abbreviatingWithTildeInPath }
    var steps: [EngineSetup.Step] { setup.steps(includeHomebrew: includeHomebrew) }

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
        setup = EngineSetup.detect()
        includeHomebrew = !setup.homebrewInstalled
        phase = setup.openCodeInstalled ? .done : .engine
    }

    /// Looks every three seconds while the engine step is open, and moves on by itself once OpenCode is there.
    func watchForTheEngine() async {
        while !Task.isCancelled, phase == .engine {
            try? await Task.sleep(for: .seconds(3))
            guard phase == .engine else { return }
            setup = EngineSetup.detect()
            if setup.openCodeInstalled { phase = .done }
        }
    }

    func checkAgain() {
        setup = EngineSetup.detect()
        checkedWithoutLuck = !setup.openCodeInstalled
        if setup.openCodeInstalled { phase = .done }
    }

    func setUpLater() { phase = .done }

    func copy(_ step: EngineSetup.Step) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(step.command, forType: .string)
        copied = step.kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == step.kind { copied = nil }
        }
    }

    func openTerminal() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    func openEnsemble() {
        NSWorkspace.shared.openApplication(at: installer.installedURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([installer.installedURL])
    }
}
