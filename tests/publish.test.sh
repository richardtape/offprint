#!/usr/bin/env bash
# Tests bin/publish, and bin/offprint, the command that runs it. Every case runs the tool's own scripts, in place,
# for a throwaway site folder (tests/fixtures/site.json, its own git repo, a bare repo as origin, stand-in `docker`
# and `curl` first on PATH), so this never touches this repo's git state, a real site, the real Docker or the network.
# Run: bash tests/publish.test.sh   (macOS bash 3.2 and Linux)
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE PUBLISH_CHECK_URL
# Git behaves here as it does on any Mac or CI runner: no user or system config (no default branch name, no
# identity, no excludes file), and every repo below names its branch and its committer itself.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR).
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-publish-test.XXXXXX")"; trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
contains() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no '$2' in '$3')"; fi; }

sleep 0 & dead=$!; wait "$dead" 2>/dev/null   # the pid of a process that has finished
n=0
# --- one throwaway site folder: $c (the tool that publishes it: $T, this repo unless the case copies it) ---
# newcase [NAME]: the site folder is $tmp/caseN/NAME (default "repo")
newcase() {
  n=$((n + 1)); c="$tmp/case$n/${1:-repo}"; S="$tmp/case$n/stubs"; O="$tmp/case$n/origin.git"; T="$SRC"
  mkdir -p "$c/site" "$c/backup" "$c/wp-content" "$c/var" "$S/bin" "$S/fixture/feed" "$S/fixture/hello"
  # The site's host: tests/fixtures/adapters/workflow (build.json, written by a deploy workflow), an adapter outside
  # the tool, in the site's own adapters/ folder, committed below, and named in its site.json.
  sed 's/"format": 1,/"format": 1, "adapter": {"name": "workflow"},/' "$SRC/tests/fixtures/site.json" > "$c/site.json"
  mkdir -p "$c/adapters/workflow"; cp "$SRC/tests/fixtures/adapters/workflow/adapter.sh" "$c/adapters/workflow/adapter.sh"
  # what the stand-in export produces
  echo '<html><body>New home</body></html>' > "$S/fixture/index.html"
  echo '<html><body>Gone</body></html>' > "$S/fixture/404.html"
  echo '<rss><channel><link>https://www.example.com/</link></channel></rss>' > "$S/fixture/feed/index.xml"
  echo '<html><body>Hello</body></html>' > "$S/fixture/hello/index.html"
  echo 'Exported 4 files, 200 bytes.' > "$S/export_stdout"
  echo 0 > "$S/export_exit"; echo 0 > "$S/dump_exit"
  printf -- '-- MariaDB dump\nCREATE TABLE t (a int);\nINSERT INTO t VALUES (1);\n\n-- Dump completed\n' > "$S/dump_body"
  # The stand-in docker notes each compose call (as one line, and argument by argument, and the OFFPRINT_* variables it
  # was given), then answers by the compose subcommand, after the options lib/site.sh's dc puts first (-p NAME
  # --project-directory DIR -f FILE). The two questions lib/site.sh asks before any compose call (whose the compose
  # project is: docker ps -a and docker volume ls) are noted apart, in docker.queries, and answered from files the case
  # controls: containers (one working folder per line, each as one container of the project) and volumes (every volume
  # Docker has, one line each, as docker volume ls prints it: NAME "project label" "offprint label" "volume label").
  # With neither file, there is no such project yet; with volume_ls_fails, only docker volume ls fails.
  cat > "$S/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != compose ]; then
  echo "$*" >> "$STUB_DIR/docker.queries"
  [ -f "$STUB_DIR/docker_down" ] && { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1; }
  case "${1:-} ${2:-}" in
    "ps -a") if [ -f "$STUB_DIR/containers" ]; then while IFS= read -r l; do echo "0123456789ab $l"; done < "$STUB_DIR/containers"; fi; exit 0 ;;
    "volume ls")
      # As docker does: --filter label=com.docker.compose.project=X keeps that project's volumes only, and a --format
      # without json labels gets each name and its offprint label alone.
      [ -f "$STUB_DIR/volume_ls_fails" ] && { echo "Error response from daemon: a volume listing that failed" >&2; exit 1; }
      [ -f "$STUB_DIR/volumes" ] || exit 0
      project=""; json=0
      for a in "$@"; do
        case "$a" in label=com.docker.compose.project=*) project="${a#label=com.docker.compose.project=}" ;; *'{{json'*) json=1 ;; esac
      done
      while IFS= read -r l; do
        rest="${l#* }"; p="${rest%%\" *}"; p="${p#\"}"
        [ -z "$project" ] || [ "$p" = "$project" ] || continue
        if [ "$json" = 1 ]; then echo "$l"; else o="${rest#*\" \"}"; echo "${l%% *} ${o%%\"*}"; fi
      done < "$STUB_DIR/volumes"
      exit 0 ;;
  esac
  echo "unexpected docker call: $*" >&2; exit 99
fi
echo "$*" >> "$STUB_DIR/docker.calls"
printf '[%s]' "$@" >> "$STUB_DIR/docker.argv"; echo >> "$STUB_DIR/docker.argv"   # each argument on its own
echo "${OFFPRINT_PUBLIC_ORIGIN-unset}|${OFFPRINT_LOCAL_HOST-unset}|${OFFPRINT_TLS_PORT-unset}|${OFFPRINT_HTTP_PORT-unset}|${OFFPRINT_TOOL-unset}" >> "$STUB_DIR/docker.env"
[ "${1:-}" = compose ] && shift
while [ $# -ge 2 ]; do
  case "$1" in -p|--project-name|--project-directory|-f|--file) shift 2 ;; *) break ;; esac
done
case "$*" in
  ps | "ps "*)
    [ -f "$STUB_DIR/ps_exit" ] && exit "$(cat "$STUB_DIR/ps_exit")"
    [ -f "$STUB_DIR/docker_down" ] && { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1; }
    [ -f "$STUB_DIR/wp_stopped" ] || echo wordpress
    echo db; exit 0 ;;
  "exec "*"wp option get siteurl")
    echo https://mysite.test; exit 0 ;;
  # what offprint setup-wp asks for, on a WordPress that is installed already; or, with wp_not_installed, one it then
  # installs, whose post 2 is what post2.json says (none without it), and whose deletion fails with post_delete_fails.
  # The install runs on_install first, when there is one (WordPress writing wp-content/ as it installs); with
  # install_already, it finds WordPress installed already, as WP-CLI says it then (and succeeds).
  up | "up "*) exit 0 ;;
  "exec "*"wp core is-installed") [ -f "$STUB_DIR/wp_not_installed" ] && exit 1; exit 0 ;;
  "exec "*"wp core install "*) rm -f "$STUB_DIR/wp_not_installed"
    [ -f "$STUB_DIR/on_install" ] && /bin/sh "$STUB_DIR/on_install"
    if [ -f "$STUB_DIR/install_already" ]; then echo "WordPress is already installed."; else echo "Success: WordPress installed successfully."; fi
    exit 0 ;;
  "exec "*"wp post get 2 "*) [ -f "$STUB_DIR/post2.json" ] || { echo "Error: Could not find the post with ID 2." >&2; exit 1; }
    cat "$STUB_DIR/post2.json"; exit 0 ;;
  "exec "*"wp post delete 2 --force") [ -f "$STUB_DIR/post_delete_fails" ] && { echo "Error: Failed deleting post 2." >&2; exit 1; }
    rm -f "$STUB_DIR/post2.json"; echo "Success: Deleted post 2."; exit 0 ;;
  "exec "*"wp option update "*|"exec "*"wp rewrite structure "*) exit 0 ;;
  "exec "*"wp offprint export"*)
    [ -f "$STUB_DIR/stage_during" ] && git -C "$PWD" add stray.txt
    [ -f "$STUB_DIR/export_sleep" ] && sleep 2
    [ -f "$STUB_DIR/export_stderr_only" ] && { echo "Error: There has been a critical error on this website." >&2; exit 1; }
    [ -f "$STUB_DIR/export_leaves_nothing" ] || cp -R "$STUB_DIR/fixture/." "$PWD/var/export/"
    [ -f "$STUB_DIR/export_fifo" ] && mkfifo "$PWD/var/export/pipe"
    [ -d "$STUB_DIR/plant_wp" ] && mkdir -p "$PWD/wp-content/plugins" && cp -R "$STUB_DIR/plant_wp" "$PWD/wp-content/plugins/planted"
    # (as on_install for setup-wp: WordPress writing wp-content/ while it exports)
    [ -f "$STUB_DIR/on_export" ] && /bin/sh "$STUB_DIR/on_export"
    cat "$STUB_DIR/export_stdout"; exit "$(cat "$STUB_DIR/export_exit")" ;;
  "exec "*mariadb-dump*)
    cat "$STUB_DIR/dump_body"; exit "$(cat "$STUB_DIR/dump_exit")" ;;
esac
echo "unexpected docker call: $*" >&2; exit 99
STUB
  cat > "$S/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/curl.calls"
[ -f "$STUB_DIR/curl_never" ] && exit 22
[ -f "$STUB_DIR/live_body" ] && { cat "$STUB_DIR/live_body"; exit 0; }
for last; do :; done
# the live site serves the commit in live_commit if there is one, else whatever it was asked about
if [ -f "$STUB_DIR/live_commit" ]; then echo "{\"commit\":\"$(cat "$STUB_DIR/live_commit")\"}"; else echo "{\"commit\":\"${last##*c=}\"}"; fi
STUB
  # GitHub, asked whether the repo is private: PRIVATE unless gh_visibility says otherwise; gh_fails: it can't answer
  cat > "$S/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.calls"
[ -f "$STUB_DIR/gh_fails" ] && { echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4; }
[ -f "$STUB_DIR/gh_hangs" ] && exec sleep 30
cat "$STUB_DIR/gh_visibility" 2>/dev/null || echo PRIVATE
STUB
  cat > "$S/bin/mv" <<'STUB'
#!/usr/bin/env bash
case "$1" in */var/publish.lock) [ -f "$STUB_DIR/lock_race" ] && echo 4242 > "$1/pid" ;; esac
[ -f "$STUB_DIR/mv_fail" ] && [ "$*" = "site.new site" ] && exit 1
exec /bin/mv "$@"
STUB
  # mkcert, for offprint setup-wp: a local CA that is made already, and a certificate it notes and writes
  mkdir -p "$S/caroot"; : > "$S/caroot/rootCA.pem"
  cat > "$S/bin/mkcert" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/mkcert.calls"
case "${1:-}" in
  -CAROOT) echo "$STUB_DIR/caroot" ;;
  -cert-file) echo cert > "$2"; echo key > "$4" ;;
esac
exit 0
STUB
  # age, which encrypts the database backup: the suites' shared stand-in (tests/fixtures/age-standin)
  cp "$SRC/tests/fixtures/age-standin" "$S/bin/age"
  chmod +x "$S/bin/docker" "$S/bin/curl" "$S/bin/mv" "$S/bin/gh" "$S/bin/mkcert" "$S/bin/age"
  # the repo, with an old site, an old backup, and a bare origin
  git init -q -b main "$c"
  git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
  cp "$SRC/templates/site.gitignore" "$c/.gitignore"   # the one a site starts with, so what it leaves out is tested too
  echo '/site/build.json' >> "$c/.gitignore"   # (the workflow writes it on the live site; a site with that host ignores it)
  echo '<html><body>Old</body></html>' > "$c/site/index.html"; echo 'OLD BACKUP' > "$c/backup/db.sql.age"
  echo old > "$c/wp-content/keep.txt"
  # This Offprint's plugin, as setup-wp puts it in a site and commits it (a publish refuses to commit any other); with
  # no_plugin=1 (bare_newcase), none, as before setup-wp's first run.
  if [ "${no_plugin:-0}" != 1 ]; then mkdir -p "$c/wp-content/mu-plugins"; cp -R "$SRC/plugin/offprint.php" "$SRC/plugin/offprint" "$c/wp-content/mu-plugins/"; fi
  git -C "$c" add -A && git -C "$c" commit -q -m initial
  git init -q --bare -b main "$O" && git -C "$c" remote add origin "$O"
  git -C "$c" push -q origin main
  commits0="$(git -C "$c" rev-list --count HEAD)"
}
bare_newcase() { no_plugin=1; newcase "$@"; no_plugin=0; }   # newcase, the site with no plugin yet
# toolcopy: a copy of the tool for this case alone (bin/, lib/, templates/, plugin/), so the case can change one of its
# scripts; pub runs that copy from then on.
toolcopy() { T="$tmp/case$n/tool"; mkdir -p "$T"; cp -R "$SRC/bin" "$SRC/lib" "$SRC/templates" "$SRC/plugin" "$T/"; }
pub() {  # run the tool's bin/publish for the site $c (OFFPRINT_SITE), from the case folder, with the stand-ins; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
    PUBLISH_CHECK_URL=https://example.test/build.json /bin/bash "$T/bin/publish" "$@" 2>&1)"; code=$?
}
js() {  # key -> value of that key in var/status.json; exit 3 if the file is not valid JSON
  php -r '$j = json_decode( (string) file_get_contents( $argv[1] ), true ); if ( ! is_array( $j ) ) { exit( 3 ); }
    $v = $j[ $argv[2] ] ?? null; echo is_array( $v ) ? json_encode( $v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES ) : ( is_bool( $v ) ? ( $v ? "true" : "false" ) : $v );' "$c/var/status.json" "$1"
}
valid() { # status.json is valid JSON with all five keys and an ISO 8601 UTC time
  if php -r '$j = json_decode( (string) file_get_contents( $argv[1] ), true );
    exit( is_array( $j ) && 6 === count( array_intersect( array_keys( $j ), array( "state", "running", "at", "commit", "message", "warnings" ) ) )
      && is_array( $j["warnings"] ) && false === $j["running"] && preg_match( "/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/", $j["at"] ) ? 0 : 1 );' "$c/var/status.json"
  then ok "$1: status.json is valid JSON"; else bad "$1: status.json is not valid ($(cat "$c/var/status.json" 2>&1))"; fi
}
nocommit() { check "$1: no new commit" "$commits0" "$(git -C "$c" rev-list --count HEAD)"; }
# compose_only T: docker was called, and every call was docker compose for this site's own project (the name in its
# site.json), with the site folder as the project directory and the tool's compose file, so it could reach no other
# compose project; and each call was given the site's values from site.json.
compose_only() {
  local site_p tool_p want
  site_p="$(cd "$c" && pwd -P)"; tool_p="$(cd "$T" && pwd -P)"
  want="compose -p example --project-directory $site_p -f $tool_p/templates/compose.yaml "
  check "$1: docker was called" yes "$([ -s "$S/docker.calls" ] && echo yes)"
  check "$1: every docker call is compose -p example, in the site folder, with the tool's compose file" "" \
    "$(W="$want" awk 'index($0, ENVIRON["W"]) != 1' "$S/docker.calls" 2>&1)"
  check "$1: each with the site's values" "" \
    "$(grep -vxF "https://www.example.com|mysite.test|4999|4998|$tool_p" "$S/docker.env" 2>&1)"
}
nosite_msg="Not in an Offprint site folder (no site.json here or above); cd into one, or set OFFPRINT_SITE."
mkdir -p "$tmp/nosite"
oldsite() { check "$1: site/ unchanged" "<html><body>Old</body></html>" "$(cat "$c/site/index.html")"; [ ! -e "$c/site/404.html" ] && ok "$1: no new files in site/" || bad "$1: site/ gained files"; }
oldbackup() { check "$1: backup/db.sql.age unchanged" "OLD BACKUP" "$(cat "$c/backup/db.sql.age")"; }

# --- export fails ---
newcase; echo 1 > "$S/export_exit"
printf 'Warning: a plugin did something\nError: Could not fetch /hello/\nError: second problem\n' > "$S/export_stdout"
pub; t="export fails (exit 1, files left behind)"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"
contains "$t: message is the first error" "Could not fetch /hello/" "$(js message)"
contains "$t: message counts the errors" "2 error" "$(js message)"
contains "$t: warning kept" "a plugin did something" "$(js warnings)"
valid "$t"; oldsite "$t"; oldbackup "$t"; nocommit "$t"
check "$t: nothing committed or staged" "" "$(git -C "$c" status --porcelain --untracked-files=no)"
contains "$t: export output is in the log" "second problem" "$(cat "$c/var/publish.log")"
check "$t: lock removed" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"
newcase; echo 1 > "$S/export_exit"; echo 'Exported 0 files, 0 bytes.' > "$S/export_stdout"
pub; check "export fails with no Error line: message" "The export failed; see var/publish.log" "$(js message)"

# --- docker not running / wordpress not running ---
newcase; touch "$S/docker_down"; pub; t="docker unreachable"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"
check "$t: message" "WordPress isn't running (offprint compose up -d)" "$(js message)"
valid "$t"; oldsite "$t"; nocommit "$t"
check "$t: export was never attempted" 0 "$(grep -c 'wp offprint export' "$S/docker.calls")"
# Docker couldn't be asked whose the compose project is: only compose ps is let through (it fails too, as above).
check "$t: the only compose call is ps" "ps --status running --services" "$(sed 's/.*compose\.yaml //' "$S/docker.calls")"
newcase; touch "$S/wp_stopped"; pub; t="wordpress service not running"
check "$t: message" "WordPress isn't running (offprint compose up -d)" "$(js message)"; valid "$t"; oldsite "$t"

# --- checks fail ---
newcase; echo '<a href="/wp-admin/">x</a>' > "$S/fixture/index.html"; pub; t="checks fail"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"
check "$t: the checked copy is removed" no "$([ -e "$c/site.new" ] && echo yes || echo no)"
contains "$t: message says why" "wp-admin" "$(js message)"
valid "$t"; oldsite "$t"; oldbackup "$t"; nocommit "$t"

# --- success, no push ---
newcase; pub --no-push; t="success with --no-push"
check "$t: exits 0" 0 "$code"; valid "$t"
check "$t: site/ equals the export" "" "$(diff -r "$c/site" "$S/fixture" 2>&1)"
check "$t: db.sql.age is the new dump, encrypted" "yes" "$(grep -q 'INSERT INTO t' "$c/backup/db.sql.age" && echo yes)"
check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: commit touches only site/, wp-content/, backup/" "" \
  "$(git -C "$c" show --name-only --format= HEAD | grep -v '^site/\|^wp-content/\|^backup/')"
check "$t: commit subject" "yes" "$(git -C "$c" log -1 --format=%s | grep -Eq '^Publish: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC$' && echo yes)"
check "$t: no trailers in the message" 1 "$(git -C "$c" log -1 --format=%B | grep -c .)"
check "$t: nothing pushed" "$commits0" "$(git -C "$O" rev-list --count main)"
check "$t: lock removed" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"
compose_only "$t"
check "$t: asked whether WordPress runs, exported, dumped" "ps exec exec" \
  "$(awk '{ for (i = 1; i <= NF; i++) if ($i == "ps" || $i == "exec") { printf "%s%s", (n++ ? " " : ""), $i; break } }' "$S/docker.calls")"
# Whose the compose project is: asked of Docker once for the whole publish, for this site's project name.
check "$t: asked docker ps -a once, for the project's containers and their folders" \
  'ps -a --filter label=com.docker.compose.project=example --format {{.ID}} {{.Label "com.docker.compose.project.working_dir"}}' \
  "$(grep '^ps -a ' "$S/docker.queries")"
check "$t: asked docker volume ls once, for every volume's name and labels" \
  'volume ls --format {{.Name}} {{json (.Label "com.docker.compose.project")}} {{json (.Label "offprint")}} {{json (.Label "com.docker.compose.volume")}}' \
  "$(grep '^volume ls ' "$S/docker.queries")"
check "$t: and nothing else outside compose" 2 "$(wc -l < "$S/docker.queries" | tr -d ' ')"
echo '# note' >> "$c/README.md"; git -C "$c" status --porcelain | grep -q README && ok "$t: other files are left alone" || bad "$t: README"
check "$t: README not in the commit" "" "$(git -C "$c" show --name-only --format= HEAD | grep README)"
pub --no-push; t="nothing changed (--no-push, second run)"
check "$t: state" unchanged "$(js state)"; valid "$t"
check "$t: no second commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"

newcase; git -C "$c" checkout -q -b other; pub --no-push; t="--no-push off main"
check "$t: works" 0 "$code"; check "$t: committed on the current branch" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
newcase; git -C "$c" checkout -q -b other; pub; t="full run off main"
check "$t: refused" failed "$(js state)"; contains "$t: message" "main branch" "$(js message)"; valid "$t"; oldsite "$t"; nocommit "$t"

# --- full run: push, then live ---
newcase; pub; t="full run"
check "$t: exits 0" 0 "$code"; check "$t: state" live "$(js state)"; valid "$t"
sha="$(git -C "$c" rev-parse HEAD)"
check "$t: status commit" "$sha" "$(js commit)"
check "$t: origin/main is the new commit" "$sha" "$(git -C "$O" rev-parse main)"
contains "$t: the live check asked for ?c=<sha>" "build.json?c=$sha" "$(cat "$S/curl.calls")"
check "$t: GitHub was asked whether the repo is private" "repo view --json visibility -q .visibility" "$(cat "$S/gh.calls")"
check "$t: git sees nothing to commit afterwards" "" "$(git -C "$c" status --porcelain)"
check "$t: the private index is removed" "" "$(ls -a "$c/.git" | grep publish-index)"
pub; t="nothing changed after a full publish"
check "$t: state" unchanged "$(js state)"; check "$t: exits 0" 0 "$code"; valid "$t"
check "$t: nothing new pushed" "$sha" "$(git -C "$O" rev-parse main)"

