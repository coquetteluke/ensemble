import CoreText
import Foundation
import SwiftUI
import Testing
@testable import EnsembleKit
#if canImport(AppKit)
import AppKit
#endif

@Suite struct AppFontTests {
    @Test func theDefaultChatFontIsEnsembleSerif() {
        #expect(AppFont.standard == AppFont.ensembleSerif)
        #expect(AppFont.standard.id == "ensemble-serif")
        #expect(AppFont.standard.source == .bundled(family: "Ensemble Serif"))
        #expect(EnsembleFonts.message == "Ensemble Serif")
        #expect(Theme.dark.chatFont == .standard)
        #expect(Theme.light.chatFont == .standard)
        // Everything else stays Inter until another interface font is chosen.
        #expect(FontRole.chat.standard == .ensembleSerif)
        #expect(FontRole.interface.standard == .inter)
        #expect(Theme.dark.interfaceFont == .inter)
    }

    @Test func builtInFontsHaveStableUniqueIDs() {
        let ids = AppFont.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "ensemble-serif")
        // Source Serif 4 is offered under its own name, and so are the choices that need no file.
        for id in ["source-serif-4", "system-serif", "system-sans", "inter"] {
            #expect(ids.contains(id))
        }
        #expect(!ids.contains { $0.hasPrefix(AppFont.customIDPrefix) })
    }

    @Test func bundledAndSystemFontsAreAvailable() {
        let available = Set(AppFont.availableBuiltIn.map(\.id))
        for font in [AppFont.ensembleSerif, .sourceSerif4, .newYork, .sanFrancisco, .inter] {
            #expect(font.isAvailable)
            #expect(available.contains(font.id))
        }
        #expect(!AppFont.custom(family: "Ensemble Test Not Installed").isAvailable)
        #expect(!EnsembleFonts.hasFamily("Ensemble Test Not Installed"))
    }

    @Test func detailSaysWhereAFontComesFrom() {
        #expect(AppFont.ensembleSerif.detail == "Built from Roboto Serif")
        #expect(AppFont.sourceSerif4.detail == "By Adobe")
        #expect(AppFont.newYork.detail == "System serif")
        #expect(AppFont.sanFrancisco.detail == "System sans")
        #expect(AppFont.custom(family: "Any").detail == "Added from a file")
        #expect(AppFont.custom(family: "Any").isCustom)
        #expect(!AppFont.ensembleSerif.isCustom)
    }

    @Test func themeTakesSpacingFromTheAppFont() {
        var theme = Theme.dark
        theme.scale = 1.5
        var font = AppFont.ensembleSerif
        font.lineSpacingRatio = 0.5
        font.trackingRatio = 0.01
        theme.chatFont = font
        #expect(theme.messageLineSpacing(10) == 7.5)
        #expect(abs(theme.messageTracking(10) - 0.15) < 0.0001)
    }

    /// Lines sit about 1.6 times the type size apart, whatever line height a font asks for itself.
    @Test func lineSpacingFollowsTheFontsOwnLineHeight() {
        // Ensemble Serif keeps the spacing it was tuned with.
        #expect(AppFont.ensembleSerif.lineSpacingRatio == 0.36)
        // Ensemble Serif asks for 1.171 of its own, so as an added font it would get 1.6 - 1.171.
        #expect(abs(AppFont.lineSpacingRatio(forFamily: EnsembleFonts.serif) - 0.429) < 0.005)
        // Source Serif 4 gets what its own line height leaves to 1.6.
        #expect(AppFont.sourceSerif4.lineSpacingRatio == AppFont.lineSpacingRatio(forFamily: EnsembleFonts.sourceSerif))
        for font in AppFont.builtIn {
            #expect((0.2...0.5).contains(font.lineSpacingRatio))
        }
        #expect((0.2...0.5).contains(AppFont.custom(family: "Ensemble Test Not Installed").lineSpacingRatio))
    }

    @Test func fileNamesAreMadeSafe() {
        #expect(CustomFontLibrary.safeFileName("TiemposText-Regular") == "TiemposText-Regular")
        #expect(CustomFontLibrary.safeFileName("../../etc/passwd") == "------etc-passwd")
        #expect(CustomFontLibrary.safeFileName("") == "font")
        #expect(CustomFontLibrary.safeFileName(String(repeating: "a", count: 200)).count == 80)
    }
}

