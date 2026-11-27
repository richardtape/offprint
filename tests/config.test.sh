#!/usr/bin/env bash
# Tests lib/config.php (the site.json validator) and lib/site.sh (the loader scripts source).
# Run: bash tests/config.test.sh. Works on macOS (bash 3.2) and Linux. The shell-side cases run
# under the bash that runs this file and again under /bin/bash where that is a different one.
set -u
cd "$(dirname "$0")/.." || exit 1
root="$PWD"
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR), and TMPDIR
# inside it from here on, so nothing the suite runs leaves anything in the real one.
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-config-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
contains() {  # haystack, needle
  case "$1" in *"$2"*) return 0 ;; esac
  return 1
}
# physical LIST: each entry of the colon-separated LIST as the folder it is on disk (cd -P), in order: what lib/site.sh
# keeps on the PATH for it (on Linux, /bin is a link to /usr/bin; on macOS, the suite's own folder is reached through
# /var, a link to /private/var)
physical() {
  local rest="$1:" e out=""
  while [ -n "$rest" ]; do e="${rest%%:*}"; rest="${rest#*:}"; out="${out:+$out:}$(cd -P -- "$e" && pwd -P)"; done
  printf '%s' "$out"
}

TAB="$(printf '\t')"
n=0
newsite() { n=$((n + 1)); site="$tmp/s$n"; mkdir -p "$site"; }
# put JSON text (printf %b-free: written exactly as given) into the site folder
put() { printf '%s' "$1" > "$site/site.json"; }
run() { out="$(php "$root/lib/config.php" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"; }
base='"format":1,"name":"example","public_url":"https://www.example.com","local_ip4":"127.0.0.9","local_ip6":"fd00::9","tls_port":4999,"http_port":4998'
with() { put "{$base,$1}"; }                 # base plus extra members
without() {                                    # base minus one member, plus extra members
  local b="$base"
  case "$1" in
    name) b="${b/\"name\":\"example\",/}" ;;
    public_url) b="${b/\"public_url\":\"https:\/\/www.example.com\",/}" ;;
    local_ip4) b="${b/\"local_ip4\":\"127.0.0.9\",/}" ;;
    local_ip6) b="${b/\"local_ip6\":\"fd00::9\",/}" ;;
    tls_port) b="${b/\"tls_port\":4999,/}" ;;
    http_port) b="${b/,\"http_port\":4998/}" ;;
    format) b="${b/\"format\":1,/}" ;;
  esac
  put "{$b}"
}
refused() {  # description, field expected in the message; the site.json is already written
  run
  if [ "$code" -eq 2 ] && [ -z "$out" ] && contains "$err" "site.json: \"$2\""; then ok "refused: $1"; else bad "refused: $1 (exit $code, out: $out, err: $err)"; fi
}
refused_text() {  # description, exact text expected somewhere in stderr
  run
  if [ "$code" -eq 2 ] && [ -z "$out" ] && contains "$err" "$2"; then ok "refused: $1"; else bad "refused: $1 (exit $code, out: $out, err: $err)"; fi
}
loads() {  # description, expected KEY=value pairs as "KEY<TAB>value" lines in $3
  run
  if [ "$code" -eq 0 ] && [ -z "$err" ] && [ "$out" = "$2" ]; then ok "loads: $1"; else bad "loads: $1 (exit $code, out: $out, err: $err)"; fi
}

# ---- config.php ----------------------------------------------------------------------------
expected_fixture="SITE_NAME${TAB}example
SITE_PUBLIC_URL${TAB}https://www.example.com
SITE_PUBLIC_HOST${TAB}www.example.com
SITE_LOCAL_HOST${TAB}mysite.test
SITE_IP4${TAB}127.0.0.9
SITE_IP6${TAB}fd00::9
SITE_TLS_PORT${TAB}4999
SITE_HTTP_PORT${TAB}4998
SITE_AGENT_LABEL${TAB}local.offprint.example.publish
SITE_DAEMON_PREFIX${TAB}local.offprint.example"
expected_all="$expected_fixture
SITE_BACKUP_RECIPIENTS${TAB}age1$(printf 'q%.0s' $(seq 1 58))
SITE_BACKUP_TO${TAB}repo
ADAPTER_NAME${TAB}none"
site="$root/tests/fixtures"; run
if [ "$code" -eq 0 ] && [ -z "$err" ] && [ "$out" = "$expected_all" ]; then ok "the fixture loads and prints exactly the ten keys, its backup's two, then ADAPTER_NAME none, in order"; else bad "fixture (exit $code, out: $out, err: $err)"; fi
php "$root/lib/config.php" "$site" 2>/dev/null | od -c | grep -q '\\r' && bad "no carriage returns in output" || ok "no carriage returns in output"

newsite; with '"local_host":"blog.test"'; loads "an explicit local_host" "$(printf '%s' "$expected_all" | sed "s/mysite.test/blog.test/" | grep -v '^SITE_BACKUP_')"
newsite; put "{${base/\"example\"/\"abc\"}}"
run
if [ "$code" -eq 0 ] && contains "$out" "SITE_NAME${TAB}abc" && contains "$out" "SITE_AGENT_LABEL${TAB}local.offprint.abc.publish" && contains "$out" "SITE_DAEMON_PREFIX${TAB}local.offprint.abc" && contains "$out" "SITE_LOCAL_HOST${TAB}wp.local"; then ok "defaults: name 'abc' gives the default labels and wp.local"; else bad "default labels ($out / $err)"; fi
newsite; with '"local_host":"a.b","agent_label":"My.Label-1","daemon_prefix":"Pre.fix"'
run
if [ "$code" -eq 0 ] && contains "$out" "SITE_AGENT_LABEL${TAB}My.Label-1" && contains "$out" "SITE_DAEMON_PREFIX${TAB}Pre.fix" && contains "$out" "SITE_LOCAL_HOST${TAB}a.b"; then ok "explicit agent_label and daemon_prefix are used"; else bad "explicit labels ($out / $err)"; fi
newsite; put '{"format":1,"name":"a","public_url":"https://x.y","local_ip4":"127.0.0.2","local_ip6":"fdab:1:2:3::ffff","tls_port":1024,"http_port":65535}'
run
if [ "$code" -eq 0 ] && contains "$out" "SITE_LOCAL_HOST${TAB}wp.local" && contains "$out" "SITE_AGENT_LABEL${TAB}local.offprint.a.publish" && contains "$out" "SITE_DAEMON_PREFIX${TAB}local.offprint.a" && contains "$out" "SITE_TLS_PORT${TAB}1024" && contains "$out" "SITE_HTTP_PORT${TAB}65535"; then ok "defaults: local_host wp.local, labels from the name; port edges 1024 and 65535 pass"; else bad "defaults ($out / $err)"; fi

# local_host
newsite; with '"local_host":"a.b;id"';        refused "local_host a.b;id" local_host
newsite; with '"local_host":"a b.c"';         refused "local_host with a space" local_host
newsite; with '"local_host":"a.b\nc.d"';      refused "local_host with an escaped newline" local_host
newsite; with '"local_host":"$(id).x"';       refused "local_host \$(id).x" local_host
newsite; with '"local_host":"a\".b"';         refused "local_host with a double quote" local_host
newsite; with '"local_host":"a.b\n"';         refused "local_host with a trailing newline" local_host
newsite; with '"local_host":"Foo.Test"';      refused "local_host in capitals" local_host
newsite; with '"local_host":"localhost"';     refused "local_host without a dot" local_host
newsite; with '"local_host":"www.example.com"'; refused "local_host equal to the public host" local_host
newsite; with "\"local_host\":\"a.$(printf 'b%.0s' $(seq 1 64))\""; refused "a 64-character label" local_host
newsite; with "\"local_host\":\"a.$(printf 'b%.0s' $(seq 1 63))\""
run; if [ "$code" -eq 0 ]; then ok "a 63-character label passes"; else bad "63-char label ($err)"; fi
long="$(printf 'abcdefghi.%.0s' $(seq 1 26))com"   # 26*10+3 = 263 chars
newsite; with "\"local_host\":\"$long\""; refused "a hostname over 253 characters" local_host
newsite; with '"local_host":5';              refused "local_host not a string" local_host
newsite; with '"local_host":null';           refused "local_host null" local_host
# public_url
newsite; put "{${base/https:\/\/www.example.com/http://x.y}}";        refused "public_url http://" public_url
newsite; put "{${base/https:\/\/www.example.com/https://x.y/}}";      refused "public_url trailing slash" public_url
newsite; put "{${base/https:\/\/www.example.com/https://x.y/blog}}";  refused "public_url with a path" public_url
newsite; put "{${base/https:\/\/www.example.com/https://x.y:8443}}";  refused "public_url with a port" public_url
newsite; put "{${base/https:\/\/www.example.com/https://X.y}}";       refused "public_url in capitals" public_url
newsite; put "{${base/https:\/\/www.example.com/https://x}}";         refused "public_url without a dot" public_url
newsite; put "{${base/https:\/\/www.example.com/https://x.y\\n}}";    refused "public_url with a trailing newline" public_url
newsite; without public_url;                  refused "public_url missing" public_url
# ports
newsite; put "{${base/\"tls_port\":4999/\"tls_port\":\"4643\"}}";     refused "tls_port as a string" tls_port
newsite; put "{${base/\"tls_port\":4999/\"tls_port\":80}}";           refused "tls_port 80" tls_port
newsite; put "{${base/\"tls_port\":4999/\"tls_port\":70000}}";        refused "tls_port 70000" tls_port
newsite; put "{${base/\"tls_port\":4999/\"tls_port\":1023}}";         refused "tls_port 1023" tls_port
newsite; put "{${base/\"tls_port\":4999/\"tls_port\":65536}}";        refused "tls_port 65536" tls_port
newsite; put "{${base/\"tls_port\":4999/\"tls_port\":4999.0}}";       refused "tls_port 4999.0" tls_port
newsite; put "{${base/\"tls_port\":4999/\"tls_port\":true}}";         refused "tls_port true" tls_port
newsite; put "{${base/\"http_port\":4998/\"http_port\":\"4998\"}}";   refused "http_port as a string" http_port
newsite; put "{${base/\"http_port\":4998/\"http_port\":4999}}";       refused "equal ports" http_port
newsite; without tls_port;                    refused "tls_port missing" tls_port
newsite; without http_port;                   refused "http_port missing" http_port
# local_ip4
newsite; put "{${base/127.0.0.9/127.0.0.1}}";   refused "local_ip4 127.0.0.1" local_ip4
newsite; put "{${base/127.0.0.9/10.0.0.1}}";    refused "local_ip4 10.0.0.1" local_ip4
newsite; put "{${base/127.0.0.9/127.0.0.256}}"; refused "local_ip4 127.0.0.256" local_ip4
newsite; put "{${base/127.0.0.9/127.0.0.06}}";  refused "local_ip4 with a leading zero" local_ip4
newsite; put "{${base/127.0.0.9/127.0.0}}";     refused "local_ip4 with three parts" local_ip4
newsite; put "{${base/127.0.0.9/127.0.0.9\\n}}"; refused "local_ip4 with a trailing newline" local_ip4
newsite; put "{${base/\"127.0.0.9\"/9}}";       refused "local_ip4 not a string" local_ip4
newsite; without local_ip4;                     refused "local_ip4 missing" local_ip4
# local_ip6
newsite; put "{${base/fd00::9/fe80::9}}";       refused "local_ip6 not fdXX" local_ip6
newsite; put "{${base/fd00::9/fd00::}}";        refused "local_ip6 without a final group" local_ip6
newsite; put "{${base/fd00::9/FD00::9}}";       refused "local_ip6 in capitals" local_ip6
newsite; put "{${base/fd00::9/fd00::9\\n}}";    refused "local_ip6 with a trailing newline" local_ip6
newsite; put "{${base/fd00::9/fd00:1:2:3:4:5:6:7::9}}"; refused "local_ip6 too many groups" local_ip6
newsite; put "{${base/fd00::9/fd00:1:2:3:4:5:6::9}}"
refused_text "local_ip6 the regex allows but PHP rejects (filter_var)" 'site.json: "local_ip6" is not a valid IPv6 address'
newsite; put "{${base/fd00::9/fd00::0}}"
refused_text "local_ip6 fd00::0 is not canonical" 'site.json: "local_ip6" must be written in canonical form; use fd00:: instead of fd00::0'
newsite; put "{${base/fd00::9/fd00:0000:0:0::1}}"
refused_text "local_ip6 fd00:0000:0:0::1 is not canonical" 'canonical form; use fd00::1 instead of fd00:0000:0:0::1'
newsite; put "{${base/fd00::9/fd12:3456:789a::6}}"
run; if [ "$code" -eq 0 ] && contains "$out" "SITE_IP6${TAB}fd12:3456:789a::6"; then ok "local_ip6 fd12:3456:789a::6 is canonical and loads"; else bad "canonical ip6 ($out / $err)"; fi
newsite; without local_ip6;                     refused "local_ip6 missing" local_ip6
# name
newsite; put "{${base/\"example\"/\"Example\"}}";   refused "name in capitals" name
newsite; put "{${base/\"example\"/\"1abc\"}}";      refused "name starting with a digit" name
newsite; put "{${base/\"example\"/\"a_b\"}}";       refused "name with an underscore" name
newsite; put "{${base/\"example\"/\"a;id\"}}";      refused "name with a semicolon" name
newsite; put "{${base/\"example\"/\"a\\n\"}}";      refused "name with a trailing newline" name
newsite; put "{${base/\"example\"/\"offprint-e2e\"}}"; refused "name offprint-e2e" name
newsite; put "{${base/\"example\"/\"a$(printf 'b%.0s' $(seq 1 31))\"}}"; refused "name of 32 characters" name
newsite; put "{${base/\"example\"/\"a$(printf 'b%.0s' $(seq 1 30))\"}}"
run; if [ "$code" -eq 0 ]; then ok "a name of 31 characters passes"; else bad "31-char name ($err)"; fi
newsite; without name;                          refused "name missing" name
# agent_label, daemon_prefix
newsite; with '"agent_label":"-x"';             refused "agent_label starting with a dash" agent_label
newsite; with '"agent_label":"a b"';            refused "agent_label with a space" agent_label
newsite; with '"agent_label":"a\n"';            refused "agent_label with a trailing newline" agent_label
newsite; with '"agent_label":"a<x"';            refused "agent_label with an angle bracket" agent_label
newsite; with "\"agent_label\":\"a$(printf 'b%.0s' $(seq 1 100))\""; refused "agent_label of 101 characters" agent_label
newsite; with '"daemon_prefix":"a/b"';          refused "daemon_prefix with a slash" daemon_prefix
newsite; with '"daemon_prefix":""';             refused "daemon_prefix empty" daemon_prefix
newsite; with '"daemon_prefix":7';              refused "daemon_prefix not a string" daemon_prefix
# format
newsite; put "{${base/\"format\":1/\"format\":2}}"
refused_text "format 2 gets the upgrade message" 'site.json: "format" is 2, newer than this Offprint understands (1); upgrade Offprint.'
newsite; put "{${base/\"format\":1/\"format\":0}}";   refused "format 0" format
newsite; put "{${base/\"format\":1/\"format\":1.0}}"; refused "format 1.0" format
newsite; put "{${base/\"format\":1/\"format\":\"1\"}}"; refused "format \"1\"" format
newsite; put "{${base/\"format\":1/\"format\":true}}"; refused "format true" format
newsite; without format;                              refused "format missing" format
# shape of the file
newsite; with '"colour":"red"';                 refused "an unknown key" colour
newsite; put '[]';                              refused_text "a JSON array" 'must be a JSON object'
newsite; put '{}';                              refused "an empty object" format
newsite; put '"x"';                             refused_text "a JSON string" 'must be a JSON object'
newsite; put '';                                refused_text "an empty file" 'site.json:'
newsite; put '{"format":1,';                    refused_text "invalid JSON" 'site.json:'
newsite; put "{$base,\"name\":\"other\"}";      refused "a duplicate key" name
newsite; put "{$base,\"na\\u006de\":\"other\"}"; refused "a duplicate key spelt with an escape" name
newsite; put "{$base,\"format\":1}";            refused "a duplicate format" format
newsite; put "{$base,\"x\":{\"a\":1,\"a\":2}}"; refused_text "a duplicate key in a nested object" 'site.json: "a" appears more than once'
newsite; put "{$base,\"name\":\"example\"} "
run; if [ "$code" -eq 2 ]; then ok "refused: a duplicate key even when the values are equal and trailing space follows"; else bad "equal duplicate"; fi
newsite; put "  {$base}
"
run; if [ "$code" -eq 0 ]; then ok "leading and trailing white space is fine"; else bad "white space ($err)"; fi
newsite; put "{$base,\"agent_label\":\"{,\\\"name\\\":\\\"x\\\"}\"}"
refused "braces and quotes inside a string value do not confuse the key scan" agent_label
if ! contains "$err" 'appears more than once'; then ok "no false duplicate from braces and quotes inside a string value"; else bad "false duplicate ($err)"; fi
newsite; with '"agent_label":"name","daemon_prefix":"format"'
run; if [ "$code" -eq 0 ] && contains "$out" "SITE_AGENT_LABEL${TAB}name"; then ok "a string value equal to a key name is not a duplicate key"; else bad "value equal to a key name ($out / $err)"; fi
# adapter block
newsite; with '"adapter":{"name":"example-host","account_id":"0123456789abcdef","retries":3}'
loads "an adapter block: name and two settings, in the file's order" "${expected_fixture/mysite.test/wp.local}
ADAPTER_NAME${TAB}example-host
ADAPTER_SET_ACCOUNT_ID${TAB}0123456789abcdef
ADAPTER_SET_RETRIES${TAB}3"
newsite; with '"adapter":{"name":"example-host"}'
loads "an adapter block with no settings" "${expected_fixture/mysite.test/wp.local}
ADAPTER_NAME${TAB}example-host"
newsite; with '"adapter":{"name":"a","k":"A-z0-9._:/@+=-","n":0,"m":2147483647}'
run; if [ "$code" -eq 0 ] && contains "$out" "ADAPTER_SET_K${TAB}A-z0-9._:/@+=-" && contains "$out" "ADAPTER_SET_N${TAB}0" && contains "$out" "ADAPTER_SET_M${TAB}2147483647"; then ok "adapter value edges: every allowed character, 0 and 2147483647"; else bad "adapter edges ($out / $err)"; fi
site="$root/tests/fixtures"; run   # (what config.php prints for the fixture, which has no adapter block)
if [ "$code" -eq 0 ] && ! contains "$out" "ADAPTER_SET_" && [ "$(printf '%s\n' "$out" | tail -n 1)" = "ADAPTER_NAME${TAB}none" ]; then
  ok "no adapter block: config.php prints no ADAPTER_SET_ line, and ADAPTER_NAME none last"
