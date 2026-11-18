import SwiftUI
import EnsembleKit

/// The state of the "Import Claude sessions" sheet: the scan, which folders are ticked, the trust checkbox, the import.
@MainActor
@Observable
final class ClaudeImportModel {
    enum Phase: Equatable {
        case scanning
        case ready
        case importing
        case finished(ClaudeImportResult)
    }

    private(set) var phase: Phase = .scanning
    private(set) var scan: ClaudeImportScan?
    /// Ticked folders (paths).
    var selected: Set<String> = []
    /// Off until the user ticks it: trusted folders load their own settings, hooks and MCP servers.
    var trustFolders = false
    /// The mode imported sessions start in (Ensemble's default).
    let permissionMode: PermissionMode

    @ObservationIgnored private let engine: ClaudeCodeEngine?
    @ObservationIgnored private let onImported: @MainActor (ClaudeImportResult) async -> Void

    init(engine: ClaudeCodeEngine?, permissionMode: PermissionMode, scan: ClaudeImportScan? = nil,
         onImported: @escaping @MainActor (ClaudeImportResult) async -> Void = { _ in }) {
        self.engine = engine
        self.permissionMode = permissionMode
        self.onImported = onImported
        if let scan { apply(scan) }
    }

    /// Scans again (when opened from the menu, or when the first scan is old).
    func load() async {
        guard let engine else { return }
        phase = .scanning
        apply(await engine.scanForImport())
    }

    func apply(_ scan: ClaudeImportScan) {
        self.scan = scan
        selected = Set(scan.folders.filter(\.selectedByDefault).map(\.path))
        phase = .ready
    }

    /// Shows a finished import (snapshots).
    func showResult(_ result: ClaudeImportResult) { phase = .finished(result) }

    // MARK: Selection

    var folders: [ClaudeImportFolder] { scan?.folders ?? [] }

    /// Folders with something to import.
    var selectableFolders: [ClaudeImportFolder] { folders.filter { !$0.newSessions.isEmpty } }

    func selectAll() { selected = Set(selectableFolders.map(\.path)) }
    func selectNone() { selected = [] }

    func toggle(_ folder: ClaudeImportFolder) {
        guard !folder.newSessions.isEmpty else { return }
        if selected.contains(folder.path) { selected.remove(folder.path) } else { selected.insert(folder.path) }
    }

    var selectedFolders: [ClaudeImportFolder] { folders.filter { selected.contains($0.path) && !$0.newSessions.isEmpty } }
    var selectedSessions: [ClaudeImportSession] { selectedFolders.flatMap(\.newSessions) }

    /// Ticked folders the trust checkbox would trust: existing ones Ensemble does not trust yet.
    var trustCandidates: [String] { selectedFolders.filter { $0.exists && !$0.trustedInEnsemble }.map(\.path) }

    /// Ticked folders the user already trusted in the claude CLI.
    var trustedInCLI: [ClaudeImportFolder] { selectedFolders.filter { $0.trustedInCLI && !$0.trustedInEnsemble } }

    // MARK: Import

    func runImport() async {
        guard let engine, phase == .ready, !selectedSessions.isEmpty else { return }
        phase = .importing
        let result = await engine.importSessions(selectedSessions, permissionMode: permissionMode,
                                                 trusting: trustFolders ? trustCandidates : [])
        await onImported(result)
        phase = .finished(result)
    }
}

/// Opens the import sheet from the File menu or the first-launch card, and decides when that card shows: once, when
/// the claude CLI has sessions and nothing has been imported yet.
@MainActor
@Observable
final class ClaudeImportCenter {
    static let shared = ClaudeImportCenter()

    /// The sheet's model while it is open.
    var model: ClaudeImportModel?
    /// The first-launch card, with what it found.
    private(set) var offer: ClaudeImportScan?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var offerChecked = false

    static let offeredKey = "claudeImport.offered"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isPresented: Bool {
        get { model != nil }
        set { if !newValue { model = nil } }
    }

    /// The Claude engine behind a store, if it has one.
    static func engine(for store: SessionStore) -> ClaudeCodeEngine? {
        (store.engine as? ClaudeCodeEngine) ?? (store.engine as? EngineRouter)?.engine(ClaudeCodeEngine.self)
    }

    static func canImport(_ store: SessionStore?) -> Bool { store.flatMap(engine(for:)) != nil }

    /// File > Import Claude Sessions...: opens the sheet and scans.
    func show(store: SessionStore) {
        guard model == nil, let engine = Self.engine(for: store) else { return }
        let reuse = offer
        offer = nil
        let model = makeModel(engine: engine, store: store, scan: reuse)
        self.model = model
        if reuse == nil { Task { await model.load() } }
    }

    /// Shows the first-launch card once the window has settled, if the claude CLI has sessions Ensemble does not.
    func offerIfNeeded(store: SessionStore) async {
        guard !offerChecked, !defaults.bool(forKey: Self.offeredKey), let engine = Self.engine(for: store) else { return }
        offerChecked = true
        try? await Task.sleep(for: .seconds(2))
        guard await engine.hasTranscriptsToImport() else { return }
        let scan = await engine.scanForImport()
        guard scan.hasNewSessions, model == nil, !defaults.bool(forKey: Self.offeredKey) else { return }
        withAnimation(.easeOut(duration: 0.2)) { offer = scan }
    }

    /// The card's Review button.
    func acceptOffer(store: SessionStore) {
        defaults.set(true, forKey: Self.offeredKey)
        show(store: store)
    }

    /// The card's Not now button: it does not come back; the File menu still has the import.
    func declineOffer() {
        defaults.set(true, forKey: Self.offeredKey)
        withAnimation(.easeOut(duration: 0.15)) { offer = nil }
    }

    private func makeModel(engine: ClaudeCodeEngine, store: SessionStore, scan: ClaudeImportScan?) -> ClaudeImportModel {
        ClaudeImportModel(engine: engine, permissionMode: store.defaultPermissionMode, scan: scan) { [defaults] result in
            defaults.set(true, forKey: Self.offeredKey)
            if result.imported > 0 { await store.reloadSessions() }
        }
    }
}
