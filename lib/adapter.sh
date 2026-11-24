# Offprint: the site's host adapter. Source after lib/site.sh, and load it once offprint_load_site (or
# offprint_read_site) has set ADAPTER_NAME and ADAPTER_SET_* from site.json:
#
#   . "$(dirname "$0")/../lib/adapter.sh"
#   trap offprint_adapter_cleanup EXIT                 # (or call it from the caller's own cleanup, on every exit)
#   offprint_adapter_load || { echo "$OFFPRINT_ADAPTER_PROBLEM" >&2; exit 2; }
#   offprint_adapter_call adapter_deploy "$COMMIT"     # each adapter function, called this way
#
# Works on macOS /bin/bash 3.2 and Linux bash, under set -u.
#
# An adapter is a folder; adapter.sh in it is the entry point, and the folder may hold more (helpers it sources, data
# files), found through OFFPRINT_ADAPTER_DIR. It is code, so it comes only from the tool ($TOOL/adapters/NAME), or else
# from the site folder's own committed code ($SITE/adapters/NAME). Never from wp-content/, var/ or anywhere else
# WordPress can write. The folder rule:
#   - no link anywhere in the folder, nor on the way to it (for the tool's adapters too);
#   - a site adapter's folder is committed whole, in the site's git repository: every file in it tracked, as a plain
#     file, with no change staged or not (checked byte for byte on disk, whatever git's record of the file's times
#     says), no file git doesn't track (one an ignore rule hides included), and no file with a second name on disk (a
#     hard link).
# What is sourced as adapter.sh is a private copy, made once by offprint_adapter_load (for a site adapter, the committed
# file read from git; for the tool's, its file): mode 600, in a folder of its own (lib/site.sh's offprint_private_dir:
# in TMPDIR, and refused when that is inside the site folder, where WordPress can write). Each call's answer is written
# there too. The caller removes that folder with offprint_adapter_cleanup on every exit.
#
# What adapter.sh may do. It is sourced once by offprint_adapter_load, and again for each call of one of its functions,
# each time in a shell of its own, after the defaults below: so its top level must be cheap and have no side effects. It
# should only set ADAPTER_ variables and define adapter_ functions (its helpers too: adapter_ names). A syntax error in
# it is refused at the load. The load hands back to its caller the ADAPTER_ variables only, by value (declared ones too:
# declare, typeset, local, readonly), and whether adapter_confirm is its own; nothing else adapter.sh sets or defines,
# and no trap, exit or cd at its top level, reaches that shell. ADAPTER_NAME and ADAPTER_SET_* are site.json's, and are
# never taken from it. Every call sees the same OFFPRINT_ADAPTER_DIR, ADAPTER_SET_* and SITE_* values: the loading
# shell's. offprint_adapter_call FN ARGS... runs FN in that call's shell: an exit, a cd, a trap or a variable it sets
# ends there. Only its status, and the first line of ADAPTER_PROBLEM and of ADAPTER_WHY (a few KB at most), come back,
# through files in the private folder; a function that ends without returning (an exit, or an error under set -u) has
# not succeeded. Each function runs under set -u, and sees the caller's own functions (bin/publish's git, log, status
# and the rest: its own are adapter_ names, so none takes one of theirs). What adapter_prepare, adapter_deploy and
# adapter_confirm print goes to var/publish.log, which WordPress can read: adapter_confirm's for the last try only, once
# the asking ends (a try that is asked again, the live site not showing the publish yet, is kept out of the log).
# bin/publish puts no time limit on any of the functions it calls (adapter_validate, adapter_prepare, adapter_deploy,
# adapter_confirm, adapter_failure_hint; the confirm's time, ADAPTER_CONFIRM_SECONDS, is looked at between its tries,
# not during one): one of a site's own adapters that hangs holds the publish's lock until it is stopped.
#
# The contract. Each of these has its default, which adapter.sh may replace:
#   ADAPTER_PREPARE_FILES    names (space-separated) of files the publish writes at the root of the checked copy. The
#                            export may not have any of them, in any letter case. Default: offprint.json when the
#                            adapter keeps the default adapter_confirm (which reads it; then it is always one of them),
#                            else none. offprint.json is bin/publish's own: written after the checks, once the publish's
#                            id is known, as {"publish":"ID"} and a line end, and committed.
#   ADAPTER_HOST_FILES       names of files the host writes at the root. The export may not have them; never committed.
#   ADAPTER_HOST_SPECIAL_FILES  names the host gives a meaning of its own at the root of what it is given (an ignore
#                            file that would leave files out of the live site, say), though nothing writes them. The
#                            export may not have them, in any letter case, a file or a folder; refused before anything
#                            is committed, and by offprint check. (Deeper down they are the export's own: an adapter
#                            whose host reads them there too refuses them itself.) Default: none.
#   ADAPTER_MAX_FILE_BYTES, ADAPTER_MAX_FILES, ADAPTER_MAX_TOTAL_BYTES   limits bin/check-site enforces, 0 for none (the
#                            total is the size of the gzip-compressed archive). Default 0, 0, 0.
#   ADAPTER_CONFIRM_SECONDS  how long the confirm may take (PUBLISH_TIMEOUT_SECONDS, when set, instead). Default 240.
#   ADAPTER_DEPLOY_AGAIN     1 for a host whose deploy is the publish's own doing (an upload from this Mac, say), so
#                            that only another deploy can mend one that failed: a publish with nothing new (no commit,
#                            nothing to push) whose live site doesn't serve it (adapter_confirm 1 or 2) then runs
#                            adapter_deploy for the last commit, and asks the live site as after any deploy. 0: that
#                            publish only asks, and fails. Default 0.
#   adapter_validate         checks its ADAPTER_SET_* settings strictly: one line per problem, each starting
#                            site.json: "adapter.KEY", and returns 1. Run before anything is exported. Default: 0.
#   adapter_prepare DIR      writes its own ADAPTER_PREPARE_FILES (other than offprint.json) into DIR, the private copy
#                            of the export, once the export's are refused and before bin/check-site: each at DIR's root,
#                            a plain file, by exactly that name. It may refuse the export too: non-zero fails the
#                            publish before anything is committed, with ADAPTER_PROBLEM (one line), when set, as the
#                            reason. Default: nothing.
#   adapter_deploy COMMIT    makes the pushed COMMIT live. Non-zero fails the publish, with ADAPTER_PROBLEM (one line)
#                            as the reason. Default: 0.
#   adapter_confirm ID COMMIT  0 when the live site serves this publish, 1 when not yet (ADAPTER_WHY says what it
#                            shows), 2 when it couldn't be reached. bin/publish asks until it is live or the time is up.
#                            ID is the publish's id: the git tree id of site/ as committed (without offprint.json, when
#                            the publish writes one: then always 40 hex digits), so the same content always has the same
#                            id. Default: offprint_confirm_publish_id.
#   adapter_failure_hint     the words after "...hasn't shown it after N seconds (WHY)" when
#                            the time is up. Default: none.
#   adapter_setup [--yes]    run by offprint adapter setup, by a person at a terminal: installs and stores on this Mac
#                            what the adapter needs, each step saying what it will do and asking first (--yes: yes to
#                            each). Its stdin is the terminal (or what was piped in). Ctrl-C reaches it as a TERM (see
#                            offprint_adapter_stop): a TERM trap is where it tidies up. Returns 0 when all is set up.
#                            Default: says there is nothing to set up.
#   adapter_doctor           run by offprint adapter doctor, stdin /dev/null: checks what the adapter needs, and its
#                            live site, changing nothing; prints one line a check, "ok" or "problem" and then what to
#                            do, and returns 0 only when every line is ok. Default: says there is nothing to check.
# bin/offprint runs adapter_validate before either, as a publish does.
# Each name that isn't a function is checked once adapter.sh has run: the three lists must be plain file names, with no
# name in two of them (in any letter case), ADAPTER_DEPLOY_AGAIN 0 or 1, the rest whole numbers.

