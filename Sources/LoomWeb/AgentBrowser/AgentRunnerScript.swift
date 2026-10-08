import Foundation

/// browser_run_code's facade (run-code design §2, §3): Playwright's `page`,
/// locators, keyboard, mouse and dialogs, for the agent's script. It runs in
/// a fresh isolated world of the session's offline runner target
/// (`ChromiumRunner`), never in the page under test. Every page call is one
/// JSON message through the binding `__loomRunCall`; Loom answers each one
/// with a `Runtime.callFunctionOn` into the same world. Loom trusts nothing
/// the facade sends: it re-checks every call against its own policies.
///
/// The Node tests (`Tests/AgentBrowserJS/runner.test.mjs`) read `facade` out
/// of this file: it must stay a `#"""` raw string, its lines at column 0.
///
/// **Calls** (runner → Loom, the binding's payload, one JSON object):
/// `{id, op, api, step, line, target?, args, attempt?}`
/// - `id`: unique in the run; the answer names it.
/// - `op`: what Loom does (design §3.2): action lane `goto`, `history`,
///   `title`, `content`, `click`, `hover`, `fill`, `type`, `press`, `check`,
///   `select`, `focus`, `blur`, `scroll`, `files`, `read`, `readAll`,
///   `count`, `state`, `aria`, `eval`, `key`, `mouse`, `viewport`, `shot`;
///   wait lane `waitState`, `waitLoad`, `nextURL`, `waitFn`, `sleep`;
///   immediate `dialog`, `listen`.
/// - `api`: the Playwright member called (`locator.click`, `page.goto`),
///   for messages and the activity pill. `step`: the run's call count (null
///   for `listen` and an automatic dismiss). `line`: the agent's line (1-based),
///   or null.
/// - `target`: `{chain, desc, strict}`, the helper's wire format (§4.1).
/// - `args`: the op's fields; `timeout` (ms, what is left of the call's time,
///   already capped by the run's end) on the ops that wait.
/// - `attempt`: 1, 2… when the facade asks again after a `retry` answer.
///
/// The facade itself keeps the lanes: one action at a time, in call order;
/// waits, dialog answers and listener changes go out at once.
///
/// **Answers** (Loom → runner): `{id, ok: true, value?, url?}` or
/// `{id, ok: false, error: {name?, message, retry?}, url?}`. `retry: true`:
/// not ready yet, `message` says why; the facade asks again (20–500 ms
/// apart) until the call's timeout, then throws Playwright's TimeoutError.
/// **Events**: `{event: "dialog", dialog: {id, type, message, defaultValue}, url?}`.
/// Both go through `answerFunction` (or `__loomRun.reply` / `__loomRun.event`),
/// the JSON as a string argument.
///
/// **A run** (`entry(code:)`, `Runtime.evaluate` with `awaitPromise` and
/// `returnByValue`) answers `{ok, value?, truncated?, error?: {name, message,
/// line?, column?, step?}, logs, logsDropped, unfinished, steps}`: `value` is
/// the return value as JSON text (absent for `undefined`), cut at
/// `Config.valueChars` with "\n… (cut at N characters)".
public enum AgentRunnerScript {

    /// Stack frames of the agent's code name this file: line L of the
    /// expression is the agent's line L − 1.
    public static let sourceURL = "browser_run_code.js"
    /// The binding the facade posts to (`Runtime.addBinding`).
    public static let bindingName = "__loomRunCall"
    /// The global function answers and events go through.
    public static let answerName = "__loomRunAnswer"

    /// `Runtime.callFunctionOn` in the run's world, with one argument: an
    /// answer or an event, as JSON text.
    public static let answerFunction = "function(json) { return globalThis.__loomRunAnswer(json); }"

    /// The expression's first line: the agent's code starts on line 2.
    public static let entryHead = "globalThis.__loomRun.run(("
    /// A bare body (not a function) is wrapped into one.
    public static let bodyHead = "async (page) => {"
    public static let bodyTail = "}"
    public static let entryTail = "))\n//# sourceURL=" + sourceURL

    /// The `Runtime.evaluate` expression of a run (after `facade` and
    /// `__loomRun.start(config)`): the agent's function, or its bare body
    /// wrapped as `async (page) => { … }`, run with `page`. Line L of a
    /// stack frame in `sourceURL` is the agent's line L − 1; a SyntaxError's
    /// `exceptionDetails.lineNumber` (0-based) is the agent's line as is.
    public static func entry(code: String) -> String {
        // `// fill the form` above `async (page) => …` is still a function, not a body.
        let trimmed = String(skippingLeadingComments(code)).trimmingCharacters(in: .whitespacesAndNewlines)
        if AgentScripts.isFunction(trimmed) {
            var body = code
            // `(fn;)` would not parse.
            while let last = body.last, last == ";" || last.isWhitespace {
                body.removeLast()
            }
            return entryHead + "\n" + body + "\n" + entryTail
        }
        return entryHead + bodyHead + "\n" + code + "\n" + bodyTail + entryTail
    }

    /// The code after its leading whitespace and comments (`//` lines, `/* */` blocks).
    static func skippingLeadingComments(_ code: String) -> Substring {
        var rest = Substring(code)
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.hasPrefix("//") {
                guard let newline = rest.firstIndex(where: { $0.isNewline }) else { return "" }
                rest = rest[newline...]
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return rest }
                rest = rest[end.upperBound...]
            } else {
                return rest
            }
        }
    }

    /// The agent's line for line `scriptLine` (1-based) of a stack frame in
    /// `sourceURL`.
    public static func agentLine(stackLine scriptLine: Int) -> Int {
        scriptLine - 1
    }

    /// What `__loomRun.start(config)` takes: every field has the facade's
    /// default when absent.
    public struct Config: Encodable, Equatable, Sendable {
        public struct Viewport: Encodable, Equatable, Sendable {
            public var width: Int
            public var height: Int

            public init(width: Int, height: Int) {
                self.width = width
                self.height = height
            }
        }

        /// The page's URL when the run starts (`page.url()` until an answer
        /// says otherwise: every answer may carry `url`).
        public var url: String
        public var viewport: Viewport?
        /// Milliseconds: actions and waits, then navigations.
        public var defaultTimeout = 5_000
        public var navigationTimeout = 30_000
        /// The script's own time; every timeout is capped by what is left.
        public var scriptMs = 56_000
        /// Page calls in a run, and at once (dialog answers are never refused).
        public var maxSteps = 1_000
        public var maxInFlight = 32
        /// One call's JSON, in UTF-8 bytes: a bigger one is refused, unsent.
        public var maxMessageBytes = 262_144
        /// The script's console: lines and characters kept.
        public var consoleLines = 200
        public var consoleChars = 8_000
        /// The return value's JSON is cut there (`AgentBrowserLimits.evaluateChars`).
        public var valueChars = 20_000

        public init(url: String, viewport: Viewport? = nil, valueChars: Int = 20_000) {
            self.url = url
            self.viewport = viewport
            self.valueChars = valueChars
        }

        /// The configuration as JSON text, for `__loomRun.start(…)`.
        public func json() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return text
        }
    }

    /// The facade: evaluated once in each run's fresh world, before
    /// `globalThis.__loomRun.start(config)` (config: an object, or its JSON
    /// text) and the run's `entry(code:)`.
    public static let facade = #"""
(() => {
"use strict";
// browser_run_code's facade (run-code design §2, §3). The agent's script
// runs here, in a fresh isolated world of the session's offline runner
// target: never in the page. Each page call is one JSON message through the
// binding __loomRunCall; Loom answers through __loomRunAnswer (or
// __loomRun.reply / __loomRun.event). Loom re-checks every call: nothing
// here is a guard, only a shape.
if (globalThis.__loomRun) return;

const G = globalThis;
const VERSION = 1;
const BINDING = "__loomRunCall";
const SOURCE = "browser_run_code.js";
const SITE = /browser_run_code\.js:(\d+):(\d+)/;
const stringify = JSON.stringify;
const parseJSON = JSON.parse;
const setTimer = G.setTimeout;
const clearTimer = G.clearTimeout;
const now = Date.now;
const freeze = Object.freeze;
const BACKOFF = [20, 50, 100, 100, 250, 500];
// A wait Loom has not answered this long after its timeout ends here.
const WAIT_GRACE = 500;

const DEFAULTS = freeze({
  defaultTimeout: 5000, navigationTimeout: 30000, scriptMs: 56000, maxSteps: 1000, maxInFlight: 32,
  maxMessageBytes: 262144, consoleLines: 200, consoleChars: 8000, valueChars: 20000,
});

const S = {
  cfg: DEFAULTS, started: false, ran: false, ended: false, end: 0,
  url: "", viewport: null, defaultTimeout: 5000, defaultTimeoutSet: false, navigationTimeout: null,
  binding: null, nextId: 1, steps: 0, live: 0, busy: false, queue: [], tasks: new Set(), pending: new Map(),
  logs: [], logChars: 0, logsDropped: 0,
  listeners: [], waiters: [], listening: false, asyncError: null,
};

// ---------------------------------------------------------------- basics

function text(value) {
  try { return String(value); } catch (_) { return "[unprintable]"; }
}

function messageOf(error) {
  try { return String(error && typeof error === "object" && "message" in error ? error.message : error); } catch (_) { return "[unprintable]"; }
}

function kindOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "an array";
  return typeof value;
}

function pause(ms) {
  return new Promise((resolve) => { setTimer(resolve, Math.max(0, ms)); });
}

/** The agent's {line (1-based), column} in a stack: the innermost frame of its code. */
function siteOf(stack) {
  const match = SITE.exec(text(stack || ""));
  return match ? { line: Number(match[1]) - 1, column: Number(match[2]) } : null;
}

function callSite() {
  return siteOf(new Error().stack);
}

class TimeoutError extends Error {
  constructor(message) {
    super(message);
    this.name = "TimeoutError";
  }
}

// Where an error was made, for the answer: {line, column, step}.
const ORIGIN = new WeakMap();

/**
 * The error, located: where the agent's code threw it (a callback of its
 * own), else at the agent's call — a stack frame in its code, as if thrown
 * there.
 */
function located(error, site, step) {
  try {
    if (!error || (typeof error !== "object" && typeof error !== "function") || ORIGIN.has(error)) return error;
    const own = error instanceof Error ? siteOf(error.stack) : null;
    const where = own || site;
    ORIGIN.set(error, { line: where ? where.line : null, column: where ? where.column : null, step: step || null });
    if (site && error instanceof Error && !own) {
      error.stack = (error.name || "Error") + ": " + error.message
        + "\n    at " + SOURCE + ":" + (site.line + 1) + ":" + site.column;
    }
  } catch (_) { /* a proxy, a frozen object: located as it is */ }
  return error;
}

/** UTF-8 bytes of a string. */
function utf8Length(value) {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) { bytes += 4; i += 1; }
    else bytes += 3;
  }
  return bytes;
}

