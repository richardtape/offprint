#!/usr/bin/env bash
# Tests bin/pigeonhole (offprint pigeonhole keys | print-server | doctor): the two keys made in the Keychain and never
# shown; what is printed for the two servers; and the doctor's check of the whole path, with a test submission.
# Hermetic: a throwaway site folder (a git repository, for its own adapter), an Offprint folder of the case's own, and
# stand-ins first on the PATH or named by a seam (tests/fixtures/pigeonhole-standins.sh, tests/fixtures/age-standin,
# and a curl here that answers as the web server and the store do). Nothing here reaches a network, a server, a real
# agent or the Keychain. tests/rehearsal.sh runs the same commands against real ones in Docker.
# Run: bash tests/pigeonhole.test.sh. Works on macOS (bash 3.2) and Linux.
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE OFFPRINT_HOME OFFPRINT_SECURITY PIGEONHOLE_CHECK_ORIGIN SSH_AUTH_SOCK SSH_AGENT_PID
. "$SRC/tests/fixtures/pigeonhole-standins.sh"
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-pigeonhole-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd -P "$tmp" && pwd -P)"
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 ('$2' is not in: $3)"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' is in the output)"; else ok "$1"; fi; }
calls() { if [ -f "$1" ]; then grep -c -- "$2" "$1"; else echo 0; fi; }

DAILY=AGE-SECRET-KEY-1TEST          # what the stand-in age opens with
DAILY_PUB="age1$(printf 'q%.0s' $(seq 1 58))"
P62="age1$(printf 'p%.0s' $(seq 1 58))"
MADE="AGE-SECRET-KEY-1$(printf 'K%.0s' $(seq 1 58))"   # what the stand-in age-keygen makes
MADE_PUB="age1$(printf 'k%.0s' $(seq 1 58))"
HK1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'A%.0s' $(seq 1 43))"
HK2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'B%.0s' $(seq 1 43))"
SERVER=",\"server\":\"10.0.0.5\",\"server_host_key\":\"$HK1\",\"jump\":\"192.0.2.10\",\"jump_host_key\":\"$HK2\""
SITE_HEAD='{"format":1,"name":"example","public_url":"https://www.example.com","local_host":"mysite.test","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998'

n=0
# newcase [PIGEONHOLE-BLOCK-INSIDES | none] [ADAPTER]: a site folder $c (its adapter "takes", which says its host
# takes comments, unless ADAPTER is given), the stand-ins in $S, an empty Keychain
newcase() {
  n=$((n + 1)); c="$tmp/case$n/site"; S="$tmp/case$n/stubs"; H="$tmp/case$n/ohome"
  B="$H/pigeonhole/example"; SP="$B/spool"; R="$S/remote"
  mkdir -p "$c/wp-content" "$c/var" "$c/adapters/takes" "$c/adapters/files" "$tmp/case$n/home"
  ph_standins "$S"
  cp "$SRC/tests/fixtures/age-standin" "$S/bin/age"; chmod +x "$S/bin/age"
  block="${1-\"path\":\"/_pigeonhole\",\"recipients\":[\"$DAILY_PUB\",\"$P62\"]$SERVER}"
  if [ "$block" = none ]; then block=""; else block=",\"pigeonhole\":{$block}"; fi
  printf '%s%s,"adapter":{"name":"%s"}}\n' "$SITE_HEAD" "$block" "${2:-takes}" > "$c/site.json"
  echo "ADAPTER_PIGEONHOLE=1" > "$c/adapters/takes/adapter.sh"
  echo "ADAPTER_PIGEONHOLE=0" > "$c/adapters/files/adapter.sh"
  ( cd "$c" && git init -q && git add adapters site.json && git -c user.name=t -c user.email=t@example.com commit -q -m site ) || bad "couldn't make the case's repository"
  # curl: the public site. A GET of anything: get_code (404). A POST: post_code (204), and with 204 the body, less
  # its eight bytes of proof, is kept in the store's folder under its hash, as the store keeps one.
  cat > "$S/bin/curl" <<'STUB'
#!/bin/bash
: "${STUB_DIR:?}"
printf '%s\n' "$*" >> "$STUB_DIR/curl.calls"
[ ! -f "$STUB_DIR/curl_down" ] || { echo "curl: (7) Failed to connect" >&2; printf '000'; exit 7; }
case " $* " in
  *" --data-binary @- "*)
    cat > "$STUB_DIR/posted"
    code="$(cat "$STUB_DIR/post_code" 2>/dev/null || echo 204)"
    if [ "$code" = 204 ] && [ ! -f "$STUB_DIR/store_drops" ]; then
      tail -c +9 "$STUB_DIR/posted" > "$STUB_DIR/remote/new"
      mv "$STUB_DIR/remote/new" "$STUB_DIR/remote/$(php -r 'echo hash_file("sha256", $argv[1]);' "$STUB_DIR/remote/new").age"
    fi
    printf '%s' "$code" ;;
  *) printf '%s' "$(cat "$STUB_DIR/get_code" 2>/dev/null || echo 404)" ;;
