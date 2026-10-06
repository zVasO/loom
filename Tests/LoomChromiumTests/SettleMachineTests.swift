import Testing
import LoomChromium
import Foundation

// Seam: the settle as a pure machine — events in, with their times, a verdict
// out. The sequences replay the orderings the step-0 probe saw on the wire
// (28-settle-misc: which events come before the barrier's reply), with
// times on a fake timeline in milliseconds from the action's ack.

@Suite("SettleMachine — when an action or a navigation is over")
struct SettleMachineTests {

    private let t0 = ContinuousClock.now
    private let poll = "GET http://localhost:3000/poll"

    private func at(_ ms: Int) -> ContinuousClock.Instant {
        t0.advanced(by: .milliseconds(ms))
    }

    private func machine(_ kind: SettleMachine.Kind = .action, pollKeys: Set<String> = [],
                         policy: SettlePolicy = SettlePolicy()) -> SettleMachine {
        SettleMachine(mark: PageMark(sequence: 0, pollKeys: pollKeys, at: t0), policy: policy, kind: kind, start: at(0))
    }

    private func feed(_ machine: inout SettleMachine, _ events: [(Int, SettleEvent)]) {
        for (ms, event) in events {
            machine.apply(event, at: at(ms))
        }
    }

    // MARK: - Actions without a navigation

    @Test("the probe's numbers are the defaults")
    func valeursParDefaut() {
        let policy = SettlePolicy()
        #expect(policy.frameFallback == .milliseconds(50))
        #expect(policy.requestedNoStart == .milliseconds(500))
        #expect(policy.loadCapAction == .seconds(10))
        #expect(policy.loadCapNavigate == .seconds(30))
        #expect(policy.chainWindow == .milliseconds(32))
        #expect(policy.quietCap == .seconds(2))
        #expect(policy.pollWindow == .seconds(2))
    }

    @Test("a click that does nothing is quiet as soon as its barrier answers")
    func clicSansEffet() {
        var settle = machine()
        #expect(settle.verdict(at: at(1)) == .waitUntil(at(2_000)), "no barrier yet: wait for it, up to the quiet cap")
        feed(&settle, [(2, .barrierDone)])
        #expect(settle.verdict(at: at(2)) == .done(.quiet))
    }

    @Test("with no barrier and no event, the quiet cap ends it")
    func sansBarriere() {
        let settle = machine()
        #expect(settle.verdict(at: at(1_999)) == .waitUntil(at(2_000)))
        #expect(settle.verdict(at: at(2_000)) == .done(.quiet))
    }

    @Test("a fetch the click starts (before the barrier, as the probe saw) is waited for, then 32 ms of quiet")
    func fetchDuClic() {
        var settle = machine()
        feed(&settle, [(1, .requestStarted(id: "r1", key: "POST http://localhost:3000/api/todos")), (2, .barrierDone)])
        #expect(settle.verdict(at: at(2)) == .waitUntil(at(2_000)))
        #expect(settle.requestsInFlight == 1)
        feed(&settle, [(50, .requestEnded(id: "r1"))])
        #expect(settle.verdict(at: at(50)) == .waitUntil(at(82)))
        #expect(settle.verdict(at: at(81)) == .waitUntil(at(82)))
        #expect(settle.verdict(at: at(82)) == .done(.quiet))
    }

    @Test("a fetch started when the first ends, within the window, is the same burst")
    func chaineDeFetch() {
        var settle = machine()
        feed(&settle, [(1, .requestStarted(id: "r1", key: "GET http://localhost:3000/a")), (2, .barrierDone),
                       (50, .requestEnded(id: "r1")), (60, .requestStarted(id: "r2", key: "GET http://localhost:3000/b"))])
        #expect(settle.verdict(at: at(83)) == .waitUntil(at(2_000)), "r2 is in flight")
        feed(&settle, [(100, .requestEnded(id: "r2"))])
        #expect(settle.verdict(at: at(100)) == .waitUntil(at(132)))
        #expect(settle.verdict(at: at(132)) == .done(.quiet))
    }

