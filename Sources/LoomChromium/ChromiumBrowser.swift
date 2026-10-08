import Darwin
import Dispatch
import Foundation

// ChromiumBrowser — the browser (root) session of one Chromium process, and
// the router of its page targets (ADR-0016).
//
// Lifecycle
//   init(process:version:)      a Chromium spawned and ready (ChromiumPool does it)
//   init(connection:version:)   any connection — the tests' in-process peer
//   start()                     one write: target discovery, paused auto-attach,
//                               downloads and permissions denied
//   shutdown(grace:reason:)     Browser.close, then the process's ladder
//   waitUntilClosed()           the reason, once the process or the pipe is gone
//
// Targets
//   createTarget(url:browserContextId:owner:)  Target.createTarget{newWindow:true}
//       → ChromiumTarget {targetId, sessionId}, attached and PAUSED (waiting for
//       the debugger). The owner sets its session sink, sends its per-target
//       init, then calls resume(_:) — Runtime.runIfWaitingForDebugger. Only
//       http(s) and about:blank are opened: Chromium itself would commit file:,
//       data:, chrome:// and run javascript:.
//   resume(_:), closeTarget(_:)                 posts, never wait: callable on the reader queue
//   createBrowserContext(), disposeBrowserContext(_:)   private sessions
//   addOwner(_:), removeOwner(_:)                browserClosed without a target yet
//
// Routing (the root sink, on the connection's reader queue, in wire order)
//   Target.attachedToTarget   a created target → its createTarget call; a popup
//                             (openerId) → attached(…) of the opener's owner,
//                             synchronously, whatever commands are pending: the
//                             opener's window.open — and the click or evaluate
//                             that called it — stays blocked until the popup
//                             runs. Anything else is closed.
//   Target.targetInfoChanged  → targetInfoChanged(targetId:url:title:)
//   Target.targetCrashed      the session's pending calls fail (.crashed) → crashed(targetId:)
//   Target.detachedFromTarget, Target.targetDestroyed
//                             the session's pending calls fail (.detached), its
//                             sink goes → detached(targetId:)
//   Browser.downloadWillBegin the frame's owner → downloadStarted(targetId:url:)
//   the process or the pipe gone → browserClosed(reason:) to every owner, once

/// A page target of the agent's Chromium, attached over a flattened session.
public struct ChromiumTarget: Hashable, Sendable {
    public let targetId: String
    public let sessionId: CDPSessionID
    /// As Chromium reports it: the default context's id for a project's tab,
    /// the private session's own otherwise; nil when it says none.
    public let browserContextId: String?

    public init(targetId: String, sessionId: CDPSessionID, browserContextId: String?) {
        self.targetId = targetId
        self.sessionId = sessionId
        self.browserContextId = browserContextId
    }
}

/// Who answers for a set of targets: a session's engine. Held weakly by the
/// router. Every call but `browserClosed` comes on the connection's reader
/// queue, in wire order: an owner applies it at once, may `post`, `setSink`,
/// `resume` or `closeTarget`, and never waits there for a reply.
public protocol ChromiumTargetOwner: AnyObject, Sendable {
    /// A popup one of the owner's pages opened, attached and paused: allowed,
    /// it gets the per-target init then `resume`; refused, `closeTarget`.
    /// `url` is often empty this early; `targetInfoChanged` brings it.
    func attached(target: ChromiumTarget, openerTargetId: String?, url: String)
    func targetInfoChanged(targetId: String, url: String, title: String)
    /// Closed, or gone with its renderer: the session is dead.
    func detached(targetId: String)
    /// The renderer crashed; the target stays, `Page.reload` brings it back.
    func crashed(targetId: String)
    /// Refused at the browser level (`Browser.setDownloadBehavior` deny).
    func downloadStarted(targetId: String, url: String)
    /// The process or its pipe is gone; every target with it. Any thread.
    func browserClosed(reason: String)
    /// The page target holding a frame that is not a main frame (a main
    /// frame's id is its target's id): how a subframe's download is routed.
    func target(ofFrame frameId: String) -> String?
}

