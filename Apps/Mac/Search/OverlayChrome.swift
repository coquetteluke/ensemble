import SwiftUI
import AppKit
import EnsembleKit

/// Puts the search, palette and shortcut overlays, file link handling and search scrolling on the window.
/// Applied once to the main window's content: `.searchLayer(search, store: store, window: window)`.
struct SearchLayer: ViewModifier {
    let search: SearchCenter
    let store: SessionStore
    let window: WindowState
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        content
            .environment(\.transcriptFocus, search.transcriptFocus)
            .environment(\.fileLinkActions, search.fileLinkActions)
            .overlay { SearchOverlayHost(search: search, store: store, window: window) }
            .task { if !isSnapshot { search.attach(store) } }
    }
}

extension View {
    func searchLayer(_ search: SearchCenter, store: SessionStore, window: WindowState) -> some View {
        modifier(SearchLayer(search: search, store: store, window: window))
    }
}

/// Shows whichever overlay is open over a dimmed window. A click outside closes it.
struct SearchOverlayHost: View {
    let search: SearchCenter
    let store: SessionStore
    let window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        if let overlay = search.overlay {
            ZStack(alignment: .top) {
                Color.black.opacity(theme.isDark ? 0.38 : 0.16)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                Group {
                    switch overlay {
                    case .search: SearchPanel(search: search, store: store, window: window)
                    case .palette: CommandPalettePanel(search: search, store: store, window: window)
                    case .shortcuts: ShortcutOverlayPanel(search: search)
                    }
                }
                .padding(.top, theme.z(overlay == .shortcuts ? 64 : 92))
                .padding(.horizontal, theme.z(24))
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .background(OverlayKeyMonitor(search: search, window: window, store: store))
        }
    }

    private func close() {
        search.close()
        window.composerFocusToken &+= 1
    }
}

/// Arrow keys, Return, Tab and Esc for the open overlay, taken before the text field sees them.
private struct OverlayKeyMonitor: View {
    let search: SearchCenter
    let window: WindowState
    let store: SessionStore
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .onAppear { if !isSnapshot { install() } }
            .onDisappear { remove() }
    }

    private func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event) }
            return handled ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let overlay = search.overlay else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53: // Esc
            search.close()
            window.composerFocusToken &+= 1
            return true
        case 126 where modifiers.isEmpty: // Up
            move(-1, overlay)
            return true
        case 125 where modifiers.isEmpty: // Down
            move(1, overlay)
            return true
        case 36, 76: // Return, Enter
            guard modifiers.isEmpty else { return false }
            switch overlay {
            case .search: search.openSelected(window: window)
            case .palette: runPaletteSelection()
            case .shortcuts: search.close()
            }
            return true
        case 48 where overlay == .search && modifiers.isEmpty: // Tab
            search.nextFilter()
            return true
        default:
            return false
        }
    }

    private func move(_ delta: Int, _ overlay: SearchCenter.Overlay) {
        switch overlay {
        case .search: search.moveSelection(delta)
        case .palette:
            let count = CommandPalettePanel.visibleCommands(search: search, context: context).count
            guard count > 0 else { return }
            search.paletteSelection = min(max(0, search.paletteSelection + delta), count - 1)
        case .shortcuts: break
        }
    }

    private var context: CommandContext {
        CommandContext(store: store, window: window, search: search, openWindow: openWindow, openSettings: openSettings)
    }

    private func runPaletteSelection() {
        let commands = CommandPalettePanel.visibleCommands(search: search, context: context)
        guard commands.indices.contains(search.paletteSelection) else { return }
        let command = commands[search.paletteSelection].command
        search.close()
        command.run()
    }
}

// MARK: - Shared pieces

/// The floating card the overlays sit in.
struct OverlayCard<Content: View>: View {
    var width: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .frame(width: theme.z(width))
            .clipShape(RoundedRectangle(cornerRadius: theme.z(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.z(14), style: .continuous).strokeBorder(theme.border))
            .background(
                // The shadow belongs to the card's shape only, not to the text inside it.
                RoundedRectangle(cornerRadius: theme.z(14), style: .continuous)
                    .fill(theme.popover)
                    .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: theme.z(28), y: theme.z(12))
            )
    }
}

/// The text field at the top of the search overlay and the palette.
struct OverlayField: View {
    let symbol: String
    let placeholder: String
    @Binding var text: String
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: theme.z(10)) {
            Image(systemName: symbol)
                .font(theme.font(size: 15))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(18))
            Group {
                if isSnapshot {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? theme.textTertiary : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onAppear { focused = true }
                }
            }
            .font(theme.font(size: 15.5))
            KeyCaps(["esc"])
        }
        .padding(.horizontal, theme.z(16))
        .frame(height: theme.z(50))
    }
}

/// Key caps such as Command-K, drawn as small rounded keys.
struct KeyCaps: View {
    let caps: [String]
    var prominent = false
    @Environment(\.theme) private var theme

    init(_ caps: [String], prominent: Bool = false) {
        self.caps = caps
        self.prominent = prominent
    }

    var body: some View {
        HStack(spacing: theme.z(3)) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(prominent ? theme.textPrimary : theme.textSecondary)
                    .padding(.horizontal, theme.z(cap.count > 1 ? 5 : 0))
                    .frame(minWidth: theme.z(19), minHeight: theme.z(19))
                    .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).strokeBorder(theme.border.opacity(0.8)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caps.joined(separator: " "))
    }
}

/// Text with some character ranges emphasised (search matches, fuzzy letters).
enum HighlightedText {
    static func attributed(_ text: String, highlights: [Range<Int>], base: Color, emphasis: Color, background: Color?,
                           font: Font, emphasisFont: Font) -> AttributedString {
        let chars = Array(text)
        var result = AttributedString()
        var index = 0
        let sorted = highlights.filter { $0.lowerBound >= 0 && $0.upperBound <= chars.count }.sorted { $0.lowerBound < $1.lowerBound }
        func append(_ range: Range<Int>, highlighted: Bool) {
            guard !range.isEmpty else { return }
            var piece = AttributedString(String(chars[range]))
            piece.foregroundColor = highlighted ? emphasis : base
            piece.font = highlighted ? emphasisFont : font
            if highlighted, let background { piece.backgroundColor = background }
            result.append(piece)
        }
        for range in sorted where range.lowerBound >= index {
            append(index..<range.lowerBound, highlighted: false)
            append(range, highlighted: true)
            index = range.upperBound
        }
        append(index..<chars.count, highlighted: false)
        return result
    }
}
