#!/usr/bin/env bash
# Tests bin/check-site on small folders in a temp dir. Run: bash tests/check-site.test.sh
# Works on macOS (bash 3.2) and Linux.
set -u
cd "$(dirname "$0")/.." || exit 1
root="$PWD"
# The suite's own temp folder, in TMPDIR (a template: without one, macOS's mktemp -d ignores TMPDIR), and TMPDIR
# inside it from here on, so nothing the suite runs leaves anything in the real one.
tmp="$(t="${TMPDIR:-/tmp}"; mktemp -d "${t%/}/offprint-check-site-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"
# The site's two hosts, as bin/publish passes them from site.json: tests/fixtures/site.json's, unlike any real site's,
# so a host written into bin/check-site instead of read from here fails the cases below.
export CHECK_SITE_HOST=www.example.com CHECK_SITE_LOCAL_HOST=mysite.test
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

n=0
newsite() {  # makes a valid small site in $site
  n=$((n + 1)); site="$tmp/s$n"
  mkdir -p "$site/feed"
  echo '<html><body><p>Hello</p></body></html>' > "$site/index.html"
  echo '<html><body><p>Not found</p></body></html>' > "$site/404.html"
  echo '<rss><channel><link>https://www.example.com/</link></channel></rss>' > "$site/feed/index.xml"
}
run() { out="$("$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"; }
fails() {  # description, expected text in the output
  run
  if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$2"; then ok "fails: $1"; else bad "fails: $1 (exit $code, output: $out)"; fi
}
fails_either() {  # description, text A, text B: exit 1 and the output holds one of them
  run
  if [ "$code" -eq 1 ] && { printf '%s' "$out" | grep -qF -- "$2" || printf '%s' "$out" | grep -qF -- "$3"; }; then ok "fails: $1"; else bad "fails: $1 (exit $code, output: $out)"; fi
}
passes() {
  run
  if [ "$code" -eq 0 ] && [ -z "$out" ]; then ok "passes: $1"; else bad "passes: $1 (exit $code, output: $out)"; fi
}

newsite; passes "a plain site"
newsite; rm "$site/index.html"; fails "index.html missing" "index.html"
newsite; rm "$site/404.html"; fails "404.html missing" "404.html"
newsite; rm "$site/feed/index.xml"; fails "feed/index.xml missing" "feed/index.xml"

newsite; echo 'var a = "https://mysite.test/x";' > "$site/a.js"; fails "mysite.test in a .js file" "a.js"
newsite; printf 'abc\000https://MYSITE.Test/x\000' > "$site/b.bin"; fails "MYSITE.Test in a binary file, any case" "b.bin"
newsite; mkdir -p "$site/d"; echo 'see mysite.test' > "$site/d/x.txt"; fails "mysite.test in a subfolder, path is relative" "d/x.txt"
newsite; for i in $(seq 1 23); do echo mysite.test > "$site/f$i.txt"; done
run
lines="$(printf '%s\n' "$out" | grep -c 'contains mysite.test')"
if [ "$code" -ne 0 ] && [ "$lines" -eq 20 ] && printf '%s' "$out" | grep -qF 'and 3 more'; then ok "mysite.test report is capped at 20 then 'and 3 more'"; else bad "mysite.test cap (exit $code, $lines lines)"; fi

newsite; echo '<a href="/wp-admin/">x</a>' > "$site/index.html"; fails "href=/wp-admin/" "/wp-admin/"
newsite; echo '<img src="https://www.example.com/wp-json/x">' > "$site/index.html"; fails "src to /wp-json/x" "wp-json/x"
newsite; echo '<form action="/wp-login.php"></form>' > "$site/index.html"; fails "action=/wp-login.php" "wp-login.php"
newsite; echo '<a href="https://www.example.com/wp-login.php?x=1">x</a>' > "$site/index.html"; fails "same-site /wp-login.php with a query" "wp-login.php"
newsite; echo '<a href="/?rest_route=/wp/v2/posts">x</a>' > "$site/index.html"; fails "rest_route= in the query" "rest_route"
newsite; echo '<img srcset="/a.png 1x, /wp-json/b.png 2x" src="/a.png">' > "$site/index.html"; fails "wp-json inside srcset" "wp-json/b.png"
newsite; echo '<video poster="/wp-admin/p.png"></video><object data="/xmlrpc.php"></object>' > "$site/index.html"; fails "poster and data" "wp-admin/p.png"
newsite; echo '<button formaction="/xmlrpc.php">x</button>' > "$site/index.html"; fails "formaction=/xmlrpc.php" "xmlrpc.php"
newsite; echo '<meta http-equiv="refresh" content="0; url=/wp-admin/">' > "$site/index.html"; fails "meta refresh to /wp-admin/" "wp-admin"
newsite; echo '<a href="/wp-%61dmin/">x</a>' > "$site/index.html"; fails "percent-encoded /wp-admin" "wp-admin"
newsite; mkdir -p "$site/a"; echo '<a href="../wp-admin/x">x</a>' > "$site/a/index.html"; fails "relative ../wp-admin resolved from a subfolder" "a/index.html"
newsite; echo '<a href="/wp-admin/&#x2F;">x</a>' > "$site/index.html"; fails "attribute with entities" "wp-admin"
newsite; echo '<style>body{background:url("/wp-admin/x.png")}</style>' > "$site/index.html"; fails "url() in <style>" "wp-admin/x.png"
newsite; echo '<p style="background:url(/wp-admin/x.png)">x</p>' > "$site/index.html"; fails "url() in style=\"\"" "wp-admin/x.png"
newsite; echo '<style>@import "/wp-json/c.css";</style>' > "$site/index.html"; fails "@import in <style>" "wp-json/c.css"
newsite; echo 'a{b:url(/wp-admin/x.png)}' > "$site/s.css"; fails "url() in a CSS file" "wp-admin/x.png"
newsite; echo '@import url("/wp-json/y.css");' > "$site/s.css"; fails "@import url() in a CSS file" "wp-json/y.css"
newsite; echo '<rss><channel><link>https://www.example.com/xmlrpc.php</link></channel></rss>' > "$site/feed/index.xml"; fails "feed <link> to xmlrpc.php" "xmlrpc.php"
newsite; echo '<rss><channel><item><guid>https://www.example.com/?rest_route=/x</guid></item></channel></rss>' > "$site/feed/index.xml"; fails "feed <guid> with rest_route" "rest_route"
newsite; echo '<rss><channel><atom:link href="https://www.example.com/wp-json/x" rel="self"/><item><enclosure url="/wp-admin/a.mp3"/></item></channel></rss>' > "$site/feed/index.xml"; fails "atom:link href" "wp-json/x"
newsite; echo '<urlset><url><loc><![CDATA[https://www.example.com/wp-admin/]]></loc></url></urlset>' > "$site/sitemap.xml"; fails "sitemap <loc> in CDATA" "wp-admin"
# A post's HTML inside a feed, escaped or in CDATA, is markup too.
newsite; echo '<rss><channel><item><description>&lt;a href="/wp-admin/d"&gt;x&lt;/a&gt;</description></item></channel></rss>' > "$site/feed/index.xml"; fails "feed <description> with escaped HTML" "wp-admin/d"
newsite; echo '<rss><channel><item><content:encoded><![CDATA[<p><img src="https://www.example.com/wp-json/e.png"></p>]]></content:encoded></item></channel></rss>' > "$site/feed/index.xml"; fails "feed <content:encoded> in CDATA" "wp-json/e.png"
newsite; echo '<feed><entry><content type="html">&lt;form action="/wp-login.php"&gt;&lt;/form&gt;</content><summary type="html">&lt;a href="/xmlrpc.php"&gt;x&lt;/a&gt;</summary></entry></feed>' > "$site/feed/index.xml"; fails "Atom <content> and <summary>" "wp-login.php"
newsite; echo '<rss><channel><item><description><![CDATA[<p>Open /wp-admin/ and call /wp-json/</p><code>/wp-login.php</code>]]></description></item></channel></rss>' > "$site/feed/index.xml"; passes "a feed whose post only writes about wp-admin"
# A feed is read with the XML parser, not by matching tags: a post that writes "</description>" can't hide what follows.
newsite; echo '<rss><channel><item><description><![CDATA[<p>Close it with </description> like this.</p><a href="/wp-admin/cd">x</a>]]></description></item></channel></rss>' > "$site/feed/index.xml"
fails "a literal </description> inside CDATA doesn't end the post's HTML" "wp-admin/cd"
newsite; echo '<rss><channel><item><content:encoded><![CDATA[<p></content:encoded></p><img src="/wp-json/ce.png">]]></content:encoded></item></channel></rss>' > "$site/feed/index.xml"
fails "nor a literal </content:encoded>" "wp-json/ce.png"
newsite; echo '<rss><channel><link><![CDATA[/wp-admin/</link>]]></link></channel></rss>' > "$site/feed/index.xml"; fails "a <link> whose CDATA holds </link>" "wp-admin"
newsite; echo '<feed><entry><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><a href="/wp-admin/xh">x</a></div></content></entry></feed>' > "$site/feed/index.xml"
fails "Atom XHTML content is markup" "wp-admin/xh"
newsite; echo '<rss><channel><link>https://www.example.com/</link></channel>' > "$site/feed/index.xml"; fails "a feed that isn't well-formed XML (fail closed)" "feed/index.xml: could not be read completely"
newsite; echo '<urlset><url><loc>https://www.example.com/a/</loc></url><url><loc>https://www.example.com/b/</loc>' > "$site/wp-sitemap.xml"; fails "a sitemap that isn't well-formed XML" "wp-sitemap.xml: could not be read completely"
newsite; : > "$site/wp-sitemap.xml"; fails "an empty XML file" "wp-sitemap.xml: is empty"
newsite; printf '  \n' > "$site/feed/index.xml"; fails "an XML file of only white space" "feed/index.xml: is empty"
# Entities that expand to a billion characters (7 levels of 10) must be refused unread and fast, in an element's
# text and in an attribute (where the parser would expand them while loading). Feeds and sitemaps never declare any.
bomb() {  # bomb WHERE: an RSS feed with the entity in <link>'s text, or in an href
  php -r '$e = "<!ENTITY a \"aaaaaaaaaa\">"; $p = "a";
    foreach ( array( "b", "c", "d", "e", "f", "g" ) as $n ) { $e .= "<!ENTITY $n \"" . str_repeat( "&$p;", 10 ) . "\">"; $p = $n; }
    $use = "text" === $argv[1] ? "<link>&g;</link>" : "<atom:link href=\"&g;\"/>";
    echo "<?xml version=\"1.0\"?><!DOCTYPE rss [$e]><rss><channel>$use</channel></rss>";' "$1"
}
for where in text attribute; do
  newsite; bomb "$where" > "$site/feed/index.xml"; start=$SECONDS
  fails "an entity bomb in an element's $where" "feed/index.xml: has a DOCTYPE or ENTITY declaration"
  if [ $((SECONDS - start)) -le 5 ]; then ok "and it is refused within 5 seconds ($where)"; else bad "the $where bomb took $((SECONDS - start)) seconds"; fi
done
newsite; printf '<?xml version="1.0"?>\n<!doctype rss>\n<rss><channel><link>https://www.example.com/</link></channel></rss>\n' > "$site/feed/index.xml"
fails "any DOCTYPE in a feed, in any case" "feed/index.xml: has a DOCTYPE or ENTITY declaration"
# A feed and a sitemap index as WordPress writes them (namespaces, CDATA, an xml-stylesheet instruction before the root),
# made up for the tests in tests/fixtures/export/. (tests/e2e.sh exports a real WordPress but doesn't run bin/check-site.)
newsite; cp "$root/tests/fixtures/export/feed/index.xml" "$site/feed/index.xml"; cp "$root/tests/fixtures/export/wp-sitemap.xml" "$site/wp-sitemap.xml"
passes "a feed and a sitemap in the shape WordPress writes them"

# --- a DTD in an encoding whose bytes don't spell <!DOCTYPE (UTF-16, UTF-7): the parser's own view decides, before it
# reads a single node. A quadratic bomb (one 10,000-character entity used 30,000 times: 300 million characters) is
# not stopped by libxml's limits, and expands when its text or attribute is read.
qbomb() {  # qbomb ENCODING WHERE
  php -r '$refs = str_repeat( "&a;", 30000 );
    $use  = "text" === $argv[2] ? "<link>$refs</link>" : "<atom:link href=\"$refs\"/>";
    $body = "<!DOCTYPE rss [<!ENTITY a \"" . str_repeat( "x", 10000 ) . "\">]><rss><channel>$use</channel></rss>";
    if ( "utf16" === $argv[1] ) { echo "\xFE\xFF", mb_convert_encoding( "<?xml version=\"1.0\" encoding=\"UTF-16\"?>$body", "UTF-16BE", "UTF-8" ); }
    else { echo "<?xml version=\"1.0\" encoding=\"UTF-7\"?>", str_replace( "<!", "+ADwAIQ-", $body ); }' "$1" "$2"
}
# measured: bin/check-site under /usr/bin/time where it can give the peak memory of it and its children (macOS -l, GNU
# time -v), stopped (with everything it started) after 20 seconds. Sets out, code ("hung" if stopped), secs, peak_mb
# ("" where this system can't measure it).
if /usr/bin/time -l true > /dev/null 2>&1; then timeflag=-l; elif /usr/bin/time -v true > /dev/null 2>&1; then timeflag=-v; else timeflag=""; fi
kill_tree() { local kids p; kids="$(pgrep -P "$1" 2>/dev/null)"; kill "$1" 2>/dev/null; for p in $kids; do kill_tree "$p"; done; }
measured() {
  local start=$SECONDS i=0 pid
  if [ -n "$timeflag" ]; then /usr/bin/time "$timeflag" "$root/bin/check-site" "$site" > "$tmp/out" 2> "$tmp/err" & pid=$!
  else "$root/bin/check-site" "$site" > "$tmp/out" 2> "$tmp/err" & pid=$!; fi
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill_tree "$pid"; wait "$pid" 2>/dev/null; code=hung; else wait "$pid"; code=$?; fi
  secs=$((SECONDS - start)); out="$(cat "$tmp/out")"; peak_mb=""
  case "$timeflag" in
    -l) peak_mb="$(awk '/maximum resident set size/ { print int($1 / 1048576) }' "$tmp/err")" ;;
    -v) peak_mb="$(awk -F: '/Maximum resident set size/ { print int($2 / 1024) }' "$tmp/err")" ;;
  esac
}
# Newer libxml (2.11 and later, as on the Linux runners) refuses this bomb itself while parsing ("Maximum entity
# amplification factor exceeded"); older ones (macOS's 2.9) load it, and the doctype check refuses it. Either is fine:
# what matters is that it is refused, fast, in little memory. The small DTD below can only be refused by the doctype check.
for enc in utf16 utf7; do
  for where in text attribute; do
    newsite; qbomb "$enc" "$where" > "$site/feed/index.xml"; measured; t="a quadratic entity bomb in $enc, in an element's $where"
    if [ "$code" = 1 ] && { printf '%s' "$out" | grep -qF "feed/index.xml: has a DOCTYPE or ENTITY declaration" \
      || printf '%s' "$out" | grep -qF "feed/index.xml: could not be read completely"; }; then ok "fails: $t"
    else bad "fails: $t (exit $code, output: $(printf '%s' "$out" | head -c 300))"; fi
    if [ "$secs" -le 10 ]; then ok "$t: within 10 seconds"; else bad "$t: took $secs seconds"; fi
    if [ "$code" = hung ]; then bad "$t: peak memory not measured (it was stopped)"
    elif [ -z "$peak_mb" ]; then echo "skip  $t: peak memory (no /usr/bin/time -l or -v here)"
    elif [ "$peak_mb" -le 150 ]; then ok "$t: peak memory under 150 MB ($peak_mb MB)"; else bad "$t: peak memory $peak_mb MB"; fi
  done
