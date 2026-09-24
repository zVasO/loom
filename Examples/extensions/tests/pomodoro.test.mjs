// Seam: the Pomodoro extension end to end in Chromium, with Loom's CSP and
// SDK (read from the Swift sources) and a fake Loom that records what the
// page asks of it: alarms, the top-bar status, the overlay. What Loom does
// with those asks natively is covered by the Swift tests and the Mac checklist.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { extname, resolve } from "node:path";
import { contentSecurityPolicy, extensionsRoot, userScript } from "./extract.mjs";

const require = createRequire(import.meta.url);
function loadPlaywright() {
  for (const candidate of ["playwright", "/opt/node22/lib/node_modules/playwright"]) {
    try {
      return require(candidate);
    } catch {}
  }
  return null;
}
const playwright = loadPlaywright();
const skip = !playwright && "playwright is not installed";

const ORIGIN = "https://pomodoro.test";
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

function fakeLoom({ storage: initial }) {
  const storage = new Map(Object.entries(initial || {}));
  const calls = [];
  const sessions = [
    { id: "a", title: "Fix login", state: "working", badges: [], createdAt: "2026-09-24T09:00:00Z" },
    { id: "b", title: "Refactor", state: "needs_input", badges: [], createdAt: "2026-09-24T09:00:00Z" },
  ];
  function answer(request) {
    const p = request.params || {};
    calls.push({ method: request.method, params: p });
    switch (request.method) {
      case "storage.get": return { value: storage.has(p.key) ? storage.get(p.key) : null };
      case "storage.set": storage.set(p.key, p.value); return { ok: true };
      case "alarms.create": return { name: p.name, scheduledTime: p.when };
      case "alarms.clear": case "ui.setStatus": case "ui.presentOverlay": case "ui.dismissOverlay":
        return { ok: true };
      case "sessions.list": return { sessions };
      default: throw { code: "unknownMethod", message: request.method };
    }
  }
  window.__fake = { storage, calls, violations: [] };
  document.addEventListener("securitypolicyviolation", (event) => {
    window.__fake.violations.push(event.violatedDirective + " " + event.blockedURI);
  });
  window.webkit = { messageHandlers: { loom: { postMessage(text) {
    const request = JSON.parse(text);
    return new Promise((resolve) => setTimeout(() => {
      try {
        resolve(JSON.stringify({ id: request.id, result: answer(request) }));
      } catch (error) {
        resolve(JSON.stringify({ id: request.id, error }));
      }
    }, 1));
  } } } };
}

async function open(browser, page, storage = {}) {
  const tab = await browser.newPage();
  const errors = [];
  tab.on("pageerror", (error) => errors.push(String(error)));
  await tab.route(ORIGIN + "/**", async (route) => {
    const path = new URL(route.request().url()).pathname.replace(/^\/+/, "") || "index.html";
    await route.fulfill({
      status: 200,
      body: readFileSync(resolve(extensionsRoot, "pomodoro", path)),
      headers: { "Content-Type": TYPES[extname(path)] || "text/plain", "Content-Security-Policy": contentSecurityPolicy() },
    });
  });
  await tab.addInitScript(fakeLoom, { storage });
  await tab.addInitScript(userScript({ extensionId: "dev.loom.pomodoro", loomApi: 1, theme: { isLight: false, tokens: {} } }));
  await tab.goto(ORIGIN + "/" + page);
  return { tab, errors };
}

const lastCall = (calls, method) => [...calls].reverse().find((call) => call.method === method);
const emit = (tab, name, payload) =>
  tab.evaluate(([n, p]) => window.__loomEmit(JSON.stringify({ name: n, payload: p })), [name, payload]);

