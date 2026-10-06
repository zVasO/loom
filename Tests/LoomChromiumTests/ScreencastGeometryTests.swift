import Testing
import LoomChromium
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Seam: the live picture's arithmetic — where a frame lands in the panel,
// which page point a view point is, what `Page.startScreencast` asks for —
// and the raw frame as the step-0 probe saw it on the wire (session last).
// The sizes are chosen so every product is exact in binary.

@Suite("ScreencastGeometry — the live picture in the panel")
struct ScreencastGeometryTests {

    /// [width, height]: an Equatable shape #expect can compare.
    private func pair(_ size: (width: Int, height: Int)) -> [Int] {
        [size.width, size.height]
    }

    private func geometry(view: CGSize, device: CGSize, image: CGSize = .zero,
                          scale: CGFloat = 1) -> ScreencastGeometry {
        ScreencastGeometry(viewSize: view, backingScale: scale, device: device, image: image)
    }

    // MARK: - Where the picture lands

    @Test("a page whose height follows the panel fills it, at one scale")
    func remplitLePanneau() {
        let fitted = geometry(view: CGSize(width: 600, height: 750), device: CGSize(width: 1_280, height: 1_600))
        #expect(fitted.contentRect == CGRect(x: 0, y: 0, width: 600, height: 750))
        #expect(fitted.pointsPerCSSPixel == 0.46875)
    }

    @Test("a pinned height leaves a letterbox, the picture centred like resizeAspect")
    func bandesHorizontales() {
        let pinned = geometry(view: CGSize(width: 600, height: 800), device: CGSize(width: 1_280, height: 720))
        #expect(pinned.contentRect == CGRect(x: 0, y: 231.25, width: 600, height: 337.5))
    }

    @Test("a panel wider than the page's aspect shows bands at the sides")
    func bandesVerticales() {
        let wide = geometry(view: CGSize(width: 1_000, height: 400), device: CGSize(width: 1_280, height: 800))
        #expect(wide.contentRect == CGRect(x: 180, y: 0, width: 640, height: 400))
        #expect(wide.pointsPerCSSPixel == 0.5)
    }

    @Test("the frame's pixel aspect is the one drawn; the device size stays the mapping's")
    func aspectDeLImage() {
        // A frame scaled to 600 × 376 (rounded) for a 1280 × 800 page.
        let rounded = geometry(view: CGSize(width: 600, height: 800), device: CGSize(width: 1_280, height: 800),
                               image: CGSize(width: 600, height: 376))
        #expect(rounded.contentRect == CGRect(x: 0, y: 212, width: 600, height: 376))
        let bottomRight = rounded.cssPointUnclamped(fromView: CGPoint(x: 600, y: 588))
        #expect(bottomRight == CGPoint(x: 1_280, y: 800))
    }

    @Test("no frame, or no size: no picture, nothing maps")
    func sansImage() {
        let empty = geometry(view: CGSize(width: 600, height: 800), device: .zero)
        #expect(empty.contentRect == .zero)
        #expect(empty.pointsPerCSSPixel == 0)
        #expect(empty.cssPoint(fromView: CGPoint(x: 10, y: 10)) == nil)
        let hidden = geometry(view: .zero, device: CGSize(width: 1_280, height: 800))
        #expect(hidden.contentRect == .zero)
        #expect(hidden.cssPoint(fromView: .zero) == nil)
    }

    // MARK: - View ↔ page

    @Test("the picture's corners and centre are the page's; the letterbox is nobody's")
    func pointsDeLaPage() {
        let pinned = geometry(view: CGSize(width: 600, height: 800), device: CGSize(width: 1_280, height: 720))
        #expect(pinned.cssPoint(fromView: CGPoint(x: 0, y: 231.25)) == CGPoint(x: 0, y: 0))
        #expect(pinned.cssPoint(fromView: CGPoint(x: 300, y: 400)) == CGPoint(x: 640, y: 360))
        #expect(pinned.cssPoint(fromView: CGPoint(x: 150, y: 265)) == CGPoint(x: 320, y: 72))
        #expect(pinned.cssPoint(fromView: CGPoint(x: 300, y: 100)) == nil, "the band above")
        #expect(pinned.cssPoint(fromView: CGPoint(x: 300, y: 700)) == nil, "the band below")
        #expect(pinned.cssPoint(fromView: CGPoint(x: 600, y: 400)) == nil, "the right edge is past the page")
        #expect(pinned.cssPoint(fromView: CGPoint(x: 300, y: 568.75)) == nil, "the bottom edge is past the page")
    }

