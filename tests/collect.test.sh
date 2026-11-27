#!/usr/bin/env bash
# Tests bin/collect (offprint collect): what is waiting in a site's pigeonhole spool is opened, checked, sorted and
# handed to WordPress, and nothing is lost or leaked on the way. Hermetic: a throwaway site folder, an Offprint folder
# of the case's own (OFFPRINT_HOME), and stand-ins first on the PATH or named by a seam: age (tests/fixtures/age-standin),
# docker (WordPress's answers), and security (OFFPRINT_SECURITY: the Keychain). The key is never a real one:
# AGE-SECRET-KEY-1TEST is what the stand-in age accepts. Nothing here reaches a real site, Docker or the Keychain.
# Run: bash tests/collect.test.sh. Works on macOS (bash 3.2) and Linux.
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE OFFPRINT_HOME OFFPRINT_SECURITY
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-collect-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd -P "$tmp" && pwd -P)"
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 ('$2' is not in: $3)"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 ('$2' is in the output)"; else ok "$1"; fi; }

KEY=AGE-SECRET-KEY-1TEST
Q62="age1$(printf 'q%.0s' $(seq 1 58))"
MARK=MARKER-ZX81   # in every comment's text here: it must turn up nowhere but on the pipe to WordPress

n=0
# newcase: a site folder $c with a pigeonhole block, its Offprint folder $H (empty), and the stand-ins in $S
newcase() {
  n=$((n + 1)); c="$tmp/case$n/site"; S="$tmp/case$n/stubs"; H="$tmp/case$n/ohome"
  B="$H/pigeonhole/example"; SP="$B/spool"
  mkdir -p "$c/wp-content" "$c/var" "$S/bin" "$tmp/case$n/home" "$tmp/case$n/make"; M="$tmp/case$n/make/blob"
  printf '%s\n' '{"format":1,"name":"example","public_url":"https://www.example.com","local_host":"mysite.test","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998,' \
    "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"]}}" > "$c/site.json"
  cp "$SRC/tests/fixtures/age-standin" "$S/bin/age"; chmod +x "$S/bin/age"
  # php: the real one, but for the switches check_fails.N and sort_fails.N: the Nth check, or sort, of an opened
  # submission fails as php itself would (a crash), saying nothing.
  REAL_PHP="$(command -v php)"
  cat > "$S/bin/php" <<STUB
#!/usr/bin/env bash
case "\${2:-}" in
  check|sort)
    case "\$1" in */lib/pigeonhole.php)
      i=\$(( \$(cat "\$STUB_DIR/\$2.count" 2>/dev/null || echo 0) + 1 )); echo "\$i" > "\$STUB_DIR/\$2.count"
      [ ! -f "\$STUB_DIR/\${2}_fails.\$i" ] || { cat > /dev/null; exit 255; } ;;
    esac ;;
esac
exec "$REAL_PHP" "\$@"
STUB
  chmod +x "$S/bin/php"
  # docker: it notes each call. Not compose: the questions lib/site.sh asks about the project (nothing there). compose
  # ps: WordPress and the database are running (wp_down: nothing is). The import: what it is given on standard input is
  # kept (import.N), and it answers "imported N hold" or "imported N spam" as it was sorted; or, when the case has
  # written one, the file answer (every import) or answer.N (the Nth).
  cat > "$S/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.calls"
[ "${1:-}" = compose ] || exit 0
case "$*" in
  *" ps "*) [ -f "$STUB_DIR/wp_down" ] || printf 'wordpress\ndb\n'; exit 0 ;;
  *" wp offprint import-submission"*)
    i=$(( $(cat "$STUB_DIR/import.count" 2>/dev/null || echo 0) + 1 )); echo "$i" > "$STUB_DIR/import.count"
    cat > "$STUB_DIR/import.$i"
    if [ -f "$STUB_DIR/answer.$i" ]; then cat "$STUB_DIR/answer.$i"
    elif [ -f "$STUB_DIR/answer" ]; then cat "$STUB_DIR/answer"
    else case "$*" in *--sorted=spam*) echo "imported $i spam" ;; *) echo "imported $i hold" ;; esac; fi
    exit 0 ;;
