import Dispatch
import Foundation
import LoomChromium

/// Calls into Loom's helper (`AgentScripts.helper`) in the `loom-agent`
/// world of a tab's main frame (ADR-0015, design §3.2, step-0 probes).
///
/// No `Runtime.enable`, so no `executionContextCreated`: the world's context
/// id comes from `Page.createIsolatedWorld`, which hands back the world
/// `addScriptToEvaluateOnNewDocument` made (the helper already in it). The id
/// is cached per document — invalidated at the main frame's commit, where a
/// new one is prefetched: across a cross-site navigation ids restart in the
/// new renderer, so a stale id could alias a live context.
///
/// A call is one `Runtime.callFunctionOn` of `AgentScripts.helperFunction`.
/// Its answer is the helper's JSON, as WebKit's `helperCall` gives it.
public final class ChromiumHelper: @unchecked Sendable {

    public static let worldName = PageSignals.worldName
    /// What ends a helper call early: Chromium would answer it only after the
    /// dialog is handled, or never (a new document, a dead renderer).
    public static let interruptible: Set<CDPInterruption> = [.dialogOpened, .navigated, .crashed, .detached]

    /// The helper's source as a function body, for a document the injected
    /// script missed: it answers "loaded", never undefined.
    public static let injectFunction = "function() {\n" + AgentScripts.helper + "\nreturn \"loaded\";\n}"

    private struct HelperMissing: Error {}

    private let connection: CDPConnection
    private let session: CDPSessionID
    private let mainFrameId: @Sendable () -> String
    private let dialogOpen: @Sendable () -> Bool

    // Guarded by `lock`.
    private let lock = NSLock()
    /// The current document's world, once Chromium named it.
    private var world: (id: Int, document: Int)?
    /// Main-frame commits seen: which document a cached id belongs to.
    private var document = 0
    private var inFlight = 0

    /// `mainFrameId`: the frame the world is made in when none is cached;
    /// `dialogOpen`: a call is refused at once while a dialog blocks the page.
    public init(connection: CDPConnection, session: CDPSessionID,
                mainFrameId: @escaping @Sendable () -> String,
                dialogOpen: @escaping @Sendable () -> Bool) {
        self.connection = connection
        self.session = session
        self.mainFrameId = mainFrameId
        self.dialogOpen = dialogOpen
    }

    /// Helper calls (and anything else counted with `begin`/`end`) waiting
    /// for the page: a stuck check only means something while one does.
    public var callsInFlight: Int {
        lock.withLock { inFlight }
    }

    func beginCall() {
        lock.withLock { inFlight += 1 }
    }

    func endCall() {
        lock.withLock { inFlight -= 1 }
    }

    // MARK: - Commands

    /// `Page.createIsolatedWorld` for a frame — the world the helper (main
    /// frame) or the relay (every frame) already lives in.
    public static func createWorldParams(frameId: String) -> [String: Any] {
        ["frameId": frameId, "worldName": worldName, "grantUniveralAccess": false]
    }

    /// One helper call, exactly as `Tests/AgentBrowserCDP/fixtures/init.json`
    /// has it (`helperCall`).
    public static func callCommand(op: String, argsJSON: String, contextId: Int) -> (String, [String: Any]) {
        let arguments: [[String: Any]] = [["value": op], ["value": argsJSON]]
        let params: [String: Any] = [
            "functionDeclaration": AgentScripts.helperFunction,
            "executionContextId": contextId,
            "arguments": arguments,
            "returnByValue": true,
            "awaitPromise": true,
            "silent": true,
        ]
        return ("Runtime.callFunctionOn", params)
    }

    // MARK: - The world's id (reader queue for the commit)

