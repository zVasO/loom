// Launching Chromium as Loom does (ADR-0015): CDP over --remote-debugging-pipe
// only — no TCP port another process could drive the agent's logged-in
// profile through — and a browser that cannot outlive Loom: when the pipe
// closes (Loom quits, or is killed), Chromium and its whole process group go.
// Also pins fixtures/flags.json, the flag list the Swift ChromiumFlags
// tests compare against.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, readlinkSync } from "node:fs";
import { BROWSERS, launch, linuxSandboxUnusable, processGroup, taggedProcesses, delay, within, performance } from "./lib/cdp.mjs";
import { canonicalArgs, forbiddenIn, FLAGS, readFlagsFixture, renderFlagsDocument, writeFlagsFixture } from "./lib/flags.mjs";
import { openTab } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

test("fixtures/flags.json is what lib/flags.mjs says (LOOM_CDP_UPDATE=1 rewrites it)", () => {
  if (process.env.LOOM_CDP_UPDATE === "1") writeFlagsFixture();
  const written = readFlagsFixture();
  assert.ok(written, "fixtures/flags.json is missing: run with LOOM_CDP_UPDATE=1");
  assert.equal(written, renderFlagsDocument(), "fixtures/flags.json drifted from lib/flags.mjs: run with LOOM_CDP_UPDATE=1");
});

test("Loom's command line never carries a forbidden flag, in any mode", () => {
  for (const kind of Object.keys(FLAGS.headless)) {
    for (const mode of [{}, { fencePort: 4242, allowedHosts: ["api.test"] }]) {
      const args = canonicalArgs(kind, { userDataDir: "/tmp/profile", ...mode });
      assert.deepEqual(forbiddenIn(args), [], `${kind} ${JSON.stringify(mode)}`);
      assert.ok(args.includes("--remote-debugging-pipe"));
      assert.equal(args.filter((arg) => arg.startsWith("--disable-features=")).length, 1, "Chromium reads one --disable-features only");
    }
  }
  assert.deepEqual(forbiddenIn(["--no-sandbox", "--remote-debugging-port=9222", "--no-sandboxing"]), ["--no-sandbox", "--remote-debugging-port=9222"]);
  // The four the plan names never leave the forbidden list.
  for (const flag of ["--no-sandbox", "--remote-debugging-port", "--enable-automation", "--disable-popup-blocking"]) {
    assert.ok(FLAGS.forbidden.includes(flag), `${flag} is forbidden`);
  }
});

test("the binaries this run uses", (t) => {
  for (const browser of BROWSERS) t.diagnostic(`${browser.kind}: ${browser.path} (from ${browser.source})`);
  if (!BROWSERS.length) t.diagnostic("none found: every Chromium suite is skipped");
  t.diagnostic(`Chromium's sandbox: ${linuxSandboxUnusable() ? "off (--no-sandbox: Linux as root, or user namespaces restricted)" : "on"}${process.getuid ? `, uid ${process.getuid()}` : ""}`);
});

/** TCP listening sockets of `pids` from /proc (Linux): null when /proc cannot say. */
function listeningFromProc(pids) {
  const listening = new Map();
  let tables = 0;
  for (const file of ["/proc/net/tcp", "/proc/net/tcp6"]) {
    let text = "";
    try { text = readFileSync(file, "utf8"); tables++; } catch { continue; }
    for (const line of text.split("\n").slice(1)) {
      const columns = line.trim().split(/\s+/);
      if (columns[3] === "0A") listening.set(columns[9], columns[1]);
    }
  }
  if (!tables) return null;
  const held = [];
  for (const pid of pids) {
    let descriptors = [];
    try { descriptors = readdirSync(`/proc/${pid}/fd`); } catch { continue; }
    for (const descriptor of descriptors) {
      let link = "";
      try { link = readlinkSync(`/proc/${pid}/fd/${descriptor}`); } catch { continue; }
      const inode = /^socket:\[(\d+)\]$/.exec(link)?.[1];
      if (inode && listening.has(inode)) held.push(`pid ${pid} listens on ${listening.get(inode)}`);
    }
  }
  return held;
}

const LSOF = ["/usr/sbin/lsof", "/usr/bin/lsof"].find((path) => existsSync(path)) ?? null;

