import CoreText
import SwiftUI

/// A typeface that can be chosen in Settings, for what agents write (`FontRole.chat`) or for everything else
/// (`FontRole.interface`). The choices live in `FontStore` and travel in `Theme.chatFont` and
/// `Theme.interfaceFont`.
public struct AppFont: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// Ships inside Ensemble under an open licence (`Resources/Fonts`).
        case bundled(family: String)
        /// The system font in a design: `.serif` is New York, `.default` is San Francisco.
        case system(Font.Design)
        /// Comes with macOS and iOS and is used by name. No file is bundled.
        case installed(family: String)
        /// Added on this device from a font file (`CustomFontLibrary`).
        case custom(family: String)
    }

    /// Saved in the device's settings, so it never changes for a font that ships.
    public let id: String
    public let name: String
    public let source: Source
    /// What a bundled font is built from, shown under its name.
    var origin: String?
    /// Size next to interface text of the same point size.
    public var scale: CGFloat = 1
    /// Extra space between lines, as a share of the type size.
    public var lineSpacingRatio: CGFloat = 0.36
    public var trackingRatio: CGFloat = 0

    /// The font at `size` points (already zoomed or scaled for Dynamic Type).
    public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch source {
        case .system(let design):
            return .system(size: size * scale, weight: weight, design: design)
        case .bundled(let family), .installed(let family), .custom(let family):
            EnsembleFonts.register()
            return .custom(family, fixedSize: size * scale).weight(weight)
        }
    }

    public func tracking(_ size: CGFloat) -> CGFloat { size * scale * trackingRatio }
    public func lineSpacing(_ size: CGFloat) -> CGFloat { size * scale * lineSpacingRatio }

    /// Where the font comes from, in a few words.
    public var detail: String {
        switch source {
        case .bundled: origin ?? "Comes with Ensemble"
        case .system(let design): design == .serif ? "System serif" : "System sans"
        case .installed: "Comes with \(Self.systemName)"
        case .custom: "Added from a file"
        }
    }

    public var isCustom: Bool {
        if case .custom = source { return true }
        return false
    }

    /// False for a family this system does not have, such as an added font whose file was removed.
    public var isAvailable: Bool {
        switch source {
        case .system: true
        case .bundled(let family), .installed(let family), .custom(let family): EnsembleFonts.hasFamily(family)
        }
    }

    private static var systemName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }
}

public extension AppFont {
    static let ensembleSerif = AppFont(id: "ensemble-serif", name: "Ensemble Serif",
                                       source: .bundled(family: EnsembleFonts.serif), origin: "Built from Roboto Serif")
    static let sourceSerif4 = AppFont(id: "source-serif-4", name: "Source Serif 4",
                                      source: .bundled(family: EnsembleFonts.sourceSerif), origin: "By Adobe",
                                      lineSpacingRatio: lineSpacingRatio(forFamily: EnsembleFonts.sourceSerif))
    static let newYork = AppFont(id: "system-serif", name: "New York", source: .system(.serif), lineSpacingRatio: 0.4)
    static let charter = installed(id: "charter", family: "Charter")
    static let iowan = installed(id: "iowan-old-style", family: "Iowan Old Style")
    static let georgia = installed(id: "georgia", family: "Georgia")
    static let palatino = installed(id: "palatino", family: "Palatino")
    static let sanFrancisco = AppFont(id: "system-sans", name: "San Francisco", source: .system(.default), lineSpacingRatio: 0.4)
    static let inter = AppFont(id: "inter", name: "Inter",
                                source: .bundled(family: EnsembleFonts.interface), origin: "By Rasmus Andersson",
                                lineSpacingRatio: 0.38)
    static let avenirNext = installed(id: "avenir-next", family: "Avenir Next")

    /// The default chat font. `FontRole.standard` has the default of each role.
    static let standard = ensembleSerif

    /// The fonts Ensemble offers without adding a file: serifs first, then sans.
    static let builtIn: [AppFont] = [
        ensembleSerif, sourceSerif4, newYork, charter, iowan, georgia, palatino,
        sanFrancisco, inter, avenirNext,
    ]

    /// The built-in fonts this system has. A system font that a platform lacks is left out.
    static let availableBuiltIn: [AppFont] = builtIn.filter(\.isAvailable)

    /// A font added from a file, listed under its family name.
    static func custom(family: String) -> AppFont {
        AppFont(id: customIDPrefix + family, name: family, source: .custom(family: family),
                 lineSpacingRatio: lineSpacingRatio(forFamily: family))
    }

    /// A font that comes with macOS and iOS, used by its family name.
    private static func installed(id: String, family: String) -> AppFont {
        AppFont(id: id, name: family, source: .installed(family: family),
                 lineSpacingRatio: lineSpacingRatio(forFamily: family))
    }

    /// The extra line space that sets lines of `family` about 1.6 times the type size apart. Fonts ask for very
    /// different line heights of their own (Palatino 1.1, Iowan Old Style 1.37), so one fixed amount would
    /// leave some cramped and others loose. Ensemble Serif keeps the spacing it was tuned with.
    static func lineSpacingRatio(forFamily family: String) -> CGFloat {
        EnsembleFonts.register()
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
        let ownLineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) / 100
        return min(0.5, max(0.2, 1.6 - ownLineHeight))
    }

    static let customIDPrefix = "custom:"

    /// The family names the built-in list uses. A file that carries one of them is not added a second time.
    static let builtInFamilies: Set<String> = Set(builtIn.compactMap { font in
        switch font.source {
        case .bundled(let family), .installed(let family): family
        case .system, .custom: nil
        }
    })
}
