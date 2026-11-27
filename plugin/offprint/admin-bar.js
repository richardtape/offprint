/**
 * The "Publish Site" node in the admin bar: keeps it current while a publish runs or is waiting.
 *
 * Printed inline by Offprint\Admin_Bar (no build step, no extra request), after a script that sets
 * window.offprintAdminBar to { url, action, nonce, interval, slow, poll }. It asks the status action
 * every `interval` milliseconds while something runs or waits (every `slow` once that looks stuck), and
 * stops when there is nothing to wait for (the view's `poll` is false: a publish that ended live, unchanged,
 * saved or failed, whatever its state is called), when it is refused (logged out, or the nonce has expired), or
 * after three failed tries in a row. In the block editor, where the page stays put while posts are saved,
 * it also looks again after each save. Everything from the server goes into the page as text, never as HTML.
 * For a site that takes comments the answer has a `comments` part too ({ label, lines }): how many wait to be
 * checked, beside the title, and the lines above the "Check for comments" button. The view's `poll` is true while
 * a check for comments is waiting as well, so the node follows it to its end the same way.
 *
 * Tested by tests/admin-bar.test.js (node --test).
 */
( function ( config ) {
	'use strict';

	if ( ! config || ! config.url ) {
		return;
	}

	var timer = 0;
	var failures = 0;
	var busy = !! config.poll;
	var tones = [ 'offprint-live', 'offprint-busy', 'offprint-failed', 'offprint-idle' ];

	function later( wait ) {
		window.clearTimeout( timer );
		timer = window.setTimeout( check, wait );
	}

	function render( view ) {
		var node = document.getElementById( 'wp-admin-bar-offprint' );
		var list = node && node.querySelector( '.ab-submenu' );
		var button = document.getElementById( 'wp-admin-bar-offprint-now' );
		var label = node && node.querySelector( '.offprint-label' );
		if ( ! node || ! list || ! button || ! label ) {
			return;
		}
		if ( label.textContent !== view.title ) {
			label.textContent = view.title;
		}
		tones.forEach( function ( tone ) {
			node.classList.remove( tone );
		} );
		node.classList.add( 'offprint-' + view.tone );
		lines( list, 'offprint-line', view.lines, button );
		if ( view.comments ) {
			var count = node.querySelector( '.offprint-count' );
			var collect = document.getElementById( 'wp-admin-bar-offprint-collect' );
			if ( count && count.textContent !== view.comments.label ) {
				count.textContent = view.comments.label;
			}
			if ( collect ) {
				lines( list, 'offprint-comments-line', view.comments.lines, collect );
			}
		}
	}

	// The lines of one kind (a class name) under the node, replaced by these texts, just above one of its buttons.
	function lines( list, name, texts, before ) {
		Array.prototype.forEach.call( list.querySelectorAll( '.' + name ), function ( old ) {
			old.parentNode.removeChild( old );
		} );
		( texts || [] ).forEach( function ( text ) {
			var item = document.createElement( 'li' );
			var line = document.createElement( 'div' );
			item.className = name;
			item.setAttribute( 'role', 'group' );
			line.className = 'ab-item ab-empty-item';
			line.setAttribute( 'role', 'menuitem' );
			line.textContent = text;
			item.appendChild( line );
			list.insertBefore( item, before );
		} );
	}

	function check() {
		var url = config.url + '?action=' + encodeURIComponent( config.action ) + '&nonce=' + encodeURIComponent( config.nonce );
		window.fetch( url, { credentials: 'same-origin', headers: { Accept: 'application/json' } } )
			.then( function ( response ) {
				return response.ok ? response.json() : null;
			} )
			.then( function ( answer ) {
				failures = 0;
				// Refused: stop, leaving the node as it is.
				if ( ! answer || ! answer.success ) {
					return;
				}
				render( answer.data );
				// After a busy answer, one more look before stopping: between the Mac taking a request and
				// bin/publish writing its first status, the status still says how the last publish ended.
				if ( answer.data.poll || busy ) {
					later( answer.data.stuck ? config.slow : config.interval );
				}
				busy = !! answer.data.poll;
			} )
			.catch( function () {
				// The network or WordPress blinked: try again, but not forever.
				failures++;
				if ( failures < 3 ) {
					later( config.interval );
				}
			} );
	}

	function start() {
		var data = window.wp && window.wp.data;
		var saving = false;
		if ( config.poll ) {
			later( config.interval );
		}
		if ( ! data || ! data.subscribe || ! data.select || ! data.select( 'core/editor' ) ) {
			return;
		}
		data.subscribe( function () {
			var editor = data.select( 'core/editor' );
			var now = !! ( editor && editor.isSavingPost() && ! editor.isAutosavingPost() );
			if ( saving && ! now ) {
				later( 1000 );
			}
			saving = now;
		} );
	}

	if ( 'loading' === document.readyState ) {
		document.addEventListener( 'DOMContentLoaded', start );
	} else {
		start();
	}
}( window.offprintAdminBar ) );
