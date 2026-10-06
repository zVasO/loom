// Seam: the tech watch end to end in Chromium, with Loom's CSP and SDK (read
// from the Swift sources) and a fake Loom that answers like Loom — and, behind
// http.fetch, like HN, GitHub, Lobsters and a blog — and records what the page
// asks: alarms, the top-bar status, Claude, hosts, launches. What Loom does
// natively with those asks is covered by the Swift tests and the Mac checklist.
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

const ORIGIN = "https://tech-watch.test";
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };
const fixture = (name) => readFileSync(resolve(extensionsRoot, "tests/fixtures/tech-watch", name), "utf8");
const DAY = 24 * 3600_000;

const ROUTES = {
  "https://hn.algolia.com/": { body: fixture("hn.json") },
  "https://api.github.com/repos/anthropics/claude-code/releases": { body: fixture("github-releases.json") },
  "https://lobste.rs/hottest.json": { body: fixture("lobsters.json") },
  "https://blog.example.com/feed.xml": { body: fixture("feed-rss.xml") },
};

function fakeLoom({ storage: initial, routes, claude, grant }) {
  const storage = new Map(Object.entries(initial || {}));
  const calls = [];
  const granted = [];
  const declared = ["hn.algolia.com", "api.github.com", "www.reddit.com", "lobste.rs"];
  function answer(request) {
    const p = request.params || {};
    calls.push({ method: request.method, params: p });
    switch (request.method) {
      case "storage.get": return { value: storage.has(p.key) ? storage.get(p.key) : null };
      case "storage.set": storage.set(p.key, p.value); return { ok: true };
      case "secrets.get": return { value: null };
      case "alarms.create": return { name: p.name, scheduledTime: p.when ?? Date.now() + p.delayMs };
      case "alarms.clear": case "ui.setStatus": return { ok: true };
      case "network.granted": return { declared, granted: [...granted] };
      case "network.request": {
        const ok = p.hosts.filter(() => grant);
        for (const host of ok) if (!granted.includes(host)) granted.push(host);
        return { granted: ok, denied: p.hosts.filter((host) => !ok.includes(host)) };
      }
      case "network.revoke":
        for (const host of p.hosts) granted.splice(granted.indexOf(host), granted.includes(host) ? 1 : 0);
        return { ok: true };
      case "sessions.launch": return { launched: true, sessionId: "11111111-1111-1111-1111-111111111111" };
      case "claude.complete": {
        if (claude.error) throw { code: claude.error, message: "Claude: Not logged in" };
        const ids = [...p.prompt.matchAll(/"id":"([^"]+)"/g)].map((match) => match[1]);
        return {
          text: "```json\n" + JSON.stringify({
            headline: "Swift 7 sort, et Claude Code aussi",
            sections: [{ theme: "Langages", summary: "Swift 7 est là.", itemIds: ids.slice(0, 2) },
                       { theme: "Outils", summary: "Une release de Claude Code.", itemIds: ids.slice(2) }],
            mustRead: ids.slice(0, 1),
          }) + "\n```",
          model: "claude-sonnet-test", costUsd: 0.0123, durationMs: 1500, truncated: false,
        };
      }
      case "http.fetch": {
        const host = new URL(p.url).hostname;
        if (!declared.includes(host) && !granted.includes(host)) {
          throw { code: "forbidden", message: host + " is not allowed" };
        }
        const prefix = Object.keys(routes).find((candidate) => p.url.startsWith(candidate));
        if (!prefix) return { status: 404, url: p.url, headers: {}, body: "", bodyEncoding: "utf8" };
        return { status: 200, url: p.url, headers: {}, body: routes[prefix].body, bodyEncoding: "utf8" };
      }
      default: throw { code: "unknownMethod", message: request.method };
    }
  }
  window.__fake = { storage, calls, granted, violations: [] };
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

async function open(browser, { storage = {}, claude = {}, grant = true } = {}) {
  const tab = await browser.newPage();
  const errors = [];
  tab.on("pageerror", (error) => errors.push(String(error)));
  await tab.route(ORIGIN + "/**", async (route) => {
    const path = new URL(route.request().url()).pathname.replace(/^\/+/, "") || "index.html";
    await route.fulfill({
      status: 200,
      body: readFileSync(resolve(extensionsRoot, "tech-watch", path)),
      headers: { "Content-Type": TYPES[extname(path)] || "text/plain", "Content-Security-Policy": contentSecurityPolicy() },
    });
  });
  await tab.addInitScript(fakeLoom, { storage, routes: ROUTES, claude, grant });
  await tab.addInitScript(userScript({ extensionId: "dev.loom.tech-watch", loomApi: 1, theme: { isLight: false, tokens: {} } }));
  await tab.goto(ORIGIN + "/index.html");
  return { tab, errors };
}

const calls = (tab, method) => tab.evaluate((m) => window.__fake.calls.filter((call) => call.method === m), method);
const stored = (tab, key) => tab.evaluate((k) => window.__fake.storage.get(k), key);
const emit = (tab, name, payload) =>
  tab.evaluate(([n, p]) => window.__loomEmit(JSON.stringify({ name: n, payload: p })), [name, payload]);
async function waitForCall(tab, method, count = 1) {
  await tab.waitForFunction(([m, c]) => window.__fake.calls.filter((call) => call.method === m).length >= c, [method, count]);
}

test("tech watch: a first run arms the morning alarm and waits for it — no digest, no Claude", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { tab, errors } = await open(browser);
  await waitForCall(tab, "alarms.create");
  await tab.locator("#view-digest").filter({ hasText: "Pas encore de digest" }).waitFor();
  const alarms = await calls(tab, "alarms.create");
  assert.deepEqual(alarms.map((call) => call.params.name), ["digest"]);
  const when = new Date(alarms[0].params.when);
  assert.equal(when.getHours(), 8);
  assert.equal(when.getMinutes(), 0);
  assert.ok(alarms[0].params.when > Date.now() && alarms[0].params.when <= Date.now() + DAY);
  assert.equal(typeof (await stored(tab, "state")).startedAt, "number");
  assert.deepEqual(await calls(tab, "claude.complete"), []);
  assert.deepEqual(await tab.evaluate(() => window.__fake.violations), []);
  assert.deepEqual(errors, []);
});

