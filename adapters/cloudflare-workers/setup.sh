# The cloudflare-workers adapter's set-up and doctor: what offprint adapter setup and offprint adapter doctor run.
# adapter.sh's adapter_setup and adapter_doctor source this file (from OFFPRINT_ADAPTER_DIR, the tool's own folder) only
# when they run, in the shell of that call: a publish never reads it. It uses adapter.sh's helpers (adapter_validate,
# adapter_cf_git, adapter_cf_alive, adapter_cf_kill_tree) and lib/adapter.sh's (offprint_secret_get and _set,
# offprint_private_dir, offprint_inside_site, offprint_confirm_publish_id). See adapter.sh for what a publish needs,
# and for the rules (adapter_cf_home, adapter_cf_runnable, adapter_cf_install_ok) by which the programs set-up, doctor
# and a publish run for wrangler or hand the token to (node, npm, wrangler, curl, and the php given Cloudflare's
# answer) are never in the site folder, nor lead there; the bash that runs os/darwin/secret, which holds the token, is
# /bin/bash (lib/adapter.sh), and the security it runs /usr/bin/security. Set-up and doctor also drop the PATH's empty
# and relative entries (adapter_cf_clean_path) before they look anything up. Every other command, of these and of all
# Offprint (bin/offprint and lib/site.sh, which run before them, included), is the one the PATH it is given finds
# first; so a PATH that reaches into a folder WordPress can write (through ".", an empty entry, or an absolute one)
# makes every Offprint command unsafe.
#
# offprint adapter setup [--yes] makes what a publish needs, in three steps, each saying what it will do and asking
# [y/N] first (--yes: yes to each; the token is still read). Nothing is made on Cloudflare: a publish makes the
# Worker.
#   1. node: the node first on the PATH's absolute entries (command -v node), its links followed to its file. Neither
#      it nor the one recorded is run, even for its version, when it is the site folder's or leads there
#      (adapter_cf_runnable); a node found only through a relative entry is refused, saying so. Refused below 22.12.0
#      (wrangler 4.166.0's own floor), naming the version found. Its path is written to
#      OFFPRINT_HOME/cloudflare-workers/node (a new file, moved onto that name: a link there is removed first, never
#      followed, and a folder there refused; what is there afterwards is checked). Nothing is asked when that file
#      names a node that runs, is new enough and is the one on the PATH (or the one on the PATH isn't usable); when it
#      names another, no keeps it.
#   2. wrangler 4.166.0: npm ci --ignore-scripts of this folder's package.json and package-lock.json, by the npm beside
#      that node (refused before it runs when it is the site folder's or leads there), in a new folder beside where it
#      goes (.wrangler-4.166.0.XXXXXX: so the move is a rename, on one disk), which becomes wrangler-4.166.0 only once
#      npm has finished and what it made is checked: the entry script, and node_modules/wrangler/package.json saying
#      exactly 4.166.0. A whole copy there already is kept, and npm not run; one that isn't whole (a link, or one
#      leading into the site folder, included) is replaced: moved aside, never followed, and removed. What is at
#      wrangler-4.166.0 after the move is checked again before "ok". A failure, or a stop, leaves neither the new folder
#      nor a half-replaced one (and the next set-up removes any a killed one left).
#      npm runs with nothing of the owner's npm settings, so that only the lockfile decides what is installed: an empty
#      environment but PATH (node's own folder first, for npm's #!/usr/bin/env node), HOME and TMPDIR, both in a private
#      folder in TMPDIR that is removed afterwards (so no ~/.npmrc is read, and nothing of npm's is left); --userconfig
#      and --globalconfig each an empty file of its own there (npm refuses one file as both); --registry the public one,
#      which every address in the lockfile names; --include=optional, so no omit setting can leave out the platform
#      packages esbuild and workerd find their programs in (their install scripts are the ones skipped); --cache in that
#      private folder, so no cache of the owner's is read or written (npm checks each package against the lockfile's
#      checksum either way; the price is a download each time set-up installs, which is once); no audit, fund or update
#      check, so nothing but the packages is asked of the network. Its stdin is /dev/null; its output is shown as it
#      comes. When it fails, the private folder goes with the log file npm names (in its cache), and set-up says so.
#   3. the Cloudflare API token: one already in the Keychain that Cloudflare knows, and that can see the account, is
#      kept, and nothing asked (one there that isn't plainly a token, adapter_cf_token_ok, is never sent: a new one is
#      asked for). Otherwise it is read from stdin (read -r -s: not shown at a terminal), spaces, tabs and carriage
#      returns around it dropped, refused unless it is plainly a token (16 to 1024 letters, digits and - _ . ~ + / =: no
#      space, quote or backslash), checked with Cloudflare (adapter_cf_check), and stored (offprint_secret_set
#      cloudflare-token) only once Cloudflare has answered 200 for it; "ok" is said only once it has been read back
#      (offprint_secret_get) and found the same, compared in the shell. That answer shows Cloudflare knows the token
#      and it can see the account, not that it may upload (Cloudflare gave it, in a real run, for a token whose only
#      permission was Account Settings Read): so "ok" says only that, and that a publish shows the rest. A 401 (a token
#      Cloudflare doesn't know: mistyped, cut short, deleted or rolled) says so; a 403 (an account the token can't
#      use, seen for real) names account_id first; a
#      404, account_id; each stores nothing.
#   Every program started before the token is read has stdin /dev/null (the token may be piped in): bin/offprint's
#   and the load's (bin/offprint), and set-up's own, each step's (below).
# Ctrl-C reaches it as a TERM from bin/offprint (lib/adapter.sh: offprint_adapter_stop): it stops at once, exit 143.
# npm and all under it are killed, the new folder, a copy moved aside and the private folder removed, the terminal's
# settings put back (read -s turns its echo off, and a TERM doesn't give them back), and no token is stored.
#
# offprint adapter doctor prints one line a check, "ok" or "problem" and then what to do, and returns 0 only when every
# line is ok: wrangler 4.166.0 installed (its entry script, and the version its package.json says: wrangler itself
# isn't run, since what it reaches as it starts can't be known from here); the node recorded runs (node --version) and
# is new enough (and is no node WordPress could have put there: then it isn't run); Cloudflare knows the token in the
# Keychain and it can see the account (asked as set-up asks; whether it may upload, only a publish shows); WordPress
# exports for site.json's public_url (the address its container was made with, as Docker records it: dc ps, docker
# inspect, never WordPress's own word); the live site's offprint.json names the publish of the site repo's HEAD (asked
# by the default confirm, offprint_confirm_publish_id); PUBLIC_URL/feed/ answers 200 as application/rss+xml; a made-up
# address answers 404. It changes nothing: it makes no file of its own, not even a temporary one, and asks git only to
# read (HEAD's publish id is worked out by php, from the tree git hands over). (Code it shares with every Offprint
# command makes and removes temporary files in TMPDIR: lib/site.sh's site.json loader, run by bin/offprint and again by
# each os/darwin/secret, one each for php's messages; and offprint_own_project, asked
# for the WordPress line, one for docker's.)
#
# The token: never traced (set -x is turned off before it is read), never exported, never in a process's arguments or
# in a file (nor in a here-document or here-string, which bash 3.2 writes to one). It reaches curl as the one line of a
# config file on curl's stdin, header = "Authorization: Bearer TOKEN" (it has no quote, backslash or space, so nothing
# in it can be taken as curl's syntax), and the Keychain on os/darwin/secret's stdin. curl runs with -q first, so no
# .curlrc of the owner's is read (one could turn on --verbose or a trace, which print the header), and with an empty
# environment but PATH (no proxy or key-log variable), and takes no more than 16 MB. What Cloudflare answers goes
# straight from curl to php, which decides on its JSON's top-level "success" and hands back only the first error's code
# and message, cut to 4 KB, in which the token's value is then replaced by [token hidden]; so no answer, however large,
# reaches the shell's string work, and none is printed raw. allexport is turned off with xtrace before the token is
# read (an inherited SHELLOPTS could turn it on, exporting the variable that holds it to every process).
adapter_cf_floor=22.12.0   # wrangler 4.166.0's engines: node >=22.12.0 (adapter_cf_new_enough compares major and minor)
# Why Cloudflare may not know a token (its HTTP 401, error 10000): not a permission it lacks.
adapter_cf_unknown="it was mistyped or cut short when copied, or has been deleted or rolled since"

