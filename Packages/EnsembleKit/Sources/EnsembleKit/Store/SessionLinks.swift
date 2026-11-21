import Foundation
import Observation

/// One session started from another inside Ensemble (an agent's proposed session, or a fork).
public struct SessionLinkRecord: Codable, Hashable, Sendable {
    public var childID: String
    public var parentID: String
    public var created: Date?

    public init(childID: String, parentID: String, created: Date? = Date()) {
        self.childID = childID
        self.parentID = parentID
        self.created = created
    }

    private enum CodingKeys: String, CodingKey { case childID, parentID, created }

    /// Tolerant: unknown keys are ignored, a missing date is fine, a missing id fails only this record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        childID = try c.decode(String.self, forKey: .childID)
        parentID = try c.decode(String.self, forKey: .parentID)
        created = try? c.decodeIfPresent(Date.self, forKey: .created)
    }
}

/// Which session started which, for nesting sessions in the sidebar. Two sources: links Ensemble recorded itself
/// (saved in `~/Library/Application Support/Ensemble/session-links.json`) and links another app keeps for the engines'
/// sessions (`EngineStartedFromLinks`, read again on every session list reload, never saved). Subagents are not links:
/// they are child sessions (`EngineSession.parentID`) and stay out of the sidebar.
@Observable @MainActor
public final class SessionLinks {
    /// Child session id to parent session id, both sources merged (Ensemble's own links win).
    public private(set) var parents: [String: String] = [:]
    /// Links recorded in Ensemble, by child id.
    public private(set) var recorded: [String: SessionLinkRecord] = [:]
    /// Links read from other apps, by child id.
    public private(set) var imported: [String: String] = [:]

    @ObservationIgnored public private(set) var fileURL: URL?
    @ObservationIgnored private var loaded = false

    nonisolated public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Ensemble/session-links.json` for the app; nil for previews and test runners.
    nonisolated public static func defaultURL(isPreview: Bool, bundle: Bundle = .main) -> URL? {
        guard !isPreview, bundle.bundleURL.pathExtension == "app" else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/session-links.json")
    }

    /// Sets the file and loads the links saved in it.
    public func configure(fileURL: URL?) {
        self.fileURL = fileURL
        loaded = false
        recorded = [:]
        loadIfNeeded()
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            recorded = Self.decode(data)
        }
        rebuild()
    }

    /// Records that `childID` was started from `parentID`, and saves. A self link is ignored.
    public func record(child childID: String, parent parentID: String, at date: Date = Date()) {
        loadIfNeeded()
        guard !childID.isEmpty, !parentID.isEmpty, childID != parentID else { return }
        recorded[childID] = SessionLinkRecord(childID: childID, parentID: parentID, created: date)
        rebuild()
        save()
    }

    /// Replaces the links read from other apps.
    public func setImported(_ links: [String: String]) {
        loadIfNeeded()
        let clean = links.filter { !$0.key.isEmpty && !$0.value.isEmpty && $0.key != $0.value }
        guard clean != imported else { return }
        imported = clean
        rebuild()
    }

    /// Drops every link to or from a removed session.
    public func remove(_ sessionID: String) {
        loadIfNeeded()
        let before = recorded.count
        recorded = recorded.filter { $0.key != sessionID && $0.value.parentID != sessionID }
        imported = imported.filter { $0.key != sessionID && $0.value != sessionID }
        rebuild()
        if recorded.count != before { save() }
    }

    private func rebuild() {
        var merged = imported
        for (child, record) in recorded { merged[child] = record.parentID }
        if merged != parents { parents = merged }
    }

    private func save() {
        guard let fileURL else { return }
        guard let data = Self.encode(recorded) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: File format

    private struct File: Codable {
        var links: [SessionLinkRecord]

        init(links: [SessionLinkRecord]) { self.links = links }

        private enum CodingKeys: String, CodingKey { case links }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let items = (try? c.decodeIfPresent([Lenient].self, forKey: .links)) ?? []
            links = items.compactMap(\.record)
        }
    }

    /// One list item; a broken item is skipped instead of failing the whole file.
    private struct Lenient: Decodable {
        var record: SessionLinkRecord?
        init(from decoder: Decoder) throws { record = try? SessionLinkRecord(from: decoder) }
    }

    nonisolated static func decode(_ data: Data) -> [String: SessionLinkRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return [:] }
        var result: [String: SessionLinkRecord] = [:]
        for link in file.links where !link.childID.isEmpty && !link.parentID.isEmpty && link.childID != link.parentID {
            result[link.childID] = link
        }
        return result
    }

    nonisolated static func encode(_ links: [String: SessionLinkRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(File(links: links.values.sorted { $0.childID < $1.childID }))
    }
}
