import Testing
@testable import LoomChromium
import Foundation

// browser_run_code's runner off the network (run-code design §1.1): the
// parameters RunnerFence builds, golden — the very ones
// Tests/AgentBrowserCDP/runcode.test.mjs runs on Chromium (no server reached,
// with every layer and with the proxy alone).

@Suite("RunnerFence — the runner's network fence")
struct RunnerFenceTests {

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("the context goes through the fence, loopback included: <-loopback> and nothing bypassed")
    func contexte() throws {
        let proxy = RunnerFence.proxyServer(port: 41_234)
        #expect(proxy == "http://127.0.0.1:41234")
        let params = RunnerFence.contextParams(proxyServer: proxy)
        #expect(try json(params)
                == #"{"disposeOnDetach":true,"proxyBypassList":"<-loopback>","proxyServer":"http://127.0.0.1:41234"}"#)
        #expect(RunnerFence.bypassList == "<-loopback>", "no host after it: nothing goes direct")
    }

    @Test("Fetch pauses every request at its start, and the runner fails it")
    func fetch() throws {
        #expect(try json(RunnerFence.fetchEnableParams) == #"{"patterns":[{"requestStage":"Request","urlPattern":"*"}]}"#)
        let fail = RunnerFence.failRequest(requestId: "interception-7")
        #expect(fail.0 == "Fetch.failRequest")
        #expect(try json(fail.1) == #"{"errorReason":"BlockedByClient","requestId":"interception-7"}"#)
    }

    @Test("offline, with no throughput limit to mean anything else")
    func horsLigne() throws {
        #expect(try json(RunnerFence.offlineParams)
                == #"{"downloadThroughput":-1,"latency":0,"offline":true,"uploadThroughput":-1}"#)
    }

    @Test("the init is one write: Fetch, offline, Page, focus, then the resume — no Runtime.enable")
    func initialisation() {
        let methods = RunnerFence.targetInit().map(\.0)
        #expect(methods == ["Fetch.enable", "Network.emulateNetworkConditions", "Page.enable",
                            "Emulation.setFocusEmulationEnabled", "Runtime.runIfWaitingForDebugger"])
        #expect(!methods.contains("Runtime.enable") && !methods.contains("Network.enable"))
        #expect(methods.last == "Runtime.runIfWaitingForDebugger", "it runs once fenced")
        #expect(RunnerFence.optionalInitMethods.isSubset(of: Set(methods)))
        #expect(!RunnerFence.optionalInitMethods.contains("Fetch.enable"), "a fence layer is never optional")
        #expect(!RunnerFence.optionalInitMethods.contains("Network.emulateNetworkConditions"))
    }

    @Test("each run its own world, by a name never reused; the binding goes into that world only")
    func monde() throws {
        #expect(RunnerFence.worldName(run: 3) == "loom-run-3")
        #expect(try json(RunnerFence.isolatedWorldParams(frameId: "T1", run: 12))
                == #"{"frameId":"T1","grantUniveralAccess":false,"worldName":"loom-run-12"}"#)
        #expect(try json(RunnerFence.addBindingParams(executionContextId: 9))
                == #"{"executionContextId":9,"name":"__loomRunCall"}"#)
        #expect(RunnerFence.bindingName != PageSignals.bindingName, "never the page's console relay")
    }

    @Test("a dialog in the runner is dismissed")
    func dialogue() throws {
        let dismiss = RunnerFence.dismissDialog()
        #expect(dismiss.0 == "Page.handleJavaScriptDialog")
        #expect(try json(dismiss.1) == #"{"accept":false}"#)
    }
}
