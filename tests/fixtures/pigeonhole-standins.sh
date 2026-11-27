# Stand-ins for what a pigeonhole's fetch and keys run, for the hermetic suites (tests/fetch.test.sh,
# tests/pigeonhole.test.sh): sourced, then  ph_standins DIR  writes them into DIR/bin (to go first on the PATH) and
# DIR/security (for OFFPRINT_SECURITY). Each notes how it was called in DIR (STUB_DIR, in its environment), and does
# what the case's switches (files in DIR) ask. None of them reaches a network, a real agent or the Keychain.
# tests/rehearsal.sh runs the real ssh, ssh-agent, ssh-add and age the same
# ways: keep these true to what those show.
#
#   security   a Keychain in DIR/keychain: one file a secret, named as its account is after "SITE/" (so one site a case). find, delete and
#              "-i" (os/darwin/secret's set). secret_locked: it is locked (152).
#   ssh-agent  -D -a SOCK: makes SOCK (a plain file here), notes its pid (agent.pid), and stays until it is killed,
#              when it removes SOCK and what was loaded. agent_fails: exits at once, making nothing.
#   ssh-add    -q -t 900 -: takes the key on standard input when it is DIR/pullkey.pem's bytes exactly, noting that
#              beside the socket it was given (SOCK.loaded). sshadd_fails: refuses.
#   ssh        -F CONFIG -n -T offprint-store WORDS, and no other call. It keeps a copy of the config and known_hosts
#              files it was given (seen.config, seen.known_hosts), and answers as the store's pull command does
#              (pigeonhole/server/pull.js), from the folder DIR/remote, when the agent its config names holds the key;
#              "Permission denied" otherwise. ssh_says: fails as ssh itself does (255) with that file's words.
#              remote_says: the far command fails (4) with that file's words. ssh_hangs: it never answers (30
#              seconds). ssh_floods: it fails with 400 KB on standard error. list_says: answers list with that
#              file. get_fails, delete_fails: every get, or delete, fails. get_fails.NAME: that one. get_as.NAME:
#              answers get NAME with that file's bytes.
#   age-keygen  prints a key as the real one does (DIR/agekey.out when the case wrote one); -y reads a private key
#              on standard input and prints its public half (DIR/agekey.pub, when it is DIR/keychain's daily key).
#   osascript  notes its arguments (osascript.calls).
ph_standins() {
  mkdir -p "$1/bin" "$1/keychain" "$1/remote"
  cat > "$1/security" <<'STUB'
#!/bin/bash
: "${STUB_DIR:?}"
echo "$*" >> "$STUB_DIR/security.calls"
[ ! -f "$STUB_DIR/secret_locked" ] || { echo "security: unable to obtain authorization for this operation." >&2; exit 152; }
item() { if [[ "$1" =~ ^[a-z][a-z0-9-]*/[a-z][a-z0-9-]*$ ]]; then printf '%s' "$STUB_DIR/keychain/${1#*/}"; else echo "security (stand-in): unexpected account $1" >&2; exit 2; fi; }
case "$*" in
  "find-generic-password -s offprint -a "*" -w")
    f="$(item "$5")" || exit 2
    [ -f "$f" ] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; }
    cat "$f"; echo ;;
  "delete-generic-password -s offprint -a "*)
    f="$(item "$5")" || exit 2
    [ -f "$f" ] || exit 44
    rm -f "$f" ;;
  -i)
    IFS= read -r line || true
    set -- $line
    [ "$1 $2 $3 $4 $5 $7" = "add-generic-password -U -s offprint -a -X" ] && [ $# -eq 8 ] || { echo "security (stand-in): unexpected line" >&2; exit 2; }
    f="$(item "$6")" || exit 2
    [ ! -f "$STUB_DIR/set_fails" ] || exit 1
    printf '%s' "$8" | sed 's/../\\x&/g' | { read -r hex; printf "$hex"; } > "$f" ;;
  *) echo "security (stand-in): unexpected: $*" >&2; exit 2 ;;
esac
STUB
  cat > "$1/bin/ssh-agent" <<'STUB'
