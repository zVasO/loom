import Foundation
import WebKit

/// The agent browser's scripts (ADR-0014). Installed ONLY in the agent's
/// own web views — the user's panes never run a line of them (WEB-07).
///
/// Kept as Swift strings rather than resources: the release script copies no
/// SwiftPM resource bundle into the app. The Node tests in
/// `Tests/AgentBrowserJS/` extract them from this file — each literal must
/// stay a `#"""` raw string, its lines at column 0.
public enum AgentScripts {

    /// The page's world, document start, every frame: console, uncaught
    /// errors and fetch/XHR, dispatched as DOM events for `relay`.
    public static let pageHook = #"""
(() => {
"use strict";
// Runs in the PAGE's world, at document start, in every frame of the agent's
// browser only (never in the user's panes — WEB-07, ADR-0014): what the page
// logs and fetches goes to Loom, so the agent can read it. The page can see
// and tamper with this hook; it is a test aid, never a guard.
const KEY = Symbol.for("loom.agent.hook");
if (window[KEY]) return;
try { Object.defineProperty(window, KEY, { value: true }); } catch (_) { return; }

// No channel to Loom in this world: messages cross to Loom's own world as
// DOM events, where the relay checks their size and rate before posting —
// a page that floods them costs its own process, never Loom's.
const EVENT = "loom-agent-hook";
function send(message) {
  try {
    document.dispatchEvent(new CustomEvent(EVENT, { detail: JSON.stringify(message) }));
  } catch (_) { /* the document is going away */ }
}

const MAX_ARG = 500;
const MAX_TEXT = 2000;

function clip(text, limit) {
  text = String(text);
  return text.length > limit ? text.slice(0, limit - 1) + "…" : text;
}

function describeNode(node) {
  if (!node || node.nodeType !== 1) return String(node && node.nodeName || node);
  let text = "<" + node.localName;
  if (node.id) text += "#" + node.id;
  if (typeof node.className === "string" && node.className.trim()) {
    text += "." + node.className.trim().split(/\s+/).slice(0, 2).join(".");
  }
  return text + ">";
}

function show(value, depth) {
  try {
    if (value === undefined) return "undefined";
    if (value === null) return "null";
    const kind = typeof value;
    if (kind === "string") return value;
    if (kind === "number" || kind === "boolean" || kind === "bigint") return String(value);
    if (kind === "symbol" || kind === "function") return String(value);
    if (value instanceof Error) {
      const stack = String(value.stack || "").split("\n").slice(0, 5).join("\n");
      return (value.name || "Error") + ": " + value.message + (stack ? "\n" + stack : "");
    }
    if (typeof Node !== "undefined" && value instanceof Node) return describeNode(value);
    const seen = new WeakSet();
    return clip(JSON.stringify(value, (key, inner) => {
      if (typeof inner === "object" && inner !== null) {
        if (seen.has(inner)) return "[Circular]";
        seen.add(inner);
        if (typeof Node !== "undefined" && inner instanceof Node) return describeNode(inner);
      }
      if (typeof inner === "bigint") return inner.toString() + "n";
      if (typeof inner === "function") return "[Function]";
      return inner;
    }) || String(value), MAX_ARG);
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
        case "d": case "i": return String(parseInt(value, 10));
        case "f": return String(parseFloat(value));
        case "c": return "";
        default: return clip(show(value), MAX_ARG);
      }
    });
  }
  for (const value of list) out += (out ? " " : "") + clip(show(value), MAX_ARG);
  return clip(out, MAX_TEXT);
}

function callerLocation() {
  try {
    const line = String(new Error().stack || "").split("\n")
      .find((entry) => entry && !/console|format|loom/i.test(entry) && /:\d+/.test(entry));
    if (!line) return "";
    const match = /((?:https?|file|blob):\/\/[^\s)]+?:\d+)(?::\d+)?\)?$/.exec(line.trim());
    return match ? clip(match[1], 300) : "";
  } catch (_) {
    return "";
  }
}

const LEVELS = { log: "info", info: "info", warn: "warning", error: "error", debug: "debug" };
for (const name of Object.keys(LEVELS)) {
  const original = console[name];
  if (typeof original !== "function") continue;
  console[name] = function () {
    try { send({ t: "console", level: LEVELS[name], text: format(arguments), loc: callerLocation() }); } catch (_) {}
    return Reflect.apply(original, this, arguments);
  };
}

window.addEventListener("error", (event) => {
  try {
    const target = event.target;
    if (target && target !== window && target.nodeType === 1) {
      const url = target.currentSrc || target.src || target.href || "";
      send({ t: "console", level: "error", text: clip("Failed to load resource: " + url, MAX_TEXT), loc: "" });
      return;
    }
    const where = event.filename ? clip(event.filename + ":" + event.lineno, 300) : "";
    const text = event.error ? show(event.error) : String(event.message || "Script error");
    send({ t: "console", level: "error", text: clip(text, MAX_TEXT), loc: where });
  } catch (_) {}
}, true);

window.addEventListener("unhandledrejection", (event) => {
  try {
    send({ t: "console", level: "error", text: clip("Unhandled promise rejection: " + show(event.reason), MAX_TEXT), loc: "" });
  } catch (_) {}
});

// Ids unique per document: Loom keys requests by frame origin and id, and
// sibling frames of one origin (or opaque ones) share a key prefix.
let sequence = Math.floor(Math.random() * 2 ** 19) * 2 ** 20;
const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());

// What this document has in flight: a frame that goes away (reloaded,
// removed) leaves nothing pending in Loom's log.
const pending = new Set();
function started(message) {
  pending.add(message.id);
  send(message);
}
function ended(message) {
  if (!pending.delete(message.id)) return;
  send(message);
}
window.addEventListener("pagehide", () => {
  for (const id of pending) send({ t: "res", id, error: "abandoned by navigation", ms: 0 });
  pending.clear();
});

const originalFetch = window.fetch;
if (typeof originalFetch === "function") {
  window.fetch = function (input, init) {
    const id = ++sequence;
    let method = "GET";
    let url = "";
    try {
      method = String((init && init.method) || (input && typeof input === "object" && input.method) || "GET").toUpperCase();
      url = String(input && typeof input === "object" && "url" in input ? input.url : input);
      url = new URL(url, document.baseURI).href;
    } catch (_) {}
    started({ t: "req", id, kind: "fetch", method, url: clip(url, MAX_ARG) });
    const begun = now();
    let promise;
    try {
      promise = Reflect.apply(originalFetch, this, arguments);
    } catch (error) {
      ended({ t: "res", id, error: clip(String(error && error.message || error), 300), ms: 0 });
      throw error;
    }
    promise.then(
      (response) => ended({ t: "res", id, status: response.status, ms: Math.round(now() - begun) }),
      (error) => ended({ t: "res", id, error: clip(String(error && error.message || error), 300), ms: Math.round(now() - begun) }));
    return promise;
  };
}

const requests = new WeakMap();
const XHR = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
if (XHR) {
  const open = XHR.open;
  const sendRequest = XHR.send;
  XHR.open = function (method, url) {
    try {
      requests.set(this, { method: String(method || "GET").toUpperCase(), url: new URL(String(url), document.baseURI).href });
    } catch (_) {}
    return Reflect.apply(open, this, arguments);
  };
  XHR.send = function () {
    const info = requests.get(this);
    if (info) {
      const id = ++sequence;
      const begun = now();
      started({ t: "req", id, kind: "xhr", method: info.method, url: clip(info.url, MAX_ARG) });
      this.addEventListener("loadend", () => {
        const failed = this.status === 0;
        ended(failed ? { t: "res", id, error: "network error", ms: Math.round(now() - begun) }
                     : { t: "res", id, status: this.status, ms: Math.round(now() - begun) });
      });
    }
    return Reflect.apply(sendRequest, this, arguments);
  };
}
})();
"""#

    /// Loom's world, document start, every frame: the page hook's events,
    /// checked for size and rate, posted to `messageHandlerName` — a handler
    /// that exists in Loom's world only. Without it (Chromium, ADR-0015) they
    /// go to the `__loomHookBinding` binding Loom adds to that world after
    /// each commit, held until it is there; requests are not relayed then:
    /// the Network domain sees them.
    public static let relay = #"""
