<?php
// Called by bin/check-site:  php bin/check-site-pigeonhole.php DIR TOOL_SCRIPTS
// The checks of comment forms (a site's pigeonhole) in an export. Prints one line per failure, sorted; nothing when all
// is right. Exits 2, having read nothing, when its settings are malformed.
//
// What a page with a comment form carries is printed by WordPress, which is untrusted, from two values it took when
// its container was made. So what is published is compared here, on the Mac, with site.json's own:
//   CHECK_SITE_PIGEONHOLE_PATH        site.json's pigeonhole.path, or empty for a site with no pigeonhole
//   CHECK_SITE_PIGEONHOLE_RECIPIENTS  its recipients, one or two age public keys with a space between, or empty
//   CHECK_SITE_HOST                   the site's public host (a form's address may be written with it)
// TOOL_SCRIPTS is the tool's own plugin/offprint folder, which holds the two scripts a page loads.
//
//   1. An element with the id offprint-pigeonhole (the block the scripts read: where a comment is posted, and to whose
//      keys it is encrypted) must be a JSON script holding exactly site.json's path and keys and the tool's own proof
//      of work, once a page. With other keys, a comment could be read by whoever holds them and not by the owner;
//      with another path, it goes nowhere. This is also what catches a container made before site.json changed.
//      On a site with no pigeonhole, no page may carry one.
//   2. The comment form itself (marked data-offprint-pigeonhole, and holding the field offprint_hp) never posts by
//      itself: its method is "dialog", which a browser does nothing with outside a dialog, so a visitor whose browser
//      did not run the script sends nothing, least of all their name, address and words in the clear. It must be
//      exactly so, once a page, on a page with the right block; and on a site with no pigeonhole, no page may have one.
//   3. Nothing else may send to the pigeonhole's path: no other form whose address is the path (however it is
//      written), and no button that sends a form there. Such a form would post what a visitor typed, readable.
//   4. The two scripts, where the export has them (wp-content/mu-plugins/offprint/pigeonhole.js and
//      pigeonhole-loader.js), must be byte for byte the tool's own: they are served from the plugin copy WordPress
//      can write. A page with the block needs both.
//
// What this does not do: a plugin that can put a script of its own on a page can read what a visitor types there
// whatever the block says, and one that can write markup no filter has seen can hide an element from one HTML parser
// and show it to another. That is the trust already placed in the owner's WordPress, and no check of the block
// changes it. What a post's author can write (WordPress filters it) is read here as a browser reads it. A page that
// isn't UTF-8 (which no parser here reads as a browser would) is refused by bin/check-site-addresses.php.

ini_set( 'memory_limit', '512M' );
const BLOCK_ID = 'offprint-pigeonhole';
const BITS = 18;   // plugin/offprint/src/Pigeonhole.php holds the same number
const FORM_MARK = 'data-offprint-pigeonhole';   // and these two names
const HIDDEN_FIELD = 'offprint_hp';
const SCRIPTS = array( 'pigeonhole.js', 'pigeonhole-loader.js' );
const SCRIPTS_AT = 'wp-content/mu-plugins/offprint';
const MAX_MARKUP_BYTES = 32 * 1024 * 1024;
const REMAKE = 'WordPress takes these when its container is made: run offprint compose up -d, then publish again.';

if ( $argc !== 3 || ! is_dir( $argv[1] ) || ! is_dir( $argv[2] ) ) { fwrite( STDERR, "usage: check-site-pigeonhole.php DIR TOOL_SCRIPTS\n" ); exit( 2 ); }
$root = rtrim( $argv[1], '/' );
$tool = rtrim( $argv[2], '/' );

$path = (string) getenv( 'CHECK_SITE_PIGEONHOLE_PATH' );
$keys = (string) getenv( 'CHECK_SITE_PIGEONHOLE_RECIPIENTS' );
$host = strtolower( rtrim( (string) getenv( 'CHECK_SITE_HOST' ), '.' ) );
$on   = '' !== $path || '' !== $keys;
if ( $on && ( 1 !== preg_match( '/\A\/[a-z0-9_-]{1,40}\z/D', $path ) || 1 !== preg_match( '/\Aage1[ac-hj-np-z02-9]{58}( age1[ac-hj-np-z02-9]{58})?\z/D', $keys ) ) ) {
	fwrite( STDERR, "CHECK_SITE_PIGEONHOLE_PATH and CHECK_SITE_PIGEONHOLE_RECIPIENTS must be site.json's pigeonhole path and its one or two age public keys (or both empty)\n" );
	exit( 2 );
}
if ( 1 !== preg_match( '/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/D', $host ) ) {
	fwrite( STDERR, "CHECK_SITE_HOST must be set to the site's public host\n" );
	exit( 2 );
}
$want = $on ? array( 'path' => $path, 'recipients' => explode( ' ', $keys ), 'bits' => BITS ) : null;

