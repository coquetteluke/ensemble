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
/// changes at that moment in one step, under a soft blur (`LayoutTransition`), so the change reads as one move in
/// time with the blur iOS puts on the moving half of the screen. The crease is the middle of the physical screen,
/// mapped into the window.
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in LayoutTransition.warmUp(self?.window) }
    }

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
        LayoutTransition.run(in: window) { [weak self] in self?.onChange?(layout) }
    }

    private func computeLayout() -> FoldLayout {
        guard partlyOpen, let window, let screen = window.windowScene?.screen else { return .flat }
        let screenBounds = screen.bounds
        let crease = window.convert(CGPoint(x: screenBounds.midX, y: screenBounds.midY), from: screen.coordinateSpace)
        let size = window.bounds.size
        return size.width >= size.height ? .book(creaseX: crease.x) : .laptop(creaseY: crease.y)
    }
}

/// How the inner screen moves from one layout to another, for the hinge and for the pane buttons.
///
/// Working out a chat at a new width takes the main thread a few frames. A transition that only starts after that
/// work reads as a freeze and then a jump, and a plain crossfade shows both layouts doubled halfway through. So:
/// - a soft blur starts to build at once. It is handed to the system's renderer before the layout work begins, so
///   it keeps building through that work;
/// - a picture of the old layout sits under the blur and the new layout lands beneath it in one step;
/// - once the blur is strong enough to hide the swap, the picture is let go and the blur eases off the new layout.
/// The blur never gets far: the text goes soft, the screen does not go blank. iOS blurs the moving half of the
/// screen for about as long, so the two read as one move.
@MainActor
enum LayoutTransition {
    enum Pace {
        /// The hinge: unhurried, in time with the system's own blur.
        case fold
        /// A button: quicker.
        case button

        /// How long the blur builds before the layouts are swapped.
        var build: TimeInterval { self == .fold ? 0.26 : 0.15 }
        var settle: TimeInterval { self == .fold ? 0.36 : 0.26 }
    }

    /// How long the blur would take to build fully. It is turned around long before that.
    private static let fullBuild: TimeInterval = 0.7
    private static let swap: TimeInterval = 0.12
    /// The transition in flight, so a second change (a quick fold and unfold) ends the first cleanly.
    private static var cleanup: (() -> Void)?

    static func run(in window: UIWindow?, pace: Pace = .fold, change: @escaping @MainActor () -> Void) {
        guard let window else { change(); return }
        cleanup?()
        cleanup = nil

        let picture = window.snapshotView(afterScreenUpdates: false)
        if let picture {
            picture.isUserInteractionEnabled = false
            picture.frame = window.bounds
            window.addSubview(picture)
        }
        // No blur with Reduce Transparency: the picture alone dissolves.
        let veil: UIVisualEffectView? = UIAccessibility.isReduceTransparencyEnabled ? nil : UIVisualEffectView(effect: nil)
        var build: UIViewPropertyAnimator?
        if let veil {
            veil.isUserInteractionEnabled = false
            veil.frame = window.bounds
            veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(veil)
            let animator = UIViewPropertyAnimator(duration: fullBuild, curve: .linear) {
                veil.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            }
            animator.startAnimation()
            build = animator
        }
        var finished = false
        let end = {
            guard !finished else { return }
            finished = true
            if build?.state == .active { build?.stopAnimation(true) }
            picture?.removeFromSuperview()
            veil?.removeFromSuperview()
        }
        cleanup = end
        // Hand the picture and the blur to the renderer now. They then run on their own while the main thread lays out.
        CATransaction.flush()
        let started = CACurrentMediaTime()

        DispatchQueue.main.async {
            change()
            // The main queue gets to this only once the layout pass has finished. With a blur, give it time to build.
            let wait = veil == nil ? 0.03 : max(0.03, pace.build - (CACurrentMediaTime() - started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard !finished else { return }
                guard let veil else {
                    UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                        picture?.alpha = 0
                    } completion: { _ in end() }
                    return
                }
                UIView.animate(withDuration: swap, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    picture?.alpha = 0
                }
                if let build, build.isRunning {
                    // Turn the blur around from wherever it has got to.
                    build.pauseAnimation()
                    build.isReversed = true
                    build.addCompletion { _ in end() }
                    build.continueAnimation(withTimingParameters: UICubicTimingParameters(animationCurve: .easeInOut),
                                            durationFactor: pace.settle / fullBuild)
                } else {
                    let clear = UIViewPropertyAnimator(duration: pace.settle, curve: .easeInOut) { veil.effect = nil }
                    clear.addCompletion { _ in end() }
                    clear.startAnimation()
                }
            }
        }
    }

    /// For layout changes that start from a button instead of the hinge.
    static func runInKeyWindow(change: @escaping @MainActor () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        run(in: scenes.flatMap(\.windows).first(where: \.isKeyWindow), pace: .button, change: change)
    }

    /// The first picture of a window costs several frames. Taking one ahead of time moves that cost to launch.
    static func warmUp(_ window: UIWindow?) {
        _ = window?.snapshotView(afterScreenUpdates: false)
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
