// browser_run_code's runner (run-code design §1 and §3; RunnerFence.swift,
// ChromiumRunner.swift): one target per session, in a browser context of its
// own, where the agent's script runs — never in the page under test — and
// talks to Loom through one binding.
//
// - The fence: the context's proxy is a listener that closes every
//   connection (ChromiumFence), loopback included (`<-loopback>`, nothing
//   bypassed); Fetch fails every request; the network is emulated offline.
//   Nothing the runner's world tries reaches a server — fetch, XHR, a
//   WebSocket, an image, a beacon, a worker's fetch, an iframe.
// - The binding, without Runtime.enable: added to each run's fresh world by
//   its executionContextId, it reaches Loom with that id; a reply goes back
//   by Runtime.callFunctionOn into the same world. A call from an older
//   world carries the older id (Loom drops it).
// - The stop ladder: Runtime.terminateExecution ends a `while (true) {}` in
//   milliseconds and does not poison the next run; Target.closeTarget of a
//   spinning runner destroys it at once; Page.crash crashes it.
// - The runner's frame id is its target id (Page.createIsolatedWorld's
//   frameId), and its timers are not throttled.
// - The real facade (AgentRunnerScript.facade) in the fenced runner, its page
//   calls carried out on a tab by a stand-in for the core: the wire format
//   both sides agree on, and its cost.
// - Agent scripts end to end (lib/runcore.mjs: ChromiumAgentCore+RunCode.swift
//   and ChromiumRunner.swift ported line by line, the real facade and the
//   real helper): a navigation, a form with a wait beside its click, a
//   strict-mode violation, dialogs with and without page.on('dialog'),
//   console output, a `while (true) {}` stopped, the 1 000-call cap, and
//   what the run's world cannot reach.
//
// RunnerFence.swift builds these very parameters (RunnerFenceTests pins them).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot } from "../AgentBrowserJS/extract.mjs";
import { delay, launch, performance, settle, settlesWithin, within, withTimeout } from "./lib/cdp.mjs";
import http from "node:http";
import { openTab, prepareBrowser } from "./lib/init.mjs";
import { RunPage, Runner, runCode } from "./lib/runcore.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

// The facade and its doors, as AgentRunnerScript.swift has them (null while it is not there).
const RUNNER_SWIFT = (() => {
  try { return readFileSync(resolve(repoRoot, "Sources/LoomWeb/AgentBrowser/AgentRunnerScript.swift"), "utf8"); } catch { return null; }
})();
const runnerLiteral = (name) => {
  const match = RUNNER_SWIFT && new RegExp(`public static let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`).exec(RUNNER_SWIFT);
  return match ? match[1] : null;
};
const runnerConstant = (name) => {
  const match = RUNNER_SWIFT && new RegExp(`public static let ${name} = "((?:[^"\\\\]|\\\\.)*)"`).exec(RUNNER_SWIFT);
  return match ? JSON.parse(`"${match[1]}"`) : null;
};
const FACADE = runnerLiteral("facade");
const ANSWER_FUNCTION = runnerConstant("answerFunction");

const BINDING = "__loomRunCall";
const SOURCE_URL = "browser_run_code.js";

/** Target.createBrowserContext for the runner: every request through the fence, loopback too. */
const contextParams = (port) => ({
  disposeOnDetach: true,
  proxyServer: `http://127.0.0.1:${port}`,
  proxyBypassList: "<-loopback>",
});

/** The runner target's init, one write (RunnerFence.targetInit). */
function runnerInit({ fetch = true, offline = true } = {}) {
  const commands = [];
  if (fetch) commands.push(["Fetch.enable", { patterns: [{ urlPattern: "*", requestStage: "Request" }] }]);
  if (offline) commands.push(["Network.emulateNetworkConditions", { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }]);
  commands.push(["Page.enable", {}]);
  commands.push(["Emulation.setFocusEmulationEnabled", { enabled: true }]);
  commands.push(["Runtime.runIfWaitingForDebugger", {}]);
  return commands;
}

