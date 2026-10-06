// @ts-check
// What the watch keeps, and in which order: merging a round into the stored
// items (the same article on HN, Lobsters and Reddit is one item), ranking,
// muting, and staying within loom.storage's megabyte.

(() => {
  "use strict";

  const root = /** @type {any} */ (globalThis);
  /** @type {TechWatchTypes.Namespace} */
  const TechWatch = (root.TechWatch = root.TechWatch || /** @type {any} */ ({}));

  const DAY = 24 * 3600 * 1000;
  const TRACKING = /^(utm_[a-z]+|ref|ref_src|fbclid|gclid|mc_cid|mc_eid)$/i;

  /** A URL as two sources would agree on it: no tracking, no fragment, no www. @param {string} value */
  function canonicalUrl(value) {
    try {
      const url = new URL(value);
      const host = url.hostname.toLowerCase().replace(/^www\./, "");
      const kept = [...url.searchParams.entries()].filter(([name]) => !TRACKING.test(name));
      const search = kept.length ? "?" + new URLSearchParams(kept).toString() : "";
      const path = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, "") : "";
      return host + path + search;
    } catch {
      return value;
    }
  }

  /**
   * A round's items into the stored ones: known ids are refreshed (score,
   * title), an article already known from another source gains an `alsoOn`,
   * the rest is new.
   * @param {TechWatchTypes.StoredItem[]} stored @param {TechWatchTypes.Item[]} fresh @param {number} now
   * @returns {{ items: TechWatchTypes.StoredItem[], added: number }}
   */
  function mergeItems(stored, fresh, now) {
    const items = stored.map((item) => ({ ...item }));
    const byId = new Map(items.map((item) => [item.id, item]));
    const byUrl = new Map(items.map((item) => [canonicalUrl(item.url), item]));
    let added = 0;
    for (const item of fresh) {
      const known = byId.get(item.id);
      if (known) {
        known.title = item.title;
        if (item.score !== undefined) known.score = item.score;
        continue;
      }
      const key = canonicalUrl(item.url);
      const twin = byUrl.get(key);
      if (twin && twin.source !== item.source) {
        const also = twin.alsoOn || (twin.alsoOn = []);
        if (!also.some((other) => other.id === item.id)) {
          also.push({ id: item.id, source: item.source, sourceLabel: item.sourceLabel,
                      discussionUrl: item.discussionUrl, score: item.score });
        }
        continue;
      }
      if (twin) continue;
      const kept = { ...item, firstSeenAt: now };
      items.push(kept);
      byId.set(kept.id, kept);
      byUrl.set(key, kept);
      added += 1;
    }
    return { items, added };
  }

  /** The keywords an item mentions. @param {TechWatchTypes.Item} item @param {string[]} keywords */
  function matchKeywords(item, keywords) {
    const haystack = (item.title + " " + item.summary + " " + (item.tags || []).join(" ")).toLowerCase();
    return keywords.filter((keyword) => haystack.includes(keyword.toLowerCase()));
  }

  /** @param {TechWatchTypes.Item} item @param {string[]} muted */
  function isMuted(item, muted) {
    return matchKeywords(item, muted).length > 0;
  }

  /** Scores on one scale: an HN hundred, a Reddit five hundred, a Lobsters twenty. @param {TechWatchTypes.Item} item */
  function weight(item) {
    switch (item.source) {
      case "hn": return (item.score ?? 0) / 100;
      case "reddit": return (item.score ?? 0) / 500;
      case "lobsters": return (item.score ?? 0) / 20;
      case "github": return 2;
      default: return 1.2;
    }
  }

  /**
   * Best first: popularity (log), freshness, the reader's keywords, being on
   * several sites at once.
   * @param {TechWatchTypes.StoredItem[]} items @param {TechWatchTypes.Settings} settings @param {number} now
   */
  function rank(items, settings, now) {
    const score = (/** @type {TechWatchTypes.StoredItem} */ item) => {
      const when = item.publishedAt || item.firstSeenAt;
      const ageHours = Math.max(0, now - when) / 3600_000;
      return Math.log2(1 + weight(item)) + Math.exp(-ageHours / 36)
        + 2 * matchKeywords(item, settings.keywords).length + 0.5 * (item.alsoOn?.length ?? 0);
    };
    return items.map((item) => ({ item, score: score(item) }))
      .sort((a, b) => b.score - a.score || b.item.firstSeenAt - a.item.firstSeenAt)
      .map((entry) => entry.item);
  }

  /**
   * What a digest is about: items first seen since `since`, not muted, the
   * best `maxItems`.
   * @param {TechWatchTypes.StoredItem[]} items @param {TechWatchTypes.Settings} settings @param {number} since @param {number} now
   */
  function selectForDigest(items, settings, since, now) {
    const fresh = items.filter((item) => item.firstSeenAt >= since && !isMuted(item, settings.muted));
    return rank(fresh, settings, now).slice(0, settings.maxItems);
  }

  /**
   * Old items out: past `maxAgeDays`, and past `maxPerSource` per source or
   * `maxItems` in all — the newest stay.
   * @param {TechWatchTypes.StoredItem[]} items @param {number} now
   * @param {{ maxPerSource?: number, maxItems?: number, maxAgeDays?: number }} [limits]
   */
  function prune(items, now, limits = {}) {
    const { maxPerSource = 60, maxItems = 400, maxAgeDays = 14 } = limits;
    const newest = items.filter((item) => now - item.firstSeenAt <= maxAgeDays * DAY)
      .sort((a, b) => b.firstSeenAt - a.firstSeenAt || b.publishedAt - a.publishedAt);
    /** @type {Map<string, number>} */ const perSource = new Map();
    /** @type {TechWatchTypes.StoredItem[]} */ const kept = [];
    for (const item of newest) {
      const key = item.source === "rss" || item.source === "github" || item.source === "reddit"
        ? item.source + ":" + item.sourceLabel : item.source;
      const count = perSource.get(key) ?? 0;
      if (count >= maxPerSource) continue;
      perSource.set(key, count + 1);
      kept.push(item);
      if (kept.length >= maxItems) break;
    }
    return kept;
  }

  /** Bytes of a value as storage holds it. @param {unknown} value */
  function byteSize(value) {
    return new TextEncoder().encode(JSON.stringify(value ?? null)).length;
  }

  /**
   * Items and digests cut until they fit `budget` bytes: older digests first
   * (the latest stays), then the oldest items.
   * @param {TechWatchTypes.StoredItem[]} items @param {TechWatchTypes.Digest[]} digests @param {number} budget
   */
  function fitBudget(items, digests, budget) {
    let keptItems = [...items].sort((a, b) => b.firstSeenAt - a.firstSeenAt);
    let keptDigests = [...digests];
    while (byteSize(keptItems) + byteSize(keptDigests) > budget) {
      if (keptDigests.length > 1) {
        keptDigests = keptDigests.slice(0, -1);
      } else if (keptItems.length > 0) {
        keptItems = keptItems.slice(0, Math.floor(keptItems.length * 0.9));
      } else {
        break;
      }
    }
    return { items: keptItems, digests: keptDigests };
  }

  TechWatch.curate = Object.freeze({
    canonicalUrl, mergeItems, matchKeywords, isMuted, rank, selectForDigest, prune, byteSize, fitBudget,
  });
})();
