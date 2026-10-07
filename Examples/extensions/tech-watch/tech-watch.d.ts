// Types of the tech watch's modules, shared by its scripts (checked with tsc --checkJs).
declare namespace TechWatchTypes {
  type SourceKind = "hn" | "github" | "rss" | "reddit" | "lobsters";

  interface Item {
    id: string;
    source: SourceKind;
    /** "Hacker News", "anthropics/claude-code", "r/swift", a feed's title. */
    sourceLabel: string;
    title: string;
    url: string;
    discussionUrl?: string;
    author?: string;
    /** ms since 1970; 0 when unknown. */
    publishedAt: number;
    score?: number;
    /** Plain text, 400 characters at most. */
    summary: string;
    tags?: string[];
  }

  interface AlsoOn {
    id: string;
    source: SourceKind;
    sourceLabel: string;
    discussionUrl?: string;
    score?: number;
  }

  interface StoredItem extends Item {
    firstSeenAt: number;
    read?: boolean;
    alsoOn?: AlsoOn[];
  }

  interface Feed {
    url: string;
    host: string;
    title: string;
  }

  interface Settings {
    digestHour: number;
    digestMinute: number;
    language: "fr" | "en";
    model: "haiku" | "sonnet" | "opus";
    maxItems: number;
    keywords: string[];
    muted: string[];
    hn: { enabled: boolean; minPoints: number; query: string };
    github: { repos: string[] };
    reddit: { subreddits: string[] };
    lobsters: { enabled: boolean; tags: string[] };
    feeds: Feed[];
  }

  interface SourceRequest {
    key: string;
    kind: SourceKind;
    label: string;
    url: string;
    headers: Record<string, string>;
    repo?: string;
    subreddit?: string;
  }

  interface SourceStatus {
    lastOkAt?: number;
    error?: string;
    count?: number;
  }

  interface State {
    /** When the watch first ran: the first digest waits for the first digest time after it. */
    startedAt: number | null;
    lastDigestAt: number | null;
    lastFetchAt: number | null;
    sources: Record<string, SourceStatus>;
  }

  interface DigestSection {
    theme: string;
    summary: string;
    itemIds: string[];
  }

  interface DigestBody {
    headline: string;
    sections: DigestSection[];
    mustRead: string[];
    /** Claude's text, when it was not the JSON asked for. */
    fallbackText?: string;
  }

  /** What a digest links to, kept with it: its items may be pruned later. */
  interface DigestItem {
    id: string;
    title: string;
    url: string;
    source: SourceKind;
    sourceLabel: string;
    discussionUrl?: string;
  }

  interface Digest extends DigestBody {
    id: string;
    createdAt: number;
    /** All the items it covered, best first. */
    items: DigestItem[];
    model?: string;
    costUsd?: number;
    /** Why there is no summary: Claude unavailable, too slow… */
    error?: string;
  }

  interface Text {
    fnv1a(text: string): string;
    collapse(value: unknown): string;
    clip(value: unknown, max: number): string;
    safeUrl(value: unknown, base?: string): string | null;
    markdownToText(value: unknown): string;
  }

  interface SettingsModule {
    DEFAULT_SETTINGS: Settings;
    MODELS: string[];
    LANGUAGES: string[];
    sanitizeSettings(raw: unknown): Settings;
  }

  interface Schedule {
    lastSlotAtOrBefore(now: number, hour: number, minute: number): number;
    nextSlotAfter(now: number, hour: number, minute: number): number;
    isDigestDue(now: number, settings: Settings, since: number | null): boolean;
    digestWindow(now: number, lastDigestAt: number | null): number;
    MAX_WINDOW: number;
  }

  interface Sources {
    parseRepo(text: string): string | null;
    parseSubreddit(text: string): string | null;
    parseLobstersTag(text: string): string | null;
    parseFeedUrl(text: string): { url: string; host: string } | { error: string };
    requestsFor(settings: Settings, now: number, githubToken: string | null): SourceRequest[];
    item(raw: Partial<Item> & { url?: unknown; title?: unknown }): Item | null;
    normalizeHN(json: unknown): Item[];
    normalizeGitHubReleases(json: unknown, repo: string): Item[];
    normalizeReddit(json: unknown, subreddit: string): Item[];
    normalizeLobsters(json: unknown): Item[];
  }

  interface Feeds {
    parseFeed(xml: string, feedUrl: string, parser: DOMParser, now: number): { title: string; items: Item[] };
    discoverFeeds(html: string, pageUrl: string, parser: DOMParser): string[];
    looksLikeHTML(body: string): boolean;
    htmlToText(html: string, parser: DOMParser): string;
  }

  interface Curate {
    canonicalUrl(value: string): string;
    mergeItems(stored: StoredItem[], fresh: Item[], now: number): { items: StoredItem[]; added: number };
    matchKeywords(item: Item, keywords: string[]): string[];
    isMuted(item: Item, muted: string[]): boolean;
    rank(items: StoredItem[], settings: Settings, now: number): StoredItem[];
    selectForDigest(items: StoredItem[], settings: Settings, since: number, now: number): StoredItem[];
    prune(items: StoredItem[], now: number, limits?: { maxPerSource?: number; maxItems?: number; maxAgeDays?: number }): StoredItem[];
    byteSize(value: unknown): number;
    fitBudget(items: StoredItem[], digests: Digest[], budget: number): { items: StoredItem[]; digests: Digest[] };
  }

  interface DigestModule {
    buildDigestPrompt(items: Item[], options: { language: "fr" | "en"; keywords: string[]; now: number }):
      { system: string; prompt: string; itemIds: string[] };
    parseDigestResponse(text: string, knownIds: string[]): DigestBody;
    buildSessionPrompt(item: Item, language: "fr" | "en"): string;
    statusFor(unread: number): { text: string; tooltip: string } | null;
    systemPrompt(language: "fr" | "en"): string;
  }

  type ListName = "keywords" | "muted" | "repos" | "subreddits" | "lobstersTags";

  interface ViewActions {
    markRead(id: string): void;
    markAllRead(ids: string[]): void;
    sendToSession(item: Item): void;
    updateSettings(edit: (draft: Settings) => void): void;
    /** An error message, or null when done. */
    editList(list: ListName, op: "add" | "remove", value: string): string | null;
    addFeed(text: string): Promise<string | null>;
    removeFeed(url: string): void;
    regrant(host: string): Promise<void>;
    setGithubToken(token: string | null): Promise<void>;
  }

  interface ViewContext {
    now: number;
    settings: Settings;
    items: StoredItem[];
    digests: Digest[];
    state: State;
    grantedHosts: string[];
    declaredHosts: string[];
    busy: { refresh: boolean; digest: boolean };
    githubTokenSet: boolean;
    /** The latest digest's items not read yet. */
    unreadIds: string[];
    sourceLabels: Record<string, string>;
    showSummaries: boolean;
    actions: ViewActions;
  }

  interface View {
    h(tag: string, props?: object, ...children: unknown[]): HTMLElement;
    renderDigest(container: HTMLElement, context: ViewContext): void;
    renderItems(container: HTMLElement, context: ViewContext): void;
    renderSettings(container: HTMLElement, context: ViewContext): void;
    ago(then: number, now: number): string;
    when(time: number): string;
  }

  interface Namespace {
    view: View;
    text: Text;
    settings: SettingsModule;
    schedule: Schedule;
    sources: Sources;
    feeds: Feeds;
    curate: Curate;
    digest: DigestModule;
  }
}

declare const TechWatch: TechWatchTypes.Namespace;