extension ChromiumTargetOwner {
    public func targetInfoChanged(targetId: String, url: String, title: String) {}
    public func target(ofFrame frameId: String) -> String? { nil }
}

public enum ChromiumBrowserError: Error, Equatable, Sendable, CustomStringConvertible {
    /// createTarget opens http(s) and about:blank only.
    case refusedURL(String)
    case startFailed(method: String, reason: String)
    case missingTargetId
    case missingBrowserContextId
    /// The target was created, but never attached.
    case attachTimedOut(targetId: String)
    case cancelled
    case closed(String)
    case contextSetupFailed(String)

    public var description: String {
        switch self {
        case .refusedURL(let url):
            return "the agent's browser opens http(s) addresses only, not \(url)"
        case .startFailed(let method, let reason):
            return "Chromium refused \(method): \(reason)"
        case .missingTargetId:
            return "Chromium created a tab without naming it"
        case .missingBrowserContextId:
            return "Chromium created a private context without naming it"
        case .attachTimedOut(let targetId):
            return "Chromium never attached the new tab \(targetId)"
        case .cancelled:
            return "cancelled"
        case .closed(let reason):
            return reason
        case .contextSetupFailed(let reason):
            return "the private context could not be set up: \(reason)"
        }
    }
}

public final class ChromiumBrowser: @unchecked Sendable {

    /// Denied for every origin, in every context: camera and microphone have
    /// no usage string in Loom's Info.plist, and the rest is never the
    /// agent's to grant. `display-capture`, not `displayCapture`: Chromium
    /// rejects the latter.
    public static let deniedPermissions = ["camera", "microphone", "geolocation", "notifications", "midi",
                                           "display-capture"]

    public let connection: CDPConnection
    public let version: ChromiumVersion
    /// nil for a browser on a bare connection (tests).
    public let process: ChromiumProcess?

    private let log: @Sendable (String) -> Void
    private let sink: RootSink
    private let closedSignal = ChromiumOnce<String>()

    // Guarded by `lock`.
    private let lock = NSLock()
    private var owners: [String: WeakOwner] = [:]
    private var liveTargets: [String: ChromiumTarget] = [:]
    private var targetsBySession: [CDPSessionID: String] = [:]
    private var watchers: [ObjectIdentifier: WeakOwner] = [:]
    private var pendingCreates: [String: PendingCreate] = [:]
    /// Attached with no owner known: our own creation whose reply is not in
    /// yet, or a stray (the startup tab). Closed once no creation is in
    /// flight and one of our targets exists — never the browser's last window.
    private var unclaimed: [String: ChromiumTarget] = [:]
    private var creationsInFlight = 0
    private var hasOwnTarget = false
    private var closingReason: String?
    private var closedReason: String?

    private struct PendingCreate {
        let owner: WeakOwner
        let waiter: ChromiumOnce<Result<ChromiumTarget, ChromiumBrowserError>>
    }

    public convenience init(process: ChromiumProcess, version: ChromiumVersion,
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(connection: process.connection, version: version, process: process, log: log)
    }

    /// The connection is started here if no one did yet; its end is this browser's end.
    public convenience init(connection: CDPConnection, version: ChromiumVersion,
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(connection: connection, version: version, process: nil, log: log)
    }

    private init(connection: CDPConnection, version: ChromiumVersion, process: ChromiumProcess?,
                 log: @escaping @Sendable (String) -> Void) {
        self.connection = connection
        self.version = version
        self.process = process
        self.log = log
        self.sink = RootSink()
        sink.browser = self
        connection.setSink(sink, for: nil)
        // A no-op when ChromiumProcess already started it: its exit says more.
        connection.start(onClose: { [weak self] reason in
            self?.markClosed("Chromium stopped (\(reason))")
        })
        if let process {
            Task { [weak self] in
                let exit = await process.exited()
                self?.markClosed("Chromium stopped (\(exit))")
            }
        }
    }

