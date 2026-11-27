// Tests pigeonhole/server/store.js, a site's pigeonhole: the store that takes the comments a site's visitors sent,
// encrypted, and keeps them for the owner's Mac to fetch. Each test starts one on a port of its own on 127.0.0.1, with a
// folder of its own and a clock the test moves. What is posted is made as the page's script makes it, and for one test
// by that script itself, as built and committed (plugin/offprint/pigeonhole.js). No network beyond this machine.
// Run: node --test tests/pigeonhole-server.test.js   (CI runs every *.test.js this way)
'use strict';

const { test } = require( 'node:test' );
const assert = require( 'node:assert' );
const fs = require( 'node:fs' );
const os = require( 'node:os' );
const path = require( 'node:path' );
const net = require( 'node:net' );
const crypto = require( 'node:crypto' );
const { spawn } = require( 'node:child_process' );

const ROOT = path.join( __dirname, '..' );
const STORE = path.join( ROOT, 'pigeonhole/server/store.js' );
const { createStore, workOk, sender, NONCE_BYTES, CIPHERTEXT_BYTES } = require( STORE );
const HOUR = 3600 * 1000;
const sha256 = ( bytes ) => crypto.createHash( 'sha256' ).update( bytes ).digest();

// Something the size of a submission to ONE recipient or TWO, starting as an age file does, different every time.
function ciphertext( recipients = 2 ) {
	const bytes = crypto.randomBytes( CIPHERTEXT_BYTES[ recipients - 1 ] );
	Buffer.from( 'age-encryption.org/v1\n-> X25519 ' ).copy( bytes );
	return bytes;
}
// What a page posts for CIPHERTEXT: a nonce that is a proof of BITS for it, then the ciphertext.
function body( bytes, bits = 8 ) {
	const input = Buffer.concat( [ sha256( bytes ), Buffer.alloc( NONCE_BYTES ) ] );
	for ( let n = 0; ; n++ ) {
		input.writeUInt32BE( n, 36 );
		if ( workOk( bytes, input.subarray( 32 ), bits ) ) { return Buffer.concat( [ input.subarray( 32 ), bytes ] ); }
	}
}

// A store, listening: its address, its folder, its clock (clock.now, in milliseconds), what it said, and how to end it.
async function start( options = {} ) {
	const dir = fs.mkdtempSync( path.join( os.tmpdir(), 'offprint-store-' ) );
	const clock = { now: 1795000000000 };
	const said = [];
	const server = createStore( { dir: path.join( dir, 'store' ), path: '/_pigeonhole', bits: 8, now: () => clock.now, say: ( line ) => said.push( line ), ...options } );
	await new Promise( ( go ) => server.listen( 0, '127.0.0.1', go ) );
	const base = `http://127.0.0.1:${ server.address().port }`;
	return {
		server, base, clock, said, dir: path.join( dir, 'store' ),
		files: () => fs.readdirSync( path.join( dir, 'store' ) ).sort(),
		stop: async () => { await new Promise( ( go ) => { server.close( go ); server.closeAllConnections(); } ); fs.rmSync( dir, { recursive: true, force: true } ); },
	};
}
// A post of BYTES to the store S: the status, and everything else it answered.
async function post( s, bytes, { address = '203.0.113.7', url = '/_pigeonhole', method = 'POST', headers = {} } = {} ) {
	const r = await fetch( s.base + url, { method, body: method === 'GET' || method === 'HEAD' ? undefined : bytes, headers: { ...( address ? { 'x-pigeonhole-client': address } : {} ), ...headers } } );
	return { status: r.status, text: await r.text(), headers: Object.fromEntries( r.headers ) };
}

test( 'a submission is kept, under the name its bytes give it, and the answer is a bare 204', async () => {
	const s = await start();
	try {
		const bytes = ciphertext();
		const r = await post( s, body( bytes ) );
		assert.strictEqual( r.status, 204 );
		assert.strictEqual( r.text, '' );
		assert.deepStrictEqual( Object.keys( r.headers ).sort(), [ 'connection', 'content-length', 'date' ], 'no header says what this is' );
		const name = sha256( bytes ).toString( 'hex' ) + '.age';
		assert.deepStrictEqual( s.files(), [ name ] );
		// what is kept is the ciphertext alone (the nonce has done its work): offprint collect opens the file as it is
		assert.ok( fs.readFileSync( path.join( s.dir, name ) ).equals( bytes ) );
		assert.strictEqual( fs.statSync( path.join( s.dir, name ) ).mode & 0o777, 0o600 );
		assert.strictEqual( fs.statSync( s.dir ).mode & 0o777, 0o700 );
	} finally { await s.stop(); }
} );

