import Testing
import LoomChromium
import Foundation

// Seam: the ledger alone — every dialog gets exactly one answer, from the
// agent, the person or Loom, and the command that carries it.

@Suite("DialogLedger — one answer per dialog")
struct DialogLedgerTests {

    private func open(_ ledger: inout DialogLedger, _ type: String = "confirm", message: String = "Delete?",
                      defaultPrompt: String? = nil) -> DialogLedger.Decision {
        ledger.opening(type: type, message: message, defaultPrompt: defaultPrompt, url: "http://localhost:3000/",
                       frameId: "MAIN", frameOrigin: "http://localhost:3000", isMainFrame: true).decision
    }

    /// Compared outside #expect: the literal keeps its type.
    private func expectParams(_ params: [String: Any], _ expected: [String: Any], _ what: String = "") {
        let matches = (params as NSDictionary).isEqual(expected as NSDictionary)
        let shown = "\(what) \(params)"
        #expect(matches, "\(shown)")
    }

    @Test("a dialog is parked, answered once; a second answer is told it was handled")
    func uneSeuleReponse() throws {
        var ledger = DialogLedger()
        guard case .park(let dialog) = open(&ledger) else {
            Issue.record("a first confirm waits for an answer")
            return
        }
        #expect(dialog.kind == .confirm)
        #expect(dialog.message == "Delete?")
        #expect(dialog.frameOrigin == "http://localhost:3000")
        #expect(dialog.isMainFrame == true)
        #expect(ledger.open == dialog)

        let answered = try ledger.answer(accept: true, promptText: nil).get()
        #expect(answered.dialog == dialog)
        #expect(answered.reply.dialogId == dialog.id)
        expectParams(answered.reply.params, ["accept": true])
        #expect(DialogLedger.Reply.method == "Page.handleJavaScriptDialog")
        #expect(ledger.open == nil)

        let again = ledger.answer(accept: false, promptText: nil, dialogId: dialog.id)
        #expect(again == .failure(.alreadyHandled))
        let none = ledger.answer(accept: false, promptText: nil)
        #expect(none == .failure(.noDialog))
        let closedAfterAnswer = ledger.closed()
        #expect(closedAfterAnswer == nil, "closed after our own answer: nothing more to say")
    }

    @Test("an answer naming another dialog is refused")
    func autreDialogue() {
        var ledger = DialogLedger()
        _ = open(&ledger)
        let wrong = ledger.answer(accept: true, promptText: nil, dialogId: 99)
        #expect(wrong == .failure(.otherDialog))
        #expect(ledger.open != nil, "the open one still waits")
    }

    @Test("a prompt accepted sends its text, \"\" without one; a dismissal sends none")
    func texteDuPrompt() throws {
        var ledger = DialogLedger()
        _ = open(&ledger, "prompt", message: "Name?", defaultPrompt: "Ada")
        #expect(ledger.open?.defaultPrompt == "Ada")
        let named = try ledger.answer(accept: true, promptText: "Grace").get()
        expectParams(named.reply.params, ["accept": true, "promptText": "Grace"])

        _ = open(&ledger, "prompt", message: "Name?")
        let empty = try ledger.answer(accept: true, promptText: nil).get()
        expectParams(empty.reply.params, ["accept": true, "promptText": ""])

        _ = open(&ledger, "prompt", message: "Name?")
        let dismissed = try ledger.answer(accept: false, promptText: "ignored").get()
        expectParams(dismissed.reply.params, ["accept": false])

        _ = open(&ledger, "alert", message: "Hi")
        let alert = try ledger.answer(accept: true, promptText: "ignored").get()
        expectParams(alert.reply.params, ["accept": true], "only a prompt takes text")
    }

