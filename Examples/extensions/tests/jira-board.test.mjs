// Seam: the Jira Board extension, end to end, in a real Chromium — served
// with Loom's own content security policy, given Loom's own SDK (both read
// from the Swift sources), and a fake Loom behind the bridge whose http.fetch
// answers as Jira Cloud would. What the WebKit host adds (the scheme, the
// rule list) is covered by the Mac checklist, not here.
// Run: node --test Examples/extensions/tests/
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

const ORIGIN = "https://ext.test";
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };

/** The fake Loom and the fake Jira, installed in the page before anything runs. */
function fakeLoom({ jiraAuth, issues }) {
  const storage = new Map();
  const secrets = new Map();
  const launches = [];
  const sessions = [];
  const expected = "Basic " + btoa(jiraAuth);

  const board = { id: 7, name: "PROJ board", type: "scrum" };
  const configuration = {
    columnConfig: {
      columns: [
        { name: "To Do", statuses: [{ id: "1" }] },
        { name: "In Progress", statuses: [{ id: "3" }] },
        { name: "Done", statuses: [{ id: "10001" }] },
      ],
    },
  };

  function jira(url, headers) {
    const { pathname } = new URL(url);
    if (headers.Authorization !== expected) return { status: 401, body: { errorMessages: ["unauthorized"] } };
    if (pathname === "/rest/api/3/myself") return { status: 200, body: { displayName: "Ada Lovelace" } };
    if (pathname === "/rest/agile/1.0/board") return { status: 200, body: { values: [board], isLast: true } };
    if (pathname === "/rest/agile/1.0/board/7/configuration") return { status: 200, body: configuration };
    if (pathname === "/rest/agile/1.0/board/7/sprint") return { status: 200, body: { values: [{ id: 42 }] } };
    if (pathname === "/rest/agile/1.0/sprint/42/issue") return { status: 200, body: { issues } };
    return { status: 404, body: {} };
  }

  function answer(request) {
    const p = request.params || {};
    switch (request.method) {
      case "loom.info":
        return { loomApi: 1, appVersion: "test", extensionId: "dev.loom.jira-board", theme: { isLight: false, tokens: {} } };
      case "projects.list":
        return { projects: [{ id: "4F1F0A2C-1111-2222-3333-444455556666", name: "webapp" }] };
      case "sessions.list":
        return { sessions };
      case "sessions.launch": {
        launches.push(p);
        const session = { id: "5E55C0DE-0000-0000-0000-000000000001", title: p.title, state: "starting", badges: p.badges || [], createdAt: "2026-09-24T10:00:00Z" };
        sessions.push(session);
        return { launched: true, sessionId: session.id };
      }
      case "sessions.open":
        return { ok: true };
      case "http.fetch": {
        if (!p.url.startsWith("https://acme.atlassian.net/")) {
          throw { code: "forbidden", message: "host not allowed" };
        }
        const { status, body } = jira(p.url, p.headers || {});
        return { status, url: p.url, headers: { "content-type": "application/json" }, body: JSON.stringify(body), bodyEncoding: "utf8" };
      }
      case "secrets.get":
        return { value: secrets.has(p.key) ? secrets.get(p.key) : null };
      case "secrets.set":
        secrets.set(p.key, p.value);
        return { ok: true };
      case "storage.get":
        return { value: storage.has(p.key) ? storage.get(p.key) : null };
      case "storage.set":
        storage.set(p.key, p.value);
        return { ok: true };
      default:
        throw { code: "unknownMethod", message: request.method };
    }
  }

  window.__fake = { storage, secrets, launches, sessions, violations: [] };
  document.addEventListener("securitypolicyviolation", (event) => {
    window.__fake.violations.push(event.violatedDirective + " " + event.blockedURI);
  });
  window.webkit = {
    messageHandlers: {
      loom: {
        postMessage(text) {
          const request = JSON.parse(text);
          return new Promise((resolve) => {
            setTimeout(() => {
              try {
                resolve(JSON.stringify({ id: request.id, result: answer(request) }));
              } catch (error) {
                resolve(JSON.stringify({ id: request.id, error }));
              }
            }, 1);
          });
        },
      },
    },
  };
}