# --- push fails, then works ---
newcase; printf '#!/bin/sh\necho no >&2\nexit 1\n' > "$O/hooks/pre-receive"; chmod +x "$O/hooks/pre-receive"
pub; t="push fails"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"; valid "$t"
check "$t: the commit exists" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: origin did not move" "$commits0" "$(git -C "$O" rev-list --count main)"
rm "$O/hooks/pre-receive"; echo '<html><body>More</body></html>' > "$S/fixture/hello/index.html"
pub; t="second run after the push failed (with a new change)"
check "$t: state" live "$(js state)"; valid "$t"
check "$t: both commits pushed" "$((commits0 + 2))" "$(git -C "$O" rev-list --count main)"
newcase; printf '#!/bin/sh\nexit 1\n' > "$O/hooks/pre-receive"; chmod +x "$O/hooks/pre-receive"; pub
rm "$O/hooks/pre-receive"; pub; t="second run, nothing new to commit, one commit unpushed"
check "$t: state" live "$(js state)"; check "$t: the earlier commit is pushed" "$((commits0 + 1))" "$(git -C "$O" rev-list --count main)"
check "$t: no extra commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"

# --- build.json never shows the commit ---
newcase; touch "$S/curl_never"; pub; t="build.json never reports the commit"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"; valid "$t"
contains "$t: message names the commit" "$(git -C "$c" rev-parse --short=7 HEAD)" "$(js message)"
contains "$t: and says the live site couldn't be reached" "(it couldn't be reached)" "$(js message)"
check "$t: it was pushed" "$(git -C "$c" rev-parse HEAD)" "$(git -C "$O" rev-parse main)"
newcase; git -C "$c" rev-parse HEAD > "$S/live_commit"; pub; t="build.json keeps reporting the build before"
check "$t: state" failed "$(js state)"
contains "$t: says which build it still reports" "(it still reports $(git -C "$c" rev-parse --short=7 HEAD~1))" "$(js message)"

# --- lock ---
newcase; mkdir "$c/var/publish.lock" "$c/var/inbox"; echo "$$" > "$c/var/publish.lock/pid"; echo "asked" > "$c/var/inbox/publish-request"
echo '{"state":"exporting"}' > "$c/var/status.json"
pub; t="a publish is already running"
check "$t: exits 75, the busy code" 75 "$code"; contains "$t: says so" "already running" "$out"
check "$t: request left in place" asked "$(cat "$c/var/inbox/publish-request")"
check "$t: lock left alone" yes "$([ -d "$c/var/publish.lock" ] && echo yes)"
check "$t: status.json left alone" '{"state":"exporting"}' "$(cat "$c/var/status.json")"
oldsite "$t"; nocommit "$t"
newcase; mkdir "$c/var/publish.lock"; echo "$dead" > "$c/var/publish.lock/pid"; pub --no-push; t="a fresh lock whose process is gone"
check "$t: still respected (75)" 75 "$code"; contains "$t: says so" "already running" "$out"
newcase; mkdir "$c/var/publish.lock"; echo "$dead" > "$c/var/publish.lock/pid"; touch -t 202001010000 "$c/var/publish.lock"
pub --no-push; t="a stale lock (old, process gone)"
check "$t: removed and the publish runs" 0 "$code"; contains "$t: logged" "stale lock" "$(cat "$c/var/publish.log")"
check "$t: committed" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"; valid "$t"
newcase; mkdir "$c/var/publish.lock"; echo "$$" > "$c/var/publish.lock/pid"; touch -t 202001010000 "$c/var/publish.lock"
pub --no-push; t="an old lock whose process is still running"
check "$t: respected (75)" 75 "$code"
newcase; mkdir "$c/var/publish.lock"; echo "$$" > "$c/var/publish.lock/pid"; ps -o command= -p "$$" > "$c/var/publish.lock/command"
touch -t 202001010000 "$c/var/publish.lock"; pub --no-push; t="an old lock whose process is still the one that took it"
check "$t: respected (75)" 75 "$code"
newcase; mkdir "$c/var/publish.lock"; echo "$$" > "$c/var/publish.lock/pid"; echo "/bin/bash /elsewhere/bin/publish" > "$c/var/publish.lock/command"
touch -t 202001010000 "$c/var/publish.lock"; pub --no-push; t="an old lock whose pid is now another program's (after a restart)"
check "$t: removed and the publish runs" 0 "$code"; contains "$t: logged" "stale lock" "$(cat "$c/var/publish.log")"
check "$t: committed" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"

# --- staged changes, origin ahead ---
newcase; echo stray > "$c/stray.txt"; git -C "$c" add stray.txt; pub; t="staged changes"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"
check "$t: message" "There are staged changes; commit or unstage them first" "$(js message)"
valid "$t"; oldsite "$t"; nocommit "$t"
check "$t: the staged file is still staged" "A  stray.txt" "$(git -C "$c" status --porcelain --untracked-files=no)"

newcase; git clone -q -b main "$O" "$tmp/case$n/other"; git -C "$tmp/case$n/other" config user.email t@example.com; git -C "$tmp/case$n/other" config user.name T
echo x > "$tmp/case$n/other/x.txt"; git -C "$tmp/case$n/other" add x.txt; git -C "$tmp/case$n/other" commit -q -m remote; git -C "$tmp/case$n/other" push -q origin main
pub; t="origin/main ahead"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"
check "$t: message" "Main on GitHub has changes this Mac doesn't have; pull first" "$(js message)"; valid "$t"
check "$t: nothing force-pushed" "$((commits0 + 1))" "$(git -C "$O" rev-list --count main)"

# --- dry run ---
newcase; pub --dry-run; t="--dry-run"
check "$t: exits 0" 0 "$code"; check "$t: state" checking "$(js state)"
check "$t: message" "Dry run: a copy of the export passed the checks; the export is in var/export, and nothing else changed." "$(js message)"; valid "$t"
check "$t: the checked copy is gone" no "$([ -e "$c/site.new" ] && echo yes || echo no)"
check "$t: the export is in var/export" "" "$(diff -r "$c/var/export" "$S/fixture" 2>&1)"
oldsite "$t"; oldbackup "$t"; nocommit "$t"
check "$t: no dump was asked for" 0 "$(grep -c mariadb-dump "$S/docker.calls")"
check "$t: working tree clean" "" "$(git -C "$c" status --porcelain)"
check "$t: lock removed" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"

# --- the dump ---
newcase; echo 2 > "$S/dump_exit"; pub; t="dump exits non-zero"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"; valid "$t"; oldbackup "$t"; nocommit "$t"
newcase; printf -- '-- MariaDB dump\nCREATE TABLE t (a int);\nINSERT INTO t VALUES (1);\n' > "$S/dump_body"; pub; t="truncated dump"
check "$t: exits non-zero" 1 "$code"; check "$t: state" failed "$(js state)"; valid "$t"; oldbackup "$t"; nocommit "$t"
newcase; : > "$S/dump_body"; pub; t="empty dump"
check "$t: state" failed "$(js state)"; oldbackup "$t"; nocommit "$t"
check "$t: no temp file left" "" "$(ls "$c/var" | grep 'db.sql')"
newcase; pub --no-push; t="the dump uses the container's own credentials"
contains "$t: no password in the call" '$MARIADB_PASSWORD' "$(grep mariadb-dump "$S/docker.calls")"

# --- warnings ---
newcase; printf 'Warning: she said "hi" and C:\\path\\x and caf\xc3\xa9 \xe2\x9c\x93 </script>\nWarning: second\nExported 4 files, 200 bytes.\n' > "$S/export_stdout"
pub --dry-run; t="warnings with quotes, backslashes and non-ASCII"
check "$t: exits 0" 0 "$code"; valid "$t"
want="$(php -r 'echo json_encode( array( "Warning: she said \"hi\" and C:\\path\\x and caf\u{e9} \u{2713} </script>", "Warning: second" ), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES );')"
check "$t: warnings array" "$want" "$(js warnings)"
newcase; printf 'Warning: w1\nExported 4 files, 200 bytes.\n' > "$S/export_stdout"; pub; t="a warning on a full run"
check "$t: live" live "$(js state)"; check "$t: warnings kept to the end" '["Warning: w1"]' "$(js warnings)"

# --- fix round 1 ---
newcase; touch "$S/export_stderr_only"; echo 1 > "$S/export_exit"; : > "$S/export_stdout"; pub; t="export fails with an error only on stderr"
check "$t: message is the stderr error, no count" "There has been a critical error on this website." "$(js message)"; valid "$t"
newcase; echo 1 > "$S/export_exit"; printf 'Error: %0300d\n' 0 > "$S/export_stdout"; pub; t="a very long first error"
check "$t: truncated to 200 characters plus the count" "yes" "$(php -r '$m = json_decode( file_get_contents( $argv[1] ), true )["message"]; echo preg_match( "/^0{200} \(1 error/", $m ) ? "yes" : "no";' "$c/var/status.json")"

# running flag: true while working, false at the end (every case above asserts false via valid)
newcase; touch "$S/export_sleep"
( cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" exec /bin/bash "$T/bin/publish" --dry-run >/dev/null 2>&1 ) & pid=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q 'offprint export' "$S/docker.calls" 2>/dev/null && break; sleep 0.2; done
check "running is true while exporting" true "$(js running)"; check "state while exporting" exporting "$(js state)"
check "the lock names the command that holds it" "$(ps -o command= -p "$pid")" "$(cat "$c/var/publish.lock/command" 2>/dev/null)"
kill -TERM "$pid"; wait "$pid" 2>/dev/null; t="SIGTERM mid-run"
check "$t: state" failed "$(js state)"; valid "$t"; check "$t: lock released" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"; oldsite "$t"

# staging during the run
newcase; echo stray > "$c/stray.txt"; touch "$S/stage_during"; pub --no-push; t="something staged outside during the run"
check "$t: publish succeeds" 0 "$code"; valid "$t"
check "$t: not in the publish commit" "" "$(git -C "$c" show --name-only --format= HEAD | grep stray)"
check "$t: still staged" "A  stray.txt" "$(git -C "$c" status --porcelain --untracked-files=no)"
# A publish commit runs no commit hooks (git commit-tree), but moving the branch runs reference-transaction, which
# can refuse: that is a failed commit.
newcase; printf '#!/bin/sh\ntouch "%s/hook-ran"\nexit 1\n' "$S" > "$c/.git/hooks/pre-commit"; chmod +x "$c/.git/hooks/pre-commit"
pub --no-push; t="a pre-commit hook"
check "$t: the publish commits" 0 "$code"; check "$t: one commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: the hook never ran" no "$([ -e "$S/hook-ran" ] && echo yes || echo no)"
newcase; printf '#!/bin/sh\n[ "$1" = prepared ] && exit 1\nexit 0\n' > "$c/.git/hooks/reference-transaction"; chmod +x "$c/.git/hooks/reference-transaction"
pub --no-push; t="a failed commit (a reference-transaction hook refuses)"
check "$t: failed" failed "$(js state)"; valid "$t"; nocommit "$t"
contains "$t: says the branch didn't move" "Git couldn't move main to the new commit" "$(js message)"
check "$t: nothing staged" "" "$(git -C "$c" diff --cached --name-only)"
rm "$c/.git/hooks/reference-transaction"; pub --no-push; t="the run after a failed commit"
check "$t: succeeds" 0 "$code"; check "$t: one commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: running false, final state" "Committed, not pushed (--no-push)." "$(js message)"

# refusals before staging
newcase; mkdir -p "$c/wp-content/mu-plugins/offprint"; echo x > "$c/wp-content/mu-plugins/offprint/a.php"; pub --no-push; t="uncommitted plugin code"
contains "$t: failed, naming the path" "uncommitted changes (first: wp-content/mu-plugins/offprint" "$(js message)"; valid "$t"; oldsite "$t"; nocommit "$t"
newcase; mkdir -p "$c/wp-content/plugins/foo/.git"; pub --no-push; t="a nested .git"
contains "$t: names it" "wp-content/plugins/foo/.git" "$(js message)"; valid "$t"; oldsite "$t"; nocommit "$t"
newcase; dd if=/dev/null of="$c/wp-content/huge.bin" bs=1 count=0 seek=100000000 2>/dev/null; pub --no-push; t="a file over 95 MB"
contains "$t: names it" "wp-content/huge.bin" "$(js message)"; valid "$t"; nocommit "$t"
newcase; mkdir -p "$c/wp-content/upgrade"; dd if=/dev/null of="$c/wp-content/upgrade/huge.zip" bs=1 count=0 seek=100000000 2>/dev/null; pub --no-push; t="a file over 95 MB in a folder git ignores (WordPress's upgrade folder)"
check "$t: is fine" 0 "$code"
newcase; dd if=/dev/null of="$c/wp-content/huge.bin" bs=1 count=0 seek=100000000 2>/dev/null; echo '/wp-content/huge.bin' >> "$c/.gitignore"; pub --no-push; t="a file over 95 MB that the .gitignore names"
check "$t: is left out, so refused" failed "$(js state)"; contains "$t: names it" "left out of the publish: wp-content/huge.bin" "$(js message)"; nocommit "$t"

# swap failure
newcase; touch "$S/mv_fail"; pub --no-push; t="the second rename fails"
check "$t: failed" failed "$(js state)"; valid "$t"; oldsite "$t"; nocommit "$t"

# the size warning reaches status.json
# The limit puts the fixture at about 90% of it, well inside the 80–100% band: the copy that is
# checked packs to a few bytes more or less than the fixture (file times), so a limit that put it
# at exactly 80% made this case fail now and then (and a failed CI run stops a publish deploying).
newcase; size="$(tar -czf - -C "$S/fixture" . | wc -c | tr -d ' ')"
echo "ADAPTER_MAX_TOTAL_BYTES=$((size * 10 / 9))" >> "$c/adapters/workflow/adapter.sh"; git -C "$c" commit -q -am "a smaller limit"
pub --dry-run; t="size warning"
contains "$t: on the terminal" "warning: the site is" "$out"; contains "$t: in status.json" "over 80%" "$(js warnings)"; valid "$t"

# many warnings are capped
newcase; { for i in $(seq 1 60); do echo "Warning: w$i"; done; echo 'Exported 4 files, 200 bytes.'; } > "$S/export_stdout"; pub --dry-run; t="60 warnings"
check "$t: capped at 50 plus a line" 51 "$(php -r 'echo count( json_decode( file_get_contents( $argv[1] ), true )["warnings"] );' "$c/var/status.json")"
contains "$t: says how many more" '"and 10 more"' "$(js warnings)"

# --- fix round 2 ---
newcase; touch "$S/lock_race"; mkdir "$c/var/publish.lock"; echo "$dead" > "$c/var/publish.lock/pid"; touch -t 202001010000 "$c/var/publish.lock"
pub --no-push; t="a fresh lock taken while the stale one was being moved"
check "$t: exits 75" 75 "$code"; contains "$t: says so" "already running" "$out"
check "$t: the fresh lock is put back" 4242 "$(cat "$c/var/publish.lock/pid" 2>/dev/null)"; nocommit "$t"; oldsite "$t"
bare_newcase; rm -rf "$c/wp-content"; pub --no-push; t="a tracked folder missing on disk"
check "$t: failed" "wp-content is missing; nothing was committed" "$(js message)"; valid "$t"; nocommit "$t"
newcase; dd if=/dev/null of="$S/fixture/huge.bin" bs=1 count=0 seek=100000000 2>/dev/null; pub --no-push; t="a file over 95 MB in the export"
contains "$t: names it" "var/export/huge.bin" "$(js message)"; valid "$t"; oldsite "$t"; nocommit "$t"
newcase; dd if=/dev/null of="$c/wp-content/huge.bin" bs=1 count=0 seek=100000000 2>/dev/null; pub --no-push; t="a file over 95 MB in wp-content"
oldsite "$t"; oldbackup "$t"

# --- what is checked is what is published: a private copy, out of WordPress's reach ---
# late_writer: bin/check-site (in a copy of the tool), then (as WordPress could, still running) a file in var/export
# that the check would refuse. bin/publish runs it in the site folder, so $PWD/var/export is the site's.
late_writer() {
  toolcopy
  mv "$T/bin/check-site" "$T/bin/check-site.real"
  cat > "$T/bin/check-site" <<'WRAP'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
"$here/check-site.real" "$@"; rc=$?
printf '<p>https://mysite.test/secret</p>\n' > "$PWD/var/export/late.html"
exit "$rc"
WRAP
  chmod +x "$T/bin/check-site"
}
newcase; late_writer; pub --no-push; t="a file WordPress adds to var/export after the check"
check "$t: control: the late file was written into var/export" yes "$([ -f "$c/var/export/late.html" ] && echo yes)"
check "$t: the publish works" 0 "$code"
check "$t: the late file is not published" no "$([ -e "$c/site/late.html" ] && echo yes || echo no)"
check "$t: nor committed" "" "$(git -C "$c" show --name-only --format= HEAD | grep late)"
newcase; late_writer; pub --dry-run; t="the same, in a dry run"
check "$t: control: the late file was written into var/export" yes "$([ -f "$c/var/export/late.html" ] && echo yes)"
check "$t: passes" 0 "$code"; oldsite "$t"
# pub_within SECONDS ARGS...: pub, but a run that hangs is killed and counted as a failure
pub_within() {
  local limit=$1 i=0; shift
  ( cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
    PUBLISH_CHECK_URL=https://example.test/build.json exec /bin/bash "$T/bin/publish" "$@" > "$S/pub.out" 2>&1 ) & local pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $((limit * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; code=hung
  else wait "$pid"; code=$?; fi
  out="$(cat "$S/pub.out")"
}
newcase; touch "$S/export_fifo"; pub_within 20 --no-push; t="a FIFO in the export"
check "$t: refused, without hanging" 1 "$code"; contains "$t: says what" "var/export/pipe" "$(js message)"
valid "$t"; oldsite "$t"; nocommit "$t"
check "$t: the checked copy is removed" no "$([ -e "$c/site.new" ] && echo yes || echo no)"

# --- the export left nothing / swap leftovers ---
newcase; mkdir "$c/site.new"; echo junk > "$c/site.new/junk"; pub --no-push; t="a leftover site.new"
check "$t: cleaned" no "$([ -e "$c/site.new" ] && echo yes || echo no)"; check "$t: published" 0 "$code"
newcase; mv "$c/site" "$c/site.old"; pub --dry-run; t="a crash between the two renames"
check "$t: the old site is put back" "<html><body>Old</body></html>" "$(cat "$c/site/index.html")"

# --- git leaves nothing out: site/ in the commit is exactly the checked copy, and wp-content/ is backed up whole ---
# committed T PATH: PATH is in the last commit
committed() { check "$1: $2 is committed" "$2" "$(git -C "$c" ls-tree -r --name-only HEAD -- "$2")"; }
# Every name templates/site.gitignore anchors at the site's root, deeper down in wp-content/ (which git add reads
# through the ignore rules; site/ is added with -f). Each would be left out, and the publish refused, if its pattern
# weren't anchored.
newcase; p="$c/wp-content/plugins/p"; mkdir -p "$p/local/certs" "$p/var" "$p/upgrade" "$p/upgrade-temp-backup" "$p/cache" "$p/site.new" "$p/site.old" "$p/site"
echo CERT > "$p/cert.pem"; echo KEY > "$p/a.key"; echo 'A=1' > "$p/.env"; echo '{}' > "$p/site/build.json"; echo c > "$p/local/certs/c.pem"
echo v > "$p/var/v.txt"; echo u > "$p/upgrade/u.txt"; echo t > "$p/upgrade-temp-backup/t.txt"; echo k > "$p/cache/k.html"; echo d > "$p/debug.log"
echo n > "$p/site.new/n.txt"; echo o > "$p/site.old/o.txt"
pub --no-push; t="names templates/site.gitignore anchors at the root, deeper down in wp-content/"
check "$t: publishes" 0 "$code"; valid "$t"
for f in cert.pem a.key .env site/build.json local/certs/c.pem var/v.txt upgrade/u.txt upgrade-temp-backup/t.txt cache/k.html debug.log site.new/n.txt site.old/o.txt; do
  committed "$t" "wp-content/plugins/p/$f"
done
# The same in the export, so under site/: names the ignore list anchors at the root (and a vendor/ folder, which an
# unanchored list once hid), each committed. site/ is added with -f, so no ignore rule can leave any of it out: the
# second case gives git an excludes file (the owner's own, say) that names them all, unanchored.
anchored_names="a/vendor/x.js wp-includes/js/dist/vendor/y.js wp-content/cache/c.css wp-content/upgrade/u.js var/v.html local/certs/k.pem site.new/s.html cert.pem debug.log"
in_export() { local f; for f in $anchored_names; do mkdir -p "$S/fixture/$(dirname "$f")"; echo x > "$S/fixture/$f"; done; }
newcase; in_export; pub --no-push; t="names templates/site.gitignore anchors at the root, in the export (so under site/)"
check "$t: publishes" 0 "$code"; valid "$t"
for f in $anchored_names; do committed "$t" "site/$f"; done
newcase; in_export; printf 'vendor/\n*.pem\n*.log\ncache/\nupgrade/\nvar/\ncerts/\nsite.new/\n' > "$S/excludes"
printf '[core]\n\texcludesFile = %s\n' "$S/excludes" > "$S/gitconfig"
GIT_CONFIG_GLOBAL="$S/gitconfig" pub --no-push; t="the same, with git's excludes file naming every one of them, unanchored"
check "$t: publishes" 0 "$code"; valid "$t"
for f in $anchored_names; do committed "$t" "site/$f"; done
newcase; mkdir -p "$c/wp-content/plugins/p"; printf 'secret.txt\n' > "$c/wp-content/plugins/p/.gitignore"; echo s > "$c/wp-content/plugins/p/secret.txt"
pub --no-push; t="a plugin's own .gitignore hides one of its files"
check "$t: fails" failed "$(js state)"; valid "$t"; nocommit "$t"
contains "$t: names the file" "These files would be left out of the publish: wp-content/plugins/p/secret.txt" "$(js message)"
contains "$t: and the rule that hides it" "(the first by wp-content/plugins/p/.gitignore:1:secret.txt)" "$(js message)"
newcase; printf '*.bak\n' > "$S/excludes"; printf '[core]\n\texcludesFile = %s\n' "$S/excludes" > "$S/gitconfig"; echo b > "$c/wp-content/old.bak"
GIT_CONFIG_GLOBAL="$S/gitconfig" pub --no-push; t="git's excludes file (the owner's, say) hides a file"
check "$t: fails" failed "$(js state)"; contains "$t: names it" "wp-content/old.bak" "$(js message)"; nocommit "$t"
contains "$t: and the rule" "(the first by $S/excludes:1:*.bak)" "$(js message)"
for f in build.json Build.json; do
  newcase; echo '{"commit":"x"}' > "$S/fixture/$f"; pub --no-push; t="$f at the root of the export (the deploy writes build.json)"
  check "$t: fails" failed "$(js state)"; contains "$t: the check names it" "The export failed the checks, nothing was published: the deploy writes build.json at the root, so the export can't have one: ./$f" "$(js message)"
  nocommit "$t"; oldsite "$t"; check "$t: never committed" "" "$(git -C "$c" ls-tree -r --name-only HEAD -- site | grep -i 'site/build\.json')"
done
newcase; echo junk > "$S/fixture/hello/.DS_Store"; echo junk > "$c/wp-content/.DS_Store"; pub --no-push; t="Finder's .DS_Store files"
check "$t: publishes" 0 "$code"; check "$t: none committed" "" "$(git -C "$c" ls-tree -r --name-only HEAD | grep DS_Store)"
check "$t: none in site/" no "$([ -e "$c/site/hello/.DS_Store" ] && echo yes || echo no)"
newcase; mkdir -p "$c/wp-content/cache" "$c/wp-content/upgrade"; echo c > "$c/wp-content/cache/page.html"; echo u > "$c/wp-content/upgrade/x.zip"; echo d > "$c/wp-content/debug.log"
pub --no-push; t="WordPress's cache and upgrade folders and debug.log"
check "$t: publishes" 0 "$code"
check "$t: none committed" "" "$(git -C "$c" ls-tree -r --name-only HEAD -- wp-content/cache wp-content/upgrade wp-content/debug.log)"

# --- a git repository WordPress plants: never staged as a link to it (mode 160000), and nothing in it ever runs ---
# evil_repo DIR: a real repository at DIR whose config names a command (core.fsmonitor) that makes $S/pwned
# whenever git looks inside it, as a plain `git status` does for a repository staged as a submodule.
evil_repo() {
  printf '#!/bin/sh\ntouch "%s/pwned"\n' "$S" > "$S/fsmonitor-hook"; chmod +x "$S/fsmonitor-hook"
  mkdir -p "$1" && git init -q -b main "$1" && git -C "$1" -c user.name=E -c user.email=e@example.com commit -q --allow-empty -m e
  git -C "$1" config core.fsmonitor "$S/fsmonitor-hook"
}
# planted T: the publish failed, no link to a repository is staged or committed, and the planted command never ran:
# not during the publish, and not in the owner's next plain git status either.
planted() {
  check "$1: fails" failed "$(js state)"; valid "$1"; nocommit "$1"
  check "$1: no repository link (mode 160000) in the index" "" "$(git -C "$c" ls-files -s | grep '^160000')"
  check "$1: nor in the last commit" "" "$(git -C "$c" ls-tree -r HEAD | grep '^160000')"
  check "$1: the planted command never ran" no "$([ -e "$S/pwned" ] && echo yes || echo no)"
  git -C "$c" status > /dev/null 2>&1
  check "$1: not even in a plain git status afterwards" no "$([ -e "$S/pwned" ] && echo yes || echo no)"
}
newcase; evil_repo "$S/fixture/x"; pub --no-push; t="a git repository in the export"
planted "$t"; contains "$t: says why" "git file or folder: ./x/.git" "$(js message)"; oldsite "$t"
newcase; evil_repo "$S/plant_wp"; pub --no-push; t="a git repository WordPress writes into wp-content during the export"
planted "$t"; contains "$t: names it" "There is a git repository inside wp-content at wp-content/plugins/planted/.git" "$(js message)"
# The same, written in the moment between that check and git add: a stand-in git plants it on the first add.
newcase; evil_repo "$S/evil"; real_git="$(command -v git)"
cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" add "*) [ -e "$c/wp-content/plugins/late" ] || cp -R "$S/evil" "$c/wp-content/plugins/late" ;; esac
exec "$real_git" "\$@"
STUB
chmod +x "$S/bin/git"; mkdir -p "$c/wp-content/plugins"
pub --no-push; t="a git repository written into wp-content just before git add"
planted "$t"; contains "$t: names it" "There is a git repository at wp-content/plugins/late; nothing was committed" "$(js message)"
newcase; mkdir -p "$c/wp-content/plugins/foo/.GIT"; pub --no-push; t="a nested .GIT (the Mac's disk ignores case)"
contains "$t: names it" "wp-content/plugins/foo/.GIT" "$(js message)"; valid "$t"; oldsite "$t"; nocommit "$t"

# --- what is committed is the index the checks looked at: nothing is read from disk again after git add ---
# git_standin PATTERN: a stand-in git, first on PATH for bin/publish only, that the first time it is called with
# arguments matching PATTERN (a case pattern for " $* ") runs $S/action (with REAL_GIT set), then the real git.
git_standin() {
  local real; real="$(command -v git)"
  cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in $1) [ -e "$S/fired" ] || { touch "$S/fired"; REAL_GIT="$real" bash "$S/action"; } ;; esac
exec "$real" "\$@"
STUB
  chmod +x "$S/bin/git"
}
no_private_index() { check "$1: the private index is removed" "" "$(ls -a "$c/.git" | grep publish-index)"; }
# The attack the last review reproduced: a tracked wp-content file swapped for a git repository after the index is
# built (the old bin/publish re-read it at git commit). At the same moment, something outside the three folders is
# staged in git's own index, as the owner might.
newcase; evil_repo "$S/evil"; echo stray > "$c/stray.txt"
cat > "$S/action" <<ACTION
rm -f "$c/wp-content/keep.txt"; cp -R "$S/evil" "$c/wp-content/keep.txt"
env -u GIT_INDEX_FILE "\$REAL_GIT" -C "$c" add stray.txt
ACTION
git_standin '*" write-tree "*|*" commit "*'; pub --no-push; t="a tracked file swapped for a git repository after git add"
check "control: the swap happened" yes "$([ -e "$S/fired" ] && [ -d "$c/wp-content/keep.txt/.git" ] && echo yes)"
# It commits what was checked: the tree is written from the index git add built, so the swap can't reach it.
check "$t: the publish commits" 0 "$code"; check "$t: one commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: the commit has the file as it was at git add" "old" "$(git -C "$c" cat-file -p HEAD:wp-content/keep.txt 2>&1)"
check "$t: no repository link (mode 160000) in the commit" "" "$(git -C "$c" ls-tree -r HEAD | grep '^160000')"
check "$t: nor in git's index" "" "$(git -C "$c" ls-files -s | grep '^160000')"
check "$t: the planted command never ran" no "$([ -e "$S/pwned" ] && echo yes || echo no)"
git -C "$c" status > /dev/null 2>&1; git -C "$c" status --porcelain --untracked-files=all > /dev/null 2>&1
check "$t: not even in plain git status afterwards" no "$([ -e "$S/pwned" ] && echo yes || echo no)"
check "$t: what was staged outside the three folders is still staged, and only that" "stray.txt" "$(git -C "$c" diff --cached --name-only)"
check "$t: and isn't in the publish commit" "" "$(git -C "$c" show --name-only --format= HEAD | grep stray)"
no_private_index "$t"
# The same moment, but the file becomes one over 95 MB, after the checks (just before the commit is made).
newcase; cat > "$S/action" <<ACTION
rm -f "$c/wp-content/keep.txt"; dd if=/dev/null of="$c/wp-content/keep.txt" bs=1 count=0 seek=100000000 2>/dev/null
ACTION
git_standin '*" commit-tree "*|*" commit "*'; pub --no-push; t="a tracked file swapped for one over 95 MB after the checks"
check "control: the swap happened" 100000000 "$(wc -c < "$c/wp-content/keep.txt" | tr -d ' ')"
check "$t: the publish commits" 0 "$code"
check "$t: the committed file is the one that was checked" 4 "$(git -C "$c" cat-file -s HEAD:wp-content/keep.txt 2>&1)"
# One over 95 MB written just before git add, after the early size check: the check of the index refuses it.
newcase; cat > "$S/action" <<ACTION
dd if=/dev/null of="$c/wp-content/late.bin" bs=1 count=0 seek=100000000 2>/dev/null
ACTION
git_standin '*" add "*'; pub --no-push; t="a file over 95 MB written into wp-content just before git add"
check "$t: fails" failed "$(js state)"; valid "$t"; nocommit "$t"
contains "$t: names it" "wp-content/late.bin is over 95 MB and GitHub would refuse it" "$(js message)"
check "$t: nothing staged" "" "$(git -C "$c" diff --cached --name-only)"; no_private_index "$t"
# Belt and braces: even if the check of the index missed a repository link (a stand-in git hides it from the
# listings the checks read), the commit is looked at once made, and the branch is moved back.
newcase; evil_repo "$S/evil"; real_git="$(command -v git)"
cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" add "*) [ -e "$c/wp-content/plugins/late" ] || cp -R "$S/evil" "$c/wp-content/plugins/late" ;; esac
case " \$* " in
  *" ls-files "*" -s "*|*" ls-tree "*" -l "*)
    case " \$* " in
      *" -z "*) "$real_git" "\$@" | tr '\0' '\n' | grep -v '^160000' | tr '\n' '\0'; exit "\${PIPESTATUS[0]}" ;;
      *) "$real_git" "\$@" | grep -v '^160000'; exit "\${PIPESTATUS[0]}" ;;
    esac ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$S/bin/git"; mkdir -p "$c/wp-content/plugins"; old_head="$(git -C "$c" rev-parse HEAD)"
