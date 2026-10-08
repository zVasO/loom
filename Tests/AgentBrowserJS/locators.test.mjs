// The helper's selector engine (design §4): browser_run_code's locators,
// and Playwright selector strings in the browser tools' targets.
//
// 1. The oracle: each query runs through Loom's engine (the helper in the
//    page, `stampAll` answering every match's data-k in engine order) and
//    through Playwright's own locators on the same page. Equal, or listed
//    in KNOWN with the reason — and then asserted to still differ, so a fix
//    is noticed and its entry removed.
// 2. getByRole finds what browser_snapshot shows: every `role "name"
//    [ref=eN]` line resolves to a set that holds eN's element.
// 3. Strictness, selector strings in browser tools, reads, waits, the
//    noRefs snapshot.
// 4. parseSelector, normalizeWS and stringMatcher, pure: no DOM, no browser.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { helperSource, pureHelper, fixturesDirectory, stampLookupSource } from "./extract.mjs";

// ---------------------------------------------------------------- pure

const pure = pureHelper();
// Values built in the helper's realm: compared as plain JSON.
const parse = (selector) => JSON.parse(JSON.stringify(pure.parseSelector(selector)));
const parseError = (selector) => {
  try {
    pure.parseSelector(selector);
  } catch (error) {
    return { code: error.code, message: error.message };
  }
  return null;
};

const PARSED = [
  ["button.primary", [{ css: "button.primary" }]],
  // An escaped colon is part of a class name (Tailwind), not an extension.
  [".md\\:visible", [{ css: ".md\\:visible" }]],
  [".dark\\:light >> nth=0", [{ css: ".dark\\:light" }, { nth: 0 }]],
  ["css=div > span", [{ css: "div > span" }]],
  ["text=Save", [{ text: { s: "Save", m: "ci" } }]],
  ['text="Save draft"', [{ text: { s: "Save draft", m: "eq" }, legacy: true }]],
  ["'Delete'", [{ text: { s: "Delete", m: "eq" }, legacy: true }]],
  ['"Delete"', [{ text: { s: "Delete", m: "eq" }, legacy: true }]],
  ["text=/sa.e/i", [{ text: { re: "sa.e", f: "i" } }]],
  ["//li[2]", [{ xpath: "//li[2]" }]],
  ["(//button)[1]", [{ xpath: "(//button)[1]" }]],
  ["xpath=//a", [{ xpath: "//a" }]],
  ["..", [{ xpath: ".." }]],
  ['role=button[name="Save"]', [{ role: "button", name: { s: "Save", m: "eq" } }]],
  ['role=button[name="save" i]', [{ role: "button", name: { s: "save", m: "eqi" } }]],
  ['role=button[name*="ave"]', [{ role: "button", name: { s: "ave", m: "cs" } }]],
  ['role=button[name*="AVE" i]', [{ role: "button", name: { s: "AVE", m: "ci" } }]],
  ["role=button[name=/^save/i]", [{ role: "button", name: { re: "^save", f: "i" } }]],
  ["role=heading[level=2]", [{ role: "heading", level: 2 }]],
  ["role=checkbox[checked]", [{ role: "checkbox", checked: true }]],
  ["role=checkbox[checked=false]", [{ role: "checkbox", checked: false }]],
  ['role=checkbox[checked="mixed"]', [{ role: "checkbox", checked: "mixed" }]],
  ["role=button[pressed][disabled=false][include-hidden]", [{ role: "button", pressed: true, disabled: false, includeHidden: true }]],
  ["role=Button[expanded=true]", [{ role: "button", expanded: true }]],
  ["id=email", [{ css: '[id="email"]' }]],
  ["data-testid=submit-order", [{ css: '[data-testid="submit-order"]' }]],
  ["data-test-id=a", [{ css: '[data-test-id="a"]' }]],
  ["aria-ref=e12", [{ ref: "e12" }]],
  ["e12", [{ ref: "e12" }]],
  ["f1e3", [{ ref: "f1e3" }]],
  ["#list >> nth=0", [{ css: "#list" }, { nth: 0 }]],
  ["li >> nth=-1", [{ css: "li" }, { nth: -1 }]],
  ["li >> visible=true", [{ css: "li" }, { visible: true }]],
  ['li >> text="a >> b"', [{ css: "li" }, { text: { s: "a >> b", m: "eq" }, legacy: true }]],
  ['[title="a >> b"] >> nth=1', [{ css: '[title="a >> b"]' }, { nth: 1 }]],
  ["[data-x=a>>b] >> span", [{ css: "[data-x=a>>b]" }, { css: "span" }]],
  ["div:has(> span) >> text=x", [{ css: "div:has(> span)" }, { text: { s: "x", m: "ci" } }]],
  ["text=it's >> nth=0", [{ text: { s: "it's", m: "ci" } }, { nth: 0 }]],
  ['role=button[name=">>"] >> nth=1', [{ role: "button", name: { s: ">>", m: "eq" } }, { nth: 1 }]],
  ['internal:role=button[name="Save"i]', [{ role: "button", name: { s: "Save", m: "ci" } }]],
  ['internal:role=button[name="Save"s]', [{ role: "button", name: { s: "Save", m: "eq" } }]],
  ['internal:text="Hello"i', [{ text: { s: "Hello", m: "ci" } }]],
  ['internal:text="Hello"s', [{ text: { s: "Hello", m: "eq" } }]],
  ['internal:label="Email"i', [{ label: { s: "Email", m: "ci" } }]],
  ['internal:attr=[placeholder="you@"i]', [{ placeholder: { s: "you@", m: "ci" } }]],
  ['internal:attr=[alt="Logo"s]', [{ alt: { s: "Logo", m: "eq" } }]],
  ["internal:attr=[title=/help/i]", [{ title: { re: "help", f: "i" } }]],
  ['internal:testid=[data-testid="x"s]', [{ testId: { s: "x", m: "eq" } }]],
  ['li >> internal:has-text="Milk"i', [{ css: "li" }, { hasText: { s: "Milk", m: "ci" } }]],
  ['li >> internal:has-not-text=/eggs/', [{ css: "li" }, { hasText: { re: "eggs", f: "" }, not: true }]],
  ['li >> internal:has="input:checked"', [{ css: "li" }, { has: { chain: [{ css: "input:checked" }], desc: "input:checked" } }]],
  ['li >> internal:has-not="text=x >> nth=0"',
    [{ css: "li" }, { has: { chain: [{ text: { s: "x", m: "ci" } }, { nth: 0 }], desc: "text=x >> nth=0" }, not: true }]],
  ['li >> internal:or="p"', [{ css: "li" }, { or: { chain: [{ css: "p" }], desc: "p" } }]],
  ['li >> internal:describe="the rows"', [{ css: "li" }]],
];

