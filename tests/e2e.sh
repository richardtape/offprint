#!/usr/bin/env bash
# End-to-end checks against a throwaway WordPress (compose project "offprint-e2e", made by tests/e2e-setup.sh): its own
# database, a temporary wp-content holding only this repo's plugin/ as a site's mu-plugins, no ports, no Caddy.
# It never touches a real site, and always removes everything it made, pass or fail. tests/compat-seo.sh uses the same
# project, so never run the two at the same time (each refuses to start while the project exists).
#   bash tests/e2e.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# The fixture's names, the throwaway project, its folders in $WORK, and dc, wp, check and the export helpers.
. tests/e2e-setup.sh
# Nothing here may write into this repo. The folders a site's mounts would make (var/, wp-content/, local/), as they
# are before the run, at the repo's root, beside the fixture's site.json, and beside templates/compose.yaml (where
# compose would resolve a relative mount without --project-directory). The throwaway's own are all in $WORK.
repo_writes() { local d; for d in . tests/fixtures templates; do ls -d "$d/var" "$d/wp-content" "$d/local" 2>/dev/null; done; }
REPO_WRITES_BEFORE=$(repo_writes)

# fetch_with SECRET PATH [CURL ARGS...]: what the exporter would see; no header when SECRET is empty.
fetch_with() {
  local secret=$1 path=$2
  shift 2
  if [ -n "$secret" ]; then
    dc exec -T wordpress curl -s -H "Host: $LOCAL" -H 'X-Forwarded-Proto: https' \
      -H "X-Offprint-Export: $secret" "$@" "http://127.0.0.1$path"
  else
    dc exec -T wordpress curl -s -H "Host: $LOCAL" -H 'X-Forwarded-Proto: https' "$@" "http://127.0.0.1$path"
  fi
}
fetch() { fetch_with "$SECRET" "$@"; }
status_of() { fetch_with "$1" "$2" --max-time 5 -o /dev/null -w '%{http_code}'; }

# The cron lock, read straight from the database: WP-CLI itself runs cron and would take the lock.
cron_lock_sql() { wp db query "$1 FROM wp_options WHERE option_name IN ('doing_cron','_transient_doing_cron','_transient_timeout_doing_cron')" ${2:-}; }
cron_lock() { cron_lock_sql "SELECT option_name" --skip-column-names; }
cron_lock_clear() { wp db query "DELETE FROM wp_options WHERE option_name IN ('doing_cron','_transient_doing_cron','_transient_timeout_doing_cron')"; }

autoload_off() { case $1 in off | no) return 0 ;; esac; return 1; }

# --- set up -------------------------------------------------------------------------------------
e2e_start

# Compose made both volumes with the label templates/compose.yaml gives each (lib/site.sh's dc refuses a project of a
# site's name whose volumes lack it).
E2E_VOLUMES=$(docker volume ls --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Name}} {{.Label "offprint"}}' | sort | paste -sd' ' -)
check "both volumes of the throwaway project are labelled offprint=1" equals "$E2E_VOLUMES" "$PROJECT"'_db 1 '"$PROJECT"'_wordpress 1'

e2e_install

# Two tiny PNGs, inside the container.
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
for name in in-post draft-only; do
  dc exec -T wordpress sh -c "echo '$PNG' | base64 -d > /tmp/$name.png"
done

IN_POST_ID=$(wp media import /tmp/in-post.png --porcelain)
IN_POST_URL=$(wp post get "$IN_POST_ID" --field=guid)
HELLO_ID=$(wp post create --post_title='Hello static' --post_status=publish --post_author=1 --porcelain \
  --post_content="<!-- wp:image --><figure class=\"wp-block-image\"><img src=\"$IN_POST_URL\" alt=\"\"/></figure><!-- /wp:image -->")
DRAFT_ID=$(wp post create --post_title='Secret draft' --post_status=draft --porcelain)
wp media import /tmp/draft-only.png --post_id="$DRAFT_ID" >/dev/null

PRIVATE_ID=$(wp post create --post_title='Private post' --post_status=private --porcelain)

# A test-only mu-plugin, in the throwaway wp-content only. Its name sorts after
# offprint.php, so export mode is already on when it runs.
#   /e2e-link-header sends a raw Link header.
#   /e2e-flush flushes part of its body early, so the rest is written after the headers went.
#   /e2e-offsite redirects to another site.
#   /e2e-length sets a Content-Length for its unrewritten body, then sends part of it early.
#   /e2e-gzip sends a compressed body.
#   /e2e-touch-post?id=N changes post N, as any request might.
# It also notes each publish request WordPress writes in /tmp/e2e-requests (in the container), so a
# test can count them. @LOCAL@ is the local host.
sed "s/@LOCAL@/$LOCAL/g" >"$E2E_WP_CONTENT/mu-plugins/zz-e2e-routes.php" <<'PHP'
<?php
add_action( 'offprint_requested', function ( $reason ) {
	file_put_contents( '/tmp/e2e-requests', $reason . "\n", FILE_APPEND );
} );
if ( isset( $_SERVER['REQUEST_URI'] ) && 0 === strpos( $_SERVER['REQUEST_URI'], '/e2e-touch-post' ) ) {
	add_action( 'wp_loaded', function () {
		wp_update_post( array( 'ID' => (int) $_GET['id'], 'post_excerpt' => 'touched ' . microtime( true ) ) );
		echo 'touched';
		exit;
	} );
}
if ( isset( $_SERVER['REQUEST_URI'] ) && 0 === strpos( $_SERVER['REQUEST_URI'], '/e2e-offsite' ) ) {
	header( 'Location: https://example.com/', true, 302 );
	exit;
}
if ( isset( $_SERVER['REQUEST_URI'] ) && 0 === strpos( $_SERVER['REQUEST_URI'], '/e2e-length' ) ) {
	header( 'Content-Length: ' . strlen( 'first https://@LOCAL@/b' ) );
	echo 'first ';
	ob_flush();
	flush(); // Out to the network, so the web server can't recount the length at the end.
	echo 'https://@LOCAL@/b';
	exit;
}
if ( isset( $_SERVER['REQUEST_URI'] ) && 0 === strpos( $_SERVER['REQUEST_URI'], '/e2e-gzip' ) ) {
	header( 'Content-Type: text/html' );
	header( 'Content-Encoding: gzip' );
	echo gzencode( '<p>compressed</p>' );
	exit;
}
if ( isset( $_SERVER['REQUEST_URI'] ) && 0 === strpos( $_SERVER['REQUEST_URI'], '/e2e-link-header' ) ) {
	header( 'Link: <https://@LOCAL@/x>; rel="x"', false );
	echo 'ok';
	exit;
}
if ( isset( $_SERVER['REQUEST_URI'] ) && 0 === strpos( $_SERVER['REQUEST_URI'], '/e2e-flush' ) ) {
	echo 'first https://@LOCAL@/a ';
	ob_flush();
	echo 'second ' . ( headers_sent() ? 'headers-sent' : 'headers-not-sent' ) . ' https://@LOCAL@/b';
	exit;
}
PHP

# The secret is made on first use.
SECRET=$(wp eval 'echo Offprint\Export_Mode::secret();')

# A real logged-in cookie for user 1.
COOKIE_NAME=$(wp eval 'echo LOGGED_IN_COOKIE;')
COOKIE_VALUE=$(wp eval 'echo wp_generate_auth_cookie(1, time()+3600, "logged_in");')
COOKIE="Cookie: $COOKIE_NAME=$COOKIE_VALUE"