pub --no-push; t="a repository link the checks missed"
check "$t: fails" failed "$(js state)"; valid "$t"; nocommit "$t"
check "$t: the branch is back where it was" "$old_head" "$(git -C "$c" rev-parse HEAD)"
contains "$t: says so" "was moved back to the commit before it" "$(js message)"
check "$t: no repository link in HEAD" "" "$(git -C "$c" ls-tree -r HEAD | grep '^160000')"
check "$t: nor in git's index" "" "$(git -C "$c" ls-files -s | grep '^160000')"
git -C "$c" status > /dev/null 2>&1
check "$t: the planted command never ran, even after git status" no "$([ -e "$S/pwned" ] && echo yes || echo no)"
# Something else commits while the publish is under way: the branch is moved only from the commit the publish
# started from, so it fails cleanly and the other commit stays.
newcase; cat > "$S/action" <<ACTION
h="\$(env -u GIT_INDEX_FILE "\$REAL_GIT" -C "$c" rev-parse HEAD)"
n="\$(env -u GIT_INDEX_FILE "\$REAL_GIT" -C "$c" commit-tree "\$h^{tree}" -p "\$h" -m concurrent)"
env -u GIT_INDEX_FILE "\$REAL_GIT" -C "$c" update-ref HEAD "\$n"
ACTION
git_standin '*" commit-tree "*|*" commit "*'; pub --no-push; t="another commit lands during the publish"
check "$t: fails" failed "$(js state)"; valid "$t"
check "$t: the other commit is the branch's" concurrent "$(git -C "$c" log -1 --format=%s)"
check "$t: and nothing of the publish's is on top of it or under it" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
contains "$t: says the branch didn't move" "Git couldn't move main to the new commit" "$(js message)"
check "$t: nothing staged" "" "$(git -C "$c" diff --cached --name-only)"; no_private_index "$t"

# --- a file re-exported with another case, on this Mac's case-insensitive disk: the commit has the new name ---
newcase; mkdir -p "$c/site/About"; echo '<p>old</p>' > "$c/site/About.html"; echo '<p>old</p>' > "$c/site/About/index.html"
git -C "$c" add -A && git -C "$c" commit -q -m "old case"; commits0="$(git -C "$c" rev-list --count HEAD)"
mkdir -p "$S/fixture/about"; echo '<p>new</p>' > "$S/fixture/about.html"; echo '<p>new</p>' > "$S/fixture/about/index.html"
mv "$c/wp-content/keep.txt" "$c/wp-content/keep.tmp" && mv "$c/wp-content/keep.tmp" "$c/wp-content/KEEP.txt"
pub --no-push; t="a case-only rename (About.html to about.html)"
check "$t: publishes" 0 "$code"
check "$t: the commit has exactly the new names" "site/about.html site/about/index.html" \
  "$(git -C "$c" ls-tree -r --name-only HEAD -- site | grep -i about | tr '\n' ' ' | sed 's/ $//')"
check "$t: and the new name in wp-content" "wp-content/KEEP.txt" "$(git -C "$c" ls-tree -r --name-only HEAD -- wp-content | grep -i keep)"
check "$t: git's own index has the new names too" "site/about.html site/about/index.html" \
  "$(git -C "$c" ls-files -- site | grep -i about | tr '\n' ' ' | sed 's/ $//')"
check "$t: git sees nothing to commit" "" "$(git -C "$c" status --porcelain)"

# --- a plugin's .gitattributes can't change how wp-content is stored ---
if git --attr-source="$(git hash-object -t tree /dev/null)" version > /dev/null 2>&1; then
  newcase; mkdir -p "$c/wp-content/plugins/p"; echo '* text' > "$c/wp-content/plugins/p/.gitattributes"
  printf 'a\r\nb\r\n' > "$c/wp-content/plugins/p/crlf.txt"
  pub --no-push; t="a plugin's .gitattributes asks git to convert line endings"
  check "$t: publishes" 0 "$code"
  check "$t: the file is stored byte for byte" "$(printf 'a\r\nb\r\n' | od -c)" "$(git -C "$c" cat-file -p HEAD:wp-content/plugins/p/crlf.txt | od -c)"
else
  echo "skip  a plugin's .gitattributes (this git has no --attr-source)"
fi

# --- GitHub has no main yet: the first publish creates it ---
newcase; rm -rf "$O"; git init -q --bare -b main "$O"; git -C "$c" push -q origin main:start
pub; t="a first publish, with no main on GitHub"
check "$t: live" live "$(js state)"; check "$t: exits 0" 0 "$code"; valid "$t"
check "$t: main is created on GitHub, at the new commit" "$(git -C "$c" rev-parse HEAD)" "$(git -C "$O" rev-parse main 2>&1)"
newcase; rm -rf "$O"; pub; t="GitHub can't be reached"
check "$t: fails" failed "$(js state)"; check "$t: says so" "Couldn't reach GitHub to check main; see var/publish.log" "$(js message)"

# --- gh never answers ---
newcase; touch "$S/gh_hangs"; start=$SECONDS; PUBLISH_GH_TIMEOUT_SECONDS=1 pub_within 30; t="gh doesn't answer"
check "$t: still publishes" live "$(js state)"
contains "$t: with a warning" "couldn't confirm that the GitHub repo is private (gh didn't answer within 1 seconds)" "$(js warnings)"
check "$t: without waiting for it" yes "$([ $((SECONDS - start)) -lt 15 ] && echo yes)"

# --- nothing new to push, but the live site never got the last commit (its deploy failed) ---
newcase; touch "$S/curl_never"; pub; rm "$S/curl_never"   # pushed; the live site never showed it
git -C "$c" rev-parse HEAD~1 > "$S/live_commit"; : > "$S/curl.calls"; pub; t="nothing new, but the live site is behind GitHub"
check "$t: fails" failed "$(js state)"; check "$t: exits non-zero" 1 "$code"; valid "$t"
check "$t: says which build it reports, and what to do" \
  "GitHub has $(git -C "$c" rev-parse --short=7 HEAD), but the live site hasn't shown it (it still reports $(git -C "$c" rev-parse --short=7 HEAD~1)); look at the GitHub Actions run" "$(js message)"
check "$t: asked the live site once" 1 "$(grep -c 'build.json?c=' "$S/curl.calls")"
check "$t: no new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
touch "$S/curl_never"; pub; t="nothing new, and the live site can't be reached"
check "$t: fails" failed "$(js state)"; valid "$t"
check "$t: says it couldn't reach it, not that it is behind" \
  "GitHub has $(git -C "$c" rev-parse --short=7 HEAD), but the live site couldn't be reached to confirm it serves that (see var/publish.log); publish again in a minute." "$(js message)"
rm "$S/curl_never"; echo '{"status":"ok"}' > "$S/live_body"; pub; t="nothing new, and the live site answers without naming a build"
check "$t: says so" "GitHub has $(git -C "$c" rev-parse --short=7 HEAD), but the live site hasn't shown it (its build.json names no build); look at the GitHub Actions run" "$(js message)"
rm "$S/live_body"
git -C "$c" rev-parse HEAD > "$S/live_commit"; pub; t="nothing new, and the live site has it"
check "$t: unchanged" unchanged "$(js state)"; check "$t: exits 0" 0 "$code"; valid "$t"
newcase; touch "$S/curl_never"; pub --no-push; pub --no-push; t="nothing new with --no-push (the live site isn't asked)"
check "$t: unchanged" unchanged "$(js state)"; check "$t: no request" no "$([ -s "$S/curl.calls" ] && echo yes || echo no)"

# --- the repo holds the database dump and every upload: it must be private on GitHub ---
newcase; echo PUBLIC > "$S/gh_visibility"; pub; t="the GitHub repo is public"
check "$t: fails" failed "$(js state)"; valid "$t"
check "$t: says so" "The GitHub repo is not private; nothing was pushed." "$(js message)"
check "$t: origin did not move" "$commits0" "$(git -C "$O" rev-list --count main)"
check "$t: the commit is kept here" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
newcase; touch "$S/gh_fails"; pub; t="gh can't answer (not logged in, offline)"
check "$t: still publishes" live "$(js state)"; contains "$t: with a warning" "couldn't confirm that the GitHub repo is private" "$(js warnings)"
contains "$t: saying why" "gh auth login" "$(js warnings)"
newcase; PUBLISH_GH=gh-is-not-installed-here pub; t="gh is not installed"
check "$t: still publishes" live "$(js state)"; contains "$t: with a warning" "couldn't confirm that the GitHub repo is private (gh is not installed)" "$(js warnings)"
check "$t: the stand-in gh was not asked" no "$([ -e "$S/gh.calls" ] && echo yes || echo no)"

# --- a folder WordPress made read-only in the export can still be removed ---
newcase; mkdir -p "$S/fixture/ro"; echo 'https://mysite.test/' > "$S/fixture/ro/x.html"; chmod 555 "$S/fixture/ro"
pub --no-push; t="a read-only folder in an export that fails the checks"
check "$t: fails" failed "$(js state)"; check "$t: the checked copy is removed" no "$([ -e "$c/site.new" ] && echo yes || echo no)"
chmod 755 "$S/fixture/ro"; rm "$S/fixture/ro/x.html"; chmod 555 "$S/fixture/ro"; pub --no-push; t="the next run, with var/export still holding it"
check "$t: var/export is emptied and the publish works" 0 "$code"
check "$t: and site/ has the folder" yes "$([ -d "$c/site/ro" ] && echo yes)"
newcase; mkdir "$c/site.old" "$c/site.old/ro"; echo x > "$c/site.old/ro/f"; chmod 555 "$c/site.old/ro"; pub --no-push; t="a read-only leftover site.old"
check "$t: publishes" 0 "$code"; check "$t: site.old is gone" no "$([ -e "$c/site.old" ] && echo yes || echo no)"

