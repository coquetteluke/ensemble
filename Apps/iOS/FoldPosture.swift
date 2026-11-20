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

/// Whether the hinge is partly open, from a `UIHingeInteraction` on an invisible view.
private struct HingeReader: UIViewRepresentable {
    @Binding var partlyOpen: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let binding = $partlyOpen
            let interaction = UIHingeInteraction { _, update in
                let partly = update.hinge?.status == .partiallyOpen
                if binding.wrappedValue != partly {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { binding.wrappedValue = partly }
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
