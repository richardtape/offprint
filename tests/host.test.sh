#!/usr/bin/env bash
# Tests os/darwin/host-setup.sh and host-undo.sh (the one privileged step: lo0, /etc/hosts, LaunchDaemons), and
# `offprint host-setup` / `offprint host-undo`.
# Every run of the scripts sets every seam, on a pretend machine in a throwaway folder: a hosts file, a LaunchDaemons
# folder, and stand-ins for ifconfig, launchctl and lsof that keep a pretend lo0 and a pretend list of loaded jobs,
# and note each call. Nothing here can reach this machine's /etc/hosts, lo0, launchd or LaunchDaemons: the scripts
# need root without the seams and refuse a seam that is (or links to) the real thing; this suite refuses to run as
# root; and tripwires named ifconfig, launchctl, lsof, dscacheutil, killall, chown and sudo come first on PATH.
# Run: bash tests/host.test.sh   (macOS bash 3.2 and Linux; the plutil -lint checks need macOS's plutil and are
# skipped, visibly, without it)
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
SRCP="$(pwd -P)"
unset OFFPRINT_SITE OFFPRINT_HOSTS_FILE OFFPRINT_DAEMON_DIR OFFPRINT_IFCONFIG OFFPRINT_LAUNCHCTL OFFPRINT_LSOF OFFPRINT_SKIP_ROOT_CHECK
if [ "$(id -u)" = 0 ]; then echo "Run tests/host.test.sh as yourself, not as root."; exit 1; fi
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR), and TMPDIR
# inside it from here on, so nothing the suite runs leaves anything in the real one.
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-host-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
skip() { echo "skip  $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
contains() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no '$2' in '$3')"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' in '$3')"; else ok "$1"; fi; }
yes_no() { if "$@"; then echo yes; else echo no; fi; }
TAB="$(printf '\t')"
real_hosts_sum="$(cksum < /etc/hosts 2>/dev/null)"

# Tripwires: a script that calls any of these by name, instead of through its seam, is caught.
TRIP="$tmp/trip"; mkdir -p "$TRIP"
for c in ifconfig launchctl lsof dscacheutil killall chown sudo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/tripped"\nexit 99\n' "$c" "$tmp" > "$TRIP/$c"; chmod +x "$TRIP/$c"
done

n=0
# world: a fresh pretend machine in $W. etc/hosts; LaunchDaemons/; lo0 (what `ifconfig lo0` prints); loaded/ (one
# file per job launchd has loaded); listening (the ports lsof finds a listener on); the stand-ins in stubs/.
# Switches, as files in $W, make a stand-in fail: fail-read (ifconfig lo0), fail-alias6 (adding an inet6 alias),
# fail-print (launchctl print), fail-lsof (lsof exits with the code in it, saying why on stderr), and
# ro-after-loopback (launchctl makes the daemon folder read-only once it has loaded a .loopback job).
world() {
  n=$((n + 1)); W="$tmp/w$n"; mkdir -p "$W/etc" "$W/LaunchDaemons" "$W/loaded" "$W/stubs"
  printf '##\n# Host Database\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n' > "$W/etc/hosts"
  printf 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n\tinet6 ::1 prefixlen 128 \n\tinet6 fe80::1%%lo0 prefixlen 64 scopeid 0x1 \n' > "$W/lo0"
  : > "$W/listening"; : > "$W/ifconfig.calls"; : > "$W/launchctl.calls"; : > "$W/lsof.calls"
  # ifconfig, for lo0 only: prints the pretend lo0, and adds or removes an address the way the scripts ask.
  sed "s#@W@#$W#g" > "$W/stubs/ifconfig" <<'STUB'
#!/bin/sh
echo "$*" >> "@W@/ifconfig.calls"
f="@W@/lo0"
case "$*" in
  lo0) [ -f "@W@/fail-read" ] && { echo "ifconfig: interface lo0 does not exist" >&2; exit 1; }; cat "$f" ;;
  "lo0 alias "*" up") [ $# -eq 4 ] || exit 1; printf '\tinet %s netmask 0xff000000\n' "$3" >> "$f" ;;
  "lo0 inet6 alias "*" prefixlen 128") [ $# -eq 6 ] || exit 1
    [ -f "@W@/fail-alias6" ] && { echo "ifconfig: ioctl (SIOCAIFADDR_IN6): Invalid argument" >&2; exit 1; }
    printf '\tinet6 %s prefixlen 128 \n' "$4" >> "$f" ;;
  "lo0 -alias "*) [ $# -eq 3 ] || exit 1; awk -v a="$3" '!($1 == "inet" && $2 == a)' "$f" > "$f.new" && mv "$f.new" "$f" ;;
  "lo0 inet6 -alias "*) [ $# -eq 4 ] || exit 1; awk -v a="$4" '!($1 == "inet6" && $2 == a)' "$f" > "$f.new" && mv "$f.new" "$f" ;;
  *) echo "UNEXPECTED $*" >> "@W@/ifconfig.calls"; exit 1 ;;
esac
STUB
  # launchctl: print (is it loaded?), bootstrap system PLIST (its Label must be its file name), bootout system/LABEL.
  sed "s#@W@#$W#g" > "$W/stubs/launchctl" <<'STUB'
#!/bin/sh
echo "$*" >> "@W@/launchctl.calls"
case "$1 $2" in
  "print system/"*) [ -f "@W@/fail-print" ] && { echo "Unhandled error" >&2; exit 5; }
    [ $# -eq 2 ] && [ -e "@W@/loaded/${2#system/}" ] && exit 0; exit 113 ;;
  "bootout system/"*) [ $# -eq 2 ] || exit 1; l="${2#system/}"; [ -e "@W@/loaded/$l" ] || exit 3; rm -f "@W@/loaded/$l" ;;
  "bootstrap system")
    [ $# -eq 3 ] && [ -f "$3" ] || exit 5
    l="$(basename "$3" .plist)"
    grep -qF "<key>Label</key><string>$l</string>" "$3" || { echo "stand-in launchctl: the Label is not $l" >&2; exit 5; }
    [ -e "@W@/loaded/$l" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
    touch "@W@/loaded/$l"
    case "$l" in *.loopback) if [ -f "@W@/ro-after-loopback" ]; then chmod 555 "@W@/LaunchDaemons"; fi ;; esac ;;
  *) echo "UNEXPECTED $*" >> "@W@/launchctl.calls"; exit 1 ;;
esac
STUB
  # lsof: a listener on each port listed in $W/listening, as lsof prints one.
  sed "s#@W@#$W#g" > "$W/stubs/lsof" <<'STUB'
#!/bin/sh
echo "$*" >> "@W@/lsof.calls"
[ -f "@W@/fail-lsof" ] && { echo "lsof: WARNING: can't stat() something" >&2; exit "$(cat "@W@/fail-lsof")"; }
port=""
for a in "$@"; do case "$a" in -iTCP:*) port="${a#-iTCP:}" ;; esac; done
[ -n "$port" ] && grep -qx "$port" "@W@/listening" || exit 1
echo "COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME"
echo "com.docke  4242 someone 12u  IPv4 0x56c16eeedce31ba7      0t0  TCP 127.0.0.1:$port (LISTEN)"
STUB
  chmod +x "$W/stubs/ifconfig" "$W/stubs/launchctl" "$W/stubs/lsof"
}
lo0_add() { printf '\tinet %s netmask 0xff000000\n' "$1" >> "$W/lo0"; }
lo0_add6() { printf '\tinet6 %s prefixlen 128 \n' "$1" >> "$W/lo0"; }
on_lo0() { awk -v a="$1" '($1 == "inet" || $1 == "inet6") && $2 == a { f = 1 } END { exit !f }' "$W/lo0"; }
reset_calls() { : > "$W/ifconfig.calls"; : > "$W/launchctl.calls"; : > "$W/lsof.calls"; }
# changed_calls: every call made to the stand-ins that changes something (all but reading lo0 and launchctl print)
changed_calls() { { grep -vx 'lo0' "$W/ifconfig.calls"; grep -v '^print ' "$W/launchctl.calls"; } | paste -sd'|' -; }
# keep: a copy of the pretend machine, to compare with; same_as_kept: "same", or "differs". With "but_backup", the
# copy of the hosts file from before (which host-undo keeps, by design) is not compared.
keep() { rm -rf "$W/kept"; mkdir -p "$W/kept"; cp -Rp "$W/etc" "$W/LaunchDaemons" "$W/loaded" "$W/lo0" "$W/kept/"; }
same_as_kept() {
  local x=""; [ "${1:-}" = but_backup ] && x="hosts.before-offprint"
  if cmp -s "$W/kept/etc/hosts" "$W/etc/hosts" && diff -r ${x:+-x "$x"} "$W/kept/etc" "$W/etc" > /dev/null 2>&1 \
     && diff -r "$W/kept/LaunchDaemons" "$W/LaunchDaemons" > /dev/null 2>&1 \
     && diff -r "$W/kept/loaded" "$W/loaded" > /dev/null 2>&1 && cmp -s "$W/kept/lo0" "$W/lo0"; then
    echo same
  else
    echo differs
  fi
}

# host SCRIPT ARGS...: os/darwin/SCRIPT with every seam set on $W; sets out and code.
#   SKIP_ROOT (default 1) is OFFPRINT_SKIP_ROOT_CHECK; XPATH goes on PATH after the
#   tripwires; IN is the folder it runs in.
host() {
  local s="$1"; shift
  out="$(cd "${IN:-$SRC}" && PATH="$TRIP:${XPATH:+$XPATH:}$PATH" OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" \
    OFFPRINT_IFCONFIG="$W/stubs/ifconfig" OFFPRINT_LAUNCHCTL="$W/stubs/launchctl" OFFPRINT_LSOF="$W/stubs/lsof" \
    OFFPRINT_SKIP_ROOT_CHECK="${SKIP_ROOT-1}" /bin/bash "$SRC/os/darwin/$s" "$@" 2>&1)"; code=$?
}
setup() { host host-setup.sh "$@"; }
undo() { host host-undo.sh "$@"; }