else bad "no adapter block (exit $code, out: $out, err: $err)"; fi
newsite; with '"adapter":"x"';                          refused "an adapter that is not an object" adapter
newsite; with '"adapter":[]';                           refused "an adapter that is a list" adapter
newsite; with '"adapter":{}';                           refused "an adapter with no name" adapter.name
newsite; with '"adapter":{"name":3}';                   refused "an adapter name that is not a string" adapter.name
newsite; with '"adapter":{"name":"Bad"}';               refused "an adapter name with a capital" adapter.name
newsite; with '"adapter":{"name":"1x"}';                refused "an adapter name starting with a digit" adapter.name
newsite; with '"adapter":{"name":"a_b"}';               refused "an adapter name with an underscore" adapter.name
newsite; with '"adapter":{"name":"a\n"}';               refused "an adapter name with a trailing newline" adapter.name
newsite; with "\"adapter\":{\"name\":\"a$(printf 'b%.0s' $(seq 1 41))\"}"; refused "an adapter name of 42 characters" adapter.name
newsite; with "\"adapter\":{\"name\":\"a$(printf 'b%.0s' $(seq 1 40))\"}"; run
if [ "$code" -eq 0 ]; then ok "an adapter name of 41 characters is fine"; else bad "41-char adapter name ($err)"; fi
newsite; with '"adapter":{"name":"x","a":{"b":"c"}}';   refused "a nested adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":["b"]}';       refused "a list adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":true}';        refused "a boolean adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":null}';        refused "a null adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":1.5}';         refused "a float adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":1.0}';         refused "a float 1.0 adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":-1}';          refused "a negative adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":2147483648}';  refused "an adapter setting over 2147483647" adapter.a
newsite; with '"adapter":{"name":"x","a":""}';          refused "an empty adapter setting" adapter.a
newsite; with '"adapter":{"name":"x","a":"a b"}';       refused "an adapter setting with a space" adapter.a
newsite; with '"adapter":{"name":"x","a":"a;b"}';       refused "an adapter setting with a semicolon" adapter.a
newsite; with '"adapter":{"name":"x","a":"ab\n"}';      refused "an adapter setting with a trailing newline" adapter.a
newsite; with "\"adapter\":{\"name\":\"x\",\"a\":\"$(printf 'b%.0s' $(seq 1 201))\"}"; refused "an adapter setting of 201 characters" adapter.a
newsite; with "\"adapter\":{\"name\":\"x\",\"a\":\"$(printf 'b%.0s' $(seq 1 200))\"}"; run
if [ "$code" -eq 0 ]; then ok "an adapter setting of 200 characters is fine"; else bad "200-char adapter setting ($err)"; fi
newsite; with '"adapter":{"name":"x","A":"b"}';         refused "an adapter key with a capital" adapter.A
newsite; with '"adapter":{"name":"x","_a":"b"}';        refused "an adapter key starting with an underscore" adapter._a
newsite; with '"adapter":{"name":"x","a-b":"b"}';       refused "an adapter key with a dash" adapter.a-b
newsite; with '"adapter":{"name":"x","a\n":"b"}';       refused "an adapter key with a newline" adapter.a?
newsite; with "\"adapter\":{\"name\":\"x\",\"a$(printf 'b%.0s' $(seq 1 41))\":\"b\"}"; refused_text "an adapter key of 42 characters" 'site.json: "adapter.'
newsite; ks=""; for i in $(seq 1 21); do ks="$ks,\"k$i\":\"v\""; done; with "\"adapter\":{\"name\":\"x\"$ks}"
refused_text "21 adapter settings" 'site.json: "adapter" has more than 20 settings.'
newsite; ks=""; for i in $(seq 1 20); do ks="$ks,\"k$i\":\"v\""; done; with "\"adapter\":{\"name\":\"x\"$ks}"; run
if [ "$code" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^ADAPTER_SET_')" -eq 20 ]; then ok "20 adapter settings are fine"; else bad "20 adapter settings ($err)"; fi
newsite; with '"adapter":{"name":"x","name":"y"}';      refused_text "a key named name twice in the adapter block" 'site.json: "adapter.name" appears more than once'
newsite; with '"adapter":{"name":"x","a":"1","a":"2"}'; refused_text "an adapter setting twice" 'site.json: "adapter.a" appears more than once'
newsite; with '"adapter":{"name":"x","a":"b"},"adapter":{"name":"y"}'; refused "the adapter block twice" adapter
newsite; with '"adapter":{"name":"x","a":"{\"name\":}"},"name":"other"'
refused_text "a top-level duplicate name after an adapter block is reported unprefixed" 'site.json: "name" appears more than once'
if ! contains "$err" 'adapter.name'; then ok "a top-level duplicate name is not attributed to the adapter"; else bad "top-level dup prefixed ($err)"; fi
newsite; with '"adapter":{"name":"x","a":"b"},"x":{"a":1,"a":2}'
refused_text "a duplicate in an object after the adapter block stays unprefixed" 'site.json: "a" appears more than once'
newsite; with '"y":[{"a":1,"a":2}],"adapter":{"name":"x"}'
refused_text "a duplicate in an array of objects before the adapter block stays unprefixed" 'site.json: "a" appears more than once'
newsite; with '"adapter":{"name":"x","a":"b"},"adapter":{"name":"y"}'
refused_text "the adapter key twice is reported as adapter" 'site.json: "adapter" appears more than once'
newsite; with '"adapter":{"name":"x","a":"b"},"colour":{"name":1}'
if ! contains "$(php "$root/lib/config.php" "$site" 2>&1)" 'more than once'; then ok "same key names in other objects are not duplicates of the adapter's"; else bad "false duplicate across objects"; fi
# the deferred case from step 1: an escaped quote inside a string value, then a real duplicate key
newsite; put "{$base,\"agent_label\":\"a\\\"b\",\"name\":\"other\"}"
refused_text "a string value with an escaped quote, then a real duplicate key" 'site.json: "name" appears more than once'
newsite; put "{$base,\"adapter\":{\"name\":\"x\",\"a\":\"b\\\"c\",\"name\":\"y\"}}"
refused_text "an escaped quote in an adapter value, then name twice" 'site.json: "adapter.name" appears more than once'

# backup block: the age public keys the database backup is encrypted to, and where it is sent
Q62="age1$(printf 'q%.0s' $(seq 1 58))"; P62="age1$(printf 'p%.0s' $(seq 1 58))"
backup_lines() { printf '%s' "${expected_fixture/mysite.test/wp.local}
SITE_BACKUP_RECIPIENTS${TAB}$1
SITE_BACKUP_TO${TAB}repo
ADAPTER_NAME${TAB}none"; }
newsite; with "\"backup\":{\"recipients\":[\"$Q62\"]}"
loads "a backup block with one recipient: the two backup lines after the ten, to repo by default" "$(backup_lines "$Q62")"
newsite; with "\"backup\":{\"recipients\":[\"$Q62\",\"$P62\"],\"to\":\"repo\"}"
loads "a backup block with two recipients and to repo: both, in the file's order, on one line" "$(backup_lines "$Q62 $P62")"
newsite; put "{$base}"; run
if [ "$code" -eq 0 ] && ! contains "$out" "SITE_BACKUP_"; then ok "no backup block: config.php prints no SITE_BACKUP_ line"; else bad "no backup block (exit $code, out: $out, err: $err)"; fi
backup_msg='site.json: "backup" must be an object with "recipients".'
list_msg='site.json: "backup.recipients" must be a list of one or two age public keys.'
key_msg='site.json: "backup.recipients" must be a list of one or two age public keys (each age1 and 58 more characters).'
newsite; with '"backup":"yes"';                          refused_text "a backup that is a string" "$backup_msg"
newsite; with '"backup":[]';                             refused_text "a backup that is a list" "$backup_msg"
newsite; with '"backup":{}';                             refused_text "a backup with no recipients" "$list_msg"
newsite; with '"backup":{"recipients":[]}';              refused_text "an empty list of recipients" "$list_msg"
newsite; with "\"backup\":{\"recipients\":\"$Q62\"}"; refused_text "recipients that is a string, not a list" "$list_msg"
newsite; with "\"backup\":{\"recipients\":{\"a\":\"$Q62\"}}"; refused_text "recipients that is an object" "$list_msg"
newsite; with "\"backup\":{\"recipients\":[\"$Q62\",\"$P62\",\"age1$(printf 'z%.0s' $(seq 1 58))\"]}"; refused_text "three recipients" "$list_msg"
newsite; with '"backup":{"recipients":["age1short"]}';   refused_text "a recipient that is too short" "$key_msg"
newsite; with "\"backup\":{\"recipients\":[\"${Q62}q\"]}"; refused_text "a recipient one character too long" "$key_msg"
newsite; with "\"backup\":{\"recipients\":[\"AGE1$(printf 'Q%.0s' $(seq 1 58))\"]}"; refused_text "a recipient in capitals" "$key_msg"
newsite; with "\"backup\":{\"recipients\":[\"age1$(printf 'b%.0s' $(seq 1 58))\"]}"; refused_text "a recipient with a letter the encoding never uses (b)" "$key_msg"
newsite; with "\"backup\":{\"recipients\":[\"$Q62\\n\"]}"; refused_text "a recipient with a trailing newline" "$key_msg"
newsite; with '"backup":{"recipients":[7]}';             refused_text "a recipient that is a number" "$key_msg"
newsite; with "\"backup\":{\"recipients\":[\"$Q62\",null]}"; refused_text "a second recipient that is null" "$key_msg"
# A private key pasted where the public one belongs: refused, and never repeated (the message goes to a terminal, a log
# and var/status.json).
secret="AGE-SECRET-KEY-1$(printf 'Q%.0s' $(seq 1 58))"
newsite; with "\"backup\":{\"recipients\":[\"$secret\"]}"; refused_text "a private key given as a recipient" "$key_msg"
if ! contains "$err$out" "AGE-SECRET-KEY"; then ok "a private key given as a recipient is not repeated in the message"; else bad "a private key was echoed ($err)"; fi
newsite; with "\"backup\":{\"recipients\":[\"$Q62\",\"$Q62\"]}"; refused_text "the same recipient twice" 'site.json: "backup.recipients" names the same key twice.'
newsite; with "\"backup\":{\"recipients\":[\"$Q62\"],\"to\":\"elsewhere\"}"; refused_text "a destination that isn't repo" 'site.json: "backup.to" must be "repo".'
newsite; with "\"backup\":{\"recipients\":[\"$Q62\"],\"to\":3}"; refused_text "a destination that is a number" 'site.json: "backup.to" must be "repo".'
newsite; with "\"backup\":{\"recipients\":[\"$Q62\"],\"colour\":1}"; refused_text "an unknown key in the backup block" 'site.json: "backup.colour" is not a known field.'
newsite; with "\"backup\":{\"recipients\":[\"$Q62\"],\"recipients\":[\"$P62\"]}"; refused_text "recipients twice in the backup block" 'site.json: "backup.recipients" appears more than once'
newsite; with "\"backup\":{\"recipients\":[\"$Q62\"]},\"adapter\":{\"name\":\"x\",\"recipients\":\"a\",\"recipients\":\"b\"}"
refused_text "a duplicate in the adapter block after a backup block is still named with adapter" 'site.json: "adapter.recipients" appears more than once'
newsite; with "\"backup\":{\"recipients\":[\"$Q62\"]},\"backup\":{\"recipients\":[\"$P62\"]}"; refused_text "the backup key twice" 'site.json: "backup" appears more than once'
# pigeonhole block: the path comments are posted to, and the age public keys they are encrypted to in the browser
pigeonhole_lines() { printf '%s' "${expected_fixture/mysite.test/wp.local}
SITE_PIGEONHOLE_PATH${TAB}$1
SITE_PIGEONHOLE_RECIPIENTS${TAB}$2
ADAPTER_NAME${TAB}none"; }
newsite; with "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"]}"
loads "a pigeonhole block with one recipient: its two lines after the ten" "$(pigeonhole_lines /_pigeonhole "$Q62")"
newsite; with "\"pigeonhole\":{\"path\":\"/drop-box_2\",\"recipients\":[\"$Q62\",\"$P62\"]}"
loads "a pigeonhole block with two recipients: both, in the file's order, on one line" "$(pigeonhole_lines /drop-box_2 "$Q62 $P62")"
newsite; with "\"backup\":{\"recipients\":[\"$P62\"]},\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"]},\"adapter\":{\"name\":\"x\"}"
run
if [ "$code" -eq 0 ] && [ "$(printf '%s\n' "$out" | sed -n '11,15p' | cut -f1 | tr '\n' ' ')" = "SITE_BACKUP_RECIPIENTS SITE_BACKUP_TO SITE_PIGEONHOLE_PATH SITE_PIGEONHOLE_RECIPIENTS ADAPTER_NAME " ]; then ok "with a backup and an adapter: the backup's lines, then the pigeonhole's, then the adapter's"; else bad "pigeonhole order (exit $code, out: $out, err: $err)"; fi
newsite; put "{$base}"; run
if [ "$code" -eq 0 ] && ! contains "$out" "SITE_PIGEONHOLE_"; then ok "no pigeonhole block: config.php prints no SITE_PIGEONHOLE_ line"; else bad "no pigeonhole block (exit $code, out: $out, err: $err)"; fi
ph_msg='site.json: "pigeonhole" must be an object with "path" and "recipients".'
ph_path_msg='site.json: "pigeonhole.path" must be a slash and one name of 1 to 40 lowercase letters, digits, dashes and underscores, like /_pigeonhole.'
ph_list_msg='site.json: "pigeonhole.recipients" must be a list of one or two age public keys.'
ph_key_msg='site.json: "pigeonhole.recipients" must be a list of one or two age public keys (each age1 and 58 more characters).'
ph() { with "\"pigeonhole\":{\"path\":$1,\"recipients\":$2}"; }
newsite; with '"pigeonhole":"yes"';                      refused_text "a pigeonhole that is a string" "$ph_msg"
newsite; with '"pigeonhole":[]';                         refused_text "a pigeonhole that is a list" "$ph_msg"
newsite; with '"pigeonhole":{}';                         refused_text "a pigeonhole with nothing in it: the path is asked for" 'site.json: "pigeonhole.path" is required.'
if contains "$err" "$ph_list_msg"; then ok "... and the recipients, in the same run"; else bad "empty pigeonhole: recipients not asked for ($err)"; fi
newsite; with "\"pigeonhole\":{\"recipients\":[\"$Q62\"]}"; refused_text "a pigeonhole with no path" 'site.json: "pigeonhole.path" is required.'
newsite; with '"pigeonhole":{"path":"/_pigeonhole"}';    refused_text "a pigeonhole with no recipients" "$ph_list_msg"
for p in '"_pigeonhole"' '"/"' '""' '"/a/b"' '"/a/"' '"//a"' '"/Drop"' '"/a b"' '"/a.b"' '"/a?b"' '"/a#b"' '"/%2e"' '"/.."' '"/a\n"' '"/a\u0000"' "\"/$(printf 'a%.0s' $(seq 1 41))\"" '7' 'null' '["/a"]' '"https://www.example.com/a"'; do
  newsite; ph "$p" "[\"$Q62\"]"; refused_text "a pigeonhole path of $(printf '%s' "$p" | cut -c1-24)" "$ph_path_msg"