// What is wrong with a block element, or '' when it is exactly what site.json and the tool say.
function block_problem( DOMElement $el, array $want ) {
	if ( 'script' !== strtolower( $el->nodeName ) || 'application/json' !== strtolower( trim( $el->getAttribute( 'type' ) ) ) ) {
		return 'it is not a JSON script element';
	}
	$text = $el->textContent;
	if ( strlen( $text ) > 4096 ) { return 'it is too long to be one'; }
	try {
		$got = json_decode( $text, true, 4, JSON_THROW_ON_ERROR );
		$raw = json_decode( $text, false, 4, JSON_THROW_ON_ERROR );
	} catch ( JsonException $e ) {
		return 'it is not JSON';
	}
	if ( ! is_array( $got ) || ! is_object( $raw ) ) { return 'it is not a JSON object'; }
	// The keys as written, twice-named ones too: PHP keeps the last of two, a browser's parser may differ.
	if ( preg_match_all( '/"(path|recipients|bits)"\s*:/', $text ) !== 3 || array_keys( $got ) !== array( 'path', 'recipients', 'bits' ) ) {
		return 'it does not hold exactly a path, the recipients and the proof of work';
	}
	if ( $got['path'] !== $want['path'] ) { return 'its path is not site.json\'s'; }
	if ( ! is_array( $raw->recipients ) || $got['recipients'] !== $want['recipients'] ) { return 'its keys are not site.json\'s'; }
	if ( $got['bits'] !== $want['bits'] ) { return 'its proof of work is not this Offprint\'s'; }
	return '';
}

// The path an address leads to on this site, as a web server would read it: resolved from the folder the address is
// written in ($dir, ending in a slash) or from the page's <base> ($base: array( host or null, dir ), or null), its dot
// segments worked out, percent-encodings decoded, anything after a ; ? or # dropped, lowercase, no slash at its end.
// Null when the address is on another host, or is no http(s) address at all. Read widely on purpose: anything that
// could be this site's path, however it is written, is.
function site_path( $address, $dir, $base, $host ) {
	$a = str_replace( '\\', '/', (string) preg_replace( '/[\x00-\x20\x7f]+/', '', (string) $address ) );
	if ( preg_match( '#\A([a-z][a-z0-9+.-]*):#i', $a, $m ) ) {
		if ( ! in_array( strtolower( $m[1] ), array( 'http', 'https' ), true ) ) { return null; }
		$a = substr( $a, strlen( $m[0] ) );
	}
	if ( null !== $base ) {
		if ( null !== $base[0] && $base[0] !== $host ) { $on_host = false; } else { $on_host = true; }
		$dir = $base[1];
	} else {
		$on_host = true;
	}
	if ( 0 === strpos( $a, '//' ) ) {
		$rest      = ltrim( $a, '/' );
		$end       = strcspn( $rest, '/?#' );
		$authority = strtolower( substr( $rest, 0, $end ) );
		$a         = substr( $rest, $end );
		$at        = strrpos( $authority, '@' );
		if ( false !== $at ) { $authority = substr( $authority, $at + 1 ); }
		$authority = rtrim( (string) preg_replace( '/:[0-9]*\z/', '', $authority ), '.' );
		$on_host   = $authority === $host;
		if ( '' === $a || '/' !== $a[0] ) { $a = '/' . $a; }
	}
	if ( ! $on_host ) { return null; }
	$a = (string) preg_replace( '/[?\#].*\z/s', '', $a );
	if ( '' === $a ) { return null; }   // the page itself, never the path (which is no page)
	if ( '/' !== $a[0] ) { $a = $dir . $a; }
	$out = array();
	foreach ( explode( '/', $a ) as $segment ) {
		$segment = rawurldecode( $segment );
		$segment = (string) preg_replace( '/;.*\z/s', '', $segment );
		if ( '..' === $segment ) { array_pop( $out ); }
		elseif ( '' !== $segment && '.' !== $segment ) { $out[] = $segment; }
	}
	return '/' . strtolower( implode( '/', $out ) );
}

