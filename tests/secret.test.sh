#!/usr/bin/env bash
# Tests os/darwin/secret (a named secret of a site's, in the macOS login Keychain) and lib/adapter.sh's
# offprint_secret_get, _set and _delete, with a stand-in `security` (OFFPRINT_SECURITY) that keeps its items in a file in
# the suite's temp folder. Nothing here runs the real security, so it never reads or changes a real keychain; it runs
# the same on macOS and on Linux, which has no security at all. Every value is a recognisable fake ("fake-value-..."),
# and the suite looks for it, and for its hex, wherever it must not be: in the stand-in's arguments, in any message, in
# set -x output, in any file under the suite's temp folder.
# Run: bash tests/secret.test.sh   (macOS bash 3.2 and Linux)
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
SECRET="$SRC/os/darwin/secret"
unset OFFPRINT_SITE OFFPRINT_SECURITY OFFPRINT_SECRET_TIMEOUT
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR).
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-secret-test.XXXXXX")"
# Whatever a stand-in left running (if the script failed to stop it) is stopped too, so the suite leaves no process.
cleanup() {
  local f
  for f in "$tmp"/stubs*/stub.pid "$tmp"/stubs*/child.pid "$tmp"/stubs*/children; do
    [ -f "$f" ] && kill -KILL $(cat "$f") 2>/dev/null
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
# Nothing may be left in TMPDIR by the script (see the end): it makes no temporary file.
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
contains() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no '$2' in '$3')"; fi; }
# lacks NAME TEXT HAYSTACK: the haystack is not shown when it fails (it may hold the value)
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 (it is there)"; else ok "$1"; fi; }
hex() { printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'; }   # the value reaches od on its stdin, not as an argument

# --- the stand-in security ---
mkdir -p "$tmp/bin"
cat > "$tmp/bin/security" <<'STUB'
#!/usr/bin/env bash
# A stand-in for macOS's security: generic passwords kept in $STUB_DIR/items, a line each (service, account and the
# password's bytes in hex, tab-separated). Its arguments are noted, a line a run, in $STUB_DIR/argv (never what it reads
# on stdin). Exit statuses are the real one's, as seen on macOS: 44 no such item, 45 the item exists already (an add
# without -U), 2 a usage error. What the case asks, by a file in $STUB_DIR:
#   exit       every command fails with the status in the file (36, 51, 128, 152: locked; any other: a failure)
#   hang       find-generic-password never answers: it waits on a child (its pid in stub.pid, the child's in child.pid)
#   stubborn   as hang, but it and its child ignore TERM
#   spawner    find-generic-password never answers: it starts another child every 50 ms (their pids in children)
#   answer_then_hang   find-generic-password prints its answer, then waits on a child as hang does
# find-generic-password notes what it finds on its stdin (64 bytes at most) in $STUB_DIR/find.stdin.
# -i reads its commands from stdin as the real one does: a last line without its line end is not run; and a line of 4095
# characters or more (which the real one would cut in two, the rest run as a command of its own) is noted in
# $STUB_DIR/overflow, and fails with 99. Words are split at spaces only: nothing that needs a quote is ever sent. What its
# stdin is (pipe, file or other) is noted, a line a run, in $STUB_DIR/i.stdin: a here-doc or here-string is a file on
# macOS's bash 3.2 (in /private/var/tmp).
set -u
export LC_ALL=C
printf '%s\n' "$*" >> "$STUB_DIR/argv"
items="$STUB_DIR/items"; touch "$items"
run() {
  local cmd="${1-}" s="" a="" x="" update=0 w=0 rc hex i
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -s) s="${2-}"; shift 2 ;;
      -a) a="${2-}"; shift 2 ;;
      -X) x="${2-}"; shift 2 ;;
      -U) update=1; shift ;;
      -w) w=1; shift ;;   # find: print the password only; add: refused (its value would be a word of the command)
      *) echo "security (stand-in): unexpected argument $1" >&2; return 2 ;;
    esac
  done
  if [ -f "$STUB_DIR/exit" ]; then
    rc="$(cat "$STUB_DIR/exit")"; echo "security: the stand-in fails with status $rc" >&2; return "$rc"
  fi
  case "$cmd" in
    add-generic-password)
      if [ "$w" = 1 ] || ! [[ $x =~ ^([0-9a-f][0-9a-f])+$ ]]; then
        echo "security: Unable to convert password data (-X must specify valid hex digits)" >&2; return 2
      fi
      if [ -n "$(awk -F '\t' -v s="$s" -v a="$a" '$1 == s && $2 == a' "$items")" ]; then
        [ "$update" = 1 ] || { echo "security: The specified item already exists in the keychain." >&2; return 45; }
        awk -F '\t' -v s="$s" -v a="$a" '!($1 == s && $2 == a)' "$items" > "$items.new" && mv "$items.new" "$items"
      fi
      printf '%s\t%s\t%s\n' "$s" "$a" "$x" >> "$items" ;;
    find-generic-password)
      head -c 64 > "$STUB_DIR/find.stdin"
      if [ -f "$STUB_DIR/hang" ] || [ -f "$STUB_DIR/stubborn" ]; then
        [ -f "$STUB_DIR/stubborn" ] && trap '' TERM
        echo "$$" > "$STUB_DIR/stub.pid"; sleep 30 & echo "$!" > "$STUB_DIR/child.pid"; wait; return 0
      fi
      if [ -f "$STUB_DIR/spawner" ]; then
        echo "$$" > "$STUB_DIR/stub.pid"
        while :; do sleep 30 & echo "$!" >> "$STUB_DIR/children"; sleep 0.05; done
      fi
      hex="$(awk -F '\t' -v s="$s" -v a="$a" '$1 == s && $2 == a { print "found:" $3; exit }' "$items")"
      if [ -z "$hex" ]; then
        echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; return 44
      fi
      hex="${hex#found:}"
      if [ "$w" = 1 ]; then i=0; while [ "$i" -lt "${#hex}" ]; do printf "\\x${hex:i:2}"; i=$((i + 2)); done; echo
      else printf 'keychain: "stand-in"\nclass: "genp"\n'; fi
      if [ -f "$STUB_DIR/answer_then_hang" ]; then
        echo "$$" > "$STUB_DIR/stub.pid"; sleep 30 & echo "$!" > "$STUB_DIR/child.pid"; wait
      fi ;;
    delete-generic-password)
      if [ -z "$(awk -F '\t' -v s="$s" -v a="$a" '$1 == s && $2 == a' "$items")" ]; then
        echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; return 44
      fi
      awk -F '\t' -v s="$s" -v a="$a" '!($1 == s && $2 == a)' "$items" > "$items.new" && mv "$items.new" "$items"
      printf 'keychain: "stand-in"\nclass: "genp"\n'; echo "password has been deleted." >&2 ;;
    *) echo "security: unknown command \"$cmd\"" >&2; return 1 ;;
  esac
}
if [ "${1-}" = -i ]; then
  [ $# -eq 1 ] || { echo "security (stand-in): nothing may follow -i" >&2; exit 2; }
  if [ -p /dev/stdin ]; then echo pipe; elif [ -f /dev/stdin ]; then echo file; else echo other; fi >> "$STUB_DIR/i.stdin"
  rc=0
  while IFS= read -r line; do
    if [ "${#line}" -ge 4095 ]; then echo "${#line}" >> "$STUB_DIR/overflow"; exit 99; fi
    set -f; set -- $line; set +f
    [ $# -gt 0 ] || continue
    run "$@"; rc=$?
    [ "$rc" = 0 ] || echo "$1: returned $rc" >&2
  done
  exit "$rc"
fi
run "$@"
STUB
chmod +x "$tmp/bin/security"

# --- the site folders: A ("example", tests/fixtures/site.json), B ("other"), one with a bad site.json, and a folder
# that is in no site ---
A="$tmp/site-a"; B="$tmp/site-b"
mkdir -p "$A" "$B" "$tmp/broken" "$tmp/nosite" "$tmp/elsewhere"
cp tests/fixtures/site.json "$A/site.json"
sed 's/"name": "example"/"name": "other"/' tests/fixtures/site.json > "$B/site.json"
sed 's/"name": "example"/"name": "Not A Name"/' tests/fixtures/site.json > "$tmp/broken/site.json"
A="$(cd "$A" && pwd -P)"; B="$(cd "$B" && pwd -P)"

# stubs: a fresh state for the stand-in (no item, no mode), in $S
k=0
stubs() { k=$((k + 1)); S="$tmp/stubs$k"; mkdir -p "$S"; }
# sec SITE ARGS... (stdin: the caller's): os/darwin/secret for the site folder SITE ("" for none: then from
# $tmp/nosite), with the stand-in. Sets out (its stdout, exactly), err and code.
sec() {
  local site="$1"; shift
  out="$(cd "$tmp/nosite" && OFFPRINT_SITE="$site" OFFPRINT_SECURITY="${SECURITY_CMD:-$tmp/bin/security}" STUB_DIR="$S" \
    /bin/bash "$SECRET" "$@" 2> "$tmp/err"; printf '|%s' "$?")"
  code="${out##*|}"; out="${out%|*}"; err="$(cat "$tmp/err")"
}
ran() { if [ -f "$S/argv" ]; then echo yes; else echo no; fi; }   # whether the stand-in was run at all
gone() { if [ ! -f "$1" ]; then echo "never started"; elif kill -0 "$(cat "$1")" 2>/dev/null; then echo running; else echo gone; fi; }
stdin_seen() { cat "$S/find.stdin" 2>/dev/null || echo "(security wasn't run)"; }   # what find-generic-password read

V1=' fake-value-123 $HOME '"'"'q'"'"' "dq" \b\s '   # a dollar, both quotes, backslashes, spaces at both ends
V2='fake-value-456'
NAME_RULE="a lowercase letter, then up to 60 lowercase letters, digits and dashes"

# --- usage and names ---
stubs
sec "$A"; t="no arguments"
check "$t: exit 2" 2 "$code"; contains "$t: usage" "usage: os/darwin/secret get|set|delete NAME" "$err"
sec "$A" show api-token; check "an unknown command: exit 2" 2 "$code"
contains "an unknown command: usage" "usage: os/darwin/secret get|set|delete NAME" "$err"
sec "$A" get api-token extra; check "an argument too many: exit 2" 2 "$code"
long61="a$(printf '%060d' 0 | tr 0 b)"; long62="${long61}c"
for bad_name in '' A 1abc a_b a/b -x 'a b' ../x 'a.b' "$(printf 'a\nb')" "$long62"; do
  sec "$A" get "$bad_name"; t="the name '$(printf '%s' "$bad_name" | tr '\n' '?' | cut -c1-20)'"
  check "$t: refused, exit 2" 2 "$code"; contains "$t: the rule is said" "$NAME_RULE" "$err"
done
check "bad names: the stand-in never ran" no "$(ran)"
sec "$A" get "$long61"; check "a name of 61 characters is a name (none is stored: exit 1)" 1 "$code"

# --- the site ---
stubs
sec "" get api-token; t="not in a site folder"
check "$t: exit 2" 2 "$code"; contains "$t: says so" "Not in an Offprint site folder" "$err"
sec "$tmp/broken" get api-token; t="a site.json that isn't valid"
check "$t: exit 2" 2 "$code"; contains "$t: says why" '"name"' "$err"
check "no site: the stand-in never ran" no "$(ran)"

# --- set, then get ---
stubs
sec "$A" set api-token < <(printf '%s' "$V1"); t="set a value with a dollar, both quotes, backslashes and spaces"
check "$t: exit 0, nothing said" "0||" "$code|$out|$err"
check "$t: security's only argument is -i (the value goes on its stdin)" "-i" "$(cat "$S/argv")"
check "$t: security's stdin is a pipe (a here-doc or here-string would be a file, on macOS's bash 3.2)" pipe "$(cat "$S/i.stdin" 2>/dev/null)"
check "$t: stored, as hex, under service offprint, account SITE_NAME/NAME" "$(printf 'offprint\texample/api-token\t%s' "$(hex "$V1")")" "$(cat "$S/items")"
: > "$S/argv"
sec "$A" get api-token < <(printf 'INPUT FOR NOBODY\n'); t="get it back"
check "$t: exit 0" 0 "$code"
check "$t: stdout is exactly the value (no line end after it)" "[$V1]" "[$out]"
check "$t: nothing on stderr" "" "$err"
check "$t: security's arguments" "find-generic-password -s offprint -a example/api-token -w" "$(cat "$S/argv")"
check "$t: security's stdin is /dev/null, not get's own" "" "$(stdin_seen)"
sec "$A" set api-token < <(printf '%s' "$V2"); t="set another value for the same name"
check "$t: exit 0" 0 "$code"
sec "$A" get api-token < /dev/null; check "$t: it replaces the first" "0|[$V2]" "$code|[$out]"
sec "$A" set api-token < <(printf '%s\n' "$V1"); t="a value with one line end after it"
check "$t: exit 0" 0 "$code"
sec "$A" get api-token < /dev/null; check "$t: the line end isn't part of the value" "0|[$V1]" "$code|[$out]"

# --- values refused: each exit 2, with a reason that doesn't show the value; nothing stored, security not run ---
refused() {  # refused WHAT WORD: set (from stdin) is refused, saying WORD; the value stored before is still there
  : > "$S/argv"
  sec "$A" set api-token; t="a value $1"
  check "$t: refused, exit 2" 2 "$code"; contains "$t: says why" "$2" "$err"; contains "$t: nothing was stored" "nothing was stored" "$err"
  lacks "$t: the message doesn't show the value" "fake-value" "$err"
  check "$t: security wasn't run" "" "$(cat "$S/argv")"
  sec "$A" get api-token < /dev/null; check "$t: the value from before is kept" "0|[$V1]" "$code|[$out]"
}
refused "with a line end inside it" "more than one line" < <(printf 'fake-value-bad\nsecond line')
refused "with two line ends after it" "more than one line" < <(printf 'fake-value-bad\n\n')
refused "with a NUL in it" "NUL" < <(printf 'fake-value-bad\0after')
refused "ending in a NUL" "NUL" < <(printf 'fake-value-bad\0')
refused "with a tab in it" "control character" < <(printf 'fake-value\tbad')
refused "with a Windows line end" "control character" < <(printf 'fake-value-bad\r\n')
refused "with an escape in it" "control character" < <(printf 'fake-value-\033[1mbad')
refused "with a DEL in it" "control character" < <(printf 'fake-value-bad\177')
refused "with a letter outside ASCII" "outside ASCII" < <(printf 'fake-value-caf\303\251')
refused "that is empty" "empty" < <(printf '')
refused "that is only a line end" "empty" < <(printf '\n')
refused "of 1025 characters" "longer than 1024" < <(printf 'fake-value-%01014d' 0)
refused "of 1026 characters with a line end" "longer than 1024" < <(printf 'fake-value-%01015d\n' 0)
LONG="fake-value-$(printf '%01013d' 0)"
sec "$A" set api-token < <(printf '%s\n' "$LONG"); t="a value of 1024 characters"
check "$t: stored" "0|1024" "$code|${#LONG}"
sec "$A" get api-token < /dev/null; check "$t: comes back exactly" "0|yes" "$code|$([ "$out" = "$LONG" ] && echo yes || echo no)"
check "$t: no command line security can't take whole (4095 characters or more) was sent" no "$([ -e "$S/overflow" ] && echo yes || echo no)"

# --- not found, locked, failed ---
stubs
sec "$A" get api-token < /dev/null; t="get, nothing stored"
check "$t: exit 1" 1 "$code"
check "$t: the message" "No secret called api-token is stored for this site; run offprint adapter setup." "$err"
check "$t: nothing on stdout" "" "$out"
sec "$A" set api-token < <(printf '%s' "$V1")
for rc in 36 51 128 152; do
  echo "$rc" > "$S/exit"; sec "$A" get api-token < /dev/null; t="get, security exits $rc (the Keychain can't be read without a prompt)"
  check "$t: exit 3" 3 "$code"; check "$t: the message" "The login Keychain is locked, so api-token couldn't be read." "$err"
  check "$t: nothing on stdout" "" "$out"
done
echo 50 > "$S/exit"; sec "$A" get api-token < /dev/null; t="get, security fails another way (status 50)"
check "$t: exit 4" 4 "$code"; contains "$t: names the status" "status 50" "$err"; check "$t: nothing on stdout" "" "$out"
echo 152 > "$S/exit"; sec "$A" set api-token < <(printf '%s' "$V2"); t="set, the Keychain locked (152)"
check "$t: exit 3" 3 "$code"; check "$t: the message" "The login Keychain is locked, so api-token couldn't be stored." "$err"
echo 50 > "$S/exit"; sec "$A" set api-token < <(printf '%s' "$V2"); t="set, security fails another way (status 50)"
check "$t: exit 4" 4 "$code"; contains "$t: names the status" "status 50" "$err"; lacks "$t: the message doesn't show the value" "fake-value" "$err"
echo 36 > "$S/exit"; sec "$A" delete api-token; t="delete, the Keychain locked (36)"
check "$t: exit 3" 3 "$code"; check "$t: the message" "The login Keychain is locked, so api-token couldn't be deleted." "$err"
echo 50 > "$S/exit"; sec "$A" delete api-token; t="delete, security fails another way (status 50)"
check "$t: exit 4" 4 "$code"; contains "$t: names the status" "status 50" "$err"
rm -f "$S/exit"
sec "$A" get api-token < /dev/null; check "the failed set and delete changed nothing" "0|[$V1]" "$code|[$out]"
# Items set some other way (in Keychain Access, say): written straight into the stand-in's store.
printf 'offprint\texample/empty-one\t\n' >> "$S/items"
sec "$A" get empty-one < /dev/null; t="get, an empty value is stored"
check "$t: taken as none, exit 1" "1|No secret called empty-one is stored for this site; run offprint adapter setup." "$code|$err"
check "$t: nothing on stdout" "" "$out"
printf 'offprint\texample/tab-one\t%s\n' "$(printf 'fake-value\tbad' | od -An -tx1 -v | tr -d ' \n')" >> "$S/items"
sec "$A" get tab-one < /dev/null; t="get, a value with a tab in it is stored"
check "$t: not used, exit 4" "4|The Keychain's answer for tab-one isn't one line of printable characters, so it wasn't used." "$code|$err"
check "$t: nothing on stdout" "" "$out"
# Longer than set ever stores (1024 characters): not used either, the message quoting none of it.
printf 'offprint\texample/long-one\t%s\n' "$(printf 'fake-value-%01014d' 0 | od -An -tx1 -v | tr -d ' \n')" >> "$S/items"
sec "$A" get long-one < /dev/null; t="get, a value of 1025 characters is stored"
check "$t: not used, exit 4" "4|The Keychain's answer for long-one is longer than 1024 characters, so it wasn't used." "$code|$err"
check "$t: nothing on stdout" "" "$out"
printf 'offprint\texample/max-one\t%s\n' "$(printf 'fake-value-%01013d' 0 | od -An -tx1 -v | tr -d ' \n')" >> "$S/items"
sec "$A" get max-one < /dev/null; t="get, a value of 1024 characters is stored"
check "$t: used, whole" "0||1024" "$code|$err|${#out}"
SECURITY_CMD="$tmp/no-such-security"
sec "$A" get api-token; t="get, no security there"
check "$t: exit 4" 4 "$code"; contains "$t: says where it looked" "$tmp/no-such-security" "$err"
sec "$A" set api-token < <(printf '%s' "$V2"); check "set, no security there: exit 4" 4 "$code"
sec "$A" delete api-token; check "delete, no security there: exit 4" 4 "$code"
unset SECURITY_CMD

# --- a security that never answers: get stops it at the limit ---
stubs; sec "$A" set api-token < <(printf '%s' "$V1")
touch "$S/hang"; start=$SECONDS
OFFPRINT_SECRET_TIMEOUT=1 sec "$A" get api-token < /dev/null; took=$((SECONDS - start)); t="get, security hangs (a limit of 1 second)"
check "$t: exit 3" 3 "$code"; check "$t: the message" "The login Keychain is locked, so api-token couldn't be read." "$err"
check "$t: stopped after the limit, not before, and soon after" yes "$([ "$took" -ge 1 ] && [ "$took" -le 5 ] && echo yes || echo "no ($took s)")"
check "$t: security is stopped" gone "$(gone "$S/stub.pid")"
check "$t: and the process it started" gone "$(gone "$S/child.pid")"
rm -f "$S/hang" "$S/stub.pid" "$S/child.pid"; touch "$S/stubborn"; start=$SECONDS
OFFPRINT_SECRET_TIMEOUT=1 sec "$A" get api-token < /dev/null; took=$((SECONDS - start)); t="get, security hangs and ignores TERM"
check "$t: exit 3" 3 "$code"
check "$t: killed at the limit all the same" yes "$([ "$took" -ge 1 ] && [ "$took" -le 5 ] && echo yes || echo "no ($took s)")"
check "$t: security is stopped" gone "$(gone "$S/stub.pid")"
check "$t: and the process it started" gone "$(gone "$S/child.pid")"
rm -f "$S/stub.pid" "$S/child.pid"
# Each process is frozen before its children are looked for, so not one started in the meantime gets away (and keeps
# get waiting on the output it holds open).
rm -f "$S/stubborn"; touch "$S/spawner"; start=$SECONDS
OFFPRINT_SECRET_TIMEOUT=1 sec "$A" get api-token < /dev/null; took=$((SECONDS - start)); t="get, security hangs, starting a process every 50 ms"
check "$t: exit 3" 3 "$code"
check "$t: stopped at the limit" yes "$([ "$took" -ge 1 ] && [ "$took" -le 5 ] && echo yes || echo "no ($took s)")"
check "$t: security is stopped" gone "$(gone "$S/stub.pid")"
left=""; for p in $(cat "$S/children" 2>/dev/null); do kill -0 "$p" 2>/dev/null && left="$left $p"; done
check "$t: it started some" yes "$([ -s "$S/children" ] && echo yes || echo no)"
check "$t: and every one of them is stopped" "" "$left"
rm -f "$S/spawner" "$S/stub.pid"
# A TERM to get, as bin/publish's cleanup sends one to each process it started (top down), stops even a security that
# ignores TERM, at once: get stops it as it goes.
touch "$S/stubborn"
( OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" exec /bin/bash "$SECRET" get api-token > /dev/null 2>&1 < /dev/null ) &
pid=$!; i=0; while [ ! -s "$S/child.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
t="a TERM to get while security, ignoring TERM, hangs"
check "$t: (control) security is running" running "$(gone "$S/child.pid")"
term_tree() { local kids p; kids="$(pgrep -P "$1" 2>/dev/null)"; kill -TERM "$1" 2>/dev/null; for p in $kids; do term_tree "$p"; done; }
term_tree "$pid"; wait "$pid" 2>/dev/null; sleep 1
check "$t: security is stopped" gone "$(gone "$S/stub.pid")"
check "$t: and the process it started" gone "$(gone "$S/child.pid")"
rm -f "$S/stubborn"
# The seam can only shorten the limit: 0, or more than 10, is ignored, and the limit stays 10 seconds. (Both at once.)
for v in 0 999; do
  stubs; sec "$A" set api-token < <(printf '%s' "$V1"); touch "$S/hang"
  ( start=$SECONDS; OFFPRINT_SECRET_TIMEOUT="$v" sec "$A" get api-token < /dev/null
    echo "$code $((SECONDS - start))" > "$S/result" ) &
done
wait
for v in 0 999; do
  [ "$v" = 0 ] && S="$tmp/stubs$((k - 1))" || S="$tmp/stubs$k"
  read -r code took < "$S/result"; t="get, security hangs, the seam set to $v (ignored)"
  check "$t: exit 3" 3 "$code"
  check "$t: stopped at 10 seconds" yes "$([ "$took" -ge 10 ] && [ "$took" -le 14 ] && echo yes || echo "no ($took s)")"
  check "$t: security is stopped" gone "$(gone "$S/stub.pid")"
done

# --- get interrupted once security has answered: nothing of the value is shown ---
# The shell that runs security (get's child) is sent a TERM, then an INT, after security has printed the value (and goes
# on waiting). Its status never comes, so what get read is the value alone: none of it may be printed, nor taken for a
# status and quoted. Job control (set -m) leaves get the INT a terminal would send: in the background without it, INT is
# ignored, and the case would prove nothing.
# interrupt SIG NAME VALUE WHAT: VALUE stored as NAME; get NAME, its child sent SIG once security has answered.
interrupt() {
  local sig="$1" name="$2" v="$3" pieces="" p i
  sec "$A" set "$name" < <(printf '%s' "$v")
  rm -f "$S/stub.pid" "$S/child.pid"; touch "$S/answer_then_hang"; start=$SECONDS
  ( set -m
    OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" /bin/bash "$SECRET" get "$name" \
      > "$S/get-$name-$sig.out" 2> "$S/get-$name-$sig.err" < /dev/null &
    getpid=$!; i=0
    while [ ! -s "$S/child.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    kill "-$sig" $(pgrep -P "$getpid") 2>/dev/null
    wait "$getpid"; echo "$?" > "$S/get-$name-$sig.rc" )
  took=$((SECONDS - start)); t="get, $4, its child sent $sig once security has answered"
  out="$(cat "$S/get-$name-$sig.out")"; err="$(cat "$S/get-$name-$sig.err")"
  check "$t: (control) security had answered, and was waiting" yes "$([ -s "$S/child.pid" ] && echo yes || echo no)"
  check "$t: exit 4, at once (not at the limit)" "4|yes" "$(cat "$S/get-$name-$sig.rc")|$([ "$took" -le 5 ] && echo yes || echo "no ($took s)")"
  check "$t: the message quotes nothing it read" "The Keychain's answer for $name didn't come back whole, so none of it was used." "$err"
  check "$t: nothing on stdout" "" "$out"
  i=0; while [ "$i" -le $((${#v} - 6)) ]; do p="${v:i:6}"; case "$out$err" in *"$p"*) pieces="$pieces [$p]" ;; esac; i=$((i + 1)); done
  check "$t: no 6-character piece of the value on stdout or stderr" "" "$pieces"
  check "$t: security is stopped" gone "$(gone "$S/stub.pid")"
  check "$t: and the process it started" gone "$(gone "$S/child.pid")"
  rm -f "$S/answer_then_hang"
}
stubs
interrupt TERM leaky 'fake-value-cut:zq-SECRET-99' "a value with a colon"
interrupt INT leaky 'fake-value-cut:zq-SECRET-99' "a value with a colon"
# A value that ends as the status would ("STOPPED:STATUS"): only the shell's own exit says that status never came.
interrupt TERM tail 'fake-value-tail-zq-SECRET:0:0' "a value ending ':0:0'"

# --- two sites, one name: separate values ---
stubs
sec "$A" set api-token < <(printf 'fake-value-for-a'); check "site A sets api-token" 0 "$code"
sec "$B" set api-token < <(printf 'fake-value-for-b'); check "site B sets api-token" 0 "$code"
sec "$A" get api-token < /dev/null; check "site A gets its own" "0|fake-value-for-a" "$code|$out"
sec "$B" get api-token < /dev/null; check "site B gets its own" "0|fake-value-for-b" "$code|$out"
check "each under its site's account" "offprint example/api-token|offprint other/api-token" "$(cut -f1,2 "$S/items" | tr '\t' ' ' | paste -sd'|' -)"
out="$(cd "$A" && OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" /bin/bash "$SECRET" get api-token < /dev/null)"
check "from inside site A's folder (no OFFPRINT_SITE), A's" fake-value-for-a "$out"
sec "$B" delete api-token; t="delete B's"
check "$t: exit 0, nothing said (security's own words dropped)" "0||" "$code|$out|$err"
sec "$B" get api-token < /dev/null; check "$t: B's is gone" 1 "$code"
sec "$A" get api-token < /dev/null; check "$t: A's is still there" "0|fake-value-for-a" "$code|$out"
sec "$B" delete api-token; t="delete, nothing stored"
check "$t: exit 1" 1 "$code"; check "$t: the message" "No secret called api-token is stored for this site, so nothing was deleted." "$err"

# --- set -x: the value is never traced ---
stubs
sec "$A" set api-token < <(printf '%s' "$V1")
out="$(printf '%s' "$V2" | OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" /bin/bash -x "$SECRET" set api-token 2>&1)"
rc=$?; t="bash -x secret set"; check "$t: stored" 0 "$rc"
check "$t: traced, and the trace stops at once" "+ set +x" "$out"
lacks "$t: the value isn't traced" "fake-value" "$out"; lacks "$t: nor its hex" "$(hex "$V2")" "$out"
out="$(OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" /bin/bash -x "$SECRET" get api-token 2> "$tmp/err" < /dev/null)"
err="$(cat "$tmp/err")"; t="bash -x secret get"; check "$t: stdout is the value" "$V2" "$out"
check "$t: traced, and the trace stops at once" "+ set +x" "$err"
lacks "$t: the value isn't traced" "fake-value" "$err"; lacks "$t: nor its hex" "$(hex "$V2")" "$err"
out="$(OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" env SHELLOPTS=xtrace /bin/bash "$SECRET" get api-token 2> "$tmp/err" < /dev/null)"
err="$(cat "$tmp/err")"; t="SHELLOPTS=xtrace from the caller"; check "$t: get's stdout is the value" "$V2" "$out"
check "$t: get is traced, and the trace stops at once" "+ set +x" "$err"
out="$(printf '%s' "$V1" | OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" env SHELLOPTS=xtrace /bin/bash "$SECRET" set api-token 2>&1)"
check "$t: set is traced, and the trace stops at once" "+ set +x" "$out"

# --- lib/adapter.sh's wrappers: for the loaded site (SITE), wherever they run from ---
stubs
cat > "$tmp/driver" <<'D'
. "$SRC/lib/site.sh"; . "$SRC/lib/adapter.sh"
offprint_find_site; unset OFFPRINT_SITE
cd "$HERE" || exit 9
"$@"
D
# wrap HERE ARGS...: ARGS (a wrapper and its NAME) in a shell that has loaded lib/site.sh and lib/adapter.sh for site A,
# from the folder HERE. Sets out, err, code.
wrap() {
  local here="$1"; shift
  out="$(SRC="$SRC" HERE="$here" OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" \
    /bin/bash "$tmp/driver" "$@" 2> "$tmp/err"; printf '|%s' "$?")"
  code="${out##*|}"; out="${out%|*}"; err="$(cat "$tmp/err")"
}
wrap "$tmp/elsewhere" offprint_secret_set api-token < <(printf 'fake-value-wrapped'); t="offprint_secret_set"
check "$t: reads its stdin, stores it, says nothing" "0||" "$code|$out|$err"
check "$t: for the loaded site (account example/api-token)" "offprint example/api-token" "$(cut -f1,2 "$S/items" | tr '\t' ' ')"
wrap "$B" offprint_secret_get api-token < <(printf 'INPUT FOR NOBODY\n'); t="offprint_secret_get, run from inside site B's folder"
check "$t: the loaded site's value (A's), exactly" "0|[fake-value-wrapped]" "$code|[$out]"
check "$t: security's stdin is /dev/null" "" "$(stdin_seen)"
wrap "$tmp/elsewhere" offprint_secret_get no-such-name; t="offprint_secret_get, nothing stored"
check "$t: exit 1, and the message" "1|No secret called no-such-name is stored for this site; run offprint adapter setup." "$code|$err"
echo 152 > "$S/exit"; wrap "$tmp/elsewhere" offprint_secret_get api-token; t="offprint_secret_get, locked"
check "$t: exit 3, and the message" "3|The login Keychain is locked, so api-token couldn't be read." "$code|$err"
rm -f "$S/exit"
wrap "$tmp/elsewhere" offprint_secret_get Bad; check "offprint_secret_get, a bad name: exit 2" 2 "$code"
wrap "$tmp/elsewhere" offprint_secret_delete api-token; t="offprint_secret_delete"
check "$t: exit 0, nothing said" "0||" "$code|$out|$err"
wrap "$tmp/elsewhere" offprint_secret_get api-token; check "$t: it is gone" 1 "$code"

# --- the bash that runs it: /bin/bash, never one on the PATH ---
# The script holds the value, so neither its #! line nor the wrappers have a bash (or an env) looked up on the PATH: a
# look-alike of each, first on the PATH, notes its arguments (planted.args) and keeps what it was given on stdin and what
# it printed (planted.stdin, planted.stdout), then runs the real one. It is never run, and so never sees the value. (It
# is planted outside the site folder: lib/site.sh leaves a PATH entry in the site folder out before anything runs, and
# says so, so one there would test that instead; the PATH clean-up's own cases are below.)
P="$tmp/planted-tools"; mkdir -p "$P"
for t in bash env; do
  case "$t" in bash) real=/bin/bash ;; *) real=/usr/bin/env ;; esac
  printf '#!/bin/sh\necho "%s $*" >> "%s/planted.args"\n/bin/cat > "%s/planted.$$.in"\n%s "$@" < "%s/planted.$$.in" > "%s/planted.$$.out"; rc=$?\n/bin/cat "%s/planted.$$.out"\n/bin/cat "%s/planted.$$.in" >> "%s/planted.stdin"; /bin/cat "%s/planted.$$.out" >> "%s/planted.stdout"\n/bin/rm -f "%s/planted.$$.in" "%s/planted.$$.out"\nexit $rc\n' \
    "$t" "$tmp" "$tmp" "$real" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" > "$P/$t"
  chmod +x "$P/$t"
done
# planted: whether the planted bash or env ran since the last time this was asked (each case asks once, after it runs;
# their notes are moved aside, not removed, and what they were given and printed stays for the checks at the end)
pn=0
planted() { pn=$((pn + 1)); if [ -e "$tmp/planted.args" ]; then mv "$tmp/planted.args" "$tmp/planted.args.$pn.$RANDOM"; echo ran; else echo "never ran"; fi; }
# (The stand-in security names env bash on its #! line: these cases run a copy that names /bin/bash, so the only thing
# that could reach the planted bash is the script under test.)
mkdir -p "$tmp/bin2"; { echo '#!/bin/bash'; tail -n +2 "$tmp/bin/security"; } > "$tmp/bin2/security"; chmod +x "$tmp/bin2/security"
check "control: the first bash and env on that PATH are the planted ones" "$P/bash|$P/env" "$(PATH="$P:$PATH" command -v bash)|$(PATH="$P:$PATH" command -v env)"
stubs
out="$(cd "$tmp/nosite" && printf '%s' "$V2" | PATH="$P:$PATH" OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin2/security" STUB_DIR="$S" "$SECRET" set api-token 2>&1)"
rc=$?; t="os/darwin/secret run by its own path (its #! line), the planted bash and env first on the PATH"
check "$t: set stored it; neither planted one ran" "0||never ran" "$rc|$out|$(planted)"
out="$(cd "$tmp/nosite" && PATH="$P:$PATH" OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin2/security" STUB_DIR="$S" "$SECRET" get api-token < /dev/null)"
check "$t: get printed it; neither planted one ran" "$V2|never ran" "$out|$(planted)"
wrap_path() {  # wrap_path PATH HERE ARGS...: wrap, with PATH; TEST_SECRET_BASH, when set, is what the driver points _OFFPRINT_SECRET_BASH at
  local path="$1" here="$2"; shift 2
  out="$(SRC="$SRC" HERE="$here" OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin2/security" STUB_DIR="$S" PATH="$path" \
    /bin/bash "$tmp/driver" "$@" 2> "$tmp/err"; printf '|%s' "$?")"
  code="${out##*|}"; out="${out%|*}"; err="$(cat "$tmp/err")"
}
# (PAST_PATH, when set, is put back as the PATH once lib/site.sh has cleaned it: "." and an empty entry, which it leaves
# out, then reach the wrappers themselves, run from the planted folder.)
cat > "$tmp/driver" <<'D'
. "$SRC/lib/site.sh"; . "$SRC/lib/adapter.sh"
offprint_find_site; unset OFFPRINT_SITE
[ -z "${TEST_SECRET_BASH:-}" ] || _OFFPRINT_SECRET_BASH="$TEST_SECRET_BASH"
[ -z "${PAST_PATH+x}" ] || PATH="$PAST_PATH"
cd "$HERE" || exit 9
"$@"
D
stubs
wrap_path "$P:$PATH" "$P" offprint_secret_set api-token < <(printf '%s' "$V2"); t="lib/adapter.sh's wrappers, run from the planted folder, it first on the PATH"
check "$t: set stored it; neither planted one ran" "0|||never ran" "$code|$out|$err|$(planted)"
wrap_path "$P:$PATH" "$P" offprint_secret_get api-token; check "$t: get printed it; neither planted one ran" "0|$V2|never ran" "$code|$out|$(planted)"
# (Through lib/site.sh, which leaves "." and the empty entry out first, these two show that first layer; each twin puts
# the PATH back past it, so the wrappers meet "." or the empty entry, run from the planted folder.)
wrap_path ".:$PATH" "$P" offprint_secret_get api-token; check "$t: the same with . first on the PATH" "0|$V2|never ran" "$code|$out|$(planted)"
PAST_PATH=".:$PATH" wrap_path ".:$PATH" "$P" offprint_secret_get api-token
check "$t: the same with . first on the PATH, put back past lib/site.sh's clean-up" "0|$V2|never ran" "$code|$out|$(planted)"
wrap_path ":$PATH" "$P" offprint_secret_get api-token; check "$t: the same with an empty entry first on the PATH" "0|$V2|never ran" "$code|$out|$(planted)"
PAST_PATH=":$PATH" wrap_path ":$PATH" "$P" offprint_secret_get api-token
check "$t: the same with an empty entry first on the PATH, put back past lib/site.sh's clean-up" "0|$V2|never ran" "$code|$out|$(planted)"
# (os/darwin/secret, run by the wrapper, sources lib/site.sh itself, which leaves the "." it is handed out, saying so.)
PAST_PATH=".:$PATH" wrap_path ".:$PATH" "$P" offprint_secret_set api-token < <(printf '%s' "$V2")
check "$t: set, with . first on the PATH, put back past lib/site.sh's clean-up: stored; neither planted one ran" "0||never ran" "$code|$out|$(planted)"
PAST_PATH=".:$PATH" wrap_path ".:$PATH" "$P" offprint_secret_get api-token; check "$t: (read back the same way)" "0|$V2|never ran" "$code|$out|$(planted)"
wrap_path "$P:$PATH" "$P" offprint_secret_delete api-token; check "$t: delete removed it; neither planted one ran" "0|never ran" "$code|$(planted)"
# No /bin/bash (a test points the wrappers at a path that isn't there): they refuse, saying so, and run no other bash.
stubs
for f in get set delete; do
  TEST_SECRET_BASH="$tmp/no-such-bash" wrap_path "$P:$PATH" "$tmp/elsewhere" "offprint_secret_$f" api-token < <(printf '%s' "$V2")
  check "offprint_secret_$f, no bash at the path it runs: refused (4), one line, the Keychain unasked, no other bash run" \
    "4||offprint: there is no $tmp/no-such-bash to run os/darwin/secret with, so the secret store wasn't used (no bash found on the PATH is used in its place).|no|never ran" \
    "$code|$out|$err|$(ran)|$(planted)"