test( 'both sizes a submission has are taken: to one recipient, and to two', async () => {
	const s = await start();
	try {
		assert.strictEqual( ( await post( s, body( ciphertext( 1 ) ) ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext( 2 ) ) ) ).status, 204 );
		assert.deepStrictEqual( s.files().map( ( f ) => fs.statSync( path.join( s.dir, f ) ).size ).sort(), [ 8392, 8490 ] );
	} finally { await s.stop(); }
} );

test( 'any other size is refused by its length alone, before a byte of it is read', async () => {
	const s = await start();
	try {
		for ( const size of [ 0, 1, 8399, 8401, 8497, 8499, 8490, 8392, 100000 ] ) {
			const r = await post( s, Buffer.alloc( size, 0x61 ) );
			assert.strictEqual( r.status, 413, `a body of ${ size } bytes` );
			assert.strictEqual( r.text, '' );
		}
		assert.deepStrictEqual( s.files(), [] );
		// a length that isn't one, straight on the wire: refused as it stands, and the 5 MB after it never waited for
		const raw = await new Promise( ( done ) => {
			const socket = net.connect( new URL( s.base ).port, '127.0.0.1', () => socket.write( 'POST /_pigeonhole HTTP/1.1\r\nHost: x\r\nContent-Length: 5000000\r\n\r\n' ) );
			let got = ''; socket.on( 'data', ( d ) => { got += d; } ); socket.on( 'close', () => done( got ) ); socket.on( 'error', () => done( got ) );
		} );
		assert.match( raw, /^HTTP\/1\.1 413 / );
	} finally { await s.stop(); }
} );

test( 'a body with no length given is refused', async () => {
	const s = await start();
	try {
		const raw = await new Promise( ( done ) => {
			const socket = net.connect( new URL( s.base ).port, '127.0.0.1', () => socket.write( 'POST /_pigeonhole HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n' ) );
			let got = ''; socket.on( 'data', ( d ) => { got += d; } ); socket.on( 'close', () => done( got ) ); socket.on( 'error', () => done( got ) );
		} );
		assert.match( raw, /^HTTP\/1\.1 411 / );
		assert.deepStrictEqual( s.files(), [] );
	} finally { await s.stop(); }
} );

test( 'it takes one path and one method, and has no way to list or give back what it holds', async () => {
	const s = await start();
	try {
		const bytes = ciphertext();
		assert.strictEqual( ( await post( s, body( bytes ) ) ).status, 204 );
		const name = s.files()[ 0 ];
		for ( const method of [ 'GET', 'HEAD', 'PUT', 'DELETE', 'PATCH', 'OPTIONS' ] ) {
			const r = await post( s, method === 'GET' || method === 'HEAD' ? undefined : body( ciphertext() ), { method } );
			assert.strictEqual( r.status, 405, method );
			assert.strictEqual( r.text, '' );
			assert.strictEqual( r.headers.allow, undefined );
		}
		for ( const url of [ '/', '/_pigeonhole/', '/_pigeonhole?x=1', '/_pigeonhole/' + name, '/' + name, '/store/' + name, '/_PIGEONHOLE', '//_pigeonhole', '/_pigeonhole/..', '/elsewhere' ] ) {
			for ( const method of [ 'GET', 'POST' ] ) {
				const r = await post( s, method === 'GET' ? undefined : body( ciphertext() ), { method, url } );
				assert.strictEqual( r.status, 404, `${ method } ${ url }` );
				assert.strictEqual( r.text, '' );
			}
		}
		assert.deepStrictEqual( s.files(), [ name ], 'nothing more was kept, and nothing changed' );
	} finally { await s.stop(); }
} );

test( 'what does not start as an age file does is refused', async () => {
	const s = await start();
	try {
		const junk = crypto.randomBytes( 8490 );
		assert.strictEqual( ( await post( s, body( junk ) ) ).status, 400 );
		const nearly = ciphertext(); nearly[ 0 ] = 0x41;
		assert.strictEqual( ( await post( s, body( nearly ) ) ).status, 400 );
		assert.deepStrictEqual( s.files(), [] );
	} finally { await s.stop(); }
} );

test( 'a proof of work that is not one for these bytes is refused', async () => {
	const s = await start( { bits: 16 } );
	try {
		const bytes = ciphertext();
		// no work done
		assert.strictEqual( ( await post( s, Buffer.concat( [ Buffer.alloc( NONCE_BYTES ), bytes ] ) ) ).status, 403 );
		// work done for fewer bits than asked (and, as it happens, no more)
		let weak;
		do { weak = body( ciphertext(), 4 ); } while ( workOk( weak.subarray( NONCE_BYTES ), weak.subarray( 0, NONCE_BYTES ), 16 ) );
		assert.strictEqual( ( await post( s, weak ) ).status, 403 );
		// work done for other bytes
		const other = body( ciphertext(), 16 );
		assert.strictEqual( ( await post( s, Buffer.concat( [ other.subarray( 0, NONCE_BYTES ), bytes ] ) ) ).status, 403 );
		assert.deepStrictEqual( s.files(), [] );
		assert.strictEqual( ( await post( s, body( bytes, 16 ) ) ).status, 204 );
	} finally { await s.stop(); }
} );

