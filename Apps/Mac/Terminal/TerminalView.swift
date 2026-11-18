import AppKit
import SwiftUI
import EnsembleKit

/// What the terminal view asks of the pane.
struct TerminalViewActions {
    var newTab: () -> Void = {}
    var closeTab: () -> Void = {}
    /// Nil when the tab's owner is not a session (a room), so there is no agent to send to.
    var sendSelection: (() -> Void)?
}

/// A terminal tab in SwiftUI: the AppKit view that draws the screen and takes keys, inside a scroll view for the
/// scrollback.
struct TerminalSurface: NSViewRepresentable {
    let tab: TerminalTab
    let palette: TerminalPalette
    let fontSize: CGFloat
    /// Bumped to put keyboard focus in the terminal.
    let focusToken: Int
    let actions: TerminalViewActions

    func makeNSView(context: Context) -> TerminalScrollView {
        TerminalScrollView()
    }

    func updateNSView(_ view: TerminalScrollView, context: Context) {
        view.canvas.actions = actions
        view.configure(tab: tab, palette: palette, fontSize: fontSize)
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            view.canvas.focusWhenReady()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var focusToken = Int.min
    }
}

/// Scroll view around the terminal: its size sets the terminal's columns and rows.
final class TerminalScrollView: NSScrollView {
    let canvas = TerminalCanvas()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        drawsBackground = true
        verticalScrollElasticity = .allowed
        documentView = canvas
        canvas.scrollView = self
        contentView.postsBoundsChangedNotifications = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(tab: TerminalTab, palette: TerminalPalette, fontSize: CGFloat) {
        backgroundColor = NSColor(cgColor: palette.background) ?? .textBackgroundColor
        canvas.configure(tab: tab, palette: palette, fontSize: fontSize)
    }

    override func tile() {
        super.tile()
        canvas.viewportChanged()
    }
}

