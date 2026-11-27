// Tests the script a page with a comment form loads: its sources (pigeonhole/browser/src: what a submission is, the
// proof of work, how it is sent) and the two files built from them and committed (plugin/offprint/pigeonhole.js and
// pigeonhole-loader.js), which are what a site is published with. No page and no network: a fake form, a fake fetch.
// What the script builds is handed to lib/pigeonhole.php, the Mac's own check, so the two never drift apart.
// Run: node --test tests/pigeonhole-browser.test.js   (CI runs every *.test.js this way)
'use strict';

const { test } = require( 'node:test' );
const assert = require( 'node:assert' );
const fs = require( 'node:fs' );
const os = require( 'node:os' );
const path = require( 'node:path' );
const crypto = require( 'node:crypto' );
const { spawnSync } = require( 'node:child_process' );

const ROOT = path.join( __dirname, '..' );
const SRC = path.join( ROOT, 'pigeonhole/browser/src' );
const BUILT = path.join( ROOT, 'plugin/offprint/pigeonhole.js' );
const LOADER = path.join( ROOT, 'plugin/offprint/pigeonhole-loader.js' );
// Two public keys made for these tests (their private halves were never kept): a daily one and a recovery one.
const DAILY = 'age1ajjp3mu9nznj5y0gk0hye0v75kcqeda3rq9q0az204f2pp6vtpese0l39k';
const RECOVERY = 'age1lcn5lw0px559ch6rctd5wj8t27d7vqasc0xd4wl85f48zlth75nsru089h';

// The built files, as committed. A change to either that nobody looked at fails here: build again
// (pigeonhole/browser/build.sh), read what changed, run tests/pigeonhole-real.sh, then put the new hashes here.
const HASHES = {
	'pigeonhole.js': 'd4a8a290562981244e027b306bd01dd29d0b84c0e133dfde963d52c5a9fbf6f5',
	'pigeonhole-loader.js': '20024e104674e29d3acce08749714c9ad4e19ac949b9eb69d51192da40767199',
};

const transport = () => import( path.join( SRC, 'transport.js' ) );
const pow = () => import( path.join( SRC, 'pow.js' ) );
// The built script is an ES module without a package.json beside it to say so: a copy named .mjs is imported.
let builtCopy = null;
function built() {
	if ( ! builtCopy ) {
		const dir = fs.mkdtempSync( path.join( os.tmpdir(), 'offprint-pigeonhole-' ) );
		builtCopy = path.join( dir, 'pigeonhole.mjs' );
		fs.copyFileSync( BUILT, builtCopy );
		process.on( 'exit', () => fs.rmSync( dir, { recursive: true, force: true } ) );
	}
	return import( builtCopy );
}

// lib/pigeonhole.php check, on BYTES: its exit status, and what it printed.
function macCheck( bytes ) {
	const r = spawnSync( 'php', [ path.join( ROOT, 'lib/pigeonhole.php' ), 'check' ], { input: Buffer.from( bytes ) } );
	return { status: r.status, out: String( r.stdout ), err: String( r.stderr ).trim() };
}

const sha256 = ( file ) => crypto.createHash( 'sha256' ).update( fs.readFileSync( file ) ).digest( 'hex' );

test( 'the committed scripts are the ones these hashes were taken of', () => {
	assert.strictEqual( sha256( BUILT ), HASHES[ 'pigeonhole.js' ] );
	assert.strictEqual( sha256( LOADER ), HASHES[ 'pigeonhole-loader.js' ] );
} );

