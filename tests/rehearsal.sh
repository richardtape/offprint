#!/usr/bin/env bash
# The rehearsal: a site's pigeonhole, whole, with the real programs and no real server. In Docker, on a private network
# of its own (compose project "offprint-rehearsal", tests/rehearsal/): a web server (Caddy, with the lines Offprint
# prints, and sshd, with the user Offprint's printed commands make) and a store set up by the script Offprint prints,
# with no published port. On the Mac, the real ssh, ssh-agent, ssh-add, age, age-keygen and curl:
#   offprint pigeonhole keys, print-server (applied to the two containers), doctor (its test submission goes through
#   Caddy to the store, and comes back through the ssh jump), offprint collect; and what the set-up must refuse (a
#   visitor naming their own address, a slow sender, any use of the pull key but its own, a machine with another host key).
# And a comment's whole journey, with the throwaway WordPress of tests/e2e-setup.sh (compose project "offprint-e2e",
# which tests/e2e.sh and tests/compat-seo.sh share: never beside either): a post that takes comments is exported and
# served by the rehearsal's Caddy; a visitor's comment and a reply are encrypted by the page's own script as it is
# committed (run in node: a browser's part is tried by hand, with --hold) and posted to Caddy; WordPress asks for a
# collection as its admin bar's button does; the site's agent fetches, opens and imports; the comments wait in
# WordPress, held; and, approved, one shows on the next export.
# It needs Docker, node, age (brew install age) and php, and the network the first time (images are pulled and a Debian
# package list read). Never run in CI. Run it on the Mac before merging any change to the fetch, the keys, the store's
# set-up, the printed server lines, the agent's part in comments, or the import.
#
# It touches no real site, server or Keychain: a throwaway site folder and Offprint folder in a temporary folder it
# removes; the stand-in Keychain of tests/fixtures/pigeonhole-standins.sh (OFFPRINT_SECURITY), which keeps the two
# throwaway keys this run makes in files in that temporary folder (the one place a test's private key is a file: a
# Keychain has to keep it somewhere); a HOME of its own, so nothing of the owner's ssh is read; a stand-in osascript
# (no notification is shown); and a docker of its own for offprint collect, which answers that WordPress runs and
# hands an import to the throwaway WordPress's container, by its id, and to nothing else.
# It refuses to start while either compose project has anything, and removes both when it ends.
#   bash tests/rehearsal.sh            everything above
#   bash tests/rehearsal.sh --hold     the same, then waits (until the file it names is removed) with the site up
#                                      and the store's limits new, for a real browser: it says what to open
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE OFFPRINT_HOME OFFPRINT_SECURITY PIGEONHOLE_CHECK_ORIGIN SSH_AUTH_SOCK SSH_AGENT_PID
hold=0; [ "${1:-}" != --hold ] || hold=1

for tool in docker node age age-keygen ssh ssh-agent ssh-add curl php git; do
  command -v "$tool" > /dev/null 2>&1 || { echo "$tool isn't installed, so the rehearsal can't run."; exit 2; }
done
PROJECT=offprint-rehearsal
LEFT=$( { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" && docker network ls -q --filter "label=com.docker.compose.project=$PROJECT"; } 2>&1 ) \
  || { echo "Docker didn't answer, so nothing was started: is it running? $LEFT"; exit 1; }
if [ -n "$LEFT" ]; then
  echo "The compose project $PROJECT already has containers or a network: another rehearsal is running, or a killed one"
  echo "left them. Nothing was started or removed. When none runs: docker compose -p $PROJECT down -v"
  exit 1
fi

# The throwaway WordPress (it refuses, here, while its project has anything; and sets a trap, replaced below by one
# that also runs its clean-up). Its check, lacks and cleanup are replaced by this script's own.
. tests/e2e-setup.sh
eval "e2e_$(declare -f cleanup)"

fail=0; passed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 ('$2' is not in: $(printf '%s' "$3" | head -c 600))"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' is in: $(printf '%s' "$3" | head -c 600))"; else ok "$1"; fi; }

# A short path: ssh-agent's socket goes under it, and a socket's whole path is about 100 bytes at most.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/oprh.XXXXXX")"; tmp="$(cd -P "$tmp" && pwd -P)"
c="$tmp/site"; S="$tmp/stubs"; H="$tmp/oh"; SERVED="$tmp/served"; B="$H/pigeonhole/rehearsal"
mkdir -p "$c/var" "$c/wp-content" "$c/adapters/rehearsal" "$tmp/home" "$tmp/t" "$SERVED" "$tmp/wpstub"
export TMPDIR="$tmp/t"
chmod 755 "$tmp" "$SERVED"
echo '<!doctype html><title>The rehearsal</title><p>A static site.' > "$SERVED/index.html"
. "$SRC/tests/fixtures/pigeonhole-standins.sh"
ph_standins "$S"   # only its Keychain is used: nothing of $S/bin goes on the PATH
REAL_DOCKER="$(command -v docker)"
cat > "$tmp/wpstub/docker" <<'STUB'
#!/usr/bin/env bash
# offprint collect's docker. The site's own compose project doesn't exist: the questions lib/site.sh asks of it find
# nothing, WordPress is said to be running, and an import is handed to the throwaway WordPress's container (WP_CONTAINER,
# its id), with the words bin/collect gave and no others. Anything else fails loudly.
echo "$*" >> "$WPSTUB_DIR/docker.calls"
[ "${1:-}" = compose ] || exit 0
case "$*" in
  *" ps "*) printf 'wordpress\ndb\n'; exit 0 ;;
  *" exec -T -u www-data wordpress wp offprint import-submission --sorted=hold"|*" exec -T -u www-data wordpress wp offprint import-submission --sorted=spam")
    [ -n "${WP_CONTAINER:-}" ] || { echo "the rehearsal has no WordPress yet" >&2; exit 99; }
    all="$*"   # (the pattern must be taken from the words as one text: on $* itself it is taken from each word)
    exec "$REAL_DOCKER" exec -i -u www-data "$WP_CONTAINER" wp offprint import-submission "--sorted=${all##*--sorted=}" ;;