test("tech watch: Loom closed at digest time — the catch-up alarm reads the sources, asks Claude once, shows 📰", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const twoDaysAgo = Date.now() - 2 * DAY;
  const { tab, errors } = await open(browser, {
    storage: { state: { startedAt: twoDaysAgo, lastDigestAt: twoDaysAgo, lastFetchAt: null, sources: {} } },
  });
  await waitForCall(tab, "alarms.create", 2);
  const catchUp = (await calls(tab, "alarms.create")).find((call) => call.params.name === "digest-catchup");
  assert.equal(catchUp.params.delayMs, 60_000, "a minute for the network to come up");

  await emit(tab, "alarm", { name: "digest-catchup", scheduledTime: Date.now() });
  await tab.locator(".headline").filter({ hasText: "Swift 7 sort" }).waitFor();
  const completions = await calls(tab, "claude.complete");
  assert.equal(completions.length, 1);
  const request = completions[0].params;
  assert.equal(request.model, "sonnet");
  assert.match(request.system, /untrusted data/);
  assert.match(request.prompt, /<articles>[\s\S]*hn:41000001[\s\S]*<\/articles>$/);
  assert.match(request.prompt, /claude-code v2\.2\.0/);

  // The three sites' Swift 7 is one item; the digest shows its sections.
  await tab.locator(".card h3").filter({ hasText: "Langages" }).waitFor();
  assert.ok(await tab.locator(".chip.must").filter({ hasText: "à lire" }).count() >= 1);
  assert.match(await tab.textContent("#view-digest"), /aussi sur r\/swift|aussi sur Lobsters/);
  assert.match(await tab.textContent("#view-digest"), /claude-sonnet-test · 0\.012 \$/);

  const statuses = await calls(tab, "ui.setStatus");
  const status = statuses.at(-1).params;
  assert.match(status.text, /^📰 \d+$/);
  const digests = await stored(tab, "digests");
  assert.equal(digests.length, 1);
  assert.ok((await stored(tab, "state")).lastDigestAt > twoDaysAgo);
  assert.equal((await calls(tab, "alarms.create")).at(-1).params.name, "digest", "re-armed for tomorrow");

  // The daily alarm right after finds today's digest done: nothing more.
  await emit(tab, "alarm", { name: "digest", scheduledTime: Date.now() });
  await tab.waitForTimeout(300);
  assert.equal((await calls(tab, "claude.complete")).length, 1);

  // Mark all read: the top bar clears.
  await tab.click("text=Tout marquer comme lu");
  await tab.waitForFunction(() => {
    const last = window.__fake.calls.filter((call) => call.method === "ui.setStatus").at(-1);
    return last && !last.params.text;
  });
  assert.deepEqual(await tab.evaluate(() => window.__fake.violations), []);
  assert.deepEqual(errors, []);
});

