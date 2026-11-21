import Foundation
import Testing
@testable import EnsembleKit

@Suite("Sidebar linked sessions tree")
struct SidebarTreeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ id: String, hoursAgo: Double = 1, dir: String = "/a/app", pinned: Bool = false) -> SidebarEntry {
        SidebarEntry(id: id, title: "Title \(id)", directory: dir, created: now.addingTimeInterval(-hoursAgo * 3600),
                     updated: now.addingTimeInterval(-hoursAgo * 3600), pinned: pinned)
    }

    func shape(_ rows: [SidebarTreeRow]) -> [String] {
        rows.map { String(repeating: ".", count: $0.depth) + $0.id + ($0.hasChildren ? "+" : "") }
    }

    @Test func noLinksIsFlat() {
        let list = [entry("a"), entry("b"), entry("c")]
        #expect(shape(SidebarTree.rows(list, parents: [:])) == ["a", "b", "c"])
        // Links to sessions that are not in the list change nothing either.
        #expect(shape(SidebarTree.rows(list, parents: ["a": "x", "b": "y"])) == ["a", "b", "c"])
    }

    @Test func threeLevels() {
        let list = [entry("grandchild"), entry("other"), entry("child"), entry("root")]
        let rows = SidebarTree.rows(list, parents: ["child": "root", "grandchild": "child"])
        #expect(shape(rows) == ["other", "root+", ".child+", "..grandchild"])
    }

    @Test func childrenKeepTheListOrder() {
        let list = [entry("c2"), entry("p"), entry("c1"), entry("c3")]
        let rows = SidebarTree.rows(list, parents: ["c1": "p", "c2": "p", "c3": "p"])
        #expect(shape(rows) == ["p+", ".c2", ".c1", ".c3"])
    }

    @Test func missingParentIsSkippedForTheNextAncestor() {
        // "hidden" is archived, pinned away or in another group: the grandchild attaches to the root.
        let list = [entry("root"), entry("grandchild")]
        let rows = SidebarTree.rows(list, parents: ["grandchild": "hidden", "hidden": "root"])
        #expect(shape(rows) == ["root+", ".grandchild"])
        // With no ancestor in the list at all, it shows at top level.
        #expect(shape(SidebarTree.rows([entry("grandchild"), entry("x")], parents: ["grandchild": "hidden", "hidden": "root"]))
            == ["grandchild", "x"])
    }

    @Test func cycleNeverLoopsOrHides() {
        let list = [entry("x"), entry("a"), entry("b"), entry("c")]
        let rows = SidebarTree.rows(list, parents: ["a": "b", "b": "c", "c": "a"])
        #expect(rows.count == 4)
        #expect(Set(rows.map(\.id)) == ["x", "a", "b", "c"])
        #expect(shape(rows) == ["x", "a+", ".c+", "..b"])
        // A cycle through sessions outside the list ends too.
        #expect(shape(SidebarTree.rows([entry("a"), entry("z")], parents: ["a": "m", "m": "n", "n": "m"])) == ["a", "z"])
    }

    @Test func selfLinkIsIgnored() {
        let rows = SidebarTree.rows([entry("a"), entry("b")], parents: ["a": "a", "b": "a"])
        #expect(shape(rows) == ["a+", ".b"])
    }

    @Test func foldingHidesEveryLevelBelow() {
        let list = [entry("root"), entry("child"), entry("grandchild"), entry("other")]
        let rows = SidebarTree.rows(list, parents: ["child": "root", "grandchild": "child"])
        #expect(shape(SidebarTree.visible(rows, folded: ["root"])) == ["root+", "other"])
        #expect(shape(SidebarTree.visible(rows, folded: ["child"])) == ["root+", ".child+", "other"])
        // A fold key on a row with nothing under it changes nothing.
        #expect(shape(SidebarTree.visible(rows, folded: ["other"])) == shape(rows))
    }

    @Test func arrangementNestsInsideEachGroupAndOrderFollows() {
        let entries = [entry("child", hoursAgo: 1), entry("root", hoursAgo: 3), entry("solo", hoursAgo: 2),
                       entry("elsewhere", hoursAgo: 4, dir: "/a/site")]
        let parents = ["child": "root", "elsewhere": "root"]
        let result = SidebarArrangement.arrange(entries, grouping: .project, sort: .recent, parents: parents, now: now)
        #expect(result.groups.map(\.title) == ["app", "site"])
        #expect(shape(result.groups[0].rows) == ["solo", "root+", ".child"])
        // A parent in another group does not pull the session out of its own group.
        #expect(shape(result.groups[1].rows) == ["elsewhere"])
        #expect(result.order.map(\.id) == ["solo", "root", "child", "elsewhere"])

        let byState = SidebarArrangement.arrange(entries, grouping: .state, sort: .name, parents: parents, now: now)
        #expect(shape(byState.groups[0].rows) == ["root+", ".child", ".elsewhere", "solo"])
    }

    @Test func pinnedParentLeavesChildAtTopLevel() {
        let entries = [entry("root", pinned: true), entry("child"), entry("pinnedChild", pinned: true)]
        let result = SidebarArrangement.arrange(entries, grouping: .project, sort: .name,
                                                parents: ["child": "root", "pinnedChild": "root"], now: now)
        #expect(shape(result.pinnedRows) == ["root+", ".pinnedChild"])
        #expect(shape(result.groups[0].rows) == ["child"])
    }
}

