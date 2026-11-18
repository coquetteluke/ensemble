import SwiftUI
import EnsembleKit

extension View {
    /// The "Import Claude sessions" sheet (opened from File > Import Claude Sessions...) and the one-time card that
    /// offers it on first launch. Attach once to the main window's content: `.claudeImport(store: store)`.
    func claudeImport(store: SessionStore) -> some View {
        modifier(ClaudeImportPresenter(store: store))
    }
}

private struct ClaudeImportPresenter: ViewModifier {
    let store: SessionStore
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        @Bindable var center = ClaudeImportCenter.shared
        content
            .overlay(alignment: .bottomTrailing) {
                if let offer = center.offer, center.model == nil, !isSnapshot {
                    ClaudeImportOfferCard(scan: offer, review: { center.acceptOffer(store: store) }, dismiss: center.declineOffer)
                        .padding(theme.z(18))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $center.isPresented) {
                if let model = center.model {
                    ClaudeImportSheet(model: model) { center.model = nil }
                        .ensembleTheme()
                }
            }
            .task(id: ObjectIdentifier(store)) {
                guard !isSnapshot else { return }
                await center.offerIfNeeded(store: store)
            }
    }
}

/// The first-launch offer: what was found, Review... (opens the sheet) and Not now. Shown once.
struct ClaudeImportOfferCard: View {
    let scan: ClaudeImportScan
    let review: () -> Void
    let dismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.z(10)) {
            HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: theme.z(13)))
                    .foregroundStyle(theme.accent)
                Text("Import Claude sessions")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
            }
            Text(summary)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: theme.z(8)) {
                Spacer()
                Button("Not now", action: dismiss)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Review...", action: review)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(theme.z(14))
        .frame(width: theme.z(330))
        .background(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous).fill(theme.popover))
        .overlay(RoundedRectangle(cornerRadius: theme.z(11), style: .continuous).strokeBorder(theme.border))
        .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.12), radius: theme.z(16), y: theme.z(6))
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        let folders = scan.folders.filter { !$0.newSessions.isEmpty }.count
        return "\(ClaudeImportSheet.count(scan.newSessionCount, "session")) in \(ClaudeImportSheet.count(folders, "folder")) "
            + "from the claude CLI and the Claude desktop app. They open in Ensemble and resume where they left off."
    }
}
