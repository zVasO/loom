// Trusted keys and text (feedback 2), as the engine sends them (lib/input.mjs):
// - Input.insertText reaches a framework-controlled input (todo.html's
//   React-style value tracker sees it), with trusted beforeinput and input;
// - Enter submits only as a keyDown carrying "\r" — the page reads
//   keydown Enter, keyCode 13 — and a rawKeyDown Enter submits nothing;
// - Tab and Shift+Tab move the focus natively, inserting nothing;
// - typing key by key, eight keys a write, types every character;
// - macOS editing commands ride on the key event (`commands`) and run on
//   any platform; the browser's own clipboard serves copy and paste.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launch } from "./lib/cdp.mjs";
import { charKey, keyPress, KEYS } from "./lib/input.mjs";
import { openTab } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

eachBrowser((browser) => {
  let server;
  let chrome;
  let tab;
  before(async () => {
    server = await startServer();
    chrome = await launch(browser);
    tab = await openTab(chrome);
  });
  after(async () => {
    await chrome?.close();
    await server?.close();
  });

  const press = async (spec, extra) => {
    await Promise.all(tab.session.sendBatch(keyPress(spec, extra)));
    await tab.barrier();
  };
  const focus = (id) => tab.call(`function(id) { document.getElementById(id).focus(); return document.activeElement.id; }`, [id]);
  const field = (id) => tab.evaluate(`(() => { const f = document.getElementById(${JSON.stringify(id)}); return { value: f.value, start: f.selectionStart, end: f.selectionEnd }; })()`);

  test("insertText reaches a React-style controlled input; Enter as keyDown \"\\r\" submits, keyCode 13", options(), async () => {
    await tab.navigate(server.url("/"));
    assert.equal(await focus("new"), "new");
    await tab.session.send("Input.insertText", { text: "milk" });
    assert.equal(await tab.evaluate("window.state.draft"), "milk", "the tracker saw the value");
    await press(KEYS.Enter);
    const state = await tab.evaluate("({ todos: window.state.todos.map((t) => t.text), events: window.events })");
    assert.deepEqual(state.todos, ["milk"]);
    assert.ok(state.events.includes("keydown:Enter:13"), JSON.stringify(state.events));
    assert.ok(state.events.includes("submit"));
  });

  test("a rawKeyDown Enter types nothing and submits nothing", options(), async () => {
    await tab.navigate(server.url("/"));
    await focus("new");
    await tab.session.send("Input.insertText", { text: "eggs" });
    await Promise.all(tab.session.sendBatch([
      ["Input.dispatchKeyEvent", { type: "rawKeyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 }],
      ["Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 }],
    ]));
    await tab.barrier();
    assert.deepEqual(await tab.evaluate("window.state.todos"), []);
    assert.ok(!(await tab.evaluate("window.events")).includes("submit"));
  });

  test("insertText fires trusted beforeinput and input, no key event; a key with text fires the whole trusted sequence", options(), async () => {
    await tab.navigate(server.url("/form.html"));
    await focus("user");
    await tab.evaluate("window.keyLog.length = 0");
    await tab.session.send("Input.insertText", { text: "ab" });
    await tab.barrier();
    const inserted = await tab.evaluate("window.keyLog");
    assert.deepEqual(inserted.map((e) => [e.type, e.inputType, e.trusted]), [["beforeinput", "insertText", true], ["input", "insertText", true]]);
    await tab.evaluate("window.keyLog.length = 0");
    await press(charKey("x"));
    const typed = await tab.evaluate("window.keyLog");
    assert.deepEqual(typed.map((e) => e.type), ["keydown", "keypress", "beforeinput", "input", "keyup"]);
    assert.ok(typed.every((e) => e.trusted));
    assert.equal(typed[0].key, "x");
    assert.equal(typed[0].keyCode, 88);
    assert.equal((await field("user")).value, "abx");
  });

  test("Enter in a plain form's field submits it (implicit submission)", options(), async () => {
    await tab.navigate(server.url("/form.html"));
    await focus("user");
    await tab.session.send("Input.insertText", { text: "ada" });
    await press(KEYS.Enter);
    assert.equal(await tab.evaluate("window.submits"), 1);
    const down = (await tab.evaluate("window.keyLog")).find((e) => e.type === "keydown" && e.key === "Enter");
    assert.deepEqual([down.keyCode, down.trusted], [13, true]);
  });

  test("Tab and Shift+Tab move the focus natively and insert nothing", options(), async () => {
    await tab.navigate(server.url("/form.html"));
    await focus("user");
    await press(KEYS.Tab);
    assert.equal(await tab.evaluate("document.activeElement.id"), "password");
    await press(KEYS.Tab, { modifiers: ["Shift"] });
    assert.equal(await tab.evaluate("document.activeElement.id"), "user");
    assert.equal((await field("user")).value, "", "no tab character typed");
  });

  test("typing key by key, eight keys a write, types every character", options(), async () => {
    await tab.navigate(server.url("/form.html"));
    await focus("area");
    const text = "Hello World 42";
    const keys = [...text].map(charKey);
    for (let i = 0; i < keys.length; i += 8) {
      const events = keys.slice(i, i + 8).flatMap((spec) => keyPress(spec));
      await Promise.all(tab.session.sendBatch(events));
    }
    await tab.barrier();
    assert.equal((await field("area")).value, text);
    const downs = (await tab.evaluate("window.keyLog")).filter((e) => e.type === "keydown" && e.key !== "Shift");
    assert.equal(downs.length, text.length);
    assert.ok(downs.every((e) => e.trusted));
  });

  test("macOS editing commands ride on the key: Meta+a selectAll, Alt+Backspace deleteWordBackward", options(), async () => {
    await tab.navigate(server.url("/form.html"));
    await focus("user");
    await tab.session.send("Input.insertText", { text: "Hello brave world" });
    await press(charKey("a"), { modifiers: ["Meta"], commands: ["selectAll"] });
    assert.deepEqual(await field("user"), { value: "Hello brave world", start: 0, end: 17 });
    await press(KEYS.ArrowLeft, { commands: ["moveToEndOfLine"] });
    assert.deepEqual(await field("user"), { value: "Hello brave world", start: 17, end: 17 });
    await press(KEYS.Backspace, { modifiers: ["Alt"], commands: ["deleteWordBackward"] });
    assert.equal((await field("user")).value, "Hello brave ");
  });

  test("copy and paste through the browser's own clipboard (Meta+C, Meta+V with their commands)",
    options({ skip: process.platform === "darwin" && process.env.LOOM_CDP_CLIPBOARD !== "1" && "it would write the Mac's pasteboard: LOOM_CDP_CLIPBOARD=1 to run it" }),
    async () => {
      await tab.navigate(server.url("/form.html"));
      await focus("user");
      await tab.session.send("Input.insertText", { text: "copied text" });
      await press(charKey("a"), { modifiers: ["Meta"], commands: ["selectAll"] });
      await press(charKey("c"), { modifiers: ["Meta"], commands: ["copy"] });
      await focus("area");
      await press(charKey("v"), { modifiers: ["Meta"], commands: ["paste"] });
      assert.equal((await field("area")).value, "copied text");
    });
});
