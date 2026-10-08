// browser_run_code's core, in Node over the pipe: a line-by-line stand-in for
// ChromiumAgentCore+RunCode.swift and ChromiumRunner.swift, so that real
// agent scripts run end to end here — the REAL facade (AgentRunnerScript.facade)
// in a fenced runner target, the REAL helper (AgentScripts.helper) in a tab —
// and the protocol both sides speak is exercised on a real Chromium.
//
// Ported as written in Swift:
// - the runner: a browser context behind a fence (every request refused),
//   Fetch failing everything, offline; a fresh world `loom-run-<n>` per run,
//   the binding added to it by id; calls from another world dropped; the
//   stop ladder (terminateExecution, closeTarget, Page.crash);
// - AgentRunCall.decode (fields from args, then the message; clamps;
//   refusals answered by id), the lanes (actions one at a time, waits beside
//   them, dialog answers at once), the caps (steps counted once per facade
//   step, 32 in flight, 256 KB a message, 8 MB in all, 2 000 messages),
//   AgentRunReply.json, the dialog rules (pushed to a listener, else the run
//   stops), runSettle / runCommit / runLoadState, runFailure's words, the
//   stop messages and runRead.
// Simplified: the tab's events (PageSignals) cover what these ops read; the
// navigation policy is http(s) and about:blank (the Swift one is pinned by
// its own tests); keys are lib/input.mjs's. Not ported (they throw "the
// stand-in does not do …"): history, mouse, viewport, screenshot, files, aria.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot, serializerSource, stampLookupSource } from "../../AgentBrowserJS/extract.mjs";
import { delay, performance, settle, withTimeout } from "./cdp.mjs";
import { HELPER_FUNCTION, prepareBrowser } from "./init.mjs";
import { charKey, keyPress, KEYS, mouseClick } from "./input.mjs";

const RUNNER_SWIFT = (() => {
  try { return readFileSync(resolve(repoRoot, "Sources/LoomWeb/AgentBrowser/AgentRunnerScript.swift"), "utf8"); } catch { return null; }
})();
const runnerLiteral = (name) => {
  const match = RUNNER_SWIFT && new RegExp(`public static let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`).exec(RUNNER_SWIFT);
  return match ? match[1] : null;
};
const runnerConstant = (name) => {
  const match = RUNNER_SWIFT && new RegExp(`public static let ${name} = "((?:[^"\\\\]|\\\\.)*)"`).exec(RUNNER_SWIFT);
  return match ? JSON.parse(`"${match[1]}"`) : null;
};

/** null while AgentRunnerScript.swift has no facade: the tests that need it skip. */
export const FACADE = runnerLiteral("facade");
export const ANSWER_FUNCTION = runnerConstant("answerFunction");
const SOURCE_URL = runnerConstant("sourceURL") ?? "browser_run_code.js";
const ENTRY_HEAD = runnerConstant("entryHead");
const BODY_HEAD = runnerConstant("bodyHead");
const BODY_TAIL = runnerConstant("bodyTail");
const ENTRY_TAIL = "))\n//# sourceURL=" + SOURCE_URL;
export const BINDING = "__loomRunCall";
const SERIALIZER = serializerSource();
const STAMP_LOOKUP = stampLookupSource();

/** AgentRunLimits. */
export const RUN_LIMITS = Object.freeze({
  scriptTime: 56_000, endReserve: 4_000, actionTimeout: 5_000, navigationTimeout: 30_000, maxTimeout: 60_000,
  maxDelay: 1_000, maxText: 100_000, maxOptions: 100, maxTargetBytes: 16_384, maxSteps: 1_000, maxInFlight: 32,
  maxMessageBytes: 262_144, maxTransferBytes: 8_388_608, heapCapBytes: 268_435_456, consoleLines: 200,
  consoleChars: 8_000, stepsShown: 5,
});

const now = () => performance.now();
/** A promise whose rejection nobody may read (an ack after an interrupted batch). */
const quiet = (promise) => { promise.catch(() => {}); return promise; };

// ---------------------------------------------------------------- AgentRunnerScript.entry

