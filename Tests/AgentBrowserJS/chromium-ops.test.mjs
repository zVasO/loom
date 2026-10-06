// The helper's Chromium-only side (ADR-0015) on a real Chromium, as Loom's
// engine drives it: the scripts installed by Page.addScriptToEvaluateOnNewDocument
// in the "loom-agent" world (the helper in the top frame only), every call
// AgentScripts.helperFunction by Runtime.callFunctionOn there, the input
// real (Input.*, through Playwright's mouse). The relay's binding mode is
// also checked in the page's world, where a stand-in binding is set by hand.
// WebKit never sends these arguments nor calls these ops: dom.test.mjs pins
// its side, unchanged.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { resolve } from "node:path";
import {
  fixturesDirectory, helperFunctionSource, helperSource, pageHookSource, relaySource, repoRoot,
} from "./extract.mjs";

async function loadPlaywright() {
  try { return await import("playwright"); } catch (_) { /* not local */ }
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    return createRequire(import.meta.url)(resolve(root, "playwright"));
  } catch (_) {
    return null;
  }
}

const playwright = await loadPlaywright();
const skip = playwright ? false : "Playwright is not installed";

const WORLD = "loom-agent";
const BINDING = "__loomHookBinding";
const VIEWPORT = { width: 900, height: 700 };

const PAGES = {
  "/blank": "<!doctype html><title>Blank</title><body></body>",
  // Logs and fetches at document start: before Loom can have added the binding.
  "/boot": "<!doctype html><title>Boot</title><script>console.log('boot ' + location.search);"
    + "fetch('/missing.json').catch(() => {});</script><body><p>Booted</p></body>",
  // A same-origin frame whose button reports its clicks to the parent.
  "/frame": "<!doctype html><body style='margin:0'><button id='inner' style='margin:10px 20px'>Inner</button>"
    + "<script>document.getElementById('inner').addEventListener('click', (e) => parent.events.push('inner:' + e.isTrusted));"
    + "</script></body>",
};

let browser;
let server;
let base;

before(async () => {
  if (skip) return;
  server = createServer((request, response) => {
    const path = request.url.split("?")[0];
    if (path === "/" || path === "/todo") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(readFileSync(resolve(fixturesDirectory, "todo.html")));
    } else if (PAGES[path]) {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(PAGES[path]);
    } else {
      response.writeHead(404, { "content-type": "application/json" });
      response.end("{}");
    }
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  base = "http://127.0.0.1:" + server.address().port;
  browser = await playwright.chromium.launch();
});

after(async () => {
  await browser?.close();
  server?.close();
});

/**
 * A tab as the engine sets it up: relay and helper in Loom's world, the
 * page hook in the page's; `helper(op, args)` is the engine's call. With
 * `helper: false` the world has no helper (a document Loom has not reached).
 */
async function openTab(path, { helper = true } = {}) {
  const page = await browser.newPage({ viewport: VIEWPORT });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Page.enable");
  await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: relaySource(), worldName: WORLD, runImmediately: true });
  await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: pageHookSource(), runImmediately: true });
  if (helper) {
    await cdp.send("Page.addScriptToEvaluateOnNewDocument", {
      source: "if (window === window.top) {\n" + helperSource() + "\n}", worldName: WORLD, runImmediately: true,
    });
  }
  const bindings = [];
  cdp.on("Runtime.bindingCalled", (event) => {
    if (event.name === BINDING) bindings.push(JSON.parse(event.payload));
  });
  if (path) await page.goto(base + path);
  const tab = {
    page,
    cdp,
    bindings,
    async world() {
      const { frameTree } = await cdp.send("Page.getFrameTree");
      const { executionContextId } = await cdp.send("Page.createIsolatedWorld", {
        frameId: frameTree.frame.id, worldName: WORLD, grantUniveralAccess: false,
      });
      return executionContextId;
    },
    /** AgentScripts.helperFunction, called as the engine calls it. */
    async helper(op, args = {}) {
      const answer = await cdp.send("Runtime.callFunctionOn", {
        functionDeclaration: helperFunctionSource(), executionContextId: await tab.world(),
        arguments: [{ value: op }, { value: JSON.stringify(args) }], returnByValue: true, awaitPromise: true, silent: true,
      });
      if (answer.exceptionDetails) throw new Error(JSON.stringify(answer.exceptionDetails));
      return JSON.parse(answer.result.value);
    },
    /** An expression in Loom's world, awaited — to schedule page work and call the helper in one task. */
    async inWorld(expression) {
      const answer = await cdp.send("Runtime.evaluate", {
        expression, contextId: await tab.world(), returnByValue: true, awaitPromise: true, silent: true,
      });
      if (answer.exceptionDetails) throw new Error(JSON.stringify(answer.exceptionDetails));
      return answer.result.value;
    },
    close: () => page.close(),
  };
  return tab;
}

