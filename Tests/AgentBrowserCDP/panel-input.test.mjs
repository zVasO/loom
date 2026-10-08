// The interactive panel (design panel.md §2, §7): what a person's mouse,
// wheel, keyboard, IME and clipboard reach through Input.* on a real
// Chromium, and the panel script's ops (AgentPanelScript.swift).
//
// The panel script is read out of the Swift source, as
// Tests/AgentBrowserJS/extract.mjs reads AgentScripts — no copy to drift
// from — and installed as the engine installs it: in the helper's world,
// Page.addScriptToEvaluateOnNewDocument {worldName: "loom-agent",
// runImmediately: true}, then reached through Page.createIsolatedWorld's
// context with Runtime.callFunctionOn(AgentPanelScript.callFunction).
//
// The probes the design marks [verify] are tests that assert what was
// measured here (Linux, chrome-headless-shell and chromium --headless=new
// 141), so the macOS CI checks it again. Where Blink is platform-specific by
// design (⌃-click, a <select>'s popup and keys, the system clipboard), the
// Mac only records what it sees: the t.diagnostic lines of the CI log.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { delay, launch, performance, within, withTimeout } from "./lib/cdp.mjs";
import { charKey, keyPress, KEYS, mouseMove, mousePress } from "./lib/input.mjs";
import { openTab, prepareBrowser, Tab, WORLD } from "./lib/init.mjs";
import { decodePNG } from "./lib/png.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const panelSwift = resolve(here, "../../Sources/LoomWeb/AgentBrowser/Chromium/AgentPanelScript.swift");

/** One `static let <name>: String = #"""…"""#` of AgentPanelScript, its lines at column 0. */
function literal(name) {
  const swift = readFileSync(panelSwift, "utf8");
  const match = new RegExp(`static let ${name}(?:: String)? = #"""\\n([\\s\\S]*?)\\n"""#`).exec(swift);
  if (!match) throw new Error(`AgentPanelScript.${name} not found — it must stay a #""" raw string at column 0`);
  return match[1];
}

const PANEL_SOURCE = literal("source");
const PANEL_FUNCTION = literal("callFunction").trim();

const darwin = process.platform === "darwin";
// Copy and paste commands may write the Mac's own pasteboard (T-clip): on a
// person's Mac only when asked; on the CI's Mac always.
const CLIPBOARD_SKIP = darwin && !process.env.CI && process.env.LOOM_CDP_CLIPBOARD !== "1"
  && "it may write the Mac's pasteboard: LOOM_CDP_CLIPBOARD=1 to run it";

/** As the engine will: the script for every new document (and the current one), in the helper's world. */
async function installPanel(tab) {
  await tab.session.send("Page.addScriptToEvaluateOnNewDocument", { source: PANEL_SOURCE, worldName: WORLD, runImmediately: true });
}

/** One panel op in the helper's world: its JSON answer. */
const panel = (tab, op, arg, callOptions) => tab.call(PANEL_FUNCTION, [op, arg], callOptions);

const PAGE_ROUND = (value) => Math.round(value * 100) / 100;

