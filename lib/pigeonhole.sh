# Offprint: a site's pigeonhole, on the Mac's side. Sourced by bin/collect and bin/pigeonhole, after lib/site.sh and
# lib/adapter.sh (for offprint_secret_get), with the site loaded. It finds the site's own folders, and fetches what the
# store holds into the spool, over ssh. Works on macOS /bin/bash 3.2 and Linux bash. Nothing here prints: a function
# that fails returns 1 with PIGEONHOLE_PROBLEM saying why, in the owner's words, and PIGEONHOLE_REASON one fixed word
# for it (what var/pigeonhole-fetch.json holds: never anything a server said).
#
# The folders (pigeonhole_box): this user's own, under OFFPRINT_HOME (~/Library/Application Support/Offprint unless
# set), never in the site folder, whose var/ WordPress can read:
#   OFFPRINT_HOME/pigeonhole/SITE_NAME/spool/      what is fetched and not yet opened
#   OFFPRINT_HOME/pigeonhole/SITE_NAME/done/       what WordPress has taken
#   OFFPRINT_HOME/pigeonhole/SITE_NAME/rejected/   what was refused, each beside a NAME.age.why
#   OFFPRINT_HOME/pigeonhole/SITE_NAME/lock/       held while anything fetches into the spool or opens what is in it
#
# The fetch. The store is a machine nothing on the internet reaches: the Mac's ssh goes to the site's web server
# (site.json's pigeonhole.jump), which lets this key do one thing, open a connection on to the store's ssh
# (pigeonhole.server), where the same key may run one command (pigeonhole/server/pull.js: list, get NAME, delete NAME)
# and nothing else. What each side is, is pinned: both machines' host keys are site.json's, written into a known_hosts
# file of this run's own, and a machine that shows another key is not spoken to. Nothing of the owner's own ssh set-up
# is read or used: not ~/.ssh/config (ssh is given a config file of this run's own, which the hop through the web
# server is given too), not their keys, not their agent.
#
# The pull key is a token (CLAUDE.md): it is in the login Keychain (the secret pigeonhole-pull) as one line of base64,
# and for a run it goes from the Keychain's helper (os/darwin/secret, which holds it as it holds any secret) down a
# pipe, is decoded on the pipe, and is read from the pipe by ssh-add, into an ssh-agent started for this run alone and
# killed when it ends. In this file and its callers it is never in a file, a variable, an argument or the environment.
# (The config and known_hosts files hold addresses and public keys only.)
#
# Neither machine can keep the Mac waiting, or fill its disk. Each ssh is given PIGEONHOLE_SSH_SECONDS and then killed
# (a machine that holds the right host key can answer for ever and never finish), a whole fetch
# PIGEONHOLE_FETCH_SECONDS, after which what is left waits for the next; and what ssh or the far side says of a
# failure goes into a file that can't grow past a few kilobytes. The site's agent, which fetches before it looks for
# a publish request, is so never held up for long; and the key's time in the run's agent outlasts any fetch.
#
# What the store answers is not trusted. A name is matched (64 hex digits and .age) before it is used; no more of a
# file is read than a submission can be; and a file is kept only when its bytes hash to its name, under which it is
# first written beside the spool's own (.incoming-NAME) and then renamed. Only then is it removed from the store: so a
# run cut short leaves a submission in both places, never in neither, and the next fetch removes the store's copy of
# what the Mac already holds. One that does not hash to its name is left on the store and counted.