// ---------------------------------------------------------------- values

/** browser_evaluate's serializer (AgentScripts.serializer): JSON the agent can read, never a crash. */
function serialize(value) {
  if (value === undefined) return "undefined";
  const seen = new WeakSet();
  try {
    const out = stringify(value, function (key, inner) {
      if (typeof inner === "bigint") return inner.toString() + "n";
      if (typeof inner === "function") return "[Function " + (inner.name || "anonymous") + "]";
      if (typeof inner === "symbol") return inner.toString();
      if (inner === undefined) return key === "" ? "undefined" : undefined;
      if (typeof inner === "object" && inner !== null) {
        if (typeof Node !== "undefined" && inner instanceof Node) return "<" + text(inner.nodeName).toLowerCase() + ">";
        if (inner instanceof Error) return { name: inner.name, message: inner.message };
        if (seen.has(inner)) return "[Circular]";
        seen.add(inner);
        if (inner instanceof Map) return Object.fromEntries(inner);
        if (inner instanceof Set) return Array.from(inner);
      }
      return inner;
    }, 2);
    return out === undefined ? text(value) : out;
  } catch (_) {
    return text(value);
  }
}

// ---------------------------------------------------------------- console

const MAX_ARG = 2000;
const MAX_LINE = 4000;

function clip(value, limit) {
  const s = text(value);
  return s.length > limit ? s.slice(0, limit - 1) + "…" : s;
}

function show(value) {
  try {
    if (value === undefined) return "undefined";
    if (value === null) return "null";
    const kind = typeof value;
    if (kind === "string") return value;
    if (kind === "number" || kind === "boolean" || kind === "bigint" || kind === "symbol") return text(value);
    if (kind === "function") return "[Function " + (value.name || "anonymous") + "]";
    if (value instanceof Error) return (value.name || "Error") + ": " + value.message;
    for (const Class of FACADE_CLASSES) {
      if (!(value instanceof Class)) continue;
      const own = value.toJSON();
      return typeof own === "string" ? own : text(stringify(own));
    }
    const seen = new WeakSet();
    const out = stringify(value, (key, inner) => {
      if (typeof inner === "bigint") return inner.toString() + "n";
      if (typeof inner === "function") return "[Function " + (inner.name || "anonymous") + "]";
      if (typeof inner === "symbol") return inner.toString();
      if (inner && typeof inner === "object") {
        if (seen.has(inner)) return "[Circular]";
        seen.add(inner);
        if (inner instanceof Map) return Object.fromEntries(inner);
        if (inner instanceof Set) return Array.from(inner);
        if (inner instanceof Error) return { name: inner.name, message: inner.message };
      }
      return inner;
    });
    return out === undefined ? text(value) : out;
  } catch (_) {
    return "[unprintable]";
  }
}

/** console's own formatting: %s %d %i %f %o %O, %c dropped. */
function format(args) {
  const list = Array.from(args);
  let out = "";
  if (typeof list[0] === "string" && /%[sdifoOc%]/.test(list[0])) {
    const template = list.shift();
    out = template.replace(/%([sdifoOc%])/g, (match, spec) => {
      if (spec === "%") return "%";
      if (!list.length) return match;
      const value = list.shift();
      switch (spec) {
        case "s": return clip(show(value), MAX_ARG);
        case "d": case "i": return text(parseInt(value, 10));
        case "f": return text(parseFloat(value));
        case "c": return "";
        default: return clip(show(value), MAX_ARG);
      }
    });
  }
  for (const value of list) out += (out ? " " : "") + clip(show(value), MAX_ARG);
  return clip(out, MAX_LINE);
}

/** One line of the script's output; past the caps, only counted. */
function record(line) {
  const room = S.cfg.consoleChars - S.logChars;
  if (S.logs.length >= S.cfg.consoleLines || room <= 0) { S.logsDropped += 1; return; }
  const kept = line.length > room ? line.slice(0, Math.max(0, room - 1)) + "…" : line;
  S.logs.push(kept);
  S.logChars += kept.length;
}

function makeConsole() {
  const counts = new Map();
  const timers = new Map();
  const out = {};
  const put = (prefix) => (...args) => record(prefix + format(args));
  out.log = put("");
  out.info = put("");
  out.trace = put("");
  out.dir = put("");
  out.dirxml = put("");
  out.table = put("");
  out.debug = put("[DEBUG] ");
  out.warn = put("[WARNING] ");
  out.error = put("[ERROR] ");
  out.assert = (condition, ...args) => {
    if (!condition) record("[ERROR] Assertion failed" + (args.length ? ": " + format(args) : ""));
  };
  out.count = (label = "default") => {
    const n = (counts.get(label) || 0) + 1;
    counts.set(label, n);
    record(text(label) + ": " + n);
  };
  out.countReset = (label = "default") => { counts.delete(label); };
  out.time = (label = "default") => { timers.set(label, now()); };
  out.timeLog = (label = "default", ...args) => {
    if (timers.has(label)) record(text(label) + ": " + (now() - timers.get(label)) + " ms" + (args.length ? " " + format(args) : ""));
  };
  out.timeEnd = (label = "default") => {
    if (timers.has(label)) { record(text(label) + ": " + (now() - timers.get(label)) + " ms"); timers.delete(label); }
  };
  out.group = (...args) => { if (args.length) record(format(args)); };
  out.groupCollapsed = out.group;
  out.groupEnd = () => {};
  out.clear = () => {};
  return freeze(out);
}

// ---------------------------------------------------------------- the world

const BLOCKED = {
  fetch: "fetch(…)", XMLHttpRequest: "new XMLHttpRequest()", WebSocket: "new WebSocket(…)",
  EventSource: "new EventSource(…)", Worker: "new Worker(…)", SharedWorker: "new SharedWorker(…)",
  RTCPeerConnection: "new RTCPeerConnection()", webkitRTCPeerConnection: "new RTCPeerConnection()",
  open: "window.open(…)", alert: "alert(…)", confirm: "confirm(…)", prompt: "prompt(…)", print: "print()",
};

function blocked(name, example) {
  return function () {
    throw new Error(name + " is not available in browser_run_code: the script runs outside the page, offline."
      + " Run it in the page: page.evaluate(() => " + example + ")");
  };
}

/** The network and the modal APIs out of the run's world: defense in depth (the fence is the boundary). */
function neutralize() {
  for (const name of Object.keys(BLOCKED)) {
    if (!(name in G)) continue;
    const value = blocked(name, BLOCKED[name]);
    try {
      Object.defineProperty(G, name, { value, writable: false, configurable: false, enumerable: false });
    } catch (_) {
      try { G[name] = value; } catch (_) { /* unforgeable */ }
    }
  }
  try {
    if (G.navigator && "sendBeacon" in G.navigator) {
      Object.defineProperty(G.navigator, "sendBeacon", { value: blocked("navigator.sendBeacon", "navigator.sendBeacon(…)") });
    }
  } catch (_) { /* kept */ }
  try {
    Object.defineProperty(G, "console", { value: makeConsole(), writable: false, configurable: false, enumerable: false });
  } catch (_) {
    try { G.console = makeConsole(); } catch (_) { /* kept */ }
  }
}

// ---------------------------------------------------------------- the bridge

const WAITS = new Set(["waitState", "waitLoad", "nextURL", "waitFn", "sleep"]);
const IMMEDIATE = new Set(["dialog", "listen"]);

function laneOf(op) {
  return IMMEDIATE.has(op) ? "immediate" : WAITS.has(op) ? "wait" : "action";
}

/**
 * One message to Loom → its raw answer {ok, value | error}. Refused here when
 * too big, or when the run has ended. `guardMs` (waits only: they change
 * nothing): when Loom has not answered by then, a TimeoutError answer.
 */
function post(task, op, target, args, attempt, guardMs) {
  // (A sleep Loom has not answered ends by itself: it is only time.)
  if (S.ended) return Promise.reject(new Error(task.api + ": the run has ended"));
  const id = S.nextId++;
  const message = { id, op, api: task.api, step: task.step, line: task.site ? task.site.line : null };
  if (target !== undefined) message.target = target;
  message.args = args || {};
  if (attempt) message.attempt = attempt;
  let payload;
  try {
    payload = stringify(message);
  } catch (error) {
    return Promise.reject(new TypeError(task.api + ": its arguments must be JSON (" + messageOf(error) + ")"));
  }
  const max = S.cfg.maxMessageBytes;
  if (payload.length > max || (payload.length * 3 > max && utf8Length(payload) > max)) {
    const kb = (n) => Math.ceil(n / 1024) + " KB";
    return Promise.reject(new Error(task.api + ": this call is " + kb(utf8Length(payload)) + "; a call is " + kb(max) + " at most"));
  }
  const binding = S.binding;
  if (typeof binding !== "function") return Promise.reject(new Error(task.api + ": Loom's bridge is missing (" + BINDING + ")"));
  return new Promise((resolve) => {
    let timer = null;
    S.pending.set(id, (reply) => {
      if (timer !== null) clearTimer(timer);
      resolve(reply);
    });
    try {
      binding(payload);
    } catch (error) {
      S.pending.delete(id);
      resolve({ ok: false, error: { name: "Error", message: "the bridge refused the call: " + messageOf(error) } });
      return;
    }
    if (guardMs !== undefined) {
      timer = setTimer(() => {
        if (!S.pending.delete(id)) return;
        resolve(op === "sleep" ? { ok: true }
          : { ok: false, error: { name: "TimeoutError", message: "Timeout " + Math.round(guardMs) + "ms exceeded (Loom did not answer)" } });
      }, guardMs + WAIT_GRACE);
    }
  });
}

