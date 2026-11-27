# The cloudflare-workers adapter: a publish uploads site/, exactly as committed, to a Cloudflare Worker's static assets,
# straight from this Mac, with wrangler (pinned at 4.166.0); the default confirm then asks the live site for its
# offprint.json until it names the publish. See lib/adapter.sh for the contract this fills in.
#
# site.json's adapter block, for example:
#   "adapter": {"name": "cloudflare-workers", "worker": "my-site", "account_id": "0123456789abcdef0123456789abcdef"}
#   worker      the Worker's name on Cloudflare: 1 to 63 lowercase letters, digits and dashes, starting and ending with
#               a letter or digit
#   account_id  the Cloudflare account's id: 32 lowercase hex digits
# Both are required, and nothing else is a setting.
#
# What a publish needs on this Mac, all put there by offprint adapter setup (a publish downloads and installs nothing):
#   OFFPRINT_HOME/cloudflare-workers/wrangler-4.166.0/  wrangler, installed with npm ci --ignore-scripts from this
#                         folder's package-lock.json; its entry script node_modules/wrangler/bin/wrangler.js (wrangler's
#                         "bin"). OFFPRINT_HOME is ~/Library/Application Support/Offprint unless set.
#   OFFPRINT_HOME/cloudflare-workers/node  the absolute path of the node set-up used, on its first line. node is run by
#                         that path, never looked up on the PATH (the launchd agent's PATH has no nvm, say).
#   the secret cloudflare-token  a Cloudflare API token allowed Account, Workers Scripts, Edit, in the login Keychain
#                         (lib/adapter.sh: offprint_secret_get).
# One missing is the deploy's failure, naming offprint adapter setup; a locked Keychain says so. So is any of them that
# WordPress could have put there (OFFPRINT_HOME or its cloudflare-workers folder in the site folder, wrangler-4.166.0 a
# link or leading there, the node recorded there or leading there): nothing is run then (see adapter_cf_home and the
# rules beside it, which set-up and doctor use too). Set-up and doctor
# (offprint adapter setup, offprint adapter doctor) are in setup.sh, beside this file: adapter_setup and adapter_doctor
# source it when they run, so a publish never reads it.
#
# Names wrangler gives a meaning of its own in the assets folder (ADAPTER_HOST_SPECIAL_FILES, refused at the root of the
# export before anything is committed, in any letter case, a file or a folder):
#   .assetsignore  gitignore-style patterns: the files they match are left out of the upload, silently. In the export it
#                  would let the container drop any checked file from the live site while the publish says "live".
#   _worker.js     a Pages worker, file or folder: wrangler refuses to upload one (it would be public code).
# _headers and _redirects, its other two, are this adapter's own (ADAPTER_PREPARE_FILES). No other name is known to mean
# anything to wrangler 4 there (_routes.json, functions/ and node_modules/ are Pages's, not a Worker's); a real run is
# to confirm it. wrangler reads .assetsignore only at the root of the assets folder: in a real run of 4.166.0
# (2026-11-23) one in a sub-folder was uploaded, and served, as a plain file. adapter_prepare and the copy below refuse
# one at any depth all the same, deliberately, as a caution (another version could read one there; a site has no reason
# to ship one), and say so: that wrangler gives the name a meaning of its own at the
# root, and Offprint refuses it at any depth.
#
# adapter_deploy COMMIT:
#   - copies site/ out of COMMIT into a private folder of its own (offprint_private_dir, in TMPDIR, refused when that
#     is inside the site folder): each file the commit's blob, byte for byte (git cat-file, which applies no attribute,
#     filter or line-end setting), a plain file of mode 644 or 755. Never site/ on disk, which can differ from what was
#     checked and committed (a .DS_Store Finder made after the publish, line ends core.autocrlf left there). Anything in
#     the commit but plain files (a link, another repository), two names this disk takes for one, .assetsignore anywhere
#     or _worker.js at the root (in any case, or a name this disk takes for either: a commit made before they were
#     refused, or some other way), and the copy stops: nothing is uploaded. So wrangler is handed exactly the commit's
#     files, and leaves none of them out but _headers and _redirects, which it reads as rules and doesn't serve.
#     offprint.json, _headers and _redirects are committed, so they are in the copy.
#   - writes wrangler.jsonc beside the copy: name the worker, compatibility_date 2026-11-21, assets.directory the copy,
#     assets.not_found_handling 404-page.
#   - only then reads the token from the Keychain, so that while it is held nothing runs but node (and the filters of
#     what it prints). One missing, locked, or not plainly a token (adapter_cf_token_ok) fails the deploy here, with
#     nothing uploaded. A person is told what is wrong in this order: wrangler not installed, node not recorded, the
#     private folder or the copy, the token.
#   - runs node on wrangler's entry script, deploy --config that file, from that folder (wrangler writes its .wrangler/
#     there), stdin /dev/null, for 120 seconds at most: then node and every process under it are stopped (frozen, then
#     killed, as os/darwin/secret stops security). Its environment is exactly these six names: CLOUDFLARE_API_TOKEN,
#     CLOUDFLARE_ACCOUNT_ID, WRANGLER_SEND_METRICS=false, CI=true (nothing waits for an answer), HOME (a folder inside
#     the private one: wrangler writes its logs and settings under HOME, and they start empty and go with it, so no
#     state of an earlier run, or of the owner's own wrangler, is read, and none is left), and PATH (node's own folder,
#     then /usr/bin:/bin, for whatever wrangler starts).
#   - what wrangler prints (stdout and stderr, each through a pipe of its own) goes to var/publish.log, which WordPress
#     can read, through a filter that replaces the token's value with [token hidden], and leaves out the list of the
#     token's accounts (names and ids) that wrangler prints when Cloudflare refuses the token, one line saying so in its
#     place (see adapter_cf_filter). When it fails, ADAPTER_PROBLEM is "Cloudflare refused the upload: ", the line after
#     wrangler's [ERROR] marker and Cloudflare's own reason below it (adapter_cf_error_line), as the filter left them,
#     colour and other escape sequences taken out, each other character outside printable ASCII a ?; then, for the two
#     reasons a real run gave, what to do (adapter_cf_refused): all of it within the 300 characters the status keeps.
#   - the private folder is removed whatever happens, a TERM or an INT included.
# The token travels only in node's environment: it is never traced (set -x is turned off before it is read), never
# exported in this shell (so git, php, rm and the rest never have it; allexport, which an inherited SHELLOPTS could turn
# on, is turned off with xtrace), never in a process's arguments, never in a file
# (nor a here-document or here-string, which bash 3.2 writes to one).
#
# Test seam, for tests/adapter.test.sh: OFFPRINT_WRANGLER_TIMEOUT, wrangler's limit in whole seconds, 1 to 120; any
# other value is ignored, so it can only shorten the limit, never lengthen or remove it.
ADAPTER_PREPARE_FILES="offprint.json _headers _redirects"
ADAPTER_HOST_SPECIAL_FILES=".assetsignore _worker.js"   # see above
ADAPTER_MAX_FILES=20000              # the free plan's limit on a Worker's static assets
ADAPTER_MAX_FILE_BYTES=26214400      # and on one file: 25 MiB
ADAPTER_MAX_TOTAL_BYTES=0
ADAPTER_CONFIRM_SECONDS=60
ADAPTER_DEPLOY_AGAIN=1               # an upload that failed is mended only by another

