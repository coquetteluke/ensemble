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
            .lineLimit(1)
    }
}

/// Title above a group of sessions: a project folder, a state or a date range. Collapses on click; a
/// project header also offers "new session here" on hover, and can be dragged up or down (or moved with its
/// context menu) when sessions are grouped by project.
struct SidebarGroupHeader: View {
    enum Icon {
        case symbol(String)
        case dot(Color)
    }

    /// Moving a folder: Move Up and Move Down (disabled at the ends) and dragging the header.
    struct Move {
        var canMoveUp: Bool
        var canMoveDown: Bool
        /// -1 moves up one place, 1 down.
        var onMove: (Int) -> Void
        var onDragStart: () -> Void
    }

    let icon: Icon
    let title: String
    let help: String?
    let collapsed: Bool
    let onToggle: () -> Void
    var onNew: (() -> Void)?
    var move: Move?
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var newHovering = false

    var body: some View {
        HStack(spacing: theme.z(6)) {
            // Not a Button: a button keeps the mouse-down a drag needs. A tap toggles, like a button would.
            HStack(spacing: theme.z(6)) {
                leading
                    .frame(width: theme.z(14))
                Text(title)
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .help(help ?? title)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(collapsed ? "Show \(title)" : "Hide \(title)")
            .accessibilityAction { onToggle() }
            .modifier(FolderMoveModifier(dragText: help ?? title, move: move))

            if hovering, let onNew {
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(newHovering ? theme.textPrimary : theme.textSecondary)
                        .frame(width: theme.z(20), height: theme.z(20))
                        .background(
                            RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                                .fill(newHovering ? theme.hover : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { newHovering = $0 }
                .help("New session in \(title)")
            }
        }
        .padding(.leading, theme.z(10))
        .padding(.trailing, theme.z(6))
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

/// Dragging, Move Up and Move Down for a folder header; nothing when the folder cannot move.
private struct FolderMoveModifier: ViewModifier {
    /// What a drop into another app gets: the folder's path.
    let dragText: String
    let move: SidebarGroupHeader.Move?

    func body(content: Content) -> some View {
        if let move {
            content
                .onDrag {
                    move.onDragStart()
                    return NSItemProvider(object: dragText as NSString)
                }
                .contextMenu {
                    Button("Move Up") { move.onMove(-1) }
                        .disabled(!move.canMoveUp)
                    Button("Move Down") { move.onMove(1) }
                        .disabled(!move.canMoveDown)
                }
                .accessibilityAction(named: Text("Move Up")) { if move.canMoveUp { move.onMove(-1) } }
                .accessibilityAction(named: Text("Move Down")) { if move.canMoveDown { move.onMove(1) } }
        } else {
            content
        }
    }
}

/// The "Group and sort" button on the Sessions header: group by project, state or date; sort by recent
/// activity, name or created; when grouping by project with folders dragged into an order, go back to the automatic one.
struct GroupAndSortMenu: View {
    @Binding var grouping: String
    @Binding var sort: String
    var hasManualFolderOrder = false
    var onClearFolderOrder: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var hovering = false

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
            if hasManualFolderOrder, grouping == SidebarGrouping.project.rawValue {
                Divider()
                Button("Clear Manual Folder Order", action: onClearFolderOrder)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(hovering ? theme.textSecondary : theme.textTertiary)
                .frame(width: theme.z(20), height: theme.z(20))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(5), style: .continuous)
                        .fill(hovering ? theme.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Group and sort")
        .accessibilityLabel("Group and sort")
    }
}
