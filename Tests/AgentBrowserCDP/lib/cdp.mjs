// Chromium over --remote-debugging-pipe, with no dependency: what LoomChromium
// does in Swift (CDPConnection, ChromiumSpawn, ChromiumProcess), in Node, so
// every CDP sequence the engine relies on is checked against a real Chromium.
//
// The pipe: Chromium reads commands on fd 3 and writes replies and events on
// fd 4, one JSON object per message, each followed by a NUL byte. Sessions
// are "flattened": a target's messages carry its sessionId on the same pipe.
//
// Playwright is never used to drive anything here; its install directories
// are only searched for the binaries (Playwright's own downloads).
import { spawn, execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { accessSync, constants, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import { canonicalArgs, FLAGS } from "./flags.mjs";

export { performance };

// ---------------------------------------------------------------------------
// Finding the binaries

const KIND_LABELS = { headlessShell: "chrome-headless-shell", fullBrowser: "chromium --headless=new" };

function isExecutable(path) {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function list(directory) {
  try { return readdirSync(directory); } catch { return []; }
}

// Inside <root>/chromium-<rev>/ and <root>/chromium_headless_shell-<rev>/:
// one platform directory (chrome-linux, chrome-mac, chrome-mac-arm64,
// chrome-headless-shell-mac-arm64, …), then the executable. A `.real` is the
// binary behind a shell wrapper (as in /opt/pw-browsers): the harness runs the
// binary itself, with Loom's flags and nothing else.
const LAYOUTS = {
  fullBrowser: {
    directory: /^chromium-(\d+)$/,
    executables: ["chrome", "Chromium.app/Contents/MacOS/Chromium",
      "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"],
  },
  headlessShell: {
    directory: /^chromium_headless_shell-(\d+)$/,
    executables: ["headless_shell.real", "headless_shell", "chrome-headless-shell"],
  },
};

function searchRegistry(root, kind) {
  const layout = LAYOUTS[kind];
  const builds = list(root)
    .map((name) => ({ name, revision: Number(layout.directory.exec(name)?.[1]) }))
    .filter((build) => Number.isFinite(build.revision))
    .sort((a, b) => b.revision - a.revision);
  for (const build of builds) {
    for (const platform of list(join(root, build.name)).filter((name) => name.startsWith("chrome"))) {
      for (const executable of layout.executables) {
        const path = join(root, build.name, platform, executable);
        if (isExecutable(path)) return path;
      }
    }
  }
  return null;
}

/**
 * The binaries to run every suite on, the headless shell (the engine's main
 * target) first. LOOM_CHROMIUM / LOOM_CHROMIUM_SHELL name them outright;
 * otherwise Playwright's install directories are searched, then
 * /opt/pw-browsers. LOOM_CDP_KINDS=headlessShell (or fullBrowser) keeps one.
 */
export function discoverBrowsers(env = process.env) {
  const roots = [...new Set([
    env.PLAYWRIGHT_BROWSERS_PATH,
    join(homedir(), ".cache", "ms-playwright"),
    join(homedir(), "Library", "Caches", "ms-playwright"),
    "/opt/pw-browsers",
  ].filter((root) => root && root !== "0"))];
  const named = { headlessShell: env.LOOM_CHROMIUM_SHELL, fullBrowser: env.LOOM_CHROMIUM };
  const wanted = (env.LOOM_CDP_KINDS || "headlessShell,fullBrowser").split(",").map((kind) => kind.trim());
  const found = [];
  for (const kind of ["headlessShell", "fullBrowser"]) {
    if (!wanted.includes(kind)) continue;
    let path = null;
    let source = null;
    if (named[kind]) {
      if (!isExecutable(named[kind])) throw new Error(`${kind === "fullBrowser" ? "LOOM_CHROMIUM" : "LOOM_CHROMIUM_SHELL"}=${named[kind]} is not an executable file`);
      path = named[kind];
      source = "environment";
    }
    for (const root of roots) {
      if (path) break;
      path = searchRegistry(root, kind);
      source = root;
    }
    if (path) found.push({ kind, path, source, label: KIND_LABELS[kind] });
  }
  return found;
}

export const BROWSERS = discoverBrowsers();
export const NO_BROWSER =
  "no Chromium found: set LOOM_CHROMIUM / LOOM_CHROMIUM_SHELL, or `npx playwright@1.56.1 install chromium chromium-headless-shell`";

// ---------------------------------------------------------------------------
// The environment and the test-only flags

/** The variable that tags every process of one launch (taggedProcesses). */
export const LAUNCH_TAG = "LOOM_CDP_LAUNCH";

/**
 * Chromium's whole environment: nothing inherited but these, so no proxy
 * variable ever reaches it; `tag` marks the launch's processes, those outside
 * its process group included (the full browser's crash handler).
 */
export function chromiumEnvironment(env = process.env, tag, pathPrefix) {
  const path = "/usr/bin:/bin:/usr/sbin:/sbin";
  const kept = { HOME: env.HOME || homedir(), PATH: pathPrefix ? `${pathPrefix}:${path}` : path, LANG: "en_US.UTF-8", TZ: env.TZ || "UTC" };
  for (const name of ["TMPDIR", "USER", "LOGNAME"]) if (env[name]) kept[name] = env[name];
  if (tag) kept[LAUNCH_TAG] = tag;
  return kept;
}

/**
 * The live processes whose environment carries this launch's tag, wherever
 * they are — Linux only (/proc); null elsewhere. A process whose environment
 * cannot be read (a sandboxed renderer) is not seen: those are in the group.
 */
export function taggedProcesses(tag) {
  if (process.platform !== "linux" || !tag) return null;
  const needle = Buffer.from(`${LAUNCH_TAG}=${tag}\0`);
  const found = [];
  for (const name of list("/proc")) {
    if (!/^\d+$/.test(name)) continue;
    let environment;
    try { environment = readFileSync(`/proc/${name}/environ`); } catch { continue; }
    if (environment.indexOf(needle) === -1) continue;
    let stat = "";
    try { stat = readFileSync(`/proc/${name}/stat`, "utf8"); } catch { continue; }
    // pid (comm) state …: comm may hold spaces or parentheses, the state follows the last ")".
    const close = stat.lastIndexOf(")");
    const state = stat.slice(close + 2, close + 3);
    if (state === "Z" || state === "X") continue;
    found.push({ pid: Number(name), comm: stat.slice(stat.indexOf("(") + 1, close) });
  }
  return found;
}

function readSmall(path) {
  try { return readFileSync(path, "utf8").trim(); } catch { return null; }
}

/**
 * Chromium's sandbox needs unprivileged user namespaces on Linux: root (this
 * container) and Ubuntu 24.04's AppArmor default (GitHub's ubuntu-latest)
 * refuse it. The harness then adds --no-sandbox — on Linux only; Loom never
 * passes it (flags.json lists it as forbidden).
 */
export function linuxSandboxUnusable() {
  if (process.platform !== "linux") return false;
  if (process.getuid?.() === 0) return true;
  if (readSmall("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") === "1") return true;
  if (readSmall("/proc/sys/kernel/unprivileged_userns_clone") === "0") return true;
  return false;
}

// ---------------------------------------------------------------------------
// Small async helpers

export const delay = (ms) => new Promise((done) => setTimeout(done, ms));
const unrefDelay = (ms) => new Promise((done) => setTimeout(done, ms).unref());

/** `promise`, or an error naming `label` after `ms`. */
export function withTimeout(promise, ms, label = "operation") {
  return Promise.race([promise, unrefDelay(ms).then(() => { throw new Error(`${label}: no answer in ${ms} ms`); })]);
}

/** `promise`'s value, or `fallback` after `ms` — a timer that never keeps the process alive. */
export function within(promise, ms, fallback = null) {
  return Promise.race([promise, unrefDelay(ms).then(() => fallback)]);
}

/** Never rejects: { ok, value | error, at } — `at` is when it settled (performance.now()). */
export function settle(promise) {
  return promise.then(
    (value) => ({ ok: true, value, at: performance.now() }),
    (error) => ({ ok: false, error, at: performance.now() }),
  );
}

/** Resolves `true` when `promise` settles within `ms`, `false` otherwise. */
export async function settlesWithin(promise, ms) {
  const marker = Symbol("pending");
  const outcome = await Promise.race([promise.then(() => true, () => true), unrefDelay(ms).then(() => marker)]);
  return outcome !== marker;
}

// ---------------------------------------------------------------------------
// The connection

export class CDPError extends Error {
  constructor(method, error) {
    super(`${method}: ${error.message}${error.data ? ` (${error.data})` : ""}`);
    this.method = method;
    this.code = error.code;
    this.cdpMessage = error.message;
  }
}

/**
 * One pipe: ids correlated per connection, events emitted in wire order as
 * they arrive — before any later reply is resolved, as LoomChromium applies
 * them. Events are emitted as "<sessionId>|<method>" for a session and
 * "<method>" for the browser; "*" sees every message.
 */
export class Connection extends EventEmitter {
  constructor(writable, readable) {
    super();
    this.setMaxListeners(0);
    this.writable = writable;
    this.nextId = 1;
    this.pending = new Map();
    this.partial = [];
    this.closed = false;
    this.recording = null;
    this.sequence = 0;
    writable.on("error", () => {});
    readable.on("error", () => {});
    readable.on("data", (chunk) => this.receive(chunk));
    readable.on("close", () => this.shut("the pipe closed"));
  }

  receive(chunk) {
    let start = 0;
    let end;
    while ((end = chunk.indexOf(0, start)) !== -1) {
      this.partial.push(chunk.subarray(start, end));
      const text = Buffer.concat(this.partial).toString("utf8");
      this.partial = [];
      start = end + 1;
      let message;
      try { message = JSON.parse(text); } catch { continue; }
      this.dispatch(message);
    }
    if (start < chunk.length) this.partial.push(chunk.subarray(start));
  }

  dispatch(message) {
    const at = performance.now();
    const seq = ++this.sequence;
    if ("id" in message) {
      const call = this.pending.get(message.id);
      this.recording?.push({ seq, at, dir: "reply", id: message.id, method: call?.method, sessionId: message.sessionId, error: message.error?.message, result: message.result });
      if (!call) return;
      this.pending.delete(message.id);
      if (message.error) call.reject(new CDPError(call.method, message.error));
      else call.resolve(message.result);
      return;
    }
    this.recording?.push({ seq, at, dir: "event", method: message.method, sessionId: message.sessionId, params: message.params });
    this.emit("*", message);
    this.emit(message.sessionId ? `${message.sessionId}|${message.method}` : message.method, message.params, message);
  }

  shut(reason) {
    if (this.closed) return;
    this.closed = true;
    for (const call of this.pending.values()) call.reject(new Error(`${call.method}: ${reason}`));
    this.pending.clear();
    this.emit("close", reason);
  }

  frame(method, params, sessionId) {
    const id = this.nextId++;
    const message = sessionId ? { id, method, params, sessionId } : { id, method, params };
    let call;
    const promise = new Promise((resolve, reject) => { call = { resolve, reject, method }; });
    // Every reply is someone's business only if awaited: an unawaited call
    // that fails (the pipe closing under it) must not end the test run.
    promise.catch(() => {});
    promise.id = id;
    this.pending.set(id, call);
    this.recording?.push({ seq: ++this.sequence, at: performance.now(), dir: "send", id, method, sessionId, params });
    return { text: JSON.stringify(message) + "\0", promise };
  }

  /** One command; the promise carries `.id`. */
  send(method, params = {}, sessionId) {
    if (this.closed) return Promise.reject(new Error(`${method}: the pipe is closed`));
    const { text, promise } = this.frame(method, params, sessionId);
    this.writable.write(text);
    return promise;
  }

  /** Several commands framed into ONE write() — LoomChromium's post(batch:). One promise each. */
  sendBatch(commands, sessionId) {
    if (this.closed) return commands.map(([method]) => Promise.reject(new Error(`${method}: the pipe is closed`)));
    const frames = commands.map(([method, params = {}]) => this.frame(method, params, sessionId));
    this.writable.write(frames.map((frame) => frame.text).join(""));
    return frames.map((frame) => frame.promise);
  }

  /** Listens to `method` (of `sessionId`, or the browser's); returns the unsubscribe. */
  listen(method, handler, sessionId) {
    const key = sessionId ? `${sessionId}|${method}` : method;
    this.on(key, handler);
    return () => this.off(key, handler);
  }

  /** The first `method` event passing `predicate`. Call it BEFORE what causes the event. */
  waitForEvent(method, { sessionId, predicate = () => true, timeout = 10_000 } = {}) {
    return new Promise((resolve, reject) => {
      const stop = this.listen(method, (params) => {
        if (!predicate(params)) return;
        clearTimeout(timer);
        stop();
        stopClose();
        resolve(params);
      }, sessionId);
      const onClose = () => { clearTimeout(timer); stop(); reject(new Error(`${method}: the pipe closed while waiting`)); };
      this.once("close", onClose);
      const stopClose = () => this.off("close", onClose);
      const timer = setTimeout(() => { stop(); stopClose(); reject(new Error(`timeout ${timeout} ms waiting for ${method}`)); }, timeout);
      timer.unref();
    });
  }

  /** Every `method` event from now on, into an array; `stop()` ends it. */
  collect(method, sessionId) {
    const events = [];
    events.stop = this.listen(method, (params) => events.push(params), sessionId);
    return events;
  }

  /** Everything on the wire from now on, in order: sends, replies and events, with times. */
  startRecording() {
    this.recording = [];
    return this.recording;
  }

  stopRecording() {
    const recording = this.recording || [];
    this.recording = null;
    return recording;
  }

  session(sessionId, targetId) {
    return new Session(this, sessionId, targetId);
  }
}

export class Session {
  constructor(connection, id, targetId) {
    this.connection = connection;
    this.id = id;
    this.targetId = targetId;
  }

  send(method, params) { return this.connection.send(method, params, this.id); }
  sendBatch(commands) { return this.connection.sendBatch(commands, this.id); }
  on(method, handler) { return this.connection.listen(method, handler, this.id); }
  collect(method) { return this.connection.collect(method, this.id); }
  waitForEvent(method, options = {}) { return this.connection.waitForEvent(method, { ...options, sessionId: this.id }); }
}

// ---------------------------------------------------------------------------
// Processes

const live = new Set();
function killAll() {
  // A test that died with Chromium still open: the whole group goes.
  for (const browser of live) {
    try { process.kill(-browser.pid, "SIGKILL"); } catch { /* gone */ }
  }
}
process.on("exit", killAll);
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    killAll();
    process.exit(signal === "SIGINT" ? 130 : 143);
  });
}

