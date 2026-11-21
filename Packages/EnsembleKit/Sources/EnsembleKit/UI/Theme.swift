import SwiftUI

/// Ensemble's colours. Dark is the default; light follows the same structure.
/// Views read it with `@Environment(\.theme)`; `.ensembleTheme()` picks the palette from the colour scheme.
public struct Theme: Sendable {
    public var isDark: Bool
    /// Window zoom (1 = 100%). Every font size and metric goes through `font(size:)` and `z(_:)`,
    /// so zooming re-lays out crisp text and controls instead of scaling a bitmap.
    public var scale: CGFloat = 1
    /// The font agents write in, chosen in Settings (`FontStore`). `.ensembleTheme()` fills it in.
    public var chatFont: AppFont = FontRole.chat.standard
    /// The font of everything else, chosen the same way.
    public var interfaceFont: AppFont = FontRole.interface.standard

    // Surfaces
    public var sidebar: Color
    public var background: Color
    public var panel: Color
    public var elevated: Color
    public var elevatedHover: Color
    public var codeBackground: Color
    public var inlineCodeBackground: Color
    public var userBubble: Color
    public var popover: Color

    // Lines and states
    public var separator: Color
    public var border: Color
    public var selection: Color
    public var hover: Color
    public var track: Color

    // Text
    public var textPrimary: Color
    public var textSidebar: Color
    public var textSecondary: Color
    public var textTertiary: Color
    public var inlineCodeText: Color

    // Signals
    public var accent: Color
    public var onAccent: Color
    public var danger: Color
    public var success: Color
    public var warning: Color

    // Diffs
    public var diffAddBackground: Color
    public var diffRemoveBackground: Color
    public var diffAddText: Color
    public var diffRemoveText: Color
    public var diffHunkBackground: Color

    // Syntax
    public var syntaxKeyword: Color
    public var syntaxString: Color
    public var syntaxComment: Color
    public var syntaxNumber: Color
    public var syntaxType: Color

    // Context categories
    public var contextBlue: Color
    public var contextOrange: Color
    public var contextTeal: Color
    public var contextAmber: Color
    public var contextGrey: Color
    public var contextBuffer: Color

    public static let dark = Theme(
        isDark: true,
        sidebar: Color(hex: 0x171716),
        background: Color(hex: 0x1D1C1B),
        panel: Color(hex: 0x181818),
        elevated: Color(hex: 0x252423),
        elevatedHover: Color(hex: 0x2C2B29),
        codeBackground: Color(hex: 0x151514),
        inlineCodeBackground: Color(hex: 0x2E2D2B),
        userBubble: Color(hex: 0x2A2927),
        popover: Color(hex: 0x262524),
        separator: Color(hex: 0x262625),
        border: Color(hex: 0x323130),
        selection: Color(hex: 0x2A2928),
        hover: Color(hex: 0x222120),
        track: Color(hex: 0x2B2B2B),
        textPrimary: Color(hex: 0xF3F3F3),
        textSidebar: Color(hex: 0xD6D5D3),
        textSecondary: Color(hex: 0xA0A0A0),
        textTertiary: Color(hex: 0x8A8A8A),
        inlineCodeText: Color(hex: 0xE8E2FF),
        accent: Color(hex: 0x8B7CF6),
        onAccent: .white,
        danger: Color(hex: 0xF0524F),
        success: Color(hex: 0x3FB950),
        warning: Color(hex: 0xD99F38),
        diffAddBackground: Color(hex: 0x2EA043).opacity(0.16),
        diffRemoveBackground: Color(hex: 0xF85149).opacity(0.15),
        diffAddText: Color(hex: 0x56D364),
        diffRemoveText: Color(hex: 0xFF7B72),
        diffHunkBackground: Color(hex: 0x8B7CF6).opacity(0.08),
        syntaxKeyword: Color(hex: 0xC79BFF),
        syntaxString: Color(hex: 0x9FD08A),
        syntaxComment: Color(hex: 0x6E6E6E),
        syntaxNumber: Color(hex: 0xF0A35E),
        syntaxType: Color(hex: 0x7CC4FA),
        contextBlue: Color(hex: 0x328CF0),
        contextOrange: Color(hex: 0xE66624),
        contextTeal: Color(hex: 0x04A887),
        contextAmber: Color(hex: 0xD38E05),
        contextGrey: Color(hex: 0x959595),
        contextBuffer: Color(hex: 0x5E5E5E)
    )

