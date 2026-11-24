#!/bin/bash
# THE ENTIRE PRIVILEGED SURFACE of Offprint, for one site: four steps, all reversed by host-undo.sh.
#   sudo /bin/bash TOOL/os/darwin/host-setup.sh SITE_DIR          make the changes (offprint host-setup prints this
#                                                                 line)
#   /bin/bash TOOL/os/darwin/host-setup.sh --print SITE_DIR       show every change, and any clash; change nothing,
#                                                                 and need no root (offprint host-setup --print)
#   sudo /bin/bash TOOL/os/darwin/host-setup.sh --adopt SITE_DIR  the same site, moved to a new folder (see
#                                                                 "Ownership")
# (/bin/bash by its path, never a bash that sudo, or your shell, finds on the PATH: one there could be WordPress's.)
# SITE_DIR is the site folder. The site's names come from its site.json, read with lib/config.php (so php must be on
# root's PATH), and are checked again here before any is used (host-lib.sh). PREFIX is site.json's daemon_prefix.
#   1. local_ip4 and local_ip6 on lo0, now (the stamped PREFIX.loopback.plist is put in place first, so the addresses
#      are known as this site's even if a later step fails);
#   2. both again at every boot: the LaunchDaemon PREFIX.loopback;
#   3. local_host as both addresses, in a block of /etc/hosts marked "# >>> offprint: LOCAL_HOST >>>". Before its
#      first change, /etc/hosts is copied to /etc/hosts.before-offprint, once; host-undo never removes that copy
#      (another site may rely on it);
#   4. launchd listening on both addresses, ports 443 and 80, relaying to the site's Caddy: PREFIX.https, PREFIX.http.
# A second run changes only what differs from what it would write (usually nothing). If a step fails, it says exactly
# what it had done, and how to go on. After a plain run, all of that is this site's, so a second run finishes and
# host-undo takes it away. After an --adopt run that stopped part way, only the files it wrote carry this folder's
# stamp, and the rest may still carry the old folder's, which a plain run refuses and host-undo leaves: the way on is
# --adopt again (stop, in host-lib.sh, says so).
#
# Ownership. Each plist carries "<!-- offprint site STAMP -->" and the hosts block "# site STAMP" (right after its
# begin marker), STAMP being the sha256 of this site folder's physical path (in the disk's own letter case, so a
# folder reached by a name in another case, on a disk that ignores case, is still one site). A plist named with
# PREFIX, or a block with this site's markers, is this site's only with this stamp: one with no stamp, or with another
# folder's, is refused (a copy of the folder, another site with the same names, someone else's job). --adopt is for
# the same site in a new folder: it re-stamps, for this folder, exactly those things that, but for the stamp, are what
# this would write (the same plists, byte for byte, and the same block lines), and nothing else. Whoever runs it says
# so by running it: that the old folder is gone, and this is the same site, not a second copy beside it. A loaded job
# with one of this site's labels and no plist of this site's is refused too, so set-up never unloads a job that is not
# this site's.
#
# It is made to run beside other sites and other tools. Before changing anything at all, it refuses, naming the
# clash, when:
#   - a PREFIX.*.plist, or this site's block, is not stamped for this folder (see above);
#   - local_ip4 or local_ip6 is on lo0 already, and no PREFIX.loopback.plist of this site's names it;
#   - local_host is on a line of /etc/hosts outside this site's block, or either address is; or this site's block
#     gives local_host other addresses (an earlier site.json);
#   - this site's plists name other addresses than the site's two; or another plist in the folder names either
#     address, or relays to the site's tls_port or http_port;
#   - a job with one of this site's labels is loaded, and there is no plist of this site's for it;
#   - something listens on tls_port or http_port, unless this site's own PREFIX.https and PREFIX.http plists are in
#     place already, exactly as this would write them (the listener is then the site's own Caddy);
#   - the site's markers in /etc/hosts are broken (hosts-block.sh);
#   - something it must read can't be read: the hosts file, ifconfig's lo0, launchctl print, lsof.
# Nothing else is touched: not 127.0.0.1 (where a local web server, Laravel Valet say, may hold ports 80 and 443),
# not any other address on lo0, not any other line of /etc/hosts, not any other LaunchDaemon.
#
# Test seams, for tests/host.test.sh only:
#   OFFPRINT_HOSTS_FILE         instead of /etc/hosts (its copy from before is then OFFPRINT_HOSTS_FILE.before-offprint)
#   OFFPRINT_DAEMON_DIR         instead of /Library/LaunchDaemons
#   OFFPRINT_IFCONFIG           instead of /sbin/ifconfig
#   OFFPRINT_LAUNCHCTL          instead of /bin/launchctl
#   OFFPRINT_LSOF               instead of /usr/sbin/lsof
#   OFFPRINT_SKIP_ROOT_CHECK=1  run without root; honoured only with the seams in use
# Set one, and all five must be set, and the hosts file and folder must not be (or link to) the real ones; then the
# DNS cache is not flushed and nothing is given to root:wheel. So no test, and no mistake, reaches this Mac's real
# files, or runs its real ifconfig, launchctl or lsof, without sudo. With the seams in use, the first and the last
# line it prints are "test seams in use: this Mac was not changed".
# Needs bash 3.2 (macOS) or newer.
set -u
export LC_ALL=C
# This folder, by the shell's own builtins: nothing is looked up on the PATH (root's, under sudo) before host-lib.sh has
# sourced lib/site.sh, which makes it safe to use.
case "${BASH_SOURCE[0]}" in */*) DARWIN="${BASH_SOURCE[0]%/*}" ;; *) DARWIN=. ;; esac
DARWIN="$(CDPATH= cd -P -- "${DARWIN:-/}" && pwd -P)" || exit 2
TOOL="$(CDPATH= cd -P -- "$DARWIN/../.." && pwd -P)" || exit 2
# shellcheck source=os/darwin/hosts-block.sh
. "$DARWIN/hosts-block.sh"
# shellcheck source=os/darwin/host-lib.sh
. "$DARWIN/host-lib.sh"
host_start host-setup "$@"

LOOP="$SITE_DAEMON_PREFIX.loopback"; HTTPS="$SITE_DAEMON_PREFIX.https"; HTTP="$SITE_DAEMON_PREFIX.http"

# The plists. Every value in them has matched a pattern with no character XML or the shell treats specially
# (host_check), so each goes in as it is.
loopback_plist() {
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- offprint site $STAMP -->
<dict>
  <key>Label</key><string>$LOOP</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>/sbin/ifconfig lo0 alias $SITE_IP4 up; /sbin/ifconfig lo0 inet6 alias $SITE_IP6 prefixlen 128</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PL
}
# The listeners on 443 and 80. launchd (root) holds the sockets on this site's two addresses only and hands each
# connection to nc, running as nobody, which relays it to Caddy's unprivileged port on 127.0.0.1. No process of
# Offprint's runs as root. Why not Docker: Docker Desktop cannot publish a port below 1024 on one loopback address
# (it binds 0.0.0.0 instead); see templates/compose.yaml's caddy ports.
forwarder_plist() {  # label, listen port, Caddy's port
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- offprint site $STAMP -->
<dict>
  <key>Label</key><string>$1</string>
  <key>UserName</key><string>nobody</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/nc</string><string>127.0.0.1</string><string>$3</string></array>
  <key>inetdCompatibility</key><dict><key>Wait</key><false/></dict>
  <key>Sockets</key>
  <dict>
    <key>v4</key><dict><key>SockNodeName</key><string>$SITE_IP4</string><key>SockServiceName</key><string>$2</string></dict>
    <key>v6</key><dict><key>SockNodeName</key><string>$SITE_IP6</string><key>SockServiceName</key><string>$2</string></dict>
  </dict>
</dict>
</plist>
PL
}
# The hosts block; with "note", the line saying the newline before it was added here (the file had none at its end),
# so host-undo, and a second set-up, take that newline away with the block.
block_text() {
  printf '%s\n# site %s\n' "$BEGIN" "$STAMP"
  [ "${1:-}" != note ] || printf '%s\n' "$NOTE"
  printf '%s\t%s\n%s\t%s\n%s\n' "$SITE_IP4" "$SITE_LOCAL_HOST" "$SITE_IP6" "$SITE_LOCAL_HOST" "$END"
}
loopback_plist > "$WORK/$LOOP.plist"
forwarder_plist "$HTTPS" 443 "$SITE_TLS_PORT" > "$WORK/$HTTPS.plist"
forwarder_plist "$HTTP" 80 "$SITE_HTTP_PORT" > "$WORK/$HTTP.plist"
for label in "$LOOP" "$HTTPS" "$HTTP"; do unstamped "$WORK/$label.plist" > "$WORK/$label.bare"; done

# ---- Every check, before anything changes. ----

# This site's LaunchDaemons: any PREFIX.*.plist must carry this folder's stamp (and name the site's two addresses), or,
# with --adopt, be one of its three exactly as this would write it but for the stamp.
adopt_loop=0; adopt_https=0; adopt_http=0
for f in "$DAEMONS/$SITE_DAEMON_PREFIX".*.plist; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  if [ -L "$f" ] || [ ! -f "$f" ]; then refuse "$f is not a plain file."; continue; fi
  label="${f##*/}"; label="${label%.plist}"
  owner="$(plist_owner "$f")"
  if [ "$owner" = ours ]; then
    names_ours "$f" || refuse "$f names $(addresses_of "$f"), not this site's $SITE_IP4 and $SITE_IP6. (If it is this site's, from an earlier site.json, put the old addresses back and run host-undo first.)"
    continue
  fi
  case "$label" in
    "$LOOP" | "$HTTPS" | "$HTTP")
      if unstamped "$f" | cmp -s - "$WORK/$label.bare"; then
        if [ "$ADOPT" = 1 ]; then
          case "$label" in "$LOOP") adopt_loop=1 ;; "$HTTPS") adopt_https=1 ;; *) adopt_http=1 ;; esac
        else
          refuse "$f was set up from a different site folder, or not by Offprint ($(whose "$owner")). If this is the same site, moved to a new folder, run host-setup again with --adopt."
        fi
      else
        refuse "$f was set up from a different site folder, or not by Offprint ($(whose "$owner"); it names $(addresses_of "$f")), and differs from what this site.json would write; --adopt takes over only what matches exactly."
      fi ;;
    *) refuse "$f has this site's daemon_prefix but was set up from a different site folder, or not by Offprint ($(whose "$owner"); it names $(addresses_of "$f"))." ;;
  esac