/** An answer or an event from Loom (JSON text, or the object). */
function answer(json) {
  let r;
  try { r = typeof json === "string" ? parseJSON(json) : json; } catch (_) { return false; }
  if (!r || typeof r !== "object") return false;
  if (typeof r.url === "string") S.url = r.url;
  if (typeof r.event === "string") {
    if (r.event === "dialog") onDialog(r.dialog);
    return true;
  }
  const resolve = S.pending.get(r.id);
  if (!resolve) return false;
  S.pending.delete(r.id);
  resolve(r);
  return true;
}

/**
 * A page call, queued in its lane: actions one at a time, in call order;
 * waits, local waits and dialog answers at once. `perform(task)` posts and
 * resolves with the value, `map` shapes it for the agent.
 */
function start(api, lane, summary, site, perform, map, counted) {
  if (S.ended) {
    return Promise.reject(located(new Error(api + ": the run has ended: this call came after your function returned (missing await?)"), site));
  }
  const steps = counted !== false;
  if (lane !== "immediate" && S.live >= S.cfg.maxInFlight) {
    return Promise.reject(located(new Error(api + ": " + S.cfg.maxInFlight + " page calls are already in flight (missing await?)"), site));
  }
  if (steps && S.steps >= S.cfg.maxSteps) {
    return Promise.reject(located(new Error(api + ": a script makes " + S.cfg.maxSteps + " page calls at most"), site));
  }
  const task = { api, lane, summary: text(summary == null ? "" : summary), site, step: steps ? ++S.steps : null,
    perform, map, done: false, resolve: null, reject: null };
  if (lane !== "immediate") S.live += 1;
  S.tasks.add(task);
  return new Promise((resolve, reject) => {
    task.resolve = resolve;
    task.reject = reject;
    if (lane === "action") {
      S.queue.push(task);
      pump();
    } else {
      execute(task);
    }
  });
}

function execute(task) {
  let result;
  try { result = Promise.resolve(task.perform(task)); } catch (error) { result = Promise.reject(error); }
  return result.then((value) => settle(task, null, value), (error) => settle(task, error || new Error(task.api + ": failed")));
}

function settle(task, error, value) {
  // After the run's end nothing settles: no one awaits it any more.
  if (task.done || S.ended) return;
  task.done = true;
  S.tasks.delete(task);
  if (task.lane !== "immediate") S.live -= 1;
  if (error) { task.reject(located(error, task.site, task.step)); return; }
  let mapped;
  try { mapped = task.map ? task.map(value) : value; } catch (failure) { task.reject(located(failure, task.site, task.step)); return; }
  task.resolve(mapped);
}

/** The action lane: the next action goes out when the previous one is answered. */
function pump() {
  if (S.busy || S.ended || !S.queue.length) return;
  const task = S.queue.shift();
  S.busy = true;
  execute(task).then(() => {
    S.busy = false;
    pump();
  });
}

/** One op, asked again after a `retry` answer until its timeout. */
async function exchange(task, op, target, args, timing) {
  const deadline = timing ? now() + timing.ms : null;
  let attempt = 0;
  let reason = "";
  for (;;) {
    const sent = Object.assign({}, args);
    if (deadline !== null) sent.timeout = Math.max(0, deadline - now());
    let guardMs;
    if (task.lane === "wait") guardMs = deadline !== null ? sent.timeout : op === "sleep" ? sent.ms : undefined;
    const reply = await post(task, op, target, sent, attempt, guardMs);
    if (reply.ok === true) return reply.value;
    const error = reply.error && typeof reply.error === "object" ? reply.error : { message: text(reply.error || "failed") };
    if ((reply.retry !== true && error.retry !== true) || deadline === null) throw replyError(task, error);
    reason = error.message ? text(error.message) : reason;
    const left = deadline - now();
    if (left <= 0) throw waitTimeout(task, timing, target, reason);
    await pause(Math.min(BACKOFF[Math.min(attempt, BACKOFF.length - 1)], left));
    attempt += 1;
  }
}

/** Loom's error, as Playwright words it: `<api>: <message>`, a TimeoutError by name. */
function replyError(task, error) {
  const raw = typeof error.name === "string" ? error.name : "";
  const name = /^\w{1,40}$/.test(raw) ? raw : "Error";
  let message = error.message == null ? "failed" : text(error.message);
  if (!/^[A-Za-z_$][\w$]*\.[A-Za-z_$][\w$]*: /.test(message)) message = task.api + ": " + message;
  const made = name === "TimeoutError" ? new TimeoutError(message) : new Error(message);
  if (name !== "TimeoutError" && name !== "Error") made.name = name;
  return made;
}

function waitTimeout(task, timing, target, reason) {
  const what = target && target.desc ? target.desc : task.summary;
  const log = ["  - waiting for " + what];
  if (reason && reason !== "waiting for " + what) log.push("  - " + reason);
  return new TimeoutError(task.api + ": Timeout " + timing.shown + "ms exceeded.\nCall log:\n" + log.join("\n"));
}

// ---------------------------------------------------------------- arguments

function options(o, api) {
  if (o === undefined || o === null) return {};
  if (typeof o !== "object" || Array.isArray(o)) throw new TypeError(api + ": options must be an object, not " + kindOf(o));
  return o;
}

function nonNegative(value, name, api, fallback) {
  if (value === undefined) return fallback;
  if (typeof value !== "number" || !(value >= 0) || value === Infinity) {
    throw new TypeError(api + ": " + name + " must be a number >= 0, not " + text(value));
  }
  return value;
}

function stringArg(value, name, api) {
  if (typeof value !== "string") throw new TypeError(api + ": " + name + " must be a string, not " + kindOf(value));
  return value;
}

function navigationDefault() {
  if (S.navigationTimeout !== null) return S.navigationTimeout;
  return S.defaultTimeoutSet ? S.defaultTimeout : S.cfg.navigationTimeout;
}

/** {shown: the timeout asked (0: the run's end), ms: what the call may take} — never past the script's end. */
function timeoutOf(o, kind, api) {
  const fallback = kind === "navigation" ? navigationDefault() : S.defaultTimeout;
  const shown = nonNegative(o.timeout, "timeout", api, fallback);
  const left = Math.max(0, S.end - now());
  return { shown, ms: Math.round(shown === 0 ? left : Math.min(shown, left)) };
}

const BUTTONS = new Set(["left", "right", "middle"]);
const MODIFIERS = new Set(["Alt", "Control", "ControlOrMeta", "Meta", "Shift"]);
const WAIT_UNTIL = new Set(["load", "domcontentloaded", "networkidle", "commit"]);
const LOAD_STATES = new Set(["load", "domcontentloaded", "networkidle"]);
const ELEMENT_STATES = new Set(["attached", "detached", "visible", "hidden"]);

function buttonOf(value, api) {
  if (value === undefined) return "left";
  if (!BUTTONS.has(value)) throw new TypeError(api + ': button must be "left", "right" or "middle", not ' + text(value));
  return value;
}

function modifiersOf(value, api) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((m) => !MODIFIERS.has(m))) {
    throw new TypeError(api + ": modifiers are among Alt, Control, ControlOrMeta, Meta and Shift, not " + text(stringify(value)));
  }
  return value.slice();
}

function positionOf(value, api) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || !Number.isFinite(value.x) || !Number.isFinite(value.y)) {
    throw new TypeError(api + ": position is {x, y}, numbers relative to the element's top-left corner");
  }
  return { x: value.x, y: value.y };
}

function countOf(value, name, api, fallback) {
  if (value === undefined) return fallback;
  if (!Number.isInteger(value) || value < 1) throw new TypeError(api + ": " + name + " must be an integer >= 1, not " + text(value));
  return value;
}

function coordinate(value, name, api) {
  if (!Number.isFinite(value)) throw new TypeError(api + ": " + name + " must be a number, not " + text(value));
  return value;
}

function keyOf(value, api) {
  if (typeof value !== "string" || !value) throw new TypeError(api + ": key must be a key name such as \"Enter\" or \"Control+a\", not " + kindOf(value));
  return value;
}

function waitUntilOf(value, api) {
  if (value === undefined) return "load";
  if (!WAIT_UNTIL.has(value)) throw new TypeError(api + ': waitUntil is "load", "domcontentloaded", "networkidle" or "commit", not ' + text(value));
  return value;
}

function clickArgs(p, clicks, api) {
  return {
    button: buttonOf(p.button, api),
    clickCount: clicks === 2 ? 2 : countOf(p.clickCount, "clickCount", api, 1),
    modifiers: modifiersOf(p.modifiers, api),
    position: positionOf(p.position, api),
    force: !!p.force,
    trial: !!p.trial,
    delay: nonNegative(p.delay, "delay", api, 0),
  };
}

