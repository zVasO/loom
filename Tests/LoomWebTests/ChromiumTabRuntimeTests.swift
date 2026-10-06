import Testing
import CoreGraphics
import Foundation
import LoomWeb

// The Chromium engine's per-tab layer (ADR-0015), its pure parts: the keys
// as DevTools commands, the per-target init against the CDP harness's
// fixtures/init.json, what a binding payload may be, the helper's answers
// and who a dialog's banner names. The live session is the harness's
// (Tests/AgentBrowserCDP) and the self-test's on a Mac.

/// The CDP harness's sequences (Tests/AgentBrowserCDP/lib/init.mjs), when present.
private let initFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("AgentBrowserCDP/fixtures/init.json")

private let hasInitFixture = FileManager.default.fileExists(atPath: initFixture.path)

/// Commands as JSON, keys sorted: what a failed comparison shows.
private func shown(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
        return String(describing: value)
    }
    return String(decoding: data, as: UTF8.self)
}

private func rendered(_ commands: [(String, [String: Any])]) -> [Any] {
    commands.map { command -> Any in [command.0, command.1] as [Any] }
}

/// The command is exactly `method` with `expected` (numbers and booleans
/// compare by value). Compared outside #expect: the literal keeps its type.
private func expectCommand(_ command: (String, [String: Any]), _ method: String, _ expected: [String: Any]) {
    let matches = command.0 == method && (command.1 as NSDictionary).isEqual(expected as NSDictionary)
    let text = command.0 + " " + shown(command.1)
    #expect(matches, "\(text)")
}

