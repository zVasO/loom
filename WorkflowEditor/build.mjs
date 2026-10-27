// Builds the workflow editor into Sources/LoomApp/WorkflowEditor (ADR-0017):
// one script, one stylesheet, the page — versioned, so the app builds with
// no Node. `--check` builds into a temporary folder and fails when the
// versioned bundle differs: CI keeps it in step with the sources.
import { build } from "esbuild";
import { mkdtempSync, readFileSync, copyFileSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const target = join(here, "..", "Sources", "LoomApp", "WorkflowEditor");
const check = process.argv.includes("--check");
const out = check ? mkdtempSync(join(tmpdir(), "loom-editor-")) : target;
mkdirSync(out, { recursive: true });

await build({
  entryPoints: { editor: join(here, "src", "index.jsx") },
  outdir: out,
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari17"],
  jsx: "automatic",
  legalComments: "none",
  define: { "process.env.NODE_ENV": '"production"' },
  loader: { ".js": "jsx" },
  logLevel: "warning",
});
copyFileSync(join(here, "index.html"), join(out, "index.html"));

if (check) {
  let stale = [];
  for (const file of ["index.html", "editor.js", "editor.css"]) {
    const built = readFileSync(join(out, file));
    const versioned = existsSync(join(target, file)) ? readFileSync(join(target, file)) : Buffer.alloc(0);
    if (!built.equals(versioned)) stale.push(file);
  }
  rmSync(out, { recursive: true, force: true });
  if (stale.length) {
    console.error(`The versioned editor is stale (${stale.join(", ")}): run scripts/build-workflow-editor.sh and commit.`);
    process.exit(1);
  }
  console.log("The versioned editor matches its sources.");
}
