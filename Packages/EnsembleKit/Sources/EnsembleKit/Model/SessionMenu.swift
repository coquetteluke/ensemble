import Foundation

/// What a session's menu can do. One list for every place the menu appears (the title bar today, the sidebar row
/// and the iPhone later), so the items, their order and their keys never drift apart.
public enum SessionMenuAction: String, CaseIterable, Sendable, Identifiable {
    case openInSplit
    case pin
    case markUnread
    case markCompleted
    case rename
    case fork
    case copyMarkdown
    case revealFolder
    case archive
    case delete

    public var id: String { rawValue }
}

/// The facts the menu's titles and availability depend on.
public struct SessionMenuState: Equatable, Sendable {
    public var pinned: Bool
    public var unread: Bool
    public var completed: Bool
    public var archived: Bool
    /// The engine can copy a conversation into a new session.
    public var canFork: Bool
    /// Another session can open beside the ones on screen.
    public var canOpenBeside: Bool
    /// This session is already one of the split panes.
    public var shownInSplit: Bool
    /// A helper session started by another agent: it has no sidebar row, so nothing to pin or mark.
    public var isSubagent: Bool

    public init(pinned: Bool = false, unread: Bool = false, completed: Bool = false, archived: Bool = false,
                canFork: Bool = true, canOpenBeside: Bool = true, shownInSplit: Bool = false, isSubagent: Bool = false) {
        self.pinned = pinned
        self.unread = unread
        self.completed = completed
        self.archived = archived
        self.canFork = canFork
        self.canOpenBeside = canOpenBeside
        self.shownInSplit = shownInSplit
        self.isSubagent = isSubagent
    }
}

/// One row of the menu.
public struct SessionMenuItem: Identifiable, Equatable, Sendable {
    public let action: SessionMenuAction
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// The key that picks this row while the menu is open; nil for rows without one.
    public let key: Character?
    public let enabled: Bool
    /// Drawn in the danger colour, and asks before it acts.
    public let destructive: Bool

    public var id: String { action.rawValue }
}

public enum SessionMenu {
    /// The menu's rows in groups; a line is drawn between groups. Empty groups are left out.
    public static func sections(_ state: SessionMenuState) -> [[SessionMenuItem]] {
        var view: [SessionMenuItem] = [
            SessionMenuItem(action: .openInSplit, title: state.shownInSplit ? "Show in Split" : "Open in Split",
                            symbol: "rectangle.split.2x1", key: "o", enabled: state.canOpenBeside, destructive: false),
        ]
        if !state.isSubagent {
            view.append(SessionMenuItem(action: .pin, title: state.pinned ? "Unpin" : "Pin",
                                        symbol: state.pinned ? "pin.slash" : "pin", key: "p", enabled: true, destructive: false))
        }

        var marks: [SessionMenuItem] = []
        if !state.isSubagent {
            marks.append(SessionMenuItem(action: .markUnread, title: state.unread ? "Mark as read" : "Mark as unread",
                                         symbol: state.unread ? "circle" : "circle.fill", key: "u", enabled: true, destructive: false))
            marks.append(SessionMenuItem(action: .markCompleted,
                                         title: state.completed ? "Mark as not completed" : "Mark as completed",
                                         symbol: state.completed ? "checkmark.circle.badge.xmark" : "checkmark.circle",
                                         key: "m", enabled: true, destructive: false))
        }

        let edit: [SessionMenuItem] = [
            SessionMenuItem(action: .rename, title: "Rename", symbol: "pencil", key: "r", enabled: true, destructive: false),
            SessionMenuItem(action: .fork, title: "Fork", symbol: "arrow.triangle.branch", key: "f",
                            enabled: state.canFork, destructive: false),
            SessionMenuItem(action: .copyMarkdown, title: "Copy as Markdown", symbol: "doc.on.clipboard", key: "c",
                            enabled: true, destructive: false),
            SessionMenuItem(action: .revealFolder, title: "Reveal in Finder", symbol: "folder", key: nil,
                            enabled: true, destructive: false),
        ]

        let remove: [SessionMenuItem] = [
            SessionMenuItem(action: .archive, title: state.archived ? "Unarchive" : "Archive",
                            symbol: state.archived ? "tray.and.arrow.up" : "archivebox", key: "a", enabled: true, destructive: false),
            SessionMenuItem(action: .delete, title: "Delete", symbol: "trash", key: "d", enabled: true, destructive: true),
        ]

        return [view, marks, edit, remove].filter { !$0.isEmpty }
    }

    /// The row a key picks while the menu is open: enabled rows only, upper or lower case.
    public static func item(forKey key: Character, in state: SessionMenuState) -> SessionMenuItem? {
        let wanted = Character(key.lowercased())
        return sections(state).joined().first { $0.key == wanted && $0.enabled }
    }

    /// A title as it will be saved: one line, no space at either end, at most `maxLength` characters. Nil when
    /// nothing is left, or when it is the title the session already has (nothing to save).
    public static func cleanedTitle(_ text: String, current: String, maxLength: Int = 200) -> String? {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = String(oneLine.trimmingCharacters(in: .whitespaces).prefix(maxLength))
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }
}
