import Testing
import LoomChromium
import Foundation

// Seam: a page's DevTools events in, settles, facts and commands out. The
// event sequences are the ones the step-0 probe recorded on the wire
// (28-settle-misc, 20b-binding-variants, 08-dialogs-files); the link and the
// fact handler are recorders, so no pipe and no Chromium are involved.

/// What PageSignals asked of the connection and told its owner.
private final class SignalsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var postsStore: [(String, [String: Any])] = []
    private var interruptsStore: [CDPInterruption] = []
    private var failuresStore: [CDPError] = []
    private var factsStore: [PageFact] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var link: PageSignalsLink {
        PageSignalsLink(
            post: { method, params in self.locked { self.postsStore.append((method, params)) } },
            interrupt: { reason in self.locked { self.interruptsStore.append(reason) } },
            failAll: { error in self.locked { self.failuresStore.append(error) } })
    }

    var factHandler: @Sendable (PageFact) -> Void {
        { fact in self.locked { self.factsStore.append(fact) } }
    }

    var posts: [(String, [String: Any])] { locked { postsStore } }
    var methods: [String] { locked { postsStore.map { $0.0 } } }
    var interrupts: [CDPInterruption] { locked { interruptsStore } }
    var failures: [CDPError] { locked { failuresStore } }
    var facts: [PageFact] { locked { factsStore } }

    func count(_ method: String) -> Int {
        locked { postsStore.filter { $0.0 == method }.count }
    }
}

@Suite("PageSignals — a page's events, settles and facts", .timeLimit(.minutes(1)))
struct PageSignalsTests {

    private let main = "MAIN"
    private let origin = "http://localhost:3000"

    private func signals(_ recorder: SignalsRecorder, mainFrameId: String = "MAIN") -> PageSignals {
        let signals = PageSignals(session: CDPSessionID("S1"), mainFrameId: mainFrameId, link: recorder.link)
        signals.setFactHandler(recorder.factHandler)
        return signals
    }

    private func send(_ signals: PageSignals, _ method: String, _ params: [String: Any]) {
        signals.handle(method: method, params: CDPObject(params), session: CDPSessionID("S1"))
    }

    private func deadline(_ seconds: Int = 5) -> ContinuousClock.Instant {
        ContinuousClock.now + .seconds(seconds)
    }

    // The main frame's events, as Chromium writes them.

    private func requested(_ signals: PageSignals, _ url: String) {
        send(signals, "Page.frameRequestedNavigation",
             ["frameId": main, "reason": "anchorClick", "url": url, "disposition": "currentTab"])
    }

    private func started(_ signals: PageSignals, loader: String, url: String) {
        send(signals, "Page.frameStartedNavigating",
             ["frameId": main, "url": url, "loaderId": loader, "navigationType": "differentDocument"])
        send(signals, "Page.frameStartedLoading", ["frameId": main])
        let request: [String: Any] = ["url": url, "method": "GET"]
        send(signals, "Network.requestWillBeSent",
             ["requestId": loader, "loaderId": loader, "documentURL": url, "type": "Document", "frameId": main,
              "request": request])
    }

    private func commit(_ signals: PageSignals, loader: String, url: String, type: String = "Navigation") {
        let frame: [String: Any] = ["id": main, "loaderId": loader, "url": url, "securityOrigin": origin,
                                    "mimeType": "text/html"]
        send(signals, "Page.frameNavigated", ["frame": frame, "type": type])
    }

    private func lifecycle(_ signals: PageSignals, _ name: String, loader: String) {
        send(signals, "Page.lifecycleEvent", ["frameId": main, "loaderId": loader, "name": name, "timestamp": 1.5])
    }

    private func loaded(_ signals: PageSignals, loader: String, url: String) {
        started(signals, loader: loader, url: url)
        commit(signals, loader: loader, url: url)
        lifecycle(signals, "DOMContentLoaded", loader: loader)
        lifecycle(signals, "load", loader: loader)
        send(signals, "Page.frameStoppedLoading", ["frameId": main])
    }

    private func xhr(_ signals: PageSignals, _ id: String, _ method: String, _ url: String, type: String = "XHR") {
        let request: [String: Any] = ["url": url, "method": method]
        send(signals, "Network.requestWillBeSent",
             ["requestId": id, "loaderId": "L1", "documentURL": origin + "/", "type": type, "frameId": main,
              "request": request])
    }

    private func dialog(_ signals: PageSignals, _ type: String, _ message: String) {
        send(signals, "Page.javascriptDialogOpening",
             ["url": origin + "/", "frameId": main, "message": message, "type": type, "hasBrowserHandler": false,
              "defaultPrompt": ""])
    }

