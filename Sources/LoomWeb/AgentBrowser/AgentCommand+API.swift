import Foundation
import LoomAPI

// The API's browser methods (ADR-0014) to the agent browser's commands, and
// its answers back — here rather than in the app, so the tests reach it.

extension AgentCommand {

    /// The command a browser method asks for; invalid parameters are the
    /// API's `invalidParams`, in words the agent can fix its call with.
    public init(method: APIMethod, params: JSONValue) throws {
        do {
            self = try Self.command(method, params)
        } catch let error as AgentError {
            throw error.apiError
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ params: JSONValue) throws -> T {
        do {
            return try params.decode(type)
        } catch {
            throw APIError(code: .invalidParams, message: "invalid parameters: \(Self.reason(error))")
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "\(key.stringValue) is required"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path.isEmpty ? "a value" : path) has the wrong type"
        default: return "\(error)"
        }
    }

    private static func command(_ method: APIMethod, _ params: JSONValue) throws -> AgentCommand {
        switch method {
        case .browserNavigate:
            let p = try decode(APIBrowserNavigateParams.self, params)
            return .navigate(try AgentNavigationPolicy.navigationURL(p.url))
        case .browserNavigateBack:
            return .navigateBack
        case .browserSnapshot:
            let p = try decode(APIBrowserSnapshotParams.self, params)
            let target = (p.target ?? p.ref).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return .snapshot(target: target, depth: try p.depth.map { try whole($0, "depth", minimum: 1) })
        case .browserClick:
            let p = try decode(APIBrowserClickParams.self, params)
            let button = try p.button.map { raw -> MouseButton in
                guard let button = MouseButton(rawValue: raw) else {
                    throw AgentError.invalid("button is left, right or middle")
                }
                return button
            } ?? .left
            let modifiers = p.modifiers ?? []
            for modifier in modifiers where !["Alt", "Control", "ControlOrMeta", "Meta", "Shift"].contains(modifier) {
                throw AgentError.invalid("unknown modifier \(modifier): Alt, Control, ControlOrMeta, Meta or Shift")
            }
            return .click(try target(p.target ?? p.ref, element: p.element), doubleClick: p.doubleClick ?? false,
                          button: button, modifiers: modifiers)
        case .browserType:
            let p = try decode(APIBrowserTypeParams.self, params)
            return .type(try target(p.target ?? p.ref, element: p.element), text: p.text, submit: p.submit ?? false)
        case .browserSelectOption:
            let p = try decode(APIBrowserSelectOptionParams.self, params)
            guard !p.values.isEmpty else { throw AgentError.invalid("values must name at least one option") }
            return .selectOption(try target(p.target ?? p.ref, element: p.element), values: p.values)
        case .browserHover:
            let p = try decode(APIBrowserTargetParams.self, params)
            return .hover(try target(p.target ?? p.ref, element: p.element))
        case .browserPressKey:
            let p = try decode(APIBrowserPressKeyParams.self, params)
            return .pressKey(try KeySpec.parse(p.key))
        case .browserWaitFor:
            let p = try decode(APIBrowserWaitForParams.self, params)
            return try wait(time: p.time, text: p.text, textGone: p.textGone, timeout: p.timeout)
        case .browserScreenshot:
            let p = try decode(APIBrowserScreenshotParams.self, params)
            let format = try p.type.map { raw -> ImageFormat in
                guard let format = ImageFormat(rawValue: raw) else { throw AgentError.invalid("type is png or jpeg") }
                return format
            } ?? .png
            let raw = p.target ?? p.ref
            let target = try raw.map { try Self.target($0, element: p.element) }
            return .screenshot(target: target, format: format)
        case .browserConsole:
            let p = try decode(APIBrowserConsoleParams.self, params)
            let level = try p.level.map { raw -> ConsoleLevel in
                guard let level = ConsoleLevel(rawValue: raw) else {
                    throw AgentError.invalid("level is error, warning, info or debug")
                }
                return level
            } ?? .info
            return .console(level: level, all: p.all ?? false)
        case .browserNetwork:
            let p = try decode(APIBrowserNetworkParams.self, params)
            return .network(filter: p.filter)
        case .browserEvaluate:
            let p = try decode(APIBrowserEvaluateParams.self, params)
            guard !p.function.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentError.invalid("function is required: () => document.title")
            }
            let raw = p.target ?? p.ref
            return .evaluate(function: p.function, target: try raw.map { try Self.target($0, element: p.element) })
        case .browserHandleDialog:
            let p = try decode(APIBrowserHandleDialogParams.self, params)
            return .handleDialog(accept: p.accept, promptText: p.promptText)
        case .browserTabs:
            let p = try decode(APIBrowserTabsParams.self, params)
            switch p.action {
            case "list":
                return .tabs(.list)
            case "new":
                let url = try p.url.map { try AgentNavigationPolicy.navigationURL($0) }
                return .tabs(.new(url))
            case "select":
                guard let index = p.index else { throw AgentError.invalid("select needs an index") }
                return .tabs(.select(try whole(index, "index", minimum: 0)))
            case "close":
                return .tabs(.close(try p.index.map { try whole($0, "index", minimum: 0) }))
            default:
                throw AgentError.invalid("action is list, new, select or close")
            }
        case .browserClose:
            return .close
        default:
            throw APIError(code: .unknownMethod, message: "\(method.rawValue) is not a browser method")
        }
    }

    private static func whole(_ value: Double, _ name: String, minimum: Int) throws -> Int {
        guard let integer = Int(exactly: value), integer >= minimum else {
            throw AgentError.invalid("\(name) must be a whole number ≥ \(minimum)")
        }
        return integer
    }
}

extension AgentError {
    /// The API's code for each failure.
    public var apiError: APIError {
        switch self {
        case .notFound(let message): return APIError(code: .notFound, message: message)
        case .invalid(let message): return APIError(code: .invalidParams, message: message)
        case .timeout(let message): return APIError(code: .timeout, message: message)
        case .unavailable(let message): return APIError(code: .unavailable, message: message)
        case .conflict(let message): return APIError(code: .conflict, message: message)
        case .failed(let message): return APIError(code: .unavailable, message: message)
        }
    }
}

extension AgentResult {
    /// The answer as the API carries it: Markdown, and the image's path.
    public var apiContent: APIToolContent {
        APIToolContent(text: text, image: image.map {
            APIImageRef(path: $0.url.path, mimeType: $0.mimeType, width: $0.width, height: $0.height)
        })
    }
}
