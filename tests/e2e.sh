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

# --- summary ------------------------------------------------------------------------------------
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
