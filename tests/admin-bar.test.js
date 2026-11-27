// Tests plugin/offprint/admin-bar.js, the script that keeps the admin bar's
// "Publish Site" node current, against a small fake page: just the DOM, timers and fetch it uses.
// Run: node --test tests/admin-bar.test.js   (CI runs every *.test.js this way)
'use strict';

const { test } = require( 'node:test' );
const assert = require( 'node:assert' );
const fs = require( 'node:fs' );
const path = require( 'node:path' );
const vm = require( 'node:vm' );

const SCRIPT = fs.readFileSync( path.join( __dirname, '../plugin/offprint/admin-bar.js' ), 'utf8' );

function element( tag ) {
	const classes = new Set();
	return {
		tag,
		id: '',
		className: '',
		children: [],
		parentNode: null,
		attributes: {},
		text: '',
		classList: { add: ( c ) => classes.add( c ), remove: ( c ) => classes.delete( c ), has: ( c ) => classes.has( c ) },
		setAttribute( name, value ) {
			this.attributes[ name ] = value;
		},
		appendChild( child ) {
			child.parentNode = this;
			this.children.push( child );
			return child;
		},
		insertBefore( child, before ) {
			const at = this.children.indexOf( before );
			child.parentNode = this;
			this.children.splice( at < 0 ? this.children.length : at, 0, child );
			return child;
		},
		removeChild( child ) {
			this.children.splice( this.children.indexOf( child ), 1 );
			child.parentNode = null;
			return child;
		},
		get textContent() {
			return this.text;
		},
		set textContent( value ) {
			this.text = String( value );
		},
		querySelectorAll( selector ) {
			const name = selector.slice( 1 );
			const found = [];
			( function walk( node ) {
				node.children.forEach( ( child ) => {
					if ( ( ' ' + child.className + ' ' ).includes( ' ' + name + ' ' ) ) {
						found.push( child );
					}
					walk( child );
				} );
			} )( this );
			return found;
		},
		querySelector( selector ) {
			return this.querySelectorAll( selector )[ 0 ] || null;
		},
	};
}

// A page with the node as Admin_Bar renders it, one old line under it; timers and fetch driven by hand.
function page( config, options = {} ) {
	const node = element( 'li' );
	node.classList.add( 'menupop' );
	node.classList.add( 'offprint-busy' );
	const label = element( 'span' );
	label.className = 'offprint-label';
	label.textContent = 'Publish requested…';
	node.appendChild( label );
	const list = element( 'ul' );
	list.className = 'ab-submenu';
	node.appendChild( list );
	const old = element( 'li' );
	old.className = 'offprint-line';
	list.appendChild( old );
	const button = element( 'li' );
	list.appendChild( button );
	// for a site that takes comments: the count beside the title, one old line, and the second button
	let count = null;
	let collect = null;
	if ( options.comments ) {
		count = element( 'span' );
		count.className = 'offprint-count';
		count.textContent = ' · 1 comment to check';
		node.appendChild( count );
		const oldComment = element( 'li' );
		oldComment.className = 'offprint-comments-line';
		list.appendChild( oldComment );
		collect = element( 'li' );
		list.appendChild( collect );
	}

	const timers = [];
	const fetched = [];
	const answers = [];
	const listeners = {};
	const document = {
		readyState: options.loading ? 'loading' : 'complete',
		getElementById: ( id ) => ( { 'wp-admin-bar-offprint': node, 'wp-admin-bar-offprint-now': button, 'wp-admin-bar-offprint-collect': collect }[ id ] || null ),
		createElement: element,
		addEventListener: ( type, listener ) => {
			listeners[ type ] = listener;
		},
	};
	const window = {
		offprintAdminBar: config,
		wp: options.wp,
		setTimeout: ( callback, wait ) => timers.push( { callback, wait } ),
		clearTimeout: ( id ) => {
			if ( id ) {
				timers[ id - 1 ] = null;
			}
		},
		fetch: ( url, init ) => {
			fetched.push( { url, init } );
			const answer = answers.shift();
			if ( answer instanceof Error ) {
				return Promise.reject( answer );
			}
			return Promise.resolve( { ok: answer.ok !== false, json: () => Promise.resolve( answer.body ) } );
		},
	};
	vm.runInNewContext( SCRIPT, { window, document } );
	return {
		node,
		label,
		list,
		button,
		count,
		collect,
		fetched,
		listeners,
		// the timer waiting now, if any
		peek() {
			return timers.filter( Boolean ).pop();
		},
		// the same, and forget the rest
		next() {
			const timer = timers.filter( Boolean ).pop();
			timers.length = 0;
			return timer;
		},
		// runs the waiting check with this answer, and lets its promises settle
		async answer( answer ) {
			const timer = this.next();
			assert.ok( timer, 'a check is waiting' );
			answers.push( answer );
			timer.callback();
			await new Promise( ( resolve ) => setImmediate( resolve ) );
			await new Promise( ( resolve ) => setImmediate( resolve ) );
			return timer;
		},
	};
}

