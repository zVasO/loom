// A local HTTP server for the fixtures: Tests/AgentBrowserJS/fixtures/todo.html
// (read, never written) and the pages in Tests/AgentBrowserCDP/fixtures/,
// plus the few dynamic answers the tests need. It records every request and
// every connection with the local address it arrived on, which is how
// local-only.test.mjs tells loopback from the outside.
import http from "node:http";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { networkInterfaces } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const here = dirname(fileURLToPath(import.meta.url));
export const cdpFixtures = resolve(here, "../fixtures");
export const jsFixtures = resolve(here, "../../AgentBrowserJS/fixtures");

/** A non-loopback IPv4 address of this machine, or null. */
export function externalIPv4() {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses || []) if (address.family === "IPv4" && !address.internal) return address.address;
  }
  return null;
}

const PNG_1x1 = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
const WORKER = `onmessage = async (event) => {
  try { const response = await fetch(event.data, { cache: "no-store" }); postMessage("ok " + response.status); }
  catch (error) { postMessage("error " + error.message); }
};`;
const SERVICE_WORKER = `self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("message", async (event) => {
  let answer;
  try { const response = await fetch(event.data, { cache: "no-store" }); answer = "ok " + response.status; }
  catch (error) { answer = "error " + error.message; }
  event.source.postMessage(answer);
});`;
const plain = (address) => String(address || "").replace(/^::ffff:/, "");

function fixture(name) {
  // Only plain names, only from the two fixture folders.
  if (!/^[a-z0-9-]+\.html$/.test(name)) return null;
  for (const folder of [cdpFixtures, jsFixtures]) {
    try { return readFileSync(resolve(folder, name)); } catch { /* next */ }
  }
  return null;
}

/**
 * Starts the server on `host` (127.0.0.1 by default; local-only.test.mjs
 * listens on 0.0.0.0 to see what arrives from outside).
 */
export async function startServer({ host = "127.0.0.1" } = {}) {
  const hits = [];
  const connections = [];
  const sockets = new Set();
  const held = new Set();
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://fixture");
    hits.push({
      at: performance.now(), method: request.method, path: url.pathname, query: url.search, host: request.headers.host,
      local: plain(request.socket.localAddress), userAgent: request.headers["user-agent"],
    });
    const send = (status, type, body, headers = {}) => {
      response.writeHead(status, { "content-type": type, "cache-control": "no-store", "access-control-allow-origin": "*", ...headers });
      response.end(body);
    };
    const wait = Number(url.searchParams.get("delay") || 0);
    const answer = () => {
      switch (url.pathname) {
        case "/":
          return send(200, "text/html; charset=utf-8", fixture("todo.html"));
        case "/blank":
          return send(200, "text/html; charset=utf-8", `<!doctype html><meta charset="utf-8"><title>blank</title><p>blank ${url.search.replace(/[<>&]/g, "")}</p>`);
        case "/boot":
          // Logs at document start, before Loom can have re-added its binding.
          return send(200, "text/html; charset=utf-8", `<!doctype html><meta charset="utf-8"><script>console.log("boot" + location.search)</script><title>boot</title><p>boot</p>`);
        case "/ok":
          return send(200, "text/plain", "ok");
        case "/missing.json":
          return send(404, "application/json", '{"error":"missing"}');
        case "/poll": {
          // A long poll: answered after `hold` ms (or when the client goes).
          const hold = Number(url.searchParams.get("hold") || 1000);
          const timer = setTimeout(() => { held.delete(timer); send(200, "application/json", '{"poll":true}'); }, hold);
          held.add(timer);
          request.on("close", () => { clearTimeout(timer); held.delete(timer); });
          return;
        }
        case "/never":
          request.on("close", () => response.destroy());
          return;
        case "/img.png":
          return send(200, "image/png", PNG_1x1);
        case "/worker.js":
          return send(200, "text/javascript", WORKER);
        case "/sw.js":
          return send(200, "text/javascript", SERVICE_WORKER);
        case "/style.css":
          return send(200, "text/css", "p { color: rgb(1, 2, 3); }");
        case "/sse":
          response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store", "access-control-allow-origin": "*" });
          response.write("data: hello\n\n");
          setTimeout(() => response.end(), 200);
          return;
        case "/echo":
          if (request.method === "POST") {
            let body = "";
            request.on("data", (chunk) => { body += chunk; });
            request.on("end", () => send(200, "text/html; charset=utf-8", `<!doctype html><title>posted</title><p id="body">${body.replace(/[<>&]/g, "")}</p>`));
            return;
          }
          return send(200, "text/html; charset=utf-8", `<!doctype html><title>echo</title><p id="query">${url.search.replace(/[<>&]/g, "")}</p>`);
        default: {
          const page = fixture(url.pathname.slice(1));
          return page ? send(200, "text/html; charset=utf-8", page) : send(404, "text/plain", "not found");
        }
      }
    };
    if (wait > 0) setTimeout(answer, wait); else answer();
  });
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    connections.push({ at: performance.now(), local: plain(socket.localAddress), remote: plain(socket.remoteAddress) });
  });
  // The smallest WebSocket handshake: open, then closed by the server.
  server.on("upgrade", (request, socket) => {
    const url = new URL(request.url, "http://fixture");
    hits.push({ at: performance.now(), method: "UPGRADE", path: url.pathname, query: url.search, host: request.headers.host, local: plain(request.socket.localAddress) });
    const accept = createHash("sha1").update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    socket.on("error", () => {});
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    setTimeout(() => socket.destroy(), 300);
  });
  server.on("clientError", (_error, socket) => socket.destroy());
  await new Promise((done, fail) => {
    server.once("error", fail);
    server.listen(0, host, () => { server.off("error", fail); done(); });
  });
  const port = server.address().port;
  return {
    port,
    host,
    hits,
    connections,
    base: `http://127.0.0.1:${port}`,
    url: (path) => `http://127.0.0.1:${port}${path}`,
    close: () => new Promise((done) => {
      for (const timer of held) clearTimeout(timer);
      for (const socket of sockets) socket.destroy();
      server.close(() => done());
    }),
  };
}
