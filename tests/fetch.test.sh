#!/usr/bin/env bash
# Tests the fetch (lib/pigeonhole.sh, through offprint collect): what a site's pigeonhole holds is brought to the
# Mac's spool over ssh, each file checked against its name before it is kept and removed from the store only after;
# and the pull key goes from the Keychain to the run's own ssh-agent on pipes, and nowhere else. Hermetic: a throwaway
# site folder, an Offprint folder of the case's own (OFFPRINT_HOME), and stand-ins first on the PATH or named by a seam
# (tests/fixtures/pigeonhole-standins.sh: ssh, ssh-agent, ssh-add, the Keychain, osascript; tests/fixtures/age-standin;
# a docker that answers as WordPress's import does). Nothing here reaches a network, a real agent, a real site or the
# Keychain. tests/rehearsal.sh runs the same fetch with the real ssh, through a real jump, to a real pull command.
# Run: bash tests/fetch.test.sh. Works on macOS (bash 3.2) and Linux.
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE OFFPRINT_HOME OFFPRINT_SECURITY OFFPRINT_OSASCRIPT SSH_AUTH_SOCK SSH_AGENT_PID
. "$SRC/tests/fixtures/pigeonhole-standins.sh"
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-fetch-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd -P "$tmp" && pwd -P)"
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 ('$2' is not in: $3)"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' is in the output)"; else ok "$1"; fi; }

KEY=AGE-SECRET-KEY-1TEST
Q62="age1$(printf 'q%.0s' $(seq 1 58))"
HK1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'A%.0s' $(seq 1 43))"
HK2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'B%.0s' $(seq 1 43))"
MARK=MARKER-ZX81     # in every comment's text
PULLMARK=PULLKEYMARKERpullkeymarker   # in the pull key: it must turn up nowhere but on the pipes
PEM="-----BEGIN OPENSSH PRIVATE KEY-----
$PULLMARK
-----END OPENSSH PRIVATE KEY-----"
PULL_LINE="$(printf '%s\n' "$PEM" | base64 | tr -d '\n')"

n=0
# newcase [SERVER-FIELDS]: a site folder $c whose pigeonhole names its server (or, given "", none), its Offprint
# folder $H, the stand-ins in $S, the store's folder $R, and both keys in the stand-in Keychain
newcase() {
  n=$((n + 1)); c="$tmp/case$n/site"; S="$tmp/case$n/stubs"; H="$tmp/case$n/ohome"
  B="$H/pigeonhole/example"; SP="$B/spool"; R="$S/remote"
  mkdir -p "$c/wp-content" "$c/var" "$tmp/case$n/home" "$tmp/case$n/make"; M="$tmp/case$n/make/blob"
  ph_standins "$S"
  server="${1-,\"server\":\"10.0.0.5\",\"server_host_key\":\"$HK1\",\"jump\":\"192.0.2.10\",\"jump_host_key\":\"$HK2\"}"
  printf '%s\n' '{"format":1,"name":"example","public_url":"https://www.example.com","local_host":"mysite.test","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998,' \
    "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"]$server}}" > "$c/site.json"
  cp "$SRC/tests/fixtures/age-standin" "$S/bin/age"; chmod +x "$S/bin/age"
  cat > "$S/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.calls"
[ "${1:-}" = compose ] || exit 0
case "$*" in
  *" ps "*) printf 'wordpress\ndb\n'; exit 0 ;;
  *" wp offprint import-submission"*)
    i=$(( $(cat "$STUB_DIR/import.count" 2>/dev/null || echo 0) + 1 )); echo "$i" > "$STUB_DIR/import.count"
    cat > "$STUB_DIR/import.$i"; echo "imported $i hold"; exit 0 ;;
