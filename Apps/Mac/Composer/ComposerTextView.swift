import SwiftUI
import AppKit

/// Multi-line message field. Return sends, Shift-Return inserts a new line, Shift-Tab cycles the permission mode.
/// Grows with its text up to `maxHeight`, then scrolls.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusToken: Int
    /// Point size; follows the window zoom.
    var fontSize: CGFloat = 14
    var textColor: NSColor
    var accentColor: NSColor
    var onSubmit: () -> Void
    var onCycleMode: () -> Void
    /// Arrow keys, Tab, Return and Esc go here first (the slash menu uses them). Return true to consume.
    var onKey: (ComposerKey) -> Bool = { _ in false }
    /// Voice dictation: its text goes in at the cursor (replacing the selection), updated as recognition improves.
    var dictation: DictationController?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = textColor
        textView.insertionPointColor = accentColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("Message")
        context.coordinator.textView = textView
        context.coordinator.connect(dictation)
        DispatchQueue.main.async {
            context.coordinator.updateHeight()
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.connect(dictation)
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            // The draft was changed elsewhere (sent, edited from the queue): dictated text has no place to go now.
            if context.coordinator.dictationRange != nil { dictation?.cancel() }
            textView.string = text
            context.coordinator.updateHeight()
        }
        textView.textColor = textColor
        textView.insertionPointColor = accentColor
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
            context.coordinator.updateHeight()
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        var lastFocusToken: Int
        /// Where the text dictated so far sits, while dictating.
        var dictationRange: NSRange?
        private var dictationNeedsSpace = false
        private var applyingDictation = false
        private weak var connectedDictation: DictationController?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateHeight()
            // Typing while dictating ends dictation; what was dictated stays.
            if !applyingDictation, dictationRange != nil { parent.dictation?.cancel() }
        }

        // MARK: Dictation

        func connect(_ dictation: DictationController?) {
            guard let dictation, dictation !== connectedDictation else { return }
            connectedDictation = dictation
            dictation.onBegin = { [weak self] in self?.beginDictation() }
            dictation.onText = { [weak self] text in self?.insertDictated(text) }
            dictation.onEnd = { [weak self] in self?.dictationRange = nil }
        }

        private func beginDictation() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            let range = textView.selectedRange()
            dictationRange = range
            let string = textView.string as NSString
            if range.location > 0, range.location <= string.length {
                let previous = string.substring(with: NSRange(location: range.location - 1, length: 1))
                dictationNeedsSpace = previous.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            } else {
                dictationNeedsSpace = false
            }
        }

        /// Replaces the text dictated so far with the newest transcription and keeps the cursor after it.
        private func insertDictated(_ transcription: String) {
            guard let textView, let range = dictationRange,
                  NSMaxRange(range) <= (textView.string as NSString).length else { return }
            let piece = (dictationNeedsSpace && !transcription.isEmpty ? " " : "") + transcription
            guard textView.shouldChangeText(in: range, replacementString: piece) else { return }
            applyingDictation = true
            textView.replaceCharacters(in: range, with: piece)
            textView.didChangeText()
            applyingDictation = false
            let inserted = NSRange(location: range.location, length: (piece as NSString).length)
            dictationRange = inserted
            textView.setSelectedRange(NSRange(location: NSMaxRange(inserted), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if !parent.onKey(.submit) {
                    parent.onSubmit()
                }
                return true
            }
            let keys: [Selector: ComposerKey] = [
                #selector(NSResponder.moveUp(_:)): .up,
                #selector(NSResponder.moveDown(_:)): .down,
                #selector(NSResponder.insertTab(_:)): .tab,
                #selector(NSResponder.cancelOperation(_:)): .escape,
            ]
            if let key = keys[selector], parent.onKey(key) { return true }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                parent.onCycleMode()
                return true
            }
            return false
        }

        func updateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let lineHeight = layout.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: parent.fontSize))
            let height = ceil(max(used, lineHeight) + textView.textContainerInset.height * 2)
            if abs(parent.height - height) > 0.5 {
                parent.height = height
            }
        }
    }
}

/// Keys the composer offers to its menus before handling them itself.
enum ComposerKey {
    case up, down, tab, escape, submit
}
