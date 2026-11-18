import SwiftUI

/// Colours and shapes for the iPhone remote: warm near-black, soft grey secondary text, rounded cards.
enum RemoteTheme {
    static let background = Color(red: 0.102, green: 0.098, blue: 0.094)      // #1A1918
    static let card = Color(red: 0.149, green: 0.145, blue: 0.137)            // #262523
    static let cardRaised = Color(red: 0.188, green: 0.184, blue: 0.173)      // #302F2C
    static let stroke = Color(red: 0.239, green: 0.231, blue: 0.220)          // #3D3B38
    static let primaryText = Color(red: 0.925, green: 0.918, blue: 0.894)     // #ECEAE4
    static let secondaryText = Color(red: 0.631, green: 0.620, blue: 0.592)   // #A19E97
    static let tertiaryText = Color(red: 0.459, green: 0.451, blue: 0.427)    // #75736D
    static let userBubble = Color(red: 0.200, green: 0.196, blue: 0.184)      // #33322F
    static let success = Color(red: 0.471, green: 0.722, blue: 0.494)
    static let warning = Color(red: 0.882, green: 0.690, blue: 0.333)
    static let danger = Color(red: 0.898, green: 0.420, blue: 0.392)

    static let cornerRadius: CGFloat = 14
}

extension Color {
    /// Parses `#RRGGBB`; grey when unreadable.
    init(remoteHex: String) {
        let cleaned = remoteHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let value = UInt32(cleaned, radix: 16) ?? 0x959595
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}

struct RemoteCard: ViewModifier {
    var padding: CGFloat = 14
    var selected = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RemoteTheme.cardRaised : RemoteTheme.card,
                        in: RoundedRectangle(cornerRadius: RemoteTheme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RemoteTheme.cornerRadius, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : RemoteTheme.stroke.opacity(0.6), lineWidth: selected ? 1.5 : 0.5))
    }
}

extension View {
    func remoteCard(padding: CGFloat = 14, selected: Bool = false) -> some View {
        modifier(RemoteCard(padding: padding, selected: selected))
    }

    /// Screen background for lists and scroll views.
    func remoteScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(RemoteTheme.background.ignoresSafeArea())
    }
}

/// Small rounded label, e.g. a room state or a permission kind.
struct Chip: View {
    var text: String
    var color: Color = RemoteTheme.secondaryText

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
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
        (path as NSString).lastPathComponent
    }
}