    // MARK: - Settles

    @Test("a link click as the probe saw it: up to the commit before the barrier's reply, the load after")
    func clicSurUnLien() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()

        requested(page, origin + "/next")
        started(page, loader: "L2", url: origin + "/next")
        commit(page, loader: "L2", url: origin + "/next")
        page.noteBarrier(lost: true)   // "Cannot find context with specified id"

        let waiting = Task { await page.wait(.action, from: mark, deadline: deadline()) }
        try? await Task.sleep(for: .milliseconds(20))
        lifecycle(page, "DOMContentLoaded", loader: "L2")
        lifecycle(page, "load", loader: "L2")
        let outcome = await waiting.value
        #expect(outcome == .loaded)

        let state = page.state
        #expect(state.generation == 2)
        #expect(state.loaderId == "L2")
        #expect(state.url == origin + "/next")
        #expect(state.reached == Set(["DOMContentLoaded", "load"]))
        #expect(recorder.count("Runtime.addBinding") == 2, "added again at each commit")
        let interrupts = recorder.interrupts
        #expect(interrupts == [CDPInterruption.navigated, CDPInterruption.navigated],
                "helper calls into a gone document give up")
        let facts = recorder.facts
        let committed = facts.contains(PageFact.committed(url: origin + "/next", loaderId: "L2", generation: 2,
                                                          securityOrigin: origin))
        #expect(committed)
    }

    @Test("everything applied before the wait counts: a load already over answers at once")
    func ordreDesEvenements() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        let mark = page.mark()
        loaded(page, loader: "L1", url: origin + "/")
        let clock = ContinuousClock.now
        let outcome = await page.wait(.navigation(loaderId: "L1"), from: mark, deadline: deadline())
        let elapsed = clock.duration(to: ContinuousClock.now)
        #expect(outcome == .loaded)
        #expect(elapsed < Duration.milliseconds(500))
    }

    @Test("pushState: frameStartedLoading then navigatedWithinDocument — quiet, no load waited for")
    func pushState() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        send(page, "Page.frameStartedLoading", ["frameId": main])
        send(page, "Page.navigatedWithinDocument", ["frameId": main, "url": origin + "/pushed", "navigationType": "historyApi"])
        send(page, "Page.frameStoppedLoading", ["frameId": main])
        page.noteBarrier(lost: false)
        let clock = ContinuousClock.now
        let outcome = await page.wait(.action, from: mark, deadline: deadline())
        let elapsed = clock.duration(to: ContinuousClock.now)
        #expect(outcome == .quiet)
        #expect(elapsed < Duration.milliseconds(500))
        #expect(page.state.url == origin + "/pushed")
        #expect(page.state.generation == 1, "the same document")
        let facts = recorder.facts
        #expect(facts.contains(PageFact.sameDocument(url: origin + "/pushed")))
    }

    @Test("a fetch the click starts is waited for; a polling request is not")
    func fetchEtSondage() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        xhr(page, "poll-1", "GET", origin + "/poll?t=1")
        let mark = page.mark()
        let pollKey = "GET " + origin + "/poll"
        #expect(mark.pollKeys.contains(pollKey))

        xhr(page, "r2", "POST", origin + "/api/todos", type: "Fetch")
        xhr(page, "poll-2", "GET", origin + "/poll?t=2")
        page.noteBarrier(lost: false)
        let clock = ContinuousClock.now
        let waiting = Task { await page.wait(.action, from: mark, deadline: deadline()) }
        try? await Task.sleep(for: .milliseconds(30))
        let response: [String: Any] = ["url": origin + "/api/todos", "status": 201, "mimeType": "application/json"]
        send(page, "Network.responseReceived", ["requestId": "r2", "type": "Fetch", "frameId": main, "response": response])
        send(page, "Network.loadingFinished", ["requestId": "r2", "encodedDataLength": 12])
        let outcome = await waiting.value
        let elapsed = clock.duration(to: ContinuousClock.now)
        #expect(outcome == .quiet)
        #expect(elapsed >= Duration.milliseconds(30), "the fetch was waited for")
        #expect(elapsed < Duration.milliseconds(1_500), "the polling request was not (it never ends here)")

        let facts = recorder.facts
        #expect(facts.contains(PageFact.network(.started(requestId: "r2", kind: .fetch, method: "POST",
                                                         url: origin + "/api/todos"))))
        let ends = facts.compactMap { fact -> Int? in
            if case .network(.ended(let id, let status, let errorText, _, _)) = fact, id == "r2", errorText == nil {
                return status
            }
            return nil
        }
        #expect(ends == [201])
        #expect(page.state.requestsInFlight == 2, "both polls are still open")
    }

    @Test("a navigation requested that never starts was cancelled after requestedNoStart")
    func demandeSansDepart() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        let clock = ContinuousClock.now
        requested(page, "file:///etc/hostname")
        page.noteBarrier(lost: false)
        let policy = SettlePolicy(requestedNoStart: .milliseconds(60))
        let outcome = await page.wait(.action, from: mark, policy: policy, deadline: deadline())
        let elapsed = clock.duration(to: ContinuousClock.now)
        #expect(outcome == .quiet)
        #expect(elapsed >= Duration.milliseconds(55), "it waited for the start that never came")
        #expect(elapsed < Duration.milliseconds(1_500))
    }

    @Test("the main document fails: the settle fails with Chromium's error")
    func documentEnEchec() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        requested(page, "http://localhost:9/")
        started(page, loader: "L3", url: "http://localhost:9/")
        send(page, "Network.loadingFailed",
             ["requestId": "L3", "type": "Document", "errorText": "net::ERR_CONNECTION_REFUSED", "canceled": false])
        commit(page, loader: "L4", url: "chrome-error://chromewebdata/")
        let outcome = await page.wait(.action, from: mark, deadline: deadline())
        #expect(outcome == .failed(errorText: "net::ERR_CONNECTION_REFUSED"))
    }

    @Test("a subframe's document is not a load of the page")
    func documentDeSousCadre() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        let request: [String: Any] = ["url": origin + "/frame", "method": "GET"]
        send(page, "Network.requestWillBeSent",
             ["requestId": "F1", "loaderId": "F1", "type": "Document", "frameId": "CHILD", "request": request])
        send(page, "Page.frameRequestedNavigation",
             ["frameId": "CHILD", "reason": "scriptInitiated", "url": origin + "/frame", "disposition": "currentTab"])
        page.noteBarrier(lost: false)
        let outcome = await page.wait(.action, from: mark, deadline: deadline())
        #expect(outcome == .quiet)
    }

    @Test("a download: the document aborts (a stop, not a failure), one note per guid")
    func telechargement() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        requested(page, origin + "/file.zip")
        started(page, loader: "D1", url: origin + "/file.zip")
        send(page, "Page.downloadWillBegin",
             ["frameId": main, "guid": "g1", "url": origin + "/file.zip", "suggestedFilename": "file.zip"])
        send(page, "Network.loadingFailed",
             ["requestId": "D1", "type": "Document", "errorText": "net::ERR_ABORTED", "canceled": true])
        send(page, "Page.frameStoppedLoading", ["frameId": main])
        page.noteDownload(url: origin + "/file.zip")   // the router's report of the same download
        let outcome = await page.wait(.action, from: mark, deadline: deadline())
        #expect(outcome == .quiet)
        let downloads = recorder.facts.filter { fact in
            if case .download = fact { return true }
            return false
        }
        #expect(downloads == [PageFact.download(guid: "g1", url: origin + "/file.zip", suggestedFilename: "file.zip")])
        page.noteDownload(url: origin + "/other.zip", guid: "g2")
        page.noteDownload(url: origin + "/other.zip", guid: "g2")
        let all = recorder.facts.filter { fact in
            if case .download = fact { return true }
            return false
        }
        #expect(all.count == 2, "one fact per download")
    }

    @Test("a back/forward-cache restore fires no load: it counts as loaded")
    func restaurationDuCache() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        commit(page, loader: "B1", url: origin + "/a", type: "BackForwardCacheRestore")
        let outcome = await page.wait(.navigation(loaderId: "B1"), from: mark, deadline: deadline())
        #expect(outcome == .loaded)
        #expect(page.state.reached.contains("load"))
    }

    @Test("the deadline ends a load under way: still loading")
    func echeance() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        let mark = page.mark()
        started(page, loader: "L1", url: origin + "/slow")
        commit(page, loader: "L1", url: origin + "/slow")
        let outcome = await page.wait(.action, from: mark, deadline: ContinuousClock.now + .milliseconds(80))
        #expect(outcome == .stillLoading)
        #expect(outcome.note == "The page was still loading when the wait ended.")
    }

    @Test("a cancelled wait answers at once with where it stood")
    func annulation() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        let mark = page.mark()
        started(page, loader: "L1", url: origin + "/slow")
        let clock = ContinuousClock.now
        let waiting = Task { await page.wait(.action, from: mark, deadline: deadline(30)) }
        try? await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        let outcome = await waiting.value
        let elapsed = clock.duration(to: ContinuousClock.now)
        #expect(outcome == .stillLoading)
        #expect(elapsed < Duration.seconds(2))
    }

    @Test("two waits on one page are each resumed")
    func deuxAttentes() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        let mark = page.mark()
        started(page, loader: "L1", url: origin + "/")
        let first = Task { await page.wait(.action, from: mark, deadline: deadline()) }
        let second = Task { await page.wait(.navigation(loaderId: "L1"), from: mark, deadline: deadline()) }
        try? await Task.sleep(for: .milliseconds(20))
        commit(page, loader: "L1", url: origin + "/")
        lifecycle(page, "load", loader: "L1")
        let outcomes = [await first.value, await second.value]
        #expect(outcomes == [SettleOutcome.loaded, SettleOutcome.loaded])
    }

    // MARK: - Dialogs

    @Test("a dialog during a click: calls interrupted, the settle modal, one answer sent")
    func dialogue() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        dialog(page, "confirm", "Delete?")
        let lastInterrupt = recorder.interrupts.last
        #expect(lastInterrupt == CDPInterruption.dialogOpened)
        let open = page.state.dialog
        #expect(open?.kind == .confirm)
        #expect(open?.message == "Delete?")
        #expect(open?.frameOrigin == origin)
        #expect(open?.isMainFrame == true)
        if let open {
            #expect(recorder.facts.contains(PageFact.dialogOpened(open)))
        }

        let outcome = await page.wait(.action, from: mark, deadline: deadline())
        #expect(outcome == .modal)

        let answer = page.answerDialog(accept: true)
        let answeredMessage = answer.map { $0.message }
        #expect(answeredMessage == .success("Delete?"))
        let posted = recorder.posts.last
        #expect(posted?.0 == "Page.handleJavaScriptDialog")
        #expect(posted?.1["accept"] as? Bool == true)
        let sent = recorder.count("Page.handleJavaScriptDialog")

        let again = page.answerDialog(accept: false, dialogId: open?.id)
        #expect(again == .failure(.alreadyHandled))
        #expect(recorder.count("Page.handleJavaScriptDialog") == sent, "never a second answer")
        send(page, "Page.javascriptDialogClosed", ["result": true, "userInput": ""])
        let closings = recorder.facts.filter { fact in
            if case .dialogClosed = fact { return true }
            return false
        }
        #expect(closings.isEmpty, "closed by our own answer")
        #expect(page.state.dialog == nil)
    }

    @Test("the 21st dialog of a document is dismissed at once; a commit starts the count again")
    func boucleDeDialogues() {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        for index in 1...20 {
            dialog(page, "alert", "#\(index)")
            _ = page.answerDialog(accept: true)
            send(page, "Page.javascriptDialogClosed", ["result": true, "userInput": ""])
        }
        #expect(recorder.count("Page.handleJavaScriptDialog") == 20)
        dialog(page, "alert", "#21")
        #expect(recorder.count("Page.handleJavaScriptDialog") == 21)
        #expect(recorder.posts.last?.1["accept"] as? Bool == false)
        #expect(page.state.dialog == nil, "not parked")
        let auto = recorder.facts.contains { fact in
            if case .dialogAutoAnswered(_, let accepted, let reason) = fact { return !accepted && reason == .tooMany }
            return false
        }
        #expect(auto)

        loaded(page, loader: "L2", url: origin + "/again")
        dialog(page, "alert", "fresh")
        #expect(page.state.dialog?.message == "fresh")
    }

    @Test("beforeunload: accepted while the agent leaves, a modal state otherwise")
    func quitterLaPage() {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        page.setAutoAcceptBeforeUnload(true)
        dialog(page, "beforeunload", "")
        #expect(page.state.dialog == nil)
        #expect(recorder.posts.last?.0 == "Page.handleJavaScriptDialog")
        #expect(recorder.posts.last?.1["accept"] as? Bool == true)
        let interruptedForDialog = recorder.interrupts.contains(CDPInterruption.dialogOpened)
        #expect(!interruptedForDialog, "nothing waits behind an answered dialog")

        page.setAutoAcceptBeforeUnload(false)
        dialog(page, "beforeunload", "")
        #expect(page.state.dialog?.kind == .beforeunload)
        let dismissed = page.dismissDialog()
        #expect(dismissed?.kind == .beforeunload)
        #expect(recorder.posts.last?.1["accept"] as? Bool == false)
        let none = page.answerDialog(accept: true)
        #expect(none == .failure(.noDialog))
    }

    @Test("a file chooser ends the settle, with the input to fill")
    func selecteurDeFichiers() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        send(page, "Page.fileChooserOpened", ["frameId": main, "mode": "selectMultiple", "backendNodeId": 42])
        let outcome = await page.wait(.action, from: mark, deadline: deadline())
        #expect(outcome == .modal)
        let chooser = PageFileChooser(backendNodeId: 42, frameId: main, mode: "selectMultiple")
        #expect(chooser.multiple)
        #expect(recorder.facts.contains(PageFact.fileChooser(chooser)))
        let interruptedForChooser = recorder.interrupts.contains(CDPInterruption.dialogOpened)
        #expect(!interruptedForChooser, "a chooser blocks nothing")
    }

    // MARK: - Crash and detach

    @Test("a crash ends the waits, fails the session's calls, takes the dialog with it")
    func plantage() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        started(page, loader: "L2", url: origin + "/next")
        let waiting = Task { await page.wait(.action, from: mark, deadline: deadline()) }
        try? await Task.sleep(for: .milliseconds(20))
        dialog(page, "alert", "boom")
        send(page, "Inspector.targetCrashed", [:])
        page.noteCrashed()
        let outcome = await waiting.value
        #expect(outcome == .modal || outcome == .crashed, "the dialog may have ended it first")
        #expect(recorder.failures == [.interrupted(.crashed)])
        #expect(page.state.crashed)
        #expect(page.state.dialog == nil)
        let facts = recorder.facts
        let crashes = facts.filter { $0 == PageFact.crashed }
        #expect(crashes.count == 1, "the router's note and the session's event are one crash")
        let gone = facts.contains { fact in
            if case .dialogDismissed(let dialog, let reason) = fact { return dialog.message == "boom" && reason == .crash }
            return false
        }
        #expect(gone)
        #expect(recorder.count("Page.handleJavaScriptDialog") == 0, "a dead page reads no answer")

        loaded(page, loader: "L3", url: origin + "/")
        #expect(page.state.crashed == false, "a reload brings it back")
    }

    @Test("a crash during a load ends that wait as crashed")
    func plantagePendantLeChargement() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        let mark = page.mark()
        started(page, loader: "L2", url: origin + "/next")
        let waiting = Task { await page.wait(.action, from: mark, deadline: deadline()) }
        try? await Task.sleep(for: .milliseconds(20))
        page.noteCrashed()
        let outcome = await waiting.value
        #expect(outcome == .crashed)
    }

    @Test("a detach ends the waits for good")
    func detachement() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        loaded(page, loader: "L1", url: origin + "/")
        let mark = page.mark()
        started(page, loader: "L2", url: origin + "/next")
        let waiting = Task { await page.wait(.action, from: mark, deadline: deadline()) }
        try? await Task.sleep(for: .milliseconds(20))
        send(page, "Inspector.detached", ["reason": "target_closed"])
        let first = await waiting.value
        #expect(first == .detached)
        #expect(recorder.failures == [.interrupted(.detached)])
        #expect(recorder.facts.contains(PageFact.detached(reason: "target_closed")))

        let later = page.mark()
        let outcome = await page.wait(.action, from: later, deadline: deadline())
        #expect(outcome == .detached)
    }

    // MARK: - The console binding

    @Test("the binding is added again on every commit, main frame and subframes")
    func liaisonApresNavigation() {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        commit(page, loader: "L1", url: origin + "/")
        let child: [String: Any] = ["id": "CHILD", "parentId": main, "loaderId": "C1", "url": origin + "/frame",
                                    "securityOrigin": origin]
        send(page, "Page.frameNavigated", ["frame": child, "type": "Navigation"])
        #expect(recorder.methods == ["Runtime.addBinding", "Runtime.addBinding"])
        let params = recorder.posts.first?.1
        #expect(params?["name"] as? String == "__loomHookBinding")
        #expect(params?["executionContextName"] as? String == "loom-agent")
        #expect(page.state.generation == 1, "a child commit is not a new page")
        #expect(page.frameOrigin("CHILD") == origin)
        #expect(page.ownsFrame("CHILD"))
    }

    @Test("binding payloads reach the owner; another name or an oversize payload does not")
    func charges() {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        commit(page, loader: "L1", url: origin + "/")
        let payload = #"{"t":"console","level":"log","text":"hi"}"#
        send(page, "Runtime.bindingCalled", ["name": "__loomHookBinding", "payload": payload, "executionContextId": 7])
        send(page, "Runtime.bindingCalled", ["name": "somethingElse", "payload": payload, "executionContextId": 7])
        let huge = String(repeating: "x", count: PageSignals.maxBindingPayloadBytes + 1)
        send(page, "Runtime.bindingCalled", ["name": "__loomHookBinding", "payload": huge, "executionContextId": 7])
        let bindings = recorder.facts.filter { fact in
            if case .binding = fact { return true }
            return false
        }
        #expect(bindings == [PageFact.binding(payload: payload, executionContextId: 7)])
    }

    @Test("a binding flood removes it until the next main-frame commit")
    func inondation() {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        commit(page, loader: "L1", url: origin + "/")
        for index in 0...(PageSignals.bindingFloodPerSecond + 50) {
            send(page, "Runtime.bindingCalled", ["name": "__loomHookBinding", "payload": "\(index)", "executionContextId": 7])
        }
        let delivered = recorder.facts.filter { fact in
            if case .binding = fact { return true }
            return false
        }
        #expect(delivered.count == PageSignals.bindingFloodPerSecond)
        #expect(recorder.facts.filter { $0 == PageFact.bindingCut }.count == 1)
        #expect(recorder.count("Runtime.removeBinding") == 1)

        let child: [String: Any] = ["id": "CHILD", "parentId": main, "loaderId": "C1", "url": origin + "/frame"]
        send(page, "Page.frameNavigated", ["frame": child])
        #expect(recorder.count("Runtime.addBinding") == 1, "not while cut")

        commit(page, loader: "L2", url: origin + "/next")
        #expect(recorder.count("Runtime.addBinding") == 2)
        send(page, "Runtime.bindingCalled", ["name": "__loomHookBinding", "payload": "after", "executionContextId": 9])
        #expect(recorder.facts.last == PageFact.binding(payload: "after", executionContextId: 9))
    }

    // MARK: - Network facts, frames, target info

    @Test("network facts: XHR and fetch only, a redirect is one request, the main document's status")
    func faitsReseau() {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        started(page, loader: "L1", url: origin + "/")
        let document: [String: Any] = ["url": origin + "/", "status": 200, "mimeType": "text/html"]
        send(page, "Network.responseReceived", ["requestId": "L1", "type": "Document", "frameId": main, "response": document])
        commit(page, loader: "L1", url: origin + "/")

        xhr(page, "img", "GET", origin + "/a.png", type: "Image")
        xhr(page, "js", "GET", origin + "/app.js", type: "Script")
        xhr(page, "x1", "GET", origin + "/api/old")
        xhr(page, "x1", "GET", origin + "/api/new")   // the redirect: same requestId
        let answer: [String: Any] = ["url": origin + "/api/new", "status": 200]
        send(page, "Network.responseReceived", ["requestId": "x1", "type": "XHR", "frameId": main, "response": answer])
        send(page, "Network.loadingFinished", ["requestId": "x1"])
        xhr(page, "x2", "GET", origin + "/api/gone")
        send(page, "Network.loadingFailed", ["requestId": "x2", "type": "XHR", "errorText": "net::ERR_FAILED", "canceled": false])

        let network = recorder.facts.compactMap { fact -> PageNetworkFact? in
            if case .network(let item) = fact { return item }
            return nil
        }
        #expect(network.first == PageNetworkFact.document(url: origin + "/", status: 200))
        let starts = network.filter { item in
            if case .started = item { return true }
            return false
        }
        #expect(starts == [PageNetworkFact.started(requestId: "x1", kind: .xhr, method: "GET", url: origin + "/api/old"),
                           PageNetworkFact.started(requestId: "x2", kind: .xhr, method: "GET", url: origin + "/api/gone")])
        let ends = network.compactMap { item -> String? in
            if case .ended(let id, let status, let errorText, _, let duration) = item {
                return "\(id) \(status.map { String($0) } ?? "-") \(errorText ?? "-") \(duration != nil)"
            }
            return nil
        }
        #expect(ends == ["x1 200 - true", "x2 - net::ERR_FAILED true"])
        #expect(page.state.requestsInFlight == 0)
    }

    @Test("frames, target info and lifecycle state")
    func etat() {
        let recorder = SignalsRecorder()
        let page = signals(recorder)
        #expect(page.ownsFrame(main))
        send(page, "Page.frameAttached", ["frameId": "CHILD", "parentFrameId": main])
        #expect(page.ownsFrame("CHILD"))
        send(page, "Page.frameDetached", ["frameId": "CHILD", "reason": "remove"])
        #expect(!page.ownsFrame("CHILD"))

        page.noteTargetInfo(title: "Todos", url: origin + "/")
        page.noteTargetInfo(title: "Todos", url: origin + "/")
        let info = ["targetId": "T1", "type": "page", "title": "Todos — 2", "url": origin + "/"]
        send(page, "Target.targetInfoChanged", ["targetInfo": info])
        let titles = recorder.facts.compactMap { fact -> String? in
            if case .targetInfo(let title, _) = fact { return title }
            return nil
        }
        #expect(titles == ["Todos", "Todos — 2"], "an unchanged title is not news")
        #expect(page.state.title == "Todos — 2")

        started(page, loader: "L1", url: origin + "/")
        commit(page, loader: "L1", url: origin + "/")
        lifecycle(page, "DOMContentLoaded", loader: "L1")
        let early = page.state.reached
        #expect(early == Set(["DOMContentLoaded"]))
        lifecycle(page, "load", loader: "OTHER")
        let after = page.state.reached
        #expect(after == Set(["DOMContentLoaded"]), "another loader's load is not this document's")
    }

    @Test("a parentless commit under another id becomes the main frame")
    func autreCadrePrincipal() async {
        let recorder = SignalsRecorder()
        let page = signals(recorder, mainFrameId: "T1")
        let mark = page.mark()
        let frame: [String: Any] = ["id": "F9", "loaderId": "L1", "url": origin + "/", "securityOrigin": origin]
        send(page, "Page.frameNavigated", ["frame": frame, "type": "Navigation"])
        send(page, "Page.lifecycleEvent", ["frameId": "F9", "loaderId": "L1", "name": "load", "timestamp": 2.0])
        #expect(page.state.mainFrameId == "F9")
        let outcome = await page.wait(.navigation(loaderId: "L1"), from: mark, deadline: deadline())
        #expect(outcome == .loaded)
    }

    @Test("a request's key is its method, origin and path")
    func cleDeRequete() {
        let key = PageSignals.requestKey(method: "get", url: "http://localhost:3000/poll?t=12#x")
        #expect(key == "GET http://localhost:3000/poll")
        let plain = PageSignals.requestKey(method: "POST", url: "http://localhost:3000/api")
        #expect(plain == "POST http://localhost:3000/api")
    }
}