const isFunction = (text) => text.startsWith("function") || text.startsWith("async ") || text.startsWith("async(")
  || /^(\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*=>/.test(text);

function skippingLeadingComments(code) {
  let rest = code;
  for (;;) {
    rest = rest.replace(/^\s+/, "");
    if (rest.startsWith("//")) {
      const newline = rest.search(/[\n\r]/);
      if (newline < 0) return "";
      rest = rest.slice(newline);
    } else if (rest.startsWith("/*")) {
      const end = rest.indexOf("*/");
      if (end < 0) return rest;
      rest = rest.slice(end + 2);
    } else {
      return rest;
    }
  }
}

export function entry(code) {
  if (isFunction(skippingLeadingComments(code).trim())) return ENTRY_HEAD + "\n" + code.replace(/[;\s]+$/, "") + "\n" + ENTRY_TAIL;
  return ENTRY_HEAD + BODY_HEAD + "\n" + code + "\n" + BODY_TAIL + ENTRY_TAIL;
}

// ---------------------------------------------------------------- errors, as Swift throws them

class AgentError extends Error {
  constructor(kind, message) { super(message); this.kind = kind; }
}
class CDPInterrupted extends Error {
  constructor(reason) { super(`interrupted: ${reason}`); this.reason = reason; }
}
class CDPTimeout extends Error {}
class Cancelled extends Error {}
/** ChromiumRunTimeout. */
class RunTimeout extends Error {
  constructor(api, ms, waiting, reason) {
    const log = [waiting, reason].filter(Boolean).map((line) => "  - " + line);
    super(`${api}: Timeout ${ms}ms exceeded.` + (log.length ? "\nCall log:\n" + log.join("\n") : ""));
  }
}
/** ChromiumRunDialogWait. */
class DialogWait extends Error {
  constructor(dialog) { super("dialog wait"); this.dialog = dialog; }
}
/** AgentRunFailure, thrown by decode. */
class Failure extends Error {
  constructor(message) { super(message); this.failure = { name: "Error", message }; }
}

/** ChromiumTabRuntime.agentError(…).message. */
function agentMessage(error) {
  if (error instanceof AgentError) return error.message;
  if (error instanceof CDPInterrupted) {
    return { dialogOpened: "a dialog is open: answer it with browser_handle_dialog", navigated: "the page navigated away during the command",
      crashed: "the page's process stopped during the command", detached: "the tab was closed during the command" }[error.reason];
  }
  if (error instanceof CDPTimeout) return "the page did not answer in time";
  if (error?.cdpMessage) return `Chromium refused ${error.method}: ${error.cdpMessage}`;
  return String(error?.message || error);
}

/** ChromiumAgentCore.runFailure. */
function runFailure(error, api) {
  if (error instanceof RunTimeout) return { name: "TimeoutError", message: error.message };
  if (error instanceof DialogWait) {
    const kind = error.dialog.kind === "beforeunload" ? "confirm" : error.dialog.kind;
    return { name: "TimeoutError", message: `${api}: Timeout exceeded while the page's ${kind} dialog (${JSON.stringify(error.dialog.message)}) `
      + "waited for an answer: your page.on('dialog') handler must call dialog.accept() or dialog.dismiss()" };
  }
  if (error instanceof Failure) return error.failure;
  return { name: "Error", message: api + ": " + agentMessage(error) };
}

const STALE = /Cannot find context with specified id/;
const GONE = /Execution context was destroyed|Promise was collected|Inspected target navigated or closed|Cannot find context with specified id/;
const PAGE_INTERRUPTIONS = ["dialogOpened", "navigated", "crashed", "detached"];

// ---------------------------------------------------------------- the tab (ChromiumTabRuntime, PageSignals, DialogLedger)

/** A tab of lib/init.mjs (openTab) as the run sees it. */
export class RunPage {
  constructor(tab) {
    this.tab = tab;
    this.session = tab.session;
    this.journal = [];
    this.sequence = 0;
    this.state = { url: tab.url, loaderId: tab.loaderId, reached: new Set(["load", "DOMContentLoaded"]), dialog: null, httpStatus: null };
    this.waiting = new Set();
    this.lastDialogId = 0;
    this.answered = [];
    this.autoAcceptBeforeUnload = false;
    this.mainDocuments = new Map();
    this.notes = [];
    const main = (frameId) => frameId === this.tab.frameId;
    const on = (method, handler) => this.session.on(method, handler);
    on("Page.frameRequestedNavigation", (p) => {
      if (main(p.frameId) && (p.disposition || "currentTab") === "currentTab") this.record({ type: "navRequested" });
    });
    on("Page.frameStartedNavigating", (p) => {
      if (!main(p.frameId) || p.navigationType === "sameDocument" || p.navigationType === "historySameDocument") return;
      this.record({ type: "navStarted", loaderId: p.loaderId });
    });
    on("Page.frameStartedLoading", (p) => { if (main(p.frameId)) this.record({ type: "navStarted", loaderId: null }); });
    on("Page.navigatedWithinDocument", (p) => {
      if (!main(p.frameId)) return;
      this.state.url = p.url;
      this.record({ type: "sameDocument" });
    });
    on("Page.frameNavigated", ({ frame }) => {
      if (frame.parentId) return;
      this.state.loaderId = frame.loaderId;
      this.state.url = frame.url + (frame.urlFragment || "");
      this.state.reached = new Set();
      if (this.state.dialog) { this.answered.push(this.state.dialog.id); this.state.dialog = null; }
      this.record({ type: "committed", loaderId: frame.loaderId });
      this.interrupt("navigated");
    });
    on("Page.lifecycleEvent", (p) => {
      if (!main(p.frameId) || (p.name !== "load" && p.name !== "DOMContentLoaded")) return;
      if (p.loaderId === this.state.loaderId) this.state.reached.add(p.name);
      this.record({ type: "lifecycle", name: p.name, loaderId: p.loaderId });
    });
    on("Page.frameStoppedLoading", (p) => { if (main(p.frameId)) this.record({ type: "navStopped" }); });
    on("Page.javascriptDialogOpening", (p) => {
      const dialog = { id: ++this.lastDialogId, kind: p.type || "alert", message: p.message || "", defaultPrompt: p.defaultPrompt || "" };
      if (dialog.kind === "beforeunload" && this.autoAcceptBeforeUnload) {
        this.answered.push(dialog.id);
        this.session.send("Page.handleJavaScriptDialog", { accept: true }).catch(() => {});
        return;
      }
      this.state.dialog = dialog;
      this.record({ type: "modal" });
      this.interrupt("dialogOpened");
    });
    on("Page.javascriptDialogClosed", () => {
      if (this.state.dialog) { this.answered.push(this.state.dialog.id); this.state.dialog = null; }
    });
    on("Network.requestWillBeSent", (p) => { if (p.type === "Document" && main(p.frameId)) this.mainDocuments.set(p.requestId, p.loaderId); });
    on("Network.responseReceived", (p) => { if (this.mainDocuments.has(p.requestId)) this.state.httpStatus = p.response.status; });
    on("Network.loadingFinished", (p) => { this.mainDocuments.delete(p.requestId); });
    on("Network.loadingFailed", (p) => {
      if (!this.mainDocuments.has(p.requestId)) return;
      this.mainDocuments.delete(p.requestId);
      if (p.canceled || /ERR_ABORTED$/.test(p.errorText || "")) this.record({ type: "navStopped" });
      else this.record({ type: "docFailed", errorText: p.errorText });
    });
  }

  get url() { return this.state.url; }
  get dialog() { return this.state.dialog; }
  get blocksPage() { return this.state.dialog !== null; }
  note(text) { this.notes.push(text); }
  record(event) { this.journal.push({ sequence: ++this.sequence, at: now(), event }); }
  mark() { return this.sequence; }
  events(since) { return this.journal.filter((entry) => entry.sequence > since); }

  interrupt(reason) {
    for (const waiter of [...this.waiting]) {
      if (!waiter.reasons.includes(reason)) continue;
      this.waiting.delete(waiter);
      waiter.reject(new CDPInterrupted(reason));
    }
  }

  /** Commands in one write, each with the deadline and interruptions of CDPConnection.call. */
  calls(batch, { deadline, interruptible = [] }) {
    return this.session.sendBatch(batch).map((reply) => quiet(new Promise((resolve, reject) => {
      const waiter = { reasons: interruptible, reject };
      this.waiting.add(waiter);
      const timer = setTimeout(() => { if (this.waiting.delete(waiter)) reject(new CDPTimeout()); }, Math.max(0, deadline - now()));
      reply.then((value) => { clearTimeout(timer); if (this.waiting.delete(waiter)) resolve(value); },
        (error) => { clearTimeout(timer); if (this.waiting.delete(waiter)) reject(error); });
    })));
  }

  call(method, params, options) {
    return this.calls([[method, params]], options)[0];
  }

  /** ChromiumHelper.call: refused under a dialog, interrupted by one or by a commit, a stale world asked again once. */
  async helper(op, args, { deadline, asBarrier = false }) {
    if (this.blocksPage) throw new CDPInterrupted("dialogOpened");
    let recreated = false;
    for (;;) {
      const world = await this.tab.world();
      let result;
      try {
        result = await this.call("Runtime.callFunctionOn", {
          functionDeclaration: HELPER_FUNCTION, executionContextId: world,
          arguments: [{ value: op }, { value: JSON.stringify(args) }], returnByValue: true, awaitPromise: true, silent: true,
        }, { deadline, interruptible: PAGE_INTERRUPTIONS });
      } catch (error) {
        if (!error.cdpMessage) throw error;
        this.tab.worldId = null;
        if (STALE.test(error.cdpMessage) && !asBarrier && !recreated) { recreated = true; continue; }
        if (GONE.test(error.cdpMessage)) throw new CDPInterrupted("navigated");
        throw error;
      }
      if (result.exceptionDetails) throw new AgentError("invalid", "JavaScript error: " + (result.exceptionDetails.exception?.description || "").split("\n")[0]);
      const answer = JSON.parse(result.result.value);
      if (answer.error) {
        const code = answer.error.code;
        const kind = code === "notFound" ? "notFound"
          : ["invalid", "ambiguous", "notSelect", "optionNotFound", "notEditable"].includes(code) ? "invalid" : "failed";
        throw new AgentError(kind, answer.error.message || "failed");
      }
      return answer;
    }
  }

  async barrier(deadline) {
    try { return await this.helper("barrier", {}, { deadline, asBarrier: true }); } catch { return null; }
  }

  /** dispatch(batch:): one write; a dialog or a commit ends the wait. */
  async dispatch(batch, deadline) {
    if (this.blocksPage) return "interrupted:dialogOpened";
    for (const reply of this.calls(batch, { deadline, interruptible: PAGE_INTERRUPTIONS })) {
      try {
        await reply;
      } catch (error) {
        if (error instanceof CDPInterrupted && (error.reason === "dialogOpened" || error.reason === "navigated")) return "interrupted:" + error.reason;
        throw error;
      }
    }
    return "acked";
  }

  /** DialogLedger.answer, then its reply: exactly once. */
  answerDialog(accept, promptText, dialogId) {
    const dialog = this.state.dialog;
    if (!dialog || (dialogId != null && dialogId !== dialog.id)) return false;
    this.state.dialog = null;
    this.answered.push(dialog.id);
    const params = { accept };
    if (accept && dialog.kind === "prompt") params.promptText = promptText ?? "";
    this.session.send("Page.handleJavaScriptDialog", params).catch(() => {});
    return true;
  }

  dismissDialog() {
    if (!this.state.dialog) return;
    this.answered.push(this.state.dialog.id);
    this.state.dialog = null;
    this.session.send("Page.handleJavaScriptDialog", { accept: false }).catch(() => {});
  }
}

// ---------------------------------------------------------------- the runner (ChromiumRunner)

export class Runner {
  constructor(chrome, fencePort) {
    this.chrome = chrome;
    this.fencePort = fencePort;
    this.contextId = null;
    this.target = null;
    this.runs = 0;
    this.route = null;
    this.paused = [];
    this.gone = new Set();
    chrome.conn.on("*", ({ method, params }) => {
      const target = this.target;
      if (!target || params?.targetId !== target.targetId) return;
      if (method === "Target.targetDestroyed" || method === "Target.detachedFromTarget") {
        this.gone.add(target.targetId);
        this.target = null;
        this.route?.onEnd("the script's sandbox was closed");
      } else if (method === "Target.targetCrashed") {
        target.crashed = true;
        this.route?.onEnd("the script's sandbox crashed (out of memory?)");
      }
    });
  }

  /** The fenced context, a target of its own window in it, the init burst (RunnerFence.targetInit). */
  async ensureTarget() {
    if (this.target && !this.target.crashed && this.target.runs < 32) return this.target;
    if (this.target) await settle(this.chrome.conn.send("Target.closeTarget", { targetId: this.target.targetId }));
    this.target = null;
    const router = await prepareBrowser(this.chrome);
    if (!this.contextId) {
      ({ browserContextId: this.contextId } = await this.chrome.conn.send("Target.createBrowserContext",
        { disposeOnDetach: true, proxyServer: `http://127.0.0.1:${this.fencePort}`, proxyBypassList: "<-loopback>" }));
      await this.chrome.conn.send("Browser.setDownloadBehavior", { behavior: "deny", eventsEnabled: true, browserContextId: this.contextId });
    }
    router.creating++;
    let created;
    try {
      created = await this.chrome.conn.send("Target.createTarget", { url: "about:blank", newWindow: true, browserContextId: this.contextId });
    } catch (error) {
      router.creating--;
      throw error;
    }
    const attached = router.claimed.get(created.targetId)
      ?? await withTimeout(new Promise((done) => this.chrome.conn.once(`claimed:${created.targetId}`, done)), 15_000, "the runner's attach");
    router.claimed.delete(created.targetId);
    const session = this.chrome.conn.session(attached.sessionId, created.targetId);
    session.on("Runtime.bindingCalled", ({ name, payload, executionContextId }) => {
      const route = this.route;
      // Another world's call — an earlier run's timer — is no call of this run.
      if (name !== BINDING || !route || executionContextId !== route.contextId) return;
      route.onCall(payload);
    });
    session.on("Fetch.requestPaused", ({ requestId, request }) => {
      this.paused.push(request.url);
      session.send("Fetch.failRequest", { requestId, errorReason: "BlockedByClient" }).catch(() => {});
    });
    session.on("Page.javascriptDialogOpening", () => session.send("Page.handleJavaScriptDialog", { accept: false }).catch(() => {}));
    await Promise.all(session.sendBatch([
      ["Fetch.enable", { patterns: [{ urlPattern: "*", requestStage: "Request" }] }],
      ["Network.emulateNetworkConditions", { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }],
      ["Page.enable", {}],
      ["Emulation.setFocusEmulationEnabled", { enabled: true }],
      ["Runtime.runIfWaitingForDebugger", {}],
    ]));
    this.target = { targetId: created.targetId, session, runs: 0, crashed: false };
    return this.target;
  }

  /** open(deadline:): a fresh world, its binding. */
  async open() {
    const target = await this.ensureTarget();
    target.runs++;
    const run = ++this.runs;
    const { executionContextId } = await target.session.send("Page.createIsolatedWorld",
      { frameId: target.targetId, worldName: `loom-run-${run}`, grantUniveralAccess: false });
    await target.session.send("Runtime.addBinding", { name: BINDING, executionContextId });
    return { contextId: executionContextId, run };
  }

  evaluate(expression, contextId, awaitPromise) {
    if (!this.target) return Promise.reject(new AgentError("unavailable", "the script's sandbox is gone"));
    return this.target.session.send("Runtime.evaluate", { expression, contextId, awaitPromise, returnByValue: true, silent: true });
  }

  /** deliver(reply:) / deliver(event:): a call into the run's world, never waited for. */
  deliver(json, contextId) {
    if (!this.target) return;
    this.target.session.send("Runtime.callFunctionOn", {
      functionDeclaration: ANSWER_FUNCTION, executionContextId: contextId, arguments: [{ value: json }], silent: true,
    }).catch(() => {});
  }

  async heapUsed() {
    if (!this.target) return null;
    const usage = await settle(withTimeout(this.target.session.send("Runtime.getHeapUsage"), 400, "Runtime.getHeapUsage"));
    return usage.ok ? usage.value.usedSize : null;
  }

  /** The stop ladder: terminateExecution, closeTarget waited for 1 s, else Page.crash and closeTarget again. */
  async stop() {
    this.route = null;
    const current = this.target;
    if (!current) return { rung: "none" };
    const started = now();
    await settle(withTimeout(current.session.send("Runtime.terminateExecution"), 250, "Runtime.terminateExecution"));
    const terminated = now() - started;
    settle(this.chrome.conn.send("Target.closeTarget", { targetId: current.targetId }));
    const gone = async (ms) => {
      const end = now() + ms;
      while (now() < end && !this.gone.has(current.targetId)) await delay(20);
      return this.gone.has(current.targetId);
    };
    if (await gone(1000)) return { rung: "close", terminated, closed: now() - started };
    settle(current.session.send("Page.crash"));
    settle(this.chrome.conn.send("Target.closeTarget", { targetId: current.targetId }));
    await gone(500);
    if (this.target === current) this.target = null;
    return { rung: "crash", terminated, closed: now() - started };
  }

  async dispose() {
    if (this.target) await settle(this.chrome.conn.send("Target.closeTarget", { targetId: this.target.targetId }));
    if (this.contextId) await settle(this.chrome.conn.send("Target.disposeBrowserContext", { browserContextId: this.contextId }));
    this.target = null;
    this.contextId = null;
  }
}

// ---------------------------------------------------------------- AgentRunCall.decode

class Fields {
  constructor(top, args, limits) { this.top = top; this.args = args; this.limits = limits; }
  get(key) {
    if (this.args[key] !== undefined && this.args[key] !== null) return this.args[key];
    if (this.top[key] !== undefined && this.top[key] !== null) return this.top[key];
    return undefined;
  }
  string(key) { const v = this.get(key); return typeof v === "string" ? v.slice(0, this.limits.maxText) : undefined; }
  double(key) { const v = this.get(key); return typeof v === "number" && Number.isFinite(v) ? v : undefined; }
  int(key) { const v = this.double(key); return v === undefined ? undefined : Math.round(Math.max(-1e12, Math.min(1e12, v))); }
  bool(key) { const v = this.get(key); return typeof v === "boolean" ? v : undefined; }
  clamped(key, low, high, fallback) { return Math.min(high, Math.max(low, this.int(key) ?? fallback)); }
  get timeout() { const t = this.int("timeout"); return t === undefined ? undefined : Math.min(this.limits.maxTimeout, Math.max(0, t)); }
  get delay() { return this.clamped("delay", 0, this.limits.maxDelay, 0); }
  required(key) { const v = this.string(key); if (v === undefined) throw new Failure(`${key} is required`); return v; }
  waitUntil(key = "waitUntil") {
    const raw = this.string(key);
    if (raw === undefined) return "load";
    if (!["load", "domcontentloaded", "commit", "networkidle"].includes(raw.toLowerCase())) throw new Failure(`waitUntil is load, domcontentloaded, networkidle or commit, not ${raw}`);
    return raw.toLowerCase();
  }
  target(required) {
    const raw = this.get("target");
    if (raw === undefined) { if (required) throw new Failure("this call needs a locator"); return null; }
    if (typeof raw === "string") {
      const text = raw.trim();
      if (!text || Buffer.byteLength(text) > this.limits.maxTargetBytes) throw new Failure(`a selector is 1 to ${this.limits.maxTargetBytes} bytes`);
      const desc = "locator('" + text.replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "')";
      const strict = this.bool("strict") ?? true;
      return { value: { chain: [{ selector: text }], desc, strict }, desc, strict };
    }
    if (typeof raw !== "object" || !Array.isArray(raw.chain)) throw new Failure("a locator is {chain, desc, strict}");
    if (Buffer.byteLength(JSON.stringify(raw)) > this.limits.maxTargetBytes) throw new Failure(`a locator is ${this.limits.maxTargetBytes / 1024} KB at most`);
    return { value: raw, desc: typeof raw.desc === "string" ? raw.desc.slice(0, 1000) : "locator", strict: typeof raw.strict === "boolean" ? raw.strict : true };
  }
  pointer(fallback = 1) {
    const button = this.string("button") ?? "left";
    if (!["left", "right", "middle"].includes(button)) throw new Failure(`button is left, right or middle, not ${button}`);
    const position = this.get("position");
    return { button, clickCount: this.clamped("clickCount", 1, 3, fallback),
      position: position && Number.isFinite(position.x) && Number.isFinite(position.y) ? { x: position.x, y: position.y } : null,
      force: this.bool("force") ?? false, trial: this.bool("trial") ?? false, delay: this.delay };
  }
  argument(key = "arg") {
    if (this.args[key] === null) return "null";
    const v = this.get(key);
    return v === undefined ? "undefined" : JSON.stringify(v);
  }
}

function decodeOp(name, f, limits) {
  switch (name) {
    case "goto": return { kind: "goto", url: f.required("url"), waitUntil: f.waitUntil(), timeout: f.timeout };
    case "title": return { kind: "title" };
    case "click": case "dblclick": return { kind: "click", target: f.target(true), pointer: f.pointer(name === "dblclick" ? 2 : 1), timeout: f.timeout };
    case "fill": return { kind: "fill", target: f.target(true), value: f.string("value") ?? "", timeout: f.timeout };
    case "type": return { kind: "type", target: f.target(false), text: f.required("text"), delay: f.delay, timeout: f.timeout };
    case "press": return { kind: "press", target: f.target(false), key: f.required("key"), delay: f.delay, timeout: f.timeout };
    case "check": case "uncheck": case "setChecked":
      return { kind: "check", checked: name === "uncheck" ? false : (f.bool("checked") ?? true), target: f.target(true), pointer: f.pointer(), timeout: f.timeout };
    case "select": {
      const raw = f.get("options") ?? f.get("values") ?? [];
      if (raw.length > limits.maxOptions) throw new Failure(`selectOption takes ${limits.maxOptions} options at most`);
      const options = raw.map((item) => {
        if (typeof item === "string") return item;
        if (typeof item?.value === "string") return { value: item.value };
        if (typeof item?.label === "string") return { label: item.label };
        if (typeof item?.index === "number" && item.index >= 0) return { index: Math.trunc(item.index) };
        throw new Failure("an option is a string, {value}, {label} or {index}");
      });
      return { kind: "select", target: f.target(true), options, timeout: f.timeout };
    }
    case "focus": case "blur": case "scroll": return { kind: name, target: f.target(true), timeout: f.timeout };
    case "read": return { kind: "read", target: f.target(true), what: f.required("what"), name: f.string("name"), timeout: f.timeout };
    case "state": return { kind: "state", target: f.target(true), what: f.required("what") };
    case "count": return { kind: "count", target: f.target(true) };
    case "readAll": return { kind: "readAll", target: f.target(true), what: f.required("what"), name: f.string("name") };
    case "eval": { const fn = f.required("fn"); return { kind: "evaluate", fn, argument: f.argument(), target: f.target(false), all: f.bool("all") ?? false }; }
    case "waitState": {
      const state = f.string("state") ?? "visible";
      if (!["attached", "detached", "visible", "hidden"].includes(state)) throw new Failure(`state is attached, detached, visible or hidden, not ${state}`);
      return { kind: "waitState", target: f.target(true), state, timeout: f.timeout };
    }
    case "waitLoad": return { kind: "waitLoad", state: f.waitUntil("state"), timeout: f.timeout };
    case "nextURL": return { kind: "nextURL", since: f.string("since") ?? "", timeout: f.timeout };
    case "waitFn": return { kind: "waitFunction", fn: f.required("fn"), argument: f.argument(), polling: f.string("polling") === "raf" ? 16 : f.clamped("polling", 16, 10_000, 100), timeout: f.timeout };
    case "sleep": return { kind: "sleep", ms: f.clamped("ms", 0, limits.maxTimeout, 0) };
    case "key": {
      const action = f.string("action") ?? "press";
      if (!["down", "up", "press", "type", "insertText"].includes(action)) throw new Failure(`keyboard's action is down, up, press, type or insertText, not ${action}`);
      const key = f.string("key");
      const text = f.string("text");
      if (action === "type" || action === "insertText") { if (text === undefined) throw new Failure("text is required"); } else if (key === undefined) throw new Failure("key is required");
      return { kind: "key", action, key, text, delay: f.delay };
    }
    case "dialog": {
      const id = f.int("id") ?? f.int("dialogId");
      if (id === undefined) throw new Failure("dialog needs its id");
      return { kind: "dialog", id, accept: f.bool("accept") ?? true, promptText: f.string("promptText") };
    }
    case "listen": return { kind: "listen", dialog: f.bool("dialog") ?? false };
    case "history": case "goBack": case "goForward": case "reload": case "content": case "hover": case "aria": case "mouse": case "viewport": case "shot": case "files":
      return { kind: name, target: f.get("target") === undefined ? null : f.target(false) };
    default: throw new Failure(`unknown page call ${name.length > 80 ? name.slice(0, 80) + "…" : name}`);
  }
}

const WAIT_KINDS = new Set(["waitState", "waitLoad", "nextURL", "waitFunction", "sleep"]);
const laneOf = (op) => (WAIT_KINDS.has(op.kind) ? "wait" : op.kind === "dialog" || op.kind === "listen" ? "immediate" : "action");

/** AgentRunOp.api. */
function apiOf(op) {
  const owner = op.target ? "locator" : "page";
  switch (op.kind) {
    case "goto": return "page.goto";
    case "click": return op.pointer.clickCount === 2 ? "locator.dblclick" : "locator.click";
    case "check": return op.checked ? "locator.check" : "locator.uncheck";
    case "select": return "locator.selectOption";
    case "type": return owner + ".pressSequentially";
    case "press": return owner + ".press";
    case "read": return "locator." + op.what;
    case "readAll": return op.what === "innerText" ? "locator.allInnerTexts" : "locator.allTextContents";
    case "evaluate": return op.all ? "locator.evaluateAll" : owner + ".evaluate";
    case "nextURL": return "page.waitForURL";
    case "waitLoad": return "page.waitForLoadState";
    case "waitState": return "locator.waitFor";
    case "waitFunction": return "page.waitForFunction";
    case "sleep": return "page.waitForTimeout";
    case "key": return "keyboard." + op.action;
    case "dialog": return op.accept ? "dialog.accept" : "dialog.dismiss";
    case "listen": return "page.on";
    default: return owner + "." + op.kind;
  }
}

/** AgentRunOp.summary. */
function summaryOf(op) {
  const short = (text) => (text.length > 80 ? text.slice(0, 80) + "…" : text);
  if (op.kind === "goto") return "goto " + short(op.url);
  if (op.kind === "press") return "press " + op.key + (op.target ? " on " + op.target.desc : "");
  if (op.kind === "key") return apiOf(op) + " " + short(op.key ?? op.text ?? "");
  const name = apiOf(op).split(".").pop();
  return op.target ? name + " " + op.target.desc : name;
}

/** {call} or {refused: {id, failure}}. */
export function decodeCall(payload, limits = RUN_LIMITS) {
  const refused = (id, message) => ({ refused: { id, failure: { name: "Error", message } } });
  if (Buffer.byteLength(payload) > limits.maxMessageBytes) return refused(null, `a page call is ${limits.maxMessageBytes / 1024 | 0} KB at most`);
  let message = null;
  try { message = JSON.parse(payload); } catch { /* refused below */ }
  if (!message || typeof message !== "object" || Array.isArray(message)) return refused(null, "a page call is a JSON object");
  if (typeof message.id !== "number" || !Number.isFinite(message.id) || message.id < 0 || message.id >= 1e12) return refused(null, "a page call needs an id");
  const id = Math.trunc(message.id);
  if (typeof message.op !== "string") return refused(id, "a page call needs an op");
  const args = message.args && typeof message.args === "object" && !Array.isArray(message.args) ? message.args : {};
  const f = new Fields(message, args, limits);
  try {
    const op = decodeOp(message.op, f, limits);
    const line = f.int("line");
    const api = typeof message.api === "string" && message.api && message.api.length <= 80 ? message.api : apiOf(op);
    const step = typeof message.step === "number" && Number.isFinite(message.step) && message.step >= 1 && message.step < 1e9 ? Math.trunc(message.step) : null;
    return { call: { id, line: line > 0 ? line : null, op, api, step } };
  } catch (error) {
    return { refused: { id, failure: error.failure ?? { name: "Error", message: String(error.message) } } };
  }
}

/** AgentRunReply.json. */
function replyJSON({ id, ok, value, error, url }) {
  let text = `{"id":${id},"ok":${ok ? "true" : "false"}`;
  if (value != null && value !== "undefined") text += `,"value":${value}`;
  if (error) text += `,"error":{"name":${JSON.stringify(error.name)},"message":${JSON.stringify(error.message)}}`;
  if (url != null) text += `,"url":${JSON.stringify(url)}`;
  return text + "}";
}

/** The AsyncStream of a run's events. */
class Channel {
  constructor() { this.items = []; this.waiter = null; this.done = false; }
  yield(item) {
    if (this.done) return;
    if (this.waiter) { const waiter = this.waiter; this.waiter = null; waiter(item); } else this.items.push(item);
  }
  next() { return this.items.length ? Promise.resolve(this.items.shift()) : new Promise((resolve) => { this.waiter = resolve; }); }
  finish() { this.done = true; }
}

// ---------------------------------------------------------------- the run (runCode)

/**
 * One browser_run_code: the agent's `code` in a fresh world of `runner`, its
 * page calls on `page` (a RunPage). Answers the report (AgentRunReport's
 * fields: error, steps, value, output, outputDropped, unfinished,
 * syntaxError) with what the tests read of the run: `run` (steps, messages,
 * replies, maxInFlightSeen…), `stopped`, `ladder` (the stop ladder's rung and
 * times), `heapSamples`, and when the run's loop ended (`endedAt`). After a
 * stop the evaluation is not waited for: its target is closed under it.
 */
export async function runCode(code, { page, runner, limits: overrides = {}, deadlineMs = 60_000 } = {}) {
  const limits = { ...RUN_LIMITS, ...overrides };
  const started = now();
  const deadline = started + deadlineMs;
  const scriptEnd = Math.min(deadline - limits.endReserve, started + limits.scriptTime);
  if (page.blocksPage) throw new AgentError("conflict", "a dialog is open: answer it with browser_handle_dialog first");
  const world = await runner.open();
  const events = new Channel();
  const run = {
    page, runner, world, limits, started, scriptEnd, deadline, events,
    ended: false, steps: 0, countedSteps: new Set(), messages: 0, transferred: 0, inFlight: 0, maxInFlightSeen: 0,
    recent: [], lastLine: null, dialogListener: false, dialogsSent: new Set(), actionTail: Promise.resolve(),
    replies: [], activity: [],
  };
  runner.route = { contextId: world.contextId, onCall: (payload) => events.yield({ call: payload }), onEnd: (reason) => events.yield({ stop: { runnerGone: reason } }) };

  const config = { consoleChars: limits.consoleChars, consoleLines: limits.consoleLines, defaultTimeout: limits.actionTimeout,
    maxInFlight: limits.maxInFlight, maxMessageBytes: limits.maxMessageBytes, maxSteps: limits.maxSteps,
    navigationTimeout: limits.navigationTimeout, scriptMs: Math.max(1, Math.round(scriptEnd - now())), url: page.url,
    valueChars: 20_000, viewport: { height: 800, width: 1280 } };
  const installed = await runner.evaluate(FACADE + "\n;globalThis.__loomRun.start(" + JSON.stringify(config) + ");\n//# sourceURL=loom-runner.js", world.contextId, false);
  if (installed.exceptionDetails) throw new Error("the facade did not start: " + JSON.stringify(installed.exceptionDetails));

  const out = { run, heapSamples: [] };
  runner.evaluate(entry(code), world.contextId, true).then(
    (result) => events.yield({ finished: result }),
    (error) => events.yield({ finished: null, failure: error.message }));
  // Unref'd: a run that hangs fails its test, it does not keep the process alive.
  const timer = setTimeout(() => events.yield({ stop: "deadline" }), Math.max(0, scriptEnd - now())).unref();
  const seen = new Set();
  const dialogWatch = setInterval(() => {
    const dialog = page.dialog;
    if (dialog && !seen.has(dialog.id)) { seen.add(dialog.id); events.yield({ dialog }); }
  }, 25).unref();
  const heapWatch = setInterval(async () => {
    const used = await runner.heapUsed();
    out.heapSamples.push(used);
    if (used != null && used > limits.heapCapBytes) events.yield({ stop: "memory" });
  }, 500).unref();

  let outcome = null;
  let stopped = null;
  for (;;) {
    const event = await events.next();
    if (event.call !== undefined) {
      stopped = admit(event.call, run);
      if (stopped) break;
    } else if (event.finished !== undefined) {
      outcome = { result: event.finished, failure: event.failure };
      break;
    } else if (event.stop) {
      stopped = event.stop;
      break;
    } else if (event.dialog) {
      if (page.dialog?.id !== event.dialog.id) continue;
      if (run.dialogListener) sendDialog(event.dialog, run);
      else { stopped = { dialog: event.dialog }; break; }
    }
  }
  out.endedAt = now();
  run.ended = true;
  runner.route = null;
  events.finish();
  clearTimeout(timer);
  clearInterval(dialogWatch);
  clearInterval(heapWatch);
  out.ladder = (stopped || !outcome?.result) && !stopped?.runnerGone ? await runner.stop() : null;
  const report = { steps: run.recent.slice(-limits.stepsShown) };
  if (stopped) report.error = stopMessage(stopped, run);
  else readOutcome(outcome, report);
  return { ...out, report, stopped, outcome };
}

/** runAdmit: the caps, then the call into its lane; a stop when a cap is passed. */
function admit(payload, run) {
  const limits = run.limits;
  const size = Buffer.byteLength(payload);
  run.messages += 1;
  run.transferred += size;
  if (size > limits.maxMessageBytes) return "oversize";
  if (run.messages > 2 * limits.maxSteps) return "flood";
  if (run.transferred > limits.maxTransferBytes) return "transfer";
  const decoded = decodeCall(payload, limits);
  if (decoded.refused) {
    if (decoded.refused.id != null) send({ id: decoded.refused.id, ok: false, error: decoded.refused.failure, url: run.page.url }, run);
    return null;
  }
  const call = decoded.call;
  const lane = laneOf(call.op);
  if (lane !== "immediate") {
    const fresh = call.step === null || !run.countedSteps.has(call.step);
    if (call.step !== null) run.countedSteps.add(call.step);
    if (fresh) run.steps += 1;
    if (run.steps > limits.maxSteps) return "steps";
    if (run.inFlight >= limits.maxInFlight) {
      send({ id: call.id, ok: false, error: { name: "Error", message: `more than ${limits.maxInFlight} page calls in flight` }, url: run.page.url }, run);
      return null;
    }
    if (call.line) run.lastLine = call.line;
    if (fresh) {
      run.recent.push(`${run.steps}) ` + summaryOf(call.op));
      if (run.recent.length > limits.stepsShown) run.recent.splice(0, run.recent.length - limits.stepsShown);
      run.activity.push(`Running code · ${run.steps}: ` + summaryOf(call.op));
    }
  }
  if (lane === "immediate") {
    immediate(call, run);
  } else {
    run.inFlight += 1;
    run.maxInFlightSeen = Math.max(run.maxInFlightSeen, run.inFlight);
    if (lane === "action") run.actionTail = run.actionTail.then(() => answer(call, run));
    else answer(call, run);
  }
  return null;
}

/** runCall. */
async function answer(call, run) {
  try {
    if (run.ended) return;
    let reply;
    try {
      reply = { id: call.id, ok: true, value: await perform(call, run), url: run.page.url };
    } catch (error) {
      if (run.ended || error instanceof Cancelled) return;
      reply = { id: call.id, ok: false, error: runFailure(error, call.api), url: run.page.url };
    }
    send(reply, run);
  } finally {
    run.inFlight -= 1;
  }
}

function send(reply, run) {
  if (run.ended) return;
  const json = replyJSON(reply);
  run.transferred += Buffer.byteLength(json);
  run.replies.push(reply);
  run.runner.deliver(json, run.world.contextId);
}

/** runImmediate. */
function immediate(call, run) {
  const op = call.op;
  if (op.kind === "listen") {
    run.dialogListener = op.dialog;
    send({ id: call.id, ok: true, value: "null", url: run.page.url }, run);
    if (op.dialog && run.page.dialog) sendDialog(run.page.dialog, run);
  } else if (run.page.answerDialog(op.accept, op.promptText, op.id)) {
    send({ id: call.id, ok: true, value: "null", url: run.page.url }, run);
  } else {
    send({ id: call.id, ok: false, error: { name: "Error", message: `Cannot ${op.accept ? "accept" : "dismiss"} dialog which is already handled!` }, url: run.page.url }, run);
  }
}

/** runSendDialog: once per dialog. */
function sendDialog(dialog, run) {
  if (run.ended || run.dialogsSent.has(dialog.id)) return;
  run.dialogsSent.add(dialog.id);
  run.runner.deliver(JSON.stringify({ event: "dialog", dialog: { id: dialog.id, type: dialog.kind, message: dialog.message, defaultValue: dialog.defaultPrompt } }), run.world.contextId);
}

// ---------------------------------------------------------------- ops (runOp)

const check = (run) => { if (run.ended) throw new Cancelled(); };
/** runLimit: [the call's end, the ms an error names]. */
const limitOf = (timeout, fallback, run) => { const asked = timeout ?? fallback; return [Math.min(now() + Math.max(0, asked), run.scriptEnd), asked]; };
/** runCallEnd. */
const callEnd = (limit, run) => Math.min(run.deadline - 2000, Math.max(limit, now() + 750));

function helper(op, args, run, limit) {
  check(run);
  return run.page.helper(op, args, { deadline: callEnd(limit, run) });
}

/** runTransient. */
async function transient(error, run, limit) {
  if (error instanceof CDPInterrupted && error.reason === "navigated") return "the page navigated";
  if (error instanceof CDPInterrupted && error.reason === "dialogOpened") { await afterDialog(run, limit); return "the page waits on a dialog"; }
  if (error instanceof CDPTimeout) return "the page did not answer in time";
  throw error;
}

/** runResolving and runPrepare: asked again while not found (or not ready), until `limit`. */
async function retrying(op, args, target, run, limit, ms, api, { ready = false, pause = 30 } = {}) {
  let reason = null;
  for (;;) {
    check(run);
    try {
      const answer = await helper(op, args, run, limit);
      if (!ready || answer.status === "ready") return answer;
      reason = answer.reason ?? null;
    } catch (error) {
      if (error instanceof AgentError) { if (error.kind !== "notFound") throw error; reason = null; }
      else if (error instanceof CDPInterrupted || error instanceof CDPTimeout) reason = await transient(error, run, limit);
      else throw error;
    }
    if (now() >= limit) throw new RunTimeout(api, ms, "waiting for " + target.desc, reason);
    await delay(pause);
  }
}

const prepare = (target, action, run, limit, ms, api, focus = false) => retrying("prepare",
  { target: target.value, action, trusted: true, ...(focus ? { focus: true, selectAll: true } : {}) },
  target, run, limit, ms, api, { ready: true, pause: action === "click" || action === "hover" ? 16 : 30 });

/** runPoint. */
async function pointOf(target, pointer, run, limit, ms, api) {
  const answer = pointer.force ? await retrying("rect", { target: target.value }, target, run, limit, ms, api)
    : await prepare(target, "click", run, limit, ms, api);
  if (pointer.position && answer.rect) return { x: answer.rect.x + pointer.position.x, y: answer.rect.y + pointer.position.y };
  if (answer.point) return answer.point;
  if (answer.rect) return { x: answer.rect.x + answer.rect.width / 2, y: answer.rect.y + answer.rect.height / 2 };
  throw new AgentError("failed", `the page did not say where ${target.desc} is`);
}

/** runAfterDialog: with a listener, until the script answers (true) or `limit` (false); without one, the run stops. */
async function afterDialog(run, limit) {
  const dialog = run.page.dialog;
  if (!dialog) return true;
  if (!run.dialogListener) run.events.yield({ dialog });
  while (run.page.dialog) {
    check(run);
    if (now() >= limit) return false;
    await delay(15);
  }
  return true;
}

/** runSettle. */
async function settleAfter(run, mark, outcome, limit) {
  if (outcome === "interrupted:dialogOpened" || run.page.blocksPage) {
    if (!await afterDialog(run, limit)) {
      if (run.page.dialog) throw new DialogWait(run.page.dialog);
      return;
    }
  }
  await run.page.barrier(Math.min(callEnd(limit, run), now() + 2000));
  await commit(run, mark, Math.min(run.scriptEnd, now() + run.limits.navigationTimeout));
}

/** runCommit. */
async function commit(run, mark, limit) {
  const page = run.page;
  for (;;) {
    check(run);
    let phase = 0;
    let requestedAt = null;
    let failure = null;
    for (const { at, event } of page.events(mark)) {
      switch (event.type) {
        case "navRequested": if (phase !== 2) { phase = 1; requestedAt = at; } break;
        case "navStarted": phase = 2; break;
        case "committed": case "sameDocument": phase = 3; failure = null; break;
        case "docFailed": phase = 3; failure = event.errorText; break;
        case "navStopped": if (phase === 1 || phase === 2) phase = 3; break;
        case "modal": return;
        default: break;
      }
    }
    if (phase === 0 || phase === 3) {
      if (failure) page.note("A page load the script started failed: " + failure);
      return;
    }
    if (phase === 1 && now() - requestedAt >= 500) return;
    if (now() >= limit) return;
    await delay(15);
  }
}

/** runLoadState. */
async function loadState(state, loaderId, mark, run, limit, ms, api, what) {
  const page = run.page;
  let quietSince = null;
  for (;;) {
    check(run);
    let expected = loaderId;
    let committed = mark === null;
    if (mark !== null) {
      for (const { event } of page.events(mark)) {
        if (event.type === "committed") { committed = true; if (loaderId === null) expected = event.loaderId; }
        if (event.type === "sameDocument" && loaderId === null) return;
        if (event.type === "docFailed") throw new AgentError("failed", event.errorText);
      }
    }
    const current = page.state;
    if (state === "commit" && committed) return;
    if (committed && (expected === null || current.loaderId === expected)) {
      const loaded = !current.loaderId || current.reached.has(state === "domcontentloaded" ? "DOMContentLoaded" : "load");
      if (loaded && state !== "networkidle") return;
      if (loaded && state === "networkidle") {
        quietSince ??= now();
        if (now() - quietSince >= 500) return;
      }
    }
    if (page.blocksPage) return;
    if (now() >= limit) throw new RunTimeout(api, ms, what, null);
    await delay(15);
  }
}

function keyEvents(name) {
  const parts = name.split("+");
  const key = parts.pop();
  const spec = KEYS[key] ?? (key.length === 1 ? charKey(key) : null);
  if (!spec) throw new AgentError("invalid", `unknown key ${name}`);
  return keyPress(spec, { modifiers: parts });
}

/** runPageEvaluate: the page's own world, as browser_evaluate; a dialog it opens is the listener's to answer. */
async function pageEvaluate(expression, run) {
  const page = run.page;
  if (page.blocksPage && !await afterDialog(run, run.scriptEnd)) throw new AgentError("conflict", "a dialog is open on the page");
  const interruptible = run.dialogListener ? ["navigated", "crashed", "detached"] : PAGE_INTERRUPTIONS;
  let result;
  try {
    result = await page.call("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true, userGesture: true },
      { deadline: callEnd(run.scriptEnd, run), interruptible });
  } catch (error) {
    if (error instanceof CDPTimeout) {
      page.session.send("Runtime.terminateExecution").catch(() => {});
      throw new AgentError("timeout", "the function did not finish before the script's time was out; Loom stopped it");
    }
    if (error instanceof CDPInterrupted && error.reason === "navigated") throw new AgentError("failed", "Execution context was destroyed, most likely because of a navigation");
    if (error instanceof CDPInterrupted && error.reason === "dialogOpened") {
      await afterDialog(run, run.scriptEnd);
      throw new AgentError("conflict", "the function opened a dialog");
    }
    throw error;
  }
  if (result.exceptionDetails) throw new AgentError("failed", (result.exceptionDetails.exception?.description || result.exceptionDetails.text || "").split("\n")[0]);
  return result.result?.value;
}

const callable = (fn) => (isFunction(fn.trim()) ? fn.trim() : "() => (\n" + fn.trim() + "\n)");

/** runEvaluateExpression. */
function evaluateExpression(fn, argument, nonce, all, expected = 1) {
  return `(async () => {
const __loomNonce = ${JSON.stringify(nonce)};
const __loomArg = (${argument});
let __loomTarget;
if (__loomNonce) {
  const found = (${STAMP_LOOKUP})(__loomNonce, ${expected});
  __loomTarget = ${all ? "found" : "found[0]"};
}
const __loomFunction = (
${callable(fn)}
);
const __loomValue = __loomNonce ? await __loomFunction(__loomTarget, __loomArg) : await __loomFunction(__loomArg);
return (${SERIALIZER})(__loomValue);
})()`;
}

async function perform(call, run) {
  const page = run.page;
  const op = call.op;
  const api = call.api;
  const limits = run.limits;
  switch (op.kind) {
    case "goto": {
      const [limit, ms] = limitOf(op.timeout, limits.navigationTimeout, run);
      let address = op.url.trim();
      if ("/?#.".includes(address[0]) && /^https?:/.test(page.url)) address = new URL(address, page.url).href;
      let target;
      try { target = new URL(address); } catch { throw new AgentError("invalid", `${address} is not an address`); }
      if (!["http:", "https:"].includes(target.protocol) && target.href !== "about:blank") {
        throw new AgentError("invalid", `the agent's browser opens http(s) addresses only, not ${target.protocol}`);
      }
      if (page.dialog) { page.dismissDialog(); page.note("The page's dialog was dismissed by the navigation."); }
      page.autoAcceptBeforeUnload = true;
      try {
        const mark = page.mark();
        const waiting = `navigating to "${target.href}", waiting until "${op.waitUntil}"`;
        let navigation;
        try {
          navigation = await page.call("Page.navigate", { url: target.href, transitionType: "typed" },
            { deadline: callEnd(limit, run), interruptible: ["dialogOpened", "crashed", "detached"] });
        } catch (error) {
          if (error instanceof CDPTimeout) throw new RunTimeout(api, ms, waiting, null);
          throw error;
        }
        if (navigation.errorText) throw new AgentError("failed", navigation.errorText);
        if (!navigation.loaderId) return "null";
        await loadState(op.waitUntil, navigation.loaderId, mark, run, limit, ms, api, waiting);
        const status = page.state.httpStatus;
        return status == null ? "null" : JSON.stringify({ url: page.url, status, ok: status >= 200 && status < 300 });
      } finally {
        page.autoAcceptBeforeUnload = false;
      }
    }
    case "title":
      return JSON.stringify((await helper("pageInfo", {}, run, limitOf(undefined, limits.actionTimeout, run)[0])).title ?? "");
    case "click": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      const point = await pointOf(op.target, op.pointer, run, limit, ms, api);
      if (op.pointer.trial) return "null";
      const mark = page.mark();
      const outcome = await page.dispatch(mouseClick(point.x, point.y, { button: op.pointer.button, clickCount: op.pointer.clickCount }), callEnd(limit, run));
      await settleAfter(run, mark, outcome, limit);
      return "null";
    }
    case "fill": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      const ready = await prepare(op.target, "type", run, limit, ms, api, true);
      const mark = page.mark();
      let outcome = "acked";
      if (ready.fill === "insertText") {
        outcome = await page.dispatch(op.value ? [["Input.insertText", { text: op.value }]] : keyEvents("Delete"), callEnd(limit, run));
      } else if (ready.fill === "setValue") {
        await helper("type", { target: op.target.value, text: op.value, submit: false }, run, limit);
      } else {
        throw new AgentError("invalid", "Element is not an <input>, <textarea> or [contenteditable] element");
      }
      await settleAfter(run, mark, outcome, limit);
      return "null";
    }
    case "type": case "press": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      if (op.target) await retrying("focus", { target: op.target.value }, op.target, run, limit, ms, api);
      const mark = page.mark();
      const batch = op.kind === "press" ? keyEvents(op.key) : [["Input.insertText", { text: op.text }]];
      await settleAfter(run, mark, await page.dispatch(batch, callEnd(limit, run)), limit);
      return "null";
    }
    case "key": {
      const [limit] = limitOf(undefined, limits.actionTimeout, run);
      const mark = page.mark();
      if (op.action !== "press" && op.action !== "type" && op.action !== "insertText") throw new AgentError("failed", "the stand-in does not do keyboard." + op.action);
      const batch = op.action === "press" ? keyEvents(op.key) : [["Input.insertText", { text: op.text }]];
      await settleAfter(run, mark, await page.dispatch(batch, callEnd(limit, run)), limit);
      return "null";
    }
    case "check": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      const before = await retrying("read", { target: op.target.value, what: "checked" }, op.target, run, limit, ms, api);
      if (before.value === op.checked) return "null";
      const point = await pointOf(op.target, op.pointer, run, limit, ms, api);
      if (op.pointer.trial) return "null";
      const mark = page.mark();
      await settleAfter(run, mark, await page.dispatch(mouseClick(point.x, point.y), callEnd(limit, run)), limit);
      if (page.blocksPage) return "null";
      const after = await helper("read", { target: op.target.value, what: "checked" }, run, limit);
      if (after.value !== op.checked) throw new AgentError("failed", "Clicking the checkbox did not change its state");
      return "null";
    }
    case "select": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      await prepare(op.target, "select", run, limit, ms, api);
      const mark = page.mark();
      const answer = await helper("selectOption", { target: op.target.value, values: op.options }, run, limit);
      await settleAfter(run, mark, "acked", limit);
      return JSON.stringify(answer.values ?? []);
    }
    case "focus": case "blur": case "scroll": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      await retrying(op.kind === "scroll" ? "rect" : op.kind, { target: op.target.value }, op.target, run, limit, ms, api);
      return "null";
    }
    case "read": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      const answer = await retrying("read", { target: op.target.value, what: op.what, ...(op.name === undefined ? {} : { name: op.name }) }, op.target, run, limit, ms, api);
      return answer.value === undefined ? "null" : JSON.stringify(answer.value);
    }
    case "state":
      return JSON.stringify((await helper("state", { target: op.target.value, what: op.what }, run, limitOf(undefined, limits.actionTimeout, run)[0])).value ?? null);
    case "count":
      return String((await helper("count", { target: op.target.value }, run, limitOf(undefined, limits.actionTimeout, run)[0])).count ?? 0);
    case "readAll":
      return JSON.stringify((await helper("readAll", { target: op.target.value, what: op.what }, run, limitOf(undefined, limits.actionTimeout, run)[0])).value ?? []);
    case "evaluate": {
      let nonce = "";
      let expected = 1;
      if (op.target) {
        const [limit, ms] = limitOf(undefined, limits.actionTimeout, run);
        const stamped = op.all ? await helper("stampAll", { target: op.target.value }, run, limit)
          : await retrying("stamp", { target: op.target.value }, op.target, run, limit, ms, api);
        nonce = stamped.nonce ?? "";
        if (op.all) expected = stamped.count ?? 0;
      }
      const raw = await pageEvaluate(evaluateExpression(op.fn, op.argument, nonce, op.all, expected), run);
      return JSON.stringify(typeof raw === "string" ? raw : "undefined");
    }
    case "waitState": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      for (;;) {
        check(run);
        const left = Math.max(0, Math.round(limit - now()));
        try {
          const answer = await page.helper("waitState", { target: op.target.value, state: op.state, maxMs: Math.min(2000, left) },
            { deadline: callEnd(now() + Math.min(2000, left) + 2000, run) });
          if (answer.done === true) return "null";
        } catch (error) {
          if (!(error instanceof CDPInterrupted || error instanceof CDPTimeout)) throw error;
          await transient(error, run, limit);
        }
        if (now() >= limit) throw new RunTimeout(api, ms, `waiting for ${op.target.desc} to be ${op.state}`, null);
      }
    }
    case "waitLoad": {
      const [limit, ms] = limitOf(op.timeout, limits.navigationTimeout, run);
      await loadState(op.state, null, null, run, limit, ms, api, null);
      return "null";
    }
    case "nextURL": {
      const [limit, ms] = limitOf(op.timeout, limits.navigationTimeout, run);
      for (;;) {
        check(run);
        if (page.url && page.url !== op.since) return JSON.stringify(page.url);
        if (now() >= limit) throw new RunTimeout(api, ms, "waiting for navigation", null);
        await delay(15);
      }
    }
    case "waitFunction": {
      const [limit, ms] = limitOf(op.timeout, limits.actionTimeout, run);
      const expression = `(async () => { const __loomArg = (${op.argument}); const __loomFunction = (\n${callable(op.fn)}\n); `
        + `const __loomValue = await __loomFunction(__loomArg); return __loomValue ? (${SERIALIZER})(__loomValue) : null; })()`;
      for (;;) {
        check(run);
        if (!page.blocksPage) {
          const raw = await pageEvaluate(expression, run);
          if (typeof raw === "string") return JSON.stringify(raw);
        }
        if (now() >= limit) throw new RunTimeout(api, ms, null, null);
        await delay(op.polling);
      }
    }
    case "sleep":
      await delay(Math.max(0, Math.min(op.ms, run.scriptEnd - now())));
      check(run);
      return "null";
    default:
      throw new AgentError("failed", "the stand-in does not do " + op.kind);
  }
}