# mksite DIR NAME HOST IP4 IP6 TLS_PORT HTTP_PORT [MORE_JSON]: a site folder with that site.json
mksite() {
  mkdir -p "$1"
  printf '{"format":1,"name":"%s","public_url":"https://%s.example.com","local_host":"%s","local_ip4":"%s","local_ip6":"%s","tls_port":%s,"http_port":%s%s}\n' \
    "$2" "$2" "$3" "$4" "$5" "$6" "$7" "${8:+,$8}" > "$1/site.json"
}
# phys_dir DIR: DIR's physical path in the disk's own letter case (/bin/pwd asks the system; bash's own pwd keeps the
# case as typed, which on a disk that ignores case may not be the folder's)
phys_dir() { if [ -x /bin/pwd ]; then (CDPATH= cd -P -- "$1" && /bin/pwd -P); else (CDPATH= cd -P -- "$1" && pwd -P); fi; }
# stamp_of DIR: a site folder's ownership stamp, the sha256 of its physical path (worked out here without php, as a
# cross-check of the scripts' own)
stamp_of() {
  local p; p="$(phys_dir "$1")"
  if command -v sha256sum > /dev/null 2>&1; then printf '%s' "$p" | sha256sum; else printf '%s' "$p" | shasum -a 256; fi | cut -d' ' -f1
}
A="$tmp/sites/alpha"; mksite "$A" alpha alpha.test 127.0.0.21 fd00:a::21 4701 4702; PA=local.offprint.alpha; SA="$(stamp_of "$A")"
B="$tmp/sites/beta"; mksite "$B" beta beta.test 127.0.0.22 fd00:b::22 4711 4712; PB=local.offprint.beta; SB="$(stamp_of "$B")"
check "the stamp is 64 lowercase hex characters" yes "$(printf '%s' "$SA" | grep -qxE '[0-9a-f]{64}' && echo yes)"
BLOCK_A="$(printf '# >>> offprint: alpha.test >>>\n# site %s\n127.0.0.21\talpha.test\nfd00:a::21\talpha.test\n# <<< offprint: alpha.test <<<' "$SA")"
BLOCK_B="$(printf '# >>> offprint: beta.test >>>\n# site %s\n127.0.0.22\tbeta.test\nfd00:b::22\tbeta.test\n# <<< offprint: beta.test <<<' "$SB")"
# with_stamp STAMP: a plist (on stdin) as host-setup writes it, the stamp comment after the <plist> line
with_stamp() { awk -v s="$1" '{ print } $0 == "<plist version=\"1.0\">" { print "<!-- offprint site " s " -->" }'; }
# forwarder_xml LABEL PORT ADDR4 ADDR6 CADDY_PORT: a relay plist in the original's shape (for planted ones)
forwarder_xml() {
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
  <key>UserName</key><string>nobody</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/nc</string><string>127.0.0.1</string><string>$5</string></array>
  <key>inetdCompatibility</key><dict><key>Wait</key><false/></dict>
  <key>Sockets</key>
  <dict>
    <key>v4</key><dict><key>SockNodeName</key><string>$3</string><key>SockServiceName</key><string>$2</string></dict>
    <key>v6</key><dict><key>SockNodeName</key><string>$4</string><key>SockServiceName</key><string>$2</string></dict>
  </dict>
</dict>
</plist>
PL
}
loopback_xml() {  # LABEL ADDR4 ADDR6
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>/sbin/ifconfig lo0 alias $2 up; /sbin/ifconfig lo0 inet6 alias $3 prefixlen 128</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PL
}
# refused T WHAT: the last run exited 1 naming WHAT, and changed nothing at all
refused() {
  check "$1: exits 1" 1 "$code"
  contains "$1: names the clash" "$2" "$out"
  check "$1: the hosts file, the daemon folder, lo0 and launchd are byte-identical" same "$(same_as_kept)"
  check "$1: nothing that changes anything was asked of ifconfig or launchctl" "" "$(changed_calls)"
}
D() { cat "$W/LaunchDaemons/$1"; }

# --- a clean set-up ---
world; keep; setup "$A"; t="a clean set-up"
check "$t: exits 0" 0 "$code"
{ cat "$W/kept/etc/hosts"; printf '\n%s\n' "$BLOCK_A"; } > "$W/expected"
check "$t: the hosts file is the old one, a blank line, and this site's block" same "$(cmp -s "$W/expected" "$W/etc/hosts" && echo same)"
check "$t: the copy from before is beside it" same "$(cmp -s "$W/kept/etc/hosts" "$W/etc/hosts.before-offprint" && echo same)"
check "$t: three plists, named with the site's prefix, and nothing else" "$PA.http.plist $PA.https.plist $PA.loopback.plist" \
  "$(ls -A "$W/LaunchDaemons" | paste -sd' ' -)"
for k in loopback https http; do
  contains "$t: $k: its label" "<key>Label</key><string>$PA.$k</string>" "$(D "$PA.$k.plist")"
  check "$t: $k: mode 644" yes "$([ -n "$(find "$W/LaunchDaemons/$PA.$k.plist" -perm 644)" ] && echo yes)"
done
contains "$t: loopback: both addresses at every boot" \
  "<string>/sbin/ifconfig lo0 alias 127.0.0.21 up; /sbin/ifconfig lo0 inet6 alias fd00:a::21 prefixlen 128</string>" "$(D "$PA.loopback.plist")"
contains "$t: loopback: at load" "<key>RunAtLoad</key><true/>" "$(D "$PA.loopback.plist")"
contains "$t: https: nc runs as nobody" "<key>UserName</key><string>nobody</string>" "$(D "$PA.https.plist")"
contains "$t: https: relays to Caddy's tls_port on 127.0.0.1" "<array><string>/usr/bin/nc</string><string>127.0.0.1</string><string>4701</string></array>" "$(D "$PA.https.plist")"
contains "$t: https: listens on local_ip4, port 443" "<key>SockNodeName</key><string>127.0.0.21</string><key>SockServiceName</key><string>443</string>" "$(D "$PA.https.plist")"
contains "$t: https: and on local_ip6, port 443" "<key>SockNodeName</key><string>fd00:a::21</string><key>SockServiceName</key><string>443</string>" "$(D "$PA.https.plist")"
contains "$t: http: relays to Caddy's http_port" "<array><string>/usr/bin/nc</string><string>127.0.0.1</string><string>4702</string></array>" "$(D "$PA.http.plist")"
contains "$t: http: listens on local_ip4, port 80" "<key>SockNodeName</key><string>127.0.0.21</string><key>SockServiceName</key><string>80</string>" "$(D "$PA.http.plist")"
contains "$t: http: and on local_ip6, port 80" "<key>SockNodeName</key><string>fd00:a::21</string><key>SockServiceName</key><string>80</string>" "$(D "$PA.http.plist")"
check "$t: the plists are the original's, with the site's names and its stamp" same \
  "$(forwarder_xml "$PA.https" 443 127.0.0.21 fd00:a::21 4701 | with_stamp "$SA" | cmp -s - "$W/LaunchDaemons/$PA.https.plist" \
    && forwarder_xml "$PA.http" 80 127.0.0.21 fd00:a::21 4702 | with_stamp "$SA" | cmp -s - "$W/LaunchDaemons/$PA.http.plist" \
    && loopback_xml "$PA.loopback" 127.0.0.21 fd00:a::21 | with_stamp "$SA" | cmp -s - "$W/LaunchDaemons/$PA.loopback.plist" && echo same)"
for k in loopback https http; do
  check "$t: $k: one stamp line, this site folder's" "<!-- offprint site $SA -->" "$(grep 'offprint site' "$W/LaunchDaemons/$PA.$k.plist")"
done
check "$t: the hosts block's stamp, right after the begin marker" "# site $SA" \
  "$(awk '$0 == "# >>> offprint: alpha.test >>>" { getline; print }' "$W/etc/hosts")"
check "$t: ifconfig adds both addresses, then launchd loads the three" \
  "lo0 alias 127.0.0.21 up|lo0 inet6 alias fd00:a::21 prefixlen 128|bootstrap system $W/LaunchDaemons/$PA.loopback.plist|bootstrap system $W/LaunchDaemons/$PA.https.plist|bootstrap system $W/LaunchDaemons/$PA.http.plist" \
  "$(changed_calls)"
check "$t: both addresses are on lo0" "yes yes" "$(yes_no on_lo0 127.0.0.21) $(yes_no on_lo0 fd00:a::21)"
check "$t: the three are loaded" "$PA.http $PA.https $PA.loopback" "$(ls -A "$W/loaded" | paste -sd' ' -)"
contains "$t: says what is next" "Next: offprint setup-wp" "$out"
if command -v plutil > /dev/null 2>&1; then
  for k in loopback https http; do
    check "$t: $k: passes plutil -lint" 0 "$(plutil -lint "$W/LaunchDaemons/$PA.$k.plist" > /dev/null 2>&1; echo $?)"
  done
  check "$t: https: the v6 address, read back by plutil" fd00:a::21 "$(plutil -extract Sockets.v6.SockNodeName raw -o - "$W/LaunchDaemons/$PA.https.plist")"
else
  skip "$t: plutil -lint and read-back (no plutil: not macOS)"
fi

# --- a second run changes nothing, and succeeds; so does one with the site's own Caddy listening ---
keep; reset_calls; setup "$A"; t="a second run"
check "$t: exits 0" 0 "$code"
check "$t: changes nothing" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
contains "$t: says so" "already" "$out"
printf '4701\n4702\n' > "$W/listening"; reset_calls; setup "$A"; t="a second run, with the site's Caddy on its ports"
check "$t: exits 0 (its own plists are in place, so the listener is its own Caddy)" 0 "$code"
check "$t: changes nothing" same "$(same_as_kept)"
check "$t: and never asks lsof" "" "$(cat "$W/lsof.calls")"
rm "$W/loaded/$PA.https"; reset_calls; setup "$A"; t="a second run, with one job not loaded"
check "$t: exits 0" 0 "$code"
check "$t: loads just that one" "bootstrap system $W/LaunchDaemons/$PA.https.plist" "$(changed_calls)"

# --- a changed port (the same site folder, its site.json edited): only that relay is rewritten and reloaded ---
mksite "$A" alpha alpha.test 127.0.0.21 fd00:a::21 4703 4702; : > "$W/listening"; reset_calls
setup "$A"; t="the same site, with a new tls_port"
check "$t: exits 0" 0 "$code"
contains "$t: the https relay goes to the new port" "<string>127.0.0.1</string><string>4703</string>" "$(D "$PA.https.plist")"
check "$t: only it is unloaded and loaded again" "bootout system/$PA.https|bootstrap system $W/LaunchDaemons/$PA.https.plist" "$(changed_calls)"
keep; echo 4704 > "$W/listening"; reset_calls
mksite "$A" alpha alpha.test 127.0.0.21 fd00:a::21 4704 4702; setup "$A"
refused "the same site, with a new tls_port something else listens on" "4704"
mksite "$A" alpha alpha.test 127.0.0.21 fd00:a::21 4701 4702

# --- --print writes nothing ---
world; keep; SKIP_ROOT= setup --print "$A"; t="--print on a clean machine, without root"
check "$t: exits 0" 0 "$code"
check "$t: changes nothing" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
check "$t: makes no copy of the hosts file" no "$([ -e "$W/etc/hosts.before-offprint" ] && echo yes || echo no)"
contains "$t: shows each address it would add" "ifconfig lo0 alias 127.0.0.21 up" "$out"
contains "$t: both" "ifconfig lo0 inet6 alias fd00:a::21 prefixlen 128" "$out"
for line in "# >>> offprint: alpha.test >>>" "127.0.0.21${TAB}alpha.test" "fd00:a::21${TAB}alpha.test" "# <<< offprint: alpha.test <<<"; do
  contains "$t: shows the hosts block: $line" "$line" "$out"
done
contains "$t: and the copy it would make" "$W/etc/hosts.before-offprint" "$out"
# shown FILE: "shown" when every line of FILE is a line of $out (give or take indentation)
shown() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "$out" | sed 's/^ *//' | grep -qxF -- "$line" || { echo "not shown: $line"; return; }
  done < "$1"
  echo shown
}
loopback_xml "$PA.loopback" 127.0.0.21 fd00:a::21 > "$W/want-loopback"
forwarder_xml "$PA.https" 443 127.0.0.21 fd00:a::21 4701 > "$W/want-https"
forwarder_xml "$PA.http" 80 127.0.0.21 fd00:a::21 4702 > "$W/want-http"
for k in loopback https http; do
  contains "$t: names $PA.$k.plist" "$W/LaunchDaemons/$PA.$k.plist" "$out"
  sed 's/^ *//' "$W/want-$k" > "$W/want-$k.trimmed"
  check "$t: shows the $k plist in full" shown "$(shown "$W/want-$k.trimmed")"
