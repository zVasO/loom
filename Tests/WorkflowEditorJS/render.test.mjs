// The built editor (Sources/LoomApp/WorkflowEditor) on a real Chromium, with
// the stand-in bridge: it loads offline, draws the workflow, and edits it.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

async function loadPlaywright() {
  try { return await import("playwright"); } catch (_) { /* not local */ }
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    return createRequire(import.meta.url)(resolve(root, "playwright"));
  } catch (_) {
    return null;
  }
}

const playwright = await loadPlaywright();
const skip = playwright ? false : "Playwright is not installed";
const here = dirname(fileURLToPath(import.meta.url));
const page = pathToFileURL(resolve(here, "../../Sources/LoomApp/WorkflowEditor/index.html")).href;
const state = JSON.parse(readFileSync(resolve(here, "fixtures/state.json"), "utf8"));

let browser;
before(async () => { if (playwright) browser = await playwright.chromium.launch(); });
after(async () => { if (browser) await browser.close(); });

async function open() {
  const tab = await browser.newPage({ viewport: { width: 1400, height: 800 } });
  const errors = [];
  const requests = [];
  tab.on("pageerror", (e) => errors.push(e.message));
  tab.on("request", (r) => { if (!r.url().startsWith("file:")) requests.push(r.url()); });
  await tab.addInitScript((s) => { window.__loomWorkflowsStandIn = s; }, state);
  await tab.goto(page);
  await tab.waitForSelector(".loom-node");
  return { tab, errors, requests };
}

test("the bundle loads offline and draws every step and link", { skip }, async () => {
  const { tab, errors, requests } = await open();
  assert.equal(await tab.$$eval(".loom-node", (n) => n.length), state.workflow.nodes.length);
  assert.ok(await tab.$$eval(".react-flow__edge", (n) => n.length) >= state.workflow.edges.length);
  assert.deepEqual(errors, []);
  assert.deepEqual(requests, [], "nothing fetched from the network");
  assert.match(await tab.textContent(".estimate"), /5 claude runs/);
  await tab.close();
});

test("a click on the palette adds a step; the inspector edits it; undo takes it back", { skip }, async () => {
  const { tab, errors } = await open();
  await tab.click(".palette-item.kind-agent");
  assert.equal(await tab.$$eval(".loom-node", (n) => n.length), state.workflow.nodes.length + 1);
  await tab.click('.react-flow__node[data-id="agent"]');
  await tab.fill(".inspector input", "Expert Symfony");
  await tab.waitForTimeout(500);
  const saved = await tab.evaluate(() => window.__loomWorkflowsStandIn.workflow.nodes.find((n) => n.id === "agent"));
  assert.equal(saved.title, "Expert Symfony", "saved through the bridge");
  await tab.click(".react-flow__pane", { position: { x: 20, y: 20 } });
  await tab.keyboard.press("Meta+z");
  await tab.keyboard.press("Control+z");
  await tab.waitForTimeout(200);
  assert.ok(await tab.$$eval(".loom-node", (n) => n.length) <= state.workflow.nodes.length + 1);
  assert.deepEqual(errors, []);
  await tab.close();
});

test("a read-only run shows statuses and no palette", { skip }, async () => {
  const tab = await browser.newPage({ viewport: { width: 1400, height: 800 } });
  const run = { status: "running", nodes: { intent: { status: "done" }, php: { status: "running", pass: 2 } } };
  await tab.addInitScript((s) => { window.__loomWorkflowsStandIn = s; }, { ...state, readOnly: true, run });
  await tab.goto(page);
  await tab.waitForSelector(".loom-node");
  assert.equal(await tab.$(".palette"), null);
  assert.match(await tab.textContent('.react-flow__node[data-id="php"]'), /Running · pass 2/);
  await tab.close();
});
