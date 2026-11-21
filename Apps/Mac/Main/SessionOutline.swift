import SwiftUI
import EnsembleKit

/// Which of your messages are pinned as chapters, per session. Saved in the app's settings; snapshots and previews
/// pass nil defaults and keep them in memory.
@Observable @MainActor
final class ChapterPins {
    static let shared = ChapterPins(defaults: AppEngine.usePreview ? nil : .standard)
    static let storageKey = "chapterPins"

    private var pins: [String: Set<String>]
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults?, pins: [String: Set<String>] = [:]) {
        self.defaults = defaults
        if let saved = defaults?.dictionary(forKey: Self.storageKey) as? [String: [String]] {
            self.pins = saved.mapValues(Set.init)
        } else {
            self.pins = pins
        }
    }

    func pinned(in sessionID: String) -> Set<String> { pins[sessionID] ?? [] }

    func toggle(_ itemID: String, in sessionID: String) {
        var set = pins[sessionID] ?? []
        if set.contains(itemID) { set.remove(itemID) } else { set.insert(itemID) }
        pins[sessionID] = set.isEmpty ? nil : set
        defaults?.set(pins.mapValues { $0.sorted() }, forKey: Self.storageKey)
    }
}

/// The title row's outline button: opens a list of the messages you sent in this session. Click one to jump to it;
/// pin the ones worth coming back to, and they become the session's chapters.
struct SessionOutlineButton: View {
    let session: SessionModel
    @Bindable var window: WindowState
    var pins: ChapterPins = .shared
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showList = false
    @State private var hovering = false

    var body: some View {
        Button {
            showList.toggle()
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(theme.font(size: 12.5))
                .foregroundStyle(showList || hovering ? theme.textPrimary : theme.textSecondary)
                .frame(width: theme.z(26), height: theme.z(24))
                .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(showList || hovering ? theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Jump to a message")
        .accessibilityLabel("Jump to a message")
        .onChange(of: window.outlineRequestToken) { if !isSnapshot { showList = true } }
        .onChange(of: session.id) { showList = false }
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            SessionOutlineList(entries: TranscriptOutline.entries(session.items, pinned: pins.pinned(in: session.id)),
                               onJump: { entry in
                                   showList = false
                                   NotificationCenter.default.post(name: .ensembleJumpToMessage, object: nil,
                                                                   userInfo: ["sessionID": session.id, "itemID": entry.id])
                               },
                               onPin: { entry in pins.toggle(entry.id, in: session.id) })
                .ensembleTheme()
        }
    }
}

/// The outline: every message you sent, numbered, with its age and how many files the turn changed. The pin on a
/// row makes it a chapter; with chapters pinned the list can show only those.
struct SessionOutlineList: View {
    let entries: [OutlineEntry]
    var now = Date()
    /// Snapshots open on the chapters filter.
    var initiallyChaptersOnly = false
    let onJump: (OutlineEntry) -> Void
    let onPin: (OutlineEntry) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var chaptersOnly: Bool?

    private var showsChaptersOnly: Bool { (chaptersOnly ?? initiallyChaptersOnly) && entries.contains(where: \.pinned) }

    var body: some View {
        let shown = TranscriptOutline.visible(entries, chaptersOnly: showsChaptersOnly)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.z(8)) {
                Text("Jump to")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("\(entries.count) \(entries.count == 1 ? "message" : "messages")")
                    .font(theme.font(size: 12).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: theme.z(8))
                if entries.contains(where: \.pinned) {
                    filterChip("All", selected: !showsChaptersOnly) { chaptersOnly = false }
                    filterChip("Chapters", selected: showsChaptersOnly) { chaptersOnly = true }
                }
            }
            .padding(.horizontal, theme.z(14))
            .frame(height: theme.z(40))
            HLine(color: theme.border)
            if entries.isEmpty {
                Text("No messages yet")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.z(26))
            } else if isSnapshot {
                rows(shown).padding(.vertical, theme.z(6))
            } else {
                ScrollView {
                    rows(shown).padding(.vertical, theme.z(6))
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: theme.z(420))
            }
        }
        .frame(width: theme.z(420), alignment: .leading)
        .background(theme.popover)
    }

    private func rows(_ shown: [OutlineEntry]) -> some View {
        VStack(alignment: .leading, spacing: theme.z(1)) {
            ForEach(shown) { entry in
                SessionOutlineRow(entry: entry, now: now, onJump: { onJump(entry) }, onPin: { onPin(entry) })
            }
        }
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.font(size: 11.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, theme.z(9))
                .frame(height: theme.z(22))
                .background(Capsule().fill(selected ? theme.raisedSelection : .clear))
                .overlay(Capsule().strokeBorder(theme.border.opacity(selected ? 1 : 0.6)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One outline row: number, the message's first line, files changed, age, and the chapter pin.
private struct SessionOutlineRow: View {
    let entry: OutlineEntry
    let now: Date
    let onJump: () -> Void
    let onPin: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(8)) {
            Text("\(entry.number)")
                .font(theme.font(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(22), alignment: .trailing)
            Text(entry.title)
                .font(theme.font(size: 13, weight: entry.pinned ? .medium : .regular))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: theme.z(8))
            if entry.filesChanged > 0 {
                Text(entry.filesChanged == 1 ? "1 file" : "\(entry.filesChanged) files")
                    .font(theme.font(size: 11).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .help("Files the agent changed in this turn")
            }
            Text(age)
                .font(theme.font(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .frame(minWidth: theme.z(30), alignment: .trailing)
            Button(action: onPin) {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .font(theme.font(size: 11))
                    .foregroundStyle(entry.pinned ? theme.accent : theme.textTertiary)
                    .frame(width: theme.z(22), height: theme.z(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(entry.pinned || hovering ? 1 : 0)
            .help(entry.pinned ? "Remove this chapter" : "Pin as a chapter")
            .accessibilityLabel(entry.pinned ? "Remove this chapter" : "Pin as a chapter")
        }
        .padding(.horizontal, theme.z(8))
        .frame(height: theme.z(32))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(hovering ? theme.raisedHover : .clear))
        .padding(.horizontal, theme.z(6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onJump)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var age: String {
        let relative = Format.relative(entry.date, now: now)
        return relative == "now" ? "now" : relative
    }
}

extension Notification.Name {
    /// Scrolls the transcript of `sessionID` to the message `itemID` (the outline's rows).
    static let ensembleJumpToMessage = Notification.Name("ensemble.jumpToMessage")
}