@Suite @MainActor struct FontStoreTests {
    @Test func startsOnTheDefaultsAndRemembersAChoiceForEachRole() throws {
        let settings = SavedFonts()

        let store = settings.store()
        #expect(store.chat == .ensembleSerif)
        #expect(store.interface == .inter)
        #expect(store.font(for: .chat) == .ensembleSerif && store.font(for: .interface) == .inter)
        #expect(store.choices == AppFont.availableBuiltIn)
        #expect(store.customFamilies.isEmpty)

        store.select(.sourceSerif4)
        #expect(store.chat == .sourceSerif4)
        #expect(store.interface == .inter)
        #expect(settings.ledger?.chat.id == "source-serif-4")

        store.select(.sanFrancisco, for: .interface)
        #expect(store.interface == .sanFrancisco)
        #expect(store.chat == .sourceSerif4)
        #expect(settings.ledger?.interface.id == "system-sans")

        // A new store on the same settings (the next launch) starts on the saved fonts.
        let relaunched = settings.store()
        #expect(relaunched.chat == .sourceSerif4)
        #expect(relaunched.interface == .sanFrancisco)
        // A device that has saved nothing is on the defaults.
        #expect(FontStore.temporary().chat == .standard)
        #expect(FontStore.temporary().interface == .inter)
    }

    @Test func aSavedFontThatIsMissingFallsBackToTheDefault() throws {
        let folder = TestFont.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        for saved in ["custom:Ensemble Test Gone", "a-font-from-a-newer-version", ""] {
            let settings = SavedFonts(SavedFonts.ledger(chat: saved, interface: saved))
            let store = settings.store(library: CustomFontLibrary(folder: folder))
            #expect(store.chat == .ensembleSerif)
            #expect(store.interface == .inter)
            #expect(!store.choices.contains { $0.id == saved })
        }
    }