    @Test("a fetch's answer ends it for the settle; its body finishing later only restarts the window")
    func reponseSansFinDeCorps() {
        // Recorded: a fetch whose body the page never reads gets
        // responseReceived and no loadingFinished.
        var settle = machine()
        feed(&settle, [(1, .requestStarted(id: "r1", key: "GET http://localhost:3000/ok")), (2, .barrierDone),
                       (10, .requestAnswered(id: "r1"))])
        #expect(settle.requestsInFlight == 0)
        #expect(settle.verdict(at: at(10)) == .waitUntil(at(42)))
        #expect(settle.verdict(at: at(42)) == .done(.quiet))
        feed(&settle, [(20, .requestEnded(id: "r1"))])
        #expect(settle.verdict(at: at(42)) == .waitUntil(at(52)), "the body was read: the page may act on it")
        #expect(settle.verdict(at: at(52)) == .done(.quiet))
    }

    @Test("a polling request (its key in flight or recent at the mark) is not waited for")
    func sondageIgnore() {
        var settle = machine(pollKeys: [poll])
        feed(&settle, [(1, .requestStarted(id: "p2", key: poll)), (2, .barrierDone)])
        #expect(settle.requestsInFlight == 0)
        #expect(settle.verdict(at: at(2)) == .done(.quiet))
    }

    @Test("a request that never ends is cut at the quiet cap, 2 s after the ack")
    func requeteLongue() {
        var settle = machine()
        feed(&settle, [(1, .requestStarted(id: "long", key: "GET http://localhost:3000/stream")), (2, .barrierDone)])
        #expect(settle.verdict(at: at(1_999)) == .waitUntil(at(2_000)))
        #expect(settle.verdict(at: at(2_000)) == .done(.quiet))
    }

    @Test("a request that ends unseen as started (before the mark) moves nothing")
    func finInconnue() {
        var settle = machine()
        feed(&settle, [(1, .requestEnded(id: "old")), (2, .barrierDone)])
        #expect(settle.verdict(at: at(2)) == .done(.quiet), "no chain window for a request this wait never tracked")
    }

    // MARK: - Actions that navigate

    @Test("a link click: everything up to the commit before the barrier, which then fails; the load ends it")
    func clicSurUnLien() {
        // The probe's linkClick: frameRequestedNavigation, frameStartedNavigating,
        // frameStartedLoading, requestWillBeSent(Document), frameNavigated —
        // all before the barrier's reply, which fails with "Cannot find
        // context with specified id".
        var settle = machine()
        feed(&settle, [(1, .navRequested), (2, .navStarted(loaderId: "L2")), (2, .navStarted(loaderId: nil)),
                       (3, .navStarted(loaderId: "L2")), (20, .committed(loaderId: "L2")), (21, .barrierLost)])
        #expect(settle.verdict(at: at(21)) == .waitUntil(at(10_000)))
        feed(&settle, [(30, .lifecycle(name: "DOMContentLoaded", loaderId: "L2"))])
        #expect(settle.verdict(at: at(30)) == .waitUntil(at(10_000)), "DOMContentLoaded is not the load")
        feed(&settle, [(40, .lifecycle(name: "load", loaderId: "L2"))])
        #expect(settle.verdict(at: at(40)) == .done(.loaded))
    }

    @Test("a navigation by setTimeout(0): requested and started before the barrier, committed after")
    func navigationParMinuteur() {
        var settle = machine()
        feed(&settle, [(1, .navRequested), (2, .navStarted(loaderId: "L2")), (2, .navStarted(loaderId: nil)), (3, .barrierDone)])
        #expect(settle.verdict(at: at(3)) == .waitUntil(at(10_000)))
        feed(&settle, [(30, .committed(loaderId: "L2")), (45, .lifecycle(name: "load", loaderId: "L2"))])
        #expect(settle.verdict(at: at(45)) == .done(.loaded))
    }

    @Test("a form POST: the same as a link, the commit after the barrier")
    func envoiDeFormulaire() {
        var settle = machine()
        feed(&settle, [(1, .navRequested), (1, .navStarted(loaderId: "P1")), (2, .navStarted(loaderId: nil)),
                       (2, .navStarted(loaderId: "P1")), (3, .barrierDone)])
        #expect(settle.verdict(at: at(3)) == .waitUntil(at(10_000)))
        feed(&settle, [(40, .committed(loaderId: "P1")), (55, .lifecycle(name: "load", loaderId: "P1"))])
        #expect(settle.verdict(at: at(55)) == .done(.loaded))
    }

