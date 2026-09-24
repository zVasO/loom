import Foundation

/// `window.loom`: the SDK every extension page gets, injected at document
/// start (ADR-0011). A convenience, never a guard — every check happens on
/// the native side of the bridge, and a page that talks to
/// `webkit.messageHandlers.loom` directly gets exactly the same answers.
///
/// Kept as a Swift string rather than a resource: the release script copies
/// no SwiftPM resource bundle into the app. The Node tests in
/// `Examples/extensions/tests/` extract it from this file — the literal must
/// stay a `#"""` raw string, its lines at column 0.
public enum LoomSDKScript {
    public static let source = #"""
(() => {
  "use strict";
  if (window.loom) return;

  const boot = window.__loomBoot || {};
  try { delete window.__loomBoot; } catch (_) { window.__loomBoot = undefined; }

  const channel = window.webkit && window.webkit.messageHandlers
    ? window.webkit.messageHandlers.loom
    : undefined;

  class LoomError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "LoomError";
      this.code = code;
    }
  }

  let sequence = 0;
  function call(method, params) {
    if (!channel) {
      return Promise.reject(new LoomError("internalError", "the Loom bridge is not available"));
    }
    const request = {
      id: String(++sequence),
      method: String(method),
      params: params === undefined || params === null ? {} : params,
    };
    let text;
    try {
      text = JSON.stringify(request);
    } catch (error) {
      return Promise.reject(new LoomError("invalidParams", "the parameters are not JSON: " + error));
    }
    return Promise.resolve(channel.postMessage(text)).then(
      (reply) => {
        let response;
        try {
          response = JSON.parse(reply);
        } catch (_) {
          throw new LoomError("internalError", "malformed bridge response");
        }
        if (response && response.error) {
          throw new LoomError(response.error.code, response.error.message);
        }
        return response && response.result !== undefined ? response.result : null;
      },
      (reason) => {
        // A refusal before dispatch arrives as "code: message".
        const text = String(reason && reason.message !== undefined ? reason.message : reason);
        const match = /^([A-Za-z]+): ([\s\S]*)$/.exec(text);
        throw match ? new LoomError(match[1], match[2]) : new LoomError("internalError", text);
      }
    );
  }

  const listeners = new Map();
  function on(name, callback) {
    if (typeof callback !== "function") throw new TypeError("loom.on needs a function");
    const key = String(name);
    if (!listeners.has(key)) listeners.set(key, new Set());
    listeners.get(key).add(callback);
    return () => {
      const set = listeners.get(key);
      if (set) set.delete(callback);
    };
  }

  function dispatch(name, payload) {
    for (const key of [name, "*"]) {
      const set = listeners.get(key);
      if (!set) continue;
      for (const callback of Array.from(set)) {
        try {
          if (key === "*") callback(name, payload);
          else callback(payload);
        } catch (error) {
          console.error("[loom] a listener of " + name + " threw", error);
        }
      }
    }
  }

  function kebab(token) {
    return String(token).replace(/[A-Z]/g, (letter) => "-" + letter.toLowerCase());
  }

  let theme = boot.theme || { isLight: false, tokens: {} };
  function applyTheme() {
    const root = document.documentElement;
    if (!root) {
      document.addEventListener("DOMContentLoaded", applyTheme, { once: true });
      return;
    }
    for (const [token, value] of Object.entries(theme.tokens || {})) {
      root.style.setProperty("--loom-" + kebab(token), value);
    }
    root.setAttribute("data-loom-appearance", theme.isLight ? "light" : "dark");
    root.style.colorScheme = theme.isLight ? "light" : "dark";
  }
  applyTheme();

  Object.defineProperty(window, "__loomEmit", {
    value: (text) => {
      let event;
      try {
        event = typeof text === "string" ? JSON.parse(text) : text;
      } catch (_) {
        return;
      }
      if (!event || typeof event.name !== "string") return;
      if (event.name === "theme.changed" && event.payload) {
        theme = event.payload;
        applyTheme();
      }
      dispatch(event.name, event.payload);
    },
    writable: false,
    configurable: false,
  });

  function encodeBody(init) {
    const headers = Object.assign({}, init.headers || {});
    let body = init.body;
    if (body !== undefined && body !== null && typeof body !== "string") {
      body = JSON.stringify(body);
      const hasType = Object.keys(headers).some((name) => name.toLowerCase() === "content-type");
      if (!hasType) headers["Content-Type"] = "application/json";
    }
    return { headers, body: body === undefined || body === null ? undefined : body };
  }

  function decodeBody(response) {
    if (response.bodyEncoding !== "base64") return response.body;
    try {
      const binary = atob(response.body);
      const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
      return new TextDecoder().decode(bytes);
    } catch (_) {
      return response.body;
    }
  }

  const loom = {
    apiVersion: 1,
    extensionId: boot.extensionId || null,
    get theme() {
      return theme;
    },
    LoomError,
    call,
    on,
    info: () => call("loom.info"),
    projects: {
      list: () => call("projects.list").then((result) => result.projects),
    },
    sessions: {
      list: (options) => call("sessions.list", options || {}).then((result) => result.sessions),
      get: (sessionId) => call("sessions.get", { sessionId }),
      open: (sessionId) => call("sessions.open", { sessionId }).then(() => undefined),
      launch: (options) => call("sessions.launch", options || {}),
    },
    http: {
      fetch: (url, init) => {
        const options = init || {};
        const { headers, body } = encodeBody(options);
        const request = { url: String(url), method: (options.method || "GET").toUpperCase(), headers };
        if (body !== undefined) request.body = body;
        return call("http.fetch", request).then((response) => ({
          status: response.status,
          ok: response.status >= 200 && response.status < 300,
          url: response.url,
          headers: response.headers,
          body: response.body,
          bodyEncoding: response.bodyEncoding,
          text: () => decodeBody(response),
          json: () => JSON.parse(decodeBody(response)),
        }));
      },
    },
    secrets: {
      get: (key) => call("secrets.get", { key }).then((result) => (result && result.value) ?? null),
      set: (key, value) => call("secrets.set", { key, value: String(value) }).then(() => undefined),
      delete: (key) => call("secrets.delete", { key }).then(() => undefined),
    },
    storage: {
      get: (key) => call("storage.get", { key }).then((result) => (result ? result.value ?? null : null)),
      set: (key, value) => call("storage.set", { key, value: value === undefined ? null : value }).then(() => undefined),
      delete: (key) => call("storage.delete", { key }).then(() => undefined),
    },
    ui: {
      openExternal: (url) => call("ui.openExternal", { url: String(url) }).then(() => undefined),
    },
  };

  Object.freeze(loom.projects);
  Object.freeze(loom.sessions);
  Object.freeze(loom.http);
  Object.freeze(loom.secrets);
  Object.freeze(loom.storage);
  Object.freeze(loom.ui);
  Object.defineProperty(window, "loom", { value: Object.freeze(loom), writable: false, configurable: false });
})();
"""#
}
