import CoreText
import Foundation
import UniformTypeIdentifiers

/// Font files the owner added ("Add Font" in Settings), on this device or on the paired one.
///
/// A file is checked, copied into the app's own Application Support folder and registered for this process.
/// The files are not part of the repository or of a build. They travel only between the owner's own paired
/// Mac and iPhone, over the encrypted remote connection (`FontSync`). The folder is left out of device backups.
public struct CustomFontLibrary: Sendable {
    /// Largest font file that is accepted. Text families are well under this; it keeps a wrong file out.
    public static let maxFileSize = 25 * 1024 * 1024
    public static let fileExtensions = ["ttf", "otf"]
    /// Most files the folder may hold, so a paired device cannot fill the disk with fonts.
    public static let maxFiles = 120
    /// The same two kinds, for the file picker.
    public static var contentTypes: [UTType] {
        fileExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .font) }
    }

    /// `Application Support/Ensemble/Fonts`, in the home folder on the Mac and in the app's container on the iPhone.
    public static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ensemble/Fonts", isDirectory: true)
    }

    public let folder: URL

    public init(folder: URL = CustomFontLibrary.defaultFolder) {
        self.folder = folder
    }

    /// One added family and the files that make it up (regular, bold, italic and so on).
    public struct Family: Identifiable, Hashable, Sendable {
        public let name: String
        public let files: [URL]
        /// When the newest of its files was copied in. A removal on the other device that is older than this
        /// does not take the family away again.
        public let addedAt: Date
        public var id: String { name }
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case wrongType(file: String)
        case tooLarge(file: String)
        case unreadable(file: String)
        case notAFont(file: String)
        case alreadyListed(family: String)
        case notSaved(file: String)
        case tooMany

        public var errorDescription: String? {
            switch self {
            case .wrongType(let file): "\(file) is not a .ttf or .otf file."
            case .tooLarge(let file): "\(file) is larger than \(CustomFontLibrary.maxFileSize / 1024 / 1024) MB."
            case .unreadable(let file): "\(file) could not be read."
            case .notAFont(let file): "\(file) is not a font that can be used."
            case .alreadyListed(let family): "\(family) is already in the list."
            case .notSaved(let file): "\(file) could not be saved."
            case .tooMany: "There are already \(CustomFontLibrary.maxFiles) added font files. Remove a font first."
            }
        }
    }

    /// Every added family, by name. Registers the files it finds, so call it once before the fonts are drawn.
    public func families() -> [Family] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var byFamily: [String: [URL]] = [:]
        for file in files where Self.fileExtensions.contains(file.pathExtension.lowercased()) {
            guard let family = Self.familyName(of: Self.descriptors(at: file)) else { continue }
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            byFamily[family, default: []].append(file)
        }
        return byFamily
            .map { name, files in
                Family(name: name, files: files.sorted { $0.lastPathComponent < $1.lastPathComponent },
                       addedAt: files.compactMap(Self.creationDate).max() ?? .distantPast)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Checks one file, copies it in and registers it. Returns the family name it is listed under.
    @discardableResult
    public func add(_ source: URL) throws -> String {
        let fileName = source.lastPathComponent
        let fileExtension = source.pathExtension.lowercased()
        guard Self.fileExtensions.contains(fileExtension) else { throw ImportError.wrongType(file: fileName) }

        // A file picked in the Files app or on another volume is readable only inside this scope.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw ImportError.unreadable(file: fileName)
        }
        guard size <= Self.maxFileSize else { throw ImportError.tooLarge(file: fileName) }
        guard let data = try? Data(contentsOf: source), !data.isEmpty else { throw ImportError.unreadable(file: fileName) }
        guard data.count <= Self.maxFileSize else { throw ImportError.tooLarge(file: fileName) }

        let found = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] ?? []
        guard let family = Self.familyName(of: found), let faceName = Self.faceName(of: found) else {
            throw ImportError.notAFont(file: fileName)
        }
        guard !AppFont.builtInFamilies.contains(family) else { throw ImportError.alreadyListed(family: family) }

        // Named after the face inside the file, never after the name it arrived with, so adding the same face
        // again replaces the earlier copy and a file name cannot point outside the folder.
        let destination = folder.appendingPathComponent(Self.safeFileName(faceName) + "." + fileExtension)
        if !FileManager.default.fileExists(atPath: destination.path), fileCount() >= Self.maxFiles {
            throw ImportError.tooMany
        }
        do {
            try prepareFolder()
            if FileManager.default.fileExists(atPath: destination.path) {
                CTFontManagerUnregisterFontsForURL(destination as CFURL, .process, nil)
            }
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ImportError.notSaved(file: fileName)
        }

        var failure: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(destination as CFURL, .process, &failure) {
            let code = failure.map { CFErrorGetCode($0.takeRetainedValue()) }
            // A face the system already has (installed in Font Book, say) is usable as it is. Anything else
            // means the file cannot be drawn with, so the copy goes.
            let usable = code == CTFontManagerError.alreadyRegistered.rawValue
                || code == CTFontManagerError.duplicatedName.rawValue
            if !usable {
                try? FileManager.default.removeItem(at: destination)
                throw ImportError.notAFont(file: fileName)
            }
        }
        return family
    }

    /// Unregisters a family and deletes its files.
    public func remove(_ family: Family) {
        for file in family.files where file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = folder
        try? folder.setResourceValues(values)
    }

    private func fileCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .count { Self.fileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    private static func creationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private static func descriptors(at file: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []
    }

    private static func familyName(of descriptors: [CTFontDescriptor]) -> String? {
        descriptors.lazy
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
            .first { !$0.isEmpty }
    }

    private static func faceName(of descriptors: [CTFontDescriptor]) -> String? {
        descriptors.lazy
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            .first { !$0.isEmpty }
    }

    /// Letters, digits, "-" and "_" only, at most 80 characters.
    static func safeFileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "-" }.prefix(80))
        return cleaned.isEmpty ? "font" : cleaned
    }
}
