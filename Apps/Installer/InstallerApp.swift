import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// "Install Ensemble": a small app that ships on the disk image with Ensemble.app inside it.
///
/// For testing: `--payload <Ensemble.app>` uses another copy of the app, `--destination <folder>` installs somewhere
/// other than Applications, and `--render <folder>` writes a picture of every screen and quits.
@main
struct InstallerApp: App {
    @State private var model: InstallerModel

    init() {
        if let folder = Self.value(after: "--render") {
            let sample = InstallerModel(payload: Self.payload, destinationFolder: Self.destination, forPictures: true)
            InstallerPictures.render(model: sample, to: URL(fileURLWithPath: folder, isDirectory: true))
            exit(0)
        }
        _model = State(initialValue: InstallerModel(payload: Self.payload, destinationFolder: Self.destination))
    }

    var body: some Scene {
        Window("Install Ensemble", id: "installer") {
            InstallerView(model: model)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
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

    private static var destination: URL {
        if let path = value(after: "--destination") { return URL(fileURLWithPath: path, isDirectory: true) }
        return AppInstaller.defaultDestination()
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
        let screens: [(String, InstallerModel.Phase, EngineSetup, Bool)] = [
            ("1-welcome", .welcome, halfway, false),
            ("2-installing", .installing(.checking), halfway, false),
            ("3-engine", .engine, halfway, false),
            ("3-engine-no-homebrew", .engine, missing, true),
            ("4-done", .done, ready, false),
            ("4-done-engine-later", .done, halfway, false),
            ("5-failed", .failed(AppInstaller.InstallError.notWritable("/Applications").localizedDescription), halfway, false),
        ]
        for (name, phase, setup, includeHomebrew) in screens {
            model.show(phase, setup: setup, includeHomebrew: includeHomebrew)
            let renderer = ImageRenderer(content: InstallerView(model: model).environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let url = folder.appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { print(url.path) }
        }
    }
}
