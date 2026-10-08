// Trusted clicks (feedback 2): Input.dispatchMouseEvent moved, pressed,
// released, sent in one write, reach the page as a real mouse would —
// isTrusted, the whole pointer-then-mouse sequence with pointerType "mouse",
// :hover computed, (hover: hover) and (pointer: fine) matching under Loom's
// --blink-settings; a double click counts 1 then 2; the right button opens
// the context menu; modifiers reach the page. When the release's ack
// arrives, the page has already run the click's handlers (a barrier is for
// what they defer). A click that opens confirm() gets its dialog while the
// release is still unanswered, and the page gets the answer Loom gives.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launch, settlesWithin } from "./lib/cdp.mjs";
import { mouseClick, mouseMove, mousePress } from "./lib/input.mjs";
import { openTab } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const POINTER_THEN_MOUSE = [
  "pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove",
  "pointerdown", "mousedown", "pointerup", "mouseup", "click",
];

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

  /** form.html, the pointer parked outside the target, the log empty. */
  async function freshForm() {
    await tab.navigate(server.url("/form.html"));
    await tab.session.send(...mouseMove(5, 5));
    await tab.evaluate("window.log.length = 0");
    return tab.centerOf("#target");
  }

  const log = () => tab.evaluate("window.log");

  test("a click is trusted: pointer then mouse events, pointerType mouse, the order a real mouse gives", options(), async () => {
    const { x, y } = await freshForm();
    const acks = tab.click(x, y);
    await Promise.all(acks);
    await tab.barrier();
    const events = await log();
    assert.deepEqual(events.map((e) => e.type), POINTER_THEN_MOUSE);
    assert.ok(events.every((e) => e.trusted), "isTrusted on every event");
    assert.ok(events.filter((e) => e.type.startsWith("pointer")).every((e) => e.pointerType === "mouse"));
    const click = events.find((e) => e.type === "click");
    assert.equal(click.detail, 1);
    assert.equal(click.button, 0);
    assert.equal(click.pointerType, "mouse", "click is a PointerEvent");
    assert.equal(events.find((e) => e.type === "mousedown").buttons, 1);
  });

  test("when the release's ack arrives, the page has run the click's handlers", options(), async () => {
    // Not so for a call sent in the click's own write: DevTools commands and
    // input reach the renderer by different channels.
    await tab.navigate(server.url("/"));
    const { x, y } = await tab.centerOf("#card");
    for (let run = 0; run < 5; run++) {
      await tab.evaluate("window.events.length = 0");
      await Promise.all(tab.click(x, y));
      assert.deepEqual(await tab.evaluate("window.events"), ["card"], `run ${run + 1}`);
    }
  });

  test(":hover is computed under the pointer; (hover: hover) and (pointer: fine) match", options(), async () => {
    const { x, y } = await freshForm();
    await tab.session.send(...mouseMove(x, y));
    await tab.barrier();
    const style = "getComputedStyle(document.getElementById('target')).backgroundColor";
    assert.equal(await tab.evaluate(style), "rgb(1, 2, 3)");
    assert.equal(await tab.evaluate("document.getElementById('target').matches(':hover')"), true);
    // The pointer leaving the view: there is no mouseLeave type, a move outside does it.
    await tab.session.send(...mouseMove(-1, -1));
    await tab.barrier();
    assert.equal(await tab.evaluate("document.getElementById('target').matches(':hover')"), false);
    assert.ok((await log()).some((e) => e.type === "mouseleave"), "mouseleave on the way out");
    assert.deepEqual(await tab.evaluate("[matchMedia('(hover: hover)').matches, matchMedia('(pointer: fine)').matches, matchMedia('(any-pointer: coarse)').matches]"),
      [true, true, false]);
  });

  test("a double click: the second pair after the first one's acks counts 2, then dblclick", options(), async () => {
    const { x, y } = await freshForm();
    await Promise.all(tab.click(x, y));
    await Promise.all(tab.session.sendBatch(mousePress(x, y, { clickCount: 2 })));
    await tab.barrier();
    const events = await log();
    assert.deepEqual(events.filter((e) => e.type === "click").map((e) => e.detail), [1, 2]);
    const dblclick = events.find((e) => e.type === "dblclick");
    assert.ok(dblclick, "dblclick fired");
    assert.equal(dblclick.detail, 2);
    assert.ok(events.every((e) => e.trusted));
  });

  test("the right button opens the context menu; a modifier reaches the page", options(), async () => {
    const { x, y } = await freshForm();
    await Promise.all(tab.click(x, y, { button: "right" }));
    await tab.barrier();
    const right = await log();
    const menu = right.find((e) => e.type === "contextmenu");
    assert.ok(menu, "contextmenu: " + right.map((e) => e.type).join(","));
    assert.equal(menu.button, 2);
    assert.equal(menu.trusted, true);
    assert.ok(!right.some((e) => e.type === "click"), "no click for the right button");
    await tab.evaluate("window.log.length = 0");
    await Promise.all(tab.click(x, y, { modifiers: 8 }));
    await tab.barrier();
    const click = (await log()).find((e) => e.type === "click");
    assert.deepEqual([click.shift, click.ctrl, click.alt, click.meta], [true, false, false, false]);
  });

  test("a pipelined click that opens confirm(): the dialog comes while the release waits; the page gets Loom's answer", options(), async () => {
    await tab.navigate(server.url("/dialogs.html"));
    const { x, y } = await tab.centerOf("#confirm");
    const opening = tab.session.waitForEvent("Page.javascriptDialogOpening");
    const [moved, pressed, released] = tab.click(x, y);
    const dialog = await opening;
    assert.equal(dialog.type, "confirm");
    assert.equal(dialog.message, "Delete it?");
    await Promise.all([moved, pressed]);
    assert.equal(await settlesWithin(released, 200), false, "mouseReleased is answered only once the dialog is");
    await tab.session.send("Page.handleJavaScriptDialog", { accept: true });
    await released;
    assert.deepEqual(await tab.evaluate("window.answers"), ["confirm:true"]);
  });

  test("the golden click is three Input.dispatchMouseEvent in one write", () => {
    assert.deepEqual(mouseClick(10, 20).map(([method, params]) => [method, params.type, params.button, params.buttons, params.clickCount]), [
      ["Input.dispatchMouseEvent", "mouseMoved", "none", 0, undefined],
      ["Input.dispatchMouseEvent", "mousePressed", "left", 1, 1],
      ["Input.dispatchMouseEvent", "mouseReleased", "left", 0, 1],
    ]);
  });
});
