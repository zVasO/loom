#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// The live picture of the agent's page in the side panel (ADR-0016): what a
// `Page.screencastFrame` carries, and where its page lands in the view.
// Pure, so the arithmetic is tested without AppKit; the view and the stream
// live in LoomWeb.
//
// Coordinates: the view's in points, origin top-left, y down (the page view
// is flipped, like CSS); the page's in CSS pixels of the frame's own
// metadata — never the emulation in force now, which may already have
// changed under a frame still on screen.

/// `params.metadata` of a `Page.screencastFrame`.
public struct ScreencastFrameMetadata: Equatable, Sendable {
    /// Always 0 under desktop emulation (no top controls).
    public var offsetTop: Double
    /// Ignored, as DevTools' own screencast view does: pinch zoom is off.
    public var pageScaleFactor: Double
    /// The page's viewport in CSS pixels — not the frame's pixel size, which
    /// `maxWidth` / `maxHeight` scale down.
    public var deviceWidth: Double
    public var deviceHeight: Double
    public var scrollOffsetX: Double
    public var scrollOffsetY: Double
    public var timestamp: Double?

    public init(offsetTop: Double = 0, pageScaleFactor: Double = 1, deviceWidth: Double, deviceHeight: Double,
                scrollOffsetX: Double = 0, scrollOffsetY: Double = 0, timestamp: Double? = nil) {
        self.offsetTop = offsetTop
        self.pageScaleFactor = pageScaleFactor
        self.deviceWidth = deviceWidth
        self.deviceHeight = deviceHeight
        self.scrollOffsetX = scrollOffsetX
        self.scrollOffsetY = scrollOffsetY
        self.timestamp = timestamp
    }

    /// nil without a positive device size: nothing could be mapped through it.
    public init?(_ object: CDPObject) {
        guard let width = object.double("deviceWidth"), let height = object.double("deviceHeight"),
              width > 0, height > 0 else { return nil }
        self.init(offsetTop: object.double("offsetTop") ?? 0,
                  pageScaleFactor: object.double("pageScaleFactor") ?? 1,
                  deviceWidth: width, deviceHeight: height,
                  scrollOffsetX: object.double("scrollOffsetX") ?? 0,
                  scrollOffsetY: object.double("scrollOffsetY") ?? 0,
                  timestamp: object.double("timestamp"))
    }

    public var deviceSize: CGSize {
        CGSize(width: deviceWidth, height: deviceHeight)
    }
}

/// One `Page.screencastFrame`, parsed off the main thread.
public struct ScreencastFrame: Equatable, Sendable {
    /// `params.sessionId`: the number `Page.screencastFrameAck` gives back —
    /// the frame's, not the CDP session's.
    public let ackId: Int
    /// The flattened session of the tab; nil on the browser session.
    public let session: CDPSessionID?
    /// The JPEG, base64 already decoded.
    public let image: Data
    public let metadata: ScreencastFrameMetadata

    public init(ackId: Int, session: CDPSessionID?, image: Data, metadata: ScreencastFrameMetadata) {
        self.ackId = ackId
        self.session = session
        self.image = image
        self.metadata = metadata
    }

    public static let method = "Page.screencastFrame"

    /// nil for anything but a whole frame: another event, no ack number,
    /// data that is not base64, a metadata without a size.
    public static func parse(_ raw: Data) -> ScreencastFrame? {
        guard let message = frameMessage(raw), let params = message.object("params"),
              let ackId = params.int("sessionId"), let encoded = params.string("data"),
              let image = Data(base64Encoded: encoded), !image.isEmpty,
              let metadata = params.object("metadata").flatMap({ ScreencastFrameMetadata($0) }) else { return nil }
        return ScreencastFrame(ackId: ackId, session: message.string("sessionId").map { CDPSessionID($0) },
                               image: image, metadata: metadata)
    }

    /// What acknowledging a frame takes, even of one `parse` refuses or
    /// nobody shows: left unacknowledged, a few frames stall the stream
    /// (step-0 probe: 4 frames, then nothing).
    public static func acknowledgement(ofRaw raw: Data) -> (ackId: Int, session: CDPSessionID?)? {
        guard let message = frameMessage(raw), let ackId = message.object("params")?.int("sessionId") else {
            return nil
        }
        return (ackId, message.string("sessionId").map { CDPSessionID($0) })
    }