esac
STUB
  chmod +x "$S/bin/curl"
  printf '%s\n' "$DAILY_PUB" > "$S/agekey.pub.$DAILY"
}
# keys_in: both keys in the stand-in Keychain, as offprint pigeonhole keys leaves them; sets PULL_PUB
keys_in() {
  printf '%s' "$DAILY" > "$S/keychain/pigeonhole-daily"
  exec 4> "$S/pull.pub"; php "$SRC/lib/pigeonhole-keys.php" pull-key 3>&4 | tr -d '\n' > "$S/keychain/pigeonhole-pull"; exec 4>&-
  php "$SRC/lib/pigeonhole-keys.php" decode < "$S/keychain/pigeonhole-pull" > "$S/pullkey.pem"
  PULL_PUB="$(cat "$S/pull.pub")"; PULL_LINE="$(cat "$S/keychain/pigeonhole-pull")"
}
# ph ARGS...: offprint pigeonhole ARGS for the site; sets out, code
ph() {
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" \
    HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/offprint" pigeonhole "$@" 2>&1 < /dev/null)"; code=$?
}
# secret-free NAME: no private key is anywhere it must not be
private() {
  check "$1: no private key is in any file (but the stand-in Keychain, and the stand-ins)" "" \
    "$(grep -rl -e 'AGE-SECRET-KEY' -e 'PRIVATE KEY' -e "${PULL_LINE:-no-pull-line-yet}" "$tmp/case$n" "$TMPDIR" 2>/dev/null | grep -v '/stubs/')"
  check "$1: ... nor in any program's arguments" "" "$(grep -l -e 'AGE-SECRET-KEY' -e 'PRIVATE KEY' -e "${PULL_LINE:-no-pull-line-yet}" "$S"/*.calls 2>/dev/null)"
  lacks "$1: ... nor in what was printed (an age key)" "AGE-SECRET-KEY" "$out"
  lacks "$1: ... (an ssh key)" "PRIVATE KEY" "$out"
  lacks "$1: ... (as the Keychain holds it)" "${PULL_LINE:-no-pull-line-yet}" "$out"
  check "$1: no private folder is left in TMPDIR" "" "$(ls "$TMPDIR" 2>/dev/null)"
}

# ---- usage -------------------------------------------------------------------------------------------------------------
USAGE="usage: offprint pigeonhole keys | doctor | print-server web | print-server store WEB_ADDRESS"
newcase
for args in "" "key" "keys extra" "doctor now" "print-server" "print-server both" "print-server web 10.0.0.2" "print-server store" "print-server store 10.0.0.2 extra"; do
  # shellcheck disable=SC2086 # the words of the case
  ph $args
  check "offprint pigeonhole $args: exits 2, with the usage line" "2 $USAGE" "$code $out"
done
check "... and none of them asked the Keychain anything" 0 "$(calls "$S/security.calls" .)"
has "offprint help lists pigeonhole keys" "  offprint pigeonhole keys " "$(/bin/bash "$SRC/bin/offprint" help)"
has "offprint help lists pigeonhole doctor" "  offprint pigeonhole doctor " "$(/bin/bash "$SRC/bin/offprint" help)"
has "offprint help lists pigeonhole print-server" "  offprint pigeonhole print-server web | store WEB_ADDRESS" "$(/bin/bash "$SRC/bin/offprint" help)"
check "bin/pigeonhole starts #!/bin/bash" "#!/bin/bash" "$(head -n 1 "$SRC/bin/pigeonhole")"

# ---- keys ----------------------------------------------------------------------------------------------------------------
newcase none; ph keys; t="keys, a new site (no pigeonhole block yet)"
check "$t: exits 0" 0 "$code"
has "$t: says the daily key was made" "ok: made this site's daily key, in the login Keychain (the secret pigeonhole-daily)." "$out"
has "$t: prints its public half" "    $MADE_PUB" "$out"
has "$t: says the pull key was made" "ok: made this site's pull key, in the login Keychain (the secret pigeonhole-pull)." "$out"
spub="$(printf '%s\n' "$out" | grep -E '^    ssh-ed25519 ' | sed 's/^    //')"
if [[ "$spub" =~ ^ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$ ]]; then ok "$t: prints the pull key's public half, as an ssh public key"; else bad "$t: pull public half ($spub)"; fi
check "$t: the Keychain holds the daily key age-keygen made" "$MADE" "$(cat "$S/keychain/pigeonhole-daily")"
stored="$(cat "$S/keychain/pigeonhole-pull")"
if [[ "$stored" =~ ^[A-Za-z0-9+/=]+$ ]] && [ "${#stored}" -ge 100 ] && [ "${#stored}" -le 1024 ]; then ok "$t: the Keychain holds the pull key as one line"; else bad "$t: the pull key's line"; fi
check "$t: that line is the key whose public half was printed" "$spub" "$(php "$SRC/lib/pigeonhole-keys.php" public < "$S/keychain/pigeonhole-pull")"
check "$t: each was stored through security -i (its value on standard input), and read back" "2 4" "$(calls "$S/security.calls" '^-i$') $(calls "$S/security.calls" 'find-generic-password')"
has "$t: says where no copy is, and to make a recovery key" "make a recovery key somewhere else" "$out"
has "$t: says what is next" "Next: site.json's \"pigeonhole\" block (docs/reference.md), then offprint pigeonhole print-server." "$out"
PULL_LINE="$(cat "$S/keychain/pigeonhole-pull")"; private "$t"
first_daily="$(cat "$S/keychain/pigeonhole-daily")"; first_pull="$PULL_LINE"
rm -f "$S/security.calls"; ph keys; t="keys, run again"
check "$t: exits 0" 0 "$code"
has "$t: the daily key is left as it is" "ok: this site's daily key is in the login Keychain already (the secret pigeonhole-daily), and was left as it is." "$out"
has "$t: and the pull key" "ok: this site's pull key is in the login Keychain already (the secret pigeonhole-pull), and was left as it is." "$out"
has "$t: the same public halves are printed" "    $MADE_PUB" "$out"
has "$t: (the pull key's)" "    $spub" "$out"
check "$t: nothing was written to the Keychain" "0 $first_daily $first_pull" "$(calls "$S/security.calls" '^-i$') $(cat "$S/keychain/pigeonhole-daily") $(cat "$S/keychain/pigeonhole-pull")"
lacks "$t: no \"Next\" when nothing was made" "Next:" "$out"

