// @ts-check
// The tech watch's settings: defaults, and a sanitizer for what storage holds
// (a hand-edited or older value must never break the page).

(() => {
  "use strict";

  const root = /** @type {any} */ (globalThis);
  /** @type {TechWatchTypes.Namespace} */
  const TechWatch = (root.TechWatch = root.TechWatch || /** @type {any} */ ({}));

  /** @type {TechWatchTypes.Settings} */
  const DEFAULT_SETTINGS = Object.freeze({
    digestHour: 8,
    digestMinute: 0,
    language: "fr",
    model: "sonnet",
    maxItems: 40,
    keywords: [],
    muted: [],
    hn: { enabled: true, minPoints: 100, query: "" },
    github: { repos: ["anthropics/claude-code"] },
    reddit: { subreddits: [] },
    lobsters: { enabled: true, tags: [] },
    feeds: [],
  });

  const MODELS = ["haiku", "sonnet", "opus"];
  const LANGUAGES = ["fr", "en"];

  /**
   * @param {unknown} value @param {number} min @param {number} max @param {number} fallback
   */
  function clampInt(value, min, max, fallback) {
    const number = Math.round(Number(value));
    return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
  }

  /**
   * Strings that pass `check`, each once, at most `max`.
   * @param {unknown} value @param {(text: string) => string | null} check @param {number} max
   * @returns {string[]}
   */
  function stringList(value, check, max) {
    if (!Array.isArray(value)) return [];
    /** @type {string[]} */ const out = [];
    for (const entry of value) {
      const checked = typeof entry === "string" ? check(entry) : null;
      if (checked && !out.includes(checked)) out.push(checked);
      if (out.length >= max) break;
    }
    return out;
  }

  /** @param {string} text */
  const word = (text) => {
    const trimmed = text.trim().toLowerCase();
    return trimmed && trimmed.length <= 40 ? trimmed : null;
  };

  /** @param {unknown} raw @returns {TechWatchTypes.Settings} */
  function sanitizeSettings(raw) {
    const source = /** @type {any} */ (raw && typeof raw === "object" ? raw : {});
    const sources = TechWatch.sources;
    const hn = source.hn && typeof source.hn === "object" ? source.hn : {};
    const lobsters = source.lobsters && typeof source.lobsters === "object" ? source.lobsters : {};
    /** @type {TechWatchTypes.Feed[]} */ const feeds = [];
    for (const feed of Array.isArray(source.feeds) ? source.feeds : []) {
      const parsed = feed && typeof feed.url === "string" ? sources.parseFeedUrl(feed.url) : null;
      if (!parsed || "error" in parsed || feeds.some((known) => known.url === parsed.url)) continue;
      feeds.push({ url: parsed.url, host: parsed.host, title: TechWatch.text.clip(feed.title || parsed.host, 120) });
      if (feeds.length >= 50) break;
    }
    return {
      digestHour: clampInt(source.digestHour, 0, 23, DEFAULT_SETTINGS.digestHour),
      digestMinute: clampInt(source.digestMinute, 0, 59, DEFAULT_SETTINGS.digestMinute),
      language: LANGUAGES.includes(source.language) ? source.language : DEFAULT_SETTINGS.language,
      model: MODELS.includes(source.model) ? source.model : DEFAULT_SETTINGS.model,
      maxItems: clampInt(source.maxItems, 5, 60, DEFAULT_SETTINGS.maxItems),
      keywords: stringList(source.keywords, word, 30),
      muted: stringList(source.muted, word, 30),
      hn: {
        enabled: hn.enabled !== false,
        minPoints: clampInt(hn.minPoints, 0, 2000, DEFAULT_SETTINGS.hn.minPoints),
        query: TechWatch.text.clip(typeof hn.query === "string" ? hn.query : "", 80),
      },
      github: {
        repos: "github" in source
          ? stringList(source.github?.repos, (text) => sources.parseRepo(text), 30)
          : [...DEFAULT_SETTINGS.github.repos],
      },
      reddit: { subreddits: stringList(source.reddit?.subreddits, (text) => sources.parseSubreddit(text), 15) },
      lobsters: {
        enabled: lobsters.enabled !== false,
        tags: stringList(lobsters.tags, (text) => sources.parseLobstersTag(text), 10),
      },
      feeds,
    };
  }

  TechWatch.settings = Object.freeze({ DEFAULT_SETTINGS, MODELS, LANGUAGES, sanitizeSettings });
})();
