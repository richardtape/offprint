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
  # docker, for restore: it notes each call. Not compose: the questions lib/site.sh asks about the project (nothing
  # there). compose: WordPress and the database are running (wp_down: nothing is); mariadb-dump prints current_dump
  # (dump_fails: fails); the database's own count of its tables is 12 (db_empty: 0; count_fails: it fails;
  # count_blank: it says nothing; count_odd: it says something that is no number); "wp db reset" and "wp db import" end as
  # reset_exit and import_exit say (0), the import keeping what it was given in imported.sql; "wp option get home"
  # prints home_before (options_fail: fails); "wp option update" succeeds.
  cat > "$S/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.calls"
[ "${1:-}" = compose ] || exit 0
case "$*" in
  *" ps "*) [ -f "$STUB_DIR/wp_down" ] || printf 'wordpress\ndb\n'; exit 0 ;;
  *mariadb-dump*) [ ! -f "$STUB_DIR/dump_fails" ] || exit 1; cat "$STUB_DIR/current_dump"; exit 0 ;;
  *information_schema*)
    [ ! -f "$STUB_DIR/count_fails" ] || { echo "ERROR 2002 (HY000): Can't connect" >&2; exit 1; }
    [ ! -f "$STUB_DIR/count_blank" ] || exit 0
    [ ! -f "$STUB_DIR/count_odd" ] || { echo "0 rows"; exit 0; }
    if [ -f "$STUB_DIR/db_empty" ]; then echo 0; else echo 12; fi; exit 0 ;;
  *" wp db reset "*) exit "$(cat "$STUB_DIR/reset_exit" 2>/dev/null || echo 0)" ;;
  *" wp db import "*) cat > "$STUB_DIR/imported.sql"; exit "$(cat "$STUB_DIR/import_exit" 2>/dev/null || echo 0)" ;;
  *" wp option get home"*) [ ! -f "$STUB_DIR/options_fail" ] || exit 1; cat "$STUB_DIR/home_before" 2>/dev/null || echo "https://mysite.test"; exit 0 ;;
  *" wp option update "*) exit 0 ;;