done
utf16() { php -r 'echo "\xFE\xFF", mb_convert_encoding( "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" . $argv[1], "UTF-16BE", "UTF-8" );' "$1"; }
utf7() { printf '<?xml version="1.0" encoding="UTF-7"?>%s' "$(printf '%s' "$1" | sed 's/<!/+ADwAIQ-/g')"; }
small_dtd='<!DOCTYPE rss [<!ENTITY a "https://www.example.com/">]><rss><channel><link>&a;</link></channel></rss>'
newsite; utf16 "$small_dtd" > "$site/feed/index.xml"; fails "a small DTD in UTF-16 (any libxml loads it; the doctype check refuses it)" "feed/index.xml: has a DOCTYPE or ENTITY declaration"
newsite; utf7 "$small_dtd" > "$site/feed/index.xml"; fails "a small DTD in UTF-7" "feed/index.xml: has a DOCTYPE or ENTITY declaration"
newsite; utf16 '<rss><channel><link>https://www.example.com/</link></channel></rss>' > "$site/feed/index.xml"; passes "a UTF-16 feed without a DTD"
newsite; utf16 '<rss><channel><link>https://www.example.com/wp-admin/</link></channel></rss>' > "$site/feed/index.xml"; fails "and its addresses are read" "wp-admin"
# A post's own markup may hold a document type declaration (SVG code in a Custom HTML block): in CDATA it is text.
newsite; printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><rss><channel><link>https://www.example.com/</link><item><content:encoded><![CDATA[<p>An icon:</p><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>]]></content:encoded></item></channel></rss>' > "$site/feed/index.xml"
passes "a feed whose post holds <!DOCTYPE svg …> in CDATA"
newsite; printf '<?xml version="1.0"?>\n<!-- <rss> -->\n<!DOCTYPE rss>\n<rss><channel><link>https://www.example.com/</link></channel></rss>\n' > "$site/feed/index.xml"
fails "a DOCTYPE after a comment in the prolog" "feed/index.xml: has a DOCTYPE or ENTITY declaration"

# --- a page or stylesheet in UTF-16 or UTF-32 (a feed is read by the XML parser, in its own encoding: see above): a browser reads it (the mark at its start outranks everything
# else that names an encoding), and none of the checks here can: no link, no host name, no form shows in its bytes ---
utf16() { printf '%s' "$1" | iconv -f UTF-8 -t "$2"; }
not_utf8="is written in UTF-16 or UTF-32, which the checks can't read (WordPress writes UTF-8)"
newsite; { printf '\377\376'; utf16 '<html><body><a href="/wp-admin/">x</a> mysite.test</body></html>' UTF-16LE; } > "$site/a.html"
fails "a page in UTF-16, little end first" "a.html: $not_utf8"
newsite; { printf '\376\377'; utf16 '<html><body><a href="/wp-admin/">x</a></body></html>' UTF-16BE; } > "$site/a.html"
fails "a page in UTF-16, big end first" "a.html: $not_utf8"
newsite; { printf '\377\376\000\000'; utf16 '<html><body><a href="/wp-admin/">x</a></body></html>' UTF-32LE; } > "$site/a.html"
fails "a page in UTF-32, little end first" "a.html: $not_utf8"
newsite; { printf '\000\000\376\377'; utf16 '<html><body><a href="/wp-admin/">x</a></body></html>' UTF-32BE; } > "$site/a.html"
fails "a page in UTF-32, big end first" "a.html: $not_utf8"
newsite; { printf '\377\376'; utf16 'a { background: url(/wp-admin/x.png) }' UTF-16LE; } > "$site/a.css"
fails "a stylesheet in UTF-16" "a.css: $not_utf8"
newsite; printf '\357\273\277<html><body><p>Hello</p></body></html>' > "$site/a.html"; passes "a page with UTF-8's own mark at its start"
newsite; printf '\377\376\001\002' > "$site/a.bin"; passes "a file that is no page, starting with the same two bytes"

