import Foundation
import Observation
import Synchronization

/// What a font is chosen for.
public enum FontRole: String, Codable, CaseIterable, Sendable, Identifiable {
    /// What agents write: replies, plans, questions.
    case chat
    /// Everything else: lists, buttons, menus, your own messages. Code stays in the system's fixed-width font.
    case interface

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chat: "Chat font"
        case .interface: "Interface font"
        }
    }

    /// Used until a font is chosen for the role, and whenever the chosen one is missing.
    public var standard: AppFont {
        switch self {
        case .chat: .ensembleSerif
        case .interface: .inter
        }
    }

    /// The line shown in each font in Settings. Markdown, so `Text` draws the bold and the italic in that font.
    public var sample: String {
        switch self {
        case .chat: "Replies look like this, with **bold** and *italic*."
        case .interface: "Lists, buttons and menus look like this, with **bold**."
        }
    }
}

/// What a device remembers about its fonts, and what it tells the other device when the two sync
/// (`FontSync`): the font chosen for each role and when, and which added fonts were removed and when.
/// The newer entry wins on both sides.
public struct FontLedger: Codable, Hashable, Sendable {
    public struct Choice: Codable, Hashable, Sendable {
        public var id: String
        public var changedAt: Date

        public init(id: String, changedAt: Date) {
            self.id = id
            self.changedAt = changedAt
        }
    }

    public var chat: Choice
    public var interface: Choice
    /// Added families that were removed, by family name. Stops the other device from sending a removed font back.
    public var removed: [String: Date]

    public init(chat: Choice, interface: Choice, removed: [String: Date] = [:]) {
        self.chat = chat
        self.interface = interface
        self.removed = removed
    }

    /// Nothing chosen yet: both roles on their default, older than any real choice.
    public static let initial = FontLedger(
        chat: Choice(id: FontRole.chat.standard.id, changedAt: .distantPast),
        interface: Choice(id: FontRole.interface.standard.id, changedAt: .distantPast)
    )

    public subscript(role: FontRole) -> Choice {
        get { role == .chat ? chat : interface }
        set {
            switch role {
            case .chat: chat = newValue
            case .interface: interface = newValue
            }
        }
    }
}

/// The fonts chosen on this device, and the fonts added to it.
///
/// `.ensembleTheme()` reads `chat` and `interface`, so every window redraws in the new font as soon as a choice
/// changes. The choices are saved in this device's settings. When the Mac and the iPhone are connected they
/// sync (`FontSync`): the newer choice wins on both, and added font files are copied across.
@Observable @MainActor
public final class FontStore {
    /// The app-wide store, made on first use. Snapshot rendering sets `FontStore.temporary()` first, so the
    /// saved choices and the added fonts of this device are never read there.
    public static var shared: FontStore {
        get {
            if let existing { return existing }
            let store = FontStore()
            existing = store
            CurrentFonts.setInterface(store.interface)
            return store
        }
        set {
            existing = newValue
            CurrentFonts.setInterface(newValue.interface)
        }
    }

    private static var existing: FontStore?

    public static let storageKey = "fonts"

    /// Whether a change was made on this device or arrived from the other one.
    public enum Origin: Sendable {
        case here
        case otherDevice
    }

    /// The font agent text is drawn in: the chosen one, or the default when the chosen one is missing.
    public private(set) var chat: AppFont = FontRole.chat.standard
    /// The font of everything else, with the same fallback.
    public private(set) var interface: AppFont = FontRole.interface.standard
    /// Every font that can be chosen: the built-in ones this system has, then the added ones.
    public private(set) var choices: [AppFont] = AppFont.availableBuiltIn
    public private(set) var customFamilies: [CustomFontLibrary.Family] = []

    /// The choices with their dates, and the removed fonts. Sent to the other device when syncing.
    @ObservationIgnored public private(set) var ledger: FontLedger
    @ObservationIgnored private let save: @MainActor (FontLedger) -> Void
    @ObservationIgnored private let library: CustomFontLibrary?
    @ObservationIgnored private var listeners: [UUID: AsyncStream<Origin>.Continuation] = [:]

    /// - Parameters:
    ///   - saved: what this device saved earlier, if anything.
    ///   - save: called with the ledger whenever it changes.
    ///   - library: where added fonts live; nil for a store without added fonts.
    public init(saved: FontLedger?, save: @escaping @MainActor (FontLedger) -> Void = { _ in }, library: CustomFontLibrary?) {
        self.save = save
        self.library = library
        ledger = saved ?? .initial
        refresh()
    }