(() => {
"use strict";
// Loom's own world, document start, every frame: the only path from the page
// hook to Loom. The message handler exists in this world alone — a page
// cannot post to it, only dispatch events this relay reads: strings of at
// most 4 KB, JSON objects only, 200 a second from the page and its own
// frames, 20 from each frame of another origin (an ad, a widget) — the rest
// counted. Loom cuts the channel of a page that multiplies its frames to
// flood anyway.
// A response passes when its request did, so a chatty page never leaves one
// pending.
// Chromium has no message handler: Loom adds a binding to this world, but
// only to the documents that exist when it does — after each commit, so
// maybe after this script ran. What is admitted meanwhile waits here (200 at
// most, the rest counted) and goes with the next post, or a retry 15 ms
// later for 3 s. Requests are not relayed there: Loom's Network domain sees
// them.
if (globalThis.__loomAgentRelay) return;
globalThis.__loomAgentRelay = true;
const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
const channel = handlers && handlers.loomAgent;
// WebKit whose channel a flood cut (window.webkit goes with its last
// handler): silent, as it always was.
if (!channel && /^Apple/.test(String(navigator.vendor || ""))) return;
const BINDING = "__loomHookBinding";

const EVENT = "loom-agent-hook";
const MAX_DETAIL = 4096;
const MAX_ADMITTED = 2000;
const MAX_WAITING = 200;
const RETRY_MS = 15;
const MAX_RETRIES = 200;
let sameOrigin = true;
try { void window.top.location.href; } catch (_) { sameOrigin = false; }
const RATE = sameOrigin ? 200 : 20;
let tokens = RATE;
let refilled = Date.now();
let dropped = 0;
const admitted = new Set();

// Binding mode only: what waits for the binding, and what did not fit.
const waiting = [];
let overflow = 0;
let retryTimer = 0;
let retries = 0;

/** Sends what waits, in order, once the binding is there; false while it is not. */
function flush() {
  const binding = globalThis[BINDING];
  if (typeof binding !== "function") {
    if (!retryTimer && retries < MAX_RETRIES && (waiting.length || overflow)) {
      retryTimer = setTimeout(() => { retryTimer = 0; retries++; flush(); }, RETRY_MS);
    }
    return false;
  }
  retries = 0;
  try {
    while (waiting.length) {
      binding(JSON.stringify(waiting[0]));
      waiting.shift();
    }
    if (overflow) {
      binding(JSON.stringify({ t: "dropped", n: overflow }));
      overflow = 0;
    }
  } catch (_) { /* the binding was cut: what is left waits */ }
  return true;
}

function post(message) {
  if (channel) {
    try { channel.postMessage(message); } catch (_) { /* the frame is going away */ }
    return;
  }
  if (waiting.length >= MAX_WAITING) flush();
  if (waiting.length >= MAX_WAITING) { overflow++; return; }
  waiting.push(message);
  flush();
}

function admit() {
  const now = Date.now();
  tokens = Math.min(RATE, tokens + (now - refilled) * RATE / 1000);
  refilled = now;
  if (tokens < 1) { dropped++; return false; }
  tokens -= 1;
  if (dropped) { post({ t: "dropped", n: dropped }); dropped = 0; }
  return true;
}

document.addEventListener(EVENT, (event) => {
  const detail = event.detail;
  if (typeof detail !== "string" || detail.length > MAX_DETAIL) return;
  let message;
  try { message = JSON.parse(detail); } catch (_) { return; }
  if (!message || typeof message !== "object" || Array.isArray(message)) return;
  if (!channel && (message.t === "req" || message.t === "res")) return;
  if (message.t === "res") {
    if (admitted.delete(message.id)) post(message);
    return;
  }
  if (!admit()) return;
  if (message.t === "req") {
    if (admitted.size >= MAX_ADMITTED) admitted.delete(admitted.values().next().value);
    admitted.add(message.id);
  }
  post(message);
}, true);
})();
"""#

    /// Loom's own content world (`worldName`), document start, main frame:
    /// the accessibility snapshot with its refs, actionability, input.
    public static let helper = #"""
