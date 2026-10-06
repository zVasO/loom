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
