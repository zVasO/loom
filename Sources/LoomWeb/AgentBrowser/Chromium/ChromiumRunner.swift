import Dispatch
import Foundation
import LoomChromium
import os

// ChromiumRunner — where browser_run_code's script runs (run-code design §1):
// never in the page under test, but in a target of the session's own, in a
// browser context of its own that reaches no network (RunnerFence: the
// context's proxy is a ChromiumFence with nothing bypassed, Fetch fails every
// request, the network is emulated offline). Its only way out is one binding
// to Loom, `__loomRunCall`; every page call the script makes comes through it
// and is carried out by the core with the tools' own primitives and checks.
//
// Lifetime   one per session (keyed by the core's control), made at the first
//            run: the fence, the context, the target (its own window: a
//            background tab of the full browser would not render), its init.
//            The target is made again after a stopped run and every 32 runs
//            (each run leaves a world behind); everything goes after 300 s
//            without a run, when the session's browser changes or closes.
// One run    a fresh isolated world `loom-run-<n>` (Chromium reuses a world by
//            name), the binding added to that world by its id — no
//            Runtime.enable: the binding reaches only the contexts that exist
//            when it is added (step-0 probe). Binding calls from any other
//            world (an older run's timers) are dropped.
// Stop       Runtime.terminateExecution (a `while (true) {}` ends in 2 ms),
//            then Target.closeTarget, waited for 1 s, then Page.crash and
//            closeTarget again (runcode.test.mjs, both binaries).
//
// Its callbacks come on the connection's reader queue, in wire order: they
// post (fail a paused request, dismiss a dialog) or hand a payload on, and
// never wait.

/// One run's world in the runner.
struct ChromiumRunWorld: Sendable, Equatable {
    let contextId: Int
    let run: Int
}

final class ChromiumRunner: ChromiumTargetOwner, CDPEventSink, @unchecked Sendable {

    /// The facade's binding: RunnerFence adds it to each run's world.
    static let bindingName = RunnerFence.bindingName
    /// How a reply reaches the facade: a call into the run's world, the JSON
    /// as its argument (`__loomRunAnswer`).
    static let replyFunction = AgentRunnerScript.answerFunction
    /// How an event (a dialog the page opened) reaches it: the same door.
    static let eventFunction = AgentRunnerScript.answerFunction

    /// The facade (AgentRunnerScript), then its start with the run's
    /// configuration: one evaluation in the run's world.
    static func installExpression(config: AgentRunnerScript.Config) -> String {
        AgentRunnerScript.facade + "\n;globalThis.__loomRun.start(" + config.json() + ");\n"
            + "//# sourceURL=loom-runner.js"
    }

    let browser: ChromiumBrowser
    let limits: AgentRunLimits
    var connection: CDPConnection { browser.connection }

    private let logger = Logger(subsystem: "app.loom", category: "agent-browser")

    private struct Route {
        let contextId: Int
        let onCall: @Sendable (String) -> Void
        let onEnd: @Sendable (String) -> Void
    }

    // Guarded by `lock`.
    private let lock = NSLock()
    private var fence: ChromiumFence?
    private var contextId: String?
    private var target: ChromiumTarget?
    private var crashed = false
    /// Runs on the current target (its worlds pile up), and in all.
    private var targetRuns = 0
    private var runs = 0
    private var route: Route?
    private var disposed = false
    private var idleGeneration = 0

    init(browser: ChromiumBrowser, limits: AgentRunLimits) {
        self.browser = browser
        self.limits = limits
    }

    var isDisposed: Bool {
        lock.withLock { disposed }
    }

    /// The runner target's id, while it lives (tests, the logs).
    var targetId: String? {
        lock.withLock { target?.targetId }
    }

    // MARK: - One per session

    private final class WeakKey {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    private struct Entry {
        let key: WeakKey
        let runner: ChromiumRunner
    }

    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: Entry] = [:]

    /// The session's runner in `browser` — a new one when it had none, or one
    /// in another browser (the lease changed: a relaunch, the network
    /// setting), which goes. Runners of sessions gone meanwhile go too.
    static func runner(for key: AnyObject, browser: ChromiumBrowser,
                       limits: AgentRunLimits = AgentRunLimits()) -> ChromiumRunner {
        var stale: [ChromiumRunner] = []
        let runner: ChromiumRunner = registryLock.withLock {
            for (id, entry) in registry where entry.key.object == nil {
                stale.append(entry.runner)
                registry[id] = nil
            }
            let id = ObjectIdentifier(key)
            if let entry = registry[id] {
                if entry.key.object === key, entry.runner.browser === browser, !entry.runner.isDisposed {
                    return entry.runner
                }
                stale.append(entry.runner)
            }
            let made = ChromiumRunner(browser: browser, limits: limits)
            registry[id] = Entry(key: WeakKey(key), runner: made)
            return made
        }
        for old in stale { old.dispose() }
        return runner
    }