# A cron event that is due now, so a request that runs cron would take the lock.
# (No container healthcheck runs here, and no WP-CLI call may sit between clearing the lock
# and the fetches, so only the fetches can take the lock.)
ready() {
  local waited=0
  until [ "$(status_of "" /)" = 200 ]; do
    [ "$waited" -ge 120 ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
}
ready || { echo "WordPress did not answer / with 200 within 120 seconds"; exit 1; }
wp cron event schedule e2e_due_event now >/dev/null
cron_lock_clear

# --- checks -------------------------------------------------------------------------------------
HOME_PAGE=$(fetch /)
POST_PAGE=$(fetch /hello-static/)
FEED=$(fetch /feed/)
ROBOTS=$(fetch /robots.txt)
POST_HEADERS=$(fetch /hello-static/ -D - -o /dev/null)

check "the secret is 40 characters"                  equals "${#SECRET}" 40
check "the secret is not autoloaded" \
  autoload_off "$(wp db query "SELECT autoload FROM wp_options WHERE option_name='offprint_secret'" --skip-column-names)"
check "the secret is not in the page"                lacks "$HOME_PAGE$POST_PAGE$FEED" "$SECRET"

check "/ is 200, not a redirect"                     equals "$(status_of "$SECRET" /)" 200
check "/ links to the public post address"           contains "$HOME_PAGE" "$PUBLIC/hello-static/"
check "/ never says $LOCAL"                        lacks "$HOME_PAGE" "$LOCAL"
check "post uses the public uploads address"         contains "$POST_PAGE" "$PUBLIC/wp-content/uploads/"
check "post never says $LOCAL"                     lacks "$POST_PAGE" "$LOCAL"
for needle in 'wp-json' 'xmlrpc' 'rel="shortlink"' 'wp-emoji' 'comment-reply' 'comments/feed' 'name="generator"' 'wlwmanifest' 'speculationrules'; do
  check "post page has no $needle"                   lacks "$POST_PAGE" "$needle"
done
check "post head keeps the main feed link"           contains "$POST_PAGE" "$PUBLIC/feed/"
check "no X-Pingback header"                         lacks "$POST_HEADERS" "X-Pingback"
check "no REST Link header"                          lacks "$POST_HEADERS" "api.w.org"
check "the draft's image is not on the front page"   lacks "$HOME_PAGE" "draft-only"
check "feed has the public link"                     contains "$FEED" "<link>$PUBLIC/</link>"
check "feed never says $LOCAL"                     lacks "$FEED" "$LOCAL"
check "robots.txt is exactly the export one" \
  equals "$ROBOTS" "$(printf 'User-agent: *\nAllow: /\n\nSitemap: %s/wp-sitemap.xml' "$PUBLIC")"
check "a redirect points at the public address" \
  contains "$(fetch /hello-static -D - -o /dev/null)" "Location: $PUBLIC/hello-static/"
check "the draft is a 404"                           equals "$(status_of "$SECRET" /secret-draft/)" 404

# Cron must not have run in export mode (it would call the public host and take the shared lock).
check "export fetches left no cron lock" test -z "$(cron_lock)"

# Forced logout: a real cookie must not show drafts, private posts or the admin bar.
check "control: cookie shows the draft in normal mode" \
  contains "$(fetch_with "" "/?p=$DRAFT_ID" -H "$COOKIE")" "Secret draft"
check "control: cookie shows the admin bar in normal mode" \
  contains "$(fetch_with "" / -H "$COOKIE")" "wpadminbar"
for path in "/?p=$DRAFT_ID" "/?p=$DRAFT_ID&preview=true" "/?p=$PRIVATE_ID"; do
  page=$(fetch "$path" -H "$COOKIE")
  check "export with a cookie: $path is 404" equals "$(fetch "$path" -H "$COOKIE" -o /dev/null -w '%{http_code}')" 404
  check "export with a cookie: $path hides the title" lacks "$page" "Secret draft"
  check "export with a cookie: $path hides the private title" lacks "$page" "Private post"
done
check "export with a cookie: no admin bar" lacks "$(fetch / -H "$COOKIE")" "wpadminbar"

# The Link header branch.
check "export rewrites a Link header" \
  contains "$(fetch /e2e-link-header -D - -o /dev/null)" "Link: <$PUBLIC/x>; rel=\"x\""
check "normal mode leaves a Link header" \
  contains "$(fetch_with "" /e2e-link-header -D - -o /dev/null)" "Link: <https://$LOCAL/x>"

# Something that flushes early sends the headers; the body after that must still be rewritten.
FLUSHED=$(fetch /e2e-flush)
check "export rewrites the part flushed early"       contains "$FLUSHED" "first $PUBLIC/a"
check "export rewrites the body after the headers went" contains "$FLUSHED" "second headers-sent $PUBLIC/b"
# A length set for the shorter local body must not cut off the longer public one.
check "an early flush drops a Content-Length the rewrite would outgrow" \
  contains "$(fetch /e2e-length)" "first $PUBLIC/b"

WRONG_PAGE=$(fetch_with "not-the-secret" /)
NONE_PAGE=$(fetch_with "" /)
check "a wrong secret is not export mode"            contains "$WRONG_PAGE" "$LOCAL"
check "no secret is not export mode"                 contains "$NONE_PAGE" "$LOCAL"
check "a wrong secret still serves the page"         equals "$(status_of not-the-secret /)" 200

check "control: a normal request does take the cron lock" \
  test -n "$(cron_lock)"
check "normal mode still has the wp-json link"        contains "$NONE_PAGE" "wp-json"
# Why bin/check-site and the exporter's Rules refuse wp-json anywhere after a leading index.php, and index.php spelled
# with any dot: WordPress answers each of these from the REST API.
for path in /index.php/wp-json/ /index.php/index.php/wp-json/ /index.php/indexXphp/wp-json/ /indexXphp/wp-json/; do
  check "control: WordPress answers $path from the REST API" contains "$(fetch_with "" "$path")" '"namespaces"'
done
check "home is still https://$LOCAL"               equals "$(wp option get home)" "https://$LOCAL"
check "siteurl is still https://$LOCAL"            equals "$(wp option get siteurl)" "https://$LOCAL"

# --- asking for a publish, and the admin bar ----------------------------------------------------
# $E2E_PUBLISH, mounted read-only at /var/www/publish, stands in for var/ on the Mac, and $E2E_INBOX,
# at /var/www/publish-inbox, for var/inbox. No agent runs here, so a request stays where WordPress wrote
# it, and the status file is whatever the test writes.
REQ="$E2E_INBOX/publish-request"
STATUS="$E2E_PUBLISH/status.json"
asked() { [ -f "$REQ" ]; }
not_asked() { [ ! -e "$REQ" ]; }
fresh() { rm -f "$REQ"; dc exec -T wordpress rm -f /tmp/e2e-requests; }
requests_written() { dc exec -T wordpress sh -c 'cat /tmp/e2e-requests 2>/dev/null' | grep -c .; }
# publish_php MODE [ARGS...]: tests/e2e-publish.php in the throwaway WordPress (see that file).
publish_php() { dc exec -T -u www-data wordpress wp eval-file - "$@" <tests/e2e-publish.php 2>&1; }
bar() { publish_php bar "$@" --user=e2e-admin; }
field() { printf '%s\n' "$2" | sed -n "s/^$1: //p"; }
# clean_bar OUTPUT: a node was made, with no PHP notice and no fatal error.
clean_bar() { lacks "$1" "php:" && lacks "$1" "critical error" && [ -n "$(field title "$1")" ]; }
# status_is STATE RUNNING AGE [MESSAGE [WARNING...]]: a status file as bin/publish writes it, AGE
# seconds old (its "at" and its mtime). Sets AT.
status_is() {
  AT=$(($(date +%s) - $3))
  php -r '
    $w = array_slice( $argv, 5 );
    echo json_encode( array( "state" => $argv[1], "running" => "true" === $argv[2], "at" => gmdate( "Y-m-d\TH:i:s\Z", (int) $argv[3] ),
      "commit" => "0123456789abcdef0123456789abcdef01234567", "message" => $argv[4] ?? "", "warnings" => $w ),
      JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE ), "\n";' "$1" "$2" "$AT" "${@:4}" >"$STATUS"
  aged "$STATUS" "$3"
}
aged() { php -r 'touch( $argv[1], time() - (int) $argv[2] );' "$1" "$2"; }
# site_time FORMAT UNIX_TIME: the time as the site's timezone shows it, worked out apart from WordPress.
site_time() { dc exec -T wordpress php -r 'date_default_timezone_set( "Pacific/Chatham" ); echo date( $argv[1], (int) $argv[2] );' "$1" "$2"; }
# cant_write USER: USER in the container can't make a file in the status folder.
cant_write() { ! dc exec -T -u "$1" wordpress sh -c ': > /var/www/publish/probe' 2>/dev/null; }
wp option update timezone_string Pacific/Chatham >/dev/null
wp user create e2e-contrib e2e-contrib@example.com --role=contributor >/dev/null

# Only the inbox is WordPress's to write.
check "WordPress can't write in the status folder"     cant_write www-data
check "not even as root"                               cant_write root
check "and nothing got there"                          test ! -e "$E2E_PUBLISH/probe"

# What asks, and what doesn't.
fresh; P1=$(wp post create --post_title='Will publish' --post_status=draft --post_author=1 --porcelain)
check "saving a new draft does not ask"                not_asked
wp post update "$P1" --post_title='Still a draft' >/dev/null
check "saving a draft again does not ask"              not_asked
wp post update "$P1" --post_status=publish >/dev/null
check "publishing a draft asks"                        asked
check "the request is one line: a UTC time and the post" \
  equals "$(grep -cE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z post $P1\$" "$REQ")/$(wc -l <"$REQ" | tr -d ' ')" "1/1"
check "no temporary file is left beside it"            equals "$(ls -A "$E2E_INBOX")" publish-request
check "and nothing is written in the status folder"   equals "$(ls -A "$E2E_PUBLISH")" ""
fresh; wp post update "$P1" --post_title='Changed while published' >/dev/null
check "updating a published post asks"                 asked
fresh; wp eval "_wp_put_post_revision( array_merge( get_post( $P1, ARRAY_A ), array( 'post_title' => 'autosaved' ) ), true );" >/dev/null
check "an autosave does not ask"                       not_asked
wp eval "_wp_put_post_revision( get_post( $P1 ) );" >/dev/null
check "a revision does not ask"                        not_asked
wp eval "define( 'DOING_AUTOSAVE', true ); wp_update_post( array( 'ID' => $P1, 'post_title' => 'In an autosave' ) );" >/dev/null
check "a change made while DOING_AUTOSAVE does not ask" not_asked
wp post delete "$P1" >/dev/null
check "trashing a published post asks"                 asked
fresh; wp post delete "$P1" --force >/dev/null
check "deleting it from the trash does not ask again"  not_asked
P2=$(wp post create --post_title='Gone for good' --post_status=publish --post_author=1 --porcelain)
fresh; wp post delete "$P2" --force >/dev/null
check "deleting a published post outright asks"        asked
fresh; wp post create --post_type=page --post_title='A page' --post_status=publish --post_author=1 >/dev/null
check "publishing a page asks"                         asked
fresh; wp post create --post_type=wp_block --post_title='A pattern' --post_status=publish >/dev/null
check "publishing a pattern (not a public type) does not ask" not_asked
fresh
for type in wp_template wp_template_part wp_navigation wp_global_styles wp_block; do
  id=$(wp post create --post_type="$type" --post_title="E2E $type" --post_name="e2e-$type" --post_status=publish --porcelain)
  check "control: a published $type was made" equals "$(wp post get "$id" --field=post_status 2>/dev/null)" publish
  wp post update "$id" --post_content='<!-- wp:paragraph --><p>Changed</p><!-- /wp:paragraph -->' >/dev/null
done
check "making and saving templates, template parts, navigation, global styles and patterns does not ask" not_asked
check "control: nothing was written for them"          equals "$(requests_written)" 0
MEDIA=$(wp media import /tmp/in-post.png --porcelain)
check "control: the upload is an attachment"           equals "$(wp post get "$MEDIA" --field=post_type)" attachment
check "uploading media does not ask"                   not_asked
MENU=$(wp menu create 'E2E menu' --porcelain)
wp menu item add-custom "$MENU" Example https://example.com/ >/dev/null
check "control: the menu item is published" \
  equals "$(wp post list --post_type=nav_menu_item --post_status=publish --format=count)" 1
wp menu item update "$(wp menu item list "$MENU" --field=db_id)" --title=Changed >/dev/null
wp menu delete "$MENU" >/dev/null
check "saving, changing and deleting a menu does not ask" not_asked
CAT=$(wp term create category Changes --porcelain)
check "creating a category does not ask"               not_asked
wp term update category "$CAT" --name=Changed >/dev/null
check "editing a category asks"                        asked
check "naming the term"                                contains "$(cat "$REQ")" " term $CAT"
fresh; wp term delete category "$CAT" >/dev/null
check "deleting a category asks"                       asked
B1=$(wp post create --post_title='Bulk one' --post_status=draft --post_author=1 --porcelain)
B2=$(wp post create --post_title='Bulk two' --post_status=draft --post_author=1 --porcelain)
fresh; wp post update "$B1" "$B2" --post_status=publish >/dev/null
check "publishing two posts at once asks"              asked
check "and writes the request once"                    equals "$(requests_written)" 1
check "naming the first and counting the rest"         contains "$(cat "$REQ")" "post $B1 and 1 more"
fresh; wp eval 'Offprint\Request::request( "button" );' >/dev/null
check "Request::request('button') asks"                contains "$(cat "$REQ" 2>/dev/null)" "Z button"
fresh; wp eval 'Offprint\Request::request( "Odd; \$(reason) <b>" );' >/dev/null
check "a reason is cleaned to [a-z0-9 _-]"             equals "$(cut -d' ' -f2- "$REQ" 2>/dev/null)" "odd reason b"