newcase none; printf '%s' "$DAILY" > "$S/keychain/pigeonhole-daily"; ph keys; t="keys, only the daily key is there"
check "$t: exits 0" 0 "$code"
has "$t: the daily key is left" "daily key is in the login Keychain already" "$out"
has "$t: the pull key is made" "ok: made this site's pull key" "$out"
check "$t: the daily key is as it was" "$DAILY" "$(cat "$S/keychain/pigeonhole-daily")"

keys_refused() {  # NAME TEXT
  ph keys
  check "$1: exits 1" 1 "$code"
  has "$1: says so" "$2" "$out"
  private "$1"
}
newcase none; touch "$S/secret_locked"
keys_refused "keys, the Keychain is locked" "problem: the login Keychain is locked; unlock it, then run offprint pigeonhole keys again. Nothing was made."
check "... nothing is in the Keychain" "" "$(ls "$S/keychain")"
newcase none; touch "$S/agekeygen_fails"
keys_refused "keys, age-keygen fails" "problem: age-keygen didn't make a key (is it age's own? brew install age). Nothing was made."
check "... nothing is in the Keychain" "" "$(ls "$S/keychain")"
newcase none; printf 'not what age-keygen prints\nAGE-SECRET-KEY-1SHORT\n' > "$S/agekey.out"
keys_refused "keys, age-keygen prints something else" "problem: age-keygen didn't make a key"
check "... nothing is in the Keychain" "" "$(ls "$S/keychain")"
newcase none; touch "$S/set_fails"
keys_refused "keys, the Keychain won't store" "problem: the daily key couldn't be stored in the login Keychain. Nothing was made."
newcase none; printf 'something-else' > "$S/keychain/pigeonhole-daily"
keys_refused "keys, the Keychain holds something else as the daily key" "problem: what the login Keychain holds as this site's daily key (the secret pigeonhole-daily) is not an age private key. It was left as it is"
check "... it is left as it is, and no pull key is made beside it" "something-else" "$(cat "$S/keychain/pigeonhole-daily")$(ls "$S/keychain" | grep pull)"
newcase none; printf '%s' "$DAILY" > "$S/keychain/pigeonhole-daily"; printf 'bm90IGEga2V5' > "$S/keychain/pigeonhole-pull"
keys_refused "keys, the Keychain holds something else as the pull key" "problem: what the login Keychain holds as this site's pull key (the secret pigeonhole-pull) is not one. It was left as it is"
check "... it is left as it is" "bm90IGEga2V5" "$(cat "$S/keychain/pigeonhole-pull")"
newcase none; rm "$S/bin/age-keygen"; t="keys, no age-keygen"
out="$(cd "$tmp/case$n" && PATH="$S/bin:/usr/bin:/bin" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/pigeonhole" keys 2>&1 < /dev/null)"; code=$?
if command -v php > /dev/null 2>&1 && [ -x /usr/bin/php ] || [ -x /bin/php ]; then
  check "$t: says how to get it" "1 problem: age-keygen isn't on the PATH; the daily key is made with it (brew install age)." "$code $out"
else
  case "$out" in *"isn't on the PATH"*) ok "$t: says what is missing" ;; *) bad "$t ($code: $out)" ;; esac
fi
newcase none; t="keys, traced, with allexport inherited"
out="$(cd "$tmp/case$n" && env PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" SHELLOPTS=xtrace:allexport /bin/bash "$SRC/bin/pigeonhole" keys 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
PULL_LINE="$(cat "$S/keychain/pigeonhole-pull")"
lacks "$t: the daily key is not in the trace" "$MADE" "$out"
lacks "$t: nor the pull key" "$PULL_LINE" "$out"
newcase none; t="keys, traced with bash -x"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash -x "$SRC/bin/pigeonhole" keys 2>&1 < /dev/null)"; code=$?
PULL_LINE="$(cat "$S/keychain/pigeonhole-pull")"
lacks "$t: the daily key is not in the trace" "$MADE" "$out"
lacks "$t: nor the pull key" "$PULL_LINE" "$out"
newcase none; t="keys, with a key piped to its standard input by mistake"
out="$(cd "$tmp/case$n" && printf 'STDIN-MARKER\n' | PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/pigeonhole" keys 2>&1)"; code=$?
check "$t: exits 0" 0 "$code"
check "$t: what was piped in is never what is stored" "" "$(grep -l STDIN-MARKER "$S/keychain"/* 2>/dev/null)"

# ---- print-server ----------------------------------------------------------------------------------------------------------
newcase; keys_in; ph print-server web; t="print-server web"; web="$out"
check "$t: exits 0" 0 "$code"
for line in "	@pigeonhole {" "		method POST" "		path /_pigeonhole" "	handle @pigeonhole {" "			max_size 16KB" "		reverse_proxy 10.0.0.5:8788 {" \
    "			request_buffers 16KB" "			header_up X-Pigeonhole-Client {client_ip}" "			header_up -X-Forwarded-For" "			header_up -Cookie" "			header_up -Referer" "			header_up -User-Agent"; do
  if printf '%s\n' "$web" | grep -qxF -- "$line"; then ok "$t: the Caddy lines have \"$(printf '%s' "$line" | tr -d '\t')\""; else bad "$t: no line \"$line\""; fi
