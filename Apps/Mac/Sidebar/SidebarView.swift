import SwiftUI
import EnsembleKit

/// Left sidebar: New session, Session Hub, Scheduled, search, projects with their sessions, Settings.
struct SidebarView: View {
    let store: SessionStore
    @Bindable var window: WindowState
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var renaming: SessionModel?
    @State private var renameText = ""
    @State private var deleting: SessionModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar area: traffic lights and the sidebar toolbar button live here.
            Color.clear.frame(height: 52)

            VStack(spacing: 1) {
                SidebarNavRow(symbol: "plus", title: "New session", accentIcon: true, shortcut: "\u{2318}N") {
                    window.beginNewSession()
                }
                SidebarNavRow(symbol: "square.grid.2x2", title: "Session Hub", selected: window.route == .hub,
                              badge: store.needsYouTotal) {
                    window.route = .hub
                }
                SidebarNavRow(symbol: "clock", title: "Scheduled", selected: window.route == .scheduled,
                              trailing: store.schedules.isEmpty ? nil : "\(store.schedules.filter { !$0.paused }.count)") {
                    window.route = .scheduled
                }
            }
            .padding(.horizontal, 8)

            InputField("Search sessions", text: $window.searchText, icon: "magnifyingglass", height: 28)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)

            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredProjects) { project in
                        projectSection(project)
                    }
                    if filteredProjects.isEmpty && store.isLoaded {
                        Text(window.searchText.isEmpty ? "No sessions yet" : "No matches")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HLine()
            footer
        }
        .background(theme.sidebar)
        .alert("Rename session", isPresented: renameShown) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let session = renaming { Task { await store.rename(session.id, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this session?", isPresented: deleteShown, presenting: deleting) { session in
            Button("Delete \"\(session.title)\"", role: .destructive) {
                Task { await store.delete(session.id) }
                deleting = nil
            }
        } message: { _ in
            Text("The transcript is removed from the engine. This cannot be undone.")
        }
    }

    // MARK: Projects

    private var filteredProjects: [ProjectGroup] {
        let query = window.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.projects }
        return store.projects.compactMap { project in
            if project.name.localizedCaseInsensitiveContains(query) { return project }
            let matches = project.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return matches.isEmpty ? nil : ProjectGroup(id: project.id, directory: project.directory, name: project.name, sessions: matches)
        }
    }

    private func projectSection(_ project: ProjectGroup) -> some View {
        let collapsed = window.collapsedProjects.contains(project.id) && window.searchText.isEmpty
        return VStack(alignment: .leading, spacing: 1) {
            ProjectHeader(name: project.name, path: project.directory, collapsed: collapsed,
                          onToggle: {
                              if collapsed { window.collapsedProjects.remove(project.id) } else { window.collapsedProjects.insert(project.id) }
                          },
                          onNew: { window.beginNewSession(in: project.directory) })
            if !collapsed {
                ForEach(project.sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: SessionModel) -> some View {
        let selectedID = store.selected.map { $0.info.parentID ?? $0.id }
        let colors = (store.sessionAgentIDs[session.id] ?? []).compactMap { store.agents[$0] }.map { Color(hexString: $0.colorHex) }
        return SessionRow(session: session,
                          selected: window.route == .session && selectedID == session.id,
                          needsYou: store.needsYouCount(session.id),
                          running: store.isRunning(session.id),
                          agentColors: colors) {
            window.open(session.id, store: store)
        }
        .contextMenu {
            Button("Rename") {
                renameText = session.title
                renaming = session
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
            }
            Divider()
            Button("Archive") { Task { await store.archive(session.id) } }
            Button("Delete", role: .destructive) { deleting = session }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                openSettings()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 18)
                    Text("Settings")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSidebar)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
            }
            .buttonStyle(RowButtonStyle())
            .help("Settings (Command-,)")

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                StatusDot(engineColor, size: 6)
                Text(engineLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            .help(store.isPreview ? "Using built-in sample data. No engine is connected." : "OpenCode engine")
            .padding(.trailing, 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var engineLabel: String {
        if store.isPreview { return "Preview data" }
        if let version = store.engineVersion { return "Engine \(version)" }
        return "Engine offline"
    }

    private var engineColor: Color {
        if store.isPreview { return theme.warning }
        return store.engineVersion == nil ? theme.danger : theme.success
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil && !isSnapshot }, set: { if !$0 { renaming = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil && !isSnapshot }, set: { if !$0 { deleting = nil } })
    }
}

/// New session, Session Hub and Scheduled rows.
struct SidebarNavRow: View {
    let symbol: String
    let title: String
    var selected = false
    var accentIcon = false
    var badge = 0
    var trailing: String?
    var shortcut: String?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if accentIcon {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(theme.accent))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.system(size: 13, weight: accentIcon ? .medium : .regular))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSidebar)
                Spacer(minLength: 4)
                if badge > 0 {
                    CountBadge(badge)
                } else if let shortcut, hovering {
                    Text(shortcut)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                } else if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .onHover { hovering = $0 }
    }
}

/// Folder name above its sessions, with collapse and "new session here" on hover.
struct ProjectHeader: View {
    let name: String
    let path: String
    let collapsed: Bool
    let onToggle: () -> Void
    let onNew: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: hovering ? (collapsed ? "chevron.right" : "chevron.down") : "folder")
                        .font(.system(size: hovering ? 9 : 11, weight: hovering ? .bold : .regular))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 14)
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Format.abbreviatedPath(path))

            if hovering {
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New session in \(name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .onHover { hovering = $0 }
    }
}

/// One session in the sidebar: agent dots, title, and a needs-you badge, spinner or age.
struct SessionRow: View {
    let session: SessionModel
    let selected: Bool
    let needsYou: Int
    let running: Bool
    let agentColors: [Color]
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !agentColors.isEmpty {
                    HStack(spacing: -2) {
                        ForEach(Array(agentColors.prefix(4).enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(selected ? theme.selection : theme.sidebar, lineWidth: 1.5))
                        }
                    }
                }
                Text(session.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSidebar)
                    .lineLimit(1)
                Spacer(minLength: 6)
                trailing
            }
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .frame(height: 30)
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var trailing: some View {
        if needsYou > 0 {
            CountBadge(needsYou)
        } else if running {
            Spinner(size: 11)
        } else if session.activity == .failed {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.danger)
        } else {
            Text(Format.relative(session.info.updated))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var accessibilityText: String {
        var parts = [session.title]
        if needsYou > 0 { parts.append("\(needsYou) waiting for you") }
        if running { parts.append("running") }
        return parts.joined(separator: ", ")
    }
}