# adapter_cf_setup [--yes]: offprint adapter setup (see the top of this file).
adapter_cf_setup() {
  { set +x +a; } 2> /dev/null   # never traced, nothing exported unasked (an inherited allexport): this reads the token
  local a cfdir dest nodefile rec cand found rec_v="" cand_v="" rec_ok=0 cand_ok=0 rec_rule=1 cand_rule=1 node have=0 npm
  local rc brc why cf_token="" back="" IFS=$' \t\n' ws=$' \t\r' rec_link=0
  export -n cf_token back   # (a local keeps the export of a caller's variable of its name, on bash 3.2 and 5 alike)
  adapter_cf_yes=0
  for a; do case "$a" in --yes) adapter_cf_yes=1 ;; *) echo "usage: offprint adapter setup [--yes]" >&2; return 2 ;; esac; done
  adapter_cf_tty=""; adapter_cf_npm=""; adapter_cf_stage=""; adapter_cf_old=""; adapter_cf_nodetmp=""; adapter_cf_swork=""
  trap 'adapter_cf_setup_stop; echo; echo "Set-up was stopped. Nothing half-done is left; run offprint adapter setup again to finish." >&2; exit 143' TERM
  trap 'adapter_cf_setup_stop' EXIT
  adapter_cf_clean_path
  if ! adapter_validate > /dev/null 2>&1 < /dev/null; then
    adapter_cf_setup_end; echo "The adapter's settings in site.json aren't right; fix them, then run offprint adapter setup again." >&2; return 2
  fi
  if ! adapter_cf_home; then adapter_cf_setup_end; echo "$cf_home_problem; $cf_home_fix, then run offprint adapter setup again." >&2; return 1; fi
  cfdir="$cf_dir"; dest="$cf_dest"; nodefile="$cf_nodefile"
  echo "Setting up this site's host: the Cloudflare Worker $ADAPTER_SET_WORKER, which a publish uploads site/ to from this"
  echo "Mac with wrangler 4.166.0. Three steps; each says what it will do, and asks first."
  echo "Nothing is made on Cloudflare here: a publish makes the Worker when it isn't there yet."

  # Step 1. Neither node (the one recorded, the one on the PATH) is run, even for its version, unless
  # adapter_cf_runnable says it may be: never one WordPress could have put there.
  echo; echo "Step 1 of 3: node"
  # A real folder at the node file's name (one set-up never makes) is refused, not removed: a file moved onto it would
  # land inside it. (A link there, to anything, is removed when node is recorded: below.)
  if [ -d "$nodefile" ] && [ ! -L "$nodefile" ]; then
    adapter_cf_setup_end
    echo "$nodefile is a folder, where set-up keeps the path of wrangler's node in a file; remove that folder (set-up never makes one), then run offprint adapter setup again." >&2
    return 1
  fi
  [ ! -L "$nodefile" ] || rec_link=1   # (a link there is never followed: adapter_cf_recorded reads nothing through it)
  # (What these run, head, readlink, node --version and the waits for it, has
  # stdin /dev/null: see the top of this file.)
  {
    rec="$(adapter_cf_recorded "$nodefile")"
    if [ -n "$rec" ]; then rec_rule=0; adapter_cf_runnable "$rec" || rec_rule=$?; fi
    if [ "$rec_rule" = 0 ]; then rec_v="$(adapter_cf_node_version "$rec")"; fi
    if [ -n "$rec_v" ] && adapter_cf_new_enough "$rec_v"; then rec_ok=1; fi
    found="$(command -v node 2> /dev/null)"; cand=""   # (the PATH's absolute entries only: adapter_cf_clean_path)
    if [ -n "$found" ]; then
      cand="$(adapter_cf_physical "$found")" || cand="$found"
      cand_rule=0; adapter_cf_runnable "$found" || cand_rule=$?
      if [ "$cand_rule" = 0 ]; then adapter_cf_runnable "$cand" || cand_rule=$?; fi
    fi
    if [ "$cand_rule" = 0 ]; then
      if [ "$cand" = "$rec" ]; then cand_v="$rec_v"; else cand_v="$(adapter_cf_node_version "$cand")"; fi
      if [ -n "$cand_v" ] && adapter_cf_new_enough "$cand_v"; then cand_ok=1; fi
    fi
  } < /dev/null
  if [ "$rec_ok" = 1 ] && { [ "$cand" = "$rec" ] || [ "$cand_ok" = 0 ]; }; then
    node="$rec"; echo "  ok: node v$rec_v at $rec, recorded already."
  elif [ "$cand_ok" = 1 ]; then
    echo "  wrangler runs on node. A publish runs node by its full path, since the launchd agent that publishes doesn't"
    echo "  have your shell's PATH."
    echo "  The node on your PATH is $cand (v$cand_v): set-up will write its path in $nodefile."
    if [ "$rec_link" = 1 ]; then
      echo "  There is a symlink at $nodefile: set-up removes the link itself (what it leads to is left as it is),"
      echo "  and writes the file in its place."
    elif [ -n "$rec" ]; then echo "  It replaces $(_offprint_shown "$rec"), recorded before."; fi
    if adapter_cf_ask "Record this node?"; then
      # A new file, moved onto the name once it is whole. Nothing is written through a link: a link at the name is
      # removed first (rm removes the link, never what it leads to), since mv would move the file into a folder the link
      # led to. What is at the name afterwards is checked: a regular file, not a link, holding exactly that one line.
      {
        if ! mkdir -p "$cfdir" 2> /dev/null || ! adapter_cf_nodetmp="$(mktemp "$cfdir/.node.XXXXXX" 2> /dev/null)" \
           || ! { printf '%s\n' "$cand" > "$adapter_cf_nodetmp" && chmod 644 "$adapter_cf_nodetmp"; } 2> /dev/null \
           || { [ -L "$nodefile" ] && ! rm -f "$nodefile" 2> /dev/null; } \
           || ! mv -f "$adapter_cf_nodetmp" "$nodefile" 2> /dev/null; then
          adapter_cf_setup_end; echo "$nodefile couldn't be written (is the disk full, or OFFPRINT_HOME where you can't write?); nothing was changed." >&2; return 1
        fi
        adapter_cf_nodetmp=""
        if [ -L "$nodefile" ] || [ ! -f "$nodefile" ] || ! printf '%s\n' "$cand" | cmp -s - "$nodefile" 2> /dev/null; then
          adapter_cf_setup_end; echo "$nodefile isn't the file set-up wrote (something else is at that name now); remove what is there, then run offprint adapter setup again." >&2; return 1
        fi
      } < /dev/null
      node="$cand"; echo "  ok: node recorded."
    elif [ "$rec_ok" = 1 ]; then
      node="$rec"; echo "  The node recorded before is kept."
    else
      adapter_cf_setup_end; echo "Nothing was changed. Run offprint adapter setup again when you're ready." >&2; return 1
    fi
  else
    adapter_cf_setup_end
    if [ -z "$found" ] && [ -n "$(adapter_cf_dropped_node)" ]; then
      echo "node is only on your PATH through $(adapter_cf_dropped_node), which set-up ignores: that folder is wherever you run it from (the site's wp-content/, say, which WordPress can write). Put node's own folder on your PATH as an absolute path, then run offprint adapter setup again." >&2
    elif [ -z "$found" ]; then
      echo "node isn't on your PATH. wrangler 4.166.0 needs node $adapter_cf_floor or newer: install it (from https://nodejs.org, or with Homebrew: brew install node), open a new terminal, then run offprint adapter setup again." >&2
    elif [ "$cand_rule" = 2 ]; then
      echo "The node on your PATH, $(_offprint_shown "$found"), is inside the site folder, which WordPress can write (or leads there), so neither set-up nor a publish will run it; install node outside the site folder, then run offprint adapter setup again." >&2
    elif [ "$cand_rule" != 0 ]; then
      echo "The node on your PATH is at $(_offprint_shown "$cand"), a path a publish can't run node from (it has a colon or a control character in it); install node in another folder, then run offprint adapter setup again." >&2
    elif [ -z "$cand_v" ]; then
      echo "The node on your PATH, $cand, didn't say its version (node --version printed none); reinstall node (https://nodejs.org), then run offprint adapter setup again." >&2
    else
      echo "The node on your PATH, $cand, is v$cand_v; wrangler 4.166.0 needs node $adapter_cf_floor or newer. Install a newer node (from https://nodejs.org, or with Homebrew: brew install node, or nvm install 22), then run offprint adapter setup again." >&2
    fi
    return 1
  fi

  # Step 2. npm, beside that node, by the same rule before it runs.
  echo; echo "Step 2 of 3: wrangler 4.166.0"
  if adapter_cf_whole "$dest" < /dev/null; then
    echo "  ok: wrangler 4.166.0 is installed already, in $dest."
  else
    why="$cf_why"; npm="${node%/*}/npm"; rc=0; adapter_cf_runnable "$npm" < /dev/null || rc=$?
    if [ "$rc" = 2 ]; then
      adapter_cf_setup_end; echo "The npm beside that node, $(_offprint_shown "$npm"), is inside the site folder, which WordPress can write (or leads there), so set-up won't run it; reinstall node (https://nodejs.org), then run offprint adapter setup again." >&2; return 1
    elif [ "$rc" != 0 ]; then
      adapter_cf_setup_end; echo "There's no npm beside $node (npm comes with node); reinstall node (https://nodejs.org), then run offprint adapter setup again." >&2; return 1
    fi
    echo "  Set-up will install wrangler 4.166.0, and what it needs, exactly as Offprint's package-lock.json pins them (each"
    echo "  package checked against its checksum there), with npm ci --ignore-scripts: no package's install script runs."
    echo "  It uses the npm beside that node, downloads from registry.npmjs.org, and builds it in a new folder that becomes"
    echo "  $dest only once it is complete."
    if [ -e "$dest" ] || [ -L "$dest" ]; then echo "  What is in $dest now isn't a whole wrangler 4.166.0 ($why): it will be replaced."; fi
    if ! adapter_cf_ask "Install wrangler 4.166.0?"; then
      adapter_cf_setup_end; echo "wrangler wasn't installed, and a publish needs it. Run offprint adapter setup again when you're ready." >&2; return 1
    fi
    adapter_cf_install "$node" "$npm" "$cfdir" "$dest" < /dev/null || { adapter_cf_setup_end; return 1; }
    echo "  ok: wrangler 4.166.0 installed, in $dest."
  fi

  echo; echo "Step 3 of 3: the Cloudflare API token"
  cf_token="$(offprint_secret_get cloudflare-token 2> /dev/null)"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$cf_token" ]; then rc=1; fi
  case "$rc" in
    0) adapter_cf_check < /dev/null; rc=$?; cf_token=""
       case "$rc" in
         0) have=1
            echo "  ok: Cloudflare knows the token already in your login Keychain, and it can see this site's account (a publish shows whether it may upload: it needs Account → Workers Scripts → Edit)." ;;
         1) case "$cf_http" in
              401) echo "  Cloudflare doesn't know the token in your login Keychain (HTTP 401${cf_said:+: $cf_said}): $adapter_cf_unknown. Set-up will ask for a new one." ;;
              404) echo "  Cloudflare finds no account $ADAPTER_SET_ACCOUNT_ID for the token in your login Keychain (HTTP 404${cf_said:+: $cf_said}): check account_id in site.json (the account's id is on its page in Cloudflare's dashboard). If it is right, the token is for another account: set-up will ask for one for this account." ;;
              403) # (seen for real: what Cloudflare answers for an account the token can't use; a token that lacks only the
                   # permission to upload is answered 200)
                   echo "  Cloudflare refuses the token in your login Keychain for the account $ADAPTER_SET_ACCOUNT_ID (HTTP 403${cf_said:+: $cf_said}): most often account_id in site.json is wrong (answer n below, correct it, then run offprint adapter setup again); if it is right, the token is for another account, and set-up will ask for a new one." ;;
              *) echo "  Cloudflare refuses the token in your login Keychain (HTTP $cf_http${cf_said:+: $cf_said}): set-up will ask for a new one." ;;
            esac ;;
         3) echo "  The token in your login Keychain isn't plainly an API token, so it wasn't sent to Cloudflare: set-up will ask for a new one." ;;
         *) adapter_cf_setup_end
            echo "The token in your login Keychain couldn't be checked ($cf_problem), so nothing was changed: $cf_advice, then run offprint adapter setup again." >&2
            return 1 ;;
       esac ;;
    1) cf_token="" ;;
    3) adapter_cf_setup_end
       echo "The login Keychain is locked, so the token stored there couldn't be read. Unlock it (Keychain Access, or log out and back in), then run offprint adapter setup again." >&2
       return 1 ;;
    4) # Status 4 is a value get refuses (not one line of printable ASCII, longer than it stores: one stored some other
       # way, say) and security failing some other way, or not there: only its own reason tells which, so only that is
       # said. No dead end: the one pasted next is stored in place of any stored before; if that store fails, its own
       # message says so.
       cf_token=""; why="$(adapter_cf_get_why)"
       echo "  The token stored in your login Keychain couldn't be read (os/darwin/secret get, status 4${why:+: $why}): set-up asks for one and stores it in its place. (To remove it instead, run this from the site folder: $(adapter_cf_delete_line))" ;;
    *) adapter_cf_setup_end
       echo "The token stored in your login Keychain couldn't be read (os/darwin/secret get failed with status $rc), so nothing was changed; run offprint adapter setup again." >&2
       return 1 ;;
  esac
  if [ "$have" = 0 ]; then
    echo "  A publish uploads with an API token of your Cloudflare account. To make one, open"
    echo "  https://dash.cloudflare.com/profile/api-tokens, choose Create Token, then Create Custom Token, and give it the"
    echo "  permission Account → Workers Scripts → Edit, for the account $ADAPTER_SET_ACCOUNT_ID (site.json's account_id)."
    echo "  Set-up asks Cloudflare whether it knows the token and the token can see the account (it asks for the account's"
    echo "  list of Workers, which changes nothing; whether it may upload, only a publish shows), and only then keeps it in"
    echo "  your login Keychain, never in a file."
    if ! adapter_cf_ask "Enter the token now?"; then
      adapter_cf_setup_end; echo "No token was stored, and a publish needs one. Run offprint adapter setup again when you have it." >&2; return 1
    fi
    printf "  Paste the token (it won't be shown), then press Return: "
    if [ -t 0 ]; then adapter_cf_tty="$(stty -g 2> /dev/null)"; fi
    IFS= read -r -s cf_token || true
    if [ -n "$adapter_cf_tty" ]; then stty "$adapter_cf_tty" 2> /dev/null; adapter_cf_tty=""; fi
    echo
    cf_token="${cf_token#"${cf_token%%[!$ws]*}"}"; cf_token="${cf_token%"${cf_token##*[!$ws]}"}"
    if [ -z "$cf_token" ]; then
      adapter_cf_setup_end; echo "No token was entered, so nothing was stored. Run offprint adapter setup again when you have it." >&2; return 1
    fi
    if ! adapter_cf_token_ok; then
      adapter_cf_setup_end
      echo "What was entered isn't an API token (one is 16 to 1024 letters, digits and - _ . ~ + / =, with no spaces or quotes), so nothing was stored. Copy the token's value (Cloudflare shows it once, when it is made), then run offprint adapter setup again." >&2
      return 1
    fi
    adapter_cf_check < /dev/null; rc=$?
    case "$rc" in
      0) ;;
      1) adapter_cf_setup_end
         if [ "$cf_http" = 404 ]; then
           echo "Cloudflare found no account $ADAPTER_SET_ACCOUNT_ID for the token (HTTP 404${cf_said:+: $cf_said}), so nothing was stored. Check account_id in site.json (the account's id is on its page in Cloudflare's dashboard), and that the token is for that account, then run offprint adapter setup again." >&2
         elif [ "$cf_http" = 401 ]; then
           echo "Cloudflare doesn't know that token (HTTP 401${cf_said:+: $cf_said}), so nothing was stored: $adapter_cf_unknown. Paste it whole, or make a new one at https://dash.cloudflare.com/profile/api-tokens, then run offprint adapter setup again." >&2
         elif [ "$cf_http" = 403 ]; then
           echo "Cloudflare refused the token for the account $ADAPTER_SET_ACCOUNT_ID (HTTP 403${cf_said:+: $cf_said}), so nothing was stored. Most often account_id in site.json is wrong: check it against the account's id on its page in Cloudflare's dashboard. If it is right, the token is for another account: make one for this account at https://dash.cloudflare.com/profile/api-tokens, then run offprint adapter setup again." >&2
         else
           echo "Cloudflare refused the token (HTTP $cf_http${cf_said:+: $cf_said}), so nothing was stored. It needs the permission Account → Workers Scripts → Edit, for the account $ADAPTER_SET_ACCOUNT_ID (site.json's account_id): edit it at https://dash.cloudflare.com/profile/api-tokens, or make a new one, then run offprint adapter setup again." >&2
         fi
         return 1 ;;
      *) adapter_cf_setup_end
         echo "The token couldn't be checked ($cf_problem), so nothing was stored: $cf_advice, then run offprint adapter setup again." >&2
         return 1 ;;
    esac
    printf '%s\n' "$cf_token" | offprint_secret_set cloudflare-token; rc=$?
    # Stored is said only once it is read back the same: security's status alone doesn't show it. Compared here, in
    # this shell, so no program is handed either value.
    if [ "$rc" = 0 ]; then
      back="$(offprint_secret_get cloudflare-token 2> /dev/null)"; brc=$?
      if [ "$brc" = 3 ]; then rc=locked   # (the Keychain locked at the read-back: not something else stored)
      elif [ "$brc" != 0 ] || [ "$back" != "$cf_token" ]; then rc=back; fi
      back=""
    fi
    cf_token=""
    case "$rc" in
      0) echo "  ok: Cloudflare knows the token, and it can see this site's account; it is in your login Keychain now (a publish shows whether it may upload: it needs Account → Workers Scripts → Edit)." ;;
      back) adapter_cf_setup_end
         echo "The login Keychain said it stored the token, but reading it back gave something else, so it isn't known to be stored. Run offprint adapter setup again; offprint adapter doctor says what is stored, and whether Cloudflare knows it." >&2
         return 1 ;;
      locked) adapter_cf_setup_end
         echo "The login Keychain said it stored the token, but was locked when set-up read it back, so it isn't known to be stored. Unlock it (Keychain Access, or log out and back in), then run offprint adapter setup again." >&2
         return 1 ;;
      3) adapter_cf_setup_end
         echo "The login Keychain is locked, so the token couldn't be stored. Unlock it (Keychain Access, or log out and back in), then run offprint adapter setup again." >&2
         return 1 ;;
      *) adapter_cf_setup_end
         echo "The token couldn't be stored in your login Keychain (os/darwin/secret set failed with status $rc; its reason is above). Run offprint adapter setup again." >&2
         return 1 ;;
    esac
  fi

  echo
  echo "Set-up is done. offprint adapter doctor checks it all, and the live site."
  echo "The first offprint publish shows whether the token may upload; when it may, it makes the Worker $ADAPTER_SET_WORKER."
  adapter_cf_setup_end
  return 0
}

