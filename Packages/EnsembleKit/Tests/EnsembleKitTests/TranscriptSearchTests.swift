import Foundation
import Testing
@testable import EnsembleKit

/// Transcript search: searchable text, query terms, snippets, ranking, the SQLite index and the indexer.
@Suite struct TranscriptSearchTests {
    // MARK: Text and queries

    @Test func entriesKeepWhatPeopleWroteAndToolTitles() {
        let items: [TranscriptItem] = [
            .user(id: "u", text: "Fix the  SSE\nreconnect", date: Date()),
            .reasoning(id: "r", text: "secret thinking", streaming: false),
            .agentText(id: "a", text: "## Plan\n**Retry** with `backoff`, see [the docs](https://example.com).\n```swift\nlet x = 1\n```", agentID: nil, streaming: false),
            .tool(ToolCallInfo(id: "t", name: "bash", title: "swift test --filter Stream", status: .succeeded, outputPreview: "huge output")),
            .notice(id: "n", text: "Interrupted"),
            .error(id: "e", message: "Network lost"),
        ]
        let entries = TranscriptSearchText.entries(items)
        #expect(entries.map(\.itemID) == ["u", "a", "t", "e"])
        #expect(entries.map(\.role) == [.user, .agent, .tool, .error])
        #expect(entries[0].text == "Fix the SSE reconnect")
        #expect(entries[1].text == "Plan Retry with backoff, see the docs. let x = 1")
        #expect(entries[2].text == "swift test --filter Stream")
        #expect(entries.map(\.ordinal) == [0, 2, 3, 5])
    }

    @Test func queriesFoldCaseAndAccentsLikeTheIndex() {
        let query = TranscriptSearchQuery("Café  SSE-reconnect sse")
        #expect(query.terms == ["cafe", "sse", "reconnect"])
        #expect(query.ftsExpression == "\"cafe\"* \"sse\"* \"reconnect\"*")
        #expect(TranscriptSearchQuery("  -- ").isEmpty)
    }

    // MARK: Snippets

    @Test func shortTextIsShownWholeWithMatchesMarked() {
        let snippet = TranscriptSnippet.make("Make the stream reconnect after sleep", terms: ["recon", "sleep"])
        #expect(snippet.text == "Make the stream reconnect after sleep")
        #expect(snippet.highlights.map { substring(snippet.text, $0) } == ["recon", "sleep"])
    }

    @Test func longTextIsCutAroundTheMatchAtWordBoundaries() {
        let before = String(repeating: "alpha beta gamma delta ", count: 20)
        let after = String(repeating: " epsilon zeta eta theta", count: 20)
        let text = before + "we decided to use SQLite for the client cache" + after
        let snippet = TranscriptSnippet.make(text, terms: ["sqlite", "client"], length: 120)
        #expect(snippet.text.hasPrefix("\u{2026}"))
        #expect(snippet.text.hasSuffix("\u{2026}"))
        #expect(snippet.text.contains("we decided to use SQLite for the client cache"))
        #expect(snippet.text.count <= 122)
        let marked = snippet.highlights.map { substring(snippet.text, $0) }
        #expect(marked == ["SQLite", "client"])
        // Cut between words, never inside one.
        let inner = snippet.text.dropFirst().dropLast()
        #expect(!inner.hasPrefix(" "))
        #expect(text.contains(String(inner)))
        let words = Set(text.split(separator: " ").map(String.init))
        #expect(inner.split(separator: " ").allSatisfy { words.contains(String($0)) })
    }

