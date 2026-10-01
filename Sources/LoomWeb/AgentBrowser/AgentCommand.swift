import Foundation

/// What went wrong with a command, in words the agent can act on. Mapped to
/// the API's codes at the edge (AgentCommand+API.swift).
public enum AgentError: Error, Equatable, Sendable {
    case notFound(String)
    case invalid(String)
    case timeout(String)
    case unavailable(String)
    /// The page is waiting on a dialog: answer it first.
    case conflict(String)
    case failed(String)

    public var message: String {
        switch self {
        case .notFound(let m), .invalid(let m), .timeout(let m), .unavailable(let m), .conflict(let m),
             .failed(let m):
            return m
        }
    }
}

/// An element the agent names: a ref from the latest snapshot (`e12`) or a
/// CSS selector matching exactly one element. `element` is the agent's own
/// description, echoed back.
public struct AgentTarget: Equatable, Sendable {
    public var target: String
    public var element: String?

    public init(target: String, element: String? = nil) {
        self.target = target
        self.element = element
    }

    public var isRef: Bool {
        target.range(of: #"^(f\d+)?e\d+$"#, options: .regularExpression) != nil
    }
}

public enum MouseButton: String, Codable, Equatable, Sendable {
    case left, right, middle
}

public enum ImageFormat: String, Codable, Equatable, Sendable {
    case png, jpeg

    public var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
}

public enum TabsAction: Equatable, Sendable {
    case list
    case new(URL?)
    case select(Int)
    case close(Int?)
}

/// One command of the agent's browser, validated — the engine runs it as is.
public enum AgentCommand: Equatable, Sendable {
    case navigate(URL)
    case navigateBack
    case snapshot(target: String?, depth: Int?)
    case click(AgentTarget, doubleClick: Bool, button: MouseButton, modifiers: [String])
    case type(AgentTarget, text: String, submit: Bool)
    case selectOption(AgentTarget, values: [String])
    case hover(AgentTarget)
    case pressKey(KeySpec)
    case waitFor(time: Double?, text: String?, textGone: String?, timeout: Double)
    case screenshot(target: AgentTarget?, format: ImageFormat)
    case console(level: ConsoleLevel, all: Bool)
    case network(filter: String?)
    case evaluate(function: String, target: AgentTarget?)
    case handleDialog(accept: Bool, promptText: String?)
    case tabs(TabsAction)
    case close

    /// The longest a wait may last, `time` and `timeout` together: the
    /// method's deadline must hold the worst case.
    public static let maxWait: Double = 30
    public static let defaultWaitTimeout: Double = 10

    /// The agent touched a page: the side panel may be revealed (once).
    public var touchesPage: Bool {
        switch self {
        case .console, .network, .close, .handleDialog: return false
        case .tabs(let action): return action != .list
        default: return true
        }
    }

    /// Opens a tab when none exists.
    public var createsBrowser: Bool {
        switch self {
        case .navigate: return true
        case .tabs(.new): return true
        default: return false
        }
    }

    /// A validated `.waitFor` (a static func of the case's own name would
    /// collide with it).
    public static func wait(time: Double?, text: String?, textGone: String?,
                            timeout: Double?) throws -> AgentCommand {
        if time == nil, text == nil, textGone == nil {
            throw AgentError.invalid("browser_wait_for needs time, text or textGone")
        }
        if text != nil, textGone != nil {
            throw AgentError.invalid("wait for text OR textGone, not both")
        }
        if let time, time < 0 { throw AgentError.invalid("time must be positive") }
        let budget = timeout ?? defaultWaitTimeout
        guard budget > 0 else { throw AgentError.invalid("timeout must be positive") }
        let worst = (time ?? 0) + (text != nil || textGone != nil ? budget : 0)
        guard worst <= maxWait else {
            throw AgentError.invalid("time + timeout must stay within \(Int(maxWait)) s (asked \(worst) s)")
        }
        return .waitFor(time: time, text: text, textGone: textGone, timeout: budget)
    }

    /// A target: a ref or a selector, never empty.
    public static func target(_ raw: String?, element: String?) throws -> AgentTarget {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw AgentError.invalid("target is required: a ref from browser_snapshot (e12) or a CSS selector")
        }
        return AgentTarget(target: text, element: element)
    }
}