// MARK: - Recorded traces

/// The hand-moved clock of a replay: each trace entry sets it to its own time.
private final class ReplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant

    init(_ start: ContinuousClock.Instant) {
        current = start
    }

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ instant: ContinuousClock.Instant) {
        lock.lock()
        current = instant
        lock.unlock()
    }
}

// Seam: Chromium's real event orderings, recorded by
// Tests/AgentBrowserCDP/settle.test.mjs on chrome-headless-shell and on a
// full Chromium (new headless). Each trace goes through a PageSignals on a
// hand-moved clock — its events in wire order, the mark, the barrier's
// reply — then SettleMachine.replay runs the wait as the engine would start
// it, at the barrier's reply. Times are milliseconds from the mark.

@Suite("Recorded traces — the settle on Chromium's own orderings")
struct SettleTraceReplayTests {

    private static let traces = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("AgentBrowserCDP/fixtures/traces")

    private struct Replayed {
        var outcome: SettleOutcome
        /// When the settle ended.
        var doneMs: Double
        /// When the barrier answered: the wait's start.
        var barrierMs: Double
        var barrierLost: Bool
        var entries: [[String: Any]]
        var loaderAtMark: String
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func time(_ entry: [String: Any]) -> Double {
        (entry["t"] as? NSNumber)?.doubleValue ?? 0
    }

