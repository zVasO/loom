#!/bin/sh
# Rebuilds the workflow editor (ADR-0017) into Sources/LoomApp/WorkflowEditor.
# The bundle is versioned: the app builds without Node. Run this after
# editing WorkflowEditor/src, then commit the bundle. `--check` only verifies
# the versioned bundle matches the sources (what CI runs).
set -eu
cd "$(dirname "$0")/../WorkflowEditor"
npm ci --no-audit --no-fund >/dev/null
node build.mjs "$@"