function optionList(values, api) {
  if (values === null || values === undefined) return [];
  const list = Array.isArray(values) ? values : [values];
  return list.map((v) => {
    if (typeof v === "string") return v;
    if (v && typeof v === "object" && !(v instanceof Locator)) {
      const option = {};
      if (v.value !== undefined) option.value = stringArg(v.value, "an option's value", api);
      if (v.label !== undefined) option.label = stringArg(v.label, "an option's label", api);
      if (v.index !== undefined) {
        if (!Number.isInteger(v.index) || v.index < 0) throw new TypeError(api + ": an option's index must be an integer >= 0");
        option.index = v.index;
      }
      if (Object.keys(option).length) return option;
    }
    throw new TypeError(api + ": an option is a string, {value}, {label} or {index}, not " + kindOf(v));
  });
}

function filePaths(files, api) {
  const list = Array.isArray(files) ? files : [files];
  for (const file of list) {
    if (typeof file !== "string" || !file) {
      throw new TypeError(api + ": Loom takes file paths (a file under the project or the session's upload folder), not "
        + (file && typeof file === "object" ? "file contents" : kindOf(file)));
    }
  }
  return list.slice();
}

function sourceOf(fn, api) {
  let source;
  if (typeof fn === "function") source = Function.prototype.toString.call(fn);
  else if (typeof fn === "string" && fn.trim()) source = fn;
  else throw new TypeError(api + ": expected a function or an expression, not " + kindOf(fn));
  if (/\{\s*\[native code\]\s*\}\s*$/.test(source)) throw new TypeError(api + ": a native or bound function cannot be sent to the page");
  return source;
}

/** {fn, arg?, all?}: the page runs fn(element or arg, arg); arg crosses as JSON. */
function evalArgs(fn, arg, api, all) {
  const args = { fn: sourceOf(fn, api) };
  if (arg !== undefined) {
    let json;
    try { json = stringify(arg); } catch (error) { throw new TypeError(api + ": arg must be JSON (" + messageOf(error) + ")"); }
    if (json === undefined) throw new TypeError(api + ": arg must be JSON, not " + kindOf(arg));
    args.arg = parseJSON(json);
  }
  if (all) args.all = true;
  return args;
}

function shotArgs(p, api) {
  if (p.path !== undefined) throw new TypeError(api + ": path is not supported: Loom attaches the screenshot to its answer");
  const type = p.type === undefined ? "png" : p.type;
  if (type !== "png" && type !== "jpeg") throw new TypeError(api + ': type is "png" or "jpeg", not ' + text(p.type));
  const args = { fullPage: !!p.fullPage, type };
  if (p.quality !== undefined) {
    if (!Number.isInteger(p.quality) || p.quality < 0 || p.quality > 100) throw new TypeError(api + ": quality is an integer from 0 to 100");
    args.quality = p.quality;
  }
  return args;
}

// ---------------------------------------------------------------- answers, shaped

const none = () => undefined;
const same = (value) => value;
const stringOf = (value) => (value == null ? "" : text(value));
const booleanOf = (value) => (value && typeof value === "object" && "value" in value ? !!value.value : !!value);
const numberOf = (value) => (typeof value === "number" ? value : value && typeof value.count === "number" ? value.count : 0);
const listOf = (value) => (Array.isArray(value) ? value : value && Array.isArray(value.value) ? value.value : []);
const selectedOf = (value) => (Array.isArray(value) ? value : value && Array.isArray(value.values) ? value.values : []);

/** An evaluation's answer: the serializer's JSON text, parsed back. */
function evalValue(value) {
  if (typeof value !== "string") return value;
  if (value === "undefined") return undefined;
  try { return parseJSON(value); } catch (_) { return value; }
}

// ---------------------------------------------------------------- descriptions (Playwright's toString)

function quote(value) {
  const json = stringify(text(value));
  return "'" + json.slice(1, -1).replace(/\\"/g, '"').replace(/'/g, "\\'") + "'";
}

function isRegExp(value) {
  return Object.prototype.toString.call(value) === "[object RegExp]";
}

function regexSource(re) {
  return text(re).replace(/(^|[^\\])(\\\\)*\\(['"`])/g, "$1$2$3");
}

function textDesc(value) {
  return isRegExp(value) ? regexSource(value) : quote(value);
}

/** A text body's (getByText, getByLabel, hasText): Playwright prints a RegExp with flags other than i, g, m as a string. */
function textBodyDesc(value) {
  if (!isRegExp(value)) return quote(value);
  return /^[gim]*$/.test(value.flags) ? regexSource(value) : quote(text(value));
}

/** A string or RegExp → the helper's TextSpec: {s, m} or {re, f} (g and y dropped). */
function textSpec(value, exact, what) {
  if (isRegExp(value)) return { re: value.source, f: value.flags.replace(/[gy]/g, "") };
  if (typeof value === "string") return { s: value, m: exact ? "eq" : "ci" };
  throw new TypeError(what + " must be a string or a RegExp, not " + kindOf(value));
}

const ROLE_OPTIONS = ["checked", "disabled", "selected", "expanded", "includeHidden", "level", "pressed"];

function roleStep(role, o) {
  if (typeof role !== "string" || !role) throw new TypeError("getByRole: role must be a non-empty string, not " + kindOf(role));
  const p = options(o, "getByRole");
  const step = { role };
  const parts = [];
  if (p.name !== undefined) {
    step.name = textSpec(p.name, !!p.exact, "getByRole: name");
    parts.push("name: " + textDesc(p.name));
    if (!isRegExp(p.name) && p.exact) parts.push("exact: true");
  }
  for (const key of ROLE_OPTIONS) {
    if (p[key] === undefined) continue;
    step[key] = p[key];
    parts.push(key + ": " + (typeof p[key] === "string" ? quote(p[key]) : text(p[key])));
  }
  return { step, desc: "getByRole(" + quote(role) + (parts.length ? ", { " + parts.join(", ") + " }" : "") + ")" };
}

function textStep(kind, method, value, o) {
  const p = options(o, method);
  const step = {};
  step[kind] = textSpec(value, !!p.exact, method + ": text");
  const shown = method === "getByText" || method === "getByLabel" ? textBodyDesc(value) : textDesc(value);
  const desc = isRegExp(value) ? method + "(" + shown + ")"
    : method + "(" + shown + (p.exact ? ", { exact: true }" : "") + ")";
  return { step, desc };
}

const BUILDERS = {
  getByRole: (role, o) => roleStep(role, o),
  getByText: (value, o) => textStep("text", "getByText", value, o),
  getByLabel: (value, o) => textStep("label", "getByLabel", value, o),
  getByPlaceholder: (value, o) => textStep("placeholder", "getByPlaceholder", value, o),
  getByAltText: (value, o) => textStep("alt", "getByAltText", value, o),
  getByTitle: (value, o) => textStep("title", "getByTitle", value, o),
  getByTestId: (value) => ({ step: { testId: textSpec(value, true, "getByTestId: testId") }, desc: "getByTestId(" + textDesc(value) + ")" }),
};

// ---------------------------------------------------------------- the guard

const HINTS = {
  page: {
    context: "the browser context is out of reach (no cookies, storage or other pages)",
    request: "no API requests: fetch from the page, page.evaluate(() => fetch(…))",
    route: "requests cannot be intercepted", unroute: "requests cannot be intercepted",
    routeFromHAR: "requests cannot be intercepted",
    frames: "frames are not supported: locators stop at a frame; a ref (aria-ref=e12) can point inside one",
    frame: "frames are not supported", mainFrame: "frames are not supported", frameLocator: "frames are not supported",
    $: "use page.locator(selector)", $$: "use page.locator(selector).all()",
    $eval: "use page.locator(selector).evaluate(fn)", $$eval: "use page.locator(selector).evaluateAll(fn)",
    waitForNavigation: "use page.waitForURL(url) or page.waitForLoadState()",
    waitForResponse: "network events are not available: wait for what the page shows (locator.waitFor(), page.waitForURL(…), page.waitForFunction(…))",
    waitForRequest: "network events are not available: wait for what the page shows (locator.waitFor(), page.waitForURL(…), page.waitForFunction(…))",
    evaluateHandle: "use page.evaluate(fn): it answers JSON",
    page: "your function receives the page itself: async (page) => { … }",
    close: "the page stays open: close tabs with browser_tabs",
    setContent: "use page.goto(url)",
    dragAndDrop: "use page.mouse: move, down, move, up",
    tap: "use click()", touchscreen: "use page.mouse",
    exposeFunction: "the page cannot call into the script", exposeBinding: "the page cannot call into the script",
  },
  locator: {
    elementHandle: "use the locator itself, or locator.evaluate(fn)", elementHandles: "use locator.all() or locator.evaluateAll(fn)",
    dragTo: "use page.mouse: move, down, move, up", tap: "use click()",
    dispatchEvent: "use locator.evaluate((e) => e.dispatchEvent(new Event(…)))",
    selectText: "use locator.evaluate(…) or page.keyboard.press('ControlOrMeta+a')",
    contentFrame: "frames are not supported", frameLocator: "frames are not supported",
    evaluateHandle: "use locator.evaluate(fn): it answers JSON",
  },
  response: {
    headers: "a response's headers are not available", body: "a response's body is not available: read the page",
    text: "a response's body is not available: read the page", json: "a response's body is not available: read the page",
  },
};

const NAMES = new Map();

function supportedNames(target, kind) {
  if (NAMES.has(kind)) return NAMES.get(kind);
  const names = [];
  for (const name of Object.keys(target)) if (name[0] !== "_" && !names.includes(name)) names.push(name);
  for (let proto = Object.getPrototypeOf(target); proto && proto !== Object.prototype; proto = Object.getPrototypeOf(proto)) {
    for (const name of Object.getOwnPropertyNames(proto)) {
      if (name === "constructor" || name === "toJSON" || name === "toString" || name[0] === "_" || names.includes(name)) continue;
      names.push(name);
    }
  }
  NAMES.set(kind, names);
  return names;
}

function distance(a, b) {
  const row = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let previous = row[0];
    row[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const held = row[j];
      row[j] = Math.min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] === b[j - 1] ? 0 : 1));
      previous = held;
    }
  }
  return row[b.length];
}

