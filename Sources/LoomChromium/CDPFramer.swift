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
        /// JSONSerialization cannot write this message. Checked first: it
        /// would raise an Objective-C exception, which no `try` catches.
        case notJSON
    }

    /// What a chunk completes, in wire order.
    public enum Piece: Equatable, Sendable {
        case frame(Data)
        /// A frame past the limit, dropped as it came: its first bytes (a
        /// reply's `{"id":N` names the call to fail) and its full length.
        case oversized(head: Data, length: Int)
    }

    /// How much of an oversized frame is kept: enough for `{"id":N,`.
    public static let headBytes = 64

    public let maxFrameBytes: Int
    private var pending = Data()
    /// How far into `pending` the last scan looked without finding a NUL: a
    /// screenshot arriving in 64 KB reads is not rescanned from its start
    /// at each of them.
    private var scanned = 0
    /// Inside an oversized frame: its head and the bytes seen so far; the
    /// rest is dropped up to its NUL. NUL never occurs inside JSON text, so
    /// the next one always ends the frame and the stream stays in step.
    private var skipping: (head: Data, length: Int)?

    public init(maxFrameBytes: Int = 256 << 20) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// The frames `chunk` completes, in wire order, without their NUL. An
    /// empty frame carries nothing and is skipped; so is one over the limit
    /// (`read` names it).
    public mutating func feed(_ chunk: Data) -> [Data] {
        read(chunk).compactMap { piece in
            if case .frame(let frame) = piece { return frame }
            return nil
        }
    }

    /// `feed`, with the frames over the limit named where they were: one
    /// answer too big fails its own call, never the whole connection.
    public mutating func read(_ chunk: Data) -> [Piece] {
        var pieces: [Piece] = []
        var chunk = chunk
        if let skipped = skipping {
            guard let terminator = Self.firstNUL(in: chunk, from: 0) else {
                skipping = (skipped.head, skipped.length + chunk.count)
                return []
            }
            pieces.append(.oversized(head: skipped.head, length: skipped.length + terminator))
            skipping = nil
            chunk = chunk.subdata(in: (chunk.startIndex + terminator + 1)..<chunk.endIndex)
        }
        pending.append(chunk)
        var start = 0
        var cursor = scanned
        while let terminator = Self.firstNUL(in: pending, from: cursor) {
            let length = terminator - start
            let base = pending.startIndex
            if length > maxFrameBytes {
                let head = pending.subdata(in: (base + start)..<(base + start + min(Self.headBytes, length)))
                pieces.append(.oversized(head: head, length: length))
            } else if length > 0 {
                pieces.append(.frame(pending.subdata(in: (base + start)..<(base + terminator))))
            }
            start = terminator + 1
            cursor = start
        }
        if start > 0 {
            // One cut per chunk, however many frames it held.
            pending.removeSubrange(pending.startIndex..<(pending.startIndex + start))
        }
        scanned = pending.count
        if pending.count > maxFrameBytes {
            // No NUL yet and already too big: dropped as it arrives.
            skipping = (Data(pending.prefix(Self.headBytes)), pending.count)
            pending = Data()
            scanned = 0
        }
        return pieces
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
