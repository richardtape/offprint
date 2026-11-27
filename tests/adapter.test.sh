#!/usr/bin/env bash
# Tests the host adapter contract: lib/adapter.sh (which finds a site's adapter, checks it may be used, and sources it),
# adapters/none, adapters/cloudflare-workers, and how bin/publish and bin/check-site use an adapter's files, limits and
# functions. Every case runs the tool's own scripts, in place, for a throwaway site folder (tests/fixtures/site.json
# with an adapter block, its own git repo, a bare repo as origin, stand-in `docker`, `curl` and `gh` first on PATH; for
# cloudflare-workers, stand-in `node` and `security` too), so this never touches this repo's git state, a real site, the
# real Docker, the Keychain, Cloudflare or the network.
# Run: bash tests/adapter.test.sh   (macOS bash 3.2 and Linux)
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE PUBLISH_CHECK_URL PUBLISH_TIMEOUT_SECONDS PUBLISH_POLL_SECONDS OFFPRINT_HOME OFFPRINT_SECURITY \
  OFFPRINT_WRANGLER_TIMEOUT
# Git behaves here as it does on any Mac or CI runner: no user or system config, and every repo names its branch.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR).
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-adapter-test.XXXXXX")"; trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
# Every private folder a load, a call or a publish makes goes in the suite's own
# TMPDIR (and none may be left: see the end).
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
contains() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no '$2' in '$3')"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' is in '$3')"; else ok "$1"; fi; }
exists() { if [ -e "$1" ] || [ -L "$1" ]; then echo yes; else echo no; fi; }

# --- the stand-ins, shared by every case; each case's own state is in its STUB_DIR ---
mkdir -p "$tmp/bin"
# docker: the two questions lib/site.sh asks before any compose call (no such project yet) are noted in docker.queries;
# compose calls in docker.calls, answered by subcommand: WordPress runs, the export copies the case's fixture into
# var/export (with export_reverse, one file at a time, in reverse order), the dump is a small whole one.
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != compose ]; then echo "$*" >> "$STUB_DIR/docker.queries"; exit 0; fi
echo "$*" >> "$STUB_DIR/docker.calls"
shift
while [ $# -ge 2 ]; do case "$1" in -p|--project-directory|-f) shift 2 ;; *) break ;; esac; done
case "$*" in
  "ps "*) echo wordpress; echo db; exit 0 ;;
  "exec "*"wp offprint export"*)
    if [ -f "$STUB_DIR/export_reverse" ]; then
      # file by file, in reverse name order, each folder made as the first file in it is copied
      ( cd "$STUB_DIR/fixture" && find . -type f | LC_ALL=C sort -r ) | while IFS= read -r f; do
        mkdir -p "$PWD/var/export/${f%/*}" && cp "$STUB_DIR/fixture/$f" "$PWD/var/export/$f"
      done
    else cp -R "$STUB_DIR/fixture/." "$PWD/var/export/"; fi
    echo 'Exported.'; exit 0 ;;
  "exec "*mariadb-dump*) printf -- '-- MariaDB dump\nCREATE TABLE t (a int);\n\n-- Dump completed\n'; exit 0 ;;
esac
echo "unexpected docker call: $*" >&2; exit 99
STUB
# curl: noted (in curl.calls), then the live site answers as the case's files say, else it can't be reached (exit 22):
#   live_exit   curl's status, as when it fails (22 for a 404, 28 for a timeout), saying so on stderr as curl does
#   live_body   the body it answers with, whatever is asked (exit 0)
#   live_site   it serves the site folder's own site/ (what the last publish wrote there), and a 404 for anything else
#   live_dir    it serves STUB_DIR/live/ (what the stand-in node last uploaded), and a 404 for anything else
#   live_fail_first N   the first N questions for offprint.json fail as a real one did just after an upload: curl 8
#               asked over HTTP/2 with -f, the address not there yet, says "curl: (56) The requested URL returned
#               error: 404" and ends with status 56
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/curl.calls"
for url; do :; done; path="${url%%\?*}"; path="${path#https://www.example.com/}"
if [ -f "$STUB_DIR/live_fail_first" ] && [ "$path" = offprint.json ] \
   && [ "$(grep -c 'offprint\.json' "$STUB_DIR/curl.calls")" -le "$(cat "$STUB_DIR/live_fail_first")" ]; then
  echo "curl: (56) The requested URL returned error: 404" >&2; exit 56
fi
if [ -f "$STUB_DIR/live_exit" ]; then rc="$(cat "$STUB_DIR/live_exit")"; echo "curl: ($rc) the stand-in failed" >&2; exit "$rc"; fi
if [ -f "$STUB_DIR/live_body" ]; then cat "$STUB_DIR/live_body"; exit 0; fi
if [ -f "$STUB_DIR/live_dir" ]; then
  if [ -f "$STUB_DIR/live/$path" ]; then cat "$STUB_DIR/live/$path"; exit 0; fi
  echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
fi
if [ -f "$STUB_DIR/live_site" ] && [ -f "$OFFPRINT_SITE/site/$path" ]; then cat "$OFFPRINT_SITE/site/$path"; exit 0; fi
echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
STUB
# gh: the repo is private
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo PRIVATE
STUB
# age, which encrypts the database backup: the suites' shared stand-in
cp "$SRC/tests/fixtures/age-standin" "$tmp/bin/age"
chmod +x "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/gh" "$tmp/bin/age"

n=0
# site_json [NAME [SETTINGS]]: the case's site.json, naming the adapter NAME (with SETTINGS, more JSON members, in its
# block), or with no adapter block at all (the adapter none) when NAME is empty.
site_json() {
  if [ -z "${1:-}" ]; then cp "$SRC/tests/fixtures/site.json" "$c/site.json"
  else sed "s#\"format\": 1,#\"format\": 1, \"adapter\": {\"name\": \"$1\"${2:+, $2}},#" "$SRC/tests/fixtures/site.json" > "$c/site.json"; fi
}
# commit MESSAGE: everything in the site folder committed and pushed (commits0 is then the count to compare with)
commit() {
  git -C "$c" add -A && git -C "$c" commit -q -m "$1" && git -C "$c" push -q origin main
  commits0="$(git -C "$c" rev-list --count HEAD)"
}
# newcase: a throwaway site folder $c (no adapter block yet), committed and pushed; its stand-ins' state in $S, the
# export the stand-in docker makes in $S/fixture.
newcase() {
  n=$((n + 1)); c="$tmp/case$n/repo"; S="$tmp/case$n/stubs"; O="$tmp/case$n/origin.git"
  mkdir -p "$c/site" "$c/backup" "$c/wp-content" "$c/var" "$S/bin" "$S/fixture/feed" "$S/fixture/hello"
  site_json
  echo '<html><body>New home</body></html>' > "$S/fixture/index.html"
  echo '<html><body>Gone</body></html>' > "$S/fixture/404.html"
  echo '<rss><channel><link>https://www.example.com/</link></channel></rss>' > "$S/fixture/feed/index.xml"
  echo '<html><body>Hello</body></html>' > "$S/fixture/hello/index.html"
  git init -q -b main "$c"
  git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
  cp "$SRC/templates/site.gitignore" "$c/.gitignore"
  echo '<html><body>Old</body></html>' > "$c/site/index.html"; echo 'OLD BACKUP' > "$c/backup/db.sql.age"; echo old > "$c/wp-content/keep.txt"
  # This Offprint's plugin, as setup-wp puts it in a site and commits it (a publish refuses to commit any other).
  mkdir -p "$c/wp-content/mu-plugins"; cp -R "$SRC/plugin/offprint.php" "$SRC/plugin/offprint" "$c/wp-content/mu-plugins/"
  git -C "$c" add -A && git -C "$c" commit -q -m initial
  git init -q --bare -b main "$O" && git -C "$c" remote add origin "$O" && git -C "$c" push -q origin main
  commits0="$(git -C "$c" rev-list --count HEAD)"
}
# adapter NAME [SETTINGS] < CODE: CODE as the site's own adapters/NAME/adapter.sh, and site.json naming it (with
# SETTINGS), committed and pushed.
adapter() {
  mkdir -p "$c/adapters/$1"; cat > "$c/adapters/$1/adapter.sh"
  site_json "$1" "${2:-}"; commit "adapter $1"
}
pub() {  # bin/publish for the site $c, from the case folder, with the stand-ins; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 \
    /bin/bash "$SRC/bin/publish" "$@" 2>&1)"; code=$?
}
js() {  # key -> value of that key in var/status.json
  php -r '$j = json_decode( (string) file_get_contents( $argv[1] ), true ); if ( ! is_array( $j ) ) { exit( 3 ); }
    $v = $j[ $argv[2] ] ?? null; echo is_array( $v ) ? json_encode( $v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES ) : ( is_bool( $v ) ? ( $v ? "true" : "false" ) : $v );' "$c/var/status.json" "$1"
}
valid() {  # status.json is a final one: valid JSON, all six keys, running false
  if php -r '$j = json_decode( (string) file_get_contents( $argv[1] ), true );
    exit( is_array( $j ) && 6 === count( array_intersect( array_keys( $j ), array( "state", "running", "at", "commit", "message", "warnings" ) ) )
      && false === $j["running"] ? 0 : 1 );' "$c/var/status.json"
  then ok "$1: status.json is valid, and final"; else bad "$1: status.json is not valid ($(cat "$c/var/status.json" 2>&1))"; fi
}
nocommit() { check "$1: no new commit" "$commits0" "$(git -C "$c" rev-list --count HEAD)"; }
oldsite() { check "$1: site/ unchanged" "<html><body>Old</body></html>|no" "$(cat "$c/site/index.html")|$(exists "$c/site/404.html")"; }
no_docker() { check "$1: docker never called" "no|no" "$(exists "$S/docker.calls")|$(exists "$S/docker.queries")"; }
short() { git -C "$c" rev-parse --short=7 HEAD; }
# id_of REV: the publish's id, recomputed from the commit REV: the entries of its
# site/ tree but offprint.json, as a tree
id_of() { git -C "$c" ls-tree "$1:site" | grep -v "$(printf '\t')offprint\.json\$" | git -C "$c" mktree; }
# id_blob ID: the git blob id of an offprint.json naming ID: exactly {"publish":"ID"} and a line end
id_blob() { printf '{"publish":"%s"}\n' "$1" | git -C "$c" hash-object --stdin; }
# fixture_id DIR: the git tree id of the files in DIR, recomputed with nothing of the site: in a repository of their
# own, in a folder of another name
fixture_id() {
  local r; r="$(mktemp -d "$tmp/id.XXXXXX")"; cp -R "$1/." "$r/"
  git init -q -b main "$r" && git -C "$r" add -A && git -C "$r" write-tree; rm -rf "$r"
}
# refused T TEXT: the publish was refused before anything was asked of Docker or exported: exit 2, a final failed status
# naming the problem (TEXT), nothing committed, site/ as it was.
refused() {
  check "$1: exits 2" 2 "$code"; check "$1: the status is failed" failed "$(js state)"; valid "$1"
  contains "$1: the status says why" "$2" "$(js message)"
  no_docker "$1"; nocommit "$1"; oldsite "$1"
}

# load [CODE]: lib/adapter.sh's offprint_adapter_load for the site $c, as bin/publish loads it (lib/site.sh first, then
# site.json), under set -u, in a shell of its own. Prints rc=N, then problem=TEXT if there is one, then, when the load
# worked, runs CODE there (calling the adapter's functions as bin/publish does, with offprint_adapter_call). PRE (shell
# code) runs just before the load. The adapter's private folder is removed at the
# end, as bin/publish removes it. Sets out.
cat > "$tmp/load.sh" <<'DRIVER'
set -u
. "$1/lib/site.sh"
. "$1/lib/adapter.sh"
trap offprint_adapter_cleanup EXIT
offprint_find_site
offprint_load_site
eval "${PRE:-}"
rc=0; offprint_adapter_load || rc=$?
printf 'rc=%s\n' "$rc"
[ -z "$OFFPRINT_ADAPTER_PROBLEM" ] || printf 'problem=%s\n' "$OFFPRINT_ADAPTER_PROBLEM"
if [ "$rc" = 0 ] && [ -n "${2:-}" ]; then eval "$2"; fi
DRIVER
load() { out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$tmp/load.sh" "$SRC" "${1:-}" 2>&1)"; }
# What every row of the contract is once the adapter is loaded, one line each.
show='printf "PREPARE=[%s]\nHOST=[%s]\nFILE_BYTES=%s\nFILES=%s\nTOTAL_BYTES=%s\nCONFIRM_SECONDS=%s\n" "$ADAPTER_PREPARE_FILES" "$ADAPTER_HOST_FILES" "$ADAPTER_MAX_FILE_BYTES" "$ADAPTER_MAX_FILES" "$ADAPTER_MAX_TOTAL_BYTES" "$ADAPTER_CONFIRM_SECONDS"
v=$(offprint_adapter_call adapter_validate 2>&1); echo "validate=$?[$v]"
mkdir -p "$OFFPRINT_SITE/../prep"; offprint_adapter_call adapter_prepare "$OFFPRINT_SITE/../prep"; echo "prepare=$?[$(ls -A "$OFFPRINT_SITE/../prep" | tr "\n" " ")]"
offprint_adapter_call adapter_deploy 0123456789abcdef0123456789abcdef01234567; echo "deploy=$?[$ADAPTER_PROBLEM]"
offprint_adapter_call adapter_confirm id 0123456789abcdef0123456789abcdef01234567; echo "confirm=$?[$ADAPTER_WHY]"
echo "hint=[$(offprint_adapter_call adapter_failure_hint)]"
echo "setup=[$(offprint_adapter_call adapter_setup)]"
echo "doctor=[$(offprint_adapter_call adapter_doctor)]"'

# === the contract: each row, set by an adapter, and its default ===
newcase; adapter bare <<'A'
# an adapter that sets nothing: every row is its default
A
load "$show"; t="an adapter that sets nothing"
check "$t: loads" "rc=0" "$(printf '%s\n' "$out" | head -n 1)"
contains "$t: ADAPTER_PREPARE_FILES is offprint.json (the default confirm reads it)" "PREPARE=[offprint.json]" "$out"
contains "$t: ADAPTER_HOST_FILES is empty" "HOST=[]" "$out"
contains "$t: ADAPTER_MAX_FILE_BYTES is 0 (no limit)" "FILE_BYTES=0" "$out"
contains "$t: ADAPTER_MAX_FILES is 0 (no limit)" "FILES=0" "$out"
contains "$t: ADAPTER_MAX_TOTAL_BYTES is 0 (no limit)" "TOTAL_BYTES=0" "$out"
contains "$t: ADAPTER_CONFIRM_SECONDS is 240" "CONFIRM_SECONDS=240" "$out"
contains "$t: adapter_validate returns 0, saying nothing" "validate=0[]" "$out"
contains "$t: adapter_prepare writes nothing" "prepare=0[]" "$out"
contains "$t: adapter_deploy returns 0" "deploy=0[]" "$out"
contains "$t: adapter_confirm is the default confirm, which asks nothing about an id that isn't one (2)" "confirm=2[]" "$out"
contains "$t: adapter_failure_hint prints nothing" "hint=[]" "$out"
contains "$t: adapter_setup has nothing to set up" "setup=[nothing to set up]" "$out"
contains "$t: adapter_doctor has nothing to check" "doctor=[nothing to check]" "$out"
load 'offprint_confirm_publish_id() { echo "asked: $*"; return 7; }; offprint_adapter_call adapter_confirm x y; echo "default=$?"'
check "$t: the default adapter_confirm is offprint_confirm_publish_id" \
  "rc=0|asked: x y|default=7" "$(printf '%s\n' "$out" | paste -sd'|' -)"

newcase; adapter every <<'A'
ADAPTER_PREPARE_FILES="_headers _redirects"
ADAPTER_HOST_FILES="build.json other.txt"
ADAPTER_MAX_FILE_BYTES=1000
ADAPTER_MAX_FILES=20
ADAPTER_MAX_TOTAL_BYTES=5000
ADAPTER_CONFIRM_SECONDS=7
adapter_validate() { echo 'site.json: "adapter.x" is wrong'; return 1; }
adapter_prepare() { : > "$1/_headers"; : > "$1/_redirects"; }
adapter_deploy() { ADAPTER_PROBLEM="the host said no"; return 1; }
adapter_confirm() { ADAPTER_WHY="it shows another"; return 1; }
adapter_failure_hint() { printf '; ask the host'; }
adapter_setup() { echo "set up every"; }
adapter_doctor() { echo "every is fine"; }
A
load "$show"; t="an adapter that sets every row"
check "$t: loads" "rc=0" "$(printf '%s\n' "$out" | head -n 1)"
contains "$t: its ADAPTER_PREPARE_FILES (no offprint.json: it has its own confirm)" "PREPARE=[_headers _redirects]" "$out"
contains "$t: its ADAPTER_HOST_FILES" "HOST=[build.json other.txt]" "$out"
contains "$t: its ADAPTER_MAX_FILE_BYTES" "FILE_BYTES=1000" "$out"
contains "$t: its ADAPTER_MAX_FILES" "FILES=20" "$out"
contains "$t: its ADAPTER_MAX_TOTAL_BYTES" "TOTAL_BYTES=5000" "$out"
contains "$t: its ADAPTER_CONFIRM_SECONDS" "CONFIRM_SECONDS=7" "$out"
contains "$t: its adapter_validate" 'validate=1[site.json: "adapter.x" is wrong]' "$out"
contains "$t: its adapter_prepare" "prepare=0[_headers _redirects ]" "$out"
contains "$t: its adapter_deploy" "deploy=1[the host said no]" "$out"
contains "$t: its adapter_confirm" "confirm=1[it shows another]" "$out"
contains "$t: its adapter_failure_hint" "hint=[; ask the host]" "$out"
contains "$t: its adapter_setup" "setup=[set up every]" "$out"
contains "$t: its adapter_doctor" "doctor=[every is fine]" "$out"

newcase; adapter ownconfirm <<'A'
adapter_confirm() { return 0; }
A
load "$show"; check "an adapter with its own confirm and no files of its own: ADAPTER_PREPARE_FILES is empty" "PREPARE=[]" "$(printf '%s\n' "$out" | grep '^PREPARE=')"
newcase; adapter keepsconfirm <<'A'
ADAPTER_PREPARE_FILES="_headers"
A
load "$show"; check "an adapter that keeps the default confirm and names files of its own: offprint.json is one of them too" \
  "PREPARE=[offprint.json _headers]" "$(printf '%s\n' "$out" | grep '^PREPARE=')"

# Nothing of the contract is taken from the environment: each variable and function is set afresh before the adapter
# is sourced (a function exported by the caller included).
newcase; adapter bare <<'A'
# sets nothing
A
out="$(cd "$tmp/case$n" && eval "adapter_deploy() { touch '$S/pwned'; return 1; }" && export -f adapter_deploy \
  && OFFPRINT_SITE="$c" ADAPTER_PREPARE_FILES=evil ADAPTER_HOST_FILES=evil ADAPTER_MAX_FILES=3 ADAPTER_CONFIRM_SECONDS=1 \
  /bin/bash "$tmp/load.sh" "$SRC" "$show" 2>&1)"; t="contract variables and an adapter_deploy function in the caller's environment"
contains "$t: ADAPTER_PREPARE_FILES is the default" "PREPARE=[offprint.json]" "$out"
contains "$t: ADAPTER_HOST_FILES is the default" "HOST=[]" "$out"
contains "$t: ADAPTER_MAX_FILES is the default" "FILES=0" "$out"
contains "$t: ADAPTER_CONFIRM_SECONDS is the default" "CONFIRM_SECONDS=240" "$out"
contains "$t: adapter_deploy is the default" "deploy=0[]" "$out"
check "$t: the exported one never ran" no "$(exists "$S/pwned")"

# === a site's own adapter, in its folder: found, and used ===
newcase; adapter rec <<'A'
adapter_prepare() { echo "$1" >> "$STUB_DIR/prepare.calls"; }
adapter_deploy() { echo "$1" >> "$STUB_DIR/deploy.calls"; }
adapter_confirm() { echo "$1 $2" >> "$STUB_DIR/confirm.calls"; }
A
pub; t="an adapter in the site's adapters/ folder"
check "$t: the publish works" "0|live" "$code|$(js state)"; valid "$t"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: adapter_prepare was given the private copy" "$(cd "$c" && pwd -P)/site.new" "$(cat "$S/prepare.calls" 2>&1)"
check "$t: adapter_deploy was given the pushed commit" "$sha" "$(cat "$S/deploy.calls" 2>&1)"
check "$t: and it is on GitHub" "$sha" "$(git -C "$O" rev-parse main)"
check "$t: adapter_confirm was asked about the publish (the site/ tree) and the commit" "$(git -C "$c" rev-parse HEAD:site) $sha" "$(cat "$S/confirm.calls" 2>&1)"
check "$t: no offprint.json is written (it has a confirm of its own)" "no|" "$(exists "$c/site/offprint.json")|$(git -C "$c" ls-tree --name-only HEAD -- site/offprint.json)"
check "$t: the message" "The site is live at ${sha:0:7}" "$(js message)"
check "$t: no network" no "$(exists "$S/curl.calls")"
# The tool's own adapter of a name comes first: one of the same name in the site folder is never sourced.
newcase; mkdir -p "$c/adapters/none"; printf 'touch "%s/sourced"\nadapter_confirm() { return 1; }\n' "$S" > "$c/adapters/none/adapter.sh"
commit "a site adapter called none"; pub; t="an adapter called none in the site's folder"
check "$t: the tool's none is used" "0|saved" "$(printf '%s|%s' "$code" "$(js state)")"
check "$t: the site's is never sourced" no "$(exists "$S/sourced")"

# === Review Focus 5: an adapter that can't be used is refused by name before anything is exported, exit 2 ===
said() { printf 'site.json: "adapter.name" is %s, and ' "$1"; }
newcase; site_json nosuch; commit "names an adapter nobody has"; pub; t="an unknown adapter"
refused "$t" "$(said nosuch)there is no adapter of that name: Offprint has none, and this site folder has no adapters/nosuch."
newcase; mkdir -p "$tmp/case$n/elsewhere/linked"; echo 'adapter_confirm() { return 0; }' > "$tmp/case$n/elsewhere/linked/adapter.sh"
mkdir -p "$c/adapters"; ln -s "$tmp/case$n/elsewhere/linked" "$c/adapters/linked"; site_json linked; commit "a linked adapter"
pub; refused "the adapter's folder is a symlink" "$(said linked)adapters/linked is a symlink; an adapter must be a real folder holding a real adapter.sh."
newcase; mkdir -p "$tmp/case$n/ext/x"; echo 'adapter_confirm() { return 0; }' > "$tmp/case$n/ext/x/adapter.sh"
ln -s "$tmp/case$n/ext" "$c/adapters"; site_json x; commit "adapters/ is a link"
pub; refused "the site's adapters folder is a symlink" "$(said x)adapters is a symlink; an adapter must be a real folder holding a real adapter.sh."
newcase; mkdir -p "$c/adapters/x"; echo 'adapter_confirm() { return 0; }' > "$c/adapters/x/real.sh"; ln -s real.sh "$c/adapters/x/adapter.sh"
site_json x; commit "adapter.sh is a link"
pub; refused "adapter.sh is a symlink" "$(said x)adapters/x/adapter.sh is a symlink; an adapter must be a real folder holding a real adapter.sh."
newcase; mkdir -p "$c/adapters/x"; echo 'see the docs' > "$c/adapters/x/README"; site_json x; commit "no adapter.sh"
pub; refused "adapter.sh missing" "$(said x)adapters/x/adapter.sh is missing."
newcase; site_json x; commit "names x"; mkdir -p "$c/adapters/x"; echo 'adapter_confirm() { return 0; }' > "$c/adapters/x/adapter.sh"
pub; refused "the site's adapter is not committed" "$(said x)adapters/x/adapter.sh isn't committed in this site folder's git repository; commit it first."
# uncommitted MESSAGE FIRST: the refusal for an adapter x with uncommitted changes, FIRST the first file changed
uncommitted() { printf '%sadapters/x has uncommitted changes (first: %s); commit them first.' "$(said x)" "$1"; }
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
echo 'touch "$STUB_DIR/edited"' >> "$c/adapters/x/adapter.sh"; pub; refused "the site's adapter with an uncommitted edit" "$(uncommitted adapters/x/adapter.sh)"
git -C "$c" add adapters/x/adapter.sh; pub; refused "the same edit, staged" "$(uncommitted adapters/x/adapter.sh)"
check "the uncommitted edit never ran, either time" no "$(exists "$S/edited")"
git -C "$c" show HEAD:adapters/x/adapter.sh > "$c/adapters/x/adapter.sh"; pub
refused "an edit staged, and the file on disk put back as committed" "$(uncommitted adapters/x/adapter.sh)"
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
echo 'adapter_confirm() { return 0; }' > "$c/adapters/x/helper.sh"; pub; refused "an uncommitted file beside adapter.sh" "$(uncommitted adapters/x/helper.sh)"
# Tracked, but named by the .gitignore: still the committed file, or refused.
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
echo '/adapters/' >> "$c/.gitignore"; commit "ignore adapters/"; echo '# edited' >> "$c/adapters/x/adapter.sh"
pub; refused "an edit to a committed adapter.sh that the .gitignore names" "$(uncommitted adapters/x/adapter.sh)"
# git's own variables that say where a repository or its work tree is can't make an uncommitted adapter pass for a
# committed one (git exports GIT_DIR inside any hook): here another repository has the same file committed.
other_repo() {  # other_repo: a repository at $other with adapters/x/adapter.sh as $c has it, committed
  other="$tmp/case$n/other"; git init -q -b main "$other"
  mkdir -p "$other/adapters/x"; cp "$c/adapters/x/adapter.sh" "$other/adapters/x/adapter.sh"
  git -C "$other" add -A && git -C "$other" -c user.name=O -c user.email=o@example.com commit -q -m other
}
newcase; site_json x; commit "names x"; mkdir -p "$c/adapters/x"; echo 'adapter_confirm() { return 0; }' > "$c/adapters/x/adapter.sh"; other_repo
GIT_DIR="$other/.git" pub; refused "an uncommitted adapter, GIT_DIR naming a repository that has it committed" \
  "$(said x)adapters/x/adapter.sh isn't committed in this site folder's git repository; commit it first."
t="the same, loaded by lib/adapter.sh for another caller (GIT_DIR exported)"
out="$(cd "$tmp/case$n" && GIT_DIR="$other/.git" OFFPRINT_SITE="$c" /bin/bash "$tmp/load.sh" "$SRC" 2>&1)"
check "$t: refused (2)" "rc=2" "$(printf '%s\n' "$out" | head -n 1)"; contains "$t: saying why" "isn't committed" "$out"
out="$(cd "$tmp/case$n" && GIT_WORK_TREE="$other" GIT_INDEX_FILE="$other/.git/index" OFFPRINT_SITE="$c" /bin/bash "$tmp/load.sh" "$SRC" 2>&1)"
check "the same, GIT_WORK_TREE and GIT_INDEX_FILE exported: refused (2)" "rc=2" "$(printf '%s\n' "$out" | head -n 1)"
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
echo '# edited' >> "$c/adapters/x/adapter.sh"; other_repo; git -C "$c" show HEAD:adapters/x/adapter.sh > "$other/adapters/x/adapter.sh"
out="$(cd "$tmp/case$n" && GIT_WORK_TREE="$other" OFFPRINT_SITE="$c" /bin/bash "$tmp/load.sh" "$SRC" 2>&1)"
check "an edited adapter, GIT_WORK_TREE naming a folder where it is as committed: refused (2)" "rc=2" "$(printf '%s\n' "$out" | head -n 1)"
# Letter case: the Mac's disk ignores it, git doesn't. An adapter committed under another case is not the committed
# adapters/NAME/adapter.sh (refused on either disk, if for a different reason).
newcase; mkdir -p "$c/Adapters/x"; echo 'adapter_confirm() { return 0; }' > "$c/Adapters/x/adapter.sh"; site_json x; commit "Adapters/"
pub; refused "the adapter committed as Adapters/x/adapter.sh" "$(said x)"
newcase; mkdir -p "$c/adapters/x"; echo 'adapter_confirm() { return 0; }' > "$c/adapters/x/ADAPTER.SH"; site_json x; commit "ADAPTER.SH"
pub; refused "the adapter committed as adapters/x/ADAPTER.SH" "$(said x)"
# WordPress can write wp-content/: an adapters folder there is never looked at, even committed (a publish commits
# wp-content/), and even when the publish is started from inside wp-content/.
newcase; mkdir -p "$c/wp-content/adapters/x"; printf 'touch "%s/sourced"\nadapter_confirm() { return 0; }\n' "$S" > "$c/wp-content/adapters/x/adapter.sh"
site_json x; commit "an adapter WordPress planted"; pub; t="an adapter planted in wp-content/adapters/"
refused "$t" "$(said x)there is no adapter of that name"; check "$t: never sourced" no "$(exists "$S/sourced")"
out="$(cd "$c/wp-content" && env -u OFFPRINT_SITE PATH="$tmp/bin:$PATH" STUB_DIR="$S" /bin/bash "$SRC/bin/publish" 2>&1)"; code=$?
t="the same, the publish started in wp-content/"; check "$t: exits 2" 2 "$code"; check "$t: never sourced" no "$(exists "$S/sourced")"
# The adapter's name is checked again by lib/adapter.sh (site.json's checker allows none of these).
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
for bad_name in '../x' 'X' 'x/../../wp-content/x' "$(printf 'x\nnone')" ''; do
  PRE="ADAPTER_NAME='$bad_name'" load; t="ADAPTER_NAME '$(printf '%s' "$bad_name" | tr '\n' '?')' (not an adapter's name)"
  check "$t: refused (2)" "rc=2" "$(printf '%s\n' "$out" | head -n 1)"; contains "$t: saying so" "that isn't an adapter's name" "$out"
done
# An adapter.sh that fails as it is loaded, or sets a variable of the contract to something it can't be.
newcase; adapter x <<'A'
return 3
A
pub; refused "an adapter.sh that fails as it is loaded" "$(said x)its adapter.sh failed when it was loaded (it returned 3)."
for bad_set in 'ADAPTER_MAX_FILES=abc' 'ADAPTER_MAX_FILE_BYTES=-1' 'ADAPTER_MAX_TOTAL_BYTES=08' 'ADAPTER_CONFIRM_SECONDS="1 2"' 'unset ADAPTER_MAX_FILES'; do
  newcase; adapter x < <(printf 'adapter_confirm() { return 0; }\n%s\n' "$bad_set"); var="${bad_set#unset }"; var="${var%%=*}"
  pub; refused "an adapter.sh that sets $bad_set" "$(said x)its adapter.sh sets $var to something that isn't a whole number."
done
for bad_set in 'ADAPTER_HOST_FILES="../x"' 'ADAPTER_HOST_FILES="a/b"' "ADAPTER_PREPARE_FILES='*'" 'ADAPTER_PREPARE_FILES=".."' 'ADAPTER_HOST_FILES="a;b"'; do
  newcase; adapter x < <(printf 'adapter_confirm() { return 0; }\n%s\n' "$bad_set"); var="${bad_set%%=*}"
  pub; refused "an adapter.sh that sets $bad_set" "$(said x)its adapter.sh sets $var to something that isn't a list of file names (letters, digits, dots, dashes and underscores, separated by spaces)."
done
# A name in two of the three lists, in any letter case (the Mac's disk takes one for the other): refused by name. (With
# the default confirm, offprint.json is one of the adapter's own files.)
for spec in 'ADAPTER_PREPARE_FILES="_headers"; ADAPTER_HOST_FILES="build.json _Headers"|_headers|ADAPTER_PREPARE_FILES|ADAPTER_HOST_FILES' \
  'ADAPTER_PREPARE_FILES="_redirects"; ADAPTER_HOST_SPECIAL_FILES="_REDIRECTS"|_redirects|ADAPTER_PREPARE_FILES|ADAPTER_HOST_SPECIAL_FILES' \
  'ADAPTER_HOST_FILES="Build.json"; ADAPTER_HOST_SPECIAL_FILES=".ignore build.JSON"|build.json|ADAPTER_HOST_FILES|ADAPTER_HOST_SPECIAL_FILES' \
  'ADAPTER_HOST_FILES="OFFPRINT.json"|offprint.json|ADAPTER_PREPARE_FILES|ADAPTER_HOST_FILES'; do
  set_code="${spec%%|*}"; rest="${spec#*|}"; dup="${rest%%|*}"; rest="${rest#*|}"; l1="${rest%%|*}"; l2="${rest#*|}"
  case "$set_code" in *OFFPRINT.json*) confirm="" ;; *) confirm='adapter_confirm() { return 0; }' ;; esac
  newcase; adapter x < <(printf '%s\n%s\n' "$confirm" "$set_code")
  PUBLISH_TIMEOUT_SECONDS=1 pub; refused "an adapter.sh that sets $set_code" "$(said x)its adapter.sh names $dup (in some letter case) in both $l1 and $l2; a file name may be in only one of the three lists."
done
# The load hands back the adapter's own ADAPTER_ variables only: ADAPTER_NAME and ADAPTER_SET_* stay site.json's, even
# when what the adapter's shell writes out names them (here an EXIT trap of its top level adds them as that shell ends).
newcase; adapter sneak '"worker": "mine"' <<'A'
trap 'printf "ADAPTER_NAME\0other\0ADAPTER_SET_WORKER\0theirs\0ADAPTER_SET_EXTRA\0x\0" >> "$OFFPRINT_ADAPTER_TMP/variables"' EXIT
adapter_confirm() { return 0; }
A
load 'printf "NAME=%s WORKER=%s EXTRA=%s\n" "$ADAPTER_NAME" "${ADAPTER_SET_WORKER-unset}" "${ADAPTER_SET_EXTRA-unset}"'
t="an adapter whose shell adds ADAPTER_NAME and ADAPTER_SET_* to what the load takes back"
check "$t: loads, the name and settings still site.json's" "rc=0|NAME=sneak WORKER=mine EXTRA=unset" "$(printf '%s\n' "$out" | paste -sd'|' -)"

# === adapter_validate: its settings are checked before anything is exported ===
newcase; adapter v '"worker": "BAD"' <<'A'
adapter_validate() {
  local rc=0
  case "${ADAPTER_SET_WORKER:-}" in [[:lower:]]*) ;; *) echo 'site.json: "adapter.worker" must start with a lowercase letter.'; rc=1 ;; esac
  [ -n "${ADAPTER_SET_REGION:-}" ] || { echo 'site.json: "adapter.region" is missing.'; rc=1; }
  return "$rc"
}
adapter_confirm() { return 0; }
A
pub; t="adapter_validate finds two problems"
check "$t: exits 1" 1 "$code"; check "$t: failed" failed "$(js state)"; valid "$t"
check "$t: the status names the first" 'site.json has a problem: site.json: "adapter.worker" must start with a lowercase letter; nothing was published.' "$(js message)"
contains "$t: the log has both" 'site.json: "adapter.region" is missing.' "$(cat "$c/var/publish.log")"
no_docker "$t"; nocommit "$t"; oldsite "$t"
site_json v '"worker": "good", "region": "eu"'; commit "good settings"; pub --no-push; t="the same adapter, its settings right"
check "$t: the publish works" "0|Committed, not pushed (--no-push)." "$code|$(js message)"

# === adapter_prepare: its own files, written into the private copy after the export's are refused, then checked ===
prepare_adapter() {  # an adapter p with files of its own, a host file, and the default confirm (so offprint.json too)
  adapter p <<'A'
ADAPTER_PREPARE_FILES="_headers _redirects"
ADAPTER_HOST_FILES="build.json"
adapter_prepare() {
  touch "$STUB_DIR/prepared"
  printf '/feed/\n  Content-Type: application/rss+xml\n' > "$1/_headers"
  printf '/feed /feed/ 301\n' > "$1/_redirects"
}
A
}
newcase; prepare_adapter; echo x > "$S/fixture/hello/_headers"; pub --no-push; t="an adapter's own files"
check "$t: the publish works" 0 "$code"; check "$t: prepare ran" yes "$(exists "$S/prepared")"
check "$t: its files are published, as it wrote them" "/feed /feed/ 301" "$(git -C "$c" show HEAD:site/_redirects 2>&1)"
check "$t: both" yes "$(git -C "$c" cat-file -e HEAD:site/_headers 2>/dev/null && echo yes)"
check "$t: the same names deeper down in the export are the export's own" "x" "$(git -C "$c" show HEAD:site/hello/_headers 2>&1)"
check "$t: offprint.json (it keeps the default confirm) names the id of all the rest of site/, its files included" \
  "$(id_blob "$(id_of HEAD)")|site/_headers" "$(git -C "$c" rev-parse HEAD:site/offprint.json 2>&1)|$(git -C "$c" ls-tree --name-only HEAD -- site/_headers)"
# Review Focus 3: the container planting the adapter's own files (or the host's) in the export, in any letter case:
# refused before adapter_prepare writes anything.
for f in _headers OFFPRINT.JSON Build.json _Redirects offprint.json; do
  case "$f" in [Bb]uild.json) who="the deploy writes build.json" ;; [Oo][Ff]*) who="the publish writes offprint.json" ;;
    _[Hh]*) who="the publish writes _headers" ;; *) who="the publish writes _redirects" ;; esac
  newcase; prepare_adapter; echo planted > "$S/fixture/$f"; pub --no-push; t="$f at the root of the export (Review Focus 3)"
  check "$t: refused" "1|failed" "$code|$(js state)"; valid "$t"
  check "$t: naming it" "The export failed the checks, nothing was published: $who at the root, so the export can't have one: ./$f" "$(js message)"
  check "$t: before the adapter wrote anything" no "$(exists "$S/prepared")"
  check "$t: the checked copy is removed" no "$(exists "$c/site.new")"; nocommit "$t"; oldsite "$t"
done
newcase; prepare_adapter; mkdir -p "$S/fixture/_HEADERS"; pub --no-push; t="a folder called _HEADERS at the root of the export"
check "$t: refused" failed "$(js state)"; contains "$t: naming it" "can't have one: ./_HEADERS" "$(js message)"; check "$t: before prepare" no "$(exists "$S/prepared")"
# The checks look at what the adapter wrote too.
newcase; adapter p <<'A'
ADAPTER_PREPARE_FILES="_headers"
adapter_prepare() { printf '/*\n  Link: <https://mysite.test/x>\n' > "$1/_headers"; }
adapter_confirm() { return 0; }
A
pub --no-push; t="an adapter that writes the local host into its own file"
check "$t: the checks refuse it" failed "$(js state)"; contains "$t: naming it" "contains mysite.test: _headers" "$(js message)"; nocommit "$t"
newcase; adapter p <<'A'
adapter_prepare() { echo "no room" >&2; return 1; }
adapter_confirm() { return 0; }
A
pub --no-push; t="adapter_prepare fails"
check "$t: failed" "1|failed" "$code|$(js state)"; valid "$t"
check "$t: says so" "The adapter couldn't prepare the export (see var/publish.log); nothing was published." "$(js message)"
contains "$t: what it said is in the log" "no room" "$(cat "$c/var/publish.log")"; nocommit "$t"; oldsite "$t"
newcase; adapter p <<'A'
adapter_prepare() { ADAPTER_PROBLEM="$(printf 'the export has a/b, which the host can\047t take\a')"; return 1; }
adapter_confirm() { return 0; }
A
pub --no-push; t="adapter_prepare fails, giving ADAPTER_PROBLEM"
check "$t: the status gives its reason, made printable" "1|The adapter couldn't prepare the export: the export has a/b, which the host can't take?; nothing was published." "$code|$(js message)"
valid "$t"; nocommit "$t"; oldsite "$t"

# === ADAPTER_HOST_FILES: never committed, even if one appears in site/ before git add ===
newcase; adapter h <<'A'
ADAPTER_HOST_FILES="build.json"
adapter_confirm() { return 0; }
A
real_git="$(command -v git)"
cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" add "*) [ -e "$c/site/index.html" ] && [ ! -e "$S/fired" ] && touch "$S/fired" && echo '{"commit":"x"}' > "$c/site/build.json" ;; esac
exec "$real_git" "\$@"
STUB
chmod +x "$S/bin/git"; pub --no-push; t="a host file that appears in site/ just before git add"
check "control: it appeared" yes "$(exists "$c/site/build.json")"
check "$t: the publish works" 0 "$code"; check "$t: it isn't committed" "" "$(git -C "$c" ls-tree --name-only HEAD -- site/build.json)"
check "$t: the rest is" "site/index.html" "$(git -C "$c" ls-tree --name-only HEAD -- site/index.html)"

# === adapter_deploy: makes the pushed commit live; when it can't, the publish fails, and nothing is undone ===
newcase; adapter d <<'A'
adapter_deploy() { echo "$1" >> "$STUB_DIR/deploy.calls"; ADAPTER_PROBLEM="the host refused the upload"; return 1; }
adapter_confirm() { echo asked >> "$STUB_DIR/confirm.calls"; return 0; }
A
pub; t="adapter_deploy fails"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: exits 1" 1 "$code"; check "$t: failed" failed "$(js state)"; valid "$t"
check "$t: says it was pushed, and the adapter's reason" "${sha:0:7} is pushed, but the deploy failed: the host refused the upload" "$(js message)"
check "$t: the commit stays" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
check "$t: and stays pushed" "$sha" "$(git -C "$O" rev-parse main)"
check "$t: site/ stays the new one" "<html><body>New home</body></html>" "$(cat "$c/site/index.html")"
check "$t: adapter_deploy was given the commit" "$sha" "$(cat "$S/deploy.calls" 2>&1)"
check "$t: the live site was never asked" no "$(exists "$S/confirm.calls")"
newcase; adapter d <<'A'
adapter_deploy() { return 1; }
adapter_confirm() { return 0; }
A
pub; t="adapter_deploy fails without a reason"; check "$t: says so" "$(short) is pushed, but the deploy failed: the adapter gave no reason (see var/publish.log)" "$(js message)"

# === adapter_confirm, ADAPTER_CONFIRM_SECONDS and adapter_failure_hint ===
# 3 seconds, so it is asked more than once whatever the clock: bin/publish counts whole seconds, and asks before it
# first looks at the clock, so with 1 second a first ask that crosses a second's end is the only one.
newcase; adapter c <<'A'
ADAPTER_CONFIRM_SECONDS=3
adapter_confirm() { echo "$2" >> "$STUB_DIR/confirm.calls"; ADAPTER_WHY="it shows something else"; return 1; }
adapter_failure_hint() { printf '; ask the host'; }
A
start=$SECONDS; pub; t="a confirm that never sees the commit (ADAPTER_CONFIRM_SECONDS=3)"
check "$t: failed" "1|failed" "$code|$(js state)"; valid "$t"
check "$t: the message, with the adapter's why and hint" "$(short) is pushed, but the live site hasn't shown it after 3 seconds (it shows something else); ask the host" "$(js message)"
check "$t: it was pushed" "$(git -C "$c" rev-parse HEAD)" "$(git -C "$O" rev-parse main)"
check "$t: asked more than once" yes "$([ "$(wc -l < "$S/confirm.calls")" -ge 2 ] && echo yes || echo no)"
check "$t: and stopped soon" yes "$([ $((SECONDS - start)) -lt 17 ] && echo yes || echo no)"
echo '<p>more</p>' > "$S/fixture/hello/index.html"; PUBLISH_TIMEOUT_SECONDS=2 pub; t="PUBLISH_TIMEOUT_SECONDS=2 instead"
check "$t: is the limit" "$(short) is pushed, but the live site hasn't shown it after 2 seconds (it shows something else); ask the host" "$(js message)"
newcase; adapter c <<'A'
ADAPTER_CONFIRM_SECONDS=1
adapter_confirm() { return 2; }
A
pub; t="a confirm that can't reach the live site, and no hint"
check "$t: the message ends at the why" "$(short) is pushed, but the live site hasn't shown it after 1 seconds (it couldn't be reached)" "$(js message)"
newcase; adapter c <<'A'
ADAPTER_CONFIRM_SECONDS=1
adapter_confirm() { return 1; }
A
pub; t="a confirm that says not yet without saying why"
check "$t: the message" "$(short) is pushed, but the live site hasn't shown it after 1 seconds (it doesn't show it yet)" "$(js message)"
newcase; adapter c <<'A'
ADAPTER_CONFIRM_SECONDS=1
A
pub; t="the default confirm, and a live site that can't be reached"
check "$t: never live" "1|$(short) is pushed, but the live site hasn't shown it after 1 seconds (it couldn't be reached)" "$code|$(js message)"
check "$t: it asked the live site for offprint.json" yes "$(grep -q '/offprint\.json?p=' "$S/curl.calls" 2>/dev/null && echo yes || echo no)"
newcase; adapter c <<'A'
adapter_confirm() { echo x >> "$STUB_DIR/confirm.calls"; [ "$(wc -l < "$STUB_DIR/confirm.calls")" -ge 2 ]; }
A
pub; t="a confirm that sees the commit on its second look"
check "$t: live" "0|live" "$code|$(js state)"; check "$t: asked twice" 2 "$(wc -l < "$S/confirm.calls" | tr -d ' ')"
# Nothing new to push: the live site is still asked, once, before the publish may say unchanged.
newcase; adapter c <<'A'
adapter_confirm() {
  echo "$2" >> "$STUB_DIR/confirm.calls"
  [ ! -f "$STUB_DIR/behind" ] || { ADAPTER_WHY="it still shows the one before"; return 1; }
  [ ! -f "$STUB_DIR/away" ] || return 2
  return 0
}
adapter_failure_hint() { printf '; ask the host'; }
A
pub; pub; t="nothing new, and the live site has it"
check "$t: unchanged" "0|unchanged" "$code|$(js state)"; check "$t: it was asked (once for each publish)" 2 "$(wc -l < "$S/confirm.calls" | tr -d ' ')"
touch "$S/behind"; pub; t="nothing new, and the live site doesn't show it"
check "$t: failed" "1|failed" "$code|$(js state)"; valid "$t"
check "$t: says so, with the adapter's why and hint" "GitHub has $(short), but the live site hasn't shown it (it still shows the one before); ask the host" "$(js message)"
check "$t: asked once" 3 "$(wc -l < "$S/confirm.calls" | tr -d ' ')"
rm "$S/behind"; touch "$S/away"; pub; t="nothing new, and the live site can't be reached"
check "$t: says so" "GitHub has $(short), but the live site couldn't be reached to confirm it serves that (see var/publish.log); publish again in a minute." "$(js message)"

# === the default confirm: the publish's id, which the publish writes in offprint.json and the live site must show ===
# defaults_adapter: the second fixture adapter: a site adapter d that sets nothing, so it uses every default (the
# default confirm, and so offprint.json, which the publish writes). dpub: a publish, PUBLISH_TIMEOUT_SECONDS standing in
# for its 240 seconds.
defaults_adapter() {
  adapter d <<'A'
# Uses every default: the publish writes offprint.json, and the default confirm asks the live site for it.
A
}
dpub() { PUBLISH_TIMEOUT_SECONDS=1 pub "$@"; }
newcase; defaults_adapter; touch "$S/live_site"; dpub; t="the adapter that uses every default, a first publish"
sha="$(git -C "$c" rev-parse HEAD)"; id="$(id_of HEAD)"; id_first="$id"
check "$t: live" "0|live" "$code|$(js state)"; valid "$t"
check "$t: the message" "The site is live at ${sha:0:7}" "$(js message)"
check "$t: site/offprint.json is committed, a plain file: exactly {\"publish\":\"ID\"} and a line end, ID the tree of site/ without it" \
  "100644 blob $(id_blob "$id")" "$(git -C "$c" ls-tree HEAD -- site/offprint.json | cut -f1)"
check "$t: the same bytes are in site/, for the host" "$(id_blob "$id")" "$(git -C "$c" hash-object --no-filters -- site/offprint.json 2>&1)"
check "$t: the id is the export's own tree, recomputed in a repository of its own (nothing of site/ or site.new)" "$id" "$(fixture_id "$S/fixture")"
check "$t: the live site was asked for offprint.json, with the id" "-fsS --max-time 10 https://www.example.com/offprint.json?p=$id" "$(cat "$S/curl.calls" 2>&1)"
check "$t: pushed" "$sha" "$(git -C "$O" rev-parse main)"
check "$t: git sees nothing to commit afterwards" "" "$(git -C "$c" status --porcelain)"
rm -f "$S/curl.calls"; dpub; t="the same export published again"
check "$t: unchanged" "0|unchanged|Nothing has changed since the last publish." "$code|$(js state)|$(js message)"
check "$t: no new commit" "$sha" "$(git -C "$c" rev-parse HEAD)"
check "$t: the same id, which the live site was still asked for, once" "-fsS --max-time 10 https://www.example.com/offprint.json?p=$id" "$(cat "$S/curl.calls" 2>&1)"
# Review Focus 1: the deploy half-happens (the live site stays at the publish before). The status says so, nothing is
# undone, and the next publish, with nothing new, asks the live site again before it says unchanged.
cp "$c/site/offprint.json" "$S/live_body" 2>/dev/null; rm "$S/live_site"
echo '<p>more</p>' > "$S/fixture/hello/index.html"; rm -f "$S/curl.calls"; dpub; t="a changed export, the live site still showing the publish before"
sha2="$(git -C "$c" rev-parse HEAD)"; id2="$(id_of HEAD)"
check "$t: failed" "1|failed" "$code|$(js state)"; valid "$t"
check "$t: says it was pushed, and which publish the live site still shows" \
  "${sha2:0:7} is pushed, but the live site hasn't shown it after 1 seconds (it still shows publish ${id:0:7})" "$(js message)"
check "$t: a new id" yes "$([ -n "$id2" ] && [ "$id2" != "$id" ] && echo yes || echo no)"
check "$t: the export's own tree, in the offprint.json committed" "$id2|$(id_blob "$id2")" "$(fixture_id "$S/fixture")|$(git -C "$c" rev-parse HEAD:site/offprint.json)"
check "$t: committed, and pushed: nothing undone" "$((commits0 + 2))|$sha2" "$(git -C "$c" rev-list --count HEAD)|$(git -C "$O" rev-parse main)"
check "$t: the live site was asked for the new id" yes "$(grep -qxF -- "-fsS --max-time 10 https://www.example.com/offprint.json?p=$id2" "$S/curl.calls" && echo yes || echo no)"
rm -f "$S/curl.calls"; dpub; t="the same export again, the live site still behind (Review Focus 1)"
check "$t: failed, not unchanged" "1|failed" "$code|$(js state)"; valid "$t"
check "$t: says which publish the live site still shows" "GitHub has ${sha2:0:7}, but the live site hasn't shown it (it still shows publish ${id:0:7})" "$(js message)"
check "$t: no new commit" "$sha2" "$(git -C "$c" rev-parse HEAD)"
check "$t: asked the live site for the same id, once" "-fsS --max-time 10 https://www.example.com/offprint.json?p=$id2" "$(cat "$S/curl.calls" 2>&1)"
rm -f "$S/live_body"; touch "$S/live_site"; dpub; t="the same export again, once the live site shows it"
check "$t: unchanged" "0|unchanged|Nothing has changed since the last publish." "$code|$(js state)|$(js message)"
# The id is the files' content and names, and the modes git records: nothing else.
newcase; defaults_adapter; touch "$S/live_site" "$S/export_reverse"; mv "$S/fixture" "$S/made"; mkdir "$S/fixture"
( umask 077; cd "$S/made" && find . -type f | LC_ALL=C sort -r | while IFS= read -r f; do mkdir -p "$S/fixture/${f%/*}"; cat "$f" > "$S/fixture/$f"; done )
LC_ALL=C dpub; t="the same export, its files made and exported in reverse order, under another umask and locale"
check "control: $t: its files are mode 600 in site/" yes "$([ -n "$(find "$c/site/index.html" -perm 600)" ] && echo yes || echo no)"
check "$t: live" "0|live" "$code|$(js state)"
check "$t: the same id as the first case's, in offprint.json" "$id_first|$(id_blob "$id_first")" "$(id_of HEAD)|$(git -C "$c" rev-parse HEAD:site/offprint.json 2>&1)"
# offprint.json is the publish's own: in the export it is refused (Review Focus
# 3), and so it is if the adapter writes it.
for f in offprint.json Offprint.JSON; do
  newcase; defaults_adapter; echo '{"publish":"0123456789abcdef0123456789abcdef01234567"}' > "$S/fixture/$f"; dpub; t="$f in the export, the adapter that uses every default"
  check "$t: refused" "1|The export failed the checks, nothing was published: the publish writes offprint.json at the root, so the export can't have one: ./$f" "$code|$(js message)"
  nocommit "$t"; oldsite "$t"; check "$t: the live site isn't asked" no "$(exists "$S/curl.calls")"
done
newcase; adapter pw <<'A'
adapter_prepare() { printf '{"publish":"%s"}\n' 0123456789abcdef0123456789abcdef01234567 > "$1/offprint.json"; }
A
dpub; t="an adapter that keeps the default confirm, and whose adapter_prepare writes offprint.json itself"
check "$t: refused by the checks" "1|The export failed the checks, nothing was published: the publish writes offprint.json at the root, so the export can't have one: ./offprint.json" "$code|$(js message)"
nocommit "$t"; oldsite "$t"
# Written by the publish after git add, never read back: a link planted by that name
# in site/ just before is never followed.
newcase; defaults_adapter; touch "$S/live_site"; echo theirs > "$tmp/case$n/target"
cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" add "*) [ -d "$c/site" ] && [ ! -e "$S/fired" ] && touch "$S/fired" && ln -s "$tmp/case$n/target" "$c/site/offprint.json" ;; esac
exec "$real_git" "\$@"
STUB
chmod +x "$S/bin/git"; dpub; t="a link planted at site/offprint.json just before git add"
check "control: it was planted" yes "$(exists "$S/fired")"
check "$t: the publish works" "0|live" "$code|$(js state)"
check "$t: the file it pointed to is untouched" theirs "$(cat "$tmp/case$n/target")"
check "$t: site/offprint.json is the publish's own, a plain file" "no|$(id_blob "$(id_of HEAD)")" "$([ -L "$c/site/offprint.json" ] && echo yes || echo no)|$(git -C "$c" hash-object --no-filters -- site/offprint.json 2>&1)"
check "$t: and so is the one committed" "100644 blob $(id_blob "$(id_of HEAD)")" "$(git -C "$c" ls-tree HEAD -- site/offprint.json | cut -f1)"
# The id is 40 hex digits, as the contract says: a repository whose ids are longer is refused before anything is
# exported (beside adapter_validate): Docker never asked, site/ and the dump as they were, nothing committed.
newcase; rm -rf "$c/.git" "$O"; git init -q -b main --object-format=sha256 "$c"
git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
git init -q --bare -b main --object-format=sha256 "$O"; git -C "$c" remote add origin "$O"; defaults_adapter
dpub --no-push; t="a SHA-256 repository (its ids are 64 hex digits)"
check "$t: refused" "1|failed" "$code|$(js state)"; valid "$t"
check "$t: saying why" "Git's ids in this site folder are 64 hex digits (a SHA-256 repository?), and the publish's id, which offprint.json gives the live site, must be 40; nothing was published." "$(js message)"
nocommit "$t"; check "$t: no offprint.json written" no "$(exists "$c/site/offprint.json")"
no_docker "$t"; oldsite "$t"; check "$t: the backup as it was" "OLD BACKUP" "$(cat "$c/backup/db.sql.age")"
dpub --dry-run; t="the same, a dry run"
check "$t: refused the same way, nothing exported" "1|failed|no" "$code|$(js state)|$(exists "$S/docker.calls")"
# The 40 hex digits are offprint.json's: an adapter with a confirm of its own (none, here) publishes from such a
# repository as before.
newcase; rm -rf "$c/.git" "$O"; git init -q -b main --object-format=sha256 "$c"
git -C "$c" config user.email t@example.com; git -C "$c" config user.name Test
git init -q --bare -b main --object-format=sha256 "$O"; git -C "$c" remote add origin "$O"; commit "a SHA-256 repository"
pub --no-push; t="a SHA-256 repository, and the adapter none (a confirm of its own: no offprint.json)"
check "$t: committed, as before" "0|Committed, not pushed (--no-push).|$((commits0 + 1))" "$code|$(js message)|$(git -C "$c" rev-list --count HEAD)"
# What the live site answers: the three outcomes. answer [ID]: the default confirm asked about ID (default $want), as
# bin/publish asks it; sets got to STATUS|WHY. body FORMAT ARGS...: the live site answers that (printf FORMAT ARGS...).
newcase; defaults_adapter; t="the default confirm"
want=0123456789abcdef0123456789abcdef01234567; other=fedcba9876543210fedcba9876543210fedcba98
answer() {
  PATH="$tmp/bin:$PATH" STUB_DIR="$S" load "offprint_adapter_call adapter_confirm ${1:-$want} c0ffee0000000000000000000000000000000000 2> /dev/null; echo \"answer=\$?|\$ADAPTER_WHY\""
  got="$(printf '%s\n' "$out" | sed -n 's/^answer=//p')"
}
body() { rm -f "$S/live_body" "$S/live_exit" "$S/curl.calls"; printf "$@" > "$S/live_body"; }
body '{"publish":"%s"}\n' "$want"; answer; check "$t: offprint.json naming the id: live (0)" "0|" "$got"
check "$t: asked with curl -fsS --max-time 10, at the public address, ?p= the id" "-fsS --max-time 10 https://www.example.com/offprint.json?p=$want" "$(cat "$S/curl.calls" 2>&1)"
body ' {\r\n  "publish" : "%s"\r\n}\r\n' "$want"; answer; check "$t: the same, with JSON's spaces and line ends: live (0)" "0|" "$got"
body '{"publish":"%s"}\n' "$other"; answer; check "$t: another publish's id: not yet (1), saying which" "1|it still shows publish fedcba9" "$got"
body '<!DOCTYPE html>\n<html><body>Not found</body></html>\n'; answer; check "$t: HTML: not yet (1), naming no publish" "1|its offprint.json names no publish" "$got"
body ''; answer; check "$t: an empty body: not yet (1), naming no publish" "1|its offprint.json names no publish" "$got"
body '{"publish":""}'; answer; check "$t: {\"publish\":\"\"}: not yet (1), naming no publish" "1|its offprint.json names no publish" "$got"
body '{"publish":"%s"}' "$(printf '%s' "$want" | tr a-f A-F)"; answer; check "$t: the id in capitals (not an id): naming no publish" "1|its offprint.json names no publish" "$got"
body '{"publish":"%s0"}' "$want"; answer; check "$t: 41 hex digits (not an id): naming no publish" "1|its offprint.json names no publish" "$got"
body '{"publish":"%s","publish":"%s"}' "$want" "$other"; answer; check "$t: two ids (not one object of one id): naming no publish" "1|its offprint.json names no publish" "$got"
body '\033[2J{"publish":"%s"}\a' "$other"; answer; check "$t: control characters around another id: naming no publish, nothing of them shown" "1|its offprint.json names no publish" "$got"
body '{"publish":"%s"' "$want"; { head -c 1048576 /dev/zero | tr '\0' ' '; printf '}'; } >> "$S/live_body"; start=$SECONDS; answer
check "$t: a body of 1 MB (more than any offprint.json): naming no publish, soon" "1|its offprint.json names no publish|yes" "$got|$([ $((SECONDS - start)) -lt 10 ] && echo yes || echo no)"
rm -f "$S/live_body"; echo 22 > "$S/live_exit"; answer; check "$t: a 404 (curl -f fails, 22): couldn't be reached (2)" "2|" "$got"
echo 28 > "$S/live_exit"; answer; check "$t: a timeout (curl's --max-time, 28): couldn't be reached (2)" "2|" "$got"
rm "$S/live_exit"; body '{"publish":"%s"}\n' "$want"; PUBLISH_CHECK_URL=https://example.test/where.json answer
check "$t: PUBLISH_CHECK_URL is asked instead of the public address" "0||-fsS --max-time 10 https://example.test/where.json?p=$want" "$got|$(cat "$S/curl.calls" 2>&1)"
for bad_id in not-an-id "${want}${want:0:24}" "$(printf '%s' "$want" | tr a-f A-F)"; do
  rm -f "$S/curl.calls"; answer "$bad_id"
  check "$t: asked about $bad_id (not a publish id): 2, and the live site isn't asked" "2||no" "$got|$(exists "$S/curl.calls")"
done
# Through a whole publish: nothing the live site answers reaches the log or the status.
newcase; defaults_adapter; printf '\033[2J\033[31m{"publish":"%s"}\n[live] The site is live\a\n' "$other" > "$S/live_body"
dpub; t="a live site answering with control characters and a line of its own"
check "$t: failed, saying its offprint.json names no publish" "1|$(short) is pushed, but the live site hasn't shown it after 1 seconds (its offprint.json names no publish)" "$code|$(js message)"
check "$t: none of what it answered is in the log" "no|no" \
  "$(grep -q "$(printf '\033')" "$c/var/publish.log" && echo yes || echo no)|$(grep -qF '[live] The site is live' "$c/var/publish.log" && echo yes || echo no)"
# The host's limits count offprint.json, which the publish writes after the checks: what the publish's checks pass is
# what offprint check passes on the site/ it publishes, warnings too. limited CODE: the case's adapter d with CODE (its
# limits; it keeps the default confirm), committed. oc_site: offprint check on the site's own site/ (sets out, code).
# verdict: the publish's (its message), and oc_site's after it, on one line each.
limited() { mkdir -p "$c/adapters/d"; printf '%s\n' "$1" > "$c/adapters/d/adapter.sh"; site_json d; commit "limits: $1"; }
oc_site() { out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" check "$c/site" 2>&1)"; code=$?; }
newcase; limited 'ADAPTER_MAX_FILES=5'; dpub --no-push; t="4 files exported and offprint.json, a limit of 5 files"
check "$t: the publish works" "0|Committed, not pushed (--no-push)." "$code|$(js message)"
check "$t: 5 files in site/, offprint.json one of them" "5|yes" "$(git -C "$c" ls-tree -r --name-only HEAD -- site | wc -l | tr -d ' ')|$(exists "$c/site/offprint.json")"
check "$t: the warning counts 5" '["warning: the site has 5 files, over 80% of the 5 limit"]' "$(js warnings)"
oc_site; check "$t: offprint check on site/ agrees, warning too" "0|warning: the site has 5 files, over 80% of the 5 limit" "$code|$out"
limited 'ADAPTER_MAX_FILES=4'; oc_site; t="the same export, a limit of 4 files"
check "$t: offprint check on site/ refuses it" "1|too many files: 5, the limit is 4" "$code|$out"
dpub --no-push; check "$t: and so does the publish" "1|The export failed the checks, nothing was published: too many files: 5, the limit is 4" "$code|$(js message)"; nocommit "$t"
limited 'ADAPTER_MAX_FILES=6'; dpub --no-push; t="the same export, a limit of 6 files (5 are 80% of it)"
check "$t: the publish works, with the warning" '0|["warning: the site has 5 files, over 80% of the 6 limit"]' "$code|$(js warnings)"
oc_site; check "$t: offprint check agrees" "0|warning: the site has 5 files, over 80% of the 6 limit" "$code|$out"
limited 'ADAPTER_MAX_FILES=7'; dpub --no-push; t="the same export, a limit of 7 files (5 are under 80% of it)"
check "$t: the publish works, without a warning" "0|[]" "$code|$(js warnings)"; oc_site; check "$t: offprint check agrees" "0|" "$code|$out"
# For one file: offprint.json (55 bytes) is the largest here (the feed is <rss/>).
newcase; echo '<rss/>' > "$S/fixture/feed/index.xml"; limited 'ADAPTER_MAX_FILE_BYTES=55'; dpub --no-push; t="offprint.json at a limit of 55 bytes for one file"
check "$t: the publish works, with the warning" '0|["warning: offprint.json is 55 bytes, over 80% of the 55 limit for one file"]' "$code|$(js warnings)"
oc_site; check "$t: offprint check agrees" "0|warning: offprint.json is 55 bytes, over 80% of the 55 limit for one file" "$code|$out"
limited 'ADAPTER_MAX_FILE_BYTES=54'; oc_site; t="the same export, a limit of 54 bytes for one file"
check "$t: offprint check on site/ refuses it" "1|offprint.json is 55 bytes, the limit for one file is 54" "$code|$out"
dpub --no-push; check "$t: and so does the publish" "1|The export failed the checks, nothing was published: offprint.json is 55 bytes, the limit for one file is 54" "$code|$(js message)"
limited 'ADAPTER_MAX_FILE_BYTES=69'; dpub --no-push; t="the same export, a limit of 69 bytes for one file (55 is under 80% of it)"
check "$t: the publish works, without a warning" "0|[]" "$code|$(js warnings)"; oc_site; check "$t: offprint check agrees" "0|" "$code|$out"
# The total (the compressed archive). Its size turns on every byte the archive holds, files' times too: each publish
# makes site/ afresh, so the same content measures a few bytes more or less each time, and the publish counts
# offprint.json as a stand-in of its size, which comes within about 100 bytes of the file written (see bin/check-site).
# So no case here sits near that: the limits are 512 over the size site/ has with offprint.json (both pass) and half
# the size it has without (both refuse), and the publish's measure is offprint check's within 256 bytes. (That the
# total counts the file to come at all is shown in tests/check-site.test.sh; the count of files and each file's size,
# above, are exact.) The export holds a random file of 6000 characters: about 4800 bytes compressed, far from the edge
# of a 10240-byte record (where tar writes those, every measure here is one record).
newcase; head -c 6000 /dev/urandom | base64 | tr -d '\n' | head -c 6000 > "$S/fixture/r.txt"; limited '# no limits'; dpub --no-push
final="$(tar -czf - -C "$c/site" . | wc -c | tr -d ' ')"
cp -Rp "$c/site" "$tmp/case$n/bare"; rm "$tmp/case$n/bare/offprint.json"; touch -r "$c/site" "$tmp/case$n/bare"
bare="$(tar -czf - -C "$tmp/case$n/bare" . | wc -c | tr -d ' ')"
limited "ADAPTER_MAX_TOTAL_BYTES=$((final + 512))"; dpub --no-push; t="a total limit 512 bytes over the size site/ has with offprint.json"
check "$t: the publish works, well under" "0|unchanged" "$code|$(js state)"; oc_site; check "$t: offprint check agrees" 0 "$code"
limited "ADAPTER_MAX_TOTAL_BYTES=$((bare / 2))"; t="a total limit of half the size site/ has without offprint.json"
dpub --no-push; check "$t: the publish refuses it, well over" "1|The export failed the checks, nothing was published: too big: " "$code|$(js message | cut -c1-62)"
published="$(js message | sed -n 's/.*too big: \([0-9]*\) bytes.*/\1/p')"
oc_site; check "$t: and so does offprint check" "1|too big: " "$code|$(printf "%s" "$out" | cut -c1-9)"
checked="$(printf '%s' "$out" | sed -n 's/^too big: \([0-9]*\) bytes.*/\1/p')"; d=$((published - checked)); [ "$d" -ge 0 ] || d=$((0 - d))
if [ -n "$published" ] && [ -n "$checked" ] && [ "$d" -le 256 ]; then ok "$t: the publish's measure (offprint.json to come) is offprint check's on site/ within 256 bytes"
else bad "$t: the publish's measure '$published', offprint check's '$checked'"; fi
# An adapter with a confirm of its own writes no offprint.json: its limits count the export's files alone, as before.
newcase; mkdir -p "$c/adapters/o"; printf 'ADAPTER_MAX_FILES=4\nadapter_confirm() { return 0; }\n' > "$c/adapters/o/adapter.sh"; site_json o; commit "own confirm, 4 files"
pub --no-push; t="an adapter with a confirm of its own, 4 files, a limit of 4"
check "$t: the publish works, 4 files, warning of 4" '0|4|no|["warning: the site has 4 files, over 80% of the 4 limit"]' \
  "$code|$(git -C "$c" ls-tree -r --name-only HEAD -- site | wc -l | tr -d ' ')|$(exists "$c/site/offprint.json")|$(js warnings)"
oc_site; check "$t: offprint check agrees" "0|warning: the site has 4 files, over 80% of the 4 limit" "$code|$out"
printf 'ADAPTER_MAX_FILES=3\nadapter_confirm() { return 0; }\n' > "$c/adapters/o/adapter.sh"; commit "a limit of 3"; pub --no-push; t="the same, a limit of 3"
check "$t: the publish refuses it" "1|The export failed the checks, nothing was published: too many files: 4, the limit is 3" "$code|$(js message)"
oc_site; check "$t: and so does offprint check" "1|too many files: 4, the limit is 3" "$code|$out"

# === limits: enforced by bin/check-site, a warning from 80% ===
# limits CODE: an adapter l with CODE (its limits), and an export with a 1000-byte file in it (five files in all).
limits() {
  newcase; adapter l < <(printf 'adapter_confirm() { return 0; }\n%s\n' "$1")
  printf '%01000d' 0 > "$S/fixture/big.bin"
}
lim_fails() {  # T TEXT: the publish failed the checks with TEXT, nothing committed
  check "$1: fails" "1|failed" "$code|$(js state)"; valid "$1"
  check "$1: naming it" "The export failed the checks, nothing was published: $2" "$(js message)"; nocommit "$1"; oldsite "$1"
}
lim_warns() {  # T TEXT: the publish worked, with the warning TEXT in its status
  check "$1: the publish works" 0 "$code"; contains "$1: with a warning in the status" "$2" "$(js warnings)"
}
limits 'ADAPTER_MAX_FILE_BYTES=900'; pub --no-push; lim_fails "a file over ADAPTER_MAX_FILE_BYTES" "big.bin is 1000 bytes, the limit for one file is 900"
limits 'ADAPTER_MAX_FILE_BYTES=1100'; pub --no-push; lim_warns "a file over 80% of ADAPTER_MAX_FILE_BYTES" "warning: big.bin is 1000 bytes, over 80% of the 1100 limit for one file"
limits 'ADAPTER_MAX_FILES=4'; pub --no-push; lim_fails "more files than ADAPTER_MAX_FILES" "too many files: 5, the limit is 4"
limits 'ADAPTER_MAX_FILES=6'; pub --no-push; lim_warns "files over 80% of ADAPTER_MAX_FILES" "warning: the site has 5 files, over 80% of the 6 limit"
limits 'ADAPTER_MAX_TOTAL_BYTES=10'; pub --no-push; t="a site over ADAPTER_MAX_TOTAL_BYTES"
check "$t: fails" failed "$(js state)"; contains "$t: naming it" "The export failed the checks, nothing was published: too big: " "$(js message)"
contains "$t: and the limit" "bytes compressed, the limit is 10" "$(js message)"; nocommit "$t"
# about 90% of the limit (the copy packs to a few bytes more or less than the fixture: see tests/publish.test.sh)
limits 'ADAPTER_MAX_TOTAL_BYTES=0'; size="$(tar -czf - -C "$S/fixture" . | wc -c | tr -d ' ')"
printf 'adapter_confirm() { return 0; }\nADAPTER_MAX_TOTAL_BYTES=%s\n' "$((size * 10 / 9))" > "$c/adapters/l/adapter.sh"; commit "total limit"
pub --no-push; lim_warns "a site over 80% of ADAPTER_MAX_TOTAL_BYTES" "over 80% of the $((size * 10 / 9)) limit"
limits '# no limits'; pub --no-push; t="no limits (each 0)"
check "$t: the publish works" 0 "$code"; check "$t: without a warning" "[]" "$(js warnings)"

# === adapters/none: commit and push, no host; the publish ends "saved" ===
newcase; echo '{"commit":"x"}' > "$S/fixture/build.json"; echo '{"publish":"x"}' > "$S/fixture/offprint.json"; pub; t="the adapter none (no adapter block in site.json)"
sha="$(git -C "$c" rev-parse HEAD)"
check "$t: exits 0" 0 "$code"; check "$t: saved" saved "$(js state)"; valid "$t"
check "$t: the message" "Committed and pushed ${sha:0:7}; this site has no host set up (site.json \"adapter\")." "$(js message)"
check "$t: the status names the commit" "$sha" "$(js commit)"
check "$t: pushed" "$sha" "$(git -C "$O" rev-parse main)"
check "$t: it reserves no names (build.json and offprint.json are the export's own here)" "site/build.json site/offprint.json" \
  "$(git -C "$c" ls-tree --name-only HEAD -- site/build.json site/offprint.json | tr '\n' ' ' | sed 's/ $//')"
check "$t: no network" no "$(exists "$S/curl.calls")"
lacks "$t: no wait for a host" "[deploying]" "$out"
# (Not "unchanged", which the admin bar shows as Live: a site with no host has no live site.)
pub; t="the adapter none, a second publish with nothing new"
check "$t: saved" "0|saved" "$code|$(js state)"; valid "$t"
check "$t: the message" "Nothing has changed since the last publish; this site has no host set up (site.json \"adapter\")." "$(js message)"
check "$t: the status names the commit" "$sha" "$(js commit)"
check "$t: nothing new pushed" "$sha" "$(git -C "$O" rev-parse main)"
check "$t: no network" no "$(exists "$S/curl.calls")"

# === a name the disk takes for a reserved one, and links: refused before the adapter writes anything ===
# fold_adapter: an adapter f with a file of its own (and offprint.json: it keeps the default confirm) and a host file
# with a k in it; its prepare notes that it ran.
fold_adapter() {
  adapter f <<'A'
ADAPTER_PREPARE_FILES="_headers"
ADAPTER_HOST_FILES="build.json _worker.js"
adapter_prepare() { touch "$STUB_DIR/prepared"; printf 'from the adapter\n' > "$1/_headers"; }
A
}
# A disk that ignores case (the Mac's) folds it in Unicode, which find -iname doesn't: a long s (U+017F) is an s, the ff
# ligature (U+FB00) is ff, the Kelvin sign (U+212A) is a k. folds VARIANT NAME: this disk's own lookup of NAME reaches a
# file called VARIANT.
LONG_S="$(printf '\305\277')"; FF="$(printf '\357\254\200')"; KELVIN="$(printf '\342\204\252')"
folds() { local d r; d="$(mktemp -d "$tmp/fold.XXXXXX")"; : > "$d/$1"; [ -e "$d/$2" ]; r=$?; rm -f "$d/$1"; rmdir "$d"; return "$r"; }
for spec in "_header$LONG_S|_headers|the publish writes _headers" "o${FF}print.json|offprint.json|the publish writes offprint.json" \
    "_wor${KELVIN}er.js|_worker.js|the deploy writes _worker.js"; do
  v="${spec%%|*}"; rest="${spec#*|}"; name="${rest%%|*}"; who="${rest#*|}"
  if ! folds "$v" "$name"; then echo "skip  $v taken for $name (this disk doesn't fold it)"; continue; fi
  newcase; fold_adapter; echo planted > "$S/fixture/$v"; pub --no-push; t="$v at the root of the export (this disk takes it for $name)"
  check "$t: refused" "1|failed" "$code|$(js state)"; valid "$t"
  check "$t: naming it" "The export failed the checks, nothing was published: $who at the root, so the export can't have one: ./$v" "$(js message)"
  check "$t: before the adapter wrote anything" no "$(exists "$S/prepared")"; nocommit "$t"; oldsite "$t"
  newcase; fold_adapter; echo outside > "$tmp/case$n/outside.txt"; ln -s "$tmp/case$n/outside.txt" "$S/fixture/$v"
  pub --no-push; t="$v, a symlink out of the site folder"
  check "$t: refused" "1|failed" "$code|$(js state)"
  check "$t: as a symlink" "The export has a symlink, so nothing was published: var/export/$v" "$(js message)"
  check "$t: before the adapter wrote anything" no "$(exists "$S/prepared")"
  check "$t: the file outside is untouched" outside "$(cat "$tmp/case$n/outside.txt")"; nocommit "$t"
  newcase; fold_adapter; mkdir "$S/fixture/$v"; echo x > "$S/fixture/$v/x"; pub --no-push; t="$v, a folder"
  check "$t: refused" "1|failed" "$code|$(js state)"
  check "$t: naming it" "The export failed the checks, nothing was published: $who at the root, so the export can't have one: ./$v" "$(js message)"
  check "$t: before the adapter wrote anything" no "$(exists "$S/prepared")"; nocommit "$t"
done
# On any disk: a link in the export is refused before the adapter writes into the copy, at the root or deeper.
newcase; fold_adapter; echo outside > "$tmp/case$n/outside.txt"; ln -s "$tmp/case$n/outside.txt" "$S/fixture/_headers"
pub --no-push; t="_headers in the export, a symlink out of the site folder"
check "$t: refused as a symlink" "1|The export has a symlink, so nothing was published: var/export/_headers" "$code|$(js message)"
check "$t: before the adapter wrote anything" no "$(exists "$S/prepared")"
check "$t: the file outside is untouched" outside "$(cat "$tmp/case$n/outside.txt")"; nocommit "$t"; oldsite "$t"
newcase; fold_adapter; ln -s ../index.html "$S/fixture/hello/link.html"; pub --no-push; t="a symlink deeper in the export"
check "$t: refused as a symlink" "1|The export has a symlink, so nothing was published: var/export/hello/link.html" "$code|$(js message)"
check "$t: before the adapter wrote anything" no "$(exists "$S/prepared")"; nocommit "$t"
# The adapter's own files must then be there: at the root, plain files, by exactly the names it declared.
for how in ':' 'printf x > "$1/_Headers"' 'ln -s /etc/hosts "$1/_headers"' 'mkdir "$1/_headers"'; do
  newcase; adapter w < <(printf 'ADAPTER_PREPARE_FILES="_headers"\nadapter_confirm() { return 0; }\nadapter_prepare() { %s; }\n' "$how")
  pub --no-push; t="an adapter that declares _headers, and whose prepare does: $how"
  check "$t: fails" "1|failed" "$code|$(js state)"; valid "$t"
  check "$t: saying so" "The adapter was to write _headers at the root of the export, as a plain file, and didn't; nothing was published." "$(js message)"
  nocommit "$t"; oldsite "$t"
done

# === a site adapter's whole folder is the owner's committed code; a tool adapter's holds no links ===
# helper_adapter: adapters/x/adapter.sh sources its helper.sh from its own folder (as an adapter may: data files and
# helpers live beside adapter.sh), committed with site.json naming it. helper.sh itself is the case's.
helper_adapter() {
  mkdir -p "$c/adapters/x"
  printf '. "$OFFPRINT_ADAPTER_DIR/helper.sh"\nadapter_confirm() { return 0; }\n' > "$c/adapters/x/adapter.sh"
  site_json x
}
planted_helper() { printf 'touch "%s/sourced"\nadapter_prepare() { touch "%s/sourced"; }\n' "$S" "$S"; }
newcase; helper_adapter; echo '/adapters/x/helper.sh' >> "$c/.gitignore"; commit "an adapter, its helper ignored"; planted_helper > "$c/adapters/x/helper.sh"
pub --no-push; t="a helper beside adapter.sh that the .gitignore hides, never committed"
refused "$t" "$(said x)adapters/x/helper.sh is a file git ignores; an adapter's folder is committed whole, so commit it (git add -f) or remove it."
check "$t: never sourced" no "$(exists "$S/sourced")"
newcase; helper_adapter; planted_helper > "$c/wp-content/helper.sh"; ln -s ../../wp-content/helper.sh "$c/adapters/x/helper.sh"; commit "helper.sh, a link into wp-content"
pub --no-push; t="a helper that is a committed symlink into wp-content/"
refused "$t" "$(said x)adapters/x/helper.sh is a symlink; nothing in an adapter's folder may be a link."
check "$t: what WordPress wrote is never sourced" no "$(exists "$S/sourced")"
newcase; helper_adapter; echo ': helper' > "$c/adapters/x/helper.sh"; mkdir -p "$c/adapters/x/lib"; ln -s ../adapter.sh "$c/adapters/x/lib/again.sh"; commit "a link deeper in"
pub --no-push; refused "a symlink in a folder inside the adapter's" "$(said x)adapters/x/lib/again.sh is a symlink; nothing in an adapter's folder may be a link."
newcase; helper_adapter; echo ': helper' > "$c/adapters/x/helper.sh"; commit "an adapter with a helper"
mkdir -p "$c/adapters/x/lib"; echo ': new' > "$c/adapters/x/lib/new.sh"
pub --no-push; refused "an untracked file in a folder inside the adapter's" "$(uncommitted adapters/x/lib/new.sh)"
rm -r "$c/adapters/x/lib"; echo ': helper, edited' > "$c/adapters/x/helper.sh"; git -C "$c" add adapters/x/helper.sh
pub --no-push; refused "the helper edited and staged" "$(uncommitted adapters/x/helper.sh)"
git -C "$c" reset -q -- adapters/x/helper.sh; git -C "$c" checkout -q -- adapters/x/helper.sh
pub --no-push; check "control: the same adapter, as committed, works" "0|Committed, not pushed (--no-push)." "$code|$(js message)"
# A file changed on disk while git's own record of it (size, time) says it isn't: still refused, byte for byte.
for f in helper.sh adapter.sh; do
  newcase; helper_adapter; echo ': helper' > "$c/adapters/x/helper.sh"; touch -t 202001010000 "$c/adapters/x/helper.sh" "$c/adapters/x/adapter.sh"
  commit "an adapter, files dated 2020"; git -C "$c" config core.trustctime false; git -C "$c" config core.checkStat minimal
  size="$(wc -c < "$c/adapters/x/$f" | tr -d ' ')"; printf '%*s' "$size" '' | tr ' ' '#' > "$c/adapters/x/$f"; touch -t 202001010000 "$c/adapters/x/$f"
  t="$f changed on disk, same size and time"
  check "control: $t: git status doesn't see it" "" "$(git -C "$c" status --porcelain -- adapters/x)"
  pub --no-push; refused "$t" "$(uncommitted "adapters/x/$f")"
done
# A file with a second name (a hard link) in wp-content/, which WordPress can write: it could change after the check.
newcase; helper_adapter; echo ': helper' > "$c/wp-content/helper.sh"; ln "$c/wp-content/helper.sh" "$c/adapters/x/helper.sh"; commit "a helper hard-linked to wp-content"
pub --no-push; refused "a helper with a hard link into wp-content/" "$(said x)adapters/x/helper.sh has another name on disk (a hard link), so something else could change it; each file in an adapter's folder must be its own."
# The tool's own adapter: no link anywhere in its folder either (a copy of the tool, for this case).
newcase; tool="$tmp/case$n/tool"; mkdir -p "$tool"; cp -R "$SRC/bin" "$SRC/lib" "$SRC/adapters" "$SRC/templates" "$tool/"
ln -s /etc/hosts "$tool/adapters/none/hosts"
out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$tmp/load.sh" "$tool" 2>&1)"; t="a symlink in a tool adapter's folder"
check "$t: refused (2)" "rc=2" "$(printf '%s\n' "$out" | head -n 1)"
contains "$t: naming it" "site.json: \"adapter.name\" is none, and Offprint's adapters/none/hosts is a symlink; nothing in an adapter's folder may be a link." "$out"

# === adapter code can't reach the publish's own shell ===
# A trap set by adapter.sh as it is loaded: the publish's own cleanup still runs (lock released, private copy removed).
newcase; adapter tr <<'A'
trap 'echo "the adapter trap ran" >> "$STUB_DIR/trap.log"' EXIT
trap 'echo "the adapter took TERM"' TERM
adapter_confirm() { return 0; }
A
echo '<a href="/wp-admin/">x</a>' > "$S/fixture/index.html"; pub --no-push; t="an adapter.sh that sets an EXIT trap, and a publish that fails the checks"
check "$t: failed, exit 1" "1|failed" "$code|$(js state)"; valid "$t"; contains "$t: for the checks" "wp-admin" "$(js message)"
check "$t: the lock is released" no "$(exists "$c/var/publish.lock")"; check "$t: the private copy is removed" no "$(exists "$c/site.new")"
echo '<html><body>New home</body></html>' > "$S/fixture/index.html"; pub; t="the same adapter, a publish that works"
check "$t: live, exit 0" "0|live" "$code|$(js state)"; check "$t: the lock is released" no "$(exists "$c/var/publish.lock")"
# A contract variable declared (not just set) at adapter.sh's top level is honoured: never dropped.
for decl in 'declare -i ADAPTER_MAX_FILES=2' 'typeset ADAPTER_MAX_FILES=2' 'local ADAPTER_MAX_FILES=2' 'readonly ADAPTER_MAX_FILES=2'; do
  newcase; adapter dl < <(printf '%s\nadapter_confirm() { return 0; }\n' "$decl"); pub --no-push; t="adapter.sh: $decl, and an export of four files"
  check "$t: the limit holds" "1|The export failed the checks, nothing was published: too many files: 4, the limit is 2" "$code|$(js message)"
done
# What adapter.sh sets at its top level, other than ADAPTER_ variables and
# adapter_ functions, doesn't reach the publish.
newcase; adapter cl <<'A'
LOG=/dev/null; POLL=99; push=0; TIMEOUT=0; SITE=/nowhere; FINAL=1
fail() { echo "the adapter's fail"; }
cd /
adapter_confirm() { return 0; }
A
start=$SECONDS; pub; t="an adapter.sh that sets the publish's own variables and functions at its top level"
check "$t: the publish works, and pushes" "0|live" "$code|$(js state)"; check "$t: pushed" "$(git -C "$c" rev-parse HEAD)" "$(git -C "$O" rev-parse main)"
contains "$t: its log is written" "publish started" "$(cat "$c/var/publish.log")"; check "$t: soon" yes "$([ $((SECONDS - start)) -lt 20 ] && echo yes || echo no)"
# Each adapter function runs in a shell of its own: an exit there is that step's failure, never the publish's own exit.
newcase; adapter ex <<'A'
adapter_deploy() { ADAPTER_PROBLEM="never seen"; exit 0; }
adapter_confirm() { return 0; }
A
pub; t="adapter_deploy calls exit 0"
check "$t: the publish fails, exit 1" "1|failed" "$code|$(js state)"; valid "$t"
check "$t: saying how" "$(short) is pushed, but the deploy failed: adapter_deploy ended without returning (an exit, or an error); see var/publish.log" "$(js message)"
check "$t: the lock is released" no "$(exists "$c/var/publish.lock")"
newcase; adapter ex <<'A'
adapter_prepare() { exit 0; }
adapter_confirm() { return 0; }
A
pub --no-push; t="adapter_prepare calls exit 0"
check "$t: fails, exit 1" "1|The adapter couldn't prepare the export (see var/publish.log); nothing was published." "$code|$(js message)"
check "$t: the private copy is removed" no "$(exists "$c/site.new")"; nocommit "$t"
newcase; adapter ex <<'A'
adapter_validate() { exit 0; }
adapter_confirm() { return 0; }
A
pub --no-push; t="adapter_validate calls exit 0"
check "$t: fails, exit 1" "1|The adapter's settings couldn't be checked: its adapter_validate ended without returning (an exit, or an error); see var/publish.log. Nothing was published." "$code|$(js message)"
no_docker "$t"
newcase; adapter ex <<'A'
ADAPTER_CONFIRM_SECONDS=1
adapter_confirm() { exit 0; }
A
pub; t="adapter_confirm calls exit 0"
check "$t: never live" "1|$(short) is pushed, but the live site hasn't shown it after 1 seconds (it couldn't be reached)" "$code|$(js message)"
# cd, a trap and the publish's own variables, set inside the adapter's functions: none reaches the publish.
newcase; adapter cdx <<'A'
ADAPTER_PREPARE_FILES="_headers"
adapter_prepare() { trap 'echo trapped' EXIT; cd "$1" || return 1; printf '/*\n  X-Test: 1\n' > _headers; COMMIT=0000000; LOG=/dev/null; }
adapter_deploy() { cd /; COMMIT=0000000; POLL=99; end=0; push=0; ADAPTER_PROBLEM=""; }
adapter_confirm() { echo "$2" >> "$STUB_DIR/confirm.calls"; cd /; return 0; }
A
start=$SECONDS; pub; t="adapter functions that cd, set a trap and set the publish's own variables"
check "$t: live" "0|live" "$code|$(js state)"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the adapter's file is published" yes "$(git -C "$c" cat-file -e HEAD:site/_headers 2>/dev/null && echo yes || echo no)"
check "$t: the confirm was given the real commit" "$sha" "$(cat "$S/confirm.calls" 2>&1)"; check "$t: the message names it" "The site is live at ${sha:0:7}" "$(js message)"
check "$t: the private copy is removed" no "$(exists "$c/site.new")"; check "$t: the lock is released" no "$(exists "$c/var/publish.lock")"
check "$t: soon" yes "$([ $((SECONDS - start)) -lt 20 ] && echo yes || echo no)"

# === offprint check: the site's adapter's names and limits, as the publish passes them ===
oc() { out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" check "$1" 2>&1)"; code=$?; }
newcase; adapter k <<'A'
ADAPTER_PREPARE_FILES="_headers"
ADAPTER_HOST_FILES="build.json"
ADAPTER_MAX_FILES=10
adapter_confirm() { return 0; }
A
cp -R "$S/fixture" "$tmp/case$n/out"; oc out; t="offprint check, for a site whose adapter names files and a limit"
check "$t: a clean export passes" "0|" "$code|$out"
echo x > "$tmp/case$n/out/_headers"; oc out; check "$t: the adapter's own file is refused" "1|the publish writes _headers at the root, so the export can't have one: ./_headers" "$code|$out"
rm "$tmp/case$n/out/_headers"; echo '{}' > "$tmp/case$n/out/Build.json"; oc out
check "$t: and its host's" "1|the publish writes build.json at the root, so the export can't have one: ./Build.json" "$code|$out"
rm "$tmp/case$n/out/Build.json"; for i in 1 2 3 4 5 6 7; do echo "$i" > "$tmp/case$n/out/$i.txt"; done; oc out
check "$t: and its limit" "1|too many files: 11, the limit is 10" "$code|$out"
cp -R "$S/fixture/." "$c/site/"; echo h > "$c/site/_headers"; oc "$c/site"
check "$t: in the site's own site/, the adapter's file is the publish's: allowed" "0|" "$code|$out"
rm "$c/site/_headers"; echo '{}' > "$c/site/build.json"; oc "$c/site"
check "$t: but not its host's" "1|the publish writes build.json at the root, so the export can't have one: ./build.json" "$code|$out"
mkdir -p "$tmp/case$n/tmpdir"; TMPDIR="$tmp/case$n/tmpdir" oc out
check "$t: nothing left in TMPDIR (the adapter's private folder goes before the check runs)" "1|" "$code|$(ls -A "$tmp/case$n/tmpdir")"
# What only the publish gives bin/check-site, the file it still writes after its check (CHECK_SITE_TO_COME) and that
# file's size, is never taken from the environment of whoever runs offprint check.
rm -rf "$tmp/case$n/out"; cp -R "$S/fixture" "$tmp/case$n/out"; for i in 1 2 3 4 5 6; do echo "$i" > "$tmp/case$n/out/$i.txt"; done
oc out; t="offprint check, 10 files and a limit of 10"
check "$t: passes, with the warning" "0|warning: the site has 10 files, over 80% of the 10 limit" "$code|$out"
CHECK_SITE_TO_COME=_headers CHECK_SITE_TO_COME_BYTES=1048576 oc out
check "$t: the same with CHECK_SITE_TO_COME and its size in the caller's environment" "0|warning: the site has 10 files, over 80% of the 10 limit" "$code|$out"
CHECK_SITE_TO_COME=_headers CHECK_SITE_TO_COME_BYTES=1 oc "$c/site"
check "offprint check on site/, CHECK_SITE_TO_COME in the caller's environment: as without it" \
  "1|the publish writes build.json at the root, so the export can't have one: ./build.json" "$code|$out"
# A TERM while the adapter is being loaded (its top level stuck, ignoring TERM, in a child): offprint check stops the
# load as every command does (offprint_adapter_stop: a TERM, then it and everything under it killed), leaving nothing.
newcase; mkdir -p "$tmp/case$n/tmpdir" "$tmp/case$n/empty"; adapter stuck <<'A'
if [ -e "$STUB_DIR/hang" ]; then trap '' TERM; sleep 4417 & echo "$!" > "$STUB_DIR/child.pid"; wait; fi
adapter_confirm() { return 0; }
A
touch "$S/hang"
( cd "$tmp/case$n" && STUB_DIR="$S" OFFPRINT_SITE="$c" TMPDIR="$tmp/case$n/tmpdir" exec /bin/bash "$SRC/bin/offprint" check empty > "$S/oc.out" 2>&1 ) &
pid=$!
i=0; while [ ! -s "$S/child.pid" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
lp="$(ps -o ppid= -p "$(cat "$S/child.pid" 2>/dev/null)" 2>/dev/null | tr -d ' ')"; echo "$lp" > "$S/load.pid"   # the load's shell
check "control: offprint check's load is stuck (its shell, under offprint check, has started a child)" yes \
  "$([ -n "$lp" ] && [ "$(ps -o ppid= -p "$lp" 2>/dev/null | tr -d ' ')" = "$pid" ] && echo yes || echo no)"
kill -TERM "$pid"; i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
t="offprint check, a TERM while its adapter's top level is stuck"
if kill -0 "$pid" 2>/dev/null; then bad "$t: it stopped within 20 seconds"; kill -KILL "$pid" 2>/dev/null; else ok "$t: it stopped within 20 seconds"; fi
code=0; wait "$pid" 2>/dev/null || code=$?
check "$t: exit 143" 143 "$code"
# (Both ignore TERM: anything left is killed here, so the suite leaves nothing running.)
sleep 0.5; left=""; for f in load.pid child.pid; do p="$(cat "$S/$f" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && left="$left $f" && kill -KILL "$p"; done
check "$t: the stuck load is stopped, with what it started" "" "$left"
check "$t: nothing left in TMPDIR" "" "$(ls -A "$tmp/case$n/tmpdir")"
newcase; cp -R "$S/fixture" "$tmp/case$n/out"; echo '{}' > "$tmp/case$n/out/build.json"; oc out
check "offprint check, the adapter none: nothing reserved, no limit" "0|" "$code|$out"
newcase; site_json nosuch; commit "names an adapter nobody has"; mkdir "$tmp/case$n/empty"; oc empty; t="offprint check, an adapter that can't be used"
check "$t: refused, exit 2" 2 "$code"; contains "$t: saying why" "$(said nosuch)there is no adapter of that name" "$out"
lacks "$t: bin/check-site never ran" "missing:" "$out"

# === a site adapter of several files: adapter.sh is what is loaded, and all of it is used, through a full publish ===
# multi_adapter: adapters/m holds a-helper.sh (sorting before adapter.sh), adapter.sh, data.json (not shell),
# lib/util.sh and zz.sh (sorting after it, and never sourced): adapter.sh sources the two helpers and reads data.json,
# and has its own files, limits and every function, each of which notes that it ran.
multi_adapter() {
  mkdir -p "$c/adapters/m/lib"
  cat > "$c/adapters/m/adapter.sh" <<'A'
. "$OFFPRINT_ADAPTER_DIR/a-helper.sh"
. "$OFFPRINT_ADAPTER_DIR/lib/util.sh"
ADAPTER_PREPARE_FILES="_headers"
ADAPTER_HOST_FILES="_worker.js"
ADAPTER_MAX_FILES=6
ADAPTER_CONFIRM_SECONDS=1
adapter_validate() { adapter_note validate; }
adapter_prepare() { adapter_note prepare; adapter_util_line > "$1/_headers"; }
adapter_deploy() { adapter_note "deploy $1"; }
adapter_confirm() { adapter_note confirm; [ ! -f "$STUB_DIR/behind" ] || { ADAPTER_WHY="it shows another"; return 1; }; }
adapter_failure_hint() { printf '; %s' "$(sed -n 's/.*"hint": *"\([^"]*\)".*/\1/p' "$OFFPRINT_ADAPTER_DIR/data.json")"; }
A
  printf 'adapter_note() { echo "$1" >> "$STUB_DIR/calls"; }\n' > "$c/adapters/m/a-helper.sh"
  printf 'adapter_util_line() { echo "/*  X-From: util"; }\n' > "$c/adapters/m/lib/util.sh"
  printf '{"hint": "ask the multi host"}\n' > "$c/adapters/m/data.json"
  printf 'echo "zz.sh ran" >> "$STUB_DIR/zz"\nADAPTER_HOST_FILES=\nADAPTER_MAX_FILES=0\n' > "$c/adapters/m/zz.sh"
  site_json m; commit "a site adapter of several files"
}
newcase; multi_adapter; pub; t="a site adapter of several files, a full publish"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: live" "0|live" "$code|$(js state)"
check "$t: each of its functions ran, in order" "validate|prepare|deploy $sha|confirm" "$(paste -sd'|' - < "$S/calls" 2>&1)"
check "$t: its helpers made its file" "/*  X-From: util" "$(git -C "$c" show HEAD:site/_headers 2>&1)"
check "$t: the file sorting after adapter.sh never ran" no "$(exists "$S/zz")"
echo '<p>more</p>' > "$S/fixture/hello/index.html"; touch "$S/behind"; pub; t="the same adapter, the live site behind"
check "$t: its hint, read from its data file" "1|$(short) is pushed, but the live site hasn't shown it after 1 seconds (it shows another); ask the multi host" "$code|$(js message)"
newcase; multi_adapter; echo planted > "$S/fixture/_worker.js"; pub --no-push; t="the same adapter, _worker.js (its host's file) in the export"
check "$t: refused" "1|The export failed the checks, nothing was published: the deploy writes _worker.js at the root, so the export can't have one: ./_worker.js" "$code|$(js message)"
check "$t: never committed" "" "$(git -C "$c" ls-tree --name-only HEAD -- site/_worker.js)"
newcase; multi_adapter; echo a > "$S/fixture/a.txt"; echo b > "$S/fixture/b.txt"; pub --no-push; t="the same adapter, seven files"
check "$t: its limit holds" "1|The export failed the checks, nothing was published: too many files: 7, the limit is 6" "$code|$(js message)"
# The reviewer's case: one helper beside adapter.sh, and the host's file planted in the export.
newcase; mkdir -p "$c/adapters/w"; printf 'ADAPTER_HOST_FILES="_worker.js"\nadapter_confirm() { return 0; }\n' > "$c/adapters/w/adapter.sh"
echo ': one line' > "$c/adapters/w/helper.sh"; site_json w; commit "an adapter with a helper"; echo planted > "$S/fixture/_worker.js"
pub --no-push; t="an adapter naming _worker.js as its host's, with a helper.sh beside it, and _worker.js in the export"
check "$t: refused" "1|failed" "$code|$(js state)"; check "$t: never committed" "" "$(git -C "$c" ls-tree --name-only HEAD -- site/_worker.js)"

# === adapter functions written any way bash allows: each call sources adapter.sh itself, no function is re-printed ===
newcase; adapter hd <<'A'
ADAPTER_PREPARE_FILES="_headers"
adapter_aaa_text() {
  cat <<EOT | tr a-z A-Z
x-from: a here-doc
EOT
}
adapter_prepare() {
  local where="$1"
  { printf '/*\n  '; adapter_aaa_text; } > "$where/_headers"
  cat > "$STUB_DIR/prepare.txt" <<EOT && echo "after the here-doc" >> "$STUB_DIR/prepare.txt"
prepared
EOT
}
adapter_deploy() {
  cat <<EOT || return 1
deploying $1
EOT
  echo "$1" > "$STUB_DIR/deployed"
}
adapter_confirm() { echo "$2" >> "$STUB_DIR/confirm.calls"; }
A
pub; t="adapter functions with here-docs (piped, then &&, then ||), local, and one defined after a here-doc"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: live" "0|live" "$code|$(js state)"
check "$t: the piped here-doc" "$(printf '/*\n  X-FROM: A HERE-DOC')" "$(git -C "$c" show HEAD:site/_headers 2>&1)"
check "$t: the here-doc, then &&" "$(printf 'prepared\nafter the here-doc')" "$(cat "$S/prepare.txt" 2>&1)"
check "$t: the function defined after them" "$sha|$sha" "$(cat "$S/deployed" 2>&1)|$(cat "$S/confirm.calls" 2>&1)"
newcase; adapter syn <<'A'
adapter_confirm() { return 0
A
pub; refused "an adapter.sh with a syntax error" "$(said syn)its adapter.sh has a syntax error (line "
# Its top-level code runs once for the load and once for each call, with the same folder, settings and site values.
newcase; mkdir -p "$tmp/case$n/tmpdir"; adapter v '"worker": "good"' <<'A'
echo loaded >> "$STUB_DIR/toplevel"
adapter_seen() { echo "$OFFPRINT_ADAPTER_DIR|${ADAPTER_SET_WORKER-}|$SITE_PUBLIC_URL" >> "$STUB_DIR/seen"; }
adapter_validate() { adapter_seen; }
adapter_prepare() { adapter_seen; }
adapter_deploy() { adapter_seen; }
adapter_confirm() { adapter_seen; }
A
TMPDIR="$tmp/case$n/tmpdir" pub; t="the values each call sees"
check "$t: live" "0|live" "$code|$(js state)"
want="$(cd "$c" && pwd -P)/adapters/v|good|https://www.example.com"
check "$t: the same folder, setting and site value in every call" "$want|$want|$want|$want" "$(paste -sd'|' - < "$S/seen" 2>&1)"
check "$t: the top level ran for the load and each of the four calls" 5 "$(wc -l < "$S/toplevel" | tr -d ' ')"
check "$t: nothing left in TMPDIR" "" "$(ls -A "$tmp/case$n/tmpdir")"
# What comes back is read a few KB at most: a huge ADAPTER_PROBLEM, ADAPTER_WHY or hint costs no time.
newcase; adapter big <<'A'
ADAPTER_CONFIRM_SECONDS=1
adapter_deploy() { [ -f "$STUB_DIR/deploy_ok" ] && return 0; ADAPTER_PROBLEM="$(head -c 400000 /dev/zero | tr '\0' x)"; return 1; }
adapter_confirm() { ADAPTER_WHY="$(head -c 400000 /dev/zero | tr '\0' y)"; return 1; }
adapter_failure_hint() { head -c 400000 /dev/zero | tr '\0' z; }
A
start=$SECONDS; pub; t="a 400 KB ADAPTER_PROBLEM"
check "$t: fails, soon" "1|yes" "$code|$([ $((SECONDS - start)) -lt 15 ] && echo yes || echo no)"
check "$t: cut to 300 characters" "$(short) is pushed, but the deploy failed: $(printf '%0300d' 0 | tr 0 x)" "$(js message)"
touch "$S/deploy_ok"; echo '<p>more</p>' > "$S/fixture/hello/index.html"; start=$SECONDS; pub; t="a 400 KB ADAPTER_WHY and hint"
check "$t: fails, soon" "1|yes" "$code|$([ $((SECONDS - start)) -lt 20 ] && echo yes || echo no)"
check "$t: each cut to 200 characters" "$(short) is pushed, but the live site hasn't shown it after 1 seconds ($(printf '%0200d' 0 | tr 0 y))$(printf '%0200d' 0 | tr 0 z)" "$(js message)"
# A TERM while an adapter function is stuck: the publish stops at once, cleans up, and leaves nothing behind.
newcase; mkdir -p "$tmp/case$n/tmpdir"; adapter stuck <<'A'
adapter_deploy() { sleep 41 & touch "$STUB_DIR/deploying"; wait; }
adapter_confirm() { return 0; }
A
( cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_POLL_SECONDS=1 \
  exec /bin/bash "$SRC/bin/publish" > "$S/pub.out" 2>&1 ) & pid=$!
i=0; while [ ! -e "$S/deploying" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
check "control: the deploy is stuck" yes "$(exists "$S/deploying")"
kill -TERM "$pid"; i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
t="a TERM while adapter_deploy is stuck"
if kill -0 "$pid" 2>/dev/null; then bad "$t: the publish stopped within 10 seconds"; kill -KILL "$pid" 2>/dev/null; else ok "$t: the publish stopped within 10 seconds"; fi
wait "$pid" 2>/dev/null
check "$t: the status is failed, and final" "failed|false" "$(js state)|$(js running)"
check "$t: the lock is released" no "$(exists "$c/var/publish.lock")"
check "$t: nothing left in TMPDIR (no load folder, no answer)" "" "$(ls -A "$tmp/case$n/tmpdir")"
sleep 0.5; check "$t: the stuck function is stopped" "" "$(pgrep -f 'sleep 41')"

# === ADAPTER_DEPLOY_AGAIN: a publish with nothing new whose live site doesn't serve it has the adapter deploy again ===
# calls FILE: how many lines the case's stand-ins wrote to STUB_DIR/FILE (0 when none)
calls() { if [ -f "$S/$1" ]; then wc -l < "$S/$1" | tr -d ' '; else echo 0; fi; }
newcase; adapter bare <<'A'
# sets nothing
A
load 'echo "AGAIN=$ADAPTER_DEPLOY_AGAIN"'
check "an adapter that sets nothing: ADAPTER_DEPLOY_AGAIN is 0" "rc=0|AGAIN=0" "$(printf '%s\n' "$out" | paste -sd'|' -)"
newcase; adapter x <<'A'
ADAPTER_DEPLOY_AGAIN=1
adapter_confirm() { return 0; }
A
load 'echo "AGAIN=$ADAPTER_DEPLOY_AGAIN"'
check "an adapter that sets ADAPTER_DEPLOY_AGAIN=1: it is 1" "rc=0|AGAIN=1" "$(printf '%s\n' "$out" | paste -sd'|' -)"
for bad_set in 'ADAPTER_DEPLOY_AGAIN=2' 'ADAPTER_DEPLOY_AGAIN=yes' 'ADAPTER_DEPLOY_AGAIN=01' 'ADAPTER_DEPLOY_AGAIN=' 'unset ADAPTER_DEPLOY_AGAIN'; do
  newcase; adapter x < <(printf 'adapter_confirm() { return 0; }\n%s\n' "$bad_set")
  pub; refused "an adapter.sh that sets $bad_set" "$(said x)its adapter.sh sets ADAPTER_DEPLOY_AGAIN to something that isn't 0 or 1."
done
# === ADAPTER_PIGEONHOLE: only a host that forwards the pigeonhole's path may show comment forms ===
# A site with a "pigeonhole" block in site.json shows comment forms that post to one path of its own origin. Only a
# web server of the owner's, set up to forward that path, takes such a post: on any other host the form would post to
# nothing. Whether its host is one is the adapter's to say; no adapter of the tool's says so.
PH_KEY="age1$(printf 'q%.0s' $(seq 1 58))"
with_pigeonhole() {
  sed "s#\"format\": 1,#\"format\": 1, \"pigeonhole\": {\"path\": \"/_pigeonhole\", \"recipients\": [\"$PH_KEY\"]},#" "$c/site.json" > "$c/site.json.new"
  mv "$c/site.json.new" "$c/site.json"; commit "a pigeonhole block"
}
no_comments() { printf 'site.json has a "pigeonhole" block, but this site'"'"'s host can'"'"'t take comments: its adapter (%s) doesn'"'"'t say that it forwards the pigeonhole'"'"'s path (ADAPTER_PIGEONHOLE=1), so a comment form would post to nothing. Take the block out of site.json, or publish to a host that can; nothing was published.' "$1"; }
newcase; adapter bare <<'A'
# sets nothing
A
load 'echo "PH=$ADAPTER_PIGEONHOLE"'
check "an adapter that sets nothing: ADAPTER_PIGEONHOLE is 0" "rc=0|PH=0" "$(printf '%s\n' "$out" | paste -sd'|' -)"
newcase; adapter x <<'A'
ADAPTER_PIGEONHOLE=1
adapter_confirm() { return 0; }
A
load 'echo "PH=$ADAPTER_PIGEONHOLE"'
check "an adapter that sets ADAPTER_PIGEONHOLE=1: it is 1" "rc=0|PH=1" "$(printf '%s\n' "$out" | paste -sd'|' -)"
for bad_set in 'ADAPTER_PIGEONHOLE=2' 'ADAPTER_PIGEONHOLE=yes' 'ADAPTER_PIGEONHOLE=01' 'ADAPTER_PIGEONHOLE=' 'unset ADAPTER_PIGEONHOLE'; do
  newcase; adapter x < <(printf 'adapter_confirm() { return 0; }\n%s\n' "$bad_set")
  pub; refused "an adapter.sh that sets $bad_set" "$(said x)its adapter.sh sets ADAPTER_PIGEONHOLE to something that isn't 0 or 1."
done
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
with_pigeonhole; pub; refused "a pigeonhole block, and an adapter that doesn't say its host takes comments" "$(no_comments x)"
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
with_pigeonhole; pub --dry-run; refused "... a dry run too" "$(no_comments x)"
newcase; with_pigeonhole; pub; refused "a pigeonhole block, and no host at all (the adapter none)" "$(no_comments none)"
newcase; adapter x <<'A'
ADAPTER_PIGEONHOLE=1
adapter_confirm() { return 0; }
A
with_pigeonhole; pub; t="a pigeonhole block, and an adapter that says its host takes comments"
check "$t: the publish goes on, and ends well" 0 "$code"
check "$t: a new commit" "$((commits0 + 1))" "$(git -C "$c" rev-list --count HEAD)"
newcase; adapter x <<'A'
adapter_confirm() { return 0; }
A
pub; t="no pigeonhole block, and an adapter that doesn't say: nothing to refuse"
check "$t: the publish ends well" 0 "$code"

# An adapter that deploys again: its deploy notes each commit it is given, fails while deploy_fails is there, and makes
# the live site serve the publish (live) unless never_live is there; its confirm answers 0 once live, else 2 while away
# is there, else 1.
newcase; adapter again <<'A'
ADAPTER_DEPLOY_AGAIN=1
ADAPTER_CONFIRM_SECONDS=1
adapter_deploy() {
  echo "$1" >> "$STUB_DIR/deploy.calls"
  [ ! -f "$STUB_DIR/deploy_fails" ] || { ADAPTER_PROBLEM="the upload failed"; return 1; }
  [ -f "$STUB_DIR/never_live" ] || touch "$STUB_DIR/live"
}
adapter_confirm() {
  echo "$2" >> "$STUB_DIR/confirm.calls"
  [ ! -f "$STUB_DIR/live" ] || return 0
  [ ! -f "$STUB_DIR/away" ] || return 2
  ADAPTER_WHY="it shows the one before"; return 1
}
adapter_failure_hint() { printf '; ask the host'; }
A
touch "$S/deploy_fails"; pub; t="ADAPTER_DEPLOY_AGAIN=1, a publish whose deploy fails"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: failed, the commit pushed" "1|${sha:0:7} is pushed, but the deploy failed: the upload failed|$sha" "$code|$(js message)|$(git -C "$O" rev-parse main)"
rm "$S/deploy_fails"; pub; t="ADAPTER_DEPLOY_AGAIN=1, then a publish with nothing new, the live site not showing it (1)"
check "$t: live, no new commit" "0|live|The site is live at ${sha:0:7}|$sha" "$code|$(js state)|$(js message)|$(git -C "$c" rev-parse HEAD)"; valid "$t"
check "$t: the commit was deployed again" "$sha|$sha" "$(paste -sd'|' - < "$S/deploy.calls")"
check "$t: the live site was asked before, and again after" "$sha|$sha" "$(paste -sd'|' - < "$S/confirm.calls")"
contains "$t: it said it was waiting for the live site" "[deploying] Waiting for www.example.com to serve ${sha:0:7}" "$out"
pub; t="ADAPTER_DEPLOY_AGAIN=1, nothing new, the live site showing it"
check "$t: unchanged" "0|unchanged|Nothing has changed since the last publish." "$code|$(js state)|$(js message)"
check "$t: the deploy wasn't run again" 2 "$(calls deploy.calls)"; check "$t: the live site was asked, once" 3 "$(calls confirm.calls)"
rm "$S/live"; touch "$S/deploy_fails"; pub; t="ADAPTER_DEPLOY_AGAIN=1, nothing new, and the deploy again fails"
check "$t: failed, with the adapter's reason" "1|${sha:0:7} is pushed, but the deploy failed: the upload failed" "$code|$(js message)"; valid "$t"
check "$t: it was run" 3 "$(calls deploy.calls)"
rm "$S/deploy_fails"; touch "$S/never_live"; pub; t="ADAPTER_DEPLOY_AGAIN=1, nothing new, the deploy again works but the live site never shows it"
check "$t: the confirm's limit, why and hint" "1|${sha:0:7} is pushed, but the live site hasn't shown it after 1 seconds (it shows the one before); ask the host" "$code|$(js message)"
check "$t: it was run" 4 "$(calls deploy.calls)"; check "$t: still no new commit" "$sha" "$(git -C "$c" rev-parse HEAD)"
rm "$S/never_live"; touch "$S/away"; pub; t="ADAPTER_DEPLOY_AGAIN=1, nothing new, the live site couldn't be reached (2)"
check "$t: deployed again, then live" "0|live|5" "$code|$(js state)|$(calls deploy.calls)"
# The default (0): a publish with nothing new only asks, as it always has.
newcase; adapter once <<'A'
adapter_deploy() { echo "$1" >> "$STUB_DIR/deploy.calls"; [ -f "$STUB_DIR/deploy_ok" ] || { ADAPTER_PROBLEM="the upload failed"; return 1; }; }
adapter_confirm() { return 2; }
A
pub; touch "$S/deploy_ok"; pub; t="ADAPTER_DEPLOY_AGAIN 0 (the default): a failed deploy, then a publish with nothing new"
check "$t: the deploy isn't run again" 1 "$(calls deploy.calls)"
check "$t: the live site is asked, as before" "1|GitHub has $(short), but the live site couldn't be reached to confirm it serves that (see var/publish.log); publish again in a minute." "$code|$(js message)"

# === ADAPTER_HOST_SPECIAL_FILES: names the host gives a meaning of its own at the root of what it is given ===
# (an ignore file, say: in the export it could drop checked files from the live site). Refused at the root, in any
# letter case, a file or a folder, before the adapter writes anything; deeper down they are the export's own.
newcase; adapter bare <<'A'
# sets nothing
A
load 'echo "SPECIAL=[$ADAPTER_HOST_SPECIAL_FILES]"'
check "an adapter that sets nothing: ADAPTER_HOST_SPECIAL_FILES is empty" "rc=0|SPECIAL=[]" "$(printf '%s\n' "$out" | paste -sd'|' -)"
for bad_set in 'ADAPTER_HOST_SPECIAL_FILES="a/b"' "ADAPTER_HOST_SPECIAL_FILES='*'" 'ADAPTER_HOST_SPECIAL_FILES=".."'; do
  newcase; adapter x < <(printf 'adapter_confirm() { return 0; }\n%s\n' "$bad_set")
  pub; refused "an adapter.sh that sets $bad_set" "$(said x)its adapter.sh sets ADAPTER_HOST_SPECIAL_FILES to something that isn't a list of file names (letters, digits, dots, dashes and underscores, separated by spaces)."
done
special_adapter() {  # an adapter s whose host gives .hostignore and _hostcode.js a meaning; its prepare notes that it ran
  adapter s <<'A'
ADAPTER_HOST_SPECIAL_FILES=".hostignore _hostcode.js"
adapter_prepare() { touch "$STUB_DIR/prepared"; }
adapter_confirm() { return 0; }
A
}
for spec in ".hostignore|file" ".HostIgnore|file" "_hostcode.js|file" "_HostCode.JS|folder"; do
  f="${spec%|*}"; kind="${spec#*|}"; lower="$(printf '%s' "$f" | tr 'A-Z' 'a-z')"
  newcase; special_adapter
  if [ "$kind" = file ]; then echo planted > "$S/fixture/$f"; else mkdir "$S/fixture/$f"; echo x > "$S/fixture/$f/x"; fi
  pub; t="$f at the root of the export ($kind), a name the host gives a meaning of its own"
  check "$t: refused" "1|The export failed the checks, nothing was published: the host gives $lower a meaning of its own at the root, so the export can't have one: ./$f" "$code|$(js message)"
  valid "$t"; check "$t: before the adapter wrote anything" no "$(exists "$S/prepared")"; nocommit "$t"; oldsite "$t"
done
newcase; special_adapter; echo x > "$S/fixture/hello/.hostignore"; pub --no-push; t="the same name deeper down (hello/.hostignore)"
check "$t: the export's own, committed" "0|hello/.hostignore" "$code|$(git -C "$c" ls-tree -r --name-only HEAD -- site/hello/.hostignore | sed 's#^site/##')"
newcase; special_adapter; cp -R "$S/fixture" "$tmp/case$n/out"; echo x > "$tmp/case$n/out/.HOSTIGNORE"
out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" check out 2>&1)"; code=$?; t="offprint check, a name the host gives a meaning of its own"
check "$t: refused" "1|the host gives .hostignore a meaning of its own at the root, so the export can't have one: ./.HOSTIGNORE" "$code|$out"
cp -R "$S/fixture/." "$c/site/"; echo x > "$c/site/.hostignore"; out="$(cd "$tmp/case$n" && OFFPRINT_SITE="$c" /bin/bash "$SRC/bin/offprint" check "$c/site" 2>&1)"; code=$?
check "$t: in the site's own site/ too (no publish writes one)" "1|the host gives .hostignore a meaning of its own at the root, so the export can't have one: ./.hostignore" "$code|$out"

# === a private folder is never inside the site folder, where WordPress can write ===
# A TMPDIR inside the site folder is refused as soon as the site folder is known (lib/site.sh: see "TMPDIR inside the
# site folder" below for every entry point). The loader's own folder (it holds the private copy of adapter.sh that every
# call sources, and each call's answer) is the second layer: refused, before anything is made, copied or sourced, for a
# TMPDIR inside the site folder, compared as folders on disk: in the same letter case, another (where the disk ignores
# case), through a link, another path to the same folder (a macOS firmlink, /System/Volumes/Data/...), or the site
# folder itself. A TMPDIR outside it works, one whose name starts like it too.
newcase; mkdir -p "$c/var/tmp"; adapter x <<'A'
touch "$STUB_DIR/sourced"
adapter_confirm() { return 0; }
A
TMPDIR="$c/var/tmp" pub; t="TMPDIR inside the site folder (var/tmp), a publish"
check "$t: refused as soon as the site folder is known (lib/site.sh), in one line, exit 2" \
  "2|TMPDIR is $c/var/tmp, inside the site folder $(cd "$c" && pwd -P), which WordPress can write; unset TMPDIR, or point it at a folder outside the site folder." "$code|$out"
check "$t: before anything is written: no status, no lock, no log" "no|no|no" "$(exists "$c/var/status.json")|$(exists "$c/var/publish.lock")|$(exists "$c/var/publish.log")"
no_docker "$t"; nocommit "$t"; oldsite "$t"
check "$t: adapter.sh was never sourced" no "$(exists "$S/sourced")"; check "$t: nothing left in it" "" "$(ls -A "$c/var/tmp")"
# The loader's own test, the second layer, for a TMPDIR set after the site folder was found:
ln -s "$c/var/tmp" "$tmp/case$n/via"; firm="/System/Volumes/Data$(cd "$c/var/tmp" && pwd -P)"
for spec in "$c/var/tmp|in the same letter case" "${c%/repo}/REPO/var/tmp|in another letter case (the site folder's own name)" "$tmp/case$n/via|through a link" \
    "$firm|through a firmlink ($firm)" "$c|the site folder itself"; do
  where="${spec%%|*}"; how="${spec#*|}"; t="the loader, TMPDIR inside the site folder, $how"
  if [ ! -d "$where" ] || ! [ "$where" -ef "$c/var/tmp" -o "$where" -ef "$c" ]; then echo "skip  $t (this disk has no such path)"; continue; fi
  PRE="TMPDIR='$where'" STUB_DIR="$S" load
  check "$t: refused (2), saying so" "rc=2|problem=$(said x)no private folder could be made to load it in: TMPDIR is inside the site folder, which WordPress can write; a private folder must be outside it." "$(printf '%s\n' "$out" | paste -sd'|' -)"
  check "$t: adapter.sh never sourced, nothing left" "no|" "$(exists "$S/sourced")|$(ls -A "$c/var/tmp")"
done
mkdir -p "$tmp/case$n/elsewhere" "$c-tmp"
for where in "$tmp/case$n/elsewhere" "$c-tmp"; do
  PRE="TMPDIR='$where'" STUB_DIR="$S" load 'echo "folder=$OFFPRINT_ADAPTER_TMP"'; t="the loader, TMPDIR $where (outside the site folder)"
  folder="$(printf '%s\n' "$out" | sed -n 's/^folder=//p')"; there=no
  case "$folder" in "$(cd "$where" && pwd -P)"/offprint-adapter.??????) there=yes ;; esac
  check "$t: loads, its folder there" "rc=0|yes" "$(printf '%s\n' "$out" | head -n 1)|$there"
  check "$t: and removed afterwards" "" "$(ls -A "$where")"; rm -f "$S/sourced"
done
rmdir "$c-tmp"

# === the cloudflare-workers adapter (adapters/cloudflare-workers) ===
# Nothing here runs the real wrangler, node or security, or reaches Cloudflare. Each case has an Offprint folder of its
# own (OFFPRINT_HOME) holding a stand-in install of wrangler 4.166.0 (just its entry script, a file the stand-in node is
# handed) and the file naming the node it runs on: the stand-in node, in a folder with a space in its name, on no PATH.
# The stand-in security (OFFPRINT_SECURITY) holds the secret cloudflare-token. The token is the fake TOKEN below;
# neither stand-in holds it as written (each has it backwards, made from TOKEN), so finding it, either half of it, or
# any 8 characters of it, in any file under the case's folder or the suite's TMPDIR, in any commit, or in what the
# publish printed, is a leak (Review Focus 2). A self-check shows the stand-in node did print it, whole. Checks whose
# text could hold it never show that text.
TOKEN=CFTOKEN-do-not-print-q7Zx4Kp9Wm; TOKEN_A="${TOKEN:0:15}"; TOKEN_B="${TOKEN:15}"
# The fake account id shares no 8 characters in a row with the token, so every piece of the token below is looked for.
ACCOUNT=fedcba9876543210fedcba9876543210
# TOKEN_PIECES: every 8 characters of the token in a row: each is looked for too, so no part of the token can leak
# unseen. TOKEN_BACK: the token backwards, made here with the shell's own string operations (no program is handed the
# token), which is all the stand-ins hold.
TOKEN_PIECES=""; i=0
while [ $((i + 8)) -le ${#TOKEN} ]; do TOKEN_PIECES="$TOKEN_PIECES ${TOKEN:i:8}"; i=$((i + 1)); done
shared=""; for p in $TOKEN_PIECES; do case "$ACCOUNT" in *"$p"*) shared="$shared $p" ;; esac; done
check "control: the fake account id shares no 8 characters in a row with the token" "" "$shared"
TOKEN_BACK=""; i=${#TOKEN}; while [ "$i" -gt 0 ]; do i=$((i - 1)); TOKEN_BACK="$TOKEN_BACK${TOKEN:i:1}"; done
# leak_args: sets LEAK to grep -F's arguments for the token's halves and its pieces
leak_args() { local p; LEAK=(-e "$TOKEN_A" -e "$TOKEN_B"); for p in $TOKEN_PIECES; do LEAK=("${LEAK[@]}" -e "$p"); done; }
leak_args
CF_SETTINGS="\"worker\": \"my-site\", \"account_id\": \"$ACCOUNT\""
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (not there)"; fi; }
qcheck() {  # check, but a value holding the token (or half of it) is never shown
  if [ "$2" = "$3" ]; then ok "$1"
  else case "$3" in *"$TOKEN_A"*|*"$TOKEN_B"*) bad "$1 (it holds the token, not shown)" ;; *) bad "$1 (wanted '$2', got '$3')" ;; esac; fi
}
no_leak() {  # no_leak T: the token, and each half of it, nowhere the run could have put it
  local hits
  hits="$(grep -rlaF -D skip "${LEAK[@]}" "$tmp/case$n" "$TMPDIR" 2>/dev/null | sed "s#^$tmp/##")"   # (a FIFO left behind is skipped, never waited on)
  check "$1: the token, half of it, or any 8 characters of it, is in no file the run wrote" "" "$hits"
  if printf '%s' "$out" | grep -qF "${LEAK[@]}"; then bad "$1: some of the token is in what the publish printed"
  else ok "$1: nor in what the publish printed"; fi
  if git -C "$c" log -p --all 2>/dev/null | grep -qF "${LEAK[@]}"; then bad "$1: some of the token is in a commit"
  else ok "$1: nor in any commit"; fi
}
# The stand-in node is perl, which sees its environment exactly as it was given (a shell would add names of its own). It
# notes what it was given in the case's stub folder (written into it when the case makes it: nothing in its environment
# may name that folder), then does what the case's files there say:
#   node_echo      it prints the token on stdout and on stderr: whole, split over two lines, and across a 4096-byte cut
#   node_fail      it prints that file (@TOKEN@ in it the token) on stderr, and fails
#   node_says      it prints that file's lines (@TOKEN@ in them the token), each on the stream its first character
#                  names (1 stdout, 2 stderr; then a space and the line), in order, and fails: wrangler prints its
#                  [ERROR] block and the rest on two streams, which reach var/publish.log interleaved
#   node_hang      it starts a child (sleep 47) and waits for it; node_stubborn: both ignore TERM
#   node_nolive    the upload "works" but the live site doesn't change
# Otherwise the upload works: the live site (the stand-in curl's live_dir) then serves what it was given to upload.
# Whatever it does, it first copies the assets folder its config names to STUBS/uploaded (links as links), and writes
# .wrangler/ in its working folder and a log under HOME, as wrangler does.
cat > "$tmp/node.pl" <<'NODE'
#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(getcwd);
use JSON::PP;
my $s = '@STUBS@';
sub note { my ($name, $text) = @_; open(my $h, '>>', "$s/$name") or die "$s/$name: $!"; print $h $text; close $h; }
sub slurp { my ($f) = @_; open(my $h, '<', $f) or return ''; local $/; my $t = <$h>; close $h; return defined $t ? $t : ''; }
# node --version (set-up and doctor ask it, and nothing else of node): the case's node_version (else v22.12.0), its
# environment's names noted in node.version, one line a run.
@ENVCHECK@
if (@ARGV == 1 && $ARGV[0] eq '--version') {
  envcheck('node --version');
  note('node.version', join(' ', sort keys %ENV) . "\n");
  my $v = slurp("$s/node_version"); $v = "v22.12.0\n" if $v eq '';
  print $v; exit 0;
}
# out FH TEXT: prints TEXT, and notes it in node.printed.rev with each line backwards (so the suite can tell what was
# printed, and the token is in no file as written)
sub out { my ($fh, $t) = @_; print $fh $t; note('node.printed.rev', join("\n", map { scalar reverse $_ } split(/\n/, $t, -1))); }
my $tok = defined $ENV{CLOUDFLARE_API_TOKEN} ? $ENV{CLOUDFLARE_API_TOKEN} : '';
note('node.runs', "ran\n");
unlink map { "$s/node.$_" } qw(argv env values cwd config stdin);
note('node.argv', join('', map { "$_\n" } @ARGV));
note('node.env', join('', map { "$_\n" } sort keys %ENV));
note('node.values', 'CLOUDFLARE_API_TOKEN=' . ($tok eq reverse('@BACK@') ? 'the stored token' : 'another value') . "\n");
note('node.values', join('', map { "$_=$ENV{$_}\n" } grep { $_ ne 'CLOUDFLARE_API_TOKEN' } sort keys %ENV));
my $cwd = getcwd();
note('node.cwd', "$cwd\n");
note('node.stdin', ((-c STDIN && !-t STDIN && eof(STDIN)) ? 'empty, not a terminal' : 'something else') . "\n");
my $cfg = '';
for my $i (0 .. $#ARGV - 1) { $cfg = $ARGV[$i + 1] if $ARGV[$i] eq '--config'; }
my $text = $cfg eq '' ? '' : slurp($cfg);
note('node.config', $text);
my $dir = eval { JSON::PP->new->decode($text)->{assets}{directory} };
$dir = '' unless defined $dir && !ref $dir;
system('/bin/rm', '-rf', "$s/uploaded");
system('/bin/cp', '-RP', $dir, "$s/uploaded") if $dir ne '' && -d $dir;
mkdir "$cwd/.wrangler";
if (open(my $w, '>', "$cwd/.wrangler/state")) { print $w "state\n"; close $w; }
if (defined $ENV{HOME} && $ENV{HOME} ne '') {
  system('/bin/mkdir', '-p', "$ENV{HOME}/.wrangler/logs");
  if (open(my $l, '>>', "$ENV{HOME}/.wrangler/logs/wrangler.log")) { print $l "a run\n"; close $l; }
}
$| = 1;
if (-e "$s/node_echo") {
  out(\*STDOUT, "token on stdout: $tok\n");
  out(\*STDERR, "token on stderr: $tok\n");
  out(\*STDOUT, 'split over two lines: ' . substr($tok, 0, 12) . "\n" . substr($tok, 12) . " (end)\n");
  # The long line, with the other stream silent. It reaches the log in two pieces (the filter reads 4096 bytes at a
  # time), and each stream's filter keeps its last line back until the next one comes, or the stream ends: so a line of
  # stderr's written at that moment could land between the pieces. So stderr ends first (closed; /dev/null in its place,
  # so no file opened later takes its number), and this waits until its filter has written what it kept back (the line
  # in the log, the site folder's var/publish.log beside STUBS; for up to 10 seconds); only stdout is written after that.
  close(STDERR); open(STDERR, '>', '/dev/null');
  for (1 .. 200) { last if index(slurp("$s/../repo/var/publish.log"), 'token on stderr: [token hidden]') >= 0; select(undef, undef, undef, 0.05); }
  out(\*STDOUT, ('x' x 4090) . $tok . " after a 4096-byte cut\n");
}
if (-e "$s/node_fail") { my $t = slurp("$s/node_fail"); $t =~ s/\@TOKEN\@/$tok/g; print STDERR $t; exit 1; }
if (-e "$s/node_says") {
  for my $l (split(/\n/, slurp("$s/node_says"))) {
    my ($w, $t) = $l =~ /^([12]) ?(.*)\z/ or next;
    $t =~ s/\@TOKEN\@/$tok/g;
    if ($w eq '1') { print STDOUT "$t\n"; } else { print STDERR "$t\n"; }
    select(undef, undef, undef, 0.05);   # (each stream has a filter of its own: so the order they write in is the order here)
  }
  exit 1;
}
if (-e "$s/node_hang") {
  $SIG{TERM} = 'IGNORE' if -e "$s/node_stubborn";
  my $pid = fork();
  if (defined $pid && $pid == 0) { exec('/bin/sleep', '47'); exit 127; }
  note('node.hanging', "$$ $pid\n");
  waitpid($pid, 0);
  exit 0;
}
unless (-e "$s/node_nolive") {
  system('/bin/rm', '-rf', "$s/live");
  system('/bin/cp', '-RP', $dir, "$s/live") if $dir ne '' && -d $dir;
}
print STDOUT "Uploaded my-site (the stand-in)\n";
exit 0;
NODE
# The stand-in security (perl, so the value is in no program's arguments): the one item it holds is the token, for the
# site "example" (tests/fixtures/site.json). Its arguments are noted in STUB_DIR/security.argv. secret_missing: no such
# item (44); secret_locked: the keychain is locked (152, as from a process with no terminal).
cat > "$tmp/security.pl" <<'STUB'
#!/usr/bin/perl
use strict;
use warnings;
my $s = $ENV{STUB_DIR};
open(my $h, '>>', "$s/security.argv") or die; print $h join(' ', @ARGV), "\n"; close $h;
if (-e "$s/secret_locked") { print STDERR "security: unable to obtain authorization for this operation.\n"; exit 152; }
if (-e "$s/secret_missing") { print STDERR "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n"; exit 44; }
if (join(' ', @ARGV) ne 'find-generic-password -s offprint -a example/cloudflare-token -w') { print STDERR "security (stand-in): unexpected\n"; exit 2; }
print scalar(reverse('@BACK@')), "\n";
STUB
# ENVCHECK: perl, for the stand-ins (and wrap.pl, below): envcheck(WHO) notes in STUBS/env.hits the name of each
# variable in its environment whose value holds the token, its hex (as os/darwin/secret hands it to security), or any
# 8 characters of it that aren't all digits (never the value), as "WHO: NAMES". (A run of 8 digits is too common to mean
# anything: with allexport, bash exports the adapter's functions too, and their code has 0123456789abcdef in it.)
ENVCHECK="$(cat <<'PERL'
sub envcheck {
  my ($who) = @_; my $tok = reverse('@BACK@'); my $hex = unpack('H*', $tok); my @hit;
  for my $k (sort keys %ENV) {
    my $v = $ENV{$k}; my $f = index($v, $tok) >= 0 || index(lc($v), $hex) >= 0;
    for (my $i = 0; !$f and $i + 8 <= length($tok); $i++) { my $p = substr($tok, $i, 8); $f = 1 if $p =~ /\D/ and index($v, $p) >= 0; }
    push @hit, $k if $f;
  }
  if (@hit) { open(my $h, '>>', "$s/env.hits") or die; print $h "$who: @hit\n"; close $h; }
}
PERL
)"
# (Bash 5.2's patsub_replacement would make each & in a ${t//PATTERN/REPLACEMENT} replacement the text it replaces: off,
# so what stand_in fills in is exactly what it is given, as on macOS's bash 3.2; and ENVCHECK has no & in it anyway.)
shopt -u patsub_replacement 2> /dev/null || true
# stand_in TEMPLATE FILE: TEMPLATE with @ENVCHECK@ (ENVCHECK), @STUBS@ (the case's stub folder), @BACK@ (TOKEN_BACK) and
# @ADIR@ (the tool's cloudflare-workers folder) filled in, as FILE, made with the shell's own string operations and
# printf (so no program is handed any of them), and executable.
stand_in() {
  local t; t="$(cat "$1")"; t="${t//@ENVCHECK@/$ENVCHECK}"; t="${t//@STUBS@/${S:-}}"; t="${t//@BACK@/$TOKEN_BACK}"
  t="${t//@ADIR@/$SRC/adapters/cloudflare-workers}"
  printf '%s\n' "$t" > "$2"; chmod +x "$2"
}
stand_in "$tmp/security.pl" "$tmp/security"
# cf_install DIR: the stand-in install in the Offprint folder DIR: wrangler's entry script (and node_modules/.bin's
# relative links to it, as npm makes them), and the file naming the node
cf_install() {
  mkdir -p "$1/cloudflare-workers/wrangler-4.166.0/node_modules/wrangler/bin" "$1/cloudflare-workers/wrangler-4.166.0/node_modules/.bin"
  echo '// the stand-in node never reads this' > "$1/cloudflare-workers/wrangler-4.166.0/node_modules/wrangler/bin/wrangler.js"
  ln -s ../wrangler/bin/wrangler.js "$1/cloudflare-workers/wrangler-4.166.0/node_modules/.bin/wrangler"
  ln -s ../wrangler/bin/wrangler.js "$1/cloudflare-workers/wrangler-4.166.0/node_modules/.bin/wrangler2"
  printf '%s\n' "$NODE" > "$1/cloudflare-workers/node"
}
# cf_case [SETTINGS]: a site naming cloudflare-workers (worker my-site, account ACCOUNT, and SETTINGS), committed; its
# Offprint folder, its stand-in node ($NODE), and a TMPDIR of its own. ENTRY is wrangler's entry script there.
cf_case() {
  newcase; site_json cloudflare-workers "$CF_SETTINGS${1:+, $1}"; commit "cloudflare-workers"
  NODE="$tmp/case$n/node bin/node"; mkdir -p "$tmp/case$n/node bin" "$tmp/case$n/tmpdir"
  stand_in "$tmp/node.pl" "$NODE"
  cf_install "$tmp/case$n/ohome"; ENTRY="$tmp/case$n/ohome/cloudflare-workers/wrangler-4.166.0/node_modules/wrangler/bin/wrangler.js"
  touch "$S/live_dir"
}
# cfpub: a publish of that site with the stand-ins, the confirm's 60 seconds cut to 1
cfpub() {
  OFFPRINT_HOME="$tmp/case$n/ohome" OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 pub "$@"
}
cf_tmp_empty() { check "$1: nothing left in TMPDIR (the upload's private folder is gone)" "" "$(ls -A "$tmp/case$n/tmpdir")"; }
never_ran() { check "$1: node never ran" 0 "$(calls node.runs)"; }

# The contract, as the adapter fills it in.
cf_case; load 'printf "PREPARE=[%s]\nHOST=[%s]\nFILE_BYTES=%s\nFILES=%s\nTOTAL_BYTES=%s\nCONFIRM_SECONDS=%s\nAGAIN=%s\n" "$ADAPTER_PREPARE_FILES" "$ADAPTER_HOST_FILES" "$ADAPTER_MAX_FILE_BYTES" "$ADAPTER_MAX_FILES" "$ADAPTER_MAX_TOTAL_BYTES" "$ADAPTER_CONFIRM_SECONDS" "$ADAPTER_DEPLOY_AGAIN"
echo "hint=[$(offprint_adapter_call adapter_failure_hint)]"'
t="cloudflare-workers"
check "$t: loads, and fills in the contract" \
  "rc=0|PREPARE=[offprint.json _headers _redirects]|HOST=[]|FILE_BYTES=26214400|FILES=20000|TOTAL_BYTES=0|CONFIRM_SECONDS=60|AGAIN=1|hint=[; run offprint adapter doctor]" \
  "$(printf '%s\n' "$out" | paste -sd'|' -)"
# The limit on wrangler's run: 120 seconds; the test seam OFFPRINT_WRANGLER_TIMEOUT can only shorten it.
for spec in 5:5 1:1 120:120 0:120 121:120 500:120 abc:120 -3:120 ' 7':120 :120; do
  v="${spec%:*}"; OFFPRINT_WRANGLER_TIMEOUT="$v" load 'offprint_adapter_call adapter_cf_limit'
  check "$t: OFFPRINT_WRANGLER_TIMEOUT='$v': wrangler's limit is ${spec##*:} seconds" "rc=0|${spec##*:}" "$(printf '%s\n' "$out" | paste -sd'|' -)"
done

# adapter_validate: worker and account_id, both required, each strictly; nothing else is a setting.
# vload SETTINGS...: adapter_validate, ADAPTER_SET_* as given (shell assignments);
# sets got to STATUS|THE LINES IT PRINTED
vload() { PRE="unset ADAPTER_SET_WORKER ADAPTER_SET_ACCOUNT_ID; $*" load 'v="$(offprint_adapter_call adapter_validate 2>&1)"; echo "validate=$?|$v"'; got="$(printf '%s\n' "$out" | sed -n '/^validate=/,$p' | paste -sd'|' -)"; got="${got#validate=}"; }
W_RULE='site.json: "adapter.worker" must be a Worker'"'"'s name: 1 to 63 lowercase letters, digits and dashes, starting and ending with a letter or digit.'
A_RULE='site.json: "adapter.account_id" must be a Cloudflare account id: 32 lowercase hex digits.'
cf_case
for w in my-site a 0 a-b-c "$(printf '%063d' 0 | tr 0 a)"; do
  vload "ADAPTER_SET_WORKER=$w ADAPTER_SET_ACCOUNT_ID=$ACCOUNT"; check "$t: worker '$w' and the account id: valid" "0|" "$got"
done
for w in My-Site -site site- my_site my.site "$(printf '%064d' 0 | tr 0 a)" 'a b'; do
  vload "ADAPTER_SET_WORKER='$w' ADAPTER_SET_ACCOUNT_ID=$ACCOUNT"; check "$t: worker '$w': refused, by name" "1|$W_RULE" "$got"
done
for a in "$(printf '%s' "$ACCOUNT" | tr a-f A-F)" "${ACCOUNT}0" "${ACCOUNT%?}" "${ACCOUNT%?}g" 12345; do
  vload "ADAPTER_SET_WORKER=my-site ADAPTER_SET_ACCOUNT_ID=$a"; check "$t: account_id '$a': refused, by name" "1|$A_RULE" "$got"
done
vload "ADAPTER_SET_ACCOUNT_ID=$ACCOUNT"
check "$t: no worker: refused" '1|site.json: "adapter.worker" is required: the name of the Worker on Cloudflare.' "$got"
vload "ADAPTER_SET_WORKER=my-site"
check "$t: no account_id: refused" '1|site.json: "adapter.account_id" is required: the Cloudflare account'"'"'s id.' "$got"
vload "ADAPTER_SET_WORKER=my-site ADAPTER_SET_ACCOUNT_ID=$ACCOUNT ADAPTER_SET_ZONE=example.com"
check "$t: another setting: refused, by name" '1|site.json: "adapter.zone" isn'"'"'t a setting of the cloudflare-workers adapter (its two are worker and account_id).' "$got"
vload "ADAPTER_SET_WORKER=My ADAPTER_SET_ACCOUNT_ID=x"; check "$t: both wrong: both said, one line each" "1|$W_RULE|$A_RULE" "$got"
# Through a publish: refused before anything is exported, the first problem in the status, every one in the log.
newcase; site_json cloudflare-workers '"worker": "My_Site", "account_id": "x"'; commit "bad settings"; pub; t="cloudflare-workers, both settings wrong"
check "$t: exits 1" 1 "$code"; check "$t: the status names the first" "site.json has a problem: ${W_RULE%.}; nothing was published." "$(js message)"
contains "$t: the log has both" "$A_RULE" "$(cat "$c/var/publish.log")"; no_docker "$t"; nocommit "$t"; oldsite "$t"

# adapter_prepare: _redirects and _headers, exactly; the checks pass with them,
# and refuse the same names from the export.
cf_case; cfpub --no-push; t="cloudflare-workers: its own files"
check "$t: committed, not pushed" "0|Committed, not pushed (--no-push)." "$code|$(js message)"
check "$t: _redirects, exactly" "$(printf '/feed /feed/ 301\n/feed/ /feed/index.xml 200\n' | git -C "$c" hash-object --stdin)" "$(git -C "$c" rev-parse HEAD:site/_redirects 2>&1)"
check "$t: _headers, exactly" \
  "$(printf '/feed/\n  Content-Type: application/rss+xml; charset=utf-8\n/feed/index.xml\n  Content-Type: application/rss+xml; charset=utf-8\n/offprint.json\n  Cache-Control: no-store\n' | git -C "$c" hash-object --stdin)" \
  "$(git -C "$c" rev-parse HEAD:site/_headers 2>&1)"
check "$t: offprint.json names the publish (both files in it)" "$(id_blob "$(id_of HEAD)")" "$(git -C "$c" rev-parse HEAD:site/offprint.json 2>&1)"
check "$t: nothing was uploaded (--no-push)" 0 "$(calls node.runs)"
for f in _headers _REDIRECTS Offprint.json; do
  cf_case; echo planted > "$S/fixture/$f"; cfpub --dry-run; t="cloudflare-workers: $f in the export"
  lower="$(printf '%s' "$f" | tr A-Z a-z)"
  check "$t: refused" "1|The export failed the checks, nothing was published: the publish writes $lower at the root, so the export can't have one: ./$f" "$code|$(js message)"
done

# adapter_deploy, the whole way: what node is given, where it runs, and what it uploads.
cf_case
for tool in git php rm mkfifo mktemp pgrep awk sleep cat; do
  real="$(command -v "$tool")"
  printf '#!/bin/sh\n[ -z "${CLOUDFLARE_API_TOKEN+x}" ] || echo %s >> "$STUB_DIR/token.env"\nexec "%s" "$@"\n' "$tool" "$real" > "$S/bin/$tool"
  chmod +x "$S/bin/$tool"
done
# (A function and a variable exported by the publish's caller: neither may reach node.)
offprint_test_fn() { :; }; export -f offprint_test_fn; export OFFPRINT_TEST_VAR=x
cfpub; t="cloudflare-workers, a publish"; sha="$(git -C "$c" rev-parse HEAD)"; work="$(cat "$S/node.cwd" 2>/dev/null)"
export -fn offprint_test_fn; unset -f offprint_test_fn; unset OFFPRINT_TEST_VAR
check "$t: live" "0|live|The site is live at ${sha:0:7}" "$code|$(js state)|$(js message)"; valid "$t"
check "$t: pushed" "$sha" "$(git -C "$O" rev-parse main)"
check "$t: node ran once" 1 "$(calls node.runs)"
check "$t: node was given wrangler's entry script, deploy and --config, the file in its own folder" \
  "$ENTRY|deploy|--config|$work/wrangler.jsonc" "$(paste -sd'|' - < "$S/node.argv")"
case "$work" in "$(cd "$tmp/case$n/tmpdir" && pwd -P)/offprint-cf."??????) ok "$t: it ran in a private folder in TMPDIR" ;; *) bad "$t: it ran in '$work'" ;; esac
check "$t: its environment: exactly the six names" "CI|CLOUDFLARE_ACCOUNT_ID|CLOUDFLARE_API_TOKEN|HOME|PATH|WRANGLER_SEND_METRICS" "$(paste -sd'|' - < "$S/node.env")"
check "$t: their values" "CLOUDFLARE_API_TOKEN=the stored token|CI=true|CLOUDFLARE_ACCOUNT_ID=$ACCOUNT|HOME=$work/home|PATH=$tmp/case$n/node bin:/usr/bin:/bin|WRANGLER_SEND_METRICS=false" \
  "$(paste -sd'|' - < "$S/node.values")"
check "$t: its stdin is empty, and not a terminal" "empty, not a terminal" "$(cat "$S/node.stdin")"
check "$t: the config's four values" "my-site|2026-11-21|$work/site|404-page" \
  "$(php -r '$j = json_decode( (string) file_get_contents( $argv[1] ), true ); echo $j["name"] ?? "-", "|", $j["compatibility_date"] ?? "-", "|", $j["assets"]["directory"] ?? "-", "|", $j["assets"]["not_found_handling"] ?? "-";' "$S/node.config")"
check "$t: and nothing else in it" "name compatibility_date assets|directory not_found_handling" \
  "$(php -r '$j = json_decode( (string) file_get_contents( $argv[1] ), true ); echo implode( " ", array_keys( $j ) ), "|", implode( " ", array_keys( $j["assets"] ) );' "$S/node.config")"
check "$t: what it uploaded is the commit's site/, byte for byte" "$(git -C "$c" rev-parse HEAD:site)" "$(fixture_id "$S/uploaded")"
check "$t: no link in it" "" "$(find "$S/uploaded" -type l)"
check "$t: offprint.json, _headers and _redirects among it" "yes|yes|yes" "$(exists "$S/uploaded/offprint.json")|$(exists "$S/uploaded/_headers")|$(exists "$S/uploaded/_redirects")"
check "$t: nothing it wrote is in the site folder (.wrangler, wrangler.jsonc)" "" "$(find "$c" \( -name .wrangler -o -name wrangler.jsonc -o -name wrangler.log \) -print)"
check "$t: git sees nothing new in the site folder" "" "$(git -C "$c" status --porcelain)"
check "$t: the token was in no other program's environment (git, php, rm, mkfifo, mktemp, pgrep, awk, sleep, cat)" no "$(exists "$S/token.env")"
check "$t: security was asked for the secret cloudflare-token, by argument, once" "find-generic-password -s offprint -a example/cloudflare-token -w" "$(cat "$S/security.argv")"
cf_tmp_empty "$t"; no_leak "$t"
# bash 3.2 writes a here-document or here-string to a file (one the token would then be in): adapter.sh has none.
check "cloudflare-workers: adapter.sh has no here-document or here-string" 0 "$(grep -c '<<' "$SRC/adapters/cloudflare-workers/adapter.sh")"
# The token is read once all but the upload is ready (site/ copied out of the commit, wrangler's settings written, the
# pipes made), so of what adapter_deploy runs only node, and the waits for it, run while it is held: git, php, find,
# mkdir, mkfifo, tr and cut (look-alikes that note running between the Keychain's answer and node's start) all ran
# before. The order of what a person is told stays: wrangler missing, then node, then the token (above).
cf_case
for tool in git php find mkdir mkfifo tr cut; do
  real="$(command -v "$tool")"
  printf '#!/bin/sh\necho %s >> "$STUB_DIR/ran"\n[ ! -e "$STUB_DIR/security.argv" ] || [ -e "$STUB_DIR/node.runs" ] || echo %s >> "$STUB_DIR/held"\nexec "%s" "$@"\n' "$tool" "$tool" "$real" > "$S/bin/$tool"
  chmod +x "$S/bin/$tool"
done
cfpub; t="cloudflare-workers, a publish: what runs while the token is held"
check "$t: live, node given the token" "0|live|1" "$code|$(js state)|$(calls node.runs)"
check "control: $t: git, php, find, mkdir and mkfifo ran" "find git mkdir mkfifo php" "$(sort -u "$S/ran" | grep -vx -e tr -e cut | paste -sd' ' -)"
check "$t: none of them ran between the Keychain's answer and node's start" "" "$(sort -u "$S/held" 2>/dev/null | paste -sd' ' -)"
no_leak "$t"; cf_tmp_empty "$t"

# Review Focus 2: wrangler printing the token, on stdout and stderr, whole, split over two lines and across a 4096-byte
# cut; and a publish run with set -x.
cf_case; touch "$S/node_echo"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 OFFPRINT_HOME="$tmp/case$n/ohome" \
  OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 /bin/bash -x "$SRC/bin/publish" 2>&1)"; code=$?
t="cloudflare-workers, wrangler printing the token, the publish run with set -x"
check "$t: live" "0|live" "$code|$(js state)"
log="$(cat "$c/var/publish.log")"
has "control: $t: set -x traced the publish, and the call of adapter_deploy (in the log)" "adapter_deploy $(git -C "$c" rev-parse HEAD)" "$out$log"
has "$t: the log has what it printed on stdout, the token hidden" "token on stdout: [token hidden]" "$log"
has "$t: and on stderr" "token on stderr: [token hidden]" "$log"
has "$t: the token split over two lines, hidden" "split over two lines: [token hidden]" "$log"
has "$t: and across a 4096-byte cut" "x[token hidden] after a 4096-byte cut" "$log"
if printf '%s' "$log" | grep -qF -e "$TOKEN" -e "$TOKEN_A" -e "$TOKEN_B"; then bad "$t: the log holds the token, or half of it"
else ok "$t: the log holds neither the token nor either half of it"; fi
# The self-check: node was given the token (its value, not just some value), and printed it whole and each half of it
# (read back from its own note, turned round line by line), so the leak checks below are looking for what was there.
printed="$(/usr/bin/perl -ne 'chomp; print scalar(reverse($_)), "\n"' "$S/node.printed.rev" 2>/dev/null)"
check "$t: node was given the stored token" "CLOUDFLARE_API_TOKEN=the stored token" "$(grep '^CLOUDFLARE_API_TOKEN=' "$S/node.values")"
case "$printed" in *"token on stdout: $TOKEN"*) ok "self-check: $t: node printed the whole token on stdout" ;; *) bad "self-check: $t: node printed the whole token on stdout" ;; esac
case "$printed" in *"token on stderr: $TOKEN"*) ok "self-check: $t: and on stderr" ;; *) bad "self-check: $t: and on stderr" ;; esac
case "$printed" in *"$TOKEN_A"*) ok "self-check: $t: so its first half" ;; *) bad "self-check: $t: so its first half" ;; esac
case "$printed" in *"$TOKEN_B"*) ok "self-check: $t: and its second half" ;; *) bad "self-check: $t: and its second half" ;; esac
case "$printed" in *"x${TOKEN} after a 4096-byte cut"*) ok "self-check: $t: and the token across the 4096-byte cut" ;; *) bad "self-check: $t: and the token across the 4096-byte cut" ;; esac
if grep -qF -e "$TOKEN_A" -e "$TOKEN_B" "$S/node.argv" "$S/security.argv"; then bad "$t: node's or security's arguments hold the token"
else ok "$t: neither node's arguments nor security's hold the token"; fi
no_leak "$t"; cf_tmp_empty "$t"

# Each piece it needs, missing: the deploy fails saying what to run, node never runs, the commit stays pushed. Each
# publish after the first has nothing new, and the adapter deploys again (ADAPTER_DEPLOY_AGAIN).
cf_case; rm -rf "$tmp/case$n/ohome/cloudflare-workers/wrangler-4.166.0"; cfpub; t="cloudflare-workers, wrangler not installed"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: failed, naming the set-up" "1|${sha:0:7} is pushed, but the deploy failed: wrangler 4.166.0 isn't installed for Offprint; run offprint adapter setup" "$code|$(js message)"; valid "$t"
check "$t: the commit stays pushed" "$sha" "$(git -C "$O" rev-parse main)"; never_ran "$t"; cf_tmp_empty "$t"
cf_install "$tmp/case$n/ohome"; rm "$tmp/case$n/ohome/cloudflare-workers/node"; cfpub; t="cloudflare-workers, no node recorded"
qcheck "$t: failed, naming the set-up" "1|${sha:0:7} is pushed, but the deploy failed: the node that wrangler runs on isn't set up, or isn't there any more; run offprint adapter setup" "$code|$(js message)"
# (This run pushed nothing: the earlier one did. So the status, and the log, say the commit is pushed, never "Pushed".)
check "$t: a run that pushes nothing: the log says the commit is pushed (each run's line), never that it pushed it" "2|0" \
  "$(grep -c "\[failed\] ${sha:0:7} is pushed, but the deploy failed: " "$c/var/publish.log")|$(grep -c 'Pushed' "$c/var/publish.log")"
never_ran "$t"
mkdir -p "$tmp/case$n/odd:dir"; cp "$NODE" "$tmp/case$n/odd:dir/node"
for bad_node in "$tmp/case$n/no such node" "node" "$tmp/case$n" "$tmp/case$n/odd:dir/node"; do
  printf '%s\n' "$bad_node" > "$tmp/case$n/ohome/cloudflare-workers/node"; cfpub; t="cloudflare-workers, the node recorded is '$bad_node'"
  check "$t: failed, naming the set-up" "1|${sha:0:7} is pushed, but the deploy failed: the node that wrangler runs on isn't set up, or isn't there any more; run offprint adapter setup" "$code|$(js message)"
  never_ran "$t"
done
cf_install "$tmp/case$n/ohome"; touch "$S/secret_missing"; cfpub; t="cloudflare-workers, no token in the Keychain"
check "$t: failed, naming the set-up" "1|${sha:0:7} is pushed, but the deploy failed: the Cloudflare token isn't in the Keychain; run offprint adapter setup" "$code|$(js message)"
never_ran "$t"
rm "$S/secret_missing"; touch "$S/secret_locked"; cfpub; t="cloudflare-workers, the Keychain locked"
check "$t: failed, saying so" "1|${sha:0:7} is pushed, but the deploy failed: the login Keychain is locked, so the Cloudflare token couldn't be read; unlock it, then publish again" "$code|$(js message)"
never_ran "$t"; cf_tmp_empty "$t"
rm "$S/secret_locked"; cfpub; t="cloudflare-workers, every piece there again, nothing new"
check "$t: deployed again, and live" "0|live|1" "$code|$(js state)|$(calls node.runs)"; no_leak "$t"

# wrangler failing: the first line after its [ERROR] marker, the token hidden, colour and control characters taken out,
# at most 200 characters; then the first line after it that starts with two spaces (Cloudflare's reason: below).
cf_case
printf '\033[33m wrangler 4.166.0\033[0m\n\n\033[31m\342\234\230 \033[41;31m[\033[41;97mERROR\033[41;31m]\033[0m \033[1mA request to the Cloudflare API failed: token @TOKEN@ is not valid [code: 10000]\033[0m\n\n  More lines after it.\n' > "$S/node_fail"
cfpub; t="cloudflare-workers, wrangler fails with a coloured [ERROR] line holding the token"; sha="$(git -C "$c" rev-parse HEAD)"
qcheck "$t: failed, with its line, the token hidden, and the indented line after it" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: A request to the Cloudflare API failed: token [token hidden] is not valid [code: 10000]. More lines after it." "$code|$(js message)"
check "$t: the commit stays pushed" "$sha" "$(git -C "$O" rev-parse main)"; no_leak "$t"; cf_tmp_empty "$t"
printf 'Some output\n\342\234\230 [ERROR]\n\n  \033]8;;https://example.com/docs\aThe name\033]8;;\a\tis\001 taken\n' > "$S/node_fail"; cfpub
t="cloudflare-workers, an [ERROR] marker alone on its line, a link and control characters in the next"
check "$t: the next line that isn't blank, made printable" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: The name?is? taken" "$code|$(js message)"
{ printf '\342\234\230 [ERROR] '; printf '%0300d' 0 | tr 0 e; printf '\n'; } > "$S/node_fail"; cfpub; t="cloudflare-workers, an [ERROR] line of 300 characters"
check "$t: cut to 200" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: $(printf '%0200d' 0 | tr 0 e)" "$code|$(js message)"
printf 'Something went wrong, said nothing more\n' > "$S/node_fail"; cfpub; t="cloudflare-workers, wrangler fails without an [ERROR] line"
check "$t: says so" "1|${sha:0:7} is pushed, but the deploy failed: the upload failed: wrangler ended with status 1 and printed no [ERROR] line; see var/publish.log" "$code|$(js message)"
has "$t: what it printed is in the log" "Something went wrong, said nothing more" "$(cat "$c/var/publish.log")"
no_leak "$t"; cf_tmp_empty "$t"

# What a real run of wrangler 4.166.0 printed (stdout and stderr as var/publish.log had them, verbatim; the account id
# and the Worker's name are this suite's) when Cloudflare refused the upload: A, for a token without the Workers
# permission; B, for an account id the token can't use. B goes on to list the token's accounts, by name and id (a real
# account's name held its owner's email address). The reason is the [ERROR] marker's line and Cloudflare's own reason,
# the first line after it that starts with two spaces (not B's next line, which starts with a paperclip; and not the
# "If you think this is a bug" line), then a hint chosen by that reason; all of it within the 300 characters the status
# keeps (the marker line's API path, in parentheses, goes first when it doesn't fit: var/publish.log has it). And the
# list of accounts, from "Getting User settings..." to the table's closing line, is left out of the log, one line saying
# so in its place; nothing else is.
SHAPE_A="$(cat <<'WRANGLER'

 ⛅️ wrangler 4.166.0
────────────────────
✘ [ERROR] A request to the Cloudflare API (/accounts/@ACCOUNT@/workers/services/my-site) failed.

  No access to the specified service.

  If you think this is a bug, please open an issue at: https://github.com/cloudflare/workers-sdk/issues/new/choose



🪵  Logs were written to "TMP/offprint-cf.XXXXXX/home/Library/Preferences/.wrangler/logs/wrangler-2026-11-23_18-58-14_311.log"
WRANGLER
)"
SHAPE_B_TOP="$(cat <<'WRANGLER'

 ⛅️ wrangler 4.166.0
────────────────────

✘ [ERROR] A request to the Cloudflare API (/accounts/@ACCOUNT@/workers/services/my-site) failed.

📎 It looks like you are authenticating Wrangler via a custom API token set in an environment variable.
  Authentication error [code: 10000]
Please ensure it has the correct permissions for this operation.
WRANGLER
)"
GAP=$'\n'   # (with a line end each side, the two blank lines after SHAPE_B_TOP, which $( ) would take off its end)
SHAPE_B_LIST="$(cat <<'WRANGLER'
Getting User settings...
👋 You are logged in with an User API Token. Unable to retrieve email for this user. Are you missing the `User->User Details->Read` permission?
ℹ️  The API Token is read from the CLOUDFLARE_API_TOKEN environment variable.
┌──────────────┬──────────────────────────────────┐
│ Account Name │ Account ID                       │
├──────────────┼──────────────────────────────────┤
│ My Account   │ @ACCOUNT@ │
└──────────────┴──────────────────────────────────┘
WRANGLER
)"
SHAPE_B_END="$(cat <<'WRANGLER'

🔓 To see token permissions visit https://dash.cloudflare.com/profile/api-tokens
🪵  Logs were written to "TMP/offprint-cf.XXXXXX/home/Library/Preferences/.wrangler/logs/wrangler-2026-11-23_19-02-41_877.log"
WRANGLER
)"
SHAPE_A="${SHAPE_A//@ACCOUNT@/$ACCOUNT}"; SHAPE_B_TOP="${SHAPE_B_TOP//@ACCOUNT@/$ACCOUNT}"; SHAPE_B_LIST="${SHAPE_B_LIST//@ACCOUNT@/$ACCOUNT}"
LEFT_OUT="offprint: wrangler's list of the token's accounts was left out of this log"
REFUSED="Cloudflare refused the upload: A request to the Cloudflare API failed."
HINT_A="The token lacks the permission Account → Workers Scripts → Edit for this site's account: edit the token, or run offprint adapter setup with one that has it"
HINT_B="Either account_id in site.json isn't an account the token belongs to, or the token lacks the permission Account → Workers Scripts → Edit: offprint adapter doctor tells which"
# wrangler_log: what the stand-in wrangler printed, as the log has it: from its first line (its banner's blank line,
# then the banner) to the publish's own line after it, the [failed] status
wrangler_log() { awk '/ ⛅️ wrangler 4\.166\.0/ { on = 1; print prev } on && /^[0-9TZ:-]+ \[failed\] / { exit } on { print } { prev = $0 }' "$c/var/publish.log"; }
cf_case; printf '%s\n' "$SHAPE_A" > "$S/node_fail"; cfpub; t="cloudflare-workers, wrangler as a real run printed it: a token without the Workers permission"
sha="$(git -C "$c" rev-parse HEAD)"; msg="$(js message)"
check "$t: the marker's line, Cloudflare's reason, and what to do" "1|${sha:0:7} is pushed, but the deploy failed: $REFUSED No access to the specified service. $HINT_A" "$code|$msg"
check "$t: the reason fits in the 300 characters the status keeps" yes "$(r="${msg#*deploy failed: }"; [ "$(LC_ALL=C; printf '%s' "${#r}")" -le 300 ] && echo yes || echo no)"
check "$t: the log has all wrangler printed, as it printed it" "$SHAPE_A" "$(wrangler_log)"
lacks "$t: nothing said left out of it" "$LEFT_OUT" "$(cat "$c/var/publish.log")"
no_leak "$t"; cf_tmp_empty "$t"
cf_case; printf '%s\n%s\n%s\n%s\n' "$SHAPE_B_TOP" "$GAP" "$SHAPE_B_LIST" "$SHAPE_B_END" > "$S/node_fail"; cfpub
t="cloudflare-workers, wrangler as a real run printed it: an account id the token can't use"; sha="$(git -C "$c" rev-parse HEAD)"; msg="$(js message)"
check "$t: the marker's line, Cloudflare's reason (not the paperclip line before it), and what to do" "1|${sha:0:7} is pushed, but the deploy failed: $REFUSED Authentication error [code: 10000]. $HINT_B" "$code|$msg"
check "$t: the reason fits in the 300 characters the status keeps" yes "$(r="${msg#*deploy failed: }"; [ "$(LC_ALL=C; printf '%s' "${#r}")" -le 300 ] && echo yes || echo no)"
check "$t: the log has the rest of what wrangler printed, the list of accounts replaced by one line" "$SHAPE_B_TOP
$GAP
$LEFT_OUT
$SHAPE_B_END" "$(wrangler_log)"
for l in "Getting User settings" "You are logged in" "The API Token is read" "My Account" "Account Name" "┌" "└"; do
  lacks "$t: the log has no '$l'" "$l" "$(cat "$c/var/publish.log")"
done
no_leak "$t"; cf_tmp_empty "$t"
# The same, its streams as wrangler writes them: the [ERROR] block on stderr, the rest on stdout, interleaved.
cf_case
{ printf '1 %s\n' "" " ⛅️ wrangler 4.166.0" "────────────────────" ""
  printf '2 %s\n' "✘ [ERROR] A request to the Cloudflare API (/accounts/$ACCOUNT/workers/services/my-site) failed." "" \
    "  Authentication error [code: 10000]" "" ""
  printf '1 %s\n' "📎 It looks like you are authenticating Wrangler via a custom API token set in an environment variable." \
    "Please ensure it has the correct permissions for this operation." "" ""
  printf '%s\n%s\n' "$SHAPE_B_LIST" "$SHAPE_B_END" | sed -e '$d' -e 's/^/1 /'
  printf '2 %s\n' "$(printf '%s\n' "$SHAPE_B_END" | tail -n 1)"; } > "$S/node_says"
cfpub; t="cloudflare-workers, wrangler's [ERROR] block on stderr and the rest on stdout"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the same reason and hint" "1|${sha:0:7} is pushed, but the deploy failed: $REFUSED Authentication error [code: 10000]. $HINT_B" "$code|$(js message)"
check "$t: one line says the list was left out" 1 "$(grep -cxF "$LEFT_OUT" "$c/var/publish.log")"
for l in "Getting User settings" "My Account" "┌" "└"; do lacks "$t: the log has no '$l'" "$l" "$(cat "$c/var/publish.log")"; done
for l in "📎 It looks like" "Please ensure it has" "  Authentication error [code: 10000]" "🔓 To see token permissions" "🪵  Logs were written"; do
  has "$t: the log still has '$l'" "$l" "$(cat "$c/var/publish.log")"
done
no_leak "$t"; cf_tmp_empty "$t"
# A table that never closes: everything from "Getting User settings..." to the end of what wrangler printed is left out.
cf_case
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$(printf '%s\n' "$SHAPE_B_LIST" | sed -n '1,4p')" "│ Account Name                │ Account ID                       │" \
  "├─────────────────────────────┼──────────────────────────────────┤" "│ owner@example.com's Account │ $ACCOUNT │" "" \
  "🔓 To see token permissions visit https://dash.cloudflare.com/profile/api-tokens" "a last line, after it" > "$S/list"
printf '%s\n%s\n%s\n' "$SHAPE_B_TOP" "$GAP" "$(cat "$S/list")" > "$S/node_fail"; rm -f "$S/list"; cfpub
t="cloudflare-workers, wrangler's list of accounts, its table never closed"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the same reason and hint" "1|${sha:0:7} is pushed, but the deploy failed: $REFUSED Authentication error [code: 10000]. $HINT_B" "$code|$(js message)"
check "$t: the log has what came before it, then one line saying it was left out, and nothing after (fail closed)" "$SHAPE_B_TOP
$GAP
$LEFT_OUT" "$(wrangler_log)"
for l in "owner@example.com" "🔓 To see" "a last line, after it"; do lacks "$t: the log has no '$l'" "$l" "$(cat "$c/var/publish.log")"; done
no_leak "$t"; cf_tmp_empty "$t"
# A row of the table holding the token, and a row that looks like the table's closing line (an account named so): the
# list is still left out up to the real closing line, and the token is nowhere.
cf_case
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$SHAPE_B_TOP" "$GAP" "$(printf '%s\n' "$SHAPE_B_LIST" | sed '$d')" "│ └────────────┘ │ $ACCOUNT │" \
  "│ @TOKEN@ │ $ACCOUNT │" "$(printf '%s\n' "$SHAPE_B_LIST" | tail -n 1)" "$SHAPE_B_END" > "$S/node_fail"; cfpub
t="cloudflare-workers, wrangler's list of accounts with the token in a row, and a row like its closing line"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the same reason and hint" "1|${sha:0:7} is pushed, but the deploy failed: $REFUSED Authentication error [code: 10000]. $HINT_B" "$code|$(js message)"
check "$t: the log has the rest of what wrangler printed, the list replaced by one line" "$SHAPE_B_TOP
$GAP
$LEFT_OUT
$SHAPE_B_END" "$(wrangler_log)"
lacks "$t: the log has no row of the table" "│" "$(cat "$c/var/publish.log")"
no_leak "$t"; cf_tmp_empty "$t"
# Cloudflare's reason holding the token: hidden. No hint for a reason that isn't one of the two.
cf_case
printf '✘ [ERROR] A request to the Cloudflare API (/accounts/%s/workers/services/my-site) failed.\n\n  The token @TOKEN@ was refused [code: 9109]\n\n' "$ACCOUNT" > "$S/node_fail"; cfpub
t="cloudflare-workers, Cloudflare's reason holding the token"; sha="$(git -C "$c" rev-parse HEAD)"
qcheck "$t: the marker's line and the reason, the token hidden, no hint" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: A request to the Cloudflare API (/accounts/$ACCOUNT/workers/services/my-site) failed. The token [token hidden] was refused [code: 9109]" "$code|$(js message)"
no_leak "$t"; cf_tmp_empty "$t"
# A marker with no line after it that starts with two spaces, or only the "If you think this is a bug" one: the marker's
# line alone, as before.
printf '✘ [ERROR] Something failed.\n\nA plain line after it.\n' > "$S/node_fail"; cfpub; t="cloudflare-workers, an [ERROR] line with no indented line after it"
check "$t: the marker's line alone" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: Something failed." "$code|$(js message)"
printf '✘ [ERROR] Something failed.\n\n  If you think this is a bug, please open an issue at: https://github.com/cloudflare/workers-sdk/issues/new/choose\n\n' > "$S/node_fail"; cfpub
t="cloudflare-workers, an [ERROR] line with only the bug-report line after it"
check "$t: the marker's line alone" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: Something failed." "$code|$(js message)"
# Long ones: the marker's line is cut (with ...) so that Cloudflare's reason fits whole.
{ printf '✘ [ERROR] '; printf '%0200d' 0 | tr 0 m; printf '\n\n  '; printf '%0150d' 0 | tr 0 r; printf '\n'; } > "$S/node_fail"; cfpub
t="cloudflare-workers, an [ERROR] line of 200 characters, and a reason of 150"
check "$t: the marker's line cut, the reason whole, 300 characters in all" \
  "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: $(printf '%0115d' 0 | tr 0 m)... $(printf '%0150d' 0 | tr 0 r)" "$code|$(js message)"
no_leak "$t"; cf_tmp_empty "$t"

# Fix round 1 (M1 to M4). What is left out of the log: a line that IS "Getting User settings..." starts the drop (never
# one that holds the words: wrangler prints each asset's path, and WordPress names the files); and, on every stream, a
# line whose first character that isn't a space is box-drawn, or a waving hand, is always left out; one line in place of
# what a stream left out. The reason is looked for only in the marker's own block.
wlog() { cat "$c/var/publish.log"; }
has_fffd() { case "$1" in *�*) echo yes ;; *) echo no ;; esac; }
hint_whole_or_none() { case "$1" in *"$HINT_B") echo yes ;; *Either*) echo no ;; *) echo yes ;; esac; }
nlines() { printf '%s\n' "$2" | grep -cxF -- "$1"; }
# M1: an asset's line that holds the words
cf_case
{ printf '1 %s\n' "🌀 Starting asset upload..." "+ /Getting User settings....html" "+ /about/index.html" "✨ Success! Uploaded 2 files"
  printf '2 %s\n' "✘ [ERROR] Something failed." "" "  No access to the specified service." ""; } > "$S/node_says"
cfpub; t="cloudflare-workers, an uploaded file named like wrangler's accounts line"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the marker's line, the reason and the hint" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: Something failed. No access to the specified service. $HINT_A" "$code|$(js message)"
for l in "+ /Getting User settings....html" "+ /about/index.html" "✨ Success! Uploaded 2 files" "✘ [ERROR] Something failed."; do
  has "$t: the log still has '$l'" "$l" "$(wlog)"
done
lacks "$t: nothing said left out" "$LEFT_OUT" "$(wlog)"
no_leak "$t"; cf_tmp_empty "$t"
# The line itself, with a carriage return or spaces after it, starts the drop; with anything else it doesn't. One line
# says so for a stream, however many lists it left out.
cf_case
{ printf '1 %s\n' "Getting User settings...   " "┌──┐" "│ x │" "└──┘" "after the first"
  printf '1 %s\n' "Getting User settings...extra" "kept, a line after it"
  printf '1 Getting User settings...\r\n'; printf '1 %s\n' "│ a row │" "└──┘" "after the second"
  printf '2 %s\n' "✘ [ERROR] Something failed."; } > "$S/node_says"
cfpub; t="cloudflare-workers, the accounts line with spaces or a carriage return after it, and with more"
for l in "after the first" "Getting User settings...extra" "kept, a line after it" "after the second"; do has "$t: the log has '$l'" "$l" "$(wlog)"; done
lacks "$t: no row" "│" "$(wlog)"
check "$t: one line says so (one stream; not for the line with more)" 1 "$(nlines "$LEFT_OUT" "$(wlog)")"
no_leak "$t"; cf_tmp_empty "$t"
# M2: the list on another stream than its first line, in the three splits; every one leaves out each account.
ROW2="│ owner@example.com's Account │ 11111111111111111111111111111111 │"
# (The account ids in the rows are not the one in wrangler's marker line, which the log keeps whole.)
split_case() {  # split_case END S1 ... S9: SHAPE_B's top on stderr, then each of the list's 9 lines on the stream given (1 or
  # 2), then its last lines on stream END (a stream that is still leaving out a list to its end leaves them out too)
  local i=-1 l w end="$1"; cf_case; shift
  { printf '%s\n' "$SHAPE_B_TOP" | sed 's/^/2 /'; printf '2 %s\n' "" ""
    printf '%s\n' "Getting User settings..." "👋 You are logged in with an User API Token. Unable to retrieve email for this user." \
      "ℹ️  The API Token is read from the CLOUDFLARE_API_TOKEN environment variable." "┌──────────────┬──────────────────────────────────┐" \
      "│ Account Name │ Account ID                       │" "├──────────────┼──────────────────────────────────┤" \
      "│ My Account   │ 22222222222222222222222222222222 │" "$ROW2" "└──────────────┴──────────────────────────────────┘" | while IFS= read -r l; do
        i=$((i + 1)); eval "w=\${$((i + 1))}"; printf '%s %s\n' "$w" "$l"; done
    printf "$end %s\n" "" "🔓 To see token permissions visit https://dash.cloudflare.com/profile/api-tokens" "🪵  Logs were written to \"x.log\""; } > "$S/node_says"
}
for spec in "Getting on stderr, the rest on stdout:1 2 1 1 1 1 1 1 1 1" "Getting, the hand and the info on stdout, the table on stderr:2 1 1 1 2 2 2 2 2 2" "header rows on stdout, data rows on stderr:2 1 1 1 1 1 1 2 2 2"; do
  split_case ${spec#*:}; cfpub; t="cloudflare-workers, wrangler's list of accounts split over the streams (${spec%%:*})"; sha="$(git -C "$c" rev-parse HEAD)"
  check "$t: the same reason and hint" "1|${sha:0:7} is pushed, but the deploy failed: $REFUSED Authentication error [code: 10000]. $HINT_B" "$code|$(js message)"
  for l in "My Account" "owner@example.com" "22222222222222222222222222222222" "11111111111111111111111111111111" "Account Name" "┌" "├" "└" "│" "👋"; do
    lacks "$t: the log has no '$l'" "$l" "$(wlog)"; lacks "$t: nor has the status" "$l" "$(cat "$c/var/status.json")"
  done
  for l in "🔓 To see token permissions" "🪵  Logs were written" "📎 It looks like"; do has "$t: the log still has '$l'" "$l" "$(wlog)"; done
  check "$t: at most one line saying so per stream, and at least one" yes "$(k="$(nlines "$LEFT_OUT" "$(wlog)")"; [ "$k" -ge 1 ] && [ "$k" -le 2 ] && echo yes || echo no)"
  no_leak "$t"; cf_tmp_empty "$t"
done
# The same, in a UTF-8 locale (the publish may run under any, or none, as under launchd).
split_case 1 2 1 1 1 1 1 1 1 1; LC_ALL=en_US.UTF-8 cfpub; t="cloudflare-workers, wrangler's list of accounts split over the streams, under LC_ALL=en_US.UTF-8"
for l in "My Account" "owner@example.com" "22222222222222222222222222222222" "┌" "└" "│"; do lacks "$t: the log has no '$l'" "$l" "$(wlog)"; done
for l in "🔓 To see token permissions" "🪵  Logs were written"; do has "$t: the log still has '$l'" "$l" "$(wlog)"; done
no_leak "$t"; cf_tmp_empty "$t"
# A table of several accounts with nothing before it; a hand line holding an address, with no "Getting" line at all; an
# indented row; none of them takes the lines around it: the error block, a file's line and the logs line are kept.
cf_case
{ printf '2 %s\n' "✘ [ERROR] Something failed." "" "  │ an indented row, owner-of-it@example.com │" "  No access to the specified service." ""
  printf '2 %s\n' "👋 You are logged in as me@example.com." "  │ an indented row, my-other-account@example.com │" "┌──┬──┐" "│ Account Name │ Account ID │" "├──┼──┤" \
    "│ One │ 1 │" "│ Two │ 2 │" "│ Three │ 3 │" "└──┴──┘" "+ /a | b.html" "🪵  Logs were written to \"x.log\""; } > "$S/node_says"
cfpub; t="cloudflare-workers, a table and a hand line outside any 'Getting' block"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the reason and hint" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: Something failed. No access to the specified service. $HINT_A" "$code|$(js message)"
for l in "me@example.com" "my-other-account" "owner-of-it" "One" "Two" "Three" "Account Name" "│" "┌" "└" "├" "👋"; do lacks "$t: the log has no '$l'" "$l" "$(wlog)"; done
for l in "✘ [ERROR] Something failed." "  No access to the specified service." "+ /a | b.html" "🪵  Logs were written"; do has "$t: the log has '$l'" "$l" "$(wlog)"; done
check "$t: one line says so (one stream)" 1 "$(nlines "$LEFT_OUT" "$(wlog)")"
lacks "$t: nor has the status the indented row (an indented line that the log leaves out is no reason)" "owner-of-it" "$(cat "$c/var/status.json")"
no_leak "$t"; cf_tmp_empty "$t"
# CRLF line ends all through.
cf_case
{ printf '✘ [ERROR] A request failed.\r\n\r\n  Authentication error [code: 10000]\r\n\r\nGetting User settings...\r\n'
  printf '%s\r\n' "👋 You are logged in as me@example.com." "┌──┐" "│ My Account │ $ACCOUNT │" "└──┘" "" "🔓 To see token permissions" "🪵  Logs were written to \"x.log\""; } > "$S/node_fail"
cfpub; t="cloudflare-workers, wrangler's output with CRLF line ends"
for l in "My Account" "me@example.com" "$ACCOUNT" "│" "👋"; do lacks "$t: the log has no '$l'" "$l" "$(wlog)"; done
for l in "🔓 To see token permissions" "🪵  Logs were written"; do has "$t: the log has '$l'" "$l" "$(wlog)"; done
check "$t: one line says so" 1 "$(nlines "$LEFT_OUT" "$(wlog)")"
no_leak "$t"; cf_tmp_empty "$t"
# M3: the reason is looked for only in the marker's own block.
cf_case
{ printf '2 %s\n' "✘ [ERROR] First thing failed." "" "📎 a note on another line" "" "✘ [ERROR] A request failed." "" "  No access to the specified service." ""; } > "$S/node_says"
cfpub; t="cloudflare-workers, two [ERROR] markers, the first with no indented line after it"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the first marker's line alone: the second's reason and hint are not attached" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: First thing failed." "$code|$(js message)"
no_leak "$t"; cf_tmp_empty "$t"
cf_case
{ printf '2 %s\n' "✘ [ERROR] First thing failed." ""
  printf '2 %s\n' "▲ [WARNING] A warning." "" "  No access to the specified service."; } > "$S/node_says"
cfpub; t="cloudflare-workers, an [ERROR] marker, then a [WARNING] marker with an indented line"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the marker's line alone" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: First thing failed." "$code|$(js message)"
cf_case
{ printf '2 %s\n' "✘ [ERROR] A request failed." ""
  printf '1 %s\n' "Getting User settings..." "┌──┐" "│ My Account │ $ACCOUNT │" "└──┘" "" "🔓 To see token permissions"
  printf '2 %s\n' "  Authentication error [code: 10000]"; } > "$S/node_says"
cfpub; t="cloudflare-workers, an indented line after the accounts table and no note under the marker"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: not taken as the reason" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: A request failed." "$code|$(js message)"
cf_case
{ printf '2 %s\n' "✘ [ERROR] A request failed." "" "🪵  Logs were written to \"x.log\"" "  Authentication error [code: 10000]"; } > "$S/node_says"
cfpub; t="cloudflare-workers, an indented line after the logs line"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: not taken as the reason" "1|${sha:0:7} is pushed, but the deploy failed: Cloudflare refused the upload: A request failed." "$code|$(js message)"
# M4: a long reason: the hint is whole or not there, and the status is valid UTF-8 JSON.
cf_case
{ printf '✘ [ERROR] A request to the Cloudflare API (/accounts/%s/workers/services/my-site) failed.\n\n  ' "$ACCOUNT"; printf '%0116d' 0 | tr 0 r; printf ' [code: 10000]\n'; } > "$S/node_fail"
cfpub; t="cloudflare-workers, a reason of 130 bytes ending [code: 10000]"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: the hint is left off whole, the reason whole" "1|${sha:0:7} is pushed, but the deploy failed: $REFUSED $(printf '%0116d' 0 | tr 0 r) [code: 10000]" "$code|$(js message)"
check "$t: status.json is valid UTF-8" 0 "$(iconv -f UTF-8 -t UTF-8 "$c/var/status.json" > /dev/null 2>&1; echo $?)"
lacks "$t: no replacement character in it" "�" "$(cat "$c/var/status.json")"
lacks "$t: no half hint" "Either" "$(cat "$c/var/status.json")"
no_leak "$t"; cf_tmp_empty "$t"
for k in 60 80 100 125 140 160 190; do
  cf_case; { printf '✘ [ERROR] A request to the Cloudflare API (/accounts/%s/workers/services/my-site) failed.\n\n  ' "$ACCOUNT"; printf "%0${k}d" 0 | tr 0 r; printf ' [code: 10000]\n'; } > "$S/node_fail"; cfpub
  t="cloudflare-workers, a reason of $((k + 14)) bytes ending [code: 10000]"; msg="$(js message)"
  check "$t: valid UTF-8, no replacement character" "0|no" "$(iconv -f UTF-8 -t UTF-8 "$c/var/status.json" > /dev/null 2>&1; echo -n $?)|$(has_fffd "$msg")"
  check "$t: the hint is whole or not there" yes "$(hint_whole_or_none "$msg")"
  check "$t: within 300 bytes" yes "$(r="${msg#*deploy failed: }"; [ "$(LC_ALL=C; printf '%s' "${#r}")" -le 300 ] && echo yes || echo no)"
done

# wrangler hanging: stopped at the limit (OFFPRINT_WRANGLER_TIMEOUT cuts it to 2 seconds), the whole tree, even one that
# ignores TERM. While it hangs, no process has the token in its arguments.
cf_case; touch "$S/node_hang" "$S/node_stubborn"; start=$SECONDS
( cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 OFFPRINT_HOME="$tmp/case$n/ohome" \
  OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 OFFPRINT_WRANGLER_TIMEOUT=2 \
  exec /bin/bash "$SRC/bin/publish" > "$S/pub.out" 2>&1 ) & pid=$!
i=0; while [ ! -e "$S/node.hanging" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
t="cloudflare-workers, wrangler hanging"
check "control: $t: it hangs" yes "$(exists "$S/node.hanging")"
procs="$(ps -A -ww -o args= 2>/dev/null)"
leaked=no; for p in "$TOKEN_A" "$TOKEN_B" $TOKEN_PIECES; do case "$procs" in *"$p"*) leaked=yes ;; esac; done
check "$t: no process has the token, or any part of it, in its arguments" no "$leaked"
wait "$pid"; code=$?; out="$(cat "$S/pub.out")"
check "$t: failed at the limit" "1|$(short) is pushed, but the deploy failed: wrangler hadn't finished the upload after 2 seconds, so it was stopped; see var/publish.log" "$code|$(js message)"
check "$t: soon" yes "$([ $((SECONDS - start)) -lt 30 ] && echo yes || echo no)"
i=0; while [ -n "$(pgrep -f 'sleep 47')" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
check "$t: node and its child are stopped" "" "$(pgrep -f 'sleep 47')"
cf_tmp_empty "$t"; no_leak "$t"

# A TERM to the publish while wrangler runs: it stops, the whole tree with it, and the private folder goes.
cf_case; touch "$S/node_hang" "$S/node_stubborn"
( cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 OFFPRINT_HOME="$tmp/case$n/ohome" \
  OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 \
  exec /bin/bash "$SRC/bin/publish" > "$S/pub.out" 2>&1 ) & pid=$!
i=0; while [ ! -e "$S/node.hanging" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
t="cloudflare-workers, a TERM while wrangler runs"
check "control: $t: it runs" yes "$(exists "$S/node.hanging")"
kill -TERM "$pid"; i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$pid" 2>/dev/null; then bad "$t: the publish stopped within 10 seconds"; kill -KILL "$pid" 2>/dev/null; else ok "$t: the publish stopped within 10 seconds"; fi
wait "$pid" 2>/dev/null; out="$(cat "$S/pub.out")"
check "$t: the status is failed, and final" "failed|false" "$(js state)|$(js running)"
check "$t: the lock is released" no "$(exists "$c/var/publish.lock")"
i=0; while { [ -n "$(ls -A "$tmp/case$n/tmpdir")" ] || [ -n "$(pgrep -f 'sleep 47')" ]; } && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
check "$t: node and its child are stopped" "" "$(pgrep -f 'sleep 47')"
cf_tmp_empty "$t"; no_leak "$t"

# Review Focus 4: under launchd's PATH (no node on it) node is reached by the path set-up recorded; and with
# OFFPRINT_HOME unset, the Offprint folder is ~/Library/Application Support/Offprint, whatever HOME is.
cf_case; mkdir -p "$tmp/case$n/phpbin"; ln -s "$(command -v php)" "$tmp/case$n/phpbin/php"; t="cloudflare-workers, PATH=/usr/bin:/bin (and the stand-ins, and php)"
check "control: $t: there is no node on it" "" "$(PATH="$S/bin:$tmp/bin:$tmp/case$n/phpbin:/usr/bin:/bin"; command -v node)"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$tmp/case$n/phpbin:/usr/bin:/bin" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 \
  OFFPRINT_HOME="$tmp/case$n/ohome" OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 /bin/bash "$SRC/bin/publish" 2>&1)"; code=$?
check "$t: live, through the node recorded" "0|live|1" "$code|$(js state)|$(calls node.runs)"
cf_case; mkdir -p "$tmp/case$n/home/Library/Application Support"; mv "$tmp/case$n/ohome" "$tmp/case$n/home/Library/Application Support/Offprint"
HOME="$tmp/case$n/home" OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 pub; t="cloudflare-workers, OFFPRINT_HOME unset, HOME elsewhere"
check "$t: live, wrangler found in HOME/Library/Application Support/Offprint" "0|live|1" "$code|$(js state)|$(calls node.runs)"
check "$t: node's HOME is its private folder all the same" "HOME=$(cat "$S/node.cwd")/home" "$(grep '^HOME=' "$S/node.values")"
# The private folder is never inside the site folder, where WordPress can write (var/, say): such a TMPDIR is refused as
# soon as the site folder is known (lib/site.sh), and the upload's own folder is refused the same way
# (offprint_private_dir, the second layer), should the deploy be reached with one (TMPDIR changed after the load, here:
# the site folder's own name in another letter case where the disk ignores it, else through a link).
cf_case; mkdir -p "$c/var/tmp"; OFFPRINT_HOME="$tmp/case$n/ohome" OFFPRINT_SECURITY="$tmp/security" TMPDIR="$c/var/tmp" PUBLISH_TIMEOUT_SECONDS=1 pub
t="cloudflare-workers, TMPDIR inside the site folder"
check "$t: refused as soon as the site folder is known" "2|TMPDIR is $c/var/tmp, inside the site folder $(cd "$c" && pwd -P), which WordPress can write; unset TMPDIR, or point it at a folder outside the site folder." "$code|$out"
never_ran "$t"; no_docker "$t"; check "$t: nothing left in it" "" "$(ls -A "$c/var/tmp")"
ln -s "$c/var/tmp" "$tmp/case$n/via"; inside="$tmp/case$n/via"; [ ! "${c%/repo}/REPO/var/tmp" -ef "$c/var/tmp" ] || inside="${c%/repo}/REPO/var/tmp"
OFFPRINT_HOME="$tmp/case$n/ohome" OFFPRINT_SECURITY="$tmp/security" STUB_DIR="$S" INSIDE="$inside" CID="$(git -C "$c" rev-parse HEAD)" \
  load 'TMPDIR="$INSIDE"; offprint_adapter_call adapter_deploy "$CID"; echo "deploy=$?|$ADAPTER_PROBLEM"'
t="adapter_deploy reached with TMPDIR inside the site folder ($([ "$inside" = "$tmp/case$n/via" ] && echo "through a link" || echo "REPO/var/tmp: the site folder's name in another letter case"))"
check "$t: refused, saying so" "deploy=1|no private folder could be made for the upload: TMPDIR is inside the site folder, which WordPress can write; a private folder must be outside it; nothing was uploaded" "$(printf '%s\n' "$out" | grep '^deploy=')"
never_ran "$t"; check "$t: nothing left in it" "" "$(ls -A "$c/var/tmp")"

# Review Focus 1: the upload works and the live site never shows the publish: failed with the hint, nothing undone; the
# next publish, with nothing new, asks again, uploads again, and is live only once the live site shows it.
cf_case; touch "$S/node_nolive"; cfpub; t="cloudflare-workers, the upload works, the live site never shows it"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: failed, with the hint" "1|${sha:0:7} is pushed, but the live site hasn't shown it after 1 seconds (it couldn't be reached); run offprint adapter doctor" "$code|$(js message)"
check "$t: the commit stays pushed" "$sha" "$(git -C "$O" rev-parse main)"; check "$t: uploaded once" 1 "$(calls node.runs)"
rm -f "$S/curl.calls"; cfpub; t="cloudflare-workers, the same, then a publish with nothing new"
check "$t: failed again, with the hint" "1|${sha:0:7} is pushed, but the live site hasn't shown it after 1 seconds (it couldn't be reached); run offprint adapter doctor" "$code|$(js message)"
check "$t: the live site was asked first, for the publish's offprint.json" "-fsS --max-time 10 https://www.example.com/offprint.json?p=$(id_of HEAD)" "$(head -n 1 "$S/curl.calls")"
check "$t: uploaded again" 2 "$(calls node.runs)"; check "$t: no new commit" "$sha" "$(git -C "$c" rev-parse HEAD)"
rm "$S/node_nolive"; cfpub; t="cloudflare-workers, the same, once an upload reaches the live site"
check "$t: live" "0|live|The site is live at ${sha:0:7}|3" "$code|$(js state)|$(js message)|$(calls node.runs)"
cfpub; t="cloudflare-workers, the same, again"
check "$t: unchanged, not uploaded again" "0|unchanged|3" "$code|$(js state)|$(calls node.runs)"
# Just after an upload the live site's offprint.json isn't there yet: the confirm's first tries get a 404, and curl says
# so. Each such try is repeated, so what it printed isn't logged (it reads as an error, though the publish then goes
# live); the last try's is, when the time runs out.
cf_case; echo 2 > "$S/live_fail_first"; PUBLISH_TIMEOUT_SECONDS=20 OFFPRINT_HOME="$tmp/case$n/ohome" OFFPRINT_SECURITY="$tmp/security" \
  TMPDIR="$tmp/case$n/tmpdir" pub; t="cloudflare-workers, the live site answering 404 to the confirm's first two tries"
check "$t: live, the third try" "0|live|3" "$code|$(js state)|$(grep -c 'offprint\.json' "$S/curl.calls")"
check "$t: no line of curl's in the log" 0 "$(grep -c '^curl:' "$c/var/publish.log")"
cf_case; echo 999 > "$S/live_fail_first"; PUBLISH_TIMEOUT_SECONDS=3 OFFPRINT_HOME="$tmp/case$n/ohome" OFFPRINT_SECURITY="$tmp/security" \
  TMPDIR="$tmp/case$n/tmpdir" pub; t="cloudflare-workers, the live site answering 404 to every try"; sha="$(git -C "$c" rev-parse HEAD)"
check "$t: failed, saying so, with the hint" "1|${sha:0:7} is pushed, but the live site hasn't shown it after 3 seconds (it couldn't be reached); run offprint adapter doctor" "$code|$(js message)"
check "control: $t: asked more than once" yes "$([ "$(grep -c 'offprint\.json' "$S/curl.calls")" -gt 1 ] && echo yes || echo no)"
check "$t: the last try's reason in the log, once" "curl: (56) The requested URL returned error: 404" "$(grep '^curl:' "$c/var/publish.log")"

# What is uploaded is the commit, never site/ on disk: what changes there after the commit (Finder's .DS_Store, a file
# planted, one edited) isn't uploaded; nor do line ends git's settings change on disk, a filter or export-subst named
# in .git/info/attributes; and the export can have no .gitattributes at all.
cf_case
cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" push "*) if [ ! -e "$S/planted" ]; then touch "$S/planted"; : > "$c/site/.DS_Store"; echo planted > "$c/site/extra.html"; echo '<html><body>edited on disk</body></html>' > "$c/site/index.html"; fi ;; esac
exec "$real_git" "\$@"
STUB
chmod +x "$S/bin/git"; cfpub; t="cloudflare-workers, site/ changed on disk after the commit"
check "control: $t: they were changed" "yes|yes|<html><body>edited on disk</body></html>" "$(exists "$c/site/.DS_Store")|$(exists "$c/site/extra.html")|$(cat "$c/site/index.html")"
check "$t: live" "0|live" "$code|$(js state)"
check "$t: what was uploaded is the commit's site/" "$(git -C "$c" rev-parse HEAD:site)" "$(fixture_id "$S/uploaded")"
check "$t: no .DS_Store, no planted file, the edited file as committed" "no|no|<html><body>New home</body></html>" \
  "$(exists "$S/uploaded/.DS_Store")|$(exists "$S/uploaded/extra.html")|$(cat "$S/uploaded/index.html")"
cf_case; git -C "$c" config core.autocrlf true; printf '<html><body>Hello\r\n</body></html>\r\n' > "$S/fixture/hello/index.html"; cfpub
t="cloudflare-workers, core.autocrlf true, a file exported with CRLF line ends"
check "control: $t: site/ on disk has them, the commit doesn't" "yes|no" \
  "$(grep -q "$(printf '\r')" "$c/site/hello/index.html" && echo yes || echo no)|$(git -C "$c" cat-file blob HEAD:site/hello/index.html | grep -q "$(printf '\r')" && echo yes || echo no)"
check "$t: live, the file uploaded as committed" "0|live|$(git -C "$c" rev-parse HEAD:site/hello/index.html)" "$code|$(js state)|$(git -C "$c" hash-object --no-filters "$S/uploaded/hello/index.html")"
cf_case; printf '* filter=evil export-subst\n' > "$c/.git/info/attributes"; git -C "$c" config filter.evil.smudge 'sed s/New/EVIL/'; git -C "$c" config filter.evil.clean cat
printf 'id: $Format:%%H$\n' > "$S/fixture/subst.txt"; cfpub; t="cloudflare-workers, a smudge filter and export-subst in .git/info/attributes"
check "$t: live, the files uploaded as committed" "0|live|<html><body>New home</body></html>|id: \$Format:%H\$" "$code|$(js state)|$(cat "$S/uploaded/index.html")|$(cat "$S/uploaded/subst.txt")"
check "$t: all of them" "$(git -C "$c" rev-parse HEAD:site)" "$(fixture_id "$S/uploaded")"
cf_case; printf '* export-ignore\n' > "$S/fixture/.gitattributes"; cfpub; t="cloudflare-workers, a .gitattributes in the export"
check "$t: refused by the checks" "1|The export failed the checks, nothing was published: git file or folder: ./.gitattributes" "$code|$(js message)"
never_ran "$t"; nocommit "$t"

# Copying site/ out of the commit fails closed: git can't list it, its answer is cut short, the disk is full, or the
# commit holds what no upload may (a link, another repository, two names that are one on this disk).
cf_case
cat > "$S/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" ls-tree -r -z "*":site "*) [ ! -f "$S/no_list" ] || { echo "fatal: the stand-in won't list it" >&2; exit 128; } ;;
  *" cat-file --batch "*) [ ! -f "$S/cut_short" ] || { "$real_git" "\$@" | head -c 60; exit 0; } ;; esac
exec "$real_git" "\$@"
STUB
chmod +x "$S/bin/git"; touch "$S/no_list"; cfpub; t="cloudflare-workers, git can't list site/ in the commit"
check "$t: failed" "1|$(short) is pushed, but the deploy failed: couldn't copy site/ out of the commit for the upload: git couldn't list it (see var/publish.log)" "$code|$(js message)"
never_ran "$t"; cf_tmp_empty "$t"
rm "$S/no_list"; touch "$S/cut_short"; cfpub; t="cloudflare-workers, git's answer cut short"
check "$t: failed" "1|$(short) is pushed, but the deploy failed: couldn't copy site/ out of the commit for the upload: git's answer for site/404.html wasn't whole" "$code|$(js message)"
never_ran "$t"; cf_tmp_empty "$t"
# cf_copy COMMIT: adapter_cf_copy for COMMIT into a fresh folder W of the case's; sets got to STATUS|ADAPTER_PROBLEM.
# PRE (shell code) runs first, in the shell of the copy.
cf_copy() {
  rm -rf "$tmp/case$n/w"; mkdir "$tmp/case$n/w"; W="$tmp/case$n/w"
  CID="$1" W="$W" load 'eval "${CPRE:-}"; offprint_adapter_call adapter_cf_copy "$CID" "$W"; echo "copy=$?|$ADAPTER_PROBLEM"'
  got="$(printf '%s\n' "$out" | sed -n 's/^copy=//p')"
}
cf_case; mkdir -p "$c/site/sub"; printf '#!/bin/sh\n' > "$c/site/sub/run.sh"; chmod +x "$c/site/sub/run.sh"
printf 'a\r\nb\000c' > "$c/site/sub/bytes.bin"; git -C "$c" add -A site; git -C "$c" commit -q -m "an executable, odd bytes"
cf_copy "$(git -C "$c" rev-parse HEAD)"; t="adapter_cf_copy, the commit's site/ with an executable and odd bytes"
check "$t: copied" "0|" "$got"; check "$t: byte for byte, modes too" "$(git -C "$c" rev-parse HEAD:site)" "$(fixture_id "$W/site")"
ln -s ../index.html "$c/site/link.html"; git -C "$c" add -A site; git -C "$c" commit -q -m "a link in site/"
cf_copy "$(git -C "$c" rev-parse HEAD)"; t="adapter_cf_copy, a link in the commit's site/"
check "$t: refused" "1|couldn't copy site/ out of the commit for the upload: site/link.html in the commit isn't a plain file (a link, or another repository)" "$got"
check "$t: no link made" "" "$(find "$W" -type l)"
blob="$(printf 'one\n' | git -C "$c" hash-object -w --stdin)"; sub="$(git -C "$c" rev-parse HEAD)"
tr_ok="$(printf '100644 blob %s\tindex.html\n160000 commit %s\tother\n' "$blob" "$sub" | git -C "$c" mktree)"
cf_copy "$(printf '040000 tree %s\tsite\n' "$tr_ok" | git -C "$c" mktree | xargs git -C "$c" commit-tree -m gitlink)"; t="adapter_cf_copy, another repository in the commit's site/"
check "$t: refused" "1|couldn't copy site/ out of the commit for the upload: site/other in the commit isn't a plain file (a link, or another repository)" "$got"
tw="$(printf '100644 blob %s\tAbout.html\n100644 blob %s\tabout.html\n' "$blob" "$(printf 'two\n' | git -C "$c" hash-object -w --stdin)" | git -C "$c" mktree)"
cf_copy "$(printf '040000 tree %s\tsite\n' "$tw" | git -C "$c" mktree | xargs git -C "$c" commit-tree -m twins)"; t="adapter_cf_copy, About.html and about.html in the commit's site/"
if folds About.html about.html; then
  check "$t: on this disk (one name for both), refused" "1|couldn't copy site/ out of the commit for the upload: site/about.html couldn't be made in the copy (two names that are one on this disk, or the disk is full)" "$got"
else
  check "$t: on this disk (two names), both copied" "0||one|two" "$got|$(cat "$W/site/About.html")|$(cat "$W/site/about.html")"
fi
cf_copy 0123456789abcdef0123456789abcdef01234567; t="adapter_cf_copy, a commit that isn't there"
check "$t: refused" "1|couldn't copy site/ out of the commit for the upload: git couldn't list it (see var/publish.log)" "$got"
cf_case; head -c 4000 /dev/zero | tr '\0' a > "$c/site/big.txt"; git -C "$c" add -A site; git -C "$c" commit -q -m "a 4000-byte file"
CPRE="ulimit -f 2; trap '' XFSZ" cf_copy "$(git -C "$c" rev-parse HEAD)"; t="adapter_cf_copy, a disk that takes no more (ulimit -f)"
case "$got" in "1|couldn't copy site/ out of the commit for the upload: site/big.txt couldn't be written in the copy (is the disk full?)"*) ok "$t: refused, saying so" ;;
  *) bad "$t: refused, saying so (got '$got')" ;; esac

# Names wrangler gives a meaning of its own in the assets folder: .assetsignore (files it names are left out of the
# upload) and _worker.js (a Pages worker: wrangler refuses to upload one). At the root, in any letter case, a fold of
# either, a file or a folder: refused before the commit, nothing uploaded. Deeper down, _worker.js means nothing to
# wrangler and is uploaded; .assetsignore deeper down passes the checks, but the copy for the upload refuses it at any
# depth (the second layer: it is never handed to wrangler), as it does any of these names in a commit made some other
# way. (wrangler 4.166.0 reads .assetsignore only at the root: in a real run one deeper down was uploaded and served as
# a plain file. It is refused at any depth all the same, as a caution, and the refusal says so: not that wrangler would
# read it there. The reason leads, the path last: the status keeps 300 characters.)
AI_WHY="wrangler gives .assetsignore a meaning of its own at the root of what it uploads (it leaves out the files it names), and Offprint refuses the name at any depth"
cf_case; load 'echo "SPECIAL=[$ADAPTER_HOST_SPECIAL_FILES]"'
check "cloudflare-workers: the names wrangler gives a meaning of its own" "rc=0|SPECIAL=[.assetsignore _worker.js]" "$(printf '%s\n' "$out" | paste -sd'|' -)"
for spec in ".assetsignore|file|.assetsignore" ".ASSETSIGNORE|file|.assetsignore" "_worker.js|file|_worker.js" "_Worker.JS|file|_worker.js" \
    ".AssetsIgnore|folder|.assetsignore" "_worker.js|folder|_worker.js" ".a${LONG_S}${LONG_S}etsignore|file|.assetsignore" "_wor${KELVIN}er.js|folder|_worker.js"; do
  f="${spec%%|*}"; rest="${spec#*|}"; kind="${rest%|*}"; name="${rest#*|}"
  case "$f" in "$name"|.ASSETSIGNORE|_Worker.JS|.AssetsIgnore) ;;
    *) if ! folds "$f" "$name"; then echo "skip  $f taken for $name (this disk doesn't fold it)"; continue; fi ;; esac
  cf_case
  if [ "$kind" = file ]; then printf 'index.html\n*.css\n' > "$S/fixture/$f"; else mkdir "$S/fixture/$f"; echo 'export default {}' > "$S/fixture/$f/index.js"; fi
  cfpub; t="cloudflare-workers, $f at the root of the export ($kind)"
  check "$t: refused before the commit" "1|The export failed the checks, nothing was published: the host gives $name a meaning of its own at the root, so the export can't have one: ./$f" "$code|$(js message)"
  nocommit "$t"; never_ran "$t"; cf_tmp_empty "$t"
done
# Deeper down, adapter_prepare refuses one (any case, a file or a folder, a fold of the name), so it is never committed.
for spec in "hello/.assetsignore|file" "hello/.ASSETSIGNORE|file" "hello/.AssetsIgnore|folder" "hello/.a${LONG_S}${LONG_S}etsignore|file"; do
  f="${spec%|*}"; kind="${spec#*|}"
  case "$f" in *"$LONG_S"*) if ! folds "${f#hello/}" .assetsignore; then echo "skip  $f taken for hello/.assetsignore (this disk doesn't fold it)"; continue; fi
    why="$AI_WHY: the export has a name this disk takes for .assetsignore in hello/" ;;
  *) why="$AI_WHY: the export has $f" ;; esac
  cf_case; if [ "$kind" = file ]; then printf '*\n' > "$S/fixture/$f"; else mkdir "$S/fixture/$f"; echo x > "$S/fixture/$f/x"; fi
  cfpub; t="cloudflare-workers, $f deeper down ($kind)"
  check "$t: refused before the commit, naming it" "1|The adapter couldn't prepare the export: $why; nothing was published." "$code|$(js message)"
  nocommit "$t"; never_ran "$t"; cf_tmp_empty "$t"
done
cf_case; echo 'export default {}' > "$S/fixture/hello/_worker.js"; cfpub; t="cloudflare-workers, _worker.js deeper down (hello/)"
check "$t: uploaded like any file, and live" "0|live|yes" "$code|$(js state)|$(exists "$S/uploaded/hello/_worker.js")"
# The second layer, on commits made some other way: each such name in the commit's site/, refused by the copy.
cf_case; blob="$(printf '*\n' | git -C "$c" hash-object -w --stdin)"
leaf_tree() { printf '100644 blob %s\t%s\n' "$blob" "$1" | git -C "$c" mktree; }   # leaf_tree NAME: a tree holding NAME
site_commit() { printf '040000 tree %s\tsite\n' "$1" | git -C "$c" mktree | xargs git -C "$c" commit-tree -m special; }
for f in .assetsignore .AssetsIgnore _worker.js _WORKER.JS; do
  cf_copy "$(site_commit "$(leaf_tree "$f")")"; t="adapter_cf_copy, $f at the root of the commit's site/"
  case "$f" in _*) why="site/$f: _worker.js is a name wrangler gives a meaning of its own at the root" ;; *) why="$AI_WHY: site/$f" ;; esac
  check "$t: refused" "1|couldn't copy site/ out of the commit for the upload: $why" "$got"
  check "$t: nothing copied" "" "$(ls -A "$W/site" 2>/dev/null)"
done
cf_copy "$(site_commit "$(printf '040000 tree %s\t_worker.js\n' "$(leaf_tree index.js)" | git -C "$c" mktree)")"; t="adapter_cf_copy, a folder _worker.js in the commit's site/"
check "$t: refused" "1|couldn't copy site/ out of the commit for the upload: site/_worker.js/index.js: _worker.js is a name wrangler gives a meaning of its own at the root" "$got"
cf_copy "$(site_commit "$(printf '040000 tree %s\ta\n' "$(printf '040000 tree %s\tb\n' "$(leaf_tree .ASSETSIGNORE)" | git -C "$c" mktree)" | git -C "$c" mktree)")"
t="adapter_cf_copy, a/b/.ASSETSIGNORE in the commit's site/"
check "$t: refused" "1|couldn't copy site/ out of the commit for the upload: $AI_WHY: site/a/b/.ASSETSIGNORE" "$got"
for spec in ".a${LONG_S}${LONG_S}etsignore|.assetsignore|" "_wor${KELVIN}er.js|_worker.js|" ".a${LONG_S}${LONG_S}etsignore|.assetsignore|a"; do
  f="${spec%%|*}"; rest="${spec#*|}"; name="${rest%|*}"; under="${rest#*|}"
  if ! folds "$f" "$name"; then echo "skip  $f taken for $name (this disk doesn't fold it)"; continue; fi
  tr_="$(leaf_tree "$f")"; [ -z "$under" ] || tr_="$(printf '040000 tree %s\t%s\n' "$tr_" "$under" | git -C "$c" mktree)"
  cf_copy "$(site_commit "$tr_")"; t="adapter_cf_copy, ${under:+$under/}$f in the commit's site/ (this disk takes it for $name)"
  if [ -n "$under" ]; then why="$AI_WHY: site/$under/ has a name this disk takes for $name"
  else why="site/ has a name this disk takes for $name: wrangler gives that name a meaning of its own at the root"; fi
  check "$t: refused" "1|couldn't copy site/ out of the commit for the upload: $why" "$got"
done

# === TMPDIR inside the site folder: refused by every entry point that finds a site, before any file is made ===
# WordPress can write var/inbox, var/export and wp-content/: a temporary file there could be swapped for a link between
# being made and being written through by name. So a TMPDIR that is the site folder or inside it (compared on disk: in
# any letter case, through a link) is refused, in one line, exit 2, as soon as the site folder is known (lib/site.sh's
# offprint_find_site), before any temporary file. Each entry point is run with TMPDIR so; a link to a file outside the
# site is planted where WordPress could plant one, and must be untouched; TMPDIR's folder must be as it was.
tmp_entries() {  # each entry point that finds a site, one a line: NAME|COMMAND (run from the case folder)
  printf '%s\n' "bin/publish|/bin/bash $SRC/bin/publish" "offprint check|/bin/bash $SRC/bin/offprint check $tmp/case$n/out" \
    "offprint compose|/bin/bash $SRC/bin/offprint compose ps" "offprint host-setup --print|/bin/bash $SRC/bin/offprint host-setup --print" \
    "bin/wp|/bin/bash $SRC/bin/wp option get siteurl" "bin/setup-wp|/bin/bash $SRC/bin/setup-wp" \
    "os/darwin/secret|/bin/bash $SRC/os/darwin/secret get cloudflare-token" "bin/publish-agent|/bin/bash $SRC/bin/publish-agent" \
    "install-agent --print|/bin/bash $SRC/os/darwin/install-agent --print" "offprint adapter setup|/bin/bash $SRC/bin/offprint adapter setup" \
    "offprint adapter doctor|/bin/bash $SRC/bin/offprint adapter doctor"
}
tmp_case() {  # a site (the adapter none), var/inbox, wp-content/, a victim file outside it with links to it planted in both
  newcase; mkdir -p "$c/var/inbox" "$tmp/case$n/home" "$tmp/case$n/out"; cp -R "$S/fixture/." "$tmp/case$n/out/"
  echo victim > "$tmp/case$n/victim"; ln -s "$tmp/case$n/victim" "$c/var/inbox/planted"; ln -s "$tmp/case$n/victim" "$c/wp-content/planted"
  printf '#!/bin/sh\necho "mkcert $*" >> "$STUB_DIR/mkcert.calls"; exit 1\n' > "$S/bin/mkcert"
  printf '#!/bin/sh\necho ran >> "$STUB_DIR/agent-publish.calls"\n' > "$S/bin/agent-publish"; chmod +x "$S/bin/mkcert" "$S/bin/agent-publish"
  ln -s "$c/var/inbox" "$tmp/case$n/via"
}
run_entry() {  # run_entry COMMAND WHERE: the command with TMPDIR=WHERE, from the case folder; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" TMPDIR="$2" HOME="$tmp/case$n/home" \
    OFFPRINT_SECURITY="$tmp/security" PUBLISH_AGENT_PUBLISH="$S/bin/agent-publish" PUBLISH_AGENT_MIN_SECONDS=0 \
    PUBLISH_AGENT_SETTLE_SECONDS=0 PUBLISH_POLL_SECONDS=1 $1 2>&1 < /dev/null)"; code=$?
}
tmp_case; site_phys="$(cd "$c" && pwd -P)"
for spec in "$c/var/inbox|in var/inbox" "$c/wp-content|in wp-content/" "$c|the site folder itself" \
    "${c%/repo}/REPO/var/inbox|in another letter case (the site folder's own name)" "$tmp/case$n/via|through a link to var/inbox" \
    "$c/var/inbox/away|through a link WordPress could plant in var/inbox, to a folder outside (it could swap it back later)"; do
  where="${spec%%|*}"; how="${spec#*|}"
  [ -e "$c/var/inbox/away" ] || ln -s "$tmp/case$n/home" "$c/var/inbox/away"
  if ! [ -d "$where" ] || { [ "$where" = "${c%/repo}/REPO/var/inbox" ] && ! [ "$where" -ef "$c/var/inbox" ]; }; then
    echo "skip  TMPDIR $how (this disk has no such path)"; continue
  fi
  before="$(ls -A "$where")"
  while IFS='|' read -r name cmd; do
    rm -f "$S/docker.calls" "$S/docker.queries" "$S/mkcert.calls" "$S/agent-publish.calls" "$S/security.argv"
    run_entry "$cmd" "$where"; t="$name, TMPDIR $how"
    check "$t: refused, in one line, exit 2" "2|TMPDIR is $where, inside the site folder $site_phys, which WordPress can write; unset TMPDIR, or point it at a folder outside the site folder." "$code|$out"
    check "$t: nothing made, nothing run: TMPDIR's folder as it was, the victim untouched" "$before|victim|no|no|no|no" \
      "$(ls -A "$where")|$(cat "$tmp/case$n/victim")|$(exists "$S/docker.calls")|$(exists "$S/docker.queries")|$(exists "$S/agent-publish.calls")|$(exists "$S/security.argv")"
  done < <(tmp_entries)
done
run_entry "/bin/bash $SRC/bin/publish" var/inbox; t="bin/publish, TMPDIR var/inbox (not an absolute path: inside the site folder once the publish is there)"
check "$t: refused, in one line, exit 2" "2|TMPDIR is var/inbox, not an absolute path, so where it is depends on the folder each step runs in; unset TMPDIR, or point it at a folder outside the site folder." "$code|$out"
check "$t: nothing made" "away planted|victim" "$(ls -A "$c/var/inbox" | paste -sd' ' -)|$(cat "$tmp/case$n/victim")"
# A TMPDIR outside the site folder, or holding it (the site folder inside TMPDIR, as these tests' own are): unaffected.
for where in "$tmp/case$n/home" "$tmp/case$n"; do
  run_entry "/bin/bash $SRC/bin/offprint check $tmp/case$n/out" "$where"; t="offprint check, TMPDIR $where (outside the site folder, or holding it)"
  check "$t: works as ever" "0|" "$code|$out"
done
run_entry "/bin/bash $SRC/bin/offprint check $tmp/case$n/out" ""; check "offprint check, TMPDIR empty: works as ever" "0|" "$code|$out"
# The race itself, made certain: a stand-in mktemp makes what it is asked, then puts a link in its place, as a writer of
# that folder could (SWAP_FILE_TO for a file, SWAP_DIR_TO for a folder), noting each call in STUB_DIR/mktemp.calls.
mkdir -p "$tmp/mk"; cat > "$tmp/mk/mktemp" <<'STUB'
#!/usr/bin/env bash
made="$(/usr/bin/mktemp "$@")" || exit $?
echo "$*" >> "$STUB_DIR/mktemp.calls"
if [ "${1-}" = -d ]; then to="${SWAP_DIR_TO-}"; else to="${SWAP_FILE_TO-}"; fi
if [ -n "$to" ]; then rm -rf "$made"; ln -s "$to" "$made"; fi
printf '%s\n' "$made"
STUB
chmod +x "$tmp/mk/mktemp"
tmp_case; t="lib/site.sh's own temporary file (site.json's messages), TMPDIR in var/inbox, a writer swapping it for a link"
out="$(cd "$tmp/case$n" && PATH="$tmp/mk:$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" TMPDIR="$c/var/inbox" SWAP_FILE_TO="$tmp/case$n/victim" \
  /bin/bash "$SRC/bin/offprint" check "$tmp/case$n/out" 2>&1)"; code=$?
check "$t: refused before any mktemp" "2|no" "$code|$(exists "$S/mktemp.calls")"; check "$t: the victim untouched" victim "$(cat "$tmp/case$n/victim")"
# offprint_private_dir, the second layer: it asks of TMPDIR's own folder first, and makes nothing there when that is
# inside the site folder; and what mktemp made must be a real folder of this user's, with no access for group or others,
# not a link to one elsewhere.
mkdir -p "$tmp/case$n/vdir"; chmod 755 "$tmp/case$n/vdir"; echo 'a victim adapter.sh' > "$tmp/case$n/vdir/adapter.sh"
PATH="$tmp/mk:$PATH" STUB_DIR="$S" SWAP_DIR_TO="$tmp/case$n/vdir" PRE='TMPDIR="$OFFPRINT_SITE/var/inbox"' \
  load 'offprint_private_dir offprint-x d; echo "made=$?|$d|$OFFPRINT_PRIVATE_PROBLEM"'
t="offprint_private_dir, TMPDIR in var/inbox, a writer swapping the folder for a link out of the site"
check "$t: the loader refuses, making nothing there" "rc=2|no" "$(printf '%s\n' "$out" | head -n 1)|$(grep -c "var/inbox" "$S/mktemp.calls" 2>/dev/null | grep -qv '^0$' && echo yes || echo no)"
contains "$t: saying so" "no private folder could be made to load it in: TMPDIR is inside the site folder" "$out"
check "$t: the folder outside untouched" "a victim adapter.sh|planted" "$(cat "$tmp/case$n/vdir/adapter.sh" 2>&1)|$(ls -A "$c/var/inbox")"
PATH="$tmp/mk:$PATH" STUB_DIR="$S" SWAP_DIR_TO="$tmp/case$n/vdir" load; t="the loader, TMPDIR outside the site folder, mktemp's folder swapped for a link"
check "$t: refused (2), saying so" "rc=2|problem=$(said none)no private folder could be made to load it in: the folder made in TMPDIR isn't a private folder of this user's (a real folder, with no access for group or others)." \
  "$(printf '%s\n' "$out" | paste -sd'|' -)"
check "$t: the folder the link names untouched (adapter.sh not written there, nothing removed)" "a victim adapter.sh" "$(cat "$tmp/case$n/vdir/adapter.sh" 2>&1)"
check "$t: and its mode unchanged (no chmod through the link)" "$tmp/case$n/vdir" "$(find "$tmp/case$n/vdir" -maxdepth 0 -perm 755)"
# Its mode is set by offprint_private_dir itself (700), not left to the umask; what it requires is a real folder of this
# user's with no access for group or others (a setgid or sticky bit, which a folder may pass on to new ones, is fine).
for um in 0277 0000; do
  STUB_DIR="$S" UM="$um" load 'umask "$UM"; offprint_private_dir offprint-x d; r=$?; u=no; [ -n "$d" ] && : > "$d/x" 2> /dev/null && u=yes
    echo "made=$r|$OFFPRINT_PRIVATE_PROBLEM|usable=$u"; [ -z "$d" ] || rm -rf "$d"'
  check "offprint_private_dir under umask $um: works, a folder it can write in" "made=0||usable=yes" "$(printf '%s\n' "$out" | grep '^made=')"
done
mkdir -p "$tmp/case$n/sg"; chmod 2755 "$tmp/case$n/sg" 2> /dev/null
if [ -g "$tmp/case$n/sg" ]; then
  STUB_DIR="$S" SG="$tmp/case$n/sg" load 'TMPDIR="$SG"; offprint_private_dir offprint-x d; echo "made=$?|$OFFPRINT_PRIVATE_PROBLEM"; [ -z "$d" ] || rm -rf "$d"'
  check "offprint_private_dir in a setgid folder (on Linux its new folder inherits the bit): works" "made=0|" "$(printf '%s\n' "$out" | grep '^made=')"
else echo "skip  offprint_private_dir in a setgid folder (this system won't make one here)"; fi
# A folder that stays group-readable (mktemp's, made so by a stand-in, and a chmod that changes nothing, as on a disk
# without Unix modes): refused, and removed.
mkdir -p "$tmp/case$n/mk2" "$tmp/case$n/t2"
printf '#!/bin/sh
made="$(/usr/bin/mktemp "$@")" || exit $?
[ "$1" != -d ] || /bin/chmod 750 "$made"
printf "%%s\\n" "$made"
' > "$tmp/case$n/mk2/mktemp"
printf '#!/bin/sh
exit 0
' > "$tmp/case$n/mk2/chmod"; chmod +x "$tmp/case$n/mk2/mktemp" "$tmp/case$n/mk2/chmod"
STUB_DIR="$S" T2="$tmp/case$n/t2" MK2="$tmp/case$n/mk2" load 'TMPDIR="$T2"; PATH="$MK2:$PATH"; offprint_private_dir offprint-x d; echo "made=$?|$d|$OFFPRINT_PRIVATE_PROBLEM"'
t="offprint_private_dir, the folder made group-readable, and no chmod that works"
check "$t: refused" "made=1||the folder made in TMPDIR isn't a private folder of this user's (a real folder, with no access for group or others)" "$(printf '%s\n' "$out" | grep '^made=')"
check "$t: and removed" "" "$(ls -A "$tmp/case$n/t2")"

# The host's limits: 20,000 files (offprint.json, _headers and _redirects among them), 26,214,400 bytes for one file.
# Made without filling the disk (empty files; one sparse one), and removed once checked.
cf_case; mkdir "$S/fixture/many"; ( cd "$S/fixture/many" && seq 1 19994 | sed 's/^/f/; s/$/.txt/' | xargs touch )
cfpub --dry-run; t="cloudflare-workers, 19,998 files exported, its 2 and offprint.json: 20,001"
check "$t: refused" "1|The export failed the checks, nothing was published: too many files: 20001, the limit is 20000" "$code|$(js message)"
rm "$S/fixture/many/f1.txt"; cfpub --dry-run; t="cloudflare-workers, one fewer: 20,000"
check "$t: passes, with the warning" '0|["warning: the site has 20000 files, over 80% of the 20000 limit"]' "$code|$(js warnings)"
rm -rf "$S/fixture/many" "$c/var/export"
cf_case; dd if=/dev/zero of="$S/fixture/big.bin" bs=1 count=0 seek=26214401 2>/dev/null
cfpub --dry-run; t="cloudflare-workers, a file of 26,214,401 bytes"
check "$t: refused" "1|The export failed the checks, nothing was published: big.bin is 26214401 bytes, the limit for one file is 26214400" "$code|$(js message)"
rm "$S/fixture/big.bin"; dd if=/dev/zero of="$S/fixture/big.bin" bs=1 count=0 seek=26214400 2>/dev/null
cfpub --dry-run; t="cloudflare-workers, a file of 26,214,400 bytes"
check "$t: passes, with the warning" '0|["warning: big.bin is 26214400 bytes, over 80% of the 26214400 limit for one file"]' "$code|$(js warnings)"
rm -rf "$S/fixture/big.bin" "$c/var/export"

# === offprint adapter setup and offprint adapter doctor: the contract (bin/offprint, lib/adapter.sh) ===
# setup runs the adapter's adapter_setup with the caller's stdin (the terminal, or what was piped in); doctor runs
# adapter_doctor with stdin /dev/null; both check the adapter's settings first. A publish still gives every adapter
# function /dev/null. An INT to the command's process group (Ctrl-C at a terminal) stops a set-up waiting at a prompt:
# the function's shell, which ignores INT (a background job's does), is sent a TERM, so its own trap can tidy up.
CS_PATH=""; OH=""
oa() {  # oa SUB [ARGS]: offprint adapter SUB ARGS for the site $c, from the case folder, stdin the caller's; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" TMPDIR="$tmp/case$n/tmpdir" \
    /bin/bash "$SRC/bin/offprint" adapter "$@" 2>&1)"; code=$?
}
# ctrl_c UNTIL ARGS...: offprint adapter ARGS for the site $c (with the set-up cases' PATH and Offprint folder, once
# they are set), as a terminal runs its foreground job: in a process group of its own, INT not ignored (whatever this
# suite was started with). Its stdin is a pipe that stays open: FEED's text (printf %b), then nothing more. Its output
# goes to $S/oa.out. Once the shell code UNTIL is true (15 seconds at most), Ctrl-C: an INT to the whole group. Sets
# code (its exit status), secs (how long it took to end after the INT) and out.
ctrl_c() {
  local until="$1" pid i=0 start; shift
  rm -f "$S/in"; mkfifo "$S/in"
  ( cd "$tmp/case$n" && PATH="${CS_PATH:-$S/bin:$tmp/bin:$PATH}" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="${OH:-$tmp/case$n/ohome}" \
      OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
      exec /usr/bin/perl -e 'setpgrp(0, 0); $SIG{INT} = "DEFAULT"; exec @ARGV or exit 127' /bin/bash "$SRC/bin/offprint" adapter "$@" ) \
    < "$S/in" > "$S/oa.out" 2>&1 &
  pid=$!
  exec 8> "$S/in"; printf '%b' "${FEED:-}" >&8
  while ! eval "$until" && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  start=$SECONDS; kill -INT -"$pid" 2> /dev/null
  i=0; while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 250 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2> /dev/null; then kill -KILL -"$pid" 2> /dev/null; fi
  wait "$pid"; code=$?; secs=$((SECONDS - start)); exec 8>&-; rm -f "$S/in"; out="$(cat "$S/oa.out")"
}
out="$(/bin/bash "$SRC/bin/offprint" help 2>&1)"; t="offprint help"
contains "$t: lists offprint adapter setup [--yes]" "offprint adapter setup [--yes]" "$out"
contains "$t: and offprint adapter doctor" "offprint adapter doctor" "$out"
newcase; mkdir -p "$tmp/case$n/tmpdir"; adapter ask <<'A'
adapter_setup() { local line; IFS= read -r line; echo "setup read [$line] args [$*]"; }
adapter_doctor() { local line rc=0; IFS= read -r line || rc=$?; echo "doctor read $rc [$line]"; return 3; }
adapter_confirm() { return 0; }
A
oa setup < <(printf 'an answer\nmore\n'); t="offprint adapter setup, an answer piped in"
check "$t: adapter_setup read it, exit 0" "0|setup read [an answer] args []" "$code|$out"
oa setup --yes < <(printf 'yes please\n'); check "offprint adapter setup --yes: passed on to adapter_setup" "0|setup read [yes please] args [--yes]" "$code|$out"
# offprint_adapter_call itself, from a script where nothing has redirected stdin before it (bin/offprint runs inside a
# case statement where something already has, and bash then hands every later background job its stdin anyway): the
# function reads the caller's stdin, never the /dev/null bash gives a background job.
load 'offprint_adapter_call adapter_setup' < <(printf 'piped in\n'); t="offprint_adapter_call, called where bash would give a background job /dev/null"
check "$t: the function reads the caller's stdin" "rc=0|setup read [piped in] args []" "$(printf '%s\n' "$out" | paste -sd'|' -)"
oa doctor < <(printf 'not for the doctor\n'); t="offprint adapter doctor, something piped in"
check "$t: adapter_doctor's stdin is empty, and its status is the command's" "3|doctor read 1 []" "$code|$out"
check "offprint adapter setup and doctor: nothing left in TMPDIR (the adapter's private folder goes)" "" "$(ls -A "$tmp/case$n/tmpdir")"
for args in "" "setup --force" "setup --yes --no" "doctor --yes" "frob"; do
  # shellcheck disable=SC2086 # the words of the case
  oa $args < /dev/null; t="offprint adapter${args:+ $args}"
  check "$t: a usage line, exit 2, nothing run" "2|usage: offprint adapter|" "$code|${out:0:23}|$(ls -A "$tmp/case$n/tmpdir")"
done
newcase; mkdir -p "$tmp/case$n/tmpdir"; adapter v <<'A'
adapter_validate() { echo 'site.json: "adapter.x" is wrong'; echo 'site.json: "adapter.y" is too'; return 1; }
adapter_setup() { touch "$STUB_DIR/setup.ran"; }
adapter_doctor() { touch "$STUB_DIR/doctor.ran"; }
A
for sub in setup doctor; do
  oa "$sub" < /dev/null; t="offprint adapter $sub, settings the adapter refuses"
  check "$t: refused, exit 2, each problem said" "2|site.json: \"adapter.x\" is wrong|site.json: \"adapter.y\" is too|Fix site.json, then run offprint adapter $sub again." \
    "$code|$(printf '%s\n' "$out" | paste -sd'|' -)"
  check "$t: adapter_$sub never ran" no "$(exists "$S/$sub.ran")"
done
newcase; mkdir -p "$tmp/case$n/tmpdir"; site_json nosuch; commit "names an adapter nobody has"; oa doctor < /dev/null; t="offprint adapter doctor, an adapter that can't be used"
check "$t: refused, exit 2" 2 "$code"; contains "$t: saying why" "$(said nosuch)there is no adapter of that name" "$out"
newcase; mkdir -p "$tmp/case$n/tmpdir"; oa setup < /dev/null; t="offprint adapter setup, the adapter none"
check "$t: nothing to set up, exit 0" "0|nothing to set up: this site has no host set up (its adapter is none), so a publish commits and pushes, and that is all. To publish to a host, name its adapter in site.json's \"adapter\" (README.md says how)." "$code|$out"
oa doctor < /dev/null; check "offprint adapter doctor, the adapter none: nothing to check, exit 0" "0|nothing to check: this site has no host set up (its adapter is none)." "$code|$out"
# A publish gives every adapter function stdin /dev/null, whatever the publish's own stdin holds (and the load too).
newcase; adapter si <<'A'
read -r l; echo "load:$?:[$l]" >> "$STUB_DIR/stdin.log"
ADAPTER_CONFIRM_SECONDS=1
adapter_validate() { read -r l; echo "validate:$?:[$l]" >> "$STUB_DIR/stdin.log"; }
adapter_prepare() { read -r l; echo "prepare:$?:[$l]" >> "$STUB_DIR/stdin.log"; }
adapter_deploy() { read -r l; echo "deploy:$?:[$l]" >> "$STUB_DIR/stdin.log"; }
adapter_confirm() { read -r l; echo "confirm:$?:[$l]" >> "$STUB_DIR/stdin.log"; ADAPTER_WHY="not yet"; return 1; }
adapter_failure_hint() { read -r l; echo "hint:$?:[$l]" >> "$STUB_DIR/stdin.log"; }
A
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > "$tmp/case$n/input"; pub < "$tmp/case$n/input"
t="a publish whose own stdin has lines in it, each adapter function (and adapter.sh's top level) reading its stdin"
check "$t: the publish ran, and failed at the confirm" "1|$(short) is pushed, but the live site hasn't shown it after 1 seconds (not yet)" "$code|$(js message)"
check "$t: every one of them read nothing: its stdin was empty" "confirm:1:[] deploy:1:[] hint:1:[] load:1:[] prepare:1:[] validate:1:[]" "$(LC_ALL=C sort -u "$S/stdin.log" | paste -sd' ' -)"
# Ctrl-C while adapter_setup waits at a prompt: it gets a TERM, and its trap runs (its folder and child go); the command
# ends at once, 130.
newcase; mkdir -p "$tmp/case$n/tmpdir"; adapter int <<'A'
adapter_setup() {
  offprint_private_dir offprint-int adapter_int_dir || return 1
  sleep 61 & adapter_int_kid=$!
  trap 'echo "the TERM trap ran" >> "$STUB_DIR/int.log"; kill "$adapter_int_kid"; rm -rf "$adapter_int_dir"; exit 143' TERM
  echo "asking" >> "$STUB_DIR/int.log"; echo "Your answer? "
  read -r l; echo "read returned [$l]" >> "$STUB_DIR/int.log"
}
A
FEED="" ctrl_c 'grep -q asking "$S/int.log" 2> /dev/null' setup; t="Ctrl-C while adapter_setup waits at a prompt"
check "control: $t: it was asking" "Your answer? " "$out"
check "$t: ended at once, 130" "130|yes" "$code|$([ "$secs" -lt 5 ] && echo yes || echo no)"
check "$t: its TERM trap ran; the read never returned" "asking|the TERM trap ran" "$(paste -sd'|' - < "$S/int.log")"
check "$t: its folder and the adapter's private folder are gone" "" "$(ls -A "$tmp/case$n/tmpdir")"
i=0; while [ -n "$(pgrep -f 'sleep 61')" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
check "$t: its child is stopped" "" "$(pgrep -f 'sleep 61')"
# One that ignores the TERM: after 10 seconds it is killed, with everything under it.
newcase; mkdir -p "$tmp/case$n/tmpdir"; adapter int <<'A'
adapter_setup() { trap '' TERM; sleep 62 & echo "asking" >> "$STUB_DIR/int.log"; read -r l; echo "read returned [$l]" >> "$STUB_DIR/int.log"; }
A
FEED="" ctrl_c 'grep -q asking "$S/int.log" 2> /dev/null' setup; t="Ctrl-C while an adapter_setup that ignores TERM waits at a prompt"
check "$t: ended after about 10 seconds, 130" "130|yes" "$code|$([ "$secs" -ge 9 ] && [ "$secs" -lt 20 ] && echo yes || echo no)"
check "$t: the read never returned" "asking" "$(paste -sd'|' - < "$S/int.log")"
i=0; while [ -n "$(pgrep -f 'sleep 62')" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
check "$t: it and its child are killed" "" "$(pgrep -f 'sleep 62')"
check "$t: the adapter's private folder is gone" "" "$(ls -A "$tmp/case$n/tmpdir")"

# === cloudflare-workers: offprint adapter setup ===
# Nothing here runs the real npm, node, wrangler or security, or reaches Cloudflare or the network: each case's
# stand-ins are its node (node.pl, whose node --version says node_version, else v22.12.0) and npm beside it in "node
# bin" (a folder with a space in its name), reached on the PATH through a link in links/, with no other node on that
# PATH; its curl (curl.pl, first on the PATH), which answers for api.cloudflare.com and the site's public_url; and its
# security (keychain.pl, by OFFPRINT_SECURITY). Its Offprint folder (OFFPRINT_HOME, OH) starts empty. The token is
# TOKEN, fed on stdin through a pipe; no_leak looks for it everywhere, as for a publish.
#
# The stand-in npm: it notes what it was given (STUBS/npm.*), and whether the folder it runs in holds exactly the
# adapter's package.json and package-lock.json, then does what the case's files say:
#   npm_fail     makes a part of node_modules, says it failed and, as npm does, where the complete log of the run is
#                (in its cache folder), and fails (status 1)
#   npm_version  writes wrangler's package.json with that version, not 4.166.0;  npm_noentry: no entry script
#   npm_hang     starts a child (sleep 53) and waits for it
# Otherwise it "installs" wrangler 4.166.0 (its entry script and its package.json). Like npm, it writes a log in its
# cache folder (--cache) and a file under HOME.
cat > "$tmp/npm.pl" <<'NPM'
#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(getcwd);
my $s = '@STUBS@';
my $adir = '@ADIR@';
sub note { my ($name, $text) = @_; open(my $h, '>>', "$s/$name") or die "$s/$name: $!"; print $h $text; close $h; }
sub slurp { my ($f) = @_; open(my $h, '<', $f) or return ''; local $/; my $t = <$h>; close $h; return defined $t ? $t : ''; }
@ENVCHECK@
note('npm.runs', "ran\n");
envcheck('npm');
unlink map { "$s/npm.$_" } qw(argv env values cwd files stdin);
note('npm.argv', join('', map { "$_\n" } @ARGV));
note('npm.env', join('', map { "$_\n" } sort keys %ENV));
note('npm.values', join('', map { "$_=$ENV{$_}\n" } sort keys %ENV));
my $cwd = getcwd();
note('npm.cwd', "$cwd\n");
my $same = -s "$cwd/package-lock.json" && slurp("$cwd/package.json") eq slurp("$adir/package.json")
  && slurp("$cwd/package-lock.json") eq slurp("$adir/package-lock.json");
note('npm.files', ($same ? "the adapter's" : 'something else') . "\n");
note('npm.stdin', ((-c STDIN && !-t STDIN && eof(STDIN)) ? 'empty, not a terminal' : 'something else') . "\n");
my $cache = ''; my ($uc, $gc) = ('', ''); for (@ARGV) { $cache = $1 if /^--cache=(.*)$/; $uc = $1 if /^--userconfig=(.*)$/; $gc = $1 if /^--globalconfig=(.*)$/; }
# Real npm 11 refuses one file as both the user and the global config, before doing anything.
if ($uc ne '' && $uc eq $gc) { print STDERR "npm error Exit prior to config file resolving\nnpm error cause\nnpm error double-loading config \"$uc\" as \"global\", previously loaded as \"user\"\n"; exit 1; }
if ($cache ne '') { system('/bin/mkdir', '-p', "$cache/_logs"); if (open(my $l, '>', "$cache/_logs/debug.log")) { print $l "a log\n"; close $l; } }
if (defined $ENV{HOME} && $ENV{HOME} ne '') { system('/bin/mkdir', '-p', "$ENV{HOME}/.npm"); if (open(my $h, '>', "$ENV{HOME}/.npm/state")) { print $h "x\n"; close $h; } }
system('/bin/mkdir', '-p', "$cwd/node_modules/wrangler/bin");
if (-e "$s/npm_fail") {
  print STDERR "npm error the stand-in failed\n";
  print STDERR "npm error A complete log of this run can be found in: $cache/_logs/debug.log\n" if $cache ne '';
  exit 1;
}
if (-e "$s/npm_hang") {
  my $pid = fork();
  if (defined $pid && $pid == 0) { exec('/bin/sleep', '53'); exit 127; }
  note('npm.hanging', "$$ $pid\n");
  waitpid($pid, 0);
  exit 0;
}
unless (-e "$s/npm_noentry") { open(my $e, '>', "$cwd/node_modules/wrangler/bin/wrangler.js") or die; print $e "// the stand-in's\n"; close $e; }
my $v = slurp("$s/npm_version"); chomp $v; $v = '4.166.0' if $v eq '';
open(my $p, '>', "$cwd/node_modules/wrangler/package.json") or die; print $p "{\n  \"name\": \"wrangler\",\n  \"version\": \"$v\"\n}\n"; close $p;
system('/bin/mkdir', '-p', "$cwd/node_modules/.bin"); symlink('../wrangler/bin/wrangler.js', "$cwd/node_modules/.bin/wrangler");
print "added 133 packages in 1s (the stand-in)\n";
exit 0;
NPM
# The stand-in curl: its arguments and the names in its environment are noted in STUBS/curl.argv and curl.env, one line
# a call; with --config -, whether the Authorization header it read held the stored token (never the token itself) in
# curl.header. Then:
#   api.cloudflare.com's list of an account's Workers, as Cloudflare answered a real run: 200 (and success) for the
#     stored token, whatever it may do (Cloudflare answers so for a token whose only permission is Account Settings
#     Read: so this shows Cloudflare knows the token and it can see the account, never that it may upload); for any
#     other token, one Cloudflare doesn't know (mistyped, cut short, deleted or rolled), 401 with its error 10000;
#     cf_status (a status) and cf_body (the answer) instead (a 403 is Cloudflare's error 10000 too); cf_echo: the error
#     repeats the token, as some APIs do; cf_exit: curl fails with that status, no answer; cf_hang: it waits (until
#     cf_release, or 30 seconds)
#   the public_url, www.example.com: /offprint.json from STUBS/live/ (404 when there is none); /feed/ 200 as
#     application/rss+xml when live/ has feed/index.xml, else 404; any other path 404; feed_status, feed_type and
#     missing_status instead; www_exit: curl fails with that status
# -f, -o FILE and -w FORMAT (%{http_code}, %{content_type}, \n) as curl does them.
cat > "$tmp/curl.pl" <<'CURL'
#!/usr/bin/perl
use strict;
use warnings;
my $s = '@STUBS@';
my $back = '@BACK@';
sub note { my ($name, $text) = @_; open(my $h, '>>', "$s/$name") or die "$s/$name: $!"; print $h $text; close $h; }
sub slurp { my ($f) = @_; open(my $h, '<', $f) or return ''; local $/; my $t = <$h>; close $h; return defined $t ? $t : ''; }
sub first { my $t = slurp($_[0]); $t =~ s/\s+\z//; return $t; }
@ENVCHECK@
envcheck('curl');
my ($fail, $out, $fmt, $cfg, $url, $maxf) = (0, '', '', '', '', '');
my @a = @ARGV;
while (@a) {
  my $x = shift @a;
  if ($x eq '-o') { $out = shift @a; }
  elsif ($x eq '-w') { $fmt = shift @a; }
  elsif ($x eq '--config' || $x eq '-K') { $cfg = shift @a; }
  elsif ($x eq '--max-filesize') { $maxf = shift @a; }
  elsif ($x eq '--proto' || $x eq '--max-time' || $x eq '--connect-timeout') { shift @a; }
  elsif ($x =~ /^-[a-zA-Z]+$/) { $fail = 1 if $x =~ /f/; }
  elsif ($x =~ /^--/) { }
  else { $url = $x; }
}
note('curl.argv', join(' ', @ARGV) . "\n");
note('curl.env', join(' ', sort keys %ENV) . "\n");
my $tok = '';
if ($cfg eq '-') {
  local $/; my $c = <STDIN>; $c = '' unless defined $c;
  $tok = $1 if $c =~ /\A\s*header = "Authorization: Bearer ([^"\n]*)"\s*\z/;
  note('curl.header', ($tok eq '' ? 'none' : ($tok eq reverse($back) ? 'the stored token' : 'another value')) . "\n");
}
my ($code, $type, $body, $exit) = (0, '', '', 0);
if ($url =~ m{\Ahttps://api\.cloudflare\.com/client/v4/accounts/[0-9a-f]{32}/workers/scripts\z}) {
  if (-e "$s/cf_hang") { note('curl.hanging', "$$\n"); my $i = 0; while (!-e "$s/cf_release" && $i < 300) { select(undef, undef, undef, 0.1); $i++; } }
  if (-e "$s/cf_exit") { $exit = first("$s/cf_exit"); }
  else {
    $code = -e "$s/cf_status" ? first("$s/cf_status") : ($tok ne '' && $tok eq reverse($back) ? 200 : 401);
    $type = 'application/json';
    if (-e "$s/cf_body") { $body = slurp("$s/cf_body"); }
    elsif ($code == 200) { $body = '{"result":[],"success":true,"errors":[],"messages":[]}'; }
    elsif (-e "$s/cf_echo") { $body = '{"success":false,"errors":[{"code":6111,"message":"Invalid format for Authorization header: Bearer ' . $tok . '"}],"messages":[],"result":null}'; }
    elsif ($code == 401) { $body = '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'; }
    else { $body = '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"messages":[],"result":null}'; }
  }
} elsif ($url =~ m{\Ahttps://www\.example\.com(/[^?]*)}) {
  my $path = $1;
  if (-e "$s/www_exit") { $exit = first("$s/www_exit"); }
  elsif ($path eq '/offprint.json') {
    if (-f "$s/live/offprint.json") { ($code, $type, $body) = (200, 'application/json', slurp("$s/live/offprint.json")); }
    else { ($code, $type, $body) = (404, 'text/html', "<html>Gone</html>\n"); }
  } elsif ($path eq '/feed/') {
    if (-f "$s/live/feed/index.xml") { ($code, $type, $body) = (200, 'application/rss+xml; charset=utf-8', slurp("$s/live/feed/index.xml")); }
    else { ($code, $type, $body) = (404, 'text/html', "<html>Gone</html>\n"); }
    $code = first("$s/feed_status") if -e "$s/feed_status";
    $type = first("$s/feed_type") if -e "$s/feed_type";
  } else {
    ($code, $type, $body) = (404, 'text/html; charset=utf-8', "<html>Gone</html>\n");
    $code = first("$s/missing_status") if -e "$s/missing_status";
  }
} else { $exit = 6; }
my $w = $fmt; my $hc = sprintf('%03d', $code);
$w =~ s/\\n/\n/g; $w =~ s/%\{http_code\}/$hc/g; $w =~ s/%\{content_type\}/$type/g;
if ($exit) { print STDERR "curl: ($exit) the stand-in failed\n"; print $w; exit $exit; }
if ($maxf ne '' && length($body) > $maxf) { print STDERR "curl: (63) Exceeded the maximum allowed file size\n"; print $w; exit 63; }
if ($fail && $code >= 400) { print STDERR "curl: (22) The requested URL returned error: $code\n"; print $w; exit 22; }
if ($out eq '') { print $body; }
elsif ($out ne '/dev/null') { open(my $o, '>', $out) or die; print $o $body; close $o; }
print $w;
exit 0;
CURL
# The stand-in security for set-up and doctor (OFFPRINT_SECURITY): what os/darwin/secret asks of it for the site
# "example": set (security -i, reading its one command line) and get. It keeps the value turned round, in STUBS/keychain
# (so the token is in no file as written), and notes in security.stored whether what was stored is the token. Its
# arguments are noted in security.argv. secret_locked: 152 for anything (a locked keychain, from a process with no
# terminal); set_locked: 152 for a set; set_lies: a set says it worked (0) and stores nothing; set_other: a set stores
# another value; get_fails: a get fails with 7 (not a locked keychain, not a missing item); nothing stored (or
# secret_missing): 44 for a get.
cat > "$tmp/keychain.pl" <<'KEYCHAIN'
#!/usr/bin/perl
use strict;
use warnings;
my $s = '@STUBS@';
my $back = '@BACK@';
sub note { my ($name, $text) = @_; open(my $h, '>>', "$s/$name") or die "$s/$name: $!"; print $h $text; close $h; }
sub slurp { my ($f) = @_; open(my $h, '<', $f) or return ''; local $/; my $t = <$h>; close $h; return defined $t ? $t : ''; }
@ENVCHECK@
envcheck('security');
note('security.argv', join(' ', @ARGV) . "\n");
if (-e "$s/secret_locked") { print STDERR "security: unable to obtain authorization for this operation.\n"; exit 152; }
if (@ARGV == 1 && $ARGV[0] eq '-i') {
  if (-e "$s/set_locked") { exit 152; }
  my $line = <STDIN>; $line = '' unless defined $line; chomp $line;
  if ($line =~ /\Aadd-generic-password -U -s offprint -a example\/cloudflare-token -X ([0-9a-f]+)\z/) {
    my $v = pack('H*', $1);
    exit 0 if -e "$s/set_lies";                                 # says it stored it, and didn't
    $v = 'another-value-abcdefghij' if -e "$s/set_other";       # stores something else (nothing of the token in it)

    open(my $k, '>', "$s/keychain") or die; print $k scalar(reverse($v)), "\n"; close $k;
    note('security.stored', ($v eq reverse($back) ? 'the token' : 'another value') . "\n");
    exit 0;
  }
  print STDERR "security (stand-in): unexpected\n"; exit 2;
}
if (join(' ', @ARGV) eq 'find-generic-password -s offprint -a example/cloudflare-token -w') {
  # lock_after_set: the Keychain locks once something is stored (between set-up's store and its read-back, say)
  if (-e "$s/lock_after_set" && -e "$s/security.stored") { print STDERR "security: unable to obtain authorization for this operation.\n"; exit 152; }
  if (-e "$s/get_fails") { print STDERR "security: it broke\n"; exit 7; }   # security failing some other way: status 7
  if (-e "$s/secret_missing" || !-e "$s/keychain") { print STDERR "security: The specified item could not be found in the keychain.\n"; exit 44; }
  my $v = slurp("$s/keychain"); chomp $v; print scalar(reverse($v)), "\n"; exit 0;
}
print STDERR "security (stand-in): unexpected\n"; exit 2;
KEYCHAIN
# The set-up cases' docker (first on their PATH, in front of the suite's): Docker's record of WordPress's container, for
# the doctor; everything else asked of the suite's stand-in. docker_down: Docker isn't running (every call fails);
# wp_none: WordPress has no container; else its id, and its environment as docker inspect gives it ({{json
# .Config.Env}}), from STUBS/wp_env (see wp_origin).
cat > "$tmp/docker-wp" <<'STUB'
if [ -e "$S/docker_down" ]; then echo "Cannot connect to the Docker daemon (the stand-in)" >&2; exit 1; fi
case " $* " in
  *" inspect "*) echo "$*" >> "$S/docker.inspect"; cat "$S/wp_env"; exit 0 ;;
  *" ps -a -q wordpress "*) echo "$*" >> "$S/docker.ps"; [ -e "$S/wp_none" ] || echo c0ffee000001; exit 0 ;;
esac
exec "$SHARED" "$@"
STUB
# wp_origin URL: the environment WordPress's container was made with (templates/compose.yaml) names URL as its public
# address, as docker inspect shows it
wp_origin() {
  printf '["WORDPRESS_DB_HOST=db","WORDPRESS_CONFIG_EXTRA=if ( isset( $_SERVER[%s] ) ) {\\n    $_SERVER[%s] = %s;\\n}\\ndefine( %s, %s );\\ndefine( %s, true );\\n","PATH=/usr/local/bin:/usr/bin"]\n' \
    "'HTTP_X_FORWARDED_PROTO'" "'HTTPS'" "'on'" "'OFFPRINT_PUBLIC_ORIGIN'" "'$1'" "'DISALLOW_FILE_EDIT'" > "$S/wp_env"
}
# wrap.pl: in place of a common command (WRAPPED, first on the PATH): envcheck, then the real one (REAL). wrap_tools:
# one for each command set-up, doctor, os/darwin/secret and a publish run, in
# STUBS/bin; each run noted in STUBS/env.ran.
cat > "$tmp/wrap.pl" <<'WRAP'
#!/usr/bin/perl
use strict;
use warnings;
my $s = '@STUBS@';
@ENVCHECK@
envcheck('@NAME@');
# (a variable the tool sets for itself, never one it exports: seen here, an inherited allexport is still on)
{ my @own = grep { exists $ENV{$_} } qw(TOOL OFFPRINT_SYSTEM_PATH WARNINGS);
  if (@own and open(my $o, '>>', "$s/env.own")) { print $o "@NAME@: @own\n"; close $o; } }
if (open(my $r, '>>', "$s/env.ran")) { print $r "@NAME@\n"; close $r; }
exec { '@REAL@' } '@REAL@', @ARGV or die "@REAL@: $!";
WRAP
wrap_tools() {
  local t w real
  for t in php git mktemp mkfifo rm chmod mkdir cp mv head tr cut cat sleep pgrep readlink find id stty ls sort sed awk grep tail paste wc dirname basename uname date; do
    if [ "$t" = php ]; then real="$(command -v php)"; else real="$(PATH=/usr/bin:/bin command -v "$t")"; fi
    [ -n "$real" ] || continue
    stand_in "$tmp/wrap.pl" "$S/bin/$t"; w="$(cat "$S/bin/$t")"; w="${w//@NAME@/$t}"; w="${w//@REAL@/$real}"; printf '%s\n' "$w" > "$S/bin/$t"
  done
}
# cs_case [SETTINGS]: a site naming cloudflare-workers (cf_case's), with nothing set up: OH, its Offprint folder,
# absent; CFD its cloudflare-workers folder, DEST where wrangler goes; the stand-ins above; NODE_PHYS, the stand-in
# node's physical path; CS_PATH, the PATH the set-up runs with.
cs_case() {
  cf_case "$@"; rm -rf "$tmp/case$n/ohome"
  OH="$tmp/case$n/ohome"; CFD="$OH/cloudflare-workers"; DEST="$CFD/wrangler-4.166.0"
  stand_in "$tmp/npm.pl" "$tmp/case$n/node bin/npm"; stand_in "$tmp/curl.pl" "$S/bin/curl"; stand_in "$tmp/keychain.pl" "$S/security"
  printf '#!/usr/bin/env bash\nS=%s; SHARED=%s\n' "$S" "$tmp/bin/docker" > "$S/bin/docker"; cat "$tmp/docker-wp" >> "$S/bin/docker"; chmod +x "$S/bin/docker"
  wp_origin https://www.example.com
  mkdir -p "$tmp/case$n/links" "$tmp/case$n/phpbin"; ln -s "$NODE" "$tmp/case$n/links/node"; ln -s "$(command -v php)" "$tmp/case$n/phpbin/php"
  NODE_PHYS="$(cd "$tmp/case$n/node bin" && pwd -P)/node"
  CS_PATH="$S/bin:$tmp/bin:$tmp/case$n/phpbin:$tmp/case$n/links:/usr/bin:/bin"
}
# cs_install: what set-up makes, made here: wrangler 4.166.0 in DEST (its entry script and package.json), and the node
# file naming the stand-in node. seed: the Keychain holds the token (turned round, as the stand-in keeps it).
cs_install() {
  mkdir -p "$DEST/node_modules/wrangler/bin" "$DEST/node_modules/.bin"; echo '// the stand-in node never reads this' > "$DEST/node_modules/wrangler/bin/wrangler.js"
  ln -s ../wrangler/bin/wrangler.js "$DEST/node_modules/.bin/wrangler"; ln -s ../wrangler/bin/wrangler.js "$DEST/node_modules/.bin/wrangler2"
  printf '{\n  "name": "wrangler",\n  "version": "4.166.0"\n}\n' > "$DEST/node_modules/wrangler/package.json"
  printf '%s\n' "$NODE_PHYS" > "$CFD/node"
}
seed() { printf '%s\n' "$TOKEN_BACK" > "$S/keychain"; }
cs() {  # cs [ARGS]: offprint adapter setup ARGS for the site, with the stand-ins, stdin the caller's; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash ${CS_X:+-x} "$SRC/bin/offprint" adapter setup "$@" 2>&1)"; code=$?
}
cdoc() {  # offprint adapter doctor for the site, with the stand-ins; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter doctor 2>&1 < /dev/null)"; code=$?
}
feed() { printf '%s\n' "$@"; }   # the answers, one a line (the shell's own printf: no program is handed the token)
last() { printf '%s\n' "$out" | tail -n 1; }
asked() { printf '%s\n' "$out" | grep -c '\[y/N\]'; }
wver() { php -r '$j = json_decode( (string) @file_get_contents( $argv[1] ), true ); echo is_array( $j ) && isset( $j["version"] ) ? $j["version"] : "none";' "$DEST/node_modules/wrangler/package.json"; }
whole() { if [ -f "$DEST/node_modules/wrangler/bin/wrangler.js" ] && [ "$(wver)" = 4.166.0 ]; then echo yes; else echo no; fi; }
beside() { ls -A "$CFD" 2>/dev/null | paste -sd' ' -; }   # what is in the cloudflare-workers folder
oh_state() {  # every file and folder in the Offprint folder: its name and inode, and each file's checksum
  [ -e "$OH" ] || { echo none; return; }
  ( cd "$OH" && { find . -exec ls -di {} +; find . -type f -exec cksum {} +; } 2>&1 | LC_ALL=C sort )
}
cs_tmp_empty() { check "$1: nothing left in TMPDIR (its private folder, the adapter's)" "" "$(ls -A "$tmp/case$n/tmpdir")"; }
CF_URL="https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts"
PERM="Account → Workers Scripts → Edit"
# What set-up and doctor say of a token Cloudflare answers 200 for: it knows the token and it can see the account; not
# that it may upload (it answers so for a token without the Workers permission too), which only a publish shows. And of
# one it answers 401 for: it doesn't know it, so the permission is not the advice.
KNOWS_STORED="  ok: Cloudflare knows the token already in your login Keychain, and it can see this site's account (a publish shows whether it may upload: it needs $PERM)."
KNOWS_PASTED="  ok: Cloudflare knows the token, and it can see this site's account; it is in your login Keychain now (a publish shows whether it may upload: it needs $PERM)."
KNOWS_DOCTOR="ok       Cloudflare knows the token in your login Keychain, and it can see this site's account (a publish shows whether it may upload: it needs $PERM)"
W401="it was mistyped or cut short when copied, or has been deleted or rolled since"
check "cloudflare-workers: setup.sh has no here-document or here-string" 0 \
  "$(if [ -f "$SRC/adapters/cloudflare-workers/setup.sh" ]; then grep -c '<<' "$SRC/adapters/cloudflare-workers/setup.sh"; else echo missing; fi)"

# From nothing: node recorded (its links followed), wrangler installed by npm ci from the lockfile in a new folder moved
# into place, the token checked with Cloudflare and only then stored.
cs_case; t="offprint adapter setup, from nothing"
cs < <(feed y y y "$TOKEN")
check "$t: done, exit 0" 0 "$code"
check "$t: three questions, one a step" 3 "$(asked)"
contains "$t: says it makes nothing on Cloudflare" "Nothing is made on Cloudflare here: a publish makes the Worker when it isn't there yet." "$out"
for s in "Step 1 of 3: node" "Step 2 of 3: wrangler 4.166.0" "Step 3 of 3: the Cloudflare API token" "$PERM" \
    "https://dash.cloudflare.com/profile/api-tokens" "Set-up is done."; do contains "$t: says '$s'" "$s" "$out"; done
contains "$t: the token: ok, saying only what Cloudflare's answer shows" "$KNOWS_PASTED" "$out"
contains "$t: set-up's last lines: what comes next, promising no upload" "Set-up is done. offprint adapter doctor checks it all, and the live site. The first offprint publish shows whether the token may upload; when it may, it makes the Worker my-site." "$(printf '%s\n' "$out" | tail -n 2 | paste -sd' ' -)"
lacks "$t: nothing says Cloudflare accepts the token" "accept" "$out"
contains "$t: says what step 1 does first" "The node on your PATH is $NODE_PHYS (v22.12.0): set-up will write its path in $CFD/node." "$out"
check "$t: the node recorded: the one on the PATH, its link followed to its file" "$NODE_PHYS" "$(cat "$CFD/node" 2>&1)"
check "$t: wrangler 4.166.0 installed, whole" yes "$(whole)"
check "$t: and nothing else left beside it" "node wrangler-4.166.0" "$(beside)"
check "$t: npm ran once (the one beside the node: links/ has none)" 1 "$(calls npm.runs)"
W="$(sed -n 's/^HOME=//p' "$S/npm.values" 2>/dev/null)"; W="${W%/home}"
case "$W" in "$(cd "$tmp/case$n/tmpdir" && pwd -P)/offprint-cf-setup."??????) ok "$t: npm's HOME was in a private folder in TMPDIR" ;; *) bad "$t: npm's HOME was in '$W'" ;; esac
check "$t: npm's arguments" "ci|--ignore-scripts|--include=optional|--no-audit|--no-fund|--no-update-notifier|--registry=https://registry.npmjs.org/|--userconfig=$W/npmrc|--globalconfig=$W/npmrc-global|--cache=$W/cache" \
  "$(paste -sd'|' - < "$S/npm.argv")"
check "$t: its environment: exactly HOME, PATH and TMPDIR" "HOME|PATH|TMPDIR" "$(paste -sd'|' - < "$S/npm.env")"
check "$t: their values (node's own folder first on PATH)" "HOME=$W/home|PATH=${NODE_PHYS%/node}:/usr/bin:/bin|TMPDIR=$W/tmp" "$(paste -sd'|' - < "$S/npm.values")"
case "$(cat "$S/npm.cwd")" in "$(cd "$CFD" && pwd -P)/.wrangler-4.166.0."??????) ok "$t: npm ran in a new folder beside where wrangler goes" ;; *) bad "$t: npm ran in '$(cat "$S/npm.cwd")'" ;; esac
check "$t: holding the adapter's package.json and package-lock.json, exactly" "the adapter's" "$(cat "$S/npm.files")"
check "$t: npm's stdin is empty, and not a terminal" "empty, not a terminal" "$(cat "$S/npm.stdin")"
check "$t: node --version ran, with an empty environment" "yes|" "$(exists "$S/node.version")|$(head -n 1 "$S/node.version" 2>&1)"
check "$t: the token was checked: curl's arguments (-q first: no .curlrc; no redirect followed; nothing of the token)" \
  "-q -s --proto =https --max-time 30 --max-filesize 16777216 --config - -w \\n%{http_code} $CF_URL" "$(head -n 1 "$S/curl.argv")"
check "$t: curl's environment: PATH alone" "PATH" "$(head -n 1 "$S/curl.env")"
check "$t: the Authorization header it read held the token entered" "the stored token" "$(cat "$S/curl.header")"
check "$t: the Keychain was asked whether one is stored, then the token stored, through security -i, then read back" \
  "find-generic-password -s offprint -a example/cloudflare-token -w|-i|find-generic-password -s offprint -a example/cloudflare-token -w|the token" \
  "$(paste -sd'|' - < "$S/security.argv")|$(cat "$S/security.stored" 2>&1)"
check "$t: git sees nothing new in the site folder" "" "$(git -C "$c" status --porcelain)"
cs_tmp_empty "$t"; no_leak "$t"
before="$(oh_state)"; cs < /dev/null; t="offprint adapter setup again, everything set up, nothing on stdin"
check "$t: done, exit 0, nothing asked" "0|0" "$code|$(asked)"
contains "$t: node: ok" "ok: node v22.12.0 at $NODE_PHYS, recorded already." "$out"
contains "$t: wrangler: ok" "ok: wrangler 4.166.0 is installed already, in $DEST." "$out"
contains "$t: the token: ok, saying only what Cloudflare's answer shows" "$KNOWS_STORED" "$out"
check "$t: npm didn't run again, nothing was stored again; the token stored was checked" \
  "1|find-generic-password -s offprint -a example/cloudflare-token -w|-i|find-generic-password -s offprint -a example/cloudflare-token -w|find-generic-password -s offprint -a example/cloudflare-token -w|the stored token" \
  "$(calls npm.runs)|$(paste -sd'|' - < "$S/security.argv")|$(sed -n 2p "$S/curl.header")"
check "$t: the Offprint folder is as it was" "$before" "$(oh_state)"
cs_tmp_empty "$t"; no_leak "$t"
# OFFPRINT_HOME unset: the Offprint folder is HOME/Library/Application Support/Offprint (a space in it), as the deploy
# has it.
cs_case; t="offprint adapter setup --yes, OFFPRINT_HOME unset"; OH="$tmp/case$n/home/Library/Application Support/Offprint"; CFD="$OH/cloudflare-workers"; DEST="$CFD/wrangler-4.166.0"
out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" HOME="$tmp/case$n/home" OFFPRINT_SECURITY="$S/security" \
  TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter setup --yes 2>&1 < <(feed "$TOKEN"))"; code=$?
check "$t: done, nothing asked but the token" "0|$NODE_PHYS|yes|the token" "$code|$(cat "$CFD/node" 2>&1)|$(whole)|$(cat "$S/security.stored" 2>&1)"
contains "$t: each step's question answered by --yes" "Install wrangler 4.166.0? [y/N] yes (--yes)" "$out"
cs_tmp_empty "$t"; no_leak "$t"

# node: too old, unreadable, absent, or at a path a publish can't run.
for v in v22.11.0 v20.18.1; do
  cs_case; printf '%s\n' "$v" > "$S/node_version"; cs --yes < /dev/null; t="offprint adapter setup, node $v"
  check "$t: refused, exit 1, naming the node, its version and the one needed" \
    "1|The node on your PATH, $NODE_PHYS, is $v; wrangler 4.166.0 needs node 22.12.0 or newer. Install a newer node (from https://nodejs.org, or with Homebrew: brew install node, or nvm install 22), then run offprint adapter setup again." "$code|$(last)"
  check "$t: nothing made (no Offprint folder); npm, the Keychain and Cloudflare never asked" "none|0|no|no" "$(oh_state)|$(calls npm.runs)|$(exists "$S/security.argv")|$(exists "$S/curl.argv")"
done
cs_case; printf 'not a version\n' > "$S/node_version"; cs --yes < /dev/null; t="offprint adapter setup, a node that doesn't say its version"
check "$t: refused, exit 1" "1|The node on your PATH, $NODE_PHYS, didn't say its version (node --version printed none); reinstall node (https://nodejs.org), then run offprint adapter setup again." "$code|$(last)"
check "$t: nothing made" none "$(oh_state)"
cs_case; CS_PATH="$S/bin:$tmp/bin:$tmp/case$n/phpbin:/usr/bin:/bin"; t="offprint adapter setup, no node on the PATH"
check "control: $t: there is none on it" "" "$(PATH="$CS_PATH"; command -v node)"
cs --yes < /dev/null
check "$t: refused, exit 1" "1|node isn't on your PATH. wrangler 4.166.0 needs node 22.12.0 or newer: install it (from https://nodejs.org, or with Homebrew: brew install node), open a new terminal, then run offprint adapter setup again." "$code|$(last)"
check "$t: nothing made" none "$(oh_state)"
cs_case; mkdir -p "$tmp/case$n/odd:dir"; cp "$NODE" "$tmp/case$n/odd:dir/node"; rm "$tmp/case$n/links/node"; ln -s "$tmp/case$n/odd:dir/node" "$tmp/case$n/links/node"
cs --yes < /dev/null; t="offprint adapter setup, the node on the PATH a link to one in a folder with a colon in its name"
check "$t: refused, exit 1" "1|The node on your PATH is at $(cd "$tmp/case$n/odd:dir" && pwd -P)/node, a path a publish can't run node from (it has a colon or a control character in it); install node in another folder, then run offprint adapter setup again." "$code|$(last)"
check "$t: nothing made" none "$(oh_state)"
# Another node recorded before: asked whether to record the one on the PATH instead; no keeps the one recorded.
cs_case; mkdir -p "$CFD" "$tmp/case$n/old bin"; cp "$NODE" "$tmp/case$n/old bin/node"; cs_install; seed
old="$(cd "$tmp/case$n/old bin" && pwd -P)/node"; printf '%s\n' "$old" > "$CFD/node"
cs < <(feed n); t="offprint adapter setup, another node recorded, the answer no"
check "$t: done, exit 0, one question" "0|1" "$code|$(asked)"
contains "$t: says which it replaces" "It replaces $old, recorded before." "$out"
check "$t: the node recorded is kept" "$old|The node recorded before is kept." "$(cat "$CFD/node")|$(printf '%s\n' "$out" | grep -o 'The node recorded before is kept.')"
cs < <(feed y); t="offprint adapter setup, another node recorded, the answer yes"
check "$t: done; the one on the PATH recorded" "0|$NODE_PHYS" "$code|$(cat "$CFD/node")"; cs_tmp_empty "$t"

# npm ci failing, or making something that isn't wrangler 4.166.0: nothing installed, nothing half-installed left.
cs_case; touch "$S/npm_fail"; cs < <(feed y y y "$TOKEN"); t="offprint adapter setup, npm ci failing"
check "$t: stopped, exit 1, saying so: npm's messages say why; what to do" "1|npm ci failed (it ended with status 1), so nothing was installed. npm's messages above say why (the network is only one possible cause); fix that, then run offprint adapter setup again." "$code|$(last)"
npmlog="$(printf '%s\n' "$out" | sed -n 's/^npm error A complete log of this run can be found in: //p')"
check "control: $t: npm named its log file" yes "$([ -n "$npmlog" ] && echo yes || echo no)"
check "$t: that log is gone with set-up's private folder (kept: no)" no "$(exists "${npmlog:-/nonexistent}")"
check "$t: and the line before the last says so" "A log file npm names above was in set-up's private folder, which is removed: npm's lines above are all there is of it." \
  "$(printf '%s\n' "$out" | tail -n 2 | head -n 1)"
contains "$t: npm's own message is there" "npm error the stand-in failed" "$out"
check "$t: nothing half-installed: only the node file beside where wrangler goes" "node" "$(beside)"
check "$t: the token was never asked for: neither the Keychain nor Cloudflare" "no|no" "$(exists "$S/security.argv")|$(exists "$S/curl.argv")"
cs_tmp_empty "$t"; no_leak "$t"
# npm's own files (its HOME, TMPDIR, cache and two config files) go in set-up's private folder in TMPDIR: when one can't
# be made there, that is the folder named (not the cloudflare-workers folder, where wrangler's new folder goes).
cs_case; printf '#!/bin/sh\ncase "$*" in *offprint-cf-setup.*/home*) exit 1 ;; esac\nexec /bin/mkdir "$@"\n' > "$S/bin/mkdir"; chmod +x "$S/bin/mkdir"
cs < <(feed y y y "$TOKEN"); t="offprint adapter setup, npm's files can't be made in set-up's private folder"
case "$code|$(last)" in
  "1|npm's files couldn't be made in set-up's private folder in TMPDIR, $(cd "$tmp/case$n/tmpdir" && pwd -P)/offprint-cf-setup."??????" (is the disk full?); nothing was installed.") ok "$t: stopped, exit 1, naming that folder" ;;
  *) bad "$t: stopped, exit 1, naming that folder (got '$code|$(last)')" ;;
esac
check "$t: npm never ran, nothing installed" "0|node" "$(calls npm.runs)|$(beside)"; cs_tmp_empty "$t"
for spec in "npm_version|4.165.0|its node_modules/wrangler/package.json says version 4.165.0" "npm_noentry||there is no node_modules/wrangler/bin/wrangler.js"; do
  f="${spec%%|*}"; rest="${spec#*|}"; v="${rest%%|*}"; why="${rest#*|}"
  cs_case; printf '%s\n' "$v" > "$S/$f"; cs --yes < /dev/null; t="offprint adapter setup, npm ci making ${v:-no entry script}"
  check "$t: refused, exit 1" "1|npm ci finished, but what it made isn't wrangler 4.166.0 ($why), so nothing was installed; run offprint adapter setup again." "$code|$(last)"
  check "$t: nothing installed" "node" "$(beside)"; cs_tmp_empty "$t"
done
# What is in wrangler-4.166.0 isn't whole: replaced; folders a stopped set-up left (a new one, an old one) go.
cs_case; mkdir -p "$DEST/node_modules/wrangler" "$CFD/.wrangler-4.166.0.abcdef/node_modules" "$CFD/.old-wrangler.ghijkl/wrangler-4.166.0"
printf '{"version": "4.166.0"}\n' > "$DEST/node_modules/wrangler/package.json"; echo old > "$DEST/marker"
cs --yes < <(feed "$TOKEN"); t="offprint adapter setup, an incomplete wrangler-4.166.0, and folders a stopped set-up left"
contains "$t: says it will be replaced" "What is in $DEST now isn't a whole wrangler 4.166.0 (there is no node_modules/wrangler/bin/wrangler.js): it will be replaced." "$out"
check "$t: done; replaced by a whole one" "0|yes|no" "$code|$(whole)|$(exists "$DEST/marker")"
check "$t: nothing else left beside it" "node wrangler-4.166.0" "$(beside)"; cs_tmp_empty "$t"
# Each step's answer no (or no answer at all): nothing more done.
cs_case; cs < /dev/null; t="offprint adapter setup, no answer (end of input)"
check "$t: stopped, exit 1, nothing made" "1|Nothing was changed. Run offprint adapter setup again when you're ready.|none" "$code|$(last)|$(oh_state)"
cs < <(feed n); check "offprint adapter setup, step 1 answered no: stopped, nothing made" "1|Nothing was changed. Run offprint adapter setup again when you're ready.|none" "$code|$(last)|$(oh_state)"
cs < <(feed y n); t="offprint adapter setup, step 2 answered no"
check "$t: stopped, exit 1; the node recorded, npm never run" "1|wrangler wasn't installed, and a publish needs it. Run offprint adapter setup again when you're ready.|node|0" "$code|$(last)|$(beside)|$(calls npm.runs)"
cs < <(feed y n); t="offprint adapter setup, step 3 answered no"
check "$t: stopped, exit 1; wrangler installed, nothing stored, Cloudflare never asked" "1|No token was stored, and a publish needs one. Run offprint adapter setup again when you have it.|yes|no|no" \
  "$code|$(last)|$(whole)|$(exists "$S/keychain")|$(exists "$S/curl.argv")"
cs_tmp_empty "$t"

# The token: refused by Cloudflare (the permission to add named), not plainly a token, or not checkable: nothing stored.
cs_case; mkdir -p "$CFD"; cs_install; echo 403 > "$S/cf_status"; CS_X=1 cs < <(feed y "$TOKEN"); t="offprint adapter setup, Cloudflare refusing the token (run with bash -x)"
has "control: $t: set -x traced the command" "+ offprint_adapter_call adapter_setup" "$out"
qcheck "$t: stopped, exit 1, naming account_id first" "1|Cloudflare refused the token for the account $ACCOUNT (HTTP 403: 10000 Authentication error), so nothing was stored. Most often account_id in site.json is wrong: check it against the account's id on its page in Cloudflare's dashboard. If it is right, the token is for another account: make one for this account at https://dash.cloudflare.com/profile/api-tokens, then run offprint adapter setup again." \
  "$code|$(printf '%s\n' "$out" | grep '^Cloudflare refused')"
check "$t: nothing stored (the Keychain was only asked whether one is)" "find-generic-password -s offprint -a example/cloudflare-token -w|no" "$(paste -sd'|' - < "$S/security.argv")|$(exists "$S/keychain")"
cs_tmp_empty "$t"; no_leak "$t"
cs_case; mkdir -p "$CFD"; cs_install; cs < <(feed y XYTOKEN-another-one-ABCDEFGHIJ); t="offprint adapter setup, a token Cloudflare doesn't know (HTTP 401)"
check "$t: refused, nothing stored" "1|another value|no" "$code|$(cat "$S/curl.header")|$(exists "$S/keychain")"
check "$t: saying Cloudflare doesn't know it, and what to do; not the permission" "1|Cloudflare doesn't know that token (HTTP 401: 10000 Authentication error), so nothing was stored: $W401. Paste it whole, or make a new one at https://dash.cloudflare.com/profile/api-tokens, then run offprint adapter setup again." "$code|$(last)"
lacks "$t: no permission advice" "It needs the permission" "$out"
cs_case; mkdir -p "$CFD"; cs_install; echo 400 > "$S/cf_status"; touch "$S/cf_echo"; cs < <(feed y "$TOKEN"); t="offprint adapter setup, Cloudflare's error repeating the token"
qcheck "$t: refused, the token hidden in what Cloudflare said" "1|Cloudflare refused the token (HTTP 400: 6111 Invalid format for Authorization header: Bearer [token hidden]), so nothing was stored. It needs the permission $PERM, for the account $ACCOUNT (site.json's account_id): edit it at https://dash.cloudflare.com/profile/api-tokens, or make a new one, then run offprint adapter setup again." "$code|$(last)"
no_leak "$t"
cs_case; mkdir -p "$CFD"; cs_install; echo 404 > "$S/cf_status"; printf '{"success":false,"errors":[{"code":7003,"message":"Could not route to /accounts, perhaps your object identifier is invalid?"}]}' > "$S/cf_body"
cs < <(feed y "$TOKEN"); t="offprint adapter setup, Cloudflare finding no such account"
check "$t: refused, naming account_id" "1|Cloudflare found no account $ACCOUNT for the token (HTTP 404: 7003 Could not route to /accounts, perhaps your object identifier is invalid?), so nothing was stored. Check account_id in site.json (the account's id is on its page in Cloudflare's dashboard), and that the token is for that account, then run offprint adapter setup again." "$code|$(last)"
check "$t: nothing stored" no "$(exists "$S/keychain")"
for spec in "cf_exit|6|api.cloudflare.com couldn't be reached: its name couldn't be looked up|check your connection" \
    "cf_exit|7|api.cloudflare.com couldn't be reached: no connection could be made|check your connection" \
    "cf_exit|28|api.cloudflare.com couldn't be reached: it didn't answer within 30 seconds|check your connection" \
    "cf_exit|60|api.cloudflare.com couldn't be reached: the secure connection failed|check your connection" \
    "cf_status|503|Cloudflare answered HTTP 503, an error on its side|try again in a few minutes" \
    "cf_status|429|Cloudflare answered HTTP 429: too many requests|wait a minute" \
    "cf_status|302|Cloudflare answered HTTP 302, which isn't understood here|try again later"; do
  f="${spec%%|*}"; rest="${spec#*|}"; v="${rest%%|*}"; rest="${rest#*|}"; why="${rest%|*}"; fix="${rest#*|}"
  cs_case; mkdir -p "$CFD"; cs_install; echo "$v" > "$S/$f"; cs < <(feed y "$TOKEN"); t="offprint adapter setup, the check: $f $v"
  check "$t: stopped, exit 1, saying why and what to do" "1|The token couldn't be checked ($why), so nothing was stored: $fix, then run offprint adapter setup again." "$code|$(last)"
  check "$t: nothing stored" no "$(exists "$S/keychain")"
done
cs_case; mkdir -p "$CFD"; cs_install; echo 200 > "$S/cf_status"; printf '<html>a portal</html>' > "$S/cf_body"; cs < <(feed y "$TOKEN"); t="offprint adapter setup, Cloudflare answering 200 with something else"
check "$t: not taken for a yes; nothing stored" "1|The token couldn't be checked (Cloudflare's answer (HTTP 200) wasn't understood), so nothing was stored: try again later, then run offprint adapter setup again.|no" "$code|$(last)|$(exists "$S/keychain")"
cs_case; mkdir -p "$CFD"; cs_install; t="offprint adapter setup, what is entered isn't plainly a token"
long="$(printf '%01025d' 0 | tr 0 a)"
for v in "abcdefgh ijklmnopqrst" 'abcdefgh"ijklmnopqrst' 'abcdefgh\ijklmnopqrst' "abcdefgh'ijklmnopqrst" "abcdefghijklmno" "$long" "$(printf 'abcdefgh\tijklmnopqrst')"; do
  rm -f "$S/curl.argv"; cs < <(feed y "$v"); shown="$(printf '%s' "$v" | cut -c1-24)"
  check "$t: '$shown': refused, exit 1, before Cloudflare is asked" "1|What was entered isn't an API token (one is 16 to 1024 letters, digits and - _ . ~ + / =, with no spaces or quotes), so nothing was stored. Copy the token's value (Cloudflare shows it once, when it is made), then run offprint adapter setup again.|no|no" \
    "$code|$(last)|$(exists "$S/curl.argv")|$(exists "$S/keychain")"
  lacks "$t: '$shown': what was entered isn't shown" "$v" "$out"
done
cs < <(feed y ""); check "offprint adapter setup, nothing entered: refused, exit 1" "1|No token was entered, so nothing was stored. Run offprint adapter setup again when you have it.|no" "$code|$(last)|$(exists "$S/keychain")"
cs < <(feed y "  $TOKEN $(printf '\r')"); t="offprint adapter setup, the token pasted with spaces and a carriage return around it"
check "$t: taken without them, checked and stored" "0|the stored token|the token" "$code|$(cat "$S/curl.header")|$(cat "$S/security.stored" 2>&1)"
no_leak "$t"
# The Keychain locked: when the token stored is to be read, or when the new one is to be stored.
cs_case; mkdir -p "$CFD"; cs_install; seed; touch "$S/secret_locked"; cs < /dev/null; t="offprint adapter setup, the Keychain locked"
check "$t: stopped, exit 1, saying so; Cloudflare never asked" "1|The login Keychain is locked, so the token stored there couldn't be read. Unlock it (Keychain Access, or log out and back in), then run offprint adapter setup again.|no" "$code|$(last)|$(exists "$S/curl.argv")"
cs_case; mkdir -p "$CFD"; cs_install; touch "$S/set_locked"; cs < <(feed y "$TOKEN"); t="offprint adapter setup, the Keychain locked when the token is stored"
check "$t: stopped, exit 1, saying so" "1|The login Keychain is locked, so the token couldn't be stored. Unlock it (Keychain Access, or log out and back in), then run offprint adapter setup again." "$code|$(last)"
no_leak "$t"
# A token in the Keychain that Cloudflare now refuses: a new one is asked for. (The stand-in keeps it turned round: it
# is AN-OLD-ONE-ABCDEFGH, plainly a token, so it is sent.)
cs_case; mkdir -p "$CFD"; cs_install; printf '%s\n' "HGFEDCBA-ENO-DLO-NA" > "$S/keychain"; cs < <(feed y "$TOKEN"); t="offprint adapter setup, a token stored that Cloudflare doesn't know (HTTP 401)"
contains "$t: says so, and why that may be" "  Cloudflare doesn't know the token in your login Keychain (HTTP 401: 10000 Authentication error): $W401. Set-up will ask for a new one." "$out"
check "$t: the new one checked and stored" "0|another value|the stored token|the token" "$code|$(sed -n 1p "$S/curl.header")|$(sed -n 2p "$S/curl.header")|$(cat "$S/security.stored")"
# Cloudflare refusing the stored token (403): the permission; finding no such account for it (404): told apart, as the
# doctor does (account_id in site.json, or a token for another account). Either way a new one is asked for.
cs_case; mkdir -p "$CFD"; cs_install; seed; echo 403 > "$S/cf_status"; cs < <(feed y "$TOKEN"); t="offprint adapter setup, Cloudflare refusing the token stored (HTTP 403)"
contains "$t: says so" "  Cloudflare refuses the token in your login Keychain for the account $ACCOUNT (HTTP 403: 10000 Authentication error): most often account_id in site.json is wrong (answer n below, correct it, then run offprint adapter setup again); if it is right, the token is for another account, and set-up will ask for a new one." "$out"
cs_case; mkdir -p "$CFD"; cs_install; seed; echo 404 > "$S/cf_status"; printf '{"success":false,"errors":[{"code":7003,"message":"Could not route"}]}' > "$S/cf_body"
cs < <(feed y "$TOKEN"); t="offprint adapter setup, Cloudflare finding no account for the token stored (HTTP 404)"
contains "$t: says so, naming account_id" "  Cloudflare finds no account $ACCOUNT for the token in your login Keychain (HTTP 404: 7003 Could not route): check account_id in site.json (the account's id is on its page in Cloudflare's dashboard). If it is right, the token is for another account: set-up will ask for one for this account." "$out"
lacks "$t: not that it is refused" "refuses the token" "$out"

# Review Focus 2: while Cloudflare is asked, no process has the token, or any part of it, in its arguments.
cs_case; mkdir -p "$CFD"; cs_install; touch "$S/cf_hang"
( cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
  exec /bin/bash "$SRC/bin/offprint" adapter setup ) < <(feed y "$TOKEN") > "$S/oa.out" 2>&1 & pid=$!
i=0; while [ ! -e "$S/curl.hanging" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
t="offprint adapter setup, while Cloudflare is asked about the token"
check "control: $t: it is being asked" yes "$(exists "$S/curl.hanging")"
procs="$(ps -A -ww -o args= 2>/dev/null)"
# (Pieces of 8 digits alone aren't looked for here: any process on this machine may have such a run in its arguments.)
leaked=no; for p in "$TOKEN_A" "$TOKEN_B" $TOKEN_PIECES; do case "$p" in *[!0-9]*) case "$procs" in *"$p"*) leaked=yes ;; esac ;; esac; done
check "$t: no process has the token, or any part of it, in its arguments" no "$leaked"
touch "$S/cf_release"; wait "$pid"; code=$?; out="$(cat "$S/oa.out")"
check "$t: then done, the token stored" "0|the token" "$code|$(cat "$S/security.stored" 2>&1)"; no_leak "$t"

# Ctrl-C: at the token prompt, and while npm runs. It stops at once (130): nothing half-installed, no token stored, no
# process left, every private folder gone.
cs_case; mkdir -p "$CFD"; cs_install; before="$(oh_state)"
FEED='y\n' ctrl_c 'grep -q "Paste the token" "$S/oa.out" 2> /dev/null' setup; t="offprint adapter setup, Ctrl-C at the token prompt"
check "control: $t: it was at the prompt" yes "$(printf '%s' "$out" | grep -q 'Paste the token' && echo yes || echo no)"
check "$t: stopped at once, 130, saying so" "130|yes|Set-up was stopped. Nothing half-done is left; run offprint adapter setup again to finish." \
  "$code|$([ "$secs" -lt 5 ] && echo yes || echo no)|$(last)"
check "$t: no token stored; Cloudflare never asked" "find-generic-password -s offprint -a example/cloudflare-token -w|no|no" "$(paste -sd'|' - < "$S/security.argv")|$(exists "$S/keychain")|$(exists "$S/curl.argv")"
check "$t: the Offprint folder as it was" "$before" "$(oh_state)"; cs_tmp_empty "$t"
cs_case; touch "$S/npm_hang"
FEED='y\ny\n' ctrl_c '[ -e "$S/npm.hanging" ]' setup; t="offprint adapter setup, Ctrl-C while npm ci runs"
check "control: $t: npm was running" yes "$(exists "$S/npm.hanging")"
check "$t: stopped at once, 130, saying so" "130|yes|Set-up was stopped. Nothing half-done is left; run offprint adapter setup again to finish." \
  "$code|$([ "$secs" -lt 5 ] && echo yes || echo no)|$(last)"
check "$t: nothing half-installed: only the node file" "node" "$(beside)"
i=0; while [ -n "$(pgrep -f 'sleep 53')" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
check "$t: npm and its child are stopped" "|" "$(pgrep -f 'sleep 53')|$(pgrep -f 'npm ci --ignore-scripts')"
cs_tmp_empty "$t"
# At a terminal (a pseudo-terminal, made by script): read -s turns the terminal's echo off for the token; Ctrl-C there
# leaves it on again.
if script --version 2>/dev/null | grep -q util-linux; then pty_kind=util-linux; elif [ "$(uname -s)" = Darwin ]; then pty_kind=bsd; else pty_kind=""; fi
if [ -z "$pty_kind" ]; then echo "skip  Ctrl-C at the token prompt at a terminal (no script command to make one)"
else
  cs_case; mkdir -p "$CFD"; cs_install; t="offprint adapter setup --yes at a terminal, Ctrl-C at the token prompt"
  printf '%s\n' "/usr/bin/perl -e '\$SIG{INT} = \"DEFAULT\"; exec @ARGV' /bin/bash '$SRC/bin/offprint' adapter setup --yes 0<&0 &" \
    "echo \$! > '$S/pty.pid'; wait \$!; echo \$? > '$S/pty.rc'; stty -a > '$S/pty.stty' 2>&1" > "$S/pty.sh"
  # (script's stdin: a pipe from a waiter that writes nothing, and ends once pty.end is there: a FIFO is refused by the
  # Mac's script.)
  ( /usr/bin/perl -e 'my $i = 0; while (!-e $ARGV[0] && $i++ < 300) { select(undef, undef, undef, 0.1); }' "$S/pty.end" \
    | ( cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" SHELL=/bin/bash \
      exec /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or exit 127' sh -c \
        'if [ "$1" = util-linux ]; then exec script -qefc "/bin/bash $2" /dev/null; else exec script -q /dev/null /bin/bash "$2"; fi' sh "$pty_kind" "$S/pty.sh" ) ) \
    > "$S/pty.out" 2>&1 &
  pid=$!
  i=0; while ! grep -q "Paste the token" "$S/pty.out" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  check "control: $t: it was at the prompt, at a terminal" "yes|yes" "$(grep -q 'Paste the token' "$S/pty.out" 2>/dev/null && echo yes || echo no)|$(exists "$S/pty.pid")"
  kill -INT "$(cat "$S/pty.pid" 2>/dev/null)" 2>/dev/null
  i=0; while [ ! -s "$S/pty.stty" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  touch "$S/pty.end"; i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; fi; wait "$pid" 2>/dev/null
  check "$t: stopped, 130" 130 "$(cat "$S/pty.rc" 2>&1)"
  check "$t: the terminal's echo is on again" "1|0" "$(tr ' \t' '\n\n' < "$S/pty.stty" | grep -cx 'echo')|$(tr ' \t' '\n\n' < "$S/pty.stty" | grep -cx -- '-echo')"
  check "$t: no token stored" no "$(exists "$S/keychain")"; cs_tmp_empty "$t"
fi
# OFFPRINT_HOME that a publish can't use: refused, nothing made.
cs_case; mkdir -p "$c/var"; OH="$c/var/ohome"; cs --yes < /dev/null; t="offprint adapter setup, OFFPRINT_HOME inside the site folder"
check "$t: refused, exit 1, nothing made" "1|OFFPRINT_HOME, $c/var/ohome, is inside the site folder, which WordPress can write (and a publish runs wrangler from it); point it at a folder outside the site folder (or unset it), then run offprint adapter setup again.|no" "$code|$(last)|$(exists "$OH")"
cs_case; OH="ohome"; cs --yes < /dev/null; t="offprint adapter setup, OFFPRINT_HOME not an absolute path"
check "$t: refused, exit 1, nothing made" "1|OFFPRINT_HOME is ohome, not an absolute path; set it to one (or unset it), then run offprint adapter setup again.|no" "$code|$(last)|$(exists "$tmp/case$n/ohome")"
cs_case '"zone": "x"'; cs --yes < /dev/null; t="offprint adapter setup, a setting the adapter doesn't have"
check "$t: refused, exit 2, nothing made" "2|site.json: \"adapter.zone\" isn't a setting of the cloudflare-workers adapter (its two are worker and account_id).|Fix site.json, then run offprint adapter setup again.|none" \
  "$code|$(printf '%s\n' "$out" | paste -sd'|' -)|$(oh_state)"

# === cloudflare-workers: offprint adapter doctor ===
# One line a check, ok or problem, a problem ending with what to do; exit 0 only when every line is ok. It changes
# nothing: no file made, changed or removed anywhere (the site folder and its git objects, the Offprint folder, TMPDIR).
state() {  # every file and folder under the site folder (git's own too), the Offprint folder and the case's TMPDIR
  local d; for d in "$c" "$OH" "$tmp/case$n/tmpdir"; do
    [ -e "$d" ] && ( cd "$d" && { find . -exec ls -di {} +; find . -type f -exec cksum {} +; } 2>&1 | LC_ALL=C sort )
  done
}
U="https://www.example.com"; MISSING="$U/offprint-doctor-no-such-page/"
cs_case; mkdir -p "$CFD"; cs_install; seed; cfpub; id="$(id_of HEAD)"; t="offprint adapter doctor, everything in order"
check "control: $t: published, and live" "0|live" "$code|$(js state)"
rm -f "$S/curl.argv" "$S/curl.env" "$S/curl.header" "$S/security.argv"; before="$(state)"; cdoc
check "$t: every line ok, exit 0" "0|ok       wrangler 4.166.0 is installed, in $DEST|ok       node v22.12.0 runs, at $NODE_PHYS (set-up recorded it; a publish runs node by that path)|$KNOWS_DOCTOR|ok       WordPress exports for site.json's public_url, $U (Docker's record of its container says so)|ok       the live site serves the site repo's last publish: $U/offprint.json names HEAD's publish (${id:0:7})|ok       $U/feed/ answers 200 as application/rss+xml|ok       a made-up address, $MISSING, answers 404" \
  "$code|$(printf '%s\n' "$out" | paste -sd'|' -)"
check "$t: nothing made, changed or removed" "$before" "$(state)"
check "$t: the token checked as set-up checks it (curl -q, the token on its stdin)" "-q -s --proto =https --max-time 30 --max-filesize 16777216 --config - -w \\n%{http_code} $CF_URL|PATH|the stored token" \
  "$(grep -F "$CF_URL" "$S/curl.argv")|$(sed -n "$(grep -nF "$CF_URL" "$S/curl.argv" | cut -d: -f1)p" "$S/curl.env")|$(cat "$S/curl.header")"
check "$t: the Keychain only read" "find-generic-password -s offprint -a example/cloudflare-token -w" "$(cat "$S/security.argv")"
rm -f "$S/node.version"; cdoc; check "$t: node --version ran, with an empty environment" "yes|" "$(exists "$S/node.version")|$(cat "$S/node.version" 2>&1)"
no_leak "$t"
# Every line a problem.
cs_case; echo 200 > "$S/missing_status"; touch "$S/wp_none"; before="$(state)"; cdoc; id="$(id_of HEAD)"; t="offprint adapter doctor, nothing set up, nothing published"
check "$t: every line a problem, ending with what to do; exit 1" "1|problem  wrangler 4.166.0 isn't installed (there is no $DEST): run offprint adapter setup|problem  no node is recorded for wrangler (there is no $CFD/node): run offprint adapter setup|problem  no Cloudflare token is in your login Keychain for this site: run offprint adapter setup|problem  WordPress has no container (not made yet, or removed), so nothing can be exported: run offprint compose up -d|problem  the live site doesn't serve the site repo's last publish (${id:0:7}): $U/offprint.json answers 404 (nothing has been published there yet, or public_url in site.json isn't the Worker's address); run offprint publish|problem  $U/feed/ answers 404, not 200: run offprint publish (it writes the _redirects rule that serves the feed there)|problem  a made-up address, $MISSING, answers 200, not 404: run offprint publish (it sets the Worker to answer a missing page with 404.html, and 404)" \
  "$code|$(printf '%s\n' "$out" | paste -sd'|' -)"
check "$t: nothing made (no Offprint folder), nothing changed" "$before" "$(state)"
check "$t: Cloudflare never asked about a token" "" "$(grep -F api.cloudflare.com "$S/curl.argv")"
# Each check failing its own way: one line changes, the rest stay ok; exit 1.
dline() { printf '%s\n' "$out" | grep "^$1"; }   # dline TEXT: the line of the doctor's output that starts with TEXT
dcase() { cs_case; mkdir -p "$CFD"; cs_install; seed; mkdir -p "$S/live/feed"; echo '<rss/>' > "$S/live/feed/index.xml"; printf '{"publish":"%s"}\n' "$(id_of HEAD)" > "$S/live/offprint.json"; }
dcase; cdoc; check "the doctor's own control case: every line ok" "0|7" "$code|$(printf '%s\n' "$out" | grep -c '^ok  ')"
dcase; printf '{\n  "version": "4.165.0"\n}\n' > "$DEST/node_modules/wrangler/package.json"; cdoc; t="offprint adapter doctor, wrangler 4.165.0 in wrangler-4.166.0"
check "$t: that line a problem, exit 1" "1|problem  $DEST isn't a whole wrangler 4.166.0 (its node_modules/wrangler/package.json says version 4.165.0): run offprint adapter setup, which replaces it|6" "$code|$(dline problem)|$(printf '%s\n' "$out" | grep -c '^ok  ')"
dcase; rm "$DEST/node_modules/wrangler/bin/wrangler.js"; cdoc
check "offprint adapter doctor, no entry script: that line a problem" "1|problem  $DEST isn't a whole wrangler 4.166.0 (there is no node_modules/wrangler/bin/wrangler.js): run offprint adapter setup, which replaces it" "$code|$(dline problem)"
dcase; printf '%s\n' "$tmp/case$n/gone/node" > "$CFD/node"; cdoc
check "offprint adapter doctor, the node recorded gone" "1|problem  the node recorded in $CFD/node isn't there, or can't be run: run offprint adapter setup" "$code|$(dline problem)"
dcase; echo v20.0.0 > "$S/node_version"; cdoc
check "offprint adapter doctor, the node recorded too old" "1|problem  the node recorded, $NODE_PHYS, is v20.0.0; wrangler 4.166.0 needs 22.12.0 or newer: install a newer node, then run offprint adapter setup" "$code|$(dline problem)"
dcase; echo junk > "$S/node_version"; cdoc
check "offprint adapter doctor, the node recorded saying no version" "1|problem  the node recorded, $NODE_PHYS, didn't say its version (node --version printed none): reinstall node, then run offprint adapter setup" "$code|$(dline problem)"
dcase; touch "$S/secret_locked"; cdoc
check "offprint adapter doctor, the Keychain locked" "1|problem  your login Keychain is locked, so the Cloudflare token couldn't be read: unlock it, then run offprint adapter doctor again" "$code|$(dline problem)"
dcase; echo 403 > "$S/cf_status"; cdoc; t="offprint adapter doctor, Cloudflare refusing the token"
qcheck "$t: naming account_id first" "1|problem  Cloudflare refuses the token in your login Keychain for the account $ACCOUNT (HTTP 403: 10000 Authentication error): check account_id in site.json first (a token that lacks only the permission to upload passes this check); if it is right, the token is for another account: run offprint adapter setup with one for this account" "$code|$(dline problem)"
no_leak "$t"
dcase; echo 400 > "$S/cf_status"; touch "$S/cf_echo"; cdoc; t="offprint adapter doctor, Cloudflare's error repeating the token"
qcheck "$t: the token hidden" "1|problem  Cloudflare refuses the token in your login Keychain (HTTP 400: 6111 Invalid format for Authorization header: Bearer [token hidden]): give it the permission $PERM, for the account $ACCOUNT, then run offprint adapter setup" "$code|$(dline problem)"
no_leak "$t"
dcase; printf '%s\n' "HGFEDCBA-ENO-DLO-NA" > "$S/keychain"; cdoc; t="offprint adapter doctor, a token Cloudflare doesn't know (HTTP 401)"
check "$t: saying so, and why that may be; not the permission" "1|problem  Cloudflare doesn't know the token in your login Keychain (HTTP 401: 10000 Authentication error; $W401): run offprint adapter setup, and paste the token whole, or a new one" "$code|$(dline problem)"
dcase; echo 404 > "$S/cf_status"; printf '{"success":false,"errors":[{"code":7003,"message":"Could not route"}]}' > "$S/cf_body"; cdoc
check "offprint adapter doctor, Cloudflare finding no such account" "1|problem  Cloudflare finds no account $ACCOUNT for the token in your login Keychain (HTTP 404: 7003 Could not route): check account_id in site.json, then run offprint adapter setup" "$code|$(dline problem)"
dcase; echo 6 > "$S/cf_exit"; cdoc
check "offprint adapter doctor, Cloudflare not reached" "1|problem  the Cloudflare token in your login Keychain couldn't be checked (api.cloudflare.com couldn't be reached: its name couldn't be looked up): check your connection, then run offprint adapter doctor again" "$code|$(dline problem)"
dcase; echo 503 > "$S/cf_status"; cdoc
check "offprint adapter doctor, Cloudflare answering 503" "1|problem  the Cloudflare token in your login Keychain couldn't be checked (Cloudflare answered HTTP 503, an error on its side): try again in a few minutes, then run offprint adapter doctor again" "$code|$(dline problem)"
dcase; old="$(id_of HEAD)"; echo '<p>more</p>' > "$c/site/more.html"; git -C "$c" add -A site; git -C "$c" commit -q -m "more"; cdoc; t="offprint adapter doctor, the live site behind HEAD"
check "$t: that line a problem" "1|problem  the live site doesn't serve the site repo's last publish ($(id_of HEAD | cut -c1-7)): it still shows publish ${old:0:7}; run offprint publish" "$code|$(dline problem)"
dcase; printf '{"publish":""}\n' > "$S/live/offprint.json"; cdoc
check "offprint adapter doctor, an offprint.json that names no publish" "1|problem  the live site doesn't serve the site repo's last publish ($(id_of HEAD | cut -c1-7)): its offprint.json names no publish; run offprint publish" "$code|$(dline problem)"
dcase; echo 500 > "$S/missing_status"; rm "$S/live/offprint.json"; echo 503 > "$S/feed_status"; cdoc; t="offprint adapter doctor, the live site answering errors"
check "$t: offprint.json missing" "problem  the live site doesn't serve the site repo's last publish ($(id_of HEAD | cut -c1-7)): $U/offprint.json answers 404 (nothing has been published there yet, or public_url in site.json isn't the Worker's address); run offprint publish" "$(dline 'problem  the live')"
check "$t: the feed answering 503" "problem  $U/feed/ answers 503, not 200: run offprint publish (it writes the _redirects rule that serves the feed there)" "$(dline "problem  $U/feed/")"
check "$t: a made-up address answering 500" "problem  a made-up address, $MISSING, answers 500, not 404: run offprint publish (it sets the Worker to answer a missing page with 404.html, and 404)" "$(dline 'problem  a made-up')"
dcase; echo 'text/html; charset=utf-8' > "$S/feed_type"; cdoc
check "offprint adapter doctor, the feed served as text/html" "1|problem  $U/feed/ answers 200 as text/html, not application/rss+xml: run offprint publish (it writes the _headers rule that gives the feed its type)" "$code|$(dline problem)"
dcase; echo 7 > "$S/www_exit"; cdoc; t="offprint adapter doctor, the live site not reached"; id="$(id_of HEAD)"
check "$t: the three lines about it problems, saying so" "1|problem  the live site couldn't be asked for the site repo's last publish (${id:0:7}): $U/offprint.json couldn't be reached (no connection could be made); check public_url in site.json and your connection|problem  $U/feed/ couldn't be reached (no connection could be made): check public_url in site.json and your connection|problem  a made-up address, $MISSING, couldn't be reached (no connection could be made): check public_url in site.json and your connection" \
  "$code|$(dline problem | paste -sd'|' -)"
dcase; git -C "$c" rm -r -q site; git -C "$c" commit -q -m "no site/"; cdoc
check "offprint adapter doctor, HEAD with no site/" "1|problem  the site repo has nothing published yet (HEAD has no site/): run offprint publish" "$code|$(dline problem)"
dcase; OH="$c/var/ohome"; mkdir -p "$c/var"; cdoc; t="offprint adapter doctor, OFFPRINT_HOME inside the site folder"
check "$t: wrangler's and node's lines problems" "1|problem  wrangler can't be found: OFFPRINT_HOME, $c/var/ohome, is inside the site folder, which WordPress can write (and a publish runs wrangler from it); point it at a folder outside the site folder (or unset it), then run offprint adapter setup|problem  node can't be found: OFFPRINT_HOME, $c/var/ohome, is inside the site folder, which WordPress can write (and a publish runs wrangler from it); point it at a folder outside the site folder (or unset it), then run offprint adapter setup" \
  "$code|$(dline problem | paste -sd'|' -)"
check "$t: nothing made there" no "$(exists "$c/var/ohome")"
# Set-up's folder is the one the doctor and the deploy look in, OFFPRINT_HOME set or not.
cs_case; t="offprint adapter setup, then doctor and a publish, OFFPRINT_HOME unset"; OH="$tmp/case$n/home/Library/Application Support/Offprint"; CFD="$OH/cloudflare-workers"; DEST="$CFD/wrangler-4.166.0"
( cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" HOME="$tmp/case$n/home" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
  /bin/bash "$SRC/bin/offprint" adapter setup --yes > /dev/null 2>&1 ) < <(feed "$TOKEN")
out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" HOME="$tmp/case$n/home" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
  /bin/bash "$SRC/bin/offprint" adapter doctor 2>&1 < /dev/null)"
check "$t: the doctor finds wrangler, node and the token" "ok       wrangler 4.166.0 is installed, in $DEST|ok       node v22.12.0 runs, at $NODE_PHYS (set-up recorded it; a publish runs node by that path)|$KNOWS_DOCTOR" \
  "$(printf '%s\n' "$out" | head -n 3 | paste -sd'|' -)"
HOME="$tmp/case$n/home" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 pub
check "$t: a publish runs that wrangler, on that node, with that token" "0|live|1|CLOUDFLARE_API_TOKEN=the stored token" "$code|$(js state)|$(calls node.runs)|$(grep '^CLOUDFLARE_API_TOKEN=' "$S/node.values")"
no_leak "$t"

# === cloudflare-workers: the token read from the Keychain is checked as a pasted one is, and read back once stored ===
# The Keychain may hold a value stored some other way (in Keychain Access, say). One that isn't plainly an API token (16
# to 1024 letters, digits and - _ . ~ + / =) is never handed on, to curl or to node: doctor says so, set-up asks for a
# new one, and a publish fails saying what to run. (The stand-in keeps it turned round: this is 'not a token "at all"
# 0123456789'.)
BAD_BACK='9876543210 "lla ta" nekot a ton'
dcase; printf '%s\n' "$BAD_BACK" > "$S/keychain"; rm -f "$S/curl.argv"; cdoc; t="offprint adapter doctor, a stored token that isn't plainly a token"
check "$t: a problem, saying what to do; exit 1" "1|problem  the Cloudflare token in your login Keychain isn't plainly an API token (16 to 1024 letters, digits and - _ . ~ + / =), so it wasn't sent to Cloudflare: run offprint adapter setup, which asks for a new one" \
  "$code|$(dline 'problem  the Cloudflare token')"
check "$t: Cloudflare never asked" "" "$(grep -F api.cloudflare.com "$S/curl.argv" 2>/dev/null)"
dcase; printf '%s\n' "$BAD_BACK" > "$S/keychain"; rm -f "$S/curl.argv"; cs --yes < <(feed "$TOKEN"); t="offprint adapter setup --yes, a stored token that isn't plainly a token"
contains "$t: says so, and asks for a new one" "The token in your login Keychain isn't plainly an API token, so it wasn't sent to Cloudflare: set-up will ask for a new one." "$out"
check "$t: done, the token entered checked (the stored one never sent) and stored" "0|1|the token" "$code|$(grep -cF "$CF_URL" "$S/curl.argv")|$(cat "$S/security.stored" 2>&1)"
no_leak "$t"; cs_tmp_empty "$t"
dcase; printf '%s\n' "$BAD_BACK" > "$S/keychain"; t="a cloudflare-workers publish, a stored token that isn't plainly a token"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 OFFPRINT_HOME="$OH" \
  OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 /bin/bash "$SRC/bin/publish" 2>&1 < /dev/null)"; code=$?
check "$t: the deploy refused, in one line; node never ran" \
  "1|$(short) is pushed, but the deploy failed: the Cloudflare token in the Keychain isn't plainly an API token, so it wasn't used; run offprint adapter setup|0" \
  "$code|$(js message)|$(calls node.runs)"
cs_tmp_empty "$t"
# Set-up says the token is in the Keychain only once it has read it back and found it the same (compared in its own
# shell: no program is handed either): a Keychain that says it stored the token but didn't, or stored another value.
NOT_STORED="The login Keychain said it stored the token, but reading it back gave something else, so it isn't known to be stored. Run offprint adapter setup again; offprint adapter doctor says what is stored, and whether Cloudflare knows it."
for how in "set_lies|stored nothing" "set_other|stored another value"; do
  sw="${how%%|*}"; what="${how#*|}"
  cs_case; mkdir -p "$CFD"; cs_install; touch "$S/$sw"
  cs --yes < <(feed "$TOKEN"); t="offprint adapter setup --yes, a Keychain that says it stored the token, but $what"
  check "$t: not ok, exit 1, saying what to do" "1|no|$NOT_STORED" \
    "$code|$(printf '%s\n' "$out" | grep -q 'it is in your login Keychain' && echo yes || echo no)|$(last)"
  check "$t: it was read back" "-i|find-generic-password -s offprint -a example/cloudflare-token -w" "$(tail -n 2 "$S/security.argv" | paste -sd'|' -)"
  no_leak "$t"; cs_tmp_empty "$t"
done
# The Keychain locked when set-up reads the token back (it said it stored it): told apart from a different value read.
cs_case; mkdir -p "$CFD"; cs_install; touch "$S/lock_after_set"; cs --yes < <(feed "$TOKEN"); t="offprint adapter setup --yes, the Keychain locked when the token is read back"
check "$t: not ok, exit 1, saying it was locked (not that it gave something else)" "1|no|The login Keychain said it stored the token, but was locked when set-up read it back, so it isn't known to be stored. Unlock it (Keychain Access, or log out and back in), then run offprint adapter setup again." \
  "$code|$(printf '%s\n' "$out" | grep -q 'it is in your login Keychain' && echo yes || echo no)|$(last)"
check "$t: it was read back" "-i|find-generic-password -s offprint -a example/cloudflare-token -w" "$(tail -n 2 "$S/security.argv" | paste -sd'|' -)"
no_leak "$t"; cs_tmp_empty "$t"
# A stored value os/darwin/secret get refuses (not one line of printable ASCII: one stored some other way, in Keychain
# Access, say) is no dead end: set-up asks for a new one, which replaces it; set-up and doctor name the way to remove
# it instead. (The stand-in keeps it turned round: a tab in it.)
DEL_LINE="/bin/bash '$(cd "$SRC" && pwd -P)/os/darwin/secret' delete cloudflare-token"
cs_case; mkdir -p "$CFD"; cs_install; printf 'utsrqponmlkjihgf\tedcba\n' > "$S/keychain"; cs --yes < <(feed "$TOKEN")
t="offprint adapter setup --yes, a stored value os/darwin/secret get refuses"
contains "$t: says what is known (it couldn't be read, with the helper's reason), that set-up asks for one and stores it in its place, and how to remove it instead" "  The token stored in your login Keychain couldn't be read (os/darwin/secret get, status 4: The Keychain's answer for cloudflare-token isn't one line of printable characters, so it wasn't used.): set-up asks for one and stores it in its place. (To remove it instead, run this from the site folder: $DEL_LINE)" "$out"
lacks "$t: doesn't say what is stored isn't usable" "isn't usable" "$out"
check "$t: done, the new one stored in its place" "0|the token" "$code|$(cat "$S/security.stored" 2>&1)"
no_leak "$t"; cs_tmp_empty "$t"
dcase; printf 'utsrqponmlkjihgf\tedcba\n' > "$S/keychain"; cdoc; t="offprint adapter doctor, a stored value os/darwin/secret get refuses"
check "$t: a problem, naming set-up and the way to remove it" "1|problem  the Cloudflare token couldn't be read from your login Keychain (os/darwin/secret get, status 4: The Keychain's answer for cloudflare-token isn't one line of printable characters, so it wasn't used.): run offprint adapter setup, which asks for one and stores it in its place (or remove it, running this from the site folder: $DEL_LINE)" "$code|$(dline problem)"
# The same status 4 from a security that failed some other way (status 7 here): the reason is os/darwin/secret's own,
# not that the stored value is unusable; set-up asks for a token all the same, and if the store then fails, says so.
cs_case; mkdir -p "$CFD"; cs_install; printf 'utsrqponmlkjihgf\tedcba\n' > "$S/keychain"; touch "$S/get_fails"; cs --yes < <(feed "$TOKEN")
t="offprint adapter setup --yes, security failing when os/darwin/secret gets the token"
contains "$t: says what is known, with the helper's reason, and nothing about the value" "  The token stored in your login Keychain couldn't be read (os/darwin/secret get, status 4: security couldn't read cloudflare-token from the login Keychain (it failed with status 7).): set-up asks for one and stores it in its place. (To remove it instead, run this from the site folder: $DEL_LINE)" "$out"
lacks "$t: doesn't say the stored value isn't usable" "isn't usable" "$out"
no_leak "$t"; cs_tmp_empty "$t"
dcase; printf 'utsrqponmlkjihgf\tedcba\n' > "$S/keychain"; touch "$S/get_fails"; cdoc; t="offprint adapter doctor, security failing when os/darwin/secret gets the token"
check "$t: a problem, with the helper's reason" "1|problem  the Cloudflare token couldn't be read from your login Keychain (os/darwin/secret get, status 4: security couldn't read cloudflare-token from the login Keychain (it failed with status 7).): run offprint adapter setup, which asks for one and stores it in its place (or remove it, running this from the site folder: $DEL_LINE)" "$code|$(dline problem)"
# With the token piped in, nothing set-up starts before it reads the token is handed the pipe it is in: bin/offprint's
# commands, lib/site.sh's, the adapter's load and set-up's own steps run with stdin /dev/null. Each program here is a
# look-alike that reads all of a pipe on its stdin (and hands it on to the real one), noting when the token was in it
# (stdin.token: never the bytes); none finds it, and set-up then reads the token whole.
cat > "$tmp/stdin-reader.pl" <<'READER'
#!/usr/bin/perl
use strict;
use warnings;
my $s = '@STUBS@';
if (open(my $r, '>>', "$s/stdin.ran")) { print $r "@NAME@\n"; close $r; }
if (!-p STDIN) { exec { '@REAL@' } '@REAL@', @ARGV; die "@REAL@: $!"; }
my $in = do { local $/; my $x = <STDIN>; defined $x ? $x : '' };
my $tok = reverse('@BACK@'); my $hit = index($in, $tok) >= 0;
for (my $i = 0; !$hit && $i + 8 <= length($tok); $i++) { $hit = 1 if index($in, substr($tok, $i, 8)) >= 0; }
if ($hit && open(my $h, '>>', "$s/stdin.token")) { print $h "@NAME@\n"; close $h; }
pipe(my $rd, my $wr) or die "pipe: $!";
my $pid = fork(); die "fork: $!" unless defined $pid;
if ($pid == 0) { close $wr; open(STDIN, '<&', $rd) or die; close $rd; exec { '@REAL@' } '@REAL@', @ARGV; die "@REAL@: $!"; }
close $rd; $SIG{PIPE} = 'IGNORE'; print $wr $in; close $wr; waitpid($pid, 0);
exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
READER
stdin_readers() {
  local t w real
  for t in php mktemp dirname find chmod id readlink rm head cat mkdir mv cp sleep; do
    if [ "$t" = php ]; then real="$(command -v php)"; else real="$(PATH=/usr/bin:/bin command -v "$t")"; fi
    [ -n "$real" ] || continue
    stand_in "$tmp/stdin-reader.pl" "$S/bin/$t"; w="$(cat "$S/bin/$t")"; w="${w//@NAME@/$t}"; w="${w//@REAL@/$real}"; printf '%s\n' "$w" > "$S/bin/$t"
  done
}
for scen in "installed|node and wrangler set up already" "nothing|from nothing"; do
  kind="${scen%%|*}"; how="${scen#*|}"
  cs_case; if [ "$kind" = installed ]; then mkdir -p "$CFD"; cs_install; fi; stdin_readers
  cs --yes < <(feed "$TOKEN"); t="offprint adapter setup --yes ($how), the token piped in, each program it starts a look-alike reading its stdin"
  check "$t: done, the token stored whole" "0|the token" "$code|$(cat "$S/security.stored" 2>&1)"
  # (dirname no longer runs at all: bin/offprint and lib/site.sh find their folders, and the site's, with the shell's
  # own builtins, so nothing is looked up on the PATH before lib/site.sh has made it safe.)
  check "control: $t: find, mktemp, php and rm ran" "find mktemp php rm" \
    "$(sort -u "$S/stdin.ran" 2>/dev/null | grep -x -e php -e mktemp -e dirname -e find -e rm | paste -sd' ' -)"
  check "$t: dirname never ran" no "$(grep -qx dirname "$S/stdin.ran" 2>/dev/null && echo yes || echo no)"
  check "$t: none of them found any of the token on its stdin" "" "$(sort -u "$S/stdin.token" 2>/dev/null | paste -sd' ' -)"
  no_leak "$t"; cs_tmp_empty "$t"
done

# === cloudflare-workers: what WordPress exports for, what may be run, and Cloudflare's answers ===
# The address WordPress exports for is the public_url its container was made with (templates/compose.yaml puts it in the
# container's environment): the doctor reads Docker's record of the container (dc ps, docker inspect), never WordPress's
# own word, and says when it isn't site.json's public_url.
wpline() { printf '%s\n' "$out" | grep '^[a-z]* *\(WordPress\|Docker\|A Docker\)'; }
dcase; wp_origin https://old.example.com; cdoc; t="offprint adapter doctor, WordPress made for an older public_url"
check "$t: that line a problem, ending with what to do; exit 1" "1|problem  WordPress's container was made for https://old.example.com, not site.json's public_url ($U), so a publish would link to the old address: run offprint compose up -d, which makes it again with public_url" "$code|$(wpline)"
check "$t: asked of Docker's record of the container: ps, then inspect" "yes|yes" "$(grep -q ' ps -a -q wordpress' "$S/docker.ps" && echo yes || echo no)|$(grep -q '^inspect --format {{json .Config.Env}} c0ffee000001$' "$S/docker.inspect" && echo yes || echo no)"
dcase; printf '["PATH=/usr/bin"]\n' > "$S/wp_env"; cdoc
check "offprint adapter doctor, a container whose record names no public address" "1|problem  Docker's record of WordPress's container names no public address (OFFPRINT_PUBLIC_ORIGIN): run offprint compose up -d" "$code|$(wpline)"
dcase; touch "$S/docker_down"; cdoc
check "offprint adapter doctor, Docker not running" "1|problem  Docker isn't running, so the address WordPress exports for couldn't be checked: start Docker, then run offprint adapter doctor again" "$code|$(wpline)"
dcase; touch "$S/wp_none"; cdoc
check "offprint adapter doctor, no WordPress container" "1|problem  WordPress has no container (not made yet, or removed), so nothing can be exported: run offprint compose up -d" "$code|$(wpline)"

# Nothing WordPress can write is run (Review Focus: wp-content/ is the container's): set-up looks node up on the PATH's
# absolute entries only (an empty or relative one names wherever set-up runs from: wp-content/, say), and refuses a
# node, or an npm, that is the site folder's or leads there, before running it; doctor and the deploy refuse such a
# recorded node, and an install that is a link or leads into the site folder, before running anything.
plant() {  # plant DIR: a node and an npm WordPress could have put in DIR, each noting that it ran (planted.ran)
  mkdir -p "$1"
  printf '#!/bin/sh\necho "$0 ran" >> "%s/planted.ran"\necho v99.0.0\n' "$S" > "$1/node"
  printf '#!/bin/sh\necho "$0 ran" >> "%s/planted.ran"\nexit 0\n' "$S" > "$1/npm"
  chmod +x "$1/node" "$1/npm"
}
csat() {  # csat DIR PATH [ARGS]: offprint adapter setup run from DIR (the site found from there), with PATH; sets out, code
  local dir="$1" path="$2"; shift 2
  out="$(cd "$dir" && PATH="$path" STUB_DIR="$S" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
    /bin/bash "$SRC/bin/offprint" adapter setup "$@" 2>&1)"; code=$?
}
# The adapter's own second layer, past lib/site.sh's clean-up. Every Offprint command sources lib/site.sh first, which
# leaves out of the PATH every empty or relative entry and every entry in the site folder (saying so), so through
# offprint itself set-up, doctor and a publish never see such an entry (the cases after each of these say so). What the
# adapter does with one anyway (adapter_cf_clean_path; its refusal of a node, npm, curl or php in the site folder) is
# kept as a second layer, and tested here: past-clean.sh does what offprint adapter SUB does (lib/site.sh, the site, the
# adapter's load and its settings checked, stdin /dev/null until set-up), then puts the case's PATH (PAST_PATH) back
# just before the adapter is loaded, as if lib/site.sh had left it as it was.
cat > "$tmp/past-clean.sh" <<'DRIVER'
set -u
. "$1/lib/site.sh" || exit 2
. "$1/lib/adapter.sh"
sub="$2"; shift 2
{
  offprint_find_site
  offprint_load_site
  PATH="$PAST_PATH"
  trap '{ offprint_adapter_stop; offprint_adapter_cleanup; } < /dev/null' EXIT
  offprint_adapter_load || { echo "$OFFPRINT_ADAPTER_PROBLEM" >&2; exit 2; }
  vrc=0; offprint_adapter_call adapter_validate > /dev/null 2>&1 < /dev/null || vrc=$?
  if [ "$OFFPRINT_ADAPTER_ENDED" != returned ] || [ "$vrc" -ne 0 ]; then echo "past-clean.sh: adapter_validate failed" >&2; exit 2; fi
} < /dev/null
rc=0
if [ "$sub" = setup ]; then offprint_adapter_call adapter_setup "$@" || rc=$?
else offprint_adapter_call adapter_doctor < /dev/null || rc=$?; fi
exit "$rc"
DRIVER
csat_past() {  # csat_past DIR PATH [ARGS]: csat, through past-clean.sh, PATH put back past lib/site.sh's clean-up; sets out, code
  local dir="$1" path="$2"; shift 2
  out="$(cd "$dir" && PATH="$path" PAST_PATH="$path" STUB_DIR="$S" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$tmp/past-clean.sh" "$SRC" setup "$@" 2>&1)"; code=$?
}
# through_offprint T DIR PATH ENTRY SEEN: csat DIR PATH --yes, through offprint itself: lib/site.sh leaves ENTRY out, in
# one line, so set-up never sees it (no SEEN in what it says), and the planted node and npm never run
through_offprint() {
  csat "$2" "$3" --yes < /dev/null
  check "$1, through offprint itself: the planted node and npm never ran" no "$(exists "$S/planted.ran")"
  check "$1, through offprint itself: lib/site.sh left the entry out, in one line" "1|1" \
    "$(printf '%s\n' "$out" | grep -c 'PATH entries left out')|$(printf '%s\n' "$out" | grep 'PATH entries left out' | grep -cF -- "$4")"
  lacks "$1, through offprint itself: set-up never saw it" "$5" "$out"
}
BASE_PATH="" # set per case: the set-up PATH without the stand-in node
# (Through offprint itself, lib/site.sh leaves out "." and the empty entry before set-up runs: so these first cases now
# show that first layer. Each twin after it, through past-clean.sh, gives set-up the same PATH, and shows the adapter's
# own layer, adapter_cf_clean_path, keeping them out.)
for spec in ".:|. first" ":|an empty entry first" "|an empty entry last"; do
  pre="${spec%%|*}"; how="${spec#*|}"
  cs_case; plant "$c/wp-content"; p="$pre$CS_PATH"; [ "$how" != "an empty entry last" ] || p="$CS_PATH:"
  csat "$c/wp-content" "$p" < <(feed y y y "$TOKEN"); t="offprint adapter setup run from wp-content/, which holds a node and an npm, PATH with $how"
  check "$t: done with the node on the PATH's absolute entries; neither planted one ran" "0|$NODE_PHYS|no" "$code|$(cat "$CFD/node" 2>&1)|$(exists "$S/planted.ran")"
  no_leak "$t"
  cs_case; plant "$c/wp-content"; p="$pre$CS_PATH"; [ "$how" != "an empty entry last" ] || p="$CS_PATH:"
  csat_past "$c/wp-content" "$p" < <(feed y y y "$TOKEN"); t="$t, past lib/site.sh's clean-up (past-clean.sh)"
  check "$t: done with the node on the PATH's absolute entries; neither planted one ran" "0|$NODE_PHYS|no" "$code|$(cat "$CFD/node" 2>&1)|$(exists "$S/planted.ran")"
  no_leak "$t"
done
cs_case; plant "$c/wp-content"; BASE_PATH="$S/bin:$tmp/bin:$tmp/case$n/phpbin:/usr/bin:/bin"
csat_past "$c/wp-content" ".:$BASE_PATH" --yes < /dev/null; t="offprint adapter setup run from wp-content/, the only node there, through . on the PATH"
check "$t: refused, exit 1, saying why; nothing run, nothing made" "1|node is only on your PATH through the relative PATH entry \".\", which set-up ignores: that folder is wherever you run it from (the site's wp-content/, say, which WordPress can write). Put node's own folder on your PATH as an absolute path, then run offprint adapter setup again.|no|none" \
  "$code|$(last)|$(exists "$S/planted.ran")|$(oh_state)"
csat_past "$c/wp-content" ":$BASE_PATH" --yes < /dev/null
check "offprint adapter setup run from wp-content/, the only node there, through an empty PATH entry: refused, nothing run" "1|node is only on your PATH through an empty PATH entry (the folder you run it from), which set-up ignores: that folder is wherever you run it from (the site's wp-content/, say, which WordPress can write). Put node's own folder on your PATH as an absolute path, then run offprint adapter setup again.|no" \
  "$code|$(last)|$(exists "$S/planted.ran")"
csat_past "$c" "wp-content:$BASE_PATH" --yes < /dev/null
check "offprint adapter setup, the only node through the relative PATH entry wp-content: refused, nothing run" "1|node is only on your PATH through the relative PATH entry \"wp-content\", which set-up ignores: that folder is wherever you run it from (the site's wp-content/, say, which WordPress can write). Put node's own folder on your PATH as an absolute path, then run offprint adapter setup again.|no" \
  "$code|$(last)|$(exists "$S/planted.ran")"
csat_past "$c" "$c/wp-content:$CS_PATH" --yes < /dev/null; t="offprint adapter setup, the first node on the PATH the site folder's (wp-content/, an absolute entry)"
check "$t: refused before it ran, nothing made" "1|The node on your PATH, $c/wp-content/node, is inside the site folder, which WordPress can write (or leads there), so neither set-up nor a publish will run it; install node outside the site folder, then run offprint adapter setup again.|no|none" \
  "$code|$(last)|$(exists "$S/planted.ran")|$(oh_state)"
# (The node is named as the PATH finds it: lib/site.sh keeps each entry as the folder it is on disk.)
mkdir -p "$tmp/case$n/via"; ln -s "$c/wp-content/node" "$tmp/case$n/via/node"; csat "$c" "$tmp/case$n/via:$CS_PATH" --yes < /dev/null
check "offprint adapter setup, the first node on the PATH a link into wp-content/: refused before it ran" "1|The node on your PATH, $(cd -P "$tmp/case$n/via" && pwd -P)/node, is inside the site folder, which WordPress can write (or leads there), so neither set-up nor a publish will run it; install node outside the site folder, then run offprint adapter setup again.|no" \
  "$code|$(last)|$(exists "$S/planted.ran")"
mkdir -p "$c/wp-content/bin"; ln -s "$NODE_PHYS" "$c/wp-content/bin/node"; csat_past "$c" "$c/wp-content/bin:$CS_PATH" --yes < /dev/null
check "offprint adapter setup, the first node on the PATH a link in wp-content/ to a good node outside: refused all the same (WordPress could change the link), nothing made" \
  "1|The node on your PATH, $c/wp-content/bin/node, is inside the site folder, which WordPress can write (or leads there), so neither set-up nor a publish will run it; install node outside the site folder, then run offprint adapter setup again.|none" \
  "$code|$(last)|$(oh_state)"
mkdir -p "$tmp/case$n/nb"; cp "$NODE" "$tmp/case$n/nb/node"; ln -s "$c/wp-content/npm" "$tmp/case$n/nb/npm"; nb="$(cd "$tmp/case$n/nb" && pwd -P)"
csat "$c" "$tmp/case$n/nb:$BASE_PATH" --yes < /dev/null; t="offprint adapter setup, the npm beside the node a link into wp-content/"
check "$t: refused before npm ran; the node (outside) recorded" "1|The npm beside that node, $nb/npm, is inside the site folder, which WordPress can write (or leads there), so set-up won't run it; reinstall node (https://nodejs.org), then run offprint adapter setup again.|no|$nb/node|node" \
  "$code|$(last)|$(exists "$S/planted.ran")|$(cat "$CFD/node" 2>&1)|$(beside)"
# The five PATHs above that past-clean.sh put back, through offprint itself (a fresh case): lib/site.sh leaves out the
# entry that reaches wp-content/ before set-up runs, saying so; neither planted program runs.
cs_case; plant "$c/wp-content"; BASE_PATH="$S/bin:$tmp/bin:$tmp/case$n/phpbin:/usr/bin:/bin"
mkdir -p "$c/wp-content/bin"; ln -s "$NODE_PHYS" "$c/wp-content/bin/node"
through_offprint "offprint adapter setup run from wp-content/, the only node there, through . on the PATH" "$c/wp-content" ".:$BASE_PATH" "'.'" "only on your PATH through"
through_offprint "offprint adapter setup run from wp-content/, the only node there, through an empty PATH entry" "$c/wp-content" ":$BASE_PATH" "''" "only on your PATH through"
through_offprint "offprint adapter setup, the only node through the relative PATH entry wp-content" "$c" "wp-content:$BASE_PATH" "'wp-content'" "only on your PATH through"
through_offprint "offprint adapter setup, the first node on the PATH the site folder's (wp-content/, an absolute entry)" "$c" "$c/wp-content:$CS_PATH" "'$c/wp-content'" "is inside the site folder"
through_offprint "offprint adapter setup, the first node on the PATH a link in wp-content/ to a good node outside" "$c" "$c/wp-content/bin:$CS_PATH" "'$c/wp-content/bin'" "is inside the site folder"
# A recorded node in the site folder: set-up never runs it, and records the one on
# the PATH; doctor and a publish refuse it.
cs_case; mkdir -p "$CFD"; cs_install; seed; plant "$c/wp-content"; printf '%s\n' "$c/wp-content/node" > "$CFD/node"
cs --yes < /dev/null; t="offprint adapter setup, the node recorded the site folder's"
check "$t: done; never ran it; the one on the PATH recorded in its place" "0|no|$NODE_PHYS" "$code|$(exists "$S/planted.ran")|$(cat "$CFD/node")"
contains "$t: says which it replaces" "It replaces $c/wp-content/node, recorded before." "$out"
dcase; plant "$c/wp-content"; printf '%s\n' "$c/wp-content/node" > "$CFD/node"; cdoc; t="offprint adapter doctor, the node recorded the site folder's"
check "$t: that line a problem; it never ran" "1|problem  the node recorded, $c/wp-content/node, is inside the site folder, which WordPress can write (or leads there): run offprint adapter setup|no" "$code|$(dline problem)|$(exists "$S/planted.ran")"
ln -s "$c/wp-content/node" "$tmp/case$n/linknode"; printf '%s\n' "$tmp/case$n/linknode" > "$CFD/node"; cdoc
check "offprint adapter doctor, the node recorded a link into the site folder: a problem; it never ran" "1|problem  the node recorded, $tmp/case$n/linknode, is inside the site folder, which WordPress can write (or leads there): run offprint adapter setup|no" "$code|$(dline problem)|$(exists "$S/planted.ran")"
# A link in the site folder to a good node outside it: WordPress could change the link, so it is refused all the same.
ln -s "$NODE_PHYS" "$c/wp-content/goodnode"; printf '%s\n' "$c/wp-content/goodnode" > "$CFD/node"; rm -f "$S/node.version"; cdoc
check "offprint adapter doctor, the node recorded a link in the site folder to a node outside it: a problem; it never ran" \
  "1|problem  the node recorded, $c/wp-content/goodnode, is inside the site folder, which WordPress can write (or leads there): run offprint adapter setup|no" "$code|$(dline problem)|$(exists "$S/node.version")"
cfpub; check "a cloudflare-workers publish, the node recorded a link in the site folder to a node outside it: refused, node never ran" \
  "1|$(short) is pushed, but the deploy failed: the node recorded for wrangler is inside the site folder, which WordPress can write (or leads there), so it wasn't run; run offprint adapter setup|0" "$code|$(js message)|$(calls node.runs)"
printf '%s\n' "$tmp/case$n/linknode" > "$CFD/node"
cfpub; t="a cloudflare-workers publish, the node recorded a link into the site folder"
check "$t: the deploy refused before running it" "1|$(short) is pushed, but the deploy failed: the node recorded for wrangler is inside the site folder, which WordPress can write (or leads there), so it wasn't run; run offprint adapter setup|no|0" \
  "$code|$(js message)|$(exists "$S/planted.ran")|$(calls node.runs)"
# wrangler-4.166.0 a link to a whole copy in wp-content/, or one whose wrangler leads there: not whole. Set-up replaces
# it (the link moved aside and removed, never followed); doctor says so; a publish refuses it.
dcase; mkdir -p "$c/wp-content/w"; mv "$DEST/node_modules" "$c/wp-content/w/"; rmdir "$DEST"; ln -s "$c/wp-content/w" "$DEST"
cdoc; t="offprint adapter doctor, wrangler-4.166.0 a link to a whole copy in wp-content/"
check "$t: a problem" "1|problem  $DEST isn't a whole wrangler 4.166.0 (it is a symlink): run offprint adapter setup, which replaces it" "$code|$(dline problem)"
cfpub; t="a cloudflare-workers publish, wrangler-4.166.0 a link into wp-content/"
check "$t: the deploy refused, node never ran" "1|$(short) is pushed, but the deploy failed: run offprint adapter setup, which replaces it: wrangler's folder for Offprint can't be run (it is a symlink)|0" "$code|$(js message)|$(calls node.runs)"
cs --yes < /dev/null; t="offprint adapter setup, wrangler-4.166.0 a link to a whole copy in wp-content/"
contains "$t: says it will be replaced" "What is in $DEST now isn't a whole wrangler 4.166.0 (it is a symlink): it will be replaced." "$out"
check "$t: done: a whole copy of its own in place of the link; the copy in wp-content/ untouched" "0|no|yes|yes" \
  "$code|$([ -L "$DEST" ] && echo yes || echo no)|$(whole)|$(exists "$c/wp-content/w/node_modules/wrangler/bin/wrangler.js")"
dcase; mv "$DEST/node_modules/wrangler" "$c/wp-content/wr"; ln -s "$c/wp-content/wr" "$DEST/node_modules/wrangler"
cdoc; check "offprint adapter doctor, wrangler-4.166.0's wrangler a link into wp-content/: a problem" "1|problem  $DEST isn't a whole wrangler 4.166.0 (it leads into the site folder, which WordPress can write): run offprint adapter setup, which replaces it" "$code|$(dline problem)"
cfpub; check "a cloudflare-workers publish, wrangler-4.166.0's wrangler a link into wp-content/: refused, node never ran" "1|$(short) is pushed, but the deploy failed: run offprint adapter setup, which replaces it: wrangler's folder for Offprint can't be run (it leads into the site folder, which WordPress can write)|0" "$code|$(js message)|$(calls node.runs)"
# Offprint's folder, or its cloudflare-workers folder, in the site folder: set-up
# refuses, doctor says so, a publish refuses.
cs_case; mkdir -p "$OH" "$c/wp-content/cfw"; ln -s "$c/wp-content/cfw" "$CFD"; cs --yes < /dev/null; t="offprint adapter setup, cloudflare-workers a link into wp-content/"
check "$t: refused; nothing written there" "1|$CFD leads into the site folder, which WordPress can write (and a publish runs wrangler from it); remove that link (set-up makes the folder itself), then run offprint adapter setup again.|" "$code|$(last)|$(ls -A "$c/wp-content/cfw")"
cdoc; check "offprint adapter doctor, cloudflare-workers a link into wp-content/: wrangler's and node's lines say so" "problem  wrangler can't be found: $CFD leads into the site folder, which WordPress can write (and a publish runs wrangler from it); remove that link (set-up makes the folder itself), then run offprint adapter setup|problem  node can't be found: $CFD leads into the site folder, which WordPress can write (and a publish runs wrangler from it); remove that link (set-up makes the folder itself), then run offprint adapter setup" \
  "$(printf '%s\n' "$out" | head -n 2 | paste -sd'|' -)"
cf_case; mkdir -p "$c/var"; cf_install "$c/var/ohome"; t="a cloudflare-workers publish, OFFPRINT_HOME inside the site folder (an install there)"
OFFPRINT_HOME="$c/var/ohome" OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 pub
check "$t: the deploy refused, node never ran" "1|$(short) is pushed, but the deploy failed: point OFFPRINT_HOME at a folder outside the site folder (or unset it), then run offprint adapter setup: it is inside the site folder, which WordPress can write (and a publish runs wrangler from it): $c/var/ohome|0" \
  "$code|$(js message)|$(calls node.runs)"

# SHELLOPTS=allexport (and xtrace) inherited: every variable would be exported, the token too, to every process. Set-up,
# doctor and the deploy turn it off before the token is read: no process started has the token (whole, as hex, or any 8
# characters of it) in its environment's values. Every common command is wrapped to look (wrap_tools), as are the
# stand-ins (security, curl, npm, node --version).
cs_case; wrap_tools; t="offprint adapter setup, SHELLOPTS=allexport:xtrace inherited"
out="$(cd "$tmp/case$n" && env SHELLOPTS=allexport:xtrace PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
  TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter setup 2>&1 < <(feed y y y "$TOKEN"))"; code=$?
has "control: $t: xtrace was on (the command traced)" "+ offprint_adapter_call adapter_setup" "$out"
check "$t: done, the token stored" "0|the token" "$code|$(cat "$S/security.stored" 2>&1)"
check "control: $t: the wrapped commands and the stand-ins ran (php, mktemp, rm; security, curl, npm)" "yes|yes|yes|yes|yes|yes" \
  "$(grep -qx php "$S/env.ran" && echo yes)|$(grep -qx mktemp "$S/env.ran" && echo yes)|$(grep -qx rm "$S/env.ran" && echo yes)|$(grep -q '^-i$' "$S/security.argv" && echo yes)|$(exists "$S/curl.argv")|$(calls npm.runs | grep -qx 1 && echo yes)"
check "$t: no process it started had the token in its environment" "" "$(cat "$S/env.hits" 2>/dev/null)"
check "$t: no command was handed a variable of the tool's own (the inherited allexport is turned off)" "" "$(sort -u "$S/env.own" 2>/dev/null | head -n 3)"
no_leak "$t"
out="$(cd "$tmp/case$n" && env SHELLOPTS=allexport:xtrace PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
  TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter doctor 2>&1 < /dev/null)"; t="offprint adapter doctor, SHELLOPTS=allexport:xtrace inherited"
check "$t: the token checked (accepted)" "yes" "$(printf '%s\n' "$out" | grep -q '^ok       Cloudflare knows the token' && echo yes || echo no)"
check "$t: no process it started had the token in its environment" "" "$(cat "$S/env.hits" 2>/dev/null)"
check "$t: no command was handed a variable of the tool's own (the inherited allexport is turned off)" "" "$(sort -u "$S/env.own" 2>/dev/null | head -n 3)"
no_leak "$t"
# os/darwin/secret itself, run with allexport inherited: the line it hands security holds the value in hex, and is in
# no process's environment.
cs_case; wrap_tools; t="os/darwin/secret set, SHELLOPTS=allexport:xtrace inherited"
out="$(cd "$tmp/case$n" && env SHELLOPTS=allexport:xtrace PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
  /bin/bash "$SRC/os/darwin/secret" set cloudflare-token 2>&1 < <(feed "$TOKEN"))"; code=$?
check "$t: stored" "0|the token|-i" "$code|$(cat "$S/security.stored" 2>&1)|$(cat "$S/security.argv")"
check "$t: no process it started had the value (or its hex) in its environment" "" "$(cat "$S/env.hits" 2>/dev/null)"
no_leak "$t"
cf_case; wrap_tools; stand_in "$tmp/keychain.pl" "$S/security"; seed; t="a cloudflare-workers publish, SHELLOPTS=allexport:xtrace inherited"
out="$(cd "$tmp/case$n" && env SHELLOPTS=allexport:xtrace PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 OFFPRINT_HOME="$tmp/case$n/ohome" \
  OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 /bin/bash "$SRC/bin/publish" 2>&1)"; code=$?
check "$t: live, node given the token" "0|live|CLOUDFLARE_API_TOKEN=the stored token" "$code|$(js state)|$(grep '^CLOUDFLARE_API_TOKEN=' "$S/node.values")"
check "control: $t: the wrapped commands ran during the deploy (git, php, mkfifo)" "yes|yes|yes" "$(grep -qx git "$S/env.ran" && echo yes)|$(grep -qx php "$S/env.ran" && echo yes)|$(grep -qx mkfifo "$S/env.ran" && echo yes)"
check "$t: no process but node had the token in its environment" "" "$(cat "$S/env.hits" 2>/dev/null)"
check "$t: no command was handed a variable of the tool's own (the inherited allexport is turned off)" "" "$(sort -u "$S/env.own" 2>/dev/null | head -n 3)"
no_leak "$t"

# Cloudflare's 200 counts only when the top level of its JSON says "success": true; anything else is not understood, and
# nothing is stored.
cs_case; mkdir -p "$CFD"; cs_install; echo 200 > "$S/cf_status"
for body in '{"success":false,"errors":[],"result":{"success":true}}' '[{"success":true}]' '{"success":"true"}' '{"result":"\"success\":true"}' 'not JSON "success":true'; do
  printf '%s' "$body" > "$S/cf_body"; cs < <(feed y "$TOKEN"); t="offprint adapter setup, Cloudflare answering 200 with $body"
  check "$t: not taken for a yes; nothing stored" "1|The token couldn't be checked (Cloudflare's answer (HTTP 200) wasn't understood), so nothing was stored: try again later, then run offprint adapter setup again.|no" "$code|$(last)|$(exists "$S/keychain")"
done
# A large answer: cut short before any of it reaches the shell's own string work, so it takes seconds. limit SECS CMD:
# CMD, killed with all under it after SECS seconds (so a regression fails, and doesn't hang the suite).
limit() { /usr/bin/perl -e 'my $s = shift; my $p = fork(); if ($p == 0) { setpgrp(0, 0); exec @ARGV; exit 127; } $SIG{ALRM} = sub { kill "KILL", -$p; }; alarm $s; waitpid($p, 0); exit($? & 127 ? 137 : $? >> 8);' "$@"; }
cs_case; mkdir -p "$CFD"; cs_install; echo 403 > "$S/cf_status"
{ printf '{"success":false,"errors":[{"code":1,"message":"'; head -c 10000000 /dev/zero | tr '\0' m; printf '"}],"result":null}'; } > "$S/cf_body"
start=$SECONDS; out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
  limit 60 /bin/bash "$SRC/bin/offprint" adapter setup 2>&1 < <(feed y "$TOKEN"))"; code=$?; secs=$((SECONDS - start)); t="offprint adapter setup, a refusal of 10 MB"
check "$t: refused within 10 seconds, Cloudflare's message cut to 200 characters" "1|yes|Cloudflare refused the token for the account $ACCOUNT (HTTP 403: 1 $(printf '%0198d' 0 | tr 0 m)), so nothing was stored. Most often account_id in site.json is wrong: check it against the account's id on its page in Cloudflare's dashboard. If it is right, the token is for another account: make one for this account at https://dash.cloudflare.com/profile/api-tokens, then run offprint adapter setup again." \
  "$code|$([ "$secs" -lt 10 ] && echo yes || echo "no ($secs s)")|$(last)"
head -c 20000000 /dev/zero | tr '\0' m > "$S/cf_body"
start=$SECONDS; out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
  limit 60 /bin/bash "$SRC/bin/offprint" adapter setup 2>&1 < <(feed y "$TOKEN"))"; code=$?; secs=$((SECONDS - start)); t="offprint adapter setup, an answer of 20 MB"
check "$t: curl told to take no more than 16 MB; refused within 10 seconds, nothing stored" "1|yes|The token couldn't be checked (Cloudflare's answer was larger than 16 MB, which isn't expected), so nothing was stored: try again later, then run offprint adapter setup again.|no" \
  "$code|$([ "$secs" -lt 10 ] && echo yes || echo "no ($secs s)")|$(last)|$(exists "$S/keychain")"
rm -f "$S/cf_body"

# === cloudflare-workers: what is handed the token, the node file, the install's links, inherited names ===
# Each program handed the token (curl; php, given Cloudflare's answer; security, through os/darwin/secret) is found
# once, by an absolute path, and refused before it runs when it is the site folder's or leads there: an absolute PATH
# entry in wp-content/ holding look-alikes. (The planted php hands every other use to the real one: lib/site.sh runs php
# first, through the PATH as given, which is the owner's to keep clean; it notes only a run with Cloudflare's answer.)
plant_tools() {  # plant_tools DIR [curl] [php]: look-alikes in DIR, noting in STUBS/planted.ran when handed the token (curl) or Cloudflare's answer (php)
  local d="$1" t real_php; shift; mkdir -p "$d"; real_php="$(command -v php)"
  for t; do
    case "$t" in
      curl) printf '#!/bin/sh\nif grep -q Authorization; then echo "curl handed the token" >> "%s/planted.ran"; fi\nexit 7\n' "$S" > "$d/curl" ;;
      php) printf '#!/bin/sh\ncase "$*" in *property_exists*) echo "php ran with the answer" >> "%s/planted.ran" ;; esac\nexec "%s" "$@"\n' "$S" "$real_php" > "$d/php" ;;
    esac
    chmod +x "$d/$t"
  done
}
# (Each through past-clean.sh, the PATH put back past lib/site.sh's own clean-up: see csat_past. Through offprint
# itself, after these, lib/site.sh leaves that entry out first, and set-up and
# doctor work with the stand-ins on the PATH.)
cs_past() {  # cs_past [ARGS]: cs, through past-clean.sh; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$CS_PATH" PAST_PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$tmp/past-clean.sh" "$SRC" setup "$@" 2>&1)"; code=$?
}
cdoc_past() {  # cdoc, through past-clean.sh; sets out, code
  out="$(cd "$tmp/case$n" && PATH="$CS_PATH" PAST_PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$tmp/past-clean.sh" "$SRC" doctor 2>&1 < /dev/null)"; code=$?
}
cs_case; mkdir -p "$CFD"; cs_install; plant_tools "$c/wp-content/tools" curl php; keep="$CS_PATH"; CS_PATH="$c/wp-content/tools:$CS_PATH"
cs_past < <(feed y "$TOKEN"); t="offprint adapter setup, a curl and a php in wp-content/ first on the PATH (an absolute entry)"
check "$t: refused before either was handed anything; nothing stored" "1|The token couldn't be checked (the curl on your PATH, $c/wp-content/tools/curl, is inside the site folder, which WordPress can write (or leads there), so it wasn't handed the token), so nothing was stored: put a curl from outside the site folder first on your PATH (macOS has /usr/bin/curl), then run offprint adapter setup again.|no|no" \
  "$code|$(last)|$(exists "$S/planted.ran")|$(exists "$S/keychain")"
no_leak "$t"
seed; cdoc_past; t="offprint adapter doctor, the same PATH"
check "$t: the token's line a problem; neither run" "1|problem  the Cloudflare token in your login Keychain couldn't be checked (the curl on your PATH, $c/wp-content/tools/curl, is inside the site folder, which WordPress can write (or leads there), so it wasn't handed the token): put a curl from outside the site folder first on your PATH (macOS has /usr/bin/curl), then run offprint adapter doctor again|no" \
  "$code|$(dline 'problem  the Cloudflare')|$(exists "$S/planted.ran")"
rm -f "$S/keychain"; CS_PATH="$keep"
cs_case; mkdir -p "$CFD"; cs_install; plant_tools "$c/wp-content/tools" php; CS_PATH="$c/wp-content/tools:$CS_PATH"
cs_past < <(feed y "$TOKEN"); t="offprint adapter setup, a php in wp-content/ first on the PATH"
check "$t: refused before curl or that php ran; nothing stored" "1|The token couldn't be checked (the php on your PATH, $c/wp-content/tools/php, is inside the site folder, which WordPress can write (or leads there), so it wasn't handed Cloudflare's answer), so nothing was stored: put a php from outside the site folder first on your PATH, then run offprint adapter setup again.|no|no|no" \
  "$code|$(last)|$(exists "$S/planted.ran")|$(exists "$S/curl.argv")|$(exists "$S/keychain")"
CS_PATH="$keep"
# The same PATH (a curl and a php in wp-content/tools first), through offprint itself: lib/site.sh leaves the entry out,
# in one line; set-up then checks the token with the stand-in curl and stores it, and doctor checks it; neither planted
# one ever runs.
cs_case; mkdir -p "$CFD"; cs_install; plant_tools "$c/wp-content/tools" curl php; keep="$CS_PATH"; CS_PATH="$c/wp-content/tools:$CS_PATH"
cs < <(feed y "$TOKEN"); t="offprint adapter setup, a curl and a php in wp-content/ first on the PATH, through offprint itself"
check "$t: done, the token stored; neither planted one ran" "0|the token|no" "$code|$(cat "$S/security.stored" 2>&1)|$(exists "$S/planted.ran")"
check "$t: lib/site.sh left the entry out, in one line" "1|1" \
  "$(printf '%s\n' "$out" | grep -c 'PATH entries left out')|$(printf '%s\n' "$out" | grep 'PATH entries left out' | grep -cF -- "'$c/wp-content/tools'")"
no_leak "$t"
cdoc; t="offprint adapter doctor, the same PATH, through offprint itself"
check "$t: the token checked (accepted); neither planted one ran" "yes|no" \
  "$(printf '%s\n' "$out" | grep -q '^ok       Cloudflare knows the token' && echo yes || echo no)|$(exists "$S/planted.ran")"
CS_PATH="$keep"
cs_case; mkdir -p "$CFD" "$c/wp-content/sec"; cs_install; stand_in "$tmp/keychain.pl" "$c/wp-content/sec/security"; seed
out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$c/wp-content/sec/security" \
  TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter setup 2>&1 < <(feed y "$TOKEN"))"; code=$?; t="offprint adapter setup, OFFPRINT_SECURITY in the site folder"
check "$t: the Keychain left unasked (that security never ran); nothing stored" "1|no" "$code|$(exists "$S/security.argv")"
out="$(cd "$tmp/case$n" && PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_SECURITY="$c/wp-content/sec/security" TMPDIR="$tmp/case$n/tmpdir" \
  /bin/bash "$SRC/os/darwin/secret" set cloudflare-token 2>&1 < <(feed "$TOKEN"))"; code=$?; t="os/darwin/secret set, OFFPRINT_SECURITY in the site folder"
check "$t: refused (4), saying why; that security never ran" "4|OFFPRINT_SECURITY, $c/wp-content/sec/security, is inside the site folder, which WordPress can write (or leads there), so it wasn't run; nothing was stored.|no" \
  "$code|$out|$(exists "$S/security.argv")"
no_leak "$t"
# The file naming the node is read only when it is a real file: a link there (to a file WordPress wrote) would let it
# choose what a publish runs. Doctor says so, a publish refuses, set-up replaces the link (never following it).
dcase; printf '#!/bin/sh\necho ran >> "%s/outside.ran"\necho v22.12.0\n' "$S" > "$tmp/case$n/outside-node"; chmod +x "$tmp/case$n/outside-node"
printf '%s\n' "$tmp/case$n/outside-node" > "$c/wp-content/nodefile"; rm "$CFD/node"; ln -s "$c/wp-content/nodefile" "$CFD/node"
cdoc; t="offprint adapter doctor, cloudflare-workers/node a link to a file in wp-content/"
check "$t: a problem; what the file names never ran" "1|problem  $CFD/node is a symlink, so the node it names isn't used (whoever could change the link would choose what a publish runs): run offprint adapter setup, which replaces it|no" "$code|$(dline problem)|$(exists "$S/outside.ran")"
cfpub; t="a cloudflare-workers publish, the same"
check "$t: the deploy refused, without reading it" "1|$(short) is pushed, but the deploy failed: run offprint adapter setup, which replaces it: the file naming wrangler's node is a symlink, so it wasn't read|no|0" "$code|$(js message)|$(exists "$S/outside.ran")|$(calls node.runs)"
cs --yes < /dev/null; t="offprint adapter setup, the same"
check "$t: done; the link replaced by a file naming the node on the PATH; the file in wp-content/ untouched; nothing run" \
  "0|no|$NODE_PHYS|$tmp/case$n/outside-node|no" "$code|$([ -L "$CFD/node" ] && echo yes || echo no)|$(cat "$CFD/node")|$(cat "$c/wp-content/nodefile")|$(exists "$S/outside.ran")"
contains "$t: says it removes the link, not what it leads to" "  There is a symlink at $CFD/node: set-up removes the link itself (what it leads to is left as it is)," "$out"
contains "$t: (and writes the file in its place)" "  and writes the file in its place." "$out"
# A link in the install that can't be followed to a place on disk (into a folder WordPress hasn't made yet, say): not
# whole. npm's own relative links (node_modules/.bin, in every stand-in install here) are fine.
dcase; ln -s "$c/wp-content/later/esbuild" "$DEST/node_modules/esbuild"; cdoc; t="offprint adapter doctor, an install with a link into wp-content/later/ (not there yet)"
check "$t: a problem" "1|problem  $DEST isn't a whole wrangler 4.166.0 (it holds a link that can't be followed: node_modules/esbuild): run offprint adapter setup, which replaces it" "$code|$(dline problem)"
cfpub; check "a cloudflare-workers publish, the same: refused, node never ran" "1|$(short) is pushed, but the deploy failed: run offprint adapter setup, which replaces it: wrangler's folder for Offprint can't be run (it holds a link that can't be followed: node_modules/esbuild)|0" "$code|$(js message)|$(calls node.runs)"
cs --yes < /dev/null; check "offprint adapter setup, the same: replaced by a whole one, without the link" "0|yes|no" "$code|$(whole)|$(exists "$DEST/node_modules/esbuild")"
# A long OFFPRINT_HOME: the publish's reason leads with what to do, so the 300 characters the status keeps hold it.
cf_case; long="$c/var/$(printf '%0150d' 0 | tr 0 o)"; mkdir -p "$c/var"; cf_install "$long"; t="a cloudflare-workers publish, a 150-character OFFPRINT_HOME folder inside the site folder"
OFFPRINT_HOME="$long" OFFPRINT_SECURITY="$tmp/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 pub
case "$(js message)" in "$(short) is pushed, but the deploy failed: point OFFPRINT_HOME at a folder outside the site folder (or unset it), then run offprint adapter setup: "*) ok "$t: the status says what to do, first" ;;
  *) bad "$t: the status says what to do, first (got '$(js message)')" ;; esac
# (The control: the message as it was, path first, would have been cut before it said what to do.)
was="OFFPRINT_HOME, $long, is inside the site folder, which WordPress can write (and a publish runs wrangler from it); point it at a folder outside the site folder (or unset it), then run offprint adapter setup"
check "control: $t: put path first, the reason would have been cut before saying what to do" yes "$([ "${#was}" -gt 300 ] && echo yes || echo no)"
# An all-relative PATH, dropped whole, leaves /usr/bin:/bin, never an empty PATH (which bash would search the folder it
# is in for).
cf_case; load 'PATH=".:rel:"; . "$OFFPRINT_ADAPTER_DIR/setup.sh"; adapter_cf_clean_path; echo "path=[$PATH]"'
check "adapter_cf_clean_path, a PATH of relative and empty entries only: /usr/bin:/bin" "path=[/usr/bin:/bin]" "$(printf '%s\n' "$out" | grep '^path=')"

# A name the caller exported that a function then declares (local) stays exported, on bash 3.2 and 5: each variable that
# holds the token, its hex, or text holding either, is un-exported before it is given it. Run with each such name in the
# caller's environment (and every common command, and the stand-ins, looking at their environment's values).
PRE="cf_token=x out=x said=x ok=x line=x value=x hex=x h=x answer=x chunk=x prev=x joined=x pre=x"
cs_case; wrap_tools; t="offprint adapter setup and doctor, $PRE in the caller's environment"
# shellcheck disable=SC2086 # the names, one a word
out="$(cd "$tmp/case$n" && env $PRE PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
  TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter setup 2>&1 < <(feed y y y "$TOKEN"))"; code=$?
check "$t: set-up done, the token stored" "0|the token" "$code|$(cat "$S/security.stored" 2>&1)"
# shellcheck disable=SC2086
out="$out$(cd "$tmp/case$n" && env $PRE PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
  TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter doctor 2>&1 < /dev/null)"
check "$t: doctor checked the token (accepted)" yes "$(printf '%s\n' "$out" | grep -q '^ok       Cloudflare knows the token' && echo yes || echo no)"
check "$t: no process either started had the token in its environment" "" "$(cat "$S/env.hits" 2>/dev/null)"
no_leak "$t"
cs_case; wrap_tools; t="os/darwin/secret set, $PRE in the caller's environment"
# shellcheck disable=SC2086
out="$(cd "$tmp/case$n" && env $PRE PATH="$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" \
  /bin/bash "$SRC/os/darwin/secret" set cloudflare-token 2>&1 < <(feed "$TOKEN"))"; code=$?
check "$t: stored; no process had the value or its hex in its environment" "0|the token|" "$code|$(cat "$S/security.stored" 2>&1)|$(cat "$S/env.hits" 2>/dev/null)"
cf_case; wrap_tools; stand_in "$tmp/keychain.pl" "$S/security"; seed; touch "$S/node_echo"; t="a cloudflare-workers publish, $PRE in the caller's environment, wrangler printing the token"
# shellcheck disable=SC2086
out="$(cd "$tmp/case$n" && env $PRE PATH="$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 OFFPRINT_HOME="$tmp/case$n/ohome" \
  OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 /bin/bash "$SRC/bin/publish" 2>&1)"; code=$?
check "$t: live" "0|live" "$code|$(js state)"
check "$t: no process but node had the token in its environment" "" "$(cat "$S/env.hits" 2>/dev/null)"
no_leak "$t"

# === cloudflare-workers: the bash that runs os/darwin/secret; the node file never written through a link ===
# os/darwin/secret holds the token (set reads it on its stdin, get prints it on its stdout), so the bash that runs it is
# /bin/bash, never one the PATH finds (its #! line would have env look bash up there). Look-alikes of bash and env,
# planted in wp-content/, each note their arguments (planted.args) and keep a copy of what they were given on stdin and
# of what they printed (planted.stdin, planted.stdout), then run the real one. With them first on the PATH (an absolute
# entry; or "." or an empty entry, run from that folder), set-up, doctor and a publish never run os/darwin/secret
# through either, and none of the token goes through them. (Other scripts may still run through the planted bash, the
# test's own stand-ins and bin/check-site among them: every other command comes from the PATH as given. See docs/security.md.)
# Planted in wp-content/, lib/site.sh leaves each of those entries out before anything runs (the first layer): so those
# three kinds now show that. Planted in a folder outside the site, an absolute entry is kept by every layer, and set-up,
# doctor and a publish meet the planted bash and env: so that kind shows /bin/bash itself (the second layer). For "."
# and an empty entry, which offprint never lets reach set-up, the twins after the loop go through past-clean.sh.
cat > "$tmp/planted-shell" <<'PLANT'
#!/bin/sh
echo "@NAME@ $*" >> "@STUBS@/planted.args"
/bin/cat > "@STUBS@/planted.$$.in"
@REAL@ "$@" < "@STUBS@/planted.$$.in" > "@STUBS@/planted.$$.out"; rc=$?
/bin/cat "@STUBS@/planted.$$.out"
/bin/cat "@STUBS@/planted.$$.in" >> "@STUBS@/planted.stdin"; /bin/cat "@STUBS@/planted.$$.out" >> "@STUBS@/planted.stdout"
/bin/rm -f "@STUBS@/planted.$$.in" "@STUBS@/planted.$$.out"
exit $rc
PLANT
plant_shells() {  # plant_shells DIR: the look-alike bash and env in DIR
  local t w real
  mkdir -p "$1"
  for t in bash env; do
    case "$t" in bash) real=/bin/bash ;; *) real=/usr/bin/env ;; esac
    stand_in "$tmp/planted-shell" "$1/$t"; w="$(cat "$1/$t")"; w="${w//@NAME@/$t}"; w="${w//@REAL@/$real}"; printf '%s\n' "$w" > "$1/$t"
  done
}
shells_clean() {  # shells_clean T: the planted bash and env never ran os/darwin/secret, and none of the token went through them
  check "$1: os/darwin/secret never run by the planted bash or env" "" "$(grep 'os/darwin/secret' "$S/planted.args" 2>/dev/null)"
  if cat "$S/planted.stdin" "$S/planted.stdout" 2>/dev/null | grep -qF "${LEAK[@]}"; then bad "$1: some of the token went through the planted bash or env (not shown)"
  else ok "$1: none of the token went through the planted bash or env"; fi
}
for spec in "abs|an absolute entry" ".|. (run from there)" "empty|an empty entry (run from there)" \
  "out|an absolute entry outside the site folder, which every layer keeps"; do
  how="${spec#*|}"; kind="${spec%%|*}"; pw="in wp-content/"; [ "$kind" != out ] || pw="outside the site folder"
  cs_case; mkdir -p "$CFD"; cs_install; P="$c/wp-content/tools"; [ "$kind" != out ] || P="$tmp/case$n/planted-tools"; plant_shells "$P"
  case "$kind" in abs|out) pre="$P:"; here="$tmp/case$n" ;; .) pre=".:"; here="$P" ;; *) pre=":"; here="$P" ;; esac
  check "control: the first bash on that PATH ($how), from there, is the planted one" yes "$(cd "$here" && b="$(PATH="$pre$CS_PATH" command -v bash)" && [ "$b" -ef "$P/bash" ] && echo yes)"
  out="$(cd "$here" && PATH="$pre$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter setup 2>&1 < <(feed y "$TOKEN"))"; code=$?
  t="offprint adapter setup (node and wrangler there, no token stored), a bash and an env $pw first on the PATH through $how"
  check "$t: done, the token stored" "0|the token" "$code|$(cat "$S/security.stored" 2>&1)"
  shells_clean "$t"; no_leak "$t"
  if [ "$kind" = out ]; then check "$t: (lib/site.sh kept that entry: nothing said)" 0 "$(printf '%s\n' "$out" | grep -c 'PATH entries left out')"; fi
  out="$(cd "$here" && PATH="$pre$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$SRC/bin/offprint" adapter doctor 2>&1 < /dev/null)"; t="offprint adapter doctor, the same PATH"
  [ "$kind" != out ] || t="$t (outside the site folder)"
  check "$t: the token checked (accepted)" yes "$(printf '%s\n' "$out" | grep -q '^ok       Cloudflare knows the token' && echo yes || echo no)"
  shells_clean "$t"; no_leak "$t"
  cf_case; stand_in "$tmp/keychain.pl" "$S/security"; seed; P="$c/wp-content/tools"; [ "$kind" != out ] || P="$tmp/case$n/planted-tools"; plant_shells "$P"
  case "$kind" in abs|out) pre="$P:"; here="$tmp/case$n" ;; .) pre=".:"; here="$P" ;; *) pre=":"; here="$P" ;; esac
  out="$(cd "$here" && PATH="$pre$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" PUBLISH_POLL_SECONDS=1 OFFPRINT_HOME="$tmp/case$n/ohome" \
    OFFPRINT_SECURITY="$S/security" TMPDIR="$tmp/case$n/tmpdir" PUBLISH_TIMEOUT_SECONDS=1 /bin/bash "$SRC/bin/publish" 2>&1 < /dev/null)"; code=$?
  t="a cloudflare-workers publish, a bash and an env $pw first on the PATH through $how"
  check "$t: live, node given the token" "0|live|CLOUDFLARE_API_TOKEN=the stored token" "$code|$(js state)|$(grep '^CLOUDFLARE_API_TOKEN=' "$S/node.values")"
  shells_clean "$t"; no_leak "$t"
done
# The twins of the "." and empty kinds, past lib/site.sh's clean-up (past-clean.sh puts the PATH back before the
# adapter is loaded): set-up and doctor meet "." or the empty entry, run from wp-content/tools, and the adapter's own
# layer (adapter_cf_clean_path, and /bin/bash for os/darwin/secret) keeps the planted bash and env out.
for spec in ".|. (run from there)" "empty|an empty entry (run from there)"; do
  how="${spec#*|}"; kind="${spec%%|*}"
  cs_case; mkdir -p "$CFD"; cs_install; P="$c/wp-content/tools"; plant_shells "$P"
  case "$kind" in .) pre=".:" ;; *) pre=":" ;; esac
  check "control: the first bash on that PATH ($how), from there, is the planted one (past-clean.sh)" yes "$(cd "$P" && b="$(PATH="$pre$CS_PATH" command -v bash)" && [ "$b" -ef "$P/bash" ] && echo yes)"
  out="$(cd "$P" && PATH="$pre$CS_PATH" PAST_PATH="$pre$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$tmp/past-clean.sh" "$SRC" setup 2>&1 < <(feed y "$TOKEN"))"; code=$?
  t="offprint adapter setup past lib/site.sh's clean-up (past-clean.sh), a bash and an env in wp-content/ first on the PATH through $how"
  check "$t: done, the token stored" "0|the token" "$code|$(cat "$S/security.stored" 2>&1)"
  shells_clean "$t"; no_leak "$t"
  out="$(cd "$P" && PATH="$pre$CS_PATH" PAST_PATH="$pre$CS_PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$OH" OFFPRINT_SECURITY="$S/security" \
    TMPDIR="$tmp/case$n/tmpdir" /bin/bash "$tmp/past-clean.sh" "$SRC" doctor 2>&1 < /dev/null)"; t="offprint adapter doctor past lib/site.sh's clean-up, the same PATH ($how)"
  check "$t: the token checked (accepted)" yes "$(printf '%s\n' "$out" | grep -q '^ok       Cloudflare knows the token' && echo yes || echo no)"
  shells_clean "$t"; no_leak "$t"
done

# The file naming node (cloudflare-workers/node) is never written through a link, whatever it leads to: set-up removes
# the link itself and writes a regular file there; a real folder there is refused, nothing written. A second run then
# changes nothing.
kind_of() { if [ -L "$1" ]; then echo link; elif [ -f "$1" ]; then echo file; elif [ -d "$1" ]; then echo folder; elif [ -p "$1" ]; then echo fifo; elif [ -e "$1" ]; then echo other; else echo none; fi; }
for spec in "wpdir|a link to a folder in wp-content/" "outdir|a link to a folder outside the site" "file|a link to a file in wp-content/" \
  "dangling|a dangling link" "fifo|a link to a FIFO outside the site"; do
  how="${spec#*|}"; kind="${spec%%|*}"
  cs_case; mkdir -p "$CFD"; cs_install; seed; rm -f "$CFD/node"
  case "$kind" in
    wpdir) to="$c/wp-content/nd"; mkdir -p "$to" ;;
    outdir) to="$tmp/case$n/elsewhere"; mkdir -p "$to" ;;
    file) to="$c/wp-content/nodefile"; printf '%s\n' "$tmp/case$n/nowhere" > "$to" ;;
    dangling) to="$tmp/case$n/not-there" ;;
    fifo) to="$tmp/case$n/fifo"; mkfifo "$to" ;;
  esac
  ln -s "$to" "$CFD/node"; was="$(kind_of "$to")|$(ls -A "$to" 2>/dev/null | paste -sd' ' -)"
  cs --yes < /dev/null; t="offprint adapter setup --yes, cloudflare-workers/node $how"
  check "$t: done; node a regular file naming the node on the PATH, and that line only" "0|file|$NODE_PHYS|1" "$code|$(kind_of "$CFD/node")|$(cat "$CFD/node" 2>&1)|$(wc -l < "$CFD/node" | tr -d ' ')"
  check "$t: what the link led to is as it was (nothing new in it)" "$was" "$(kind_of "$to")|$(ls -A "$to" 2>/dev/null | paste -sd' ' -)"
  [ "$kind" != file ] || check "$t: the file it led to unchanged" "$tmp/case$n/nowhere" "$(cat "$to")"
  check "$t: says ok only once it is there" "yes" "$(printf '%s\n' "$out" | grep -q '^  ok: node recorded\.$' && echo yes || echo no)"
  before="$(oh_state)"; cs --yes < /dev/null
  check "$t: a second run changes nothing" "0|$before" "$code|$(oh_state)"
  contains "$t: (it says the node is recorded already)" "ok: node v22.12.0 at $NODE_PHYS, recorded already." "$out"
done
cs_case; mkdir -p "$CFD"; cs_install; seed; rm -f "$CFD/node"; mkdir "$CFD/node"; touch "$CFD/node/keep"; before="$(oh_state)"
cs --yes < /dev/null; t="offprint adapter setup --yes, cloudflare-workers/node a real folder"
check "$t: refused, exit 1, saying what to remove; nothing written, nothing run" "1|$CFD/node is a folder, where set-up keeps the path of wrangler's node in a file; remove that folder (set-up never makes one), then run offprint adapter setup again.|$before|no" \
  "$code|$(last)|$(oh_state)|$(exists "$S/node.version")"
cs --yes < /dev/null; check "$t: a second run the same, nothing written" "1|$before" "$code|$(oh_state)"
# What set-up wrote is checked once it is in place, and "ok" said only then: a stand-in mv that makes a folder at the
# name just before the move (as a race could) leaves the new file inside it, and set-up says so.
cs_case; mkdir -p "$CFD"; cs_install; seed; rm -f "$CFD/node"
printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in */cloudflare-workers/node) /bin/mkdir -p "$last" ;; esac\nexec /bin/mv "$@"\n' > "$S/bin/mv"; chmod +x "$S/bin/mv"
cs --yes < /dev/null; t="offprint adapter setup --yes, a folder made at cloudflare-workers/node just before the move"
check "$t: not ok; says what to do" "1|no|$CFD/node isn't the file set-up wrote (something else is at that name now); remove what is there, then run offprint adapter setup again." \
  "$code|$(printf '%s\n' "$out" | grep -q 'ok: node recorded' && echo yes || echo no)|$(last)"
rm -f "$S/bin/mv"
# The same for wrangler-4.166.0: the new copy's final move is checked, and "ok" said only once a whole copy is there.
# The next set-up replaces what was left at the name.
cs_case; mkdir -p "$CFD"; seed
printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in */cloudflare-workers/wrangler-4.166.0) /bin/mkdir -p "$last" ;; esac\nexec /bin/mv "$@"\n' > "$S/bin/mv"; chmod +x "$S/bin/mv"
cs --yes < /dev/null; t="offprint adapter setup --yes, a folder made at wrangler-4.166.0 just before the new copy's move"
check "$t: not ok; says what to do" "1|no|wrangler 4.166.0 was made, but what is at $DEST now isn't it (something else took that name meanwhile); run offprint adapter setup again, which replaces it." \
  "$code|$(printf '%s\n' "$out" | grep -q 'ok: wrangler 4.166.0 installed' && echo yes || echo no)|$(last)"
rm -f "$S/bin/mv"; cs --yes < /dev/null
check "$t: the next set-up replaces it with a whole copy" "yes|" "$(whole)|$(ls -A "$CFD" | grep '^\.' | paste -sd' ' -)"

# === the PATH clean-up (lib/site.sh): offprint adapter setup and doctor, look-alikes in wp-content/ ===
# Run from inside the site folder's wp-content/, which holds look-alikes of bash, dirname, php, mktemp, git, docker,
# curl, readlink and env (each noting that it ran), with the PATH reaching there through . first, an empty entry first,
# relative entries, its absolute path, and a link outside the site folder; both as /bin/bash bin/offprint and by its own
# #! line. None runs, the entries left out are named in one line, and each does what it does (the adapter none's set-up
# and doctor: nothing to do, and they say so).
newcase; mkdir -p "$c/wp-content"
for p in bash dirname php mktemp git docker curl readlink env; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$c/wp-content/$p"; chmod +x "$c/wp-content/$p"
done
ln -s "$c/wp-content" "$tmp/case$n/wplink"
for spec in ".:|'.'|. first" ":|''|an empty entry first" "wp-content:../wp-content:|'wp-content' '../wp-content'|relative entries" \
  "$c/wp-content:|'$c/wp-content'|its absolute path" "$tmp/case$n/wplink:|'$tmp/case$n/wplink'|a link to it"; do
  pre="${spec%%|*}"; rest="${spec#*|}"; named="${rest%%|*}"; how="${rest#*|}"
  for by in bash direct; do
    run=/bin/bash; [ "$by" = bash ] || run=""
    for sub in setup doctor; do
      rm -f "$tmp/planted.ran"
      out="$(cd "$c/wp-content" && env -u OFFPRINT_SITE PATH="$pre$S/bin:$tmp/bin:$PATH" STUB_DIR="$S" ${run:+"$run"} "$SRC/bin/offprint" adapter "$sub" 2>&1 < /dev/null)"; code=$?
      t="the PATH clean-up: offprint adapter $sub ($by), the adapter none, run from wp-content/ holding look-alikes, the PATH through $how"
      check "$t: none of them ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
      check "$t: one line names what was left out of the PATH" "1|1" "$(printf '%s\n' "$out" | grep -c 'PATH entries left out')|$(printf '%s\n' "$out" | grep 'PATH entries left out' | grep -cF -- "$named")"
      case "$sub" in setup) want="nothing to set up: this site has no host set up (its adapter is none)" ;; *) want="nothing to check: this site has no host set up (its adapter is none)." ;; esac
      said="no: $(last)"; case "$(last)" in "$want"*) said=yes ;; esac
      check "$t: done, saying so" "0|yes" "$code|$said"
    done
  done
done
rm -f "$tmp/planted.ran"

check "nothing left in the suite's TMPDIR by any load, call or publish" "" "$(ls -A "$TMPDIR")"
exit "$fail"