esac
echo "unexpected docker call: $*" >&2; exit 99
STUB
  # security: the Keychain. It holds one item, the site's daily key (the file key in the stubs folder). secret_missing:
  # no such item. secret_locked: the Keychain is locked.
  cat > "$S/security" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/security.calls"
[ ! -f "$STUB_DIR/secret_locked" ] || { echo "security: unable to obtain authorization for this operation." >&2; exit 152; }
[ ! -f "$STUB_DIR/secret_missing" ] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; }
[ "$*" = "find-generic-password -s offprint -a example/pigeonhole-daily -w" ] || { echo "security (stand-in): unexpected: $*" >&2; exit 2; }
cat "$STUB_DIR/key"
STUB
  chmod +x "$S/bin/docker" "$S/security"
  printf '%s\n' "$KEY" > "$S/key"
}
# seal: what the stand-in age writes for the plaintext on standard input
seal() { echo "age-encryption.org/v1"; echo "-> stand-in"; echo "--- run 1"; cat; }
# plaintext KIND [HP] [ELAPSED] [TEXT]: an opened submission, as the browser pads it (8192 bytes)
BN=0
plaintext() {
  BN=$((BN + 1))
  BN="$BN" php -r 'require $argv[1];
    $kind = $argv[2];
    $f = ["post_id" => 4, "parent" => 0, "author" => "Ada", "email" => "ada@example.com", "url" => "", "content" => $argv[5], "hp" => $argv[3], "elapsed" => (int) $argv[4]];
    $d = ["v" => 1, "kind" => $kind, "id" => sprintf("%032x", (int) getenv("BN")), "ts" => time() - 60, "page" => "/hello/", "fields" => $kind === "comment" ? $f : []];
    echo str_pad($kind === "form" ? json_encode($d) : offprint_pigeonhole_line($d), 8192, " ");' \
    "$SRC/lib/pigeonhole.php" "$1" "${2:-}" "${3:-42}" "${4:-$MARK a comment}"
}
# drop: the sealed file just written as $M, into the spool under the name its bytes give it; sets blob (that name).
# (Not at the end of a pipe: blob must be set in this shell.)
drop() {
  mkdir -p "$SP"; chmod 700 "$H/pigeonhole" "$B" "$SP" 2>/dev/null
  blob="$(php -r 'echo hash_file("sha256", $argv[1]);' "$tmp/case$n/make/blob").age"
  mv "$tmp/case$n/make/blob" "$SP/$blob"
}
# comment [HP] [ELAPSED] [TEXT]: a good comment, sealed, into the spool
comment() { BN=$((BN + 1)); plaintext comment "${1:-}" "${2:-42}" "${3:-$MARK a comment $BN}" | seal > "$M"; drop; }
# collect [ARGS...]: offprint collect for the site; sets out, code
collect() {
  out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" \
    HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/offprint" collect "$@" 2>&1 < /dev/null)"; code=$?
}
count() { ls "$1" 2>/dev/null | grep -c . ; }
status() { cat "$c/var/pigeonhole.json" 2>/dev/null | sed 's/"collected_at":[0-9]*,//'; }
# clean NAME: nothing of the key or of a comment's text is anywhere it must not be, and the run left nothing behind
clean() {
  check "$1: the key is in no file (but the stand-ins, which know it)" "" "$(grep -rl "$KEY" "$tmp/case$n" "$TMPDIR" 2>/dev/null | grep -v '/stubs/')"
  check "$1: the key is in no program's arguments" "" "$(grep -l "$KEY" "$S/docker.calls" "$S/age.calls" "$S/security.calls" 2>/dev/null)"
  check "$1: a comment's text is in no file but what WordPress was handed and the sealed files" "" \
    "$(grep -rl "$MARK" "$tmp/case$n" "$TMPDIR" 2>/dev/null | grep -v '/stubs/import\.[0-9]*$' | grep -v '\.age$')"
  check "$1: ... and in no program's arguments" "" "$(grep -l "$MARK" "$S/docker.calls" "$S/age.calls" "$S/security.calls" 2>/dev/null)"
  lacks "$1: ... and not in what was printed" "$MARK" "$out"
  check "$1: the lock is gone" "" "$(ls -d "$c/var/publish.lock" 2>/dev/null)"
  check "$1: no private folder is left in TMPDIR" "" "$(ls "$TMPDIR" 2>/dev/null)"
}