    @Test func snippetPrefersThePlaceWithTheMostTerms() {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 12)
        let text = "postgres first. " + filler + "postgres and sqlite together here. " + filler
        let snippet = TranscriptSnippet.make(text, terms: ["postgres", "sqlite"], length: 80)
        #expect(snippet.text.contains("postgres and sqlite together"))
    }

    @Test func matchesStartWords() {
        let snippet = TranscriptSnippet.marking("Unreconnected reconnect", terms: ["reconnect"])
        #expect(snippet.highlights.map { substring(snippet.text, $0) } == ["reconnect"])
        #expect(snippet.highlights.first?.lowerBound == 14)
    }

    // MARK: Ranking

    private func session(_ id: String, _ title: String, directory: String = "/p/one", ageDays: Double = 1,
                         archived: Bool = false, now: Date) -> TranscriptSearchSession {
        TranscriptSearchSession(id: id, title: title, directory: directory, updated: now.addingTimeInterval(-ageDays * 86_400), archived: archived)
    }

    private func hit(_ session: String, _ item: String, _ text: String, role: TranscriptSearchEntry.Role = .agent, rank: Double = -1) -> TranscriptSearchRawHit {
        TranscriptSearchRawHit(sessionID: session, itemID: item, role: role, ordinal: 0, text: text, rank: rank)
    }

    @Test func titleMatchesRankAboveBodyMatches() {
        let now = Date()
        let sessions = [session("body", "Sync service work", now: now), session("title", "SQLite or Postgres", ageDays: 20, now: now)]
        let hits = [hit("body", "b1", "We picked SQLite for the clients")]
        let results = TranscriptSearchRanker.rank(query: TranscriptSearchQuery("sqlite"), hits: hits, sessions: sessions,
                                                  filter: .all, folder: nil, now: now)
        #expect(results.map(\.id) == ["title", "body"])
        #expect(results[0].title.highlights.map { substring(results[0].title.text, $0) } == ["SQLite"])
        #expect(results[1].matches.map(\.itemID) == ["b1"])
    }

    @Test func moreAndBetterMatchesRankHigher() {
        let now = Date()
        let sessions = [session("one", "A", now: now), session("many", "B", now: now), session("tool", "C", now: now)]
        let hits = [
            hit("one", "o1", "the reconnect loop"),
            hit("many", "m1", "the reconnect loop"), hit("many", "m2", "reconnect again"), hit("many", "m3", "reconnect backoff"),
            hit("tool", "t1", "grep reconnecting", role: .tool),
        ]
        let results = TranscriptSearchRanker.rank(query: TranscriptSearchQuery("reconnect"), hits: hits, sessions: sessions,
                                                  filter: .all, folder: nil, now: now)
        #expect(results.map(\.id) == ["many", "one", "tool"])
        #expect(results[0].matchCount == 3)
        #expect(results[0].matches.count == 3)
    }

    @Test func newerSessionsWinTies() {
        let now = Date()
        let sessions = [session("old", "A", ageDays: 90, now: now), session("new", "B", ageDays: 0, now: now)]
        let hits = [hit("old", "o", "rate limiter"), hit("new", "n", "rate limiter")]
        let results = TranscriptSearchRanker.rank(query: TranscriptSearchQuery("limiter"), hits: hits, sessions: sessions,
                                                  filter: .all, folder: nil, now: now)
        #expect(results.map(\.id) == ["new", "old"])
    }

    @Test func filtersPickFolderAndArchivedSessions() {
        let now = Date()
        let sessions = [
            session("here", "Readme here", directory: "/p/one", now: now),
            session("there", "Readme there", directory: "/p/two", now: now),
            session("gone", "Readme archived", directory: "/p/one", archived: true, now: now),
        ]
        let query = TranscriptSearchQuery("readme")
        let all = TranscriptSearchRanker.rank(query: query, hits: [], sessions: sessions, filter: .all, folder: "/p/one", now: now)
        #expect(Set(all.map(\.id)) == ["here", "there", "gone"])
        let folder = TranscriptSearchRanker.rank(query: query, hits: [], sessions: sessions, filter: .folder, folder: "/p/one", now: now)
        #expect(Set(folder.map(\.id)) == ["here", "gone"])
        let archived = TranscriptSearchRanker.rank(query: query, hits: [], sessions: sessions, filter: .archived, folder: "/p/one", now: now)
        #expect(archived.map(\.id) == ["gone"])
    }

    @Test func partialTitleMatchWithoutMessagesIsNotAResult() {
        let now = Date()
        let sessions = [session("s", "SQLite notes", now: now)]
        let results = TranscriptSearchRanker.rank(query: TranscriptSearchQuery("sqlite postgres"), hits: [], sessions: sessions,
                                                  filter: .all, folder: nil, now: now)
        #expect(results.isEmpty)
    }

    @Test func emptyQueryListsNewestSessions() {
        let now = Date()
        let sessions = [session("a", "A", ageDays: 3, now: now), session("b", "B", ageDays: 1, now: now)]
        let results = TranscriptSearchRanker.rank(query: TranscriptSearchQuery(""), hits: [], sessions: sessions,
                                                  filter: .all, folder: nil, now: now)
        #expect(results.map(\.id) == ["b", "a"])
    }

    // MARK: Index

    @Test func indexFindsPrefixesAccentsAndReplacesSessions() async throws {
        let index = try TranscriptSearchIndex(fileURL: nil)
        let date = Date(timeIntervalSince1970: 1_000)
        try await index.replace(sessionID: "s1", updated: date, items: [
            .user(id: "u1", text: "Make the stream reconnect after sleep", date: date),
            .agentText(id: "a1", text: "Added a retry loop at the café", agentID: nil, streaming: false),
        ])
        try await index.replace(sessionID: "s2", updated: date, items: [
            .agentText(id: "b1", text: "Nothing about streams here, only sleep", agentID: nil, streaming: false),
        ])

        let recon = try await index.hits(for: TranscriptSearchQuery("recon"))
        #expect(recon.map(\.itemID) == ["u1"])
        let cafe = try await index.hits(for: TranscriptSearchQuery("CAFE retry"))
        #expect(cafe.map(\.itemID) == ["a1"])
        let sleep = try await index.hits(for: TranscriptSearchQuery("sleep"))
        #expect(Set(sleep.map(\.sessionID)) == ["s1", "s2"])

        let stamps = try await index.stamps()
        #expect(stamps["s1"]?.entryCount == 2)
        #expect(stamps["s1"]?.updated == date)

        try await index.replace(sessionID: "s1", updated: date.addingTimeInterval(5), items: [
            .user(id: "u2", text: "Now about the rate limiter", date: date),
        ])
        #expect(try await index.hits(for: TranscriptSearchQuery("reconnect")).isEmpty)
        #expect(try await index.hits(for: TranscriptSearchQuery("limiter")).map(\.itemID) == ["u2"])

        try await index.remove(sessionIDs: ["s2"])
        #expect(try await index.hits(for: TranscriptSearchQuery("sleep")).isEmpty)
        #expect(try await index.stamps().keys.sorted() == ["s1"])
    }

    @Test func indexFileSurvivesReopening() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("search-index.sqlite")
        do {
            let index = try TranscriptSearchIndex(fileURL: url)
            try await index.replace(sessionID: "s", updated: Date(), items: [.user(id: "u", text: "persisted words", date: Date())])
        }
        let reopened = try TranscriptSearchIndex(fileURL: url)
        #expect(try await reopened.hits(for: TranscriptSearchQuery("persisted")).map(\.itemID) == ["u"])
    }

    @Test func rankedSearchThroughTheIndex() async throws {
        let index = try TranscriptSearchIndex(fileURL: nil)
        let now = Date()
        try await index.replace(sessionID: "debate", updated: now, items: [
            .agentText(id: "d1", text: "Decision: SQLite on clients, Postgres on the server.", agentID: nil, streaming: false),
        ])
        try await index.replace(sessionID: "readme", updated: now, items: [
            .agentText(id: "r1", text: "The README now covers how to build it.", agentID: nil, streaming: false),
        ])
        let sessions = [
            TranscriptSearchSession(id: "debate", title: "Database choice", directory: "/p", updated: now, archived: false),
            TranscriptSearchSession(id: "readme", title: "Write the README", directory: "/p", updated: now, archived: false),
        ]
        let results = await index.search(TranscriptSearchQuery("postgres server"), sessions: sessions, filter: .all, folder: nil)
        #expect(results.map(\.id) == ["debate"])
        let match = try #require(results.first?.matches.first)
        #expect(match.itemID == "d1")
        #expect(match.snippet.highlights.map { substring(match.snippet.text, $0) } == ["Postgres", "server"])
    }

    // MARK: Fuzzy commands

    @Test func fuzzyMatchingForThePalette() {
        let titles = ["New session", "Search transcripts", "Transcript view: Verbose", "Show sidebar", "Zoom in"]
        func best(_ query: String) -> String? {
            titles.compactMap { title in FuzzyMatch.match(query, title: title).map { (title, $0.score) } }
                .max { $0.1 < $1.1 }?.0
        }
        #expect(best("nse") == "New session")
        #expect(best("tvv") == "Transcript view: Verbose")
        #expect(best("zoom") == "Zoom in")
        #expect(best("side") == "Show sidebar")
        #expect(FuzzyMatch.match("xyz", title: "New session") == nil)
        #expect(FuzzyMatch.match("abc", title: "abd abc")?.positions == [4, 5, 6])
        #expect(FuzzyMatch.match("iphone", title: "Pair device", keywords: ["iPhone", "remote"]) != nil)
        #expect(FuzzyMatch.match("", title: "Anything")?.score == 0)
        // A title match beats a keyword match, however good.
        let keyword = FuzzyMatch.match("view", title: "Hide sidebar", keywords: ["View"])
        let title = FuzzyMatch.match("view", title: "Transcript view: Verbose")
        #expect((title?.score ?? 0) > (keyword?.score ?? 0))
    }

    private func substring(_ text: String, _ range: Range<Int>) -> String {
        let chars = Array(text)
        guard range.lowerBound >= 0, range.upperBound <= chars.count else { return "<out of range>" }
        return String(chars[range])
    }
}