esac
echo "unexpected docker call: $*" >&2; exit 99
STUB
  chmod +x "$S/bin/docker"; mkdir -p "$tmp/case$n/home"
  printf -- '-- MariaDB dump\nINSERT INTO t VALUES ("CURRENT");\n\n-- Dump completed\n' > "$S/current_dump"
  dump_whole | sealed > "$c/backup/db.sql.age"
  git init -q -b main "$c"; git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
  git -C "$c" add -A; git -C "$c" commit -q -m initial
  short="$(git -C "$c" rev-parse --short HEAD)"
}
# verify [ARGS...]: offprint backup ARGS (verify by default) for the site, the key in $key on standard input; sets out, code
key="$KEY"
verify() {
  [ $# -gt 0 ] || set -- verify
  out="$(cd "$tmp/case$n" && { printf '%s\n' "$key" 2> /dev/null || true; } | PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup "$@" 2>&1)"; code=$?
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
check "control ($t): the run was traced" yes "$(printf '%s' "$out" | grep -c '^+' | grep -qvx 0 && echo yes || echo no)"

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

usage="usage: offprint backup verify | restore [--from FILE] [--unchecked] [--yes]"
newcase
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup 2>&1 < /dev/null)"; code=$?; t="offprint backup, alone"
check "$t: exits 2" 2 "$code"; check "$t: usage" "$usage" "$out"
verify frobnicate; t="offprint backup frobnicate"
check "$t: exits 2" 2 "$code"; check "$t: usage" "$usage" "$out"
verify verify now; t="offprint backup verify now"
check "$t: exits 2" 2 "$code"; check "$t: usage" "$usage" "$out"

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


# ---- offprint backup restore ---------------------------------------------------------------------------------------
# restore [ARGS...]: offprint backup restore ARGS for the site, the key in $key on standard input (not a terminal, so
# every case here says --yes or is refused for want of it); sets out, code
restore() {
  out="$(cd "$tmp/case$n" && { printf '%s\n' "$key" 2> /dev/null || true; } | HOME="$tmp/case$n/home" PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup restore "$@" 2>&1)"; code=$?
}
did() { grep -oE 'mariadb-dump|information_schema|wp db reset|wp db import|wp option get home|wp option update (home|siteurl)' "$S/docker.calls" 2>/dev/null | paste -sd'|' -; }
kept() { ls "$c/var/before-restore" 2>/dev/null | paste -sd' ' -; }
nothing_replaced() { check "$1: the database was not touched" "" "$(did | grep -oE 'wp db reset|wp db import' | paste -sd'|' -)"; check "$1: no lock is left" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"; }
Q62="age1$(printf 'q%.0s' $(seq 1 58))"
all_steps='information_schema|mariadb-dump|wp db reset|wp db import|wp option get home|wp option update home|wp option update siteurl'

newcase; restore --yes; t="restore, the committed backup"; kept1="$(kept)"
check "$t: exits 0" 0 "$code"
check "$t: says what it did, and where the one before is" "ok: example's database is now backup/db.sql.age (commit $short)'s. The one before is var/before-restore/$kept1." "$out"
check "$t: kept, then reset, imported, and made reachable, in that order" "$all_steps" "$(did)"
check "$t: what was imported is the backup's dump, byte for byte" "$(dump_whole)" "$(cat "$S/imported.sql")"
check "$t: one kept copy, named by the time" yes "$(printf '%s' "$kept1" | grep -Eq '^[0-9]{8}-[0-9]{6}\.sql\.age$' && echo yes)"
check "$t: the kept copy is the database as it was, encrypted to site.json's recipient" "-> stand-in $Q62|1" "$(sed -n 2p "$c/var/before-restore/$kept1")|$(grep -c CURRENT "$c/var/before-restore/$kept1")"
check "$t: var/before-restore is the owner's alone" 700 "$(stat -c %a "$c/var/before-restore" 2>/dev/null || stat -f %Lp "$c/var/before-restore")"
check "$t: home and siteurl are set to the site's local address" 2 "$(grep -c 'wp option update .* https://mysite.test' "$S/docker.calls")"
check "$t: every WP-CLI call loads no plugin and no theme" 0 "$(grep ' wp ' "$S/docker.calls" | grep -vc -- '--skip-plugins --skip-themes')"
check "$t: the key was given to age on standard input, never in its environment" no "$(cat "$S/age.env")"
check "$t: no lock is left" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"
lacks "$t: the key is not in the output" "$KEY" "$out"
check "$t: the key is in no file" "" "$(grep -rl "$KEY" "$tmp/case$n" "$TMPDIR" 2>/dev/null | grep -v '/stubs/bin/age$')"
check "$t: no readable dump was written anywhere but the stand-ins' notes" "" "$(grep -rl 'INSERT INTO' "$c" "$TMPDIR" 2>/dev/null | grep -v '\.age$')"
check "$t: the site's committed files are as they were" "" "$(git -C "$c" status --porcelain)"

# Tracing, and a variable of the script's name already exported: the key stays out of both.
newcase; t="restore under bash -x"
out="$(cd "$tmp/case$n" && printf '%s\n' "$KEY" | HOME="$tmp/case$n/home" PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash -x "$SRC/bin/backup" restore --yes 2>&1)"; code=$?
check "$t: exits 0" 0 "$code"; lacks "$t: the key is not in the trace" "$KEY" "$out"
newcase; t="restore, tracing inherited and a variable named key exported"
out="$(cd "$tmp/case$n" && printf '%s\n' "$KEY" | env SHELLOPTS=xtrace key=old HOME="$tmp/case$n/home" PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup restore --yes 2>&1)"; code=$?
check "$t: exits 0" 0 "$code"; lacks "$t: the key is not in the trace" "$KEY" "$out"; check "$t: nor in age's environment" no "$(cat "$S/age.env")"

# A readable dump the owner names (how a database comes in from another WordPress).
newcase; dump_whole | sed 's/VALUES (1)/VALUES (7)/' > "$tmp/case$n/theirs.sql"; key="" restore --from "$tmp/case$n/theirs.sql" --yes; t="restore --from a readable dump"
check "$t: exits 0" 0 "$code"; check "$t: imported byte for byte" same "$(cmp -s "$tmp/case$n/theirs.sql" "$S/imported.sql" && echo same)"
check "$t: the same steps" "$all_steps" "$(did)"; check "$t: age only encrypted the kept copy" 1 "$(wc -l < "$S/age.calls" | tr -d ' ')"
check "$t: says what it did" "ok: example's database is now $tmp/case$n/theirs.sql's. The one before is var/before-restore/$(kept)." "$out"
newcase; dump_whole > "$tmp/case$n/rel.sql"; out="$(cd "$tmp/case$n" && HOME="$tmp/case$n/home" PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" backup restore --from rel.sql --yes 2>&1 < /dev/null)"; code=$?; t="restore --from a path relative to where it was run"
check "$t: exits 0" 0 "$code"; check "$t: imported" same "$(cmp -s "$tmp/case$n/rel.sql" "$S/imported.sql" && echo same)"
newcase; { dump_whole | sed '$d'; echo "-- Dump completed on 2026-11-26 10:00:00"; } > "$tmp/case$n/dated.sql"; key="" restore --from "$tmp/case$n/dated.sql" --yes; t="restore --from a dump whose last line has a date (another tool's)"
check "$t: exits 0" 0 "$code"
newcase; printf 'CREATE TABLE t (a int);\n' > "$tmp/case$n/cut.sql"; key="" restore --from "$tmp/case$n/cut.sql" --yes; t="restore --from a dump with no last line"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
check "$t: says so, and how to take it anyway" "problem: $tmp/case$n/cut.sql doesn't end as a database dump does (\"-- Dump completed\"). If it is a whole export from another tool, say --unchecked. Nothing was restored." "$out"
check "$t: nothing was kept either" "" "$(kept)"
key="" restore --from "$tmp/case$n/cut.sql" --unchecked --yes; t="the same, --unchecked"
check "$t: exits 0" 0 "$code"; check "$t: imported" same "$(cmp -s "$tmp/case$n/cut.sql" "$S/imported.sql" && echo same)"
case "$out" in *"(not checked to be a whole dump: --unchecked)"*) ok "$t: says it was not checked" ;; *) bad "$t: says it was not checked ($out)" ;; esac
# An encrypted file the owner names (a copy of an earlier commit's backup, say).
newcase; cp "$c/backup/db.sql.age" "$tmp/case$n/earlier.age"; restore --from "$tmp/case$n/earlier.age" --yes; t="restore --from an encrypted file"
check "$t: exits 0" 0 "$code"; check "$t: imported, decrypted" "$(dump_whole)" "$(cat "$S/imported.sql")"
restore --from "$tmp/case$n/earlier.age" --unchecked --yes; t="--unchecked with an encrypted file"
check "$t: exits 2" 2 "$code"; check "$t: usage" "$usage" "$out"

