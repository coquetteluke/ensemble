import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// "Install Ensemble": a small app that ships on the disk image with Ensemble.app inside it.
///
/// Without a window: `--unattended` installs the app and the engine with no click, prints what it did and quits
/// (add `--open` to open Ensemble at the end, `--skip-engine` to leave the engine alone). It is what
/// `scripts/install-ensemble.sh` runs, and what an AI assistant uses to install Ensemble for someone.
///
/// For testing: `--payload <Ensemble.app>` uses another copy of the app, `--destination <folder>` installs somewhere
/// other than Applications, `--engine-destination <folder>` and `--engine-releases <url>` point the engine download
/// elsewhere, and `--render <folder>` writes a picture of every screen and quits.
@main
struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerDelegate.self) private var delegate
    @State private var model: InstallerModel

    init() {
        if let folder = Self.value(after: "--render") {
            let sample = InstallerModel(payload: Self.payload, destinationFolder: Self.destination, forPictures: true)
            InstallerPictures.render(model: sample, to: URL(fileURLWithPath: folder, isDirectory: true))
            exit(0)
        }
        let model = InstallerModel(payload: Self.payload, destinationFolder: Self.destination, engineInstaller: Self.engineInstaller)
        _model = State(initialValue: model)
        // No window, no Dock icon: the work runs here and the app never starts its interface.
        if CommandLine.arguments.contains("--unattended") { Unattended.run(model) }
    }

    var body: some Scene {
        Window("Install Ensemble", id: "installer") {
            InstallerView(model: model)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // An installer always opens on its window: macOS must not remember that the window was closed last time.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands { CommandGroup(replacing: .newItem) {} }
    }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return (arguments[index + 1] as NSString).expandingTildeInPath
    }

    private static var payload: URL {
        if let path = value(after: "--payload") { return URL(fileURLWithPath: path, isDirectory: true) }
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Ensemble.app", isDirectory: true)
    }

    private static var engineInstaller: EngineInstaller {
        var installer = EngineInstaller()
        if let path = value(after: "--engine-destination") { installer.destinationFolder = URL(fileURLWithPath: path, isDirectory: true) }
        if let text = value(after: "--engine-releases"), let url = URL(string: text) ?? Optional(URL(fileURLWithPath: text)) {
            installer.releases = url.scheme == nil ? URL(fileURLWithPath: text) : url
        }
        return installer
    }

    private static var destination: URL {
        if let path = value(after: "--destination") { return URL(fileURLWithPath: path, isDirectory: true) }
        return AppInstaller.defaultDestination()
    }
}

/// Closing the window quits the installer, and it comes to the front when opened.
final class InstallerDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate() }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// `--unattended`: the whole install with no window and no click. Prints one line per step and exits with 0 when
/// everything asked for worked, 1 when the app could not be installed, 3 when only the engine could not be.
@MainActor
enum Unattended {
    static func run(_ model: InstallerModel) -> Never {
        Task { @MainActor in
            let arguments = CommandLine.arguments
            // 1. The app.
            model.install()
            while model.phase == .welcome || isInstalling(model.phase) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if case .failed(let message) = model.phase {
                print("app: failed: \(message)")
                exit(1)
            }
            print("app: installed at \(model.installer.installedURL.path)")

            // 2. The engine, unless it is there already or was not wanted.
            var engineReady = model.phase == .done
            if engineReady {
                print("engine: OpenCode is already installed")
            } else if arguments.contains("--skip-engine") {
                print("engine: skipped")
            } else {
                model.installEngine()
                while model.isInstallingEngine { try? await Task.sleep(for: .milliseconds(100)) }
                if case .failed(let message) = model.engineInstall {
                    print("engine: failed: \(message)")
                } else {
                    engineReady = true
                    print("engine: installed OpenCode at \(model.engineInstaller.installedURL.path)")
                }
            }

            // 3. Open it.
            if arguments.contains("--open") {
                print(await model.openEnsembleAndWait() ? "opened: Ensemble" : "opened: failed")
            }
            exit(engineReady || arguments.contains("--skip-engine") ? 0 : 3)
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    private static func isInstalling(_ phase: InstallerModel.Phase) -> Bool {
        if case .installing = phase { true } else { false }
    }
}

/// Pictures of every screen, for the install guide and for checking the look without clicking through.
@MainActor
enum InstallerPictures {
    static func render(model: InstallerModel, to folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = EngineSetup(homebrewInstalled: false, openCodeInstalled: false)
        let halfway = EngineSetup(homebrewInstalled: true, openCodeInstalled: false)
        let ready = EngineSetup(homebrewInstalled: true, openCodeInstalled: true)
        let screens: [(String, InstallerModel.Phase, EngineSetup, InstallerModel.EngineInstall)] = [
            ("1-welcome", .welcome, missing, .idle),
            ("2-installing", .installing(.checking), missing, .idle),
            ("3-engine", .engine, missing, .idle),
            ("3-engine-homebrew", .engine, halfway, .idle),
            ("3-engine-downloading", .engine, missing, .working(.downloading(fraction: 0.43))),
            ("3-engine-failed", .engine, missing, .failed(EngineInstaller.InstallError.wrongChecksum.localizedDescription)),
            ("4-done", .done, ready, .idle),
            ("4-done-engine-later", .done, missing, .idle),
            ("5-failed", .failed(AppInstaller.InstallError.notWritable("/Applications").localizedDescription), missing, .idle),
        ]
        for (name, phase, setup, engineInstall) in screens {
            model.show(phase, setup: setup, engineInstall: engineInstall)
            let screen = InstallerView(model: model)
                .frame(width: InstallerView.size.width, height: InstallerView.size.height)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: screen)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let url = folder.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { print(url.path) }
        }
    }
}
