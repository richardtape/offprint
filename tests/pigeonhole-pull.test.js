// Tests pigeonhole/server/pull.js, the one command the owner's Mac may run on a site's store: list what is held, take
// one, remove one, and nothing else whatever is asked. Each test has a folder of its own. The command is run both as a
// function and as sshd runs it: a process, with what was asked for in SSH_ORIGINAL_COMMAND.
// Run: node --test tests/pigeonhole-pull.test.js   (CI runs every *.test.js this way)
'use strict';

const { test } = require( 'node:test' );
const assert = require( 'node:assert' );
const fs = require( 'node:fs' );
const os = require( 'node:os' );
const path = require( 'node:path' );
const crypto = require( 'node:crypto' );
const { spawnSync } = require( 'node:child_process' );

const PULL = path.join( __dirname, '..', 'pigeonhole/server/pull.js' );
const { pull, MAX_BYTES, MAX_LISTED } = require( PULL );

function folder() {
	const dir = fs.mkdtempSync( path.join( os.tmpdir(), 'offprint-pull-' ) );
	test.after( () => fs.rmSync( dir, { recursive: true, force: true } ) );
	return dir;
}
// A file as the store keeps one: its name the sha256 of its bytes. Returns the name. AGE: how many seconds old.
function keep( dir, bytes = crypto.randomBytes( 8392 ), age = 0 ) {
	const name = crypto.createHash( 'sha256' ).update( bytes ).digest( 'hex' ) + '.age';
	fs.writeFileSync( path.join( dir, name ), bytes );
	const at = Date.now() / 1000 - age;
	fs.utimesSync( path.join( dir, name ), at, at );
	return name;
}
// What ASKED gets: { status, out (a Buffer), err }.
function ask( dir, asked ) {
	const out = [];
	let err = '';
	const status = pull( dir, asked, ( b ) => out.push( Buffer.from( b ) ), ( t ) => { err += t; } );
	return { status, out: Buffer.concat( out ), err };
}
// The same, as sshd runs it.
function run( dir, asked, args ) {
	const env = { PATH: process.env.PATH };
	if ( asked !== undefined ) { env.SSH_ORIGINAL_COMMAND = asked; }
	const r = spawnSync( process.execPath, [ PULL, ...( args || [ dir ] ) ], { env } );
	return { status: r.status, out: r.stdout, err: r.stderr.toString() };
}
const NAME_A = 'a'.repeat( 64 ) + '.age';

test( 'list: the names held, one a line, oldest first; nothing else in the folder is named', () => {
	const dir = folder();
	const newer = keep( dir, undefined, 10 );
	const older = keep( dir, undefined, 500 );
	fs.writeFileSync( path.join( dir, '.incoming-1-abc' ), 'half' );
	fs.writeFileSync( path.join( dir, 'notes.txt' ), 'x' );
	fs.writeFileSync( path.join( dir, 'A'.repeat( 64 ) + '.age' ), 'capitals' );
	fs.mkdirSync( path.join( dir, 'b'.repeat( 64 ) + '.age' ) );
	fs.symlinkSync( path.join( dir, older ), path.join( dir, 'c'.repeat( 64 ) + '.age' ) );
	fs.writeFileSync( path.join( dir, 'd'.repeat( 64 ) + '.age' ), Buffer.alloc( MAX_BYTES + 1 ) );
	const r = ask( dir, 'list' );
	assert.strictEqual( r.status, 0 );
	assert.strictEqual( r.out.toString(), older + '\n' + newer + '\n' );
	assert.strictEqual( r.err, '' );
} );

test( 'list: an empty store is an empty answer, and no more than 500 names are given at a time', () => {
	const dir = folder();
	assert.deepStrictEqual( [ ask( dir, 'list' ).status, ask( dir, 'list' ).out.length ], [ 0, 0 ] );
	for ( let i = 0; i < MAX_LISTED + 5; i++ ) { keep( dir, crypto.randomBytes( 16 ), i ); }
	const names = ask( dir, 'list' ).out.toString().trim().split( '\n' );
	assert.strictEqual( names.length, MAX_LISTED );
	assert.ok( names.every( ( n ) => /^[0-9a-f]{64}\.age$/.test( n ) ) );
} );

test( 'get: the file\'s bytes, exactly, and the file stays', () => {
	const dir = folder();
	const bytes = crypto.randomBytes( 8490 );
	const name = keep( dir, bytes );
	const r = ask( dir, 'get ' + name );
	assert.strictEqual( r.status, 0 );
	assert.ok( r.out.equals( bytes ) );
	assert.ok( fs.existsSync( path.join( dir, name ) ) );
} );

test( 'get: no such file, a link, a folder, or one too large to be a submission is "gone" (3), and gives nothing', () => {
	const dir = folder();
	const outside = path.join( folder(), 'secret' );
	fs.writeFileSync( outside, 'OUTSIDE' );
	const link = 'c'.repeat( 64 ) + '.age';
	fs.symlinkSync( outside, path.join( dir, link ) );
	const sub = 'b'.repeat( 64 ) + '.age';
	fs.mkdirSync( path.join( dir, sub ) );
	const big = 'd'.repeat( 64 ) + '.age';
	fs.writeFileSync( path.join( dir, big ), Buffer.alloc( MAX_BYTES + 1 ) );
	for ( const name of [ NAME_A, link, sub, big ] ) {
		const r = ask( dir, 'get ' + name );
		assert.deepStrictEqual( [ r.status, r.out.length, r.err ], [ 3, 0, 'gone\n' ], name );
	}
} );

