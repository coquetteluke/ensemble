import SwiftUI
import Observation
import EnsembleKit

/// A model the session cannot switch to (it runs on another engine and the session has history), offered as a new
/// session instead.
struct ModelChangeOffer: Equatable {
    var sessionID: String
    var model: ModelRef
    var modelName: String
    var change: EngineChange
}

/// Open offers by session id. The composer of that session shows the bar; it goes when answered or when another model
/// is picked.
@MainActor @Observable
final class ModelChangeOffers {
    static let shared = ModelChangeOffers()
    var bySession: [String: ModelChangeOffer] = [:]
}

/// Picking a model from the composer, the `/model` command or the iPhone: the store decides what can happen
/// (`SessionStore.changeModel`) and this moves the draft and opens the session that replaces an empty one.
@MainActor
enum ModelSwitcher {
    static func pick(_ ref: ModelRef, session: SessionModel, store: SessionStore, window: WindowState) async {
        let sessionID = session.id
        ModelChangeOffers.shared.bySession[sessionID] = nil
        switch await store.changeModel(ref, for: sessionID) {
        case .switched, .stagedForNextMessage, .failed:
            break
        case .restarted(let from, let to):
            moveDraft(from: from, to: to, window: window)
            window.open(to, store: store)
        case .needsNewSession(let change):
            ModelChangeOffers.shared.bySession[sessionID] = ModelChangeOffer(
                sessionID: sessionID, model: ref, modelName: store.modelName(ref), change: change)
        }
    }

    /// "Start a new session with <model>": same folder and permission mode; the draft goes along.
    static func accept(_ offer: ModelChangeOffer, store: SessionStore, window: WindowState) async {
        ModelChangeOffers.shared.bySession[offer.sessionID] = nil
        guard let fresh = await store.startSession(like: offer.sessionID, model: offer.model) else { return }
        moveDraft(from: offer.sessionID, to: fresh.id, window: window)
        window.open(fresh.id, store: store)
    }

    static func decline(_ offer: ModelChangeOffer) {
        ModelChangeOffers.shared.bySession[offer.sessionID] = nil
    }

    /// "Trust and start": trusts the folder the engine refused (the home folder on its own), then does what was asked
    /// again. A folder that cannot be trusted is reported as an error.
    static func trustAndRetry(_ pending: PendingFolderTrust, store: SessionStore, window: WindowState) async {
        store.pendingFolderTrust = nil
        guard store.trustFolder(pending.folder) else {
            store.lastError = store.trustError(for: pending.folder) ?? "Could not trust \(pending.folder)."
            return
        }
        switch pending.retry {
        case .changeModel(let sessionID, let model):
            guard let session = store.session(sessionID) else { return }
            await pick(model, session: session, store: store, window: window)
            if store.trustNotes.refusals[sessionID] != nil {
                await store.sendRefusedMessageAgain(for: session)
            }
        case .startLike(let sessionID, let model):
            guard let fresh = await store.startSession(like: sessionID, model: model) else { return }
            moveDraft(from: sessionID, to: fresh.id, window: window)
            window.open(fresh.id, store: store)
        }
    }

    private static func moveDraft(from: String, to: String, window: WindowState) {
        window.drafts[to] = window.drafts[from]
        window.attachments[to] = window.attachments[from]
        window.drafts[from] = nil
        window.attachments[from] = nil
    }
}

/// Above the composer when the picked model runs on another engine and this session has history.
struct ModelChangeOfferBar: View {
    let offer: ModelChangeOffer
    let onStart: () -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.z(10)) {
            Image(systemName: "arrow.triangle.branch")
                .font(theme.font(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: theme.z(18), height: theme.z(18))
            VStack(alignment: .leading, spacing: theme.z(8)) {
                VStack(alignment: .leading, spacing: theme.z(2)) {
                    Text("\(offer.modelName) runs on \(offer.change.modelEngine)")
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("This conversation stays on \(offer.change.sessionEngine). A new session starts in the same folder and mode.")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FlowRow(spacing: theme.z(8)) {
                    Button("Start a new session with \(offer.modelName)", action: onStart)
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Cancel", action: onCancel)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(theme.z(12))
        .background(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(12), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(offer.modelName) needs a new session")
    }
}
