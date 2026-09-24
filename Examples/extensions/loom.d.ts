// Types of `window.loom`, the SDK Loom injects into every extension page
// (bridge version 1 — ADR-0011, docs/extensions.md). Reference it from a
// checked JavaScript file with:
//   /// <reference path="../loom.d.ts" />

declare namespace Loom {
  type ErrorCode =
    | "invalidRequest"
    | "unknownMethod"
    | "invalidParams"
    | "forbidden"
    | "notFound"
    | "conflict"
    | "network"
    | "tooLarge"
    | "internalError";

  interface LoomError extends Error {
    readonly name: "LoomError";
    readonly code: ErrorCode | string;
  }

  interface Theme {
    isLight: boolean;
    /** The 16 palette tokens by name, as `#RRGGBB` — also set as `--loom-<kebab-name>` CSS variables. */
    tokens: Record<string, string>;
  }

  interface Info {
    loomApi: number;
    appVersion: string;
    extensionId: string;
    theme: Theme;
  }

  interface Project {
    id: string;
    name: string;
  }

  type SessionState =
    | "draft"
    | "starting"
    | "working"
    | "needs_input"
    | "idle"
    | "completed"
    | "failed"
    | "interrupted"
    | "archived";

  interface Session {
    id: string;
    title: string;
    state: SessionState | string;
    projectID?: string;
    branch?: string;
    worktreePath?: string;
    badges: string[];
    /** ISO 8601. */
    createdAt: string;
  }

  interface LaunchOptions {
    /** A project id from `loom.projects.list()`; the user can change it in the sheet. */
    projectId?: string;
    /** What claude starts with. Shown, editable, in Loom's confirmation sheet. */
    prompt: string;
    title?: string;
    badges?: string[];
    placement?: "worktree" | "folder";
  }

  interface LaunchResult {
    /** False when the user cancelled. */
    launched: boolean;
    sessionId?: string;
  }

  interface FetchInit {
    method?: "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE";
    headers?: Record<string, string>;
    /** A string is sent as is; anything else as JSON. */
    body?: unknown;
  }

  interface FetchResponse {
    status: number;
    ok: boolean;
    url: string;
    /** Lowercased names. */
    headers: Record<string, string>;
    body: string;
    bodyEncoding: "utf8" | "base64";
    text(): string;
    json(): any;
  }

  interface EventPayloads {
    "theme.changed": Theme;
    "sessions.changed": { sessions: Session[] };
    "session.stateChanged": { sessionId: string; state: SessionState | string; previous: string | null };
    command: { id: string };
  }

  interface SDK {
    readonly apiVersion: 1;
    readonly extensionId: string | null;
    readonly theme: Theme;
    readonly LoomError: new (code: string, message: string) => LoomError;

    call(method: string, params?: unknown): Promise<any>;
    on<K extends keyof EventPayloads>(name: K, callback: (payload: EventPayloads[K]) => void): () => void;
    on(name: "*", callback: (name: string, payload: unknown) => void): () => void;
    info(): Promise<Info>;

    projects: {
      /** Needs `"projects": ["read"]`. */
      list(): Promise<Project[]>;
    };
    sessions: {
      /** Needs `"sessions": ["read"]`. */
      list(options?: { includeArchived?: boolean }): Promise<Session[]>;
      get(sessionId: string): Promise<Session>;
      /** Brings a live session on screen. */
      open(sessionId: string): Promise<void>;
      /** Needs `"sessions": ["launch"]`, and the extension on screen. The user confirms in Loom. */
      launch(options: LaunchOptions): Promise<LaunchResult>;
    };
    http: {
      /** Needs the host in `"network"`. HTTPS only, no cookies. */
      fetch(url: string, init?: FetchInit): Promise<FetchResponse>;
    };
    secrets: {
      get(key: string): Promise<string | null>;
      set(key: string, value: string): Promise<void>;
      delete(key: string): Promise<void>;
    };
    storage: {
      get<T = unknown>(key: string): Promise<T | null>;
      set(key: string, value: unknown): Promise<void>;
      delete(key: string): Promise<void>;
    };
    ui: {
      /** Opens an https URL in the user's browser. */
      openExternal(url: string): Promise<void>;
    };
  }
}

interface Window {
  readonly loom: Loom.SDK;
}

declare const loom: Loom.SDK;