# ---- nothing to do -----------------------------------------------------------------------------------------------
newcase; t="a site with no pigeonhole block"
printf '%s\n' '{"format":1,"name":"example","public_url":"https://www.example.com","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998}' > "$c/site.json"
collect
check "$t: exits 1" 1 "$code"
check "$t: says so" 'problem: site.json has no "pigeonhole" block, so this site takes no comments and there is nothing to collect.' "$out"
check "$t: makes no folder" "" "$(ls "$H" 2>/dev/null)"
check "$t: asks nothing of Docker or the Keychain" "" "$(cat "$S/docker.calls" "$S/security.calls" 2>/dev/null)"

newcase; collect; t="an empty spool"
check "$t: exits 0" 0 "$code"
check "$t: says so" "ok: nothing is waiting in the pigeonhole's spool." "$out"
check "$t: the three folders are made" "done rejected spool " "$(ls "$B" | tr '\n' ' ')"
for d in "$B" "$B/spool" "$B/done" "$B/rejected"; do
  check "$t: ${d#$H/} is the owner's alone" "" "$(find "$d" -maxdepth 0 \( -perm -040 -o -perm -004 -o -perm -020 -o -perm -002 -o -perm -010 -o -perm -001 \) -print)"
done
check "$t: the Keychain is not asked" "" "$(cat "$S/security.calls" 2>/dev/null)"
check "$t: WordPress is not asked" "" "$(grep -c 'import-submission\| ps ' "$S/docker.calls" 2>/dev/null | grep -v '^0$')"
check "$t: the counts are all 0" '{"imported":0,"spam":0,"already":0,"canaries":0,"rejected":0,"damaged":0,"failed":0,"waiting":0}' "$(status)"
clean "$t"

newcase; collect extra; t="an argument"
check "$t: exits 2" 2 "$code"
check "$t: the usage line" "usage: offprint collect" "$out"

# ---- a comment, to WordPress ---------------------------------------------------------------------------------------
newcase; comment; first="$blob"; collect; t="one good comment"
check "$t: exits 0" 0 "$code"
check "$t: says where it is" "ok: 1 comment is waiting for you in WordPress's moderation queue." "$out"
check "$t: the spool is empty" 0 "$(count "$SP")"
check "$t: the file is in done" "$first" "$(ls "$B/done")"
check "$t: WordPress was handed one line, the checked submission" 1 "$(wc -l < "$S/import.1" | tr -d ' ')"
has "$t: ... which is the comment" "\"content\":\"$MARK a comment" "$(cat "$S/import.1")"
has "$t: ... starting as a checked comment does" '{"v":1,"kind":"comment","id":"' "$(cut -c1-30 "$S/import.1")"
has "$t: the import is told it was held" " wp offprint import-submission --sorted=hold" "$(cat "$S/docker.calls")"
# (the site's plugins and theme are loaded: a post of a type one of them registers must take comments)
lacks "$t: ... and is not told to leave out the site's plugins or theme" "--skip-" "$(grep import-submission "$S/docker.calls")"
has "$t: ... as the web server's user, with no terminal" "exec -T -u www-data wordpress wp " "$(grep import-submission "$S/docker.calls")"
has "$t: age is given the key on a pipe" "-d -i - $SP/$first (a key of ${#KEY} characters on standard input)" "$(cat "$S/age.calls")"
check "$t: ... and not in its environment" no "$(cat "$S/age.env")"
check "$t: the counts" '{"imported":1,"spam":0,"already":0,"canaries":0,"rejected":0,"damaged":0,"failed":0,"waiting":0}' "$(status)"
has "$t: the counts carry a time" '"collected_at":1' "$(cat "$c/var/pigeonhole.json")"
clean "$t"

