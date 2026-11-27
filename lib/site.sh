# Offprint: makes the PATH safe to use, finds a site folder and loads its site.json. Source it first thing in a script,
# found by the shell's own builtins (no dirname: nothing may be looked up on the PATH before this has run), and stop
# when it fails:
#
#   case "${BASH_SOURCE[0]}" in */*) here="${BASH_SOURCE[0]%/*}" ;; *) here=. ;; esac
#   . "$here/../lib/site.sh" || exit 2
#   offprint_find_site     # sets SITE (absolute, physical path)
#   offprint_load_site     # sets SITE_NAME, SITE_PUBLIC_URL, ... (see the case below)
#   dc up -d               # docker compose for this site, once its compose project is known to be this site's
#
# Works on macOS /bin/bash 3.2 and Linux bash. site.json is parsed by lib/config.php, which validates it; nothing from
# it is ever sourced or eval'ed here. TOOL is the tool's root folder, taken from this file's own location.
#
# The PATH. A program a command runs by name is the first of that name on the PATH it is given. An empty entry (a
# leading, trailing or doubled colon), "." or any other entry that isn't an absolute path is whatever folder the command
# runs in; and an entry that is a site folder or inside one (or a link that leads there) is a folder WordPress may write
# (wp-content/, var/export, var/inbox: everything in its container is untrusted). From either, a look-alike bash,
# dirname, php, git, docker or curl that WordPress put there would run as the owner, and could ask the Keychain for the
# site's token itself. So, as this file is sourced, before anything is looked up on the PATH (its top level runs the
# shell's own builtins only): offprint_clean_path leaves out every entry that isn't an absolute path (~ and ~/... are
# HOME's first, as bash takes them, when HOME is an absolute path with no colon in it: a PATH can't hold one, so with
# one they are left out); then offprint_drop_site_path every entry that is the site folder this runs in (or below), or
# OFFPRINT_SITE's, or inside either; and offprint_find_site, once it knows the site folder, that one's. Inside is asked
# of the disk (offprint_inside_site), not of the names. Each says what it left out, in one line on stderr (nothing when
# it left out nothing). offprint_drop_site_path also leaves out, without a word, every entry that can't be entered when
# it looks (not there, not a folder, a link to nothing, a folder closed to this user): it runs nothing now, and once it
# is left out nothing made or opened there later (by WordPress, through a link that leads into the site folder, say)
# can be reached through it; stale entries are common, so they go silently. (One of those that is in the site folder by
# its text is named, as the site's.) A link that can be entered is judged by where it leads, and every entry kept is
# kept as the folder it is on disk then (cd -P), not as its text, in its order: so a link on its way that WordPress
# points elsewhere later (one in wp-content/, which a link of the owner's leads through, say) changes nothing. One whose
# folder on disk has a colon in its name, which can't be written in a PATH, is left out too, and named (it works, so its
# going must be said). At the moment of the check, such a link can make an entry lead to any folder outside the site
# folder that is there then, another site's folders included; an owner whose PATH passes through the site folder is
# choosing that. PATH is never left empty (bash would then search the folder it runs in): with nothing
# left, it is the system's own, OFFPRINT_SYSTEM_PATH, said in one line. PATH is exported, so the tool's own scripts a
# command runs (each as /bin/bash SCRIPT, never by a bash found on the PATH) inherit it clean and say nothing again. An
# absolute entry outside every site folder that can be entered is the owner's own to keep clean (docs/security.md, the
# table): whatever is there runs, as it would for any command. TMPDIR is held the same way (offprint_check_tmpdir).

# An inherited allexport (SHELLOPTS=allexport in the environment turns it on in every bash) is turned off here, for the
# whole command: with it, every variable and function a script sets would go into the environment of each program it
# starts, and on Linux no program can be started while one such string is over 128 KiB (a publish's warnings can be), so
# a publish could neither write its status nor remove what it made. What the caller itself exported stays exported.
set +a