# --- no single page or feed over 32 MB: the parsers would take gigabytes ---
newsite; dd if=/dev/null of="$site/big.html" bs=1 count=0 seek=34000000 2>/dev/null; fails "an HTML file over 32 MB" "big.html: is larger than 32 MB; that is not a page"
newsite; dd if=/dev/null of="$site/wp-sitemap.xml" bs=1 count=0 seek=34000000 2>/dev/null; fails "an XML file over 32 MB" "wp-sitemap.xml: is larger than 32 MB; that is not a page"
newsite; mkdir "$site/p"; printf '<!DOCTYPE html>' > "$site/p/noext"; dd if=/dev/null of="$site/p/noext" bs=1 count=0 seek=34000000 2>/dev/null
fails "extensionless markup over 32 MB" "p/noext: is larger than 32 MB; that is not a page"
newsite; dd if=/dev/null of="$site/big.css" bs=1 count=0 seek=34000000 2>/dev/null; passes "a big file that isn't markup (it is in the total size)"
# A 27 MB feed of 270 posts is fine.
newsite; php -r '$p = "<p>" . str_repeat( "word ", 20000 ) . "</p>"; echo "<?xml version=\"1.0\"?><rss><channel><link>https://www.example.com/</link>";
  for ( $i = 0; $i < 270; $i++ ) { echo "<item><link>https://www.example.com/p$i/</link><content:encoded><![CDATA[$p]]></content:encoded></item>"; }
  echo "</channel></rss>";' > "$site/feed/index.xml"
passes "a 27 MB feed ($(wc -c < "$site/feed/index.xml" | tr -d ' ') bytes)"

# --- same-site only: other hosts may be linked ---
newsite; echo '<a href="https://example.com/wp-admin/">a</a><a href="//example.org/wp-json/x">b</a><a href="https://example.com/blog/wp-login.php">c</a>' > "$site/index.html"; passes "links to other sites' /wp-admin, /wp-json, wp-login.php"
newsite; echo '<a href="//www.example.com/wp-admin/">a</a>' > "$site/index.html"; fails "protocol-relative same-site" "wp-admin"
newsite; echo '<a href="https://WWW.Example.COM./wp-admin/">a</a>' > "$site/index.html"; fails "host in other case with a trailing dot" "wp-admin"
newsite; echo '<a href="https://www.example.com:443/wp-admin/">a</a>' > "$site/index.html"; fails "same host with a default port" "wp-admin"
newsite; echo '<a href="https://user@www.example.com/wp-admin/">a</a>' > "$site/index.html"; fails "same host behind userinfo" "wp-admin"
newsite; echo '<a href="https://mysite.test/wp-json/">a</a>' > "$site/index.html"; fails "mysite.test host" "wp-json"
newsite; echo '<a href="https://www.example.com.evil.example/wp-admin/">a</a>' > "$site/index.html"; passes "a look-alike host is another site"
newsite; echo '<a href="https://other.test/wp-admin/">a</a>' > "$site/index.html"; CHECK_SITE_HOST=other.test fails "CHECK_SITE_HOST sets the site's host" "wp-admin"
newsite; echo '<a href="https://local.other/wp-admin/">a</a>' > "$site/index.html"; passes "control: with another local host, local.other is another site"
CHECK_SITE_LOCAL_HOST=local.other fails "CHECK_SITE_LOCAL_HOST is a same-site host in the address check too" "index.html: https://local.other/wp-admin/ points at /wp-admin"

# --- the two hosts come from the environment only: both must be set, and look like a hostname, before anything is read
# or any pattern is made from them ---
# refused T: exit 2, nothing on stdout, a reason on stderr naming VAR
refused() {
  if [ "$code" -eq 2 ] && [ -z "$out" ] && printf '%s' "$err" | grep -qF -- "$2"; then ok "refused: $1"
  else bad "refused: $1 (exit $code, out '$out', err '$err')"; fi
}
for v in CHECK_SITE_HOST CHECK_SITE_LOCAL_HOST; do
  newsite; echo '<p>mysite.test</p>' > "$site/index.html"
  out="$(env -u "$v" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"; refused "without $v" "$v"
  out="$(env "$v=" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"; refused "with $v empty" "$v"
done
newsite; out="$(env -u CHECK_SITE_HOST -u CHECK_SITE_LOCAL_HOST "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
refused "with neither" "CHECK_SITE_HOST"
nl="$(printf 'a.b\nc.d')"
for v in CHECK_SITE_HOST CHECK_SITE_LOCAL_HOST; do
  for h in 'a b.c' 'x;id.y' '$(touch pwned).x' "$nl" '-e.x' '.*' 'a..b' 'nodot' 'a.b/c' "a.b'" '*.example.com' 'a.b|c.d' '[a].b' 'café.example' 'x-.y'; do
    newsite; out="$(cd "$tmp" && env "$v=$h" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
    refused "$v=$(printf '%s' "$h" | tr '\n' '?') is not a hostname" "$v"
  done
done
if [ -n "$(find "$tmp" -name pwned)" ] || [ -e "$root/pwned" ]; then bad "a host value ran a command"; else ok "no host value ran a command"; fi

# --- the local host is searched for as itself: each dot is a dot or one of its encodings, never "any character" (the
# search is built from CHECK_SITE_LOCAL_HOST, every regex character escaped) ---
for s in 'offprint.local' 'offprint&#46;local' 'OFFPRINT%2Elocal' 'offprint&#x2E;local' 'offprint&period;local' 'x.offprint.local.y'; do
  newsite; echo "<p>$s</p>" > "$site/index.html"; CHECK_SITE_LOCAL_HOST=offprint.local fails "local host offprint.local: a page saying $s" "contains offprint.local: index.html"
done
for s in 'offprintxlocal' 'offprint-local' 'offprint local' 'offprint&#47;local'; do
  newsite; echo "<p>$s</p>" > "$site/index.html"; CHECK_SITE_LOCAL_HOST=offprint.local passes "local host offprint.local: a page saying $s"
done
# A label with a hyphen in it.
for s in 'my-site.test' 'my-site&#46;test' 'MY-SITE%2etest'; do
  newsite; echo "<p>$s</p>" > "$site/index.html"; CHECK_SITE_LOCAL_HOST=my-site.test fails "local host my-site.test: a page saying $s" "contains my-site.test: index.html"
done
for s in 'my-sitextest' 'mysite.test' 'my_site.test'; do
  newsite; echo "<p>$s</p>" > "$site/index.html"; CHECK_SITE_LOCAL_HOST=my-site.test passes "local host my-site.test: a page saying $s"
done
newsite; for i in $(seq 1 21); do echo offprint.local > "$site/f$i.txt"; done
CHECK_SITE_LOCAL_HOST=offprint.local fails "the count line names the local host too" "and 1 more files contain offprint.local"

# --- the HTML parser must not give up silently ---
newsite; { for i in $(seq 1 300); do printf '<div>'; done; echo '<a href="/wp-admin/deep">x</a>'; } > "$site/index.html"; fails "an address 300 elements deep" "wp-admin/deep"
newsite; { printf '<p>'; head -c 12000000 /dev/zero | tr '\0' 'a'; echo '</p><a href="/wp-admin/huge">x</a>'; } > "$site/index.html"; fails "an address after a 12 MB text node" "wp-admin/huge"
newsite; { for i in $(seq 1 5000); do printf '<div>'; done; echo '<a href="/wp-admin/deeper">x</a>'; } > "$site/index.html"; fails_either "an address 5000 elements deep (either the address or 'could not be read completely' is accepted)" "wp-admin/deeper" "could not be read completely"

# --- unparsable-looking and unusual address forms ---
for a in '/wp-admin/x:80' '/wp-json/wp/v2/posts:1' '/wp-admin/:80/c22' 'wp-admin/x:1' ; do
  newsite; echo "<a href=\"$a\">x</a>" > "$site/index.html"; fails "odd address $a" "wp-"
done
newsite; echo '<meta http-equiv="refresh" content="0; /wp-admin/">' > "$site/index.html"; fails "meta refresh without url=" "wp-admin"
newsite; echo 'a{b:url(/wp\2d admin/x.png)}' > "$site/s.css"; fails "CSS hex escape in url()" "wp-admin"
newsite; echo 'a{b:url(/\77 p-admin/x.png)}' > "$site/s.css"; fails "CSS escape of the first letter" "wp-admin"
newsite; echo '@import"/wp-json/x.css";' > "$site/s.css"; fails "@import with no space" "wp-json"
newsite; echo '<svg><use xlink:href="/wp-admin/s.svg#a"/></svg>' > "$site/index.html"; fails "xlink:href" "wp-admin"
newsite; echo '<img imagesrcset="/wp-json/a.png 1x">' > "$site/index.html"; fails "imagesrcset" "wp-json"
newsite; echo '<a ping="/ok /wp-admin/ping">x</a>' > "$site/index.html"; fails "ping" "wp-admin"
newsite; echo '<blockquote cite="/wp-admin/q">x</blockquote><object data="/ok"></object><body background="/wp-json/bg.png">' > "$site/index.html"; fails "cite and background" "wp-"
newsite; echo '<html manifest="/wp-admin/m"><body></body></html>' > "$site/index.html"; fails "manifest" "wp-admin"
newsite; echo '<img longdesc="/wp-json/d">' > "$site/index.html"; fails "longdesc" "wp-json"
newsite; echo '<iframe srcdoc="&lt;a href=&quot;/wp-admin/in&quot;&gt;x&lt;/a&gt;"></iframe>' > "$site/index.html"; fails "iframe srcdoc is parsed as HTML" "wp-admin/in"
newsite; echo '<base href="/wp-admin/"><a href="x.html">x</a>' > "$site/index.html"; fails "<base href> changes where relative addresses go" "x.html"
newsite; echo '<base href="https://example.com/wp-admin/"><a href="x.html">x</a>' > "$site/index.html"; passes "<base> on another site"
newsite; echo '<feed><link href="https://www.example.com/xmlrpc.php" rel="self"/></feed>' > "$site/feed/index.xml"; fails "Atom <link href/>" "xmlrpc.php"
for f in a.htm a.xhtml a.svg; do newsite; echo '<a href="/wp-admin/z" xlink:href="/wp-admin/z">x</a>' > "$site/$f"; fails "$f is parsed as markup" "$f"; done
for f in a.rss a.atom; do newsite; echo '<rss><link>/wp-admin/z</link></rss>' > "$site/$f"; fails "$f is parsed as a feed" "$f"; done
newsite; mkdir "$site/.well-known"; echo '<a href="../wp-admin/z">x</a>' > "$site/.well-known/page.html"; fails "a relative address in a file under .well-known/" ".well-known/page.html"
newsite; mkdir "$site/.wp-admin"; echo '<a href="x.html">x</a>' > "$site/.wp-admin/page.html"; passes "a folder named .wp-admin is not /wp-admin"
newsite; mkdir "$site/p"; echo '<!DOCTYPE html><a href="/wp-admin/z">x</a>' > "$site/p/noext"; fails "extensionless HTML" "p/noext"
newsite; mkdir "$site/p"; printf '<?xml version="1.0"?><rss><link>/wp-admin/z</link></rss>' > "$site/p/feedfile"; fails "extensionless XML" "p/feedfile"
newsite; mkdir "$site/p"; echo 'just words <a href="/wp-admin/z">' > "$site/p/notes"; passes "extensionless plain text is not parsed"