/** A page with the relay in the page's own world and no WebKit handler: the binding is set by hand. */
async function openRelayPage() {
  const page = await browser.newPage({ viewport: VIEWPORT });
  await page.addInitScript(relaySource());
  await page.goto(base + "/blank");
  return page;
}

const refOf = (yaml, pattern) => {
  const line = yaml.split("\n").find((l) => pattern.test(l));
  assert.ok(line, "no line matches " + pattern + " in:\n" + yaml);
  return /\[ref=(e\d+)\]/.exec(line)[1];
};

/** Adds an element to the page's body, from the page's world. */
const append = (page, html, style = "") => page.evaluate(([markup, css]) => {
  const holder = document.createElement("div");
  holder.innerHTML = markup;
  const el = holder.firstElementChild;
  if (css) el.style.cssText = css;
  document.body.append(el);
}, [html, style]);

/** A same-origin frame at a known place: left 100, top 200, a 5 px border. */
const addFrame = (page, style = "position:absolute; left:100px; top:200px; width:300px; height:150px; border:5px solid red") =>
  page.evaluate((css) => new Promise((done) => {
    const frame = document.createElement("iframe");
    frame.id = "framed";
    frame.style.cssText = css;
    frame.src = "/frame";
    frame.onload = done;
    document.body.prepend(frame);
  }), style);

// ---------------------------------------------------------------- the call

test("helperFunction is the one-line function of the engine's fixture, and says when the helper is missing", { skip }, async () => {
  const fn = helperFunctionSource();
  assert.ok(fn.startsWith("async function(op, args) {"), fn);
  assert.ok(!fn.includes("\n"), "one line");
  const fixture = resolve(repoRoot, "Tests/AgentBrowserCDP/fixtures/init.json");
  if (existsSync(fixture)) {
    const init = JSON.parse(readFileSync(fixture, "utf8"));
    assert.equal(fn, init.helperCall[1].functionDeclaration, "the CDP harness calls the same function");
  }
  const bare = await openTab("/blank", { helper: false });
  assert.deepEqual(await bare.helper("pageInfo"), { error: { code: "helperMissing", message: "the helper is not loaded" } });
  await bare.close();
  const tab = await openTab("/todo");
  const info = await tab.helper("pageInfo");
  assert.equal(info.title, "Todos");
  assert.equal(info.width, VIEWPORT.width);
  assert.equal((await tab.helper("nope")).error.code, "invalid");
  assert.equal(await tab.page.evaluate("typeof globalThis.__loomAgent"), "undefined", "the page's world never sees the helper");
  await tab.close();
});

// ---------------------------------------------------------------- the relay's binding mode

test("without WebKit's handler, posts wait for the binding and go, in order, with the next one; requests stay out", { skip }, async () => {
  const page = await openRelayPage();
  const got = await page.evaluate(() => {
    const fire = (m) => document.dispatchEvent(new CustomEvent("loom-agent-hook", { detail: JSON.stringify(m) }));
    fire({ t: "console", level: "info", text: "one" });
    fire({ t: "req", id: 7, kind: "fetch", method: "GET", url: "http://x/" });
    fire({ t: "console", level: "error", text: "two" });
    fire({ t: "res", id: 7, status: 200 });
    const payloads = [];
    globalThis.__loomHookBinding = (payload) => payloads.push(payload);
    fire({ t: "console", level: "warning", text: "three" });
    fire({ t: "req", id: 8, kind: "xhr", method: "POST", url: "http://x/" });
    fire({ t: "console", level: "info", text: "four" });
    return payloads;
  });
  assert.ok(got.every((payload) => typeof payload === "string"), "the binding takes JSON text");
  const messages = got.map((payload) => JSON.parse(payload));
  assert.deepEqual(messages.map((m) => m.text), ["one", "two", "three", "four"]);
  assert.ok(!messages.some((m) => m.t === "req" || m.t === "res"), "the Network domain sees requests");
  await page.close();
});