newcase; comment; comment; comment; collect; t="three good comments"
check "$t: exits 0" 0 "$code"
check "$t: says how many" "ok: 3 comments are waiting for you in WordPress's moderation queue." "$out"
check "$t: three imports" 3 "$(cat "$S/import.count")"
check "$t: all in done" 3 "$(count "$B/done")"
clean "$t"

newcase; comment "https://www.example.com/"; comment "" 1; comment; collect; t="two the sorter calls spam, one it holds"
check "$t: exits 0" 0 "$code"
check "$t: says both" "ok: 1 comment is waiting for you in WordPress's moderation queue. 2 went to WordPress's spam list." "$out"
check "$t: two imports sorted as spam" 2 "$(grep -c -- '--sorted=spam' "$S/docker.calls")"
check "$t: one held" 1 "$(grep -c -- '--sorted=hold' "$S/docker.calls")"
check "$t: the counts" '{"imported":1,"spam":2,"already":0,"canaries":0,"rejected":0,"damaged":0,"failed":0,"waiting":0}' "$(status)"
clean "$t"

newcase; plaintext canary | seal > "$M"; drop; collect; t="a canary"
check "$t: exits 0" 0 "$code"
check "$t: says so" "ok: 1 test submission arrived." "$out"
check "$t: it is in done" 1 "$(count "$B/done")"
check "$t: WordPress is not handed it" "" "$(grep import-submission "$S/docker.calls")"
clean "$t"

newcase; comment; echo "already 7" > "$S/answer"; collect; t="a comment WordPress has already"
check "$t: exits 0" 0 "$code"
check "$t: says so" "ok: 1 was a comment already." "$out"
check "$t: it is in done" 1 "$(count "$B/done")"
check "$t: the counts" '{"imported":0,"spam":0,"already":1,"canaries":0,"rejected":0,"damaged":0,"failed":0,"waiting":0}' "$(status)"

newcase; comment; printf 'Warning: something a plugin said\nDeprecated: and more\nimported 12 hold\r\n' > "$S/answer"; collect; t="WordPress says other things first"
check "$t: exits 0: its last line is its answer" 0 "$code"
check "$t: it is in done" 1 "$(count "$B/done")"

# ---- refused: kept, with why ---------------------------------------------------------------------------------------
newcase; comment; kept="$blob"; echo "AGE-SECRET-KEY-1WRONG" > "$S/key"; collect; t="a comment the daily key doesn't open"
check "$t: exits 0" 0 "$code"
check "$t: says it is kept, and where" "ok: 1 was refused and is kept, each with its reason beside it, in $B/rejected." "$out"
check "$t: it is in rejected, beside its reason" "$kept $kept.why " "$(ls "$B/rejected" | tr '\n' ' ')"
check "$t: the reason" "it does not open with this site's daily key" "$(cat "$B/rejected/$kept.why")"
check "$t: WordPress is not handed it" "" "$(grep import-submission "$S/docker.calls")"
check "$t: the counts" '{"imported":0,"spam":0,"already":0,"canaries":0,"rejected":1,"damaged":0,"failed":0,"waiting":0}' "$(status)"

newcase; plaintext form | seal > "$M"; drop; kept="$blob"; comment; collect; t="a submission of a kind this Offprint doesn't know, then a good one"
check "$t: exits 0" 0 "$code"
check "$t: says both" "ok: 1 comment is waiting for you in WordPress's moderation queue. 1 was refused and is kept, each with its reason beside it, in $B/rejected." "$out"
check "$t: the reason is the check's" "its kind is not one this Offprint knows" "$(cat "$B/rejected/$kept.why")"
check "$t: WordPress is handed only the good one" 1 "$(cat "$S/import.count")"
clean "$t"

