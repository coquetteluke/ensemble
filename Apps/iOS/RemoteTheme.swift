import EnsembleKit
import SwiftUI
import UIKit

/// Adaptive design tokens and reusable components for the iPhone Remote, matching Ensemble Mac's warm craft in both
/// light and dark appearance.
enum RemoteTheme {
    // MARK: Surfaces
    static let background = Color(light: 0xFBFAF8, dark: 0x1D1C1B)
    static let sidebar = Color(light: 0xF1F0ED, dark: 0x171716)
    static let codeBackground = Color(light: 0xF3F2EF, dark: 0x151514)
    static let card = Color(light: 0xFFFFFF, dark: 0x252423)
    static let cardRaised = Color(light: 0xF4F3F0, dark: 0x2C2B29)
    static let inlineCodeBackground = Color(light: 0xECEAE6, dark: 0x2E2D2B)
    static let userBubble = Color(light: 0xEFEDE9, dark: 0x2A2927)
    static let selection = Color(light: 0xE4E2DD, dark: 0x2A2928)

    // MARK: Lines
    static let border = Color(light: 0xDEDBD6, dark: 0x323130)
    static let separator = Color(light: 0xE7E5E0, dark: 0x262625)
    static let stroke = border
    static let track = Color(light: 0xE2E0DB, dark: 0x2B2B2B)

    // MARK: Text
    static let primaryText = Color(light: 0x1D1D1B, dark: 0xF3F3F3)
    static let secondaryText = Color(light: 0x6D6C69, dark: 0xA0A0A0)
    static let tertiaryText = Color(light: 0x9A9894, dark: 0x787878)
    static let inlineCodeText = Color(light: 0x4B3BB0, dark: 0xE8E2FF)

    // MARK: Signals
    static let accent = Color(light: 0x6C54E8, dark: 0x8B7CF6)
    static let onAccent = Color.white
    static let success = Color(light: 0x1F8F3A, dark: 0x3FB950)
    static let warning = Color(light: 0xB8771A, dark: 0xD99F38)
    static let danger = Color(light: 0xD63A36, dark: 0xF0524F)
    static let info = Color(light: 0x2F80E4, dark: 0x328CF0)

    // MARK: Metrics
    static let cornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 14
    static let sectionGap: CGFloat = 20
    static let cardGap: CGFloat = 12
    static let screenHorizontalPadding: CGFloat = 16
    static let minTapTarget: CGFloat = 44

    // MARK: Typography
    static func registerFonts() {
        EnsembleFonts.register()
    }

    static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        switch design {
        case .default:
            EnsembleFonts.register()
            return .custom(EnsembleFonts.interface, size: size, relativeTo: textStyle).weight(weight)
        default:
            return .system(size: size, weight: weight, design: design)
        }
    }

    static func serifFont(size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        MessageType.font(size: size, weight: weight)
    }
}

// MARK: - Color helpers

extension Color {
    /// Adaptive sRGB colour that responds to system Light and Dark appearances.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    /// Parses `#RRGGBB`; falls back to neutral grey when unreadable.
    init(remoteHex: String) {
        let cleaned = remoteHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let value = UInt32(cleaned, radix: 16) ?? 0x959595
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Theme environment

private struct RemoteThemeProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = scheme == .dark ? Theme.dark : Theme.light
        content
            .environment(\.theme, theme)
            .tint(RemoteTheme.accent)
    }
}

extension View {
    func remoteThemeEnvironment() -> some View {
        modifier(RemoteThemeProvider())
    }
}

// MARK: - Cards & surfaces

enum RemoteCardHighlight {
    case none
    case selected
    case attention
}

