# A host adapter for the tests, kept outside the tool: tests/publish.test.sh's throwaway sites copy it to their own
# adapters/workflow/, commit it, and name it in site.json. It is the host bin/publish was written for before the adapter
# contract (lib/adapter.sh), kept so that every one of those tests still holds: a deploy workflow on GitHub (a GitHub
# Actions run) builds the site from the pushed commit and writes build.json at the root of the live site, naming the
# commit. The publish asks the live site for that file until it names the commit just pushed.
ADAPTER_HOST_FILES=build.json   # the deploy writes it; the export can't have one, and it is never committed
ADAPTER_PREPARE_FILES=
ADAPTER_MAX_TOTAL_BYTES=104857600   # 100 MB, gzip-compressed

# adapter_confirm ID COMMIT: 0 when the live site's build.json names COMMIT; 1 when it names another build or none
# (ADAPTER_WHY says which); 2 when it couldn't be reached, or answered with an error. PUBLISH_CHECK_URL, when set, is
# asked instead of PUBLIC_URL/build.json. (The ?c= makes each question a new address, so no cache answers it.)
adapter_confirm() {
  local body live
  body="$(curl -fsS --max-time 10 "${PUBLISH_CHECK_URL:-$SITE_PUBLIC_URL/build.json}?c=$2")" || return 2
  live="$(printf '%s' "$body" | tr -d '\n' | sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p')"
  [ "$live" != "$2" ] || return 0
  if [ -n "$live" ]; then ADAPTER_WHY="it still reports ${live:0:7}"; else ADAPTER_WHY="its build.json names no build"; fi
  return 1
}

adapter_failure_hint() { printf '; look at the GitHub Actions run'; }
