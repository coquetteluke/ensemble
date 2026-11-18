import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots for the composer work: the queue strip with two messages, the side question panel, and the microphone
/// while dictating (plus the message shown when access is off). Each in dark and light at the requested zoom.
/// Called from `SnapshotRenderer.run`.
@MainActor
enum ComposerQueueSnapshots {
    static func render(to directory: URL, zoom: CGFloat) {
        // A session that is working, with two messages sent meanwhile.
        var seed = PreviewData.seed()
        seed.activities[PreviewData.mainSessionID] = .working
        seed.permissions.removeAll { $0.sessionID == PreviewData.mainSessionID }
        let store = SessionStore(engine: PreviewEngine(seed: seed, delayScale: 0))
        store.seed(seed)
        store.select(PreviewData.mainSessionID)
        let window = WindowState()
        guard let session = store.session(PreviewData.mainSessionID) else { return }
        Task { @MainActor in
            await store.send("Also add a test for the empty state", to: session.id)
            await store.send("Then update the README screenshot\nand mention the new panel in the changelog", to: session.id)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // The side question and dictation shots use an idle session with nothing queued.
        var idleSeed = PreviewData.seed()
        idleSeed.activities[PreviewData.mainSessionID] = .idle
        let idleStore = SessionStore(engine: PreviewEngine(seed: idleSeed, delayScale: 0))
        idleStore.seed(idleSeed)
        guard let idleSession = idleStore.session(PreviewData.mainSessionID) else { return }

        let question = SideQuestion(sourceSessionID: session.id, question: "Which files has the agent changed so far, and why?",
                                    phase: .answered, forkSessionID: "ses_side_preview")
        let answer = """
        Three files so far:

        - **ContextPanelView.swift**: the new panel, with the Environment, Context and Outputs sections.
        - **ContextBar.swift**: the coloured usage bar, split by category.
        - **MainView.swift**: shows the panel on the right and remembers whether it is open.

        It is now running the tests before touching the connectors list.
        """
        let recording = DictationController(previewPhase: .recording, previewLevel: 0.65)
        let denied = DictationController(previewPhase: .unavailable(.microphoneDenied))

        var written: [String] = []
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            written += save("composer-queue-\(suffix)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                VStack(alignment: .leading, spacing: 0) {
                    ComposerView(store: store, session: session, window: window, snapshotDraft: "")
                    StatusLine(store: store, session: session, window: window)
                }
                .padding(24)
            }
            written += save("composer-side-question-\(suffix)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 330 * zoom)
                    ComposerView(store: idleStore, session: idleSession, window: window, snapshotDraft: "",
                                 snapshotSideQuestion: (question, answer))
                    StatusLine(store: idleStore, session: idleSession, window: window)
                }
                .padding(24)
            }
            written += save("composer-dictation-\(suffix)", to: directory, width: 820, zoom: zoom, scheme: scheme) {
                VStack(alignment: .leading, spacing: 18) {
                    ComposerView(store: idleStore, session: idleSession, window: window,
                                 snapshotDraft: "Move the usage button next to the context meter and make it", snapshotDictation: recording)
                    ComposerView(store: idleStore, session: idleSession, window: window, snapshotDraft: "", snapshotDictation: denied)
                }
                .padding(24)
            }
        }
        for path in written { print(path) }
        checkLiveComposer()
    }

    /// The real composer in a window that is never shown: Command-semicolon opens the side question panel, and
    /// `/btw` with Return asks in a hidden copy. Prints one line with the results.
    private static func checkLiveComposer() {
        var seed = PreviewData.seed()
        seed.activities[PreviewData.mainSessionID] = .idle
        let store = SessionStore(engine: PreviewEngine(seed: seed, delayScale: 0.05))
        store.seed(seed)
        let window = WindowState()
        guard let session = store.session(PreviewData.mainSessionID) else { return }
        let root = ComposerView(store: store, session: session, window: window)
            .padding(24)
            .frame(width: 820, height: 600, alignment: .bottom)
            .ensembleTheme()
            .environment(SnapshotRenderer.power)
        let hosting = NSHostingView(rootView: root)
        let offscreen = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled],
                                 backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = hosting
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        spin(0.5)

        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                   windowNumber: offscreen.windowNumber, context: nil, characters: ";",
                                   charactersIgnoringModifiers: ";", isARepeat: false, keyCode: 41)
        let handled = key.map { offscreen.performKeyEquivalent(with: $0) } ?? false
        spin(0.3)
        let opened = store.sideQuestions[session.id]?.phase == .composing
        Task { @MainActor in await store.closeSideQuestion(for: session.id) }
        spin(0.2)

        var asked = false
        var hidden = false
        if let textView = findTextView(in: hosting) {
            offscreen.makeFirstResponder(textView)
            textView.insertText("/btw what changed so far?", replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.2)
            textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            spin(1.5)
            asked = store.sideQuestions[session.id]?.question == "what changed so far?"
            if let forkID = store.sideQuestions[session.id]?.forkSessionID {
                hidden = store.isSideQuestionSession(forkID) && !store.sidebarOrder.contains { $0.id == forkID }
            }
        }
        let untouched = !session.items.contains { if case .user(_, let text, _) = $0 { text.contains("what changed so far") } else { false } }
        Task { @MainActor in await store.closeSideQuestion(for: session.id) }
        spin(0.3)
        offscreen.close()
        let dictation = DictationController.buildProblem().map { "unavailable (\($0.message))" } ?? "ready"
        print("Side question check: Command-semicolon handled \(handled), opens the panel \(opened), /btw asks \(asked), "
              + "copy hidden \(hidden), session untouched \(untouched). Dictation in this build: \(dictation)")
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable { return textView }
        for child in view.subviews { if let found = findTextView(in: child) { return found } }
        return nil
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let content = Canvas(width: width * zoom) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width * zoom, height: nil)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }

    private struct Canvas<Content: View>: View {
        let width: CGFloat
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.background)
        }
    }
}
