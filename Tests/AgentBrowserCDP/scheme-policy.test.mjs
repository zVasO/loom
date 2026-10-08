// Which top-level navigations Chromium itself refuses (critic §2: no engine
// re-checks a page's own navigations as WebKit's decidePolicyFor did):
// - a page cannot take the top frame to data:, file:, chrome: or an unknown
//   (external) scheme — by script or by a trusted click on a link; nothing
//   commits. Its javascript: URL runs in its own document (it is the page's
//   own script); blob: does commit (documented as partial parity).
// - Loom's own Page.navigate is NOT filtered: data: and file: commit (a file
//   is readable), and javascript: runs in the current page. Hence the engine
//   allows only http, https and about:blank before every Page.navigate,
//   the panel's address bar included.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { delay, launch, settle } from "./lib/cdp.mjs";
import { openTab } from "./lib/init.mjs";
import { startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const REFUSED = [
  ["data:", "data:text/html,<title>data</title><p>data</p>"],
  ["file:", "file:///etc/hosts"],
  ["chrome:", "chrome://version"],
  ["an unknown scheme", "loom-test-scheme://open"],
];

eachBrowser((browser) => {
  let server;
  let chrome;
  let tab;
  before(async () => {
    server = await startServer();
    chrome = await launch(browser);
    tab = await openTab(chrome);
  });
  after(async () => {
    await chrome?.close();
    await server?.close();
  });

  /** The URL the main frame commits within `timeout` ms of `action` (a refused one never does), or null. */
  async function commitAfter(action, timeout = 1000) {
    const commit = settle(tab.session.waitForEvent("Page.frameNavigated", { predicate: ({ frame }) => !frame.parentId, timeout }));
    await action();
    const outcome = await commit;
    return outcome.ok ? outcome.value.frame.url : null;
  }

  for (const [scheme, url] of REFUSED) {
    test(`the page cannot take the top frame to ${scheme}, by script or by a trusted click`, options(), async () => {
      await tab.navigate(server.url("/blank?from"));
      assert.equal(await commitAfter(() => tab.evaluate(`location.href = ${JSON.stringify(url)}; true`, { userGesture: true })), null, "location.href");
      assert.equal(await tab.evaluate("location.href"), server.url("/blank?from"));
      await tab.evaluate(`(() => { const a = document.createElement("a"); a.id = "go"; a.href = ${JSON.stringify(url)}; a.textContent = "go"; a.style.cssText = "display:block;width:100px;height:30px"; document.body.prepend(a); return true; })()`);
      const { x, y } = await tab.centerOf("#go");
      assert.equal(await commitAfter(() => Promise.all(tab.click(x, y))), null, "a trusted click on a link");
      assert.equal(await tab.evaluate("location.href"), server.url("/blank?from"));
    });
  }

  test("a page's javascript: URL runs in its own document; nothing commits", options(), async () => {
    await tab.navigate(server.url("/blank?js"));
    assert.equal(await commitAfter(() => tab.evaluate(`location.href = "javascript:void(document.title = 'ran')"; true`, { userGesture: true })), null);
    assert.equal(await tab.evaluate("document.title"), "ran");
    assert.equal(await tab.evaluate("location.search"), "?js");
  });

  test("blob: from the page does commit (partial parity)", options(), async () => {
    await tab.navigate(server.url("/blank?blob"));
    const committed = await commitAfter(() => tab.evaluate(`location.href = URL.createObjectURL(new Blob(["<p>blob</p>"], { type: "text/html" })); true`, { userGesture: true }), 10_000);
    assert.match(committed ?? "", /^blob:http:\/\/127\.0\.0\.1:\d+\//);
  });

  // mailto: and news: never commit: "nothing commits" cannot see them. A
  // full browser hands them to the system (Chrome's external protocol
  // handler allows them without asking): on Linux through xdg-email and
  // xdg-open, faked here on Chromium's PATH; on a Mac through LaunchServices
  // (Mail opens a message the page wrote), which a runner cannot observe.
  test("mailto: and news: never leave chrome-headless-shell for an app of the system", options({
    skip: process.platform !== "linux" && "the hand-off goes through LaunchServices on a Mac: the Mac checklist covers it",
  }), async (t) => {
    const bin = mkdtempSync(join(tmpdir(), "loom-xdg-"));
    const marker = join(bin, "handed-off.log");
    for (const name of ["xdg-email", "xdg-open"]) {
      writeFileSync(join(bin, name), `#!/bin/sh\necho "${name} $@" >> ${marker}\n`);
      chmodSync(join(bin, name), 0o755);
    }
    const own = await launch(browser, { pathPrefix: bin });
    try {
      const page = await openTab(own);
      await page.navigate(server.url("/blank?mail"));
      await page.evaluate(`location.href = "mailto:agent@example.com?subject=from&body=the-page"; true`, { userGesture: true });
      await delay(800);
      await page.evaluate(`(() => { const a = document.createElement("a"); a.id = "news"; a.href = "news:comp.lang.javascript"; a.textContent = "news"; a.style.cssText = "display:block;width:100px;height:30px"; document.body.prepend(a); return true; })()`);
      const { x, y } = await page.centerOf("#news");
      await Promise.all(page.click(x, y));
      await delay(1200);
      const handed = existsSync(marker) ? readFileSync(marker, "utf8").trim() : "";
      t.diagnostic(`handed to the system: ${handed || "nothing"}`);
      if (browser.kind === "headlessShell") {
        assert.equal(handed, "", "Loom's pick hands nothing to the system");
      }
    } finally {
      await own.close();
      rmSync(bin, { recursive: true, force: true });
    }
  });

  test("Loom's own Page.navigate is not filtered: data: and file: commit, javascript: runs — the engine must allow-list", options(), async () => {
    const data = await tab.navigate("data:text/html,<title>data</title>");
    assert.equal(data.errorText, undefined, "data: commits");
    assert.equal(await tab.evaluate("location.protocol"), "data:");
    const file = await tab.navigate("file:///etc/hosts");
    assert.equal(file.errorText, undefined, "file: commits");
    assert.match(await tab.evaluate("document.body.innerText"), /localhost/, "and the file is readable");
    await tab.navigate(server.url("/blank?before-js"));
    const script = await tab.session.send("Page.navigate", { url: "javascript:void(document.title = 'ran from Page.navigate')" });
    assert.equal(script.errorText, "net::ERR_ABORTED");
    assert.equal(await tab.evaluate("document.title"), "ran from Page.navigate", "the script ran in the current page");
  });
});