done
newsite; ph "\"/$(printf 'a%.0s' $(seq 1 40))\"" "[\"$Q62\"]"; run
if [ "$code" -eq 0 ]; then ok "a pigeonhole path of 40 characters after the slash is allowed"; else bad "40-character path ($err)"; fi
newsite; ph '"/_pigeonhole"' '[]';                        refused_text "pigeonhole: an empty list of recipients" "$ph_list_msg"
newsite; ph '"/_pigeonhole"' "\"$Q62\"";                  refused_text "pigeonhole: recipients that is a string" "$ph_list_msg"
newsite; ph '"/_pigeonhole"' "{\"a\":\"$Q62\"}";          refused_text "pigeonhole: recipients that is an object" "$ph_list_msg"
newsite; ph '"/_pigeonhole"' "[\"$Q62\",\"$P62\",\"age1$(printf 'z%.0s' $(seq 1 58))\"]"; refused_text "pigeonhole: three recipients" "$ph_list_msg"
newsite; ph '"/_pigeonhole"' '["age1short"]';             refused_text "pigeonhole: a recipient that is too short" "$ph_key_msg"
newsite; ph '"/_pigeonhole"' "[\"${Q62}q\"]";             refused_text "pigeonhole: a recipient one character too long" "$ph_key_msg"
newsite; ph '"/_pigeonhole"' "[\"$Q62\\n\"]";             refused_text "pigeonhole: a recipient with a trailing newline" "$ph_key_msg"
newsite; ph '"/_pigeonhole"' '[7]';                       refused_text "pigeonhole: a recipient that is a number" "$ph_key_msg"
newsite; ph '"/_pigeonhole"' "[\"$Q62\",null]";           refused_text "pigeonhole: a second recipient that is null" "$ph_key_msg"
# A private key pasted where the public one belongs: refused, and never repeated. Here it would be worse than in the
# backup's block: these keys are printed into every page of the public site.
newsite; ph '"/_pigeonhole"' "[\"$secret\"]";             refused_text "pigeonhole: a private key given as a recipient" "$ph_key_msg"
if ! contains "$err$out" "AGE-SECRET-KEY"; then ok "pigeonhole: a private key given as a recipient is not repeated in the message"; else bad "pigeonhole: a private key was echoed ($err)"; fi
newsite; ph '"/_pigeonhole"' "[\"$Q62\",\"$Q62\"]";       refused_text "pigeonhole: the same recipient twice" 'site.json: "pigeonhole.recipients" names the same key twice.'
newsite; with "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"],\"colour\":1}"; refused_text "an unknown key in the pigeonhole block" 'site.json: "pigeonhole.colour" is not a known field.'
newsite; with "\"pigeonhole\":{\"path\":\"/a\",\"path\":\"/b\",\"recipients\":[\"$Q62\"]}"; refused_text "path twice in the pigeonhole block" 'site.json: "pigeonhole.path" appears more than once'
newsite; with "\"pigeonhole\":{\"path\":\"/a\",\"recipients\":[\"$Q62\"]},\"pigeonhole\":{\"path\":\"/b\",\"recipients\":[\"$Q62\"]}"; refused_text "the pigeonhole key twice" 'site.json: "pigeonhole" appears more than once'
# the pigeonhole's server: where the Mac fetches from. Four fields, all or none, each held to one way of writing it; both
# host keys are pinned here and never learnt, so nothing loose may pass for one.
HK1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'A%.0s' $(seq 1 43))"
HK2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'B%.0s' $(seq 1 43))"
phs() { with "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"]$1}"; }
srv() { phs ",\"server\":${1:-\"10.0.0.5\"},\"server_host_key\":${2:-\"$HK1\"},\"jump\":${3:-\"192.0.2.10\"},\"jump_host_key\":${4:-\"$HK2\"}${5:-}"; }
server_lines() { printf '%s' "${expected_fixture/mysite.test/wp.local}
SITE_PIGEONHOLE_PATH${TAB}/_pigeonhole
SITE_PIGEONHOLE_RECIPIENTS${TAB}$Q62
SITE_PIGEONHOLE_SERVER${TAB}$1
SITE_PIGEONHOLE_SERVER_PORT${TAB}$2
SITE_PIGEONHOLE_SERVER_HOST_KEY${TAB}$HK1
SITE_PIGEONHOLE_JUMP${TAB}$3
SITE_PIGEONHOLE_JUMP_PORT${TAB}$4
SITE_PIGEONHOLE_JUMP_HOST_KEY${TAB}$HK2
SITE_PIGEONHOLE_STORE_PORT${TAB}$5
ADAPTER_NAME${TAB}none"; }
newsite; srv; loads "a pigeonhole with its server: seven more lines, the ports their defaults" "$(server_lines 10.0.0.5 22 192.0.2.10 22 8788)"
newsite; srv '' '' '' '' ',"server_port":2222,"jump_port":2200,"store_port":9000'
loads "a pigeonhole server with all three ports given" "$(server_lines 10.0.0.5 2222 192.0.2.10 2200 9000)"
newsite; srv '"fd00::5"' '' '"2001:db8::10"'; loads "a pigeonhole server and jump at IPv6 addresses" "$(server_lines fd00::5 22 2001:db8::10 22 8788)"
addr_msg() { printf 'site.json: "pigeonhole.%s" must be an address (IPv4 like 10.0.0.5, or IPv6 in its shortest lowercase form), not a name.' "$1"; }
for a in '"store.example.com"' '"localhost"' '"10.0.0.05"' '"10.0.0"' '"10.0.0.256"' '"10.0.0.5:22"' '"[fd00::5]"' '"FD00::5"' '"fd00:0::5"' '"fe80::1%en0"' '"::ffff:10.0.0.5"' '"10.0.0.5\n"' '"10.0.0.5 "' '"-oProxyCommand=x"' '""' '7' 'null' '["10.0.0.5"]'; do
  newsite; srv "$a"; refused_text "a pigeonhole server of $(printf '%s' "$a" | cut -c1-24)" "$(addr_msg server)"
  newsite; srv '' '' "$a"; refused_text "a pigeonhole jump of $(printf '%s' "$a" | cut -c1-24)" "$(addr_msg jump)"
done
key_msg_for() { printf 'site.json: "pigeonhole.%s" must be that machine'"'"'s Ed25519 host key, as ssh-ed25519, a space and its 68 characters, with nothing after them.' "$1"; }
rsa="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ$(printf 'A%.0s' $(seq 1 40))"
private="-----BEGIN OPENSSH PRIVATE KEY-----SECRETSECRET"
for k in "\"$HK1 root@store\"" "\"${HK1}A\"" "\"${HK1%A}\"" "\"${HK1%A}=\"" "\"$rsa\"" "\"${HK1#ssh-ed25519 }\"" "\"10.0.0.5 $HK1\"" "\"$HK1\\n\"" "\"$HK1\\n$HK2\"" "\"ssh-ed25519  ${HK1#ssh-ed25519 }\"" "\"$private\"" '""' '7' 'null' "[\"$HK1\"]"; do
  newsite; srv '' "$k"; refused_text "a pigeonhole server_host_key of $(printf '%s' "$k" | cut -c1-30)" "$(key_msg_for server_host_key)"
  newsite; srv '' '' '' "$k"; refused_text "a pigeonhole jump_host_key of $(printf '%s' "$k" | cut -c1-30)" "$(key_msg_for jump_host_key)"
done
newsite; srv '' "\"$private\""; run
if ! contains "$err$out" "SECRETSECRET"; then ok "pigeonhole: a private key given as a host key is not repeated in the message"; else bad "pigeonhole: a private key was echoed ($err)"; fi
for f in server server_host_key jump jump_host_key; do
  case "$f" in server) v='"10.0.0.5"' ;; jump) v='"192.0.2.10"' ;; *) v="\"$HK1\"" ;; esac
  newsite; phs ",\"$f\":$v"; run
  missing=0; for g in server server_host_key jump jump_host_key; do [ "$g" = "$f" ] || { contains "$err" "site.json: \"pigeonhole.$g\" is required when the block names its server" && missing=$((missing + 1)); }; done
  if [ "$code" -eq 2 ] && [ -z "$out" ] && [ "$missing" = 3 ]; then ok "refused: a pigeonhole with $f alone: the other three are asked for"; else bad "pigeonhole with $f alone (exit $code, out: $out, err: $err)"; fi