PIGEONHOLE_PROBLEM=""; PIGEONHOLE_REASON=""
PIGEONHOLE_MAX_BYTES=16384        # no submission's file is larger: the largest today is under 9 KB
PIGEONHOLE_MAX_NAMES=500          # what one fetch takes at most (pull.js lists no more); the rest wait for the next
# How long one ssh may take, and a whole fetch, in seconds. From the environment only to shorten them (the tests do).
PIGEONHOLE_SSH_SECONDS=60; PIGEONHOLE_FETCH_SECONDS=600
case "${OFFPRINT_PIGEONHOLE_SSH_SECONDS:-}" in [1-9]|[1-5][0-9]) PIGEONHOLE_SSH_SECONDS="$OFFPRINT_PIGEONHOLE_SSH_SECONDS" ;; esac
case "${OFFPRINT_PIGEONHOLE_FETCH_SECONDS:-}" in [1-9]|[1-9][0-9]|[1-5][0-9][0-9]) PIGEONHOLE_FETCH_SECONDS="$OFFPRINT_PIGEONHOLE_FETCH_SECONDS" ;; esac
PIGEONHOLE_LOCK_STALE_MINUTES=30  # no run lasts this long (see PIGEONHOLE_FETCH_SECONDS): an older lock is nobody's
PIGEONHOLE_PULL_SECRET=pigeonhole-pull
PIGEONHOLE_JUMP_USER=pigeonhole-jump
BOX=""; SPOOL=""; DONE=""; REJECTED=""
PH_HAVE_LOCK=0; PH_AGENT_PID=""; PH_DIR=""; PH_CONFIG=""
FETCHED=0; FETCH_DAMAGED=0; FETCH_LEFT=0

# pigeonhole_store_user: the store's user for this site, ph-SITE_NAME: one user a site, so one site's key reaches only
# its own submissions. (A Linux user's name is 32 characters at most: bin/pigeonhole refuses a longer site name.)
pigeonhole_store_user() { printf 'ph-%s' "$SITE_NAME"; }