function is_page( $file, $ext ) {
	if ( in_array( $ext, array( 'html', 'htm', 'xhtml', 'svg', 'xml' ), true ) ) { return true; }
	if ( '' !== $ext ) { return false; }
	$head = ltrim( (string) file_get_contents( $file, false, null, 0, 512 ), "\xEF\xBB\xBF \t\r\n" );
	return 1 === preg_match( '/^<(\?xml|!doctype|html|head|body|svg)\b/i', $head );
}

$found = array();
$with_block = array();
$it = new RecursiveIteratorIterator( new RecursiveDirectoryIterator( $root, FilesystemIterator::SKIP_DOTS ) );
foreach ( $it as $file ) {
	if ( $file->isLink() || ! $file->isFile() || ! is_page( $file->getPathname(), strtolower( $file->getExtension() ) ) ) { continue; }
	$rel = substr( $file->getPathname(), strlen( $root ) + 1 );
	if ( $file->getSize() > MAX_MARKUP_BYTES ) { continue; }   // (bin/check-site-addresses.php refuses it)
	$html = file_get_contents( $file->getPathname() );
	if ( false === $html ) { $found[ "$rel: could not be read" ] = true; continue; }
	// Nothing to look at in a page with no tag that could be a block, a form or a button, and no entity that could
	// spell one. (A page in another encoding than UTF-8, where these bytes would not show, is refused elsewhere.)
	if ( false === stripos( $html, 'pigeonhole' ) && false === stripos( $html, 'form' ) && false === strpos( $html, '&' ) ) { continue; }
	$doc = new DOMDocument();
	libxml_use_internal_errors( true );
	$doc->loadHTML( '<?xml encoding="utf-8"?>' . $html, LIBXML_NONET | LIBXML_PARSEHUGE );
	libxml_clear_errors();   // (a page the parser could not read to its end is reported by bin/check-site-addresses.php)

	$d    = dirname( $rel );
	$dir  = '.' === $d ? '/' : '/' . $d . '/';
	$base = null;
	foreach ( $doc->getElementsByTagName( 'base' ) as $b ) {   // the first <base href> decides how a relative address resolves
		if ( ! $b->hasAttribute( 'href' ) ) { continue; }
		$href = str_replace( '\\', '/', (string) preg_replace( '/[\x00-\x20\x7f]+/', '', $b->getAttribute( 'href' ) ) );
		$bhost = null;
		if ( preg_match( '#\A(?:[a-z][a-z0-9+.-]*:)?//+([^/?\#]*)#i', $href, $m ) ) {
			$bhost = rtrim( (string) preg_replace( '/:[0-9]*\z/', '', strtolower( (string) preg_replace( '/\A.*@/', '', $m[1] ) ) ), '.' );
		}
		$bpath = site_path( $href, $dir, null, null === $bhost ? $host : $bhost );
		$bpath = null === $bpath ? '/' : $bpath;
		$base  = array( $bhost, '/' === substr( (string) preg_replace( '/[?\#].*\z/s', '', $href ), -1 ) ? rtrim( $bpath, '/' ) . '/' : rtrim( dirname( $bpath ), '/' ) . '/' );
		break;
	}

	$blocks = array(); $forms = array(); $senders = array();
	foreach ( $doc->getElementsByTagName( '*' ) as $el ) {
		if ( $el->hasAttribute( 'id' ) && BLOCK_ID === $el->getAttribute( 'id' ) ) { $blocks[] = $el; }
		$name = strtolower( $el->nodeName );
		if ( $el->hasAttribute( FORM_MARK ) || ( $el->hasAttribute( 'name' ) && HIDDEN_FIELD === $el->getAttribute( 'name' ) ) ) {
			// the tool's own comment form: the element marked, or the form that holds its hidden field
			$form = $el;
			while ( $form && 'form' !== strtolower( $form->nodeName ) ) { $form = $form->parentNode instanceof DOMElement ? $form->parentNode : null; }
			$forms[ spl_object_id( $form ? $form : $el ) ] = $form ? $form : $el;
		}
		if ( null !== $want ) {
			// anything that could send to the path: a form by its address, a button by the address it gives its form
			if ( 'form' === $name && $el->hasAttribute( 'action' ) && site_path( $el->getAttribute( 'action' ), $dir, $base, $host ) === $want['path'] ) { $senders[ spl_object_id( $el ) ] = $el; }
			if ( $el->hasAttribute( 'formaction' ) && site_path( $el->getAttribute( 'formaction' ), $dir, $base, $host ) === $want['path'] ) { $senders[ spl_object_id( $el ) ] = $el; }
		}
	}

	$good = false;
	if ( $blocks ) {
		if ( null === $want ) {
			$found[ "$rel: carries a comment form's settings (the " . BLOCK_ID . ' block), but site.json has no "pigeonhole" block. ' . REMAKE ] = true;
		} elseif ( count( $blocks ) > 1 ) {
			$found[ "$rel: carries a comment form's settings (the " . BLOCK_ID . ' block) more than once; a page has one.' ] = true;
		} else {
			$why = block_problem( $blocks[0], $want );
			if ( '' === $why ) { $good = true; $with_block[] = $rel; }
			else { $found[ "$rel: its comment form's settings (the " . BLOCK_ID . " block) are not right: $why. " . REMAKE ] = true; }
		}
	}

	// The tool's own form: only on a page with the right block, once, and unable to post by itself.
	$own = null;
	if ( $forms ) {
		if ( null === $want ) {
			$found[ "$rel: has a pigeonhole's comment form, but site.json has no \"pigeonhole\" block. " . REMAKE ] = true;
		} elseif ( ! $blocks ) {
			$found[ "$rel: has a pigeonhole's comment form, but not the block that says whose keys a comment is encrypted to; a comment sent from it would go nowhere." ] = true;
		} elseif ( count( $forms ) > 1 ) {
			$found[ "$rel: has a pigeonhole's comment form more than once; a page has one." ] = true;
		} else {
			$own = reset( $forms );
			$bad = '';
			if ( 'form' !== strtolower( $own->nodeName ) ) { $bad = 'its mark or its hidden field is not in a form'; }
			elseif ( ! $own->hasAttribute( FORM_MARK ) ) { $bad = 'it is not marked as one'; }
			elseif ( 'dialog' !== strtolower( trim( $own->getAttribute( 'method' ) ) ) ) { $bad = 'it could post what a visitor typed, readable, should the script not run (its method is not "dialog")'; }
			elseif ( $own->getAttribute( 'action' ) !== $want['path'] ) { $bad = 'its address is not the pigeonhole\'s path'; }
			else {
				foreach ( $own->getElementsByTagName( '*' ) as $inner ) {
					if ( $inner->hasAttribute( 'formmethod' ) || $inner->hasAttribute( 'formaction' ) ) { $bad = 'a button in it sends it another way'; break; }
				}
			}
			if ( '' !== $bad ) { $found[ "$rel: its comment form is not as this Offprint prints it: $bad." ] = true; }
		}
	}
	// And nothing else sends to the path.
	foreach ( $senders as $id => $el ) {
		if ( null !== $own && spl_object_id( $own ) === $id ) { continue; }
		$found[ "$rel: has a form or a button that sends to {$want['path']}, the pigeonhole's path, and is not the comment form this Offprint prints; it would post what a visitor typed, readable." ] = true;
		break;
	}
}