    /// The session's runner goes now (its browser is let go: suspend,
    /// tearDown). A no-op when it has none.
    static func dispose(for key: AnyObject) {
        let runner: ChromiumRunner? = registryLock.withLock {
            registry.removeValue(forKey: ObjectIdentifier(key))?.runner
        }
        runner?.dispose()
    }

    private static func unregister(_ runner: ChromiumRunner) {
        registryLock.withLock {
            for (id, entry) in registry where entry.runner === runner {
                registry[id] = nil
            }
        }
    }

    // MARK: - A run

    /// A fresh world for the next run, with the binding in it; the fence,
    /// the context and the target are made first when there are none. A
    /// target that does not answer within 2 s (a previous script's timers
    /// spinning) is replaced once.
    func open(deadline: ContinuousClock.Instant) async throws -> ChromiumRunWorld {
        var attempt = 0
        while true {
            attempt += 1
            let target = try await ensureTarget(deadline: deadline)
            let run: Int = lock.withLock {
                runs += 1
                targetRuns += 1
                return runs
            }
            let options = CDPCallOptions(deadline: min(deadline, ContinuousClock.now + .seconds(2)))
            do {
                let world = try await connection.call("Page.createIsolatedWorld",
                                                      RunnerFence.isolatedWorldParams(frameId: target.targetId, run: run),
                                                      session: target.sessionId, options: options)
                guard let contextId = world.int("executionContextId") else {
                    throw AgentError.failed("Chromium named no world for the script")
                }
                _ = try await connection.call("Runtime.addBinding",
                                              RunnerFence.addBindingParams(executionContextId: contextId),
                                              session: target.sessionId, options: options)
                return ChromiumRunWorld(contextId: contextId, run: run)
            } catch {
                if error is CancellationError { throw error }
                if let cdp = error as? CDPError, cdp == .cancelled { throw CancellationError() }
                guard attempt < 2, ContinuousClock.now < deadline else { throw error }
                logger.info("runner: \(String(describing: error), privacy: .public); a fresh target")
                await stop()
            }
        }
    }

    /// The run's binding calls (`onCall`, its payload as sent) and the end of
    /// the runner under it (`onEnd`: closed, crashed, Chromium gone). Both on
    /// the reader queue; they must not wait.
    func route(_ world: ChromiumRunWorld, onCall: @escaping @Sendable (String) -> Void,
               onEnd: @escaping @Sendable (String) -> Void) {
        lock.withLock { route = Route(contextId: world.contextId, onCall: onCall, onEnd: onEnd) }
    }

    func unroute() {
        lock.withLock { route = nil }
    }

    /// `Runtime.evaluate` in a run's world, by value: its raw result, with
    /// `exceptionDetails` when the expression threw (a SyntaxError).
    func evaluate(_ expression: String, contextId: Int, awaitPromise: Bool,
                  deadline: ContinuousClock.Instant) async throws -> CDPObject {
        guard let target = lock.withLock({ self.target }) else {
            throw AgentError.unavailable("the script's sandbox is gone")
        }
        let params: [String: Any] = [
            "expression": expression,
            "contextId": contextId,
            "awaitPromise": awaitPromise,
            "returnByValue": true,
            "silent": true,
        ]
        return try await connection.call("Runtime.evaluate", params, session: target.sessionId,
                                          options: CDPCallOptions(deadline: deadline))
    }

    /// A page call's answer, into the run's world. Never waited for: a world
    /// gone meanwhile (the run stopped) only logs.
    func deliver(reply json: String, contextId: Int) {
        call(Self.replyFunction, json, contextId: contextId)
    }

    /// An event (a dialog the page opened) for the facade's handlers.
    func deliver(event json: String, contextId: Int) {
        call(Self.eventFunction, json, contextId: contextId)
    }

