import Foundation

/// The one attention state a sidebar row shows, highest priority first.
public enum SidebarRowStatus: String, CaseIterable, Sendable {
    /// An open permission prompt or question.
    case needsYou
    case running
    /// The last turn failed and the user has not marked it completed.
    case failed
    /// A turn finished while the user was not looking at it.
    case unread
    /// The user marked it completed.
    case completed
    case idle

    public static func resolve(prompts: Int, running: Bool, failed: Bool, unread: Bool, completed: Bool) -> SidebarRowStatus {
        if prompts > 0 { return .needsYou }
        if running { return .running }
        if completed { return .completed }
        if failed { return .failed }
        if unread { return .unread }
        return .idle
    }
}

/// How the sidebar groups sessions.
public enum SidebarGrouping: String, CaseIterable, Identifiable, Sendable {
    case project
    case state
    case date

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .project: "Project"
        case .state: "State"
        case .date: "Date"
        }
    }
}

/// How sessions are ordered inside each group.
public enum SidebarSort: String, CaseIterable, Identifiable, Sendable {
    case recent
    case name
    case created

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .recent: "Recent activity"
        case .name: "Name"
        case .created: "Created"
        }
    }
}

/// Groups for "group by state", in the order shown.
public enum SidebarStateGroup: String, CaseIterable, Sendable {
    case needsYou
    case running
    case unread
    case idle
    case completed

    public var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .running: "Running"
        case .unread: "Unread"
        case .idle: "Idle"
        case .completed: "Completed"
        }
    }

    public init(_ status: SidebarRowStatus) {
        switch status {
        case .needsYou, .failed: self = .needsYou
        case .running: self = .running
        case .unread: self = .unread
        case .completed: self = .completed
        case .idle: self = .idle
        }
    }
}

/// Groups for "group by date" (last activity), in the order shown.
public enum SidebarDateGroup: String, CaseIterable, Sendable {
    case today
    case yesterday
    case week
    case month
    case older

    public var label: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "Previous 7 days"
        case .month: "Previous 30 days"
        case .older: "Older"
        }
    }

    public init(_ date: Date, now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: self = .today
        case 1: self = .yesterday
        case 2...7: self = .week
        case 8...30: self = .month
        default: self = .older
        }
    }
}

/// One session as the sidebar arranges it.
public struct SidebarEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var directory: String
    public var created: Date
    public var updated: Date
    public var status: SidebarRowStatus
    public var pinned: Bool

    public init(id: String, title: String, directory: String, created: Date, updated: Date,
                status: SidebarRowStatus = .idle, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.directory = directory
        self.created = created
        self.updated = updated
        self.status = status
        self.pinned = pinned
    }

    /// True if the title or the folder name contains `query` (case and accents ignored).
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query) || Format.folderName(directory).localizedCaseInsensitiveContains(query)
    }
}

/// A titled run of sessions in the sidebar.
public struct SidebarGroup: Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case project(directory: String)
        case state(SidebarStateGroup)
        case date(SidebarDateGroup)
    }

    public var kind: Kind
    public var title: String
    public var entries: [SidebarEntry]

    /// Stable across launches: also the key for collapsed groups.
    public var id: String {
        switch kind {
        case .project(let directory): directory
        case .state(let group): "state:" + group.rawValue
        case .date(let group): "date:" + group.rawValue
        }
    }
}

/// The sidebar's sessions: pinned ones first, then the rest grouped and sorted.
public struct SidebarArrangement: Sendable {
    public var pinned: [SidebarEntry]
    public var groups: [SidebarGroup]

    /// Every session in the order the sidebar shows them (Command-1 to 9).
    public var order: [SidebarEntry] { pinned + groups.flatMap(\.entries) }
    public var isEmpty: Bool { pinned.isEmpty && groups.isEmpty }

    public init(pinned: [SidebarEntry] = [], groups: [SidebarGroup] = []) {
        self.pinned = pinned
        self.groups = groups
    }

    public static func arrange(_ entries: [SidebarEntry], grouping: SidebarGrouping, sort: SidebarSort,
                               now: Date = Date(), calendar: Calendar = .current) -> SidebarArrangement {
        let pinned = sorted(entries.filter(\.pinned), by: sort)
        let rest = entries.filter { !$0.pinned }
        let groups: [SidebarGroup]
        switch grouping {
        case .project:
            groups = Dictionary(grouping: rest, by: \.directory)
                .map { directory, list in
                    SidebarGroup(kind: .project(directory: directory), title: Format.folderName(directory), entries: sorted(list, by: sort))
                }
                .sorted { projectOrder($0, $1, by: sort) }
        case .state:
            let byState = Dictionary(grouping: rest) { SidebarStateGroup($0.status) }
            groups = SidebarStateGroup.allCases.compactMap { group in
                guard let list = byState[group], !list.isEmpty else { return nil }
                return SidebarGroup(kind: .state(group), title: group.label, entries: sorted(list, by: sort))
            }
        case .date:
            let byDate = Dictionary(grouping: rest) { SidebarDateGroup($0.updated, now: now, calendar: calendar) }
            groups = SidebarDateGroup.allCases.compactMap { group in
                guard let list = byDate[group], !list.isEmpty else { return nil }
                return SidebarGroup(kind: .date(group), title: group.label, entries: sorted(list, by: sort))
            }
        }
        return SidebarArrangement(pinned: pinned, groups: groups)
    }

    public static func sorted(_ entries: [SidebarEntry], by sort: SidebarSort) -> [SidebarEntry] {
        entries.sorted { a, b in
            switch sort {
            case .recent:
                if a.updated != b.updated { return a.updated > b.updated }
            case .created:
                if a.created != b.created { return a.created > b.created }
            case .name:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.id < b.id
        }
    }

    /// Projects: most recent activity, name, or newest session first.
    private static func projectOrder(_ a: SidebarGroup, _ b: SidebarGroup, by sort: SidebarSort) -> Bool {
        switch sort {
        case .recent:
            let x = a.entries.map(\.updated).max() ?? .distantPast
            let y = b.entries.map(\.updated).max() ?? .distantPast
            if x != y { return x > y }
        case .created:
            let x = a.entries.map(\.created).max() ?? .distantPast
            let y = b.entries.map(\.created).max() ?? .distantPast
            if x != y { return x > y }
        case .name:
            let order = a.title.localizedStandardCompare(b.title)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return a.id < b.id
    }
}
