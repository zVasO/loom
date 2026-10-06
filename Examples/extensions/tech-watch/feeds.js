// @ts-check
// RSS 2.0, Atom and RSS 1.0 (RDF) feeds into the watch's items. Needs a
// DOMParser — the page's, or Chromium's in the tests. A parsed document is
// inert: no script runs, no image loads; HTML descriptions become text.

(() => {
  "use strict";

  const root = /** @type {any} */ (globalThis);
  /** @type {TechWatchTypes.Namespace} */
  const TechWatch = (root.TechWatch = root.TechWatch || /** @type {any} */ ({}));

  /** The direct children of `parent` with one of these local names. @param {Element} parent @param {string[]} names */
  function children(parent, names) {
    return Array.from(parent.children).filter((child) => names.includes(child.localName));
  }

  /** The first such child's text. @param {Element} parent @param {string[]} names */
  function text(parent, names) {
    for (const child of children(parent, names)) {
      const value = child.textContent?.trim();
      if (value) return value;
    }
    return "";
  }

  /** @param {string} html @param {DOMParser} parser */
  function htmlToText(html, parser) {
    if (!/[<&]/.test(html)) return TechWatch.text.collapse(html);
    const document = parser.parseFromString(html, "text/html");
    // Inert, but their source would still read as text.
    for (const element of Array.from(document.querySelectorAll("script, style, noscript, template"))) element.remove();
    return TechWatch.text.collapse(document.body?.textContent ?? "");
  }

  /** An Atom entry's link: rel="alternate", or no rel. @param {Element} entry */
  function atomLink(entry) {
    const links = children(entry, ["link"]);
    const best = links.find((link) => (link.getAttribute("rel") || "alternate") === "alternate") || links[0];
    return best?.getAttribute("href") || "";
  }

  /**
   * @param {string} xml @param {string} feedUrl @param {DOMParser} parser @param {number} now
   * @returns {{ title: string, items: TechWatchTypes.Item[] }}
   */
  function parseFeed(xml, feedUrl, parser, now) {
    const { clip, safeUrl, fnv1a } = TechWatch.text;
    const document = parser.parseFromString(xml, "application/xml");
    if (document.getElementsByTagName("parsererror").length) throw new Error("Ce n'est pas un flux RSS ou Atom lisible.");
    const top = document.documentElement;
    /** @type {Element | null} */ let channel = null;
    /** @type {Element[]} */ let entries = [];
    let atom = false;
    if (top.localName === "rss") {
      channel = children(top, ["channel"])[0] || null;
      entries = channel ? children(channel, ["item"]) : [];
    } else if (top.localName === "feed") {
      atom = true;
      channel = top;
      entries = children(top, ["entry"]);
    } else if (top.localName === "RDF") {
      channel = children(top, ["channel"])[0] || null;
      entries = children(top, ["item"]);
    } else {
      throw new Error("Ce n'est pas un flux RSS ou Atom.");
    }
    const feedTitle = clip(channel ? text(channel, ["title"]) : "", 120) || new URL(feedUrl).hostname;
    /** @type {TechWatchTypes.Item[]} */ const items = [];
    for (const entry of entries.slice(0, 50)) {
      const link = atom ? atomLink(entry) : text(entry, ["link"]) || text(entry, ["guid"]);
      const url = safeUrl(link, feedUrl);
      if (!url) continue;
      const guid = text(entry, atom ? ["id"] : ["guid"]) || url;
      const date = Date.parse(text(entry, atom ? ["published", "updated"] : ["pubDate", "date", "published", "updated"]));
      const body = text(entry, atom ? ["summary", "content"] : ["description", "encoded", "summary"]);
      const author = atom
        ? text(children(entry, ["author"])[0] || entry, ["name"])
        : text(entry, ["creator", "author"]);
      const made = TechWatch.sources.item({
        id: "rss:" + fnv1a(feedUrl) + ":" + fnv1a(guid), source: "rss", sourceLabel: feedTitle,
        title: htmlToText(text(entry, ["title"]), parser), url,
        publishedAt: Number.isFinite(date) ? date : now,
        summary: body ? htmlToText(body, parser) : "", author,
      });
      if (made) items.push(made);
    }
    return { title: feedTitle, items };
  }

  /**
   * The feeds a web page announces: `<link rel="alternate" type="application/rss+xml">`.
   * @param {string} html @param {string} pageUrl @param {DOMParser} parser
   * @returns {string[]}
   */
  function discoverFeeds(html, pageUrl, parser) {
    const document = parser.parseFromString(html, "text/html");
    /** @type {string[]} */ const found = [];
    for (const link of Array.from(document.querySelectorAll("link[rel~='alternate'][href]"))) {
      const type = (link.getAttribute("type") || "").toLowerCase();
      if (!/(rss|atom)\+xml|application\/feed\+json/.test(type) || type.includes("json")) continue;
      const url = TechWatch.text.safeUrl(link.getAttribute("href"), pageUrl);
      if (url && !found.includes(url)) found.push(url);
    }
    return found;
  }

  /** Whether a body looks like a page rather than a feed. @param {string} body */
  function looksLikeHTML(body) {
    return /^\s*(<!doctype html|<html)/i.test(body);
  }

  TechWatch.feeds = Object.freeze({ parseFeed, discoverFeeds, looksLikeHTML, htmlToText });
})();
