import Foundation
import LoomAPI

/// The colours and the look a report is written in — a Loom theme's
/// tokens, mapped by role (ADR-0017), and its document style.
public struct ArtifactPalette: Codable, Equatable, Sendable {
    public var isDark: Bool
    public var bg: String
    public var card: String
    public var bgSubtle: String
    /// Header band and footer.
    public var bgWarm: String
    public var line: String
    /// The brand accent: the rule under titles, the H1's key word, the timeline's dots.
    public var brand: String
    /// Links, buttons, focus, the active tab.
    public var link: String
    public var onLink: String
    public var fg1: String
    public var fg2: String
    public var fg3: String
    public var statusBlock: String
    public var statusFix: String
    public var statusOK: String
    public var fontSans: String
    public var fontMono: String
    /// A Google Fonts stylesheet, or nil.
    public var fontsURL: String?
    public var radius: String
    public var logoSVG: String?
    public var extraCSS: String?

    public init(isDark: Bool = false, bg: String = "#FFFFFF", card: String = "#FFFFFF",
                bgSubtle: String = "#F4F4F4", bgWarm: String = "#FFF3E5", line: String = "#DCDCDC",
                brand: String = "#E22C22", link: String = "#0D6E74", onLink: String = "#FFFFFF",
                fg1: String = "#1E1E1E", fg2: String = "#505050", fg3: String = "#767676",
                statusBlock: String = "#A61A16", statusFix: String = "#C64C00", statusOK: String = "#007153",
                fontSans: String = ArtifactPalette.defaultSans, fontMono: String = ArtifactPalette.defaultMono,
                fontsURL: String? = ArtifactPalette.defaultFontsURL, radius: String = "16px",
                logoSVG: String? = nil, extraCSS: String? = nil) {
        self.isDark = isDark
        self.bg = bg
        self.card = card
        self.bgSubtle = bgSubtle
        self.bgWarm = bgWarm
        self.line = line
        self.brand = brand
        self.link = link
        self.onLink = onLink
        self.fg1 = fg1
        self.fg2 = fg2
        self.fg3 = fg3
        self.statusBlock = statusBlock
        self.statusFix = statusFix
        self.statusOK = statusOK
        self.fontSans = fontSans
        self.fontMono = fontMono
        self.fontsURL = fontsURL
        self.radius = radius
        self.logoSVG = logoSVG
        self.extraCSS = extraCSS
    }

    public static let defaultSans = #""Nunito", ui-rounded, "Segoe UI", system-ui, sans-serif"#
    public static let defaultMono = #""JetBrains Mono", ui-monospace, Menlo, monospace"#
    public static let defaultFontsURL =
        "https://fonts.googleapis.com/css2?family=Nunito:wght@400;600;700;800&family=JetBrains+Mono:wght@400;600&display=swap"
}

/// A run's report: one self-contained HTML file — its data inline, its
/// script inline, nothing fetched but the theme's fonts.
public enum ArtifactRenderer {

    public static let templates: [(id: String, name: String)] = [
        ("pr-review", "Rapport de review de PR"),
        ("generic", "Rapport générique"),
    ]

    public static func html(template: String, title: String, palette: ArtifactPalette, data: JSONValue) -> String {
        let fonts = palette.fontsURL.flatMap { url -> String? in
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host == "fonts.googleapis.com"
            else { return nil }
            return """
            <link rel="preconnect" href="https://fonts.googleapis.com">
            <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
            <link rel="stylesheet" href="\(escapeAttribute(url))">
            """
        } ?? ""
        return page
            .replacingOccurrences(of: "/*LOOM_TITLE*/", with: escapeText(title))
            .replacingOccurrences(of: "<!--LOOM_FONTS-->", with: fonts)
            .replacingOccurrences(of: "/*LOOM_VARS*/", with: cssVariables(palette))
            .replacingOccurrences(of: "/*LOOM_EXTRA_CSS*/", with: sanitizedCSS(palette.extraCSS ?? ""))
            .replacingOccurrences(of: "<!--LOOM_LOGO-->", with: sanitizedSVG(palette.logoSVG ?? ""))
            .replacingOccurrences(of: "/*LOOM_TEMPLATE*/", with: template == "generic" ? "generic" : "pr-review")
            .replacingOccurrences(of: "/*LOOM_DATA*/", with: embed(data))
    }

