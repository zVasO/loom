import CoreGraphics
import Dispatch
import Foundation
import LoomChromium

// browser_run_code on the Chromium engine (run-code design §1.2, §3, §5).
//
// The agent's `async (page) => { … }` runs in ChromiumRunner's sandbox, in a
// fresh world, with AgentRunnerScript's facade (Playwright's page, locators,
// keyboard, mouse). Every page call reaches Loom through one binding as a
// JSON message (§3.1), is decoded here with its values clamped — nothing the
// facade checked is trusted — and is carried out on the tab that was active
// when the run started, with the tools' own primitives and policies: the
// navigation policy and local-only mode for goto, trusted input after the
// helper's readiness checks for actions, AgentUploadPolicy for files, the
// dialog ledger. Each action settles on its navigation's commit only: no
// network-quiet wait and no snapshot between steps.
//
// Lanes (§3.3) actions run one at a time, in the order they were called;
//              waits (waitFor, waitForURL, waitForLoadState, waitForFunction,
//              waitForTimeout) run beside them, so
//              `Promise.all([page.waitForURL(…), locator.click()])` works;
//              dialog answers and listener changes skip both.
// Caps         56 s of script (the app's 60 s less 4 s to stop, settle and
//              answer), 1 000 calls, 32 in flight, 256 KB a message, 8 MB in
//              all, 256 MB of heap.
// Dialogs      with a page.on('dialog') listener, pushed to the script and
//              answered by it; without one, the run stops and the answer
//              shows ### Modal state.
// The answer   ### Error (first, and isError), ### Result (the value as JSON),
//              ### Script output, then the core's own sections and — unless
//              snapshot "none" — the page's snapshot.
//
// The core's state is private to ChromiumAgentCore.swift: what this needs of
// it (the active page, the answer's sections, the activity pill, the
// session's width) comes in a ChromiumRunHost, made by `execute`'s
// `.runCode` case.

// MARK: - What the core hands over

/// The core's private parts browser_run_code uses, as `execute` hands them
/// over. Its closures are the core's own (actor-isolated): called from the
/// core only.
struct ChromiumRunHost {
    var options: AgentCommandOptions
    var environment: AgentBrowser.Environment
    /// The active tab's page, brought back if it was released or crashed; a
    /// new tab on about:blank when there is none.
    var page: (ContinuousClock.Instant) async throws -> ChromiumTabRuntime
    /// The usual answer for that page: `### Result` (as given), ### Page,
    /// ### Open tabs, ### Modal state, ### Snapshot, ### Events.
    var respond: (String?, ChromiumTabRuntime, String?) -> AgentResult
    /// The panel's pill: what the script is doing.
    var activity: (String) -> Void
    /// `page.setViewportSize`: the session's width, as browser_resize sets it.
    var resize: (ViewportWidth) async -> Void
}

// MARK: - Limits

/// browser_run_code's bounds (run-code design §3.1, §6). Times in
/// milliseconds are those the facade sends.
public struct AgentRunLimits: Equatable, Sendable {
    /// The script's time: the app's deadline less `endReserve`.
    public var scriptTime: Duration = .seconds(56)
    /// What ends the call after the script: the stop, the final settle, the snapshot, the answer.
    public var endReserve: Duration = .seconds(4)
    public var actionTimeout = 5_000
    public var navigationTimeout = 30_000
    /// A call's own timeout, at most (the run's end bounds it anyway).
    public var maxTimeout = 60_000
    public var maxDelay = 1_000
    public var maxMoveSteps = 100
    public var maxText = 100_000
    public var maxPaths = 32
    public var maxOptions = 100
    /// A locator as the helper takes it (its own limit too).
    public var maxTargetBytes = 16_384
    /// Page calls per run.
    public var maxSteps = 1_000
    public var maxInFlight = 32
    /// One message through the binding, checked before it is parsed.
    public var maxMessageBytes = 262_144
    /// Calls and replies of one run, together.
    public var maxTransferBytes = 8_388_608
    public var maxScreenshots = 5
    public var heapCapBytes = 268_435_456
    /// Runs on one runner target before it is made again (each leaves a world).
    public var recycleAfterRuns = 32
    public var idleDispose: Duration = .seconds(300)
    /// The facade's console buffer.
    public var consoleLines = 200
    public var consoleChars = 8_000
    /// The steps an error lists before it.
    public var stepsShown = 5

    public init() {}
}

// MARK: - The agent's code

/// How the agent's code is wrapped, and how its lines are found again.
public enum AgentRunSource {

    public static let sourceURL = "browser_run_code.js"

    /// The expression evaluated in the run's world (the facade's
    /// `AgentRunnerScript.entry`): line 0 opens the call, the agent's code
    /// starts on line 1 — a stack's `browser_run_code.js:L` is the agent's
    /// line L − 1. A function (`async (page) => {…}`) is passed as it is;
    /// anything else is the body of one.
    public static func expression(code: String) -> String {
        AgentRunnerScript.entry(code: code)
    }

    /// The agent's line in a stack: its first `browser_run_code.js:L:C` frame
    /// is line L − 1.
    public static func agentLine(stack: String) -> Int? {
        guard let range = stack.range(of: #"browser_run_code\.js:\d+:\d+"#, options: .regularExpression) else {
            return nil
        }
        let parts = stack[range].split(separator: ":")
        guard parts.count >= 3, let line = Int(parts[parts.count - 2]), line >= 2 else { return nil }
        return line - 1
    }

    /// A SyntaxError's `exceptionDetails.lineNumber` (0-based in the
    /// expression) is the agent's 1-based line.
    public static func agentLine(exceptionLine: Int) -> Int? {
        exceptionLine >= 1 ? exceptionLine : nil
    }
}

// MARK: - The bridge's messages

/// A target as the helper takes it: a locator `{chain, desc, strict}` —
/// forwarded as it came; Loom checks its size only (the helper its shape).
public struct AgentRunTarget: Equatable, @unchecked Sendable {
    /// `[String: Any]` from the message, as `ChromiumHelper.json` writes it back.
    public let value: Any
    /// Its JSON, for the size check and equality.
    public let json: String
    /// Playwright's words for it: `getByRole('button', { name: 'Save' })`.
    public let desc: String
    public let strict: Bool

    public static func == (lhs: AgentRunTarget, rhs: AgentRunTarget) -> Bool {
        lhs.json == rhs.json && lhs.desc == rhs.desc && lhs.strict == rhs.strict
    }

