import Foundation

/// What the setup screens need when the engine is missing: whether OpenCode is on this Mac, and whether Homebrew is
/// (people who have it can use it; nobody needs it, because `EngineInstaller` downloads OpenCode directly).
public struct EngineSetup: Equatable, Sendable {
    public var homebrewInstalled: Bool
    public var openCodeInstalled: Bool

    public init(homebrewInstalled: Bool, openCodeInstalled: Bool) {
        self.homebrewInstalled = homebrewInstalled
        self.openCodeInstalled = openCodeInstalled
    }

    /// For people who already use Homebrew and would rather install OpenCode with it.
    public static let openCodeCommand = "brew install opencode"

    /// Where Homebrew puts `brew`: Apple silicon first, then Intel.
    public static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Directories searched for `opencode`: `PATH`, then Homebrew and the usual install places.
    /// (Kept here, free of other EnsembleKit types, because the installer app compiles this file on its own.)
    public static func engineSearchPaths() -> [String] {
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.opencode/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Looks on disk. Cheap enough to call every few seconds while the setup screen is open.
    public static func detect(engineSearchPaths: [String] = EngineSetup.engineSearchPaths(),
                              homebrewDirectories: [String] = EngineSetup.homebrewDirectories) -> EngineSetup {
        EngineSetup(homebrewInstalled: hasExecutable("brew", in: homebrewDirectories),
                    openCodeInstalled: hasExecutable("opencode", in: engineSearchPaths))
    }

    private static func hasExecutable(_ name: String, in directories: [String]) -> Bool {
        directories.contains { directory in
            FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path)
        }
    }
}
