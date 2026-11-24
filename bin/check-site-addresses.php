<?php
// Called by bin/check-site:  php bin/check-site-addresses.php DIR
// Prints "<relative file>: <address> points at <what>" for every same-site address in the exported markup, CSS and
// feed files that leads to WordPress's admin, login, XML-RPC or REST API. Feeds and sitemaps are read with the XML
// parser, and the HTML of a post inside a feed (an RSS <description> or <content:encoded>, an Atom <content> or
// <summary>) is checked as markup. An address is same-site when it is relative,
// protocol-relative, or has the site's public host (CHECK_SITE_HOST) or its local host (CHECK_SITE_LOCAL_HOST) as its
// host; links to other sites are allowed. Text, <code>/<pre> and .js files are not checked.
// Both hosts come from the environment only (bin/check-site needs them; bin/publish and offprint check set them from
// site.json), and each must look like a hostname, or this exits 2 having read nothing.
// A file the HTML or XML parser could not read completely is itself reported (fail closed).

// A finite limit: anything that blows up (a file built to) fails this check instead of exhausting the Mac.
ini_set( 'memory_limit', '512M' );
if ( $argc < 2 || ! is_dir( $argv[1] ) ) { fwrite( STDERR, "usage: check-site-addresses.php DIR\n" ); exit( 2 ); }
$root = rtrim( $argv[1], '/' );

// Lowercase, no trailing dot; ideographic and fullwidth forms mapped to plain ASCII (browsers do the same).
function norm_host( $h ) {
	$h = (string) $h;
	if ( preg_match( '//u', $h ) ) {
		$h = str_replace( array( "\u{3002}", "\u{FF0E}", "\u{FF61}" ), '.', $h );
		$h = preg_replace_callback( '/[\x{FF01}-\x{FF5E}]/u', function ( $m ) {
			return chr( 0x21 + ( mb_ord_compat( $m[0] ) - 0xFF01 ) );
		}, $h );
	}
	return rtrim( strtolower( trim( $h ) ), '.' );
}
function mb_ord_compat( $ch ) { $u = unpack( 'N', mb_convert_encoding( $ch, 'UCS-4BE', 'UTF-8' ) ); return $u[1]; }

// The host in the environment variable $name, normalised, if it looks like a hostname; otherwise exits 2.
function env_host( $name ) {
	$h = getenv( $name );
	$h = false === $h ? '' : norm_host( $h );
	if ( '' === $h || strlen( $h ) > 253 || 1 !== preg_match( '/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/D', $h ) ) {
		fwrite( STDERR, "$name must be set to a hostname (CHECK_SITE_HOST: the public host, CHECK_SITE_LOCAL_HOST: the local one)\n" );
		exit( 2 );
	}
	return $h;
}
$HOSTS = array( env_host( 'CHECK_SITE_HOST' ), env_host( 'CHECK_SITE_LOCAL_HOST' ) );

// Split an address into array( host or null, resolved lowercase path, decoded query ), or null when it is not an
// http(s) address. $dir is the folder the address is resolved from (URL path ending in /), $baseHost the host of <base>.
function parse_address( $a, $dir, $baseHost ) {
	$a = str_replace( '\\', '/', preg_replace( '/[\x00-\x20\x7f]+/', '', (string) $a ) );
	if ( '' === $a ) { return null; }
	if ( preg_match( '#^([a-z][a-z0-9+.-]*):#i', $a, $m ) ) {
		if ( ! in_array( strtolower( $m[1] ), array( 'http', 'https' ), true ) ) { return null; }
		$a = substr( $a, strlen( $m[0] ) );
	}
	$host = $baseHost;
	$auth = false;
	if ( 0 === strpos( $a, '//' ) ) {
		$rest = ltrim( $a, '/' );   // a browser skips every slash before the host, not just two
		$end  = strcspn( $rest, '/?#' );
		$auth = substr( $rest, 0, $end );
		$a    = substr( $rest, $end );
		$at   = strrpos( $auth, '@' );
		if ( false !== $at ) { $auth = substr( $auth, $at + 1 ); }
		if ( '[' === substr( $auth, 0, 1 ) ) { $host = substr( $auth, 0, strpos( $auth, ']' ) ?: strlen( $auth ) ); }
		else { $host = substr( $auth, 0, strcspn( $auth, ':' ) ); }
		$host = norm_host( rawurldecode( $host ) );
		if ( '' === $host ) { $host = null; }   // no host at all: treat as this site (fail closed)
	}
	$p = strpos( $a, '#' );  if ( false !== $p ) { $a = substr( $a, 0, $p ); }
	$q = '';
	$p = strpos( $a, '?' );  if ( false !== $p ) { $q = rawurldecode( substr( $a, $p + 1 ) ); $a = substr( $a, 0, $p ); }
	$path = rawurldecode( $a );
	if ( '' === $path ) { $path = $auth ? '/' : $dir; } elseif ( '/' !== $path[0] ) { $path = $dir . $path; }
	$out = array();
	foreach ( explode( '/', $path ) as $seg ) {
		if ( '..' === $seg ) { array_pop( $out ); } elseif ( '' !== $seg && '.' !== $seg ) { $out[] = $seg; }
	}
	$trail = ( '' !== $path && '/' === substr( $path, -1 ) ) ? '/' : '';
	return array( $host, '/' . strtolower( implode( '/', $out ) ) . ( $out ? $trail : '' ), $q );
}