done
check "$t: the path is matched once, exactly, and only for POST (no wildcard, no other method)" "1 1 0" "$(printf '%s\n' "$web" | grep -c '^		path ') $(printf '%s\n' "$web" | grep -c '^		method ') $(printf '%s\n' "$web" | grep -c 'path.*\*')"
has "$t: the jump user's key may only open a connection to the store's ssh" "'restrict,port-forwarding,permitopen=\"10.0.0.5:22\",permitlisten=\"127.0.0.1:1\",command=\"/usr/sbin/nologin\" $PULL_PUB offprint-pigeonhole-example'" "$web"
has "$t: the user has no shell" "--shell /usr/sbin/nologin pigeonhole-jump" "$web"
has "$t: an earlier line for this site is taken out before the new one goes in" "sed -i '/ offprint-pigeonhole-example\$/d' /var/lib/pigeonhole-jump/.ssh/authorized_keys" "$web"
for line in "			header_up -Authorization" "			header_up -Accept-Language" "			header_up -Sec-*" "			header_up -X-Real-IP"; do
  if printf '%s\n' "$web" | grep -qxF -- "$line"; then ok "$t: the Caddy lines have \"$(printf '%s' "$line" | tr -d '\t')\""; else bad "$t: no line \"$line\""; fi
done
has "$t: ... and no password, which is not a locked account" "usermod -p '*' pigeonhole-jump" "$web"
has "$t: its folder is root's" "install -d -m 755 -o root -g root /var/lib/pigeonhole-jump /var/lib/pigeonhole-jump/.ssh" "$web"
for line in "Match User pigeonhole-jump" "	AllowTcpForwarding local" "	AllowStreamLocalForwarding no" "	PermitListen none" "	PermitTTY no" "Match all"; do
  if printf '%s\n' "$web" | grep -qxF -- "$line"; then ok "$t: sshd's rule for the jump user has \"$(printf '%s' "$line" | tr -d '\t')\""; else bad "$t: no line \"$line\""; fi
done
# The owner pastes these lines as root, with no set -e: a line that fails stops nothing after it. An sshd told to read
# a configuration it can't read exits, and nobody can log in to a server that serves other sites too. So sshd is
# reloaded only by the line that asked sshd -t first, and never by a signal (which asks nothing).
lacks "$t: sshd is never sent a signal to re-read its configuration" "kill" "$web"
lacks "$t: ... and its pid file is never read" "sshd.pid" "$web"
check "$t: sshd -t is on no line of its own, where failing would stop nothing" 0 "$(printf '%s\n' "$web" | grep -cx 'sshd -t')"
check "$t: every line that reloads sshd asks sshd -t first, on that line" "1 0" "$(printf '%s\n' "$web" | grep -v '^#' | grep -c '^if sshd -t; then .*reload') $(printf '%s\n' "$web" | grep -v '^#' | grep 'reload\|restart' | grep -vc '^if sshd -t; then ')"
has "$t: the comment beside it says what to do when sshd -t refuses" "remove the file just written" "$web"
# That line, run as it would be pasted (no set -e), with stand-ins for sshd, systemctl and kill.
reload_line="$(printf '%s\n' "$web" | grep '^if sshd -t; then ')"
mkdir "$tmp/case$n/sshd"
for prog in sshd systemctl kill; do
  cat > "$tmp/case$n/sshd/$prog" <<'STUB'
#!/bin/bash
me="${0##*/}"
printf '%s\n' "$me $*" >> "$CALLS"
[ ! -f "$FAILS/$me" ] && [ ! -f "$FAILS/$me $*" ]
STUB
  chmod +x "$tmp/case$n/sshd/$prog"