esac
echo "unexpected docker call: $*" >&2; exit 99
STUB
  chmod +x "$S/bin/docker"
  printf '%s' "$KEY" > "$S/keychain/pigeonhole-daily"
  printf '%s' "$PULL_LINE" > "$S/keychain/pigeonhole-pull"
  printf '%s\n' "$PEM" > "$S/pullkey.pem"
}
BN=0
# held [TEXT]: a comment as the store keeps one, in $R; sets blob (its name). (Not at the end of a pipe.)
held() {
  BN=$((BN + 1))
  { echo "age-encryption.org/v1"; echo "-> stand-in"; echo "--- run 1"
    BN="$BN" php -r 'require $argv[1];
      $d = ["v" => 1, "kind" => "comment", "id" => sprintf("%032x", (int) getenv("BN")), "ts" => time() - 60, "page" => "/hello/",
        "fields" => ["post_id" => 4, "parent" => 0, "author" => "Ada", "email" => "ada@example.com", "url" => "", "content" => $argv[2], "hp" => "", "elapsed" => 42]];
      echo str_pad(offprint_pigeonhole_line($d), 8192, " ");' "$SRC/lib/pigeonhole.php" "${1:-$MARK a comment $BN}"; } > "$M"
  blob="$(php -r 'echo hash_file("sha256", $argv[1]);' "$M").age"
  mv "$M" "$R/$blob"
}
# collect [ARGS...]: offprint collect for the site; sets out, code
collect() {
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" \
    OFFPRINT_OSASCRIPT="$S/bin/osascript" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/offprint" collect "$@" 2>&1 < /dev/null)"; code=$?
}
count() { ls "$1" 2>/dev/null | grep -c . ; }
calls() { if [ -f "$1" ]; then grep -c -- "$2" "$1"; else echo 0; fi; }
fstatus() { sed 's/"fetched_at":[0-9]*,//' "$c/var/pigeonhole-fetch.json" 2>/dev/null; }
# clean NAME: the pull key is nowhere it must not be, and the run left nothing behind
clean() {
  check "$1: the pull key is in no file (but the stand-ins, which know it)" "" "$(grep -rl -e "$PULLMARK" -e "$PULL_LINE" "$tmp/case$n" "$TMPDIR" 2>/dev/null | grep -v '/stubs/')"
  check "$1: ... and in no program's arguments" "" "$(grep -l -e "$PULLMARK" -e "$PULL_LINE" "$S"/*.calls 2>/dev/null)"
  lacks "$1: ... and not in what was printed" "$PULLMARK" "$out"
  lacks "$1: ... nor as the Keychain holds it" "$PULL_LINE" "$out"
  check "$1: the run's ssh-agent was ended" "gone" "$(cat "$S/agent.ended" 2>/dev/null)"
  check "$1: ... and is no process now" "" "$(pid="$(cat "$S/agent.pid" 2>/dev/null)"; [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || echo running)"
  check "$1: the spool's lock is gone" "" "$(ls -d "$B/lock" 2>/dev/null)"
  check "$1: no private folder is left in TMPDIR" "" "$(ls "$TMPDIR" 2>/dev/null)"
  check "$1: nothing half-fetched is left in the spool" "" "$(ls -A "$SP" 2>/dev/null | grep '^\.incoming')"
}

# ---- a fetch alone: what the agent runs ---------------------------------------------------------------------------------
newcase; held; one="$blob"; held; two="$blob"; cp "$R/$one" "$tmp/case$n/one"
collect --fetch-only; t="--fetch-only, two on the store"
check "$t: exits 0" 0 "$code"
check "$t: says how many, and that they wait" "ok: Fetched 2 submissions from the pigeonhole. 2 are waiting to be opened (offprint collect)." "$out"
check "$t: both are in the spool, under their names" "$(printf '%s\n%s\n' "$one" "$two" | sort)" "$(ls "$SP" | sort)"
check "$t: byte for byte" "" "$(cmp "$SP/$one" "$tmp/case$n/one" 2>&1)"
check "$t: and gone from the store" 0 "$(count "$R")"
check "$t: a file in the spool is the owner's alone to read" "600" "$(perl -e 'printf "%o", (stat shift)[2] & 0777' "$SP/$one")"
check "$t: nothing was opened: age never ran" 0 "$(calls "$S/age.calls" .)"
check "$t: ... WordPress was handed nothing" 0 "$(calls "$S/docker.calls" import-submission)"
check "$t: ... and the daily key was never asked for" 0 "$(calls "$S/security.calls" pigeonhole-daily)"
check "$t: the Keychain was asked for the pull key, once" 1 "$(calls "$S/security.calls" 'example/pigeonhole-pull -w')"
check "$t: var/pigeonhole-fetch.json has the counts, and nothing else" '{"ok":true,"fetched":2,"damaged":0,"left":0,"waiting":2,"reason":""}' "$(fstatus)"
check "$t: no notification without --notify" 0 "$(calls "$S/osascript.calls" .)"
check "$t: the publish's lock was not taken" "" "$(ls -d "$c/var/publish.lock" 2>/dev/null)"
clean "$t"
# what ssh was given: this run's own files, both host keys pinned, nothing of the owner's
cfg="$(cat "$S/seen.config")"
check "$t: every ssh call was -F CONFIG -n -T offprint-store WORDS" "" "$(grep -vE '^-F [^ ]+/config -n -T offprint-store (list|(get|delete) [0-9a-f]{64}\.age)$' "$S/ssh.calls")"
check "$t: the order: list, then each got and only then deleted" "list get delete get delete" "$(awk '{print $6}' "$S/ssh.calls" | tr '\n' ' ' | sed 's/ $//')"
check "$t: known_hosts pins both machines' keys, by this run's own names for them" "offprint-jump $HK2
offprint-store $HK1" "$(cat "$S/seen.known_hosts")"
for line in "  StrictHostKeyChecking yes" "  GlobalKnownHostsFile /dev/null" "  UpdateHostKeys no" "  BatchMode yes" "  IdentityFile none" \
    "  ForwardAgent no" "  HostKeyAlgorithms ssh-ed25519" "  HostName 10.0.0.5" "  HostName 192.0.2.10" "  User ph-example" "  User pigeonhole-jump" \
    "  HostKeyAlias offprint-store" "  HostKeyAlias offprint-jump" "  Port 22" "  PasswordAuthentication no" "  RequestTTY no" "  ControlPath none"; do
  if printf '%s\n' "$cfg" | grep -qxF -- "$line"; then ok "$t: the config has \"${line#  }\""; else bad "$t: the config lacks \"$line\""; fi