OFFPRINT_ADAPTER_PROBLEM=""
OFFPRINT_ADAPTER_DIR=""
OFFPRINT_ADAPTER_ENDED=""
OFFPRINT_ADAPTER_TMP=""    # the private folder (see above), while an adapter is loaded
OFFPRINT_ADAPTER_FILE=""   # the private copy of adapter.sh in it
OFFPRINT_ADAPTER_PID=""    # the shell of a load or a call while it runs, for the caller's cleanup to stop

# offprint_confirm_publish_id ID COMMIT: the default confirm. Asks the live site for its offprint.json, which
# bin/publish writes at the root of site/ as {"publish":"ID"} (ID: the publish's id, the git tree of site/ without
# offprint.json):
#   curl -fsS --max-time 10 PUBLIC_URL/offprint.json?p=ID
# (PUBLISH_CHECK_URL, when set, is asked instead of PUBLIC_URL/offprint.json; the ?p= makes each question a new address,
# so no cache answers it). Returns 0 when it names ID; 1 when it names another publish (ADAPTER_WHY: it still shows
# publish XXXXXXX) or none (ADAPTER_WHY: its offprint.json names no publish); 2 when the live site couldn't be reached
# or answered with an error (a 404, say: curl -f), and when ID isn't a publish id (40 lowercase hex digits: then nothing
# is asked). What the live site answers is not trusted: no more than 4 KB of it is read (offprint.json is 55 bytes, so a
# longer answer isn't one), none of it is run, logged or shown, and it counts only when the whole of it is that one JSON
# object, its id exactly 40 lowercase hex digits; nothing of it but those digits is used. COMMIT is not used.
offprint_confirm_publish_id() {
  local id="${1-}" out rc body live
  local id_re='^[0-9a-f]{40}$'
  local json_re='^[[:space:]]*[{][[:space:]]*"publish"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})"[[:space:]]*[}][[:space:]]*$'
  ADAPTER_WHY=""
  if ! ( LC_ALL=C; [[ $id =~ $id_re ]] ); then
    echo "offprint: the publish id to confirm isn't 40 lowercase hex digits, so the live site wasn't asked" >&2
    return 2
  fi
  # The answer, cut after 4 KB and a byte (head may stop curl there), then curl's own status, after the last colon.
  out="$(curl -fsS --max-time 10 "${PUBLISH_CHECK_URL:-$SITE_PUBLIC_URL/offprint.json}?p=$id" | head -c 4097
    printf ':%s' "${PIPESTATUS[0]}")"
  rc="${out##*:}"; body="${out%:*}"
  if [ "$(LC_ALL=C; printf '%s' "${#body}")" -gt 4096 ]; then ADAPTER_WHY="its offprint.json names no publish"; return 1; fi
  [ "$rc" = 0 ] || return 2
  live="$(LC_ALL=C; [[ $body =~ $json_re ]] && printf '%s' "${BASH_REMATCH[1]}")"
  [ "$live" != "$id" ] || return 0
  if [ -n "$live" ]; then ADAPTER_WHY="it still shows publish ${live:0:7}"; else ADAPTER_WHY="its offprint.json names no publish"; fi
  return 1
}

# offprint_adapter_load: finds the adapter site.json names (ADAPTER_NAME), checks it may be used, makes the private copy
# of its adapter.sh and loads it (see above). Returns 0, with the contract's variables set; or 2 with
# OFFPRINT_ADAPTER_PROBLEM saying why, in one line starting site.json: "adapter.name" is NAME, and ... (and the private
# folder already removed). OFFPRINT_ADAPTER_DIR is then the adapter's folder.
offprint_adapter_load() {
  local _oa_name="${ADAPTER_NAME:-}" _oa_base _oa_shown _oa_said _oa_p _oa_dir _oa_file _oa_state _oa_v _oa_n _oa_ok
  local _oa_rel _oa_line _oa_mode _oa_type _oa_entry _oa_rest _oa_changed _oa_tab=$'\t' _oa_rec _oa_path
  local _oa_fmode _oa_ftype _oa_fblob _oa_frest _oa_a _oa_b
  local _oa_name_re='^[a-z][a-z0-9-]*$' _oa_names_re='^[A-Za-z0-9._ -]*$' _oa_count_re='^(0|[1-9][0-9]{0,14})$'
  local _oa_var_re='^ADAPTER_[A-Za-z0-9_]*$'
  local IFS=$' \t\n'
  OFFPRINT_ADAPTER_PROBLEM=""; OFFPRINT_ADAPTER_DIR=""
  offprint_adapter_cleanup
  _oa_said="site.json: \"adapter.name\" is $(_offprint_shown "$_oa_name"), and"
  # The name again (lib/config.php checked it), since it becomes a path: nothing in it may climb out of adapters/.
  if [ "${#_oa_name}" -gt 41 ] || ! ( LC_ALL=C; [[ $_oa_name =~ $_oa_name_re ]] ); then
    OFFPRINT_ADAPTER_PROBLEM="$_oa_said that isn't an adapter's name (a lowercase letter, then lowercase letters, digits and dashes)."
    return 2
  fi
  # The tool's own adapter of that name first, else the site folder's. (A link by that name counts as one, and is
  # refused below.)
  if [ -e "$TOOL/adapters/$_oa_name" ] || [ -L "$TOOL/adapters/$_oa_name" ]; then
    _oa_base="$TOOL"; _oa_shown="Offprint's adapters"
  elif [ -e "$SITE/adapters/$_oa_name" ] || [ -L "$SITE/adapters/$_oa_name" ]; then
    _oa_base="$SITE"; _oa_shown="adapters"
  else
    OFFPRINT_ADAPTER_PROBLEM="$_oa_said there is no adapter of that name: Offprint has none, and this site folder has no adapters/$_oa_name."
    return 2
  fi
  # Real folders and a real file, each step of the way: a link could lead anywhere, wp-content/ included. (TOOL and SITE
  # are physical paths already.)
  for _oa_p in "" "/$_oa_name" "/$_oa_name/adapter.sh"; do
    if [ -L "$_oa_base/adapters$_oa_p" ]; then
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said $_oa_shown$_oa_p is a symlink; an adapter must be a real folder holding a real adapter.sh."
      return 2
    fi
  done
  _oa_dir="$_oa_base/adapters/$_oa_name"
  if [ ! -d "$_oa_dir" ]; then OFFPRINT_ADAPTER_PROBLEM="$_oa_said $_oa_shown/$_oa_name isn't a folder."; return 2; fi
  _oa_file="$_oa_dir/adapter.sh"
  if [ ! -e "$_oa_file" ]; then OFFPRINT_ADAPTER_PROBLEM="$_oa_said $_oa_shown/$_oa_name/adapter.sh is missing."; return 2; fi
  if [ ! -f "$_oa_file" ]; then OFFPRINT_ADAPTER_PROBLEM="$_oa_said $_oa_shown/$_oa_name/adapter.sh isn't a file."; return 2; fi
  # Nor anywhere inside the folder: adapter.sh may source what is beside it.
  _oa_line="$(find "$_oa_dir" -type l 2> /dev/null | head -n 1)"
  if [ -n "$_oa_line" ]; then
    _oa_line="$(_offprint_shown "${_oa_line#"$_oa_dir/"}")"
    OFFPRINT_ADAPTER_PROBLEM="$_oa_said $_oa_shown/$_oa_name/$_oa_line is a symlink; nothing in an adapter's folder may be a link."
    return 2
  fi

  if [ "$_oa_base" = "$SITE" ]; then
    # The site's own code: its whole folder, committed, exactly. Asked of the repository git finds from the site folder
    # (and only from there: see _offprint_adapter_git), by exact paths, in git's own letter case: on the Mac's disk,
    # which ignores case, adapters/x/adapter.sh opens Adapters/x/ADAPTER.SH too, but git doesn't take one for the other.
    _oa_rel="adapters/$_oa_name/adapter.sh"
    if ! _offprint_adapter_git rev-parse --git-dir > /dev/null 2>&1; then
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said this site folder isn't a git repository, so adapters/$_oa_name can't be checked; run git init here and commit it."
      return 2
    fi
    # adapter.sh in the last commit, as a file: _oa_entry is its blob, the one sourced (and nothing below reuses it).
    _oa_line="$(_offprint_adapter_git ls-tree HEAD -- "$_oa_rel" 2> /dev/null)"
    read -r _oa_mode _oa_type _oa_entry _oa_rest <<EOT
$_oa_line
EOT
    if [ "$_oa_line" != "$_oa_mode $_oa_type $_oa_entry$_oa_tab$_oa_rel" ] || [ "$_oa_type" != blob ] \
       || { [ "$_oa_mode" != 100644 ] && [ "$_oa_mode" != 100755 ]; }; then
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said $_oa_rel isn't committed in this site folder's git repository; commit it first."
      return 2
    fi
    # Nothing in the folder changed, staged or not, nor new, nor hidden by an ignore rule. Asked without the optional
    # locks, so git's index is not rewritten.
    if ! _oa_changed="$(_offprint_adapter_git --no-optional-locks status --porcelain --untracked-files=all --ignored \
        --ignore-submodules=all -- "adapters/$_oa_name" 2> /dev/null)"; then
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said git couldn't say whether adapters/$_oa_name has uncommitted changes."
      return 2
    fi
    # git's index, entry by entry, as the last commit has it (by blob id: no file times involved).
    if [ -z "$_oa_changed" ] && ! _offprint_adapter_git diff --cached --quiet HEAD -- "adapters/$_oa_name" > /dev/null 2>&1; then
      _oa_changed="M  $(_offprint_adapter_git diff --cached --name-only HEAD -- "adapters/$_oa_name" 2> /dev/null | head -n 1)"
    fi
    # Each committed file: a plain file in the commit (no link, no other repository), the same bytes on disk (git status
    # may take a file's times on trust), and its only name on disk. (Its own names: _oa_f*.)
    if [ -z "$_oa_changed" ]; then
      while IFS= read -r -d '' _oa_rec; do
        _oa_path="${_oa_rec#*"$_oa_tab"}"; _oa_rec="${_oa_rec%%"$_oa_tab"*}"
        read -r _oa_fmode _oa_ftype _oa_fblob _oa_frest <<EOT
$_oa_rec
EOT
        if [ "$_oa_ftype" != blob ] || { [ "$_oa_fmode" != 100644 ] && [ "$_oa_fmode" != 100755 ]; }; then
          OFFPRINT_ADAPTER_PROBLEM="$_oa_said $(_offprint_shown "$_oa_path") is committed as a link or another repository; an adapter's folder holds plain files only."
          return 2
        fi
        if [ "$(_offprint_adapter_git hash-object --no-filters -- "$_oa_path" 2> /dev/null)" != "$_oa_fblob" ]; then
          _oa_changed=" M $_oa_path"; break
        fi
        if [ -n "$(find "$SITE/$_oa_path" -links +1 2> /dev/null)" ]; then
          OFFPRINT_ADAPTER_PROBLEM="$_oa_said $(_offprint_shown "$_oa_path") has another name on disk (a hard link), so something else could change it; each file in an adapter's folder must be its own."
          return 2
        fi
      done < <(_offprint_adapter_git ls-tree -r -z HEAD -- "adapters/$_oa_name" 2> /dev/null)
    fi
    if [ -n "$_oa_changed" ]; then
      _oa_line="$(printf '%s\n' "$_oa_changed" | head -n 1)"
      _oa_p="$(printf '%s' "${_oa_line#???}" | LC_ALL=C tr '\001-\037\177' '?')"
      case "$_oa_line" in
        '!! '*) OFFPRINT_ADAPTER_PROBLEM="$_oa_said $_oa_p is a file git ignores; an adapter's folder is committed whole, so commit it (git add -f) or remove it." ;;
        *) OFFPRINT_ADAPTER_PROBLEM="$_oa_said adapters/$_oa_name has uncommitted changes (first: $_oa_p); commit them first." ;;
      esac
      return 2
    fi
  fi

  # The private copy of adapter.sh, sourced from here on: for a site adapter the committed file, read from git (nothing
  # on disk can change it after the checks above); for the tool's, its file.
  if ! offprint_private_dir offprint-adapter OFFPRINT_ADAPTER_TMP; then
    OFFPRINT_ADAPTER_TMP=""
    OFFPRINT_ADAPTER_PROBLEM="$_oa_said no private folder could be made to load it in${OFFPRINT_PRIVATE_PROBLEM:+: $OFFPRINT_PRIVATE_PROBLEM}."
    return 2
  fi
  OFFPRINT_ADAPTER_FILE="$OFFPRINT_ADAPTER_TMP/adapter.sh"
  if [ "$_oa_base" = "$SITE" ]; then
    _offprint_adapter_git cat-file blob "$_oa_entry" > "$OFFPRINT_ADAPTER_FILE" 2> /dev/null; _oa_ok=$?
  else
    cat "$_oa_file" > "$OFFPRINT_ADAPTER_FILE" 2> /dev/null; _oa_ok=$?
  fi
  if [ "$_oa_ok" -ne 0 ] || ! chmod 600 "$OFFPRINT_ADAPTER_FILE"; then
    offprint_adapter_cleanup; OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh couldn't be copied to load it."; return 2
  fi
  # A syntax error is refused here, by name (bash -n reads it all, and runs none of it).
  if ! "${BASH:-bash}" -n "$OFFPRINT_ADAPTER_FILE" > /dev/null 2> "$OFFPRINT_ADAPTER_TMP/syntax"; then
    _oa_line="$(head -c 4096 "$OFFPRINT_ADAPTER_TMP/syntax" | head -n 1)"; _oa_line="${_oa_line#"$OFFPRINT_ADAPTER_FILE: "}"
    _oa_line="$(printf '%s' "$_oa_line" | LC_ALL=C tr '\001-\037\177' '?' | cut -c1-200)"
    offprint_adapter_cleanup
    OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh has a syntax error (${_oa_line:-bash -n said nothing}); nothing in it was run."
    return 2
  fi
  OFFPRINT_ADAPTER_DIR="$_oa_dir"
  # Loaded in a shell of its own, after the defaults; that shell writes out its ADAPTER_ variables and the state. Its
  # stdin is /dev/null, said here: bash gives a background job /dev/null only when nothing before it in the function
  # redirected stdin, and the loop above over a site adapter's files does (done < <(...)).
  (
    _offprint_adapter_defaults
    _oa_default="$(builtin declare -f adapter_confirm)"
    _oa_rc=0; . "$OFFPRINT_ADAPTER_FILE" adapter || _oa_rc=$?
    # (Whatever it changed of this shell's own settings is put back first.)
    IFS=$' \t\n'; set +e +f; set -u
    if [ "$_oa_rc" -ne 0 ]; then builtin printf 'failed %s\n' "$_oa_rc" > "$OFFPRINT_ADAPTER_TMP/state"; exit 0; fi
    # offprint.json is what the default confirm reads, so with that confirm it is always the publish's own file.
    ADAPTER_PREPARE_FILES="${ADAPTER_PREPARE_FILES-}"
    if [ "$(builtin declare -f adapter_confirm)" = "$_oa_default" ]; then
      case " $ADAPTER_PREPARE_FILES " in
        *" offprint.json "*) ;;
        *) ADAPTER_PREPARE_FILES="offprint.json${ADAPTER_PREPARE_FILES:+ $ADAPTER_PREPARE_FILES}" ;;
      esac
    fi
    for _oa_v in $(builtin compgen -v ADAPTER_); do
      case "$_oa_v" in ADAPTER_NAME|ADAPTER_SET_*) ;; *) builtin printf '%s\0%s\0' "$_oa_v" "${!_oa_v-}" ;; esac
    done > "$OFFPRINT_ADAPTER_TMP/variables"
    builtin echo loaded > "$OFFPRINT_ADAPTER_TMP/state"
  ) < /dev/null &
  OFFPRINT_ADAPTER_PID=$!
  wait "$OFFPRINT_ADAPTER_PID"
  OFFPRINT_ADAPTER_PID=""
  _oa_state="$(head -c 64 "$OFFPRINT_ADAPTER_TMP/state" 2> /dev/null | head -n 1)"
  case "$_oa_state" in
    loaded) ;;
    "failed "*)
      offprint_adapter_cleanup
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh failed when it was loaded (it returned ${_oa_state#failed })."
      return 2 ;;
    *)
      offprint_adapter_cleanup
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh ended the shell that loaded it (an exit, or an error, at its top level); it may only set ADAPTER_ variables and define adapter_ functions."
      return 2 ;;
  esac
  # In this shell: its ADAPTER_ variables, by value, and nothing else of the contract (its functions are called with
  # offprint_adapter_call, which sources the private copy again).
  for _oa_v in $(compgen -A function adapter_); do unset -f "$_oa_v"; done
  for _oa_v in $(compgen -v ADAPTER_); do case "$_oa_v" in ADAPTER_NAME|ADAPTER_SET_*) ;; *) unset "$_oa_v" ;; esac; done
  # (ADAPTER_NAME and ADAPTER_SET_* are site.json's: never taken from that list, whatever wrote it.)
  while IFS= read -r -d '' _oa_v && IFS= read -r -d '' _oa_n; do
    case "$_oa_v" in ADAPTER_NAME|ADAPTER_SET_*) continue ;; esac
    if ( LC_ALL=C; [[ $_oa_v =~ $_oa_var_re ]] ); then printf -v "$_oa_v" '%s' "$_oa_n"; fi
  done < "$OFFPRINT_ADAPTER_TMP/variables"
  rm -f "$OFFPRINT_ADAPTER_TMP/state" "$OFFPRINT_ADAPTER_TMP/variables" "$OFFPRINT_ADAPTER_TMP/syntax"
  ADAPTER_WHY=""; ADAPTER_PROBLEM=""
  # The names become patterns and paths (find, git's pathspecs), the numbers arithmetic: each is checked first.
  # (Only once a list has only those characters is it split into words: none can then be a wildcard.)
  for _oa_v in ADAPTER_PREPARE_FILES ADAPTER_HOST_FILES ADAPTER_HOST_SPECIAL_FILES; do
    _oa_n="${!_oa_v-}"; _oa_ok=1
    if [ "${#_oa_n}" -gt 2000 ] || ! ( LC_ALL=C; [[ $_oa_n =~ $_oa_names_re ]] ); then _oa_ok=0
    else for _oa_p in $_oa_n; do case "$_oa_p" in .|..) _oa_ok=0 ;; esac; done; fi
    if [ "$_oa_ok" = 0 ]; then
      offprint_adapter_cleanup
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh sets $_oa_v to something that isn't a list of file names (letters, digits, dots, dashes and underscores, separated by spaces)."
      return 2
    fi
  done
  # A name in two of the lists would be the publish's own and the host's at once (written and refused, or committed and
  # not): refused by name, in any letter case, since the Mac's disk takes one for the other. (The names are ASCII, as
  # checked above, so tr's A-Z is every capital they can hold.)
  for _oa_v in "ADAPTER_PREPARE_FILES ADAPTER_HOST_FILES" "ADAPTER_PREPARE_FILES ADAPTER_HOST_SPECIAL_FILES" \
      "ADAPTER_HOST_FILES ADAPTER_HOST_SPECIAL_FILES"; do
    _oa_a="${_oa_v% *}"; _oa_b="${_oa_v#* }"
    for _oa_p in $(printf '%s' "${!_oa_a-}" | LC_ALL=C tr 'A-Z' 'a-z'); do
      for _oa_n in $(printf '%s' "${!_oa_b-}" | LC_ALL=C tr 'A-Z' 'a-z'); do
        if [ "$_oa_p" = "$_oa_n" ]; then
          offprint_adapter_cleanup
          OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh names $_oa_p (in some letter case) in both $_oa_a and $_oa_b; a file name may be in only one of the three lists."
          return 2
        fi
      done
    done
  done
  for _oa_v in ADAPTER_MAX_FILE_BYTES ADAPTER_MAX_FILES ADAPTER_MAX_TOTAL_BYTES ADAPTER_CONFIRM_SECONDS; do
    _oa_n="${!_oa_v-}"
    if ! ( LC_ALL=C; [[ $_oa_n =~ $_oa_count_re ]] ); then
      offprint_adapter_cleanup
      OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh sets $_oa_v to something that isn't a whole number."
      return 2
    fi
  done
  case "${ADAPTER_DEPLOY_AGAIN-}" in
    0|1) ;;
    *) offprint_adapter_cleanup
       OFFPRINT_ADAPTER_PROBLEM="$_oa_said its adapter.sh sets ADAPTER_DEPLOY_AGAIN to something that isn't 0 or 1."
       return 2 ;;
  esac
  return 0
}