# adapter_validate: worker and account_id, each strictly; any other setting is refused, by name.
adapter_validate() {
  local rc=0 v k worker_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' account_re='^[0-9a-f]{32}$' IFS=$' \t\n'
  if [ -z "${ADAPTER_SET_WORKER+x}" ]; then
    echo 'site.json: "adapter.worker" is required: the name of the Worker on Cloudflare.'; rc=1
  elif ! ( LC_ALL=C; [[ $ADAPTER_SET_WORKER =~ $worker_re ]] ); then
    echo "site.json: \"adapter.worker\" must be a Worker's name: 1 to 63 lowercase letters, digits and dashes, starting and ending with a letter or digit."; rc=1
  fi
  if [ -z "${ADAPTER_SET_ACCOUNT_ID+x}" ]; then
    echo "site.json: \"adapter.account_id\" is required: the Cloudflare account's id."; rc=1
  elif ! ( LC_ALL=C; [[ $ADAPTER_SET_ACCOUNT_ID =~ $account_re ]] ); then
    echo 'site.json: "adapter.account_id" must be a Cloudflare account id: 32 lowercase hex digits.'; rc=1
  fi
  for v in $(compgen -v ADAPTER_SET_); do
    case "$v" in
      ADAPTER_SET_WORKER|ADAPTER_SET_ACCOUNT_ID) ;;
      *) k="$(printf '%s' "${v#ADAPTER_SET_}" | LC_ALL=C tr 'A-Z' 'a-z')"
         echo "site.json: \"adapter.$k\" isn't a setting of the cloudflare-workers adapter (its two are worker and account_id)."; rc=1 ;;
    esac
  done
  return "$rc"
}