// ---------------------------------------------------------------- the end

/** runStopMessage. */
function stopMessage(stop, run) {
  const limits = run.limits;
  const at = `at step ${run.steps}` + (run.lastLine ? ` (line ${run.lastLine} of your code)` : "");
  if (stop === "deadline") return `The script ran out of time: browser_run_code stops a script after ${Math.floor((run.scriptEnd - run.started) / 1000)} s. It was stopped ${at}.`;
  if (stop === "steps") return `The script made more than ${limits.maxSteps} page calls: it was stopped.`;
  if (stop === "flood") return `The script called Loom's bridge more than ${2 * limits.maxSteps} times: it was stopped.`;
  if (stop === "transfer") return `The script's page calls carried more than ${limits.maxTransferBytes / 1048576 | 0} MB: it was stopped.`;
  if (stop === "oversize") return `A page call was larger than ${limits.maxMessageBytes / 1024 | 0} KB: the script was stopped.`;
  if (stop === "memory") return `The script used more than ${limits.heapCapBytes / 1048576 | 0} MB of memory: it was stopped.`;
  if (stop.dialog) {
    const kind = stop.dialog.kind === "beforeunload" ? "confirm" : stop.dialog.kind;
    return `The page opened a ${kind} dialog (${JSON.stringify(stop.dialog.message)}) ${at}: the script was stopped. `
      + "Answer it with browser_handle_dialog, or handle it in the script: page.once('dialog', d => d.accept()).";
  }
  return `The script's sandbox stopped (${stop.runnerGone}) ${at}.`;
}