test( 'the same bytes sent again are one file, never written twice, and still 204', async () => {
	const s = await start();
	try {
		const bytes = ciphertext();
		const sent = body( bytes );
		assert.strictEqual( ( await post( s, sent ) ).status, 204 );
		const file = path.join( s.dir, s.files()[ 0 ] );
		const before = fs.statSync( file );
		s.clock.now += 5000;
		assert.strictEqual( ( await post( s, sent ) ).status, 204 );
		assert.strictEqual( ( await post( s, sent, { address: '203.0.113.8' } ) ).status, 204 );
		assert.strictEqual( s.files().length, 1 );
		const after = fs.statSync( file );
		assert.strictEqual( after.ino, before.ino );
		assert.strictEqual( after.mtimeMs, before.mtimeMs );
		// at once, from many: still one file, whole
		const again = body( ciphertext() );
		const all = await Promise.all( Array.from( { length: 8 }, ( _, i ) => post( s, again, { address: `203.0.113.${ 20 + i }` } ) ) );
		assert.deepStrictEqual( all.map( ( r ) => r.status ), Array( 8 ).fill( 204 ) );
		assert.strictEqual( s.files().length, 2 );
		assert.deepStrictEqual( s.files().filter( ( f ) => f.startsWith( '.' ) ), [], 'nothing half-written is left' );
	} finally { await s.stop(); }
} );

test( 'one address may send so many an hour, and no more; another is not held up by it', async () => {
	const s = await start( { perAddress: 3 } );
	try {
		for ( let i = 0; i < 3; i++ ) { assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 ); }
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 429 );
		assert.strictEqual( s.files().length, 3 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.8' } ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '2001:db8::1' } ) ).status, 204 );
		// sending the same thing again is a turn like any other
		const s2 = await start( { perAddress: 2 } );
		try {
			const sent = body( ciphertext() );
			assert.strictEqual( ( await post( s2, sent ) ).status, 204 );
			assert.strictEqual( ( await post( s2, sent ) ).status, 204 );
			assert.strictEqual( ( await post( s2, sent ) ).status, 429 );
		} finally { await s2.stop(); }
		// an hour on, the address may send again
		s.clock.now += HOUR + 1;
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 );
	} finally { await s.stop(); }
} );

test( 'the web server must say whose it is: without that, or with something that is no address, it is refused', async () => {
	const s = await start();
	try {
		for ( const address of [ null, 'not an address; rm -rf /', 'x'.repeat( 300 ), '203.0.113', '203.0.113.7, 198.51.100.1', '2001:db8::1::2', 'localhost', '' ] ) {
			const r = await post( s, body( ciphertext() ), { address } );
			assert.strictEqual( r.status, 400, `the address ${ address }` );
		}
		assert.deepStrictEqual( s.files(), [] );
		s.server.report();
		assert.deepStrictEqual( s.said, [ 'pigeonhole: no address 8' ] );
	} finally { await s.stop(); }
} );

test( 'a sender is one IPv4 address, or one /64 of IPv6, however it is written', () => {
	assert.strictEqual( sender( '203.0.113.7' ), '203.0.113.7' );
	// IPv4 written as IPv6 is that IPv4 address
	assert.strictEqual( sender( '::ffff:203.0.113.7' ), '203.0.113.7' );
	assert.strictEqual( sender( '::FFFF:cb00:7107' ), '203.0.113.7' );
	assert.strictEqual( sender( '0:0:0:0:0:ffff:203.0.113.7' ), '203.0.113.7' );
	// every address of a /64 is one sender: a visitor with IPv6 has all of them
	const one = sender( '2001:db8:1:2::1' );
	assert.strictEqual( one, '2001:db8:1:2::/64' );
	for ( const same of [ '2001:db8:1:2:ffff:ffff:ffff:ffff', '2001:DB8:1:2::abcd', '2001:0db8:0001:0002:0000:0000:0000:0001', '2001:db8:1:2:0:0:0:1', '2001:db8:1:2::1.2.3.4' ] ) {
		assert.strictEqual( sender( same ), one, same );
	}
	assert.notStrictEqual( sender( '2001:db8:1:3::1' ), one );
	assert.strictEqual( sender( '::1' ), '0:0:0:0::/64' );
	assert.strictEqual( sender( '2001:db8::' ), '2001:db8:0:0::/64' );
	for ( const not of [ undefined, null, 7, '', 'x', '203.0.113', '203.0.113.256', '2001:db8::1::2', '2001:db8:1:2:3:4:5:6:7', '[2001:db8::1]', '2001:db8::1%eth0', ' 203.0.113.7', '203.0.113.7\n' ] ) {
		assert.strictEqual( sender( not ), null, String( not ) );
	}
} );

