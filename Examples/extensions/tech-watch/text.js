// @ts-check
// Small text helpers shared by the tech watch's modules: pure, no DOM, no Loom.

(() => {
  "use strict";

  const root = /** @type {any} */ (globalThis);
  /** @type {TechWatchTypes.Namespace} */
  const TechWatch = (root.TechWatch = root.TechWatch || /** @type {any} */ ({}));

  /**
   * FNV-1a, 32 bits, as 8 hex digits — ids from URLs and guids. The page is
   * not a secure context: crypto.subtle may be missing.
   * @param {string} text
   */
  function fnv1a(text) {
    let hash = 0x811c9dc5;
    for (let index = 0; index < text.length; index++) {
      hash ^= text.charCodeAt(index);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return hash.toString(16).padStart(8, "0");
  }

  /** Control characters out, runs of whitespace to one space. @param {unknown} value */
  function collapse(value) {
    return String(value ?? "")
      // eslint-disable-next-line no-control-regex
      .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  /** At most `max` characters, with an ellipsis when cut. @param {unknown} value @param {number} max */
  function clip(value, max) {
    const text = collapse(value);
    return text.length <= max ? text : text.slice(0, Math.max(0, max - 1)).trimEnd() + "…";
  }

  /**
   * An http(s) URL as text, resolved against `base` — or null: a
   * `javascript:` link from a feed never reaches an href.
   * @param {unknown} value @param {string} [base]
   */
  function safeUrl(value, base) {
    if (typeof value !== "string" || !value.trim()) return null;
    try {
      const url = base ? new URL(value.trim(), base) : new URL(value.trim());
      return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
    } catch {
      return null;
    }
  }

  /** A rough Markdown-to-text for release notes: no markup, no images. @param {unknown} value */
  function markdownToText(value) {
    return collapse(String(value ?? "")
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/<[^>]+>/g, " ")
      .replace(/^#+\s*/gm, "")
      .replace(/[*_`>~|]/g, " "));
  }

  TechWatch.text = Object.freeze({ fnv1a, collapse, clip, safeUrl, markdownToText });
})();
