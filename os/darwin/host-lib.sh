# Sourced by os/darwin/host-setup.sh and host-undo.sh, which run as root, once they have set TOOL. It sources
# lib/site.sh first: its top level makes the PATH (root's, under sudo) safe to use before anything is looked up on it
# (lib/site.sh's header), and sets variables these scripts don't read, TOOL to the same folder; of its functions,
# host_start uses offprint_drop_site_path, offprint_check_tmpdir and offprint_private_dir. Otherwise this only defines
# functions. host_start, which both call first, reads their arguments ([--print] [--adopt] SITE_DIR), applies the test
# seams and the root check, and loads the site's names from its site.json through lib/config.php. It checks every name
# again, with its own patterns, before either script uses one: they go into /etc/hosts, launchd plists and ifconfig, as
# root. The callers set LC_ALL=C, so [a-z] here is the 26 ASCII letters and nothing else.
#
# Ownership: what host-setup writes carries the site folder's stamp, the sha256 of the folder's physical path: an XML
# comment "<!-- offprint site STAMP -->" in each plist, and a line "# site STAMP" right after the begin marker of the
# hosts block. "This site's" means the expected name or markers AND this stamp; anything else is someone else's.
# Needs bash 3.2 (macOS) or newer.

# Without it, the PATH clean-up and offprint_check_tmpdir (the TMPDIR defence) would be missing, not run: so a copy of
# Offprint that has no readable lib/site.sh is refused here, in one line, before anything else; and so is one whose
# lib/site.sh fails (it says why).
{ [ -f "$TOOL/lib/site.sh" ] && [ -r "$TOOL/lib/site.sh" ]; } \
  || { echo "${0##*/}: $TOOL/lib/site.sh couldn't be read, so nothing was done (is this copy of Offprint whole?)" >&2; exit 2; }
# shellcheck source=lib/site.sh
. "$TOOL/lib/site.sh" || exit 2

# shq STRING: STRING in single quotes, for a line to paste into a shell (each ' in it becomes '\'').
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

host_die() { echo "$JOB: $*" >&2; exit 2; }

host_usage() {
  local adopt=""; [ "$JOB" != host-setup ] || adopt=" [--adopt]"
  echo "usage: sudo /bin/bash $(shq "$SELF")$adopt SITE_DIR" >&2
  echo "       /bin/bash $(shq "$SELF") --print$adopt SITE_DIR    (shows what it would do; needs no root, changes nothing)" >&2
  exit 2
}

# On exit: the temporary folder goes, and with the test seams in use, the last line says so again.
host_end() {
  [ -z "${WORK:-}" ] || rm -rf "$WORK"
  [ "${SEAMS:-0}" = 0 ] || echo "test seams in use: this Mac was not changed" >&2
}

# phys PATH: PATH with every link in its folder resolved. Its folder must exist; PATH itself need not.
phys() {
  local dir
  dir="$(CDPATH= cd -P -- "$(dirname -- "$1")" 2> /dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "${dir%/}" "$(basename -- "$1")"
}

# is_real PATH REAL: PATH is the real REAL: the same file (device and inode), or the same physical path.
is_real() {
  local p r
  [ "$1" -ef "$2" ] && return 0
  p="$(phys "${1%/}")" || return 1
  r="$(phys "$2")" || r="$2"
  [ "$p" = "$r" ] || [ "$p" = "$2" ]
}

