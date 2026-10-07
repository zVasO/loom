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
    /// that exists in Loom's world only. Without it (Chromium, ADR-0016) they
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
    if (pointer && visible && !ctx.noRefs) {
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
  // `noRefs` (a locator's ariaSnapshot): the YAML without refs — none
  // minted, and the latest snapshot's refs left as they were.
  const ctx = { active: deepActiveElement(doc), elements: new Map(), noRefs: !!args.noRefs };
  const nodes = [];
  for (const root of roots) {
    if (root === doc.body || root === doc.documentElement) nodes.push(...collectChildren(root, ctx));
    else nodes.push(...buildNodes(root, ctx));
  }
  const rendered = renderTree(nodes, { budget: args.budget || 30000, depth: args.depth });
  if (!ctx.noRefs) {
    latest = new Map();
    for (const ref of rendered.printed) {
      const el = ctx.elements.get(ref);
      if (el) latest.set(ref, new WeakRef(el));
    }
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

// ---------------------------------------------------------------- locators
// Playwright's selector engines, ported (Apache-2.0, microsoft/playwright:
// packages/injected selectorUtils, roleSelectorEngine, injectedScript;
// isomorphic selectorParser). What browser_run_code's locators resolve
// through — a structured target {chain, desc, strict} — and a Playwright
// selector string in a browser tool's target (text=, role=…[name=…],
// >> nth=1). Roles and names are the snapshot's own (roleOf,
// accessibleNameRaw untruncated): getByRole finds what browser_snapshot
// shows. Frames are not entered (a ref still reaches into one).
//
// A step (wire format): {css} {xpath} {ref} {selector} | {role, name?,
// checked?, pressed?, selected?, expanded?, level?, disabled?,
// includeHidden?} | {text, legacy?} {label} {placeholder} {alt} {title}
// {testId} | {hasText, not?} {has: Locator, not?} {visible} | {nth}
// {and: Locator} {or: Locator}. A text is {s, m: ci|cs|eq|eqi} or {re, f}.

const LOCATOR_LIMITS = { steps: 32, depth: 4, bytes: 16384, lines: 10, chars: 100000, items: 1000, total: 1000000 };

/** Playwright's normalizeWhiteSpace: zero-width spaces and soft hyphens dropped, trimmed, runs collapsed. */
function normalizeWS(text) {
  return String(text == null ? "" : text).replace(/[\u200b\u00ad]/g, "").trim().replace(/\s+/g, " ");
}

function invalidSelector(message) {
  const error = new Error(message);
  error.code = "invalid";
  return error;
}

function messageOf(error) {
  return String(error && error.message || error);
}

const TEXT_MODES = new Set(["ci", "cs", "eq", "eqi"]);

/** A text spec checked: {s, m} or {re, f}; a bare string is Playwright's default (contains, any case). */
function textSpec(spec) {
  if (typeof spec === "string") return { s: spec, m: "ci" };
  if (spec && typeof spec === "object") {
    if (typeof spec.re === "string") return { re: spec.re, f: typeof spec.f === "string" ? spec.f : "" };
    if (typeof spec.s === "string") {
      const m = spec.m == null ? "ci" : spec.m;
      if (TEXT_MODES.has(m)) return { s: spec.s, m };
    }
  }
  throw invalidSelector("a text must be a string, {s, m: ci|cs|eq|eqi} or {re, f}: " + JSON.stringify(spec));
}

/** The spec's RegExp, without g and y: they make test() stateful. */
function specRegex(spec) {
  try {
    return new RegExp(spec.re, String(spec.f || "").replace(/[gy]/g, ""));
  } catch (error) {
    throw invalidSelector("invalid regular expression /" + spec.re + "/" + (spec.f || "") + ": " + messageOf(error));
  }
}

/**
 * Text spec → (value) => boolean. `normalize`: role names (both sides
 * normalized); otherwise attribute values, as they are. ci contains, any
 * case; cs contains; eq equals; eqi equals, any case; a regex is tested.
 */
function stringMatcher(spec, normalize) {
  const t = textSpec(spec);
  const prep = normalize ? normalizeWS : (value) => String(value == null ? "" : value);
  if (t.re !== undefined) {
    const re = specRegex(t);
    return (value) => re.test(prep(value));
  }
  const q = prep(t.s);
  const lower = q.toLowerCase();
  switch (t.m) {
    case "cs": return (value) => prep(value).includes(q);
    case "eq": return (value) => prep(value) === q;
    case "eqi": return (value) => prep(value).toLowerCase() === lower;
    default: return (value) => prep(value).toLowerCase().includes(lower);
  }
}

/**
 * Text spec → {kind, test(elementText)}: getByText's rules — a regex on the
 * full text, the rest on the normalized one. `legacy` (text="…", "…"):
 * Playwright's older rule, one of the element's own text nodes equals it.
 */
function textTest(spec, legacy) {
  const t = textSpec(spec);
  if (t.re !== undefined) {
    const re = specRegex(t);
    return { kind: "regex", test: (et) => re.test(et.full) };
  }
  const q = normalizeWS(t.s);
  const lower = q.toLowerCase();
  switch (t.m) {
    case "eq":
      if (legacy) {
        return { kind: "strict", legacy: true,
          test: (et) => (!q && !et.immediate.length) || et.immediate.some((s) => normalizeWS(s) === q) };
      }
      return { kind: "strict", test: (et) => et.normalized === q };
    case "eqi": return { kind: "strict", test: (et) => et.normalized.toLowerCase() === lower };
    case "cs": return { kind: "lax", test: (et) => et.normalized.includes(q) };
    default: return { kind: "lax", test: (et) => et.normalized.toLowerCase().includes(lower) };
  }
}

// ---------- parseSelector (pure)

const CSS_EXTENSIONS = /:(?:has-text|text|text-is|text-matches|nth-match|right-of|left-of|above|below|near)\(|:(?:visible|light)(?![\w-])/;

/** Playwright's CSS extensions are not CSS here: said, with the locator to use instead. */
function checkCSSExtensions(css) {
  const bare = css.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
  const found = CSS_EXTENSIONS.exec(bare);
  if (found) {
    throw invalidSelector("Playwright's CSS extension " + found[0].replace(/\($/, "()") + " in " + JSON.stringify(css)
      + " is not supported: use getByText, filter({ hasText }) or filter({ visible: true })");
  }
}

function cssQuote(text) {
  return '"' + String(text).replace(/["\\]/g, "\\$&").replace(/\n/g, "\\a ") + '"';
}

function cssUnquote(text) {
  const inner = text.substring(1, text.length - 1);
  if (!inner.includes("\\")) return inner;
  let out = "";
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] === "\\" && i + 1 < inner.length) i++;
    out += inner[i];
  }
  return out;
}

/**
 * Splits on top-level `>>`: not inside quotes, brackets or parentheses (a
 * `text=` body with text in it keeps its quotes, as Playwright's does), and
 * names each part — `engine=body`, a quoted text, an XPath, else CSS.
 */
function splitSelector(selector) {
  const parts = [];
  let start = 0;
  let index = 0;
  let quote = "";
  let depth = 0;
  const append = () => {
    const part = selector.substring(start, index).trim();
    const eq = part.indexOf("=");
    let name;
    let body;
    if (eq !== -1 && /^[a-zA-Z_0-9-+:*]+$/.test(part.substring(0, eq).trim())) {
      name = part.substring(0, eq).trim();
      body = part.substring(eq + 1);
    } else if (part.length > 1 && part[0] === '"' && part[part.length - 1] === '"') {
      name = "text"; body = part;
    } else if (part.length > 1 && part[0] === "'" && part[part.length - 1] === "'") {
      name = "text"; body = part;
    } else if (/^\(*\/\//.test(part) || part.startsWith("..")) {
      name = "xpath"; body = part;
    } else {
      name = "css"; body = part;
    }
    parts.push({ name, body });
  };
  const textBody = () => {
    const match = /^\s*text\s*=(.*)$/.exec(selector.substring(start, index));
    return !!match && !!match[1];
  };
  while (index < selector.length) {
    const c = selector[index];
    if (c === "\\" && index + 1 < selector.length) {
      index += 2;
    } else if (quote) {
      if (c === quote) quote = "";
      index++;
    } else if ((c === '"' || c === "'" || c === "`") && !textBody()) {
      quote = c;
      index++;
    } else if ((c === "[" || c === "(") && !textBody()) {
      depth++;
      index++;
    } else if ((c === "]" || c === ")") && depth > 0) {
      depth--;
      index++;
    } else if (c === ">" && selector[index + 1] === ">" && depth === 0) {
      append();
      index += 2;
      start = index;
    } else {
      index++;
    }
  }
  append();
  return parts;
}

/**
 * Playwright's parseAttributeSelector (unquoted strings allowed):
 * `name[attr op value flag]…` → {name, attributes: [{name, op, value,
 * caseSensitive, regex?}]}. A quoted value is case-sensitive unless `i`.
 */
function parseAttributes(selector) {
  let wp = 0;
  let EOL = selector.length === 0;
  const next = () => selector[wp] || "";
  const eat1 = () => {
    const c = next();
    ++wp;
    EOL = wp >= selector.length;
    return c;
  };
  const fail = (stage) => {
    if (EOL) throw invalidSelector("Unexpected end of selector while parsing selector `" + selector + "`");
    throw invalidSelector("Error while parsing selector `" + selector + "` - unexpected symbol \"" + next()
      + "\" at position " + wp + (stage ? " during " + stage : ""));
  };
  const skipSpaces = () => { while (!EOL && /\s/.test(next())) eat1(); };
  const nameChar = (c) => c >= "\x80" || (c >= "0" && c <= "9") || (c >= "A" && c <= "Z") || (c >= "a" && c <= "z")
    || c === "_" || c === "-";
  const readIdentifier = () => {
    let out = "";
    skipSpaces();
    while (!EOL && nameChar(next())) out += eat1();
    return out;
  };
  const readQuoted = (quote) => {
    let out = eat1();
    if (out !== quote) fail("parsing quoted string");
    while (!EOL && next() !== quote) {
      if (next() === "\\") eat1();
      out += eat1();
    }
    if (next() !== quote) fail("parsing quoted string");
    out += eat1();
    return out;
  };
  const readRegex = () => {
    if (eat1() !== "/") fail("parsing regular expression");
    let source = "";
    let inClass = false;
    while (!EOL) {
      if (next() === "\\") {
        source += eat1();
        if (EOL) fail("parsing regular expression");
      } else if (inClass && next() === "]") {
        inClass = false;
      } else if (!inClass && next() === "[") {
        inClass = true;
      } else if (!inClass && next() === "/") {
        break;
      }
      source += eat1();
    }
    if (eat1() !== "/") fail("parsing regular expression");
    let flags = "";
    while (!EOL && /[dgimsuy]/.test(next())) flags += eat1();
    const regex = { re: source, f: flags };
    specRegex(regex);
    return regex;
  };
  const readToken = () => {
    skipSpaces();
    const token = next() === "'" || next() === '"' ? readQuoted(next()).slice(1, -1) : readIdentifier();
    if (!token) fail("parsing property path");
    return token;
  };
  const readOperator = () => {
    skipSpaces();
    let op = "";
    if (!EOL) op += eat1();
    if (!EOL && op !== "=") op += eat1();
    if (!["=", "*=", "^=", "$=", "|=", "~="].includes(op)) fail("parsing operator");
    return op;
  };
  const readAttribute = () => {
    eat1();
    const path = [readToken()];
    skipSpaces();
    while (next() === ".") {
      eat1();
      path.push(readToken());
      skipSpaces();
    }
    const name = path.join(".");
    if (next() === "]") {
      eat1();
      return { name, op: "<truthy>", value: null, caseSensitive: false };
    }
    const op = readOperator();
    let value;
    let regex;
    let caseSensitive = true;
    skipSpaces();
    if (next() === "/") {
      if (op !== "=") {
        throw invalidSelector("Error while parsing selector `" + selector + "` - cannot use " + op + " in attribute with regular expression");
      }
      regex = readRegex();
    } else if (next() === "'" || next() === '"') {
      value = readQuoted(next()).slice(1, -1);
      skipSpaces();
      if (next() === "i" || next() === "I") {
        caseSensitive = false;
        eat1();
      } else if (next() === "s" || next() === "S") {
        eat1();
      }
    } else {
      value = "";
      while (!EOL && (nameChar(next()) || next() === "+" || next() === ".")) value += eat1();
      if (value === "true") value = true;
      else if (value === "false") value = false;
    }
    skipSpaces();
    if (next() !== "]") fail("parsing attribute value");
    eat1();
    if (op !== "=" && typeof value !== "string") {
      throw invalidSelector("Error while parsing selector `" + selector + "` - cannot use " + op
        + " in attribute with non-string matching value - " + value);
    }
    return regex ? { name, op, regex, caseSensitive } : { name, op, value, caseSensitive };
  };
  const result = { name: readIdentifier(), attributes: [] };
  skipSpaces();
  while (next() === "[") {
    result.attributes.push(readAttribute());
    skipSpaces();
  }
  if (!EOL) fail();
  if (!result.name && !result.attributes.length) {
    throw invalidSelector("Error while parsing selector `" + selector + "` - selector cannot be empty");
  }
  return result;
}

/** text=…: /re/flags; "x" or 'x' — Playwright's legacy exact rule; else contains, any case. */
function textSelectorStep(body) {
  if (body[0] === "/" && body.lastIndexOf("/") > 0) {
    const last = body.lastIndexOf("/");
    const spec = { re: body.substring(1, last), f: body.substring(last + 1) };
    specRegex(spec);
    return { text: spec };
  }
  const quoted = body.length > 1 && ((body[0] === '"' && body[body.length - 1] === '"')
    || (body[0] === "'" && body[body.length - 1] === "'"));
  if (quoted) return { text: { s: cssUnquote(body), m: "eq" }, legacy: true };
  return { text: { s: body, m: "ci" } };
}

/** An internal:text, has-text or label body: /re/, "x"i (contains, any case), "x"s or "x" (equals). */
function internalText(body) {
  if (body[0] === "/" && body.lastIndexOf("/") > 0) {
    const last = body.lastIndexOf("/");
    const spec = { re: body.substring(1, last), f: body.substring(last + 1) };
    specRegex(spec);
    return spec;
  }
  const json = (text) => {
    try { return String(JSON.parse(text)); } catch (_) { throw invalidSelector("Malformed text: " + body); }
  };
  if (body.length > 1 && body[0] === '"') {
    const end = body[body.length - 1];
    if (end === '"') return { s: json(body), m: "eq" };
    if ((end === "i" || end === "s") && body[body.length - 2] === '"') {
      return { s: json(body.slice(0, -1)), m: end === "i" ? "ci" : "eq" };
    }
  }
  return { s: body, m: "ci" };
}

const ROLE_ATTRIBUTES = ["checked", "disabled", "expanded", "include-hidden", "level", "name", "pressed", "selected"];

/** role=button[name="Save" i][level=2]: Playwright's role engine. internal:role reads name="x"i as contains. */
function roleSelectorStep(body, internal) {
  const parsed = parseAttributes(body);
  const step = { role: parsed.name.toLowerCase() };
  if (!step.role) throw invalidSelector("Role must not be empty");
  for (const attr of parsed.attributes) {
    switch (attr.name) {
      case "checked": case "pressed": case "selected": case "expanded": case "disabled": case "include-hidden": {
        if (attr.op !== "<truthy>" && attr.op !== "=") {
          throw invalidSelector('"' + attr.name + '" does not support "' + attr.op + '" matcher');
        }
        step[attr.name === "include-hidden" ? "includeHidden" : attr.name] = attr.op === "<truthy>" ? true : attr.value;
        break;
      }
      case "level": {
        const value = typeof attr.value === "string" ? Number(attr.value) : attr.value;
        if (attr.op !== "=" || typeof value !== "number" || Number.isNaN(value)) {
          throw invalidSelector('"level" attribute must be compared to a number');
        }
        step.level = value;
        break;
      }
      case "name": {
        if (attr.op === "<truthy>") throw invalidSelector('"name" attribute must have a value');
        if (attr.regex) {
          step.name = attr.regex;
        } else if (typeof attr.value !== "string") {
          throw invalidSelector('"name" attribute must be a string or a regular expression');
        } else if (attr.op === "=") {
          step.name = { s: attr.value, m: attr.caseSensitive ? "eq" : (internal ? "ci" : "eqi") };
        } else if (attr.op === "*=") {
          step.name = { s: attr.value, m: attr.caseSensitive ? "cs" : "ci" };
        } else {
          throw invalidSelector('"name" takes = or *= here, not ' + attr.op);
        }
        break;
      }
      default:
        throw invalidSelector('Unknown attribute "' + attr.name + '", must be one of '
          + ROLE_ATTRIBUTES.map((a) => '"' + a + '"').join(", ") + ".");
    }
  }
  roleOptions(step);
  return step;
}

/** internal:attr=[placeholder|alt|title="x"i], internal:testid=[data-testid="x"s]. */
function attributeSelectorStep(body, engine) {
  const parsed = parseAttributes(body);
  if (parsed.name || parsed.attributes.length !== 1) throw invalidSelector("Malformed attribute selector: " + body);
  const attr = parsed.attributes[0];
  let spec = attr.regex;
  if (!spec && typeof attr.value === "string") spec = { s: attr.value, m: attr.caseSensitive ? "eq" : "ci" };
  if (!spec) throw invalidSelector("Malformed attribute selector: " + body);
  if (engine === "internal:testid") {
    if (attr.name !== "data-testid") throw invalidSelector("only data-testid is a test id here: " + body);
    return { testId: spec };
  }
  if (attr.name === "placeholder" || attr.name === "alt" || attr.name === "title") return { [attr.name]: spec };
  throw invalidSelector("internal:attr takes placeholder, alt or title: " + body);
}

function nestedSelector(name, body) {
  let parsed = null;
  try { parsed = JSON.parse("[" + body + "]"); } catch (_) { parsed = null; }
  if (!Array.isArray(parsed) || parsed.length !== 1 || typeof parsed[0] !== "string") {
    throw invalidSelector("Malformed selector: " + name + "=" + body);
  }
  return parsed[0];
}

const NESTED_ENGINES = { "internal:has": "has", "internal:has-not": "hasNot", "internal:and": "and", "internal:or": "or" };

function selectorSteps(part, whole) {
  const { name, body } = part;
  if (name[0] === "*") throw invalidSelector("the * capture of " + JSON.stringify(whole) + " is not supported");
  switch (name) {
    case "css": {
      const css = body.trim();
      if (!css) throw invalidSelector("an empty part in the selector " + JSON.stringify(whole));
      if (REF_RE.test(css)) return [{ ref: css }];
      checkCSSExtensions(css);
      return [{ css }];
    }
    case "xpath": return [{ xpath: body.trim() }];
    case "text": return [textSelectorStep(body)];
    case "role": return [roleSelectorStep(body, false)];
    case "id": return [{ css: "[id=" + cssQuote(body) + "]" }];
    case "data-testid": case "data-test-id": case "data-test": return [{ css: "[" + name + "=" + cssQuote(body) + "]" }];
    case "aria-ref": {
      const ref = body.trim();
      if (!REF_RE.test(ref)) throw invalidSelector("aria-ref takes a ref of the latest snapshot, like e12: " + JSON.stringify(ref));
      return [{ ref }];
    }
    case "nth": {
      const text = body.trim();
      if (!/^-?\d+$/.test(text)) throw invalidSelector("nth= takes an integer: " + JSON.stringify(text));
      return [{ nth: Number(text) }];
    }
    case "visible": {
      const text = body.trim();
      if (text !== "true" && text !== "false") throw invalidSelector("visible= takes true or false: " + JSON.stringify(text));
      return [{ visible: text === "true" }];
    }
    case "internal:text": return [{ text: internalText(body) }];
    case "internal:has-text": return [{ hasText: internalText(body) }];
    case "internal:has-not-text": return [{ hasText: internalText(body), not: true }];
    case "internal:label": return [{ label: internalText(body) }];
    case "internal:role": return [roleSelectorStep(body, true)];
    case "internal:attr": case "internal:testid": return [attributeSelectorStep(body, name)];
    case "internal:describe": return [];
    case "internal:has": case "internal:has-not": case "internal:and": case "internal:or": {
      const inner = nestedSelector(name, body);
      const locator = { chain: parseSelector(inner), desc: inner };
      const kind = NESTED_ENGINES[name];
      if (kind === "hasNot") return [{ has: locator, not: true }];
      return [{ [kind]: locator }];
    }
    default:
      if (name.startsWith("internal:")) {
        throw invalidSelector(name + " is not supported here: use the getBy… locators of browser_run_code");
      }
      throw invalidSelector('Unknown engine "' + name + '" while parsing selector ' + whole);
  }
}

/**
 * A Playwright selector string → steps (pure: no DOM). Parts joined by
 * `>>`: css= (the default), xpath= (or //…, ..), text= (or "…"), role=,
 * id=, data-testid=, aria-ref= (or a bare e12), nth=, visible=, and the
 * internal: engines Playwright's locators print. Throws {code: "invalid"}.
 */
function parseSelector(text) {
  const whole = String(text == null ? "" : text);
  if (!whole.trim()) throw invalidSelector("the selector is empty");
  const parts = splitSelector(whole);
  const steps = [];
  parts.forEach((part, index) => {
    if (index === 0 && NESTED_ENGINES[part.name]) throw invalidSelector('"' + part.name + '" selector cannot be first');
    for (const step of selectorSteps(part, whole)) steps.push(step);
  });
  if (steps.length > LOCATOR_LIMITS.steps) throw invalidSelector("a selector has " + LOCATOR_LIMITS.steps + " parts at most");
  return steps;
}

// ---------- DOM: text, labels, visibility (Playwright's rules)

function skipForText(node) {
  const doc = node.ownerDocument;
  return node.nodeName === "SCRIPT" || node.nodeName === "NOSCRIPT" || node.nodeName === "STYLE"
    || !!(doc && doc.head && doc.head.contains(node));
}

/** Playwright's elementText: {full, normalized, immediate} — a button input by its value, open shadow roots appended. */
function elementText(cache, root) {
  let value = cache.get(root);
  if (value !== undefined) return value;
  value = { full: "", normalized: "", immediate: [] };
  if (!skipForText(root)) {
    if (root.nodeType === 1 && root.localName === "input" && (root.type === "submit" || root.type === "button")) {
      value = { full: root.value, normalized: normalizeWS(root.value), immediate: [root.value] };
    } else {
      let current = "";
      for (let child = root.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === 3) {
          value.full += child.nodeValue || "";
          current += child.nodeValue || "";
        } else if (child.nodeType !== 8) {
          if (current) value.immediate.push(current);
          current = "";
          if (child.nodeType === 1) value.full += elementText(cache, child).full;
        }
      }
      if (current) value.immediate.push(current);
      if (root.shadowRoot) value.full += elementText(cache, root.shadowRoot).full;
      if (value.full) value.normalized = normalizeWS(value.full);
    }
  }
  cache.set(root, value);
  return value;
}

/** "none" | "self" | "selfAndChildren": whether the text matches here, and also in a child element. */
function matchesText(cache, el, test) {
  if (skipForText(el)) return "none";
  if (!test(elementText(cache, el))) return "none";
  for (let child = el.firstChild; child; child = child.nextSibling) {
    if (child.nodeType === 1 && test(elementText(cache, child))) return "selfAndChildren";
  }
  if (el.shadowRoot && test(elementText(cache, el.shadowRoot))) return "selfAndChildren";
  return "self";
}

/** The elements `aria-labelledby` names, in its tree; null when it names none. */
function labelledByElements(el) {
  const ids = el.getAttribute("aria-labelledby");
  if (ids === null) return null;
  const root = el.getRootNode ? el.getRootNode() : el.ownerDocument;
  const found = [];
  for (const id of ids.split(" ").filter(Boolean)) {
    const target = root && root.getElementById ? root.getElementById(id) : null;
    if (target && !found.includes(target)) found.push(target);
  }
  return found.length ? found : null;
}

/** Playwright's getElementLabels: aria-labelledby, else aria-label, else a labelable element's <label>s. */
function labelTexts(cache, el) {
  const byIds = labelledByElements(el);
  if (byIds) return byIds.map((target) => elementText(cache, target));
  const aria = el.getAttribute("aria-label");
  if (aria !== null && aria.trim()) return [{ full: aria, normalized: normalizeWS(aria), immediate: [aria] }];
  const tag = el.localName;
  const labelable = /^(button|meter|output|progress|select|textarea)$/.test(tag) || (tag === "input" && el.type !== "hidden");
  if (labelable && el.labels) return Array.from(el.labels).map((label) => elementText(cache, label));
  return [];
}

function isVisibleTextNode(node) {
  const range = node.ownerDocument.createRange();
  range.selectNode(node);
  const rect = range.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

/** Playwright's style test: checkVisibility() (display:none at or above, a closed <details>), then visibility. */
function styleVisible(el, style) {
  if (!style) return true;
  if (typeof el.checkVisibility === "function") {
    if (!el.checkVisibility()) return false;
  } else {
    const details = el.closest("details,summary");
    if (details !== el && details && details.localName === "details" && !details.open) return false;
  }
  return style.visibility === "visible";
}

/** Playwright's isElementVisible: styled visible with a box of some size; display:contents through its children. */
function elementVisible(el) {
  const style = styleOf(el);
  if (!style) return true;
  if (style.display === "contents") {
    for (let child = el.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 1 && elementVisible(child)) return true;
      if (child.nodeType === 3 && isVisibleTextNode(child)) return true;
    }
    return false;
  }
  if (!styleVisible(el, style)) return false;
  const rect = el.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function parentOrHost(el) {
  if (el.parentElement) return el.parentElement;
  const parent = el.parentNode;
  return parent && parent.nodeType === 11 && parent.host ? parent.host : null;
}

/**
 * Hidden from assistive technology, as getByRole skips it: Playwright's
 * isElementHiddenForAria, and an inert subtree (the snapshot drops it). A
 * zero-size element is not hidden: sr-only text still matches.
 */
function isHiddenForAria(el, cache) {
  const tag = el.localName;
  if (tag === "style" || tag === "script" || tag === "noscript" || tag === "template") return true;
  const style = styleOf(el);
  const slot = tag === "slot";
  if (style && style.display === "contents" && !slot) {
    for (let child = el.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 1 && !isHiddenForAria(child, cache)) return false;
      if (child.nodeType === 3 && isVisibleTextNode(child)) return false;
    }
    return true;
  }
  const optionInSelect = tag === "option" && !!el.closest("select");
  if (!optionInSelect && !slot && !styleVisible(el, style)) return true;
  return hiddenByAncestry(el, cache);
}

function hiddenByAncestry(el, cache) {
  if (cache && cache.has(el)) return cache.get(el);
  let hidden = !!(el.parentElement && el.parentElement.shadowRoot && !el.assignedSlot);
  if (!hidden) {
    const style = styleOf(el);
    hidden = !style || style.display === "none" || (el.getAttribute("aria-hidden") || "").toLowerCase() === "true"
      || el.hasAttribute("inert");
  }
  if (!hidden) {
    const parent = parentOrHost(el);
    if (parent) hidden = hiddenByAncestry(parent, cache);
  }
  if (cache) cache.set(el, hidden);
  return hidden;
}

// ---------- DOM: ARIA states (Playwright's getAria*, over the snapshot's roleOf)

const ARIA_CHECKED_ROLES = ["checkbox", "menuitemcheckbox", "option", "radio", "switch", "menuitemradio", "treeitem"];
const ARIA_PRESSED_ROLES = ["button"];
const ARIA_SELECTED_ROLES = ["gridcell", "option", "row", "tab", "rowheader", "columnheader", "treeitem"];
const ARIA_EXPANDED_ROLES = ["application", "button", "checkbox", "combobox", "gridcell", "link", "listbox", "menuitem",
  "row", "rowheader", "tab", "treeitem", "columnheader", "menuitemcheckbox", "menuitemradio", "switch"];
const ARIA_LEVEL_ROLES = ["heading", "listitem", "row", "treeitem"];
const ARIA_DISABLED_ROLES = ["application", "button", "composite", "gridcell", "group", "input", "link", "menuitem",
  "scrollbar", "separator", "tab", "checkbox", "columnheader", "combobox", "grid", "listbox", "menu", "menubar",
  "menuitemcheckbox", "menuitemradio", "option", "radio", "radiogroup", "row", "rowheader", "searchbox", "select",
  "slider", "spinbutton", "switch", "tablist", "textbox", "toolbar", "tree", "treegrid", "treeitem"];

/** true | false | "mixed" (when allowed) | "error" (not checkable). */
function ariaChecked(el, role, allowMixed) {
  const input = el.localName === "input";
  if (allowMixed && input && el.indeterminate) return "mixed";
  if (input && (el.type === "checkbox" || el.type === "radio")) return el.checked;
  if (ARIA_CHECKED_ROLES.includes(role)) {
    const value = el.getAttribute("aria-checked");
    if (value === "true") return true;
    if (allowMixed && value === "mixed") return "mixed";
    return false;
  }
  return "error";
}

function ariaPressed(el, role) {
  if (!ARIA_PRESSED_ROLES.includes(role)) return false;
  const value = el.getAttribute("aria-pressed");
  return value === "true" ? true : value === "mixed" ? "mixed" : false;
}

function ariaSelected(el, role) {
  if (el.localName === "option") return el.selected;
  return ARIA_SELECTED_ROLES.includes(role) && (el.getAttribute("aria-selected") || "").toLowerCase() === "true";
}

function ariaExpanded(el, role) {
  if (el.localName === "details") return el.open;
  if (!ARIA_EXPANDED_ROLES.includes(role)) return undefined;
  const value = el.getAttribute("aria-expanded");
  return value === null ? undefined : value === "true";
}

function ariaLevel(el, role) {
  const native = /^h([1-6])$/.exec(el.localName);
  if (native) return Number(native[1]);
  if (ARIA_LEVEL_ROLES.includes(role)) {
    const attr = el.getAttribute("aria-level");
    const value = attr === null ? NaN : Number(attr);
    if (Number.isInteger(value) && value >= 1) return value;
  }
  return 0;
}

function nativelyDisabled(el) {
  if (!/^(button|input|select|textarea|option|optgroup)$/.test(el.localName)) return false;
  if (el.hasAttribute("disabled")) return true;
  if (el.localName === "option" && el.closest("optgroup[disabled]")) return true;
  const fieldset = el.closest("fieldset[disabled]");
  if (!fieldset) return false;
  const legend = fieldset.querySelector(":scope > legend");
  return !legend || !legend.contains(el);
}

function explicitlyDisabled(el, ancestor) {
  if (!el) return false;
  if (ancestor || ARIA_DISABLED_ROLES.includes(roleOf(el) || "")) {
    const value = (el.getAttribute("aria-disabled") || "").toLowerCase();
    if (value === "true") return true;
    if (value === "false") return false;
    return explicitlyDisabled(parentOrHost(el), true);
  }
  return false;
}

function ariaDisabled(el) {
  return nativelyDisabled(el) || explicitlyDisabled(el, false);
}

/** A role step checked as Playwright's role engine does, its name a matcher. Pure. */
function roleOptions(step) {
  const role = String(step.role == null ? "" : step.role).trim().toLowerCase();
  if (!role) throw invalidSelector("Role must not be empty");
  const only = (attr, roles) => {
    if (!roles.includes(role)) {
      throw invalidSelector('"' + attr + '" attribute is only supported for roles: '
        + roles.slice().sort().map((r) => '"' + r + '"').join(", "));
    }
  };
  const among = (attr, value, allowed) => {
    if (!allowed.includes(value)) {
      throw invalidSelector('"' + attr + '" must be one of ' + allowed.map((v) => JSON.stringify(v)).join(", "));
    }
  };
  const options = { role };
  if (step.checked !== undefined) { only("checked", ARIA_CHECKED_ROLES); among("checked", step.checked, [true, false, "mixed"]); options.checked = step.checked; }
  if (step.pressed !== undefined) { only("pressed", ARIA_PRESSED_ROLES); among("pressed", step.pressed, [true, false, "mixed"]); options.pressed = step.pressed; }
  if (step.selected !== undefined) { only("selected", ARIA_SELECTED_ROLES); among("selected", step.selected, [true, false]); options.selected = step.selected; }
  if (step.expanded !== undefined) { only("expanded", ARIA_EXPANDED_ROLES); among("expanded", step.expanded, [true, false]); options.expanded = step.expanded; }
  if (step.level !== undefined) {
    only("level", ARIA_LEVEL_ROLES);
    if (typeof step.level !== "number" || Number.isNaN(step.level)) throw invalidSelector('"level" attribute must be compared to a number');
    options.level = step.level;
  }
  if (step.disabled !== undefined) { among("disabled", step.disabled, [true, false]); options.disabled = step.disabled; }
  if (step.includeHidden !== undefined) { among("include-hidden", step.includeHidden, [true, false]); options.includeHidden = step.includeHidden; }
  if (step.name !== undefined && step.name !== null) options.name = stringMatcher(step.name, true);
  return options;
}

// ---------- engines

/** Every element under `root` (not root): its tree in document order, then each open shadow root's, as Playwright walks. */
function deepElements(root) {
  const out = [];
  const visit = (node) => {
    const shadows = [];
    if (node.shadowRoot) shadows.push(node.shadowRoot);
    for (const el of node.querySelectorAll("*")) {
      out.push(el);
      if (el.shadowRoot) shadows.push(el.shadowRoot);
    }
    for (const shadow of shadows) visit(shadow);
  };
  visit(root);
  return out;
}

/** Splits a selector list on its top-level commas. */
function splitTopLevel(text) {
  const parts = [];
  let depth = 0;
  let quote = "";
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "\\") { i++; continue; }
    if (quote) { if (c === quote) quote = ""; continue; }
    if (c === '"' || c === "'") quote = c;
    else if (c === "(" || c === "[") depth++;
    else if ((c === ")" || c === "]") && depth > 0) depth--;
    else if (c === "," && depth === 0) { parts.push(text.substring(start, i)); start = i + 1; }
  }
  parts.push(text.substring(start));
  return parts;
}

/** Every compound inside the scope, as Playwright matches CSS under an element: `:scope` before each selector of the list. */
function scopedCSS(css) {
  return splitTopLevel(css).map((part) => (/:scope(?![\w-])/.test(part) ? part : ":scope " + part.trim())).join(", ");
}

function checkCSS(css) {
  checkCSSExtensions(css);
  try {
    document.createDocumentFragment().querySelector(/^\s*[>+~]/.test(css) ? ":scope " + css : css);
  } catch (_) {
    throw invalidSelector(JSON.stringify(css) + " is not a valid CSS selector");
  }
}

/**
 * CSS under `scope`: its light tree (an element's: `scopedCSS`), then each
 * open shadow root below, as Playwright orders them. Combinators do not
 * cross a shadow boundary here (Playwright's do).
 */
function queryCSS(scope, css) {
  const out = [];
  const visit = (node, selector) => {
    for (const el of node.querySelectorAll(selector)) out.push(el);
    const shadows = [];
    if (node.shadowRoot) shadows.push(node.shadowRoot);
    for (const el of node.querySelectorAll("*")) if (el.shadowRoot) shadows.push(el.shadowRoot);
    for (const shadow of shadows) visit(shadow, css);
  };
  visit(scope, scope.nodeType === 1 ? scopedCSS(css) : css);
  return out;
}

function queryXPath(scope, xpath) {
  const expression = xpath.startsWith("/") && scope.nodeType !== 9 ? "." + xpath : xpath;
  const doc = scope.ownerDocument || scope;
  let result;
  try {
    result = doc.evaluate(expression, scope, null, 7 /* ORDERED_NODE_SNAPSHOT_TYPE */, null);
  } catch (_) {
    throw invalidSelector(JSON.stringify(xpath) + " is not a valid XPath expression");
  }
  const out = [];
  for (let i = 0; i < result.snapshotLength; i++) {
    const node = result.snapshotItem(i);
    if (node && node.nodeType === 1) out.push(node);
  }
  return out;
}

/** A ref of the latest snapshot, inside the scope (anywhere, a same-origin frame included, from the document). */
function queryRef(scope, ref) {
  const weak = latest.get(ref);
  const el = weak && weak.deref();
  if (!el || !el.isConnected) return [];
  if (scope.nodeType === 1 && (el === scope || !containsDeep(scope, el))) return [];
  return [el];
}

/** Playwright's queryRole over the snapshot's roles and names. */
function queryRole(scope, options, ctx) {
  const out = [];
  for (const el of deepElements(scope)) {
    const role = roleOf(el);
    if (role !== options.role) continue;
    if (options.selected !== undefined && ariaSelected(el, role) !== options.selected) continue;
    if (options.checked !== undefined && ariaChecked(el, role, true) !== options.checked) continue;
    if (options.pressed !== undefined && ariaPressed(el, role) !== options.pressed) continue;
    if (options.expanded !== undefined && ariaExpanded(el, role) !== options.expanded) continue;
    if (options.level !== undefined && ariaLevel(el, role) !== options.level) continue;
    if (options.disabled !== undefined && ariaDisabled(el) !== options.disabled) continue;
    if (!options.includeHidden && isHiddenForAria(el, ctx.hidden)) continue;
    if (options.name && !options.name(accessibleNameRaw(el, role))) continue;
    out.push(el);
  }
  return out;
}

/** Playwright's internal:text — the scope itself included; an element whose children match is left to them. */
function queryText(scope, test, ctx) {
  const out = [];
  let lastNone = null;
  const append = (el) => {
    if (test.kind === "lax" && lastNone && lastNone.contains(el)) return;
    const match = matchesText(ctx.text, el, test.test);
    if (match === "none") lastNone = el;
    if (match === "self" || (match === "selfAndChildren" && test.legacy)) out.push(el);
  };
  if (scope.nodeType === 1) append(scope);
  for (const el of deepElements(scope)) append(el);
  return out;
}

const STEP_KINDS = ["css", "xpath", "ref", "selector", "role", "text", "label", "placeholder", "alt", "title", "testId",
  "hasText", "has", "visible", "nth", "and", "or"];

function stepKind(step) {
  if (step && typeof step === "object" && !Array.isArray(step)) {
    for (const kind of STEP_KINDS) {
      if (Object.prototype.hasOwnProperty.call(step, kind)) return kind;
    }
  }
  throw invalidSelector("not a locator step: " + String(JSON.stringify(step)).slice(0, 200));
}

/** (scope, ctx) => elements for a query step, its matchers built once. */
function queryFor(step, kind) {
  switch (kind) {
    case "css": {
      const css = String(step.css);
      checkCSS(css);
      return (scope) => queryCSS(scope, css);
    }
    case "xpath": {
      const xpath = String(step.xpath).trim();
      if (!xpath) throw invalidSelector("an empty XPath");
      return (scope) => queryXPath(scope, xpath);
    }
    case "ref": {
      const ref = String(step.ref).trim();
      return (scope) => queryRef(scope, ref);
    }
    case "role": {
      const options = roleOptions(step);
      return (scope, ctx) => queryRole(scope, options, ctx);
    }
    case "text": {
      const test = textTest(step.text, step.legacy === true);
      return (scope, ctx) => queryText(scope, test, ctx);
    }
    case "label": {
      const test = textTest(step.label);
      return (scope, ctx) => deepElements(scope).filter((el) => labelTexts(ctx.text, el).some((et) => test.test(et)));
    }
    case "placeholder": case "alt": case "title": case "testId": {
      // getByTestId is exact, whatever the spec says: Playwright's always is.
      let spec = textSpec(step[kind]);
      if (kind === "testId" && spec.re === undefined) spec = { s: spec.s, m: "eq" };
      const match = stringMatcher(spec, false);
      const name = kind === "testId" ? "data-testid" : kind;
      return (scope) => deepElements(scope).filter((el) => el.hasAttribute(name) && match(el.getAttribute(name)));
    }
    default:
      throw invalidSelector("not a locator step: " + kind);
  }
}

function locatorOf(value) {
  if (value && typeof value === "object" && Array.isArray(value.chain)) return value;
  throw invalidSelector("a locator is {chain: [steps], desc}: " + String(JSON.stringify(value)).slice(0, 200));
}

/** Playwright's sortInDOMOrder: shadow trees after their host's children. */
function sortInDOMOrder(elements) {
  const entries = new Map();
  const roots = [];
  const out = [];
  const append = (el) => {
    let entry = entries.get(el);
    if (entry) return entry;
    const parent = el.nodeType === 1 ? parentOrHost(el) : null;
    entry = { children: [], taken: false };
    if (parent) append(parent).children.push(el);
    else roots.push(el);
    entries.set(el, entry);
    return entry;
  };
  for (const el of elements) append(el).taken = true;
  const visit = (el) => {
    const entry = entries.get(el);
    if (entry.taken) out.push(el);
    if (entry.children.length > 1) {
      const set = new Set(entry.children);
      entry.children = [];
      for (let child = el.firstElementChild; child && entry.children.length < set.size; child = child.nextElementSibling) {
        if (set.has(child)) entry.children.push(child);
      }
      for (let child = el.shadowRoot ? el.shadowRoot.firstElementChild : null;
           child && entry.children.length < set.size; child = child.nextElementSibling) {
        if (set.has(child)) entry.children.push(child);
      }
    }
    entry.children.forEach(visit);
  };
  roots.forEach(visit);
  return out;
}

/**
 * A chain checked and its matchers built, before anything runs: selector
 * steps parsed, 32 steps a chain, has/and/or 4 deep — whatever the page
 * holds (an inner chain runs only where its outer one matched).
 */
function compileChain(chain, depth) {
  if (!Array.isArray(chain)) throw invalidSelector("a locator's chain is an array of steps");
  if (depth > LOCATOR_LIMITS.depth) throw invalidSelector("has, and and or nest " + LOCATOR_LIMITS.depth + " deep at most");
  const steps = [];
  for (const step of chain) {
    if (step && typeof step === "object" && typeof step.selector === "string") steps.push(...parseSelector(step.selector));
    else steps.push(step);
  }
  if (steps.length > LOCATOR_LIMITS.steps) throw invalidSelector("a locator has " + LOCATOR_LIMITS.steps + " steps at most");
  return steps.map((step) => compileStep(step, depth));
}

function compileStep(step, depth) {
  const kind = stepKind(step);
  switch (kind) {
    case "nth":
      if (!Number.isInteger(step.nth)) throw invalidSelector("nth takes an integer: " + JSON.stringify(step.nth));
      return { kind, nth: step.nth };
    case "visible":
      return { kind, visible: step.visible !== false };
    case "hasText":
      return { kind, test: textTest(step.hasText), not: !!step.not };
    case "has":
      return { kind, inner: compileChain(locatorOf(step.has).chain, depth + 1), not: !!step.not };
    case "and": case "or":
      return { kind, inner: compileChain(locatorOf(step[kind]).chain, depth + 1) };
    default:
      return { kind, query: queryFor(step, kind) };
  }
}

/** One compiled step over the current set: a query from each element (deduped, in scope order) or a filter. */
function applyStep(set, step, root, ctx) {
  switch (step.kind) {
    case "nth": {
      const index = step.nth < 0 ? set.length + step.nth : step.nth;
      return index >= 0 && index < set.length ? [set[index]] : [];
    }
    case "visible":
      return set.filter((el) => el.nodeType === 1 && elementVisible(el) === step.visible);
    case "hasText":
      return set.filter((el) => el.nodeType === 1 && step.test.test(elementText(ctx.text, el)) !== step.not);
    case "has":
      // Playwright's internal:has: the inner chain from the element, its and/or too.
      return set.filter((el) => el.nodeType === 1 && (runChain(step.inner, [el], el, ctx).length > 0) !== step.not);
    case "and": {
      const other = new Set(runChain(step.inner, [root], root, ctx));
      return set.filter((el) => other.has(el));
    }
    case "or":
      return sortInDOMOrder(Array.from(new Set(set.concat(runChain(step.inner, [root], root, ctx)))));
    default: {
      const next = new Set();
      for (const scope of set) {
        for (const el of step.query(scope, ctx)) next.add(el);
      }
      return Array.from(next);
    }
  }
}

function runChain(steps, scopes, root, ctx) {
  let set = scopes.slice();
  for (const step of steps) set = applyStep(set, step, root, ctx);
  return set;
}

/** {elements} (engine order, never strict) | {error: {code: "invalid", message}}; from the document unless `scopes`. */
function resolveLocator(locator, scopes) {
  const ctx = { text: new Map(), hidden: new Map() };
  try {
    const t = locatorOf(locator);
    let size = 0;
    try { size = JSON.stringify(t).length; } catch (_) { size = Infinity; }
    if (size > LOCATOR_LIMITS.bytes) throw invalidSelector("a locator is " + LOCATOR_LIMITS.bytes + " bytes at most");
    const steps = compileChain(t.chain, 0);
    const roots = scopes && scopes.length ? scopes : [document];
    const elements = runChain(steps, roots, roots[0], ctx).filter((el) => el && el.nodeType === 1);
    return { elements };
  } catch (error) {
    return { error: { code: "invalid", message: messageOf(error) } };
  }
}

function locatorDescription(t) {
  const desc = t && typeof t.desc === "string" && t.desc ? t.desc : "locator";
  return desc.length > 500 ? desc.slice(0, 499) + "…" : desc;
}

/** The refs of the latest snapshot, by element. */
function latestRefs() {
  const refs = new Map();
  for (const [ref, weak] of latest) {
    const el = weak.deref();
    if (el) refs.set(el, ref);
  }
  return refs;
}

/** Playwright's strict-mode message: at most 10 elements, each with its ref when the latest snapshot has one. */
function strictViolation(desc, elements) {
  const refs = latestRefs();
  const lines = elements.slice(0, LOCATOR_LIMITS.lines).map((el, i) =>
    "    " + (i + 1) + ") " + describe(el) + (refs.has(el) ? " [ref=" + refs.get(el) + "]" : ""));
  if (elements.length > LOCATOR_LIMITS.lines) lines.push("    … and " + (elements.length - LOCATOR_LIMITS.lines) + " more");
  return "strict mode violation: " + desc + " resolved to " + elements.length + " elements:\n" + lines.join("\n");
}

/**
 * A structured target {chain, desc, strict, wait}: one element, or
 * notFound (`retry` unless `wait` is false: the caller polls), ambiguous
 * when strict (the default) and more than one match, invalid.
 */
function resolveObjectTarget(t) {
  const resolved = resolveLocator(t);
  if (resolved.error) return resolved;
  const desc = locatorDescription(t);
  const elements = resolved.elements;
  if (!elements.length) {
    if (t.wait === false) return { error: { code: "notFound", message: JSON.stringify(desc) + " does not match any elements." } };
    return { error: { code: "notFound", retry: true, message: "waiting for " + desc } };
  }
  if (elements.length > 1 && t.strict !== false) {
    return { error: { code: "ambiguous", message: strictViolation(desc, elements) } };
  }
  return { element: elements[0] };
}

/** A string that is no CSS: a Playwright selector, resolved strictly and without waiting. */
function resolveSelectorString(text) {
  let chain;
  try {
    chain = parseSelector(text);
  } catch (error) {
    return { error: { code: "invalid", message: JSON.stringify(text) + " is neither a ref (e12) nor a valid selector: " + messageOf(error) } };
  }
  return { chain };
}

/** Every match of a target, never strict: a locator, a ref, CSS (the light DOM, as a browser tool's) or a selector string. */
function resolveAll(target) {
  if (target && typeof target === "object") return resolveLocator(target);
  const text = String(target || "").trim();
  if (!text) return { error: { code: "invalid", message: "a target is required: a ref from browser_snapshot or a selector" } };
  if (REF_RE.test(text)) {
    const weak = latest.get(text);
    const el = weak && weak.deref();
    return { elements: el && el.isConnected ? [el] : [] };
  }
  let matches = null;
  try { matches = document.querySelectorAll(text); } catch (_) { matches = null; }
  if (matches) return { elements: Array.from(matches) };
  const parsed = resolveSelectorString(text);
  if (parsed.error) return parsed;
  const resolved = resolveLocator({ chain: parsed.chain, desc: text });
  if (resolved.error) resolved.error.message = JSON.stringify(text) + " is neither a ref (e12) nor a valid selector: " + resolved.error.message;
  return resolved;
}

/** resolveAll's elements, one of them demanded: the strict-mode error when the target is strict and more match. */
function ambiguity(target, elements) {
  if (elements.length < 2) return null;
  if (target && typeof target === "object") {
    if (target.strict === false) return null;
    return { error: { code: "ambiguous", message: strictViolation(locatorDescription(target), elements) } };
  }
  return { error: { code: "ambiguous", message: strictViolation(String(target).trim(), elements) } };
}

// ---------------------------------------------------------------- targets

/**
 * A ref, CSS, a Playwright selector string (strict, no wait) — or a
 * structured target {chain, desc, strict, wait} (resolveObjectTarget).
 */
function resolveTarget(target) {
  if (target && typeof target === "object") return resolveObjectTarget(target);
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
    // Not CSS: a Playwright selector? (None of them is valid CSS.)
    const parsed = resolveSelectorString(text);
    if (parsed.error) return parsed;
    const resolved = resolveObjectTarget({ chain: parsed.chain, desc: text, strict: true, wait: false });
    if (resolved.error && resolved.error.code === "invalid") {
      resolved.error.message = JSON.stringify(text) + " is neither a ref (e12) nor a valid selector: " + resolved.error.message;
    }
    return resolved;
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
  // A value is a string (value, then label), or Playwright's {value},
  // {label} or {index}.
  const wanted = (args.values || []).map((value) => (value && typeof value === "object" ? value : String(value)));
  if (!wanted.length) return { error: { code: "invalid", message: "values must name at least one option" } };
  if (wanted.length > 1 && !el.multiple) return { error: { code: "invalid", message: "this <select> takes one value" } };
  const options = Array.from(el.options);
  const picked = [];
  for (const value of wanted) {
    let option;
    if (typeof value === "object") {
      if (value.value != null) option = options.find((o) => o.value === String(value.value));
      else if (value.label != null) option = options.find((o) => o.label === String(value.label));
      else if (value.index != null) option = options[Number(value.index)];
    } else {
      option = options.find((o) => o.value === value)
        || options.find((o) => collapse(o.label || o.textContent) === collapse(value))
        || options.find((o) => collapse(o.label || o.textContent).toLowerCase() === collapse(value).toLowerCase());
    }
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
  return { ok: true, description: describe(el), selected: picked.map((o) => collapse(o.label || o.textContent)),
    values: picked.map((o) => o.value) };
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

function newNonce() {
  return "n" + Math.random().toString(36).slice(2) + Date.now().toString(36);
}

/** Marks the target for a page-world function: only DOM state crosses worlds. */
function stamp(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const nonce = newNonce();
  resolved.element.setAttribute("data-loom-eval", nonce);
  return { ok: true, nonce, description: describe(resolved.element) };
}

// ---------------------------------------------------------------- Chromium
// What only Loom's Chromium engine asks (ADR-0016): its input is real
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

// ---------------------------------------------------------------- locator ops
// What browser_run_code's locators read and wait on (design §4.3). Each
// takes `target`: a locator {chain, desc, strict, wait}, or a string as
// the browser tools take it. count, readAll and stampAll are never strict;
// read, state, focus and blur are (unless strict: false).

function invalid(message) {
  return { error: { code: "invalid", message } };
}

function cutText(value) {
  if (value == null) return null;
  const text = String(value);
  return text.length > LOCATOR_LIMITS.chars ? text.slice(0, LOCATOR_LIMITS.chars) : text;
}

/** Playwright's retarget: a label's control for "follow-label" (a state of a field read through its label). */
function retarget(el, behavior) {
  if (behavior === "none") return el;
  let element = el;
  if (!element.matches("input, textarea, select") && !element.isContentEditable) {
    element = element.closest("button, [role=button], [role=checkbox], [role=radio]") || element;
  }
  if (behavior === "follow-label"
      && !element.matches("a, input, textarea, button, select, [role=link], [role=button], [role=checkbox], [role=switch], [role=radio]")
      && !element.isContentEditable) {
    const label = element.closest("label");
    if (label && label.control) element = label.control;
  }
  return element;
}

/** Playwright's getReadonly: true | false | "error" (nothing that can be read-only). */
function readOnlyState(el) {
  if (/^(input|textarea|select)$/.test(el.localName)) return el.hasAttribute("readonly");
  if (["checkbox", "combobox", "grid", "gridcell", "listbox", "radiogroup", "slider", "spinbutton", "textbox",
       "columnheader", "rowheader", "searchbox", "switch", "treegrid"].includes(roleOf(el) || "")) {
    return el.getAttribute("aria-readonly") === "true";
  }
  if (el.isContentEditable) return false;
  return "error";
}

/** One reading of one element: {value} or {error}. */
function readValue(el, what, name) {
  switch (what) {
    case "textContent": return { value: cutText(el.textContent) };
    case "innerText":
      if (typeof el.innerText !== "string") return invalid("Node is not an HTMLElement");
      return { value: cutText(el.innerText) };
    case "innerHTML": return { value: cutText(el.innerHTML) };
    case "attribute":
      if (typeof name !== "string" || !name) return invalid("attribute needs a name");
      return { value: cutText(el.getAttribute(name)) };
    case "inputValue": {
      const field = retarget(el, "follow-label");
      if (!/^(input|textarea|select)$/.test(field.localName)) return invalid("Not an <input>, <textarea> or <select> element");
      return { value: cutText(field.value) };
    }
    case "boundingBox": {
      if (!el.getClientRects().length) return { value: null };
      const r = topRect(el);
      return { value: { x: r.left, y: r.top, width: r.width, height: r.height } };
    }
    case "checked": {
      const field = retarget(el, "follow-label");
      const checked = ariaChecked(field, roleOf(field), false);
      if (checked === "error") return invalid("Not a checkbox or radio button");
      return { value: checked };
    }
    case "editable": {
      const field = retarget(el, "follow-label");
      const readOnly = readOnlyState(field);
      if (readOnly === "error") {
        return invalid("Element is not an <input>, <textarea>, <select> or [contenteditable] and does not have a role allowing [aria-readonly]");
      }
      return { value: !readOnly && !ariaDisabled(field) };
    }
    case "visible": return { value: elementVisible(el) };
    case "hidden": return { value: !elementVisible(el) };
    case "enabled": return { value: !ariaDisabled(retarget(el, "follow-label")) };
    case "disabled": return { value: ariaDisabled(retarget(el, "follow-label")) };
    default: return invalid("unknown reading " + JSON.stringify(what));
  }
}

/** → {ok, count}: no wait, never strict. */
function count(args) {
  const resolved = resolveAll(args.target);
  if (resolved.error) return resolved;
  return { ok: true, count: resolved.elements.length };
}

/**
 * `what`: textContent | innerText | innerHTML | inputValue | attribute
 * (`name`) | boundingBox | checked | editable (and the states) → {ok,
 * value}: strings cut at 100 000, a box in the top viewport's CSS pixels
 * (null without one). Zero matches: notFound, with `retry` for a locator.
 */
function read(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  const answer = readValue(resolved.element, args.what, args.name);
  return answer.error ? answer : { ok: true, value: answer.value };
}

/** Every match's reading (allTextContents, allInnerTexts) → {ok, value: []}: 1000 items, 1 000 000 characters at most. */
function readAll(args) {
  const resolved = resolveAll(args.target);
  if (resolved.error) return resolved;
  const value = [];
  let total = 0;
  let truncated = false;
  for (const el of resolved.elements) {
    if (value.length >= LOCATOR_LIMITS.items || total >= LOCATOR_LIMITS.total) { truncated = true; break; }
    const answer = readValue(el, args.what, args.name);
    if (answer.error) return answer;
    value.push(answer.value);
    total += typeof answer.value === "string" ? answer.value.length : 0;
  }
  return truncated ? { ok: true, value, truncated } : { ok: true, value };
}

/**
 * visible | hidden | enabled | disabled | checked | editable → {ok, value},
 * at once. Zero matches: visible false, hidden true; the others notFound.
 */
function state(args) {
  const what = args.what;
  if (!/^(visible|hidden|enabled|disabled|checked|editable)$/.test(String(what))) return invalid("unknown state " + JSON.stringify(what));
  const resolved = resolveAll(args.target);
  if (resolved.error) return resolved;
  const elements = resolved.elements;
  const many = ambiguity(args.target, elements);
  if (many) return many;
  let el = elements[0];
  if (!el) {
    if (what === "visible" || what === "hidden") return { ok: true, value: what === "hidden" };
    const missing = resolveTarget(args.target);   // its notFound, worded for the target
    if (missing.error) return missing;
    el = missing.element;
  }
  const answer = readValue(el, what);
  return answer.error ? answer : { ok: true, value: answer.value };
}

const WAIT_STATES = new Set(["attached", "detached", "visible", "hidden"]);

/**
 * attached | detached | visible | hidden → {ok, done, count}. Checked now,
 * then a frame after each DOM change (subtree, childList, attributes,
 * characterData) — at most once a frame — and every 250 ms for what no
 * observer sees (a shadow tree, a stylesheet), until done or `maxMs`
 * (2000 by default and at most: Loom asks again). A strict target that
 * matches several is the strict-mode error, as Playwright's waitFor.
 */
function waitState(args) {
  const want = args.state == null ? "visible" : String(args.state);
  if (!WAIT_STATES.has(want)) return invalid("state is attached, detached, visible or hidden, not " + JSON.stringify(args.state));
  const check = () => {
    const resolved = resolveAll(args.target);
    if (resolved.error) return resolved;
    const elements = resolved.elements;
    const many = ambiguity(args.target, elements);
    if (many) return many;
    const first = elements[0];
    let done;
    if (want === "attached") done = !!first;
    else if (want === "detached") done = !first;
    else if (want === "visible") done = !!first && elementVisible(first);
    else done = !first || !elementVisible(first);
    return { ok: true, done, count: elements.length };
  };
  const now = check();
  if (now.error || now.done) return now;
  const raw = args.maxMs == null ? NaN : Number(args.maxMs);
  const maxMs = Number.isFinite(raw) ? Math.min(Math.max(raw, 0), 2000) : 2000;
  if (maxMs === 0) return now;
  return new Promise((resolve) => {
    let finished = false;
    let pending = false;
    let timer = 0;
    let poll = 0;
    let observer = null;
    const finish = (answer) => {
      if (finished) return;
      finished = true;
      if (observer) observer.disconnect();
      clearTimeout(timer);
      clearInterval(poll);
      resolve(answer);
    };
    const later = () => {
      if (pending || finished) return;
      pending = true;
      oneFrame().then(() => {
        pending = false;
        if (finished) return;
        const answer = check();
        if (answer.error || answer.done) finish(answer);
      });
    };
    observer = new MutationObserver(later);
    observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
    poll = setInterval(later, 250);
    timer = setTimeout(() => finish(check()), maxMs);
  });
}

/** Focuses the target, without scrolling. */
function focus(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  resolved.element.focus({ preventScroll: true });
  return { ok: true, description: describe(resolved.element), focused: describe(deepActiveElement(document)) };
}

function blur(args) {
  const resolved = resolveTarget(args.target);
  if (resolved.error) return resolved;
  resolved.element.blur();
  return { ok: true, description: describe(resolved.element), focused: describe(deepActiveElement(document)) };
}

/**
 * Every match gets data-loom-eval=<nonce>, for a page-world evaluateAll →
 * {ok, nonce, count}. `keys` (tests): each match's data-k, in engine order.
 */
function stampAll(args) {
  const resolved = resolveAll(args.target);
  if (resolved.error) return resolved;
  const nonce = newNonce();
  for (const el of resolved.elements) el.setAttribute("data-loom-eval", nonce);
  const answer = { ok: true, nonce, count: resolved.elements.length };
  if (args.keys === true) answer.keys = resolved.elements.map((el) => el.getAttribute("data-k"));
  return answer;
}

const OPS = { snapshot, prepare, click, hover, type, selectOption, pressKey, waitText, rect, pageInfo, stamp,
  setChecked, setValue, focusField, typeKeys, scrollTo, barrier, documentRect, dispatchCancel,
  count, read, readAll, state, waitState, focus, blur, stampAll };

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
    _pure: Object.freeze({ collapse, truncate, yamlScalar, nodeHead, renderTree, REF_RE,
      normalizeWS, stringMatcher, parseSelector }),
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

    /// The function every helper call runs in Chromium (ADR-0016, design
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
