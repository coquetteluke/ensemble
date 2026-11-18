import SwiftUI
import EnsembleKit

/// The main window: sidebar, centre (transcript and composer, or Hub / Scheduled), context panel.
struct MainView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    /// Snapshots pass a fixed value; the app uses the stored setting.
    var remoteControlOverride: Bool?

    @AppStorage("remoteControlEnabled") private var remoteControl = false
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    static let sidebarWidth: CGFloat = 260
    static let panelWidth: CGFloat = 303

    var body: some View {
        HStack(spacing: 0) {
            if window.showSidebar {
                SidebarView(store: store, window: window)
                    .frame(width: Self.sidebarWidth)
                    .transition(.move(edge: .leading))
                VLine()
            }
            CenterColumn(store: store, window: window)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsPanel {
                VLine()
                ContextPanelView(store: store, session: store.selected, remoteControl: remoteControlBinding)
                    .frame(width: Self.panelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(theme.background)
        .overlay(alignment: .topLeading) { if isSnapshot { SnapshotWindowChrome(window: window) } }
        .ignoresSafeArea()
        .environment(\.transcriptActions, actions)
        .navigationTitle(store.selected?.title ?? "Ensemble")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                IconButton("sidebar.left", help: window.showSidebar ? "Hide sidebar" : "Show sidebar", size: 28) {
                    window.toggleSidebar()
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                IconButton("sidebar.right", help: window.showContextPanel ? "Hide context panel (Option-Command-I)" : "Show context panel (Option-Command-I)",
                           size: 28, active: window.showContextPanel) {
                    window.toggleContextPanel()
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $window.showNewSession) {
            NewSessionSheet(store: store, window: window)
                .ensembleTheme()
        }
        .alert("Something went wrong", isPresented: errorShown, presenting: store.lastError) { _ in
            Button("OK") { store.lastError = nil }
        } message: { message in
            Text(message)
        }
    }

    private var showsPanel: Bool { window.showContextPanel && window.route == .session }

    private var remoteControlBinding: Binding<Bool> {
        if let remoteControlOverride { return .constant(remoteControlOverride) }
        return $remoteControl
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { store.lastError != nil && !isSnapshot }, set: { if !$0 { store.lastError = nil } })
    }

    private var actions: TranscriptActions {
        let store = store
        let window = window
        return TranscriptActions(
            openSession: { id in window.open(id, store: store) },
            replyPermission: { request, decision in Task { await store.reply(to: request, decision: decision) } }
        )
    }
}

/// Centre column: header, then the conversation or a placeholder screen.
struct CenterColumn: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            CenterHeader(store: store, window: window)
            switch window.route {
            case .session:
                if let session = store.selected {
                    ConversationView(store: store, session: session, window: window)
                } else {
                    EmptySessionView(store: store, window: window)
                }
            case .hub:
                HubPlaceholderView(store: store, window: window)
            case .scheduled:
                ScheduledPlaceholderView(store: store)
            }
        }
        .background(theme.background)
    }
}

/// Title row in the window's title bar area.
struct CenterHeader: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if !window.showSidebar {
                Color.clear.frame(width: 110, height: 1)
            }
            switch window.route {
            case .session:
                if let session = store.selected {
                    if let parentID = session.info.parentID, let parent = store.session(parentID) {
                        Button {
                            window.open(parent.id, store: store)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                                Text(parent.title).lineLimit(1)
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        Text("/").foregroundStyle(theme.textTertiary)
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.accent)
                    }
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(Format.abbreviatedPath(session.directory))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            case .hub:
                Text("Session Hub").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            case .scheduled:
                Text("Scheduled").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            }
            Spacer(minLength: 60)
        }
        .padding(.leading, 20)
        .frame(height: 52)
        .background(theme.background)
        .zIndex(1)
    }
}

/// Shown when no session is selected.
struct EmptySessionView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text(store.isLoaded ? "No session selected" : "Loading sessions")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            if store.isLoaded {
                Button("New session") { window.beginNewSession() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Traffic lights and toolbar buttons drawn into snapshots (real windows draw their own).
struct SnapshotWindowChrome: View {
    let window: WindowState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12, height: 12)
            Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12, height: 12)
            Circle().fill(Color(hex: 0x28C840)).frame(width: 12, height: 12)
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 22)
        }
        .padding(.leading, 20)
        .frame(height: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14))
                .foregroundStyle(window.showContextPanel ? theme.textPrimary : theme.textSecondary)
                .padding(.trailing, 20)
        }
        .allowsHitTesting(false)
    }
}
