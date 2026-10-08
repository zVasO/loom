// "Local sites only" under Chromium (plan §3, critic C11): Loom points
// Chromium's proxy at a ChromiumFence — a 127.0.0.1:0 listener of its own that
// accepts and closes every connection — and bypasses the proxy for loopback
// only (flags.json localOnly). Ground truth is what reaches this machine's
// non-loopback address (where the fixture server also listens), a request
// for a DNS name mapped there, and UDP datagrams:
// - loopback goes direct (127.0.0.0/8, localhost, *.localhost, 0.0.0.0, [::1]);
// - every leak vector the step-0 probes found stays blocked: navigations
//   (Loom's, the page's, window.open, iframes), subresources, fetch to IP
//   literals in every spelling, XHR, WebSocket, EventSource, beacons, pings,
//   workers and service workers, preconnect/prefetch/speculation rules, and
//   WebRTC (no candidate, no datagram);
// - link-local and public names, and a name aliasing 127.0.0.1, meet the fence;
// - the headless shell opens no connection of its own while idle.
// Vectors that need a non-loopback interface are skipped when there is none.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import dgram from "node:dgram";
import net from "node:net";
import { delay, launch, performance, settle, withTimeout } from "./lib/cdp.mjs";
import { openTab } from "./lib/init.mjs";
import { externalIPv4, startServer } from "./lib/server.mjs";
import { eachBrowser, options } from "./lib/suite.mjs";

const EXT = externalIPv4();
const NEEDS_EXT = EXT ? false : "this machine has no non-loopback IPv4 address to watch";

/** The fence: accepts, closes, counts. Loom's is ChromiumFence (Swift). */
async function startFence() {
  const connections = [];
  const server = net.createServer((socket) => {
    connections.push(performance.now());
    socket.on("error", () => {});
    socket.destroy();
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  return { port: server.address().port, connections, close: () => new Promise((done) => server.close(done)) };
}

async function startUdpSink() {
  const datagrams = [];
  const socket = dgram.createSocket("udp4");
  socket.on("message", (message, from) => datagrams.push({ from: from.address, bytes: message.length }));
  await new Promise((done) => socket.bind(0, "0.0.0.0", done));
  return { port: socket.address().port, datagrams, close: () => socket.close() };
}

async function startLoopback6() {
  // Sockets are destroyed at close: server.close() alone waits for every
  // connection to end, and Chromium may keep one open (on CI, where [::1]
  // exists, the suite hung there for 30 minutes).
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    socket.end("HTTP/1.1 200 OK\r\naccess-control-allow-origin: *\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok");
  });
  try {
    await new Promise((done, fail) => { server.once("error", fail); server.listen(0, "::1", done); });
    return {
      port: server.address().port,
      close: () => new Promise((done) => {
        for (const socket of sockets) socket.destroy();
        server.close(() => done());
      }),
    };
  } catch {
    return null;
  }
}

