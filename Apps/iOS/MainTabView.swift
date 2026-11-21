import EnsembleKit
import SwiftUI

/// Picks the layout from the horizontal size class: tabs on a compact width (outer Duo screen / iPhone),
/// panes side by side on a regular width (unfolded Duo inner screen, portrait and landscape).
/// Both read from `RemoteAppModel`, so folding or unfolding keeps the open chat, drafts, and scroll anchor.
struct MainTabView: View {
    let client: RemoteClient
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        FoldAware {
            if sizeClass == .regular {
                SplitRootView(client: client)
            } else {
                CompactRootView(client: client)
            }
        }
    }
}

// MARK: - Compact outer shell

/// Outer screen: 4 tabs, with chats pushed onto the Hub or Rooms stack.
struct CompactRootView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Hub", systemImage: "tray.full", value: RemoteTab.hub) {
                NavigationStack(path: $model.hubPath) {
                    HubView(client: client, open: { model.open($0, from: .hub) })
                        .navigationDestination(for: ChatRoute.self) { route in
                            CompactChatDestination(client: client, route: route)
                        }
                }
            }
            .badge(needsYouCount(client))

            Tab("Rooms", systemImage: "person.3", value: RemoteTab.rooms) {
                NavigationStack(path: $model.roomsPath) {
                    RoomsView(client: client, open: { model.open($0, from: .rooms) })
                        .navigationDestination(for: ChatRoute.self) { route in
                            CompactChatDestination(client: client, route: route)
                        }
                }
            }
            .badge(client.rooms.count(where: \.needsYou))

            Tab("Usage", systemImage: "chart.bar", value: RemoteTab.usage) {
                NavigationStack {
                    UsageView(client: client)
                }
            }

            Tab("Settings", systemImage: "gearshape", value: RemoteTab.settings) {
                NavigationStack {
                    SettingsView(client: client)
                }
            }
        }
    }
}

private struct CompactChatDestination: View {
    let client: RemoteClient
    let route: ChatRoute

    var body: some View {
        ChatView(client: client, sessionID: route.sessionID, title: route.title)
            .id(route.sessionID)
            .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - Unfolded inner pane shell

/// Inner screen: the session list, the chat and the details panel as panes this app lays out itself.
///
/// A NavigationSplitView cannot do this. Asked for a list as wide as half the screen (the book fold) it shows its
/// overlay mode for most of a second, the chat full width and dimmed under the list, before it settles. Here the
/// panes are plain views in a row (or a column for the laptop fold), so a fold or a button moves them in one step
/// and the panes slide from their old places to their new ones.
struct SplitRootView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.foldLayout) private var fold
    @AppStorage("remote.panes.sidebar") private var sidebarWanted = true
    @AppStorage("remote.panes.details") private var detailsWanted = false
    /// Where the panes sit on screen, to turn the crease's screen position into a pane width.
    @State private var frame: CGRect = .zero
    @State private var toggleHaptic = 0
    /// How far each pane is from its place while a fold slides it there. Empty when nothing is moving.
    @State private var paneShift: [PaneRole: CGSize] = [:]
    /// A pane button's own glide is running until then, so the fold's slide stays out of its way.
    @State private var buttonGlideUntil = Date.distantPast
    @State private var lastSlide = Date.distantPast

    /// The top safe area is tall enough to be the upright screen's status band.
    private var liftsSidebar: Bool { frame.minY > 44 }
    private static let liftedHeaderInset: CGFloat = 16

    private var chat: ChatRoute? {
        model.tab == .hub || model.tab == .rooms ? model.selectedChat : nil
    }

    private var plan: PanePlan { plan(fold: fold, sidebar: sidebarWanted, details: detailsWanted) }

    private func plan(fold: FoldLayout, sidebar: Bool, details: Bool) -> PanePlan {
        let local: FoldLayout = switch fold {
        case .flat: .flat
        case .book(let creaseX): .book(creaseX: creaseX - frame.minX)
        case .laptop(let creaseY): .laptop(creaseY: creaseY - frame.minY)
        }
        return PanePlan.resolve(size: frame.size, fold: local, sidebarWanted: sidebar,
                                detailsWanted: details, hasChat: chat != nil)
    }

