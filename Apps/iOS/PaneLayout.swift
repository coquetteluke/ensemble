import SwiftUI

/// Which panes the inner screen shows and where, for one window size, fold and pair of switches.
///
/// There are three panes: the session list, the chat (or Usage, Settings) and the details panel. The inner screen
/// of the iPhone Duo fits two of them at a time, so the list and the details take turns next to the chat.
struct PanePlan: Equatable {
    enum Shape: Equatable {
        /// Panes side by side.
        case row
        /// Partly folded like a book: two pages that meet at the crease (`creaseX` from the left edge).
        case book(creaseX: CGFloat)
        /// Partly folded like a laptop: the chat above the crease, a deck below (`creaseY` from the top edge).
        case laptop(creaseY: CGFloat)
    }

    /// The shape without its crease position: tells a new layout from a crease that only moved a little.
    var kind: Int {
        switch shape {
        case .row: 0
        case .book: 1
        case .laptop: 2
        }
    }

    /// What sits under the message box in the laptop shape.
    enum Deck: Equatable { case none, sidebar, details }

    var shape: Shape = .row
    /// Width of the session list when it has its own column or page.
    var sidebarWidth: CGFloat?
    /// Width of the details panel when it has its own column or page.
    var detailsWidth: CGFloat?
    var deck: Deck = .none
    /// The list and the details panel both fit next to the chat (wide screens only).
    var fitsBoth = false

    var showsSidebar: Bool { sidebarWidth != nil || deck == .sidebar }
    var showsDetails: Bool { detailsWidth != nil || deck == .details }

    /// The narrowest the chat may get before a side pane has to give way.
    static let chatMinWidth: CGFloat = 340

    /// Width of the list or the details panel as a column.
    static func paneWidth(in width: CGFloat) -> CGFloat {
        min(340, max(300, (width * 0.4).rounded()))
    }

    /// - Parameters:
    ///   - size: the space for the panes.
    ///   - fold: the hinge layout, with the crease in the same coordinates as `size`.
    ///   - sidebarWanted: the session list is switched on.
    ///   - detailsWanted: the details panel is switched on.
    ///   - hasChat: a chat is open (the details panel describes one chat, so it needs one).
    static func resolve(size: CGSize, fold: FoldLayout, sidebarWanted: Bool, detailsWanted: Bool, hasChat: Bool) -> PanePlan {
        let details = detailsWanted && hasChat
        switch fold {
        case .laptop(let creaseY) where creaseY > 120 && creaseY < size.height - 120:
            let deck: Deck = details ? .details : (sidebarWanted ? .sidebar : .none)
            return PanePlan(shape: .laptop(creaseY: creaseY), deck: deck)
        case .book(let creaseX) where creaseX > 200 && creaseX < size.width - 200:
            // Always two pages: the list and the chat, or the chat and its details.
            if hasChat && (detailsWanted || !sidebarWanted) {
                return PanePlan(shape: .book(creaseX: creaseX), detailsWidth: size.width - creaseX)
            }
            return PanePlan(shape: .book(creaseX: creaseX), sidebarWidth: creaseX)
        default:
            let pane = paneWidth(in: size.width)
            let fitsBoth = size.width - pane * 2 >= chatMinWidth
            return PanePlan(shape: .row,
                            sidebarWidth: sidebarWanted && (fitsBoth || !details) ? pane : nil,
                            detailsWidth: details ? pane : nil,
                            fitsBoth: fitsBoth)
        }
    }
}

/// The two pane switches, for the buttons in the list's header and the chat's toolbar.
struct PaneControls {
    /// False on the outer screen, which has tabs instead of panes.
    var isActive = false
    var sidebarShown = true
    var detailsShown = false
    /// A chat is open, so there are details to show.
    var canShowDetails = false
    var toggleSidebar: @MainActor () -> Void = {}
    var toggleDetails: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    @Entry var paneControls = PaneControls()
    /// The pane the laptop fold puts under the message box (the session list or the details), nil otherwise.
    @Entry var laptopDeck: AnyView? = nil
}

/// Shows or hides the session list. It sits at the top left: in the list's header while the list is open, in the
/// toolbar of whatever is next to it while the list is hidden.
struct SidebarToggleButton: View {
    @Environment(\.paneControls) private var controls

    var body: some View {
        Button {
            controls.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
                .font(RemoteTheme.font(size: 15, weight: .medium, relativeTo: .body))
                .foregroundStyle(RemoteTheme.secondaryText)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controls.sidebarShown ? "Hide session list" : "Show session list")
    }
}

/// Shows or hides the details panel (Environment, Context, Outputs, Connectors).
struct DetailsToggleButton: View {
    @Environment(\.paneControls) private var controls

    var body: some View {
        Button {
            controls.toggleDetails()
        } label: {
            Image(systemName: "sidebar.right")
                .font(RemoteTheme.font(size: 15, weight: .medium, relativeTo: .body))
                .foregroundStyle(controls.detailsShown ? RemoteTheme.accent : RemoteTheme.secondaryText)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(controls.detailsShown ? "Hide details" : "Show details")
    }
}

/// How the panes move when the phone folds or unfolds.
enum PaneMotion {
    /// The curve and length of the slide. The panes are real views moved with an offset, so any animation works
    /// here without costing a layout pass per frame.
    static var fold: Animation {
        // TODO(human): choose how the fold feels. This default is a calm glide with no bounce.
        .smooth(duration: 0.5)
    }
}
