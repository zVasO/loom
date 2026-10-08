import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import LoomChromium
import os

// The live picture of a Chromium tab (ADR-0016): `Page.startScreencast`
// while a page view shows the tab on screen, frames taken raw off the
// connection's reader queue, parsed and acknowledged at once, decoded by
// ImageIO off the main thread, the latest one only handed to the main actor.
// Nothing about a frame waits on main: a busy terminal costs the panel
// frames, never Chromium its flow (unacknowledged, it stalls after 4).

private let screencastLogger = Logger(subsystem: "app.loom", category: "agent-browser")

/// Where a tab's frames come from: its browser's connection and the tab's
/// flattened session. Equal when both are the same.
public struct ChromiumScreencastSource: Equatable, Sendable {
    public let connection: CDPConnection
    public let session: CDPSessionID

    public init(connection: CDPConnection, session: CDPSessionID) {
        self.connection = connection
        self.session = session
    }

    public static func == (lhs: ChromiumScreencastSource, rhs: ChromiumScreencastSource) -> Bool {
        lhs.connection === rhs.connection && lhs.session == rhs.session
    }
}

/// One decoded frame, as the page view shows it.
public struct ScreencastPicture: @unchecked Sendable {
    // CGImage is immutable once decoded: safe to hand across threads.
    public let image: CGImage
    public let metadata: ScreencastFrameMetadata
    public let session: CDPSessionID

    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

/// The frames of one page view: one tab at a time, restarted when the tab
/// or the view's pixel size changes, stopped when the view leaves the screen.
/// Thread-safe; its picture is delivered on the main actor.
public final class ScreencastStream: @unchecked Sendable {

    /// JPEG quality asked of `Page.startScreencast`: about 7 KB a frame at
    /// 1280 × 800 (step-0 probe), 60 frames a second while the page animates.
    public static let quality = 60
    /// How many tabs' last frames are kept (compressed) for an instant
    /// picture when the panel comes back or switches tab.
    static let cachedTabs = 4

    private let decodeQueue: DispatchQueue
    private let onPicture: @MainActor (ScreencastPicture) -> Void
    private let log: @Sendable (String) -> Void

    // Guarded by `lock`.
    private let lock = NSLock()
    private var source: ChromiumScreencastSource?
    private var size: (width: Int, height: Int) = (0, 0)
    /// Bumped by every start and stop: what an older run decoded is dropped.
    private var generation = 0
    private var pending: ScreencastFrame?
    private var pendingGeneration = 0
    private var decoding = false
    private var ready: ScreencastPicture?
    private var readyGeneration = 0
    private var delivering = false
    private var cache: [CDPSessionID: ScreencastFrame] = [:]
    private var cacheOrder: [CDPSessionID] = []

    /// `log` nil: the agent browser's log.
    public init(label: String = "panel", log: (@Sendable (String) -> Void)? = nil,
                onPicture: @escaping @MainActor (ScreencastPicture) -> Void) {
        self.decodeQueue = DispatchQueue(label: "app.loom.agent-browser.screencast.\(label)", qos: .userInteractive)
        self.onPicture = onPicture
        if let log {
            self.log = log
        } else {
            self.log = { message in
                screencastLogger.info("\(message, privacy: .public)")
            }
        }
    }

    deinit {
        // The view went without detaching: Chromium stops sending to nobody.
        if let source {
            ScreencastRouter.shared.unregister(self, connection: source.connection, session: source.session)
            source.connection.post("Page.stopScreencast", [:], session: source.session)
        }
    }

