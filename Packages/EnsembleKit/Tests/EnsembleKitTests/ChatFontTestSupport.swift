import CoreText
import Foundation
@testable import EnsembleKit

/// Makes font files for the tests without keeping any in the repository: a copy of the bundled Ensemble
/// Serif whose `name` table carries another family name. Font registration is shared by the whole test
/// process, so every test uses a family name of its own.
enum TestFont {
    /// A family name no other test uses.
    static func uniqueFamily() -> String {
        "Ensemble Test " + UUID().uuidString.prefix(8).uppercased()
    }

    /// The bundled Ensemble Serif (upright or italic) renamed to `family`.
    static func data(family: String, italic: Bool = false) throws -> Data {
        try renamed(Data(contentsOf: bundledSerif(italic: italic)), from: EnsembleFonts.serif, to: family)
    }

    /// Writes a renamed font into `folder` and returns the file.
    static func write(family: String, italic: Bool = false, to folder: URL, name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name ?? (italic ? "Sample Italic.ttf" : "Sample Regular.ttf"))
        try data(family: family, italic: italic).write(to: file)
        return file
    }

    static func bundledSerif(italic: Bool) throws -> URL {
        EnsembleFonts.register()
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: EnsembleFonts.serif] as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        if italic, let slanted = CTFontCreateCopyWithSymbolicTraits(font, 16, nil, .traitItalic, .traitItalic) {
            font = slanted
        }
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    /// A new temporary folder, removed by the caller.
    static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-font-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Rewrites every string of the `name` table, replacing `old` with `new` (with and without spaces).
    /// All other tables are copied as they are; checksums are recomputed.
    static func renamed(_ source: Data, from old: String, to new: String) -> Data {
        let font = [UInt8](source)
        func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ bytes: [UInt8], _ at: Int) -> Int { u16(bytes, at) << 16 | u16(bytes, at + 2) }
        func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func be32(_ value: Int) -> [UInt8] { be16(value >> 16 & 0xFFFF) + be16(value & 0xFFFF) }
        func checksum(_ bytes: [UInt8]) -> Int {
            var sum: UInt32 = 0
            var index = 0
            while index < bytes.count {
                var word: UInt32 = 0
                for offset in 0..<4 {
                    word = word << 8 | UInt32(index + offset < bytes.count ? bytes[index + offset] : 0)
                }
                sum &+= word
                index += 4
            }
            return Int(sum)
        }

        let tableCount = u16(font, 4)
        var tables: [(tag: [UInt8], data: [UInt8])] = (0..<tableCount).map { index in
            let record = 12 + 16 * index
            let offset = u32(font, record + 8)
            return (Array(font[record..<record + 4]), Array(font[offset..<offset + u32(font, record + 12)]))
        }

        let pairs = [(old.replacingOccurrences(of: " ", with: ""), new.replacingOccurrences(of: " ", with: "")), (old, new)]
        for index in tables.indices where tables[index].tag == Array("name".utf8) {
            let table = tables[index].data
            let count = u16(table, 2)
            let storage = u16(table, 4)
            var records: [UInt8] = []
            var strings: [UInt8] = []
            for record in 0..<count {
                let at = 6 + 12 * record
                let platform = u16(table, at)
                let encoding: String.Encoding = platform == 1 ? .macOSRoman : .utf16BigEndian
                let start = storage + u16(table, at + 10)
                var text = String(bytes: table[start..<start + u16(table, at + 8)], encoding: encoding) ?? ""
                for (before, after) in pairs { text = text.replacingOccurrences(of: before, with: after) }
                let raw = [UInt8](text.data(using: encoding) ?? Data())
                records += Array(table[at..<at + 8]) + be16(raw.count) + be16(strings.count)
                strings += raw
            }
            tables[index].data = be16(0) + be16(count) + be16(6 + records.count) + records + strings
        }

        var directory: [UInt8] = []
        var body: [UInt8] = []
        var offset = 12 + 16 * tables.count
        var headOffset: Int?
        for table in tables {
            var data = table.data
            if table.tag == Array("head".utf8) {
                data.replaceSubrange(8..<12, with: [0, 0, 0, 0])
                headOffset = offset
            }
            directory += table.tag + be32(checksum(data)) + be32(offset) + be32(data.count)
            data += [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
            body += data
            offset += data.count
        }
        var result = Array(font[0..<12]) + directory + body
        if let headOffset {
            let adjustment = Int(UInt32(0xB1B0_AFBA) &- UInt32(checksum(result)))
            result.replaceSubrange(headOffset + 8..<headOffset + 12, with: be32(adjustment))
        }
        return Data(result)
    }
}

/// Stands in for the device's settings, so a test writes no settings file.
@MainActor final class SavedChatFont {
    var id: String?

    init(_ id: String? = nil) { self.id = id }

    /// A store as the app makes it at launch, reading and saving the choice here.
    func store(library: CustomFontLibrary? = nil) -> ChatFontStore {
        ChatFontStore(saved: id, save: { [self] in id = $0 }, library: library)
    }
}
