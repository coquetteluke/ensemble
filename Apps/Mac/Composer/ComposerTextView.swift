import SwiftUI
import AppKit
import EnsembleKit

/// Multi-line message field. Return sends, Shift-Return inserts a new line, Shift-Tab cycles the permission mode.
/// Grows with its text up to `maxHeight`, then scrolls. Pasting or dropping files or a picture attaches them.
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
    /// Files and pictures pasted or dropped into the field.
    var onAttach: ([URL]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerNSTextView.scrollableTextView()
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
        (textView as? ComposerNSTextView)?.onAttach = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onAttach(urls)
        }
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

/// The message field's text view. A paste or a drop that carries files or a picture attaches them instead of typing
/// a path (a plain `NSTextView` types the path, and ignores a picture that has no file, such as a screenshot on the
/// clipboard).
final class ComposerNSTextView: NSTextView {
    var onAttach: (([URL]) -> Void)?

    override func paste(_ sender: Any?) {
        let urls = ComposerPasteboard.attachments(from: .general)
        if !urls.isEmpty, let onAttach {
            onAttach(urls)
        } else {
            super.paste(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        // Paste stays on with a picture on the clipboard (the text view only looks for text).
        if item.action == #selector(paste(_:)), ComposerPasteboard.hasAttachments(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        ComposerPasteboard.hasAttachments(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        ComposerPasteboard.hasAttachments(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = ComposerPasteboard.attachments(from: sender.draggingPasteboard)
        if !urls.isEmpty, let onAttach {
            onAttach(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

/// What on a pasteboard gets attached to the message instead of typed.
@MainActor
enum ComposerPasteboard {
    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// A picture with no text beside it: a screenshot, or a picture copied out of an app. Text with a picture (a
    /// copied part of a web page) is pasted as text.
    private static func hasLonePicture(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return !types.contains(.string) && (types.contains(.png) || types.contains(.tiff))
    }

    static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(pasteboard).isEmpty || hasLonePicture(pasteboard)
    }

    /// Files as they are; a picture that has no file is saved as a PNG in the picture cache first.
    static func attachments(from pasteboard: NSPasteboard,
                            cache: MessagePictureCache = MessagePictureCache(directory: MessagePictureCache.appDirectory)) -> [URL] {
        let files = fileURLs(pasteboard)
        if !files.isEmpty { return files }
        guard hasLonePicture(pasteboard) else { return [] }
        if let png = pasteboard.data(forType: .png), let url = cache.store(data: png) { return [url] }
        if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]), let url = cache.store(data: png) {
            return [url]
        }
        return []
    }
}

/// Keys the composer offers to its menus before handling them itself.
enum ComposerKey {
    case up, down, tab, escape, submit
}
