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

/// Watches the hinge and works out the fold layout, with the crease where it is on the glass.
///
/// iOS resizes the app's window itself when the hinge leaves flat (with its own blur and crossfade). The layout is
/// switched in the same moment and without an animation of its own, so it happens inside that one system transition
/// instead of a second one after it. The crease is the middle of the physical screen, mapped into the window, since
/// the window can be narrower than the screen while folded.
private final class HingeView: UIView {
    var onChange: ((FoldLayout) -> Void)?
    private var partlyOpen = false
    private var last: FoldLayout = .flat

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                self.partlyOpen = update.hinge?.status == .partiallyOpen
                self.publish()
            }
            addInteraction(interaction)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        publish()
    }

    private func publish() {
        let layout = computeLayout()
        guard layout != last else { return }
        last = layout
        onChange?(layout)
    }

    private func computeLayout() -> FoldLayout {
        guard partlyOpen, let window, let screen = window.windowScene?.screen else { return .flat }
        let screenBounds = screen.bounds
        let crease = window.convert(CGPoint(x: screenBounds.midX, y: screenBounds.midY), from: screen.coordinateSpace)
        let size = window.bounds.size
        return size.width >= size.height ? .book(creaseX: crease.x) : .laptop(creaseY: crease.y)
    }
}

private struct HingeReader: UIViewRepresentable {
    @Binding var layout: FoldLayout

    func makeUIView(context: Context) -> HingeView {
        let view = HingeView()
        let binding = $layout
        view.onChange = { layout in
            // No animation of our own: the change lands inside the system's resize transition.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { binding.wrappedValue = layout }
        }
        return view
    }

    func updateUIView(_ uiView: HingeView, context: Context) {}
}

/// Reads the hinge and hands the fold layout to everything below.
struct FoldAware<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var layout: FoldLayout = .flat

    var body: some View {
        content
            .environment(\.foldLayout, layout)
            .background {
                HingeReader(layout: $layout)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
    }
}