    /// The palette as the custom properties the page's CSS reads.
    public static func cssVariables(_ p: ArtifactPalette) -> String {
        let vars: [(String, String)] = [
            ("color-scheme", p.isDark ? "dark" : "light"),
            ("--bg", p.bg), ("--card", p.card), ("--bg-subtle", p.bgSubtle), ("--bg-warm", p.bgWarm),
            ("--line", p.line), ("--brand", p.brand), ("--link", p.link), ("--on-link", p.onLink),
            ("--fg1", p.fg1), ("--fg2", p.fg2), ("--fg3", p.fg3),
            ("--status-block", p.statusBlock), ("--status-fix", p.statusFix), ("--status-ok", p.statusOK),
            ("--font", p.fontSans), ("--mono", p.fontMono), ("--radius", p.radius),
        ]
        return vars.map { "  \($0.0): \(sanitizedValue($0.1));" }.joined(separator: "\n")
    }

    /// JSON inside a `<script>`: `</` can never close it.
    public static func embed(_ data: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(data)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return json.replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "<!--", with: "<\\!--")
    }

    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A token value cannot leave its declaration.
    static func sanitizedValue(_ value: String) -> String {
        value.filter { !";{}<>".contains($0) }
    }

    /// The theme's own CSS stays CSS.
    static func sanitizedCSS(_ css: String) -> String {
        css.replacingOccurrences(of: "</", with: "<\\/")
    }

    /// An inline logo: an `<svg>` element, without scripts or handlers.
    static func sanitizedSVG(_ svg: String) -> String {
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<svg"), trimmed.lowercased().hasSuffix("</svg>") else { return "" }
        let lowered = trimmed.lowercased()
        if lowered.contains("<script") || lowered.contains("javascript:") || lowered.contains("<foreignobject") {
            return ""
        }
        guard let regex = try? NSRegularExpression(pattern: #"\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
                                                   options: [.caseInsensitive]) else { return "" }
        return regex.stringByReplacingMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed),
                                              withTemplate: "")
    }

    // MARK: The page

    static let page = #"""
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>/*LOOM_TITLE*/</title>
<!--LOOM_FONTS-->
<style>
:root {
/*LOOM_VARS*/
  --shadow-sm: 0 0 24px 0 rgba(30, 30, 30, 0.05);
  --shadow-md: 0 1px 2px rgba(30, 30, 30, 0.06), 0 10px 28px rgba(30, 30, 30, 0.07);
  --ease-out: cubic-bezier(0.16, 1, 0.3, 1);
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body { margin: 0; background: var(--bg); color: var(--fg1); font-family: var(--font);
  font-size: 16px; line-height: 1.55; -webkit-font-smoothing: antialiased; }
a { color: var(--link); }
:focus-visible { outline: 3px solid var(--link); outline-offset: 2px; }
code, pre, .mono { font-family: var(--mono); font-size: 13px; }
pre { background: var(--bg-subtle); border-radius: 10px; padding: 12px 14px; overflow-x: auto; white-space: pre-wrap; }
:not(pre) > code { background: var(--bg-subtle); border-radius: 6px; padding: 1px 6px; }
.wrap { max-width: 1080px; margin: 0 auto; padding: 0 16px; }

.hero { background: var(--bg-warm); border-radius: 0 0 32px 32px; padding: 28px 0 36px; }
.hero .top { display: flex; align-items: center; gap: 14px; min-height: 36px; }
.hero .logo svg { height: 34px; width: auto; display: block; }
.eyebrow { text-transform: uppercase; letter-spacing: .12em; font-size: 12px; font-weight: 800; color: var(--fg2); }
h1 { font-size: clamp(28px, 4.2vw, 40px); font-weight: 800; line-height: 1.15; margin: 14px 0 12px; }
h1 .key { color: var(--brand); }
.hero-grid { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 24px; align-items: start; }
@media (max-width: 820px) { .hero-grid { grid-template-columns: 1fr; } }
.meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 6px; }
.pill { display: inline-flex; align-items: center; gap: 6px; border-radius: 999px; padding: 4px 12px;
  font-size: 13px; font-weight: 700; background: var(--card); color: var(--fg2); box-shadow: var(--shadow-sm); }
