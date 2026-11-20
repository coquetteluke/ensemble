import CoreText
import Foundation
import SwiftUI
import Testing
@testable import EnsembleKit
#if canImport(AppKit)
import AppKit
#endif

@Suite struct EnsembleFontsTests {
    @Test func bundledFontsRegisterAndResolveFaces() throws {
        EnsembleFonts.register()

        let baseDesc = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: EnsembleFonts.message,
        ] as CFDictionary)
        let regular = CTFontCreateWithFontDescriptor(baseDesc, 16, nil)
        #expect(CTFontCopyPostScriptName(regular) as String == "EnsembleSerif-Regular")
        #expect(CTFontCopyFamilyName(regular) as String == "Ensemble Serif")
        let regularURL = try #require(CTFontCopyAttribute(regular, kCTFontURLAttribute) as? URL)
        #expect(regularURL.lastPathComponent == "EnsembleSerif.ttf")

        let folder = regularURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains("EnsembleSerif.ttf"))
        #expect(names.contains("EnsembleSerif-Italic.ttf"))
        #expect(names.contains("EnsembleSerif-OFL.txt"))
        #expect(names.contains("InterVariable.ttf"))

        let axes = try #require(CTFontCopyVariationAxes(regular) as? [[String: Any]])
        #expect(axes.count == 1)
        let wghtTag = 0x77676874 as NSNumber // "wght"

        let bold = try #require(CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, .traitBold, .traitBold))
        #expect(CTFontCopyPostScriptName(bold) as String == "EnsembleSerif-Bold")
        #expect(CTFontGetSymbolicTraits(bold).contains(.traitBold))
        #expect(!CTFontGetSymbolicTraits(bold).contains(.traitItalic))
        #expect((CTFontCopyAttribute(bold, kCTFontURLAttribute) as? URL)?.lastPathComponent == "EnsembleSerif.ttf")
        let boldVars = CTFontCopyVariation(bold) as? [NSNumber: Double] ?? [:]
        #expect(boldVars[wghtTag] == 700)

        let italic = try #require(CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, .traitItalic, .traitItalic))
        #expect(CTFontCopyPostScriptName(italic) as String == "EnsembleSerif-Italic")
        #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
        #expect(!CTFontGetSymbolicTraits(italic).contains(.traitBold))
        #expect((CTFontCopyAttribute(italic, kCTFontURLAttribute) as? URL)?.lastPathComponent == "EnsembleSerif-Italic.ttf")

        let boldItalic = try #require(
            CTFontCreateCopyWithSymbolicTraits(regular, 16, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic])
        )
        #expect(CTFontCopyPostScriptName(boldItalic) as String == "EnsembleSerif-BoldItalic")
        #expect(CTFontGetSymbolicTraits(boldItalic).contains([.traitBold, .traitItalic]))
        #expect((CTFontCopyAttribute(boldItalic, kCTFontURLAttribute) as? URL)?.lastPathComponent == "EnsembleSerif-Italic.ttf")
        let boldItalicVars = CTFontCopyVariation(boldItalic) as? [NSNumber: Double] ?? [:]
        #expect(boldItalicVars[wghtTag] == 700)
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