# --- the backup is always in the commit, whatever ignores *.age ---
backup_bytes() { wc -c < "$c/backup/db.sql.age" | tr -d ' '; }
newcase; printf '*.age\n*.sql\n' >> "$c/.git/info/exclude"; pub; t="*.age in .git/info/exclude"
check "$t: live" live "$(js state)"; check "$t: backup/db.sql.age is in the commit, as written" "$(backup_bytes)" "$(git -C "$c" cat-file -s HEAD:backup/db.sql.age 2>&1)"
check "$t: and on GitHub" 1 "$(git -C "$O" show main:backup/db.sql.age 2>/dev/null | grep -c 'INSERT INTO t')"
newcase; printf '*.age\n' > "$S/excludes"; printf '[core]\n\texcludesFile = %s\n' "$S/excludes" > "$S/gitconfig"
GIT_CONFIG_GLOBAL="$S/gitconfig" pub; t="*.age in git's excludes file"
check "$t: live" live "$(js state)"; check "$t: backup/db.sql.age is in the commit, as written" "$(backup_bytes)" "$(git -C "$c" cat-file -s HEAD:backup/db.sql.age 2>&1)"
# The owner's own attributes can still filter it (a clean filter that keeps 5 bytes): then the commit would not hold the
# backup as written, so nothing is committed.
newcase; printf '*.age filter=shrink\n' > "$c/.git/info/attributes"; git -C "$c" config filter.shrink.clean 'head -c 5'
pub --no-push; t="a filter changes backup/db.sql.age on its way into git"
check "$t: fails" failed "$(js state)"; valid "$t"; nocommit "$t"
contains "$t: says so" "The database backup isn't in the commit as it was written" "$(js message)"

# --- the backup is encrypted: to site.json's recipients, with age, and never committed readable ---
Q62="age1$(printf 'q%.0s' $(seq 1 58))"; P62="age1$(printf 'p%.0s' $(seq 1 58))"
age_calls() { if [ -f "$S/age.calls" ]; then wc -l < "$S/age.calls" | tr -d ' '; else echo 0; fi; }
plain_left() { check "$1: no dump, readable or encrypted, is left in var/" "" "$(ls "$c/var" | grep 'db.sql')"; }
is_age() { git -C "$c" show "HEAD:backup/db.sql.age" 2>/dev/null | head -n 1; }
# with_recipients LIST: the case's site.json with those recipients ("A" or "A","B", quoted for JSON), committed
with_recipients() { sed "s/\"recipients\": \[[^]]*\]/\"recipients\": [$1]/" "$c/site.json" > "$c/site.json.new" && mv "$c/site.json.new" "$c/site.json"; git -C "$c" commit -q -am recipients; }
newcase; pub; t="a publish encrypts the backup"
check "$t: live" live "$(js state)"
check "$t: backup/db.sql.age is committed, and nothing else in backup/" "backup/db.sql.age" "$(git -C "$c" ls-tree -r --name-only HEAD -- backup)"
check "$t: it is an age file" "age-encryption.org/v1" "$(is_age)"
check "$t: encrypted to site.json's recipient, from var/, into var/" "-r $Q62 -o $(cd "$c" && pwd -P)/var/db.sql.age.tmp $(cd "$c" && pwd -P)/var/db.sql.tmp" "$(cat "$S/age.calls")"
plain_left "$t"
check "$t: what the commit holds is what is on disk" "$(backup_bytes)" "$(git -C "$c" cat-file -s HEAD:backup/db.sql.age)"
check "$t: var/backup.id notes the dump and who it was encrypted to" "$(git hash-object --no-filters "$S/dump_body") $Q62" "$(cat "$c/var/backup.id")"
check "$t: no warning" "[]" "$(js warnings)"
newcase; with_recipients "\"$Q62\", \"$P62\""; pub --no-push; t="two recipients in site.json"
check "$t: committed" "$((commits0 + 2))" "$(git -C "$c" rev-list --count HEAD)"
contains "$t: both, in site.json's order" "-r $Q62 -r $P62 -o " "$(cat "$S/age.calls")"

# No backup block: refused before anything is exported, a dry run too. (Otherwise the dump would have to be committed
# readable, or not at all.)
no_block="site.json has no \"backup\" block, so the database backup can't be encrypted; nothing was published. Make a key (age-keygen), keep it in your password manager, and add its public half: \"backup\": {\"recipients\": [\"age1...\"]}. The README has the steps."
for flag in "" --dry-run; do
  newcase; grep -v '"backup"' "$c/site.json" | sed 's/"http_port": 4998,/"http_port": 4998/' > "$c/site.json.new"; mv "$c/site.json.new" "$c/site.json"
  git -C "$c" commit -q -am "no backup block"; commits0="$(git -C "$c" rev-list --count HEAD)"
  pub $flag; t="no backup block in site.json${flag:+, $flag}"
  check "$t: exits 1" 1 "$code"; check "$t: failed" failed "$(js state)"; valid "$t"; nocommit "$t"; oldsite "$t"; oldbackup "$t"
  check "$t: says what to do" "$no_block" "$(js message)"
  check "$t: the export never ran" 0 "$(cat "$S/docker.calls" 2>/dev/null | grep -c 'wp offprint export')"
  check "$t: age never ran" 0 "$(age_calls)"
done
# No age on the PATH: the same. no_age_path: the PATH, each folder that holds an age (the real one, on a Mac that has
# it) replaced by a folder of links to everything else in it.
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
no_age="age isn't installed; install it (brew install age) and publish again."
for flag in "" --dry-run; do
  newcase; rm "$S/bin/age"; PATH="$(no_age_path)" pub $flag; t="no age on the PATH${flag:+, $flag}"
  check "control ($t): there is no age on that PATH" no "$(PATH="$S/bin:$(no_age_path)" command -v age > /dev/null && echo yes || echo no)"
  check "$t: exits 1" 1 "$code"; check "$t: failed" failed "$(js state)"; valid "$t"; nocommit "$t"; oldsite "$t"; oldbackup "$t"
  check "$t: says what to install" "$no_age" "$(js message)"
  check "$t: the export never ran" 0 "$(cat "$S/docker.calls" 2>/dev/null | grep -c 'wp offprint export')"
done
# age failing, or succeeding with nothing usable written: nothing is committed, the last backup stays, and no dump is
# left behind.
cant="The database backup couldn't be encrypted, so nothing was committed; see var/publish.log"
for how in age_fails age_empty age_junk; do
  newcase; pub --no-push; before="$(cat "$c/backup/db.sql.age")"; note="$(cat "$c/var/backup.id")"; commits0="$(git -C "$c" rev-list --count HEAD)"
  printf -- '-- MariaDB dump\nINSERT INTO t VALUES (2);\n\n-- Dump completed\n' > "$S/dump_body"; touch "$S/$how"; pub --no-push; t="$how"
  check "$t: exits 1" 1 "$code"; check "$t: failed" failed "$(js state)"; valid "$t"; nocommit "$t"
  check "$t: says so" "$cant" "$(js message)"
  check "$t: the last backup is untouched" "$before" "$(cat "$c/backup/db.sql.age")"
  check "$t: var/backup.id is untouched" "$note" "$(cat "$c/var/backup.id")"
  plain_left "$t"
done
# The same dump, the same recipients, the same committed file: kept, not encrypted again (age's output differs on every
# run, so encrypting again would make a commit of every publish).
newcase; pub --no-push; one="$(git -C "$c" rev-parse HEAD)"; pub --no-push; t="a second publish, nothing changed"
check "$t: exits 0" 0 "$code"; check "$t: no second commit" "$one" "$(git -C "$c" rev-parse HEAD)"
check "$t: age ran once" 1 "$(age_calls)"; plain_left "$t"
check "$t: the working tree is clean" "" "$(git -C "$c" status --porcelain)"
# ... but each of these means the committed file can't be taken for this dump's, so it is made again.
newcase; pub --no-push; with_recipients "\"$Q62\", \"$P62\""; pub --no-push; t="the recipients changed, the database didn't"
check "$t: exits 0" 0 "$code"; check "$t: age ran again" 2 "$(age_calls)"
contains "$t: to both" "-r $Q62 -r $P62 -o " "$(tail -n 1 "$S/age.calls")"
contains "$t: and the commit's backup names both" "$Q62 $P62" "$(git -C "$c" show HEAD:backup/db.sql.age | sed -n 2p)"
check "$t: var/backup.id names both" "$(git hash-object --no-filters "$S/dump_body") $Q62 $P62" "$(cat "$c/var/backup.id")"
newcase; pub --no-push; rm "$c/var/backup.id"; pub --no-push; t="var/backup.id lost"
check "$t: exits 0" 0 "$code"; check "$t: age ran again" 2 "$(age_calls)"; check "$t: the commit's backup is an age file" "age-encryption.org/v1" "$(is_age)"
newcase; pub --no-push; rm "$c/backup/db.sql.age"; pub --no-push; t="backup/db.sql.age deleted from the folder"
check "$t: exits 0" 0 "$code"; check "$t: age ran again" 2 "$(age_calls)"; check "$t: the commit's backup is an age file" "age-encryption.org/v1" "$(is_age)"
check "$t: and it is back on disk" "$(backup_bytes)" "$(git -C "$c" cat-file -s HEAD:backup/db.sql.age)"
newcase; pub --no-push; echo scribble > "$c/backup/db.sql.age"; pub --no-push; t="backup/db.sql.age overwritten in the folder"
check "$t: exits 0" 0 "$code"; check "$t: age ran again" 2 "$(age_calls)"; check "$t: the commit's backup is an age file" "age-encryption.org/v1" "$(is_age)"
newcase; pub --no-push; ln -s "$c/backup/db.sql.age" "$c/var/link"; rm "$c/var/backup.id"; ln -s "$c/var/link" "$c/var/backup.id"; pub --no-push; t="var/backup.id is a link"
check "$t: exits 0" 0 "$code"; check "$t: age ran again" 2 "$(age_calls)"
check "$t: the note is a plain file again, and the link's target was not written through" "no|age-encryption.org/v1" "$([ -L "$c/var/backup.id" ] && echo yes || echo no)|$(head -n 1 "$c/backup/db.sql.age")"
newcase; pub --no-push; printf -- '-- MariaDB dump\nINSERT INTO t VALUES (2);\n\n-- Dump completed\n' > "$S/dump_body"; pub --no-push; t="the database changed"
check "$t: age ran again" 2 "$(age_calls)"; check "$t: a second commit" "$((commits0 + 2))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: holding the new dump" 1 "$(git -C "$c" show HEAD:backup/db.sql.age | grep -c 'VALUES (2)')"
# A site from before: its readable backup/db.sql leaves the commit and the folder, and the owner is told, once, that
# earlier commits still hold it.
history="Earlier commits in this repository still hold the database unencrypted (backup/db.sql). A publish never rewrites history; whether to is yours to decide."
newcase; echo 'OLD DUMP' > "$c/backup/db.sql"; git -C "$c" add -f backup/db.sql; git -C "$c" commit -q -m "a readable dump, as before"; pub --no-push; t="a site that had backup/db.sql"
check "$t: exits 0" 0 "$code"
check "$t: the commit holds only the encrypted backup" "backup/db.sql.age" "$(git -C "$c" ls-tree -r --name-only HEAD -- backup)"
check "$t: backup/db.sql is gone from the folder" no "$([ -e "$c/backup/db.sql" ] && echo yes || echo no)"
contains "$t: the owner is told about earlier commits" "$history" "$(js warnings)"
check "$t: told once" 1 "$(js warnings | grep -o 'Earlier commits' | wc -l | tr -d ' ')"
printf -- '-- MariaDB dump\nINSERT INTO t VALUES (3);\n\n-- Dump completed\n' > "$S/dump_body"; pub --no-push; t="that site's next publish"
check "$t: exits 0" 0 "$code"; check "$t: no such warning again" 0 "$(js warnings | grep -c 'Earlier commits')"
# A dry run stops before the backup: nothing of it is made or noted.
newcase; pub --dry-run; t="a dry run and the backup"
check "$t: exits 0" 0 "$code"; oldbackup "$t"; check "$t: age never ran" 0 "$(age_calls)"
check "$t: no var/backup.id" no "$([ -e "$c/var/backup.id" ] && echo yes || echo no)"
# The size limit is the encrypted file's (it is what is pushed).
newcase; head -c 99614721 /dev/zero > "$S/big"; cat > "$S/bin/age" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -r) shift 2 ;; *) shift ;; esac; done
{ echo "age-encryption.org/v1"; cat "$STUB_DIR/big"; } > "$out"
STUB
pub --no-push; t="an encrypted backup over 95 MB"
check "$t: failed" failed "$(js state)"; nocommit "$t"; oldbackup "$t"; plain_left "$t"
contains "$t: says so" "The database backup is over 95 MB" "$(js message)"

# --- a merge, rebase, cherry-pick, revert or bisect under way: never publish over it ---
inprogress="A merge or rebase is in progress in this folder; finish or abort it first."
newcase; git -C "$c" checkout -q -b theirs; echo theirs > "$c/wp-content/keep.txt"; git -C "$c" commit -q -am theirs
git -C "$c" checkout -q main; echo ours > "$c/wp-content/keep.txt"; git -C "$c" commit -q -am ours; commits0="$(git -C "$c" rev-list --count HEAD)"
git -C "$c" push -q origin main; git -C "$c" merge -q theirs > /dev/null 2>&1
check "control: the merge stopped on a conflict" yes "$([ -f "$c/.git/MERGE_HEAD" ] && [ -n "$(git -C "$c" ls-files -u)" ] && echo yes)"
before="$(cat "$c/wp-content/keep.txt")"; pub; t="a merge stopped on a conflict"
check "$t: fails" failed "$(js state)"; check "$t: says so" "$inprogress" "$(js message)"; valid "$t"; nocommit "$t"; oldsite "$t"
check "$t: nothing pushed" "$(git -C "$c" rev-parse HEAD)" "$(git -C "$O" rev-parse main)"
check "$t: the merge is still in progress" yes "$([ -f "$c/.git/MERGE_HEAD" ] && echo yes)"
check "$t: its conflict is still there" yes "$([ -n "$(git -C "$c" ls-files -u)" ] && echo yes)"
check "$t: the conflicted file is untouched" "$before" "$(cat "$c/wp-content/keep.txt")"
check "$t: the export never ran" 0 "$(grep -c 'wp offprint export' "$S/docker.calls")"
newcase; git -C "$c" checkout -q -b feature; echo feature > "$c/wp-content/keep.txt"; git -C "$c" commit -q -am feature
git -C "$c" checkout -q main; echo main > "$c/wp-content/keep.txt"; git -C "$c" commit -q -am main
git -C "$c" checkout -q feature; git -C "$c" rebase main > /dev/null 2>&1
check "control: the rebase stopped on a conflict" yes "$([ -d "$c/.git/rebase-merge" ] || [ -d "$c/.git/rebase-apply" ] && echo yes)"
head_before="$(git -C "$c" rev-parse HEAD)"; pub; t="a rebase stopped on a conflict"
check "$t: fails" failed "$(js state)"; check "$t: says so" "$inprogress" "$(js message)"; valid "$t"
check "$t: HEAD didn't move" "$head_before" "$(git -C "$c" rev-parse HEAD)"; check "$t: nothing pushed" "$commits0" "$(git -C "$O" rev-list --count main)"
check "$t: the rebase is still in progress" yes "$([ -d "$c/.git/rebase-merge" ] || [ -d "$c/.git/rebase-apply" ] && echo yes)"
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge/ rebase-apply/; do
  newcase; case "$marker" in */) mkdir -p "$c/.git/$marker" ;; *) git -C "$c" rev-parse HEAD > "$c/.git/$marker" ;; esac
  pub --no-push; t="$marker in the git folder"; check "$t: refused" "$inprogress" "$(js message)"; nocommit "$t"
done

# --- git's own index: brought in line after the commit even if something holds its lock for a moment; and if it can't
# be, the status says exactly what to run, and the next publish puts it right first ---
# lock_index: when the publish moves the branch, something takes git's index lock (an editor's background git status,
# say), and with $S/release_lock gives it back a second later.
lock_index() {
  cat > "$S/action" <<ACTION
touch "$c/.git/index.lock" "$S/lock_taken"
[ -f "$S/release_lock" ] && ( sleep 1; rm -f "$c/.git/index.lock" ) > /dev/null 2>&1 &
exit 0
ACTION
  git_standin '*" update-ref "*'
}
stale="this folder's git index is out of date: run \`git reset -q -- site wp-content backup\` before committing anything here."
newcase; touch "$S/release_lock"; lock_index; pub --no-push; t="git's index locked for a second after the commit"
check "control: the lock was taken" yes "$([ -e "$S/lock_taken" ] && echo yes)"
check "$t: publishes" 0 "$code"; check "$t: no warning about the index" "" "$(js warnings | grep -F 'index is out of date')"
check "$t: git's index matches the commit" "" "$(git -C "$c" diff --cached --name-only HEAD)"
newcase; lock_index; PUBLISH_RESET_TRIES=3 PUBLISH_RESET_WAIT=0.1 pub; t="git's index locked until the publish ends"
check "control: the lock was taken" yes "$([ -e "$S/lock_taken" ] && echo yes)"
check "$t: the site is live" live "$(js state)"; valid "$t"
check "$t: the message says what to run" "The site is live at $(git -C "$c" rev-parse --short=7 HEAD), but $stale" "$(js message)"
check "$t: and the first warning says it too" "Action needed: $stale" "$(php -r 'echo json_decode( file_get_contents( $argv[1] ), true )["warnings"][0] ?? "";' "$c/var/status.json")"
check "control: git's index is still the one from before" yes "$([ -n "$(git -C "$c" diff --cached --name-only HEAD)" ] && echo yes)"
rm -f "$c/.git/index.lock" "$S/bin/git"; pub; t="the next publish, after the lock is gone"
check "$t: puts git's index right" "" "$(git -C "$c" diff --cached --name-only HEAD)"
check "$t: unchanged" unchanged "$(js state)"; check "$t: no warning about the index" "" "$(js warnings | grep -F 'index is out of date')"
newcase; echo changed > "$c/wp-content/keep.txt"; git -C "$c" add wp-content/keep.txt; echo 1 > "$S/export_exit"
pub --no-push; t="changes staged only inside site/, wp-content/ and backup/ (left by an earlier publish)"
check "$t: the run goes on (and fails later, at the export)" "The export failed; see var/publish.log" "$(js message)"
check "$t: they are unstaged first" "" "$(git -C "$c" diff --cached --name-only)"
check "$t: the file itself is untouched" changed "$(cat "$c/wp-content/keep.txt")"
contains "$t: and the log says so" "unstaged" "$(cat "$c/var/publish.log")"
newcase; echo changed > "$c/wp-content/keep.txt"; echo stray > "$c/stray.txt"; git -C "$c" add wp-content/keep.txt stray.txt
pub --no-push; t="changes staged inside and outside the three folders"
check "$t: refused" "There are staged changes; commit or unstage them first" "$(js message)"
check "$t: nothing unstaged" "stray.txt wp-content/keep.txt" "$(git -C "$c" diff --cached --name-only | tr '\n' ' ' | sed 's/ $//')"

# --- GitHub is checked before anything is committed, so main can fast-forward ---
newcase; git clone -q -b main "$O" "$tmp/case$n/other"; git -C "$tmp/case$n/other" config user.email t@example.com; git -C "$tmp/case$n/other" config user.name T
echo x > "$tmp/case$n/other/x.txt"; git -C "$tmp/case$n/other" add x.txt; git -C "$tmp/case$n/other" commit -q -m remote; git -C "$tmp/case$n/other" push -q origin main
pub; t="main on GitHub is ahead"
check "$t: refused" "Main on GitHub has changes this Mac doesn't have; pull first" "$(js message)"; nocommit "$t"; oldsite "$t"
check "$t: before the export" 0 "$(grep -c 'wp offprint export' "$S/docker.calls")"
check "$t: so git pull --ff-only works" 0 "$(git -C "$c" pull -q --ff-only origin main > /dev/null 2>&1; echo $?)"
pub; t="the publish after that pull"; check "$t: live" live "$(js state)"; check "$t: on top of GitHub's commit" "$((commits0 + 2))" "$(git -C "$O" rev-list --count main)"
# The race: GitHub moves between that check and the push. The second check refuses; git pull --rebase then works.
newcase; git clone -q -b main "$O" "$tmp/case$n/other"; git -C "$tmp/case$n/other" config user.email t@example.com; git -C "$tmp/case$n/other" config user.name T
cat > "$S/action" <<ACTION
echo x > "$tmp/case$n/other/x.txt"; git -C "$tmp/case$n/other" add x.txt; git -C "$tmp/case$n/other" commit -q -m remote; git -C "$tmp/case$n/other" push -q origin main
ACTION
git_standin '*" commit-tree "*'; pub; t="main on GitHub moves during the publish"
check "$t: refused" "Main on GitHub has changes this Mac doesn't have; pull first" "$(js message)"
check "$t: GitHub keeps its commit" remote "$(git -C "$O" log -1 --format=%s main)"
rm -f "$S/bin/git"; check "$t: git pull --rebase works" 0 "$(git -C "$c" pull -q --rebase origin main > /dev/null 2>&1; echo $?)"

# --- the branch couldn't be moved back: the message must not say it was ---
newcase; evil_repo "$S/evil"; real_git="$(command -v git)"
cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" add "*) [ -e "$c/wp-content/plugins/late" ] || cp -R "$S/evil" "$c/wp-content/plugins/late" ;; esac
case " \$* " in *" update-ref "*"undone"*) exit 1 ;; esac
case " \$* " in
  *" ls-tree "*" -l "*) "$real_git" "\$@" | grep -v '^160000'; exit "\${PIPESTATUS[0]}" ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$S/bin/git"; mkdir -p "$c/wp-content/plugins"; old_head="$(git -C "$c" rev-parse --short=7 HEAD)"