function unsupported(kind, target, prop) {
  const names = supportedNames(target, kind);
  const hints = HINTS[kind] || {};
  const hint = Object.prototype.hasOwnProperty.call(hints, prop) ? hints[prop] : "";
  let near = "";
  if (!hint && prop.length > 2) {
    let best = 3;
    for (const name of names) {
      const d = distance(prop.toLowerCase(), name.toLowerCase());
      if (d < best) { best = d; near = name; }
    }
  }
  return new Error(kind + "." + prop + " is not available in Loom's browser_run_code" + (hint ? ": " + hint : "") + "."
    + (near ? " Did you mean " + kind + "." + near + "?" : "") + " Supported: " + names.join(", ") + ".");
}

/** A Playwright object, guarded: an unknown member throws what is available; then, toJSON and symbols answer undefined. */
function guard(target, kind) {
  return new Proxy(target, {
    get(t, prop, receiver) {
      if (prop in t) return Reflect.get(t, prop, receiver);
      if (typeof prop === "symbol" || prop === "then" || prop === "toJSON") return undefined;
      throw unsupported(kind, t, prop);
    },
    set() { return false; },
    defineProperty() { return false; },
    deleteProperty() { return false; },
  });
}

function method(proto, name, fn) {
  Object.defineProperty(proto, name, { value: fn, writable: false, configurable: false, enumerable: false });
}

// ---------------------------------------------------------------- calls

/**
 * One page call: its arguments checked here (a TypeError costs no step),
 * then queued and posted. spec: {api, op, loc?, o?, kind?: "action" |
 * "navigation" (the call waits: it gets a timeout), build?(options) → args,
 * map?, summary?}.
 */
function request(spec) {
  const site = callSite();
  let args;
  let timing = null;
  let target;
  try {
    const o = options(spec.o, spec.api);
    args = spec.build ? spec.build(o) : {};
    if (spec.kind) timing = timeoutOf(o, spec.kind, spec.api);
    target = spec.loc ? spec.loc._target() : undefined;
  } catch (error) {
    return Promise.reject(located(error, site));
  }
  const summary = spec.summary !== undefined ? spec.summary : spec.loc ? spec.loc._desc : "";
  return start(spec.api, laneOf(spec.op), summary, site,
    (task) => exchange(task, spec.op, target, args, timing), spec.map || none);
}

function readCall(what, map) {
  return (loc, api, o) => request({ api, op: "read", loc, o, kind: "action", build: () => ({ what }), map: map || same });
}

function stateCall(what) {
  return (loc, api) => request({ api, op: "state", loc, build: () => ({ what }), map: booleanOf });
}

function checkCall(loc, api, checked, o) {
  return request({ api, op: "check", loc, o, kind: "action",
    build: (p) => ({ checked: !!checked, force: !!p.force, position: positionOf(p.position, api), trial: !!p.trial }) });
}

function typeCall(loc, api, value, o) {
  return request({ api, op: "type", loc, o, kind: "action",
    build: (p) => ({ text: stringArg(value, "text", api), delay: nonNegative(p.delay, "delay", api, 0) }) });
}

/** A locator's actions and reads, shared with page.<action>(selector, …): (locator, api, …arguments). */
const ACT = {
  click: (loc, api, o) => request({ api, op: "click", loc, o, kind: "action", build: (p) => clickArgs(p, 1, api) }),
  dblclick: (loc, api, o) => request({ api, op: "click", loc, o, kind: "action", build: (p) => clickArgs(p, 2, api) }),
  hover: (loc, api, o) => request({ api, op: "hover", loc, o, kind: "action",
    build: (p) => ({ position: positionOf(p.position, api), modifiers: modifiersOf(p.modifiers, api), force: !!p.force, trial: !!p.trial }) }),
  fill: (loc, api, value, o) => request({ api, op: "fill", loc, o, kind: "action",
    build: (p) => ({ value: stringArg(value, "value", api), force: !!p.force }) }),
  clear: (loc, api, o) => request({ api, op: "fill", loc, o, kind: "action", build: (p) => ({ value: "", force: !!p.force }) }),
  type: typeCall,
  pressSequentially: typeCall,
  press: (loc, api, key, o) => request({ api, op: "press", loc, o, kind: "action",
    build: (p) => ({ key: keyOf(key, api), delay: nonNegative(p.delay, "delay", api, 0) }) }),
  check: (loc, api, o) => checkCall(loc, api, true, o),
  uncheck: (loc, api, o) => checkCall(loc, api, false, o),
  setChecked: (loc, api, checked, o) => checkCall(loc, api, checked, o),
  selectOption: (loc, api, values, o) => request({ api, op: "select", loc, o, kind: "action",
    build: (p) => ({ options: optionList(values, api), force: !!p.force }), map: selectedOf }),
  focus: (loc, api, o) => request({ api, op: "focus", loc, o, kind: "action" }),
  blur: (loc, api, o) => request({ api, op: "blur", loc, o, kind: "action" }),
  scrollIntoViewIfNeeded: (loc, api, o) => request({ api, op: "scroll", loc, o, kind: "action" }),
  setInputFiles: (loc, api, files, o) => request({ api, op: "files", loc, o, kind: "action", build: () => ({ paths: filePaths(files, api) }) }),
  textContent: readCall("textContent"),
  innerText: readCall("innerText"),
  innerHTML: readCall("innerHTML"),
  inputValue: readCall("inputValue"),
  getAttribute: (loc, api, name, o) => request({ api, op: "read", loc, o, kind: "action",
    build: () => ({ what: "attribute", name: stringArg(name, "name", api) }), map: same }),
  boundingBox: readCall("boundingBox"),
  isVisible: stateCall("visible"),
  isHidden: stateCall("hidden"),
  isEnabled: readCall("enabled", booleanOf),
  isDisabled: readCall("disabled", booleanOf),
  isChecked: readCall("checked", booleanOf),
  isEditable: readCall("editable", booleanOf),
  allTextContents: (loc, api) => request({ api, op: "readAll", loc, build: () => ({ what: "textContent" }), map: listOf }),
  allInnerTexts: (loc, api) => request({ api, op: "readAll", loc, build: () => ({ what: "innerText" }), map: listOf }),
  count: (loc, api) => request({ api, op: "count", loc, map: numberOf }),
  evaluate: (loc, api, fn, arg, o) => request({ api, op: "eval", loc, o, kind: "action", build: () => evalArgs(fn, arg, api, false), map: evalValue }),
  evaluateAll: (loc, api, fn, arg) => request({ api, op: "eval", loc, build: () => evalArgs(fn, arg, api, true), map: evalValue }),
  waitFor: (loc, api, o) => request({ api, op: "waitState", loc, o, kind: "action", build: (p) => ({ state: elementState(p.state, api) }) }),
  screenshot: (loc, api, o) => request({ api, op: "shot", loc, o, kind: "action", build: (p) => shotArgs(p, api) }),
  ariaSnapshot: (loc, api, o) => request({ api, op: "aria", loc, o, kind: "action", map: stringOf }),
};

function elementState(value, api) {
  if (value === undefined) return "visible";
  if (!ELEMENT_STATES.has(value)) throw new TypeError(api + ': state is "attached", "detached", "visible" or "hidden", not ' + text(value));
  return value;
}

// ---------------------------------------------------------------- Locator

class Locator {
  constructor(chain, desc, strict) {
    this._chain = chain;
    this._desc = desc;
    this._strict = strict !== false;
    freeze(this);
  }
  /** The helper's target: {chain, desc, strict}. */
  _target() { return { chain: this._chain, desc: this._desc, strict: this._strict }; }
  _ref() { return { chain: this._chain, desc: this._desc }; }
  _with(steps, suffix) { return wrapLocator(new Locator(this._chain.concat(steps), this._desc + suffix, true)); }
  locator(selectorOrLocator, o) {
    const p = options(o, "locator.locator");
    const base = selectorOrLocator instanceof Locator
      ? this._with(selectorOrLocator._chain, ".locator(" + selectorOrLocator._desc + ")")
      : this._with([{ selector: selectorText(selectorOrLocator, "locator.locator") }], ".locator(" + quote(selectorOrLocator) + ")");
    return withFilters(base, p, "locator.locator");
  }
  filter(o) { return withFilters(this, options(o, "locator.filter"), "locator.filter"); }
  nth(index) {
    if (!Number.isInteger(index)) throw new TypeError("locator.nth: index must be an integer, not " + text(index));
    return this._with([{ nth: index }], ".nth(" + index + ")");
  }
  first() { return this._with([{ nth: 0 }], ".first()"); }
  last() { return this._with([{ nth: -1 }], ".last()"); }
  and(other) {
    const inner = asLocator(other, "locator.and");
    return this._with([{ and: inner._ref() }], ".and(" + inner._desc + ")");
  }
  or(other) {
    const inner = asLocator(other, "locator.or");
    return this._with([{ or: inner._ref() }], ".or(" + inner._desc + ")");
  }
  describe(description) {
    stringArg(description, "description", "locator.describe");
    return this._with([], "");
  }
  all() {
    const self = this;
    return ACT.count(self, "locator.all").then((n) => Array.from({ length: n }, (_, i) => self.nth(i)));
  }
  highlight() { return Promise.resolve(); }
  page() { return page; }
  toString() { return this._desc; }
  toJSON() { return "locator: " + this._desc; }
}

function wrapLocator(locator) {
  return guard(locator, "locator");
}

function asLocator(value, what) {
  if (value instanceof Locator) return value;
  throw new TypeError(what + " must be a locator (page.locator(…), page.getByRole(…), …), not " + kindOf(value));
}

function selectorText(selector, api) {
  if (typeof selector !== "string" || !selector.trim()) throw new TypeError(api + ": selector must be a non-empty string, not " + kindOf(selector));
  return selector;
}

