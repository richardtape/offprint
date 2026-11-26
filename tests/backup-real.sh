#!/usr/bin/env bash
# The database backup with the real age, not a stand-in: what a publish and `offprint backup verify` assume of it.
# It needs age and age-keygen on the PATH (brew install age) and is never run in CI: run it on the Mac before any merge
# that touches the backup. It touches no site, no Keychain and no host: everything is in a temporary folder it removes,
# and every private key it makes lives in a shell variable only, never in a file.
#   bash tests/backup-real.sh
set -uo pipefail
cd "$(dirname "$0")/.."

for tool in age age-keygen; do
  command -v "$tool" > /dev/null 2>&1 || { echo "$tool isn't installed (brew install age), so the real backup checks can't run."; exit 2; }
done

fail=0; passed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/offprint-backup-real.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

new_identity() { age-keygen 2> /dev/null | grep '^AGE-SECRET-KEY-'; }
identity="$(new_identity)"
recipient="$(printf '%s\n' "$identity" | age-keygen -y)"
identity2="$(new_identity)"
recipient2="$(printf '%s\n' "$identity2" | age-keygen -y)"
stranger="$(new_identity)"

printf -- '-- a dump\nINSERT INTO t VALUES (1);\n-- Dump completed\n' > "$tmp/db.sql"
age -r "$recipient" -r "$recipient2" -o "$tmp/db.sql.age" "$tmp/db.sql"

check "a recipient matches the pattern the tool accepts" yes "$(printf '%s' "$recipient" | grep -Eq '^age1[ac-hj-np-z02-9]{58}$' && echo yes)"
check "the file starts with the age header" "age-encryption.org/v1" "$(head -n 1 "$tmp/db.sql.age")"
check "the first key opens it, given on standard input" "$(cat "$tmp/db.sql")" "$(printf '%s\n' "$identity" | age -d -i - "$tmp/db.sql.age" 2>&1)"
check "the second key opens it too" "$(cat "$tmp/db.sql")" "$(printf '%s\n' "$identity2" | age -d -i - "$tmp/db.sql.age" 2>&1)"
check "a wrong key fails" 1 "$(printf '%s\n' "$stranger" | age -d -i - "$tmp/db.sql.age" > /dev/null 2>&1; echo $?)"
age -r "$recipient" -r "$recipient2" -o "$tmp/again.age" "$tmp/db.sql"
check "encrypting the same file twice gives different bytes" no "$(cmp -s "$tmp/db.sql.age" "$tmp/again.age" && echo yes || echo no)"
check "no private key reached a file" "" "$(grep -rl 'AGE-SECRET-KEY-' "$tmp")"

echo "passed $passed"
exit "$fail"