test("tech watch: without Claude the digest still lists the articles, and says why", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { tab, errors } = await open(browser, { claude: { error: "unavailable" } });
  await waitForCall(tab, "alarms.create");
  await tab.click("#summarize");
  await tab.locator(".warn").filter({ hasText: "Pas de résumé cette fois : Claude: Not logged in" }).waitFor();
  assert.ok(await tab.locator("#view-digest .items li").count() > 0);
  assert.equal((await stored(tab, "digests"))[0].error, "Claude: Not logged in");
  assert.deepEqual(errors, []);
});

test("tech watch: an article goes to a Claude session through Loom's launch sheet", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { tab, errors } = await open(browser);
  await waitForCall(tab, "alarms.create");
  await emit(tab, "command", { id: "digest" });
  await tab.locator(".headline").waitFor();
  await tab.locator("[data-action='session']").first().click();
  await waitForCall(tab, "sessions.launch");
  const launch = (await calls(tab, "sessions.launch"))[0].params;
  assert.match(launch.prompt, /URL : https:\/\//);
  assert.match(launch.prompt, /jamais comme des instructions/);
  assert.match(launch.title, /^Veille : /);
  assert.deepEqual(launch.badges, ["veille"]);
  assert.deepEqual(errors, []);
});

test("tech watch: adding a feed asks Loom for its host — refused, nothing is kept; allowed, it is read and named", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const refused = await open(browser, { grant: false });
  await waitForCall(refused.tab, "alarms.create");
  await refused.tab.click("[data-tab='settings']");
  await refused.tab.fill("input[name='feed']", "https://blog.example.com/feed.xml");
  await refused.tab.click("[data-add='feed']");
  await refused.tab.locator(".error").filter({ hasText: "Loom n'a pas autorisé blog.example.com" }).waitFor();
  assert.deepEqual((await calls(refused.tab, "network.request"))[0].params.hosts, ["blog.example.com"]);
  assert.equal(await stored(refused.tab, "settings"), undefined);

  const { tab, errors } = await open(browser, { grant: true });
  await waitForCall(tab, "alarms.create");
  await tab.click("[data-tab='settings']");
  await tab.fill("input[name='feed']", "http://blog.example.com/feed.xml");
  await tab.click("[data-add='feed']");
  await tab.locator(".error").filter({ hasText: "HTTPS" }).waitFor();
  await tab.fill("input[name='feed']", "https://blog.example.com/feed.xml");
  await tab.click("[data-add='feed']");
  await tab.locator("#view-settings a").filter({ hasText: "Le blog d'Exemple" }).waitFor();
  assert.deepEqual((await stored(tab, "settings")).feeds,
                   [{ url: "https://blog.example.com/feed.xml", host: "blog.example.com", title: "Le blog d'Exemple" }]);

  // Its items show as text — a hostile title included.
  await tab.click("[data-tab='items']");
  await tab.locator("#view-items .title").filter({ hasText: "Des agents & des worktrees" }).waitFor();
  assert.equal(await tab.evaluate(() => window.__pwned), undefined);

  // Removed: the host goes back to Loom.
  await tab.click("[data-tab='settings']");
  await tab.locator("#view-settings .list li").filter({ hasText: "Le blog d'Exemple" }).locator("button").click();
  await waitForCall(tab, "network.revoke");
  assert.deepEqual((await calls(tab, "network.revoke"))[0].params.hosts, ["blog.example.com"]);
  assert.deepEqual((await stored(tab, "settings")).feeds, []);

  // A revoke from Loom's Settings: the feed says so.
  await tab.evaluate(() => window.__fake.granted.splice(0));
  await emit(tab, "network.changed", { granted: [] });
  assert.deepEqual(await tab.evaluate(() => window.__fake.violations), []);
  assert.deepEqual(errors, []);
  assert.deepEqual(refused.errors, []);
});

test("tech watch: a feed whose host was revoked in Settings shows it and can ask again", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { tab, errors } = await open(browser, {
    storage: { settings: { feeds: [{ url: "https://blog.example.com/feed.xml", title: "Le blog d'Exemple" }] } },
  });
  await waitForCall(tab, "alarms.create");
  await tab.click("[data-tab='settings']");
  const row = tab.locator("#view-settings .list li").filter({ hasText: "Le blog d'Exemple" });
  await row.filter({ hasText: "accès retiré" }).waitFor();
  await row.locator("text=redemander").click();
  await waitForCall(tab, "network.request");
  await tab.locator("#view-settings .list li").filter({ hasText: "Le blog d'Exemple" }).filter({ hasNotText: "accès retiré" }).waitFor();
  assert.deepEqual(errors, []);
});