done
has "$t: the hop through the web server is given the same config file" "-F '$(awk '{print $2; exit}' "$S/ssh.calls")' -W '[%h]:%p' offprint-jump" "$cfg"
if printf '%s\n' "$cfg" | grep -qE "^  ProxyCommand '[^']+' -F '[^']+' -W '\[%h\]:%p' offprint-jump$"; then ok "$t: every word of the hop's command is in single quotes (ssh runs it through the owner's shell, and zsh reads [..] as a pattern)"; else bad "$t: the hop's command is not quoted: $(printf '%s\n' "$cfg" | grep ProxyCommand)"; fi
check "$t: the owner's own agent is never offered: SSH_AUTH_SOCK is unset for ssh" "unset" "$(sort -u "$S/ssh.env")"
has "$t: the key went to ssh-add on standard input, for this run's agent, with no prompt possible" "-q -t 900 - | sock $TMPDIR/offprint-collect." "$(cat "$S/sshadd.calls")"
has "$t: ... (askpass never)" "askpass never" "$(cat "$S/sshadd.calls")"

newcase; collect --fetch-only; t="--fetch-only, nothing on the store"
check "$t: exits 0" 0 "$code"
check "$t: says so" "ok: Nothing new on the pigeonhole. 0 are waiting to be opened (offprint collect)." "$out"
check "$t: the status" '{"ok":true,"fetched":0,"damaged":0,"left":0,"waiting":0,"reason":""}' "$(fstatus)"
clean "$t"

newcase; held; mkdir "$c/var/publish.lock"; echo 1 > "$c/var/publish.lock/pid"; collect --fetch-only; t="--fetch-only while a publish holds its lock"
check "$t: exits 0: a fetch does not wait on a publish" 0 "$code"
check "$t: it fetched" 1 "$(count "$SP")"
check "$t: the publish's lock is left as it was" 1 "$(cat "$c/var/publish.lock/pid")"

# ---- sites with nothing to fetch from ---------------------------------------------------------------------------------
newcase ""; collect --fetch-only; t="--fetch-only, a pigeonhole that names no server"
check "$t: exits 0" 0 "$code"
check "$t: says nothing (the agent runs it for every site)" "" "$out"
check "$t: ssh never ran" 0 "$(calls "$S/ssh.calls" .)"
check "$t: the Keychain was not asked" 0 "$(calls "$S/security.calls" .)"
check "$t: no folder was made for it" "" "$(ls "$H" 2>/dev/null)"
newcase ""; printf '%s\n' '{"format":1,"name":"example","public_url":"https://www.example.com","local_host":"mysite.test","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998}' > "$c/site.json"
collect --fetch-only --notify; t="--fetch-only, a site with no pigeonhole"
check "$t: exits 0" 0 "$code"
check "$t: says nothing" "" "$out"
check "$t: ssh never ran" 0 "$(calls "$S/ssh.calls" .)"
newcase ""; collect; t="collect, a pigeonhole that names no server"
check "$t: exits 0: the spool alone is read" 0 "$code"
check "$t: ssh never ran" 0 "$(calls "$S/ssh.calls" .)"
check "$t: no fetch status is written" "" "$(ls "$c/var/pigeonhole-fetch.json" 2>/dev/null)"

# ---- collect: the fetch, then the opening --------------------------------------------------------------------------------
newcase; held; held; collect; t="collect, two on the store"
check "$t: exits 0" 0 "$code"
check "$t: says both steps" "ok: Fetched 2 submissions from the pigeonhole. 2 comments are waiting for you in WordPress's moderation queue." "$out"
check "$t: WordPress was handed both" 2 "$(calls "$S/docker.calls" import-submission)"
check "$t: the spool is empty, and both are in done/" "0 2" "$(count "$SP") $(count "$B/done")"
check "$t: the store is empty" 0 "$(count "$R")"
check "$t: the fetch status counts none waiting now... as of the fetch, two" '{"ok":true,"fetched":2,"damaged":0,"left":0,"waiting":2,"reason":""}' "$(fstatus)"
has "$t: and the collection's own status none" '"waiting":0' "$(cat "$c/var/pigeonhole.json")"
check "$t: the publish's lock is gone" "" "$(ls -d "$c/var/publish.lock" 2>/dev/null)"
clean "$t"