# Export mode asks nothing, whatever the request changes.
fresh
check "control: a normal request that changes a post" equals "$(fetch_with "" "/e2e-touch-post?id=$HELLO_ID")" touched
check "control: asks"                                  asked
fresh
check "export mode: a request that changes a post"    equals "$(fetch "/e2e-touch-post?id=$HELLO_ID")" touched
check "export mode: asks nothing"                      not_asked

# The admin bar, for each status.
rm -f "$REQ" "$STATUS"
BAR=$(bar)
check "no status file: Not published yet"              equals "$(field title "$BAR")" "Not published yet"
check "the node has the Publish Site button"           equals "$(field button "$BAR")" "Publish Site"
check "which posts to admin-post.php with a nonce" \
  contains "$BAR" "action=\"https://$LOCAL/wp-admin/admin-post.php\""
check "for the offprint_request action"          contains "$BAR" 'name="action" value="offprint_request"'
check "with a nonce field of its own"                  contains "$BAR" 'name="offprint_nonce"'
check "not a second _wpnonce on the screen"            lacks "$BAR" '_wpnonce'
check "a user who can't publish gets no node"          equals "$(publish_php bar --user=e2e-contrib)" "no node"
check "a site with no pigeonhole: nothing about comments in the node" lacks "$BAR" "omments"
for state in exporting checking pushing deploying; do
  status_is "$state" true 5 "Working on it"
  BAR=$(bar)
  check "$state, running: Publishing… ($state)"       equals "$(field title "$BAR")" "Publishing… ($state)"
  check "$state, running: amber"                       equals "$(field tone "$BAR")" busy
  check "$state, running: the message below"           equals "$(field line "$BAR")" "Working on it"
done
status_is live false 5 "The site is live at 0123456"
BAR=$(bar)
check "live: Live and the time, in the site's timezone" equals "$(field title "$BAR")" "Live · $(site_time 'g:i a' "$AT")"
check "live: green"                                    equals "$(field tone "$BAR")" live
check "live: the commit below"                         equals "$(field line "$BAR")" "Commit 0123456"
status_is live false $((3 * 86400))
check "live days ago: with the date too" \
  equals "$(field title "$(bar)")" "Live · $(site_time 'F j, Y g:i a' "$AT")"
status_is unchanged false 5 "Nothing has changed since the last publish."
check "unchanged: Live (no changes) and the time"     equals "$(field title "$(bar)")" "Live (no changes) · $(site_time 'g:i a' "$AT")"
status_is failed false 5 "The export failed the checks" "Warning: one" "Warning: two"
BAR=$(bar)
check "failed: Publish failed"                         equals "$(field title "$BAR")" "Publish failed"
check "failed: red"                                    equals "$(field tone "$BAR")" failed
check "failed: the message, then each warning, below" \
  equals "$(field line "$BAR" | paste -sd'|' -)" "The export failed the checks|Warning: one|Warning: two"
status_is checking false 5 "Dry run: the export is in var/export and passed the checks."
check "a dry run: its message"                         equals "$(field title "$(bar)")" "Dry run: the export is in var/export and passed the checks."
status_is checking false 5 "Committed, not pushed (--no-push)."
check "--no-push: its message"                         equals "$(field title "$(bar)")" "Committed, not pushed (--no-push)."
status_is exporting true 1200 "Exporting the site from WordPress"
BAR=$(bar)
check "running, but nothing for 20 minutes: may be stuck" equals "$(field title "$BAR")" "Publish may be stuck"
check "stuck: says to look at the log"                 contains "$BAR" "var/publish.log"
check "stuck: and at the agent"                        contains "$BAR" "offprint install-agent"
status_is live false 60
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') button" >"$REQ"
check "a request newer than the status: requested"     equals "$(field title "$(bar)")" "Publish requested…"
aged "$REQ" 120
check "a request older than the status: still waiting (the Mac removes what it takes)" \
  equals "$(field title "$(bar)")" "Publish requested…"
rm -f "$REQ"; echo "2026-11-20T10:00:00Z button" >"$E2E_PUBLISH/publish-waiting"
check "one the Mac has taken but not run (var/publish-waiting): requested" equals "$(field title "$(bar)")" "Publish requested…"
aged "$E2E_PUBLISH/publish-waiting" 1200
check "and if the Mac hasn't touched it for 20 minutes: may be stuck" equals "$(field title "$(bar)")" "Publish may be stuck"
rm -f "$E2E_PUBLISH/publish-waiting"; echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') button" >"$REQ"
rm -f "$STATUS"; aged "$REQ" 1200
check "a request nobody took for 20 minutes: may be stuck" equals "$(field title "$(bar)")" "Publish may be stuck"
check "no PHP notices from any of it"                  clean_bar "$(bar)"
rm -f "$REQ"   # nothing waiting from here on, so the status shows

# A status file is data from outside WordPress.
for bad in '{"state":"live","running":' '[1,2,3]' '{"state":["live"],"running":"yes","at":5,"commit":"<b>","message":{"a":1},"warnings":"no"}'; do
  printf '%s' "$bad" >"$STATUS"
  BAR=$(bar)
  check "a malformed status ($bad): a node, no PHP notice" clean_bar "$BAR"
done
printf '%s' '[1,2,3]' >"$STATUS"
check "a status that isn't one: Publish status unknown" equals "$(field title "$(bar)")" "Publish status unknown"
head -c 2000000 /dev/zero | tr '\0' 'x' | sed 's/^/{"state":"failed","message":"/; s/$/"}/' >"$STATUS"
BAR=$(bar)
check "a 2 MB status: a node, no PHP notice"           clean_bar "$BAR"
check "a 2 MB status: Publish status unknown"          equals "$(field title "$BAR")" "Publish status unknown"
status_is failed false 5 '<script>alert("m")</script>' '<img src=x onerror=alert(1)>'
BAR=$(bar)
check "HTML in the status is text in the node"         equals "$(field line "$BAR" | head -1)" '<script>alert("m")</script>'
check "and escaped in its HTML"                        contains "$BAR" 'raw: &lt;script&gt;alert(&quot;m&quot;)&lt;/script&gt;'
check "with no raw script"                             lacks "$(field raw "$BAR")" '<script>alert'
check "the warning too"                                contains "$BAR" 'raw: &lt;img src=x onerror=alert(1)&gt;'
check "with no raw img"                                lacks "$(field raw "$BAR")" '<img src=x'

# The same, through the web: the front end and wp-admin, the status action and the button.
ADMIN_AUTH=$(publish_php auth e2e-admin)
ADMIN_COOKIE=$(echo "$ADMIN_AUTH" | sed -n 1p); ADMIN_ASK=$(echo "$ADMIN_AUTH" | sed -n 2p); ADMIN_STATUS=$(echo "$ADMIN_AUTH" | sed -n 3p)
CONTRIB_AUTH=$(publish_php auth e2e-contrib)
CONTRIB_COOKIE=$(echo "$CONTRIB_AUTH" | sed -n 1p); CONTRIB_ASK=$(echo "$CONTRIB_AUTH" | sed -n 2p); CONTRIB_STATUS=$(echo "$CONTRIB_AUTH" | sed -n 3p)
# Through the REST API, as the block editor does it: once per change.
ADMIN_REST=$(echo "$ADMIN_AUTH" | sed -n 4p)
rest() { fetch_with "" "/?rest_route=$1" -X POST -H "$ADMIN_COOKIE" -H "X-WP-Nonce: $ADMIN_REST" -H 'Content-Type: application/json' --data "$2" -o /dev/null -w '%{http_code}'; }
VIA_REST=$(wp post create --post_title='Via REST' --post_status=draft --post_author=1 --porcelain)
fresh
check "REST: publishing a draft works"                 equals "$(rest "/wp/v2/posts/$VIA_REST" '{"status":"publish"}')" 200
check "REST: control: it is published"                 equals "$(wp post get "$VIA_REST" --field=post_status)" publish
check "REST: it asks"                                  asked
check "REST: once"                                     equals "$(requests_written)" 1
REST_CAT=$(wp term create category 'Via REST' --porcelain)
fresh
check "REST: renaming a category works"                equals "$(rest "/wp/v2/categories/$REST_CAT" '{"name":"Renamed via REST"}')" 200
check "REST: it asks, once"                            equals "$(requests_written)" 1
check "REST: naming the term"                          contains "$(cat "$REQ" 2>/dev/null)" " term $REST_CAT"
wp term delete category "$REST_CAT" >/dev/null
fresh   # nothing waiting from here on, so the status shows
FRONT=$(fetch_with "" / -H "$COOKIE")
check "front end, logged in: the node is there"        contains "$FRONT" "id='wp-admin-bar-offprint'"
check "front end: the status HTML is escaped"          contains "$FRONT" '&lt;script&gt;alert(&quot;m&quot;)&lt;/script&gt;'
check "front end: no raw script from the status"       lacks "$FRONT" '<script>alert("m")'
check "front end: no raw img from the status"          lacks "$FRONT" '<img src=x'
check "front end: the style is there"                  contains "$FRONT" 'offprint-admin-bar-inline-css'
check "front end: the script is there"                 contains "$FRONT" 'offprint-admin-bar-js-after'
check "front end: after its config"                    contains "$FRONT" 'window.offprintAdminBar = {'
check "front end: the script is the plugin's admin-bar.js" contains "$FRONT" "}( window.offprintAdminBar ) );"
check "front end, logged out: none of it"              lacks "$(fetch_with "" /)" "offprint"
check "wp-admin: the node is there too" \
  contains "$(fetch_with "" /wp-admin/ -H "$ADMIN_COOKIE")" "id='wp-admin-bar-offprint'"