    private func replay(_ scenario: String, _ binary: String) throws -> Replayed {
        let file = Self.traces.appendingPathComponent("\(scenario).\(binary).json")
        let data = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: data)
        let trace = try #require(object as? [String: Any])
        let mainFrame = try #require(trace["mainFrame"] as? String)
        let entries = try #require(trace["entries"] as? [[String: Any]])

        let origin = ContinuousClock.now
        let clock = ReplayClock(origin)
        let session = CDPSessionID("TRACE")
        let page = PageSignals(session: session, mainFrameId: mainFrame, link: .unlinked, clock: { clock.now })
        var mark: PageMark?
        var waitStart: ContinuousClock.Instant?
        var lost = false
        for entry in entries {
            let microseconds = Int64((Self.time(entry) * 1_000).rounded())
            clock.set(origin.advanced(by: .microseconds(microseconds)))
            if entry["mark"] as? Bool == true {
                mark = page.mark()
            } else if let method = entry["event"] as? String {
                let params = entry["params"] as? [String: Any] ?? [:]
                page.handle(method: method, params: CDPObject(params), session: session)
            } else if entry["reply"] as? String == "barrier" {
                lost = entry["error"] != nil
                page.noteBarrier(lost: lost)
                waitStart = clock.now
            }
        }
        let from = try #require(mark, "the trace has a mark")
        let start = try #require(waitStart, "the trace has the barrier's reply")
        let result = SettleMachine.replay(page.events(since: from), mark: from, kind: .action, start: start)
        return Replayed(outcome: result.outcome, doneMs: Self.milliseconds(origin.duration(to: result.at)),
                        barrierMs: Self.milliseconds(origin.duration(to: start)), barrierLost: lost,
                        entries: entries, loaderAtMark: trace["loaderAtMark"] as? String ?? "")
    }

