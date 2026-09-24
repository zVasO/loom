// Reads the SDK and the content security policy out of the Swift sources, so
// the JavaScript tests run exactly what Loom injects and sends — no copy to
// drift from.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = resolve(here, "../../..");
export const extensionsRoot = resolve(here, "..");

export function sdkSource() {
  const swift = readFileSync(resolve(repoRoot, "Sources/LoomExtensions/LoomSDKScript.swift"), "utf8");
  const match = /public static let source = #"""\n([\s\S]*?)\n"""#/.exec(swift);
  if (!match) throw new Error("LoomSDKScript.source not found — it must stay a #\"\"\" raw string at column 0");
  return match[1];
}

export function contentSecurityPolicy() {
  const swift = readFileSync(resolve(repoRoot, "Sources/LoomExtensions/ExtensionWebPolicy.swift"), "utf8");
  const block = /contentSecurityPolicy = \[([\s\S]*?)\]\.joined\(separator: "; "\)/.exec(swift);
  if (!block) throw new Error("ExtensionWebPolicy.contentSecurityPolicy not found");
  const parts = [...block[1].matchAll(/"([^"]*)"/g)].map((part) => part[1]);
  return parts.join("; ");
}

/** The document-start script, as BridgeScripts.userScript(boot:) builds it. */
export function userScript(boot) {
  return "window.__loomBoot = " + JSON.stringify(boot) + ";\n" + sdkSource();
}
