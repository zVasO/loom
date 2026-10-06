// What Loom's Chromium engine sends to a browser and to each of its tabs —
// engine design §2.4 and §3.1 as the step-0 probes amended them:
//
// - no Runtime.enable: the helper's world comes from Page.createIsolatedWorld,
//   which returns the world addScriptToEvaluateOnNewDocument made;
// - Runtime.addBinding installs the binding only in the documents whose world
//   exists when it is sent, so on every Page.frameNavigated Loom sends, in one
//   write, Page.createIsolatedWorld (the world exists from then on, even where
//   Blink makes contexts lazily, as the headless shell does for a subframe)
//   and Runtime.addBinding again; the relay holds its messages until the
//   binding is there;
// - every tab is its own window (newWindow:true): in the full browser's new
//   headless mode, a second tab in a window hides the first;
// - device scale 1 (critic C1).
//
// fixtures/init.json is this file's output with the scripts left as
// placeholders: the reference the Swift engine is written against
// (target-init.test.mjs fails when it drifts; LOOM_CDP_UPDATE=1 rewrites it).
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as scripts from "../../AgentBrowserJS/extract.mjs";
import { settle, withTimeout } from "./cdp.mjs";
import { mouseClick } from "./input.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const initFixture = resolve(here, "../fixtures/init.json");

export const WORLD = "loom-agent";
export const BINDING = "__loomHookBinding";
export const VIEWPORT = Object.freeze({ width: 1280, height: 800 });
export const DENIED_PERMISSIONS = ["camera", "microphone", "geolocation", "notifications", "midi", "display-capture"];

const { helperSource, pageHookSource, relaySource } = scripts;

/**
 * The function of every helper call (design §3.2), by Runtime.callFunctionOn
 * in the helper's world: AgentScripts.helperFunction when the Swift source
 * has it, else the same text.
 */
export const HELPER_FUNCTION = scripts.helperFunctionSource?.().trim()
  ?? "async function(op, args) { return globalThis.__loomAgent ? await globalThis.__loomAgent.run(op, args) : JSON.stringify({ error: { code: \"helperMissing\", message: \"the helper is not loaded\" } }); }";

/**
 * Chromium's answers to a call whose document went away — what the engine
 * reads as "navigated" (SettleMachine's barrierLost):
 * - "Cannot find context with specified id": sent into a document already
 *   gone (a stale world id): its failure follows Page.frameNavigated;
 * - "Execution context was destroyed.": pending when the document went: on a
 *   same-site navigation its failure comes BEFORE Page.frameNavigated (the
 *   renderer tears the old document down before it reports the commit);
 * - "Promise was collected": the same, for an awaited promise the teardown
 *   garbage-collected first (a promise nothing else holds).
 */
export const DOCUMENT_GONE = /Cannot find context with specified id|Execution context was destroyed|Promise was collected/;
/** Of those, the one whose call never ran in the old document: its commit is on the wire first. */
export const SENT_AFTER_COMMIT = /Cannot find context with specified id/;

/**
 * The settle barrier (design §4): one task of the page's event loop. Every
 * DevTools event a click causes synchronously, in a microtask or in a
 * setTimeout(0) is on the pipe before its reply (settle.test.mjs).
 */
export const BARRIER_FUNCTION = "async function() { await new Promise((resolve) => setTimeout(resolve, 0)); return JSON.stringify({ url: location.href, visibility: document.visibilityState }); }";

/**
 * The relay's binding channel, for an AgentScripts.relay without its own
 * (before Chromium support landed in it): it stands where WebKit's message
 * handler stands, so the relay is still the one Loom ships. A message posted before the binding exists (document start: the
 * binding is re-added only once Loom sees the commit) waits here, and goes
 * with the next post or a retry 15 ms later — at most 3 s, 500 messages.
 */
export const BINDING_CHANNEL = `(() => {
"use strict";
if (globalThis.webkit && globalThis.webkit.messageHandlers) return;
const waiting = [];
let timer = 0;
let tries = 0;
function flush() {
  const binding = globalThis.${BINDING};
  if (typeof binding !== "function") return false;
  while (waiting.length) binding(waiting.shift());
  return true;
}
function retry() {
  timer = 0;
  if (!flush() && waiting.length && ++tries < 200) timer = setTimeout(retry, 15);
}
const loomAgent = {
  postMessage(message) {
    waiting.push(JSON.stringify(message));
    if (waiting.length > 500) waiting.shift();
    if (!flush() && !timer) timer = setTimeout(retry, 15);
  },
};
Object.defineProperty(globalThis, "webkit", { value: Object.freeze({ messageHandlers: Object.freeze({ loomAgent }) }) });
})();`;