newcase; held; collect --no-fetch; t="collect --no-fetch"
check "$t: exits 0" 0 "$code"
check "$t: says there is nothing in the spool" "ok: nothing is waiting in the pigeonhole's spool." "$out"
check "$t: ssh never ran" 0 "$(calls "$S/ssh.calls" .)"
check "$t: the store still holds it" 1 "$(count "$R")"

newcase; collect; t="collect, nothing anywhere"
check "$t: exits 0" 0 "$code"
check "$t: says so" "ok: nothing is waiting in the pigeonhole's spool." "$out"
clean "$t"

# ---- the store can't be reached, or isn't the store ------------------------------------------------------------------
unreachable="the pigeonhole's server couldn't be reached over ssh, through the web server (site.json's pigeonhole.jump). Is this Mac online, and are both machines up? offprint pigeonhole doctor checks each step."
newcase; held; echo "ssh: connect to host 192.0.2.10 port 22: Operation timed out" > "$S/ssh_says"; collect --fetch-only; t="the web server can't be reached"
check "$t: exits 1" 1 "$code"
check "$t: says so, and what to try" "problem: The fetch: $unreachable" "$out"
check "$t: the status says it failed, in one fixed word" '{"ok":false,"fetched":0,"damaged":0,"left":0,"waiting":0,"reason":"unreachable"}' "$(fstatus)"
clean "$t"

newcase; held; mkdir -p "$SP"; chmod 700 "$H/pigeonhole" "$B" "$SP"; held; mv "$R/$blob" "$SP/$blob"
echo "ssh: connect to host 192.0.2.10 port 22: Operation timed out" > "$S/ssh_says"; collect; t="collect when the store can't be reached"
check "$t: exits 1" 1 "$code"
check "$t: what was in the spool already is opened all the same, and the fetch's failure said" "problem: 1 comment is waiting for you in WordPress's moderation queue. The fetch: $unreachable" "$out"
check "$t: WordPress was handed it" 1 "$(calls "$S/docker.calls" import-submission)"
newcase; echo "ssh: connect to host 192.0.2.10 port 22: Operation timed out" > "$S/ssh_says"; collect; t="collect, nothing in the spool, and the store can't be reached"
check "$t: exits 1" 1 "$code"
check "$t: says both" "problem: The fetch: $unreachable Nothing is waiting in the pigeonhole's spool." "$out"

# what_ssh_said WORDS REASON TEXT-IT-MUST-SAY NAME
said_case() {
  newcase; held; printf '%s\n' "$1" > "$S/ssh_says"; collect --fetch-only
  check "$4: exits 1" 1 "$code"
  has "$4: says which machine, and what to do" "$3" "$out"
  has "$4: the status's one word" "\"reason\":\"$2\"" "$(fstatus)"
  check "$4: nothing was fetched" "0 1" "$(count "$SP") $(count "$R")"
  lacks "$4: what ssh itself said is not repeated" "SERVER-SAID" "$out"
}
said_case "No ED25519 host key is known for offprint-jump and you have requested strict checking. SERVER-SAID
Host key verification failed." jump-host-key "the web server (site.json's pigeonhole.jump) didn't show the ssh host key site.json pins for it (pigeonhole.jump_host_key), so it wasn't spoken to." "the web server shows a host key that isn't pinned"
said_case "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
The ED25519 host key for offprint-jump has changed, SERVER-SAID
Host key verification failed." jump-host-key "pigeonhole.jump_host_key" "the web server's host key has changed"
said_case "No ED25519 host key is known for offprint-store and you have requested strict checking. SERVER-SAID
Host key verification failed." store-host-key "the pigeonhole's server (site.json's pigeonhole.server) didn't show the ssh host key site.json pins for it (pigeonhole.server_host_key), so it wasn't spoken to." "the store shows a host key that isn't pinned"
said_case "pigeonhole-jump@192.0.2.10: Permission denied (publickey). SERVER-SAID" jump-refused "the web server (site.json's pigeonhole.jump) refused this site's pull key: is the key in its pigeonhole-jump user's authorized_keys? (offprint pigeonhole print-server web)" "the web server refuses the key"
said_case "ph-example@10.0.0.5: Permission denied (publickey). SERVER-SAID" store-refused "the pigeonhole's server (site.json's pigeonhole.server) refused this site's pull key: is the key in its ph-example user's authorized_keys, and does the connection come from the web server's own address? (offprint pigeonhole print-server store)" "the store refuses the key"
said_case "channel 0: open failed: administratively prohibited: open failed SERVER-SAID
stdio forwarding failed" jump-forward "wouldn't open a connection on to the pigeonhole's server: its authorized_keys line must permit exactly that address and port" "the web server won't forward to the store"
said_case "stdio forwarding failed SERVER-SAID" jump-forward "wouldn't open a connection on to the pigeonhole's server: its authorized_keys line must permit exactly that address and port" "the web server won't forward (as ssh says it with its messages turned down)"
said_case "$(printf 'SERVER-SAID \033[31m anything at all')" unreachable "couldn't be reached over ssh" "ssh says something unknown"

