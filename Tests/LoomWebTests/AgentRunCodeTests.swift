import Testing
import CoreGraphics
import Foundation
import LoomAPI
import Network
@testable import LoomWeb

// browser_run_code (run-code design §3, §5): the API's command, the bridge's
// messages as the facade posts them (decoded, clamped, refused), the
// expression the agent's code runs in and how its lines are found again, the
// keys the keyboard sends, the answer — and, with LOOM_CHROMIUM pointing at a
// binary, real scripts on a real Chromium. The CDP sequences themselves are
// pinned by Tests/AgentBrowserCDP/runcode.test.mjs.

private func decoded(_ json: String) -> AgentRunDecoded {
    AgentRunCall.decode(json)
}

private func call(_ json: String) throws -> AgentRunCall {
    guard case .call(let call) = decoded(json) else {
        throw AgentRunFailure(message: "refused: \(json)")
    }
    return call
}

private func refusal(_ json: String) -> (id: Int?, message: String)? {
    guard case .refused(let id, let failure) = decoded(json) else { return nil }
    return (id, failure.message)
}

@Suite("browser_run_code — the command")
struct RunCodeCommandTests {

    private func command(_ params: [String: JSONValue]) throws -> AgentCommand {
        try AgentCommand(method: .browserRunCode, params: .object(params))
    }

    private func code(_ params: [String: JSONValue]) -> APIError? {
        do {
            _ = try command(params)
            return nil
        } catch let error as APIError {
            return error
        } catch {
            return APIError(code: .internalError, message: "\(error)")
        }
    }

    @Test("code decodes as given (its lines are the agent's); it opens a page and shows the panel")
    func decodage() throws {
        let source = "\nasync (page) => {\n  return await page.title();\n}\n"
        #expect(try command(["code": .string(source)]) == .runCode(source))
        #expect(AgentCommand.runCode("1").createsBrowser, "page exists on a fresh browser: about:blank")
        #expect(AgentCommand.runCode("1").touchesPage)
        let options = try AgentCommandOptions(method: .browserRunCode, params: .object(["code": .string("1"),
                                                                                        "snapshot": .string("none")]))
        #expect(options.snapshot == .none, "the final snapshot is opt-out")
    }

    @Test("no code, blank code, more than 64 KB, or a filename: invalidParams the agent can fix")
    func refus() {
        #expect(code([:])?.code == .invalidParams)
        #expect(code(["code": .string(" \n ")])?.code == .invalidParams)
        #expect(code(["code": .string(String(repeating: "x", count: AgentCommand.maxCodeBytes))]) == nil, "64 KB fit")
        #expect(code(["code": .string(String(repeating: "x", count: AgentCommand.maxCodeBytes + 1))])?.code == .invalidParams)
        let filename = code(["code": .string("async (page) => 1"), "filename": .string("result.json")])
        #expect(filename?.code == .invalidParams)
        #expect(filename?.message.contains("filename is not supported") == true, "\(filename?.message ?? "")")
        #expect(filename?.message.contains("@script.js") == true, "it says what to do instead")
    }

    @Test("WebKit answers that it needs Chromium; both engines' pills say what runs")
    @MainActor
    func webKit() {
        #expect(AgentBrowser.runCodeUnavailable.contains("needs the Chromium engine"))
        #expect(AgentBrowser.runCodeUnavailable.contains("Settings ▸ Agents"))
        #expect(AgentBrowser.summary(of: .runCode("1")) == "Running code")
        #expect(ChromiumAgentCore.summary(of: .runCode("1")) == "Running code")
    }

    @Test("the method's deadline holds 56 s of script, the end, and one cold navigation")
    func budget() throws {
        let limits = AgentRunLimits()
        let deadline = try #require(APIMethod.browserRunCode.appDeadline)
        #expect(deadline >= limits.scriptTime + limits.endReserve)
        #expect(Duration.milliseconds(limits.navigationTimeout) + limits.endReserve < deadline, "one cold navigation fits")
        #expect(limits.maxSteps == 1_000 && limits.maxInFlight == 32 && limits.maxMessageBytes == 262_144)
    }
}

@Suite("browser_run_code — the bridge's messages")
struct RunCodeBridgeTests {