// Why an address is forbidden, or '' if it is fine or leads to another site.
function forbidden( $address, $ctx ) {
	global $HOSTS;
	$p = parse_address( $address, $ctx['dir'], $ctx['host'] );
	if ( null === $p ) { return ''; }
	if ( null !== $p[0] && ! in_array( $p[0], $HOSTS, true ) ) { return ''; }
	// Only WordPress's own addresses, which are always the first segment: a post at /wp-admin-tips/, a tag at
	// /tag/wp-json/ or a file at /blog/wp-login.php is the site's own. Behind a leading index.php WordPress reads the rest
	// as the address and matches it against its rule ^index.php/wp-json, whose dot is any character: so wp-json anywhere
	// after a leading index.php (spelled with any dot) is the REST API, and the first segment is the one after them all.
	$segs    = '/' === $p[1] ? array() : explode( '/', trim( $p[1], '/' ) );
	$indexed = false;
	while ( $segs && preg_match( '/^index.php$/', $segs[0] ) ) { array_shift( $segs ); $indexed = true; }
	if ( $indexed && in_array( 'wp-json', $segs, true ) ) { return '/wp-json'; }
	$path = '/' . implode( '/', $segs );
	if ( preg_match( '#^/wp-admin(/|$)#', $path ) ) { return '/wp-admin'; }
	if ( preg_match( '#^/wp-login\.php(/|$)#', $path ) ) { return '/wp-login.php'; }
	if ( preg_match( '#^/xmlrpc\.php(/|$)#', $path ) ) { return '/xmlrpc.php'; }
	if ( preg_match( '#^/wp-json(/|$)#', $path ) ) { return '/wp-json'; }
	if ( false !== stripos( '&' . $p[2], 'rest_route=' ) ) { return 'rest_route='; }
	return '';
}

function css_unescape( $css ) {
	return preg_replace_callback( '/\\\\(?:([0-9a-f]{1,6})[ \t\r\n\f]?|(.))/is', function ( $m ) {
		if ( isset( $m[2] ) && '' !== $m[2] ) { return $m[2]; }
		$cp = hexdec( $m[1] );
		return ( $cp < 1 || $cp > 0x10ffff ) ? '' : html_entity_decode( '&#' . $cp . ';', ENT_QUOTES, 'UTF-8' );
	}, $css );
}

function css_addresses( $css ) {
	$css = css_unescape( preg_replace( '#/\*.*?\*/#s', '', $css ) );
	$all = array();
	if ( preg_match_all( '/url\(\s*([\'"]?)(.*?)\1\s*\)/is', $css, $m ) ) { $all = array_merge( $all, $m[2] ); }
	if ( preg_match_all( '/@import\s*[\'"]([^\'"]+)[\'"]/i', $css, $m ) ) { $all = array_merge( $all, $m[1] ); }
	return $all;
}