# No message names an address: the agent logs these lines in var/, which WordPress can read.
newcase; held; echo "ssh: connect to host 192.0.2.10 port 22: Operation timed out" > "$S/ssh_says"; collect --fetch-only
lacks "a fetch's failure names no address of either server (the jump's)" "192.0.2.10" "$out"
lacks "... (the store's)" "10.0.0.5" "$out"
# The far command's own failure is never read as ssh's: a store can't point the owner at the web server.
newcase; held; printf '%s\n' "No ED25519 host key is known for offprint-jump and you have requested strict checking." "Host key verification failed." "pigeonhole-jump@192.0.2.10: Permission denied (publickey)." > "$S/remote_says"; collect --fetch-only; t="the store's command fails, printing ssh's own words about the web server"
check "$t: exits 1" 1 "$code"
check "$t: said to be the store's command, not the web server's key" "problem: The fetch: the pigeonhole's server was reached, but its pull command failed. Is it the one this Offprint prints? (offprint pigeonhole print-server store)" "$out"
has "$t: the status's one word" '"reason":"store-answer"' "$(fstatus)"
clean "$t"
# A server that holds the right key and never finishes.
newcase; held; touch "$S/ssh_hangs"; t="the store never answers"; start=$SECONDS
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" OFFPRINT_PIGEONHOLE_SSH_SECONDS=1 HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/collect" --fetch-only 2>&1 < /dev/null)"; code=$?
check "$t: exits 1" 1 "$code"
check "$t: cut off, and said" "problem: The fetch: the pigeonhole's server took longer than 1 seconds to answer, so it was cut off. offprint pigeonhole doctor checks each step." "$out"
if [ $((SECONDS - start)) -lt 15 ]; then ok "$t: within its time, not the server's ($((SECONDS - start)) seconds)"; else bad "$t: took $((SECONDS - start)) seconds"; fi
has "$t: the status's one word" '"reason":"slow"' "$(fstatus)"
clean "$t"
for bad_limit in 0 600 abc -1 ""; do
  newcase; held
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" OFFPRINT_PIGEONHOLE_SSH_SECONDS="$bad_limit" OFFPRINT_PIGEONHOLE_FETCH_SECONDS=99999 HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/collect" --fetch-only 2>&1 < /dev/null)"; code=$?
  check "a limit of \"$bad_limit\" from the environment (it can only shorten): ignored, and the fetch works" "0 1" "$code $(count "$SP")"
done
newcase; held; held; held; t="a fetch that runs out of its time"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" OFFPRINT_PIGEONHOLE_FETCH_SECONDS=1 HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/collect" --fetch-only 2>&1 < /dev/null)"; code=$?
check "$t: nothing is lost: what wasn't taken is on the store still" 3 "$(( $(count "$SP") + $(count "$R") ))"
newcase; held; touch "$S/ssh_floods"; collect --fetch-only; t="ssh fails with 400 KB of words"
check "$t: exits 1" 1 "$code"
check "$t: no more of it reached the Mac's disk than a few kilobytes" "" "$(find "$tmp/case$n" "$TMPDIR" -name ssh.err -size +64k 2>/dev/null)"
lacks "$t: and none of it is shown" "xxxxxxxx" "$out"

newcase; held; touch "$S/outside"
printf '%s\n' "$blob" "../../outside" > "$S/list_says"; collect --fetch-only; t="a list with a line that is no name"
check "$t: exits 1" 1 "$code"
has "$t: says it is not the pull command answering" "problem: The fetch: what the pigeonhole's server answered is not a list of submissions, so nothing was fetched." "$out"
check "$t: nothing at all was asked for after the list, not even the good name" "list" "$(awk '{print $6}' "$S/ssh.calls" | tr '\n' ' ' | sed 's/ $//')"
has "$t: the status's one word" '"reason":"not-a-list"' "$(fstatus)"
for junk in 'Welcome to Ubuntu' "$(printf 'a%.0s' $(seq 1 64)).age extra" "$(printf 'A%.0s' $(seq 1 64)).age" '$(touch pwned).age' "-oProxyCommand=x" "$(printf 'a%.0s' $(seq 1 64)).age/.."; do
  newcase; printf '%s\n' "$junk" > "$S/list_says"; collect --fetch-only
  check "a list that is \"$(printf '%s' "$junk" | cut -c1-24)\": refused, and only the list was asked for" "1 list" "$code $(awk '{print $6}' "$S/ssh.calls" | tr '\n' ' ' | sed 's/ $//')"
