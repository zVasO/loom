// The helper against a real DOM, in headless Chromium through Playwright —
// when Playwright is installed; skipped otherwise. Chromium is not WebKit:
// the WebKit-only parts (content worlds, dialogs, snapshots) are checked by
// Loom's own self-test on a Mac (`LOOM_AUTOTEST=agent-browser`). Here the
// helper runs in the page's world, which is stricter for the React-style
// input than WebKit's isolated world (see todo.html).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { helperSource, pageHookSource, relaySource, fixturesDirectory } from "./extract.mjs";

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

let browser;
let server;
let base;

before(async () => {
  if (skip) return;
  server = createServer((request, response) => {
    if (request.url === "/never-answers") {
      request.on("close", () => response.destroy());   // held open until the page goes
      return;
    }
    if (request.url === "/" || request.url.startsWith("/todo")) {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(readFileSync(resolve(fixturesDirectory, "todo.html")));
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

async function openTodo() {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  // The relay posts to webkit.messageHandlers; a stand-in collects. (In
  // WebKit the relay and the handler live in Loom's world, the hook in the
  // page's; Chromium here runs all three in one.)
  await page.addInitScript(() => {
    window.__posted = [];
    window.webkit = { messageHandlers: { loomAgent: { postMessage: (m) => window.__posted.push(m) } } };
  });
  await page.addInitScript(relaySource());
  await page.addInitScript(pageHookSource());
  await page.addInitScript(helperSource());
  await page.goto(base + "/todo");
  return page;
}

const run = (page, op, args = {}) =>
  page.evaluate(([o, a]) => globalThis.__loomAgent.run(o, a), [op, JSON.stringify(args)]).then(JSON.parse);

const refOf = (yaml, pattern) => {
  const line = yaml.split("\n").find((l) => pattern.test(l));
  assert.ok(line, "no line matches " + pattern + " in:\n" + yaml);
  return /\[ref=(e\d+)\]/.exec(line)[1];
};

test("the snapshot names roles the way an accessibility tree does", { skip }, async () => {
  const page = await openTodo();
  const { yaml } = await run(page, "snapshot", { budget: 20000 });
  assert.match(yaml, /- heading "Todos" \[level=1\] \[ref=e\d+\]/);
  assert.match(yaml, /- textbox "New todo" \[ref=e\d+\]:?/);
  assert.match(yaml, /\/placeholder: What needs to be done\?/);
  assert.match(yaml, /- button "Add" \[ref=e\d+\]/);
  assert.match(yaml, /- link "Docs" \[ref=e\d+\]( \[cursor=pointer\])?:\n\s+- \/url: "#docs"/);
  assert.match(yaml, /- combobox "Color" \[ref=e\d+\]:\n\s+- option "Red" \[selected\]\n\s+- option "Green"/);
  assert.match(yaml, /- paragraph \[ref=e\d+\]: "Count: 0"/);
  const order = [...yaml.matchAll(/\[ref=e(\d+)\]/g)].map((m) => Number(m[1]));
  assert.deepEqual(order, [...order].sort((a, b) => a - b), "refs read in document order");
  assert.match(yaml, /- generic \[ref=e\d+\] \[cursor=pointer\]: Clickable card/);
  assert.match(yaml, /- navigation \[ref=e\d+\]:/);
  await page.close();
});

test("refs are stable across snapshots, and only the latest snapshot's resolve", { skip }, async () => {
  const page = await openTodo();
  const first = (await run(page, "snapshot", {})).yaml;
  const second = (await run(page, "snapshot", {})).yaml;
  assert.equal(refOf(first, /button "Add"/), refOf(second, /button "Add"/));
  const missing = await run(page, "click", { target: "e9999" });
  assert.equal(missing.error.code, "notFound");
  assert.match(missing.error.message, /Ref e9999 not found in the current page snapshot/);
  await page.close();
});

test("typing reaches a framework-controlled input, Enter submits through the form", { skip }, async () => {
  const page = await openTodo();
  const { yaml } = await run(page, "snapshot", {});
  const field = refOf(yaml, /textbox "New todo"/);
  assert.equal((await run(page, "prepare", { target: field, action: "type" })).status, "ready");
  const typed = await run(page, "type", { target: field, text: "milk", submit: true });
  assert.equal(typed.ok, true);
  const state = await page.evaluate(() => ({ todos: window.state.todos, events: window.events }));
  assert.deepEqual(state.todos.map((t) => t.text), ["milk"], "the tracker saw the value, the form submitted");
  assert.ok(state.events.includes("keydown:Enter:13"), "legacy keyCode reaches page listeners");
  await page.close();
});

test("a click toggles a checkbox and fires its change handler", { skip }, async () => {
  const page = await openTodo();
  let { yaml } = await run(page, "snapshot", {});
  await run(page, "type", { target: refOf(yaml, /textbox "New todo"/), text: "eggs", submit: true });
  ({ yaml } = await run(page, "snapshot", {}));
  const box = refOf(yaml, /checkbox "eggs"/);
  assert.equal((await run(page, "prepare", { target: box, action: "click" })).status, "ready");
  await run(page, "click", { target: box });
  const events = await page.evaluate(() => window.events);
  assert.ok(events.includes("toggle:eggs"));
  ({ yaml } = await run(page, "snapshot", {}));
  assert.match(yaml, /checkbox "eggs" \[checked\]/);
  await page.close();
});

test("something covering the target is named, not clicked through", { skip }, async () => {
  const page = await openTodo();
  const { yaml } = await run(page, "snapshot", {});
  await run(page, "click", { target: refOf(yaml, /button "Cover the page"/) });
  const blocked = await run(page, "prepare", { target: refOf(yaml, /button "Add"/), action: "click" });
  assert.equal(blocked.status, "retry");
  assert.match(blocked.reason, /<div#overlay(\.\w+)*> intercepts pointer events/);
  await page.close();
});

test("a dialog opened by a click does not wedge the helper call", { skip }, async () => {
  const page = await openTodo();
  const seen = [];
  page.on("dialog", async (dialog) => { seen.push(dialog.message()); await dialog.dismiss(); });
  const { yaml } = await run(page, "snapshot", {});
  const answer = await run(page, "click", { target: refOf(yaml, /button "Clear done"/) });
  assert.equal(answer.ok, true);
  assert.deepEqual(seen, ["Clear the done todos?"]);
  assert.ok((await page.evaluate(() => window.events)).includes("kept"));
  await page.close();
});

test("Tab moves focus forward, Shift+Tab back", { skip }, async () => {
  const page = await openTodo();
  await page.evaluate(() => document.getElementById("new").focus());
  await run(page, "pressKey", { key: "Tab", code: "Tab", keyCode: 9 });
  assert.equal(await page.evaluate(() => document.activeElement.textContent), "Add");
  await run(page, "pressKey", { key: "Tab", code: "Tab", keyCode: 9, shiftKey: true });
  assert.equal(await page.evaluate(() => document.activeElement.id), "new");
  await page.close();
});

test("a select takes an option by value or by label", { skip }, async () => {
  const page = await openTodo();
  const { yaml } = await run(page, "snapshot", {});
  const select = refOf(yaml, /combobox "Color"/);
  assert.equal((await run(page, "selectOption", { target: select, values: ["Blue"] })).ok, true);
  assert.equal((await run(page, "selectOption", { target: select, values: ["g"] })).ok, true);
  assert.deepEqual(await page.evaluate(() => window.events), ["color:b", "color:g"]);
  const wrong = await run(page, "selectOption", { target: select, values: ["Purple"] });
  assert.equal(wrong.error.code, "optionNotFound");
  await page.close();
});

test("waiting for text answers in one shot; the page hook reports console and requests", { skip }, async () => {
  const page = await openTodo();
  const { yaml } = await run(page, "snapshot", {});
  assert.equal((await run(page, "waitText", { text: "Clickable card" })).found, true);
  assert.equal((await run(page, "waitText", { textGone: "Clickable card" })).found, false);
  await run(page, "click", { target: refOf(yaml, /button "Log an error"/) });
  await run(page, "click", { target: refOf(yaml, /button "Load remote"/) });
  await page.waitForFunction(() => document.getElementById("status").textContent !== "");
  await page.waitForTimeout(50);
  const posted = await page.evaluate(() => window.__posted);
  const errors = posted.filter((m) => m.t === "console" && m.level === "error").map((m) => m.text);
  assert.ok(errors.some((t) => t.startsWith("Something broke {\"code\":42}")), JSON.stringify(errors));
  assert.ok(errors.some((t) => /uncaught in timer/.test(t)), JSON.stringify(errors));
  const request = posted.find((m) => m.t === "req" && /missing\.json$/.test(m.url));
  assert.ok(request, "the fetch was reported");
  const response = posted.find((m) => m.t === "res" && m.id === request.id);
  assert.equal(response.status, 404);
  await page.close();
});

test("the relay: bounded, rate-limited, and a response always follows its request", { skip }, async () => {
  const page = await openTodo();
  const posted = await page.evaluate(async () => {
    window.__posted.length = 0;
    const fire = (detail) => document.dispatchEvent(new CustomEvent("loom-agent-hook", { detail }));
    fire({ t: "console", level: "info", text: "an object, not a string" });
    fire(JSON.stringify({ t: "console", level: "info", text: "x".repeat(5000) }));
    fire("not json");
    fire(JSON.stringify({ t: "res", id: 77, status: 200 }));          // no request: dropped
    const id = 4242;
    fire(JSON.stringify({ t: "req", id, kind: "fetch", method: "GET", url: "http://x/slow" }));
    for (let i = 0; i < 1000; i++) fire(JSON.stringify({ t: "console", level: "info", text: "spam " + i }));
    fire(JSON.stringify({ t: "res", id, status: 204 }));               // past the bucket: kept
    fire(JSON.stringify({ t: "res", id, status: 204 }));               // twice: once only
    return window.__posted.slice();
  });
  assert.ok(!posted.some((m) => m.text === "an object, not a string"), "only strings cross");
  assert.ok(!posted.some((m) => typeof m.text === "string" && m.text.length > 4096), "oversized detail dropped");
  assert.ok(!posted.some((m) => m.t === "res" && m.id === 77), "a response without its request is dropped");
  const spam = posted.filter((m) => m.t === "console").length;
  assert.ok(spam < 260, "the flood is cut near 200: " + spam);
  assert.equal(posted.filter((m) => m.t === "res" && m.id === 4242).length, 1, "the response passed, once");
  await page.close();
});

test("request ids are unique per document; a leaving document abandons what it had in flight", { skip }, async () => {
  const page = await openTodo();
  const ids = await page.evaluate(async () => {
    window.__posted.length = 0;
    await fetch("/missing-a.json");
    await fetch("/missing-b.json");
    return window.__posted.filter((m) => m.t === "req").map((m) => m.id);
  });
  assert.equal(ids.length, 2);
  assert.ok(ids[0] > 2 ** 20, "a random per-document base, not 1: " + ids[0]);
  assert.equal(ids[1], ids[0] + 1);
  const abandoned = await page.evaluate(async () => {
    window.__posted.length = 0;
    fetch("/never-answers").catch(() => {});
    await new Promise((done) => setTimeout(done, 20));
    window.dispatchEvent(new PageTransitionEvent("pagehide"));
    return window.__posted.filter((m) => m.t === "res").map((m) => m.error);
  });
  assert.ok(abandoned.includes("abandoned by navigation"), JSON.stringify(abandoned));
  await page.close();
});

test("an element's box inside a same-origin frame is in the top viewport's coordinates", { skip }, async () => {
  const page = await openTodo();
  await page.evaluate(() => new Promise((done) => {
    const frame = document.createElement("iframe");
    frame.style.cssText = "position:absolute; left:100px; top:200px; width:300px; height:150px; border:5px solid red";
    frame.srcdoc = "<body style='margin:0'><button style='margin:10px 20px'>Inner</button></body>";
    frame.onload = done;
    document.body.prepend(frame);
  }));
  const yaml = (await run(page, "snapshot", { budget: 20000 })).yaml;
  const inner = refOf(yaml, /button "Inner"/);
  const answer = await run(page, "rect", { target: inner });
  assert.equal(answer.ok, true, JSON.stringify(answer));
  assert.equal(answer.rect.x, 100 + 5 + 20 - (await page.evaluate(() => window.scrollX)));
  assert.equal(answer.rect.y, 200 + 5 + 10 - (await page.evaluate(() => window.scrollY)));
  await page.close();
});

test("a full-page capture scrolls the top document at once, and reads where it was", { skip }, async () => {
  const page = await openTodo();
  await page.evaluate(() => {
    document.documentElement.style.scrollBehavior = "smooth";   // a page's own: not ours
    const tall = document.createElement("div");
    tall.style.height = "3000px";
    document.body.append(tall);
  });
  const before = await run(page, "pageInfo");
  assert.equal(before.scrollY, 0);
  assert.ok(before.scrollHeight >= 3000, "the page's whole height: " + before.scrollHeight);
  const moved = await run(page, "scrollTo", { x: 0, y: 1200 });
  assert.equal(moved.y, 1200, "instant, despite smooth scrolling");
  const clamped = await run(page, "scrollTo", { x: 0, y: 99999 });
  assert.equal(clamped.y, before.scrollHeight - before.height, "the last slice starts where the page lets it");
  await page.close();
});

test("a custom checkbox re-rendered by its framework a turn later reads as set", { skip }, async () => {
  const page = await openTodo();
  await page.evaluate(() => {
    const box = document.createElement("div");
    box.setAttribute("role", "checkbox");
    box.setAttribute("aria-checked", "false");
    box.setAttribute("aria-label", "Newsletter");
    box.tabIndex = 0;
    box.textContent = "Newsletter";
    let on = false;
    // As Vue or Lit do: the state now, the DOM in a microtask.
    box.addEventListener("click", () => { on = !on; queueMicrotask(() => box.setAttribute("aria-checked", String(on))); });
    document.body.prepend(box);
  });
  const { yaml } = await run(page, "snapshot", { budget: 20000 });
  const answer = await run(page, "setChecked", { target: refOf(yaml, /checkbox "Newsletter"/), checked: true });
  assert.equal(answer.checked, true, JSON.stringify(answer));
  await page.close();
});

test("a page whose body scrolls itself is as tall as its window, for a full-page capture", { skip }, async () => {
  const page = await openTodo();
  await page.evaluate(() => {
    document.documentElement.style.cssText = "overflow:hidden;height:100%";
    document.body.style.cssText = "height:100%;overflow:auto;margin:0";
    const tall = document.createElement("div");
    tall.style.height = "5000px";
    document.body.append(tall);
  });
  const info = await run(page, "pageInfo");
  assert.equal(info.scrollHeight, info.height, "what window.scrollTo can reach");
  await page.close();
});

test("a frame of another origin gets a tenth of the page's relay budget; the page's own frames, all of it", { skip }, async () => {
  const page = await openTodo();
  const flood = (count) => {
    for (let i = 0; i < count; i++) {
      document.dispatchEvent(new CustomEvent("loom-agent-hook",
        { detail: JSON.stringify({ t: "console", level: "info", text: "f" + i }) }));
    }
    return window.__posted.filter((m) => m.t === "console").length;
  };
  await page.evaluate(() => new Promise((done) => {
    const own = document.createElement("iframe");
    own.srcdoc = "<p>own</p>";
    own.onload = done;
    document.body.append(own);
  }));
  const ownFrame = page.frames().find((f) => f !== page.mainFrame() && f.url() === "about:srcdoc");
  assert.ok(ownFrame, "the page's own frame");
  const own = await ownFrame.evaluate(flood, 300);
  assert.ok(own >= 150, "a same-origin frame is the page's: " + own);
  const other = base.replace("127.0.0.1", "localhost") + "/todo";
  await page.evaluate((src) => new Promise((done) => {
    const frame = document.createElement("iframe");
    frame.src = src;
    frame.onload = done;
    document.body.append(frame);
  }), other);
  const otherFrame = page.frames().find((f) => f.url().startsWith(base.replace("127.0.0.1", "localhost")));
  assert.ok(otherFrame, "the other origin's frame");
  const foreign = await otherFrame.evaluate(flood, 300);
  assert.ok(foreign > 0 && foreign <= 25, "about 20 from another origin: " + foreign);
  await page.close();
});

test("a stamped element is found by the page-world function, then unmarked", { skip }, async () => {
  const page = await openTodo();
  const { yaml } = await run(page, "snapshot", {});
  const { nonce } = await run(page, "stamp", { target: refOf(yaml, /button "Add"/) });
  const text = await page.evaluate((n) => {
    const el = document.querySelector('[data-loom-eval="' + n + '"]');
    el.removeAttribute("data-loom-eval");
    return el.textContent;
  }, nonce);
  assert.equal(text, "Add");
  await page.close();
});

test("form fields: a checkbox to a state, a slider to a value, keys one by one", { skip }, async () => {
  const page = await openTodo();
  const { yaml } = await run(page, "snapshot", {});
  const terms = refOf(yaml, /checkbox "I agree"/);
  assert.equal((await run(page, "setChecked", { target: terms, checked: true })).checked, true);
  assert.equal((await run(page, "setChecked", { target: terms, checked: true })).checked, true, "already: untouched");
  await run(page, "setValue", { target: refOf(yaml, /slider "Volume"/), value: "7" });
  const field = refOf(yaml, /textbox "New todo"/);
  await run(page, "focusField", { target: field, clear: true });
  await run(page, "typeKeys", { keys: [..."tea"].map((c) => ({ key: c, code: "Key" + c.toUpperCase(), keyCode: c.toUpperCase().charCodeAt(0), text: c })) });
  const state = await page.evaluate(() => ({ events: window.events, draft: window.state.draft }));
  assert.deepEqual(state.events.filter((e) => /^(terms|volume)/.test(e)), ["terms:true", "volume:7"]);
  assert.equal(state.draft, "tea", "each key typed its character");
  await page.close();
});