// Check every address in markup. Adds "address => reason" to $hits; sets $fatal to a message if the parser gave up.
function html_scan( $html, $ctx, &$hits, &$fatal ) {
	$doc = new DOMDocument();
	libxml_use_internal_errors( true );
	libxml_clear_errors();
	$doc->loadHTML( '<?xml encoding="utf-8"?>' . $html, LIBXML_NONET | LIBXML_PARSEHUGE );
	foreach ( libxml_get_errors() as $e ) {
		if ( ( LIBXML_ERR_FATAL === $e->level || preg_match( '/huge|excessive depth/i', $e->message ) ) && null === $fatal ) {
			$fatal = trim( $e->message );
		}
	}
	libxml_clear_errors();
	foreach ( $doc->getElementsByTagName( 'base' ) as $b ) {   // the first <base href> decides how relative addresses resolve
		if ( $b->hasAttribute( 'href' ) ) {
			$p = parse_address( $b->getAttribute( 'href' ), $ctx['dir'], $ctx['host'] );
			if ( $p ) { $ctx = array( 'dir' => substr( $p[1], 0, strrpos( $p[1], '/' ) + 1 ), 'host' => $p[0] ); }
			break;
		}
	}
	$single = array( 'href', 'src', 'action', 'poster', 'data', 'formaction', 'cite', 'longdesc', 'manifest', 'background', 'xlink:href' );
	$list   = array();
	foreach ( $doc->getElementsByTagName( '*' ) as $el ) {
		foreach ( $el->attributes as $at ) {
			$name = strtolower( $at->nodeName );
			$val  = $at->nodeValue;
			if ( in_array( $name, $single, true ) ) { $list[] = $val; }
			elseif ( 'srcset' === $name || 'imagesrcset' === $name ) {
				foreach ( explode( ',', $val ) as $cand ) { $tok = preg_split( '/\s+/', trim( $cand ) ); $list[] = $tok[0]; }
			} elseif ( 'ping' === $name ) { $list = array_merge( $list, preg_split( '/\s+/', trim( $val ) ) ); }
			elseif ( 'style' === $name ) { $list = array_merge( $list, css_addresses( $val ) ); }
			elseif ( 'srcdoc' === $name ) { html_scan( $val, $ctx, $hits, $fatal ); }
			elseif ( 'content' === $name && 'meta' === $el->nodeName && 'refresh' === strtolower( trim( $el->getAttribute( 'http-equiv' ) ) )
				&& preg_match( '/^\s*[\d.]*\s*[;,]?\s*(?:url\s*=\s*)?[\'"]?([^\'"]*)/i', $val, $m ) ) { $list[] = $m[1]; }
		}
		if ( 'style' === $el->nodeName ) { $list = array_merge( $list, css_addresses( $el->textContent ) ); }
	}
	foreach ( $list as $address ) {
		$why = forbidden( $address, $ctx );
		if ( '' !== $why ) { $hits[ trim( $address ) ] = $why; }
	}
}

// The name of an element or attribute without its prefix, lowercase (a prefix the file never declared, as in a bare
// <atom:link>, stays part of the name the parser reports, so it is cut here too).
function local_name( $node ) {
	$n = strtolower( (string) ( $node->localName ? $node->localName : $node->nodeName ) );
	$p = strrpos( $n, ':' );
	return false === $p ? $n : substr( $n, $p + 1 );
}

// Check a feed or sitemap, read with the XML parser (so CDATA that holds "</description>" or "</link>" is just text):
// the text of every <link>, <loc>, <guid> and <comments>; every href, src and url attribute; and, as markup, what each
// element that holds a post's HTML carries (<content:encoded>, <description>, Atom <content> and <summary>), whether
// escaped, in CDATA or as XHTML elements. Sets $fatal when the file isn't XML the parser can read whole (fail closed).
// Returns false, having read no node, when the document has a DOCTYPE: WordPress's feeds and sitemaps never do, and
// declared entities expand (to gigabytes, if built to) when a node using them is read. That holds in any encoding, which
// the raw-byte look at the prolog can't see through (UTF-16, UTF-7). Parsed with LIBXML_NONET only: no LIBXML_NOENT,
// LIBXML_DTDLOAD or LIBXML_DTDATTR, so nothing is substituted or loaded while parsing, and no LIBXML_PARSEHUGE, so
// libxml's own limits stay.
function xml_scan( $xml, $ctx, &$hits, &$fatal ) {
	$doc = new DOMDocument();
	libxml_use_internal_errors( true );
	libxml_clear_errors();
	$ok = $doc->loadXML( $xml, LIBXML_NONET );
	foreach ( libxml_get_errors() as $e ) {
		if ( LIBXML_ERR_FATAL === $e->level && null === $fatal ) { $fatal = trim( $e->message ); }
	}
	libxml_clear_errors();
	if ( ! $ok || null !== $fatal ) {
		if ( null === $fatal ) { $fatal = 'not well-formed XML'; }
		return true;
	}
	if ( null !== $doc->doctype ) { return false; }
	$list = array();
	foreach ( $doc->getElementsByTagName( '*' ) as $el ) {
		$name = local_name( $el );
		if ( in_array( $name, array( 'link', 'loc', 'guid', 'comments' ), true ) ) { $list[] = trim( $el->textContent ); }
		foreach ( $el->attributes as $at ) {
			if ( in_array( local_name( $at ), array( 'href', 'src', 'url' ), true ) ) { $list[] = $at->nodeValue; }
		}
		if ( in_array( $name, array( 'encoded', 'description', 'content', 'summary' ), true ) ) {
			$html = '';
			foreach ( $el->childNodes as $child ) {
				$html .= XML_ELEMENT_NODE === $child->nodeType ? $doc->saveXML( $child ) : $child->textContent;
			}
			html_scan( $html, $ctx, $hits, $fatal );
		}
	}
	foreach ( $list as $address ) {
		$why = forbidden( $address, $ctx );
		if ( '' !== $why ) { $hits[ trim( $address ) ] = $why; }
	}
	return true;
}

