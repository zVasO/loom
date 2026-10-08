// JavaScript dialogs against the engine's pipelined input (design §2.1, §7):
// - a click whose handler opens confirm(): on the wire, the dialog opens
//   BEFORE the release's reply, which only comes once
//   Page.handleJavaScriptDialog is answered — so the engine races the input
//   acks against Page.javascriptDialogOpening, never waits for them alone;
// - while a dialog is open the page answers nothing, helper calls included;
// - prompt() returns the text Loom gives;
// - beforeunload: Page.navigate after a user gesture raises a "beforeunload"
//   dialog (accepted, the navigation goes on; dismissed, the page stays);
//   Target.closeTarget never raises one.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launch, settle, settlesWithin, within } from "./lib/cdp.mjs";
import { openTab } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

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

  /** A trusted click on `selector`, the three events in one write; resolves once the dialog opens. */
  async function clickOpening(tab, selector) {
    const { x, y } = await tab.centerOf(selector);
    const opening = tab.session.waitForEvent("Page.javascriptDialogOpening");
    const acks = tab.click(x, y);
    const dialog = await opening;
    return { dialog, acks };
  }

  test("confirm() from a pipelined click: dialogOpening comes before the release's reply, which follows the answer", options(), async (t) => {
    const tab = await openTab(chrome, { url: server.url("/dialogs.html") });
    const orders = new Set();
    for (let run = 0; run < 6; run++) {
      const accept = run % 2 === 0;
      const wire = chrome.conn.startRecording();
      const { dialog, acks } = await clickOpening(tab, "#confirm");
      assert.equal(dialog.type, "confirm");
      const [moved, pressed, released] = acks;
      const handled = tab.session.send("Page.handleJavaScriptDialog", { accept });
      await Promise.all([handled, released]);
      chrome.conn.stopRecording();
      const position = (match) => wire.findIndex(match);
      const reply = (promise) => position((e) => e.dir === "reply" && e.id === promise.id);
      const event = (method) => position((e) => e.dir === "event" && e.method === method && e.sessionId === tab.session.id);
      const at = {
        moved: reply(moved), pressed: reply(pressed), opening: event("Page.javascriptDialogOpening"),
        closed: event("Page.javascriptDialogClosed"), handled: reply(handled), released: reply(released),
      };
      orders.add(Object.entries(at).filter(([, i]) => i >= 0).sort((a, b) => a[1] - b[1]).map(([name]) => name).join(" → "));
      // The press's reply may come before or after the dialog opens; the release's never before.
      assert.ok(at.opening < at.released, "the dialog opened while mouseReleased was pending");
      assert.ok(at.handled < at.released && at.closed < at.released, "mouseReleased answered after the dialog was");
    }
    t.diagnostic(`wire order: ${[...orders].join(" | ")}`);
    assert.deepEqual(await tab.evaluate("window.answers"), ["confirm:true", "confirm:false", "confirm:true", "confirm:false", "confirm:true", "confirm:false"]);
    await tab.close();
  });

  test("while an alert is open the page answers nothing, helper calls included", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/dialogs.html") });
    const { dialog, acks } = await clickOpening(tab, "#alert");
    assert.equal(dialog.type, "alert");
    assert.equal(dialog.message, "Saved");
    const evaluation = settle(tab.evaluate("1 + 1"));
    const helperCall = settle(tab.helper("pageInfo"));
    assert.equal(await settlesWithin(evaluation, 300), false, "Runtime.evaluate waits for the dialog");
    assert.equal(await settlesWithin(helperCall, 50), false, "so does a helper call");
    await tab.session.send("Page.handleJavaScriptDialog", { accept: true });
    await Promise.all(acks);
    const [answered, helped] = [await evaluation, await helperCall];
    assert.equal(answered.value, 2);
    assert.equal(typeof helped.value.scrollHeight, "number");
    assert.deepEqual(await tab.evaluate("window.answers"), ["alert closed"]);
    await tab.close();
  });

  test("prompt(): the page receives the text Loom answers with", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/dialogs.html") });
    const { dialog, acks } = await clickOpening(tab, "#prompt");
    assert.deepEqual([dialog.type, dialog.message, dialog.defaultPrompt], ["prompt", "Your name?", "nobody"]);
    await tab.session.send("Page.handleJavaScriptDialog", { accept: true, promptText: "Loom" });
    await Promise.all(acks);
    assert.deepEqual(await tab.evaluate("window.answers"), ["prompt:Loom"]);
    await tab.close();
  });

  test("beforeunload: Page.navigate after a user gesture raises it; accepted, the navigation goes on; dismissed, the page stays", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/dialogs.html") });
    const { x, y } = await tab.centerOf("#arm");
    await Promise.all(tab.click(x, y));
    assert.deepEqual(await tab.evaluate("window.answers"), ["armed"]);

    const dismissedOpening = tab.session.waitForEvent("Page.javascriptDialogOpening");
    const stayed = settle(tab.session.send("Page.navigate", { url: server.url("/blank?left"), transitionType: "typed" }));
    const asked = await dismissedOpening;
    assert.equal(asked.type, "beforeunload");
    await tab.session.send("Page.handleJavaScriptDialog", { accept: false });
    await within(stayed, 5000);
    assert.match(await tab.evaluate("location.pathname"), /dialogs\.html$/, "dismissed: still on the page");

    const opening = tab.session.waitForEvent("Page.javascriptDialogOpening");
    const navigation = settle(tab.navigate(server.url("/blank?left")));
    assert.equal((await opening).type, "beforeunload");
    await tab.session.send("Page.handleJavaScriptDialog", { accept: true });
    const outcome = await within(navigation, 10_000);
    assert.ok(outcome?.ok, "the navigation went on: " + (outcome?.error?.message ?? "no answer"));
    assert.equal(await tab.evaluate("location.search"), "?left");
    await tab.close();
  });

  test("Target.closeTarget raises no beforeunload, even after a user gesture", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/dialogs.html") });
    const { x, y } = await tab.centerOf("#arm");
    await Promise.all(tab.click(x, y));
    const dialog = settle(tab.session.waitForEvent("Page.javascriptDialogOpening", { timeout: 1500 }));
    const destroyed = chrome.conn.waitForEvent("Target.targetDestroyed", { predicate: (p) => p.targetId === tab.targetId, timeout: 5000 });
    await tab.close();
    await destroyed;
    assert.equal((await dialog).ok, false, "no dialog opened");
  });
});