# adapter_cf_install NODE NPM CFDIR DEST: step 2's work (see the top of this file). Returns 0 once DEST is a whole
# wrangler 4.166.0; else 1, having said why on stderr and left nothing of its own behind.
adapter_cf_install() {
  local node="$1" npm="$2" cfdir="$3" dest="$4" d rc w
  # What a set-up that was killed left (never another's folder: these are its own names).
  for d in "$cfdir"/.wrangler-4.166.0.?????? "$cfdir"/.old-wrangler.??????; do
    if [ -d "$d" ] && [ ! -L "$d" ]; then chmod -R u+rwX "$d" 2> /dev/null; rm -rf "$d"; fi
  done
  # (Never inside the site folder: offprint_private_dir compares the folders on disk.)
  if ! offprint_private_dir offprint-cf-setup adapter_cf_swork; then
    adapter_cf_swork=""
    echo "No private folder could be made for npm (in TMPDIR)${OFFPRINT_PRIVATE_PROBLEM:+: $OFFPRINT_PRIVATE_PROBLEM}; nothing was installed." >&2
    return 1
  fi
  # npm's own files, in the private folder (in TMPDIR); then wrangler's new folder, in cfdir: each named when it fails.
  if ! { mkdir "$adapter_cf_swork/home" "$adapter_cf_swork/tmp" "$adapter_cf_swork/cache" && : > "$adapter_cf_swork/npmrc" \
       && : > "$adapter_cf_swork/npmrc-global"; } 2> /dev/null; then
    w="$adapter_cf_swork"; adapter_cf_setup_stop
    echo "npm's files couldn't be made in set-up's private folder in TMPDIR, $w (is the disk full?); nothing was installed." >&2
    return 1
  fi
  if ! adapter_cf_stage="$(mktemp -d "$cfdir/.wrangler-4.166.0.XXXXXX" 2> /dev/null)" || [ -z "$adapter_cf_stage" ] \
     || ! cp "$OFFPRINT_ADAPTER_DIR/package.json" "$OFFPRINT_ADAPTER_DIR/package-lock.json" "$adapter_cf_stage/" 2> /dev/null; then
    adapter_cf_setup_stop
    echo "A new folder for wrangler couldn't be made in $cfdir (is the disk full?); nothing was installed." >&2
    return 1
  fi
  # npm, in the background so that a TERM (Ctrl-C) stops this shell's wait, and its trap npm.
  ( cd "$adapter_cf_stage" || exit 126
    exec /usr/bin/env -i PATH="${node%/*}:/usr/bin:/bin" HOME="$adapter_cf_swork/home" TMPDIR="$adapter_cf_swork/tmp" \
      "$npm" ci --ignore-scripts --include=optional --no-audit --no-fund --no-update-notifier \
      --registry=https://registry.npmjs.org/ --userconfig="$adapter_cf_swork/npmrc" --globalconfig="$adapter_cf_swork/npmrc-global" \
      --cache="$adapter_cf_swork/cache" ) < /dev/null &
  adapter_cf_npm=$!
  wait "$adapter_cf_npm"; rc=$?; adapter_cf_npm=""
  if [ "$rc" != 0 ]; then
    # (npm's cache, and the log it names in its last lines, are in the private folder, which goes: so it is said here.)
    adapter_cf_setup_stop
    echo "A log file npm names above was in set-up's private folder, which is removed: npm's lines above are all there is of it." >&2
    echo "npm ci failed (it ended with status $rc), so nothing was installed. npm's messages above say why (the network is only one possible cause); fix that, then run offprint adapter setup again." >&2
    return 1
  fi
  if ! adapter_cf_whole "$adapter_cf_stage"; then
    adapter_cf_setup_stop
    echo "npm ci finished, but what it made isn't wrangler 4.166.0 ($cf_why), so nothing was installed; run offprint adapter setup again." >&2
    return 1
  fi
  # Into place, by renames on one disk: what was there (not whole) moved aside first, removed once the new one is in.
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if ! adapter_cf_old="$(mktemp -d "$cfdir/.old-wrangler.XXXXXX" 2> /dev/null)" || [ -z "$adapter_cf_old" ] \
       || ! mv "$dest" "$adapter_cf_old/" 2> /dev/null; then
      adapter_cf_setup_stop; echo "What is in $dest couldn't be moved aside to replace it; nothing was installed." >&2; return 1
    fi
  fi
  if ! mv "$adapter_cf_stage" "$dest" 2> /dev/null; then
    adapter_cf_setup_stop; echo "wrangler 4.166.0 was made, but couldn't be moved to $dest; nothing was installed." >&2; return 1
  fi
  adapter_cf_stage=""
  # What is at DEST now is checked, as the node file is: the name was emptied just above, but a folder (or a link to
  # one) put there in between would have taken the new copy inside it. The next set-up replaces whatever it is.
  if ! adapter_cf_whole "$dest"; then
    adapter_cf_setup_stop
    echo "wrangler 4.166.0 was made, but what is at $dest now isn't it (something else took that name meanwhile); run offprint adapter setup again, which replaces it." >&2
    return 1
  fi
  adapter_cf_setup_stop   # the copy moved aside, and the private folder
  return 0
}

