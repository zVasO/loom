import Dispatch
import Foundation

// RunnerFence — what keeps browser_run_code's runner off the network
// (run-code design §1.1, §6; the plan's "proxy ChromiumFence sans
// exception"). The runner is a target of its own, in a browser context of
// its own, where the agent's script runs in a fresh isolated world; its only
// way out is one binding to Loom. Three layers, each enough on its own
// (Tests/AgentBrowserCDP/runcode.test.mjs, both binaries):
//
//   1. the context's proxy is a ChromiumFence (a listener that closes every
//      connection), with `<-loopback>` and nothing after it: loopback goes
//      to the fence too — every request of the context, workers and
//      WebSockets included;
//   2. Fetch fails every request at its start (BlockedByClient), answered on
//      the reader queue by the runner's sink;
//   3. the network is emulated offline (`navigator.onLine` false).
//
// The facade also takes the network APIs out of the run's world: defense in
// depth, not the boundary. Pure parameter builders, plus the context's
// creation on ChromiumBrowser (its denials are the default context's).

public enum RunnerFence {

    /// The binding the facade posts its page calls to (`Runtime.bindingCalled`).
    public static let bindingName = "__loomRunCall"
    /// A run's world is `loom-run-<n>`: Chromium hands back an existing world
    /// for a name it knows, and every run must start from a clean realm.
    public static let worldPrefix = "loom-run-"
    /// What a failed request reports in the runner (`net::ERR_BLOCKED_BY_CLIENT`).
    public static let failReason = "BlockedByClient"
    /// Every proxy rule Chromium would otherwise add by itself (loopback,
    /// link-local) removed — and none added: everything meets the fence.
    public static let bypassList = "<-loopback>"

    /// The fence's address as the context's proxy.
    public static func proxyServer(port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    /// `Target.createBrowserContext`: in memory, gone when the browser
    /// session ends, every request through `proxyServer`.
    public static func contextParams(proxyServer: String) -> [String: Any] {
        ["disposeOnDetach": true, "proxyServer": proxyServer, "proxyBypassList": bypassList]
    }

    /// `Fetch.enable`: every request paused at its start — and failed.
    public static var fetchEnableParams: [String: Any] {
        let pattern: [String: Any] = ["urlPattern": "*", "requestStage": "Request"]
        return ["patterns": [pattern]]
    }

    /// The answer to a `Fetch.requestPaused` of the runner: it fails.
    public static func failRequest(requestId: String) -> (String, [String: Any]) {
        ("Fetch.failRequest", ["requestId": requestId, "errorReason": failReason])
    }

    /// `Network.emulateNetworkConditions` offline (accepted without
    /// `Network.enable`: no network event ever reaches Loom from the runner).
    public static var offlineParams: [String: Any] {
        ["offline": true, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1]
    }

    /// A dialog in the runner (the facade takes alert, confirm and prompt
    /// away; a stray one never blocks it): dismissed at once.
    public static func dismissDialog() -> (String, [String: Any]) {
        ("Page.handleJavaScriptDialog", ["accept": false])
    }

    /// The runner target's init, in ONE write, ending with the resume: the
    /// fence's two in-target layers, dialogs reported (to be dismissed), its
    /// timers and frames at full speed. No `Runtime.enable`: the binding is
    /// added to each run's world by its id, and the facade keeps the script's
    /// console itself.
    public static func targetInit() -> [(String, [String: Any])] {
        let empty: [String: Any] = [:]
        let enabled: [String: Any] = ["enabled": true]
        return [
            ("Fetch.enable", fetchEnableParams),
            ("Network.emulateNetworkConditions", offlineParams),
            ("Page.enable", empty),
            ("Emulation.setFocusEmulationEnabled", enabled),
            ("Runtime.runIfWaitingForDebugger", empty),
        ]
    }

    /// Init commands the runner may refuse and still be used: its focus
    /// emulation, and the resume of a target that already runs.
    public static let optionalInitMethods: Set<String> = [
        "Emulation.setFocusEmulationEnabled", "Runtime.runIfWaitingForDebugger",
    ]

    public static func worldName(run: Int) -> String {
        worldPrefix + String(run)
    }

    /// `Page.createIsolatedWorld` in the runner's main frame (its frame id is
    /// its target id) for run `run`; no universal access.
    public static func isolatedWorldParams(frameId: String, run: Int) -> [String: Any] {
        ["frameId": frameId, "worldName": worldName(run: run), "grantUniveralAccess": false]
    }

    /// `Runtime.addBinding` into ONE world, by id: added without
    /// `Runtime.enable`, a binding reaches only the contexts that exist
    /// (step-0 probe) — exactly the run's.
    public static func addBindingParams(executionContextId: Int) -> [String: Any] {
        ["name": bindingName, "executionContextId": executionContextId]
    }
}

extension ChromiumBrowser {

    /// The runner's context: fenced (RunnerFence), with the downloads and
    /// permissions of every other context denied. Disposed again if the
    /// download denial fails. Throws `CDPError` or `ChromiumBrowserError`.
    public func createRunnerContext(proxyServer: String, timeout: Duration = .seconds(10)) async throws -> String {
        let options = CDPCallOptions(deadline: ContinuousClock.now + timeout)
        let result = try await connection.call("Target.createBrowserContext",
                                               RunnerFence.contextParams(proxyServer: proxyServer),
                                               session: nil, options: options)
        guard let contextId = result.string("browserContextId") else {
            throw ChromiumBrowserError.missingBrowserContextId
        }
        let replies = connection.post(batch: Self.denials(browserContextId: contextId), session: nil, options: options)
        for reply in replies {
            do {
                _ = try await reply.value()
            } catch {
                if reply.method == "Browser.setPermission" { continue }
                disposeBrowserContext(contextId)
                throw ChromiumBrowserError.contextSetupFailed(Self.describe(error))
            }
        }
        return contextId
    }
}