done

# --- what it starts before set reads the value: nothing on stdin ---
# set reads the value on its stdin. Each program the script starts before that (found on the PATH: dirname, mktemp, php,
# rm, cat, readlink) is a look-alike here that notes whether it ran (stdin.ran) and how much it found on its stdin, and
# whether the value was in it (stdin.read: never the bytes themselves), then runs the real one. None found anything. Run
# from inside the site folder (so the search for it runs too) and with OFFPRINT_SECURITY a link (so readlink runs).
L="$tmp/lookalikes"; mkdir -p "$L"
for t in dirname mktemp php rm cat readlink; do
  if [ "$t" = php ]; then real="$(command -v php)"; else real="$(PATH=/usr/bin:/bin command -v "$t")"; fi
  printf '#!/usr/bin/perl\nopen(my $r, ">>", "%s/stdin.ran"); print $r "%s\\n"; close $r;\nmy $in = ""; if (!-t STDIN) { local $/; $in = <STDIN>; $in = "" unless defined $in; }\nif (length $in) { open(my $h, ">>", "%s/stdin.read"); print $h "%s read " . length($in) . " bytes" . (index($in, "fake" . "-value") >= 0 ? ", the value among them" : "") . "\\n"; close $h; }\nexec { "%s" } "%s", @ARGV or die "%s: $!";\n' \
    "$tmp" "$t" "$tmp" "$t" "$real" "$real" "$real" > "$L/$t"
  chmod +x "$L/$t"
