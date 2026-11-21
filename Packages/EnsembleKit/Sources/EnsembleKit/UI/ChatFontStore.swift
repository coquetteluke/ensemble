import Foundation
import Observation

/// The chat font chosen on this device, and the fonts added on it.
///
/// `.ensembleTheme()` reads `current`, so every window draws agent text in the new font as soon as the choice
/// changes. The choice is saved in this device's settings; the Mac and the iPhone each keep their own.
@Observable @MainActor
public final class ChatFontStore {
    /// The app-wide store, made on first use. Snapshot rendering sets `ChatFontStore.temporary()` first, so the
    /// saved choice and the added fonts of this device are never read there.
    public static var shared: ChatFontStore {
        get {
            if let existing { return existing }
            let store = ChatFontStore()
            existing = store
            return store
        }
        set { existing = newValue }
    }

    private static var existing: ChatFontStore?

    public static let storageKey = "chatFont"

    /// The font agent text is drawn in: the chosen one, or the default when the chosen one is missing.
    public private(set) var current: ChatFont = .standard
    /// Every font that can be chosen: the built-in ones this system has, then the added ones.
    public private(set) var choices: [ChatFont] = ChatFont.availableBuiltIn
    public private(set) var customFamilies: [CustomFontLibrary.Family] = []

    @ObservationIgnored private let save: @MainActor (String?) -> Void
    @ObservationIgnored private let library: CustomFontLibrary?
    @ObservationIgnored private var selectedID: String

    /// - Parameters:
    ///   - saved: the id of the font chosen earlier, if any.
    ///   - save: called with the new id when the choice changes, and with nil when it goes back to the default.
    ///   - library: where added fonts live; nil for a store without added fonts.
    public init(saved: String?, save: @escaping @MainActor (String?) -> Void = { _ in }, library: CustomFontLibrary?) {
        self.save = save
        self.library = library
        selectedID = saved ?? ChatFont.standard.id
        refresh()
    }

    /// The store the apps use: the choice is kept in this device's settings under `storageKey`.
    public convenience init(defaults: UserDefaults = .standard, library: CustomFontLibrary? = CustomFontLibrary()) {
        self.init(
            saved: defaults.string(forKey: Self.storageKey),
            save: { id in
                if let id {
                    defaults.set(id, forKey: Self.storageKey)
                } else {
                    defaults.removeObject(forKey: Self.storageKey)
                }
            },
            library: library
        )
    }

    /// A store that reads and saves nothing, for snapshots and previews.
    public static func temporary() -> ChatFontStore { ChatFontStore(saved: nil, library: nil) }

    /// The folder added fonts are copied into, for the line under "Add Font".
    public var customFontFolder: URL? { library?.folder }

    public func select(_ font: ChatFont) {
        selectedID = font.id
        save(font.id)
        refresh()
    }

    /// Adds font files. Returns one line for each file that was not added.
    @discardableResult
    public func add(_ files: [URL]) -> [String] {
        guard let library else { return [] }
        var problems: [String] = []
        for file in files {
            do {
                try library.add(file)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        refresh()
        return problems
    }

    /// Removes an added family. If it was the chosen font, agent text goes back to the default.
    public func remove(_ font: ChatFont) {
        guard let library, case .custom(let name) = font.source,
              let family = customFamilies.first(where: { $0.name == name }) else { return }
        library.remove(family)
        if selectedID == font.id {
            selectedID = ChatFont.standard.id
            save(nil)
        }
        refresh()
    }

    private func refresh() {
        customFamilies = library?.families() ?? []
        choices = ChatFont.availableBuiltIn + customFamilies.map { ChatFont.custom(family: $0.name) }
        current = choices.first { $0.id == selectedID } ?? .standard
    }
}
