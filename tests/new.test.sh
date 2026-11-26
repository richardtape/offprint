#!/usr/bin/env bash
# Tests bin/new (offprint new NAME [--public-url URL]): the site folder it makes, the values it picks, and every
# refusal and failure, which must leave nothing behind.
# Every run is in a throwaway folder, with every seam set: a pretend hosts file (OFFPRINT_HOSTS_FILE), stand-ins for
# ifconfig and lsof (OFFPRINT_IFCONFIG, OFFPRINT_LSOF), the 40 random bits fixed (OFFPRINT_NEW_PREFIX), and a stand-in
# docker first on the PATH; tripwires named ifconfig, lsof, launchctl, sudo, security, npm and wrangler come next. git's
# identity is the suite's own (GIT_CONFIG_GLOBAL), never the owner's. So nothing here reads or changes this machine's
# hosts file, lo0, Docker or git settings.
# Run: bash tests/new.test.sh   (macOS bash 3.2 and Linux)
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
unset OFFPRINT_SITE OFFPRINT_HOSTS_FILE OFFPRINT_DAEMON_DIR OFFPRINT_IFCONFIG OFFPRINT_LAUNCHCTL OFFPRINT_LSOF \
  OFFPRINT_NEW_PREFIX OFFPRINT_NEW_ASSUME_TTY
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
export GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
if [ "$(id -u)" = 0 ]; then echo "Run tests/new.test.sh as yourself, not as root."; exit 1; fi
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR), and TMPDIR inside
# it from here on (bin/new must leave it empty: it makes nothing outside the folder it runs in).
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-new-test.XXXXXX")"
trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
# git's identity for every run: a config file of the suite's own.
printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$tmp/gitconfig"; export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
# contains T WANT TEXT: WANT is in TEXT, as it is (several lines in a row, too)
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in '$3')" ;; esac; }

