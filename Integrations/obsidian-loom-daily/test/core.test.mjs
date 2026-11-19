import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { core } = require("../main.js");

const line = (object) => JSON.stringify(object);
const at = (minute) => `2026-11-17T10:${String(minute).padStart(2, "0")}:00.000Z`;

const transcript = [
  line({ type: "user", cwd: "/Users/ada/loom", gitBranch: "claude/fix-cache", sessionId: "s1",
         timestamp: at(0), message: { role: "user", content: "Old question" } }),
  line({ type: "user", cwd: "/Users/ada/loom", gitBranch: "claude/fix-cache", timestamp: at(20),
         message: { role: "user", content: "Fix the flaky login test <system-reminder>x</system-reminder>" } }),
  line({ type: "assistant", timestamp: at(21), message: { role: "assistant", content: [
    { type: "text", text: "I'll look at the test." },
    { type: "tool_use", name: "Bash", input: { command: "swift test --filter LoginTests\nmore" } },
    { type: "tool_use", name: "Edit", input: { file_path: "Tests/LoginTests.swift" } },
  ] } }),
  line({ type: "user", timestamp: at(22), message: { role: "user", content: [
    { type: "tool_result", tool_use_id: "t", content: "ok" } ] } }),
  line({ type: "user", timestamp: at(23), isMeta: true, message: { role: "user", content: "meta" } }),
  line({ type: "user", timestamp: at(24), message: { role: "user", content: "<command-name>/clear</command-name>" } }),
  "not json",
].join("\n");

test("activity after the last pass: words, tool lines, nothing else", () => {
  const activity = core.readActivity(transcript, Date.parse(at(10)));
  assert.equal(activity.cwd, "/Users/ada/loom");
  assert.equal(activity.branch, "claude/fix-cache");
  assert.deepEqual(activity.items.map((item) => [item.role, item.text]), [
    ["user", "Fix the flaky login test"],
    ["claude", "I'll look at the test."],
    ["tool", "Bash: swift test --filter LoginTests"],
    ["tool", "Edit: Tests/LoginTests.swift"],
  ]);
  assert.equal(core.sessionLabel(activity), "loom (claude/fix-cache)");
});

test("the prompt names each session and keeps its latest lines", () => {
  const activity = core.readActivity(transcript, Date.parse(at(10)));
  const prompt = core.buildPrompt([activity], { language: "French" });
  assert.match(prompt, /in French/);
  assert.match(prompt, /### loom \(claude\/fix-cache\)/);
  assert.match(prompt, /tool: Bash: swift test/);
});

test("a block goes at the end of its section, before the next heading", () => {
  const note = "# Tuesday\n\n## Loom\n- 09:30\n  - **loom** : a\n\n## Notes\nfree text\n";
  const next = core.insertUnderHeading(note, "## Loom", "- 10:00\n  - **loom** : b");
  assert.equal(next, "# Tuesday\n\n## Loom\n- 09:30\n  - **loom** : a\n- 10:00\n  - **loom** : b\n\n## Notes\nfree text\n");
});

test("no section yet: it is added at the end; an empty note gets it alone", () => {
  assert.equal(core.insertUnderHeading("# Tuesday\n", "## Loom", "- 10:00"), "# Tuesday\n\n## Loom\n- 10:00\n");
  assert.equal(core.insertUnderHeading("", "## Loom", "- 10:00"), "## Loom\n- 10:00\n");
});

test("the summary's bullets are nested under the time", () => {
  assert.equal(core.formatBlock("10:30", "- **loom** : fixed it\n\n**web** : deployed"),
    "- 10:30\n  - **loom** : fixed it\n  - **web** : deployed");
});

test("only whole lines are consumed: a line being written waits", () => {
  assert.deepEqual(core.wholeLines('{"a":1}\n{"b":'), { text: '{"a":1}\n', consumed: 8 });
  assert.deepEqual(core.wholeLines('{"b":'), { text: "", consumed: 0 });
});
