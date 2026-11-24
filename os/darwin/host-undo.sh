#!/bin/bash
# Reverses host-setup.sh for one site, and removes only what is that site's.
#   sudo /bin/bash TOOL/os/darwin/host-undo.sh SITE_DIR      (offprint host-undo prints this line)
#   /bin/bash TOOL/os/darwin/host-undo.sh --print SITE_DIR   show what it would remove and what it would leave;
#                                                            change nothing, and need no root (offprint host-undo
#                                                            --print)
# (/bin/bash by its path, never a bash that sudo, or your shell, finds on the PATH: one there could be WordPress's.)
# The site's names come from its site.json, read and checked as host-setup.sh reads them. PREFIX is its daemon_prefix.
# What is this site's (see "Ownership" in host-setup.sh: everything host-setup writes carries this site folder's
# stamp, and nothing without that stamp is ever removed):
#   - the block between its own markers in /etc/hosts ("# >>> offprint: LOCAL_HOST >>>"), when it carries this
#     folder's stamp and every other line in it gives one of the site's two addresses to local_host;
#   - PREFIX.https, PREFIX.http and PREFIX.loopback in /Library/LaunchDaemons, each when it carries this folder's stamp,
#     names the site's two addresses and no other, and no line of /etc/hosts outside the site's block has either
#     address (another site's, or another tool's); each is unloaded (launchctl bootout), then deleted;
#   - local_ip4 and local_ip6 on lo0, each only when this site's PREFIX.loopback.plist was there, named it, and is
#     removed here: so an address another tool put on lo0 is never taken away.
# Anything else is left as it is, and said so. /etc/hosts.before-offprint is never removed: another site may rely on
# it. Before anything changes, it refuses when the block is broken (one marker without the other), or when the hosts
# file or ifconfig's lo0 can't be read.
# Test seams: the same as host-setup.sh's (see its header); with them in use, the first and the last line it prints
# are "test seams in use: this Mac was not changed".
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
host_start host-undo "$@"

LOOP="$SITE_DAEMON_PREFIX.loopback"

# ---- Every decision, before anything changes. ----

# Lines of the hosts file outside this site's block with either of its addresses: then the addresses (and the jobs on
# them) are not this site's alone.
shared=""; remove_block=0
if [ "$HOSTS_OK" = 1 ]; then
  if ! outside="$(hosts_outside)"; then refuse "couldn't read $HOSTS."; outside=""; fi
  shared="$(printf '%s\n' "$outside" | awk -F '\t' '$2 ~ /address/ { sub(/^[^\t]*\t[^\t]*\t/, ""); print }' | paste -sd'|' -)"

  # The hosts block.
  if has_markers; then
    if ! msg="$(strip_hosts_block "$HOSTS" "$WORK/hosts" "$BEGIN" "$END" 2>&1)"; then
      refuse "$msg"
    else
      owner="$(block_owner)"; strays="$(block_strays)"
      if [ "$owner" != ours ]; then
        leave "the $SITE_LOCAL_HOST block in $HOSTS: it was not set up from this site folder ($(whose "$owner"))"
      elif [ -n "$strays" ]; then
        leave "the $SITE_LOCAL_HOST block in $HOSTS: it has lines that are not this site's ($(printf '%s\n' "$strays" | paste -sd'|' -))"
      else
        remove_block=1
        # The newline host-setup added before the block (the file had none at its end) goes with it.
        if note_at_end; then drop_final_newline "$WORK/hosts"; fi
      fi
    fi
  fi
fi

# The LaunchDaemons.
remove=""; loop_ours=0
for kind in https http loopback; do
  label="$SITE_DAEMON_PREFIX.$kind"; f="$DAEMONS/$label.plist"
  [ -e "$f" ] || [ -L "$f" ] || continue
  why=""
  if [ -L "$f" ] || [ ! -f "$f" ]; then
    why="it is not a plain file"
  elif owner="$(plist_owner "$f")" && [ "$owner" != ours ]; then
    why="it was not set up from this site folder ($(whose "$owner"); it names $(addresses_of "$f"))"
  elif ! names_ours "$f"; then
    why="it names $(addresses_of "$f"), not this site's $SITE_IP4 and $SITE_IP6 (if it is this site's, from an earlier site.json, put the old values back and run this again)"
  elif [ -n "$shared" ]; then
    why="$HOSTS has this site's addresses outside its block too ($shared), so they are not this site's alone"
  fi
  if [ -n "$why" ]; then
    leave "$f: $why"
  else
    remove="$remove $kind"
    [ "$kind" != loopback ] || loop_ours=1
  fi