/** The fence: accepts, closes, counts (Loom's is ChromiumFence). */
async function startFence() {
  const connections = [];
  const server = net.createServer((socket) => {
    connections.push(performance.now());
    socket.on("error", () => {});
    socket.destroy();
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  return { port: server.address().port, connections, close: () => new Promise((done) => server.close(done)) };
}

function claim(browser, targetId, timeout = 15_000) {
  const known = browser.router.claimed.get(targetId);
  if (known) return Promise.resolve(known);
  return withTimeout(new Promise((resolve) => browser.conn.once(`claimed:${targetId}`, resolve)), timeout, `attachedToTarget for ${targetId}`);
}

/** A small site for the end-to-end scripts: two pages and a link between them, a form, dialogs. */
const SITE = {
  "/a": `<!doctype html><meta charset="utf-8"><title>Page A</title><h1>Page A</h1><a href="/b">Next</a>
<button onclick="document.title = 'saved'">Save</button><button>Save draft</button>
<p id="late"></p><script>setTimeout(() => { document.getElementById("late").textContent = "arrived"; }, 300);</script>`,
  "/b": `<!doctype html><meta charset="utf-8"><title>Page B</title><h1>Page B</h1><a href="#docs">Docs</a>
<form action="/done" method="get">
<label>Email <input name="email"></label>
<label>Password <input name="password" type="password"></label>
<label><input type="checkbox" name="terms" value="yes"> I agree</label>
<label>Plan <select name="plan"><option>Free</option><option value="pro">Pro</option></select></label>
<button type="submit">Sign in</button></form>`,
  "/done": `<!doctype html><meta charset="utf-8"><title>Done</title><h1>Done</h1>`,
  "/dialogs": `<!doctype html><meta charset="utf-8"><title>Dialogs</title>
<button onclick="answers.push('confirm:' + confirm('Delete it?'))">Delete</button>
<button onclick="answers.push('prompt:' + prompt('Your name?', 'nobody'))">Rename</button>
<button onclick="alert('Saved'); answers.push('alert closed')">Notify</button>
<script>window.answers = [];</script>`,
};

async function startSite() {
  const hits = [];
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://site");
    hits.push(url.pathname + url.search);
    const page = SITE[url.pathname];
    response.writeHead(page ? 200 : 404, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    response.end(page ?? "not found");
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, hits, close: () => new Promise((done) => { server.close(done); server.closeAllConnections(); }) };
}

/** Polls `check` every 5 ms until it is truthy, or throws after `ms`. */
async function until(check, ms = 5000, label = "condition") {
  const end = performance.now() + ms;
  while (performance.now() < end) {
    const value = check();
    if (value) return value;
    await delay(5);
  }
  throw new Error(`${label}: not met in ${ms} ms`);
}

eachBrowser((browser) => {
  let server;
  let fence;
  let chrome;
  let worlds = 0;
  let site;
  let core;

  before(async () => {
    server = await startServer();
    fence = await startFence();
    site = await startSite();
    chrome = await launch(browser);
    await prepareBrowser(chrome);
  });
  after(async () => {
    await core?.dispose();
    await chrome?.close();
    await fence?.close();
    await site?.close();
    await server?.close();
  });

  /**
   * A runner as ChromiumRunner makes it: a fenced context, a target of its
   * own window in it, the init burst. Fetch's paused requests are failed
   * and dialogs dismissed on the reader, as the runner's sink does.
   */
  async function openRunner(layers = {}) {
    const router = await prepareBrowser(chrome);
    const { browserContextId } = await chrome.conn.send("Target.createBrowserContext", contextParams(fence.port));
    router.creating++;
    let created;
    try {
      created = await chrome.conn.send("Target.createTarget", { url: "about:blank", browserContextId, newWindow: true });
    } catch (error) {
      router.creating--;
      throw error;
    }
    const attached = await claim(chrome, created.targetId);
    router.claimed.delete(created.targetId);
    const session = chrome.conn.session(attached.sessionId, created.targetId);
    const paused = [];
    session.on("Fetch.requestPaused", ({ requestId, request }) => {
      paused.push(request.url);
      session.send("Fetch.failRequest", { requestId, errorReason: "BlockedByClient" }).catch(() => {});
    });
    session.on("Page.javascriptDialogOpening", () => {
      session.send("Page.handleJavaScriptDialog", { accept: false }).catch(() => {});
    });
    const init = runnerInit(layers);
    const outcomes = await Promise.all(session.sendBatch(init).map(settle));
    const refused = outcomes.map((outcome, i) => outcome.ok ? null : `${init[i][0]}: ${outcome.error.message}`).filter(Boolean);
    return {
      session, targetId: created.targetId, browserContextId, paused, refused, attached,
      close: async () => {
        await settle(chrome.conn.send("Target.closeTarget", { targetId: created.targetId }));
        await settle(chrome.conn.send("Target.disposeBrowserContext", { browserContextId }));
      },
    };
  }

  /** A run's fresh world, its binding added by id (no Runtime.enable anywhere). */
  async function newWorld(runner) {
    const { executionContextId } = await runner.session.send("Page.createIsolatedWorld", {
      frameId: runner.targetId, worldName: `loom-run-${++worlds}`, grantUniveralAccess: false,
    });
    await runner.session.send("Runtime.addBinding", { name: BINDING, executionContextId });
    return executionContextId;
  }

  async function evaluate(runner, contextId, expression, { awaitPromise = true } = {}) {
    const { result, exceptionDetails } = await runner.session.send("Runtime.evaluate", {
      contextId, expression, awaitPromise, returnByValue: true, silent: true,
    });
    if (exceptionDetails) throw new Error(`evaluate: ${exceptionDetails.exception?.description || exceptionDetails.text}`);
    return result.value;
  }

  test("the runner's init is accepted, its main frame is its target, and it is no tab of the router's", options(), async () => {
    const runner = await openRunner();
    try {
      assert.deepEqual(runner.refused, [], "Fetch, the offline emulation (no Network.enable) and the rest");
      assert.equal(runner.attached.targetInfo.browserContextId, runner.browserContextId);
      const { frameTree } = await runner.session.send("Page.getFrameTree");
      assert.equal(frameTree.frame.id, runner.targetId, "Page.createIsolatedWorld takes the target id as frame");
      const ctx = await newWorld(runner);
      assert.equal(await evaluate(runner, ctx, "navigator.onLine"), false, "offline, as the page sees it");
    } finally {
      await runner.close();
    }
  });

  /** Every way out a script in the run world might try, each settling to a word; `marker` tags the requests. */
  const ESCAPES = (base, marker) => `(async () => {
    const out = {};
    const url = (name) => "${base}/ok?${marker}-" + name;
    const guard = (promise, ms = 2000) => Promise.race([promise, new Promise((r) => setTimeout(() => r("timeout"), ms))]);
    out.fetch = await guard(fetch(url("fetch")).then((r) => "status " + r.status, (e) => "failed: " + e.message));
    out.xhr = await guard(new Promise((resolve) => {
      const x = new XMLHttpRequest();
      x.onload = () => resolve("status " + x.status);
      x.onerror = () => resolve("failed");
      x.open("GET", url("xhr")); x.send();
    }));
    out.websocket = await guard(new Promise((resolve) => {
      const ws = new WebSocket("${base.replace("http", "ws")}/ws?${marker}-ws");
      ws.onopen = () => resolve("open");
      ws.onerror = () => resolve("failed");
    }));
    out.image = await guard(new Promise((resolve) => {
      const img = new Image();
      img.onload = () => resolve("loaded");
      img.onerror = () => resolve("failed");
      img.src = url("img");
    }));
    out.beacon = navigator.sendBeacon(url("beacon"), "x") ? "queued" : "refused";
    out.worker = await guard(new Promise((resolve) => {
      const source = "fetch(" + JSON.stringify(url("worker")) + ").then((r) => postMessage('status ' + r.status), (e) => postMessage('failed'))";
      const worker = new Worker(URL.createObjectURL(new Blob([source], { type: "text/javascript" })));
      worker.onmessage = (event) => resolve(event.data);
      worker.onerror = () => resolve("failed to start");
    }));
    out.iframe = await guard(new Promise((resolve) => {
      const frame = document.createElement("iframe");
      frame.onload = () => { let text = ""; try { text = frame.contentDocument?.body?.innerText || ""; } catch (_) { text = "cross-origin"; } resolve("loaded " + text.slice(0, 40)); };
      frame.src = url("iframe");
      document.documentElement.appendChild(frame);
    }));
    return out;
  })()`;

  for (const [label, layers] of [["every layer", {}], ["the proxy alone", { fetch: false, offline: false }]]) {
    test(`the runner's world reaches no server — ${label}`, options(), async (t) => {
      const runner = await openRunner(layers);
      const marker = `runner-${label.replace(/\W+/g, "")}-${Date.now()}`;
      const fencedBefore = fence.connections.length;
      try {
        assert.deepEqual(runner.refused, []);
        const ctx = await newWorld(runner);
        const outcome = await within(evaluate(runner, ctx, ESCAPES(server.base, marker)), 20_000);
        assert.ok(outcome, "the probes settled");
        t.diagnostic(JSON.stringify(outcome));
        await delay(300);   // a beacon goes out after its call returns
        const leaked = server.hits.filter((hit) => hit.query.includes(marker));
        assert.deepEqual(leaked, [], "no request of the runner reached the server");
        assert.match(outcome.fetch, /^failed/);
        assert.match(outcome.xhr, /^failed/);
        assert.notEqual(outcome.websocket, "open");
        assert.notEqual(outcome.image, "loaded");
        assert.doesNotMatch(String(outcome.worker), /^status/);
        assert.doesNotMatch(String(outcome.iframe), /ok/);
        const fenced = fence.connections.length - fencedBefore;
        t.diagnostic(`fence connections: ${fenced}; requests Fetch failed: ${runner.paused.length}`);
        if (layers.fetch === false) assert.ok(fenced > 0, "with no other layer, the requests met the fence");
      } finally {
        await runner.close();
      }
    });
  }

  test("the binding reaches Loom from the run's world, by its id, without Runtime.enable; replies go back by callFunctionOn", options(), async (t) => {
    const runner = await openRunner();
    try {
      const calls = runner.session.collect("Runtime.bindingCalled");
      const first = await newWorld(runner);
      const pending = runner.session.send("Runtime.evaluate", {
        contextId: first, awaitPromise: true, returnByValue: true, silent: true,
        expression: `new Promise((resolve) => { globalThis.__reply = resolve; ${BINDING}(JSON.stringify({ id: 1, op: "title" })); })\n//# sourceURL=${SOURCE_URL}`,
      });
      await until(() => calls.length >= 1, 5000, "the binding call");
      assert.equal(calls[0].name, BINDING);
      assert.equal(calls[0].executionContextId, first, "the call names its world");
      assert.deepEqual(JSON.parse(calls[0].payload), { id: 1, op: "title" });
      await runner.session.send("Runtime.callFunctionOn", {
        executionContextId: first, functionDeclaration: "function(r) { globalThis.__reply(JSON.parse(r)); }",
        arguments: [{ value: JSON.stringify({ id: 1, ok: true, value: "Todos", url: "http://x/" }) }], silent: true,
      });
      const { result } = await within(pending, 5000, { result: {} });
      assert.deepEqual(result.value, { id: 1, ok: true, value: "Todos", url: "http://x/" });

      // A second run's world: a call left behind in the first carries the first's id.
      const second = await newWorld(runner);
      assert.notEqual(second, first);
      await evaluate(runner, first, `setTimeout(() => ${BINDING}("late"), 30), 1`);
      await evaluate(runner, second, `${BINDING}("second"), 1`);
      await until(() => calls.length >= 3, 5000, "both calls");
      const byPayload = Object.fromEntries(calls.slice(1).map((call) => [call.payload, call.executionContextId]));
      assert.equal(byPayload.second, second);
      assert.equal(byPayload.late, first, "the old world's call names the old world: Loom drops it");

      // A world the binding was not added to has none.
      const { executionContextId: bare } = await runner.session.send("Page.createIsolatedWorld", {
        frameId: runner.targetId, worldName: `loom-run-bare-${++worlds}`, grantUniveralAccess: false,
      });
      assert.equal(await evaluate(runner, bare, `typeof ${BINDING}`), "undefined");

      // The bridge's own cost: call out, reply in.
      const times = [];
      await evaluate(runner, second, `globalThis.__wait = new Map(); globalThis.__ask = (id) => new Promise((resolve) => { __wait.set(id, resolve); ${BINDING}(String(id)); }); 1`);
      const off = runner.session.on("Runtime.bindingCalled", ({ payload, executionContextId }) => {
        if (executionContextId !== second) return;
        runner.session.send("Runtime.callFunctionOn", {
          executionContextId: second, functionDeclaration: "function(id) { __wait.get(id)(id); }",
          arguments: [{ value: payload }], silent: true,
        }).catch(() => {});
      });
      for (let i = 0; i < 30; i++) {
        const started = performance.now();
        await evaluate(runner, second, `__ask("${i}")`);
        times.push(performance.now() - started);
      }
      off();
      times.sort((a, b) => a - b);
      t.diagnostic(`bridge round trip (evaluate + call + reply): p50 ${times[15].toFixed(2)} ms, p90 ${times[27].toFixed(2)} ms`);
      calls.stop();
    } finally {
      await runner.close();
    }
  });

  test("a SyntaxError names the agent's line; a runtime error's stack names browser_run_code.js", options(), async () => {
    const runner = await openRunner();
    try {
      const ctx = await newWorld(runner);
      // As AgentRunSource wraps the code: line 0 opens the call, the agent's code starts on line 1.
      const wrap = (code) => `(async (fn) => { try { return { ok: true, value: await fn() }; } catch (e) { return { ok: false, stack: String(e && e.stack) }; } })((\nasync (page) => {\n${code}\n}\n))\n//# sourceURL=${SOURCE_URL}`;
      const broken = await runner.session.send("Runtime.evaluate", { contextId: ctx, expression: wrap("const a = 1;\nconst b = ;"), returnByValue: true, silent: true });
      assert.ok(broken.exceptionDetails, "a SyntaxError is an exception of the evaluation itself");
      assert.match(broken.exceptionDetails.exception?.description || "", /SyntaxError/);
      // Script line 0 is the wrapper, 1 is "async (page) => {", the agent's line 1 is script line 2.
      assert.equal(broken.exceptionDetails.lineNumber, 3, "0-based: the agent's second line, after the two wrapper lines");
      const thrown = await evaluate(runner, ctx, wrap("const a = 1;\nnull.x;"));
      assert.equal(thrown.ok, false);
      assert.match(thrown.stack, /browser_run_code\.js:4:\d+/, thrown.stack);
    } finally {
      await runner.close();
    }
  });

  test("Runtime.terminateExecution ends a spinning run in milliseconds; the next run is not poisoned", options(), async (t) => {
    const runner = await openRunner();
    try {
      const ctx = await newWorld(runner);
      const spinning = settle(runner.session.send("Runtime.evaluate", {
        contextId: ctx, expression: "(async () => { while (true) {} })()", awaitPromise: true, returnByValue: true, silent: true,
      }));
      await delay(200);
      const probe = runner.session.send("Runtime.evaluate", { expression: "1", returnByValue: true });
      assert.equal(await settlesWithin(probe, 300), false, "the runner's thread is busy");
      const started = performance.now();
      await within(runner.session.send("Runtime.terminateExecution"), 5000);
      const outcome = await within(spinning, 1000);
      const elapsed = performance.now() - started;
      t.diagnostic(`the spinning evaluation ended ${elapsed.toFixed(1)} ms after terminateExecution`);
      assert.ok(outcome, "the evaluation answered");
      // "Execution was terminated" in the page's own world; Chromium 141 says
      // "Internal error" for an awaited evaluation in an isolated world.
      // Either way it failed: ChromiumRunner reads any failure after a stop as the stop.
      const text = outcome.ok ? JSON.stringify(outcome.value) : outcome.error.message;
      assert.equal(outcome.ok && !outcome.value?.exceptionDetails, false, text);
      assert.match(text, /terminated|Internal error/i, text);
      assert.ok(elapsed < 500, `within 500 ms (took ${elapsed.toFixed(1)})`);
      // The next run: a fresh world, its binding, its code — runs.
      const next = await newWorld(runner);
      assert.equal(await within(evaluate(runner, next, "(async () => 1 + 1)()"), 5000), 2);
      // terminateExecution on an idle runner: harmless.
      await runner.session.send("Runtime.terminateExecution");
      assert.equal(await within(evaluate(runner, next, "2 + 2"), 5000), 4);
    } finally {
      await runner.close();
    }
  });

  test("the ladder's next rungs: closeTarget destroys a spinning runner; Page.crash crashes one", options(), async (t) => {
    const closing = await openRunner();
    const ctx = await newWorld(closing);
    settle(closing.session.send("Runtime.evaluate", { contextId: ctx, expression: "while (true) {}", returnByValue: true }));
    await delay(150);
    const destroyed = chrome.conn.waitForEvent("Target.targetDestroyed", { predicate: (p) => p.targetId === closing.targetId, timeout: 5000 });
    const started = performance.now();
    await within(chrome.conn.send("Target.closeTarget", { targetId: closing.targetId }), 5000);
    await destroyed;
    const closedMs = performance.now() - started;
    t.diagnostic(`closeTarget of a spinning runner: destroyed in ${closedMs.toFixed(1)} ms`);
    assert.ok(closedMs < 1500, `within 1.5 s (took ${closedMs.toFixed(1)})`);
    await settle(chrome.conn.send("Target.disposeBrowserContext", { browserContextId: closing.browserContextId }));

    const crashing = await openRunner();
    try {
      const world = await newWorld(crashing);
      settle(crashing.session.send("Runtime.evaluate", { contextId: world, expression: "while (true) {}", returnByValue: true }));
      await delay(150);
      const crashed = chrome.conn.waitForEvent("Target.targetCrashed", { predicate: (p) => p.targetId === crashing.targetId, timeout: 10_000 });
      const crashStarted = performance.now();
      settle(crashing.session.send("Page.crash"));
      await crashed;
      t.diagnostic(`Page.crash of a spinning runner: targetCrashed in ${(performance.now() - crashStarted).toFixed(1)} ms`);
    } finally {
      await crashing.close();
    }
  });

  test("the runner's timers run at full speed, and a dialog in it is dismissed at once", options(), async (t) => {
    const runner = await openRunner();
    try {
      const ctx = await newWorld(runner);
      const elapsed = await evaluate(runner, ctx, `(async () => {
        const start = performance.now();
        for (let i = 0; i < 20; i++) await new Promise((r) => setTimeout(r, 10));
        return performance.now() - start;
      })()`);
      t.diagnostic(`20 × setTimeout(10): ${elapsed.toFixed(1)} ms`);
      assert.ok(elapsed < 400, `not throttled (${elapsed.toFixed(1)} ms)`);
      const answer = await within(evaluate(runner, ctx, "confirm('leave?')"), 5000, "no answer");
      assert.equal(answer, false, "dismissed by the runner's sink");
    } finally {
      await runner.close();
    }
  });

  /**
   * The facade in the fenced runner, its page calls carried out on a real
   * tab by a stand-in for ChromiumAgentCore+RunCode (the same helper ops and
   * input, the same reply shape: AgentRunReply.json). It pins the wire
   * format both sides agree on — {id, op, api, line, target, args} out,
   * {id, ok, value | error, url} back through __loomRunAnswer — and times it.
   */
  test("a script through the real facade: fill, Enter, check and reads on the page, answered by Loom's shapes", options({ skip: !FACADE && "AgentRunnerScript.swift has no facade yet" }), async (t) => {
    const page = await openTab(chrome, { url: server.url("/") });
    const runner = await openRunner();
    try {
      const ctx = await newWorld(runner);
      const config = { url: server.url("/"), viewport: { width: 1280, height: 800 }, defaultTimeout: 5000,
        navigationTimeout: 30000, scriptMs: 20000, maxSteps: 1000, maxInFlight: 32, maxMessageBytes: 262144,
        consoleLines: 200, consoleChars: 8000, valueChars: 20000 };
      await evaluate(runner, ctx, FACADE + "\n;globalThis.__loomRun.start(" + JSON.stringify(config) + ");", { awaitPromise: false });

      const calls = [];
      const timings = [];
      const reply = (answer) => runner.session.send("Runtime.callFunctionOn", {
        executionContextId: ctx, functionDeclaration: ANSWER_FUNCTION,
        arguments: [{ value: JSON.stringify({ ...answer, url: page.url }) }], silent: true,
      }).catch(() => {});
      /** The helper op, asked again while the target is not there yet (runResolving). */
      const resolving = async (op, args) => {
        for (let attempt = 0; attempt < 100; attempt++) {
          const answer = await page.helper(op, args);
          if (!answer.error || answer.error.code !== "notFound") return answer;
          await delay(30);
        }
        throw new Error("not found");
      };
      const ready = async (target, action, extra = {}) => {
        for (let attempt = 0; attempt < 100; attempt++) {
          const answer = await page.helper("prepare", { target, action, trusted: true, ...extra });
          if (answer.status === "ready") return answer;
          if (answer.error && answer.error.code !== "notFound") throw new Error(answer.error.message);
          await delay(16);
        }
        throw new Error("never ready");
      };
      const perform = async (message) => {
        const { op, target, args } = message;
        switch (op) {
          case "fill": {
            await ready(target, "type", { focus: true, selectAll: true });
            await page.session.send("Input.insertText", { text: args.value });
            await page.barrier();
            return null;
          }
          case "press": {
            await resolving("focus", { target });
            assert.equal(args.key, "Enter");
            const key = { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 };
            await Promise.all(page.session.sendBatch([["Input.dispatchKeyEvent", { type: "keyDown", ...key, text: "\r", unmodifiedText: "\r" }],
              ["Input.dispatchKeyEvent", { type: "keyUp", ...key }]]));
            await page.barrier();
            return null;
          }
          case "check": {
            const before = await resolving("read", { target, what: "checked" });
            if (before.value === args.checked) return null;
            const { point } = await ready(target, "click");
            await Promise.all(page.click(point.x, point.y));
            await page.barrier();
            return null;
          }
          case "read": return (await resolving("read", { target, what: args.what, name: args.name })).value;
          case "count": return (await page.helper("count", { target })).count;
          case "title": return (await page.helper("pageInfo", {})).title;
          default: throw new Error("the stand-in does not do " + op);
        }
      };
      const off = runner.session.on("Runtime.bindingCalled", ({ name, payload, executionContextId }) => {
        if (name !== BINDING || executionContextId !== ctx) return;
        const message = JSON.parse(payload);
        calls.push(message);
        const started = performance.now();
        perform(message).then(
          (value) => { timings.push({ op: message.op, ms: performance.now() - started }); return reply({ id: message.id, ok: true, value }); },
          (error) => reply({ id: message.id, ok: false, error: { name: "Error", message: message.api + ": " + error.message } }));
      });
      const code = `async (page) => {
  await page.getByLabel('New todo').fill('milk');
  await page.getByLabel('New todo').press('Enter');
  await page.getByRole('checkbox', { name: 'milk' }).check();
  console.log('count', await page.locator('#count').textContent());
  return { title: await page.title(), items: await page.getByRole('listitem').count(),
           checked: await page.getByRole('checkbox', { name: 'milk' }).isChecked() };
}`;
      const started = performance.now();
      const outcome = await within(evaluate(runner, ctx, "globalThis.__loomRun.run((\n" + code + "\n))\n//# sourceURL=browser_run_code.js"), 20_000);
      const total = performance.now() - started;
      off();
      assert.ok(outcome, "the run answered");
      assert.equal(outcome.ok, true, JSON.stringify(outcome.error));
      assert.deepEqual(JSON.parse(outcome.value), { title: "Todos", items: 1, checked: true });
      assert.deepEqual(outcome.logs, ["count 1"]);
      assert.deepEqual(outcome.unfinished, []);
      assert.equal(await page.evaluate("window.state.todos.map((t) => t.text + ':' + t.done).join()"), "milk:true", "the page did it");

      // The messages as Loom decodes them: the fields in args, the target a locator with its words.
      const fill = calls.find((call) => call.op === "fill");
      assert.equal(fill.api, "locator.fill");
      assert.equal(fill.line, 2, "the agent's line");
      assert.deepEqual(Object.keys(fill.target).sort(), ["chain", "desc", "strict"]);
      assert.equal(fill.target.desc, "getByLabel('New todo')");
      assert.equal(fill.args.value, "milk");
      assert.ok(typeof fill.args.timeout === "number" && fill.args.timeout <= 5000, "the call's time left, in args");
      assert.deepEqual(calls.map((call) => call.op), ["fill", "press", "check", "read", "title", "count", "read"]);
      t.diagnostic(`run: ${total.toFixed(1)} ms; ops: ${timings.map((x) => `${x.op} ${x.ms.toFixed(1)}`).join(", ")}`);
    } finally {
      await runner.close();
      await settle(page.close());
    }
  });

  // ------------------------------------------------------------ agent scripts, end to end (lib/runcore.mjs)

  const noFacade = !FACADE && "AgentRunnerScript.swift has no facade yet";

  /** `code` run on a fresh tab at `path` of the site; the tab is closed after `inspect`. */
  async function script(path, code, { limits, inspect } = {}) {
    core ??= new Runner(chrome, fence.port);
    const tab = await openTab(chrome, { url: site.base + path });
    const page = new RunPage(tab);
    try {
      const out = await within(runCode(code, { page, runner: core, limits }), 60_000, null);
      assert.ok(out, "the run answered within a minute");
      const inspected = inspect ? await inspect(page, tab) : undefined;
      return { ...out, page, inspected };
    } finally {
      if (page.dialog) page.dismissDialog();
      await settle(tab.close());
    }
  }

  test("a script navigates by a getByRole click and reads the new page; a wait for a hash change runs beside its click", options({ skip: noFacade }), async () => {
    const { report, run, page } = await script("/a", `async (page) => {
  await page.goto('${site.base}/a');
  console.log('at', page.url(), await page.title());
  await page.getByRole('link', { name: 'Next' }).click();
  const heading = await page.getByRole('heading').textContent();
  await Promise.all([page.waitForURL(/#docs$/), page.getByRole('link', { name: 'Docs' }).click()]);
  return { heading, url: page.url() };
}`);
    assert.equal(report.error, undefined, report.error);
    assert.deepEqual(JSON.parse(report.value), { heading: "Page B", url: `${site.base}/b#docs` });
    assert.deepEqual(report.output, [`at ${site.base}/a Page A`]);
    assert.deepEqual(report.unfinished, []);
    assert.equal(page.url, `${site.base}/b#docs`, "the page did it");
    assert.equal(run.maxInFlightSeen, 2, "waitForURL's wait ran beside the click");
    assert.equal(run.steps, 6, "one step per call: the wait's two messages are one");
    assert.equal(run.messages, 7);
  });

  test("a form: fill, check, selectOption, then Promise.all([waitForURL, click]) submits it", options({ skip: noFacade }), async () => {
    const { report, run } = await script("/b", `async (page) => {
  await page.getByLabel('Email').fill('a@b.c');
  await page.getByLabel('Password').fill('hunter2');
  await page.getByRole('checkbox', { name: 'I agree' }).check();
  const plan = await page.getByLabel('Plan').selectOption('pro');
  await Promise.all([page.waitForURL('**/done?*'), page.getByRole('button', { name: 'Sign in' }).click()]);
  return { plan, url: page.url(), heading: await page.locator('h1').textContent() };
}`);
    assert.equal(report.error, undefined, report.error);
    assert.deepEqual(JSON.parse(report.value), {
      plan: ["pro"], url: `${site.base}/done?email=a%40b.c&password=hunter2&terms=yes&plan=pro`, heading: "Done",
    });
    assert.equal(run.maxInFlightSeen, 2);
    assert.ok(site.hits.includes("/done?email=a%40b.c&password=hunter2&terms=yes&plan=pro"), "the form reached the server");
  });

  test("a strict-mode violation fails at once, in Playwright's words, at the agent's line", options({ skip: noFacade }), async () => {
    const { report, run, endedAt } = await script("/a", `async (page) => {
  await page.getByRole('button', { name: 'Save' }).click();
}`);
    assert.equal(report.error, "Error: locator.click: strict mode violation: getByRole('button', { name: 'Save' }) resolved to 2 elements:\n"
      + "    1) button \"Save\"\n    2) button \"Save draft\" (line 2 of your code, step 1)");
    assert.ok(endedAt - run.started < 2000, "no auto-wait for an ambiguous locator");
  });

  test("auto-wait: a read waits for its element; a click on none is a TimeoutError naming what it waited for", options({ skip: noFacade }), async () => {
    const late = await script("/a", "return await page.getByText('arrived').textContent();");
    assert.equal(late.report.error, undefined, late.report.error);
    assert.equal(JSON.parse(late.report.value), "arrived");
    const missing = await script("/a", `async (page) => {
  await page.getByRole('button', { name: 'Missing' }).click({ timeout: 300 });
}`);
    assert.equal(missing.report.error, "TimeoutError: locator.click: Timeout 300ms exceeded.\nCall log:\n"
      + "  - waiting for getByRole('button', { name: 'Missing' }) (line 2 of your code, step 1)");
  });

  test("dialogs with page.on('dialog'): the script answers each, from a click or from page.evaluate", options({ skip: noFacade }), async () => {
    const { report, page, inspected } = await script("/dialogs", `async (page) => {
  page.on('dialog', async (dialog) => {
    console.log(dialog.type(), dialog.message());
    await dialog.accept(dialog.type() === 'prompt' ? 'Ada' : undefined);
  });
  await page.getByRole('button', { name: 'Delete' }).click();
  await page.getByRole('button', { name: 'Rename' }).click();
  await page.getByRole('button', { name: 'Notify' }).click();
  const asked = await page.evaluate(() => prompt('question?', 'yes.'));
  return { asked, answers: await page.evaluate(() => window.answers) };
}`, { inspect: (_, tab) => tab.evaluate("window.answers") });
    assert.equal(report.error, undefined, report.error);
    // Playwright's own page.evaluate(() => prompt(…)) test: the handler's text comes back.
    assert.deepEqual(JSON.parse(report.value), { asked: "Ada", answers: ["confirm:true", "prompt:Ada", "alert closed"] });
    assert.deepEqual(report.output, ["confirm Delete it?", "prompt Your name?", "alert Saved", "prompt question?"]);
    assert.deepEqual(inspected, ["confirm:true", "prompt:Ada", "alert closed"]);
    assert.equal(page.dialog, null, "every dialog answered once");
  });

  test("a dialog without a listener stops the run; one the handler never answers makes its click a TimeoutError", options({ skip: noFacade }), async () => {
    const none = await script("/dialogs", `async (page) => {
  console.log('before');
  await page.getByRole('button', { name: 'Delete' }).click();
  return 'not reached';
}`, { inspect: (page) => page.dialog });
    assert.equal(none.report.error, "The page opened a confirm dialog (\"Delete it?\") at step 1 (line 3 of your code): the script was stopped. "
      + "Answer it with browser_handle_dialog, or handle it in the script: page.once('dialog', d => d.accept()).");
    assert.equal(none.inspected?.message, "Delete it?", "left open: the answer shows ### Modal state");
    assert.equal(none.ladder?.rung, "close");

    const evaluated = await script("/dialogs", "return await page.evaluate(() => confirm('really?'));");
    assert.match(evaluated.report.error, /^The page opened a confirm dialog \("really\?"\) at step 1 \(line 1 of your code\): the script was stopped\./);

    const once = await script("/dialogs", `async (page) => {
  page.once('dialog', (dialog) => dialog.dismiss());
  await page.getByRole('button', { name: 'Delete' }).click();
  await page.getByRole('button', { name: 'Delete' }).click();
}`);
    assert.match(once.report.error, /^The page opened a confirm dialog \("Delete it\?"\) at step 2 \(line 4 of your code\)/, "once: the second has no listener");

    const unanswered = await script("/dialogs", `async (page) => {
  page.on('dialog', (dialog) => console.log('saw', dialog.message()));
  await page.getByRole('button', { name: 'Delete' }).click({ timeout: 500 });
  return 'not reached';
}`, { inspect: (page) => page.dialog });
    assert.equal(unanswered.report.error, "TimeoutError: locator.click: Timeout exceeded while the page's confirm dialog (\"Delete it?\") waited "
      + "for an answer: your page.on('dialog') handler must call dialog.accept() or dialog.dismiss() (line 3 of your code, step 1)");
    assert.deepEqual(unanswered.report.output, ["saw Delete it?"]);
    assert.equal(unanswered.inspected?.message, "Delete it?");
  });

  test("the script's console is kept for the answer: formatted, 200 lines at most, the rest counted", options({ skip: noFacade }), async () => {
    const { report } = await script("/a", `async (page) => {
  console.log('hello %s, %d items', 'world', 3, { a: 1 });
  console.warn('careful');
  console.error(new Error('boom'));
  for (let i = 0; i < 250; i++) console.log('line ' + i);
  return 1;
}`);
    assert.deepEqual(report.output.slice(0, 4), ['hello world, 3 items {"a":1}', "[WARNING] careful", "[ERROR] Error: boom", "line 0"]);
    assert.equal(report.output.length, 200);
    assert.equal(report.outputDropped, 53);
    assert.equal(report.value, "1");
  });

  test("errors name the agent's line: a SyntaxError runs nothing; a throw; a call left without await", options({ skip: noFacade }), async () => {
    const syntax = await script("/a", "async (page) => {\n  const a = 1;\n  const b = ;\n}");
    assert.equal(syntax.report.error, "SyntaxError: Unexpected token ';' (line 3, column 13 of your code). Nothing ran.");
    assert.equal(syntax.run.messages, 0);
    const thrown = await script("/a", "await page.title();\nthrow new Error('nope');");
    assert.equal(thrown.report.error, "Error: nope (line 2 of your code)");
    const unawaited = await script("/a", "page.getByRole('button', { name: 'Missing' }).click();\nreturn 'returned';");
    assert.equal(unawaited.report.value, "\"returned\"");
    assert.deepEqual(unawaited.report.unfinished, ["locator.click getByRole('button', { name: 'Missing' })"]);
  });

  test("while (true) {} is stopped at the script's end by Runtime.terminateExecution, at once; the next run works", options({ skip: noFacade }), async (t) => {
    const spin = await script("/a", "await page.title();\nwhile (true) {}", { limits: { scriptTime: 1500 } });
    assert.match(spin.report.error, /^The script ran out of time: browser_run_code stops a script after 1 s\. It was stopped at step 1 \(line 1 of your code\)\.$/);
    assert.equal(spin.stopped, "deadline");
    t.diagnostic(`terminateExecution answered in ${spin.ladder.terminated.toFixed(1)} ms; the runner target was gone ${spin.ladder.closed.toFixed(1)} ms after the stop`);
    assert.ok(spin.ladder.terminated < 250, "the spinning renderer took the termination (250 ms is the ladder's wait)");
    assert.equal(spin.ladder.rung, "close", "closed within 1 s: no Page.crash needed");
    assert.ok(spin.ladder.closed < 1000, `stopped within 1 s (${spin.ladder.closed.toFixed(1)} ms)`);
    assert.ok(spin.endedAt - spin.run.started < 2500, "the run ended at the script's end, not later");
    const next = await script("/a", "return await page.title();");
    assert.equal(next.report.error, undefined, next.report.error);
    assert.equal(JSON.parse(next.report.value), "Page A", "a fresh runner target, not poisoned");
  });

  test("1 000 page calls: the facade refuses the next one; a wait's two messages are one step; a script that posts itself is stopped", options({ skip: noFacade }), async () => {
    const capped = await script("/a", `async (page) => {
  let n = 0;
  try { for (;;) { await page.locator('h1').count(); n++; } } catch (error) { return { n, error: error.message }; }
}`);
    assert.deepEqual(JSON.parse(capped.report.value), { n: 1000, error: "locator.count: a script makes 1000 page calls at most" });
    assert.equal(capped.stopped, null);

    const waited = await script("/b", `async (page) => {
  for (let i = 0; i < 998; i++) await page.locator('h1').count();
  await Promise.all([page.waitForURL(/#docs$/), page.getByRole('link', { name: 'Docs' }).click()]);
  return page.url();
}`);
    assert.equal(waited.report.error, undefined, "within the facade's 1 000: not stopped by Loom");
    assert.equal(waited.run.steps, 1000);
    assert.equal(waited.run.messages, 1001);

    const flood = await script("/a", `async (page) => {
  for (let i = 0; i < 2500; i++) __loomRunCall(JSON.stringify({ id: 1e6 + i, op: 'count', target: { chain: [{ css: 'h1' }], desc: 'h1', strict: true }, args: {} }));
  await page.waitForTimeout(5000);
}`);
    assert.equal(flood.report.error, "The script made more than 1000 page calls: it was stopped.");
    assert.equal(flood.run.maxInFlightSeen, 32, "never more than 32 in flight");
  });

  test("the run's world: no network API, an opaque origin with no cookie or storage of the page's profile, no Node", options({ skip: noFacade }), async () => {
    const { report } = await script("/a", `async (page) => {
  await page.evaluate(() => { document.cookie = 'session=1'; localStorage.setItem('token', 'secret'); });
  const out = {};
  for (const name of ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'open', 'alert']) {
    try { globalThis[name]('http://127.0.0.1:1/'); out[name] = 'ran'; } catch (error) { out[name] = error.message.split(':')[0]; }
  }
  try { navigator.sendBeacon('http://127.0.0.1:1/', 'x'); out.sendBeacon = 'ran'; } catch (error) { out.sendBeacon = error.message.split(':')[0]; }
  out.origin = location.origin;
  for (const [name, read] of [['cookie', () => document.cookie], ['localStorage', () => localStorage.getItem('token')], ['indexedDB', () => indexedDB.open('x') && 'opened']]) {
    try { out[name] = read(); } catch (error) { out[name] = error.name; }
  }
  out.node = [typeof process, typeof require].join();
  out.pageCookie = await page.evaluate(() => document.cookie);
  return out;
}`);
    assert.equal(report.error, undefined, report.error);
    const out = JSON.parse(report.value);
    for (const name of ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "open", "alert"]) {
      assert.equal(out[name], `${name} is not available in browser_run_code`, name);
    }
    assert.equal(out.sendBeacon, "navigator.sendBeacon is not available in browser_run_code");
    assert.equal(out.origin, "null", "the runner's about:blank in a context of its own");
    assert.equal(out.cookie, "SecurityError");
    assert.equal(out.localStorage, "SecurityError");
    assert.equal(out.indexedDB, "SecurityError");
    assert.equal(out.node, "undefined,undefined");
    assert.equal(out.pageCookie, "session=1", "the page's own world is page.evaluate's, as browser_evaluate's");
  });

  test("the runner's own navigations reach no server: location.href, a form, an iframe, window.open", options(), async () => {
    // Without the fence each of these reaches the server (the headless shell
    // opens the popup too): the runner navigating itself is a request too.
    const runner = await openRunner();
    const marker = `nav-${Date.now()}`;
    const url = (name) => `${server.base}/ok?${marker}-${name}`;
    try {
      await evaluate(runner, await newWorld(runner), `location.href = ${JSON.stringify(url("location"))}; 1`, { awaitPromise: false });
      await delay(700);
      // The first left an error page: a world of it, the rest from there.
      await evaluate(runner, await newWorld(runner), `(() => {
        const form = document.createElement("form");
        form.action = ${JSON.stringify(url("form"))}; form.method = "post";
        document.documentElement.appendChild(form);
        const frame = document.createElement("iframe");
        frame.src = ${JSON.stringify(url("frame"))};
        document.documentElement.appendChild(frame);
        try { open(${JSON.stringify(url("popup"))}); } catch (_) {}
        setTimeout(() => form.submit(), 100);
        return 1;
      })()`, { awaitPromise: false });
      await delay(1500);
      assert.deepEqual(server.hits.filter((hit) => hit.query.includes(marker)), [], "nothing reached the server");
    } finally {
      await runner.close();
    }
  });
});