# host_start JOB ARGS...: everything both scripts do before they look at the machine. Sets JOB, SELF, PRINT, ADOPT,
# SITE_DIR (and SITE, the same), the seams (SEAMS, HOSTS, DAEMONS, IFCONFIG, LAUNCHCTL, LSOF), WORK (a temporary
# folder, removed on exit),
# the site's names (SITE_NAME, SITE_LOCAL_HOST, SITE_IP4, SITE_IP6, SITE_TLS_PORT, SITE_HTTP_PORT, SITE_DAEMON_PREFIX),
# STAMP, the block markers BEGIN and END, NOTE (see host-setup.sh), BACKUP (the copy of the hosts file from before),
# OURS (both addresses, sorted, one space between), LO0 (what ifconfig says about lo0) and HOSTS_OK (0 when the hosts
# file can't be read). A read that fails is a refusal (refuse, below), so nothing is decided on a guess.
host_start() {
  JOB="$1"; shift
  SELF="$TOOL/os/darwin/$JOB.sh"
  PRINT=0; ADOPT=0; WORK=""; SEAMS=0
  trap host_end EXIT
  local arg site_arg="" p
  for arg in "$@"; do
    case "$arg" in
      --print) PRINT=1 ;;
      --adopt) [ "$JOB" = host-setup ] || host_usage; ADOPT=1 ;;
      -*) host_usage ;;
      *) [ -z "$site_arg" ] || host_usage; site_arg="$arg" ;;
    esac
  done
  [ -n "$site_arg" ] || host_usage
  p="$site_arg"
  case "$p" in /*) ;; *) p="./$p" ;; esac   # a name like "-" must stay a folder name
  if [ ! -d "$p" ] || [ ! -f "$p/site.json" ]; then host_die "$site_arg is not a site folder (a folder holding site.json)."; fi
  # The folder's physical path in the disk's own letter case, which the stamp is made from: /bin/pwd asks the system,
  # where bash's own pwd keeps the case as typed (on a disk that ignores case, the same folder could get two stamps).
  if [ -x /bin/pwd ]; then
    SITE_DIR="$(CDPATH= cd -P -- "$p" && /bin/pwd -P)" || host_die "can't open $site_arg."
  else
    SITE_DIR="$(CDPATH= cd -P -- "$p" && pwd -P)" || host_die "can't open $site_arg."
  fi
  # Every PATH entry that is the site folder or inside it, where WordPress can write, is left out (lib/site.sh), now
  # that the site folder is known and before anything is looked up on the PATH (only builtins and /bin/pwd have run).
  SITE="$SITE_DIR"; offprint_drop_site_path "$SITE_DIR"

  host_seams
  host_root
  host_tmpdir "$(id -u)" "$SEAMS"
  # The working folder (WORK, below) feeds the hosts file and the plists. In a TMPDIR that is the site folder or inside
  # it, where WordPress can write, it could be swapped for a link and those written through it: so such a TMPDIR is
  # refused here, in one line, exit 2, before anything is made (lib/site.sh, the site folder being SITE_DIR). It is
  # asked once host_tmpdir has decided whether TMPDIR is kept: as root with no seams it is unset, so one sudo -E passed
  # through (a missing one, say) is set aside rather than refused. (Nothing above makes a file.)
  offprint_check_tmpdir
  if [ "$SEAMS" = 0 ] && [ "$(uname -s)" != Darwin ]; then host_die "this is for macOS (it runs ifconfig, launchctl and lsof)."; fi
  # Made in TMPDIR's own folder on disk, and only a real folder of this user's with no access for others will do
  # (lib/site.sh's offprint_private_dir).
  offprint_private_dir "offprint-$JOB" WORK \
    || { WORK=""; host_die "can't make a temporary folder${OFFPRINT_PRIVATE_PROBLEM:+: $OFFPRINT_PRIVATE_PROBLEM}."; }
  host_load
  host_check
  # The stamp: the sha256 of the site folder's physical path, worked out with the php this needs anyway.
  STAMP="$(php -r 'echo hash("sha256", $argv[1]);' -- "$SITE_DIR" 2> /dev/null)" || STAMP=""
  [[ $STAMP =~ ^[0-9a-f]{64}$ ]] || host_die "couldn't work out the site folder's stamp (php's sha256 of its path)."

  BEGIN="# >>> offprint: $SITE_LOCAL_HOST >>>"
  END="# <<< offprint: $SITE_LOCAL_HOST <<<"
  NOTE="# (offprint added the newline at the end of the line before this block)"
  BACKUP="$HOSTS.before-offprint"
  OURS="$(printf '%s\n%s\n' "$SITE_IP4" "$SITE_IP6" | sort -u | paste -sd' ' -)"
  HOSTS_OK=1
  if ! cat "$HOSTS" > "$WORK/hosts.orig" 2> /dev/null; then refuse "can't read $HOSTS."; HOSTS_OK=0; fi
  if ! LO0="$("$IFCONFIG" lo0 2> "$WORK/ifconfig.err")"; then
    refuse "couldn't read lo0: $IFCONFIG lo0 failed ($(head -1 "$WORK/ifconfig.err"))."
    LO0=""
  fi
}

# The test seams. With none set, the real files and commands. Set one, and all five must be set, the hosts file and
# the daemon folder must not be (or link to) the real ones, and the three commands must be programs: so no test, and
# no mistake, can reach this Mac's real files or run its real ifconfig, launchctl or lsof without sudo. With them in
# use, the first and the last line say so.
host_seams() {
  SEAMS=0
  HOSTS=/etc/hosts; DAEMONS=/Library/LaunchDaemons
  IFCONFIG=/sbin/ifconfig; LAUNCHCTL=/bin/launchctl; LSOF=/usr/sbin/lsof
  if [ -z "${OFFPRINT_HOSTS_FILE:-}${OFFPRINT_DAEMON_DIR:-}${OFFPRINT_IFCONFIG:-}${OFFPRINT_LAUNCHCTL:-}${OFFPRINT_LSOF:-}" ]; then
    return 0
  fi
  local missing="" v
  [ -n "${OFFPRINT_HOSTS_FILE:-}" ] || missing="$missing OFFPRINT_HOSTS_FILE"
  [ -n "${OFFPRINT_DAEMON_DIR:-}" ] || missing="$missing OFFPRINT_DAEMON_DIR"
  [ -n "${OFFPRINT_IFCONFIG:-}" ] || missing="$missing OFFPRINT_IFCONFIG"
  [ -n "${OFFPRINT_LAUNCHCTL:-}" ] || missing="$missing OFFPRINT_LAUNCHCTL"
  [ -n "${OFFPRINT_LSOF:-}" ] || missing="$missing OFFPRINT_LSOF"
  [ -z "$missing" ] || host_die "the test seams go together, and these are not set:$missing. (They are for tests/host.test.sh; see the header of $SELF.)"
  HOSTS="$OFFPRINT_HOSTS_FILE"; DAEMONS="${OFFPRINT_DAEMON_DIR%/}"
  IFCONFIG="$OFFPRINT_IFCONFIG"; LAUNCHCTL="$OFFPRINT_LAUNCHCTL"; LSOF="$OFFPRINT_LSOF"
  if [ -L "$HOSTS" ] || [ ! -f "$HOSTS" ]; then host_die "OFFPRINT_HOSTS_FILE ($HOSTS) must be a plain file, not a link."; fi
  if [ -L "$DAEMONS" ] || [ ! -d "$DAEMONS" ]; then host_die "OFFPRINT_DAEMON_DIR ($OFFPRINT_DAEMON_DIR) must be a folder, not a link."; fi
  if is_real "$HOSTS" /etc/hosts; then host_die "OFFPRINT_HOSTS_FILE is this Mac's /etc/hosts; a test seam must point elsewhere."; fi
  if is_real "$DAEMONS" /Library/LaunchDaemons; then host_die "OFFPRINT_DAEMON_DIR is this Mac's /Library/LaunchDaemons; a test seam must point elsewhere."; fi
  for v in "$IFCONFIG" "$LAUNCHCTL" "$LSOF"; do
    if [ ! -f "$v" ] || [ ! -x "$v" ]; then host_die "$v (a test seam) is not a program."; fi
  done
  SEAMS=1
  echo "test seams in use: this Mac was not changed" >&2
}

# host_tmpdir UID SEAMS: as root (UID 0) with no test seams in use (SEAMS 0), a real run, TMPDIR is unset, so the
# working folder is made in /tmp. A TMPDIR passed through (sudo -E keeps it) is the owner's own folder, where a process
# of theirs could swap the working folder for a link between being made and being written, and so have root write the
# hosts file or a plist through it. With the seams in use, or not as root, TMPDIR is kept (the tests' own folders).
host_tmpdir() {
  if [ "$1" = 0 ] && [ "$2" = 0 ]; then unset TMPDIR; fi
  return 0
}

# Root, unless only printing. OFFPRINT_SKIP_ROOT_CHECK=1 counts only with the seams in use (see host_seams).
host_root() {
  local adopt=""; [ "$ADOPT" = 0 ] || adopt=" --adopt"
  [ "$PRINT" = 1 ] && return 0
  [ "$(id -u)" = 0 ] && return 0
  if [ "$SEAMS" = 1 ] && [ "${OFFPRINT_SKIP_ROOT_CHECK:-}" = 1 ]; then return 0; fi
  echo "$JOB changes lo0, /etc/hosts and /Library/LaunchDaemons, so it runs as root. Run:"
  echo "  sudo /bin/bash $(shq "$SELF")$adopt $(shq "$SITE_DIR")"
  echo "(To see first what it would do, without root: /bin/bash $(shq "$SELF") --print$adopt $(shq "$SITE_DIR"))"
  exit 1
}

# The site's names, from lib/config.php's KEY<TAB>value lines. Only these seven are ever assigned; nothing from the
# file is sourced or evaluated.
host_load() {
  local out key value
  if ! command -v php > /dev/null 2>&1; then
    local adopt=""; [ "$ADOPT" = 0 ] || adopt=" --adopt"
    echo "$JOB: php is not on this PATH ($PATH), and site.json is read with php (lib/config.php)." >&2
    echo "sudo may have given root a PATH without php's folder (Homebrew's is /opt/homebrew/bin, or /usr/local/bin on an Intel Mac). Run it with that folder on PATH:" >&2
    echo "  sudo env PATH=\"/opt/homebrew/bin:/usr/local/bin:\$PATH\" /bin/bash $(shq "$SELF")$adopt $(shq "$SITE_DIR")" >&2
    exit 2
  fi
  if ! out="$(php "$TOOL/lib/config.php" "$SITE_DIR" 2> "$WORK/config.err")"; then
    cat "$WORK/config.err" >&2
    host_die "$SITE_DIR/site.json has the problems above; nothing was changed."
  fi
  SITE_NAME=""; SITE_LOCAL_HOST=""; SITE_IP4=""; SITE_IP6=""; SITE_TLS_PORT=""; SITE_HTTP_PORT=""; SITE_DAEMON_PREFIX=""
  while IFS=$'\t' read -r key value; do
    case "$key" in
      SITE_NAME) SITE_NAME="$value" ;;
      SITE_LOCAL_HOST) SITE_LOCAL_HOST="$value" ;;
      SITE_IP4) SITE_IP4="$value" ;;
      SITE_IP6) SITE_IP6="$value" ;;
      SITE_TLS_PORT) SITE_TLS_PORT="$value" ;;
      SITE_HTTP_PORT) SITE_HTTP_PORT="$value" ;;
      SITE_DAEMON_PREFIX) SITE_DAEMON_PREFIX="$value" ;;
      *) ;;
    esac
  done <<EOT
$out
EOT
}

# Each name again, against the same rules as lib/config.php's: none can hold a character that a shell, XML, a regular
# expression or the hosts file treats specially.
host_check() {
  local bad="" re part big=0
  re='^[a-z][a-z0-9-]{0,30}$'
  [[ $SITE_NAME =~ $re ]] || bad="$bad name"
  re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  if ! [[ $SITE_LOCAL_HOST =~ $re ]] || [ "${#SITE_LOCAL_HOST}" -gt 253 ]; then bad="$bad local_host"; fi
  re='^127\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'
  if [[ $SITE_IP4 =~ $re ]] && [ "$SITE_IP4" != 127.0.0.1 ]; then
    for part in ${SITE_IP4//./ }; do [ "$part" -le 255 ] || big=1; done
    [ "$big" = 0 ] || bad="$bad local_ip4"
  else
    bad="$bad local_ip4"
  fi
  re='^fd[0-9a-f]{2}(:[0-9a-f]{1,4}){0,6}::[0-9a-f]{1,4}$'
  [[ $SITE_IP6 =~ $re ]] || bad="$bad local_ip6"
  re='^[1-9][0-9]{3,4}$'
  if [[ $SITE_TLS_PORT =~ $re ]] && [ "$SITE_TLS_PORT" -ge 1024 ] && [ "$SITE_TLS_PORT" -le 65535 ]; then
    if [ "$SITE_TLS_PORT" = "$SITE_HTTP_PORT" ]; then bad="$bad http_port(the same as tls_port)"; fi
  else
    bad="$bad tls_port"
  fi
  if ! [[ $SITE_HTTP_PORT =~ $re ]] || [ "$SITE_HTTP_PORT" -lt 1024 ] || [ "$SITE_HTTP_PORT" -gt 65535 ]; then bad="$bad http_port"; fi
  re='^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$'
  [[ $SITE_DAEMON_PREFIX =~ $re ]] || bad="$bad daemon_prefix"
  [ -z "$bad" ] || host_die "lib/config.php gave a value this will not use, for:$bad. Nothing was changed."
}

# note FILE TEXT: one line of TEXT in FILE, control characters (but tabs) shown as ?. refuse: a clash, which stops
# everything; leave: something host-undo leaves as it is; done_step: a change made, for stop to list.
note() { printf '  - %s\n' "$(printf '%s' "$2" | tr '\001-\010\013-\037\177' '?')" >> "$1"; }
refuse() { note "$WORK/refused" "$*"; }
leave() { note "$WORK/left" "$*"; }
done_step() { note "$WORK/done" "$*"; }

# lo0_has inet|inet6 ADDRESS: ADDRESS is on lo0 (as ifconfig said, in LO0).
lo0_has() { printf '%s\n' "$LO0" | awk -v k="$1" -v a="$2" '$1 == k && tolower($2) == a { f = 1 } END { exit !f }'; }

# job_state LABEL: "loaded" or "absent" (launchctl print exits 0, or 113: no such service), else "error N".
job_state() {
  local rc=0
  "$LAUNCHCTL" print "system/$1" > /dev/null 2>&1 || rc=$?
  case "$rc" in 0) echo loaded ;; 113) echo absent ;; *) echo "error $rc" ;; esac
}

# plist_addresses FILE: the addresses a plist names, one per line, sorted: each SockNodeName (a relay's), and each
# address after "alias" (the loopback job's). Only the shapes host-setup writes are read; anything else names none.
plist_addresses() {
  {
    grep -oE '<key>SockNodeName</key>[[:space:]]*<string>[^<]*</string>' "$1" | sed -e 's/.*<string>//' -e 's/<\/string>$//'
    grep -oE 'alias [^ ;<]+' "$1" | sed 's/^alias //'
  } 2> /dev/null | tr 'A-F' 'a-f' | sort -u
}
# names_ours FILE: it names this site's two addresses and nothing else. addresses_of FILE: what it names, for a message.
names_ours() { [ "$(plist_addresses "$1" | paste -sd' ' -)" = "$OURS" ]; }
addresses_of() { local a; a="$(plist_addresses "$1" | paste -sd' ' -)"; printf '%s' "${a:-no address}"; }

# plist_owner FILE: "ours" (this site folder's stamp, and no other), "none" (no Offprint stamp) or "other".
plist_owner() {
  local s
  s="$(grep -oE '<!-- offprint site [0-9a-f]{64} -->' "$1" 2> /dev/null | sort -u | sed -e 's/^<!-- offprint site //' -e 's/ -->$//')"
  if [ -z "$s" ]; then echo none; elif [ "$s" = "$STAMP" ]; then echo ours; else echo other; fi
}
# unstamped FILE: FILE without its stamp lines (to compare it with what this would write, but for the stamp).
unstamped() { grep -vE '^<!-- offprint site [0-9a-f]{64} -->$' "$1" 2> /dev/null || true; }
# whose OWNER: the words for a message.
whose() { case "$1" in none) echo "it has no Offprint stamp" ;; *) echo "it carries another site folder's Offprint stamp" ;; esac; }

# has_markers: either of this site's markers is a line of the hosts file.
has_markers() { grep -qxF -- "$BEGIN" "$HOSTS" || grep -qxF -- "$END" "$HOSTS"; }

# block_owner: of this site's block: "ours", "none" or "other", from the stamp line right after the begin marker.
block_owner() {
  local s
  s="$(awk -v b="$BEGIN" '
    after { if (length($0) == 71 && substr($0, 1, 7) == "# site " && substr($0, 8) !~ /[^0-9a-f]/) print substr($0, 8); exit }
    $0 == b { after = 1 }' "$HOSTS")"
  if [ -z "$s" ]; then echo none; elif [ "$s" = "$STAMP" ]; then echo ours; else echo other; fi
}
# block_body: the block's lines, but for the stamp line right after the begin marker and the newline note.
block_body() {
  awk -v b="$BEGIN" -v e="$END" -v n="$NOTE" '
    $0 == b { on = 1; first = 1; next }
    on && $0 == e { on = 0; next }
    on { if (first && substr($0, 1, 7) == "# site ") { first = 0; next } first = 0; if ($0 != n) print }' "$HOSTS"
}
# note_at_end: this site's block holds the newline note (host-setup found no newline at the end of the file), and
# still ends the file, so the newline it added is taken away with it.
note_at_end() {
  awk -v b="$BEGIN" -v e="$END" -v n="$NOTE" '
    $0 == b { on = 1; seen = 0; next }
    on && $0 == n { seen = 1 }
    on && $0 == e { on = 0; last = NR; had = seen }
    END { exit !(had && last == NR) }' "$HOSTS"
}
# drop_final_newline FILE: FILE without the newline after its last line.
drop_final_newline() {
  awk 'NR > 1 { print prev } { prev = $0 } END { if (NR) printf "%s", prev }' "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

# hosts_outside: the lines of the hosts file, outside this site's block, that name local_host ("name"), or give one of
# the site's addresses to a name ("address"), or both ("name+address"), as "NUMBER<TAB>KIND<TAB>the line". A comment
# is not a line here, and a CR at the end of a line is not part of it. Names are compared without case, as the
# resolver compares them.
hosts_outside() {
  awk -v b="$BEGIN" -v e="$END" -v h="$SITE_LOCAL_HOST" -v a4="$SITE_IP4" -v a6="$SITE_IP6" '
    $0 == b { inside = 1; next }
    inside && $0 == e { inside = 0; next }
    inside { next }
    {
      line = $0; sub(/\r$/, "", line); $0 = line; sub(/#.*/, ""); kind = ""
      for (i = 2; i <= NF; i++) if (tolower($i) == h) kind = "name"
      if (NF >= 2 && (tolower($1) == a4 || tolower($1) == a6)) kind = kind (kind == "" ? "" : "+") "address"
      if (kind != "") print NR "\t" kind "\t" line
    }' "$HOSTS"
}