for (const [selector, expected] of PARSED) {
  test("parseSelector " + JSON.stringify(selector), () => {
    assert.deepEqual(parse(selector), expected);
  });
}

const REFUSED = [
  ["", /empty/],
  ["   ", /empty/],
  ["li:visible", /:visible .*filter\(\{ visible: true \}\)/],
  ["button:has-text('Save')", /:has-text\(\).*getByText/],
  ["p:text-is('x')", /:text-is\(\)/],
  ["foo=bar", /Unknown engine "foo"/],
  ["Role=button", /Unknown engine "Role"/],
  ["_react=App", /Unknown engine "_react"/],
  ["*css=li", /capture/],
  ["role=", /Role must not be empty|selector cannot be empty/],
  ["role=button[checked]", /"checked" attribute is only supported for roles/],
  ["role=heading[level=two]", /"level" attribute must be compared to a number/],
  ["role=button[name]", /"name" attribute must have a value/],
  ["role=button[name^=\"Sa\"]", /takes = or \*=/],
  ["role=button[nme=\"x\"]", /Unknown attribute "nme"/],
  ['role=button[name="x"', /Unexpected end/],
  ["text=/[a-/", /invalid regular expression/],
  ["li >> nth=first", /nth= takes an integer/],
  ["li >> visible=yes", /visible= takes true or false/],
  ["aria-ref=button", /aria-ref takes a ref/],
  ['internal:has="li"', /cannot be first/],
  ["li >> internal:has=li", /Malformed selector/],
  ["internal:control=enter-frame", /not supported here/],
  ["li >>  >> span", /empty part/],
  [Array.from({ length: 33 }, () => "li").join(" >> "), /32 parts at most/],
];

for (const [selector, pattern] of REFUSED) {
  test("parseSelector refuses " + JSON.stringify(selector.length > 40 ? selector.slice(0, 40) + "…" : selector), () => {
    const error = parseError(selector);
    assert.ok(error, "no error for " + selector);
    assert.equal(error.code, "invalid");
    assert.match(error.message, pattern);
  });
}

test("normalizeWS is Playwright's: zero-width and soft hyphens dropped, runs collapsed, trimmed", () => {
  assert.equal(pure.normalizeWS("  Lots \n\t of   space "), "Lots of space");
  assert.equal(pure.normalizeWS("Zero​width­text"), "Zerowidthtext");
  assert.equal(pure.normalizeWS("a b"), "a b", "a no-break space is whitespace");
  assert.equal(pure.normalizeWS(null), "");
});

test("stringMatcher: contains any case, contains, equals, equals any case, regex; names normalized, attributes as they are", () => {
  const name = (spec, value) => pure.stringMatcher(spec, true)(value);
  const attr = (spec, value) => pure.stringMatcher(spec, false)(value);
  assert.equal(name({ s: "save", m: "ci" }, "Save  draft"), true);
  assert.equal(name({ s: "Save draft", m: "ci" }, " Save\n draft "), true, "both sides normalized");
  assert.equal(name({ s: "save", m: "cs" }, "Save draft"), false);
  assert.equal(name({ s: "Save", m: "cs" }, "Save draft"), true);
  assert.equal(name({ s: "Save", m: "eq" }, "Save draft"), false);
  assert.equal(name({ s: "Save", m: "eq" }, "  Save "), true);
  assert.equal(name({ s: "SAVE", m: "eqi" }, "save"), true);
  assert.equal(name({ re: "^save", f: "i" }, "Save draft"), true);
  assert.equal(name({ re: "^save", f: "gi" }, "Save"), true);
  assert.equal(name({ re: "^save", f: "gi" }, "Save"), true, "g dropped: test() stays stateless");
  assert.equal(name("save", "Save draft"), true, "a bare string: contains, any case");
  assert.equal(attr({ s: "you@", m: "ci" }, "YOU@example.com"), true);
  assert.equal(attr({ s: "a  b", m: "ci" }, "a b"), false, "attributes are not normalized");
  assert.equal(attr({ s: "x", m: "eq" }, "x"), true);
  assert.throws(() => pure.stringMatcher({ s: "x", m: "nope" }, true), /a text must be/);
  assert.throws(() => pure.stringMatcher({ re: "(", f: "" }, true), /invalid regular expression/);
});

// ---------------------------------------------------------------- browser

async function loadPlaywright() {
  try { return await import("playwright"); } catch (_) { /* not local */ }
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    return createRequire(import.meta.url)(resolve(root, "playwright"));
  } catch (_) {
    return null;
  }
}

const playwright = await loadPlaywright();
const skip = playwright ? false : "Playwright is not installed";

let browser;
let server;
let base;
/** One fixture page for the read-only oracle queries. */
let sharedPage = null;

