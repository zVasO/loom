import Foundation

/// A flattened target session (`Target.attachToTarget{flatten:true}`): every
/// message of one tab carries its id. No id means the browser session.
public struct CDPSessionID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A parsed JSON object (JSONSerialization output), immutable once parsed:
/// read on the reader queue, then handed to whoever awaits it.
public struct CDPObject: @unchecked Sendable {
    public let raw: [String: Any]

    public init(_ raw: [String: Any]) {
        self.raw = raw
    }

    public func string(_ key: String) -> String? {
        raw[key] as? String
    }

    /// JSON numbers arrive as NSNumber; a fractional one is truncated.
    public func int(_ key: String) -> Int? {
        Self.integer(raw[key])
    }

    public func double(_ key: String) -> Double? {
        guard let value = raw[key] else { return nil }
        if let number = value as? Double { return number }
        return (value as? NSNumber)?.doubleValue
    }

    public func bool(_ key: String) -> Bool? {
        raw[key] as? Bool
    }

    public func object(_ key: String) -> CDPObject? {
        (raw[key] as? [String: Any]).map { CDPObject($0) }
    }

    /// The array's objects; its other elements are skipped.
    public func objects(_ key: String) -> [CDPObject]? {
        guard let array = raw[key] as? [Any] else { return nil }
        return array.compactMap { element in
            (element as? [String: Any]).map { CDPObject($0) }
        }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? Int { return number }
        return (value as? NSNumber)?.intValue
    }
}

/// What ends a wait early on a page, besides its reply: the call's
/// `interruptible` set names the ones it gives up on.
public enum CDPInterruption: Error, Hashable, Sendable {
    /// A JavaScript dialog blocks the page: an `Input.*` or an evaluation
    /// would only answer once the dialog is handled.
    case dialogOpened
    case navigated
    case crashed
    case detached
}

public enum CDPError: Error, Equatable, Sendable {
    /// Chromium answered `{"error":{code, message}}`.
    case protocolError(method: String, code: Int, message: String)
    case timeout(method: String)
    case interrupted(CDPInterruption)
    /// The pipe is gone: EOF, a write that failed, or `close()`.
    case disconnected(String)
    /// The awaiting task was cancelled; the late reply is dropped by id.
    case cancelled

    /// `protocolError`'s code for a reply Loom could not read (over the
    /// frame limit, or not JSON): JSON-RPC's server-error range, not one
    /// Chromium uses.
    public static let unreadableCode = -32_099
}

public struct CDPCallOptions: Sendable {
    /// Past it the call fails with `.timeout`; its late reply is dropped by id.
    public var deadline: ContinuousClock.Instant?
    /// Session events that end the wait (the late reply is dropped by id).
    public var interruptible: Set<CDPInterruption>

    public init(deadline: ContinuousClock.Instant? = nil, interruptible: Set<CDPInterruption> = []) {
        self.deadline = deadline
        self.interruptible = interruptible
    }
}

/// Receives events on the reader queue, in wire order, BEFORE any reply that
/// followed them is resumed: a caller woken by a reply knows every event
/// Chromium sent before it was already applied.
///
/// From `handle`, a sink may `post`, `setSink`, `interrupt` or `failAll` —
/// never wait for a reply: this very queue is the one that would read it.
public protocol CDPEventSink: AnyObject, Sendable {
    func handle(method: String, params: CDPObject, session: CDPSessionID?)
}

/// One frame from Chromium, sorted: a reply carries the `id` of our command,
/// an event a `method`.
enum CDPInbound {
    case result(id: Int, CDPObject)
    case failure(id: Int, code: Int, message: String)
    case event(method: String, params: CDPObject, session: CDPSessionID?)

    /// nil for a frame that is not a JSON object, or neither a reply nor an event.
    static func parse(_ frame: Data) -> CDPInbound? {
        // Chromium escapes a lone UTF-16 surrogate as it is (a page's string
        // cut in the middle of an emoji: "ab\ud83d"); JSONSerialization
        // refuses the whole frame for it. Read again with U+FFFD in its place.
        guard let object = (try? JSONSerialization.jsonObject(with: frame))
                ?? wellFormed(frame).flatMap({ try? JSONSerialization.jsonObject(with: $0) }),
              let fields = object as? [String: Any] else { return nil }
        let message = CDPObject(fields)
        if let id = message.int("id") {
            if let error = message.object("error") {
                return .failure(id: id, code: error.int("code") ?? 0, message: error.string("message") ?? "")
            }
            return .result(id: id, message.object("result") ?? CDPObject([:]))
        }
        guard let method = message.string("method") else { return nil }
        let session = message.string("sessionId").map { CDPSessionID($0) }
        return .event(method: method, params: message.object("params") ?? CDPObject([:]), session: session)
    }

    /// `frame` with each unpaired `\uD800`–`\uDFFF` escape written `\uFFFD`;
    /// nil when it has none. Escapes are ASCII and a backslash only occurs
    /// inside strings, so a byte scan that steps over `\\` is exact.
    static func wellFormed(_ frame: Data) -> Data? {
        let bytes = [UInt8](frame)
        let count = bytes.count
        let backslash = UInt8(ascii: "\\")
        let letterU = UInt8(ascii: "u")
        func unit(at index: Int) -> Int? {
            guard index + 6 <= count, bytes[index] == backslash, bytes[index + 1] == letterU else { return nil }
            var value = 0
            for byte in bytes[(index + 2)..<(index + 6)] {
                guard let digit = Int(String(UnicodeScalar(byte)), radix: 16) else { return nil }
                value = value * 16 + digit
            }
            return value
        }
        let replacement = Array("\\uFFFD".utf8)
        var out: [UInt8] = []
        var changed = false
        var index = 0
        out.reserveCapacity(count)
        while index < count {
            guard bytes[index] == backslash, index + 1 < count else {
                out.append(bytes[index])
                index += 1
                continue
            }
            guard let value = unit(at: index) else {
                out.append(contentsOf: bytes[index...(index + 1)])   // \" \\ \n …: kept, and stepped over
                index += 2
                continue
            }
            switch value {
            case 0xD800...0xDBFF:
                if let low = unit(at: index + 6), (0xDC00...0xDFFF).contains(low) {
                    out.append(contentsOf: bytes[index..<(index + 12)])
                    index += 12
                } else {
                    out.append(contentsOf: replacement)
                    changed = true
                    index += 6
                }
            case 0xDC00...0xDFFF:
                out.append(contentsOf: replacement)
                changed = true
                index += 6
            default:
                out.append(contentsOf: bytes[index..<(index + 6)])
                index += 6
            }
        }
        return changed ? Data(out) : nil
    }
}