# adapter_cf_setup_stop: on every way out of set-up (a TERM included), what it has under way: the terminal's settings
# put back (read -s turns its echo off), npm and every process under it killed, the new folder, a copy moved aside,
# a node file not yet moved into place and the private folder removed (each only by its own name's pattern), and the
# token forgotten. adapter_cf_setup_end: that, and its traps lifted.
adapter_cf_setup_stop() {
  local IFS=$' \t\n'
  if [ -n "${adapter_cf_tty:-}" ]; then stty "$adapter_cf_tty" 2> /dev/null; adapter_cf_tty=""; fi
  # (Reaped here, quietly: bash 5 would otherwise print "Killed" and npm's command line when the next command reaps it.)
  {
    if [ -n "${adapter_cf_npm:-}" ]; then adapter_cf_kill_tree "$adapter_cf_npm"; wait "$adapter_cf_npm" 2> /dev/null; fi
    case "${adapter_cf_stage:-}" in */.wrangler-4.166.0.??????) chmod -R u+rwX "$adapter_cf_stage" 2> /dev/null; rm -rf "$adapter_cf_stage" ;; esac
    case "${adapter_cf_old:-}" in */.old-wrangler.??????) chmod -R u+rwX "$adapter_cf_old" 2> /dev/null; rm -rf "$adapter_cf_old" ;; esac
    case "${adapter_cf_nodetmp:-}" in */.node.??????) rm -f "$adapter_cf_nodetmp" ;; esac
    case "${adapter_cf_swork:-}" in */offprint-cf-setup.??????) chmod -R u+rwX "$adapter_cf_swork" 2> /dev/null; rm -rf "$adapter_cf_swork" ;; esac
  } < /dev/null
  adapter_cf_npm=""; adapter_cf_stage=""; adapter_cf_old=""; adapter_cf_nodetmp=""; adapter_cf_swork=""
  cf_token=""
}
adapter_cf_setup_end() { adapter_cf_setup_stop; trap - TERM EXIT; }

