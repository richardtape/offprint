#!/usr/bin/env bash
# Tests bin/publish-agent (what launchd runs when WordPress asks for a publish) with a stand-in bin/publish,
# and os/darwin/install-agent (offprint install-agent). Both are the tool's own, run in place for a throwaway site
# folder.
# Nothing here touches launchd: install-agent runs only with --print, as a pretend root, or with a stand-in
# launchctl and a throwaway HOME.
# Run: bash tests/agent.test.sh   (macOS bash 3.2 and Linux; the plist checks need macOS's plutil and are
# skipped, visibly, without it)
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR), and TMPDIR
# inside it from here on, so nothing the suite runs leaves anything in the real one.
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-agent-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
skip() { echo "skip  $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
contains() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no '$2' in '$3')"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' in '$3')"; else ok "$1"; fi; }
count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# wait_for FILE LINES: until FILE has at least LINES lines (at most 10 seconds)
wait_for() { local i=0; while [ "$(count "$1")" -lt "$2" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; }

n=0
# --- one throwaway site folder: $c, its inbox $in, stand-ins in $S ---
newcase() {
  n=$((n + 1)); c="$tmp/case$n/repo"; in="$c/var/inbox"; S="$tmp/case$n/stubs"
  mkdir -p "$in" "$S"
  cp "$SRC/tests/fixtures/site.json" "$c/site.json"
  # The stand-in bin/publish: notes each start (and where, and for which site), then does what the case asks,
  # then notes a finished run.
  #   busy_for N    the first N calls say a publish is already running and exit 75, as bin/publish does
  #   busy_text     a call that says "already running" but exits 1 (an ordinary failure)
  #   plant         the first call makes the inbox request a symlink to the folder $STUB_DIR/target
  #   storm         every run writes a new request, as if the owner kept asking
  #   sleep N       how long a run takes (default 2 seconds)
  cat > "$S/publish" <<'STUB'
#!/usr/bin/env bash
echo start >> "$STUB_DIR/starts"
echo "$PWD|${OFFPRINT_SITE-unset}" >> "$STUB_DIR/where"
if [ -f "$STUB_DIR/plant" ] && [ "$(wc -l < "$STUB_DIR/starts")" -eq 1 ]; then
  mkdir -p "$STUB_DIR/target"; ln -s "$STUB_DIR/target" "$PWD/var/inbox/publish-request"
fi
if [ -f "$STUB_DIR/busy_for" ] && [ "$(wc -l < "$STUB_DIR/starts")" -le "$(cat "$STUB_DIR/busy_for")" ]; then
  echo "A publish is already running (var/publish.lock); it will not start a second one." >&2
  exit 75
fi
if [ -f "$STUB_DIR/busy_text" ]; then
  echo "A publish is already running, says the text, but not the exit code" >&2
  exit 1
fi
[ -f "$STUB_DIR/storm" ] && echo "2026-11-20T10:00:00Z storm" > "$PWD/var/inbox/publish-request"
sleep "$(cat "$STUB_DIR/sleep" 2>/dev/null || echo 2)"
echo "error output from the run" >&2
echo run >> "$STUB_DIR/runs"
STUB
  # The stand-in bin/collect: notes each call's arguments (collect.calls), and whether a publish had started by then.
  #   --fetch-only --notify (what every start runs first): does nothing and says nothing, as for a site with no
  #     pigeonhole. fetch_fails: fails as a fetch does, the file's one word being why (it writes
  #     var/pigeonhole-fetch.json as bin/collect does). fetch_code N: exits N instead.
  #   no arguments (a collection): says what collect_says holds (or that two comments wait), and exits collect_code
  #     (0). collect_busy_for N: the first N say a lock is held and exit 75.
  cat > "$S/collect" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/collect.calls"
if [ "$*" = "--fetch-only --notify" ]; then
  if [ -f "$STUB_DIR/starts" ]; then echo after >> "$STUB_DIR/fetch.when"; else echo before >> "$STUB_DIR/fetch.when"; fi
  if [ -f "$STUB_DIR/fetch_fails" ]; then
    printf '{"fetched_at":1,"ok":false,"fetched":0,"damaged":0,"left":0,"waiting":0,"reason":"%s"}\n' "$(cat "$STUB_DIR/fetch_fails")" > "$PWD/var/pigeonhole-fetch.json"
    echo "problem: The fetch: the pigeonhole's server couldn't be reached ($(cat "$STUB_DIR/fetch_fails"))."
    echo "a second line that is not logged"
    exit 1
  fi
  exit "$(cat "$STUB_DIR/fetch_code" 2>/dev/null || echo 0)"
fi
[ $# -eq 0 ] || { echo "unexpected: $*"; exit 99; }
echo "$PWD|${OFFPRINT_SITE-unset}" >> "$STUB_DIR/collect.where"
n="$(grep -c '^$' "$STUB_DIR/collect.calls")"
if [ -f "$STUB_DIR/collect_busy_for" ] && [ "$n" -le "$(cat "$STUB_DIR/collect_busy_for")" ]; then
  echo "problem: a publish is running, or left its lock (var/publish.lock); wait for it, then collect again."
  exit 75
fi
if [ -f "$STUB_DIR/collect_says" ]; then cat "$STUB_DIR/collect_says"; else echo "ok: 2 comments are waiting for you in WordPress's moderation queue."; fi
exit "$(cat "$STUB_DIR/collect_code" 2>/dev/null || echo 0)"
STUB
  chmod +x "$S/publish" "$S/collect"
}
ask_collect() { echo "2026-11-20T10:00:00Z ${1:-button}" > "$in/collect-request"; }
ask() { echo "2026-11-20T10:00:00Z ${1:-button}" > "$in/publish-request"; }
waiting() { if [ -e "$in/publish-request" ] || [ -L "$in/publish-request" ]; then echo yes; else echo no; fi; }
marker() { if [ -e "$c/var/publish-waiting" ]; then echo yes; else echo no; fi; }
# aged FILE MINUTES: FILE's mtime that many minutes ago (perl is on macOS and Ubuntu alike)
aged() { perl -e 'my $t = time - 60 * shift; utime $t, $t, @ARGV' "$2" "$1"; }
# agent [ENV=VALUE...]: runs the tool's agent for the site $c (OFFPRINT_SITE), from the case folder, in the
# foreground; sets code. Fast settings unless the case overrides them.
agent() {
  (cd "$tmp/case$n" && env STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_AGENT_PUBLISH="$S/publish" PUBLISH_AGENT_COLLECT="$S/collect" PUBLISH_AGENT_MIN_SECONDS=0 \
    PUBLISH_AGENT_BACKOFF_SECONDS=0.2 PUBLISH_AGENT_SETTLE_SECONDS=0 "$@" /bin/bash "$SRC/bin/publish-agent" > "$S/agent.out" 2>&1); code=$?
}
agent_lines() { grep -c ' agent: ' "$c/var/publish.log" 2>/dev/null || true; }
# leftovers: anything in var/ besides the inbox, the log and what the case put there
leftovers() { find "$c/var" -mindepth 1 -maxdepth 1 ! -name inbox ! -name publish.log; }

# --- one request: one run ---
newcase; ask "post 12"; agent; t="one request"
check "$t: one run" 1 "$(count "$S/runs")"
check "$t: the request is taken" no "$(waiting)"
check "$t: exits 0" 0 "$code"
check "$t: one line in the log" 1 "$(agent_lines)"
contains "$t: the line has the reason" "post 12" "$(cat "$c/var/publish.log")"
contains "$t: and when it was asked" "2026-11-20T10:00:00Z" "$(cat "$c/var/publish.log")"
check "$t: the line starts with the time" yes \
  "$(grep ' agent: ' "$c/var/publish.log" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' && echo yes)"
contains "$t: the run's error output is in the log" "error output from the run" "$(cat "$c/var/publish.log")"
check "$t: nothing on the agent's own output" "" "$(cat "$S/agent.out")"
check "$t: nothing left over in var/" "" "$(leftovers)"

# --- no request: no run, and nothing changes ---
newcase; agent; t="no request"
check "$t: no run" 0 "$(count "$S/starts")"
check "$t: exits 0" 0 "$code"
check "$t: var/ is left exactly as it was" "$in" "$(find "$c/var" -mindepth 1)"

# --- a request written during a run: exactly one more run ---
newcase; ask; ( agent ) & pid=$!
wait_for "$S/starts" 1; ask "during"; wait "$pid"; t="a request during a run"
check "$t: exactly one more run" 2 "$(count "$S/runs")"
check "$t: none left waiting" no "$(waiting)"
contains "$t: the second run's reason is logged" "during" "$(cat "$c/var/publish.log")"
newcase; ask; ( agent ) & pid=$!
wait_for "$S/starts" 1; ask one; ask two; ask three; wait "$pid"; t="three requests during a run"
check "$t: still one more run" 2 "$(count "$S/runs")"

# --- a burst of requests (a post saved, then its meta boxes) is one run ---
newcase; echo 0 > "$S/sleep"; ask first; ( agent PUBLISH_AGENT_SETTLE_SECONDS=2 ) & pid=$!
sleep 1; ask second; wait "$pid"; t="two requests a second apart"
check "$t: one run" 1 "$(count "$S/runs")"
check "$t: none left waiting" no "$(waiting)"
contains "$t: for the later one" "second" "$(grep ' agent: ' "$c/var/publish.log")"

# --- never two at once: bin/publish exits 75 when another publish holds the lock ---
newcase; ask; echo 2 > "$S/busy_for"; echo 0 > "$S/sleep"; agent; t="busy twice, then free"
check "$t: three tries" 3 "$(count "$S/starts")"
check "$t: one real run" 1 "$(count "$S/runs")"
check "$t: nothing waiting afterwards" "no no" "$(waiting) $(marker)"
check "$t: the wait is logged once" 1 "$(grep -c 'already running' "$c/var/publish.log")"
check "$t: nothing left over in var/" "" "$(leftovers)"
check "$t: nothing ever written in the inbox" "" "$(find "$in" -mindepth 1)"
newcase; ask; echo 12 > "$S/busy_for"; echo 0 > "$S/sleep"; agent PUBLISH_AGENT_BACKOFF_SECONDS=0.05; t="busy for more than 10 tries"
check "$t: refused starts don't use up the runs" "13 1" "$(count "$S/starts") $(count "$S/runs")"
newcase; ask; touch "$S/busy_text"; echo 0 > "$S/sleep"; agent; t="'already running' in the text, but exit 1"
check "$t: an ordinary failure: one try, no wait" "1 no" "$(count "$S/starts") $(marker)"
newcase; ask "post 7"; echo 999 > "$S/busy_for"; touch "$S/before"; sleep 1; start=$SECONDS
agent PUBLISH_AGENT_BACKOFF_SECONDS=0.3 PUBLISH_AGENT_BUSY_MAX_SECONDS=2; t="busy for longer than it waits"
check "$t: gives up after the wait (2 seconds here, 35 minutes really)" yes "$([ $((SECONDS - start)) -ge 2 ] && echo yes)"
check "$t: tried more than once" yes "$([ "$(count "$S/starts")" -ge 3 ] && echo yes)"
check "$t: no run" 0 "$(count "$S/runs")"
check "$t: the request waits in var/publish-waiting" yes "$(marker)"
contains "$t: with its reason" "post 7" "$(cat "$c/var/publish-waiting")"
check "$t: touched at each try, so WordPress doesn't call it stuck" yes "$([ -n "$(find "$c/var/publish-waiting" -newer "$S/before")" ] && echo yes)"
check "$t: nothing put back into the inbox" "" "$(find "$in" -mindepth 1)"
contains "$t: giving up is logged" "giving up" "$(cat "$c/var/publish.log")"
newcase; printf '2026-11-20T10:00:00Z post 3\n' > "$c/var/publish-waiting"; echo 0 > "$S/sleep"; agent; t="a request already waiting (the sweep, or at login)"
check "$t: one run" 1 "$(count "$S/runs")"
check "$t: no longer waiting" no "$(marker)"
contains "$t: with its reason" "(asked at 2026-11-20T10:00:00Z: post 3)" "$(cat "$c/var/publish.log")"
newcase; ask; echo 2 > "$S/busy_for"; touch "$S/plant"; echo 0 > "$S/sleep"; agent; t="a symlink to a folder planted while busy"
check "$t: nothing is created through it" "" "$(find "$S/target" -mindepth 1)"
check "$t: the waiting request is still served" 1 "$(count "$S/runs")"
check "$t: the link is removed" "no no" "$(waiting) $(marker)"
contains "$t: and logged" "was a symlink" "$(cat "$c/var/publish.log")"

# --- a request storm can't loop forever ---
newcase; ask; touch "$S/storm"; echo 0 > "$S/sleep"; agent; t="a request every run"
check "$t: 10 runs, then stops" 10 "$(count "$S/runs")"
check "$t: the last request is left for next time" yes "$([ -f "$in/publish-request" ] && echo yes)"
contains "$t: the stop is logged" "stopping after 10" "$(cat "$c/var/publish.log")"

# --- launchd throttles a job that exits within 10 seconds of starting: the agent stays that long, watching ---
newcase; ask; echo 0 > "$S/sleep"; start=$SECONDS; ( agent PUBLISH_AGENT_MIN_SECONDS=3 ) & pid=$!
wait_for "$S/runs" 1; sleep 1; ask "late"; wait "$pid"; t="a request soon after the last run"
check "$t: is still picked up" 2 "$(count "$S/runs")"
check "$t: the agent lived at least its minimum" yes "$([ $((SECONDS - start)) -ge 3 ] && echo yes)"
newcase; start=$SECONDS; agent PUBLISH_AGENT_MIN_SECONDS=2; t="no request, with a minimum"
check "$t: waits, then exits without a run" "yes 0" "$([ $((SECONDS - start)) -ge 2 ] && echo yes) $(count "$S/starts")"
check "$t: var/ still untouched" "$in" "$(find "$c/var" -mindepth 1)"

# --- what is in the request is data, not instructions ---
newcase; printf '2026-11-20T10:00:00Z post 12; rm -rf ~ $(touch pwned) `id` | sh & > x\nsecond line $(touch pwned2)\n' > "$in/publish-request"
echo 0 > "$S/sleep"; agent; t="shell metacharacters and newlines"; log="$(grep ' agent: ' "$c/var/publish.log")"
check "$t: still one run" 1 "$(count "$S/runs")"
check "$t: one line in the log" 1 "$(agent_lines)"
logged="${log##*Z: }"; logged="${logged%)}"   # the reason, as logged
check "$t: the reason, cleaned" "post 12 rm -rf  touch pwned id  sh   x" "$logged"
for ch in ';' '$' '(' '`' '|' '&' '>' '~'; do lacks "$t: no $ch in the reason" "$ch" "$logged"; done
lacks "$t: nothing from the second line" "second" "$(cat "$c/var/publish.log")"
check "$t: nothing ran" no "$(find "$tmp/case$n" -name 'pwned*' | grep -q . && echo yes || echo no)"
newcase; printf 'garbage with no time\n' > "$in/publish-request"; echo 0 > "$S/sleep"; agent; t="a request with no time"
check "$t: still runs" 1 "$(count "$S/runs")"
contains "$t: the whole line is the reason" "(asked: garbage with no time)" "$(cat "$c/var/publish.log")"
newcase; printf '2026-11-20T10:00:00Z\n' > "$in/publish-request"; echo 0 > "$S/sleep"; agent; t="a request with a time and no reason"
contains "$t: the reason is unknown" "(asked at 2026-11-20T10:00:00Z: unknown)" "$(cat "$c/var/publish.log")"

# --- the inbox is the container's to write, so the agent trusts nothing in it ---
outside="$tmp/outside"; mkdir -p "$outside/inbox"; echo "keep me" > "$outside/precious"
echo "2026-11-20T10:00:00Z button" > "$outside/inbox/publish-request"
# refused NAME: no run, the request gone, one line in the log saying so, the files outside untouched
refused() {
  check "$1: no run" 0 "$(count "$S/starts")"
  check "$1: removed" no "$(waiting)"
  check "$1: one line in the log" 1 "$(agent_lines)"
  check "$1: exits 0" 0 "$code"
  check "$1: the file outside var/ is untouched" "keep me" "$(cat "$outside/precious")"
  check "$1: so is the outside inbox" "2026-11-20T10:00:00Z button" "$(cat "$outside/inbox/publish-request")"
  check "$1: nothing left over in var/" "" "$(leftovers)"
}
newcase; ln -s "$outside/precious" "$in/publish-request"; agent; t="a request that is a symlink to a file outside var/"
refused "$t"; contains "$t: says why" "was a symlink" "$(cat "$c/var/publish.log")"
newcase; ln -s "$outside/inbox/publish-request" "$in/publish-request"; agent; t="a request that is a symlink to a good-looking request"
refused "$t"
newcase; rmdir "$in"; ln -s "$outside/inbox" "$in"; agent; t="an inbox that is a symlink"
refused "$t"; contains "$t: says why" "var/inbox was a symlink" "$(cat "$c/var/publish.log")"
check "$t: the link itself is gone" no "$([ -L "$in" ] || [ -e "$in" ] && echo yes || echo no)"
newcase; mkdir "$in/publish-request"; ln -s "$outside/precious" "$in/publish-request/link"; agent; t="a request that is a folder"
refused "$t"; contains "$t: says why" "not a plain file" "$(cat "$c/var/publish.log")"
newcase; mkfifo "$in/publish-request"; agent; t="a request that is a FIFO (and must not hang)"
refused "$t"
# sized N: a good request padded to exactly N bytes
sized() { { printf '2026-11-20T10:00:00Z button\n'; head -c $(($1 - 28)) /dev/zero | tr '\0' x; } > "$in/publish-request"; }
newcase; sized 1025; t="a request of 1025 bytes"
check "$t: control: 1025 bytes" 1025 "$(wc -c < "$in/publish-request" | tr -d ' ')"
agent
refused "$t"; contains "$t: says why" "larger than 1 KB" "$(cat "$c/var/publish.log")"
newcase; sized 1024; echo 0 > "$S/sleep"; check "a request of exactly 1 KB: control: 1024 bytes" 1024 "$(wc -c < "$in/publish-request" | tr -d ' ')"
agent; check "a request of exactly 1 KB: runs" 1 "$(count "$S/runs")"
newcase; printf '#!/bin/sh\ntouch "%s/ran"\n' "$S" > "$in/evil.sh"; chmod +x "$in/evil.sh"; cp "$in/evil.sh" "$in/publish-request.sh"
ask; echo 0 > "$S/sleep"; agent; t="other files in the inbox"
check "$t: the request still runs" 1 "$(count "$S/runs")"
check "$t: nothing in them ran" no "$([ -e "$S/ran" ] && echo yes || echo no)"
check "$t: they are left alone" "$in/evil.sh $in/publish-request.sh" "$(find "$in" -mindepth 1 | sort | paste -sd' ' -)"
newcase; for f in .publish-request.old1 .publish-request.new1 other; do echo x > "$in/$f"; done
aged "$in/.publish-request.old1" 11; aged "$in/other" 11; ln -s "$outside/precious" "$in/.publish-request.lnk"
agent; t="WordPress's temporary files left in the inbox"
check "$t: one older than 10 minutes is removed" no "$([ -e "$in/.publish-request.old1" ] && echo yes || echo no)"
check "$t: a new one, a link and anything else stay" "$in/.publish-request.lnk $in/.publish-request.new1 $in/other" \
  "$(find "$in" -mindepth 1 | sort | paste -sd' ' -)"
check "$t: the link's target is untouched" "keep me" "$(cat "$outside/precious")"
check "$t: no run" 0 "$(count "$S/starts")"

# --- the agent works in the site folder, and runs bin/publish there, for that site ---
phys() { (cd "$1" && pwd -P); }
newcase; ask; echo 0 > "$S/sleep"; agent; t="the agent's publish"
check "$t: runs in the site folder, with OFFPRINT_SITE set to it" "$(phys "$c")|$(phys "$c")" "$(cat "$S/where")"
newcase; ask; echo 0 > "$S/sleep"
(cd "$tmp/case$n" && env STUB_DIR="$S" OFFPRINT_SITE=repo PUBLISH_AGENT_PUBLISH="$S/publish" PUBLISH_AGENT_MIN_SECONDS=0 \
  PUBLISH_AGENT_SETTLE_SECONDS=0 /bin/bash "$SRC/bin/publish-agent" > "$S/agent.out" 2>&1); code=$?; t="OFFPRINT_SITE given as a relative path"
check "$t: one run" 1 "$(count "$S/runs")"
check "$t: the publish gets the absolute path" "$(phys "$c")|$(phys "$c")" "$(cat "$S/where")"
newcase; ask; echo 0 > "$S/sleep"; mkdir -p "$c/wp-content/plugins"
(cd "$c/wp-content/plugins" && env -u OFFPRINT_SITE STUB_DIR="$S" PUBLISH_AGENT_PUBLISH="$S/publish" PUBLISH_AGENT_MIN_SECONDS=0 \
  PUBLISH_AGENT_SETTLE_SECONDS=0 /bin/bash "$SRC/bin/publish-agent" > "$S/agent.out" 2>&1); code=$?; t="started in a folder inside the site, no OFFPRINT_SITE"
check "$t: finds the site above: one run" 1 "$(count "$S/runs")"
check "$t: in the site folder, for the site" "$(phys "$c")|$(phys "$c")" "$(cat "$S/where")"
check "$t: the request is taken" no "$(waiting)"
newcase; mkdir -p "$tmp/case$n/nosite"; t="outside any site folder"
out="$(cd "$tmp/case$n/nosite" && env -u OFFPRINT_SITE STUB_DIR="$S" PUBLISH_AGENT_PUBLISH="$S/publish" /bin/bash "$SRC/bin/publish-agent" 2>&1)"; code=$?
check "$t: exits 2" 2 "$code"
check "$t: says so" "Not in an Offprint site folder (no site.json here or above); cd into one, or set OFFPRINT_SITE." "$out"
check "$t: runs nothing" 0 "$(count "$S/starts")"
check "$t: makes nothing" "" "$(find "$tmp/case$n/nosite" -mindepth 1)"
# It needs only the site folder, not site.json's values: it never runs php itself (a stand-in php here would note it).
# (What it runs, bin/publish and bin/collect, each reads site.json: both are stand-ins here.)
newcase; ask; echo 0 > "$S/sleep"; mkdir -p "$S/bin"; printf '#!/bin/sh\ntouch "%s/php-ran"\nexit 1\n' "$S" > "$S/bin/php"; chmod +x "$S/bin/php"
agent PATH="$S/bin:$PATH"; t="with a php that only notes it was run"
check "$t: one run" 1 "$(count "$S/runs")"; check "$t: php never ran" no "$([ -e "$S/php-ran" ] && echo yes || echo no)"
# Without PUBLISH_AGENT_PUBLISH it runs the tool's own bin/publish (here a copy of the tool, with a stand-in there).
newcase; ask; echo 0 > "$S/sleep"; tool="$tmp/case$n/tool"; mkdir -p "$tool/bin" "$tool/lib"
cp "$SRC/bin/publish-agent" "$tool/bin/"; cp "$SRC/lib/site.sh" "$tool/lib/"; cp "$S/publish" "$tool/bin/publish"
(cd "$tmp/case$n" && env -u PUBLISH_AGENT_PUBLISH STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_AGENT_MIN_SECONDS=0 PUBLISH_AGENT_SETTLE_SECONDS=0 \
  /bin/bash "$tool/bin/publish-agent" > "$S/agent.out" 2>&1); code=$?; t="no PUBLISH_AGENT_PUBLISH"
check "$t: runs the tool's bin/publish once" 1 "$(count "$S/runs")"
check "$t: in the site folder, for the site" "$(phys "$c")|$(phys "$c")" "$(cat "$S/where")"
check "$t: exits 0" 0 "$code"
# The real bin/publish, for a site whose site.json it can't use: the publish fails and says so in var/status.json, so
# the "live" there from before doesn't stay (the admin bar would go on saying Live), and the request isn't lost
# silently: it is taken once that failure is written. (A stand-in docker notes any call.)
newcase; ask; sed 's/^{/{"colour":"red",/' "$SRC/tests/fixtures/site.json" > "$c/site.json"
printf '{"state":"live","running":false,"at":"2026-11-20T10:00:00Z","commit":"abc1234","message":"The site is live at abc1234.","warnings":[]}\n' > "$c/var/status.json"
mkdir -p "$S/bin"; printf '#!/bin/sh\necho "$*" >> "%s/docker.calls"\nexit 1\n' "$S" > "$S/bin/docker"; chmod +x "$S/bin/docker"
agent PATH="$S/bin:$PATH" PUBLISH_AGENT_PUBLISH="$SRC/bin/publish"; t="the real bin/publish, for a site.json it can't use"
# st KEY: that key of var/status.json (true and false as words), or "invalid"
st() {
  php -r '$j = json_decode( (string) file_get_contents( $argv[1] ), true ); if ( ! is_array( $j ) ) { echo "invalid"; exit; }
    $v = $j[ $argv[2] ] ?? null; echo is_bool( $v ) ? ( $v ? "true" : "false" ) : (string) $v;' "$c/var/status.json" "$1"
}
check "$t: the agent exits 0" 0 "$code"
check "$t: the status is failed, not the live from before" failed "$(st state)"
check "$t: and not running" false "$(st running)"
check "$t: it says why" 'site.json has a problem: site.json: "colour" is not a known field; nothing was published.' "$(st message)"
contains "$t: the log has the agent's line" "agent: publishing (asked at 2026-11-20T10:00:00Z: button)" "$(cat "$c/var/publish.log")"
contains "$t: and the publish's" "[failed] site.json has a problem" "$(cat "$c/var/publish.log")"
check "$t: docker never called" no "$([ -e "$S/docker.calls" ] && echo yes || echo no)"
check "$t: the request is taken, the failure written" no "$(marker)"
check "$t: the lock is released" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"

# --- install-agent (os/darwin/install-agent, which offprint install-agent runs) ---
# It is the tool's own, run in place for a throwaway site folder. The site folder's path has a space and an ampersand
# (".../My Sites/a&b"), so the plist's XML escaping is tested too.
newi() {
  n=$((n + 1)); r="$tmp/case $n/My Sites/a&b"; S="$tmp/case$n/stubs"
  mkdir -p "$r" "$S/bin" "$S/tools" "$S/home"
  cp "$SRC/tests/fixtures/site.json" "$r/site.json"
  for tool in docker git php; do printf '#!/bin/sh\n' > "$S/tools/$tool"; chmod +x "$S/tools/$tool"; done
  # stand-ins: launchctl only notes what it was asked; id can pretend to be root
  printf '#!/bin/sh\necho "$*" >> "%s/launchctl.calls"\n[ "$1" = bootstrap ] && [ -f "%s/bootstrap_fails" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }\nexit 0\n' "$S" "$S" > "$S/bin/launchctl"
  printf '#!/bin/sh\n[ "$1" = -u ] && [ -f "%s/root" ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' "$S" > "$S/bin/id"
  chmod +x "$S/bin/launchctl" "$S/bin/id"
}
# install [ARGS...]: install-agent, run from the site folder $r (no OFFPRINT_SITE), with the stand-ins first on PATH
# and a throwaway HOME; sets out, code
install() {
  out="$(cd "$r" && env -u OFFPRINT_SITE PATH="$S/bin:$PATH" HOME="$S/home" INSTALL_AGENT_PATH="$S/tools" /bin/bash "$SRC/os/darwin/install-agent" "$@" 2>&1)"; code=$?
}
real="$(cd "$SRC" && pwd -P)"
xml_of() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
LABEL=local.offprint.example.publish   # the fixture's name, with the default agent_label

newi; out="$(cd "$r" && env -u OFFPRINT_SITE HOME="$S/home" /bin/bash "$SRC/os/darwin/install-agent" --print 2>&1)"; code=$?; t="--print"
check "$t: exits 0" 0 "$code"
rr="$(xml_of "$(cd "$r" && pwd -P)")"; tt="$(xml_of "$real")"
contains "$t: the site folder's path, XML-escaped" "/My Sites/a&amp;b" "$out"
contains "$t: the label (site.json's agent_label: here the default)" "<key>Label</key><string>$LABEL</string>" "$out"
contains "$t: runs the tool's agent with /bin/bash" "<string>/bin/bash</string><string>$tt/bin/publish-agent</string>" "$out"
contains "$t: tells it the site folder" "<key>OFFPRINT_SITE</key><string>$rr</string>" "$out"
contains "$t: watches the site's inbox folder" "<key>WatchPaths</key>
  <array><string>$rr/var/inbox</string></array>" "$out"
contains "$t: and looks every 5 minutes anyway" "<key>StartInterval</key><integer>300</integer>" "$out"
contains "$t: works in the site folder" "<key>WorkingDirectory</key><string>$rr</string>" "$out"
contains "$t: logs to the site's var/publish.log" "<key>StandardOutPath</key><string>$rr/var/publish.log</string>" "$out"
contains "$t: errors too" "<key>StandardErrorPath</key><string>$rr/var/publish.log</string>" "$out"
contains "$t: the PATH" "<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>" "$out"
contains "$t: not at load" "<key>RunAtLoad</key><false/>" "$out"
contains "$t: the throttle it allows for" "<key>ThrottleInterval</key><integer>10</integer>" "$out"
check "$t: changes nothing" "no no" "$([ -e "$r/var" ] && echo yes || echo no) $([ -e "$S/home/Library" ] && echo yes || echo no)"
if command -v plutil >/dev/null 2>&1; then
  printf '%s\n' "$out" > "$S/print.plist"
  check "$t: passes plutil -lint" 0 "$(plutil -lint "$S/print.plist" >/dev/null 2>&1; echo $?)"
  check "$t: the watched path, read back by plutil" "$(cd "$r" && pwd -P)/var/inbox" "$(plutil -extract WatchPaths.0 raw -o - "$S/print.plist")"
  check "$t: OFFPRINT_SITE, read back by plutil (with its &)" "$(cd "$r" && pwd -P)" "$(plutil -extract EnvironmentVariables.OFFPRINT_SITE raw -o - "$S/print.plist")"
  check "$t: the agent, read back by plutil" "$real/bin/publish-agent" "$(plutil -extract ProgramArguments.1 raw -o - "$S/print.plist")"
  check "$t: PATH, read back by plutil" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$(plutil -extract EnvironmentVariables.PATH raw -o - "$S/print.plist")"
  check "$t: StartInterval, read back by plutil" 300 "$(plutil -extract StartInterval raw -o - "$S/print.plist")"
else
  skip "$t: plutil -lint and read-back (no plutil: not macOS)"
fi
# offprint install-agent --print, with OFFPRINT_SITE, from somewhere else: the same plist
out2="$(cd "$tmp" && OFFPRINT_SITE="$r" HOME="$S/home" /bin/bash "$SRC/bin/offprint" install-agent --print 2>&1)"; code=$?
t="offprint install-agent --print, with OFFPRINT_SITE"
check "$t: exits 0" 0 "$code"; check "$t: the same plist" "$out" "$out2"
# a label of the site's own (agent_label in site.json)
newi; printf '{"format":1,"name":"example","public_url":"https://www.example.com","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998,"agent_label":"com.example.agent-test"}\n' > "$r/site.json"
install --print; t="--print, with agent_label in site.json"
check "$t: exits 0" 0 "$code"; contains "$t: the configured label" "<key>Label</key><string>com.example.agent-test</string>" "$out"
lacks "$t: not the default" "local.offprint.example.publish" "$out"
newi; mkdir -p "$tmp/case$n/nosite"; t="outside any site folder"
out="$(cd "$tmp/case$n/nosite" && env -u OFFPRINT_SITE HOME="$S/home" /bin/bash "$SRC/os/darwin/install-agent" --print 2>&1)"; code=$?
check "$t: exits 2" 2 "$code"; check "$t: says so" "Not in an Offprint site folder (no site.json here or above); cd into one, or set OFFPRINT_SITE." "$out"

newi; touch "$S/root"; install --print; t="as root"
check "$t: refuses" 1 "$code"; contains "$t: says why" "not with sudo" "$out"; lacks "$t: prints no plist" "<plist" "$out"
install; check "$t: refuses to install" 1 "$code"
check "$t: launchctl never called" no "$([ -e "$S/launchctl.calls" ] && echo yes || echo no)"

newi; install --bogus; check "an unknown option: usage" 2 "$code"; contains "an unknown option: says how" "usage: offprint install-agent" "$out"

if command -v plutil >/dev/null 2>&1; then
  newi; t="install (stand-in launchctl, throwaway HOME)"
  if [ "$(PATH="$S/bin:$PATH" command -v launchctl)" != "$S/bin/launchctl" ]; then
    bad "$t: the stand-in launchctl isn't first on PATH; not running this case"
  else
    install; uid="$(id -u)"; plist="$S/home/Library/LaunchAgents/$LABEL.plist"
    check "$t: exits 0" 0 "$code"
    check "$t: the plist is in ~/Library/LaunchAgents, named for the label" yes "$([ -f "$plist" ] && echo yes)"
    check "$t: it passes plutil -lint" 0 "$(plutil -lint "$plist" >/dev/null 2>&1; echo $?)"
    check "$t: the PATH it checked is the one it wrote" "$S/tools" "$(plutil -extract EnvironmentVariables.PATH raw -o - "$plist")"
    check "$t: OFFPRINT_SITE is the site folder" "$(cd "$r" && pwd -P)" "$(plutil -extract EnvironmentVariables.OFFPRINT_SITE raw -o - "$plist")"
    check "$t: var/inbox made" yes "$([ -d "$r/var/inbox" ] && [ ! -L "$r/var/inbox" ] && echo yes)"
    check "$t: an earlier copy unloaded, then enabled and loaded" \
      "bootout gui/$uid/$LABEL|enable gui/$uid/$LABEL|bootstrap gui/$uid $plist" \
      "$(paste -sd'|' "$S/launchctl.calls")"
    contains "$t: says so" "Installed and loaded $LABEL" "$out"
    : > "$S/launchctl.calls"; install; t="installed again, for the same site"
    check "$t: exits 0" 0 "$code"; check "$t: loaded again" 3 "$(count "$S/launchctl.calls")"
    # Another site folder with the same site.json, so the same label: that plist is the first site's agent.
    r2="$tmp/case $n/other site"; mkdir -p "$r2"; cp "$r/site.json" "$r2/site.json"; cp "$plist" "$S/first.plist"
    install2() { out="$(cd "$r2" && env -u OFFPRINT_SITE PATH="$S/bin:$PATH" HOME="$S/home" INSTALL_AGENT_PATH="$S/tools" /bin/bash "$SRC/os/darwin/install-agent" "$@" 2>&1)"; code=$?; }
    : > "$S/launchctl.calls"; install2; t="another site folder with the same label"
    check "$t: refuses" 1 "$code"
    contains "$t: names the other site folder" "$(cd "$r" && pwd -P)" "$out"; contains "$t: and this one" "$(cd "$r2" && pwd -P)" "$out"
    contains "$t: and the way out" "agent_label" "$out"
    check "$t: the first site's plist is untouched" same "$(cmp -s "$S/first.plist" "$plist" && echo same)"
    check "$t: launchctl never called" "" "$(cat "$S/launchctl.calls")"
    install2 --remove; check "$t: --remove refuses too" 1 "$code"
    check "$t: --remove leaves it" same "$(cmp -s "$S/first.plist" "$plist" && echo same)"
    check "$t: --remove never calls launchctl" "" "$(cat "$S/launchctl.calls")"
    install2 --force; check "$t: --force replaces it" 0 "$code"
    check "$t: --force: now for this site" "$(cd "$r2" && pwd -P)" "$(plutil -extract EnvironmentVariables.OFFPRINT_SITE raw -o - "$plist")"
    : > "$S/launchctl.calls"; install --remove; t="--remove"
    check "$t: refuses for the first site now" 1 "$code"
    install2 --remove; t="--remove, for the site it belongs to"
    check "$t: exits 0" 0 "$code"
    check "$t: unloads it" "bootout gui/$uid/$LABEL" "$(cat "$S/launchctl.calls")"
    check "$t: deletes the plist" no "$([ -e "$plist" ] && echo yes || echo no)"
    # An agent from before OFFPRINT_SITE, for another folder: its WorkingDirectory says whose it is.
    mkdir -p "$(dirname "$plist")"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n  <key>Label</key><string>%s</string>\n  <key>WorkingDirectory</key><string>%s</string>\n</dict>\n</plist>\n' "$LABEL" "$tmp/someone-elses-blog" > "$plist"
    cp "$plist" "$S/old.plist"; : > "$S/launchctl.calls"; install; t="an older agent with the same label, working in another folder"
    check "$t: refuses" 1 "$code"; contains "$t: names that folder" "$tmp/someone-elses-blog" "$out"
    check "$t: leaves it" same "$(cmp -s "$S/old.plist" "$plist" && echo same)"
    check "$t: launchctl never called" "" "$(cat "$S/launchctl.calls")"
  fi
  newi; touch "$S/bootstrap_fails"; install; t="launchctl bootstrap fails"
  check "$t: exits non-zero" 1 "$code"; contains "$t: says what to try" "Allow in the Background" "$out"
  contains "$t: and to run it again" "Run offprint install-agent again" "$out"
  newi; mkdir -p "$r/var/publish.lock"; install; t="a publish is running (var/publish.lock)"
  check "$t: refuses" 1 "$code"; contains "$t: says why" "--force" "$out"
  check "$t: launchctl never called" no "$([ -e "$S/launchctl.calls" ] && echo yes || echo no)"
  install --remove; check "$t: --remove refuses too" 1 "$code"
  install --force; check "$t: --force installs anyway" 0 "$code"
  install --remove --force; check "$t: --remove --force removes anyway" 0 "$code"
  newi; mkdir -p "$r/var" "$S/elsewhere"; ln -s "$S/elsewhere" "$r/var/inbox"; install; t="var/inbox is a symlink"
  check "$t: refuses" 1 "$code"; contains "$t: says why" "symlink" "$out"
  check "$t: launchctl never called" no "$([ -e "$S/launchctl.calls" ] && echo yes || echo no)"
  newi; rm "$S/tools/docker" "$S/tools/php"; install; t="docker and php not on the agent's PATH"
  check "$t: refuses" 1 "$code"; contains "$t: names them" "docker php" "$out"
  check "$t: launchctl never called" no "$([ -e "$S/launchctl.calls" ] && echo yes || echo no)"
else
  skip "install and --remove with a stand-in launchctl (no plutil: not macOS)"
fi

# --- the PATH clean-up (lib/site.sh): look-alikes WordPress could put in wp-content/ never run ---
# bin/publish-agent and install-agent, each run from inside the site folder's wp-content/, which holds look-alikes of
# bash, dirname, php, mktemp, git, docker, curl, readlink and env (each noting that it ran), with the PATH reaching
# there through . first, an empty entry first, relative entries, its absolute path, and a link outside the site folder;
# both as /bin/bash SCRIPT and by its own #! line. None runs, the entries left out are named in one line, and the
# command does what it does. (launchd runs the agent with its plist's PATH: the clean-up is the same there.)
plant() {  # plant DIR: the look-alikes in DIR
  local p; mkdir -p "$1"
  for p in bash dirname php mktemp git docker curl readlink env; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$1/$p"; chmod +x "$1/$p"
  done
}
# variant KIND SITE BASE: vpath, the PATH (KIND's way to SITE/wp-content/, then BASE), and vleft, what the line names
variant() {
  case "$1" in
    dot) vpath=".:$3"; vleft="'.'" ;;
    empty) vpath=":$3"; vleft="''" ;;
    relative) vpath="wp-content:../wp-content:$3"; vleft="'wp-content' '../wp-content'" ;;
    absolute) vpath="$2/wp-content:$3"; vleft="'$2/wp-content'" ;;
    link) rm -f "$tmp/case$n/wplink"; ln -s "$2/wp-content" "$tmp/case$n/wplink"; vpath="$tmp/case$n/wplink:$3"; vleft="'$tmp/case$n/wplink'" ;;
  esac
}
# planted_ok T TEXT: no look-alike ran, and TEXT has one line (one only) naming what was left out of the PATH
planted_ok() {
  check "$1: no look-alike in wp-content/ ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
  check "$1: one line says what was left out of the PATH" 1 "$(printf '%s\n' "$2" | grep -c 'PATH entries left out')"
  contains "$1: naming it" "$vleft" "$(printf '%s\n' "$2" | grep 'PATH entries left out')"
  rm -f "$tmp/planted.ran"
}
base="$PATH"
newcase; plant "$c/wp-content"; echo 0 > "$S/sleep"; cphys="$(cd "$c" && pwd -P)"
for kind in dot empty relative absolute link; do
  for how in bash direct; do
    if [ "$how" = bash ]; then runner=/bin/bash; else runner=""; fi
    variant "$kind" "$c" "$base"; ask "path $kind"; runs0="$(count "$S/runs")"
    (cd "$c/wp-content" && env -u OFFPRINT_SITE PATH="$vpath" STUB_DIR="$S" PUBLISH_AGENT_PUBLISH="$S/publish" PUBLISH_AGENT_MIN_SECONDS=0 \
      PUBLISH_AGENT_BACKOFF_SECONDS=0.2 PUBLISH_AGENT_SETTLE_SECONDS=0 ${runner:+"$runner"} "$SRC/bin/publish-agent" > "$S/agent.out" 2>&1); code=$?
    t="bin/publish-agent ($how), look-alikes in wp-content/, run there, PATH $kind"
    planted_ok "$t" "$(cat "$S/agent.out")"
    check "$t: the request taken, one run, in the site folder, for it" "0|$((runs0 + 1))|no|$cphys|$cphys" \
      "$code|$(count "$S/runs")|$(waiting)|$(tail -n 1 "$S/where")"
  done
