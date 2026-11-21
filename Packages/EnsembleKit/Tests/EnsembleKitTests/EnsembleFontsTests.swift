import CoreText
import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import EnsembleKit
#if canImport(AppKit)
import AppKit
#endif

@Suite struct EnsembleFontsTests {
    /// Ensemble Serif (built from Roboto Serif), the default for what agents write.
    @Test(arguments: [
        ["Ensemble Serif", "EnsembleSerif"],
    ])
    func bundledSerifRegistersAndResolvesFaces(_ names: [String]) throws {
        let family = names[0]
        let file = names[1]
        EnsembleFonts.register()

        let baseDesc = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
        ] as CFDictionary)
        let regular = CTFontCreateWithFontDescriptor(baseDesc, 16, nil)
        #expect(CTFontCopyPostScriptName(regular) as String == "\(file)-Regular")
        #expect(CTFontCopyFamilyName(regular) as String == family)
        let regularURL = try #require(CTFontCopyAttribute(regular, kCTFontURLAttribute) as? URL)
        #expect(regularURL.lastPathComponent == "\(file).ttf")

        // Each font file has its licence text next to it.
        let folder = regularURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains("\(file).ttf"))
        #expect(names.contains("\(file)-Italic.ttf"))
        #expect(names.contains("\(file)-OFL.txt"))
        #expect(names.contains("InterVariable.ttf"))
        #expect(names.contains("Inter-OFL.txt"))

        let axes = try #require(CTFontCopyVariationAxes(regular) as? [[String: Any]])
        #expect(axes.count == 1)
        let wghtTag = 0x77676874 as NSNumber // "wght"

        let bold = try #require(CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, .traitBold, .traitBold))
        #expect(CTFontCopyPostScriptName(bold) as String == "\(file)-Bold")
        #expect(CTFontGetSymbolicTraits(bold).contains(.traitBold))
        #expect(!CTFontGetSymbolicTraits(bold).contains(.traitItalic))
        #expect((CTFontCopyAttribute(bold, kCTFontURLAttribute) as? URL)?.lastPathComponent == "\(file).ttf")
        let boldVars = CTFontCopyVariation(bold) as? [NSNumber: Double] ?? [:]
        #expect(boldVars[wghtTag] == 700)

        let italic = try #require(CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, .traitItalic, .traitItalic))
        #expect(CTFontCopyPostScriptName(italic) as String == "\(file)-Italic")
        #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
        #expect(!CTFontGetSymbolicTraits(italic).contains(.traitBold))
        #expect((CTFontCopyAttribute(italic, kCTFontURLAttribute) as? URL)?.lastPathComponent == "\(file)-Italic.ttf")

        let boldItalic = try #require(
            CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic])
        )
        #expect(CTFontCopyPostScriptName(boldItalic) as String == "\(file)-BoldItalic")
        #expect(CTFontGetSymbolicTraits(boldItalic).contains([.traitBold, .traitItalic]))
        #expect((CTFontCopyAttribute(boldItalic, kCTFontURLAttribute) as? URL)?.lastPathComponent == "\(file)-Italic.ttf")
        let boldItalicVars = CTFontCopyVariation(boldItalic) as? [NSNumber: Double] ?? [:]
        #expect(boldItalicVars[wghtTag] == 700)
    }

    /// Source Serif 4: regular, bold, italic and bold italic are the font's own faces, from the right files.
    @Test func sourceSerifResolvesItsOwnFaces() throws {
        EnsembleFonts.register()
        let base = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: EnsembleFonts.sourceSerif] as CFDictionary)
        let regular = CTFontCreateWithFontDescriptor(base, 16, nil)
        #expect(CTFontCopyFamilyName(regular) as String == "Source Serif 4")
        #expect(CTFontCopyPostScriptName(regular) as String == "SourceSerif4Roman-Regular")
        #expect((CTFontCopyAttribute(regular, kCTFontURLAttribute) as? URL)?.lastPathComponent == "SourceSerif4.ttf")

        let bold = try #require(CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, .traitBold, .traitBold))
        #expect(CTFontCopyPostScriptName(bold) as String == "SourceSerif4Roman-Bold")
        let italic = try #require(CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, .traitItalic, .traitItalic))
        #expect(CTFontCopyPostScriptName(italic) as String == "SourceSerif4Italic-Italic")
        #expect((CTFontCopyAttribute(italic, kCTFontURLAttribute) as? URL)?.lastPathComponent == "SourceSerif4-Italic.ttf")
        let both = try #require(
            CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic])
        )
        #expect(CTFontCopyPostScriptName(both) as String == "SourceSerif4Italic-Bold")
    }

    /// "Source" is a reserved font name: only Adobe's unchanged files may be called Source Serif 4. These are the
    /// git blob ids of `ofl/sourceserif4` in github.com/google/fonts; a changed file fails here.
    @Test func sourceSerifFilesAreAdobesOriginals() throws {
        let folder = try fontsFolder()
        let expected = [
            "SourceSerif4.ttf": "40bbb58cb58e893ad0470f0bb291e096c73d3554",
            "SourceSerif4-Italic.ttf": "ccb969aa6847e1169ff9c8c8bdc28daff6966861",
        ]
        for (name, id) in expected {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            var blob = Data("blob \(data.count)\u{0}".utf8)
            blob.append(data)
            let digest = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            #expect(digest == id, "\(name) is not the original file")
        }
        let licence = try String(contentsOf: folder.appendingPathComponent("SourceSerif4-OFL.txt"), encoding: .utf8)
        #expect(licence.contains("Reserved Font Name 'Source'"))
        #expect(licence.contains("SIL OPEN FONT LICENSE Version 1.1"))
    }

    /// A font file in the bundle that is not on the list of open-licence fonts fails the test.
    @Test func onlyTheListedFontFilesAreBundled() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: fontsFolder().path).sorted()
        #expect(names == [
            "EnsembleSerif-Italic.ttf", "EnsembleSerif-OFL.txt", "EnsembleSerif.ttf",
            "Inter-OFL.txt", "InterVariable.ttf",
            "SourceSerif4-Italic.ttf", "SourceSerif4-OFL.txt", "SourceSerif4.ttf",
        ])
    }

    /// The bundle's Fonts folder, found through a registered font's file.
    private func fontsFolder() throws -> URL {
        EnsembleFonts.register()
        let regular = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: EnsembleFonts.serif] as CFDictionary), 16, nil)
        return try #require(CTFontCopyAttribute(regular, kCTFontURLAttribute) as? URL).deletingLastPathComponent()
    }

    #if canImport(AppKit)
    @Test @MainActor func swiftUIMarkdownResolvesRegularBoldAndItalicFaces() throws {
        EnsembleFonts.register()
        _ = NSApplication.shared

        let attributed = MarkdownInline.attributed(
            "Plain *Italic* **Bold** ***Both***",
            theme: .dark,
            size: 16
        )
        let view = Text(attributed)
            .font(MessageType.font(size: 16))
            .frame(width: 400, height: 60)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        host.layoutSubtreeIfNeeded()

        let pdfData = host.dataWithPDF(inside: host.bounds)
        let pdf = try #require(String(data: pdfData, encoding: .isoLatin1))
        #expect(pdf.contains("EnsembleSerif-Regular"))
        #expect(pdf.contains("EnsembleSerif-Italic"))
        #expect(pdf.contains("EnsembleSerif-Bold"))
        #expect(pdf.contains("EnsembleSerif-BoldItalic"))
    }
    #endif
}