const CONFIG = { url: 'https://wp.local/wp-admin/admin-ajax.php', action: 'offprint_status', nonce: 'n&1', interval: 5000, slow: 60000, poll: true };
const view = ( fields ) => ( { body: { success: true, data: Object.assign( { title: 'Live · 2:32 pm', tone: 'live', poll: false, stuck: false, lines: [] }, fields ) } } );

test( 'polls every 5 seconds while busy, and updates the node as text', async () => {
	const p = page( CONFIG );
	const timer = await p.answer( view( { title: 'Publishing… (checking)', tone: 'busy', poll: true, lines: [ '<b>x</b>', 'second' ] } ) );
	assert.strictEqual( timer.wait, 5000 );
	assert.strictEqual( p.fetched[ 0 ].url, 'https://wp.local/wp-admin/admin-ajax.php?action=offprint_status&nonce=n%261' );
	assert.strictEqual( p.fetched[ 0 ].init.credentials, 'same-origin' );
	assert.strictEqual( p.label.textContent, 'Publishing… (checking)' );
	const lines = p.list.children.filter( ( child ) => child.className === 'offprint-line' );
	assert.deepStrictEqual( lines.map( ( line ) => line.children[ 0 ].textContent ), [ '<b>x</b>', 'second' ], 'as text, the old line gone' );
	assert.strictEqual( p.list.children[ p.list.children.length - 1 ], p.button, 'the button stays last' );
	assert.ok( p.node.classList.has( 'offprint-busy' ) && p.node.classList.has( 'menupop' ) );
	assert.strictEqual( p.next().wait, 5000, 'and keeps polling' );
} );

test( 'looks once more after a busy answer, then stops', async () => {
	const p = page( CONFIG );
	await p.answer( view( { title: 'Publishing…', tone: 'busy', poll: true } ) );
	await p.answer( view() );
	assert.strictEqual( p.label.textContent, 'Live · 2:32 pm' );
	assert.ok( p.node.classList.has( 'offprint-live' ) && ! p.node.classList.has( 'offprint-busy' ), 'the tone is swapped' );
	await p.answer( view() );
	assert.strictEqual( p.next(), undefined, 'stops when it is still idle' );
} );

test( 'a publish that ends saved (a site with no host) is finished: shown, then no more looks', async () => {
	const p = page( CONFIG );
	await p.answer( view( { title: 'Publishing… (pushing)', tone: 'busy', poll: true } ) );
	await p.answer( view( { title: 'Saved · 2:32 pm', tone: 'live', state: 'saved', lines: [ 'Committed and pushed a1b2c3d; this site has no host set up (site.json "adapter").' ] } ) );
	assert.strictEqual( p.label.textContent, 'Saved · 2:32 pm' );
	assert.ok( p.node.classList.has( 'offprint-live' ) && ! p.node.classList.has( 'offprint-busy' ) );
	const lines = p.list.children.filter( ( child ) => child.className === 'offprint-line' );
	assert.deepStrictEqual( lines.map( ( line ) => line.children[ 0 ].textContent ), [ 'Committed and pushed a1b2c3d; this site has no host set up (site.json "adapter").' ] );
	await p.answer( view( { title: 'Saved · 2:32 pm', tone: 'live', state: 'saved' } ) );
	assert.strictEqual( p.next(), undefined, 'stops' );
} );

test( 'sees a publish that starts just after the Mac took the request', async () => {
	const p = page( CONFIG );
	await p.answer( view( { title: 'Live · old' } ) );
	await p.answer( view( { title: 'Publishing… (exporting)', tone: 'busy', poll: true } ) );
	assert.strictEqual( p.label.textContent, 'Publishing… (exporting)' );
	assert.ok( p.next() );
} );

test( 'polls once a minute while stuck', async () => {
	const p = page( CONFIG );
	await p.answer( view( { title: 'Publish may be stuck', tone: 'failed', poll: true, stuck: true } ) );
	assert.strictEqual( p.next().wait, 60000 );
} );