# --- extra slashes before the host, other hosts' spellings ---
for a in 'https:///www.example.com/wp-admin/' '///www.example.com/wp-admin/' 'https:\\\www.example.com\wp-admin' '////www.example.com/wp-admin/' 'https://www。example.com/wp-admin/' 'https://www．example.com/wp-admin/' 'https://www｡example.com/wp-admin/' 'https://ｗｗｗ.example.com/wp-admin/' ; do
  newsite; printf '<a href="%s">x</a>\n' "$a" > "$site/index.html"; fails "HTML address $a" "wp-admin"
  case "$a" in *'\'*) ;; *)   # in CSS a backslash is an escape, not a slash
  newsite; printf 'a{b:url(%s)}\n' "$a" > "$site/s.css"; fails "CSS address $a" "wp-admin" ;; esac
  newsite; printf '<rss><channel><link>%s</link></channel></rss>\n' "$a" > "$site/feed/index.xml"; fails "feed address $a" "wp-admin"
done
newsite; echo '<a href="https:///example.com/wp-admin/">x</a>' > "$site/index.html"; passes "extra slashes before another site's host"
newsite; mkdir "$site/sub"; echo '<base href="https://www.example.com"><a href="wp-admin/">x</a>' > "$site/sub/index.html"; fails "<base> with a host and no path" "wp-admin"
newsite; mkdir "$site/sub"; echo '<base href="//www.example.com"><a href="wp-json/">x</a>' > "$site/sub/index.html"; fails "protocol-relative <base> with no path" "wp-json"

# --- mysite.test spelled differently ---
for s in 'mysite&#46;test' 'mysite&#x2e;test' 'MYSITE&#X2E;TEST' 'mysite%2Etest' 'mysite%2etest' 'mysite&period;test'; do
  newsite; echo "<p>$s</p>" > "$site/index.html"; fails "mysite.test spelled $s" "index.html"
done

newsite; echo '<p>Open wp-admin and call /wp-json/ or visit /wp-login.php</p>' > "$site/index.html"; passes "page text that mentions wp-admin and /wp-json/"
newsite; echo '<pre><code>wp-login.php</code></pre><code>/xmlrpc.php</code>' > "$site/index.html"; passes "<code> blocks"
newsite; echo 'fetch("/wp-json/wp/v2/posts"); var a="/wp-admin/";' > "$site/a.js"; passes ".js file with wp-json"
newsite; echo '<a href="/wp-content/x.png">x</a><a href="mailto:a@b.c">m</a><a href="/wp-administration-notes/">n</a>' > "$site/index.html"
passes "wp-content, mailto, and a slug that starts with wp-admin"

# --- only WordPress's own addresses: /wp-admin and /wp-json as the whole first segment, the scripts at the root ---
for a in /wp-admin-tips/ /wp-json-explained/ /tag/wp-admin/ /tag/wp-json/ /tag/feed/ /tag/x/feed/ /blog/wp-login.php /blog/xmlrpc.php /2026/wp-admin/ wp-json-notes/; do
  newsite; echo "<a href=\"$a\">x</a>" > "$site/index.html"; passes "a post, tag or file whose address only has WordPress's names in it: $a"
done
for a in /wp-admin /wp-admin/ /WP-JSON /wp-json/wp/v2/posts /index.php/wp-json/wp/v2/posts /wp-login.php /xmlrpc.php /wp-login.php/x /tag/../wp-admin/; do
  newsite; echo "<a href=\"$a\">x</a>" > "$site/index.html"; fails "WordPress's own address $a" "$a"
done
# WordPress matches what follows /index.php/ against its rule ^index.php/wp-json, whose dot is any character: so
# wp-json anywhere after a leading index.php is the REST API, and so is index.php spelled with any dot.
for a in /index.php/index.php/wp-json/wp/v2/posts /index.php/indexXphp/wp-json/ /INDEX.PHP/wp-json/ /index.php/tag/x/wp-json/ \
  /indexXphp/wp-json/wp/v2/posts /index.php/index.php/wp-admin/ /index.php/index.php/xmlrpc.php https://www.example.com/index.php/index.php/wp-json/; do
  newsite; echo "<a href=\"$a\">x</a>" > "$site/index.html"; fails "the REST API or admin behind index.php: $a" "$a"
done
for a in /tag/index.php/wp-json/ /index.php/about/ /about/index.php; do
  newsite; echo "<a href=\"$a\">x</a>" > "$site/index.html"; passes "index.php's name without wp-json after a leading index.php: $a"
done

newsite; ln -s index.html "$site/link.html"; fails "a symlink to a file" "link.html"
newsite; mkdir "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$site/dir"; fails "a symlink to a folder" "dir"
newsite; : > "$site/$(printf 'bad\001name')"; fails "a control character in a name" "control character"

# --- nothing git would treat as its own: a repository (git runs commands its config names), or a file that changes
# what git does with the files around it ---
newsite; mkdir -p "$site/x/.git"; echo '[core]' > "$site/x/.git/config"; fails "a .git folder in a subfolder" "x/.git"
newsite; echo 'gitdir: /tmp/elsewhere' > "$site/.git"; fails "a .git file at the root" "./.git"
newsite; mkdir -p "$site/y/.GIT"; fails "a .GIT folder (the Mac's disk ignores case)" "y/.GIT"
for f in .gitattributes .gitmodules .gitignore .GitIgnore; do
  newsite; mkdir -p "$site/d"; echo '*' > "$site/d/$f"; fails "a $f file" "d/$f"
done
newsite; mkdir -p "$site/.github" "$site/z.git" "$site/a.gitignore"; echo x > "$site/.gitkeep"; passes "names that only start or end like git's"

# --- a name the publish writes at the root (CHECK_SITE_RESERVED; here build.json, which a host's deploy writes), in any
# case, can't come from the export ---
for f in build.json Build.json BUILD.JSON; do
  newsite; echo '{"commit":"x"}' > "$site/$f"; CHECK_SITE_RESERVED=build.json fails "$f at the root" "$f"
done
newsite; mkdir -p "$site/wp-content/plugins/p"; echo '{}' > "$site/wp-content/plugins/p/build.json"; CHECK_SITE_RESERVED=build.json passes "a build.json deeper down (a theme's or a plugin's)"
newsite; echo '{"commit":"x"}' > "$site/build.json"; passes "build.json at the root, with no name reserved (no host's file is known here)"
# Each reserved name, in any case, a file or a folder; the message names the reserved name and what the export has.
for f in _headers _HEADERS Offprint.JSON; do
  newsite; echo x > "$site/$f"; lower="$(printf '%s' "$f" | tr 'A-Z' 'a-z')"
  CHECK_SITE_RESERVED="offprint.json _headers" fails "reserved: $f at the root" "the publish writes $lower at the root, so the export can't have one: ./$f"
done
newsite; mkdir "$site/_Redirects"; CHECK_SITE_RESERVED="_redirects" fails "reserved: a folder called _Redirects at the root" "the publish writes _redirects at the root, so the export can't have one: ./_Redirects"
newsite; mkdir "$site/a"; echo x > "$site/a/_headers"; CHECK_SITE_RESERVED="_headers offprint.json" passes "reserved: the same name deeper down is the export's own"
# CHECK_SITE_ALLOWED: reserved names the publish has just written itself, allowed exactly as written (and only those).
newsite; echo x > "$site/_headers"; CHECK_SITE_RESERVED="offprint.json _headers" CHECK_SITE_ALLOWED="_headers" passes "allowed: _headers, written by the publish"
newsite; echo x > "$site/_Headers"; CHECK_SITE_RESERVED="_headers" CHECK_SITE_ALLOWED="_headers" fails "allowed: _headers, but the root has _Headers" "can't have one: ./_Headers"
newsite; echo x > "$site/_headers"; echo '{}' > "$site/offprint.json"; CHECK_SITE_RESERVED="offprint.json _headers" CHECK_SITE_ALLOWED="_headers" \
  fails "allowed: _headers, and the root has offprint.json too" "the publish writes offprint.json at the root, so the export can't have one: ./offprint.json"
