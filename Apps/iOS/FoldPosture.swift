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
/// follows at that moment, and `SplitRootView` slides the panes to their new places. The crease is the middle of the
/// physical screen, mapped into the window.
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
        guard let window else { return }
        // The window and the hosting view are black or system-coloured by default. While iOS resizes the window
        // during a fold, the panes are laid out a moment after it, and that default colour showed as a black bar
        // along the edge. The app's own background colour there makes the catch-up invisible.
        let fill = UIColor(RemoteTheme.background)
        window.backgroundColor = fill
        window.rootViewController?.view.backgroundColor = fill
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in PaneGlide.warmUp(self?.window) }
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

/// One of the inner screen's three panes.
enum PaneRole: Hashable, CaseIterable {
    case chat, sidebar, details
}

/// Moves the inner screen from one layout to another by gliding a picture of each pane from its old place to its
/// new one. Used for the pane buttons only.
///
/// Laying a chat out at a new width takes the main thread several frames. So the panes on screen during the move
/// are pictures:
/// - a picture of each pane in the old layout is put where the pane is, and starts to move and resize toward
///   where that pane will be. The move is handed to the system's renderer at once, so it runs at full speed while
///   the main thread works out the real new layout underneath;
/// - when the new layout is ready, a picture of each pane in it fades in over the old one, inside the moving frame;
/// - when the frames arrive, the pictures are removed and the real layout is exactly where they were.
/// A pane that is new slides in from the edge it belongs to, and one that goes slides out to it.
///
/// Not used for the hinge. On the real phone iOS resizes the app's window for a moment while the hinge moves, and
/// pictures pinned to fixed places then sit in the wrong place (dark blocks over half the screen). The hinge moves
/// the real panes instead, see `SplitRootView.slide`.
@MainActor
enum PaneGlide {
    private static let travel: TimeInterval = 0.62
    private static let contentFade: TimeInterval = 0.15
    /// The glide in flight, so a second change (a quick fold and unfold) ends the first cleanly.
    private static var cleanup: (() -> Void)?

    /// Call right before the layout changes (or while it has changed but is not on screen yet).
    /// - Parameters:
    ///   - old: where each pane is now, in window coordinates. Together they cover the window.
    ///   - new: where each pane will be.
    ///   - colors: each pane's background, shown where its picture does not reach during the move.
    static func run(from old: [PaneRole: CGRect], to new: [PaneRole: CGRect], colors: [PaneRole: UIColor]) {
        guard old != new, let window = keyWindow, let root = window.rootViewController?.view else { return }
        cleanup?()
        cleanup = nil
        if UIAccessibility.isReduceMotionEnabled {
            dissolve(window)
            return
        }

        let stage = UIView(frame: window.bounds)
        stage.isUserInteractionEnabled = false
        stage.backgroundColor = colors[.chat]
        struct Piece {
            let role: PaneRole
            let frame: UIView
            let before: UIView?
            let target: CGRect?
            let end: CGRect
        }
        var pieces: [Piece] = []
        // The chat first: the side panes slide over it.
        for role in PaneRole.allCases {
            let from = old[role], to = new[role]
            guard from != nil || to != nil else { continue }
            let start = from ?? offstage(role, like: to ?? .zero, in: window.bounds)
            let end = to ?? offstage(role, like: from ?? .zero, in: window.bounds)
            let frame = UIView(frame: start)
            frame.clipsToBounds = true
            frame.backgroundColor = colors[role]
            // A pane that is coming in has no picture yet. Shown empty, it read as a dark flash at the edge, so it
            // stays hidden until its picture is ready and then fades in as it slides.
            if from == nil { frame.alpha = 0 }
            var before: UIView?
            if let from, let picture = root.resizableSnapshotView(from: from, afterScreenUpdates: false, withCapInsets: .zero) {
                picture.frame.origin = .zero
                frame.addSubview(picture)
                before = picture
            }
            stage.addSubview(frame)
            pieces.append(Piece(role: role, frame: frame, before: before, target: to, end: end))
        }
        window.addSubview(stage)

        var arrived = false, filled = false, finished = false
        let end = {
            guard !finished else { return }
            finished = true
            stage.removeFromSuperview()
        }
        cleanup = end
        let finishIfReady = { if arrived && filled { end() } }

        UIView.animate(withDuration: travel, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            for piece in pieces { piece.frame.frame = piece.end }
        } completion: { _ in
            arrived = true
            finishIfReady()
        }
        // Hand the move to the renderer now. It then runs on its own while the main thread lays out.
        CATransaction.flush()

        // The main queue gets to this only once the new layout has been worked out.
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                guard !finished else { return }
                var after: [UIView] = []
                for piece in pieces {
                    guard let target = piece.target,
                          let picture = root.resizableSnapshotView(from: target, afterScreenUpdates: true, withCapInsets: .zero)
                    else { continue }
                    picture.frame.origin = .zero
                    // In a hidden frame the picture is shown at once, and the frame does the fading.
                    picture.alpha = piece.frame.alpha == 0 ? 1 : 0
                    piece.frame.addSubview(picture)
                    after.append(picture)
                }
                UIView.animate(withDuration: contentFade, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    for picture in after { picture.alpha = 1 }
                    for piece in pieces where piece.target != nil {
                        piece.before?.alpha = 0
                        piece.frame.alpha = 1
                    }
                } completion: { _ in
                    filled = true
                    finishIfReady()
                }
            }
        }
    }

    /// Where a pane waits before it slides in, or goes when it slides out: just past the edge it belongs to.
    static func offstage(_ role: PaneRole, like rect: CGRect, in bounds: CGRect) -> CGRect {
        let isColumn = rect.height >= bounds.height * 0.8
        switch role {
        case .sidebar where isColumn: return rect.offsetBy(dx: -rect.maxX, dy: 0)
        case .details where isColumn: return rect.offsetBy(dx: bounds.maxX - rect.minX, dy: 0)
        default: return rect.offsetBy(dx: 0, dy: bounds.maxY - rect.minY)
        }
    }

    /// Reduce Motion: no travel, a picture of the old layout fades into the new one.
    private static func dissolve(_ window: UIWindow) {
        guard let picture = window.snapshotView(afterScreenUpdates: false) else { return }
        picture.isUserInteractionEnabled = false
        window.addSubview(picture)
        var finished = false
        let end = {
            guard !finished else { return }
            finished = true
            picture.removeFromSuperview()
        }
        cleanup = end
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    picture.alpha = 0
                } completion: { _ in end() }
            }
        }
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
    }

    /// The first picture of a window costs several frames. Taking one ahead of time moves that cost to launch.
    static func warmUp(_ window: UIWindow?) {
        guard let root = window?.rootViewController?.view else { return }
        _ = root.resizableSnapshotView(from: CGRect(x: 0, y: 0, width: 40, height: 40), afterScreenUpdates: false, withCapInsets: .zero)
    }
}

private struct HingeReader: UIViewRepresentable {
    @Binding var layout: FoldLayout

    func makeUIView(context: Context) -> HingeView {
        let view = HingeView()
        let binding = $layout
        view.onChange = { layout in
            // No SwiftUI animation: the real layout lands in one step under the gliding pictures of the panes.
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