function selectorLocator(selector, strict, api) {
  return wrapLocator(new Locator([{ selector: selectorText(selector, api) }], "locator(" + quote(selector) + ")", strict));
}

/** Playwright's locator options as filters, in its order: hasText, hasNotText, has, hasNot, visible. */
function withFilters(locator, p, api) {
  const steps = [];
  let suffix = "";
  if (p.hasText) {
    steps.push({ hasText: textSpec(p.hasText, false, api + ": hasText") });
    suffix += ".filter({ hasText: " + textBodyDesc(p.hasText) + " })";
  }
  if (p.hasNotText) {
    steps.push({ hasText: textSpec(p.hasNotText, false, api + ": hasNotText"), not: true });
    suffix += ".filter({ hasNotText: " + textBodyDesc(p.hasNotText) + " })";
  }
  if (p.has) {
    const inner = asLocator(p.has, api + ": has");
    steps.push({ has: inner._ref() });
    suffix += ".filter({ has: " + inner._desc + " })";
  }
  if (p.hasNot) {
    const inner = asLocator(p.hasNot, api + ": hasNot");
    steps.push({ has: inner._ref(), not: true });
    suffix += ".filter({ hasNot: " + inner._desc + " })";
  }
  if (p.visible !== undefined) {
    steps.push({ visible: !!p.visible });
    suffix += ".filter({ visible: " + (p.visible ? "true" : "false") + " })";
  }
  return steps.length ? locator._with(steps, suffix) : locator;
}

for (const name of Object.keys(BUILDERS)) {
  method(Locator.prototype, name, function (...args) {
    const built = BUILDERS[name](...args);
    return this._with([built.step], "." + built.desc);
  });
}
for (const name of Object.keys(ACT)) {
  method(Locator.prototype, name, function (...args) {
    return ACT[name](this, "locator." + name, ...args);
  });
}

// ---------------------------------------------------------------- dialogs

class Dialog {
  constructor(info) {
    this._id = info.id;
    this._type = text(info.type || "alert");
    this._message = text(info.message == null ? "" : info.message);
    this._defaultValue = text(info.defaultValue == null ? "" : info.defaultValue);
    this._state = { handled: false };
    freeze(this);
  }
  type() { return this._type; }
  message() { return this._message; }
  defaultValue() { return this._defaultValue; }
  page() { return page; }
  accept(promptText) { return answerDialog(this, true, promptText, "dialog.accept"); }
  dismiss() { return answerDialog(this, false, undefined, "dialog.dismiss"); }
  toJSON() { return "dialog: " + this._type + " " + stringify(this._message); }
}

function answerDialog(dialog, accept, promptText, api) {
  if (dialog._state.handled) {
    return Promise.reject(located(new Error("Cannot " + (accept ? "accept" : "dismiss") + " dialog which is already handled!"), callSite()));
  }
  if (promptText !== undefined && typeof promptText !== "string") {
    return Promise.reject(located(new TypeError(api + ": promptText must be a string, not " + kindOf(promptText)), callSite()));
  }
  dialog._state.handled = true;
  return request({ api, op: "dialog", summary: dialog._type + " " + stringify(dialog._message),
    build: () => {
      const args = { id: dialog._id, accept };
      if (accept && promptText !== undefined) args.promptText = promptText;
      return args;
    } });
}

/** The page's dialog listener, said to Loom when it changes: with none, Loom stops the run at a dialog. */
function listenersChanged() {
  const want = S.listeners.length + S.waiters.length > 0;
  if (want === S.listening || S.ended) return;
  S.listening = want;
  post({ api: "page.on", step: null, site: null }, "listen", undefined, { dialog: want }, 0).then(none, none);
}

function onDialog(info) {
  if (!info || typeof info !== "object" || S.ended) return;
  const dialog = guard(new Dialog(info), "dialog");
  let taken = false;
  for (const entry of S.listeners.slice()) {
    taken = true;
    if (entry.once) removeEntry(entry, true);
    try {
      const result = entry.handler.call(page, dialog);
      if (result && typeof result.then === "function") result.then(none, (error) => handlerFailed(error, entry.site));
    } catch (error) {
      handlerFailed(error, entry.site);
    }
  }
  for (const waiter of S.waiters.slice()) {
    taken = true;
    waiter.offer(dialog);
  }
  // After the handlers: an answer they gave at once goes out before a `once` listener's end.
  listenersChanged();
  // No one to answer it (a listener just removed): Playwright's default, dismissed.
  if (!taken) {
    dialog._state.handled = true;
    post({ api: "dialog.dismiss", step: null, site: null }, "dialog", undefined, { id: info.id, accept: false }, 0).then(none, none);
  }
}

/** A dialog handler's error fails the run: located where it was thrown, else at its page.on. */
function handlerFailed(error, site) {
  if (!S.asyncError) S.asyncError = located(error, site);
}

const PAGE_EVENTS = {
  console: "the page's console is in browser_console_messages after the run; the script's own console.log is answered",
  pageerror: "the page's errors are in browser_console_messages after the run",
  request: "the page's requests are in browser_network_requests after the run",
  response: "the page's requests are in browser_network_requests after the run",
  requestfinished: "the page's requests are in browser_network_requests after the run",
  requestfailed: "the page's requests are in browser_network_requests after the run",
  popup: "a popup becomes a tab: browser_tabs",
  load: "use page.waitForLoadState('load')",
  domcontentloaded: "use page.waitForLoadState('domcontentloaded')",
  framenavigated: "use page.waitForURL(url)",
  filechooser: "use locator.setInputFiles(paths)",
  download: "downloads are refused",
};

function eventError(api, event) {
  const name = text(event);
  const hint = Object.prototype.hasOwnProperty.call(PAGE_EVENTS, name) ? " " + PAGE_EVENTS[name] + "." : "";
  return new Error(api + "('" + name + "') is not available in Loom's browser_run_code: only 'dialog' is." + hint);
}

function addListener(api, event, handler, once) {
  if (event !== "dialog") throw eventError(api, event);
  if (typeof handler !== "function") throw new TypeError(api + ": the listener must be a function, not " + kindOf(handler));
  S.listeners.push({ handler, once, site: callSite() });
  listenersChanged();
}

function removeEntry(entry, quiet) {
  const index = S.listeners.indexOf(entry);
  if (index >= 0) S.listeners.splice(index, 1);
  if (!quiet) listenersChanged();
}

function removeListener(api, event, handler) {
  if (event !== "dialog") throw eventError(api, event);
  for (let i = S.listeners.length - 1; i >= 0; i--) {
    if (S.listeners[i].handler === handler) {
      S.listeners.splice(i, 1);
      break;
    }
  }
  listenersChanged();
}

// ---------------------------------------------------------------- small objects

class Response {
  constructor(info) {
    this._url = text(info.url == null ? "" : info.url);
    this._status = Number(info.status) || 0;
    this._statusText = text(info.statusText == null ? "" : info.statusText);
    freeze(this);
  }
  url() { return this._url; }
  status() { return this._status; }
  statusText() { return this._statusText; }
  ok() { return this._status === 0 || (this._status >= 200 && this._status <= 299); }
  toJSON() { return { url: this._url, status: this._status }; }
}

function responseOf(value) {
  return value && typeof value === "object" ? guard(new Response(value), "response") : null;
}

class Handle {
  constructor(value) {
    this._value = value;
    freeze(this);
  }
  jsonValue() { return Promise.resolve(this._value); }
  dispose() { return Promise.resolve(); }
  toJSON() { return this._value; }
}

class Keyboard {
  down(key) { return request({ api: "keyboard.down", op: "key", summary: text(key), build: () => ({ action: "down", key: keyOf(key, "keyboard.down") }) }); }
  up(key) { return request({ api: "keyboard.up", op: "key", summary: text(key), build: () => ({ action: "up", key: keyOf(key, "keyboard.up") }) }); }
  press(key, o) {
    return request({ api: "keyboard.press", op: "key", o, summary: text(key),
      build: (p) => ({ action: "press", key: keyOf(key, "keyboard.press"), delay: nonNegative(p.delay, "delay", "keyboard.press", 0) }) });
  }
  type(value, o) {
    return request({ api: "keyboard.type", op: "key", o, summary: stringify(text(value)).slice(0, 60),
      build: (p) => ({ action: "type", text: stringArg(value, "text", "keyboard.type"), delay: nonNegative(p.delay, "delay", "keyboard.type", 0) }) });
  }
  insertText(value) {
    return request({ api: "keyboard.insertText", op: "key", summary: stringify(text(value)).slice(0, 60),
      build: () => ({ action: "insertText", text: stringArg(value, "text", "keyboard.insertText") }) });
  }
  toJSON() { return "keyboard"; }
}

class Mouse {
  move(x, y, o) {
    const api = "mouse.move";
    return request({ api, op: "mouse", o, summary: text(x) + "," + text(y),
      build: (p) => ({ action: "move", x: coordinate(x, "x", api), y: coordinate(y, "y", api), steps: countOf(p.steps, "steps", api, 1) }) });
  }
  down(o) {
    const api = "mouse.down";
    return request({ api, op: "mouse", o, build: (p) => ({ action: "down", button: buttonOf(p.button, api), clickCount: countOf(p.clickCount, "clickCount", api, 1) }) });
  }
  up(o) {
    const api = "mouse.up";
    return request({ api, op: "mouse", o, build: (p) => ({ action: "up", button: buttonOf(p.button, api), clickCount: countOf(p.clickCount, "clickCount", api, 1) }) });
  }
  click(x, y, o) {
    const api = "mouse.click";
    return request({ api, op: "mouse", o, summary: text(x) + "," + text(y),
      build: (p) => ({ action: "click", x: coordinate(x, "x", api), y: coordinate(y, "y", api), button: buttonOf(p.button, api),
        clickCount: countOf(p.clickCount, "clickCount", api, 1), delay: nonNegative(p.delay, "delay", api, 0) }) });
  }
  dblclick(x, y, o) {
    const api = "mouse.dblclick";
    return request({ api, op: "mouse", o, summary: text(x) + "," + text(y),
      build: (p) => ({ action: "click", x: coordinate(x, "x", api), y: coordinate(y, "y", api), button: buttonOf(p.button, api),
        clickCount: 2, delay: nonNegative(p.delay, "delay", api, 0) }) });
  }
  wheel(deltaX, deltaY) {
    const api = "mouse.wheel";
    return request({ api, op: "mouse", summary: text(deltaX) + "," + text(deltaY),
      build: () => ({ action: "wheel", dx: coordinate(deltaX, "deltaX", api), dy: coordinate(deltaY, "deltaY", api) }) });
  }
  toJSON() { return "mouse"; }
}

