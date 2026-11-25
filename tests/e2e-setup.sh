# Sourced, from the repo's root, by tests/e2e.sh and tests/compat-seo.sh: the throwaway WordPress both run against
# (compose project "offprint-e2e": its own database, a temporary wp-content holding only this repo's plugin/ as a site's
# mu-plugins, no ports, no Caddy), and the helpers both use. It never touches a real site, and the trap it sets removes
# everything it made, pass or fail. The two share the project, so never run them at the same time: it refuses to start
# while the project has a container or a volume (the other's run, or what a killed run left), and then removes nothing.

# The site's names (its public address, local host and ports) are tests/fixtures/site.json's, read through the
# loader every script uses (lib/site.sh, which runs lib/config.php).
OFFPRINT_SITE=tests/fixtures
. lib/site.sh
offprint_find_site
offprint_load_site
unset OFFPRINT_SITE
PROJECT=offprint-e2e

# Before anything is made, and before the trap that would remove another run's project.
E2E_LEFT=$( { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" &&
  docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT"; } 2>&1 ) ||
  { echo "Docker didn't answer, so nothing was started: is it running? $E2E_LEFT"; exit 1; }
if [ -n "$E2E_LEFT" ]; then
  echo "The compose project $PROJECT already has these containers or volumes: $(printf '%s' "$E2E_LEFT" | paste -sd' ' -)."
  echo "tests/e2e.sh and tests/compat-seo.sh share it, so one of them is running, or a killed run left it. Nothing was"
  echo "started or removed. When neither runs: docker compose -p $PROJECT down -v, then docker volume rm any left."
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/offprint-e2e.XXXXXX")
export E2E_WP_CONTENT="$WORK/wp-content" E2E_EXPORT="$WORK/export" E2E_PUBLISH="$WORK/publish" E2E_INBOX="$WORK/inbox"
PUBLIC="$SITE_PUBLIC_URL"
LOCAL="$SITE_LOCAL_HOST"
LOCAL_RE="$(printf '%s' "$LOCAL" | sed 's/\./\\./g')"   # for grep: the dots are dots
FAILED=0
PASSED=0

# Not lib/site.sh's dc (a site's own project, named after it, in its folder): this replaces it here. The throwaway
# project: templates/compose.yaml with tests/compose.e2e.yaml over it, the temporary folder as its project directory
# (so no relative path reaches this repo or a site), the fixture's values for the OFFPRINT_* variables. Caddy, the
# only service with ports, is never started.
dc() {
  OFFPRINT_PUBLIC_ORIGIN="$SITE_PUBLIC_URL" OFFPRINT_LOCAL_HOST="$SITE_LOCAL_HOST" \
  OFFPRINT_TLS_PORT="$SITE_TLS_PORT" OFFPRINT_HTTP_PORT="$SITE_HTTP_PORT" OFFPRINT_TOOL="$TOOL" \
  docker compose -p "$PROJECT" --project-directory "$WORK" \
    -f "$TOOL/templates/compose.yaml" -f "$TOOL/tests/compose.e2e.yaml" "$@"
}

cleanup() {
  # Files WordPress made may belong to www-data; open them up so rm can work.
  dc exec -T wordpress chmod -R a+rwX /var/www/html/wp-content >/dev/null 2>&1
  dc down -v --remove-orphans >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# wp ARGS...: WP-CLI in the throwaway WordPress, as www-data.
wp() { dc exec -T -u www-data wordpress wp "$@"; }

# check NAME CMD...: runs CMD, counts and prints the result.
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1)); echo "ok   - $name"
  else
    FAILED=$((FAILED + 1)); echo "FAIL - $name"
  fi
}
contains() { case $1 in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! contains "$1" "$2"; }
equals() { [ "$1" = "$2" ]; }

# e2e_start: the throwaway's folders, this repo's plugin/ as its mu-plugins, and its WordPress, started.
e2e_start() {
  mkdir -p "$E2E_WP_CONTENT" "$E2E_EXPORT" "$E2E_PUBLISH" "$E2E_INBOX"
  mkdir -p "$E2E_WP_CONTENT/mu-plugins"
  cp -R plugin/offprint.php plugin/offprint "$E2E_WP_CONTENT/mu-plugins/"
  chmod -R a+rwX "$WORK"
  echo "Starting the throwaway WordPress..."
  dc up -d --build --wait wordpress >/dev/null || { echo "could not start"; exit 1; }
}

# e2e_install: WordPress installed at the local host, its admin e2e-admin (user 1), with pretty permalinks.
e2e_install() {
  ADMIN_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  wp core install --url="https://$LOCAL" --title="E2E" --admin_user=e2e-admin \
    --admin_password="$ADMIN_PASSWORD" --admin_email=e2e@example.com --skip-email >/dev/null || { echo "install failed"; exit 1; }
  wp rewrite structure '/%postname%/' --hard >/dev/null
}

# run_export DIR: the exporter, into DIR in the export mount; sets EXPORT_OUT (stdout),
# EXPORT_ERR (stderr) and EXPORT_STATUS.
run_export() {
  EXPORT_OUT=$(wp offprint export --out="/var/www/export/$1" 2>"$WORK/export.stderr")
  EXPORT_STATUS=$?
  EXPORT_ERR=$(cat "$WORK/export.stderr")
}
found_in() { find "$1" -name "$2" 2>/dev/null | head -1; }
# These pass only for a folder that exists, so a missing export cannot pass them.
not_found_in() { [ -d "$1" ] && [ -z "$(found_in "$1" "$2")" ]; }
never_says() { [ -d "$1" ] && ! grep -rqi "$2" "$1"; }

# check_site_as_published EXPORT COPY: bin/check-site on a copy of EXPORT (made at COPY) as a publish to
# cloudflare-workers runs it: adapter_prepare's files written into the copy (lib/adapter.sh loads the tool's adapter, as
# a publish does), then the check with that adapter's names and limits, as bin/publish passes them: its prepare files
# allowed as written, offprint.json still to come (55 bytes). Sets CHECK_OUT; returns the check's status.
check_site_as_published() {
  cp -R "$1" "$2"
  CHECK_OUT=$( (
    set +o pipefail
    ADAPTER_NAME=cloudflare-workers
    . "$TOOL/lib/adapter.sh"
    trap offprint_adapter_cleanup EXIT
    offprint_adapter_load || { echo "the adapter couldn't be loaded: $OFFPRINT_ADAPTER_PROBLEM"; exit 1; }
    offprint_adapter_call adapter_prepare "$2" || { echo "adapter_prepare failed"; exit 1; }
    allowed=""; to_come=""
    for r in $ADAPTER_PREPARE_FILES; do if [ "$r" = offprint.json ]; then to_come=$r; else allowed="${allowed:+$allowed }$r"; fi; done
    CHECK_SITE_HOST="$SITE_PUBLIC_HOST" CHECK_SITE_LOCAL_HOST="$SITE_LOCAL_HOST" \
      CHECK_SITE_RESERVED="$ADAPTER_PREPARE_FILES $ADAPTER_HOST_FILES" CHECK_SITE_ALLOWED="$allowed" \
      CHECK_SITE_TO_COME="$to_come" CHECK_SITE_TO_COME_BYTES=55 CHECK_SITE_MAX_BYTES="$ADAPTER_MAX_TOTAL_BYTES" \
      CHECK_SITE_MAX_FILES="$ADAPTER_MAX_FILES" CHECK_SITE_MAX_FILE_BYTES="$ADAPTER_MAX_FILE_BYTES" \
      "$TOOL/bin/check-site" "$2"
  ) 2>&1 )
}
