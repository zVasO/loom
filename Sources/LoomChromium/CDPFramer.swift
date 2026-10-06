#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The `--remote-debugging-pipe` wire: each message is one JSON text followed
/// by a NUL byte (Chromium's `PipeWriterASCIIZ`). A read ends anywhere —
/// mid-frame, mid-character — so the bytes after the last NUL wait for the
/// next chunk.
public struct CDPFramer: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// A frame outgrew the limit before its NUL: the peer is not speaking
        /// the protocol, and buffering on would only exhaust memory.
        case frameTooLarge(limit: Int)
        /// JSONSerialization cannot write this message. Checked first: it
        /// would raise an Objective-C exception, which no `try` catches.
        case notJSON
    }

    public let maxFrameBytes: Int
    private var pending = Data()
    /// How far into `pending` the last scan looked without finding a NUL: a
    /// screenshot arriving in 64 KB reads is not rescanned from its start
    /// at each of them.
    private var scanned = 0

    public init(maxFrameBytes: Int = 256 << 20) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// The frames `chunk` completes, in wire order, without their NUL. An
    /// empty frame carries nothing and is skipped. After a throw the framer
    /// is spent: a stream cut at an arbitrary byte cannot be resynchronised.
    public mutating func feed(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var frames: [Data] = []
        var start = 0
        var cursor = scanned
        while let terminator = Self.firstNUL(in: pending, from: cursor) {
            let length = terminator - start
            guard length <= maxFrameBytes else { throw Failure.frameTooLarge(limit: maxFrameBytes) }
            if length > 0 {
                let base = pending.startIndex
                frames.append(pending.subdata(in: (base + start)..<(base + terminator)))
            }
            start = terminator + 1
            cursor = start
        }
        if start > 0 {
            // One cut per chunk, however many frames it held.
            pending.removeSubrange(pending.startIndex..<(pending.startIndex + start))
        }
        scanned = pending.count
        guard pending.count <= maxFrameBytes else { throw Failure.frameTooLarge(limit: maxFrameBytes) }
        return frames
    }

    /// One message as it goes on the wire: its JSON, then the NUL.
    public static func encode(_ message: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(message) else { throw Failure.notJSON }
        var frame = try JSONSerialization.data(withJSONObject: message)
        frame.append(UInt8(0))
        return frame
    }

    /// Offset of the first NUL at or after `offset`: memchr, since a frame
    /// can be megabytes of base64.
    private static func firstNUL(in data: Data, from offset: Int) -> Int? {
        guard offset < data.count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.baseAddress,
                  let hit = memchr(base + offset, 0, raw.count - offset) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }
}