done
newi; plant "$r/wp-content"; rphys="$(cd "$r" && pwd -P)"
for kind in dot empty relative absolute link; do
  for how in bash direct; do
    if [ "$how" = bash ]; then runner=/bin/bash; else runner=""; fi
    variant "$kind" "$r" "$base"
    out="$(cd "$r/wp-content" && env -u OFFPRINT_SITE PATH="$vpath" HOME="$S/home" ${runner:+"$runner"} "$SRC/os/darwin/install-agent" --print 2>&1)"; code=$?
    t="install-agent --print ($how), look-alikes in wp-content/, run there, PATH $kind"
    planted_ok "$t" "$out"
    check "$t: the plist, for this site" "0|1|1" "$code|$(printf '%s\n' "$out" | grep -c "<key>Label</key><string>$LABEL</string>")|$(printf '%s\n' "$out" | grep -c "<key>OFFPRINT_SITE</key><string>$(xml_of "$rphys")</string>")"
  done
done

# === comments: a fetch on every start, and a collection when WordPress asks ===
calls() { if [ -f "$S/collect.calls" ]; then tr '\n' '|' < "$S/collect.calls"; fi; }
collect_lines() { grep -c ' agent: comments: ' "$c/var/publish.log" 2>/dev/null || true; }
newcase; agent; t="a start with no request"
check "$t: it fetches, once, opening nothing" "--fetch-only --notify|" "$(calls)"
check "$t: no publish, no collection" "0" "$(count "$S/starts")"
check "$t: a fetch that works is not logged" 0 "$(agent_lines | grep . || echo 0)"
check "$t: var/ is left exactly as it was" "$in" "$(find "$c/var" -mindepth 1)"
newcase; ask "post 12"; echo 0 > "$S/sleep"; agent; t="a start with a publish request"
check "$t: one fetch, and it came before the publish" "--fetch-only --notify| before" "$(calls) $(cat "$S/fetch.when")"
check "$t: the publish ran" 1 "$(count "$S/runs")"
newcase; ask; ask; echo 0 > "$S/sleep"; touch "$S/storm"; agent; t="a start that runs ten publishes"
check "$t: still one fetch" 1 "$(grep -c -- '--fetch-only' "$S/collect.calls")"