    public static let light = Theme(
        isDark: false,
        sidebar: Color(hex: 0xF1F0ED),
        background: Color(hex: 0xFBFAF8),
        panel: Color(hex: 0xF6F5F2),
        elevated: Color(hex: 0xFFFFFF),
        elevatedHover: Color(hex: 0xF4F3F0),
        codeBackground: Color(hex: 0xF3F2EF),
        inlineCodeBackground: Color(hex: 0xECEAE6),
        userBubble: Color(hex: 0xEFEDE9),
        popover: Color(hex: 0xFFFFFF),
        separator: Color(hex: 0xE7E5E0),
        border: Color(hex: 0xDEDBD6),
        selection: Color(hex: 0xE4E2DD),
        hover: Color(hex: 0xEAE8E4),
        track: Color(hex: 0xE2E0DB),
        textPrimary: Color(hex: 0x1D1D1B),
        textSidebar: Color(hex: 0x2F2E2C),
        textSecondary: Color(hex: 0x6D6C69),
        textTertiary: Color(hex: 0x716F6B),
        inlineCodeText: Color(hex: 0x4B3BB0),
        accent: Color(hex: 0x6C54E8),
        onAccent: .white,
        danger: Color(hex: 0xD63A36),
        success: Color(hex: 0x1F8F3A),
        warning: Color(hex: 0xB8771A),
        diffAddBackground: Color(hex: 0x2EA043).opacity(0.13),
        diffRemoveBackground: Color(hex: 0xF85149).opacity(0.12),
        diffAddText: Color(hex: 0x1A7F37),
        diffRemoveText: Color(hex: 0xCF222E),
        diffHunkBackground: Color(hex: 0x6C54E8).opacity(0.07),
        syntaxKeyword: Color(hex: 0x8A3FD1),
        syntaxString: Color(hex: 0x2F7D32),
        syntaxComment: Color(hex: 0x9A9894),
        syntaxNumber: Color(hex: 0xB45A12),
        syntaxType: Color(hex: 0x1F6FB2),
        contextBlue: Color(hex: 0x2F80E4),
        contextOrange: Color(hex: 0xE0601E),
        contextTeal: Color(hex: 0x05977A),
        contextAmber: Color(hex: 0xC78404),
        contextGrey: Color(hex: 0xB4B2AE),
        contextBuffer: Color(hex: 0x8C8A86)
    )

    /// Interface font at `size` points times the zoom: the chosen interface font for the default design (Inter
    /// unless another is chosen), the system fonts for `.monospaced` (SF Mono) and the other designs.
    public func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        switch design {
        case .default:
            return interfaceFont.font(size: size * scale, weight: weight)
        default:
            return .system(size: size * scale, weight: weight, design: design)
        }
    }

    /// Font for what an agent writes: the chosen chat font, at the zoom. See `AppFont`.
    public func messageFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        chatFont.font(size: size * scale, weight: weight)
    }

    /// Letter spacing for agent text at `size` (the interface size passed to `messageFont`).
    public func messageTracking(_ size: CGFloat) -> CGFloat { chatFont.tracking(size) * scale }

    /// Extra space between lines of agent text at `size`.
    public func messageLineSpacing(_ size: CGFloat) -> CGFloat { chatFont.lineSpacing(size) * scale }

    /// A length (padding, row height, corner radius, icon size) times the zoom.
    public func z(_ value: CGFloat) -> CGFloat { value * scale }

    /// Fills for things that sit on a raised surface (a popover or a card). The plain `hover`, `selection` and
    /// `track` are tuned for the window background and the sidebar. In dark mode they are within a shade of the
    /// raised surfaces, so there they cannot be seen.
    public var raisedFill: Color { isDark ? Color.white.opacity(0.07) : hover }
    public var raisedHover: Color { isDark ? Color.white.opacity(0.05) : hover }
    public var raisedSelection: Color { isDark ? Color.white.opacity(0.10) : selection }
    /// The track of a switch that is off, visible on a card as well as on the window background.
    public var switchOffTrack: Color { isDark ? Color.white.opacity(0.16) : track }

    /// Colour for a context category key (see `ContextBreakdown.Category.key`).
    public func contextColor(for key: String) -> Color {
        switch key {
        case "messages": contextBlue
        case "tools", "mcp", "mcpTools": contextOrange
        case "systemTools": contextTeal
        case "systemPrompt": contextAmber
        case "buffer": contextBuffer
        case "free": track
        default: contextGrey
        }
    }
}