# offprint_adapter_call FN ARGS...: runs the adapter's function FN in a shell of its own: the defaults, then the private
# copy of adapter.sh, then FN. Nothing it does (an exit, a cd, a trap, a variable it sets) reaches this shell, and this
# shell waits for it in a way a TERM or INT interrupts (its caller's cleanup then stops it: OFFPRINT_ADAPTER_PID). Its
# stdin and output are the caller's to redirect: a background job's stdin would be /dev/null, so it is given this
# shell's own (bin/publish gives each call /dev/null; offprint adapter setup gives adapter_setup the terminal). That
# shell of its own ignores INT, as any background job of a script does (and bash 3.2 lets no trap there change that):
# an INT meant for it (Ctrl-C) reaches it as offprint_adapter_stop's TERM. Returns FN's status, with
# OFFPRINT_ADAPTER_ENDED "returned" and ADAPTER_PROBLEM and ADAPTER_WHY as FN set them (the first line of each, of their
# first 4 KB); when FN (or adapter.sh) ended any other way, returns 125 with OFFPRINT_ADAPTER_ENDED "exited", the two
# empty, and says so on stderr.
offprint_adapter_call() {
  local _oc_fn="$1" _oc_d="$OFFPRINT_ADAPTER_TMP" _oc_rc
  shift
  OFFPRINT_ADAPTER_ENDED=exited; ADAPTER_PROBLEM=""; ADAPTER_WHY=""
  if [ -z "$_oc_d" ] || [ ! -f "$OFFPRINT_ADAPTER_FILE" ]; then
    echo "offprint: no adapter is loaded, so $_oc_fn can't be called" >&2; return 125
  fi
  # (What this function runs itself, before and after FN, has stdin /dev/null: the caller's stdin is FN's alone. For
  # offprint adapter setup it may be a token, piped in.)
  rm -f "$_oc_d/answer.rc" "$_oc_d/answer.problem" "$_oc_d/answer.why" < /dev/null
  (
    _offprint_adapter_defaults
    . "$OFFPRINT_ADAPTER_FILE" adapter || { echo "offprint: adapter.sh failed when it was loaded for $_oc_fn" >&2; exit 125; }
    ADAPTER_PROBLEM=""; ADAPTER_WHY=""
    "$_oc_fn" "$@"; _oc_rc=$?
    builtin printf '%s' "${ADAPTER_PROBLEM-}" > "$_oc_d/answer.problem"
    builtin printf '%s' "${ADAPTER_WHY-}" > "$_oc_d/answer.why"
    builtin printf '%s\n' "$_oc_rc" > "$_oc_d/answer.rc"
  ) 0<&0 &
  OFFPRINT_ADAPTER_PID=$!
  wait "$OFFPRINT_ADAPTER_PID"
  OFFPRINT_ADAPTER_PID=""
  _oc_rc="$(head -c 16 "$_oc_d/answer.rc" 2> /dev/null < /dev/null | head -n 1)"
  case "$_oc_rc" in
    ''|*[!0-9]*)
      rm -f "$_oc_d/answer.rc" "$_oc_d/answer.problem" "$_oc_d/answer.why" < /dev/null
      echo "offprint: $_oc_fn ended without returning (an exit, or an error)" >&2; return 125 ;;
  esac
  ADAPTER_PROBLEM="$(head -c 4096 "$_oc_d/answer.problem" 2> /dev/null < /dev/null | head -n 1)"
  ADAPTER_WHY="$(head -c 4096 "$_oc_d/answer.why" 2> /dev/null < /dev/null | head -n 1)"
  rm -f "$_oc_d/answer.rc" "$_oc_d/answer.problem" "$_oc_d/answer.why" < /dev/null
  OFFPRINT_ADAPTER_ENDED=returned
  return "$_oc_rc"
}