test( 'the limit for one sender holds across a /64 of IPv6, and for IPv4 written as IPv6', async () => {
	const s = await start( { perAddress: 2 } );
	try {
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '2001:db8:1:2::1' } ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '2001:DB8:1:2:aaaa:bbbb:cccc:dddd' } ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '2001:db8:1:2:ffff::9' } ) ).status, 429 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '2001:db8:1:3::1' } ) ).status, 204, 'the next /64 is another sender' );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.7' } ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '::ffff:203.0.113.7' } ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.7' } ) ).status, 429 );
	} finally { await s.stop(); }
} );

test( 'the same bytes sent again, from however many senders, do not use up everyone\'s hour', async () => {
	const s = await start( { perHour: 3 } );
	try {
		const sent = body( ciphertext() );
		for ( let i = 0; i < 12; i++ ) { assert.strictEqual( ( await post( s, sent, { address: `2001:db8:1:${ i }::1` } ) ).status, 204 ); }
		assert.strictEqual( s.files().length, 1 );
		// the one that was kept is one of the hour's three; two more are still taken
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.50' } ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.51' } ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.52' } ) ).status, 429 );
	} finally { await s.stop(); }
} );

test( 'a sender is forgotten within the hour, though nobody else comes', async () => {
	const s = await start();
	try {
		await post( s, body( ciphertext() ), { address: '203.0.113.7' } );
		await post( s, body( ciphertext() ), { address: '2001:db8::1' } );
		assert.strictEqual( s.server.remembered(), 2 );
		s.clock.now += HOUR - 1000; s.server.forget();
		assert.strictEqual( s.server.remembered(), 2 );
		s.clock.now += 2000; s.server.forget();   // (as its own timer does, every ten minutes)
		assert.strictEqual( s.server.remembered(), 0 );
	} finally { await s.stop(); }
} );

// A file system that fails as told: FAIL( name, args ) is asked before each call, and what it returns (an error to
// throw, a number to return in place of the real answer) is what happens.
function failing( fail ) {
	return new Proxy( fs, { get: ( real, name ) => ( typeof real[ name ] !== 'function' ? real[ name ] : ( ...args ) => {
		const instead = fail( name, args );
		if ( instead instanceof Error ) { throw instead; }
		if ( typeof instead === 'number' ) { return instead; }
		return real[ name ]( ...args );
	} ) } );
}
const errno = ( code ) => Object.assign( new Error( code ), { code } );

test( 'a submission that could not be written whole is not kept, leaves nothing behind, and is a turn all the same', async () => {
	let broken = 'short';
	const s = await start( { perAddress: 4, fs: failing( ( name, args ) => {
		if ( name !== 'writeSync' || ! broken ) { return undefined; }
		if ( broken === 'short' ) { return fs.writeSync( args[ 0 ], args[ 1 ], args[ 2 ], 100 ) && 0; }   // some of it written, then no more
		return errno( 'ENOSPC' );
	} ) } );
	try {
		const sent = body( ciphertext() );
		assert.strictEqual( ( await post( s, sent ) ).status, 500 );
		assert.deepStrictEqual( s.files(), [], 'nothing under its name, and nothing half-written' );
		broken = 'full';
		assert.strictEqual( ( await post( s, sent ) ).status, 500 );
		assert.strictEqual( ( await post( s, sent ) ).status, 500 );
		assert.deepStrictEqual( s.files(), [] );
		s.server.report();
		assert.deepStrictEqual( s.said, [ 'pigeonhole: failed ENOSPC 2, failed ESHORT 1' ], 'why, by its code, and no path' );
		// the disk is mended: the same bytes are kept now, whole (they were never "held already")
		broken = null;
		assert.strictEqual( ( await post( s, sent ) ).status, 204 );
		assert.strictEqual( fs.statSync( path.join( s.dir, s.files()[ 0 ] ) ).size, 8490 );
		// and each failure was a turn: four taken, so the fifth is refused
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 429 );
	} finally { await s.stop(); }
} );

test( 'a write that takes several goes is kept whole', async () => {
	const s = await start( { fs: failing( ( name, args ) => ( name === 'writeSync' ? fs.writeSync( args[ 0 ], args[ 1 ], args[ 2 ], Math.min( 1000, args[ 3 ] ) ) : undefined ) ) } );
	try {
		const bytes = ciphertext();
		assert.strictEqual( ( await post( s, body( bytes ) ) ).status, 204 );
		assert.ok( fs.readFileSync( path.join( s.dir, s.files()[ 0 ] ) ).equals( bytes ) );
	} finally { await s.stop(); }
} );

