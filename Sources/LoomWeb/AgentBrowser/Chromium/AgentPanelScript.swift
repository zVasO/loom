import Foundation

/// The page side of the interactive panel (design panel.md §2): what the
/// person's input needs to know of the page that a frame cannot show, and
/// the few things CDP input cannot do.
///
/// Installed by the engine in the helper's own world, as the helper is:
/// `Page.addScriptToEvaluateOnNewDocument {source, worldName: "loom-agent",
/// runImmediately: true}`, then reached with `Runtime.callFunctionOn` in the
/// world `Page.createIsolatedWorld` returns, `callFunction` as the function,
/// `[op, arg]` as its arguments, `returnByValue: true`. Its globals are
/// invisible to the page; the only traces it leaves are its `copy`, `cut`
/// and `keydown` listeners on `window` (none cancels or stops anything),
/// and a mirror `<div>` added and removed in the same task while
/// `caretRect` measures a `<textarea>` (a MutationObserver sees it).
///
/// Every op takes one JSON value and answers one (`{error: {code, message}}`
/// when it cannot):
/// - `hitInfo({x, y, select?})` → `{cursor, editable, link, select?}` under a
///   point in CSS px of the main frame (open shadow roots and same-origin
///   frames pierced). `cursor` is the CSS keyword (`url(…)` dropped for its
///   fallback, `-webkit-` dropped); `editable` and `link` say what `auto`
///   means there. `select` (left out with `select: false`) describes a
///   `<select>` whose picker is native: `{rect: {x, y, width, height},
///   options: [{label, value, disabled, group?}], selectedIndex, multiple,
///   disabled, size, open}` — the panel shows its own menu for a one-line
///   one (`!multiple && size <= 1`); `open`: a press that reached it opened
///   Chromium's own popup, which no frame shows.
/// - `caretRect()` → `{x, y, width, height}` of the focused field's caret,
///   in CSS px of the main frame, or null when nothing editable has focus.
/// - `takeCopied()` → `{text, type, ageMs}` of the last trusted `copy` or
///   `cut` (what Chromium put on its clipboard), then forgets it; null if
///   none since.
/// - `firePaste({text})` → `{cancelled}`: a `paste` event carrying `text` on
///   the focused element. Not cancelled: the caller sends `Input.insertText`.
/// - `chooseUserSelect({index})` → `{ok, changed, value, selectedIndex}`:
///   the option the person picked in the panel's menu, set as the agent's
///   `selectOption` sets it (focus, then `input` and `change`).
///
/// The Node tests (`Tests/AgentBrowserCDP/panel-input.test.mjs`) read both
/// literals out of this file and run them in a real Chromium: each must stay
/// a `#"""` raw string, its lines at column 0.
enum AgentPanelScript {