    @Test func addsAFamilyFromSeveralFilesAndRemovesIt() throws {
        let settings = SavedFonts()
        let folder = TestFont.temporaryFolder()
        let downloads = TestFont.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: downloads)
        }
        let family = TestFont.uniqueFamily()
        let compact = family.replacingOccurrences(of: " ", with: "")
        let regular = try TestFont.write(family: family, to: downloads)
        let italic = try TestFont.write(family: family, italic: true, to: downloads)
        #expect(!EnsembleFonts.hasFamily(family))

        let library = CustomFontLibrary(folder: folder)
        let store = settings.store(library: library)
        let problems = store.add([regular, italic])
        #expect(problems.isEmpty)

        // Listed once, under the family name, after the built-in fonts.
        let added = AppFont.custom(family: family)
        #expect(store.customFamilies.map(\.name) == [family])
        #expect(store.choices == AppFont.availableBuiltIn + [added])
        #expect(EnsembleFonts.hasFamily(family))
        // Copied into the library's own folder, named after the faces inside the files.
        let stored = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(stored == ["\(compact)-Light.ttf", "\(compact)-LightItalic.ttf"])
        #expect(store.customFamilies.first?.files.count == 2)
        // The picked files are left where they were.
        #expect(FileManager.default.fileExists(atPath: regular.path))

        // The real italic of the added family is used, not a slanted regular.
        let base = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let upright = CTFontCreateWithFontDescriptor(base, 16, nil)
        let slanted = try #require(CTFontCreateCopyWithSymbolicTraits(upright, 16, nil, .traitItalic, .traitItalic))
        #expect(CTFontCopyPostScriptName(slanted) as String == "\(compact)-Italic")

        // Adding does not change the chosen font. Choosing it is saved.
        #expect(store.chat == .standard)
        store.select(added)
        #expect(store.chat == added)
        #expect(settings.ledger?.chat.id == "custom:\(family)")
        // It can be the interface font too.
        store.select(added, for: .interface)
        #expect(store.interface == added)

        // Adding the same files again replaces the copies.
        #expect(store.add([regular, italic]).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        #expect(store.chat == added)

        // The next launch finds the family in the folder and starts on it.
        let relaunched = settings.store(library: library)
        #expect(relaunched.chat == added)

        // Removing it deletes the files, and agent text goes back to the default.
        store.remove(added)
        #expect(store.chat == .standard)
        #expect(store.customFamilies.isEmpty)
        #expect(store.choices == AppFont.availableBuiltIn)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!EnsembleFonts.hasFamily(family))
        #expect(store.interface == .inter)
        #expect(settings.ledger?.chat.id == "ensemble-serif")
        #expect(settings.ledger?.interface.id == "inter")
        #expect(settings.ledger?.removed[family] != nil)
        #expect(settings.store(library: library).chat == .standard)
    }

    @Test func removingAnAddedFontThatIsNotChosenKeepsTheChoice() throws {
        let folder = TestFont.temporaryFolder()
        let downloads = TestFont.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: downloads)
        }
        let family = TestFont.uniqueFamily()
        let store = FontStore(saved: nil, library: CustomFontLibrary(folder: folder))
        #expect(store.add([try TestFont.write(family: family, to: downloads)]).isEmpty)
        store.select(.inter)
        store.remove(.custom(family: family))
        #expect(store.chat == .inter)
        // A built-in font cannot be removed.
        store.remove(.inter)
        #expect(store.choices.contains(.inter))
        #expect(store.chat == .inter)
    }

    @Test func aFontDeletedBehindTheStoreFallsBackOnTheNextLaunch() throws {
        let settings = SavedFonts()
        let folder = TestFont.temporaryFolder()
        let downloads = TestFont.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: downloads)
        }
        let family = TestFont.uniqueFamily()
        let library = CustomFontLibrary(folder: folder)
        let store = settings.store(library: library)
        #expect(store.add([try TestFont.write(family: family, to: downloads)]).isEmpty)
        store.select(.custom(family: family))

        // The owner deletes the file in Finder between two launches.
        for file in store.customFamilies.flatMap(\.files) {
            CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
            try FileManager.default.removeItem(at: file)
        }
        let relaunched = settings.store(library: library)
        #expect(relaunched.chat == .standard)
        #expect(relaunched.customFamilies.isEmpty)
    }

    @Test func refusesFilesThatAreNotUsableFonts() throws {
        let folder = TestFont.temporaryFolder()
        let downloads = TestFont.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: downloads)
        }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let library = CustomFontLibrary(folder: folder)

        // Not a .ttf or .otf file, even when it holds a real font.
        let wrongType = downloads.appendingPathComponent("Sample.woff2")
        try TestFont.data(family: TestFont.uniqueFamily()).write(to: wrongType)
        #expect(throws: CustomFontLibrary.ImportError.wrongType(file: "Sample.woff2")) { try library.add(wrongType) }

        // The right ending, but not a font inside.
        let notAFont = downloads.appendingPathComponent("Notes.ttf")
        try Data("These are notes, not a font.".utf8).write(to: notAFont)
        #expect(throws: CustomFontLibrary.ImportError.notAFont(file: "Notes.ttf")) { try library.add(notAFont) }

        let empty = downloads.appendingPathComponent("Empty.otf")
        try Data().write(to: empty)
        #expect(throws: CustomFontLibrary.ImportError.unreadable(file: "Empty.otf")) { try library.add(empty) }

        let missing = downloads.appendingPathComponent("Missing.ttf")
        #expect(throws: CustomFontLibrary.ImportError.unreadable(file: "Missing.ttf")) { try library.add(missing) }

        // Over the size limit (a sparse file, so nothing large is written).
        let large = downloads.appendingPathComponent("Large.ttf")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(CustomFontLibrary.maxFileSize) + 1)
        try handle.close()
        #expect(throws: CustomFontLibrary.ImportError.tooLarge(file: "Large.ttf")) { try library.add(large) }

        // A family the list already has is not added a second time.
        let bundled = try TestFont.bundledSerif(italic: false)
        #expect(throws: CustomFontLibrary.ImportError.alreadyListed(family: "Ensemble Serif")) { try library.add(bundled) }

        // Nothing was copied, and the store reports one line per refused file.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let store = FontStore(saved: nil, library: library)
        let problems = store.add([wrongType, notAFont, large])
        #expect(problems == [
            "Sample.woff2 is not a .ttf or .otf file.",
            "Notes.ttf is not a font that can be used.",
            "Large.ttf is larger than 25 MB.",
        ])
        #expect(store.choices == AppFont.availableBuiltIn)
    }

    @Test func oneBadFileDoesNotStopTheOthers() throws {
        let folder = TestFont.temporaryFolder()
        let downloads = TestFont.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: downloads)
        }
        let family = TestFont.uniqueFamily()
        let good = try TestFont.write(family: family, to: downloads)
        let bad = downloads.appendingPathComponent("Broken.otf")
        try Data(repeating: 7, count: 4096).write(to: bad)

        let store = FontStore(saved: nil, library: CustomFontLibrary(folder: folder))
        #expect(store.add([bad, good]) == ["Broken.otf is not a font that can be used."])
        #expect(store.customFamilies.map(\.name) == [family])
        store.remove(.custom(family: family))
    }

    #if canImport(AppKit)
    /// Two views that are already open are both handed the new font as soon as the choice changes, with no
    /// restart and nothing done to the views themselves. No other test reads `FontStore.shared`.
    @Test func openWindowsFollowTheChoiceAtOnce() async throws {
        _ = NSApplication.shared
        let store = FontStore.temporary()
        FontStore.shared = store
        let seen = SeenFonts()
        let windows = (0..<2).map { index in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FontProbe(index: index, seen: seen).ensembleTheme())
            window.contentView?.layoutSubtreeIfNeeded()
            return window
        }
        defer { windows.forEach { $0.close() } }
        #expect(seen.fonts == [0: "ensemble-serif inter", 1: "ensemble-serif inter"])

        let steps: [(AppFont, FontRole, String)] = [
            (.sourceSerif4, .chat, "source-serif-4 inter"),
            (.sanFrancisco, .interface, "source-serif-4 system-sans"),
            (.newYork, .chat, "system-serif system-sans"),
            (.inter, .interface, "system-serif inter"),
        ]
        for (font, role, expected) in steps {
            store.select(font, for: role)
            // SwiftUI redraws on the next turn of the run loop: wait for it, two seconds at most.
            for _ in 0..<100 where seen.fonts != [0: expected, 1: expected] {
                try await Task.sleep(for: .milliseconds(20))
                windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            }
            #expect(seen.fonts == [0: expected, 1: expected])
        }
    }

    /// Interface text drawn through the theme uses the chosen interface font, and code keeps the fixed-width one.
    @Test func interfaceTextIsDrawnInTheChosenInterfaceFont() throws {
        _ = NSApplication.shared

        func facesDrawn(_ font: AppFont) throws -> String {
            var theme = Theme.dark
            theme.interfaceFont = font
            let view = VStack {
                Text("Session Hub").font(theme.font(size: 13))
                Text("Allow once").font(theme.font(size: 13, weight: .semibold))
                Text("npm test").font(theme.font(size: 12, design: .monospaced))
            }
            .frame(width: 300)
            let pdf = NSMutableData()
            ImageRenderer(content: view).render { size, draw in
                var page = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
                      let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
            }
            return try #require(String(data: pdf as Data, encoding: .isoLatin1))
        }

        let standard = try facesDrawn(.inter)
        #expect(standard.contains("Inter"))
        #expect(!standard.contains("EnsembleSerif"))
        #expect(standard.contains("Mono"))

        let serif = try facesDrawn(.ensembleSerif)
        #expect(serif.contains("EnsembleSerif-Regular"))
        #expect(serif.contains("EnsembleSerif-SemiBold"))
        #expect(!serif.contains("Inter"))
        #expect(serif.contains("Mono"))
    }

    /// Agent text drawn through the theme uses the chosen font's own regular, bold and italic faces.
    @Test func markdownIsDrawnInTheChosenFont() throws {
        _ = NSApplication.shared

        // Drawn into a PDF, which names every font face that was used.
        func facesDrawn(_ font: AppFont) throws -> String {
            var theme = Theme.dark
            theme.chatFont = font
            let view = MarkdownView("Plain *Italic* **Bold**")
                .environment(\.theme, theme)
                .frame(width: 400)
            let pdf = NSMutableData()
            ImageRenderer(content: view).render { size, draw in
                var page = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
                      let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
            }
            return try #require(String(data: pdf as Data, encoding: .isoLatin1))
        }

        let standard = try facesDrawn(.standard)
        #expect(standard.contains("EnsembleSerif-Regular"))
        #expect(standard.contains("EnsembleSerif-Italic"))
        #expect(standard.contains("EnsembleSerif-Bold"))
        #expect(!standard.contains("SourceSerif4"))

        let source = try facesDrawn(.sourceSerif4)
        #expect(source.contains("SourceSerif4Roman-Regular"))
        #expect(source.contains("SourceSerif4Italic-Italic"))
        // Source Serif 4 has an optical size axis, so at 14 points the bold is drawn as the upright font at
        // weight 700 (2BC in hexadecimal) and optical size 14, and the file names it that way.
        #expect(source.contains("SourceSerif4Roman-Regular_wght2BC0000_opszE0000"))
        #expect(!source.contains("EnsembleSerif"))

        let system = try facesDrawn(.newYork)
        #expect(!system.contains("EnsembleSerif") && !system.contains("SourceSerif4"))
    }
    #endif
}

#if canImport(AppKit)
/// The chat font and the interface font each open probe view was last drawn with.
@MainActor final class SeenFonts {
    var fonts: [Int: String] = [:]
}

/// Stands in for a window's content: it notes the fonts the theme hands it every time it is drawn.
private struct FontProbe: View {
    let index: Int
    let seen: SeenFonts
    @Environment(\.theme) private var theme

    var body: some View {
        seen.fonts[index] = theme.chatFont.id + " " + theme.interfaceFont.id
        return Text("Agent text").font(theme.messageFont(size: 14))
    }
}
#endif
