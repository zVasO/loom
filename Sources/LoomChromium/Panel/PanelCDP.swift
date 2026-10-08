#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// What the user's input in the side panel becomes on the wire (ADR-0016,
// panel design §2): `Input.*` commands as values — Equatable for the tests,
// Codable for the golden sequences (Tests/AgentBrowserCDP/fixtures/
// panel-sequences.json), Sendable so they cross to the pump's queue — and
// back to the (method, params) tuples `CDPConnection.post(batch:)` writes.

/// A JSON value as a command's params hold it. Numbers are one case, so an
/// integer and the same double compare equal (JSON does not tell them apart).
public indirect enum PanelJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PanelJSON])
    case object([String: PanelJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([PanelJSON].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: PanelJSON].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    public var doubleValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    /// A whole number only: 65, never 65.5.
    public var intValue: Int? {
        guard case .number(let number) = self, number.isFinite, number == number.rounded(.towardZero),
              abs(number) <= Self.exactIntegers else { return nil }
        return Int(number)
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public var arrayValue: [PanelJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    /// 2^53: past it a double no longer holds every integer.
    static let exactIntegers: Double = 9_007_199_254_740_992

    /// What JSONSerialization writes: a whole number as an Int (`65`, never
    /// `65.0`, which a CDP integer field might refuse), NSNull for null.
    public var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .number(let number):
            guard number.isFinite else { return 0 }
            if number == number.rounded(.towardZero), abs(number) <= Self.exactIntegers {
                return Int(number)
            }
            return number
        case .string(let string):
            return string
        case .array(let array):
            return array.map { $0.foundationValue }
        case .object(let object):
            return object.mapValues { $0.foundationValue }
        }
    }

    /// A JSONSerialization-style value (what `CDPInput` builds); nil for
    /// anything JSON cannot hold.
    public init?(foundation value: Any) {
        switch value {
        case let json as PanelJSON:
            self = json
        case let string as String:
            self = .string(string)
        case is NSNull:
            self = .null
        case let object as [String: Any]:
            var converted: [String: PanelJSON] = [:]
            for (key, element) in object {
                guard let json = PanelJSON(foundation: element) else { return nil }
                converted[key] = json
            }
            self = .object(converted)
        case let array as [Any]:
            var converted: [PanelJSON] = []
            for element in array {
                guard let json = PanelJSON(foundation: element) else { return nil }
                converted.append(json)
            }
            self = .array(converted)
        default:
            guard let scalar = PanelJSON.scalar(value) else { return nil }
            self = scalar
        }
    }

    /// A Bool or a number. The exact dynamic type decides first: a Swift
    /// Bool is never read as 1, nor an Int as true.
    private static func scalar(_ value: Any) -> PanelJSON? {
        let kind = Swift.type(of: value)
        if kind == Bool.self, let bool = value as? Bool { return .bool(bool) }
        if kind == Int.self, let number = value as? Int { return .number(Double(number)) }
        if kind == Double.self, let number = value as? Double { return .number(number) }
        if kind == Float.self, let number = value as? Float { return .number(Double(number)) }
        if kind == CGFloat.self, let number = value as? CGFloat { return .number(Double(number)) }
        if kind == Int64.self, let number = value as? Int64 { return .number(Double(number)) }
        if kind == Int32.self, let number = value as? Int32 { return .number(Double(number)) }
        if kind == Int16.self, let number = value as? Int16 { return .number(Double(number)) }
        if kind == Int8.self, let number = value as? Int8 { return .number(Double(number)) }
        if kind == UInt.self, let number = value as? UInt { return .number(Double(number)) }
        if kind == UInt64.self, let number = value as? UInt64 { return .number(Double(number)) }
        if kind == UInt32.self, let number = value as? UInt32 { return .number(Double(number)) }
        if kind == UInt16.self, let number = value as? UInt16 { return .number(Double(number)) }
        if kind == UInt8.self, let number = value as? UInt8 { return .number(Double(number)) }
        // JSONSerialization's output: a boolean NSNumber is a char ("c").
        if let number = value as? NSNumber {
            if String(cString: number.objCType) == "c" { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        return nil
    }
}

extension PanelJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(arrayLiteral elements: PanelJSON...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, PanelJSON)...) {
        var object: [String: PanelJSON] = [:]
        for (key, value) in elements {
            object[key] = value
        }
        self = .object(object)
    }
}

/// One DevTools command of the panel: `Input.dispatchMouseEvent`,
/// `Input.dispatchKeyEvent`, `Input.insertText`, `Input.imeSetComposition`.
public struct PanelCDPCommand: Codable, Equatable, Sendable {
    public var method: String
    public var params: [String: PanelJSON]

    public init(method: String, params: [String: PanelJSON] = [:]) {
        self.method = method
        self.params = params
    }

    /// From `CDPInput`'s (method, params). A value JSON cannot hold is left
    /// out — `CDPInput` builds none.
    public init(_ command: (String, [String: Any])) {
        var params: [String: PanelJSON] = [:]
        for (key, value) in command.1 {
            if let json = PanelJSON(foundation: value) {
                params[key] = json
            }
        }
        self.init(method: command.0, params: params)
    }

    /// The (method, params) `CDPConnection.post(batch:)` writes.
    public var cdpCommand: (String, [String: Any]) {
        (method, params.mapValues { $0.foundationValue })
    }

    /// Commands in order, as one `post(batch:)`: one write, so nothing of
    /// Chromium's runs between them.
    public static func cdpBatch(_ commands: [PanelCDPCommand]) -> [(String, [String: Any])] {
        commands.map { $0.cdpCommand }
    }

    /// `params.type` ("mouseMoved", "keyDown"…), when it has one.
    public var type: String? {
        params["type"]?.stringValue
    }

    private enum CodingKeys: String, CodingKey {
        case method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent([String: PanelJSON].self, forKey: .params) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }
}

extension PanelCDPCommand: CustomStringConvertible {
    /// `method {params}`, keys sorted: what a failing test prints.
    public var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(params) else { return method }
        return method + " " + String(decoding: data, as: UTF8.self)
    }
}