done
check "$t: with the stamp in each plist" 3 "$(printf '%s\n' "$out" | grep -cxE " *<!-- offprint site $SA -->")"
check "$t: and in the hosts block" 1 "$(printf '%s\n' "$out" | grep -cxE " *# site $SA")"
contains "$t: and the line that would make the changes" "sudo /bin/bash '$SRCP/os/darwin/host-setup.sh' '$(cd "$A" && pwd -P)'" "$out"
setup "$A"; keep; reset_calls; setup --print "$A"; t="--print after a set-up"
check "$t: exits 0" 0 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
contains "$t: says nothing would change" "Nothing would change" "$out"
world; lo0_add 127.0.0.21; keep; setup --print "$A"; t="--print, with a clash"
check "$t: exits 1" 1 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
contains "$t: says it would refuse" "refuse" "$out"; contains "$t: naming the clash" "127.0.0.21" "$out"

# --- each refusal: exit 1, naming the clash, everything byte-identical ---
world; lo0_add 127.0.0.21; keep; setup "$A"; refused "local_ip4 on lo0 already, with no plist of this site's naming it" "127.0.0.21"
contains "local_ip4 on lo0 already: says what it is" "lo0" "$out"
world; lo0_add6 fd00:a::21; keep; setup "$A"; refused "local_ip6 on lo0 already, with no plist of this site's naming it" "fd00:a::21"
world; lo0_add 127.0.0.21; loopback_xml "$PA.loopback" 127.0.0.99 fd00:a::21 > "$W/LaunchDaemons/$PA.loopback.plist"; keep; setup "$A"
refused "local_ip4 on lo0, and this site's loopback plist naming another address" "127.0.0.99"
world; printf '10.1.2.3\tother.test alpha.test\n' >> "$W/etc/hosts"; keep; setup "$A"
refused "local_host on a line of the hosts file outside this site's block" "alpha.test"
contains "local_host in the hosts file: names the line" "line 7" "$out"
world; printf '10.1.2.3\tALPHA.TEST\n' >> "$W/etc/hosts"; keep; setup "$A"; refused "local_host in capitals in the hosts file" "ALPHA.TEST"
world; printf '127.0.0.21\tsomething.else\n' >> "$W/etc/hosts"; keep; setup "$A"
refused "local_ip4 given to another name in the hosts file" "127.0.0.21${TAB}something.else"
world; printf 'fd00:a::21 something.else\n' >> "$W/etc/hosts"; keep; setup "$A"; refused "local_ip6 given to another name in the hosts file" "fd00:a::21 something.else"
world; printf '127.0.0.21\talpha.test something.else\n' >> "$W/etc/hosts"; keep; setup "$A"
refused "local_ip4 given to local_host and another name, outside this site's block" "names alpha.test outside this site's block"
world; printf '\n# >>> offprint: alpha.test >>>\n127.0.0.99\talpha.test\n# <<< offprint: alpha.test <<<\n' >> "$W/etc/hosts"; keep; setup "$A"
refused "a block with this site's markers that maps another address (another site with the same local_host)" "127.0.0.99"
world; printf '# 10.1.2.3 alpha.test (a comment)\n' >> "$W/etc/hosts"; setup "$A"; t="local_host only in a comment of the hosts file"
check "$t: is no clash" 0 "$code"
world; printf '\n# >>> offprint: alpha.test >>>\n127.0.0.21\talpha.test\n' >> "$W/etc/hosts"; keep; setup "$A"
refused "a begin marker with no end marker" "refusing to touch"
world; forwarder_xml "$PA.https" 443 127.0.0.99 fd00:a::21 4701 > "$W/LaunchDaemons/$PA.https.plist"; keep; setup "$A"
refused "this site's https plist exists and names another address" "$PA.https.plist"
contains "this site's https plist names another address: which" "127.0.0.99" "$out"
world; loopback_xml "$PA.extra" 10.9.9.9 fd00:a::21 > "$W/LaunchDaemons/$PA.extra.plist"; keep; setup "$A"
refused "another plist with this site's prefix names another address" "$PA.extra.plist"
world; printf '<plist version="1.0"><dict><key>Label</key><string>%s.https</string></dict></plist>\n' "$PA" > "$W/LaunchDaemons/$PA.https.plist"; keep; setup "$A"
refused "this site's https plist exists and names no address" "no address"
world; forwarder_xml "$PA.http" 80 127.0.0.21 fd00:a::21 4702 > "$W/target.plist"; ln -s "$W/target.plist" "$W/LaunchDaemons/$PA.http.plist"; keep; setup "$A"
refused "this site's http plist is a link (even to one that looks right)" "not a plain file"
world; loopback_xml com.example.other 127.0.0.21 fd00:99::1 > "$W/LaunchDaemons/com.example.other.plist"; keep; setup "$A"
refused "another plist names local_ip4" "com.example.other.plist"
world; loopback_xml com.example.other 127.0.0.210 fd00:a::210 > "$W/LaunchDaemons/com.example.other.plist"; setup "$A"; t="another plist names 127.0.0.210 and fd00:a::210"
check "$t: is no clash with 127.0.0.21 and fd00:a::21" 0 "$code"
world; loopback_xml com.example.other 127.0.0.99 FD00:A::21 > "$W/LaunchDaemons/com.example.other.plist"; keep; setup "$A"
refused "another plist names local_ip6 (in capitals)" "com.example.other.plist"
world; forwarder_xml com.example.relay 8443 127.0.0.99 fd00:99::1 4701 > "$W/LaunchDaemons/com.example.relay.plist"; keep; setup "$A"
refused "another plist relays to the site's tls_port" "4701"
world; forwarder_xml com.example.relay 8080 127.0.0.99 fd00:99::1 4702 > "$W/LaunchDaemons/com.example.relay.plist"; keep; setup "$A"
refused "another plist relays to the site's http_port" "4702"
world; echo 4701 > "$W/listening"; keep; setup "$A"; refused "something listening on tls_port, on a first set-up" "4701"
contains "something listening on tls_port: says what" "com.docke" "$out"
world; echo 4702 > "$W/listening"; keep; setup "$A"; refused "something listening on http_port, on a first set-up" "4702"
world; lo0_add 127.0.0.21; echo 4701 > "$W/listening"; printf '10.1.2.3\talpha.test\n' >> "$W/etc/hosts"; keep; setup "$A"; t="three clashes at once"
refused "$t" "127.0.0.21"; contains "$t: names the second" "alpha.test" "$out"; contains "$t: and the third" "4701" "$out"

# --- the owner's own block and daemons, from before Offprint, come through set-up and undo byte-identical ---
world
printf '\n# >>> wp.local (another/host/setup.sh) >>>\n127.0.0.25\twp.local\nfd00:b::25\twp.local\n# <<< wp.local <<<\n' >> "$W/etc/hosts"
lo0_add 127.0.0.25; lo0_add6 fd00:b::25
forwarder_xml local.wp.https 443 127.0.0.25 fd00:b::25 4725 > "$W/LaunchDaemons/local.wp.https.plist"
loopback_xml local.wp.loopback 127.0.0.25 fd00:b::25 > "$W/LaunchDaemons/local.wp.loopback.plist"
touch "$W/loaded/local.wp.https" "$W/loaded/local.wp.loopback"; echo 4725 > "$W/listening"
keep; setup "$A"; t="beside the wp.local block and local.wp.* daemons"
check "$t: set-up exits 0" 0 "$code"
check "$t: their plists are byte-identical" same "$(diff -r "$W/kept/LaunchDaemons" "$W/LaunchDaemons" 2>/dev/null | grep -v "^Only in $W/LaunchDaemons: $PA\." | grep -q . || echo same)"
{ cat "$W/kept/etc/hosts"; printf '\n%s\n' "$BLOCK_A"; } > "$W/expected"
check "$t: the hosts file is the old one, the wp.local block untouched, and this site's block after it" same \
  "$(cmp -s "$W/expected" "$W/etc/hosts" && echo same)"
check "$t: their jobs are still loaded, and nothing of theirs was asked of launchctl" "yes" \
  "$([ -e "$W/loaded/local.wp.https" ] && [ -e "$W/loaded/local.wp.loopback" ] && ! grep -q 'local\.wp' "$W/launchctl.calls" && echo yes)"
reset_calls; undo "$A"; t="beside the wp.local block and local.wp.* daemons, after undo"
check "$t: undo exits 0" 0 "$code"
check "$t: the hosts file, daemon folder, lo0 and launchd are as they were" same "$(same_as_kept but_backup)"
check "$t: the hosts file is byte-identical" same "$(cmp -s "$W/kept/etc/hosts" "$W/etc/hosts" && echo same)"
lacks "$t: ifconfig never asked about their addresses (v4)" "127.0.0.25" "$(changed_calls)"
lacks "$t: ifconfig never asked about their addresses (v6)" "fd00:b::25" "$(changed_calls)"
lacks "$t: launchctl never asked about their jobs" "local.wp" "$(changed_calls)"
mksite "$tmp/sites/clash" clash wp.local 127.0.0.25 fd00:c::5 4801 4802; keep; reset_calls; setup "$tmp/sites/clash"
refused "a site wanting wp.local and 127.0.0.25 beside them" "wp.local"
contains "a site wanting wp.local and 127.0.0.25 beside them: names the address" "127.0.0.25" "$out"
contains "a site wanting wp.local and 127.0.0.25 beside them: names their plist" "local.wp.loopback.plist" "$out"
undo "$tmp/sites/clash"; t="undo for a site wanting wp.local and 127.0.0.25"
check "$t: exits 0" 0 "$code"; check "$t: removes nothing" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
contains "$t: says the address is not its to remove" "127.0.0.25" "$out"
# A site.json that copies every one of their values (prefix, host, addresses, ports) can neither set up nor undo theirs.
forwarder_xml local.wp.http 80 127.0.0.25 fd00:b::25 4726 > "$W/LaunchDaemons/local.wp.http.plist"; touch "$W/loaded/local.wp.http"
mksite "$tmp/sites/mimic" mimic wp.local 127.0.0.25 fd00:b::25 4725 4726 '"daemon_prefix":"local.wp"'
keep; reset_calls; setup "$tmp/sites/mimic"; refused "a site.json with all of their values" "wp.local"
reset_calls; undo "$tmp/sites/mimic"; t="undo for a site.json with all of their values"
check "$t: exits 0" 0 "$code"; check "$t: removes nothing of theirs" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
contains "$t: says why" "not set up from this site folder" "$out"

# --- undo after set-up restores the start ---
world; keep; setup "$A"; reset_calls; undo "$A"; t="undo after set-up"
check "$t: exits 0" 0 "$code"
check "$t: the hosts file, daemon folder, lo0 and launchd are as they were" same "$(same_as_kept but_backup)"
check "$t: the copy from before is kept" same "$(cmp -s "$W/kept/etc/hosts" "$W/etc/hosts.before-offprint" && echo same)"
contains "$t: and says so" "hosts.before-offprint" "$out"
check "$t: takes the addresses off lo0; unloads the three" \
  "lo0 -alias 127.0.0.21|lo0 inet6 -alias fd00:a::21|bootout system/$PA.https|bootout system/$PA.http|bootout system/$PA.loopback" \
  "$(changed_calls)"