pub --no-push; t="a repository link the checks missed, and the branch can't be moved back"
check "$t: fails" failed "$(js state)"; valid "$t"
contains "$t: says it couldn't be moved back" "couldn't be moved back" "$(js message)"
check "$t: doesn't say it was" "" "$(js message | grep -F 'was moved back')"
contains "$t: names the command that puts it back" "git reset --soft $old_head" "$(js message)"

# --- bin/check-site that never finishes (an export built to keep it busy) is stopped, with what it started ---
newcase; toolcopy; cat > "$T/bin/check-site" <<'SLOW'
#!/usr/bin/env bash
sleep 37 &
wait $!
SLOW
chmod +x "$T/bin/check-site"; start=$SECONDS; PUBLISH_CHECK_TIMEOUT=1 pub_within 20 --no-push; t="bin/check-site never finishes"
check "$t: fails" failed "$(js state)"; valid "$t"; nocommit "$t"; oldsite "$t"
check "$t: says so" "Checking the export took longer than 1 seconds and was stopped; nothing was published." "$(js message)"
check "$t: soon after the limit" yes "$([ $((SECONDS - start)) -lt 10 ] && echo yes)"
sleep 1; check "$t: the check and what it started are stopped" "" "$(pgrep -f 'sleep 37')"
check "$t: the checked copy is removed" no "$([ -e "$c/site.new" ] && echo yes || echo no)"
newcase; PUBLISH_CHECK_TIMEOUT=30 pub --dry-run; t="a check that finishes within the limit"
check "$t: passes" 0 "$code"

# --- executable bits ---
newcase; printf '#!/bin/sh\n' > "$c/wp-content/run.sh"; chmod +x "$c/wp-content/run.sh"; pub --no-push; t="an executable file in wp-content"
check "$t: is committed as executable" 100755 "$(git -C "$c" ls-tree HEAD wp-content/run.sh | cut -c1-6)"
newcase; git -C "$c" config core.fileMode false; pub --no-push; t="core.fileMode is false"
check "$t: refused" failed "$(js state)"; valid "$t"; nocommit "$t"
contains "$t: says why and what to do" "git config core.fileMode true" "$(js message)"

# --- a site's names come from its site.json, and the tool runs in place for whichever site folder it is given ---
# The live check and the wait name the public address in site.json (no PUBLISH_CHECK_URL here).
newcase; out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
  /bin/bash "$T/bin/publish" 2>&1)"; code=$?; t="a full run, with the live check from site.json"