done
for f in server_port jump_port store_port; do
  case "$f" in store_port) least=1024; low=1023 ;; *) least=1; low=0 ;; esac
  for v in "$low" 65536 '"22"' 22.5 -1 null '[22]'; do
    newsite; srv '' '' '' '' ",\"$f\":$v"; refused_text "a pigeonhole $f of $v" "site.json: \"pigeonhole.$f\" must be a JSON integer from $least to 65535."
  done
  newsite; phs ",\"$f\":2222"; refused_text "a pigeonhole $f with no server named" "site.json: \"pigeonhole.$f\" is given, but the block names no server"
done
newsite; srv '"10.0.0.5"' '' '"10.0.0.5"'; refused_text "a pigeonhole whose jump is its server" 'site.json: "pigeonhole.jump" must be another machine than "pigeonhole.server"'
newsite; srv '"10.0.0.5"' '' '"10.0.0.5"' '' ',"jump_port":2200'; run
if [ "$code" -eq 0 ]; then ok "the same address at two ssh ports is two machines (a forwarded port): allowed"; else bad "same address, two ports ($err)"; fi
newsite; srv '' '' '' '' ',"server":"10.0.0.6"'; refused_text "server twice in the pigeonhole block" 'site.json: "pigeonhole.server" appears more than once'
newsite; srv '' '' '' '' ',"user":"root"'; refused_text "an unknown key beside the server's" 'site.json: "pigeonhole.user" is not a known field.'
newsite; with "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"]}"; run
if [ "$code" -eq 0 ] && ! contains "$out" "SITE_PIGEONHOLE_SERVER" && ! contains "$out" "SITE_PIGEONHOLE_JUMP" && ! contains "$out" "SITE_PIGEONHOLE_STORE_PORT"; then ok "a pigeonhole that names no server: none of the seven lines"; else bad "no server lines ($out)"; fi
newsite; put "{$base,\"pigeonhole\":{\"path\":\"/x\",\"recipients\":[7],\"server\":\"10.0.0.5\",\"server_host_key\":\"$HK1\",\"jump\":\"192.0.2.10\",\"jump_host_key\":\"$HK2\"}}"; run
if [ "$code" -eq 2 ] && [ -z "$out" ]; then ok "a good server beside bad recipients: nothing is printed"; else bad "server beside bad recipients (exit $code, out: $out)"; fi
newsite; put "{$base}"; head -c 70000 /dev/zero | tr '\0' ' ' >> "$site/site.json"
refused_text "a file over 64 KB" '64'
newsite; put "{$base}"; printf '\0' >> "$site/site.json"
refused_text "a NUL byte after the object" 'contains a NUL byte'
newsite; put "{$base,\"a\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}"
refused_text "nesting deeper than the limit" 'Maximum stack depth exceeded'
newsite; put "{$base}"; mv "$site/site.json" "$tmp/real.json"; ln -s "$tmp/real.json" "$site/site.json"
refused_text "a symlinked site.json" 'symlink'
newsite
refused_text "a missing site.json" 'site.json:'
newsite; mkdir "$site/site.json"
refused_text "site.json is a directory" 'site.json:'
# reporting all problems at once
newsite; put '{"format":1,"name":"A","public_url":"http://x","local_ip4":"1.2.3.4","local_ip6":"x","tls_port":1,"http_port":2,"colour":1}'
run
lines="$(printf '%s\n' "$err" | grep -c '^site.json: "')"
if [ "$code" -eq 2 ] && [ "$lines" -eq 7 ]; then ok "all problems are reported in one run, one per line"; else bad "all problems (exit $code, $lines lines: $err)"; fi
# usage
out="$(php "$root/lib/config.php" 2>&1)"; code=$?
if [ "$code" -eq 2 ] && contains "$out" "usage:"; then ok "no argument: usage, exit 2"; else bad "no argument ($code, $out)"; fi
out="$(php "$root/lib/config.php" "$tmp/nope" 2>&1)"; code=$?
if [ "$code" -eq 2 ] && contains "$out" "usage:"; then ok "not a directory: usage, exit 2"; else bad "not a directory ($code, $out)"; fi