before(async () => {
  if (skip) return;
  server = createServer((request, response) => {
    const path = request.url.split("?")[0];
    const file = path === "/locators" ? "locators.html" : path === "/todo" ? "todo.html" : null;
    if (file) {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(readFileSync(resolve(fixturesDirectory, file)));
    } else {
      response.writeHead(404, { "content-type": "application/json" });
      response.end("{}");
    }
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  base = "http://127.0.0.1:" + server.address().port;
  browser = await playwright.chromium.launch();
});

after(async () => {
  await sharedPage?.close();
  await browser?.close();
  server?.close();
});

/** A page with the helper in its world (Loom puts it in its own; the DOM is the same). */
async function open(path) {
  const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
  await page.addInitScript(helperSource());
  await page.goto(base + path);
  return page;
}

const run = (page, op, args = {}) =>
  page.evaluate(([o, a]) => globalThis.__loomAgent.run(o, a), [op, JSON.stringify(args)]).then(JSON.parse);

const refOf = (yaml, pattern) => {
  const line = yaml.split("\n").find((l) => pattern.test(l));
  assert.ok(line, "no line matches " + pattern + " in:\n" + yaml);
  return /\[ref=(e\d+)\]/.exec(line)[1];
};

/** Removes every data-loom-eval, open shadow trees included: stamps are Loom's, not the page's. */
const unstamp = (page) => page.evaluate(() => {
  const visit = (root) => {
    for (const el of root.querySelectorAll("*")) {
      el.removeAttribute("data-loom-eval");
      if (el.shadowRoot) visit(el.shadowRoot);
    }
  };
  visit(document);
});

// ---------- one query, both engines

const spec = (value, exact) => (value instanceof RegExp
  ? { re: value.source, f: value.flags.replace(/[gy]/g, "") }
  : { s: String(value), m: exact ? "eq" : "ci" });

/** One query written once: Loom's chain (the facade's wire format) and Playwright's locator. */
class Q {
  constructor(chain = [], build = (page) => page) {
    this.chain = chain;
    this.build = build;
  }

  with(steps, apply) {
    const previous = this.build;
    return new Q([...this.chain, ...steps], (page) => apply(previous(page), page));
  }

  getByRole(role, options = {}) {
    const step = { role };
    if (options.name !== undefined) step.name = spec(options.name, options.exact);
    for (const key of ["checked", "pressed", "selected", "expanded", "level", "disabled", "includeHidden"]) {
      if (options[key] !== undefined) step[key] = options[key];
    }
    return this.with([step], (x) => x.getByRole(role, options));
  }

  getByText(text, options = {}) { return this.with([{ text: spec(text, options.exact) }], (x) => x.getByText(text, options)); }
  getByLabel(text, options = {}) { return this.with([{ label: spec(text, options.exact) }], (x) => x.getByLabel(text, options)); }
  getByPlaceholder(text, options = {}) {
    return this.with([{ placeholder: spec(text, options.exact) }], (x) => x.getByPlaceholder(text, options));
  }
  getByAltText(text, options = {}) { return this.with([{ alt: spec(text, options.exact) }], (x) => x.getByAltText(text, options)); }
  getByTitle(text, options = {}) { return this.with([{ title: spec(text, options.exact) }], (x) => x.getByTitle(text, options)); }
  getByTestId(text) { return this.with([{ testId: spec(text, true) }], (x) => x.getByTestId(text)); }
  locator(selector) { return this.with([{ selector }], (x) => x.locator(selector)); }
  nth(index) { return this.with([{ nth: index }], (x) => x.nth(index)); }
  first() { return this.with([{ nth: 0 }], (x) => x.first()); }
  last() { return this.with([{ nth: -1 }], (x) => x.last()); }
  and(other) { return this.with([{ and: { chain: other.chain, desc: "and" } }], (x, page) => x.and(other.build(page))); }
  or(other) { return this.with([{ or: { chain: other.chain, desc: "or" } }], (x, page) => x.or(other.build(page))); }

  filter(options) {
    const steps = [];
    if (options.hasText !== undefined) steps.push({ hasText: spec(options.hasText, false) });
    if (options.hasNotText !== undefined) steps.push({ hasText: spec(options.hasNotText, false), not: true });
    if (options.has) steps.push({ has: { chain: options.has.chain, desc: "has" } });
    if (options.hasNot) steps.push({ has: { chain: options.hasNot.chain, desc: "hasNot" }, not: true });
    if (options.visible !== undefined) steps.push({ visible: options.visible });
    return this.with(steps, (x, page) => {
      const pw = { ...options };
      if (options.has) pw.has = options.has.build(page);
      else delete pw.has;
      if (options.hasNot) pw.hasNot = options.hasNot.build(page);
      else delete pw.hasNot;
      return x.filter(pw);
    });
  }
}

const p = new Q();

const QUERIES = [
  // getByRole: roles, names, states, hidden
  ["role button", p.getByRole("button")],
  ["role button in the form", p.locator("form").getByRole("button")],
  ["role button, name contains", p.getByRole("button", { name: "Save" })],
  ["role button, name exact", p.getByRole("button", { name: "Save", exact: true })],
  ["role button, name exact is case-sensitive", p.getByRole("button", { name: "save", exact: true })],
  ["role button, name regex", p.getByRole("button", { name: /^save/i })],
  ["role button, name regex on the normalized name", p.getByRole("button", { name: /draft$/ })],
  ["role button, pressed", p.getByRole("button", { pressed: true })],
  ["role button in the form, not pressed", p.locator("form").getByRole("button", { pressed: false })],
  ["role button, expanded false", p.getByRole("button", { expanded: false })],
  ["role button, disabled (native, aria-disabled)", p.getByRole("button", { disabled: true })],
  ["role textbox, disabled by its fieldset", p.getByRole("textbox", { disabled: true })],
  ["role button in a disabled fieldset's legend is enabled", p.locator("legend").getByRole("button", { disabled: false })],
  ["display:none is hidden", p.getByRole("button", { name: "Ghost display none" })],
  ["display:none with includeHidden", p.getByRole("button", { name: "Ghost display none", includeHidden: true })],
  ["aria-hidden ancestor", p.getByRole("button", { name: "Hidden from AT" })],
  ["aria-hidden ancestor with includeHidden", p.getByRole("button", { name: "Hidden from AT", includeHidden: true })],
  ["visibility:hidden", p.getByRole("button", { name: "Invisible ghost" })],
  ["sr-only is not hidden", p.getByRole("button", { name: "Screen reader only" })],
  ["inside a closed details", p.getByRole("button", { name: "Inside details" })],
  ["inert subtree", p.getByRole("button", { name: "Inert action" })],
  ["open shadow root", p.getByRole("button", { name: "Shadow action" })],
  ["closed shadow root", p.getByRole("button", { name: "Closed action" })],
  ["a name past 100 characters", p.getByRole("button", { name: "one row per item and one column per field" })],
  ["inline elements in a name", p.getByRole("button", { name: "Buy for €12.00", exact: true })],
  ["headings", p.getByRole("heading")],
  ["heading level 2", p.getByRole("heading", { level: 2 })],
  ["heading level 4 (aria-level)", p.getByRole("heading", { level: 4 })],
  ["checkbox checked", p.getByRole("checkbox", { checked: true })],
  ["checkbox unchecked", p.getByRole("checkbox", { checked: false })],
  ["checkbox mixed", p.getByRole("checkbox", { checked: "mixed" })],
  ["switch checked", p.getByRole("switch", { checked: true })],
  ["radio checked", p.getByRole("radio", { checked: true })],
  ["radio by its label", p.getByRole("radio", { name: "Pro" })],
  ["option selected", p.getByRole("option", { selected: true })],
  ["links", p.getByRole("link")],
  ["link by name", p.getByRole("link", { name: "Docs" })],
  ["textboxes", p.getByRole("textbox")],
  ["textbox by label for", p.getByRole("textbox", { name: "Email address" })],
  ["textbox by wrapping label", p.getByRole("textbox", { name: "Full name" })],
  ["textbox by aria-labelledby", p.getByRole("textbox", { name: "Short bio" })],
  ["searchbox", p.getByRole("searchbox")],
  ["combobox by aria-label", p.getByRole("combobox", { name: "Country" })],
  ["listitems", p.getByRole("listitem")],
  ["rows", p.getByRole("row")],
  ["row by name", p.getByRole("row", { name: "#1002" })],
  ["cells", p.getByRole("cell")],
  ["column headers", p.getByRole("columnheader")],
  ["dialog by aria-labelledby", p.getByRole("dialog", { name: "Confirm" })],
  ["regions", p.getByRole("region")],
  ["region by name", p.getByRole("region", { name: "Profile" })],
  ["navigation", p.getByRole("navigation", { name: "Main" })],
  ["img by alt", p.getByRole("img", { name: "Company logo" })],
  ["groups", p.getByRole("group")],
  ["banner and contentinfo", p.getByRole("banner").or(p.getByRole("contentinfo"))],

  // getByText
  ["text contains", p.getByText("Hello")],
  ["text in an inline child", p.getByText("world")],
  ["text exact across an inline element", p.getByText("Hello world", { exact: true })],
  ["text regex on the full text", p.getByText(/lots\s+of/i)],
  ["text exact, whitespace normalized", p.getByText("Lots of space here", { exact: true })],
  ["text, zero-width and soft hyphen dropped", p.getByText("Zerowidthtext")],
  ["text contains any case", p.getByText("case matters")],
  ["text exact is case-sensitive", p.getByText("case matters", { exact: true })],
  ["text on buttons", p.getByText("Save")],
  ["text of a submit input", p.getByText("Send")],
  ["text in an open shadow root", p.getByText("Shadow text")],
  ["text in a closed shadow root", p.getByText("Closed action")],
  ["text in a contenteditable and a list", p.getByText("Milk")],
  ["hidden text still matches", p.getByText("Hidden until opened")],
  ["text exact of a paragraph with a child", p.getByText("3 items, 1 done", { exact: true })],

  // getByLabel, getByPlaceholder, getByAltText, getByTitle, getByTestId
  ["label for", p.getByLabel("Email address")],
  ["wrapping label", p.getByLabel("Full name")],
  ["aria-labelledby", p.getByLabel("Short bio")],
  ["aria-label", p.getByLabel("Search settings")],
  ["label after its input", p.getByLabel("Password")],
  ["aria-label on a button", p.getByLabel("Close")],
  ["aria-label contains", p.getByLabel("Milk")],
  ["aria-label exact", p.getByLabel("Milk done", { exact: true })],
  ["label regex", p.getByLabel(/news/i)],
  ["radio label", p.getByLabel("Free")],
  ["label on a contenteditable", p.getByLabel("Notes")],
  ["placeholder contains", p.getByPlaceholder("you@")],
  ["placeholder exact", p.getByPlaceholder("Jane Doe", { exact: true })],
  ["placeholder regex", p.getByPlaceholder(/words/)],
  ["alt text", p.getByAltText("logo")],
  ["title", p.getByTitle("Documentation")],
  ["title any case", p.getByTitle("help")],
  ["title of an iframe", p.getByTitle("Embedded")],
  ["test id", p.getByTestId("submit-order")],
  ["test id is exact", p.getByTestId("submit")],
  ["test id regex", p.getByTestId(/order/)],

  // chains and filters
  ["listitem with text, its button", p.getByRole("listitem").filter({ hasText: "Milk" }).getByRole("button")],
  ["nth", p.locator("#list").getByRole("listitem").nth(1)],
  ["first", p.locator("#list").getByRole("listitem").first()],
  ["last", p.locator("#list").getByRole("listitem").last()],
  ["nth from the end", p.locator("#list").getByRole("listitem").nth(-2)],
  ["nth out of range", p.locator("#list").getByRole("listitem").nth(5)],
  ["filter has", p.getByRole("listitem").filter({ has: p.getByRole("checkbox", { checked: true }) })],
  ["filter hasNot", p.locator("#list").getByRole("listitem").filter({ hasNot: p.getByRole("checkbox", { checked: true }) })],
  ["filter hasNotText", p.locator("#list").getByRole("listitem").filter({ hasNotText: "Eggs" })],
  ["filter hasText regex", p.getByRole("listitem").filter({ hasText: /bread/i })],
  ["filter visible", p.locator("section[aria-label=Help] > button").filter({ visible: true })],
  ["filter not visible", p.locator("section[aria-label=Help] > button").filter({ visible: false })],
  ["text under a css scope", p.locator("ul").getByText("Eggs")],
  ["and", p.getByRole("button", { name: "Save" }).and(p.getByText("draft"))],
  ["or, in document order", p.getByRole("button", { name: "Send" }).or(p.getByRole("button", { name: "Save", exact: true }))],
  ["or across a shadow root", p.getByText("Shadow text").or(p.getByRole("heading", { level: 1 }))],
  ["css under an element", p.locator("form").locator("input")],
  ["css descendant", p.locator("#list li")],
  ["css combinator inside the scope", p.locator("#list").locator("li > button")],
  ["css combinator must sit inside the scope", p.locator("li").locator("ul li")],
  ["section with text, its checkboxes", p.locator("section").filter({ hasText: "Shopping" }).getByRole("checkbox")],
  ["row with text, its third cell", p.getByRole("row").filter({ hasText: "Shipped" }).getByRole("cell").nth(2)],
  ["css into a shadow root from its host", p.locator("#host").locator("button")],
  ["css inside a shadow root", p.locator("div[data-k=shadow-row] span")],
  ["css combinator across a shadow boundary", p.locator("#host button")],
  ["a child of the scope, with a shadow root below it", p.locator("section[aria-label=Help]").locator("> button")],
  ["native :has()", p.locator("li:has(input:checked)")],
  ["role under main", p.locator("main").getByRole("button", { name: "Delete" })],

  // selector strings (the browser tools' targets)
  ["text=", p.locator("text=Clickable card")],
  ['text="…" (legacy: an own text node)', p.locator('text="Eggs"')],
  ['"…"', p.locator('"Delete"')],
  ["text=/re/", p.locator("text=/clickable/i")],
  ["role= name exact", p.locator('role=button[name="Save"]')],
  ["role= name any case", p.locator('role=button[name="save" i]')],
  ["role= name contains", p.locator('role=button[name*="ave"]')],
  ["role= level", p.locator("role=heading[level=2]")],
  ["role= checked=false", p.locator("role=checkbox[checked=false]")],
  [">> nth=0", p.locator("#list >> nth=0")],
  [">> nth=-1", p.locator("#list li >> nth=-1")],
  ["xpath", p.locator("//li[2]")],
  ["xpath=", p.locator('xpath=//button[@data-testid="submit-order"]')],
  ["id=", p.locator("id=email")],
  ["data-testid=", p.locator("data-testid=order-summary")],
  [">> visible=true", p.locator("#list li >> visible=true")],
  [">> text= under css", p.locator("li >> text=Eggs")],
  ["internal:role", p.locator('internal:role=button[name="Save"i]')],
  ["internal:label", p.locator('internal:label="Email"i')],
  ["internal:has", p.locator('#list >> internal:has="input:checked"')],
];

/** Understood divergences: query → why. Each is asserted to still differ. */
const KNOWN = {
  "role button": "a <summary> is a button for Loom (browser_snapshot shows it so, as Chrome's tree does), no role "
    + "for Playwright; an inert subtree is hidden for Loom (the snapshot drops it), not for Playwright",
  "inert subtree": "an inert subtree is hidden for Loom (the snapshot drops it), not for Playwright",
  "inline elements in a name": "the snapshot's names put a space around every child element (\"Buy for € 12 .00\"); "
    + "Playwright's accessible name joins inline ones",
  "textboxes": "a contenteditable without a role is a textbox for Loom (the snapshot shows it so), no role for Playwright",
  "cells": "a <th> without scope is a columnheader for Loom, a cell for Playwright",
  "column headers": "a <th> without scope is a columnheader for Loom, a cell for Playwright",
  "css combinator across a shadow boundary": "CSS combinators do not cross shadow boundaries in Loom's engine "
    + "(querySelectorAll per tree); Playwright's do",
};

async function shared() {
  if (!sharedPage) sharedPage = await open("/locators");
  return sharedPage;
}

for (const [label, query] of QUERIES) {
  test("oracle: " + label, { skip }, async () => {
    const page = await shared();
    const ours = await run(page, "stampAll", { target: { chain: query.chain, desc: label, strict: false }, keys: true });
    await unstamp(page);
    assert.equal(ours.ok, true, JSON.stringify(ours));
    const theirs = await query.build(page).evaluateAll((els) => els.map((e) => e.getAttribute("data-k")));
    if (KNOWN[label]) {
      assert.notDeepEqual(ours.keys, theirs, "fixed? remove it from KNOWN: " + KNOWN[label]);
    } else {
      assert.deepEqual(ours.keys, theirs);
    }
  });
}

test("the oracle runs about sixty queries, and each known divergence names one of them", () => {
  assert.ok(QUERIES.length >= 60, String(QUERIES.length));
  const labels = new Set(QUERIES.map(([label]) => label));
  assert.equal(labels.size, QUERIES.length, "labels are unique");
  for (const label of Object.keys(KNOWN)) assert.ok(labels.has(label), label);
});

// ---------- getByRole finds what browser_snapshot shows

const SNAPSHOT_LINE = /^\s*- ([a-z]+) ("(?:[^"\\]|\\.)*")(?: \[[^\]]*\])* \[ref=(e\d+)\]/;

async function checkSnapshotConsistency(page) {
  const { yaml } = await run(page, "snapshot", { budget: 100000 });
  let checked = 0;
  let inFrames = 0;
  for (const line of yaml.split("\n")) {
    const match = SNAPSHOT_LINE.exec(line);
    if (!match) continue;
    const [, role, quoted, ref] = match;
    const name = JSON.parse(quoted);
    // The snapshot cuts names at 100 characters: the shown prefix, contained.
    const nameSpec = name.endsWith("…") ? { s: name.slice(0, -1), m: "ci" } : { s: name, m: "eq" };
    const { nonce } = await run(page, "stamp", { target: ref });
    const inTop = await page.evaluate((n) => {
      const find = (root) => {
        if (root.querySelector('[data-loom-eval="' + n + '"]')) return true;
        for (const el of root.querySelectorAll("*")) if (el.shadowRoot && find(el.shadowRoot)) return true;
        return false;
      };
      return find(document);
    }, nonce);
    await unstamp(page);
    if (!inTop) { inFrames++; continue; }   // locators do not enter frames
    const target = { chain: [{ role, name: nameSpec }, { and: { chain: [{ ref }], desc: ref } }], desc: line.trim(), strict: false };
    const answer = await run(page, "count", { target });
    assert.equal(answer.count, 1, line.trim() + " → " + JSON.stringify(answer));
    checked++;
  }
  return { checked, inFrames };
}

test("getByRole finds what browser_snapshot shows: every named line of the fixture resolves to its ref", { skip }, async () => {
  const page = await open("/locators");
  const { checked, inFrames } = await checkSnapshotConsistency(page);
  assert.ok(checked >= 40, "lines checked: " + checked);
  assert.equal(inFrames, 1, "the frame's button only");
  await page.close();
});

test("getByRole finds what browser_snapshot shows: todo.html, with todos", { skip }, async () => {
  const page = await open("/todo");
  const { yaml } = await run(page, "snapshot", {});
  const field = refOf(yaml, /textbox "New todo"/);
  await run(page, "type", { target: field, text: "milk", submit: true });
  await run(page, "type", { target: field, text: "eggs and a very long name " + "x".repeat(110), submit: true });
  const { checked } = await checkSnapshotConsistency(page);
  assert.ok(checked >= 12, "lines checked: " + checked);
  await page.close();
});

// ---------- strictness

const saveButtons = { chain: [{ role: "button", name: { s: "Save", m: "ci" } }], desc: "getByRole('button', { name: 'Save' })" };

test("strict: two matches are the strict-mode error, naming both, with the ref the latest snapshot has", { skip }, async () => {
  const page = await open("/locators");
  // A snapshot of the Save button alone: only it has a ref.
  const { yaml } = await run(page, "snapshot", { target: '[data-k="save"]' });
  const ref = refOf(yaml, /button "Save"/);
  const answer = await run(page, "prepare", { target: { ...saveButtons, strict: true }, action: "click", trusted: true });
  assert.equal(answer.error.code, "ambiguous", JSON.stringify(answer));
  assert.equal(answer.error.message, [
    "strict mode violation: getByRole('button', { name: 'Save' }) resolved to 2 elements:",
    '    1) button "Save" [ref=' + ref + "]",
    '    2) button "Save draft"',
  ].join("\n"));
  const lenient = await run(page, "prepare", { target: { ...saveButtons, strict: false }, action: "click", trusted: true });
  assert.equal(lenient.status, "ready", JSON.stringify(lenient));
  assert.equal(lenient.description, 'button "Save"', "the first");
  const many = await run(page, "click", { target: { chain: [{ role: "button" }], desc: "getByRole('button')" } });
  assert.equal(many.error.code, "ambiguous", "strict by default");
  assert.match(many.error.message, /resolved to \d+ elements:\n(.*\n){10}    … and \d+ more$/, "ten lines at most");
  await page.close();
});

test("strict: no match waits (retry) unless wait is false", { skip }, async () => {
  const page = await open("/locators");
  const none = { chain: [{ role: "button", name: { s: "Nope", m: "eq" } }], desc: "getByRole('button', { name: 'Nope', exact: true })" };
  const waiting = await run(page, "prepare", { target: none, action: "click" });
  assert.deepEqual(waiting.error, { code: "notFound", retry: true, message: "waiting for " + none.desc });
  const now = await run(page, "prepare", { target: { ...none, wait: false }, action: "click" });
  assert.equal(now.error.code, "notFound");
  assert.equal(now.error.retry, undefined);
  await page.close();
});

test("a locator past its limits is invalid: 32 steps, 4 levels of has/and/or, unknown steps, bad patterns", { skip }, async () => {
  const page = await open("/locators");
  const invalid = async (chain) => {
    const answer = await run(page, "count", { target: { chain, desc: "x" } });
    assert.equal(answer.error && answer.error.code, "invalid", JSON.stringify(answer));
    return answer.error.message;
  };
  assert.match(await invalid(Array.from({ length: 33 }, () => ({ css: "div" }))), /32 steps at most/);
  let deep = { chain: [{ css: "div" }], desc: "d" };
  for (let i = 0; i < 5; i++) deep = { chain: [{ css: "div" }, { has: deep }], desc: "d" };
  assert.match(await invalid(deep.chain), /nest 4 deep at most/);
  assert.match(await invalid([{ nope: 1 }]), /not a locator step/);
  assert.match(await invalid([{ css: "li:visible" }]), /filter\(\{ visible: true \}\)/);
  assert.match(await invalid([{ css: "div[" }]), /is not a valid CSS selector/);
  assert.match(await invalid([{ xpath: "//[" }]), /is not a valid XPath expression/);
  assert.match(await invalid([{ text: { re: "(", f: "" } }]), /invalid regular expression/);
  assert.match(await invalid([{ role: "button", checked: true }]), /"checked" attribute is only supported/);
  assert.match(await invalid([{ selector: "role=button[" }]), /Unexpected end/);
  assert.match(await invalid([{ text: { s: "x", m: "fuzzy" } }]), /a text must be/);
  const big = await run(page, "count", { target: { chain: [{ css: "div" }], desc: "x".repeat(20000) } });
  assert.match(big.error.message, /16384 bytes at most/);
  await page.close();
});

// ---------- selector strings in the browser tools

test("a browser tool's target takes a Playwright selector; CSS and refs as before", { skip }, async () => {
  const page = await open("/todo");
  const { yaml } = await run(page, "snapshot", {});
  const add = refOf(yaml, /button "Add"/);
  assert.equal((await run(page, "prepare", { target: 'role=button[name="Add"]', action: "click" })).status, "ready");
  assert.equal((await run(page, "prepare", { target: "text=Clickable card", action: "click" })).status, "ready");
  assert.equal((await run(page, "stamp", { target: "#list >> nth=0" })).ok, true);
  assert.equal((await run(page, "prepare", { target: "aria-ref=" + add, action: "click" })).status, "ready");
  assert.equal((await run(page, "prepare", { target: add, action: "click" })).status, "ready", "a bare ref, as before");
  assert.equal((await run(page, "prepare", { target: "#new", action: "type" })).status, "ready", "CSS, as before");
  const css = await run(page, "click", { target: "button" });
  assert.deepEqual(css.error, { code: "ambiguous", message: '"button" matches 5 elements: use a ref from browser_snapshot' },
    "CSS keeps its wording");
  const many = await run(page, "click", { target: "role=button" });
  assert.equal(many.error.code, "ambiguous");
  assert.match(many.error.message, /^strict mode violation: role=button resolved to 6 elements:\n {4}1\) button "Add" \[ref=e\d+\]/);
  const none = await run(page, "click", { target: "text=Nope" });
  assert.deepEqual(none.error, { code: "notFound", message: '"text=Nope" does not match any elements.' });
  const broken = await run(page, "click", { target: "role=button[" });
  assert.equal(broken.error.code, "invalid");
  assert.match(broken.error.message, /^"role=button\[" is neither a ref \(e12\) nor a valid selector: Unexpected end/);
  const badCSS = await run(page, "click", { target: "div[" });
  assert.equal(badCSS.error.code, "invalid");
  assert.match(badCSS.error.message, /^"div\[" is neither a ref \(e12\) nor a valid selector: "div\[" is not a valid CSS selector$/);
  await page.close();
});