esac
echo "the rehearsal's docker was asked for: $*" >&2; exit 99
STUB
# The agent's publish: none is made here (WordPress asks for one whenever a post changes). It notes that it was asked.
printf '#!/usr/bin/env bash\necho asked >> "%s/publish.calls"\n' "$tmp/wpstub" > "$tmp/wpstub/publish"
chmod +x "$tmp/wpstub/docker" "$tmp/wpstub/publish"
WP_CONTAINER=""

dcr() { REHEARSAL_SERVED="$SERVED" docker compose -p "$PROJECT" -f "$SRC/tests/rehearsal/compose.yaml" "$@"; }
cleanup() {
  dcr down -v --remove-orphans > /dev/null 2>&1
  e2e_cleanup
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# offprint ARGS...: the tool, for the throwaway site, with the real programs; sets out, code
offprint() {
  out="$(cd "$tmp" && STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/home" \
    OFFPRINT_OSASCRIPT="$S/bin/osascript" WPSTUB_DIR="$tmp/wpstub" REAL_DOCKER="$REAL_DOCKER" WP_CONTAINER="$WP_CONTAINER" \
    PUBLISH_AGENT_MIN_SECONDS=0 PUBLISH_AGENT_SETTLE_SECONDS=0 PUBLISH_AGENT_PUBLISH="$tmp/wpstub/publish" \
    PIGEONHOLE_CHECK_ORIGIN="$ORIGIN" PATH="$tmp/wpstub:$PATH" /bin/bash "$SRC/bin/offprint" "$@" 2>&1 < /dev/null)"; code=$?
}
ORIGIN=http://127.0.0.1:1

echo "Building and starting the two machines..."
dcr up -d --build --wait > "$tmp/up.log" 2>&1 || { cat "$tmp/up.log"; echo "the rehearsal's containers couldn't be started"; exit 1; }
WEB_PORT="$(dcr port web 80 | sed 's/.*://')"; JUMP_PORT="$(dcr port web 22 | sed 's/.*://')"
ORIGIN="http://127.0.0.1:$WEB_PORT"
i=0; while [ "$i" -lt 30 ] && ! { dcr exec -T store test -s /etc/ssh/ssh_host_ed25519_key.pub && dcr exec -T web test -s /etc/ssh/ssh_host_ed25519_key.pub && dcr exec -T web test -s /run/sshd.pid; } 2> /dev/null; do i=$((i + 1)); sleep 1; done
STORE_KEY="$(dcr exec -T store cut -d ' ' -f 1,2 /etc/ssh/ssh_host_ed25519_key.pub | tr -d '\r')"
JUMP_KEY="$(dcr exec -T web cut -d ' ' -f 1,2 /etc/ssh/ssh_host_ed25519_key.pub | tr -d '\r')"
check "the store has no published port: nothing on the Mac reaches it but through the web server" "" "$(dcr port store 8788 2> /dev/null; dcr port store 22 2> /dev/null)"

# ---- the keys ----------------------------------------------------------------------------------------------------------
site_json() {  # RECIPIENTS-JSON STORE-KEY JUMP-KEY
  local block=""
  if [ -n "$1" ]; then
    block=',"pigeonhole":{"path":"/_pigeonhole","recipients":'"$1"',"server":"10.213.77.5","server_host_key":"'"$2"'","jump":"127.0.0.1","jump_host_key":"'"$3"'","jump_port":'"$JUMP_PORT"'}'
  fi
  printf '%s%s}\n' '{"format":1,"name":"rehearsal","public_url":"https://www.example.com","local_host":"mysite.test","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998,"adapter":{"name":"rehearsal"}' "$block" > "$c/site.json"
}
site_json ""
echo "ADAPTER_PIGEONHOLE=1" > "$c/adapters/rehearsal/adapter.sh"
( cd "$c" && git init -q && git add adapters && git -c user.name=t -c user.email=t@example.com commit -q -m adapter ) || bad "couldn't make the site's repository"

