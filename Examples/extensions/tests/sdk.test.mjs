// Seam: window.loom as Loom injects it (extracted from LoomSDKScript.swift),
// run in a bare VM context against a fake `webkit.messageHandlers.loom`.
// Run: node --test Examples/extensions/tests/
import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { userScript } from "./extract.mjs";

function makePage({ reply, boot } = {}) {
  const posted = [];
  const properties = new Map();
  const attributes = new Map();
  const documentElement = {
    style: {
      setProperty: (name, value) => properties.set(name, value),
      colorScheme: "",
    },
    setAttribute: (name, value) => attributes.set(name, value),
  };
  const window = {
    console,
    TextDecoder,
    TextEncoder,
    atob: (text) => Buffer.from(text, "base64").toString("binary"),
    document: { documentElement, addEventListener() {} },
    webkit: {
      messageHandlers: {
        loom: {
          postMessage(text) {
            const request = JSON.parse(text);
            posted.push(request);
            return reply ? reply(request) : Promise.resolve(JSON.stringify({ id: request.id, result: {} }));
          },
        },
      },
    },
  };
  window.window = window;
  const context = vm.createContext(window);
  vm.runInContext(userScript(boot ?? { extensionId: "dev.example.x", loomApi: 1, theme: {
    isLight: true, tokens: { accent: "#FF0000", surfaceRaised: "#EEEEEE" } } }), context);
  return { window, loom: window.loom, posted, properties, attributes, context };
}

// Objects built inside the VM have its own prototypes: compare them as JSON.
const plain = (value) => JSON.parse(JSON.stringify(value));

const answer = (result) => (request) => Promise.resolve(JSON.stringify({ id: request.id, result }));

test("a call posts {id, method, params} as JSON text and resolves the result", async () => {
  const page = makePage({ reply: answer({ projects: [{ id: "p", name: "loom" }] }) });
  const projects = await page.loom.projects.list();
  assert.deepEqual(plain(projects), [{ id: "p", name: "loom" }]);
  assert.equal(page.posted[0].method, "projects.list");
  assert.deepEqual(plain(page.posted[0].params), {});
  assert.equal(typeof page.posted[0].id, "string");
});

test("an error response rejects with a LoomError carrying the code", async () => {
  const page = makePage({
    reply: (request) => Promise.resolve(JSON.stringify({ id: request.id, error: { code: "forbidden", message: "no" } })),
  });
  await assert.rejects(page.loom.sessions.list(), (error) => {
    assert.equal(error.name, "LoomError");
    assert.equal(error.code, "forbidden");
    assert.equal(error.message, "no");
    return error instanceof page.loom.LoomError;
  });
});

test("a refusal before dispatch ('code: message') becomes a LoomError too", async () => {
  const page = makePage({ reply: () => Promise.reject(new Error("forbidden: the bridge answers the extension's own page only")) });
  await assert.rejects(page.loom.info(), { name: "LoomError", code: "forbidden" });
});

test("listeners hear their event, '*' hears all, and unsubscribe works", () => {
  const page = makePage();
  const heard = [];
  const off = page.loom.on("session.stateChanged", (payload) => heard.push(["one", payload.state]));
  page.loom.on("*", (name) => heard.push(["any", name]));
  page.window.__loomEmit(JSON.stringify({ name: "session.stateChanged", payload: { sessionId: "s", state: "idle" } }));
  off();
  page.window.__loomEmit(JSON.stringify({ name: "session.stateChanged", payload: { sessionId: "s", state: "working" } }));
  assert.deepEqual(heard, [["one", "idle"], ["any", "session.stateChanged"], ["any", "session.stateChanged"]]);
});

test("a throwing listener does not stop the others", () => {
  const page = makePage();
  let reached = false;
  const originalError = console.error;
  console.error = () => {};
  try {
    page.loom.on("command", () => { throw new Error("boom"); });
    page.loom.on("command", () => { reached = true; });
    page.window.__loomEmit(JSON.stringify({ name: "command", payload: { id: "refresh" } }));
  } finally {
    console.error = originalError;
  }
  assert.ok(reached);
});