# ---- lib/site.sh ---------------------------------------------------------------------------
shell_cases() {  # $1 = bash to test with
  local B="$1" t="$1"
  [ -x "$B" ] || { ok "($B not present, skipped)"; return; }
  local sh_out sh_code

  # offprint_find_site from a subfolder
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; mkdir -p "$site/a/b"
  want="$(cd "$site" && pwd -P)"
  sh_out="$(cd "$site/a/b" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$want" ]; then ok "[$t] offprint_find_site from a subfolder"; else bad "[$t] find from subfolder ($sh_code: $sh_out)"; fi
  # A site.json inside a site folder (one WordPress could have written into wp-content/ or var/) is never taken for the
  # site: exit 2, naming it and the site folder around it, before anything else.
  # nested WHERE_TO_CD OUTER INNER: run offprint_find_site from WHERE_TO_CD; expect the message for INNER/site.json
  nested() {
    sh_out="$(cd "$1" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf 'SURVIVED %s' \"\$SITE\"" 2>&1)"; sh_code=$?
    local o i; o="$(cd "$2" && pwd -P)"; i="$(cd "$3" && pwd -P)"
    [ "$sh_code" -eq 2 ] && [ "$sh_out" = "site.json at $i/site.json is inside the site folder $o; cd to $o or set OFFPRINT_SITE." ]
  }
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; mkdir -p "$site/wp-content/themes/t"; cp "$root/tests/fixtures/site.json" "$site/wp-content/"
  if nested "$site/wp-content/themes/t" "$site" "$site/wp-content"; then ok "[$t] a site.json in wp-content/, from below it: refused, both named"; else bad "[$t] nested from below ($sh_code: $sh_out)"; fi
  if nested "$site/wp-content" "$site" "$site/wp-content"; then ok "[$t] a site.json in wp-content/, from wp-content/: refused"; else bad "[$t] nested from inner ($sh_code: $sh_out)"; fi
  sh_out="$(cd "$site" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$(cd "$site" && pwd -P)" ]; then ok "[$t] from the site folder itself, the inner one doesn't matter"; else bad "[$t] outer with an inner site.json ($sh_code: $sh_out)"; fi
  sh_out="$(cd / && OFFPRINT_SITE="$site/wp-content" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$(cd "$site/wp-content" && pwd -P)" ]; then ok "[$t] an OFFPRINT_SITE naming the inner folder is the owner's word: used"; else bad "[$t] explicit inner OFFPRINT_SITE ($sh_code: $sh_out)"; fi
  # three levels: the outermost site folder is named
  newsite; mkdir -p "$site/a/b/c"; for d in "$site" "$site/a" "$site/a/b"; do cp "$root/tests/fixtures/site.json" "$d/"; done
  if nested "$site/a/b/c" "$site" "$site/a/b"; then ok "[$t] three site.json files, one inside another: refused, the outermost named"; else bad "[$t] three levels ($sh_code: $sh_out)"; fi
  # an ancestor's site.json that is a symlink counts, to a file or to nothing at all
  newsite; mkdir -p "$site/in"; cp "$root/tests/fixtures/site.json" "$site/in/"; ln -s "$root/tests/fixtures/site.json" "$site/site.json"
  if nested "$site/in" "$site" "$site/in"; then ok "[$t] an ancestor's site.json that is a symlink: refused"; else bad "[$t] symlinked ancestor ($sh_code: $sh_out)"; fi
  newsite; mkdir -p "$site/in"; cp "$root/tests/fixtures/site.json" "$site/in/"; ln -s "$tmp/nowhere$n/site.json" "$site/site.json"
  if nested "$site/in" "$site" "$site/in"; then ok "[$t] an ancestor's site.json that is a dangling symlink: refused"; else bad "[$t] dangling ancestor ($sh_code: $sh_out)"; fi
  newsite; mkdir -p "$site/in" "$site/site.json"; cp "$root/tests/fixtures/site.json" "$site/in/"
  if nested "$site/in" "$site" "$site/in"; then ok "[$t] an ancestor's site.json that is a folder: refused"; else bad "[$t] folder ancestor ($sh_code: $sh_out)"; fi
  # A folder name chosen in the container goes into that message: no control character reaches the terminal.
  evil="$(printf 'evil\033]0;x\007dir')"
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; mkdir -p "$site/wp-content/$evil"; cp "$root/tests/fixtures/site.json" "$site/wp-content/$evil/"
  sh_out="$(cd "$site/wp-content/$evil" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site" 2>&1)"; sh_code=$?
  ctl="$(printf '%s' "$sh_out" | LC_ALL=C tr -dc '\001-\037\177' | wc -c | tr -d ' ')"
  if [ "$sh_code" -eq 2 ] && [ "$ctl" = 0 ] && contains "$sh_out" "/wp-content/evil?]0;x?dir/site.json is inside the site folder"; then
    ok "[$t] a nested site.json under a folder named with ESC and BEL: the message has them as ?"
  else bad "[$t] control characters in the message ($sh_code, $ctl control bytes: $(printf '%s' "$sh_out" | LC_ALL=C tr '\001-\037\177' '?'))"; fi
  # Something named site.json that is not a regular file, at or below where it starts, is passed over: the site
  # folder above is found.
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; mkdir -p "$site/sub/site.json" "$site/sub/deeper"
  sh_out="$(cd "$site/sub" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$(cd "$site" && pwd -P)" ]; then ok "[$t] a folder named site.json where it starts: passed over, the site above found"; else bad "[$t] folder site.json below ($sh_code: $sh_out)"; fi
  sh_out="$(cd "$site/sub/deeper" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$(cd "$site" && pwd -P)" ]; then ok "[$t] a folder named site.json between it and the site: passed over"; else bad "[$t] folder site.json between ($sh_code: $sh_out)"; fi
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; mkdir -p "$site/sub"; ln -s "$tmp/nowhere$n/site.json" "$site/sub/site.json"
  sh_out="$(cd "$site/sub" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$(cd "$site" && pwd -P)" ]; then ok "[$t] a dangling symlink named site.json where it starts: passed over, the site above found"; else bad "[$t] dangling site.json below ($sh_code: $sh_out)"; fi

  # a symlinked path gives the physical path (a fresh plain site again, for this and the cases after it)
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; mkdir -p "$site/a/b"; want="$(cd "$site" && pwd -P)"
  ln -s "$site" "$tmp/link$n"
  sh_out="$(cd "$tmp/link$n/a" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"
  if [ "$sh_out" = "$want" ]; then ok "[$t] SITE is an absolute physical path"; else bad "[$t] physical path ($sh_out)"; fi
  # OFFPRINT_SITE
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$want" ]; then ok "[$t] OFFPRINT_SITE is used"; else bad "[$t] OFFPRINT_SITE ($sh_code: $sh_out)"; fi
  # OFFPRINT_SITE wins over the folder we are in
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; other="$site"
  sh_out="$(cd "$tmp/s$((n - 1))/a" && OFFPRINT_SITE="$other" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"
  if [ "$sh_out" = "$(cd "$other" && pwd -P)" ]; then ok "[$t] OFFPRINT_SITE wins over the current folder"; else bad "[$t] OFFPRINT_SITE precedence ($sh_out)"; fi
  # OFFPRINT_SITE without site.json: exit 2, names the path, no fall-through
  mkdir -p "$tmp/empty$n"
  sh_out="$(cd "$site" && OFFPRINT_SITE="$tmp/empty$n" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf 'SURVIVED'" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 2 ] && contains "$sh_out" "$tmp/empty$n" && ! contains "$sh_out" SURVIVED; then ok "[$t] OFFPRINT_SITE without site.json: exit 2, path named, no fall-through"; else bad "[$t] bad OFFPRINT_SITE ($sh_code: $sh_out)"; fi
  sh_out="$(cd "$site" && OFFPRINT_SITE="$tmp/does-not-exist" "$B" -c ". '$root/lib/site.sh'; offprint_find_site" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 2 ] && contains "$sh_out" "$tmp/does-not-exist"; then ok "[$t] OFFPRINT_SITE that is not a folder: exit 2"; else bad "[$t] OFFPRINT_SITE missing dir ($sh_code: $sh_out)"; fi
  # from /
  sh_out="$(cd / && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 2 ] && [ "$sh_out" = "Not in an Offprint site folder (no site.json here or above); cd into one, or set OFFPRINT_SITE." ]; then ok "[$t] offprint_find_site from /: exit 2 and the message"; else bad "[$t] find from / ($sh_code: $sh_out)"; fi
  # (a) the working folder was deleted: must exit 2, never hang
  gone="$tmp/gone$n"; mkdir -p "$gone"
  ( cd "$gone" && rmdir "$gone" && env -u OFFPRINT_SITE "$B" -c ". '$root/lib/site.sh'; offprint_find_site" ) > "$tmp/gone.out" 2>&1 &
  gpid=$!; i=0
  while kill -0 "$gpid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$gpid" 2>/dev/null; then kill "$gpid" 2>/dev/null; sleep 0.2; kill -9 "$gpid" 2>/dev/null; hung=1; else hung=0; fi
  wait "$gpid" 2>/dev/null; sh_code=$?
  if [ "$hung" -eq 0 ] && [ "$sh_code" -eq 2 ] && [ -s "$tmp/gone.out" ]; then ok "[$t] offprint_find_site with a deleted working folder: exit 2 and a message, no hang"; else bad "[$t] deleted cwd (hung=$hung code=$sh_code: $(cat "$tmp/gone.out"))"; fi
  # (b) CDPATH must not redirect the cd that resolves SITE or TOOL
  mkdir -p "$tmp/cdp$n/foo" "$tmp/cwd$n/foo"; cp "$root/tests/fixtures/site.json" "$tmp/cdp$n/foo/"; cp "$root/tests/fixtures/site.json" "$tmp/cwd$n/foo/"
  sh_out="$(cd "$tmp/cwd$n" && CDPATH="$tmp/cdp$n" OFFPRINT_SITE=foo "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"
  if [ "$sh_out" = "$(cd "$tmp/cwd$n/foo" && pwd -P)" ]; then ok "[$t] CDPATH does not redirect a relative OFFPRINT_SITE (one line, the folder checked)"; else bad "[$t] CDPATH SITE ($sh_out)"; fi
  mkdir -p "$tmp/cdp2$n/bin" "$tmp/cdp2$n/lib" "$tmp/tl$n/bin" "$tmp/tl$n/lib"; cp "$root/lib/site.sh" "$root/lib/config.php" "$tmp/tl$n/lib/"
  sh_out="$(cd "$tmp/tl$n" && CDPATH="$tmp/cdp2$n" "$B" -c ". bin/../lib/site.sh; printf '%s' \"\$TOOL\"" 2>&1)"
  if [ "$sh_out" = "$(cd "$tmp/tl$n" && pwd -P)" ]; then ok "[$t] CDPATH does not redirect TOOL when site.sh is sourced by a relative path"; else bad "[$t] CDPATH TOOL ($sh_out)"; fi
  # (c) OFFPRINT_SITE=- is a folder named -, not $OLDPWD
  mkdir -p "$tmp/dash$n/-" "$tmp/dashother$n"; cp "$root/tests/fixtures/site.json" "$tmp/dash$n/-/"; cp "$root/tests/fixtures/site.json" "$tmp/dashother$n/"
  sh_out="$(OFFPRINT_SITE=- "$B" -c "cd '$tmp/dashother$n'; cd '$tmp/dash$n'; . '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$SITE\"" 2>&1)"
  if [ "$sh_out" = "$(cd "$tmp/dash$n/-" && pwd -P)" ]; then ok "[$t] OFFPRINT_SITE=- is the folder named -"; else bad "[$t] OFFPRINT_SITE=- ($sh_out)"; fi
  # TOOL
  sh_out="$(cd / && "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$TOOL\"" 2>&1)"
  if [ "$sh_out" = "$(cd "$root" && pwd -P)" ]; then ok "[$t] TOOL is the tool's root from any directory"; else bad "[$t] TOOL ($sh_out)"; fi
  # TOOL with a space in the path, reached through a symlink too
  mkdir -p "$tmp/with space/lib"; cp "$root/lib/site.sh" "$root/lib/config.php" "$tmp/with space/lib/"
  ln -s "$tmp/with space/lib" "$tmp/lnk$n"
  sh_out="$(cd / && "$B" -c ". '$tmp/lnk$n/site.sh'; printf '%s' \"\$TOOL\"" 2>&1)"
  if [ "$sh_out" = "$(cd "$tmp/with space" && pwd -P)" ]; then ok "[$t] TOOL works with a space in the path and via a symlink"; else bad "[$t] TOOL with space ($sh_out)"; fi

  # offprint_load_site: the fixture
  sh_out="$(cd / && OFFPRINT_SITE="$root/tests/fixtures" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; for v in SITE_NAME SITE_PUBLIC_URL SITE_PUBLIC_HOST SITE_LOCAL_HOST SITE_IP4 SITE_IP6 SITE_TLS_PORT SITE_HTTP_PORT SITE_AGENT_LABEL SITE_DAEMON_PREFIX; do printf '%s\t%s\n' \$v \"\${!v}\"; done" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "$expected_fixture" ]; then ok "[$t] offprint_load_site sets the ten variables"; else bad "[$t] load ($sh_code: $sh_out)"; fi
  # the backup's two values: set from the block, and empty (never inherited) without one
  sh_out="$(cd / && OFFPRINT_SITE="$root/tests/fixtures" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s' \"\$SITE_BACKUP_RECIPIENTS\" \"\$SITE_BACKUP_TO\"" 2>&1)"
  if [ "$sh_out" = "age1$(printf 'q%.0s' $(seq 1 58))|repo" ]; then ok "[$t] offprint_load_site sets SITE_BACKUP_RECIPIENTS and SITE_BACKUP_TO"; else bad "[$t] load backup ($sh_out)"; fi
  newsite; put "{$base}"
  sh_out="$(cd / && SITE_BACKUP_RECIPIENTS=inherited SITE_BACKUP_TO=inherited OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s' \"\$SITE_BACKUP_RECIPIENTS\" \"\$SITE_BACKUP_TO\"" 2>&1)"
  if [ "$sh_out" = "|" ]; then ok "[$t] offprint_load_site, no backup block: both empty, whatever the environment held"; else bad "[$t] load no backup ($sh_out)"; fi
  # the pigeonhole's two values: set from the block, and empty (never inherited) without one
  newsite; with "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\",\"$P62\"]}"
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s' \"\$SITE_PIGEONHOLE_PATH\" \"\$SITE_PIGEONHOLE_RECIPIENTS\"" 2>&1)"
  if [ "$sh_out" = "/_pigeonhole|$Q62 $P62" ]; then ok "[$t] offprint_load_site sets SITE_PIGEONHOLE_PATH and SITE_PIGEONHOLE_RECIPIENTS"; else bad "[$t] load pigeonhole ($sh_out)"; fi
  newsite; put "{$base}"
  sh_out="$(cd / && SITE_PIGEONHOLE_PATH=/inherited SITE_PIGEONHOLE_RECIPIENTS=inherited OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s' \"\$SITE_PIGEONHOLE_PATH\" \"\$SITE_PIGEONHOLE_RECIPIENTS\"" 2>&1)"
  if [ "$sh_out" = "|" ]; then ok "[$t] offprint_load_site, no pigeonhole block: both empty, whatever the environment held"; else bad "[$t] load no pigeonhole ($sh_out)"; fi
  # the server's seven: set from the block, and empty (never inherited) when it names none
  seven='printf "%s|" "$SITE_PIGEONHOLE_SERVER" "$SITE_PIGEONHOLE_SERVER_PORT" "$SITE_PIGEONHOLE_SERVER_HOST_KEY" "$SITE_PIGEONHOLE_JUMP" "$SITE_PIGEONHOLE_JUMP_PORT" "$SITE_PIGEONHOLE_JUMP_HOST_KEY" "$SITE_PIGEONHOLE_STORE_PORT"'
  newsite; srv
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; $seven" 2>&1)"
  if [ "$sh_out" = "10.0.0.5|22|$HK1|192.0.2.10|22|$HK2|8788|" ]; then ok "[$t] offprint_load_site sets the seven values of a pigeonhole's server"; else bad "[$t] load pigeonhole server ($sh_out)"; fi
  newsite; with "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\"]}"
  sh_out="$(cd / && SITE_PIGEONHOLE_SERVER=10.9.9.9 SITE_PIGEONHOLE_SERVER_PORT=1 SITE_PIGEONHOLE_SERVER_HOST_KEY=x SITE_PIGEONHOLE_JUMP=10.9.9.8 SITE_PIGEONHOLE_JUMP_PORT=2 SITE_PIGEONHOLE_JUMP_HOST_KEY=y SITE_PIGEONHOLE_STORE_PORT=3 OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; $seven" 2>&1)"
  if [ "$sh_out" = "|||||||" ]; then ok "[$t] offprint_load_site, a pigeonhole that names no server: all seven empty, whatever the environment held"; else bad "[$t] load no pigeonhole server ($sh_out)"; fi
  # adapter variables
  newsite; cp "$root/tests/fixtures/site.json" "$site/"
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s' \"\$ADAPTER_NAME\" \"\$(compgen -v | grep -c '^ADAPTER_SET_')\"" 2>&1)"
  if [ "$sh_out" = "none|0" ]; then ok "[$t] no adapter block: ADAPTER_NAME is none, no ADAPTER_SET_ variable"; else bad "[$t] adapter none ($sh_out)"; fi
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; with '"adapter":{"name":"example-host","account_id":"abc123","retries":3}'
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s|%s' \"\$ADAPTER_NAME\" \"\$ADAPTER_SET_ACCOUNT_ID\" \"\$ADAPTER_SET_RETRIES\"" 2>&1)"
  if [ "$sh_out" = "example-host|abc123|3" ]; then ok "[$t] offprint_load_site sets ADAPTER_NAME and the ADAPTER_SET_ variables"; else bad "[$t] adapter load ($sh_out)"; fi
  sh_out="$(cd / && ADAPTER_SET_EVIL=x ADAPTER_NAME=env OFFPRINT_SITE="$root/tests/fixtures" "$B" -c "export ADAPTER_SET_EVIL2=y; . '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s|%s' \"\${ADAPTER_SET_EVIL-unset}\" \"\${ADAPTER_SET_EVIL2-unset}\" \"\$ADAPTER_NAME\"" 2>&1)"
  if [ "$sh_out" = "unset|unset|none" ]; then ok "[$t] an ADAPTER_SET_ variable from the caller's environment is unset by the load"; else bad "[$t] adapter env ($sh_out)"; fi
  # a stand-in config.php printing adapter lines with bad keys
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; fake="$tmp/fakead$n"; mkdir -p "$fake/lib"; cp "$root/lib/site.sh" "$fake/lib/"
  cat > "$fake/lib/config.php" <<PHP
<?php
foreach (['SITE_NAME'=>'ok','SITE_PUBLIC_URL'=>'u','SITE_PUBLIC_HOST'=>'h','SITE_LOCAL_HOST'=>'l','SITE_IP4'=>'4','SITE_IP6'=>'6','SITE_TLS_PORT'=>'1','SITE_HTTP_PORT'=>'2','SITE_AGENT_LABEL'=>'a','SITE_DAEMON_PREFIX'=>'d'] as \$k=>\$v) echo "\$k\t\$v\n";
echo "ADAPTER_SET_x\ty\n";
echo "ADAPTER_SET_\tq\n";
echo "ADAPTER_SETX\t1\n";
echo "ADAPTER_SET_1A\tz\n";
echo "PATH\t/tmp\n";
PHP
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$fake/lib/site.sh'; oldpath=\$PATH; offprint_find_site; offprint_load_site; printf '%s|%s|%s|%s' \"\$(compgen -v | grep -c '^ADAPTER_SET')\" \"\${ADAPTER_SETX-unset}\" \"\$ADAPTER_NAME\" \"\$([ \"\$PATH\" = \"\$oldpath\" ] && echo pathkept)\"" 2>&1)"
  if [ "$sh_out" = "0|unset|none|pathkept" ]; then ok "[$t] stand-in config.php: ADAPTER_SET_ lines with bad keys, ADAPTER_SETX and PATH set nothing"; else bad "[$t] adapter stand-in ($sh_out)"; fi
  # a stand-in printing a good ADAPTER_SET_ line and a value with spaces and a dollar sign
  cat >> "$fake/lib/config.php" <<PHP