const ADF_DESCRIPTION = {
  type: "doc",
  version: 1,
  content: [
    { type: "paragraph", content: [{ type: "text", text: "Users cannot log in with SSO." }] },
    { type: "bulletList", content: [
      { type: "listItem", content: [{ type: "paragraph", content: [{ type: "text", text: "Happens on Safari" }] }] },
    ] },
  ],
};

const ISSUES = [
  { key: "PROJ-1", fields: { summary: "Fix login", status: { id: "1", name: "To Do" }, issuetype: { name: "Bug" },
    priority: { name: "High" }, assignee: { displayName: "Grace Hopper" }, description: ADF_DESCRIPTION } },
  { key: "PROJ-2", fields: { summary: "<img src=x onerror=alert(1)>", status: { id: "3", name: "In Progress" },
    issuetype: { name: "Task" }, assignee: null, description: "plain v2 text" } },
  { key: "PROJ-3", fields: { summary: "Ship it", status: { id: "10001", name: "Done" }, issuetype: { name: "Story" } } },
];

async function openExtension(browser) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  page.on("dialog", (dialog) => {
    errors.push("dialog: " + dialog.message());
    dialog.dismiss();
  });
  await page.route(ORIGIN + "/**", async (route) => {
    const path = new URL(route.request().url()).pathname.replace(/^\/+/, "") || "index.html";
    try {
      const body = readFileSync(resolve(extensionsRoot, "jira-board", path));
      await route.fulfill({
        status: 200,
        body,
        headers: {
          "Content-Type": TYPES[extname(path)] || "application/octet-stream",
          "Content-Security-Policy": contentSecurityPolicy(),
          "Cache-Control": "no-store",
        },
      });
    } catch {
      await route.fulfill({ status: 404, body: "Not found" });
    }
  });
  await page.addInitScript(fakeLoom, { jiraAuth: "ada@example.com:tok-123", issues: ISSUES });
  await page.addInitScript(userScript({ extensionId: "dev.loom.jira-board", loomApi: 1,
    theme: { isLight: false, tokens: { accent: "#7C83FF" } } }));
  await page.goto(ORIGIN + "/");
  return { page, errors };
}

