// The facts the event-driven settle (design §4) stands on, and the traces
// LoomChromium's SettleMachine tests replay. For each scenario — a click
// that does nothing, fetches, fetches twice in a chain, navigates (a link, a
// timer, a form POST), pushes a history state, changes the hash, or fetches
// while a long-poll XHR runs — the test clicks as the engine does (moved,
// pressed, released in one write) and sends the barrier (a setTimeout(0)
// task in the helper's world), recording every DevTools event of the tab.
//
// Asserted: whatever the click starts synchronously, in a microtask or in a
// setTimeout(0) — Page.frameRequestedNavigation, the Document or Fetch
// Network.requestWillBeSent, Page.navigatedWithinDocument — is on the pipe
// before the barrier's reply. When the navigation wins, the barrier fails
// (lib/init.mjs DOCUMENT_GONE): sent into the new document ("Cannot find
// context with specified id"), after Page.frameNavigated; pending when the old
// one went ("Execution context was destroyed."), possibly BEFORE it — the
// engine reads either as a navigation whose commit may still be coming.
//
// The traces go to fixtures/traces/<scenario>.<binary>.json when missing or
// with LOOM_CDP_UPDATE=1 (times vary run to run: they are not compared).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { delay, launch, performance, settle, within } from "./lib/cdp.mjs";
import { BARRIER_FUNCTION, DOCUMENT_GONE, SENT_AFTER_COMMIT, openTab } from "./lib/init.mjs";
import { cdpFixtures, startServer } from "./lib/server.mjs";
import { buildTrace } from "./lib/trace.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const NAVIGATION_STARTS = new Set(["Page.frameRequestedNavigation", "Page.frameStartedNavigating"]);

const SCENARIOS = [
  { name: "click-noop", target: "#noop", description: "A click whose handler does nothing: the barrier answers, nothing else happens." },
  { name: "click-fetch", target: "#fetch", fetches: ["/ok?s=fetch"], description: "A click that starts fetch() synchronously." },
  { name: "click-fetch-chain", target: "#chain", fetches: ["/ok?s=chain-1&delay=40"], tail: 700,
    description: "A click that fetches, then fetches again when the first answers (40 ms each): the second starts after the barrier." },
  { name: "click-navigates", target: "#link", navigates: true, description: "A click on a link to another page of the same origin." },
  { name: "click-navigates-in-timer", target: "#later", navigates: true, description: "A click whose handler sets location.href in a setTimeout(0)." },
  { name: "click-submits-post", target: "#submit", navigates: true, post: true, description: "A click on a form's submit button: a POST navigation." },
  { name: "click-push-state", target: "#push", sameDocument: true, description: "A click that calls history.pushState: same document, no load." },
  { name: "click-hash", target: "#hash", sameDocument: true, description: "A click that changes location.hash: same document, no load." },
  { name: "click-fetch-during-long-poll", page: "/settle.html?poll", warmup: 1600, target: "#fetch", fetches: ["/ok?s=fetch"], tail: 2300, longPoll: true,
    description: "A click that fetches while the page keeps a long-poll XHR open (700 ms each, re-sent at once): the poll was in flight at the mark." },
];