    public var pid: pid_t? { process?.pid }
    public var stderrTail: String { process?.stderrTail ?? "" }

    public var isClosed: Bool {
        lock.withLock { closedReason != nil }
    }

    /// Why it closed; nil while it runs.
    public var closeReason: String? {
        lock.withLock { closedReason }
    }

    /// Returns once the process or its pipe is gone, with the reason owners got.
    public func waitUntilClosed() async -> String {
        await closedSignal.wait()
    }

    // MARK: - Start and stop

    /// One write: discovery of page targets (title, url, crashes), auto-attach
    /// paused on start (a popup cannot run before its policy check), and the
    /// browser-wide denials. A refused permission name is only logged; the
    /// rest must hold, or nothing is launched.
    public func start(timeout: Duration = .seconds(10)) async throws {
        let options = CDPCallOptions(deadline: ContinuousClock.now + timeout)
        let pages: [[String: Any]] = [["type": "page"]]
        var batch: [(String, [String: Any])] = []
        batch.append(("Target.setDiscoverTargets", ["discover": true, "filter": pages]))
        batch.append(("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": true,
                                               "flatten": true, "filter": pages]))
        batch.append(contentsOf: Self.denials(browserContextId: nil))
        let replies = connection.post(batch: batch, session: nil, options: options)
        for reply in replies {
            do {
                _ = try await reply.value()
            } catch {
                let reason = Self.describe(error)
                if reply.method == "Browser.setPermission" {
                    log("chromium: a permission denial was refused: \(reason)")
                    continue
                }
                throw ChromiumBrowserError.startFailed(method: reply.method, reason: reason)
            }
        }
    }

    /// `Browser.close` (cookies flushed), then the process's shutdown ladder.
    /// Owners get `browserClosed(reason:)` with `reason`.
    public func shutdown(grace: Duration = .seconds(2), reason: String = "Chromium was stopped") async {
        lock.withLock {
            if closingReason == nil { closingReason = reason }
        }
        if let process {
            await process.shutdown(grace: grace)
            if await closedSignal.wait(upTo: .seconds(1)) == nil {
                markClosed(reason)
            }
            return
        }
        if !connection.isClosed {
            connection.post("Browser.close", [:], session: nil,
                            options: CDPCallOptions(deadline: ContinuousClock.now + grace))
        }
        if await closedSignal.wait(upTo: grace) != nil { return }
        connection.close()
        if await closedSignal.wait(upTo: .seconds(1)) != nil { return }
        markClosed(reason)
    }

    // MARK: - Targets

    /// What createTarget may open: http(s) with a host, or about:blank.
    public static func isOpenable(_ url: String) -> Bool {
        if url.lowercased() == "about:blank" { return true }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return !(parsed.host() ?? "").isEmpty
    }

    /// A new tab in a window of its own (`newWindow:true`: in the full
    /// browser, a background tab of a shared window stops rendering), attached
    /// and paused. The owner then gets its events; `resume` lets it run.
    /// Throws `CDPError` or `ChromiumBrowserError`.
    public func createTarget(url: String = "about:blank", browserContextId: String? = nil,
                             owner: ChromiumTargetOwner, timeout: Duration = .seconds(10)) async throws -> ChromiumTarget {
        guard Self.isOpenable(url) else { throw ChromiumBrowserError.refusedURL(url) }
        let deadline = ContinuousClock.now + timeout
        let weakOwner = WeakOwner(owner)
        lock.lock()
        if let reason = closedReason {
            lock.unlock()
            throw ChromiumBrowserError.closed(reason)
        }
        creationsInFlight += 1
        watchers[ObjectIdentifier(owner)] = weakOwner
        lock.unlock()

        var claimed = false
        defer { creationEnded(claimed: claimed) }

        var params: [String: Any] = ["url": url, "newWindow": true]
        if let browserContextId { params["browserContextId"] = browserContextId }
        let result = try await connection.call("Target.createTarget", params, session: nil,
                                               options: CDPCallOptions(deadline: deadline))
        guard let targetId = result.string("targetId") else { throw ChromiumBrowserError.missingTargetId }

        // The attach may have come first (it is parked), or be on its way.
        let waiter = ChromiumOnce<Result<ChromiumTarget, ChromiumBrowserError>>()
        lock.lock()
        if let reason = closedReason {
            lock.unlock()
            throw ChromiumBrowserError.closed(reason)
        }
        if let target = unclaimed.removeValue(forKey: targetId) {
            register(target, owner: weakOwner)
            lock.unlock()
            claimed = true
            return target
        }
        pendingCreates[targetId] = PendingCreate(owner: weakOwner, waiter: waiter)
        lock.unlock()

        let timer = DispatchWorkItem {
            _ = waiter.set(.failure(.attachTimedOut(targetId: targetId)))
        }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + .milliseconds(Self.milliseconds(until: deadline)), execute: timer)
        let outcome = await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            _ = waiter.set(.failure(.cancelled))
        }
        timer.cancel()
        switch outcome {
        case .success(let target):
            claimed = true
            return target
        case .failure(let error):
            lock.withLock { pendingCreates[targetId] = nil }
            closeTarget(targetId)
            throw error
        }
    }

    /// Runtime.runIfWaitingForDebugger on the target's session: it runs.
    @discardableResult
    public func resume(_ target: ChromiumTarget) -> CDPReply {
        connection.post("Runtime.runIfWaitingForDebugger", [:], session: target.sessionId,
                        options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(10)))
    }

    /// Never runs `beforeunload`. The detach that follows reaches the owner.
    @discardableResult
    public func closeTarget(_ targetId: String) -> CDPReply {
        connection.post("Target.closeTarget", ["targetId": targetId], session: nil,
                        options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(5)))
    }

    /// The targets an owner holds now.
    public func targets(of owner: ChromiumTargetOwner) -> [ChromiumTarget] {
        lock.withLock {
            owners.compactMap { entry -> ChromiumTarget? in
                guard entry.value.owner === owner else { return nil }
                return liveTargets[entry.key]
            }
        }
    }

    // MARK: - Owners

    /// The owner hears `browserClosed` even before its first target; at once
    /// if the browser is already gone.
    public func addOwner(_ owner: ChromiumTargetOwner) {
        lock.lock()
        let reason = closedReason
        if reason == nil {
            watchers[ObjectIdentifier(owner)] = WeakOwner(owner)
        }
        lock.unlock()
        if let reason { owner.browserClosed(reason: reason) }
    }

    /// Hears nothing more; its targets stay open (closing them is its call).
    public func removeOwner(_ owner: ChromiumTargetOwner) {
        lock.withLock {
            watchers[ObjectIdentifier(owner)] = nil
            for (targetId, entry) in owners where entry.owner === owner || entry.owner == nil {
                owners[targetId] = nil
            }
        }
    }

    // MARK: - Private contexts

    /// A throwaway context for a private session: in memory, disposed with
    /// the browser session, downloads and permissions denied like the default
    /// one. Fails — and is disposed — if downloads cannot be denied.
    public func createBrowserContext(timeout: Duration = .seconds(10)) async throws -> String {
        let options = CDPCallOptions(deadline: ContinuousClock.now + timeout)
        let result = try await connection.call("Target.createBrowserContext", ["disposeOnDetach": true],
                                               session: nil, options: options)
        guard let contextId = result.string("browserContextId") else {
            throw ChromiumBrowserError.missingBrowserContextId
        }
        let replies = connection.post(batch: Self.denials(browserContextId: contextId), session: nil,
                                      options: options)
        for reply in replies {
            do {
                _ = try await reply.value()
            } catch {
                let reason = Self.describe(error)
                if reply.method == "Browser.setPermission" {
                    log("chromium: a permission denial was refused in \(contextId): \(reason)")
                    continue
                }
                disposeBrowserContext(contextId)
                throw ChromiumBrowserError.contextSetupFailed(reason)
            }
        }
        return contextId
    }

    /// The default context's session cookies (no expiry: Chromium keeps
    /// them in memory only, and they go with the process). Empty when it
    /// cannot say in time.
    public func sessionCookies(timeout: Duration = .seconds(2)) async -> [CDPObject] {
        guard !isClosed else { return [] }
        let options = CDPCallOptions(deadline: ContinuousClock.now + timeout)
        guard let result = try? await connection.call("Storage.getCookies", [:], session: nil, options: options) else {
            return []
        }
        return (result.objects("cookies") ?? []).filter { $0.bool("session") == true }
    }

    /// Puts back what `sessionCookies` read, as Chromium wrote it (measured:
    /// `Storage.setCookies` takes its own cookie objects).
    public func restoreCookies(_ cookies: [CDPObject], timeout: Duration = .seconds(2)) async {
        guard !cookies.isEmpty, !isClosed else { return }
        let options = CDPCallOptions(deadline: ContinuousClock.now + timeout)
        _ = try? await connection.call("Storage.setCookies", ["cookies": cookies.map(\.raw)], session: nil,
                                       options: options)
    }

    /// Closes the context's targets and forgets everything it held.
    @discardableResult
    public func disposeBrowserContext(_ browserContextId: String) -> CDPReply {
        connection.post("Target.disposeBrowserContext", ["browserContextId": browserContextId], session: nil,
                        options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(5)))
    }

    /// `Browser.setDownloadBehavior` deny, then the permission denials.
    static func denials(browserContextId: String?) -> [(String, [String: Any])] {
        var download: [String: Any] = ["behavior": "deny", "eventsEnabled": true]
        if let browserContextId { download["browserContextId"] = browserContextId }
        var batch: [(String, [String: Any])] = [("Browser.setDownloadBehavior", download)]
        for name in deniedPermissions {
            var params: [String: Any] = ["permission": ["name": name], "setting": "denied"]
            if let browserContextId { params["browserContextId"] = browserContextId }
            batch.append(("Browser.setPermission", params))
        }
        return batch
    }

    // MARK: - Root events (reader queue)

    fileprivate func handleRoot(method: String, params: CDPObject) {
        switch method {
        case "Target.attachedToTarget":
            attachedToTarget(params)
        case "Target.detachedFromTarget":
            targetGone(targetId: params.string("targetId"), session: params.string("sessionId").map { CDPSessionID($0) })
        case "Target.targetDestroyed":
            targetGone(targetId: params.string("targetId"), session: nil)
        case "Target.targetCrashed":
            if let targetId = params.string("targetId") { targetCrashed(targetId) }
        case "Target.targetInfoChanged":
            if let info = params.object("targetInfo") { targetInfoChanged(info) }
        case "Browser.downloadWillBegin":
            downloadWillBegin(frameId: params.string("frameId") ?? "", url: params.string("url") ?? "")
        default:
            break
        }
    }

    private func attachedToTarget(_ params: CDPObject) {
        guard let info = params.object("targetInfo"), let targetId = info.string("targetId"),
              let session = params.string("sessionId") else { return }
        // Root auto-attach is filtered to pages; anything else is not ours to drive.
        guard (info.string("type") ?? "page") == "page" else { return }
        let target = ChromiumTarget(targetId: targetId, sessionId: CDPSessionID(session),
                                    browserContextId: info.string("browserContextId"))
        let openerId = info.string("openerId").flatMap { $0.isEmpty ? nil : $0 }
        let url = info.string("url") ?? ""

        lock.lock()
        if closedReason != nil {
            lock.unlock()
            return
        }
        if let pending = pendingCreates.removeValue(forKey: targetId) {
            register(target, owner: pending.owner)
            lock.unlock()
            if !pending.waiter.set(.success(target)) {
                // Its creator gave up meanwhile: nobody's.
                lock.withLock { unregister(targetId) }
                closeTarget(targetId)
            }
            return
        }
        if let openerId, let entry = owners[openerId], let owner = entry.owner {
            register(target, owner: entry)
            lock.unlock()
            // Synchronously, here: the opener is blocked until this popup runs.
            owner.attached(target: target, openerTargetId: openerId, url: url)
            return
        }
        let closeNow = openerId != nil || (creationsInFlight == 0 && hasOwnTarget)
        if !closeNow {
            unclaimed[targetId] = target
        }
        lock.unlock()
        if closeNow {
            log("chromium: a tab nobody owns was closed (\(targetId))")
            // A popup closed while still paused leaves its opener's
            // window.open blocked for good: it runs first, then goes.
            if openerId != nil, params.bool("waitingForDebugger") ?? true {
                resume(target)
            }
            closeTarget(targetId)
        }
    }

    private func targetGone(targetId: String?, session: CDPSessionID?) {
        lock.lock()
        var resolved = targetId
        if resolved == nil, let session { resolved = targetsBySession[session] }
        guard let resolvedId = resolved else {
            lock.unlock()
            return
        }
        unclaimed[resolvedId] = nil
        guard let target = liveTargets[resolvedId] else {
            lock.unlock()
            return
        }
        let owner = owners[resolvedId]?.owner
        unregister(resolvedId)
        lock.unlock()
        // Nothing will answer them now. Before the owner hears of it, so a
        // call it makes in `detached` is not failed with them.
        connection.failAll(session: target.sessionId, .interrupted(.detached))
        connection.setSink(nil, for: target.sessionId)
        owner?.detached(targetId: resolvedId)
    }

    private func targetCrashed(_ targetId: String) {
        lock.lock()
        let target = liveTargets[targetId]
        let owner = owners[targetId]?.owner
        lock.unlock()
        guard let target else { return }
        connection.failAll(session: target.sessionId, .interrupted(.crashed))
        owner?.crashed(targetId: targetId)
    }

    private func targetInfoChanged(_ info: CDPObject) {
        guard let targetId = info.string("targetId") else { return }
        let owner = lock.withLock { owners[targetId]?.owner }
        owner?.targetInfoChanged(targetId: targetId, url: info.string("url") ?? "", title: info.string("title") ?? "")
    }

    private func downloadWillBegin(frameId: String, url: String) {
        lock.lock()
        let mainFrameOwner = owners[frameId]?.owner
        let everyone = distinctOwners()
        lock.unlock()
        if let mainFrameOwner {
            mainFrameOwner.downloadStarted(targetId: frameId, url: url)
            return
        }
        for owner in everyone {
            if let targetId = owner.target(ofFrame: frameId) {
                owner.downloadStarted(targetId: targetId, url: url)
                return
            }
        }
        log("chromium: a download from an unknown frame was refused: \(url)")
    }

    // MARK: - Bookkeeping (under `lock`)

    private func register(_ target: ChromiumTarget, owner: WeakOwner) {
        owners[target.targetId] = owner
        liveTargets[target.targetId] = target
        targetsBySession[target.sessionId] = target.targetId
        if let live = owner.owner {
            watchers[ObjectIdentifier(live)] = owner
        }
    }

    private func unregister(_ targetId: String) {
        owners[targetId] = nil
        if let target = liveTargets.removeValue(forKey: targetId) {
            targetsBySession[target.sessionId] = nil
        }
    }

    /// Every live owner once, watchers and target owners alike.
    private func distinctOwners() -> [ChromiumTargetOwner] {
        var seen = Set<ObjectIdentifier>()
        var result: [ChromiumTargetOwner] = []
        for entry in Array(watchers.values) + Array(owners.values) {
            guard let owner = entry.owner else { continue }
            if seen.insert(ObjectIdentifier(owner)).inserted { result.append(owner) }
        }
        return result
    }

    /// A createTarget is over. Strays wait until none is in flight — one may
    /// be its own attach, ahead of its reply — and until one of ours exists.
    private func creationEnded(claimed: Bool) {
        lock.lock()
        creationsInFlight -= 1
        if claimed { hasOwnTarget = true }
        var strays: [String] = []
        if creationsInFlight == 0 && hasOwnTarget && closedReason == nil {
            strays = Array(unclaimed.keys)
            unclaimed.removeAll()
        }
        lock.unlock()
        for targetId in strays {
            log("chromium: a tab nobody owns was closed (\(targetId))")
            closeTarget(targetId)
        }
    }

    /// Once: pending creations fail, owners hear `browserClosed`.
    private func markClosed(_ fallback: String) {
        lock.lock()
        guard closedReason == nil else {
            lock.unlock()
            return
        }
        let reason = closingReason ?? fallback
        closedReason = reason
        let notify = distinctOwners()
        let waiting = pendingCreates.values.map { $0.waiter }
        owners.removeAll()
        liveTargets.removeAll()
        targetsBySession.removeAll()
        watchers.removeAll()
        pendingCreates.removeAll()
        unclaimed.removeAll()
        lock.unlock()
        log("chromium: \(reason)")
        for waiter in waiting {
            _ = waiter.set(.failure(.closed(reason)))
        }
        // Owners first: whoever waits for the close (shutdown, the pool) finds them told.
        for owner in notify {
            owner.browserClosed(reason: reason)
        }
        _ = closedSignal.set(reason)
    }

    // MARK: - Helpers

    static func describe(_ error: Error) -> String {
        if let browserError = error as? ChromiumBrowserError { return browserError.description }
        guard let cdp = error as? CDPError else { return String(describing: error) }
        switch cdp {
        case .protocolError(let method, _, let message): return "\(method): \(message)"
        case .timeout(let method): return "\(method) got no answer in time"
        case .interrupted(let interruption): return "interrupted (\(interruption))"
        case .disconnected(let reason): return reason
        case .cancelled: return "cancelled"
        }
    }

    /// Whole milliseconds from now to `deadline`, 0 when past, a day at most.
    static func milliseconds(until deadline: ContinuousClock.Instant) -> Int {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return 0 }
        let parts = left.components
        let seconds = min(parts.seconds, 86_400)
        return Int(seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// The router as the connection's root sink, without the connection holding
/// the browser: the browser owns the connection, not the reverse.
private final class RootSink: CDPEventSink, @unchecked Sendable {
    weak var browser: ChromiumBrowser?

    func handle(method: String, params: CDPObject, session: CDPSessionID?) {
        browser?.handleRoot(method: method, params: params)
    }
}

private final class WeakOwner {
    weak var owner: ChromiumTargetOwner?

    init(_ owner: ChromiumTargetOwner) {
        self.owner = owner
    }
}

/// A value set once, awaited by any number of tasks, before or after.
final class ChromiumOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    init() {}

    var value: Value? {
        lock.withLock { stored }
    }

    /// False if a value was already set: the first one stays.
    @discardableResult
    func set(_ value: Value) -> Bool {
        lock.lock()
        if stored != nil {
            lock.unlock()
            return false
        }
        stored = value
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting {
            waiter.resume(returning: value)
        }
        return true
    }

    func wait() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            lock.lock()
            if let stored {
                lock.unlock()
                continuation.resume(returning: stored)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// The value, if it is set within `limit`.
    func wait(upTo limit: Duration) async -> Value? {
        if let current = value { return current }
        let race = ChromiumOnce<Value?>()
        Task {
            let settled = await self.wait()
            race.set(settled)
        }
        Task {
            try? await Task.sleep(for: limit)
            race.set(nil)
        }
        return await race.wait()
    }
}