newcase; printf 'junk that is not a submission at all, %s\n' "$MARK" | seal > "$M"; drop; kept="$blob"; collect; t="something that opens but is not a submission"
check "$t: exits 0" 0 "$code"
check "$t: the reason" "it is not the size a submission has" "$(cat "$B/rejected/$kept.why")"
lacks "$t: the reason repeats nothing that was sent" "$MARK" "$(cat "$B/rejected/$kept.why")$out"

newcase; comment; kept="$blob"; echo "refused no such public post, or its comments are closed" > "$S/answer"; collect; t="a comment WordPress refuses"
check "$t: exits 0" 0 "$code"
check "$t: it is in rejected" "$kept $kept.why " "$(ls "$B/rejected" | tr '\n' ' ')"
check "$t: the reason is WordPress's" "wordpress refused it: no such public post, or its comments are closed" "$(cat "$B/rejected/$kept.why")"
clean "$t"

# ---- WordPress doesn't answer as the import does: nothing is lost, and nothing it says is believed --------------------
# (WordPress is untrusted. Its answer is one line of one of three shapes, or it is no answer.)
answer_case() {  # NAME, the answer file's bytes (printf format)
  newcase; comment; comment; printf "$2" > "$S/answer"; collect; t="WordPress answers $1"
  check "$t: exits 1" 1 "$code"
  has "$t: says it stopped, and that nothing is lost" "It stopped there: WordPress didn't answer as the import does, twice running" "$out"
  has "$t: ... and how many are still waiting" "2 submissions are still in the spool, and nothing is lost: collect again." "$out"
  check "$t: both are still in the spool" 2 "$(count "$SP")"
  check "$t: nothing is in done or rejected" "0 0" "$(count "$B/done") $(count "$B/rejected")"
  check "$t: both were tried" 2 "$(cat "$S/import.count")"
  check "$t: the counts" '{"imported":0,"spam":0,"already":0,"canaries":0,"rejected":0,"damaged":0,"failed":2,"waiting":2}' "$(status)"
  lacks "$t: what WordPress said is not repeated" "OWNED" "$out"
  clean "$t"
}
answer_case "nothing" ''
answer_case "a PHP error" 'PHP Fatal error:  Uncaught Error OWNED in /var/www/html/wp-content/x.php:1\n'
answer_case "that it imported, and more" 'imported 3 hold OWNED\n'
answer_case "that it imported into a list there isn't" 'imported 3 approved\n'
answer_case "a refusal with a script in it" 'refused <script>OWNED</script>\n'
answer_case "a refusal with an escape sequence in it" 'refused \033[2J OWNED\n'
answer_case "a refusal that is too long" "refused $(printf 'a%.0s' $(seq 1 121))\n"
answer_case "already, with no number" 'already OWNED\n'
answer_case "the right line, then another" 'imported 3 hold\nOWNED\n'

newcase; comment; comment; comment; comment; echo junk > "$S/answer"; collect; t="WordPress answers nothing of use, four waiting"
check "$t: exits 1" 1 "$code"
check "$t: it stops after two: WordPress is the trouble, not a submission" 2 "$(cat "$S/import.count")"
check "$t: all four are still in the spool" 4 "$(count "$SP")"
has "$t: says how many" "4 submissions are still in the spool, and nothing is lost: collect again." "$out"

# One submission WordPress can't take (a crash in a hook of its own, say) must not hold up those behind it: on this
# run, or on any later one, where it would be met first again.
newcase; comment; comment; comment; echo "junk" > "$S/answer.1"; collect; t="WordPress fails on the first of three, and takes the rest"
check "$t: exits 1" 1 "$code"
check "$t: says what was taken, and what was not" "problem: 2 comments are waiting for you in WordPress's moderation queue. 1 submission couldn't be taken this time and is still in the spool; nothing is lost: collect again. One that is left every time can be moved out of $SP by hand." "$out"
check "$t: one is still in the spool" 1 "$(count "$SP")"
check "$t: two are in done" 2 "$(count "$B/done")"
check "$t: the counts" '{"imported":2,"spam":0,"already":0,"canaries":0,"rejected":0,"damaged":0,"failed":1,"waiting":1}' "$(status)"
clean "$t"
rm -f "$S/answer.1"; collect
check "$t: collect again: exits 0" 0 "$code"
check "$t: ... and takes the one that was left" "ok: 1 comment is waiting for you in WordPress's moderation queue." "$out"
check "$t: ... the spool is empty" 0 "$(count "$SP")"