test("Pomodoro: start sets Loom's alarm and top-bar countdown; the alarm opens the break over Loom; Skip ends it", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { tab, errors } = await open(browser, "index.html");
  await tab.locator("#clock").filter({ hasText: "25:00" }).waitFor();

  const before = Date.now();
  await tab.click("#start");
  await tab.locator("#phase").filter({ hasText: "Focus" }).waitFor();
  let calls = await tab.evaluate(() => window.__fake.calls);
  const alarm = lastCall(calls, "alarms.create");
  assert.equal(alarm.params.name, "phase-end");
  assert.ok(Math.abs(alarm.params.when - (before + 25 * 60_000)) < 5_000, "the alarm is Loom's, at the end of the run");
  const status = lastCall(calls, "ui.setStatus");
  assert.equal(status.params.text, "🍅");
  assert.equal(status.params.countdownTo, alarm.params.when, "Loom counts down to the same instant");

  // Loom reopens after the run ended: the page catches up to the break and covers Loom.
  const ended = Date.now() - 10;
  const reopened = await open(browser, "index.html", {
    timer: { phase: "focus", endsAt: ended, pausedRemaining: null, completedFocus: 0 },
  });
  const breakTab = reopened.tab;
  await breakTab.locator("#phase").filter({ hasText: "Short break" }).waitFor();
  calls = await breakTab.evaluate(() => window.__fake.calls);
  const overlay = lastCall(calls, "ui.presentOverlay");
  assert.equal(overlay.params.page, "break.html");
  assert.equal(overlay.params.dismissLabel, "Skip break");
  assert.equal(overlay.params.until, ended + 5 * 60_000, "the break ends when it would have");
  assert.equal(lastCall(calls, "ui.setStatus").params.text, "☕");

  // The user presses Loom's "Skip break": the page hears it and moves on.
  await emit(breakTab, "overlay.dismissed", { reason: "user", page: "break.html" });
  await breakTab.locator("#phase").filter({ hasText: "Ready" }).waitFor();
  const after = await breakTab.evaluate(() => ({
    stats: window.__fake.storage.get("stats"),
    status: [...window.__fake.calls].reverse().find((call) => call.method === "ui.setStatus").params,
    cleared: window.__fake.calls.some((call) => call.method === "alarms.clear"),
    violations: window.__fake.violations,
  }));
  assert.equal(after.stats.focusDone, 1);
  assert.equal(after.stats.breaksSkipped, 1);
  assert.deepEqual(after.status, {}, "the top bar is cleared");
  assert.ok(after.cleared, "no alarm is left behind");
  assert.deepEqual(after.violations, []);
  assert.deepEqual(errors, []);
  assert.deepEqual(reopened.errors, []);
});

test("Pomodoro: Loom's alarm ends the run and starts the break; an early one is ignored", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { tab, errors } = await open(browser, "index.html");
  await tab.click("#start");
  await tab.locator("#phase").filter({ hasText: "Focus" }).waitFor();

  await emit(tab, "alarm", { name: "phase-end", scheduledTime: Date.now() });
  await tab.waitForTimeout(200);
  assert.match(await tab.textContent("#phase"), /^Focus/, "an alarm long before the end changes nothing");

  // 26 minutes later, as far as the page can tell.
  await tab.clock.setFixedTime(Date.now() + 26 * 60_000);
  await emit(tab, "alarm", { name: "phase-end", scheduledTime: Date.now() + 25 * 60_000 });
  await tab.locator("#phase").filter({ hasText: "Short break" }).waitFor();
  const overlay = await tab.evaluate(() => [...window.__fake.calls].reverse().find((c) => c.method === "ui.presentOverlay"));
  assert.equal(overlay.params.page, "break.html");
  assert.equal((await tab.evaluate(() => window.__fake.storage.get("stats"))).focusDone, 1);
  assert.deepEqual(errors, []);
});

test("Pomodoro: commands from ⌘K start, pause and skip", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { tab, errors } = await open(browser, "index.html");
  await tab.locator("#clock").filter({ hasText: "25:00" }).waitFor();
  await emit(tab, "command", { id: "start" });
  await tab.locator("#phase").filter({ hasText: "Focus" }).waitFor();
  await emit(tab, "command", { id: "pause" });
  await tab.locator("#phase").filter({ hasText: "paused" }).waitFor();
  assert.equal((await tab.evaluate(() => [...window.__fake.calls].reverse().find((c) => c.method === "ui.setStatus").params)).text, "🍅 paused");
  await emit(tab, "command", { id: "skip" });
  await tab.locator("#phase").filter({ hasText: "Short break" }).waitFor();
  assert.deepEqual(errors, []);
});

test("Pomodoro: the break page shows the time left and what the agents are doing", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const endsAt = Date.now() + 4 * 60_000 + 30_000;
  const { tab, errors } = await open(browser, "break.html", {
    timer: { phase: "longBreak", endsAt, pausedRemaining: null, completedFocus: 4 },
  });
  await tab.locator("#break-sessions").filter({ hasText: "working" }).waitFor();
  assert.equal(await tab.textContent("#break-kind"), "Long break");
  assert.match(await tab.textContent("#break-clock"), /^4:(2\d|30)$/);
  assert.equal(await tab.textContent("#break-sessions"), "1 agent is working · 1 waits for you — it will keep.");
  await emit(tab, "sessions.changed", { sessions: [] });
  await tab.locator("#break-sessions").filter({ hasText: "No agent" }).waitFor();
  assert.deepEqual(await tab.evaluate(() => window.__fake.violations), []);
  assert.deepEqual(errors, []);
});