test( 'whatever fails while it is kept, nothing half-written is left', async () => {
	for ( const at of [ 'fsyncSync', 'linkSync', 'closeSync' ] ) {
		let once = true;
		const s = await start( { fs: failing( ( name ) => ( name === at && once ? ( once = false, errno( 'EIO' ) ) : undefined ) ) } );
		try {
			assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 500, at );
			assert.deepStrictEqual( s.files(), [], at );
			assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204, `${ at }: and it goes on` );
		} finally { await s.stop(); }
	}
} );

test( 'what a run that was stopped mid-write left behind is removed when the next one starts', async () => {
	const dir = fs.mkdtempSync( path.join( os.tmpdir(), 'offprint-store-' ) );
	try {
		fs.mkdirSync( path.join( dir, 's' ) );
		fs.writeFileSync( path.join( dir, 's', '.incoming-123-abcdef' ), 'half' );
		fs.writeFileSync( path.join( dir, 's', 'a'.repeat( 64 ) + '.age' ), 'kept' );
		fs.writeFileSync( path.join( dir, 's', 'notes.txt' ), 'left' );
		createStore( { dir: path.join( dir, 's' ), path: '/_pigeonhole' } ).close();
		assert.deepStrictEqual( fs.readdirSync( path.join( dir, 's' ) ).sort(), [ 'a'.repeat( 64 ) + '.age', 'notes.txt' ] );
	} finally { fs.rmSync( dir, { recursive: true, force: true } ); }
} );

test( 'a name taken by something that is not the submission is not called kept', async () => {
	const s = await start();
	try {
		const bytes = ciphertext(); const name = sha256( bytes ).toString( 'hex' ) + '.age';
		for ( const make of [ () => fs.symlinkSync( '/etc/hosts', path.join( s.dir, name ) ), () => fs.mkdirSync( path.join( s.dir, name ) ), () => fs.writeFileSync( path.join( s.dir, name ), bytes.subarray( 0, 4096 ) ) ] ) {
			make();
			assert.strictEqual( ( await post( s, body( bytes ), { address: `203.0.113.${ Math.floor( Math.random() * 250 ) }` } ) ).status, 500 );
			fs.rmSync( path.join( s.dir, name ), { recursive: true, force: true } );
		}
		s.server.report();
		assert.deepStrictEqual( s.said, [ 'pigeonhole: failed ETAKEN 3' ] );
		assert.strictEqual( ( await post( s, body( bytes ), { address: '198.51.100.1' } ) ).status, 204 );
	} finally { await s.stop(); }
} );

// A connection that sends the start of a submission and then nothing; ended by the test, or by the store.
function dawdler( s, address ) {
	return new Promise( ( ready ) => {
		const socket = net.connect( new URL( s.base ).port, '127.0.0.1', () => {
			socket.write( `POST /_pigeonhole HTTP/1.1\r\nHost: x\r\nX-Pigeonhole-Client: ${ address }\r\nContent-Length: 8498\r\n\r\nage-encryp` );
			setTimeout( () => ready( socket ), 150 );
		} );
		socket.on( 'data', () => {} ); socket.on( 'error', () => {} );
	} );
}

test( 'only so many of one sender\'s are read at once; another sender is not held up, and a place comes back', async () => {
	const s = await start( { atOnce: 2, headersWithin: 20000, allWithin: 20000 } );
	try {
		const slow = [ await dawdler( s, '2001:db8:9:9::1' ), await dawdler( s, '2001:db8:9:9::2' ) ];
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '2001:db8:9:9::3' } ) ).status, 429, 'a third from the same /64, while two are being read' );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.7' } ) ).status, 204, 'another sender' );
		slow[ 0 ].destroy();
		await new Promise( ( go ) => setTimeout( go, 150 ) );
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '2001:db8:9:9::3' } ) ).status, 204, 'one gave up: its place is free' );
		slow[ 1 ].destroy();
		s.server.report();
		assert.match( s.said[ 0 ], /at once 1/ );
	} finally { await s.stop(); }
} );