# offprint_adapter_stop: for a caller's cleanup, stops a load or call still running (OFFPRINT_ADAPTER_PID): a TERM to
# its shell, whose own TERM trap can then tidy up what it started (a folder, a process, the terminal's settings), up to
# 10 seconds for it to end, then it and every process still under it killed (each frozen first, top down, so none starts
# another, then KILL). For a call run at a terminal, where Ctrl-C (an INT to the caller) must stop the function too.
offprint_adapter_stop() {
  local _os_p="${OFFPRINT_ADAPTER_PID:-}" _os_i=0
  OFFPRINT_ADAPTER_PID=""
  [ -n "$_os_p" ] || return 0
  if kill -0 "$_os_p" 2> /dev/null; then
    kill -TERM "$_os_p" 2> /dev/null
    while kill -0 "$_os_p" 2> /dev/null && [ "$_os_i" -lt 100 ]; do sleep 0.1; _os_i=$((_os_i + 1)); done
    # shellcheck disable=SC2046 # one pid a word
    if kill -0 "$_os_p" 2> /dev/null; then kill -KILL $(_offprint_freeze "$_os_p") 2> /dev/null; fi
  fi
  wait "$_os_p" 2> /dev/null
  return 0
}
# _offprint_freeze PID: stops (STOP) that process, then each under it, top down, printing each pid.
_offprint_freeze() {
  local _of_p IFS=$' \t\n'
  kill -STOP "$1" 2> /dev/null; echo "$1"
  for _of_p in $(pgrep -P "$1" 2> /dev/null); do _offprint_freeze "$_of_p"; done
}