# A disk that ignores case (the Mac's) folds it in Unicode, which find -iname doesn't: there a long s (U+017F) opens as an
# s, the ff ligature (U+FB00) as ff, the Kelvin sign (U+212A) as a k. The disk's own lookup finds them; an allowed name
# lets by only the entry spelt exactly so. (Only where this disk folds them: folds VARIANT NAME.)
LONG_S="$(printf '\305\277')"; FF="$(printf '\357\254\200')"; KELVIN="$(printf '\342\204\252')"
folds() { local d r; d="$(mktemp -d "$tmp/fold.XXXXXX")"; : > "$d/$1"; [ -e "$d/$2" ]; r=$?; rm -f "$d/$1"; rmdir "$d"; return "$r"; }
for spec in "_header$LONG_S|_headers" "o${FF}print.json|offprint.json" "_wor${KELVIN}er.js|_worker.js"; do
  v="${spec%%|*}"; name="${spec#*|}"
  if ! folds "$v" "$name"; then echo "skip  $v taken for $name (this disk doesn't fold it)"; continue; fi
  msg="the publish writes $name at the root, so the export can't have one: ./$v"
  newsite; echo x > "$site/$v"; CHECK_SITE_RESERVED="$name" fails "reserved: $v (this disk takes it for $name)" "$msg"
  CHECK_SITE_RESERVED="$name" CHECK_SITE_ALLOWED="$name" fails "allowed: $name doesn't let $v by" "$msg"
  newsite; ln -s /etc/hosts "$site/$v"; CHECK_SITE_RESERVED="$name" CHECK_SITE_ALLOWED="$name" fails "reserved: $v, a symlink" "$msg"
  newsite; mkdir "$site/$v"; CHECK_SITE_RESERVED="$name" fails "reserved: $v, a folder" "$msg"
done
# --- names the host gives a meaning of its own at the root of what it is given (CHECK_SITE_SPECIAL; here an ignore file
# and a code file): in any case, a file or a folder, never allowed (no publish writes one); deeper down, the export's own ---
for f in .hostignore .HOSTIGNORE _hostcode.js _HostCode.JS; do
  newsite; echo x > "$site/$f"; lower="$(printf '%s' "$f" | tr 'A-Z' 'a-z')"
  CHECK_SITE_SPECIAL=".hostignore _hostcode.js" fails "special: $f at the root" "the host gives $lower a meaning of its own at the root, so the export can't have one: ./$f"
done
newsite; mkdir "$site/_hostcode.js"; echo x > "$site/_hostcode.js/x"; CHECK_SITE_SPECIAL="_hostcode.js" fails "special: a folder called _hostcode.js at the root" "the host gives _hostcode.js a meaning of its own at the root, so the export can't have one: ./_hostcode.js"
newsite; mkdir "$site/a"; echo x > "$site/a/.hostignore"; CHECK_SITE_SPECIAL=".hostignore" passes "special: the same name deeper down is the export's own"
newsite; echo x > "$site/.hostignore"; CHECK_SITE_SPECIAL=".hostignore" CHECK_SITE_RESERVED=".hostignore" CHECK_SITE_ALLOWED=".hostignore" \
  fails "special: never allowed, whatever CHECK_SITE_ALLOWED says" "the host gives .hostignore a meaning of its own at the root, so the export can't have one: ./.hostignore"
newsite; echo x > "$site/.hostignore"; passes "special: .hostignore at the root, with no name given (no host is known here)"
for spec in ".ho${LONG_S}tignore|.hostignore" "_hostcode.j${LONG_S}|_hostcode.js"; do
  v="${spec%%|*}"; name="${spec#*|}"
  if ! folds "$v" "$name"; then echo "skip  $v taken for $name (this disk doesn't fold it)"; continue; fi
  newsite; echo x > "$site/$v"; CHECK_SITE_SPECIAL="$name" fails "special: $v (this disk takes it for $name)" "the host gives $name a meaning of its own at the root, so the export can't have one: ./$v"
done
for value in '*' 'a/b' '..' '.' 'a;b' '$(touch pwned)' "$(printf 'a\nb')" 'a?' '[ab]'; do
  newsite; out="$(cd "$tmp" && env "CHECK_SITE_SPECIAL=$value" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
  refused "CHECK_SITE_SPECIAL='$(printf '%s' "$value" | tr '\n\t' '??')' is not file names" "CHECK_SITE_SPECIAL"
done
# The names come from the environment: each must be a plain file name before a pattern is made from it.
for v in CHECK_SITE_RESERVED CHECK_SITE_ALLOWED; do
  for value in '*' 'a/b' '..' '.' 'a;b' '$(touch pwned)' "$(printf 'a\nb')" 'a?' '[ab]' "a$(printf '\t')b"; do
    newsite; out="$(cd "$tmp" && env "$v=$value" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
    refused "$v='$(printf '%s' "$value" | tr '\n\t' '??')' is not file names" "$v"
  done
done

# --- limits from the environment (0 or unset: none), a warning on stderr from 80% ---
newsite; CHECK_SITE_MAX_FILES=2 fails "more files than CHECK_SITE_MAX_FILES" "too many files: 3, the limit is 2"
newsite; CHECK_SITE_MAX_FILES=3 run
if [ "$code" -eq 0 ] && [ -z "$out" ] && [ "$err" = "warning: the site has 3 files, over 80% of the 3 limit" ]; then ok "passes with a warning at 80% of CHECK_SITE_MAX_FILES"; else bad "80% of the file limit (exit $code, out '$out', err '$err')"; fi
newsite; CHECK_SITE_MAX_FILES=4 run
if [ "$code" -eq 0 ] && [ -z "$err" ]; then ok "passes without a warning under 80% of CHECK_SITE_MAX_FILES"; else bad "under the file limit (exit $code, err '$err')"; fi
newsite; mkdir "$site/d"; printf '%01000d' 0 > "$site/d/big.txt"
CHECK_SITE_MAX_FILE_BYTES=999 fails "a file over CHECK_SITE_MAX_FILE_BYTES" "d/big.txt is 1000 bytes, the limit for one file is 999"
for limit in 1000 1250; do
  CHECK_SITE_MAX_FILE_BYTES=$limit run
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ "$err" = "warning: d/big.txt is 1000 bytes, over 80% of the $limit limit for one file" ]; then ok "passes with a warning: a file at $((100000 / limit))% of CHECK_SITE_MAX_FILE_BYTES"
  else bad "a file near the limit of $limit (exit $code, out '$out', err '$err')"; fi