/// The indexer against a store on the preview engine.
@MainActor
@Suite struct TranscriptSearchIndexerTests {
    @Test func indexesOpenSessionsFromMemoryAndLoadsTheRest() async throws {
        let engine = PreviewEngine(seed: PreviewData.seed(), delayScale: 0)
        let store = SessionStore(engine: engine)
        await store.start()
        let loaded = LoadLog()
        let openBefore = Set(store.sessions.filter(\.transcriptLoaded).map(\.id))
        let indexer = TranscriptSearchIndexer(store: store, index: try TranscriptSearchIndex(fileURL: nil)) { id in
            await loaded.add(id)
            return try? await engine.transcript(id)
        }
        await indexer.pass()

        let topLevel = store.sessions.filter { $0.info.parentID == nil }
        #expect(indexer.indexedCount == topLevel.count)
        #expect(indexer.pendingCount == 0)
        // Open sessions came from memory; only the others went through the engine.
        let fromEngine = Set(await loaded.ids)
        #expect(fromEngine.isDisjoint(with: openBefore))
        #expect(fromEngine.isSubset(of: Set(topLevel.map(\.id))))
        #expect(fromEngine.count >= topLevel.count - openBefore.count - 1)

        let results = await indexer.search("postgres server", filter: .all, folder: nil)
        #expect(results.first?.id == "ses_db_debate")
        #expect(results.first?.matches.first?.itemID == "ba3")

        let titles = await indexer.search("astro", filter: .all, folder: nil)
        #expect(titles.first?.id == "ses_astro")

        // A second pass reads nothing again.
        let before = await loaded.ids.count
        await indexer.pass()
        #expect(await loaded.ids.count == before)
    }

