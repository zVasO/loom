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
import { helperSource, pageHookSource, fixturesDirectory } from "./extract.mjs";

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
  // The page hook posts to webkit.messageHandlers; a stand-in collects.
  await page.addInitScript(() => {
    window.__posted = [];
    window.webkit = { messageHandlers: { loomAgent: { postMessage: (m) => window.__posted.push(m) } } };
  });
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