# The kept copies. Restoring from one must not destroy it: each restore writes a new file and never writes over one.
newcase; restore --yes; first="$(kept)"; before="$(cat "$c/var/before-restore/$first")"; : > "$S/docker.calls"
printf -- '-- MariaDB dump\nINSERT INTO t VALUES ("RESTORED");\n\n-- Dump completed\n' > "$S/current_dump"
sleep 1; restore --from "$c/var/before-restore/$first" --yes; t="restore --from a kept copy"
check "$t: exits 0" 0 "$code"; check "$t: what was imported is the kept copy's dump" 1 "$(grep -c CURRENT "$S/imported.sql")"
check "$t: the kept copy is byte for byte what it was" "$before" "$(cat "$c/var/before-restore/$first")"
check "$t: and a second, newer copy is beside it" 2 "$(ls "$c/var/before-restore" | wc -l | tr -d ' ')"
check "$t: holding the database that was just replaced" 1 "$(grep -l RESTORED "$c/var/before-restore"/* | wc -l | tr -d ' ')"
# An import that fails leaves the database empty. The kept copy is the way back, and a second try (the database now
# empty) must neither replace it nor add a copy of nothing.
newcase; echo 1 > "$S/import_exit"; restore --yes; t="the import fails"; first="$(kept)"; before="$(cat "$c/var/before-restore/$first")"
check "$t: exits 1" 1 "$code"
check "$t: says the database is empty, and the exact way back" "problem: the import failed, and the database is now empty or part-filled. Put the last one back with: offprint backup restore --from var/before-restore/$first" "$out"
check "$t: the options were not touched" "information_schema|mariadb-dump|wp db reset|wp db import" "$(did)"; check "$t: no lock is left" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"
rm "$S/import_exit"; touch "$S/db_empty"; : > "$S/docker.calls"; out="$(cd "$c" && printf '%s\n' "$KEY" | HOME="$tmp/case$n/home" PATH="$S/bin:$PATH" STUB_DIR="$S" /bin/bash "$SRC/bin/offprint" backup restore --from "var/before-restore/$first" --yes 2>&1)"; code=$?; t="then the way back, as it was printed, run in the site folder"
check "$t: exits 0" 0 "$code"; check "$t: the kept copy is still there, unchanged" "$before" "$(cat "$c/var/before-restore/$first")"
check "$t: no copy was made of the empty database" "$first" "$(kept)"; check "$t: mariadb-dump never ran" "information_schema|wp db reset|wp db import|wp option get home|wp option update home|wp option update siteurl" "$(did)"
check "$t: says there was nothing to keep" "ok: example's database is now var/before-restore/$first's. The database was empty before, so nothing was kept." "$out"
newcase; echo 1 > "$S/reset_exit"; restore --yes; t="the reset fails"
check "$t: exits 1" 1 "$code"; check "$t: the import never ran" "information_schema|mariadb-dump|wp db reset" "$(did)"
case "$out" in "problem: the import failed, and the database is now empty or part-filled. Put the last one back with: offprint backup restore --from var/before-restore/"*) ok "$t: the same way back" ;; *) bad "$t: the same way back ($out)" ;; esac
# The current database can't be kept: nothing is replaced.
for how in dump_fails age_fails age_empty age_junk; do
  newcase; touch "$S/$how"; cp "$S/current_dump" "$tmp/case$n/src.sql"; key="" restore --from "$tmp/case$n/src.sql" --yes; t="the database as it is can't be kept ($how)"
  check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
  check "$t: says so" "problem: the database as it is now couldn't be kept, so nothing was replaced." "$out"
  check "$t: nothing is left in var/before-restore" "" "$(kept)"