offprint pigeonhole keys
check "keys, with the real age-keygen and php: exits 0" 0 "$code"
[ "$code" = 0 ] || { echo "$out"; echo "the keys couldn't be made, so nothing after this can be tried"; exit 1; }
DAILY_PUB="$(printf '%s\n' "$out" | grep -E '^    age1' | tr -d ' ')"
PULL_PUB="$(printf '%s\n' "$out" | grep -E '^    ssh-ed25519 ' | sed 's/^    //')"
[[ "$DAILY_PUB" =~ ^age1[a-z0-9]{58}$ ]] && ok "keys: the daily key's public half is printed" || bad "keys: no age public key in: $out"
[[ "$PULL_PUB" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}$ ]] && ok "keys: the pull key's public half is printed" || bad "keys: no ssh public key in: $out"
lacks "keys: no private key is printed" "AGE-SECRET-KEY" "$out"
lacks "keys: (the ssh one)" "PRIVATE KEY" "$out"
check "keys: the real age-keygen derives the same public half from what the Keychain holds" "$DAILY_PUB" "$(age-keygen -y < "$S/keychain/pigeonhole-daily" 2> /dev/null)"
RECOVERY="$(age-keygen 2> /dev/null | grep '^AGE-SECRET-KEY-')"; RECOVERY_PUB="$(printf '%s\n' "$RECOVERY" | age-keygen -y)"   # in these variables only
site_json "[\"$DAILY_PUB\",\"$RECOVERY_PUB\"]" "$STORE_KEY" "$JUMP_KEY"

# ---- the two servers, set up with what Offprint prints -------------------------------------------------------------------
offprint pigeonhole print-server store 10.213.77.2
check "print-server store: exits 0" 0 "$code"
printf '%s\n' "$out" > "$tmp/store-setup.sh"
dcr cp "$tmp/store-setup.sh" store:/root/store-setup.sh > /dev/null 2>&1
setup_out="$(dcr exec -T store /bin/bash /root/store-setup.sh 2>&1)"; rc=$?
check "the printed script runs clean on a new Debian, as root" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$setup_out" | tail -20
has "... it says the unit is written but not started (no systemd in a container)" "systemd isn't running here, so the unit is written but nothing was started." "$setup_out"
has "... it prints this machine's host key, for site.json" "  $STORE_KEY" "$setup_out"
has "... and the firewall lines, for the owner" "ufw allow from 10.213.77.2 to any port 8788 proto tcp" "$setup_out"
setup_out="$(dcr exec -T store /bin/bash /root/store-setup.sh 2>&1)"
check "... run a second time, it does the same and fails at nothing" 0 "$?"
check "... the store's folder is its user's alone" "700 ph-rehearsal" "$(dcr exec -T store stat -c '%a %U' /var/lib/pigeonhole/rehearsal/store | tr -d '\r')"
check "... the key's line is root's: the user can't change what its key may do" "644 root" "$(dcr exec -T store stat -c '%a %U' /var/lib/pigeonhole/rehearsal/.ssh/authorized_keys | tr -d '\r')"
check "... the user can't write its own .ssh" "no" "$(dcr exec -T -u ph-rehearsal store sh -c 'touch /var/lib/pigeonhole/rehearsal/.ssh/x 2>/dev/null && echo yes || echo no' | tr -d '\r')"
verify="$(dcr exec -T store systemd-analyze verify --man=no /etc/systemd/system/pigeonhole@rehearsal.service 2>&1 | grep -v -e 'pigeonhole@rehearsal.service: Command /usr/bin/node is not executable' || true)"
check "... systemd reads the unit and its drop-in without complaint (systemd-analyze verify)" "" "$(printf '%s\n' "$verify" | grep -i 'pigeonhole' || true)"
# No systemd here: the store is started by hand as the unit would start it (its user, its environment file).
dcr exec -T -d -u ph-rehearsal store sh -c 'set -a; . /etc/pigeonhole/rehearsal.env; exec node /opt/pigeonhole/store.js > /tmp/store.log 2>&1'
i=0; while [ "$i" -lt 20 ] && ! dcr exec -T web curl -s -o /dev/null --max-time 2 http://10.213.77.5:8788/ 2> /dev/null; do i=$((i + 1)); sleep 0.5; done

offprint pigeonhole print-server web
check "print-server web: exits 0" 0 "$code"
printf '%s\n' "$out" | sed -n '/^# ---- 1\./,/^# ---- 2\./p' | sed '$d' > "$tmp/site-extra.caddy"
printf '%s\n' "$out" | sed -n '/^# ---- 2\./,/^# ---- 3\./p' | sed '$d' > "$tmp/web-setup.sh"
dcr cp "$tmp/site-extra.caddy" web:/etc/caddy/site-extra.caddy > /dev/null 2>&1
dcr cp "$tmp/web-setup.sh" web:/root/web-setup.sh > /dev/null 2>&1
validate="$(dcr exec -T web caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; rc=$?
check "the printed Caddy lines, inside a site's block, pass the real caddy validate" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$validate" | tail -5
dcr exec -T web caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1
check "... and Caddy takes them (reload)" 0 "$?"
web_out="$(dcr exec -T web /bin/bash -eu /root/web-setup.sh 2>&1)"; rc=$?
check "the printed commands for the jump user run clean, as root" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$web_out" | tail -10
dcr exec -T web /bin/bash -eu /root/web-setup.sh > /dev/null 2>&1
check "... run a second time, they leave one line for this site, not two" "0 1" "$? $(dcr exec -T web grep -c . /var/lib/pigeonhole-jump/.ssh/authorized_keys | tr -d '\r')"
sleep 1