    @Test("past 20 dialogs in one document, Loom dismisses them at once; a commit starts the count again")
    func bouclesDeDialogues() throws {
        var ledger = DialogLedger()
        for index in 1...DialogLedger.perDocumentLimit {
            guard case .park = open(&ledger, "alert", message: "#\(index)") else {
                Issue.record("dialog \(index) should wait for an answer")
                return
            }
            _ = try ledger.answer(accept: true, promptText: nil).get()
            let closed = ledger.closed()
            #expect(closed == nil)
        }
        guard case .answer(let dialog, let reply, let reason) = open(&ledger, "alert", message: "#21") else {
            Issue.record("the 21st is answered by Loom")
            return
        }
        #expect(reason == .tooMany)
        #expect(reply.accept == false)
        #expect(reply.dialogId == dialog.id)
        #expect(ledger.open == nil, "nothing parked")
        #expect(ledger.openedInDocument == 21)
        let late = ledger.answer(accept: true, promptText: nil, dialogId: dialog.id)
        #expect(late == .failure(.alreadyHandled))

        let gone = ledger.documentCommitted()
        #expect(gone == nil)
        #expect(ledger.openedInDocument == 0)
        guard case .park = open(&ledger, "alert", message: "fresh") else {
            Issue.record("a new document's first dialog waits again")
            return
        }
    }

    @Test("beforeunload is accepted while the agent leaves, modal otherwise")
    func quitterLaPage() {
        var ledger = DialogLedger()
        ledger.autoAcceptBeforeUnload = true
        guard case .answer(let dialog, let reply, let reason) = open(&ledger, "beforeunload", message: "") else {
            Issue.record("the agent's own navigation leaves")
            return
        }
        #expect(dialog.kind == .beforeunload)
        #expect(reason == .agentLeaving)
        expectParams(reply.params, ["accept": true])

        ledger.autoAcceptBeforeUnload = false
        guard case .park(let parked) = open(&ledger, "beforeunload", message: "") else {
            Issue.record("a leave the page asks for itself is a modal state")
            return
        }
        #expect(parked.kind == .beforeunload)

        ledger.autoAcceptBeforeUnload = true
        _ = ledger.dismiss(.navigation)
        guard case .park = open(&ledger, "confirm") else {
            Issue.record("the auto-accept covers beforeunload only")
            return
        }
    }

    @Test("a navigation dismisses the open dialog with an answer; a crash or a detach with none")
    func renvois() {
        var ledger = DialogLedger()
        let nothing = ledger.dismiss(.navigation)
        #expect(nothing?.dialog == nil)

        _ = open(&ledger)
        let navigation = ledger.dismiss(.navigation)
        #expect(navigation?.dialog.message == "Delete?")
        let reply = navigation?.reply
        #expect(reply?.accept == false)
        #expect(reply?.promptText == nil)
        #expect(ledger.open == nil)

        _ = open(&ledger)
        let crash = ledger.dismiss(.crash)
        #expect(crash?.dialog != nil)
        #expect(crash?.reply == nil, "a dead page reads no answer")
        if let id = crash?.dialog.id {
            let late = ledger.answer(accept: true, promptText: nil, dialogId: id)
            #expect(late == .failure(.alreadyHandled))
        }

        _ = open(&ledger)
        let detach = ledger.dismiss(.detach)
        #expect(detach?.dialog != nil)
        #expect(detach?.reply == nil)
    }

    @Test("a dialog Chromium closes itself, or a commit takes away, leaves the ledger")
    func fermeturesSansNous() {
        var ledger = DialogLedger()
        _ = open(&ledger)
        let closed = ledger.closed()
        #expect(closed?.message == "Delete?")
        #expect(ledger.open == nil)

        _ = open(&ledger)
        let gone = ledger.documentCommitted()
        #expect(gone?.message == "Delete?")
        #expect(ledger.open == nil)
    }

    @Test("a dialog opening while one is recorded open supersedes it, with nothing sent for the old one")
    func remplace() {
        var ledger = DialogLedger()
        _ = open(&ledger, "alert", message: "first")
        let (superseded, decision) = ledger.opening(type: "confirm", message: "second", defaultPrompt: nil,
                                                    url: "http://localhost:3000/", frameId: nil)
        #expect(superseded?.message == "first")
        guard case .park(let second) = decision else {
            Issue.record("the new one waits")
            return
        }
        #expect(second.message == "second")
        #expect(second.frameId == nil)
        #expect(ledger.open == second)
    }

    @Test("an unknown dialog type reads as an alert; ids increase")
    func typeInconnu() {
        var ledger = DialogLedger()
        guard case .park(let first) = open(&ledger, "mystery") else {
            Issue.record("parked")
            return
        }
        #expect(first.kind == .alert)
        _ = ledger.dismiss(.navigation)
        guard case .park(let second) = open(&ledger) else {
            Issue.record("parked")
            return
        }
        #expect(second.id > first.id)
    }
}