    private func call(_ function: String, _ argument: String, contextId: Int) {
        guard let target = lock.withLock({ self.target }) else { return }
        let arguments: [[String: Any]] = [["value": argument]]
        let params: [String: Any] = [
            "functionDeclaration": function,
            "executionContextId": contextId,
            "arguments": arguments,
            "silent": true,
        ]
        let reply = connection.post("Runtime.callFunctionOn", params, session: target.sessionId,
                                    options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(5)))
        let logger = self.logger
        Task {
            do {
                let result = try await reply.value()
                if let exception = result.object("exceptionDetails") {
                    logger.info("runner: a reply was refused: \(ChromiumHelper.describe(exception), privacy: .public)")
                }
            } catch {
                logger.debug("runner: a reply was not delivered: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The runner's JavaScript heap in bytes; nil when it does not answer
    /// (busy: a script spinning cannot be sampled).
    func heapUsed(limit: Duration = .milliseconds(400)) async -> Int? {
        guard let target = lock.withLock({ self.target }) else { return nil }
        guard let usage = try? await connection.call("Runtime.getHeapUsage", [:], session: target.sessionId,
                                                     options: CDPCallOptions(deadline: ContinuousClock.now + limit)),
              let used = usage.double("usedSize") else { return nil }
        return Int(used)
    }

    /// The stop ladder: the script stopped (Runtime.terminateExecution), the
    /// target closed within 1 s — else crashed (`Page.crash`, from its IO
    /// thread) and closed again. The next run makes a fresh target, which
    /// also clears a termination still pending ("terminates the current or
    /// next execution"). The context stays.
    func stop() async {
        let current: ChromiumTarget? = lock.withLock {
            route = nil
            return target
        }
        guard let current else { return }
        _ = try? await connection.call("Runtime.terminateExecution", [:], session: current.sessionId,
                                       options: CDPCallOptions(deadline: ContinuousClock.now + .milliseconds(250)))
        browser.closeTarget(current.targetId)
        if await waitGone(current, upTo: .seconds(1)) { return }
        logger.info("runner: \(current.targetId, privacy: .public) did not close in 1 s; crashed")
        connection.post("Page.crash", [:], session: current.sessionId,
                        options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(1)))
        browser.closeTarget(current.targetId)
        _ = await waitGone(current, upTo: .milliseconds(500))
        forget(current)
    }

    /// A run ended: the idle clock starts again.
    func finished() {
        let generation: Int = lock.withLock {
            route = nil
            idleGeneration += 1
            return idleGeneration
        }
        let idle = limits.idleDispose
        Task { [weak self] in
            try? await Task.sleep(for: idle)
            self?.disposeIfIdle(since: generation)
        }
    }

    private func disposeIfIdle(since generation: Int) {
        let idle = lock.withLock { idleGeneration == generation && route == nil && !disposed }
        guard idle else { return }
        dispose()
    }

    /// Everything goes: the target, the context, the fence.
    func dispose() {
        let state: (ChromiumTarget?, String?, ChromiumFence?, Route?) = lock.withLock {
            let held = (target, contextId, fence, route)
            disposed = true
            target = nil
            contextId = nil
            fence = nil
            route = nil
            return held
        }
        Self.unregister(self)
        if let target = state.0 {
            connection.setSink(nil, for: target.sessionId)
            if !browser.isClosed { browser.closeTarget(target.targetId) }
        }
        if let context = state.1, !browser.isClosed {
            browser.disposeBrowserContext(context)
        }
        browser.removeOwner(self)
        state.3?.onEnd("the script's sandbox was closed")
        // Blocks until the listener is closed; never called on the fence's queue.
        state.2?.stop()
    }

    // MARK: - Making it

    private func ensureTarget(deadline: ContinuousClock.Instant) async throws -> ChromiumTarget {
        if browser.isClosed { throw AgentError.unavailable(browser.closeReason ?? "Chromium stopped") }
        let state: (ChromiumTarget?, Bool, Bool) = lock.withLock {
            var recycled: ChromiumTarget?
            if let target, crashed || targetRuns >= limits.recycleAfterRuns {
                recycled = target
                self.target = nil
                crashed = false
                targetRuns = 0
            }
            return (recycled, self.target != nil, disposed)
        }
        if state.2 { throw AgentError.unavailable("the script's sandbox was closed") }
        if let old = state.0 {
            forget(old)
            browser.closeTarget(old.targetId)
        }
        if state.1, let live = lock.withLock({ target }) { return live }

        let context = try await ensureContext(deadline: deadline)
        let left = max(Duration.seconds(1), min(Duration.seconds(10), ContinuousClock.now.duration(to: deadline)))
        let made = try await browser.createTarget(url: "about:blank", browserContextId: context, owner: self,
                                                  timeout: left)
        connection.setSink(self, for: made.sessionId)
        lock.withLock {
            target = made
            crashed = false
            targetRuns = 0
        }
        let replies = connection.post(batch: RunnerFence.targetInit(), session: made.sessionId,
                                      options: CDPCallOptions(deadline: ContinuousClock.now + left))
        for reply in replies {
            do {
                _ = try await reply.value()
            } catch {
                if RunnerFence.optionalInitMethods.contains(reply.method) {
                    logger.info("runner: \(reply.method, privacy: .public) was refused")
                    continue
                }
                forget(made)
                browser.closeTarget(made.targetId)
                throw AgentError.unavailable("the script's sandbox could not be fenced (\(reply.method) was refused)")
            }
        }
        return made
    }

    private func ensureContext(deadline: ContinuousClock.Instant) async throws -> String {
        if let existing = lock.withLock({ contextId }) { return existing }
        let held: ChromiumFence? = lock.withLock { fence }
        let listening: ChromiumFence
        if let held, held.isListening {
            listening = held
        } else {
            do {
                listening = try ChromiumFence.start()
            } catch {
                // Fail closed: no runner without its fence.
                throw AgentError.unavailable("the script's sandbox could not be fenced off the network (\(error))")
            }
            lock.withLock { fence = listening }
        }
        let left = max(Duration.seconds(1), min(Duration.seconds(10), ContinuousClock.now.duration(to: deadline)))
        let created = try await browser.createRunnerContext(proxyServer: RunnerFence.proxyServer(port: listening.port),
                                                            timeout: left)
        let keep: Bool = lock.withLock {
            guard !disposed else { return false }
            contextId = created
            return true
        }
        if !keep {
            browser.disposeBrowserContext(created)
            throw AgentError.unavailable("the script's sandbox was closed")
        }
        return created
    }

    private func waitGone(_ watched: ChromiumTarget, upTo limit: Duration) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            let gone = lock.withLock { target?.targetId != watched.targetId }
            if gone || browser.isClosed { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { target?.targetId != watched.targetId }
    }

    private func forget(_ old: ChromiumTarget) {
        lock.withLock {
            if target?.targetId == old.targetId { target = nil }
        }
        connection.setSink(nil, for: old.sessionId)
    }

    private func ended(_ reason: String) {
        let current: Route? = lock.withLock {
            let held = route
            route = nil
            return held
        }
        current?.onEnd(reason)
    }

    // MARK: - CDPEventSink (reader queue)

    func handle(method: String, params: CDPObject, session: CDPSessionID?) {
        switch method {
        case "Runtime.bindingCalled":
            guard params.string("name") == RunnerFence.bindingName, let payload = params.string("payload") else { return }
            let current: Route? = lock.withLock { route }
            // Another world's call — an earlier run's timer — is no call of this run.
            guard let current, params.int("executionContextId") == current.contextId else { return }
            current.onCall(payload)
        case "Fetch.requestPaused":
            guard let requestId = params.string("requestId"), let session else { return }
            let fail = RunnerFence.failRequest(requestId: requestId)
            connection.post(fail.0, fail.1, session: session,
                            options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(5)))
        case "Page.javascriptDialogOpening":
            guard let session else { return }
            let dismiss = RunnerFence.dismissDialog()
            connection.post(dismiss.0, dismiss.1, session: session,
                            options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(5)))
        case "Inspector.targetCrashed":
            lock.withLock { crashed = true }
            ended("the script's sandbox crashed (out of memory?)")
        default:
            break
        }
    }

    // MARK: - ChromiumTargetOwner (reader queue)

    /// A popup of the runner: it runs (its opener would stay blocked), then goes.
    func attached(target popup: ChromiumTarget, openerTargetId: String?, url: String) {
        browser.resume(popup)
        browser.closeTarget(popup.targetId)
    }

    func detached(targetId: String) {
        let ours: Bool = lock.withLock {
            guard target?.targetId == targetId else { return false }
            target = nil
            return true
        }
        if ours { ended("the script's sandbox was closed") }
    }

    func crashed(targetId: String) {
        let ours: Bool = lock.withLock {
            guard target?.targetId == targetId else { return false }
            crashed = true
            return true
        }
        if ours { ended("the script's sandbox crashed (out of memory?)") }
    }

    func downloadStarted(targetId: String, url: String) {}

    func browserClosed(reason: String) {
        let fenceToStop: ChromiumFence? = lock.withLock {
            disposed = true
            target = nil
            contextId = nil
            let held = fence
            fence = nil
            return held
        }
        ended(reason)
        Self.unregister(self)
        fenceToStop?.stop()
    }
}
