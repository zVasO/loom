import AppKit
import LoomChromium
import SwiftUI

// The live picture of the agent's Chromium tab in the side panel
// (ADR-0016), and the person's way into it (panel design §2): mouse, wheel,
// keyboard with the input method, the Edit menu and the clipboard, all
// forwarded through the surface's UserInputPump as DevTools input — no
// NSEvent ever reaches Chromium. The view is flipped so a view point reads
// like a CSS point (ScreencastGeometry).
//
// Focus: the view takes the keyboard ONLY when the person presses a mouse
// button in it (a page shown) — never on appear, a frame, a resize or an
// agent action — so the terminal never loses its keys unexpectedly. ⌘ chords
// stay Loom's but for an allow-list (PanelShortcut): ⌘C ⌘X ⌘V ⌘A ⌘Z ⌘⇧Z go
// to the page, ⌘L ⌘R ⌘[ ⌘] to the panel; ⌃Tab and ⌃⇧Tab give the keyboard
// back.

/// A layer whose contents are the latest decoded frame, aspect-fit. It asks
/// for frames only while it is on screen — in a window that is visible, not
/// hidden, with a size and a tab — and tells the surface the page area it
/// has, for Fit and for the frames' size.
@MainActor
public final class ChromiumPageView: NSView, NSTextInputClient {

    /// The tab whose frames are shown; nil: none (no tab, or its page is
    /// released or crashed).
    var source: ChromiumScreencastSource? {
        didSet {
            guard source != oldValue else { return }
            if let oldValue, source?.connection !== oldValue.connection {
                // The browser went (relaunch, crash) or the tab has no page:
                // that session's frames will never be asked for again.
                stream.forget(oldValue.session)
            }
            if source == nil {
                clearPicture()
                // No page left to type into: the window takes the keys back
                // (the terminal reclaims an idle window's), none swallowed.
                if let window, window.firstResponder === self {
                    window.makeFirstResponder(nil)   // resignFirstResponder lets go of the page's keys
                }
            }
            refresh()
        }
    }

    /// Where the person's input goes (the surface's pump); nil: watch-only.
    var input: UserInputPump? {
        didSet {
            guard input !== oldValue else { return }
            if let oldValue {
                if oldValue.viewer === self {
                    oldValue.viewer = nil
                }
                // Another session's browser under the same view: the keyboard
                // was given to the old one's page, not this one's. Its marked
                // text is committed there, and the window takes the keys back
                // (the terminal reclaims an idle window's).
                if let window, window.firstResponder === self {
                    oldValue.resign()
                    window.makeFirstResponder(nil)
                }
            }
            input?.viewer = self
        }
    }

    /// The page area in points, the backing scale, and whether the view is
    /// on screen: the surface sizes Fit's emulation from it.
    var onPageArea: (@MainActor (_ size: CGSize, _ backingScale: CGFloat, _ onScreen: Bool) -> Void)?

    /// The frame on screen: what a point of the view maps through, never the
    /// emulation in force now.
    private(set) var picture: ScreencastPicture?

    private lazy var stream = ScreencastStream(onPicture: { [weak self] picture in
        self?.show(picture)
    })
    private var observedWindow: NSWindow?
    /// What the surface last heard.
    private var reported: (size: CGSize, scale: CGFloat, onScreen: Bool)?
    private var settle: Task<Void, Never>?

    // The keyboard.
    /// What AppKit calls back during one keyDown's interpretKeyEvents; nil
    /// outside one (then it goes to the pump at once).
    private var collected: [KeyAction]?
    /// The input method's marked text and its selection, as AppKit set them.
    private var marked: (text: String, selection: NSRange)?
    /// The focused field's caret, CSS px, fetched once per composition start.
    private var caret: CGRect?
    private var caretRequest: Task<Void, Never>?
    /// Where the last press landed (view points): the input method's anchor
    /// until the caret is known.
    private var lastPress: CGPoint?