case "${BASH_SOURCE[0]}" in */*) _offprint_lib="${BASH_SOURCE[0]%/*}" ;; *) _offprint_lib=. ;; esac
TOOL="$(CDPATH= cd -P -- "${_offprint_lib:-/}" && CDPATH= cd -P -- .. && pwd -P)" && [ -n "$TOOL" ] \
  || { printf '%s\n' "Offprint can't find its own folder (from ${BASH_SOURCE[0]}), so nothing was done." >&2; return 2; }
OFFPRINT_SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin
# offprint_own_project's answer, once Docker has said the compose project is this site's: "NAME|SITE", for the rest of
# this process. Emptied here, so a value from the environment is never taken for an answer.
OFFPRINT_PROJECT_OK=""
OFFPRINT_PROJECT_PROBLEM=""
OFFPRINT_PRIVATE_PROBLEM=""   # why offprint_private_dir refused (empty when TMPDIR can't be entered or mktemp failed)
# The named volumes in templates/compose.yaml, which compose names NAME_<key> (tests/publish.test.sh checks this list
# is exactly the template's).
OFFPRINT_VOLUMES="db wordpress"

# Sets SITE: $OFFPRINT_SITE if set, else the nearest folder at or above $PWD holding site.json, as long as that
# folder is not inside another site folder. Exits 2 when there is none, or when it is inside one; and when TMPDIR is
# inside it, or can't be entered (offprint_check_tmpdir), before anything has made a temporary file; TMPDIR is then the
# folder it is on disk. Once SITE is known, and before anything is looked up on the PATH, every PATH entry that is that
# folder or inside it, or can't be entered, is left out, and the rest kept as the folders they are on disk
# (offprint_drop_site_path).
# (The search itself runs the shell's own builtins only.)
offprint_find_site() {
  _offprint_find_site_folder
  offprint_drop_site_path "$SITE"
  offprint_check_tmpdir
}

# offprint_clean_path: leaves out of PATH every empty entry and every entry that isn't an absolute path (see the top),
# saying which in one line on stderr; with nothing left, PATH is OFFPRINT_SYSTEM_PATH. An entry that is ~ or starts ~/
# is taken first as HOME's, as bash itself takes it, when HOME is an absolute path (and then judged as any other); with
# HOME not one, it is left out with the rest. With HOME one that has a colon in it, it is left out too, and named: bash
# takes it as one folder, which a PATH can't hold (the colon would split it into other entries, a relative or an empty
# one, say). Exports PATH; returns 0. The shell's own builtins only.
offprint_clean_path() {
  local rest="${PATH-}:" e x kept="" nk=0 left="" colon="" why=""
  while [ -n "$rest" ]; do
    e="${rest%%:*}"; rest="${rest#*:}"; x="$e"
    case "$e" in "~"|"~/"*) case "${HOME-}" in /*) x="$HOME${e#"~"}" ;; esac ;; esac
    case "$x" in
      *:*) colon="$colon '$(_offprint_shown "$e")'" ;;   # HOME's, with a colon: it would split into other entries
      /*) if [ "$nk" = 0 ]; then kept="$x"; else kept="$kept:$x"; fi; nk=$((nk + 1)) ;;
      *) left="$left '$(_offprint_shown "$e")'" ;;
    esac
  done
  [ -z "$left" ] || why="as each names whatever folder a command runs in (empty, or not an absolute path):$left"
  [ -z "$colon" ] || why="${why:+$why; and }as each is HOME or a folder in it, and HOME has a colon in it, which can't be written in a PATH:$colon"
  if [ -n "$why" ]; then _offprint_set_path "$nk" "$kept" "$why"
  elif [ "$kept" != "${PATH-}" ]; then _offprint_set_path "$nk" "$kept" ""; fi   # (a ~ taken as HOME's: silently)
  return 0
}

# offprint_drop_site_path [DIR...]: leaves out of PATH every entry that is one of the folders DIR (site folders,
# absolute; an empty one is passed over) or inside one, asked of the disk (offprint_inside_site: so a link that leads
# there counts, a link there that leads out counts too, since WordPress could change it, and so does an entry under one
# that isn't there yet), saying which in one line on stderr. Then, silently, every other entry that can't be entered
# now: not a folder (after following links: so not there, or a link to nothing), or one without search permission for
# this user (mode 000, say); that is, what cd -P would refuse, asked first with test's -d and -x, which ask the system
# the same question without starting a shell. Such an entry runs nothing now, and once it is left out nothing made or
# opened there later can be reached through it (a link outside the site folder to a folder in it that isn't there yet,
# or is closed, say). Every entry kept is kept as the folder it is on disk now (cd -P, then pwd -P, in a subshell: no
# program is run), not as its text, and that folder is asked again: a link on its way (one of the owner's leading
# through one in wp-content/ to a folder outside, say) that WordPress points elsewhere later then changes nothing that
# is looked up, by this shell or by what it runs. (Two entries may then be the same folder, /bin and /usr/bin on Linux,
# say: harmless.) One whose folder on disk has a colon in its name (a Finder name with a / in it, say), which a PATH
# can't hold, is left out, and named in the same line, with why: it can be entered, so a program found there until now
# would otherwise be "command not found" with nothing said. (One that is in a site folder is named as the site's.) With
# nothing left, PATH is OFFPRINT_SYSTEM_PATH, said in one line. Exports PATH; returns 0. The shell's own builtins only.
offprint_drop_site_path() {
  local rest="${PATH-}:" e p kept="" nk=0 left="" colon="" why="" d seen="" where="" nl='
'
  for d; do
    [ -n "$d" ] || continue
    case "$nl$seen$nl" in *"$nl$d$nl"*) continue ;; esac
    seen="$seen$nl$d"; where="${where:+$where and }$(_offprint_shown "$d")"
  done
  while [ -n "$rest" ]; do
    e="${rest%%:*}"; rest="${rest#*:}"
    if [ -n "$where" ] && _offprint_in_sites "$e" "$@"; then left="$left '$(_offprint_shown "$e")'"; continue; fi
    [ -d "$e" ] && [ -x "$e" ] || continue
    p="$(_offprint_on_disk "$e")" && p="${p%?x}" && [ -n "$p" ] || continue
    if [ -n "$where" ] && _offprint_folder_in_sites "$p" "$@"; then left="$left '$(_offprint_shown "$e")'"; continue; fi
    case "$p" in *:*) colon="$colon '$(_offprint_shown "$e")'"; continue ;; esac   # (it would split into other entries)
    if [ "$nk" = 0 ]; then kept="$p"; else kept="$kept:$p"; fi; nk=$((nk + 1))
  done
  [ -z "$left" ] || why="as each is in the site folder $where, which WordPress can write:$left"
  [ -z "$colon" ] || why="${why:+$why; and }as each leads to a folder with a colon in its name, which can't be written in a PATH:$colon"
  _offprint_set_path "$nk" "$kept" "$why"
  return 0
}
# _offprint_on_disk DIR: the folder DIR is on disk now, followed by a line end and an x (so that a name ending in a line
# end survives $( ); the caller takes the two off); fails when it can't be entered. cd -P and pwd -P, builtins, in a
# subshell of its own: the caller's working folder never changes.
_offprint_on_disk() ( CDPATH= cd -P -- "$1" 2> /dev/null && pwd -P && printf x )
# _offprint_folder_in_sites FOLDER DIR...: FOLDER, as it is on disk (from pwd -P, so no link is on its way), is one of
# the folders DIR (an empty one passed over) or inside one: it and each folder above it are compared with each as the
# same folder (-ef), as offprint_inside_site compares; with no link to follow, no subshell is needed.
_offprint_folder_in_sites() {
  local up="$1" d; shift
  while :; do
    for d; do [ -z "$d" ] || [ ! "$up" -ef "$d" ] || return 0; done
    [ "$up" != / ] || return 1
    up="${up%/*}"; [ -n "$up" ] || up=/
  done
}
# _offprint_in_sites ENTRY DIR...: ENTRY is one of the folders DIR (an empty one passed over) or inside one.
_offprint_in_sites() {
  local e="$1" SITE; shift
  for SITE; do
    [ -n "$SITE" ] || continue
    if offprint_inside_site "$e"; then return 0; fi
  done
  return 1
}
# _offprint_set_path COUNT KEPT WHY: PATH is KEPT (COUNT entries), or OFFPRINT_SYSTEM_PATH when that is none, exported;
# and one line on stderr says what was left out, and why (WHY). With no WHY (only entries that can't be entered were
# left out), it says nothing, unless nothing was left.
_offprint_set_path() {
  if [ "$1" = 0 ]; then PATH="$OFFPRINT_SYSTEM_PATH"; else PATH="$2"; fi
  export PATH
  if [ -n "$3" ] && [ "$1" = 0 ]; then
    printf 'offprint: PATH entries left out, %s; none was left, so PATH is %s\n' "$3" "$OFFPRINT_SYSTEM_PATH" >&2
  elif [ -n "$3" ]; then
    printf 'offprint: PATH entries left out, %s\n' "$3" >&2
  elif [ "$1" = 0 ]; then
    printf 'offprint: no PATH entry can be entered (each is missing, or closed to you), so PATH is %s\n' "$OFFPRINT_SYSTEM_PATH" >&2
  fi
  return 0
}
# _offprint_drop_here: offprint_drop_site_path for the site folders known before offprint_find_site runs: OFFPRINT_SITE
# (when it is a folder holding site.json), and the outermost folder at or above the one this runs in that holds anything
# named site.json (so one WordPress put in wp-content/ changes nothing: the site folder around it is the outermost).
# With neither, it still leaves out the entries that can't be entered.
_offprint_drop_here() {
  local p named="" here=""
  if [ -n "${OFFPRINT_SITE:-}" ]; then
    p="$OFFPRINT_SITE"
    case "$p" in /*) ;; *) p="./$p" ;; esac
    if [ -d "$p" ] && [ -f "$p/site.json" ]; then named="$(CDPATH= cd -P -- "$p" 2> /dev/null && pwd -P)" || named=""; fi
  fi
  if here="$(pwd -P 2> /dev/null)" && [ -n "$here" ]; then here="$(_offprint_outermost_site "$here")"; else here=""; fi
  offprint_drop_site_path "$named" "$here"
}
# _offprint_outermost_site DIR: the outermost folder at or above DIR (an absolute path) holding anything named site.json
# (a file, a folder, a link, a broken link), or nothing.
_offprint_outermost_site() {
  local d="$1" outer=""
  while :; do
    if [ -e "$d/site.json" ] || [ -L "$d/site.json" ]; then outer="$d"; fi
    case "$d" in /|"") break ;; esac
    d="${d%/*}"; [ -n "$d" ] || d=/
  done
  printf '%s' "$outer"
}

# offprint_check_tmpdir: once SITE is known, and before any temporary file is made, refuses (one line, exit 2) a TMPDIR
# that is the site folder or inside it. WordPress can write var/inbox, var/export and wp-content/: a temporary file
# there could be swapped for a link between being made and being written or read again by name, and so truncate or
# overwrite a file anywhere this user can, or feed a script what WordPress chose. Inside is asked of the disk
# (offprint_inside_site). A TMPDIR that isn't an absolute path is refused too: where it is would depend on the folder
# each step runs in (bin/publish works in the site folder). One that passes is then set (and exported) to the folder it
# is on disk now, asked again, before any temporary file is made: the mktemp calls below make files in TMPDIR by its
# name, so a link on its way (one of the owner's that leads through one in wp-content/ to a folder outside, say) that
# WordPress points into the site folder later would otherwise take them there. So one that can't be entered (not there,
# not a folder, closed to this user) is refused as well: it is on no folder yet, and one WordPress made there later
# could be the site's. An empty or unset TMPDIR (/tmp is then used: a folder of the system's, outside every site), and
# one holding the site folder, are fine.
offprint_check_tmpdir() {
  local p
  [ -n "${TMPDIR:-}" ] || return 0
  case "$TMPDIR" in
    /*) ;;
    *) echo "TMPDIR is $(_offprint_shown "$TMPDIR"), not an absolute path, so where it is depends on the folder each step runs in; unset TMPDIR, or point it at a folder outside the site folder." >&2
       exit 2 ;;
  esac
  if offprint_inside_site "$TMPDIR"; then
    echo "TMPDIR is $(_offprint_shown "$TMPDIR"), inside the site folder $(_offprint_shown "$SITE"), which WordPress can write; unset TMPDIR, or point it at a folder outside the site folder." >&2
    exit 2
  fi
  if ! p="$(_offprint_on_disk "$TMPDIR")" || ! p="${p%?x}" || [ -z "$p" ]; then
    echo "TMPDIR is $(_offprint_shown "$TMPDIR"), which can't be entered (it isn't there, isn't a folder, or is closed to you), so no temporary file can go there; unset TMPDIR, or point it at a folder outside the site folder." >&2
    exit 2
  fi
  if offprint_inside_site "$p"; then
    echo "TMPDIR is $(_offprint_shown "$TMPDIR"), inside the site folder $(_offprint_shown "$SITE"), which WordPress can write; unset TMPDIR, or point it at a folder outside the site folder." >&2
    exit 2
  fi
  TMPDIR="$p"; export TMPDIR
}

# offprint_inside_site PATH: 0 when PATH (absolute) is the site folder (SITE) or a folder inside it, asked of the disk,
# not of the names: PATH, and each folder its name passes through on the way up to /, is followed to where it is on
# disk (cd -P), when it exists; and that folder and each above it is compared with SITE as the same folder (-ef). So
# another letter case (the Mac's disk ignores case, and pwd -P keeps the case it was given), a link anywhere on the way,
# another path to the same folder (a macOS firmlink, /System/Volumes/Data/...), or a part of PATH that WordPress could
# turn into a link later (inside a folder it can write, itself inside the site folder), all count as inside.
offprint_inside_site() {
  local p="$1" phys up
  [ -n "${SITE:-}" ] || return 1
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while :; do
    if phys="$(cd -P -- "$p" 2> /dev/null && pwd -P)" && [ -n "$phys" ]; then
      up="$phys"
      while :; do
        [ ! "$up" -ef "$SITE" ] || return 0
        [ "$up" != / ] || break
        up="${up%/*}"; [ -n "$up" ] || up=/
      done
    fi
    [ "$p" != / ] || return 1
    p="${p%/*}"; [ -n "$p" ] || p=/
  done
}

# offprint_private_dir NAME VAR: makes a folder of this process's own, NAME.XXXXXX, in TMPDIR (or /tmp when that is
# unset or empty), and sets VAR to its path on disk; returns 0. TMPDIR's own folder is asked first: followed on disk
# (cd -P), it must not be the site folder (SITE) or inside it, where WordPress can write (offprint_inside_site); only
# then is the folder made, with mktemp -d, in that folder's path on disk. (Made first and looked at after, in a folder
# WordPress could write, it could be swapped for a link to anywhere in between.) Its mode is then set to 700 here, not
# left to the umask, once it is known to be a real folder (chmod would follow a link); and it must then be a real folder
# of this user's with no access for group or others (a setgid or sticky bit, which a folder may pass on to new ones,
# doesn't matter). Returns 1, VAR empty, with OFFPRINT_PRIVATE_PROBLEM saying why (empty when TMPDIR
# can't be entered or mktemp failed), having made nothing or removed what it made (a link with rm -f, never followed).
# (offprint_find_site has refused such a TMPDIR already, where it runs: this is the second layer.)
offprint_private_dir() {
  local _pd_parent _pd_dir
  OFFPRINT_PRIVATE_PROBLEM=""
  printf -v "$2" '%s' ""
  _pd_parent="$(cd -P -- "${TMPDIR:-/tmp}" 2> /dev/null && pwd -P)" && [ -n "$_pd_parent" ] || return 1
  if offprint_inside_site "${TMPDIR:-/tmp}" || offprint_inside_site "$_pd_parent"; then
    OFFPRINT_PRIVATE_PROBLEM="TMPDIR is inside the site folder, which WordPress can write; a private folder must be outside it"
    return 1
  fi
  _pd_dir="$(mktemp -d "${_pd_parent%/}/$1.XXXXXX" 2> /dev/null < /dev/null)" && [ -n "$_pd_dir" ] || return 1
  [ ! -d "$_pd_dir" ] || [ -L "$_pd_dir" ] || chmod 700 "$_pd_dir" 2> /dev/null
  if [ -z "$(find "$_pd_dir" -maxdepth 0 -type d -user "$(id -u)" ! -perm -040 ! -perm -020 ! -perm -010 \
      ! -perm -004 ! -perm -002 ! -perm -001 -print 2> /dev/null)" ]; then
    if [ -L "$_pd_dir" ]; then rm -f "$_pd_dir"; else rm -rf "$_pd_dir"; fi
    OFFPRINT_PRIVATE_PROBLEM="the folder made in TMPDIR isn't a private folder of this user's (a real folder, with no access for group or others)"
    return 1
  fi
  printf -v "$2" '%s' "$_pd_dir"
}

# _offprint_find_site_folder: offprint_find_site's search for the site folder (see above), which sets SITE.
_offprint_find_site_folder() {
  local dir p up outer
  if [ -n "${OFFPRINT_SITE:-}" ]; then
    p="$OFFPRINT_SITE"
    case "$p" in /*) ;; *) p="./$p" ;; esac   # a name like "-" must stay a folder name
    if [ ! -d "$p" ] || [ ! -f "$p/site.json" ]; then
      echo "OFFPRINT_SITE is set to $OFFPRINT_SITE, which is not a folder holding site.json." >&2
      exit 2
    fi
    SITE="$(CDPATH= cd -P -- "$p" && pwd -P)" || exit 2
    return 0
  fi
  if ! dir="$(pwd -P 2>/dev/null)" || [ -z "$dir" ]; then
    echo "Cannot tell which folder this is (has the working folder been deleted?); cd into a site folder, or set OFFPRINT_SITE." >&2
    exit 2
  fi
  while :; do
    if [ -f "$dir/site.json" ]; then
      # WordPress can write wp-content/, var/export and var/inbox, so a site.json found there may be the container's,
      # naming its own hosts and compose project. So the folders above are looked at too: a site.json in any of them (a
      # file, a link, a broken link, anything by that name) means this one is inside a site folder, and it is refused,
      # naming the outermost. (OFFPRINT_SITE, above, is the owner's own word and is not second-guessed.)
      up="$dir"; outer=""
      while [ "$up" != / ] && [ "$up" != . ] && [ -n "$up" ]; do
        up="${up%/*}"; [ -n "$up" ] || up=/
        if [ -e "$up/site.json" ] || [ -L "$up/site.json" ]; then outer="$up"; fi
      done
      if [ -n "$outer" ]; then
        # The container may have named the folders on the way: control characters in either path become "?", so
        # none reaches the terminal.
        dir="$(_offprint_shown "$dir")"
        outer="$(_offprint_shown "$outer")"
        echo "site.json at $dir/site.json is inside the site folder $outer; cd to $outer or set OFFPRINT_SITE." >&2
        exit 2
      fi
      SITE="$dir"; return 0
    fi
    case "$dir" in /|.|"") break ;; esac
    dir="${dir%/*}"; [ -n "$dir" ] || dir=/
  done
  echo "Not in an Offprint site folder (no site.json here or above); cd into one, or set OFFPRINT_SITE." >&2
  exit 2
}

# Runs lib/config.php on $SITE and assigns the ten SITE_* variables, SITE_BACKUP_RECIPIENTS (the age public keys the
# database backup is encrypted to, space-separated) and SITE_BACKUP_TO (both empty when site.json has no backup block),
# SITE_PIGEONHOLE_PATH and SITE_PIGEONHOLE_RECIPIENTS (the path comments are posted to and the age public keys they are
# encrypted to; both empty when site.json has no pigeonhole block),
# ADAPTER_NAME ("none" when site.json has no adapter block) and ADAPTER_SET_* (one per adapter setting). Only those names are ever assigned (an ADAPTER_SET_ key must match
# ^ADAPTER_SET_[A-Z][A-Z0-9_]{0,40}$); any other line the validator prints is ignored.
# Exits 2 on any problem, having printed it.
offprint_load_site() {
  offprint_read_site || { printf '%s\n' "$OFFPRINT_SITE_PROBLEMS" >&2; exit 2; }
}

# offprint_read_site: offprint_load_site, but on a problem it returns 1 instead of exiting, with OFFPRINT_SITE_PROBLEMS
# saying what (every line lib/config.php printed, one problem a line) and OFFPRINT_SITE_ERROR "php" when php, which
# reads site.json, isn't on the PATH, else "config". For bin/publish, which writes the problem into var/status.json.
offprint_read_site() {
  local output key value errfile old
  SITE_NAME=""; SITE_PUBLIC_URL=""; SITE_PUBLIC_HOST=""; SITE_LOCAL_HOST=""; SITE_IP4=""
  SITE_IP6=""; SITE_TLS_PORT=""; SITE_HTTP_PORT=""; SITE_AGENT_LABEL=""; SITE_DAEMON_PREFIX=""
  # the backup's two are site.json's "backup" block, and empty without one: never the environment's
  SITE_BACKUP_RECIPIENTS=""; SITE_BACKUP_TO=""
  # nor the pigeonhole's two: with no block there is no pigeonhole, whatever the environment says
  SITE_PIGEONHOLE_PATH=""; SITE_PIGEONHOLE_RECIPIENTS=""
  # nothing ADAPTER_* is inherited from the environment or an earlier load
  for old in $(compgen -v ADAPTER_SET_); do unset "$old"; done
  ADAPTER_NAME=none
  OFFPRINT_SITE_PROBLEMS=""; OFFPRINT_SITE_ERROR=config
  if ! command -v php > /dev/null 2>&1; then
    OFFPRINT_SITE_ERROR=php
    OFFPRINT_SITE_PROBLEMS="php isn't on the PATH ($PATH), and site.json is read with php (lib/config.php)."
    return 1
  fi
  if ! errfile="$(mktemp "${TMPDIR:-/tmp}/offprint-config.XXXXXX" < /dev/null)"; then
    OFFPRINT_SITE_PROBLEMS="site.json couldn't be read: no temporary file could be made for lib/config.php's messages."
    return 1
  fi
  if ! output="$(php "$TOOL/lib/config.php" "$SITE" 2>"$errfile" < /dev/null)"; then
    OFFPRINT_SITE_PROBLEMS="$(cat "$errfile")"
    rm -f "$errfile"
    [ -n "$OFFPRINT_SITE_PROBLEMS" ] || OFFPRINT_SITE_PROBLEMS="site.json couldn't be read: lib/config.php failed and said nothing."
    return 1
  fi
  rm -f "$errfile"
  while IFS=$'\t' read -r key value; do
    case "$key" in
      SITE_NAME) SITE_NAME="$value" ;;
      SITE_PUBLIC_URL) SITE_PUBLIC_URL="$value" ;;
      SITE_PUBLIC_HOST) SITE_PUBLIC_HOST="$value" ;;
      SITE_LOCAL_HOST) SITE_LOCAL_HOST="$value" ;;
      SITE_IP4) SITE_IP4="$value" ;;
      SITE_IP6) SITE_IP6="$value" ;;
      SITE_TLS_PORT) SITE_TLS_PORT="$value" ;;
      SITE_HTTP_PORT) SITE_HTTP_PORT="$value" ;;
      SITE_AGENT_LABEL) SITE_AGENT_LABEL="$value" ;;
      SITE_DAEMON_PREFIX) SITE_DAEMON_PREFIX="$value" ;;
      SITE_BACKUP_RECIPIENTS) SITE_BACKUP_RECIPIENTS="$value" ;;
      SITE_BACKUP_TO) SITE_BACKUP_TO="$value" ;;
      SITE_PIGEONHOLE_PATH) SITE_PIGEONHOLE_PATH="$value" ;;
      SITE_PIGEONHOLE_RECIPIENTS) SITE_PIGEONHOLE_RECIPIENTS="$value" ;;
      ADAPTER_NAME) ADAPTER_NAME="$value" ;;
      ADAPTER_SET_*)
        if printf '%s' "$key" | grep -Eq '^ADAPTER_SET_[A-Z][A-Z0-9_]{0,40}$'; then printf -v "$key" '%s' "$value"; fi ;;
      *) ;;
    esac
  done <<EOT
$output
EOT
  if [ -z "$SITE_NAME" ] || [ -z "$SITE_PUBLIC_URL" ] || [ -z "$SITE_PUBLIC_HOST" ] \
     || [ -z "$SITE_LOCAL_HOST" ] || [ -z "$SITE_IP4" ] || [ -z "$SITE_IP6" ] \
     || [ -z "$SITE_TLS_PORT" ] || [ -z "$SITE_HTTP_PORT" ] \
     || [ -z "$SITE_AGENT_LABEL" ] || [ -z "$SITE_DAEMON_PREFIX" ]; then
    SITE_NAME=""; SITE_PUBLIC_URL=""; SITE_PUBLIC_HOST=""; SITE_LOCAL_HOST=""; SITE_IP4=""
    SITE_IP6=""; SITE_TLS_PORT=""; SITE_HTTP_PORT=""; SITE_AGENT_LABEL=""; SITE_DAEMON_PREFIX=""
    SITE_BACKUP_RECIPIENTS=""; SITE_BACKUP_TO=""; SITE_PIGEONHOLE_PATH=""; SITE_PIGEONHOLE_RECIPIENTS=""
    for old in $(compgen -v ADAPTER_SET_); do unset "$old"; done
    ADAPTER_NAME=none
    OFFPRINT_SITE_PROBLEMS="site.json: the loader did not get all ten values; refusing to continue."
    return 1
  fi
}

# offprint_own_project: whether the compose project called SITE_NAME is this site folder's own. A compose project is
# only a name: docker compose -p NAME, given Offprint's compose file, takes over whatever containers and volumes carry
# that name, whichever folder made them (another tool's project, a copy of this site folder), and setup-wp would then
# change the WordPress it found. So Docker is asked two questions, which change nothing:
#   - every container of the project must have been made from this folder. Compose records the folder in the label
#     com.docker.compose.project.working_dir; it is compared with SITE as a folder on disk (-ef), not as a name, since
#     the Mac's disk ignores case and its temporary folders are reached through a link. A folder that is gone, or none
#     recorded, is another folder.
#   - every volume of the project (by its compose label), and every volume with a name compose would mount for it
#     (NAME_db, NAME_wordpress: see OFFPRINT_VOLUMES), whatever made it, must carry both labels Offprint's own carry:
#     offprint=1 (templates/compose.yaml) and com.docker.compose.project=NAME. A volume of that name made some other way
#     (docker volume create, docker run -v, another project's explicit name:) has no compose label for this project,
#     and compose would mount it all the same, with only a warning: MariaDB would run on that volume's data.
#     The volumes are listed whole, in one call, and looked up here by exact name: a volume that isn't there is simply
#     not in a listing that worked, which a failed call (Docker not running) never is.
# Returns 0 when both hold (remembered in OFFPRINT_PROJECT_OK, so a publish asks once), 1 when not, and 3 when Docker
# couldn't be asked (it isn't running, say). OFFPRINT_PROJECT_PROBLEM then says why, in one line.
offprint_own_project() {
  local out errfile line folder vol rest v mine site_shown
  # The list of volume keys is split on spaces whatever the caller's IFS is (with IFS a line end, it would be one word,
  # and the look-up by name would find nothing).
  local IFS=$' \t\n'
  if [ -n "${SITE_NAME:-}" ] && [ "$OFFPRINT_PROJECT_OK" = "$SITE_NAME|${SITE:-}" ]; then return 0; fi
  OFFPRINT_PROJECT_PROBLEM=""
  if [ -z "${SITE_NAME:-}" ] || [ -z "${SITE:-}" ]; then
    OFFPRINT_PROJECT_PROBLEM="The site's name isn't loaded, so its compose project can't be checked."
    return 1
  fi
  if ! errfile="$(mktemp "${TMPDIR:-/tmp}/offprint-docker.XXXXXX" < /dev/null)"; then
    OFFPRINT_PROJECT_PROBLEM="no temporary file could be made for docker's messages"
    return 3
  fi
  # Each line is a container's ID, a space, and its folder (so a container with no folder recorded is a line too).
  if ! out="$(docker ps -a --filter "label=com.docker.compose.project=$SITE_NAME" \
      --format '{{.ID}} {{.Label "com.docker.compose.project.working_dir"}}' 2> "$errfile" < /dev/null)"; then
    OFFPRINT_PROJECT_PROBLEM="$(_offprint_first_line "$errfile")"; rm -f "$errfile"
    return 3
  fi
  if [ -n "$out" ]; then
    while IFS= read -r line; do
      case "$line" in *" "*) folder="${line#* }" ;; *) folder="" ;; esac
      [ -n "$folder" ] && [ "$folder" -ef "$SITE" ] && continue
      if [ -n "$folder" ]; then folder="$(_offprint_shown "$folder")"; else folder="a folder it didn't record"; fi
      site_shown="$(_offprint_shown "$SITE")"
      OFFPRINT_PROJECT_PROBLEM="A Docker compose project called $SITE_NAME already exists, made from $folder, not from this site folder ($site_shown). Change \"name\" in site.json, or, if this is the same site moved to a new folder, remove its old containers first: docker compose -p $SITE_NAME down (its data volumes are kept)."
      rm -f "$errfile"
      return 1
    done <<EOT
$out
EOT
  fi
  # Each line is a volume's name (never with a space or a quote in it), then its compose project, offprint and compose
  # volume labels, each as a JSON string ("" when missing): a label's quotes and line ends are escaped there, so the
  # whole-string comparisons below can't be fooled by what a label holds.
  if ! out="$(docker volume ls --format '{{.Name}} {{json (.Label "com.docker.compose.project")}} {{json (.Label "offprint")}} {{json (.Label "com.docker.compose.volume")}}' \
      2> "$errfile" < /dev/null)"; then
    OFFPRINT_PROJECT_PROBLEM="$(_offprint_first_line "$errfile")"; rm -f "$errfile"
    return 3
  fi
  rm -f "$errfile"
  if [ -n "$out" ]; then
    while IFS= read -r line; do
      vol="${line%% *}"; rest="${line#* }"
      mine=0
      for v in $OFFPRINT_VOLUMES; do [ "$vol" != "${SITE_NAME}_$v" ] || mine=1; done
      case "$rest" in "\"$SITE_NAME\" "*) ;; *) [ "$mine" = 1 ] || continue ;; esac   # none of this project's
      case "$rest" in "\"$SITE_NAME\" \"1\" "*) continue ;; esac                      # Offprint's, for this project
      OFFPRINT_PROJECT_PROBLEM="Docker volumes for a compose project called $SITE_NAME already exist and were not made by Offprint (first: $(_offprint_shown "$vol")). Change \"name\" in site.json."
      return 1
    done <<EOT
$out
EOT
  fi
  OFFPRINT_PROJECT_OK="$SITE_NAME|$SITE"
  return 0
}
# _offprint_shown TEXT: TEXT for a message, each control character (in the C locale: bytes 1 to 31, and 127) as "?", by
# the shell's own builtins (it names what the PATH clean-up left out, before the PATH is clean).
# _offprint_first_line FILE: its first line so, at most 200 characters, or a word that docker said nothing.
_offprint_shown() { ( LC_ALL=C; printf '%s' "${1//[[:cntrl:]]/?}" ); }
_offprint_first_line() {
  local l
  l="$(head -n 1 "$1" 2> /dev/null | LC_ALL=C tr '\001-\011\013-\037\177' '?' | cut -c1-200)"
  printf '%s' "${l:-docker failed and said nothing}"
}

# offprint_require_project [VERB]: offprint_own_project, or stop. When the project is another folder's: its reason, and
# exit 2. When Docker couldn't be asked: exit 1, saying so; but VERB ps is let through. It needs Docker as much, so it
# fails the same way, with Docker's own words, and changes nothing; if Docker answers it after all, the next compose
# call asks again, since only a yes is remembered. (That is how offprint publish says WordPress isn't running when
# Docker isn't, as before.)
offprint_require_project() {
  local rc=0
  offprint_own_project || rc=$?
  if [ "$rc" = 0 ]; then return 0; fi
  if [ "$rc" = 1 ]; then echo "$OFFPRINT_PROJECT_PROBLEM" >&2; exit 2; fi
  if [ "${1:-}" = ps ]; then return 0; fi
  echo "Docker isn't running (docker said: $OFFPRINT_PROJECT_PROBLEM), so it couldn't be checked that the compose project $SITE_NAME is this site's; nothing was run. Start Docker, then try again." >&2
  exit 1
}

# offprint_plugin_list VAR [-w]: this Offprint's own plugin (TOOL/plugin), as git ls-tree -r lists it in a site's
# commit, but for the type: one line a file, "MODE HASH<tab>wp-content/mu-plugins/PATH", in git's order (sorted in the C
# locale), for offprint.php and every file under offprint/ but Finder's .DS_Store (which a site's .gitignore leaves
# out). MODE is 100755 for a file that can be run, else 100644; HASH is the id git gives the file's bytes as they are
# (hash-object --no-filters: no attribute or filter changes them), asked of the caller's own git (a function of its
# own, which runs git as that script must) in the folder it runs in, so the ids are that repository's. With -w, each
# blob is written into that repository too. Anything in the plugin folder that is neither a file nor a folder (a link,
# say) is refused: what it leads to isn't the tool's. Sets VAR and returns 0; else returns 1, VAR empty, and
# OFFPRINT_PLUGIN_PROBLEM says why: "odd WHAT" (offprint.php or offprint/ missing, or something in them neither a file
# nor a folder: WHAT names it, or is find's own message), "unreadable" (the folder couldn't be read), or "git MESSAGE"
# (git couldn't hash a file; MESSAGE is what it said). bin/setup-wp commits this list; bin/publish refuses a commit
# whose plugin isn't exactly it.
offprint_plugin_list() {
  local _pl_var="$1" _pl_w="" _pl_bad="" _pl_files _pl_f _pl_mode _pl_hash _pl_list="" _pl_tab _pl_nl='
'
  _pl_tab="$(printf '\t')"
  [ "${2:-}" != -w ] || _pl_w=-w
  OFFPRINT_PLUGIN_PROBLEM=""
  printf -v "$_pl_var" '%s' ""
  if [ -L "$TOOL/plugin/offprint.php" ] || [ ! -f "$TOOL/plugin/offprint.php" ]; then _pl_bad="$TOOL/plugin/offprint.php"
  elif [ -L "$TOOL/plugin/offprint" ] || [ ! -d "$TOOL/plugin/offprint" ]; then _pl_bad="$TOOL/plugin/offprint"
  elif ! _pl_bad="$(find "$TOOL/plugin/offprint" ! -type f ! -type d -print 2>&1 < /dev/null)"; then _pl_bad="${_pl_bad:-$TOOL/plugin/offprint}"
  fi
  if [ -n "$_pl_bad" ]; then OFFPRINT_PLUGIN_PROBLEM="odd $_pl_bad"; return 1; fi
  # (find's status is asked of find itself, not of a pipeline: a caller may run without pipefail)
  if ! _pl_files="$(cd "$TOOL/plugin" && find offprint -type f ! -name .DS_Store)"; then
    OFFPRINT_PLUGIN_PROBLEM=unreadable; return 1
  fi
  _pl_files="$(printf 'offprint.php\n%s\n' "$_pl_files" | grep . | LC_ALL=C sort)"
  while IFS= read -r _pl_f; do
    _pl_mode=100644; [ ! -x "$TOOL/plugin/$_pl_f" ] || _pl_mode=100755
    # The id from git's stdout alone: what goes to stderr (a trace of the caller's git function, under set -x, too)
    # never mixes with it. When git fails, it is asked again, for its words.
    if ! _pl_hash="$(git hash-object ${_pl_w:+"$_pl_w"} --no-filters -- "$TOOL/plugin/$_pl_f" 2> /dev/null < /dev/null)"; then
      _pl_hash="$(git hash-object ${_pl_w:+"$_pl_w"} --no-filters -- "$TOOL/plugin/$_pl_f" 2>&1 > /dev/null < /dev/null)"
      OFFPRINT_PLUGIN_PROBLEM="git $_pl_hash"; return 1
    fi
    _pl_list="$_pl_list$_pl_mode $_pl_hash${_pl_tab}wp-content/mu-plugins/$_pl_f$_pl_nl"
  done <<EOF
$_pl_files
EOF
  _pl_list="$(printf '%s' "$_pl_list" | LC_ALL=C sort)"
  if [ -z "$_pl_list" ]; then OFFPRINT_PLUGIN_PROBLEM=unreadable; return 1; fi
  printf -v "$_pl_var" '%s' "$_pl_list"
}
# offprint_plugin_replace PATHS: what replaces a site's committed plugin copy that isn't this Offprint's (an older one)
# with this Offprint's, for the owner to run (an upgrade is the owner's decision): the old copy out, in a commit of its
# own (PATHS: those of the two paths that HEAD has), then offprint setup-wp, which commits this one. bin/setup-wp and
# bin/publish both say it, in these words.
offprint_plugin_replace() {
  printf '%s' "To replace it with this Offprint's: rm -rf wp-content/mu-plugins/offprint.php wp-content/mu-plugins/offprint && git commit -m \"The old plugin copy out\" -- $1 && offprint setup-wp"
}

# docker compose for this site, once its compose project is known to be this site's (offprint_require_project, which
# exits otherwise). The five variables are set for that one command only.
dc() {
  offprint_require_project "${1:-}"
  OFFPRINT_PUBLIC_ORIGIN="$SITE_PUBLIC_URL" \
  OFFPRINT_LOCAL_HOST="$SITE_LOCAL_HOST" \
  OFFPRINT_TLS_PORT="$SITE_TLS_PORT" \
  OFFPRINT_HTTP_PORT="$SITE_HTTP_PORT" \
  OFFPRINT_TOOL="$TOOL" \
  docker compose -p "$SITE_NAME" --project-directory "$SITE" -f "$TOOL/templates/compose.yaml" "$@"
}

# The PATH clean-up, as this file is sourced (see the top): everything above has only set variables and defined
# functions, and these two run the shell's own builtins only.
offprint_clean_path
_offprint_drop_here
