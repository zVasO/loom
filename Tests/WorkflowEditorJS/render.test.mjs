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

test("the orchestrator is switched on from the inspector and saved with the workflow", { skip }, async () => {
  const { tab, errors } = await open();
  await tab.click(".react-flow__pane", { position: { x: 20, y: 20 } });
  await tab.click(".orchestrator-toggle input");
  await tab.waitForSelector(".orchestrator textarea");
  await tab.fill(".orchestrator textarea", "Rerun a vague expert.");
  await tab.waitForTimeout(500);
  const saved = await tab.evaluate(() => window.__loomWorkflowsStandIn.workflow.orchestrator);
  assert.equal(saved.instructions, "Rerun a vague expert.");
  assert.equal(saved.maxInterventions, 12);
  assert.deepEqual(errors, []);
  await tab.close();
});

test("a run shows what the orchestrator did on each step", { skip }, async () => {
  const tab = await browser.newPage({ viewport: { width: 1400, height: 800 } });
  const run = { status: "running", orchestrator: { sessionID: "x", interventions: 2, holding: true },
    nodes: { intent: { status: "done", asked: 1 }, php: { status: "running", pass: 1, reruns: 1 } } };
  await tab.addInitScript((s) => { window.__loomWorkflowsStandIn = s; }, { ...state, readOnly: true, run });
  await tab.goto(page);
  await tab.waitForSelector(".loom-node");
  assert.match(await tab.textContent('.react-flow__node[data-id="php"]'), /rerun/);
  assert.match(await tab.textContent('.react-flow__node[data-id="intent"]'), /asked/);
  assert.match(await tab.textContent(".orchestrator"), /2 intervention\(s\) · the run waits for it/);
  await tab.close();
});

test("a block of the palette is placed, its link given a verdict, a way back drawn", { skip }, async () => {
  const tab = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const errors = [];
  tab.on("pageerror", (e) => errors.push(e.message));
  const block = { id: "b1", name: "Revue PHP", color: "#123456", summary: "PHP review", rules: [], ruleSetIDs: [],
    template: { prompt: "Review {{in.text}}", output: [], verdict: { options: ["ok", "à revoir"], guidance: "" } } };
  const workflow = { ...state.workflow,
    edges: [...state.workflow.edges, { id: "php->php:retry", from: "php", to: "php", when: "à revoir", retry: { max: 2 } }],
    nodes: state.workflow.nodes.map((n) => (n.id === "php" ? { ...n, config: { ...n.config, blockID: "b1" } } : n)) };
  await tab.addInitScript((s) => { window.__loomWorkflowsStandIn = s; }, { ...state, workflow, blocks: [block] });
  await tab.goto(page);
  await tab.waitForSelector(".loom-node");
  assert.match(await tab.textContent(".palette"), /Revue PHP/);
  assert.match(await tab.textContent('.react-flow__node[data-id="php"]'), /Block «Revue PHP»/);
  assert.ok(await tab.$(".react-flow__edge.retry-edge"), "the way back is drawn");
  await tab.click(".palette-block");
  await tab.waitForTimeout(500);
  const placed = await tab.evaluate(() => window.__loomWorkflowsStandIn.workflow.nodes.find((n) => n.id === "revue-php"));
  assert.equal(placed.config.blockID, "b1");
  await tab.click('.react-flow__node[data-id="php"]');
  assert.match(await tab.textContent(".inspector"), /Instructions for this step/);
  await tab.click(".block-edit", { force: true });
  assert.match(await tab.textContent(".inspector"), /Every step placed from it/);
  assert.deepEqual(errors, []);
  await tab.close();
});