@Suite("Sidebar folder order")
struct SidebarFolderOrderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func group(_ id: String) -> SidebarGroup {
        SidebarGroup(kind: .project(directory: id), title: id, entries: [])
    }

    @Test func applyPutsNewFoldersFirst() {
        let groups = ["/new", "/b", "/a", "/c"].map(group)
        #expect(SidebarFolderOrder.apply(groups, saved: []).map(\.id) == ["/new", "/b", "/a", "/c"])
        #expect(SidebarFolderOrder.apply(groups, saved: ["/a", "/gone", "/c", "/b"]).map(\.id) == ["/new", "/a", "/c", "/b"])
    }

    @Test func movingBeforeAndAfter() {
        let shown = ["/a", "/b", "/c", "/d"]
        #expect(SidebarFolderOrder.moving("/d", to: "/b", after: false, shown: shown, saved: []) == ["/a", "/d", "/b", "/c"])
        #expect(SidebarFolderOrder.moving("/a", to: "/c", after: true, shown: shown, saved: []) == ["/b", "/c", "/a", "/d"])
        // Onto itself, or onto or from an unknown folder: the shown order is saved unchanged.
        #expect(SidebarFolderOrder.moving("/b", to: "/b", after: true, shown: shown, saved: []) == shown)
        #expect(SidebarFolderOrder.moving("/x", to: "/b", after: true, shown: shown, saved: []) == shown)
        #expect(SidebarFolderOrder.moving("/b", to: "/x", after: true, shown: shown, saved: []) == shown)
    }

    @Test func movingKeepsHiddenSavedFoldersInPlace() {
        // "/hidden" has no sessions in the list right now; it stays after "/a", the folder it followed.
        let saved = ["/a", "/hidden", "/b", "/c"]
        let shown = ["/a", "/b", "/c"]
        #expect(SidebarFolderOrder.moving("/c", to: "/a", after: false, shown: shown, saved: saved) == ["/c", "/a", "/hidden", "/b"])
        #expect(SidebarFolderOrder.moving("/c", to: "/a", after: false, shown: shown, saved: ["/first", "/a"])
            == ["/first", "/c", "/a", "/b"])
    }

    @Test func moveUpAndDown() {
        let shown = ["/a", "/b", "/c"]
        #expect(SidebarFolderOrder.moving("/b", by: -1, shown: shown, saved: []) == ["/b", "/a", "/c"])
        #expect(SidebarFolderOrder.moving("/b", by: 1, shown: shown, saved: []) == ["/a", "/c", "/b"])
        #expect(SidebarFolderOrder.moving("/a", by: -1, shown: shown, saved: []) == shown)
        #expect(SidebarFolderOrder.moving("/c", by: 1, shown: shown, saved: []) == shown)
        #expect(!SidebarFolderOrder.canMove("/a", by: -1, shown: shown))
        #expect(SidebarFolderOrder.canMove("/a", by: 1, shown: shown))
        #expect(!SidebarFolderOrder.canMove("/c", by: 1, shown: shown))
        #expect(!SidebarFolderOrder.canMove("/x", by: 1, shown: shown))
    }

    @Test func arrangementAppliesOrderOnlyForProjects() {
        let entries = [
            SidebarEntry(id: "1", title: "One", directory: "/x/zeta", created: now, updated: now),
            SidebarEntry(id: "2", title: "Two", directory: "/x/alpha", created: now - 60, updated: now - 60),
            SidebarEntry(id: "3", title: "Three", directory: "/x/new", created: now - 7200, updated: now - 7200),
        ]
        let saved = ["/x/alpha", "/x/zeta"]
        let projects = SidebarArrangement.arrange(entries, grouping: .project, sort: .recent, folderOrder: saved, now: now)
        #expect(projects.groups.map(\.id) == ["/x/new", "/x/alpha", "/x/zeta"])
        #expect(projects.order.map(\.id) == ["3", "2", "1"])
        let byDate = SidebarArrangement.arrange(entries, grouping: .date, sort: .recent, folderOrder: saved, now: now)
        #expect(byDate.groups.map(\.id) == SidebarArrangement.arrange(entries, grouping: .date, sort: .recent, now: now).groups.map(\.id))
    }
}