newcase; comment; comment; comment; echo junk > "$S/answer.1"; echo junk > "$S/answer.3"; collect; t="WordPress fails on the first and the third, not in a row"
check "$t: exits 1" 1 "$code"
check "$t: all three were tried" 3 "$(cat "$S/import.count")"
check "$t: the second was taken" 1 "$(count "$B/done")"

# The same for the Mac's own two steps: a file the check or the sorter fails on is left, and the rest go on.
newcase; comment; comment; comment; touch "$S/sort_fails.1"; collect; t="the sorter fails on the first of three"
check "$t: exits 1" 1 "$code"
has "$t: the other two are taken" "2 comments are waiting for you in WordPress's moderation queue." "$out"
has "$t: the one is left, and said" "1 submission couldn't be taken this time and is still in the spool" "$out"
check "$t: one is still in the spool" 1 "$(count "$SP")"
check "$t: WordPress was handed two" 2 "$(cat "$S/import.count")"
clean "$t"

newcase; comment; comment; comment; touch "$S/check_fails.2"; collect; t="the check fails on the second of three"
check "$t: exits 1" 1 "$code"
has "$t: the other two are taken" "2 comments are waiting for you in WordPress's moderation queue." "$out"
check "$t: one is still in the spool" 1 "$(count "$SP")"
check "$t: nothing is in rejected: a check that failed is no reason" 0 "$(count "$B/rejected")"
clean "$t"

# ---- what is in the spool is not what was sent: left, and said ---------------------------------------------------------
newcase; comment; good="$blob"
plaintext comment | seal > "$SP/not-a-name.age"
plaintext comment | seal > "$SP/$(printf 'a%.0s' $(seq 1 64)).age"
plaintext comment | seal > "$SP/$(printf 'B%.0s' $(seq 1 64)).age"
ln -s "$SP/$good" "$SP/$(printf 'c%.0s' $(seq 1 64)).age"
mkdir "$SP/$(printf 'd%.0s' $(seq 1 64)).age"
collect; t="five things in the spool that are not submissions as sent, and a good comment"
check "$t: exits 1" 1 "$code"
has "$t: the good one is taken" "1 comment is waiting for you in WordPress's moderation queue." "$out"
has "$t: the others are counted, and left" "5 things in the spool are not submissions as they were sent (a name, size or bytes are wrong) and were left in $SP." "$out"
check "$t: five are still in the spool" 5 "$(count "$SP")"
check "$t: only the good one was opened" 1 "$(grep -c -- '^-d ' "$S/age.calls")"
check "$t: the counts" '{"imported":1,"spam":0,"already":0,"canaries":0,"rejected":0,"damaged":5,"failed":0,"waiting":5}' "$(status)"

newcase; mkdir -p "$SP"; chmod 700 "$H/pigeonhole" "$B" "$SP"
{ echo "age-encryption.org/v1"; head -c 20000 /dev/zero | tr '\0' 'a'; } > "$tmp/case$n/make/big"
big="$(php -r 'echo hash_file("sha256", $argv[1]);' "$tmp/case$n/make/big").age"; mv "$tmp/case$n/make/big" "$SP/$big"
collect; t="a file larger than any submission, under the right name"
check "$t: exits 1" 1 "$code"
has "$t: it is counted, and left" "1 thing in the spool is not a submission as it was sent" "$out"
check "$t: it is not opened" "" "$(cat "$S/age.calls" 2>/dev/null)"