eachBrowser((browser) => {
  let server;
  let chrome;
  before(async () => {
    server = await startServer();
    chrome = await launch(browser);
  });
  after(async () => {
    await chrome?.close();
    await server?.close();
  });

  for (const scenario of SCENARIOS) {
    test(`${scenario.name}: ${scenario.description}`, options(), async (t) => {
      const tab = await openTab(chrome);
      const wire = chrome.conn.startRecording();
      let recording = true;
      try {
        await tab.navigate(server.url(scenario.page || "/settle.html"));
        if (scenario.warmup) await delay(scenario.warmup);
        const { x, y } = await tab.centerOf(scenario.target);
        const world = await tab.world();
        const loaderAtMark = tab.loaderId;

        const mark = performance.now();
        const acks = tab.click(x, y);
        const ackOutcomes = await Promise.all(acks.map(settle));
        const barrier = tab.session.send("Runtime.callFunctionOn", {
          functionDeclaration: BARRIER_FUNCTION, executionContextId: world, returnByValue: true, awaitPromise: true, silent: true,
        });
        const barrierOutcome = await settle(barrier);

        const sinceMark = () => wire.filter((e) => e.at >= mark && e.sessionId === tab.session.id && e.dir === "event");
        const navigationStarted = sinceMark().some((e) => NAVIGATION_STARTS.has(e.method)) || !barrierOutcome.ok;
        const isNewLoad = (e) => e.method === "Page.lifecycleEvent" && e.params.name === "load" && e.params.loaderId !== loaderAtMark
          && e.params.frameId === tab.frameId;
        if (navigationStarted) {
          if (!sinceMark().some(isNewLoad)) {
            await within(tab.session.waitForEvent("Page.lifecycleEvent", { predicate: (p) => p.name === "load" && p.loaderId !== loaderAtMark && p.frameId === tab.frameId, timeout: 10_000 }), 11_000);
          }
          await delay(300);
        } else {
          await delay(scenario.tail ?? 400);
        }
        chrome.conn.stopRecording();
        recording = false;

        // ---- the trace
        const refs = new Map([[acks[0].id, "click.moved"], [acks[1].id, "click.pressed"], [acks[2].id, "click.released"], [barrier.id, "barrier"]]);
        const { entries, token } = buildTrace({ entries: wire, sessionId: tab.session.id, mark, refs, origin: server.base });
        const trace = {
          $comment: "Recorded by Tests/AgentBrowserCDP/settle.test.mjs for SettleMachine replay. t: ms from the mark (just before the click's write). "
            + "Ids are tokens (F frame, L loader — a navigation's Document request shares its loader's —, R request); {origin} is the fixture server.",
          scenario: scenario.name,
          description: scenario.description,
          binary: browser.kind,
          product: chrome.version.product,
          mainFrame: token("F", tab.frameId),
          loaderAtMark: token("L", loaderAtMark),
          barrier: barrierOutcome.ok ? "answered" : barrierOutcome.error.cdpMessage,
          entries,
        };
        // Before the facts: a failure on CI still shows the wire order.
        const markAt = entries.findIndex((e) => e.mark);
        t.diagnostic(entries.slice(markAt).filter((e) => !e.event?.startsWith("Page.lifecycleEvent")).slice(0, 14)
          .map((e) => `${e.t} ${e.event || (e.send ? "→ " + e.ref : e.reply ? "← " + e.reply + (e.error ? " (" + e.error + ")" : "") : "mark")}`).join(" | "));

        // ---- the facts
        const ownEvents = wire.filter((e) => e.sessionId === tab.session.id && e.dir === "event");
        const barrierReply = wire.findIndex((e) => e.dir === "reply" && e.id === barrier.id);
        const markIndex = wire.findIndex((e) => e.at >= mark);
        const between = ownEvents.filter((e) => e.seq > wire[markIndex].seq && e.seq < wire[barrierReply].seq);
        const firstBefore = (match) => between.find(match);
        const tracked = (e) => e.method === "Network.requestWillBeSent" && ["Document", "XHR", "Fetch"].includes(e.params.type);
        assert.ok(ackOutcomes.every((o) => o.ok), "the click's three events were acknowledged");

        if (!scenario.navigates && !scenario.sameDocument) {
          assert.ok(barrierOutcome.ok, "the barrier answered: " + barrierOutcome.error?.message);
          assert.ok(!between.some((e) => NAVIGATION_STARTS.has(e.method) || e.method === "Page.navigatedWithinDocument"), "no navigation");
          const fetched = between.filter(tracked).map((e) => new URL(e.params.request.url).pathname + new URL(e.params.request.url).search);
          if (scenario.longPoll) {
            assert.deepEqual(fetched.filter((path) => !path.startsWith("/poll")), scenario.fetches);
          } else {
            assert.deepEqual(fetched, scenario.fetches ?? [], "the requests started before the barrier's reply");
          }
          for (const e of between.filter(tracked)) {
            if (!e.params.request.url.includes("/poll")) assert.equal(e.params.type, "Fetch");
          }
        }
        if (scenario.navigates) {
          assert.ok(firstBefore((e) => e.method === "Page.frameRequestedNavigation" && e.params.frameId === tab.frameId),
            "frameRequestedNavigation before the barrier's reply");
          const documentRequest = ownEvents.find((e) => tracked(e) && e.params.type === "Document" && e.seq > wire[markIndex].seq);
          assert.ok(documentRequest, "the navigation's Document request");
          assert.equal(documentRequest.params.request.method, scenario.post ? "POST" : "GET");
          if (!barrierOutcome.ok) {
            assert.match(barrierOutcome.error.message, DOCUMENT_GONE);
            const isCommit = (e) => e.method === "Page.frameNavigated" && !e.params.frame.parentId;
            assert.ok(ownEvents.some((e) => isCommit(e) && e.seq > wire[markIndex].seq), "the navigation committed");
            if (SENT_AFTER_COMMIT.test(barrierOutcome.error.message)) {
              assert.ok(firstBefore(isCommit), "a barrier sent into the new document fails after the commit");
            } else {
              // Lost in flight: the old document went with the barrier pending — its
              // failure may precede the commit on the wire, never the navigation's start.
              assert.ok(firstBefore((e) => e.method === "Page.frameStartedNavigating" || (tracked(e) && e.params.type === "Document")),
                "a barrier lost in flight comes after the navigation started");
              t.diagnostic(`barrier lost in flight: ${barrierOutcome.error.cdpMessage}, ${firstBefore(isCommit) ? "after" : "before"} Page.frameNavigated`);
            }
          }
          assert.ok(ownEvents.some((e) => isNewLoad(e)), "the new document loaded");
        }
        if (scenario.sameDocument) {
          assert.ok(barrierOutcome.ok, "the barrier answered: " + barrierOutcome.error?.message);
          assert.ok(firstBefore((e) => e.method === "Page.navigatedWithinDocument" && e.params.frameId === tab.frameId), "navigatedWithinDocument before the barrier's reply");
          assert.ok(!between.some((e) => e.method === "Page.frameStartedNavigating" && e.params.navigationType !== "sameDocument"
            && e.params.navigationType !== "historySameDocument"), "no cross-document navigation");
        }
        if (scenario.longPoll) {
          const before = ownEvents.filter((e) => e.seq < wire[markIndex].seq);
          const polls = before.filter((e) => e.method === "Network.requestWillBeSent" && e.params.request.url.includes("/poll"));
          const finished = new Set(before.filter((e) => e.method === "Network.loadingFinished" || e.method === "Network.loadingFailed").map((e) => e.params.requestId));
          assert.ok(polls.some((e) => !finished.has(e.params.requestId)), "a long poll was in flight at the mark");
          const after = ownEvents.filter((e) => e.seq > wire[barrierReply].seq);
          assert.ok(after.some((e) => e.method === "Network.requestWillBeSent" && e.params.request.url.includes("/poll")), "the poll went on after the barrier");
        }

        // ---- the trace file (fixtures/traces), once the facts hold
        const file = resolve(cdpFixtures, "traces", `${scenario.name}.${browser.kind}.json`);
        if (process.env.LOOM_CDP_UPDATE === "1" || !existsSync(file)) {
          writeFileSync(file, JSON.stringify(trace, null, 1) + "\n");
          t.diagnostic(`wrote ${file}`);
        }
      } finally {
        if (recording) chrome.conn.stopRecording();
        await tab.close();
      }
    });
  }
});