    /// The last time the response or the end of one of `ids` came, after the mark.
    private func lastEnd(of ids: [String], in entries: [[String: Any]]) -> Double? {
        let ends = entries.filter { entry in
            guard let method = entry["event"] as? String,
                  ["Network.responseReceived", "Network.loadingFinished", "Network.loadingFailed"].contains(method),
                  let params = entry["params"] as? [String: Any],
                  let id = params["requestId"] as? String else { return false }
            return ids.contains(id) && Self.time(entry) > 0
        }
        return ends.map { Self.time($0) }.max()
    }

    @Test("a click that changes nothing, or stays on its document, is over when the barrier answers",
          arguments: ["click-noop", "click-push-state", "click-hash"], ["headlessShell", "fullBrowser"])
    func memeDocument(scenario: String, binary: String) throws {
        let replayed = try replay(scenario, binary)
        #expect(replayed.outcome == .quiet)
        #expect(abs(replayed.doneMs - replayed.barrierMs) < 0.01,
                "done at \(replayed.doneMs) ms, barrier at \(replayed.barrierMs) ms")
    }

    @Test("a click that navigates is over at the new document's load (or the barrier, if later)",
          arguments: ["click-navigates", "click-navigates-in-timer", "click-submits-post"], ["headlessShell", "fullBrowser"])
    func navigation(scenario: String, binary: String) throws {
        let replayed = try replay(scenario, binary)
        #expect(replayed.outcome == .loaded)
        let loads = replayed.entries.filter { entry in
            guard entry["event"] as? String == "Page.lifecycleEvent",
                  let params = entry["params"] as? [String: Any] else { return false }
            let name = params["name"] as? String ?? ""
            let loader: String? = params["loaderId"] as? String
            let after = Self.time(entry) > 0
            return name == "load" && loader != replayed.loaderAtMark && after
        }
        let load = try #require(loads.first.map { Self.time($0) }, "the trace records the new document's load")
        let expected = max(load, replayed.barrierMs)
        #expect(abs(replayed.doneMs - expected) < 0.01, "done at \(replayed.doneMs) ms, expected \(expected) ms")
    }

    @Test("a link: the barrier fails with \"Cannot find context with specified id\" after the commit — a navigation",
          arguments: ["headlessShell", "fullBrowser"])
    func barriereSurLien(binary: String) throws {
        let replayed = try replay("click-navigates", binary)
        #expect(replayed.barrierLost)
        #expect(replayed.outcome == .loaded)
    }

    @Test("a fetch the click starts is waited for until its answer, plus the 32 ms chain window",
          arguments: ["headlessShell", "fullBrowser"])
    func fetch(binary: String) throws {
        // Its body is never read: Chromium sends no loadingFinished for it —
        // the answer ends it, or the wait would run to the 2 s cap.
        let replayed = try replay("click-fetch", binary)
        #expect(replayed.outcome == .quiet)
        let answer = try #require(lastEnd(of: ["R1"], in: replayed.entries))
        let expected = max(answer + 32, replayed.barrierMs)
        #expect(abs(replayed.doneMs - expected) < 0.01, "done at \(replayed.doneMs) ms, expected \(expected) ms")
    }

    @Test("a fetch chain (the second starts after the barrier, when the first ends) is one burst",
          arguments: ["headlessShell", "fullBrowser"])
    func chaine(binary: String) throws {
        let replayed = try replay("click-fetch-chain", binary)
        #expect(replayed.outcome == .quiet)
        let end = try #require(lastEnd(of: ["R1", "R2"], in: replayed.entries))
        #expect(abs(replayed.doneMs - (end + 32)) < 0.01, "done at \(replayed.doneMs) ms, the chain ended at \(end) ms")
    }

    @Test("a long-poll in flight at the mark is not waited for; the click's own fetch is",
          arguments: ["headlessShell", "fullBrowser"])
    func longPoll(binary: String) throws {
        let replayed = try replay("click-fetch-during-long-poll", binary)
        #expect(replayed.outcome == .quiet)
        let answer = try #require(lastEnd(of: ["R4"], in: replayed.entries))
        let expected = max(answer + 32, replayed.barrierMs)
        #expect(abs(replayed.doneMs - expected) < 0.01, "done at \(replayed.doneMs) ms, expected \(expected) ms")
        #expect(replayed.doneMs < 200, "the poll answers at ~510 ms and is sent again at once")
    }
}
