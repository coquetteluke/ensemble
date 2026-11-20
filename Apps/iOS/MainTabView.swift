import EnsembleKit
import SwiftUI

/// Picks the layout from the horizontal size class: tabs on a compact width (outer Duo screen / iPhone),
/// a two-column split view on a regular width (unfolded Duo inner screen, portrait and landscape).
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

// MARK: - Unfolded inner split shell

/// Inner screen: Hub/Rooms sidebar (310-380 pt) with Usage/Settings footer, and full-bleed detail view.
struct SplitRootView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var width: CGFloat = 0
    @State private var didInitializeWidth = false

    /// Unfolded Duo landscape is ~951 pt; unfolded Duo portrait is ~669 pt.
    private let sideBySideWidth: CGFloat = 780
    private var isSideBySide: Bool { width >= sideBySideWidth }

    @Environment(\.foldLayout) private var fold
    /// Where this view sits on screen, to put the book layout's page break on the crease.
    @State private var globalMinX: CGFloat = 0

    var body: some View {
        Group {
            if case .book(let creaseX) = fold {
                bookLayout(leftWidth: max(240, creaseX - globalMinX))
                    .transition(.opacity)
            } else {
                splitLayout
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { globalMinX = $0 }
    }

    /// Partly folded like a book: the list on the left page, the chat on the right, the page break on the crease.
    private func bookLayout(leftWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            SplitSidebarView(client: client, onOpenRoute: open, onSelectUtilityTab: selectUtilityTab)
                .padding(.trailing, FoldMetrics.creaseGutter)
                .frame(width: leftWidth)
                .background(RemoteTheme.sidebar.ignoresSafeArea())
            NavigationStack {
                SplitDetailView(
                    client: client,
                    isSideBySide: true,
                    showStatusInToolbar: false,
                    onShowSidebar: {}
                )
            }
            .padding(.leading, FoldMetrics.creaseGutter)
            .background(RemoteTheme.background.ignoresSafeArea())
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SplitSidebarView(
                client: client,
                onOpenRoute: open,
                onSelectUtilityTab: selectUtilityTab
            )
            .navigationSplitViewColumnWidth(min: 310, ideal: 340, max: 380)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            NavigationStack {
                SplitDetailView(
                    client: client,
                    isSideBySide: isSideBySide,
                    showStatusInToolbar: !isSideBySide || columns == .detailOnly,
                    onShowSidebar: { columns = .doubleColumn }
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            let wasSideBySide = width >= sideBySideWidth
            width = newWidth
            let nowSideBySide = newWidth >= sideBySideWidth

            if !didInitializeWidth {
                didInitializeWidth = true
                if nowSideBySide {
                    columns = .all
                } else {
                    columns = (model.selectedChat == nil && (model.tab == .hub || model.tab == .rooms))
                        ? .doubleColumn
                        : .detailOnly
                }
                return
            }

            if wasSideBySide != nowSideBySide {
                if nowSideBySide {
                    columns = .all
                } else if model.selectedChat == nil && (model.tab == .hub || model.tab == .rooms) {
                    columns = .doubleColumn
                } else {
                    columns = .detailOnly
                }
            }
        }
    }

    private func open(_ route: ChatRoute, from list: RemoteTab) {
        model.open(route, from: list)
        if !isSideBySide {
            columns = .detailOnly
        }
    }

    private func selectUtilityTab(_ tab: RemoteTab) {
        model.tab = model.tab == tab ? model.listTab : tab
        if !isSideBySide {
            columns = .detailOnly
        }
    }
}

private struct SplitSidebarView: View {
    let client: RemoteClient
    let onOpenRoute: (ChatRoute, RemoteTab) -> Void
    let onSelectUtilityTab: (RemoteTab) -> Void
    @Environment(RemoteAppModel.self) private var model
    @State private var showNewSession = false
    @State private var showNewRoom = false

    var body: some View {
        VStack(spacing: 0) {
            SplitSidebarHeader(client: client) {
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
                        open: { onOpenRoute($0, .hub) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SplitSidebarFooter(onSelect: onSelectUtilityTab)
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
    let onNew: () -> Void
    @Environment(RemoteAppModel.self) private var model

    private var hubBadge: Int { needsYouCount(client) }
    private var roomsBadge: Int { client.rooms.count(where: \.needsYou) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Ensemble")
                    .font(RemoteTheme.font(size: 18, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(RemoteTheme.primaryText)
                Spacer(minLength: 8)
                StatusPill(client: client)
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
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(RemoteTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RemoteTheme.separator).frame(height: 1)
        }
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
    let isSideBySide: Bool
    let showStatusInToolbar: Bool
    let onShowSidebar: () -> Void
    @Environment(RemoteAppModel.self) private var model

    var body: some View {
        switch model.tab {
        case .usage:
            UsageView(client: client, showStatusInToolbar: showStatusInToolbar)
        case .settings:
            SettingsView(client: client, showStatusInToolbar: showStatusInToolbar)
        case .hub, .rooms:
            if let route = model.selectedChat {
                ChatView(client: client, sessionID: route.sessionID, title: route.title)
                    .id(route.sessionID)
            } else {
                EmptyDetailView(isSideBySide: isSideBySide, onShowSidebar: onShowSidebar)
            }
        }
    }
}

private struct EmptyDetailView: View {
    let isSideBySide: Bool
    let onShowSidebar: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ConstellationSpinner(size: 52, frozenAt: 1.1)
            Text("No chat selected")
                .font(RemoteTheme.font(size: 16, weight: .medium, relativeTo: .headline))
                .foregroundStyle(RemoteTheme.secondaryText)
            if !isSideBySide {
                Button("Show list", action: onShowSidebar)
                    .buttonStyle(RemoteSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RemoteTheme.background.ignoresSafeArea())
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
