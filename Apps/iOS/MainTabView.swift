import EnsembleKit
import SwiftUI

/// Picks the layout from the space available: tabs on a compact width (iPhone, or the outer screen of a
/// foldable iPhone), a two-column split view on a regular width (the inner screen). Both read the same
/// model, so folding or unfolding keeps the open chat, drafts and scroll positions.
struct MainTabView: View {
    let client: RemoteClient
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            SplitRootView(client: client)
        } else {
            CompactRootView(client: client)
        }
    }
}

/// Outer screen: one column of tabs, chats pushed onto the Hub or Rooms stack.
struct CompactRootView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Hub", systemImage: "tray.full", value: RemoteTab.hub) {
                NavigationStack(path: $model.hubPath) {
                    HubView(client: client, open: { model.open($0, from: .hub) })
                        .navigationDestination(for: ChatRoute.self) { chat($0) }
                }
            }
            .badge(needsYouCount(client))
            Tab("Rooms", systemImage: "person.3", value: RemoteTab.rooms) {
                NavigationStack(path: $model.roomsPath) {
                    RoomsView(client: client, open: { model.open($0, from: .rooms) })
                        .navigationDestination(for: ChatRoute.self) { chat($0) }
                }
            }
            Tab("Usage", systemImage: "chart.bar", value: RemoteTab.usage) {
                NavigationStack { UsageView(client: client) }
            }
            Tab("Settings", systemImage: "gearshape", value: RemoteTab.settings) {
                NavigationStack { SettingsView(client: client) }
            }
        }
    }

    private func chat(_ route: ChatRoute) -> some View {
        ChatView(client: client, sessionID: route.sessionID, title: route.title)
            .toolbar(.hidden, for: .tabBar)
    }
}

/// Inner screen: Session Hub or Rooms in the sidebar, the open chat (or Usage, Settings) on the right.
struct SplitRootView: View {
    let client: RemoteClient
    @Environment(RemoteAppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    /// Window width. Below `sideBySideWidth` the sidebar floats over the chat (inner screen in portrait).
    @State private var width: CGFloat = 0
    private let sideBySideWidth: CGFloat = 800

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            width = newWidth
            // Nothing open yet: show the list instead of an empty detail column.
            if model.selectedChat == nil && (model.tab == .hub || model.tab == .rooms) { columns = .doubleColumn }
        }
        .onChange(of: width >= sideBySideWidth) { _, wide in
            // Back to side by side when there is room again (rotated to landscape).
            if wide { columns = .all }
        }
    }

    /// Opens a chat; when the sidebar floats over the chat, hides it so the chat is visible.
    private func open(_ route: ChatRoute, from list: RemoteTab) {
        model.open(route, from: list)
        if width < sideBySideWidth { columns = .detailOnly }
    }

    private var sidebar: some View {
        Group {
            if model.listTab == .rooms {
                RoomsView(client: client, selectedSessionID: model.selectedChat?.sessionID,
                          open: { open($0, from: .rooms) })
            } else {
                HubView(client: client, selectedSessionID: model.selectedChat?.sessionID,
                        open: { open($0, from: .hub) })
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("List", selection: Binding(get: { model.listTab }, set: { model.showList($0) })) {
                Text("Session Hub").tag(RemoteTab.hub)
                Text("Rooms").tag(RemoteTab.rooms)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RemoteTheme.background)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                footerButton("Usage", systemImage: "chart.bar", tab: .usage)
                footerButton("Settings", systemImage: "gearshape", tab: .settings)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func footerButton(_ title: String, systemImage: String, tab: RemoteTab) -> some View {
        Button {
            model.tab = model.tab == tab ? model.listTab : tab
            if width < sideBySideWidth { columns = .detailOnly }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(model.tab == tab ? Color.accentColor : RemoteTheme.secondaryText)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.tab {
        case .usage:
            UsageView(client: client)
        case .settings:
            SettingsView(client: client)
        case .hub, .rooms:
            if let route = model.selectedChat {
                ChatView(client: client, sessionID: route.sessionID, title: route.title)
                    .id(route.sessionID)
            } else {
                ContentUnavailableView {
                    Label("No chat open", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Choose a session or room from the list.")
                } actions: {
                    Button("Show list") { columns = .doubleColumn }
                        .buttonStyle(.bordered)
                }
                .remoteScreen()
            }
        }
    }
}

@MainActor private func needsYouCount(_ client: RemoteClient) -> Int {
    HubBoard.group(client.sessions)[.needsYou]?.count ?? 0
}

#Preview("Phone") {
    MainTabView(client: .preview())
        .environment(RemoteAppModel())
        .preferredColorScheme(.dark)
}

/// Connection status shown in every screen's toolbar. Tap to reconnect now.
struct StatusPill: View {
    let client: RemoteClient

    var body: some View {
        Button {
            if !client.state.isConnected { client.reconnectNow() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RemoteTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RemoteTheme.cardRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(label)")
    }

    private var label: String {
        if client.isInProcess { return "Demo" }
        switch client.state {
        case .idle: return "Offline"
        case .connecting: return "Connecting"
        case .connected: return client.macName
        case .waiting(let s): return "Retry in \(s)s"
        case .rejected: return "Pair again"
        }
    }

    private var color: Color {
        if client.isInProcess { return .accentColor }
        switch client.state {
        case .connected: return RemoteTheme.success
        case .connecting, .waiting: return RemoteTheme.warning
        case .idle, .rejected: return RemoteTheme.danger
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