    @Test("unclamped, a point past the picture maps past the page: a drag goes on")
    func horsDeLImage() {
        let pinned = geometry(view: CGSize(width: 600, height: 800), device: CGSize(width: 1_280, height: 720))
        #expect(pinned.cssPointUnclamped(fromView: CGPoint(x: -30, y: 231.25)) == CGPoint(x: -64, y: 0))
        #expect(pinned.cssPointUnclamped(fromView: CGPoint(x: 300, y: 602.5)) == CGPoint(x: 640, y: 792))
    }

    @Test("a page rectangle lands where its picture is, and maps back")
    func rectangleDeLaPage() {
        let pinned = geometry(view: CGSize(width: 600, height: 800), device: CGSize(width: 1_280, height: 720))
        let element = CGRect(x: 128, y: 64, width: 256, height: 32)
        let shown = pinned.viewRect(fromCSS: element)
        #expect(shown == CGRect(x: 60, y: 261.25, width: 120, height: 15))
        #expect(pinned.cssPoint(fromView: shown.origin) == element.origin)
        #expect(pinned.viewPoint(fromCSS: CGPoint(x: 1_280, y: 720)) == CGPoint(x: 600, y: 568.75))
    }

    // MARK: - Wheel

    @Test("trackpad points scale to the page; a wheel's lines are 40 CSS px; down is positive")
    func molette() {
        let fitted = geometry(view: CGSize(width: 600, height: 750), device: CGSize(width: 1_280, height: 1_600))
        let precise = fitted.cssWheelDelta(CGSize(width: 0, height: 15), precise: true)
        #expect(precise == CGSize(width: 0, height: -32))
        let lines = fitted.cssWheelDelta(CGSize(width: 1, height: -3), precise: false)
        #expect(lines == CGSize(width: -40, height: 120))
        let noFrame = geometry(view: CGSize(width: 600, height: 750), device: .zero)
        #expect(noFrame.cssWheelDelta(CGSize(width: 0, height: 10), precise: true) == CGSize(width: 0, height: -10))
    }

    // MARK: - What the screencast asks for

    @Test("the frames asked for are the view's own pixels, never less than one")
    func tailleDuFlux() {
        let retina = ScreencastGeometry.screencastMax(viewSize: CGSize(width: 600, height: 800), backingScale: 2)
        #expect(pair(retina) == [1_200, 1_600])
        let fractional = ScreencastGeometry.screencastMax(viewSize: CGSize(width: 600.25, height: 800.75),
                                                          backingScale: 2)
        #expect(pair(fractional) == [1_201, 1_602])
        let zero = ScreencastGeometry.screencastMax(viewSize: .zero, backingScale: 0)
        #expect(pair(zero) == [1, 1])
        let fitted = geometry(view: CGSize(width: 300, height: 400), device: CGSize(width: 1_280, height: 800), scale: 2)
        #expect(pair(fitted.screencastMax) == [600, 800])
    }

    @Test("the stream restarts for 8 px or more, not for a divider's every step")
    func redemarrage() {
        #expect(!ScreencastGeometry.needsRestart(from: (1_200, 1_600), to: (1_207, 1_593)))
        #expect(ScreencastGeometry.needsRestart(from: (1_200, 1_600), to: (1_208, 1_600)))
        #expect(ScreencastGeometry.needsRestart(from: (1_200, 1_600), to: (1_200, 1_592)))
    }

    @Test("Fit emulates the panel's points; a width keeps the panel's aspect unless a height is pinned")
    func viewportEmule() {
        let area = CGSize(width: 600.75, height: 800.5)
        #expect(pair(ScreencastGeometry.emulatedViewport(cssWidth: nil, pageArea: area)) == [600, 800])
        let laptop = ScreencastGeometry.emulatedViewport(cssWidth: 1_280, pageArea: CGSize(width: 600, height: 800))
        #expect(pair(laptop) == [1_280, 1_707])
        let pinned = ScreencastGeometry.emulatedViewport(cssWidth: 1_280, pageArea: CGSize(width: 600, height: 800),
                                                         pinnedHeight: 720)
        #expect(pair(pinned) == [1_280, 720])
        let unmeasured = ScreencastGeometry.emulatedViewport(cssWidth: 1_024, pageArea: .zero)
        #expect(pair(unmeasured) == [1_024, 576])
        #expect(pair(ScreencastGeometry.emulatedViewport(cssWidth: nil, pageArea: .zero)) == [1_280, 720])
    }