done
adopting() { case "$1" in "$LOOP") [ "$adopt_loop" = 1 ] ;; "$HTTPS") [ "$adopt_https" = 1 ] ;; *) [ "$adopt_http" = 1 ] ;; esac; }

# The addresses. On lo0 already is fine only when this site's own loopback job (stamped, or being adopted) names them.
loop_names() {
  local f="$DAEMONS/$LOOP.plist"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(plist_owner "$f")" = ours ] || adopting "$LOOP" || return 1
  plist_addresses "$f" | grep -qxF -- "$1"
}
add4=1; add6=1
if lo0_has inet "$SITE_IP4"; then
  add4=0
  loop_names "$SITE_IP4" || refuse "$SITE_IP4 (local_ip4) is on lo0 already, and no $LOOP.plist of this site's in $DAEMONS names it: something else uses that address."
fi
if lo0_has inet6 "$SITE_IP6"; then
  add6=0
  loop_names "$SITE_IP6" || refuse "$SITE_IP6 (local_ip6) is on lo0 already, and no $LOOP.plist of this site's in $DAEMONS names it: something else uses that address."
fi

# No other plist may name either address, or relay to either of the site's ports.
re4="$(printf '%s' "$SITE_IP4" | sed 's/\./\\./g')"
for f in "$DAEMONS"/*.plist; do
  case "${f##*/}" in "$SITE_DAEMON_PREFIX".*) continue ;; esac
  [ -f "$f" ] || continue
  if grep -qE "(^|[^0-9.])$re4([^0-9.]|\$)" "$f" 2> /dev/null; then refuse "$f names $SITE_IP4, this site's local_ip4."; fi
  if grep -qiE "(^|[^0-9a-f:])$SITE_IP6([^0-9a-f:]|\$)" "$f" 2> /dev/null; then refuse "$f names $SITE_IP6, this site's local_ip6."; fi
  if grep -qF "<string>127.0.0.1</string><string>$SITE_TLS_PORT</string>" "$f" 2> /dev/null; then refuse "$f relays to 127.0.0.1:$SITE_TLS_PORT, this site's tls_port."; fi
  if grep -qF "<string>127.0.0.1</string><string>$SITE_HTTP_PORT</string>" "$f" 2> /dev/null; then refuse "$f relays to 127.0.0.1:$SITE_HTTP_PORT, this site's http_port."; fi