.pill.ok { color: var(--status-ok); } .pill.fix { color: var(--status-fix); } .pill.block { color: var(--status-block); }
.verdict { background: var(--card); border-radius: var(--radius); box-shadow: var(--shadow-md); padding: 20px 22px; }
.verdict .label { font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: .1em; color: var(--fg3); }
.verdict .value { font-size: 24px; font-weight: 800; margin: 4px 0 12px; }
.verdict .value.ok { color: var(--status-ok); } .verdict .value.fix { color: var(--status-fix); }
.verdict .value.block { color: var(--status-block); }
.stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
.stat b { display: block; font-size: 22px; font-weight: 800; }
.stat span { font-size: 12px; color: var(--fg3); }

nav.toc { position: sticky; top: 0; z-index: 5; background: color-mix(in srgb, var(--bg) 88%, transparent);
  backdrop-filter: blur(8px); padding: 12px 0; }
nav.toc .wrap { display: flex; gap: 8px; overflow-x: auto; }
nav.toc a { text-decoration: none; white-space: nowrap; border-radius: 999px; padding: 6px 14px; font-size: 14px;
  font-weight: 700; color: var(--fg2); background: var(--bg-subtle); transition: background .3s var(--ease-out), color .3s; }
nav.toc a.active { background: var(--link); color: var(--on-link); }

section { padding: 28px 0 8px; scroll-margin-top: 64px; }
h2 { font-size: 26px; font-weight: 800; margin: 0 0 18px; }
h2::after { content: ""; display: block; width: 36px; height: 4px; margin-top: 10px; border-radius: 999px;
  background: var(--brand); transform-origin: left; }
h3 { font-size: 18px; font-weight: 800; margin: 0 0 6px; }
.card { background: var(--card); border-radius: var(--radius); box-shadow: var(--shadow-md); padding: 20px 22px; margin-bottom: 14px; }
.muted { color: var(--fg3); }
.grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 14px; }

.timeline { position: relative; margin: 0; padding: 0 0 0 28px; list-style: none; }
.timeline::before { content: ""; position: absolute; left: 7px; top: 6px; bottom: 6px; width: 2px;
  background: var(--line); transform-origin: top; }
.timeline li { position: relative; padding: 0 0 18px; }
.timeline li::before { content: ""; position: absolute; left: -26px; top: 6px; width: 12px; height: 12px;
  border-radius: 999px; background: var(--brand); box-shadow: 0 0 0 4px var(--bg); }
.timeline .path { font-family: var(--mono); font-weight: 600; font-size: 14px; }

table { width: 100%; border-collapse: collapse; }
th { text-align: left; font-size: 13px; color: var(--fg2); background: var(--bg-subtle); padding: 10px 12px; }
th:first-child { border-radius: 10px 0 0 10px; } th:last-child { border-radius: 0 10px 10px 0; }
td { padding: 12px; border-bottom: 1px solid var(--line); vertical-align: top; }

.finding { border-left: 4px solid var(--line); }
.finding.block { border-left-color: var(--status-block); }
.finding.fix { border-left-color: var(--status-fix); }
.finding.minor { border-left-color: var(--fg3); }
.finding .where { font-family: var(--mono); font-size: 13px; color: var(--fg2); margin: 2px 0 8px; }
.gauge { height: 6px; border-radius: 999px; background: var(--bg-subtle); overflow: hidden; margin-top: 10px; }
.gauge i { display: block; height: 100%; width: 0; background: var(--link); border-radius: 999px;
  transition: width 1.1s var(--ease-out); }
.tabs { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 14px; }
.tabs button { font: inherit; font-size: 14px; font-weight: 700; border: 0; cursor: pointer; border-radius: 999px;
  padding: 6px 14px; background: var(--bg-subtle); color: var(--fg2); transition: background .3s var(--ease-out), color .3s; }
.tabs button[aria-selected="true"] { background: var(--link); color: var(--on-link); }
details summary { cursor: pointer; font-weight: 700; }

footer { background: var(--bg-warm); border-radius: 32px 32px 0 0; margin-top: 40px; padding: 28px 0;
  color: var(--fg2); font-size: 14px; }

.reveal { opacity: 0; transform: translateY(18px); transition: opacity .7s var(--ease-out), transform .7s var(--ease-out);
  transition-delay: calc(var(--i, 0) * 60ms); }