// The two scripts: the tool's own, where the export has them; and there, for a page that carries the block.
foreach ( SCRIPTS as $name ) {
	$rel  = SCRIPTS_AT . '/' . $name;
	$mine = "$tool/$name";
	$its  = "$root/$rel";
	if ( ! is_file( $mine ) || is_link( $mine ) ) { $found[ "the comment-form check could not run: this Offprint has no plugin/offprint/$name" ] = true; continue; }
	if ( ! file_exists( $its ) && ! is_link( $its ) ) {
		if ( $with_block ) { $found[ "{$with_block[0]}: carries a comment form's settings, but the export has no $rel, the script that sends a comment." ] = true; }
		continue;
	}
	if ( is_link( $its ) || ! is_file( $its ) || filesize( $its ) !== filesize( $mine ) || ! hash_equals( (string) hash_file( 'sha256', $mine ), (string) hash_file( 'sha256', $its ) ) ) {
		$found[ "$rel: is not this Offprint's own script (plugin/offprint/$name), byte for byte: the copy WordPress serves was changed, or the site's plugin copy is another Offprint's (offprint setup-wp says how to replace it)." ] = true;
	}
}

$lines = array();
foreach ( array_keys( $found ) as $line ) { $lines[] = preg_replace( '/[\x00-\x1f\x7f]/', '?', $line ); }
sort( $lines );
foreach ( $lines as $line ) { echo $line, "\n"; }