done
CHECK_SITE_MAX_FILE_BYTES=1251 run
if [ "$code" -eq 0 ] && [ -z "$err" ]; then ok "passes without a warning: a file under 80% of CHECK_SITE_MAX_FILE_BYTES"; else bad "a file under the limit (exit $code, err '$err')"; fi
newsite; head -c 3000 /dev/urandom | base64 > "$site/big.txt"
CHECK_SITE_MAX_BYTES=0 CHECK_SITE_MAX_FILES=0 CHECK_SITE_MAX_FILE_BYTES=0 run
if [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then ok "every limit 0: no limit, no warning"; else bad "limits of 0 (exit $code, out '$out', err '$err')"; fi
for v in CHECK_SITE_MAX_BYTES CHECK_SITE_MAX_FILES CHECK_SITE_MAX_FILE_BYTES; do
  for value in abc -1 08 1.5 '1 2' '$(touch pwned)' 'a[$(touch pwned)]' 1234567890123456 ' 5'; do
    newsite; out="$(cd "$tmp" && env "$v=$value" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
    refused "$v='$value' is not a whole number" "$v"
  done
done
if [ -n "$(find "$tmp" -name pwned)" ] || [ -e "$root/pwned" ]; then bad "a name or a limit ran a command"; else ok "no name or limit ran a command"; fi

newsite; head -c 3000 /dev/urandom | base64 > "$site/big.txt"
CHECK_SITE_MAX_BYTES=1000 run; if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -qF 'too big'; then ok "fails: larger than the limit"; else bad "fails: larger than the limit (exit $code, $out)"; fi
size="$(tar -czf - -C "$site" . | wc -c | tr -d ' ')"
CHECK_SITE_MAX_BYTES=$((size * 5 / 4)) run
if [ "$code" -eq 0 ] && [ -z "$out" ] && printf '%s' "$err" | grep -q 'warning'; then ok "passes with a warning at 80% of the limit"; else bad "80% case (exit $code, out '$out', err '$err')"; fi
CHECK_SITE_MAX_BYTES=$((size * 3)) run
if [ "$code" -eq 0 ] && [ -z "$err" ]; then ok "passes without a warning well under the limit"; else bad "under limit (exit $code, err '$err')"; fi

# --- a file the publish still writes at the root after the check (its id file): counted as if it were there ---
# CHECK_SITE_TO_COME names it, CHECK_SITE_TO_COME_BYTES is its size. tc CMD...: CMD with offprint.json of 55 bytes to
# come (reserved, as bin/publish passes it). warns T LIMIT_VAR LIMIT WARNING: passes, and its one warning is WARNING ("" none).
tc() { CHECK_SITE_RESERVED=offprint.json CHECK_SITE_TO_COME=offprint.json CHECK_SITE_TO_COME_BYTES=55 "$@"; }
warns() {
  env "$2=$3" CHECK_SITE_RESERVED=offprint.json CHECK_SITE_TO_COME=offprint.json CHECK_SITE_TO_COME_BYTES=55 "$root/bin/check-site" "$site" > "$tmp/out" 2> "$tmp/err"
  code=$?; out="$(cat "$tmp/out")"; err="$(cat "$tmp/err")"
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ "$err" = "$4" ]; then ok "$1"; else bad "$1 (exit $code, out '$out', err '$err')"; fi
}
newsite; warns "to come: 3 files and it, at a limit of 4 files: passes, warning of 4" CHECK_SITE_MAX_FILES 4 "warning: the site has 4 files, over 80% of the 4 limit"
newsite; CHECK_SITE_MAX_FILES=3 tc fails "to come: 3 files and it, a limit of 3 files" "too many files: 4, the limit is 3"
newsite; CHECK_SITE_MAX_FILES=3 run
if [ "$code" -eq 0 ] && [ -z "$out" ]; then ok "control: the same 3 files, nothing to come: within a limit of 3"; else bad "nothing to come, 3 files (exit $code, out '$out')"; fi
newsite; warns "to come: 4 files in all are 80% of a limit of 5: the warning" CHECK_SITE_MAX_FILES 5 "warning: the site has 4 files, over 80% of the 5 limit"
newsite; warns "to come: 4 files in all are under 80% of a limit of 6: no warning" CHECK_SITE_MAX_FILES 6 ""
# For one file: a site whose own files are all smaller than the one to come (its feed is <rss/>).
small() { newsite; echo '<rss/>' > "$site/feed/index.xml"; }
small; CHECK_SITE_MAX_FILE_BYTES=54 tc fails "to come: 55 bytes, over a limit of 54 for one file" "offprint.json is 55 bytes, the limit for one file is 54"
small; warns "to come: 55 bytes, at a limit of 55 for one file: passes, warning" CHECK_SITE_MAX_FILE_BYTES 55 "warning: offprint.json is 55 bytes, over 80% of the 55 limit for one file"
small; warns "to come: 55 bytes, 80% of a limit of 68 for one file: the warning" CHECK_SITE_MAX_FILE_BYTES 68 "warning: offprint.json is 55 bytes, over 80% of the 68 limit for one file"
small; warns "to come: 55 bytes, under 80% of a limit of 69 for one file: no warning" CHECK_SITE_MAX_FILE_BYTES 69 ""
small; printf '%060d' 0 > "$site/aa.txt"; printf '%060d' 0 > "$site/zz.txt"; CHECK_SITE_MAX_FILE_BYTES=54 tc run
check_lines="$(printf 'aa.txt is 60 bytes, the limit for one file is 54\noffprint.json is 55 bytes, the limit for one file is 54\nzz.txt is 60 bytes, the limit for one file is 54')"
if [ "$code" -eq 1 ] && [ "$out" = "$check_lines" ]; then ok "to come: named among the files over the limit, in name order"; else bad "to come, in name order (exit $code, out '$out')"; fi
# The total: the site's archive measured with a stand-in of the file to come in it. That measure and the one the folder
# makes once the file is written can't agree to the byte: gzip's size turns on the very bytes, on where they fall in the
# archive and on files' times, tens of bytes either way (up to about 100). So no case here rests on it: they compare
# measures a whole file apart, keep their limits 512 bytes clear, or allow 256 bytes. The site's archive is far from
# the edge of a 10240-byte record (a random file of 6000 characters: about 4800 bytes compressed), so where tar writes
# those records (the Mac's), every measure here is the same one record; elsewhere a file adds 60 bytes or more.
# measure [VAR=VALUE...]: bin/check-site's measure of the total of $site, with those settings (it says it, over a limit
# of 1 byte); id_written: a written offprint.json in $site; with_id: the settings that let it by. more A B: A is more
# than B, or both are the same whole number of 10240-byte records (tar writes those).
measure() { env CHECK_SITE_MAX_BYTES=1 "$@" "$root/bin/check-site" "$site" 2>/dev/null | sed -n 's/^too big: \([0-9]*\) bytes.*/\1/p'; }
id_written() { printf '{"publish":"%s"}\n' 0123456789abcdef0123456789abcdef01234567 > "$site/offprint.json"; }
more() { [ -n "$1" ] && [ -n "$2" ] && { [ "$1" -gt "$2" ] || { [ "$1" = "$2" ] && [ $(( $2 % 10240 )) = 0 ]; }; }; }
to_come="CHECK_SITE_RESERVED=offprint.json CHECK_SITE_TO_COME=offprint.json CHECK_SITE_TO_COME_BYTES=55"
with_id="CHECK_SITE_RESERVED=offprint.json CHECK_SITE_ALLOWED=offprint.json"
newsite; head -c 6000 /dev/urandom | base64 | tr -d '\n' | head -c 6000 > "$site/r.txt"
s0="$(measure)"; s1="$(measure $to_come)"; id_written; sf="$(measure $with_id)"; rm "$site/offprint.json"
CHECK_SITE_MAX_BYTES=$((s0 + 512)) run
if [ "$code" -eq 0 ] && [ -z "$out" ]; then ok "control: without the file to come, the site passes well under a total 512 over its measure"
else bad "the site, 512 over its measure $s0 (exit $code, out '$out')"; fi
if more "$s1" "$s0"; then ok "to come: it counts toward the total: the site measures more with it than without"
else bad "to come, the total (without '$s0', with '$s1')"; fi
if more "$sf" "$s0"; then ok "and so does the file, written"; else bad "the file written, the total (without '$s0', written '$sf')"; fi
d=$((s1 - sf)); [ "$d" -ge 0 ] || d=$((0 - d))
if [ -n "$s1" ] && [ -n "$sf" ] && [ "$d" -le 256 ]; then ok "to come: its measure is the written file's within 256 bytes"
else bad "to come, how close (with '$s1', written '$sf')"; fi
CHECK_SITE_MAX_BYTES=$((s0 - 512)) tc fails "to come: refused well over a total 512 under the site's measure without it" "too big: "
CHECK_SITE_MAX_BYTES=$((sf + 512)) tc run
if [ "$code" -eq 0 ] && [ -z "$out" ]; then ok "to come: passes well under a total 512 over the measure with the file written"
else bad "to come, 512 over the written measure (exit $code, out '$out')"; fi
# Nothing is counted twice: a file by that name already there is refused (it is reserved, and not allowed).
newsite; echo '{}' > "$site/offprint.json"; tc fails "to come, and a file by that name already there" "the publish writes offprint.json at the root, so the export can't have one: ./offprint.json"
# What CHECK_SITE_TO_COME may be: one plain file name, one of CHECK_SITE_RESERVED's and none of CHECK_SITE_ALLOWED's.
for value in 'a b' '*' '../x' 'x/y' '..' '$(touch pwned)'; do
  newsite; out="$(cd "$tmp" && CHECK_SITE_RESERVED="a b x" CHECK_SITE_TO_COME="$value" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
  refused "CHECK_SITE_TO_COME='$value' is not one file name" "CHECK_SITE_TO_COME"
done
newsite; out="$(CHECK_SITE_RESERVED=_headers CHECK_SITE_TO_COME=offprint.json "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
refused "CHECK_SITE_TO_COME not one of the reserved names" "CHECK_SITE_TO_COME"
newsite; out="$(CHECK_SITE_RESERVED=offprint.json CHECK_SITE_ALLOWED=offprint.json CHECK_SITE_TO_COME=offprint.json "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
refused "CHECK_SITE_TO_COME one of the allowed names" "CHECK_SITE_TO_COME"
for value in abc -1 08 '1 2' '$(touch pwned)' 1048577; do
  newsite; out="$(cd "$tmp" && CHECK_SITE_RESERVED=offprint.json CHECK_SITE_TO_COME=offprint.json CHECK_SITE_TO_COME_BYTES="$value" "$root/bin/check-site" "$site" 2>"$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
  refused "CHECK_SITE_TO_COME_BYTES='$value' is not a whole number of at most 1048576" "CHECK_SITE_TO_COME_BYTES"
done
if [ -n "$(find "$tmp" -name pwned)" ] || [ -e "$root/pwned" ]; then bad "a name to come ran a command"; else ok "no name to come or its size ran a command"; fi
newsite; mkdir "$tmp/tcdir"; TMPDIR="$tmp/tcdir" CHECK_SITE_MAX_BYTES=100000 tc run
check_left="$(ls -A "$tmp/tcdir")"
if [ "$code" -eq 0 ] && [ -z "$check_left" ]; then ok "to come: the stand-in measured in the archive is removed (nothing left in TMPDIR)"; else bad "to come, TMPDIR (exit $code, left '$check_left')"; fi

# --- comment forms (a site's pigeonhole): what a page carries is site.json's, and the scripts are the tool's -------------
# WordPress prints a page's block (where a comment is posted, and to whose keys it is encrypted) from values it took
# when its container was made; the two scripts are served from the plugin copy it can write. bin/publish passes
# site.json's own path and keys (CHECK_SITE_PIGEONHOLE_PATH, CHECK_SITE_PIGEONHOLE_RECIPIENTS), and the export is
# compared with them, and with the tool's own scripts.
PHQ="age1$(printf 'q%.0s' $(seq 1 58))"; PHP2="age1$(printf 'p%.0s' $(seq 1 58))"
ph_block() { printf '<script type="application/json" id="offprint-pigeonhole">{"path":"%s","recipients":[%s],"bits":%s}</script>' "${1:-/_pigeonhole}" "${2:-\"$PHQ\",\"$PHP2\"}" "${3:-18}"; }
# the comment form as the plugin prints it: marked, unable to post by itself (method "dialog"), its hidden field in it
ph_form='<form action="/_pigeonhole" method="dialog" data-offprint-pigeonhole="1"><textarea name="comment"></textarea><input type="text" name="offprint_hp" value=""></form>'
# ph_site [BODY]: a site with a post whose page holds BODY (a good block and the form, unless given), and both scripts
ph_site() {
  newsite; mkdir -p "$site/hello" "$site/wp-content/mu-plugins/offprint"
  printf '<html><body><p>A post</p>%s</body></html>\n' "${1-$ph_form$(ph_block)}" > "$site/hello/index.html"
  cp "$root/plugin/offprint/pigeonhole.js" "$root/plugin/offprint/pigeonhole-loader.js" "$site/wp-content/mu-plugins/offprint/"
}
ph_on() { export CHECK_SITE_PIGEONHOLE_PATH=/_pigeonhole CHECK_SITE_PIGEONHOLE_RECIPIENTS="$PHQ $PHP2"; }
ph_off() { unset CHECK_SITE_PIGEONHOLE_PATH CHECK_SITE_PIGEONHOLE_RECIPIENTS; }
remake='WordPress takes these when its container is made: run offprint compose up -d, then publish again.'