/** The relay Loom injects, with the binding channel in front when it has none of its own. */
export function relayScript() {
  const relay = relaySource();
  return relay.includes(BINDING) ? relay : BINDING_CHANNEL + "\n" + relay;
}

/** The helper, top frame only (as AgentBrowser.swift installs it). */
export const helperTopFrameScript = () => "if (window === window.top) {\n" + helperSource() + "\n}";

/** A Mac's user agent with the running major version, and its client hints: no "Headless" anywhere. */
export function userAgentOverride({ major, fullVersion }) {
  return {
    userAgent: `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}.0.0.0 Safari/537.36`,
    acceptLanguage: "en-US,en",
    platform: "MacIntel",
    // Without the metadata, navigator.userAgentData.brands is empty.
    userAgentMetadata: {
      brands: [{ brand: "Chromium", version: String(major) }, { brand: "Not?A_Brand", version: "24" }],
      fullVersionList: [{ brand: "Chromium", version: String(fullVersion) }, { brand: "Not?A_Brand", version: "24.0.0.0" }],
      platform: "macOS",
      platformVersion: "15.0.0",
      architecture: "arm",
      model: "",
      mobile: false,
      bitness: "64",
      wow64: false,
    },
  };
}

export const deviceMetrics = ({ width, height }) =>
  ({ width, height, deviceScaleFactor: 1, mobile: false, screenWidth: width, screenHeight: height });

/** On every Page.frameNavigated, in one write: the world made sure of, then the binding into it. */
export function rebindCommands(frameId) {
  return [
    ["Page.createIsolatedWorld", { frameId, worldName: WORLD, grantUniveralAccess: false }],
    ["Runtime.addBinding", { name: BINDING, executionContextName: WORLD }],
  ];
}