# ---- the doctor: the whole path, with the real everything ---------------------------------------------------------------
offprint pigeonhole doctor
check "doctor: exits 0" 0 "$code"
check "doctor: every line is ok" "" "$(printf '%s\n' "$out" | grep -v '^ok: ')"
has "doctor: both hops, against the pinned keys, and the pull command" "each showed the host key site.json pins, and the pull command answered (0 held there now)." "$out"
has "doctor: the real Caddy refuses a GET of the path" "ok: the public site refuses a GET of the path (404)" "$out"
has "doctor: a test submission went through Caddy to the store" "ok: a test submission was posted through the public site, and the store kept it (204)." "$out"
has "doctor: it came back through the jump" "ok: it was fetched to this Mac, and removed from the store." "$out"
has "doctor: the real age opened it with the key from the Keychain" "ok: the daily key opened it" "$out"
check "doctor: the store is empty again, and the canary is in done/" "0 1" "$(dcr exec -T store sh -c 'ls /var/lib/pigeonhole/rehearsal/store | wc -l' | tr -d ' \r') $(ls "$B/done" | grep -c .)"
check "doctor: nothing of the owner's ssh was made or changed (the run's HOME has no .ssh)" "" "$(ls -A "$tmp/home")"

# ---- a comment's whole journey ---------------------------------------------------------------------------------------------
# The throwaway WordPress, with this run's keys as its pigeonhole's, and the site's own var/ as the folder it reads
# (the admin bar's two files) and var/inbox as the one it writes its requests in: as a real site's are mounted.
echo "Starting the throwaway WordPress..."
E2E_PIGEONHOLE_PATH=/_pigeonhole; E2E_PIGEONHOLE_RECIPIENTS="$DAILY_PUB $RECOVERY_PUB"
mkdir -p "$c/var/inbox"; chmod 755 "$c" "$c/var"; chmod 777 "$c/var/inbox"
export E2E_PUBLISH="$c/var" E2E_INBOX="$c/var/inbox"
e2e_start > /dev/null 2>&1; e2e_install > /dev/null 2>&1
WP_CONTAINER="$(dc ps -q wordpress 2> /dev/null | head -n 1)"
[ -n "$WP_CONTAINER" ] && ok "the throwaway WordPress is up, with this run's keys as its pigeonhole's" || { bad "the throwaway WordPress didn't start"; exit 1; }
wp option update thread_comments 1 > /dev/null 2>&1
wp post delete 2 --force > /dev/null 2>&1   # WordPress's own Sample Page, which links to wp-admin: no export may
POST_ID="$(wp post create --post_title='Takes comments' --post_name=takes-comments --post_status=publish --post_author=1 --comment_status=open --post_content='<!-- wp:paragraph --><p>A post.</p><!-- /wp:paragraph -->' --porcelain 2> /dev/null)"
FIRST="$(wp comment create --comment_post_ID="$POST_ID" --comment_author=Ada --comment_author_email=ada@example.com --comment_content='MARKER-FIRST' --comment_approved=1 --porcelain 2> /dev/null)"
run_export rehearsal
check "a post that takes comments is exported" 0 "$EXPORT_STATUS"
offprint check "$E2E_EXPORT/rehearsal"
check "the export passes the publish's own checks, told this site's path and keys (offprint check)" 0 "$code"
[ "$code" = 0 ] || printf '%s\n' "$out" | head -5
# Served by the rehearsal's Caddy. A page names the site's public origin; here that is the web server's own address on
# this Mac, so the pages (never the two scripts) are rewritten to it, as nothing on the real site would need.
serve() {  # EXPORT-FOLDER: that export, as the site
  find "$SERVED" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -R "$1/." "$SERVED/"; chmod -R a+rX "$SERVED"
  grep -rlF "$PUBLIC" "$SERVED" 2> /dev/null | while IFS= read -r f; do
    case "$f" in */pigeonhole.js|*/pigeonhole-loader.js) continue ;; esac
    ORIGIN="$ORIGIN" PUBLIC="$PUBLIC" php -r '$t = file_get_contents($argv[1]); file_put_contents($argv[1], str_replace(getenv("PUBLIC"), getenv("ORIGIN"), $t));' "$f"
  done
}
serve "$E2E_EXPORT/rehearsal"
PAGE="$(curl -s "$ORIGIN/takes-comments/")"
has "Caddy serves the page, with its comment form's settings: this run's keys" "\"recipients\":[\"$DAILY_PUB\",\"$RECOVERY_PUB\"],\"bits\":18}" "$PAGE"
check "... and the two scripts, the tool's own, byte for byte" "" "$(curl -s "$ORIGIN/wp-content/mu-plugins/offprint/pigeonhole.js" | cmp - "$SRC/plugin/offprint/pigeonhole.js" 2>&1; curl -s "$ORIGIN/wp-content/mu-plugins/offprint/pigeonhole-loader.js" | cmp - "$SRC/plugin/offprint/pigeonhole-loader.js" 2>&1)"