check "$t: live" live "$(js state)"; check "$t: exits 0" 0 "$code"; sha="$(git -C "$c" rev-parse HEAD)"
contains "$t: asks the public address in site.json for build.json" "https://www.example.com/build.json?c=$sha" "$(cat "$S/curl.calls")"
contains "$t: waits for the public host in site.json" "[deploying] Waiting for www.example.com to serve ${sha:0:7}" "$out"
compose_only "$t"
# A site folder whose path has a space and an XML character in it (Review Focus 5).
newcase "My Sites/a&b"; pub --no-push; t="a site folder at 'My Sites/a&b'"
check "$t: exits 0" 0 "$code"; valid "$t"
check "$t: ends Committed, not pushed" "[checking] Committed, not pushed (--no-push)." "$(printf '%s\n' "$out" | tail -n 1)"
check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: site/ equals the export" "" "$(diff -r "$c/site" "$S/fixture" 2>&1)"
check "$t: db.sql.age is the new dump, encrypted" "yes" "$(grep -q 'INSERT INTO t' "$c/backup/db.sql.age" && echo yes)"
compose_only "$t"
check "$t: the site folder reaches docker as one argument, every time" "" \
  "$(W="[compose][-p][example][--project-directory][$(cd "$c" && pwd -P)][-f][$(cd "$T" && pwd -P)/templates/compose.yaml][" \
    awk 'index($0, ENVIRON["W"]) != 1' "$S/docker.argv" 2>&1)"
check "$t: (three calls)" 3 "$(wc -l < "$S/docker.argv" | tr -d ' ')"
pub --no-push; t="the same site folder, nothing changed"; check "$t: state" unchanged "$(js state)"
# Run from a folder inside the site, with no OFFPRINT_SITE: it finds the site above and works there.
newcase; out="$(cd "$c/wp-content" && env -u OFFPRINT_SITE PATH="$S/bin:$PATH" STUB_DIR="$S" /bin/bash "$T/bin/publish" --no-push 2>&1)"; code=$?
t="run from wp-content/, with no OFFPRINT_SITE"
check "$t: exits 0" 0 "$code"; check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: site/ equals the export" "" "$(diff -r "$c/site" "$S/fixture" 2>&1)"; compose_only "$t"
# Outside any site folder: one clear message, exit 2, nothing started (Review Focus 4).
newcase; out="$(cd "$tmp/nosite" && PATH="$S/bin:$PATH" STUB_DIR="$S" /bin/bash "$T/bin/publish" --no-push 2>&1)"; code=$?; t="run outside any site folder"
check "$t: exits 2" 2 "$code"; check "$t: says so" "$nosite_msg" "$out"
check "$t: docker never called" no "$([ -e "$S/docker.calls" ] && echo yes || echo no)"; nocommit "$t"
# A site.json that doesn't pass lib/config.php: nothing is run, and the publish ends failed in var/status.json, saying
# why. A "live" left there from before would keep the admin bar saying Live, while the agent took the request as done.
# (This used to be "nothing written in var/": the site folder is known, so the failure is written there.)
live_before() { printf '{"state":"live","running":false,"at":"2026-11-20T10:00:00Z","commit":"%s","message":"The site is live at abc1234.","warnings":[]}\n' abc1234 > "$c/var/status.json"; }
newcase; printf '{"format":1,"name":"example","public_url":"https://www.example.com","local_host":"a b;id","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998}\n' > "$c/site.json"
live_before; pub --no-push; t="a site.json with a bad local_host"
check "$t: exits 1" 1 "$code"; contains "$t: names the field" 'site.json: "local_host"' "$out"
check "$t: the status is failed, not the live from before" failed "$(js state)"; valid "$t"
check "$t: the status says why" 'site.json has a problem: site.json: "local_host" must be a lowercase hostname with at least one dot; nothing was published.' "$(js message)"
contains "$t: and so does the log" 'site.json: "local_host" must be a lowercase hostname' "$(cat "$c/var/publish.log")"
check "$t: docker never called" no "$([ -e "$S/docker.calls" ] || [ -e "$S/docker.queries" ] && echo yes || echo no)"
check "$t: the lock is released" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"; nocommit "$t"; oldsite "$t"
newcase; sed 's/^{/{"colour":"red",/' "$SRC/tests/fixtures/site.json" > "$c/site.json"; live_before; pub; t="a site.json with an unknown key"
check "$t: exits 1" 1 "$code"; check "$t: failed" failed "$(js state)"; valid "$t"
check "$t: the status names the key" 'site.json has a problem: site.json: "colour" is not a known field; nothing was published.' "$(js message)"
check "$t: docker never called" no "$([ -e "$S/docker.calls" ] || [ -e "$S/docker.queries" ] && echo yes || echo no)"; nocommit "$t"
# php is what reads site.json (and writes status.json): without it, the status is still written, saying so.
minbin="$tmp/minbin"; mkdir -p "$minbin"
for tool in awk basename bash cat chmod cmp cp cut date dirname env find git grep head ls mkdir mktemp mv pgrep ps rm sed sleep sort tail tr wc; do
  p="$(command -v "$tool")" && ln -s "$p" "$minbin/$tool"
done
newcase; live_before; PATH="$minbin" pub --no-push; t="php is not on the PATH"
check "control: there is no php on that PATH" no "$(PATH="$S/bin:$minbin" command -v php > /dev/null && echo yes || echo no)"
check "$t: exits 1" 1 "$code"; check "$t: failed" failed "$(js state)"; valid "$t"
check "$t: the status says why" "php isn't on the PATH, so site.json couldn't be read; nothing was published." "$(js message)"
check "$t: docker never called" no "$([ -e "$S/docker.calls" ] || [ -e "$S/docker.queries" ] && echo yes || echo no)"
check "$t: the lock is released" no "$([ -e "$c/var/publish.lock" ] && echo yes || echo no)"; nocommit "$t"; oldsite "$t"
# bin/check-site is given both hosts from site.json.
newcase; echo '<a href="https://www.example.com/wp-json/x">x</a>' > "$S/fixture/hello/index.html"; pub --no-push; t="an export linking to the public host's /wp-json/"
check "$t: fails the checks" failed "$(js state)"; contains "$t: says why" "hello/index.html: https://www.example.com/wp-json/x points at /wp-json" "$(js message)"
nocommit "$t"; oldsite "$t"
newcase; echo '<p>mysite&#46;test</p>' > "$S/fixture/hello/index.html"; pub --no-push; t="an export naming the local host from site.json, its dot encoded"
check "$t: fails the checks" failed "$(js state)"; contains "$t: names it" "contains mysite.test: hello/index.html" "$(js message)"
nocommit "$t"; oldsite "$t"

# --- a site.json WordPress could have planted in a folder it writes is never taken for the site ---
# planted_json DIR: a valid site.json in DIR naming another compose project, local host and public address
planted_json() {
  printf '{"format":1,"name":"othersite","public_url":"https://attacker.example","local_host":"nothing.invalid","local_ip4":"127.0.0.66","local_ip6":"fd00::66","tls_port":5999,"http_port":5998}\n' > "$1/site.json"
}
inside_msg() { echo "site.json at $(cd "$1" && pwd -P)/site.json is inside the site folder $(cd "$c" && pwd -P); cd to $(cd "$c" && pwd -P) or set OFFPRINT_SITE."; }
newcase; planted_json "$c/wp-content"
out="$(cd "$c/wp-content" && env -u OFFPRINT_SITE PATH="$S/bin:$PATH" STUB_DIR="$S" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
  PUBLISH_CHECK_URL=https://example.test/build.json /bin/bash "$SRC/bin/offprint" publish 2>&1)"; code=$?
t="a site.json planted in wp-content/, offprint publish run there"
check "$t: exits 2" 2 "$code"; check "$t: says which site.json is inside which site folder" "$(inside_msg "$c/wp-content")" "$out"
check "$t: docker never called" no "$([ -e "$S/docker.calls" ] && echo yes || echo no)"
check "$t: nothing made in var/" "" "$(ls -A "$c/var")"; check "$t: nor a var/ in wp-content/" no "$([ -e "$c/wp-content/var" ] && echo yes || echo no)"
nocommit "$t"; oldsite "$t"; check "$t: nothing pushed" "$commits0" "$(git -C "$O" rev-list --count main)"

# --- a real publish needs the site folder to be the top of its own git repository ---
# Inside another repository, git would commit into that one, with paths relative to the subfolder, and the site's
# .gitignore anchoring would not apply.
newcase "outer/repo"; rm -rf "$c/.git"; outer="$tmp/case$n/outer"
git init -q -b main "$outer"; git -C "$outer" config user.email t@example.com; git -C "$outer" config user.name Test
git -C "$outer" add -A && git -C "$outer" commit -q -m outer; outer_commits="$(git -C "$outer" rev-list --count HEAD)"
pub --no-push; t="a site folder inside another git repository"
check "$t: fails" failed "$(js state)"; valid "$t"
check "$t: says so, naming git's top" "This site folder isn't the top of its own git repository (git's is $(cd "$outer" && pwd -P)); nothing was published." "$(js message)"
check "$t: no commit in the outer repository" "$outer_commits" "$(git -C "$outer" rev-list --count HEAD)"
check "$t: nothing staged there" "" "$(git -C "$outer" status --porcelain --untracked-files=no)"
check "$t: the export never ran" 0 "$(grep -c 'wp offprint export' "$S/docker.calls")"; oldsite "$t"
pub --dry-run; t="the same folder, a dry run (it commits nothing, so it may)"
check "$t: passes the checks" 0 "$code"; check "$t: its message" "Dry run: a copy of the export passed the checks; the export is in var/export, and nothing else changed." "$(js message)"
# (With the tool's own adapter, none: an adapter in the site folder must be committed in its repository, so with no
# repository that adapter is what is refused, before this.)
newcase; cp "$SRC/tests/fixtures/site.json" "$c/site.json"; rm -rf "$c/.git"; pub --no-push; t="a site folder that isn't a git repository"
check "$t: fails" failed "$(js state)"; valid "$t"
check "$t: says to git init" "This site folder isn't a git repository; run git init here first." "$(js message)"
check "$t: the export never ran" 0 "$(grep -c 'wp offprint export' "$S/docker.calls")"; oldsite "$t"
newcase; ln -s "$c" "$tmp/case$n/link"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$tmp/case$n/link" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
  PUBLISH_CHECK_URL=https://example.test/build.json /bin/bash "$T/bin/publish" --no-push 2>&1)"; code=$?
t="OFFPRINT_SITE given through a symlink to a site folder that is its repository's top"
check "$t: publishes" 0 "$code"; check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: Committed, not pushed" "Committed, not pushed (--no-push)." "$(js message)"
# On a disk that ignores case (the Mac's, by default) a site folder reached by a name in another case is the same
# folder, and git names it in the disk's own case: still the top of its repository.
touch "$tmp/CaseProbe"
if [ -e "$tmp/caseprobe" ]; then
  newcase CaseSite
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$tmp/case$n/casesite" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
    PUBLISH_CHECK_URL=https://example.test/build.json /bin/bash "$T/bin/publish" --no-push 2>&1)"; code=$?
  t="OFFPRINT_SITE naming the site folder in another case (CaseSite as casesite)"
  check "$t: publishes" 0 "$code"; check "$t: Committed, not pushed" "Committed, not pushed (--no-push)." "$(js message)"
  check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
  newcase CaseSite
  out="$(cd "$tmp/case$n/casesite/wp-content" && env -u OFFPRINT_SITE PATH="$S/bin:$PATH" STUB_DIR="$S" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
    PUBLISH_CHECK_URL=https://example.test/build.json /bin/bash "$T/bin/publish" --no-push 2>&1)"; code=$?
  t="run from casesite/wp-content (the folder is CaseSite), with no OFFPRINT_SITE"
  check "$t: publishes" 0 "$code"; check "$t: Committed, not pushed" "Committed, not pushed (--no-push)." "$(js message)"
  check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
else
  echo "skip  a site folder reached by a name in another case (this disk minds case)"
fi
# git's own variables that say where a repository is (git exports GIT_DIR inside any hook, say) can't send the publish
# into another repository, or its index.
other_repo() {
  other="$tmp/case$n/other"; git init -q -b main "$other"; git -C "$other" config user.email t@example.com; git -C "$other" config user.name T
  echo o > "$other/o.txt"; git -C "$other" add o.txt; git -C "$other" commit -q -m other
  other_head="$(git -C "$other" rev-parse HEAD)"; other_index="$(cksum < "$other/.git/index")"; other_files="$(cd "$other" && ls -A)"
}
other_untouched() {
  check "$1: the other repository's HEAD is unchanged" "$other_head" "$(git -C "$other" rev-parse HEAD)"
  check "$1: and its index" "$other_index" "$(cksum < "$other/.git/index")"
  check "$1: and its files" "$other_files" "$(cd "$other" && ls -A)"
  check "$1: nothing of the site's is committed there" "" "$(git -C "$other" log --all --name-only --format= | grep -E '^(site|backup|wp-content)/')"
}
newcase; other_repo; GIT_DIR="$other/.git" pub --no-push; t="GIT_DIR exported, naming another repository"
check "$t: publishes" 0 "$code"; check "$t: into the site's own repository" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: the dump is in the site's commit" 1 "$(git -C "$c" show HEAD:backup/db.sql.age | grep -c 'INSERT INTO t')"
other_untouched "$t"
newcase; other_repo; GIT_WORK_TREE="$other" pub --no-push; t="GIT_WORK_TREE exported, naming another folder"
check "$t: publishes" 0 "$code"; check "$t: into the site's own repository" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
other_untouched "$t"
newcase; other_repo; GIT_INDEX_FILE="$other/.git/index" pub --no-push; t="GIT_INDEX_FILE exported, naming another repository's index"
check "$t: publishes" 0 "$code"; check "$t: into the site's own repository" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: the site's own index matches its commit" "" "$(git -C "$c" diff --cached --name-only HEAD)"
other_untouched "$t"

# --- bin/offprint: the one command, which runs the scripts above ---
newcase; out="$(/bin/bash "$SRC/bin/offprint" help 2>&1)"; code=$?; t="offprint help"
check "$t: exits 0" 0 "$code"
for cmd in "publish [--dry-run] [--no-push]" "agent" "wp ARGS" "compose ARGS" "setup-wp" "install-agent [--force] [--remove | --print]" \
  "host-setup [--print]" "host-undo [--print]" "check DIR" "help"; do
  contains "$t: lists offprint $cmd" "offprint $cmd" "$out"
done
help="$out"; out="$(/bin/bash "$SRC/bin/offprint" 2>&1)"; code=$?; t="offprint with no command"
check "$t: prints the list" "$help" "$out"; check "$t: exits 0" 0 "$code"
for unknown in nonsense --dry-run ''; do
  newcase; out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" "$unknown" publish 2>&1)"; code=$?
  t="offprint '$unknown' (an unknown command)"
  check "$t: exits 2" 2 "$code"; contains "$t: says so" "offprint: unknown command '$unknown'" "$out"; contains "$t: and lists the commands" "offprint publish" "$out"
  check "$t: runs nothing" no "$([ -e "$S/docker.calls" ] && echo yes || echo no)"; nocommit "$t"
done
# Outside any site folder, every command that needs one says so and starts nothing.
for args in "publish --no-push" "agent" "wp option get siteurl" "compose ps" "setup-wp" "install-agent --print" "host-setup" "host-undo --print" \
  "check $tmp/nosite"; do
  newcase; out="$(cd "$tmp/nosite" && PATH="$S/bin:$PATH" STUB_DIR="$S" /bin/bash "$SRC/bin/offprint" $args 2>&1)"; code=$?
  t="offprint $(printf '%s' "$args" | sed "s#$tmp#TMP#"), outside any site folder"
  check "$t: exits 2" 2 "$code"; check "$t: says so" "$nosite_msg" "$out"
  check "$t: starts nothing" no "$([ -e "$S/docker.calls" ] && echo yes || echo no)"
done
# Through a symlink on PATH (as it would be installed), itself pointing at a symlink, without readlink's -f.
newcase; mkdir -p "$tmp/case$n/pathbin" "$tmp/case$n/links"
ln -s "$SRC/bin/offprint" "$tmp/case$n/links/offprint-real"; ln -s ../links/offprint-real "$tmp/case$n/pathbin/offprint"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$tmp/case$n/pathbin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 \
  PUBLISH_TIMEOUT_SECONDS=2 PUBLISH_CHECK_URL=https://example.test/build.json offprint publish --no-push 2>&1)"; code=$?
t="offprint publish --no-push, through two symlinks on PATH"
check "$t: exits 0" 0 "$code"; check "$t: ends Committed, not pushed" "Committed, not pushed (--no-push)." "$(js message)"
check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"; compose_only "$t"
check "bin/offprint never uses readlink -f (older macOS has no -f)" "" "$(grep -nE '^[^#]*readlink[[:space:]]+-[a-zA-Z]*f' "$SRC/bin/offprint")"
# offprint compose ARGS: docker compose for this site's project.
newcase; out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" compose ps --status running --services 2>&1)"; code=$?
t="offprint compose ps"
check "$t: exits 0" 0 "$code"; check "$t: docker's answer" "wordpress
db" "$out"
check "$t: exactly that call, for this site's project" \
  "compose -p example --project-directory $(cd "$c" && pwd -P) -f $(cd "$SRC" && pwd -P)/templates/compose.yaml ps --status running --services" \
  "$(cat "$S/docker.calls")"
compose_only "$t"
newcase; echo 7 > "$S/ps_exit"; out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" compose ps 2>&1)"; code=$?
check "offprint compose: docker's exit code is its own" 7 "$code"
# offprint wp ARGS: WP-CLI in the site's wordpress container, as www-data (no terminal here, so -T).
newcase; out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" wp option get siteurl < /dev/null 2>&1)"; code=$?
t="offprint wp option get siteurl"
check "$t: exits 0" 0 "$code"; check "$t: WP-CLI's answer" https://mysite.test "$out"
check "$t: exec -T -u www-data wordpress wp ..." "compose -p example --project-directory $(cd "$c" && pwd -P) -f $(cd "$SRC" && pwd -P)/templates/compose.yaml exec -T -u www-data wordpress wp option get siteurl" \
  "$(cat "$S/docker.calls")"
compose_only "$t"
# offprint check DIR: bin/check-site with both hosts from site.json; DIR is the caller's, not the site's.
newcase; cp -R "$S/fixture" "$tmp/case$n/out"
run_check() { out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" check out 2>&1)"; code=$?; }
t="offprint check DIR"
run_check; check "$t: a clean export passes" "0|" "$code|$out"
echo '<p>https://mysite.test/</p>' > "$tmp/case$n/out/hello/index.html"; run_check
check "$t: the local host in site.json fails it" 1 "$code"; contains "$t: naming it" "contains mysite.test: hello/index.html" "$out"
echo '<a href="https://www.example.com/wp-admin/">x</a>' > "$tmp/case$n/out/hello/index.html"; run_check
check "$t: so does an address on the public host in site.json" 1 "$code"
contains "$t: naming it" "hello/index.html: https://www.example.com/wp-admin/ points at /wp-admin" "$out"
out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" check 2>&1)"; code=$?
check "$t: without DIR: usage, exit 2" 2 "$code"
# offprint check . inside var/export, where a site.json was planted: refused before bin/check-site runs with its hosts.
# (A copy of the tool whose bin/check-site only notes the hosts it was given.)
newcase; toolcopy; printf '#!/bin/sh\necho "$CHECK_SITE_HOST $CHECK_SITE_LOCAL_HOST $*" >> "%s/check-ran"\n' "$S" > "$T/bin/check-site"
mkdir -p "$c/var/export"; cp -R "$S/fixture/." "$c/var/export/"; planted_json "$c/var/export"
out="$(cd "$c/var/export" && env -u OFFPRINT_SITE /bin/bash "$T/bin/offprint" check . 2>&1)"; code=$?
t="offprint check . inside var/export, with a site.json planted there"
check "$t: exits 2" 2 "$code"; check "$t: says which site.json is inside which site folder" "$(inside_msg "$c/var/export")" "$out"
check "$t: bin/check-site never ran" no "$([ -e "$S/check-ran" ] && echo yes || echo no)"
out="$(cd "$c" && env -u OFFPRINT_SITE /bin/bash "$T/bin/offprint" check var/export 2>&1)"; code=$?
check "$t: control: from the site folder, it runs with the site's own hosts" "www.example.com mysite.test var/export" "$(cat "$S/check-ran" 2>&1)"
# offprint agent: bin/publish-agent for the site.
newcase; mkdir -p "$c/var/inbox"; echo "2026-11-20T10:00:00Z button" > "$c/var/inbox/publish-request"
printf '#!/bin/sh\necho "$PWD|$OFFPRINT_SITE" > "%s/ran"\n' "$S" > "$S/publish-standin"; chmod +x "$S/publish-standin"
out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" PUBLISH_AGENT_PUBLISH="$S/publish-standin" PUBLISH_AGENT_MIN_SECONDS=0 PUBLISH_AGENT_SETTLE_SECONDS=0 \
  /bin/bash "$SRC/bin/offprint" agent 2>&1)"; code=$?; t="offprint agent"
check "$t: exits 0" 0 "$code"
check "$t: ran the publish once, in the site folder, for the site" "$(cd "$c" && pwd -P)|$(cd "$c" && pwd -P)" "$(cat "$S/ran" 2>&1)"

# --- the compose project named in site.json must be this site folder's own ---
# A compose project is only a name. docker compose -p NAME, given Offprint's compose file, would take over whatever
# containers and volumes carry that name, from whichever folder made them (another tool's project, a copy of this site
# folder), and setup-wp would then change the WordPress it found there. So every command that runs compose asks Docker
# first (the stand-in answers from the case's containers and volumes files).
# op ARGS...: bin/offprint for the site $c, from the case folder, with the
# stand-ins and nothing on stdin; sets out, code
op() {
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="${OP_SITE:-$c}" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
    PUBLISH_CHECK_URL=https://example.test/build.json /bin/bash "$SRC/bin/offprint" "$@" < /dev/null 2>&1)"; code=$?
}
# files: every path in the site folder but its .git (what a refusal must leave as it was)
files() { (cd "$c" && find . -path ./.git -prune -o -print | LC_ALL=C sort); }
no_compose() { check "$1: docker compose never ran" no "$([ -e "$S/docker.calls" ] && echo yes || echo no)"; }
fresh_calls() { rm -f "$S/docker.calls" "$S/docker.queries" "$S/docker.argv" "$S/docker.env" "$S/mkcert.calls"; }
other_msg() {  # FOLDER: the refusal, for a project of the site's name made from FOLDER
  printf 'A Docker compose project called example already exists, made from %s, not from this site folder (%s). Change "name" in site.json, or, if this is the same site moved to a new folder, remove its old containers first: docker compose -p example down (its data volumes are kept).' \
    "$1" "$(cd "$c" && pwd -P)"
}
newcase; elsewhere="$tmp/case$n/elsewhere/blog"; mkdir -p "$elsewhere"; echo "$elsewhere" > "$S/containers"; before="$(files)"
for args in "compose up -d" "compose ps" "setup-wp" "wp option get siteurl"; do
  fresh_calls; op $args; t="offprint $args, with a compose project of the site's name made from another folder"
  check "$t: refused, exit 2" 2 "$code"; contains "$t: says whose it is, and what to do" "$(other_msg "$elsewhere")" "$out"
  no_compose "$t"; check "$t: nothing written" "$before" "$(files)"
  check "$t: Docker was asked" 1 "$(grep -c '^ps -a ' "$S/docker.queries" 2>/dev/null)"
done
check "offprint setup-wp, refused: mkcert never ran" no "$([ -e "$S/mkcert.calls" ] && echo yes || echo no)"
fresh_calls; live_before; op publish --no-push; t="offprint publish, with a compose project of the site's name made from another folder"
check "$t: refused, exit 2" 2 "$code"; contains "$t: says whose it is, and what to do" "$(other_msg "$elsewhere")" "$out"
no_compose "$t"; nocommit "$t"; oldsite "$t"; oldbackup "$t"
check "$t: the status is failed, with that message" "failed|$(other_msg "$elsewhere")" "$(js state)|$(js message)"; valid "$t"
check "$t: nothing else in var/ (no export)" "publish.log status.json" "$(ls -A "$c/var" | paste -sd' ' -)"
fresh_calls; OFFPRINT_PROJECT_OK="example|$(cd "$c" && pwd -P)" op compose up -d; t="the same, with the check's remembered answer set beforehand in the environment"
check "$t: still refused" 2 "$code"; no_compose "$t"
newcase; echo "$tmp/case$n/gone" > "$S/containers"; op compose up -d; t="a project of the site's name made from a folder that is gone"
check "$t: refused" 2 "$code"; contains "$t: names it" "$(other_msg "$tmp/case$n/gone")" "$out"; no_compose "$t"
newcase; printf '%s\n' "$c" "$tmp/case$n/copy" > "$S/containers"; op compose up -d; t="a project with containers from this folder and from another"
check "$t: refused" 2 "$code"; contains "$t: names the other" "$(other_msg "$tmp/case$n/copy")" "$out"; no_compose "$t"
newcase; printf '%s/x\033[31m\n' "$tmp/case$n" > "$S/containers"; op compose up -d; t="a project folder with a control character in its name"
check "$t: refused" 2 "$code"; contains "$t: shown as ?" "$(other_msg "$tmp/case$n/x?[31m")" "$out"
check "$t: no control character reaches the terminal" no "$(printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')" && echo yes || echo no)"
newcase; printf '%s\n' "$c" > "$S/containers"; op compose up -d
check "this folder's own containers, recorded by a name with a link in it (the temporary folder, on the Mac): goes on" 0 "$code"
# One with no folder recorded (made by hand, say) is refused too.
newcase; : > "$S/containers"; echo "" >> "$S/containers"; op compose up -d; t="a container of the project with no folder recorded"
check "$t: refused" 2 "$code"; no_compose "$t"
# This folder's own project: everything goes on.
ours_vols='example_db "example" "1" "db"
example_wordpress "example" "1" "wordpress"'
newcase; echo "$c" > "$S/containers"; printf '%s\n' "$ours_vols" > "$S/volumes"
op compose ps; t="offprint compose ps, the project made from this folder"; check "$t: works" "0|wordpress db" "$code|$(printf '%s' "$out" | paste -sd' ' -)"
op wp option get siteurl; t="offprint wp, the project made from this folder"; check "$t: works" "0|https://mysite.test" "$code|$out"
fresh_calls; pub --no-push; t="offprint publish, the project made from this folder"; check "$t: works" 0 "$code"; compose_only "$t"
fresh_calls; op setup-wp; t="offprint setup-wp, the project made from this folder"
check "$t: works" 0 "$code"; contains "$t: to the end" "Done: https://mysite.test/" "$out"
check "$t: with a certificate" yes "$([ -s "$c/local/certs/local.pem" ] && echo yes)"; check "$t: and the plugin" yes "$([ -f "$c/wp-content/mu-plugins/offprint.php" ] && echo yes)"
compose_only "$t"; contains "$t: it started the containers" "up -d --build --wait db wordpress" "$(cat "$S/docker.calls")"
# --- offprint setup-wp: the two traps of a first publish go ---
# WordPress's Sample Page (post 2 of a new install) links to /wp-admin/, which the export checks refuse: on a WordPress
# this run installed (WP-CLI said "Success:"), it is deleted, but only when it is that page, never changed. And a publish
# refuses while the plugin copy is uncommitted: on any run, this Offprint's plugin is committed alone, as "Offprint's
# plugin", when the site folder is the top of its git repository with nothing staged and HEAD doesn't have it; else
# what to do is said.
sample='{"post_type":"page","post_name":"sample-page","post_date":"2026-11-23 10:00:00","post_modified":"2026-11-23 10:00:00"}'
fresh_wp() {  # fresh_wp [POST2]: a case whose WordPress isn't installed yet, with post 2 as POST2 (no post 2 without it)
  bare_newcase; touch "$S/wp_not_installed"; [ $# -eq 0 ] || printf '%s\n' "$1" > "$S/post2.json"
}
setup_wp() { WP_ADMIN_USER=admin WP_ADMIN_EMAIL=admin@example.com WP_ADMIN_PASSWORD=secret op setup-wp; }
plugin_copy() { (cd "$c" && find wp-content/mu-plugins -type f ! -name .DS_Store | LC_ALL=C sort); }
not_deleted() { check "$1: post 2 is not deleted" "" "$(grep 'wp post delete' "$S/docker.calls")"; contains "$1: says so" "No untouched Sample Page to delete" "$out"; }
# tool_tree: the tool's own plugin (offprint.php, and every file under offprint/ but Finder's .DS_Store) as git ls-tree -r
# lists it in a site: mode, blob, the hash of its bytes as they are (no filter), path. head_tree: what HEAD has there.
tool_tree() {
  (cd "$SRC/plugin" && find offprint.php offprint -type f ! -name .DS_Store) | while IFS= read -r f; do
    printf '100644 blob %s\twp-content/mu-plugins/%s\n' "$(git hash-object --no-filters -- "$SRC/plugin/$f")" "$f"
  done | LC_ALL=C sort
}
head_tree() { git -C "$c" ls-tree -r HEAD -- wp-content/mu-plugins/offprint.php wp-content/mu-plugins/offprint | LC_ALL=C sort; }
again="run offprint setup-wp again to commit it"
committed_msg="Committed this Offprint's plugin as \"Offprint's plugin\" (wp-content/mu-plugins/offprint.php and wp-content/mu-plugins/offprint)."
differs_msg="The commit holds this Offprint's own plugin, but the copy on disk differs from it"
fresh_wp "$sample"; setup_wp; t="offprint setup-wp, installing WordPress"
check "$t: works" 0 "$code"; contains "$t: to the end" "Done: https://mysite.test/" "$out"
contains "$t: it installed WordPress" "wp core install" "$(cat "$S/docker.calls")"
contains "$t: WP-CLI's own line shown" "Success: WordPress installed successfully." "$out"
check "$t: asked WP-CLI about post 2" 1 "$(grep -c 'wp post get 2 --fields=post_type,post_name,post_date,post_modified --format=json$' "$S/docker.calls")"
check "$t: deleted it, the untouched Sample Page, once" 1 "$(grep -c 'wp post delete 2 --force$' "$S/docker.calls")"
contains "$t: says so" "Deleted WordPress's Sample Page (post 2, never changed)" "$out"
check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: its message" "Offprint's plugin" "$(git -C "$c" log -1 --format=%B | sed '/^$/d')"
check "$t: holding the plugin copy, and nothing else" "$(plugin_copy)" "$(git -C "$c" show --name-only --format= HEAD | sed '/^$/d' | LC_ALL=C sort)"
check "$t: the plugin copy is the tool's" "" "$(diff -r "$SRC/plugin/offprint" "$c/wp-content/mu-plugins/offprint" 2>&1; cmp "$SRC/plugin/offprint.php" "$c/wp-content/mu-plugins/offprint.php" 2>&1)"
check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
check "$t: nothing left staged or changed" "" "$(git -C "$c" status --porcelain)"
contains "$t: says so" "$committed_msg" "$out"
check "$t: no word that the copy differs" "" "$(printf '%s\n' "$out" | grep -F "$differs_msg")"
bare_newcase; echo "$c" > "$S/containers"; printf '%s\n' "$sample" > "$S/post2.json"; setup_wp; t="offprint setup-wp, WordPress installed already"
check "$t: works" 0 "$code"; contains "$t: says so" "WordPress is already installed." "$out"
check "$t: post 2 neither looked at nor deleted" "" "$(grep 'wp post' "$S/docker.calls")"
check "$t: the plugin committed all the same, as Offprint's plugin" "$((commits0 + 1))|Offprint's plugin" "$(git -C "$c" rev-list --count HEAD)|$(git -C "$c" log -1 --format=%B | sed '/^$/d')"
check "$t: the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
check "$t: nothing left staged or changed" "" "$(git -C "$c" status --porcelain)"
contains "$t: says it committed it" "$committed_msg" "$out"
check "$t: no word of the Sample Page" "" "$(printf '%s\n' "$out" | grep -e 'Sample Page')"
setup_wp; t="offprint setup-wp, WordPress installed already, run again"
check "$t: works, no new commit" "0|$((commits0 + 1))" "$code|$(git -C "$c" rev-list --count HEAD)"
contains "$t: says it is committed already" "The plugin copy is committed already." "$out"
# An install that finds WordPress installed already (WP-CLI says so, and succeeds) didn't install it: post 2 is left alone.
fresh_wp "$sample"; touch "$S/install_already"; setup_wp; t="offprint setup-wp, is-installed fails, then the install finds WordPress installed already"
check "$t: works" 0 "$code"; contains "$t: WP-CLI's line shown" "WordPress is already installed." "$out"
check "$t: post 2 neither looked at nor deleted" "" "$(grep 'wp post' "$S/docker.calls")"
check "$t: no word of the Sample Page" "" "$(printf '%s\n' "$out" | grep -e 'Sample Page')"
check "$t: the plugin committed" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
for spec in '{"post_type":"page","post_name":"sample-page","post_date":"2026-11-23 10:00:00","post_modified":"2026-11-23 10:05:00"}|changed since' \
    '{"post_type":"post","post_name":"sample-page","post_date":"2026-11-23 10:00:00","post_modified":"2026-11-23 10:00:00"}|a post, not a page' \
    '{"post_type":"page","post_name":"about","post_date":"2026-11-23 10:00:00","post_modified":"2026-11-23 10:00:00"}|another slug' \
    '{"post_type":"page","post_name":"sample-page"}|no dates' 'not JSON|WP-CLI saying something else'; do
  fresh_wp "${spec%|*}"; setup_wp; t="offprint setup-wp, installing WordPress, post 2 ${spec#*|}"
  check "$t: works" 0 "$code"; not_deleted "$t"; check "$t: the plugin still committed" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
done
fresh_wp; setup_wp; t="offprint setup-wp, installing WordPress, no post 2"
check "$t: works" 0 "$code"; not_deleted "$t"
fresh_wp "$sample"; touch "$S/post_delete_fails"; setup_wp; t="offprint setup-wp, installing WordPress, the deletion fails"
check "$t: works" 0 "$code"; contains "$t: says so, and the command" "Couldn't delete WordPress's Sample Page (post 2), which links to /wp-admin/ (the export checks refuse that): offprint wp post delete 2 --force" "$out"
# The plugin copy, when it can't be committed alone
fresh_wp "$sample"; echo staged > "$c/notes.txt"; git -C "$c" add notes.txt; setup_wp; t="offprint setup-wp, installing WordPress, something else staged"
check "$t: works" 0 "$code"; check "$t: nothing committed" "$commits0" "$(git -C "$c" rev-list --count HEAD)"
check "$t: what was staged still is, and only it" "A  notes.txt|?? wp-content/mu-plugins/" "$(git -C "$c" status --porcelain | paste -sd'|' -)"
contains "$t: says why, and what to do" "The plugin copy wasn't committed, as something else is staged; commit or unstage that, then run offprint setup-wp again to commit it alone." "$out"
fresh_wp "$sample"; git -C "$c" config --unset user.email; git -C "$c" config --unset user.name; setup_wp; t="offprint setup-wp, installing WordPress, no git identity"
check "$t: works" 0 "$code"; check "$t: nothing committed or staged" "$commits0|?? wp-content/mu-plugins/" "$(git -C "$c" rev-list --count HEAD)|$(git -C "$c" status --porcelain | paste -sd'|' -)"
contains "$t: says why, and what to do" "The plugin copy wasn't committed: git has no user.name and user.email. Set them (git config), then $again." "$out"
fresh_wp "$sample"; printf '#!/bin/sh\necho "a hook said no" >&2\nexit 1\n' > "$c/.git/hooks/pre-commit"; chmod +x "$c/.git/hooks/pre-commit"
setup_wp; t="offprint setup-wp, installing WordPress, the commit fails"
check "$t: works" 0 "$code"; check "$t: nothing committed, nothing left staged" "$commits0|?? wp-content/mu-plugins/" "$(git -C "$c" rev-list --count HEAD)|$(git -C "$c" status --porcelain | paste -sd'|' -)"
contains "$t: says why, and what to do" "Couldn't commit the plugin copy (git said: a hook said no); once that is put right, $again." "$out"
fresh_wp "$sample"; rm -rf "$c/.git"; setup_wp; t="offprint setup-wp, installing WordPress, the site folder not a git repository"
check "$t: works" 0 "$code"; contains "$t: says why, and what to do" "The plugin copy wasn't committed: the site folder isn't the top of a git repository (a publish needs it to be). Once it is, $again." "$out"
fresh_wp "$sample"; rm -rf "$c/.git"; git init -q -b main "$tmp/case$n"; setup_wp; t="offprint setup-wp, installing WordPress, the site folder inside another repository"
check "$t: works" 0 "$code"; contains "$t: says why" "the site folder isn't the top of a git repository" "$out"
check "$t: nothing staged there" "" "$(git -C "$tmp/case$n" diff --cached --name-only)"
fresh_wp "$sample"; mkdir -p "$c/wp-content/mu-plugins"; cp -R "$SRC/plugin/offprint.php" "$SRC/plugin/offprint" "$c/wp-content/mu-plugins/"
git -C "$c" add wp-content/mu-plugins; git -C "$c" commit -q -m "the plugin"; setup_wp; t="offprint setup-wp, installing WordPress, the plugin copy committed already"
check "$t: works" 0 "$code"; check "$t: no new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
contains "$t: says so" "The plugin copy is committed already." "$out"
# A repository with no commit yet: the plugin is its first; and when that commit fails, the index is empty again.
fresh_wp "$sample"; rm -rf "$c/.git"; git init -q -b main "$c"; git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
setup_wp; t="offprint setup-wp, the site folder a repository with no commit yet"
check "$t: works, one commit, Offprint's plugin" "0|1|Offprint's plugin" "$code|$(git -C "$c" rev-list --count HEAD 2>&1)|$(git -C "$c" log -1 --format=%B 2>&1 | sed '/^$/d')"
check "$t: the tool's plugin, byte for byte, and nothing else" "$(tool_tree)" "$(git -C "$c" ls-tree -r HEAD | LC_ALL=C sort)"
fresh_wp "$sample"; rm -rf "$c/.git"; git init -q -b main "$c"; git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
printf '#!/bin/sh\necho "a hook said no" >&2\nexit 1\n' > "$c/.git/hooks/pre-commit"; chmod +x "$c/.git/hooks/pre-commit"
setup_wp; t="offprint setup-wp, the site folder a repository with no commit yet, the commit fails"
check "$t: works, says why" "0|yes" "$code|$(printf '%s\n' "$out" | grep -qF "Couldn't commit the plugin copy (git said: a hook said no)" && echo yes)"
check "$t: no commit, and nothing left in the index" "no|" "$(git -C "$c" rev-parse -q --verify HEAD > /dev/null && echo yes || echo no)|$(git -C "$c" ls-files)"
# git's variables pointing at another repository (as inside a git hook): the commit is still the site folder's own.
fresh_wp "$sample"; git init -q -b main "$tmp/case$n/other"; echo x > "$tmp/case$n/other/x.txt"
GIT_DIR="$tmp/case$n/other/.git" GIT_WORK_TREE="$tmp/case$n/other" GIT_INDEX_FILE="$tmp/case$n/other/.git/index" setup_wp
t="offprint setup-wp, with GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE naming another repository"
check "$t: works, the plugin committed in the site folder's repository" "0|$((commits0 + 1))|Offprint's plugin" "$code|$(git -C "$c" rev-list --count HEAD)|$(git -C "$c" log -1 --format=%B | sed '/^$/d')"
check "$t: the tool's plugin" "$(tool_tree)" "$(head_tree)"
check "$t: nothing in the other repository: no commit, nothing staged" "no||?? x.txt" "$(git -C "$tmp/case$n/other" rev-parse -q --verify HEAD > /dev/null && echo yes || echo no)|$(git -C "$tmp/case$n/other" ls-files)|$(git -C "$tmp/case$n/other" status --porcelain)"
# HEAD has another plugin there (an older Offprint's): it is left as it is, and what would replace it is said.
replace_cmd="rm -rf wp-content/mu-plugins/offprint.php wp-content/mu-plugins/offprint && git commit -m \"The old plugin copy out\" -- wp-content/mu-plugins/offprint.php wp-content/mu-plugins/offprint"
fresh_wp "$sample"; mkdir -p "$c/wp-content/mu-plugins"; cp -R "$SRC/plugin/offprint.php" "$SRC/plugin/offprint" "$c/wp-content/mu-plugins/"
echo "// an older Offprint's" >> "$c/wp-content/mu-plugins/offprint.php"; git -C "$c" add wp-content/mu-plugins; git -C "$c" commit -q -m "the plugin"
old_tree="$(head_tree)"; setup_wp; t="offprint setup-wp, HEAD holding another plugin (an older Offprint's, say)"
check "$t: works, no new commit" "0|$((commits0 + 1))" "$code|$(git -C "$c" rev-list --count HEAD)"
check "$t: what HEAD has there, as it was" "$old_tree" "$(head_tree)"
check "$t: nothing staged or changed" "" "$(git -C "$c" status --porcelain)"
contains "$t: says so, and the command that would replace it with this Offprint's" "The plugin copy in the repository isn't this Offprint's (an older Offprint's, say), so it was left as it is. To replace it with this Offprint's: $replace_cmd && offprint setup-wp" "$out"
(cd "$c" && eval "$replace_cmd") > /dev/null 2>&1; setup_wp; t="$t, then the command it gave"
check "$t: two new commits, the second Offprint's plugin" "$((commits0 + 3))|Offprint's plugin" "$(git -C "$c" rev-list --count HEAD)|$(git -C "$c" log -1 --format=%B | sed '/^$/d')"
check "$t: the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
check "$t: the copy on disk is it" "" "$(git -C "$c" status --porcelain)"
# What is committed is built from the tool's own plugin, never from the copy on disk, which WordPress can write: here it
# writes in it as it installs, before the commit.
fresh_wp "$sample"
printf 'echo planted > "%s/wp-content/mu-plugins/offprint/planted.php"; echo "// changed" >> "%s/wp-content/mu-plugins/offprint.php"\n' "$c" "$c" > "$S/on_install"
setup_wp; t="offprint setup-wp, WordPress plants a file in the plugin copy and changes offprint.php as it installs"
check "$t: works" 0 "$code"; check "$t: (it did, before the commit)" "yes|yes" "$([ -f "$c/wp-content/mu-plugins/offprint/planted.php" ] && echo yes)|$(grep -q '^// changed$' "$c/wp-content/mu-plugins/offprint.php" && echo yes)"
check "$t: one new commit, Offprint's plugin" "$((commits0 + 1))|Offprint's plugin" "$(git -C "$c" rev-list --count HEAD)|$(git -C "$c" log -1 --format=%B | sed '/^$/d')"
check "$t: the commit holds the tool's plugin, byte for byte, and nothing else" "$(tool_tree)" "$(head_tree)"
check "$t: and changes nothing else" "$(tool_tree | cut -f2 | LC_ALL=C sort)" "$(git -C "$c" diff --name-only HEAD~1 HEAD | LC_ALL=C sort)"
check "$t: the planted file isn't in it" "" "$(git -C "$c" ls-tree -r --name-only HEAD | grep planted)"
contains "$t: says the copy on disk differs, naming the paths" "$differs_msg (wp-content/mu-plugins/offprint.php, wp-content/mu-plugins/offprint/planted.php), so a publish will refuse until the copy matches." "$out"
check "$t: the copy on disk left as it is" "yes|yes" "$([ -f "$c/wp-content/mu-plugins/offprint/planted.php" ] && echo yes)|$(grep -q '^// changed$' "$c/wp-content/mu-plugins/offprint.php" && echo yes)"
pub --no-push; t="$t, then a publish"
check "$t: refused, the plugin copy differing" "failed|The publish plugin has uncommitted changes (first: wp-content/mu-plugins/offprint.php); commit them first." "$(js state)|$(js message)"
# A .gitattributes WordPress plants, naming a clean filter the owner's git config defines: git never runs it (where this
# git has --attr-source), and the blobs are the tool's bytes.
if git --attr-source="$(git hash-object -t tree /dev/null)" version > /dev/null 2>&1; then
  fresh_wp "$sample"; git -C "$c" config filter.offprinttest.clean "touch '$S/filter.ran'; tr a-z A-Z"
  printf 'printf "* filter=offprinttest\\n" > "%s/wp-content/.gitattributes"\n' "$c" > "$S/on_install"
  setup_wp; t="offprint setup-wp, WordPress plants a .gitattributes naming the owner's clean filter as it installs"
  check "$t: works" 0 "$code"
  check "$t: the filter never ran" no "$([ -e "$S/filter.ran" ] && echo yes || echo no)"
  check "$t: (it was planted)" "* filter=offprinttest" "$(cat "$c/wp-content/.gitattributes" 2>&1)"
  check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
  check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
else
  echo "skip  offprint setup-wp, a .gitattributes WordPress plants (this git has no --attr-source)"
fi
# A git repository WordPress plants in the plugin folder: never committed as a link to it (mode 160000).
fresh_wp "$sample"
printf 'git init -q -b main "%s/wp-content/mu-plugins/offprint" && git -C "%s/wp-content/mu-plugins/offprint" -c user.name=x -c user.email=x@example.com commit -q --allow-empty -m planted\n' "$c" "$c" > "$S/on_install"
setup_wp; t="offprint setup-wp, WordPress plants a git repository in the plugin folder as it installs"
check "$t: works" 0 "$code"; check "$t: (it did)" yes "$([ -d "$c/wp-content/mu-plugins/offprint/.git" ] && echo yes)"
check "$t: no link to a repository in the commit" "" "$(git -C "$c" ls-tree -r HEAD | grep '^160000')"
check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
# The tool's own plugin folder holding anything but files and folders (a link, here): nothing is committed from it.
fresh_wp "$sample"; T="$tmp/case$n/tool"; mkdir -p "$T"; cp -R "$SRC/bin" "$SRC/lib" "$SRC/templates" "$SRC/plugin" "$T/"
ln -s ../offprint.php "$T/plugin/offprint/link.php"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" WP_ADMIN_USER=admin WP_ADMIN_EMAIL=admin@example.com \
  WP_ADMIN_PASSWORD=secret /bin/bash "$T/bin/setup-wp" < /dev/null 2>&1)"; code=$?
t="offprint setup-wp, the tool's plugin folder holding a link"
check "$t: works, nothing committed" "0|$commits0" "$code|$(git -C "$c" rev-list --count HEAD)"
check "$t: nothing staged" "" "$(git -C "$c" diff --cached --name-only)"
contains "$t: says why, naming it, and what to do" "The plugin copy wasn't committed: this Offprint's plugin folder holds something that is neither a file nor a folder ($(cd "$T" && pwd -P)/plugin/offprint/link.php). Once that is put right, $again." "$out"

# --- the plugin a publish commits is this Offprint's own, exactly ---
# WordPress runs the plugin from its copy in wp-content/mu-plugins/, which it can write, and a publish commits
# wp-content/: a change it makes to that copy while it exports (after the refusal of uncommitted changes, which comes
# before the export) must never be committed. on_export: what WordPress does in the site folder while it exports.
plugin_paths="wp-content/mu-plugins/offprint.php wp-content/mu-plugins/offprint"
plugin_file="$(cd "$SRC/plugin" && find offprint -type f -name '*.php' | LC_ALL=C sort | head -n 1)"   # one of its files
changed_msg() {  # changed_msg FIRST [EXTRA]: the refusal when HEAD has this Offprint's plugin and the copy differs
  printf '%s' "The plugin copy in wp-content/mu-plugins differs from this Offprint's, the one committed (first: $1): WordPress, or someone, changed it. Nothing was committed. To put back the committed copy: git checkout -- $plugin_paths${2:+; and look at, then remove, what this Offprint's plugin doesn't have: $2}."
}
pcase() { newcase "$@"; head0="$(git -C "$c" rev-parse HEAD)"; }
# late_refused T: refused once the commit's tree is built, as the other refusals there are: failed, nothing committed
# (HEAD where it was), nothing staged in git's own index, and the publish's private index gone.
late_refused() {
  check "$1: refused, exit 1" "1|failed" "$code|$(js state)"; valid "$1"; nocommit "$1"
  check "$1: HEAD where it was" "$head0" "$(git -C "$c" rev-parse HEAD)"
  check "$1: nothing staged" "" "$(git -C "$c" diff --cached --name-only)"; no_private_index "$1"
}
pcase; printf 'echo "// changed" >> "%s/wp-content/mu-plugins/offprint.php"\n' "$c" > "$S/on_export"
pub; t="WordPress changes offprint.php in the plugin copy while it exports"
check "control: $t: it did" "// changed" "$(tail -n 1 "$c/wp-content/mu-plugins/offprint.php")"
late_refused "$t"; check "$t: nothing pushed" "$commits0" "$(git -C "$O" rev-list --count main)"
check "$t: says so, naming it, and the git checkout that puts back the committed copy" "$(changed_msg wp-content/mu-plugins/offprint.php)" "$(js message)"
pub; t="$t, then a publish"
check "$t: refused before the export (the copy differs from its commit)" "failed|The publish plugin has uncommitted changes (first: wp-content/mu-plugins/offprint.php); commit them first." "$(js state)|$(js message)"
rm "$S/on_export"; (cd "$c" && git checkout -- $plugin_paths); pub; t="the same, after the git checkout the refusal gave"
check "$t: live" "0|live" "$code|$(js state)"; check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
pcase; printf 'echo planted > "%s/wp-content/mu-plugins/offprint/planted.php"\n' "$c" > "$S/on_export"
pub --no-push; t="WordPress adds a file to the plugin copy while it exports"; late_refused "$t"
check "$t: says so, naming the file for the owner to look at and remove" \
  "$(changed_msg wp-content/mu-plugins/offprint/planted.php wp-content/mu-plugins/offprint/planted.php)" "$(js message)"
check "$t: the file is left as it is" planted "$(cat "$c/wp-content/mu-plugins/offprint/planted.php")"
rm "$S/on_export" "$c/wp-content/mu-plugins/offprint/planted.php"; pub --no-push; t="the same, once the owner has removed it"
check "$t: committed" "0|Committed, not pushed (--no-push).|$((commits0 + 1))" "$code|$(js message)|$(git -C "$c" rev-list --count HEAD)"
check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
pcase; printf 'rm -f "%s/wp-content/mu-plugins/%s"; ln -s ../offprint.php "%s/wp-content/mu-plugins/%s"\n' "$c" "$plugin_file" "$c" "$plugin_file" > "$S/on_export"
pub --no-push; t="WordPress replaces a file of the plugin copy with a link while it exports"
check "control: $t: it did" yes "$([ -L "$c/wp-content/mu-plugins/$plugin_file" ] && echo yes)"
late_refused "$t"; check "$t: says so, naming it" "$(changed_msg "wp-content/mu-plugins/$plugin_file")" "$(js message)"
pcase; printf 'chmod +x "%s/wp-content/mu-plugins/%s"\n' "$c" "$plugin_file" > "$S/on_export"
pub --no-push; t="WordPress makes a file of the plugin copy executable while it exports"
late_refused "$t"; check "$t: says so, naming it" "$(changed_msg "wp-content/mu-plugins/$plugin_file")" "$(js message)"
# Control: what WordPress may do to the copy that changes nothing git commits (each file's time, a group's write bit, a
# Finder .DS_Store, which a site's .gitignore leaves out), while it writes elsewhere in wp-content/.
pcase
printf 'find "%s/wp-content/mu-plugins" -type f -exec touch -t 202001010000 {} +; chmod g+w "%s/wp-content/mu-plugins/%s"; echo junk > "%s/wp-content/mu-plugins/offprint/.DS_Store"; echo new > "%s/wp-content/new.txt"\n' \
  "$c" "$c" "$plugin_file" "$c" "$c" > "$S/on_export"
pub --no-push; t="control: WordPress touches the plugin copy's files and adds a .DS_Store while it exports, and writes elsewhere"
check "$t: committed" "0|Committed, not pushed (--no-push).|$((commits0 + 1))" "$code|$(js message)|$(git -C "$c" rev-list --count HEAD)"
check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
check "$t: and what WordPress wrote elsewhere" new "$(git -C "$c" show HEAD:wp-content/new.txt 2>&1)"
# HEAD holding another plugin (an older Offprint's), the work tree clean: setup-wp's command replaces it.
pcase; echo "// an older Offprint's" >> "$c/wp-content/mu-plugins/offprint.php"; git -C "$c" commit -q -am "an older plugin"
git -C "$c" push -q origin main; commits0="$(git -C "$c" rev-list --count HEAD)"; head0="$(git -C "$c" rev-parse HEAD)"
pub; t="HEAD holding another plugin (an older Offprint's, say), the work tree clean"; late_refused "$t"
check "$t: says so, with the command that replaces it, as setup-wp says it" \
  "The plugin copy in the repository isn't this Offprint's (an older Offprint's, say; first: wp-content/mu-plugins/offprint.php). Nothing was committed. To replace it with this Offprint's: $replace_cmd && offprint setup-wp" "$(js message)"
(cd "$c" && eval "$replace_cmd") > /dev/null 2>&1; setup_wp; t="$t, then the command it gave"
contains "$t: setup-wp commits this Offprint's plugin" "$committed_msg" "$out"
pub; check "$t: and a publish goes live" "0|live" "$code|$(js state)"
check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
# A site with no plugin at all: offprint setup-wp puts this Offprint's in place, and commits it.
bare_newcase; head0="$(git -C "$c" rev-parse HEAD)"; pub; t="a site with no plugin"; late_refused "$t"
check "$t: says so, and to run offprint setup-wp" "This site has no Offprint plugin to commit (first missing: wp-content/mu-plugins/offprint.php). Nothing was committed. Run offprint setup-wp, then publish again." "$(js message)"
setup_wp; pub; t="$t, then offprint setup-wp"
check "$t: live" "0|live" "$code|$(js state)"; check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
# No plugin committed, and WordPress writes a copy that isn't this Offprint's while it exports.
bare_newcase; head0="$(git -C "$c" rev-parse HEAD)"
printf 'mkdir -p "%s/wp-content/mu-plugins" && cp -R "%s/plugin/offprint.php" "%s/plugin/offprint" "%s/wp-content/mu-plugins/" && echo "// changed" >> "%s/wp-content/mu-plugins/offprint.php"\n' \
  "$c" "$SRC" "$SRC" "$c" "$c" > "$S/on_export"
pub --no-push; t="no plugin committed, and WordPress writes a copy that isn't this Offprint's while it exports"; late_refused "$t"
check "$t: says so: offprint setup-wp, then the git checkout that puts this Offprint's copy in place" \
  "This site has no Offprint plugin committed, and the copy in wp-content/mu-plugins isn't this Offprint's (first: wp-content/mu-plugins/offprint.php). Nothing was committed. Run offprint setup-wp, which commits this Offprint's, then put its copy in place: git checkout -- $plugin_paths." "$(js message)"
rm "$S/on_export"; setup_wp; (cd "$c" && git checkout -- $plugin_paths); pub --no-push; t="$t, then both"
check "$t: committed" "0|Committed, not pushed (--no-push)." "$code|$(js message)"; check "$t: the commit holds the tool's plugin, byte for byte" "$(tool_tree)" "$(head_tree)"
# This Offprint's own plugin folder not as it should be: refused before anything is exported.
pcase; toolcopy; ln -s ../offprint.php "$T/plugin/offprint/link.php"
for args in --no-push --dry-run; do
  rm -f "$S/docker.calls"; pub $args; t="publish $args, this Offprint's own plugin folder holding a link"
  check "$t: refused before the export" "1|failed|0" "$code|$(js state)|$(grep -c 'wp offprint export' "$S/docker.calls")"
  check "$t: says why" "This Offprint's own plugin folder is missing a part, or holds something that is neither a file nor a folder ($(cd "$T" && pwd -P)/plugin/offprint/link.php), so the site's copy can't be checked against it; nothing was published." "$(js message)"
  nocommit "$t"; oldsite "$t"
done
# A dry run builds no tree: the copy on disk is compared, never read through a link (nor anything but a plain file).
dry_ok="Dry run: a copy of the export passed the checks; the export is in var/export, and nothing else changed."
dry_refused() {  # dry_refused T: the dry run refused, having changed nothing
  check "$1: refused, exit 1" "1|failed" "$code|$(js state)"; valid "$1"; nocommit "$1"; oldsite "$1"; oldbackup "$1"
  check "$1: the checked copy is removed" no "$([ -e "$c/site.new" ] && echo yes || echo no)"
}
pcase; echo "// changed by hand" >> "$c/wp-content/mu-plugins/offprint.php"; pub --dry-run; t="--dry-run, the plugin copy on disk changed"
dry_refused "$t"; check "$t: says so, as a publish would" "$(changed_msg wp-content/mu-plugins/offprint.php)" "$(js message)"
check "$t: the change is left as it is" "// changed by hand" "$(tail -n 1 "$c/wp-content/mu-plugins/offprint.php")"
pcase; chmod +x "$c/wp-content/mu-plugins/$plugin_file"; pub --dry-run; t="--dry-run, a file of the plugin copy on disk executable"
dry_refused "$t"; check "$t: says so" "$(changed_msg "wp-content/mu-plugins/$plugin_file")" "$(js message)"
pcase; cp "$c/wp-content/mu-plugins/offprint.php" "$tmp/case$n/same.php"; rm "$c/wp-content/mu-plugins/offprint.php"
ln -s "$tmp/case$n/same.php" "$c/wp-content/mu-plugins/offprint.php"; pub --dry-run; t="--dry-run, offprint.php a link to a file with its very bytes"
dry_refused "$t"; check "$t: refused all the same (it isn't read through the link)" "$(changed_msg wp-content/mu-plugins/offprint.php)" "$(js message)"
pcase; mkdir "$tmp/case$n/elsewhere"; mv "$c/wp-content/mu-plugins" "$tmp/case$n/elsewhere/"; ln -s "$tmp/case$n/elsewhere/mu-plugins" "$c/wp-content/mu-plugins"
pub --dry-run; t="--dry-run, wp-content/mu-plugins a link to a folder holding exactly this Offprint's plugin"
dry_refused "$t"; check "$t: refused (nothing is read through it), naming it" "$(changed_msg wp-content/mu-plugins wp-content/mu-plugins)" "$(js message)"
pcase; mkfifo "$c/wp-content/mu-plugins/offprint/pipe"; pub_within 20 --dry-run; t="--dry-run, a FIFO in the plugin copy"
dry_refused "$t"; check "$t: refused without waiting on it, naming it" "$(changed_msg wp-content/mu-plugins/offprint/pipe wp-content/mu-plugins/offprint/pipe)" "$(js message)"
pcase; mkdir "$c/wp-content/mu-plugins/offprint/extra"; pub --dry-run; t="--dry-run, a folder in the plugin copy that this Offprint's plugin lacks"
dry_refused "$t"; check "$t: says so, naming it" "$(changed_msg wp-content/mu-plugins/offprint/extra wp-content/mu-plugins/offprint/extra)" "$(js message)"
pcase; find "$c/wp-content/mu-plugins" -type f -exec touch -t 202001010000 {} +; chmod g+w "$c/wp-content/mu-plugins/$plugin_file"
echo junk > "$c/wp-content/mu-plugins/offprint/.DS_Store"; pub --dry-run; t="control: --dry-run, the plugin copy's files touched, a group's write bit, a .DS_Store"
check "$t: passes" "0|$dry_ok" "$code|$(js message)"
# (git hashes the copy outside any repository too: a dry run needs none. With the tool's own adapter, none.)
pcase; cp "$SRC/tests/fixtures/site.json" "$c/site.json"; rm -rf "$c/.git"; pub --dry-run; t="control: --dry-run in a site folder that is no git repository"
check "$t: passes" "0|$dry_ok" "$code|$(js message)"
echo "// changed by hand" >> "$c/wp-content/mu-plugins/offprint.php"; pub --dry-run; t="--dry-run in a site folder that is no git repository, the plugin copy changed"
check "$t: refused" "1|failed" "$code|$(js state)"
touch "$tmp/CaseProbe"
if [ -e "$tmp/caseprobe" ]; then
  newcase CaseSite; echo "$c" > "$S/containers"; OP_SITE="$tmp/case$n/casesite" op compose ps; t="the project made from this folder, named in another case (CaseSite as casesite)"
  check "$t: compose ps works" 0 "$code"
  fresh_calls; out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$tmp/case$n/casesite" /bin/bash "$T/bin/publish" --no-push 2>&1)"; code=$?
  check "$t: a publish works" 0 "$code"; check "$t: one new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
else
  echo "skip  the project made from this folder, named in another case (this disk minds case)"
fi
# Volumes. Every volume of the project (by its compose label), and the two compose would mount by name (example_db,
# example_wordpress), whatever made them, must carry offprint=1 and this project's compose label. Other volumes are
# none of its business (here: another project's, a name that only starts the same, one with no labels at all).
vol_msg() { printf 'Docker volumes for a compose project called example already exist and were not made by Offprint (first: %s). Change "name" in site.json.' "$1"; }
other_vols='blog_db "blog" "" "db"
blog_wordpress "blog" "" "wordpress"
examples_db "examples" "1" "db"
loose "" "" ""'
# Another tool's volume in a project of the site's name (kept after its containers were removed).
newcase; printf '%s\nexample_data "example" "" "data"\n' "$other_vols" > "$S/volumes"; before="$(files)"; op compose up -d
t="another tool's volume in a project of the site's name, and no containers"
check "$t: refused, exit 2" 2 "$code"; contains "$t: says so" "$(vol_msg example_data)" "$out"; no_compose "$t"; check "$t: nothing written" "$before" "$(files)"
fresh_calls; op setup-wp; check "offprint setup-wp, with that volume: refused" 2 "$code"; no_compose "offprint setup-wp, with that volume"
fresh_calls; pub --no-push; t="offprint publish, with that volume"
check "$t: refused" 2 "$code"; no_compose "$t"; check "$t: says so in the status" "$(vol_msg example_data)" "$(js message)"; nocommit "$t"
# A volume with exactly the name compose would mount, that compose didn't make (docker volume create, docker run -v),
# with no labels at all: it has no compose label, so only the look-up by name finds it.
newcase; printf '%s\nexample_db "" "" ""\n' "$other_vols" > "$S/volumes"; before="$(files)"
for args in "compose up -d" "setup-wp" "wp option get siteurl"; do
  fresh_calls; op $args; t="offprint $args, with a volume called example_db that has no labels"
  check "$t: refused, exit 2" 2 "$code"; contains "$t: names it" "$(vol_msg example_db)" "$out"; no_compose "$t"
  check "$t: nothing written" "$before" "$(files)"
done
fresh_calls; pub --no-push; t="offprint publish, with a volume called example_db that has no labels"
check "$t: refused, exit 2" 2 "$code"; no_compose "$t"; check "$t: says so in the status" "$(vol_msg example_db)" "$(js message)"; nocommit "$t"
newcase; printf '%s\nexample_db "other" "1" "db"\n' "$other_vols" > "$S/volumes"; op compose up -d; t="a volume called example_db labelled offprint=1, but another project's"
check "$t: refused" 2 "$code"; contains "$t: names it" "$(vol_msg example_db)" "$out"; no_compose "$t"
newcase; printf 'example_wordpress "example" "1" "wordpress"\nexample_db "example" "yes" "db"\n' > "$S/volumes"; op compose up -d
t="one volume labelled offprint=1, and one with another value"
check "$t: refused" 2 "$code"; contains "$t: names the one" "$(vol_msg example_db)" "$out"; no_compose "$t"
newcase; printf '%s\n%s\n' "$other_vols" "$ours_vols" > "$S/volumes"; op compose up -d; t="the project's two volumes, with both labels, and no containers"
check "$t: goes on" 0 "$code"; check "$t: compose up -d ran" "up -d" "$(sed 's/.*compose\.yaml //' "$S/docker.calls")"
newcase; printf '%s\n' "$other_vols" > "$S/volumes"; op compose up -d; t="neither volume yet (only other projects' and unlabelled ones)"
check "$t: goes on" 0 "$code"; check "$t: compose up -d ran" "up -d" "$(sed 's/.*compose\.yaml //' "$S/docker.calls")"
# The volume listing fails (and the containers' doesn't): Docker couldn't be asked, so only a bare ps is let through.
newcase; touch "$S/volume_ls_fails"; op compose up -d; t="docker volume ls fails"
check "$t: compose up -d exits 1" 1 "$code"; no_compose "$t"
check "$t: saying Docker couldn't be asked" "Docker isn't running (docker said: Error response from daemon: a volume listing that failed), so it couldn't be checked that the compose project example is this site's; nothing was run. Start Docker, then try again." "$out"
fresh_calls; op compose ps; check "$t: compose ps is let through" "0|ps" "$code|$(sed 's/.*compose\.yaml //' "$S/docker.calls")"
# Volumes shaped like Offprint's own but without the offprint label (this project's compose labels, volume keys db and
# wordpress): refused like any other, whether or not there are containers, and whatever else is listed with them.
old_vols='example_db "example" "" "db"
example_wordpress "example" "" "wordpress"'
newcase; echo "$c" > "$S/containers"; printf '%s\n%s\n' "$other_vols" "$old_vols" > "$S/volumes"; before="$(files)"; op compose up -d
t="volumes with this project's compose labels but no offprint label, its containers from this folder"
check "$t: refused, exit 2" 2 "$code"; check "$t: with the one refusal" "$(vol_msg example_db)" "$out"; no_compose "$t"
check "$t: nothing written" "$before" "$(files)"
fresh_calls; pub --no-push; t="offprint publish, with those volumes"
check "$t: refused, exit 2" 2 "$code"; no_compose "$t"; check "$t: the status says the same" "$(vol_msg example_db)" "$(js message)"; nocommit "$t"
newcase; printf '%s\n' "$old_vols" > "$S/volumes"; op setup-wp; t="the same volumes, and no containers: offprint setup-wp"
check "$t: refused with the one refusal" "2|$(vol_msg example_db)" "$code|$out"; no_compose "$t"
newcase; printf '%s\nexample_data "example" "" "data"\n' "$old_vols" > "$S/volumes"; op compose up -d; t="those volumes, and another tool's in the same project"
check "$t: refused, naming the first in Docker's listing" "2|$(vol_msg example_db)" "$code|$out"; no_compose "$t"
newcase; printf 'example_db "example" "" "wordpress"\n' > "$S/volumes"; op compose up -d; t="a volume called example_db whose compose volume label is another"
check "$t: refused" "2|$(vol_msg example_db)" "$code|$out"
newcase; echo "$tmp/case$n/elsewhere" > "$S/containers"; printf '%s\n' "$old_vols" > "$S/volumes"; op compose up -d; t="such volumes, with containers from another folder"
check "$t: refused for the containers" "2|$(other_msg "$tmp/case$n/elsewhere")" "$code|$out"
# A script that sources lib/site.sh with IFS set to a line end: the look-up by
# name still splits the list of volume keys.
newcase; printf '%s\nexample_db "" "" ""\n' "$other_vols" > "$S/volumes"
cat > "$S/ifs-caller.sh" <<'CALLER'
IFS=$'\n'
. "$1/lib/site.sh"
offprint_find_site
offprint_load_site
offprint_own_project; rc=$?
printf 'rc=%s|%s' "$rc" "$OFFPRINT_PROJECT_PROBLEM"
CALLER
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" /bin/bash "$S/ifs-caller.sh" "$SRC" 2>&1)"
check "a caller with IFS set to a line end: a volume called example_db with no labels is still refused" "rc=1|$(vol_msg example_db)" "$out"
# Docker not running: compose ps is let through (it fails too, with Docker's own words); nothing else runs.
newcase; touch "$S/docker_down"; before="$(files)"
op compose ps; t="offprint compose ps, Docker not running"
check "$t: Docker's own exit code and words" "1|Cannot connect to the Docker daemon at unix:///var/run/docker.sock" "$code|$out"
for args in "compose up -d" "wp option get siteurl" "setup-wp"; do
  fresh_calls; op $args; t="offprint $args, Docker not running"
  check "$t: exit 1" 1 "$code"
  check "$t: says Docker isn't running" "Docker isn't running (docker said: Cannot connect to the Docker daemon at unix:///var/run/docker.sock), so it couldn't be checked that the compose project example is this site's; nothing was run. Start Docker, then try again." "$out"
  no_compose "$t"; check "$t: nothing written" "$before" "$(files)"
done
check "offprint setup-wp, Docker not running: mkcert never ran" no "$([ -e "$S/mkcert.calls" ] && echo yes || echo no)"
# templates/compose.yaml labels every named volume, as the check looks for.
vols="$(awk '/^volumes:/ { on = 1; next } on && /^[^ #]/ { on = 0 } on && /^  [A-Za-z0-9_.-]+:/ { v = $1; sub(/:.*/, "", v); print v }' "$SRC/templates/compose.yaml" | paste -sd' ' -)"
check "templates/compose.yaml declares the volumes db and wordpress" "db wordpress" "$vols"
check "templates/compose.yaml labels every one of them offprint: \"1\"" "" "$(awk '
  /^volumes:/ { on = 1; next }
  on && /^[^ #]/ { on = 0 }
  !on { next }
  /^  [A-Za-z0-9_.-]+:/ { if (v != "" && !ok) print v; v = $1; sub(/:.*/, "", v); ok = 0; lab = 0; next }
  /^    labels:[[:space:]]*$/ { lab = 1; next }
  /^    [^ ]/ { lab = 0 }
  lab && /^      offprint: "1"[[:space:]]*$/ { ok = 1 }
  END { if (v != "" && !ok) print v }' "$SRC/templates/compose.yaml")"
check "every named volume a service mounts is declared at the top level" "db wordpress" \
  "$(grep -oE '^      - [a-z]+:/' "$SRC/templates/compose.yaml" | sed -e 's/^      - //' -e 's/:\/$//' | LC_ALL=C sort -u | paste -sd' ' -)"
# The check looks each of the template's named volumes up by name: its list (lib/site.sh) is exactly the template's.
check "lib/site.sh's OFFPRINT_VOLUMES is every named volume in templates/compose.yaml, and only those" "$vols" \
  "$(/bin/bash -c '. "$1/lib/site.sh"; printf "%s" "$OFFPRINT_VOLUMES"' _ "$SRC")"

# --- the PATH clean-up (lib/site.sh): look-alikes WordPress could put in wp-content/ never run ---
# With . or an empty entry first on the PATH, a relative entry, or an absolute one (or a link) that is wp-content/, a
# command run from there would run what WordPress put there: bash (the #! line's env bash), dirname, php, git, docker...
# Each entry point, run both as /bin/bash SCRIPT and by its own #! line, from inside wp-content/, with look-alikes of
# each there (noting in $tmp/planted.ran that they ran): none runs, the entries left out are named in one line (once for
# the command typed, however many of the tool's scripts it runs), and the command does what it does with a clean PATH.
plant() {  # plant DIR: the look-alikes in DIR
  local p; mkdir -p "$1"
  for p in bash dirname php mktemp git docker curl readlink env; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$1/$p"; chmod +x "$1/$p"
  done
}
# variant KIND BASE: vpath, the PATH (KIND's way to wp-content/, then BASE), and vleft, what the one line must name
variant() {
  case "$1" in
    dot) vpath=".:$2"; vleft="'.'" ;;
    empty) vpath=":$2"; vleft="''" ;;
    relative) vpath="wp-content:../wp-content:$2"; vleft="'wp-content' '../wp-content'" ;;
    absolute) vpath="$c/wp-content:$2"; vleft="'$c/wp-content'" ;;
    link) rm -f "$tmp/case$n/wplink"; ln -s "$c/wp-content" "$tmp/case$n/wplink"; vpath="$tmp/case$n/wplink:$2"; vleft="'$tmp/case$n/wplink'" ;;
  esac
}
# planted_ok T: after a run (out): no look-alike ran, and one line (one only) names what was left out of the PATH
planted_ok() {
  check "$1: no look-alike in wp-content/ ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
  check "$1: one line says what was left out of the PATH" 1 "$(printf '%s\n' "$out" | grep -c 'PATH entries left out')"
  contains "$1: naming it" "$vleft" "$(printf '%s\n' "$out" | grep 'PATH entries left out')"
  rm -f "$tmp/planted.ran"
}
# in_wp HOW SCRIPT ARGS...: SCRIPT ARGS from wp-content/ (no OFFPRINT_SITE: the site is found from there), PATH vpath,
# run by /bin/bash (HOW bash) or by its own #! line (HOW direct); sets out, code
in_wp() {
  local how="$1"; shift
  if [ "$how" = bash ]; then set -- /bin/bash "$@"; fi
  out="$(cd "$c/wp-content" && env -u OFFPRINT_SITE PATH="$vpath" STUB_DIR="$S" PUBLISH_POLL_SECONDS=1 PUBLISH_TIMEOUT_SECONDS=2 \
    PUBLISH_CHECK_URL=https://example.test/build.json "$@" < /dev/null 2>&1)"; code=$?
}
base="$PATH"
dry_msg="Dry run: a copy of the export passed the checks; the export is in var/export, and nothing else changed."
newcase; plant "$c/wp-content"
mkdir -p "$tmp/case$n/links"; ln -s "$SRC/bin/offprint" "$tmp/case$n/links/offprint"
for kind in dot empty relative absolute link; do
  for how in bash direct; do
    variant "$kind" "$S/bin:$base"
    in_wp "$how" "$SRC/bin/publish" --dry-run; t="bin/publish --dry-run ($how), look-alikes in wp-content/, run there, PATH $kind"
    planted_ok "$t"; check "$t: the dry run passed, no warnings" "0|$dry_msg|[]" "$code|$(js message)|$(js warnings)"
    in_wp "$how" "$tmp/case$n/links/offprint" publish --dry-run; t="offprint publish --dry-run ($how, through a link), the same"
    planted_ok "$t"; check "$t: the dry run passed, no warnings" "0|$dry_msg|[]" "$code|$(js message)|$(js warnings)"
    in_wp "$how" "$SRC/bin/wp" option get siteurl; t="bin/wp option get siteurl ($how), the same"
    planted_ok "$t"; check "$t: WP-CLI's answer" "0|https://mysite.test" "$code|$(printf '%s\n' "$out" | grep -v 'PATH entries left out')"
    in_wp "$how" "$SRC/bin/setup-wp"; t="bin/setup-wp ($how), the same"
    planted_ok "$t"; check "$t: done" "0|Done: https://mysite.test/  (admin: https://mysite.test/wp-admin/)" "$code|$(printf '%s\n' "$out" | tail -n 1)"
  done
