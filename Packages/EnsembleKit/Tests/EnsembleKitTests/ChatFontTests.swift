import CoreText
import Foundation
import SwiftUI
import Testing
@testable import EnsembleKit
#if canImport(AppKit)
import AppKit
#endif

@Suite struct ChatFontTests {
    @Test func theDefaultIsEnsembleSerif4() {
        #expect(ChatFont.standard == ChatFont.serif4)
        #expect(ChatFont.standard.id == "ensemble-serif-4")
        #expect(ChatFont.standard.source == .bundled(family: "Ensemble Serif 4"))
        #expect(EnsembleFonts.message == "Ensemble Serif 4")
        #expect(Theme.dark.chatFont == .standard)
        #expect(Theme.light.chatFont == .standard)
    }

    @Test func builtInFontsHaveStableUniqueIDs() {
        let ids = ChatFont.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "ensemble-serif-4")
        // The font used before the chooser is still offered, and so are the choices that need no file.
        for id in ["ensemble-serif", "system-serif", "system-sans", "inter"] {
            #expect(ids.contains(id))
        }
        #expect(!ids.contains { $0.hasPrefix(ChatFont.customIDPrefix) })
    }

    @Test func bundledAndSystemFontsAreAvailable() {
        let available = Set(ChatFont.availableBuiltIn.map(\.id))
        for font in [ChatFont.serif4, .ensembleSerif, .newYork, .sanFrancisco, .inter] {
            #expect(font.isAvailable)
            #expect(available.contains(font.id))
        }
        #expect(!ChatFont.custom(family: "Ensemble Test Not Installed").isAvailable)
        #expect(!EnsembleFonts.hasFamily("Ensemble Test Not Installed"))
    }

    @Test func detailSaysWhereAFontComesFrom() {
        #expect(ChatFont.serif4.detail == "Built from Source Serif 4")
        #expect(ChatFont.ensembleSerif.detail == "Built from Roboto Serif")
        #expect(ChatFont.newYork.detail == "System serif")
        #expect(ChatFont.sanFrancisco.detail == "System sans")
        #expect(ChatFont.custom(family: "Any").detail == "Added from a file")
        #expect(ChatFont.custom(family: "Any").isCustom)
        #expect(!ChatFont.serif4.isCustom)
    }

    @Test func themeTakesSpacingFromTheChatFont() {
        var theme = Theme.dark
        theme.scale = 1.5
        var font = ChatFont.ensembleSerif
        font.lineSpacingRatio = 0.5
        font.trackingRatio = 0.01
        theme.chatFont = font
        #expect(theme.messageLineSpacing(10) == 7.5)
        #expect(abs(theme.messageTracking(10) - 0.15) < 0.0001)
    }

    /// Lines sit about 1.6 times the type size apart, whatever line height a font asks for itself.
    @Test func lineSpacingFollowsTheFontsOwnLineHeight() {
        // The bundled serifs keep the spacing they were tuned with.
        #expect(ChatFont.serif4.lineSpacingRatio == 0.36)
        #expect(ChatFont.ensembleSerif.lineSpacingRatio == 0.36)
        // Ensemble Serif asks for 1.171 of its own, so as an added font it would get 1.6 - 1.171.
        #expect(abs(ChatFont.lineSpacingRatio(forFamily: EnsembleFonts.serif) - 0.429) < 0.005)
        // A tall font is not squeezed and a short one is not spread without limit.
        #expect(abs(ChatFont.lineSpacingRatio(forFamily: EnsembleFonts.serif4) - 0.229) < 0.005)
        for font in ChatFont.builtIn {
            #expect((0.2...0.5).contains(font.lineSpacingRatio))
        }
        #expect((0.2...0.5).contains(ChatFont.custom(family: "Ensemble Test Not Installed").lineSpacingRatio))
    }

    @Test func fileNamesAreMadeSafe() {
        #expect(CustomFontLibrary.safeFileName("TiemposText-Regular") == "TiemposText-Regular")
        #expect(CustomFontLibrary.safeFileName("../../etc/passwd") == "------etc-passwd")
        #expect(CustomFontLibrary.safeFileName("") == "font")
        #expect(CustomFontLibrary.safeFileName(String(repeating: "a", count: 200)).count == 80)
    }
}

@Suite @MainActor struct ChatFontStoreTests {
    @Test func startsOnTheDefaultAndRemembersAChoice() throws {
        let settings = SavedChatFont()

        let store = settings.store()
        #expect(store.current == .standard)
        #expect(store.choices == ChatFont.availableBuiltIn)
        #expect(store.customFamilies.isEmpty)

        store.select(.ensembleSerif)
        #expect(store.current == .ensembleSerif)
        #expect(settings.id == "ensemble-serif")

        // A new store on the same settings (the next launch) starts on the saved font.
        #expect(settings.store().current == .ensembleSerif)
        // Another device has its own settings and stays on the default.
        #expect(ChatFontStore.temporary().current == .standard)
    }

    @Test func aSavedFontThatIsMissingFallsBackToTheDefault() throws {
        let settings = SavedChatFont()
        let folder = TestFont.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        for saved in ["custom:Ensemble Test Gone", "a-font-from-a-newer-version", ""] {
            settings.id = saved
            let store = settings.store(library: CustomFontLibrary(folder: folder))
            #expect(store.current == .standard)
            #expect(!store.choices.contains { $0.id == saved })
        }
    }