keep; reset_calls; undo "$A"; t="undo with nothing to undo"
check "$t: exits 0" 0 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
contains "$t: says so" "Nothing of this site's" "$out"
setup "$A"; keep; reset_calls; undo --print "$A"; t="undo --print"
check "$t: exits 0" 0 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
printf '%s\n' "$BLOCK_A" > "$W/want-block"
check "$t: shows the block it would remove, line by line" shown "$(shown "$W/want-block")"
contains "$t: and the plists" "$W/LaunchDaemons/$PA.https.plist" "$out"
contains "$t: and the addresses" "127.0.0.21" "$out"
contains "$t: and the line for the real run" "The real run, as root:  sudo /bin/bash '$SRCP/os/darwin/host-undo.sh' '$(cd "$A" && pwd -P)'" "$out"
SKIP_ROOT= undo "$A"; t="undo without root and without --print"
check "$t: exits 1" 1 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
contains "$t: prints the line to run" "sudo /bin/bash '$SRCP/os/darwin/host-undo.sh' '$(cd "$A" && pwd -P)'" "$out"
contains "$t: and the line to see it first, by /bin/bash too" "without root: /bin/bash '$SRCP/os/darwin/host-undo.sh' --print '$(cd "$A" && pwd -P)'" "$out"

# --- undo removes only what is this site's ---
world; lo0_add 127.0.0.21; lo0_add6 fd00:a::21; keep; undo "$A"; t="undo, with the site's addresses on lo0 but no plist of its naming them"
check "$t: exits 0" 0 "$code"; check "$t: leaves them" same "$(same_as_kept)"
contains "$t: and says so" "127.0.0.21" "$out"
world; lo0_add 127.0.0.21; lo0_add6 fd00:a::21; forwarder_xml "$PA.https" 443 127.0.0.99 fd00:a::21 4701 > "$W/LaunchDaemons/$PA.https.plist"
loopback_xml "$PA.loopback" 127.0.0.99 fd00:a::21 > "$W/LaunchDaemons/$PA.loopback.plist"; keep; undo "$A"
t="undo, with plists of the site's prefix that name another address"
check "$t: exits 0" 0 "$code"; check "$t: leaves them, and lo0" same "$(same_as_kept)"
contains "$t: and says why" "127.0.0.99" "$out"
world; setup "$A"; printf '127.0.0.21\tother.test\n' >> "$W/etc/hosts"; keep; reset_calls; undo "$A"
t="undo, with the site's address given to another name too, outside its block"
check "$t: exits 0" 0 "$code"
check "$t: removes the site's block" no "$(grep -qxF '# >>> offprint: alpha.test >>>' "$W/etc/hosts" && echo yes || echo no)"
check "$t: leaves the other line" yes "$(grep -qxF "127.0.0.21${TAB}other.test" "$W/etc/hosts" && echo yes)"
check "$t: leaves the plists" "$PA.http.plist $PA.https.plist $PA.loopback.plist" "$(ls -A "$W/LaunchDaemons" | paste -sd' ' -)"
check "$t: and the addresses" "yes yes" "$(yes_no on_lo0 127.0.0.21) $(yes_no on_lo0 fd00:a::21)"
contains "$t: says why" "other.test" "$out"
world; setup "$A"; printf '# >>> offprint: alpha.test >>>\n' >> "$W/etc/hosts"; keep; reset_calls; undo "$A"
refused "undo, with a broken block" "refusing to touch"
world; setup "$A"; printf '127.0.0.99\talpha.test\n' > "$W/line"
awk -v l="$(cat "$W/line")" '{ print } $0 == "127.0.0.21\talpha.test" { print l }' "$W/etc/hosts" > "$W/h" && cat "$W/h" > "$W/etc/hosts"
keep; reset_calls; undo "$A"; t="undo, with a line in this site's block naming another address"
check "$t: exits 0" 0 "$code"
check "$t: leaves the block" same "$(cmp -s "$W/kept/etc/hosts" "$W/etc/hosts" && echo same)"
contains "$t: says why" "127.0.0.99" "$out"
check "$t: still removes the site's plists" "" "$(ls -A "$W/LaunchDaemons")"

# --- two sites set up and undone independently ---
world; keep; cp "$W/etc/hosts" "$W/start"; setup "$A"; ca=$code; setup "$B"; t="two sites"
check "$t: both set up" "0 0" "$ca $code"
{ cat "$W/start"; printf '\n%s\n\n%s\n' "$BLOCK_A" "$BLOCK_B"; } > "$W/expected"
check "$t: both blocks" same "$(cmp -s "$W/expected" "$W/etc/hosts" && echo same)"
check "$t: six plists" 6 "$(ls -A "$W/LaunchDaemons" | wc -l | tr -d ' ')"
mkdir -p "$W/b"; cp -p "$W/LaunchDaemons/$PB".* "$W/b/"
reset_calls; undo "$A"; t="undo for site A"
check "$t: exits 0" 0 "$code"
{ cat "$W/start"; printf '\n%s\n' "$BLOCK_B"; } > "$W/expected"
check "$t: leaves B's block, and only it" same "$(cmp -s "$W/expected" "$W/etc/hosts" && echo same)"
check "$t: leaves B's plists byte-identical" same "$(diff -r "$W/b" "$W/LaunchDaemons" > /dev/null && echo same)"
check "$t: leaves B's addresses on lo0, takes A's off" "yes yes no no" \
  "$(yes_no on_lo0 127.0.0.22) $(yes_no on_lo0 fd00:b::22) $(yes_no on_lo0 127.0.0.21) $(yes_no on_lo0 fd00:a::21)"
check "$t: B's jobs still loaded" "$PB.http $PB.https $PB.loopback" "$(ls -A "$W/loaded" | paste -sd' ' -)"
lacks "$t: never asks about B's" "$PB" "$(changed_calls)"
undo "$B"; t="then undo for site B"
check "$t: exits 0" 0 "$code"; check "$t: everything is as it was" same "$(same_as_kept but_backup)"

# --- a second site sharing anything with the first is refused ---
world; setup "$A"
mksite "$tmp/sites/c1" gamma alpha.test 127.0.0.23 fd00:c::23 4721 4722; keep; reset_calls; setup "$tmp/sites/c1"
refused "a second site with the first's local_host" "alpha.test"
mksite "$tmp/sites/c2" gamma gamma.test 127.0.0.21 fd00:c::23 4721 4722; keep; reset_calls; setup "$tmp/sites/c2"
refused "a second site with the first's local_ip4" "127.0.0.21"
mksite "$tmp/sites/c3" gamma gamma.test 127.0.0.23 fd00:a::21 4721 4722; keep; reset_calls; setup "$tmp/sites/c3"
refused "a second site with the first's local_ip6" "fd00:a::21"
mksite "$tmp/sites/c4" gamma gamma.test 127.0.0.23 fd00:c::23 4701 4722; keep; reset_calls; setup "$tmp/sites/c4"
refused "a second site with the first's tls_port (its Caddy not running)" "4701"
mksite "$tmp/sites/c5" gamma gamma.test 127.0.0.23 fd00:c::23 4721 4702; keep; reset_calls; setup "$tmp/sites/c5"
refused "a second site with the first's http_port" "4702"
mksite "$tmp/sites/c6" gamma gamma.test 127.0.0.23 fd00:c::23 4721 4722 '"daemon_prefix":"local.offprint.alpha"'; keep; reset_calls; setup "$tmp/sites/c6"
refused "a second site with the first's daemon_prefix" "$PA.loopback.plist"
mksite "$tmp/sites/c7" gamma gamma.test 127.0.0.21 fd00:a::21 4721 4722 '"daemon_prefix":"local.offprint.alpha"'; keep; reset_calls; setup "$tmp/sites/c7"
refused "a second site with the first's prefix and addresses, and its own host and ports" "127.0.0.21"
undo "$tmp/sites/c7"; t="undo for that second site (which was never set up)"
check "$t: exits 0" 0 "$code"
check "$t: leaves the first site's block, plists, addresses and jobs" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"

# --- the seams, and the guard on OFFPRINT_SKIP_ROOT_CHECK ---
# Each of these is run with stand-ins that note any call, and changes nothing: the real files can't be written
# by this user anyway, and the hosts file is compared before and after.
world; keep
# raw ENV...: the script with exactly these seam variables (and the tripwires on PATH)
raw() { out="$(env PATH="$TRIP:$PATH" "$@" /bin/bash "$SRC/os/darwin/host-setup.sh" "$A" 2>&1)"; code=$?; }
seams_ok() {
  check "$1: no stand-in was called" "" "$(cat "$W/ifconfig.calls" "$W/launchctl.calls" "$W/lsof.calls")"
  check "$1: the pretend machine is untouched" same "$(same_as_kept)"
}
raw; t="no seams, not root"
check "$t: exits 1" 1 "$code"; contains "$t: prints the line to run" "sudo /bin/bash '$SRCP/os/darwin/host-setup.sh' '$(cd "$A" && pwd -P)'" "$out"
raw OFFPRINT_SKIP_ROOT_CHECK=1; t="OFFPRINT_SKIP_ROOT_CHECK=1 with no seams"
check "$t: is ignored: root is needed, exit 1" 1 "$code"; contains "$t: says so" "sudo /bin/bash" "$out"
SEAMS="OFFPRINT_IFCONFIG=$W/stubs/ifconfig OFFPRINT_LAUNCHCTL=$W/stubs/launchctl OFFPRINT_LSOF=$W/stubs/lsof OFFPRINT_SKIP_ROOT_CHECK=1"
# shellcheck disable=SC2086 # SEAMS is a list of words
raw $SEAMS OFFPRINT_HOSTS_FILE=/etc/hosts OFFPRINT_DAEMON_DIR="$W/LaunchDaemons"; t="OFFPRINT_HOSTS_FILE=/etc/hosts"
check "$t: exits 2" 2 "$code"; contains "$t: says why" "OFFPRINT_HOSTS_FILE" "$out"; seams_ok "$t"
ln -s /etc/hosts "$W/hosts-link"
# shellcheck disable=SC2086
raw $SEAMS OFFPRINT_HOSTS_FILE="$W/hosts-link" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons"; t="OFFPRINT_HOSTS_FILE a link to /etc/hosts"
check "$t: exits 2" 2 "$code"; contains "$t: says why" "OFFPRINT_HOSTS_FILE" "$out"; seams_ok "$t"
# shellcheck disable=SC2086
raw $SEAMS OFFPRINT_HOSTS_FILE="/etc/../etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons"; t="OFFPRINT_HOSTS_FILE=/etc/../etc/hosts"
check "$t: exits 2" 2 "$code"; seams_ok "$t"
# shellcheck disable=SC2086
raw $SEAMS OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR=/Library/LaunchDaemons; t="OFFPRINT_DAEMON_DIR=/Library/LaunchDaemons"
check "$t: exits 2" 2 "$code"; contains "$t: says why" "OFFPRINT_DAEMON_DIR" "$out"; seams_ok "$t"
# shellcheck disable=SC2086
raw $SEAMS OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR=/Library/LaunchDaemons/; t="OFFPRINT_DAEMON_DIR=/Library/LaunchDaemons/"
check "$t: exits 2" 2 "$code"; seams_ok "$t"
# shellcheck disable=SC2086
raw $SEAMS OFFPRINT_HOSTS_FILE="$W/etc/hosts"; t="OFFPRINT_HOSTS_FILE without OFFPRINT_DAEMON_DIR"
check "$t: exits 2" 2 "$code"; contains "$t: names the missing one" "OFFPRINT_DAEMON_DIR" "$out"; seams_ok "$t"
for v in IFCONFIG LAUNCHCTL LSOF; do
  set -- OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" OFFPRINT_SKIP_ROOT_CHECK=1
  for u in IFCONFIG LAUNCHCTL LSOF; do [ "$u" = "$v" ] || set -- "$@" "OFFPRINT_$u=$W/stubs/$(echo "$u" | tr 'A-Z' 'a-z')"; done
  raw "$@"; t="the hosts and daemon seams without OFFPRINT_$v"
  check "$t: exits 2" 2 "$code"; contains "$t: names it" "OFFPRINT_$v" "$out"; seams_ok "$t"
