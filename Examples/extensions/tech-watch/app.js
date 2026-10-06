// @ts-check
/// <reference path="../loom.d.ts" />
/// <reference path="./tech-watch.d.ts" />

// Veille techno — a Loom extension (docs/extensions.md, ADR-0015). This page
// runs from Loom's launch ("background") and is also the extension's tab.
// Every morning Loom's alarm wakes it: it reads the sources (loom.http.fetch),
// asks Claude for a digest (loom.claude.complete — text only, the user's
// Claude Code account), stores it, and shows "📰 N" in Loom's top bar. Feeds
// the user adds are new hosts: Loom asks them first (loom.network.request).

(() => {
  "use strict";

  const KEY_SETTINGS = "settings";
  const KEY_ITEMS = "items";
  const KEY_STATE = "state";
  const KEY_DIGESTS = "digests";
  const SECRET_GITHUB = "github-token";
  const ALARM_DIGEST = "digest";
  const ALARM_CATCH_UP = "digest-catchup";
  /** Of loom.storage's megabyte, what items and digests may hold. */
  const BUDGET = 700_000;
  const MAX_DIGESTS = 7;
  const CONCURRENCY = 4;

  const { sanitizeSettings } = TechWatch.settings;
  const { nextSlotAfter, isDigestDue, digestWindow } = TechWatch.schedule;
  const { mergeItems, prune, selectForDigest, fitBudget } = TechWatch.curate;

  /** @type {TechWatchTypes.Settings} */ let settings = sanitizeSettings(null);
  /** @type {TechWatchTypes.StoredItem[]} */ let items = [];
  /** @type {TechWatchTypes.State} */ let state = { startedAt: null, lastDigestAt: null, lastFetchAt: null, sources: {} };
  /** @type {TechWatchTypes.Digest[]} */ let digests = [];
  /** @type {string[]} */ let grantedHosts = [];
  /** @type {string[]} */ let declaredHosts = [];
  let githubTokenSet = false;
  /** @type {Promise<number> | null} */ let refreshing = null;
  /** @type {Promise<void> | null} */ let digesting = null;
  /** @type {string | null} */ let banner = null;
  let tab = "digest";

  /** @param {string} id */
  function $(id) {
    const element = document.getElementById(id);
    if (!element) throw new Error("missing #" + id);
    return element;
  }

  /** @param {unknown} error */
  function message(error) {
    const any = /** @type {any} */ (error);
    return String(any && any.message !== undefined ? any.message : error);
  }

  // MARK: - Storage

  /** @param {unknown} raw @returns {TechWatchTypes.State} */
  function sanitizeState(raw) {
    const source = /** @type {any} */ (raw && typeof raw === "object" ? raw : {});
    const time = (/** @type {unknown} */ value) => (typeof value === "number" && Number.isFinite(value) ? value : null);
    return {
      startedAt: time(source.startedAt),
      lastDigestAt: time(source.lastDigestAt),
      lastFetchAt: time(source.lastFetchAt),
      sources: source.sources && typeof source.sources === "object" ? source.sources : {},
    };
  }

  /** Items and digests trimmed to the budget, then everything stored. */
  async function persist() {
    const fitted = fitBudget(items, digests, BUDGET);
    items = fitted.items;
    digests = fitted.digests;
    await Promise.all([
      loom.storage.set(KEY_ITEMS, items),
      loom.storage.set(KEY_DIGESTS, digests),
      loom.storage.set(KEY_STATE, state),
    ]);
  }

  async function saveSettings() {
    await loom.storage.set(KEY_SETTINGS, settings);
  }

  // MARK: - Alarms and the top bar

  /** Loom's alarms are not kept across launches: re-created from state here. */
  async function arm() {
    const now = Date.now();
    await loom.alarms.create(ALARM_DIGEST, { when: nextSlotAfter(now, settings.digestHour, settings.digestMinute) });
    if (isDigestDue(now, settings, state.lastDigestAt ?? state.startedAt)) {
      // Loom was closed, or the Mac asleep, at digest time: a minute for the network to come up.
      await loom.alarms.create(ALARM_CATCH_UP, { delayMs: 60_000 });
    }
  }

  /** The latest digest's items the reader has not opened yet. */
  function unreadIds() {
    const latest = digests[0];
    if (!latest) return [];
    return latest.items.map((item) => item.id)
      .filter((id) => items.some((stored) => stored.id === id && stored.read !== true));
  }

  async function syncStatus() {
    await loom.ui.setStatus(TechWatch.digest.statusFor(unreadIds().length)).catch((error) => {
      console.warn("[tech-watch] status", error);
    });
  }

  // MARK: - Reading the sources

  /** @template T @param {T[]} list @param {number} size @param {(entry: T) => Promise<void>} work */
  async function pool(list, size, work) {
    let next = 0;
    const runners = Array.from({ length: Math.min(size, list.length) }, async () => {
      while (next < list.length) await work(list[next++]);
    });
    await Promise.all(runners);
  }

  /** @param {TechWatchTypes.SourceRequest} request @param {number} now @returns {Promise<TechWatchTypes.Item[]>} */
  async function fetchSource(request, now) {
    let response;
    try {
      response = await loom.http.fetch(request.url, { headers: request.headers });
    } catch (error) {
      const code = /** @type {any} */ (error)?.code;
      if (code === "forbidden" && request.kind === "rss") throw new Error("accès retiré — redemandez-le dans les réglages");
      throw error;
    }
    if (response.status >= 300 && response.status < 400) {
      throw new Error("le flux redirige vers " + (response.headers.location || "un autre site") + " — ajoutez cette adresse");
    }
    if (!response.ok) throw new Error("HTTP " + response.status);
    switch (request.kind) {
      case "hn": return TechWatch.sources.normalizeHN(response.json());
      case "github": return TechWatch.sources.normalizeGitHubReleases(response.json(), request.repo || request.label);
      case "reddit": return TechWatch.sources.normalizeReddit(response.json(), request.subreddit || request.label);
      case "lobsters": return TechWatch.sources.normalizeLobsters(response.json());
      case "rss": return TechWatch.feeds.parseFeed(response.text(), request.url, new DOMParser(), now).items;
    }
    return [];
  }

  /** @type {Record<string, string>} */ let sourceLabels = {};

  /** Reads every source once; resolves to how many items are new. One round at a time. */
  function refresh() {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      const now = Date.now();
      const token = await loom.secrets.get(SECRET_GITHUB).catch(() => null);
      const requests = TechWatch.sources.requestsFor(settings, now, token);
      sourceLabels = Object.fromEntries(requests.map((request) => [request.key, request.label]));
      /** @type {TechWatchTypes.Item[]} */ const fresh = [];
      /** @type {Record<string, TechWatchTypes.SourceStatus>} */ const statuses = {};
      await pool(requests, CONCURRENCY, async (request) => {
        try {
          const found = await fetchSource(request, now);
          fresh.push(...found);
          statuses[request.key] = { lastOkAt: now, count: found.length };
        } catch (error) {
          statuses[request.key] = { ...(state.sources[request.key] || {}), error: message(error) };
          delete statuses[request.key].count;
        }
      });
      const merged = mergeItems(items, fresh, now);
      items = prune(merged.items, now);
      state.sources = statuses;
      state.lastFetchAt = now;
      await persist();
      return merged.added;
    })().finally(() => {
      refreshing = null;
      render();
    });
    render();
    return refreshing;
  }

  // MARK: - The digest

  /** @param {unknown} error */
  function describeClaudeError(error) {
    const code = /** @type {any} */ (error)?.code;
    if (code === "forbidden") return "la permission Claude n'est pas accordée à l'extension.";
    if (code === "timeout") return "Claude n'a pas répondu à temps.";
    return message(error);
  }

  /** @param {TechWatchTypes.StoredItem} item @returns {TechWatchTypes.DigestItem} */
  function digestItem(item) {
    /** @type {TechWatchTypes.DigestItem} */ const kept = {
      id: item.id, title: item.title, url: item.url, source: item.source, sourceLabel: item.sourceLabel,
    };
    if (item.discussionUrl) kept.discussionUrl = item.discussionUrl;
    return kept;
  }

  /**
   * Reads the sources, asks Claude, stores the digest. "scheduled" runs only
   * when a digest time passed with none since — the catch-up and the daily
   * alarm never make two.
   * @param {"scheduled" | "manual"} trigger
   */
  function runDigest(trigger) {
    if (digesting) return digesting;
    digesting = (async () => {
      if (trigger === "scheduled" && !isDigestDue(Date.now(), settings, state.lastDigestAt ?? state.startedAt)) return;
      await refresh().catch((error) => console.warn("[tech-watch] refresh", error));
      const now = Date.now();
      const selected = selectForDigest(items, settings, digestWindow(now, state.lastDigestAt), now);
      /** @type {TechWatchTypes.Digest} */ const digest = {
        id: "d" + now, createdAt: now, items: selected.map(digestItem), headline: "", sections: [], mustRead: [],
      };
      if (!selected.length) {
        digest.headline = settings.language === "fr" ? "Rien de neuf depuis le dernier digest." : "Nothing new since the last digest.";
      } else {
        const { system, prompt, itemIds } = TechWatch.digest.buildDigestPrompt(selected, {
          language: settings.language, keywords: settings.keywords, now,
        });
        try {
          const completion = await loom.claude.complete({ system, prompt, model: settings.model, timeoutMs: 180_000 });
          Object.assign(digest, TechWatch.digest.parseDigestResponse(completion.text, itemIds));
          if (completion.model) digest.model = completion.model;
          if (typeof completion.costUsd === "number") digest.costUsd = completion.costUsd;
        } catch (error) {
          digest.error = describeClaudeError(error);
        }
      }
      digests = [digest, ...digests].slice(0, MAX_DIGESTS);
      state.lastDigestAt = now;
      await persist();
      await arm().catch((error) => console.warn("[tech-watch] alarms", error));
      await syncStatus();
      tab = "digest";
    })().catch((error) => {
      banner = "Le digest a échoué : " + message(error);
    }).finally(() => {
      digesting = null;
      render();
    });
    render();
    return digesting;
  }

  // MARK: - What the reader does

  /** @param {string[]} ids */
  async function markRead(ids) {
    let changed = false;
    for (const item of items) {
      if (ids.includes(item.id) && item.read !== true) {
        item.read = true;
        changed = true;
      }
    }
    if (!changed) return;
    await loom.storage.set(KEY_ITEMS, items);
    await syncStatus();
    render();
  }

  /** @param {TechWatchTypes.Item} item */
  async function sendToSession(item) {
    try {
      const result = await loom.sessions.launch({
        prompt: TechWatch.digest.buildSessionPrompt(item, settings.language),
        title: TechWatch.text.clip((settings.language === "fr" ? "Veille : " : "Watch: ") + item.title, 180),
        badges: ["veille"],
      });
      if (result.launched) await markRead([item.id]);
    } catch (error) {
      banner = "La session n'a pas démarré : " + message(error);
      render();
    }
  }

  /** @param {(draft: TechWatchTypes.Settings) => void} edit */
  async function updateSettings(edit) {
    const draft = /** @type {TechWatchTypes.Settings} */ (JSON.parse(JSON.stringify(settings)));
    edit(draft);
    const before = settings;
    settings = sanitizeSettings(draft);
    await saveSettings();
    if (before.digestHour !== settings.digestHour || before.digestMinute !== settings.digestMinute) {
      await arm().catch((error) => console.warn("[tech-watch] alarms", error));
    }
    render({ force: true });
  }

  /** @param {TechWatchTypes.ListName} list @param {"add" | "remove"} op @param {string} value */
  function editList(list, op, value) {
    const { parseRepo, parseSubreddit, parseLobstersTag } = TechWatch.sources;
    /** @type {Record<TechWatchTypes.ListName, { read: (s: TechWatchTypes.Settings) => string[], check: (text: string) => string | null, error: string }>} */
    const lists = {
      keywords: { read: (s) => s.keywords, check: (text) => text.trim().toLowerCase() || null, error: "Un mot, s'il vous plaît." },
      muted: { read: (s) => s.muted, check: (text) => text.trim().toLowerCase() || null, error: "Un mot, s'il vous plaît." },
      repos: { read: (s) => s.github.repos, check: parseRepo, error: "Un dépôt s'écrit owner/repo." },
      subreddits: { read: (s) => s.reddit.subreddits, check: parseSubreddit, error: "Un nom de subreddit : lettres, chiffres, _." },
      lobstersTags: { read: (s) => s.lobsters.tags, check: parseLobstersTag, error: "Un tag Lobsters : lettres minuscules, chiffres, - ou _." },
    };
    const entry = lists[list];
    if (op === "remove") {
      void updateSettings((draft) => {
        const values = entry.read(draft);
        values.splice(values.indexOf(value), values.includes(value) ? 1 : 0);
      });
      return null;
    }
    const checked = entry.check(value);
    if (!checked) return entry.error;
    if (entry.read(settings).includes(checked)) return "Déjà dans la liste.";
    void updateSettings((draft) => { entry.read(draft).push(checked); });
    return null;
  }

  /** Whether `host` may be fetched: declared in the manifest, or granted at use. @param {string} host */
  function reachable(host) {
    return declaredHosts.includes(host) || grantedHosts.includes(host);
  }

  /** Asks Loom for `host` when it is not reachable yet; true once it is. @param {string} host */
  async function ensureHost(host) {
    if (reachable(host)) return true;
    const grant = await loom.network.request([host]);
    for (const granted of grant.granted) if (!grantedHosts.includes(granted)) grantedHosts.push(granted);
    return grant.granted.includes(host);
  }

  /**
   * Adds a feed: asks for its host, reads it once, keeps its title. A web
   * page that announces a feed is followed to it, once.
   * @param {string} text @returns {Promise<string | null>} an error, or null
   */
  async function addFeed(text, depth = 0) {
    const parsed = TechWatch.sources.parseFeedUrl(text);
    if ("error" in parsed) return parsed.error;
    if (settings.feeds.some((feed) => feed.url === parsed.url)) return "Ce flux est déjà suivi.";
    try {
      if (!(await ensureHost(parsed.host))) return "Loom n'a pas autorisé " + parsed.host + " : le flux n'est pas ajouté.";
      const response = await loom.http.fetch(parsed.url);
      if (response.status >= 300 && response.status < 400 && response.headers.location && depth === 0) {
        const target = TechWatch.text.safeUrl(response.headers.location, parsed.url);
        if (target) return addFeed(target, depth + 1);
      }
      if (!response.ok) return "Le site a répondu HTTP " + response.status + ".";
      const body = response.text();
      const parser = new DOMParser();
      if (TechWatch.feeds.looksLikeHTML(body)) {
        const found = TechWatch.feeds.discoverFeeds(body, parsed.url, parser);
        if (found.length && depth === 0) return addFeed(found[0], depth + 1);
        return "Cette page n'annonce pas de flux RSS ou Atom.";
      }
      const feed = TechWatch.feeds.parseFeed(body, parsed.url, parser, Date.now());
      await updateSettings((draft) => {
        draft.feeds.push({ url: parsed.url, host: parsed.host, title: feed.title });
      });
      void refresh();
      return null;
    } catch (error) {
      const code = /** @type {any} */ (error)?.code;
      if (code === "forbidden") return "Gardez l'onglet de l'extension affiché pendant l'ajout : Loom ne demande l'accès qu'à l'écran.";
      return message(error);
    }
  }

  /** Removes a feed, and gives its host back when no other feed uses it. @param {string} url */
  async function removeFeed(url) {
    const feed = settings.feeds.find((candidate) => candidate.url === url);
    await updateSettings((draft) => { draft.feeds = draft.feeds.filter((candidate) => candidate.url !== url); });
    if (feed && !declaredHosts.includes(feed.host) && !settings.feeds.some((other) => other.host === feed.host)) {
      await loom.network.revoke([feed.host]).catch((error) => console.warn("[tech-watch] revoke", error));
      grantedHosts = grantedHosts.filter((host) => host !== feed.host);
      render({ force: true });
    }
  }

  /** @param {string} host */
  async function regrant(host) {
    try {
      if (await ensureHost(host)) void refresh();
    } catch (error) {
      banner = message(error);
    }
    render({ force: true });
  }

  /** @param {string | null} token */
  async function setGithubToken(token) {
    if (token) await loom.secrets.set(SECRET_GITHUB, token);
    else await loom.secrets.delete(SECRET_GITHUB);
    githubTokenSet = token !== null;
    render({ force: true });
  }

  // MARK: - Rendering

  /** @returns {TechWatchTypes.ViewContext} */
  function context() {
    return {
      now: Date.now(), settings, items, digests, state, grantedHosts, declaredHosts,
      busy: { refresh: refreshing !== null, digest: digesting !== null },
      githubTokenSet, unreadIds: unreadIds(), sourceLabels, showSummaries: tab === "items",
      actions: {
        markRead: (id) => void markRead([id]),
        markAllRead: (ids) => void markRead(ids),
        sendToSession: (item) => void sendToSession(item),
        updateSettings: (edit) => void updateSettings(edit),
        editList, addFeed, removeFeed: (url) => void removeFeed(url), regrant, setGithubToken,
      },
    };
  }

  /**
   * Redraws the visible view. The settings are not redrawn under the
   * reader's typing unless asked: a background refresh must not eat input.
   * @param {{ force?: boolean }} [options]
   */
  function render(options = {}) {
    if (!document.body) return;
    const now = Date.now();
    const busy = digesting ? "Claude prépare le digest…" : refreshing ? "Lecture des sources…" : "";
    const next = nextSlotAfter(now, settings.digestHour, settings.digestMinute);
    const parts = [];
    if (busy) parts.push(busy);
    if (state.lastFetchAt) parts.push("Sources lues " + TechWatch.view.ago(state.lastFetchAt, now));
    parts.push("prochain digest " + TechWatch.view.when(next));
    $("meta").textContent = parts.join(" · ");
    const bannerElement = $("banner");
    bannerElement.textContent = banner || "";
    bannerElement.hidden = !banner;
    /** @type {HTMLButtonElement} */ ($("refresh")).disabled = refreshing !== null;
    /** @type {HTMLButtonElement} */ ($("summarize")).disabled = digesting !== null;
    for (const button of Array.from(document.querySelectorAll(".tab"))) {
      button.setAttribute("aria-pressed", String(/** @type {HTMLElement} */ (button).dataset.tab === tab));
    }
    for (const name of ["digest", "items", "settings"]) $("view-" + name).hidden = name !== tab;
    const ctx = context();
    if (tab === "digest") TechWatch.view.renderDigest($("view-digest"), ctx);
    if (tab === "items") TechWatch.view.renderItems($("view-items"), ctx);
    if (tab === "settings") {
      const view = $("view-settings");
      const typing = view.contains(document.activeElement) && document.activeElement?.tagName === "INPUT";
      if (options.force || !typing || !view.childElementCount) TechWatch.view.renderSettings(view, ctx);
    }
  }

  // MARK: - Wiring

  loom.on("alarm", ({ name }) => {
    if (name === ALARM_DIGEST || name === ALARM_CATCH_UP) void runDigest("scheduled");
  });
  loom.on("command", ({ id }) => {
    if (id === "refresh") void refresh();
    if (id === "digest") void runDigest("manual");
  });
  loom.on("network.changed", ({ granted }) => {
    grantedHosts = [...granted];
    render({ force: true });
  });

  async function boot() {
    for (const button of Array.from(document.querySelectorAll(".tab"))) {
      button.addEventListener("click", () => {
        tab = /** @type {HTMLElement} */ (button).dataset.tab || "digest";
        banner = null;
        render({ force: true });
      });
    }
    $("refresh").addEventListener("click", () => void refresh());
    $("summarize").addEventListener("click", () => void runDigest("manual"));

    const [rawSettings, rawItems, rawState, rawDigests] = await Promise.all(
      [KEY_SETTINGS, KEY_ITEMS, KEY_STATE, KEY_DIGESTS].map((key) => loom.storage.get(key)));
    settings = sanitizeSettings(rawSettings);
    items = Array.isArray(rawItems) ? rawItems.filter((item) => item && typeof item.id === "string" && typeof item.url === "string") : [];
    state = sanitizeState(rawState);
    digests = Array.isArray(rawDigests) ? rawDigests.filter((digest) => digest && Array.isArray(digest.items)) : [];
    if (state.startedAt === null) {
      state.startedAt = Date.now();
      await loom.storage.set(KEY_STATE, state);
    }
    const hosts = await loom.network.granted().catch(() => ({ declared: [], granted: [] }));
    declaredHosts = hosts.declared;
    grantedHosts = hosts.granted;
    githubTokenSet = (await loom.secrets.get(SECRET_GITHUB).catch(() => null)) !== null;
    render({ force: true });
    await arm().catch((error) => console.warn("[tech-watch] alarms", error));
    await syncStatus();
  }

  boot().catch((error) => {
    banner = "La veille n'a pas démarré : " + message(error);
    render();
  });
})();
