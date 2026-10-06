// Stuck and crashed pages (design §7): the engine's ladder, checked on a
// renderer that spins.
// - A page whose main thread loops — in a CDP evaluation, a helper call, a
//   page timer or a click handler — leaves a 500 ms probe (Runtime.evaluate
//   "1") unanswered; Runtime.terminateExecution stops it in milliseconds, the
//   looping call fails "Execution was terminated", and the page works after:
//   evaluation, navigation, trusted clicks. No Runtime.enable anywhere.
// - On an idle page, terminateExecution is harmless.
// - Page.crash never replies, but the crash is reported (Inspector.targetCrashed
//   on the tab, Target.targetCrashed on the browser) and Page.reload recovers.
// - Chromium killed outright: the pipe ends and every pending call fails.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { delay, launch, performance, settle, settlesWithin, within } from "./lib/cdp.mjs";
import { openTab, WORLD } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const PROBE_MS = 500;

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

  const probe = (tab) => tab.session.send("Runtime.evaluate", { expression: "1", returnByValue: true });

  /** The page answers, navigates, and takes a trusted click. */
  async function usable(tab) {
    assert.equal(await within(tab.evaluate("1 + 1"), 5000), 2, "evaluation");
    const reply = await within(tab.navigate(server.url("/")), 10_000);
    assert.ok(reply && !reply.errorText, "navigation");
    const { x, y } = await tab.centerOf("#card");
    await within(Promise.all(tab.click(x, y)), 5000);
    assert.deepEqual(await tab.evaluate("window.events"), ["card"], "a trusted click");
  }

  // `start` answers { call } — the CDP call that started the loop, if any (a
  // bare promise would be awaited); `then`: what becomes of it once terminated.
  const loops = [
    { name: "while(true) in a CDP evaluation", then: "terminated",
      start: async (tab) => ({ call: tab.session.send("Runtime.evaluate", { expression: "while (true) {}", returnByValue: true }) }) },
    { name: "while(true) in a helper-world call", then: "terminated",
      start: async (tab) => ({ call: tab.session.send("Runtime.callFunctionOn", {
        functionDeclaration: "async function() { while (true) {} }", executionContextId: await tab.world(), awaitPromise: true, returnByValue: true,
      }) }) },
    { name: "a page timer that loops", then: null,
      start: async (tab) => { await tab.evaluate("setTimeout(() => { while (true) {} }, 0), 1"); return {}; } },
    { name: "a click handler that loops (a trusted click)", then: "answered",
      start: async (tab) => {
        await tab.evaluate("document.getElementById('card').addEventListener('click', () => { while (true) {} }), 1");
        const { x, y } = await tab.centerOf("#card");
        return { call: tab.click(x, y)[2] };   // mouseReleased: the handler runs on it
      } },
    { name: "a microtask loop", then: null,
      start: async (tab) => { await tab.evaluate("setTimeout(() => { (async () => { for (;;) await 0; })(); }, 0), 1"); return {}; } },
  ];

  for (const loop of loops) {
    test(`${loop.name}: unanswered probe, then terminateExecution frees the page`, options(), async (t) => {
      const tab = await openTab(chrome, { url: server.url("/") });
      try {
        const { call } = await loop.start(tab);
        const looping = call ? settle(call) : null;
        await delay(200);
        const stuck = probe(tab);
        assert.equal(await settlesWithin(stuck, PROBE_MS), false, "the probe is unanswered while the page spins");
        const started = performance.now();
        await within(tab.session.send("Runtime.terminateExecution"), 5000);
        const terminatedMs = performance.now() - started;
        assert.ok(await settlesWithin(stuck, 5000), "the probe queued behind the loop answers");
        t.diagnostic(`terminateExecution answered in ${terminatedMs.toFixed(1)} ms`);
        if (looping) {
          const outcome = await within(looping, 5000);
          assert.ok(outcome, "the call that started the loop has its answer");
          if (loop.then === "terminated") assert.match(outcome.error?.message ?? "answered", /Execution was terminated/);
          else assert.equal(outcome.ok, true, outcome.error?.message);
        }
        await usable(tab);
      } finally {
        await settle(tab.close());
      }
    });
  }

  test("terminateExecution on an idle page is harmless", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/") });
    await tab.session.send("Runtime.terminateExecution");
    assert.equal(await within(tab.evaluate("1 + 1"), 5000), 2);
    assert.equal(await within(tab.call("function() { return 3; }", [], {}), 5000), 3, "the helper's world too");
    await usable(tab);
    await tab.close();
  });

  test("Page.crash: no reply, the crash reported twice, Page.reload brings the page back", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/") });
    const inspector = tab.session.waitForEvent("Inspector.targetCrashed", { timeout: 10_000 });
    const target = chrome.conn.waitForEvent("Target.targetCrashed", { predicate: (p) => p.targetId === tab.targetId, timeout: 10_000 });
    const crash = settle(tab.session.send("Page.crash"));
    await inspector;
    const crashed = await target;
    assert.equal(crashed.targetId, tab.targetId);
    assert.equal(await settlesWithin(crash, 300), false, "Page.crash itself never answers");
    const reloaded = tab.session.waitForEvent("Page.lifecycleEvent", { predicate: (p) => p.name === "load", timeout: 10_000 });
    await within(tab.session.send("Page.reload"), 10_000);
    await reloaded;
    assert.equal(await within(tab.evaluate("document.title"), 5000), "Todos");
    assert.equal(typeof (await tab.helper("pageInfo")).scrollHeight, "number", "the helper is back in the new world");
    await tab.close();
  });

  test("Chromium killed: the pipe ends and every pending call fails", options(), async () => {
    const doomed = await launch(browser);
    try {
      const tab = await openTab(doomed, { url: server.url("/blank") });
      const pending = settle(tab.session.send("Runtime.evaluate", { expression: "new Promise(() => {})", awaitPromise: true }));
      const closed = new Promise((done) => doomed.conn.once("close", done));
      process.kill(doomed.pid, "SIGKILL");
      assert.ok(await within(closed.then(() => true), 5000), "the pipe ended");
      const outcome = await within(pending, 5000);
      assert.equal(outcome?.ok, false);
      assert.match(outcome.error.message, /pipe closed/);
      await assert.rejects(doomed.conn.send("Browser.getVersion"), /pipe is closed/);
    } finally {
      await doomed.close();
    }
  });

  test("the helper's world id survives nothing: after a crash and reload, the old id is refused", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/") });
    const { executionContextId: old } = await tab.session.send("Page.createIsolatedWorld", { frameId: tab.frameId, worldName: WORLD });
    const crashed = tab.session.waitForEvent("Inspector.targetCrashed", { timeout: 10_000 });
    settle(tab.session.send("Page.crash"));
    await crashed;
    const loaded = tab.session.waitForEvent("Page.lifecycleEvent", { predicate: (p) => p.name === "load", timeout: 10_000 });
    await tab.session.send("Page.reload");
    await loaded;
    const fresh = await tab.world();
    if (fresh === old) {
      // A new renderer numbers its contexts from scratch: the same number may come back, for another world.
      assert.equal(await tab.call("function() { return typeof globalThis.__loomAgent; }"), "object");
    } else {
      await assert.rejects(tab.session.send("Runtime.callFunctionOn", { functionDeclaration: "function() { return 1; }", executionContextId: old }),
        /Cannot find context with specified id/);
    }
    await tab.close();
  });
});
