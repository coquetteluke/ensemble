import SwiftUI
import EnsembleKit

/// Small grey section title ("Pinned", "Sessions"), optionally collapsible, with controls on the right.
struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    /// nil when the section cannot collapse.
    let collapsed: Bool?
    let onToggle: () -> Void
    @ViewBuilder let accessory: Accessory
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(4)) {
            if let collapsed {
                Button(action: onToggle) {
                    HStack(spacing: theme.z(4)) {
                        label
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(theme.font(size: 8, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                            .opacity(hovering || collapsed ? 1 : 0)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "Show \(title)" : "Hide \(title)")
            } else {
                label
                Spacer(minLength: 0)
            }
            accessory
        }
        .padding(.leading, theme.z(10))
        .padding(.trailing, theme.z(6))
        .frame(height: theme.z(24))
        .onHover { hovering = $0 }
    }

    private var label: some View {
        Text(title)
            .font(theme.font(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textTertiary)
    }
}

/// Title above a group of sessions: a project folder, a state or a date range. Collapses on click; a
/// project header also offers "new session here" on hover.
struct SidebarGroupHeader: View {
    enum Icon {
        case symbol(String)
        case dot(Color)
    }

    let icon: Icon
    let title: String
    let help: String?
    let collapsed: Bool
    let onToggle: () -> Void
    var onNew: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(6)) {
            Button(action: onToggle) {
                HStack(spacing: theme.z(6)) {
                    leading
                        .frame(width: theme.z(14))
                    Text(title)
                        .font(theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help ?? title)
            .accessibilityLabel(collapsed ? "Show \(title)" : "Hide \(title)")

            if hovering, let onNew {
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: theme.z(20), height: theme.z(20))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New session in \(title)")
            }
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(26))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var leading: some View {
        if hovering {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(theme.font(size: 9, weight: .bold))
                .foregroundStyle(theme.textTertiary)
        } else {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textTertiary)
            case .dot(let color):
                StatusDot(color, size: 7)
            }
        }
    }
}

/// The "Group and sort" button on the Sessions header: group by project, state or date; sort by recent
/// activity, name or created.
struct GroupAndSortMenu: View {
    @Binding var grouping: String
    @Binding var sort: String
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            Section("Group by") {
                Picker("Group by", selection: $grouping) {
                    ForEach(SidebarGrouping.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Sort by") {
                Picker("Sort by", selection: $sort) {
                    ForEach(SidebarSort.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.z(20), height: theme.z(20))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group and sort")
        .accessibilityLabel("Group and sort")
    }
}