// ---------- reads, states, focus, waits

const byKey = (key) => ({ chain: [{ css: '[data-k="' + key + '"]' }], desc: "locator('[data-k=\"" + key + "\"]')" });

test("read: inputValue (through a label too), attribute, checked, text; errors worded as Playwright's", { skip }, async () => {
  const page = await open("/locators");
  const read = (target, what, name) => run(page, "read", { target, what, name });
  const email = { chain: [{ label: { s: "Email address", m: "ci" } }], desc: "getByLabel('Email address')" };
  assert.deepEqual(await read(email, "inputValue"), { ok: true, value: "ada@example.com" });
  assert.deepEqual(await read(byKey("label-email"), "inputValue"), { ok: true, value: "ada@example.com" }, "a label reads its control");
  assert.deepEqual(await read(byKey("bio"), "inputValue"), { ok: true, value: "Writes code." });
  assert.deepEqual(await read(byKey("country"), "inputValue"), { ok: true, value: "de" });
  assert.deepEqual(await read(byKey("save"), "inputValue"),
    { error: { code: "invalid", message: "Not an <input>, <textarea> or <select> element" } });
  assert.deepEqual(await read(byKey("link-docs"), "attribute", "href"), { ok: true, value: "#docs" });
  assert.deepEqual(await read(byKey("link-docs"), "attribute", "target"), { ok: true, value: null });
  assert.deepEqual(await read(byKey("news"), "checked"), { ok: true, value: true });
  assert.deepEqual(await read(byKey("label-terms"), "checked"), { ok: true, value: false }, "a label reads its control");
  assert.deepEqual(await read(byKey("select-all"), "checked"), { ok: true, value: false }, "mixed reads unchecked");
  assert.deepEqual(await read(byKey("save"), "checked"), { error: { code: "invalid", message: "Not a checkbox or radio button" } });
  assert.deepEqual(await read(byKey("hello"), "textContent"), { ok: true, value: "Hello world" });
  assert.deepEqual(await read(byKey("hello"), "innerHTML"), { ok: true, value: 'Hello <b data-k="world">world</b>' });
  assert.deepEqual(await read(byKey("spaced"), "innerText"), { ok: true, value: "Lots of space here" });
  assert.deepEqual(await read(byKey("email"), "editable"), { ok: true, value: true });
  assert.deepEqual(await read(byKey("card-number"), "editable"), { ok: true, value: false }, "disabled by its fieldset");
  const nope = await read({ chain: [{ css: "#nope" }], desc: "locator('#nope')" }, "textContent");
  assert.equal(nope.error.code, "notFound");
  assert.equal(nope.error.retry, true);
  // Every reading Playwright also gives, compared on a few elements.
  for (const key of ["h1", "hello", "spaced", "zw", "send", "dialog-text"]) {
    const ours = await read(byKey(key), "innerText");
    assert.equal(ours.value, await page.locator('[data-k="' + key + '"]').innerText(), key);
    const content = await read(byKey(key), "textContent");
    assert.equal(content.value, await page.locator('[data-k="' + key + '"]').textContent(), key);
  }
  await page.close();
});