echo "ADAPTER_NAME\tfake\n";
echo "ADAPTER_SET_GOOD_1\t\\\$(touch $tmp/pwned2) a b\n";
PHP
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$fake/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s|%s' \"\$ADAPTER_NAME\" \"\$ADAPTER_SET_GOOD_1\"" 2>&1)"
  if [ "$sh_out" = "fake|\$(touch $tmp/pwned2) a b" ] && [ ! -e "$tmp/pwned2" ]; then ok "[$t] a good ADAPTER_SET_ line is assigned literally, never evaluated"; else bad "[$t] adapter good line ($sh_out)"; fi
  # a site path with a space
  newsite; site="$tmp/my site $n"; mkdir -p "$site"; cp "$root/tests/fixtures/site.json" "$site/"
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf '%s' \"\$SITE_NAME\"" 2>&1)"
  if [ "$sh_out" = "example" ]; then ok "[$t] a site path with a space loads"; else bad "[$t] spaced site ($sh_out)"; fi
  # an invalid site.json: exit 2, problems on stderr, nothing set
  put '{"format":1,"name":"A"}'
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; printf 'SURVIVED'" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 2 ] && contains "$sh_out" 'site.json: "name"' && ! contains "$sh_out" SURVIVED; then ok "[$t] an invalid site.json: problems printed, exit 2"; else bad "[$t] invalid load ($sh_code: $sh_out)"; fi

  # a stand-in config.php that prints an unknown key and a known one
  newsite; fake="$tmp/fake$n"; mkdir -p "$fake/lib"; cp "$root/lib/site.sh" "$fake/lib/"; cp "$root/tests/fixtures/site.json" "$site/"
  cat > "$fake/lib/config.php" <<PHP
<?php
echo "EVIL\tx\n";
echo "PATH\t/nowhere\n";
echo "SITE_NAME\tok\n";
echo "SITE_PUBLIC_URL\t\$(touch $tmp/pwned)\n";
PHP
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$fake/lib/site.sh'; offprint_find_site; offprint_load_site; printf 'SURVIVED'" 2>&1)"; sh_code=$?
  # incomplete output (only some keys) must exit 2, and EVIL must not become a variable
  if [ "$sh_code" -eq 2 ] && ! contains "$sh_out" SURVIVED && [ ! -e "$tmp/pwned" ]; then ok "[$t] incomplete config output: exit 2, nothing evaluated"; else bad "[$t] incomplete output ($sh_code: $sh_out)"; fi
  cat > "$fake/lib/config.php" <<PHP
<?php
echo "EVIL\tx\n";
echo "PATH\t/nowhere\n";
foreach (['SITE_NAME'=>'ok','SITE_PUBLIC_URL'=>'\$(touch $tmp/pwned)','SITE_PUBLIC_HOST'=>'h','SITE_LOCAL_HOST'=>'l','SITE_IP4'=>'4','SITE_IP6'=>'6','SITE_TLS_PORT'=>'1','SITE_HTTP_PORT'=>'2','SITE_AGENT_LABEL'=>'a','SITE_DAEMON_PREFIX'=>'d'] as \$k=>\$v) echo "\$k\t\$v\n";
PHP
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$fake/lib/site.sh'; oldpath=\$PATH; offprint_find_site; offprint_load_site; printf '%s|%s|%s|%s' \"\${EVIL-unset}\" \"\$SITE_NAME\" \"\$SITE_PUBLIC_URL\" \"\$([ \"\$PATH\" = \"\$oldpath\" ] && echo pathkept)\"" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 0 ] && [ "$sh_out" = "unset|ok|\$(touch $tmp/pwned)|pathkept" ] && [ ! -e "$tmp/pwned" ]; then ok "[$t] unknown keys are ignored (EVIL unset, PATH untouched), values never evaluated"; else bad "[$t] stand-in ($sh_code: $sh_out)"; fi
  # a failing config.php: stderr relayed, exit 2
  printf '%s\n' '<?php fwrite(STDERR, "site.json: \"x\" is broken\n"); exit(2);' > "$fake/lib/config.php"
  sh_out="$(cd / && OFFPRINT_SITE="$site" "$B" -c ". '$fake/lib/site.sh'; offprint_find_site; offprint_load_site; printf 'SURVIVED'" 2>&1)"; sh_code=$?
  if [ "$sh_code" -eq 2 ] && contains "$sh_out" 'site.json: "x" is broken' && ! contains "$sh_out" SURVIVED; then ok "[$t] config.php failure: its stderr is printed, exit 2"; else bad "[$t] failing config ($sh_code: $sh_out)"; fi

  # dc with a stand-in docker (which says, to dc's two questions before compose, that there is no such project yet)
  newsite; site="$tmp/dc site $n"; mkdir -p "$site" "$tmp/bin$n"; cp "$root/tests/fixtures/site.json" "$site/"
  cat > "$tmp/bin$n/docker" <<STUB
#!/bin/sh
[ "\$1" = compose ] || exit 0
{ for a in "\$@"; do printf 'ARG[%s]\n' "\$a"; done
  printf 'ENV OFFPRINT_PUBLIC_ORIGIN=%s\nENV OFFPRINT_LOCAL_HOST=%s\nENV OFFPRINT_TLS_PORT=%s\nENV OFFPRINT_HTTP_PORT=%s\nENV OFFPRINT_TOOL=%s\n' "\${OFFPRINT_PUBLIC_ORIGIN-}" "\${OFFPRINT_LOCAL_HOST-}" "\${OFFPRINT_TLS_PORT-}" "\${OFFPRINT_HTTP_PORT-}" "\${OFFPRINT_TOOL-}"; } > "$tmp/docker.rec$n"
exit 7
STUB
  chmod +x "$tmp/bin$n/docker"
  sh_out="$(cd / && PATH="$tmp/bin$n:$PATH" OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; dc up -d 'two words'; echo \"rc=\$?\"; printf 'leak=[%s%s%s%s%s]' \"\${OFFPRINT_PUBLIC_ORIGIN-}\" \"\${OFFPRINT_LOCAL_HOST-}\" \"\${OFFPRINT_TLS_PORT-}\" \"\${OFFPRINT_HTTP_PORT-}\" \"\${OFFPRINT_TOOL-}\"" 2>&1)"
  physsite="$(cd "$site" && pwd -P)"; phystool="$(cd "$root" && pwd -P)"
  want_rec="ARG[compose]
ARG[-p]
ARG[example]
ARG[--project-directory]
ARG[$physsite]
ARG[-f]
ARG[$phystool/templates/compose.yaml]
ARG[up]
ARG[-d]
ARG[two words]
ENV OFFPRINT_PUBLIC_ORIGIN=https://www.example.com
ENV OFFPRINT_LOCAL_HOST=mysite.test
ENV OFFPRINT_TLS_PORT=4999
ENV OFFPRINT_HTTP_PORT=4998
ENV OFFPRINT_TOOL=$phystool"
  if [ "$(cat "$tmp/docker.rec$n")" = "$want_rec" ]; then ok "[$t] dc runs docker compose with the exact argv and the five variables"; else bad "[$t] dc argv/env: $(cat "$tmp/docker.rec$n" 2>&1)"; fi
  if contains "$sh_out" "rc=7" && contains "$sh_out" "leak=[]"; then ok "[$t] dc returns docker's exit code and leaves the variables unexported in the caller"; else bad "[$t] dc rc/leak ($sh_out)"; fi

  # dc hands compose the pigeonhole's two values too (the compose file makes constants of them in WordPress), and
  # empty ones for a site with no block, whatever the environment held.
  for ph_case in block none; do
    newsite; mkdir -p "$tmp/bin$n"
    if [ "$ph_case" = block ]; then with "\"pigeonhole\":{\"path\":\"/_pigeonhole\",\"recipients\":[\"$Q62\",\"$P62\"]}"; ph_want="/_pigeonhole|$Q62 $P62"
    else put "{$base}"; ph_want="|"; fi
    cat > "$tmp/bin$n/docker" <<STUB