    private static func frameMessage(_ raw: Data) -> CDPObject? {
        guard let object = try? JSONSerialization.jsonObject(with: raw),
              let fields = object as? [String: Any] else { return nil }
        let message = CDPObject(fields)
        return message.string("method") == method ? message : nil
    }

    private static let sessionKey = Array(#""sessionId":""#.utf8)

    /// The CDP session of a raw frame, read from its tail without parsing
    /// the base64 before it: Chromium writes the session last
    /// (`…"sessionId":7},"sessionId":"HEX"}`). The frame's own number is
    /// unquoted, so it never matches. nil on the browser session.
    public static func session(ofRaw raw: Data) -> CDPSessionID? {
        let key = sessionKey
        return raw.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> CDPSessionID? in
            var end = bytes.count
            while end > 0, isSpace(bytes[end - 1]) {
                end -= 1
            }
            // `"}` closes the session's string and the message.
            guard end >= key.count + 2, bytes[end - 1] == UInt8(ascii: "}"),
                  bytes[end - 2] == UInt8(ascii: "\"") else { return nil }
            let valueEnd = end - 2
            var valueStart = valueEnd
            // Chromium's session ids are 32 hex digits; 128 bytes is plenty.
            let floor = max(0, valueEnd - 128)
            while valueStart > floor {
                let byte = bytes[valueStart - 1]
                if byte == UInt8(ascii: "\"") { break }
                if byte == UInt8(ascii: "\\") { return nil }
                valueStart -= 1
            }
            // The key ends on the value's opening quote.
            let keyStart = valueStart - key.count
            guard valueStart < valueEnd, keyStart >= 0 else { return nil }
            for offset in 0..<key.count where bytes[keyStart + offset] != key[offset] {
                return nil
            }
            return CDPSessionID(String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self))
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// Where the page's picture lands in the view, and how a point of one maps
/// to the other.
///
/// The picture is aspect-fit and centred both ways — what
/// `CALayer.contentsGravity = .resizeAspect` draws — so a page whose height
/// follows the panel fills it, and a pinned height (`browser_resize` with a
/// height) shows a letterbox.
public struct ScreencastGeometry: Equatable, Sendable {
    /// The page area, in points.
    public var viewSize: CGSize
    /// The view's window backing scale (2 on Retina).
    public var backingScale: CGFloat
    /// `deviceWidth` × `deviceHeight` of the frame ON SCREEN, in CSS pixels.
    public var device: CGSize
    /// The frame's pixel size: its aspect is the one drawn. Chromium keeps the
    /// device's when it scales down, to a rounding; zero means the device's.
    public var image: CGSize

    public init(viewSize: CGSize, backingScale: CGFloat = 1, device: CGSize, image: CGSize = .zero) {
        self.viewSize = viewSize
        self.backingScale = backingScale
        self.device = device
        self.image = image
    }

    /// Of the frame on screen.
    public init(viewSize: CGSize, backingScale: CGFloat = 1, metadata: ScreencastFrameMetadata,
                image: CGSize = .zero) {
        self.init(viewSize: viewSize, backingScale: backingScale, device: metadata.deviceSize, image: image)
    }

    /// The picture's rectangle in the view; empty without a frame or a size.
    public var contentRect: CGRect {
        let drawn = image.width > 0 && image.height > 0 ? image : device
        guard drawn.width > 0, drawn.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / drawn.width, viewSize.height / drawn.height)
        let width = drawn.width * scale
        let height = drawn.height * scale
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2,
                      width: width, height: height)
    }

    /// Points on screen per CSS pixel of the page; 0 without a frame.
    public var pointsPerCSSPixel: CGFloat {
        guard device.width > 0 else { return 0 }
        return contentRect.width / device.width
    }

    /// The page point under a view point; nil in the letterbox or without a
    /// frame — a press there is not the page's.
    public func cssPoint(fromView point: CGPoint) -> CGPoint? {
        let rect = contentRect
        guard !rect.isEmpty, device.width > 0, device.height > 0,
              point.x >= rect.minX, point.x < rect.maxX, point.y >= rect.minY, point.y < rect.maxY else { return nil }
        return cssPointUnclamped(fromView: point)
    }