done
check "the PATH clean-up: docker (the stand-in) did each command's work" yes "$(grep -q 'wp option update blog_public 1' "$S/docker.calls" && grep -q 'wp offprint export' "$S/docker.calls" && echo yes)"
# An entry that can't be entered when the command starts runs nothing then, and once it is left out nothing made or
# opened there later can be reached through it: so it is left out, silently (stale entries are common). Each first on
# the PATH of bin/wp, run from the site folder: a folder that isn't there, a link to nothing, a mode-000 folder outside
# the site, and a link outside the site to a mode-000 folder in wp-content/ (its text is outside the site, so it too is
# left out without a word: where a link leads can't be asked of one that can't be followed). The stand-in docker is
# found through a link outside the site to a folder outside it (as /bin is a link on some systems): kept (as the folder
# it leads to, on disk), and found. It notes the PATH it was given.
newcase; real="$tmp/case$n/realbin"; mkdir -p "$real" "$c/wp-content/locked" "$tmp/case$n/closed"; ln -s "$real" "$tmp/case$n/linkbin"
realp="$(cd -P "$real" && pwd -P)"
printf '#!/bin/sh\nprintf "%%s\\n" "$PATH" > "%s/seen.path"\nexec "%s/bin/docker" "$@"\n' "$S" "$S" > "$real/docker"; chmod +x "$real/docker"
ln -s "$tmp/case$n/not-there" "$tmp/case$n/dangling"; ln -s "$c/wp-content/locked" "$tmp/case$n/to-locked"
chmod 000 "$tmp/case$n/closed" "$c/wp-content/locked"
for spec in "$tmp/case$n/missing|a folder that isn't there|quiet" "$tmp/case$n/dangling|a link to nothing|quiet" \
  "$tmp/case$n/closed|a mode-000 folder outside the site|quiet" "$tmp/case$n/to-locked|a link outside the site to a mode-000 folder in wp-content/|"; do
  e="${spec%%|*}"; rest="${spec#*|}"; how="${rest%%|*}"; quiet="${rest#*|}"
  rm -f "$S/seen.path"
  out="$(cd "$c" && env -u OFFPRINT_SITE PATH="$e:$tmp/case$n/linkbin:$S/bin:$base" STUB_DIR="$S" /bin/bash "$SRC/bin/wp" option get siteurl 2> "$S/wp.err" < /dev/null)"; code=$?
  t="bin/wp, the PATH starting with $how"
  check "$t: WP-CLI's answer, through the stand-in docker found by the link outside the site" "0|https://mysite.test|yes" "$code|$out|$([ -s "$S/seen.path" ] && echo yes || echo no)"
  check "$t: that entry isn't on the PATH docker was given" no "$(tr ':' '\n' < "$S/seen.path" 2>/dev/null | grep -qxF -- "$e" && echo yes || echo no)"
  check "$t: the link outside the site is, as the folder it leads to on disk" yes "$(tr ':' '\n' < "$S/seen.path" 2>/dev/null | grep -qxF -- "$realp" && echo yes || echo no)"
  check "$t: (the link's own text isn't)" no "$(tr ':' '\n' < "$S/seen.path" 2>/dev/null | grep -qxF -- "$tmp/case$n/linkbin" && echo yes || echo no)"
  if [ "$quiet" = quiet ]; then check "$t: nothing said about it" "" "$(cat "$S/wp.err")"; fi