@Suite("Session links store")
@MainActor
struct SessionLinksStoreTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ens-links-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("session-links.json")
    }

    @Test func saveAndLoadRoundTrip() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let links = SessionLinks(fileURL: file)
        links.record(child: "child", parent: "root")
        links.record(child: "grandchild", parent: "child")
        links.record(child: "self", parent: "self")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let reloaded = SessionLinks(fileURL: file)
        reloaded.loadIfNeeded()
        #expect(reloaded.parents == ["child": "root", "grandchild": "child"])

        reloaded.remove("child")
        #expect(reloaded.parents.isEmpty)
        let again = SessionLinks(fileURL: file)
        again.loadIfNeeded()
        #expect(again.parents.isEmpty)
    }

    @Test func importedLinksMergeButAreNeverSaved() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let links = SessionLinks(fileURL: file)
        links.setImported(["a": "b", "c": "d", "e": "e"])
        links.record(child: "a", parent: "own")
        #expect(links.parents == ["a": "own", "c": "d"])
        let reloaded = SessionLinks(fileURL: file)
        reloaded.loadIfNeeded()
        #expect(reloaded.parents == ["a": "own"])
        links.remove("d")
        #expect(links.parents == ["a": "own"])
    }

    @Test func noFileWritesNothing() {
        let links = SessionLinks(fileURL: nil)
        links.record(child: "a", parent: "b")
        #expect(links.parents == ["a": "b"])
        #expect(SessionLinks.defaultURL(isPreview: true) == nil)
        // Test runners are not an app bundle, so they never get the real file either.
        #expect(SessionLinks.defaultURL(isPreview: false) == nil)
    }

    @Test func decodingToleratesMissingAndUnknownKeys() {
        let json = """
        {"version": 3, "links": [
          {"childID": "a", "parentID": "b", "created": "2026-11-20T10:00:00Z", "extra": true},
          {"childID": "c", "parentID": "d"},
          {"childID": "e"},
          {"parentID": "f"},
          {"childID": "g", "parentID": "g"},
          "not an object",
          {"childID": "h", "parentID": "i", "created": "yesterday"}
        ]}
        """
        let decoded = SessionLinks.decode(Data(json.utf8))
        #expect(decoded.mapValues(\.parentID) == ["a": "b", "c": "d", "h": "i"])
        #expect(decoded["a"]?.created != nil)
        #expect(decoded["c"]?.created == nil)
        #expect(SessionLinks.decode(Data("{}".utf8)).isEmpty)
        #expect(SessionLinks.decode(Data("not json".utf8)).isEmpty)
        #expect(SessionLinks.decode(Data(#"{"links": 5}"#.utf8)).isEmpty)
    }
}

