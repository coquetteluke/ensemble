import Foundation
import Testing
@testable import EnsembleKit

@Suite struct FileTreeTests {
    /// A small project in a temporary folder, removed when the test ends.
    private final class Project {
        let root: String

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-filetree-" + UUID().uuidString)
            root = base.path
            for folder in ["Sources/App", "Sources/Kit", "docs", ".git/objects", "node_modules/left-pad"] {
                try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
            }
            for file in ["README.md", "Package.swift", "file10.txt", "file2.txt", "Sources/App/Main.swift", "Sources/App/MainView.swift",
                         "Sources/Kit/Store.swift", "docs/PLAN.md", ".git/HEAD", "node_modules/left-pad/index.js", ".env"] {
                FileManager.default.createFile(atPath: root + "/" + file, contents: Data("x".utf8))
            }
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test func foldersComeFirstThenFilesInFinderOrder() throws {
        let project = try Project()
        let entries = FileTree.list(project.root)
        #expect(entries.map(\.name) == ["docs", "Sources", ".env", "file2.txt", "file10.txt", "Package.swift", "README.md"])
        #expect(entries.map(\.isDirectory) == [true, true, false, false, false, false, false])
        #expect(entries.first?.path == project.root + "/docs")
    }

    @Test func versionControlAndBuildOutputAreNotListed() throws {
        let project = try Project()
        let names = Set(FileTree.list(project.root).map(\.name))
        #expect(!names.contains(".git"))
        #expect(!names.contains("node_modules"))
        #expect(FileTree.search(root: project.root, query: "HEAD").isEmpty)
        #expect(FileTree.search(root: project.root, query: "index.js").isEmpty)
    }

    @Test func aFolderThatCannotBeReadIsEmpty() {
        #expect(FileTree.list("/definitely/not/here-\(UUID().uuidString)").isEmpty)
    }

    @Test func searchMatchesEveryWordAnywhereInThePath() throws {
        let project = try Project()
        #expect(FileTree.search(root: project.root, query: "main").map(\.name) == ["Main.swift", "MainView.swift"])
        #expect(FileTree.search(root: project.root, query: "kit store").map(\.name) == ["Store.swift"])
        #expect(FileTree.search(root: project.root, query: "SWIFT app").map(\.name) == ["Main.swift", "MainView.swift"])
        #expect(FileTree.search(root: project.root, query: "   ").isEmpty)
        #expect(FileTree.search(root: project.root, query: "nothing-like-this").isEmpty)
    }

    @Test func aNameThatStartsWithTheWordComesFirstAndResultsAreCapped() throws {
        let project = try Project()
        // "plan" starts PLAN.md; "p" also matches Package.swift (starts with it) and paths that only contain it.
        #expect(FileTree.search(root: project.root, query: "plan").first?.name == "PLAN.md")
        #expect(FileTree.search(root: project.root, query: "s", limit: 2).count == 2)
        #expect(FileTree.search(root: project.root, query: "swift", visitLimit: 3).count <= 3)
    }

    @Test func linksAreListedButNeverWalkedInto() throws {
        let project = try Project()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-filetree-outside-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        FileManager.default.createFile(atPath: outside + "/secret.txt", contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: project.root + "/elsewhere", withDestinationPath: outside)

        let link = try #require(FileTree.list(project.root).first { $0.name == "elsewhere" })
        #expect(link.isLink)
        #expect(!link.isDirectory)
        #expect(FileTree.search(root: project.root, query: "secret").isEmpty)
    }

    @Test func aResultsFolderIsShownBelowTheRoot() throws {
        let project = try Project()
        #expect(FileTree.folder(of: project.root + "/Sources/App/Main.swift", under: project.root) == "Sources/App")
        #expect(FileTree.folder(of: project.root + "/README.md", under: project.root) == "")
    }
}