test( 'delete: removes that file and no other; one that is gone already is done', () => {
	const dir = folder();
	const a = keep( dir );
	const b = keep( dir );
	assert.strictEqual( ask( dir, 'delete ' + a ).status, 0 );
	assert.deepStrictEqual( fs.readdirSync( dir ), [ b ] );
	assert.strictEqual( ask( dir, 'delete ' + a ).status, 0 );
	assert.deepStrictEqual( fs.readdirSync( dir ), [ b ] );
} );

test( 'delete: a folder or a link under a submission\'s name is not removed, nor what a link leads to', () => {
	const dir = folder();
	const outside = path.join( folder(), 'kept' );
	fs.writeFileSync( outside, 'OUTSIDE' );
	const link = 'c'.repeat( 64 ) + '.age';
	fs.symlinkSync( outside, path.join( dir, link ) );
	const sub = 'b'.repeat( 64 ) + '.age';
	fs.mkdirSync( path.join( dir, sub ) );
	assert.strictEqual( ask( dir, 'delete ' + link ).status, 4 );
	assert.strictEqual( ask( dir, 'delete ' + sub ).status, 4 );
	assert.ok( fs.existsSync( outside ) && fs.lstatSync( path.join( dir, link ) ).isSymbolicLink() && fs.existsSync( path.join( dir, sub ) ) );
} );

test( 'anything but the three is refused (2), and nothing is read, written or removed', () => {
	const dir = folder();
	const name = keep( dir );
	fs.writeFileSync( path.join( dir, 'notes.txt' ), 'x' );
	const before = fs.readdirSync( dir ).sort();
	const asks = [
		undefined, '', 'ls', 'LIST', 'list ', ' list', 'list\n', 'list; id', 'list ' + name, 'get', 'get ', 'delete',
		'get notes.txt', 'get ../' + name, 'get /etc/passwd', 'get ' + name + ' ' + name, 'get ' + name + '\n',
		'get ' + name + '/', 'get ./' + name, 'get ' + name.toUpperCase(), 'get  ' + name, 'get\t' + name,
		'get ' + name.slice( 1 ), 'get ' + name + 'x', 'delete *', 'delete ' + name + ' -rf', 'delete .incoming-1',
		'delete ../' + name, 'put ' + name, 'cat ' + name, 'scp -t .', 'sh', 'node -e 1', 'get ' + name + '\0', '\0list',
		'x'.repeat( 5000 ), 7, null, [ 'list' ],
	];
	for ( const asked of asks ) {
		const r = ask( dir, asked );
		assert.deepStrictEqual( [ r.status, r.out.length, r.err ], [ 2, 0, 'refused\n' ], JSON.stringify( asked ) );
	}
	assert.deepStrictEqual( fs.readdirSync( dir ).sort(), before );
} );

test( 'a store that is not a whole path, or is not there, is refused', () => {
	assert.strictEqual( ask( 'store', 'list' ).status, 2 );
	assert.strictEqual( ask( null, 'list' ).status, 2 );
	assert.strictEqual( ask( path.join( folder(), 'none' ), 'list' ).status, 2 );
	assert.strictEqual( ask( path.join( folder(), 'none' ), 'get ' + NAME_A ).status, 3 );
} );

test( 'what it says of a failure is one fixed word: never a path, a name or what was asked', () => {
	const dir = folder();
	const name = keep( dir );
	for ( const asked of [ 'get ' + NAME_A, 'cat /etc/passwd MARKER', 'delete ' + 'b'.repeat( 64 ) + '.age' ] ) {
		const r = ask( dir, asked );
		assert.match( r.err, /^(|gone\n|refused\n|failed\n|no store\n)$/ );
	}
	assert.ok( name );
} );

test( 'as sshd runs it: the asked-for word comes from SSH_ORIGINAL_COMMAND, and a get is whole', () => {
	const dir = folder();
	const bytes = crypto.randomBytes( 8392 );
	const name = keep( dir, bytes );
	let r = run( dir, 'list' );
	assert.deepStrictEqual( [ r.status, r.out.toString() ], [ 0, name + '\n' ] );
	r = run( dir, 'get ' + name );
	assert.strictEqual( r.status, 0 );
	assert.ok( r.out.equals( bytes ) );
	r = run( dir, 'delete ' + name );
	assert.strictEqual( r.status, 0 );
	assert.deepStrictEqual( fs.readdirSync( dir ), [] );
	r = run( dir, 'get ' + name );
	assert.deepStrictEqual( [ r.status, r.err ], [ 3, 'gone\n' ] );
} );

test( 'as sshd runs it: no word asked for (a bare login), a shell\'s words, or arguments of its own get nothing', () => {
	const dir = folder();
	const name = keep( dir );
	assert.strictEqual( run( dir, undefined ).status, 2 );
	assert.strictEqual( run( dir, 'list && cat ' + name ).status, 2 );
	assert.strictEqual( run( dir, '$(id)' ).status, 2 );
	// the folder is the one argument the forced command gives it; with none, or more, it does nothing
	assert.strictEqual( run( dir, 'list', [] ).status, 2 );
	assert.strictEqual( run( dir, 'list', [ dir, 'list' ] ).status, 2 );
	assert.ok( fs.existsSync( path.join( dir, name ) ) );
} );