ph_on
ph_site; passes "pigeonhole: a page with the form, site.json's block and the tool's two scripts"
ph_site ""; passes "pigeonhole: a site with one, and a page with no form and no block"
ph_site "$(ph_block)"; passes "pigeonhole: a block and no form (a theme with no comment form): nothing to send, nothing wrong"
ph_site "$ph_form$(ph_block /_pigeonhole "\"$PHQ\"")"; fails "pigeonhole: a block with one of site.json's two keys" "hello/index.html: its comment form's settings (the offprint-pigeonhole block) are not right: its keys are not site.json's. $remake"
ph_site "$ph_form$(ph_block /_pigeonhole "\"$PHP2\",\"$PHQ\"")"; fails "pigeonhole: the two keys the other way round" "its keys are not site.json's"
ph_site "$ph_form$(ph_block /_pigeonhole "\"$PHQ\",\"age1$(printf 'z%.0s' $(seq 1 58))\"")"; fails "pigeonhole: a key that is not site.json's" "its keys are not site.json's"
ph_site "$ph_form$(ph_block /_pigeonhole "\"$PHQ\",\"$PHP2\",\"age1$(printf 'z%.0s' $(seq 1 58))\"")"; fails "pigeonhole: a third key" "its keys are not site.json's"
ph_site "$ph_form<script type=\"application/json\" id=\"offprint-pigeonhole\">{\"path\":\"/_pigeonhole\",\"recipients\":{\"0\":\"$PHQ\",\"1\":\"$PHP2\"},\"bits\":18}</script>"
fails "pigeonhole: the keys as an object, not a list" "its keys are not site.json's"
ph_site "$ph_form$(ph_block /elsewhere)"; fails "pigeonhole: a block with another path" "its path is not site.json's. $remake"
ph_site "$ph_form$(ph_block /_pigeonhole "\"$PHQ\",\"$PHP2\"" 1)"; fails "pigeonhole: a block asking for less proof of work" "its proof of work is not this Offprint's"
ph_site "$ph_form$(ph_block /_pigeonhole "\"$PHQ\",\"$PHP2\"" '"18"')"; fails "pigeonhole: the proof of work as text" "its proof of work is not this Offprint's"
ph_site "$ph_form<script type=\"application/json\" id=\"offprint-pigeonhole\">{\"path\":\"/_pigeonhole\",\"recipients\":[\"$PHQ\",\"$PHP2\"],\"bits\":18,\"extra\":1}</script>"
fails "pigeonhole: a block with a fourth key" "it does not hold exactly a path, the recipients and the proof of work"
ph_site "$ph_form<script type=\"application/json\" id=\"offprint-pigeonhole\">{\"path\":\"/elsewhere\",\"path\":\"/_pigeonhole\",\"recipients\":[\"$PHQ\",\"$PHP2\"],\"bits\":18}</script>"
fails "pigeonhole: a block that names its path twice" "it does not hold exactly a path, the recipients and the proof of work"
ph_site "$ph_form<script type=\"application/json\" id=\"offprint-pigeonhole\">{\"recipients\":[\"$PHQ\",\"$PHP2\"],\"path\":\"/_pigeonhole\",\"bits\":18}</script>"
fails "pigeonhole: a block with its keys in another order" "it does not hold exactly a path, the recipients and the proof of work"
ph_site "$ph_form<script type=\"application/json\" id=\"offprint-pigeonhole\">not json</script>"; fails "pigeonhole: a block that is not JSON" "it is not JSON"
ph_site "$ph_form<script type=\"application/json\" id=\"offprint-pigeonhole\">[1]</script>"; fails "pigeonhole: a block that is a list" "it is not a JSON object"
ph_site "$ph_form<script id=\"offprint-pigeonhole\">{}</script>"; fails "pigeonhole: a block that is a script a browser runs" "it is not a JSON script element"
ph_site "$ph_form<div id=\"offprint-pigeonhole\">x</div>"; fails "pigeonhole: something else with the block's id" "it is not a JSON script element"
ph_site "$ph_form$(ph_block)$(ph_block)"; fails "pigeonhole: the block twice" "hello/index.html: carries a comment form's settings (the offprint-pigeonhole block) more than once; a page has one."
ph_site "$ph_form$(ph_block)$(ph_block /elsewhere)"; fails "pigeonhole: a right block and a wrong one" "more than once"
ph_site "$ph_form<script type=\"application/json\" id=\"offprint&#45;pigeonhole\">{\"path\":\"/elsewhere\",\"recipients\":[\"$PHQ\",\"$PHP2\"],\"bits\":18}</script>"
fails "pigeonhole: a wrong block whose id is written with an entity" "its path is not site.json's"
ph_site "$ph_form<SCRIPT TYPE=\"Application/JSON\" ID=\"offprint-pigeonhole\">{\"path\":\"/_pigeonhole\",\"recipients\":[\"$PHQ\",\"$PHP2\"],\"bits\":18}</SCRIPT>"
passes "pigeonhole: the block's tag and type in capitals"
# The form itself: only as the plugin prints it (it can't post by itself), once, on a page with the block.
ph_site "$ph_form"; fails "pigeonhole: the form and no block" "hello/index.html: has a pigeonhole's comment form, but not the block that says whose keys a comment is encrypted to; a comment sent from it would go nowhere."
not_as_printed="hello/index.html: its comment form is not as this Offprint prints it:"
ph_site "<form action=\"/_pigeonhole\" method=\"post\" data-offprint-pigeonhole=\"1\"><input name=\"offprint_hp\"></form>$(ph_block)"
fails "pigeonhole: the form as WordPress writes it, able to post" "$not_as_printed it could post what a visitor typed, readable, should the script not run (its method is not \"dialog\")."
ph_site "<form action=\"/_pigeonhole\" data-offprint-pigeonhole=\"1\"><input name=\"offprint_hp\"></form>$(ph_block)"
fails "pigeonhole: the form with no method at all (a browser would get the path)" "its method is not \"dialog\""
ph_site "<form action=\"/_pigeonhole\" method=\"dialog\"><input name=\"offprint_hp\"></form>$(ph_block)"
fails "pigeonhole: the form with its hidden field and no mark" "$not_as_printed it is not marked as one."
ph_site "<form action=\"/_pigeonhole?x=1\" method=\"dialog\" data-offprint-pigeonhole=\"1\"></form>$(ph_block)"
fails "pigeonhole: the form with something after the path in its address" "$not_as_printed its address is not the pigeonhole's path."
ph_site "<form action=\"/elsewhere\" method=\"dialog\" data-offprint-pigeonhole=\"1\"></form>$(ph_block)"
fails "pigeonhole: the form with another address" "its address is not the pigeonhole's path"
ph_site "<form action=\"/_pigeonhole\" method=\"dialog\" data-offprint-pigeonhole=\"1\"><button formmethod=\"post\">Send</button></form>$(ph_block)"
fails "pigeonhole: the form with a button that posts it" "$not_as_printed a button in it sends it another way."
ph_site "<form action=\"/_pigeonhole\" method=\"dialog\" data-offprint-pigeonhole=\"1\"><button formaction=\"https://other.example.com/\">Send</button></form>$(ph_block)"
fails "pigeonhole: the form with a button that sends it elsewhere" "a button in it sends it another way"
ph_site "$ph_form$ph_form$(ph_block)"; fails "pigeonhole: the form twice" "hello/index.html: has a pigeonhole's comment form more than once; a page has one."
ph_site "<div data-offprint-pigeonhole=\"1\"></div>$(ph_block)"; fails "pigeonhole: the mark on something that is no form" "its mark or its hidden field is not in a form"
ph_site "<input name=\"offprint_hp\">$(ph_block)"; fails "pigeonhole: the hidden field outside any form" "its mark or its hidden field is not in a form"
ph_site "<FORM ACTION=\"/_pigeonhole\" METHOD=\" Dialog \" DATA-OFFPRINT-PIGEONHOLE=\"1\"><INPUT NAME=\"offprint_hp\"></FORM>$(ph_block)"
passes "pigeonhole: the form's tag and method in capitals"
# Nothing else sends to the path, however its address is written: it would post what a visitor typed, readable.
sends="hello/index.html: has a form or a button that sends to /_pigeonhole, the pigeonhole's path, and is not the comment form this Offprint prints; it would post what a visitor typed, readable."
ph_site '<form action="/_pigeonhole" method="post"></form>'; fails "pigeonhole: a form that posts to the path, and nothing else on the page" "$sends"
ph_site "$ph_form<form action=\"/_pigeonhole\" method=\"post\"></form>$(ph_block)"; fails "pigeonhole: a second form that posts to the path, beside the right one" "$sends"
ph_site "<p><form action=\"/_pigeonhole\" method=\"post\"><textarea name=\"comment\"></textarea></form></p>$ph_form$(ph_block)"; fails "pigeonhole: a form that posts to the path, before the right one" "$sends"
ph_site '<form action="/_pigeonhole"></form>'; fails "pigeonhole: a form that gets the path" "$sends"
ph_site '<form><button formmethod="post" formaction="/_pigeonhole">x</button></form>'; fails "pigeonhole: a button that posts its form to the path" "$sends"
ph_site '<form><input type="image" formaction="/_pigeonhole"></form>'; fails "pigeonhole: an image button that sends its form to the path" "$sends"
for a in 'https://www.example.com/_pigeonhole' '//WWW.EXAMPLE.COM/_pigeonhole?x=1#y' '/%5Fpigeonhole/' '../_pigeonhole' './../_pigeonhole' '/a/../_pigeonhole' '/a/b/../../_pigeonhole/' 'https:/_pigeonhole' 'https:../_pigeonhole' '/_PIGEONHOLE' '/_pigeonhole;x' '/_pigeonhole/;x=1?y' '\_pigeonhole' 'https://www.example.com:443/_pigeonhole' 'https://user@www.example.com./_pigeonhole' ' /_pige	onhole '; do
  ph_site "<form action=\"$a\" method=\"post\"></form>"; fails "pigeonhole: a form posting to the path written as $a" "$sends"
