#!/usr/bin/env bash
# Names that must not be in the tool.
# - The plugin was renamed from "Static Publish" to "Offprint". No old spelling may be left in a tracked file. This
#   file and docs/ (which tell the story of the rename) are not searched.
# - The tool was copied from one person's site, where the tool and the site were one folder. A site's names now come
#   from its site.json, so none of that site's names, addresses or ports may be left in the tool's code.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

hits="$(git grep -n -I -i -E 'static.?publish|static.?export' -- . ':!docs' ':!tests/names.test.sh' ':!.superpowers')"
if [ -z "$hits" ]; then ok "no old Static Publish / static export spelling in any tracked file"
else bad "old spelling left in:"; echo "$hits"; fi

hits="$(git ls-files -- wp-content | head -5)"
if [ -z "$hits" ]; then ok "no wp-content/ folder in the tool repo"
else bad "wp-content/ still holds tracked files:"; echo "$hits"; fi

[ -f plugin/offprint.php ] && [ -d plugin/offprint/src ] && ok "plugin lives in plugin/" || bad "plugin lives in plugin/"

# The code, not the tests (whose data may name anything): bin/, lib/, os/ (the macOS set-up and agent), templates/
# and plugin/. The one allowed hit is this exact line of lib/config.php, the default local_host; any other line
# there, or anywhere else, is a failure.
allowed="$(cat <<'LINE'
$localHost = $str('local_host', '/\A' . HOST . '\z/D', 'a lowercase hostname with at least one dot', 'wp.local');
LINE
)"
code=""
for d in bin lib os templates plugin; do
  if [ -e "$d" ]; then code="$code $d"; else bad "the folder $d/ is missing"; fi
done
# shellcheck disable=SC2086 # the folder list
hits="$(git grep -n -I -E 'wp\.local|blog-e2e|project\.json|local\.wp\.|before-wp' -- $code \
  | ALLOWED="$allowed" awk '{ line = $0; sub(/^lib\/config\.php:[0-9]+:/, "", line) }
      !(index($0, "lib/config.php:") == 1 && line == ENVIRON["ALLOWED"])')"
if [ -z "$hits" ]; then ok "no site's names, addresses or ports in the tool's code (${code# })"
else bad "a site's names, addresses or ports left in the tool's code:"; echo "$hits"; fi

# The publish and its checks know no host by name: what a host needs (the files it writes, how the live site is asked
# which publish it serves, what to say when it doesn't) is in that host's adapter (adapters/, and lib/adapter.sh's
# contract). Comments too. Files not yet committed are searched as well (--untracked).
hits="$(git grep -n -I -i -E --untracked 'build\.json|wrangler|cloudflare|workers\.dev|GitHub Actions|Deploy workflow' \
  -- bin/publish bin/check-site bin/check-site-addresses.php lib)"
if [ -z "$hits" ]; then ok "no host named in bin/publish, bin/check-site, bin/check-site-addresses.php or lib/"
else bad "a host named in bin/publish, bin/check-site, bin/check-site-addresses.php or lib/:"; echo "$hits"; fi

if git ls-files --error-unmatch templates/compose.yaml > /dev/null 2>&1; then
  hits="$(git grep -n -E '^name:' -- templates/compose.yaml)"
  if [ -z "$hits" ]; then ok "templates/compose.yaml names no compose project (each site's is its own)"
  else bad "templates/compose.yaml names a compose project:"; echo "$hits"; fi
else
  bad "templates/compose.yaml is not in the repo"
fi

# Every entry point (what a person, launchd or sudo runs) names /bin/bash on its #! line: never a bash looked up on the
# PATH (#!/usr/bin/env bash), which, with . or an entry in the site folder on the PATH, could be one WordPress put in
# wp-content/. Every other file in bin/ and os/darwin/ with a #! line must be one of them, so a new one isn't missed.
entry_points="bin/offprint bin/new bin/publish bin/check-site bin/wp bin/setup-wp bin/publish-agent os/darwin/install-agent os/darwin/host-setup.sh os/darwin/host-undo.sh os/darwin/secret"
wrong=""
for f in $entry_points; do
  if [ ! -f "$f" ]; then wrong="$wrong $f (missing)"; elif [ "$(head -n 1 "$f")" != '#!/bin/bash' ]; then wrong="$wrong $f ($(head -n 1 "$f"))"; fi
done
for f in bin/* os/darwin/*; do
  case "$(head -c 2 "$f")" in '#!') ;; *) continue ;; esac
  case " $entry_points " in *" $f "*) ;; *) wrong="$wrong $f (an entry point not on the list here)" ;; esac
done
if [ -z "$wrong" ]; then ok "every entry point starts #!/bin/bash ($entry_points)"
else bad "an entry point doesn't start #!/bin/bash:$wrong"; fi
# The lines Offprint prints for the owner to run (as root, with sudo; or --print) name /bin/bash by its path too: sudo
# looks a bare bash up on the PATH it keeps, and with an entry in the site folder there, root would run WordPress's.
hits="$(grep -rnE 'sudo bash |sudo env .* bash |[^/]bash \$\(shq' bin os)"
if [ -z "$hits" ]; then ok "every line printed for the owner to run names /bin/bash, never a bash on the PATH (bin/, os/)"
else bad "a line printed for the owner to run names a bare bash:"; echo "$hits"; fi

# The tool is not a site: nothing of the one it was copied from is left at its root.
hits="$(git ls-files -- compose.yaml project.json local tests/fixtures/project.json tests/local.test.sh)"
if [ -z "$hits" ]; then ok "no compose.yaml, project.json, local/ or tests/local.test.sh left from when the tool was a site"
else bad "left from when the tool was a site:"; echo "$hits"; fi

[ "$fail" -eq 0 ]
