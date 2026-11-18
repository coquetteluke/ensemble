import SwiftUI
import EnsembleKit

/// Tells the power controller which sessions are working and which still exist, so holders release
/// after the grace period and deleted sessions stop holding. Attach once, high in the main window.
struct PowerSessionSync: ViewModifier {
    let store: SessionStore
    @Environment(PowerController.self) private var power: PowerController?

    func body(content: Content) -> some View {
        content
            .onChange(of: workingIDs, initial: true) { _, ids in
                power?.syncWorking(ids, kind: .session)
            }
            .onChange(of: existingIDs, initial: true) { _, ids in
                // Only a fully loaded list can say a session was deleted.
                if let ids { power?.syncExisting(ids, kind: .session) }
            }
    }

    /// Top-level sessions where an agent (or one of its subagents) is running.
    private var workingIDs: Set<PowerHolderID> {
        Set(store.sessions.filter { !$0.isSubagent && store.isRunning($0.id) }.map { PowerHolderID.session($0.id) })
    }

    private var existingIDs: Set<PowerHolderID>? {
        store.isLoaded ? Set(store.sessions.map { PowerHolderID.session($0.id) }) : nil
    }
}

/// The same for rooms: pass the ids of running rooms and, once rooms are loaded, of all rooms.
struct PowerRoomSync: ViewModifier {
    let working: Set<UUID>
    /// nil until the room list is loaded.
    let existing: Set<UUID>?
    @Environment(PowerController.self) private var power: PowerController?

    func body(content: Content) -> some View {
        content
            .onChange(of: working, initial: true) { _, ids in
                power?.syncWorking(Set(ids.map(PowerHolderID.room)), kind: .room)
            }
            .onChange(of: existing, initial: true) { _, ids in
                if let ids { power?.syncExisting(Set(ids.map(PowerHolderID.room)), kind: .room) }
            }
    }
}

extension View {
    /// Keeps the power controller in step with the store's sessions.
    func powerSessionSync(store: SessionStore) -> some View {
        modifier(PowerSessionSync(store: store))
    }

    /// Keeps the power controller in step with the rooms.
    func powerRoomSync(working: Set<UUID>, existing: Set<UUID>?) -> some View {
        modifier(PowerRoomSync(working: working, existing: existing))
    }
}