done
raw OFFPRINT_IFCONFIG="$W/stubs/ifconfig" OFFPRINT_SKIP_ROOT_CHECK=1; t="OFFPRINT_IFCONFIG alone"
check "$t: exits 2" 2 "$code"; seams_ok "$t"
# shellcheck disable=SC2086
raw $SEAMS OFFPRINT_HOSTS_FILE="$W/nothing" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons"; t="OFFPRINT_HOSTS_FILE that does not exist"
check "$t: exits 2" 2 "$code"; seams_ok "$t"
out="$(env PATH="$TRIP:$PATH" /bin/bash "$SRC/os/darwin/host-undo.sh" "$A" 2>&1)"; code=$?; t="undo with no seams, not root"
check "$t: exits 1" 1 "$code"; contains "$t: prints the line to run" "sudo /bin/bash '$SRCP/os/darwin/host-undo.sh'" "$out"; seams_ok "$t"
# shellcheck disable=SC2086
out="$(env PATH="$TRIP:$PATH" $SEAMS OFFPRINT_HOSTS_FILE=/etc/hosts OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" /bin/bash "$SRC/os/darwin/host-undo.sh" "$A" 2>&1)"; code=$?
t="undo with OFFPRINT_HOSTS_FILE=/etc/hosts"; check "$t: exits 2" 2 "$code"; seams_ok "$t"

# --- the site's names are checked again by the script itself, before any use ---
# A stand-in php prints what lib/config.php would never print; the script refuses (exit 2), naming the value.
world; keep; mkdir -p "$W/phpbin"
good="SITE_NAME${TAB}alpha
SITE_PUBLIC_URL${TAB}https://alpha.example.com
SITE_PUBLIC_HOST${TAB}alpha.example.com
SITE_LOCAL_HOST${TAB}alpha.test
SITE_IP4${TAB}127.0.0.21
SITE_IP6${TAB}fd00:a::21
SITE_TLS_PORT${TAB}4701
SITE_HTTP_PORT${TAB}4702
SITE_AGENT_LABEL${TAB}local.offprint.alpha.publish
SITE_DAEMON_PREFIX${TAB}local.offprint.alpha"
# fake_php KEY VALUE: the good lines with KEY's value replaced (VALUE "-" drops the line)
# (php -r, which works out the stamp, goes to the real php)
REAL_PHP="$(command -v php)"
fake_php() {
  printf '%s\n' "$good" | awk -F "$TAB" -v k="$1" -v v="$2" 'BEGIN { OFS = FS } $1 == k { if (v == "-") next; $2 = v } { print }' > "$W/php.out"
  printf '#!/bin/sh\n[ "$1" = -r ] && exec "%s" "$@"\ncat "%s"\n' "$REAL_PHP" "$W/php.out" > "$W/phpbin/php"; chmod +x "$W/phpbin/php"
}
while IFS='|' read -r key value field; do
  fake_php "$key" "$value"; XPATH="$W/phpbin" setup "$A"; t="a $field of '$value' from lib/config.php"
  check "$t: exits 2" 2 "$code"; contains "$t: names it" "$field" "$out"
  check "$t: changes nothing" same "$(same_as_kept)"; check "$t: asks nothing that changes anything" "" "$(changed_calls)"
done <<'CASES'
SITE_LOCAL_HOST|a.b;id|local_host
SITE_LOCAL_HOST|$(id).x|local_host
SITE_LOCAL_HOST|nodot|local_host
SITE_LOCAL_HOST|-|local_host
SITE_IP4|127.0.0.1|local_ip4
SITE_IP4|10.0.0.1|local_ip4
SITE_IP4|127.0.0.256|local_ip4
SITE_IP4|127.0.0.05|local_ip4
SITE_IP6|fd00::9 x|local_ip6
SITE_IP6|::1|local_ip6
SITE_IP6|FD00::9|local_ip6
SITE_TLS_PORT|80|tls_port
SITE_TLS_PORT|70000|tls_port
SITE_TLS_PORT|4702|http_port
SITE_HTTP_PORT|04702|http_port
SITE_DAEMON_PREFIX|../evil|daemon_prefix
SITE_DAEMON_PREFIX|a/b|daemon_prefix
SITE_DAEMON_PREFIX|-x|daemon_prefix
SITE_NAME|Alpha|name
CASES
printf '%s\nEVIL%sx\nSITE_EXTRA%sy\n' "$good" "$TAB" "$TAB" > "$W/php.out"; XPATH="$W/phpbin" setup --print "$A"; t="other lines from lib/config.php"
check "$t: are ignored" 0 "$code"
# The real lib/config.php refuses a bad site.json: so does the script, with its message.
mksite "$tmp/sites/badhost" bad "bad host.test" 127.0.0.31 fd00:d::31 4731 4732; setup "$tmp/sites/badhost"; t="a site.json lib/config.php refuses"
check "$t: exits 2" 2 "$code"; contains "$t: with its message" 'site.json: "local_host"' "$out"; check "$t: changes nothing" same "$(same_as_kept)"
mkdir -p "$tmp/sites/nosite"; setup "$tmp/sites/nosite"; t="a folder with no site.json"
check "$t: exits 2" 2 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
setup; check "no site folder given: usage, exit 2" 2 "$code"
contains "no site folder given: the usage names /bin/bash, for the run as root" "usage: sudo /bin/bash '$SRCP/os/darwin/host-setup.sh' [--adopt] SITE_DIR" "$out"
contains "no site folder given: and for --print" "       /bin/bash '$SRCP/os/darwin/host-setup.sh' --print [--adopt] SITE_DIR" "$out"
setup "$A" "$B"; check "two site folders given: usage, exit 2" 2 "$code"
setup --bogus "$A"; check "an unknown option: usage, exit 2" 2 "$code"
# Without php on PATH (here a PATH holding only the other tools the scripts use), it says so.
minbin="$tmp/minbin"; mkdir -p "$minbin"
# (find: lib/site.sh's offprint_private_dir reads the working folder's mode with it.)
for c in awk basename cat chmod cmp cp cut dirname find grep head id mkdir mktemp mv paste rm sed sleep sort tr uname wc; do
  p="$(command -v "$c")" && ln -s "$p" "$minbin/$c"
done
out="$(PATH="$TRIP:$minbin" OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" OFFPRINT_IFCONFIG="$W/stubs/ifconfig" \
  OFFPRINT_LAUNCHCTL="$W/stubs/launchctl" OFFPRINT_LSOF="$W/stubs/lsof" OFFPRINT_SKIP_ROOT_CHECK=1 /bin/bash "$SRC/os/darwin/host-setup.sh" "$A" 2>&1)"; code=$?
t="php not on PATH"; check "$t: exits 2" 2 "$code"; contains "$t: says so" "php is not on" "$out"; check "$t: changes nothing" same "$(same_as_kept)"
contains "$t: gives the line to run with php's folder on PATH" "\$PATH\" /bin/bash '$SRCP/os/darwin/host-setup.sh' '$(phys_dir "$A")'" "$out"
out="$(PATH="$TRIP:$minbin" OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" OFFPRINT_IFCONFIG="$W/stubs/ifconfig" \
  OFFPRINT_LAUNCHCTL="$W/stubs/launchctl" OFFPRINT_LSOF="$W/stubs/lsof" OFFPRINT_SKIP_ROOT_CHECK=1 /bin/bash "$SRC/os/darwin/host-setup.sh" --adopt "$A" 2>&1)"; code=$?
t="php not on PATH, with --adopt"; check "$t: exits 2" 2 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
contains "$t: the line to run keeps --adopt" "\$PATH\" /bin/bash '$SRCP/os/darwin/host-setup.sh' --adopt '$(phys_dir "$A")'" "$out"

# --- offprint host-setup / host-undo ---
# A site folder whose path has a space, a quote, an ampersand and a dollar sign: the printed line must paste as is.
S1="$tmp/sites/My Sites/it's a&b \$HOME"; mksite "$S1" delta delta.test 127.0.0.41 fd00:e::41 4741 4742; S1P="$(cd "$S1" && pwd -P)"
world; keep
# offprint ARGS...: bin/offprint for the site S1, with every seam set (so a run that should only print, but ran,
# would show as a change)
offprint() {
  out="$(cd "$S1" && env -u OFFPRINT_SITE PATH="$TRIP:$PATH" OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" \
    OFFPRINT_IFCONFIG="$W/stubs/ifconfig" OFFPRINT_LAUNCHCTL="$W/stubs/launchctl" OFFPRINT_LSOF="$W/stubs/lsof" \
    OFFPRINT_SKIP_ROOT_CHECK=1 /bin/bash "$SRC/bin/offprint" "$@" 2>&1)"; code=$?
}
for job in host-setup host-undo; do
  offprint "$job"; t="offprint $job, not root"
  check "$t: exits 1" 1 "$code"
  check "$t: changes nothing" same "$(same_as_kept)"; check "$t: asks nothing at all" "" "$(cat "$W/ifconfig.calls" "$W/launchctl.calls")"
  line="$(printf '%s\n' "$out" | grep -E '^ *sudo ' | head -1)"
  check "$t: prints the exact line to run" "sudo /bin/bash '$SRCP/os/darwin/$job.sh' '$(printf '%s' "$S1P" | sed "s/'/'\\\\''/g")'" "$(printf '%s' "$line" | sed 's/^ *//')"
  got="$(sudo() { printf '%s\n' "$@"; }; eval "$line")"
  check "$t: which pastes into a shell as exactly three words" "$(printf '%s\n' /bin/bash "$SRCP/os/darwin/$job.sh" "$S1P")" "$got"
done
offprint host-setup --print; t="offprint host-setup --print"
check "$t: exits 0" 0 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
contains "$t: shows the plists in full" "<key>Label</key><string>local.offprint.delta.https</string>" "$out"
contains "$t: and the hosts block" "# >>> offprint: delta.test >>>" "$out"
offprint host-undo --print; t="offprint host-undo --print"
check "$t: exits 0" 0 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
offprint host-setup --bogus; check "offprint host-setup --bogus: usage, exit 2" 2 "$code"
offprint host-setup "$A"; check "offprint host-setup with a folder: usage, exit 2 (the site is the one it is run in)" 2 "$code"
check "offprint host-setup with bad arguments: changes nothing" same "$(same_as_kept)"
mkdir -p "$tmp/nosite"
out="$(cd "$tmp/nosite" && env -u OFFPRINT_SITE PATH="$TRIP:$PATH" /bin/bash "$SRC/bin/offprint" host-setup 2>&1)"; code=$?; t="offprint host-setup outside any site folder"
check "$t: exits 2" 2 "$code"; contains "$t: says so" "Not in an Offprint site folder" "$out"

