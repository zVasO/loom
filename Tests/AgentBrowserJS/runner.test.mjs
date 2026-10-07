// browser_run_code's facade (AgentRunnerScript.facade, run-code design §2,
// §3) in a Node vm, with a fake Loom on the other side of the bridge: the
// binding __loomRunCall records each call, answers go back through
// __loomRunAnswer. No browser needed — except the last tests, which run the
// facade in a real Chromium isolated world (binding, sourceURL lines, a
// SyntaxError's line) and compare locator descriptions with Playwright's
// own toString, when Playwright is installed.
import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot, serializerSource, helperSource } from "./extract.mjs";

// ---------------------------------------------------------------- the Swift side, read

const swift = readFileSync(resolve(repoRoot, "Sources/LoomWeb/AgentBrowser/AgentRunnerScript.swift"), "utf8");

function literal(name) {
  const match = new RegExp(`public static let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`).exec(swift);
  if (!match) throw new Error(`AgentRunnerScript.${name} not found — it must stay a #""" raw string at column 0`);
  return match[1];
}

function constant(name) {
  const match = new RegExp(`public static let ${name} = "((?:[^"\\\\]|\\\\.)*)"`).exec(swift);
  if (!match) throw new Error(`AgentRunnerScript.${name} not found`);
  return JSON.parse(`"${match[1]}"`);
}

const FACADE = literal("facade");
const SOURCE_URL = constant("sourceURL");
const ENTRY_HEAD = constant("entryHead");
const BODY_HEAD = constant("bodyHead");
const BODY_TAIL = constant("bodyTail");
const ENTRY_TAIL = "))\n//# sourceURL=" + SOURCE_URL;
const ANSWER_FUNCTION = constant("answerFunction");