private func fixture() throws -> [String: Any] {
    let data = try Data(contentsOf: initFixture)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

private let key = "Input.dispatchKeyEvent"

@Suite("Chromium tab — keys as trusted input")
struct ChromiumKeySpecTests {

    @Test("Enter is keyDown with text \\r (the only one that submits), then keyUp")
    func entree() throws {
        let events = try KeySpec.parse("Enter").cdpPress()
        try #require(events.count == 2, "\(shown(rendered(events)))")
        expectCommand(events[0], key, ["type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13,
                                       "nativeVirtualKeyCode": 13, "modifiers": 0, "text": "\r", "unmodifiedText": "\r"])
        expectCommand(events[1], key, ["type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13,
                                       "nativeVirtualKeyCode": 13, "modifiers": 0])
    }

    @Test("Tab and Shift+Tab type nothing: rawKeyDown, so focus moves natively; Shift goes around")
    func tabulation() throws {
        let tab = try KeySpec.parse("Tab").cdpPress()
        try #require(tab.count == 2)
        expectCommand(tab[0], key, ["type": "rawKeyDown", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9,
                                    "nativeVirtualKeyCode": 9, "modifiers": 0])
        let back = try KeySpec.parse("Shift+Tab").cdpPress()
        try #require(back.count == 4, "\(shown(rendered(back)))")
        expectCommand(back[0], key, ["type": "rawKeyDown", "key": "Shift", "code": "ShiftLeft",
                                     "windowsVirtualKeyCode": 16, "nativeVirtualKeyCode": 16, "modifiers": 8,
                                     "location": 1])
        expectCommand(back[1], key, ["type": "rawKeyDown", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9,
                                     "nativeVirtualKeyCode": 9, "modifiers": 8])
        expectCommand(back[3], key, ["type": "keyUp", "key": "Shift", "code": "ShiftLeft", "windowsVirtualKeyCode": 16,
                                     "nativeVirtualKeyCode": 16, "modifiers": 0, "location": 1])
    }

    @Test("ControlOrMeta+a is Meta on a Mac: around a textless a carrying selectAll")
    func toutSelectionner() throws {
        let events = try KeySpec.parse("ControlOrMeta+a").cdpPress()
        try #require(events.count == 4, "\(shown(rendered(events)))")
        expectCommand(events[0], key, ["type": "rawKeyDown", "key": "Meta", "code": "MetaLeft",
                                       "windowsVirtualKeyCode": 91, "nativeVirtualKeyCode": 91, "modifiers": 4,
                                       "location": 1])
        expectCommand(events[1], key, ["type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                       "nativeVirtualKeyCode": 65, "modifiers": 4, "commands": ["selectAll"]])
        expectCommand(events[2], key, ["type": "keyUp", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                       "nativeVirtualKeyCode": 65, "modifiers": 4])
        expectCommand(events[3], key, ["type": "keyUp", "key": "Meta", "code": "MetaLeft", "windowsVirtualKeyCode": 91,
                                       "nativeVirtualKeyCode": 91, "modifiers": 0, "location": 1])
    }

    @Test("Meta+C and Meta+V carry copy and paste; Control+A the Mac's own; Backspace deleteBackward")
    func commandesMac() throws {
        let copy = try KeySpec.parse("Meta+c").cdpPress()
        let paste = try KeySpec.parse("Meta+v").cdpPress()
        let controlA = try KeySpec.parse("Control+a").cdpPress()
        let backspace = try KeySpec.parse("Backspace").cdpPress()
        let copyCommands = copy.count == 4 ? copy[1].1["commands"] as? [String] : nil
        let pasteCommands = paste.count == 4 ? paste[1].1["commands"] as? [String] : nil
        let controlCommands = controlA.count == 4 ? controlA[1].1["commands"] as? [String] : nil
        #expect(copyCommands == ["copy"])
        #expect(pasteCommands == ["paste"])
        #expect(controlCommands == ["moveToBeginningOfParagraph"])
        try #require(backspace.count == 2)
        expectCommand(backspace[0], key, ["type": "rawKeyDown", "key": "Backspace", "code": "Backspace",
                                          "windowsVirtualKeyCode": 8, "nativeVirtualKeyCode": 8, "modifiers": 0,
                                          "commands": ["deleteBackward"]])
    }

    @Test("a plain letter, Space and Alt+letter: no command where the Mac table lists none")
    func sansCommande() throws {
        let letter = try KeySpec.parse("a").cdpPress()
        try #require(letter.count == 2)
        expectCommand(letter[0], key, ["type": "keyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                       "nativeVirtualKeyCode": 65, "modifiers": 0, "text": "a", "unmodifiedText": "a"])
        let space = try KeySpec.parse("Space").cdpPress()
        try #require(space.count == 2)
        expectCommand(space[0], key, ["type": "keyDown", "key": " ", "code": "Space", "windowsVirtualKeyCode": 32,
                                      "nativeVirtualKeyCode": 32, "modifiers": 0, "text": " ", "unmodifiedText": " "])
        let alt = try KeySpec.parse("Alt+a").cdpPress()
        try #require(alt.count == 4)
        expectCommand(alt[1], key, ["type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                    "nativeVirtualKeyCode": 65, "modifiers": 1])
    }

    @Test("typing: a capital is Shift and the letter, a newline Enter, é inserted as text")
    func frappe() throws {
        let capital = KeySpec.typing("A").cdpTyping()
        try #require(capital.count == 4, "\(shown(rendered(capital)))")
        expectCommand(capital[1], key, ["type": "keyDown", "key": "A", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                        "nativeVirtualKeyCode": 65, "modifiers": 8, "text": "A",
                                        "unmodifiedText": "A"])
        let newline = KeySpec.typing("\n").cdpTyping()
        try #require(newline.count == 2)
        let typed = newline[0].1["text"] as? String
        #expect(typed == "\r")
        let accent = KeySpec.typing("é").cdpTyping()
        try #require(accent.count == 1)
        expectCommand(accent[0], "Input.insertText", ["text": "é"])
    }

    @Test("type slowly goes in writes of 8 keys; a key's events never straddle two writes")
    func fenetresDeTouches() {
        let writes = KeySpec.cdpTypingWrites("hello world")
        let sizes = writes.map { $0.count }
        #expect(sizes == [16, 6])
        let mixed = KeySpec.cdpTypingWrites("Hi!")
        let mixedSizes = mixed.map { $0.count }
        #expect(mixedSizes == [7], "Shift+H 4, i 2, ! inserted 1")
        let single = KeySpec.cdpTypingWrites("abc", keysPerWrite: 1)
        let singleSizes = single.map { $0.count }
        #expect(singleSizes == [2, 2, 2])
        #expect(KeySpec.cdpTypingWrites("").isEmpty)
    }
}

@Suite("Chromium tab — the per-target init")
struct ChromiumTabInitTests {

    private let agent = ChromiumUserAgent(major: "{major}", fullVersion: "{fullVersion}", acceptLanguage: "en-US,en",
                                          platformVersion: "15.0.0", architecture: "arm")

    private func placeholders() -> [(String, [String: Any])] {
        ChromiumTabRuntime.initCommands(viewport: CGSize(width: 1280, height: 800), userAgent: agent,
                                        relay: "{relay}", pageHook: "{pageHook}", helperTopFrame: "{helperTopFrame}")
    }

    @Test("the init is the CDP harness's, command for command", .enabled(if: hasInitFixture))
    func commeLeBanc() throws {
        let document = try fixture()
        let expected = try #require(document["target"] as? [Any])
        let ours = rendered(placeholders())
        let theirMethods = expected.compactMap { ($0 as? [Any])?.first as? String }
        let ourMethods = placeholders().map { $0.0 }
        #expect(ourMethods == theirMethods)
        let same = (ours as NSArray).isEqual(to: expected)
        let mine = shown(ours)
        let theirs = shown(expected)
        #expect(same, "ours: \(mine)\nharness: \(theirs)")
    }

    @Test("at every commit: the frame's world, then the binding; a helper call and the stuck probe as the harness sends them",
          .enabled(if: hasInitFixture))
    func sequencesDuBanc() throws {
        let document = try fixture()
        let onCommit = try #require(document["onFrameNavigated"] as? [Any])
        let ours = rendered(ChromiumTabRuntime.frameNavigatedCommands(frameId: "{frameId}"))
        let sameCommit = (ours as NSArray).isEqual(to: onCommit)
        let shownCommit = shown(ours)
        #expect(sameCommit, "\(shownCommit)")

        let call = try #require(document["helperCall"] as? [Any])
        try #require(call.count == 2)
        var theirParams = try #require(call[1] as? [String: Any])
        theirParams["executionContextId"] = 7
        let ourCall = ChromiumHelper.callCommand(op: "{op}", argsJSON: "{argsJSON}", contextId: 7)
        #expect(ourCall.0 == call[0] as? String)
        expectCommand(ourCall, "Runtime.callFunctionOn", theirParams)

        let probe = try #require(document["stuckProbe"] as? [Any])
        try #require(probe.count == 2)
        let theirProbe = try #require(probe[1] as? [String: Any])
        let probeMethod = try #require(probe[0] as? String)
        expectCommand(ChromiumTabRuntime.stuckProbeCommand, probeMethod, theirProbe)
    }

    @Test("never Runtime.enable; the binding by world name; device scale 1; it runs last")
    func formeDeLInit() throws {
        let commands = placeholders()
        let methods = commands.map { $0.0 }
        #expect(!methods.contains("Runtime.enable"))
        #expect(methods.last == "Runtime.runIfWaitingForDebugger")
        #expect(methods.first == "Page.enable")
        let binding = try #require(commands.first(where: { $0.0 == "Runtime.addBinding" }))
        expectCommand(binding, "Runtime.addBinding", ["name": "__loomHookBinding", "executionContextName": "loom-agent"])
        let metrics = try #require(commands.first(where: { $0.0 == "Emulation.setDeviceMetricsOverride" }))
        expectCommand(metrics, "Emulation.setDeviceMetricsOverride",
                      ["width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": false,
                       "screenWidth": 1280, "screenHeight": 800])
        let attach = try #require(commands.first(where: { $0.0 == "Target.setAutoAttach" }))
        expectCommand(attach, "Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true])
        let scripts = commands.filter { $0.0 == "Page.addScriptToEvaluateOnNewDocument" }
        let worlds = scripts.map { $0.1["worldName"] as? String ?? "page" }
        #expect(worlds == ["loom-agent", "page", "loom-agent"], "relay, hook, helper")
        #expect(ChromiumTabRuntime.helperTopFrame.hasPrefix("if (window === window.top) {\n"))
        #expect(ChromiumTabRuntime.helperTopFrame.hasSuffix("\n}"))
    }

    @Test("the real scripts go in: the relay with its binding channel, the hook, the helper")
    func vraisScripts() throws {
        let commands = ChromiumTabRuntime.initCommands(viewport: CGSize(width: 800, height: 600), userAgent: agent)
        let sources = commands.filter { $0.0 == "Page.addScriptToEvaluateOnNewDocument" }
            .compactMap { $0.1["source"] as? String }
        try #require(sources.count == 3)
        #expect(sources[0] == AgentScripts.relay)
        #expect(sources[0].contains("__loomHookBinding"))
        #expect(sources[1] == AgentScripts.pageHook)
        #expect(sources[2] == ChromiumTabRuntime.helperTopFrame)
    }

    @Test("the user agent: a Mac's Chrome, its client hints, never Headless")
    func agentUtilisateur() throws {
        let real = ChromiumUserAgent(major: "141", fullVersion: "141.0.7390.37", platformVersion: "15.0.0",
                                     architecture: "arm")
        #expect(real.userAgent == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36")
        let params = real.overrideParams
        let text = shown(params)
        #expect(!text.contains("Headless"))
        let metadata = try #require(params["userAgentMetadata"] as? [String: Any])
        let brands = try #require(metadata["brands"] as? [[String: Any]])
        let names = brands.compactMap { $0["brand"] as? String }
        #expect(names == ["Chromium", "Not?A_Brand"])
        #expect(metadata["platform"] as? String == "macOS")
        #expect(params["platform"] as? String == "MacIntel")
        #expect(["arm", "x86"].contains(ChromiumUserAgent.machineArchitecture))
    }

    @Test("an out-of-process iframe: relay, hook, binding, network, choosers, its own children — no helper")
    func initDUnCadreEnfant() throws {
        let commands = ChromiumTabRuntime.childFrameInitCommands(relay: "{relay}", pageHook: "{pageHook}")
        let methods = commands.map { $0.0 }
        #expect(methods == ["Page.enable", "Network.enable", "Page.addScriptToEvaluateOnNewDocument",
                            "Page.addScriptToEvaluateOnNewDocument", "Runtime.addBinding",
                            "Page.setInterceptFileChooserDialog", "Target.setAutoAttach",
                            "Runtime.runIfWaitingForDebugger"])
        let sources = commands.compactMap { $0.1["source"] as? String }
        #expect(sources == ["{relay}", "{pageHook}"])
        expectCommand(commands[1], "Network.enable",
                      ["maxTotalBufferSize": 0, "maxResourceBufferSize": 0, "maxPostDataSize": 0])
    }

    @Test("a viewport side is whole CSS px, 1 to 16 384")
    func cotesDuViewport() {
        expectCommand(("Emulation.setDeviceMetricsOverride", ChromiumTabRuntime.deviceMetrics(CGSize(width: 0, height: 100_000))),
                      "Emulation.setDeviceMetricsOverride",
                      ["width": 1, "height": 16_384, "deviceScaleFactor": 1, "mobile": false,
                       "screenWidth": 1, "screenHeight": 16_384])
        expectCommand(("Emulation.setDeviceMetricsOverride", ChromiumTabRuntime.deviceMetrics(CGSize(width: 1023.6, height: 700.2))),
                      "Emulation.setDeviceMetricsOverride",
                      ["width": 1024, "height": 700, "deviceScaleFactor": 1, "mobile": false,
                       "screenWidth": 1024, "screenHeight": 700])
    }
}

@Suite("Chromium tab — what the page may post")
struct ChromiumBindingPayloadTests {

    @Test("over 8 KB of UTF-8 a payload is dropped before it is parsed")
    func plafond() {
        #expect(ChromiumTabRuntime.maxBindingPayloadBytes == 8_192)
        #expect(ChromiumTabRuntime.admitsBindingPayload(String(repeating: "a", count: 8_192)))
        #expect(!ChromiumTabRuntime.admitsBindingPayload(String(repeating: "a", count: 8_193)))
        #expect(!ChromiumTabRuntime.admitsBindingPayload(String(repeating: "é", count: 4_097)), "two bytes each")
        let huge = #"{"t":"console","level":"error","text":""# + String(repeating: "x", count: 9_000) + #""}"#
        #expect(ChromiumTabRuntime.hookMessage(fromPayload: huge) == nil, "valid, but never parsed")
    }

    @Test("what the relay posts parses as the hook's messages; anything else is dropped")
    func messagesDuRelais() {
        let console = #"{"t":"console","level":"error","text":"boom","loc":"http://localhost:5173/app.js:3"}"#
        #expect(ChromiumTabRuntime.hookMessage(fromPayload: console)
                == .console(level: .error, text: "boom", location: "http://localhost:5173/app.js:3"))
        #expect(ChromiumTabRuntime.hookMessage(fromPayload: #"{"t":"dropped","n":30}"#) == .dropped(30))
        #expect(ChromiumTabRuntime.hookMessage(fromPayload: "not json") == nil)
        #expect(ChromiumTabRuntime.hookMessage(fromPayload: #"["console"]"#) == nil)
        #expect(ChromiumTabRuntime.hookMessage(fromPayload: #"{"t":"console","level":"loud","text":"x"}"#) == nil)
    }

    @Test("the longest message the hook writes, in a script of three bytes a character, still fits")
    func messageLongEnUTF8() {
        let text = String(repeating: "漢", count: 2_000)
        let location = "http://localhost:5173/" + String(repeating: "p", count: 270)
        let payload = #"{"t":"console","level":"info","text":""# + text + #"","loc":""# + location + #""}"#
        #expect(ChromiumTabRuntime.admitsBindingPayload(payload))
        #expect(ChromiumTabRuntime.hookMessage(fromPayload: payload) == .console(level: .info, text: text,
                                                                                 location: location))
    }
}

@Suite("Chromium tab — the helper's answers and the page's words")
struct ChromiumHelperAnswerTests {

    @Test("the helper's errors in the WebKit engine's codes")
    func erreursDuHelper() throws {
        #expect(throws: AgentError.notFound("no element e9")) {
            try ChromiumHelper.decode(#"{"error":{"code":"notFound","message":"no element e9"}}"#)
        }
        for code in ["invalid", "ambiguous", "notSelect", "optionNotFound", "notEditable"] {
            #expect(throws: AgentError.invalid("m")) {
                try ChromiumHelper.decode(#"{"error":{"code":""# + code + #"","message":"m"}}"#)
            }
        }
        #expect(throws: AgentError.failed("odd")) {
            try ChromiumHelper.decode(#"{"error":{"code":"weird","message":"odd"}}"#)
        }
        #expect(throws: AgentError.failed("the page answered something unexpected")) {
            try ChromiumHelper.decode("null")
        }
        _ = try ChromiumHelper.decode(#"{"ok":true,"status":"ready"}"#)
        do {
            _ = try ChromiumHelper.decode(#"{"error":{"code":"helperMissing","message":"the helper is not loaded"}}"#)
            Issue.record("helperMissing must throw")
        } catch {
            #expect(!(error is AgentError), "helperMissing is the caller's to handle: it injects the helper")
        }
    }

    @Test("a document gone under a call, in Chromium's words")
    func documentDisparu() {
        #expect(ChromiumHelper.isStaleContext("Cannot find context with specified id"))
        #expect(ChromiumHelper.isDocumentGone("Execution context was destroyed."))
        #expect(ChromiumHelper.isDocumentGone("Promise was collected"))
        #expect(ChromiumHelper.isDocumentGone("Cannot find context with specified id"))
        #expect(!ChromiumHelper.isStaleContext("Execution context was destroyed."))
        #expect(!ChromiumHelper.isDocumentGone("Invalid parameters"))
    }

    @Test("arguments go as JSON; anything JSON cannot hold goes as {}")
    func argumentsJSON() throws {
        let text = ChromiumHelper.json(["target": "e12", "action": "click", "trusted": true, "path": "/a/b"])
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let parsed = try #require(object as? [String: Any])
        #expect(parsed["target"] as? String == "e12")
        #expect(parsed["trusted"] as? Bool == true)
        #expect(text.contains("/a/b"), "slashes unescaped")
        #expect(ChromiumHelper.json(["x": Double.nan]) == "{}")
    }

    @Test("the world is asked for by frame, never with universal access")
    func monde() {
        expectCommand(("Page.createIsolatedWorld", ChromiumHelper.createWorldParams(frameId: "F1")),
                      "Page.createIsolatedWorld",
                      ["frameId": "F1", "worldName": "loom-agent", "grantUniveralAccess": false])
        #expect(ChromiumHelper.injectFunction.hasPrefix("function() {\n"))
        #expect(ChromiumHelper.injectFunction.hasSuffix("\nreturn \"loaded\";\n}"))
    }

    @Test("browser_evaluate runs the agent's function in an async arrow, the stamp's nonce a string literal")
    func expressionEvaluee() {
        let expression = ChromiumTabRuntime.evaluateExpression(function: "() => document.title", nonce: "n\"1")
        #expect(expression.hasPrefix("(async () => {\nconst nonce = \"n\\\"1\";\n"))
        #expect(expression.hasSuffix("\n})()"))
        #expect(expression.contains(AgentScripts.evaluateBody(function: "() => document.title")))
    }

    @Test("a dialog's banner names its frame; an opaque frame never passes for the page")
    func hoteDuDialogue() {
        let top = "http://localhost:5173/checkout"
        #expect(ChromiumTabRuntime.dialogHost(frameOrigin: "https://pay.example", isMainFrame: false, topURL: top)
                == "pay.example")
        #expect(ChromiumTabRuntime.dialogHost(frameOrigin: nil, isMainFrame: true, topURL: top) == "localhost")
        #expect(ChromiumTabRuntime.dialogHost(frameOrigin: "null", isMainFrame: false, topURL: top)
                == "A frame embedded in localhost")
        #expect(ChromiumTabRuntime.dialogHost(frameOrigin: "://", isMainFrame: false, topURL: top)
                == "A frame embedded in localhost")
        #expect(ChromiumTabRuntime.dialogHost(frameOrigin: nil, isMainFrame: nil, topURL: "about:blank")
                == "this page")
    }
}