newcase; ask "post 12"; echo 0 > "$S/sleep"; echo unreachable > "$S/fetch_fails"; agent; t="the fetch fails"
check "$t: logged, in one line: collect's own first line" 1 "$(grep -c " agent: fetching comments: problem: The fetch: the pigeonhole's server couldn't be reached (unreachable).\$" "$c/var/publish.log")"
check "$t: its second line is not logged" 0 "$(grep -c 'a second line' "$c/var/publish.log")"
check "$t: the publish runs all the same" 1 "$(count "$S/runs")"
check "$t: exits 0" 0 "$code"
# (a start within four minutes of a fetch doesn't fetch: the later starts here are five minutes on)
later() { aged "$c/var/pigeonhole-fetch.json" 5; }
later; agent; later; agent; t="the fetch fails again, the same way, on later starts"
check "$t: it was tried each time" 3 "$(grep -c -- '--fetch-only' "$S/collect.calls")"
check "$t: and not logged again (a Mac that is offline wakes this every five minutes)" 1 "$(grep -c ' agent: fetching comments: ' "$c/var/publish.log")"
echo locked > "$S/fetch_fails"; later; agent; t="then fails another way"
check "$t: that is logged" 2 "$(grep -c ' agent: fetching comments: ' "$c/var/publish.log")"
rm "$S/fetch_fails"; printf '{"fetched_at":2,"ok":true,"fetched":0,"damaged":0,"left":0,"waiting":0,"reason":""}\n' > "$c/var/pigeonhole-fetch.json"; later; agent
echo locked > "$S/fetch_fails"; later; agent; t="then works, then fails as before"
check "$t: logged again: it had mended" 3 "$(grep -c ' agent: fetching comments: ' "$c/var/publish.log")"
# WordPress can start the agent as often as it writes to the inbox: that must not be a fetch each time.
newcase; printf '{"fetched_at":2,"ok":true,"fetched":0,"damaged":0,"left":0,"waiting":0,"reason":""}\n' > "$c/var/pigeonhole-fetch.json"
ask_collect; agent; t="a start within four minutes of the last fetch"
check "$t: no fetch; the collection that was asked for still runs" "|" "$(calls)"
aged "$c/var/pigeonhole-fetch.json" 5; agent; t="a start five minutes after it"
check "$t: it fetches" "|--fetch-only --notify|" "$(calls)"
newcase; ln -s "$S/elsewhere" "$c/var/pigeonhole-fetch.json"; : > "$S/elsewhere"; agent; t="a fetch status that is a new link"
check "$t: not taken for a fetch just made: it fetches" "--fetch-only --notify|" "$(calls)"
for rc in 75 2 127; do
  newcase; echo "$rc" > "$S/fetch_code"; agent
  check "a fetch that ends $rc (another run has the spool; site.json; no collect): not logged, and the agent goes on" "0 0" "$(agent_lines | grep . || echo 0) $code"