eachBrowser((browser) => {
  let server;
  let chrome;
  let tab;
  before(async () => {
    server = await startServer();
    chrome = await launch(browser);
    tab = await openTab(chrome);
    await installPanel(tab);
  });
  after(async () => {
    await chrome?.close();
    await server?.close();
  });

  const log = () => tab.evaluate("window.__log");
  const clearLog = () => tab.evaluate("window.__log.length = 0");
  const press = async (spec, extra, on = tab) => {
    await Promise.all(on.session.sendBatch(keyPress(spec, extra)));
    await on.barrier();
  };
  const copyKey = (command = "copy", on = tab) => press(charKey(command === "cut" ? "x" : "c"), { modifiers: ["Meta"], commands: [command] }, on);
  const pasteKey = (on = tab) => press(charKey("v"), { modifiers: ["Meta"], commands: ["paste"] }, on);
  const valueOf = (id, on = tab) => on.evaluate(`document.getElementById(${JSON.stringify(id)}).value`);
  // In the helper's world (the DOM is shared, the page's globals are not)…
  const run = (body, args = []) => tab.call(body, args);
  // …and in the page's own world, where the fixture's helpers and logs live.
  const inPage = (body, ...args) => tab.evaluate(`(${body})(...${JSON.stringify(args)})`);
  const mouse = (type, x, y, extra = {}) => ["Input.dispatchMouseEvent", { type, x, y, modifiers: 0, pointerType: "mouse", ...extra }];

  /** panel.html, the pointer parked on the empty body, the log empty. */
  async function fresh() {
    await tab.navigate(server.url("/panel.html"));
    await tab.session.send(...mouseMove(5, 780));
    await tab.barrier();
    await clearLog();
  }

  async function focusWith(id, text, selection) {
    await inPage(`function(id, text, selection) {
      const field = document.getElementById(id);
      field.value = text;
      field.focus();
      if (selection) field.setSelectionRange(selection[0], selection[1]);
      window.__log.length = 0;
    }`, id, text, selection ?? null);
  }

  // -------------------------------------------------------------- the script

  test("the Swift literals: the source parses, the call function is one line, no Swift escape inside", () => {
    assert.doesNotThrow(() => new Function(PANEL_SOURCE));
    assert.doesNotThrow(() => new Function(`return (${PANEL_FUNCTION});`));
    assert.equal(PANEL_FUNCTION.includes("\n"), false);
    // In a #"""…"""# literal, \# starts a Swift escape and """# ends it.
    for (const text of [PANEL_SOURCE, PANEL_FUNCTION]) {
      assert.equal(/\\#/.test(text), false, "no \\# in the literal");
      assert.equal(text.includes('"""#'), false);
    }
  });

  test("installed as the engine installs it: the helper's world, main frame only, invisible to the page, once", options(), async () => {
    await fresh();
    const world = await tab.world();
    const installed = await run(`function() {
      const d = Object.getOwnPropertyDescriptor(globalThis, "__loomPanel");
      return { enumerable: d.enumerable, writable: d.writable, frozen: Object.isFrozen(d.value),
        ops: Object.keys(d.value).sort(), version: d.value.version, helper: typeof globalThis.__loomAgent };
    }`);
    assert.deepEqual(installed, {
      enumerable: false, writable: false, frozen: true, version: 1, helper: "object",
      ops: ["caretRect", "chooseUserSelect", "firePaste", "hitInfo", "takeCopied", "version"],
    });
    // The page's own world sees nothing of it.
    assert.deepEqual(await tab.evaluate("[typeof __loomPanel, Object.getOwnPropertyNames(window).filter((name) => name.startsWith('__loom'))]"),
      ["undefined", []]);
    // Run twice (runImmediately on a world that has it): the same object stays.
    await run("function() { globalThis.__panelBefore = globalThis.__loomPanel; }");
    await tab.session.send("Runtime.evaluate", { expression: PANEL_SOURCE, contextId: world });
    assert.equal(await run("function() { return globalThis.__panelBefore === globalThis.__loomPanel; }"), true);
    // A same-origin frame's own world: no panel (window !== top).
    const { frameTree } = await tab.session.send("Page.getFrameTree");
    const child = frameTree.childFrames[0].frame;
    const { executionContextId } = await tab.session.send("Page.createIsolatedWorld", { frameId: child.id, worldName: WORLD });
    assert.equal(await tab.call("function() { return typeof globalThis.__loomPanel; }", [], { contextId: executionContextId }), "undefined");
    assert.deepEqual(await panel(tab, "hitInfo", { x: 1, y: 1 }, { contextId: executionContextId }),
      { error: { code: "panelMissing", message: "the panel script is not loaded" } });
    assert.deepEqual(await panel(tab, "nope", {}), { error: { code: "invalid", message: "unknown op nope" } });
    assert.deepEqual(await panel(tab, "version", {}), { error: { code: "invalid", message: "unknown op version" } });
    assert.deepEqual(await panel(tab, "toString", {}), { error: { code: "invalid", message: "unknown op toString" } });
  });

  // -------------------------------------------------------------- hitInfo

  test("hitInfo: the CSS cursor under a point, and what auto means there (editable, link)", options(), async () => {
    await fresh();
    const at = async (selector) => panel(tab, "hitInfo", await tab.centerOf(selector));
    // Chromium's own style sheet already says text for fields and pointer for links.
    assert.deepEqual(await at("#field"), { cursor: "text", editable: true, link: false });
    assert.deepEqual(await at("#area"), { cursor: "text", editable: true, link: false });
    assert.deepEqual(await at("#password"), { cursor: "text", editable: true, link: false });
    assert.deepEqual(await at("#editor"), { cursor: "auto", editable: true, link: false });
    assert.deepEqual(await at("#link"), { cursor: "pointer", editable: false, link: true });
    assert.deepEqual(await at("#inner"), { cursor: "pointer", editable: false, link: true });
    assert.deepEqual(await at("#press"), { cursor: "pointer", editable: false, link: false });
    assert.deepEqual(await at("#grab"), { cursor: "grab", editable: false, link: false });
    assert.deepEqual(await at("#grabbed"), { cursor: "grab", editable: false, link: false }, "inherited");
    assert.deepEqual(await at("#nocursor"), { cursor: "crosshair", editable: false, link: false }, "url(…) dropped for its fallback");
    assert.deepEqual(await at("#scroller"), { cursor: "auto", editable: false, link: false });
    assert.deepEqual(await at("#custom"), { cursor: "auto", editable: false, link: false });
    assert.deepEqual(await panel(tab, "hitInfo", { x: -5, y: -5 }), { cursor: "auto", editable: false, link: false }, "outside the viewport");
    assert.deepEqual(await panel(tab, "hitInfo", {}), { error: { code: "invalid", message: "x and y must be numbers" } });
  });

  test("hitInfo pierces open shadow roots and same-origin frames", options(), async () => {
    await fresh();
    const host = await run("function() { const r = document.getElementById('host').getBoundingClientRect(); return { x: r.left, y: r.top + r.height / 2 }; }");
    assert.deepEqual(await panel(tab, "hitInfo", { x: host.x + 40, y: host.y }), { cursor: "pointer", editable: false, link: false }, "the shadow root's button");
    assert.deepEqual(await panel(tab, "hitInfo", { x: host.x + 140, y: host.y }), { cursor: "text", editable: true, link: false }, "the shadow root's field");
    const frame = await run("function() { const r = document.getElementById('frame').getBoundingClientRect(); return { x: r.left, y: r.top }; }");
    assert.deepEqual(await panel(tab, "hitInfo", { x: frame.x + 150, y: frame.y + 60 }), { cursor: "crosshair", editable: false, link: false }, "the frame's page");
    const field = await run(`function() {
      const frame = document.getElementById('frame');
      const box = frame.getBoundingClientRect();
      const r = frame.contentDocument.getElementById('inner-field').getBoundingClientRect();
      return { x: box.left + frame.clientLeft + r.left + 5, y: box.top + frame.clientTop + r.top + r.height / 2 };
    }`);
    assert.deepEqual(await panel(tab, "hitInfo", field), { cursor: "text", editable: true, link: false }, "a field in the frame");
  });

  test("hitInfo describes a native <select>: its rect, options with groups and disabled ones; none for appearance: base-select", options(), async () => {
    await fresh();
    const point = await tab.centerOf("#pick");
    const info = await panel(tab, "hitInfo", point);
    assert.deepEqual(info, {
      cursor: "default", editable: false, link: false,
      select: {
        rect: { x: 340, y: 40, width: 200, height: 30 },
        options: [
          { label: "Apple", value: "apple", disabled: false },
          { label: "Banana", value: "banana", disabled: true },
          { label: "Lemon", value: "lemon", disabled: false, group: "Citrus" },
          { label: "Lime green", value: "lime", disabled: false, group: "Citrus" },
          { label: "Kiwi", value: "kiwi", disabled: true, group: "Gone" },
          { label: "Pear (label)", value: "pear", disabled: false },
        ],
        selectedIndex: 0, multiple: false, disabled: false, size: 0, open: false,
      },
    });
    assert.equal("select" in await panel(tab, "hitInfo", { ...point, select: false }), false, "select: false leaves it out");
    // A customizable select draws its picker in the page: the press goes to the page.
    assert.equal("select" in await panel(tab, "hitInfo", await tab.centerOf("#fancy")), false);
  });

  // -------------------------------------------------------------- chooseUserSelect

  test("chooseUserSelect sets the option on hitInfo's <select> as selectOption does: focus, then input and change", options(), async () => {
    await fresh();
    const point = await tab.centerOf("#pick");
    await panel(tab, "hitInfo", point);
    assert.deepEqual(await panel(tab, "chooseUserSelect", { index: 3 }), { ok: true, changed: true, value: "lime", selectedIndex: 3 });
    assert.equal(await tab.evaluate("document.activeElement.id"), "pick");
    const events = (await log()).filter((e) => ["focus", "input", "change"].includes(e.type));
    assert.deepEqual(events.map((e) => [e.type, e.target, e.trusted]), [["focus", "pick", true], ["input", "pick", false], ["change", "pick", false]]);
    // The option already selected: nothing fires (Chromium's own menu does the same).
    await clearLog();
    assert.deepEqual(await panel(tab, "chooseUserSelect", { index: 3 }), { ok: true, changed: false, value: "lime", selectedIndex: 3 });
    assert.deepEqual((await log()).filter((e) => e.type === "change"), []);
    assert.equal((await panel(tab, "chooseUserSelect", { index: 1 })).error.code, "disabled", "a disabled option");
    assert.equal((await panel(tab, "chooseUserSelect", { index: 4 })).error.code, "disabled", "an option of a disabled group");
    assert.equal((await panel(tab, "chooseUserSelect", { index: 99 })).error.code, "invalid");
    // Re-rendered between the press and the choice: the <select> now at that point.
    await run("function() { const s = document.getElementById('pick'); const copy = s.cloneNode(true); copy.selectedIndex = 0; s.replaceWith(copy); }");
    assert.deepEqual(await panel(tab, "chooseUserSelect", { index: 5 }), { ok: true, changed: true, value: "pear", selectedIndex: 5 });
    // No <select> at the last point: the focused one, else none.
    await panel(tab, "hitInfo", await tab.centerOf("#press"));
    await run("function() { document.getElementById('pick').focus(); }");
    assert.deepEqual(await panel(tab, "chooseUserSelect", { index: 0 }), { ok: true, changed: true, value: "apple", selectedIndex: 0 });
    await run("function() { document.getElementById('field').focus(); }");
    assert.equal((await panel(tab, "chooseUserSelect", { index: 0 })).error.code, "noSelect");
  });

  // -------------------------------------------------------------- caretRect

  test("caretRect: an <input>'s caret where the page itself measures its text", options(), async () => {
    await fresh();
    assert.equal(await panel(tab, "caretRect"), null, "nothing focused");
    await focusWith("field", "");
    await tab.session.send("Input.insertText", { text: "abcdef" });
    const reference = (caret) => inPage(`function(caret) {
      const field = document.getElementById("field");
      const box = field.getBoundingClientRect();
      const style = getComputedStyle(field);
      return { x: box.left + field.clientLeft + parseFloat(style.paddingLeft) + window.__textWidth(style.font, field.value.slice(0, caret)),
        top: box.top, bottom: box.bottom };
    }`, caret);
    for (const caret of [6, 2, 0]) {
      await run("function(caret) { document.getElementById('field').setSelectionRange(caret, caret); }", [caret]);
      const rect = await panel(tab, "caretRect");
      const expected = await reference(caret);
      assert.ok(Math.abs(rect.x - expected.x) < 1, `caret ${caret}: x ${rect.x} ≈ ${expected.x}`);
      assert.ok(rect.y > expected.top && rect.y + rect.height < expected.bottom, `inside the field: ${JSON.stringify(rect)}`);
      assert.equal(rect.width, 0);
      assert.ok(rect.height >= 14 && rect.height <= 24, `a line's height: ${rect.height}`);
    }
  });

  test("caretRect: a <textarea>'s caret on its line, through a mirror the page only sees as a mutation", options(), async () => {
    await fresh();
    await focusWith("area", "line one\nline two\nthird", [14, 14]);
    await inPage("function() { window.__mutations = 0; new MutationObserver((records) => { window.__mutations += records.length; }).observe(document, { childList: true, subtree: true }); }");
    const rect = await panel(tab, "caretRect");
    // Nothing left behind; a MutationObserver of the whole document saw it come and go.
    await tab.barrier();
    assert.equal(await tab.evaluate("document.documentElement.childElementCount"), 2);
    assert.equal(await tab.evaluate("window.__mutations"), 2);
    const expected = await inPage(`function() {
      const area = document.getElementById("area");
      const box = area.getBoundingClientRect();
      const style = getComputedStyle(area);
      const char = window.__textWidth(style.font, "x");
      return { x: box.left + area.clientLeft + parseFloat(style.paddingLeft) + 5 * char,
        line: box.top + area.clientTop + parseFloat(style.paddingTop) + 20 };
    }`);
    assert.ok(Math.abs(rect.x - expected.x) < 1, `line 2, column 5: x ${rect.x} ≈ ${expected.x}`);
    assert.ok(rect.y >= expected.line && rect.y + rect.height <= expected.line + 20, `on line 2: ${JSON.stringify(rect)} from ${expected.line}`);
    // A long line wraps: the caret at the end is below the third line.
    await focusWith("area", "line one\nline two\nthird line that is long enough to wrap around");
    const wrapped = await panel(tab, "caretRect");
    assert.ok(wrapped.y >= expected.line + 40, `wrapped onto a fourth line: ${JSON.stringify(wrapped)}`);
  });

  test("caretRect: editable content, an open shadow root's field, a same-origin frame's field", options(), async () => {
    await fresh();
    await run("function() { document.getElementById('editor').focus(); }");
    const box = await run("function() { const e = document.getElementById('editor'); const r = e.getBoundingClientRect(); return { left: r.left + e.clientLeft + 4, top: r.top + e.clientTop + 4 }; }");
    const empty = await panel(tab, "caretRect");
    assert.deepEqual([PAGE_ROUND(empty.x), PAGE_ROUND(empty.y), empty.width], [box.left, box.top, 0], "an empty block: its content start");
    await tab.session.send("Input.insertText", { text: "hello" });
    const typed = await panel(tab, "caretRect");
    const width = await tab.evaluate("window.__textWidth(getComputedStyle(document.getElementById('editor')).font, 'hello')");
    assert.ok(Math.abs(typed.x - (box.left + width)) < 1, `after "hello": ${typed.x} ≈ ${box.left + width}`);
    assert.ok(typed.height > 0);
    // Inside an open shadow root.
    await run("function() { document.getElementById('host').shadowRoot.getElementById('shadow-field').focus(); }");
    const shadow = await panel(tab, "caretRect");
    const shadowBox = await run("function() { const r = document.getElementById('host').shadowRoot.getElementById('shadow-field').getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }; }");
    assert.ok(shadow.x >= shadowBox.left && shadow.x <= shadowBox.right && shadow.y >= shadowBox.top && shadow.y <= shadowBox.bottom, JSON.stringify({ shadow, shadowBox }));
    // A same-origin frame: in the main frame's CSS px.
    await run("function() { document.getElementById('frame').contentDocument.getElementById('inner-field').focus(); }");
    await tab.session.send("Input.insertText", { text: "fr" });
    const framed = await panel(tab, "caretRect");
    const frameBox = await run(`function() {
      const frame = document.getElementById("frame");
      const outer = frame.getBoundingClientRect();
      const r = frame.contentDocument.getElementById("inner-field").getBoundingClientRect();
      return { left: outer.left + frame.clientLeft + r.left, top: outer.top + frame.clientTop + r.top, bottom: outer.top + frame.clientTop + r.bottom };
    }`);
    assert.ok(framed.x > frameBox.left && framed.x < frameBox.left + 60, JSON.stringify({ framed, frameBox }));
    assert.ok(framed.y >= frameBox.top && framed.y <= frameBox.bottom, JSON.stringify({ framed, frameBox }));
    await run("function() { document.activeElement.blur(); }");
    assert.equal(await panel(tab, "caretRect"), null);
  });

  // -------------------------------------------------------------- the clipboard

  test("T-clip: Chromium's copy command round-trips to its paste command; the page's copy and paste are trusted",
    options({ skip: CLIPBOARD_SKIP }), async (t) => {
      await fresh();
      await focusWith("field", "copied text");
      await press(charKey("a"), { modifiers: ["Meta"], commands: ["selectAll"] });
      await copyKey();
      await focusWith("q", "");
      await pasteKey();
      assert.equal(await valueOf("q"), "copied text");
      const clip = (await log()).filter((e) => ["copy", "paste"].includes(e.type));
      assert.deepEqual(clip.map((e) => [e.type, e.target, e.trusted]), [["paste", "q", true]]);
      // A password field: no copy event at all, the clipboard keeps what it had.
      await focusWith("password", "secret");
      await press(charKey("a"), { modifiers: ["Meta"], commands: ["selectAll"] });
      await copyKey();
      assert.deepEqual((await log()).filter((e) => e.type === "copy"), []);
      await focusWith("q", "");
      await pasteKey();
      assert.equal(await valueOf("q"), "copied text");
      if (!darwin) return;
      // The Mac: does Chromium's clipboard write or read NSPasteboard? Recorded, not asserted.
      const saved = pbpaste();
      try {
        pbcopy("loom-sentinel");
        await focusWith("field", "copied on the Mac");
        await press(charKey("a"), { modifiers: ["Meta"], commands: ["selectAll"] });
        await copyKey();
        const afterCopy = pbpaste();
        t.diagnostic(`T-clip mac ${browser.kind}: a copy command ${afterCopy === "copied on the Mac" ? "WRITES" : "does not write"} NSPasteboard (it holds ${JSON.stringify(afterCopy)})`);
        pbcopy("from the Mac pasteboard");
        await focusWith("q", "");
        await pasteKey();
        const pasted = await valueOf("q");
        t.diagnostic(`T-clip mac ${browser.kind}: a paste command ${pasted === "from the Mac pasteboard" ? "READS" : "does not read"} NSPasteboard (pasted ${JSON.stringify(pasted)})`);
      } finally {
        if (saved !== null) pbcopy(saved);
      }
    });

  test("takeCopied: what Chromium copied — the selection, or the page's own data when it cancels — once", options({ skip: CLIPBOARD_SKIP }), async () => {
    await fresh();
    assert.equal(await panel(tab, "takeCopied"), null, "nothing yet");
    // A field's selection: read as soon as the key's acks are in, no barrier.
    await focusWith("field", "copied text", [0, 6]);
    await Promise.all(tab.session.sendBatch(keyPress(charKey("c"), { modifiers: ["Meta"], commands: ["copy"] })));
    const taken = await panel(tab, "takeCopied");
    assert.equal(taken.text, "copied");
    assert.equal(taken.type, "copy");
    assert.ok(taken.ageMs >= 0 && taken.ageMs < 1000, `ageMs ${taken.ageMs}`);
    assert.equal(await panel(tab, "takeCopied"), null, "taken once");
    // Each paragraph, then Chromium's own paste: takeCopied has what the clipboard got.
    const cases = {
      custom: "custom:Custom copy text", // the page set data and cancelled
      loose: "Loose copy text", // data set without preventDefault: ignored by Chromium too
      late: "late:Late copy text", // a window listener the page added after the panel's
      plain: "Plain copy text",
    };
    for (const [id, expected] of Object.entries(cases)) {
      await inPage("function(id) { document.activeElement.blur(); window.__select(id); }", id);
      await copyKey();
      const copied = await panel(tab, "takeCopied");
      await focusWith("q", "");
      await pasteKey();
      assert.deepEqual([copied?.text, await valueOf("q")], [expected, expected], id);
    }
    // A cut: the text before it goes.
    await focusWith("area", "cut me please", [4, 7]);
    await copyKey("cut");
    assert.deepEqual(await panel(tab, "takeCopied").then(({ text, type }) => ({ text, type })), { text: "me ", type: "cut" });
    assert.equal(await valueOf("area"), "cut please");
    await run(`function() {
      const editor = document.getElementById("editor");
      editor.textContent = "cut this word";
      editor.focus();
      const range = document.createRange();
      range.setStart(editor.firstChild, 4);
      range.setEnd(editor.firstChild, 9);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
    }`);
    await copyKey("cut");
    assert.equal((await panel(tab, "takeCopied")).text, "this ");
    assert.equal(await tab.evaluate("document.getElementById('editor').textContent"), "cut word");
    // A field inside an open shadow root: its own selection.
    await run("function() { const field = document.getElementById('host').shadowRoot.getElementById('shadow-field'); field.value = 'in the shadow'; field.focus(); field.setSelectionRange(7, 13); }");
    await copyKey();
    assert.equal((await panel(tab, "takeCopied")).text, "shadow");
    // A password field: Chromium dispatches no copy at all.
    await focusWith("password", "secret", [0, 6]);
    await copyKey();
    assert.equal(await panel(tab, "takeCopied"), null);
    // The page's own document.execCommand("copy") dispatches a trusted copy too.
    await tab.evaluate("(() => { window.__select('custom'); document.execCommand('copy'); })()", { userGesture: true });
    assert.equal((await panel(tab, "takeCopied")).text, "custom:Custom copy text");
    // An untrusted copy event the page makes is no copy.
    await tab.evaluate("document.dispatchEvent(new ClipboardEvent('copy', { bubbles: true }))");
    assert.equal(await panel(tab, "takeCopied"), null);
  });

  test("the clipboard data is readable in a microtask of the copy event, not after it (why takeCopied reads it there)",
    options({ skip: CLIPBOARD_SKIP }), async () => {
      await fresh();
      await tab.evaluate(`document.getElementById("custom").addEventListener("copy", (event) => {
        const data = event.clipboardData;
        window.__reads = [];
        queueMicrotask(() => window.__reads.push(["microtask", data.getData("text/plain")]));
        setTimeout(() => window.__reads.push(["timeout", data.getData("text/plain"), event.defaultPrevented]), 0);
      })`);
      await inPage("function() { window.__select('custom'); }");
      await copyKey();
      await tab.barrier();
      assert.deepEqual(await tab.evaluate("window.__reads"), [["microtask", "custom:Custom copy text"], ["timeout", "", true]]);
    });

  test("Chromium's clipboard is one per browser process: a copy in one browser context pastes in another", options({ skip: CLIPBOARD_SKIP }), async () => {
    await fresh();
    const other = await contextTab(chrome);
    try {
      await other.navigate(server.url("/panel.html"));
      await focusWith("field", "from context A");
      await press(charKey("a"), { modifiers: ["Meta"], commands: ["selectAll"] });
      await copyKey();
      await other.evaluate("document.getElementById('q').focus()");
      await pasteKey(other);
      assert.equal(await valueOf("q", other), "from context A");
    } finally {
      await other.close();
      await chrome.conn.send("Target.disposeBrowserContext", { browserContextId: other.browserContextId }).catch(() => {});
    }
  });

  test("firePaste: an untrusted, cancelable, composed paste on the focused element; not cancelled, Input.insertText types it", options(), async () => {
    await fresh();
    await focusWith("field", "");
    assert.deepEqual(await panel(tab, "firePaste", { text: "pasted!" }), { cancelled: false });
    assert.deepEqual(await tab.evaluate("window.__pastes"), [{ target: "field", text: "pasted!", trusted: false, composed: true, cancelable: true }]);
    assert.equal(await valueOf("field"), "", "an untrusted paste inserts nothing itself");
    await tab.session.send("Input.insertText", { text: "pasted!" });
    assert.equal(await valueOf("field"), "pasted!");
    // A page that takes the paste for itself cancels it.
    await focusWith("otp", "");
    assert.deepEqual(await panel(tab, "firePaste", { text: "ab12" }), { cancelled: true });
    assert.equal(await valueOf("otp"), "AB12");
    // In an open shadow root: dispatched on the inner field (the document sees its host).
    await inPage(`function() {
      window.__pastes.length = 0;
      const field = document.getElementById("host").shadowRoot.getElementById("shadow-field");
      field.addEventListener("paste", () => { window.__innerPaste = true; }, { once: true });
      field.focus();
    }`);
    assert.deepEqual(await panel(tab, "firePaste", { text: "s" }), { cancelled: false });
    assert.equal(await tab.evaluate("window.__pastes[0].target"), "host");
    assert.equal(await tab.evaluate("window.__innerPaste"), true, "the field itself got it");
    // Nothing focused: the body.
    await inPage("function() { window.__pastes.length = 0; document.activeElement.blur(); }");
    await panel(tab, "firePaste", { text: "b" });
    assert.equal(await tab.evaluate("window.__pastes[0].target"), "body");
  });

  // -------------------------------------------------------------- the mouse

  test("T-leave: a move to (-1, -1) after a hover fires the out and leave events up to the document, and :hover clears", options(), async () => {
    await fresh();
    const link = await tab.centerOf("#link");
    await tab.session.send(...mouseMove(link.x, link.y));
    await tab.barrier();
    assert.equal(await tab.evaluate("getComputedStyle(document.getElementById('link')).color"), "rgb(1, 2, 3)");
    await clearLog();
    await tab.session.send(...mouseMove(-1, -1));
    await tab.barrier();
    const events = (await log()).map((e) => `${e.type}@${e.target}`);
    assert.deepEqual(events, [
      "pointerout@inner", "pointerleave@inner", "pointerleave@link", "pointerleave@body", "pointerleave@html", "pointerleave@#document",
      "mouseout@inner", "mouseleave@inner", "mouseleave@link", "mouseleave@body", "mouseleave@html", "mouseleave@#document",
    ]);
    assert.ok((await log()).every((e) => e.trusted));
    assert.equal(await tab.evaluate("document.getElementById('link').matches(':hover')"), false);
    assert.equal(await tab.evaluate("getComputedStyle(document.getElementById('link')).color"), "rgb(0, 0, 238)");
    // Already so when the move's reply arrives.
    await tab.session.send(...mouseMove(link.x, link.y));
    await tab.session.send(...mouseMove(-1, -1));
    assert.equal(await tab.evaluate("document.getElementById('link').matches(':hover')"), false);
  });

  test("a click is trusted with pointerType mouse; :hover is computed under the pointer", options(), async () => {
    await fresh();
    const link = await tab.centerOf("#link");
    await Promise.all(tab.click(link.x, link.y));
    await tab.barrier();
    const events = (await log()).filter((e) => e.target === "inner" && !["focus", "blur"].includes(e.type));
    assert.deepEqual(events.map((e) => e.type), [
      "pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove",
      "pointerdown", "mousedown", "pointerup", "mouseup", "click",
    ]);
    assert.ok(events.every((e) => e.trusted));
    assert.ok(events.filter((e) => e.type.startsWith("pointer") || e.type === "click").every((e) => e.pointerType === "mouse"));
    assert.equal(await tab.evaluate("getComputedStyle(document.getElementById('link')).color"), "rgb(1, 2, 3)");
    assert.equal(await tab.evaluate("location.hash"), "#linked");
  });

  test("buttons on a drag: 1, 3 with a second button down, back to 1; a drag that leaves the viewport is still released", options(), async (t) => {
    await fresh();
    const { x, y } = await tab.centerOf("#grab");
    await tab.session.send(...mouseMove(x, y));
    await clearLog();
    // One write each, as the pump sends them (one move in flight): Chromium
    // coalesces moves that arrive together.
    const send = async (commands) => {
      for (const command of commands) await tab.session.send(...command);
      await tab.barrier();
    };
    await send([
      mouse("mousePressed", x, y, { button: "left", buttons: 1, clickCount: 1 }),
      mouse("mouseMoved", x + 10, y, { button: "left", buttons: 1 }),
      mouse("mousePressed", x + 10, y, { button: "right", buttons: 3, clickCount: 1 }),
      mouse("mouseMoved", x + 20, y, { button: "left", buttons: 3 }),
      mouse("mouseReleased", x + 20, y, { button: "right", buttons: 1, clickCount: 1 }),
      mouse("mouseMoved", x + 30, y, { button: "left", buttons: 1 }),
      mouse("mouseReleased", x + 30, y, { button: "left", buttons: 0, clickCount: 1 }),
    ]);
    const events = (await log()).filter((e) => /^mouse(down|move|up)$/.test(e.type));
    assert.deepEqual(events.map((e) => `${e.type}@${e.target}:${e.button}:${e.buttons}`), [
      "mousedown@grab:0:1", "mousemove@grab:0:1", "mousedown@grab:2:3", "mousemove@grab:0:3", "mouseup@grab:2:1",
      "mousemove@grab:0:1", "mouseup@grab:0:0",
    ]);
    assert.ok(events.every((e) => e.trusted));
    const pointer = (await log()).filter((e) => /^pointer(down|move|up)$/.test(e.type));
    assert.deepEqual(pointer.map((e) => `${e.type}:${e.buttons}`), [
      "pointerdown:1", "pointermove:1", "pointermove:3", "pointermove:3", "pointermove:1", "pointermove:1", "pointerup:0",
    ], "a second button going down or up is a pointermove");
    // Out of the viewport with the button held (unclamped), released out there.
    await clearLog();
    await send([
      mouse("mousePressed", x, y, { button: "left", buttons: 1, clickCount: 1 }),
      mouse("mouseMoved", x + 30, y, { button: "left", buttons: 1 }),
      mouse("mouseMoved", -50, -50, { button: "left", buttons: 1 }),
      mouse("mouseReleased", -50, -50, { button: "left", buttons: 0, clickCount: 1 }),
    ]);
    const outside = (await log()).filter((e) => /^(mouse(down|move|up|leave)|click)$/.test(e.type)).map((e) => `${e.type}@${e.target}:${e.buttons}`);
    t.diagnostic(`drag outside ${browser.kind}: ${outside.join(" ")}`);
    assert.ok(outside.includes("mouseleave@grab:1"), "the page sees the pointer leave, the button held");
    assert.deepEqual(outside.slice(-2), ["mouseup@html:0", "click@html:0"], "and the release, on the root");
  });

  test("dragging a link is HTML5 drag and drop: dragstart … dragend and no mouseup; with Input.setInterceptDrags, dragCancel ends it", options(), async () => {
    for (const intercept of [false, true]) {
      await fresh();
      await tab.evaluate("for (const type of ['dragstart', 'drag', 'dragend', 'drop']) document.addEventListener(type, (e) => window.__log.push({ type, target: e.target.id, trusted: e.isTrusted }), true)");
      await tab.session.send("Input.setInterceptDrags", { enabled: intercept });
      const intercepted = tab.session.collect("Input.dragIntercepted");
      try {
        const link = await tab.centerOf("#link");
        await tab.session.send(...mouseMove(link.x, link.y));
        await clearLog();
        for (const command of [
          mouse("mousePressed", link.x, link.y, { button: "left", buttons: 1, clickCount: 1 }),
          mouse("mouseMoved", link.x + 60, link.y + 60, { button: "left", buttons: 1 }),
          mouse("mouseMoved", link.x + 80, link.y + 80, { button: "left", buttons: 1 }),
          mouse("mouseReleased", link.x + 80, link.y + 80, { button: "left", buttons: 0, clickCount: 1 }),
        ]) await tab.session.send(...command);
        await tab.barrier();
        const types = (await log()).filter((e) => /^(drag|drop|mouseup|click)/.test(e.type)).map((e) => e.type);
        if (!intercept) {
          assert.equal(intercepted.length, 0);
          assert.equal(types[0], "dragstart");
          assert.equal(types.at(-1), "dragend", "headless ends the drag on the release by itself");
          assert.deepEqual(types.filter((type) => ["mouseup", "click", "drop"].includes(type)), [], "no mouseup, no click, no drop");
        } else {
          assert.deepEqual(types, ["dragstart"], "the drag waits for CDP");
          assert.equal(intercepted.length, 1);
          assert.deepEqual(intercepted[0].data.items.map((item) => item.mimeType).sort(), ["text/html", "text/plain", "text/uri-list"]);
          await tab.session.send("Input.dispatchDragEvent", { type: "dragCancel", x: link.x + 80, y: link.y + 80, data: intercepted[0].data });
          await tab.barrier();
          assert.equal((await log()).filter((e) => /^drag/.test(e.type)).at(-1).type, "dragend");
        }
        // The mouse works again at once.
        const press = await tab.centerOf("#press");
        await clearLog();
        await Promise.all(tab.click(press.x, press.y));
        await tab.barrier();
        assert.deepEqual((await log()).filter((e) => ["mousedown", "mouseup", "click"].includes(e.type)).map((e) => `${e.type}@${e.target}`),
          ["mousedown@press", "mouseup@press", "click@press"]);
      } finally {
        intercepted.stop();
        await tab.session.send("Input.setInterceptDrags", { enabled: false });
      }
    }
  });

  test("clickCount 2 is a double click (dblclick, detail 2; a word selected in a field), in one write or two", options(), async () => {
    await fresh();
    const { x, y } = await tab.centerOf("#press");
    await tab.session.send(...mouseMove(x, y));
    await clearLog();
    await Promise.all(tab.session.sendBatch(mousePress(x, y)));
    await Promise.all(tab.session.sendBatch(mousePress(x, y, { clickCount: 2 })));
    await Promise.all(tab.session.sendBatch([...mousePress(x, y), ...mousePress(x, y, { clickCount: 2 })]));
    await tab.barrier();
    const clicks = (await log()).filter((e) => ["click", "dblclick"].includes(e.type)).map((e) => `${e.type}:${e.detail}`);
    assert.deepEqual(clicks, ["click:1", "click:2", "dblclick:2", "click:1", "click:2", "dblclick:2"]);
    await focusWith("field", "hello world", [0, 0]);
    const field = await tab.centerOf("#field");
    const left = await run("function() { const f = document.getElementById('field'); return f.getBoundingClientRect().left + f.clientLeft + 6 + 20; }");
    await Promise.all(tab.session.sendBatch([...mousePress(left, field.y), ...mousePress(left, field.y, { clickCount: 2 })]));
    await tab.barrier();
    assert.deepEqual(await tab.evaluate("[document.getElementById('field').selectionStart, document.getElementById('field').selectionEnd]"), [0, 5]);
  });

  test("⌃-click is forwarded as a left click with Control", options(), async (t) => {
    await fresh();
    const { x, y } = await tab.centerOf("#press");
    await tab.session.send(...mouseMove(x, y));
    await clearLog();
    await Promise.all(tab.session.sendBatch([
      mouse("mousePressed", x, y, { button: "left", buttons: 1, clickCount: 1, modifiers: 2 }),
      mouse("mouseReleased", x, y, { button: "left", buttons: 0, clickCount: 1, modifiers: 2 }),
    ]));
    await tab.barrier();
    const events = (await log()).filter((e) => ["mousedown", "click", "contextmenu"].includes(e.type)).map((e) => `${e.type}:${e.button}:${e.ctrl}`);
    if (darwin) {
      // Blink on a Mac may turn it into a context menu: recorded.
      t.diagnostic(`⌃-click mac ${browser.kind}: ${events.join(" ")}`);
      return;
    }
    assert.deepEqual(events, ["mousedown:0:true", "click:0:true"], "no contextmenu off the Mac");
  });

  // -------------------------------------------------------------- the wheel

  test("T-wheel: a mouseWheel scrolls by exactly deltaY CSS px, in one step at a later frame — never animated; fractions add up", options(), async (t) => {
    await fresh();
    const scroller = await tab.centerOf("#scroller");
    await tab.evaluate(`addEventListener("wheel", (e) => window.__wheels.push({ deltaY: e.deltaY, deltaMode: e.deltaMode, trusted: e.isTrusted }), { passive: true, capture: true })`);
    for (const [label, x, y, read] of [
      ["scroller", scroller.x, scroller.y, "document.getElementById('scroller').scrollTop"],
      ["document", 1100, 600, "scrollY"],
    ]) {
      await tab.session.send(...mouseMove(x, y));
      await tab.evaluate(`window.__samples = []; window.__wheels = [];
        (() => { const start = performance.now(); const tick = () => { window.__samples.push(${read}); if (performance.now() - start < 700) requestAnimationFrame(tick); }; requestAnimationFrame(tick); })()`);
      const sent = performance.now();
      await tab.session.send(...mouse("mouseWheel", x, y, { deltaX: 0, deltaY: 300 }));
      const atReply = await tab.evaluate(read);
      let landed = null;
      for (let i = 0; i < 100 && landed === null; i++) {
        if (await tab.evaluate(read) === 300) landed = performance.now() - sent;
        else await delay(5);
      }
      t.diagnostic(`T-wheel ${browser.kind} ${label}: ${atReply} when the reply arrived, 300 after ${landed?.toFixed(0)} ms`);
      assert.notEqual(landed, null, `${label} scrolled`);
      await delay(800);
      const samples = await tab.evaluate("window.__samples");
      assert.deepEqual([...new Set(samples)].filter((value) => value !== 0 && value !== 300), [], `${label}: no frame between 0 and 300: ${samples}`);
      assert.equal(await tab.evaluate(read), 300);
      assert.deepEqual(await tab.evaluate("window.__wheels"), [{ deltaY: 300, deltaMode: 0, trusted: true }]);
    }
    // Trackpad-sized fractions are kept, not rounded away; pipelined deltas add up.
    await tab.evaluate("scrollTo(0, 0)");
    const inner = await tab.centerOf("#scroller");
    for (const [count, delta, total] of [[10, 0.4, 4], [10, 1.5, 15], [6, 2.6667, 16]]) {
      await tab.evaluate("document.getElementById('scroller').scrollTop = 0");
      await tab.barrier();
      await Promise.all(tab.session.sendBatch(Array.from({ length: count }, () => mouse("mouseWheel", inner.x, inner.y, { deltaX: 0, deltaY: delta }))));
      let top = null;
      for (let i = 0; i < 100; i++) {
        top = await tab.evaluate("document.getElementById('scroller').scrollTop");
        if (top === total) break;
        await delay(10);
      }
      assert.equal(top, total, `${count} × ${delta}`);
    }
  });

  // -------------------------------------------------------------- a <select>

  test("T-select: a trusted press on a <select> focuses it and opens a popup that no frame shows", options(), async (t) => {
    // Its own browser: a popup left open, or a native menu blocking the browser, stays there.
    const own = await launch(browser);
    try {
      const page = await openTab(own);
      await installPanel(page);
      await page.navigate(server.url("/panel.html"));
      const point = await page.centerOf("#pick");
      const state = () => within(page.evaluate(`(() => {
        const select = document.getElementById("pick");
        let open = null;
        try { open = select.matches(":open"); } catch (error) { open = "unsupported"; }
        return { value: select.value, focused: document.activeElement === select, open };
      })()`), 3000, "no answer");
      const keyed = async () => (await page.evaluate("window.__log")).filter((e) => !/^(pointer|mouse)/.test(e.type));
      // The screencast, in PNG: the latest frame before and after the press.
      let latest = null;
      let frames = 0;
      const stopFrames = page.session.on("Page.screencastFrame", (frame) => {
        latest = frame;
        frames++;
        page.session.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
      });
      await page.session.send("Page.startScreencast", { format: "png", everyNthFrame: 1 });
      for (let i = 0; i < 100 && !latest; i++) await delay(10);
      await delay(150);
      const before = latest;
      await page.evaluate("window.__log.length = 0");
      const replied = await within(Promise.all(page.click(point.x, point.y)).then(() => true), 5000, false);
      t.diagnostic(`T-select ${browser.kind}: press and release ${replied ? "answered" : "NOT answered in 5 s"}`);
      if (darwin && !replied) return;
      assert.equal(replied, true);
      await within(page.barrier(), 3000);
      await delay(300);
      const opened = await state();
      const hit = await within(panel(page, "hitInfo", point), 3000, null);
      const framesAfter = frames;
      const after = latest;
      await page.session.send("Page.stopScreencast");
      stopFrames();
      // Below the <select>, where a popup would be drawn (the frame is in CSS px at scale 1).
      const region = { x: 330, y: 76, width: 220, height: 190 };
      const changed = before && after ? countChanged(decodePNG(Buffer.from(before.data, "base64")), decodePNG(Buffer.from(after.data, "base64")), region) : "no frame";
      t.diagnostic(`T-select ${browser.kind}: after the press ${JSON.stringify(opened)}, hitInfo open ${hit?.select?.open}, ${changed} pixels changed below it in the screencast (${framesAfter} frames)`);
      if (darwin) {
        const pressed = await within(Promise.all(page.session.sendBatch(keyPress(KEYS.ArrowDown))).then(() => true), 3000, false);
        t.diagnostic(`T-select mac ${browser.kind}: ArrowDown ${pressed ? "answered" : "not answered"}, then ${JSON.stringify(await state())}`);
        return;
      }
      assert.deepEqual(opened, { value: "apple", focused: true, open: true });
      assert.equal(hit.select.open, true, "hitInfo tells the popup is open");
      assert.equal(changed, 0, "no screencast frame shows the popup");
      assert.deepEqual((await keyed()).map((e) => `${e.type}@${e.target}`), ["focus@pick", "click@pick"]);
      // The keys go to the invisible popup: ArrowDown moves its highlight (past the disabled
      // option) and the page sees no key; Enter picks it, with trusted input, change and click.
      await page.evaluate("window.__log.length = 0");
      for (let i = 0; i < 2; i++) await Promise.all(page.session.sendBatch(keyPress(KEYS.ArrowDown)));
      await page.barrier();
      assert.deepEqual(await state(), { value: "apple", focused: true, open: true });
      assert.deepEqual(await keyed(), []);
      await Promise.all(page.session.sendBatch(keyPress(KEYS.Enter)));
      await page.barrier();
      assert.deepEqual(await state(), { value: "lime", focused: true, open: false });
      assert.deepEqual((await keyed()).map((e) => `${e.type}:${e.trusted}`), ["input:true", "change:true", "click:true", "keyup:true"]);
      // Open again: Escape closes it, and the page sees only its keyup.
      await Promise.all(page.click(point.x, point.y));
      await page.barrier();
      assert.equal((await state()).open, true);
      await page.evaluate("window.__log.length = 0");
      await Promise.all(page.session.sendBatch(keyPress(KEYS.Escape, { commands: ["cancelOperation"] })));
      await page.barrier();
      assert.deepEqual(await state(), { value: "lime", focused: true, open: false });
      assert.deepEqual((await keyed()).map((e) => e.type), ["keyup"]);
      // Open again: a click where the popup would be closes it and lands on the page under it.
      await Promise.all(page.click(point.x, point.y));
      await page.barrier();
      await page.evaluate("window.__log.length = 0");
      await Promise.all(page.click(point.x, point.y + 60));
      await page.barrier();
      assert.deepEqual(await state(), { value: "lime", focused: false, open: false });
      assert.deepEqual((await page.evaluate("window.__log")).filter((e) => ["mousedown", "click", "change"].includes(e.type)).map((e) => `${e.type}@${e.target}`),
        ["mousedown@body", "click@body"]);
      // The panel's own choice does not close a popup a press opened; a screenshot does.
      await Promise.all(page.click(point.x, point.y));
      await page.barrier();
      await panel(page, "hitInfo", point);
      assert.deepEqual(await panel(page, "chooseUserSelect", { index: 5 }), { ok: true, changed: true, value: "pear", selectedIndex: 5 });
      assert.equal((await state()).open, true);
      await page.session.send("Page.captureScreenshot", { format: "png", clip: { ...region, scale: 1 } });
      assert.equal((await state()).open, false, "Page.captureScreenshot closes it");
    } finally {
      await own.close();
    }
  });

  // -------------------------------------------------------------- the keyboard

  test("IME: imeSetComposition('^') then insertText('ê') gives trusted composition events, no key event, and ê; an empty composition cancels", options(), async () => {
    await fresh();
    const composition = ["compositionstart", "compositionupdate", "compositionend", "beforeinput", "input"];
    for (const id of ["field", "editor"]) {
      await inPage("function(id) { document.getElementById(id).focus(); window.__log.length = 0; }", id);
      await tab.session.send("Input.imeSetComposition", { text: "^", selectionStart: 1, selectionEnd: 1 });
      const marked = await tab.evaluate(`(() => { const e = document.getElementById(${JSON.stringify(id)}); return e.value ?? e.textContent; })()`);
      await tab.session.send("Input.insertText", { text: "ê" });
      await tab.barrier();
      const events = (await log()).filter((e) => !/^(pointer|mouse)/.test(e.type));
      // compositionend is the one untrusted event: Blink dispatches it so, whatever ends the composition.
      assert.deepEqual(events.map((e) => [e.type, e.inputType, e.data, e.trusted]), [
        ["compositionstart", null, "", true], ["compositionupdate", null, "^", true],
        ["beforeinput", "insertCompositionText", "^", true], ["input", "insertCompositionText", "^", true],
        ["compositionupdate", null, "ê", true],
        ["beforeinput", "insertCompositionText", "ê", true], ["input", "insertCompositionText", "ê", true],
        ["compositionend", null, "ê", false],
      ], id);
      assert.ok(events.every((e) => composition.includes(e.type)), "no keydown or keyup");
      assert.ok(events.filter((e) => e.type === "input").every((e) => e.isComposing), "input events while composing");
      assert.equal(marked, "^", "the marked text is in the field meanwhile");
      assert.equal(await tab.evaluate(`(() => { const e = document.getElementById(${JSON.stringify(id)}); return e.value ?? e.textContent; })()`), "ê");
    }
    // The agent takes over mid-composition: an empty composition removes the marked text.
    await focusWith("field", "ab", [2, 2]);
    await tab.session.send("Input.imeSetComposition", { text: "か", selectionStart: 1, selectionEnd: 1 });
    assert.equal(await valueOf("field"), "abか");
    await tab.session.send("Input.imeSetComposition", { text: "", selectionStart: 0, selectionEnd: 0 });
    await tab.barrier();
    assert.equal(await valueOf("field"), "ab");
    assert.deepEqual((await log()).filter((e) => e.type.startsWith("composition")).map((e) => [e.type, e.data]),
      [["compositionstart", ""], ["compositionupdate", "か"], ["compositionupdate", ""], ["compositionend", ""]]);
    // Focus moving away mid-composition commits the marked text (the page's own blur).
    await focusWith("field", "", [0, 0]);
    await tab.session.send("Input.imeSetComposition", { text: "^", selectionStart: 1, selectionEnd: 1 });
    await run("function() { document.getElementById('area').focus(); }");
    await tab.barrier();
    assert.equal(await valueOf("field"), "^");
    assert.deepEqual((await log()).filter((e) => ["compositionend", "change", "blur"].includes(e.type)).map((e) => `${e.type}:${e.data ?? ""}`),
      ["compositionend:^", "change:", "blur:"]);
    // A multi-step composition, and the caret rect moving with the marked text.
    await focusWith("area", "");
    const start = await panel(tab, "caretRect");
    await tab.session.send("Input.imeSetComposition", { text: "に", selectionStart: 1, selectionEnd: 1 });
    await tab.session.send("Input.imeSetComposition", { text: "にほ", selectionStart: 2, selectionEnd: 2 });
    const composing = await panel(tab, "caretRect");
    assert.ok(composing.x > start.x, `the caret follows the marked text: ${start.x} → ${composing.x}`);
    await tab.session.send("Input.insertText", { text: "日本" });
    assert.equal(await valueOf("area"), "日本");
  });

  test("Mac editing commands: AppKit's selector names run as Chromium commands, in place of the key's own action", options(), async () => {
    await fresh();
    const TEXT = "alpha beta\ngamma delta\nepsilon";
    const F20 = { key: "F20", code: "F20", keyCode: 131 };
    const runCommand = async (command) => {
      await focusWith("area", TEXT, [17, 17]);
      await press(F20, { commands: [command] });
      return run("function(text) { const f = document.getElementById('area'); return [f.value === text ? '=' : f.value, f.selectionStart, f.selectionEnd]; }", [TEXT]);
    };
    // From line 2, column 6 ("gamma |delta"), monospace.
    const expected = {
      deleteBackward: ["alpha beta\ngammadelta\nepsilon", 16, 16],
      deleteForward: ["alpha beta\ngamma elta\nepsilon", 17, 17],
      deleteWordBackward: ["alpha beta\ndelta\nepsilon", 11, 11],
      deleteToBeginningOfLine: ["alpha beta\ndelta\nepsilon", 11, 11],
      deleteToEndOfParagraph: ["alpha beta\ngamma \nepsilon", 17, 17],
      moveLeft: ["=", 16, 16],
      moveUp: ["=", 6, 6],
      moveDown: ["=", 29, 29],
      moveToBeginningOfLine: ["=", 11, 11],
      moveToLeftEndOfLine: ["=", 11, 11],
      moveToBeginningOfParagraph: ["=", 11, 11],
      moveToEndOfLine: ["=", 22, 22],
      moveToRightEndOfLine: ["=", 22, 22],
      moveToEndOfParagraph: ["=", 22, 22],
      moveToBeginningOfDocument: ["=", 0, 0],
      moveToEndOfDocument: ["=", 30, 30],
      moveRightAndModifySelection: ["=", 17, 18],
      moveToLeftEndOfLineAndModifySelection: ["=", 11, 17],
      selectAll: ["=", 0, 30],
      // insert* as a command inserts: what the mapping drops (Playwright's rule).
      insertTab: ["alpha beta\ngamma \tdelta\nepsilon", 18, 18],
      insertNewline: ["alpha beta\ngamma \ndelta\nepsilon", 18, 18],
      // Unknown to Chromium: nothing happens.
      cancelOperation: ["=", 17, 17],
      noop: ["=", 17, 17],
      scrollPageDown: ["=", 17, 17],
    };
    const measured = {};
    for (const command of Object.keys(expected)) measured[command] = await runCommand(command);
    assert.deepEqual(measured, expected);
    // With the keys a Mac sends them: ⌥⌫, ⌘←, ⌘A.
    await focusWith("field", "Hello brave world", [17, 17]);
    await press(KEYS.Backspace, { modifiers: ["Alt"], commands: ["deleteWordBackward"] });
    assert.equal(await valueOf("field"), "Hello brave ");
    const down = (await log()).find((e) => e.type === "keydown" && e.key === "Backspace");
    assert.deepEqual([down.alt, down.trusted], [true, true]);
    assert.equal((await log()).find((e) => e.type === "beforeinput").inputType, "deleteWordBackward");
    await press(KEYS.ArrowLeft, { modifiers: ["Meta"], commands: ["moveToLeftEndOfLine"] });
    assert.deepEqual(await tab.evaluate("[document.getElementById('field').selectionStart, document.getElementById('field').selectionEnd]"), [0, 0]);
    await press(charKey("a"), { modifiers: ["Meta"], commands: ["selectAll"] });
    assert.deepEqual(await tab.evaluate("[document.getElementById('field').selectionStart, document.getElementById('field').selectionEnd]"), [0, 12]);
    // The command replaces the key's own action: one deletion, one move, one newline.
    await focusWith("field", "abc", [3, 3]);
    await press(KEYS.Backspace, { commands: ["deleteBackward"] });
    assert.equal(await valueOf("field"), "ab");
    await press(KEYS.ArrowLeft, { commands: ["moveLeft"] });
    assert.equal(await tab.evaluate("document.getElementById('field').selectionStart"), 1);
    await focusWith("area", "ab", [2, 2]);
    await press(KEYS.Enter, { commands: ["insertNewline"] });
    assert.equal(await valueOf("area"), "ab\n");
    // Undo and redo.
    await focusWith("area", "");
    await tab.session.send("Input.insertText", { text: "first" });
    await tab.session.send("Input.insertText", { text: " second" });
    await press(charKey("z"), { modifiers: ["Meta"], commands: ["undo"] });
    assert.equal(await valueOf("area"), "first");
    await press(charKey("z"), { modifiers: ["Meta", "Shift"], commands: ["redo"] });
    assert.equal(await valueOf("area"), "first second");
    // A command Chromium does not know leaves the key's own action: PageDown still scrolls.
    await run("function() { document.activeElement.blur(); scrollTo(0, 0); }");
    await press({ key: "PageDown", code: "PageDown", keyCode: 34 }, { commands: ["scrollPageDown"] });
    let scrolled = 0;
    for (let i = 0; i < 100 && scrolled === 0; i++) {
      scrolled = await tab.evaluate("scrollY");
      if (scrolled === 0) await delay(10);
    }
    assert.ok(scrolled > 0, "PageDown scrolled the page");
  });

  test("Enter as a keyDown with text \"\\r\" submits the form", options(), async () => {
    await fresh();
    await focusWith("q", "query");
    await press(KEYS.Enter);
    assert.equal(await tab.evaluate("window.__submits"), 1);
    const down = (await log()).find((e) => e.type === "keydown");
    assert.deepEqual([down.key, down.keyCode, down.trusted], ["Enter", 13, true]);
  });
});

/** Pixels (every other one) of `region` that differ between two decoded PNGs of one size. */
function countChanged(a, b, region = { x: 0, y: 0, width: a.width, height: a.height }) {
  let changed = 0;
  for (let y = region.y; y < Math.min(a.height, region.y + region.height); y += 2) {
    for (let x = region.x; x < Math.min(a.width, region.x + region.width); x += 2) {
      const p = a.pixel(x, y);
      const q = b.pixel(x, y);
      if (p[0] !== q[0] || p[1] !== q[1] || p[2] !== q[2]) changed++;
    }
  }
  return changed;
}

/** A tab in a new browser context of the same browser (another session's private context). */
async function contextTab(browser) {
  const router = await prepareBrowser(browser);
  const { browserContextId } = await browser.conn.send("Target.createBrowserContext", { disposeOnDetach: true });
  router.creating++;
  const created = await browser.conn.send("Target.createTarget", { url: "about:blank", browserContextId, newWindow: true });
  const attached = router.claimed.get(created.targetId)
    ?? await withTimeout(new Promise((resolve) => browser.conn.once(`claimed:${created.targetId}`, resolve)), 15_000, "the other context's tab");
  router.claimed.delete(created.targetId);
  const session = browser.conn.session(attached.sessionId, created.targetId);
  await Promise.all(session.sendBatch([
    ["Page.enable", {}],
    ["Page.setLifecycleEventsEnabled", { enabled: true }],
    ["Emulation.setFocusEmulationEnabled", { enabled: true }],
    ["Runtime.runIfWaitingForDebugger", {}],
  ]));
  const tab = new Tab(browser, session);
  tab.rebind = false;
  tab.browserContextId = browserContextId;
  const { frameTree } = await session.send("Page.getFrameTree");
  tab.frameId = frameTree.frame.id;
  return tab;
}

function pbpaste() {
  try { return execFileSync("pbpaste", { encoding: "utf8" }); } catch { return null; }
}

function pbcopy(text) {
  try { execFileSync("pbcopy", { input: text }); } catch { /* recorded as not written */ }
}
