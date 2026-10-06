// Seam: tech-watch/feeds.js in Chromium — RSS 2.0, Atom and RDF read with the
// page's own DOMParser; HTML in a feed becomes text without running anything;
// links are http(s) only; a web page's announced feeds are found.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { extensionsRoot } from "./extract.mjs";

const require = createRequire(import.meta.url);
function loadPlaywright() {
  for (const candidate of ["playwright", "/opt/node22/lib/node_modules/playwright"]) {
    try {
      return require(candidate);
    } catch {}
  }
  return null;
}
const playwright = loadPlaywright();
const skip = !playwright && "playwright is not installed";

const fixture = (name) => readFileSync(resolve(extensionsRoot, "tests/fixtures/tech-watch", name), "utf8");
const NOW = Date.UTC(2026, 9, 6, 8);

async function page(browser) {
  const tab = await browser.newPage();
  await tab.setContent("<!doctype html><title>feeds</title>");
  for (const file of ["text.js", "sources.js", "feeds.js"]) {
    await tab.addScriptTag({ content: readFileSync(resolve(extensionsRoot, "tech-watch", file), "utf8") });
  }
  return tab;
}

const parse = (tab, xml, url) => tab.evaluate(([x, u, now]) => {
  try {
    return TechWatch.feeds.parseFeed(x, u, new DOMParser(), now);
  } catch (error) {
    return { error: String(error.message) };
  }
}, [xml, url, NOW]);

test("feeds: RSS 2.0 — relative links resolved, HTML turned into inert text, javascript: links dropped", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const tab = await page(browser);
  const feed = await parse(tab, fixture("feed-rss.xml"), "https://blog.example.com/feed.xml");
  assert.equal(feed.title, "Le blog d'Exemple");
  assert.deepEqual(feed.items.map((i) => i.url), [
    "https://blog.example.com/2026/10/agents",
    "https://blog.example.com/2026/10/sans-date",
  ]);
  const [first, second] = feed.items;
  assert.equal(first.title, "Des agents & des worktrees");
  assert.equal(first.summary, "Un retour d'expérience.");
  assert.equal(first.author, "Camille");
  assert.equal(first.publishedAt, Date.parse("Mon, 05 Oct 2026 08:00:00 GMT"));
  assert.match(first.id, /^rss:[0-9a-f]{8}:[0-9a-f]{8}$/);
  assert.equal(second.publishedAt, NOW, "no date: when it was read");
  await tab.waitForTimeout(200);
  assert.equal(await tab.evaluate(() => window.__pwned), undefined, "nothing in the feed ran");
});

test("feeds: Atom — the alternate link, HTML summaries, updated as a fallback date", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const tab = await page(browser);
  const feed = await parse(tab, fixture("feed-atom.xml"), "https://atom.example.org/feed.atom");
  assert.equal(feed.title, "Atom Example");
  assert.deepEqual(feed.items.map((i) => i.url), ["https://atom.example.org/entries/1", "https://atom.example.org/entries/2"]);
  assert.equal(feed.items[0].summary, "Hello Atom");
  assert.equal(feed.items[0].author, "Robin");
  assert.equal(feed.items[1].publishedAt, Date.parse("2026-10-05T10:00:00Z"));
});

test("feeds: RDF, and what is not a feed", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const tab = await page(browser);
  const rdf = await parse(tab, fixture("feed-rdf.xml"), "https://rdf.example.net/index.rdf");
  assert.equal(rdf.title, "RDF Example");
  assert.equal(rdf.items[0].url, "https://rdf.example.net/a");
  assert.equal(rdf.items[0].publishedAt, Date.parse("2026-10-03T12:00:00Z"));
  assert.ok((await parse(tab, "<rss><channel><item>", "https://x.example.com/f")).error);
  assert.ok((await parse(tab, "<html><body>hi</body></html>", "https://x.example.com/f")).error);
});

test("feeds: a web page's announced RSS and Atom feeds, resolved", { skip }, async (t) => {
  const browser = await playwright.chromium.launch();
  t.after(() => browser.close());
  const tab = await page(browser);
  const found = await tab.evaluate((html) => TechWatch.feeds.discoverFeeds(html, "https://blog.example.com/about", new DOMParser()),
                                   fixture("page.html"));
  assert.deepEqual(found, ["https://blog.example.com/feed.xml", "https://blog.example.com/atom.xml"]);
  assert.equal(await tab.evaluate((html) => TechWatch.feeds.looksLikeHTML(html), fixture("page.html")), true);
  assert.equal(await tab.evaluate((xml) => TechWatch.feeds.looksLikeHTML(xml), fixture("feed-rss.xml")), false);
});