# adapter_cf_delete_line: the line that removes the stored token, for the owner to run from the site folder (the way out
# when what is stored can't be read): the tool's os/darwin/secret by /bin/bash, its path in single quotes.
adapter_cf_delete_line() {
  printf "/bin/bash '%s' delete cloudflare-token" "$(printf '%s' "$TOOL/os/darwin/secret" | sed "s/'/'\\\\''/g")"
}

# adapter_cf_get_why: why os/darwin/secret get failed (for a status it gives for more than one cause: 4), in its own
# words (its first line on stderr, made printable and cut to 200 characters), by asking again with its stdout thrown
# away. No message of that helper ever shows the value (its header). Nothing when it says nothing.
adapter_cf_get_why() {
  offprint_secret_get cloudflare-token 2>&1 > /dev/null | head -n 1 | LC_ALL=C tr -d '\r\n' | LC_ALL=C tr -c ' -~' '?' | cut -c1-200
}

# adapter_cf_ask QUESTION: QUESTION and [y/N], then 0 when the line read from stdin is y or yes (any case), else 1 (the
# end of the input too). With --yes, 0, without reading.
adapter_cf_ask() {
  local a=""
  if [ "$adapter_cf_yes" = 1 ]; then printf '  %s [y/N] yes (--yes)\n' "$1"; return 0; fi
  printf '  %s [y/N] ' "$1"
  IFS= read -r a || a=""
  [ -t 0 ] || echo
  case "$a" in [yY]|[yY][eE][sS]) return 0 ;; esac
  return 1
}