test("read: boundingBox in the top viewport's CSS pixels, as Playwright's; null without a box; through a frame by ref", { skip }, async () => {
  const page = await open("/locators");
  for (const key of ["h1", "email", "btn-sr", "logo", "dialog-ok"]) {
    const ours = await run(page, "read", { target: byKey(key), what: "boundingBox" });
    const theirs = await page.locator('[data-k="' + key + '"]').boundingBox();
    for (const side of ["x", "y", "width", "height"]) {
      assert.ok(Math.abs(ours.value[side] - theirs[side]) < 0.01, key + "." + side + ": " + ours.value[side] + " vs " + theirs[side]);
    }
  }
  assert.deepEqual(await run(page, "read", { target: byKey("btn-gone"), what: "boundingBox" }), { ok: true, value: null });
  const { yaml } = await run(page, "snapshot", { budget: 100000 });
  const inner = refOf(yaml, /button "Frame button"/);
  const box = (await run(page, "read", { target: inner, what: "boundingBox" })).value;
  const theirs = await page.frameLocator('[data-k="frame"]').getByRole("button").boundingBox();
  assert.ok(Math.abs(box.x - theirs.x) < 0.01 && Math.abs(box.y - theirs.y) < 0.01, JSON.stringify([box, theirs]));
  await page.close();
});