test( 'the loader is small, and names the other script as the exporter can read it', () => {
	const text = fs.readFileSync( LOADER, 'utf8' );
	assert.ok( text.length < 1024, `the loader is ${ text.length } bytes` );
	// plugin/offprint/src/Links.php follows import("...") in a script: that is how pigeonhole.js is exported at all.
	assert.ok( text.includes( 'import("./pigeonhole.js")' ) );
	// the block and the form are found with the document's own querySelector, not a property an element can stand in for
	assert.ok( text.includes( 'Document.prototype.querySelector.call(document' ) );
	assert.ok( text.includes( 'script#offprint-pigeonhole[type="application/json"]' ) );
	assert.ok( text.includes( 'form[data-offprint-pigeonhole]' ) );
	assert.ok( ! /document\.(forms|getElementById)/.test( text ) );
	assert.ok( ! /https?:\/\//.test( text ), 'the loader names no address' );
} );

test( 'the built script asks for nothing outside the page', () => {
	const text = fs.readFileSync( BUILT, 'utf8' );
	assert.ok( ! /\bimport\s*\(/.test( text ), 'it loads no other script' );
	assert.ok( ! /XMLHttpRequest|sendBeacon|WebSocket|EventSource|localStorage|sessionStorage|document\.cookie/.test( text ) );
	assert.strictEqual( ( text.match( /\bfetch\b/g ) || [] ).length, 1, 'fetch is named once: the one post' );
} );

test( 'proof of work: a nonce is found, checks, and is bound to its ciphertext', async () => {
	const { proveWork, workOk, zeroBits, NONCE_BYTES } = await pow();
	assert.strictEqual( zeroBits( Uint8Array.of( 0, 0, 0x10 ) ), 19 );
	assert.strictEqual( zeroBits( Uint8Array.of( 0x80 ) ), 0 );
	assert.strictEqual( zeroBits( Uint8Array.of( 0, 0 ) ), 16 );
	const ciphertext = new TextEncoder().encode( 'a ciphertext' );
	const nonce = await proveWork( ciphertext, 10 );
	assert.strictEqual( nonce.length, NONCE_BYTES );
	assert.strictEqual( await workOk( ciphertext, nonce, 10 ), true );
	assert.strictEqual( await workOk( new TextEncoder().encode( 'another one' ), nonce, 10 ), false );
	assert.strictEqual( await workOk( ciphertext, nonce.slice( 1 ), 10 ), false );
	assert.strictEqual( await workOk( ciphertext, new Uint8Array( NONCE_BYTES ).fill( 0xff ), 24 ), false );
} );

test( 'proof of work: with a hash that answers at once, the same nonce is found', async () => {
	const { proveWork, workOk } = await pow();
	const hash = ( bytes ) => new Uint8Array( crypto.createHash( 'sha256' ).update( bytes ).digest() );
	const ciphertext = new TextEncoder().encode( 'a ciphertext' );
	const slow = await proveWork( ciphertext, 12 );
	const fast = await proveWork( ciphertext, 12, hash );
	assert.deepStrictEqual( Array.from( fast ), Array.from( slow ) );
	assert.strictEqual( await workOk( ciphertext, fast, 12 ), true );
	// and past the point where it pauses to let the page breathe
	const far = await proveWork( ciphertext, 17, hash );
	assert.strictEqual( await workOk( ciphertext, far, 17 ), true );
} );

test( 'one line of text loses what the check refuses, and its ends', async () => {
	const { oneLine, manyLines, pagePath } = await transport();
	assert.strictEqual( oneLine( '  Ada\tLovelace\n' ), 'Ada Lovelace' );
	assert.strictEqual( oneLine( 'Ada\u{202E}nimda' ), 'Ada nimda' );
	assert.strictEqual( oneLine( 'a\u{2028}b\u{2029}c\u{2066}d' ), 'a b c d' );
	assert.strictEqual( oneLine( 'می\u{200C}خواهم' ), 'می\u{200C}خواهم' );
	assert.strictEqual( oneLine( undefined ), '' );
	// half of a pair of surrogates (a character cut in two) can't be written as JSON the Mac's check reads
	assert.strictEqual( oneLine( 'a' + String.fromCharCode( 0xd83d ) + 'b' ), 'a\u{FFFD}b' );
	assert.strictEqual( manyLines( String.fromCharCode( 0xde00 ) + 'x' ), '\u{FFFD}x' );
	assert.strictEqual( oneLine( 'ok \u{1F600}' ), 'ok \u{1F600}' );
	assert.strictEqual( manyLines( ' one\r\ntwo\n\tthree\u0000\u001b \n' ), 'one\r\ntwo\n\tthree' );
	assert.strictEqual( pagePath( '/hello/' ), '/hello/' );
	assert.strictEqual( pagePath( '//www.example.com/' ), '/' );
	assert.strictEqual( pagePath( 'hello' ), '/' );
	assert.strictEqual( pagePath( '/a\tb' ), '/' );
	assert.strictEqual( pagePath( '/' + 'a'.repeat( 500 ) ), '/' );
} );

test( 'a comment\'s fields come from the form, and what is wrong with them is said', async () => {
	const { commentFields } = await transport();
	const form = { comment_post_ID: '4', comment_parent: '7', author: ' Ada ', email: 'ada@example.com', url: '', comment: ' Hello.\n ', offprint_hp: '' };
	assert.deepStrictEqual( commentFields( form, 42.9 ), {
		fields: { post_id: 4, parent: 7, author: 'Ada', email: 'ada@example.com', url: '', content: 'Hello.', hp: '', elapsed: 42 },
		problem: '',
	} );
	assert.strictEqual( commentFields( { ...form, comment: ' \n ' }, 1 ).problem, 'empty' );
	assert.strictEqual( commentFields( { ...form, comment: 'x'.repeat( 6001 ) }, 1 ).problem, 'long:content' );
	assert.strictEqual( commentFields( { ...form, comment: 'é'.repeat( 3001 ) }, 1 ).problem, 'long:content' );   // bytes, not characters
	assert.strictEqual( commentFields( { ...form, author: 'a'.repeat( 246 ) }, 1 ).problem, 'long:author' );
	assert.strictEqual( commentFields( { ...form, email: 'a'.repeat( 101 ) }, 1 ).problem, 'long:email' );
	assert.strictEqual( commentFields( { ...form, url: 'a'.repeat( 201 ) }, 1 ).problem, 'long:url' );
	// what is not a whole number is 0, and the check or WordPress refuses it there
	assert.strictEqual( commentFields( { ...form, comment_post_ID: 'x', comment_parent: '-1' }, -5 ).fields.post_id, 0 );
	assert.strictEqual( commentFields( { ...form, comment_parent: '1.5' }, 1 ).fields.parent, 0 );
	assert.strictEqual( commentFields( form, -5 ).fields.elapsed, 0 );
	// a filled hidden field is kept (the sorter reads it), short
	assert.strictEqual( commentFields( { ...form, offprint_hp: 'x'.repeat( 500 ) }, 1 ).fields.hp.length, 50 );
} );

test( 'a submission is padded to one size, whatever it holds', async () => {
	const { commentFields, envelope, padded, PLAIN_BYTES } = await transport();
	const one = padded( envelope( 'comment', commentFields( { comment_post_ID: '4', comment: 'x' }, 5 ).fields, { now: 1795000000123, id: 'a'.repeat( 32 ), page: '/hello/' } ) );
	const two = padded( envelope( 'comment', commentFields( { comment_post_ID: '4', comment: 'x'.repeat( 6000 ), author: 'Zoë' }, 5 ).fields ) );
	assert.strictEqual( one.length, PLAIN_BYTES );
	assert.strictEqual( two.length, PLAIN_BYTES );
	assert.deepStrictEqual( JSON.parse( new TextDecoder().decode( one ) ), {
		v: 1, kind: 'comment', id: 'a'.repeat( 32 ), ts: 1795000000, page: '/hello/',
		fields: { post_id: 4, parent: 0, author: '', email: '', url: '', content: 'x', hp: '', elapsed: 5 },
	} );
	// 6000 quotation marks are 12000 bytes written down: too long, and said so, not cut
	assert.strictEqual( padded( envelope( 'comment', commentFields( { comment_post_ID: '4', comment: '"'.repeat( 6000 ) }, 5 ).fields ) ), null );
} );

test( 'an id is 32 hex digits, from the random bytes it is given', async () => {
	const { randomId } = await transport();
	assert.match( randomId(), /^[0-9a-f]{32}$/ );
	assert.notStrictEqual( randomId(), randomId() );
	assert.strictEqual( randomId( ( bytes ) => bytes.fill( 0xab ) ), 'ab'.repeat( 16 ) );
} );

test( 'what the script builds, the Mac\'s check takes', async () => {
	const { commentFields, envelope, padded } = await transport();
	const cases = [
		{ comment_post_ID: '4', comment_parent: '0', author: 'Ada', email: 'ada@example.com', url: 'https://www.example.com/', comment: 'A comment — with ünïcode, <b>markup</b> & "quotes".\nAnd a second line.', offprint_hp: '' },
		{ comment_post_ID: '4', comment: 'x' },
		{ comment_post_ID: '2147483647', comment_parent: '2147483647', author: 'a'.repeat( 245 ), email: 'a'.repeat( 100 ), url: 'a'.repeat( 200 ), comment: 'x'.repeat( 6000 ), offprint_hp: 'h'.repeat( 500 ) },
		// what a paste can bring: each is cleaned here, so the check has nothing to refuse
		{ comment_post_ID: '4', author: 'Ada\tLovelace\u{202E}', email: ' ada@example.com\n', url: 'https://www.example.com/\u{2028}', comment: 'a\u0000b\u001bc\r\nd\u{2028}e' },
		{ comment_post_ID: '4', author: 'Ada' + String.fromCharCode( 0xd83d ), comment: 'x' + String.fromCharCode( 0xdc00 ) + 'y', offprint_hp: '\u{1F600}'.repeat( 30 ) },
	];
	for ( const values of cases ) {
		const { fields, problem } = commentFields( values, 42 );
		assert.strictEqual( problem, '' );
		const r = macCheck( padded( envelope( 'comment', fields, { page: '/hello/' } ) ) );
		assert.strictEqual( r.status, 0, r.err );
		assert.deepStrictEqual( JSON.parse( r.out ).fields, fields );
	}
	// and a page path the check would refuse is never sent as it is
	const r = macCheck( padded( envelope( 'comment', commentFields( cases[ 1 ], 1 ).fields, { page: '//www.example.com/x' } ) ) );
	assert.strictEqual( r.status, 0, r.err );
	assert.strictEqual( JSON.parse( r.out ).page, '/' );
} );

test( 'what is posted is the nonce, then the ciphertext, and nothing travels with it', async () => {
	const { body, send } = await transport();
	const { workOk, NONCE_BYTES } = await pow();
	const ciphertext = new TextEncoder().encode( 'a ciphertext' );
	const bytes = await body( ciphertext, 8 );
	assert.strictEqual( bytes.length, NONCE_BYTES + ciphertext.length );
	assert.deepStrictEqual( Array.from( bytes.slice( NONCE_BYTES ) ), Array.from( ciphertext ) );
	assert.strictEqual( await workOk( ciphertext, bytes.slice( 0, NONCE_BYTES ), 8 ), true );
	const calls = [];
	const fetcher = ( status ) => async ( url, init ) => { calls.push( { url, init } ); return { status }; };
	assert.strictEqual( await send( '/_pigeonhole', bytes, fetcher( 204 ) ), true );
	assert.strictEqual( await send( '/_pigeonhole', bytes, fetcher( 200 ) ), false );
	assert.strictEqual( await send( '/_pigeonhole', bytes, fetcher( 500 ) ), false );
	assert.strictEqual( calls[ 0 ].url, '/_pigeonhole' );
	assert.deepStrictEqual( Object.keys( calls[ 0 ].init ).sort(), [ 'body', 'cache', 'credentials', 'method', 'redirect', 'referrerPolicy' ] );
	assert.strictEqual( calls[ 0 ].init.method, 'POST' );
	assert.strictEqual( calls[ 0 ].init.credentials, 'omit' );
	assert.strictEqual( calls[ 0 ].init.referrerPolicy, 'no-referrer' );
	assert.strictEqual( calls[ 0 ].init.redirect, 'error' );
	assert.strictEqual( calls[ 0 ].init.body, bytes );
} );

// ---- the built script, as a page runs it ------------------------------------------------------------------------------

// A form as the script uses it: its fields by name, the line under it, its button.
function fakeForm( values ) {
	const made = [];
	const elements = {};
	for ( const [ name, value ] of Object.entries( values ) ) {
		// a field as a page has it: its value, whether the site asks for it, and the browser's own word on it
		elements[ name ] = typeof value === 'object' ? value : { value };
	}
	const button = { disabled: false };
	const form = {
		elements, button, made,
		ownerDocument: {
			location: { pathname: '/hello-comments/', origin: 'https://www.example.com' },
			createElement: ( tag ) => ( { tag, className: '', textContent: '', attributes: {}, setAttribute( k, v ) { this.attributes[ k ] = v; } } ),
		},
		querySelector: ( selector ) => {
			if ( selector === '[type="submit"]' ) { return button; }
			if ( selector === '.offprint-pigeonhole-status' ) { return made[ 0 ] || null; }
			const named = /^\[name="([^"]+)"\]$/.exec( selector );
			if ( named ) { return elements[ named[ 1 ] ] || null; }
			return null;
		},
		append: ( el ) => made.push( el ),
	};
	return form;
}
const GOOD = { comment_post_ID: '4', comment_parent: '0', author: 'Ada', email: 'ada@example.com', url: '', comment: 'MARKER-ZX81 a comment', offprint_hp: '' };
const CONFIG = { path: '/_pigeonhole', recipients: [ DAILY, RECOVERY ], bits: 8 };

// Runs FN with the page's fetch replaced by one that notes each call and answers STATUS (or throws, for 0).
async function withFetch( status, fn ) {
	const calls = [];
	const real = globalThis.fetch;
	globalThis.fetch = async ( url, init ) => { calls.push( { url, init } ); if ( status === 0 ) { throw new TypeError( 'network' ); } return { status }; };
	try { await fn( calls ); } finally { globalThis.fetch = real; }
}

test( 'built: a submission is encrypted to every key, and is one size for each number of keys', async () => {
	const { seal } = await built();
	const plain = new Uint8Array( 8192 ).fill( 0x20 );
	const one = await seal( plain, [ DAILY ] );
	const two = await seal( plain, [ DAILY, RECOVERY ] );
	assert.strictEqual( new TextDecoder().decode( one.slice( 0, 32 ) ), 'age-encryption.org/v1\n-> X25519 ' );
	// The two sizes the pigeonhole takes, and no other: the real age makes the same (tests/pigeonhole-real.sh opens them).
	assert.strictEqual( one.length, 8392 );
	assert.strictEqual( two.length, 8490 );
	assert.notDeepStrictEqual( Array.from( await seal( plain, [ DAILY ] ) ), Array.from( one ), 'no two encryptions are the same' );
	await assert.rejects( seal( plain, [ 'age1' + 'q'.repeat( 58 ) ] ), 'a key that is no key is refused, not skipped' );
} );

test( 'built: a comment is encrypted, proved and posted, and the visitor is told', async () => {
	const { submit, SAYS } = await built();
	const { workOk, NONCE_BYTES } = await pow();
	const form = fakeForm( GOOD );
	await withFetch( 204, async ( calls ) => {
		await submit( form, CONFIG, Date.now() - 42000 );
		assert.strictEqual( calls.length, 1 );
		// the path on the page's own origin, written whole: a <base> element in the page can't send it elsewhere
		assert.strictEqual( calls[ 0 ].url, 'https://www.example.com/_pigeonhole' );
		const body = calls[ 0 ].init.body;
		assert.strictEqual( body.length, NONCE_BYTES + 8490 );
		assert.strictEqual( await workOk( body.slice( NONCE_BYTES ), body.slice( 0, NONCE_BYTES ), 8 ), true );
		assert.ok( ! Buffer.from( body ).includes( 'MARKER-ZX81' ), 'nothing readable is posted' );
		assert.ok( ! Buffer.from( body ).includes( 'ada@example.com' ) );
	} );
	assert.strictEqual( form.made.length, 1 );
	assert.strictEqual( form.made[ 0 ].textContent, SAYS.sent );
	assert.strictEqual( form.made[ 0 ].attributes.role, 'status' );
	assert.strictEqual( form.elements.comment.value, '', 'the text is cleared' );
	assert.strictEqual( form.elements.author.value, 'Ada', 'the name is kept' );
	assert.strictEqual( form.button.disabled, false );
} );

for ( const [ name, status ] of [ [ 'the pigeonhole refuses it', 429 ], [ 'the pigeonhole answers 200, which is not its answer', 200 ], [ 'the network fails', 0 ] ] ) {
	test( `built: when ${ name }, the visitor is told and what they wrote is kept`, async () => {
		const { submit, SAYS } = await built();
		const form = fakeForm( GOOD );
		await withFetch( status, async ( calls ) => {
			await submit( form, CONFIG, Date.now() - 42000 );
			assert.strictEqual( calls.length, 1 );
		} );
		assert.strictEqual( form.made[ 0 ].textContent, SAYS.failed );
		assert.strictEqual( form.elements.comment.value, 'MARKER-ZX81 a comment' );
		assert.strictEqual( form.button.disabled, false );
		// and the next try is not taken for a second press
		await withFetch( 204, async ( calls ) => {
			await submit( form, CONFIG, Date.now() - 42000 );
			assert.strictEqual( calls.length, 1 );
		} );
		assert.strictEqual( form.made[ 0 ].textContent, SAYS.sent );
	} );
}

test( 'built: nothing is posted for an empty comment, or one too long', async () => {
	const { submit, SAYS } = await built();
	await withFetch( 204, async ( calls ) => {
		const empty = fakeForm( { ...GOOD, comment: '  \n ' } );
		await submit( empty, CONFIG, Date.now() );
		assert.strictEqual( empty.made[ 0 ].textContent, SAYS.empty );
		const long = fakeForm( { ...GOOD, comment: 'x'.repeat( 6001 ) } );
		await submit( long, CONFIG, Date.now() );
		assert.strictEqual( long.made[ 0 ].textContent, SAYS.long );
		assert.strictEqual( long.elements.comment.value.length, 6001, 'what they wrote is kept' );
		const quotes = fakeForm( { ...GOOD, comment: '"'.repeat( 5000 ) } );
		await submit( quotes, CONFIG, Date.now() );
		assert.strictEqual( quotes.made[ 0 ].textContent, SAYS.long );
		assert.strictEqual( calls.length, 0 );
	} );
} );

test( 'built: a name or an address the site asks for, and WordPress would refuse, is asked for before anything is sent', async () => {
	const { submit, SAYS } = await built();
	const asked = ( value, valid = true ) => ( { value, required: true, checkValidity: () => valid } );
	await withFetch( 204, async ( calls ) => {
		const noName = fakeForm( { ...GOOD, author: asked( '  ' ), email: asked( 'ada@example.com' ) } );
		await submit( noName, CONFIG, Date.now() - 5000 );
		assert.strictEqual( noName.made[ 0 ].textContent, SAYS.missing );
		const badEmail = fakeForm( { ...GOOD, author: asked( 'Ada' ), email: asked( 'not an address', false ) } );
		await submit( badEmail, CONFIG, Date.now() - 5000 );
		assert.strictEqual( badEmail.made[ 0 ].textContent, SAYS.missing );
		assert.strictEqual( badEmail.elements.comment.value, 'MARKER-ZX81 a comment', 'what they wrote is kept' );
		// a theme that marks a field the older way
		const aria = fakeForm( { ...GOOD, author: { value: '', getAttribute: ( n ) => ( n === 'aria-required' ? 'true' : null ) } } );
		await submit( aria, CONFIG, Date.now() - 5000 );
		assert.strictEqual( aria.made[ 0 ].textContent, SAYS.missing );
		assert.strictEqual( calls.length, 0 );
		// a site that asks for neither takes a comment with neither
		const free = fakeForm( { ...GOOD, author: '', email: '' } );
		await submit( free, CONFIG, Date.now() - 5000 );
		assert.strictEqual( free.made[ 0 ].textContent, SAYS.sent );
		assert.strictEqual( calls.length, 1 );
	} );
} );

test( 'built: a second press while one is being sent does nothing', async () => {
	const { submit } = await built();
	const form = fakeForm( GOOD );
	await withFetch( 204, async ( calls ) => {
		const first = submit( form, CONFIG, Date.now() - 5000 );
		const second = submit( form, CONFIG, Date.now() - 5000 );
		await Promise.all( [ first, second ] );
		assert.strictEqual( calls.length, 1 );
	} );
} );

test( 'built: a key that is no key posts nothing, and the visitor is told it failed', async () => {
	const { submit, SAYS } = await built();
	const form = fakeForm( GOOD );
	await withFetch( 204, async ( calls ) => {
		await submit( form, { ...CONFIG, recipients: [ 'age1' + 'q'.repeat( 58 ) ] }, Date.now() - 5000 );
		assert.strictEqual( calls.length, 0 );
	} );
	assert.strictEqual( form.made[ 0 ].textContent, SAYS.failed );
	assert.strictEqual( form.elements.comment.value, 'MARKER-ZX81 a comment' );
} );