    /// A main-frame commit (`Page.frameNavigated` without a parent), on the
    /// reader queue BEFORE PageSignals sees it: the cached id goes, and the
    /// new document's is asked for now, so the first call after a load pays
    /// no extra round trip. Not interruptible: the very commit that asked
    /// for it interrupts `.navigated` calls next.
    public func documentChanged(frameId: String) {
        let current: Int = lock.withLock {
            document += 1
            world = nil
            return document
        }
        let reply = connection.post("Page.createIsolatedWorld", Self.createWorldParams(frameId: frameId),
                                    session: session,
                                    options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(10)))
        Task { [weak self] in
            guard let result = try? await reply.value(), let id = result.int("executionContextId") else { return }
            self?.store(id, document: current)
        }
    }

    /// A subframe's commit: its world is made sure of before the binding is
    /// added again (in the headless shell a subframe's contexts are made
    /// lazily, and the binding reaches only those that exist). Fire-and-forget.
    public func subframeChanged(frameId: String) {
        connection.post("Page.createIsolatedWorld", Self.createWorldParams(frameId: frameId), session: session,
                        options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(10)))
    }

    /// The world's id in the current document: the cached one, else asked
    /// for now (one round trip, under a millisecond on an idle page).
    func contextId(deadline: ContinuousClock.Instant) async throws -> (id: Int, document: Int) {
        let cached: (id: Int, document: Int)? = lock.withLock { world }
        if let cached { return cached }
        let current = lock.withLock { document }
        let result = try await connection.call("Page.createIsolatedWorld",
                                               Self.createWorldParams(frameId: mainFrameId()),
                                               session: session, options: CDPCallOptions(deadline: deadline))
        guard let id = result.int("executionContextId") else {
            throw AgentError.failed("Chromium named no world for Loom's helper")
        }
        store(id, document: current)
        return (id, current)
    }

    private func store(_ id: Int, document owner: Int) {
        lock.withLock {
            guard document == owner, world == nil else { return }
            world = (id, owner)
        }
    }

    private func invalidate(_ id: Int) {
        lock.withLock {
            guard world?.id == id else { return }
            world = nil
        }
    }

    // MARK: - Calls

    /// The helper's answer to `op`. Throws:
    /// - `AgentError` for the helper's own errors (`notFound`, `invalid`…)
    ///   and for a JavaScript exception ("JavaScript error: …");
    /// - `CDPError.interrupted(.navigated)` when the document went away
    ///   under the call ("Execution context was destroyed.", "Promise was
    ///   collected", or a stale id twice);
    /// - `CDPError.interrupted(.dialogOpened | .crashed | .detached)`,
    ///   `.timeout`, `.disconnected`, `.cancelled` as the connection gives them.
    ///
    /// The helper missing (a document the injected script missed) is
    /// injected once, then the call is made again; a stale context id
    /// ("Cannot find context with specified id") gets a fresh world and one
    /// more try — except `asBarrier`, for which a stale id means the barrier
    /// lost its document: a navigation.
    public func call(_ op: String, argsJSON: String, deadline: ContinuousClock.Instant,
                     asBarrier: Bool = false) async throws -> CDPObject {
        if dialogOpen() { throw CDPError.interrupted(.dialogOpened) }
        beginCall()
        defer { endCall() }
        var recreated = false
        var injected = false
        while true {
            try Task.checkCancellation()
            let current = try await contextId(deadline: deadline)
            let command = Self.callCommand(op: op, argsJSON: argsJSON, contextId: current.id)
            let result: CDPObject
            do {
                result = try await connection.call(command.0, command.1, session: session,
                                                   options: CDPCallOptions(deadline: deadline,
                                                                           interruptible: Self.interruptible))
            } catch let error as CDPError {
                guard case .protocolError(_, _, let message) = error else { throw error }
                if Self.isStaleContext(message) {
                    invalidate(current.id)
                    if asBarrier || recreated { throw CDPError.interrupted(.navigated) }
                    recreated = true
                    continue
                }
                if Self.isDocumentGone(message) {
                    invalidate(current.id)
                    throw CDPError.interrupted(.navigated)
                }
                throw error
            }
            if let exception = result.object("exceptionDetails") {
                throw AgentError.invalid("JavaScript error: " + Self.describe(exception))
            }
            guard let text = result.object("result")?.string("value") else {
                throw AgentError.failed("the page answered something unexpected")
            }
            do {
                return try Self.decode(text)
            } catch is HelperMissing {
                if injected { throw AgentError.failed("Loom's helper could not be loaded in this page") }
                injected = true
                try await inject(contextId: current.id, deadline: deadline)
            }
        }
    }

    /// The helper evaluated into the world directly (as the WebKit engine's
    /// `injectHelper`), for a document whose injected script did not run.
    private func inject(contextId: Int, deadline: ContinuousClock.Instant) async throws {
        let params: [String: Any] = [
            "functionDeclaration": Self.injectFunction,
            "executionContextId": contextId,
            "returnByValue": true,
            "silent": true,
        ]
        let result: CDPObject
        do {
            result = try await connection.call("Runtime.callFunctionOn", params, session: session,
                                               options: CDPCallOptions(deadline: deadline,
                                                                       interruptible: Self.interruptible))
        } catch let error as CDPError {
            if case .protocolError(_, _, let message) = error,
               Self.isStaleContext(message) || Self.isDocumentGone(message) {
                invalidate(contextId)
                throw CDPError.interrupted(.navigated)
            }
            throw error
        }
        if let exception = result.object("exceptionDetails") {
            throw AgentError.failed("Loom's helper could not be loaded in this page: " + Self.describe(exception))
        }
    }

    // MARK: - Reading answers

    /// "Cannot find context with specified id": the call named a world of a
    /// document already gone (its commit is on the wire before this error).
    public static func isStaleContext(_ message: String) -> Bool {
        message.contains("Cannot find context with specified id")
    }

    /// The document went away while the call was pending: on a same-site
    /// navigation the failure even comes before `Page.frameNavigated`.
    public static func isDocumentGone(_ message: String) -> Bool {
        message.contains("Execution context was destroyed")
            || message.contains("Promise was collected")
            || message.contains("Inspected target navigated or closed")
            || isStaleContext(message)
    }

    /// The helper's answer: its fields, or its `{error}` as an AgentError —
    /// the codes the WebKit engine maps (AgentJS.decode).
    public static func decode(_ json: String) throws -> CDPObject {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let object = parsed as? [String: Any] else {
            throw AgentError.failed("the page answered something unexpected")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "failed"
            switch error["code"] as? String {
            case "notFound":
                throw AgentError.notFound(message)
            case "invalid", "ambiguous", "notSelect", "optionNotFound", "notEditable":
                throw AgentError.invalid(message)
            case "helperMissing":
                throw HelperMissing()
            default:
                throw AgentError.failed(message)
            }
        }
        return CDPObject(object)
    }

    /// `exceptionDetails` in one line: the exception's first line
    /// ("TypeError: x is not a function"), its value for a thrown non-Error.
    public static func describe(_ details: CDPObject) -> String {
        if let exception = details.object("exception") {
            if let description = exception.string("description"), !description.isEmpty {
                let first = description.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
                return first.map(String.init) ?? description
            }
            if let value = exception.raw["value"] {
                return String(describing: value)
            }
        }
        return details.string("text") ?? "an exception was thrown"
    }

    /// Arguments as the helper reads them: JSON, `{}` for anything that is
    /// not (JSONSerialization would raise on it).
    public static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
