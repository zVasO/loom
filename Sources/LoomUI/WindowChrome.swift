import AppKit
import SwiftUI

/// AppKit keeps a title-bar band at the top of the window — 32 pt, measured from
/// `contentLayoutRect` — even when the title bar is hidden. It swallows the SECOND
/// click of a double-click there, then, having no title to act on, does nothing
/// with it: SwiftUI's own gesture is never offered the event. Below that band the
/// gesture works normally. A local monitor sees the click before the window does.
public struct TitleBarDoubleClick: NSViewRepresentable {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public func makeNSView(context: Context) -> WatchNSView {
        let view = WatchNSView()
        view.action = action
        return view
    }

    public func updateNSView(_ view: WatchNSView, context: Context) {
        view.action = action
    }

    public final class WatchNSView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window,
                      event.clickCount == 2,
                      event.locationInWindow.y > window.contentLayoutRect.maxY,
                      !Self.hitsWindowButton(event.locationInWindow, in: window)
                else { return event }
                self.action?()
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// The traffic lights answer for themselves.
        private static func hitsWindowButton(_ point: NSPoint, in window: NSWindow) -> Bool {
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            return types.contains { type in
                guard let button = window.standardWindowButton(type) else { return false }
                return button.convert(button.bounds, to: nil)
                    .insetBy(dx: -6, dy: -6)
                    .contains(point)
            }
        }
    }
}