    static let source: String = #"""
(() => {
"use strict";
// Main frame only; once per document (the engine may install it twice).
if (window !== window.top) return;
if (Object.prototype.hasOwnProperty.call(globalThis, "__loomPanel")) return;

const VERSION = 1;
const TEXT_TYPES = new Set(["text", "search", "url", "tel", "email", "password", "number"]);

function fail(code, message) {
  return { error: { code, message } };
}

function collapse(text) {
  return String(text == null ? "" : text).replace(/\s+/g, " ").trim();
}

function styleOf(el) {
  const view = (el.ownerDocument && el.ownerDocument.defaultView) || window;
  return view.getComputedStyle(el);
}

function px(value) {
  const number = parseFloat(value);
  return Number.isFinite(number) ? number : 0;
}

/** The parent in the flat tree: a slot, the element's parent, a shadow root's host. */
function flatParent(node) {
  if (node.assignedSlot) return node.assignedSlot;
  if (node.parentElement) return node.parentElement;
  const root = node.getRootNode ? node.getRootNode() : null;
  return root && root.host ? root.host : null;
}

function isTextField(el) {
  if (!el || el.nodeType !== 1) return false;
  if (el.localName === "textarea") return true;
  return el.localName === "input" && TEXT_TYPES.has(el.type);
}

/** Where `cursor: auto` is an I-beam: a text field that is not disabled, or editable content. */
function isEditable(el) {
  if (isTextField(el)) return !el.disabled;
  return el.isContentEditable === true;
}

/** Where `cursor: auto` is a pointing hand: inside a link. */
function isLink(el) {
  for (let node = el; node; node = flatParent(node)) {
    if ((node.localName === "a" || node.localName === "area") && node.hasAttribute("href")) return true;
  }
  return false;
}

/** The computed cursor keyword: the fallback after any url(…), without -webkit-. */
function cursorOf(el) {
  let value = "";
  try { value = String(styleOf(el).cursor || ""); } catch (error) { value = ""; }
  const comma = value.lastIndexOf(",");
  if (comma >= 0) value = value.slice(comma + 1);
  value = value.trim().toLowerCase().replace(/^-webkit-/, "");
  return value || "auto";
}

function frameDocument(el) {
  if (el.localName !== "iframe" && el.localName !== "frame") return null;
  try { return el.contentDocument || null; } catch (error) { return null; }
}

/** A frame element's content box, where its document's viewport starts. */
function contentOrigin(el) {
  const rect = el.getBoundingClientRect();
  const style = styleOf(el);
  return { x: rect.left + el.clientLeft + px(style.paddingLeft), y: rect.top + el.clientTop + px(style.paddingTop) };
}

/** The deepest element under a main-frame point, and its document's offset in the main frame. */
function hitAt(x, y) {
  let px0 = x, py0 = y, ox = 0, oy = 0;
  let el = document.elementFromPoint(x, y);
  for (let hops = 0; el && hops < 32; hops++) {
    if (el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(px0, py0);
      if (inner && inner !== el) { el = inner; continue; }
    }
    const child = frameDocument(el);
    if (!child) break;
    const origin = contentOrigin(el);
    const inner = child.elementFromPoint(px0 - origin.x, py0 - origin.y);
    if (!inner) break;
    px0 -= origin.x; py0 -= origin.y; ox += origin.x; oy += origin.y;
    el = inner;
  }
  return el ? { el, ox, oy } : null;
}

/** The focused element, through open shadow roots and same-origin frames. */
function deepActive() {
  let ox = 0, oy = 0;
  let el = document.activeElement;
  for (let hops = 0; el && hops < 32; hops++) {
    if (el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
    const child = frameDocument(el);
    if (!child || !child.activeElement) break;
    const origin = contentOrigin(el);
    ox += origin.x; oy += origin.y;
    el = child.activeElement;
  }
  return el ? { el, ox, oy } : null;
}

function rectAt(rect, ox, oy) {
  return { x: rect.left + ox, y: rect.top + oy, width: rect.width, height: rect.height };
}

/** A <select> whose picker Chromium draws outside the page (none for appearance: base-select). */
function nativeSelect(el) {
  const select = el.closest ? el.closest("select") : null;
  if (!select) return null;
  try { if (styleOf(select).appearance === "base-select") return null; } catch (error) { /* a plain one */ }
  return select;
}

function describeSelect(select, ox, oy) {
  const options = [];
  for (const option of Array.from(select.options)) {
    const parent = option.parentElement;
    const entry = { label: collapse(option.label), value: option.value, disabled: option.matches(":disabled") };
    if (parent && parent.localName === "optgroup") entry.group = collapse(parent.label);
    options.push(entry);
  }
  return {
    rect: rectAt(select.getBoundingClientRect(), ox, oy),
    options,
    selectedIndex: select.selectedIndex,
    multiple: select.multiple,
    disabled: select.matches(":disabled"),
    size: select.size,
    open: isOpen(select),
  };
}

/** Its picker is showing: after a press that reached it, Chromium's popup is open but never drawn in a frame. */
function isOpen(select) {
  try { return select.matches(":open"); } catch (error) { return false; }
}

let lastHit = null;

function hitInfo(args) {
  const x = Number(args && args.x);
  const y = Number(args && args.y);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return fail("invalid", "x and y must be numbers");
  const hit = hitAt(x, y);
  const select = hit ? nativeSelect(hit.el) : null;
  lastHit = { x, y, select: select ? new WeakRef(select) : null };
  if (!hit) return { cursor: "auto", editable: false, link: false };
  const info = { cursor: cursorOf(hit.el), editable: isEditable(hit.el), link: isLink(hit.el) };
  if (select && !(args && args.select === false)) info.select = describeSelect(select, hit.ox, hit.oy);
  return info;
}

// ---------------------------------------------------------------- caret

/** The element's bottom-left: where an input method's window goes when the caret is unknown. */
function bottomLeft(el) {
  const rect = el.getBoundingClientRect();
  return { x: rect.left, y: rect.bottom, width: 0, height: 0 };
}

function lineHeightOf(style) {
  const line = px(style.lineHeight);
  return line > 0 ? line : px(style.fontSize) * 1.2;
}

/** An <input>: its text measured on a canvas (nothing added to the page). */
function inputCaret(el, caret) {
  const style = styleOf(el);
  const canvas = typeof OffscreenCanvas === "function" ? new OffscreenCanvas(1, 1) : el.ownerDocument.createElement("canvas");
  const context = canvas.getContext("2d");
  if (!context) return null;
  context.font = [style.fontStyle, style.fontWeight, style.fontSize, style.fontFamily].join(" ");
  if (style.letterSpacing && style.letterSpacing !== "normal" && "letterSpacing" in context) context.letterSpacing = style.letterSpacing;
  const shown = el.type === "password" ? "\u2022".repeat(el.value.length) : el.value;
  const before = context.measureText(shown.slice(0, caret)).width;
  const whole = context.measureText(shown).width;
  const rect = el.getBoundingClientRect();
  const left = rect.left + el.clientLeft + px(style.paddingLeft);
  const width = el.clientWidth - px(style.paddingLeft) - px(style.paddingRight);
  const rtl = style.direction === "rtl";
  const align = style.textAlign;
  let shift = 0;
  if (whole < width) {
    if (align === "center" || align === "-webkit-center") shift = (width - whole) / 2;
    else if (align === "right" || (align === "end" && !rtl) || (align === "start" && rtl)) shift = width - whole;
  }
  const metrics = context.measureText(shown || "M");
  const ascent = metrics.fontBoundingBoxAscent;
  const descent = metrics.fontBoundingBoxDescent;
  const height = Number.isFinite(ascent) && Number.isFinite(descent) ? ascent + descent : px(style.fontSize) * 1.2;
  const top = rect.top + el.clientTop + px(style.paddingTop);
  const inner = el.clientHeight - px(style.paddingTop) - px(style.paddingBottom);
  return { x: left + shift + before - el.scrollLeft, y: top + (inner - height) / 2, width: 0, height };
}

const MIRRORED = ["direction", "boxSizing", "width", "height", "overflowX", "overflowY",
  "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth", "borderStyle",
  "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
  "fontStyle", "fontVariant", "fontWeight", "fontStretch", "fontSize", "fontSizeAdjust", "lineHeight", "fontFamily",
  "fontFeatureSettings", "fontKerning", "textAlign", "textTransform", "textIndent", "letterSpacing", "wordSpacing",
  "tabSize", "whiteSpace", "wordBreak", "overflowWrap"];

/**
 * A <textarea>: a hidden copy of its box and text up to the caret, added
 * and removed in the same task — never painted, though a MutationObserver
 * on the whole document would see it come and go.
 */
function textareaCaret(el, caret) {
  const doc = el.ownerDocument;
  const style = styleOf(el);
  const mirror = doc.createElement("div");
  const marker = doc.createElement("span");
  for (const name of MIRRORED) mirror.style[name] = style[name];
  mirror.style.position = "absolute";
  mirror.style.visibility = "hidden";
  mirror.style.pointerEvents = "none";
  mirror.style.left = "-10000px";
  mirror.style.top = "0px";
  mirror.style.margin = "0px";
  mirror.style.whiteSpace = "pre-wrap";
  if (style.overflowWrap === "normal" && style.wordBreak === "normal") mirror.style.overflowWrap = "break-word";
  mirror.textContent = el.value.slice(0, caret);
  marker.textContent = el.value.slice(caret) || ".";
  mirror.appendChild(marker);
  (doc.documentElement || doc).appendChild(mirror);
  try {
    const box = mirror.getBoundingClientRect();
    const spot = marker.getClientRects()[0] || marker.getBoundingClientRect();
    const rect = el.getBoundingClientRect();
    return { x: rect.left + (spot.left - box.left) - el.scrollLeft, y: rect.top + (spot.top - box.top) - el.scrollTop,
      width: 0, height: spot.height || lineHeightOf(style) };
  } finally {
    mirror.remove();
  }
}

/** Editable content: the selection's focus point, or the start of an empty block. */
function editableCaret(el) {
  const doc = el.ownerDocument;
  const root = el.getRootNode ? el.getRootNode() : doc;
  const selection = (root !== doc && typeof root.getSelection === "function" ? root.getSelection() : null) || doc.getSelection();
  if (!selection || !selection.rangeCount || !selection.focusNode || !el.contains(selection.focusNode)) return null;
  const range = doc.createRange();
  try { range.setStart(selection.focusNode, selection.focusOffset); } catch (error) { return null; }
  range.collapse(true);
  const rects = range.getClientRects();
  const spot = rects.length ? rects[rects.length - 1] : null;
  if (spot && (spot.height > 0 || spot.width > 0)) return { x: spot.left, y: spot.top, width: 0, height: spot.height };
  // A collapsed range in an empty block has no box: the block's content start.
  const node = selection.focusNode.nodeType === 1 ? selection.focusNode : selection.focusNode.parentElement;
  const block = node && el.contains(node) ? node : el;
  const style = styleOf(block);
  const rect = block.getBoundingClientRect();
  return { x: rect.left + block.clientLeft + px(style.paddingLeft), y: rect.top + block.clientTop + px(style.paddingTop),
    width: 0, height: lineHeightOf(style) };
}

function caretRect() {
  const focused = deepActive();
  if (!focused) return null;
  const el = focused.el;
  let rect = null;
  if (isTextField(el)) {
    let caret = null;
    try { caret = el.selectionDirection === "backward" ? el.selectionStart : el.selectionEnd; } catch (error) { caret = null; }
    if (caret == null) caret = el.value.length;
    rect = el.localName === "textarea" ? textareaCaret(el, caret) : inputCaret(el, caret);
  } else if (el.isContentEditable) {
    rect = editableCaret(el);
  } else {
    return null;
  }
  if (!rect) rect = bottomLeft(el);
  return { x: rect.x + focused.ox, y: rect.y + focused.oy, width: rect.width, height: rect.height };
}

// ---------------------------------------------------------------- clipboard

let copied = null;

/** What the browser copies when the page does not cancel the event: the selection. */
function selectedText(target) {
  if (isTextField(target)) {
    if (target.type === "password") return "";
    let start = null, end = null;
    try { start = target.selectionStart; end = target.selectionEnd; } catch (error) { start = null; }
    if (start != null && end != null) return target.value.slice(start, end);
  }
  const doc = (target && target.ownerDocument) || document;
  const selection = doc.getSelection();
  return selection ? String(selection) : "";
}

function readData(data) {
  try { return data ? data.getData("text/plain") : ""; } catch (error) { return ""; }
}

/**
 * A trusted copy or cut, on `window` in the bubble phase — after the
 * page's own handlers. Read now and once more in a microtask: one runs
 * after each listener of an event the browser dispatches, while the
 * clipboard data can still be read (it cannot after the dispatch).
 */
function onClipboard(event) {
  if (!event.isTrusted) return;
  const data = event.clipboardData;
  // The node itself, inside an open shadow root (event.target is its host by now).
  const path = event.composedPath();
  const target = path.length ? path[0] : event.target;
  const early = readData(data);
  queueMicrotask(() => {
    const text = event.defaultPrevented ? (readData(data) || early) : selectedText(target);
    copied = { text, type: event.type, at: performance.now() };
  });
}

function listen() {
  window.removeEventListener("copy", onClipboard);
  window.removeEventListener("cut", onClipboard);
  window.addEventListener("copy", onClipboard);
  window.addEventListener("cut", onClipboard);
}
listen();
// A key may copy (⌘C, Edit ▸ Copy): first make these listeners the last on
// window, after any the page added since.
window.addEventListener("keydown", (event) => { if (event.isTrusted) listen(); }, true);

function takeCopied() {
  if (!copied) return null;
  const result = { text: copied.text, type: copied.type, ageMs: Math.max(0, Math.round(performance.now() - copied.at)) };
  copied = null;
  return result;
}

function firePaste(args) {
  const text = String(args && args.text != null ? args.text : "");
  const focused = deepActive();
  let target = focused ? focused.el : null;
  const doc = target ? target.ownerDocument : document;
  if (!target || target === doc.documentElement) target = doc.body || doc.documentElement;
  const view = doc.defaultView || window;
  const data = new view.DataTransfer();
  data.setData("text/plain", text);
  const event = new view.ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true, composed: true });
  return { cancelled: !target.dispatchEvent(event) };
}

// ---------------------------------------------------------------- <select>

function chooseUserSelect(args) {
  const index = Number(args && args.index);
  let select = lastHit && lastHit.select ? lastHit.select.deref() : null;
  if (select && !select.isConnected) select = null;
  if (!select && lastHit) {
    const hit = hitAt(lastHit.x, lastHit.y);
    select = hit ? nativeSelect(hit.el) : null;
  }
  if (!select) {
    const focused = deepActive();
    select = focused && focused.el.localName === "select" ? focused.el : null;
  }
  if (!select) return fail("noSelect", "no <select> under the last point, none focused");
  if (select.matches(":disabled")) return fail("disabled", "the <select> is disabled");
  if (!Number.isInteger(index) || index < 0 || index >= select.options.length) return fail("invalid", "no option at index " + String(args && args.index));
  if (select.options[index].matches(":disabled")) return fail("disabled", "the option is disabled");
  select.focus({ preventScroll: true });
  if (select.selectedIndex === index && !select.multiple) {
    return { ok: true, changed: false, value: select.value, selectedIndex: index };
  }
  select.selectedIndex = index;
  const view = select.ownerDocument.defaultView || window;
  select.dispatchEvent(new view.Event("input", { bubbles: true, composed: true }));
  select.dispatchEvent(new view.Event("change", { bubbles: true }));
  return { ok: true, changed: true, value: select.value, selectedIndex: select.selectedIndex };
}

Object.defineProperty(globalThis, "__loomPanel", {
  value: Object.freeze({ version: VERSION, hitInfo, caretRect, takeCopied, firePaste, chooseUserSelect }),
  configurable: false,
  enumerable: false,
  writable: false,
});
})();
"""#

    /// The function every panel op runs by (`Runtime.callFunctionOn` in the
    /// helper's world, `arguments: [{value: op}, {value: arg}]`,
    /// `returnByValue: true`): the op's own answer, or `{error}`.
    static let callFunction: String = #"""
function(op, arg) { const panel = globalThis.__loomPanel; if (!panel) return { error: { code: "panelMissing", message: "the panel script is not loaded" } }; if (typeof panel[op] !== "function" || !Object.prototype.hasOwnProperty.call(panel, op)) return { error: { code: "invalid", message: "unknown op " + op } }; try { return panel[op](arg); } catch (error) { return { error: { code: "failed", message: String(error && error.message || error) } }; } }
"""#
}