    @Test func addsAFamilyFromSeveralFilesAndRemovesIt() throws {
        let settings = SavedChatFont()
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
        let added = ChatFont.custom(family: family)
        #expect(store.customFamilies.map(\.name) == [family])
        #expect(store.choices == ChatFont.availableBuiltIn + [added])
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
        #expect(store.current == .standard)
        store.select(added)
        #expect(store.current == added)
        #expect(settings.id == "custom:\(family)")

        // Adding the same files again replaces the copies.
        #expect(store.add([regular, italic]).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        #expect(store.current == added)

        // The next launch finds the family in the folder and starts on it.
        let relaunched = settings.store(library: library)
        #expect(relaunched.current == added)

        // Removing it deletes the files, and agent text goes back to the default.
        store.remove(added)
        #expect(store.current == .standard)
        #expect(store.customFamilies.isEmpty)
        #expect(store.choices == ChatFont.availableBuiltIn)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!EnsembleFonts.hasFamily(family))
        #expect(settings.id == nil)
        #expect(settings.store(library: library).current == .standard)
    }

    @Test func removingAnAddedFontThatIsNotChosenKeepsTheChoice() throws {
        let folder = TestFont.temporaryFolder()
        let downloads = TestFont.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: downloads)
        }
        let family = TestFont.uniqueFamily()
        let store = ChatFontStore(saved: nil, library: CustomFontLibrary(folder: folder))
        #expect(store.add([try TestFont.write(family: family, to: downloads)]).isEmpty)
        store.select(.inter)
        store.remove(.custom(family: family))
        #expect(store.current == .inter)
        // A built-in font cannot be removed.
        store.remove(.inter)
        #expect(store.choices.contains(.inter))
        #expect(store.current == .inter)
    }

    @Test func aFontDeletedBehindTheStoreFallsBackOnTheNextLaunch() throws {
        let settings = SavedChatFont()
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
        #expect(relaunched.current == .standard)
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
        let store = ChatFontStore(saved: nil, library: library)
        let problems = store.add([wrongType, notAFont, large])
        #expect(problems == [
            "Sample.woff2 is not a .ttf or .otf file.",
            "Notes.ttf is not a font that can be used.",
            "Large.ttf is larger than 25 MB.",
        ])
        #expect(store.choices == ChatFont.availableBuiltIn)
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

        let store = ChatFontStore(saved: nil, library: CustomFontLibrary(folder: folder))
        #expect(store.add([bad, good]) == ["Broken.otf is not a font that can be used."])
        #expect(store.customFamilies.map(\.name) == [family])
        store.remove(.custom(family: family))
    }

    #if canImport(AppKit)
    /// Two views that are already open are both handed the new font as soon as the choice changes, with no
    /// restart and nothing done to the views themselves. No other test reads `ChatFontStore.shared`.
    @Test func openWindowsFollowTheChoiceAtOnce() async throws {
        _ = NSApplication.shared
        let store = ChatFontStore.temporary()
        ChatFontStore.shared = store
        let seen = SeenChatFonts()
        let windows = (0..<2).map { index in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ChatFontProbe(index: index, seen: seen).ensembleTheme())
            window.contentView?.layoutSubtreeIfNeeded()
            return window
        }
        defer { windows.forEach { $0.close() } }
        #expect(seen.fonts == [0: "ensemble-serif-4", 1: "ensemble-serif-4"])

        for font in [ChatFont.ensembleSerif, .newYork, .standard] {
            store.select(font)
            // SwiftUI redraws on the next turn of the run loop: wait for it, two seconds at most.
            for _ in 0..<100 where seen.fonts != [0: font.id, 1: font.id] {
                try await Task.sleep(for: .milliseconds(20))
                windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            }
            #expect(seen.fonts == [0: font.id, 1: font.id])
        }
    }

    /// Agent text drawn through the theme uses the chosen font's own regular, bold and italic faces.
    @Test func markdownIsDrawnInTheChosenFont() throws {
        _ = NSApplication.shared

        // Drawn into a PDF, which names every font face that was used.
        func facesDrawn(_ font: ChatFont) throws -> String {
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
        #expect(standard.contains("EnsembleSerif4-Regular"))
        #expect(standard.contains("EnsembleSerif4-Italic"))
        #expect(standard.contains("EnsembleSerif4-Bold"))
        #expect(!standard.contains("EnsembleSerif-"))

        let roboto = try facesDrawn(.ensembleSerif)
        #expect(roboto.contains("EnsembleSerif-Regular"))
        #expect(roboto.contains("EnsembleSerif-Italic"))
        #expect(roboto.contains("EnsembleSerif-Bold"))
        #expect(!roboto.contains("EnsembleSerif4-"))

        let system = try facesDrawn(.newYork)
        #expect(!system.contains("EnsembleSerif"))
    }
    #endif
}

#if canImport(AppKit)
/// The chat font each open probe view was last drawn with.
@MainActor final class SeenChatFonts {
    var fonts: [Int: String] = [:]
}

/// Stands in for a window's content: it notes the chat font the theme hands it every time it is drawn.
private struct ChatFontProbe: View {
    let index: Int
    let seen: SeenChatFonts
    @Environment(\.theme) private var theme

    var body: some View {
        seen.fonts[index] = theme.chatFont.id
        return Text("Agent text").font(theme.messageFont(size: 14))
    }
}
#endif