# --- a set-up belongs to the site folder it was made from: its stamp ---
# P1: a second site with the first's local_host, addresses and daemon_prefix, but its own name and ports.
world; setup "$A"; keep; reset_calls
mksite "$tmp/sites/p1" pone alpha.test 127.0.0.21 fd00:a::21 4791 4792 '"daemon_prefix":"local.offprint.alpha"'
setup "$tmp/sites/p1"; refused "P1: a site with the first's host, addresses and prefix, and its own ports" "set up from a different site folder"
contains "P1: names the first's relay" "$PA.https.plist" "$out"
reset_calls; undo "$tmp/sites/p1"; t="P1: undo for that site"
check "$t: exits 0" 0 "$code"; check "$t: leaves the first site's everything" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
contains "$t: says why" "not set up from this site folder" "$out"
# P1b: a plain copy of the first site's folder, beside it.
cp -R "$A" "$tmp/sites/alpha-copy"; reset_calls; setup "$tmp/sites/alpha-copy"
refused "P1b: a copy of the site folder" "set up from a different site folder"
contains "P1b: says what to do if it is the same site, moved" "--adopt" "$out"
reset_calls; undo "$tmp/sites/alpha-copy"; t="P1b: undo in the copy"
check "$t: exits 0" 0 "$code"; check "$t: leaves the first site's block, plists and addresses" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"
reset_calls; setup "$A"; t="P1b: the first site, run again"
check "$t: exits 0" 0 "$code"; check "$t: still nothing to change" same "$(same_as_kept)"; check "$t: asks nothing" "" "$(changed_calls)"
# P6: someone else's loopback job, in another shape, naming the same aliases; nothing in the hosts file.
world; lo0_add 127.0.0.9; lo0_add6 fd00:9::9
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>com.vendor.thing.loopback</string><key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>ifconfig lo0 alias 127.0.0.9; ifconfig lo0 inet6 alias fd00:9::9 prefixlen 128; /usr/local/bin/thing</string></array><key>KeepAlive</key><true/></dict></plist>\n' \
  > "$W/LaunchDaemons/com.vendor.thing.loopback.plist"
touch "$W/loaded/com.vendor.thing.loopback"
mksite "$tmp/sites/p6" thing thing.test 127.0.0.9 fd00:9::9 4795 4796 '"daemon_prefix":"com.vendor.thing"'
keep; setup "$tmp/sites/p6"; refused "P6: a site.json copying a vendor job's prefix and aliases" "com.vendor.thing.loopback.plist"
contains "P6: says it was not Offprint's, or not this folder's" "not by Offprint" "$out"
reset_calls; undo "$tmp/sites/p6"; t="P6: undo for it"
check "$t: exits 0" 0 "$code"; check "$t: leaves the vendor's job and aliases" same "$(same_as_kept)"
check "$t: asks nothing that changes anything" "" "$(changed_calls)"

# --- a site folder that was moved: refused without --adopt; re-stamped with it; then undone from the new folder ---
world; keep; mv "$W/kept" "$W/kept0"
mksite "$tmp/sites/mv-from" moved moved.test 127.0.0.51 fd00:f::51 4751 4752; SF="$(stamp_of "$tmp/sites/mv-from")"
setup "$tmp/sites/mv-from"; t="a moved site folder"; check "$t: set up in the old folder" 0 "$code"
mv "$tmp/sites/mv-from" "$tmp/sites/mv-to"; ST="$(stamp_of "$tmp/sites/mv-to")"; PM=local.offprint.moved
keep; reset_calls; setup "$tmp/sites/mv-to"; refused "$t: set-up from the new folder, without --adopt" "--adopt"
setup --print --adopt "$tmp/sites/mv-to"; t="a moved site folder: --print --adopt"
check "$t: exits 0" 0 "$code"; check "$t: changes nothing" same "$(same_as_kept)"; check "$t: asks nothing that changes anything" "" "$(changed_calls)"
contains "$t: shows the re-stamping" "re-stamp" "$out"
check "$t: shows the new stamp in each plist" 3 "$(printf '%s\n' "$out" | grep -cxE " *<!-- offprint site $ST -->")"
check "$t: and in the block" 1 "$(printf '%s\n' "$out" | grep -cxE " *# site $ST")"
reset_calls; setup --adopt "$tmp/sites/mv-to"; t="a moved site folder: --adopt"
check "$t: exits 0" 0 "$code"
for k in loopback https http; do
  check "$t: $k carries the new folder's stamp" "<!-- offprint site $ST -->" "$(grep 'offprint site' "$W/LaunchDaemons/$PM.$k.plist")"
done
check "$t: so does the block" "# site $ST" "$(awk '$0 == "# >>> offprint: moved.test >>>" { getline; print }' "$W/etc/hosts")"
check "$t: the old stamp is gone" no "$(grep -rqF "$SF" "$W/etc/hosts" "$W/LaunchDaemons" && echo yes || echo no)"
check "$t: no address added or job reloaded" "" "$(changed_calls)"
keep; reset_calls; setup "$tmp/sites/mv-to"; t="a moved site folder: run again after --adopt"
check "$t: exits 0" 0 "$code"; check "$t: nothing to change" same "$(same_as_kept)"; check "$t: asks nothing" "" "$(changed_calls)"
undo "$tmp/sites/mv-to"; t="a moved site folder: undo from the new folder"
rm -rf "$W/kept"; mv "$W/kept0" "$W/kept"
check "$t: exits 0" 0 "$code"; check "$t: removes everything: back to the start" same "$(same_as_kept but_backup)"
# --adopt takes over only what matches this site.json exactly
world; setup "$A"; mv "$A" "$tmp/sites/alpha-moved"
mksite "$tmp/sites/alpha-moved" alpha alpha.test 127.0.0.21 fd00:a::21 4709 4702
keep; reset_calls; setup --adopt "$tmp/sites/alpha-moved"; refused "--adopt, with a relay that differs from what site.json would write" "differs"
mv "$tmp/sites/alpha-moved" "$A"; mksite "$A" alpha alpha.test 127.0.0.21 fd00:a::21 4701 4702

# --- P8: a job with this site's label, loaded from someone else's plist ---
world; printf '<plist version="1.0"><dict><key>Label</key><string>com.vendor.http</string></dict></plist>\n' > "$W/LaunchDaemons/org.vendor-webhelper.plist"
touch "$W/loaded/com.vendor.http"
mksite "$tmp/sites/p8" webhelp webhelp.test 127.0.0.58 fd00:8::58 4758 4759 '"daemon_prefix":"com.vendor"'
keep; setup "$tmp/sites/p8"; refused "P8: a loaded job with this site's label and no plist of this site's" "com.vendor.http"
check "P8: launchctl was never asked to boot anything out" "" "$(grep '^bootout' "$W/launchctl.calls")"
setup --print "$tmp/sites/p8"; check "P8: --print says it would refuse" 1 "$code"; contains "P8: --print names the label" "com.vendor.http" "$out"
# --print shows a bootout exactly when one will happen
world; setup "$A"; mksite "$A" alpha alpha.test 127.0.0.21 fd00:a::21 4703 4702
setup --print "$A"; t="--print, replacing this site's loaded relay"
contains "$t: shows the bootout" "launchctl bootout system/$PA.https" "$out"; lacks "$t: and none for the unchanged one" "bootout system/$PA.http " "$out"
rm "$W/loaded/$PA.https"; setup --print "$A"; t="--print, replacing this site's relay that is not loaded"
lacks "$t: shows no bootout" "bootout" "$out"
mksite "$A" alpha alpha.test 127.0.0.21 fd00:a::21 4701 4702

# --- a set-up that stops part way leaves a state that set-up and undo both know as this site's ---
# P4a: the inet6 alias fails after the inet one was added.
world; keep; touch "$W/fail-alias6"; setup "$A"; t="P4a: the inet6 alias fails"
check "$t: exits 1" 1 "$code"
contains "$t: says what was done: the loopback plist" "wrote $W/LaunchDaemons/$PA.loopback.plist" "$out"
contains "$t: and the inet alias" "added 127.0.0.21 to lo0" "$out"
contains "$t: and how to reverse it" "host-undo" "$out"
contains "$t: with the line to run, by /bin/bash" "sudo /bin/bash '$SRCP/os/darwin/host-undo.sh' '$(cd "$A" && pwd -P)'" "$out"
check "$t: the loopback plist was in place before ifconfig ran" yes "$([ -f "$W/LaunchDaemons/$PA.loopback.plist" ] && on_lo0 127.0.0.21 && echo yes)"
rm "$W/fail-alias6"; reset_calls; undo "$A"; t="P4a: then undo"
check "$t: exits 0" 0 "$code"; check "$t: back to the start" same "$(same_as_kept but_backup)"
world; keep; touch "$W/fail-alias6"; setup "$A"; rm "$W/fail-alias6"; setup "$A"; t="P4a: then set-up again"
check "$t: exits 0" 0 "$code"; check "$t: finishes: both addresses on lo0" "yes yes" "$(yes_no on_lo0 127.0.0.21) $(yes_no on_lo0 fd00:a::21)"
undo "$A"; check "$t, then undo: back to the start" same "$(same_as_kept but_backup)"
# P4d: the daemon folder can't be written to: from the start (nothing done), or after the loopback job is loaded.
world; keep; chmod 555 "$W/LaunchDaemons"; setup "$A"; chmod 755 "$W/LaunchDaemons"; t="P4d: a daemon folder it can't write to"
check "$t: exits 1" 1 "$code"; contains "$t: says nothing was changed" "Nothing was changed" "$out"
check "$t: and nothing was" same "$(same_as_kept)"; check "$t: asks nothing that changes anything" "" "$(changed_calls)"
world; keep; touch "$W/ro-after-loopback"; setup "$A"; chmod 755 "$W/LaunchDaemons"; rm "$W/ro-after-loopback"; t="P4d: the relay can't be written, after the rest"
check "$t: exits 1" 1 "$code"
for done_line in "wrote $W/LaunchDaemons/$PA.loopback.plist" "added 127.0.0.21 to lo0" "added fd00:a::21 to lo0" "loaded $PA.loopback" "wrote $W/etc/hosts"; do
  contains "$t: lists what was done: $done_line" "$done_line" "$out"
done
reset_calls; undo "$A"; t="P4d: then undo"
check "$t: exits 0" 0 "$code"; check "$t: back to the start" same "$(same_as_kept but_backup)"
world; keep; touch "$W/ro-after-loopback"; setup "$A"; chmod 755 "$W/LaunchDaemons"; rm "$W/ro-after-loopback"; setup "$A"; t="P4d: then set-up again"
check "$t: exits 0" 0 "$code"; check "$t: finishes: three plists" 3 "$(ls -A "$W/LaunchDaemons" | wc -l | tr -d ' ')"
undo "$A"; check "$t, then undo: back to the start" same "$(same_as_kept but_backup)"