/** AgentScripts.isFunction, as Swift has it. */
function isFunction(text) {
  if (text.startsWith("function") || text.startsWith("async ") || text.startsWith("async(")) return true;
  return /^(\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*=>/.test(text);
}

/** AgentRunnerScript.skippingLeadingComments, as Swift has it. */
function skippingLeadingComments(code) {
  let rest = code;
  for (;;) {
    rest = rest.replace(/^\s+/, "");
    if (rest.startsWith("//")) {
      const newline = rest.search(/[\n\r\u2028\u2029]/);
      if (newline < 0) return "";
      rest = rest.slice(newline);
    } else if (rest.startsWith("/*")) {
      const end = rest.indexOf("*/");
      if (end < 0) return rest;
      rest = rest.slice(end + 2);
    } else {
      return rest;
    }
  }
}

/** AgentRunnerScript.entry(code:), as Swift has it. */
function entry(code) {
  if (isFunction(skippingLeadingComments(code).trim())) return ENTRY_HEAD + "\n" + code.replace(/[;\s]+$/, "") + "\n" + ENTRY_TAIL;
  return ENTRY_HEAD + BODY_HEAD + "\n" + code + "\n" + BODY_TAIL + ENTRY_TAIL;
}

/** ChromiumRunner.installExpression: the facade, then its start. */
const install = (config) => FACADE + "\n;globalThis.__loomRun.start(" + JSON.stringify(config) + ");\n//# sourceURL=loom-runner.js";

const plain = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("entry's pieces are the ones these tests rebuild", () => {
  assert.ok(swift.includes('public static let entryTail = "))\\n//# sourceURL=" + sourceURL'));
  assert.ok(swift.includes("while let last = body.last, last == \";\" || last.isWhitespace"));
  assert.equal(SOURCE_URL, "browser_run_code.js");
  assert.equal(constant("bindingName"), "__loomRunCall");
  assert.equal(constant("answerName"), "__loomRunAnswer");
  assert.equal(entry("async (page) => 1;\n"), "globalThis.__loomRun.run((\nasync (page) => 1\n))\n//# sourceURL=browser_run_code.js");
  assert.equal(entry("return 1"), "globalThis.__loomRun.run((async (page) => {\nreturn 1\n}))\n//# sourceURL=browser_run_code.js");
  assert.ok(swift.includes("let trimmed = String(skippingLeadingComments(code)).trimmingCharacters(in: .whitespacesAndNewlines)"));
  assert.ok(entry("// fill the form\n/* then */ async (page) => 1").startsWith(ENTRY_HEAD + "\n// fill"), "a comment above a function");
});

// ---------------------------------------------------------------- a fake Loom

/**
 * The facade in a fresh context. `handlers[op](message, loom)` answers a
 * call (or holds it); without one, a call is answered `{ok: true}` on the
 * next turn. `loom.posts` holds every call, parsed.
 */
function runner({ config = {}, handlers = {}, globals = {} } = {}) {
  const posts = [];
  const context = vm.createContext({ setTimeout, clearTimeout, URL, ...globals });
  const loom = {
    posts,
    context,
    ops: () => posts.map((m) => m.op),
    send(object) { return context.__loomRunAnswer(JSON.stringify(object)); },
    ok(message, value, extra = {}) { return loom.send({ id: message.id, ok: true, value, ...extra }); },
    fail(message, error, extra = {}) { return loom.send({ id: message.id, ok: false, error, ...extra }); },
    /** The agent's code, as Loom runs it → the run's answer, as plain JSON. */
    run(code) { return vm.runInContext(entry(code), context, { filename: "evaluate.js" }).then(plain); },
    eval(code) { return vm.runInContext(code, context); },
  };
  context.__loomRunCall = (payload) => {
    assert.equal(typeof payload, "string");
    const message = JSON.parse(payload);
    posts.push(message);
    const handler = handlers[message.op];
    setImmediate(() => {
      if (handler) handler(message, loom);
      else loom.ok(message);
    });
  };
  vm.runInContext(install({ url: "http://localhost:5173/", viewport: { width: 1280, height: 800 }, ...config }), context);
  return loom;
}

/** A runner whose `page` is kept in globalThis.page, for the builders (they need no run). */
async function builders() {
  const loom = runner();
  await loom.run("async (page) => { globalThis.page = page; }");
  return loom;
}

/** A call's message without its remaining-time field, which moves with the clock. */
function shape(message) {
  const copy = plain(message);
  if (copy.args && "timeout" in copy.args) {
    assert.ok(copy.args.timeout >= 0 && copy.args.timeout <= 60000, `timeout ${copy.args.timeout}`);
    copy.args.timeout = "T";
  }
  return copy;
}

// ---------------------------------------------------------------- messages

test("a locator's click posts the design's message: target chain, desc, strict, every click option", async () => {
  const loom = runner();
  const result = await loom.run(`async (page) => {
  await page.getByRole('button', { name: 'Save' }).click();
}`);
  assert.deepEqual(result, { ok: true, logs: [], logsDropped: 0, unfinished: [], steps: 1 });
  assert.equal(loom.posts.length, 1);
  const message = loom.posts[0];
  assert.ok(message.args.timeout > 4900 && message.args.timeout <= 5000, "what is left of the 5 s default");
  assert.deepEqual(shape(message), {
    id: 1, op: "click", api: "locator.click", step: 1, line: 2,
    target: { chain: [{ role: "button", name: { s: "Save", m: "ci" } }], desc: "getByRole('button', { name: 'Save' })", strict: true },
    args: { button: "left", clickCount: 1, modifiers: [], position: null, force: false, trial: false, delay: 0, timeout: "T" },
  });
});

test("page.<action>(selector) is not strict unless asked; the selector is one step the helper parses", async () => {
  const loom = runner();
  await loom.run(`async (page) => {
  await page.click('#a');
  await page.click('text=Save >> nth=1', { strict: true, button: 'right', modifiers: ['Shift'], position: { x: 1, y: 2 } });
  await page.fill('input[name=q]', 'milk', { strict: false });
}`);
  assert.deepEqual(loom.posts.map(shape), [
    { id: 1, op: "click", api: "page.click", step: 1, line: 2,
      target: { chain: [{ selector: "#a" }], desc: "locator('#a')", strict: false },
      args: { button: "left", clickCount: 1, modifiers: [], position: null, force: false, trial: false, delay: 0, timeout: "T" } },
    { id: 2, op: "click", api: "page.click", step: 2, line: 3,
      target: { chain: [{ selector: "text=Save >> nth=1" }], desc: "locator('text=Save >> nth=1')", strict: true },
      args: { button: "right", clickCount: 1, modifiers: ["Shift"], position: { x: 1, y: 2 }, force: false, trial: false, delay: 0, timeout: "T" } },
    { id: 3, op: "fill", api: "page.fill", step: 3, line: 4,
      target: { chain: [{ selector: "input[name=q]" }], desc: "locator('input[name=q]')", strict: false },
      args: { value: "milk", force: false, timeout: "T" } },
  ]);
});

// What the helper receives (design §4.1), built by the facade — never a string to parse — and
// Playwright's own toString (checked against real Playwright at the end of this file).
const CHAINS = [
  ["page.getByRole('heading', { level: 2 })", [{ role: "heading", level: 2 }], "getByRole('heading', { level: 2 })"],
  ["page.getByRole('checkbox', { checked: 'mixed', includeHidden: true, disabled: false })",
    [{ role: "checkbox", checked: "mixed", disabled: false, includeHidden: true }],
    "getByRole('checkbox', { checked: 'mixed', disabled: false, includeHidden: true })"],
  ["page.getByRole('checkbox', { checked: true, disabled: false, includeHidden: true, expanded: false, pressed: 'mixed', selected: true })",
    [{ role: "checkbox", checked: true, disabled: false, selected: true, expanded: false, includeHidden: true, pressed: "mixed" }],
    "getByRole('checkbox', { checked: true, disabled: false, selected: true, expanded: false, includeHidden: true, pressed: 'mixed' })"],
  ["page.getByRole('button', { name: 'Save', exact: true, pressed: true })",
    [{ role: "button", name: { s: "Save", m: "eq" }, pressed: true }], "getByRole('button', { name: 'Save', exact: true, pressed: true })"],
  ["page.getByRole('button', { name: /sa.e/gi })", [{ role: "button", name: { re: "sa.e", f: "i" } }], "getByRole('button', { name: /sa.e/gi })"],
  ["page.getByText('Hello')", [{ text: { s: "Hello", m: "ci" } }], "getByText('Hello')"],
  ["page.getByText('Hello', { exact: true })", [{ text: { s: "Hello", m: "eq" } }], "getByText('Hello', { exact: true })"],
  ["page.getByText(/hel+o/gim)", [{ text: { re: "hel+o", f: "im" } }], "getByText(/hel+o/gim)"],
  // Playwright prints a text body's RegExp with flags beyond i, g, m as a string; an attribute's, as a RegExp.
  ["page.getByText(/hel+o/iy)", [{ text: { re: "hel+o", f: "i" } }], "getByText('/hel+o/iy')"],
  ["page.getByLabel(/a/u)", [{ label: { re: "a", f: "u" } }], "getByLabel('/a/u')"],
  ["page.locator('b').filter({ hasText: /a/s })", [{ selector: "b" }, { hasText: { re: "a", f: "s" } }], "locator('b').filter({ hasText: '/a/s' })"],
  ["page.locator('b').filter({ hasNotText: /a/y })", [{ selector: "b" }, { hasText: { re: "a", f: "" }, not: true }],
    "locator('b').filter({ hasNotText: '/a/y' })"],
  ["page.getByPlaceholder(/a/s)", [{ placeholder: { re: "a", f: "s" } }], "getByPlaceholder(/a/s)"],
  ["page.getByAltText(/a/y)", [{ alt: { re: "a", f: "" } }], "getByAltText(/a/y)"],
  ["page.getByTitle(/a/s)", [{ title: { re: "a", f: "s" } }], "getByTitle(/a/s)"],
  ["page.getByTestId(/a/s)", [{ testId: { re: "a", f: "s" } }], "getByTestId(/a/s)"],
  ["page.getByRole('button', { name: /a/s })", [{ role: "button", name: { re: "a", f: "s" } }], "getByRole('button', { name: /a/s })"],
  ["page.getByText(/it's \"q\"/)", [{ text: { re: "it's \"q\"", f: "" } }], "getByText(/it's \"q\"/)"],
  ["page.getByText(/a\\/b/)", [{ text: { re: "a\\/b", f: "" } }], "getByText(/a\\/b/)"],
  ["page.getByText(/it's/)", [{ text: { re: "it's", f: "" } }], "getByText(/it's/)"],
  ["page.getByLabel('Email')", [{ label: { s: "Email", m: "ci" } }], "getByLabel('Email')"],
  ["page.getByLabel('Email', { exact: true })", [{ label: { s: "Email", m: "eq" } }], "getByLabel('Email', { exact: true })"],
  ["page.getByPlaceholder('Search', { exact: true })", [{ placeholder: { s: "Search", m: "eq" } }], "getByPlaceholder('Search', { exact: true })"],
  ["page.getByAltText('Logo')", [{ alt: { s: "Logo", m: "ci" } }], "getByAltText('Logo')"],
  ["page.getByTitle('Tip')", [{ title: { s: "Tip", m: "ci" } }], "getByTitle('Tip')"],
  ["page.getByTestId('x')", [{ testId: { s: "x", m: "eq" } }], "getByTestId('x')"],
  ["page.getByTestId(/x-\\d/)", [{ testId: { re: "x-\\d", f: "" } }], "getByTestId(/x-\\d/)"],
  ["page.locator('#a')", [{ selector: "#a" }], "locator('#a')"],
  ["page.locator('text=Save')", [{ selector: "text=Save" }], "locator('text=Save')"],
  ["page.locator('ul').getByText('Eggs')", [{ selector: "ul" }, { text: { s: "Eggs", m: "ci" } }], "locator('ul').getByText('Eggs')"],
  ["page.locator('ul').locator('li')", [{ selector: "ul" }, { selector: "li" }], "locator('ul').locator('li')"],
  ["page.locator('ul').locator(page.getByRole('button'))", [{ selector: "ul" }, { role: "button" }], "locator('ul').locator(getByRole('button'))"],
  ["page.getByText('x').locator('..')", [{ text: { s: "x", m: "ci" } }, { selector: ".." }], "getByText('x').locator('..')"],
  ["page.getByRole('listitem').filter({ hasText: 'Milk' }).getByRole('button')",
    [{ role: "listitem" }, { hasText: { s: "Milk", m: "ci" } }, { role: "button" }],
    "getByRole('listitem').filter({ hasText: 'Milk' }).getByRole('button')"],
  ["page.getByRole('listitem').filter({ hasNotText: /Milk/ })", [{ role: "listitem" }, { hasText: { re: "Milk", f: "" }, not: true }],
    "getByRole('listitem').filter({ hasNotText: /Milk/ })"],
  ["page.getByRole('listitem').filter({ has: page.getByRole('checkbox', { checked: true }) })",
    [{ role: "listitem" }, { has: { chain: [{ role: "checkbox", checked: true }], desc: "getByRole('checkbox', { checked: true })" } }],
    "getByRole('listitem').filter({ has: getByRole('checkbox', { checked: true }) })"],
  ["page.getByRole('listitem').filter({ hasNot: page.getByText('x') })",
    [{ role: "listitem" }, { has: { chain: [{ text: { s: "x", m: "ci" } }], desc: "getByText('x')" }, not: true }],
    "getByRole('listitem').filter({ hasNot: getByText('x') })"],
  ["page.getByRole('listitem').filter({ visible: true })", [{ role: "listitem" }, { visible: true }], "getByRole('listitem').filter({ visible: true })"],
  ["page.getByRole('listitem').filter({ visible: false })", [{ role: "listitem" }, { visible: false }], "getByRole('listitem').filter({ visible: false })"],
  ["page.locator('div', { hasText: 'x', has: page.locator('b') })",
    [{ selector: "div" }, { hasText: { s: "x", m: "ci" } }, { has: { chain: [{ selector: "b" }], desc: "locator('b')" } }],
    "locator('div').filter({ hasText: 'x' }).filter({ has: locator('b') })"],
  ["page.locator('.a').filter({ hasText: 'x' }).filter({ hasText: 'y' })",
    [{ selector: ".a" }, { hasText: { s: "x", m: "ci" } }, { hasText: { s: "y", m: "ci" } }],
    "locator('.a').filter({ hasText: 'x' }).filter({ hasText: 'y' })"],
  ["page.getByRole('button').nth(1)", [{ role: "button" }, { nth: 1 }], "getByRole('button').nth(1)"],
  ["page.getByRole('button').nth(-2)", [{ role: "button" }, { nth: -2 }], "getByRole('button').nth(-2)"],
  ["page.getByRole('button').first()", [{ role: "button" }, { nth: 0 }], "getByRole('button').first()"],
  ["page.getByRole('button').last()", [{ role: "button" }, { nth: -1 }], "getByRole('button').last()"],
  ["page.getByRole('button').and(page.getByTitle('Save'))",
    [{ role: "button" }, { and: { chain: [{ title: { s: "Save", m: "ci" } }], desc: "getByTitle('Save')" } }],
    "getByRole('button').and(getByTitle('Save'))"],
  ["page.getByRole('button').or(page.getByRole('link'))",
    [{ role: "button" }, { or: { chain: [{ role: "link" }], desc: "getByRole('link')" } }], "getByRole('button').or(getByRole('link'))"],
  ["page.getByRole('button').describe('Save button')", [{ role: "button" }], "getByRole('button')"],
  ["page.getByText(\"it's\")", [{ text: { s: "it's", m: "ci" } }], "getByText('it\\'s')"],
  ["page.getByText('say \"hi\"')", [{ text: { s: "say \"hi\"", m: "ci" } }], "getByText('say \"hi\"')"],
  ["page.getByRole('button', { name: 'it\\'s' })", [{ role: "button", name: { s: "it's", m: "ci" } }], "getByRole('button', { name: 'it\\'s' })"],
  ["page.getByRole('button', { name: 'a\\nb' })", [{ role: "button", name: { s: "a\nb", m: "ci" } }], "getByRole('button', { name: 'a\\nb' })"],
  ["page.locator('aria-ref=e12')", [{ selector: "aria-ref=e12" }], "locator('aria-ref=e12')"],
];

test("locators build the helper's steps (structured, never strings) and Playwright's descriptions", async () => {
  const loom = await builders();
  for (const [expression, chain, desc] of CHAINS) {
    assert.deepEqual(plain(loom.eval(`(${expression})._target()`)), { chain, desc, strict: true }, expression);
    assert.equal(loom.eval(`String(${expression})`), desc, expression);
    assert.equal(loom.eval(`JSON.stringify(${expression})`), JSON.stringify("locator: " + desc), expression);
  }
  assert.equal(loom.posts.length, 0, "building a locator posts nothing");
});

test("a builder's bad argument throws at once", async () => {
  const loom = await builders();
  for (const [expression, pattern] of [
    ["page.getByText(42)", /getByText: text must be a string or a RegExp, not number/],
    ["page.getByRole('')", /getByRole: role must be a non-empty string/],
    ["page.locator('')", /page.locator: selector must be a non-empty string/],
    ["page.getByRole('button').nth(1.5)", /locator.nth: index must be an integer/],
    ["page.getByRole('button').filter({ has: 'x' })", /locator.filter: has must be a locator/],
    ["page.getByRole('button').and({})", /locator.and must be a locator/],
    ["page.getByRole('button', 'Save')", /getByRole: options must be an object, not string/],
  ]) {
    assert.throws(() => loom.eval(expression), (error) => error.name === "TypeError" && pattern.test(error.message), expression);
  }
});

// Every member of design §2.1 → its op, lane and args (§3.2): the bridge's shapes, pinned.
const MEMBERS = [
  ["page.goto('/docs')", "goto", { url: "/docs", waitUntil: "load", timeout: "T" }],
  ["page.goto('http://x/', { waitUntil: 'commit', timeout: 1000 })", "goto", { url: "http://x/", waitUntil: "commit", timeout: "T" }],
  ["page.goBack()", "history", { delta: -1, waitUntil: "load", timeout: "T" }],
  ["page.goForward({ waitUntil: 'domcontentloaded' })", "history", { delta: 1, waitUntil: "domcontentloaded", timeout: "T" }],
  ["page.reload()", "history", { delta: 0, waitUntil: "load", timeout: "T" }],
  ["page.title()", "title", {}],
  ["page.content()", "content", {}],
  ["page.dblclick('#a', { delay: 10 })", "click", { button: "left", clickCount: 2, modifiers: [], position: null, force: false, trial: false, delay: 10, timeout: "T" }],
  ["page.hover('#a', { force: true })", "hover", { position: null, modifiers: [], force: true, trial: false, timeout: "T" }],
  ["page.type('#a', 'xy', { delay: 5 })", "type", { text: "xy", delay: 5, timeout: "T" }],
  ["page.press('#a', 'Enter')", "press", { key: "Enter", delay: 0, timeout: "T" }],
  ["page.check('#a')", "check", { checked: true, force: false, position: null, trial: false, timeout: "T" }],
  ["page.uncheck('#a')", "check", { checked: false, force: false, position: null, trial: false, timeout: "T" }],
  ["page.setChecked('#a', true)", "check", { checked: true, force: false, position: null, trial: false, timeout: "T" }],
  ["page.selectOption('#a', 'blue')", "select", { options: ["blue"], force: false, timeout: "T" }],
  ["page.selectOption('#a', ['a', { value: 'b' }, { label: 'C' }, { index: 2 }])", "select",
    { options: ["a", { value: "b" }, { label: "C" }, { index: 2 }], force: false, timeout: "T" }],
  ["page.focus('#a')", "focus", { timeout: "T" }],
  ["page.setInputFiles('#a', ['a.txt', 'b.png'])", "files", { paths: ["a.txt", "b.png"], timeout: "T" }],
  ["page.textContent('#a')", "read", { what: "textContent", timeout: "T" }],
  ["page.innerText('#a')", "read", { what: "innerText", timeout: "T" }],
  ["page.innerHTML('#a')", "read", { what: "innerHTML", timeout: "T" }],
  ["page.inputValue('#a')", "read", { what: "inputValue", timeout: "T" }],
  ["page.getAttribute('#a', 'href')", "read", { what: "attribute", name: "href", timeout: "T" }],
  ["page.isVisible('#a')", "state", { what: "visible" }],
  ["page.isHidden('#a')", "state", { what: "hidden" }],
  ["page.isEnabled('#a')", "read", { what: "enabled", timeout: "T" }],
  ["page.isDisabled('#a')", "read", { what: "disabled", timeout: "T" }],
  ["page.isChecked('#a')", "read", { what: "checked", timeout: "T" }],
  ["page.isEditable('#a')", "read", { what: "editable", timeout: "T" }],
  ["page.locator('#a').clear()", "fill", { value: "", force: false, timeout: "T" }],
  ["page.locator('#a').pressSequentially('ab')", "type", { text: "ab", delay: 0, timeout: "T" }],
  ["page.locator('#a').blur()", "blur", { timeout: "T" }],
  ["page.locator('#a').scrollIntoViewIfNeeded()", "scroll", { timeout: "T" }],
  ["page.locator('#a').boundingBox()", "read", { what: "boundingBox", timeout: "T" }],
  ["page.locator('#a').count()", "count", {}],
  ["page.locator('#a').allTextContents()", "readAll", { what: "textContent" }],
  ["page.locator('#a').allInnerTexts()", "readAll", { what: "innerText" }],
  ["page.locator('#a').evaluate((e, n) => e.id + n, 1)", "eval", { fn: "(e, n) => e.id + n", arg: 1, timeout: "T" }],
  ["page.locator('#a').evaluateAll((es) => es.length)", "eval", { fn: "(es) => es.length", all: true }],
  ["page.locator('#a').waitFor()", "waitState", { state: "visible", timeout: "T" }],
  ["page.locator('#a').waitFor({ state: 'detached', timeout: 100 })", "waitState", { state: "detached", timeout: "T" }],
  ["page.locator('#a').screenshot()", "shot", { fullPage: false, type: "png", timeout: "T" }],
  ["page.locator('#a').ariaSnapshot()", "aria", { timeout: "T" }],
  ["page.waitForSelector('#a', { state: 'attached' })", "waitState", { state: "attached", timeout: "T" }],
  ["page.waitForLoadState()", "waitLoad", { state: "load", timeout: "T" }],
  ["page.waitForLoadState('networkidle')", "waitLoad", { state: "networkidle", timeout: "T" }],
  ["page.waitForFunction(() => window.ready)", "waitFn", { fn: "() => window.ready", polling: 100, timeout: "T" }],
  ["page.waitForFunction((n) => n > 1, 2, { polling: 'raf' })", "waitFn", { fn: "(n) => n > 1", arg: 2, polling: 16, timeout: "T" }],
  ["page.waitForTimeout(20)", "sleep", { ms: 20 }],
  ["page.evaluate(() => document.title)", "eval", { fn: "() => document.title" }],
  ["page.evaluate('1 + 1')", "eval", { fn: "1 + 1" }],
  ["page.evaluate((o) => o.a, { a: [1, 'x', null] })", "eval", { fn: "(o) => o.a", arg: { a: [1, "x", null] } }],
  ["page.keyboard.down('Shift')", "key", { action: "down", key: "Shift" }],
  ["page.keyboard.up('Shift')", "key", { action: "up", key: "Shift" }],
  ["page.keyboard.press('Control+a', { delay: 3 })", "key", { action: "press", key: "Control+a", delay: 3 }],
  ["page.keyboard.type('hé', { delay: 1 })", "key", { action: "type", text: "hé", delay: 1 }],
  ["page.keyboard.insertText('ê')", "key", { action: "insertText", text: "ê" }],
  ["page.mouse.move(10, 20, { steps: 5 })", "mouse", { action: "move", x: 10, y: 20, steps: 5 }],
  ["page.mouse.down({ button: 'right' })", "mouse", { action: "down", button: "right", clickCount: 1 }],
  ["page.mouse.up()", "mouse", { action: "up", button: "left", clickCount: 1 }],
  ["page.mouse.click(1, 2, { clickCount: 3, delay: 4 })", "mouse", { action: "click", x: 1, y: 2, button: "left", clickCount: 3, delay: 4 }],
  ["page.mouse.dblclick(1, 2)", "mouse", { action: "click", x: 1, y: 2, button: "left", clickCount: 2, delay: 0 }],
  ["page.mouse.wheel(0, 300)", "mouse", { action: "wheel", dx: 0, dy: 300 }],
  ["page.setViewportSize({ width: 390, height: 844 })", "viewport", { width: 390, height: 844 }],
  ["page.screenshot({ fullPage: true, type: 'jpeg', quality: 70 })", "shot", { fullPage: true, type: "jpeg", quality: 70 }],
  ["page.ariaSnapshot()", "aria", { timeout: "T" }],
];

const LANES = {
  goto: "action", history: "action", title: "action", content: "action", click: "action", hover: "action", fill: "action",
  type: "action", press: "action", check: "action", select: "action", focus: "action", blur: "action", scroll: "action",
  files: "action", read: "action", readAll: "action", count: "action", state: "action", aria: "action", eval: "action",
  key: "action", mouse: "action", viewport: "action", shot: "action",
  waitState: "wait", waitLoad: "wait", nextURL: "wait", waitFn: "wait", sleep: "wait",
  dialog: "immediate", listen: "immediate",
};

test("every member posts its op with the design's fields", async () => {
  for (const [expression, op, args] of MEMBERS) {
    const loom = runner({ handlers: { count: (m, l) => l.ok(m, 0), readAll: (m, l) => l.ok(m, []) } });
    const result = await loom.run(`async (page) => { await ${expression}; }`);
    assert.equal(result.ok, true, `${expression}: ${JSON.stringify(result.error)}`);
    assert.equal(loom.posts.length, 1, expression);
    assert.equal(loom.posts[0].op, op, expression);
    assert.ok(op in LANES, op);
    assert.deepEqual(shape(loom.posts[0]).args, args, expression);
  }
});

test("bad arguments reject before anything is posted, and cost no step", async () => {
  const loom = runner();
  const result = await loom.run(`async (page) => {
  const out = [];
  for (const call of [
    () => page.click('#a', { button: 'side' }),
    () => page.click('#a', { modifiers: ['Hyper'] }),
    () => page.fill('#a', 42),
    () => page.goto(''),
    () => page.goto('/x', { waitUntil: 'idle' }),
    () => page.waitForLoadState('commit'),
    () => page.locator('#a').waitFor({ state: 'gone' }),
    () => page.setInputFiles('#a', { name: 'a.txt', mimeType: 'text/plain', buffer: 'eA==' }),
    () => page.selectOption('#a', [42]),
    () => page.evaluate(() => 1, { f: 1n }),
    () => page.evaluate(Math.max),
    () => page.mouse.click('1', 2),
    () => page.keyboard.press(''),
    () => page.setViewportSize({ width: 0, height: 10 }),
    () => page.screenshot({ path: 'a.png' }),
    () => page.click('#a', { timeout: -1 }),
  ]) out.push(await call().then(() => 'resolved', (e) => e.name + ': ' + e.message));
  return out;
}`);
  assert.equal(result.ok, true);
  assert.equal(loom.posts.length, 0);
  assert.equal(result.steps, 0);
  const lines = JSON.parse(result.value);
  assert.deepEqual(lines, [
    'TypeError: page.click: button must be "left", "right" or "middle", not side',
    "TypeError: page.click: modifiers are among Alt, Control, ControlOrMeta, Meta and Shift, not [\"Hyper\"]",
    "TypeError: page.fill: value must be a string, not number",
    "TypeError: page.goto: url must be a non-empty string, not string",
    'TypeError: page.goto: waitUntil is "load", "domcontentloaded", "networkidle" or "commit", not idle',
    'TypeError: page.waitForLoadState: state is "load", "domcontentloaded" or "networkidle", not commit',
    'TypeError: locator.waitFor: state is "attached", "detached", "visible" or "hidden", not gone',
    "TypeError: page.setInputFiles: Loom takes file paths (a file under the project or the session's upload folder), not file contents",
    "TypeError: page.selectOption: an option is a string, {value}, {label} or {index}, not number",
    "TypeError: page.evaluate: arg must be JSON (Do not know how to serialize a BigInt)",
    "TypeError: page.evaluate: a native or bound function cannot be sent to the page",
    "TypeError: mouse.click: x must be a number, not 1",
    'TypeError: keyboard.press: key must be a key name such as "Enter" or "Control+a", not string',
    "TypeError: page.setViewportSize: expected {width, height}, positive integers in CSS pixels",
    "TypeError: page.screenshot: path is not supported: Loom attaches the screenshot to its answer",
    "TypeError: page.click: timeout must be a number >= 0, not -1",
  ]);
});

// ---------------------------------------------------------------- answers

test("answers are shaped as Playwright returns them; every answer may move page.url()", async () => {
  const values = {
    title: "Todos", content: "<html></html>", count: 3, read: "milk", readAll: ["a", "b"], state: true,
    select: ["blue"], aria: "- button \"Save\"", eval: JSON.stringify({ a: [1, 2] }, null, 2), waitFn: "true",
    goto: { url: "http://localhost:5173/docs", status: 200, statusText: "OK" },
  };
  const handlers = {};
  for (const [op, value] of Object.entries(values)) handlers[op] = (m, l) => l.ok(m, value, { url: "http://localhost:5173/docs" });
  handlers.history = (m, l) => l.ok(m, null);
  const loom = runner({ handlers });
  const result = await loom.run(`async (page) => {
  const before = page.url();
  const response = await page.goto('/docs');
  const handle = await page.waitForFunction(() => true);
  return {
    before, after: page.url(), status: response.status(), ok: response.ok(), responseURL: response.url(),
    back: await page.goBack(),
    title: await page.title(), content: await page.content(),
    count: await page.locator('li').count(),
    all: (await page.locator('li').all()).map(String),
    text: await page.locator('li').first().textContent(),
    texts: await page.locator('li').allTextContents(),
    visible: await page.locator('li').first().isVisible(),
    selected: await page.locator('select').selectOption('blue'),
    aria: await page.locator('main').ariaSnapshot(),
    evaluated: await page.evaluate(() => ({ a: [1, 2] })),
    waited: await handle.jsonValue(),
    clicked: await page.locator('li').first().click(),
  };
}`);
  assert.equal(result.ok, true, JSON.stringify(result.error));
  assert.deepEqual(JSON.parse(result.value), {
    before: "http://localhost:5173/", after: "http://localhost:5173/docs", status: 200, ok: true,
    responseURL: "http://localhost:5173/docs", back: null, title: "Todos", content: "<html></html>", count: 3,
    all: ["locator('li').nth(0)", "locator('li').nth(1)", "locator('li').nth(2)"],
    text: "milk", texts: ["a", "b"], visible: true, selected: ["blue"], aria: "- button \"Save\"",
    evaluated: { a: [1, 2] }, waited: true,
  });
});

test("the return value is browser_evaluate's JSON, cut at valueChars; undefined answers none", async () => {
  const code = "async (page) => ({ list: Array.from({ length: 30 }, (_, i) => i), long: 'y'.repeat(100) })";
  const cut = await runner({ config: { valueChars: 40 } }).run(code);
  const whole = await runner().run(code);
  assert.equal(cut.ok, true);
  assert.equal(cut.truncated, true);
  assert.equal(whole.truncated, undefined);
  assert.equal(cut.value, whole.value.slice(0, 40) + "\n… (cut at 40 characters)");

  const values = await runner().run(`async (page) => ({ map: new Map([['k', 1]]), big: 2n, fn: function named() {}, error: new TypeError('x'),
    locator: page.getByRole('button'), page, nothing: undefined, cycle: (() => { const o = {}; o.o = o; return o; })() })`);
  assert.deepEqual(JSON.parse(values.value), {
    map: { k: 1 }, big: "2n", fn: "[Function named]", error: { name: "TypeError", message: "x" },
    locator: "locator: getByRole('button')", page: "page: http://localhost:5173/", cycle: { o: "[Circular]" },
  });
  assert.equal("value" in await runner().run("async (page) => { await page.title(); }"), false);
  assert.equal((await runner().run("async (page) => null")).value, "null");
  assert.equal((await runner().run("async (page) => 'x'")).value, '"x"');
});

test("the facade's serializer answers what AgentScripts.serializer answers, for values without nodes", () => {
  const context = vm.createContext({ setTimeout, clearTimeout, URL });
  vm.runInContext(install({}), context);
  const reference = vm.runInContext(serializerSource(), context);
  const ours = context.__loomRun._pure.serialize;
  for (const source of ["1", "'x'", "null", "undefined", "[1, undefined, () => 1]", "({ a: undefined, b: 1n, c: Symbol('s') })",
    "new Map([['a', { b: 1 }]])", "new Set(['a', 'a'])", "(() => { const o = { n: 1 }; o.self = o; return [o, o]; })()",
    "new RangeError('r')", "({ toJSON() { return 'j'; } })", "[new Date(0)]", "NaN", "'\\u2028'"]) {
    const value = vm.runInContext(`(${source})`, context);
    assert.equal(ours(value), reference(value), source);
  }
});

// ---------------------------------------------------------------- lanes

test("actions go one at a time, in call order; waits and dialog answers do not queue behind them", async () => {
  const held = [];
  const loom = runner({ handlers: { click: (m) => held.push(m), sleep: (m, l) => setTimeout(() => l.ok(m), m.args.ms) } });
  const running = loom.run(`async (page) => {
  const a = page.locator('#a').click();
  const b = page.locator('#b').click();
  const c = page.locator('#c').fill('x');
  await page.waitForTimeout(5);
  return Promise.all([a, b, c]);
}`);
  await sleep(30);
  assert.deepEqual(loom.ops(), ["click", "sleep"], "the second click waits for the first; the sleep went out at once");
  loom.ok(held.shift());
  await sleep(10);
  assert.deepEqual(loom.ops(), ["click", "sleep", "click"]);
  assert.equal(loom.posts[2].target.desc, "locator('#b')");
  loom.ok(held.shift());
  const result = await running;
  assert.equal(result.ok, true);
  assert.deepEqual(loom.ops(), ["click", "sleep", "click", "fill"]);
});

test("Promise.all([page.waitForURL(…), locator.click()]): the wait goes out first, the click navigates", async () => {
  let pendingURL = null;
  let current = "http://localhost:5173/";
  const loom = runner({
    handlers: {
      nextURL: (m, l) => {
        if (current !== m.args.since) l.ok(m, current, { url: current });
        else pendingURL = m;
      },
      click: (m, l) => {
        current = "http://localhost:5173/done";
        l.ok(m, null, { url: current });
        if (pendingURL) { const w = pendingURL; pendingURL = null; l.ok(w, current, { url: current }); }
      },
    },
  });
  const result = await loom.run(`async (page) => {
  await Promise.all([page.waitForURL('**/done'), page.getByRole('link', { name: 'Done' }).click()]);
  return page.url();
}`);
  assert.equal(result.ok, true, JSON.stringify(result.error));
  assert.equal(JSON.parse(result.value), "http://localhost:5173/done");
  assert.deepEqual(loom.ops(), ["nextURL", "click", "waitLoad"]);
  assert.deepEqual(shape(loom.posts[0]), { id: 1, op: "nextURL", api: "page.waitForURL", step: 1, line: 2,
    args: { since: "http://localhost:5173/", timeout: "T" } });
  assert.ok(loom.posts[0].args.timeout > 29000, "a navigation wait: 30 s");
  assert.deepEqual(shape(loom.posts[2]).args, { state: "load", timeout: "T" });
});

test("waitForURL: a glob, a RegExp or a predicate, against each URL Loom pushes; already there answers at once", async () => {
  const urls = ["http://localhost:5173/a", "http://localhost:5173/b?x=1", "http://localhost:5173/settings#top"];
  const loom = runner({ handlers: { nextURL: (m, l) => { const next = urls.shift(); setTimeout(() => l.ok(m, next, { url: next }), 2); } } });
  const result = await loom.run(`async (page) => {
  await page.waitForURL('http://localhost:5173/');
  await page.waitForURL(/\\/b\\?x=1$/, { waitUntil: 'commit' });
  await page.waitForURL((url) => url.hash === '#top', { waitUntil: 'domcontentloaded' });
  return page.url();
}`);
  assert.equal(result.ok, true, JSON.stringify(result.error));
  assert.equal(JSON.parse(result.value), "http://localhost:5173/settings#top");
  assert.deepEqual(loom.ops(), ["waitLoad", "nextURL", "nextURL", "nextURL", "waitLoad"]);
  assert.deepEqual(loom.posts.map((m) => m.args.since ?? m.args.state),
    ["load", "http://localhost:5173/", "http://localhost:5173/a", "http://localhost:5173/b?x=1", "domcontentloaded"]);

  // Loom answers a wait that ran out with a TimeoutError; the facade says it Playwright's way, with the URLs seen.
  let moves = ["http://localhost:5173/x"];
  const late = runner({ handlers: { nextURL: (m, l) => {
    const next = moves.shift();
    if (next) l.ok(m, next, { url: next });
    else setTimeout(() => l.fail(m, { name: "TimeoutError", message: `Timeout ${m.args.timeout}ms exceeded.` }), m.args.timeout);
  } } });
  const timedOut = await late.run(`async (page) => {
  await page.waitForURL('**/never', { timeout: 50 });
}`);
  assert.equal(timedOut.ok, false);
  assert.deepEqual(timedOut.error, { name: "TimeoutError", line: 2, column: 14, step: 1,
    message: 'page.waitForURL: Timeout 50ms exceeded.\nCall log:\n  - waiting for navigation to "**/never" until "load"'
      + '\n  - navigated to "http://localhost:5173/x"' });

  // A wait Loom never answers ends 500 ms past its timeout all the same (waits change nothing; actions are Loom's to end).
  const silent = runner({ handlers: { nextURL: () => {}, waitState: () => {} } });
  const started = Date.now();
  const guarded = await silent.run(`async (page) => {
  const url = await page.waitForURL('**/never', { timeout: 40 }).catch((e) => e.name);
  const state = await page.locator('#a').waitFor({ timeout: 40 }).catch((e) => e.name + ': ' + e.message);
  return [url, state];
}`);
  assert.deepEqual(JSON.parse(guarded.value), ["TimeoutError", "TimeoutError: locator.waitFor: Timeout 40ms exceeded (Loom did not answer)"]);
  assert.ok(Date.now() - started >= 1000 && Date.now() - started < 2500, `${Date.now() - started} ms`);
  const asleep = runner({ handlers: { sleep: () => {} } });
  const slept = await asleep.run("async (page) => { await page.waitForTimeout(20); return 'woke'; }");
  assert.equal(JSON.parse(slept.value), "woke", "a sleep Loom never answers ends by itself");
});

test("globToRegexPattern is Playwright's", () => {
  const context = vm.createContext({ setTimeout, clearTimeout, URL });
  vm.runInContext(install({}), context);
  const { globToRegexPattern, resolveGlobToRegexPattern } = context.__loomRun._pure;
  const matches = (glob, url) => new RegExp(resolveGlobToRegexPattern(undefined, glob)).test(url);
  // From Playwright's own tests (tests/page/interception.spec.ts, "should work with glob").
  assert.ok(matches("**/*.js", "https://localhost:8080/foo.js"));
  assert.ok(!matches("**/*.css", "https://localhost:8080/foo.js"));
  assert.ok(!matches("*.js", "https://localhost:8080/foo.js"));
  assert.ok(matches("https://**/*.js", "https://localhost:8080/foo.js"));
  assert.ok(matches("http://localhost:8080/simple/path.js", "http://localhost:8080/simple/path.js"));
  assert.ok(matches("**/{a,b}.js", "https://localhost:8080/a.js"));
  assert.ok(!matches("**/{a,b}.js", "https://localhost:8080/c.js"));
  assert.ok(matches("**/*.{png,jpg,jpeg}", "https://localhost:8080/c.jpeg"));
  assert.ok(!matches("**/*.{png,jpg,jpeg}", "https://localhost:8080/c.css"));
  assert.ok(matches("foo*", "foo.js"));
  assert.ok(!matches("foo*", "foo/bar.js"));
  assert.ok(!matches("http://localhost:3000/signin-oidc*", "http://localhost:3000/signin-oidc/foo"));
  assert.ok(matches("http://localhost:3000/signin-oidc*", "http://localhost:3000/signin-oidcnice"));
  assert.ok(matches("**/three-columns/settings.html?**id=settings-**", "http://mydomain:8080/blah/blah/three-columns/settings.html?id=settings-e3c58efe-02e9-44b0-97ac-dd138100cf7c&blah"));
  assert.equal(globToRegexPattern("\\?"), "^\\?$");
  assert.equal(globToRegexPattern("\\"), "^\\\\$");
  assert.equal(globToRegexPattern("\\\\"), "^\\\\$");
  assert.equal(globToRegexPattern("\\["), "^\\[$");
  assert.equal(globToRegexPattern("[a-z]"), "^\\[a-z\\]$");
  assert.equal(globToRegexPattern("$^+.\\*()|\\?\\{\\}\\[\\]"), "^\\$\\^\\+\\.\\*\\(\\)\\|\\?\\{\\}\\[\\]$");
  assert.ok(matches("http://localhost:5173/**", "http://localhost:5173/a/b"));
  assert.ok(matches("HTTP://LOCALHOST:5173/A", "http://localhost:5173/A"), "the origin is case-insensitive, the path is not");
  assert.ok(!matches("http://localhost:5173/A", "http://localhost:5173/a"));

  // Against Playwright's own implementation, when it is installed.
  const core = playwrightCore();
  if (!core) return;
  const globs = ["**/*.js", "*.js", "https://**/*.js", "**/{a,b}.js", "foo*", "http://localhost:3000/signin-oidc*",
    "**/three-columns/settings.html?**id=settings-**", "http://localhost:5173/**", "HTTP://LOCALHOST:5173/A", "/docs", "**/docs?q=*",
    "about:blank", "data:*", "file:///tmp/**", "\\?x", "**/a\\{b\\}", "http://[::1]:8080/**", "**/", "", "**/*.{png,jpg}?v=*"];
  for (const glob of globs) {
    assert.equal(resolveGlobToRegexPattern(undefined, glob), core.resolveGlobToRegexPattern(undefined, glob), glob);
  }
});

// ---------------------------------------------------------------- strictness, auto-wait, errors

const AMBIGUOUS = "strict mode violation: getByRole('button') resolved to 2 elements:\n    1) button \"Save\" [ref=e5]\n    2) button \"Save draft\"";

test("a strict-mode violation fails at once, without asking again, in Playwright's words", async () => {
  const loom = runner({ handlers: { click: (m, l) => l.fail(m, { name: "Error", message: AMBIGUOUS }) } });
  const result = await loom.run(`async (page) => {
  const save = page.getByRole('button');
  await save.click();
}`);
  assert.equal(loom.posts.length, 1);
  assert.deepEqual(result.error, { name: "Error", message: "locator.click: " + AMBIGUOUS, line: 3, column: 14, step: 1 });
});

test("a `retry` answer is asked again until the call's timeout; then Playwright's TimeoutError with its call log", async () => {
  let n = 0;
  const loom = runner({
    handlers: {
      click: (m, l) => (++n < 3 ? l.fail(m, { message: "element is not visible", retry: true }) : l.ok(m)),
      fill: (m, l) => l.fail(m, { message: "waiting for getByLabel('Email')", retry: true }),
      check: (m, l) => l.fail(m, { message: "element is not enabled", retry: true }),
    },
  });
  const result = await loom.run(`async (page) => {
  await page.getByRole('button').click();
  try {
    await page.getByLabel('Email').fill('a@b.c', { timeout: 150 });
  } catch (e) {
    console.log(e.name, e instanceof Error);
  }
  await page.check('#c', { timeout: 120 });
}`);
  const clicks = loom.posts.filter((m) => m.op === "click");
  assert.deepEqual(clicks.map((m) => m.attempt), [undefined, 1, 2]);
  assert.deepEqual(clicks.map((m) => m.step), [1, 1, 1], "one call, one step");
  assert.ok(clicks[2].args.timeout < clicks[0].args.timeout, "each try gets what is left");
  const fills = loom.posts.filter((m) => m.op === "fill");
  assert.ok(fills.length >= 3 && fills.length <= 8, `${fills.length} tries in 150 ms`);
  assert.deepEqual(result.logs, ["TimeoutError true"]);
  assert.deepEqual(result.error, {
    name: "TimeoutError", line: 8, column: 14, step: 3,
    message: "page.check: Timeout 120ms exceeded.\nCall log:\n  - waiting for locator('#c')\n  - element is not enabled",
  });
});

test("Loom's own errors keep their name; a message already named by its call is not named twice", async () => {
  const loom = runner({
    handlers: {
      fill: (m, l) => l.fail(m, { name: "TimeoutError", message: "Timeout 5000ms exceeded.\nCall log:\n  - waiting for getByLabel('Email')" }),
      click: (m, l) => l.fail(m, { name: "TimeoutError", message: "locator.click: Timeout 5000ms exceeded." }),
      goto: (m, l) => l.fail(m, { message: "net::ERR_CONNECTION_REFUSED at http://localhost:9/" }),
      read: (m, l) => l.fail(m, { name: "Bad Name!", message: "Not an <input>, <textarea> or <select> element" }),
    },
  });
  const result = await loom.run(`async (page) => {
  const out = [];
  for (const call of [() => page.getByLabel('Email').fill('x'), () => page.getByRole('button').click(),
    () => page.goto('http://localhost:9/'), () => page.locator('p').inputValue()]) {
    out.push(await call().then(() => 'resolved', (e) => e.name + ': ' + e.message));
  }
  return out;
}`);
  assert.deepEqual(JSON.parse(result.value), [
    "TimeoutError: locator.fill: Timeout 5000ms exceeded.\nCall log:\n  - waiting for getByLabel('Email')",
    "TimeoutError: locator.click: Timeout 5000ms exceeded.",
    "Error: page.goto: net::ERR_CONNECTION_REFUSED at http://localhost:9/",
    "Error: locator.inputValue: Not an <input>, <textarea> or <select> element",
  ]);
});

test("errors carry the agent's line: a call's, a thrown one's, through a helper of its own; bare bodies too", async () => {
  const loom = runner({ handlers: { title: (m, l) => l.fail(m, { message: "boom" }) } });
  const result = await loom.run(`async (page) => {
  const helper = async () => {
    await page.title();
  };
  await helper();
}`);
  assert.deepEqual(result.error, { name: "Error", message: "page.title: boom", line: 3, column: 16, step: 1 });
  assert.equal(loom.posts[0].line, 3);

  const thrown = await runner().run(`async (page) => {
  await page.title();

  throw new RangeError("nope");
}`);
  assert.deepEqual(thrown.error, { name: "RangeError", message: "nope", line: 4, column: 9 });

  const body = await runner().run(`const t = await page.title();
if (t === undefined) throw new Error('no title: ' + t);
return t;`);
  assert.equal(body.ok, true, "a bare body is run as async (page) => { … }");
  const bodyError = await runner().run(`await page.title();
null.x;`);
  assert.equal(bodyError.error.name, "TypeError");
  assert.equal(bodyError.error.line, 2);

  const commented = await runner().run(`// the title, twice
async (page) => {
  await page.title();
  throw new Error('line 4');
}`);
  assert.deepEqual(commented.error, { name: "Error", message: "line 4", line: 4, column: 9 }, "a leading comment keeps it a function, lines as written");

  const predicate = await runner({ handlers: { nextURL: (m, l) => l.ok(m, "http://localhost:5173/next", { url: "http://localhost:5173/next" }) } })
    .run(`async (page) => {
  await page.waitForURL((url) => {
    if (url.pathname === '/next') throw new Error('from the predicate');
    return false;
  });
}`);
  assert.deepEqual(predicate.error, { name: "Error", message: "from the predicate", line: 3, column: 41, step: 1 },
    "a callback's own error: where it was thrown, in the step that ran it");

  const notError = await runner().run("async (page) => { throw 'just a string'; }");
  assert.deepEqual(notError.error, { name: "Error", message: "just a string" });

  // A SyntaxError: nothing ran. Node reports the expression's line; Chromium's exceptionDetails.lineNumber is
  // 0-based, which makes it the agent's line (checked on a real Chromium below).
  assert.throws(() => new vm.Script(entry("async (page) => {\n  const a = 1;\n  const = 2;\n}"), { filename: SOURCE_URL }),
    (error) => error instanceof SyntaxError && /browser_run_code\.js:4\b/.test(error.stack));
});

test("a call after the function returned is refused; calls still out are named (missing await?)", async () => {
  const loom = runner({ handlers: { click: () => {} } });
  const result = await loom.run(`async (page) => {
  globalThis.late = page;
  page.getByRole('button', { name: 'Save' }).click();
  page.locator('#b').fill('x');
  page.waitForTimeout(10000);
}`);
  assert.equal(result.ok, true);
  assert.deepEqual(result.unfinished, [
    "locator.click getByRole('button', { name: 'Save' })", "locator.fill locator('#b')", "page.waitForTimeout 10000 ms",
  ]);
  assert.deepEqual(loom.ops(), ["click", "sleep"], "the fill never went out: the click held the lane");
  await assert.rejects(loom.eval("late.title()"), /page.title: the run has ended: this call came after your function returned \(missing await\?\)/);
  await sleep(10);
  assert.equal(loom.posts.length, 2);
});

test("caps: 32 calls in flight, the run's call count, a message's bytes — refused here, never posted", async () => {
  const flight = runner({ handlers: { sleep: () => {} } });
  const inFlight = await flight.run(`async (page) => {
  const calls = [];
  for (let i = 0; i < 33; i++) calls.push(page.waitForTimeout(1000).then(() => 'ok', (e) => e.message));
  return await calls[32];
}`);
  assert.equal(JSON.parse(inFlight.value), "page.waitForTimeout: 32 page calls are already in flight (missing await?)");
  assert.equal(flight.posts.length, 32);
  assert.equal(inFlight.unfinished.length, 32);

  const steps = runner({ config: { maxSteps: 3 } });
  const counted = await steps.run(`async (page) => {
  await page.title(); await page.title(); await page.title();
  return await page.title().catch((e) => e.message);
}`);
  assert.equal(JSON.parse(counted.value), "page.title: a script makes 3 page calls at most");
  assert.equal(steps.posts.length, 3);

  const bytes = runner({ config: { maxMessageBytes: 1000 } });
  const big = await bytes.run(`async (page) => {
  const out = [await page.locator('#a').fill('é'.repeat(600)).catch((e) => e.message)];
  out.push(await page.locator('#a').fill('e'.repeat(600)).then(() => 'sent'));
  return out;
}`);
  assert.deepEqual(JSON.parse(big.value), ["locator.fill: this call is 2 KB; a call is 1 KB at most", "sent"]);
  assert.equal(bytes.posts.length, 1);
  assert.equal(big.steps, 2);
});

test("time: a 0 timeout is the run's end; every timeout is capped by it", async () => {
  const loom = runner({ config: { scriptMs: 2000 } });
  await loom.run(`async (page) => {
  await page.locator('#a').click({ timeout: 0 });
  await page.goto('/x');
  page.setDefaultTimeout(700);
  await page.locator('#a').click();
  await page.goto('/y');
  page.setDefaultNavigationTimeout(900);
  await page.goto('/z');
  await page.waitForTimeout(60000);
}`);
  const timeouts = loom.posts.map((m) => m.args.timeout ?? m.args.ms);
  assert.ok(timeouts[0] > 1900 && timeouts[0] <= 2000, `0 → the run's end: ${timeouts[0]}`);
  assert.ok(timeouts[1] > 1900 && timeouts[1] <= 2000, `30 s capped: ${timeouts[1]}`);
  assert.ok(timeouts[2] > 600 && timeouts[2] <= 700, `setDefaultTimeout: ${timeouts[2]}`);
  assert.ok(timeouts[3] > 600 && timeouts[3] <= 700, `navigations follow it: ${timeouts[3]}`);
  assert.ok(timeouts[4] > 800 && timeouts[4] <= 900, `until setDefaultNavigationTimeout: ${timeouts[4]}`);
  assert.ok(timeouts[5] > 1800 && timeouts[5] <= 2000, `a sleep too: ${timeouts[5]}`);
});

// ---------------------------------------------------------------- dialogs

test("page.on('dialog'): the listener is said to Loom; the handler's answer passes the click it blocks", async () => {
  let blockedClick = null;
  const loom = runner({
    handlers: {
      listen: (m, l) => l.ok(m),
      click: (m, l) => {
        blockedClick = m;
        l.send({ event: "dialog", dialog: { id: 7, type: "prompt", message: "Name?", defaultValue: "Ann" } });
      },
      dialog: (m, l) => {
        l.ok(m);
        if (blockedClick) l.ok(blockedClick);
      },
    },
  });
  const result = await loom.run(`async (page) => {
  const seen = [];
  const handler = async (dialog) => {
    seen.push([dialog.type(), dialog.message(), dialog.defaultValue()]);
    const accepted = dialog.accept('Bob');
    seen.push(await dialog.accept().catch((e) => e.message));
    await accepted;
  };
  page.on('dialog', handler);
  await page.getByRole('button', { name: 'Rename' }).click();
  page.off('dialog', handler);
  return seen;
}`);
  assert.equal(result.ok, true, JSON.stringify(result.error));
  assert.deepEqual(JSON.parse(result.value), [["prompt", "Name?", "Ann"], "Cannot accept dialog which is already handled!"]);
  assert.deepEqual(loom.posts.map(shape), [
    { id: 1, op: "listen", api: "page.on", step: null, line: null, args: { dialog: true } },
    { id: 2, op: "click", api: "locator.click", step: 1, line: 10,
      target: { chain: [{ role: "button", name: { s: "Rename", m: "ci" } }], desc: "getByRole('button', { name: 'Rename' })", strict: true },
      args: { button: "left", clickCount: 1, modifiers: [], position: null, force: false, trial: false, delay: 0, timeout: "T" } },
    { id: 3, op: "dialog", api: "dialog.accept", step: 2, line: 5, args: { id: 7, accept: true, promptText: "Bob" } },
    { id: 4, op: "listen", api: "page.on", step: null, line: null, args: { dialog: false } },
  ]);
});

test("once, waitForEvent and a dismiss; a dialog no one listens for any more is dismissed", async () => {
  const loom = runner({
    handlers: {
      click: (m, l) => {
        l.send({ event: "dialog", dialog: { id: m.id, type: "confirm", message: "Delete?" } });
        setTimeout(() => l.ok(m), 5);
      },
    },
  });
  const result = await loom.run(`async (page) => {
  page.once('dialog', (d) => d.dismiss());
  await page.locator('#delete').click();
  const [dialog] = await Promise.all([page.waitForEvent('dialog'), page.locator('#again').click()]);
  await dialog.accept();
  const late = await page.waitForEvent('dialog', { timeout: 30 }).catch((e) => e.name + ': ' + e.message);
  return [dialog.message(), JSON.stringify({ dialog }), late];
}`);
  assert.equal(result.ok, true, JSON.stringify(result.error));
  assert.deepEqual(JSON.parse(result.value), ["Delete?", JSON.stringify({ dialog: "dialog: confirm \"Delete?\"" }),
    "TimeoutError: page.waitForEvent: Timeout 30ms exceeded while waiting for event \"dialog\""]);
  assert.deepEqual(loom.posts.map((m) => [m.op, m.args.dialog ?? m.args.accept ?? null]), [
    ["listen", true], ["click", null], ["dialog", false], ["listen", false],
    ["listen", true], ["click", null], ["listen", false], ["dialog", true],
    ["listen", true], ["listen", false],
  ]);

  // An event with no listener left (a race with page.off): dismissed, as Playwright does by default.
  const stray = runner();
  await stray.run("async (page) => { globalThis.p = page; }");
  stray.send({ event: "dialog", dialog: { id: 9, type: "alert", message: "Hi" } });
  await sleep(5);
  assert.equal(stray.posts.length, 0, "after the run, nothing is posted");
  const live = runner({ handlers: { sleep: (m, l) => { l.send({ event: "dialog", dialog: { id: 4, type: "alert", message: "Hi" } }); setTimeout(() => l.ok(m), 5); } } });
  await live.run("async (page) => { await page.waitForTimeout(1); }");
  assert.deepEqual(live.posts.map(shape)[1], { id: 2, op: "dialog", api: "dialog.dismiss", step: null, line: null, args: { id: 4, accept: false } });
});

test("a handler that throws fails the run with its own error and line", async () => {
  const loom = runner({ handlers: { click: (m, l) => { l.send({ event: "dialog", dialog: { id: 1, type: "alert", message: "x" } }); setTimeout(() => l.ok(m), 5); } } });
  const result = await loom.run(`async (page) => {
  page.on('dialog', (dialog) => {
    dialog.acept();
  });
  await page.locator('#a').click();
  return 'done';
}`);
  assert.equal(result.ok, false);
  assert.equal(result.error.line, 3);
  assert.match(result.error.message, /^dialog\.acept is not available in Loom's browser_run_code\. Did you mean dialog\.accept\? Supported: type, message, defaultValue, page, accept, dismiss\.$/);
});

test("other events are refused with what to use instead", async () => {
  const loom = await builders();
  assert.throws(() => loom.eval("page.on('console', () => {})"),
    /^Error: page\.on\('console'\) is not available in Loom's browser_run_code: only 'dialog' is\. the page's console is in browser_console_messages/);
  await assert.rejects(loom.eval("page.waitForEvent('popup')"), /page\.waitForEvent\('popup'\) is not available.*a popup becomes a tab: browser_tabs/);
});

// ---------------------------------------------------------------- the guard

test("unknown members throw what is available; await page and JSON never hang or throw", async () => {
  const loom = runner();
  const result = await loom.run(`async (page) => {
  const out = {};
  out.awaited = (await page) === page;
  out.then = page.then === undefined && page.getByRole('button').then === undefined;
  out.symbol = page[Symbol.iterator] === undefined;
  for (const [name, get] of [['route', () => page.route], ['typo', () => page.getByRol], ['frames', () => page.frameLocator],
    ['dollar', () => page.$$], ['context', () => page.context], ['locator', () => page.locator('a').dragTo],
    ['keyboard', () => page.keyboard.sendCharacter], ['destructured', () => { const { page: p } = page; return p; }]]) {
    try { get(); out[name] = 'no error'; } catch (e) { out[name] = e.message; }
  }
  out.json = JSON.stringify({ page, locator: page.getByText('Hi'), keyboard: page.keyboard });
  out.string = String(page.getByText('Hi')) + ' | ' + \`\${page.locator('#a').first()}\`;
  return out;
}`);
  const out = JSON.parse(result.value);
  assert.equal(out.awaited, true);
  assert.equal(out.then, true);
  assert.equal(out.symbol, true);
  assert.match(out.route, /^page\.route is not available in Loom's browser_run_code: requests cannot be intercepted\. Supported: keyboard, mouse, url, title, content, goto, /);
  assert.match(out.route, /, getByRole, .*, click, dblclick, hover, fill, /);
  assert.match(out.typo, /^page\.getByRol is not available in Loom's browser_run_code\. Did you mean page\.getByRole\? Supported: /);
  assert.match(out.frames, /^page\.frameLocator is not available in Loom's browser_run_code: frames are not supported\./);
  assert.match(out.dollar, /^page\.\$\$ is not available in Loom's browser_run_code: use page\.locator\(selector\)\.all\(\)\./);
  assert.match(out.context, /: the browser context is out of reach/);
  assert.match(out.locator, /^locator\.dragTo is not available in Loom's browser_run_code: use page\.mouse: move, down, move, up\. Supported: /);
  assert.match(out.keyboard, /^keyboard\.sendCharacter is not available .* Supported: down, up, press, type, insertText\.$/);
  assert.match(out.destructured, /^page\.page is not available in Loom's browser_run_code: your function receives the page itself/);
  assert.equal(out.json, JSON.stringify({ page: "page: http://localhost:5173/", locator: "locator: getByText('Hi')", keyboard: "keyboard" }));
  assert.equal(out.string, "getByText('Hi') | locator('#a').first()");
});

test("the script's world: the network and modal APIs throw with what to do; its console is kept, formatted and capped", async () => {
  const fetches = [];
  const loom = runner({
    config: { consoleLines: 6, consoleChars: 160 },
    globals: { fetch: (...args) => { fetches.push(args); return Promise.resolve({}); }, alert: () => {}, navigator: { sendBeacon: () => true } },
  });
  const result = await loom.run(`async (page) => {
  const out = [];
  for (const call of [() => fetch('http://example.com'), () => alert('x'), () => navigator.sendBeacon('/x', 'y')]) {
    try { await call(); out.push('called'); } catch (e) { out.push(e.message); }
  }
  console.log('%s has %d items', 'list', 3.7, { a: 1 });
  console.warn(page.getByRole('button'));
  console.error(new TypeError('bad'));
  console.info([1, [2]], null, undefined);
  console.assert(1 === 2, 'math');
  console.debug('x'.repeat(200));
  console.log('dropped');
  console.log('dropped too');
  return out;
}`);
  assert.equal(fetches.length, 0);
  assert.deepEqual(JSON.parse(result.value), [
    "fetch is not available in browser_run_code: the script runs outside the page, offline. Run it in the page: page.evaluate(() => fetch(…))",
    "alert is not available in browser_run_code: the script runs outside the page, offline. Run it in the page: page.evaluate(() => alert(…))",
    "navigator.sendBeacon is not available in browser_run_code: the script runs outside the page, offline. Run it in the page: page.evaluate(() => navigator.sendBeacon(…))",
  ]);
  assert.deepEqual(result.logs, [
    'list has 3 items {"a":1}',
    "[WARNING] locator: getByRole('button')",
    "[ERROR] TypeError: bad",
    "[1,[2]] null undefined",
    "[ERROR] Assertion failed: math",
    "[DEBUG] " + "x".repeat(15) + "…",
  ]);
  assert.equal(result.logs.join("").length, 160);
  assert.equal(result.logsDropped, 2);
});

// ---------------------------------------------------------------- the bridge's edges

test("answers arrive as JSON text or objects, through __loomRunAnswer, __loomRun.reply and __loomRun.event; junk is ignored", async () => {
  const loom = runner({ handlers: { title: () => {}, content: () => {} } });
  const running = loom.run("async (page) => [await page.title(), await page.content(), page.url()]");
  await sleep(5);
  assert.equal(loom.eval("__loomRunAnswer('not json')"), false);
  assert.equal(loom.eval("__loomRunAnswer({ id: 999, ok: true })"), false);
  assert.equal(loom.eval(`__loomRun.reply(${JSON.stringify(JSON.stringify({ id: 1, ok: true, value: "T" }))})`), true);
  await sleep(5);
  assert.equal(loom.eval("__loomRun.event(JSON.stringify({ event: 'url', url: 'http://localhost:5173/moved' }))"), true);
  assert.equal(loom.eval("__loomRun.reply({ id: 2, ok: true, value: 'C' })"), true);
  assert.deepEqual(JSON.parse((await running).value), ["T", "C", "http://localhost:5173/moved"]);
  // The engine's answer function, as Chromium would call it.
  const deliver = loom.eval(`(${ANSWER_FUNCTION})`);
  assert.equal(deliver(JSON.stringify({ id: 3, ok: true })), false, "an id already answered");
});

test("a second run in the same world is refused without ending the first", async () => {
  const loom = runner({ handlers: { sleep: (m, l) => setTimeout(() => l.ok(m), 20) } });
  const result = await loom.run(`async (page) => {
  const nested = await globalThis.__loomRun.run(async () => 1);
  await page.waitForTimeout(1);
  return nested.error.message;
}`);
  assert.equal(result.ok, true);
  assert.equal(JSON.parse(result.value), "this world already runs a script");
});

// ---------------------------------------------------------------- real Chromium, when Playwright is installed

async function loadPlaywright() {
  try { return await import("playwright"); } catch (_) { /* not local */ }
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    return createRequire(import.meta.url)(resolve(root, "playwright"));
  } catch (_) {
    return null;
  }
}

function playwrightCore() {
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    const require = createRequire(resolve(root, "playwright", "package.json"));
    return require("playwright-core/lib/utils/isomorphic/urlMatch.js");
  } catch (_) {
    return null;
  }
}

const playwright = await loadPlaywright();
const skip = playwright ? false : "Playwright is not installed";

test("in a real Chromium isolated world: the binding out, callFunctionOn back, sourceURL lines, a SyntaxError's line", { skip }, async () => {
  const browser = await playwright.chromium.launch();
  try {
    const page = await browser.newPage();
    await page.setContent("<title>Real</title><button>Save</button>");
    const cdp = await page.context().newCDPSession(page);
    const { frameTree } = await cdp.send("Page.getFrameTree");

    async function world(n, config) {
      const { executionContextId } = await cdp.send("Page.createIsolatedWorld", { frameId: frameTree.frame.id, worldName: `loom-run-${n}` });
      await cdp.send("Runtime.addBinding", { name: "__loomRunCall", executionContextId });
      const installed = await cdp.send("Runtime.evaluate", { contextId: executionContextId, expression: install(config), returnByValue: true });
      assert.equal(installed.exceptionDetails, undefined, JSON.stringify(installed.exceptionDetails));
      return executionContextId;
    }

    // Loom, played by the test: answers `title` and `count` from the page, by the world's id only.
    const posts = [];
    let contextId = 0;
    cdp.on("Runtime.bindingCalled", async (event) => {
      if (event.executionContextId !== contextId) return;
      const message = JSON.parse(event.payload);
      posts.push(message);
      const reply = { id: message.id, ok: true, url: "http://localhost:5173/real" };
      if (message.op === "title") reply.value = await page.title();
      if (message.op === "count") reply.value = await page.locator("button").count();
      await cdp.send("Runtime.callFunctionOn", { executionContextId: contextId, functionDeclaration: ANSWER_FUNCTION,
        arguments: [{ value: JSON.stringify(reply) }], silent: true });
    });

    contextId = await world(1, { url: "about:blank" });
    const ok = await cdp.send("Runtime.evaluate", { contextId, awaitPromise: true, returnByValue: true, expression: entry(`async (page) => {
  console.log('in', typeof document);
  const title = await page.title();
  const buttons = await page.getByRole('button', { name: 'Save' }).count();
  let blocked;
  try { await fetch('/x'); } catch (e) { blocked = e.message; }
  return { title, buttons, url: page.url(), blocked };
}`) });
    assert.equal(ok.exceptionDetails, undefined);
    const run = ok.result.value;
    assert.equal(run.ok, true, JSON.stringify(run.error));
    assert.deepEqual(JSON.parse(run.value), { title: "Real", buttons: 1, url: "http://localhost:5173/real",
      blocked: "fetch is not available in browser_run_code: the script runs outside the page, offline. Run it in the page: page.evaluate(() => fetch(…))" });
    assert.deepEqual(run.logs, ["in object"]);
    assert.deepEqual(posts.map((m) => [m.op, m.line]), [["title", 3], ["count", 4]]);

    // A thrown error's line comes from its stack: V8 names the frame after the sourceURL.
    contextId = await world(2, {});
    const thrown = await cdp.send("Runtime.evaluate", { contextId, awaitPromise: true, returnByValue: true, expression: entry(`async (page) => {
  await page.title();

  undefinedFunction();
}`) });
    assert.deepEqual(thrown.result.value.error, { name: "ReferenceError", message: "undefinedFunction is not defined", line: 4, column: 3 });

    // A SyntaxError: nothing ran; exceptionDetails.lineNumber (0-based) is the agent's line.
    contextId = await world(3, {});
    const syntax = await cdp.send("Runtime.evaluate", { contextId, awaitPromise: true, returnByValue: true,
      expression: entry("async (page) => {\n  const a = 1;\n  const = 2;\n}") });
    assert.equal(syntax.exceptionDetails.lineNumber, 3);
    assert.equal(syntax.exceptionDetails.columnNumber + 1, 9);
    assert.match(syntax.exceptionDetails.exception.description, /^SyntaxError: /);
    const bare = await cdp.send("Runtime.evaluate", { contextId, awaitPromise: true, returnByValue: true,
      expression: entry("await page.title()\nreturn )") });
    assert.equal(bare.exceptionDetails.lineNumber, 2);
  } finally {
    await browser.close();
  }
});

test("locator descriptions equal Playwright's toString", { skip }, async () => {
  const browser = await playwright.chromium.launch();
  try {
    const real = await browser.newPage();
    const loom = await builders();
    for (const [expression] of CHAINS) {
      const theirs = new Function("page", `return String(${expression});`)(real);
      assert.equal(loom.eval(`String(${expression})`), theirs, expression);
    }
  } finally {
    await browser.close();
  }
});

test("the facade's targets against the helper's selector engine on a real page: strictness, auto-wait, reads, waits", { skip }, async () => {
  const browser = await playwright.chromium.launch();
  try {
    const page = await browser.newPage();
    await page.addInitScript(helperSource());
    await page.goto("about:blank");
    await page.setContent(`
      <ul><li>Milk <button>Delete</button></li><li>Eggs <button>Delete</button></li></ul>
      <button>Save</button><button>Save draft</button>
      <label>Name <input id="name"></label>
      <p hidden>Secret</p><p id="log"></p>
      <script>
        setTimeout(() => {
          const later = document.createElement("button");
          later.textContent = "Later";
          later.onclick = () => {
            document.getElementById("log").textContent = "later clicked";
            setTimeout(() => document.body.append(Object.assign(document.createElement("p"), { textContent: "Done" })), 100);
          };
          document.body.append(later);
        }, 150);
      </script>`);

    // Loom, played by the test: each op through the helper, its answers as the bridge says.
    const helper = async (op, args) =>
      JSON.parse(await page.evaluate(([o, a]) => globalThis.__loomAgent.run(o, a), [op, JSON.stringify(args)]));
    const answerOf = (result, key) => {
      if (result.error) return { ok: false, error: { message: result.error.message, retry: result.error.retry === true } };
      if (result.status === "retry") return { ok: false, error: { message: result.reason, retry: true } };
      return { ok: true, value: key ? result[key] : undefined };
    };
    const forward = (fn) => (message, loom) => {
      fn(message).then((reply) => loom.send({ id: message.id, ...reply }),
        (error) => loom.send({ id: message.id, ok: false, error: { message: String(error) } }));
    };
    const act = (action, then) => forward(async (m) => {
      const ready = await helper("prepare", { target: m.target, action });
      if (ready.error || ready.status !== "ready") return answerOf(ready);
      return answerOf(await helper(then.op, then.args(m)));
    });
    const loom = runner({
      handlers: {
        count: forward(async (m) => answerOf(await helper("count", { target: m.target }), "count")),
        read: forward(async (m) => answerOf(await helper("read", { target: m.target, what: m.args.what, name: m.args.name }), "value")),
        readAll: forward(async (m) => answerOf(await helper("readAll", { target: m.target, what: m.args.what }), "value")),
        state: forward(async (m) => answerOf(await helper("state", { target: m.target, what: m.args.what }), "value")),
        waitState: forward(async (m) => {
          const result = await helper("waitState", { target: m.target, state: m.args.state, maxMs: Math.min(m.args.timeout, 500) });
          if (result.error) return answerOf(result);
          return result.done ? { ok: true } : { ok: false, error: { message: "waiting for " + m.target.desc, retry: true } };
        }),
        click: act("click", { op: "click", args: (m) => ({ target: m.target }) }),
        fill: act("type", { op: "type", args: (m) => ({ target: m.target, text: m.args.value }) }),
      },
    });
    const result = await loom.run(`async (page) => {
  const rows = page.getByRole('listitem');
  const out = {};
  out.count = await rows.count();
  out.texts = await rows.allTextContents();
  out.milk = await rows.filter({ hasText: 'Milk' }).getByRole('button').count();
  out.notEggs = await rows.filter({ hasNotText: 'Eggs' }).textContent();
  out.secret = await page.getByText('Secret').isVisible();
  out.strict = await page.getByRole('button', { name: 'Save' }).click().catch((e) => e.message);
  out.loose = await page.textContent('text=Delete');
  await page.getByRole('button', { name: 'Later' }).click();
  await page.getByText('Done').waitFor();
  out.log = await page.locator('#log').textContent();
  await page.getByLabel('Name').fill('Ann');
  out.name = await page.getByLabel('Name').inputValue();
  out.missing = await page.getByRole('button', { name: 'Nope' }).click({ timeout: 300 }).catch((e) => e.name + ': ' + e.message);
  return out;
}`);
    assert.equal(result.ok, true, JSON.stringify(result.error));
    const out = JSON.parse(result.value);
    assert.equal(out.count, 2);
    assert.deepEqual(out.texts, ["Milk Delete", "Eggs Delete"]);
    assert.equal(out.milk, 1);
    assert.equal(out.notEggs, "Milk Delete");
    assert.equal(out.secret, false);
    assert.match(out.strict, /^locator\.click: strict mode violation: getByRole\('button', \{ name: 'Save' \}\) resolved to 2 elements:\n    1\) /);
    assert.equal(out.loose, "Delete", "page.textContent(selector) is not strict: the first of two");
    assert.equal(out.log, "later clicked", "the click waited for its button (retry answers), then the text appeared (waitState)");
    assert.equal(out.name, "Ann");
    assert.equal(out.missing, "TimeoutError: locator.click: Timeout 300ms exceeded.\nCall log:\n  - waiting for getByRole('button', { name: 'Nope' })");
    assert.ok(loom.posts.filter((m) => m.op === "click" && m.attempt).length >= 1, "the Later click was asked again");
  } finally {
    await browser.close();
  }
});
