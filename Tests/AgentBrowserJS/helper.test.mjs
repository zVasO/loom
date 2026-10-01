// The snapshot's text format, pinned on hand-built trees: what the agent
// reads must look like Playwright MCP's (agents are trained on it), and the
// budget must never print a ref that will not resolve.
import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { pureHelper, serializerSource, helperSource } from "./extract.mjs";

const pure = pureHelper();

test("scalars stay plain when YAML allows it, JSON-quoted otherwise", () => {
  assert.equal(pure.yamlScalar("Hello world"), "Hello world");
  assert.equal(pure.yamlScalar("key: value"), JSON.stringify("key: value"));
  assert.equal(pure.yamlScalar("- dash"), JSON.stringify("- dash"));
  assert.equal(pure.yamlScalar("true"), JSON.stringify("true"));
  assert.equal(pure.yamlScalar("42"), JSON.stringify("42"));
  assert.equal(pure.yamlScalar(""), '""');
  assert.equal(pure.yamlScalar("trailing "), JSON.stringify("trailing "));
});

test("a node's head lists its attributes in Playwright's order", () => {
  const head = pure.nodeHead({
    role: "checkbox", name: "Milk", ref: "e5",
    attrs: { checked: true, disabled: true, active: true, cursorPointer: true },
  });
  assert.equal(head, 'checkbox "Milk" [checked] [disabled] [active] [ref=e5] [cursor=pointer]');
  assert.equal(pure.nodeHead({ role: "heading", name: "Todos", ref: "e2", attrs: { level: 1 } }),
    'heading "Todos" [level=1] [ref=e2]');
  assert.equal(pure.nodeHead({ role: "button", name: "Menu", attrs: { expanded: false } }),
    'button "Menu" [expanded=false]');
});

test("children render indented; a lone text child goes inline; links carry their url", () => {
  const tree = [{
    role: "list", name: "", attrs: {}, ref: "e1", children: [
      { role: "listitem", name: "", attrs: {}, ref: "e2", children: ["milk"] },
      { role: "link", name: "Docs", attrs: {}, ref: "e3", url: "/docs", children: [] },
      { role: "textbox", name: "Email", attrs: {}, ref: "e4", value: "a@b.c", children: [] },
    ],
  }];
  const { text, printed, truncated } = pure.renderTree(tree, {});
  assert.equal(text, [
    "- list [ref=e1]:",
    "  - listitem [ref=e2]: milk",
    '  - link "Docs" [ref=e3]:',
    "    - /url: /docs",
    '  - textbox "Email" [ref=e4]: a@b.c',
  ].join("\n"));
  assert.deepEqual([...printed], ["e1", "e2", "e3", "e4"], "built in the helper's realm: compared as values");
  assert.equal(truncated, false);
});

test("loose text between elements becomes `- text:` lines", () => {
  const { text } = pure.renderTree([{ role: "paragraph", name: "", attrs: {}, children: [
    "Hello", { role: "link", name: "you", attrs: {}, children: [] }, "there",
  ] }], {});
  assert.equal(text, ["- paragraph:", "  - text: Hello", '  - link "you"', "  - text: there"].join("\n"));
});

test("the budget cuts cleanly: every printed ref is complete, none beyond", () => {
  const many = Array.from({ length: 50 }, (_, i) => ({
    role: "button", name: "Button number " + i, attrs: {}, ref: "e" + (i + 1), children: [],
  }));
  const { text, printed, truncated } = pure.renderTree(many, { budget: 400 });
  assert.equal(truncated, true);
  assert.ok(text.length <= 400 + 120, "the text stays near its budget");
  for (const ref of printed) assert.ok(text.includes("[ref=" + ref + "]"), ref + " is printed");
  for (let i = printed.length + 1; i <= 50; i++) assert.ok(!text.includes("[ref=e" + i + "]"), "e" + i + " is not");
  assert.match(text, /snapshot truncated/);
});

test("depth stops descending and says so", () => {
  const tree = [{ role: "list", name: "", attrs: {}, children: [
    { role: "listitem", name: "", attrs: {}, children: [{ role: "button", name: "deep", attrs: {}, children: [] }] },
  ] }];
  const { text, depthCut } = pure.renderTree(tree, { depth: 1 });
  assert.equal(depthCut, true);
  assert.equal(text, ["- list:", "  - listitem:", "    - …"].join("\n"));
});

test("refs look like Playwright's: e12, f1e3", () => {
  assert.ok(pure.REF_RE.test("e12"));
  assert.ok(pure.REF_RE.test("f1e3"));
  assert.ok(!pure.REF_RE.test("#e12"));
  assert.ok(!pure.REF_RE.test("button"));
});

test("evaluate's serializer answers JSON, whatever the value", () => {
  const serialize = vm.runInNewContext(serializerSource(), { JSON, WeakSet, Map, Set, Object, Array, String, Error });
  assert.equal(serialize(undefined), "undefined");
  assert.equal(serialize(42), "42");
  assert.equal(serialize({ a: [1, 2] }), JSON.stringify({ a: [1, 2] }, null, 2));
  const cyclic = { name: "x" };
  cyclic.self = cyclic;
  assert.match(serialize(cyclic), /\[Circular\]/);
  assert.match(serialize({ f() {} }), /\[Function f\]/);
  assert.equal(serialize(new Map([["k", 1]])), JSON.stringify({ k: 1 }, null, 2));
});

test("the helper installs once and freezes its surface", () => {
  const context = vm.createContext({ WeakRef, WeakMap, Map, Set, JSON, Math, Object, String, Number, Array });
  vm.runInContext(helperSource(), context);
  const first = context.__loomAgent;
  vm.runInContext(helperSource(), context);
  assert.equal(context.__loomAgent, first, "a second injection keeps the first");
  assert.ok(Object.isFrozen(first));
});