    var body: some View {
        let plan = plan
        let gutter = FoldMetrics.creaseGutter
        // Laptop fold without a chat: the detail on top, the list below. With a chat, the chat takes the whole
        // height and puts the deck under its own message box.
        let stackedCrease: CGFloat? = if case .laptop(let creaseY) = plan.shape, chat == nil { creaseY } else { nil }
        let isBook = if case .book = plan.shape { true } else { false }
        let stack = stackedCrease == nil ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))

        stack {
            if let width = plan.sidebarWidth {
                sidebarPane()
                    .safeAreaPadding(.trailing, isBook ? gutter : 0)
                    // Upright, the top of the screen is a tall band that holds the clock on the right and the
                    // chat's bar. The list's header moves up into the band's free left side, level with that bar,
                    // instead of starting under an empty strip.
                    .padding(.top, liftsSidebar ? Self.liftedHeaderInset : 0)
                    .ignoresSafeArea(.container, edges: liftsSidebar ? .top : [])
                    .frame(width: width)
                    .overlay(alignment: .trailing) { paneEdge }
                    .offset(paneShift[.sidebar] ?? .zero)
                    .zIndex(1)
            }

            // Always the second child, whatever is around it, so the chat keeps its place and its scroll position.
            NavigationStack {
                SplitDetailView(client: client)
            }
            .safeAreaPadding(.leading, isBook && plan.sidebarWidth != nil ? gutter : 0)
            .safeAreaPadding(.trailing, isBook && plan.detailsWidth != nil ? gutter : 0)
            .frame(height: stackedCrease.map { max(0, $0 - gutter) })
            .frame(maxWidth: .infinity, maxHeight: stackedCrease == nil ? .infinity : nil)
            // The chat's colour runs on under its neighbours, so while it slides there is never a bare gap beside it.
            .background(RemoteTheme.background.padding(.horizontal, -500).ignoresSafeArea())
            .offset(paneShift[.chat] ?? .zero)

            if let width = plan.detailsWidth, let chat {
                detailsPane(chat)
                    .safeAreaPadding(.leading, isBook ? gutter : 0)
                    .frame(width: width)
                    .overlay(alignment: .leading) { paneEdge }
                    .offset(paneShift[.details] ?? .zero)
                    .zIndex(1)
            }

            if stackedCrease != nil {
                sidebarPane(compact: true)
                    .padding(.top, gutter)
                    .frame(maxHeight: .infinity)
                    .background(RemoteTheme.sidebar.ignoresSafeArea())
                    .offset(paneShift[.sidebar] ?? .zero)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Measured without the keyboard: the keyboard coming up must not change which layout this is, or the
        // panes would jump around the moment you tap a text field while the phone is part folded.
        .background {
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                // Outside the reader: a reader outside this modifier would still see the keyboard-shortened size.
                .ignoresSafeArea(.keyboard)
        }
        // The layout changed shape (the hinge): slide the real panes from where they were to where they are now.
        .onChange(of: plan) { old, new in slide(from: old, to: new) }
        .environment(\.paneControls, PaneControls(
            isActive: true,
            sidebarShown: plan.showsSidebar || stackedCrease != nil,
            detailsShown: plan.showsDetails,
            canShowDetails: chat != nil,
            toggleSidebar: { toggleSidebar(plan) },
            toggleDetails: { toggleDetails(plan) }
        ))
        .environment(\.laptopDeck, deck(plan))
        .sensoryFeedback(.selection, trigger: toggleHaptic)
    }

    /// The session list. `compact` is the short form for the lower half of the laptop fold.
    private func sidebarPane(compact: Bool = false) -> some View {
        SplitSidebarView(client: client, compact: compact, onOpenRoute: { model.open($0, from: $1) },
                         onSelectUtilityTab: selectUtilityTab)
    }

    /// The hairline between a side pane and the chat.
    private var paneEdge: some View {
        Rectangle().fill(RemoteTheme.separator).frame(width: 1).ignoresSafeArea()
    }

    private func detailsPane(_ chat: ChatRoute) -> some View {
        SessionDetailsPanel(client: client, sessionID: chat.sessionID)
            .id(chat.sessionID)
    }

    /// What the chat puts under its message box in the laptop fold.
    private func deck(_ plan: PanePlan) -> AnyView? {
        guard case .laptop = plan.shape, let chat else { return nil }
        switch plan.deck {
        case .none: return nil
        case .sidebar: return AnyView(sidebarPane(compact: true).offset(paneShift[.sidebar] ?? .zero))
        case .details: return AnyView(detailsPane(chat).offset(paneShift[.details] ?? .zero))
        }
    }

    private func toggleSidebar(_ plan: PanePlan) {
        toggleHaptic += 1
        buttonGlideUntil = Date().addingTimeInterval(0.6)
        var sidebar = sidebarWanted, details = detailsWanted
        if plan.showsSidebar {
            sidebar = false
        } else {
            sidebar = true
            if !plan.fitsBoth { details = false }
        }
        glide(from: plan, to: self.plan(fold: fold, sidebar: sidebar, details: details))
        sidebarWanted = sidebar
        detailsWanted = details
    }

    private func toggleDetails(_ plan: PanePlan) {
        toggleHaptic += 1
        buttonGlideUntil = Date().addingTimeInterval(0.6)
        var sidebar = sidebarWanted, details = detailsWanted
        if plan.showsDetails {
            details = false
            // The book fold always has two pages: without the details, the list is the other one.
            if case .book = plan.shape { sidebar = true }
        } else {
            details = true
        }
        glide(from: plan, to: self.plan(fold: fold, sidebar: sidebar, details: details))
        sidebarWanted = sidebar
        detailsWanted = details
    }

    /// Starts the panes gliding from one plan's places to another's. Call it before the new layout is on screen.
    private func glide(from old: PanePlan, to new: PanePlan) {
        guard old != new, frame.width > 0 else { return }
        PaneGlide.run(from: paneRects(old), to: paneRects(new), colors: [
            .chat: UIColor(RemoteTheme.background), .sidebar: UIColor(RemoteTheme.sidebar), .details: UIColor(RemoteTheme.sidebar),
        ])
    }

    /// The hinge changed the layout's shape. The panes are already in their new places and sizes: each one is put
    /// back where it was with an offset, and the offsets then run down to zero. Nothing is laid out again while they
    /// move, and the panes are the real views, so they stay right when iOS resizes the window mid-fold.
    private func slide(from old: PanePlan, to new: PanePlan) {
        let now = Date()
        // Folding (into the book or laptop shape) already gets iOS's own fade over the whole window; a slide of
        // ours on top of it shows up as a second movement after the fade, with the chat cut off at its edge.
        // Unfolding gets no fade from iOS, so only that direction slides.
        guard new.shape == .row else { return }
        guard old.kind != new.kind, frame.width > 0, now > buttonGlideUntil,
              now.timeIntervalSince(lastSlide) > 0.6, !UIAccessibility.isReduceMotionEnabled else { return }
        let before = paneRects(old), after = paneRects(new)
        let bounds = windowBounds
        let isColumn = { (rect: CGRect) in rect.height >= bounds.height * 0.8 }
        var shifts: [PaneRole: CGSize] = [:]
        for (role, place) in after {
            var start = before[role]
            // A side pane that changes from a column to the lower half (or back) comes in from its edge instead.
            if role != .chat, let was = start, isColumn(was) != isColumn(place) { start = nil }
            let from = start ?? PaneGlide.offstage(role, like: place, in: bounds)
            let shift = CGSize(width: from.minX - place.minX, height: from.minY - place.minY)
            if abs(shift.width) > 24 || abs(shift.height) > 24 { shifts[role] = shift }
        }
        guard !shifts.isEmpty else { return }
        lastSlide = now
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { paneShift = shifts }
        // One turn of the run loop later, so the panes are drawn once at their starting places first.
        DispatchQueue.main.async {
            withAnimation(PaneMotion.fold) { paneShift = [:] }
        }
    }

    private var windowBounds: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.bounds ?? frame
    }

    /// Where each pane sits for a plan, in window coordinates, edge to edge (the panes' backgrounds run under the
    /// safe areas). Together the rectangles cover the window, which is what lets the glide end exactly on the real
    /// layout.
    private func paneRects(_ plan: PanePlan) -> [PaneRole: CGRect] {
        let window = windowBounds
        var rects: [PaneRole: CGRect] = [:]
        switch plan.shape {
        case .row, .book:
            var left = window.minX, right = window.maxX
            if let width = plan.sidebarWidth {
                let edge = frame.minX + width
                rects[.sidebar] = CGRect(x: left, y: window.minY, width: edge - left, height: window.height)
                left = edge
            }
            if let width = plan.detailsWidth {
                let edge = frame.maxX - width
                rects[.details] = CGRect(x: edge, y: window.minY, width: right - edge, height: window.height)
                right = edge
            }
            rects[.chat] = CGRect(x: left, y: window.minY, width: right - left, height: window.height)
        case .laptop(let creaseY):
            let crease = frame.minY + creaseY
            // With a chat open the deck's pane starts under the message box, which is about this tall.
            let top = chat == nil ? crease : crease + 132
            let lower = CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top)
            let upper = CGRect(x: window.minX, y: window.minY, width: window.width, height: top - window.minY)
            switch chat == nil ? PanePlan.Deck.sidebar : plan.deck {
            case .none: rects[.chat] = window
            case .sidebar: rects[.chat] = upper; rects[.sidebar] = lower
            case .details: rects[.chat] = upper; rects[.details] = lower
            }
        }
        return rects
    }

    private func selectUtilityTab(_ tab: RemoteTab) {
        model.tab = model.tab == tab ? model.listTab : tab
    }
}