done
# reload_run NAME [WHAT FAILS...]: runs the line; sets out, code and called (what was run, on one line)
reload_run() {
  local d="$tmp/case$n/sshd/$1"; shift
  mkdir -p "$d/fails"; : > "$d/calls"; while [ $# -gt 0 ]; do : > "$d/fails/$1"; shift; done
  out="$(printf '%s\necho after\n' "$reload_line" | PATH="$tmp/case$n/sshd:/usr/bin:/bin" CALLS="$d/calls" FAILS="$d/fails" /bin/bash 2>&1)"; code=$?
  called="$(paste -sd'|' - < "$d/calls")"
}
reload_run good
check "$t: sshd -t passing, sshd is reloaded, once" "sshd -t|systemctl reload ssh" "$called"
check "$t: ... and nothing is said" "after" "$out"
reload_run other "systemctl reload ssh"
check "$t: where the unit is sshd, that one is reloaded" "sshd -t|systemctl reload ssh|systemctl reload sshd" "$called"
reload_run refused sshd
check "$t: sshd -t refusing, nothing is reloaded and nothing signalled" "sshd -t" "$called"
has "$t: ... it says sshd was not reloaded" "sshd was NOT reloaded" "$out"
has "$t: ... and to remove the file just written, by its name" "rm /etc/ssh/sshd_config.d/offprint-pigeonhole-jump.conf" "$out"
check "$t: ... and the lines pasted after it still run (it stops no shell)" "after" "$(printf '%s\n' "$out" | tail -n 1)"
check "$t: ... the file it names is the one the commands wrote" 1 "$(printf '%s\n' "$web" | grep -c "^cat > /etc/ssh/sshd_config.d/offprint-pigeonhole-jump.conf <<'SSHD'\$")"
# {client_ip} behind a proxy: by default Caddy takes the first address in X-Forwarded-For, which a visitor writes.
has "$t: the Caddy note names the option for the header the proxy itself sets" "client_ip_headers" "$web"
has "$t: ... and the strict reading of X-Forwarded-For" "trusted_proxies_strict" "$web"
has "$t: ... beside trusted_proxies" "(trusted_proxies)" "$web"
has "$t: ... and says a visitor chooses the first address of X-Forwarded-For" "the first address in X-Forwarded-For, which is whatever a visitor wrote" "$web"
check "$t: sshd's rule ends by matching everyone again, so nothing after it is this user's alone" "Match all" "$(printf '%s\n' "$web" | sed -n '/^Match User/,/^SSHD$/p' | sed '$d' | tail -n 1)"
lacks "$t: no sudo is printed" "sudo" "$web"
has "$t: says nothing was run" "Nothing here has been run" "$web"
check "$t: ssh never ran, nor curl" "0 0" "$(calls "$S/ssh.calls" .) $(calls "$S/curl.calls" .)"
private "$t"

newcase "\"path\":\"/drop\",\"recipients\":[\"$DAILY_PUB\"],\"server\":\"fd00::5\",\"server_host_key\":\"$HK1\",\"jump\":\"2001:db8::10\",\"jump_host_key\":\"$HK2\",\"server_port\":2222,\"store_port\":9000"
keys_in; ph print-server web; t="print-server web, IPv6 and its own ports"
has "$t: the store's address is in brackets before its port" "		reverse_proxy [fd00::5]:9000 {" "$out"
has "$t: and in the key's one permitted address" "permitopen=\"[fd00::5]:2222\",permitlisten=" "$out"
has "$t: the path is the site's" "		path /drop" "$out"

newcase; keys_in; ph print-server store 10.0.0.2; t="print-server store"; script="$out"
check "$t: exits 0" 0 "$code"
check "$t: it is a script" "#!/bin/bash" "$(printf '%s\n' "$script" | head -n 1)"
for line in "PH_SITE='example'" "PH_PATH='/_pigeonhole'" "PH_LISTEN='10.0.0.5:8788'" "PH_KEY='$PULL_PUB'" "PH_WEB='10.0.0.2'" "PH_SSH_PORT='22'"; do
  if printf '%s\n' "$script" | grep -qxF -- "$line"; then ok "$t: it sets $line"; else bad "$t: no line $line"; fi
done
printf '%s\n' "$script" > "$tmp/case$n/setup-printed.sh"
check "$t: bash can read it" "" "$(bash -n "$tmp/case$n/setup-printed.sh" 2>&1)"
# the two programs inside it are the tool's own, byte for byte
( cd "$tmp/case$n" && sed -n '/^write_store_js() {$/,/^OFFPRINT_PIGEONHOLE_END$/p' setup-printed.sh | sed '1,2d;$d' > store.out
  sed -n '/^write_pull_js() {$/,/^OFFPRINT_PIGEONHOLE_END$/p' setup-printed.sh | sed '1,2d;$d' > pull.out )
check "$t: store.js is in it, byte for byte" "" "$(cmp "$tmp/case$n/store.out" "$SRC/pigeonhole/server/store.js" 2>&1)"
check "$t: pull.js is in it, byte for byte" "" "$(cmp "$tmp/case$n/pull.out" "$SRC/pigeonhole/server/pull.js" 2>&1)"
check "$t: it ends with the tool's set-up, byte for byte" "" "$(tail -n "$(wc -l < "$SRC/pigeonhole/server/setup.sh" | tr -d ' ')" "$tmp/case$n/setup-printed.sh" | cmp - "$SRC/pigeonhole/server/setup.sh" 2>&1)"
has "$t: the pull key is tied to the pull command, from the web server's address, and to nothing else" 'restrict,from="$PH_WEB",command="$NODE /opt/pigeonhole/pull.js $STORE_DIR" $PH_KEY offprint-pigeonhole-$PH_SITE' "$script"
has "$t: the store may speak with the web server alone" 'IPAddressAllow=$PH_WEB' "$script"
has "$t: the unit shuts it in" "ProtectSystem=strict" "$script"
has "$t: (no new privileges)" "NoNewPrivileges=yes" "$script"
has "$t: the firewall lines are printed, never run" 'echo "  ufw default deny incoming"' "$script"
check "$t: no ufw, iptables or nft is run by it" "" "$(printf '%s\n' "$script" | grep -E '^[[:space:]]*(ufw|iptables|nft) ')"
lacks "$t: no sudo is in it" "sudo " "$script"
# The unit's filter (@system-service) kills a program at the first call outside it, and node's engine asks for a
# memory protection key as it starts (pkey_alloc), which that list leaves out: on the first real machine the store
# died at every start (signal SYS), five seconds apart. The three pkey calls touch the program's own memory alone.
has "$t: the unit lets node ask for a memory protection key (it dies at once without)" "SystemCallFilter=pkey_alloc pkey_mprotect pkey_free" "$script"
# And the set-up called that store "running": a unit that dies at once is active again each time systemd starts it
# again, and the one look came two seconds after the start. So the look is at the process: the same one, still there
# after longer than systemd waits before starting it again. Run here as printed, with a stand-in systemctl and sleep.
( cd "$tmp/case$n" && mkdir -p su && sed -n '/^start_store() {$/,/^}$/p' setup-printed.sh > su/start.sh
  printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$SU/systemctl.calls"' 'case "$*" in' \
    '  *"-p MainPID"*) k="$(cat "$SU/k" 2> /dev/null || echo 0)"; k=$((k + 1)); echo "$k" > "$SU/k"; sed -n "${k}p" "$SU/pids" ;;' \
    '  is-active*) [ -f "$SU/active" ] ;;' 'esac' > su/systemctl
  printf '%s\n' '#!/bin/bash' 'echo "$1" >> "$SU/sleep.calls"' > su/sleep
  chmod 755 su/systemctl su/sleep )
start_store() {  # start_store PID_AT_FIRST PID_LATER active|inactive
  rm -f "$tmp/case$n/su/k" "$tmp/case$n/su/active" "$tmp/case$n/su/systemctl.calls" "$tmp/case$n/su/sleep.calls"
  printf '%s\n' "$1" "$2" > "$tmp/case$n/su/pids"; [ "$3" != active ] || : > "$tmp/case$n/su/active"
  out="$(cd "$tmp/case$n/su" && SU="$tmp/case$n/su" PATH="$tmp/case$n/su:/usr/bin:/bin" /bin/bash -c 'set -eu; PH_SITE=example PH_PATH=/_pigeonhole PH_LISTEN=10.0.0.5:8788; die() { echo "pigeonhole set-up: $1" >&2; exit 1; }; . ./start.sh; start_store' 2>&1)"; code=$?
}
check "$t: the start is a part of its own (start_store)" "start_store() {" "$(head -n 1 "$tmp/case$n/su/start.sh")"
start_store 4001 4001 active
check "$t, a store that stays up: exits 0" 0 "$code"
has "$t, a store that stays up: called running" "The store is running: pigeonhole@example, taking /_pigeonhole on 10.0.0.5:8788." "$out"
has "$t, a store that stays up: it was enabled and started" "enable pigeonhole@example.service" "$(cat "$tmp/case$n/su/systemctl.calls")"
wait_s="$(tail -n 1 "$tmp/case$n/su/sleep.calls")"; again_s="$(printf '%s\n' "$script" | sed -n 's/^RestartSec=\([0-9][0-9]*\)$/\1/p')"
if [ -n "$again_s" ] && [ "${wait_s:-0}" -gt "$again_s" ]; then ok "$t: the second look comes later than systemd starts a dead store again (${wait_s}s, ${again_s}s)"; else bad "$t: the second look ('$wait_s's) is no later than RestartSec ('$again_s's)"; fi
start_store 4001 4002 active
check "$t, a store started again meanwhile (it died): exits 1" 1 "$code"
has "$t, a store started again meanwhile: says so" "pigeonhole set-up: the store didn't stay up" "$out"
has "$t, a store started again meanwhile: says where the reason is" "journalctl -u pigeonhole@example" "$out"
lacks "$t, a store started again meanwhile: never called running" "The store is running" "$out"
start_store 0 0 active
check "$t, a store with no process: exits 1" 1 "$code"
lacks "$t, a store with no process: never called running" "The store is running" "$out"
start_store 4001 4001 inactive
check "$t, a store systemd calls stopped: exits 1" 1 "$code"
lacks "$t, a store systemd calls stopped: never called running" "The store is running" "$out"
check "$t: ssh never ran, nor curl" "0 0" "$(calls "$S/ssh.calls" .) $(calls "$S/curl.calls" .)"
private "$t"
for a in "store.example.com" "10.0.0" "10.0.0.02" "10.0.0.2;id" '$(id)' "10.0.0.2 x" "" "FD00::2"; do
  ph print-server store "$a"
  check "print-server store \"$a\": refused, and no script printed" "1 0" "$code $(printf '%s\n' "$out" | grep -c 'PH_SITE')"
done
ph print-server store 10.0.0.5
check "print-server store, the store's own address: refused" "1 problem: that is the store's own address (site.json's pigeonhole.server); the one wanted is the web server's, on the same private network." "$code $out"

newcase; ph print-server web; t="print-server, no pull key yet"
check "$t: says to make it" "1 problem: this site's pull key isn't in the login Keychain yet; offprint pigeonhole keys makes it." "$code $out"
newcase "\"path\":\"/_pigeonhole\",\"recipients\":[\"$DAILY_PUB\"]"; keys_in; ph print-server web; t="print-server, a block that names no server"
check "$t: exits 1" 1 "$code"
has "$t: says what is needed" "problem: site.json's \"pigeonhole\" block names no server yet" "$out"
newcase none; keys_in; ph print-server store 10.0.0.2; t="print-server, no pigeonhole block"
check "$t: says so" "1 problem: site.json has no \"pigeonhole\" block, so there is nothing to set a server up for (docs/reference.md)." "$code $out"
newcase; keys_in; touch "$S/secret_locked"; ph print-server web; t="print-server, the Keychain is locked"
check "$t: says so" "1 problem: the login Keychain is locked, so the pull key's public half couldn't be read; unlock it, then try again." "$code $out"
newcase; keys_in; sed -i.bak 's/"name":"example"/"name":"a-name-that-is-thirty-chars-xx"/' "$c/site.json"; t="print-server, a site name too long for a user's name"
mv "$S/keychain/pigeonhole-pull" "$S/pullheld"; ph print-server store 10.0.0.2
has "$t: refused before anything is read" "problem: this site's name is over 29 characters" "$out"

# ---- doctor ----------------------------------------------------------------------------------------------------------------
newcase; keys_in; ph doctor; t="doctor, everything right"
check "$t: exits 0" 0 "$code"
check "$t: every line is ok" "" "$(printf '%s\n' "$out" | grep -v '^ok: ')"
check "$t: the lines, in order" "ok: site.json has a pigeonhole block: comments are posted to https://www.example.com/_pigeonhole.
ok: it names its server: the store at 10.0.0.5, reached through the web server at 192.0.2.10.
ok: comments are encrypted to two keys: the daily key and a recovery key.
ok: the site's adapter (takes) says its host forwards the path.
ok: php, age, age-keygen, ssh, ssh-agent, ssh-add and curl are on the PATH.
ok: the daily key is in the login Keychain, and is one of the keys comments are encrypted to.
ok: the pull key is in the login Keychain, and this run's own ssh-agent took it.
ok: ssh reached the web server and, through it, the pigeonhole's server; each showed the host key site.json pins, and the pull command answered (0 held there now).
ok: the public site refuses a GET of the path (404): only a POST is passed on.
ok: a test submission was posted through the public site, and the store kept it (204).
ok: it was fetched to this Mac, and removed from the store.
ok: the daily key opened it: a comment sent now would reach this Mac, and only this Mac can read it." "$out"
check "$t: what was posted is a submission to two recipients, with its eight bytes of proof" 8498 "$(wc -c < "$S/posted" | tr -d ' ')"
check "$t: ... whose proof of work is 18 bits, as the store asks" yes "$(php -r '$b = file_get_contents($argv[1]); $h = hash("sha256", hash("sha256", substr($b, 8), true) . substr($b, 0, 8), true); echo ord($h[0]) === 0 && ord($h[1]) === 0 && (ord($h[2]) & 0xc0) === 0 ? "yes" : "no";' "$S/posted")"
has "$t: posted as a browser posts: to the path, no content type" "-X POST -H Content-Type: -H Expect: --data-binary @- https://www.example.com/_pigeonhole" "$(cat "$S/curl.calls")"
check "$t: the canary is in done/, and nothing waits" "1 0 0" "$(ls "$B/done" | grep -c .) $(ls "$SP" | grep -c .) $(ls "$R" | grep -c .)"
check "$t: the canary's words are in no file but the sealed ones" "" "$(grep -rl '"kind":"canary"' "$tmp/case$n" "$TMPDIR" 2>/dev/null | grep -v -e '\.age$' -e '/stubs/')"
check "$t: the run's agent is gone, and the lock" "gone " "$(cat "$S/agent.ended") $(ls -d "$B/lock" 2>/dev/null)"
check "$t: WordPress was never asked anything (no docker here at all)" 0 "$(calls "$S/docker.calls" .)"
private "$t"

newcase "\"path\":\"/_pigeonhole\",\"recipients\":[\"$DAILY_PUB\"]$SERVER"; keys_in; ph doctor; t="doctor, one recipient"
check "$t: exits 0: it is advice, not a problem" 0 "$code"
has "$t: the advice" "ok: comments are encrypted to one key. With no recovery key" "$out"
check "$t: what was posted is a submission to one recipient" 8400 "$(wc -c < "$S/posted" | tr -d ' ')"

newcase; keys_in; BN=0
for i in 1 2; do
  { echo "age-encryption.org/v1"; echo "-> stand-in"; echo "--- run $i"; echo "a visitor's $i"; } > "$S/v"
  mv "$S/v" "$R/$(php -r 'echo hash_file("sha256", $argv[1]);' "$S/v").age"
done
ph doctor; t="doctor, while two real submissions are on the store"
check "$t: exits 0" 0 "$code"
has "$t: the list counted them" "the pull command answered (2 held there now)" "$out"
has "$t: says they came too, and wait" "ok: 2 more that visitors sent came with it, and wait to be opened (offprint collect)." "$out"
check "$t: they wait in the spool, unopened; only the canary went to done/" "2 1" "$(ls "$SP" | grep -c .) $(ls "$B/done" | grep -c .)"
has "$t: the fetch's status is written for the admin bar" '"ok":true,"fetched":3' "$(cat "$c/var/pigeonhole-fetch.json")"

# doctor_problem NAME EXPECTED-LINE [EXPECTED-EXIT]: one problem line is exactly this, and the exit is 1
doctor_problem() {
  ph doctor
  check "$1: exits ${3:-1}" "${3:-1}" "$code"
  if printf '%s\n' "$out" | grep -qxF -- "problem: $2"; then ok "$1: says so, and what to do"; else bad "$1: no line \"problem: $2\" in: $out"; fi
  private "$1"
}
newcase none; keys_in
doctor_problem "doctor, no pigeonhole block" 'site.json has no "pigeonhole" block, so this site takes no comments. docs/reference.md says what goes in one; offprint pigeonhole keys makes the keys first.'
check "... and it stops there" 1 "$(printf '%s\n' "$out" | grep -c .)"
newcase "\"path\":\"/_pigeonhole\",\"recipients\":[\"$DAILY_PUB\",\"$P62\"]"; keys_in
doctor_problem "doctor, a block that names no server" 'the block names no server ("server", "server_host_key", "jump", "jump_host_key"), so nothing can be fetched.'
check "... ssh never ran, and nothing was posted: a canary that can't be fetched back would only sit on the store" "0 0" "$(calls "$S/ssh.calls" .) $(calls "$S/curl.calls" 'data-binary')"
has "... the other checks still ran" "ok: the daily key is in the login Keychain" "$out"
newcase "\"path\":\"/_pigeonhole\",\"recipients\":[\"$DAILY_PUB\",\"$P62\"]$SERVER" files; keys_in
doctor_problem "doctor, an adapter whose host only takes files" "the site's adapter (files) doesn't say its host forwards the path (ADAPTER_PIGEONHOLE=1), so a publish refuses this site while it has the block. Only a host with a web server of your own can take comments."
newcase; keys_in; rm "$S/keychain/pigeonhole-daily"
doctor_problem "doctor, no daily key" "this site's daily key isn't in the login Keychain; offprint pigeonhole keys makes it."
has "... the canary still went the whole way but for the opening" "problem: the test submission came back, but there is no daily key to open it with (see above). It waits in the spool." "$out"
newcase "\"path\":\"/_pigeonhole\",\"recipients\":[\"$P62\"]$SERVER"; keys_in
doctor_problem "doctor, the daily key is not one of the recipients" "the daily key in the login Keychain is not one of site.json's pigeonhole.recipients, so it opens nothing sent to them. Its public half is $DAILY_PUB: put that first in the list (then offprint compose up -d, and publish)."
newcase; keys_in; touch "$S/secret_locked"
doctor_problem "doctor, the Keychain is locked" "the login Keychain is locked, so the keys couldn't be read; unlock it, then run the doctor again."
newcase; keys_in; rm "$S/keychain/pigeonhole-pull"
doctor_problem "doctor, no pull key" "this site's pull key isn't in the login Keychain (the secret pigeonhole-pull); offprint pigeonhole keys makes it."
has "... the canary is still posted, and said to wait" "problem: the test submission is on the store, but the fetch couldn't be tried (see above)." "$out"
newcase; keys_in; echo "No ED25519 host key is known for offprint-store and you have requested strict checking." > "$S/ssh_says"
doctor_problem "doctor, the store shows another host key" "the pigeonhole's server (site.json's pigeonhole.server) didn't show the ssh host key site.json pins for it (pigeonhole.server_host_key), so it wasn't spoken to. If the machine was rebuilt, check its new key before changing site.json."
newcase; keys_in; echo "Welcome to the wrong command" > "$S/list_says"
doctor_problem "doctor, the store answers but not as the pull command" "the pigeonhole's server answered, but not as its pull command does. Is its authorized_keys line the one this Offprint prints? (offprint pigeonhole print-server store)"
newcase; keys_in; echo 200 > "$S/get_code"
doctor_problem "doctor, the path answers a GET" "the public site answers a GET of /_pigeonhole with 200, where a refusal (404 or 405) was expected: something else is at that path. Choose another pigeonhole.path, or look at the web server's lines (offprint pigeonhole print-server web)."
check "... and no test submission is posted to whatever that is" 0 "$(calls "$S/curl.calls" 'data-binary')"
newcase; keys_in; touch "$S/curl_down"
doctor_problem "doctor, the public site can't be reached" "the public site couldn't be reached at https://www.example.com (is this Mac online?), so the path wasn't checked."
for pair in "404|the web server answered the test submission with 404: it doesn't pass a POST to /_pigeonhole on to the store. Are the Caddy lines in the site's block? (offprint pigeonhole print-server web)" \
    "405|the web server answered the test submission with 405: it doesn't pass a POST to /_pigeonhole on to the store. Are the Caddy lines in the site's block? (offprint pigeonhole print-server web)" \
    "502|the web server passes the path on, but the store didn't answer it (502). Is the store running (systemctl status pigeonhole@example on its machine), and does its firewall let the web server reach port 8788?" \
    "400|the store refused the test submission (400): the web server must name the visitor's address in the X-Pigeonhole-Client header (offprint pigeonhole print-server web)." \
    "403|the store refused the test submission's proof of work (403): its PIGEONHOLE_BITS must be 18, as a page's script makes." \
    "429|the store has taken as many submissions from this address, or from everyone, as it takes in an hour (429). Nothing is wrong with the path; run the doctor again in an hour to send a test through it." \
    "507|the store is full (507): fetch what it holds (offprint collect), and look at why it wasn't fetched." \
    "500|the public site answered the test submission with 500, where 204 was expected."; do
  newcase; keys_in; echo "${pair%%|*}" > "$S/post_code"
  doctor_problem "doctor, the test submission is answered ${pair%%|*}" "${pair#*|}"
done
newcase; keys_in; touch "$S/store_drops"
doctor_problem "doctor, the store says kept but the fetch doesn't bring it" "the store said it kept the test submission, but the fetch didn't bring it back. Is the store the web server passes to (port 8788, the path /_pigeonhole) the instance whose folder the pull command reads?"
newcase; keys_in; printf '%s' "AGE-SECRET-KEY-1OTHER" > "$S/keychain/pigeonhole-daily"; printf '%s\n' "$DAILY_PUB" > "$S/agekey.pub.AGE-SECRET-KEY-1OTHER"
doctor_problem "doctor, the daily key doesn't open what was sent to it" "the test submission came back, but the daily key didn't open it. It is left in the spool; offprint collect will move it aside with its reason."
newcase; keys_in; mkdir -p "$B/lock"; chmod 700 "$H/pigeonhole" "$B"; echo "$$" > "$B/lock/pid"; ph doctor; t="doctor, while a fetch holds the spool's lock"
check "$t: exits 75" 75 "$code"
has "$t: says so" "problem: another fetch or collection is running for this site; wait for it, then try again." "$out"
newcase; keys_in; rm "$S/bin/age-keygen" "$S/bin/age"; t="doctor, age isn't installed"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$(dirname "$(command -v php)"):$(dirname "$(command -v git)"):/usr/bin:/bin" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/pigeonhole" doctor 2>&1 < /dev/null)"; code=$?
if command -v age > /dev/null 2>&1 && [ "$(dirname "$(command -v age)")" = "$(dirname "$(command -v php)")" ]; then ok "$t: (not tried: the real age sits beside php here)"
else has "$t: says what is missing, and how to get it" "problem: not on the PATH: age, age-keygen (age and age-keygen: brew install age). The rest can't be checked without them." "$out"; fi

newcase; keys_in; t="doctor, asked of another origin (the rehearsal's seam)"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" PIGEONHOLE_CHECK_ORIGIN="http://127.0.0.1:8099" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/pigeonhole" doctor 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
has "$t: that origin is posted to" "--data-binary @- http://127.0.0.1:8099/_pigeonhole" "$(cat "$S/curl.calls")"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" PIGEONHOLE_CHECK_ORIGIN="http://127.0.0.1:8099/x y" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/pigeonhole" doctor 2>&1 < /dev/null)"; code=$?
has "$t, one that is no origin: refused" "problem: PIGEONHOLE_CHECK_ORIGIN isn't an origin" "$out"

[ "$fail" -eq 0 ]
