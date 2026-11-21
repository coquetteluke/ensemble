#if os(macOS)
import Foundation

/// Copies the app that ships inside the installer into an Applications folder.
/// Foundation only: the installer app compiles this file on its own, without the rest of EnsembleKit.
public struct AppInstaller: Sendable {
    public enum Stage: Sendable, Equatable { case copying, checking, finishing }

    public enum InstallError: Error, Equatable, LocalizedError {
        case payloadMissing
        case notWritable(String)
        case damaged
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .payloadMissing: "This installer is incomplete: the app is not inside it. Download it again."
            case .notWritable(let folder): "Ensemble could not be copied to \(folder). You do not have permission to change that folder."
            case .damaged: "The copy did not pass its check, so nothing was installed. Download the installer again."
            case .failed(let reason): "The install did not finish. \(reason)"
            }
        }
    }

    /// The app inside the installer.
    public let payload: URL
    /// The folder it goes into.
    public let destinationFolder: URL

    public init(payload: URL, destinationFolder: URL) {
        self.payload = payload
        self.destinationFolder = destinationFolder
    }

    public var installedURL: URL { destinationFolder.appendingPathComponent(payload.lastPathComponent) }

    /// `/Applications` when this account may write there, otherwise the account's own `~/Applications`.
    public static func defaultDestination(systemApplications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                                          home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        if FileManager.default.isWritableFile(atPath: systemApplications.path) { return systemApplications }
        return home.appendingPathComponent("Applications", isDirectory: true)
    }

    /// `CFBundleShortVersionString` of an app, for "Ensemble 0.1.0" in the window.
    public static func version(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Copies the app next to its final place, takes the "downloaded from the internet" mark off the copy, checks
    /// the copy's signature, then swaps it in. A copy that fails the check is removed and the old app, if any, stays.
    /// `verify` is replaceable for tests; the default runs `codesign --verify`.
    @discardableResult
    public func install(progress: @Sendable (Stage) -> Void = { _ in },
                        verify: (URL) -> Bool = AppInstaller.signatureIsValid) throws -> URL {
        let files = FileManager.default
        guard files.fileExists(atPath: payload.appendingPathComponent("Contents").path) else { throw InstallError.payloadMissing }
        do {
            try files.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        } catch {
            throw InstallError.notWritable(destinationFolder.path)
        }
        guard files.isWritableFile(atPath: destinationFolder.path) else { throw InstallError.notWritable(destinationFolder.path) }

        progress(.copying)
        let staging = destinationFolder.appendingPathComponent(".\(payload.lastPathComponent).installing-\(UUID().uuidString)")
        do {
            try files.copyItem(at: payload, to: staging)
        } catch {
            try? files.removeItem(at: staging)
            throw InstallError.failed(error.localizedDescription)
        }
        Self.removeQuarantine(at: staging)

        progress(.checking)
        guard verify(staging) else {
            try? files.removeItem(at: staging)
            throw InstallError.damaged
        }

        progress(.finishing)
        do {
            if files.fileExists(atPath: installedURL.path) {
                _ = try files.replaceItemAt(installedURL, withItemAt: staging)
            } else {
                try files.moveItem(at: staging, to: installedURL)
            }
        } catch {
            try? files.removeItem(at: staging)
            throw InstallError.failed(error.localizedDescription)
        }
        return installedURL
    }

    /// Removes `com.apple.quarantine` from a folder and everything in it. Returns how many items carried it.
    /// The person has already approved the installer in Privacy & Security; this keeps macOS from asking a second
    /// time for the app the installer puts in place. It touches only that copy and changes no system setting.
    @discardableResult
    public static func removeQuarantine(at root: URL) -> Int {
        var removed = 0
        var paths = [root.path]
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker { paths.append(root.appendingPathComponent(relative).path) }
        }
        for path in paths where removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 { removed += 1 }
        return removed
    }

    /// True when `codesign --verify --deep --strict` accepts the bundle.
    public static func signatureIsValid(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
#endif