done
newcase; i=0; while [ "$i" -lt 501 ]; do printf '%064x.age\n' "$i"; i=$((i + 1)); done > "$S/list_says"; collect --fetch-only; t="a list of 501 names"
check "$t: refused: the pull command gives 500 at most" "1 list" "$code $(awk '{print $6}' "$S/ssh.calls" | sort -u | tr '\n' ' ' | sed 's/ $//')"

# ---- a file that is not what its name says ----------------------------------------------------------------------------
newcase; held; good="$blob"; held; wrong="$blob"; echo "other bytes" > "$S/get_as.$wrong"; collect --fetch-only; t="a file whose bytes don't hash to its name"
check "$t: exits 1" 1 "$code"
check "$t: says so" "problem: Fetched 1 submission from the pigeonhole. The fetch: 1 file on the pigeonhole's server is not what its name says and was left there." "$out"
check "$t: only the good one is in the spool" "$good" "$(ls "$SP")"
check "$t: the wrong one is left on the store, and the good one removed" "$wrong" "$(ls "$R")"
check "$t: no delete was asked for it" 0 "$(calls "$S/ssh.calls" "delete $wrong")"
check "$t: the status counts it" '{"ok":false,"fetched":1,"damaged":1,"left":0,"waiting":1,"reason":""}' "$(fstatus)"
clean "$t"
newcase; held; head -c 20000 /dev/zero > "$S/get_as.$blob"; collect --fetch-only; t="a file larger than a submission can be"
check "$t: not kept, and left on the store" "1 0 1" "$code $(count "$SP") $(count "$R")"
check "$t: no more of it was ever on this Mac's disk than a submission's size and a byte" "" "$(find "$H" -size +17k 2>/dev/null)"
newcase; held; : > "$S/get_as.$blob"; collect --fetch-only; t="a file that comes back empty"
check "$t: not kept, and left on the store" "1 0 1" "$code $(count "$SP") $(count "$R")"

# ---- cut short, and tried again ------------------------------------------------------------------------------------------
newcase; held; mkdir -p "$SP" "$B/done"; chmod 700 "$H/pigeonhole" "$B" "$SP" "$B/done"; cp "$R/$blob" "$SP/$blob"; inspool="$blob"
held; cp "$R/$blob" "$B/done/$blob"; held; fresh="$blob"
collect --fetch-only; t="the store still holds what the Mac already has (a fetch was cut short)"
check "$t: exits 0" 0 "$code"
check "$t: only the new one counts as fetched" "ok: Fetched 1 submission from the pigeonhole. 2 are waiting to be opened (offprint collect)." "$out"
check "$t: the store's copies are removed" 0 "$(count "$R")"
check "$t: the ones held were not fetched again" "0" "$(calls "$S/ssh.calls" "get $inspool")"
clean "$t"

newcase; held; a="$blob"; held; b="$blob"; touch "$S/get_fails.$a"; collect --fetch-only; t="one file can't be fetched"
check "$t: exits 1" 1 "$code"
check "$t: says so; the other is fetched" "problem: Fetched 1 submission from the pigeonhole. The fetch: 1 submission couldn't be fetched or removed this time; the next fetch tries again." "$out"
check "$t: the one that failed is still on the store, and only there" "$a|$b" "$(ls "$R")|$(ls "$SP")"
clean "$t"
rm -f "$S/get_fails.$a" "$S/agent.ended"; collect --fetch-only
check "$t, then again: it is fetched" "0 2 0" "$code $(count "$SP") $(count "$R")"

newcase; held; held; held; touch "$S/get_fails"; collect --fetch-only; t="every get fails"
check "$t: exits 1" 1 "$code"
check "$t: it stops after two: the connection is the trouble" 2 "$(calls "$S/ssh.calls" ' get ')"
has "$t: says the store couldn't be reached" "couldn't be reached over ssh" "$out"
check "$t: nothing is lost" "0 3" "$(count "$SP") $(count "$R")"
clean "$t"

newcase; held; touch "$S/delete_fails"; collect --fetch-only; t="the delete fails after the file is kept"
check "$t: exits 0: it is held here, whole" 0 "$code"
check "$t: in both places: a duplicate, never a loss" "1 1" "$(count "$SP") $(count "$R")"
rm -f "$S/delete_fails" "$S/agent.ended"; collect --fetch-only
check "$t, then again: the store's copy is removed, and nothing is fetched twice" "0 1 0" "$code $(count "$SP") $(count "$R")"
has "$t, then again: says nothing new came" "ok: Nothing new on the pigeonhole. 1 is waiting" "$out"