done
ln -s "$tmp/bin/security" "$tmp/security-link"
stubs
out="$(cd "$A" && printf '%s\n' "$V2" | PATH="$L:$PATH" OFFPRINT_SECURITY="$tmp/security-link" STUB_DIR="$S" /bin/bash "$SECRET" set api-token 2>&1)"
rc=$?; t="set, from inside the site folder, OFFPRINT_SECURITY a link, every program it starts a look-alike"
check "$t: stored" "0|" "$rc|$out"
# (dirname no longer runs at all: the script finds its folder, and lib/site.sh the tool's and the site's, with the shell's
# own builtins, so nothing is looked up on the PATH before lib/site.sh has made it safe.)
check "control: $t: each look-alike ran (mktemp, php, rm, readlink)" "mktemp php readlink rm" "$(sort -u "$tmp/stdin.ran" | grep -v '^cat$' | paste -sd' ' -)"
check "$t: dirname never ran" no "$(grep -qx dirname "$tmp/stdin.ran" && echo yes || echo no)"
check "$t: none of them found anything on its stdin" "" "$(cat "$tmp/stdin.read" 2>/dev/null)"
sec "$A" get api-token < /dev/null; check "$t: the value stored is the one given, whole" "0|$V2" "$code|$out"
rm -f "$tmp/stdin.ran" "$tmp/stdin.read"
out="$(printf '%s\n' "$V2" | PATH="$L:$PATH" OFFPRINT_SITE="$A" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" /bin/bash "$SECRET" set api-token 2>&1)"
rc=$?; t="set, with OFFPRINT_SITE, every program it starts a look-alike"
check "$t: stored; none of them found anything on its stdin" "0||" "$rc|$out|$(cat "$tmp/stdin.read" 2>/dev/null)"

