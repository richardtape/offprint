#!/usr/bin/env bash
# Tests bin/backup (offprint backup verify): that the committed database backup opens with the key the owner gives,
# and is a whole dump. Hermetic: a throwaway site folder (tests/fixtures/site.json, its own git repository, a committed
# backup/db.sql.age) and the suites' stand-in age (tests/fixtures/age-standin) first on the PATH. The key is always
# given on standard input, and is never the real thing: AGE-SECRET-KEY-1TEST is what the stand-in accepts.
# Run: bash tests/backup.test.sh. Works on macOS (bash 3.2) and Linux. tests/backup-real.sh does it with the real age.
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-backup-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' is in the output)"; else ok "$1"; fi; }

KEY=AGE-SECRET-KEY-1TEST
dump_whole() { printf -- '-- MariaDB dump\nCREATE TABLE t (a int);\nINSERT INTO t VALUES (1);\n\n-- Dump completed\n'; }
# sealed: what the stand-in age writes for the dump on standard input
sealed() { echo "age-encryption.org/v1"; echo "-> stand-in"; echo "--- run 1"; cat; }

n=0
# newcase: a site folder $c with a whole, "encrypted" backup committed, and the stand-ins in $S
newcase() {
  n=$((n + 1)); c="$tmp/case$n/site"; S="$tmp/case$n/stubs"
  mkdir -p "$c/backup" "$c/wp-content" "$c/var" "$S/bin"
  cp "$SRC/tests/fixtures/site.json" "$c/site.json"; cp "$SRC/templates/site.gitignore" "$c/.gitignore"
  cp "$SRC/tests/fixtures/age-standin" "$S/bin/age"; chmod +x "$S/bin/age"
  dump_whole | sealed > "$c/backup/db.sql.age"
  git init -q -b main "$c"; git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
  git -C "$c" add -A; git -C "$c" commit -q -m initial
  short="$(git -C "$c" rev-parse --short HEAD)"
}
# verify [ARGS...]: offprint backup ARGS (verify by default) for the site, the key in $key on standard input; sets out, code
key="$KEY"
verify() {
  [ $# -gt 0 ] || set -- verify
  out="$(cd "$tmp/case$n" && printf '%s\n' "$key" | PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup "$@" 2>&1)"; code=$?
}
# untouched NAME: the command changed nothing in the site folder, and the key is in no file of the case's
untouched() {
  check "$1: nothing in the site folder changed" "" "$(git -C "$c" status --porcelain --ignored)"
  check "$1: the key is in no file (but the stand-in, which knows it)" "" "$(grep -rl "$KEY" "$tmp/case$n" "$TMPDIR" 2>/dev/null | grep -v '/stubs/bin/age$')"
}

newcase; verify; t="a whole backup and the right key"
check "$t: exits 0" 0 "$code"
check "$t: says so, naming the commit" "ok: backup/db.sql.age (commit $short) opens with this key and is a whole database dump." "$out"
check "$t: age was given the key on standard input, and the committed file" "-d -i - $(cd "$c" && pwd -P)/backup/db.sql.age (a key of ${#KEY} characters on standard input)" "$(cat "$S/age.calls")"
lacks "$t: the key is not in the output" "$KEY" "$out"; untouched "$t"
check "$t: nothing of the dump is printed" 0 "$(printf '%s' "$out" | grep -c 'INSERT INTO')"

# A variable of the name the script uses, already exported in the owner's shell: the key read into it must not be
# exported with it, into age's environment (or any child's).
newcase; t="a variable named key already exported"
out="$(cd "$tmp/case$n" && printf '%s\n' "$KEY" | env key=old rc=old PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup verify 2>&1)"; code=$?
check "$t: exits 0" 0 "$code"; check "$t: the key is not in age's environment" no "$(cat "$S/age.env" 2>/dev/null)"; untouched "$t"

# The key must not be traced: by a bash -x the owner runs it under, or by tracing inherited from the environment.
newcase; t="run under bash -x"
out="$(cd "$tmp/case$n" && printf '%s\n' "$KEY" | PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash -x "$SRC/bin/backup" verify 2>&1)"; code=$?
check "$t: exits 0" 0 "$code"; lacks "$t: the key is not in the trace" "$KEY" "$out"; untouched "$t"
newcase; t="tracing inherited (SHELLOPTS=xtrace)"
out="$(cd "$tmp/case$n" && printf '%s\n' "$KEY" | env SHELLOPTS=xtrace PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup verify 2>&1)"; code=$?
check "$t: exits 0" 0 "$code"; lacks "$t: the key is not in the trace" "$KEY" "$out"; untouched "$t"
check "control ($t): the run was traced" yes "$(printf '%s' "$out" | grep -q '^+' && echo yes || echo no)"

newcase; key=AGE-SECRET-KEY-1WRONG verify; t="a wrong key"
check "$t: exits 1" 1 "$code"; check "$t: says so" "problem: that key doesn't open backup/db.sql.age. Nothing was changed." "$out"
lacks "$t: the key given is not repeated" "AGE-SECRET-KEY-1WRONG" "$out"; untouched "$t"

newcase; key="" verify; t="an empty line for the key"
check "$t: exits 1" 1 "$code"; check "$t: says so" "problem: no key was given." "$out"
check "$t: age never ran" no "$([ -e "$S/age.calls" ] && echo yes || echo no)"; untouched "$t"

newcase; printf -- '-- MariaDB dump\nINSERT INTO t VALUES (1);\n' | sealed > "$c/backup/db.sql.age"; git -C "$c" commit -q -am truncated; verify; t="a backup that opens, but is not a whole dump"
check "$t: exits 1" 1 "$code"
check "$t: says so" 'problem: backup/db.sql.age opens, but what is in it is not a whole database dump (its last line is not "-- Dump completed"). Publish again, and verify again.' "$out"
untouched "$t"

newcase; git -C "$c" rm -q backup/db.sql.age; git -C "$c" commit -q -m "no backup"; verify; t="no backup in the last commit"
check "$t: exits 1" 1 "$code"; check "$t: says so" "problem: this site's last commit has no backup/db.sql.age. Publish first." "$out"
check "$t: age never ran" no "$([ -e "$S/age.calls" ] && echo yes || echo no)"

newcase; echo scribble >> "$c/backup/db.sql.age"; verify; t="the file in the folder is not the commit's"
check "$t: exits 1" 1 "$code"
check "$t: says so" "problem: backup/db.sql.age in this folder is not the one in the last commit; publish, or restore it with git, then verify again." "$out"
check "$t: age never ran" no "$([ -e "$S/age.calls" ] && echo yes || echo no)"
newcase; rm "$c/backup/db.sql.age"; verify; t="the file is missing from the folder"
check "$t: exits 1" 1 "$code"
check "$t: says so" "problem: backup/db.sql.age in this folder is not the one in the last commit; publish, or restore it with git, then verify again." "$out"
# A link at its name is never read through (it could lead anywhere), whatever it leads to.
newcase; cp "$c/backup/db.sql.age" "$tmp/case$n/elsewhere.age"; rm "$c/backup/db.sql.age"; ln -s "$tmp/case$n/elsewhere.age" "$c/backup/db.sql.age"; verify; t="the file in the folder is a link to a copy of itself"
check "$t: exits 1" 1 "$code"; check "$t: age never ran" no "$([ -e "$S/age.calls" ] && echo yes || echo no)"

# No age on the PATH. no_age_path: the PATH, each folder that holds an age replaced by a folder of links to the rest.
no_age_path() {
  local rest="$PATH:" e out="" d i=0 f
  while [ -n "$rest" ]; do
    e="${rest%%:*}"; rest="${rest#*:}"
    if [ -n "$e" ] && [ -x "$e/age" ]; then
      i=$((i + 1)); d="$tmp/case$n/noage$i"; mkdir -p "$d"
      for f in "$e"/*; do case "${f##*/}" in age | age-keygen) ;; *) ln -s "$f" "$d/${f##*/}" 2>/dev/null ;; esac; done
      e="$d"
    fi
    out="${out:+$out:}$e"
  done
  printf '%s' "$out"
}
newcase; rm "$S/bin/age"; PATH="$(no_age_path)" verify; t="no age on the PATH"
check "$t: exits 1" 1 "$code"; check "$t: says what to install" "problem: age isn't installed; install it (brew install age) and verify again." "$out"

newcase
verify; code0=$code
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup 2>&1 < /dev/null)"; code=$?; t="offprint backup, alone"
check "$t: exits 2" 2 "$code"; check "$t: usage" "usage: offprint backup verify" "$out"
verify restore; t="offprint backup restore"
check "$t: exits 2" 2 "$code"; check "$t: usage" "usage: offprint backup verify" "$out"
verify verify now; t="offprint backup verify now"
check "$t: exits 2" 2 "$code"; check "$t: usage" "usage: offprint backup verify" "$out"

