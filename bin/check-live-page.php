<?php
// Called by bin/publish (check_live_comments):  php bin/check-live-page.php PUBLISHED LIVE
// Whether a page with a comment form, as the live site serves it (LIVE), runs the scripts the page that was published
// runs (PUBLISHED), and no others. A comment is typed into the page before it is encrypted: one script added on the
// way to a visitor, by the host or by anything in front of it, reads every comment as it is written, whatever keys
// the page names. So the script elements of the two are compared, in order: where each is loaded from (its src and
// type, as written) and, for one written into the page, its text (by its hash). Prints one line when they differ,
// and nothing when they are the same; that line holds counts and a position, never a byte of the live page.
// Exits 2 on a usage mistake or a page it can't read.
//
// What this does not see, and nothing here claims to: a script file changed on the host under the same address (but
// for the two of the comment form's own, which bin/publish compares byte for byte), script in an attribute (onclick,
// a javascript: address), or a change made for some visitors and not for this request.

ini_set( 'display_errors', 'stderr' );
ini_set( 'memory_limit', '512M' );
const MAX_BYTES = 32 * 1024 * 1024;

if ( $argc !== 3 ) { fwrite( STDERR, "usage: check-live-page.php PUBLISHED LIVE\n" ); exit( 2 ); }

// The page's script elements, in order, each as "src|type|sha256 of its text".
function scripts( $file ) {
	if ( is_link( $file ) || ! is_file( $file ) || filesize( $file ) > MAX_BYTES ) { return null; }
	$html = file_get_contents( $file );
	if ( false === $html ) { return null; }
	$doc = new DOMDocument();
	$was = libxml_use_internal_errors( true );
	// (the pages are UTF-8: bin/check-site-addresses.php refuses an export's page that isn't)
	$ok = '' === $html ? true : $doc->loadHTML( '<?xml encoding="utf-8"?>' . $html, LIBXML_NONET | LIBXML_PARSEHUGE | LIBXML_NOERROR | LIBXML_NOWARNING );
	libxml_clear_errors();
	libxml_use_internal_errors( $was );
	if ( ! $ok ) { return null; }
	$found = array();
	foreach ( $doc->getElementsByTagName( 'script' ) as $el ) {
		$found[] = $el->getAttribute( 'src' ) . '|' . strtolower( trim( $el->getAttribute( 'type' ) ) ) . '|' . hash( 'sha256', $el->textContent );
	}
	return $found;
}

$published = scripts( $argv[1] );
$live      = scripts( $argv[2] );
if ( null === $published || null === $live ) { fwrite( STDERR, "a page could not be read\n" ); exit( 2 ); }
if ( $published === $live ) { exit( 0 ); }
$n = min( count( $published ), count( $live ) );
for ( $i = 0; $i < $n && $published[ $i ] === $live[ $i ]; $i++ ) { }
printf( "the page runs %d scripts as the live site serves it, and %d as it was published; the first that differs is number %d\n", count( $live ), count( $published ), $i + 1 );
exit( 1 );