check "export mode with a cookie: no node, no script"  lacks "$(fetch / -H "$COOKIE")" "offprint"
AJAX="/wp-admin/admin-ajax.php?action=offprint_status"
check "status action: refuses a logged-out request"    equals "$(fetch_with "" "$AJAX&nonce=$ADMIN_STATUS" -w ' %{http_code}')" "0 400"
check "status action: refuses a wrong nonce"           equals "$(fetch_with "" "$AJAX&nonce=wrong" -H "$ADMIN_COOKIE" -w ' %{http_code}')" "-1 403"
check "status action: refuses a user who can't publish" \
  equals "$(fetch_with "" "$AJAX&nonce=$CONTRIB_STATUS" -H "$CONTRIB_COOKIE" -o /dev/null -w '%{http_code}')" 403
JSON=$(fetch_with "" "$AJAX&nonce=$ADMIN_STATUS" -H "$ADMIN_COOKIE")
json() { php -r '$j = json_decode( stream_get_contents( STDIN ), true ); $v = $j["data"][ $argv[1] ] ?? null; echo is_array( $v ) ? implode( "|", $v ) : var_export( $v, true );' "$1" <<<"$JSON"; }
check "status action: the title"                       equals "$(json title)" "'Publish failed'"
check "status action: running"                         equals "$(json running)" false
check "status action: the lines, as text" \
  equals "$(json lines)" '<script>alert("m")</script>|<img src=x onerror=alert(1)>'
check "status action: no raw < in the JSON"            lacks "$JSON" "<"
fresh
POST=/wp-admin/admin-post.php
check "button: refuses a wrong nonce" \
  equals "$(fetch_with "" "$POST" -H "$ADMIN_COOKIE" --data "action=offprint_request&offprint_nonce=wrong" -o /dev/null -w '%{http_code}')" 403
check "button: a wrong nonce asks nothing"             not_asked
check "button: refuses a user who can't publish" \
  equals "$(fetch_with "" "$POST" -H "$CONTRIB_COOKIE" --data "action=offprint_request&offprint_nonce=$CONTRIB_ASK" -o /dev/null -w '%{http_code}')" 403
check "button: that asks nothing either"               not_asked
check "button: asks, then goes back to the page it was on" \
  equals "$(fetch_with "" "$POST" -H "$ADMIN_COOKIE" -H "Referer: https://$LOCAL/wp-admin/edit.php" \
    --data "action=offprint_request&offprint_nonce=$ADMIN_ASK" -o /dev/null -w '%{http_code} %{redirect_url}')" "302 https://$LOCAL/wp-admin/edit.php"
check "button: the request says button"                contains "$(cat "$REQ" 2>/dev/null)" "Z button"

# When the folder isn't there or can't be written, say so; never a PHP warning.
dc exec -T wordpress sh -c 'mkdir -p /var/www/publish-ro && chmod 755 /var/www/publish-ro'
BAR=$(bar /var/www/publish-ro)
check "a folder WordPress can't write: Can't ask"      equals "$(field title "$BAR")" "Can't ask for a publish"
check "a folder WordPress can't write: says which"     contains "$(field line "$BAR")" "/var/www/publish-ro"
BAR=$(bar /var/www/publish-missing)
check "no folder: Can't ask"                           equals "$(field title "$BAR")" "Can't ask for a publish"
check "no folder: says to recreate the container"      contains "$BAR" "offprint compose up -d"
fresh; OUT=$(publish_php request /var/www/publish-missing button)
check "asking with no folder: no PHP warning, no fatal" equals "$OUT" "done"
check "asking with no folder: writes nothing"          not_asked
BAR=$(bar)
check "with the folder back, the failed request is still shown" equals "$(field title "$BAR")" "Last request didn't reach the Mac"
check "and says to ask again"                          contains "$(field line "$BAR" | head -1)" "Use Publish Site to ask again"
status_is live false -5
check "a publish that started since then covers it"   equals "$(field title "$(bar)")" "Live · $(site_time 'g:i a' "$AT")"
status_is failed false 600 "An old failure"
OUT=$(publish_php request /var/www/publish-ro button)
check "asking where it can't write: no PHP warning"    equals "$OUT" "done"
wp eval 'Offprint\Request::request( "button" );' >/dev/null
check "a request that works clears it"                 equals "$(field title "$(bar)")" "Publish requested…"
check "nothing was made in this repo (var/, wp-content/, local/ at its root, in tests/fixtures/ or in templates/)" \
  equals "$(repo_writes)" "$REPO_WRITES_BEFORE"

# --- wp offprint export ---------------------------------------------------------------------------
# What the export must find by itself: a second page of posts, a category, a page with forms.
# Content gets an author, as real posts have (WP-CLI would leave it 0, and a classic theme then
# links to an author archive at /author/ that doesn't exist).
wp post generate --count=12 --post_status=publish --post_author=1 >/dev/null
wp term create category Notes --slug=notes >/dev/null
wp post term set "$HELLO_ID" category notes >/dev/null
# A post whose address changed: WordPress redirects the old one, so the export saves it there too.
MOVED_ID=$(wp post create --post_title=Moved --post_name=before --post_status=publish --post_author=1 --porcelain)
wp post update "$MOVED_ID" --post_name=after >/dev/null
# Find also links to a post without its trailing slash (a redirect to the same file) and to the
# old address, and has a form of its own besides the search. (Made by the admin, whose content
# may hold a <form>.)
wp post create --user=e2e-admin --post_type=page --post_title=Find --post_name=find --post_status=publish \
  --post_content='<!-- wp:search {"label":"Search","buttonText":"Search"} /-->
<p><a href="/hello-static">no slash</a> <a href="/before/">old address</a></p>
<form action="/find/results/" method="post"><button>Go</button></form>' >/dev/null
# The default Sample Page links to the dashboard, which no static page can. (The export warns about
# it, as the "Bad link" page below shows; this keeps the every-link-has-a-file check meaningful.)
wp post delete "$(wp post list --post_type=page --name=sample-page --field=ID)" --force >/dev/null
# An image's attachment page: WordPress redirects it to the image itself.
ATTACHMENT_PAGE=$(wp eval "echo get_attachment_link($IN_POST_ID);")
ATTACHMENT_PUBLIC="$PUBLIC${ATTACHMENT_PAGE#"https://$LOCAL"}"
IN_POST_PUBLIC="$PUBLIC${IN_POST_URL#"https://$LOCAL"}"

# in_order TEXT: warnings, then errors, then the summary as the last line, and nothing else.
in_order() {
  printf '%s\n' "$1" | awk '
    { t = /^Warning: / ? 1 : /^Error: / ? 2 : /^Exported [0-9]+ files, [0-9]+ bytes\.$/ ? 3 : 9
      if (t == 9 || t < last || last == 3) bad = 1
      last = t }
    END { exit (bad || last != 3) }'
}
# links_in DIR: tests/e2e-links.php on an export, run by the container's PHP.
links_in() { dc exec -T wordpress php -- "/var/www/export/$1" "$PUBLIC" <tests/e2e-links.php 2>&1; }

# export_block THEME TEXT_404: activates THEME, then exports and checks the result.
export_block() {
  local theme=$1 text_404=$2 out="$E2E_EXPORT/$1" installed links links_status ids
  if ! installed=$(wp theme install "$theme" --activate 2>&1) || ! equals "$(wp option get stylesheet)" "$theme"; then
    FAILED=$((FAILED + 1))
    echo "FAIL - $theme could not be installed and activated (can the container reach wordpress.org?)"
    echo "$installed" | sed 's/^/    /'
    return
  fi
  echo "# $theme"

  run_export "$theme"
  echo "$EXPORT_OUT" | sed 's/^/    /'
  check "$theme: export exits 0"                         equals "$EXPORT_STATUS" 0
  check "$theme: warnings, errors, then the summary, all on stdout" in_order "$EXPORT_OUT"
  check "$theme: nothing on stderr"                      equals "$EXPORT_ERR" ""
  for file in index.html hello-static/index.html page/2/index.html category/notes/index.html \
    feed/index.xml 404.html robots.txt wp-sitemap.xml; do
    check "$theme: $file exists and is not empty"        test -s "$out/$file"
  done
  check "$theme: 404.html has the theme's 404 text"      grep -q "$text_404" "$out/404.html"
  check "$theme: in-post.png is exported"                test -n "$(found_in "$out/wp-content/uploads" in-post.png)"
  check "$theme: control: draft-only.png is in uploads"  test -n "$(found_in "$E2E_WP_CONTENT/uploads" draft-only.png)"
  check "$theme: draft-only.png is nowhere in the export" not_found_in "$out" 'draft-only*'
  check "$theme: no file says $LOCAL"                  never_says "$out" "$LOCAL_RE"
  check "$theme: warns that /find/ has a form" \
    contains "$EXPORT_OUT" "Warning: a form posting to $PUBLIC/find/results/ is on 1 page, first seen on $PUBLIC/find/; it won't work on the static site"
  check "$theme: the search form, however many pages have it, is one warning" \
    equals "$(printf '%s\n' "$EXPORT_OUT" | grep -c "^Warning: a form posting to $PUBLIC/ is on ")" 1
  check "$theme: control: the moved post is at its new address" grep -q Moved "$out/after/index.html"
  check "$theme: its old address holds the same page"    cmp -s "$out/before/index.html" "$out/after/index.html"

  # In place of clicking through the site: every address a page or stylesheet uses is there.
  links=$(links_in "$theme")
  links_status=$?
  check "$theme: every same-site address in every page and stylesheet has a file" equals "$links_status" 0
  check "$theme: the link check looked at addresses"     test "$(echo "$links" | sed -n 's/^checked //p')" -gt 50
  { echo "$links" | grep -v '^checked ' | head -20; echo "$links" | tail -1; } | sed 's/^/    link check: /'
  rm -f "$(found_in "$out/wp-content/uploads" in-post.png)"
  check "$theme: control: the link check sees a missing file" contains "$(links_in "$theme")" "in-post.png"

  # A broken link, a redirect to another site, a compressed response, an image linked to its
  # attachment page, a refused link on two pages, and a page that says the local host.
  ids="$(wp post create --post_type=page --post_title='Bad link' --post_name=bad-link --post_status=publish \
    --post_author=1 --porcelain --post_content="<p><a href=\"/no-such-page/\">gone</a> <a href=\"/wp-login.php\">log in</a>
<a href=\"/e2e-offsite\">away</a> <a href=\"/e2e-gzip\">zipped</a></p>
<p><a href=\"$ATTACHMENT_PAGE\"><img src=\"$IN_POST_URL\" alt=\"\"></a></p>")"
  ids="$ids $(wp post create --post_type=page --post_title=Leak --post_name=leak --post_status=publish \
    --post_author=1 --porcelain --post_content="<p>Written on $LOCAL. <a href=\"/wp-login.php\">log in</a></p>")"
  run_export "$theme-bad"
  echo "$EXPORT_OUT" | grep -v '^Warning: a form posting' | sed 's/^/    /'
  check "$theme: a broken link fails the export"         equals "$EXPORT_STATUS" 1
  check "$theme: failing, it is still warnings, errors, then the summary" in_order "$EXPORT_OUT"
  check "$theme: failing, nothing on stderr"             equals "$EXPORT_ERR" ""
  check "$theme: the error names the address and the page linking to it" \
    contains "$EXPORT_OUT" "Error: $PUBLIC/no-such-page/ answered 404 (linked from $PUBLIC/bad-link/)"
  check "$theme: a redirect to another site is an error naming the page linking to it" \
    contains "$EXPORT_OUT" "Error: $PUBLIC/e2e-offsite redirects to https://example.com/, which is not exported (linked from $PUBLIC/bad-link/)"
  check "$theme: a page that says $LOCAL is an error"  contains "$EXPORT_OUT" "Error: $PUBLIC/leak/ contains $LOCAL"
  check "$theme: a compressed response is an error" \
    contains "$EXPORT_OUT" "Error: $PUBLIC/e2e-gzip could not be fetched: it came back compressed (Content-Encoding: gzip)"
  check "$theme: an attachment page that redirects to its image is a warning" \
    contains "$EXPORT_OUT" "Warning: $ATTACHMENT_PUBLIC redirects to the file $IN_POST_PUBLIC; links to it will not work on the static site (first seen on $PUBLIC/bad-link/)"
  check "$theme: the image is exported"                  test -n "$(found_in "$E2E_EXPORT/$theme-bad/wp-content/uploads" in-post.png)"
  check "$theme: the attachment page is not"             test ! -e "$E2E_EXPORT/$theme-bad${ATTACHMENT_PAGE#"https://$LOCAL"}"
  check "$theme: one warning for a refused address on two pages" \
    equals "$(echo "$EXPORT_OUT" | grep -c "^Warning: .*$PUBLIC/wp-login\.php")" 1
  check "$theme: which names the address and counts the pages" \
    contains "$EXPORT_OUT" "links to $PUBLIC/wp-login.php, which is not exported (2 pages in all)"
  # shellcheck disable=SC2086 # two IDs
  wp post delete $ids --force >/dev/null
}