// ---------------------------------------------------------------- URLs (Playwright's urlMatch.ts, Apache-2.0)

const GLOB_ESCAPED = new Set(["$", "^", "+", ".", "*", "(", ")", "|", "\\", "?", "{", "}", "[", "]"]);

function globToRegexPattern(glob) {
  const tokens = ["^"];
  let inGroup = false;
  for (let i = 0; i < glob.length; ++i) {
    const c = glob[i];
    if (c === "\\" && i + 1 < glob.length) {
      const char = glob[++i];
      tokens.push(GLOB_ESCAPED.has(char) ? "\\" + char : char);
      continue;
    }
    if (c === "*") {
      let starCount = 1;
      while (glob[i + 1] === "*") { starCount++; i++; }
      tokens.push(starCount > 1 ? "(.*)" : "([^/]*)");
      continue;
    }
    switch (c) {
      case "{": inGroup = true; tokens.push("("); break;
      case "}": inGroup = false; tokens.push(")"); break;
      case ",":
        if (inGroup) { tokens.push("|"); break; }
        tokens.push("\\" + c);
        break;
      default: tokens.push(GLOB_ESCAPED.has(c) ? "\\" + c : c);
    }
  }
  tokens.push("$");
  return tokens.join("");
}

function resolveBaseURL(baseURL, givenURL) {
  try {
    const url = new URL(givenURL, baseURL);
    return { resolved: url.toString(), caseInsensitivePart: url.origin };
  } catch (_) {
    return { resolved: givenURL };
  }
}

function resolveGlobBase(baseURL, match) {
  if (match.startsWith("*")) return match;
  const tokenMap = new Map();
  const mapToken = (original, replacement) => {
    if (original.length === 0) return "";
    tokenMap.set(replacement, original);
    return replacement;
  };
  match = match.replace(/\\\\\?/g, "?");
  if (/^(about|data|chrome|edge|file):/.test(match)) return match;
  const relativePath = match.split("/").map((token, index) => {
    if (token === "." || token === ".." || token === "") return token;
    if (index === 0 && token.endsWith(":")) return mapToken(token, "http:");
    const questionIndex = token.indexOf("?");
    if (questionIndex === -1) return mapToken(token, "$_" + index + "_$");
    const newPrefix = mapToken(token.substring(0, questionIndex), "$_" + index + "_$");
    const newSuffix = mapToken(token.substring(questionIndex), "?$_" + index + "_$");
    return newPrefix + newSuffix;
  }).join("/");
  const result = resolveBaseURL(baseURL, relativePath);
  let resolved = result.resolved;
  for (const [token, original] of tokenMap) {
    const normalize = result.caseInsensitivePart && result.caseInsensitivePart.includes(token);
    resolved = resolved.replace(token, normalize ? original.toLowerCase() : original);
  }
  return resolved;
}

function resolveGlobToRegexPattern(baseURL, glob) {
  return globToRegexPattern(resolveGlobBase(baseURL, glob));
}

/** url → (href) => boolean | Promise<boolean>: a glob, a RegExp or a predicate of a URL, as Playwright's urlMatches. */
function urlMatcher(match, api) {
  if (match === undefined || match === "") return () => true;
  if (typeof match === "string") {
    const re = new RegExp(resolveGlobToRegexPattern(undefined, match));
    return (href) => re.test(href);
  }
  if (isRegExp(match)) {
    return (href) => { match.lastIndex = 0; return match.test(href); };
  }
  if (typeof match === "function") {
    return (href) => {
      let url;
      try { url = new URL(href); } catch (_) { return false; }
      return match(url);
    };
  }
  throw new TypeError(api + ": url must be a string (a glob), a RegExp or a function of a URL, not " + kindOf(match));
}

function urlDesc(match) {
  if (typeof match === "string") return stringify(match);
  if (isRegExp(match)) return text(match);
  return "a URL the predicate accepts";
}

// ---------------------------------------------------------------- Page

class Page {
  constructor() {
    this.keyboard = guard(new Keyboard(), "keyboard");
    this.mouse = guard(new Mouse(), "mouse");
    freeze(this);
  }
  url() { return S.url; }
  title() { return request({ api: "page.title", op: "title", map: stringOf }); }
  content() { return request({ api: "page.content", op: "content", map: stringOf }); }
  goto(url, o) {
    return request({ api: "page.goto", op: "goto", o, kind: "navigation", summary: text(url), map: responseOf,
      build: (p) => {
        if (typeof url !== "string" || !url.trim()) throw new TypeError("page.goto: url must be a non-empty string, not " + kindOf(url));
        return { url, waitUntil: waitUntilOf(p.waitUntil, "page.goto") };
      } });
  }
  goBack(o) { return history("page.goBack", -1, o); }
  goForward(o) { return history("page.goForward", 1, o); }
  reload(o) { return history("page.reload", 0, o); }
  locator(selector, o) {
    const p = options(o, "page.locator");
    return withFilters(selectorLocator(selector, true, "page.locator"), p, "page.locator");
  }
  waitForTimeout(ms) {
    const api = "page.waitForTimeout";
    return request({ api, op: "sleep", summary: text(ms) + " ms",
      build: () => ({ ms: Math.round(Math.min(nonNegative(ms, "timeout", api, 0), Math.max(0, S.end - now()))) }) });
  }
  waitForSelector(selector, o) {
    const api = "page.waitForSelector";
    let loc;
    let p;
    try {
      p = options(o, api);
      loc = selectorLocator(selector, !!p.strict, api);
    } catch (error) {
      return Promise.reject(located(error, callSite()));
    }
    return request({ api, op: "waitState", loc, o, kind: "action",
      build: () => ({ state: elementState(p.state, api) }),
      map: () => (p.state === "hidden" || p.state === "detached" ? null : p.strict ? loc : loc.first()) });
  }
  waitForLoadState(state, o) {
    const api = "page.waitForLoadState";
    return request({ api, op: "waitLoad", o, kind: "navigation", summary: text(state === undefined ? "load" : state),
      build: () => {
        const value = state === undefined ? "load" : state;
        if (!LOAD_STATES.has(value)) throw new TypeError(api + ': state is "load", "domcontentloaded" or "networkidle", not ' + text(state));
        return { state: value };
      } });
  }
  waitForURL(match, o) {
    const api = "page.waitForURL";
    const site = callSite();
    let matcher;
    let until;
    let timing;
    try {
      const p = options(o, api);
      matcher = urlMatcher(match, api);
      until = waitUntilOf(p.waitUntil, api);
      timing = timeoutOf(p, "navigation", api);
    } catch (error) {
      return Promise.reject(located(error, site));
    }
    const desc = urlDesc(match);
    return start(api, "wait", desc, site, async (task) => {
      const deadline = now() + timing.ms;
      const left = () => Math.max(0, deadline - now());
      const seen = [];
      const expired = () => new TimeoutError(api + ": Timeout " + timing.shown + "ms exceeded.\nCall log:\n  - waiting for navigation to "
        + desc + " until \"" + until + "\"" + seen.slice(-5).map((u) => "\n  - navigated to " + stringify(u)).join(""));
      const matches = (href) => {
        const verdict = matcher(href);
        return verdict && typeof verdict.then === "function" ? verdict : !!verdict;
      };
      let current = S.url;
      for (;;) {
        // A predicate may answer a promise; a glob or a RegExp answers at once, so the
        // first nextURL goes out before a click called beside it (Promise.all).
        let verdict = matches(current);
        if (typeof verdict !== "boolean") verdict = !!(await verdict);
        if (verdict) break;
        if (left() <= 0) throw expired();
        const wait = left();
        const reply = await post(task, "nextURL", undefined, { since: current, timeout: wait }, 0, wait);
        if (reply.ok !== true) {
          const error = reply.error && typeof reply.error === "object" ? reply.error : {};
          if (error.name === "TimeoutError") throw expired();
          if (reply.retry !== true && error.retry !== true) throw replyError(task, error);
          await pause(Math.min(100, left()));
          continue;
        }
        const next = typeof reply.value === "string" ? reply.value : S.url;
        if (next === current) await pause(Math.min(100, left()));
        else seen.push(next);
        current = next;
      }
      if (until === "commit") return undefined;
      const loading = left();
      const loaded = await post(task, "waitLoad", undefined, { state: until, timeout: loading }, 0, loading);
      if (loaded.ok !== true) {
        const error = loaded.error && typeof loaded.error === "object" ? loaded.error : {};
        throw error.name === "TimeoutError" ? expired() : replyError(task, error);
      }
      return undefined;
    }, none);
  }
  waitForFunction(fn, arg, o) {
    const api = "page.waitForFunction";
    return request({ api, op: "waitFn", o, kind: "action",
      build: (p) => {
        const args = evalArgs(fn, arg, api, false);
        let polling = 100;
        if (p.polling === "raf") polling = 16;
        else if (p.polling !== undefined) polling = nonNegative(p.polling, "polling", api, 100);
        args.polling = polling;
        return args;
      },
      map: (value) => guard(new Handle(evalValue(value)), "handle") });
  }
  waitForEvent(event, optionsOrPredicate) {
    const api = "page.waitForEvent";
    const site = callSite();
    let p;
    let timing;
    try {
      if (event !== "dialog") throw eventError(api, event);
      p = typeof optionsOrPredicate === "function" ? { predicate: optionsOrPredicate } : options(optionsOrPredicate, api);
      if (p.predicate !== undefined && typeof p.predicate !== "function") throw new TypeError(api + ": predicate must be a function");
      timing = timeoutOf(p, "action", api);
    } catch (error) {
      return Promise.reject(located(error, site));
    }
    return start(api, "local", "'dialog'", site, () => new Promise((resolve, reject) => {
      let timer = null;
      const waiter = {
        over: false,
        offer(dialog) {
          let verdict;
          try { verdict = p.predicate ? p.predicate(dialog) : true; } catch (error) { done(); reject(error); return; }
          Promise.resolve(verdict).then((ok) => {
            if (ok && !waiter.over) { done(); resolve(dialog); }
          }, (error) => { done(); reject(error); });
        },
      };
      const done = () => {
        if (waiter.over) return;
        waiter.over = true;
        if (timer !== null) clearTimer(timer);
        const index = S.waiters.indexOf(waiter);
        if (index >= 0) S.waiters.splice(index, 1);
        listenersChanged();
      };
      S.waiters.push(waiter);
      listenersChanged();
      timer = setTimer(() => {
        done();
        reject(new TimeoutError(api + ": Timeout " + timing.shown + "ms exceeded while waiting for event \"dialog\""));
      }, timing.ms);
    }), same, false);
  }
  evaluate(fn, arg) {
    return request({ api: "page.evaluate", op: "eval", build: () => evalArgs(fn, arg, "page.evaluate", false), map: evalValue });
  }
  setViewportSize(size) {
    const api = "page.setViewportSize";
    let wanted;
    return request({ api, op: "viewport",
      build: () => {
        if (!size || typeof size !== "object" || !Number.isInteger(size.width) || !Number.isInteger(size.height) || size.width < 1 || size.height < 1) {
          throw new TypeError(api + ": expected {width, height}, positive integers in CSS pixels");
        }
        wanted = { width: size.width, height: size.height };
        return wanted;
      },
      summary: size && typeof size === "object" ? text(size.width) + "x" + text(size.height) : "",
      map: () => { S.viewport = wanted; } });
  }
  viewportSize() { return S.viewport ? { width: S.viewport.width, height: S.viewport.height } : null; }
  screenshot(o) { return request({ api: "page.screenshot", op: "shot", o, build: (p) => shotArgs(p, "page.screenshot") }); }
  ariaSnapshot(o) { return request({ api: "page.ariaSnapshot", op: "aria", o, kind: "action", map: stringOf }); }
  on(event, handler) { addListener("page.on", event, handler, false); return page; }
  once(event, handler) { addListener("page.once", event, handler, true); return page; }
  addListener(event, handler) { addListener("page.addListener", event, handler, false); return page; }
  off(event, handler) { removeListener("page.off", event, handler); return page; }
  removeListener(event, handler) { removeListener("page.removeListener", event, handler); return page; }
  removeAllListeners(event) {
    if (event === undefined || event === "dialog") {
      S.listeners.length = 0;
      listenersChanged();
    }
    return page;
  }
  setDefaultTimeout(ms) {
    S.defaultTimeout = nonNegative(ms, "timeout", "page.setDefaultTimeout", S.defaultTimeout);
    S.defaultTimeoutSet = true;
  }
  setDefaultNavigationTimeout(ms) {
    S.navigationTimeout = nonNegative(ms, "timeout", "page.setDefaultNavigationTimeout", navigationDefault());
  }
  isClosed() { return false; }
  toJSON() { return "page: " + S.url; }
  toString() { return "page: " + S.url; }
}

