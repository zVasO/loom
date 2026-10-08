// One suite per Chromium binary found (lib/cdp.mjs), or one skipped test
// saying why there is none.
import { describe, test } from "node:test";
import { BROWSERS, NO_BROWSER } from "./cdp.mjs";

/** Generous: a slow CI runner never fails on a timeout, a hang still ends. */
export const TEST_TIMEOUT = 120_000;

export function eachBrowser(body, { kinds, skip } = {}) {
  const browsers = BROWSERS.filter((browser) => !kinds || kinds.includes(browser.kind));
  if (!browsers.length) {
    test("Chromium over the DevTools pipe", { skip: kinds ? `no ${kinds.join(" or ")} found — ${NO_BROWSER}` : NO_BROWSER }, () => {});
    return;
  }
  for (const browser of browsers) {
    describe(browser.label, { skip: skip?.(browser) || false }, () => body(browser));
  }
}

export const options = (extra = {}) => ({ timeout: TEST_TIMEOUT, ...extra });

/**
 * Measured on GitHub's Ubuntu runners, both builds: a renderer killed by
 * Page.crash is never reported (no Inspector.targetCrashed nor
 * Target.targetCrashed in 10 s) — the runner's crash handling, not Loom's
 * code: the same tests pass on macOS runners (Loom's platform) and on other
 * Linux machines. A skip reason there, false everywhere else.
 */
export const CRASH_UNREPORTED = process.platform === "linux" && process.env.GITHUB_ACTIONS === "true"
  && "GitHub's Ubuntu runners never report a renderer killed by Page.crash (both builds, measured); macOS, Loom's platform, runs it";
