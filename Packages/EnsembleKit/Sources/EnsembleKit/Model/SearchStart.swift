import Foundation

/// What the search overlay lists before anything is typed: the sessions that need you, the ones working now, and
/// the most recent of the rest. A session appears once, in the first group it fits.
public struct SearchStart: Equatable, Sendable {
    public struct Section: Identifiable, Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case needsYou, working, recent

            public var title: String {
                switch self {
                case .needsYou: "Needs you"
                case .working: "Working"
                case .recent: "Recent"
                }
            }
        }

        public var kind: Kind
        public var entries: [SidebarEntry]
        public var id: String { kind.rawValue }
        public var title: String { kind.title }

        public init(kind: Kind, entries: [SidebarEntry]) {
            self.kind = kind
            self.entries = entries
        }
    }

    public var sections: [Section]

    public init(sections: [Section] = []) {
        self.sections = sections
    }

    /// Every session row in the order shown.
    public var entries: [SidebarEntry] { sections.flatMap(\.entries) }

    /// Groups `entries` (top-level, not archived). Needs you holds open prompts and failed turns; Working holds
    /// running sessions; Recent holds the newest of the rest. Each group is newest first and capped; empty groups
    /// are left out.
    public static func build(_ entries: [SidebarEntry], groupLimit: Int = 5, recentLimit: Int = 6) -> SearchStart {
        let newestFirst = entries.sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
        var needsYou: [SidebarEntry] = []
        var working: [SidebarEntry] = []
        var rest: [SidebarEntry] = []
        for entry in newestFirst {
            switch entry.status {
            case .needsYou, .failed: needsYou.append(entry)
            case .running: working.append(entry)
            case .unread, .completed, .idle: rest.append(entry)
            }
        }
        let sections = [
            Section(kind: .needsYou, entries: Array(needsYou.prefix(groupLimit))),
            Section(kind: .working, entries: Array(working.prefix(groupLimit))),
            Section(kind: .recent, entries: Array(rest.prefix(recentLimit))),
        ]
        return SearchStart(sections: sections.filter { !$0.entries.isEmpty })
    }
}