# pigeonhole_box: finds and, where missing, makes this site's folders; sets BOX, SPOOL, DONE and REJECTED. Each must be
# a real folder (never a link) of this user's that nobody else can read, outside the site folder.
pigeonhole_box() {
  local home="${OFFPRINT_HOME:-}" d
  PIGEONHOLE_PROBLEM=""; PIGEONHOLE_REASON=folders
  if [ -z "$home" ]; then
    case "${HOME:-}" in
      /*) home="$HOME/Library/Application Support/Offprint" ;;
      *) PIGEONHOLE_PROBLEM="HOME isn't set to a folder, so there is nowhere to keep the pigeonhole's spool; set HOME, or OFFPRINT_HOME."; return 1 ;;
    esac
  fi
  case "$home" in /*) ;; *) PIGEONHOLE_PROBLEM="OFFPRINT_HOME must be a whole path, starting with a slash."; return 1 ;; esac
  BOX="$home/pigeonhole/$SITE_NAME"
  if offprint_inside_site "$BOX"; then
    PIGEONHOLE_PROBLEM="the pigeonhole's folder, $(_offprint_shown "$BOX"), is inside the site folder, which WordPress can read and write; set OFFPRINT_HOME to a folder outside it."
    return 1
  fi
  for d in "$home" "$home/pigeonhole" "$BOX" "$BOX/spool" "$BOX/done" "$BOX/rejected"; do
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
      PIGEONHOLE_PROBLEM="$(_offprint_shown "$d") is not a folder (a link, or a file); move it away, then collect again."
      return 1
    fi
    if [ ! -d "$d" ]; then
      # (the Offprint folder itself may need the folders above it, in a new HOME; the rest are made one by one)
      case "$d" in "$home") mkdir -p "$d" 2> /dev/null ;; *) mkdir "$d" 2> /dev/null ;; esac \
        || { PIGEONHOLE_PROBLEM="couldn't make the folder $(_offprint_shown "$d")."; return 1; }
      case "$d" in "$home") ;; *) chmod 700 "$d" 2> /dev/null ;; esac
    fi
  done
  for d in "$BOX" "$BOX/spool" "$BOX/done" "$BOX/rejected"; do
    if [ -z "$(find "$d" -maxdepth 0 -type d -user "$(id -u)" ! -perm -040 ! -perm -020 ! -perm -010 \
        ! -perm -004 ! -perm -002 ! -perm -001 -print 2> /dev/null)" ]; then
      PIGEONHOLE_PROBLEM="$(_offprint_shown "$d") must be a folder of yours that nobody else can read (chmod 700), and it isn't."
      return 1
    fi
  done
  # made after the check above, so a link put in a folder's place in between is still refused
  if offprint_inside_site "$BOX/spool" || offprint_inside_site "$BOX/done" || offprint_inside_site "$BOX/rejected"; then
    PIGEONHOLE_PROBLEM="the pigeonhole's folder, $(_offprint_shown "$BOX"), leads into the site folder, which WordPress can read and write; set OFFPRINT_HOME to a folder outside it."
    return 1
  fi
  SPOOL="$BOX/spool"; DONE="$BOX/done"; REJECTED="$BOX/rejected"; PIGEONHOLE_REASON=""
}

# pigeonhole_lock: takes the spool's lock (BOX/lock; mkdir is atomic), so two runs never fetch into the spool or open
# what is in it at once. Returns 1 while another run holds it. One left behind is taken over: a fetch that was killed
# must not stop every later one, silently, for ever. Left behind means its pid is no process now, or it is older than
# any run can last (a run killed before it wrote its pid; a pid that is another program's since a restart). It is
# taken over as a publish takes its own stale lock: moved aside (only one rename can win), and put back if what was
# moved is not the lock that was looked at, so that two runs taking over at once can't both end up holding it.
# pigeonhole_unlock gives it back.
pigeonhole_lock() {
  local pid old stale=0
  PIGEONHOLE_PROBLEM=""; PIGEONHOLE_REASON=busy
  if ! mkdir "$BOX/lock" 2> /dev/null; then
    pid="$(head -c 20 "$BOX/lock/pid" 2> /dev/null | head -n 1)"
    if [ -L "$BOX/lock" ] || [ ! -d "$BOX/lock" ]; then stale=0
    elif [[ "$pid" =~ ^[0-9]{1,10}$ ]] && ! kill -0 "$pid" 2> /dev/null; then stale=1
    elif [ -n "$(find "$BOX/lock" -maxdepth 0 -mmin +"$PIGEONHOLE_LOCK_STALE_MINUTES" 2> /dev/null)" ]; then stale=1
    fi
    if [ "$stale" = 1 ] && mv "$BOX/lock" "$BOX/lock.stale.$$" 2> /dev/null; then
      old="$(head -c 20 "$BOX/lock.stale.$$/pid" 2> /dev/null | head -n 1)"
      if [ "$old" = "$pid" ]; then
        rm -rf "$BOX/lock.stale.$$"
      else
        # another run took it over, and this moved that run's new lock: back it goes
        mv "$BOX/lock.stale.$$" "$BOX/lock" 2> /dev/null || rm -rf "$BOX/lock.stale.$$"
        stale=0
      fi
    else
      stale=0
    fi
    if [ "$stale" != 1 ] || ! mkdir "$BOX/lock" 2> /dev/null; then
      PIGEONHOLE_PROBLEM="another fetch or collection is running for this site; wait for it, then try again."
      return 1
    fi
  fi
  PH_HAVE_LOCK=1; PIGEONHOLE_REASON=""
  echo "$$" > "$BOX/lock/pid"
}
pigeonhole_unlock() { [ "$PH_HAVE_LOCK" != 1 ] || rm -rf "$BOX/lock"; PH_HAVE_LOCK=0; }

# pigeonhole_ssh_open DIR: makes ready to speak to the store, in DIR, a private folder of this run's (made by
# offprint_private_dir): the config and known_hosts files, an ssh-agent of this run's own, and the pull key loaded into
# it from the Keychain, on a pipe. pigeonhole_ssh_close ends the agent (call it on every exit).
pigeonhole_ssh_open() {
  local dir="$1" sock tool waited=0 rc ssh_bin safe='^[A-Za-z0-9/._+=@-]+$'
  PIGEONHOLE_PROBLEM=""; PIGEONHOLE_REASON=setup
  for tool in ssh ssh-agent ssh-add php; do
    command -v "$tool" > /dev/null 2>&1 || { PIGEONHOLE_PROBLEM="$tool isn't on the PATH, and the fetch from the pigeonhole needs it."; return 1; }
  done
  ssh_bin="$(command -v ssh)"
  # Both go into the config file, where a space would end a word and % starts one of ssh's own: neither is quoted
  # around, they are refused. (A temporary folder's path has neither.)
  if ! [[ "$dir" =~ $safe ]] || ! [[ "$ssh_bin" =~ $safe ]]; then
    PIGEONHOLE_PROBLEM="the temporary folder's path (TMPDIR) or ssh's own has a space or another character an ssh config file can't hold plainly; set TMPDIR to a folder without one."
    return 1
  fi
  PH_DIR="$dir"; PH_CONFIG="$dir/config"; sock="$dir/a"
  # (The hop's command is run by ssh through the owner's own shell, whichever that is: each word of it is in single
  # quotes, so that none is read as a pattern. zsh takes [%h]:%p for one, and fails.)
  # Each machine is known by a name of this file's own (HostKeyAlias), so the one line for it below is the only key it
  # may show, whatever its address or port.
  printf '%s %s\n%s %s\n' offprint-jump "$SITE_PIGEONHOLE_JUMP_HOST_KEY" offprint-store "$SITE_PIGEONHOLE_SERVER_HOST_KEY" \
    > "$dir/known_hosts" || { PIGEONHOLE_PROBLEM="couldn't write this run's ssh files."; return 1; }
  cat > "$PH_CONFIG" <<CONFIG || { PIGEONHOLE_PROBLEM="couldn't write this run's ssh files."; return 1; }
Host offprint-jump
  HostName $SITE_PIGEONHOLE_JUMP
  Port $SITE_PIGEONHOLE_JUMP_PORT
  User $PIGEONHOLE_JUMP_USER
  HostKeyAlias offprint-jump
Host offprint-store
  HostName $SITE_PIGEONHOLE_SERVER
  Port $SITE_PIGEONHOLE_SERVER_PORT
  User $(pigeonhole_store_user)
  HostKeyAlias offprint-store
  ProxyCommand '$ssh_bin' -F '$PH_CONFIG' -W '[%h]:%p' offprint-jump
Host *
  BatchMode yes
  IdentityAgent $sock
  IdentityFile none
  IdentitiesOnly no
  PreferredAuthentications publickey
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  UserKnownHostsFile $dir/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  HostKeyAlgorithms ssh-ed25519
  UpdateHostKeys no
  CheckHostIP no
  VerifyHostKeyDNS no
  ForwardAgent no
  ForwardX11 no
  ClearAllForwardings yes
  ControlMaster no
  ControlPath none
  PermitLocalCommand no
  RequestTTY no
  Compression no
  ConnectTimeout 15
  ServerAliveInterval 10
  ServerAliveCountMax 3
  LogLevel ERROR
CONFIG
  # The agent, in the foreground of a background job (-D), so its pid is this shell's to kill. Nothing is asked of the
  # owner's own agent from here on.
  unset SSH_AUTH_SOCK SSH_AGENT_PID
  ssh-agent -D -a "$sock" > /dev/null 2>&1 < /dev/null &
  PH_AGENT_PID=$!
  while [ ! -e "$sock" ] && [ "$waited" -lt 50 ] && kill -0 "$PH_AGENT_PID" 2> /dev/null; do sleep 0.1; waited=$((waited + 1)); done
  if [ ! -e "$sock" ]; then
    PIGEONHOLE_PROBLEM="ssh-agent didn't start for this run$([ "${#sock}" -le 100 ] || printf ' (the temporary folder'"'"'s path is too long for its socket: set TMPDIR to a shorter one)')."
    return 1
  fi
  # The key: Keychain to pipe to pipe to ssh-add. What any of the three says is dropped.
  offprint_secret_get "$PIGEONHOLE_PULL_SECRET" 2> /dev/null | php "$TOOL/lib/pigeonhole-keys.php" decode 2> /dev/null \
    | SSH_AUTH_SOCK="$sock" SSH_ASKPASS_REQUIRE=never ssh-add -q -t 900 - > /dev/null 2>&1
  rc="${PIPESTATUS[0]} ${PIPESTATUS[1]} ${PIPESTATUS[2]}"
  case "$rc" in
    "0 0 0") ;;
    "1 "*) PIGEONHOLE_REASON=no-key
      PIGEONHOLE_PROBLEM="this site's pull key isn't in the login Keychain (the secret $PIGEONHOLE_PULL_SECRET); offprint pigeonhole keys makes it."; return 1 ;;
    "3 "*) PIGEONHOLE_REASON=locked
      PIGEONHOLE_PROBLEM="the login Keychain is locked, so the pull key couldn't be read; unlock it, then try again."; return 1 ;;
    "0 0 "*) PIGEONHOLE_REASON=bad-key
      PIGEONHOLE_PROBLEM="ssh-add didn't take this site's pull key, so nothing was fetched."; return 1 ;;
    "0 "*) PIGEONHOLE_REASON=bad-key
      PIGEONHOLE_PROBLEM="what the login Keychain holds as this site's pull key (the secret $PIGEONHOLE_PULL_SECRET) is not one; offprint pigeonhole keys makes it."; return 1 ;;
    *) PIGEONHOLE_REASON=keychain
      PIGEONHOLE_PROBLEM="the pull key couldn't be read from the login Keychain."; return 1 ;;
  esac
  PIGEONHOLE_REASON=""
}

# pigeonhole_ssh_close: the run's agent killed, and the key with it. (Its folder is the caller's to remove.)
pigeonhole_ssh_close() {
  # shellcheck disable=SC2046 # one pid a word
  [ -z "$PH_SSH_PID" ] || { kill $(pgrep -P "$PH_SSH_PID" 2> /dev/null) "$PH_SSH_PID" 2> /dev/null; wait "$PH_SSH_PID" 2> /dev/null; PH_SSH_PID=""; }
  [ -z "$PH_AGENT_PID" ] || { kill "$PH_AGENT_PID" 2> /dev/null; wait "$PH_AGENT_PID" 2> /dev/null; }
  PH_AGENT_PID=""
}

# pigeonhole_ssh WORDS: asks the store's pull command for WORDS (list, "get NAME", "delete NAME"); its answer is this
# function's standard output, its status this function's (124 when it was killed for taking longer than
# PIGEONHOLE_SSH_SECONDS). What ssh or the far side said of a failure is kept in the run's folder (ssh.err), for
# pigeonhole_ssh_why, and never shown as it is: a server can put anything there. That file can't grow past 32 KB
# (ulimit -f, in the shell that becomes ssh: more, and ssh is stopped).
PH_SSH_PID=""
pigeonhole_ssh() {
  local rc end=$((SECONDS + PIGEONHOLE_SSH_SECONDS))
  ( ulimit -f 64 2> /dev/null; exec ssh -F "$PH_CONFIG" -n -T offprint-store "$1" 2> "$PH_DIR/ssh.err" < /dev/null ) &
  PH_SSH_PID=$!
  while kill -0 "$PH_SSH_PID" 2> /dev/null && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
  if kill -0 "$PH_SSH_PID" 2> /dev/null; then
    # It and what it started (the ssh of the hop through the web server): one of those left alive would hold this
    # function's output open, and whoever reads it would wait on for as long as that one lived.
    # shellcheck disable=SC2046 # one pid a word
    kill $(pgrep -P "$PH_SSH_PID" 2> /dev/null) "$PH_SSH_PID" 2> /dev/null; wait "$PH_SSH_PID" 2> /dev/null; PH_SSH_PID=""
    return 124
  fi
  wait "$PH_SSH_PID" 2> /dev/null; rc=$?; PH_SSH_PID=""
  return "$rc"
}

# pigeonhole_ssh_why STATUS: after a pigeonhole_ssh that failed with STATUS, sets PIGEONHOLE_PROBLEM and
# PIGEONHOLE_REASON, in this tool's own fixed words. ssh's own failures (it exits 255) are told apart by what ssh said,
# and which machine it was by the names only this run's config uses. Any other status is the far command's own, and
# so is whatever it printed: a store must not be able to point the owner at the web server by printing ssh's words.
# No message names an address: the agent logs these lines in var/, which WordPress can read; site.json has them.
pigeonhole_ssh_why() {
  local said=""
  case "${1:-255}" in
    255) said="$(head -c 4096 "$PH_DIR/ssh.err" 2> /dev/null | LC_ALL=C tr -c ' -~\n' '?')" ;;
    124)
      PIGEONHOLE_REASON=slow
      PIGEONHOLE_PROBLEM="the pigeonhole's server took longer than $PIGEONHOLE_SSH_SECONDS seconds to answer, so it was cut off. offprint pigeonhole doctor checks each step."
      return ;;
    *)
      PIGEONHOLE_REASON=store-answer
      PIGEONHOLE_PROBLEM="the pigeonhole's server was reached, but its pull command failed. Is it the one this Offprint prints? (offprint pigeonhole print-server store)"
      return ;;
  esac
  case "$said" in
    *"host key"*offprint-jump*|*offprint-jump*"host key"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*offprint-jump*)
      PIGEONHOLE_REASON=jump-host-key
      PIGEONHOLE_PROBLEM="the web server (site.json's pigeonhole.jump) didn't show the ssh host key site.json pins for it (pigeonhole.jump_host_key), so it wasn't spoken to. If the machine was rebuilt, check its new key with its owner before changing site.json." ;;
    *"host key"*offprint-store*|*offprint-store*"host key"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
      PIGEONHOLE_REASON=store-host-key
      PIGEONHOLE_PROBLEM="the pigeonhole's server (site.json's pigeonhole.server) didn't show the ssh host key site.json pins for it (pigeonhole.server_host_key), so it wasn't spoken to. If the machine was rebuilt, check its new key before changing site.json." ;;
    *"$PIGEONHOLE_JUMP_USER@"*"Permission denied"*)
      PIGEONHOLE_REASON=jump-refused
      PIGEONHOLE_PROBLEM="the web server (site.json's pigeonhole.jump) refused this site's pull key: is the key in its $PIGEONHOLE_JUMP_USER user's authorized_keys? (offprint pigeonhole print-server web)" ;;
    *"Permission denied"*)
      PIGEONHOLE_REASON=store-refused
      PIGEONHOLE_PROBLEM="the pigeonhole's server (site.json's pigeonhole.server) refused this site's pull key: is the key in its $(pigeonhole_store_user) user's authorized_keys, and does the connection come from the web server's own address? (offprint pigeonhole print-server store)" ;;
    *"administratively prohibited"*|*"open failed"*|*"stdio forwarding failed"*)
      PIGEONHOLE_REASON=jump-forward
      PIGEONHOLE_PROBLEM="the web server (site.json's pigeonhole.jump) wouldn't open a connection on to the pigeonhole's server: its authorized_keys line must permit exactly that address and port (offprint pigeonhole print-server web)." ;;
    *)
      PIGEONHOLE_REASON=unreachable
      PIGEONHOLE_PROBLEM="the pigeonhole's server couldn't be reached over ssh, through the web server (site.json's pigeonhole.jump). Is this Mac online, and are both machines up? offprint pigeonhole doctor checks each step." ;;
  esac
}

# pigeonhole_fetch: everything the store holds, into the spool (see the top). Needs pigeonhole_box, the lock and
# pigeonhole_ssh_open. Sets FETCHED (new in the spool), FETCH_DAMAGED (left on the store: not what their names say)
# and FETCH_LEFT (not taken this time). Returns 1 when the store couldn't be asked or stopped answering.
pigeonhole_fetch() {
  local names name f size hash rc count=0 failures=0 name_re='^[0-9a-f]{64}\.age$' end=$((SECONDS + PIGEONHOLE_FETCH_SECONDS))
  FETCHED=0; FETCH_DAMAGED=0; FETCH_LEFT=0; PIGEONHOLE_PROBLEM=""; PIGEONHOLE_REASON=""
  # what a run that was cut short left half-fetched: never a submission
  find "$SPOOL" -maxdepth 1 -name '.incoming-*' -exec rm -rf {} + 2> /dev/null
  # (no more is read of the list than the most names it may hold)
  rc=0; names="$(pigeonhole_ssh list | head -c $((PIGEONHOLE_MAX_NAMES * 70 + 1)); exit "${PIPESTATUS[0]}")" || rc=$?
  [ "$rc" = 0 ] || { pigeonhole_ssh_why "$rc"; return 1; }
  [ -n "$names" ] || return 0
  # The list is the store's word, so every line of it is matched before any is used; one that isn't a name means this
  # is not the pull command answering, and nothing is fetched.
  while IFS= read -r name; do
    count=$((count + 1))
    if ! [[ "$name" =~ $name_re ]] || [ "$count" -gt "$PIGEONHOLE_MAX_NAMES" ]; then
      PIGEONHOLE_REASON=not-a-list
      PIGEONHOLE_PROBLEM="what the pigeonhole's server answered is not a list of submissions, so nothing was fetched. Is its pull command the one this Offprint prints? (offprint pigeonhole print-server store)"
      return 1
    fi
  done <<EOT
$names
EOT
  while IFS= read -r name; do
    # A fetch has its time, and no more: what is left then is on the store still, for the next.
    if [ "$SECONDS" -ge "$end" ]; then FETCH_LEFT=$((FETCH_LEFT + 1)); continue; fi
    if [ -f "$SPOOL/$name" ] || [ -f "$DONE/$name" ] || [ -f "$REJECTED/$name" ]; then
      # Held here already (a fetch was cut short after it was kept): only the store's copy is left to remove.
      pigeonhole_ssh "delete $name" > /dev/null || FETCH_LEFT=$((FETCH_LEFT + 1))
      continue
    fi
    f="$SPOOL/.incoming-$name"
    rm -rf "$f" 2> /dev/null
    rc=0; ( umask 077; pigeonhole_ssh "get $name" | head -c $((PIGEONHOLE_MAX_BYTES + 1)) > "$f"; exit "${PIPESTATUS[0]}" ) || rc=$?
    if [ "$rc" != 0 ]; then
      rm -f "$f"; FETCH_LEFT=$((FETCH_LEFT + 1)); failures=$((failures + 1))
      # Twice running, and it is the connection that is the trouble, not one file.
      if [ "$failures" -ge 2 ]; then pigeonhole_ssh_why "$rc"; return 1; fi
      continue
    fi
    failures=0
    size="$(wc -c < "$f" 2> /dev/null | tr -d ' ')" || size=""
    hash=""
    case "$size" in ''|*[!0-9]*) ;; *)
      if [ "$size" -gt 0 ] && [ "$size" -le "$PIGEONHOLE_MAX_BYTES" ] && [ -f "$f" ] && [ ! -L "$f" ]; then
        hash="$(php -r 'echo hash_file("sha256", $argv[1]);' -- "$f" 2> /dev/null < /dev/null)" || hash=""
      fi ;;
    esac
    if [ "$hash.age" != "$name" ]; then
      # Not the bytes its name says: not kept, and left where it is for the owner to look at.
      rm -f "$f"; FETCH_DAMAGED=$((FETCH_DAMAGED + 1))
      continue
    fi
    mv -f -- "$f" "$SPOOL/$name" 2> /dev/null || { rm -f "$f"; FETCH_LEFT=$((FETCH_LEFT + 1)); continue; }
    FETCHED=$((FETCHED + 1))
    # Only now, held whole under its own name, is it removed from the store. Should that fail, the next fetch sees the
    # name again, finds it held here, and removes it then.
    pigeonhole_ssh "delete $name" > /dev/null || true
  done <<EOT
$names
EOT
  return 0
}

# pigeonhole_waiting: how many things are in the spool (what is fetched and not opened), on standard output.
pigeonhole_waiting() {
  local f n=0
  for f in "$SPOOL"/*; do [ ! -e "$f" ] && [ ! -L "$f" ] || n=$((n + 1)); done
  printf '%s' "$n"
}

# pigeonhole_fetch_status OK: writes var/pigeonhole-fetch.json for the admin bar: when, whether it worked (OK: true or
# false), the counts, and the one fixed word of why not. Numbers and that word only: nothing a server or a stranger sent.
pigeonhole_fetch_status() {
  local reason="$PIGEONHOLE_REASON"
  [[ "$reason" =~ ^[a-z-]{0,30}$ ]] || reason=unknown
  mkdir -p "$SITE/var" 2> /dev/null
  printf '{"fetched_at":%s,"ok":%s,"fetched":%s,"damaged":%s,"left":%s,"waiting":%s,"reason":"%s"}\n' \
    "$(date +%s)" "$1" "$FETCHED" "$FETCH_DAMAGED" "$FETCH_LEFT" "$(pigeonhole_waiting)" "$reason" \
    > "$SITE/var/pigeonhole-fetch.json.$$" 2> /dev/null && mv -f "$SITE/var/pigeonhole-fetch.json.$$" "$SITE/var/pigeonhole-fetch.json" 2> /dev/null
  rm -f "$SITE/var/pigeonhole-fetch.json.$$" 2> /dev/null
}
