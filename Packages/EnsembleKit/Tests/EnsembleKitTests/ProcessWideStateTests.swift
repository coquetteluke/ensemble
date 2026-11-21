import Foundation
import Testing

/// The file mode mask, the current folder and the environment belong to the whole process. Code that changes one of
/// them "for a moment" changes it for every thread, and a child process started in that moment keeps the changed
/// value for good. `AgentToolsServer.start` tightened the mask around `bind` until 2026-11-20: a folder another
/// thread made in those 40 microseconds lost its execute bit, and one random test in most full runs failed with a
/// permission error.
@Suite struct ProcessWideStateTests {
    /// Give a child its own folder or environment when it is started (`Process.currentDirectoryURL`,
    /// `Process.environment`, `posix_spawn_file_actions_addchdir`), and keep a file private with a private folder or
    /// `chmod`, instead of changing this process.
    @Test func nothingChangesTheMaskTheCurrentFolderOrTheEnvironment() throws {
        // The call as it is written, not as the end of a longer name (`posix_spawn_file_actions_addchdir`).
        let call = try Regex(#"(^|[^A-Za-z0-9_])(umask|chdir|fchdir|setenv|unsetenv|putenv)\s*\("#)
        let folderSetter = "changeCurrent" + "DirectoryPath"
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let folders = [package.appendingPathComponent("Sources"), package.appendingPathComponent("Tests"),
                       repository.appendingPathComponent("Apps")]

        var found: [String] = []
        var filesRead = 0
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                filesRead += 1
                guard [folderSetter, "umask", "chdir", "setenv", "putenv"].contains(where: text.contains) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    // A comment may name the call.
                    if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") { continue }
                    if line.contains(folderSetter) || line.firstMatch(of: call) != nil {
                        found.append("\(file.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        #expect(filesRead > 100, "the search read the source folders")
        #expect(found.isEmpty, "this changes state the whole process shares: \(found.joined(separator: ", "))")
    }
}