done

# The addresses: only those this site's loopback job named, and only with that job going.
del4=0; del6=0
if lo0_has inet "$SITE_IP4"; then
  if [ "$loop_ours" = 1 ]; then del4=1
  else leave "$SITE_IP4 on lo0: no $LOOP.plist of this site's (removed here) names it, so it is not this site's to take away"; fi
fi
if lo0_has inet6 "$SITE_IP6"; then
  if [ "$loop_ours" = 1 ]; then del6=1
  else leave "$SITE_IP6 on lo0: no $LOOP.plist of this site's (removed here) names it, so it is not this site's to take away"; fi
fi
if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
  leave "$BACKUP, the copy of the hosts file from before the first set-up (another site may rely on it)"
fi
nothing=0
[ "$remove_block" = 1 ] || [ -n "$remove" ] || [ "$del4" = 1 ] || [ "$del6" = 1 ] || nothing=1

# ---- --print: what it would do, or why it would refuse. ----
if [ "$PRINT" = 1 ]; then
  echo "host-undo --print, for the site $SITE_NAME ($SITE_DIR). This only looks: it changes nothing."
  echo "The real run, as root:  sudo /bin/bash $(shq "$SELF") $(shq "$SITE_DIR")"
  echo "This site folder's stamp: $STAMP"
  echo
  if [ -s "$WORK/refused" ]; then
    echo "It would refuse, and change nothing:"
    cat "$WORK/refused"
    exit 1
  fi
  if [ "$nothing" = 1 ]; then
    echo "Nothing of this site's to remove."
  else
    echo "It would remove:"
    if [ "$remove_block" = 1 ]; then
      echo "  - this block from $HOSTS (and the blank line, or the newline, before it):"
      awk -v b="$BEGIN" -v e="$END" '$0 == b { on = 1 } on { print "      " $0 } on && $0 == e { on = 0 }' "$HOSTS"
      echo "    and flush the DNS cache"
    fi
    for kind in $remove; do
      echo "  - $DAEMONS/$SITE_DAEMON_PREFIX.$kind.plist (launchctl bootout system/$SITE_DAEMON_PREFIX.$kind, then delete it)"
    done
    [ "$del4" = 0 ] || echo "  - $SITE_IP4 from lo0 (ifconfig lo0 -alias $SITE_IP4)"
    [ "$del6" = 0 ] || echo "  - $SITE_IP6 from lo0 (ifconfig lo0 inet6 -alias $SITE_IP6)"
  fi
  if [ -s "$WORK/left" ]; then
    echo "It would leave as it is:"
    cat "$WORK/left"
  fi
  exit 0
fi

if [ -s "$WORK/refused" ]; then
  echo "host-undo refuses, and has changed nothing:" >&2
  cat "$WORK/refused" >&2
  exit 1
fi
if [ "$nothing" = 1 ]; then
  echo "Nothing of this site's to remove."
  if [ -s "$WORK/left" ]; then echo "Left as it is:"; cat "$WORK/left"; fi
  exit 0
fi

# ---- The changes, in the reverse order of host-setup's. Each one made is noted, for stop. ----
if [ "$remove_block" = 1 ]; then
  cat "$WORK/hosts" > "$HOSTS" || stop "couldn't write $HOSTS."
  done_step "removed the $SITE_LOCAL_HOST block from $HOSTS"
  echo "removed the $SITE_LOCAL_HOST block from $HOSTS"
  flush_dns
fi
for kind in $remove; do
  label="$SITE_DAEMON_PREFIX.$kind"; f="$DAEMONS/$label.plist"
  "$LAUNCHCTL" bootout "system/$label" 2> /dev/null || true
  rm -f "$f" || stop "couldn't remove $f."
  done_step "unloaded and removed $f"
  echo "unloaded and removed $f"
done
if [ "$del4" = 1 ]; then
  "$IFCONFIG" lo0 -alias "$SITE_IP4" || stop "ifconfig couldn't take $SITE_IP4 off lo0."
  done_step "removed $SITE_IP4 from lo0"
  echo "removed $SITE_IP4 from lo0"
fi
if [ "$del6" = 1 ]; then
  "$IFCONFIG" lo0 inet6 -alias "$SITE_IP6" || stop "ifconfig couldn't take $SITE_IP6 off lo0."
  done_step "removed $SITE_IP6 from lo0"
  echo "removed $SITE_IP6 from lo0"
fi
if [ -s "$WORK/left" ]; then echo "Left as it is:"; cat "$WORK/left"; fi
echo "Done."
