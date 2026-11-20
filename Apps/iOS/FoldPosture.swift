import SwiftUI
import UIKit

/// How the inner screen is laid out for the hinge. Read from `UIHingeInteraction` (iOS 27.1) at the root.
///
/// - `flat`: fully open (or no hinge): the normal split view.
/// - `book`: partly folded with the crease running top to bottom: two pages that meet at the crease, the session
///   list on the left page and the chat on the right, so nothing bends over the fold.
/// - `laptop`: partly folded with the crease running side to side: the chat on the top half, the message box on
///   the bottom half.
///
/// The crease position is in global coordinates, measured from the full screen (the hinge sits in the middle).
enum FoldLayout: Equatable {
    case flat
    case book(creaseX: CGFloat)
    case laptop(creaseY: CGFloat)

    var isFolded: Bool { self != .flat }
}

private struct FoldLayoutKey: EnvironmentKey {
    static let defaultValue = FoldLayout.flat
}

extension EnvironmentValues {
    var foldLayout: FoldLayout {
        get { self[FoldLayoutKey.self] }
        set { self[FoldLayoutKey.self] = newValue }
    }
}

/// Space kept clear on each side of the crease, where the screen bends.
enum FoldMetrics {
    static let creaseGutter: CGFloat = 14
}

/// Decides when the phone counts as folded, from the hinge's status and angle.
///
/// Folding is a continuous motion, so the layout switches once, with a dead zone: it folds below 160 degrees and
/// unfolds above 170 degrees (or when the hinge reports fully open or closed), and in between it keeps what it has.
/// A change only lands after the hinge has held it for a moment, so a hand that wobbles near the edge does not make
/// the screen flip back and forth.
@available(iOS 27.1, *)
@MainActor
final class FoldDecider {
    static let foldBelow: CGFloat = 160 * .pi / 180
    static let unfoldAbove: CGFloat = 170 * .pi / 180
    static let settle: Duration = .milliseconds(140)

    private(set) var folded = false
    private var pending: Task<Void, Never>?

    /// The folded state this reading points to, given the current one.
    static func wantsFolded(status: UIHinge.Status, angle: CGFloat, current: Bool) -> Bool {
        switch status {
        case .partiallyOpen:
            if angle < foldBelow { return true }
            if angle > unfoldAbove { return false }
            return current
        default:
            return false
        }
    }

    func update(status: UIHinge.Status, angle: CGFloat, apply: @escaping @MainActor (Bool) -> Void) {
        let wanted = Self.wantsFolded(status: status, angle: angle, current: folded)
        pending?.cancel()
        guard wanted != folded else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard let self, !Task.isCancelled, wanted != self.folded else { return }
            self.folded = wanted
            apply(wanted)
        }
    }
}

/// Whether the phone is folded, from a `UIHingeInteraction` on an invisible view.
private struct HingeReader: UIViewRepresentable {
    @Binding var partlyOpen: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let binding = $partlyOpen
            let decider = FoldDecider()
            let interaction = UIHingeInteraction { _, update in
                guard let hinge = update.hinge else {
                    decider.update(status: .unknown, angle: .pi) { folded in binding.wrappedValue = folded }
                    return
                }
                decider.update(status: hinge.status, angle: hinge.angle) { folded in
                    withAnimation(.smooth(duration: 0.38)) { binding.wrappedValue = folded }
                }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Reads the hinge and the full screen size, and hands the fold layout to everything below.
struct FoldAware<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var partlyOpen = false
    @State private var screen: CGSize = .zero

    var body: some View {
        content
            .environment(\.foldLayout, layout)
            .background {
                HingeReader(partlyOpen: $partlyOpen)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .background {
                // The whole screen, safe areas included, so the crease lands in the middle of the glass.
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { screen = proxy.frame(in: .global).size }
                        .onChange(of: proxy.frame(in: .global).size) { _, size in screen = size }
                }
                .ignoresSafeArea()
            }
    }

    private var layout: FoldLayout {
        guard partlyOpen, screen.width > 0, screen.height > 0 else { return .flat }
        return screen.width >= screen.height ? .book(creaseX: screen.width / 2) : .laptop(creaseY: screen.height / 2)
    }
}