test("a post held for the binding goes out on its own once the binding comes", { skip }, async () => {
  const page = await openRelayPage();
  await page.evaluate(() => {
    document.dispatchEvent(new CustomEvent("loom-agent-hook",
      { detail: JSON.stringify({ t: "console", level: "info", text: "early" }) }));
  });
  await page.evaluate(() => {
    window.__got = [];
    globalThis.__loomHookBinding = (payload) => window.__got.push(JSON.parse(payload));
  });
  await page.waitForFunction(() => window.__got.length > 0, null, { timeout: 3000 });
  assert.deepEqual(await page.evaluate(() => window.__got.map((m) => m.text)), ["early"]);
  await page.close();
});

test("the relay holds 200 posts at most for the binding: the rest is counted, then reported", { skip }, async () => {
  const page = await openRelayPage();
  const got = await page.evaluate(async () => {
    const fire = (text) => document.dispatchEvent(new CustomEvent("loom-agent-hook",
      { detail: JSON.stringify({ t: "console", level: "info", text }) }));
    for (let i = 0; i < 200; i++) fire("a" + i);               // the rate's whole bucket: all admitted
    await new Promise((done) => setTimeout(done, 400));          // ~80 tokens back
    for (let i = 0; i < 30; i++) fire("b" + i);                 // admitted, but nowhere to wait
    const payloads = [];
    globalThis.__loomHookBinding = (payload) => payloads.push(JSON.parse(payload));
    fire("c");
    return payloads;
  });
  assert.deepEqual(got.slice(0, 200).map((m) => m.text), Array.from({ length: 200 }, (_, i) => "a" + i));
  assert.deepEqual(got[200], { t: "dropped", n: 30 });
  assert.equal(got[201].text, "c");
  assert.equal(got.length, 202);
  await page.close();
});

test("WebKit with its channel cut by a flood stays silent, as before: no binding mode there", { skip }, async () => {
  const page = await browser.newPage({ viewport: VIEWPORT });
  // WebKit's vendor, and no window.webkit: it goes with the world's last handler.
  await page.addInitScript(() => Object.defineProperty(navigator, "vendor", { get: () => "Apple Computer, Inc." }));
  await page.addInitScript(relaySource());
  await page.goto(base + "/blank");
  const got = await page.evaluate(async () => {
    const payloads = [];
    globalThis.__loomHookBinding = (payload) => payloads.push(payload);
    document.dispatchEvent(new CustomEvent("loom-agent-hook",
      { detail: JSON.stringify({ t: "console", level: "info", text: "flooding" }) }));
    await new Promise((done) => setTimeout(done, 50));
    return { payloads, installed: globalThis.__loomAgentRelay === true };
  });
  assert.deepEqual(got, { payloads: [], installed: true });
  await page.close();
});

test("in Loom's world, the document-start console reaches Runtime.bindingCalled once the binding is added", { skip }, async () => {
  const tab = await openTab("/boot?first");
  // Added after the commit, as the engine does on Page.frameNavigated: the
  // relay held what the page logged while it loaded.
  await tab.world();
  await tab.cdp.send("Runtime.addBinding", { name: BINDING, executionContextName: WORLD });
  const deadline = Date.now() + 5000;
  while (!tab.bindings.some((m) => m.text === "boot ?first") && Date.now() < deadline) {
    await new Promise((done) => setTimeout(done, 20));
  }
  assert.ok(tab.bindings.some((m) => m.t === "console" && m.level === "info" && m.text === "boot ?first"),
    JSON.stringify(tab.bindings));
  await tab.page.evaluate(() => console.warn("later", 42));
  const later = Date.now() + 5000;
  while (!tab.bindings.some((m) => m.text === "later 42") && Date.now() < later) {
    await new Promise((done) => setTimeout(done, 20));
  }
  assert.ok(tab.bindings.some((m) => m.level === "warning" && m.text === "later 42"), JSON.stringify(tab.bindings));
  assert.ok(!tab.bindings.some((m) => m.t === "req" || m.t === "res"), "the boot fetch is the Network domain's");
  await tab.close();
});