// Whether the prolog (what comes before the root element's start tag: the XML declaration, comments, processing
// instructions) holds a DOCTYPE or ENTITY declaration, read as bytes. Only an ASCII-compatible encoding can be read
// this way; xml_scan() judges every encoding by what the parser saw. A post that only shows a "<!DOCTYPE" inside its
// CDATA is past the prolog, so it is fine.
function prolog_has_dtd( $xml ) {
	$i = "\xEF\xBB\xBF" === substr( $xml, 0, 3 ) ? 3 : 0;
	$n = strlen( $xml );
	while ( $i < $n ) {
		$i += strspn( $xml, " \t\r\n", $i );
		if ( '<?' === substr( $xml, $i, 2 ) ) { $end = strpos( $xml, '?>', $i ); $close = 2; }
		elseif ( '<!--' === substr( $xml, $i, 4 ) ) { $end = strpos( $xml, '-->', $i ); $close = 3; }
		else { return 0 === strncasecmp( substr( $xml, $i, 9 ), '<!DOCTYPE', 9 ) || 0 === strncasecmp( substr( $xml, $i, 8 ), '<!ENTITY', 8 ); }
		if ( false === $end ) { return false; }
		$i = $end + $close;
	}
	return false;
}

const DTD_REFUSED = ': has a DOCTYPE or ENTITY declaration, which a feed or sitemap never has, so it was not read';
// Bigger than this, a page or feed is not one WordPress made, and its DOM would take gigabytes.
const MAX_MARKUP_BYTES = 32 * 1024 * 1024;

function file_kind( $path, $ext ) {
	if ( in_array( $ext, array( 'html', 'htm', 'xhtml', 'svg' ), true ) ) { return 'html'; }
	if ( 'css' === $ext ) { return 'css'; }
	if ( in_array( $ext, array( 'xml', 'rss', 'atom' ), true ) ) { return 'xml'; }
	if ( '' !== $ext ) { return ''; }
	$head = ltrim( (string) file_get_contents( $path, false, null, 0, 512 ), "\xEF\xBB\xBF \t\r\n" );
	if ( preg_match( '/^<\?xml|^<(rss|feed|urlset|sitemapindex)\b/i', $head ) ) { return 'xml'; }
	if ( preg_match( '/^<(!doctype|html|head|body|svg)\b/i', $head ) ) { return 'html'; }
	return '';
}

$found = array();
$it = new RecursiveIteratorIterator( new RecursiveDirectoryIterator( $root, FilesystemIterator::SKIP_DOTS ) );
foreach ( $it as $file ) {
	if ( $file->isLink() || ! $file->isFile() ) { continue; }
	$kind = file_kind( $file->getPathname(), strtolower( $file->getExtension() ) );
	if ( '' === $kind ) { continue; }
	$rel  = substr( $file->getPathname(), strlen( $root ) + 1 );
	if ( 'css' !== $kind && $file->getSize() > MAX_MARKUP_BYTES ) { $found[ $rel . ': is larger than 32 MB; that is not a page' ] = true; continue; }
	$d    = dirname( $rel );
	$ctx  = array( 'dir' => '.' === $d ? '/' : '/' . $d . '/', 'host' => null );
	$text = file_get_contents( $file->getPathname() );
	if ( false === $text ) { $found[ $rel . ': could not be read' ] = true; continue; }
	$hits = array(); $fatal = null;
	if ( 'xml' === $kind && '' === trim( $text ) ) { $found[ $rel . ': is empty' ] = true; continue; }
	// A DOCTYPE in the prolog is refused unread, on the raw bytes; any other encoding is caught by xml_scan().
	if ( 'xml' === $kind && prolog_has_dtd( $text ) ) { $found[ $rel . DTD_REFUSED ] = true; continue; }
	if ( 'html' === $kind ) { html_scan( $text, $ctx, $hits, $fatal ); }
	elseif ( 'xml' === $kind && ! xml_scan( $text, $ctx, $hits, $fatal ) ) { $found[ $rel . DTD_REFUSED ] = true; continue; }
	else {
		foreach ( css_addresses( $text ) as $address ) {
			$why = forbidden( $address, $ctx );
			if ( '' !== $why ) { $hits[ trim( $address ) ] = $why; }
		}
	}
	if ( null !== $fatal ) { $found[ $rel . ': could not be read completely (' . $fatal . ')' ] = true; }
	foreach ( $hits as $address => $why ) { $found[ $rel . ': ' . $address . ' points at ' . $why ] = true; }
}
$lines = array();
foreach ( array_keys( $found ) as $line ) { $lines[] = preg_replace( '/[\x00-\x1f\x7f]/', '?', $line ); }
sort( $lines );
foreach ( $lines as $line ) { echo $line, "\n"; }
