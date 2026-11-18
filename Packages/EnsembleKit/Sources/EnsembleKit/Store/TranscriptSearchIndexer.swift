import Foundation
import Observation

/// Keeps `TranscriptSearchIndex` current with the store, in the background:
/// - sessions open in the app are indexed from the transcript already in memory, a moment after they change;
/// - other sessions are loaded through the engine one at a time, newest first, only when their `updated` date
///   differs from what the index holds (so later launches only read what changed);
/// - sessions that disappear from the store are dropped from the index.
@Observable @MainActor
public final class TranscriptSearchIndexer {
    /// Loads a session's transcript in the background; nil skips it (it is indexed once it is opened instead).
    public typealias Loader = @Sendable (String) async -> [TranscriptItem]?

    /// Top-level sessions the index holds up to date.
    public private(set) var indexedCount = 0
    /// Top-level sessions still waiting to be read.
    public private(set) var pendingCount = 0
    public private(set) var isIndexing = false
    /// Bumped after each change to the index, so an open search can run again.
    public private(set) var generation = 0

    public let store: SessionStore
    public let index: TranscriptSearchIndex
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var stamps: [String: TranscriptSearchIndex.Stamp]?
    /// Store revision of each open session when it was last indexed, and when.
    @ObservationIgnored private var indexedRevision: [String: Int] = [:]
    @ObservationIgnored private var lastLiveIndex: [String: Date] = [:]
    /// Sessions the loader declined this launch; tried again when they are opened.
    @ObservationIgnored private var skipped: Set<String> = []
    /// Wait between passes, and between indexing a session whose agent is still writing.
    @ObservationIgnored var passInterval: Duration = .seconds(4)
    @ObservationIgnored var workingInterval: TimeInterval = 20

    public init(store: SessionStore, index: TranscriptSearchIndex, loader: @escaping Loader) {
        self.store = store
        self.index = index
        self.loader = loader
    }

    /// The usual setup: the file in Application Support (in memory for the preview engine), loading
    /// transcripts through the store's engine.
    public static func makeDefault(store: SessionStore) -> TranscriptSearchIndexer? {
        let fileURL: URL? = store.isPreview ? nil : TranscriptSearchIndex.defaultFileURL
        let index = (try? TranscriptSearchIndex(fileURL: fileURL)) ?? (try? TranscriptSearchIndex(fileURL: nil))
        guard let index else { return nil }
        return TranscriptSearchIndexer(store: store, index: index, loader: defaultLoader(for: store.engine))
    }

    /// Loads through the engine, except sessions of engines that would have to start an agent process to rebuild
    /// history (ACP agents); those are indexed once opened.
    public static func defaultLoader(for engine: any OpenCodeAPI) -> Loader {
        { sessionID in
            if let router = engine as? EngineRouter {
                guard let registration = await router.registration(forSession: sessionID) else { return nil }
                if registration.engine is ACPEngine { return nil }
            } else if engine is ACPEngine {
                return nil
            }
            return try? await engine.transcript(sessionID)
        }
    }

    // MARK: Running

    /// Starts indexing after `delay` (a search opened meanwhile starts it at once).
    public func start(after delay: Duration = .zero) {
        guard loop == nil else { return }
        loop = Task(priority: .utility) { [weak self] in
            if delay > .zero { await self?.sleep(delay) }
            while !Task.isCancelled {
                guard let self else { return }
                await self.pass()
                await self.sleep(self.passInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        resume()
    }

    /// Runs the next pass now (a search was opened or typed into).
    public func refreshSoon() {
        if loop == nil { start() } else { resume() }
    }

    private func resume() {
        let continuation = wake
        wake = nil
        continuation?.resume()
    }

    private func sleep(_ duration: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.resume()
        }
        await withCheckedContinuation { continuation in
            if let pending = wake { pending.resume() }
            wake = continuation
        }
        timer.cancel()
    }

    // MARK: Searching

    /// Searches the index and ranks the sessions the store knows now.
    public func search(_ text: String, filter: TranscriptSearchFilter, folder: String?) async -> [TranscriptSearchResult] {
        let sessions = searchableSessions().map {
            TranscriptSearchSession(id: $0.id, title: $0.title, directory: $0.directory, updated: $0.info.updated, archived: $0.info.archived)
        }
        return await index.search(TranscriptSearchQuery(text), sessions: sessions, filter: filter, folder: folder)
    }

    /// Top-level sessions (subagents are reached through the session that started them).
    private func searchableSessions() -> [SessionModel] {
        store.sessions.filter { $0.info.parentID == nil }
    }

    // MARK: Passes

    /// One round: index open sessions that changed, read stale ones, drop removed ones. Tests call it directly.
    public func pass() async {
        guard store.isLoaded else { return }
        isIndexing = true
        defer { isIndexing = false }
        if stamps == nil { stamps = (try? await index.stamps()) ?? [:] }

        let sessions = searchableSessions()
        let ids = Set(sessions.map(\.id))
        let gone = Array((stamps ?? [:]).keys.filter { !ids.contains($0) })
        if !gone.isEmpty {
            try? await index.remove(sessionIDs: gone)
            for id in gone { stamps?[id] = nil }
            generation &+= 1
        }

        // Open sessions first: their transcript is already in memory.
        for session in sessions where session.transcriptLoaded {
            guard needsLiveIndex(session) else { continue }
            await save(session.id, updated: session.info.updated, items: session.items)
            indexedRevision[session.id] = session.revision
            lastLiveIndex[session.id] = Date()
            skipped.remove(session.id)
        }

        var queue = sessions.filter { !$0.transcriptLoaded && !skipped.contains($0.id) && isStale($0) }
            .sorted { $0.info.updated > $1.info.updated }
        updateCounts(sessions, pending: queue.count)
        while !queue.isEmpty, !Task.isCancelled {
            let session = queue.removeFirst()
            // It may have been opened (and indexed live) while earlier ones loaded.
            guard !session.transcriptLoaded, isStale(session) else { continue }
            let updated = session.info.updated
            if let items = await loader(session.id) {
                await save(session.id, updated: updated, items: items)
            } else {
                skipped.insert(session.id)
            }
            updateCounts(sessions, pending: queue.count)
            await Task.yield()
        }
        updateCounts(sessions, pending: 0)
    }

    private func needsLiveIndex(_ session: SessionModel) -> Bool {
        if indexedRevision[session.id] == session.revision { return false }
        // Indexed in an earlier launch and unchanged since: nothing to do.
        if indexedRevision[session.id] == nil, stamps?[session.id] != nil, !isStale(session) {
            indexedRevision[session.id] = session.revision
            return false
        }
        // While an agent is writing, index at most every `workingInterval`; at once when the turn ends.
        guard session.isWorking, stamps?[session.id] != nil, let last = lastLiveIndex[session.id] else { return true }
        return Date().timeIntervalSince(last) >= workingInterval
    }

    private func isStale(_ session: SessionModel) -> Bool {
        guard let stamp = stamps?[session.id] else { return true }
        return abs(stamp.updated.timeIntervalSince(session.info.updated)) > 0.001
    }

    private func save(_ sessionID: String, updated: Date, items: [TranscriptItem]) async {
        guard let count = try? await index.replace(sessionID: sessionID, updated: updated, items: items) else { return }
        stamps?[sessionID] = TranscriptSearchIndex.Stamp(updated: updated, entryCount: count)
        generation &+= 1
    }

    private func updateCounts(_ sessions: [SessionModel], pending: Int) {
        let stamps = stamps ?? [:]
        indexedCount = sessions.filter { stamps[$0.id] != nil }.count
        pendingCount = pending
    }
}