# Run from wp-content/, with . on the PATH and an age planted there: WordPress's is never run (lib/site.sh leaves the
# relative entry out), and the real stand-in, further along, is.
newcase; printf '#!/bin/sh\necho planted > "%s/planted.ran"\n' "$tmp/case$n" > "$c/wp-content/age"; chmod +x "$c/wp-content/age"
git -C "$c" add -A; git -C "$c" commit -q -m planted; short="$(git -C "$c" rev-parse --short HEAD)"
out="$(cd "$c/wp-content" && printf '%s\n' "$KEY" | PATH=".:$S/bin:$PATH" STUB_DIR="$S" /bin/bash "$SRC/bin/offprint" backup verify 2>&1)"; code=$?; t="an age planted in wp-content/, with . on the PATH"
check "$t: exits 0" 0 "$code"; check "$t: the planted one never ran" no "$([ -e "$tmp/case$n/planted.ran" ] && echo yes || echo no)"
check "$t: the one outside the site did" 1 "$(wc -l < "$S/age.calls" | tr -d ' ')"

# Not in a site folder at all.
out="$(cd "$tmp" && printf '%s\n' "$KEY" | env -u OFFPRINT_SITE PATH="$S/bin:$PATH" /bin/bash "$SRC/bin/offprint" backup verify 2>&1)"; code=$?; t="outside every site folder"
check "$t: exits 2" 2 "$code"; check "$t: says so" "Not in an Offprint site folder (no site.json here or above); cd into one, or set OFFPRINT_SITE." "$out"

# A site folder that isn't a git repository has no commit to look in.
newcase; rm -rf "$c/.git"; verify; t="a site folder that isn't a git repository"
check "$t: exits 1" 1 "$code"; check "$t: says so" "problem: this site's last commit has no backup/db.sql.age. Publish first." "$out"

[ "$fail" -eq 0 ]