    /// Whether frames of a tab are asked for now.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    /// Streams `next` at `maxWidth` × `maxHeight` pixels at most: starts it,
    /// or restarts it for another tab or a size 8 px or more away; nothing
    /// for the same tab at about the same size. false: the picture on screen
    /// is another tab's and none of this one is cached — the view clears it
    /// rather than show the wrong page until the first frame (about 45 ms).
    @discardableResult
    public func show(_ next: ChromiumScreencastSource, maxWidth: Int, maxHeight: Int) -> Bool {
        let wanted = (width: max(1, maxWidth), height: max(1, maxHeight))
        lock.lock()
        let previous = source
        if previous == next, !ScreencastGeometry.needsRestart(from: size, to: wanted) {
            lock.unlock()
            return true
        }
        generation += 1
        source = next
        size = wanted
        pending = nil
        ready = nil
        let cached = previous == next ? nil : cache[next.session]
        if let cached {
            pending = cached
            pendingGeneration = generation
        }
        let decodeNow = cached != nil && !decoding
        if decodeNow {
            decoding = true
        }
        lock.unlock()

        // The new route first: on the same connection the raw subscription
        // then stays up across a tab switch.
        ScreencastRouter.shared.register(self, connection: next.connection, session: next.session)
        if let previous, previous != next {
            ScreencastRouter.shared.unregister(self, connection: previous.connection, session: previous.session)
            previous.connection.post("Page.stopScreencast", [:], session: previous.session)
        }
        let start: (String, [String: Any]) = ("Page.startScreencast", [
            "format": "jpeg", "quality": Self.quality,
            "maxWidth": wanted.width, "maxHeight": wanted.height, "everyNthFrame": 1,
        ])
        if previous == next {
            // New size, same tab: one write, stop then start, in order.
            _ = next.connection.post(batch: [("Page.stopScreencast", [:]), start], session: next.session,
                                     options: CDPCallOptions())
        } else {
            next.connection.post(start.0, start.1, session: next.session)
        }
        if decodeNow {
            decodeQueue.async { self.drain() }
        }
        return cached != nil || previous == next
    }

    /// No more frames: the view left the screen, or has no tab to show.
    public func stop() {
        lock.lock()
        let previous = source
        source = nil
        generation += 1
        pending = nil
        ready = nil
        lock.unlock()
        guard let previous else { return }
        ScreencastRouter.shared.unregister(self, connection: previous.connection, session: previous.session)
        previous.connection.post("Page.stopScreencast", [:], session: previous.session)
    }

    /// Forgets a gone tab's last frame.
    public func forget(_ session: CDPSessionID) {
        lock.lock()
        cache[session] = nil
        cacheOrder.removeAll { $0 == session }
        lock.unlock()
    }

    // MARK: - Frames (the router's queue)

    /// Every frame is acknowledged at once — without it Chromium stops after
    /// a few — then only the latest waits to be decoded.
    func receive(_ raw: Data, connection: CDPConnection) {
        guard let frame = ScreencastFrame.parse(raw) else {
            ScreencastRouter.acknowledge(raw, on: connection)
            log("screencast: an unreadable frame of \(raw.count) bytes was dropped")
            return
        }
        connection.post("Page.screencastFrameAck", ["sessionId": frame.ackId], session: frame.session)
        guard let session = frame.session else { return }
        lock.lock()
        guard let current = source, current.connection === connection, current.session == session else {
            lock.unlock()
            return
        }
        remember(frame, for: session)
        pending = frame
        pendingGeneration = generation
        let decodeNow = !decoding
        if decodeNow {
            decoding = true
        }
        lock.unlock()
        if decodeNow {
            decodeQueue.async { self.drain() }
        }
    }