    static let click = #"""
    {"id":12,"op":"click","line":4,
     "target":{"chain":[{"role":"button","name":{"s":"Save","m":"ci"}}],"desc":"getByRole('button', { name: 'Save' })","strict":true},
     "args":{"button":"left","clickCount":1,"modifiers":["Shift"],"position":null,"force":false,"trial":false,"delay":0,"timeout":5000}}
    """#

    @Test("the design's click message: its target forwarded as it came, its lane, its words")
    func clic() throws {
        let decoded = try call(Self.click)
        #expect(decoded.id == 12 && decoded.line == 4)
        #expect(decoded.api == "locator.click")
        guard case .click(let target, let pointer, let timeout) = decoded.op else {
            Issue.record("not a click: \(decoded.op)")
            return
        }
        #expect(target.desc == "getByRole('button', { name: 'Save' })" && target.strict)
        #expect(target.json.contains(#""role":"button""#))
        #expect(pointer.button == .left && pointer.clickCount == 1 && pointer.modifiers == ["Shift"])
        #expect(pointer.position == nil && !pointer.force && !pointer.trial && pointer.delay == 0)
        #expect(timeout == 5_000)
        #expect(decoded.op.lane == .action)
        #expect(decoded.op.summary == "click getByRole('button', { name: 'Save' })")
    }

    @Test("a selector string is a locator of one step, strict unless said otherwise")
    func selecteur() throws {
        let decoded = try call(##"{"id":1,"op":"fill","target":"#email","value":"a@b.c"}"##)
        guard case .fill(let target, let value, _) = decoded.op else {
            Issue.record("not a fill")
            return
        }
        #expect(value == "a@b.c")
        #expect(target.desc == "locator('#email')" && target.strict)
        #expect(target.json.contains(##""selector":"#email""##))
        let loose = try call(#"{"id":2,"op":"click","target":"text=Save","strict":false}"#)
        #expect(loose.op.target?.strict == false)
    }

    @Test("values are clamped: timeouts, delays, steps, click counts")
    func bornes() throws {
        let slow = try call(##"{"id":1,"op":"click","target":"#a","args":{"timeout":999999,"delay":5000,"clickCount":9}}"##)
        guard case .click(_, let pointer, let timeout) = slow.op else {
            Issue.record("not a click")
            return
        }
        #expect(timeout == 60_000 && pointer.delay == 1_000 && pointer.clickCount == 3)
        let negative = try call(##"{"id":2,"op":"waitState","target":"#a","timeout":-5}"##)
        #expect(negative.op == .waitState(negative.op.target!, state: "visible", timeout: 0), "no time left: one attempt")
        let moved = try call(#"{"id":3,"op":"mouse","action":"move","x":10,"y":20,"steps":500}"#)
        #expect(moved.op == .mouse(.move, x: 10, y: 20, button: .left, clickCount: 1, steps: 100, deltaX: 0, deltaY: 0,
                                   delay: 0))
        let nap = try call(#"{"id":4,"op":"sleep","ms":120000}"#)
        #expect(nap.op == .sleep(milliseconds: 60_000))
    }

    @Test("each op its lane: actions in order, waits beside them, dialog answers at once")
    func voies() throws {
        let waits = [##"{"id":1,"op":"waitState","target":"#a","state":"hidden"}"##, #"{"id":2,"op":"waitLoad","state":"load"}"#,
                     #"{"id":3,"op":"nextURL","since":"http://x/"}"#, #"{"id":4,"op":"waitFn","fn":"() => true"}"#,
                     #"{"id":5,"op":"sleep","ms":10}"#]
        for json in waits {
            #expect(try call(json).op.lane == .wait, "\(json)")
        }
        let answer = try call(#"{"id":6,"op":"dialog","args":{"id":3,"accept":true,"promptText":"x"}}"#)
        #expect(answer.id == 6 && answer.op == .dialog(id: 3, accept: true, promptText: "x"), "the dialog's id is in args")
        #expect(answer.op.lane == .immediate)
        #expect(try call(#"{"id":7,"op":"listen","dialog":true}"#).op == .listen(dialog: true))
        #expect(try call(#"{"id":8,"op":"goto","url":"/next"}"#).op == .goto(url: "/next", waitUntil: .load, timeout: nil))
        #expect(try call(#"{"id":9,"op":"title"}"#).op.lane == .action)
    }

    @Test("selectOption's options: a string, {value}, {label}, {index}")
    func options() throws {
        let select = try call(##"{"id":1,"op":"select","target":"#s","options":["a",{"value":"b"},{"label":"C"},{"index":2}]}"##)
        guard case .select(_, let options, _) = select.op else {
            Issue.record("not a select")
            return
        }
        #expect(options == [.text("a"), .value("b"), .label("C"), .index(2)])
    }

    @Test("evaluate's argument travels as JSON; none is undefined")
    func evaluation() throws {
        let withArg = try call(#"{"id":1,"op":"eval","fn":"(x) => x.a","arg":{"a":1}}"#)
        #expect(withArg.op == .evaluate(function: "(x) => x.a", argument: #"{"a":1}"#, target: nil, all: false))
        let bare = try call(#"{"id":2,"op":"eval","fn":"document.title"}"#)
        #expect(bare.op == .evaluate(function: "document.title", argument: "undefined", target: nil, all: false))
        // page.evaluate(fn, null): the facade sends "arg":null, and null it stays.
        let explicitNull = try call(#"{"id":4,"op":"eval","args":{"fn":"(x) => x === null","arg":null}}"#)
        #expect(explicitNull.op == .evaluate(function: "(x) => x === null", argument: "null", target: nil, all: false))
        let all = try call(#"{"id":3,"op":"eval","fn":"(es) => es.length","target":"li","all":true}"#)
        #expect(all.api == "locator.evaluateAll")
    }

    @Test("what cannot be decoded is refused — with its id when it has one, never a crash")
    func refus() {
        #expect(refusal(#"{"id":3,"op":"fly"}"#)?.id == 3)
        #expect(refusal(#"{"id":3,"op":"fly"}"#)?.message == "unknown page call fly")
        #expect(refusal(#"{"op":"click"}"#)?.id == nil, "no id: nothing to answer")
        #expect(refusal("not json")?.id == nil)
        #expect(refusal("[1,2]")?.id == nil)
        #expect(refusal(#"{"id":4,"op":"click"}"#)?.message == "this call needs a locator")
        #expect(refusal(#"{"id":5,"op":"goto"}"#)?.message == "url is required")
        #expect(refusal(#"{"id":6,"op":"goto","url":"/","waitUntil":"later"}"#)?.id == 6)
        #expect(refusal(#"{"id":7,"op":"click","target":{"desc":"no chain"}}"#)?.id == 7)
        #expect(refusal(#"{"id":8,"op":"viewport","width":100}"#)?.id == 8, "ViewportWidth.range")
        #expect(refusal(#"{"id":9,"op":"key","action":"type"}"#)?.message == "text is required")
        #expect(refusal(#"{"id":10,"op":"mouse","action":"click","x":1}"#)?.id == 10, "a click needs x and y")
        let paths = (0...32).map { "\"/w/\($0).png\"" }.joined(separator: ",")
        #expect(refusal(##"{"id":11,"op":"files","target":"#f","paths":[\##(paths)]}"##)?.id == 11, "32 files at most")
        let chain = String(repeating: #"{"css":"div"},"#, count: 1_500) + #"{"css":"p"}"#
        #expect(refusal(#"{"id":12,"op":"count","target":{"chain":[\#(chain)],"desc":"big"}}"#)?.id == 12, "16 KB at most")
        let huge = ##"{"id":13,"op":"fill","target":"#a","value":""## + String(repeating: "x", count: 262_144) + #""}"#
        #expect(refusal(huge)?.id == nil, "over 256 KB: dropped unparsed")
    }

    @Test("a reply as the facade reads it: value as JSON, undefined left out, the page's URL")
    func reponses() {
        #expect(AgentRunReply(id: 12, ok: true, value: "null", url: "http://x/").json
                == #"{"id":12,"ok":true,"value":null,"url":"http://x/"}"#)
        #expect(AgentRunReply(id: 3, ok: true, value: "undefined").json == #"{"id":3,"ok":true}"#)
        #expect(AgentRunReply(id: 4, ok: true, value: #"{"a":[1,"b"]}"#).json == #"{"id":4,"ok":true,"value":{"a":[1,"b"]}}"#)
        let failed = AgentRunReply(id: 5, ok: false, error: AgentRunFailure(name: "TimeoutError", message: "a \"b\"\nc"),
                                   url: "http://x/a?b=1")
        #expect(failed.json == #"{"id":5,"ok":false,"error":{"name":"TimeoutError","message":"a \"b\"\nc"},"url":"http://x/a?b=1"}"#)
        let parsed = try? JSONSerialization.jsonObject(with: Data(failed.json.utf8)) as? [String: Any]
        #expect(parsed?["ok"] as? Bool == false, "valid JSON")
    }

    @Test("a call's failure: Playwright's TimeoutError words; any other named after the call")
    func echecs() {
        let timeout = ChromiumAgentCore.runFailure(ChromiumRunTimeout(api: "locator.click", milliseconds: 5_000,
                                                                      waiting: "waiting for getByRole('button')",
                                                                      reason: "element is not visible"),
                                                   api: "locator.click")
        #expect(timeout == AgentRunFailure(name: "TimeoutError", message: """
            locator.click: Timeout 5000ms exceeded.
            Call log:
              - waiting for getByRole('button')
              - element is not visible
            """))
        let strict = ChromiumAgentCore.runFailure(AgentError.invalid("strict mode violation: getByRole('button') resolved to 2 elements"),
                                                  api: "locator.click")
        #expect(strict == AgentRunFailure(name: "Error",
                                          message: "locator.click: strict mode violation: getByRole('button') resolved to 2 elements"))
        let gone = ChromiumAgentCore.runFailure(AgentError.unavailable("the tab was closed during the command"),
                                                api: "page.title")
        #expect(gone == AgentRunFailure(name: "Error", message: "page.title: the tab was closed during the command"))
    }
}

@Suite("browser_run_code — the code and its lines")
struct RunCodeSourceTests {

    @Test("a function runs as given; anything else is the body of one; line 1 is the agent's first")
    func expression() {
        let function = AgentRunSource.expression(code: "async (page) => { return 1; };\n\n")
        #expect(function == "globalThis.__loomRun.run((\nasync (page) => { return 1; }\n))\n//# sourceURL=browser_run_code.js")
        let body = AgentRunSource.expression(code: "await page.goto('/');\nreturn page.url();")
        #expect(body == "globalThis.__loomRun.run((async (page) => {\nawait page.goto('/');\nreturn page.url();\n}))\n"
                + "//# sourceURL=browser_run_code.js")
        // A leading blank line stays: the agent's line numbers do too.
        #expect(AgentRunSource.expression(code: "\nasync (page) => 1").hasPrefix("globalThis.__loomRun.run((\n\nasync"))
        // A trailing line comment cannot swallow the call's end.
        #expect(AgentRunSource.expression(code: "async (page) => 1 // done").contains("// done\n))"))
    }

    @Test("a stack's browser_run_code.js:L is the agent's line L − 1; a SyntaxError's 0-based line is its 1-based one")
    func lignes() {
        #expect(AgentRunSource.agentLine(stack: "TypeError: x\n    at async <anonymous> (browser_run_code.js:3:15)") == 2)
        #expect(AgentRunSource.agentLine(stack: "Error\n    at f (loom-runner.js:40:2)\n    at browser_run_code.js:2:1") == 1)
        #expect(AgentRunSource.agentLine(stack: "Error: no frame") == nil)
        #expect(AgentRunSource.agentLine(stack: "at browser_run_code.js:1:30") == nil, "line 1 is the wrapper's")
        #expect(AgentRunSource.agentLine(exceptionLine: 3) == 3)
        #expect(AgentRunSource.agentLine(exceptionLine: 0) == nil)
    }

    @Test("page.evaluate in the page's world: the element first, then the argument, through the serializer")
    func evaluationDansLaPage() {
        let one = ChromiumAgentCore.runEvaluateExpression(function: "(el, arg) => el.id + arg", argument: #""-x""#,
                                                          nonce: "n1", all: false)
        #expect(one.contains(#"const __loomNonce = "n1";"#))
        #expect(one.contains(#"const __loomArg = ("-x");"#))
        #expect(one.contains("__loomTarget = found[0];"))
        #expect(one.contains("await __loomFunction(__loomTarget, __loomArg)"))
        #expect(one.contains(AgentScripts.serializer))
        let all = ChromiumAgentCore.runEvaluateExpression(function: "(els) => els.length", argument: "undefined",
                                                          nonce: "n2", all: true)
        #expect(all.contains("__loomTarget = found;"))
        let expression = ChromiumAgentCore.runEvaluateExpression(function: "document.title", argument: "undefined",
                                                                 nonce: "", all: false)
        #expect(expression.contains("() => (\ndocument.title\n)"), "an expression is wrapped into a function")
        #expect(ChromiumAgentCore.runWaitExpression(function: "() => window.ready", argument: "undefined")
                .contains("return __loomValue ? ("))
    }

    @Test("goto resolves a relative address against the page's; anything else goes to the policy as typed")
    func adresses() {
        let base = "http://127.0.0.1:5173/app/list?x=1"
        #expect(ChromiumAgentCore.runResolve("/next", against: base) == "http://127.0.0.1:5173/next")
        #expect(ChromiumAgentCore.runResolve("?page=2", against: base) == "http://127.0.0.1:5173/app/list?page=2")
        #expect(ChromiumAgentCore.runResolve("#top", against: base) == "http://127.0.0.1:5173/app/list?x=1#top")
        #expect(ChromiumAgentCore.runResolve("../a", against: base) == "http://127.0.0.1:5173/a")
        #expect(ChromiumAgentCore.runResolve("localhost:3000", against: base) == "localhost:3000")
        #expect(ChromiumAgentCore.runResolve("https://example.com/", against: base) == "https://example.com/")
        #expect(ChromiumAgentCore.runResolve("/next", against: "about:blank") == "/next", "nothing to resolve against")
    }

    @Test("the facade is installed, then started with the run's configuration, in one evaluation")
    func installation() {
        let config = AgentRunnerScript.Config(url: "about:blank", viewport: .init(width: 1_280, height: 800))
        let expression = ChromiumRunner.installExpression(config: config)
        #expect(expression.hasPrefix(AgentRunnerScript.facade))
        #expect(expression.contains("globalThis.__loomRun.start({"))
        #expect(expression.contains(#""defaultTimeout":5000"#))
        #expect(expression.contains(#""url":"about:blank""#))
        #expect(ChromiumRunner.replyFunction == AgentRunnerScript.answerFunction)
        #expect(ChromiumRunner.eventFunction == AgentRunnerScript.answerFunction)
        #expect(ChromiumRunner.bindingName == AgentRunnerScript.bindingName, "the fence adds the facade's binding")
        #expect(AgentRunSource.sourceURL == AgentRunnerScript.sourceURL)
        let limits = AgentRunLimits()
        #expect(config.defaultTimeout == limits.actionTimeout && config.navigationTimeout == limits.navigationTimeout)
        #expect(config.maxSteps == limits.maxSteps && config.maxInFlight == limits.maxInFlight)
        #expect(config.maxMessageBytes == limits.maxMessageBytes)
    }
}

@Suite("browser_run_code — keys")
struct RunCodeKeyTests {

    private func names(_ events: [(String, [String: Any])]) -> [String] {
        events.map { "\($0.1["type"] as? String ?? "?") \($0.1["key"] as? String ?? "?") \($0.1["modifiers"] as? Int ?? -1)" }
    }

    @Test("a modifier alone goes down and up as itself: keyboard.down('Shift')")
    func modificateur() throws {
        let shift = try ChromiumAgentCore.runKeyEvents("Shift", held: [])
        #expect(names(shift.down) == ["rawKeyDown Shift 8"])
        #expect(names(shift.up) == ["keyUp Shift 0"])
        #expect(ChromiumAgentCore.runModifier("ControlOrMeta")?.0 == .meta, "⌘ on a Mac")
        #expect(ChromiumAgentCore.runModifier("a") == nil)
    }

    @Test("a combination presses its own modifiers around the key; one already held is not pressed again")
    func combinaisons() throws {
        let select = try ChromiumAgentCore.runKeyEvents("Control+a", held: [])
        #expect(names(select.down) == ["rawKeyDown Control 2", "rawKeyDown a 2"])
        #expect(names(select.up) == ["keyUp a 2", "keyUp Control 0"])
        let held = try ChromiumAgentCore.runKeyEvents("a", held: [.shift])
        #expect(names(held.down) == ["keyDown a 8"], "the held Shift is in its flags, not pressed again")
        #expect(names(held.up) == ["keyUp a 8"])
        #expect(throws: AgentError.self) { _ = try ChromiumAgentCore.runKeyEvents("Hyper+q", held: []) }
    }
}

@Suite("browser_run_code — the answer")
struct RunCodeAnswerTests {

    private let page = AgentPageSummary(url: "http://localhost:5173/next", title: "Next")

    private func render(_ report: AgentRunReport) -> String {
        let (prefix, result) = report.sections(resultLimit: 20_000)
        let rendered = AgentResponseBuilder.render(result: result, page: page, tabs: [], modal: nil,
                                                   snapshot: "- button \"Go\" [ref=e1]", events: [])
        return AgentRunReport.compose(prefix: prefix, page: rendered)
    }

    @Test("a value: ### Result as JSON, the script's output after it, then the page and its snapshot")
    func valeur() {
        var report = AgentRunReport()
        report.value = "{\n  \"count\": 2\n}"
        report.output = ["on http://localhost:5173/next"]
        let text = render(report)
        #expect(text.hasPrefix("### Result\n```json\n{\n  \"count\": 2\n}\n```\n\n### Script output\non http://localhost:5173/next"
                               + "\n\n### Page\n- Page URL: http://localhost:5173/next"), "\(text)")
        #expect(text.contains("### Snapshot\n```yaml\n- button \"Go\" [ref=e1]"))
        #expect(!report.isError)
    }

    @Test("an error comes first, with the steps before it; no value means no ### Result")
    func erreur() {
        var report = AgentRunReport()
        report.error = "TimeoutError: locator.click: Timeout 5000ms exceeded. (line 3 of your code)"
        report.steps = ["5) fill getByLabel('Email')", "6) click getByRole('button', { name: 'Sign in' })"]
        report.output = ["filled"]
        let text = render(report)
        #expect(text.hasPrefix("### Error\nTimeoutError: locator.click: Timeout 5000ms exceeded. (line 3 of your code)\n"
                               + "Steps before it: 5) fill getByLabel('Email') 6) click getByRole('button', { name: 'Sign in' })"
                               + "\n\n### Script output\nfilled\n\n### Page"), "\(text)")
        #expect(!text.contains("### Result"))
        #expect(report.isError)
        #expect(AgentResult(text: text, isError: true).apiContent.isError == true)
        #expect(AgentResult(text: "### Page").apiContent.isError == nil, "every other answer's JSON unchanged")
    }

    @Test("undefined answers no ### Result; a long value and long output are cut, saying so")
    func coupes() {
        var report = AgentRunReport()
        report.value = "undefined"
        #expect(report.sections(resultLimit: 100).result == nil)
        report.value = "\"" + String(repeating: "x", count: 50) + "\""
        let body = report.resultBody(limit: 10) ?? ""
        #expect(body.hasSuffix("\n… (cut at 10 characters)\n```"), "\(body)")
        report.output = ["aaaa", "bbbb", "cccc"]
        report.outputDropped = 2
        #expect(report.outputSection(limit: 9) == "### Script output\naaaa\nbbbb\n… (3 more lines)")
        #expect(report.outputSection(limit: 100) == "### Script output\naaaa\nbbbb\ncccc\n… (2 more lines)")
    }

    @Test("calls still pending when the function returned are named for ### Events")
    func appelsEnCours() {
        var report = AgentRunReport()
        #expect(report.unfinishedNote == nil)
        report.unfinished = ["click", "fill"]
        #expect(report.unfinishedNote
                == "2 page calls were still running when your function returned (missing await?): click, fill")
    }
}

// MARK: - A real Chromium

@Suite("browser_run_code — a real session (LOOM_CHROMIUM)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_CHROMIUM"].map { !$0.isEmpty } ?? false))
struct ChromiumRunCodeSessionTests {

    static let first = """
        <!doctype html>
        <html><head><title>First</title></head>
        <body><h1>First</h1><a href="/next">Next page</a></body></html>
        """

    static let next = """
        <!doctype html>
        <html><head><title>Next</title></head>
        <body>
        <h1>Next</h1>
        <button id="go">Go</button>
        <p id="out">waiting</p>
        <script>
        document.getElementById('go').addEventListener('click', (event) => {
          document.getElementById('out').textContent = 'clicked ' + event.isTrusted;
        });
        </script>
        </body></html>
        """

    @Test("a script clicks across a navigation, waits for the URL, clicks again; a spinning one is stopped")
    @MainActor
    func scripts() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOOM_CHROMIUM"])
        let server = RunCodePageServer(pages: ["/": Data(Self.first.utf8), "/next": Data(Self.next.utf8)])
        let started = await server.start()
        let port = try #require(started, "the test pages could not be served on 127.0.0.1")
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-run-code-" + UUID().uuidString, isDirectory: true)
        let environment = AgentBrowser.Environment(screenshotsDirectory: root.appendingPathComponent("shots"),
                                                    initialViewport: CGSize(width: 1_000, height: 800))
        let browser = ChromiumAgentBrowser.standalone(executablePath: path, root: root.appendingPathComponent("chromium"),
                                                      environment: environment)
        do {
            _ = try await browser.run(.navigate(URL(string: "http://127.0.0.1:\(port)/")!),
                                      deadline: ContinuousClock.now + .seconds(30))
            let code = """
                async (page) => {
                  await Promise.all([page.waitForURL('**/next'), page.getByRole('link', { name: 'Next page' }).click()]);
                  await page.getByRole('button', { name: 'Go' }).click();
                  console.log('on', page.url());
                  return { title: await page.title(), out: await page.locator('#out').textContent() };
                }
                """
            let answer = try await browser.run(.runCode(code), deadline: ContinuousClock.now + .seconds(60))
            #expect(!answer.isError, "\(answer.text)")
            #expect(answer.text.hasPrefix("### Result\n```json"), "\(answer.text)")
            #expect(answer.text.contains("clicked true"), "a trusted click on the new page: \(answer.text)")
            #expect(answer.text.contains("\"Next\""), "\(answer.text)")
            #expect(answer.text.contains("### Script output") && answer.text.contains("/next"), "\(answer.text)")
            #expect(answer.text.contains("- Page URL: http://127.0.0.1:\(port)/next"), "\(answer.text)")
            #expect(answer.text.contains("### Snapshot"), "\(answer.text)")

            // 8 s of deadline: 4 s of script, then the stop — terminateExecution, the target closed.
            let spinStarted = ContinuousClock.now
            let spun = try await browser.run(.runCode("async (page) => { while (true) {} }"),
                                             deadline: spinStarted + .seconds(8))
            let elapsed = spinStarted.duration(to: .now)
            #expect(spun.isError, "\(spun.text)")
            #expect(spun.text.hasPrefix("### Error\nThe script ran out of time"), "\(spun.text)")
            #expect(elapsed < Duration.seconds(5) + .milliseconds(500), "stopped within about a second of its time: \(elapsed)")

            // The next run gets a fresh sandbox: nothing of the stop is left.
            let next = try await browser.run(.runCode("async (page) => 6 * 7"), deadline: ContinuousClock.now + .seconds(30))
            #expect(!next.isError && next.text.hasPrefix("### Result\n```json\n42\n```"), "\(next.text)")

            // A SyntaxError: nothing ran, its line is the agent's.
            let broken = try await browser.run(.runCode("async (page) => {\n  const a = ;\n}"),
                                               deadline: ContinuousClock.now + .seconds(30))
            #expect(broken.isError && broken.text.hasPrefix("### Error\nSyntaxError"), "\(broken.text)")
            #expect(broken.text.contains("line 2"), "\(broken.text)")
        } catch {
            Issue.record("\(error)")
        }
        await browser.shutDown()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Serves a few pages on 127.0.0.1 — any other path is a 404.
private final class RunCodePageServer: @unchecked Sendable {
    private let pages: [String: Data]
    private let queue = DispatchQueue(label: "app.loom.tests.run-code")
    private var listener: NWListener?

    init(pages: [String: Data]) {
        self.pages = pages
    }

    func start() async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let once = RunCodeResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [pages] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            let page = pages[path]
            let body = page ?? Data("not found".utf8)
            let head = "HTTP/1.1 \(page != nil ? "200 OK" : "404 Not Found")\r\n"
                + "Content-Type: \(page != nil ? "text/html; charset=utf-8" : "text/plain")\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class RunCodeResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
