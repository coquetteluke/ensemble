import Foundation
import Testing
@testable import EnsembleKit

/// File paths in agent text: which ones become links, with their lines, and which never do.
@Suite struct FilePathLinkTests {
    /// A project folder with a few files, and a folder next to it that is outside the project.
    final class Sandbox {
        let root: URL
        let project: String
        let outside: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-paths-\(UUID().uuidString)")
            project = root.appendingPathComponent("project").path
            outside = root.appendingPathComponent("other").path
            let fm = FileManager.default
            for folder in ["Sources/App", "docs", "Apps/Mac/Search"] {
                try fm.createDirectory(atPath: project + "/" + folder, withIntermediateDirectories: true)
            }
            try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
            for file in ["Sources/App/Foo.swift", "docs/PLAN.md", "Package.swift", "icon@2x.png", ".gitignore"] {
                try "x".write(toFile: project + "/" + file, atomically: true, encoding: .utf8)
            }
            try "secret".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(atPath: project + "/escape.txt", withDestinationPath: outside + "/secret.txt")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// The disk check without the cache, so each test sees its own files.
        let check: FilePathDetector.FileCheck = { FileLinkCache.diskCheck($0, base: $1) }

        func matches(_ text: String) -> [FilePathDetector.Match] {
            FilePathDetector.matches(in: text, base: project, isFileInside: check)
        }

        func found(_ text: String) -> [String] {
            matches(text).map { String(text[$0.range]) }
        }
    }

