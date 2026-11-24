#!/usr/bin/env bash
# Checks a site's running local WordPress against its site.json: https://<local_host> answers, the name resolves
# to the site's addresses, Caddy listens only where it should, and WordPress has the settings offprint setup-wp gives it.
#   bash tests/site.test.sh SITE_DIR
# It reads real things (DNS, the site's containers, WordPress's options) and changes nothing. macOS only (it asks
# dscacheutil), and only for a site that is set up and running, so it is not run in CI.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then echo "usage: bash tests/site.test.sh SITE_DIR" >&2; exit 2; fi
. "$(dirname "$0")/../lib/site.sh"
OFFPRINT_SITE="$dir"
offprint_find_site
offprint_load_site
cd "$SITE" || exit 1
# The checks below run dc with its errors sent to /dev/null, so a compose project that isn't this site folder's own (or
# Docker not running) would show only as failures with no reason. lib/site.sh's check is run once here instead: it
# prints why, and stops (exit 2, or 1 when Docker isn't running).
offprint_require_project
export OFFPRINT_SITE="$SITE"   # for bin/wp
fail=0
check() {  # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (wanted '$2', got '$3')"; fail=1; fi
}
contains() {  # description, needle, haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "ok    $1"; else echo "FAIL  $1 (no '$2' in '$3')"; fail=1; fi
}

check "https://$SITE_LOCAL_HOST/ answers 200 with a trusted certificate" 200 \
  "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "https://$SITE_LOCAL_HOST/" 2>/dev/null)"

start=$(perl -MTime::HiRes=time -e 'print time')
hosts="$(dscacheutil -q host -a name "$SITE_LOCAL_HOST" 2>/dev/null)"
elapsed=$(perl -MTime::HiRes=time -e 'printf "%.2f", time - $ARGV[0]' "$start")
contains "$SITE_LOCAL_HOST resolves to $SITE_IP4" "$SITE_IP4" "$hosts"
contains "$SITE_LOCAL_HOST resolves to $SITE_IP6" "$SITE_IP6" "$hosts"
if perl -e 'exit($ARGV[0] < 1 ? 0 : 1)' "$elapsed"; then echo "ok    lookup took under 1 second"; else echo "FAIL  lookup took ${elapsed}s"; fail=1; fi

check "caddy publishes 443 on 127.0.0.1:$SITE_TLS_PORT only" "127.0.0.1:$SITE_TLS_PORT" \
  "$(dc port caddy 443 2>/dev/null)"
for ip in "$SITE_IP4" "$SITE_IP6"; do
  if nc -z -w 2 "$ip" 443 2>/dev/null; then echo "ok    something listens on [$ip]:443"; else echo "FAIL  nothing listens on [$ip]:443"; fail=1; fi
done
pubs="$(dc ps --format '{{.Publishers}}' 2>/dev/null)"
if [ -n "$pubs" ] && ! printf '%s' "$pubs" | grep -q '0\.0\.0\.0'; then
  echo "ok    no service publishes a port on 0.0.0.0"
else
  echo "FAIL  no service publishes on 0.0.0.0 (publishers: '${pubs:-none running}')"; fail=1
fi

check "permalink structure is /%postname%/" '/%postname%/' \
  "$("$TOOL/bin/wp" option get permalink_structure 2>/dev/null | tr -d '\r')"
check "comments are closed by default" closed \
  "$("$TOOL/bin/wp" option get default_comment_status 2>/dev/null | tr -d '\r')"

exit "$fail"
