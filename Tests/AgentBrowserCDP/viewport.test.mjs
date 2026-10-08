// The page's size and identity as the engine sets them (design §9, critic
// C1, plan §7): Emulation.setDeviceMetricsOverride at device scale 1 gives
// innerWidth = the width asked, devicePixelRatio 1, and — with
// --hide-scrollbars — clientWidth = innerWidth on a page that scrolls, as
// with macOS overlay scrollbars. A new width takes effect at once and fires
// resize. The user agent is a Mac Chrome's, "Headless" nowhere, with its
// client hints — passed as metadata, without which the brands are empty.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launch } from "./lib/cdp.mjs";
import { deviceMetrics, openTab, userAgentOverride } from "./lib/init.mjs";
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

  const geometry = "({ innerWidth, innerHeight, clientWidth: document.documentElement.clientWidth, dpr: devicePixelRatio, screenWidth: screen.width, scrolls: document.documentElement.scrollHeight > innerHeight })";

  test("1280 × 800 at scale 1: innerWidth 1280, clientWidth too (no scrollbar), devicePixelRatio 1", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/long.html") });
    assert.deepEqual(await tab.evaluate(geometry), { innerWidth: 1280, innerHeight: 800, clientWidth: 1280, dpr: 1, screenWidth: 1280, scrolls: true });
    await tab.close();
  });

  test("a new width applies at once: innerWidth follows, resize fires, media queries switch", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/long.html") });
    // The listener is in place before the override is sent: Emulation is handled in the browser
    // process and reaches the renderer by another channel than a Runtime command.
    await tab.evaluate("window.resized = new Promise((done) => addEventListener('resize', () => done(innerWidth), { once: true })), true");
    await tab.session.send("Emulation.setDeviceMetricsOverride", deviceMetrics({ width: 900, height: 700 }));
    assert.equal(await tab.evaluate("window.resized"), 900);
    assert.deepEqual(await tab.evaluate(geometry), { innerWidth: 900, innerHeight: 700, clientWidth: 900, dpr: 1, screenWidth: 900, scrolls: true });
    assert.equal(await tab.evaluate("matchMedia('(max-width: 1000px)').matches"), true);
    await tab.close();
  });

  test("the user agent: a Mac's, no Headless anywhere, brands from the metadata", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/blank") });
    const seen = await tab.evaluate("({ ua: navigator.userAgent, platform: navigator.platform, brands: navigator.userAgentData.brands.map((b) => b.brand), mobile: navigator.userAgentData.mobile, webdriver: navigator.webdriver })");
    assert.equal(seen.ua, userAgentOverride(chrome).userAgent);
    assert.doesNotMatch(seen.ua, /Headless/);
    assert.equal(seen.platform, "MacIntel");
    assert.ok(seen.brands.includes("Chromium"), JSON.stringify(seen.brands));
    assert.ok(!seen.brands.some((brand) => /Headless/.test(brand)));
    assert.equal(seen.mobile, false);
    const hints = await tab.evaluate("navigator.userAgentData.getHighEntropyValues(['platform', 'architecture']).then((v) => [v.platform, v.architecture])");
    assert.deepEqual(hints, ["macOS", "arm"]);
    // Requests carry it too.
    await tab.evaluate("fetch('/echo?ua').then(() => true)");
    const request = server.hits.findLast((hit) => hit.path === "/echo" && hit.query === "?ua");
    assert.equal(request?.userAgent, seen.ua);
    await tab.close();
  });

  test("without the metadata, the brands are empty: Loom always sends it", options(), async () => {
    const tab = await openTab(chrome, { url: server.url("/blank") });
    const { userAgent, platform } = userAgentOverride(chrome);
    await tab.session.send("Emulation.setUserAgentOverride", { userAgent, platform });
    await tab.navigate(server.url("/blank?again"));
    assert.deepEqual(await tab.evaluate("navigator.userAgentData.brands.length"), 0);
    await tab.close();
  });
});