# The PATH the runs start from: this one's absolute entries that are folders (an owner's relative entry would make every
# run say it was left out, which is lib/site.sh's business, tested in tests/publish.test.sh).
BASE=""; rest="$PATH:"
while [ -n "$rest" ]; do
  e="${rest%%:*}"; rest="${rest#*:}"
  case "$e" in /*) [ -d "$e" ] && BASE="${BASE:+$BASE:}$e" ;; esac
done
# Tripwires: a run that reaches any of these by name, not through its seam, is caught.
TRIP="$tmp/trip"; mkdir -p "$TRIP"
for c in ifconfig lsof launchctl sudo security npm wrangler; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/tripped"\nexit 99\n' "$c" "$tmp" > "$TRIP/$c"; chmod +x "$TRIP/$c"
done
# without NAME: a folder of links to the programs a run needs, from BASE, but NAME (so that it is missing).
without() {
  local d="$tmp/without-$1" p f
  mkdir -p "$d"
  for p in bash sh cat cp mv rm ls mkdir chmod mktemp od tr awk sed grep head tail cut sort env id uname dirname basename \
    git php docker; do
    [ "$p" = "$1" ] && continue
    f="$(PATH="$BASE" command -v "$p" 2>/dev/null)" || continue
    case "$f" in /*) ln -s "$f" "$d/$p" ;; esac
  done
  printf '%s' "$d"
}
REALGIT="$(PATH="$BASE" command -v git)"

n=0
# newcase: a fresh pretend machine in $W, and an empty folder $H to run in. W/hosts (the hosts file), W/lo0 (what
# ifconfig lo0 prints), W/listening (the ports lsof finds a listener on, one a line), W/projects and W/volumes (what
# docker compose ls -a -q and docker volume ls -q print). Switches, as files in W: docker_down (docker fails),
# ifconfig_fails, lsof_fails (lsof exits with the code in it, saying why on stderr). Every stand-in notes its calls.
# The run's settings, reset here: PFX (OFFPRINT_NEW_PREFIX), IN (stdin), TTY (OFFPRINT_NEW_ASSUME_TTY), RUNPATH.
newcase() {
  n=$((n + 1)); W="$tmp/w$n"; H="$W/here"
  mkdir -p "$H" "$W/stubs/bin"
  printf '##\n# Host Database\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n' > "$W/hosts"
  printf 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n\tinet6 ::1 prefixlen 128 \n\tinet6 fe80::1%%lo0 prefixlen 64 scopeid 0x1 \n' > "$W/lo0"
  : > "$W/listening"
  cat > "$W/stubs/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_DIR/docker.calls"
[ -f "$STUB_DIR/docker_down" ] && { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1; }
case "$*" in
  "compose ls -a -q") cat "$STUB_DIR/projects" 2>/dev/null; exit 0 ;;
  "volume ls -q") cat "$STUB_DIR/volumes" 2>/dev/null; exit 0 ;;
esac
echo "unexpected docker call: $*" >&2; exit 99
STUB
  cat > "$W/stubs/ifconfig" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_DIR/ifconfig.calls"
[ -f "$STUB_DIR/ifconfig_fails" ] && { echo "ifconfig: interface lo0 does not exist" >&2; exit 1; }
[ "$*" = lo0 ] || { echo "unexpected ifconfig call: $*" >&2; exit 99; }
cat "$STUB_DIR/lo0"
STUB
  cat > "$W/stubs/lsof" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_DIR/lsof.calls"
[ -f "$STUB_DIR/lsof_fails" ] && { echo "lsof: WARNING: can't stat() something" >&2; exit "$(cat "$STUB_DIR/lsof_fails")"; }
port=""
for a in "$@"; do case "$a" in -iTCP:*) port="${a#-iTCP:}" ;; esac; done
[ -n "$port" ] && grep -qx "$port" "$STUB_DIR/listening" || exit 1
echo "COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME"
echo "com.docke  4242 someone 12u  IPv4 0x56c16eeedce31ba7      0t0  TCP 127.0.0.1:$port (LISTEN)"
STUB
  chmod +x "$W/stubs/bin/docker" "$W/stubs/ifconfig" "$W/stubs/lsof"
  PFX=ab12cd34ef; IN=/dev/null; TTY=""; RUNPATH="$W/stubs/bin:$TRIP:$BASE"
}
# nw ARGS...: bin/new ARGS, run in $H with the seams and the case's settings; sets out (its stdout), err (its stderr)
# and code.
nw() {
  out="$(cd "$H" && PATH="$RUNPATH" STUB_DIR="$W" OFFPRINT_HOSTS_FILE="$W/hosts" OFFPRINT_IFCONFIG="$W/stubs/ifconfig" \
    OFFPRINT_LSOF="$W/stubs/lsof" OFFPRINT_NEW_PREFIX="$PFX" OFFPRINT_NEW_ASSUME_TTY="$TTY" \
    /bin/bash "$SRC/bin/new" "$@" 2> "$W/err" < "$IN")"; code=$?
  err="$(cat "$W/err")"
}
URL=https://www.example.com
# listing DIR: every name in DIR (but . and ..), one line, sorted
listing() { ls -A "$1" | LC_ALL=C sort | paste -sd' ' -; }
# refused T WANT [BEFORE]: exit 2, one line on stderr holding WANT, nothing on stdout, and $H as it was (BEFORE, or empty)
refused() {
  check "$1: exit 2" 2 "$code"
  contains "$1: says why" "$2" "$err"
  check "$1: in one line" 1 "$(printf '%s\n' "$err" | grep -c .)"
  check "$1: nothing on stdout" "" "$out"
  check "$1: nothing made" "${3:-}" "$(listing "$H")"
}
no_docker() { check "$1: Docker was never asked" no "$([ -e "$W/docker.calls" ] && echo yes || echo no)"; }
# field DIR KEY: KEY's value in DIR/site.json, or nothing
field() { php -d display_errors=0 -r '$j = json_decode((string) @file_get_contents($argv[1]), true); echo is_array($j) ? ($j[$argv[2]] ?? "") : "";' "$1/site.json" "$2"; }

# --- the happy path ---
newcase; nw mysite --public-url "$URL"; t="offprint new mysite --public-url $URL"
check "$t: exit 0" 0 "$code"
check "$t: nothing on stderr" "" "$err"
check "$t: the folder mysite, and nothing else, in the folder it ran in" mysite "$(listing "$H")"
want_json='{
  "format": 1,
  "name": "mysite",
  "public_url": "https://www.example.com",
  "local_host": "mysite.local",
  "local_ip4": "127.0.0.2",
  "local_ip6": "fdab:12cd:34ef::2",
  "tls_port": 4243,
  "http_port": 4280
}'
check "$t: site.json, byte for byte" "$want_json" "$(cat "$H/mysite/site.json")"
check "$t: site.json ends with a line end" "$(printf '}\n' | od -An -c)" "$(tail -c 2 "$H/mysite/site.json" | od -An -c)"
check "$t: .gitignore is templates/site.gitignore" same "$(cmp -s "$SRC/templates/site.gitignore" "$H/mysite/.gitignore" && echo same)"
check "$t: lib/config.php accepts site.json" 0 "$(php "$SRC/lib/config.php" "$H/mysite" > /dev/null 2>&1; echo $?)"
check "$t: the folder holds .git, .gitignore and site.json" ".git .gitignore site.json" "$(listing "$H/mysite")"
check "$t: on the branch main" main "$(git -C "$H/mysite" symbolic-ref --short HEAD)"
check "$t: one commit" 1 "$(git -C "$H/mysite" rev-list --count HEAD)"
check "$t: its message" "A new site" "$(git -C "$H/mysite" log -1 --format=%B | sed '/^$/d')"
check "$t: its two files" ".gitignore site.json" "$(git -C "$H/mysite" ls-tree --name-only HEAD | paste -sd' ' -)"
check "$t: by the git identity it was given" "Test <test@example.com>" "$(git -C "$H/mysite" log -1 --format='%an <%ae>')"
check "$t: the work tree is clean" "" "$(git -C "$H/mysite" status --porcelain --ignored)"
want_out='Made mysite: a git repository on main, holding site.json and .gitignore, committed as "A new site".
In its site.json:
  name        mysite
  public_url  https://www.example.com
  local_host  mysite.local
  local_ip4   127.0.0.2
  local_ip6   fdab:12cd:34ef::2
  tls_port    4243
  http_port   4280
Next, in this order:
  cd mysite
  offprint host-setup          (prints the sudo line to run)
  offprint setup-wp
  offprint publish --dry-run
Before the first publish (a dry run too), give the site a backup key:
  age-keygen                 # prints a private key (AGE-SECRET-KEY-…) and its public key (age1…)
  # keep the private key in your password manager, not on this Mac alone
  # then add to site.json:  "backup": {"recipients": ["age1…"]}
Run offprint host-setup for this site before making another: until then its address and ports are not yet taken on this Mac.
To publish to a host, add an adapter block to site.json: see the README.'
check "$t: what it says, on stdout" "$want_out" "$out"
check "$t: Docker was asked for its projects and volumes, and nothing else" "compose ls -a -q|volume ls -q" "$(paste -sd'|' - < "$W/docker.calls")"
check "$t: ifconfig was asked about lo0 once" lo0 "$(cat "$W/ifconfig.calls")"
check "$t: lsof was asked about the two ports" "-nP -iTCP:4243 -sTCP:LISTEN|-nP -iTCP:4280 -sTCP:LISTEN" "$(paste -sd'|' - < "$W/lsof.calls")"
check "$t: nothing left in TMPDIR" "" "$(listing "$TMPDIR")"
check "$t: nothing written beside it" "docker.calls err here hosts ifconfig.calls listening lo0 lsof.calls stubs" "$(listing "$W")"
# The folder's mode is what mkdir would give it (the umask's), not mktemp's 700.
newcase; out="$(umask 022; cd "$H" && PATH="$RUNPATH" STUB_DIR="$W" OFFPRINT_HOSTS_FILE="$W/hosts" OFFPRINT_IFCONFIG="$W/stubs/ifconfig" \
  OFFPRINT_LSOF="$W/stubs/lsof" OFFPRINT_NEW_PREFIX="$PFX" /bin/bash "$SRC/bin/new" mysite --public-url "$URL" 2>&1 < /dev/null)"
check "the site folder's mode, with umask 022" drwxr-xr-x "$(ls -ld "$H/mysite" | cut -c1-10)"
newcase; nw --public-url="$URL" mysite; t="--public-url=URL, before NAME"
check "$t: exit 0" 0 "$code"; check "$t: the address" "$URL" "$(field "$H/mysite" public_url)"
# Through bin/offprint.
newcase; out="$(cd "$H" && PATH="$RUNPATH" STUB_DIR="$W" OFFPRINT_HOSTS_FILE="$W/hosts" OFFPRINT_IFCONFIG="$W/stubs/ifconfig" \
  OFFPRINT_LSOF="$W/stubs/lsof" OFFPRINT_NEW_PREFIX="$PFX" /bin/bash "$SRC/bin/offprint" new mysite --public-url "$URL" 2>&1 < /dev/null)"; code=$?
t="offprint new, through bin/offprint"
check "$t: exit 0" 0 "$code"; contains "$t: says what it made" "Made mysite:" "$out"
check "$t: site.json" "$want_json" "$(cat "$H/mysite/site.json" 2>&1)"
out="$(/bin/bash "$SRC/bin/offprint" help 2>&1)"
contains "offprint help lists offprint new" "offprint new NAME [--public-url URL]" "$out"

# --- usage ---
for args in "" "mysite other --public-url $URL" "--public-url" "mysite --public-url" "mysite --frobnicate" \
    "mysite --public-url $URL --public-url $URL"; do
  newcase; nw $args; t="offprint new $args (usage)"
  check "$t: exit 2" 2 "$code"; contains "$t: prints the usage" "usage: offprint new NAME [--public-url URL]" "$err"
  check "$t: nothing made" "" "$(listing "$H")"; no_docker "$t"
done
newcase; nw --help; t="offprint new --help"
check "$t: exit 0, the usage on stdout" "0|usage: offprint new NAME [--public-url URL]" "$code|$out"

# --- refusals, before anything is made ---
name_rule="lowercase letters, digits and dashes, starting with a letter, at most 31 characters"
for bad_name in MySite 1site my_site "my site" mysite/ my.site "" abcdefghijklmnopqrstuvwxyz012345 "$(printf 'my\033[31msite')"; do
  newcase; nw "$bad_name" --public-url "$URL"; t="the name '$(printf '%s' "$bad_name" | tr '\033' '?')'"
  refused "$t" "$name_rule"; no_docker "$t"
  check "$t: no control character reaches the terminal" no "$(printf '%s' "$err" | LC_ALL=C grep -q "$(printf '\033')" && echo yes || echo no)"
done
newcase; nw abcdefghijklmnopqrstuvwxyz01234 --public-url "$URL"; check "a name of 31 characters: made" 0 "$code"
newcase; nw my--site --public-url "$URL"; check "a name with two dashes in a row: made" "0|my--site.local" "$code|$(field "$H/my--site" local_host)"
# site.json's rule allows a dash at the end of a name, but then NAME.local isn't a host name
newcase; nw mysite- --public-url "$URL"; t="the name mysite-"; refused "$t" "it ends with a dash, so mysite-.local can't be its local host name"; no_docker "$t"
newcase; nw offprint-e2e --public-url "$URL"; t="the name offprint-e2e"
refused "$t" "offprint-e2e is the tests' own compose project"; no_docker "$t"
# ./NAME there already, of any kind
newcase; mkdir "$H/mysite"; nw mysite --public-url "$URL"; refused "an empty folder mysite there" "./mysite already exists" mysite
check "an empty folder mysite there: left empty" "" "$(listing "$H/mysite")"; no_docker "an empty folder mysite there"
newcase; mkdir "$H/mysite"; echo keep > "$H/mysite/notes.txt"; nw mysite --public-url "$URL"
refused "a folder mysite there, with a file in it" "./mysite already exists" mysite
check "a folder mysite there: its file as it was" keep "$(cat "$H/mysite/notes.txt")"
newcase; echo keep > "$H/mysite"; nw mysite --public-url "$URL"; refused "a file mysite there" "./mysite already exists" mysite
newcase; ln -s "$W/nowhere" "$H/mysite"; nw mysite --public-url "$URL"; refused "a link to nothing called mysite there" "./mysite already exists" mysite
newcase; mkdir "$W/elsewhere"; ln -s "$W/elsewhere" "$H/mysite"; nw mysite --public-url "$URL"
refused "a link to a folder called mysite there" "./mysite already exists" mysite
check "a link to a folder: the folder left empty" "" "$(listing "$W/elsewhere")"
# inside a site folder: a site.json here, or above, of any kind
newcase; cp "$SRC/tests/fixtures/site.json" "$H/site.json"; nw mysite --public-url "$URL"
refused "run in a site folder" "inside the site folder $(cd "$H" && pwd -P)" site.json; no_docker "run in a site folder"
# (the site folder above is W/site, so that the stand-ins' folder isn't in it: lib/site.sh would leave it out of the PATH)
newcase; H="$W/site/inner"; mkdir -p "$H"; cp "$SRC/tests/fixtures/site.json" "$W/site/site.json"; nw mysite --public-url "$URL"
refused "run in a folder inside a site folder" "inside the site folder $(cd "$W/site" && pwd -P)"
newcase; H="$W/site/inner"; mkdir -p "$H" "$W/site/site.json"; nw mysite --public-url "$URL"; refused "a folder called site.json above" "inside the site folder"
newcase; H="$W/site/inner"; mkdir -p "$H"; ln -s "$W/nowhere" "$W/site/site.json"; nw mysite --public-url "$URL"
refused "a link to nothing called site.json above" "inside the site folder"
# inside a git repository: here, above, or a .git file (a linked work tree's) above
newcase; git init -q -b main "$H"; nw mysite --public-url "$URL"; refused "run at the top of a git repository" "inside the git repository" .git
newcase; git init -q -b main "$W"; nw mysite --public-url "$URL"; refused "run inside a git repository" "inside the git repository $(cd "$W" && pwd -P)"
newcase; echo "gitdir: $W/nowhere" > "$W/.git"; nw mysite --public-url "$URL"; refused "a .git file above" "inside the git repository"
newcase; git init -q --bare "$H"; before="$(listing "$H")"; nw mysite --public-url "$URL"; refused "run in a bare repository" "inside a git repository" "$before"
# no git, no php
newcase; RUNPATH="$W/stubs/bin:$(without git)"; nw mysite --public-url "$URL"; refused "no git on the PATH" "git isn't on the PATH"; no_docker "no git"
newcase; RUNPATH="$W/stubs/bin:$(without php)"; nw mysite --public-url "$URL"; refused "no php on the PATH" "php isn't on the PATH"; no_docker "no php"
# Docker has a project, or a volume compose would mount, of the name
newcase; printf 'blog\nmysite\n' > "$W/projects"; nw mysite --public-url "$URL"
refused "Docker has a compose project called mysite" "Docker has a compose project called mysite already"
newcase; printf 'blog_db\nmysite_db\n' > "$W/volumes"; nw mysite --public-url "$URL"; refused "Docker has a volume mysite_db" "Docker has a volume called mysite_db already"
newcase; printf 'mysite_wordpress\n' > "$W/volumes"; nw mysite --public-url "$URL"; refused "Docker has a volume mysite_wordpress" "Docker has a volume called mysite_wordpress already"
newcase; printf 'mysite2\nmy\nmysite-old\n' > "$W/projects"; printf 'mysite_dbx\nmysite_data\nxmysite_db\n' > "$W/volumes"
nw mysite --public-url "$URL"; t="Docker has projects and volumes with names like it, but not its own"
check "$t: made" 0 "$code"; check "$t: nothing on stderr" "" "$err"
# the hosts file names NAME.local already
newcase; printf '127.0.0.9\tmysite.local\n' >> "$W/hosts"; nw mysite --public-url "$URL"
refused "the hosts file names mysite.local" "$W/hosts names mysite.local already (line 7)"
newcase; printf '127.0.0.9 other.local MySite.Local\r\n' >> "$W/hosts"; nw mysite --public-url "$URL"
refused "the hosts file names it in another case, on a CRLF line" "names mysite.local already"
newcase; printf '# 127.0.0.9 mysite.local\n127.0.0.9 other.local # mysite.local\n' >> "$W/hosts"; nw mysite --public-url "$URL"
check "the hosts file names it only in comments: made" 0 "$code"
# no public address, and stdin is not a terminal
newcase; nw mysite; t="no --public-url, stdin not a terminal"
check "$t: exit 2" 2 "$code"; contains "$t: prints the usage" "usage: offprint new NAME [--public-url URL]" "$err"
contains "$t: says why" "--public-url" "$err"; check "$t: nothing made" "" "$(listing "$H")"

# --- the public address, asked for (OFFPRINT_NEW_ASSUME_TTY=1 stands for a terminal on stdin) ---
prompt="The site's public address, where it will be served (https://..., no path): "
newcase; printf '%s\n' "$URL" > "$W/answer"; IN="$W/answer"; TTY=1; nw mysite; t="asked for the public address"
check "$t: exit 0" 0 "$code"; check "$t: the prompt, on stderr" "$prompt" "$err"
check "$t: the address in site.json" "$URL" "$(field "$H/mysite" public_url)"
contains "$t: and on stdout" "  public_url  $URL" "$out"
newcase; printf '  %s \r\n' "$URL" > "$W/answer"; IN="$W/answer"; TTY=1; nw mysite; t="the answer with spaces around it"
check "$t: taken without them" "0|$URL" "$code|$(field "$H/mysite" public_url)"
newcase; printf '\n' > "$W/answer"; IN="$W/answer"; TTY=1; nw mysite; t="an empty answer"
check "$t: exit 2" 2 "$code"; contains "$t: says so" "no public address was given" "$err"; check "$t: nothing made" "" "$(listing "$H")"
newcase; IN=/dev/null; TTY=1; nw mysite; t="no answer at all (end of input)"
check "$t: exit 2" 2 "$code"; check "$t: nothing made" "" "$(listing "$H")"

# --- a public address site.json's rule refuses: lib/config.php's line, and the folder gone ---
url_rule='site.json: "public_url" must be https://hostname, lowercase, with no port, path or trailing slash.'
for bad_url in http://www.example.com https://WWW.example.com https://www.example.com/ https://www.example.com:8443 \
    https://localhost 'https://www.example.com", "agent_label": "x' 'https://www.example.com\' "$(printf 'https://www.example.com\nx')"; do
  newcase; nw mysite --public-url "$bad_url"; t="the public address '$(printf '%s' "$bad_url" | tr '\n' '?')'"
  check "$t: exit 2" 2 "$code"; contains "$t: lib/config.php's line" "$url_rule" "$err"
  contains "$t: and that nothing was made" "nothing was made" "$err"
  check "$t: the folder is gone" "" "$(listing "$H")"; check "$t: nothing on stdout" "" "$out"
done
newcase; nw mysite --public-url https://mysite.local; t="the public address is mysite.local"
check "$t: exit 2" 2 "$code"; contains "$t: lib/config.php's line" 'site.json: "local_host" must differ from the public host.' "$err"
check "$t: the folder is gone" "" "$(listing "$H")"

# --- the address and ports picked ---
newcase; printf '\tinet 127.0.0.2 netmask 0xff000000\n' >> "$W/lo0"; printf '127.0.0.3\tblog.local\n# 127.0.0.4 old.local\n' >> "$W/hosts"
nw mysite --public-url "$URL"; t="127.0.0.2 on lo0, 127.0.0.3 in the hosts file (and 127.0.0.4 only in a comment)"
check "$t: 127.0.0.4, and its ports" "0|127.0.0.4|fdab:12cd:34ef::4|4443|4480" \
  "$code|$(field "$H/mysite" local_ip4)|$(field "$H/mysite" local_ip6)|$(field "$H/mysite" tls_port)|$(field "$H/mysite" http_port)"
newcase; echo 4243 > "$W/listening"; nw mysite --public-url "$URL"; t="something listens on 4243 (N 2's tls_port)"
check "$t: N 3" "0|127.0.0.3|fdab:12cd:34ef::3|4343|4380" \
  "$code|$(field "$H/mysite" local_ip4)|$(field "$H/mysite" local_ip6)|$(field "$H/mysite" tls_port)|$(field "$H/mysite" http_port)"
newcase; printf '4280\n4343\n' > "$W/listening"; nw mysite --public-url "$URL"; t="something listens on 4280 (N 2's http_port) and 4343 (N 3's tls_port)"
check "$t: N 4" "0|127.0.0.4|4443|4480" "$code|$(field "$H/mysite" local_ip4)|$(field "$H/mysite" tls_port)|$(field "$H/mysite" http_port)"
newcase; i=2; while [ "$i" -le 9 ]; do printf '\tinet 127.0.0.%s netmask 0xff000000\n' "$i" >> "$W/lo0"; i=$((i + 1)); done
nw mysite --public-url "$URL"; t="2 to 9 on lo0"
check "$t: N 10, written the same in both addresses" "0|127.0.0.10|fdab:12cd:34ef::10|5043|5080" \
  "$code|$(field "$H/mysite" local_ip4)|$(field "$H/mysite" local_ip6)|$(field "$H/mysite" tls_port)|$(field "$H/mysite" http_port)"
check "$t: lib/config.php accepts it" 0 "$(php "$SRC/lib/config.php" "$H/mysite" > /dev/null 2>&1; echo $?)"
newcase; i=2; while [ "$i" -le 254 ]; do printf '127.0.0.%s\tsite%s.local\n' "$i" "$i" >> "$W/hosts"; i=$((i + 1)); done
nw mysite --public-url "$URL"; refused "every address from 127.0.0.2 to 127.0.0.254 in the hosts file" "no free address"
# A source the pick reads can't be read: it says so, and goes on (host-setup checks every value again).
newcase; echo 3 > "$W/lsof_fails"; nw mysite --public-url "$URL"; t="lsof fails"
check "$t: made, with N 2" "0|127.0.0.2" "$code|$(field "$H/mysite" local_ip4)"
contains "$t: says the ports couldn't be checked" "couldn't tell whether anything listens on port 4243 (lsof exited 3: lsof: WARNING: can't stat() something)" "$err"
contains "$t: and that host-setup checks again" "offprint host-setup --print checks again" "$err"
check "$t: in one line, and lsof asked once" "1|1" "$(printf '%s\n' "$err" | grep -c .)|$(grep -c . "$W/lsof.calls")"
newcase; touch "$W/ifconfig_fails"; printf '127.0.0.2\tblog.local\n' >> "$W/hosts"; nw mysite --public-url "$URL"; t="ifconfig lo0 fails"
check "$t: made, with N 3 (the hosts file still read)" "0|127.0.0.3" "$code|$(field "$H/mysite" local_ip4)"
contains "$t: says lo0 couldn't be read" "couldn't read lo0 (ifconfig: interface lo0 does not exist)" "$err"
check "$t: in one line" 1 "$(printf '%s\n' "$err" | grep -c .)"
newcase; printf '\tinet 127.0.0.2 netmask 0xff000000\n' >> "$W/lo0"; rm -f "$W/hosts"; nw mysite --public-url "$URL"; t="the hosts file can't be read"
check "$t: made, with N 3 (lo0 still read)" "0|127.0.0.3" "$code|$(field "$H/mysite" local_ip4)"
contains "$t: says so" "couldn't read $W/hosts" "$err"; check "$t: in one line" 1 "$(printf '%s\n' "$err" | grep -c .)"

# --- the IPv6 prefix: 40 bits, written in the canonical form lib/config.php demands ---
newcase; PFX=0a0b0c0d0e; nw mysite --public-url "$URL"; t="bits 0a0b0c0d0e"
check "$t: no leading zeros in a group" "0|fd0a:b0c:d0e::2" "$code|$(field "$H/mysite" local_ip6)"
check "$t: lib/config.php accepts it" 0 "$(php "$SRC/lib/config.php" "$H/mysite" > /dev/null 2>&1; echo $?)"
newcase; PFX="ab0000cdef ab12340000 12345678ab"; nw mysite --public-url "$URL"; t="draws with an all-zero group"
check "$t: drawn again until neither group is zero" "0|fd12:3456:78ab::2" "$code|$(field "$H/mysite" local_ip6)"
for bad_pfx in ab12cd34e ab12cd34eff AB12CD34EF ab12cd34eg; do
  newcase; PFX="$bad_pfx"; nw mysite --public-url "$URL"; t="OFFPRINT_NEW_PREFIX=$bad_pfx"
  check "$t: exit 2" 2 "$code"; contains "$t: says so" "OFFPRINT_NEW_PREFIX" "$err"; check "$t: nothing made" "" "$(listing "$H")"
done
newcase; PFX="ab0000cdef"; nw mysite --public-url "$URL"; t="the test seam's draws run out"
check "$t: exit 2" 2 "$code"; check "$t: nothing made" "" "$(listing "$H")"
# Without the seam, the bits come from /dev/urandom: a fresh prefix each time, which lib/config.php accepts.
newcase; PFX=""; nw mysite --public-url "$URL"; t="a random prefix"; p1="$(field "$H/mysite" local_ip6)"
check "$t: made" 0 "$code"; check "$t: lib/config.php accepts it" 0 "$(php "$SRC/lib/config.php" "$H/mysite" > /dev/null 2>&1; echo $?)"
check "$t: of the form fdXX:X...:X...::2" yes "$(printf '%s' "$p1" | grep -Eq '^fd[0-9a-f]{2}:[1-9a-f][0-9a-f]{0,3}:[1-9a-f][0-9a-f]{0,3}::2$' && echo yes)"
newcase; PFX=""; nw mysite --public-url "$URL"; p2="$(field "$H/mysite" local_ip6)"
check "another random prefix, made the same way, differs" yes "$([ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ] && echo yes)"

# --- no git identity: the files are left uncommitted, and it says how to commit them ---
newcase; out="$(cd "$H" && PATH="$RUNPATH" STUB_DIR="$W" OFFPRINT_HOSTS_FILE="$W/hosts" OFFPRINT_IFCONFIG="$W/stubs/ifconfig" \
  OFFPRINT_LSOF="$W/stubs/lsof" OFFPRINT_NEW_PREFIX="$PFX" GIT_CONFIG_GLOBAL=/dev/null /bin/bash "$SRC/bin/new" mysite --public-url "$URL" 2> "$W/err" < /dev/null)"
code=$?; err="$(cat "$W/err")"; t="no git identity"
check "$t: exit 0" 0 "$code"; check "$t: nothing on stderr" "" "$err"
check "$t: site.json as ever" "$want_json" "$(cat "$H/mysite/site.json" 2>&1)"
check "$t: a repository on main with no commit yet" "main|no" "$(git -C "$H/mysite" symbolic-ref --short HEAD)|$(git -C "$H/mysite" rev-parse -q --verify HEAD > /dev/null && echo yes || echo no)"
check "$t: both files untracked, nothing staged" "?? .gitignore|?? site.json" "$(git -C "$H/mysite" status --porcelain | paste -sd'|' -)"
contains "$t: says why" "not committed: git has no user.name and user.email" "$out"
contains "$t: and the two commands, after cd" "  cd mysite
  git add site.json .gitignore
  git commit -m \"A new site\"
  offprint host-setup" "$out"

# --- Docker missing, or failing: it says it couldn't check, and goes on ---
newcase; RUNPATH="$(without docker)"; nw mysite --public-url "$URL"; t="no docker on the PATH"
check "$t: made" 0 "$code"
check "$t: says it couldn't check, in one line" "offprint new: docker isn't on the PATH, so it couldn't be checked that Docker has no compose project or volume called mysite; offprint setup-wp checks again before it starts anything." "$err"
newcase; touch "$W/docker_down"; nw mysite --public-url "$URL"; t="docker fails"
check "$t: made" 0 "$code"
check "$t: says it couldn't check, with Docker's words, in one line" "offprint new: Docker couldn't be asked (docker said: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?), so it couldn't be checked that Docker has no compose project or volume called mysite; offprint setup-wp checks again before it starts anything." "$err"

# --- something fails part way, or a signal stops it: nothing is left ---
# A stand-in git, first on the PATH: the real one, but for commit, which (with W/commit_fails) fails as a signing
# failure would, or (with W/commit_waits) says it has started and waits for W/release.
newcase; mkdir -p "$W/gitbin"
cat > "$W/gitbin/git" <<STUB
#!/bin/sh
case " \$* " in
  *" commit "*)
    if [ -f "\$STUB_DIR/commit_fails" ]; then echo "error: gpg failed to sign the data" >&2; echo "fatal: failed to write commit object" >&2; exit 128; fi
    if [ -f "\$STUB_DIR/commit_waits" ]; then
      touch "\$STUB_DIR/at-commit"; i=0
      while [ ! -f "\$STUB_DIR/release" ] && [ "\$i" -lt 200 ]; do sleep 0.05; i=\$((i + 1)); done
      exit 1
    fi ;;
esac
exec "$REALGIT" "\$@"
STUB
chmod +x "$W/gitbin/git"; gitbin="$W/gitbin"
touch "$W/commit_fails"; RUNPATH="$gitbin:$W/stubs/bin:$TRIP:$BASE"; nw mysite --public-url "$URL"; t="git commit fails"
check "$t: exit 1" 1 "$code"; contains "$t: shows what git said" "error: gpg failed to sign the data" "$err"
contains "$t: and that nothing was made" "nothing was made" "$err"
check "$t: the folder is gone" "" "$(listing "$H")"; check "$t: nothing on stdout" "" "$out"
for sig in TERM HUP; do
  newcase; touch "$W/commit_waits"; mkdir -p "$W/gitbin"; cp "$gitbin/git" "$W/gitbin/git"
  ( cd "$H" && exec env PATH="$W/gitbin:$W/stubs/bin:$TRIP:$BASE" STUB_DIR="$W" OFFPRINT_HOSTS_FILE="$W/hosts" \
      OFFPRINT_IFCONFIG="$W/stubs/ifconfig" OFFPRINT_LSOF="$W/stubs/lsof" OFFPRINT_NEW_PREFIX="$PFX" \
      /bin/bash "$SRC/bin/new" mysite --public-url "$URL" > "$W/out" 2> "$W/err" < /dev/null ) &
  pid=$!; i=0
  while [ ! -f "$W/at-commit" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  t="a $sig while it commits"
  check "$t: it got that far, with its folder made" yes "$([ -f "$W/at-commit" ] && [ -n "$(ls -A "$H")" ] && echo yes)"
  kill -"$sig" "$pid" 2>/dev/null; touch "$W/release"; wait "$pid"; code=$?
  if [ "$sig" = TERM ]; then want=143; else want=129; fi
  check "$t: exit $want" "$want" "$code"
  check "$t: nothing left" "" "$(listing "$H")"; check "$t: nothing on stdout" "" "$(cat "$W/out")"
done

# --- run from a folder WordPress can write, with look-alikes of git, php, docker... there and . on the PATH ---
plant() {  # plant DIR: the look-alikes in DIR, each noting in $tmp/planted.ran that it ran
  local p; mkdir -p "$1"
  for p in bash sh git php docker od mktemp awk cat cp chmod rm tr grep head cut env ifconfig lsof; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$1/$p"; chmod +x "$1/$p"
  done
}
newcase; mkdir -p "$W/site/wp-content"; cp "$SRC/tests/fixtures/site.json" "$W/site/site.json"; plant "$W/site/wp-content"
H="$W/site/wp-content"; before="$(listing "$H")"; RUNPATH=".:$W/stubs/bin:$TRIP:$BASE"; nw mysite --public-url "$URL"
t="in a site's wp-content/, look-alikes there, . first on the PATH"
check "$t: exit 2" 2 "$code"; contains "$t: refused, as inside the site folder" "inside the site folder $(cd "$W/site" && pwd -P)" "$err"
check "$t: no look-alike ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"; check "$t: nothing made" "$before" "$(listing "$H")"
contains "$t: says . was left out of the PATH" "PATH entries left out" "$err"; rm -f "$tmp/planted.ran"
RUNPATH="$W/site/wp-content:$W/stubs/bin:$TRIP:$BASE"; nw mysite --public-url "$URL"; t="the same, with wp-content/ on the PATH by its absolute path"
check "$t: exit 2" 2 "$code"; check "$t: no look-alike ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
contains "$t: says it was left out of the PATH" "as each is in the site folder" "$err"; rm -f "$tmp/planted.ran"
newcase; plant "$H"; before="$(listing "$H")"; RUNPATH=".:$W/stubs/bin:$TRIP:$BASE"; nw mysite --public-url "$URL"
t="in a folder holding look-alikes, . first on the PATH"
check "$t: made" 0 "$code"; check "$t: no look-alike ran" "" "$(cat "$tmp/planted.ran" 2>/dev/null)"
check "$t: site.json as ever" "$want_json" "$(cat "$H/mysite/site.json" 2>&1)"
check "$t: one commit" 1 "$(git -C "$H/mysite" rev-list --count HEAD 2>&1)"
check "$t: one line says . was left out of the PATH" "offprint: PATH entries left out, as each names whatever folder a command runs in (empty, or not an absolute path): '.'" "$err"
rm -f "$tmp/planted.ran"

# --- ifconfig and lsof with no seam: the ones host-setup runs, where they are, else the PATH's ---
# (bin/new is never run here without the seams: that would read this Mac's lo0 and ports. Its choice is made by
# which_program, run here on its own, and bin/new is read for the two lines that use it, with host-lib.sh's paths.)
hl="$(grep -E '^ *IFCONFIG=/[^;]*; LAUNCHCTL=/[^;]*; LSOF=/[^;]*$' "$SRC/os/darwin/host-lib.sh")"
hl_ifconfig="$(printf '%s' "$hl" | sed 's/^ *IFCONFIG=\([^;]*\);.*/\1/')"; hl_lsof="$(printf '%s' "$hl" | sed 's/.*; LSOF=//')"
check "host-lib.sh runs /sbin/ifconfig and /usr/sbin/lsof" "/sbin/ifconfig|/usr/sbin/lsof" "$hl_ifconfig|$hl_lsof"
check "bin/new takes ifconfig the same way: the seam, else host-lib.sh's where it is, else the PATH's" 1 \
  "$(grep -cxF "IFCONFIG=\"\$(which_program \"\${OFFPRINT_IFCONFIG:-}\" $hl_ifconfig ifconfig)\"" "$SRC/bin/new")"
check "bin/new takes lsof the same way" 1 "$(grep -cxF "LSOF=\"\$(which_program \"\${OFFPRINT_LSOF:-}\" $hl_lsof lsof)\"" "$SRC/bin/new")"
wp_def="$(grep '^which_program() ' "$SRC/bin/new")"
touch "$tmp/notrun"; chmod +x "$tmp/notrun"
check "which_program: the seam, when it is set" "$W/stubs/ifconfig" "$(eval "$wp_def"; which_program "$W/stubs/ifconfig" "$tmp/notrun" ifconfig 2>&1)"
check "which_program: else the absolute path, where it is" "$tmp/notrun" "$(eval "$wp_def"; which_program "" "$tmp/notrun" ifconfig 2>&1)"
check "which_program: else the name, for the PATH" ifconfig "$(eval "$wp_def"; which_program "" "$tmp/not-there" ifconfig 2>&1)"

check "no tripwire was ever reached (ifconfig, lsof, launchctl, sudo, security, npm, wrangler by name)" "" "$(cat "$tmp/tripped" 2>/dev/null)"
exit "$fail"