    // MARK: - The frame on the wire

    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])

    private static func rawFrame(ack: String = "7", data: String? = nil, session: String? = "8F1D6B0C",
                                 metadata: String = #"{"offsetTop":0,"pageScaleFactor":1,"deviceWidth":1280,"deviceHeight":800,"scrollOffsetX":0,"scrollOffsetY":120.5,"timestamp":1759750000.25}"#) -> Data {
        let encoded = data ?? jpeg.base64EncodedString()
        // In steps: one long chain of literals and `+` is slow to type-check.
        var text: String = #"{"method":"Page.screencastFrame","params":{"data":""# + encoded
        text += #"","metadata":"# + metadata
        text += #","sessionId":"# + ack + "}"
        if let session {
            text += #","sessionId":""# + session + #""}"#
        } else {
            text += "}"
        }
        return Data(text.utf8)
    }

    @Test("a frame as Chromium writes it: its ack number, its session, the JPEG, the page's size")
    func trameLue() throws {
        let frame = try #require(ScreencastFrame.parse(Self.rawFrame()))
        #expect(frame.ackId == 7)
        #expect(frame.session == CDPSessionID("8F1D6B0C"))
        #expect(frame.image == Self.jpeg)
        #expect(frame.metadata == ScreencastFrameMetadata(deviceWidth: 1_280, deviceHeight: 800,
                                                          scrollOffsetY: 120.5, timestamp: 1_759_750_000.25))
        #expect(frame.metadata.deviceSize == CGSize(width: 1_280, height: 800))
    }

    @Test("not a whole frame: nothing to show or to ack")
    func trameIncomplete() {
        #expect(ScreencastFrame.parse(Self.rawFrame(data: "not base64!")) == nil)
        #expect(ScreencastFrame.parse(Self.rawFrame(data: "")) == nil)
        #expect(ScreencastFrame.parse(Self.rawFrame(ack: #""7""#)) == nil)
        #expect(ScreencastFrame.parse(Self.rawFrame(metadata: #"{"deviceWidth":0,"deviceHeight":800}"#)) == nil)
        #expect(ScreencastFrame.parse(Data(#"{"method":"Page.frameNavigated","params":{}}"#.utf8)) == nil)
        #expect(ScreencastFrame.parse(Data("{".utf8)) == nil)
    }

    @Test("a frame too damaged to show is still acknowledged: its number and session are enough")
    func accuseDeReception() {
        let damaged = ScreencastFrame.acknowledgement(ofRaw: Self.rawFrame(data: "not base64!"))
        #expect(damaged?.ackId == 7)
        #expect(damaged?.session == CDPSessionID("8F1D6B0C"))
        let browserSession = ScreencastFrame.acknowledgement(ofRaw: Self.rawFrame(session: nil))
        #expect(browserSession?.ackId == 7)
        #expect(browserSession?.session == nil)
        #expect(ScreencastFrame.acknowledgement(ofRaw: Self.rawFrame(ack: #""7""#))?.ackId == nil,
                "no number to give back")
        let other = Data(#"{"method":"Page.frameNavigated","params":{"sessionId":7}}"#.utf8)
        #expect(ScreencastFrame.acknowledgement(ofRaw: other)?.ackId == nil)
        #expect(ScreencastFrame.acknowledgement(ofRaw: Data("{".utf8))?.ackId == nil)
    }

    @Test("the session is read from the tail, past the frame's own unquoted number")
    func sessionEnQueue() {
        #expect(ScreencastFrame.session(ofRaw: Self.rawFrame()) == CDPSessionID("8F1D6B0C"))
        var trailing = Self.rawFrame()
        trailing.append(contentsOf: Array(" \n".utf8))
        #expect(ScreencastFrame.session(ofRaw: trailing) == CDPSessionID("8F1D6B0C"))
        #expect(ScreencastFrame.session(ofRaw: Self.rawFrame(session: nil)) == nil, "the browser session")
        #expect(ScreencastFrame.session(ofRaw: Self.rawFrame(session: "")) == nil)
        #expect(ScreencastFrame.session(ofRaw: Data(#"{"method":"X","params":{},"other":"AB"}"#.utf8)) == nil)
        #expect(ScreencastFrame.session(ofRaw: Data()) == nil)
        let session = ScreencastFrame.parse(Self.rawFrame())?.session
        #expect(session == ScreencastFrame.session(ofRaw: Self.rawFrame()), "the tail agrees with the parse")
    }

    @Test("a metadata object without a page size is no metadata")
    func metadonnees() {
        let object = CDPObject(["deviceWidth": 1_280, "deviceHeight": 720.5, "scrollOffsetX": 3])
        let metadata = ScreencastFrameMetadata(object)
        #expect(metadata?.deviceHeight == 720.5)
        #expect(metadata?.scrollOffsetX == 3)
        #expect(metadata?.offsetTop == 0)
        #expect(metadata?.pageScaleFactor == 1)
        #expect(metadata?.timestamp == nil)
        #expect(ScreencastFrameMetadata(CDPObject(["deviceWidth": 1_280])) == nil)
        #expect(ScreencastFrameMetadata(CDPObject(["deviceWidth": -1, "deviceHeight": 720])) == nil)
    }
}
