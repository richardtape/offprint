#!/usr/bin/env bash
# offprint collect with the real age, not a stand-in: what bin/collect assumes of it (the key on a pipe, the file
# named, a wrong key or a damaged file refused). It needs age and age-keygen on the PATH (brew install age) and is
# never run in CI: run it on the Mac before any merge that touches bin/collect. It touches no site, no Keychain, no
# Docker and no host: a throwaway site folder and Offprint folder in a temporary folder it removes, a stand-in docker
# (WordPress's answers) and a stand-in security (the Keychain), which prints the key it is given in its environment.
# Every private key it makes lives in a shell variable and in that environment only, never in a file.
#   bash tests/collect-real.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD"
unset OFFPRINT_SITE OFFPRINT_HOME OFFPRINT_SECURITY

for tool in age age-keygen php; do
  command -v "$tool" > /dev/null 2>&1 || { echo "$tool isn't installed, so the real collect checks can't run."; exit 2; }
done

fail=0; passed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/offprint-collect-real.XXXXXX")"; tmp="$(cd -P "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"

new_identity() { age-keygen 2> /dev/null | grep '^AGE-SECRET-KEY-'; }
daily="$(new_identity)";    daily_pub="$(printf '%s\n' "$daily" | age-keygen -y)"
recovery="$(new_identity)"; recovery_pub="$(printf '%s\n' "$recovery" | age-keygen -y)"
stranger="$(new_identity)"

c="$tmp/site"; S="$tmp/stubs"; H="$tmp/ohome"; SP="$H/pigeonhole/example/spool"; B="$H/pigeonhole/example"
mkdir -p "$c/var" "$c/wp-content" "$S/bin" "$tmp/home" "$SP"; chmod 700 "$H/pigeonhole" "$B" "$SP"
printf '%s\n' '{"format":1,"name":"example","public_url":"https://www.example.com","local_host":"mysite.test","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998,' \
  "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$daily_pub\",\"$recovery_pub\"]}}" > "$c/site.json"
cat > "$S/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = compose ] || exit 0
case "$*" in
  *" ps "*) printf 'wordpress\ndb\n'; exit 0 ;;
  *" wp offprint import-submission "*) cat >> "$STUB_DIR/imported"; echo "imported 1 hold"; exit 0 ;;
esac
exit 99
STUB
cat > "$S/security" <<'STUB'
#!/bin/bash
[ "$*" = "find-generic-password -s offprint -a example/pigeonhole-daily -w" ] || exit 2
printf '%s\n' "$REAL_KEY"
STUB
chmod +x "$S/bin/docker" "$S/security"

N=0
# plain TEXT: an opened comment, padded as the browser pads it, in $tmp/plain
plain() {
  N=$((N + 1))
  N="$N" php -r 'require $argv[1];
    $d = ["v" => 1, "kind" => "comment", "id" => sprintf("%032x", (int) getenv("N")), "ts" => time() - 60, "page" => "/hello/",
      "fields" => ["post_id" => 4, "parent" => 0, "author" => "Zoë", "email" => "zoe@example.com", "url" => "", "content" => $argv[2], "hp" => "", "elapsed" => 42]];
    echo str_pad(offprint_pigeonhole_line($d), 8192, " ");' "$SRC/lib/pigeonhole.php" "$1" > "$tmp/plain"
}
# into_spool FILE: FILE into the spool, under the name its bytes give it
into_spool() { mv "$1" "$SP/$(php -r 'echo hash_file("sha256", $argv[1]);' "$1").age"; }
# collect KEY: offprint collect, the Keychain holding KEY; sets out, code
collect() {
  : > "$S/imported"
  out="$(cd "$tmp" && REAL_KEY="$1" PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" \
    HOME="$tmp/home" /bin/bash "$SRC/bin/offprint" collect 2>&1 < /dev/null)"; code=$?
}
count() { ls "$1" 2> /dev/null | grep -c .; }

plain "MARKER-ONE a comment — with ünïcode & <b>markup</b>"
age -r "$daily_pub" -o "$tmp/one.age" "$tmp/plain"; into_spool "$tmp/one.age"
collect "$daily"; t="encrypted to the daily key alone"
check "$t: exits 0" 0 "$code"
check "$t: says where it is" "ok: 1 comment is waiting for you in WordPress's moderation queue." "$out"
check "$t: WordPress was handed the comment, whole" 1 "$(grep -c 'MARKER-ONE a comment — with ünïcode & <b>markup</b>' "$S/imported")"

plain "MARKER-TWO a comment"
age -r "$daily_pub" -r "$recovery_pub" -o "$tmp/two.age" "$tmp/plain"; cp "$tmp/two.age" "$tmp/two-again.age"; cp "$tmp/two.age" "$tmp/two-stranger.age"
into_spool "$tmp/two.age"
collect "$daily"; t="encrypted to both keys, opened with the daily one"
check "$t: exits 0" 0 "$code"
check "$t: WordPress was handed it" 1 "$(grep -c MARKER-TWO "$S/imported")"
into_spool "$tmp/two-again.age"
collect "$recovery"; t="... opened with the recovery one"
check "$t: exits 0" 0 "$code"
check "$t: WordPress was handed it" 1 "$(grep -c MARKER-TWO "$S/imported")"

into_spool "$tmp/two-stranger.age"; before="$(count "$B/rejected")"
collect "$stranger"; t="a key that is neither"
check "$t: exits 0: it is refused, and kept" 0 "$code"
check "$t: WordPress was handed nothing" 0 "$(grep -c . "$S/imported")"
check "$t: it is in rejected, with its reason" "it does not open with this site's daily key" "$(cat "$B"/rejected/*.why | tail -n 1)"
check "$t: two more files in rejected (it, and why)" "$((before + 2))" "$(count "$B/rejected")"

plain "MARKER-CUT a comment"
age -r "$daily_pub" -o "$tmp/whole.age" "$tmp/plain"
head -c 4000 "$tmp/whole.age" > "$tmp/cut.age"; into_spool "$tmp/cut.age"
collect "$daily"; t="a file cut short (and named for what is left)"
check "$t: exits 0: it is refused, and kept" 0 "$code"
check "$t: WordPress was handed nothing" 0 "$(grep -c . "$S/imported")"
check "$t: its reason" "it does not open with this site's daily key" "$(cat "$B"/rejected/*.why | sort -u | tail -n 1)"

php -r '$b = file_get_contents($argv[1]); $i = strlen($b) - 100; $b[$i] = chr(ord($b[$i]) ^ 1); file_put_contents($argv[2], $b);' "$tmp/whole.age" "$tmp/flipped.age"
into_spool "$tmp/flipped.age"
collect "$daily"; t="a file with one bit changed (and named for what it is now)"
check "$t: exits 0: it is refused, and kept" 0 "$code"
check "$t: WordPress was handed nothing: not one byte of a file that doesn't authenticate" 0 "$(grep -c . "$S/imported")"

into_spool "$tmp/whole.age"
collect "$daily"; t="the same file, whole"
check "$t: exits 0" 0 "$code"
check "$t: WordPress was handed it" 1 "$(grep -c MARKER-CUT "$S/imported")"

check "no private key is in any file" "" "$(grep -rl 'AGE-SECRET-KEY-' "$tmp" 2> /dev/null)"
check "nothing is left in the spool" 0 "$(count "$SP")"

echo "$passed ok"
[ "$fail" -eq 0 ]
