#!/usr/bin/env bash
# offprint backup restore with the real tools, start to finish: a real (throwaway) site folder made by offprint new,
# its WordPress made by offprint setup-wp, a real publish (--no-push) that encrypts the backup with the real age, and
# restores from the committed backup, from a readable dump and from a kept copy. tests/e2e.sh can't hold this: its
# throwaway WordPress is not a site's own compose project, which the tool refuses to act on, and rightly.
#
# Needs Docker running, mkcert (with its local CA made), age and git; uses the network only if Docker must pull an
# image. Never in CI. It touches no real site: the site folder is in a temporary folder, its compose project is
# "offprint-restore-real" (it refuses to start while that exists), nothing runs with sudo and the host set-up is never
# run (the WordPress is only asked from inside its container). Every key it makes lives in a shell variable only. It
# removes the project, its volumes and the folder on every exit.
#   bash tests/restore-real.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD"
NAME=offprint-restore-real

for tool in docker mkcert age age-keygen git; do
  command -v "$tool" > /dev/null 2>&1 || { echo "$tool isn't installed, so the real restore checks can't run."; exit 2; }
done
left="$( { docker ps -aq --filter "label=com.docker.compose.project=$NAME" && docker volume ls -q --filter "label=com.docker.compose.project=$NAME"; } 2>&1)" \
  || { echo "Docker didn't answer, so nothing was started: is it running?"; exit 2; }
[ -z "$left" ] || { echo "The compose project $NAME already has containers or volumes (a killed run?). Nothing was started or removed. When no run is going: docker compose -p $NAME down -v"; exit 2; }

fail=0; passed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in '$3')" ;; esac; }