export_block twentytwentyone 'Nothing here'
run_export twentytwentyone
check "the export refuses a folder that is not empty"    equals "$EXPORT_STATUS" 1
check "and says why"                                     contains "$EXPORT_OUT" "is not empty"
check "and leaves what was there"                        test -s "$E2E_EXPORT/twentytwentyone/index.html"
# With sitemaps off (as "Discourage search engines" turns them off) it says what that costs.
wp option update blog_public 0 >/dev/null
run_export no-sitemaps
check "sitemaps off: the export still works"             equals "$EXPORT_STATUS" 0
check "sitemaps off: it warns that only linked pages are exported" \
  contains "$EXPORT_OUT" "Warning: Sitemaps are off, so only pages reachable by links"
check "sitemaps off: once"                               equals "$(printf '%s\n' "$EXPORT_OUT" | grep -c '^Warning: Sitemaps are off')" 1
# robots.txt still names WordPress's sitemap, which is a 404 now: a warning, not an error.
check "sitemaps off: robots.txt naming the sitemap that isn't there is a warning" \
  contains "$EXPORT_OUT" "Warning: robots.txt names the sitemap $PUBLIC/wp-sitemap.xml, which could not be exported: it answered 404"
check "sitemaps off: no sitemap"                         test ! -e "$E2E_EXPORT/no-sitemaps/wp-sitemap.xml"
check "sitemaps off: control: the home page is there"    test -s "$E2E_EXPORT/no-sitemaps/index.html"
wp option update blog_public 1 >/dev/null
export_block twentytwentyfive 'Page not found'

# --- the cloudflare-workers adapter, on a real export ------------------------------------------
# A fresh export (the theme's own above had a file removed on purpose), copied, with adapter_prepare's files for
# cloudflare-workers written into the copy, then bin/check-site on it with that adapter's names and limits, as a
# publish runs it (check_site_as_published, in tests/e2e-setup.sh).
run_export cf-check
check "cloudflare-workers: a fresh export for it"        equals "$EXPORT_STATUS" 0
CF_COPY="$WORK/cf-check"
check_site_as_published "$E2E_EXPORT/cf-check" "$CF_COPY"
CF_STATUS=$?
CF_OUT=$CHECK_OUT
[ "$CF_STATUS" = 0 ] || printf '%s\n' "$CF_OUT" | head -20 | sed 's/^/    cloudflare-workers check: /'
check "cloudflare-workers: a real export, its _headers and _redirects in place, passes bin/check-site with its names and limits" \
  equals "$CF_STATUS" 0
check "cloudflare-workers: its _redirects is in the copy" grep -qx '/feed/ /feed/index.xml 200' "$CF_COPY/_redirects"
check "cloudflare-workers: its _headers is in the copy"  grep -q 'Cache-Control: no-store' "$CF_COPY/_headers"

# --- offprint_own_project, against a real compose project -----------------------------------------
# lib/site.sh's own question (the one a publish asks before any compose call), put to Docker about the throwaway project:
# its containers were made from $WORK, and its volumes carry Offprint's labels, so it is that folder's own. Asked for
# another folder, it is not.
OWN_RC=$( ( SITE_NAME="$PROJECT"; SITE="$WORK"; OFFPRINT_PROJECT_OK=""; offprint_own_project >/dev/null 2>&1; echo $? ) )
check "offprint_own_project: the real $PROJECT project is its folder's own (0)" equals "$OWN_RC" 0
OWN_RC=$( ( SITE_NAME="$PROJECT"; SITE="$TOOL"; OFFPRINT_PROJECT_OK=""; offprint_own_project >/dev/null 2>&1; echo $? ) )
check "offprint_own_project: control: the same project asked about another folder (1)" equals "$OWN_RC" 1

