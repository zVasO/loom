import Foundation

/// The pixel size of a PNG or JPEG, read from its header. Chromium encodes
/// screenshots itself at the size asked; Loom needs that size, never the
/// pixels, so nothing is decoded.
public enum ImageSize {

    /// nil: neither format, or a header cut short.
    public static func of(_ data: Data) -> (width: Int, height: Int)? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> (width: Int, height: Int)? in
            if let size = png(bytes) { return size }
            return jpeg(bytes)
        }
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The signature, then IHDR, always the first chunk: its data opens on
    /// the width and the height, four bytes each, big-endian.
    private static func png(_ bytes: UnsafeRawBufferPointer) -> (width: Int, height: Int)? {
        guard bytes.count >= 24, bytes.prefix(8).elementsEqual(pngSignature),
              bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 else { return nil }
        let width = bigEndian32(bytes, at: 16)
        let height = bigEndian32(bytes, at: 20)
        // The format caps both at 2^31 - 1.
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else { return nil }
        return (width, height)
    }

    /// Segment after segment until a frame header (SOFn): each one names its
    /// own length, so APPn, DQT and DHT are stepped over unread. A scan or the
    /// end of the image before any frame header: no size to give.
    private static func jpeg(_ bytes: UnsafeRawBufferPointer) -> (width: Int, height: Int)? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xFF {
                index += 1   // a fill byte before the marker
                continue
            }
            index += 2
            switch marker {
            case 0x01, 0xD0...0xD8:
                continue     // TEM, RSTn, SOI: no length follows
            case 0x00, 0xD9, 0xDA:
                return nil   // stuffed data, EOI, SOS
            default:
                break
            }
            guard index + 2 <= bytes.count else { return nil }
            let length = bigEndian16(bytes, at: index)
            guard length >= 2 else { return nil }
            if isFrameHeader(marker) {
                // Length, precision, then height and width.
                guard length >= 7, index + 7 <= bytes.count else { return nil }
                let height = bigEndian16(bytes, at: index + 3)
                let width = bigEndian16(bytes, at: index + 5)
                // A zero height is given later by a DNL segment: unknown here.
                guard width > 0, height > 0 else { return nil }
                return (width, height)
            }
            index += length
        }
        return nil
    }

    /// SOF0 to SOF15, less DHT (C4), JPG (C8) and DAC (CC), which share the range.
    private static func isFrameHeader(_ marker: UInt8) -> Bool {
        (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
    }

    private static func bigEndian16(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int {
        let high = Int(bytes[offset])
        let low = Int(bytes[offset + 1])
        return high << 8 | low
    }

    private static func bigEndian32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int {
        let high = bigEndian16(bytes, at: offset)
        let low = bigEndian16(bytes, at: offset + 2)
        return high << 16 | low
    }
}