    /// Under `lock`.
    private func remember(_ frame: ScreencastFrame, for session: CDPSessionID) {
        cache[session] = frame
        cacheOrder.removeAll { $0 == session }
        cacheOrder.append(session)
        while cacheOrder.count > Self.cachedTabs {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    // MARK: - Decoding (its own queue)

    private func drain() {
        while true {
            lock.lock()
            guard let frame = pending else {
                decoding = false
                lock.unlock()
                return
            }
            let frameGeneration = pendingGeneration
            pending = nil
            lock.unlock()

            guard let session = frame.session, let image = Self.decode(frame.image) else {
                log("screencast: a frame ImageIO could not decode was dropped")
                continue
            }
            let picture = ScreencastPicture(image: image, metadata: frame.metadata, session: session)
            lock.lock()
            guard frameGeneration == generation, source != nil else {
                lock.unlock()
                continue
            }
            ready = picture
            readyGeneration = frameGeneration
            let hop = !delivering
            if hop {
                delivering = true
            }
            lock.unlock()
            if hop {
                // One hop at a time: frames decoded meanwhile replace the
                // one waiting, so main shows the latest at its own pace.
                DispatchQueue.main.async { self.deliver() }
            }
        }
    }

    /// The JPEG decoded now, here, not lazily at the first draw on main.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    // MARK: - Delivery (main)

    private func deliver() {
        lock.lock()
        let picture = ready
        let current = readyGeneration == generation && source != nil
        ready = nil
        delivering = false
        lock.unlock()
        guard let picture, current else { return }
        MainActor.assumeIsolated {
            onPicture(picture)
        }
    }
}

/// A connection allows one raw subscription per method: this one is shared
/// by every stream of its tabs and routed by the session read from each
/// frame's tail, so another tab's frames never cost a parse. One stream per
/// session: a second view of the same tab takes its frames over.
final class ScreencastRouter: @unchecked Sendable {

    static let shared = ScreencastRouter()

    private final class Route {
        weak var connection: CDPConnection?
        var streams: [CDPSessionID: WeakStream] = [:]

        init(connection: CDPConnection) {
            self.connection = connection
        }
    }

    private struct WeakStream {
        weak var stream: ScreencastStream?
    }

    /// Where raw frames are handed over: parse and ack happen here.
    private let queue = DispatchQueue(label: "app.loom.agent-browser.screencast.route", qos: .userInteractive)

    // Guarded by `lock`. The connection's (un)subscribe runs under it too, so
    // a stream leaving cannot drop the subscription another just took; the
    // connection never calls back here holding its own lock.
    private let lock = NSLock()
    private var routes: [ObjectIdentifier: Route] = [:]

    func register(_ stream: ScreencastStream, connection: CDPConnection, session: CDPSessionID) {
        let key = ObjectIdentifier(connection)
        let queue = self.queue
        lock.lock()
        defer { lock.unlock() }
        // A dead connection's identifier may be a new one's: its route is stale.
        if let existing = routes[key], existing.connection === connection {
            existing.streams[session] = WeakStream(stream: stream)
            return
        }
        let route = Route(connection: connection)
        route.streams[session] = WeakStream(stream: stream)
        routes[key] = route
        connection.subscribeRaw(method: ScreencastFrame.method, queue: queue) { [weak self, weak connection] raw in
            guard let self, let connection else { return }
            self.dispatch(raw, from: connection)
        }
    }

    /// Only the stream registered: another view may have taken the session since.
    func unregister(_ stream: ScreencastStream, connection: CDPConnection, session: CDPSessionID) {
        let key = ObjectIdentifier(connection)
        lock.lock()
        defer { lock.unlock() }
        guard let route = routes[key], route.connection === connection else { return }
        if let registered = route.streams[session], registered.stream === stream || registered.stream == nil {
            route.streams[session] = nil
        }
        route.streams = route.streams.filter { $0.value.stream != nil }
        guard route.streams.isEmpty else { return }
        routes[key] = nil
        connection.unsubscribeRaw(method: ScreencastFrame.method)
    }

    private func dispatch(_ raw: Data, from connection: CDPConnection) {
        let session = ScreencastFrame.session(ofRaw: raw)
        lock.lock()
        let route = routes[ObjectIdentifier(connection)]
        var stream: ScreencastStream?
        if let route, route.connection === connection, let session {
            stream = route.streams[session]?.stream
        }
        lock.unlock()
        if let stream {
            stream.receive(raw, connection: connection)
        } else {
            // A frame still in flight after its stream stopped: acknowledged
            // all the same, Chromium counts them.
            Self.acknowledge(raw, on: connection)
        }
    }

    /// `Page.screencastFrameAck` for a frame nobody shows.
    static func acknowledge(_ raw: Data, on connection: CDPConnection) {
        guard let ack = ScreencastFrame.acknowledgement(ofRaw: raw) else { return }
        connection.post("Page.screencastFrameAck", ["sessionId": ack.ackId], session: ack.session)
    }
}
