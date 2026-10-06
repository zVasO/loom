// @ts-check
/// <reference path="./tech-watch.d.ts" />
// The tech watch's three views — digest, items, settings — drawn from the
// page's state. Everything from a feed or from Claude is set with textContent;
// an href is only ever an http(s) URL the watch checked itself.

(() => {
  "use strict";

  const root = /** @type {any} */ (globalThis);
  /** @type {TechWatchTypes.Namespace} */
  const TechWatch = (root.TechWatch = root.TechWatch || /** @type {any} */ ({}));

  /**
   * @typedef {{
   *   class?: string, href?: string | null, type?: string, value?: string, placeholder?: string,
   *   title?: string, name?: string, min?: string, max?: string, hidden?: boolean, disabled?: boolean,
   *   checked?: boolean, selected?: boolean, dataset?: Record<string, string>, open?: boolean,
   *   on?: Record<string, (event: Event) => void>,
   * }} Props
   * @typedef {Node | string | null | undefined | false} Child
   */

  /** @param {string} tag @param {Props} [props] @param {...(Child | Child[])} children @returns {HTMLElement} */
  function h(tag, props = {}, ...children) {
    const element = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (value === undefined || value === null || value === false) continue;
      if (key === "class") element.className = String(value);
      else if (key === "on") {
        for (const [name, handler] of Object.entries(/** @type {Record<string, any>} */ (value))) {
          element.addEventListener(name, handler);
        }
      } else if (key === "dataset") Object.assign(element.dataset, value);
      else if (key === "href") {
        const safe = TechWatch.text.safeUrl(value);
        if (safe) {
          element.setAttribute("href", safe);
          element.setAttribute("target", "_blank");
          element.setAttribute("rel", "noopener noreferrer");
        }
      } else if (key === "value" || key === "checked" || key === "selected" || key === "disabled" || key === "hidden") {
        /** @type {any} */ (element)[key] = value;
      } else element.setAttribute(key, String(value));
    }
    for (const child of children.flat()) {
      if (child === null || child === undefined || child === false) continue;
      element.append(typeof child === "string" ? document.createTextNode(child) : child);
    }
    return element;
  }

  const timeFormat = new Intl.DateTimeFormat("fr-FR", { hour: "2-digit", minute: "2-digit" });
  const dayFormat = new Intl.DateTimeFormat("fr-FR", { weekday: "long", day: "numeric", month: "long" });

  /** "il y a 3 h". @param {number} then @param {number} now */
  function ago(then, now) {
    const minutes = Math.max(0, Math.round((now - then) / 60_000));
    if (minutes < 1) return "à l'instant";
    if (minutes < 60) return "il y a " + minutes + " min";
    const hours = Math.round(minutes / 60);
    if (hours < 48) return "il y a " + hours + " h";
    return "il y a " + Math.round(hours / 24) + " j";
  }

  /** @param {number} time */
  function when(time) {
    return dayFormat.format(time) + " à " + timeFormat.format(time);
  }

  /** Fills `container` with what is there — a `cond && h(…)` that was false is skipped. @param {HTMLElement} container @param {...(Child | Child[])} children */
  function fill(container, ...children) {
    /** @type {(Node | string)[]} */ const nodes = [];
    for (const child of children.flat()) {
      if (child === null || child === undefined || child === false || child === "") continue;
      nodes.push(child);
    }
    container.replaceChildren(...nodes);
  }

  // MARK: - One item

  /**
   * @param {TechWatchTypes.DigestItem & Partial<TechWatchTypes.StoredItem>} item
   * @param {TechWatchTypes.ViewContext} context
   * @param {{ mustRead?: boolean }} [marks]
   */
  function itemRow(item, context, marks = {}) {
    const stored = context.items.find((candidate) => candidate.id === item.id);
    /** @type {TechWatchTypes.Item & Partial<TechWatchTypes.StoredItem>} */
    const full = { publishedAt: 0, summary: "", ...item, ...(stored || {}) };
    const read = stored ? stored.read === true : false;
    const keywords = stored ? TechWatch.curate.matchKeywords(stored, context.settings.keywords) : [];
    const isNew = stored && context.state.lastDigestAt !== null && stored.firstSeenAt > context.state.lastDigestAt;
    return h("li", { class: read ? "read" : "", dataset: { id: item.id } },
      h("a", { class: "title", href: full.url, on: { click: () => context.actions.markRead(item.id) } }, full.title),
      h("div", { class: "line" },
        h("span", { class: "chip" }, full.sourceLabel),
        marks.mustRead && h("span", { class: "chip must" }, "à lire"),
        isNew && h("span", { class: "chip must" }, "nouveau"),
        ...keywords.map((keyword) => h("span", { class: "chip kw" }, keyword)),
        full.score !== undefined && h("span", {}, full.score + " pts"),
        stored && h("span", {}, ago(stored.publishedAt || stored.firstSeenAt, context.now)),
        full.discussionUrl && h("a", { href: full.discussionUrl }, "discussion"),
        ...(stored?.alsoOn || []).map((other) => other.discussionUrl
          ? h("a", { href: other.discussionUrl }, "aussi sur " + other.sourceLabel)
          : h("span", {}, "aussi sur " + other.sourceLabel)),
        !read && stored && h("button", { type: "button", class: "link", on: { click: () => context.actions.markRead(item.id) } }, "lu"),
        h("button", {
          type: "button", class: "link", title: "Ouvre la feuille de lancement de Loom, avec l'article en contexte",
          dataset: { action: "session" }, on: { click: () => context.actions.sendToSession(full) },
        }, "→ session Claude")),
      stored?.summary && context.showSummaries && h("p", { class: "hint" }, stored.summary));
  }

  // MARK: - Digest

  /** @param {TechWatchTypes.Digest} digest @param {TechWatchTypes.ViewContext} context */
  function digestBody(digest, context) {
    const byId = new Map(digest.items.map((item) => [item.id, item]));
    const covered = new Set(digest.sections.flatMap((section) => section.itemIds));
    const must = new Set(digest.mustRead);
    const rows = (/** @type {string[]} */ ids) =>
      h("ul", { class: "items" }, ids.map((id) => byId.get(id)).filter(Boolean)
        .map((item) => itemRow(/** @type {TechWatchTypes.DigestItem} */ (item), context, { mustRead: must.has(/** @type {any} */ (item).id) })));
    const meta = [when(digest.createdAt), digest.items.length + " articles"];
    if (digest.model) meta.push(digest.model);
    if (typeof digest.costUsd === "number") meta.push(digest.costUsd.toFixed(3) + " $");
    const others = digest.items.filter((item) => !covered.has(item.id)).map((item) => item.id);
    return [
      h("p", { class: "muted" }, meta.join(" · ")),
      digest.error && h("p", { class: "warn" }, "Pas de résumé cette fois : " + digest.error),
      digest.headline && h("p", { class: "headline" }, digest.headline),
      digest.fallbackText && h("div", { class: "card" }, h("p", { class: "fallback" }, digest.fallbackText)),
      ...digest.sections.map((section) => h("div", { class: "card" },
        h("h3", {}, section.theme),
        section.summary && h("p", { class: "summary" }, section.summary),
        rows(section.itemIds))),
      others.length > 0 && h("div", { class: "card" },
        h("h3", {}, digest.sections.length ? "Aussi" : "Les articles"),
        rows(others)),
    ];
  }

  /** @param {HTMLElement} container @param {TechWatchTypes.ViewContext} context */
  function renderDigest(container, context) {
    const [latest, ...older] = context.digests;
    if (!latest) {
      const next = TechWatch.schedule.nextSlotAfter(context.now, context.settings.digestHour, context.settings.digestMinute);
      fill(container, h("p", { class: "empty" },
        context.busy.digest ? "Claude prépare le premier digest…"
          : "Pas encore de digest. Le premier arrive " + when(next) + " — ou tout de suite avec « Résumer maintenant »."));
      return;
    }
    const unread = context.unreadIds;
    fill(container,
      ...digestBody(latest, context),
      unread.length > 0 && h("div", { class: "row" },
        h("button", { type: "button", class: "ghost", on: { click: () => context.actions.markAllRead(unread) } },
          "Tout marquer comme lu")),
      older.length > 0 && h("h2", { class: "muted" }, "Digests précédents"),
      ...older.map((digest) => h("details", { class: "card" },
        h("summary", {}, when(digest.createdAt) + (digest.headline ? " — " + digest.headline : "")),
        ...digestBody(digest, context))));
  }

  // MARK: - Items

  /** @param {HTMLElement} container @param {TechWatchTypes.ViewContext} context */
  function renderItems(container, context) {
    const statuses = Object.entries(context.state.sources).map(([key, status]) => {
      const label = context.sourceLabels[key] || key;
      return status.error
        ? h("span", { class: "chip source-error", title: status.error }, label + " — " + status.error)
        : h("span", { class: "chip source-ok" }, label + (status.count !== undefined ? " · " + status.count : ""));
    });
    const visible = TechWatch.curate.rank(
      context.items.filter((item) => !TechWatch.curate.isMuted(item, context.settings.muted)),
      context.settings, context.now).slice(0, 150);
    fill(container,
      h("div", { class: "sources" }, statuses.length ? statuses : h("span", { class: "muted" }, "Aucune source lue pour l'instant — « Rafraîchir ».")),
      visible.length
        ? h("ul", { class: "items" }, visible.map((item) => itemRow(item, context)))
        : h("p", { class: "empty" }, context.busy.refresh ? "Lecture des sources…" : "Rien pour l'instant."));
  }

  // MARK: - Settings

  /**
   * A list of strings with a remove button each, and an input to add one.
   * @param {{ values: string[], placeholder: string, describe?: (value: string) => Child[],
   *           onAdd: (text: string) => Promise<string | null> | string | null, onRemove: (value: string) => void,
   *           name: string }} options
   */
  function listEditor(options) {
    const error = h("p", { class: "error", hidden: true });
    const input = /** @type {HTMLInputElement} */ (h("input", { type: "text", class: "wide", placeholder: options.placeholder, name: options.name }));
    const add = async () => {
      const text = input.value.trim();
      if (!text) return;
      error.hidden = true;
      const problem = await options.onAdd(text);
      if (problem) {
        error.textContent = problem;
        error.hidden = false;
      } else {
        input.value = "";
      }
    };
    input.addEventListener("keydown", (event) => { if (event.key === "Enter") void add(); });
    return h("div", {},
      h("ul", { class: "list" }, options.values.map((value) => h("li", {},
        h("span", { class: "grow" }, ...(options.describe ? options.describe(value) : [value])),
        h("button", { type: "button", class: "link", title: "Retirer", on: { click: () => options.onRemove(value) } }, "retirer")))),
      h("div", { class: "row" }, input,
        h("button", { type: "button", class: "ghost", dataset: { add: options.name }, on: { click: () => void add() } }, "Ajouter")),
      error);
  }

  /** @param {HTMLElement} container @param {TechWatchTypes.ViewContext} context */
  function renderSettings(container, context) {
    const { settings, actions } = context;
    const pad = (/** @type {number} */ n) => String(n).padStart(2, "0");
    /** @param {(draft: TechWatchTypes.Settings, value: string, input: HTMLInputElement) => void} apply */
    const onChange = (apply) => ({ change: (/** @type {Event} */ event) => {
      const input = /** @type {HTMLInputElement} */ (event.target);
      actions.updateSettings((draft) => apply(draft, input.value, input));
    } });
    /** @param {string} id @param {string} label @param {string[]} values @param {string} current @param {(draft: TechWatchTypes.Settings, value: string) => void} apply */
    const select = (id, label, values, current, apply) => h("label", {}, label,
      h("select", { name: id, on: onChange(apply) },
        values.map((value) => h("option", { value, selected: value === current }, value))));
    const feedGranted = (/** @type {string} */ host) =>
      context.grantedHosts.includes(host) || context.declaredHosts.includes(host);

    fill(container, h("div", { class: "settings" },
      h("h2", {}, "Le digest"),
      h("div", { class: "row" },
        h("label", {}, "Chaque matin à",
          h("input", { type: "time", name: "time", value: pad(settings.digestHour) + ":" + pad(settings.digestMinute),
                       on: onChange((draft, value) => {
                         const [hour, minute] = value.split(":").map(Number);
                         draft.digestHour = hour;
                         draft.digestMinute = minute;
                       }) })),
        select("language", "Langue", ["fr", "en"], settings.language, (draft, value) => { draft.language = /** @type {any} */ (value); }),
        select("model", "Modèle", ["haiku", "sonnet", "opus"], settings.model, (draft, value) => { draft.model = /** @type {any} */ (value); }),
        h("label", {}, "Articles au plus",
          h("input", { type: "number", name: "maxItems", min: "5", max: "60", value: String(settings.maxItems),
                       on: onChange((draft, value) => { draft.maxItems = Number(value); }) }))),
      h("p", { class: "hint" }, "Claude écrit le résumé avec votre compte Claude Code, sans aucun outil : il ne voit que les titres et extraits. Le coût compte sur votre forfait."),

      h("h2", {}, "Centres d'intérêt"),
      h("p", { class: "hint" }, "Mis en avant dans le tri et signalés à Claude."),
      listEditor({ name: "keyword", values: settings.keywords, placeholder: "swift, mcp, claude…",
                   onAdd: (text) => actions.editList("keywords", "add", text), onRemove: (value) => actions.editList("keywords", "remove", value) }),
      h("h2", {}, "Mots à ignorer"),
      listEditor({ name: "muted", values: settings.muted, placeholder: "crypto, nft…",
                   onAdd: (text) => actions.editList("muted", "add", text), onRemove: (value) => actions.editList("muted", "remove", value) }),

      h("h2", {}, "Hacker News"),
      h("div", { class: "row" },
        h("label", {}, h("input", { type: "checkbox", name: "hn", checked: settings.hn.enabled,
                                    on: onChange((draft, _value, input) => { draft.hn.enabled = input.checked; }) }), "Lire Hacker News"),
        h("label", {}, "Points au moins",
          h("input", { type: "number", name: "minPoints", min: "0", max: "2000", value: String(settings.hn.minPoints),
                       on: onChange((draft, value) => { draft.hn.minPoints = Number(value); }) })),
        h("label", {}, "Recherche",
          h("input", { type: "text", name: "hnQuery", placeholder: "(tout)", value: settings.hn.query,
                       on: onChange((draft, value) => { draft.hn.query = value; }) }))),

      h("h2", {}, "Releases GitHub"),
      listEditor({ name: "repo", values: settings.github.repos, placeholder: "owner/repo",
                   onAdd: (text) => actions.editList("repos", "add", text), onRemove: (value) => actions.editList("repos", "remove", value) }),
      h("div", { class: "row" },
        h("label", {}, "Jeton GitHub (optionnel, 60 requêtes/h sans)",
          h("input", { type: "password", name: "githubToken", placeholder: context.githubTokenSet ? "•••••• enregistré" : "ghp_…",
                       on: { change: (event) => {
                         const input = /** @type {HTMLInputElement} */ (event.target);
                         if (input.value.trim()) void actions.setGithubToken(input.value.trim());
                       } } })),
        context.githubTokenSet && h("button", { type: "button", class: "link", on: { click: () => void actions.setGithubToken(null) } }, "oublier le jeton")),

      h("h2", {}, "Reddit"),
      listEditor({ name: "subreddit", values: settings.reddit.subreddits, placeholder: "r/swift",
                   describe: (value) => ["r/" + value],
                   onAdd: (text) => actions.editList("subreddits", "add", text), onRemove: (value) => actions.editList("subreddits", "remove", value) }),

      h("h2", {}, "Lobsters"),
      h("div", { class: "row" },
        h("label", {}, h("input", { type: "checkbox", name: "lobsters", checked: settings.lobsters.enabled,
                                    on: onChange((draft, _value, input) => { draft.lobsters.enabled = input.checked; }) }), "Lire Lobsters")),
      listEditor({ name: "lobstersTag", values: settings.lobsters.tags, placeholder: "tag (vide : la une)",
                   onAdd: (text) => actions.editList("lobstersTags", "add", text), onRemove: (value) => actions.editList("lobstersTags", "remove", value) }),

      h("h2", {}, "Flux RSS / Atom"),
      h("p", { class: "hint" }, "Loom vous demande d'autoriser chaque nouveau site. Une page web qui annonce son flux convient aussi."),
      listEditor({ name: "feed", values: settings.feeds.map((feed) => feed.url), placeholder: "https://exemple.com/feed.xml",
                   describe: (url) => {
                     const feed = settings.feeds.find((candidate) => candidate.url === url);
                     const host = feed ? feed.host : url;
                     const status = context.state.sources["rss:" + url];
                     return [
                       h("a", { href: url }, feed ? feed.title : url), " ",
                       h("span", { class: "muted" }, host),
                       !feedGranted(host) && h("span", { class: "warn" }, " · accès retiré "),
                       !feedGranted(host) && h("button", { type: "button", class: "link", on: { click: () => void actions.regrant(host) } }, "redemander"),
                       status?.error && feedGranted(host) && h("span", { class: "error" }, " · " + status.error),
                     ];
                   },
                   onAdd: (text) => actions.addFeed(text), onRemove: (value) => actions.removeFeed(value) })));
  }

  TechWatch.view = Object.freeze({ h, renderDigest, renderItems, renderSettings, ago, when });
})();