// ---------------------------------------------------------------- prepare, trusted

test("prepare trusted: the point is the element's centre in the top viewport, and a real click there reaches it", { skip }, async () => {
  const tab = await openTab("/todo");
  const { yaml } = await tab.helper("snapshot", {});
  const answer = await tab.helper("prepare", { target: refOf(yaml, /generic \[ref=e\d+\] \[cursor=pointer\]: Clickable card/), action: "click", trusted: true });
  assert.equal(answer.status, "ready", JSON.stringify(answer));
  const box = await tab.page.locator("#card").boundingBox();
  assert.ok(Math.abs(answer.point.x - (box.x + box.width / 2)) < 0.6, JSON.stringify([answer.point, box]));
  assert.ok(Math.abs(answer.point.y - (box.y + box.height / 2)) < 0.6, JSON.stringify([answer.point, box]));
  assert.equal(answer.fill, "none");
  assert.equal(answer.description, "<div#card.card>");
  await tab.page.mouse.click(answer.point.x, answer.point.y);
  assert.deepEqual(await tab.page.evaluate(() => window.events), ["card"]);
  await tab.close();
});

test("prepare trusted scrolls an element below the fold into the top viewport first", { skip }, async () => {
  const tab = await openTab("/todo");
  await append(tab.page, "<div></div>", "height:3000px");
  await append(tab.page, "<button id='far'>Far away</button>");
  await tab.page.evaluate(() => document.getElementById("far").addEventListener("click", () => window.events.push("far")));
  const answer = await tab.helper("prepare", { target: "#far", action: "click", trusted: true });
  assert.equal(answer.status, "ready", JSON.stringify(answer));
  assert.ok(await tab.page.evaluate(() => window.scrollY) > 2000, "scrolled");
  assert.ok(answer.point.y > 0 && answer.point.y < VIEWPORT.height, JSON.stringify(answer.point));
  await tab.page.mouse.click(answer.point.x, answer.point.y);
  assert.deepEqual(await tab.page.evaluate(() => window.events), ["far"]);
  await tab.close();
});

test("prepare trusted in a same-origin frame: the point is in the top viewport, past the frame's offset and border", { skip }, async () => {
  const tab = await openTab("/todo");
  await addFrame(tab.page);
  const { yaml } = await tab.helper("snapshot", { budget: 20000 });
  const answer = await tab.helper("prepare", { target: refOf(yaml, /button "Inner"/), action: "click", trusted: true });
  assert.equal(answer.status, "ready", JSON.stringify(answer));
  const inner = await tab.page.frameLocator("#framed").locator("#inner").boundingBox();
  assert.ok(Math.abs(answer.point.x - (inner.x + inner.width / 2)) < 0.6, JSON.stringify([answer.point, inner]));
  assert.ok(Math.abs(answer.point.y - (inner.y + inner.height / 2)) < 0.6, JSON.stringify([answer.point, inner]));
  assert.equal(answer.rect.x, 100 + 5 + 20);
  assert.equal(answer.rect.y, 200 + 5 + 10);
  await tab.page.mouse.click(answer.point.x, answer.point.y);
  assert.deepEqual(await tab.page.evaluate(() => window.events), ["inner:true"], "a trusted click inside the frame");
  await tab.close();
});