work="$(mktemp -d "${TMPDIR:-/tmp}/offprint-restore-real.XXXXXX")"; work="$(cd "$work" && pwd -P)"
site="$work/$NAME"
op() { ( cd "$site" && /bin/bash "$SRC/bin/offprint" "$@" ); }
cleanup() {
  if [ -f "$site/site.json" ]; then
    op compose exec -T wordpress chmod -R a+rwX /var/www/html/wp-content > /dev/null 2>&1
    op compose down -v --remove-orphans > /dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT

identity="$(age-keygen 2> /dev/null | grep '^AGE-SECRET-KEY-')"
recipient="$(printf '%s\n' "$identity" | age-keygen -y)"

# --- a real site folder, and its WordPress ---
( cd "$work" && /bin/bash "$SRC/bin/offprint" new "$NAME" --public-url https://www.example.com ) > "$work/new.out" 2>&1 \
  || { cat "$work/new.out"; echo "offprint new failed; nothing was started."; exit 1; }
sed '$d' "$site/site.json" | sed '$s/$/,/' > "$site/site.json.new"
printf '  "backup": {"recipients": ["%s"]}\n}\n' "$recipient" >> "$site/site.json.new"; mv "$site/site.json.new" "$site/site.json"
git -C "$site" commit -q -am "a backup key"
echo "Making the throwaway WordPress (a minute or two)..."
( cd "$site" && WP_ADMIN_USER=real-admin WP_ADMIN_EMAIL=admin@example.com \
  WP_ADMIN_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)" /bin/bash "$SRC/bin/offprint" setup-wp ) > "$work/setup.out" 2>&1 \
  || { tail -20 "$work/setup.out"; echo "offprint setup-wp failed."; exit 1; }
wp() { op wp "$@" < /dev/null; }
titles() { wp post list --post_type=post --post_status=publish --field=post_title 2> /dev/null | sort | paste -sd'|' -; }
post="$(wp post create --post_title=Before --post_status=publish --post_author=1 --porcelain)"

# --- a publish makes the encrypted backup; verify opens it ---
out="$(op publish --no-push 2>&1)"; code=$?
check "a real publish (--no-push) succeeds" 0 "$code"; [ "$code" = 0 ] || printf '%s\n' "$out" | tail -15
check "the commit's backup is an age file" "age-encryption.org/v1" "$(git -C "$site" show HEAD:backup/db.sql.age 2> /dev/null | head -n 1)"
out="$(printf '%s\n' "$identity" | op backup verify 2>&1)"
contains "offprint backup verify opens it with the real key" "opens with this key and is a whole database dump." "$out"

# --- restore from the committed backup ---
wp post update "$post" --post_title=After > /dev/null
check "control: the post was changed" "After|Hello world!" "$(titles)"
out="$(printf '%s\n' "$identity" | op backup restore --yes 2>&1)"; code=$?
check "restore from the committed backup: exits 0" 0 "$code"; [ "$code" = 0 ] || printf '%s\n' "$out"
check "restore from the committed backup: the post is as it was" "Before|Hello world!" "$(titles)"
contains "restore from the committed backup: says ok, and where the one before is" "The one before is var/before-restore/" "$out"
kept1="$(ls "$site/var/before-restore" | head -n 1)"
check "the kept copy opens with the real key, is a whole dump, and holds the database that was replaced" "-- Dump completed|1" \
  "$(printf '%s\n' "$identity" | age -d -i - "$site/var/before-restore/$kept1" 2> /dev/null | grep -v '^[[:space:]]*$' | tail -n 1)|$(printf '%s\n' "$identity" | age -d -i - "$site/var/before-restore/$kept1" 2> /dev/null | grep -c "'After'" | sed 's/^[1-9][0-9]*$/1/')"
check "home and siteurl are the site's local address" "https://$NAME.local|https://$NAME.local" "$(wp option get home)|$(wp option get siteurl)"
check "WordPress still answers: the admin user is the dump's" real-admin "$(wp user list --field=user_login 2> /dev/null | paste -sd'|' -)"
check "no lock is left" no "$([ -e "$site/var/publish.lock" ] && echo yes || echo no)"
check "no readable dump is anywhere in the site folder" "" "$(grep -rl 'Dump completed' "$site" --include='*' 2> /dev/null | grep -v '/\.git/' | head -3)"

# --- restore from a kept copy: back to "After", and the copy survives ---
before_bytes="$(wc -c < "$site/var/before-restore/$kept1" | tr -d ' ')"
out="$(printf '%s\n' "$identity" | op backup restore --from "var/before-restore/$kept1" --yes 2>&1)"; code=$?
check "restore from a kept copy: exits 0" 0 "$code"; [ "$code" = 0 ] || printf '%s\n' "$out"
check "restore from a kept copy: the post is the changed one again" "After|Hello world!" "$(titles)"
check "restore from a kept copy: the copy is still there, the same size" "$before_bytes" "$(wc -c < "$site/var/before-restore/$kept1" | tr -d ' ')"
check "restore from a kept copy: and there are two copies now" 2 "$(ls "$site/var/before-restore" | wc -l | tr -d ' ')"

# --- restore from a readable dump taken at another address (a database brought in from another WordPress) ---
wp option update home https://old.example.com > /dev/null; wp option update siteurl https://old.example.com > /dev/null
wp post update "$post" --post_title=Theirs > /dev/null
op compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' > "$work/theirs.sql" 2> /dev/null < /dev/null
check "control: the dump was taken as another tool takes it (its last line has a date)" yes "$(tail -n 1 "$work/theirs.sql" | grep -q '^-- Dump completed on ' && echo yes)"
wp option update home "https://$NAME.local" > /dev/null; wp post update "$post" --post_title=Mine > /dev/null
out="$(op backup restore --from "$work/theirs.sql" --yes 2>&1 < /dev/null)"; code=$?
check "restore --from a readable dump: exits 0" 0 "$code"; [ "$code" = 0 ] || printf '%s\n' "$out"
check "restore --from a readable dump: the post is the dump's" "Hello world!|Theirs" "$(titles)"
check "restore --from a readable dump: home and siteurl are the local address again" "https://$NAME.local|https://$NAME.local" "$(wp option get home)|$(wp option get siteurl)"
contains "restore --from a readable dump: says where it came from, and the command to consider" "The dump came from https://old.example.com: addresses inside its content still say so. To change them: offprint wp search-replace 'https://old.example.com' 'https://$NAME.local' --skip-columns=guid" "$out"

# --- an import that fails leaves the way back, and the way back works ---
printf 'THIS IS NOT SQL;\n-- Dump completed\n' > "$work/bad.sql"
out="$(op backup restore --from "$work/bad.sql" --yes 2>&1 < /dev/null)"; code=$?
check "a dump that isn't SQL: exits 1" 1 "$code"
contains "a dump that isn't SQL: says the database is empty, and the way back" "the import failed, and the database is now empty or part-filled. Put the last one back with: offprint backup restore --from var/before-restore/" "$out"
back="$(printf '%s\n' "$out" | sed -n 's/.*--from \(var\/before-restore\/[0-9-]*\.sql\.age\).*/\1/p')"
out="$(printf '%s\n' "$identity" | op backup restore --from "$back" --yes 2>&1)"; code=$?
check "the way back, as printed: exits 0" 0 "$code"; [ "$code" = 0 ] || printf '%s\n' "$out"
check "the way back: the database is the one before the failed import" "Hello world!|Theirs" "$(titles)"
contains "the way back: an empty database was not kept" "The database was empty before, so nothing was kept." "$out"
check "no private key reached a file" "" "$(grep -rlE 'AGE-SECRET-KEY-1[A-Z0-9]{20}' "$work" 2> /dev/null | head -3)"

echo "passed $passed"
exit "$fail"