    @Test func pathsThatExistBecomeLinks() throws {
        let box = try Sandbox()
        let text = "See Sources/App/Foo.swift:42 and docs/PLAN.md. Package.swift too."
        let matches = box.matches(text)
        #expect(matches.map { String(text[$0.range]) } == ["Sources/App/Foo.swift:42", "docs/PLAN.md", "Package.swift"])
        #expect(matches.map(\.link.path) == [box.project + "/Sources/App/Foo.swift", box.project + "/docs/PLAN.md", box.project + "/Package.swift"]
            .map { ($0 as NSString).standardizingPath })
        #expect(matches.map(\.link.line) == [42, nil, nil])
        #expect(matches[0].link.display(base: (box.project as NSString).standardizingPath) == "Sources/App/Foo.swift:42")
    }

    @Test func lineSuffixes() throws {
        let box = try Sandbox()
        let column = try #require(box.matches("at Sources/App/Foo.swift:12:7").first)
        #expect(column.link.line == 12)
        #expect(column.link.column == 7)
        #expect(box.matches("docs/PLAN.md#L30").first?.link.line == 30)
        #expect(box.matches("docs/PLAN.md:10-20").first?.link.line == 10)
        // Punctuation after the line number is not part of it.
        #expect(box.found("(Sources/App/Foo.swift:42), then") == ["Sources/App/Foo.swift:42"])
        #expect(box.found("in Package.swift: the target") == ["Package.swift"])
        // A colon followed by words is not a line.
        #expect(box.found("docs/PLAN.md:intro").isEmpty)
    }

    @Test func quotedAndCodeLikeSurroundings() throws {
        let box = try Sandbox()
        #expect(box.found("\"docs/PLAN.md\" and 'Package.swift'") == ["docs/PLAN.md", "Package.swift"])
        #expect(box.found("./docs/PLAN.md") == ["./docs/PLAN.md"])
        #expect(box.found("icon@2x.png and .gitignore") == ["icon@2x.png", ".gitignore"])
        #expect(FilePathDetector.link(forCode: "docs/PLAN.md", base: box.project, isFileInside: box.check) != nil)
        #expect(FilePathDetector.link(forCode: " Sources/App/Foo.swift:3 ", base: box.project, isFileInside: box.check)?.line == 3)
        #expect(FilePathDetector.link(forCode: "swift build", base: box.project, isFileInside: box.check) == nil)
    }

    @Test func urlsThatLookLikePathsAreNotLinks() throws {
        let box = try Sandbox()
        #expect(box.found("https://github.com/me/project/blob/main/docs/PLAN.md").isEmpty)
        #expect(box.found("http://localhost:3000/docs/PLAN.md").isEmpty)
        #expect(box.found("file:///docs/PLAN.md").isEmpty)
        #expect(box.found("example.com/docs/PLAN.md").isEmpty)
    }

    @Test func pathsOutsideTheFolderAreNotLinks() throws {
        let box = try Sandbox()
        #expect(box.found("../other/secret.txt").isEmpty)
        #expect(box.found(box.outside + "/secret.txt").isEmpty)
        #expect(box.found("Sources/../../other/secret.txt").isEmpty)
        // A link inside the folder that points outside it.
        #expect(box.found("escape.txt").isEmpty)
        // The same folder name as a prefix is not inside ("/x/project-old" is not in "/x/project").
        #expect(FilePathDetector.resolve(box.project + "-old/a.txt", base: box.project) == nil)
    }

    @Test func absolutePathsInsideTheFolderAreLinks() throws {
        let box = try Sandbox()
        let absolute = box.project + "/docs/PLAN.md"
        #expect(box.found("open \(absolute):5 now") == [absolute + ":5"])
    }

    @Test func wordsVersionsAndMissingFilesAreNotLinks() throws {
        let box = try Sandbox()
        #expect(box.found("Version 2.3.0 is out, e.g. today.").isEmpty)
        #expect(box.found("docs/MISSING.md and Missing.swift").isEmpty)
        #expect(box.found("the docs folder, docs/ and Sources/App").isEmpty)
        #expect(box.found("and/or this").isEmpty)
        #expect(box.found("--flag=Package.swift").isEmpty)
    }

    @Test func pathShape() {
        #expect(FilePathDetector.looksLikePath("docs/PLAN.md"))
        #expect(FilePathDetector.looksLikePath("Package.swift"))
        #expect(FilePathDetector.looksLikePath("Makefile") == false)
        #expect(FilePathDetector.looksLikePath("2.3.0") == false)
        #expect(FilePathDetector.looksLikePath("docs/") == false)
        #expect(FilePathDetector.splitLine("a.swift:3:4") == ("a.swift", 3, 4))
        #expect(FilePathDetector.splitLine("a.swift:0") == ("a.swift:0", nil, nil))
        #expect(FilePathDetector.splitLine("a.swift:1:2:3") == ("a.swift:1:2:3", nil, nil))
    }

    @Test func linkURLsRoundTrip() {
        let link = FileLink(path: "/Users/me/My Project/a b.swift", line: 12, column: 3)
        #expect(link.url.scheme == FileLink.scheme)
        #expect(FileLink(url: link.url) == link)
        #expect(FileLink(url: URL(string: "https://example.com")!) == nil)
        #expect(FileLink(url: URL(string: "ensemble-file://open?path=relative.txt")!) == nil)
    }

    @Test func markdownMarksPathsInTextAndCodeSpans() throws {
        let box = try Sandbox()
        let base = (box.project as NSString).standardizingPath
        let attributed = MarkdownInline.attributed("Edited `docs/PLAN.md` and Sources/App/Foo.swift:9, see [site](https://example.com).",
                                                   theme: .dark, size: 14, fileBase: base)
        var links: [(String, URL)] = []
        for run in attributed.runs {
            if let url = run.link { links.append((String(attributed[run.range].characters), url)) }
        }
        #expect(links.map(\.0) == ["docs/PLAN.md", "Sources/App/Foo.swift:9", "site"])
        #expect(FileLink(url: links[0].1)?.path == base + "/docs/PLAN.md")
        #expect(FileLink(url: links[1].1)?.line == 9)
        #expect(links[2].1.absoluteString == "https://example.com")

        let plain = MarkdownInline.attributed("Edited docs/PLAN.md", theme: .dark, size: 14)
        #expect(plain.runs.allSatisfy { $0.link == nil })
    }
}