/** The live (non-zombie) processes of a process group. */
export function processGroup(pgid) {
  let output = "";
  try { output = execFileSync("ps", ["-A", "-o", "pid=,pgid=,stat="], { encoding: "utf8" }); } catch { return []; }
  return output.split("\n").map((line) => line.trim().split(/\s+/))
    .filter(([pid, group, state]) => pid && Number(group) === pgid && !String(state).startsWith("Z"))
    .map(([pid]) => Number(pid));
}

export class Browser {
  constructor({ browser, child, connection, args, userDataDir, ownsProfile, exited, stderr, tag }) {
    this.binary = browser;
    this.kind = browser.kind;
    this.child = child;
    this.pid = child.pid;
    this.conn = connection;
    this.args = args;
    this.userDataDir = userDataDir;
    this.ownsProfile = ownsProfile;
    this.exited = exited;
    this.stderr = stderr;
    this.tag = tag;
    this.version = null;
    this.closed = false;
  }

  /** The major version, from Browser.getVersion's product ("HeadlessChrome/141.0.7390.37"). */
  get major() { return Number(/\/(\d+)\./.exec(this.version?.product || "")?.[1]); }
  get fullVersion() { return /\/([\d.]+)/.exec(this.version?.product || "")?.[1]; }

  killGroup(signal = "SIGKILL") {
    try { process.kill(-this.pid, signal); } catch { /* already gone */ }
  }