/** The same from lsof (macOS): null when there is no lsof or it fails. */
function listeningFromLsof(pids) {
  if (!LSOF) return null;
  // lsof may exit 1 when one of the -p pids has no matching file: its output is read whatever the status.
  const parse = (output) => String(output || "").split("\n").filter((line) => line && !line.startsWith("COMMAND"));
  try {
    return parse(execFileSync(LSOF, ["-a", "-nP", "-iTCP", "-sTCP:LISTEN", "-p", pids.join(",")], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  } catch (error) {
    return error.status === 1 ? parse(error.stdout) : null;
  }
}

/** TCP sockets in LISTEN state held by any of `pids`: /proc on Linux, lsof elsewhere; null when neither can say. */
const listeningSockets = (pids) => (process.platform === "linux" ? listeningFromProc(pids) : listeningFromLsof(pids));

eachBrowser((browser) => {
  let server;
  before(async () => { server = await startServer(); });
  after(async () => { await server?.close(); });

  test("the pipe answers Browser.getVersion: a Chromium at or above the floor (120)", options(), async (t) => {
    const started = performance.now();
    const chrome = await launch(browser);
    try {
      t.diagnostic(`${chrome.version.product}, first reply after ${Math.round(performance.now() - started)} ms, sandbox ${chrome.args.includes("--no-sandbox") ? "off" : "on"}`);
      assert.match(chrome.version.product, /Chrome\/\d+\./);
      assert.equal(chrome.version.protocolVersion, "1.3");
      assert.ok(chrome.major >= 120, `major ${chrome.major}`);
      assert.deepEqual(forbiddenIn(chrome.args).filter((flag) => flag !== "--no-sandbox"), []);
      if (process.platform !== "linux") assert.ok(!chrome.args.includes("--no-sandbox"), "--no-sandbox is for Linux test runs only");
    } finally {
      await chrome.close();
    }
  });

  test("no process of the browser listens on a TCP port", options(), async (t) => {
    const chrome = await launch(browser);
    try {
      const tab = await openTab(chrome, { url: server.url("/") });
      assert.equal(await tab.evaluate("document.title"), "Todos");
      const pids = processGroup(chrome.pid);
      assert.ok(pids.includes(chrome.pid), "the browser leads its own process group");
      t.diagnostic(`${pids.length} processes in the group`);
      const listening = listeningSockets(pids);
      if (listening === null) return t.skip("neither /proc nor lsof can list listening sockets here");
      assert.deepEqual(listening, []);
    } finally {
      await chrome.close();
    }
  });

  test("control: the same check sees the listener --remote-debugging-port opens (/proc and lsof alike)", options(), async (t) => {
    // Test-only: the flag Loom forbids, to prove the check above is not blind.
    const chrome = await launch(browser, { args: ["--remote-debugging-port=0"] });
    try {
      await openTab(chrome, { url: server.url("/") });
      const pids = processGroup(chrome.pid);
      const methods = [["platform", listeningSockets], ...(process.platform === "linux" ? [["lsof", listeningFromLsof]] : [])];
      let checked = 0;
      for (const [name, method] of methods) {
        // The port opens a moment after the first reply: a few tries.
        let found = method(pids);
        for (let waited = 0; found !== null && !found.length && waited < 3000; waited += 100) {
          await delay(100);
          found = method(pids);
        }
        if (found === null) { t.diagnostic(`${name}: cannot list sockets here`); continue; }
        checked++;
        t.diagnostic(`${name}: ${found.join("; ")}`);
        assert.ok(found.length >= 1, `${name} saw no listener`);
      }
      if (!checked) t.skip("neither /proc nor lsof can list listening sockets here");
    } finally {
      await chrome.close();
    }
  });

  test("closing the pipe ends Chromium and every process of its group, and those outside it", options(), async (t) => {
    const chrome = await launch(browser);
    try {
      await openTab(chrome, { url: server.url("/") });
      const before = processGroup(chrome.pid);
      assert.ok(before.length >= 2, `a browser and its renderer at least: ${before.length}`);
      // The full browser's crash handler double-forks into a session of its own:
      // no group kill reaches it, it must end by itself.
      const tagged = taggedProcesses(chrome.tag);
      if (tagged) assert.ok(tagged.some(({ pid }) => pid === chrome.pid), "the launch's tag is in the browser's environment");
      const outside = tagged?.filter(({ pid }) => !before.includes(pid)) ?? null;
      t.diagnostic(outside === null ? "processes outside the group: not looked for on this platform"
        : `processes outside the group: ${outside.map(({ pid, comm }) => `${comm} ${pid}`).join(", ") || "none"}`);
      const started = performance.now();
      chrome.child.stdio[3].end();   // Loom closing its end of fd 3: what quitting (or dying) does
      const exit = await within(chrome.exited, 10_000);
      assert.ok(exit, "Chromium is still running 10 s after the end of its pipe");
      t.diagnostic(`exited after ${Math.round(performance.now() - started)} ms: ${JSON.stringify(exit)}`);
      let left = processGroup(chrome.pid);
      for (let waited = 0; left.length && waited < 5000; waited += 100) {
        await delay(100);
        left = processGroup(chrome.pid);
      }
      assert.deepEqual(left, [], "processes of the group outlived the browser");
      if (outside !== null) {
        let stray = taggedProcesses(chrome.tag);
        for (let waited = 0; stray.length && waited < 5000; waited += 100) {
          await delay(100);
          stray = taggedProcesses(chrome.tag);
        }
        assert.deepEqual(stray.map(({ pid, comm }) => `${comm} ${pid}`), [], "a process of this launch outlived the browser");
      }
    } finally {
      await chrome.close();
    }
  });
});