/** runRead. */
function readOutcome(outcome, report) {
  if (outcome.failure) { report.error = `The script did not finish: ${outcome.failure}`; return; }
  const result = outcome.result;
  if (result?.exceptionDetails) {
    const description = (result.exceptionDetails.exception?.description || result.exceptionDetails.text || "").split("\n")[0];
    if (!description.startsWith("SyntaxError")) { report.error = description; return; }
    report.syntaxError = true;
    const line = result.exceptionDetails.lineNumber;
    report.error = description + (line >= 1 ? ` (line ${line}, column ${result.exceptionDetails.columnNumber + 1} of your code)` : "") + ". Nothing ran.";
    return;
  }
  const value = result?.result?.value;
  if (!value || typeof value !== "object") { report.error = "The script ended without an answer."; return; }
  report.output = (value.logs ?? []).filter((line) => typeof line === "string");
  report.outputDropped = value.logsDropped ?? 0;
  report.unfinished = (value.unfinished ?? []).filter((line) => typeof line === "string");
  if (value.ok === true) { report.value = value.value; return; }
  const failure = value.error ?? {};
  const name = typeof failure.name === "string" ? failure.name : "Error";
  const message = typeof failure.message === "string" ? failure.message : "the script failed";
  let text = message.startsWith(name + ":") ? message : name + ": " + message;
  const line = typeof failure.line === "number" ? Math.trunc(failure.line) : null;
  if (line !== null && !text.includes(`line ${line} of your code`)) text += ` (line ${line} of your code` + (typeof failure.step === "number" ? `, step ${failure.step}` : "") + ")";
  report.error = text;
}