test( 'a body that comes a byte at a time takes no more room than a submission', async () => {
	const s = await start( { headersWithin: 20000, allWithin: 20000 } );
	try {
		const sent = body( ciphertext() );
		const status = await new Promise( ( done ) => {
			const socket = net.connect( new URL( s.base ).port, '127.0.0.1', async () => {
				socket.write( `POST /_pigeonhole HTTP/1.1\r\nHost: x\r\nX-Pigeonhole-Client: 203.0.113.7\r\nContent-Length: ${ sent.length }\r\n\r\n` );
				for ( let i = 0; i < sent.length; i += 97 ) { socket.write( sent.subarray( i, i + 97 ) ); await new Promise( ( go ) => setImmediate( go ) ); }
			} );
			let got = ''; socket.on( 'data', ( d ) => { got += d; } ); socket.on( 'close', () => done( got.slice( 9, 12 ) ) ); socket.on( 'error', () => {} );
		} );
		assert.strictEqual( status, '204' );
		assert.ok( fs.readFileSync( path.join( s.dir, s.files()[ 0 ] ) ).equals( sent.subarray( NONCE_BYTES ) ) );
	} finally { await s.stop(); }
} );

test( 'a request that asks for something first gets a bare answer too', async () => {
	const s = await start();
	try {
		const raw = await new Promise( ( done ) => {
			const socket = net.connect( new URL( s.base ).port, '127.0.0.1', () => socket.write( 'POST /_pigeonhole HTTP/1.1\r\nHost: x\r\nExpect: a-miracle\r\nContent-Length: 8498\r\n\r\n' ) );
			let got = ''; socket.on( 'data', ( d ) => { got += d; } ); socket.on( 'close', () => done( got ) ); socket.on( 'error', () => done( got ) );
		} );
		assert.match( raw, /^HTTP\/1\.1 417 / );
		assert.ok( /Content-Length: 0/i.test( raw ) && ! /chunked|keep-alive/i.test( raw ) );
	} finally { await s.stop(); }
} );

test( 'a clock that starts far ahead does not take everything held for old', async () => {
	const s = await start( { days: 30 } );
	try {
		fs.writeFileSync( path.join( s.dir, 'b'.repeat( 64 ) + '.age' ), 'held from before' );
		// the machine came up thinking it is next year; this run is seconds old
		s.clock.now = Date.now() + 400 * 24 * HOUR;
		const far = await start( { days: 30 } ); await far.stop();
		const late = createStore( { dir: s.dir, path: '/_pigeonhole', bits: 8, now: () => s.clock.now, say: () => {} } );
		await new Promise( ( go ) => late.listen( 0, '127.0.0.1', go ) );
		try {
			const r = await fetch( `http://127.0.0.1:${ late.address().port }/_pigeonhole`, { method: 'POST', body: body( ciphertext() ), headers: { 'x-pigeonhole-client': '203.0.113.7' } } );
			assert.strictEqual( r.status, 204 );
			assert.ok( fs.existsSync( path.join( s.dir, 'b'.repeat( 64 ) + '.age' ) ), 'still there, in the run\'s first minutes' );
		} finally { await new Promise( ( go ) => { late.close( go ); late.closeAllConnections(); } ); }
	} finally { await s.stop(); }
} );

test( 'everyone together may send so many an hour', async () => {
	const s = await start( { perHour: 4 } );
	try {
		for ( let i = 0; i < 4; i++ ) { assert.strictEqual( ( await post( s, body( ciphertext() ), { address: `203.0.113.${ i }` } ) ).status, 204 ); }
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.99' } ) ).status, 429 );
		s.clock.now += HOUR + 1;
		assert.strictEqual( ( await post( s, body( ciphertext() ), { address: '203.0.113.99' } ) ).status, 204 );
	} finally { await s.stop(); }
} );

test( 'a full store takes no more, until the owner has fetched', async () => {
	const s = await start( { quota: 3, perAddress: 100 } );
	try {
		for ( let i = 0; i < 3; i++ ) { assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 ); }
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 507 );
		assert.strictEqual( s.files().length, 3 );
		// the owner's fetch removes what it took, from outside; the store sees so at its next look
		for ( const name of s.files().slice( 0, 2 ) ) { fs.unlinkSync( path.join( s.dir, name ) ); }
		s.clock.now += 11000;
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 );
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 507 );
	} finally { await s.stop(); }
} );

test( 'what was never fetched is removed after its days, and nothing else in the folder is touched', async () => {
	const s = await start( { days: 30 } );
	try {
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 );
		const old = s.files()[ 0 ];
		fs.writeFileSync( path.join( s.dir, 'notes.txt' ), 'not a submission' );
		// the file's own time is the machine's, so the clock here is moved from now
		s.clock.now = Date.now() + 29 * 24 * HOUR;
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 );
		assert.ok( s.files().includes( old ), 'kept at 29 days' );
		s.clock.now = Date.now() + 31 * 24 * HOUR;
		assert.strictEqual( ( await post( s, body( ciphertext() ) ) ).status, 204 );
		assert.ok( ! s.files().includes( old ), 'gone at 31 days' );
		assert.ok( s.files().includes( 'notes.txt' ) );
	} finally { await s.stop(); }
} );

