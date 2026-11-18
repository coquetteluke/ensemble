import SwiftUI
import AppKit
import EnsembleKit

/// Two to four sessions side by side in the centre of the window, each with its own header, transcript, composer and
/// status line. Dividers drag to resize (double-click to make the panes equal); a click anywhere in a pane focuses it.
struct SplitSessionsView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var dragStart: [Double]?

    var body: some View {
        let layout = window.split
        GeometryReader { proxy in
            let widths = paneWidths(layout, total: proxy.size.width)
            HStack(spacing: 0) {
                ForEach(Array(layout.panes.enumerated()), id: \.element.id) { index, pane in
                    if index > 0 {
                        divider(index - 1, layout: layout, total: proxy.size.width)
                    }
                    SplitPaneView(store: store, window: window, pane: pane, width: widths[index],
                                  isFirst: index == 0, isLast: index == layout.panes.count - 1,
                                  focused: layout.focusedID == pane.id, showsFocus: layout.panes.count > 1)
                        .frame(width: widths[index])
                        // A pane narrower than its composer's row clips it instead of drawing over its neighbours.
                        .clipped()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background {
                if !isSnapshot {
                    // Clicks in a composer's text view never reach SwiftUI gestures, so pane focus follows the mouse here.
                    MouseDownMonitor { point in
                        guard let index = paneIndex(at: point.x, widths: widths), layout.panes.indices.contains(index) else { return }
                        window.focusPane(layout.panes[index].id, store: store)
                    }
                }
            }
        }
        .background(theme.background)
        .background { splitShortcuts }
    }

    /// Pane widths from the layout's shares, after the 1 pt dividers.
    private func paneWidths(_ layout: SplitLayout, total: CGFloat) -> [CGFloat] {
        let usable = max(0, total - CGFloat(max(0, layout.panes.count - 1)))
        return layout.fractions.map { (usable * $0).rounded(.down) }
    }

    private func paneIndex(at x: CGFloat, widths: [CGFloat]) -> Int? {
        var edge: CGFloat = 0
        for (index, width) in widths.enumerated() {
            edge += width + (index > 0 ? 1 : 0)
            if x < edge { return index }
        }
        return nil
    }

    private func divider(_ index: Int, layout: SplitLayout, total: CGFloat) -> some View {
        let usable = max(1, total - CGFloat(layout.panes.count - 1))
        let minFraction = Double(theme.z(SplitLayout.minPaneWidth) / usable)
        return VLine()
            .overlay {
                Color.clear
                    .frame(width: theme.z(9))
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? layout.fractions
                                if dragStart == nil { dragStart = start }
                                window.resizeSplit(divider: index, from: start, by: Double(value.translation.width / usable),
                                                   minFraction: minFraction, save: false)
                            }
                            .onEnded { value in
                                let start = dragStart ?? layout.fractions
                                window.resizeSplit(divider: index, from: start, by: Double(value.translation.width / usable),
                                                   minFraction: minFraction, save: true)
                                dragStart = nil
                            }
                    )
                    .onTapGesture(count: 2) { window.equalizePanes() }
                    .help("Drag to resize. Double-click to make the panes equal.")
            }
            .zIndex(1)
    }

    /// Control-Command-W closes the focused pane; Option-Command-Left and Right move between panes.
    private var splitShortcuts: some View {
        ZStack {
            Button("Close pane") {
                if let focused = window.split.focusedID { window.closePane(focused, store: store) }
            }
            .keyboardShortcut("w", modifiers: [.command, .control])
            Button("Next pane") { window.focusNeighbourPane(1, store: store) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous pane") { window.focusNeighbourPane(-1, store: store) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// One pane: a header in the title bar strip (title, folder, status, close), then the session's conversation with the
/// pane's own window state, so its composer keeps its own focus, menus and draft.
struct SplitPaneView: View {
    let store: SessionStore
    let window: WindowState
    let pane: SplitLayout.Pane
    /// The pane's width: the header and the conversation are laid out to it, so a conversation wider than the pane
    /// (a composer row that cannot shrink further) never pushes the header out of place.
    let width: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let focused: Bool
    let showsFocus: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.zoom) private var zoom

    /// How wide the composer's row is at 100% (measured: `Split pane check` in the snapshot run), with the model's
    /// effort and fast mode chips and without. Lower these once the composer's row adapts to narrow widths.
    static let composerWidth: CGFloat = 530
    static let plainComposerWidth: CGFloat = 430

    /// The composer shrinks at most to this share of the window's zoom; a pane narrower than that clips its edges.
    static let smallestComposerScale: CGFloat = 0.8

    /// A smaller zoom for the composer when the pane is narrower than its row (at most 20% smaller, so it still matches
    /// the rest of the window); nil when it fits.
    static func composerZoom(width: CGFloat, zoom: CGFloat, store: SessionStore, session: SessionModel) -> CGFloat? {
        let options = store.options(for: session.info.model)
        let chips = !(options?.effortLevels.isEmpty ?? true) || options?.supportsFastMode == true
        let needed = (chips ? composerWidth : plainComposerWidth) * zoom
        guard width < needed else { return nil }
        return max(zoom * smallestComposerScale, CGFloat(Zoom.steps.first ?? 0.7), zoom * width / needed)
    }

    var body: some View {
        let paneWindow = window.paneState(pane.id)
        VStack(spacing: 0) {
            header
                .frame(width: width)
            if let session = store.session(pane.sessionID) {
                ConversationView(store: store, session: session, window: paneWindow,
                                 composerZoom: Self.composerZoom(width: width, zoom: zoom, store: store, session: session))
                    .frame(width: width)
                    .environment(\.transcriptActions,
                                 MainView.transcriptActions(store: store, session: session, window: window,
                                                            paneWindow: paneWindow, ownsShortcuts: focused))
                    .task(id: session.id) {
                        guard !isSnapshot, !session.transcriptLoaded else { return }
                        await store.loadSession(session.id)
                    }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.background)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { window.focusPane(pane.id, store: store) })
        .clipped()
    }

    private var header: some View {
        let session = store.session(pane.sessionID)
        return HStack(spacing: theme.z(8)) {
            if isFirst && !window.showSidebar {
                // The traffic lights and the sidebar button sit here.
                Color.clear.frame(width: 110, height: 1)
            }
            if let session {
                SplitPaneStatus(store: store, session: session)
                // The folder shows only when it fits whole next to the whole title; otherwise the title alone.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: theme.z(8)) {
                        title(session)
                        Text(Format.folderName(session.directory))
                            .font(theme.font(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    title(session)
                }
                .help(Format.abbreviatedPath(session.directory))
            } else {
                Text("Session not available")
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: theme.z(8))
            IconButton("xmark", help: "Close pane (Control-Command-W)", size: 24) {
                window.closePane(pane.id, store: store)
            }
            if isLast && !window.showContextPanel {
                // The window's toolbar buttons sit here when no pane is open on the right.
                Color.clear.frame(width: MainView.toolbarButtonsWidth - theme.z(10), height: 1)
            }
        }
        .padding(.leading, theme.z(16))
        .padding(.trailing, theme.z(10))
        .frame(height: 52)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            // The focused pane carries an accent line under its title.
            if showsFocus && focused {
                Rectangle().fill(theme.accent).frame(height: theme.z(2))
            } else {
                HLine()
            }
        }
        .zIndex(1)
    }

    private func title(_ session: SessionModel) -> some View {
        Text(session.title)
            .font(theme.font(size: 13, weight: .semibold))
            .foregroundStyle(focused || !showsFocus ? theme.textPrimary : theme.textSecondary)
            .lineLimit(1)
    }
}

/// The session's state in its pane header: needs-you count, working spinner or a failed dot.
private struct SplitPaneStatus: View {
    let store: SessionStore
    let session: SessionModel
    @Environment(\.theme) private var theme

    var body: some View {
        let prompts = store.needsYouCount(session.id)
        if prompts > 0 {
            CountBadge(prompts)
        } else if store.isRunning(session.id) {
            Spinner(size: 11)
        } else if session.activity == .failed {
            StatusDot(theme.danger, size: 7)
        }
    }
}

/// Reports left mouse-downs inside this view (in its own top-left coordinates) before the window delivers them, so a
/// click in a pane's text view still focuses the pane.
private struct MouseDownMonitor: NSViewRepresentable {
    let onMouseDown: (CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var onMouseDown: ((CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        // Never takes clicks itself.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point) { self.onMouseDown?(point) }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
