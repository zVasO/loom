import AppKit
import LoomChromium
import SwiftUI

// The live picture of the agent's Chromium tab in the side panel
// (ADR-0016), watch-only for now: no click, key or focus reaches the page
// from here — the user's input comes with its own step. The view is flipped
// so a view point reads like a CSS point (ScreencastGeometry).

/// A layer whose contents are the latest decoded frame, aspect-fit. It asks
/// for frames only while it is on screen — in a window that is visible, not
/// hidden, with a size and a tab — and tells the surface the page area it
/// has, for Fit and for the frames' size.
@MainActor
public final class ChromiumPageView: NSView {

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
            }
            refresh()
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

    /// A size settles before the surface hears of it and the stream follows:
    /// a divider being dragged would otherwise re-emulate the page and
    /// restart the frames at every step. Meanwhile the frame on screen
    /// simply scales (resizeAspect).
    static let resizeDebounce: UInt64 = 150_000_000

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Agent browser page")
        setAccessibilityHelp("A live picture of claude's browser.")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("ChromiumPageView is built in code")
    }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    // Watch-only: never the first responder, so the terminal keeps its keys.
    public override var acceptsFirstResponder: Bool { false }

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

    /// The view leaves the panel: no more frames, and the surface knows.
    func detach() {
        stream.stop()
        cancelSettle()
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: observedWindow)
            self.observedWindow = nil
        }
        if let reported, reported.onScreen {
            send(size: reported.size, scale: reported.scale, onScreen: false)
        }
        onPageArea = nil
    }
}

/// The page view in SwiftUI. A tab switch changes its source, never the
/// view itself.
struct ChromiumPageViewRepresentable: NSViewRepresentable {
    let source: ChromiumScreencastSource?
    let onPageArea: @MainActor (_ size: CGSize, _ backingScale: CGFloat, _ onScreen: Bool) -> Void

    func makeNSView(context: Context) -> ChromiumPageView {
        let view = ChromiumPageView(frame: .zero)
        view.onPageArea = onPageArea
        view.source = source
        return view
    }

    func updateNSView(_ view: ChromiumPageView, context: Context) {
        view.onPageArea = onPageArea
        view.source = source
    }

    static func dismantleNSView(_ view: ChromiumPageView, coordinator: ()) {
        view.detach()
    }
}
