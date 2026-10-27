// The workflow editor's pure side (ADR-0017): a Loom workflow ⇄ React
// Flow, ids, links allowed, what a prompt may name, undo.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as G from "../../WorkflowEditor/src/graph.js";

const state = JSON.parse(readFileSync(new URL("./fixtures/state.json", import.meta.url), "utf8"));
const workflow = state.workflow;

test("ids are slugs nobody uses", () => {
  assert.equal(G.slugify("Revue sécurité!"), "revue-securite");
  assert.equal(G.slugify("  "), "step");
  assert.equal(G.uniqueId("php", ["php", "php-2"]), "php-3");
  assert.equal(G.uniqueId("Agent", ["start"]), "agent");
});

test("a workflow becomes nodes and edges, a loop's way back drawn but not editable", () => {
  const flow = G.toFlow(workflow, { experts: state.experts, issues: state.issues });
  assert.equal(flow.nodes.length, workflow.nodes.length);
  const php = flow.nodes.find((n) => n.id === "php");
  assert.equal(php.data.expert.name, "Expert PHP");
  assert.equal(php.data.issues.length, 1);
  const yes = flow.edges.find((e) => e.id === "check->report:yes");
  assert.equal(yes.sourceHandle, "yes");
  assert.equal(yes.label, "Yes");
  const back = flow.edges.find((e) => e.data && e.data.loopBack);
  assert.equal(back.source, "loop");
  assert.equal(back.target, "php");
  assert.equal(back.deletable, false);
});

test("a run lights the nodes and animates what leaves a running step", () => {
  const run = { nodes: { php: { status: "running", pass: 2 }, intent: { status: "done" } } };
  const flow = G.toFlow(workflow, { run });
  assert.equal(flow.nodes.find((n) => n.id === "php").data.status, "running");
  assert.equal(flow.nodes.find((n) => n.id === "php").data.pass, 2);
  assert.equal(flow.edges.find((e) => e.id === "php->check").animated, true);
  assert.equal(flow.edges.find((e) => e.id === "intent->php").animated, false);
});

test("back from the flow: positions rounded, loop edges dropped, a deleted step cleaned out of loops", () => {
  const flow = G.toFlow(workflow);
  const moved = flow.nodes.map((n) => (n.id === "pr" ? { ...n, position: { x: 300.4, y: 99.6 } } : n));
  const back = G.fromFlow(workflow, moved, flow.edges);
  assert.deepEqual(back.nodes.find((n) => n.id === "pr").position, { x: 300, y: 100 });
  assert.equal(back.edges.length, workflow.edges.length, "the loop's drawn way back is not a link");
  assert.deepEqual(back.edges.find((e) => e.from === "check" && e.to === "loop"), { id: "check->loop:no", from: "check", to: "loop", branch: "no" });
  const withoutPhp = G.fromFlow(workflow, flow.nodes.filter((n) => n.id !== "php"), flow.edges);
  assert.equal(withoutPhp.nodes.find((n) => n.id === "loop").config.targets.length, 0);
  assert.ok(!withoutPhp.edges.some((e) => e.from === "php" || e.to === "php"));
});

test("links: no self-link, nothing into Start, no duplicate, no circle", () => {
  assert.equal(G.canConnect(workflow, { source: "pr", target: "pr" }), false);
  assert.equal(G.canConnect(workflow, { source: "pr", target: "start" }), false);
  assert.equal(G.canConnect(workflow, { source: "start", target: "pr" }), false, "already there");
  assert.equal(G.canConnect(workflow, { source: "php", target: "intent" }), false, "a circle");
  assert.equal(G.canConnect(workflow, { source: "pr", target: "php" }), true);
  assert.equal(G.canConnect(workflow, { source: "check", target: "php", sourceHandle: "back" }), false);
});

test("a prompt may name the steps before it, never Start, and earlier passes", () => {
  const groups = G.variablesFor(workflow, "php");
  const steps = groups.find((g) => g.label === "Steps before").items;
  assert.ok(steps.includes("steps.intent.intent"));
  assert.ok(steps.includes("steps.pr.files"));
  assert.ok(steps.includes("steps.ticket.acceptanceCriteria"));
  assert.ok(!steps.some((s) => s.startsWith("steps.start")));
  assert.ok(!steps.some((s) => s.startsWith("steps.report")), "nothing after it");
  assert.ok(groups.find((g) => g.label === "Previous pass").items.includes("previous.intent"));
  assert.deepEqual(G.loopCandidates(workflow, "loop").map((n) => n.id).sort(), ["check", "intent", "php", "pr", "ticket"]);
});

test("new steps start with a usable configuration", () => {
  const agent = G.newNode("agent", workflow, { x: 10.2, y: 20.7 });
  assert.equal(agent.id, "agent");
  assert.deepEqual(agent.position, { x: 10, y: 21 });
  assert.equal(agent.config.mode, "headless");
  assert.equal(G.newNode("loop", workflow, { x: 0, y: 0 }).id, "loop-2");
  assert.equal(G.defaultConfig("artifact").theme, "current");
});

test("undo and redo walk the snapshots", () => {
  const history = new G.History(2);
  history.push({ v: 1 });
  history.push({ v: 2 });
  history.push({ v: 3 });
  assert.deepEqual(history.undo({ v: 4 }), { v: 3 });
  assert.deepEqual(history.undo({ v: 3 }), { v: 2 });
  assert.equal(history.undo({ v: 2 }), null, "bounded");
  assert.deepEqual(history.redo({ v: 2 }), { v: 3 });
});

test("the estimate reads as an order of magnitude", () => {
  assert.equal(G.formatEstimate({ runs: 17, lowUSD: 0.8, highUSD: 4 }), "≈ 17 claude runs · 0.80–4.00 $");
  assert.equal(G.formatEstimate({ runs: 1, lowUSD: null, highUSD: null }), "≈ 1 claude run");
  assert.equal(G.formatEstimate(null), "");
});
