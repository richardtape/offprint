#!/usr/bin/env bash
# The script a page with a comment form loads, with the real tools, not stand-ins. Two things the hermetic suites
# can't show:
#   - the two committed scripts (plugin/offprint/pigeonhole.js and pigeonhole-loader.js) are what the sources build:
#     built again here from a clean install of exactly what the lock file pins, and compared byte for byte;
#   - what the committed script encrypts, the real age opens, with either private key and no other, and the Mac's own
#     check (lib/pigeonhole.php) takes what comes out.
# It needs node, npm, age, age-keygen and php, and the network (npm ci fetches the pinned packages, each checked against
# the lock file's hash; no install script of any package is run). So it is never run in CI: run it on the Mac before
# any merge that touches pigeonhole/browser/ or the two built scripts. It touches no site, no Keychain and no host:
# everything is in a temporary folder it removes, and every private key it makes lives in a shell variable only.
#   bash tests/pigeonhole-real.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD"

for tool in node npm age age-keygen php; do
  command -v "$tool" > /dev/null 2>&1 || { echo "$tool isn't installed, so the real pigeonhole checks can't run."; exit 2; }
done

fail=0; passed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/offprint-pigeonhole-real.XXXXXX")"; tmp="$(cd -P "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# ---- built again, from a clean install -----------------------------------------------------------------------------------
mkdir "$tmp/browser" "$tmp/out"
cp -R pigeonhole/browser/package.json pigeonhole/browser/package-lock.json pigeonhole/browser/build.sh pigeonhole/browser/src "$tmp/browser/"
if ( cd "$tmp/browser" && npm ci --ignore-scripts --no-audit --no-fund > "$tmp/npm.out" 2>&1 ); then ok "the pinned packages install, with no install script run"
else bad "npm ci failed: $(tail -n 3 "$tmp/npm.out" | tr '\n' ' ')"; fi
check "the lock file is as committed after the install" "" "$(cmp "$tmp/browser/package-lock.json" pigeonhole/browser/package-lock.json 2>&1)"
if ( cd "$tmp/browser" && ./build.sh "$tmp/out" > "$tmp/build.out" 2>&1 ); then ok "the two scripts build"
else bad "the build failed: $(tail -n 3 "$tmp/build.out" | tr '\n' ' ')"; fi
for f in pigeonhole.js pigeonhole-loader.js; do
  if cmp -s "$tmp/out/$f" "plugin/offprint/$f"; then ok "plugin/offprint/$f is, byte for byte, what the sources build"
  else bad "plugin/offprint/$f is not what the sources build: run pigeonhole/browser/build.sh, read what changed, and commit it with its new hash (tests/pigeonhole-browser.test.js)"; fi
done

# ---- what the committed script encrypts, the real age opens ----------------------------------------------------------------
new_identity() { age-keygen 2> /dev/null | grep '^AGE-SECRET-KEY-'; }
daily="$(new_identity)";    daily_pub="$(printf '%s\n' "$daily" | age-keygen -y)"
recovery="$(new_identity)"; recovery_pub="$(printf '%s\n' "$recovery" | age-keygen -y)"
stranger="$(new_identity)"

cp plugin/offprint/pigeonhole.js "$tmp/pigeonhole.mjs"
# seal OUT RECIPIENT...: a comment, built and padded by the sources and encrypted by the committed script; the posted
# body (the proof of work's nonce, then the ciphertext) in OUT.body, the ciphertext alone in OUT.age
seal() {
  local out="$1"; shift
  OUT="$out" BUILT="$tmp/pigeonhole.mjs" SRC="$SRC" node --input-type=module -e '
    import fs from "node:fs";
    const { seal } = await import(process.env.BUILT);
    const t = await import(process.env.SRC + "/pigeonhole/browser/src/transport.js");
    const { fields } = t.commentFields({ comment_post_ID: "4", comment_parent: "0", author: "Zoë", email: "zoe@example.com", url: "",
      comment: "MARKER-REAL a comment — with ünïcode & <b>markup</b>\nand a second line", offprint_hp: "" }, 42);
    const sealed = await seal(t.padded(t.envelope("comment", fields, { page: "/hello/" })), process.argv.slice(1));
    fs.writeFileSync(process.env.OUT + ".age", sealed);
    fs.writeFileSync(process.env.OUT + ".body", await t.body(sealed, 12));' "$@"
}
# opened KEY FILE: what the real age makes of FILE with KEY (on a pipe), through the Mac's own check
opened() { printf '%s\n' "$1" | age -d -i - "$2" 2> /dev/null | php "$SRC/lib/pigeonhole.php" check 2> "$tmp/why"; }

seal "$tmp/one" "$daily_pub" || bad "the committed script could not encrypt to one key"
seal "$tmp/two" "$daily_pub" "$recovery_pub" || bad "the committed script could not encrypt to two keys"
check "to one key, the ciphertext is the size the pigeonhole takes for one" 8392 "$(wc -c < "$tmp/one.age" | tr -d ' ')"
check "to two keys, the size it takes for two" 8490 "$(wc -c < "$tmp/two.age" | tr -d ' ')"
check "what is posted is 8 bytes more: the proof of work" 8498 "$(wc -c < "$tmp/two.body" | tr -d ' ')"
out="$(opened "$daily" "$tmp/one.age")"; rc=$?
check "to one key: the real age opens it, and the Mac's check takes it" 0 "$rc"
check "... the comment, whole" 1 "$(printf '%s' "$out" | grep -c 'MARKER-REAL a comment — with ünïcode & <b>markup</b>\\nand a second line')"
check "to two keys: the daily key opens it" 1 "$(opened "$daily" "$tmp/two.age" | grep -c MARKER-REAL)"
check "to two keys: the recovery key opens it" 1 "$(opened "$recovery" "$tmp/two.age" | grep -c MARKER-REAL)"
check "a key that is neither opens nothing" 0 "$(opened "$stranger" "$tmp/two.age" | grep -c MARKER-REAL)"
check "... and the recovery key doesn't open what was encrypted to the daily one alone" 0 "$(opened "$recovery" "$tmp/one.age" | grep -c MARKER-REAL)"
check "nothing readable is in what is posted" 0 "$(grep -c 'MARKER-REAL\|zoe@example.com' "$tmp/two.body")"
check "no private key is in any file" "" "$(grep -rl 'AGE-SECRET-KEY-' "$tmp" --exclude-dir=node_modules 2> /dev/null)"

echo "$passed ok"
[ "$fail" -eq 0 ]
