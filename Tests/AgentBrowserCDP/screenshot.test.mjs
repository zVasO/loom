// Screenshots as the engine takes them (design §9 at device scale 1, critic
// C1): Page.captureScreenshot answers the viewport at its CSS size, a
// clip.scale shrinks it in Chromium (never re-encoded by Loom), and a full
// page is one call with captureBeyondViewport — which keeps the page's
// scroll position (no scroll back needed) but fires a resize in the page.
// A clip is in document coordinates: an element's viewport rectangle needs
// the scroll offset added.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launch } from "./lib/cdp.mjs";
import { openTab, VIEWPORT } from "./lib/init.mjs";
import { decodePNG, imageSize } from "./lib/png.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const BANDS = 24;
const bandColor = (i) => [i * 10, 255 - i * 10, (i * 37) % 256];
/** Which 100-px band of long.html a pixel shows, or its colour when none. */
function bandOf([r, g, b]) {
  for (let i = 0; i < BANDS; i++) {
    const [br, bg, bb] = bandColor(i);
    if (Math.abs(br - r) <= 3 && Math.abs(bg - g) <= 3 && Math.abs(bb - b) <= 3) return i;
  }
  return `rgb(${r}, ${g}, ${b})`;
}

eachBrowser((browser) => {
  let server;
  let chrome;
  let tab;
  before(async () => {
    server = await startServer();
    chrome = await launch(browser);
    tab = await openTab(chrome, { url: server.url("/long.html") });
  });
  after(async () => {
    await chrome?.close();
    await server?.close();
  });

  const capture = async (params) => Buffer.from((await tab.session.send("Page.captureScreenshot", params)).data, "base64");
  const scrollTo = (y) => tab.evaluate(`new Promise((done) => { scrollTo(0, ${y}); requestAnimationFrame(() => done(scrollY)); })`);

  test("the viewport at device scale 1: its CSS size in PNG and JPEG; clip.scale 0.5 halves it", options(), async () => {
    await scrollTo(0);
    assert.deepEqual(imageSize(await capture({ format: "png" })), { type: "png", ...VIEWPORT });
    assert.deepEqual(imageSize(await capture({ format: "jpeg", quality: 80, optimizeForSpeed: true })), { type: "jpeg", ...VIEWPORT });
    const half = await capture({ format: "png", clip: { x: 0, y: 0, width: VIEWPORT.width, height: VIEWPORT.height, scale: 0.5 } });
    assert.deepEqual(imageSize(half), { type: "png", width: 640, height: 400 });
    const top = decodePNG(await capture({ format: "png" }));
    assert.equal(bandOf(top.pixel(10, 10)), 0);
    assert.equal(bandOf(top.pixel(10, 790)), 7);
  });

  test("the full page in one call: captureBeyondViewport keeps scrollY; the bands come in order", options(), async (t) => {
    assert.equal(await scrollTo(100), 100);
    const before = await tab.evaluate("st()");
    const shot = decodePNG(await capture({
      format: "png", captureBeyondViewport: true, clip: { x: 0, y: 0, width: VIEWPORT.width, height: before.scrollHeight, scale: 1 },
    }));
    const after = await tab.evaluate("new Promise((done) => requestAnimationFrame(() => done(st())))");
    assert.deepEqual([shot.width, shot.height], [1280, 2400]);
    assert.deepEqual([0, 1550, 2390].map((y) => bandOf(shot.pixel(10, y))), [0, 15, 23]);
    assert.equal(after.scrollY, 100, "the scroll position is kept");
    assert.equal(after.innerHeight, VIEWPORT.height, "the viewport is back");
    t.diagnostic(`side effects in the page: ${after.resize - before.resize} resize, ${after.ro - before.ro} ResizeObserver callbacks`);
  });

  test("a clip is in document coordinates: scrolled to 500, y 600 shows band 6, y 0 nothing", options(), async () => {
    assert.equal(await scrollTo(500), 500);
    const clip = (y) => capture({ format: "png", clip: { x: 0, y, width: 100, height: 50, scale: 1 } }).then(decodePNG);
    assert.equal(bandOf((await clip(600)).pixel(10, 10)), 6);
    assert.notEqual(typeof bandOf((await clip(0)).pixel(10, 10)), "number", "above the viewport: blank without captureBeyondViewport");
    const element = await tab.call("function() { const r = document.querySelectorAll('div.band')[9].getBoundingClientRect(); return { x: r.x + scrollX, y: r.y + scrollY }; }");
    assert.equal(bandOf((await clip(element.y)).pixel(10, 10)), 9, "an element: its rect plus the scroll offset");
  });

  test("capped at 1568 px: a scale of 1568 / height gives the capped image", options(), async () => {
    const scale = 1568 / 2400;
    const capped = imageSize(await capture({ format: "png", captureBeyondViewport: true, clip: { x: 0, y: 0, width: 1280, height: 2400, scale } }));
    assert.equal(capped.height, 1568);
    assert.ok(Math.abs(capped.width - Math.round(1280 * scale)) <= 1, `width ${capped.width}`);
  });
});