# offprint_adapter_cleanup: removes the private folder (the copy of adapter.sh, and any answer left in it). The caller
# stops a load or call still running first (OFFPRINT_ADAPTER_PID).
offprint_adapter_cleanup() {
  case "$OFFPRINT_ADAPTER_TMP" in */offprint-adapter.??????) rm -rf "$OFFPRINT_ADAPTER_TMP" ;; esac
  OFFPRINT_ADAPTER_TMP=""; OFFPRINT_ADAPTER_FILE=""
}

# offprint_secret_get NAME, offprint_secret_set NAME, offprint_secret_delete NAME: a named secret of the loaded site's
# (a token its adapter needs, say), kept in the operating system's own store for secrets and never in a file. The OS
# folder's secret script does the work (os/darwin/secret, on macOS: see its header for the rules), for the site folder
# SITE, whatever folder they are run from. get prints the value on stdout, and nothing else; set reads it from its own
# stdin. Each returns the script's status, its reason (one line, never the value) on stderr: 0 done; 1 no secret of
# that name is stored; 2 a bad NAME, or a value set refuses; 3 the store is locked (get never waits on a prompt: it
# gives up after 10 seconds); 4 any other failure. The value passes through no variable and no argument here.
# The script holds the value (set reads it on its stdin, get prints it), so the bash that runs it is never one the PATH
# finds (run by its own name, its #! line would have env look bash up there, and a PATH that reaches into wp-content/
# would hand the value to whatever WordPress put there): it is _OFFPRINT_SECRET_BASH, /bin/bash, which macOS has (the
# 3.2 these scripts are written for), as has Linux. When that isn't a program that can be run, they fail (4), saying
# so, and run no other bash in its place. (Set here, so nothing in the environment can name another; a test that has
# sourced this file may point it at one that isn't there.)
_OFFPRINT_SECRET_BASH=/bin/bash
offprint_secret_get() { _offprint_secret get "${1-}" < /dev/null; }
offprint_secret_set() { _offprint_secret set "${1-}"; }
offprint_secret_delete() { _offprint_secret delete "${1-}" < /dev/null; }
_offprint_secret() {
  if [ ! -f "$_OFFPRINT_SECRET_BASH" ] || [ ! -x "$_OFFPRINT_SECRET_BASH" ]; then
    echo "offprint: there is no $_OFFPRINT_SECRET_BASH to run os/darwin/secret with, so the secret store wasn't used (no bash found on the PATH is used in its place)." >&2
    return 4
  fi
  OFFPRINT_SITE="${SITE:-${OFFPRINT_SITE:-}}" "$_OFFPRINT_SECRET_BASH" "$TOOL/os/darwin/secret" "$@"
}