newcase; held; mkdir -p "$SP"; chmod 700 "$H/pigeonhole" "$B" "$SP"; echo half > "$SP/.incoming-$blob"; echo half > "$SP/.incoming-old"
collect --fetch-only; t="half-fetched files left by a run that was killed"
check "$t: exits 0" 0 "$code"
check "$t: they are removed, and the real one fetched whole" "$blob" "$(ls -A "$SP")"

# ---- the pull key ------------------------------------------------------------------------------------------------------
key_case() {  # NAME TEXT REASON
  collect --fetch-only
  check "$1: exits 1" 1 "$code"
  check "$1: says so" "problem: The fetch: $2" "$out"
  has "$1: the status's one word" "\"reason\":\"$3\"" "$(fstatus)"
  check "$1: ssh never ran" 0 "$(calls "$S/ssh.calls" .)"
  check "$1: nothing was fetched" "0 1" "$(count "$SP") $(count "$R")"
  clean "$1"
}
newcase; held; rm "$S/keychain/pigeonhole-pull"
key_case "no pull key in the Keychain" "this site's pull key isn't in the login Keychain (the secret pigeonhole-pull); offprint pigeonhole keys makes it." no-key
newcase; held; touch "$S/secret_locked"
key_case "the Keychain is locked" "the login Keychain is locked, so the pull key couldn't be read; unlock it, then try again." locked
newcase; held; printf 'not-a-key' > "$S/keychain/pigeonhole-pull"
key_case "the Keychain holds something that is not a pull key" "what the login Keychain holds as this site's pull key (the secret pigeonhole-pull) is not one; offprint pigeonhole keys makes it." bad-key
check "... and ssh-add was handed nothing of it" "0 bytes" "$(sed -n 's/.* | \([0-9]* bytes\) on standard input/\1/p' "$S/sshadd.calls")"
newcase; held; touch "$S/sshadd_fails"
key_case "ssh-add refuses the key" "ssh-add didn't take this site's pull key, so nothing was fetched." bad-key
newcase; held; touch "$S/agent_fails"; collect --fetch-only; t="ssh-agent doesn't start"
check "$t: exits 1" 1 "$code"
has "$t: says so" "problem: The fetch: ssh-agent didn't start for this run" "$out"
check "$t: the Keychain was never asked for the key" 0 "$(calls "$S/security.calls" .)"
check "$t: ssh never ran" 0 "$(calls "$S/ssh.calls" .)"
newcase; held; rm "$S/bin/ssh-add"; t="no ssh-add on the PATH"
out="$(cd "$tmp/case$n" && PATH="$S/bin:/nonexistent" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/collect" --fetch-only 2>&1 < /dev/null)"; code=$?
if command -v ssh-add > /dev/null 2>&1 && [ "$code" != 1 ]; then :; fi
case "$out" in *"isn't on the PATH"*|*"php isn't on the PATH"*) ok "$t: said, and nothing fetched" ;; *) bad "$t ($code: $out)" ;; esac

# ---- the key stays out of sight under tracing -----------------------------------------------------------------------------
newcase; held; t="traced with bash -x"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash -x "$SRC/bin/collect" --fetch-only 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
lacks "$t: the pull key is not in the trace" "$PULLMARK" "$out"
lacks "$t: nor as the Keychain holds it" "$PULL_LINE" "$out"
newcase; held; t="tracing and allexport inherited through SHELLOPTS"
out="$(cd "$tmp/case$n" && env PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" SHELLOPTS=xtrace:allexport /bin/bash "$SRC/bin/collect" --fetch-only 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
lacks "$t: the pull key is not in the trace" "$PULLMARK" "$out"
lacks "$t: nor as the Keychain holds it" "$PULL_LINE" "$out"
newcase; held; t="the owner's own ssh-agent is in the environment"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" SSH_AUTH_SOCK="$tmp/case$n/owners.sock" SSH_AGENT_PID=1 OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/collect" --fetch-only 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
check "$t: ssh is never given it" "unset" "$(sort -u "$S/ssh.env")"
lacks "$t: nor is ssh-add" "owners.sock" "$(cat "$S/sshadd.calls")"

