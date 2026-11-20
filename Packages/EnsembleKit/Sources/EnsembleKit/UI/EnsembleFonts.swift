import CoreText
import Foundation

/// Fonts that ship inside Ensemble, each under an open licence whose text sits next to the font
/// file in `Resources/Fonts`. They are registered for this process the first time a view asks for
/// one, on the Mac and the iPhone alike.
public enum EnsembleFonts {
    /// Interface text: Inter by Rasmus Andersson (SIL Open Font License 1.1).
    public static let interface = "Inter Variable"

    /// What agents write: Ensemble Serif, built from Source Serif 4 (SIL Open Font License 1.1).
    public static let message = "Ensemble Serif"

    /// Registers the bundled fonts once. Cheap to call again; safe from any thread.
    public static func register() { _ = registered }

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
