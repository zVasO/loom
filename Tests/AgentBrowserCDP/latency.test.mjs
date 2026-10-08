// What each primitive of the engine costs on todo.html, idle, local: p50 and
// p90 over LOOM_CDP_SAMPLES runs (20 by default), printed for the record —
// compare a Mac with the step-0 numbers (design §4: click without snapshot
// p50 ≤ 40 ms, with snapshot p90 ≤ 120 ms). Only wide ceilings are asserted,
// so a loaded CI runner never fails here; a regression of an order of
// magnitude still does.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launch, performance } from "./lib/cdp.mjs";
import { keyPress, KEYS } from "./lib/input.mjs";
import { openTab } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { summary } from "./lib/stats.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const SAMPLES = Math.max(5, Number(process.env.LOOM_CDP_SAMPLES) || 20);
const WARMUP = 3;
const TWO_FRAMES = "function() { return new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(true)))); }";
const RECT = "function(selector) { const r = document.querySelector(selector).getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }";

async function measure(run) {
  for (let i = 0; i < WARMUP; i++) await run();
  const samples = [];
  for (let i = 0; i < SAMPLES; i++) {
    const started = performance.now();
    await run();
    samples.push(performance.now() - started);
  }
  return summary(samples);
}

eachBrowser((browser) => {
  let server;
  let chrome;
  let tab;
  const results = [];
  before(async () => {
    server = await startServer();
    chrome = await launch(browser);
    tab = await openTab(chrome, { url: server.url("/") });
  });
  after(async () => {
    await chrome?.close();
    await server?.close();
  });

  // name, ceiling for the p50 in ms, the primitive
  const PRIMITIVES = [
    ["Runtime.evaluate round trip", 100, () => tab.evaluate("1")],
    ["Page.createIsolatedWorld", 100, () => tab.session.send("Page.createIsolatedWorld", { frameId: tab.frameId, worldName: "loom-agent" })],
    ["helper snapshot (callFunctionOn)", 500, () => tab.helper("snapshot", { budget: 30000 })],
    ["barrier (setTimeout 0)", 150, () => tab.barrier()],
    ["two-rAF stability wait", 300, () => tab.call(TWO_FRAMES)],
    ["pipelined click, one write (acks)", 250, async () => {
      const { x, y } = await tab.call(RECT, ["#card"]);
      const started = performance.now();
      await Promise.all(tab.click(x, y));
      return performance.now() - started;
    }],
    ["click: 2-rAF prepare + write + barrier", 500, async () => {
      await tab.call(TWO_FRAMES);
      const { x, y } = await tab.call(RECT, ["#card"]);
      await Promise.all(tab.click(x, y));
      await tab.barrier();
    }],
    ["click, then the snapshot (no barrier)", 800, async () => {
      await tab.call(TWO_FRAMES);
      const { x, y } = await tab.call(RECT, ["#card"]);
      await Promise.all(tab.click(x, y));
      await tab.helper("snapshot", { budget: 30000 });
    }],
    ["Input.insertText, 20 characters", 150, () => tab.session.send("Input.insertText", { text: "twenty characters ok" })],
    ["Enter, keyDown + keyUp in one write", 150, () => Promise.all(tab.session.sendBatch(keyPress(KEYS.Enter)))],
    ["screenshot, viewport JPEG q80", 1500, () => tab.session.send("Page.captureScreenshot", { format: "jpeg", quality: 80, optimizeForSpeed: true })],
    ["Page.navigate + load (local page)", 2000, () => tab.navigate(server.url("/blank?latency"))],
  ];

  for (const [name, ceiling, run] of PRIMITIVES) {
    test(`${name}: p50 under ${ceiling} ms`, options(), async (t) => {
      if (name.startsWith("Page.navigate")) await tab.navigate(server.url("/blank"));
      else if (tab.url !== server.url("/")) await tab.navigate(server.url("/"));
      if (name.startsWith("Input.insertText") || name.startsWith("Enter")) {
        await tab.call("function() { const field = document.getElementById('new'); field.focus(); return true; }");
      }
      let own = [];
      const stats = name.startsWith("pipelined click")
        // The write and its acks only: the rectangle is measured apart.
        ? await (async () => {
          for (let i = 0; i < WARMUP; i++) await run();
          for (let i = 0; i < SAMPLES; i++) own.push(await run());
          return summary(own);
        })()
        : await measure(run);
      results.push([name, stats]);
      t.diagnostic(`p50 ${stats.p50} ms, p90 ${stats.p90} ms (min ${stats.min}, max ${stats.max}, n ${stats.n})`);
      assert.ok(stats.p50 < ceiling, `${name}: p50 ${stats.p50} ms`);
    });
  }

  test("a new tab: createTarget, the paused attach and the init burst: p50 under 3000 ms", options(), async (t) => {
    const stats = await measure(async () => {
      const fresh = await openTab(chrome);
      await fresh.close();
    });
    results.push(["new tab (createTarget + init)", stats]);
    t.diagnostic(`p50 ${stats.p50} ms, p90 ${stats.p90} ms`);
    assert.ok(stats.p50 < 3000);
  });

  test("the table", (t) => {
    const width = Math.max(...results.map(([name]) => name.length));
    t.diagnostic(`${browser.label}, ${chrome.version.product}, ${SAMPLES} samples, ${process.platform}`);
    for (const [name, stats] of results) t.diagnostic(`${name.padEnd(width)}  p50 ${String(stats.p50).padStart(8)}  p90 ${String(stats.p90).padStart(8)}`);
  });
});