test("state: visible and hidden as Playwright's isVisible; enabled and disabled; none matching", { skip }, async () => {
  const page = await open("/locators");
  const keys = ["h1", "btn-gone", "btn-aria-hidden", "btn-ghost", "btn-sr", "details-button", "summary", "host",
    "token", "logo", "dialog", "btn-inert", "label-name"];
  for (const key of keys) {
    const visible = await run(page, "state", { target: byKey(key), what: "visible" });
    const hidden = await run(page, "state", { target: byKey(key), what: "hidden" });
    const theirs = await page.locator('[data-k="' + key + '"]').isVisible();
    assert.equal(visible.value, theirs, key + " visible");
    assert.equal(hidden.value, !theirs, key + " hidden");
  }
  for (const key of ["delete", "soon", "card-number", "billing-help", "save", "label-pw"]) {
    const enabled = await run(page, "state", { target: byKey(key), what: "enabled" });
    assert.equal(enabled.value, await page.locator('[data-k="' + key + '"]').isEnabled(), key + " enabled");
    const disabled = await run(page, "state", { target: byKey(key), what: "disabled" });
    assert.equal(disabled.value, !enabled.value, key + " disabled");
  }
  const none = { chain: [{ css: "#nope" }], desc: "locator('#nope')" };
  assert.deepEqual(await run(page, "state", { target: none, what: "visible" }), { ok: true, value: false });
  assert.deepEqual(await run(page, "state", { target: none, what: "hidden" }), { ok: true, value: true });
  assert.deepEqual((await run(page, "state", { target: none, what: "enabled" })).error,
    { code: "notFound", retry: true, message: "waiting for locator('#nope')" });
  assert.equal((await run(page, "state", { target: saveButtons, what: "visible" })).error.code, "ambiguous");
  assert.equal((await run(page, "state", { target: { ...saveButtons, strict: false }, what: "visible" })).value, true);
  await page.close();
});