# A visitor. The page's settings are read from the page as served; the comment is built, padded and proved as the
# sources do, and encrypted by the committed script itself; and it is posted as a browser's fetch posts it.
cp "$SRC/plugin/offprint/pigeonhole.js" "$tmp/pigeonhole.mjs"
visitor() {  # TEXT PARENT [HP]: prints the status the web server answered
  BUILT="$tmp/pigeonhole.mjs" SRC="$SRC" ORIGIN="$ORIGIN" POST_ID="$POST_ID" node --input-type=module -e '
    const { seal } = await import(process.env.BUILT);
    const t = await import(process.env.SRC + "/pigeonhole/browser/src/transport.js");
    const page = await (await fetch(process.env.ORIGIN + "/takes-comments/")).text();
    const block = JSON.parse(/<script type="application\/json" id="offprint-pigeonhole">(.*?)<\/script>/s.exec(page)[1]);
    const [text, parent, hp] = process.argv.slice(1);
    const { fields } = t.commentFields({ comment_post_ID: process.env.POST_ID, comment_parent: parent, author: "Zoë", email: "zoe@example.com", url: "",
      comment: text, offprint_hp: hp || "" }, 42);
    const sealed = await seal(t.padded(t.envelope("comment", fields, { page: "/takes-comments/" })), block.recipients);
    const answer = await fetch(process.env.ORIGIN + block.path, { method: "POST", body: await t.body(sealed, block.bits) });
    console.log(answer.status);' "$@" 2>&1
}
check "a visitor's comment, encrypted by the page's script to the keys the page names, is kept (204)" 204 "$(visitor 'MARKER-REHEARSAL a comment — with ünïcode, <b>bold</b> and <script>alert(1)</script>' 0)"
check "a reply to the first comment is kept" 204 "$(visitor 'MARKER-REPLY to Ada' "$FIRST")"
check "one that fills the field no person sees is kept too: the store can't tell, and decides nothing" 204 "$(visitor 'MARKER-HONEYPOT buy now' 0 filled)"
check "three wait on the store, and WordPress knows nothing yet" "3 0" "$(dcr exec -T store sh -c 'ls /var/lib/pigeonhole/rehearsal/store | wc -l' | tr -d ' \r') $(wp comment list --post_id="$POST_ID" --status=hold --format=count 2> /dev/null)"

# The agent's wake: it fetches, and opens nothing.
# (It doesn't fetch within four minutes of the last fetch, and the doctor's was moments ago: its note is made older.)
touch -t 202001010000 "$c/var/pigeonhole-fetch.json"
: > "$tmp/wpstub/docker.calls"
offprint agent
check "the agent's wake: exits 0" 0 "$code"
check "... it fetched the three, and removed them from the store" "3 0" "$(ls "$B/spool" | grep -c .) $(dcr exec -T store sh -c 'ls /var/lib/pigeonhole/rehearsal/store | wc -l' | tr -d ' \r')"
check "... it opened nothing: WordPress was handed nothing, and holds no new comment" "0 0" "$(grep -c 'import-submission' "$tmp/wpstub/docker.calls") $(wp comment list --post_id="$POST_ID" --status=hold --format=count 2> /dev/null)"
check "... one notification: a count and the site's name, nothing else" '-e display notification "3 comments are waiting to be checked" with title "Offprint: rehearsal"' "$(cat "$S/osascript.calls" 2> /dev/null)"
has "... WordPress's admin bar says three wait (it reads the site's var/)" "Comments: 3 have arrived on the Mac and wait to be checked." "$(dc exec -T -u www-data wordpress wp eval-file - bar --user=e2e-admin < tests/e2e-publish.php 2>&1)"
check "... nothing of a comment is in var/, the folder WordPress can read" "" "$(grep -rl 'MARKER-\|zoe@example' "$c/var" 2> /dev/null)"

