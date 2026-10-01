import Foundation

/// A key as the page's events carry it — parsed from Playwright's syntax
/// ("Enter", "Shift+Tab", "ControlOrMeta+a", "a"), encoded as the helper reads it.
public struct KeySpec: Codable, Equatable, Sendable {
    public var key: String
    public var code: String
    public var keyCode: Int
    /// What the key types, when it types something.
    public var text: String?
    public var shiftKey: Bool
    public var ctrlKey: Bool
    public var altKey: Bool
    public var metaKey: Bool

    public init(key: String, code: String, keyCode: Int, text: String? = nil,
                shiftKey: Bool = false, ctrlKey: Bool = false, altKey: Bool = false, metaKey: Bool = false) {
        self.key = key
        self.code = code
        self.keyCode = keyCode
        self.text = text
        self.shiftKey = shiftKey
        self.ctrlKey = ctrlKey
        self.altKey = altKey
        self.metaKey = metaKey
    }

    private static let named: [String: (code: String, keyCode: Int, text: String?)] = {
        var table: [String: (String, Int, String?)] = [
            "Enter": ("Enter", 13, nil), "Tab": ("Tab", 9, nil), "Escape": ("Escape", 27, nil),
            "Backspace": ("Backspace", 8, nil), "Delete": ("Delete", 46, nil), "Insert": ("Insert", 45, nil),
            "ArrowLeft": ("ArrowLeft", 37, nil), "ArrowUp": ("ArrowUp", 38, nil),
            "ArrowRight": ("ArrowRight", 39, nil), "ArrowDown": ("ArrowDown", 40, nil),
            "Home": ("Home", 36, nil), "End": ("End", 35, nil),
            "PageUp": ("PageUp", 33, nil), "PageDown": ("PageDown", 34, nil),
            "Space": ("Space", 32, " "),
        ]
        for n in 1...12 { table["F\(n)"] = ("F\(n)", 111 + n, nil) }
        return table.mapValues { (code: $0.0, keyCode: $0.1, text: $0.2) }
    }()

    private static let punctuation: [Character: (code: String, keyCode: Int)] = [
        "-": ("Minus", 189), "=": ("Equal", 187), "[": ("BracketLeft", 219), "]": ("BracketRight", 221),
        "\\": ("Backslash", 220), ";": ("Semicolon", 186), "'": ("Quote", 222), ",": ("Comma", 188),
        ".": ("Period", 190), "/": ("Slash", 191), "`": ("Backquote", 192), " ": ("Space", 32),
    ]

    private static let modifierNames: [String: WritableKeyPath<KeySpec, Bool>] = [
        "shift": \.shiftKey, "control": \.ctrlKey, "ctrl": \.ctrlKey, "alt": \.altKey, "option": \.altKey,
        "meta": \.metaKey, "command": \.metaKey, "cmd": \.metaKey,
        // Playwright's portable spelling: ⌘ on macOS.
        "controlormeta": \.metaKey,
    ]

    public static func parse(_ input: String) throws -> KeySpec {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw AgentError.invalid("key is required, e.g. Enter, Shift+Tab, a") }
        var parts = raw.components(separatedBy: "+")
        // "+" itself, alone or after modifiers ("Shift++").
        var keyName: String
        if raw == "+" {
            keyName = "+"
            parts = []
        } else if raw.hasSuffix("++") {
            keyName = "+"
            parts = Array(parts.dropLast(2))
        } else {
            keyName = parts.removeLast()
        }
        var spec = try base(for: keyName)
        for modifier in parts {
            guard let path = modifierNames[modifier.lowercased()] else {
                throw AgentError.invalid("unknown modifier \(modifier): use Shift, Control, Alt, Meta or ControlOrMeta")
            }
            spec[keyPath: path] = true
        }
        if spec.shiftKey, let text = spec.text, text.count == 1, text.first?.isLetter == true {
            spec.text = text.uppercased()
            spec.key = text.uppercased()
        }
        if spec.ctrlKey || spec.metaKey { spec.text = nil }
        return spec
    }

    /// The key that types `character` — `browser_type slowly`, as Playwright's
    /// pressSequentially: a newline is Enter, a capital is Shift and the letter.
    public static func typing(_ character: Character) -> KeySpec {
        switch character {
        case " ": return KeySpec(key: " ", code: "Space", keyCode: 32, text: " ")
        case "\n", "\r\n", "\r": return KeySpec(key: "Enter", code: "Enter", keyCode: 13)
        case "\t": return KeySpec(key: "Tab", code: "Tab", keyCode: 9)
        default: break
        }
        guard var spec = try? base(for: String(character)) else {
            return KeySpec(key: String(character), code: "", keyCode: 0, text: String(character))
        }
        if character.isASCII, character.isLetter, character.isUppercase { spec.shiftKey = true }
        return spec
    }

    private static func base(for name: String) throws -> KeySpec {
        if let known = named[name] {
            return KeySpec(key: name == "Space" ? " " : name, code: known.code, keyCode: known.keyCode, text: known.text)
        }
        if let known = named.first(where: { $0.key.lowercased() == name.lowercased() }) {
            return KeySpec(key: known.key == "Space" ? " " : known.key, code: known.value.code,
                           keyCode: known.value.keyCode, text: known.value.text)
        }
        guard name.count == 1, let character = name.first else {
            let names = named.keys.sorted().joined(separator: ", ")
            throw AgentError.invalid("unknown key \(name): use one character or one of \(names)")
        }
        if character.isLetter, character.isASCII {
            let upper = character.uppercased()
            return KeySpec(key: String(character), code: "Key" + upper,
                           keyCode: Int(upper.unicodeScalars.first!.value), text: String(character))
        }
        if character.isNumber, character.isASCII {
            return KeySpec(key: String(character), code: "Digit\(character)",
                           keyCode: Int(character.unicodeScalars.first!.value), text: String(character))
        }
        if let known = punctuation[character] {
            return KeySpec(key: String(character), code: known.code, keyCode: known.keyCode, text: String(character))
        }
        return KeySpec(key: String(character), code: "", keyCode: 0, text: String(character))
    }
}
