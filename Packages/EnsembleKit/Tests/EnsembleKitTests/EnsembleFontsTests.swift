import CoreText
import Foundation
import SwiftUI
import Testing
@testable import EnsembleKit
#if canImport(AppKit)
import AppKit
#endif

@Suite struct EnsembleFontsTests {
    /// Both bundled serifs: the default (Ensemble Serif 4, from Source Serif 4) and Ensemble Serif (from Roboto Serif).
    @Test(arguments: [
        ["Ensemble Serif 4", "EnsembleSerif4"],
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

    /// A font file in the bundle that is not on the list of open-licence fonts fails the test.
    @Test func onlyTheListedFontFilesAreBundled() throws {
        EnsembleFonts.register()
        let regular = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: EnsembleFonts.serif] as CFDictionary), 16, nil)
        let folder = try #require(CTFontCopyAttribute(regular, kCTFontURLAttribute) as? URL).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == [
            "EnsembleSerif-Italic.ttf", "EnsembleSerif-OFL.txt", "EnsembleSerif.ttf",
            "EnsembleSerif4-Italic.ttf", "EnsembleSerif4-OFL.txt", "EnsembleSerif4.ttf",
            "Inter-OFL.txt", "InterVariable.ttf",
        ])
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
        #expect(pdf.contains("EnsembleSerif4-Regular"))
        #expect(pdf.contains("EnsembleSerif4-Italic"))
        #expect(pdf.contains("EnsembleSerif4-Bold"))
        #expect(pdf.contains("EnsembleSerif4-BoldItalic"))
    }
    #endif
}