# adapter_cf_doctor: offprint adapter doctor (see the top of this file).
adapter_cf_doctor() {
  { set +x +a; } 2> /dev/null   # never traced, nothing exported unasked (an inherited allexport): this reads the token
  local dest nodefile node v rc id u f m kind why cf_token="" IFS=$' \t\n'
  export -n cf_token   # (see adapter_cf_setup)
  adapter_cf_problems=0
  adapter_cf_clean_path
  if adapter_cf_home; then
    dest="$cf_dest"; nodefile="$cf_nodefile"
    if adapter_cf_whole "$dest"; then adapter_cf_line ok "wrangler 4.166.0 is installed, in $dest"
    elif [ -e "$dest" ] || [ -L "$dest" ]; then adapter_cf_line problem "$dest isn't a whole wrangler 4.166.0 ($cf_why): run offprint adapter setup, which replaces it"
    else adapter_cf_line problem "wrangler 4.166.0 isn't installed (there is no $dest): run offprint adapter setup"; fi
    node="$(adapter_cf_recorded "$nodefile")"; rc=0; adapter_cf_runnable "$node" || rc=$?
    if [ -L "$nodefile" ]; then adapter_cf_line problem "$nodefile is a symlink, so the node it names isn't used (whoever could change the link would choose what a publish runs): run offprint adapter setup, which replaces it"
    elif [ ! -f "$nodefile" ]; then adapter_cf_line problem "no node is recorded for wrangler (there is no $nodefile): run offprint adapter setup"
    elif [ "$rc" = 2 ]; then adapter_cf_line problem "the node recorded, $(_offprint_shown "$node"), is inside the site folder, which WordPress can write (or leads there): run offprint adapter setup"
    elif [ "$rc" != 0 ]; then adapter_cf_line problem "the node recorded in $nodefile isn't there, or can't be run: run offprint adapter setup"
    else
      v="$(adapter_cf_node_version "$node")"
      if [ -z "$v" ]; then adapter_cf_line problem "the node recorded, $node, didn't say its version (node --version printed none): reinstall node, then run offprint adapter setup"
      elif ! adapter_cf_new_enough "$v"; then adapter_cf_line problem "the node recorded, $node, is v$v; wrangler 4.166.0 needs $adapter_cf_floor or newer: install a newer node, then run offprint adapter setup"
      else adapter_cf_line ok "node v$v runs, at $node (set-up recorded it; a publish runs node by that path)"; fi
    fi
  else
    adapter_cf_line problem "wrangler can't be found: $cf_home_problem; $cf_home_fix, then run offprint adapter setup"
    adapter_cf_line problem "node can't be found: $cf_home_problem; $cf_home_fix, then run offprint adapter setup"
  fi

  cf_token="$(offprint_secret_get cloudflare-token 2> /dev/null)"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$cf_token" ]; then rc=1; fi
  case "$rc" in
    0) adapter_cf_check; rc=$?; cf_token=""
       case "$rc" in
         0) adapter_cf_line ok "Cloudflare knows the token in your login Keychain, and it can see this site's account (a publish shows whether it may upload: it needs Account → Workers Scripts → Edit)" ;;
         3) adapter_cf_line problem "the Cloudflare token in your login Keychain isn't plainly an API token (16 to 1024 letters, digits and - _ . ~ + / =), so it wasn't sent to Cloudflare: $cf_advice" ;;
         1) if [ "$cf_http" = 404 ]; then
              adapter_cf_line problem "Cloudflare finds no account $ADAPTER_SET_ACCOUNT_ID for the token in your login Keychain (HTTP 404${cf_said:+: $cf_said}): check account_id in site.json, then run offprint adapter setup"
            elif [ "$cf_http" = 401 ]; then
              adapter_cf_line problem "Cloudflare doesn't know the token in your login Keychain (HTTP 401${cf_said:+: $cf_said}; $adapter_cf_unknown): run offprint adapter setup, and paste the token whole, or a new one"
            elif [ "$cf_http" = 403 ]; then
              adapter_cf_line problem "Cloudflare refuses the token in your login Keychain for the account $ADAPTER_SET_ACCOUNT_ID (HTTP 403${cf_said:+: $cf_said}): check account_id in site.json first (a token that lacks only the permission to upload passes this check); if it is right, the token is for another account: run offprint adapter setup with one for this account"
            else
              adapter_cf_line problem "Cloudflare refuses the token in your login Keychain (HTTP $cf_http${cf_said:+: $cf_said}): give it the permission Account → Workers Scripts → Edit, for the account $ADAPTER_SET_ACCOUNT_ID, then run offprint adapter setup"
            fi ;;
         *) adapter_cf_line problem "the Cloudflare token in your login Keychain couldn't be checked ($cf_problem): $cf_advice, then run offprint adapter doctor again" ;;
       esac ;;
    1) adapter_cf_line problem "no Cloudflare token is in your login Keychain for this site: run offprint adapter setup" ;;
    3) adapter_cf_line problem "your login Keychain is locked, so the Cloudflare token couldn't be read: unlock it, then run offprint adapter doctor again" ;;
    4) # (what is stored can't be read, or security failed: its own reason is shown; set-up asks for one, or it can be removed)
       why="$(adapter_cf_get_why)"
       adapter_cf_line problem "the Cloudflare token couldn't be read from your login Keychain (os/darwin/secret get, status 4${why:+: $why}): run offprint adapter setup, which asks for one and stores it in its place (or remove it, running this from the site folder: $(adapter_cf_delete_line))" ;;
    *) adapter_cf_line problem "the Cloudflare token couldn't be read from your login Keychain (os/darwin/secret get failed with status $rc): run offprint adapter setup" ;;
  esac
  cf_token=""

  # WordPress: the address it exports for is the public_url its container was made with (templates/compose.yaml puts it
  # in the container's environment): asked of Docker's record of the container (dc ps, docker inspect), never of
  # WordPress, and only compared with site.json's.
  rc=0; offprint_own_project || rc=$?
  case "$rc" in
    0) adapter_cf_wordpress ;;
    1) adapter_cf_line problem "WordPress couldn't be asked: $OFFPRINT_PROJECT_PROBLEM" ;;
    *) adapter_cf_line problem "Docker isn't running, so the address WordPress exports for couldn't be checked: start Docker, then run offprint adapter doctor again" ;;
  esac

  # The live site: what the publish's own confirm asks, for HEAD's publish; then the feed, and a page that isn't there.
  u="${PUBLISH_CHECK_URL:-$SITE_PUBLIC_URL/offprint.json}"
  id="$(adapter_cf_head_id)"; rc=$?
  case "$rc" in
    0) ADAPTER_WHY=""; offprint_confirm_publish_id "$id" "" > /dev/null 2>&1; rc=$?
       case "$rc" in
         0) adapter_cf_line ok "the live site serves the site repo's last publish: $u names HEAD's publish (${id:0:7})" ;;
         1) adapter_cf_line problem "the live site doesn't serve the site repo's last publish (${id:0:7}): $ADAPTER_WHY; run offprint publish" ;;
         *) adapter_cf_fetch "$u"
            case "$cf_code" in
              000) adapter_cf_line problem "the live site couldn't be asked for the site repo's last publish (${id:0:7}): $u couldn't be reached ($(adapter_cf_curl_words "$cf_crc" 10)); check public_url in site.json and your connection" ;;
              404) adapter_cf_line problem "the live site doesn't serve the site repo's last publish (${id:0:7}): $u answers 404 (nothing has been published there yet, or public_url in site.json isn't the Worker's address); run offprint publish" ;;
              *) adapter_cf_line problem "the live site doesn't serve the site repo's last publish (${id:0:7}): $u answers HTTP $cf_code; run offprint publish, then offprint adapter doctor again" ;;
            esac ;;
       esac ;;
    1) adapter_cf_line problem "the site repo has nothing published yet (HEAD has no site/): run offprint publish" ;;
    2) adapter_cf_line problem "the site repo's ids aren't 40 hex digits (a SHA-256 repository?), so no publish id can name HEAD: make the site repo a SHA-1 one (git init's default)" ;;
    *) adapter_cf_line problem "the site repo's last commit (HEAD) couldn't be read: commit, then run offprint publish" ;;
  esac
  f="$SITE_PUBLIC_URL/feed/"; adapter_cf_fetch "$f"
  case "$cf_code" in
    000) adapter_cf_line problem "$f couldn't be reached ($(adapter_cf_curl_words "$cf_crc" 10)): check public_url in site.json and your connection" ;;
    200) kind="$(printf '%s' "${cf_type%%;*}" | LC_ALL=C tr -d ' ' | LC_ALL=C tr 'A-Z' 'a-z')"
         if [ "$kind" = application/rss+xml ]; then adapter_cf_line ok "$f answers 200 as application/rss+xml"
         else adapter_cf_line problem "$f answers 200 as ${kind:-no type}, not application/rss+xml: run offprint publish (it writes the _headers rule that gives the feed its type)"; fi ;;
    *) adapter_cf_line problem "$f answers $cf_code, not 200: run offprint publish (it writes the _redirects rule that serves the feed there)" ;;
  esac
  m="$SITE_PUBLIC_URL/offprint-doctor-no-such-page/"; adapter_cf_fetch "$m"
  case "$cf_code" in
    000) adapter_cf_line problem "a made-up address, $m, couldn't be reached ($(adapter_cf_curl_words "$cf_crc" 10)): check public_url in site.json and your connection" ;;
    404) adapter_cf_line ok "a made-up address, $m, answers 404" ;;
    *) adapter_cf_line problem "a made-up address, $m, answers $cf_code, not 404: run offprint publish (it sets the Worker to answer a missing page with 404.html, and 404)" ;;
  esac
  [ "$adapter_cf_problems" = 0 ]
}
# adapter_cf_wordpress: the doctor's line about the address WordPress exports for (see adapter_cf_doctor), once the
# compose project is known to be this site's (offprint_own_project).
adapter_cf_wordpress() {
  local cid env origin id_re='^[0-9a-f]{12,64}$' re="define[(] 'OFFPRINT_PUBLIC_ORIGIN', '([^']*)' [)]"
  cid="$(dc ps -a -q wordpress 2> /dev/null < /dev/null | head -n 1)"
  if [ -z "$cid" ]; then
    adapter_cf_line problem "WordPress has no container (not made yet, or removed), so nothing can be exported: run offprint compose up -d"; return
  fi
  env=""
  if ( LC_ALL=C; [[ $cid =~ $id_re ]] ); then
    env="$(docker inspect --format '{{json .Config.Env}}' "$cid" 2> /dev/null < /dev/null | head -c 65536)"
  fi
  if [ -z "$env" ]; then adapter_cf_line problem "Docker couldn't say how WordPress's container was made: run offprint adapter doctor again"; return; fi
  origin="$(LC_ALL=C; [[ $env =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}")"; env=""
  if [ -z "$origin" ]; then
    adapter_cf_line problem "Docker's record of WordPress's container names no public address (OFFPRINT_PUBLIC_ORIGIN): run offprint compose up -d"
  elif [ "$origin" = "$SITE_PUBLIC_URL" ]; then
    adapter_cf_line ok "WordPress exports for site.json's public_url, $SITE_PUBLIC_URL (Docker's record of its container says so)"
  else
    origin="$(printf '%s' "$origin" | LC_ALL=C tr -c ' -~' '?' | cut -c1-200)"
    adapter_cf_line problem "WordPress's container was made for $origin, not site.json's public_url ($SITE_PUBLIC_URL), so a publish would link to the old address: run offprint compose up -d, which makes it again with public_url"
  fi
}
# adapter_cf_line KIND TEXT: one line of the doctor's, "ok" or "problem" and then TEXT; a problem is counted
adapter_cf_line() {
  printf '%-8s %s\n' "$1" "$2"
  [ "$1" = ok ] || adapter_cf_problems=$((adapter_cf_problems + 1))
}

