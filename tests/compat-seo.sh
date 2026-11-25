#!/usr/bin/env bash
# Whether the export works with a plugin that replaces WordPress's own sitemaps (an SEO plugin, say), on the throwaway
# WordPress tests/e2e.sh uses (compose project "offprint-e2e", made by tests/e2e-setup.sh, which removes everything it
# made on exit, pass or fail). It shares that project, so never run it while tests/e2e.sh runs: each refuses to start
# while the project exists. Unlike e2e.sh it needs the network: the plugin comes from wordpress.org.
#   bash tests/compat-seo.sh PLUGIN_SLUG          (the plugin's slug on wordpress.org: wordpress-seo, say)
# It makes a few posts, two pages (one that nothing links to), a category and a tag; installs and activates the
# plugin; exports; and checks the export, one ok or FAIL line each. Its last line is the README's table row:
#   SLUG VERSION: N ok, M FAIL
# It exits 0 only when M is 0.
set -uo pipefail
cd "$(dirname "$0")/.."

SLUG=${1:-}
# A wordpress.org slug: lowercase letters and digits, in groups joined by dashes. Checked before it reaches WP-CLI.
slug_re='^[a-z0-9]+(-[a-z0-9]+)*$'
if [ "$#" -ne 1 ] || ! [[ $SLUG =~ $slug_re ]]; then
  echo "usage: bash tests/compat-seo.sh PLUGIN_SLUG   (a wordpress.org slug: lowercase letters, digits and dashes)" >&2
  exit 2
fi

# The fixture's names, the throwaway project, its folders in $WORK, and dc, wp, check and the export helpers.
. tests/e2e-setup.sh
e2e_start
e2e_install

# --- the site ---------------------------------------------------------------------------------------
# WordPress's Sample Page links to the dashboard, which the checks refuse (setup-wp deletes it too).
wp post delete "$(wp post list --post_type=page --name=sample-page --field=ID)" --force >/dev/null
wp term create category Notes --slug=notes >/dev/null
wp term create post_tag Ideas --slug=ideas >/dev/null
for n in 1 2 3; do
  id=$(wp post create --post_title="Post $n" --post_status=publish --post_author=1 --porcelain \
    --post_content="<!-- wp:paragraph --><p>Post number $n.</p><!-- /wp:paragraph -->")
  wp post term set "$id" category notes >/dev/null
  wp post term set "$id" post_tag ideas >/dev/null
done
wp post create --post_type=page --post_title=About --post_name=about --post_status=publish --post_author=1 \
  --post_content='<!-- wp:paragraph --><p>About this site.</p><!-- /wp:paragraph -->' >/dev/null
wp post create --post_type=page --post_title=Unlinked --post_name=unlinked --post_status=publish --post_author=1 \
  --post_content='<!-- wp:paragraph --><p>Nothing links here: only a sitemap can bring it in.</p><!-- /wp:paragraph -->' >/dev/null
# A block theme's navigation lists every page unless there is a menu: this one links home and About, and nothing else.
wp post create --user=e2e-admin --post_type=wp_navigation --post_title=Main --post_status=publish \
  --post_content='<!-- wp:navigation-link {"label":"Home","url":"/","kind":"custom"} /--><!-- wp:navigation-link {"label":"About","url":"/about/","kind":"custom"} /-->' >/dev/null

# --- the plugin -------------------------------------------------------------------------------------
if ! installed=$(wp plugin install "$SLUG" --activate 2>&1) || [ "$(wp plugin get "$SLUG" --field=status 2>/dev/null)" != active ]; then
  echo "FAIL - $SLUG could not be installed and activated (can the container reach wordpress.org?)"
  printf '%s\n' "$installed" | sed 's/^/    /'
  echo "$SLUG (not installed): 0 ok, 1 FAIL"
  exit 1
fi
VERSION=$(wp plugin get "$SLUG" --field=version)
echo "# $SLUG $VERSION"

# --- the export -------------------------------------------------------------------------------------
run_export compat
OUT="$E2E_EXPORT/compat"
printf '%s\n' "$EXPORT_OUT" | sed 's/^/    /'
[ -z "$EXPORT_ERR" ] || printf '%s\n' "$EXPORT_ERR" | sed 's/^/    stderr: /'
[ ! -d "$OUT" ] || echo "    sitemap files: $(cd "$OUT" && find . \( -name '*.xml' -o -name '*.xsl' \) ! -path './feed/*' | sed 's#^\./##' | LC_ALL=C sort | paste -sd' ' -)"