test("what stamp and stampAll mark in an open shadow root or a same-origin frame, the page's lookup finds — then unmarks", { skip }, async () => {
  const page = await open("/locators");
  const lookup = stampLookupSource();
  const find = (nonce, expected) => page.evaluate(([source, n, e]) => {
    const found = eval(source)(n, e);
    return found.map((el) => el.dataset.k);
  }, [lookup, nonce, expected]);
  const shadow = await run(page, "stamp", { target: { chain: [{ role: "button", name: { s: "Shadow action", m: "eq" } }], desc: "x" } });
  assert.equal(shadow.ok, true);
  assert.deepEqual(await find(shadow.nonce, 1), ["shadow-button"], "inside the open shadow root");
  assert.deepEqual(await find(shadow.nonce, 1), [], "unmarked: found once");
  const framed = await run(page, "stamp", { target: { chain: [{ role: "button", name: { s: "Frame button", m: "eq" } }], desc: "x" } });
  if (framed.ok) assert.deepEqual(await find(framed.nonce, 1), ["frame-button"], "inside the same-origin frame");
  const all = await run(page, "stampAll", { target: { chain: [{ role: "button" }], desc: "x" } });
  const keys = await find(all.nonce, all.count);
  assert.equal(keys.length, all.count, "every button the engine counted, the shadow one included: " + keys.join());
  assert.ok(keys.includes("shadow-button"));
  await unstamp(page);
  await page.close();
});