  /** Browser.close, then the whole process group, then the throwaway profile. */
  async close() {
    if (this.closed) return;
    this.closed = true;
    if (!this.conn.closed) await settle(withTimeout(this.conn.send("Browser.close"), 3000, "Browser.close"));
    const exited = await Promise.race([this.exited.then(() => true), unrefDelay(5000).then(() => false)]);
    this.killGroup("SIGKILL");
    if (!exited) await Promise.race([this.exited, unrefDelay(3000)]);
    for (const stream of this.child.stdio) stream?.destroy?.();
    live.delete(this);
    if (this.ownsProfile) rmSync(this.userDataDir, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  }
}

function tail(text, lines = 6) {
  return text.trim().split("\n").filter(Boolean).slice(-lines).join(" | ").slice(0, 1200);
}

/**
 * Starts `browser` (an entry of BROWSERS) on a pipe and waits for its first
 * reply (Browser.getVersion). Loom's canonical flags come first (flags.mjs;
 * local-only ones with `fencePort`), then the harness's own (--no-sandbox
 * where Linux needs it, --no-proxy-server unless a proxy is set), then `args`.
 */
export async function launch(browser, { headless, args = [], userDataDir, canonical = true, fencePort, allowedHosts, timeoutMs = 30_000, pathPrefix } = {}) {
  const profile = userDataDir || mkdtempSync(join(tmpdir(), "loom-cdp-"));
  const ownsProfile = !userDataDir;
  let flags = canonical ? canonicalArgs(browser.kind, { userDataDir: profile, fencePort, allowedHosts })
    : ["--remote-debugging-pipe", ...FLAGS.headless[browser.kind], FLAGS.userDataDir + profile];
  if (headless !== undefined) {
    const own = FLAGS.headless[browser.kind];
    flags = flags.filter((flag) => !own.includes(flag));
    flags.push(...[headless].flat().filter(Boolean));
  }
  const proxyChosen = [...flags, ...args].some((arg) => arg.startsWith("--proxy-server") || arg === "--no-proxy-server");
  const harness = [...(proxyChosen ? [] : ["--no-proxy-server"])];
  const attempt = async (sandboxOff) => {
    const argv = [...flags, ...harness, ...(sandboxOff ? ["--no-sandbox"] : []), ...args];
    const tag = randomUUID();
    const child = spawn(browser.path, argv, {
      stdio: ["ignore", "pipe", "pipe", "pipe", "pipe"],
      detached: true,
      env: chromiumEnvironment(process.env, tag, pathPrefix),
    });
    let stderr = "";
    child.stderr.on("data", (data) => { stderr = (stderr + data).slice(-65_536); });
    child.stdout.on("data", () => {});
    const exited = new Promise((resolve) => child.once("exit", (code, signal) => resolve({ code, signal })));
    child.once("error", () => {});
    const connection = new Connection(child.stdio[3], child.stdio[4]);
    const instance = new Browser({ browser, child, connection, args: argv, userDataDir: profile, ownsProfile, exited, stderr: () => stderr, tag });
    live.add(instance);
    try {
      instance.version = await Promise.race([
        connection.send("Browser.getVersion"),
        exited.then((how) => { throw new Error(`Chromium exited before its first reply (${JSON.stringify(how)})`); }),
        unrefDelay(timeoutMs).then(() => { throw new Error(`no reply from Chromium in ${timeoutMs} ms`); }),
      ]);
      return instance;
    } catch (error) {
      instance.killGroup("SIGKILL");
      await Promise.race([exited, unrefDelay(2000)]);
      for (const stream of child.stdio) stream?.destroy?.();
      live.delete(instance);
      error.stderr = stderr;
      error.message += ` — ${browser.path}; stderr: ${tail(stderr)}`;
      throw error;
    }
  };
  try {
    try {
      return await attempt(linuxSandboxUnusable());
    } catch (error) {
      // A Linux whose sandbox the checks above missed: once more without it.
      if (process.platform === "linux" && /No usable sandbox|--no-sandbox/.test(error.stderr || "")) return await attempt(true);
      throw error;
    }
  } catch (error) {
    if (ownsProfile) rmSync(profile, { recursive: true, force: true });
    throw error;
  }
}
