import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Small building blocks shared by the Mac and iPhone apps

/// Activity spinner drawn in SwiftUI (renders in snapshots, unlike `ProgressView`).
public struct Spinner: View {
    var size: CGFloat
    var lineWidth: CGFloat
    var color: Color?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var spinning = false

    public init(size: CGFloat = 12, lineWidth: CGFloat = 1.6, color: Color? = nil) {
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        Circle()
            .trim(from: 0.18, to: 1)
            .stroke(color ?? theme.textSecondary, style: StrokeStyle(lineWidth: theme.z(lineWidth), lineCap: .round))
            .frame(width: theme.z(size), height: theme.z(size))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !isSnapshot else { return }
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityLabel("Working")
    }
}

/// Small switch like the one in the context panel (28 x 16 pt).
public struct CompactSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: Configuration
        @Environment(\.theme) private var theme

        var body: some View {
            HStack(spacing: theme.z(8)) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? theme.accent : theme.switchOffTrack)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: theme.z(0.5), y: theme.z(0.5))
                        .padding(theme.z(2))
                }
                .frame(width: theme.z(28), height: theme.z(16))
                .contentShape(Capsule())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

/// Filled accent button ("Allow once", "Save", "Create").
public struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color?
    public init(tint: Color? = nil) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color?
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(theme.font(size: 12.5, weight: .medium))
                // A disabled button dims its label as well as its fill, so it does not read as ready to press.
                .foregroundStyle(theme.onAccent.opacity(isEnabled ? 1 : 0.55))
                .padding(.horizontal, theme.z(12))
                .frame(height: theme.z(28))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                        .fill(tint ?? theme.accent)
                        .brightness(isEnabled && hovering && !configuration.isPressed ? 0.06 : 0)
                        .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Quiet bordered button ("Always allow", "Reject", "Cancel").
public struct SecondaryButtonStyle: ButtonStyle {
    var foreground: Color?
    public init(foreground: Color? = nil) { self.foreground = foreground }