done
# Whether the database is empty is asked of the database itself, and only its plain 0 means empty: no answer, a failed
# question or anything else is never taken for "nothing to keep" (the reset would follow with no way back).
for how in count_fails count_blank count_odd; do
  newcase; touch "$S/$how"; restore --yes; t="the database can't say how many tables it has ($how)"
  check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
  check "$t: says so" "problem: the database as it is now couldn't be kept, so nothing was replaced." "$out"
done
check "the question is asked of the database's own container, not of WordPress" 1 "$(grep -c ' exec -T db .*information_schema' "$S/docker.calls")"
# The kept copy is the dump byte for byte: nothing between mariadb-dump and age may change it (a NUL, a line with no
# end, bytes that are no text).
newcase; printf -- '-- MariaDB dump\nINSERT INTO t VALUES ("a\0b \377\376 c");\n-- Dump completed' > "$S/current_dump"; restore --yes; t="a dump with a NUL, bytes that are no text and no final line end"
check "$t: exits 0" 0 "$code"
check "$t: the kept copy holds it byte for byte" same "$(tail -n +4 "$c/var/before-restore/$(kept)" | cmp -s - "$S/current_dump" && echo same)"
newcase; printf -- '-- MariaDB dump\nINSERT INTO t VALUES ("CUT");\n' > "$S/current_dump"; restore --yes; t="the dump of the database as it is doesn't finish"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"; check "$t: says so" "problem: the database as it is now couldn't be kept, so nothing was replaced." "$out"
# A kept copy is never removed by a restore, however many there are: not after one that fails, not after one that
# succeeds, not the one it restored from, and not a file of the owner's beside them.
newcase; mkdir -p "$c/var/before-restore"; for d in 01 02 03 04 05 06; do dump_whole | sealed > "$c/var/before-restore/202601$d-000000.sql.age"; done
echo mine > "$c/var/before-restore/2026-notes.sql.age"
echo 1 > "$S/import_exit"; restore --yes; t="six kept copies and a file of the owner's, then a restore that fails"
check "$t: none was removed" 8 "$(ls "$c/var/before-restore" | wc -l | tr -d ' ')"
rm "$S/import_exit"; sleep 1; restore --from "$c/var/before-restore/20260101-000000.sql.age" --yes; t="then one that succeeds, from the oldest"
check "$t: exits 0" 0 "$code"; check "$t: none was removed" 9 "$(ls "$c/var/before-restore" | wc -l | tr -d ' ')"
check "$t: the one restored from is still there" yes "$([ -f "$c/var/before-restore/20260101-000000.sql.age" ] && echo yes)"
check "$t: so is the owner's file" mine "$(cat "$c/var/before-restore/2026-notes.sql.age")"
newcase; mkdir -p "$tmp/case$n/elsewhere"; ln -s "$tmp/case$n/elsewhere" "$c/var/before-restore"; restore --yes; t="var/before-restore is a link"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"; check "$t: nothing was written through it" "" "$(ls "$tmp/case$n/elsewhere")"

