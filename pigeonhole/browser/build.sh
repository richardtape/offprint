#!/bin/bash
# Builds the two scripts a page with a comment form loads, into plugin/offprint/, from src/ and the packages the lock
# file pins. Run it here after `npm ci --ignore-scripts`, and commit what it writes: a site is published with the
# committed scripts, never with ones built at the time, and tests/pigeonhole-browser.test.js holds their hashes.
#   pigeonhole.js         src/main.js and all it imports (the age library among it), one file
#   pigeonhole-loader.js  src/loader.js alone: it loads the other, by name, when a visitor first touches the form
# tests/pigeonhole-real.sh builds them again from a clean install and compares.
set -eu
cd "$(dirname "$0")"
out="${1:-../../plugin/offprint}"
esbuild=node_modules/.bin/esbuild
[ -x "$esbuild" ] || { echo "no esbuild here: run npm ci --ignore-scripts first" >&2; exit 1; }
"$esbuild" src/main.js --bundle --format=esm --minify --target=es2022 --legal-comments=none --log-level=warning --outfile="$out/pigeonhole.js"
"$esbuild" src/loader.js --format=esm --minify --target=es2022 --legal-comments=none --log-level=warning --outfile="$out/pigeonhole-loader.js"
