import SwiftUI
import UIKit

/// How the inner screen is laid out for the hinge. Read from `UIHingeInteraction` (iOS 27.1) at the root.
///
/// - `flat`: fully open (or no hinge): the panes sit side by side.
/// - `book`: partly folded with the crease running top to bottom: two pages that meet at the crease, so nothing
///   bends over the fold.
/// - `laptop`: partly folded with the crease running side to side: the chat on the top half, the message box and
///   the session list on the bottom half.
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
/// iOS reports "partly open" as soon as the hinge leaves flat, and "open" again only once it is flat. The layout
/// changes at that moment in one step. To keep the step from reading as a jump, the window is covered with a
/// picture of the old layout that fades out once the new one is drawn, so one dissolves into the other. The crease is the middle of
/// the physical screen, mapped into the window.
private final class HingeView: UIView {
    var onChange: ((FoldLayout) -> Void)?
    private var partlyOpen = false
    private var last: FoldLayout = .flat
    private var lastWindowSize: CGSize = .zero

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
        askAgainAfterScreenChange()
        publish()
    }

    /// The hinge is only ever reported, never readable. When the window lands on the other screen (the phone was
    /// opened from shut), switching the interaction off and on makes iOS report the hinge for the new window, in
    /// case the report for the move went to the old one.
    private func askAgainAfterScreenChange() {
        guard let size = window?.bounds.size, size != lastWindowSize else { return }
        let first = lastWindowSize == .zero
        lastWindowSize = size
        guard !first, #available(iOS 27.1, *) else { return }
        for case let interaction as UIHingeInteraction in interactions {
            interaction.isEnabled = false
            interaction.isEnabled = true
        }
    }

    private func publish() {
        let layout = computeLayout()
        guard layout != last else { return }
        last = layout
        WindowCrossfade.run(in: window)
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

/// Dissolves the window from what it shows now into whatever it shows after the next layout pass.
@MainActor
enum WindowCrossfade {
    static let duration: TimeInterval = 0.28

    /// Call right before changing the layout. The picture is taken now and sits on top without taking touches.
    /// It starts to fade only once the new layout has been drawn underneath: laying out a chat at a new width can
    /// take a few frames, and a fade that ran through that pause would be over before anything could be seen.
    static func run(in window: UIWindow?) {
        guard let window, let picture = window.snapshotView(afterScreenUpdates: false) else { return }
        picture.isUserInteractionEnabled = false
        picture.frame = window.bounds
        window.addSubview(picture)
        // The main queue runs this after the layout pass that the change is about to cause.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                picture.alpha = 0
            } completion: { _ in
                picture.removeFromSuperview()
            }
        }
    }

    /// The app's front window, for layout changes that start from a button instead of the hinge.
    static func runInKeyWindow() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        run(in: scenes.flatMap(\.windows).first(where: \.isKeyWindow))
    }
}

private struct HingeReader: UIViewRepresentable {
    @Binding var layout: FoldLayout

    func makeUIView(context: Context) -> HingeView {
        let view = HingeView()
        let binding = $layout
        view.onChange = { layout in
            // No SwiftUI animation: the new layout lands in one step under the fading picture of the old one.
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