done
ph_site '<base href="/"><form action="_pigeonhole" method="post"></form>'; fails "pigeonhole: a form posting to the path through the page's <base>" "$sends"
ph_site '<base href="https://www.example.com/x/y"><form action="../_pigeonhole" method="post"></form>'; fails "pigeonhole: ... a <base> with a path of its own" "$sends"
newsite; mkdir -p "$site/wp-content/mu-plugins/offprint"; echo '<html><body><form action="_pigeonhole" method="post"></form></body></html>' > "$site/index.html"
fails "pigeonhole: a form on the home page posting to the path by its name alone" "index.html: has a form or a button that sends to /_pigeonhole"
for a in '/_pigeonhole-not' '/a/_pigeonhole' '_pigeonhole' '/_pigeonhol' 'https://other.example.com/_pigeonhole' 'mailto:_pigeonhole' '#_pigeonhole' '?_pigeonhole' ''; do
  ph_site "<form action=\"$a\" method=\"post\"></form>"; passes "pigeonhole: a form posting somewhere else ($a)"
done
ph_site '<base href="https://other.example.com/"><form action="/_pigeonhole" method="post"></form>'; passes "pigeonhole: a form posting to that path on another site, through <base>"
# A page that is not a .html file: read all the same.
ph_site ""; printf '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body>%s%s</body></html>' "$ph_form" "$(ph_block /elsewhere)" > "$site/hello/c.xml"
fails "pigeonhole: a wrong block in a page that is an .xml file" "hello/c.xml: its comment form's settings (the offprint-pigeonhole block) are not right: its path is not site.json's"
ph_site ""; printf '<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><form xmlns="http://www.w3.org/1999/xhtml" action="/_pigeonhole" method="post"></form></foreignObject></svg>' > "$site/hello/c.svg"
fails "pigeonhole: a form posting to the path inside an .svg file" "hello/c.svg: has a form or a button that sends to /_pigeonhole"
# the two scripts
ph_site; echo '// more' >> "$site/wp-content/mu-plugins/offprint/pigeonhole.js"
fails "pigeonhole: the script that sends a comment, changed" "wp-content/mu-plugins/offprint/pigeonhole.js: is not this Offprint's own script (plugin/offprint/pigeonhole.js), byte for byte"
ph_site; echo 'fetch("https://other.example.com/")' > "$site/wp-content/mu-plugins/offprint/pigeonhole-loader.js"
fails "pigeonhole: the loader, replaced" "wp-content/mu-plugins/offprint/pigeonhole-loader.js: is not this Offprint's own script"
ph_site; sz=$(wc -c < "$root/plugin/offprint/pigeonhole-loader.js" | tr -d ' '); head -c "$sz" /dev/zero | tr '\0' 'x' > "$site/wp-content/mu-plugins/offprint/pigeonhole-loader.js"
fails "pigeonhole: the loader, other bytes of the same length" "pigeonhole-loader.js: is not this Offprint's own script"
ph_site; rm "$site/wp-content/mu-plugins/offprint/pigeonhole.js"
fails "pigeonhole: a page with the block, and no script that sends" "hello/index.html: carries a comment form's settings, but the export has no wp-content/mu-plugins/offprint/pigeonhole.js, the script that sends a comment."
ph_site; rm "$site/wp-content/mu-plugins/offprint/pigeonhole-loader.js"
fails "pigeonhole: a page with the block, and no loader" "but the export has no wp-content/mu-plugins/offprint/pigeonhole-loader.js"
ph_site ""; rm -r "$site/wp-content"; passes "pigeonhole: no page with the block, and no scripts: nothing loads them"
ph_site; rm "$site/wp-content/mu-plugins/offprint/pigeonhole.js"; mkdir "$site/wp-content/mu-plugins/offprint/pigeonhole.js"
fails "pigeonhole: a folder where the script should be" "pigeonhole.js: is not this Offprint's own script"
# a site with no pigeonhole
ph_off
ph_site; fails "no pigeonhole in site.json: a page with a block" "hello/index.html: carries a comment form's settings (the offprint-pigeonhole block), but site.json has no \"pigeonhole\" block. $remake"
ph_site '<form action="/_pigeonhole" method="post"></form>'; passes "no pigeonhole in site.json: a form posting to some path is only a form (the exporter warns of it)"
ph_site "$ph_form"; fails "no pigeonhole in site.json: a page with a pigeonhole's comment form" "hello/index.html: has a pigeonhole's comment form, but site.json has no \"pigeonhole\" block. $remake"
ph_site '<form method="post" action="/x"><input name="offprint_hp"></form>'; fails "no pigeonhole in site.json: a form with the hidden field (a container made when there was one)" "has a pigeonhole's comment form, but site.json has no"
ph_site ""; echo '// more' >> "$site/wp-content/mu-plugins/offprint/pigeonhole.js"
fails "no pigeonhole in site.json: the script, changed, is still refused" "pigeonhole.js: is not this Offprint's own script"
# its settings come whole, or the check reads nothing
bad_ph() {  # description; the two variables are set
  ph_site; run
  if [ "$code" -eq 2 ] && [ -z "$out" ] && printf '%s' "$err" | grep -qF "CHECK_SITE_PIGEONHOLE_PATH and CHECK_SITE_PIGEONHOLE_RECIPIENTS must be site.json's pigeonhole path and its one or two age public keys (or both empty)"; then ok "exit 2: $1"; else bad "exit 2: $1 (exit $code, out: $out, err: $err)"; fi
}
export CHECK_SITE_PIGEONHOLE_PATH=/_pigeonhole CHECK_SITE_PIGEONHOLE_RECIPIENTS=""; bad_ph "pigeonhole: a path and no keys"
export CHECK_SITE_PIGEONHOLE_PATH="" CHECK_SITE_PIGEONHOLE_RECIPIENTS="$PHQ"; bad_ph "pigeonhole: keys and no path"
export CHECK_SITE_PIGEONHOLE_PATH="/a/b" CHECK_SITE_PIGEONHOLE_RECIPIENTS="$PHQ"; bad_ph "pigeonhole: a path of two names"
export CHECK_SITE_PIGEONHOLE_PATH='/a$(id)' CHECK_SITE_PIGEONHOLE_RECIPIENTS="$PHQ"; bad_ph "pigeonhole: a path with a command in it"
export CHECK_SITE_PIGEONHOLE_PATH=/_pigeonhole CHECK_SITE_PIGEONHOLE_RECIPIENTS="$PHQ $PHP2 $PHQ"; bad_ph "pigeonhole: three keys"
export CHECK_SITE_PIGEONHOLE_PATH=/_pigeonhole CHECK_SITE_PIGEONHOLE_RECIPIENTS="AGE-SECRET-KEY-1$(printf 'Q%.0s' $(seq 1 58))"; bad_ph "pigeonhole: a private key"
if ! printf '%s' "$err$out" | grep -q 'AGE-SECRET-KEY'; then ok "pigeonhole: a private key given as a recipient is not repeated"; else bad "pigeonhole: a private key was echoed"; fi
ph_off
unset -f bad_ph
# --- the PATH clean-up (lib/site.sh, sourced first): look-alikes WordPress could put in wp-content/ never run ---
# bin/check-site run by itself, from inside a site folder's wp-content/, which holds look-alikes of bash, dirname, php,
# mktemp, git, docker, curl, readlink and env (each noting that it ran), with the PATH reaching there through . first,
# an empty entry first, relative entries, its absolute path, and a link outside the site folder; both as /bin/bash
# SCRIPT and by its own #! line. None runs, the entries left out are named in one line on stderr, and the check passes.
pc="$tmp/pathcase/site"; mkdir -p "$pc/wp-content"; cp "$root/tests/fixtures/site.json" "$pc/"
for p in bash dirname php mktemp git docker curl readlink env; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/planted.ran"\nexit 0\n' "$p" "$tmp" > "$pc/wp-content/$p"; chmod +x "$pc/wp-content/$p"
done
ln -s "$pc/wp-content" "$tmp/pathcase/wplink"
newsite
for spec in ".:|'.'|. first" ":|''|an empty entry first" "wp-content:../wp-content:|'wp-content' '../wp-content'|relative entries" \
  "$pc/wp-content:|'$pc/wp-content'|its absolute path" "$tmp/pathcase/wplink:|'$tmp/pathcase/wplink'|a link to it"; do
  pre="${spec%%|*}"; rest="${spec#*|}"; named="${rest%%|*}"; how="${rest#*|}"
  for by in bash direct; do
    rm -f "$tmp/planted.ran"
    if [ "$by" = bash ]; then set -- /bin/bash "$root/bin/check-site"; else set -- "$root/bin/check-site"; fi
    out="$(cd "$pc/wp-content" && env -u OFFPRINT_SITE PATH="$pre$PATH" "$@" "$site" 2> "$tmp/err")"; code=$?; err="$(cat "$tmp/err")"
    t="the PATH clean-up: bin/check-site ($by), run from wp-content/ holding look-alikes, the PATH through $how"
    if [ ! -e "$tmp/planted.ran" ]; then ok "$t: none of them ran"; else bad "$t: none of them ran ($(cat "$tmp/planted.ran"))"; fi
    if [ "$(printf '%s\n' "$err" | grep -c .)" = 1 ] && printf '%s' "$err" | grep -q 'PATH entries left out' && printf '%s' "$err" | grep -qF -- "$named"; then
      ok "$t: one line names what was left out of the PATH"
    else bad "$t: one line names what was left out of the PATH ($err)"; fi
    if [ "$code" -eq 0 ] && [ -z "$out" ]; then ok "$t: the check passes"; else bad "$t: the check passes (exit $code, output: $out)"; fi
  done
done
set --

exit "$fail"