# adapter_prepare DIR: first refuses an .assetsignore anywhere in DIR, in any letter case, a file or a folder, or a name
# the disk takes for one (bin/publish has refused one at the root already): wrangler reads one at the root, and leaves
# the files it names out of the upload; deeper down it is refused as a caution (see the top). Refused here, it is never
# committed (an upload of the commit would refuse it, and a publish with nothing new would retry and fail the same way
# every time). Then _redirects serves the feed at /feed/ (its file is feed/index.xml), and _headers gives it its type
# and keeps offprint.json out of every cache. Cloudflare reads both from the assets folder and serves neither.
adapter_prepare() {
  local hit d
  while IFS= read -r -d '' hit; do break; done < <(cd "$1" && find . -mindepth 1 -iname .assetsignore -print0 2> /dev/null)
  if [ -n "${hit:-}" ]; then
    hit="$(printf '%s' "${hit#./}" | LC_ALL=C tr -c ' -~' '?' | cut -c1-160)"
    ADAPTER_PROBLEM="$(adapter_cf_ai_why): the export has $hit"
    return 1
  fi
  while IFS= read -r -d '' d; do
    if [ -e "$d/.assetsignore" ] || [ -L "$d/.assetsignore" ]; then
      d="$(printf '%s' "${d#"$1"}" | LC_ALL=C tr -c ' -~' '?' | cut -c1-160)"; d="${d#/}"
      if [ -n "$d" ]; then d="in $d/"; else d="at the root"; fi
      ADAPTER_PROBLEM="$(adapter_cf_ai_why): the export has a name this disk takes for .assetsignore $d"
      return 1
    fi
  done < <(find "$1" -type d -print0 2> /dev/null)
  printf '/feed /feed/ 301\n/feed/ /feed/index.xml 200\n' > "$1/_redirects" || return 1
  printf '/feed/\n  Content-Type: application/rss+xml; charset=utf-8\n/feed/index.xml\n  Content-Type: application/rss+xml; charset=utf-8\n/offprint.json\n  Cache-Control: no-store\n' \
    > "$1/_headers" || return 1
}

# adapter_cf_ai_why: why an .assetsignore is refused, at any depth (see the top). It leads each refusal, the path last:
# the publish's status keeps 300 characters.
adapter_cf_ai_why() {
  printf '%s' "wrangler gives .assetsignore a meaning of its own at the root of what it uploads (it leaves out the files it names), and Offprint refuses the name at any depth"
}

adapter_failure_hint() { printf '; run offprint adapter doctor'; }

# adapter_setup [--yes], adapter_doctor: offprint adapter setup and doctor, from setup.sh (see the top of this file).
adapter_setup() {
  . "$OFFPRINT_ADAPTER_DIR/setup.sh" || { echo "offprint: the adapter's setup.sh couldn't be read" >&2; return 1; }
  adapter_cf_setup "$@"
}
adapter_doctor() {
  . "$OFFPRINT_ADAPTER_DIR/setup.sh" || { echo "offprint: the adapter's setup.sh couldn't be read" >&2; return 1; }
  adapter_cf_doctor
}

# What set-up writes and a publish runs, and the rules for each, in one place: set-up, doctor and adapter_deploy all use
# these. The programs that run wrangler or are handed the token (node, wrangler's install, npm; and in set-up and doctor
# curl and the php given Cloudflare's answer) must be the owner's, never anything WordPress could have put there or
# could change later: the site folder is the container's to write in (wp-content/, var/), so none of them is run from
# it, nor by a link leading there, nor read through a link (the file naming node). Each rule asks the disk, with every
# link followed (lib/site.sh: offprint_inside_site), and runs nothing. (os/darwin/secret, which holds the token, is run
# with /bin/bash, by lib/adapter.sh, and itself runs /usr/bin/security. Other commands, git, php, rm and the rest, come
# from the PATH the publish is given: see docs/security.md on keeping folders WordPress can write off it.)
#
# adapter_cf_home: sets cf_home, the Offprint folder (OFFPRINT_HOME, else HOME/Library/Application Support/Offprint),
# cf_dir (its cloudflare-workers folder), cf_dest (wrangler-4.166.0 there), cf_entry (wrangler's entry script in it,
# node_modules/wrangler/bin/wrangler.js: its "bin") and cf_nodefile (the file naming node), and returns 0; or returns 1,
# with cf_home_problem and cf_home_fix saying why and what to do: HOME unset, the folder not an absolute path, or it or
# its cloudflare-workers folder the site folder or inside it. The same, for a message that must lead with what to do
# (the publish's status keeps 300 characters): cf_home_todo, cf_home_why and cf_home_shown (the path, to go last).
adapter_cf_home() {
  local what=OFFPRINT_HOME
  cf_home=""; cf_dir=""; cf_dest=""; cf_entry=""; cf_nodefile=""; cf_home_problem=""; cf_home_fix=""
  cf_home_todo=""; cf_home_why=""; cf_home_shown=""
  if [ -n "${OFFPRINT_HOME:-}" ]; then cf_home="$OFFPRINT_HOME"
  elif [ -n "${HOME:-}" ]; then cf_home="$HOME/Library/Application Support/Offprint"; what="Offprint's folder"
  else
    cf_home_problem="HOME isn't set, so Offprint's folder can't be found"; cf_home_fix="set HOME (or OFFPRINT_HOME)"
    cf_home_todo="$cf_home_fix"; cf_home_why="$cf_home_problem"; return 1
  fi
  cf_home_shown="$(_offprint_shown "$cf_home")"
  case "$cf_home" in
    /*) ;;
    *) cf_home_problem="$what is $cf_home_shown, not an absolute path"; cf_home_fix="set it to one (or unset it)"
       cf_home_why="it isn't an absolute path"; cf_home=""
       if [ "$what" = OFFPRINT_HOME ]; then cf_home_todo="set OFFPRINT_HOME to an absolute path (or unset it)"
       else cf_home_todo="set HOME to an absolute path (or set OFFPRINT_HOME)"; fi
       return 1 ;;
  esac
  if offprint_inside_site "$cf_home"; then
    cf_home_problem="$what, $cf_home_shown, is inside the site folder, which WordPress can write (and a publish runs wrangler from it)"
    cf_home_fix="point it at a folder outside the site folder (or unset it)"
    cf_home_why="it is inside the site folder, which WordPress can write (and a publish runs wrangler from it)"; cf_home=""
    if [ "$what" = OFFPRINT_HOME ]; then cf_home_todo="point OFFPRINT_HOME at a folder outside the site folder (or unset it)"
    else cf_home_todo="set OFFPRINT_HOME to a folder outside the site folder"; fi
    return 1
  fi
  if offprint_inside_site "$cf_home/cloudflare-workers"; then
    cf_home_shown="$(_offprint_shown "$cf_home/cloudflare-workers")"
    cf_home_problem="$cf_home_shown leads into the site folder, which WordPress can write (and a publish runs wrangler from it)"
    cf_home_fix="remove that link (set-up makes the folder itself)"
    cf_home_why="Offprint's cloudflare-workers folder leads into the site folder, which WordPress can write (and a publish runs wrangler from it)"
    cf_home_todo="remove the link at Offprint's cloudflare-workers folder (set-up makes the folder itself)"; cf_home=""; return 1
  fi
  cf_dir="$cf_home/cloudflare-workers"; cf_dest="$cf_dir/wrangler-4.166.0"
  cf_entry="$cf_dest/node_modules/wrangler/bin/wrangler.js"; cf_nodefile="$cf_dir/node"
}
# adapter_cf_recorded FILE: the node FILE names (its first line, of its first 4 KB); nothing when there is no FILE, or
# it isn't a real file: a link there (to a file in the site folder, say) is never followed, since whoever could make the
# link would choose what a publish runs.
adapter_cf_recorded() { [ -L "$1" ] || [ ! -f "$1" ] || head -c 4096 "$1" 2> /dev/null | head -n 1; }
# adapter_cf_plain_path PATH: whether PATH is absolute, with no : (node's folder starts wrangler's PATH) and no control
# character
adapter_cf_plain_path() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *:*) return 1 ;; esac
  [ "$1" = "$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177')" ]
}
# adapter_cf_physical PATH: PATH with every link on it followed, by hand (older macOS has no readlink -f), and its
# folder as it is on disk (cd -P); nothing, and 1, when that can't be done.
adapter_cf_physical() {
  local p="$1" l n=0 d
  case "$p" in */*) ;; *) p="./$p" ;; esac
  while [ -L "$p" ]; do
    [ "$n" -lt 40 ] || return 1
    l="$(readlink -- "$p")" || return 1
    case "$l" in /*) p="$l" ;; *) p="${p%/*}/$l" ;; esac
    n=$((n + 1))
  done
  d="${p%/*}"; [ -n "$d" ] || d=/
  d="$(cd -P -- "$d" 2> /dev/null && pwd -P)" && [ -n "$d" ] || return 1
  printf '%s/%s\n' "${d%/}" "${p##*/}"
}
# adapter_cf_runnable PATH: whether the program PATH (node, or the npm beside it) may be run: 0 when PATH is plain
# (adapter_cf_plain_path), neither it nor the file it leads to is the site folder's or inside it, and that is a file
# that can be run; 1 when it isn't a program that can be run; 2 when WordPress could have put it there, or could change
# it.
adapter_cf_runnable() {
  local phys
  adapter_cf_plain_path "$1" || return 1
  ! offprint_inside_site "$1" || return 2
  [ -f "$1" ] && [ -x "$1" ] || return 1
  phys="$(adapter_cf_physical "$1")" || return 1
  ! offprint_inside_site "$phys" || return 2
  return 0
}
# adapter_cf_install_ok DIR: whether wrangler may be run from DIR (in the folder adapter_cf_home allows): 0 when DIR is
# a real folder (not a link), nothing in it leads into the site folder (the entry script, and each link in it, followed:
# npm makes some, in node_modules/.bin; a real folder in DIR is in DIR), no link in it leads nowhere that can be checked
# (into a folder not made yet, say, which WordPress could make later), and the entry script is a file; else 1 (there is
# no entry script) or 2 (a link, leading into the site folder, or one that can't be followed), with cf_why saying which.
adapter_cf_install_ok() {
  local e="$1/node_modules/wrangler/bin/wrangler.js" p l
  cf_why=""
  if [ -L "$1" ]; then cf_why="it is a symlink"; return 2; fi
  if p="$(adapter_cf_physical "$e")" && offprint_inside_site "$p"; then
    cf_why="it leads into the site folder, which WordPress can write"; return 2
  fi
  while IFS= read -r -d '' l; do
    if ! p="$(adapter_cf_physical "$l")"; then
      cf_why="it holds a link that can't be followed: $(printf '%s' "${l#"$1"/}" | LC_ALL=C tr -c ' -~' '?' | cut -c1-100)"; return 2
    fi
    if offprint_inside_site "$p"; then cf_why="it leads into the site folder, which WordPress can write"; return 2; fi
  done < <(find "$1" -type l -print0 2> /dev/null)
  if [ ! -f "$e" ]; then cf_why="there is no node_modules/wrangler/bin/wrangler.js"; return 1; fi
  return 0
}

# adapter_cf_token_ok: whether cf_token (the caller's) is plainly an API token: 16 to 1024 letters, digits and
# - _ . ~ + / =, so no space, quote, backslash or control character in it can be taken as curl's syntax or end a header.
# Set-up holds a pasted token to it, and set-up, doctor and a publish hold one read from the Keychain to it (which may
# have been stored some other way, in Keychain Access, say) before it is handed to anything. (The token is read from
# the caller's variable, never passed as an argument; the test runs in a subshell of this one, no program.)
adapter_cf_token_ok() {
  local re='^[A-Za-z0-9._~+/=-]+$'
  [ "${#cf_token}" -ge 16 ] && [ "${#cf_token}" -le 1024 ] && ( LC_ALL=C; [[ $cf_token =~ $re ]] )
}

# adapter_cf_limit: prints wrangler's limit, in seconds (see the test seam above).
adapter_cf_limit() {
  local s=120
  case "${OFFPRINT_WRANGLER_TIMEOUT:-}" in [1-9]|[1-9][0-9]|1[01][0-9]|120) s="$OFFPRINT_WRANGLER_TIMEOUT" ;; esac
  printf '%s\n' "$s"
}