# --- reads that fail are refusals, before any change ---
world; keep; chmod 000 "$W/etc/hosts"; setup "$A"; chmod 644 "$W/etc/hosts"; refused "a hosts file it can't read" "$W/etc/hosts"
chmod 000 "$W/etc/hosts"; undo "$A"; chmod 644 "$W/etc/hosts"; check "undo with a hosts file it can't read: exits 1" 1 "$code"
world; keep; touch "$W/fail-read"; setup "$A"; refused "ifconfig lo0 failing" "lo0"
undo "$A"; check "undo with ifconfig lo0 failing: exits 1" 1 "$code"
world; keep; echo 2 > "$W/fail-lsof"; setup "$A"; refused "lsof failing (exit 2)" "lsof"
world; keep; echo 1 > "$W/fail-lsof"; setup "$A"; refused "lsof failing (exit 1, with an error)" "lsof"
world; keep; touch "$W/fail-print"; setup "$A"; refused "launchctl print failing" "launchctl"

# --- CRLF lines are read like any other ---
world; printf '10.1.2.3\talpha.test\r\n' >> "$W/etc/hosts"; keep; setup "$A"; refused "a CRLF line naming local_host" "alpha.test"
world; printf '127.0.0.21 other.test\r\n' >> "$W/etc/hosts"; keep; setup "$A"; refused "a CRLF line with local_ip4" "other.test"

# --- a hosts file with no newline at its end ---
world; printf '127.0.0.1\tlocalhost\n::1\tlocalhost' > "$W/etc/hosts"; keep; setup --print "$A"; t="no newline at the end of the hosts file"
NOTE="# (offprint added the newline at the end of the line before this block)"
contains "$t: --print shows the note it adds" "$NOTE" "$out"
setup "$A"; check "$t: set-up exits 0" 0 "$code"
{ cat "$W/kept/etc/hosts"; printf '\n# >>> offprint: alpha.test >>>\n# site %s\n%s\n127.0.0.21\talpha.test\nfd00:a::21\talpha.test\n# <<< offprint: alpha.test <<<\n' "$SA" "$NOTE"; } > "$W/expected"
check "$t: the block follows on the next line, with the note" same "$(cmp -s "$W/expected" "$W/etc/hosts" && echo same)"
cp -p "$W/etc/hosts" "$W/after-first"; reset_calls; setup "$A"
check "$t: a second set-up changes nothing" same "$(cmp -s "$W/after-first" "$W/etc/hosts" && echo same)"
check "$t: and asks nothing" "" "$(changed_calls)"
undo "$A"; check "$t: undo restores it byte for byte" same "$(cmp -s "$W/kept/etc/hosts" "$W/etc/hosts" && echo same)"
check "$t: and everything else" same "$(same_as_kept but_backup)"

# --- with the seams in use, the scripts say so first and last ---
SEAMLINE="test seams in use: this Mac was not changed"
world; setup "$A"; t="seams in use: a set-up"
check "$t: first line" "$SEAMLINE" "$(printf '%s\n' "$out" | head -1)"; check "$t: last line" "$SEAMLINE" "$(printf '%s\n' "$out" | tail -1)"
lo0_add 127.0.0.22; setup "$B"; t="seams in use: a refusal"
check "$t: first line" "$SEAMLINE" "$(printf '%s\n' "$out" | head -1)"; check "$t: last line" "$SEAMLINE" "$(printf '%s\n' "$out" | tail -1)"
undo --print "$A"; t="seams in use: undo --print"
check "$t: first line" "$SEAMLINE" "$(printf '%s\n' "$out" | head -1)"; check "$t: last line" "$SEAMLINE" "$(printf '%s\n' "$out" | tail -1)"
out="$(PATH="$TRIP:$PATH" /bin/bash "$SRC/os/darwin/host-setup.sh" "$A" 2>&1)"; t="no seams"
lacks "$t: no such line" "$SEAMLINE" "$out"

# --- offprint host-setup --adopt ---
world; keep
offprint host-setup --adopt; t="offprint host-setup --adopt, not root"
check "$t: exits 1" 1 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
line="$(printf '%s\n' "$out" | grep -E '^ *sudo ' | head -1)"
got="$(sudo() { printf '%s\n' "$@"; }; eval "$line")"
check "$t: the line to run passes --adopt" "$(printf '%s\n' /bin/bash "$SRCP/os/darwin/host-setup.sh" --adopt "$S1P")" "$got"
offprint host-setup --print --adopt; t="offprint host-setup --print --adopt"
check "$t: exits 0" 0 "$code"; check "$t: changes nothing" same "$(same_as_kept)"
offprint host-undo --adopt; check "offprint host-undo --adopt: usage, exit 2" 2 "$code"
undo --adopt "$A"; check "host-undo.sh --adopt: usage, exit 2" 2 "$code"

# --- F1: on a disk that ignores case, a site folder reached by a name in another case is the same folder: one stamp ---
touch "$tmp/CaseProbe"
if [ -e "$tmp/caseprobe" ]; then
  CS="$tmp/sites/CaseSite"; cs="$tmp/sites/casesite"; mksite "$CS" casey casey.test 127.0.0.71 fd00:c5::71 4771 4772; SCS="$(stamp_of "$CS")"
  check "F1: casesite and CaseSite have one stamp" "$SCS" "$(stamp_of "$cs")"
  world; keep; mv "$W/kept" "$W/kept0"; setup "$CS"; t="F1: a site folder named in another case"
  check "$t: set up as CaseSite" 0 "$code"
  keep; reset_calls; setup "$cs"
  check "$t: set-up as casesite: exits 0" 0 "$code"; check "$t: nothing to change" same "$(same_as_kept)"
  check "$t: asks nothing that changes anything" "" "$(changed_calls)"; lacks "$t: suggests no --adopt" "--adopt" "$out"
  setup --print "$cs"; contains "$t: --print shows the folder's own stamp" "This site folder's stamp: $SCS" "$out"
  IN="$cs" setup .; t="F1: run from a shell whose folder was entered as casesite, given ."
  check "$t: exits 0" 0 "$code"; check "$t: nothing to change" same "$(same_as_kept)"; check "$t: asks nothing" "" "$(changed_calls)"
  IN="$cs" undo .; t="F1: undo from there"
  rm -rf "$W/kept"; mv "$W/kept0" "$W/kept"
  check "$t: exits 0" 0 "$code"; lacks "$t: does not say there is nothing to remove" "Nothing of this site's" "$out"
  check "$t: removes everything: back to the start" same "$(same_as_kept but_backup)"
else
  skip "F1: a site folder named in another case (this disk minds case)"
fi

# --- F2: an --adopt that stops part way says plainly how to finish; then it can be finished, and undone ---
world; keep; mv "$W/kept" "$W/kept0"
mksite "$tmp/sites/ad-from" adopted adopted.test 127.0.0.81 fd00:ad::81 4781 4782; SAF="$(stamp_of "$tmp/sites/ad-from")"
setup "$tmp/sites/ad-from"; mv "$tmp/sites/ad-from" "$tmp/sites/ad-to"; AT="$(phys_dir "$tmp/sites/ad-to")"; PAD=local.offprint.adopted
rm -f "$W/loaded/"*; touch "$W/ro-after-loopback"; setup --adopt "$tmp/sites/ad-to"; chmod 755 "$W/LaunchDaemons"; rm "$W/ro-after-loopback"
t="F2: an --adopt that stops part way"
check "$t: exits 1" 1 "$code"
contains "$t: lists what was re-stamped" "wrote $W/LaunchDaemons/$PAD.loopback.plist" "$out"
contains "$t: says the rest still carries the old folder's stamp" "the old folder's stamp" "$out"
contains "$t: and that what it loaded is listed too" "loaded $PAD.loopback" "$out"
contains "$t: so says only the files it wrote carry the new stamp" 'The files it wrote (the "wrote" lines above) now carry this folder'"'"'s stamp' "$out"
lacks "$t: not that everything listed does" "what is listed above now carries" "$out"
contains "$t: says to finish with --adopt, with the line to run" "sudo /bin/bash '$SRCP/os/darwin/host-setup.sh' --adopt '$AT'" "$out"
lacks "$t: does not offer a plain re-run as the way on" "host-setup run again finishes" "$out"
lacks "$t: nor host-undo as the way back" "host-undo.sh" "$out"
check "$t: the https relay does still carry the old folder's stamp" "<!-- offprint site $SAF -->" "$(grep 'offprint site' "$W/LaunchDaemons/$PAD.https.plist")"
setup "$tmp/sites/ad-to"; check "$t: as it says, a plain re-run is refused" 1 "$code"
setup --adopt "$tmp/sites/ad-to"; t="F2: then --adopt again"
check "$t: finishes" 0 "$code"
check "$t: every plist carries the new folder's stamp" 3 "$(grep -l "offprint site $(stamp_of "$tmp/sites/ad-to")" "$W/LaunchDaemons/$PAD".*.plist | wc -l | tr -d ' ')"
undo "$tmp/sites/ad-to"; rm -rf "$W/kept"; mv "$W/kept0" "$W/kept"; t="F2: then undo from the new folder"
check "$t: exits 0" 0 "$code"; check "$t: back to the start" same "$(same_as_kept but_backup)"

# --- F3: undo leaves the plists and addresses when another line of the hosts file has the site's address ---
world; cp "$W/etc/hosts" "$W/start"; setup "$A"; printf '127.0.0.21 other.test\n' >> "$W/etc/hosts"
mkdir -p "$W/a-plists"; cp -p "$W/LaunchDaemons/"* "$W/a-plists/"; reset_calls; undo "$A"
t="F3: undo, with A's own address given to other.test outside its block"
check "$t: exits 0" 0 "$code"
{ cat "$W/start"; printf '127.0.0.21 other.test\n'; } > "$W/expected"
check "$t: removes A's block; the other line is untouched" same "$(cmp -s "$W/expected" "$W/etc/hosts" && echo same)"
check "$t: leaves the three plists byte-identical" same "$(diff -r "$W/a-plists" "$W/LaunchDaemons" > /dev/null && echo same)"
check "$t: leaves both addresses on lo0" "yes yes" "$(yes_no on_lo0 127.0.0.21) $(yes_no on_lo0 fd00:a::21)"
check "$t: asks nothing of launchctl or ifconfig" "" "$(changed_calls)"
for k in https http loopback; do
  contains "$t: says why it leaves $k" "$W/LaunchDaemons/$PA.$k.plist: $W/etc/hosts has this site's addresses outside its block too (127.0.0.21 other.test), so they are not this site's alone" "$out"
done

# === TMPDIR inside the site folder: refused before anything is made ===
# host-setup.sh and host-undo.sh take the site folder as their argument and make a working folder in TMPDIR (as root,
# but for --print), from which the hosts file and the plists are written. One inside the site folder, where WordPress
# can write (var/inbox, wp-content/), could be swapped for a link, and those files written through it. So such a TMPDIR
# (compared on disk: the site folder itself, another letter case where the disk ignores it, through a link) is refused,
# in one line, exit 2, before anything is made: TMPDIR's folder as it was, a link planted there pointing outside left
# alone, the pretend machine unchanged. (TMPDIR is checked once host_tmpdir has had its say, after the seams are read:
# so here, with the seams in use, the one line comes between the two lines that say so, as for any refusal.)
world; G="$tmp/sites/gamma"; mksite "$G" gamma gamma.test 127.0.0.23 fd00:c::23 4721 4722; mkdir -p "$G/var/inbox"
echo victim > "$tmp/victim"; ln -s "$tmp/victim" "$G/var/inbox/planted"; ln -s "$G/var/inbox" "$tmp/via-inbox"
GP="$(phys_dir "$G")"; keep
for spec in "$G/var/inbox|in var/inbox" "$G|the site folder itself" "$tmp/sites/GAMMA/var/inbox|in another letter case" "$tmp/via-inbox|through a link to var/inbox"; do
  where="${spec%%|*}"; how="${spec#*|}"
  if ! [ "$where" -ef "$G/var/inbox" -o "$where" -ef "$G" ]; then skip "TMPDIR $how (this disk has no such path)"; continue; fi
  before="$(ls -A "$where")"
  for s in host-setup.sh host-undo.sh; do
    for p in "" --print; do
      TMPDIR="$where" host "$s" ${p:+"$p"} "$G"; t="$s${p:+ $p}, TMPDIR $how"
      check "$t: refused, in one line (between the seams' first and last), exit 2" \
        "2|$SEAMLINE