done
chmod 755 "$tmp/case$n/closed" "$c/wp-content/locked"
# A kept entry is kept as the folder it is on disk when the command starts, never as its text; and so is TMPDIR. A link
# of the owner's outside the site folder (own/tools) that leads through a link WordPress owns (wp-content/hop) to a
# folder outside (outside/bin) is kept, as that folder, so WordPress pointing its link at a folder of its own later
# changes nothing; the same for TMPDIR (own/tmp, through wp-content/hoptmp, to outside/tmp). In outside/bin: a php that
# points wp-content/hoptmp at wp-content/caught, then runs the real one (lib/site.sh makes a temporary file for docker's
# messages after it); and a docker that notes the PATH and TMPDIR it was given and what is in wp-content/caught (that
# file is there while docker runs), points wp-content/hop at a folder holding a look-alike docker, looks docker up
# again, and does the stand-in's work. bin/wp then runs docker twice more, each looked up again.
newcase; o="$tmp/case$n/outside"; mkdir -p "$o/bin" "$o/tmp" "$tmp/case$n/own" "$c/wp-content/planted" "$c/wp-content/caught"
op="$(cd -P "$o" && pwd -P)"
printf '#!/bin/sh\necho "docker $*" >> "%s/planted.ran"\nexit 0\n' "$S" > "$c/wp-content/planted/docker"; chmod +x "$c/wp-content/planted/docker"
cat > "$o/bin/php" <<STUB
#!/bin/sh
/bin/rm -f '$c/wp-content/hoptmp'; /bin/ln -s '$c/wp-content/caught' '$c/wp-content/hoptmp'
exec '$(command -v php)' "\$@"
STUB
cat > "$o/bin/docker" <<STUB
#!/bin/sh
{ echo "PATH=\$PATH"; echo "TMPDIR=\${TMPDIR-}"; echo "caught=\$(/bin/ls -A '$c/wp-content/caught')"; } >> "$S/hop.seen"
/bin/rm -f '$c/wp-content/hop'; /bin/ln -s '$c/wp-content/planted' '$c/wp-content/hop'
echo "again=\$(command -v docker)" >> "$S/hop.seen"
exec "$S/bin/docker" "\$@"
STUB
chmod +x "$o/bin/php" "$o/bin/docker"
for how in "bin/wp" "offprint wp"; do
  if [ "$how" = bin/wp ]; then set -- /bin/bash "$SRC/bin/wp"; else set -- /bin/bash "$SRC/bin/offprint" wp; fi
  rm -f "$c/wp-content/hop" "$c/wp-content/hoptmp" "$tmp/case$n/own/tools" "$tmp/case$n/own/tmp" "$S/hop.seen" "$S/planted.ran"
  ln -s "$o/bin" "$c/wp-content/hop"; ln -s "$c/wp-content/hop" "$tmp/case$n/own/tools"
  ln -s "$o/tmp" "$c/wp-content/hoptmp"; ln -s "$c/wp-content/hoptmp" "$tmp/case$n/own/tmp"
  out="$(cd "$c" && env -u OFFPRINT_SITE PATH="$tmp/case$n/own/tools:$S/bin:$base" TMPDIR="$tmp/case$n/own/tmp" STUB_DIR="$S" \
    "$@" option get siteurl 2> "$S/wp.err" < /dev/null)"; code=$?
  t="$how, the PATH through a link of the owner's that leads through wp-content/hop to a folder outside, and TMPDIR the same way; WordPress points both links elsewhere meanwhile"
  check "$t: WP-CLI's answer, nothing said" "0|https://mysite.test|" "$code|$out|$(cat "$S/wp.err")"
  check "$t: the look-alike docker never ran" "" "$(cat "$S/planted.ran" 2>/dev/null)"
  check "$t: the docker outside found each time (ps, volume ls, compose), and again by itself after the switch" "3|3" \
    "$(grep -c '^PATH=' "$S/hop.seen")|$(grep -cxF -- "again=$op/bin/docker" "$S/hop.seen")"
  check "$t: the PATH docker was given holds the folder outside, on disk, not the link" "yes|no" \
    "$(sed -n 's/^PATH=//p' "$S/hop.seen" | head -n 1 | tr ':' '\n' | grep -qxF -- "$op/bin" && echo yes || echo no)|$(grep -qF -- "$tmp/case$n/own/tools" "$S/hop.seen" && echo yes || echo no)"
  check "$t: TMPDIR, the folder outside on disk" "TMPDIR=$op/tmp" "$(grep '^TMPDIR=' "$S/hop.seen" | sort -u)"
  check "$t: no temporary file went into the site folder (wp-content/caught empty while docker ran, and after)" "caught=|" \
    "$(grep '^caught=' "$S/hop.seen" | sort -u)|$(ls -A "$c/wp-content/caught")"
done

exit "$fail"