# What --from may name.
from_refused() {  # NAME FILE MESSAGE
  key="" restore --from "$2" --yes
  check "$1: exits 1" 1 "$code"; check "$1: says so" "$3" "$out"; nothing_replaced "$1"
  check "$1: nothing was read or asked of Docker's WordPress" "" "$(cat "$S/age.calls" 2>/dev/null)$(did)"
}
writable="is in a folder WordPress can write or the tool keeps for itself; copy it somewhere else first."
newcase; dump_whole > "$tmp/case$n/real.sql"; ln -s "$tmp/case$n/real.sql" "$tmp/case$n/link.sql"
from_refused "restore --from a link" "$tmp/case$n/link.sql" "problem: $tmp/case$n/link.sql isn't a plain file."
from_refused "restore --from a folder" "$tmp/case$n" "problem: $tmp/case$n isn't a plain file."
from_refused "restore --from a file that isn't there" "$tmp/case$n/none.sql" "problem: $tmp/case$n/none.sql isn't a plain file."
dump_whole > "$c/wp-content/x.sql"; from_refused "restore --from a file in wp-content/" "$c/wp-content/x.sql" "problem: $c/wp-content/x.sql $writable"
mkdir -p "$c/wp-content/uploads/2026"; dump_whole > "$c/wp-content/uploads/2026/x.sql"; from_refused "restore --from a file deep in wp-content/" "$c/wp-content/uploads/2026/x.sql" "problem: $c/wp-content/uploads/2026/x.sql $writable"
mkdir -p "$c/var/export"; dump_whole > "$c/var/export/x.sql"; from_refused "restore --from a file in var/export" "$c/var/export/x.sql" "problem: $c/var/export/x.sql $writable"
dump_whole > "$c/var/x.sql"; from_refused "restore --from a file in var/" "$c/var/x.sql" "problem: $c/var/x.sql $writable"
mkdir -p "$c/var/before-restore"; dump_whole > "$c/var/before-restore/mine.sql"; from_refused "restore --from a file in var/before-restore that isn't a kept copy" "$c/var/before-restore/mine.sql" "problem: $c/var/before-restore/mine.sql $writable"
ln -s "$c/wp-content" "$tmp/case$n/way-in"; from_refused "restore --from a file in wp-content/, reached through a link outside" "$tmp/case$n/way-in/x.sql" "problem: $tmp/case$n/way-in/x.sql $writable"
rm -rf "$c/wp-content/x.sql" "$c/wp-content/uploads" "$c/var/export" "$c/var/x.sql" "$c/var/before-restore"
# The committed backup, when the folder's file isn't the commit's (as verify).
newcase; echo scribble >> "$c/backup/db.sql.age"; restore --yes; t="restore, the file in the folder is not the commit's"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
check "$t: says so" "problem: backup/db.sql.age in this folder is not the one in the last commit; publish, or restore it with git, then restore again." "$out"
newcase; git -C "$c" rm -q backup/db.sql.age; git -C "$c" commit -q -m "no backup"; restore --yes; t="restore, no backup in the last commit"
check "$t: exits 1" 1 "$code"; check "$t: says so" "problem: this site's last commit has no backup/db.sql.age. Publish first, or name a dump with --from." "$out"