# ---- what the run needs, and doesn't have ----------------------------------------------------------------------------
needs_case() {  # NAME, the message; the case is set up and collect has run
  check "$1: exits 1" 1 "$code"
  check "$1: says so" "$2" "$out"
  check "$1: the comment is still in the spool" 1 "$(count "$SP")"
  check "$1: WordPress is not handed anything" "" "$(grep import-submission "$S/docker.calls" 2>/dev/null)"
  check "$1: the lock is gone" "" "$(ls -d "$c/var/publish.lock" 2>/dev/null)"
}
newcase; comment; touch "$S/secret_missing"; collect
needs_case "no daily key in the Keychain" "problem: this site's daily key isn't in the login Keychain (the secret pigeonhole-daily), so nothing can be opened. Nothing was collected."
newcase; comment; touch "$S/secret_locked"; collect
needs_case "the Keychain is locked" "problem: the login Keychain is locked, so the daily key couldn't be read; unlock it, then collect again."
newcase; comment; echo "hunter2 $MARK" > "$S/key"; collect
needs_case "the Keychain holds something that is no key" "problem: what the login Keychain holds as this site's daily key (the secret pigeonhole-daily) is not an age private key. Nothing was collected."
lacks "the Keychain holds something that is no key: what it holds is not shown" "hunter2" "$out"
newcase; comment; touch "$S/wp_down"; collect
needs_case "WordPress isn't running" "problem: WordPress isn't running (offprint compose up -d), so nothing was collected."
check "WordPress isn't running: the Keychain is not asked" "" "$(cat "$S/security.calls" 2>/dev/null)"
newcase; comment; rm "$S/bin/age"   # a PATH with php on it (the stand-in, which runs the real one), and no age
out="$(cd "$tmp/case$n" && PATH="$S/bin:/usr/bin:/bin:/usr/sbin:/sbin" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/offprint" collect 2>&1 < /dev/null)"; code=$?
if [ -x /usr/bin/age ] || [ -x /bin/age ] || [ -x /usr/sbin/age ] || [ -x /sbin/age ]; then
  echo "skip  no age: this machine has an age in the system's own folders"
else
  needs_case "no age" "problem: age isn't installed; install it (brew install age) and collect again."
fi

newcase; comment; mkdir "$c/var/publish.lock"; echo 1 > "$c/var/publish.lock/pid"; collect; t="a publish holds the lock"
check "$t: exits 1" 1 "$code"
check "$t: says so" "problem: a publish is running, or left its lock (var/publish.lock); wait for it, then collect again." "$out"
check "$t: the lock is left as it was" 1 "$(cat "$c/var/publish.lock/pid")"
check "$t: the comment is still in the spool" 1 "$(count "$SP")"
check "$t: nothing was asked of the Keychain" "" "$(cat "$S/security.calls" 2>/dev/null)"

# ---- the folders are the owner's, and outside the site ------------------------------------------------------------------
newcase; H="$c/var/ohome"; B="$H/pigeonhole/example"; SP="$B/spool"; collect; t="OFFPRINT_HOME inside the site folder"
check "$t: exits 1" 1 "$code"
has "$t: says so" "is inside the site folder, which WordPress can read and write; set OFFPRINT_HOME to a folder outside it." "$out"
check "$t: makes nothing there" "" "$(ls "$c/var" 2>/dev/null)"

newcase; mkdir -p "$H/pigeonhole" "$c/wp-content/trap"; ln -s "$c/wp-content/trap" "$B"; collect; t="the site's pigeonhole folder is a link into wp-content"
check "$t: exits 1" 1 "$code"
has "$t: says so" "problem: " "$out"
check "$t: nothing is made in wp-content" "" "$(ls "$c/wp-content/trap")"

newcase; comment; ln -s "$c/wp-content" "$B/done"; collect; t="done is a link"
check "$t: exits 1" 1 "$code"
has "$t: says so" "$B/done is not a folder (a link, or a file); move it away, then collect again." "$out"
check "$t: the comment is still in the spool" 1 "$(count "$SP")"

newcase; comment; chmod 755 "$SP"; collect; t="a spool others can read"
check "$t: exits 1" 1 "$code"
has "$t: says so" "$SP must be a folder of yours that nobody else can read (chmod 700), and it isn't." "$out"