/** The browser session's setup, in one write (design §2.4). */
export function browserSetup() {
  return [
    ["Target.setDiscoverTargets", { discover: true, filter: [{ type: "page" }] }],
    ["Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true, filter: [{ type: "page" }] }],
    ["Browser.setDownloadBehavior", { behavior: "deny", eventsEnabled: true }],
    // "display-capture", not "displayCapture": the camel-case name is refused.
    ...DENIED_PERMISSIONS.map((name) => ["Browser.setPermission", { permission: { name }, setting: "denied" }]),
  ];
}

/** A tab's init burst, in one write while it waits for the debugger (design §3.1). */
export function targetInit({ relay, pageHook, helper, userAgent, viewport = VIEWPORT, focusEmulation = true }) {
  return [
    ["Page.enable", {}],
    ["Page.setLifecycleEventsEnabled", { enabled: true }],
    ["Network.enable", { maxTotalBufferSize: 0, maxResourceBufferSize: 0, maxPostDataSize: 0 }],
    ["Page.addScriptToEvaluateOnNewDocument", { source: relay, worldName: WORLD, runImmediately: true }],
    ["Page.addScriptToEvaluateOnNewDocument", { source: pageHook, runImmediately: true }],
    ["Page.addScriptToEvaluateOnNewDocument", { source: helper, worldName: WORLD, runImmediately: true }],
    ["Runtime.addBinding", { name: BINDING, executionContextName: WORLD }],
    ["Page.setInterceptFileChooserDialog", { enabled: true }],
    ["Emulation.setDeviceMetricsOverride", deviceMetrics(viewport)],
    ...(focusEmulation ? [["Emulation.setFocusEmulationEnabled", { enabled: true }]] : []),
    ["Emulation.setUserAgentOverride", userAgent],
    ["Page.setWebLifecycleState", { state: "active" }],
    // No filter: a target this pauses but does not attach would never start —
    // with [{type:"iframe"}], dedicated and service workers hang forever. Every
    // related target attaches paused (an out-of-process iframe, to get its own
    // init); the router resumes the rest.
    ["Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }],
    ["Runtime.runIfWaitingForDebugger", {}],
  ];
}

/** fixtures/init.json: every sequence above, the scripts and versions as placeholders. */
export function initDocument() {
  return {
    $comment: [
      "The CDP sequences of Loom's Chromium engine, produced by Tests/AgentBrowserCDP/lib/init.mjs and checked",
      "against Chromium by target-init.test.mjs. Placeholders: {relay} = AgentScripts.relay (with the binding",
      "channel), {pageHook} = AgentScripts.pageHook, {helperTopFrame} = 'if (window === window.top) {\\n' +",
      "AgentScripts.helper + '\\n}', {major}/{fullVersion} from Browser.getVersion's product.",
    ],
    browser: browserSetup(),
    createTarget: ["Target.createTarget", { url: "about:blank", newWindow: true }],
    target: targetInit({
      relay: "{relay}", pageHook: "{pageHook}", helper: "{helperTopFrame}",
      userAgent: userAgentOverride({ major: "{major}", fullVersion: "{fullVersion}" }),
    }),
    // In one write, for every frame; for the main frame, the first reply is the helper's world id.
    onFrameNavigated: rebindCommands("{frameId}"),
    helperCall: ["Runtime.callFunctionOn", {
      functionDeclaration: HELPER_FUNCTION, executionContextId: "{world}",
      arguments: [{ value: "{op}" }, { value: "{argsJSON}" }], returnByValue: true, awaitPromise: true, silent: true,
    }],
    barrier: ["Runtime.callFunctionOn", {
      functionDeclaration: BARRIER_FUNCTION, executionContextId: "{world}", returnByValue: true, awaitPromise: true, silent: true,
    }],
    click: mouseClick("{x}", "{y}"),
    stuckProbe: ["Runtime.evaluate", { expression: "1", returnByValue: true }],
  };
}

export const renderInitDocument = () => JSON.stringify(initDocument(), null, 2) + "\n";
export function readInitFixture() {
  try { return readFileSync(initFixture, "utf8"); } catch { return null; }
}
export const writeInitFixture = () => writeFileSync(initFixture, renderInitDocument());

// ---------------------------------------------------------------------------
// The browser's router

/**
 * Sends the browser setup and routes every target that attaches paused:
 * ours (a Target.createTarget in flight, no opener) wait for openTab's init;
 * any other — a popup, an out-of-process iframe, a worker, a service worker —
 * is resumed at once. A popup left paused blocks its opener's window.open,
 * and with it the click or evaluate that called it; a worker left paused
 * never runs.
 */
export async function prepareBrowser(browser) {
  if (browser.router) return browser.router;
  const router = { creating: 0, claimed: new Map(), resumed: [] };
  browser.router = router;
  browser.conn.on("*", (message) => {
    if (message.method !== "Target.attachedToTarget" || !message.params.waitingForDebugger) return;
    const { sessionId, targetInfo } = message.params;
    if (!message.sessionId && targetInfo.type === "page" && !targetInfo.openerId && router.creating > 0) {
      router.creating--;
      router.claimed.set(targetInfo.targetId, message.params);
      browser.conn.emit(`claimed:${targetInfo.targetId}`, message.params);
      return;
    }
    router.resumed.push(targetInfo);
    browser.conn.send("Runtime.runIfWaitingForDebugger", {}, sessionId);
  });
  const outcomes = await Promise.all(browser.conn.sendBatch(browserSetup()).map(settle));
  router.setupErrors = outcomes.filter((outcome) => !outcome.ok).map((outcome) => outcome.error.message);
  return router;
}

function claim(browser, targetId, timeout) {
  const known = browser.router.claimed.get(targetId);
  if (known) return Promise.resolve(known);
  return withTimeout(new Promise((resolve) => browser.conn.once(`claimed:${targetId}`, resolve)), timeout, `attachedToTarget for ${targetId}`);
}

// ---------------------------------------------------------------------------
// A tab

export class Tab {
  constructor(browser, session) {
    this.browser = browser;
    this.session = session;
    this.targetId = session.targetId;
    this.frameId = null;
    this.loaderId = null;
    this.url = "about:blank";
    this.worldId = null;
    this.bindings = [];
    this.rebinds = 0;
    session.on("Runtime.bindingCalled", ({ name, payload, executionContextId }) => {
      let message = payload;
      try { message = JSON.parse(payload); } catch { /* kept as sent */ }
      this.bindings.push({ name, payload, message, executionContextId });
    });
    session.on("Page.frameNavigated", ({ frame }) => {
      // A new document, a new world: its id may even be the old one's number in
      // a new renderer process, so the cached id goes, never a lookup.
      let world = null;
      if (this.rebind) {
        this.rebinds++;
        const [created] = session.sendBatch(rebindCommands(frame.id));
        world = created.then((reply) => reply.executionContextId);
        world.catch(() => {});
      }
      if (!frame.parentId) {
        this.worldId = world;
        this.frameId = frame.id;
        this.loaderId = frame.loaderId;
        this.url = frame.url;
      }
    });
  }

  get conn() { return this.browser.conn; }

  /** The helper's world in the current main-frame document (prefetched at its commit). */
  async world() {
    if (this.worldId !== null) {
      try { return await this.worldId; } catch { /* the frame went: ask again */ }
    }
    const pending = this.session.send("Page.createIsolatedWorld", { frameId: this.frameId, worldName: WORLD, grantUniveralAccess: false })
      .then((reply) => reply.executionContextId);
    this.worldId = pending;
    return pending;
  }

  /** A function in the helper's world; throws on a JavaScript exception. */
  async call(functionDeclaration, args = [], { contextId } = {}) {
    const executionContextId = contextId ?? await this.world();
    const { result, exceptionDetails } = await this.session.send("Runtime.callFunctionOn", {
      functionDeclaration, executionContextId, arguments: args.map((value) => ({ value })),
      returnByValue: true, awaitPromise: true, silent: true,
    });
    if (exceptionDetails) throw new Error(`callFunctionOn: ${exceptionDetails.exception?.description || exceptionDetails.text}`);
    return result.value;
  }

  /** One helper op, answered as the helper answers (parsed JSON). */
  async helper(op, args = {}) {
    return JSON.parse(await this.call(HELPER_FUNCTION, [op, JSON.stringify(args)]));
  }

  barrier() {
    return this.call(BARRIER_FUNCTION).then(JSON.parse);
  }

  /** An expression in the page's world (or the helper's, with `world: true`). */
  async evaluate(expression, { world = false, awaitPromise = true, userGesture = false } = {}) {
    const params = { expression, returnByValue: true, awaitPromise };
    if (world) params.contextId = await this.world();
    if (userGesture) params.userGesture = true;
    const { result, exceptionDetails } = await this.session.send("Runtime.evaluate", params);
    if (exceptionDetails) throw new Error(`evaluate: ${exceptionDetails.exception?.description || exceptionDetails.text}`);
    return result.value;
  }

  /**
   * Page.navigate, then the load lifecycle event of the new document's
   * loader (none for a same-document navigation). Resolves the reply.
   */
  async navigate(url, { timeout = 20_000, waitForLoad = true } = {}) {
    const loads = this.session.collect("Page.lifecycleEvent");
    try {
      const reply = await this.session.send("Page.navigate", { url, transitionType: "typed" });
      if (reply.errorText || !reply.loaderId || !waitForLoad) return reply;
      const isLoad = (event) => event.name === "load" && event.loaderId === reply.loaderId;
      if (!loads.some(isLoad)) await this.session.waitForEvent("Page.lifecycleEvent", { predicate: isLoad, timeout });
      return reply;
    } finally {
      loads.stop();
    }
  }

  /** The centre of the first `selector` match, scrolled into view, in viewport CSS px. */
  async centerOf(selector) {
    return this.call(`function(selector) {
      const element = document.querySelector(selector);
      if (!element) throw new Error("no element " + selector);
      let r = element.getBoundingClientRect();
      if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) {
        element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        r = element.getBoundingClientRect();
      }
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    }`, [selector]);
  }

  /** moved, pressed, released in ONE write: three promises. */
  click(x, y, options) {
    return this.session.sendBatch(mouseClick(x, y, options));
  }

  close() {
    return this.conn.send("Target.closeTarget", { targetId: this.targetId });
  }
}

/**
 * A new tab, initialised as Loom does it: Target.createTarget (its own
 * window), the paused attach, the init burst in one write, then the
 * navigation to `url` if one is given.
 *
 * Options: newWindow (true), viewport, focusEmulation (true), rebind (true:
 * Runtime.addBinding again on every frameNavigated).
 */
export async function openTab(browser, { url, newWindow = true, viewport = VIEWPORT, focusEmulation = true, rebind = true } = {}) {
  const router = await prepareBrowser(browser);
  const params = { url: "about:blank" };
  if (newWindow !== undefined && newWindow !== null) params.newWindow = newWindow;
  router.creating++;
  let created;
  try {
    created = await browser.conn.send("Target.createTarget", params);
  } catch (error) {
    router.creating--;
    throw error;
  }
  // The attach and the createTarget reply arrive in either order.
  const attached = await claim(browser, created.targetId, 15_000);
  router.claimed.delete(created.targetId);
  const session = browser.conn.session(attached.sessionId, created.targetId);
  const tab = new Tab(browser, session);
  tab.rebind = rebind;
  tab.attachedEvent = attached;
  const burst = targetInit({
    relay: relayScript(), pageHook: pageHookSource(), helper: helperTopFrameScript(),
    userAgent: userAgentOverride(browser), viewport, focusEmulation,
  });
  tab.initSent = burst.map(([method]) => method);
  tab.initOutcomes = await Promise.all(session.sendBatch(burst).map(settle));
  const failed = tab.initOutcomes.map((outcome, i) => outcome.ok ? null : `${burst[i][0]}: ${outcome.error.message}`).filter(Boolean);
  if (failed.length) throw new Error(`the init burst was refused: ${failed.join("; ")}`);
  const { frameTree } = await session.send("Page.getFrameTree");
  tab.frameId = frameTree.frame.id;
  tab.loaderId = frameTree.frame.loaderId;
  if (url) await tab.navigate(url);
  return tab;
}