private struct SplitSidebarView: View {
    let client: RemoteClient
    /// One header row with everything in it and no footer, for the lower half of the laptop fold.
    var compact = false
    let onOpenRoute: (ChatRoute, RemoteTab) -> Void
    let onSelectUtilityTab: (RemoteTab) -> Void
    @Environment(RemoteAppModel.self) private var model
    @State private var showNewSession = false
    @State private var showNewRoom = false

    var body: some View {
        VStack(spacing: 0) {
            SplitSidebarHeader(client: client, compact: compact, onSelectUtilityTab: onSelectUtilityTab) {
                if model.listTab == .rooms {
                    showNewRoom = true
                } else {
                    showNewSession = true
                }
            }

            Group {
                let activeSessionID = (model.tab == .hub || model.tab == .rooms) ? model.selectedChat?.sessionID : nil
                if model.listTab == .rooms {
                    RoomsListContent(
                        client: client,
                        selectedSessionID: activeSessionID,
                        open: { onOpenRoute($0, .rooms) }
                    )
                } else {
                    HubBoardContent(
                        client: client,
                        selectedSessionID: activeSessionID,
                        showsFilter: !compact,
                        open: { onOpenRoute($0, .hub) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !compact {
                SplitSidebarFooter(onSelect: onSelectUtilityTab)
            }
        }
        .background(RemoteTheme.sidebar.ignoresSafeArea())
        .sheet(isPresented: $showNewSession) {
            RemoteNewSessionSheet(client: client) { created in
                onOpenRoute(ChatRoute(sessionID: created.id, title: created.title), .hub)
            }
            .remoteThemeEnvironment()
        }
        .sheet(isPresented: $showNewRoom) {
            RemoteNewRoomSheet(client: client) { room in
                onOpenRoute(ChatRoute(sessionID: room.sessionID, title: room.title), .rooms)
            }
            .remoteThemeEnvironment()
        }
    }
}

private struct SplitSidebarHeader: View {
    let client: RemoteClient
    var compact = false
    var onSelectUtilityTab: (RemoteTab) -> Void = { _ in }
    let onNew: () -> Void
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.paneControls) private var controls

    private var hubBadge: Int { needsYouCount(client) }
    private var roomsBadge: Int { client.rooms.count(where: \.needsYou) }

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .center, spacing: 8) {
                    if controls.isActive {
                        SidebarToggleButton()
                            .padding(.leading, -4)
                    }
                    segments
                    utilityButton("Usage", systemImage: "chart.bar", target: .usage)
                    utilityButton("Settings", systemImage: "gearshape", target: .settings)
                    newButton
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        if controls.isActive {
                            SidebarToggleButton()
                                .padding(.leading, -4)
                        }
                        Text("Ensemble")
                            .font(RemoteTheme.font(size: 18, weight: .semibold, relativeTo: .headline))
                            .foregroundStyle(RemoteTheme.primaryText)
                            .lineLimit(1)
                            .fixedSize()
                        Spacer(minLength: 4)
                        StatusPill(client: client)
                        newButton
                    }
                    segments
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
        }
        .background(RemoteTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RemoteTheme.separator).frame(height: 1)
        }
    }

    private var segments: some View {
        HStack(spacing: 4) {
            segmentButton(title: "Hub", badge: hubBadge, target: .hub)
            segmentButton(title: "Rooms", badge: roomsBadge, target: .rooms)
        }
        .padding(3)
        .background(RemoteTheme.codeBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(RemoteTheme.border, lineWidth: 0.75)
        )
    }

    private var newButton: some View {
        Button(action: onNew) {
            Image(systemName: "plus")
                .font(RemoteTheme.font(size: 13.5, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.accent)
                .frame(width: 30, height: 30)
                .background(RemoteTheme.accent.opacity(0.14), in: Circle())
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!client.state.isConnected || client.availableModels.isEmpty)
        .accessibilityLabel(model.listTab == .rooms ? "New room" : "New session")
        .accessibilityHint(
            !client.state.isConnected
                ? "Connect to your Mac first"
                : (client.availableModels.isEmpty ? "Loading available models from your Mac" : "")
        )
    }

    /// Usage or Settings as an icon, where the short header has no room for the footer's labelled buttons.
    private func utilityButton(_ title: String, systemImage: String, target: RemoteTab) -> some View {
        let active = model.tab == target
        return Button {
            onSelectUtilityTab(target)
        } label: {
            Image(systemName: systemImage)
                .font(RemoteTheme.font(size: 14, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(active ? RemoteTheme.accent : RemoteTheme.secondaryText)
                .frame(width: 36, height: 36)
                .background(active ? RemoteTheme.accent.opacity(0.14) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func segmentButton(title: String, badge: Int, target: RemoteTab) -> some View {
        let active = model.listTab == target
        return Button {
            model.showList(target)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(RemoteTheme.font(size: 13.5, weight: active ? .semibold : .medium, relativeTo: .subheadline))
                if badge > 0 {
                    Text("\(badge)")
                        .font(RemoteTheme.font(size: 11, weight: .semibold, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(active ? RemoteTheme.onAccent : RemoteTheme.primaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(active ? RemoteTheme.accent : RemoteTheme.warning.opacity(0.24))
                        )
                }
            }
            .foregroundStyle(active ? RemoteTheme.primaryText : RemoteTheme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(active ? RemoteTheme.card : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .strokeBorder(active ? RemoteTheme.border : .clear, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: RemoteTheme.minTapTarget)
    }
}

private struct SplitSidebarFooter: View {
    let onSelect: (RemoteTab) -> Void
    @Environment(RemoteAppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(RemoteTheme.separator).frame(height: 1)
            HStack(spacing: 8) {
                footerButton("Usage", systemImage: "chart.bar", target: .usage)
                footerButton("Settings", systemImage: "gearshape", target: .settings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RemoteTheme.sidebar)
        }
    }

    private func footerButton(_ title: String, systemImage: String, target: RemoteTab) -> some View {
        let active = model.tab == target
        return Button {
            onSelect(target)
        } label: {
            Label(title, systemImage: systemImage)
                .font(RemoteTheme.font(size: 13.5, weight: active ? .semibold : .medium, relativeTo: .subheadline))
                .foregroundStyle(active ? RemoteTheme.accent : RemoteTheme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: RemoteTheme.minTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? RemoteTheme.accent.opacity(0.14) : RemoteTheme.card.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? RemoteTheme.accent.opacity(0.45) : RemoteTheme.border, lineWidth: 0.75)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SplitDetailView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.paneControls) private var controls

    var body: some View {
        Group {
            switch model.tab {
            case .usage:
                UsageView(client: client, showStatusInToolbar: !controls.sidebarShown)
            case .settings:
                SettingsView(client: client, showStatusInToolbar: !controls.sidebarShown)
            case .hub, .rooms:
                if let route = model.selectedChat {
                    ChatView(client: client, sessionID: route.sessionID, title: route.title)
                        .id(route.sessionID)
                } else {
                    EmptyDetailView()
                }
            }
        }
        .toolbar {
            if !controls.sidebarShown {
                ToolbarItem(placement: .topBarLeading) { SidebarToggleButton() }
            }
            if controls.canShowDetails {
                ToolbarItem(placement: .topBarTrailing) { DetailsToggleButton() }
            }
        }
    }
}

private struct EmptyDetailView: View {
    @Environment(\.paneControls) private var controls

    var body: some View {
        VStack(spacing: 16) {
            ConstellationSpinner(size: 52, frozenAt: 1.1)
            Text("No chat selected")
                .font(RemoteTheme.font(size: 16, weight: .medium, relativeTo: .headline))
                .foregroundStyle(RemoteTheme.secondaryText)
            if !controls.sidebarShown {
                Button("Show list") { controls.toggleSidebar() }
                    .buttonStyle(RemoteSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RemoteTheme.background.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - Helpers & StatusPill

@MainActor private func needsYouCount(_ client: RemoteClient) -> Int {
    HubBoard.group(client.sessions)[.needsYou]?.count ?? 0
}

/// Compact connection status pill in toolbars and sidebar header. Tapping reconnects when offline.
struct StatusPill: View {
    let client: RemoteClient
    var inToolbar = false

    var body: some View {
        Button {
            if !client.state.isConnected && !client.isInProcess {
                client.reconnectNow()
            }
        } label: {
            if inToolbar {
                pillContent
                    .padding(.horizontal, 6)
            } else {
                pillContent
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RemoteTheme.cardRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(RemoteTheme.border, lineWidth: 0.75))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel("Connection: \(client.statusText)")
    }

    private var pillContent: some View {
        HStack(spacing: 6) {
            RemoteLiveDot(color: dotColor, size: 7, pulsing: isConnecting)
            Text(shortLabel)
                .font(RemoteTheme.font(size: 12.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(RemoteTheme.primaryText)
                .lineLimit(1)
        }
    }

    private var isConnecting: Bool {
        if case .connecting = client.state { return !client.isInProcess }
        return false
    }

    private var shortLabel: String {
        if client.isInProcess { return "Demo" }
        switch client.state {
        case .idle: return "Offline"
        case .connecting: return "Connecting"
        case .connected(via: .direct): return "Direct"
        case .connected(via: .relay): return "Relay"
        case .macOffline: return "Mac offline"
        case .limitReached: return "Relay limit"
        case .waiting(let s): return "Retry \(s)s"
        case .rejected: return "Pair again"
        }
    }

    private var dotColor: Color {
        if client.isInProcess { return RemoteTheme.accent }
        switch client.state {
        case .connected: return RemoteTheme.success
        case .connecting, .waiting, .macOffline: return RemoteTheme.warning
        case .idle, .rejected, .limitReached: return RemoteTheme.danger
        }
    }
}

/// Shows a failed action as an alert.
struct ActionErrorModifier: ViewModifier {
    @Binding var error: String?

    func body(content: Content) -> some View {
        content.alert("Could not do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

extension View {
    func actionErrorAlert(_ error: Binding<String?>) -> some View { modifier(ActionErrorModifier(error: error)) }
}

#Preview("Phone") {
    MainTabView(client: .preview(.showcase()))
        .environment(RemoteAppModel())
        .remoteThemeEnvironment()
}
