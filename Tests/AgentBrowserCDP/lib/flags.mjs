// The agent browser's Chromium launch flags, as data: the one list the Swift
// engine (LoomChromium's ChromiumFlags) must produce. Written out to
// fixtures/flags.json, which the Swift tests read; launch.test.mjs fails when
// the two drift (LOOM_CDP_UPDATE=1 rewrites the file).
//
// Every flag here is one the step-0 probes ran with on Chromium 141, both the
// full browser (--headless=new) and chrome-headless-shell, and that this
// harness runs with on every test: nothing is assumed.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const flagsFixture = resolve(here, "../fixtures/flags.json");

export const FLAGS = Object.freeze({
  $comment: [
    "Chromium launch flags for Loom's agent browser (ADR-0016), produced by Tests/AgentBrowserCDP/lib/flags.mjs.",
    "Launch arguments = base + headless[kind] + userDataDir + (localOnly when the fence is on).",
    "forbidden: never on Loom's command line (a ChromiumFlags test checks it). The Node harness adds",
    "--no-sandbox (Linux CI as root or under AppArmor only) and --no-proxy-server; neither belongs here.",
  ],
  version: 1,
  base: [
    // CDP over fds 3 and 4: no TCP listener (launch.test.mjs).
    "--remote-debugging-pipe",
    "--no-first-run",
    "--no-default-browser-check",
    "--no-service-autorun",
    // The macOS keychain is never touched; cookies are keyed by a constant (ADR-0016).
    "--use-mock-keychain",
    "--password-store=basic",
    // Pages keep running with no viewer (background.test.mjs).
    "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows",
    // Pipelined input and pushState loops are never throttled; no hang dialog.
    "--disable-ipc-flooding-protection",
    "--disable-hang-monitor",
    // A bfcache restore fires no load event: navigate_back would have nothing to settle on.
    "--disable-back-forward-cache",
    // (hover: hover) and (pointer: fine) match, as on a Mac with a mouse (input-click.test.mjs).
    "--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4",
    // innerWidth == clientWidth, as with macOS overlay scrollbars (viewport.test.mjs).
    "--hide-scrollbars",
    "--force-color-profile=srgb",
    "--mute-audio",
    "--deny-permission-prompts",
    // No traffic of Chromium's own (Playwright's set; local-only.test.mjs measures the shell at zero).
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-field-trial-config",
    "--disable-breakpad",
    "--disable-client-side-phishing-detection",
    "--disable-component-extensions-with-background-pages",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-sync",
    "--metrics-recording-only",
    "--disable-search-engine-choice-screen",
    // One --disable-features only: Chromium reads the last one.
    "--disable-features=NetworkTimeServiceQuerying,Translate,OptimizationHints,MediaRouter",
  ],
  headless: {
    // chrome-headless-shell is headless by construction; --headless is accepted and harmless.
    headlessShell: ["--headless"],
    fullBrowser: ["--headless=new"],
  },
  // Followed by the profile directory.
  userDataDir: "--user-data-dir=",
  localOnly: {
    // Followed by the ChromiumFence's port: a Loom-owned 127.0.0.1:0 listener that accepts and
    // closes every connection.
    proxyServer: "--proxy-server=http://127.0.0.1:",
    // Followed by `bypass` (then the person's allowed hosts) joined with ";". <-loopback> drops
    // Chromium's implicit bypass, which sends link-local addresses (169.254.169.254) direct; the
    // loopback names and ranges are then added back one by one. Names are matched as strings,
    // never resolved: a /etc/hosts alias of 127.0.0.1 still meets the fence.
    proxyBypassList: "--proxy-bypass-list=",
    bypass: ["<-loopback>", "localhost", "*.localhost", "127.0.0.0/8", "[::1]", "0.0.0.0"],
    args: [
      "--disable-quic",
      "--dns-prefetch-disable",
      // Both spellings: the full browser honours only the first, the headless shell only the second.
      "--webrtc-ip-handling-policy=disable_non_proxied_udp",
      "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
    ],
  },
  // Matched as a prefix ("--remote-debugging-port" also catches "--remote-debugging-port=0").
  forbidden: [
    "--no-sandbox",
    "--remote-debugging-port",
    "--remote-debugging-address",
    "--enable-automation",
    "--disable-popup-blocking",
    "--disable-web-security",
    "--single-process",
    "--no-zygote",
    "--allow-running-insecure-content",
  ],
});

/** The local-only arguments for a fence on `fencePort`, the person's allowed hosts last. */
export function localOnlyArgs(fencePort, allowedHosts = []) {
  const bypass = [...FLAGS.localOnly.bypass, ...allowedHosts].join(";");
  return [FLAGS.localOnly.proxyServer + fencePort, FLAGS.localOnly.proxyBypassList + bypass, ...FLAGS.localOnly.args];
}

/** Loom's whole command line for a binary kind ("headlessShell" | "fullBrowser"). */
export function canonicalArgs(kind, { userDataDir, fencePort, allowedHosts } = {}) {
  const headless = FLAGS.headless[kind];
  if (!headless) throw new Error(`unknown binary kind ${kind}`);
  return [
    ...FLAGS.base,
    ...headless,
    FLAGS.userDataDir + userDataDir,
    ...(fencePort === undefined ? [] : localOnlyArgs(fencePort, allowedHosts)),
  ];
}

/** The forbidden flags present in `args`. */
export function forbiddenIn(args) {
  return args.filter((arg) => FLAGS.forbidden.some((flag) => arg === flag || arg.startsWith(flag + "=")));
}

/** What fixtures/flags.json holds: the data, plus four whole command lines to compare with. */
export function flagsDocument() {
  const placeholders = { userDataDir: "{userDataDir}" };
  return {
    ...FLAGS,
    examples: {
      "headlessShell.open": canonicalArgs("headlessShell", placeholders),
      "fullBrowser.open": canonicalArgs("fullBrowser", placeholders),
      "headlessShell.localOnly": canonicalArgs("headlessShell", { ...placeholders, fencePort: "{fencePort}", allowedHosts: ["{allowedHosts…}"] }),
      "fullBrowser.localOnly": canonicalArgs("fullBrowser", { ...placeholders, fencePort: "{fencePort}" }),
    },
  };
}

export const renderFlagsDocument = () => JSON.stringify(flagsDocument(), null, 2) + "\n";

export function readFlagsFixture() {
  try { return readFileSync(flagsFixture, "utf8"); } catch { return null; }
}

export function writeFlagsFixture() {
  writeFileSync(flagsFixture, renderFlagsDocument());
}
