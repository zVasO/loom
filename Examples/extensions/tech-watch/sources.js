// @ts-check
// The sources the watch reads, as plain requests and normalizers: what to ask
// (URL, headers), and how each answer becomes the watch's items. No network
// here — app.js sends the requests through loom.http.fetch.

(() => {
  "use strict";

  const root = /** @type {any} */ (globalThis);
  /** @type {TechWatchTypes.Namespace} */
  const TechWatch = (root.TechWatch = root.TechWatch || /** @type {any} */ ({}));

  const SUMMARY_MAX = 400;

  /** "owner/repo", or null. @param {string} text */
  function parseRepo(text) {
    const match = /^\s*(?:https:\/\/github\.com\/)?([A-Za-z0-9-]{1,39})\/([A-Za-z0-9._-]{1,100}?)(?:\.git)?\/?\s*$/.exec(text);
    return match && match[2] !== "." && match[2] !== ".." ? match[1] + "/" + match[2] : null;
  }

  /** A subreddit name without "r/", or null. @param {string} text */
  function parseSubreddit(text) {
    const name = text.trim().replace(/^\/?r\//i, "");
    return /^[A-Za-z0-9_]{2,21}$/.test(name) ? name : null;
  }

  /** A Lobsters tag, or null. @param {string} text */
  function parseLobstersTag(text) {
    const tag = text.trim().toLowerCase();
    return /^[a-z0-9_-]{1,25}$/.test(tag) ? tag : null;
  }

  /**
   * A feed address the watch can read: HTTPS, a host name, no credentials.
   * @param {string} text
   * @returns {{ url: string, host: string } | { error: string }}
   */
  function parseFeedUrl(text) {
    let url;
    try {
      url = new URL(text.trim());
    } catch {
      return { error: "Ce n'est pas une adresse web." };
    }
    if (url.protocol === "http:") return { error: "Loom ne lit que des flux en HTTPS — essayez https://" + url.host + url.pathname };
    if (url.protocol !== "https:") return { error: "Une adresse de flux commence par https://." };
    if (url.username || url.password) return { error: "Pas d'identifiants dans l'adresse." };
    if (url.port && url.port !== "443") return { error: "Pas de port dans l'adresse." };
    const host = url.hostname.toLowerCase();
    if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(host) || /^[0-9.]+$/.test(host)) {
      return { error: "L'adresse doit nommer un site (pas une adresse IP)." };
    }
    url.hash = "";
    return { url: url.href, host };
  }

  /**
   * Everything to fetch for one round.
   * @param {TechWatchTypes.Settings} settings @param {number} now @param {string | null} githubToken
   * @returns {TechWatchTypes.SourceRequest[]}
   */
  function requestsFor(settings, now, githubToken) {
    /** @type {TechWatchTypes.SourceRequest[]} */ const requests = [];
    if (settings.hn.enabled) {
      const since = Math.floor(now / 1000) - 48 * 3600;
      const filters = encodeURIComponent("created_at_i>" + since + ",points>=" + settings.hn.minPoints);
      const query = settings.hn.query ? "&query=" + encodeURIComponent(settings.hn.query) : "";
      requests.push({
        key: "hn", kind: "hn", label: "Hacker News",
        url: "https://hn.algolia.com/api/v1/search_by_date?tags=story&hitsPerPage=50&numericFilters=" + filters + query,
        headers: {},
      });
    }
    for (const repo of settings.github.repos) {
      /** @type {Record<string, string>} */
      const headers = { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };
      if (githubToken) headers.Authorization = "Bearer " + githubToken;
      requests.push({
        key: "github:" + repo, kind: "github", label: repo, repo,
        url: "https://api.github.com/repos/" + repo + "/releases?per_page=5", headers,
      });
    }
    for (const subreddit of settings.reddit.subreddits) {
      requests.push({
        key: "reddit:" + subreddit, kind: "reddit", label: "r/" + subreddit, subreddit,
        url: "https://www.reddit.com/r/" + subreddit + "/top.json?t=day&limit=25",
        headers: { "User-Agent": "loom-tech-watch/1.0" },
      });
    }
    if (settings.lobsters.enabled) {
      const tags = settings.lobsters.tags;
      requests.push({
        key: "lobsters", kind: "lobsters", label: "Lobsters",
        url: tags.length ? "https://lobste.rs/t/" + tags.join(",") + ".json" : "https://lobste.rs/hottest.json",
        headers: {},
      });
    }
    for (const feed of settings.feeds) {
      requests.push({ key: "rss:" + feed.url, kind: "rss", label: feed.title || feed.host, url: feed.url, headers: {} });
    }
    return requests;
  }

  /**
   * An item, checked: a title and an http(s) link, or nothing.
   * @param {Partial<TechWatchTypes.Item> & { url?: unknown, title?: unknown }} raw
   * @returns {TechWatchTypes.Item | null}
   */
  function item(raw) {
    const { clip, safeUrl } = TechWatch.text;
    const url = safeUrl(raw.url);
    const title = clip(raw.title, 200);
    if (!url || !title || !raw.id || !raw.source) return null;
    /** @type {TechWatchTypes.Item} */ const out = {
      id: raw.id, source: raw.source, sourceLabel: clip(raw.sourceLabel, 60), title, url,
      publishedAt: Number.isFinite(raw.publishedAt) ? /** @type {number} */ (raw.publishedAt) : 0,
      summary: clip(raw.summary, SUMMARY_MAX),
    };
    const discussion = safeUrl(raw.discussionUrl);
    if (discussion && discussion !== url) out.discussionUrl = discussion;
    if (raw.author) out.author = clip(raw.author, 60);
    if (Number.isFinite(raw.score)) out.score = /** @type {number} */ (raw.score);
    if (raw.tags && raw.tags.length) out.tags = raw.tags.slice(0, 6).map((tag) => clip(tag, 30));
    return out;
  }

  /** @param {(TechWatchTypes.Item | null)[]} items */
  const present = (items) => /** @type {TechWatchTypes.Item[]} */ (items.filter(Boolean));

  /** Algolia's HN search. @param {any} json */
  function normalizeHN(json) {
    const hits = Array.isArray(json?.hits) ? json.hits : [];
    return present(hits.map((/** @type {any} */ hit) => {
      const discussionUrl = "https://news.ycombinator.com/item?id=" + encodeURIComponent(String(hit.objectID));
      return item({
        id: "hn:" + hit.objectID, source: "hn", sourceLabel: "Hacker News",
        title: hit.title, url: hit.url || discussionUrl, discussionUrl,
        author: hit.author, publishedAt: Number(hit.created_at_i) * 1000, score: Number(hit.points),
        summary: hit.story_text ? TechWatch.text.markdownToText(hit.story_text) : "",
      });
    }));
  }

  /** GitHub's releases of one repository. @param {any} json @param {string} repo */
  function normalizeGitHubReleases(json, repo) {
    const releases = Array.isArray(json) ? json : [];
    return present(releases.filter((release) => release && !release.draft).map((release) => {
      const tag = String(release.tag_name || "");
      const name = String(release.name || "").trim();
      return item({
        id: "gh:" + repo + ":" + (release.id ?? tag), source: "github", sourceLabel: repo,
        title: repo + " " + tag + (name && name !== tag ? " — " + name : ""),
        url: release.html_url, author: release.author?.login,
        publishedAt: Date.parse(release.published_at || release.created_at),
        summary: TechWatch.text.markdownToText(release.body),
        tags: release.prerelease ? ["pre-release"] : undefined,
      });
    }));
  }

  /** A subreddit's top of the day. @param {any} json @param {string} subreddit */
  function normalizeReddit(json, subreddit) {
    const children = Array.isArray(json?.data?.children) ? json.data.children : [];
    return present(children.map((/** @type {any} */ child) => child?.data)
      .filter((/** @type {any} */ post) => post && !post.stickied && !post.over_18)
      .map((/** @type {any} */ post) => {
        const discussionUrl = "https://www.reddit.com" + String(post.permalink || "");
        return item({
          id: "reddit:" + post.id, source: "reddit", sourceLabel: "r/" + subreddit,
          title: post.title, url: post.url_overridden_by_dest || discussionUrl, discussionUrl,
          author: post.author, publishedAt: Number(post.created_utc) * 1000, score: Number(post.score),
          summary: post.selftext ? TechWatch.text.markdownToText(post.selftext) : "",
        });
      }));
  }

  /** Lobsters' hottest, or a tag page. @param {any} json */
  function normalizeLobsters(json) {
    const stories = Array.isArray(json) ? json : [];
    return present(stories.map((story) => item({
      id: "lobsters:" + story.short_id, source: "lobsters", sourceLabel: "Lobsters",
      title: story.title, url: story.url || story.comments_url, discussionUrl: story.comments_url,
      author: typeof story.submitter_user === "string" ? story.submitter_user : story.submitter_user?.username,
      publishedAt: Date.parse(story.created_at), score: Number(story.score),
      summary: story.description_plain || "", tags: Array.isArray(story.tags) ? story.tags : undefined,
    })));
  }

  TechWatch.sources = Object.freeze({
    parseRepo, parseSubreddit, parseLobstersTag, parseFeedUrl, requestsFor, item,
    normalizeHN, normalizeGitHubReleases, normalizeReddit, normalizeLobsters,
  });
})();