# --- the PATH clean-up (lib/site.sh, sourced first): look-alikes WordPress could put in wp-content/ never run ---
# os/darwin/secret get and set, run from inside A's wp-content/, which holds look-alikes of bash, dirname, php, mktemp,
# git, docker, curl, readlink and env (each noting that it ran), with the PATH reaching there through . first, an empty
# entry first, relative entries, its absolute path, and a link outside the site folder; both as /bin/bash SCRIPT and by
# its own #! line. None runs, the entries left out are named in one line on stderr, and each does what it does.
W="$A/wp-content"; mkdir -p "$W"
for p in bash dirname php mktemp git docker curl readlink env; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$W/$p"; chmod +x "$W/$p"
done
ln -s "$W" "$tmp/wplink"
stubs
for spec in ".:|'.'|. first" ":|''|an empty entry first" "wp-content:../wp-content:|'wp-content' '../wp-content'|relative entries" \
  "$W:|'$W'|its absolute path" "$tmp/wplink:|'$tmp/wplink'|a link to it"; do
  pre="${spec%%|*}"; rest="${spec#*|}"; named="${rest%%|*}"; how="${rest#*|}"
  for by in bash direct; do
    if [ "$by" = bash ]; then set -- /bin/bash "$SECRET"; else set -- "$SECRET"; fi
    rm -f "$tmp/planted.ran"
    out="$(cd "$W" && printf '%s\n' "$V2" | env -u OFFPRINT_SITE PATH="$pre$PATH" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" "$@" set api-token 2> "$tmp/err"; printf '|%s' "$?")"
    code="${out##*|}"; out="${out%|*}"; err="$(cat "$tmp/err")"
    t="the PATH clean-up: set ($by), run from wp-content/ holding look-alikes, the PATH through $how"
    check "$t: none of them ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
    check "$t: stored" "0|" "$code|$out"
    check "$t: one line names what was left out of the PATH" "1|1" "$(printf '%s\n' "$err" | grep -c .)|$(printf '%s\n' "$err" | grep 'PATH entries left out' | grep -cF -- "$named")"
    rm -f "$tmp/planted.ran"
    out="$(cd "$W" && env -u OFFPRINT_SITE PATH="$pre$PATH" OFFPRINT_SECURITY="$tmp/bin/security" STUB_DIR="$S" "$@" get api-token 2> "$tmp/err" < /dev/null; printf '|%s' "$?")"
    code="${out##*|}"; out="${out%|*}"; err="$(cat "$tmp/err")"
    t="the PATH clean-up: get ($by), the same"
    check "$t: none of them ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
    check "$t: printed it" "0|$V2" "$code|$out"
    check "$t: one line names what was left out of the PATH" "1|1" "$(printf '%s\n' "$err" | grep -c .)|$(printf '%s\n' "$err" | grep 'PATH entries left out' | grep -cF -- "$named")"
  done