# --- a comment from the pigeonhole, imported (wp offprint import-submission) ----------------------------------------
# What offprint collect hands WordPress, one checked submission a time on a pipe, with the site's plugins and theme
# loaded: here the lines are made as lib/pigeonhole.php prints them. Importing never publishes; the HTML filter
# is on (under WP-CLI it is off by itself); a link keeps its address only when it is a whole one to another site; and
# the same submission twice is one comment.
PH_TS=$(( $(date +%s) - 100 ))
PH_N=0
# ph POST PARENT AUTHOR EMAIL URL CONTENT [KIND]: one checked submission, with an id of its own, as PH_LINE
ph() {
  PH_N=$((PH_N + 1))
  PH_LINE=$(PH_ID=$(printf '%032x' "$PH_N") PH_TS="$PH_TS" php -r 'require $argv[1];
    $f = ["post_id" => (int) $argv[2], "parent" => (int) $argv[3], "author" => $argv[4], "email" => $argv[5], "url" => $argv[6], "content" => $argv[7], "hp" => "", "elapsed" => 42];
    $kind = $argv[8] ?? "comment";
    echo offprint_pigeonhole_line(["v" => 1, "kind" => $kind, "id" => getenv("PH_ID"), "ts" => (int) getenv("PH_TS"), "page" => "/", "fields" => $kind === "comment" ? $f : []]), "\n";' \
    "$TOOL/lib/pigeonhole.php" "$@")
}
# ph_import SORTED [LINE]: WordPress's one-line answer to PH_LINE (or LINE), as PH_OUT, and the comment's number as PH_C
ph_import() {
  PH_OUT=$(printf '%s\n' "${2-$PH_LINE}" | dc exec -T -u www-data wordpress wp offprint import-submission --sorted="$1" 2>&1 | tail -1)
  PH_C=$(printf '%s' "$PH_OUT" | sed -n 's/^imported \([0-9][0-9]*\) [a-z]*$/\1/p')
}
ph_field() { wp comment get "$1" --field="$2" 2>/dev/null; }
ph_refused() { ph_import hold; check "pigeonhole: refused: $1" equals "$PH_OUT" "refused $2"; }
ph_no_mail() {
  check "pigeonhole: no mail was sent $1" test ! -e "$E2E_WP_CONTENT/e2e-mail.log"
  [ ! -e "$E2E_WP_CONTENT/e2e-mail.log" ] || sed 's/^/    mail: /' "$E2E_WP_CONTENT/e2e-mail.log"
  rm -f "$E2E_WP_CONTENT/e2e-mail.log"
}
# every mail WordPress tries to send is noted, and none is sent
cat > "$E2E_WP_CONTENT/mu-plugins/zz-e2e-mail.php" <<'PHP'
<?php
add_filter('pre_wp_mail', function ($r, $a) { file_put_contents(WP_CONTENT_DIR . '/e2e-mail.log', $a['subject'] . "\n", FILE_APPEND); return true; }, 10, 2);
PHP
chmod a+r "$E2E_WP_CONTENT/mu-plugins/zz-e2e-mail.php"
wp eval 'wp_mail("e2e@example.com", "control", "x");' >/dev/null 2>&1
check "pigeonhole: control: a mail WordPress sends is noted"   grep -qx control "$E2E_WP_CONTENT/e2e-mail.log"
rm -f "$E2E_WP_CONTENT/e2e-mail.log"
wp option update comment_moderation 0 >/dev/null; wp option update comment_previously_approved 0 >/dev/null   # WordPress would publish at once
wp option update moderation_notify 1 >/dev/null; wp option update comments_notify 1 >/dev/null               # and send mail about it
PH_POST=$(wp post create --post_title='Takes comments' --post_name=takes-comments --post_status=publish --post_author=1 --comment_status=open --post_content='<!-- wp:paragraph --><p>Open.</p><!-- /wp:paragraph -->' --porcelain)
PH_OTHER=$(wp post create --post_title='Also takes comments' --post_status=publish --post_author=1 --comment_status=open --post_content='x' --porcelain)
PH_CLOSED=$(wp post create --post_title='Closed' --post_status=publish --post_author=1 --comment_status=closed --post_content='x' --porcelain)
PH_DRAFT=$(wp post create --post_title='Draft' --post_status=draft --post_author=1 --comment_status=open --post_content='x' --porcelain)
PH_LOCKED=$(wp post create --post_title='Locked' --post_status=publish --post_author=1 --comment_status=open --post_password=secret --post_content='x' --porcelain)
PH_APPROVED_BEFORE=$(wp comment list --status=approve --format=count)

ph "$PH_POST" 0 Ada ada@example.com https://other.example.com/ada 'MARKER-GOOD a comment with <b>bold</b> in it'; PH_GOOD=$PH_LINE
ph_import hold; PH_C1=$PH_C
check "pigeonhole: a good comment is imported, held ($PH_OUT)" test -n "$PH_C1"
check "pigeonhole: ... not approved, though WordPress's settings would publish it at once" equals "$(ph_field "$PH_C1" comment_approved)" 0
check "pigeonhole: ... as no user"                             equals "$(ph_field "$PH_C1" user_id)" 0
check "pigeonhole: ... dated when the visitor sent it"         equals "$(ph_field "$PH_C1" comment_date_gmt)" "$(php -r 'echo gmdate("Y-m-d H:i:s", (int) $argv[1]);' "$PH_TS")"
check "pigeonhole: ... with no address of the visitor's"       equals "$(ph_field "$PH_C1" comment_author_IP)" ""
check "pigeonhole: ... its allowed markup kept"                contains "$(ph_field "$PH_C1" comment_content)" '<b>bold</b>'
check "pigeonhole: ... its web address, a whole one on another site, kept" equals "$(ph_field "$PH_C1" comment_author_url)" 'https://other.example.com/ada'
check "pigeonhole: ... and its submission's id noted"          equals "$(wp comment meta get "$PH_C1" offprint_pigeonhole_id)" "$(printf '%032x' 1)"
ph_import hold "$PH_GOOD"
check "pigeonhole: the same submission again is the same comment" equals "$PH_OUT" "already $PH_C1"
check "pigeonhole: ... once"                                   equals "$(wp comment list --post_id="$PH_POST" --status=all --format=count)" 1

# Hostile markup, and links to this site itself: the exporter follows those, and one to a page that isn't there (or to
# wp-admin) would fail every publish once the comment was approved.
ph "$PH_POST" 0 Mallory mallory@example.com "$PUBLIC/not-there-either" "MARKER-XSS <script>alert(1)</script><img src=x onerror=alert(2)> <a href=\"javascript:alert(3)\" onclick=\"alert(4)\">one</a> <a href=\"/wp-admin/\">two</a> <a href=\"https://other.example.com/ok\">three</a> <a href=\"$PUBLIC/not-there\">four</a> <a href=\"https://$LOCAL/not-there\">five</a> <blockquote cite=\"$PUBLIC/not-there-cite\">six</blockquote> <iframe src=\"https://other.example.com/\"></iframe> seven $PUBLIC/bare-not-there eight ${PUBLIC#https://}/wp-admin/ nine $LOCAL ten $(printf '%s' "$LOCAL" | sed 's/\./\&#46;/g') <a href=\"https://other.example.com/?$LOCAL\">eleven</a>"
ph_import hold; PH_C2=$PH_C
check "pigeonhole: a hostile comment is imported, held, seconds after the first ($PH_OUT)" equals "$(ph_field "$PH_C2" comment_approved)" 0
PH_STORED=$(ph_field "$PH_C2" comment_content)
for bad in '<script' 'onerror' 'onclick' 'javascript:' '<iframe' '<img' 'href="alert' 'wp-admin' 'not-there' "$LOCAL" "${PUBLIC#https://}" '&#46;' 'other.example.com/?'; do
  check "pigeonhole: ... with no $bad left in what WordPress stored" lacks "$PH_STORED" "$bad"
done
check "pigeonhole: ... each address of this site's own in its words replaced, the words around it kept" \
  sh -c "printf '%s' \"\$1\" | grep -q 'seven \\[a link to this site\\] eight \\[a link to this site\\] nine \\[a link to this site\\] ten \\[a link to this site\\]'" _ "$PH_STORED"
check "pigeonhole: ... its whole link to another site kept"    contains "$PH_STORED" 'href="https://other.example.com/ok"'
check "pigeonhole: ... the words of its other links kept"      sh -c "printf '%s' \"\$1\" | grep -q 'four' && printf '%s' \"\$1\" | grep -q 'six'" _ "$PH_STORED"
check "pigeonhole: ... and its web address, on this site, dropped" equals "$(ph_field "$PH_C2" comment_author_url)" ""

ph "$PH_POST" 0 Spammer spam@example.com '' 'MARKER-SPAM buy things'; ph_import spam; PH_C3=$PH_C
check "pigeonhole: one the Mac sorted as spam goes to the spam list ($PH_OUT)" equals "$(ph_field "$PH_C3" comment_approved)" spam

ph "$PH_CLOSED" 0 Ada ada@example.com '' 'x y z';  ph_refused "a post with comments closed" 'no such public post, or its comments are closed'
ph "$PH_DRAFT" 0 Ada ada@example.com '' 'x y z';   ph_refused "a draft" 'no such public post, or its comments are closed'
ph "$PH_LOCKED" 0 Ada ada@example.com '' 'x y z';  ph_refused "a post behind a password" 'no such public post, or its comments are closed'
ph 999999 0 Ada ada@example.com '' 'x y z';        ph_refused "a post that isn't there" 'no such public post, or its comments are closed'
ph "$PH_POST" "$PH_C1" Grace grace@example.com '' 'a reply too soon'; ph_refused "a reply to a held comment" 'its parent is not an approved comment on that post'
ph "$PH_POST" 999999 Grace grace@example.com '' 'a reply to nothing'; ph_refused "a reply to a comment that isn't there" 'its parent is not an approved comment on that post'
ph_no_mail "about any of those"
wp comment approve "$PH_C1" >/dev/null
rm -f "$E2E_WP_CONTENT/e2e-mail.log"   # (approving by hand tells the post's author: not the import's doing)
ph "$PH_OTHER" "$PH_C1" Grace grace@example.com '' 'a reply elsewhere'; ph_refused "a reply to a comment on another post" 'its parent is not an approved comment on that post'
ph "$PH_POST" "$PH_C1" Grace grace@example.com '' 'MARKER-REPLY a reply'; ph_import hold; PH_C4=$PH_C
check "pigeonhole: a reply to an approved comment is imported, held ($PH_OUT)" equals "$(ph_field "$PH_C4" comment_approved)" 0
check "pigeonhole: ... under its parent"                       equals "$(ph_field "$PH_C4" comment_parent)" "$PH_C1"
# Ada has an approved comment now, and WordPress's settings would let her next one straight through.
ph "$PH_POST" 0 Ada ada@example.com '' 'MARKER-AGAIN a second from an approved author'; ph_import hold; PH_C5=$PH_C
check "pigeonhole: a second comment from an approved author is still held ($PH_OUT)" equals "$(ph_field "$PH_C5" comment_approved)" 0
ph "$PH_POST" 0 '' ada@example.com '' 'x y z';              ph_refused "no name, where the site asks for one" 'this site asks for a name and an email address'
ph "$PH_POST" 0 '   ' ada@example.com '' 'x y z';           ph_refused "a name of spaces, where the site asks for one" 'this site asks for a name and an email address'
ph "$PH_POST" 0 Ada 'not an address' '' 'x y z';            ph_refused "an email address that isn't one" 'its email address is not one'
wp option update comment_registration 1 >/dev/null
ph "$PH_POST" 0 Ada ada@example.com '' 'x y z';            ph_refused "a site that takes comments from its users only" 'this site takes comments from its registered users only'
wp option update comment_registration 0 >/dev/null
ph "$PH_POST" 0 "$LOCAL" local@example.com '' 'MARKER-NAMED a comment from someone named for the local host'; ph_import hold; PH_C6=$PH_C
check "pigeonhole: a commenter named for the local host is imported ($PH_OUT), without that name" equals "$(ph_field "$PH_C6" comment_author)" '[a link to this site]'
ph "$PH_POST" 0 Ada ada@example.com '' '<img src=x> <script></script>'; ph_refused "text that is nothing once filtered" 'nothing is left of its text once filtered'
ph "$PH_POST" 0 Ada ada@example.com https://other.example.com/ada 'MARKER-GOOD a comment with <b>bold</b> in it'; ph_refused "the same text from the same author again" 'comment_duplicate'
ph 0 0 '' '' '' '' canary;                                  ph_refused "a canary is not a comment" 'it is not a checked comment'
ph_import hold 'junk'
check "pigeonhole: refused: junk"                              equals "$PH_OUT" 'refused it is not a checked comment'
ph "$PH_POST" 0 Ada ada@example.com '' 'x y z'; ph_import publish
check "pigeonhole: refused: sorted as something else"          equals "$PH_OUT" 'refused it was sorted as neither hold nor spam'
# A post of a type that a plugin registers takes comments like any other: the import loads the site's plugins.
mkdir -p "$E2E_WP_CONTENT/plugins/e2e-books"
cat > "$E2E_WP_CONTENT/plugins/e2e-books/e2e-books.php" <<'PHP'
<?php
/* Plugin Name: E2E Books */
add_action('init', function () { register_post_type('e2e_book', array('public' => true, 'label' => 'Books', 'supports' => array('title', 'editor', 'comments'))); });
PHP
chmod -R a+rX "$E2E_WP_CONTENT/plugins/e2e-books"
wp plugin activate e2e-books >/dev/null
PH_BOOK=$(wp post create --post_type=e2e_book --post_title='A book' --post_status=publish --post_author=1 --comment_status=open --post_content='x' --porcelain)
ph "$PH_BOOK" 0 Ada ada@example.com '' 'MARKER-BOOK a comment on a book'; ph_import hold; PH_C7=$PH_C
check "pigeonhole: a comment on a post of a type a plugin registers is imported, held ($PH_OUT)" equals "$(ph_field "$PH_C7" comment_approved)" 0
check "pigeonhole: ... on that post"                          equals "$(ph_field "$PH_C7" comment_post_ID)" "$PH_BOOK"
wp post delete "$PH_BOOK" --force >/dev/null; wp plugin deactivate e2e-books >/dev/null; rm -rf "$E2E_WP_CONTENT/plugins/e2e-books"
check "pigeonhole: nothing was published by importing: one more approved comment, the one approved here by hand" \
  equals "$(wp comment list --status=approve --format=count)" "$((PH_APPROVED_BEFORE + 1))"
ph_no_mail "about those either"
# Approved, the hostile comment must neither run anything on the public page nor stop the publish.
wp comment approve "$PH_C2" "$PH_C6" >/dev/null
rm -f "$E2E_WP_CONTENT/mu-plugins/zz-e2e-mail.php" "$E2E_WP_CONTENT/e2e-mail.log"
wp post delete "$PH_LOCKED" --force >/dev/null   # (its password form posts to the login page, which the checks refuse)
run_export pigeonhole
PH_PAGE=$(cat "$E2E_EXPORT/pigeonhole/takes-comments/index.html" 2>/dev/null)
check "pigeonhole: with the hostile comment approved, the export still succeeds" equals "$EXPORT_STATUS" 0
[ "$EXPORT_STATUS" = 0 ] || printf '%s\n%s\n' "$EXPORT_OUT" "$EXPORT_ERR" | grep -i error | head -8 | sed 's/^/    pigeonhole export: /'
check "pigeonhole: ... the approved comments are on the page"  sh -c "printf '%s' \"\$1\" | grep -q MARKER-GOOD && printf '%s' \"\$1\" | grep -q MARKER-XSS" _ "$PH_PAGE"
check "pigeonhole: ... the held and spam ones are not"         sh -c "! printf '%s' \"\$1\" | grep -q 'MARKER-REPLY\|MARKER-SPAM\|MARKER-AGAIN'" _ "$PH_PAGE"
check "pigeonhole: ... the one named for the local host is, under its replaced name" contains "$PH_PAGE" 'MARKER-NAMED'
for bad in '<script>alert' 'onerror' 'onclick' 'javascript:' '<iframe' 'href="alert' 'not-there'; do
  check "pigeonhole: ... and the page has no $bad"             lacks "$PH_PAGE" "$bad"
done
check "pigeonhole: ... nor any commenter's email address"      never_says "$E2E_EXPORT/pigeonhole" 'ada@example.com\|mallory@example.com'
check_site_as_published "$E2E_EXPORT/pigeonhole" "$WORK/pigeonhole-checked"
PH_CHECK=$?
[ "$PH_CHECK" = 0 ] || printf '%s\n' "$CHECK_OUT" | head -8 | sed 's/^/    pigeonhole check: /'
check "pigeonhole: ... and it passes bin/check-site"           equals "$PH_CHECK" 0

# --- comment forms on the exported pages (a site with a pigeonhole) -------------------------------------------------
# WordPress takes the pigeonhole's path and keys when its container is made, so it is made again here with them (the
# compose file turns the two into constants). Then a post that takes comments shows WordPress's own form, pointed at
# the path, with the keys and the loader; reply links stay on the page; and bin/check-site compares all of it with
# what site.json says. Two public keys made for the tests (tests/pigeonhole-browser.test.js has the same).
PG_DAILY=age1ajjp3mu9nznj5y0gk0hye0v75kcqeda3rq9q0az204f2pp6vtpese0l39k
PG_RECOVERY=age1lcn5lw0px559ch6rctd5wj8t27d7vqasc0xd4wl85f48zlth75nsru089h
E2E_PIGEONHOLE_PATH=/_pigeonhole; E2E_PIGEONHOLE_RECIPIENTS="$PG_DAILY $PG_RECOVERY"
dc up -d --wait wordpress >/dev/null 2>&1
for _ in $(seq 1 60); do wp option get home >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,1)'; done
check "comment forms: WordPress, made again, has the pigeonhole's path" equals "$(wp eval 'echo OFFPRINT_PIGEONHOLE_PATH;' 2>/dev/null)" /_pigeonhole
check "comment forms: ... and its keys"                        equals "$(wp eval 'echo OFFPRINT_PIGEONHOLE_RECIPIENTS;' 2>/dev/null)" "$PG_DAILY $PG_RECOVERY"
wp option update thread_comments 1 >/dev/null; wp option update show_avatars 1 >/dev/null; wp option update comment_registration 0 >/dev/null
wp comment approve "$PH_C4" >/dev/null   # the reply to Ada's comment: a thread of two on the page
run_export forms
PG="$E2E_EXPORT/forms"; PG_PAGE="$PG/takes-comments/index.html"; PG_HTML=$(cat "$PG_PAGE" 2>/dev/null)
check "comment forms: the export succeeds"                     equals "$EXPORT_STATUS" 0
[ "$EXPORT_STATUS" = 0 ] || printf '%s\n%s\n' "$EXPORT_OUT" "$EXPORT_ERR" | grep -i error | head -8 | sed 's/^/    comment forms export: /'
PG_BLOCK="<script type=\"application/json\" id=\"offprint-pigeonhole\">{\"path\":\"/_pigeonhole\",\"recipients\":[\"$PG_DAILY\",\"$PG_RECOVERY\"],\"bits\":18}</script>"
PG_FORM=$(grep -o '<form [^>]*data-offprint-pigeonhole[^>]*>' "$PG_PAGE" | head -1)
check "comment forms: a post that takes comments has WordPress's own form, marked ($PG_FORM)" test -n "$PG_FORM"
check "comment forms: ... its address the path"               contains "$PG_FORM" 'action="/_pigeonhole"'
check "comment forms: ... and unable to post by itself: its method is dialog" contains "$PG_FORM" 'method="dialog"'
check "comment forms: ... no form on the page posts"          sh -c "! grep -Eiq \"<form [^>]*method=['\\\"]post\" '$PG_PAGE'"
check "comment forms: ... and there is one such form"         equals "$(grep -o 'data-offprint-pigeonhole' "$PG_PAGE" | wc -l | tr -d ' ')" 1
check "comment forms: ... the block, exactly"                  contains "$PG_HTML" "$PG_BLOCK"
check "comment forms: ... once"                                equals "$(grep -o 'id="offprint-pigeonhole"' "$PG_PAGE" | wc -l | tr -d ' ')" 1
check "comment forms: ... the loader, as a module, from the site's own origin" contains "$PG_HTML" "<script type=\"module\" src=\"$PUBLIC/wp-content/mu-plugins/offprint/pigeonhole-loader.js\"></script>"
check "comment forms: ... the field no person sees"            contains "$PG_HTML" 'name="offprint_hp"'
check "comment forms: ... a line for a reader without scripts" contains "$PG_HTML" 'Without it, this form sends nothing.</p></noscript>'
check "comment forms: ... the post's id and the parent, for the script to read" sh -c "grep -Eq \"name=['\\\"]comment_post_ID['\\\"][^>]*value=['\\\"]$PH_POST['\\\"]\" '$PG_PAGE' && grep -Eq \"name=['\\\"]comment_parent['\\\"]\" '$PG_PAGE'"
check "comment forms: ... and no box to save a name in a cookie" sh -c "! grep -Eq \"name=['\\\"]wp-comment-cookies-consent\" '$PG_PAGE'"
check "comment forms: the loader is exported, the tool's own"  cmp -s "$PG/wp-content/mu-plugins/offprint/pigeonhole-loader.js" "$TOOL/plugin/offprint/pigeonhole-loader.js"
check "comment forms: the script it loads is exported too (the exporter read its name in the loader), the tool's own" cmp -s "$PG/wp-content/mu-plugins/offprint/pigeonhole.js" "$TOOL/plugin/offprint/pigeonhole.js"
PG_REPLIES=$(grep -o '<a [^>]*class="comment-reply-link"[^>]*>' "$PG_PAGE" | wc -l | tr -d ' ')   # (not the link that cancels a reply, whose id ends the same)
PG_APPROVED=$(wp comment list --post_id="$PH_POST" --status=approve --format=count)
check "comment forms: each approved comment has a reply link ($PG_REPLIES for $PG_APPROVED)" equals "$PG_REPLIES" "$PG_APPROVED"
check "comment forms: ... every one to the form on the page"   equals "$(grep -o '<a [^>]*class="comment-reply-link"[^>]*>' "$PG_PAGE" | grep -c 'href="#respond"')" "$PG_APPROVED"
check "comment forms: ... and the link that cancels a reply"    sh -c "grep -q 'id=\"cancel-comment-reply-link\" href=\"#respond\"' '$PG_PAGE'"
check "comment forms: ... naming its comment, for WordPress's reply script" contains "$PG_HTML" "data-commentid=\"$PH_C1\""
check "comment forms: ... which the page loads"                sh -c "grep -q 'comment-reply[^\"]*\\.js' '$PG_PAGE'"
check "comment forms: ... and the export has"                  test -n "$(found_in "$PG" 'comment-reply*.js')"
check "comment forms: no address anywhere asks WordPress to reply" never_says "$PG" 'replytocom'
check "comment forms: nothing names WordPress's own comment address" never_says "$PG" 'wp-comments-post'
# (WordPress's own first comment links to gravatar.com as its author's site: a link is not an avatar)
check "comment forms: control: exported with no pigeonhole, the same comments carried avatars" sh -c "grep -rq 'gravatar\\.com/avatar' '$E2E_EXPORT/pigeonhole'"
check "comment forms: no avatar is asked of another site, though the site shows avatars" never_says "$PG" 'gravatar\.com/avatar\|class="avatar'
check "comment forms: a post with comments closed is exported" test -s "$PG/closed/index.html"
check "comment forms: a post with comments closed has no form" lacks "$(cat "$PG/closed/index.html" 2>/dev/null)" '/_pigeonhole'
check "comment forms: ... no block"                            lacks "$(cat "$PG/closed/index.html" 2>/dev/null)" 'offprint-pigeonhole'
check "comment forms: ... and no loader"                       lacks "$(cat "$PG/closed/index.html" 2>/dev/null)" 'pigeonhole-loader'
check "comment forms: the home page has no block"              lacks "$(cat "$PG/index.html" 2>/dev/null)" 'offprint-pigeonhole'
check "comment forms: the exporter says nothing of the comment form" lacks "$EXPORT_OUT" "a form posting to $PUBLIC/_pigeonhole"
check "comment forms: no commenter's email address is in the export" never_says "$PG" 'ada@example.com\|mallory@example.com\|grace@example.com'
CHECK_SITE_PIGEONHOLE_PATH=/_pigeonhole CHECK_SITE_PIGEONHOLE_RECIPIENTS="$PG_DAILY $PG_RECOVERY" check_site_as_published "$PG" "$WORK/forms-checked"
PG_CHECK=$?
[ "$PG_CHECK" = 0 ] || printf '%s\n' "$CHECK_OUT" | head -8 | sed 's/^/    comment forms check: /'
check "comment forms: the export passes bin/check-site, told site.json's path and keys" equals "$PG_CHECK" 0
# site.json changed (the recovery key dropped) and the container not made again: the pages still carry the old keys.
CHECK_SITE_PIGEONHOLE_PATH=/_pigeonhole CHECK_SITE_PIGEONHOLE_RECIPIENTS="$PG_DAILY" check_site_as_published "$PG" "$WORK/forms-stale"
PG_CHECK=$?
check "comment forms: the same export is refused when site.json's keys are others" equals "$PG_CHECK" 1
check "comment forms: ... saying what to do"                   contains "$CHECK_OUT" "takes-comments/index.html: its comment form's settings (the offprint-pigeonhole block) are not right: its keys are not site.json's. WordPress takes these when its container is made: run offprint compose up -d, then publish again."
check_site_as_published "$PG" "$WORK/forms-none"
PG_CHECK=$?
check "comment forms: ... and when site.json has no pigeonhole at all" equals "$PG_CHECK" 1
check "comment forms: ... saying so"                           contains "$CHECK_OUT" 'but site.json has no "pigeonhole" block'
# A site that takes comments from its registered users only: WordPress would show a link to the login page in place
# of the form, which the checks refuse. Nobody is logged in to a static site, so such a site shows no form.
wp option update comment_registration 1 >/dev/null
run_export forms-users
check "comment forms: users only: the export succeeds"         equals "$EXPORT_STATUS" 0
check "comment forms: users only: no form, no block, no link to the login page" sh -c "! grep -rq '/_pigeonhole\|offprint-pigeonhole\|wp-login' '$E2E_EXPORT/forms-users/takes-comments/index.html'"
wp option update comment_registration 0 >/dev/null