test("prepare trusted asks again while the element moves, and is ready once it stops", { skip }, async () => {
  const tab = await openTab("/todo");
  await append(tab.page, "<button id='mover'>Moving</button>", "position:absolute; left:0; top:400px");
  await tab.page.evaluate(() => {
    const mover = document.getElementById("mover");
    let left = 0;
    window.moving = true;
    const step = () => {
      if (!window.moving) return;
      left = (left + 7) % 600;
      mover.style.left = left + "px";
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
  const moving = await tab.helper("prepare", { target: "#mover", action: "click", trusted: true });
  assert.equal(moving.status, "retry", JSON.stringify(moving));
  assert.equal(moving.reason, "element is moving");
  assert.equal(typeof moving.rect.x, "number");
  await tab.page.evaluate(() => { window.moving = false; });
  const still = await tab.helper("prepare", { target: "#mover", action: "click", trusted: true });
  assert.equal(still.status, "ready", JSON.stringify(still));
  // Typing needs no stability: no frame waited for.
  const typing = await tab.helper("prepare", { target: "#new", action: "type", trusted: true });
  assert.equal(typing.status, "ready");
  await tab.close();
});

test("prepare trusted names what covers the element — in its own document, or over its frame", { skip }, async () => {
  const tab = await openTab("/todo");
  await addFrame(tab.page);
  const { yaml } = await tab.helper("snapshot", { budget: 20000 });
  const inner = refOf(yaml, /button "Inner"/);
  // Over the frame only: the frame's own document still hits the button.
  await append(tab.page, "<div id='veil' class='glass'></div>", "position:absolute; left:90px; top:190px; width:330px; height:180px; z-index:5");
  const veiled = await tab.helper("prepare", { target: inner, action: "click", trusted: true });
  assert.equal(veiled.status, "retry", JSON.stringify(veiled));
  assert.equal(veiled.reason, "<div#veil.glass> intercepts pointer events");
  await tab.page.evaluate(() => document.getElementById("veil").remove());
  assert.equal((await tab.helper("prepare", { target: inner, action: "click", trusted: true })).status, "ready");
  // The whole page.
  await tab.page.click("#cover");
  const covered = await tab.helper("prepare", { target: refOf(yaml, /button "Add"/), action: "click", trusted: true });
  assert.equal(covered.status, "retry");
  assert.match(covered.reason, /^<div#overlay\.shown> intercepts pointer events$/);
  await tab.close();
});

test("prepare trusted readies a field for Input.insertText: focused, all selected, and says how to fill it", { skip }, async () => {
  const tab = await openTab("/todo");
  await append(tab.page, "<input id='when' type='date'>");
  await append(tab.page, "<input id='how-many' type='number'>");
  await append(tab.page, "<textarea id='notes'>x</textarea>");
  await append(tab.page, "<div id='rich' contenteditable='true'>rich</div>");
  const fills = {};
  for (const target of ["#new", "#when", "#how-many", "#notes", "#rich"]) {
    fills[target] = (await tab.helper("prepare", { target, action: "type", trusted: true })).fill;
  }
  fills["#clear"] = (await tab.helper("prepare", { target: "#clear", action: "click", trusted: true })).fill;
  assert.deepEqual(fills, {
    "#new": "insertText", "#when": "setValue", "#how-many": "setValue", "#notes": "insertText", "#rich": "insertText", "#clear": "none",
  });
  assert.equal((await tab.helper("prepare", { target: "#volume", action: "type", trusted: true })).error.code, "notEditable",
    "as the single shot: a slider is not typed into");
  // The React-style field: real text replaces what was there.
  await tab.page.fill("#new", "old text");
  const ready = await tab.helper("prepare", { target: "#new", action: "type", trusted: true, focus: true, selectAll: true });
  assert.equal(ready.status, "ready");
  assert.deepEqual(await tab.page.evaluate(() => [document.activeElement.id, document.activeElement.selectionStart,
    document.activeElement.selectionEnd]), ["new", 0, 8]);
  await tab.cdp.send("Input.insertText", { text: "milk" });
  assert.equal(await tab.page.evaluate(() => window.state.draft), "milk", "the tracker saw it");
  await tab.close();
});

// ---------------------------------------------------------------- after an action

test("barrier: a task later — what a click queued with setTimeout(0) has run — and where the page stands", { skip }, async () => {
  const tab = await openTab("/todo");
  await append(tab.page, "<button id='later'>Later</button>");
  await tab.page.evaluate(() => {
    let clicks = 0;
    document.getElementById("later").addEventListener("click", () => {
      const count = ++clicks;
      setTimeout(() => { document.title = "Later " + count; }, 0);
    });
  });
  const { point } = await tab.helper("prepare", { target: "#later", action: "click", trusted: true });
  for (let round = 1; round <= 3; round++) {
    await tab.page.mouse.click(point.x, point.y);
    const facts = await tab.helper("barrier");
    assert.equal(facts.title, "Later " + round, "round " + round);
  }
  await tab.page.focus("#new");
  const facts = await tab.helper("barrier");
  assert.equal(facts.ok, true);
  assert.equal(facts.url, base + "/todo");
  assert.equal(facts.visibility, "visible");
  assert.equal(facts.focused, 'textbox "New todo"');
  assert.equal("checked" in facts, false, "no checkedOf: no checked");
  const box = await tab.helper("prepare", { target: "#terms", action: "click", trusted: true });
  await tab.page.mouse.click(box.point.x, box.point.y);
  assert.equal((await tab.helper("barrier", { checkedOf: "#terms" })).checked, true);
  assert.equal("checked" in (await tab.helper("barrier", { checkedOf: "e9999" })), false, "a ref gone: unknown");
  await tab.close();
});

test("snapshot afterFrame sees what a task and a frame render; without it, the walk is at once", { skip }, async () => {
  const tab = await openTab("/todo");
  // Scheduled and asked in one task of Loom's world: neither has run when the walk starts.
  const answer = JSON.parse(await tab.inWorld(`(async () => {
    requestAnimationFrame(() => { const b = document.createElement("button"); b.textContent = "From a frame"; document.body.append(b); });
    setTimeout(() => { const b = document.createElement("button"); b.textContent = "From a task"; document.body.append(b); }, 0);
    const now = JSON.parse(await globalThis.__loomAgent.run("snapshot", "{}"));
    const later = JSON.parse(await globalThis.__loomAgent.run("snapshot", JSON.stringify({ afterFrame: true })));
    return JSON.stringify({ now, later });
  })()`));
  assert.doesNotMatch(answer.now.yaml, /From a/);
  assert.equal(answer.now.focused, undefined, "the plain snapshot is WebKit's");
  assert.match(answer.later.yaml, /button "From a frame"/);
  assert.match(answer.later.yaml, /button "From a task"/);
  assert.equal(answer.later.ok, true);
  assert.equal(answer.later.visibility, "visible");
  assert.equal(typeof answer.later.focused, "string");
  await tab.close();
});

test("waitText with maxMs waits on the DOM: soon after the text comes, found:false at maxMs; without it, one shot", { skip }, async () => {
  const tab = await openTab("/todo");
  const after = (ms, script) => tab.page.evaluate(([delay, body]) => { setTimeout(new Function(body), delay); }, [ms, script]);

  await after(300, "const p = document.createElement('p'); p.textContent = 'Saved at last'; document.body.append(p);");
  let started = Date.now();
  let answer = await tab.helper("waitText", { text: "Saved at last", maxMs: 5000 });
  let took = Date.now() - started;
  assert.deepEqual(answer, { ok: true, found: true });
  assert.ok(took >= 200 && took < 2000, "seen when it came, not at maxMs: " + took + " ms");

  started = Date.now();
  answer = await tab.helper("waitText", { text: "Never there", maxMs: 300 });
  took = Date.now() - started;
  assert.deepEqual(answer, { ok: true, found: false });
  assert.ok(took >= 280 && took < 2000, "answered at maxMs: " + took + " ms");

  await after(200, "document.getElementById('card').remove();");
  answer = await tab.helper("waitText", { textGone: "Clickable card", maxMs: 5000 });
  assert.equal(answer.found, true, "gone");

  // Shown by an attribute, not a node: seen too.
  await append(tab.page, "<p id='hint' hidden>Shown by an attribute</p>");
  await after(200, "document.getElementById('hint').hidden = false;");
  answer = await tab.helper("waitText", { text: "Shown by an attribute", maxMs: 5000 });
  assert.equal(answer.found, true);

  // In a frame's own document, which no observer here sees: the slow check finds it.
  await addFrame(tab.page);
  await after(100, "document.getElementById('framed').contentDocument.body.append('Deep inside');");
  answer = await tab.helper("waitText", { text: "Deep inside", maxMs: 5000 });
  assert.equal(answer.found, true);

  started = Date.now();
  answer = await tab.helper("waitText", { text: "Not yet" });
  assert.deepEqual(answer, { ok: true, found: false }, "WebKit's single shot");
  assert.ok(Date.now() - started < 1000);
  assert.equal((await tab.helper("waitText", { maxMs: 100 })).error.code, "invalid");
  await tab.close();
});

// ---------------------------------------------------------------- screenshots, files

test("documentRect: the element's box in document coordinates, wherever the page is scrolled", { skip }, async () => {
  const tab = await openTab("/todo");
  await tab.page.evaluate(() => {
    const spacer = document.createElement("div");
    spacer.style.height = "4000px";
    document.body.append(spacer);
    const mark = document.createElement("div");
    mark.id = "mark";
    mark.style.cssText = "position:absolute; left:40px; top:1500px; width:120px; height:60px; background:teal";
    document.body.append(mark);
  });
  await tab.page.evaluate(() => window.scrollTo(0, 1200));
  let answer = await tab.helper("documentRect", { target: "#mark" });
  assert.deepEqual(answer.rect, { x: 40, y: 1500, width: 120, height: 60 });
  assert.deepEqual(answer.viewport, { x: 0, y: 1200, width: VIEWPORT.width, height: VIEWPORT.height });
  assert.equal(answer.description, "<div#mark>");
  // Out of view: scrolled to it, the box still the document's.
  await tab.page.evaluate(() => window.scrollTo(0, 3000));
  answer = await tab.helper("documentRect", { target: "#mark" });
  assert.deepEqual(answer.rect, { x: 40, y: 1500, width: 120, height: 60 });
  assert.ok(answer.viewport.y <= 1500 && answer.viewport.y + VIEWPORT.height >= 1560, JSON.stringify(answer.viewport));
  // In a frame: the frame's place in the document added.
  await tab.page.evaluate(() => window.scrollTo(0, 0));
  await addFrame(tab.page);
  await tab.page.evaluate(() => window.scrollTo(0, 150));
  const { yaml } = await tab.helper("snapshot", { budget: 20000 });
  answer = await tab.helper("documentRect", { target: refOf(yaml, /button "Inner"/) });
  assert.equal(answer.rect.x, 100 + 5 + 20);
  assert.equal(answer.rect.y, 200 + 5 + 10);
  assert.equal(answer.viewport.y, 150);
  await tab.close();
});

test("dispatchCancel: a cancelled chooser's cancel event, on a ref or selector or a stamp; only on a file input", { skip }, async () => {
  const tab = await openTab("/todo");
  await tab.page.evaluate(() => {
    document.getElementById("photo").addEventListener("cancel", (e) => window.events.push("cancel:" + e.bubbles));
    document.body.addEventListener("cancel", () => window.events.push("bubbled"));
  });
  assert.equal((await tab.helper("dispatchCancel", { target: "#photo" })).ok, true);
  const { nonce } = await tab.helper("stamp", { target: "#photo" });
  const answer = await tab.helper("dispatchCancel", { nonce });
  assert.equal(answer.ok, true, JSON.stringify(answer));
  assert.deepEqual(await tab.page.evaluate(() => window.events), ["cancel:true", "bubbled", "cancel:true", "bubbled"]);
  assert.equal(await tab.page.evaluate(() => document.querySelector("[data-loom-eval]")), null, "the stamp is gone");
  assert.equal((await tab.helper("dispatchCancel", { nonce })).error.code, "notFound");
  assert.equal((await tab.helper("dispatchCancel", { target: "#new" })).error.code, "invalid");
  await tab.close();
});

// ---------------------------------------------------------------- WebKit's side

test("WebKit's calls answer as before: prepare without trusted has no point and waits for no frame", { skip }, async () => {
  const tab = await openTab("/todo");
  const answer = await tab.helper("prepare", { target: "#card", action: "click" });
  assert.equal(answer.status, "ready");
  assert.deepEqual(Object.keys(answer).sort(), ["description", "ok", "rect", "status"]);
  await tab.close();
});