# adapter_cf_git ARGS...: git for the site folder, as lib/adapter.sh and bin/publish run it: without git's variables
# that say where a repository, its objects, index or work tree are, or that change how a path is matched (git exports
# GIT_DIR inside a hook), without settings from the environment, without a core.fsmonitor command or the optional locks;
# and without replacement objects, so each object is the one its id names. stdin is the caller's to give.
adapter_cf_git() {
  ( unset GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_REPLACE_REF_BASE \
      GIT_NO_REPLACE_OBJECTS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
      GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
    exec git -C "$SITE" --no-replace-objects -c core.fsmonitor=false --no-optional-locks "$@" )
}

# adapter_cf_copy COMMIT WORK: copies site/ out of COMMIT into WORK/site (WORK: an empty private folder), byte for byte.
# git lists the tree (ls-tree -z: every name exactly), php checks the list and names the blobs, git hands them over in
# one stream (cat-file --batch: the stored bytes, no attribute or filter applied), and php writes each file from it,
# checking that the stream is exactly what was asked for. Returns 1, with ADAPTER_PROBLEM saying why (php's own reason,
# one line), at the first thing wrong; what went wrong in detail is in var/publish.log.
adapter_cf_copy() {
  local commit="$1" work="$2" rc why code
  code='
$mode = $argv[1] ?? ""; $list = $argv[2] ?? ""; $dest = $argv[3] ?? "";
function stop($why, $code) { fwrite(STDERR, $why . "\n"); exit($code); }
function shown($p) {
  $s = ""; $n = min(strlen($p), 160);
  for ($i = 0; $i < $n; $i++) { $o = ord($p[$i]); $s .= ($o > 31 && $o < 127) ? $p[$i] : "?"; }
  return strlen($p) > 160 ? $s . "..." : $s;
}
function why() { $e = error_get_last(); return null === $e ? "" : ": " . $e["message"]; }
$raw = @file_get_contents($list);
if (false === $raw) stop("git'"'"'s list of site/ couldn'"'"'t be read" . why(), 2);
$entries = array();
if ("" !== $raw) {
  if ("\0" !== substr($raw, -1)) stop("git'"'"'s list of site/ wasn'"'"'t whole", 2);
  foreach (explode("\0", substr($raw, 0, -1)) as $rec) {
    $tab = strpos($rec, "\t");
    $meta = false === $tab ? array() : explode(" ", substr($rec, 0, $tab));
    if (3 !== count($meta)) stop("git'"'"'s list of site/ wasn'"'"'t understood", 2);
    $path = substr($rec, $tab + 1);
    list($m, $t, $id) = $meta;
    if ("blob" !== $t || ("100644" !== $m && "100755" !== $m)) stop("site/" . shown($path) . " in the commit isn'"'"'t a plain file (a link, or another repository)", 2);
    $l = strlen($id);
    if ((40 !== $l && 64 !== $l) || strspn($id, "0123456789abcdef") !== $l) stop("git named site/" . shown($path) . " by something that isn'"'"'t an object id", 2);
    $parts = explode("/", $path);
    foreach ($parts as $part) {
      if ("" === $part || "." === $part || ".." === $part) stop("site/ in the commit has a name no file can have: site/" . shown($path), 2);
    }
    foreach ($parts as $part) { if (".assetsignore" === strtolower($part)) stop(($argv[4] ?? "") . ": site/" . shown($path), 2); }
    if ("_worker.js" === strtolower($parts[0])) stop("site/" . shown($path) . ": _worker.js is a name wrangler gives a meaning of its own at the root", 2);
    $entries[] = array($m, $id, $path);
  }
}
if (array() === $entries) stop("site/ in the commit has no files", 2);
if ("list" === $mode) { foreach ($entries as $e) { echo $e[1], "\n"; } exit(0); }
if ("write" !== $mode) stop("no such step", 2);
$made = array();
foreach ($entries as $e) {
  list($m, $id, $path) = $e;
  $h = fgets(STDIN, 256);
  $p = (false === $h || "\n" !== substr($h, -1)) ? array() : explode(" ", substr($h, 0, -1));
  if (3 !== count($p) || $p[0] !== $id || "blob" !== $p[1] || "" === $p[2] || strlen($p[2]) > 15 || strspn($p[2], "0123456789") !== strlen($p[2])) {
    stop("git'"'"'s answer for site/" . shown($path) . " wasn'"'"'t whole", 4);
  }
  $left = (int) $p[2];
  $slash = strrpos($path, "/");
  if (false !== $slash) {
    $dir = "";
    foreach (explode("/", substr($path, 0, $slash)) as $part) {
      $dir = "" === $dir ? $part : $dir . "/" . $part;
      if (isset($made[$dir])) continue;
      if (!@mkdir($dest . "/" . $dir, 0755)) stop("site/" . shown($dir) . " couldn'"'"'t be made in the copy (two names that are one on this disk, or the disk is full)", 3);
      $made[$dir] = true;
    }
  }
  $f = @fopen($dest . "/" . $path, "xb");
  if (false === $f) stop("site/" . shown($path) . " couldn'"'"'t be made in the copy (two names that are one on this disk, or the disk is full)", 3);
  while ($left > 0) {
    $chunk = fread(STDIN, min($left, 1048576));
    if (false === $chunk || "" === $chunk) stop("git'"'"'s answer for site/" . shown($path) . " wasn'"'"'t whole", 4);
    if (@fwrite($f, $chunk) !== strlen($chunk)) stop("site/" . shown($path) . " couldn'"'"'t be written in the copy (is the disk full?)" . why(), 3);
    $left -= strlen($chunk);
  }
  if (!@fclose($f)) stop("site/" . shown($path) . " couldn'"'"'t be written in the copy (is the disk full?)" . why(), 3);
  if ("\n" !== fread(STDIN, 1)) stop("git'"'"'s answer for site/" . shown($path) . " wasn'"'"'t whole", 4);
  if (!@chmod($dest . "/" . $path, "100755" === $m ? 0755 : 0644)) stop("site/" . shown($path) . " couldn'"'"'t be made in the copy" . why(), 3);
}
if ("" !== fread(STDIN, 1)) stop("git'"'"'s answer had more in it than site/ has", 4);
exit(0);
'
  if ! adapter_cf_git ls-tree -r -z "$commit:site" > "$work/tree.z" 2> "$work/git.err" < /dev/null; then
    head -c 4096 "$work/git.err" >&2
    ADAPTER_PROBLEM="couldn't copy site/ out of the commit for the upload: git couldn't list it (see var/publish.log)"; return 1
  fi
  rc=0
  php -n -d display_errors=stderr -d log_errors=0 -r "$code" -- list "$work/tree.z" "" "$(adapter_cf_ai_why)" > "$work/blobs" 2> "$work/copy.err" < /dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    if mkdir "$work/site"; then
      adapter_cf_git cat-file --batch < "$work/blobs" 2> "$work/git.err" \
        | php -n -d display_errors=stderr -d log_errors=0 -r "$code" -- write "$work/tree.z" "$work/site" "$(adapter_cf_ai_why)" 2> "$work/copy.err"
      rc="${PIPESTATUS[1]} ${PIPESTATUS[0]}"   # php's status, then git's (both read before either is reset)
      case "$rc" in "0 0") rc=0 ;; "0 "*) rc="${rc#0 }"; cp "$work/git.err" "$work/copy.err" ;; *) rc="${rc%% *}" ;; esac
    else
      rc=1; echo "the folder for it couldn't be made" > "$work/copy.err"
    fi
  fi
  if [ "$rc" = 0 ]; then
    # And by the disk's own lookup, which on the Mac's disk folds letter case in Unicode as php's strtolower doesn't (a
    # long s for an s): wrangler opens .assetsignore and walks the names it finds by that same lookup.
    why="$(adapter_cf_own_names "$work/site")"
    [ -n "$why" ] || return 0
    ADAPTER_PROBLEM="couldn't copy site/ out of the commit for the upload: $why"; return 1
  fi
  head -c 4096 "$work/copy.err" >&2
  why="$(head -c 4096 "$work/copy.err" | head -n 1 | LC_ALL=C tr -c ' -~\n' '?' | cut -c1-200)"
  ADAPTER_PROBLEM="couldn't copy site/ out of the commit for the upload: ${why:-php failed (status $rc)}"
  return 1
}

# adapter_cf_own_names DIR: says which folder of DIR (the copy) holds a name the disk takes for one wrangler gives a
# meaning of its own (.assetsignore in any folder, _worker.js at the root), as found by the disk's own lookup; nothing
# when none does.
adapter_cf_own_names() {
  local d n
  for n in .assetsignore _worker.js; do
    if [ -e "$1/$n" ] || [ -L "$1/$n" ]; then
      printf 'site/ has a name this disk takes for %s: wrangler gives that name a meaning of its own at the root' "$n"; return 0
    fi
  done
  while IFS= read -r -d '' d; do
    if [ -e "$d/.assetsignore" ] || [ -L "$d/.assetsignore" ]; then
      d="$(printf '%s' "${d#"$1"/}" | LC_ALL=C tr -c ' -~' '?' | cut -c1-160)"
      printf '%s: site/%s/ has a name this disk takes for .assetsignore' "$(adapter_cf_ai_why)" "$d"; return 0
    fi
  done < <(find "$1" -mindepth 1 -type d -print0 2> /dev/null)
}

# adapter_cf_filter: copies its stdin to its stdout (var/publish.log) and to fd 3 (the private copy adapter_deploy reads
# the error from), with each appearance of the token's value (cf_token, adapter_deploy's) replaced by [token hidden].
# The token never leaves this shell: the replacement is bash's own, so no other program (sed, awk) is handed it, as an
# argument or otherwise. It reads lines of up to 4096 bytes at a time (a longer line in pieces), and keeps the last one
# back until the next comes, so a token split once between two pieces (by a line end, or by a 4096-byte cut) is found
# too. (The token is the Keychain's, printable ASCII of 1 to 1024 characters, so no 4096-byte cut splits it twice; a
# token wrapped over three lines or more is not found, and wrangler is not known to wrap what it prints to a pipe.) Each
# stream has a filter of its own, so nothing node writes on the other can fall in the middle of one. wrangler sends the
# token only as a header, and is not known to print it, as written or encoded (in URL or base64 form): only the value as
# written is looked for.
# After 8 MB it keeps nothing more, and says so once, but reads on, so node never waits on a full pipe.
# What is personal is left out of the log (stdout; fd 3 keeps it, for adapter_cf_error_line, in the private folder,
# which goes, as wrangler's own log there does): when Cloudflare refuses the token for the account, wrangler lists every
# account the token can see, by name and id (an account's name can hold its owner's email address), and, with the
# permission User Details Read missing, says who is logged in (the owner's email address when it can). What goes, with
# the token already hidden and each line judged on its own first characters (so the same in any locale):
#  - from a line that IS "Getting User settings..." (the whole line, a carriage return or spaces after it allowed; not a
#    line that merely holds those words: wrangler prints each uploaded file's path, WordPress names the files) to the
#    closing line of the table of accounts, └ then ─ and ┴ only, then ┘ (a row can't be taken for it: each starts
#    │). If the table never closes, everything from that line to the end of this stream goes (fail closed);
#  - whatever the state, and on every stream (nothing says wrangler prints that block on one): each line whose first
#    character that isn't a space is ┌ │ ├ or └ (a row or rule of a box-drawn table), and each that starts 👋.
# One line says so in the place of what a stream had left out (once per stream, however much). Nothing else goes: not an
# [ERROR] block, not a file's line, not the line that says where wrangler's own log is.
adapter_cf_filter() {
  local LC_ALL=C chunk prev="" pend=0 end="" pend_end="" joined pre more=1 n=0 full=0 cap=8388608 bol=1 drop=0 cont=0 told=0
  local hide='[token hidden]' len="${#cf_token}"
  export -n chunk prev joined pre   # (they hold what wrangler printed, the token in it: never exported, see adapter_deploy)
  while [ "$more" = 1 ]; do
    chunk=""
    if IFS= read -r -n 4096 chunk; then
      if [ "${#chunk}" -ge 4096 ]; then end=""; else end=$'\n'; fi
    else
      more=0; end=""
      [ -n "$chunk" ] || break
    fi
    chunk="${chunk//"$cf_token"/$hide}"
    if [ "$pend" = 1 ]; then
      # Neither piece holds the token now: so any in the two together starts in the one kept back and ends in this one.
      joined="$prev$chunk"
      case "$joined" in
        *"$cf_token"*)
          pre="${joined%%"$cf_token"*}"
          chunk="${chunk:$(( ${#pre} + len - ${#prev} ))}"; prev="${prev:0:${#pre}}$hide" ;;
      esac
      adapter_cf_emit "$prev$pend_end"
    fi
    prev="$chunk"; pend_end="$end"; pend=1
  done
  [ "$pend" = 0 ] || adapter_cf_emit "$prev$pend_end"
}
# adapter_cf_emit TEXT: adapter_cf_filter's output, up to its cap (its n, full and cap), TEXT a line with its line end,
# or a piece of one (a 4096-byte cut, or the end with no line end): to fd 3, and to the log unless it is left out (see
# above; its bol, whether TEXT starts a line, drop, whether the list of accounts is being left out, cont, whether the
# line TEXT is part of is left out on its own account: 0 no, 1 yes, 2 not known yet, its pieces so far only spaces; and
# told, whether the line saying so has been written).
adapter_cf_emit() {
  local at="$bol" t s nl=$'\n' cr=$'\r' sp=$' '
  case "$1" in *"$nl") bol=1 ;; *) bol=0 ;; esac
  [ "$full" = 0 ] || return 0
  n=$((n + ${#1}))
  if [ "$n" -gt "$cap" ]; then
    full=1; printf '%s\n' "(wrangler printed more than 8 MB here; the rest isn't kept)"; printf '\n' >&3; return 0
  fi
  printf '%s' "$1" >&3
  if [ "$at" = 1 ] || [ "$cont" = 2 ]; then
    # (C locale: ┌ and the others are byte strings here, matched as such, in any locale the publish runs in)
    cont=0; s="${1#"${1%%[! ]*}"}"
    case "$s" in
      "") [ "$bol" = 1 ] || cont=2 ;;
      "┌"*|"│"*|"├"*|"└"*|"👋"*) cont=1 ;;
    esac
  fi
  if [ "$drop" = 1 ]; then
    # Its end: a whole line, └, then ─ and ┴ only, then ┘ (a carriage return before the line end allowed).
    if [ "$at" = 1 ] && [ "$bol" = 1 ]; then
      t="${1%"$nl"}"; t="${t%"$cr"}"
      case "$t" in └*┘) t="${t#└}"; t="${t%┘}"; t="${t//─/}"; t="${t//┴/}"; [ -n "$t" ] || drop=0 ;; esac
    fi
    adapter_cf_told; return 0
  fi
  if [ "$at" = 1 ]; then
    t="${1%"$nl"}"; t="${t%"${t##*[! $cr]}"}"
    if [ "$t" = "Getting User settings..." ]; then drop=1; adapter_cf_told; return 0; fi
  fi
  if [ "$cont" = 1 ]; then adapter_cf_told; return 0; fi
  printf '%s' "$1"
}
# adapter_cf_told: the one line, in the log, that says something was left out (adapter_cf_emit's told)
adapter_cf_told() {
  [ "$told" = 1 ] || printf '%s\n' "offprint: wrangler's list of the token's accounts was left out of this log"
  told=1
}

# adapter_cf_error_line FILE: what wrangler's first [ERROR] marker in FILE (its output, the token already hidden) says,
# in two lines. The first: the rest of the marker's line, or when that is blank the next line that isn't. The second
# (empty when there is none): Cloudflare's own reason, the first line after that which starts with two spaces (wrangler
# indents the notes under its marker so) and isn't blank, other than its "If you think this is a bug" line; not merely
# the next line, which can be another of wrangler's (it prints on two streams, which reach FILE interleaved). Only the
# marker's own block is searched: up to the next marker line ([ERROR] or [WARNING]), the line "Getting User
# settings...", or the line that names wrangler's log (🪵), whichever comes first; when there is none, the second line
# is empty (an indented line further on, or under another marker, is not this one's), and no line the log leaves out
# (adapter_cf_filter) is taken. Escape sequences (colour, links) are taken out first, so a marker coloured in pieces is
# found; each other character outside printable ASCII becomes ?, and each line is cut to 200 characters. Prints nothing
# when there is no marker.
adapter_cf_error_line() {
  LC_ALL=C awk '
    BEGIN { e = sprintf("%c", 27); b = sprintf("%c", 7); state = 0; m = ""; r = "" }
    function plain(s,    out, i, n, c) {
      out = ""; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c != e) { out = out c; i++; continue }
        c = substr(s, i + 1, 1)
        if (c == "[") { i += 2; while (i <= n && substr(s, i, 1) !~ /[@-~]/) i++; i++ }
        else if (c == "]") {
          i += 2
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == b) { i++; break }
            if (c == e && substr(s, i + 1, 1) == "\\") { i += 2; break }
            i++
          }
        } else i += 2
      }
      return out
    }
    # a line the log leaves out (see adapter_cf_filter): a row of a box-drawn table, or a line led by a waving hand;
    # never taken for a reason or for the text of a marker, though it is indented
    function left_out(s) {
      return index(s, "\342\224\214") == 1 || index(s, "\342\224\202") == 1 || index(s, "\342\224\234") == 1 || \
        index(s, "\342\224\224") == 1 || index(s, "\360\237\221\213") == 1
    }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function shown(s) { gsub(/[^ -~]/, "?", s); return substr(s, 1, 200) }
    state == 2 {
      p = plain($0); s = trim(p)
      # the block of the marker ends at the next marker, the accounts line, or the line that names the wrangler log
      if (index(s, "[ERROR]") == 1 || index(s, "[WARNING]") == 1 || index(s, "\342\234\230 [ERROR]") == 1 || index(s, "\342\226\262 [WARNING]") == 1 || \
          s == "Getting User settings..." || index(s, "\360\237\252\265") == 1) exit
      if (substr(p, 1, 2) == "  " && s != "" && index(s, "If you think this is a bug") != 1 && !left_out(s)) { r = s; exit }
      next
    }
    state == 1 { s = trim(plain($0)); if (s != "" && !left_out(s)) { m = s; state = 2 }; next }
    index($0, "ERROR") {
      s = plain($0); i = index(s, "[ERROR]"); if (i == 0) next
      m = trim(substr(s, i + 7)); state = (m != "") ? 2 : 1
    }
    END { if (m != "") { print shown(m); print shown(r) } }' "$1" 2> /dev/null
}
# adapter_cf_refused FILE: ADAPTER_PROBLEM for an upload wrangler failed, from FILE (its output, the token hidden):
# "Cloudflare refused the upload: ", what adapter_cf_error_line finds (the marker's line, then Cloudflare's reason),
# and, chosen by that reason, what to do. All of it within the 300 bytes the publish's status keeps, by these steps,
# each taken only when the one before leaves it too long: the marker's line loses its first part in parentheses (the
# API path wrangler names, account id and Worker in it, which var/publish.log has whole); what to do is left off, whole
# (never cut: it holds a multi-byte character); the marker's line is cut, with "...", so that the reason is kept
# whole; and last the reason itself is cut. (Both lines are printable ASCII, adapter_cf_error_line sees to that, so a
# cut can't fall inside a character.) Returns 1, setting nothing, when there is no [ERROR] marker.
adapter_cf_refused() {
  local LC_ALL=C out m r hint="" pre="Cloudflare refused the upload: " room k nl=$'\n'
  out="$(adapter_cf_error_line "$1")"
  m="${out%%"$nl"*}"; r=""; case "$out" in *"$nl"*) r="${out#*"$nl"}" ;; esac
  [ -n "$m" ] || return 1
  case "$r" in
    "No access to the specified service"*)
      hint="The token lacks the permission Account → Workers Scripts → Edit for this site's account: edit the token, or run offprint adapter setup with one that has it" ;;
    *"[code: 10000]")
      hint="Either account_id in site.json isn't an account the token belongs to, or the token lacks the permission Account → Workers Scripts → Edit: offprint adapter doctor tells which" ;;
  esac
  room=$((300 - ${#pre}))
  if [ -n "$r" ]; then
    case "$m" in *" ("*")"*) [ $(( ${#m} + 2 + ${#r} + 2 + ${#hint} )) -le "$room" ] || { k="${m#* (}"; m="${m%% (*}${k#*)}"; } ;; esac
    if [ -n "$hint" ] && [ $(( ${#m} + 2 + ${#r} + 2 + ${#hint} )) -le "$room" ]; then r="$r$(adapter_cf_joint "$r")$hint"; fi
    if [ $(( ${#m} + 2 + ${#r} )) -gt "$room" ]; then
      k=$(( room - ${#r} - 4 )); [ "$k" -ge 20 ] || k=20
      m="${m:0:k}..."
    fi
    m="$m$(adapter_cf_joint "$m")$r"
  fi
  ADAPTER_PROBLEM="$pre${m:0:room}"
}
# adapter_cf_joint TEXT: what goes between TEXT and a sentence after it: a space when TEXT ends a sentence (or a clause:
# . ! ? : ;), else a full stop and a space
adapter_cf_joint() { case "$1" in *[.!?:\;]) printf ' ' ;; *) printf '. ' ;; esac; }

# adapter_cf_freeze PID: stops (STOP) that process, then each under it, top down, printing each pid: a stopped process
# can start no other, so the list is whole. adapter_cf_kill_tree PID: all of them frozen, then killed (KILL: none of
# them runs again, not even a handler for TERM).
adapter_cf_freeze() {
  local p IFS=$' \t\n'
  kill -STOP "$1" 2> /dev/null; echo "$1"
  for p in $(pgrep -P "$1" 2> /dev/null); do adapter_cf_freeze "$p"; done
}
adapter_cf_kill_tree() {
  local IFS=$' \t\n'
  # shellcheck disable=SC2046 # one pid a word
  kill -KILL $(adapter_cf_freeze "$1") 2> /dev/null
}
# adapter_cf_stop: stops whatever adapter_deploy still has running (node, with everything under it, and the filters) and
# removes its private folder. Run on every way out of adapter_deploy, a TERM or an INT included.
adapter_cf_stop() {
  local p IFS=$' \t\n'
  [ -z "${adapter_cf_node:-}" ] || adapter_cf_kill_tree "$adapter_cf_node"
  for p in ${adapter_cf_filters:-}; do kill -KILL "$p" 2> /dev/null; done
  case "${adapter_cf_work:-}" in
    */offprint-cf.??????) chmod -R u+rwX "$adapter_cf_work" 2> /dev/null; rm -rf "$adapter_cf_work" ;;
  esac
  adapter_cf_node=""; adapter_cf_filters=""; adapter_cf_work=""
}
# adapter_cf_end: adapter_cf_stop, and its traps lifted
adapter_cf_end() { adapter_cf_stop; trap - TERM INT EXIT; }
# adapter_cf_alive PID...: whether any of them still runs
adapter_cf_alive() { local p; for p; do kill -0 "$p" 2> /dev/null && return 0; done; return 1; }

# adapter_deploy COMMIT: see the top of this file.
adapter_deploy() {
  { set +x +a; } 2> /dev/null   # never traced, nothing exported unasked (an inherited allexport): this reads the token
  local commit="${1-}" entry node path secs line rc nrc=0 stopped=0 waited=0 cf_token="" IFS=$' \t\n'
  local commit_re='^[0-9a-f]{40}([0-9a-f]{24})?$'
  export -n cf_token   # (a local keeps the export of a caller's variable of its name, on bash 3.2 and 5 alike)
  adapter_cf_work=""; adapter_cf_node=""; adapter_cf_filters=""
  if ! adapter_validate > /dev/null 2>&1; then
    ADAPTER_PROBLEM="the adapter's settings in site.json aren't right; nothing was uploaded"; return 1
  fi
  if ! ( LC_ALL=C; [[ $commit =~ $commit_re ]] ); then
    ADAPTER_PROBLEM="the commit to upload isn't a commit id; nothing was uploaded"; return 1
  fi
  # What set-up installed, by the rules above (adapter_cf_home, adapter_cf_install_ok, adapter_cf_runnable): wrangler,
  # and the node it runs on. Nothing WordPress could have put there is run.
  # (Each problem leads with what to do, and ends with what is long, a path: the status keeps 300 characters.)
  if ! adapter_cf_home; then
    echo "offprint: $cf_home_problem; nothing was uploaded" >&2
    ADAPTER_PROBLEM="$cf_home_todo, then run offprint adapter setup: $cf_home_why${cf_home_shown:+: $cf_home_shown}"; return 1
  fi
  entry="$cf_entry"; rc=0; adapter_cf_install_ok "$cf_dest" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "offprint: wrangler 4.166.0 isn't installed: there is no $entry" >&2
       ADAPTER_PROBLEM="wrangler 4.166.0 isn't installed for Offprint; run offprint adapter setup"; return 1 ;;
    *) echo "offprint: $cf_dest can't be run: $cf_why" >&2
       ADAPTER_PROBLEM="run offprint adapter setup, which replaces it: wrangler's folder for Offprint can't be run ($cf_why)"; return 1 ;;
  esac
  if [ -L "$cf_nodefile" ]; then
    echo "offprint: $cf_nodefile is a symlink; it isn't followed" >&2
    ADAPTER_PROBLEM="run offprint adapter setup, which replaces it: the file naming wrangler's node is a symlink, so it wasn't read"; return 1
  fi
  node="$(adapter_cf_recorded "$cf_nodefile")"; rc=0; adapter_cf_runnable "$node" || rc=$?
  case "$rc" in
    0) ;;
    2) echo "offprint: $cf_nodefile names a node inside the site folder, or leading there" >&2
       ADAPTER_PROBLEM="the node recorded for wrangler is inside the site folder, which WordPress can write (or leads there), so it wasn't run; run offprint adapter setup"
       return 1 ;;
    *) echo "offprint: $cf_nodefile names no node that can be run" >&2
       ADAPTER_PROBLEM="the node that wrangler runs on isn't set up, or isn't there any more; run offprint adapter setup"; return 1 ;;
  esac
  # The private folder: removed on every way out from here on.
  trap 'adapter_cf_stop; exit 143' TERM
  trap 'adapter_cf_stop; exit 130' INT
  trap 'adapter_cf_stop' EXIT
  # (Never inside the site folder: offprint_private_dir compares the folders on disk.)
  if ! offprint_private_dir offprint-cf adapter_cf_work; then
    adapter_cf_work=""; cf_token=""; adapter_cf_end
    if [ -n "$OFFPRINT_PRIVATE_PROBLEM" ]; then
      ADAPTER_PROBLEM="no private folder could be made for the upload: $OFFPRINT_PRIVATE_PROBLEM; nothing was uploaded"
    else ADAPTER_PROBLEM="no private folder could be made for the upload (in TMPDIR); nothing was uploaded"; fi
    return 1
  fi
  line="$adapter_cf_work"
  # (Its path goes into wrangler.jsonc as a JSON string: so no quote, backslash or control character.)
  case "$line" in */offprint-cf.??????) ;; *) line="" ;; esac
  case "$line" in *'"'*|*'\'*) line="" ;; esac
  [ "$line" = "$(printf '%s' "$line" | LC_ALL=C tr -d '\001-\037\177')" ] || line=""
  if [ -z "$line" ]; then
    cf_token=""; adapter_cf_end
    ADAPTER_PROBLEM="the private folder for the upload has a path that can't go in wrangler's settings (TMPDIR); nothing was uploaded"; return 1
  fi
  adapter_cf_work="$line"
  echo "offprint: copying site/ of ${commit:0:7} out of the commit, to upload it to the Worker $ADAPTER_SET_WORKER"
  if ! adapter_cf_copy "$commit" "$adapter_cf_work"; then adapter_cf_end; return 1; fi
  if ! { mkdir "$adapter_cf_work/home" \
      && printf '{\n  "name": "%s",\n  "compatibility_date": "2026-11-21",\n  "assets": {\n    "directory": "%s",\n    "not_found_handling": "404-page"\n  }\n}\n' \
        "$ADAPTER_SET_WORKER" "$adapter_cf_work/site" > "$adapter_cf_work/wrangler.jsonc" \
      && mkfifo -m 600 "$adapter_cf_work/stdout" "$adapter_cf_work/stderr" && : > "$adapter_cf_work/output"; } 2> /dev/null; then
    adapter_cf_end
    ADAPTER_PROBLEM="the upload couldn't be set up in its private folder (is the disk full?); nothing was uploaded"; return 1
  fi
  # The token: read into this shell (not exported), with tracing off (above), only now that all but the upload is
  # ready, so that while it is held nothing runs but node and the filters (git, php, find and the rest have finished).
  # The Keychain's reason, never the value, goes to the log. A value that isn't plainly a token (adapter_cf_token_ok) is
  # never handed to node.
  cf_token="$(offprint_secret_get cloudflare-token)"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$cf_token" ]; then rc=1; fi
  if [ "$rc" = 0 ] && ! adapter_cf_token_ok; then rc=5; fi
  case "$rc" in
    0) ;;
    1) ADAPTER_PROBLEM="the Cloudflare token isn't in the Keychain; run offprint adapter setup" ;;
    3) ADAPTER_PROBLEM="the login Keychain is locked, so the Cloudflare token couldn't be read; unlock it, then publish again" ;;
    5) ADAPTER_PROBLEM="the Cloudflare token in the Keychain isn't plainly an API token, so it wasn't used; run offprint adapter setup" ;;
    *) ADAPTER_PROBLEM="the Cloudflare token couldn't be read from the Keychain (see var/publish.log); run offprint adapter doctor" ;;
  esac
  if [ "$rc" != 0 ]; then cf_token=""; adapter_cf_end; return 1; fi
  echo "offprint: uploading site/ of ${commit:0:7} to the Worker $ADAPTER_SET_WORKER with wrangler 4.166.0"

  secs="$(adapter_cf_limit)"
  path="${node%/*}"; [ -n "$path" ] || path=/
  # Each of node's two streams through a filter of its own, then node, in the background, so this shell can stop it.
  adapter_cf_filter < "$adapter_cf_work/stdout" 3>> "$adapter_cf_work/output" &
  adapter_cf_filters="$!"
  adapter_cf_filter < "$adapter_cf_work/stderr" 3>> "$adapter_cf_work/output" &
  adapter_cf_filters="$adapter_cf_filters $!"
  # node's environment: every exported variable and function of this shell dropped, then the six names, given by bash
  # itself (so the token is in no program's arguments). exec adds SHLVL, which env -u takes out before node starts. The
  # values are held as positional parameters while the variables go, whatever names the caller's environment had.
  (
    cd "$adapter_cf_work" || exit 126
    set -- "$cf_token" "$ADAPTER_SET_ACCOUNT_ID" "$adapter_cf_work/home" "$path:/usr/bin:/bin" "$node" "$entry" \
      "$adapter_cf_work/wrangler.jsonc"
    for v in $(compgen -A function); do unset -f "$v"; done
    for v in $(compgen -e); do unset "$v" 2> /dev/null || export -n "$v" 2> /dev/null; done
    CLOUDFLARE_API_TOKEN="$1" CLOUDFLARE_ACCOUNT_ID="$2" WRANGLER_SEND_METRICS=false CI=true HOME="$3" PATH="$4" \
      exec /usr/bin/env -u SHLVL "$5" "$6" deploy --config "$7"
  ) < /dev/null > "$adapter_cf_work/stdout" 2> "$adapter_cf_work/stderr" &
  adapter_cf_node="$!"
  while adapter_cf_alive "$adapter_cf_node" && [ "$waited" -lt $((secs * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
  if adapter_cf_alive "$adapter_cf_node"; then stopped=1; adapter_cf_kill_tree "$adapter_cf_node"; fi
  wait "$adapter_cf_node" 2> /dev/null; nrc=$?; adapter_cf_node=""
  cf_token=""
  # The filters end once every writer has closed the pipes; something node left behind holding them gets 5 seconds.
  waited=0
  while adapter_cf_alive $adapter_cf_filters && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  if adapter_cf_alive $adapter_cf_filters; then
    echo "offprint: something node left behind still held its output after 5 seconds; it is no longer read" >&2
    for line in $adapter_cf_filters; do kill -KILL "$line" 2> /dev/null; done
  fi
  for line in $adapter_cf_filters; do wait "$line" 2> /dev/null; done
  adapter_cf_filters=""

  if [ "$stopped" = 1 ]; then
    ADAPTER_PROBLEM="wrangler hadn't finished the upload after $secs seconds, so it was stopped; see var/publish.log"
    adapter_cf_end; return 1
  fi
  if [ "$nrc" != 0 ]; then
    adapter_cf_refused "$adapter_cf_work/output" \
      || ADAPTER_PROBLEM="the upload failed: wrangler ended with status $nrc and printed no [ERROR] line; see var/publish.log"
    adapter_cf_end; return 1
  fi
  adapter_cf_end
  return 0
}