newcase; t="OFFPRINT_HOME that is not a whole path"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="relative/home" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/offprint" collect 2>&1 < /dev/null)"; code=$?
check "$t: exits 1" 1 "$code"
check "$t: says so" "problem: OFFPRINT_HOME must be a whole path, starting with a slash." "$out"

newcase; t="no OFFPRINT_HOME: the folder is in HOME's Library"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash "$SRC/bin/offprint" collect 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
check "$t: the spool is there" spool "$(ls "$tmp/case$n/home/Library/Application Support/Offprint/pigeonhole/example" 2>/dev/null | grep spool)"

# ---- what was taken long ago is removed -------------------------------------------------------------------------------
newcase; mkdir -p "$B/done" "$B/rejected" "$SP"; chmod 700 "$H/pigeonhole" "$B" "$B/done" "$B/rejected" "$SP"
old="$(printf 'e%.0s' $(seq 1 64)).age"; new="$(printf 'f%.0s' $(seq 1 64)).age"
echo x > "$B/done/$old"; echo x > "$B/done/$new"; echo x > "$B/rejected/$old"
touch -t 202001010000 "$B/done/$old" "$B/rejected/$old"
collect; t="a file in done from long ago"
check "$t: exits 0" 0 "$code"
check "$t: it is removed, and a new one kept" "$new" "$(ls "$B/done")"
check "$t: what was refused long ago is kept: that is the owner's to remove" "$old" "$(ls "$B/rejected")"

# ---- the key and the comments stay out of sight -----------------------------------------------------------------------
newcase; comment; t="traced with bash -x"
out="$(cd "$tmp/case$n" && PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" /bin/bash -x "$SRC/bin/collect" 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
lacks "$t: the key is not in the trace" "$KEY" "$out"
lacks "$t: a comment's text is not in the trace" "$MARK" "$out"
has "$t: it still says what happened" "ok: 1 comment is waiting for you" "$out"

newcase; comment; t="tracing inherited through SHELLOPTS"
out="$(cd "$tmp/case$n" && env PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" SHELLOPTS=xtrace /bin/bash "$SRC/bin/collect" 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
lacks "$t: the key is not in the trace" "$KEY" "$out"
lacks "$t: a comment's text is not in the trace" "$MARK" "$out"

newcase; comment; t="identity and checked exported in the owner's shell, and allexport inherited"
out="$(cd "$tmp/case$n" && export identity=old checked=old && env PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" SHELLOPTS=allexport /bin/bash "$SRC/bin/collect" 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
check "$t: the key is not in age's environment" no "$(cat "$S/age.env")"
newcase; comment; t="the opened comment is in no program's environment"
# a docker that notes whether the comment's text is in its environment when it is handed the import
sed '2i\
case "$*" in *import-submission*) if env | grep -q MARKER-ZX81; then echo yes > "$STUB_DIR/docker.env"; else echo no > "$STUB_DIR/docker.env"; fi ;; esac
' "$S/bin/docker" > "$S/bin/docker.new" && mv "$S/bin/docker.new" "$S/bin/docker" && chmod +x "$S/bin/docker"
out="$(cd "$tmp/case$n" && export identity=old checked=old && env PATH="$S/bin:$PATH" STUB_DIR="$S" OFFPRINT_SITE="$c" OFFPRINT_HOME="$H" OFFPRINT_SECURITY="$S/security" HOME="$tmp/case$n/home" SHELLOPTS=allexport /bin/bash "$SRC/bin/collect" 2>&1 < /dev/null)"; code=$?
check "$t: exits 0" 0 "$code"
check "$t: not in docker's, even with checked exported and allexport on" no "$(cat "$S/docker.env" 2>/dev/null)"

# ---- the command is wired in --------------------------------------------------------------------------------------------
has "offprint help lists collect" "  offprint collect " "$(/bin/bash "$SRC/bin/offprint" help)"
check "bin/collect starts #!/bin/bash" "#!/bin/bash" "$(head -n 1 "$SRC/bin/collect")"

[ "$fail" -eq 0 ]
