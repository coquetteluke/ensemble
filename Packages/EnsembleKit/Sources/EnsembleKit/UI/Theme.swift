import SwiftUI

/// Ensemble's colours. Dark is the default; light follows the same structure.
/// Views read it with `@Environment(\.theme)`; `.ensembleTheme()` picks the palette from the colour scheme.
public struct Theme: Sendable {
    public var isDark: Bool

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
        textTertiary: Color(hex: 0x787878),
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
        textTertiary: Color(hex: 0x9A9894),
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

/// Type sizes. The app uses the system font (SF Pro) throughout.
public enum EFont {
    public static let body = Font.system(size: 13)
    public static let bodyMedium = Font.system(size: 13, weight: .medium)
    public static let transcript = Font.system(size: 14)
    public static let small = Font.system(size: 12)
    public static let caption = Font.system(size: 11.5)
    public static let mono = Font.system(size: 12.5, design: .monospaced)
    public static let monoSmall = Font.system(size: 12, design: .monospaced)
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
}

private struct ThemeProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .environment(\.theme, scheme == .dark ? .dark : .light)
            .tint(scheme == .dark ? Theme.dark.accent : Theme.light.accent)
    }
}

public extension View {
    /// Sets `\.theme` from the current colour scheme.
    func ensembleTheme() -> some View { modifier(ThemeProvider()) }
}