/// How agent text is set when no chat font has been chosen: `AppFont.standard` (Ensemble Serif, see
/// `EnsembleFonts` and tools/fonts/README.md), at the interface size with normal letter spacing and lines
/// about 1.6 times the type size apart. Views take the chosen font from `Theme.messageFont` instead.
public enum MessageType {
    public static let scale: CGFloat = AppFont.standard.scale
    public static let trackingRatio: CGFloat = AppFont.standard.trackingRatio
    public static let lineSpacingRatio: CGFloat = AppFont.standard.lineSpacingRatio

    /// The default chat font at `size` points (already zoomed or scaled for Dynamic Type), not scaled again.
    public static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        AppFont.standard.font(size: size, weight: weight)
    }

    /// The serif size that matches interface text of `size` points.
    public static func size(_ size: CGFloat) -> CGFloat { size * scale }
    public static func tracking(_ size: CGFloat) -> CGFloat { AppFont.standard.tracking(size) }
    public static func lineSpacing(_ size: CGFloat) -> CGFloat { AppFont.standard.lineSpacing(size) }
}


public extension Color {
    /// `Color(hex: 0x8B7CF6)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Parses `#RRGGBB` (as stored in `AgentSpec.colorHex`). Falls back to grey.
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self.init(hex: UInt32(cleaned, radix: 16) ?? 0x959595)
    }
}

public extension EnvironmentValues {
    @Entry var theme: Theme = .dark
    /// True while rendering PNG snapshots with `ImageRenderer`. Views swap platform-backed controls
    /// (scroll views, text fields) for plain SwiftUI equivalents so everything draws.
    @Entry var isSnapshot: Bool = false
    /// The session's folder, used to show paths relative to the project.
    @Entry var sessionDirectory: String = ""
    /// Window zoom factor (1 = 100%), read by `.ensembleTheme()`.
    @Entry var zoom: CGFloat = 1
}

/// Zoom steps for View > Zoom In / Zoom Out / Actual Size.
public enum Zoom {
    /// 70% to 200% in steps of 5%, so one press of Command-plus or Command-minus is a small change.
    public static let steps: [Double] = stride(from: 70, through: 200, by: 5).map { Double($0) / 100 }
    public static let storageKey = "zoom"

    public static func zoomIn(from current: Double) -> Double {
        steps.first { $0 > current + 0.001 } ?? steps.last ?? 1
    }

    public static func zoomOut(from current: Double) -> Double {
        steps.last { $0 < current - 0.001 } ?? steps.first ?? 1
    }

    /// Snaps a stored value to the nearest step.
    public static func clamped(_ value: Double) -> Double {
        steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    /// "125%".
    public static func label(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

private struct ThemeProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.zoom) private var zoom

    func body(content: Content) -> some View {
        var theme = scheme == .dark ? Theme.dark : Theme.light
        theme.scale = zoom
        // Read here, so every window that uses the theme redraws when a font choice changes.
        theme.chatFont = FontStore.shared.chat
        theme.interfaceFont = FontStore.shared.interface
        return content
            .environment(\.theme, theme)
            // Text that sets no font of its own (form labels, alerts inside the window) uses the interface font too.
            .font(theme.font(size: 13))
            .tint(scheme == .dark ? Theme.dark.accent : Theme.light.accent)
    }
}

public extension View {
    /// Sets `\.theme` from the current colour scheme, `\.zoom` and the chosen fonts.
    func ensembleTheme() -> some View { modifier(ThemeProvider()) }
}