/// `Input.dispatchKeyEvent.type`: `keyDown` types its `text`, `rawKeyDown`
/// carries none (Tab, arrows, shortcuts).
public enum KeyEventType: String, Equatable, Sendable {
    case keyDown, rawKeyDown, keyUp
}

extension PanelCDPCommand {

    public static let dispatchMouseEvent = CDPInput.dispatchMouseEvent
    public static let dispatchKeyEvent = CDPInput.dispatchKeyEvent
    public static let insertTextMethod = "Input.insertText"
    public static let imeSetCompositionMethod = "Input.imeSetComposition"

    /// A key event of the panel. `nativeKeyCode` is the Mac's virtual key
    /// code (NSEvent.keyCode) — what tells the gate which key is held.
    /// `text` goes as `text` and `unmodifiedText`; location 0 and a false
    /// autoRepeat are left out, as `CDPInput` leaves them.
    public static func keyEvent(_ type: KeyEventType, _ key: KeyIdentity, nativeKeyCode: UInt16,
                                modifiers: CDPModifiers, text: String? = nil, autoRepeat: Bool = false,
                                commands: [String] = []) -> PanelCDPCommand {
        var params: [String: PanelJSON] = [
            "type": .string(type.rawValue),
            "key": .string(key.key),
            "code": .string(key.code),
            "windowsVirtualKeyCode": .number(Double(key.windowsKeyCode)),
            "nativeVirtualKeyCode": .number(Double(nativeKeyCode)),
            "modifiers": .number(Double(modifiers.rawValue)),
        ]
        if let text {
            params["text"] = .string(text)
            params["unmodifiedText"] = .string(text)
        }
        if key.location != 0 { params["location"] = .number(Double(key.location)) }
        if key.location == 3 { params["isKeypad"] = .bool(true) }
        if autoRepeat { params["autoRepeat"] = .bool(true) }
        if !commands.isEmpty { params["commands"] = .array(commands.map { PanelJSON.string($0) }) }
        return PanelCDPCommand(method: dispatchKeyEvent, params: params)
    }

    /// Text as an IME commits it: trusted beforeinput and input, no key event.
    public static func insertText(_ text: String) -> PanelCDPCommand {
        PanelCDPCommand(CDPInput.insertText(text))
    }

    /// The marked text of a composition (a dead key's "^", kana before
    /// conversion); "" ends it with nothing inserted.
    public static func imeSetComposition(_ text: String, selectionStart: Int, selectionEnd: Int) -> PanelCDPCommand {
        PanelCDPCommand(CDPInput.imeSetComposition(text, selectionStart: selectionStart, selectionEnd: selectionEnd))
    }
}