eachBrowser((browser) => {
  let server;
  let fence;
  let udp;
  let loopback6;
  let chrome;
  let tab;
  let page;
  before(async () => {
    server = await startServer({ host: "0.0.0.0" });
    fence = await startFence();
    udp = await startUdpSink();
    loopback6 = await startLoopback6();
    // Names only this test resolves: one to the outside address, one aliasing loopback.
    const rules = ["MAP loopback-alias.test 127.0.0.1", ...(EXT ? [`MAP leak.test ${EXT}`, `MAP www.leak.test ${EXT}`] : [])];
    chrome = await launch(browser, { fencePort: fence.port, args: [`--host-resolver-rules=${rules.join(", ")}`] });
    page = server.url("/leak-probe.html");
    tab = await openTab(chrome, { url: page });
  });
  after(async () => {
    await chrome?.close();
    await fence?.close();
    udp?.close();
    await loopback6?.close();
    await server?.close();
  });

  const probe = (call, { userGesture = false } = {}) => withTimeout(tab.evaluate(call, { userGesture }), 10_000, call);
  const call = (name, ...args) => `probes.${name}(${args.map((arg) => JSON.stringify(arg)).join(", ")})`;
  const fenceDuring = async (action) => {
    const before = fence.connections.length;
    const outcome = await action();
    await delay(200);
    return { outcome, fenced: fence.connections.length - before };
  };

  test("idle, the headless shell opens no connection of its own", options({ skip: browser.kind !== "headlessShell" && "the full browser calls Google services on its own when idle; local-only sends it all into the fence (the leak test below checks nothing gets out)" }), async (t) => {
    await tab.navigate("about:blank");
    const before = fence.connections.length;
    await delay(3000);
    t.diagnostic(`${fence.connections.length - before} connections in 3 s`);
    assert.equal(fence.connections.length - before, 0);
    await tab.navigate(page);
  });

  test("loopback goes direct: 127.0.0.0/8, localhost, *.localhost, 0.0.0.0, [::1], WebSocket, Page.navigate", options(), async (t) => {
    const port = server.port;
    const direct = ["127.0.0.1", "localhost", "app.localhost", ...(process.platform === "linux" ? ["127.0.0.2", "0.0.0.0"] : [])];
    for (const host of direct) {
      assert.equal(await probe(call("fetch", `http://${host}:${port}/ok?direct=${host}`)), "ok 200", host);
      const hit = server.hits.findLast((h) => h.query === `?direct=${host}`);
      assert.ok(hit && !hit.local.startsWith(EXT ?? "\0"), `${host} arrived over loopback`);
    }
    if (loopback6) assert.equal(await probe(call("fetch", `http://[::1]:${loopback6.port}/`)), "ok 200", "[::1]");
    else t.diagnostic("no IPv6 loopback here: [::1] not tried");
    assert.equal(await probe(call("webSocket", `ws://localhost:${port}/socket`)), "open");
    assert.equal(await probe(call("webSocket", `ws://127.0.0.1:${port}/socket`)), "open");
    const reply = await tab.navigate(`http://localhost:${port}/blank?direct-navigation`);
    assert.equal(reply.errorText, undefined);
    assert.equal(await tab.evaluate("location.search"), "?direct-navigation");
    await tab.navigate(page);
  });

  test("link-local, public and loopback-aliasing names meet the fence, never the network", options(), async () => {
    const port = server.port;
    for (const url of ["http://169.254.169.254/latest/meta-data/", "http://example.com/", `http://loopback-alias.test:${port}/ok?alias`]) {
      const { outcome, fenced } = await fenceDuring(() => probe(call("fetch", url)));
      assert.equal(outcome, "error Failed to fetch", url);
      assert.ok(fenced >= 1, `${url}: through the fence`);
    }
    assert.ok(!server.hits.some((h) => h.query === "?alias"), "a name is matched as a string, never resolved to loopback");
  });

  test("no leak vector reaches the outside", options({ skip: NEEDS_EXT }), async (t) => {
    const port = server.port;
    const at = (host, tag, path = "/ok") => `http://${host}:${port}${path}?probe=${tag}`;
    const octets = EXT.split(".").map(Number);
    const decimal = String(((octets[0] * 256 + octets[1]) * 256 + octets[2]) * 256 + octets[3]);
    const hex = "0x" + octets.map((n) => n.toString(16).padStart(2, "0")).join("");
    const vectors = [
      { tag: "F1", name: "fetch, IP literal", js: call("fetch", at(EXT, "F1")), fails: true },
      { tag: "F2", name: "fetch, decimal IP", js: call("fetch", `http://${decimal}:${port}/ok?probe=F2`), fails: true },
      { tag: "F3", name: "fetch, hexadecimal IP", js: call("fetch", `http://${hex}:${port}/ok?probe=F3`), fails: true },
      { tag: "F4", name: "fetch, IPv4-mapped IPv6", js: call("fetch", `http://[::ffff:${EXT}]:${port}/ok?probe=F4`), fails: true },
      { tag: "F5", name: "fetch, DNS name", js: call("fetch", at("leak.test", "F5")), fails: true },
      { tag: "F6", name: "fetch, https", js: call("fetch", `https://${EXT}:${port}/ok?probe=F6`), fails: true },
      { tag: "F7", name: "fetch, no-cors", js: call("noCors", at(EXT, "F7")), fails: true },
      { tag: "X1", name: "XMLHttpRequest", js: call("xhr", at(EXT, "X1")), fails: true },
      { tag: "W1", name: "WebSocket, IP literal", js: call("webSocket", `ws://${EXT}:${port}/socket?probe=W1`), fails: true },
      { tag: "W2", name: "WebSocket, DNS name", js: call("webSocket", `ws://leak.test:${port}/socket?probe=W2`), fails: true },
      { tag: "E1", name: "EventSource", js: call("eventSource", at(EXT, "E1", "/sse")), fails: true },
      { tag: "S1", name: "img", js: call("element", "img", "src", at(EXT, "S1", "/img.png")), fails: true },
      { tag: "S2", name: "script", js: call("element", "script", "src", at(EXT, "S2", "/worker.js")), fails: true },
      { tag: "S3", name: "stylesheet", js: call("element", "link", "href", at(EXT, "S3", "/style.css")), fails: true },
      { tag: "I1", name: "iframe", js: call("element", "iframe", "src", at(EXT, "I1", "/blank")) },
      { tag: "B1", name: "navigator.sendBeacon", js: call("beacon", at(EXT, "B1")) },
      { tag: "B2", name: "a[ping]", js: call("ping", at(EXT, "B2")), userGesture: true },
      { tag: "K1", name: "a dedicated worker's fetch", js: call("worker", at(EXT, "K1")), fails: true },
      { tag: "K2", name: "a service worker's fetch", js: call("serviceWorker", at(EXT, "K2")), fails: true },
      { tag: "R1", name: "link rel=prefetch", js: call("linkRel", "prefetch", at(EXT, "R1", "/blank")) },
      { tag: "R2", name: "link rel=preconnect", js: call("linkRel", "preconnect", `http://${EXT}:${port}`) },
      { tag: "R3", name: "link rel=dns-prefetch and preconnect, DNS name", js: call("linkRel", "dns-prefetch", `http://www.leak.test:${port}`) + "; " + call("linkRel", "preconnect", `http://www.leak.test:${port}`) },
      { tag: "R4", name: "speculation rules (prerender, prefetch)", js: call("speculation", [at(EXT, "R4", "/blank")]) },
      { tag: "P1", name: "window.open", js: call("open", at(EXT, "P1", "/blank")), userGesture: true },
    ];
    const outcomes = [];
    for (const vector of vectors) {
      const outcome = await settle(probe(vector.js, { userGesture: vector.userGesture }));
      const text = outcome.ok ? String(outcome.value) : `harness: ${outcome.error.message}`;
      outcomes.push(`${vector.tag} ${vector.name}: ${text}`);
      if (vector.fails) assert.doesNotMatch(text, /^(ok|open|load)\b/, `${vector.name} succeeded`);
    }
    // Navigations: Loom's own (Page.navigate) and the page's.
    const errors = new Set();
    for (const [tag, url] of [["N1", at(EXT, "N1", "/blank")], ["N2", `https://${EXT}:${port}/blank?probe=N2`], ["N3", at("leak.test", "N3", "/blank")]]) {
      const reply = await tab.session.send("Page.navigate", { url });
      assert.match(reply.errorText ?? "", /^net::ERR_/, `${tag}: Page.navigate failed`);
      assert.notEqual(reply.errorText, "net::ERR_ABORTED");
      errors.add(reply.errorText);
      outcomes.push(`${tag} Page.navigate: ${reply.errorText}`);
      await tab.navigate(page);
    }
    const committed = tab.session.waitForEvent("Page.frameNavigated", { predicate: ({ frame }) => !frame.parentId, timeout: 10_000 });
    await tab.evaluate(`location.href = ${JSON.stringify(at(EXT, "N4", "/blank"))}`);
    const { frame } = await committed;
    assert.equal(frame.url, "chrome-error://chromewebdata/", "the page's own navigation ends on an error page");
    await tab.navigate(page);
    // WebRTC: the policy leaves no candidate and sends no datagram.
    const before = udp.datagrams.length;
    for (const stun of [`stun:${EXT}:${udp.port}`, `stun:leak.test:${udp.port}`]) {
      const candidates = await probe(call("webrtc", stun));
      outcomes.push(`U WebRTC ${stun}: ${candidates}`);
      assert.equal(candidates, "candidates 0", stun);
    }
    await delay(1500);   // beacons, pings, prefetches and retries are asynchronous
    t.diagnostic(outcomes.join("\n"));
    t.diagnostic(`navigation errors through the fence: ${[...errors].join(", ")}; fence connections so far: ${fence.connections.length}`);
    assert.equal(udp.datagrams.length - before, 0, "UDP datagrams");
    const leaked = server.hits.filter((h) => /probe=/.test(h.query) || h.local === EXT || /leak\.test/.test(h.host || ""));
    assert.deepEqual(leaked.map((h) => `${h.method} ${h.host}${h.path}${h.query} via ${h.local}`), []);
    assert.deepEqual(server.connections.filter((c) => c.local === EXT), [], "no TCP connection on the outside address");
    assert.ok(fence.connections.length > 0, "the vectors met the fence");
    // Popups the probes opened.
    const { targetInfos } = await chrome.conn.send("Target.getTargets");
    for (const info of targetInfos) {
      if (info.type === "page" && info.targetId !== tab.targetId && info.url !== "about:blank") await settle(chrome.conn.send("Target.closeTarget", { targetId: info.targetId }));
    }
  });
});