# --- the admin bar, for a site that takes comments ---------------------------------------------------------------
# How many comments the Mac has fetched and not opened, when, and how the last check went (from two small files the
# Mac writes in var/: here the test writes them), and the "Check for comments" button, which writes a collect request
# into the inbox and asks for no publish.
CREQ="$E2E_INBOX/collect-request"; FETCHED="$E2E_PUBLISH/pigeonhole-fetch.json"; COLLECTED="$E2E_PUBLISH/pigeonhole.json"
rm -f "$REQ" "$CREQ" "$FETCHED" "$COLLECTED"; fresh
wp user create e2e-author e2e-author@example.com --role=author --user_pass="$ADMIN_PASSWORD" >/dev/null 2>&1
BAR=$(bar)
check "comments in the admin bar: no PHP notices"             lacks "$BAR" "php:"
check "comments in the admin bar: nothing fetched yet: none wait" equals "$(field comments "$BAR" | head -1)" "Comments: none waiting to be checked."
check "comments in the admin bar: ... and it says the agent fetches" contains "$(field comments "$BAR")" "Nothing has been fetched yet. The Mac's agent fetches every five minutes (offprint install-agent)."
check "comments in the admin bar: ... nothing beside the title" equals "$(field count "$BAR")" ""
check "comments in the admin bar: the Check for comments button" equals "$(field collect "$BAR")" "Check for comments"
check "comments in the admin bar: ... posts to admin-post.php, for its own action" contains "$BAR" 'name="action" value="offprint_collect"'
check "comments in the admin bar: ... the Publish Site button is still there" equals "$(field button "$BAR")" "Publish Site"
check "comments in the admin bar: a user who can publish but not moderate sees the node, and nothing about comments" \
  sh -c 'printf "%s" "$1" | grep -q "^button: Publish Site" && ! printf "%s" "$1" | grep -q "omments"' _ "$(publish_php bar --user=e2e-author)"
