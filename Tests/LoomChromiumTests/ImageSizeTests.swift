import Testing
import LoomChromium
import Foundation

// Seam: the header bytes as Chromium writes them. The images are built by
// hand, header only: the size never needs a pixel.

@Suite("ImageSize — PNG and JPEG headers")
struct ImageSizeTests {

    /// Signature, then IHDR: 1280 × 720, 8-bit RGBA, and a CRC nobody checks.
    private static let png: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0xD0,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    private static let soi: [UInt8] = [0xFF, 0xD8]
    /// JFIF APP0: 16 bytes long, its length included.
    private static let app0: [UInt8] = [
        0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    ]
    /// A DHT segment: its marker (C4) sits in the SOF range and must not be taken for one.
    private static let dht: [UInt8] = [0xFF, 0xC4, 0x00, 0x05, 0x00, 0x01, 0x02]

    /// A frame header: 640 × 480, three components.
    private static func sof(_ marker: UInt8, width: UInt16 = 640, height: UInt16 = 480) -> [UInt8] {
        [0xFF, marker, 0x00, 0x11, 0x08,
         UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF),
         0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
    }

    private static let sos: [UInt8] = [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]

    /// [width, height]: an Equatable shape #expect can compare.
    private func size(_ bytes: [UInt8]) -> [Int]? {
        ImageSize.of(Data(bytes)).map { [$0.width, $0.height] }
    }

    @Test("a PNG's size comes from its IHDR")
    func taillePng() {
        #expect(size(Self.png) == [1280, 720])
    }

    @Test("a PNG cut inside IHDR, or whose first chunk is not IHDR, has no size")
    func pngTronque() {
        #expect(size(Array(Self.png.prefix(23))) == nil)
        var renamed = Self.png
        renamed[12] = 0x69   // "iHDR"
        #expect(size(renamed) == nil)
        var zero = Self.png
        zero[16...19] = [0, 0, 0, 0]
        #expect(size(zero) == nil)
    }

    @Test("a baseline JPEG's size comes from SOF0, past APP0")
    func jpegBaseline() {
        #expect(size(Self.soi + Self.app0 + Self.sof(0xC0) + Self.sos) == [640, 480])
    }

    @Test("SOF1 and SOF2 are frame headers too; DHT is not")
    func jpegAutresTrames() {
        #expect(size(Self.soi + Self.sof(0xC1, width: 1, height: 2)) == [1, 2])
        #expect(size(Self.soi + Self.app0 + Self.dht + Self.sof(0xC2, width: 2560, height: 1600)) == [2560, 1600])
    }

    @Test("fill bytes before a marker are skipped")
    func jpegOctetsDeRemplissage() {
        #expect(size(Self.soi + [0xFF, 0xFF] + Self.app0 + Self.sof(0xC0)) == [640, 480])
    }

    @Test("a JPEG cut before its frame header ends, or scanning before any, has no size")
    func jpegTronque() {
        let whole = Self.soi + Self.app0 + Self.sof(0xC0)
        for length in [2, 3, 4, Self.soi.count + Self.app0.count, whole.count - 11] {
            #expect(size(Array(whole.prefix(length))) == nil, "cut at \(length)")
        }
        #expect(size(Self.soi + Self.app0 + Self.sos + Self.sof(0xC0)) == nil)
        #expect(size(Self.soi + [0xFF, 0xD9]) == nil)
    }

    @Test("neither format, or nothing at all, has no size")
    func autresDonnees() {
        #expect(size([]) == nil)
        #expect(size(Array("GIF89a\u{1}\u{0}\u{1}\u{0}".utf8)) == nil)
        #expect(size([0xFF, 0xD8, 0x00, 0x00, 0x00, 0x00]) == nil)
    }

    @Test("a slice of a larger buffer is read from its own start")
    func tranche() throws {
        let padded = Data([0xAA, 0xBB] + Self.png)
        let found = try #require(ImageSize.of(padded.dropFirst(2)))
        #expect(found.width == 1280)
        #expect(found.height == 720)
    }
}