done

# The jobs launchd has loaded under this site's labels. One with no plist of this site's is someone else's: set-up
# would unload it, so it is a refusal. launchctl print failing is a refusal too (nothing is decided on a guess).
j_loop="$(job_state "$LOOP")"; j_https="$(job_state "$HTTPS")"; j_http="$(job_state "$HTTP")"
for pair in "$LOOP $j_loop" "$HTTPS $j_https" "$HTTP $j_http"; do
  label="${pair%% *}"; js="${pair#* }"
  case "$js" in
    error*) refuse "couldn't tell whether $label is loaded: launchctl print system/$label exited ${js#error }." ;;
    loaded) [ -e "$DAEMONS/$label.plist" ] || [ -L "$DAEMONS/$label.plist" ] \
              || refuse "a job labelled $label is loaded in launchd, but $DAEMONS has no $label.plist: something else uses that label, and set-up would unload it." ;;
  esac
done

# The hosts file: local_host, and the two addresses, only in this site's block; and the block only this site's.
adopt_block=0; hosts_change=0; with_note=""
if [ "$HOSTS_OK" = 1 ]; then
  if ! outside="$(hosts_outside)"; then refuse "couldn't read $HOSTS."; outside=""; fi
  while IFS=$'\t' read -r nr kind text; do
    [ -n "$nr" ] || continue
    case "$kind" in
      name*) refuse "$HOSTS line $nr names $SITE_LOCAL_HOST outside this site's block: $text" ;;
      *) refuse "$HOSTS line $nr gives this site's address to a name outside this site's block: $text" ;;
    esac
  done <<EOT