# _offprint_adapter_defaults: in the shell of a load or a call, before adapter.sh: nothing of the contract inherited (a
# variable or a function the caller exported included), then each default.
_offprint_adapter_defaults() {
  local _od_v
  for _od_v in $(builtin compgen -A function adapter_); do unset -f "$_od_v"; done
  for _od_v in $(builtin compgen -v ADAPTER_); do case "$_od_v" in ADAPTER_NAME|ADAPTER_SET_*) ;; *) unset "$_od_v" ;; esac; done
  ADAPTER_PREPARE_FILES=""; ADAPTER_HOST_FILES=""; ADAPTER_HOST_SPECIAL_FILES=""; ADAPTER_MAX_FILE_BYTES=0; ADAPTER_MAX_FILES=0
  ADAPTER_MAX_TOTAL_BYTES=0; ADAPTER_CONFIRM_SECONDS=240; ADAPTER_DEPLOY_AGAIN=0; ADAPTER_WHY=""; ADAPTER_PROBLEM=""
  adapter_validate() { return 0; }
  adapter_prepare() { return 0; }
  adapter_deploy() { return 0; }
  adapter_confirm() { offprint_confirm_publish_id "$@"; }
  adapter_failure_hint() { :; }
  adapter_setup() { echo "nothing to set up"; }
  adapter_doctor() { echo "nothing to check"; }
}

# git, for the site folder, as bin/publish runs it: without any of git's variables that say where a repository, its
# index or its work tree are (git exports GIT_DIR inside any hook; left set, they would have git answer about another
# repository, where the same file may well be committed), without those that change how a path is matched, and without
# a core.fsmonitor command.
_offprint_adapter_git() {
  ( unset GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_GRAFT_FILE GIT_SHALLOW_FILE \
      GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
    command git -C "$SITE" -c core.fsmonitor=false "$@" < /dev/null )
}