# has_file PATH: the export has the file a public address's PATH is saved as: the file itself, or, for a folder (a
# trailing slash, or no extension on the last segment), its index.html or index.xml. As tests/e2e-links.php does.
has_file() {
  local path=$1 last
  last=${path%/}; last=${last##*/}
  case $path in
    */) ;;
    *.*) case $last in *.*) [ -f "$OUT$path" ]; return ;; esac ;;
  esac
  [ -f "$OUT${path%/}/index.html" ] || [ -f "$OUT${path%/}/index.xml" ]
}
# all_there COUNT MISSING: COUNT addresses were looked for, and none is missing.
all_there() { [ "$1" -gt 0 ] && [ -z "$2" ]; }

# 1. Errors fail an export, and a publish with it.
check "the export ended without errors" equals "$EXPORT_STATUS" 0

# 2. Read here with sed, not the exporter's own reader, so a gap in that shows up.
SITEMAPS=$( [ -f "$OUT/robots.txt" ] && tr -d '\r' <"$OUT/robots.txt" |
  sed -n 's/^[[:space:]]*[Ss][Ii][Tt][Ee][Mm][Aa][Pp][[:space:]]*:[[:space:]]*//p' | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')
ON_SITE=0; MISSING=""
while IFS= read -r address; do
  case $address in "$PUBLIC"/*) ;; *) continue ;; esac
  ON_SITE=$((ON_SITE + 1))
  has_file "${address#"$PUBLIC"}" || MISSING="$MISSING $address"
done <<EOF
$SITEMAPS
EOF
[ -z "$MISSING" ] || echo "    not in the export:$MISSING"
check "every Sitemap: address in the exported robots.txt that is on the site is a file in the export ($ON_SITE of them)" \
  all_there "$ON_SITE" "$MISSING"

# 3. Asked of WordPress, not of any sitemap: each published post and page, and the archive of each category and tag
# with a post and each author with a post.
EXPECTED=$(wp eval '
  foreach ( get_posts( array( "post_type" => array( "post", "page" ), "post_status" => "publish", "numberposts" => -1 ) ) as $p ) { echo get_permalink( $p ), "\n"; }
  foreach ( get_terms( array( "taxonomy" => array( "category", "post_tag" ), "hide_empty" => true ) ) as $t ) { echo get_term_link( $t ), "\n"; }
  foreach ( get_users( array( "has_published_posts" => array( "post" ) ) ) as $u ) { echo get_author_posts_url( $u->ID ), "\n"; }')
ASKED=0; MISSING=""
while IFS= read -r url; do
  case $url in
    "https://$LOCAL"/*) ASKED=$((ASKED + 1)); has_file "${url#"https://$LOCAL"}" || MISSING="$MISSING $url" ;;
    http://* | https://*) ASKED=$((ASKED + 1)); MISSING="$MISSING $url" ;;
    ?*) echo "    wp eval said: $url" ;;
  esac
done <<EOF
$EXPECTED
EOF
[ -z "$MISSING" ] || echo "    not in the export:$MISSING"
check "every published post, page, category, tag and author archive WordPress has is in the export ($ASKED of them)" \
  all_there "$ASKED" "$MISSING"
# The unlinked page above proves the sitemap's part only if no page links to it.
LINKERS=$( [ -d "$OUT" ] && grep -rlF --include='*.html' '/unlinked/' "$OUT" | grep -vxF "$OUT/unlinked/index.html")
[ -z "$LINKERS" ] || printf '%s\n' "$LINKERS" | sed "s#^$OUT/#    links to the unlinked page: #"
check "control: the unlinked page is in the export, and no other page links to it" \
  all_there "$([ -f "$OUT/unlinked/index.html" ] && echo 1 || echo 0)" "$LINKERS"

# 4.
check "no file in the export holds $LOCAL" never_says "$OUT" "$LOCAL_RE"

# 5. As a publish runs it, and as tests/e2e.sh does: cloudflare-workers' names and limits.
if [ -d "$OUT" ]; then check_site_as_published "$OUT" "$WORK/compat-check"; CHECKED=$?; else CHECKED=1; CHECK_OUT="no export"; fi
[ "$CHECKED" = 0 ] || printf '%s\n' "$CHECK_OUT" | head -20 | sed 's/^/    check-site: /'
check "bin/check-site passes on the export" equals "$CHECKED" 0

echo "$SLUG $VERSION: $PASSED ok, $FAILED FAIL"
[ "$FAILED" -eq 0 ]
