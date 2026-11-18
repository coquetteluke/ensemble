import AppKit
import EnsembleKit

/// The menu bar icon: Ensemble's mark with the number of agents working (the mark fills in while a session
/// needs you). Its menu lists sessions that need you and sessions running, each opens that session, then
/// Open Ensemble.
///
/// Plain AppKit on purpose: SwiftUI's `MenuBarExtra(isInserted:)` writes its binding back to UserDefaults on every
/// update, and with the app's `@AppStorage` that re-runs the scene in a loop at full CPU.
@MainActor
final class AttentionStatusItem: NSObject, NSMenuDelegate {
    static let symbol = "point.3.connected.trianglepath.dotted"
    static let needsYouSymbol = "point.3.filled.connected.trianglepath.dotted"

    private weak var center: AttentionCenter?
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var shownSymbol: String?
    private var shownCount: Int?

    init(center: AttentionCenter) {
        self.center = center
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// Shows, updates or removes the icon.
    func update(totals: SessionAttentionTotals, visible: Bool) {
        guard visible else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownSymbol = nil
            shownCount = nil
            return
        }
        let item = self.item ?? makeItem()
        guard let button = item.button else { return }
        let symbol = totals.needsYou > 0 ? Self.needsYouSymbol : Self.symbol
        if shownSymbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            shownSymbol = symbol
        }
        if shownCount != totals.running {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: totals.running > 0 ? " \(totals.running)" : "",
                                                        attributes: [.font: font])
            shownCount = totals.running
        }
        var label = ["Ensemble", totals.running == 1 ? "1 agent running" : "\(totals.running) agents running"]
        if totals.needsYou > 0 { label.append(totals.needsYou == 1 ? "1 session needs you" : "\(totals.needsYou) sessions need you") }
        button.setAccessibilityLabel(label.joined(separator: ", "))
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.menu = menu
        self.item = item
        return item
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let center else { return }
        let needsYou = center.needsYouSessions
        let running = center.runningSessions

        if !needsYou.isEmpty {
            menu.addItem(.sectionHeader(title: "Needs you"))
            for session in needsYou { menu.addItem(sessionItem(session)) }
        }
        if center.extraCount > 0 {
            if needsYou.isEmpty { menu.addItem(.sectionHeader(title: "Needs you")) }
            let rooms = NSMenuItem(title: center.extraCount == 1 ? "1 room waiting for you" : "\(center.extraCount) rooms waiting for you",
                                   action: #selector(openApp), keyEquivalent: "")
            rooms.target = self
            menu.addItem(rooms)
        }
        if !running.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: "Running"))
            for session in running { menu.addItem(sessionItem(session)) }
        }
        if menu.numberOfItems == 0 {
            let none = NSMenuItem(title: "No agents running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Ensemble", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    private func sessionItem(_ session: SessionAttentionSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: session.title, action: #selector(openSession(_:)), keyEquivalent: "")
        item.subtitle = Format.folderName(session.directory)
        item.representedObject = session.id
        item.target = self
        return item
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        center?.open(id)
    }

    @objc private func openApp() {
        center?.showMainWindow()
    }
}