    @Test func newMessagesInAnOpenSessionAreIndexed() async throws {
        let store = SessionStore(engine: PreviewEngine(seed: PreviewData.seed(), delayScale: 0))
        store.seed(PreviewData.seed())
        let indexer = TranscriptSearchIndexer(store: store, index: try TranscriptSearchIndex(fileURL: nil)) { _ in nil }
        await indexer.pass()
        #expect(await indexer.search("zebracorn", filter: .all, folder: nil).isEmpty)

        store.apply(.textEnded(sessionID: "ses_readme", itemID: "new", text: "The zebracorn section is done."))
        await indexer.pass()
        let results = await indexer.search("zebracorn", filter: .all, folder: nil)
        #expect(results.map(\.id) == ["ses_readme"])
        #expect(results.first?.matches.first?.itemID == "new")
    }

    @Test func removedSessionsLeaveTheIndex() async throws {
        let store = SessionStore(engine: PreviewEngine(seed: PreviewData.seed(), delayScale: 0))
        store.seed(PreviewData.seed())
        let index = try TranscriptSearchIndex(fileURL: nil)
        let indexer = TranscriptSearchIndexer(store: store, index: index) { _ in nil }
        await indexer.pass()
        #expect(try await index.stamps()["ses_astro"] != nil)
        store.apply(.sessionDeleted(sessionID: "ses_astro"))
        await indexer.pass()
        #expect(try await index.stamps()["ses_astro"] == nil)
        #expect(await indexer.search("astro", filter: .all, folder: nil).isEmpty)
    }
}

private actor LoadLog {
    var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}