function history(api, delta, o) {
  return request({ api, op: "history", o, kind: "navigation", map: responseOf,
    build: (p) => ({ delta, waitUntil: waitUntilOf(p.waitUntil, api) }) });
}

for (const name of Object.keys(BUILDERS)) {
  method(Page.prototype, name, function (...args) {
    const built = BUILDERS[name](...args);
    return wrapLocator(new Locator([built.step], built.desc, true));
  });
}

// page.<action>(selector, …, options): a locator of the selector, strict only with {strict: true}.
const SHORTCUTS = [["click", 0], ["dblclick", 0], ["hover", 0], ["fill", 1], ["type", 1], ["press", 1], ["check", 0],
  ["uncheck", 0], ["setChecked", 1], ["selectOption", 1], ["focus", 0], ["setInputFiles", 1], ["textContent", 0],
  ["innerText", 0], ["innerHTML", 0], ["inputValue", 0], ["getAttribute", 1], ["isVisible", 0], ["isHidden", 0],
  ["isEnabled", 0], ["isDisabled", 0], ["isChecked", 0], ["isEditable", 0]];
for (const [name, arity] of SHORTCUTS) {
  method(Page.prototype, name, function (selector, ...rest) {
    const api = "page." + name;
    let loc;
    try {
      const o = rest[arity];
      loc = selectorLocator(selector, !!(o && typeof o === "object" && o.strict), api);
    } catch (error) {
      return Promise.reject(located(error, callSite()));
    }
    return ACT[name](loc, api, ...rest);
  });
}

const FACADE_CLASSES = [Page, Locator, Dialog, Response, Keyboard, Mouse, Handle];
for (const Class of FACADE_CLASSES) freeze(Class.prototype);

const page = guard(new Page(), "page");

// ---------------------------------------------------------------- the run

function configure(raw) {
  let c = raw;
  if (typeof c === "string") { try { c = parseJSON(c); } catch (_) { c = {}; } }
  if (!c || typeof c !== "object") c = {};
  const cfg = {};
  for (const key of Object.keys(DEFAULTS)) {
    const v = c[key];
    cfg[key] = typeof v === "number" && v > 0 && v < 1e9 ? Math.floor(v) : DEFAULTS[key];
  }
  S.cfg = freeze(cfg);
  S.url = typeof c.url === "string" ? c.url : "";
  const v = c.viewport;
  S.viewport = v && typeof v === "object" && Number.isFinite(v.width) && Number.isFinite(v.height) ? { width: v.width, height: v.height } : null;
  S.defaultTimeout = cfg.defaultTimeout;
}

/** The world made ready: the configuration, the binding, the console, the network APIs out. */
function startRun(config) {
  if (S.started) return { ok: false, error: "already started" };
  configure(config);
  // Kept here and taken off the world: the agent's code reaches Loom only
  // through post(), which caps each message and stops at the run's end (a
  // bare call could send a frame big enough to close the shared pipe).
  S.binding = typeof G[BINDING] === "function" ? G[BINDING] : null;
  try { delete G[BINDING]; } catch (_) { /* not configurable: left as is */ }
  try { if (Error.stackTraceLimit < 50) Error.stackTraceLimit = 50; } catch (_) { /* kept */ }
  neutralize();
  S.started = true;
  return { ok: true, version: VERSION };
}

function errorInfo(error) {
  const info = { name: "Error", message: "" };
  let origin;
  try {
    if (error && (typeof error === "object" || typeof error === "function")) {
      origin = ORIGIN.get(error);
      const name = text(error.name || "Error");
      info.name = /^\w{1,40}$/.test(name) ? name : "Error";
      info.message = "message" in error ? text(error.message) : text(error);
      if (!origin) origin = siteOf(error.stack);
    } else {
      info.message = text(error);
    }
  } catch (_) {
    info.message = info.message || "[unprintable]";
  }
  if (info.message.length > 8000) info.message = info.message.slice(0, 7999) + "…";
  if (origin && origin.line != null) {
    info.line = origin.line;
    if (origin.column != null) info.column = origin.column;
  }
  if (origin && origin.step) info.step = origin.step;
  return info;
}

/** The run's answer: the outcome, the script's output, the calls still out. */
function finish(ok, value, error) {
  S.ended = true;
  const unfinished = [];
  for (const task of S.tasks) unfinished.push(task.api + (task.summary ? " " + task.summary : ""));
  if (S.asyncError) { ok = false; error = S.asyncError; }
  const result = { ok, logs: S.logs.slice(), logsDropped: S.logsDropped, unfinished, steps: S.steps };
  if (!ok) {
    result.error = errorInfo(error);
  } else if (value !== undefined) {
    let json = serialize(value);
    const max = S.cfg.valueChars;
    if (json.length > max) {
      json = json.slice(0, max) + "\n… (cut at " + max + " characters)";
      result.truncated = true;
    }
    result.value = json;
  }
  return result;
}

/** The agent's function, run with `page` → the run's answer (never a rejection). */
async function run(fn) {
  if (!S.started) startRun({});
  if (S.ran) {
    return { ok: false, error: { name: "Error", message: "this world already runs a script" }, logs: [], logsDropped: 0,
      unfinished: [], steps: 0 };
  }
  S.ran = true;
  S.end = now() + S.cfg.scriptMs;
  let ok = true;
  let value;
  let error;
  try {
    if (typeof fn !== "function") throw new TypeError("browser_run_code takes a function of page: async (page) => { … }");
    value = await fn(page);
  } catch (failure) {
    ok = false;
    error = failure;
  }
  return finish(ok, value, error);
}

const reply = (json) => answer(json);
const event = (json) => answer(json);

Object.defineProperty(G, "__loomRunAnswer", { value: answer, writable: false, configurable: false, enumerable: false });
Object.defineProperty(G, "__loomRun", {
  value: freeze({
    version: VERSION,
    start: startRun,
    run,
    reply,
    event,
    answer,
    _pure: freeze({ globToRegexPattern, resolveGlobToRegexPattern, siteOf, quote, format, serialize, utf8Length }),
  }),
  writable: false, configurable: false, enumerable: false,
});
})();
"""#
}
