// A tab as Loom's Chromium engine sets it up (design §3.1, fixtures/init.json):
// attached paused, then one write of init commands, all accepted. Then what
// the engine builds on, without Runtime.enable (no console flood, no
// automation tell):
// - Page.createIsolatedWorld hands back the world the helper was injected
//   into, the page's own world never sees it, and only the top frame has it;
// - the page's console reaches Loom over Runtime.addBinding — on condition
//   that, on every Page.frameNavigated, Loom makes sure of the frame's world
//   (Page.createIsolatedWorld) and adds the binding again in the same write:
//   it only goes into worlds that exist when it is sent, and the headless
//   shell makes a subframe's contexts only when something first needs them;
// - a new document is a new world: the old id is refused with the error the
//   engine reads as "navigated";
// - workers and service workers run: the tab's auto-attach (paused, so an
//   out-of-process iframe gets its init first) takes no filter, because a
//   target it pauses without attaching never starts.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launch, settle, within } from "./lib/cdp.mjs";
import {
  BINDING, DOCUMENT_GONE, HELPER_FUNCTION, WORLD, openTab, prepareBrowser, readInitFixture, renderInitDocument, writeInitFixture,
} from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

test("fixtures/init.json is what lib/init.mjs sends (LOOM_CDP_UPDATE=1 rewrites it)", () => {
  if (process.env.LOOM_CDP_UPDATE === "1") writeInitFixture();
  const written = readInitFixture();
  assert.ok(written, "fixtures/init.json is missing: run with LOOM_CDP_UPDATE=1");
  assert.equal(written, renderInitDocument(), "fixtures/init.json drifted from lib/init.mjs: run with LOOM_CDP_UPDATE=1");
});

/** Waits for a binding message `matches` accepts, from `tab.bindings`. */
async function bindingMessage(tab, matches, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const found = tab.bindings.find((call) => matches(call.message));
    if (found) return found;
    await new Promise((done) => setTimeout(done, 20));
  }
  return null;
}