done
set --
rm -f "$tmp/planted.ran"

# --- where the value must never be ---
# Not in a file, even for a moment: macOS's bash 3.2 writes a here-doc or here-string to a file (in /private/var/tmp,
# and removes it at once, so no sweep of a folder afterwards would find it). So the secret script, and the three
# wrappers in lib/adapter.sh and the function they share, have none at all; and every security -i of the suite read a
# pipe.
check "os/darwin/secret has no here-doc or here-string" "" "$(grep -n '<<' "$SECRET")"
wrappers="$(grep -E '^offprint_secret_(get|set|delete)\(\)' "$SRC/lib/adapter.sh")"
check "lib/adapter.sh has the three wrappers, a line each" 3 "$(printf '%s\n' "$wrappers" | grep -c .)"
check "and none of them has a here-doc or here-string" "" "$(printf '%s\n' "$wrappers" | grep '<<')"
shared="$(awk '/^_offprint_secret\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "$SRC/lib/adapter.sh")"
check "control: lib/adapter.sh has _offprint_secret, which they share, whole (its first and last lines)" "_offprint_secret() {|}" \
  "$(printf '%s\n' "$shared" | sed -n '1p;$p' | paste -sd'|' -)"
check "and it has no here-doc or here-string either" "" "$(printf '%s\n' "$shared" | grep '<<')"
check "every security -i run in the suite read its commands from a pipe" pipe "$(sort -u "$tmp"/stubs*/i.stdin 2>&1)"
all_argv="$(cat "$tmp"/stubs*/argv 2>/dev/null)"
lacks "no value is in any of security's arguments, in any case" "fake-value" "$all_argv"
lacks "nor any value's hex" "$(hex fake-value)" "$all_argv"
hits="$(grep -rl -F -e fake-value -e zq-SECRET "$tmp" 2>/dev/null)"
check "no file under the suite's temp folder holds a value (the stand-in keeps its items as hex)" "" "$hits"
hits="$(grep -rl -F "$(hex fake-value)" "$tmp" 2>/dev/null | grep -v '/items$')"
check "nor any value's hex, but for the stand-in's items" "" "$hits"
check "nothing left in TMPDIR" "" "$(ls -A "$TMPDIR")"
left=""; for f in "$tmp"/stubs*/stub.pid "$tmp"/stubs*/child.pid; do [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null && left="$left $f"; done
for p in $(cat "$tmp"/stubs*/children 2>/dev/null); do kill -0 "$p" 2>/dev/null && left="$left $p"; done
check "no stand-in process left running" "" "$left"
exit "$fail"