$outside
EOT
  # The hosts file this would write: this site's block (an old one taken out first) at the end. An IPv6 line for the
  # same name: without one, macOS asks mDNS for a .local name's AAAA record, and waits 5 seconds for nobody to answer.
  # (local_ip6 is a unique-local fdXX: address; lib/config.php allows no other kind, so never ::1, where whatever
  # listens on 127.0.0.1's ports would answer for this name.)
  base_ok=1
  if has_markers; then
    if msg="$(strip_hosts_block "$HOSTS" "$WORK/hosts" "$BEGIN" "$END" 2>&1)"; then
      owner="$(block_owner)"
      if [ "$owner" = ours ]; then
        strays="$(block_strays)"
        [ -z "$strays" ] || refuse "$HOSTS has this site's block, but it says $(printf '%s\n' "$strays" | paste -sd'|' -): an earlier site.json? Put the old values back and run host-undo first."
      else
        body="$(block_body)"
        if [ "$body" = "$(printf '%s\t%s\n%s\t%s' "$SITE_IP4" "$SITE_LOCAL_HOST" "$SITE_IP6" "$SITE_LOCAL_HOST")" ]; then
          if [ "$ADOPT" = 1 ]; then adopt_block=1
          else refuse "$HOSTS has a block for $SITE_LOCAL_HOST that was set up from a different site folder, or not by Offprint ($(whose "$owner")). If this is the same site, moved to a new folder, run host-setup again with --adopt."; fi
        else
          refuse "$HOSTS has a block for $SITE_LOCAL_HOST that was set up from a different site folder, or not by Offprint ($(whose "$owner")), and differs from what this site.json would write: $(printf '%s\n' "$body" | paste -sd'|' -)"
        fi
      fi
      if note_at_end; then drop_final_newline "$WORK/hosts"; fi
    else
      refuse "$msg"; base_ok=0
    fi
  else
    cat "$WORK/hosts.orig" > "$WORK/hosts" || { refuse "couldn't read $HOSTS."; base_ok=0; }
  fi
  if [ "$base_ok" = 1 ]; then
    if [ -s "$WORK/hosts" ] && [ -n "$(tail -c 1 "$WORK/hosts")" ]; then with_note=note; else with_note=""; fi
    { printf '\n'; block_text $with_note; } >> "$WORK/hosts"
    cmp -s "$WORK/hosts" "$HOSTS" || hosts_change=1
  fi