# The other refusals: each before anything is replaced.
newcase; key=AGE-SECRET-KEY-1WRONG restore --yes; t="restore, a wrong key"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"; check "$t: says so" "problem: that key doesn't open backup/db.sql.age. Nothing was restored." "$out"
check "$t: nothing was kept" "" "$(kept)"
newcase; key="" restore --yes; t="restore --yes, an encrypted source and no key line"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"; check "$t: says so" "problem: no key was given." "$out"
newcase; printf -- '-- MariaDB dump\n' | sealed > "$c/backup/db.sql.age"; git -C "$c" commit -q -am cut; restore --yes; t="restore, a backup that is not a whole dump"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
check "$t: says so" 'problem: backup/db.sql.age opens, but what is in it is not a whole database dump (its last line is not "-- Dump completed"). Nothing was restored.' "$out"
newcase; restore; t="restore without --yes, and no terminal to ask at"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
check "$t: says so" "problem: a restore asks before it replaces the database, and there is no terminal to ask at; say --yes." "$out"
check "$t: age never ran" no "$([ -e "$S/age.calls" ] && echo yes || echo no)"
newcase; touch "$S/wp_down"; restore --yes; t="restore, WordPress not running"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"; check "$t: says so" "problem: WordPress isn't running (offprint compose up -d), so nothing was restored." "$out"
newcase; mkdir -p "$c/var/publish.lock"; echo 4242 > "$c/var/publish.lock/pid"; restore --yes; t="restore while a publish holds the lock"
check "$t: exits 1" 1 "$code"; check "$t: says so" "problem: a publish is running, or left its lock (var/publish.lock); wait for it, then restore again." "$out"
check "$t: the lock is the publish's still" 4242 "$(cat "$c/var/publish.lock/pid" 2>/dev/null)"; check "$t: the database was not touched" "" "$(did | grep -oE 'wp db reset|wp db import' | paste -sd'|' -)"
newcase; grep -v '"backup"' "$c/site.json" | sed 's/"http_port": 4998,/"http_port": 4998/' > "$c/site.json.new"; mv "$c/site.json.new" "$c/site.json"; git -C "$c" commit -q -am "no backup block"; restore --yes; t="restore, no backup block in site.json"
check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
check "$t: says so" 'problem: site.json has no "backup" block, and a restore keeps an encrypted copy of the database it replaces. Add one (the README has the steps), then restore again.' "$out"
newcase; rm "$S/bin/age"; PATH="$(no_age_path)" restore --yes; t="restore, no age on the PATH"
check "$t: exits 1" 1 "$code"; check "$t: says what to install" "problem: age isn't installed; install it (brew install age) and restore again." "$out"
for bad_args in "--from" "--frm x" "extra" "--yes --yes --from"; do
  newcase; restore $bad_args; check "restore $bad_args: usage, exit 2" "2|$usage" "$code|$out"
done

