import SwiftUI
import EnsembleKit

/// The side panel's tab strip, in the band above the pane (left of the window's toolbar buttons): one tab per pane
/// opened in this window, a "+" that opens another, and a button that lets the panel fill the window. Tabs stay
/// open while another one is in front, so Changes, Browser and Terminal can be flipped through without losing place.
struct SidePaneTabStrip: View {
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let tabs = window.paneTabs.tabs
        let front = window.sidePane.kind
        HStack(spacing: theme.z(4)) {
            // As much of each tab as fits: every title, then only the front tab's, then symbols alone.
            ViewThatFits(in: .horizontal) {
                chips(tabs, front: front, titles: .all)
                chips(tabs, front: front, titles: .frontOnly)
                chips(tabs, front: front, titles: .none)
            }
            addMenu(open: tabs)
            IconButton(window.sidePaneMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: window.sidePaneMaximized ? "Put the panel back beside the conversation" : "Fill the window with this panel",
                       size: 24, active: window.sidePaneMaximized) {
                window.toggleSidePaneMaximized()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, theme.z(10))
        .frame(height: 52)
    }

    enum Titles { case all, frontOnly, none }

    private func chips(_ tabs: [SidePane.Kind], front: SidePane.Kind?, titles: Titles) -> some View {
        HStack(spacing: theme.z(4)) {
            ForEach(tabs, id: \.self) { kind in
                SidePaneTabChip(kind: kind, isFront: kind == front,
                                showsTitle: titles == .all || (titles == .frontOnly && kind == front),
                                select: { window.selectPaneTab(kind) },
                                close: { window.closePaneTab(kind) })
            }
        }
    }

    /// Panes that are not open yet.
    @ViewBuilder private func addMenu(open: [SidePane.Kind]) -> some View {
        let closed: [SidePane.Kind] = [.review, .file, .browser, .terminal].filter { !open.contains($0) }
        if !closed.isEmpty {
            if isSnapshot {
                addLabel
            } else {
                Menu {
                    ForEach(closed, id: \.self) { kind in
                        Button {
                            window.openSidePane(Self.pane(kind))
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    addLabel
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open another pane")
                .accessibilityLabel("Open another pane")
            }
        }
    }

    private var addLabel: some View {
        Image(systemName: "plus")
            .font(theme.font(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .frame(width: theme.z(24), height: theme.z(24))
            .contentShape(Rectangle())
    }

    private static func pane(_ kind: SidePane.Kind) -> SidePane {
        switch kind {
        case .review: .review
        case .browser: .browser
        case .terminal: .terminal
        case .file: .files
        }
    }
}

/// One tab: symbol and title; the front tab is filled and carries its close button, the others close on hover.
private struct SidePaneTabChip: View {
    let kind: SidePane.Kind
    let isFront: Bool
    let showsTitle: Bool
    let select: () -> Void
    let close: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(5)) {
            Image(systemName: kind.symbol)
                .font(theme.font(size: 11.5))
                .frame(width: theme.z(16))
            if showsTitle {
                Text(kind.title)
                    .font(theme.font(size: 12, weight: isFront ? .medium : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            if isFront || hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(theme.font(size: 8.5, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: theme.z(14), height: theme.z(14))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close \(kind.title)")
                .accessibilityLabel("Close \(kind.title)")
            }
        }
        .foregroundStyle(isFront ? theme.textPrimary : theme.textSecondary)
        .padding(.leading, theme.z(7))
        .padding(.trailing, theme.z(isFront || hovering ? 4 : 7))
        .frame(height: theme.z(26))
        .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
            .fill(isFront ? theme.selection : (hovering ? theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .help(kind.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.title) tab")
        .accessibilityAddTraits(isFront ? [.isButton, .isSelected] : .isButton)
    }
}