fi

# The plists: new, the same as this would write, to be adopted (re-stamped), or to be replaced; whether each needs
# unloading first, and loading.
state() {
  if [ ! -e "$DAEMONS/$1.plist" ]; then echo new
  elif cmp -s "$WORK/$1.plist" "$DAEMONS/$1.plist"; then echo same
  elif adopting "$1"; then echo adopt
  else echo replace; fi
}
s_loop="$(state "$LOOP")"; s_https="$(state "$HTTPS")"; s_http="$(state "$HTTP")"
needs_load() {  # state, job state
  case "$1" in new | replace) echo 1 ;; *) if [ "$2" = loaded ]; then echo 0; else echo 1; fi ;; esac
}
l_loop="$(needs_load "$s_loop" "$j_loop")"; l_https="$(needs_load "$s_https" "$j_https")"; l_http="$(needs_load "$s_http" "$j_http")"

# The ports. On a first set-up, nothing may listen on Caddy's two (on any address: that holds 127.0.0.1 too). When
# this site's own relays are in place already, exactly as written here (or being adopted), a listener there is the
# site's own Caddy. lsof finds nothing: exit 1 and silent; anything else it says is a refusal.
case "$s_https $s_http" in
  "same same" | "same adopt" | "adopt same" | "adopt adopt") ;;
  *)
    for p in "$SITE_TLS_PORT tls_port" "$SITE_HTTP_PORT http_port"; do
      port="${p% *}"; rc=0
      found="$("$LSOF" -nP -iTCP:"$port" -sTCP:LISTEN 2> "$WORK/lsof.err")" || rc=$?
      if [ "$rc" = 0 ]; then
        who="$(printf '%s\n' "$found" | awk 'NR > 1 { $1 = $1; print }' | head -3 | paste -sd';' -)"
        refuse "something is listening on port $port (this site's ${p#* }), where the site's Caddy must: ${who:-lsof found a listener}"
      elif [ "$rc" != 1 ] || [ -s "$WORK/lsof.err" ] || [ -n "$found" ]; then
        refuse "couldn't tell whether anything listens on port $port (this site's ${p#* }): lsof exited $rc ($(head -1 "$WORK/lsof.err"))."
      fi
    done ;;
esac