# WordPress asks, as its admin bar's button does; the agent collects.
check "WordPress asks for a collection (what the Check for comments button runs)" "" "$(wp eval 'echo Offprint\Request::collect();' 2>&1)"
check "... the request is in the site's inbox" "collect-request" "$(ls "$c/var/inbox")"
rm -f "$S/osascript.calls"
offprint agent
check "the agent takes the request: exits 0" 0 "$code"
has "... and logs what collect said: counts, and nothing of a comment" "agent: comments: ok: 2 comments are waiting for you in WordPress's moderation queue. 1 went to WordPress's spam list." "$(cat "$c/var/publish.log")"
check "... nothing new had come since the wake's own fetch, and collect says of a fetch only what it brought" 0 "$(grep -c 'Fetched' "$c/var/publish.log")"
check "... the log has no word of any comment" 0 "$(grep -c 'MARKER-\|zoe@example\|Zoë' "$c/var/publish.log")"
check "... the request is gone, and nothing is left waiting in var/" "" "$(ls "$c/var/inbox")$(ls "$c/var" | grep waiting)"
for why in "$B"/rejected/*.why; do [ ! -e "$why" ] || echo "      refused: $(cat "$why")"; done
HELD="$(wp comment list --post_id="$POST_ID" --status=hold --fields=comment_ID,comment_parent,comment_author,comment_content --format=csv 2> /dev/null)"
has "the comment is in WordPress, held for moderation" "MARKER-REHEARSAL a comment — with ünïcode, <b>bold</b> and alert(1)" "$HELD"
lacks "... its script element gone: WordPress's filter was on at the import" "<script" "$HELD"
has "... the reply is held too, under the comment it answers" ",$FIRST,Zoë,\"MARKER-REPLY to Ada\"" "$HELD"
check "... the one that filled the hidden field went to the spam list, where the owner can still see it" 1 "$(wp comment list --post_id="$POST_ID" --status=spam --search=MARKER-HONEYPOT --format=count 2> /dev/null)"
check "... no visitor's address is recorded with any of them" "" "$(wp comment list --post_id="$POST_ID" --status=hold --field=comment_author_IP 2> /dev/null | tr -d '\n')"
check "... nothing was published by collecting: the post still shows one comment" 1 "$(wp comment list --post_id="$POST_ID" --status=approve --format=count 2> /dev/null)"
check "... the spool is empty, and the three (and the doctor's canary) are in done/" "0 4" "$(ls "$B/spool" | grep -c .) $(ls "$B/done" | grep -c .)"
has "... the admin bar says how it went" "2 are in the moderation queue; 1 went to spam." "$(dc exec -T -u www-data wordpress wp eval-file - bar --user=e2e-admin < tests/e2e-publish.php 2>&1)"
offprint collect
check "collect again: nothing new, and nothing imported twice" "0|ok: nothing is waiting in the pigeonhole's spool.|2" "$code|$out|$(wp comment list --post_id="$POST_ID" --status=hold --format=count 2> /dev/null)"

# Approved, it shows at the next export; held, it doesn't.
NEW="$(wp comment list --post_id="$POST_ID" --status=hold --search=MARKER-REHEARSAL --field=comment_ID 2> /dev/null | head -n 1)"
wp comment approve "$NEW" > /dev/null 2>&1
run_export approved
check "with the comment approved, the next export succeeds" 0 "$EXPORT_STATUS"
APPROVED="$(cat "$E2E_EXPORT/approved/takes-comments/index.html" 2> /dev/null)"
has "... and the page shows it" "MARKER-REHEARSAL a comment — with ünïcode, <b>bold</b> and alert(1)" "$APPROVED"
lacks "... the reply, still held, is not on the page" "MARKER-REPLY" "$APPROVED"
lacks "... nor the visitor's email address" "zoe@example.com" "$APPROVED"
offprint check "$E2E_EXPORT/approved"
check "... and it passes the publish's own checks" 0 "$code"
serve "$E2E_EXPORT/approved"
SENT=4   # what this address has had kept so far: the doctor's canary, and the three above

# ---- what the web server must do, and must not ----------------------------------------------------------------------------
# body: what a page posts for a new canary, in $tmp/body (a canary is no secret)
body() { php "$SRC/lib/pigeonhole-keys.php" canary | age -r "$DAILY_PUB" -r "$RECOVERY_PUB" | php "$SRC/lib/pigeonhole-keys.php" prove 18 3> /dev/null > "$tmp/body"; }
post() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type:' "$@" --data-binary @"$tmp/body" "$ORIGIN/_pigeonhole" 2> /dev/null; }
check "the real age makes a submission to two recipients the size the store takes (8490, and 8 of proof)" 8498 "$(body; wc -c < "$tmp/body" | tr -d ' ')"
check "a GET of the path is the static site's: 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "$ORIGIN/_pigeonhole")"
check "a POST below the path is the static site's to refuse" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$tmp/body" "$ORIGIN/_pigeonhole/x")"
check "a POST to the path with a query is passed on, and the store refuses its path (404)" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type:' --data-binary @"$tmp/body" "$ORIGIN/_pigeonhole?x=1")"
check "a PUT to the path is the static site's to refuse" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$tmp/body" "$ORIGIN/_pigeonhole")"
check "the static site is still served" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$ORIGIN/")"
check "a body over Caddy's limit never reaches the store (413)" "413" "$(head -c 40000 /dev/zero | curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type:' --data-binary @- "$ORIGIN/_pigeonhole")"
check "the store, asked directly with no address named, refuses (400): only the web server's own forwarding is taken" "400" \
  "$(dcr cp "$tmp/body" web:/tmp/body > /dev/null 2>&1; dcr exec -T web curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type:' --data-binary @/tmp/body http://10.213.77.5:8788/_pigeonhole | tr -d '\r')"

# A slow sender. The store gives a request four seconds; this one takes six. It is kept only if Caddy held the whole
# of it before passing any on (request_buffers): the slow sender held a place in Caddy, not in the store.
body
slow="$(PORT="$WEB_PORT" php -r '
  $b = file_get_contents($argv[1]);
  $s = stream_socket_client("tcp://127.0.0.1:" . getenv("PORT"), $e, $m, 5);
  fwrite($s, "POST /_pigeonhole HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: " . strlen($b) . "\r\nConnection: close\r\n\r\n" . substr($b, 0, 100));
  sleep(6);
  fwrite($s, substr($b, 100));
  stream_set_timeout($s, 10);
  echo substr((string) fgets($s), 9, 3);' "$tmp/body" 2> /dev/null)"
check "a body sent slowly (six seconds; the store allows four) is kept: Caddy took the whole of it first" 204 "$slow"

# A visitor who names their own address. Ten are taken from one address in an hour; this address has had some kept
# already. Each of these claims another address in the store's own header (and in the forwarding one): were either
# believed, none would ever be refused.
SENT=$((SENT + 1))   # the slow one
codes=""; want=""
i=0; while [ "$i" -lt $((12 - SENT)) ]; do
  i=$((i + 1)); body
  codes="$codes $(post -H "X-Pigeonhole-Client: 198.51.100.$i" -H "X-Forwarded-For: 198.51.100.$i")"
  if [ $((SENT + i)) -le 10 ]; then want="$want 204"; else want="$want 429"; fi
done
check "this address's tenth is kept, and its eleventh and twelfth refused, whatever address each claimed (Caddy sets the header itself)" "$want" "$codes"
# The store says what it counted when it is stopped (the fetch needs only its machine's ssh).
dcr exec -T store pkill -TERM -f store.js > /dev/null 2>&1; sleep 1
log="$(dcr exec -T store cat /tmp/store.log | tr -d '\r')"
check "the store wrote down no address, name or body: its log is counts" "" \
  "$(printf '%s\n' "$log" | grep -v -E '^pigeonhole: (taking /_pigeonhole on 10\.213\.77\.5:8788|([a-z ]+ [0-9]+(, )?)+)$')"
has "... ten kept, two refused for their address, one with no address named; and two for their path (this script's own look to see it was up, and the POST with a query): the POST below the path and the PUT never reached it" "address 2, elsewhere 2, kept 10, no address 1" "$(printf '%s\n' "$log" | tr '\n' ' ' | sed 's/pigeonhole: //g')"
lacks "... (no other method arrived)" "method" "$log"

# ---- the fetch, and the collection, as the owner runs them -----------------------------------------------------------------
check "six wait on the store (the canaries sent since the agent's fetch)" 6 "$(dcr exec -T store sh -c 'ls /var/lib/pigeonhole/rehearsal/store | wc -l' | tr -d ' \r')"
offprint collect --fetch-only
check "collect --fetch-only: exits 0" 0 "$code"
check "collect --fetch-only: says so" "ok: Fetched 6 submissions from the pigeonhole. 6 are waiting to be opened (offprint collect)." "$out"
check "... the store is empty, and each file in the spool is the bytes its name says" "0 6 6" \
  "$(dcr exec -T store sh -c 'ls /var/lib/pigeonhole/rehearsal/store | wc -l' | tr -d ' \r') $(ls "$B/spool" | grep -c .) $(cd "$B/spool" && for f in *.age; do [ "$(php -r 'echo hash_file("sha256", $argv[1]);' "$f").age" = "$f" ] && echo y; done | grep -c y)"
offprint collect
check "collect: exits 0" 0 "$code"
check "collect: every one was a test submission, opened with the real age and dropped" "ok: 6 test submissions arrived." "$out"
check "... the spool is empty" 0 "$(ls "$B/spool" | grep -c .)"

# ---- what the pull key can do, and can't --------------------------------------------------------------------------------
# A config, a known_hosts and an agent as a fetch makes them (lib/pigeonhole.sh), then the real ssh, asked for more.
probe() {  # WORDS...: a bash line run with the fetch's own ssh set-up ready ($PH_CONFIG); sets out
  out="$(cd "$tmp" && STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/home" /bin/bash -c '
    . "$1/lib/site.sh"; . "$1/lib/adapter.sh"; . "$1/lib/pigeonhole.sh"
    offprint_find_site; offprint_load_site
    offprint_private_dir offprint-probe TMP || exit 97
    trap "pigeonhole_ssh_close; rm -rf \"\$TMP\"" EXIT
    pigeonhole_ssh_open "$TMP" || { echo "open failed: $PIGEONHOLE_PROBLEM"; exit 98; }
    eval "$2"' _ "$SRC" "$1" 2>&1 < /dev/null)"; code=$?
}
probe 'ssh -F "$PH_CONFIG" -n -T offprint-store list'
check "the pull command answers the real ssh, through the real jump: list (nothing held)" "0|" "$code|$out"
for words in "id" "sh" "list; id" "get /etc/passwd" "get ../../../etc/passwd" "delete *" "scp -f /etc/passwd" "/bin/sh -c id"; do
  probe "ssh -F \"\$PH_CONFIG\" -n -T offprint-store '$words'"
  check "on the store, the key asked for \"$words\": refused, and nothing ran" "2|refused" "$code|$out"
done
probe 'ssh -F "$PH_CONFIG" -n -T offprint-store'
check "on the store, the key asked for a shell: it gets the pull command, which refuses" "2|refused" "$code|$out"
probe 'ssh -F "$PH_CONFIG" -n -tt offprint-store 2>&1'
lacks "on the store, the key asked for a terminal: none is given" "\$ " "$out"
has "... (sshd says so)" "PTY allocation request failed" "$out"
probe 'ssh -F "$PH_CONFIG" -o ClearAllForwardings=no -o ExitOnForwardFailure=yes -n -T -L 127.0.0.1:18788:10.213.77.5:8788 offprint-store list; curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:18788/ || true'
lacks "on the store, the key can't forward a port" "404" "$out"
probe 'ssh -F "$PH_CONFIG" -W 10.213.77.5:8788 offprint-store < /dev/null'
has "on the store, the key can't open a connection onward" "forwarding failed" "$out"
probe 'ssh -F "$PH_CONFIG" -n -T offprint-jump id'
lacks "on the web server, the key runs no command" "uid=" "$out"
check "... (ssh fails)" yes "$([ "$code" != 0 ] && echo yes || echo no)"
probe 'ssh -F "$PH_CONFIG" -W 10.213.77.5:8788 offprint-jump < /dev/null'
has "on the web server, the key can't open a connection to the store's own port" "forwarding failed" "$out"
probe 'ssh -F "$PH_CONFIG" -W 10.213.77.2:80 offprint-jump < /dev/null'
has "... nor to the web server itself" "forwarding failed" "$out"
# Nor may it listen on the web server (a remote forward): a port of that machine's, or a socket, tunnelled back to
# whoever holds the key.
probe 'ssh -F "$PH_CONFIG" -o ClearAllForwardings=no -o ExitOnForwardFailure=yes -N -R 127.0.0.1:18999:127.0.0.1:9 offprint-jump < /dev/null & p=$!; sleep 3; kill $p 2> /dev/null; wait $p 2> /dev/null'
check "on the web server, the key can't open a listening port (ssh -R)" "0" "$(dcr exec -T web sh -c "ss -ltn 2>/dev/null | grep -c ':18999 ' || true" | tr -d '\r')"
probe 'ssh -F "$PH_CONFIG" -o ClearAllForwardings=no -o ExitOnForwardFailure=yes -N -R /tmp/offprint-probe.sock:127.0.0.1:9 offprint-jump < /dev/null & p=$!; sleep 3; kill $p 2> /dev/null; wait $p 2> /dev/null'
check "... nor a listening socket" "no" "$(dcr exec -T web sh -c 'test -e /tmp/offprint-probe.sock && echo yes || echo no' | tr -d '\r')"
probe 'ssh -F "$PH_CONFIG" -W 10.213.77.5:22 offprint-jump < /dev/null | head -c 4'
check "... only to the store's ssh (which answers as ssh does)" "SSH-" "$out"
probe 'SSH_AUTH_SOCK="$PH_DIR/a" ssh-add -D > /dev/null 2>&1; ssh -F "$PH_CONFIG" -n -T offprint-store list'
has "with no key in the run's agent, nothing is offered: the web server refuses" "Permission denied" "$out"
check "the key made in php is one the real ssh-add took, and the real sshd accepted: (shown by every line above)" 0 0
check "no private ssh key is in any file but the stand-in Keychain's" "" "$(grep -rl 'PRIVATE KEY' "$tmp" 2> /dev/null | grep -v "^$S/")"
check "... and the owner's own ssh folder was never made in the run's HOME" "" "$(ls -A "$tmp/home")"

# The store takes the key only from the web server's own address: from anywhere else on the private network it is no use.
check "the store's line for the key names the one address it may come from" 1 "$(dcr exec -T store grep -c '^restrict,from="10.213.77.2",command=' /var/lib/pigeonhole/rehearsal/.ssh/authorized_keys | tr -d '\r')"

# ---- a machine that shows another host key is not spoken to ---------------------------------------------------------------
OTHER="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'A%.0s' $(seq 1 43))"
site_json "[\"$DAILY_PUB\",\"$RECOVERY_PUB\"]" "$OTHER" "$JUMP_KEY"; offprint collect --fetch-only
check "the store shows a key that isn't the one pinned: refused" 1 "$code"
has "... and said, in the tool's own words" "the pigeonhole's server (site.json's pigeonhole.server) didn't show the ssh host key site.json pins for it (pigeonhole.server_host_key)" "$out"
site_json "[\"$DAILY_PUB\",\"$RECOVERY_PUB\"]" "$STORE_KEY" "$OTHER"; offprint collect --fetch-only
check "the web server shows a key that isn't the one pinned: refused" 1 "$code"
has "... and said" "the web server (site.json's pigeonhole.jump) didn't show the ssh host key site.json pins for it (pigeonhole.jump_host_key)" "$out"
site_json "[\"$DAILY_PUB\",\"$RECOVERY_PUB\"]" "$STORE_KEY" "$JUMP_KEY"
dcr exec -T web sh -c ': > /var/lib/pigeonhole-jump/.ssh/authorized_keys'; offprint collect --fetch-only
has "the web server no longer has the key: said" "the web server (site.json's pigeonhole.jump) refused this site's pull key" "$out"
dcr exec -T web /bin/bash -eu /root/web-setup.sh > /dev/null 2>&1
dcr exec -T store sh -c ': > /var/lib/pigeonhole/rehearsal/.ssh/authorized_keys'; offprint collect --fetch-only
has "the store no longer has the key: said" "the pigeonhole's server (site.json's pigeonhole.server) refused this site's pull key" "$out"
dcr exec -T store /bin/bash /root/store-setup.sh > /dev/null 2>&1
dcr stop store > /dev/null 2>&1; offprint collect --fetch-only
check "the store is down: refused" 1 "$code"
has "... and said" "couldn't be reached over ssh" "$out"

if [ "$hold" = 1 ]; then
  # For a real browser: the store started again (its limits are in memory, so they are new), the site as last exported.
  dcr start store > /dev/null 2>&1
  dcr exec -T -d -u ph-rehearsal store sh -c 'set -a; . /etc/pigeonhole/rehearsal.env; exec node /opt/pigeonhole/store.js > /tmp/store.log 2>&1'
  : > "$tmp/remove-me-to-end"
  {
    echo "export STUB_DIR='$S' OFFPRINT_SITE='$c' OFFPRINT_HOME='$H' OFFPRINT_SECURITY='$S/security' HOME='$tmp/home' TMPDIR='$TMPDIR'"
    echo "export OFFPRINT_OSASCRIPT='$S/bin/osascript' WPSTUB_DIR='$tmp/wpstub' REAL_DOCKER='$REAL_DOCKER' WP_CONTAINER='$WP_CONTAINER'"
    echo "export PIGEONHOLE_CHECK_ORIGIN='$ORIGIN' PATH='$tmp/wpstub':\"\$PATH\" POST_ID='$POST_ID'"
  } > "$tmp/env.sh"
  echo "HOLDING. The page: $ORIGIN/takes-comments/   To run the tool for this site: . $tmp/env.sh; bash $SRC/bin/offprint collect"
  echo "Remove $tmp/remove-me-to-end to end."
  while [ -e "$tmp/remove-me-to-end" ]; do sleep 2; done
fi

echo "$passed ok"
[ "$fail" -eq 0 ]