    @Test("pushState and a hash: frameStartedLoading, then navigatedWithinDocument — no load to wait for")
    func memeDocument() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: nil)), (1, .sameDocument), (2, .barrierDone)])
        #expect(settle.verdict(at: at(2)) == .done(.quiet))
        feed(&settle, [(3, .navStopped(loaderId: nil))])
        #expect(settle.verdict(at: at(3)) == .done(.quiet))
    }

    @Test("a same-document change does not end a known new document's load")
    func memeDocumentPendantUnChargement() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (2, .sameDocument)])
        #expect(settle.verdict(at: at(2)) == .waitUntil(at(10_000)))
    }

    @Test("a navigation requested that never starts was cancelled after 500 ms")
    func demandeSansDepart() {
        var settle = machine()
        feed(&settle, [(1, .navRequested), (2, .barrierDone)])
        #expect(settle.verdict(at: at(2)) == .waitUntil(at(501)))
        #expect(settle.verdict(at: at(500)) == .waitUntil(at(501)))
        #expect(settle.verdict(at: at(501)) == .done(.quiet))
        #expect(settle.finalOutcome(at: at(100)) == .quiet, "nothing started: nothing is loading")
    }

    @Test("a start that comes in time keeps the navigation")
    func demandePuisDepart() {
        var settle = machine()
        feed(&settle, [(1, .navRequested), (400, .navStarted(loaderId: "L2"))])
        #expect(settle.verdict(at: at(600)) == .waitUntil(at(10_000)))
    }

    @Test("a download: the main document aborts — a stop, not a load, not a failure")
    func telechargement() {
        var settle = machine()
        feed(&settle, [(1, .navRequested), (2, .navStarted(loaderId: "D1")), (20, .navStopped(loaderId: "D1"))])
        #expect(settle.verdict(at: at(20)) == .done(.quiet))
    }

    @Test("frameStoppedLoading before any commit: cancelled")
    func arretAvantCommit() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (15, .navStopped(loaderId: nil))])
        #expect(settle.verdict(at: at(15)) == .done(.quiet))
    }

    @Test("stopped after the commit with no load (window.stop()): as loaded as it gets")
    func arretApresCommit() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (5, .committed(loaderId: "L2")), (8, .navStopped(loaderId: nil))])
        #expect(settle.verdict(at: at(8)) == .done(.loaded))
    }

    @Test("the main document fails: the settle fails with Chromium's error, the error page does not undo it")
    func documentEnEchec() {
        var settle = machine()
        feed(&settle, [(1, .navRequested), (2, .navStarted(loaderId: "L4")),
                       (15, .docFailed(loaderId: "L4", errorText: "net::ERR_CONNECTION_REFUSED")),
                       (16, .committed(loaderId: "L5")), (20, .lifecycle(name: "load", loaderId: "L5"))])
        #expect(settle.verdict(at: at(20)) == .done(.failed(errorText: "net::ERR_CONNECTION_REFUSED")))
    }

    @Test("a document failure with no navigation of this wait is not this wait's")
    func echecHorsAttente() {
        var settle = machine()
        feed(&settle, [(1, .docFailed(loaderId: "OLD", errorText: "net::ERR_EMPTY_RESPONSE")), (2, .barrierDone)])
        #expect(settle.verdict(at: at(2)) == .done(.quiet))
    }

    @Test("a superseded loader's abort does not end the newer load")
    func chargementRemplace() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "La")), (5, .navStarted(loaderId: "Lb")), (6, .navStopped(loaderId: "La"))])
        #expect(settle.verdict(at: at(6)) == .waitUntil(at(10_000)))
        feed(&settle, [(10, .committed(loaderId: "Lb")), (20, .lifecycle(name: "load", loaderId: "Lb"))])
        #expect(settle.verdict(at: at(20)) == .done(.loaded))
    }

    @Test("frameStartedLoading during a load is the same load")
    func departSansChargeurPendantLeChargement() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (5, .committed(loaderId: "L2")), (6, .navStarted(loaderId: nil))])
        #expect(settle.verdict(at: at(6)) == .waitUntil(at(10_000)))
        feed(&settle, [(10, .lifecycle(name: "load", loaderId: "L2"))])
        #expect(settle.verdict(at: at(10)) == .done(.loaded))
    }

    @Test("an older document's load does not end this one's wait")
    func ancienChargement() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (2, .lifecycle(name: "load", loaderId: "L1"))])
        #expect(settle.verdict(at: at(2)) == .waitUntil(at(10_000)))
    }

    @Test("the load cap: still loading, with the WebKit engine's note")
    func plafondDeChargement() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (5, .committed(loaderId: "L2"))])
        #expect(settle.verdict(at: at(9_999)) == .waitUntil(at(10_000)))
        #expect(settle.verdict(at: at(10_000)) == .done(.stillLoading))
        #expect(SettleOutcome.stillLoading.note == "The page was still loading when the wait ended.")
        #expect(SettleOutcome.loaded.note == nil)
        #expect(settle.finalOutcome(at: at(500)) == .stillLoading)
    }

    @Test("the barrier lost before any commit: a navigation is coming")
    func barrierePerdue() {
        var settle = machine()
        feed(&settle, [(3, .barrierLost)])
        #expect(settle.verdict(at: at(3)) == .waitUntil(at(10_000)))
        feed(&settle, [(5, .committed(loaderId: "L2")), (9, .lifecycle(name: "load", loaderId: "L2"))])
        #expect(settle.verdict(at: at(9)) == .done(.loaded))
    }

    @Test("the barrier lost after a commit and load already seen changes nothing")
    func barrierePerdueApresChargement() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (4, .committed(loaderId: "L2")),
                       (6, .lifecycle(name: "load", loaderId: "L2")), (7, .barrierLost)])
        #expect(settle.verdict(at: at(7)) == .done(.loaded))
    }

    @Test("the old document's requests are forgotten at the commit")
    func requetesDeLAncienDocument() {
        var settle = machine()
        feed(&settle, [(1, .requestStarted(id: "r1", key: "GET http://localhost:3000/a")), (2, .navStarted(loaderId: "L2")),
                       (10, .committed(loaderId: "L2")), (20, .lifecycle(name: "load", loaderId: "L2"))])
        #expect(settle.verdict(at: at(20)) == .done(.loaded))
    }

    @Test("after the load, the new page's fetches are waited for, within 2 s of the load")
    func fetchApresChargement() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (10, .committed(loaderId: "L2")),
                       (20, .lifecycle(name: "load", loaderId: "L2")),
                       (25, .requestStarted(id: "r2", key: "GET http://localhost:3000/api/me"))])
        #expect(settle.verdict(at: at(25)) == .waitUntil(at(2_020)), "the quiet cap counts from the load")
        feed(&settle, [(100, .requestEnded(id: "r2"))])
        #expect(settle.verdict(at: at(100)) == .waitUntil(at(132)))
        #expect(settle.verdict(at: at(132)) == .done(.loaded))
        #expect(settle.finalOutcome(at: at(132)) == .loaded)
    }

    @Test("a script redirect right after the load is followed to its own load")
    func redirectionParScript() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L1")), (5, .committed(loaderId: "L1")),
                       (10, .lifecycle(name: "load", loaderId: "L1")), (11, .requestStarted(id: "r", key: "GET http://localhost:3000/x")),
                       (12, .navRequested), (13, .navStarted(loaderId: "L2"))])
        #expect(settle.verdict(at: at(13)) == .waitUntil(at(10_000)))
        feed(&settle, [(20, .committed(loaderId: "L2")), (30, .lifecycle(name: "load", loaderId: "L2"))])
        #expect(settle.verdict(at: at(30)) == .done(.loaded))
    }

    // MARK: - Modal, crash, detach

    @Test("a dialog ends the wait at once, barrier or not")
    func dialogue() {
        var settle = machine()
        feed(&settle, [(3, .modal)])
        #expect(settle.verdict(at: at(3)) == .done(.modal))
        feed(&settle, [(4, .navStarted(loaderId: "L2"))])
        #expect(settle.verdict(at: at(4)) == .done(.modal), "the first end stays")
    }

    @Test("a crash or a detach outranks a dialog and is final")
    func plantageEtDetachement() {
        var crashed = machine()
        feed(&crashed, [(1, .modal), (2, .crashed), (3, .detached), (4, .committed(loaderId: "L9"))])
        #expect(crashed.verdict(at: at(4)) == .done(.crashed))
        #expect(crashed.finalOutcome(at: at(4)) == .crashed)

        var detached = machine(.navigation(loaderId: "N1"))
        feed(&detached, [(1, .detached), (2, .crashed)])
        #expect(detached.verdict(at: at(2)) == .done(.detached))
    }

    @Test("a failure is kept when a dialog follows")
    func echecPuisDialogue() {
        var settle = machine()
        feed(&settle, [(1, .navStarted(loaderId: "L2")), (2, .docFailed(loaderId: "L2", errorText: "net::ERR_NAME_NOT_RESOLVED")),
                       (3, .modal)])
        #expect(settle.verdict(at: at(3)) == .done(.failed(errorText: "net::ERR_NAME_NOT_RESOLVED")))
    }

    // MARK: - navigate

    @Test("navigate waits for its own loader's load, not an older document's")
    func naviguer() {
        var settle = machine(.navigation(loaderId: "N1"))
        #expect(settle.verdict(at: at(0)) == .waitUntil(at(30_000)), "no barrier: the loader says what to wait for")
        feed(&settle, [(5, .lifecycle(name: "load", loaderId: "OLD")), (10, .committed(loaderId: "N1"))])
        #expect(settle.verdict(at: at(10)) == .waitUntil(at(30_000)))
        feed(&settle, [(30, .lifecycle(name: "load", loaderId: "N1"))])
        #expect(settle.verdict(at: at(30)) == .done(.loaded))
    }

    @Test("navigate counts requests from the commit, polling keys or not")
    func naviguerSansHeuristiqueDeSondage() {
        var settle = machine(.navigation(loaderId: "N1"), pollKeys: [poll])
        feed(&settle, [(10, .committed(loaderId: "N1")), (20, .lifecycle(name: "load", loaderId: "N1")),
                       (21, .requestStarted(id: "p", key: poll))])
        #expect(settle.verdict(at: at(21)) == .waitUntil(at(2_020)))
        feed(&settle, [(40, .requestEnded(id: "p"))])
        #expect(settle.verdict(at: at(72)) == .done(.loaded))
    }

    @Test("navigate with no loader was same-document: nothing to load")
    func naviguerMemeDocument() {
        let settle = machine(.navigation(loaderId: nil))
        #expect(settle.verdict(at: at(0)) == .done(.quiet))
    }

    @Test("navigate's load cap is 30 s")
    func plafondDeNavigate() {
        var settle = machine(.navigation(loaderId: "N1"))
        feed(&settle, [(10, .committed(loaderId: "N1"))])
        #expect(settle.verdict(at: at(29_999)) == .waitUntil(at(30_000)))
        #expect(settle.verdict(at: at(30_000)) == .done(.stillLoading))
    }

    @Test("navigate's failure after its reply (a redirect to a refused port) fails it")
    func naviguerEchecTardif() {
        var settle = machine(.navigation(loaderId: "N1"))
        feed(&settle, [(10, .docFailed(loaderId: "N1", errorText: "net::ERR_CONNECTION_REFUSED"))])
        #expect(settle.verdict(at: at(10)) == .done(.failed(errorText: "net::ERR_CONNECTION_REFUSED")))
    }

    @Test("a back/forward-cache restore (journaled as commit and load) is loaded at once")
    func restaurationDuCache() {
        var settle = machine(.navigation(loaderId: "B1"))
        feed(&settle, [(3, .committed(loaderId: "B1")), (3, .lifecycle(name: "load", loaderId: "B1"))])
        #expect(settle.verdict(at: at(3)) == .done(.loaded))
    }

    // MARK: - Replay

    @Test("replay runs the wait as a live one would: to the instant the verdict names, or to the next event")
    func rejeu() {
        let mark = PageMark(sequence: 0, at: t0)
        let events: [(at: ContinuousClock.Instant, event: SettleEvent)] = [
            (at(1), .requestStarted(id: "r1", key: "GET http://localhost:3000/a")),
            (at(2), .barrierDone),
            (at(50), .requestAnswered(id: "r1")),
            (at(60), .requestStarted(id: "r2", key: "GET http://localhost:3000/b")),
            (at(100), .requestEnded(id: "r2")),
        ]
        let chain = SettleMachine.replay(events, mark: mark, kind: .action, start: at(2))
        #expect(chain.outcome == .quiet)
        #expect(chain.at == at(132))

        let nothing = SettleMachine.replay([], mark: mark, kind: .action, start: at(0))
        #expect(nothing.outcome == .quiet)
        #expect(nothing.at == at(2_000), "no barrier: the quiet cap")

        let commitOnly: [(at: ContinuousClock.Instant, event: SettleEvent)] = [(at(5), .committed(loaderId: "N1"))]
        let navigation = SettleMachine.replay(commitOnly, mark: mark, kind: .navigation(loaderId: "N1"), start: at(0))
        #expect(navigation.outcome == .stillLoading)
        #expect(navigation.at == at(30_000))
    }
}