    // The pointer.
    /// The page's cursor where the pointer last was, as sampled.
    private var cursorKind: CursorKind = .arrow
    private var pointerInside = false

    /// A size settles before the surface hears of it and the stream follows:
    /// a divider being dragged would otherwise re-emulate the page and
    /// restart the frames at every step. Meanwhile the frame on screen
    /// simply scales (resizeAspect).
    static let resizeDebounce: UInt64 = 150_000_000

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Agent browser page")
        setAccessibilityHelp("A live picture of claude's browser. Click into it to use the page.")
        // Its own rectangle, kept up to date by AppKit (.inVisibleRect).
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("ChromiumPageView is built in code")
    }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    /// Only with a page to type into. AppKit makes a view that accepts first
    /// responder the first responder on any left click in it, before
    /// mouseDown: a click on an empty panel must leave the terminal its keys.
    public override var acceptsFirstResponder: Bool { input != nil && source != nil }
    /// Tab reaches the page (keyboard-only use), ⌃Tab leaves it.
    public override var canBecomeKeyView: Bool { acceptsFirstResponder }

    /// Drawn at the display's pace however many frames arrived since. The
    /// layer is transparent: the letterbox shows the panel's background.
    public override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = .resizeAspect
        layer.contents = picture?.image
    }

    /// Where the frame on screen lands, and how points map to the page.
    var geometry: ScreencastGeometry? {
        guard let picture else { return nil }
        return ScreencastGeometry(viewSize: bounds.size, backingScale: backingScale,
                                  metadata: picture.metadata, image: picture.pixelSize)
    }

    // MARK: - On screen or not

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let observedWindow, observedWindow !== newWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: observedWindow)
            self.observedWindow = nil
        }
        // Taken out of its window with the keyboard: what was marked is
        // committed and the pointer leaves, as on a resign.
        if newWindow !== window, let window, window.firstResponder === self {
            letGoOfKeyboard()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, observedWindow !== window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window)
            observedWindow = window
        }
        refresh()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        refresh()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refresh(resizing: true)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        refresh()
    }

    /// Minimised, behind another window, on another Space, the app hidden:
    /// nobody sees it, Chromium sends nothing.
    var isOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, bounds.width >= 1, bounds.height >= 1 else { return false }
        return window.occlusionState.contains(.visible)
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Starts, restarts or stops the frames for what the view is now, and
    /// tells the surface. Off screen: at once — the surface counts the panels
    /// shown. A new size while shown: once it settles.
    private func refresh(resizing: Bool = false) {
        guard isOnScreen else {
            cancelSettle()
            stream.stop()
            if let reported, reported.onScreen {
                send(size: reported.size, scale: reported.scale, onScreen: false)
            }
            return
        }
        if resizing, let reported, reported.onScreen {
            if reported.size == bounds.size, reported.scale == backingScale {
                cancelSettle()
            } else {
                scheduleSettle()
            }
            return
        }
        cancelSettle()
        apply()
    }

    /// The size and visibility as they are now, to the surface and the stream.
    private func apply() {
        let size = bounds.size
        let scale = backingScale
        let known = reported.map { $0.onScreen && $0.size == size && $0.scale == scale } ?? false
        if !known {
            send(size: size, scale: scale, onScreen: true)
        }
        guard let source else {
            stream.stop()
            return
        }
        let pixels = ScreencastGeometry.screencastMax(viewSize: size, backingScale: scale)
        let cachedOrSame = stream.show(source, maxWidth: pixels.width, maxHeight: pixels.height)
        // Another tab's picture goes now unless this one's is on its way.
        if !cachedOrSame, picture?.session != source.session {
            clearPicture()
        }
    }

    private func scheduleSettle() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ChromiumPageView.resizeDebounce)
            guard !Task.isCancelled, let self else { return }
            self.settle = nil
            self.refresh()
        }
    }

    private func cancelSettle() {
        settle?.cancel()
        settle = nil
    }

    private func send(size: CGSize, scale: CGFloat, onScreen: Bool) {
        reported = (size, scale, onScreen)
        onPageArea?(size, scale, onScreen)
    }

    // MARK: - Frames

    private func show(_ next: ScreencastPicture) {
        // A late frame of the tab just left: not this tab's picture.
        guard next.session == source?.session else { return }
        picture = next
        needsDisplay = true
    }

    private func clearPicture() {
        guard picture != nil else { return }
        picture = nil
        needsDisplay = true
    }

    /// The view leaves the panel: no more frames, and the surface knows. With
    /// the keyboard, the window takes it back (the terminal reclaims an idle
    /// window's), whatever SwiftUI does with the view next.
    func detach() {
        if let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        stream.stop()
        cancelSettle()
        caretRequest?.cancel()
        caretRequest = nil
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: observedWindow)
            self.observedWindow = nil
        }
        if let reported, reported.onScreen {
            send(size: reported.size, scale: reported.scale, onScreen: false)
        }
        onPageArea = nil
        if let input, input.viewer === self {
            input.viewer = nil
        }
    }

    // MARK: - Focus

    /// First responder in the key window: the page is the person's, and the
    /// bare pointer moves reach it.
    private var isArmed: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            input?.setFirstResponder(window?.isKeyWindow ?? false)
            noteFocusRingMaskChanged()
        }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            letGoOfKeyboard()
            noteFocusRingMaskChanged()
        }
        return resigned
    }

    /// The marked text is committed (as the page itself does on a blur),
    /// the input method forgets it, the pointer leaves.
    private func letGoOfKeyboard() {
        input?.resign()
        caretRequest?.cancel()
        caretRequest = nil
        caret = nil
        if marked != nil {
            marked = nil
            inputContext?.discardMarkedText()
        }
    }

    /// The system's ring around the page while the keys go to it.
    public override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 2, dy: 2)
    }

    public override func drawFocusRingMask() {
        NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)).fill()
    }

    // MARK: - Mouse

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    public override func mouseDown(with event: NSEvent) {
        pressButton(event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        pressButton(event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        pressButton(event)
    }

    /// The only place the view takes the keyboard: a press, on a page.
    private func pressButton(_ event: NSEvent) {
        guard let input, source != nil else { return }
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        let point = location(of: event)
        lastPress = point
        guard let geometry else { return }
        input.mouseDown(event.panelMouseEvent(at: point), geometry: geometry)
    }

    public override func mouseDragged(with event: NSEvent) {
        dragButton(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        dragButton(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        dragButton(event)
    }

    private func dragButton(_ event: NSEvent) {
        guard let input, let geometry else { return }
        input.mouseDragged(event.panelMouseEvent(at: location(of: event)), geometry: geometry)
    }

    public override func mouseUp(with event: NSEvent) {
        releaseButton(event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        releaseButton(event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        releaseButton(event)
    }

    /// Wherever it ends, even past the picture: the page never keeps a
    /// button down (the pump drops a release whose press it never sent).
    private func releaseButton(_ event: NSEvent) {
        guard let input, let geometry else { return }
        input.mouseUp(event.panelMouseEvent(at: location(of: event)), geometry: geometry)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let input, let geometry else { return }
        input.setFirstResponder(isArmed)
        input.mouseMoved(event.panelMouseEvent(at: location(of: event)), geometry: geometry)
    }

    public override func mouseEntered(with event: NSEvent) {
        pointerInside = true
    }

    public override func mouseExited(with event: NSEvent) {
        pointerInside = false
        input?.mouseExited()
    }

    public override func cursorUpdate(with event: NSEvent) {
        cursorKind.cursor.set()
    }

    /// No arming: looking at the page is enough to scroll it.
    public override func scrollWheel(with event: NSEvent) {
        guard let input, let geometry else { return }
        input.scrollWheel(event.panelScrollEvent(at: location(of: event)), geometry: geometry)
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let input else { return }
        let press = event.panelKeyPress
        if case .leave(let forward) = PanelShortcut.classify(press) {
            leave(forward: forward)
            return
        }
        guard input.acceptsKeys else {
            // Not the person's page now: dropped, with the notice why. The
            // input method never sees it, so nothing composes meanwhile.
            input.refuseKeyDown(press)
            return
        }
        collected = []
        interpretKeyEvents([event])
        let actions = collected ?? []
        collected = nil
        input.keyDown(press, actions: actions)
    }

    public override func keyUp(with event: NSEvent) {
        input?.keyUp(event.panelKeyPress)
    }

    public override func flagsChanged(with event: NSEvent) {
        input?.flagsChanged(event.panelKeyPress)
    }

    /// Offered every key equivalent of the window: only the allow-list, and
    /// only while the keys are the page's. Everything else stays Loom's menus'
    /// and the system's.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let input, let window, window.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch PanelShortcut.classify(event.panelKeyPress) {
        case .page(let command):
            input.editCommand(command)
            return true
        case .panel(let action):
            input.panelAction(action)
            return true
        case .leave(let forward):
            leave(forward: forward)
            return true
        case .notOurs:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// ⌃Tab, ⌃⇧Tab: the keyboard-only way out of the page — to the next
    /// key view, or, with none, to the window (the terminal reclaims it).
    private func leave(forward: Bool) {
        guard let window else { return }
        if forward {
            window.selectNextKeyView(self)
        } else {
            window.selectPreviousKeyView(self)
        }
        if window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    // MARK: - The Edit menu

    @objc func copy(_ sender: Any?) {
        input?.editCommand(.copy)
    }

    @objc func cut(_ sender: Any?) {
        input?.editCommand(.cut)
    }

    @objc func paste(_ sender: Any?) {
        input?.editCommand(.paste)
    }

    public override func selectAll(_ sender: Any?) {
        input?.editCommand(.selectAll)
    }

    @objc func undo(_ sender: Any?) {
        input?.editCommand(.undo)
    }

    @objc func redo(_ sender: Any?) {
        input?.editCommand(.redo)
    }

    /// The Edit menu's actions this view answers.
    static let editActions: [Selector: PanelEditCommand] = [
        #selector(ChromiumPageView.copy(_:)): .copy,
        #selector(ChromiumPageView.cut(_:)): .cut,
        #selector(ChromiumPageView.paste(_:)): .paste,
        #selector(ChromiumPageView.selectAll(_:)): .selectAll,
        #selector(ChromiumPageView.undo(_:)): .undo,
        #selector(ChromiumPageView.redo(_:)): .redo,
    ]

    // MARK: - NSTextInputClient

    /// Goes with the keyDown being interpreted, or to the page at once.
    private func record(_ action: KeyAction) {
        if collected != nil {
            collected?.append(action)
        } else {
            input?.text([action])
        }
    }

    private static func plainText(_ string: Any) -> String {
        if let attributed = string as? NSAttributedString { return attributed.string }
        if let text = string as? String { return text }
        return ""
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        marked = nil
        record(.insertText(Self.plainText(string)))
    }

    public override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Collected for the key's commands; outside a keyDown a command has no
    /// key to go with, and nothing else here acts on it (no beep either).
    public override func doCommand(by selector: Selector) {
        guard collected != nil else { return }
        collected?.append(.doCommand(NSStringFromSelector(selector)))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainText(string)
        let starting = marked == nil
        if text.isEmpty {
            marked = nil
        } else {
            marked = (text: text, selection: selectedRange)
        }
        if starting, marked != nil {
            fetchCaret()
        }
        record(.setMarkedText(text, selectedLocation: selectedRange.location, selectedLength: selectedRange.length))
    }

    public func unmarkText() {
        guard marked != nil else { return }
        marked = nil
        record(.unmarkText)
    }

    public func selectedRange() -> NSRange {
        marked?.selection ?? NSRange(location: 0, length: 0)
    }

    public func markedRange() -> NSRange {
        guard let marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: marked.text.utf16.count)
    }

    public func hasMarkedText() -> Bool {
        marked != nil
    }

    /// The page's text is not readable from here: reconversion degrades.
    public func attributedSubstring(forProposedRange range: NSRange,
                                    actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Where the input method's window goes: the page's caret, fetched when
    /// the composition started; until it comes, where the person clicked.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let rect: CGRect
        if let caret, let geometry {
            rect = geometry.viewRect(fromCSS: caret)
        } else {
            let anchor = lastPress ?? CGPoint(x: bounds.minX, y: bounds.maxY)
            rect = CGRect(origin: anchor, size: .zero)
        }
        let inWindow = convert(rect, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    private func fetchCaret() {
        caret = nil
        caretRequest?.cancel()
        guard let input else { return }
        caretRequest = Task { @MainActor [weak self] in
            let rect = await input.caretRect()
            guard !Task.isCancelled, let self else { return }
            self.caretRequest = nil
            self.caret = rect
            if rect != nil {
                self.inputContext?.invalidateCharacterCoordinates()
            }
        }
    }
}

// MARK: - The Edit menu's state

extension ChromiumPageView: NSMenuItemValidation {
    /// Copy, Paste… are on while the page would take them.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let command = Self.editActions[action] else { return true }
        return input?.canPerform(command) ?? false
    }
}

// MARK: - What the pump asks of the view

extension ChromiumPageView: UserInputPumpViewer {

    func pumpCursorChanged(_ kind: CursorKind) {
        cursorKind = kind
        if pointerInside, window?.isKeyWindow == true {
            kind.cursor.set()
        }
    }

    func pumpCompositionEnded() {
        caretRequest?.cancel()
        caretRequest = nil
        caret = nil
        guard marked != nil else { return }
        marked = nil
        inputContext?.discardMarkedText()
    }

    /// The select's options as a Mac menu over it. Popped up from the run
    /// loop, outside the current event and outside any main-queue block: the
    /// menu's tracking loop drains the main queue only when no block of it is
    /// running (from `DispatchQueue.main.async`, every main-actor job in Loom
    /// — terminals, other sessions' browser calls — would wait for the menu).
    func pumpChoose(from menu: SelectMenuModel, completion: @escaping @MainActor (Int?) -> Void) {
        guard let geometry, window != nil else {
            completion(nil)
            return
        }
        let anchor = geometry.viewRect(fromCSS: menu.rect)
        let choice = SelectMenuChoice(completion: completion)
        let nsMenu = SelectMenuBridge.menu(for: menu, target: choice, action: #selector(SelectMenuChoice.choose(_:)))
        nsMenu.minimumWidth = max(0, anchor.width)
        let checked = nsMenu.items.first { $0.state == .on }
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else {
                    choice.finish(nil)
                    return
                }
                let picked = nsMenu.popUp(positioning: checked, at: NSPoint(x: anchor.minX, y: anchor.minY), in: self)
                if picked {
                    // Its action normally came already; if AppKit queued it, it comes first.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { choice.finish(nil) }
                    }
                } else {
                    choice.finish(nil)
                }
            }
        }
    }
}

/// The page view in SwiftUI. A tab switch changes its source, never the
/// view itself (the keyboard stays where it is).
struct ChromiumPageViewRepresentable: NSViewRepresentable {
    let source: ChromiumScreencastSource?
    let input: UserInputPump?
    let onPageArea: @MainActor (_ size: CGSize, _ backingScale: CGFloat, _ onScreen: Bool) -> Void

    func makeNSView(context: Context) -> ChromiumPageView {
        let view = ChromiumPageView(frame: .zero)
        view.onPageArea = onPageArea
        view.input = input
        view.source = source
        return view
    }

    func updateNSView(_ view: ChromiumPageView, context: Context) {
        view.onPageArea = onPageArea
        view.input = input
        view.source = source
    }

    static func dismantleNSView(_ view: ChromiumPageView, coordinator: ()) {
        view.detach()
    }
}