#!/bin/sh
[ "\$1" = compose ] || exit 0
printf '%s|%s' "\${OFFPRINT_PIGEONHOLE_PATH-unset}" "\${OFFPRINT_PIGEONHOLE_RECIPIENTS-unset}" > "$tmp/docker.ph$n"
STUB
    chmod +x "$tmp/bin$n/docker"
    sh_out="$(cd / && PATH="$tmp/bin$n:$PATH" OFFPRINT_PIGEONHOLE_PATH=/inherited OFFPRINT_PIGEONHOLE_RECIPIENTS=inherited OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; offprint_load_site; dc up -d" 2>&1)"
    if [ "$(cat "$tmp/docker.ph$n" 2>/dev/null)" = "$ph_want" ]; then ok "[$t] dc hands compose the pigeonhole's path and recipients ($ph_case)"; else bad "[$t] dc pigeonhole env, $ph_case: $(cat "$tmp/docker.ph$n" 2>&1) $sh_out"; fi
  done

  # ---- the PATH clean-up: offprint_clean_path, and the site folder's entries ----
  # An empty entry, or one that isn't an absolute path, is whatever folder a command runs in (wp-content/, say); an
  # entry in a site folder is one WordPress can write. Each is left out, in one line on stderr, and PATH is never left
  # empty. left WHAT...: sh_err is one line, saying PATH entries were left out, naming each WHAT
  left() {
    local w
    [ "$(printf '%s\n' "$sh_err" | grep -c .)" = 1 ] || return 1
    contains "$sh_err" "PATH entries left out" || return 1
    for w; do contains "$sh_err" "$w" || return 1; done
  }
  # cp_run PATH: offprint_clean_path alone, on PATH (lib/site.sh sourced first, with a PATH with nothing wrong), from /;
  # sh_out is the PATH it left, sh_err what it said
  cp_run() {
    sh_out="$(cd / && PATH=/usr/bin:/bin "$B" -c ". '$root/lib/site.sh'; PATH=\"\$1\"; offprint_clean_path; printf '%s' \"\$PATH\"" _ "$1" 2> "$tmp/cp.err")"; sh_code=$?
    sh_err="$(cat "$tmp/cp.err")"
  }
  fixed=/usr/bin:/bin:/usr/sbin:/sbin
  cp_run ""; if [ "$sh_code" = 0 ] && [ "$sh_out" = "$fixed" ] && left "''" "$fixed"; then ok "[$t] offprint_clean_path, an empty PATH: the fixed system PATH, said in one line"; else bad "[$t] clean empty ($sh_code: $sh_out / $sh_err)"; fi
  cp_run ".:/usr/bin:/bin"; if [ "$sh_out" = /usr/bin:/bin ] && left "'.'"; then ok "[$t] offprint_clean_path, . first: left out, named"; else bad "[$t] clean . ($sh_out / $sh_err)"; fi
  cp_run "..:/usr/bin"; if [ "$sh_out" = /usr/bin ] && left "'..'"; then ok "[$t] offprint_clean_path, ..: left out"; else bad "[$t] clean .. ($sh_out / $sh_err)"; fi
  HOME=relhome cp_run "rel/bin:/usr/bin:wp-content:~/bin"; if [ "$sh_out" = /usr/bin ] && left "'rel/bin'" "'wp-content'" "'~/bin'"; then ok "[$t] offprint_clean_path, relative entries (and ~/bin, with HOME not an absolute path): left out, each named, in one line"; else bad "[$t] clean relative ($sh_out / $sh_err)"; fi
  cp_run "/usr/bin::/bin"; if [ "$sh_out" = /usr/bin:/bin ] && left "''"; then ok "[$t] offprint_clean_path, a doubled colon: the empty entry left out"; else bad "[$t] clean doubled ($sh_out / $sh_err)"; fi
  cp_run ":/usr/bin"; a="$sh_out|$(left "''" && echo said)"; cp_run "/usr/bin:"; b="$sh_out|$(left "''" && echo said)"
  if [ "$a" = "/usr/bin|said" ] && [ "$b" = "/usr/bin|said" ]; then ok "[$t] offprint_clean_path, a leading and a trailing colon: the empty entry left out"; else bad "[$t] clean leading/trailing ($a / $b)"; fi
  cp_run ".:rel::"; if [ "$sh_out" = "$fixed" ] && left "'.'" "'rel'" "''" "$fixed"; then ok "[$t] offprint_clean_path, only bad entries: the fixed system PATH, never an empty one"; else bad "[$t] clean only bad ($sh_out / $sh_err)"; fi
  cp_run "/usr/bin:/bin:/a b/c"; if [ "$sh_code" = 0 ] && [ "$sh_out" = "/usr/bin:/bin:/a b/c" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_clean_path, nothing wrong: unchanged, in order, and silent"; else bad "[$t] clean nothing wrong ($sh_out / $sh_err)"; fi
  cp_run "/with space/bin:rel space:/usr/bin"; if [ "$sh_out" = "/with space/bin:/usr/bin" ] && left "'rel space'"; then ok "[$t] offprint_clean_path, entries with spaces: kept and left out as whole strings"; else bad "[$t] clean spaces ($sh_out / $sh_err)"; fi
  cp_run "/usr/bin:$(printf 're\nl\033]0;x\007')x:/bin"
  ctl="$(printf '%s' "$sh_err" | LC_ALL=C tr -dc '\001-\011\013-\037\177' | wc -c | tr -d ' ')"
  if [ "$sh_out" = /usr/bin:/bin ] && left "'re?l?]0;x?x'" && [ "$ctl" = 0 ]; then ok "[$t] offprint_clean_path, a line end and control characters in an entry: still one line, each shown as ?"; else bad "[$t] clean control ($sh_out / $sh_err)"; fi
  sh_out="$(cd / && PATH=/usr/bin:/bin "$B" -c ". '$root/lib/site.sh'; PATH=.:/usr/bin; offprint_clean_path; /usr/bin/env" 2>/dev/null | grep '^PATH=')"
  if [ "$sh_out" = PATH=/usr/bin ]; then ok "[$t] offprint_clean_path: the PATH it leaves is exported (a program run after has it)"; else bad "[$t] clean export ($sh_out)"; fi
  # sourcing lib/site.sh cleans the PATH at once, using only the shell's own builtins until then (TOOL too: no dirname):
  # look-alikes in the folder it runs from, and in an absolute entry, never run
  mkdir -p "$tmp/plant$n"
  for p in bash dirname php mktemp git docker curl readlink env cat tr; do printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$tmp/plant$n/$p"; chmod +x "$tmp/plant$n/$p"; done
  rm -f "$tmp/planted.ran"
  sh_out="$(cd "$tmp/plant$n" && PATH=".:/usr/bin:/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s|%s' \"\$PATH\" \"\$TOOL\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical /usr/bin:/bin)|$(cd "$root" && pwd -P)" ] && left "'.'" && [ ! -e "$tmp/planted.ran" ]; then ok "[$t] sourcing lib/site.sh, . first on the PATH, run from a folder of look-alikes: . left out at once, TOOL right, none ran"; else bad "[$t] source with . ($sh_out / $sh_err / $(cat "$tmp/planted.ran" 2>&1))"; fi
  sh_out="$(cd / && PATH="$tmp/plant$n:/usr/bin:/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$TOOL\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(cd "$root" && pwd -P)" ] && [ -z "$sh_err" ] && [ ! -e "$tmp/planted.ran" ]; then ok "[$t] sourcing lib/site.sh runs no program for TOOL (a dirname first on the PATH never runs)"; else bad "[$t] TOOL without dirname ($sh_out / $sh_err / $(cat "$tmp/planted.ran" 2>&1))"; fi
  # bash's own PATH, when none is given (it has . in it on macOS): . left out, and the PATH left exported
  sh_out="$(cd / && env -i "$B" -c ". '$root/lib/site.sh'; /usr/bin/env" 2>/dev/null | grep '^PATH=')"
  case ":${sh_out#PATH=}:" in
    *::*|*:.:*|*:[!/]*|PATH=) bad "[$t] no PATH given ($sh_out)" ;;
    *) if [ -n "${sh_out#PATH=}" ]; then ok "[$t] no PATH given: what bash makes up is cleaned, and exported"; else bad "[$t] no PATH given, empty ($sh_out)"; fi ;;
  esac

  # the site folder's entries: offprint_find_site leaves out each that is the site
  # folder or inside it, asked of the disk
  newsite; cp "$root/tests/fixtures/site.json" "$site/"; mkdir -p "$site/wp-content/sub"
  ln -s "$site/wp-content" "$tmp/wplink$n"; ln -s /usr/bin "$site/wp-content/usrbin"
  # sd_run PATH: offprint_find_site for $site (OFFPRINT_SITE), from /, the PATH set once lib/site.sh is sourced; sh_out
  # is the PATH it left, sh_err what it said
  sd_run() {
    sh_out="$(cd / && PATH=/usr/bin:/bin OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; PATH=\"\$1\"; offprint_find_site; printf '%s' \"\$PATH\"" _ "$1" 2> "$tmp/cp.err")"; sh_code=$?
    sh_err="$(cat "$tmp/cp.err")"
  }
  sd_run "/usr/bin:$site:/bin"; if [ "$sh_code" = 0 ] && [ "$sh_out" = "$(physical /usr/bin:/bin)" ] && left "'$site'" "$(cd "$site" && pwd -P)"; then ok "[$t] offprint_find_site: the site folder itself on the PATH, left out, named with the site folder, in one line"; else bad "[$t] site itself ($sh_code: $sh_out / $sh_err)"; fi
  sd_run "/usr/bin:$site/wp-content/sub:/bin"; if [ "$sh_out" = "$(physical /usr/bin:/bin)" ] && left "'$site/wp-content/sub'"; then ok "[$t] offprint_find_site: a folder inside it, left out"; else bad "[$t] inside ($sh_out / $sh_err)"; fi
  sd_run "$tmp/wplink$n:/usr/bin"; if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$tmp/wplink$n'"; then ok "[$t] offprint_find_site: a link outside it that leads into wp-content/, left out"; else bad "[$t] link in ($sh_out / $sh_err)"; fi
  sd_run "$site/wp-content/usrbin:/usr/bin"; if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$site/wp-content/usrbin'"; then ok "[$t] offprint_find_site: a link inside it that leads out (WordPress could change it), left out"; else bad "[$t] link out ($sh_out / $sh_err)"; fi
  sd_run "$site/wp-content/nope/bin:/usr/bin"; if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$site/wp-content/nope/bin'"; then ok "[$t] offprint_find_site: an entry under it that doesn't exist (yet), left out"; else bad "[$t] missing inside ($sh_out / $sh_err)"; fi
  sd_run "$tmp/nowhere$n/bin:/usr/bin"; if [ "$sh_out" = "$(physical /usr/bin)" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_find_site: an entry elsewhere that doesn't exist (it can't be entered), left out, silently"; else bad "[$t] missing elsewhere ($sh_out / $sh_err)"; fi
  # An entry that can't be entered now (not there, a link to nothing, a folder closed to this user) runs nothing now,
  # and nothing made or opened there later can be reached through it once it is left out: so it is, silently (stale
  # entries are common). One in the site folder by its text is named, as the site's; a link that can be entered is
  # judged by where it leads (/bin is a link on some systems).
  mkdir -p "$tmp/closed$n" "$site/wp-content/locked" "$tmp/real$n"; ln -s "$tmp/real$n" "$tmp/linkok$n"
  ln -s "$tmp/gone$n/x" "$tmp/dangling$n"; ln -s "$site/wp-content/locked" "$tmp/tolocked$n"; chmod 000 "$tmp/closed$n" "$site/wp-content/locked"
  if (cd "$tmp/closed$n") 2> /dev/null; then bad "[$t] control: a mode-000 folder can't be entered (is this running as root?)"; else ok "[$t] control: a mode-000 folder can't be entered"; fi
  sd_run "$tmp/dangling$n:/usr/bin:$tmp/closed$n:$tmp/tolocked$n:/bin"
  if [ "$sh_out" = "$(physical /usr/bin:/bin)" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_find_site: a link to nothing, a mode-000 folder outside, a link outside to a mode-000 folder in wp-content/: left out, silently"; else bad "[$t] unenterable ($sh_out / $sh_err)"; fi
  sd_run "/usr/bin:$site/wp-content/locked"; if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$site/wp-content/locked'"; then ok "[$t] offprint_find_site: a mode-000 folder in the site folder by its text, left out and named as the site's"; else bad "[$t] locked in site ($sh_out / $sh_err)"; fi
  sd_run "$tmp/linkok$n:/usr/bin"; if [ "$sh_out" = "$(physical "$tmp/real$n:/usr/bin")" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_find_site: a link outside the site to a folder outside it, kept (as the folder it leads to), silently"; else bad "[$t] link ok ($sh_out / $sh_err)"; fi
  sh_out="$(cd / && env -u OFFPRINT_SITE PATH="$tmp/dangling$n:/usr/bin:$tmp/closed$n:$tmp/linkok$n" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical "/usr/bin:$tmp/real$n")" ] && [ -z "$sh_err" ]; then ok "[$t] sourcing lib/site.sh outside any site folder: entries that can't be entered left out, silently, the rest kept in order"; else bad "[$t] source unenterable ($sh_out / $sh_err)"; fi
  sh_out="$(cd / && env -u OFFPRINT_SITE PATH="$tmp/dangling$n:$tmp/closed$n:$tmp/nowhere$n/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$fixed" ] && [ "$(printf '%s\n' "$sh_err" | grep -c .)" = 1 ] && contains "$sh_err" "$fixed"; then ok "[$t] sourcing lib/site.sh, no entry that can be entered: the fixed system PATH, said in one line"; else bad "[$t] source none enterable ($sh_out / $sh_err)"; fi
  chmod 755 "$tmp/closed$n" "$site/wp-content/locked"
  sd_run "/usr/bin:/bin"; if [ "$sh_code" = 0 ] && [ "$sh_out" = "$(physical /usr/bin:/bin)" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_find_site: nothing of the site folder's on the PATH, unchanged and silent"; else bad "[$t] site nothing ($sh_out / $sh_err)"; fi
  sd_run "$site/wp-content"; if [ "$sh_out" = "$fixed" ] && left "'$site/wp-content'" "$fixed"; then ok "[$t] offprint_find_site: the site folder's entries only, the fixed system PATH, never an empty one"; else bad "[$t] site only ($sh_out / $sh_err)"; fi
  sd_run "/bin:$site/wp-content:/usr/bin:$tmp/wplink$n:/sbin"
  if [ "$sh_out" = "$(physical /bin:/usr/bin:/sbin)" ] && left "'$site/wp-content'" "'$tmp/wplink$n'"; then ok "[$t] offprint_find_site: two left out, the rest kept in order, one line"; else bad "[$t] order ($sh_out / $sh_err)"; fi
  # as soon as lib/site.sh is sourced, from inside the site folder (or with OFFPRINT_SITE): before anything is looked up
  sh_out="$(cd "$site/wp-content/sub" && env -u OFFPRINT_SITE PATH="$site/wp-content:/usr/bin:/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical /usr/bin:/bin)" ] && left "'$site/wp-content'"; then ok "[$t] sourcing lib/site.sh from inside a site folder: its entries left out at once"; else bad "[$t] source inside ($sh_out / $sh_err)"; fi
  sh_out="$(cd / && OFFPRINT_SITE="$site" PATH="$tmp/wplink$n:/usr/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$tmp/wplink$n'"; then ok "[$t] sourcing lib/site.sh with OFFPRINT_SITE: its entries left out at once"; else bad "[$t] source OFFPRINT_SITE ($sh_out / $sh_err)"; fi
  sh_out="$(cd "$site/wp-content/sub" && env -u OFFPRINT_SITE PATH=".:$site/wp-content:/usr/bin" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical /usr/bin)" ] && [ "$(printf '%s\n' "$sh_err" | grep -c 'PATH entries left out')" = 2 ] && contains "$sh_err" "'.'" && contains "$sh_err" "'$site/wp-content'"; then ok "[$t] sourced, then offprint_find_site, from inside the site: each entry named once (one line for ., one for the site's)"; else bad "[$t] said once ($sh_out / $sh_err)"; fi

  # ---- what is kept is the folder each entry is on disk when it is checked (cd -P), never its text ----
  # A link of the owner's, outside the site folder, can lead through a link in wp-content/ (WordPress's) to a folder
  # outside it: every folder its text names, followed, is outside the site, so it is kept. Kept as text, WordPress could
  # point its link at a folder of its own programs later (in the middle of a publish: its export is WordPress's code),
  # and the next look-up would find them. Kept as the folder it leads to now, nothing WordPress changes later moves it.
  # The same for TMPDIR, once it has passed its check: offprint_read_site and offprint_own_project make files there.
  newsite; cp "$root/tests/fixtures/site.json" "$site/"
  mkdir -p "$site/wp-content/planted" "$site/wp-content/caught" "$tmp/out$n/bin" "$tmp/out$n/tree/bin" "$tmp/out$n/tmp" "$tmp/own$n"
  ln -s "$tmp/out$n/bin" "$site/wp-content/hop"; ln -s "$site/wp-content/hop" "$tmp/own$n/tools"
  ln -s "$tmp/out$n/tree" "$site/wp-content/hop2"; ln -s "$site/wp-content/hop2" "$tmp/own$n/tree"
  ln -s "$tmp/out$n/tmp" "$site/wp-content/hoptmp"; ln -s "$site/wp-content/hoptmp" "$tmp/own$n/tmp"
  ln -s "$site/wp-content/notyet" "$tmp/own$n/tmpgone"
  for d in "$tmp/out$n/bin" "$tmp/out$n/tree/bin"; do printf '#!/bin/sh\necho benign\n' > "$d/hoptool"; chmod +x "$d/hoptool"; done
  printf '#!/bin/sh\necho PLANTED-RAN\n' > "$site/wp-content/planted/hoptool"; chmod +x "$site/wp-content/planted/hoptool"
  sd_run "$tmp/own$n/tools:/usr/bin"
  if [ "$sh_code" = 0 ] && [ "$sh_out" = "$(physical "$tmp/out$n/bin:/usr/bin")" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_find_site: a link outside the site, through a link in wp-content/, to a folder outside: kept as that folder on disk, silently"; else bad "[$t] link chain ($sh_code: $sh_out / $sh_err)"; fi
  sd_run "$tmp/own$n/tree/bin:/usr/bin"
  if [ "$sh_out" = "$(physical "$tmp/out$n/tree/bin:/usr/bin")" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_find_site: the same, the link in wp-content/ a folder on the way (own/tree/bin): kept as the folder on disk"; else bad "[$t] link chain, on the way ($sh_out / $sh_err)"; fi
  sh_out="$(cd "$site" && env -u OFFPRINT_SITE PATH="$tmp/own$n/tools:/usr/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical "$tmp/out$n/bin:/usr/bin")" ] && [ -z "$sh_err" ]; then ok "[$t] sourcing lib/site.sh in the site folder: the same, kept as the folder on disk"; else bad "[$t] link chain at source ($sh_out / $sh_err)"; fi
  # WordPress then points its link at a folder of its own: the name is still found where it was, by bash's remembered
  # path and by a new look-up, and the look-alike never runs
  sh_out="$(cd / && PATH=/usr/bin:/bin OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; PATH=\"\$1\"; offprint_find_site; hoptool; /bin/rm -f '$site/wp-content/hop'; /bin/ln -s '$site/wp-content/planted' '$site/wp-content/hop'; hoptool; hash -r; hoptool" _ "$tmp/own$n/tools:/usr/bin:/bin" 2>&1)"
  if [ "$sh_out" = "benign
benign
benign" ]; then ok "[$t] offprint_find_site, then WordPress points wp-content/hop at its own folder: the benign one found each time, the look-alike never runs"; else bad "[$t] link flipped ($sh_out)"; fi
  /bin/rm -f "$site/wp-content/hop"; ln -s "$tmp/out$n/bin" "$site/wp-content/hop"
  # The folder an entry is on disk is asked again (a link WordPress switched between the two looks would show there),
  # by _offprint_folder_in_sites: that folder, and each above it, against each site folder, as the same folder.
  pw="$(physical "$site/wp-content")"; sh_out=""
  for spec in "$pw|$site|0" "$(physical "$site")|$site|0" "$pw|/nowhere$n:$site|0" "$(physical "$tmp/out$n/bin")|$site|1" \
    "$(physical "$tmp")|$site|1" "$pw||1" "$(physical "$tmp")/s$n-not|$site|1"; do
    f="${spec%%|*}"; rest="${spec#*|}"; d="${rest%|*}"; want="${rest##*|}"
    got="$(cd / && "$B" -c ". '$root/lib/site.sh'; IFS=:; set -f; _offprint_folder_in_sites \"\$1\" \$2; printf '%s' \$?" _ "$f" "$d" 2>/dev/null)"
    [ "$got" = "$want" ] || sh_out="$sh_out [$f in $d: $got, not $want]"
  done
  if [ -z "$sh_out" ]; then ok "[$t] _offprint_folder_in_sites: a folder on disk in a site folder (or it), yes; outside, above it, beside it, or no site, no"; else bad "[$t] folder in sites:$sh_out"; fi
  # A link whose folder on disk has a colon in its name (one ending in a colon, here) can't be kept as that folder: it
  # would split into other entries, an empty one among them (the folder a command runs in). Left out; and named, saying
  # why, since it is a working entry of the owner's (a Finder name with a / in it is a colon on disk), not a stale one.
  mkdir -p "$tmp/out$n/a:" && ln -s "$tmp/out$n/a:" "$tmp/own$n/colon"
  sh_out="$(cd / && env -u OFFPRINT_SITE PATH="$tmp/own$n/colon:/usr/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$tmp/own$n/colon'" "a colon in its name, which can't be written in a PATH"; then ok "[$t] sourcing lib/site.sh, a link to a folder named with a colon: left out (never split into an empty entry), named in one line, saying why"; else bad "[$t] colon ($sh_out / $sh_err)"; fi
  sd_run "$tmp/own$n/colon:$site/wp-content:/usr/bin"
  if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$tmp/own$n/colon'" "a colon in its name" "'$site/wp-content'" "in the site folder"; then ok "[$t] offprint_find_site: a link to a folder named with a colon, and an entry in the site folder: both left out, named in one line, each with its reason"; else bad "[$t] colon and site ($sh_out / $sh_err)"; fi
  # TMPDIR, once it passes: the folder it is on disk, exported; so a temporary file made after WordPress points its
  # link elsewhere still goes there, never into the site folder
  sh_out="$(cd / && OFFPRINT_SITE="$site" TMPDIR="$tmp/own$n/tmp" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s|' \"\$TMPDIR\"; /usr/bin/env | grep '^TMPDIR='" 2>&1)"
  if [ "$sh_out" = "$(physical "$tmp/out$n/tmp")|TMPDIR=$(physical "$tmp/out$n/tmp")" ]; then ok "[$t] offprint_find_site: a TMPDIR that is such a link chain is set, and exported, as the folder it is on disk"; else bad "[$t] TMPDIR link chain ($sh_out)"; fi
  sh_out="$(cd / && OFFPRINT_SITE="$site" TMPDIR="$tmp/own$n/tmp" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; /bin/rm -f '$site/wp-content/hoptmp'; /bin/ln -s '$site/wp-content/caught' '$site/wp-content/hoptmp'; f=\"\$(mktemp \"\${TMPDIR:-/tmp}/offprint-config.XXXXXX\")\" && printf '%s' \"\${f%/*}\"" 2>&1)"
  if [ "$sh_out" = "$(physical "$tmp/out$n/tmp")" ] && [ -z "$(ls -A "$site/wp-content/caught")" ]; then ok "[$t] offprint_find_site, then WordPress points wp-content/hoptmp into the site: a temporary file made after goes where TMPDIR led when checked, none in the site"; else bad "[$t] TMPDIR flipped ($sh_out / $(ls -A "$site/wp-content/caught"))"; fi
  /bin/rm -f "$site/wp-content/hoptmp"; ln -s "$tmp/out$n/tmp" "$site/wp-content/hoptmp"
  sh_out="$(cd / && OFFPRINT_SITE="$site" TMPDIR="$tmp/tmpdir" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\$TMPDIR\"" 2>&1)"
  if [ "$sh_out" = "$(physical "$tmp/tmpdir")" ]; then ok "[$t] offprint_find_site: a plain TMPDIR outside the site, as the folder it is on disk"; else bad "[$t] TMPDIR plain ($sh_out)"; fi
  sh_out="$(cd / && env -u TMPDIR OFFPRINT_SITE="$site" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '%s' \"\${TMPDIR-unset}\"" 2>&1)"
  a="$sh_out"; sh_out="$(cd / && OFFPRINT_SITE="$site" TMPDIR= "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf '[%s]' \"\${TMPDIR-unset}\"" 2>&1)"
  if [ "$a|$sh_out" = "unset|[]" ]; then ok "[$t] offprint_find_site: no TMPDIR, or an empty one, left as it is (/tmp is used)"; else bad "[$t] TMPDIR unset/empty ($a|$sh_out)"; fi
  # One that can't be entered has no folder on disk to be kept as, and one WordPress makes there later (through a link
  # into the site folder) would take the files: refused, as one inside the site is, before any temporary file is made.
  for spec in "$tmp/nowhere$n/tmp|a folder that isn't there" "$tmp/own$n/tmpgone|a link outside the site to a folder in wp-content/ that isn't there yet"; do
    e="${spec%%|*}"
    sh_out="$(cd / && OFFPRINT_SITE="$site" TMPDIR="$e" "$B" -c ". '$root/lib/site.sh'; offprint_find_site; printf 'SURVIVED'" 2>&1)"; sh_code=$?
    if [ "$sh_code" = 2 ] && [ "$(printf '%s\n' "$sh_out" | grep -c .)" = 1 ] && contains "$sh_out" "TMPDIR is $e, which can't be entered" && [ ! -e "$site/wp-content/notyet" ]; then ok "[$t] offprint_find_site, TMPDIR ${spec#*|}: refused, in one line, exit 2"; else bad "[$t] TMPDIR can't be entered ($sh_code: $sh_out)"; fi
  done

  # ---- ~ and ~/...: bash itself takes a PATH entry that starts so as HOME's ----
  # So does the clean-up, when HOME is an absolute path, and then judges it like any other entry; otherwise it is left
  # out, as not an absolute path.
  mkdir -p "$tmp/home$n/bin"; printf '#!/bin/sh\necho tilde-found\n' > "$tmp/home$n/bin/tildetool"; chmod +x "$tmp/home$n/bin/tildetool"
  HOME="$tmp/home$n" cp_run "~/bin:/usr/bin:~"
  if [ "$sh_code" = 0 ] && [ "$sh_out" = "$tmp/home$n/bin:/usr/bin:$tmp/home$n" ] && [ -z "$sh_err" ]; then ok "[$t] offprint_clean_path, ~/bin and ~ with HOME an absolute path: HOME's, kept, silently"; else bad "[$t] clean ~ ($sh_out / $sh_err)"; fi
  sh_out="$(cd / && env -u OFFPRINT_SITE HOME="$tmp/home$n" PATH="~/bin:/usr/bin:/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s|' \"\$PATH\"; tildetool" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical "$tmp/home$n/bin:/usr/bin:/bin")|tilde-found" ] && [ -z "$sh_err" ]; then ok "[$t] sourcing lib/site.sh, ~/bin first on the PATH: the program in HOME's bin found, as bash finds it"; else bad "[$t] source ~/bin ($sh_out / $sh_err)"; fi
  for h in relhome ""; do
    HOME="$h" cp_run "~/bin:/usr/bin:~"
    if [ "$sh_out" = /usr/bin ] && left "'~/bin'" "'~'"; then ok "[$t] offprint_clean_path, ~/bin and ~ with HOME '$h' (not an absolute path): left out, named"; else bad "[$t] clean ~, HOME '$h' ($sh_out / $sh_err)"; fi
  done
  sh_out="$(cd / && env -u HOME PATH=/usr/bin:/bin "$B" -c ". '$root/lib/site.sh'; unset HOME; PATH=\"\$1\"; offprint_clean_path; printf '%s' \"\$PATH\"" _ "~/bin:/usr/bin" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = /usr/bin ] && left "'~/bin'"; then ok "[$t] offprint_clean_path, ~/bin with no HOME: left out, named"; else bad "[$t] clean ~, no HOME ($sh_out / $sh_err)"; fi
  HOME="$tmp/home$n" cp_run "~nobody/bin:/usr/bin"
  if [ "$sh_out" = /usr/bin ] && left "'~nobody/bin'"; then ok "[$t] offprint_clean_path, ~nobody/bin (another user's): left out, named"; else bad "[$t] clean ~user ($sh_out / $sh_err)"; fi
  sh_out="$(cd / && OFFPRINT_SITE="$site" HOME="$site/wp-content" PATH="~/bin:/usr/bin" "$B" -c ". '$root/lib/site.sh'; printf '%s' \"\$PATH\"" 2> "$tmp/cp.err")"; sh_err="$(cat "$tmp/cp.err")"
  if [ "$sh_out" = "$(physical /usr/bin)" ] && left "'$site/wp-content/bin'" "in the site folder"; then ok "[$t] sourcing lib/site.sh, ~/bin with HOME in the site folder: judged as HOME's, left out as the site's"; else bad "[$t] ~/bin in the site ($sh_out / $sh_err)"; fi
  # A HOME with a colon in it: bash takes ~/bin there as the one folder HOME/bin, which a PATH can't hold (its colon
  # would split it: into a relative entry, or an empty one, each whatever folder a command runs in). Left out, named,
  # saying why; the PATH a command's children see then has no relative or empty entry, nor a folder made of one.
  HOME=/nope:rel cp_run "~/bin:/usr/bin"
  if [ "$sh_out" = /usr/bin ] && left "'~/bin'" "HOME has a colon"; then ok "[$t] offprint_clean_path, ~/bin with HOME /nope:rel (a colon in it): left out, named, saying why"; else bad "[$t] clean ~, HOME with a colon ($sh_out / $sh_err)"; fi
  HOME=/x: cp_run "~:/usr/bin"
  if [ "$sh_out" = /usr/bin ] && left "'~'" "HOME has a colon"; then ok "[$t] offprint_clean_path, ~ with HOME /x: (ending in a colon): left out, named, never an empty entry"; else bad "[$t] clean ~, HOME ending in a colon ($sh_out / $sh_err)"; fi
  HOME=/nope:rel cp_run "rel2:~/bin:/usr/bin"
  if [ "$sh_out" = /usr/bin ] && left "'rel2'" "not an absolute path" "'~/bin'" "HOME has a colon"; then ok "[$t] offprint_clean_path, a relative entry and ~/bin with HOME /nope:rel: both named in one line, each with its reason"; else bad "[$t] clean relative and ~ ($sh_out / $sh_err)"; fi
  mkdir -p "$tmp/hc$n/rel/bin"
  for spec in "/nope:rel|~/bin" "/x:|~"; do
    h="${spec%%|*}"; e="${spec#*|}"
    sh_out="$(cd "$tmp/hc$n" && env -u OFFPRINT_SITE HOME="$h" PATH="$e:/usr/bin:/bin" "$B" -c ". '$root/lib/site.sh'; /usr/bin/env" 2> "$tmp/cp.err" | grep '^PATH=')"; sh_err="$(cat "$tmp/cp.err")"
    case ":${sh_out#PATH=}:" in
      *::*|*:[!/]*) bad "[$t] sourcing lib/site.sh, $e with HOME $h: a relative or empty entry reached a child ($sh_out / $sh_err)" ;;
      *) if [ "${sh_out#PATH=}" = "$(physical /usr/bin:/bin)" ] && left "'$e'" "HOME has a colon"; then ok "[$t] sourcing lib/site.sh, $e with HOME $h, run where rel/bin is: a child's PATH is the rest, named in one line"; else bad "[$t] source $e, HOME $h ($sh_out / $sh_err)"; fi ;;
    esac
  done
}
shell_cases "$(command -v bash)"
if [ -x /bin/bash ] && [ "$(command -v bash)" != /bin/bash ]; then shell_cases /bin/bash; fi

# ---- the loader never sources or evals -------------------------------------------------------
if grep -nE '(^|[^a-zA-Z_])(eval|source)[[:space:]]|^[[:space:]]*\.[[:space:]]' "$root/lib/site.sh" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then bad "lib/site.sh contains eval, source or a dot-command"; else ok "lib/site.sh has no eval, source or dot-command"; fi
if grep -nE 'mapfile|readarray|declare -A|\$\{[a-z_A-Z]+(,,|\^\^)' "$root/lib/site.sh" >/dev/null; then bad "lib/site.sh uses a bash 4 feature"; else ok "lib/site.sh avoids bash 4 features"; fi

[ "$fail" -eq 0 ]