    /// Past the picture's edges too: a drag may leave the view and go on.
    public func cssPointUnclamped(fromView point: CGPoint) -> CGPoint {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: (point.x - rect.minX) * device.width / rect.width,
                       y: (point.y - rect.minY) * device.height / rect.height)
    }

    public func viewPoint(fromCSS point: CGPoint) -> CGPoint {
        let rect = contentRect
        guard device.width > 0, device.height > 0 else { return rect.origin }
        return CGPoint(x: rect.minX + point.x * rect.width / device.width,
                       y: rect.minY + point.y * rect.height / device.height)
    }

    /// A page rectangle (an element's, a caret's) in the view.
    public func viewRect(fromCSS rect: CGRect) -> CGRect {
        let origin = viewPoint(fromCSS: rect.origin)
        let far = viewPoint(fromCSS: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: far.x - origin.x, height: far.y - origin.y)
    }

    /// A pixel's worth of scrolling for one line of a wheel without precise deltas.
    public static let wheelLinePixels: CGFloat = 40

    /// An NSEvent scroll as `Input.dispatchMouseEvent{mouseWheel}` deltas:
    /// points of a trackpad scaled to the page, or lines of a mouse wheel;
    /// the sign flipped, CDP's positive deltaY scrolling down.
    public func cssWheelDelta(_ delta: CGSize, precise: Bool) -> CGSize {
        guard precise else {
            return CGSize(width: -delta.width * Self.wheelLinePixels, height: -delta.height * Self.wheelLinePixels)
        }
        let scale = pointsPerCSSPixel
        guard scale > 0 else { return CGSize(width: -delta.width, height: -delta.height) }
        return CGSize(width: -delta.width / scale, height: -delta.height / scale)
    }

    /// `Page.startScreencast`'s `maxWidth` × `maxHeight`: the view's own
    /// pixels. Chromium scales a frame down into them, aspect kept, and
    /// never up — a frame is never larger than the screen shows.
    public static func screencastMax(viewSize: CGSize, backingScale: CGFloat) -> (width: Int, height: Int) {
        let scale = backingScale > 0 ? backingScale : 1
        let width = viewSize.width > 0 ? Int((viewSize.width * scale).rounded(.up)) : 1
        let height = viewSize.height > 0 ? Int((viewSize.height * scale).rounded(.up)) : 1
        return (max(1, width), max(1, height))
    }

    public var screencastMax: (width: Int, height: Int) {
        Self.screencastMax(viewSize: viewSize, backingScale: backingScale)
    }

    /// A restart is worth it only past a few pixels: a divider dragged by one
    /// point must not stop and start the stream at each step.
    public static let restartThreshold = 8

    public static func needsRestart(from old: (width: Int, height: Int), to new: (width: Int, height: Int)) -> Bool {
        abs(old.width - new.width) >= restartThreshold || abs(old.height - new.height) >= restartThreshold
    }

    /// The aspect a page area that was never measured stands for (1280 × 720).
    public static let fallbackAspect: CGFloat = 720.0 / 1_280.0

    /// The size the page is emulated at, in CSS pixels. `cssWidth` nil: the
    /// panel's own size (Fit). A width: the height follows the panel's aspect,
    /// so the scaled picture fills its width — unless the agent pinned one.
    public static func emulatedViewport(cssWidth: Int?, pageArea: CGSize,
                                        pinnedHeight: Int? = nil) -> (width: Int, height: Int) {
        let measured = pageArea.width >= 1 && pageArea.height >= 1
        guard let cssWidth else {
            guard measured else { return (1_280, pinnedHeight ?? 720) }
            return (Int(pageArea.width.rounded(.down)), pinnedHeight ?? Int(pageArea.height.rounded(.down)))
        }
        let width = max(1, cssWidth)
        if let pinnedHeight { return (width, max(1, pinnedHeight)) }
        let aspect = measured ? pageArea.height / pageArea.width : fallbackAspect
        return (width, max(1, Int((CGFloat(width) * aspect).rounded())))
    }
}