test("Jira Board: setup, board, detail, launch, live state — with Loom's CSP", { skip: !playwright && "playwright is not installed" }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { page, errors } = await openExtension(browser);

  // First run: nothing stored, the setup screen asks for the connection.
  await page.locator("#setup").waitFor({ state: "visible" });
  await page.fill("#site", "https://ACME.atlassian.net/jira/software");
  await page.fill("#email", "ada@example.com");
  await page.fill("#token", "wrong");
  await page.click("#setup-form button[type=submit]");
  await page.locator("#setup-error").waitFor({ state: "visible" });
  assert.match(await page.textContent("#setup-error"), /refused the credentials/);

  await page.fill("#token", "tok-123");
  await page.click("#setup-form button[type=submit]");
  await page.locator("#board .column").first().waitFor();

  const fake = await page.evaluate(() => ({
    secrets: Object.fromEntries(window.__fake.secrets),
    storage: Object.fromEntries(window.__fake.storage),
  }));
  assert.equal(fake.secrets.apiToken, "tok-123", "the token goes to the Keychain, through secrets");
  assert.deepEqual(fake.storage.config, { site: "acme.atlassian.net", email: "ada@example.com" });
  assert.equal(await page.inputValue("#token"), "", "the token field is cleared");

  // The board: three columns, one card each, in the right place.
  const heads = await page.locator(".column-head span:first-child").allTextContents();
  assert.deepEqual(heads, ["To Do", "In Progress", "Done"]);
  assert.equal(await page.locator(".column").nth(0).locator(".card").count(), 1);
  assert.match(await page.locator(".column").nth(0).textContent(), /Fix login/);

  // Ticket text is data: a summary made of HTML shows as text.
  assert.equal(await page.locator("#board img").count(), 0);
  assert.match(await page.locator(".column").nth(1).textContent(), /<img src=x onerror=alert\(1\)>/);

  // Pick the Loom project the board works in.
  await page.selectOption("#project-select", { label: "webapp" });

  // The detail: the ADF description as text.
  await page.click(".card[data-key='PROJ-1']");
  await page.locator("#detail").waitFor({ state: "visible" });
  assert.match(await page.textContent("#detail-description"), /Users cannot log in with SSO\.\s+• Happens on Safari/);
  assert.equal(await page.getAttribute("#detail-link", "href"), "https://acme.atlassian.net/browse/PROJ-1");

  // Start a session: Loom receives the proposal the user will confirm.
  await page.click("#detail-start");
  await page.locator("#detail-session").filter({ hasText: "starting" }).waitFor();
  const launch = await page.evaluate(() => window.__fake.launches[0]);
  assert.equal(launch.title, "PROJ-1 · Fix login");
  assert.deepEqual(launch.badges, ["PROJ-1"]);
  assert.equal(launch.projectId, "4F1F0A2C-1111-2222-3333-444455556666");
  assert.match(launch.prompt, /^Work on the Jira issue PROJ-1: Fix login/);
  assert.match(launch.prompt, /Type: Bug · Priority: High/);
  assert.match(launch.prompt, /Users cannot log in with SSO\./);
  assert.match(launch.prompt, /https:\/\/acme\.atlassian\.net\/browse\/PROJ-1/);

  // Loom pushes the session's state; the card and the detail follow.
  await page.evaluate(() => window.__loomEmit(JSON.stringify({
    name: "session.stateChanged",
    payload: { sessionId: "5E55C0DE-0000-0000-0000-000000000001", state: "needs_input", previous: "working" },
  })));
  await page.locator(".card[data-key='PROJ-1'] .chip").filter({ hasText: "needs input" }).waitFor();
  assert.equal(await page.isVisible("#detail-open"), true, "a live session can be opened");

  // A ⌘K command reaches the page.
  await page.evaluate(() => window.__loomEmit(JSON.stringify({ name: "command", payload: { id: "refresh" } })));
  await page.locator("#status").filter({ hasText: "3 issues" }).waitFor();

  // The theme arrives as CSS variables.
  const accent = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--loom-accent").trim());
  assert.equal(accent, "#7C83FF");

  const violations = await page.evaluate(() => window.__fake.violations);
  assert.deepEqual(violations, [], "the page lives within Loom's content security policy");
  assert.deepEqual(errors, []);
});

test("Jira Board: a stored connection opens straight on the board; a revoked token sends back to setup", { skip: !playwright && "playwright is not installed" }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.route(ORIGIN + "/**", async (route) => {
    const path = new URL(route.request().url()).pathname.replace(/^\/+/, "") || "index.html";
    await route.fulfill({
      status: 200,
      body: readFileSync(resolve(extensionsRoot, "jira-board", path)),
      headers: { "Content-Type": TYPES[extname(path)] || "text/plain", "Content-Security-Policy": contentSecurityPolicy() },
    });
  });
  await page.addInitScript(fakeLoom, { jiraAuth: "ada@example.com:tok-123", issues: ISSUES });
  await page.addInitScript(() => {
    window.__fake.storage.set("config", { site: "acme.atlassian.net", email: "ada@example.com" });
    window.__fake.secrets.set("apiToken", "revoked");
  });
  await page.addInitScript(userScript({ extensionId: "dev.loom.jira-board", loomApi: 1, theme: { isLight: true, tokens: {} } }));
  await page.goto(ORIGIN + "/");
  await page.locator("#setup-error").waitFor({ state: "visible" });
  assert.match(await page.textContent("#setup-error"), /check the e-mail and the token/);
  assert.equal(await page.inputValue("#site"), "acme.atlassian.net", "the known site is kept");
});

test("Loom's CSP blocks a direct network call from the page", { skip: !playwright && "playwright is not installed" }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const { page } = await openExtension(browser);
  await page.locator("#setup").waitFor({ state: "visible" });
  const outcome = await page.evaluate(async () => {
    try {
      await fetch("https://acme.atlassian.net/rest/api/3/myself");
      return "reached";
    } catch {
      return "blocked";
    }
  });
  assert.equal(outcome, "blocked");
  const violations = await page.evaluate(() => window.__fake.violations);
  assert.ok(violations.some((line) => line.startsWith("connect-src")), violations.join(", "));
});