    /// A string target (a selector, a ref) as a locator of one step: the
    /// helper parses it (`parseSelector`), strictly unless said otherwise.
    static func selector(_ text: String, strict: Bool) -> AgentRunTarget? {
        let step: [String: Any] = ["selector": text]
        let desc = "locator(" + AgentRunTarget.quoted(text) + ")"
        let value: [String: Any] = ["chain": [step], "desc": desc, "strict": strict]
        guard let json = AgentRunJSON.text(value) else { return nil }
        return AgentRunTarget(value: value, json: json, desc: desc, strict: strict)
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

public struct AgentRunPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// An option of `selectOption`: Playwright's string (value, then label),
/// `{value}`, `{label}` or `{index}`.
public enum AgentRunOption: Equatable, Sendable {
    case text(String)
    case value(String)
    case label(String)
    case index(Int)

    var helperValue: Any {
        switch self {
        case .text(let text): return text
        case .value(let value): return ["value": value] as [String: Any]
        case .label(let label): return ["label": label] as [String: Any]
        case .index(let index): return ["index": index] as [String: Any]
        }
    }
}

/// One page call (run-code design §3.2), its values clamped.
public enum AgentRunOp: Equatable, Sendable {

    public enum WaitUntil: String, Equatable, Sendable {
        case load, domcontentloaded, commit, networkidle
    }

    public enum KeyAction: String, Equatable, Sendable {
        case down, up, press, type, insertText
    }

    public enum MouseAction: String, Equatable, Sendable {
        case move, down, up, click, dblclick, wheel
    }

    public struct Pointer: Equatable, Sendable {
        public var button: MouseButton = .left
        public var clickCount = 1
        public var modifiers: [String] = []
        /// From the element's top-left corner.
        public var position: AgentRunPoint?
        public var force = false
        public var trial = false
        public var delay = 0

        public init() {}
    }

    public enum Lane: Sendable, Equatable {
        /// One at a time, in the order called.
        case action
        /// Beside the actions: read-only polls.
        case wait
        /// At once, never queued: a dialog answer must pass a click blocked on it.
        case immediate
    }

    case goto(url: String, waitUntil: WaitUntil, timeout: Int?)
    /// -1 back, 1 forward, 0 reload.
    case history(delta: Int, waitUntil: WaitUntil, timeout: Int?)
    case title
    case content
    case click(AgentRunTarget, Pointer, timeout: Int?)
    case hover(AgentRunTarget, Pointer, timeout: Int?)
    case fill(AgentRunTarget, value: String, timeout: Int?)
    case type(AgentRunTarget?, text: String, delay: Int, timeout: Int?)
    case press(AgentRunTarget?, key: String, delay: Int, timeout: Int?)
    case check(AgentRunTarget, checked: Bool, Pointer, timeout: Int?)
    case select(AgentRunTarget, options: [AgentRunOption], timeout: Int?)
    case focus(AgentRunTarget, timeout: Int?)
    case blur(AgentRunTarget, timeout: Int?)
    case scroll(AgentRunTarget, timeout: Int?)
    case files(AgentRunTarget, paths: [String], timeout: Int?)
    case read(AgentRunTarget, what: String, name: String?, timeout: Int?)
    case state(AgentRunTarget, what: String)
    case count(AgentRunTarget)
    case readAll(AgentRunTarget, what: String, name: String?)
    case aria(AgentRunTarget?, timeout: Int?)
    /// `argument`: JSON text, or `undefined`.
    case evaluate(function: String, argument: String, target: AgentRunTarget?, all: Bool)
    case waitState(AgentRunTarget, state: String, timeout: Int?)
    case waitLoad(WaitUntil, timeout: Int?)
    case nextURL(since: String, timeout: Int?)
    case waitFunction(function: String, argument: String, polling: Int, timeout: Int?)
    case sleep(milliseconds: Int)
    case key(KeyAction, key: String?, text: String?, delay: Int)
    case mouse(MouseAction, x: Double?, y: Double?, button: MouseButton, clickCount: Int, steps: Int,
               deltaX: Double, deltaY: Double, delay: Int)
    case viewport(width: Int, height: Int?)
    case screenshot(AgentRunTarget?, fullPage: Bool, format: ImageFormat)
    case dialog(id: Int, accept: Bool, promptText: String?)
    case listen(dialog: Bool)

    public var lane: Lane {
        switch self {
        case .waitState, .waitLoad, .nextURL, .waitFunction, .sleep: return .wait
        case .dialog, .listen: return .immediate
        default: return .action
        }
    }

    var target: AgentRunTarget? {
        switch self {
        case .click(let target, _, _), .hover(let target, _, _), .fill(let target, _, _), .check(let target, _, _, _),
             .select(let target, _, _), .focus(let target, _), .blur(let target, _), .scroll(let target, _),
             .files(let target, _, _), .read(let target, _, _, _), .state(let target, _), .count(let target),
             .readAll(let target, _, _), .waitState(let target, _, _):
            return target
        case .type(let target, _, _, _), .press(let target, _, _, _), .aria(let target, _),
             .evaluate(_, _, let target, _), .screenshot(let target, _, _):
            return target
        default:
            return nil
        }
    }

    /// Playwright's name for the call, as its errors start ("locator.click").
    public var api: String {
        let owner = target == nil ? "page" : "locator"
        switch self {
        case .goto: return "page.goto"
        case .history(let delta, _, _): return delta < 0 ? "page.goBack" : (delta > 0 ? "page.goForward" : "page.reload")
        case .title: return "page.title"
        case .content: return "page.content"
        case .click(_, let pointer, _): return pointer.clickCount == 2 ? "locator.dblclick" : "locator.click"
        case .hover: return "locator.hover"
        case .fill: return "locator.fill"
        case .type: return owner + ".pressSequentially"
        case .press: return owner + ".press"
        case .check(_, let checked, _, _): return checked ? "locator.check" : "locator.uncheck"
        case .select: return "locator.selectOption"
        case .focus: return "locator.focus"
        case .blur: return "locator.blur"
        case .scroll: return "locator.scrollIntoViewIfNeeded"
        case .files: return "locator.setInputFiles"
        case .read(_, let what, _, _): return "locator." + what
        case .state(_, let what): return "locator.is" + what.prefix(1).uppercased() + String(what.dropFirst())
        case .count: return "locator.count"
        case .readAll(_, let what, _): return what == "innerText" ? "locator.allInnerTexts" : "locator.allTextContents"
        case .aria: return owner + ".ariaSnapshot"
        case .evaluate(_, _, _, let all): return all ? "locator.evaluateAll" : owner + ".evaluate"
        case .waitState: return "locator.waitFor"
        case .waitLoad: return "page.waitForLoadState"
        case .nextURL: return "page.waitForURL"
        case .waitFunction: return "page.waitForFunction"
        case .sleep: return "page.waitForTimeout"
        case .key(let action, _, _, _): return "keyboard." + action.rawValue
        case .mouse(let action, _, _, _, _, _, _, _, _): return "mouse." + action.rawValue
        case .viewport: return "page.setViewportSize"
        case .screenshot: return owner + ".screenshot"
        case .dialog(_, let accept, _): return accept ? "dialog.accept" : "dialog.dismiss"
        case .listen: return "page.on"
        }
    }

    /// What the pill and an error's steps say: "click getByRole('button', { name: 'Save' })".
    public var summary: String {
        switch self {
        case .goto(let url, _, _): return "goto " + AgentRunOp.short(url)
        case .key(_, let key, let text, _): return api + " " + AgentRunOp.short(key ?? text ?? "")
        case .press(let target, let key, _, _): return "press " + key + (target.map { " on " + $0.desc } ?? "")
        case .mouse(_, let x, let y, _, _, _, _, _, _):
            guard let x, let y else { return api }
            return api + " \(Int(x)),\(Int(y))"
        default:
            let name = api.split(separator: ".").last.map(String.init) ?? api
            guard let target else { return name }
            return name + " " + target.desc
        }
    }

    static func short(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

/// What a call failed with, as the facade throws it (`TimeoutError` or `Error`).
public struct AgentRunFailure: Error, Equatable, Sendable {
    public var name: String
    public var message: String

    public init(name: String = "Error", message: String) {
        self.name = name
        self.message = message
    }
}

/// One message from the facade, decoded.
public struct AgentRunCall: Equatable, Sendable {
    public var id: Int
    /// The agent's line that made the call, when the facade found it.
    public var line: Int?
    public var op: AgentRunOp
    /// The facade's own name for the call ("locator.click"), else the op's.
    public var api: String
    /// The facade's step number (`step`): every message of one call carries
    /// the same (waitForURL posts nextURL, then waitLoad), and counts once.
    public var step: Int? = nil
}

public enum AgentRunDecoded: Equatable, Sendable {
    case call(AgentRunCall)
    /// Answered at once with the failure — or dropped, with no id to answer.
    case refused(id: Int?, AgentRunFailure)
}

extension AgentRunCall {

    /// A binding payload: at most `maxMessageBytes` (checked before it is
    /// parsed), a JSON object `{id, op, line?, api?, target?, args?, …}` —
    /// each field read from `args`, then from the message itself — every
    /// value clamped. Never throws: what cannot be decoded is refused.
    public static func decode(_ payload: String, limits: AgentRunLimits = AgentRunLimits()) -> AgentRunDecoded {
        guard payload.utf8.count <= limits.maxMessageBytes else {
            return .refused(id: nil, AgentRunFailure(message: "a page call is \(limits.maxMessageBytes / 1_024) KB at most"))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let message = parsed as? [String: Any] else {
            return .refused(id: nil, AgentRunFailure(message: "a page call is a JSON object"))
        }
        guard let rawId = message["id"] as? Double, rawId.isFinite, rawId >= 0, rawId < 1e12 else {
            return .refused(id: nil, AgentRunFailure(message: "a page call needs an id"))
        }
        let id = Int(rawId)
        guard let name = message["op"] as? String else {
            return .refused(id: id, AgentRunFailure(message: "a page call needs an op"))
        }
        let fields = Fields(top: message, args: message["args"] as? [String: Any] ?? [:], limits: limits)
        do {
            let op = try decodeOp(name, fields, limits: limits)
            let line = fields.int("line").flatMap { $0 > 0 ? $0 : nil }
            let api = (message["api"] as? String).flatMap { $0.isEmpty || $0.count > 80 ? nil : $0 } ?? op.api
            var decoded = AgentRunCall(id: id, line: line, op: op, api: api)
            if let rawStep = message["step"] as? Double, rawStep.isFinite, rawStep >= 1, rawStep < 1e9 {
                decoded.step = Int(rawStep)
            }
            return .call(decoded)
        } catch let failure as AgentRunFailure {
            return .refused(id: id, failure)
        } catch {
            return .refused(id: id, AgentRunFailure(message: "\(error)"))
        }
    }

    /// A message's fields: `args` first, then the message itself.
    private struct Fields {
        let top: [String: Any]
        let args: [String: Any]
        let limits: AgentRunLimits

        subscript(_ key: String) -> Any? {
            if let value = args[key], !(value is NSNull) { return value }
            if let value = top[key], !(value is NSNull) { return value }
            return nil
        }

        func string(_ key: String) -> String? {
            (self[key] as? String).map { $0.count > limits.maxText ? String($0.prefix(limits.maxText)) : $0 }
        }

        func double(_ key: String) -> Double? {
            guard let number = self[key] as? Double, number.isFinite else { return nil }
            return number
        }

        func int(_ key: String) -> Int? {
            double(key).map { Int(max(-1e12, min(1e12, $0)).rounded()) }
        }

        func bool(_ key: String) -> Bool? {
            self[key] as? Bool
        }

        func clamped(_ key: String, _ range: ClosedRange<Int>, default fallback: Int) -> Int {
            min(range.upperBound, max(range.lowerBound, int(key) ?? fallback))
        }

        /// What is left of a call's time, in ms (the facade's `timeout`).
        var timeout: Int? {
            int("timeout").map { min(limits.maxTimeout, max(0, $0)) }
        }

        var delay: Int {
            clamped("delay", 0...limits.maxDelay, default: 0)
        }

        func point(_ key: String) -> AgentRunPoint? {
            guard let raw = self[key] as? [String: Any], let x = raw["x"] as? Double, let y = raw["y"] as? Double,
                  x.isFinite, y.isFinite else { return nil }
            return AgentRunPoint(x: x, y: y)
        }

        func waitUntil(_ key: String = "waitUntil") throws -> AgentRunOp.WaitUntil {
            guard let raw = string(key) else { return .load }
            guard let value = AgentRunOp.WaitUntil(rawValue: raw.lowercased()) else {
                throw AgentRunFailure(message: "waitUntil is load, domcontentloaded, networkidle or commit, not \(raw)")
            }
            return value
        }

        func button() throws -> MouseButton {
            guard let raw = string("button") else { return .left }
            guard let button = MouseButton(rawValue: raw) else {
                throw AgentRunFailure(message: "button is left, right or middle, not \(raw)")
            }
            return button
        }

        /// The target, required or not: a locator object, or a selector string.
        func target(required: Bool) throws -> AgentRunTarget? {
            guard let raw = self["target"] else {
                if required { throw AgentRunFailure(message: "this call needs a locator") }
                return nil
            }
            if let text = raw as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.utf8.count <= limits.maxTargetBytes,
                      let target = AgentRunTarget.selector(trimmed, strict: bool("strict") ?? true) else {
                    throw AgentRunFailure(message: "a selector is 1 to \(limits.maxTargetBytes) bytes")
                }
                return target
            }
            guard let object = raw as? [String: Any], object["chain"] is [Any] else {
                throw AgentRunFailure(message: "a locator is {chain, desc, strict}")
            }
            guard let json = AgentRunJSON.text(object), json.utf8.count <= limits.maxTargetBytes else {
                throw AgentRunFailure(message: "a locator is \(limits.maxTargetBytes / 1_024) KB at most")
            }
            let desc = (object["desc"] as? String).map { String($0.prefix(1_000)) } ?? "locator"
            return AgentRunTarget(value: object, json: json, desc: desc, strict: object["strict"] as? Bool ?? true)
        }

        func required(_ key: String) throws -> String {
            guard let value = string(key) else { throw AgentRunFailure(message: "\(key) is required") }
            return value
        }

        func pointer(clickCount fallback: Int = 1) throws -> AgentRunOp.Pointer {
            var pointer = AgentRunOp.Pointer()
            pointer.button = try button()
            pointer.clickCount = clamped("clickCount", 1...3, default: fallback)
            pointer.modifiers = (self["modifiers"] as? [Any] ?? []).compactMap { $0 as? String }
                .filter { ["Alt", "Control", "ControlOrMeta", "Meta", "Shift"].contains($0) }
            pointer.position = point("position")
            pointer.force = bool("force") ?? false
            pointer.trial = bool("trial") ?? false
            pointer.delay = delay
            return pointer
        }

        /// A JSON argument, as JSON text; `undefined` when absent. An explicit
        /// `null` (`page.evaluate(fn, null)`: the facade sends `"arg":null`)
        /// stays null, as Playwright passes it.
        func argument(_ key: String = "arg") -> String {
            if args[key] is NSNull { return "null" }
            guard let value = self[key] else { return "undefined" }
            return AgentRunJSON.text(value) ?? "undefined"
        }
    }

    private static func decodeOp(_ name: String, _ f: Fields, limits: AgentRunLimits) throws -> AgentRunOp {
        switch name {
        case "goto":
            return .goto(url: try f.required("url"), waitUntil: try f.waitUntil(), timeout: f.timeout)
        case "history", "goBack", "goForward", "reload":
            let delta: Int
            switch name {
            case "goBack": delta = -1
            case "goForward": delta = 1
            case "reload": delta = 0
            default: delta = (f.int("delta") ?? 0).signum()
            }
            return .history(delta: delta, waitUntil: try f.waitUntil(), timeout: f.timeout)
        case "title":
            return .title
        case "content":
            return .content
        case "click", "dblclick":
            let target = try f.target(required: true)!
            return .click(target, try f.pointer(clickCount: name == "dblclick" ? 2 : 1), timeout: f.timeout)
        case "hover":
            return .hover(try f.target(required: true)!, try f.pointer(), timeout: f.timeout)
        case "fill":
            return .fill(try f.target(required: true)!, value: f.string("value") ?? "", timeout: f.timeout)
        case "type":
            return .type(try f.target(required: false), text: try f.required("text"), delay: f.delay, timeout: f.timeout)
        case "press":
            return .press(try f.target(required: false), key: try f.required("key"), delay: f.delay, timeout: f.timeout)
        case "check", "uncheck", "setChecked":
            let checked = name == "uncheck" ? false : (f.bool("checked") ?? true)
            return .check(try f.target(required: true)!, checked: checked, try f.pointer(), timeout: f.timeout)
        case "select":
            let raw = (f["options"] ?? f["values"]) as? [Any] ?? []
            guard raw.count <= limits.maxOptions else {
                throw AgentRunFailure(message: "selectOption takes \(limits.maxOptions) options at most")
            }
            let options: [AgentRunOption] = try raw.map { (item: Any) throws -> AgentRunOption in
                if let text = item as? String { return .text(text) }
                if let object = item as? [String: Any] {
                    if let value = object["value"] as? String { return .value(value) }
                    if let label = object["label"] as? String { return .label(label) }
                    if let index = object["index"] as? Double, index.isFinite, index >= 0 { return .index(Int(index)) }
                }
                throw AgentRunFailure(message: "an option is a string, {value}, {label} or {index}")
            }
            return .select(try f.target(required: true)!, options: options, timeout: f.timeout)
        case "focus":
            return .focus(try f.target(required: true)!, timeout: f.timeout)
        case "blur":
            return .blur(try f.target(required: true)!, timeout: f.timeout)
        case "scroll":
            return .scroll(try f.target(required: true)!, timeout: f.timeout)
        case "files":
            let paths = (f["paths"] as? [Any] ?? []).compactMap { $0 as? String }
            guard paths.count <= limits.maxPaths else {
                throw AgentRunFailure(message: "setInputFiles takes \(limits.maxPaths) files at most")
            }
            return .files(try f.target(required: true)!, paths: paths, timeout: f.timeout)
        case "read":
            return .read(try f.target(required: true)!, what: try f.required("what"), name: f.string("name"),
                         timeout: f.timeout)
        case "state":
            return .state(try f.target(required: true)!, what: try f.required("what"))
        case "count":
            return .count(try f.target(required: true)!)
        case "readAll":
            return .readAll(try f.target(required: true)!, what: try f.required("what"), name: f.string("name"))
        case "aria":
            return .aria(try f.target(required: false), timeout: f.timeout)
        case "eval":
            let function = try f.required("fn")
            return .evaluate(function: function, argument: f.argument(), target: try f.target(required: false),
                             all: f.bool("all") ?? false)
        case "waitState":
            let state = f.string("state") ?? "visible"
            guard ["attached", "detached", "visible", "hidden"].contains(state) else {
                throw AgentRunFailure(message: "state is attached, detached, visible or hidden, not \(state)")
            }
            return .waitState(try f.target(required: true)!, state: state, timeout: f.timeout)
        case "waitLoad":
            return .waitLoad(try f.waitUntil("state"), timeout: f.timeout)
        case "nextURL":
            return .nextURL(since: f.string("since") ?? "", timeout: f.timeout)
        case "waitFn":
            let polling: Int
            if f.string("polling") == "raf" {
                polling = 16
            } else {
                polling = f.clamped("polling", 16...10_000, default: 100)
            }
            return .waitFunction(function: try f.required("fn"), argument: f.argument(), polling: polling,
                                 timeout: f.timeout)
        case "sleep":
            return .sleep(milliseconds: f.clamped("ms", 0...limits.maxTimeout, default: 0))
        case "key":
            let raw = f.string("action") ?? "press"
            guard let action = AgentRunOp.KeyAction(rawValue: raw) else {
                throw AgentRunFailure(message: "keyboard's action is down, up, press, type or insertText, not \(raw)")
            }
            let key = f.string("key")
            let text = f.string("text")
            if action == .type || action == .insertText {
                guard text != nil else { throw AgentRunFailure(message: "text is required") }
            } else if key == nil {
                throw AgentRunFailure(message: "key is required")
            }
            return .key(action, key: key, text: text, delay: f.delay)
        case "mouse":
            let raw = f.string("action") ?? "move"
            guard let action = AgentRunOp.MouseAction(rawValue: raw) else {
                throw AgentRunFailure(message: "mouse's action is move, down, up, click, dblclick or wheel, not \(raw)")
            }
            let x = f.double("x")
            let y = f.double("y")
            if [AgentRunOp.MouseAction.move, .click, .dblclick].contains(action), x == nil || y == nil {
                throw AgentRunFailure(message: "mouse.\(raw) needs x and y")
            }
            return .mouse(action, x: x, y: y, button: try f.button(),
                          clickCount: f.clamped("clickCount", 1...3, default: action == .dblclick ? 2 : 1),
                          steps: f.clamped("steps", 1...limits.maxMoveSteps, default: 1),
                          deltaX: f.double("dx") ?? f.double("deltaX") ?? 0, deltaY: f.double("dy") ?? f.double("deltaY") ?? 0,
                          delay: f.delay)
        case "viewport":
            guard let width = f.int("width") else { throw AgentRunFailure(message: "width is required") }
            guard ViewportWidth.range.contains(width) else {
                throw AgentRunFailure(message: "width is \(ViewportWidth.range.lowerBound) to \(ViewportWidth.range.upperBound) CSS pixels")
            }
            let height = f.int("height").map { min(16_384, max(1, $0)) }
            return .viewport(width: width, height: height)
        case "shot":
            let format: ImageFormat = f.string("type") == "jpeg" ? .jpeg : .png
            return .screenshot(try f.target(required: false), fullPage: f.bool("fullPage") ?? false, format: format)
        case "dialog":
            guard let dialogId = f.int("id") ?? f.int("dialogId") else {
                throw AgentRunFailure(message: "dialog needs its id")
            }
            return .dialog(id: dialogId, accept: f.bool("accept") ?? true, promptText: f.string("promptText"))
        case "listen":
            return .listen(dialog: f.bool("dialog") ?? false)
        default:
            throw AgentRunFailure(message: "unknown page call \(AgentRunOp.short(name))")
        }
    }
}

/// A page call's answer, as the facade reads it (`__loomRun.reply`).
public struct AgentRunReply: Equatable, Sendable {
    public var id: Int
    public var ok: Bool
    /// JSON text; nil (or `undefined`) for no value.
    public var value: String?
    public var error: AgentRunFailure?
    /// The page's main-frame URL: `page.url()` is synchronous in the facade.
    public var url: String?

    public init(id: Int, ok: Bool, value: String? = nil, error: AgentRunFailure? = nil, url: String? = nil) {
        self.id = id
        self.ok = ok
        self.value = value
        self.error = error
        self.url = url
    }

    public var json: String {
        var text = "{\"id\":\(id),\"ok\":\(ok ? "true" : "false")"
        if let value, value != "undefined" { text += ",\"value\":" + value }
        if let error {
            text += ",\"error\":{\"name\":" + ChromiumTabRuntime.jsString(error.name)
                + ",\"message\":" + ChromiumTabRuntime.jsString(error.message) + "}"
        }
        if let url { text += ",\"url\":" + ChromiumTabRuntime.jsString(url) }
        return text + "}"
    }
}

/// JSON text from JSONSerialization values, fragments included — never an
/// Objective-C exception: an invalid value (NaN) is nil.
enum AgentRunJSON {
    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        let wrapped: [Any] = [value]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - The answer

/// What a run answers, before the page's own sections (run-code design §3.5).
public struct AgentRunReport: Equatable, Sendable {
    /// The script's error, a SyntaxError or why it was stopped.
    public var error: String?
    /// The last steps before the error: "6) click getByRole('button')".
    public var steps: [String] = []
    /// The function's value as JSON text; nil for `undefined`.
    public var value: String?
    public var output: [String] = []
    public var outputDropped = 0
    /// Calls still pending when the function returned.
    public var unfinished: [String] = []
    /// Nothing ran: no snapshot is taken.
    public var syntaxError = false

    public init() {}

    public var isError: Bool { error != nil }

    public var errorSection: String? {
        guard let error else { return nil }
        var text = "### Error\n" + error
        if !steps.isEmpty { text += "\nSteps before it: " + steps.joined(separator: " ") }
        return text
    }

    /// The value as browser_evaluate shows it, cut at `limit` characters.
    public func resultBody(limit: Int) -> String? {
        guard let value, value != "undefined" else { return nil }
        let head = value.prefix(limit)
        let shown = head.endIndex == value.endIndex ? value : String(head) + "\n… (cut at \(limit) characters)"
        return "```json\n" + shown + "\n```"
    }

    public func outputSection(limit: Int = AgentRunLimits().consoleChars) -> String? {
        guard !output.isEmpty || outputDropped > 0 else { return nil }
        var lines: [String] = []
        var used = 0
        var dropped = outputDropped
        for (index, line) in output.enumerated() {
            if used + line.count > limit {
                dropped += output.count - index
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        if dropped > 0 { lines.append("… (\(dropped) more line\(dropped == 1 ? "" : "s"))") }
        return "### Script output\n" + lines.joined(separator: "\n")
    }

    /// For `### Events`.
    public var unfinishedNote: String? {
        guard !unfinished.isEmpty else { return nil }
        let count = unfinished.count
        let shown = unfinished.prefix(10).joined(separator: ", ") + (count > 10 ? ", …" : "")
        return "\(count) page call\(count == 1 ? " was" : "s were") still running when your function returned "
            + "(missing await?): " + shown
    }

    /// What comes before the page's sections, and what the core's builder
    /// shows as `### Result` (the value, then the output when there is a
    /// value): ### Error, ### Result, ### Script output, in that order.
    public func sections(resultLimit: Int) -> (prefix: [String], result: String?) {
        var prefix: [String] = []
        if let errorSection { prefix.append(errorSection) }
        var result = resultBody(limit: resultLimit)
        if let output = outputSection() {
            if let body = result {
                result = body + "\n\n" + output
            } else {
                prefix.append(output)
            }
        }
        return (prefix, result)
    }

    /// The whole answer: the prefix, then the page's sections.
    public static func compose(prefix: [String], page: String) -> String {
        (prefix + (page.isEmpty ? [] : [page])).joined(separator: "\n\n")
    }
}

// MARK: - A run's state

/// Why a run was stopped before its function returned.
enum ChromiumRunStop: Sendable, Equatable {
    case deadline
    case steps
    case flood
    case transfer
    case oversize
    case memory
    case dialog(PageDialog)
    case runnerGone(String)
}

enum ChromiumRunEvent: Sendable {
    /// A binding payload, unparsed.
    case call(String)
    /// The evaluation answered (its raw result), or failed.
    case finished(CDPObject?, String?)
    case stop(ChromiumRunStop)
    case dialog(PageDialog)
}

/// A timeout of one call, in Playwright's words.
struct ChromiumRunTimeout: Error {
    var api: String
    var milliseconds: Int
    var waiting: String?
    var reason: String?

    var message: String {
        var text = "\(api): Timeout \(milliseconds)ms exceeded."
        var log: [String] = []
        if let waiting { log.append("  - " + waiting) }
        if let reason { log.append("  - " + reason) }
        if !log.isEmpty { text += "\nCall log:\n" + log.joined(separator: "\n") }
        return text
    }
}

/// An action whose dialog the script's page.on('dialog') handler did not
/// answer within the action's time: a TimeoutError, as Playwright's click
/// that "never finishes" while its dialog waits.
struct ChromiumRunDialogWait: Error {
    var dialog: PageDialog
}

/// One run's state: touched on the core actor only.
final class ChromiumRunState: @unchecked Sendable {
    let page: ChromiumTabRuntime
    let host: ChromiumRunHost
    let runner: ChromiumRunner
    let world: ChromiumRunWorld
    let limits: AgentRunLimits
    let started = ContinuousClock.now
    let scriptEnd: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let events: AsyncStream<ChromiumRunEvent>.Continuation

    var ended = false
    var steps = 0
    /// The facade's step numbers counted already (AgentRunCall.step).
    var countedSteps: Set<Int> = []
    var messages = 0
    var transferred = 0
    var inFlight = 0
    var recent: [String] = []
    var lastLine: Int?
    var dialogListener = false
    var dialogsSent: Set<Int> = []
    var actionTail: Task<Void, Never>?
    var tasks: [Task<Void, Never>] = []
    var heldModifiers: CDPModifiers = []
    var mouse = AgentRunPoint(x: 0, y: 0)
    var buttons: CDPMouseButtons = []
    var image: AgentImage?
    var screenshots = 0
    var pageEvaluations = 0
    var lastActivity: ContinuousClock.Instant?

    init(page: ChromiumTabRuntime, host: ChromiumRunHost, runner: ChromiumRunner, world: ChromiumRunWorld,
         limits: AgentRunLimits, scriptEnd: ContinuousClock.Instant, deadline: ContinuousClock.Instant,
         events: AsyncStream<ChromiumRunEvent>.Continuation) {
        self.page = page
        self.host = host
        self.runner = runner
        self.world = world
        self.limits = limits
        self.scriptEnd = scriptEnd
        self.deadline = deadline
        self.events = events
    }
}

// MARK: - The run

extension ChromiumAgentCore {

    /// browser_run_code: the agent's code in the session's runner, its page
    /// calls on the tab active now, then the answer (run-code design §1.2).
    func runCode(_ code: String, deadline: ContinuousClock.Instant, host: ChromiumRunHost) async throws -> AgentResult {
        let limits = AgentRunLimits()
        let scriptEnd = min(deadline - limits.endReserve, ContinuousClock.now + limits.scriptTime)
        guard ContinuousClock.now < scriptEnd - .seconds(1) else {
            throw AgentError.timeout("too little time was left to run the script")
        }
        let page = try await host.page(deadline)
        try Self.refuseWhileDialog(page)
        host.activity("Running code")

        let runner = ChromiumRunner.runner(for: control, browser: page.browser, limits: limits)
        let world: ChromiumRunWorld
        do {
            world = try await runner.open(deadline: min(scriptEnd, ContinuousClock.now + .seconds(10)))
        } catch {
            try Self.rethrowCancellation(error)
            runner.finished()
            throw AgentError.unavailable("browser_run_code's sandbox could not start: \(Self.message(of: error))")
        }

        let (events, continuation) = AsyncStream<ChromiumRunEvent>.makeStream()
        let run = ChromiumRunState(page: page, host: host, runner: runner, world: world, limits: limits,
                                   scriptEnd: scriptEnd, deadline: deadline, events: continuation)
        runner.route(world, onCall: { payload in continuation.yield(.call(payload)) },
                     onEnd: { reason in continuation.yield(.stop(.runnerGone(reason))) })

        // The facade, started with what it knows of the page.
        do {
            let config = Self.runConfig(run, valueChars: host.environment.limits.evaluateChars)
            let installed = try await runner.evaluate(ChromiumRunner.installExpression(config: config),
                                                      contextId: world.contextId, awaitPromise: false,
                                                      deadline: min(scriptEnd, ContinuousClock.now + .seconds(5)))
            if let exception = installed.object("exceptionDetails") {
                throw AgentError.failed("browser_run_code's library could not start: " + ChromiumHelper.describe(exception))
            }
        } catch {
            continuation.finish()
            runner.unroute()
            await runner.stop()
            runner.finished()
            try Self.rethrowCancellation(error)
            throw (error as? AgentError) ?? AgentError.unavailable("browser_run_code's sandbox failed: \(Self.message(of: error))")
        }

        // The agent's function; its answer ends the run.
        let entry = AgentRunSource.expression(code: code)
        let contextId = world.contextId
        let evaluation = Task {
            do {
                let result = try await runner.evaluate(entry, contextId: contextId, awaitPromise: true, deadline: deadline)
                continuation.yield(.finished(result, nil))
            } catch {
                continuation.yield(.finished(nil, Self.message(of: error)))
            }
        }
        let timer = Task {
            do { try await Task.sleep(until: scriptEnd, clock: .continuous) } catch { return }
            continuation.yield(.stop(.deadline))
        }
        let dialogWatch = Task {
            var seen: Set<Int> = []
            while !Task.isCancelled {
                if let dialog = page.dialog, !seen.contains(dialog.id) {
                    seen.insert(dialog.id)
                    continuation.yield(.dialog(dialog))
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
        let heapWatch = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                if let used = await runner.heapUsed(), used > limits.heapCapBytes {
                    continuation.yield(.stop(.memory))
                    return
                }
            }
        }

        var outcome: (result: CDPObject?, failure: String?)?
        var stopped: ChromiumRunStop?
        loop: for await event in events {
            switch event {
            case .call(let payload):
                if let stop = runAdmit(payload, run) {
                    stopped = stop
                    break loop
                }
            case .finished(let result, let failure):
                outcome = (result, failure)
                break loop
            case .stop(let reason):
                stopped = reason
                break loop
            case .dialog(let dialog):
                guard run.page.dialog?.id == dialog.id else { continue }
                if run.dialogListener {
                    runSendDialog(dialog, run)
                } else {
                    stopped = .dialog(dialog)
                    break loop
                }
            }
        }
        let cancelled = Task.isCancelled

        // The end: nothing more is answered; what is pending goes.
        run.ended = true
        runner.unroute()
        continuation.finish()
        timer.cancel()
        dialogWatch.cancel()
        heapWatch.cancel()
        for task in run.tasks { task.cancel() }
        run.actionTail?.cancel()
        if stopped != nil || cancelled || outcome?.result == nil {
            // Stopped, or its evaluation failed: the runner may still be busy.
            evaluation.cancel()
            var runnerGone = false
            if case .runnerGone(_)? = stopped { runnerGone = true }
            if !runnerGone { await runner.stop() }
        }
        runner.finished()
        if run.pageEvaluations > 0 {
            // A page.evaluate still running in the page: stopped with the run.
            page.post("Runtime.terminateExecution")
        }
        await runReleaseInput(run)
        if cancelled { throw CancellationError() }

        var report = AgentRunReport()
        report.steps = Array(run.recent.suffix(limits.stepsShown))
        if let stopped {
            report.error = runStopMessage(stopped, run)
        } else if let outcome {
            runRead(outcome, into: &report)
        }

        // Where the page stands: one turn of its event loop, then its snapshot.
        if !page.blocksPage, !page.isDetached, !page.isCrashed {
            _ = try? await page.barrier(deadline: min(deadline - .milliseconds(1_500),
                                                      ContinuousClock.now + .seconds(1)))
        }
        let pageLimits = host.environment.limits
        var yaml: String?
        if host.options.snapshot == .full, !report.syntaxError, !page.blocksPage, !page.isDetached, !page.isCrashed,
           ContinuousClock.now < deadline - .milliseconds(500) {
            let answer = try? await page.helper("snapshot", ["budget": pageLimits.actionSnapshotChars, "afterFrame": true],
                                                deadline: deadline - .milliseconds(300))
            yaml = answer?.string("yaml")
        }
        if let note = report.unfinishedNote { page.note(note) }

        // The facade cut the value already, its notice after it.
        let (prefix, result) = report.sections(resultLimit: pageLimits.evaluateChars + 64)
        if let body = yaml, !prefix.isEmpty {
            // The builder trims the snapshot to fit its own sections; the
            // prefix comes on top of them.
            let room = max(0, pageLimits.responseChars - prefix.joined(separator: "\n\n").count - 2_000)
            if body.count > room {
                yaml = String(body.prefix(room)) + "\n- … (snapshot cut to fit the answer: call browser_snapshot with a target)"
            }
        }
        var answer = host.respond(result, page, yaml)
        answer.text = AgentRunReport.compose(prefix: prefix, page: answer.text)
        answer.isError = report.isError
        if let image = run.image { answer.image = image }
        return answer
    }

    // MARK: Messages in

    /// One binding payload: the caps, then the call into its lane. A stop
    /// when a cap is passed.
    private func runAdmit(_ payload: String, _ run: ChromiumRunState) -> ChromiumRunStop? {
        let limits = run.limits
        let size = payload.utf8.count
        run.messages += 1
        run.transferred += size
        if size > limits.maxMessageBytes { return .oversize }
        if run.messages > 2 * limits.maxSteps { return .flood }
        if run.transferred > limits.maxTransferBytes { return .transfer }
        let call: AgentRunCall
        switch AgentRunCall.decode(payload, limits: limits) {
        case .refused(let id, let failure):
            if let id { runSend(AgentRunReply(id: id, ok: false, error: failure, url: run.page.url), run) }
            return nil
        case .call(let decoded):
            call = decoded
        }
        let lane = call.op.lane
        if lane != .immediate {
            // One facade call is one step, however many messages it posts
            // (waitForURL: nextURL, then waitLoad) — else a script within the
            // facade's own budget is stopped here. A message without a step
            // counts alone; the flood cap bounds a forged one.
            let fresh = call.step.map { run.countedSteps.insert($0).inserted } ?? true
            if fresh { run.steps += 1 }
            if run.steps > limits.maxSteps { return .steps }
            if run.inFlight >= limits.maxInFlight {
                runSend(AgentRunReply(id: call.id, ok: false, error: AgentRunFailure(
                    message: "more than \(limits.maxInFlight) page calls in flight"), url: run.page.url), run)
                return nil
            }
            if let line = call.line { run.lastLine = line }
            if fresh {
                run.recent.append("\(run.steps)) " + call.op.summary)
                if run.recent.count > limits.stepsShown { run.recent.removeFirst(run.recent.count - limits.stepsShown) }
                let now = ContinuousClock.now
                if run.lastActivity.map({ $0.duration(to: now) >= .milliseconds(100) }) ?? true {
                    run.lastActivity = now
                    run.host.activity("Running code · \(run.steps): " + call.op.summary)
                }
            }
        }
        switch lane {
        case .immediate:
            runImmediate(call, run)
        case .action:
            run.inFlight += 1
            let previous = run.actionTail
            let task = Task {
                await previous?.value
                await self.runCall(call, run)
            }
            run.actionTail = task
            run.tasks.append(task)
        case .wait:
            run.inFlight += 1
            run.tasks.append(Task { await self.runCall(call, run) })
        }
        return nil
    }

    /// A call of the action or wait lane, answered.
    private func runCall(_ call: AgentRunCall, _ run: ChromiumRunState) async {
        defer { run.inFlight -= 1 }
        guard !run.ended, !Task.isCancelled else { return }
        let reply: AgentRunReply
        do {
            let value = try await runOp(call, run)
            reply = AgentRunReply(id: call.id, ok: true, value: value, url: run.page.url)
        } catch {
            if run.ended || Task.isCancelled || error is CancellationError { return }
            reply = AgentRunReply(id: call.id, ok: false, error: Self.runFailure(error, api: call.api),
                                  url: run.page.url)
        }
        runSend(reply, run)
    }

    private func runSend(_ reply: AgentRunReply, _ run: ChromiumRunState) {
        guard !run.ended else { return }
        let json = reply.json
        run.transferred += json.utf8.count
        run.runner.deliver(reply: json, contextId: run.world.contextId)
    }

    private func runImmediate(_ call: AgentRunCall, _ run: ChromiumRunState) {
        switch call.op {
        case .listen(let dialog):
            run.dialogListener = dialog
            runSend(AgentRunReply(id: call.id, ok: true, value: "null", url: run.page.url), run)
            if dialog, let open = run.page.dialog { runSendDialog(open, run) }
        case .dialog(let id, let accept, let promptText):
            switch run.page.answerDialog(accept: accept, promptText: promptText, dialogId: id) {
            case .success:
                runSend(AgentRunReply(id: call.id, ok: true, value: "null", url: run.page.url), run)
            case .failure:
                runSend(AgentRunReply(id: call.id, ok: false, error: AgentRunFailure(
                    message: "Cannot \(accept ? "accept" : "dismiss") dialog which is already handled!"),
                                      url: run.page.url), run)
            }
        default:
            break
        }
    }

    /// The dialog to the script's handlers, once.
    private func runSendDialog(_ dialog: PageDialog, _ run: ChromiumRunState) {
        guard !run.ended, run.dialogsSent.insert(dialog.id).inserted else { return }
        let type = dialog.kind.rawValue
        let json = "{\"event\":\"dialog\",\"dialog\":{\"id\":\(dialog.id),\"type\":" + ChromiumTabRuntime.jsString(type)
            + ",\"message\":" + ChromiumTabRuntime.jsString(dialog.message)
            + ",\"defaultValue\":" + ChromiumTabRuntime.jsString(dialog.defaultPrompt) + "}}"
        run.runner.deliver(event: json, contextId: run.world.contextId)
    }

    // MARK: Ops

    /// One call on the page; its value as JSON text.
    private func runOp(_ call: AgentRunCall, _ run: ChromiumRunState) async throws -> String? {
        let page = run.page
        let api = call.api
        let limits = run.limits
        switch call.op {
        case .goto(let url, let waitUntil, let timeout):
            return try await runGoto(url, waitUntil: waitUntil, timeout: timeout, run, api: api)

        case .history(let delta, let waitUntil, let timeout):
            return try await runHistory(delta, waitUntil: waitUntil, timeout: timeout, run, api: api)

        case .title:
            let info = try await runHelper("pageInfo", [:], run, limit: Self.runLimit(nil, limits.actionTimeout, run).0)
            return AgentRunJSON.text(info.string("title") ?? page.title)

        case .content:
            let raw = try await runPageEvaluate("""
                (() => { const root = document.documentElement; const html = root ? root.outerHTML : "";
                return html.length > 100000 ? html.slice(0, 100000) : html; })()
                """, run, api: api)
            return AgentRunJSON.text(raw)

        case .click(let target, let pointer, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            let point = try await runPoint(target, action: "click", pointer: pointer, run, limit: limit, ms: ms, api: api)
            if pointer.trial { return "null" }
            let flags = Self.modifiers(pointer.modifiers).union(run.heldModifiers)
            let mark = page.mark()
            let outcome = try await runClickAt(point, button: pointer.button, clickCount: pointer.clickCount,
                                               modifiers: flags, delay: pointer.delay, run, limit: limit)
            run.mouse = point
            try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
            return "null"

        case .hover(let target, let pointer, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            let point = try await runPoint(target, action: "hover", pointer: pointer, run, limit: limit, ms: ms, api: api)
            if pointer.trial { return "null" }
            let flags = Self.modifiers(pointer.modifiers).union(run.heldModifiers)
            let mark = page.mark()
            // The pointer stays there: :hover holds until it moves.
            let outcome = try await page.dispatch(batch: [CDPInput.mouseMoved(x: point.x, y: point.y, modifiers: flags,
                                                                                 held: run.buttons)],
                                                  deadline: Self.runCallEnd(limit, run))
            run.mouse = point
            try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
            return "null"

        case .fill(let target, let value, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            let ready = try await runPrepare(target, action: "type", run, limit: limit, ms: ms, api: api, focus: true)
            let mark = page.mark()
            var outcome: ChromiumInputOutcome = .acked
            switch ready.string("fill") ?? "" {
            case "insertText":
                let batch: [(String, [String: Any])] = value.isEmpty ? Self.deleteKey.cdpPress() : [CDPInput.insertText(value)]
                outcome = try await page.dispatch(batch: batch, deadline: Self.runCallEnd(limit, run))
            case "setValue":
                do {
                    _ = try await runHelper("type", ["target": target.value, "text": value, "submit": false], run, limit: limit)
                } catch CDPError.interrupted(let reason) where reason == .dialogOpened || reason == .navigated {
                    outcome = .interrupted(reason)
                }
            default:
                throw AgentError.invalid("Element is not an <input>, <textarea> or [contenteditable] element")
            }
            try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
            return "null"

        case .type(let target, let text, let delay, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            if let target {
                _ = try await runResolving("focus", ["target": target.value], target: target, run, limit: limit, ms: ms, api: api)
            }
            let mark = page.mark()
            var outcome: ChromiumInputOutcome = .acked
            if delay == 0 {
                outcome = try await page.dispatch(writes: KeySpec.cdpTypingWrites(text), deadline: Self.runCallEnd(limit, run))
            } else {
                for character in text {
                    try Self.runCheck(run)
                    outcome = try await page.dispatch(batch: KeySpec.typing(character).cdpTyping(),
                                                      deadline: Self.runCallEnd(limit, run))
                    if outcome != .acked { break }
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
            try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
            return "null"

        case .press(let target, let key, let delay, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            if let target {
                _ = try await runResolving("focus", ["target": target.value], target: target, run, limit: limit, ms: ms, api: api)
            }
            let mark = page.mark()
            let outcome = try await runPressKey(key, delay: delay, run, limit: limit)
            try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
            return "null"

        case .check(let target, let checked, let pointer, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            let before = try await runResolving("read", ["target": target.value, "what": "checked"], target: target,
                                                run, limit: limit, ms: ms, api: api)
            if before.bool("value") == checked { return "null" }
            let point = try await runPoint(target, action: "click", pointer: pointer, run, limit: limit, ms: ms, api: api)
            if pointer.trial { return "null" }
            let mark = page.mark()
            let outcome = try await runClickAt(point, button: .left, clickCount: 1, modifiers: run.heldModifiers, delay: 0,
                                               run, limit: limit)
            run.mouse = point
            try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
            if page.blocksPage { return "null" }
            let after = try await runHelper("read", ["target": target.value, "what": "checked"], run, limit: limit)
            if after.bool("value") != checked {
                throw AgentError.failed("Clicking the checkbox did not change its state")
            }
            return "null"

        case .select(let target, let options, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            _ = try await runPrepare(target, action: "select", run, limit: limit, ms: ms, api: api)
            let mark = page.mark()
            var values: Any = [Any]()
            var outcome: ChromiumInputOutcome = .acked
            do {
                let answer = try await runHelper("selectOption", ["target": target.value,
                                                                  "values": options.map(\.helperValue)],
                                                 run, limit: limit)
                values = answer.raw["values"] ?? [Any]()
            } catch CDPError.interrupted(let reason) where reason == .dialogOpened || reason == .navigated {
                outcome = .interrupted(reason)
            }
            try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
            return AgentRunJSON.text(values) ?? "[]"

        case .focus(let target, let timeout), .blur(let target, let timeout), .scroll(let target, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            let op: String
            switch call.op {
            case .focus: op = "focus"
            case .blur: op = "blur"
            default: op = "rect"
            }
            _ = try await runResolving(op, ["target": target.value], target: target, run, limit: limit, ms: ms, api: api)
            return "null"

        case .files(let target, let paths, let timeout):
            return try await runFiles(target, paths: paths, timeout: timeout, run, api: api)

        case .read(let target, let what, let name, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            var args: [String: Any] = ["target": target.value, "what": what]
            if let name { args["name"] = name }
            let answer = try await runResolving("read", args, target: target, run, limit: limit, ms: ms, api: api)
            return AgentRunJSON.text(answer.raw["value"]) ?? "null"

        case .state(let target, let what):
            let answer = try await runHelper("state", ["target": target.value, "what": what], run,
                                             limit: Self.runLimit(nil, limits.actionTimeout, run).0)
            return AgentRunJSON.text(answer.raw["value"]) ?? "null"

        case .count(let target):
            let answer = try await runHelper("count", ["target": target.value], run,
                                             limit: Self.runLimit(nil, limits.actionTimeout, run).0)
            return String(answer.int("count") ?? 0)

        case .readAll(let target, let what, let name):
            var args: [String: Any] = ["target": target.value, "what": what]
            if let name { args["name"] = name }
            let answer = try await runHelper("readAll", args, run, limit: Self.runLimit(nil, limits.actionTimeout, run).0)
            return AgentRunJSON.text(answer.raw["value"] ?? [Any]()) ?? "[]"

        case .aria(let target, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            var args: [String: Any] = ["noRefs": true, "budget": 20_000]
            let answer: CDPObject
            if let target {
                args["target"] = target.value
                answer = try await runResolving("snapshot", args, target: target, run, limit: limit, ms: ms, api: api)
            } else {
                answer = try await runHelper("snapshot", args, run, limit: limit)
            }
            return AgentRunJSON.text(answer.string("yaml") ?? "") ?? "\"\""

        case .evaluate(let function, let argument, let target, let all):
            var nonce = ""
            if let target {
                let (limit, ms) = Self.runLimit(nil, limits.actionTimeout, run)
                let stamped: CDPObject
                if all {
                    stamped = try await runHelper("stampAll", ["target": target.value], run, limit: limit)
                } else {
                    stamped = try await runResolving("stamp", ["target": target.value], target: target, run,
                                                     limit: limit, ms: ms, api: api)
                }
                nonce = stamped.string("nonce") ?? ""
            }
            let raw = try await runPageEvaluate(Self.runEvaluateExpression(function: function, argument: argument,
                                                                           nonce: nonce, all: all), run, api: api)
            // The serializer's JSON text, as a string: the facade parses it back.
            return AgentRunJSON.text((raw as? String) ?? "undefined")

        case .waitState(let target, let state, let timeout):
            return try await runWaitState(target, state: state, timeout: timeout, run, api: api)

        case .waitLoad(let state, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.navigationTimeout, run)
            try await runLoadState(state, loaderId: nil, mark: nil, run, limit: limit, ms: ms, api: api, what: nil)
            return "null"

        case .nextURL(let since, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.navigationTimeout, run)
            while true {
                try Self.runCheck(run)
                let url = page.url
                if !url.isEmpty, url != since { return AgentRunJSON.text(url) }
                if page.isCrashed || page.isDetached { throw AgentError.unavailable("the page went away") }
                if ContinuousClock.now >= limit {
                    throw ChromiumRunTimeout(api: api, milliseconds: ms, waiting: "waiting for navigation", reason: nil)
                }
                try await Task.sleep(for: .milliseconds(15))
            }

        case .waitFunction(let function, let argument, let polling, let timeout):
            let (limit, ms) = Self.runLimit(timeout, limits.actionTimeout, run)
            let expression = Self.runWaitExpression(function: function, argument: argument)
            while true {
                try Self.runCheck(run)
                if !page.blocksPage {
                    let raw = try await runPageEvaluate(expression, run, api: api)
                    if let value = raw as? String { return AgentRunJSON.text(value) }
                }
                if ContinuousClock.now >= limit {
                    throw ChromiumRunTimeout(api: api, milliseconds: ms, waiting: nil, reason: nil)
                }
                try await Task.sleep(for: .milliseconds(polling))
            }

        case .sleep(let milliseconds):
            let until = min(ContinuousClock.now + .milliseconds(milliseconds), run.scriptEnd)
            try await Task.sleep(until: until, clock: .continuous)
            return "null"

        case .key(let action, let key, let text, let delay):
            return try await runKeyboard(action, key: key, text: text, delay: delay, run)

        case .mouse(let action, let x, let y, let button, let clickCount, let steps, let deltaX, let deltaY, let delay):
            return try await runMouse(action, x: x, y: y, button: button, clickCount: clickCount, steps: steps,
                                      deltaX: deltaX, deltaY: deltaY, delay: delay, run)

        case .viewport(let width, let height):
            await run.host.resize(.css(width))
            if let height {
                try await page.setViewport(cssSize: CGSize(width: width, height: height),
                                           deadline: Self.runCallEnd(ContinuousClock.now + .seconds(2), run))
            }
            return "null"

        case .screenshot(let target, let fullPage, let format):
            return try await runScreenshot(target, fullPage: fullPage, format: format, run, api: api)

        case .dialog, .listen:
            runImmediate(call, run)
            return nil
        }
    }

    // MARK: Navigation

    private func runGoto(_ url: String, waitUntil: AgentRunOp.WaitUntil, timeout: Int?, _ run: ChromiumRunState,
                         api: String) async throws -> String {
        let page = run.page
        let (limit, ms) = Self.runLimit(timeout, run.limits.navigationTimeout, run)
        let address = Self.runResolve(url, against: page.url)
        // The tools' own checks: the address bar's rules and the policy, then
        // local-only, then http(s) and about:blank only.
        let target = try AgentNavigationPolicy.navigationURL(address)
        if AgentNetworkRules.refuses(target, under: control.networkAccess) {
            throw AgentError.invalid("\(target.host() ?? target.absoluteString) is outside local sites only "
                                     + "(Loom's Settings ▸ Agents lists the hosts it lets through)")
        }
        try Self.refuseScheme(target)
        if page.dialog != nil {
            page.dismissDialog()
            page.note("The page's dialog was dismissed by the navigation.")
        }
        page.setAutoAcceptBeforeUnload(true)
        defer { page.setAutoAcceptBeforeUnload(false) }
        let mark = page.mark()
        let waiting = "navigating to \"\(target.absoluteString)\", waiting until \"\(waitUntil.rawValue)\""
        let navigation: ChromiumNavigation
        do {
            navigation = try await page.navigate(to: target.absoluteString, deadline: Self.runCallEnd(limit, run))
        } catch CDPError.timeout {
            throw ChromiumRunTimeout(api: api, milliseconds: ms, waiting: waiting, reason: nil)
        }
        if navigation.isDownload {
            throw AgentError.failed("the address is a download; downloads are refused (\(target.absoluteString))")
        }
        if let errorText = navigation.errorText {
            throw AgentError.failed(Self.loadFailure(errorText: errorText, url: target,
                                                     localOnly: control.networkAccess != .open) ?? errorText)
        }
        guard let loaderId = navigation.loaderId else { return "null" }   // same document: no response
        try await runLoadState(waitUntil, loaderId: loaderId, mark: mark, run, limit: limit, ms: ms, api: api,
                               what: waiting)
        return Self.runResponse(page)
    }

    private func runHistory(_ delta: Int, waitUntil: AgentRunOp.WaitUntil, timeout: Int?, _ run: ChromiumRunState,
                            api: String) async throws -> String {
        let page = run.page
        let (limit, ms) = Self.runLimit(timeout, run.limits.navigationTimeout, run)
        page.setAutoAcceptBeforeUnload(true)
        defer { page.setAutoAcceptBeforeUnload(false) }
        let mark = page.mark()
        let end = Self.runCallEnd(limit, run)
        do {
            if delta < 0 {
                guard try await page.goBack(deadline: end) else { return "null" }
            } else if delta > 0 {
                let history = try await page.call("Page.getNavigationHistory", deadline: end,
                                                  interruptible: [.crashed, .detached])
                guard let index = history.int("currentIndex"), let entries = history.objects("entries"),
                      index + 1 < entries.count, let entryId = entries[index + 1].int("id"),
                      ChromiumBrowser.isOpenable(entries[index + 1].string("url") ?? "") else { return "null" }
                _ = try await page.call("Page.navigateToHistoryEntry", ["entryId": entryId], deadline: end,
                                        interruptible: [.dialogOpened, .crashed, .detached])
            } else {
                try await page.reload(deadline: end)
            }
        } catch CDPError.interrupted(.dialogOpened) {
            return "null"
        }
        try await runLoadState(waitUntil, loaderId: nil, mark: mark, run, limit: limit, ms: ms, api: api,
                               what: "waiting for navigation until \"\(waitUntil.rawValue)\"")
        return Self.runResponse(page)
    }

    /// Until the document reaches `state` — `loaderId`'s, else the one
    /// committed since `mark` (or the current one with no mark).
    private func runLoadState(_ state: AgentRunOp.WaitUntil, loaderId: String?, mark: PageMark?, _ run: ChromiumRunState,
                              limit: ContinuousClock.Instant, ms: Int, api: String, what: String?) async throws {
        let page = run.page
        var quietSince: ContinuousClock.Instant?
        while true {
            try Self.runCheck(run)
            if page.isCrashed { throw AgentError.unavailable("the page's process stopped") }
            if page.isDetached { throw AgentError.unavailable("the page's tab was closed") }
            var expected = loaderId
            var committed = mark == nil
            if let mark {
                for (_, event) in page.signals.events(since: mark) {
                    switch event {
                    case .committed(let loader):
                        committed = true
                        if loaderId == nil { expected = loader }
                    case .sameDocument:
                        if loaderId == nil { return }
                    case .docFailed(_, let errorText):
                        let address = page.lastRequestedAddress.flatMap { URL(string: $0) }
                        throw AgentError.failed(Self.loadFailure(errorText: errorText, url: address,
                                                                 localOnly: control.networkAccess != .open) ?? errorText)
                    default:
                        break
                    }
                }
            }
            let current = page.signals.state
            if state == .commit, committed { return }
            if committed, expected == nil || current.loaderId == expected {
                switch state {
                case .commit:
                    return
                case .domcontentloaded:
                    if current.reached.contains("DOMContentLoaded") || current.loaderId == nil { return }
                case .load:
                    if current.reached.contains("load") || current.loaderId == nil { return }
                case .networkidle:
                    if current.reached.contains("load") || current.loaderId == nil {
                        if current.requestsInFlight == 0 {
                            let since = quietSince ?? ContinuousClock.now
                            quietSince = since
                            if since.duration(to: .now) >= .milliseconds(500) { return }
                        } else {
                            quietSince = nil
                        }
                    }
                }
            }
            // A dialog the page opened while loading: the run's dialog rules take it from here.
            if page.blocksPage { return }
            if ContinuousClock.now >= limit {
                throw ChromiumRunTimeout(api: api, milliseconds: ms, waiting: what, reason: nil)
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    // MARK: Actions

    /// The helper's readiness checks for real input (prepare{trusted}),
    /// again while the element is missing, hidden, disabled, moving or
    /// covered — Playwright's auto-wait — until `limit`. A strict-mode
    /// violation or an invalid locator fails at once.
    private func runPrepare(_ target: AgentRunTarget, action: String, _ run: ChromiumRunState,
                            limit: ContinuousClock.Instant, ms: Int, api: String,
                            focus: Bool = false) async throws -> CDPObject {
        var args: [String: Any] = ["target": target.value, "action": action, "trusted": true]
        if focus {
            args["focus"] = true
            args["selectAll"] = true
        }
        let pointer = action == "click" || action == "hover"
        var reason: String?
        while true {
            try Self.runCheck(run)
            do {
                let answer = try await runHelper("prepare", args, run, limit: limit)
                if answer.string("status") == "ready" { return answer }
                reason = answer.string("reason")
            } catch let error as AgentError {
                guard case .notFound = error else { throw error }
                reason = nil
            } catch let error as CDPError {
                reason = try await runTransient(error, run, limit: limit)
            }
            if ContinuousClock.now >= limit {
                throw ChromiumRunTimeout(api: api, milliseconds: ms, waiting: "waiting for " + target.desc, reason: reason)
            }
            try await Task.sleep(for: .milliseconds(pointer ? 16 : 30))
        }
    }

    /// Where to press: after the checks, the element's centre (or `position`
    /// from its top-left corner); with `force`, wherever it is.
    private func runPoint(_ target: AgentRunTarget, action: String, pointer: AgentRunOp.Pointer,
                          _ run: ChromiumRunState, limit: ContinuousClock.Instant, ms: Int,
                          api: String) async throws -> AgentRunPoint {
        let answer: CDPObject
        if pointer.force {
            answer = try await runResolving("rect", ["target": target.value], target: target, run, limit: limit, ms: ms,
                                            api: api)
        } else {
            answer = try await runPrepare(target, action: action, run, limit: limit, ms: ms, api: api)
        }
        let rect = answer.object("rect")
        if let position = pointer.position, let x = rect?.double("x"), let y = rect?.double("y") {
            return AgentRunPoint(x: x + position.x, y: y + position.y)
        }
        if let point = answer.object("point"), let x = point.double("x"), let y = point.double("y") {
            return AgentRunPoint(x: x, y: y)
        }
        if let rect, let x = rect.double("x"), let y = rect.double("y"), let width = rect.double("width"),
           let height = rect.double("height") {
            return AgentRunPoint(x: x + width / 2, y: y + height / 2)
        }
        throw AgentError.failed("the page did not say where \(target.desc) is")
    }

    private func runClickAt(_ point: AgentRunPoint, button: MouseButton, clickCount: Int, modifiers: CDPModifiers,
                            delay: Int, _ run: ChromiumRunState,
                            limit: ContinuousClock.Instant) async throws -> ChromiumInputOutcome {
        let page = run.page
        let end = Self.runCallEnd(limit, run)
        let pressed = Self.button(button)
        if delay == 0 {
            if clickCount <= 1 {
                return try await page.dispatch(batch: CDPInput.click(x: point.x, y: point.y, button: pressed,
                                                                     modifiers: modifiers), deadline: end)
            }
            return try await page.dispatch(writes: CDPInput.clicks(x: point.x, y: point.y, button: pressed,
                                                                   clickCount: clickCount, modifiers: modifiers),
                                           deadline: end)
        }
        for count in 1...max(1, clickCount) {
            var down: [(String, [String: Any])] = []
            if count == 1 { down.append(CDPInput.mouseMoved(x: point.x, y: point.y, modifiers: modifiers)) }
            down.append(CDPInput.mousePressed(x: point.x, y: point.y, button: pressed, clickCount: count,
                                              modifiers: modifiers))
            let went = try await page.dispatch(batch: down, deadline: end)
            if went != .acked { return went }
            try await Task.sleep(for: .milliseconds(delay))
            let up = try await page.dispatch(batch: [CDPInput.mouseReleased(x: point.x, y: point.y, button: pressed,
                                                                            clickCount: count, modifiers: modifiers)],
                                             deadline: end)
            if up != .acked { return up }
        }
        return .acked
    }

    /// After an action's acks: a dialog it opened (waited for while the
    /// script's handler answers it), the page's turn (the barrier), then the
    /// navigation it started, until its commit — no network-quiet wait, no
    /// snapshot.
    private func runSettle(_ run: ChromiumRunState, mark: PageMark, outcome: ChromiumInputOutcome,
                           limit: ContinuousClock.Instant) async throws {
        let page = run.page
        if outcome == .interrupted(.dialogOpened) || page.blocksPage {
            guard try await runAfterDialog(run, limit: limit) else {
                // The script's handler left it unanswered: the action never
                // finished (design §3.4), whatever it did before.
                if let open = page.dialog { throw ChromiumRunDialogWait(dialog: open) }
                return
            }
        }
        _ = try await page.barrier(deadline: min(Self.runCallEnd(limit, run), ContinuousClock.now + .seconds(2)))
        try await runCommit(run, mark: mark,
                            limit: min(run.scriptEnd, ContinuousClock.now + .milliseconds(run.limits.navigationTimeout)))
    }

    /// A dialog on the page: with a listener, waited for until the script
    /// answers it (true) or `limit` (false); without one, the run stops.
    private func runAfterDialog(_ run: ChromiumRunState, limit: ContinuousClock.Instant) async throws -> Bool {
        guard let dialog = run.page.dialog else { return true }
        if !run.dialogListener {
            // The run stops at it: the main loop ends the run, which cancels
            // this call. Should the dialog close first (answered from the
            // panel, gone with its document), the loop drops the event and
            // the action goes on — it must not wait for an answer that never
            // comes.
            run.events.yield(.dialog(dialog))
        }
        while run.page.dialog != nil {
            try Self.runCheck(run)
            if ContinuousClock.now >= limit { return false }
            try await Task.sleep(for: .milliseconds(15))
        }
        return true
    }

    /// The navigation an action started, until it commits (or fails, stops,
    /// stays in the document) — the next call finds the new page. A request
    /// that never starts is over after the policy's 500 ms.
    private func runCommit(_ run: ChromiumRunState, mark: PageMark, limit: ContinuousClock.Instant) async throws {
        let page = run.page
        let noStart = page.policy.requestedNoStart
        while true {
            try Self.runCheck(run)
            var phase = 0           // 0 none, 1 requested, 2 started, 3 over
            var requestedAt: ContinuousClock.Instant?
            var failure: String?
            for (at, event) in page.signals.events(since: mark) {
                switch event {
                case .navRequested:
                    if phase != 2 {
                        phase = 1
                        requestedAt = at
                    }
                case .navStarted:
                    phase = 2
                case .barrierLost:
                    if phase < 2 { phase = 2 }
                case .committed, .sameDocument:
                    phase = 3
                    failure = nil
                case .docFailed(_, let errorText):
                    phase = 3
                    failure = errorText
                case .navStopped:
                    if phase == 1 || phase == 2 { phase = 3 }
                case .modal, .crashed, .detached:
                    return
                default:
                    break
                }
            }
            if phase == 0 || phase == 3 {
                if let failure {
                    let address = page.lastRequestedAddress.flatMap { URL(string: $0) }
                    let message = Self.loadFailure(errorText: failure, url: address,
                                                   localOnly: control.networkAccess != .open) ?? failure
                    page.note("A page load the script started failed: \(message)")
                }
                return
            }
            if phase == 1, let requestedAt, requestedAt.duration(to: .now) >= noStart { return }
            if ContinuousClock.now >= limit { return }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    // MARK: Keyboard and mouse

    private static let modifierKeys: [(CDPModifiers, CDPKey)] = [
        (.shift, CDPKey.shift), (.control, CDPKey.control), (.alt, CDPKey.alt), (.meta, CDPKey.meta),
    ]

    /// A modifier named alone ("Shift", "ControlOrMeta"): `keyboard.down('Shift')`.
    static func runModifier(_ name: String) -> (CDPModifiers, CDPKey)? {
        switch name.lowercased() {
        case "shift": return (.shift, CDPKey.shift)
        case "control", "ctrl": return (.control, CDPKey.control)
        case "alt", "option": return (.alt, CDPKey.alt)
        case "meta", "command", "cmd", "controlormeta": return (.meta, CDPKey.meta)
        default: return nil
        }
    }

    /// A key press with what `keyboard.down` holds: the key's own modifiers
    /// not already held go down first, and up after it.
    static func runKeyEvents(_ name: String, held: CDPModifiers) throws -> (down: [(String, [String: Any])],
                                                                            up: [(String, [String: Any])]) {
        if case let (flag, modifierKey)? = runModifier(name) {
            var down = modifierKey
            down.modifiers = held.union(flag)
            var up = modifierKey
            up.modifiers = held
            return ([CDPInput.keyDown(down)], [CDPInput.keyUp(up)])
        }
        var key = try KeySpec.parse(name).cdpKey
        let own = key.modifiers
        key.modifiers = own.union(held)
        var downs: [(String, [String: Any])] = []
        var ups: [(String, [String: Any])] = []
        var pressed = held
        var added: [(CDPModifiers, CDPKey)] = []
        for (flag, modifierKey) in modifierKeys where own.contains(flag) && !held.contains(flag) {
            pressed.insert(flag)
            var down = modifierKey
            down.modifiers = pressed
            downs.append(CDPInput.keyDown(down))
            added.append((flag, modifierKey))
        }
        downs.append(CDPInput.keyDown(key))
        ups.append(CDPInput.keyUp(key))
        for (flag, modifierKey) in added.reversed() {
            pressed.remove(flag)
            var up = modifierKey
            up.modifiers = pressed
            ups.append(CDPInput.keyUp(up))
        }
        return (downs, ups)
    }

    private func runPressKey(_ name: String, delay: Int, _ run: ChromiumRunState,
                             limit: ContinuousClock.Instant) async throws -> ChromiumInputOutcome {
        let events = try Self.runKeyEvents(name, held: run.heldModifiers)
        let end = Self.runCallEnd(limit, run)
        if delay == 0 {
            return try await run.page.dispatch(batch: events.down + events.up, deadline: end)
        }
        let down = try await run.page.dispatch(batch: events.down, deadline: end)
        if down != .acked { return down }
        try await Task.sleep(for: .milliseconds(delay))
        return try await run.page.dispatch(batch: events.up, deadline: end)
    }

    private func runKeyboard(_ action: AgentRunOp.KeyAction, key: String?, text: String?, delay: Int,
                             _ run: ChromiumRunState) async throws -> String {
        let page = run.page
        let limit = Self.runLimit(nil, run.limits.actionTimeout, run).0
        let end = Self.runCallEnd(limit, run)
        let mark = page.mark()
        var outcome: ChromiumInputOutcome = .acked
        switch action {
        case .down:
            let name = key ?? ""
            if case let (flag, modifierKey)? = Self.runModifier(name) {
                run.heldModifiers.insert(flag)
                var down = modifierKey
                down.modifiers = run.heldModifiers
                _ = try await page.dispatch(batch: [CDPInput.keyDown(down)], deadline: end)
                return "null"
            }
            var spec = try KeySpec.parse(name).cdpKey
            spec.modifiers = spec.modifiers.union(run.heldModifiers)
            outcome = try await page.dispatch(batch: [CDPInput.keyDown(spec)], deadline: end)
        case .up:
            let name = key ?? ""
            if case let (flag, modifierKey)? = Self.runModifier(name) {
                run.heldModifiers.remove(flag)
                var up = modifierKey
                up.modifiers = run.heldModifiers
                _ = try await page.dispatch(batch: [CDPInput.keyUp(up)], deadline: end)
                return "null"
            }
            var spec = try KeySpec.parse(name).cdpKey
            spec.modifiers = spec.modifiers.union(run.heldModifiers)
            outcome = try await page.dispatch(batch: [CDPInput.keyUp(spec)], deadline: end)
        case .press:
            outcome = try await runPressKey(key ?? "", delay: delay, run, limit: limit)
        case .type:
            let typed = text ?? ""
            if delay == 0 {
                outcome = try await page.dispatch(writes: KeySpec.cdpTypingWrites(typed), deadline: end)
            } else {
                for character in typed {
                    try Self.runCheck(run)
                    outcome = try await page.dispatch(batch: KeySpec.typing(character).cdpTyping(), deadline: end)
                    if outcome != .acked { break }
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
        case .insertText:
            outcome = try await page.dispatch(batch: [CDPInput.insertText(text ?? "")], deadline: end)
        }
        try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
        return "null"
    }

    private func runMouse(_ action: AgentRunOp.MouseAction, x: Double?, y: Double?, button: MouseButton,
                          clickCount: Int, steps: Int, deltaX: Double, deltaY: Double, delay: Int,
                          _ run: ChromiumRunState) async throws -> String {
        let page = run.page
        let limit = Self.runLimit(nil, run.limits.actionTimeout, run).0
        let end = Self.runCallEnd(limit, run)
        let flags = run.heldModifiers
        let pressed = Self.button(button)
        let mark = page.mark()
        var outcome: ChromiumInputOutcome = .acked
        switch action {
        case .move:
            let target = AgentRunPoint(x: x ?? run.mouse.x, y: y ?? run.mouse.y)
            let from = run.mouse
            var batch: [(String, [String: Any])] = []
            for step in 1...max(1, steps) {
                let t = Double(step) / Double(max(1, steps))
                batch.append(CDPInput.mouseMoved(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t,
                                                 modifiers: flags, held: run.buttons))
            }
            run.mouse = target
            _ = try await page.dispatch(batch: batch, deadline: end)
            return "null"
        case .down:
            outcome = try await page.dispatch(batch: [CDPInput.mousePressed(x: run.mouse.x, y: run.mouse.y, button: pressed,
                                                                            clickCount: clickCount, modifiers: flags,
                                                                            held: run.buttons)], deadline: end)
            run.buttons.insert(pressed.mask)
        case .up:
            run.buttons.remove(pressed.mask)
            outcome = try await page.dispatch(batch: [CDPInput.mouseReleased(x: run.mouse.x, y: run.mouse.y, button: pressed,
                                                                             clickCount: clickCount, modifiers: flags,
                                                                             held: run.buttons)], deadline: end)
        case .click, .dblclick:
            let point = AgentRunPoint(x: x ?? run.mouse.x, y: y ?? run.mouse.y)
            outcome = try await runClickAt(point, button: button, clickCount: action == .dblclick ? 2 : clickCount,
                                           modifiers: flags, delay: delay, run, limit: limit)
            run.mouse = point
        case .wheel:
            _ = try await page.dispatch(batch: [CDPInput.mouseWheel(x: run.mouse.x, y: run.mouse.y, deltaX: deltaX,
                                                                    deltaY: deltaY, modifiers: flags)], deadline: end)
            return "null"
        }
        try await runSettle(run, mark: mark, outcome: outcome, limit: limit)
        return "null"
    }

    /// What the script still held at its end comes up: no key or button
    /// stays down for the next command.
    private func runReleaseInput(_ run: ChromiumRunState) async {
        let page = run.page
        guard !page.isDetached, !page.isCrashed, !run.buttons.isEmpty || !run.heldModifiers.isEmpty else { return }
        var batch: [(String, [String: Any])] = []
        var buttons = run.buttons
        for button in [CDPMouseButton.left, .right, .middle] where buttons.contains(button.mask) {
            buttons.remove(button.mask)
            batch.append(CDPInput.mouseReleased(x: run.mouse.x, y: run.mouse.y, button: button, held: buttons))
        }
        var held = run.heldModifiers
        for (flag, modifierKey) in Self.modifierKeys.reversed() where held.contains(flag) {
            held.remove(flag)
            var up = modifierKey
            up.modifiers = held
            batch.append(CDPInput.keyUp(up))
        }
        run.buttons = []
        run.heldModifiers = []
        _ = try? await page.dispatch(batch: batch, deadline: ContinuousClock.now + .seconds(1))
    }

    // MARK: Reads, waits, files, screenshots

    private func runWaitState(_ target: AgentRunTarget, state: String, timeout: Int?, _ run: ChromiumRunState,
                              api: String) async throws -> String {
        let (limit, ms) = Self.runLimit(timeout, run.limits.actionTimeout, run)
        while true {
            try Self.runCheck(run)
            let left = max(0, Self.milliseconds(ContinuousClock.now.duration(to: limit)))
            do {
                let answer = try await run.page.helper("waitState", ["target": target.value, "state": state,
                                                                     "maxMs": min(2_000, left)],
                                                       deadline: Self.runCallEnd(ContinuousClock.now
                                                                                 + .milliseconds(min(2_000, left) + 2_000), run))
                if answer.bool("done") == true { return "null" }
            } catch let error as CDPError {
                _ = try await runTransient(error, run, limit: limit)
            }
            if ContinuousClock.now >= limit {
                throw ChromiumRunTimeout(api: api, milliseconds: ms, waiting: "waiting for \(target.desc) to be \(state)",
                                         reason: nil)
            }
        }
    }

    private func runFiles(_ target: AgentRunTarget, paths: [String], timeout: Int?, _ run: ChromiumRunState,
                          api: String) async throws -> String {
        let page = run.page
        let (limit, ms) = Self.runLimit(timeout, run.limits.actionTimeout, run)
        // The policy first: nothing of the page is touched for a path it refuses.
        let policy = AgentUploadPolicy(roots: run.host.environment.uploadRoots)
        var files: [URL] = []
        if !paths.isEmpty {
            switch policy.validate(paths, allowsMultiple: true) {
            case .success(let accepted): files = accepted
            case .failure(let refusal): throw AgentError.invalid(AgentUploadPolicy.message(for: refusal, roots: policy.roots))
            }
        }
        let stamped = try await runResolving("stamp", ["target": target.value], target: target, run, limit: limit,
                                             ms: ms, api: api)
        let nonce = stamped.string("nonce") ?? ""
        let end = Self.runCallEnd(limit, run)
        let interruptible: Set<CDPInterruption> = [.dialogOpened, .navigated, .crashed, .detached]
        let found = try await page.call("Runtime.evaluate", [
            "expression": "(() => { const e = document.querySelector('[data-loom-eval=\"" + nonce + "\"]'); "
                + "if (e) e.removeAttribute('data-loom-eval'); return e; })()",
            "returnByValue": false,
        ], deadline: end, interruptible: interruptible)
        guard let objectId = found.object("result")?.string("objectId") else {
            throw AgentError.failed("\(target.desc) is no longer in the page")
        }
        defer { page.post("Runtime.releaseObject", ["objectId": objectId]) }
        let kind = try await page.call("Runtime.callFunctionOn", [
            "objectId": objectId,
            "functionDeclaration": "function() { return { file: this.localName === 'input' && "
                + "String(this.type).toLowerCase() === 'file', multiple: !!this.multiple }; }",
            "returnByValue": true,
        ], deadline: end, interruptible: interruptible)
        let input = kind.object("result")?.object("value")
        guard input?.bool("file") == true else { throw AgentError.invalid("Node is not an HTMLInputElement of type file") }
        if files.count > 1, input?.bool("multiple") != true {
            throw AgentError.invalid(AgentUploadPolicy.message(for: .tooMany, roots: policy.roots))
        }
        let mark = page.mark()
        _ = try await page.call("DOM.setFileInputFiles", ["files": files.map(\.path), "objectId": objectId],
                                deadline: end, interruptible: [.dialogOpened, .crashed, .detached])
        try await runSettle(run, mark: mark, outcome: .acked, limit: limit)
        return "null"
    }

    private func runScreenshot(_ target: AgentRunTarget?, fullPage: Bool, format: ImageFormat, _ run: ChromiumRunState,
                               api: String) async throws -> String {
        let page = run.page
        guard run.screenshots < run.limits.maxScreenshots else {
            throw AgentError.invalid("a run takes \(run.limits.maxScreenshots) screenshots at most")
        }
        if page.blocksPage { throw AgentError.conflict("a dialog is open: the page cannot be drawn") }
        let environment = run.host.environment
        let maxEdge = environment.limits.imageMaxEdge
        let (limit, ms) = Self.runLimit(nil, run.limits.actionTimeout, run)
        let end = Self.runCallEnd(limit, run)
        let shot: ChromiumScreenshot
        if fullPage {
            let info = try await runHelper("pageInfo", [:], run, limit: limit)
            let width = info.double("width") ?? 0
            let height = max(info.double("scrollHeight") ?? 0, info.double("height") ?? 0)
            guard width > 0, height > 0 else { throw AgentError.failed("the page has no size to capture") }
            shot = try await page.capture(clip: CGRect(x: 0, y: 0, width: width, height: height), format: format,
                                          fullPage: true, maxEdge: maxEdge, deadline: end)
        } else if let target {
            let answer = try await runResolving("documentRect", ["target": target.value], target: target, run,
                                                limit: limit, ms: ms, api: api)
            guard let box = answer.object("rect"), let x = box.double("x"), let y = box.double("y"),
                  let width = box.double("width"), let height = box.double("height"), width > 0, height > 0 else {
                throw AgentError.invalid("\(target.desc) has no visible box to capture")
            }
            var clip = CGRect(x: x, y: y, width: width, height: height)
            if let view = answer.object("viewport"), let viewWidth = view.double("width"),
               let viewHeight = view.double("height") {
                clip = clip.intersection(CGRect(x: view.double("x") ?? 0, y: view.double("y") ?? 0,
                                                width: viewWidth, height: viewHeight))
            }
            guard !clip.isNull, clip.width >= 1, clip.height >= 1 else {
                throw AgentError.invalid("\(target.desc) is outside the visible page")
            }
            shot = try await page.capture(clip: clip, format: format, fullPage: false, maxEdge: maxEdge, deadline: end)
        } else {
            shot = try await page.capture(clip: nil, format: format, fullPage: false, maxEdge: maxEdge, deadline: end)
        }
        let directory = environment.screenshotsDirectory
        let url = try AgentScreenshot.write(shot.data, in: directory,
                                            sequence: AgentScreenshot.lastSequence(in: directory) + 1, format: format)
        run.image = AgentImage(url: url, mimeType: format.mimeType, width: shot.width, height: shot.height)
        run.screenshots += 1
        return "null"
    }

    // MARK: Primitives

    private func runHelper(_ op: String, _ args: [String: Any], _ run: ChromiumRunState,
                           limit: ContinuousClock.Instant) async throws -> CDPObject {
        try Self.runCheck(run)
        return try await run.page.helper(op, args, deadline: Self.runCallEnd(limit, run))
    }

    /// A helper op on a target that may not be there yet: asked again while
    /// it is not found, or the page is between two documents, until `limit`.
    private func runResolving(_ op: String, _ args: [String: Any], target: AgentRunTarget, _ run: ChromiumRunState,
                              limit: ContinuousClock.Instant, ms: Int, api: String) async throws -> CDPObject {
        var reason: String?
        while true {
            do {
                return try await runHelper(op, args, run, limit: limit)
            } catch let error as AgentError {
                guard case .notFound = error else { throw error }
                reason = nil
            } catch let error as CDPError {
                reason = try await runTransient(error, run, limit: limit)
            }
            if ContinuousClock.now >= limit {
                throw ChromiumRunTimeout(api: api, milliseconds: ms, waiting: "waiting for " + target.desc, reason: reason)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// A helper call the page could not answer now (a navigation, a dialog,
    /// a busy page): the reason, to try again. Anything else is thrown.
    private func runTransient(_ error: CDPError, _ run: ChromiumRunState,
                              limit: ContinuousClock.Instant) async throws -> String {
        switch error {
        case .interrupted(.navigated):
            return "the page navigated"
        case .interrupted(.dialogOpened):
            _ = try await runAfterDialog(run, limit: limit)
            return "the page waits on a dialog"
        case .timeout:
            return "the page did not answer in time"
        case .cancelled:
            throw CancellationError()
        default:
            throw error
        }
    }

    /// A script in the page's own world (page.evaluate, locator.evaluate,
    /// waitForFunction, content): as browser_evaluate runs it, stopped
    /// (terminateExecution) when the run's time is out. Its raw value.
    private func runPageEvaluate(_ expression: String, _ run: ChromiumRunState, api: String) async throws -> Any? {
        let page = run.page
        if page.blocksPage {
            guard try await runAfterDialog(run, limit: run.scriptEnd) else {
                throw AgentError.conflict("a dialog is open on the page")
            }
        }
        run.pageEvaluations += 1
        defer { run.pageEvaluations -= 1 }
        let params: [String: Any] = ["expression": expression, "awaitPromise": true, "returnByValue": true,
                                     "userGesture": true]
        // With a page.on('dialog') listener, a dialog the function opens is
        // the script's to answer, and the evaluation waits for it — as
        // Playwright's `page.evaluate(() => prompt(…))` does. Without one,
        // the run stops at it (runAfterDialog).
        let interruptible: Set<CDPInterruption> = run.dialogListener
            ? [.navigated, .crashed, .detached] : ChromiumTabRuntime.inputInterruptions
        let result: CDPObject
        do {
            result = try await page.call("Runtime.evaluate", params, deadline: Self.runCallEnd(run.scriptEnd, run),
                                         interruptible: interruptible)
        } catch let error as CDPError {
            switch error {
            case .timeout:
                page.post("Runtime.terminateExecution")
                throw AgentError.timeout("the function did not finish before the script's time was out; Loom stopped it")
            case .interrupted(.navigated):
                throw AgentError.failed("Execution context was destroyed, most likely because of a navigation")
            case .interrupted(.dialogOpened):
                // No listener: the run stops at the dialog (runAfterDialog
                // reports it, and is cancelled with the run).
                _ = try await runAfterDialog(run, limit: run.scriptEnd)
                throw AgentError.conflict("the function opened a dialog")
            case .protocolError(_, _, let message):
                if ChromiumHelper.isDocumentGone(message) {
                    throw AgentError.failed("Execution context was destroyed, most likely because of a navigation")
                }
                if message.contains("terminated") { throw AgentError.failed("the function was stopped before it finished") }
                throw error
            default:
                throw error
            }
        }
        if let exception = result.object("exceptionDetails") {
            throw AgentError.failed(ChromiumHelper.describe(exception))
        }
        return result.object("result")?.raw["value"]
    }

    // MARK: Reading the end

    private func runRead(_ outcome: (result: CDPObject?, failure: String?), into report: inout AgentRunReport) {
        if let failure = outcome.failure {
            report.error = "The script did not finish: \(failure)"
            return
        }
        guard let result = outcome.result else {
            report.error = "The script ended without an answer."
            return
        }
        if let exception = result.object("exceptionDetails") {
            let description = ChromiumHelper.describe(exception)
            if description.hasPrefix("SyntaxError") {
                report.syntaxError = true
                var place = ""
                if let line = exception.int("lineNumber").flatMap(AgentRunSource.agentLine(exceptionLine:)) {
                    place = " (line \(line)"
                    if let column = exception.int("columnNumber") { place += ", column \(column + 1)" }
                    place += " of your code)"
                }
                report.error = description + place + ". Nothing ran."
            } else {
                report.error = description
            }
            return
        }
        guard let value = result.object("result")?.object("value") else {
            report.error = "The script ended without an answer."
            return
        }
        // The facade's `logs` (`output` in the design's first draft).
        report.output = (value.raw["logs"] as? [Any] ?? value.raw["output"] as? [Any] ?? []).compactMap { $0 as? String }
        report.outputDropped = value.int("logsDropped") ?? value.int("outputDropped") ?? 0
        report.unfinished = (value.raw["unfinished"] as? [Any] ?? []).compactMap { $0 as? String }
        if value.bool("ok") == true {
            report.value = value.string("value")
            return
        }
        let failure = value.object("error")
        let name = failure?.string("name") ?? "Error"
        let message = failure?.string("message") ?? "the script failed"
        var text = message.hasPrefix(name + ":") ? message : name + ": " + message
        let line = failure?.int("line") ?? failure?.string("stack").flatMap(AgentRunSource.agentLine(stack:))
        if let line, !text.contains("line \(line) of your code") {
            text += " (line \(line) of your code" + (failure?.int("step").map { ", step \($0)" } ?? "") + ")"
        }
        report.error = text
    }

    private func runStopMessage(_ stop: ChromiumRunStop, _ run: ChromiumRunState) -> String {
        let limits = run.limits
        let at = "at step \(run.steps)" + (run.lastLine.map { " (line \($0) of your code)" } ?? "")
        switch stop {
        case .deadline:
            let seconds = Int(run.started.duration(to: run.scriptEnd).components.seconds)
            return "The script ran out of time: browser_run_code stops a script after \(seconds) s. "
                + "It was stopped \(at)."
        case .steps:
            return "The script made more than \(limits.maxSteps) page calls: it was stopped."
        case .flood:
            return "The script called Loom's bridge more than \(2 * limits.maxSteps) times: it was stopped."
        case .transfer:
            return "The script's page calls carried more than \(limits.maxTransferBytes / 1_048_576) MB: it was stopped."
        case .oversize:
            return "A page call was larger than \(limits.maxMessageBytes / 1_024) KB: the script was stopped."
        case .memory:
            return "The script used more than \(limits.heapCapBytes / 1_048_576) MB of memory: it was stopped."
        case .dialog(let dialog):
            let kind = dialog.kind == .beforeunload ? "confirm" : dialog.kind.rawValue
            return "The page opened a \(kind) dialog (\(AgentModalState.quoted(dialog.message))) \(at): "
                + "the script was stopped. Answer it with browser_handle_dialog, or handle it in the script: "
                + "page.once('dialog', d => d.accept())."
        case .runnerGone(let reason):
            return "The script's sandbox stopped (\(reason)) \(at)."
        }
    }

    // MARK: Pure parts

    /// What the facade starts with (run-code design §1.2): the page as it
    /// stands, the run's limits, the script's own time.
    static func runConfig(_ run: ChromiumRunState, valueChars: Int) -> AgentRunnerScript.Config {
        let size = run.page.viewport
        var config = AgentRunnerScript.Config(url: run.page.url,
                                              viewport: .init(width: Int(size.width.rounded()),
                                                              height: Int(size.height.rounded())),
                                              valueChars: valueChars)
        config.defaultTimeout = run.limits.actionTimeout
        config.navigationTimeout = run.limits.navigationTimeout
        config.scriptMs = max(1, milliseconds(ContinuousClock.now.duration(to: run.scriptEnd)))
        config.maxSteps = run.limits.maxSteps
        config.maxInFlight = run.limits.maxInFlight
        config.maxMessageBytes = run.limits.maxMessageBytes
        config.consoleLines = run.limits.consoleLines
        config.consoleChars = run.limits.consoleChars
        return config
    }

    /// A call's limit: the time the facade says is left of it (Playwright's
    /// `timeout: 0` is already the run's end there; 0 here is none left:
    /// one attempt), else `fallback` — never past the run's end. And the
    /// milliseconds an error names.
    static func runLimit(_ timeout: Int?, _ fallback: Int, _ run: ChromiumRunState) -> (ContinuousClock.Instant, Int) {
        let asked = timeout ?? fallback
        return (min(ContinuousClock.now + .milliseconds(max(0, asked)), run.scriptEnd), asked)
    }

    /// One CDP call's deadline within a call: its limit, at least 750 ms
    /// (a page busy loading still answers), never past the command's end.
    static func runCallEnd(_ limit: ContinuousClock.Instant, _ run: ChromiumRunState) -> ContinuousClock.Instant {
        min(run.deadline - .seconds(2), max(limit, ContinuousClock.now + .milliseconds(750)))
    }

    static func runCheck(_ run: ChromiumRunState) throws {
        if run.ended || Task.isCancelled { throw CancellationError() }
    }

    /// A relative address (`/next`, `?q=1`, `#x`, `../a`) against the page's.
    static func runResolve(_ address: String, against base: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, "/?#.".contains(first),
              let page = URL(string: base), ["http", "https"].contains(page.scheme?.lowercased() ?? ""),
              let resolved = URL(string: trimmed, relativeTo: page)?.absoluteURL else { return trimmed }
        return resolved.absoluteString
    }

    /// `{url, status, ok}` of the document the page shows; null without a status.
    static func runResponse(_ page: ChromiumTabRuntime) -> String {
        guard let status = page.httpStatus else { return "null" }
        let value: [String: Any] = ["url": page.url, "status": status, "ok": (200..<300).contains(status)]
        return AgentRunJSON.text(value) ?? "null"
    }

    /// page.evaluate / locator.evaluate(All) in the page's world: the
    /// function called with the stamped element(s) first, then `argument`;
    /// its value through browser_evaluate's serializer.
    static func runEvaluateExpression(function: String, argument: String, nonce: String, all: Bool) -> String {
        let trimmed = function.trimmingCharacters(in: .whitespacesAndNewlines)
        let callable = AgentScripts.isFunction(trimmed) ? trimmed : "() => (\n" + trimmed + "\n)"
        return """
        (async () => {
        const __loomNonce = \(ChromiumTabRuntime.jsString(nonce));
        const __loomArg = (\(argument));
        let __loomTarget;
        if (__loomNonce) {
          const found = Array.from(document.querySelectorAll('[data-loom-eval="' + __loomNonce + '"]'));
          for (const element of found) element.removeAttribute("data-loom-eval");
          __loomTarget = \(all ? "found" : "found[0]");
        }
        const __loomFunction = (
        \(callable)
        );
        const __loomValue = __loomNonce ? await __loomFunction(__loomTarget, __loomArg) : await __loomFunction(__loomArg);
        return (\(AgentScripts.serializer))(__loomValue);
        })()
        """
    }

    /// waitForFunction's poll: the serializer's JSON of a truthy value, else null.
    static func runWaitExpression(function: String, argument: String) -> String {
        let trimmed = function.trimmingCharacters(in: .whitespacesAndNewlines)
        let callable = AgentScripts.isFunction(trimmed) ? trimmed : "() => (\n" + trimmed + "\n)"
        return """
        (async () => {
        const __loomArg = (\(argument));
        const __loomFunction = (
        \(callable)
        );
        const __loomValue = await __loomFunction(__loomArg);
        return __loomValue ? (\(AgentScripts.serializer))(__loomValue) : null;
        })()
        """
    }

    /// A call's failure as the facade throws it: `TimeoutError` with
    /// Playwright's words, else `Error` named after the call.
    static func runFailure(_ error: Error, api: String) -> AgentRunFailure {
        if let timeout = error as? ChromiumRunTimeout {
            return AgentRunFailure(name: "TimeoutError", message: timeout.message)
        }
        if let waiting = error as? ChromiumRunDialogWait {
            let kind = waiting.dialog.kind == .beforeunload ? "confirm" : waiting.dialog.kind.rawValue
            return AgentRunFailure(name: "TimeoutError", message: api + ": Timeout exceeded while the page's " + kind
                                   + " dialog (" + AgentModalState.quoted(waiting.dialog.message) + ") waited for an answer: "
                                   + "your page.on('dialog') handler must call dialog.accept() or dialog.dismiss()")
        }
        if let failure = error as? AgentRunFailure { return failure }
        let agent = (error as? AgentError) ?? (ChromiumTabRuntime.agentError(error) as? AgentError)
        let message = agent?.message ?? String(describing: error)
        return AgentRunFailure(name: "Error", message: api + ": " + message)
    }
}