# block_strays: the lines inside this site's block that are not one of its two addresses followed by local_host.
block_strays() {
  awk -v b="$BEGIN" -v e="$END" -v h="$SITE_LOCAL_HOST" -v a4="$SITE_IP4" -v a6="$SITE_IP6" '
    $0 == b { inside = 1; next }
    inside && $0 == e { inside = 0; next }
    !inside { next }
    {
      line = $0; sub(/\r$/, "", line); $0 = line; sub(/#.*/, "")
      if (NF == 0) next
      bad = (NF < 2) || !(tolower($1) == a4 || tolower($1) == a6)
      for (i = 2; i <= NF; i++) if (tolower($i) != h) bad = 1
      if (bad) print line
    }' "$HOSTS"
}

# The resolver's cache, after the hosts file changed. Never with the test seams: then no real system command runs.
flush_dns() {
  [ "$SEAMS" = 0 ] || return 0
  /usr/bin/dscacheutil -flushcache 2> /dev/null || true
  /usr/bin/killall -HUP mDNSResponder 2> /dev/null || true
}

# stop WHY: a change failed, after the checks had passed. Says exactly what had been done, and how to go on or back.
stop() {
  echo "$JOB stopped: $*" >&2
  if [ ! -s "$WORK/done" ]; then
    echo "Nothing was changed." >&2
  elif [ "$JOB" = host-setup ] && [ "$ADOPT" = 1 ]; then
    # Half adopted: the files it wrote (the "wrote" lines) carry this folder's stamp; what it loaded, unloaded, added to
    # lo0 or copied carries none, and what it never reached may carry the old folder's. host-setup without --adopt
    # refuses the old-stamped things, and host-undo would take away only the re-stamped ones (leaving the old-stamped
    # relays listening on addresses it had removed), so the only way on is --adopt again.
    echo "What it had done before it stopped:" >&2
    cat "$WORK/done" >&2
    echo "This was an --adopt run, and it stopped part way. The files it wrote (the \"wrote\" lines above) now carry this folder's stamp;" >&2
    echo "the rest of this site's set-up may still carry the old folder's stamp. host-setup without --adopt refuses" >&2
    echo "that, and host-undo would remove only the re-stamped part, so neither is the way out of this state. Finish" >&2
    echo "the adoption by running host-setup again, with --adopt:" >&2
    echo "  sudo /bin/bash $(shq "$TOOL/os/darwin/host-setup.sh") --adopt $(shq "$SITE_DIR")" >&2
  elif [ "$JOB" = host-setup ]; then
    echo "What it had done before it stopped:" >&2
    cat "$WORK/done" >&2
    echo "All of it is this site's: the plists and the hosts block carry its stamp, and its stamped $SITE_DAEMON_PREFIX.loopback.plist" >&2
    echo "names the addresses. So host-setup run again finishes the set-up, and host-undo takes all of it away again" >&2
    echo "(keeping $BACKUP, as it always does):" >&2
    echo "  sudo /bin/bash $(shq "$TOOL/os/darwin/host-undo.sh") $(shq "$SITE_DIR")" >&2
  else
    echo "What it had done before it stopped:" >&2
    cat "$WORK/done" >&2
    echo "Run host-undo again to remove the rest." >&2
  fi
  exit 1
}