# adapter_cf_check: asks Cloudflare whether it knows the token (cf_token, the caller's) and the token can see the
# account in site.json: GET https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/workers/scripts, the account's
# list of Workers, which changes nothing. (Cloudflare answers it for a token without the Workers permission too: it
# doesn't show the token may upload.) Returns 0 when Cloudflare answers 200 and its JSON's top level says "success":
# true; 1 when it refuses (4xx but 429: 401 when it doesn't know the token, 403, 404 when it finds no such account),
# with cf_http its status and cf_said its first error (code and message, the token's value in it replaced by [token
# hidden], printable ASCII, at most 200 characters); 2 when it can't be told, with cf_problem saying why and cf_advice
# what to do; 3, asking nothing, when the token isn't plainly one (adapter_cf_token_ok: the rule a pasted token is held
# to, applied to one read from the Keychain before it goes into curl's config line). curl (see the top of this file for
# how it is run, and handed the token): https only, 30 seconds and 16 MB at most, no redirect followed (none is
# expected: one is not understood), no -f (a refusal's answer is read for its error), its own messages dropped (its
# status is put into words instead). What it answers goes straight to php, which decodes it and hands back one short
# line (its status, whether it succeeded, and the first error, cut to 4 KB): so no answer, however large, reaches the
# shell's own string work. (The token is hidden after that cut, so a copy of it that the cut runs through is left in
# part, and only 200 characters are shown. The limit, plainly: only a token far longer than a real one, echoed many
# times in the message, can bring part of itself within those 200, since each whole copy before the cut shrinks to the
# 14 characters of [token hidden].)
adapter_cf_check() {
  local curl php out rc ok said url tab=$'\t' code
  export -n out said ok   # (they may hold what Cloudflare answered, the token in it: see adapter_cf_setup)
  code='$raw = (string) stream_get_contents(STDIN);
$nl = strrpos($raw, "\n");
$http = false === $nl ? "" : substr($raw, $nl + 1);
if (1 !== preg_match("/\\A[0-9]{3}\\z/", $http)) { $http = "000"; }
$j = json_decode(false === $nl ? "" : substr($raw, 0, $nl), false);
$raw = "";
$ok = is_object($j) && property_exists($j, "success") && true === $j->success ? "yes" : "no";
$said = "";
if (is_object($j) && isset($j->errors) && is_array($j->errors) && isset($j->errors[0]) && is_object($j->errors[0])) {
  $e = $j->errors[0];
  $c = isset($e->code) && (is_int($e->code) || is_string($e->code)) ? (string) $e->code : "";
  $m = isset($e->message) && is_string($e->message) ? $e->message : "";
  $said = trim(substr((string) preg_replace("/[\\x00-\\x1f\\x7f]+/", " ", substr($c . " " . $m, 0, 8192)), 0, 4096));
}
echo $http, "\t", $ok, "\t", $said;'
  cf_http=""; cf_said=""; cf_problem=""; cf_advice=""
  # A token read from the Keychain may have been stored some other way: one that isn't plainly a token goes nowhere.
  if ! adapter_cf_token_ok; then
    cf_problem="the token isn't plainly an API token (16 to 1024 letters, digits and - _ . ~ + / =), so it wasn't sent to Cloudflare"
    cf_advice="run offprint adapter setup, which asks for a new one"; return 3
  fi
  url="https://api.cloudflare.com/client/v4/accounts/$ADAPTER_SET_ACCOUNT_ID/workers/scripts"
  # curl is handed the token, and php what Cloudflare answers: each found once, by an absolute path, and refused before
  # it runs when it is the site folder's or leads there (adapter_cf_runnable: one WordPress could have put on the PATH).
  curl="$(command -v curl 2> /dev/null)"; rc=0; adapter_cf_runnable "$curl" || rc=$?
  case "$rc" in
    0) ;;
    2) cf_problem="the curl on your PATH, $(_offprint_shown "$curl"), is inside the site folder, which WordPress can write (or leads there), so it wasn't handed the token"
       cf_advice="put a curl from outside the site folder first on your PATH (macOS has /usr/bin/curl)"; return 2 ;;
    *) cf_problem="curl isn't on the PATH"; cf_advice="install curl"; return 2 ;;
  esac
  php="$(command -v php 2> /dev/null)"; rc=0; adapter_cf_runnable "$php" || rc=$?
  case "$rc" in
    0) ;;
    2) cf_problem="the php on your PATH, $(_offprint_shown "$php"), is inside the site folder, which WordPress can write (or leads there), so it wasn't handed Cloudflare's answer"
       cf_advice="put a php from outside the site folder first on your PATH"; return 2 ;;
    *) cf_problem="php isn't on the PATH"; cf_advice="install php"; return 2 ;;
  esac
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$cf_token" \
      | /usr/bin/env -i PATH=/usr/bin:/bin "$curl" -q -s --proto =https --max-time 30 --max-filesize 16777216 --config - \
        -w '\n%{http_code}' "$url" 2> /dev/null \
      | "$php" -n -r "$code" 2> /dev/null
    printf ':%s' "${PIPESTATUS[1]}")"
  rc="${out##*:}"; out="${out%:*}"
  case "$out" in
    *"$tab"*"$tab"*) cf_http="${out%%"$tab"*}"; out="${out#*"$tab"}"; ok="${out%%"$tab"*}"; said="${out#*"$tab"}" ;;
    *) cf_http=000; ok=no; said="" ;;
  esac
  out=""
  case "$cf_http" in [0-9][0-9][0-9]) ;; *) cf_http=000 ;; esac
  if [ "$rc" = 63 ]; then
    cf_problem="Cloudflare's answer was larger than 16 MB, which isn't expected"; cf_advice="try again later"; return 2
  fi
  if [ "$rc" != 0 ] || [ "$cf_http" = 000 ]; then
    cf_problem="api.cloudflare.com couldn't be reached: $(adapter_cf_curl_words "$rc" 30)"; cf_advice="check your connection"; return 2
  fi
  [ -z "$cf_token" ] || said="${said//"$cf_token"/[token hidden]}"
  cf_said="$(printf '%s' "$said" | LC_ALL=C tr -c ' -~' '?' | cut -c1-200)"; said=""
  case "$cf_http" in
    200) [ "$ok" != yes ] || return 0
         cf_problem="Cloudflare's answer (HTTP 200) wasn't understood"; cf_advice="try again later" ;;
    429) cf_problem="Cloudflare answered HTTP 429: too many requests"; cf_advice="wait a minute" ;;
    4??) return 1 ;;
    5??) cf_problem="Cloudflare answered HTTP $cf_http, an error on its side"; cf_advice="try again in a few minutes" ;;
    *) cf_problem="Cloudflare answered HTTP $cf_http, which isn't understood here"; cf_advice="try again later" ;;
  esac
  return 2
}
# adapter_cf_curl_words STATUS SECS: curl's exit status, in words (SECS: its --max-time)
adapter_cf_curl_words() {
  case "$1" in
    6) echo "its name couldn't be looked up" ;;
    7) echo "no connection could be made" ;;
    28) echo "it didn't answer within $2 seconds" ;;
    35|51|53|54|58|59|60|64|66|77|80|82|83|90|91) echo "the secure connection failed" ;;
    *) echo "curl failed with status $1" ;;
  esac
}
# adapter_cf_fetch URL: the live site's status and type for URL (no token involved): curl -q, https only, 10 seconds,
# no redirect followed, what it answers dropped. Sets cf_code (000 when there was no answer), cf_type (printable, up to
# 100 characters) and cf_crc (curl's status).
adapter_cf_fetch() {
  local out
  out="$(curl -q -s --proto =https --max-time 10 -o /dev/null -w '%{http_code} %{content_type}' "$1" 2> /dev/null; printf ':%s' "$?")"
  cf_crc="${out##*:}"; out="${out%:*}"; cf_code="${out%% *}"; cf_type="${out#* }"
  case "$cf_code" in [0-9][0-9][0-9]) ;; *) cf_code=000 ;; esac
  [ "$cf_crc" = 0 ] || cf_code=000
  [ "$cf_code" != 000 ] || cf_type=""
  cf_type="$(printf '%s' "$cf_type" | LC_ALL=C tr -c ' -~' '?' | cut -c1-100)"
}
# adapter_cf_head_id: prints the publish id of the site repo's HEAD, as bin/publish makes it (the git tree id of site/
# without offprint.json), writing nothing: git hands over site/'s tree as it is stored (cat-file), and php checks that
# it is whole (it hashes to the id asked for), drops the offprint.json entry and hashes the rest as git hashes a tree.
# Returns 1 when HEAD has no site/; 2 when the repository's ids aren't 40 hex digits (SHA-1); 3 when HEAD can't be read.
adapter_cf_head_id() {
  local t id hex_re='^[0-9a-f]{40}$' code
  code='$id = $argv[1] ?? ""; $raw = (string) stream_get_contents(STDIN); $n = strlen($raw);
if (sha1("tree " . $n . "\0" . $raw) !== $id) exit(3);
$i = 0; $out = "";
while ($i < $n) {
  $sp = strpos($raw, " ", $i); $nul = false === $sp ? false : strpos($raw, "\0", $sp);
  if (false === $nul || $nul + 21 > $n) exit(3);
  $mode = substr($raw, $i, $sp - $i); $name = substr($raw, $sp + 1, $nul - $sp - 1);
  if (!("offprint.json" === $name && 0 === strncmp($mode, "100", 3))) $out .= substr($raw, $i, $nul + 21 - $i);
  $i = $nul + 21;
}
echo sha1("tree " . strlen($out) . "\0" . $out), "\n";'
  adapter_cf_git rev-parse -q --verify 'HEAD^{commit}' > /dev/null 2>&1 < /dev/null || return 3
  t="$(adapter_cf_git rev-parse -q --verify HEAD:site 2> /dev/null < /dev/null)" || return 1
  [ "$(adapter_cf_git cat-file -t "$t" 2> /dev/null < /dev/null)" = tree ] || return 1
  ( LC_ALL=C; [[ $t =~ $hex_re ]] ) || return 2
  id="$(adapter_cf_git cat-file tree "$t" 2> /dev/null < /dev/null | php -n -r "$code" -- "$t" 2> /dev/null)"
  ( LC_ALL=C; [[ $id =~ $hex_re ]] ) || return 3
  printf '%s\n' "$id"
}

