import Foundation
import LoomAPI
import LoomCore

extension JSONValue {
    /// From what `JSONSerialization` gives.
    public static func from(any value: Any) -> JSONValue {
        switch value {
        case is NSNull: return .null
        case let number as NSNumber:
            // NSNumber carries booleans too: tell them apart by their type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map(from(any:)))
        case let object as [String: Any]: return .object(object.mapValues(from(any:)))
        default: return .string(String(describing: value))
        }
    }

    public var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let bool): bool
        case .number(let number): number != 0
        case .string(let string): ["true", "yes", "oui", "1"].contains(string.lowercased())
        case .array(let array): !array.isEmpty
        case .object(let object): !object.isEmpty
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .null: true
        case .bool: false
        case .number: false
        case .string(let string): string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let array): array.isEmpty
        case .object(let object): object.isEmpty
        }
    }

    public var numberValue: Double? {
        switch self {
        case .number(let number): number
        case .string(let string): Double(string)
        case .bool(let bool): bool ? 1 : 0
        default: nil
        }
    }

    public var isString: Bool {
        if case .string = self { return true }
        return false
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// How a value reads inside a prompt: text as is, numbers without a
    /// pointless `.0`, a list of texts as bullets, anything else as JSON.
    public var plainText: String {
        switch self {
        case .null: return ""
        case .bool(let bool): return bool ? "true" : "false"
        case .number(let number):
            return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .string(let string): return string
        case .array(let items) where items.allSatisfy(\.isString):
            return items.map { "- " + $0.plainText }.joined(separator: "\n")
        case .array, .object: return prettyJSON
        }
    }

    public var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// `steps.coherence.findings.0.title` in a JSON value. An integer segment
/// indexes an array.
public enum JSONPath {
    public static func lookup(_ path: String, in root: JSONValue) -> JSONValue? {
        var current: JSONValue? = root
        for segment in path.split(separator: ".").map(String.init) {
            guard let value = current else { return nil }
            switch value {
            case .object(let object): current = object[segment]
            case .array(let array):
                guard let index = Int(segment), array.indices.contains(index) else { return nil }
                current = array[index]
            default: return nil
            }
        }
        return current
    }
}

/// `{{path}}` in a prompt, filled from the run's context:
/// `steps.<id>.<field>`, `steps.<id>.text`, `previous.<id>` (its answer in
/// the pass before), `history.<id>` (every earlier pass), `pr.*`,
/// `ticket.*`, `repo.*`, `iteration`.
public enum TemplateRenderer {
    public struct Rendered: Equatable, Sendable {
        public let text: String
        /// Paths that named nothing — the editor warns about them.
        public let unknown: [String]
    }

    public static func render(_ template: String, context: JSONValue) -> Rendered {
        var output = ""
        var unknown: [String] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                output += rest[open.lowerBound...]
                rest = ""
                break
            }
            let path = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = JSONPath.lookup(path, in: context) {
                output += value.plainText
            } else {
                unknown.append(path)
            }
            rest = after[close.upperBound...]
        }
        output += rest
        return Rendered(text: output, unknown: unknown)
    }

    /// Every `{{path}}` a template names.
    public static func paths(in template: String) -> [String] {
        var paths: [String] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else { break }
            paths.append(after[..<close.lowerBound].trimmingCharacters(in: .whitespaces))
            rest = after[close.upperBound...]
        }
        return paths
    }

    /// The context a run's templates read, from its inputs and its state.
    public static func context(inputs: JSONValue, state: RunState, planner: WorkflowPlanner,
                               for nodeID: String? = nil) -> JSONValue {
        var steps: [String: JSONValue] = [:]
        var previous: [String: JSONValue] = [:]
        for node in planner.workflow.nodes {
            if let record = state.nodes[node.id], record.status == .done {
                var object = record.output?.objectValue ?? [:]
                object["text"] = .string(record.text ?? record.output?.plainText ?? "")
                steps[node.id] = .object(object)
            }
            if let last = state.history[node.id]?.last { previous[node.id] = last }
        }
        var root = inputs.objectValue ?? [:]
        root["steps"] = .object(steps)
        root["previous"] = .object(previous)
        root["history"] = .object(state.history.mapValues { .array($0) })
        let pass = nodeID.map { planner.pass(of: $0, in: state) } ?? planner.currentPass(in: state)
        root["iteration"] = .number(Double(pass))
        return .object(root)
    }
}

/// A step's answer: what claude is told to write, and the check that it did.
public enum OutputSchema {

    public static func instructions(for fields: [OutputField]) -> String {
        guard !fields.isEmpty else { return "" }
        let lines = fields.map { field -> String in
            let shape: String
            switch field.type {
            case .text: shape = "string"
            case .list: shape = "array"
            case .boolean: shape = "true or false"
            case .number: shape = "number"
            case .object: shape = "object"
            }
            let optional = field.required ? "" : " (optional)"
            let about = field.description.isEmpty ? "" : " — \(field.description)"
            return "- \"\(field.name)\": \(shape)\(optional)\(about)"
        }
        return """
        Answer with ONE JSON object and nothing else — no prose before or after, no code fence. Its keys:
        \(lines.joined(separator: "\n"))
        """
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noObject
        case invalid([String])

        public var description: String {
            switch self {
            case .noObject: "The answer holds no JSON object."
            case .invalid(let problems): problems.joined(separator: " ")
            }
        }
    }

    /// The answer as an object, checked against the fields. A missing
    /// optional field is fine; a wrong type is not.
    public static func parse(_ text: String, fields: [OutputField]) -> Result<JSONValue, ParseError> {
        guard let data = LenientJSON.objectData(in: text),
              let any = try? JSONSerialization.jsonObject(with: data) else { return .failure(.noObject) }
        let value = JSONValue.from(any: any)
        let problems = validate(value, against: fields)
        return problems.isEmpty ? .success(value) : .failure(.invalid(problems))
    }

    public static func validate(_ value: JSONValue, against fields: [OutputField]) -> [String] {
        guard let object = value.objectValue else { return ["The answer is not a JSON object."] }
        var problems: [String] = []
        for field in fields {
            guard let item = object[field.name], item != .null else {
                if field.required { problems.append("\"\(field.name)\" is missing.") }
                continue
            }
            let matches: Bool
            switch (field.type, item) {
            case (.text, .string), (.list, .array), (.boolean, .bool), (.number, .number), (.object, .object):
                matches = true
            default:
                matches = false
            }
            if !matches { problems.append("\"\(field.name)\" should be \(field.type.rawValue).") }
        }
        return problems
    }
}