TMPDIR is $where, inside the site folder $GP, which WordPress can write; unset TMPDIR, or point it at a folder outside the site folder.
$SEAMLINE" "$code|$out"
      check "$t: nothing made: TMPDIR's folder as it was, the link's target untouched, the pretend machine unchanged" \
        "$before|victim|same|" "$(ls -A "$where")|$(cat "$tmp/victim")|$(same_as_kept)|$(changed_calls)"
    done
  done
done
# The swap itself, made certain: a stand-in mktemp makes the folder it is asked for, then puts a link in its place (to
# a folder outside, as a writer of TMPDIR could). TMPDIR inside the site folder: refused before mktemp runs. TMPDIR
# elsewhere (where no one else can write, so the swap here is one no one could make): the working folder must be a real
# folder of this user's, with no access for group or others, or nothing goes on; nothing is written through the link.
mkdir -p "$tmp/mk" "$tmp/swapped-to" "$tmp/tmpd"; chmod 755 "$tmp/swapped-to"
printf '#!/bin/sh\nmade="$(/usr/bin/mktemp "$@")" || exit $?\necho "$*" >> "%s/mktemp.calls"\nif [ "$1" = -d ]; then rm -rf "$made"; ln -s "%s" "$made"; fi\nprintf "%%s\\n" "$made"\n' \
  "$tmp" "$tmp/swapped-to" > "$tmp/mk/mktemp"; chmod +x "$tmp/mk/mktemp"
for s in host-setup.sh host-undo.sh; do
  rm -f "$tmp/mktemp.calls"; TMPDIR="$G/var/inbox" XPATH="$tmp/mk" host "$s" --print "$G"; t="$s --print, TMPDIR in var/inbox, its working folder swapped for a link"
  check "$t: refused before mktemp ran" "2|no" "$code|$(yes_no test -e "$tmp/mktemp.calls")"
  TMPDIR="$tmp/tmpd" XPATH="$tmp/mk" host "$s" --print "$G"; t="$s --print, TMPDIR elsewhere, its working folder swapped for a link"
  check "$t: refused, saying why" "2|${s%.sh}: can't make a temporary folder: the folder made in TMPDIR isn't a private folder of this user's (a real folder, with no access for group or others)." \
    "$code|$(printf '%s\n' "$out" | grep -v '^test seams in use')"
  check "$t: nothing written through the link, nothing left in TMPDIR, the pretend machine unchanged" "||same" "$(ls -A "$tmp/swapped-to")|$(ls -A "$tmp/tmpd")|$(same_as_kept)"
  check "$t: the folder the link names keeps its mode (no chmod through the link)" "$tmp/swapped-to" "$(find "$tmp/swapped-to" -maxdepth 0 -perm 755)"
done
# A TMPDIR elsewhere, and one holding the site folder (as this suite's temp folder does): unchanged.
for where in "$tmp/tmpd" "$tmp"; do
  TMPDIR="$where" SKIP_ROOT= setup --print "$G"; t="host-setup.sh --print, TMPDIR $where (outside the site folder, or holding it)"
  check "$t: works as ever, and leaves nothing in TMPDIR" "0|yes|" "$code|$(printf '%s' "$out" | grep -qF "ifconfig lo0 alias 127.0.0.23 up" && echo yes)|$(ls -A "$tmp/tmpd")"
done

# A copy of the scripts with no lib/site.sh beside them (a copy of Offprint that isn't whole): refused in one line, exit
# 2, before anything else runs, with or without --print (under all five seams, as ever).
mkdir -p "$tmp/partial/os"; cp -R "$SRC/os/darwin" "$tmp/partial/os/darwin"; PT="$(cd "$tmp/partial" && pwd -P)"
world; keep
for s in host-setup.sh host-undo.sh; do
  for p in --print ""; do
    out="$(cd "$SRC" && PATH="$TRIP:$PATH" OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" \
      OFFPRINT_IFCONFIG="$W/stubs/ifconfig" OFFPRINT_LAUNCHCTL="$W/stubs/launchctl" OFFPRINT_LSOF="$W/stubs/lsof" \
      OFFPRINT_SKIP_ROOT_CHECK=1 /bin/bash "$PT/os/darwin/$s" ${p:+"$p"} "$A" 2>&1)"; code=$?
    t="$s${p:+ $p}, no lib/site.sh in its copy of Offprint"
    check "$t: refused in one line, exit 2" "2|$s: $PT/lib/site.sh couldn't be read, so nothing was done (is this copy of Offprint whole?)" "$code|$out"
    check "$t: the pretend machine unchanged, nothing asked of it" "same|0|0|0" \
      "$(same_as_kept)|$(wc -l < "$W/ifconfig.calls" | tr -d ' ')|$(wc -l < "$W/launchctl.calls" | tr -d ' ')|$(wc -l < "$W/lsof.calls" | tr -d ' ')"
  done
done

# --- the PATH clean-up (lib/site.sh, through host-lib.sh): look-alikes WordPress could put in wp-content/ never run ---
# host-setup.sh and host-undo.sh --print, under every seam, run from inside the site folder's wp-content/, which holds
# look-alikes of bash, dirname, php, mktemp, git, docker, curl, readlink and env (each noting that it ran), with the
# PATH reaching there through . first, an empty entry first, relative entries, its absolute path, and a link outside the
# site folder; both as /bin/bash SCRIPT and by its own #! line. None runs, the entries left out are named in one line,
# and the --print does what it does. (Run as root, these scripts name the site folder; the PATH it then has, sudo's,
# gets the same clean-up.)
PS="$tmp/sites/pathsite"; mksite "$PS" pathsite pathsite.test 127.0.0.31 fd00:c::31 4721 4722; mkdir -p "$PS/wp-content"
for p in bash dirname php mktemp git docker curl readlink env; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$PS/wp-content/$p"; chmod +x "$PS/wp-content/$p"
done
ln -s "$PS/wp-content" "$tmp/sites/wplink"
world; keep
for spec in ".:|'.'|. first" ":|''|an empty entry first" "wp-content:../wp-content:|'wp-content' '../wp-content'|relative entries" \
  "$PS/wp-content:|'$PS/wp-content'|its absolute path" "$tmp/sites/wplink:|'$tmp/sites/wplink'|a link to it"; do
  pre="${spec%%|*}"; rest="${spec#*|}"; named="${rest%%|*}"; how="${rest#*|}"
  for s in host-setup.sh host-undo.sh; do
    for by in bash direct; do
      rm -f "$tmp/planted.ran"
      run=/bin/bash; [ "$by" = bash ] || run=""
      out="$(cd "$PS/wp-content" && PATH="$pre$TRIP:$PATH" OFFPRINT_HOSTS_FILE="$W/etc/hosts" OFFPRINT_DAEMON_DIR="$W/LaunchDaemons" \
        OFFPRINT_IFCONFIG="$W/stubs/ifconfig" OFFPRINT_LAUNCHCTL="$W/stubs/launchctl" OFFPRINT_LSOF="$W/stubs/lsof" \
        OFFPRINT_SKIP_ROOT_CHECK=1 ${run:+"$run"} "$SRC/os/darwin/$s" --print "$PS" 2>&1)"; code=$?
      t="$s --print ($by), look-alikes in wp-content/, run there, the PATH through $how"
      check "$t: no look-alike ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
      check "$t: one line says what was left out of the PATH" 1 "$(printf '%s\n' "$out" | grep -c 'PATH entries left out')"
      contains "$t: naming it" "$named" "$(printf '%s\n' "$out" | grep 'PATH entries left out')"
      check "$t: it only looked, as ever" "0|same" "$code|$(same_as_kept)"
      contains "$t: what it looked at" "${s%.sh} --print, for the site pathsite" "$out"
    done
  done
done
rm -f "$tmp/planted.ran"

# As root with no test seams (a real run, under sudo), TMPDIR is unset before the working folder is made, so it is made
# in /tmp: a TMPDIR passed through (sudo -E keeps it) is the owner's own folder, where a process of theirs could swap
# the working folder for a link between being made and being written. The decision is host_tmpdir UID SEAMS, tested
# here as a function (no test runs these scripts as root); and host_start asks it, with id -u and SEAMS, before the
# folder is made.
td() { /bin/bash -c 'TOOL="$1"; . "$1/os/darwin/host-lib.sh"; TMPDIR=/somewhere; host_tmpdir "$2" "$3"; printf "%s" "${TMPDIR-unset}"' _ "$SRC" "$1" "$2" 2>&1; }
check "host_tmpdir: root, no seams in use: TMPDIR unset" unset "$(td 0 0)"
check "host_tmpdir: root, the seams in use: TMPDIR kept" /somewhere "$(td 0 1)"
check "host_tmpdir: not root, no seams: TMPDIR kept" /somewhere "$(td 501 0)"
check "host_tmpdir: not root, the seams in use: TMPDIR kept" /somewhere "$(td 501 1)"
check "host_start asks host_tmpdir with id -u and SEAMS, after the seams and the root check, before the working folder is made" yes \
  "$(awk '/^host_start\(\) \{/ { on = 1 } on && /^  host_seams$/ { s = NR } on && /^  host_root$/ { r = NR }
    on && /^  host_tmpdir "\$\(id -u\)" "\$SEAMS"$/ { t = NR } on && /offprint_private_dir/ { p = NR } on && /^}/ { on = 0 }
    END { if (s && r && t && p && s < t && r < t && t < p) print "yes"; else print "no" }' "$SRC/os/darwin/host-lib.sh")"
# TMPDIR is checked (offprint_check_tmpdir) only once host_tmpdir has decided whether it is kept: as root with no seams
# it is unset, so a TMPDIR that sudo -E passed through and that is missing, say, is set aside rather than refused. And
# it is still checked before the working folder (or anything else) is made.
check "host_start checks TMPDIR after the seams and host_tmpdir, and before the working folder is made" yes \
  "$(awk '/^host_start\(\) \{/ { on = 1 } on && /^  host_seams$/ { s = NR }
    on && /^  host_tmpdir "\$\(id -u\)" "\$SEAMS"$/ { t = NR } on && /^  offprint_check_tmpdir$/ { c = NR; n++ }
    on && /offprint_private_dir/ { p = NR } on && /^}/ { on = 0 }
    END { if (s && t && c && p && n == 1 && s < t && t < c && c < p) print "yes"; else print "no" }' "$SRC/os/darwin/host-lib.sh")"

check "no tripwire was ever reached (ifconfig, launchctl, lsof, dscacheutil, killall, chown, sudo by name)" "" "$(cat "$tmp/tripped" 2>/dev/null)"
check "this machine's /etc/hosts is unchanged" "$real_hosts_sum" "$(cksum < /etc/hosts 2>/dev/null)"
exit "$fail"