# adapter_cf_node_version NODE: the version NODE says it is (node --version: vX.Y.Z...), as X.Y.Z; nothing when it says
# none. node runs with an empty environment (so no NODE_OPTIONS can have it load anything), for 10 seconds at most.
adapter_cf_node_version() {
  local line re='^v([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})'
  line="$(adapter_cf_limited 10 /usr/bin/env -i "$1" --version | head -n 1 | head -c 100)"
  ( LC_ALL=C; [[ $line =~ $re ]] && printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" )
}
# adapter_cf_new_enough X.Y.Z: whether that is adapter_cf_floor or newer (by major and minor: the floor's patch is 0)
adapter_cf_new_enough() {
  local a b x y
  a="${1%%.*}"; b="${1#*.}"; b="${b%%.*}"; x="${adapter_cf_floor%%.*}"; y="${adapter_cf_floor#*.}"; y="${y%%.*}"
  [ "$a" -gt "$x" ] || { [ "$a" -eq "$x" ] && [ "$b" -ge "$y" ]; }
}
# adapter_cf_limited SECS CMD...: runs CMD, stdin /dev/null and its stderr dropped, its stdout this function's; once it
# has run SECS seconds, it and every process under it are killed, and this returns 124; else CMD's status.
adapter_cf_limited() {
  local secs="$1" pid waited=0; shift
  "$@" < /dev/null 2> /dev/null &
  pid=$!
  while adapter_cf_alive "$pid" && [ "$waited" -lt $((secs * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
  if adapter_cf_alive "$pid"; then adapter_cf_kill_tree "$pid"; wait "$pid" 2> /dev/null; return 124; fi
  wait "$pid"
}
# adapter_cf_whole DIR: whether DIR holds a whole wrangler 4.166.0: one a publish may run (adapter_cf_install_ok: not a
# link, nothing leading into the site folder, its entry script there), and node_modules/wrangler/package.json saying
# exactly that version (read as JSON, by php); else 1, with cf_why saying what isn't so. (One that isn't whole, a link
# included, is replaced by set-up: moved aside whole, never followed, and removed once the new one is in place.)
adapter_cf_whole() {
  local v
  adapter_cf_install_ok "$1" || return 1
  v="$(php -n -r '$j = json_decode((string) @file_get_contents($argv[1]), true);
    $v = is_array($j) && isset($j["version"]) && is_string($j["version"]) ? $j["version"] : "";
    $ok = strlen($v) <= 40 && strspn($v, "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+-") === strlen($v);
    echo $ok ? $v : "?";' -- "$1/node_modules/wrangler/package.json" 2> /dev/null < /dev/null)"
  [ "$v" != 4.166.0 ] || return 0
  if [ -z "$v" ]; then cf_why="its node_modules/wrangler/package.json has no version"
  else cf_why="its node_modules/wrangler/package.json says version $v"; fi
  return 1
}
# adapter_cf_clean_path: PATH without its empty and relative entries (".", "bin"), for this shell and everything it runs
# from here on: the folder such an entry names is wherever set-up runs from (the site's wp-content/, say, which
# WordPress can write), so a node, an npm, a curl (handed the token) or a php there would be run. (bin/offprint and
# lib/site.sh, which ran before this, looked their own commands up on the PATH as given: an Offprint command run with
# such a PATH from a folder WordPress can write is unsafe whatever this does.) adapter_cf_dropped: those entries, each
# as "E:ENTRY" and a line end. adapter_cf_dropped_node: when a node is in one of those folders, which (in words, for a
# message); else nothing.
adapter_cf_clean_path() {
  local e rest="$PATH:" kept="" nl=$'\n'
  adapter_cf_dropped=""
  while [ -n "$rest" ]; do
    e="${rest%%:*}"; rest="${rest#*:}"
    case "$e" in /*) kept="${kept:+$kept:}$e" ;; *) adapter_cf_dropped="${adapter_cf_dropped}E:$e$nl" ;; esac
  done
  PATH="${kept:-/usr/bin:/bin}"; hash -r   # (never empty: bash would search the folder it is in)
}
adapter_cf_dropped_node() {
  local rest="$adapter_cf_dropped" e nl=$'\n'
  while [ -n "$rest" ]; do
    e="${rest%%"$nl"*}"; rest="${rest#*"$nl"}"; e="${e#E:}"
    if [ -f "${e:-.}/node" ] && [ -x "${e:-.}/node" ]; then
      if [ -z "$e" ]; then echo "an empty PATH entry (the folder you run it from)"; else echo "the relative PATH entry \"$(_offprint_shown "$e")\""; fi
      return 0
    fi
  done
}