# ---- --print: what it would do, or why it would refuse. ----
show_daemon() {  # step, label, state, load (1, 0, or "later": shown on a line of its own), job state
  local f="$DAEMONS/$2.plist" load="" unload="" running=""
  [ "$4" != 1 ] || load=", then load it (launchctl bootstrap system $f)"
  [ "$5" != loaded ] || unload=", unloading its job first (launchctl bootout system/$2)"
  [ "$4" != 0 ] || running="; its loaded job is left running"
  case "$3" in
    same)
      if [ "$4" = 1 ]; then echo "$1  $f is in place already; load it:  launchctl bootstrap system $f"; changes=1
      elif [ "$4" = later ]; then echo "$1  $f is in place already: nothing to write"
      else echo "$1  $f is in place and loaded already: nothing to do"; fi
      return 0 ;;
    new) echo "$1  write $f (owner root:wheel, mode 644)$load:" ;;
    adopt) echo "$1  re-stamp $f for this site folder (otherwise unchanged$running)$load:" ;;
    replace) echo "$1  replace $f (owner root:wheel, mode 644)$unload$load. Its new content:" ;;
  esac
  sed 's/^/       /' "$WORK/$2.plist"
  changes=1
}
if [ "$PRINT" = 1 ]; then
  adopt=""; [ "$ADOPT" = 0 ] || adopt=" --adopt"
  echo "host-setup --print$adopt, for the site $SITE_NAME ($SITE_DIR). This only looks: it changes nothing."
  echo "The real run, as root:  sudo /bin/bash $(shq "$SELF")$adopt $(shq "$SITE_DIR")"
  echo "This site folder's stamp: $STAMP"
  if [ "$SEAMS" = 0 ] && [ "$(id -u)" != 0 ]; then echo "(lsof, run as you, sees only your own processes; the real run, as root, sees every one.)"; fi
  echo
  if [ -s "$WORK/refused" ]; then
    echo "It would refuse, and change nothing:"
    cat "$WORK/refused"
    exit 1
  fi
  changes=0
  echo "No clash found. What it would do:"
  show_daemon "1/4" "$LOOP" "$s_loop" later "$j_loop"
  if [ "$add4" = 1 ]; then echo "1/4  add $SITE_IP4 to lo0:  ifconfig lo0 alias $SITE_IP4 up"; changes=1
  else echo "1/4  $SITE_IP4 is on lo0 already ($LOOP.plist names it): nothing to do"; fi
  if [ "$add6" = 1 ]; then echo "     add $SITE_IP6 to lo0:  ifconfig lo0 inet6 alias $SITE_IP6 prefixlen 128"; changes=1
  else echo "     $SITE_IP6 is on lo0 already ($LOOP.plist names it): nothing to do"; fi
  if [ "$l_loop" = 1 ]; then echo "2/4  load $LOOP:  launchctl bootstrap system $DAEMONS/$LOOP.plist"; changes=1
  else echo "2/4  $LOOP is loaded already: nothing to do"; fi
  if [ "$hosts_change" = 1 ]; then
    changes=1
    if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then echo "3/4  ($BACKUP, the copy from before, is there already, and stays as it is)"
    else echo "3/4  copy $HOSTS to $BACKUP (kept: host-undo never removes it), then"; fi
    if [ "$adopt_block" = 1 ]; then echo "     re-stamp this site's block in $HOSTS for this site folder, so that it says:"
    elif has_markers; then echo "     replace this site's block in $HOSTS with:"
    elif [ -n "$with_note" ]; then echo "     add this at the end of $HOSTS, on a new line (the file has no newline at its end; the note says so):"
    else echo "     add this at the end of $HOSTS, after a blank line:"; fi
    block_text $with_note | sed 's/^/       /'
    echo "     and flush the DNS cache (dscacheutil -flushcache; killall -HUP mDNSResponder)"
  else
    echo "3/4  $HOSTS has this site's block already: nothing to do"
  fi
  show_daemon "4/4" "$HTTPS" "$s_https" "$l_https" "$j_https"
  show_daemon "   " "$HTTP" "$s_http" "$l_http" "$j_http"
  echo
  [ "$changes" = 1 ] || echo "Nothing would change: this site is set up already."
  exit 0
fi

if [ -s "$WORK/refused" ]; then
  echo "host-setup refuses, and has changed nothing:" >&2
  cat "$WORK/refused" >&2
  echo "Choose other values in $SITE_DIR/site.json, or find out what is using these." >&2
  exit 1
fi

