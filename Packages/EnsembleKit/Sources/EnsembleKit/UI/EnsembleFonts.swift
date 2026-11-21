import CoreText
import Foundation

/// Fonts that ship inside Ensemble, each under an open licence whose text sits next to the font
/// file in `Resources/Fonts`. They are registered for this process the first time a view asks for
/// one, on the Mac and the iPhone alike.
public enum EnsembleFonts {
    /// Interface text: Inter by Rasmus Andersson (SIL Open Font License 1.1).
    public static let interface = "Inter Variable"

    /// Ensemble Serif 4, built from Source Serif 4 (SIL Open Font License 1.1). The default for what agents write.
    public static let serif4 = "Ensemble Serif 4"

    /// Ensemble Serif, built from Roboto Serif (SIL Open Font License 1.1).
    public static let serif = "Ensemble Serif"

    /// What agents write when no other chat font is chosen (see `ChatFont`).
    public static let message = serif4

    /// Registers the bundled fonts once. Cheap to call again; safe from any thread.
    public static func register() { _ = registered }

    /// Whether a font family can be used right now: bundled, part of the system, or added on this device.
    public static func hasFamily(_ family: String) -> Bool {
        register()
        let wanted = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = NSSet(object: kCTFontFamilyNameAttribute) as CFSet
        return CTFontDescriptorCreateMatchingFontDescriptor(wanted, mandatory) != nil
    }

    private static let registered: Bool = {
        guard let folder = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return false }
        for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        return true
    }()
}