    /// The store the apps use: the ledger is kept in this device's settings under `storageKey`.
    public convenience init(defaults: UserDefaults = .standard, library: CustomFontLibrary? = CustomFontLibrary()) {
        let saved = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(FontLedger.self, from: $0) }
        self.init(
            saved: saved,
            save: { ledger in
                if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.storageKey) }
            },
            library: library
        )
    }

    /// A store that reads and saves nothing, for snapshots and previews.
    public static func temporary() -> FontStore { FontStore(saved: nil, library: nil) }

    /// The folder added fonts are copied into, for the line under "Add Font".
    public var customFontFolder: URL? { library?.folder }

    public func font(for role: FontRole) -> AppFont {
        switch role {
        case .chat: chat
        case .interface: interface
        }
    }

    public func select(_ font: AppFont, for role: FontRole = .chat, at date: Date = Date()) {
        ledger[role] = FontLedger.Choice(id: font.id, changedAt: after(ledger[role].changedAt, date))
        commit(.here)
    }

    /// Adds font files. Returns one line for each file that was not added.
    @discardableResult
    public func add(_ files: [URL]) -> [String] {
        let problems = install(files)
        commit(.here)
        return problems
    }

    /// Removes an added family. A role that used it goes back to its default.
    public func remove(_ font: AppFont, at date: Date = Date()) {
        guard let library, case .custom(let name) = font.source,
              let family = customFamilies.first(where: { $0.name == name }) else { return }
        library.remove(family)
        ledger.removed[name] = after(family.addedAt, date)
        for role in FontRole.allCases where ledger[role].id == font.id {
            ledger[role] = FontLedger.Choice(id: role.standard.id, changedAt: after(ledger[role].changedAt, date))
        }
        commit(.here)
    }

    /// `date`, or just after `known` when the clock says it is earlier. What is done on this device now always
    /// counts as newer than what this device has already seen, even if the other device's clock runs ahead.
    private func after(_ known: Date, _ date: Date) -> Date {
        known < date ? date : known.addingTimeInterval(0.001)
    }

    // MARK: Syncing with the other device

    /// Takes over what the other device knows wherever it is newer: its choices, and the fonts it removed.
    /// Returns whether anything changed here.
    @discardableResult
    public func merge(_ other: FontLedger) -> Bool {
        var merged = ledger
        for role in FontRole.allCases where other[role].changedAt > merged[role].changedAt {
            merged[role] = other[role]
        }
        for (family, date) in other.removed where date > (merged.removed[family] ?? .distantPast) {
            merged.removed[family] = date
        }
        // A family removed over there after it was added here goes here too.
        let gone = customFamilies.filter { isRemoved($0.name, addedAt: $0.addedAt, in: merged) }
        guard merged != ledger || !gone.isEmpty else { return false }
        ledger = merged
        gone.forEach { library?.remove($0) }
        commit(.otherDevice)
        return true
    }

    /// Adds font files that arrived from the other device. Returns one line for each file that was not added.
    @discardableResult
    public func receive(_ files: [URL]) -> [String] {
        let problems = install(files)
        commit(.otherDevice)
        return problems
    }

    /// Whether `family` was removed (on either device) after it was added at `addedAt`. Such a font is not sent
    /// and not asked for.
    public func isRemoved(_ family: String, addedAt: Date) -> Bool {
        isRemoved(family, addedAt: addedAt, in: ledger)
    }

    /// Every change to the choices or the added fonts, with where it came from. Ends when the reader stops.
    public func changes() -> AsyncStream<Origin> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
        }
    }

    private func isRemoved(_ family: String, addedAt: Date, in ledger: FontLedger) -> Bool {
        guard let removedAt = ledger.removed[family] else { return false }
        return removedAt > addedAt
    }

    private func install(_ files: [URL]) -> [String] {
        guard let library else { return [] }
        var problems: [String] = []
        for file in files {
            do {
                try library.add(file)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        return problems
    }

    private func commit(_ origin: Origin) {
        save(ledger)
        refresh()
        listeners.values.forEach { $0.yield(origin) }
    }

    private func refresh() {
        customFamilies = library?.families() ?? []
        choices = AppFont.availableBuiltIn + customFamilies.map { AppFont.custom(family: $0.name) }
        chat = choices.first { $0.id == ledger.chat.id } ?? FontRole.chat.standard
        interface = choices.first { $0.id == ledger.interface.id } ?? FontRole.interface.standard
        if Self.existing === self { CurrentFonts.setInterface(interface) }
    }
}

/// The interface font for code that cannot wait for the main actor (a font asked for outside a view body).
/// The app-wide `FontStore` keeps it current.
public enum CurrentFonts {
    private static let interfaceFont = Mutex<AppFont>(FontRole.interface.standard)

    public static var interface: AppFont { interfaceFont.withLock { $0 } }

    static func setInterface(_ font: AppFont) { interfaceFont.withLock { $0 = font } }
}
