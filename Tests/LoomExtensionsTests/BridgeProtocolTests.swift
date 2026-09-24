import Testing
import LoomExtensions
import LoomAPI
import Foundation

// Seam: the bridge's wire contract (ADR-0011) — requests, responses, events,
// the scripts that carry them into a page. No WebKit here: the host in
// LoomWeb only moves these strings.

@Suite("Extensions — bridge contract")
struct BridgeProtocolTests {

    @Test("a request without params, or with null, carries an empty object")
    func parametresParDefaut() throws {
        let bare = try JSONDecoder().decode(BridgeRequest.self, from: Data(#"{"id":"1","method":"loom.info"}"#.utf8))
        #expect(bare.params == .object([:]))
        let null = try JSONDecoder().decode(BridgeRequest.self,
                                            from: Data(#"{"id":"2","method":"loom.info","params":null}"#.utf8))
        #expect(null.params == .object([:]))
    }

    @Test("a response is a result or an error, as JSON text")
    func reponse() throws {
        let ok = BridgeResponse.ok("7", BridgeOK())
        let decoded = try JSONDecoder().decode(BridgeResponse.self, from: Data(ok.jsonText.utf8))
        #expect(decoded.result == .object(["ok": .bool(true)]))
        #expect(decoded.error == nil)
        #expect(!ok.jsonText.contains("\"error\""), "no error key on a success")

        let failed = BridgeResponse.failure("8", BridgeError(.forbidden, "no"))
        let back = try JSONDecoder().decode(BridgeResponse.self, from: Data(failed.jsonText.utf8))
        #expect(back.error == BridgeError(.forbidden, "no"))
        #expect(back.result == nil)
    }

    @Test("every method names the permission it needs; storage and secrets need none")
    func exigences() {
        #expect(BridgeMethod.sessionsLaunch.requirement == .sessions(.launch))
        #expect(BridgeMethod.sessionsList.requirement == .sessions(.read))
        #expect(BridgeMethod.sessionsOpen.requirement == .sessions(.read))
        #expect(BridgeMethod.projectsList.requirement == .projects(.read))
        #expect(BridgeMethod.httpFetch.requirement == .network)
        for method in [BridgeMethod.info, .storageGet, .storageSet, .storageDelete,
                       .secretsGet, .secretsSet, .secretsDelete, .openExternal] {
            #expect(method.requirement == nil, "\(method.rawValue)")
        }
    }

    @Test("the top bar and the overlay need their ui grant; alarms need none")
    func exigencesInterface() {
        #expect(BridgeMethod.uiSetStatus.requirement == .ui(.status))
        #expect(BridgeMethod.uiPresentOverlay.requirement == .ui(.overlay))
        #expect(BridgeMethod.uiDismissOverlay.requirement == .ui(.overlay))
        for method in [BridgeMethod.alarmsCreate, .alarmsClear, .alarmsList] {
            #expect(method.requirement == nil, "\(method.rawValue)")
        }
    }

    @Test("an alarm fires within a week, at an instant or after a delay; too soon or past fires in a second")
    func alarmes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = try BridgeAlarmParams(name: "phase-end", when: (now.timeIntervalSince1970 + 60) * 1000).fireDate(now: now)
        #expect(later == now.addingTimeInterval(60))
        #expect(try BridgeAlarmParams(name: "t", delayMs: 5000).fireDate(now: now) == now.addingTimeInterval(5))
        #expect(try BridgeAlarmParams(name: "t", delayMs: 10).fireDate(now: now) == now.addingTimeInterval(1))
        #expect(try BridgeAlarmParams(name: "t", when: (now.timeIntervalSince1970 - 30) * 1000).fireDate(now: now)
                == now.addingTimeInterval(1), "a page re-creating an alarm that just passed")
        #expect(throws: BridgeError.self) { try BridgeAlarmParams(name: "t", delayMs: 8 * 24 * 3600 * 1000).fireDate(now: now) }
        #expect(throws: BridgeError.self) { try BridgeAlarmParams(name: "t").fireDate(now: now) }
        #expect(throws: BridgeError.self) {
            try BridgeAlarmParams(name: "t", when: 1, delayMs: 5000).fireDate(now: now)
        }
        #expect(throws: BridgeError.self) { try BridgeAlarmParams(name: "a b", delayMs: 5000).fireDate(now: now) }
    }

    @Test("an overlay's end is capped at an hour and must be ahead")
    func finDeLEcran() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let capped = try BridgeOverlayParams(page: "break.html").validated(now: now)
        #expect(capped.until == now.addingTimeInterval(3600))
        #expect(capped.dismissLabel == "Dismiss")
        let five = try BridgeOverlayParams(page: "ui/break.html", until: (now.timeIntervalSince1970 + 300) * 1000,
                                           dismissLabel: " Skip break ").validated(now: now)
        #expect(five.until == now.addingTimeInterval(300))
        #expect(five.dismissLabel == "Skip break")
        #expect(throws: BridgeError.self) {
            try BridgeOverlayParams(page: "break.html", until: (now.timeIntervalSince1970 - 1) * 1000).validated(now: now)
        }
        #expect(throws: BridgeError.self) {
            try BridgeOverlayParams(page: "break.html", dismissLabel: "  ").validated(now: now)
        }
    }

    @Test("alarm and overlay events carry what the page needs")
    func evenementsDesBriques() {
        let alarm = BridgeEvent.alarm("phase-end", scheduledTime: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(alarm.payload["scheduledTime"] == .number(1_800_000_000_000))
        #expect(alarm.requirement == nil)
        let dismissed = BridgeEvent.overlayDismissed(.user, page: "break.html")
        #expect(dismissed.payload["reason"] == .string("user"))
    }

    @Test("a launch proposal is checked before any sheet opens")
    func propositionDeLancement() {
        #expect(throws: BridgeError.self) { try BridgeLaunchParams(prompt: "  ").validate() }
        #expect(throws: BridgeError.self) { try BridgeLaunchParams(prompt: "x", placement: "cloud").validate() }
        #expect(throws: BridgeError.self) { try BridgeLaunchParams(projectId: "nope", prompt: "x").validate() }
        #expect(throws: BridgeError.self) {
            try BridgeLaunchParams(prompt: "x", badges: Array(repeating: "b", count: 9)).validate()
        }
        #expect(throws: Never.self) {
            try BridgeLaunchParams(projectId: UUID().uuidString, prompt: "Fix PROJ-1",
                                   title: "PROJ-1 · Fix", badges: ["PROJ-1"], placement: "worktree").validate()
        }
    }

    @Test("an emitted event reaches the page as one JSON string literal, decoded back intact")
    func emission() throws {
        let event = BridgeEvent.sessionStateChanged(sessionId: "abc", state: "needs_input", previous: "working")
        let script = BridgeScripts.emit(event)
        #expect(script.hasPrefix("window.__loomEmit && window.__loomEmit(\""))
        #expect(script.hasSuffix(");"))
        let opening = try #require(script.range(of: "window.__loomEmit(")).upperBound
        let close = try #require(script.range(of: ");", options: .backwards)).lowerBound
        let quoted = String(script[opening..<close])
        let text = try JSONDecoder().decode(String.self, from: Data(quoted.utf8))
        let back = try JSONDecoder().decode(BridgeEvent.self, from: Data(text.utf8))
        #expect(back == event)
    }

    @Test("a hostile title stays data: quotes and script tags cannot close the literal")
    func emissionHostile() throws {
        let session = APISession(id: "s", title: "\"); alert(1); (\"</script>\u{2028}", state: "idle",
                                 badges: [], createdAt: "2026-09-24T00:00:00Z")
        let script = BridgeScripts.emit(.sessionsChanged([session]))
        let opening = try #require(script.range(of: "window.__loomEmit(")).upperBound
        let close = try #require(script.range(of: ");", options: .backwards)).lowerBound
        let text = try JSONDecoder().decode(String.self, from: Data(String(script[opening..<close]).utf8))
        let back = try JSONDecoder().decode(BridgeEvent.self, from: Data(text.utf8))
        #expect(back.payload["sessions"] != nil)
    }

    @Test("the user script sets the boot values before the SDK runs")
    func scriptDAmorcage() {
        let script = BridgeScripts.userScript(boot: BridgeBoot(
            extensionId: "dev.example.x", theme: BridgeTheme(isLight: true, tokens: ["accent": "#FF0000"])))
        #expect(script.hasPrefix("window.__loomBoot = {"))
        #expect(script.contains("\"extensionId\":\"dev.example.x\""))
        #expect(script.contains(LoomSDKScript.source))
    }

    @Test("session events are held to the sessions:read grant; theme and commands are not")
    func exigencesDesEvenements() {
        #expect(BridgeEvent.sessionsChanged([]).requirement == .sessions(.read))
        #expect(BridgeEvent.sessionStateChanged(sessionId: "s", state: "idle", previous: nil).requirement
                == .sessions(.read))
        #expect(BridgeEvent.themeChanged(BridgeTheme(isLight: false, tokens: [:])).requirement == nil)
        #expect(BridgeEvent.command("refresh").requirement == nil)
    }
}

