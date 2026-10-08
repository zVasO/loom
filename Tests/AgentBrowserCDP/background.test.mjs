// Pages keep running while nobody watches them (feedback 1): with two
// sessions' tabs in one Chromium and no screencast, each tab's rAF, CSS
// animations, IntersectionObserver, ResizeObserver and timers advance, each
// reads as visible and focused. What makes it so: every tab in its own
// window (Target.createTarget{newWindow:true}), focus emulation, and the
// anti-throttling flags. The control shows why newWindow is needed: in the
// full browser's new headless mode, two tabs of one window leave the first
// hidden and frozen (the headless shell shows every page regardless).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { delay, launch } from "./lib/cdp.mjs";
import { openTab } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const SAMPLE_MS = 1500;

/** Rates per second over the sample, and the state at its end. */
async function sample(tabs) {
  const read = (tab) => tab.evaluate("window.read()");
  const start = await Promise.all(tabs.map(read));
  await delay(SAMPLE_MS);
  const end = await Promise.all(tabs.map(read));
  return tabs.map((_, i) => {
    const a = start[i];
    const z = end[i];
    const seconds = (z.now - a.now) / 1000;
    const rate = (key) => Math.round(((z[key] - a[key]) / seconds) * 10) / 10;
    return {
      raf: rate("raf"), interval: rate("interval"), io: rate("io"), ro: rate("ro"),
      animationAdvancedMs: a.animationTime === null || z.animationTime === null ? null : Math.round(z.animationTime - a.animationTime),
      visibility: z.visibility, hasFocus: z.hasFocus, fieldFocused: z.fieldFocused, visibilityChanges: z.visibilityChanges,
    };
  });
}

async function openBackgroundTabs(chrome, server, count, tabOptions) {
  const tabs = [];
  for (let i = 0; i < count; i++) {
    const tab = await openTab(chrome, { url: server.url("/background.html"), ...tabOptions });
    await tab.evaluate("document.getElementById('field').focus(), true");
    tabs.push(tab);
  }
  await delay(300);
  return tabs;
}

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

  test("two tabs, each its own window, no viewer: everything advances in both", options(), async (t) => {
    const tabs = await openBackgroundTabs(chrome, server, 2, {});
    // Measured on macOS runners: a full Chrome with --headless=new, two
    // windows open, renders either window at 0 to 4 frames a second from
    // one run to the next (rAF, animations and the observers that follow
    // frames), while timers, visibility and focus hold. chrome-headless-shell,
    // Loom's own pick, keeps both at full rate there and everywhere; a full
    // browser runs only when chosen in Settings, and the guide says what it
    // costs. Under it on macOS, the frames are reported, not required.
    const fullOnMac = browser.kind === "fullBrowser" && process.platform === "darwin";
    try {
      const rates = await sample(tabs);
      for (const [i, rate] of rates.entries()) {
        t.diagnostic(`tab ${i + 1}: ${JSON.stringify(rate)}`);
        const which = `tab ${i + 1} of 2`;
        if (!fullOnMac) {
          // 60 a second on an idle machine; a loaded CI runner still does far better than this.
          assert.ok(rate.raf >= 15, `${which}: rAF ${rate.raf}/s`);
          assert.ok(rate.animationAdvancedMs >= SAMPLE_MS / 3, `${which}: the animation advanced ${rate.animationAdvancedMs} ms`);
          assert.ok(rate.io > 0, `${which}: IntersectionObserver ${rate.io}/s`);
          assert.ok(rate.ro > 0, `${which}: ResizeObserver ${rate.ro}/s`);
        }
        assert.ok(rate.interval >= 5, `${which}: timers ${rate.interval}/s`);
        assert.equal(rate.visibility, "visible", which);
        assert.equal(rate.hasFocus, true, `${which}: document.hasFocus()`);
        assert.equal(rate.fieldFocused, true, `${which}: its input kept the focus`);
        assert.deepEqual(rate.visibilityChanges, [], `${which}: never hidden`);
      }
    } finally {
      for (const tab of tabs) await tab.close();
    }
  });

  test("control: two tabs in one window, no focus emulation", options(), async (t) => {
    const tabs = await openBackgroundTabs(chrome, server, 2, { newWindow: null, focusEmulation: false });
    // As above: a full Chrome on macOS runners slows the front tab's frames
    // too (9 to 49/s measured); there it is only required not to stop.
    const fullOnMac = browser.kind === "fullBrowser" && process.platform === "darwin";
    try {
      const [first, second] = await sample(tabs);
      t.diagnostic(`first: ${JSON.stringify(first)}`);
      t.diagnostic(`second: ${JSON.stringify(second)}`);
      assert.equal(second.visibility, "visible");
      assert.ok(second.raf >= (fullOnMac ? 1 : 15), `the tab in front: rAF ${second.raf}/s`);
      if (browser.kind === "fullBrowser") {
        assert.equal(first.visibility, "hidden", "new headless hides a window's other tabs: hence newWindow:true");
        assert.ok(first.raf < 5, `the hidden tab's rAF: ${first.raf}/s`);
      } else {
        assert.equal(first.visibility, "visible", "the headless shell shows every page");
        assert.ok(first.raf >= 15, `rAF ${first.raf}/s`);
      }
    } finally {
      for (const tab of tabs) await tab.close();
    }
  });
});