check "comments in the admin bar: a user who can't publish gets no node" equals "$(publish_php bar --user=e2e-contrib)" "no node"
NOW=$(date +%s)
printf '{"fetched_at":%s,"ok":true,"fetched":3,"damaged":0,"left":0,"waiting":3,"reason":""}\n' "$((NOW - 60))" > "$FETCHED"; chmod a+r "$FETCHED"
BAR=$(bar)
check "comments in the admin bar: three fetched: said under the node" equals "$(field comments "$BAR" | head -1)" "Comments: 3 have arrived on the Mac and wait to be checked."
check "comments in the admin bar: ... and beside the title"    contains "$(field count "$BAR")" "3 comments to check"
check "comments in the admin bar: ... with when they were fetched" contains "$(field comments "$BAR" | sed -n 2p)" "Last fetched at "
printf '{"collected_at":%s,"imported":2,"spam":1,"already":0,"canaries":0,"rejected":0,"damaged":0,"failed":0,"waiting":0}\n' "$((NOW - 10))" > "$COLLECTED"; chmod a+r "$COLLECTED"
BAR=$(bar)
check "comments in the admin bar: after a collection: none wait" equals "$(field comments "$BAR" | head -1)" "Comments: none waiting to be checked."
check "comments in the admin bar: ... and how it went"         contains "$(field comments "$BAR" | sed -n 3p)" ": 2 are in the moderation queue; 1 went to spam."
printf '{"fetched_at":%s,"ok":false,"fetched":0,"damaged":0,"left":0,"waiting":"<img src=x onerror=alert(1)>","reason":"<script>alert(1)</script>"}\n' "$NOW" > "$FETCHED"
BAR=$(bar)
check "comments in the admin bar: a fetch file with markup in it is not believed" contains "$(field comments "$BAR")" "couldn't be read; the next fetch writes it again."
check "comments in the admin bar: ... and none of it reaches the page" sh -c '! printf "%s" "$1" | grep -q "<img\|<script>alert\|onerror"' _ "$BAR"
printf '{"fetched_at":%s,"ok":false,"fetched":0,"damaged":0,"left":0,"waiting":1,"reason":"unreachable"}\n' "$NOW" > "$FETCHED"
BAR=$(bar)
check "comments in the admin bar: a fetch that failed says why, and what to run" contains "$(field comments "$BAR")" "failed: the pigeonhole's server couldn't be reached. On the Mac: offprint pigeonhole doctor."
# The button, through the web.
ADMIN_AUTH=$(publish_php auth e2e-admin); ADMIN_COOKIE=$(echo "$ADMIN_AUTH" | sed -n 1p); ADMIN_STATUS=$(echo "$ADMIN_AUTH" | sed -n 3p); ADMIN_COLLECT=$(echo "$ADMIN_AUTH" | sed -n 5p)
AUTHOR_AUTH=$(publish_php auth e2e-author); AUTHOR_COOKIE=$(echo "$AUTHOR_AUTH" | sed -n 1p); AUTHOR_COLLECT=$(echo "$AUTHOR_AUTH" | sed -n 5p)
check "Check for comments: refuses a wrong nonce" \
  equals "$(fetch_with "" "$POST" -H "$ADMIN_COOKIE" --data "action=offprint_collect&offprint_nonce=wrong" -o /dev/null -w '%{http_code}')" 403
check "Check for comments: ... which asks nothing"             test ! -e "$CREQ"
check "Check for comments: refuses the Publish Site button's nonce" \
  equals "$(fetch_with "" "$POST" -H "$ADMIN_COOKIE" --data "action=offprint_collect&offprint_nonce=$ADMIN_ASK" -o /dev/null -w '%{http_code}')" 403
check "Check for comments: refuses a user who may not moderate comments" \
  equals "$(fetch_with "" "$POST" -H "$AUTHOR_COOKIE" --data "action=offprint_collect&offprint_nonce=$AUTHOR_COLLECT" -o /dev/null -w '%{http_code}')" 403
check "Check for comments: ... which asks nothing either"      test ! -e "$CREQ"
check "Check for comments: refuses a logged-out request"       test "$(fetch_with "" "$POST" --data "action=offprint_collect&offprint_nonce=$ADMIN_COLLECT" -o /dev/null -w '%{http_code}')" != 302
check "Check for comments: ... which asks nothing either"      test ! -e "$CREQ"
check "Check for comments: asks, then goes back to the page it was on" \
  equals "$(fetch_with "" "$POST" -H "$ADMIN_COOKIE" -H "Referer: https://$LOCAL/wp-admin/edit-comments.php" \
    --data "action=offprint_collect&offprint_nonce=$ADMIN_COLLECT" -o /dev/null -w '%{http_code} %{redirect_url}')" "302 https://$LOCAL/wp-admin/edit-comments.php"
check "Check for comments: the request is one line: a time, and that the button asked" sh -c "grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z button' '$CREQ'"
check "Check for comments: nothing else is left in the inbox"  equals "$(ls -A "$E2E_INBOX")" "collect-request"
check "Check for comments: it asks for no publish"             not_asked
BAR=$(bar)
check "comments in the admin bar: while the request waits: checking" equals "$(field comments "$BAR" | head -1)" "Comments: checking…"
JSON=$(fetch_with "" "$AJAX&nonce=$ADMIN_STATUS" -H "$ADMIN_COOKIE")
check "status action: has the comments part, as text"         equals "$(php -r '$j = json_decode( stream_get_contents( STDIN ), true ); echo $j["data"]["comments"]["lines"][0] ?? "", "|", var_export( $j["data"]["comments"]["pending"] ?? null, true ), "|", var_export( $j["data"]["poll"] ?? null, true );' <<<"$JSON")" "Comments: checking…|true|true"
check "status action: a user who may not moderate gets no comments part" \
  equals "$(fetch_with "" "$AJAX&nonce=$(echo "$AUTHOR_AUTH" | sed -n 3p)" -H "$AUTHOR_COOKIE" | php -r '$j = json_decode( stream_get_contents( STDIN ), true ); echo isset( $j["data"]["title"] ) && ! isset( $j["data"]["comments"] ) ? "none" : "some";')" none
check "export mode with a cookie: nothing about comments, and no button" lacks "$(fetch / -H "$ADMIN_COOKIE")" "offprint_collect"
rm -f "$CREQ" "$FETCHED" "$COLLECTED"

# --- summary ------------------------------------------------------------------------------------
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