# ---- the spool's lock --------------------------------------------------------------------------------------------------
newcase; held; mkdir -p "$B/lock"; chmod 700 "$H/pigeonhole" "$B"; echo "$$" > "$B/lock/pid"; collect --fetch-only; t="another run holds the spool's lock"
check "$t: exits 75" 75 "$code"
check "$t: says so" "problem: another fetch or collection is running for this site; wait for it, then try again." "$out"
check "$t: the lock is left as it was" "$$" "$(cat "$B/lock/pid")"
check "$t: nothing was fetched" "0 1" "$(count "$SP") $(count "$R")"
collect; check "$t, a collection: exits 75 too" 75 "$code"
check "$t, a collection: and gives the publish's lock back" "" "$(ls -d "$c/var/publish.lock" 2>/dev/null)"
newcase; held; mkdir -p "$B/lock"; chmod 700 "$H/pigeonhole" "$B"; ( : ) & wait $!; echo "$!" > "$B/lock/pid"; collect --fetch-only; t="a lock left by a run that is gone"
check "$t: exits 0: it is taken over" 0 "$code"
check "$t: it fetched" 1 "$(count "$SP")"
check "$t: and the lock is gone" "" "$(ls -d "$B/lock" 2>/dev/null)"
newcase; held; mkdir -p "$B/lock"; chmod 700 "$H/pigeonhole" "$B"; echo "not a pid" > "$B/lock/pid"; collect --fetch-only; t="a new lock whose pid is no number"
check "$t: exits 75: not taken over while it may be a run's" 75 "$code"
newcase; held; mkdir -p "$B/lock"; chmod 700 "$H/pigeonhole" "$B"; collect --fetch-only; t="a new lock with no pid at all (a run just started)"
check "$t: exits 75" 75 "$code"
# Left for ever, such a lock would stop every fetch without a word: no run lasts half an hour.
newcase; held; mkdir -p "$B/lock"; chmod 700 "$H/pigeonhole" "$B"; touch -t 202001010000 "$B/lock"; collect --fetch-only; t="a lock with no pid, from long ago (a run killed as it started)"
check "$t: taken over: exits 0, and it fetched" "0 1" "$code $(count "$SP")"
check "$t: and the lock is gone, with nothing left beside it" "" "$(ls -d "$B"/lock* 2>/dev/null)"
newcase; held; mkdir -p "$B/lock"; chmod 700 "$H/pigeonhole" "$B"; echo "$$" > "$B/lock/pid"; touch -t 202001010000 "$B/lock"; collect --fetch-only; t="a lock from long ago whose pid is some other program's now"
check "$t: taken over" "0 1" "$code $(count "$SP")"
newcase; held; mkdir -p "$B"; chmod 700 "$H/pigeonhole" "$B"; ln -s "$tmp/case$n/make" "$B/lock"; collect --fetch-only; t="a lock that is a link"
check "$t: never taken over, and what it leads to is left" "75 yes" "$code $([ -d "$tmp/case$n/make" ] && echo yes)"

# ---- the notification ----------------------------------------------------------------------------------------------------
newcase; held; held; collect --fetch-only --notify; t="--notify, two fetched"
check "$t: exits 0" 0 "$code"
check "$t: one notification: the count and the site's name, nothing else" '-e display notification "2 comments are waiting to be checked" with title "Offprint: example"' "$(cat "$S/osascript.calls")"
lacks "$t: not a word of a comment" "$MARK" "$(cat "$S/osascript.calls")"
rm -f "$S/osascript.calls"; held; collect --fetch-only --notify; t="--notify, one more fetched while two wait"
check "$t: the count is what waits now" '-e display notification "3 comments are waiting to be checked" with title "Offprint: example"' "$(cat "$S/osascript.calls")"
rm -f "$S/osascript.calls"; collect --fetch-only --notify; t="--notify, nothing new"
check "$t: no notification, though three still wait" 0 "$(calls "$S/osascript.calls" .)"
newcase; held; collect --fetch-only --notify; t="--notify, one fetched"
check "$t: one comment is" '-e display notification "1 comment is waiting to be checked" with title "Offprint: example"' "$(cat "$S/osascript.calls")"
newcase; held; echo "ssh: connect to host 192.0.2.10 port 22: Operation timed out" > "$S/ssh_says"; collect --fetch-only --notify; t="--notify, the fetch fails"
check "$t: no notification" 0 "$(calls "$S/osascript.calls" .)"
newcase; held; cp "$S/bin/osascript" "$c/wp-content/osascript"; t="an osascript in the site folder"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" OFFPRINT_OSASCRIPT="$c/wp-content/osascript" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/collect" --fetch-only --notify 2>&1 < /dev/null)"; code=$?
check "$t: the fetch works" "0 1" "$code $(count "$SP")"
check "$t: it is never run" 0 "$(calls "$S/osascript.calls" .)"

# ---- usage -------------------------------------------------------------------------------------------------------------
for args in "--notify" "--fetch-only --no-fetch" "--no-fetch --notify" "--fetch" "--fetch-only extra"; do
  newcase; held
  # shellcheck disable=SC2086 # the words of the case
  collect $args
  check "collect $args: exits 2, with the usage line" "2 usage: offprint collect [--no-fetch | --fetch-only [--notify]]" "$code $out"
  check "collect $args: nothing ran" "0" "$(calls "$S/ssh.calls" .)"
done

[ "$fail" -eq 0 ]
