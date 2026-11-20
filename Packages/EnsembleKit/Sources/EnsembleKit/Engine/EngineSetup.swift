import Foundation

/// What the first-launch screen needs when the engine is missing: whether Homebrew and OpenCode are on this Mac, and
/// the commands that install them. Ensemble never runs these itself; the person runs them in Terminal.
public struct EngineSetup: Equatable, Sendable {
    public var homebrewInstalled: Bool
    public var openCodeInstalled: Bool

    public init(homebrewInstalled: Bool, openCodeInstalled: Bool) {
        self.homebrewInstalled = homebrewInstalled
        self.openCodeInstalled = openCodeInstalled
    }

    /// One command the person runs in Terminal.
    public struct Step: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case homebrew, openCode }
        public let kind: Kind
        public let title: String
        public let note: String
        public let command: String
        public let done: Bool
        public var id: String { kind.rawValue }
    }

    /// The install command from https://brew.sh.
    public static let homebrewCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    public static let openCodeCommand = "brew install opencode"

    /// Where Homebrew puts `brew`: Apple silicon first, then Intel.
    public static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The steps to show. Homebrew is listed only when it was missing when the screen opened (`includeHomebrew`), and
    /// stays listed, ticked, once it is installed, so the list does not jump while the person works through it.
    public func steps(includeHomebrew: Bool) -> [Step] {
        var steps: [Step] = []
        if includeHomebrew {
            steps.append(Step(kind: .homebrew, title: "Install Homebrew",
                              note: "Homebrew installs OpenCode. Its installer asks for your Mac password.",
                              command: Self.homebrewCommand, done: homebrewInstalled))
        }
        steps.append(Step(kind: .openCode, title: "Install OpenCode",
                          note: "OpenCode is the free, open-source program that runs the agents.",
                          command: Self.openCodeCommand, done: openCodeInstalled))
        return steps
    }

    /// Looks on disk. Cheap enough to call every few seconds while the setup screen is open.
    public static func detect(engineSearchPaths: [String] = EngineManager.defaultSearchPaths(),
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