(() => {
"use strict";
if (globalThis.__loomAgent) return;

// Runs in Loom's own content world ("loom-agent"): the page cannot see these
// globals, but the DOM is shared. Only DOM state crosses worlds — values,
// attributes, events — never an expando: a property set here on an element
// or an event is invisible to the page's scripts.

const VERSION = 1;
const REF_RE = /^(f\d+)?e\d+$/;

const LIMITS = { text: 200, name: 100, list: 50 };

// ---------------------------------------------------------------- pure

function collapse(text) {
  return String(text == null ? "" : text).replace(/\s+/g, " ").trim();
}

function truncate(text, limit) {
  return text.length > limit ? text.slice(0, Math.max(0, limit - 1)) + "…" : text;
}

const YAML_KEYWORDS = /^(true|false|null|yes|no|on|off|~|-?\d+(\.\d+)?([eE][-+]?\d+)?)$/i;

/** A YAML scalar as Playwright prints it: plain when safe, JSON-quoted otherwise. */
function yamlScalar(text) {
  const value = String(text);
  if (value === "") return '""';
  const unsafe = /^[\s\-?:,\[\]{}#&*!|>'"%@`]/.test(value)
    || /\s$/.test(value)
    || /: |:$| #/.test(value)
    || /[\u0000-\u001f\u007f]/.test(value)
    || YAML_KEYWORDS.test(value);
  return unsafe ? JSON.stringify(value) : value;
}

/** `- role "name" [attr]…` — attributes in Playwright's order. */
function nodeHead(node) {
  let head = node.role;
  if (node.name) head += " " + JSON.stringify(node.name);
  const a = node.attrs || {};
  if (a.checked === "mixed") head += " [checked=mixed]";
  else if (a.checked) head += " [checked]";
  if (a.disabled) head += " [disabled]";
  if (a.expanded === true) head += " [expanded]";
  else if (a.expanded === false) head += " [expanded=false]";
  if (a.active) head += " [active]";
  if (a.level) head += " [level=" + a.level + "]";
  if (a.pressed === "mixed") head += " [pressed=mixed]";
  else if (a.pressed) head += " [pressed]";
  if (a.selected) head += " [selected]";
  if (node.ref) head += " [ref=" + node.ref + "]";
  if (a.cursorPointer) head += " [cursor=pointer]";
  return head;
}

/**
 * The tree as YAML lines, within a character budget. Returns the text, the
 * refs actually printed (only those resolve afterwards), and whether the
 * budget or the depth cut anything.
 */
function renderTree(nodes, options) {
  const budget = options && options.budget ? options.budget : Infinity;
  const maxDepth = options && options.depth != null ? options.depth : Infinity;
  const lines = [];
  const printed = [];
  let used = 0;
  let truncated = false;
  let depthCut = false;

  function push(line) {
    if (truncated) return false;
    if (used + line.length + 1 > budget) {
      truncated = true;
      return false;
    }
    lines.push(line);
    used += line.length + 1;
    return true;
  }

  function render(item, indent, depth) {
    if (truncated) return;
    if (typeof item === "string") {
      push(indent + "- text: " + yamlScalar(item));
      return;
    }
    const children = item.children || [];
    const props = [];
    if (item.url != null) props.push("/url: " + yamlScalar(item.url));
    if (item.placeholder) props.push("/placeholder: " + yamlScalar(item.placeholder));
    let line = indent + "- " + nodeHead(item);
    const onlyText = children.length === 1 && typeof children[0] === "string" && props.length === 0;
    if (item.value != null && item.value !== "" && children.length === 0 && props.length === 0) {
      line += ": " + yamlScalar(item.value);
    } else if (onlyText) {
      line += ": " + yamlScalar(children[0]);
    } else if (children.length || props.length) {
      line += ":";
    }
    if (!push(line)) return;
    if (item.ref) printed.push(item.ref);
    if (onlyText || (!children.length && !props.length)) return;
    const inner = indent + "  ";
    for (const prop of props) {
      if (!push(inner + "- " + prop)) return;
    }
    if (depth + 1 > maxDepth) {
      if (children.length) {
        depthCut = true;
        push(inner + "- …");
      }
      return;
    }
    let shown = 0;
    for (const child of children) {
      if (truncated) return;
      render(child, inner, depth + 1);
      shown++;
    }
  }

  for (const node of nodes) render(node, "", 0);
  let text = lines.join("\n");
  if (truncated) {
    text += (text ? "\n" : "") + "- … (snapshot truncated at " + used
      + " characters: pass a target or a depth to see the rest)";
  }
  return { text, printed, truncated, depthCut };
}

// ---------------------------------------------------------------- DOM: roles and names

const INPUT_ROLES = {
  button: "button", submit: "button", reset: "button", image: "button", file: "button", color: "button",
  checkbox: "checkbox", radio: "radio", range: "slider", number: "spinbutton", search: "searchbox",
};

const KNOWN_ROLES = new Set(("alert alertdialog application article banner blockquote button caption cell checkbox "
  + "code columnheader combobox complementary contentinfo definition deletion dialog directory document "
  + "emphasis feed figure form generic grid gridcell group heading img insertion link list listbox listitem "
  + "log main marquee math meter menu menubar menuitem menuitemcheckbox menuitemradio navigation none note "
  + "option paragraph presentation progressbar radio radiogroup region row rowgroup rowheader scrollbar "
  + "search searchbox separator slider spinbutton status strong subscript superscript switch tab table "
  + "tablist tabpanel term textbox time timer toolbar tooltip tree treegrid treeitem").split(" "));

const NAME_FROM_CONTENT = new Set(["button", "cell", "checkbox", "columnheader", "gridcell", "heading", "link",
  "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "row", "rowheader", "switch", "tab",
  "tooltip", "treeitem"]);

const INTERACTIVE_SELECTOR = "a[href], button, input, select, textarea, iframe, img, summary, [role], "
  + "[tabindex], [contenteditable=''], [contenteditable='true'], [onclick]";

const INTERACTIVE_ROLES = new Set(["button", "checkbox", "combobox", "link", "listbox", "menuitem",
  "menuitemcheckbox", "menuitemradio", "option", "radio", "searchbox", "slider", "spinbutton", "switch",
  "tab", "textbox", "treeitem"]);

function styleOf(el) {
  const view = el.ownerDocument && el.ownerDocument.defaultView;
  return view ? view.getComputedStyle(el) : null;
}

function insideSectioning(el) {
  for (let p = el.parentElement; p; p = p.parentElement) {
    if (/^(article|aside|main|nav|section)$/.test(p.localName)) return true;
  }
  return false;
}

function implicitRole(el) {
  const tag = el.localName;
  switch (tag) {
    case "a": case "area": return el.hasAttribute("href") ? "link" : null;
    case "button": case "summary": return "button";
    case "input": {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (type === "hidden") return null;
      if (el.hasAttribute("list") && /^(text|search|email|tel|url)$/.test(type)) return "combobox";
      return INPUT_ROLES[type] || "textbox";
    }
    case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
    case "textarea": return "textbox";
    case "option": return "option";
    case "img": return el.getAttribute("alt") === "" ? null : "img";
    case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
    case "nav": return "navigation";
    case "main": return "main";
    case "aside": return "complementary";
    case "header": return insideSectioning(el) ? null : "banner";
    case "footer": return insideSectioning(el) ? null : "contentinfo";
    case "form": return accessibleNameRaw(el, "form") ? "form" : null;
    case "section": return accessibleNameRaw(el, "region") ? "region" : null;
    case "article": return "article";
    case "ul": case "ol": case "menu": return "list";
    case "li": return "listitem";
    case "table": return "table";
    case "tr": return "row";
    case "td": return "cell";
    case "th": return el.getAttribute("scope") === "row" ? "rowheader" : "columnheader";
    case "thead": case "tbody": case "tfoot": return "rowgroup";
    case "dialog": return "dialog";
    case "details": case "fieldset": return "group";
    case "progress": return "progressbar";
    case "meter": return "meter";
    case "hr": return "separator";
    case "p": return "paragraph";
    case "blockquote": return "blockquote";
    case "iframe": return "iframe";
    case "figure": return "figure";
    default: return null;
  }
}

function roleOf(el) {
  const explicit = (el.getAttribute("role") || "").trim().toLowerCase().split(/\s+/)
    .find((token) => KNOWN_ROLES.has(token));
  if (explicit) return explicit === "none" || explicit === "presentation" ? null : explicit;
  if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return "textbox";
  return implicitRole(el);
}

function isHiddenForNames(el) {
  if (el.getAttribute && el.getAttribute("aria-hidden") === "true") return true;
  const style = styleOf(el);
  return !!style && (style.display === "none" || style.visibility === "hidden");
}

/** The text a subtree shows: text nodes, alt text, nothing hidden. */
function contentText(el, exclude) {
  let out = "";
  for (const child of el.childNodes) {
    if (child.nodeType === 3) {
      out += child.data;
    } else if (child.nodeType === 1) {
      if (child === exclude || isHiddenForNames(child)) continue;
      const tag = child.localName;
      if (tag === "script" || tag === "style" || tag === "template" || tag === "noscript") continue;
      if (tag === "img") { out += " " + (child.getAttribute("alt") || "") + " "; continue; }
      if (tag === "input" || tag === "select" || tag === "textarea") continue;
      const label = child.getAttribute("aria-label");
      out += " " + (label ? label : contentText(child, exclude)) + " ";
    }
  }
  return out;
}

function labelledByText(el) {
  const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
  if (!ids.length) return "";
  const doc = el.ownerDocument;
  return collapse(ids.map((id) => doc.getElementById(id)).filter(Boolean)
    .map((target) => target.getAttribute("aria-label") || contentText(target)).join(" "));
}

function accessibleNameRaw(el, role) {
  const byIds = labelledByText(el);
  if (byIds) return byIds;
  const aria = collapse(el.getAttribute("aria-label"));
  if (aria) return aria;
  const tag = el.localName;
  if (tag === "input") {
    const type = (el.getAttribute("type") || "text").toLowerCase();
    if (type === "button" || type === "submit" || type === "reset") {
      return collapse(el.value) || (type === "submit" ? "Submit" : type === "reset" ? "Reset" : "");
    }
    if (type === "image") return collapse(el.getAttribute("alt")) || "Submit";
  }
  if (tag === "input" || tag === "select" || tag === "textarea" || tag === "meter" || tag === "progress"
      || tag === "button") {
    const labels = el.labels ? Array.from(el.labels) : [];
    const text = collapse(labels.map((label) => contentText(label, el)).join(" "));
    if (text) return text;
  }
  if (tag === "img" || tag === "area") {
    const alt = collapse(el.getAttribute("alt"));
    if (alt) return alt;
  }
  if (tag === "fieldset") {
    const legend = el.querySelector(":scope > legend");
    if (legend) return collapse(contentText(legend));
  }
  if (tag === "table") {
    const caption = el.querySelector(":scope > caption");
    if (caption) return collapse(contentText(caption));
  }
  if (tag === "figure") {
    const caption = el.querySelector(":scope > figcaption");
    if (caption) return collapse(contentText(caption));
  }
  if (tag === "svg") {
    const title = el.querySelector(":scope > title");
    if (title) return collapse(title.textContent);
  }
  if (role && NAME_FROM_CONTENT.has(role)) {
    const text = collapse(contentText(el));
    if (text) return text;
  }
  const title = collapse(el.getAttribute("title"));
  if (title) return title;
  if (tag === "input" || tag === "textarea") return collapse(el.getAttribute("placeholder"));
  return "";
}

function accessibleName(el, role) {
  return truncate(accessibleNameRaw(el, role), LIMITS.name);
}

// ---------------------------------------------------------------- DOM: state

function isVisible(el) {
  if (typeof el.checkVisibility === "function") {
    if (!el.checkVisibility({ checkVisibilityCSS: true, visibilityProperty: true, checkOpacity: false })) {
      return false;
    }
  } else {
    const style = styleOf(el);
    if (!style || style.visibility !== "visible" || style.display === "none") return false;
  }
  const rect = el.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function isDisabled(el) {
  try {
    if (el.matches(":disabled")) return true;
  } catch (_) { /* not a form element */ }
  for (let node = el; node; node = node.parentElement) {
    if (node.getAttribute && node.getAttribute("aria-disabled") === "true") return true;
  }
  return false;
}

function deepActiveElement(doc) {
  let active = (doc || document).activeElement;
  for (;;) {
    if (!active) return null;
    if (active.shadowRoot && active.shadowRoot.activeElement) { active = active.shadowRoot.activeElement; continue; }
    if (active.localName === "iframe") {
      let inner = null;
      try { inner = active.contentDocument; } catch (_) { inner = null; }
      if (inner && inner.activeElement && inner.activeElement !== inner.body) { active = inner.activeElement; continue; }
    }
    return active;
  }
}

function isEditable(el) {
  if (!el) return false;
  if (el.isContentEditable) return true;
  if (el.localName === "textarea") return !el.readOnly && !el.disabled;
  if (el.localName === "input") {
    const type = (el.getAttribute("type") || "text").toLowerCase();
    const textual = /^(text|search|email|tel|url|password|number|date|datetime-local|month|time|week)$/.test(type);
    return textual && !el.readOnly && !el.disabled;
  }
  return false;
}

function stateAttrs(el, role, active) {
  const attrs = {};
  const tag = el.localName;
  if (role === "checkbox" || role === "radio" || role === "switch" || role === "menuitemcheckbox"
      || role === "menuitemradio") {
    if (tag === "input") attrs.checked = el.indeterminate ? "mixed" : el.checked;
    else {
      const value = el.getAttribute("aria-checked");
      attrs.checked = value === "mixed" ? "mixed" : value === "true";
    }
  }
  if (INTERACTIVE_ROLES.has(role) && isDisabled(el)) attrs.disabled = true;
  const expanded = el.getAttribute("aria-expanded");
  if (expanded === "true") attrs.expanded = true;
  else if (expanded === "false") attrs.expanded = false;
  else if (tag === "details") attrs.expanded = el.open;
  if (el === active) attrs.active = true;
  if (role === "heading") {
    const level = Number(el.getAttribute("aria-level")) || Number((/^h([1-6])$/.exec(tag) || [])[1]) || 0;
    if (level) attrs.level = level;
  }
  const pressed = el.getAttribute("aria-pressed");
  if (pressed === "true") attrs.pressed = true;
  else if (pressed === "mixed") attrs.pressed = "mixed";
  if (tag === "option" ? el.selected : el.getAttribute("aria-selected") === "true") attrs.selected = true;
  return attrs;
}

function describe(el) {
  if (!el || el.nodeType !== 1) return "nothing";
  const role = roleOf(el);
  const name = role ? accessibleName(el, role) : "";
  if (role) return name ? role + " " + JSON.stringify(name) : role;
  let text = "<" + el.localName;
  if (el.id) text += "#" + el.id;
  const classes = typeof el.className === "string" ? el.className.trim().split(/\s+/).filter(Boolean) : [];
  if (classes.length) text += "." + classes.slice(0, 2).join(".");
  return text + ">";
}

// ---------------------------------------------------------------- snapshot

let refCounter = 0;
/** element → {role, name, ref}: a ref stays the same while role and name do. */
let refCache = new WeakMap();
/** The refs the last printed snapshot showed — the only ones that resolve. */
let latest = new Map();

function refFor(el, role, name) {
  const cached = refCache.get(el);
  if (cached && cached.role === role && cached.name === name) return cached.ref;
  const ref = "e" + (++refCounter);
  refCache.set(el, { role, name, ref });
  return ref;
}

function childNodesOf(el) {
  if (el.shadowRoot) return Array.from(el.shadowRoot.childNodes);
  if (el.localName === "slot" && typeof el.assignedNodes === "function") {
    const assigned = el.assignedNodes({ flatten: true });
    if (assigned.length) return assigned;
  }
  return Array.from(el.childNodes);
}

const SKIPPED_TAGS = new Set(["script", "style", "template", "noscript", "head", "meta", "link", "title"]);

function buildNodes(el, ctx) {
  // Returns the node(s) `el` contributes to its parent: an element node, or
  // its children spliced in when it carries no role (a plain container).
  if (SKIPPED_TAGS.has(el.localName)) return [];
  if (el.getAttribute("aria-hidden") === "true" || el.hasAttribute("hidden") && !el.shadowRoot) return [];
  if (el.hasAttribute("inert")) return [];
  const style = styleOf(el);
  if (!style || style.display === "none") return [];
  const contents = style.display === "contents";
  const visible = contents || isVisible(el);
  if (!visible && style.visibility !== "hidden" && !contents) {
    // Collapsed to nothing (zero size): children may still overflow visibly.
    const rects = el.getClientRects();
    if (!rects.length && style.overflow !== "visible") return [];
  }

  const role = roleOf(el);
  const pointer = visible && !contents && style.pointerEvents !== "none";
  const cursorPointer = pointer && style.cursor === "pointer"
    && !(el.parentElement && styleOf(el.parentElement) && styleOf(el.parentElement).cursor === "pointer");
  const focusable = el.hasAttribute("tabindex") && el.tabIndex >= 0;
  const clickable = el.hasAttribute("onclick") || cursorPointer || focusable;
  const emitted = (role || clickable) && !(!visible && style.visibility === "hidden");

  // The node's own ref is minted before its children's: refs read in
  // document order, like Playwright's.
  let node = null;
  if (emitted) {
    const finalRole = role || "generic";
    const name = finalRole === "generic" ? "" : accessibleName(el, finalRole);
    node = { role: finalRole, name, children: [], attrs: stateAttrs(el, finalRole, ctx.active) };
    if (cursorPointer) node.attrs.cursorPointer = true;
    if (pointer && visible) {
      node.ref = refFor(el, finalRole, name);
      ctx.elements.set(node.ref, el);
    }
  }

  const children = [];
  if (el.localName === "iframe") {
    let doc = null;
    try { doc = el.contentDocument; } catch (_) { doc = null; }
    if (doc && doc.body) children.push(...collectChildren(doc.body, ctx));
    else children.push("(cross-origin frame, not inspectable)");
  } else {
    children.push(...collectChildren(el, ctx));
  }

  if (!node) return visible || style.visibility === "hidden" ? children : [];
  const finalRole = node.role;
  const name = node.name;
  if (finalRole === "link" && el.hasAttribute("href")) node.url = el.getAttribute("href");
  if ((el.localName === "input" || el.localName === "textarea") && role !== "checkbox" && role !== "radio"
      && role !== "button") {
    const type = (el.getAttribute("type") || "").toLowerCase();
    node.value = type === "password" ? (el.value ? "••••" : "") : truncate(collapse(el.value), LIMITS.text);
    const placeholder = collapse(el.getAttribute("placeholder"));
    if (placeholder && placeholder !== name) node.placeholder = truncate(placeholder, LIMITS.text);
  } else if (el.localName === "select" && role === "combobox") {
    const option = el.selectedOptions && el.selectedOptions[0];
    node.value = option ? truncate(collapse(option.label || option.textContent), LIMITS.text) : "";
  } else if (el.isContentEditable && finalRole === "textbox") {
    node.value = truncate(collapse(el.innerText), LIMITS.text);
    children.length = 0;
  }
  // A name read from the content is not repeated as a child.
  if (name && children.length === 1 && typeof children[0] === "string" && collapse(children[0]) === name) {
    children.length = 0;
  }
  node.children = capList(children, finalRole);
  return [node];
}

function capList(children, role) {
  if (children.length <= LIMITS.list || (role !== "list" && role !== "listbox" && role !== "table"
      && role !== "rowgroup" && role !== "menu" && role !== "tree" && role !== "grid")) {
    return children;
  }
  const kept = children.slice(0, LIMITS.list);
  kept.push("… " + (children.length - LIMITS.list) + " more");
  return kept;
}

function collectChildren(el, ctx) {
  const out = [];
  let text = "";
  const flushText = () => {
    const value = collapse(text);
    if (value) out.push(truncate(value, LIMITS.text));
    text = "";
  };
  for (const child of childNodesOf(el)) {
    if (child.nodeType === 3) {
      text += child.data;
    } else if (child.nodeType === 1) {
      const display = styleOf(child) ? styleOf(child).display : "";
      const inline = /^inline/.test(display) && !roleOf(child) && !child.shadowRoot
        && child.localName !== "img" && child.localName !== "br" && child.localName !== "iframe"
        && !child.hasAttribute("onclick") && !(child.hasAttribute("tabindex") && child.tabIndex >= 0)
        && !(styleOf(child).cursor === "pointer" && styleOf(el) && styleOf(el).cursor !== "pointer")
        // A <label> around its checkbox: the control must stay a node of its own.
        && !child.querySelector(INTERACTIVE_SELECTOR);
      if (inline && !isHiddenForNames(child)) {
        // Inline text formatting (<b>, <span>) stays part of the sentence.
        text += " " + contentText(child) + " ";
        continue;
      }
      if (child.localName === "br") { text += " "; continue; }
      flushText();
      out.push(...buildNodes(child, ctx));
    }
  }
  flushText();
  return out;
}

function snapshot(args) {
  if (args.afterFrame) return snapshotAfterFrame(args);
  const doc = document;
  let roots;
  if (args.target) {
    const resolved = resolveTarget(args.target);
    if (resolved.error) return resolved;
    roots = [resolved.element];
  } else {
    roots = [doc.body || doc.documentElement];
  }
  const ctx = { active: deepActiveElement(doc), elements: new Map() };
  const nodes = [];
  for (const root of roots) {
    if (root === doc.body || root === doc.documentElement) nodes.push(...collectChildren(root, ctx));
    else nodes.push(...buildNodes(root, ctx));
  }
  const rendered = renderTree(nodes, { budget: args.budget || 30000, depth: args.depth });
  latest = new Map();
  for (const ref of rendered.printed) {
    const el = ctx.elements.get(ref);
    if (el) latest.set(ref, new WeakRef(el));
  }
  return {
    ok: true,
    yaml: rendered.text,
    truncated: rendered.truncated,
    refs: rendered.printed.length,
    url: location.href,
    title: doc.title,
  };
}

// ---------------------------------------------------------------- targets

function resolveTarget(target) {
  const text = String(target || "").trim();
  if (!text) return { error: { code: "invalid", message: "a target is required: a ref from browser_snapshot or a CSS selector" } };
  if (REF_RE.test(text)) {
    const ref = latest.get(text);
    const el = ref && ref.deref();
    if (!el || !el.isConnected) {
      return { error: { code: "notFound", message: "Ref " + text + " not found in the current page snapshot. Try capturing new snapshot." } };
    }
    return { element: el };
  }
  let matches;
  try {
    matches = document.querySelectorAll(text);
  } catch (_) {
    return { error: { code: "invalid", message: JSON.stringify(text) + " is neither a ref (e12) nor a valid CSS selector" } };
  }
  if (!matches.length) {
    return { error: { code: "notFound", message: JSON.stringify(text) + " does not match any elements." } };
  }
  if (matches.length > 1) {
    return { error: { code: "ambiguous", message: JSON.stringify(text) + " matches " + matches.length
      + " elements: use a ref from browser_snapshot" } };
  }
  return { element: matches[0] };
}

function center(el) {
  const rect = el.getBoundingClientRect();
  return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, rect };
}

function inViewport(el) {
  const rect = el.getBoundingClientRect();
  const view = el.ownerDocument.defaultView;
  return rect.bottom > 0 && rect.right > 0 && rect.top < view.innerHeight && rect.left < view.innerWidth;
}

/** The element that receives a pointer at `el`'s centre — shadow roots traversed. */
function hitTarget(el) {
  const { x, y } = center(el);
  let root = el.ownerDocument;
  let hit = root.elementFromPoint(x, y);
  while (hit && hit.shadowRoot) {
    const inner = hit.shadowRoot.elementFromPoint(x, y);
    if (!inner || inner === hit) break;
    hit = inner;
  }
  return hit;
}

function containsDeep(el, node) {
  for (let n = node; n; ) {
    if (n === el) return true;
    if (n.parentNode) n = n.parentNode;
    else if (n.host) n = n.host;
    else return false;
  }
  return false;
}

/**
 * Single shot: is the target ready for `action`? Swift calls again (and
 * compares the box, for stability) until ready or out of time — no timers
 * here, a hidden page throttles them.
 */
function prepare(args) {
  if (args.trusted) return prepareTrusted(args);
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  if (!el.isConnected) return { ok: true, status: "retry", reason: "element is not attached to the page" };
  if (!isVisible(el) && !(args.action === "upload" && el.localName === "input")) {
    return { ok: true, status: "retry", reason: "element is not visible" };
  }
  if ((args.action === "click" || args.action === "type" || args.action === "select") && isDisabled(el)) {
    return { ok: true, status: "retry", reason: "element is disabled" };
  }
  if (args.action === "type" && !isEditable(el) && !el.isContentEditable) {
    const inner = el.querySelector && el.querySelector("input, textarea, [contenteditable='true'], [contenteditable='']");
    if (!inner) return { error: { code: "notEditable", message: describe(el) + " is not an editable field" } };
  }
  if (args.action === "select" && el.localName !== "select") {
    return { error: { code: "notSelect", message: describe(el) + " is not a <select>: click it, then click the option's ref" } };
  }
  if (!inViewport(el)) {
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
  }
  const { rect } = center(el);
  if (args.action === "click" || args.action === "hover") {
    const hit = hitTarget(el);
    const label = hit && hit.closest ? hit.closest("label") : null;
    const ok = hit && (containsDeep(el, hit) || (label && label.control === el) || (el.localName === "label" && containsDeep(el, hit)));
    if (!ok) {
      return { ok: true, status: "retry", reason: describe(hit) + " intercepts pointer events", rect: box(rect) };
    }
  }
  return { ok: true, status: "ready", rect: box(rect), description: describe(el) };
}

function box(rect) {
  return { x: Math.round(rect.left), y: Math.round(rect.top), width: Math.round(rect.width), height: Math.round(rect.height) };
}

// ---------------------------------------------------------------- input

function modifiersInit(modifiers) {
  const set = new Set((modifiers || []).map((m) => String(m).toLowerCase()));
  return { altKey: set.has("alt"), ctrlKey: set.has("control"), metaKey: set.has("meta") || set.has("controlormeta"), shiftKey: set.has("shift") };
}

const BUTTONS = { left: 0, middle: 1, right: 2 };

function pointerSequence(el, options) {
  const doc = el.ownerDocument;
  const view = doc.defaultView;
  const { x, y } = center(el);
  const target = hitTarget(el) || el;
  const button = BUTTONS[options.button || "left"] || 0;
  const buttons = button === 0 ? 1 : button === 1 ? 4 : 2;
  const mods = modifiersInit(options.modifiers);
  const base = Object.assign({ bubbles: true, cancelable: true, composed: true, view, clientX: x, clientY: y,
    screenX: x + (view.screenX || 0), screenY: y + (view.screenY || 0) }, mods);
  const pointer = (type, extra) => target.dispatchEvent(new view.PointerEvent(type, Object.assign(
    { pointerId: 1, pointerType: "mouse", isPrimary: true }, base, extra)));
  const mouse = (type, extra) => target.dispatchEvent(new view.MouseEvent(type, Object.assign({}, base, extra)));

  pointer("pointerover", { buttons: 0 });
  target.dispatchEvent(new view.PointerEvent("pointerenter", Object.assign({}, base, { bubbles: false, buttons: 0, pointerType: "mouse" })));
  mouse("mouseover", { buttons: 0 });
  target.dispatchEvent(new view.MouseEvent("mouseenter", Object.assign({}, base, { bubbles: false, buttons: 0 })));
  pointer("pointermove", { buttons: 0 });
  mouse("mousemove", { buttons: 0 });
  if (options.hoverOnly) return;

  const clicks = options.double ? 2 : 1;
  for (let detail = 1; detail <= clicks; detail++) {
    pointer("pointerdown", { button, buttons, detail });
    const allowed = mouse("mousedown", { button, buttons, detail });
    if (allowed && detail === 1) focusFor(target, el);
    pointer("pointerup", { button, buttons: 0, detail });
    mouse("mouseup", { button, buttons: 0, detail });
    if (button === 0) mouse("click", { button, buttons: 0, detail });
    else if (button === 1) mouse("auxclick", { button, buttons: 0, detail });
  }
  if (button === 2) mouse("contextmenu", { button, buttons: 0, detail: 1 });
  if (options.double && button === 0) mouse("dblclick", { button, buttons: 0, detail: 2 });
}

/** What a real press focuses: the nearest focusable ancestor of the hit, else nothing. */
function focusFor(hit, fallback) {
  for (let node = hit; node && node.nodeType === 1; node = node.parentElement || (node.getRootNode && node.getRootNode().host)) {
    if (isFocusable(node)) {
      node.focus({ preventScroll: true });
      return;
    }
  }
  const active = deepActiveElement(fallback.ownerDocument);
  if (active && active.blur && active !== fallback.ownerDocument.body) active.blur();
}

function isFocusable(el) {
  if (!el || el.nodeType !== 1 || isDisabled(el)) return false;
  if (el.hasAttribute("tabindex")) return el.tabIndex >= -1;
  if (el.isContentEditable) return true;
  const tag = el.localName;
  if (tag === "a" || tag === "area") return el.hasAttribute("href");
  return /^(button|input|select|textarea|iframe|summary)$/.test(tag);
}

function click(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  pointerSequence(el, { button: args.button, double: args.doubleClick, modifiers: args.modifiers });
  return { ok: true, description: describe(el) };
}

function hover(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  pointerSequence(resolved.element, { hoverOnly: true });
  return { ok: true, description: describe(resolved.element) };
}

function editableIn(el) {
  if (isEditable(el) || el.isContentEditable) return el;
  return el.querySelector ? el.querySelector("input, textarea, [contenteditable='true'], [contenteditable='']") : null;
}

function inputEvent(el, type, data, inputType) {
  const view = el.ownerDocument.defaultView;
  const init = { bubbles: true, cancelable: type === "beforeinput", composed: true, data, inputType };
  return el.dispatchEvent(typeof view.InputEvent === "function" ? new view.InputEvent(type, init) : new view.Event(type, init));
}

/** Types `text` where the caret is, as the editing commands do (trusted input events). */
function insertText(el, text) {
  const doc = el.ownerDocument;
  let done = false;
  try { done = text ? doc.execCommand("insertText", false, text) : doc.execCommand("delete", false); } catch (_) { done = false; }
  if (done) return true;
  if (el.localName === "input" || el.localName === "textarea") {
    // Fallback: the value property from this world is the native setter — a
    // framework's tracker lives on the page's wrapper, so it sees a change.
    const start = el.selectionStart != null ? el.selectionStart : el.value.length;
    const end = el.selectionEnd != null ? el.selectionEnd : el.value.length;
    el.value = el.value.slice(0, start) + text + el.value.slice(end);
    inputEvent(el, "input", text || null, text ? "insertText" : "deleteContentBackward");
    return true;
  }
  return false;
}

function selectAllIn(el) {
  if (el.localName === "input" || el.localName === "textarea") {
    try { el.select(); } catch (_) { /* types without selection */ }
    return;
  }
  const doc = el.ownerDocument;
  const range = doc.createRange();
  range.selectNodeContents(el);
  const selection = doc.defaultView.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

function type(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const field = editableIn(resolved.element);
  if (!field) return { error: { code: "notEditable", message: describe(resolved.element) + " is not an editable field" } };
  const text = String(args.text == null ? "" : args.text);
  field.focus({ preventScroll: true });
  selectAllIn(field);
  insertText(field, text);
  const plain = field.localName === "input" || field.localName === "textarea";
  if (plain && field.value !== text && (field.getAttribute("type") || "").toLowerCase() !== "file") {
    field.value = text;
    inputEvent(field, "input", text, "insertReplacementText");
  }
  if (plain) field.dispatchEvent(new field.ownerDocument.defaultView.Event("change", { bubbles: true }));
  if (args.submit) pressKey({ key: "Enter", code: "Enter", keyCode: 13 });
  return { ok: true, description: describe(field), value: plain ? (field.type === "password" ? "••••" : field.value) : collapse(field.innerText) };
}

function selectOption(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  if (el.localName !== "select") {
    return { error: { code: "notSelect", message: describe(el) + " is not a <select>: click it, then click the option's ref" } };
  }
  const wanted = (args.values || []).map(String);
  if (!wanted.length) return { error: { code: "invalid", message: "values must name at least one option" } };
  if (wanted.length > 1 && !el.multiple) return { error: { code: "invalid", message: "this <select> takes one value" } };
  const options = Array.from(el.options);
  const picked = [];
  for (const value of wanted) {
    const option = options.find((o) => o.value === value)
      || options.find((o) => collapse(o.label || o.textContent) === collapse(value))
      || options.find((o) => collapse(o.label || o.textContent).toLowerCase() === collapse(value).toLowerCase());
    if (!option) {
      return { error: { code: "optionNotFound", message: "no option " + JSON.stringify(value) + " — options: "
        + options.slice(0, 20).map((o) => JSON.stringify(collapse(o.label || o.textContent))).join(", ") } };
    }
    picked.push(option);
  }
  el.focus({ preventScroll: true });
  if (el.multiple) options.forEach((o) => { o.selected = picked.includes(o); });
  else el.value = picked[0].value;
  const view = el.ownerDocument.defaultView;
  el.dispatchEvent(new view.Event("input", { bubbles: true, composed: true }));
  el.dispatchEvent(new view.Event("change", { bubbles: true }));
  return { ok: true, description: describe(el), selected: picked.map((o) => collapse(o.label || o.textContent)) };
}

// Keyboard: the page sees keydown/keypress/keyup; the browser's own default
// actions do not follow synthetic events, so the common ones are emulated.

function tabbables(doc) {
  const all = Array.from(doc.querySelectorAll("*")).filter((el) => {
    if (!isFocusable(el) || el.tabIndex < 0) return false;
    if (el.closest("[inert]")) return false;
    return isVisible(el);
  });
  const positive = all.filter((el) => el.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex);
  return positive.concat(all.filter((el) => el.tabIndex === 0));
}

function moveFocus(from, backwards) {
  const doc = (from && from.ownerDocument) || document;
  const list = tabbables(doc);
  if (!list.length) return null;
  let index = list.indexOf(from);
  index = index < 0 ? (backwards ? list.length - 1 : 0) : (index + (backwards ? -1 : 1) + list.length) % list.length;
  list[index].focus();
  return list[index];
}

function implicitSubmit(field) {
  const form = field.form || (field.closest && field.closest("form"));
  if (!form) return false;
  const submitter = Array.from(form.elements).find((el) =>
    (el.localName === "button" && (el.getAttribute("type") || "submit").toLowerCase() === "submit")
    || (el.localName === "input" && /^(submit|image)$/i.test(el.getAttribute("type") || "")));
  if (submitter) {
    if (!isDisabled(submitter)) submitter.click();
    return true;
  }
  const fields = Array.from(form.elements).filter((el) => el.localName === "input" && isEditable(el));
  if (fields.length === 1) {
    if (typeof form.requestSubmit === "function") form.requestSubmit();
    else form.submit();
    return true;
  }
  return false;
}

function defaultAction(spec, target) {
  const key = spec.key;
  const mods = spec;
  const editable = isEditable(target) || (target && target.isContentEditable);
  const view = (target && target.ownerDocument.defaultView) || window;
  if ((mods.metaKey || mods.ctrlKey) && key.toLowerCase() === "a") {
    if (editable) selectAllIn(target);
    else target.ownerDocument.execCommand("selectAll");
    return;
  }
  if (mods.metaKey || mods.ctrlKey) return;
  switch (key) {
    case "Enter":
      if (target.localName === "textarea") { insertText(target, "\n"); return; }
      if (target.isContentEditable) { target.ownerDocument.execCommand("insertParagraph"); return; }
      if (target.localName === "input" && isEditable(target)) { implicitSubmit(target); return; }
      if (target.localName === "a" || target.localName === "button" || roleOf(target) === "button" || roleOf(target) === "link") {
        target.click();
      }
      return;
    case " ":
      if (editable) { insertText(target, " "); return; }
      if (/^(button|summary)$/.test(target.localName) || /^(checkbox|radio)$/i.test(target.getAttribute("type") || "")
          || /^(button|checkbox|radio|switch|menuitem|tab|option)$/.test(roleOf(target) || "")) {
        target.click();
        return;
      }
      view.scrollBy(0, view.innerHeight * 0.8);
      return;
    case "Tab":
      moveFocus(target, mods.shiftKey);
      return;
    case "Backspace":
      if (editable) target.ownerDocument.execCommand("delete");
      return;
    case "Delete":
      if (editable) target.ownerDocument.execCommand("forwardDelete");
      return;
    case "ArrowDown": case "ArrowUp":
      if (target.localName === "select" && !target.multiple) {
        const next = target.selectedIndex + (key === "ArrowDown" ? 1 : -1);
        if (next >= 0 && next < target.options.length) {
          target.selectedIndex = next;
          target.dispatchEvent(new view.Event("input", { bubbles: true }));
          target.dispatchEvent(new view.Event("change", { bubbles: true }));
        }
        return;
      }
      if (!editable) view.scrollBy(0, key === "ArrowDown" ? 40 : -40);
      return;
    case "PageDown": case "PageUp":
      if (!editable) view.scrollBy(0, (key === "PageDown" ? 1 : -1) * view.innerHeight * 0.8);
      return;
    case "Home": case "End":
      if (!editable) view.scrollTo(0, key === "Home" ? 0 : target.ownerDocument.documentElement.scrollHeight);
      return;
    default:
      if (spec.text && editable) insertText(target, spec.text);
  }
}

/** `spec`: {key, code, keyCode, text?, shiftKey, ctrlKey, altKey, metaKey}, parsed in Swift. */
function pressKey(spec) {
  const active = deepActiveElement(document);
  const target = active && active !== document.documentElement ? active : (document.body || document.documentElement);
  const view = target.ownerDocument.defaultView;
  const init = {
    key: spec.key, code: spec.code || "", keyCode: spec.keyCode || 0, which: spec.keyCode || 0, charCode: 0,
    shiftKey: !!spec.shiftKey, ctrlKey: !!spec.ctrlKey, altKey: !!spec.altKey, metaKey: !!spec.metaKey,
    bubbles: true, cancelable: true, composed: true, view,
  };
  const proceed = target.dispatchEvent(new view.KeyboardEvent("keydown", init));
  if (proceed) {
    const printable = spec.text && !spec.ctrlKey && !spec.metaKey;
    if (printable || spec.key === "Enter") {
      const code = printable ? spec.text.charCodeAt(0) : 13;
      const pressed = target.dispatchEvent(new view.KeyboardEvent("keypress", Object.assign({}, init,
        { charCode: code, keyCode: code, which: code })));
      if (pressed) {
        if (printable && spec.key !== " ") {
          if (isEditable(target) || target.isContentEditable) insertText(target, spec.text);
        } else {
          defaultAction(Object.assign({}, spec, init), target);
        }
      }
    } else {
      defaultAction(Object.assign({}, spec, init), target);
    }
  }
  target.dispatchEvent(new view.KeyboardEvent("keyup", init));
  const now = deepActiveElement(document);
  return { ok: true, focused: describe(now) };
}

/** One turn of the page's scheduler: its microtasks, then a task — where
 * Vue, Svelte, Lit and React re-render. A message, not a timer: a hidden
 * page's timers are throttled. */
function nextTurn(view) {
  return new Promise((resolve) => {
    const channel = new view.MessageChannel();
    channel.port1.onmessage = () => resolve();
    channel.port2.postMessage(0);
  });
}

/** A checkbox or radio to a state: clicked only when it differs, read once
 * the page had its turn to re-render (a custom one's aria-checked). */
async function setChecked(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  const input = el.localName === "input" ? el : (el.control || el.querySelector && el.querySelector("input"));
  const read = () => input ? input.checked : el.getAttribute("aria-checked") === "true";
  const wanted = !!args.checked;
  if (read() !== wanted) {
    pointerSequence(el, {});
    await nextTurn(el.ownerDocument.defaultView || window);
  }
  return { ok: true, description: describe(el), checked: read() };
}

/** A range (slider) or any input whose value is set directly. */
function setValue(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  if (el.localName !== "input" && el.localName !== "textarea") {
    return { error: { code: "notEditable", message: describe(el) + " has no value to set" } };
  }
  el.focus({ preventScroll: true });
  el.value = String(args.value);
  const view = el.ownerDocument.defaultView;
  el.dispatchEvent(new view.Event("input", { bubbles: true, composed: true }));
  el.dispatchEvent(new view.Event("change", { bubbles: true }));
  return { ok: true, description: describe(el), value: el.value };
}

/** Focuses the field and clears it — before characters are typed one by one. */
function focusField(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const field = editableIn(resolved.element);
  if (!field) return { error: { code: "notEditable", message: describe(resolved.element) + " is not an editable field" } };
  field.focus({ preventScroll: true });
  if (args.clear) {
    selectAllIn(field);
    insertText(field, "");
  }
  return { ok: true, description: describe(field) };
}

/** Each key of `keys` as a press — for type-ahead handlers that watch keys. */
function typeKeys(args) {
  for (const spec of args.keys || []) pressKey(spec);
  return { ok: true };
}

// ---------------------------------------------------------------- reading

function visibleText(doc) {
  let text = doc.body ? doc.body.innerText || "" : "";
  for (const frame of doc.querySelectorAll("iframe")) {
    try {
      if (frame.contentDocument) text += "\n" + visibleText(frame.contentDocument);
    } catch (_) { /* cross-origin */ }
  }
  return text;
}

function waitText(args) {
  if (args.maxMs !== undefined || args.observe === true) return waitTextObserved(args);
  const text = collapse(visibleText(document));
  if (args.text != null) return { ok: true, found: text.includes(collapse(args.text)) };
  if (args.textGone != null) return { ok: true, found: !text.includes(collapse(args.textGone)) };
  return { error: { code: "invalid", message: "text or textGone is required" } };
}

/** `el`'s box in the top document's viewport: the offsets of the same-origin
 * frames it sits in added, clipped to each frame. */
function topRect(el) {
  const r = el.getBoundingClientRect();
  let left = r.left, top = r.top, right = r.right, bottom = r.bottom;
  for (let view = el.ownerDocument.defaultView; view && view.frameElement;
       view = view.frameElement.ownerDocument.defaultView) {
    const frame = view.frameElement;
    const outer = frame.getBoundingClientRect();
    const style = styleOf(frame) || {};
    const dx = outer.left + frame.clientLeft + (parseFloat(style.paddingLeft) || 0);
    const dy = outer.top + frame.clientTop + (parseFloat(style.paddingTop) || 0);
    left = Math.max(left, 0) + dx;
    top = Math.max(top, 0) + dy;
    right = Math.min(right, view.innerWidth) + dx;
    bottom = Math.min(bottom, view.innerHeight) + dy;
  }
  return { left, top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
}

function rect(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  let r = topRect(el);
  if (!(r.width > 0 && r.height > 0 && r.top < window.innerHeight && r.left < window.innerWidth
        && r.top + r.height > 0 && r.left + r.width > 0)) {
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    r = topRect(el);
  }
  return { ok: true, rect: box(r), description: describe(el) };
}

function pageInfo() {
  const doc = document.documentElement;
  return {
    ok: true, url: location.href, title: document.title,
    width: window.innerWidth, height: window.innerHeight,
    // What window.scrollTo can reach: a page whose <body> scrolls itself is
    // as tall as its window.
    scrollWidth: (document.scrollingElement || doc || { scrollWidth: 0 }).scrollWidth,
    scrollHeight: (document.scrollingElement || doc || { scrollHeight: 0 }).scrollHeight,
    scrollX: window.scrollX, scrollY: window.scrollY,
    visibility: document.visibilityState,
  };
}

/** Scrolls the top document at once (a page's smooth scrolling aside) — for
 * full-page screenshots, which put it back after. */
function scrollTo(args) {
  window.scrollTo({ left: Number(args.x) || 0, top: Number(args.y) || 0, behavior: "instant" });
  return { ok: true, x: window.scrollX, y: window.scrollY };
}

/** Marks the target for a page-world function: only DOM state crosses worlds. */
function stamp(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const nonce = "n" + Math.random().toString(36).slice(2) + Date.now().toString(36);
  resolved.element.setAttribute("data-loom-eval", nonce);
  return { ok: true, nonce, description: describe(resolved.element) };
}

// ---------------------------------------------------------------- Chromium
// What only Loom's Chromium engine asks (ADR-0015): its input is real
// (Input.*), so the helper finds where to press and when the page has had
// its turn. WebKit never passes `trusted`, `afterFrame` or `maxMs`, nor
// calls `barrier`, `documentRect` or `dispatchCancel`: its paths above are
// unchanged.

/** One task of the page's event loop: what the page queued before with a
 * setTimeout(0) has run, and the DevTools events it caused are on the pipe
 * before this call's reply (design §4). */
function nextTask() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

/** One rendering frame: a rAF, raced with 50 ms — a page that does not
 * paint never stalls a command. */
function oneFrame() {
  return new Promise((resolve) => {
    let timer = 0;
    const done = () => { clearTimeout(timer); resolve(); };
    timer = setTimeout(done, 50);
    try { requestAnimationFrame(done); } catch (_) { /* no rendering here: the timer */ }
  });
}

/** `rect` (top viewport) cut to the top viewport. */
function clipToTop(r) {
  const left = Math.max(r.left, 0);
  const top = Math.max(r.top, 0);
  const right = Math.min(r.left + r.width, window.innerWidth);
  const bottom = Math.min(r.top + r.height, window.innerHeight);
  return { left, top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
}

function inTopViewport(el) {
  const visible = clipToTop(topRect(el));
  return visible.width > 0 && visible.height > 0;
}

function sameRect(a, b) {
  return a.left === b.left && a.top === b.top && a.width === b.width && a.height === b.height;
}

const round2 = (value) => Math.round(value * 100) / 100;

/** The element a pointer at (x, y) of `doc`'s viewport lands on — shadow roots traversed. */
function elementAt(doc, x, y) {
  let hit = doc.elementFromPoint(x, y);
  while (hit && hit.shadowRoot) {
    const inner = hit.shadowRoot.elementFromPoint(x, y);
    if (!inner || inner === hit) break;
    hit = inner;
  }
  return hit;
}

/** Whether a press on `hit` reaches `el`: inside it, or on a label of it. */
function reaches(el, hit) {
  if (!hit) return false;
  if (containsDeep(el, hit)) return true;
  const label = hit.closest ? hit.closest("label") : null;
  return !!(label && label.control === el);
}

/**
 * What would take a press at `point` (top viewport) instead of `el`, or
 * null: `el`'s own document is hit at the frame-local point, then each frame
 * it sits in must be what its parent document hits there — an overlay over
 * the iframe takes the press too.
 */
function interceptor(el, point) {
  const levels = [];   // innermost frame first
  for (let view = el.ownerDocument.defaultView; view && view.frameElement;
       view = view.frameElement.ownerDocument.defaultView) {
    const frame = view.frameElement;
    const outer = frame.getBoundingClientRect();
    const style = styleOf(frame) || {};
    levels.push({
      frame,
      dx: outer.left + frame.clientLeft + (parseFloat(style.paddingLeft) || 0),
      dy: outer.top + frame.clientTop + (parseFloat(style.paddingTop) || 0),
    });
  }
  let x = point.x;
  let y = point.y;
  for (const level of levels) { x -= level.dx; y -= level.dy; }
  const hit = elementAt(el.ownerDocument, x, y);
  if (!reaches(el, hit)) return { hit };
  for (const level of levels) {
    x += level.dx;
    y += level.dy;
    const outer = elementAt(level.frame.ownerDocument, x, y);
    if (outer !== level.frame) return { hit: outer };
  }
  return null;
}

const SET_VALUE_TYPES = /^(date|datetime-local|month|time|week|color|range|number)$/;

/** How text reaches the field: typed by Input.insertText, set by the
 * helper's `type` (a picker's value: date, color, range, number), or not at all. */
function fillMode(el) {
  const field = editableIn(el) || el;
  if (field.localName === "input") {
    const type = (field.getAttribute("type") || "text").toLowerCase();
    if (SET_VALUE_TYPES.test(type)) return "setValue";
    return isEditable(field) ? "insertText" : "none";
  }
  if (field.localName === "textarea") return isEditable(field) ? "insertText" : "none";
  return field.isContentEditable ? "insertText" : "none";
}

/**
 * `prepare` for real input: the checks of the single shot, then — for a
 * pointer — the box unchanged over one frame and nothing else under its
 * centre, through the frames it sits in. Answers the point to press, in
 * the top viewport's CSS pixels, and how `type` fills it; `focus` and
 * `selectAll` ready the field for Input.insertText. One call, no timer
 * loop: Loom calls again on `retry`.
 */
async function prepareTrusted(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  const action = args.action;
  const pointer = action === "click" || action === "hover";
  if (!el.isConnected) return { ok: true, status: "retry", reason: "element is not attached to the page" };
  if (!isVisible(el) && !(action === "upload" && el.localName === "input")) {
    return { ok: true, status: "retry", reason: "element is not visible" };
  }
  if ((action === "click" || action === "type" || action === "select") && isDisabled(el)) {
    return { ok: true, status: "retry", reason: "element is disabled" };
  }
  if (action === "type" && !isEditable(el) && !el.isContentEditable) {
    const inner = el.querySelector && el.querySelector("input, textarea, [contenteditable='true'], [contenteditable='']");
    if (!inner) return { error: { code: "notEditable", message: describe(el) + " is not an editable field" } };
  }
  if (action === "select" && el.localName !== "select") {
    return { error: { code: "notSelect", message: describe(el) + " is not a <select>: click it, then click the option's ref" } };
  }
  if (!inTopViewport(el)) {
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
  }
  let r = topRect(el);
  if (pointer) {
    await oneFrame();
    if (!el.isConnected) return { ok: true, status: "retry", reason: "element is not attached to the page" };
    const after = topRect(el);
    if (!sameRect(r, after)) return { ok: true, status: "retry", reason: "element is moving", rect: box(after) };
    r = after;
  }
  const visible = clipToTop(r);
  const shown = visible.width > 0 && visible.height > 0;
  if (pointer && !shown) {
    return { ok: true, status: "retry", reason: "element is outside of the viewport", rect: box(r) };
  }
  const area = shown ? visible : r;
  const point = { x: round2(area.left + area.width / 2), y: round2(area.top + area.height / 2) };
  if (pointer) {
    const blocked = interceptor(el, point);
    if (blocked) {
      return { ok: true, status: "retry", reason: describe(blocked.hit) + " intercepts pointer events", rect: box(r) };
    }
  }
  if (args.focus) {
    const field = editableIn(el) || el;
    field.focus({ preventScroll: true });
    if (args.selectAll) selectAllIn(field);
  }
  return { ok: true, status: "ready", rect: box(r), point, description: describe(el), fill: fillMode(el) };
}

/** A checkbox, radio or switch's state, as `setChecked` reads it. */
function checkedState(el) {
  const input = el.localName === "input" ? el : (el.control || (el.querySelector && el.querySelector("input")));
  return input ? input.checked : el.getAttribute("aria-checked") === "true";
}

/** Where the page stands: what `barrier` answers, and a snapshot `afterFrame`. */
function pageFacts(args) {
  const facts = {
    url: location.href,
    title: document.title,
    visibility: document.visibilityState,
    focused: describe(deepActiveElement(document)),
  };
  if (args.checkedOf != null) {
    const resolved = resolveTarget(args.checkedOf);
    if (!resolved.error) facts.checked = checkedState(resolved.element);
  }
  return facts;
}

/** After an action: one task of the page's event loop, then where it stands. */
async function barrier(args) {
  await nextTask();
  return Object.assign({ ok: true }, pageFacts(args));
}

/** The barrier, then one frame for what renders in a rAF, then the walk. */
async function snapshotAfterFrame(args) {
  await nextTask();
  await oneFrame();
  const answer = snapshot(Object.assign({}, args, { afterFrame: false }));
  if (answer.error) return answer;
  return Object.assign(answer, pageFacts(args));
}

/**
 * `waitText` that waits, up to `maxMs` (2000 by default, 30 s at most):
 * checked again a frame after the DOM changes, at most once a frame — and
 * every 250 ms for what no observer here sees (a frame's own document, a
 * stylesheet's effect). `found` as the single shot's.
 */
function waitTextObserved(args) {
  if (args.text == null && args.textGone == null) {
    return { error: { code: "invalid", message: "text or textGone is required" } };
  }
  const met = () => {
    let text = "";
    try { text = collapse(visibleText(document)); } catch (_) { return false; }
    return args.text != null ? text.includes(collapse(args.text)) : !text.includes(collapse(args.textGone));
  };
  if (met()) return { ok: true, found: true };
  const raw = args.maxMs == null ? NaN : Number(args.maxMs);
  const maxMs = Number.isFinite(raw) ? Math.min(Math.max(raw, 0), 30000) : 2000;
  if (maxMs === 0) return { ok: true, found: false };
  return new Promise((resolve) => {
    let finished = false;
    let pending = false;
    let timer = 0;
    let poll = 0;
    let observer = null;
    const finish = (found) => {
      if (finished) return;
      finished = true;
      if (observer) observer.disconnect();
      clearTimeout(timer);
      clearInterval(poll);
      resolve({ ok: true, found });
    };
    const check = () => {
      if (pending || finished) return;
      pending = true;
      oneFrame().then(() => {
        pending = false;
        if (!finished && met()) finish(true);
      });
    };
    observer = new MutationObserver(check);
    observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
    poll = setInterval(check, 250);
    timer = setTimeout(() => finish(met()), maxMs);
  });
}

/**
 * The element's box in the top DOCUMENT's coordinates (its top-viewport
 * box plus the scroll): Page.captureScreenshot's clip. Scrolled into view
 * first when none of it shows, as `rect` does; `viewport` is the part of
 * the document on screen.
 */
function documentRect(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const el = resolved.element;
  if (!inTopViewport(el)) {
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
  }
  const r = topRect(el);
  const x = window.scrollX;
  const y = window.scrollY;
  return {
    ok: true,
    rect: box({ left: r.left + x, top: r.top + y, width: r.width, height: r.height }),
    viewport: { x, y, width: window.innerWidth, height: window.innerHeight },
    description: describe(el),
  };
}

/** The element `stamp` (or Loom) marked with `nonce`, in the top document or a same-origin frame. */
function stamped(doc, nonce) {
  const found = doc.querySelector('[data-loom-eval="' + nonce.replace(/["\\]/g, "\\$&") + '"]');
  if (found) return found;
  for (const frame of doc.querySelectorAll("iframe")) {
    let inner = null;
    try { inner = frame.contentDocument; } catch (_) { inner = null; }
    const hit = inner ? stamped(inner, nonce) : null;
    if (hit) return hit;
  }
  return null;
}

/** A file chooser Loom cancelled: the input's `cancel` event, as a person's
 * cancel fires it. `target` (a ref or selector) or `nonce` (a stamp). */
function dispatchCancel(args) {
  let el = null;
  if (args.nonce != null) {
    el = stamped(document, String(args.nonce));
    if (!el) return { error: { code: "notFound", message: "the file input is no longer in the page" } };
    el.removeAttribute("data-loom-eval");
  } else {
    const resolved = resolveTarget(args.target);
    if (resolved.error) return resolved;
    el = resolved.element;
  }
  if (el.localName !== "input" || (el.getAttribute("type") || "").toLowerCase() !== "file") {
    return { error: { code: "invalid", message: describe(el) + " is not a file input" } };
  }
  const view = el.ownerDocument.defaultView || window;
  el.dispatchEvent(new view.Event("cancel", { bubbles: true }));
  return { ok: true, description: describe(el) };
}

const OPS = { snapshot, prepare, click, hover, type, selectOption, pressKey, waitText, rect, pageInfo, stamp,
  setChecked, setValue, focusField, typeKeys, scrollTo, barrier, documentRect, dispatchCancel };

async function run(op, argsJSON) {
  try {
    const fn = OPS[op];
    if (!fn) return JSON.stringify({ error: { code: "invalid", message: "unknown op " + op } });
    const args = argsJSON ? JSON.parse(argsJSON) : {};
    return JSON.stringify(await fn(args));
  } catch (error) {
    return JSON.stringify({ error: { code: "failed", message: String(error && error.message || error) } });
  }
}

Object.defineProperty(globalThis, "__loomAgent", {
  value: Object.freeze({
    version: VERSION,
    run,
    _pure: Object.freeze({ collapse, truncate, yamlScalar, nodeHead, renderTree, REF_RE }),
  }),
  configurable: false,
  enumerable: false,
  writable: false,
});
})();
"""#

    /// What `browser_evaluate` answers goes through this, in the page's world.
    public static let serializer = #"""
((value) => {
  // What browser_evaluate answers: JSON the agent can read. Nodes are
  // described, cycles marked, functions named — never a crash on undefined.
  if (value === undefined) return "undefined";
  const describe = (node) => {
    if (!node || node.nodeType !== 1) return String(node && node.nodeName || node);
    let text = "<" + node.localName;
    if (node.id) text += "#" + node.id;
    if (typeof node.className === "string" && node.className.trim()) {
      text += "." + node.className.trim().split(/\s+/).slice(0, 2).join(".");
    }
    return text + ">";
  };
  const seen = new WeakSet();
  try {
    const text = JSON.stringify(value, function (key, inner) {
      if (typeof inner === "bigint") return inner.toString() + "n";
      if (typeof inner === "function") return "[Function " + (inner.name || "anonymous") + "]";
      if (typeof inner === "symbol") return inner.toString();
      if (inner === undefined) return key === "" ? "undefined" : undefined;
      if (typeof inner === "object" && inner !== null) {
        if (typeof Node !== "undefined" && inner instanceof Node) return describe(inner);
        if (inner instanceof Error) return { name: inner.name, message: inner.message };
        if (seen.has(inner)) return "[Circular]";
        seen.add(inner);
        if (inner instanceof Map) return Object.fromEntries(inner);
        if (inner instanceof Set) return Array.from(inner);
      }
      return inner;
    }, 2);
    return text === undefined ? String(value) : text;
  } catch (error) {
    return String(value);
  }
})
"""#

    public static let worldName = "loom-agent"
    public static let messageHandlerName = "loomAgent"

    /// The helper's content world: its globals are invisible to the page,
    /// the DOM is shared.
    @MainActor public static var world: WKContentWorld { .world(name: worldName) }

    /// The body every helper call runs (callAsyncJavaScript, in `world`), with
    /// `op` and `args` (a JSON string) as arguments. A page that navigated
    /// since has a fresh world: the helper answers `helperMissing`, and the
    /// caller injects it again.
    public static let helperCall = """
    return globalThis.__loomAgent \
        ? await globalThis.__loomAgent.run(op, args) \
        : JSON.stringify({ error: { code: "helperMissing", message: "the helper is not loaded" } });
    """

    /// The function every helper call runs in Chromium (ADR-0015, design
    /// §3.2): `Runtime.callFunctionOn` in the `worldName` world, with `op`
    /// and `args` (a JSON string) as its arguments, `awaitPromise` and
    /// `returnByValue` — the JSON text `helperCall` answers in WebKit. One
    /// line, as `Tests/AgentBrowserCDP/fixtures/init.json` has it.
    public static let helperFunction = #"""
async function(op, args) { return globalThis.__loomAgent ? await globalThis.__loomAgent.run(op, args) : JSON.stringify({ error: { code: "helperMissing", message: "the helper is not loaded" } }); }
"""#

    /// The body `browser_evaluate` runs in the PAGE's world: the agent's
    /// function, spliced in as code (an injected script is not subject to the
    /// page's CSP), called with the element the helper stamped, if any.
    /// An expression rather than a function is wrapped into one.
    public static func evaluateBody(function: String) -> String {
        let trimmed = function.trimmingCharacters(in: .whitespacesAndNewlines)
        let callable = isFunction(trimmed) ? trimmed : "() => (\n" + trimmed + "\n)"
        return """
        const __loomTarget = typeof nonce === "string" && nonce
            ? document.querySelector('[data-loom-eval="' + nonce + '"]') : undefined;
        if (__loomTarget) __loomTarget.removeAttribute("data-loom-eval");
        const __loomFunction = (
        \(callable)
        );
        const __loomValue = await __loomFunction(__loomTarget);
        return (\(serializer))(__loomValue);
        """
    }

    /// `function…`, `async…`, `x => …`, `(a, b) => …`.
    public static func isFunction(_ text: String) -> Bool {
        if text.hasPrefix("function") || text.hasPrefix("async ") || text.hasPrefix("async(") {
            return true
        }
        return text.range(of: #"^(\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*=>"#, options: .regularExpression) != nil
    }
}