# After the import: a WordPress that can't read its settings is a problem, not an ok.
newcase; touch "$S/options_fail"; restore --yes; t="the dump is in, but WordPress can't read its settings"; first="$(kept)"
check "$t: exits 1" 1 "$code"
check "$t: says so, with the way back" "problem: the dump is in, but WordPress can't read its settings (another table prefix?). Put the last database back with: offprint backup restore --from var/before-restore/$first" "$out"
# A dump from another address: said, with the command to consider; and only an address that looks like one is printed.
newcase; echo "https://old.example.com" > "$S/home_before"; restore --yes; t="a dump from another address"
check "$t: exits 0" 0 "$code"
check "$t: the second line names it and the command to consider" "The dump came from https://old.example.com: addresses inside its content still say so. To change them: offprint wp search-replace 'https://old.example.com' 'https://mysite.test' --skip-columns=guid" "$(printf '%s\n' "$out" | sed -n 2p)"
newcase; printf '%s\n' "https://x.example/\$(touch $tmp/case$n/ran)';id" > "$S/home_before"; restore --yes; t="a dump whose address is not one"
check "$t: exits 0" 0 "$code"; lacks "$t: nothing of it is printed" 'touch' "$out"
check "$t: says only that it was another" "The dump came from another address: addresses inside its content still say so (offprint wp search-replace changes them)." "$(printf '%s\n' "$out" | sed -n 2p)"
check "$t: and nothing in it ran" no "$([ -e "$tmp/case$n/ran" ] && echo yes || echo no)"
# The publish agent installed: said before and after (a publish WordPress asks for runs straight after).
newcase; mkdir -p "$tmp/case$n/home/Library/LaunchAgents"; : > "$tmp/case$n/home/Library/LaunchAgents/local.offprint.example.publish.plist"; restore --yes; t="restore with the publish agent installed"
check "$t: exits 0" 0 "$code"
check "$t: says so, twice" 2 "$(printf '%s\n' "$out" | grep -c 'The publish agent is installed: a publish WordPress asks for will run straight after, on the restored database. offprint install-agent --remove takes it away.')"

# At a terminal: the question, the name typed, and the key pasted unseen. A pseudo-terminal, made by python3.
if command -v python3 > /dev/null 2>&1; then
  # at_terminal ARGS -- LINES...: runs offprint backup ARGS with a terminal as its input and output, types each LINE
  # when the output stops, and prints everything the terminal showed; sets out, code.
  at_terminal() {
    out="$(cd "$tmp/case$n" && HOME="$tmp/case$n/home" PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" python3 - /bin/bash "$SRC/bin/offprint" backup "$@" <<'PY' 2>&1
import os, pty, select, sys
args = sys.argv[1:]; cut = args.index('--'); cmd, lines = args[:cut], args[cut + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(cmd[0], cmd)
shown = b''
def drain(wait):
    global shown
    while True:
        r, _, _ = select.select([fd], [], [], wait)
        if not r: return True
        try: data = os.read(fd, 4096)
        except OSError: return False
        if not data: return False
        shown += data
alive = drain(3)
for line in lines:
    if not alive: break
    os.write(fd, line.encode() + b'\n'); alive = drain(3)
while alive: alive = drain(3)
_, status = os.waitpid(pid, 0)
sys.stdout.write(shown.decode(errors='replace').replace('\r', ''))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 99)
PY
)"; code=$?
  }
  newcase; at_terminal restore -- example "$KEY"; t="restore at a terminal, the name typed and the key pasted"
  check "$t: exits 0" 0 "$code"; check "$t: the database was replaced" "$all_steps" "$(did)"
  case "$out" in *"This replaces the whole database of example (https://mysite.test) with backup/db.sql.age (commit $short)."*"Type the site's name (example) to go on: "*) ok "$t: it asks first, naming the site and the source" ;; *) bad "$t: it asks first ($out)" ;; esac
  lacks "$t: the key is not shown as it is pasted" "$KEY" "$out"
  newcase; at_terminal restore -- exmaple; t="restore at a terminal, another name typed"
  check "$t: exits 1" 1 "$code"; nothing_replaced "$t"
  case "$out" in *"problem: that isn't the site's name; nothing was restored."*) ok "$t: says so" ;; *) bad "$t: says so ($out)" ;; esac
  check "$t: the key was never asked for" 0 "$(printf '%s' "$out" | grep -c 'private key')"
  newcase; at_terminal verify -- "$KEY"; t="verify at a terminal"
  check "$t: exits 0" 0 "$code"; lacks "$t: the key is not shown as it is pasted" "$KEY" "$out"
  case "$out" in *"Paste the backup's private key"*"ok: backup/db.sql.age (commit $short) opens with this key and is a whole database dump."*) ok "$t: it asks, then says ok" ;; *) bad "$t: it asks, then says ok ($out)" ;; esac
else
  echo "skip  the cases at a terminal (the question, the name typed, the key pasted unseen): no python3 to make one"
fi

[ "$fail" -eq 0 ]