eachBrowser((browser) => {
  let server;
  let chrome;
  before(async () => {
    server = await startServer();
    chrome = await launch(browser);
  });
  after(async () => {
    await chrome?.close();
    await server?.close();
  });

  test("the browser setup is accepted in one write: auto-attach paused, downloads and six permissions denied", options(), async () => {
    const router = await prepareBrowser(chrome);
    assert.deepEqual(router.setupErrors, []);
    const tab = await openTab(chrome, { url: server.url("/blank") });
    const state = await tab.evaluate("navigator.permissions.query({ name: 'geolocation' }).then((p) => p.state)");
    assert.equal(state, "denied");
    await tab.close();
  });

  test("a new tab attaches waiting for the debugger; the init burst, in one write, is accepted whole", options(), async () => {
    const tab = await openTab(chrome);
    assert.equal(tab.attachedEvent.waitingForDebugger, true);
    assert.equal(tab.attachedEvent.targetInfo.type, "page");
    assert.deepEqual(tab.initOutcomes.filter((outcome) => !outcome.ok), []);
    assert.equal(tab.initSent.at(-1), "Runtime.runIfWaitingForDebugger");
    assert.ok(!tab.initSent.includes("Runtime.enable"), "no Runtime.enable");
    await tab.navigate(server.url("/"));
    assert.equal(await tab.evaluate("document.title"), "Todos");
    await tab.close();
  });

  test("createIsolatedWorld returns the helper's world; the page's world never sees the helper", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/") });
    const { executionContextId: first } = await tab.session.send("Page.createIsolatedWorld", { frameId: tab.frameId, worldName: WORLD });
    const { executionContextId: again } = await tab.session.send("Page.createIsolatedWorld", { frameId: tab.frameId, worldName: WORLD });
    assert.equal(again, first, "one world per name and document");
    assert.equal(await tab.call("function() { return typeof globalThis.__loomAgent; }", [], { contextId: first }), "object");
    assert.equal(await tab.evaluate("typeof globalThis.__loomAgent"), "undefined", "the page's world");
    assert.equal(await tab.evaluate(`typeof globalThis.${BINDING}`), "undefined", "the binding is not the page's either");
    const { yaml } = await tab.helper("snapshot", { budget: 20000 });
    assert.match(yaml, /- heading "Todos" \[level=1\] \[ref=e\d+\]/);
    assert.match(yaml, /- textbox "New todo" \[ref=e\d+\]/);
    // The helper call is the one in fixtures/init.json.
    const raw = await tab.session.send("Runtime.callFunctionOn", {
      functionDeclaration: HELPER_FUNCTION, executionContextId: first,
      arguments: [{ value: "pageInfo" }, { value: "{}" }], returnByValue: true, awaitPromise: true, silent: true,
    });
    assert.equal(typeof JSON.parse(raw.result.value).scrollHeight, "number");
    await tab.close();
  });

  test("the helper is in the top frame only; the relay is in every frame, and hears its document start", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/") });
    const child = tab.session.waitForEvent("Page.frameNavigated", { predicate: ({ frame }) => frame.parentId === tab.frameId });
    // A frame that runs a script of its own: on the headless shell, Blink makes no
    // context at all for a document without one (nothing there could log either).
    await tab.evaluate(`new Promise((done) => {
      const frame = document.createElement("iframe");
      frame.src = "/boot?child";
      frame.onload = () => done(true);
      document.body.append(frame);
    })`);
    const { frame } = await child;
    const { executionContextId } = await tab.session.send("Page.createIsolatedWorld", { frameId: frame.id, worldName: WORLD });
    const seen = await tab.call("function() { return [typeof globalThis.__loomAgent, globalThis.__loomAgentRelay === true]; }", [], { contextId: executionContextId });
    assert.deepEqual(seen, ["undefined", true]);
    const call = await bindingMessage(tab, (m) => m?.text === "boot?child");
    assert.ok(call, "the child's document-start console message");
    assert.equal(call.executionContextId, executionContextId, "posted from the child's world");
    // A frame with no script of its own, whose console its parent calls later.
    await tab.evaluate(`new Promise((done) => {
      const frame = document.createElement("iframe");
      frame.id = "static";
      frame.src = "/blank?static";
      frame.onload = () => done(true);
      document.body.append(frame);
    })`);
    await tab.evaluate(`document.getElementById("static").contentWindow.console.log("static, later")`);
    assert.ok(await bindingMessage(tab, (m) => m?.text === "static, later"), "a frame whose context came late");
    await tab.close();
  });

  test("the page's console reaches Loom over the binding, with no Runtime.enable and no Runtime event", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/") });
    const runtimeEvents = [];
    const stop = (message) => {
      if (message.sessionId === tab.session.id && message.method.startsWith("Runtime.") && message.method !== "Runtime.bindingCalled") runtimeEvents.push(message.method);
    };
    chrome.conn.on("*", stop);
    try {
      const { x, y } = await tab.centerOf("#boom");
      await Promise.all(tab.click(x, y));
      const call = await bindingMessage(tab, (m) => m?.t === "console" && m.level === "error" && m.text?.startsWith("Something broke"));
      assert.ok(call, "console.error arrived: " + JSON.stringify(tab.bindings.map((b) => b.message)));
      assert.equal(call.name, BINDING);
      assert.equal(call.executionContextId, await tab.world(), "posted from the helper's world");
      const uncaught = await bindingMessage(tab, (m) => m?.t === "console" && /uncaught in timer/.test(m.text || ""));
      assert.ok(uncaught, "the uncaught error in a timer too");
      assert.deepEqual(runtimeEvents, [], "no Runtime event but bindingCalled");
    } finally {
      chrome.conn.off("*", stop);
      await tab.close();
    }
  });

  test("a new document: a new world (the old id refused), and with the re-add the binding even hears its document start", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/boot?first") });
    assert.ok(await bindingMessage(tab, (m) => m?.text === "boot?first"), "document start of the first page");
    const old = await tab.world();
    const before = tab.rebinds;
    await tab.navigate(server.url("/boot?same-site"));
    assert.ok(tab.rebinds > before, "the world and the binding sent again on frameNavigated");
    await assert.rejects(
      tab.session.send("Runtime.callFunctionOn", { functionDeclaration: "function() { return 1; }", executionContextId: old, returnByValue: true }),
      /Cannot find context with specified id/,
    );
    assert.notEqual(await tab.world(), old);
    assert.ok(await bindingMessage(tab, (m) => m?.text === "boot?same-site"), "document start, same site");
    // Another site: on the full browser, another renderer, whose ids start again.
    await tab.navigate(`http://localhost:${server.port}/boot?cross-site`);
    assert.ok(await bindingMessage(tab, (m) => m?.text === "boot?cross-site"), "document start, cross site");
    assert.equal(typeof (await tab.helper("pageInfo")).scrollHeight, "number", "the helper answers in the new world");
    await tab.close();
  });

  test("Chromium 141: without the re-add, a document created after Runtime.addBinding never has the binding", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/boot?kept"), rebind: false });
    await within(new Promise((done) => setTimeout(done, 800)), 1000);
    assert.equal(await tab.call(`function() { return typeof globalThis.${BINDING}; }`), "undefined");
    assert.equal(tab.bindings.length, 0, "nothing posted: " + JSON.stringify(tab.bindings.map((b) => b.message)));
    // Added again now, it reaches this document — the queued document-start message goes out with it.
    await tab.session.send("Runtime.addBinding", { name: BINDING, executionContextName: WORLD });
    assert.ok(await bindingMessage(tab, (m) => m?.text === "boot?kept"), "the relay's queue went out once the binding came");
    await tab.close();
  });

  test("workers and service workers run: attached paused, then resumed by the router", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/leak-probe.html") });
    const before = chrome.router.resumed.length;
    assert.equal(await tab.evaluate(`probes.worker("/ok?worker")`), "ok 200");
    assert.equal(await tab.evaluate(`probes.serviceWorker("/ok?service-worker")`), "ok 200");
    const kinds = chrome.router.resumed.slice(before).map((info) => info.type);
    assert.ok(kinds.includes("worker") && kinds.includes("service_worker"), JSON.stringify(kinds));
    await tab.close();
  });

  test("Chromium 141: auto-attach filtered to iframes leaves a dedicated worker paused for ever", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/leak-probe.html") });
    await tab.session.send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true, filter: [{ type: "iframe" }] });
    assert.equal(await tab.evaluate(`probes.worker("/ok?filtered")`), "timeout", "the worker never answered");
    await tab.close();
  });

  test("a helper call in flight when its document goes away fails as 'navigated', even before the commit is on the wire", options(), async (t) => {
    const tab = await openTab(chrome, { url: server.url("/") });
    // Two kinds of pending call: one only its promise holds (the teardown may
    // collect it first: "Promise was collected"), one a timer holds.
    const shapes = ["function() { return new Promise(() => {}); }", "function() { return new Promise((done) => setTimeout(done, 60_000)); }"];
    const seen = [];
    for (const shape of shapes) {
      await tab.navigate(server.url("/?" + seen.length));
      const wire = chrome.conn.startRecording();
      const call = tab.call(shape);
      const pending = settle(call);
      await new Promise((done) => setTimeout(done, 50));
      await tab.navigate(server.url("/blank?after"));
      const outcome = await within(pending, 5000);
      chrome.conn.stopRecording();
      assert.ok(outcome, "the call still has no answer 5 s after the navigation");
      assert.equal(outcome.ok, false);
      assert.match(outcome.error.message, DOCUMENT_GONE);
      const own = wire.filter((e) => e.sessionId === tab.session.id);
      const failed = own.findIndex((e) => e.dir === "reply" && e.error && e.method === "Runtime.callFunctionOn");
      const committed = own.findIndex((e) => e.dir === "event" && e.method === "Page.frameNavigated" && !e.params.frame.parentId);
      assert.ok(committed >= 0, "the commit came");
      seen.push(`${outcome.error.cdpMessage}, ${failed < committed ? "before" : "after"} Page.frameNavigated`);
      // Same site, same frame host: the renderer tears the old document down
      // (failing the call) before it reports the commit.
      assert.ok(failed >= 0 && failed < committed, "the failure is on the wire before Page.frameNavigated");
    }
    t.diagnostic(seen.join("; "));
    await tab.close();
  });
});
