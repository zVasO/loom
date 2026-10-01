// Reads the agent browser's scripts out of the Swift source, so these tests
// run exactly what Loom injects — no copy to drift from (ADR-0014).
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = resolve(here, "../..");
export const fixturesDirectory = resolve(here, "fixtures");

function literal(name) {
  const swift = readFileSync(resolve(repoRoot, "Sources/LoomWeb/AgentBrowser/AgentScripts.swift"), "utf8");
  const match = new RegExp(`public static let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`).exec(swift);
  if (!match) throw new Error(`AgentScripts.${name} not found — it must stay a #""" raw string at column 0`);
  return match[1];
}

export const helperSource = () => literal("helper");
export const pageHookSource = () => literal("pageHook");
export const serializerSource = () => literal("serializer");

/** The helper's pure functions, in a bare context: no DOM needed. */
export function pureHelper() {
  const context = vm.createContext({ WeakRef, WeakMap, Map, Set, JSON, Math, Object, String, Number, Array });
  vm.runInContext(helperSource(), context);
  return context.__loomAgent._pure;
}
