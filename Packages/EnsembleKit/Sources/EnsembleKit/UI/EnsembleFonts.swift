import CoreText
import Foundation

/// Fonts that ship inside Ensemble, each under an open licence whose text sits next to the font
/// file in `Resources/Fonts`. They are registered for this process the first time a view asks for
/// one, on the Mac and the iPhone alike.
public enum EnsembleFonts {
    /// Interface text: Inter by Rasmus Andersson (SIL Open Font License 1.1).
    public static let interface = "Inter Variable"

    /// Ensemble Serif, built from Roboto Serif (SIL Open Font License 1.1). The default for what agents write.
    public static let serif = "Ensemble Serif"

    /// Source Serif 4 by Adobe (SIL Open Font License 1.1), the original files, unchanged. "Source" is a reserved
    /// name, so a changed copy could not be called this: `sourceSerifFilesAreAdobesOriginals` checks the files.
    public static let sourceSerif = "Source Serif 4"

    /// What agents write when no other chat font is chosen (see `AppFont`).
    public static let message = serif

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
