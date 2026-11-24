#!/usr/bin/env bash
# Tests os/darwin/hosts-block.sh against sample files in a temp dir; never touches /etc/hosts.
set -u
cd "$(dirname "$0")/.." || exit 1
. os/darwin/hosts-block.sh
B="# >>> offprint: mysite.test >>>"; E="# <<< offprint: mysite.test <<<"
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR), and TMPDIR
# inside it from here on, so nothing the suite runs leaves anything in the real one.
d="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-hosts-block-test.XXXXXX")"; trap 'rm -rf "$d"' EXIT
mkdir "$d/tmpdir"; export TMPDIR="$d/tmpdir"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > "$d/clean"
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n\n%s\n127.0.0.9\tmysite.test\nfd00::9\tmysite.test\n%s\n' "$B" "$E" > "$d/block"
printf '127.0.0.1\tlocalhost\n\n%s\n127.0.0.9\tmysite.test\n10.0.0.1\tother\n' "$B" > "$d/noend"
printf '%s\n%s\n' "$B" "$E" > "$d/nolocalhost"

strip_hosts_block "$d/clean" "$d/out" "$B" "$E" && cmp -s "$d/clean" "$d/out" && ok "clean file passes unchanged" || bad "clean file passes unchanged"
strip_hosts_block "$d/block" "$d/out" "$B" "$E" && cmp -s "$d/clean" "$d/out" && ok "block removed, rest identical" || bad "block removed, rest identical"
rm -f "$d/out"
if strip_hosts_block "$d/noend" "$d/out" "$B" "$E" 2>"$d/err"; then bad "BEGIN without END refused"
elif [ ! -e "$d/out" ] && grep -q refusing "$d/err"; then ok "BEGIN without END refused, no output written"; else bad "BEGIN without END refused"; fi
if strip_hosts_block "$d/nolocalhost" "$d/out" "$B" "$E" 2>/dev/null; then bad "no-localhost result refused"; else ok "no-localhost result refused"; fi
exit "$fail"