    public func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, foreground: foreground)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let foreground: Color?
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(foreground ?? theme.textPrimary)
                .padding(.horizontal, theme.z(12))
                .frame(height: theme.z(28))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                        .fill(hovering || configuration.isPressed ? theme.elevatedHover : theme.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Plain row button with a hover and selected background (sidebar rows, menu rows).
public struct RowButtonStyle: ButtonStyle {
    var selected: Bool
    var cornerRadius: CGFloat
    /// True for rows on a popover, menu or card: uses the raised hover and selection fills, which stay visible there in dark mode.
    var raised: Bool
    public init(selected: Bool = false, cornerRadius: CGFloat = 7, raised: Bool = false) {
        self.selected = selected
        self.cornerRadius = cornerRadius
        self.raised = raised
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, selected: selected, cornerRadius: cornerRadius, raised: raised)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let selected: Bool
        let cornerRadius: CGFloat
        let raised: Bool
        @Environment(\.theme) private var theme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(selected ? (raised ? theme.raisedSelection : theme.selection)
                              : (hovering || configuration.isPressed ? (raised ? theme.raisedHover : theme.hover) : .clear))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// Square icon button with a hover background (toolbar-like buttons).
public struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat
    var active: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    public init(_ systemName: String, help: String, size: CGFloat = 28, active: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(theme.font(size: 14, weight: .regular))
                .foregroundStyle(active ? theme.textPrimary : theme.textSecondary)
                .frame(width: theme.z(size), height: theme.z(size))
                .background(
                    RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                        .fill(hovering ? theme.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Rounded-square letter avatar used for connectors and providers.
public struct LetterAvatar: View {
    let text: String
    var size: CGFloat
    @Environment(\.theme) private var theme

    public init(_ name: String, size: CGFloat = 16) {
        self.text = name.first.map { String($0).uppercased() } ?? "?"
        self.size = size
    }

    public var body: some View {
        Text(text)
            .font(theme.font(size: size * 0.6, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .frame(width: theme.z(size), height: theme.z(size))
            .background(
                RoundedRectangle(cornerRadius: theme.z(size * 0.28), style: .continuous)
                    .strokeBorder(theme.isDark ? Color(hex: 0x2A2A2A) : theme.border, lineWidth: 1)
            )
    }
}

public struct StatusDot: View {
    let color: Color
    var size: CGFloat
    @Environment(\.theme) private var theme
    public init(_ color: Color, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }
    public var body: some View {
        Circle().fill(color).frame(width: theme.z(size), height: theme.z(size))
    }
}

/// Count badge (needs-you count).
public struct CountBadge: View {
    let count: Int
    var color: Color?
    @Environment(\.theme) private var theme
    public init(_ count: Int, color: Color? = nil) {
        self.count = count
        self.color = color
    }
    public var body: some View {
        Text("\(count)")
            .font(theme.font(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, theme.z(5))
            .frame(minWidth: theme.z(17), minHeight: theme.z(17))
            .background(Capsule().fill(color ?? theme.accent))
            .accessibilityLabel("\(count) waiting for you")
    }
}

/// 1 pt horizontal line.
public struct HLine: View {
    var color: Color?
    @Environment(\.theme) private var theme
    public init(color: Color? = nil) { self.color = color }
    public var body: some View {
        Rectangle().fill(color ?? theme.separator).frame(height: 1)
    }
}

/// 1 pt vertical line.
public struct VLine: View {
    var color: Color?
    @Environment(\.theme) private var theme
    public init(color: Color? = nil) { self.color = color }
    public var body: some View {
        Rectangle().fill(color ?? theme.separator).frame(width: 1)
    }
}

/// A scroll view that becomes a clipped stack while rendering snapshots
/// (`ImageRenderer` cannot draw platform scroll views).
public struct AdaptiveScroll<Content: View>: View {
    let axes: Axis.Set
    let snapshotAlignment: Alignment
    let content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    public init(_ axes: Axis.Set = .vertical, snapshotAlignment: Alignment = .top, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.snapshotAlignment = snapshotAlignment
        self.content = content()
    }

    public var body: some View {
        if isSnapshot {
            content
                .fixedSize(horizontal: axes.contains(.horizontal), vertical: axes.contains(.vertical))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: axes.contains(.vertical) ? 0 : nil,
                       maxHeight: axes.contains(.vertical) ? .infinity : nil, alignment: snapshotAlignment)
                .clipped()
        } else {
            ScrollView(axes) { content }
        }
    }
}

/// Text field with Ensemble's rounded look. Draws a static copy in snapshots.
public struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool
    var monospaced: Bool
    var icon: String?
    var height: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    public init(_ placeholder: String, text: Binding<String>, secure: Bool = false, monospaced: Bool = false,
                icon: String? = nil, height: CGFloat = 28) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.monospaced = monospaced
        self.icon = icon
        self.height = height
    }

    public var body: some View {
        HStack(spacing: theme.z(6)) {
            if let icon {
                Image(systemName: icon)
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
            }
            field
        }
        .padding(.horizontal, theme.z(9))
        .frame(height: theme.z(height))
        .background(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var font: Font {
        monospaced ? theme.font(size: 12.5, design: .monospaced) : theme.font(size: 13)
    }

    @ViewBuilder private var field: some View {
        if isSnapshot {
            Group {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(theme.textTertiary)
                } else {
                    Text(secure ? String(repeating: "\u{2022}", count: min(24, text.count)) : text)
                        .foregroundStyle(theme.textPrimary)
                }
            }
            .font(font)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if secure {
            SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary))
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(theme.textPrimary)
        } else {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary))
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
        }
    }
}

public extension View {
    /// Enables text selection except in snapshots (selectable text is platform-backed on macOS).
    func selectableText() -> some View { modifier(SelectableText()) }
}

private struct SelectableText: ViewModifier {
    @Environment(\.isSnapshot) private var isSnapshot
    func body(content: Content) -> some View {
        if isSnapshot { content } else { content.textSelection(.enabled) }
    }
}

// MARK: - Layouts for narrow places

/// Children left to right, starting a new line when the next one would not fit, so a row of buttons in a narrow card
/// (a split pane, a large zoom) wraps instead of cutting a label to "Allow o...". Each child gets its ideal width, or
/// the row's width when that is less. Lines are leading-aligned; children are centred on their line.
public struct FlowRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    public init(spacing: CGFloat, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(width: CGFloat?, subviews: Subviews) -> [Line] {
        let limit = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > limit { size = subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil)) }
            if !line.items.isEmpty, line.width + spacing + size.width > limit {
                lines.append(line)
                line = Line()
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(width: proposal.width, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2), anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

/// Side padding that tightens when the offered width is under `threshold` (a narrow split pane), around content at
/// most `maxContentWidth` wide and centred. Takes the whole offered width, or more when the content cannot fit in it,
/// so a parent that clips cuts both edges evenly.
public struct AdaptiveInset: Layout {
    var wide: CGFloat
    var narrow: CGFloat
    var threshold: CGFloat
    var maxContentWidth: CGFloat

    public init(wide: CGFloat, narrow: CGFloat, below threshold: CGFloat, maxContentWidth: CGFloat = .infinity) {
        self.wide = wide
        self.narrow = narrow
        self.threshold = threshold
        self.maxContentWidth = maxContentWidth
    }

    /// The padding on each side at this width (the wide one when the width is not known).
    public func inset(for width: CGFloat?) -> CGFloat {
        guard let width else { return wide }
        return width < threshold ? narrow : wide
    }

    private func contentProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        let inset = inset(for: proposal.width)
        return ProposedViewSize(width: proposal.width.map { min(max(0, $0 - 2 * inset), maxContentWidth) }, height: proposal.height)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews.reduce(CGSize.zero) { size, child in
            let fitted = child.sizeThatFits(contentProposal(proposal))
            return CGSize(width: max(size.width, fitted.width), height: max(size.height, fitted.height))
        }
        let needed = content.width + 2 * inset(for: proposal.width)
        return CGSize(width: max(needed, proposal.width ?? 0), height: content.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The same padding as when measured: an overflowing child makes the bounds wider than the offer.
        let content = contentProposal(ProposedViewSize(width: proposal.width ?? bounds.width, height: bounds.height))
        for child in subviews {
            child.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: content)
        }
    }
}

/// Copies plain text to the system pasteboard.
@MainActor public func copyToPasteboard(_ text: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
}

// MARK: - Permission mode presentation

public extension PermissionMode {
    var symbolName: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil.line"
        case .plan: "list.bullet.clipboard"
        case .auto: "wand.and.sparkles"
        case .bypass: "exclamationmark.shield"
        }
    }

    /// One line on what the mode allows.
    var summary: String {
        switch self {
        case .ask: "Edits and commands ask you first"
        case .acceptEdits: "File edits run, commands ask"
        case .plan: "Reads and plans, changes nothing"
        case .auto: "Safe actions run, risky commands ask"
        case .bypass: "Everything runs without asking"
        }
    }

    var isDangerous: Bool { self == .bypass }

    /// The next mode for Shift-Tab cycling.
    var next: PermissionMode {
        let all = PermissionMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}