/// Draws a tab's screen and scrollback, and turns keys, the mouse, Copy and Paste into terminal input.
final class TerminalCanvas: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    weak var scrollView: TerminalScrollView?
    var actions = TerminalViewActions()
    private(set) weak var tab: TerminalTab?
    private var palette = TerminalPalette(theme: .dark)
    private var metrics = TerminalMetrics(size: 12)
    private var markedText = ""
    private var wantsFocus = false
    /// Where the scrollback started when last drawn, to keep a scrolled-back view still while old lines drop off.
    private var lastFirstStableRow = 0
    private var lastAlternate = false

    // Mouse
    private enum SelectionUnit { case character, word, line }
    private var selectionAnchor: TerminalPosition?
    private var selectionUnit = SelectionUnit.character
    private var dragged = false
    private var reportingMouse = false
    private var scrollRemainder: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Setup

    func configure(tab newTab: TerminalTab, palette newPalette: TerminalPalette, fontSize: CGFloat) {
        var changed = false
        if tab !== newTab {
            tab?.onScreenChange = nil
            tab = newTab
            newTab.onScreenChange = { [weak self] in self?.screenChanged() }
            markedText = ""
            lastFirstStableRow = newTab.emulator.firstStableRow
            lastAlternate = newTab.emulator.isAlternateScreen
            changed = true
        }
        if palette != newPalette {
            palette = newPalette
            changed = true
        }
        if metrics.size != fontSize {
            metrics = TerminalMetrics(size: fontSize)
            changed = true
        }
        if changed {
            viewportChanged()
            scrollToBottom()
            needsDisplay = true
        }
    }

    func focusWhenReady() {
        wantsFocus = true
        DispatchQueue.main.async { [weak self] in self?.takeFocusIfWanted() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocusIfWanted()
    }

    private func takeFocusIfWanted() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    private var isFocused: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    // MARK: Size and scrolling

    /// The visible area changed size: fits the terminal to it.
    func viewportChanged() {
        guard let scrollView, let tab else { return }
        let size = scrollView.contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let grid = metrics.grid(for: size)
        let atBottom = isScrolledToBottom
        tab.resize(columns: grid.columns, rows: grid.rows)
        updateDocumentSize()
        if atBottom { scrollToBottom() }
    }

    private var documentHeight: CGFloat {
        guard let tab else { return 0 }
        return metrics.padding.height * 2 + CGFloat(tab.emulator.documentLineCount) * metrics.lineHeight
    }

    private func updateDocumentSize() {
        guard let scrollView else { return }
        let width = scrollView.contentView.bounds.width
        let height = max(documentHeight, scrollView.contentView.bounds.height)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    private var isScrolledToBottom: Bool {
        guard let scrollView else { return true }
        let visible = scrollView.contentView.bounds
        return visible.maxY >= frame.height - metrics.lineHeight / 2
    }

    func scrollToBottom() {
        guard let scrollView else { return }
        let y = max(0, frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollBy(lines: Int) {
        guard let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let maxY = max(0, frame.height - visible.height)
        let y = min(max(visible.minY + CGFloat(lines) * metrics.lineHeight, 0), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// New output (or a resize): redraws, following the output when the view was at the bottom.
    private func screenChanged() {
        guard let tab else { return }
        let emulator = tab.emulator
        let atBottom = isScrolledToBottom
        let dropped = emulator.isAlternateScreen == lastAlternate ? emulator.firstStableRow - lastFirstStableRow : 0
        let switchedScreen = emulator.isAlternateScreen != lastAlternate
        lastFirstStableRow = emulator.firstStableRow
        lastAlternate = emulator.isAlternateScreen
        updateDocumentSize()
        if atBottom || switchedScreen {
            scrollToBottom()
        } else if dropped > 0 {
            // Keep reading the same lines while the oldest drop off the top.
            scrollBy(lines: -dropped)
        }
        setNeedsDisplay(visibleRect)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(palette.background)
        context.fill(dirtyRect)
        guard let tab else { return }
        let emulator = tab.emulator
        let count = emulator.documentLineCount
        let first = max(0, Int(floor((dirtyRect.minY - metrics.padding.height) / metrics.lineHeight)))
        let last = min(count - 1, Int(ceil((dirtyRect.maxY - metrics.padding.height) / metrics.lineHeight)))
        guard first <= last else { return }
        // No cursor once the shell has ended.
        let cursor: TerminalCursorDrawing? = tab.isRunning && (emulator.cursorVisible || !markedText.isEmpty)
            ? TerminalCursorDrawing(documentRow: emulator.cursorDocumentRow, column: emulator.cursorColumn, style: emulator.cursorStyle,
                                    focused: isFocused, markedText: markedText)
            : nil
        TerminalRenderer.drawLines(context, emulator: emulator, range: first...last,
                                   lineTop: { self.metrics.padding.height + CGFloat($0) * self.metrics.lineHeight },
                                   metrics: metrics, palette: palette, selection: tab.selection, cursor: cursor)
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers.contains(.command) {
            if modifiers.subtracting(.capsLock) == .command {
                switch key {
                case "t":
                    actions.newTab()
                    return true
                case "w":
                    actions.closeTab()
                    return true
                default:
                    break
                }
            }
            return super.performKeyEquivalent(with: event)
        }
        // Control-backquote shows and hides the terminal (the menu command).
        if modifiers.contains(.control), key == "`" { return false }
        // Every other key belongs to the program, even ones the menus use elsewhere (Esc, Control-O).
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let tab else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if hasMarkedText() {
            _ = inputContext?.handleEvent(event)
            return
        }
        if let bytes = specialKeyBytes(event, emulator: tab.emulator) {
            if !bytes.isEmpty { sendFromKeyboard(bytes) }
            return
        }
        if modifiers.contains(.control), let character = event.charactersIgnoringModifiers?.first,
           let byte = TerminalInput.controlByte(for: character) {
            sendFromKeyboard(modifiers.contains(.option) ? [0x1B, byte] : [byte])
            return
        }
        if inputContext?.handleEvent(event) != true, let characters = event.characters, !characters.isEmpty {
            sendFromKeyboard(Array(characters.utf8))
        }
    }

    private func sendFromKeyboard(_ bytes: [UInt8]) {
        guard let tab else { return }
        if !isScrolledToBottom { scrollToBottom() }
        tab.send(bytes)
    }

    /// Bytes for keys that are not text; an empty array for keys handled here (Page Up and Down scroll the
    /// scrollback at the prompt); nil for text keys.
    private func specialKeyBytes(_ event: NSEvent, emulator: TerminalEmulator) -> [UInt8]? {
        let flags = event.modifierFlags
        var modifiers = TerminalKeyModifiers()
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let application = emulator.applicationCursorKeys
        func key(_ key: TerminalKey, _ keyModifiers: TerminalKeyModifiers? = nil) -> [UInt8] {
            TerminalInput.bytes(for: key, modifiers: keyModifiers ?? modifiers, applicationCursor: application)
        }
        if event.keyCode == 53 { return [0x1B] }
        guard let special = event.specialKey else { return nil }
        switch special {
        case .upArrow: return key(.up)
        case .downArrow: return key(.down)
        case .leftArrow: return key(.left)
        case .rightArrow: return key(.right)
        case .home: return key(.home)
        case .end: return key(.end)
        case .pageUp, .pageDown:
            // At the prompt Page Up and Page Down read back through the scrollback; full-screen programs get them.
            let toProgram = emulator.isAlternateScreen != modifiers.contains(.shift)
            if toProgram { return key(special == .pageUp ? .pageUp : .pageDown, modifiers.subtracting(.shift)) }
            let page = max(1, (scrollView?.contentView.bounds.height ?? 0) / metrics.lineHeight - 1)
            scrollBy(lines: special == .pageUp ? -Int(page) : Int(page))
            return []
        case .deleteForward: return key(.forwardDelete)
        case .delete, .backspace: return key(.backspace)
        case .tab: return key(.tab)
        case .backTab: return key(.tab, modifiers.union(.shift))
        case .carriageReturn, .enter, .newline: return key(.enter)
        case .f1: return key(.function(1))
        case .f2: return key(.function(2))
        case .f3: return key(.function(3))
        case .f4: return key(.function(4))
        case .f5: return key(.function(5))
        case .f6: return key(.function(6))
        case .f7: return key(.function(7))
        case .f8: return key(.function(8))
        case .f9: return key(.function(9))
        case .f10: return key(.function(10))
        case .f11: return key(.function(11))
        case .f12: return key(.function(12))
        default: return nil
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        if !text.isEmpty { sendFromKeyboard(Array(text.utf8)) }
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        // Keys the input system turned into commands; the special keys above already cover the usual ones.
        switch selector {
        case #selector(insertNewline(_:)): sendFromKeyboard([0x0D])
        case #selector(insertTab(_:)): sendFromKeyboard([0x09])
        case #selector(deleteBackward(_:)): sendFromKeyboard([0x7F])
        case #selector(cancelOperation(_:)): sendFromKeyboard([0x1B])
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let tab, let window else { return .zero }
        let emulator = tab.emulator
        let rect = NSRect(x: metrics.padding.width + CGFloat(emulator.cursorColumn) * metrics.cellWidth,
                          y: metrics.padding.height + CGFloat(emulator.cursorDocumentRow) * metrics.lineHeight,
                          width: metrics.cellWidth, height: metrics.lineHeight)
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Copy, paste, select all

    @objc func copy(_ sender: Any?) {
        guard let text = tab?.selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if !isScrolledToBottom { scrollToBottom() }
        tab?.paste(text)
    }

    override func selectAll(_ sender: Any?) {
        guard let tab else { return }
        let emulator = tab.emulator
        let first = TerminalPosition(row: emulator.firstStableRow, column: 0)
        let last = TerminalPosition(row: emulator.firstStableRow + emulator.documentLineCount - 1, column: emulator.columns - 1)
        tab.select(first...last)
    }

    @objc func sendSelectionToAgent(_ sender: Any?) {
        actions.sendSelection?()
    }

    @objc func clearScrollbackCommand(_ sender: Any?) {
        tab?.clearScrollback()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return tab?.hasSelection == true
        case #selector(sendSelectionToAgent(_:)): return tab?.hasSelection == true && actions.sendSelection != nil
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil && tab?.isRunning == true
        default: return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if mouseReportingWanted(event) { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        if actions.sendSelection != nil {
            menu.addItem(withTitle: "Send Selection to Agent", action: #selector(sendSelectionToAgent(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Scrollback", action: #selector(clearScrollbackCommand(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Mouse

    /// Cell under a point, in stable rows, clamped to the text.
    private func position(at point: NSPoint) -> TerminalPosition? {
        guard let tab else { return nil }
        let emulator = tab.emulator
        let index = min(max(Int(floor((point.y - metrics.padding.height) / metrics.lineHeight)), 0), emulator.documentLineCount - 1)
        let column = min(max(Int(floor((point.x - metrics.padding.width) / metrics.cellWidth)), 0), emulator.columns - 1)
        return TerminalPosition(row: emulator.firstStableRow + index, column: column)
    }

    /// The program asked for mouse events and Option is not held (Option-drag always selects).
    private func mouseReportingWanted(_ event: NSEvent) -> Bool {
        guard let tab else { return false }
        return tab.emulator.mouseTracking != .off && !event.modifierFlags.contains(.option)
    }

    private func reportMouse(_ event: NSEvent, button: TerminalInput.MouseButton, pressed: Bool, motion: Bool = false) {
        guard let tab, let position = position(at: convert(event.locationInWindow, from: nil)) else { return }
        let row = position.row - tab.emulator.firstStableRow - (tab.emulator.documentLineCount - tab.emulator.rows)
        guard row >= 0 else { return }
        var modifiers = TerminalKeyModifiers()
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if let bytes = TerminalInput.mouseReport(button, pressed: pressed, column: position.column, row: row, motion: motion,
                                                 modifiers: modifiers, sgr: tab.emulator.mouseSGR) {
            tab.send(bytes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let tab else { return }
        if mouseReportingWanted(event) {
            reportingMouse = true
            reportMouse(event, button: .left, pressed: true)
            return
        }
        reportingMouse = false
        guard let position = position(at: convert(event.locationInWindow, from: nil)) else { return }
        dragged = false
        if event.modifierFlags.contains(.shift), let current = tab.selection {
            // Shift-click extends the selection.
            selectionAnchor = position < current.lowerBound ? current.upperBound : current.lowerBound
            selectionUnit = .character
            extendSelection(to: position)
            return
        }
        selectionAnchor = position
        switch event.clickCount {
        case 2:
            selectionUnit = .word
            extendSelection(to: position)
        case 3...:
            selectionUnit = .line
            extendSelection(to: position)
        default:
            selectionUnit = .character
            tab.clearSelection()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if reportingMouse {
            if let tab, tab.emulator.mouseTracking != .clicks { reportMouse(event, button: .left, pressed: true, motion: true) }
            return
        }
        autoscroll(with: event)
        guard let position = position(at: convert(event.locationInWindow, from: nil)) else { return }
        dragged = true
        extendSelection(to: position)
    }

    override func mouseUp(with event: NSEvent) {
        if reportingMouse {
            reportingMouse = false
            reportMouse(event, button: .release, pressed: false)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if mouseReportingWanted(event) {
            reportMouse(event, button: .right, pressed: true)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseReportingWanted(event) {
            reportMouse(event, button: .release, pressed: false)
            return
        }
        super.rightMouseUp(with: event)
    }

    private func extendSelection(to position: TerminalPosition) {
        guard let tab, let anchor = selectionAnchor else { return }
        let emulator = tab.emulator
        var start = min(anchor, position)
        var end = max(anchor, position)
        switch selectionUnit {
        case .character:
            break
        case .word:
            start = emulator.wordRange(at: start).start
            end = emulator.wordRange(at: end).end
        case .line:
            start.column = 0
            end.column = emulator.columns - 1
        }
        tab.select(start...end)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let tab, tab.emulator.isAlternateScreen else {
            super.scrollWheel(with: event)
            return
        }
        // Full-screen programs: mouse wheel reports when they asked for them, else arrow keys (as Terminal does).
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / metrics.lineHeight : event.scrollingDeltaY
        scrollRemainder += delta
        let steps = Int(scrollRemainder.rounded(.towardZero))
        guard steps != 0 else { return }
        scrollRemainder -= CGFloat(steps)
        for _ in 0..<min(abs(steps), 20) {
            if mouseReportingWanted(event) {
                reportMouse(event, button: steps > 0 ? .scrollUp : .scrollDown, pressed: true)
            } else {
                tab.send(TerminalInput.bytes(for: steps > 0 ? .up : .down, applicationCursor: tab.emulator.applicationCursorKeys))
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .iBeam)
    }
}