test( 'stops when refused (logged out, or the nonce expired)', async () => {
	const p = page( CONFIG );
	await p.answer( { ok: false, body: null } );
	assert.strictEqual( p.next(), undefined );
	const q = page( CONFIG );
	await q.answer( { body: { success: false } } );
	assert.strictEqual( q.next(), undefined );
} );

test( 'gives up after three failures in a row', async () => {
	const p = page( CONFIG );
	let tries = 0;
	while ( p.peek() && tries < 10 ) {
		await p.answer( new Error( 'offline' ) );
		tries++;
	}
	assert.strictEqual( tries, 3 );
} );

test( 'does nothing at load when nothing runs or waits', () => {
	const p = page( Object.assign( {}, CONFIG, { poll: false } ) );
	assert.strictEqual( p.next(), undefined );
	assert.strictEqual( p.fetched.length, 0 );
} );

test( 'does nothing without its config', () => {
	const p = page( undefined );
	assert.strictEqual( p.next(), undefined );
} );

test( 'in the block editor, looks again a second after a save, not after an autosave', () => {
	const editor = { saving: false, auto: false };
	let listener;
	const wp = {
		data: {
			subscribe: ( callback ) => {
				listener = callback;
			},
			select: ( store ) => ( 'core/editor' === store ? { isSavingPost: () => editor.saving, isAutosavingPost: () => editor.auto } : undefined ),
		},
	};
	const p = page( Object.assign( {}, CONFIG, { poll: false } ), { wp } );
	editor.saving = true;
	listener();
	editor.saving = false;
	listener();
	assert.strictEqual( p.next().wait, 1000 );
	editor.saving = true;
	editor.auto = true;
	listener();
	editor.saving = false;
	editor.auto = false;
	listener();
	assert.strictEqual( p.next(), undefined );
} );

test( 'waits for the page when it is still loading', () => {
	const p = page( CONFIG, { loading: true } );
	assert.strictEqual( p.next(), undefined );
	p.listeners.DOMContentLoaded();
	assert.ok( p.next() );
} );

test( 'comments: the count beside the title and the lines above their button are kept current, as text', async () => {
	const p = page( CONFIG, { comments: true } );
	await p.answer( view( { poll: true, lines: [ 'Commit abc1234' ], comments: { count: 3, label: ' · 3 comments to check', pending: true, stuck: false, lines: [ 'Comments: checking…', '<b>3</b> have arrived' ] } } ) );
	assert.strictEqual( p.count.textContent, ' · 3 comments to check' );
	const kinds = p.list.children.map( ( child ) => child.className || ( child === p.button ? 'publish button' : 'collect button' ) );
	assert.deepStrictEqual( kinds, [ 'offprint-line', 'publish button', 'offprint-comments-line', 'offprint-comments-line', 'collect button' ] );
	assert.deepStrictEqual( p.list.children.filter( ( c ) => c.className === 'offprint-comments-line' ).map( ( c ) => c.children[ 0 ].textContent ), [ 'Comments: checking…', '<b>3</b> have arrived' ] );
	assert.strictEqual( p.list.children[ 0 ].children[ 0 ].textContent, 'Commit abc1234' );
	assert.strictEqual( p.peek().wait, 5000, 'it goes on looking while a check is waiting' );
} );

test( 'comments: when none wait the count is emptied, and the old lines go', async () => {
	const p = page( CONFIG, { comments: true } );
	await p.answer( view( { comments: { count: 0, label: '', pending: false, stuck: false, lines: [ 'Comments: none waiting to be checked.' ] } } ) );
	assert.strictEqual( p.count.textContent, '' );
	assert.deepStrictEqual( p.list.children.filter( ( c ) => c.className === 'offprint-comments-line' ).map( ( c ) => c.children[ 0 ].textContent ), [ 'Comments: none waiting to be checked.' ] );
} );

test( 'comments: an answer with no comments part (a site that takes none) leaves that part of the node alone', async () => {
	const p = page( CONFIG, { comments: true } );
	await p.answer( view( { lines: [ 'one' ] } ) );
	assert.strictEqual( p.count.textContent, ' · 1 comment to check' );
	assert.strictEqual( p.list.children.filter( ( c ) => c.className === 'offprint-comments-line' ).length, 1 );
} );

test( 'comments: a page without the comments part (a user who may not moderate) is not broken by an answer that has one', async () => {
	const p = page( CONFIG );
	await p.answer( view( { lines: [ 'one' ], comments: { count: 2, label: ' · 2 comments to check', pending: false, stuck: false, lines: [ 'x' ] } } ) );
	assert.deepStrictEqual( p.list.children.map( ( c ) => c.className ), [ 'offprint-line', '' ] );
} );