struct RemoteCard: ViewModifier {
    var padding: CGFloat = RemoteTheme.cardPadding
    var cornerRadius: CGFloat = RemoteTheme.cornerRadius
    var highlight: RemoteCardHighlight = .none

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
    }

    private var backgroundColor: Color {
        switch highlight {
        case .selected: RemoteTheme.cardRaised
        case .attention, .none: RemoteTheme.card
        }
    }

    private var borderColor: Color {
        switch highlight {
        case .selected: RemoteTheme.accent
        case .attention: RemoteTheme.warning.opacity(0.65)
        case .none: RemoteTheme.border
        }
    }

    private var borderWidth: CGFloat {
        switch highlight {
        case .selected, .attention: 1.5
        case .none: 1
        }
    }
}

extension View {
    func remoteCard(
        padding: CGFloat = RemoteTheme.cardPadding,
        cornerRadius: CGFloat = RemoteTheme.cornerRadius,
        selected: Bool = false,
        attention: Bool = false
    ) -> some View {
        let highlight: RemoteCardHighlight = selected ? .selected : (attention ? .attention : .none)
        return modifier(RemoteCard(padding: padding, cornerRadius: cornerRadius, highlight: highlight))
    }

    /// Screen background for lists and scroll views.
    func remoteScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(RemoteTheme.background.ignoresSafeArea())
    }
}

// MARK: - Shared pills, dots, buttons, formatting

/// Small rounded capsule badge (room mode, phase, permission kind).
struct Chip: View {
    var text: String
    var color: Color = RemoteTheme.secondaryText
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(RemoteTheme.font(size: 10, weight: .semibold, relativeTo: .caption2))
            }
            Text(text)
                .font(RemoteTheme.font(size: 11.5, weight: .semibold, relativeTo: .caption2))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.24), lineWidth: 0.75))
        .fixedSize()
    }
}

/// Crisp status dot that pulses gently when active (respects Reduce Motion).
struct RemoteLiveDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.32))
                    .frame(width: size * 1.9, height: size * 1.9)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .opacity(pulse ? 0.15 : 0.7)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .onAppear {
            guard pulsing && !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Primary accent pill button with 44pt+ touch height.
struct RemotePrimaryButtonStyle: ButtonStyle {
    var tint: Color = RemoteTheme.accent
    var minHeight: CGFloat = RemoteTheme.minTapTarget

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, minHeight: minHeight)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        let minHeight: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(RemoteTheme.font(size: 14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint)
                        .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
                )
                .contentShape(Rectangle())
        }
    }
}

/// Secondary outlined button with 44pt+ touch height.
struct RemoteSecondaryButtonStyle: ButtonStyle {
    var foreground: Color = RemoteTheme.primaryText
    var border: Color = RemoteTheme.border
    var minHeight: CGFloat = RemoteTheme.minTapTarget

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, foreground: foreground, border: border, minHeight: minHeight)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let foreground: Color
        let border: Color
        let minHeight: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(RemoteTheme.font(size: 14, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(configuration.isPressed ? RemoteTheme.cardRaised : RemoteTheme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// Compact meter bar matching Ensemble Mac's PlanLimitRow bar.
struct RemoteMeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(RemoteTheme.track)
                if clamped > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: height)
    }
}

/// Monospace code preview container used in permissions and details.
struct RemoteCommandBox: View {
    let text: String
    var maxHeight: CGFloat? = nil

    var body: some View {
        Group {
            if let maxHeight {
                ViewThatFits(in: .vertical) {
                    commandText
                    ScrollView(.vertical) { commandText }
                }
                .frame(maxHeight: maxHeight)
            } else {
                commandText
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RemoteTheme.codeBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(RemoteTheme.border, lineWidth: 1)
        )
    }

    private var commandText: some View {
        Text(text)
            .font(RemoteTheme.font(size: 12.5, design: .monospaced, relativeTo: .footnote))
            .foregroundStyle(RemoteTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

enum RemoteFormat {
    static func cost(_ usd: Double) -> String {
        usd < 0.01 && usd > 0 ? "<$0.01" : usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000) : "\(n)"
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    static func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