#!/bin/bash
: "${STUB_DIR:?}"
echo "$*" >> "$STUB_DIR/agent.calls"
[ "${1:-}" = -D ] && [ "${2:-}" = -a ] && [ $# -eq 3 ] || { echo "ssh-agent (stand-in): unexpected: $*" >&2; exit 99; }
[ ! -f "$STUB_DIR/agent_fails" ] || exit 1
echo "$$" > "$STUB_DIR/agent.pid"
: > "$3"
trap 'rm -f "$3" "$3.loaded"; echo gone >> "$STUB_DIR/agent.ended"; exit 0' TERM INT
while :; do sleep 0.1; done
STUB
  cat > "$1/bin/ssh-add" <<'STUB'
#!/bin/bash
: "${STUB_DIR:?}"
cat > "$STUB_DIR/sshadd.in"
echo "$* | sock ${SSH_AUTH_SOCK:-none} | askpass ${SSH_ASKPASS_REQUIRE:-unset} | $(wc -c < "$STUB_DIR/sshadd.in" | tr -d ' ') bytes on standard input" >> "$STUB_DIR/sshadd.calls"
same=no; cmp -s "$STUB_DIR/sshadd.in" "$STUB_DIR/pullkey.pem" && same=yes
rm -f "$STUB_DIR/sshadd.in"
[ "$*" = "-q -t 900 -" ] || { echo "ssh-add (stand-in): unexpected: $*" >&2; exit 99; }
[ ! -f "$STUB_DIR/sshadd_fails" ] || { echo "Error loading key \"(stdin)\": error in libcrypto" >&2; exit 1; }
[ "$same" = yes ] || { echo "Error loading key \"(stdin)\": invalid format" >&2; exit 1; }
[ -e "${SSH_AUTH_SOCK:-}" ] || { echo "Could not open a connection to your authentication agent." >&2; exit 2; }
: > "$SSH_AUTH_SOCK.loaded"
STUB
  cat > "$1/bin/ssh" <<'STUB'
#!/bin/bash
: "${STUB_DIR:?}"
echo "$*" >> "$STUB_DIR/ssh.calls"
if [ -n "${SSH_AUTH_SOCK:-}" ]; then echo set >> "$STUB_DIR/ssh.env"; else echo unset >> "$STUB_DIR/ssh.env"; fi
[ "${1:-}" = -F ] && [ "${3:-}" = -n ] && [ "${4:-}" = -T ] && [ "${5:-}" = offprint-store ] && [ $# -eq 6 ] \
  || { echo "ssh (stand-in): unexpected: $*" >&2; exit 99; }
config="$2"; words="$6"
cp "$config" "$STUB_DIR/seen.config" 2>/dev/null || { echo "ssh (stand-in): no config file at $config" >&2; exit 99; }
known="$(sed -n 's/^  UserKnownHostsFile //p' "$config")"; sock="$(sed -n 's/^  IdentityAgent //p' "$config")"
cp "$known" "$STUB_DIR/seen.known_hosts" 2>/dev/null
if [ -f "$STUB_DIR/ssh_says" ]; then cat "$STUB_DIR/ssh_says" >&2; exit 255; fi
if [ -f "$STUB_DIR/ssh_hangs" ]; then sleep 30; exit 0; fi
if [ -f "$STUB_DIR/ssh_floods" ]; then head -c 400000 /dev/zero | tr '\0' 'x' >&2; exit 255; fi
if [ -f "$STUB_DIR/remote_says" ] && [ -e "$sock.loaded" ]; then cat "$STUB_DIR/remote_says" >&2; exit 4; fi
[ -e "$sock.loaded" ] || { echo "ph-example@10.0.0.5: Permission denied (publickey)." >&2; exit 255; }
R="$STUB_DIR/remote"
case "$words" in
  list)
    if [ -f "$STUB_DIR/list_says" ]; then cat "$STUB_DIR/list_says"; else ls "$R" | grep -E '^[0-9a-f]{64}\.age$'; fi; exit 0 ;;
  "get "*)
    name="${words#get }"
    if [ -f "$STUB_DIR/get_fails" ] || [ -f "$STUB_DIR/get_fails.$name" ]; then echo "Connection to 10.0.0.5 closed by remote host." >&2; exit 255; fi
    if [ -f "$STUB_DIR/get_as.$name" ]; then cat "$STUB_DIR/get_as.$name"; exit 0; fi
    [ -f "$R/$name" ] || { echo gone >&2; exit 3; }
    cat "$R/$name"; exit 0 ;;
  "delete "*)
    name="${words#delete }"
    [ ! -f "$STUB_DIR/delete_fails" ] || { echo "Connection to 10.0.0.5 closed by remote host." >&2; exit 255; }
    rm -f "$R/$name"; exit 0 ;;
esac
echo refused >&2; exit 2
STUB
  cat > "$1/bin/age-keygen" <<'STUB'
#!/bin/bash
: "${STUB_DIR:?}"
echo "$*" >> "$STUB_DIR/agekeygen.calls"
[ ! -f "$STUB_DIR/agekeygen_fails" ] || exit 1
if [ "${1:-}" = -y ] && [ $# -eq 1 ]; then
  IFS= read -r key || true
  [ -f "$STUB_DIR/agekey.pub.$key" ] || { echo "age-keygen: error: failed to parse identity" >&2; exit 1; }
  cat "$STUB_DIR/agekey.pub.$key"; exit 0
fi
[ $# -eq 0 ] || { echo "age-keygen (stand-in): unexpected: $*" >&2; exit 99; }
if [ -f "$STUB_DIR/agekey.out" ]; then cat "$STUB_DIR/agekey.out"; exit 0; fi
pub="age1$(printf 'k%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58)"
key="AGE-SECRET-KEY-1$(printf 'K%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58)"
echo "Public key: $pub" >&2
printf '# created: 2026-11-27T10:00:00Z\n# public key: %s\n%s\n' "$pub" "$key"
printf '%s\n' "$pub" > "$STUB_DIR/agekey.pub.$key"
STUB
  cat > "$1/bin/osascript" <<'STUB'
#!/bin/bash
: "${STUB_DIR:?}"
printf '%s\n' "$*" >> "$STUB_DIR/osascript.calls"
STUB
  chmod +x "$1/security" "$1/bin/ssh-agent" "$1/bin/ssh-add" "$1/bin/ssh" "$1/bin/age-keygen" "$1/bin/osascript"
}