test( 'what it says is counts and reasons: never an address, a name or a byte of a body', async () => {
	const s = await start( { perAddress: 1 } );
	try {
		const bytes = ciphertext();
		await post( s, body( bytes ), { address: '203.0.113.77' } );
		await post( s, body( ciphertext() ), { address: '203.0.113.77' } );
		await post( s, Buffer.alloc( 5 ), { address: '203.0.113.78' } );
		await post( s, undefined, { method: 'GET', url: '/secret-looking-path' } );
		assert.deepStrictEqual( s.said, [], 'nothing is said as each one comes' );
		s.server.report();
		assert.deepStrictEqual( s.said, [ 'pigeonhole: address 1, elsewhere 1, kept 1, size 1' ] );
		s.server.report();
		assert.strictEqual( s.said.length, 1, 'and nothing when nothing happened' );
		const all = s.said.join( '\n' );
		assert.ok( ! all.includes( '203.0.113' ) && ! all.includes( 'secret' ) && ! all.includes( sha256( bytes ).toString( 'hex' ).slice( 0, 8 ) ) );
	} finally { await s.stop(); }
} );

test( 'a request that dawdles does not hold a place', async () => {
	// (as it runs: its headers within 3 seconds, all of it within 4, looked at every second; here, shorter)
	const s = await start( { headersWithin: 300, allWithin: 600, lookEvery: 100 } );
	try {
		const started = Date.now();
		const ended = await new Promise( ( done ) => {
			const socket = net.connect( new URL( s.base ).port, '127.0.0.1', () => socket.write( 'POST /_pigeonhole HTTP/1.1\r\nHost: x\r\nContent-Length: 8498\r\n\r\nage-encryp' ) );
			socket.on( 'data', () => {} ); socket.on( 'close', () => done( Date.now() - started ) ); socket.on( 'error', () => done( Date.now() - started ) );
		} );
		assert.ok( ended < 3000, `the connection was ended after ${ ended } ms` );
		assert.deepStrictEqual( s.files(), [] );
	} finally { await s.stop(); }
} );