#if os(macOS)
@Suite("Claude desktop linked sessions")
struct ClaudeDesktopLinksTests {
    /// A made-up desktop app folder with one org of session files.
    func makeDesktop(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ens-desktop-\(UUID().uuidString.prefix(8))")
        let org = root.appendingPathComponent("claude-code-sessions/acct-1/org-1")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        for (name, body) in files {
            try Data(body.utf8).write(to: org.appendingPathComponent(name))
        }
        return root
    }

    @Test func decodesStartedFromAndResolvesEnsembleIDs() throws {
        let desktop = try makeDesktop([
            "local_root.json": #"{"sessionId": "local_root", "cliSessionId": "cli-root", "title": "Root", "lastActivityAt": 1}"#,
            "local_child.json": #"""
            {"sessionId": "local_child", "cliSessionId": "cli-child-new", "priorCliSessionIds": ["cli-child-old"],
             "spawnedFrom": {"sessionId": "local_root", "taskId": "t1", "title": "Root", "sideSession": true, "more": {"x": 1}},
             "forkedFromSessionId": "local_other"}
            """#,
            "local_grand.json": #"{"sessionId": "local_grand", "cliSessionId": "cli-grand", "spawnedFrom": {"sessionId": "local_child"}}"#,
            "local_detached.json": #"{"sessionId": "local_detached", "cliSessionId": "cli-detached", "spawnedFrom": {"sessionId": "local_root"}, "lineageDetached": true}"#,
            "local_orphan.json": #"{"sessionId": "local_orphan", "cliSessionId": "cli-orphan", "spawnedFrom": {"sessionId": "local_missing"}}"#,
            "local_forkonly.json": #"{"sessionId": "local_forkonly", "cliSessionId": "cli-forkonly", "forkedFromSessionId": "local_root"}"#,
            "local_badshape.json": #"{"sessionId": "local_badshape", "cliSessionId": "cli-bad", "spawnedFrom": "local_root"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: desktop) }
        let sessions = ClaudeDesktopSessions.load(desktopDirectory: desktop)
        #expect(sessions.byCLISession["cli-child-new"]?.spawnedFromSessionID == "local_root")
        #expect(sessions.byCLISession["cli-detached"]?.lineageDetached == true)
        #expect(sessions.byCLISession["cli-root"]?.spawnedFromSessionID == nil)
        #expect(sessions.byCLISession["cli-bad"]?.spawnedFromSessionID == nil)

        // The child is known in Ensemble by its earlier CLI id; the grandchild started in Ensemble has its own id.
        let known: [(id: String, cliID: String)] = [
            ("cli-root", "cli-root"), ("cli-child-old", "cli-child-old"), ("ens-grand", "cli-grand"),
            ("cli-detached", "cli-detached"), ("cli-orphan", "cli-orphan"), ("cli-forkonly", "cli-forkonly"), ("cli-bad", "cli-bad"),
        ]
        let links = ClaudeDesktopLinks.links(desktop: sessions, sessions: known)
        #expect(links == ["cli-child-old": "cli-root", "ens-grand": "cli-child-old"])
    }

    @Test func sessionsEnsembleDoesNotHaveAreLeftOut() throws {
        let desktop = try makeDesktop([
            "local_root.json": #"{"sessionId": "local_root", "cliSessionId": "cli-root"}"#,
            "local_child.json": #"{"sessionId": "local_child", "cliSessionId": "cli-child", "spawnedFrom": {"sessionId": "local_root"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: desktop) }
        let sessions = ClaudeDesktopSessions.load(desktopDirectory: desktop)
        #expect(ClaudeDesktopLinks.links(desktop: sessions, sessions: [("cli-child", "cli-child")]).isEmpty)
        #expect(ClaudeDesktopLinks.links(desktop: sessions, sessions: []).isEmpty)
    }
}
#endif