done
newcase; echo unreachable > "$S/fetch_fails"; ln -s "$S/elsewhere" "$c/var/pigeonhole-fetch.json"; : > "$S/elsewhere"; agent; t="the fetch's status file is a link"
check "$t: it is not read: the failure is logged" 1 "$(grep -c ' agent: fetching comments: ' "$c/var/publish.log")"

newcase; ask_collect; agent; t="WordPress asks for a collection"
check "$t: the fetch, then one collection" "--fetch-only --notify||" "$(calls)"
check "$t: in the site folder, for the site" "$(phys "$c")|$(phys "$c")" "$(cat "$S/collect.where")"
check "$t: the request is taken" "" "$(find "$in" -mindepth 1)"
check "$t: exits 0" 0 "$code"
check "$t: logged when it started, with when and why it was asked" 1 "$(grep -c ' agent: checking for comments (asked at 2026-11-20T10:00:00Z: button)$' "$c/var/publish.log")"
check "$t: and what collect said: counts, in its own words" 1 "$(grep -c " agent: comments: ok: 2 comments are waiting for you in WordPress's moderation queue.\$" "$c/var/publish.log")"
check "$t: no publish ran" 0 "$(count "$S/starts")"
check "$t: nothing left over in var/" "" "$(leftovers)"
newcase; ask_collect; ask "post 3"; echo 0 > "$S/sleep"; agent; t="a publish and a collection both asked for"
check "$t: both run, once each" "1 1" "$(count "$S/runs") $(grep -c '^$' "$S/collect.calls")"
check "$t: nothing left over in var/" "" "$(leftovers)"
newcase; ask_collect; echo "problem: 1 submission couldn't be taken this time and is still in the spool; nothing is lost: collect again." > "$S/collect_says"; echo 1 > "$S/collect_code"; agent; t="the collection ends with a problem"
check "$t: logged, and the request is done with" "1 " "$(grep -c " agent: comments: problem: 1 submission couldn't be taken" "$c/var/publish.log") $(leftovers)"
check "$t: one try" 1 "$(grep -c '^$' "$S/collect.calls")"
newcase; ask_collect; : > "$S/collect_says"; echo 3 > "$S/collect_code"; agent; t="collect says nothing"
check "$t: that is logged, with its status" 1 "$(grep -c ' agent: comments: offprint collect said nothing (it ended with status 3)$' "$c/var/publish.log")"
newcase; ask_collect; printf 'ok: \033[31mred\001 %s\nsecond line\n' "$(printf 'x%.0s' $(seq 1 400))" > "$S/collect_says"; agent; t="collect's line has control characters and is long"
line="$(grep ' agent: comments: ' "$c/var/publish.log")"
check "$t: no control character reaches the log, and no second line" "0 0" "$(printf '%s' "$line" | LC_ALL=C grep -c '[[:cntrl:]]') $(grep -c 'second line' "$c/var/publish.log")"
check "$t: it is cut to 300 characters" 300 "$(printf '%s' "${line#* agent: comments: }" | wc -c | tr -d ' ')"

newcase; ask_collect; echo 2 > "$S/collect_busy_for"; agent PUBLISH_AGENT_BACKOFF_SECONDS=0.05; t="a publish holds the lock for two tries"
check "$t: tried three times, and done" "3 " "$(grep -c '^$' "$S/collect.calls") $(leftovers)"
check "$t: logged once that it is waiting" 1 "$(grep -c ' agent: a publish or a fetch is running; trying again every 0.05 seconds' "$c/var/publish.log")"
check "$t: started once in the log, answered once" "1 1" "$(grep -c ' agent: checking for comments' "$c/var/publish.log") $(collect_lines)"
newcase; ask_collect; echo 999 > "$S/collect_busy_for"; agent PUBLISH_AGENT_BACKOFF_SECONDS=0.05 PUBLISH_AGENT_BUSY_MAX_SECONDS=1; t="the lock is held too long"
check "$t: it gives up, and the request waits in var/ for the next start" "1 yes" "$(grep -c ' agent: giving up for now: a lock has been held' "$c/var/publish.log") $([ -f "$c/var/collect-waiting" ] && echo yes || echo no)"
rm "$S/collect_busy_for"; agent
check "$t, then the next start: it runs, and is done" "1 " "$(collect_lines) $(leftovers)"

newcase; mkdir -p "$S/target"; echo keep > "$S/target/file"; ln -s "$S/target" "$in/collect-request"; agent; t="a collect request that is a symlink to a folder"
check "$t: no collection" 0 "$(grep -c '^$' "$S/collect.calls")"
check "$t: removed, and logged" "1" "$(grep -c ' agent: var/inbox/collect-request was a symlink, so it was removed and nothing ran$' "$c/var/publish.log")"
check "$t: what it pointed at is untouched" keep "$(cat "$S/target/file")"
check "$t: nothing left over" "" "$(find "$in" -mindepth 1)$(leftovers)"
newcase; mkdir "$in/collect-request"; echo x > "$in/collect-request/file"; agent; t="a collect request that is a folder"
check "$t: no collection; removed, and logged" "0 1" "$(grep -c '^$' "$S/collect.calls") $(grep -c ' agent: var/inbox/collect-request was not a plain file, so it was removed and nothing ran$' "$c/var/publish.log")"
newcase; head -c 2000 /dev/zero | tr '\0' 'a' > "$in/collect-request"; agent; t="a collect request larger than 1 KB"
check "$t: no collection; removed, and logged" "0 1" "$(grep -c '^$' "$S/collect.calls") $(grep -c ' agent: var/inbox/collect-request was larger than 1 KB, so it was removed and nothing ran$' "$c/var/publish.log")"
newcase; printf '2026-11-20T10:00:00Z $(touch %s/pwned) `id` ; rm -rf /\n' "$S" > "$in/collect-request"; agent; t="a collect request with a shell's words in it"
check "$t: nothing of it runs; only its letters reach the log" "no 1" "$([ -e "$S/pwned" ] && echo yes || echo no) $(grep -c ' agent: checking for comments (asked at 2026-11-20T10:00:00Z: touch' "$c/var/publish.log")"
check "$t: collect is given no word of it" "--fetch-only --notify||" "$(calls)"
newcase; echo x > "$in/.collect-request.abc123"; aged "$in/.collect-request.abc123" 11; echo y > "$in/.collect-request.new"; agent; t="WordPress's temporary files for a collect request"
check "$t: one left for over ten minutes is removed, a new one kept" ".collect-request.new" "$(ls -A "$in")"
newcase; i=0; ( while [ "$i" -lt 40 ]; do ask_collect; i=$((i + 1)); sleep 0.05; done ) & writer=$!
agent PUBLISH_AGENT_MIN_SECONDS=1; wait "$writer"; t="a stream of collect requests"
runs_now="$(grep -c '^$' "$S/collect.calls")"
if [ "$runs_now" -ge 1 ] && [ "$runs_now" -le 10 ]; then ok "$t: at most ten collections in one start ($runs_now)"; else bad "$t: $runs_now collections"; fi

exit "$fail"