test( 'settings that make no sense are refused before it listens', () => {
	const dir = fs.mkdtempSync( path.join( os.tmpdir(), 'offprint-store-' ) );
	try {
		const ok = { dir: path.join( dir, 's' ), path: '/_pigeonhole' };
		assert.throws( () => createStore( { ...ok, dir: 'relative/store' } ), /whole path/ );
		assert.throws( () => createStore( { ...ok, dir: undefined } ), /whole path/ );
		for ( const bad of [ '_pigeonhole', '/', '/a/b', '/A', '/a?b', undefined ] ) { assert.throws( () => createStore( { ...ok, path: bad } ), /slash and one name/ ); }
		for ( const name of [ 'bits', 'perAddress', 'perHour', 'quota', 'days', 'atOnce' ] ) {
			for ( const bad of [ 0, -1, 1.5, NaN, '18' ] ) { assert.throws( () => createStore( { ...ok, [ name ]: bad } ), /whole number above 0/ ); }
		}
		assert.throws( () => createStore( { ...ok, bits: 33 } ), /32 at most/ );
		for ( const bad of [ 'Not A Header', 'X-Upper', '', 'a:b', undefined ] ) { assert.throws( () => createStore( { ...ok, clientHeader: bad } ), /header's name/ ); }
	} finally { fs.rmSync( dir, { recursive: true, force: true } ); }
} );

test( 'as a program: it listens where it is told, takes a submission, and says so when it is stopped', async () => {
	const dir = fs.mkdtempSync( path.join( os.tmpdir(), 'offprint-store-' ) );
	const port = await new Promise( ( go ) => { const probe = net.createServer(); probe.listen( 0, '127.0.0.1', () => { const p = probe.address().port; probe.close( () => go( p ) ); } ); } );
	const child = spawn( process.execPath, [ STORE ], { env: { PATH: process.env.PATH, PIGEONHOLE_STORE: path.join( dir, 's' ), PIGEONHOLE_LISTEN: `127.0.0.1:${ port }`, PIGEONHOLE_PATH: '/_pigeonhole', PIGEONHOLE_BITS: '8' } } );
	let out = '';
	child.stdout.on( 'data', ( d ) => { out += d; } ); child.stderr.on( 'data', ( d ) => { out += d; } );
	try {
		for ( let i = 0; i < 100 && ! out.includes( 'taking' ); i++ ) { await new Promise( ( go ) => setTimeout( go, 50 ) ); }
		assert.match( out, new RegExp( `^pigeonhole: taking /_pigeonhole on 127\\.0\\.0\\.1:${ port }\\n` ) );
		const r = await fetch( `http://127.0.0.1:${ port }/_pigeonhole`, { method: 'POST', body: body( ciphertext() ), headers: { 'x-pigeonhole-client': '203.0.113.7' } } );
		assert.strictEqual( r.status, 204 );
		assert.strictEqual( fs.readdirSync( path.join( dir, 's' ) ).length, 1 );
	} finally {
		child.kill( 'SIGTERM' );
		await new Promise( ( go ) => child.on( 'close', go ) );
		fs.rmSync( dir, { recursive: true, force: true } );
	}
	assert.match( out, /\npigeonhole: kept 1\n$/ );
	assert.ok( ! out.includes( '203.0.113' ) );
} );

test( 'as a program: without its settings it says what it needs, and does not start', async () => {
	const whole = { PIGEONHOLE_STORE: os.tmpdir() + '/offprint-never', PIGEONHOLE_PATH: '/_pigeonhole' };
	for ( const env of [ {}, { PIGEONHOLE_LISTEN: '127.0.0.1:1' }, { ...whole, PIGEONHOLE_LISTEN: '127.0.0.1:99999' }, { ...whole, PIGEONHOLE_LISTEN: '127.0.0.1:0' }, { ...whole, PIGEONHOLE_LISTEN: '0.0.0.0:8788' }, { ...whole, PIGEONHOLE_LISTEN: '[::]:8788' }, { ...whole, PIGEONHOLE_LISTEN: '1:8788' }, { ...whole, PIGEONHOLE_LISTEN: 'store.example.com:8788' }, { ...whole, PIGEONHOLE_LISTEN: '127.0.0.1:8788', PIGEONHOLE_CLIENT_HEADER: 'Not A Header' }, { PIGEONHOLE_LISTEN: 'not-a-port', PIGEONHOLE_STORE: '/tmp/x', PIGEONHOLE_PATH: '/_pigeonhole' }, { PIGEONHOLE_LISTEN: '127.0.0.1:1', PIGEONHOLE_STORE: os.tmpdir() + '/offprint-never', PIGEONHOLE_PATH: '/_pigeonhole', PIGEONHOLE_BITS: 'many' } ] ) {
		const child = spawn( process.execPath, [ STORE ], { env: { PATH: process.env.PATH, ...env } } );
		let err = ''; child.stderr.on( 'data', ( d ) => { err += d; } );
		const code = await new Promise( ( go ) => child.on( 'close', go ) );
		assert.strictEqual( code, 2 );
		assert.match( err, /^pigeonhole: [^\n]+\n$/, 'one line of its own, not a stack of node\'s' );
	}
	assert.ok( ! fs.existsSync( os.tmpdir() + '/offprint-never' ) );
} );

test( 'what the page\'s own script posts, as built and committed, is what the store takes', async () => {
	const s = await start( { bits: 18 } );
	const copy = path.join( fs.mkdtempSync( path.join( os.tmpdir(), 'offprint-pigeonhole-' ) ), 'pigeonhole.mjs' );
	fs.copyFileSync( path.join( ROOT, 'plugin/offprint/pigeonhole.js' ), copy );
	try {
		const { seal } = await import( copy );
		const t = await import( path.join( ROOT, 'pigeonhole/browser/src/transport.js' ) );
		const { fields } = t.commentFields( { comment_post_ID: '4', comment: 'A comment.', author: 'Ada', email: 'ada@example.com' }, 42 );
		const plain = t.padded( t.envelope( 'comment', fields, { page: '/hello/' } ) );
		for ( const recipients of [ [ 'age1ajjp3mu9nznj5y0gk0hye0v75kcqeda3rq9q0az204f2pp6vtpese0l39k' ], [ 'age1ajjp3mu9nznj5y0gk0hye0v75kcqeda3rq9q0az204f2pp6vtpese0l39k', 'age1lcn5lw0px559ch6rctd5wj8t27d7vqasc0xd4wl85f48zlth75nsru089h' ] ] ) {
			const sealed = await seal( plain, recipients );
			const sent = await t.body( sealed, 18 );
			// through the script's own send, pointed at the store, the visitor's address named as the web server names it
			const forwarded = ( url, init ) => fetch( url, { ...init, headers: { 'x-pigeonhole-client': '2001:db8::7' } } );
			assert.strictEqual( await t.send( s.base + '/_pigeonhole', sent, forwarded ), true );
			const name = sha256( Buffer.from( sealed ) ).toString( 'hex' ) + '.age';
			assert.ok( fs.readFileSync( path.join( s.dir, name ) ).equals( Buffer.from( sealed ) ) );
		}
		assert.strictEqual( s.files().length, 2 );
	} finally { await s.stop(); fs.rmSync( path.dirname( copy ), { recursive: true, force: true } ); }
} );