.reveal.in { opacity: 1; transform: none; }
h2.reveal::after { transform: scaleX(0); transition: transform .8s var(--ease-out) .2s; }
h2.reveal.in::after { transform: scaleX(1); }
.timeline.reveal::before { transform: scaleY(0); transition: transform 1.2s var(--ease-out) .1s; }
.timeline.reveal.in::before { transform: scaleY(1); }
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  .reveal, .reveal.in, h2.reveal::after, .timeline.reveal::before, .gauge i, nav.toc a, .tabs button {
    transition: none !important; opacity: 1; transform: none; }
}
/*LOOM_EXTRA_CSS*/
</style>
</head>
<body>
<header class="hero"><div class="wrap">
  <div class="top"><div class="logo"><!--LOOM_LOGO--></div><div class="eyebrow" id="eyebrow"></div></div>
  <div class="hero-grid">
    <div><h1 id="title"></h1><div class="meta" id="meta"></div></div>
    <aside class="verdict reveal" id="verdict"></aside>
  </div>
</div></header>
<nav class="toc" aria-label="Sommaire"><div class="wrap" id="toc"></div></nav>
<main class="wrap" id="main"></main>
<footer><div class="wrap" id="footer"></div></footer>
<script type="application/json" id="loom-data">/*LOOM_DATA*/</script>
<script>
(function () {
  "use strict";
  var TEMPLATE = "/*LOOM_TEMPLATE*/";
  var data = {};
  try { data = JSON.parse(document.getElementById("loom-data").textContent); } catch (e) {}
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  // Markdown, the little claude writes: paragraphs, bullets, `code`, **bold**, fences.
  function md(text) {
    var out = el("div");
    var source = String(text || "");
    var blocks = source.split(/```/);
    blocks.forEach(function (block, i) {
      if (i % 2 === 1) {
        var lines = block.split("\n");
        if (/^[a-z0-9_-]*$/i.test(lines[0])) lines.shift();
        out.appendChild(el("pre", null, lines.join("\n").replace(/\n$/, "")));
        return;
      }
      block.split(/\n{2,}/).forEach(function (para) {
        var trimmed = para.trim();
        if (!trimmed) return;
        var lines = trimmed.split("\n");
        var bullets = lines.every(function (l) { return /^\s*([-*]|\d+\.)\s+/.test(l); });
        var html = function (s) {
          return esc(s).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
        };
        if (bullets) {
          var ul = el("ul");
          lines.forEach(function (l) { var li = el("li"); li.innerHTML = html(l.replace(/^\s*([-*]|\d+\.)\s+/, "")); ul.appendChild(li); });
          out.appendChild(ul);
        } else {
          var p = el("p");
          p.innerHTML = lines.map(html).join("<br>");
          out.appendChild(p);
        }
      });
    });
    return out;
  }
  function asText(value) {
    if (value === null || value === undefined) return "";
    if (typeof value === "string") return value;
    if (typeof value === "number" || typeof value === "boolean") return String(value);
    return JSON.stringify(value, null, 2);
  }
  function list(value) { return Array.isArray(value) ? value : []; }

  var steps = data.steps || {};
  var nodes = list(data.nodes);
  function titleOf(id) {
    for (var i = 0; i < nodes.length; i++) if (nodes[i].id === id) return nodes[i].title || id;
    return id;
  }
  function find(key) {
    var ids = Object.keys(steps);
    for (var i = 0; i < ids.length; i++) {
      var out = steps[ids[i]];
      if (out && out[key] !== undefined && out[key] !== null && out[key] !== "") return { id: ids[i], value: out[key], step: out };
    }
    return null;
  }
  var consolidated = null;
  Object.keys(steps).forEach(function (id) {
    var out = steps[id];
    if (out && out.verdict !== undefined && Array.isArray(out.findings)) consolidated = { id: id, step: out };
  });
  var expertIDs = Object.keys(steps).filter(function (id) {
    var out = steps[id];
    return out && Array.isArray(out.findings) && (!consolidated || id !== consolidated.id);
  });

  function severityClass(s) {
    s = String(s || "").toLowerCase();
    if (/block|bloq|critical|high|major/.test(s)) return "block";
    if (/fix|corrig|medium|warn/.test(s)) return "fix";
    return "minor";
  }
  function severityLabel(s) {
    var c = severityClass(s);
    return c === "block" ? "Bloquant" : c === "fix" ? "À corriger" : "Mineur";
  }
  function verdictInfo(v) {
    v = String(v || "").toLowerCase();
    if (/approve|ok|accept/.test(v)) return { label: "Approuver", cls: "ok" };
    if (/request|change|reject|block/.test(v)) return { label: "Demander des changements", cls: "block" };
    if (v) return { label: "Commenter", cls: "fix" };
    return { label: "—", cls: "" };
  }

  // Hero
  var pr = data.pr || {};
  document.getElementById("eyebrow").textContent =
    (TEMPLATE === "pr-review" ? "Review de PR" : "Rapport") + " · " + (data.workflow || "Workflow");
  var h1 = document.getElementById("title");
  if (pr.number) { h1.appendChild(el("span", "key", "#" + pr.number + " ")); }
  h1.appendChild(document.createTextNode(data.title || pr.title || "Rapport"));
  var meta = document.getElementById("meta");
  if (pr.author) meta.appendChild(el("span", "pill", "@" + pr.author));
  if (pr.head) meta.appendChild(el("span", "pill mono", pr.head + " → " + (pr.base || "")));
  if (pr.additions !== undefined) meta.appendChild(el("span", "pill", "+" + pr.additions + " −" + (pr.deletions || 0)));
  if (data.ticket && data.ticket.key) meta.appendChild(el("span", "pill", data.ticket.key));
  if (pr.url) { var a = el("a", "pill", "Ouvrir sur GitHub"); a.href = pr.url; meta.appendChild(a); }

  var verdict = document.getElementById("verdict");
  var info = verdictInfo(consolidated && consolidated.step.verdict);
  verdict.appendChild(el("div", "label", "Verdict suggéré"));
  verdict.appendChild(el("div", "value " + info.cls, info.label));
  var stats = el("div", "stats");
  function stat(n, label, suffix) {
    var s = el("div", "stat");
    var b = el("b", null, "0");
    b.setAttribute("data-count", n);
    if (suffix) b.setAttribute("data-suffix", suffix);
    s.appendChild(b);
    s.appendChild(el("span", null, label));
    stats.appendChild(s);
  }
  var findings = consolidated ? list(consolidated.step.findings) : [];
  stat(findings.length, "retours");
  stat(findings.filter(function (f) { return severityClass(f.severity) === "block"; }).length, "bloquants");
  stat((data.run && data.run.passes) || 1, "passes");
  verdict.appendChild(stats);
  if (consolidated && consolidated.step.stable !== undefined) {
    verdict.appendChild(el("div", "pill " + (consolidated.step.stable ? "ok" : "fix"),
      consolidated.step.stable ? "Review stable" : "Review encore mouvante"));
  }

  // Sections
  var main = document.getElementById("main");
  var toc = document.getElementById("toc");
  function section(id, title) {
    var s = el("section");
    s.id = id;
    s.appendChild(el("h2", "reveal", title));
    main.appendChild(s);
    var link = el("a", null, title);
    link.href = "#" + id;
    toc.appendChild(link);
    return s;
  }
  function card(parent, cls) { var c = el("div", "card reveal" + (cls ? " " + cls : "")); parent.appendChild(c); return c; }

  var intent = find("intent");
  if (intent) {
    var s1 = section("intention", "Intention de la PR");
    card(s1).appendChild(md(intent.value));
    var risks = find("risks");
    if (risks && list(risks.value).length) {
      var rc = card(s1);
      rc.appendChild(el("h3", null, "Points de vigilance"));
      var wrapRisks = el("div", "meta");
      list(risks.value).forEach(function (r) { wrapRisks.appendChild(el("span", "pill fix", asText(r))); });
      rc.appendChild(wrapRisks);
    }
    var questions = find("questions");
    if (questions && list(questions.value).length) {
      var qc = card(s1);
      qc.appendChild(el("h3", null, "Questions ouvertes"));
      qc.appendChild(md(list(questions.value).map(function (q) { return "- " + asText(q); }).join("\n")));
    }
  }

  var order = find("readingOrder");
  if (order && list(order.value).length) {
    var s2 = section("lecture", "Sens de lecture");
    var ol = el("ol", "timeline reveal");
    list(order.value).forEach(function (item, i) {
      var li = el("li", "reveal");
      li.style.setProperty("--i", i);
      var path = typeof item === "string" ? item : (item.path || item.file || "");
      li.appendChild(el("div", "path", path));
      if (item && item.why) li.appendChild(el("div", "muted", item.why));
      ol.appendChild(li);
    });
    card(s2).appendChild(ol);
  }

  var criteria = find("ticketCriteria");
  var ticketStep = find("acceptanceCriteria");
  if ((criteria && list(criteria.value).length) || (ticketStep && ticketStep.step.summary)) {
    var s3 = section("ticket", "Le ticket est-il traité ?");
    if (ticketStep) {
      var tc = card(s3);
      tc.appendChild(el("h3", null, (ticketStep.step.key ? ticketStep.step.key + " — " : "") + (ticketStep.step.summary || "")));
      if (ticketStep.step.description) tc.appendChild(md(ticketStep.step.description));
    }
    if (criteria && list(criteria.value).length) {
      var table = el("table");
      var head = el("tr");
      ["Critère", "Statut", "Dans le code"].forEach(function (h) { head.appendChild(el("th", null, h)); });
      table.appendChild(head);
      list(criteria.value).forEach(function (c) {
        var tr = el("tr");
        tr.appendChild(el("td", null, typeof c === "string" ? c : c.criterion || ""));
        var status = String((c && c.status) || "").toLowerCase();
        var cls = status === "ok" ? "ok" : status === "partial" ? "fix" : "block";
        var label = status === "ok" ? "Couvert" : status === "partial" ? "Partiel" : "Manquant";
        var td = el("td");
        td.appendChild(el("span", "pill " + cls, label));
        tr.appendChild(td);
        tr.appendChild(el("td", "muted", (c && c.evidence) || ""));
        table.appendChild(tr);
      });
      card(s3).appendChild(table);
    }
  }

  function findingCard(parent, f, i) {
    var c = card(parent, "finding " + severityClass(f.severity));
    c.style.setProperty("--i", i % 8);
    var top = el("div", "meta");
    top.appendChild(el("span", "pill " + severityClass(f.severity), severityLabel(f.severity)));
    if (f.expert) top.appendChild(el("span", "pill", f.expert));
    c.appendChild(top);
    c.appendChild(el("h3", null, f.title || "Retour"));
    if (f.path) c.appendChild(el("div", "where", f.path + (f.line ? ":" + f.line : "")));
    if (f.detail) c.appendChild(md(f.detail));
    if (f.suggestion) c.appendChild(md(f.suggestion));
    if (typeof f.confidence === "number") {
      var g = el("div", "gauge");
      var bar = el("i");
      bar.setAttribute("data-width", Math.round(Math.max(0, Math.min(1, f.confidence)) * 100) + "%");
      g.appendChild(bar);
      g.title = "Confiance " + Math.round(f.confidence * 100) + " %";
      c.appendChild(g);
    }
  }
  function sortBySeverity(items) {
    var rank = { block: 0, fix: 1, minor: 2 };
    return items.slice().sort(function (a, b) { return rank[severityClass(a.severity)] - rank[severityClass(b.severity)]; });
  }

  if (consolidated) {
    var s4 = section("retours", "Retours du code");
    if (consolidated.step.summary) card(s4).appendChild(md(consolidated.step.summary));
    sortBySeverity(findings).forEach(function (f, i) { findingCard(s4, f, i); });
    if (!findings.length) card(s4).appendChild(el("p", "muted", "Aucun retour retenu."));
  }

  if (expertIDs.length) {
    var s5 = section("experts", "Par expert");
    var tabs = el("div", "tabs");
    tabs.setAttribute("role", "tablist");
    var panel = el("div");
    s5.appendChild(tabs);
    s5.appendChild(panel);
    function show(id) {
      Array.prototype.forEach.call(tabs.children, function (b) { b.setAttribute("aria-selected", b.getAttribute("data-id") === id ? "true" : "false"); });
      panel.innerHTML = "";
      var out = steps[id];
      if (out.summary) card(panel).appendChild(md(out.summary));
      sortBySeverity(list(out.findings)).forEach(function (f, i) { findingCard(panel, f, i); });
      if (!list(out.findings).length) card(panel).appendChild(el("p", "muted", "Rien à signaler."));
      reveal(panel);
    }
    expertIDs.forEach(function (id, i) {
      var b = el("button", null, titleOf(id) + " · " + list(steps[id].findings).length);
      b.setAttribute("role", "tab");
      b.setAttribute("data-id", id);
      b.addEventListener("click", function () { show(id); });
      tabs.appendChild(b);
    });
    setTimeout(function () { show(expertIDs[0]); }, 0);
  }

  var history = (data.history || {});
  if (consolidated && list(history[consolidated.id]).length) {
    var s6 = section("passes", "Les passes");
    var passes = list(history[consolidated.id]).concat([consolidated.step]);
    var tl = el("ol", "timeline reveal");
    passes.forEach(function (p, i) {
      var li = el("li", "reveal");
      li.style.setProperty("--i", i);
      li.appendChild(el("div", "path", "Passe " + (i + 1) + " · " + list(p.findings).length + " retours" + (p.stable ? " · stable" : "")));
      if (p.changes) li.appendChild(md(p.changes));
      tl.appendChild(li);
    });
    card(s6).appendChild(tl);
  }

  var dropped = consolidated && list(consolidated.step.dropped);
  if (dropped && dropped.length) {
    var s7 = section("ecartes", "Écartés");
    dropped.forEach(function (d) {
      var c = card(s7);
      c.appendChild(el("h3", null, d.title || asText(d)));
      if (d.why) c.appendChild(el("p", "muted", d.why));
    });
  }

  var detailIDs = Object.keys(steps);
  if (detailIDs.length) {
    var s8 = section("etapes", TEMPLATE === "generic" ? "Étapes" : "Détails des étapes");
    detailIDs.forEach(function (id) {
      var c = card(s8);
      var d = el("details");
      if (TEMPLATE === "generic") d.open = true;
      d.appendChild(el("summary", null, titleOf(id)));
      var out = steps[id];
      if (out && out.text && TEMPLATE === "generic") d.appendChild(md(out.text));
      else d.appendChild(el("pre", null, asText(out)));
      c.appendChild(d);
    });
  }

  // Footer
  var run = data.run || {};
  var foot = document.getElementById("footer");
  var parts = ["Généré par Loom", data.workflow || ""];
  if (run.finishedAt) parts.push(new Date(run.finishedAt).toLocaleString("fr-FR"));
  if (typeof run.costUSD === "number" && run.costUSD > 0) parts.push("coût " + run.costUSD.toFixed(2) + " $");
  foot.textContent = parts.filter(Boolean).join(" · ");

  // Motion: reveal on scroll, counters, gauges, the active tab of the table of contents.
  function countUp(node) {
    var target = Number(node.getAttribute("data-count")) || 0;
    if (reduce || target === 0) { node.textContent = String(target); return; }
    var start = performance.now(), duration = 900;
    function tick(now) {
      var t = Math.min(1, (now - start) / duration);
      var eased = 1 - Math.pow(1 - t, 3);
      node.textContent = String(Math.round(target * eased));
      if (t < 1) requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }
  function fill(root) {
    Array.prototype.forEach.call(root.querySelectorAll(".gauge i[data-width]"), function (bar) {
      requestAnimationFrame(function () { bar.style.width = bar.getAttribute("data-width"); });
    });
  }
  var observer = ("IntersectionObserver" in window && !reduce) ? new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("in");
      fill(entry.target);
      observer.unobserve(entry.target);
    });
  }, { rootMargin: "0px 0px -8% 0px" }) : null;
  function reveal(root) {
    Array.prototype.forEach.call(root.querySelectorAll(".reveal:not(.in)"), function (node, i) {
      if (!node.style.getPropertyValue("--i")) node.style.setProperty("--i", i % 6);
      if (observer) observer.observe(node); else { node.classList.add("in"); fill(node); }
    });
  }
  reveal(document);
  Array.prototype.forEach.call(document.querySelectorAll("[data-count]"), countUp);
  var links = toc.querySelectorAll("a");
  if (links.length) links[0].classList.add("active");
  if ("IntersectionObserver" in window) {
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        Array.prototype.forEach.call(links, function (l) { l.classList.toggle("active", l.getAttribute("href") === "#" + entry.target.id); });
      });
    }, { rootMargin: "-40% 0px -55% 0px" });
    Array.prototype.forEach.call(main.querySelectorAll("section"), function (s) { spy.observe(s); });
  }
})();
</script>
</body>
</html>
"""#
}