test("count, readAll and stampAll are never strict; focus and blur move focus without scrolling", { skip }, async () => {
  const page = await open("/locators");
  assert.deepEqual(await run(page, "count", { target: { chain: [{ role: "listitem" }], desc: "x" } }), { ok: true, count: 6 });
  assert.deepEqual(await run(page, "count", { target: "#list li" }), { ok: true, count: 3 }, "CSS string");
  assert.deepEqual(await run(page, "count", { target: "role=listitem >> nth=1" }), { ok: true, count: 1 }, "selector string");
  assert.deepEqual(await run(page, "count", { target: { chain: [{ selector: "#list" }, { role: "listitem" }], desc: "x" } }),
    { ok: true, count: 3 }, "a selector step inside a chain");
  assert.deepEqual(await run(page, "readAll", { target: "#list li span", what: "textContent" }),
    { ok: true, value: ["Milk", "Eggs", "Bread"] });
  assert.deepEqual(await run(page, "readAll", { target: { chain: [{ css: "#list input" }], desc: "x" }, what: "checked" }),
    { ok: true, value: [true, false, false] });
  const stamped = await run(page, "stampAll", { target: { chain: [{ css: "#list li" }], desc: "x", strict: true } });
  assert.equal(stamped.count, 3);
  assert.equal(await page.evaluate((n) => document.querySelectorAll('[data-loom-eval="' + n + '"]').length, stamped.nonce), 3);
  await unstamp(page);
  const email = { chain: [{ label: { s: "Email address", m: "eq" } }], desc: "getByLabel('Email address', { exact: true })" };
  const focused = await run(page, "focus", { target: email });
  assert.equal(focused.ok, true);
  assert.equal(await page.evaluate(() => document.activeElement.dataset.k), "email");
  await run(page, "blur", { target: email });
  assert.equal(await page.evaluate(() => document.activeElement === document.body), true);
  await page.close();
});

/** waitState in the page, `change` run 100 ms in: the answer, and how long after the change it came. */
async function waitAfter(page, args, change) {
  return page.evaluate(async ([a, changeSource]) => {
    setTimeout(() => {
      (0, eval)(changeSource)();
      window.__changedAt = performance.now();
    }, 100);
    const started = performance.now();
    const answer = JSON.parse(await globalThis.__loomAgent.run("waitState", JSON.stringify(a)));
    const now = performance.now();
    return { answer, afterChange: window.__changedAt ? now - window.__changedAt : null, elapsed: now - started };
  }, [args, change.toString()]);
}

test("waitState: an element added later is seen within a frame of the mutation; detached after a removal", { skip }, async () => {
  const page = await open("/locators");
  const late = { chain: [{ role: "button", name: { s: "Late", m: "eq" } }], desc: "getByRole('button', { name: 'Late', exact: true })", strict: true };
  const added = await waitAfter(page, { target: late, state: "visible", maxMs: 2000 }, () => {
    const button = document.createElement("button");
    button.textContent = "Late";
    document.querySelector("main").prepend(button);
  });
  assert.deepEqual(added.answer, { ok: true, done: true, count: 1 });
  // A frame is ~16 ms; the bound leaves a loaded CI runner room, and stays
  // well under the 250 ms poll: the observer saw it, not the poll.
  assert.ok(added.afterChange < 100, "seen " + added.afterChange.toFixed(1) + " ms after the mutation");
  const gone = await waitAfter(page, { target: late, state: "detached", maxMs: 2000 }, () => {
    document.querySelector("main > button").remove();
  });
  assert.deepEqual(gone.answer, { ok: true, done: true, count: 0 });
  assert.ok(gone.afterChange < 100, "seen " + gone.afterChange.toFixed(1) + " ms after the removal");
  const shown = await waitAfter(page, { target: byKey("btn-gone"), state: "visible", maxMs: 2000 }, () => {
    document.querySelector('[data-k="btn-gone"]').classList.remove("gone");
  });
  assert.equal(shown.answer.done, true, "an attribute change");
  const never = await waitAfter(page, { target: { chain: [{ css: "#never" }], desc: "x" }, state: "attached", maxMs: 300 }, () => {});
  assert.deepEqual(never.answer, { ok: true, done: false, count: 0 });
  assert.ok(never.elapsed >= 295, "waited its maxMs: " + never.elapsed);
  assert.deepEqual(await run(page, "waitState", { target: { chain: [{ css: "#never" }], desc: "x" }, state: "hidden" }),
    { ok: true, done: true, count: 0 }, "nothing matching is hidden");
  const strict = await run(page, "waitState", { target: { ...saveButtons, strict: true }, state: "visible" });
  assert.equal(strict.error.code, "ambiguous");
  assert.equal((await run(page, "waitState", { target: saveButtons, state: "gone" })).error.code, "invalid");
  await page.close();
});

test("waitState sees a change inside an open shadow root (the 250 ms poll)", { skip }, async () => {
  const page = await open("/locators");
  const waited = await waitAfter(page, { target: { chain: [{ role: "button", name: { s: "Shadow late", m: "eq" } }], desc: "x" }, state: "attached" }, () => {
    const button = document.createElement("button");
    button.textContent = "Shadow late";
    document.getElementById("host").shadowRoot.append(button);
  });
  assert.equal(waited.answer.done, true);
  assert.ok(waited.afterChange < 450, "within a poll: " + waited.afterChange);
  await page.close();
});

// ---------- the noRefs snapshot, select options

test("a noRefs snapshot (ariaSnapshot) shows no refs and leaves the latest snapshot's resolvable", { skip }, async () => {
  const page = await open("/locators");
  const { yaml } = await run(page, "snapshot", {});
  const save = refOf(yaml, /button "Save"/);
  const aria = await run(page, "snapshot", { target: { chain: [{ css: "#list" }], desc: "locator('#list')" }, noRefs: true });
  assert.equal(aria.ok, true);
  assert.equal(aria.refs, 0);
  assert.ok(!aria.yaml.includes("[ref="), aria.yaml);
  assert.match(aria.yaml, /^- list:\n {2}- listitem:/);
  assert.equal((await run(page, "prepare", { target: save, action: "click" })).status, "ready", "the earlier ref resolves");
  const again = await run(page, "snapshot", {});
  assert.equal(refOf(again.yaml, /button "Save"/), save, "and refs stay stable");
  await page.close();
});

test("selectOption takes Playwright's {value}, {label} and {index}, and answers the values", { skip }, async () => {
  const page = await open("/locators");
  const country = { chain: [{ role: "combobox", name: { s: "Country", m: "eq" } }], desc: "getByRole('combobox')" };
  assert.deepEqual((await run(page, "selectOption", { target: country, values: [{ index: 2 }] })).values, ["it"]);
  assert.deepEqual((await run(page, "selectOption", { target: country, values: [{ label: "France" }] })).values, ["fr"]);
  assert.deepEqual((await run(page, "selectOption", { target: country, values: [{ value: "de" }] })).selected, ["Germany"]);
  assert.equal((await run(page, "selectOption", { target: country, values: [{ label: "france" }] })).error.code, "optionNotFound",
    "a {label} is exact");
  assert.deepEqual((await run(page, "selectOption", { target: country, values: ["italy"] })).values, ["it"], "strings as before");
  await page.close();
});