@Suite("Extensions — session change detection")
struct SessionChangeDetectorTests {

    private func session(_ id: String, _ state: String, title: String = "t") -> APISession {
        APISession(id: id, title: title, state: state, badges: [], createdAt: "2026-09-24T00:00:00Z")
    }

    @Test("the first snapshot is a baseline and says nothing")
    func referenceInitiale() {
        var detector = SessionChangeDetector()
        #expect(detector.update([session("a", "working")]).isEmpty)
    }

    @Test("a state that moves gives one stateChanged, then the list")
    func changementDEtat() {
        var detector = SessionChangeDetector()
        _ = detector.update([session("a", "working"), session("b", "idle")])
        let events = detector.update([session("a", "needs_input"), session("b", "idle")])
        #expect(events.map(\.name) == [BridgeEvent.sessionStateChangedName, BridgeEvent.sessionsChangedName])
        #expect(events.first?.payload["sessionId"] == .string("a"))
        #expect(events.first?.payload["previous"] == .string("working"))
    }

    @Test("a title change or a closed session gives the list only")
    func changementSansEtat() {
        var detector = SessionChangeDetector()
        _ = detector.update([session("a", "idle"), session("b", "idle")])
        #expect(detector.update([session("a", "idle", title: "renamed"), session("b", "idle")]).map(\.name)
                == [BridgeEvent.sessionsChangedName])
        #expect(detector.update([session("a", "idle", title: "renamed")]).map(\.name)
                == [BridgeEvent.sessionsChangedName])
    }

    @Test("a new session announces its state with no previous one")
    func nouvelleSession() {
        var detector = SessionChangeDetector()
        _ = detector.update([])
        let events = detector.update([session("n", "starting")])
        #expect(events.first?.payload["previous"] == .null)
    }

    @Test("an identical snapshot is silent")
    func silence() {
        var detector = SessionChangeDetector()
        _ = detector.update([session("a", "idle")])
        #expect(detector.update([session("a", "idle")]).isEmpty)
    }
}