test("the theme becomes --loom-* variables at boot and on theme.changed", () => {
  const page = makePage();
  assert.equal(page.properties.get("--loom-accent"), "#FF0000");
  assert.equal(page.properties.get("--loom-surface-raised"), "#EEEEEE");
  assert.equal(page.attributes.get("data-loom-appearance"), "light");
  page.window.__loomEmit(JSON.stringify({ name: "theme.changed", payload: { isLight: false, tokens: { accent: "#00FF00" } } }));
  assert.equal(page.properties.get("--loom-accent"), "#00FF00");
  assert.equal(page.attributes.get("data-loom-appearance"), "dark");
  assert.equal(page.loom.theme.isLight, false);
});

test("http.fetch sends an object body as JSON and decodes the answer", async () => {
  const page = makePage({
    reply: answer({ status: 201, url: "https://a.atlassian.net/x", headers: {}, body: "{\"ok\":true}", bodyEncoding: "utf8" }),
  });
  const response = await page.loom.http.fetch("https://a.atlassian.net/x", { method: "post", body: { a: 1 } });
  const sent = page.posted[0].params;
  assert.equal(sent.method, "POST");
  assert.equal(sent.body, "{\"a\":1}");
  assert.equal(sent.headers["Content-Type"], "application/json");
  assert.equal(response.ok, true);
  assert.deepEqual(plain(response.json()), { ok: true });
});

test("a base64 body is decoded by text()", async () => {
  const body = Buffer.from("héllo", "utf8").toString("base64");
  const page = makePage({ reply: answer({ status: 200, url: "u", headers: {}, body, bodyEncoding: "base64" }) });
  const response = await page.loom.http.fetch("https://a.atlassian.net/x");
  assert.equal(response.text(), "héllo");
});

test("secrets.get and storage.get give null for a missing key", async () => {
  const page = makePage({ reply: answer({ value: null }) });
  assert.equal(await page.loom.secrets.get("token"), null);
  assert.equal(await page.loom.storage.get("config"), null);
});

test("window.loom cannot be replaced, and a second injection changes nothing", () => {
  const page = makePage();
  const first = page.loom;
  assert.throws(() => vm.runInContext("'use strict'; window.loom = {}", page.context));
  vm.runInContext(userScript({ extensionId: "dev.other.x", loomApi: 1, theme: { isLight: false, tokens: {} } }), page.context);
  assert.equal(page.window.loom, first);
  assert.equal(page.window.loom.extensionId, "dev.example.x");
  assert.ok(Object.isFrozen(page.window.loom.sessions));
});

test("without the Loom bridge, calls reject instead of hanging", async () => {
  const window = { console, document: { documentElement: null, addEventListener() {} } };
  window.window = window;
  const context = vm.createContext(window);
  vm.runInContext(userScript({ extensionId: "dev.example.x", loomApi: 1, theme: { isLight: true, tokens: {} } }), context);
  await assert.rejects(window.loom.info(), { code: "internalError" });
});

test("setStatus takes a string, options with a Date, or null to clear", async () => {
  const page = makePage({ reply: answer({ ok: true }) });
  await page.loom.ui.setStatus("🍅");
  await page.loom.ui.setStatus({ text: "☕", countdownTo: new Date(1_800_000_000_000) });
  await page.loom.ui.setStatus(null);
  assert.deepEqual(plain(page.posted.map((request) => request.params)),
    [{ text: "🍅" }, { text: "☕", countdownTo: 1_800_000_000_000 }, {}]);
  assert.deepEqual(page.posted.map((request) => request.method), ["ui.setStatus", "ui.setStatus", "ui.setStatus"]);
});

test("alarms and overlays accept Dates and send milliseconds", async () => {
  const page = makePage({ reply: answer({ name: "tick", scheduledTime: 1 }) });
  await page.loom.alarms.create("tick", { when: new Date(1_800_000_000_000) });
  await page.loom.ui.presentOverlay({ page: "break.html", until: new Date(1_800_000_060_000), dismissLabel: "Skip" });
  await page.loom.alarms.clear("tick");
  assert.deepEqual(plain(page.posted.map(({ method, params }) => ({ method, params }))), [
    { method: "alarms.create", params: { name: "tick", when: 1_800_000_000_000 } },
    { method: "ui.presentOverlay", params: { page: "break.html", until: 1_800_000_060_000, dismissLabel: "Skip" } },
    { method: "alarms.clear", params: { name: "tick" } },
  ]);
});