# ---- The changes. Each one made is noted, so a failure can say exactly what was done (stop, in host-lib.sh). ----
# write_daemon STEP LABEL STATE JOBSTATE: put the plist in place, unless it is the same. A new file is made beside it
# and moved into place, so a link there is replaced, never followed. A job being replaced is unloaded first.
write_daemon() {
  local f="$DAEMONS/$2.plist" t
  if [ "$3" = same ]; then echo "$1  $f already in place"; return 0; fi
  t="$(mktemp "$DAEMONS/.offprint.XXXXXX" 2> /dev/null)" || stop "couldn't make a file in $DAEMONS."
  if ! { cat "$WORK/$2.plist" > "$t" && chmod 644 "$t"; }; then rm -f "$t"; stop "couldn't write $t."; fi
  if [ "$SEAMS" = 0 ] && ! /usr/sbin/chown root:wheel "$t"; then rm -f "$t"; stop "couldn't give $t to root:wheel."; fi
  # An earlier copy first. launchctl can refuse a bootstrap made straight after a bootout.
  if [ "$3" = replace ] && [ "$4" = loaded ] && "$LAUNCHCTL" bootout "system/$2" 2> /dev/null; then
    done_step "unloaded $2"; sleep 1
  fi
  mv -f "$t" "$f" || { rm -f "$t"; stop "couldn't put $f in place."; }
  done_step "wrote $f"
  if [ "$3" = adopt ]; then echo "$1  re-stamped $f for this site folder"; else echo "$1  wrote $f"; fi
}
# load_daemon STEP LABEL LOAD: load the job, if it needs it.
load_daemon() {
  if [ "$3" = 1 ]; then
    "$LAUNCHCTL" bootstrap system "$DAEMONS/$2.plist" || stop "launchctl couldn't load $DAEMONS/$2.plist."
    done_step "loaded $2"
    echo "$1  loaded $2"
  else
    echo "$1  $2 already loaded"
  fi
}

# 1. The loopback job's plist first, stamped: from here on the addresses are known as this site's. Then the aliases,
#    now.
write_daemon "1/4" "$LOOP" "$s_loop" "$j_loop"
if [ "$add4" = 1 ]; then
  "$IFCONFIG" lo0 alias "$SITE_IP4" up || stop "ifconfig couldn't add $SITE_IP4 to lo0."
  done_step "added $SITE_IP4 to lo0"
  echo "1/4  added $SITE_IP4 to lo0"
else
  echo "1/4  $SITE_IP4 already on lo0"
fi
if [ "$add6" = 1 ]; then
  "$IFCONFIG" lo0 inet6 alias "$SITE_IP6" prefixlen 128 || stop "ifconfig couldn't add $SITE_IP6 to lo0."
  done_step "added $SITE_IP6 to lo0"
  echo "1/4  added $SITE_IP6 to lo0"
else
  echo "1/4  $SITE_IP6 already on lo0"
fi

# 2. Both again at every boot (an lo0 alias does not survive a restart).
load_daemon "2/4" "$LOOP" "$l_loop"

# 3. The name, in this site's block of the hosts file, rewritten whole (cat into it, so the file keeps its owner,
#    mode and inode), so a re-run upgrades it.
if [ "$hosts_change" = 1 ]; then
  if [ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ]; then
    cp -p "$HOSTS" "$BACKUP" || stop "couldn't copy $HOSTS to $BACKUP."
    done_step "copied $HOSTS to $BACKUP"
  fi
  cat "$WORK/hosts" > "$HOSTS" || stop "couldn't write $HOSTS."
  done_step "wrote $HOSTS (this site's block)"
  echo "3/4  $SITE_LOCAL_HOST is $SITE_IP4 and $SITE_IP6 in $HOSTS (the copy from before: $BACKUP)"
  flush_dns
else
  echo "3/4  $SITE_LOCAL_HOST is $SITE_IP4 and $SITE_IP6 in $HOSTS already"
fi

# 4. The listeners on 443 and 80 (see forwarder_plist).
write_daemon "4/4" "$HTTPS" "$s_https" "$j_https"
load_daemon "4/4" "$HTTPS" "$l_https"
write_daemon "4/4" "$HTTP" "$s_http" "$j_http"
load_daemon "4/4" "$HTTP" "$l_http"
echo "4/4  launchd listens on $SITE_IP4 and $SITE_IP6, ports 443 and 80, for Caddy on 127.0.0.1:$SITE_TLS_PORT and :$SITE_HTTP_PORT"

echo
echo "Done. Next: offprint setup-wp"
