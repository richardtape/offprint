<?php
/**
 * Run by tests/e2e.sh in the throwaway WordPress: `wp eval-file - MODE [ARGS] [--user=LOGIN]`.
 *   bar [INBOX]            the offprint admin-bar node as the current user sees it: "title:",
 *                          "tone:", a "line:" for each line under it, "button:", and each one's "raw:" HTML;
 *                          with OFFPRINT_INBOX set to INBOX if given. For a site that takes comments, also
 *                          "count:" (what stands beside the title), a "comments:" for each line about them, and
 *                          "collect:" (the second button)
 *   request INBOX REASON   Request::request( REASON ), with OFFPRINT_INBOX set to INBOX
 *   auth LOGIN             a Cookie header that logs LOGIN in to wp-admin, then that session's nonces
 *                          for the request button, for the status, for the REST API, and for the
 *                          Check for comments button
 * Any PHP notice, warning or deprecation is printed as a "php:" line, so the test can fail on it.
 */
set_error_handler(
	static function ( int $level, string $message, string $file, int $line ): bool {
		echo "php: $message ($file:$line)\n";
		return true;
	}
);
$text = static fn ( string $html ): string => html_entity_decode( wp_strip_all_tags( $html ), ENT_QUOTES | ENT_HTML5, 'UTF-8' );

switch ( $args[0] ?? '' ) {
	case 'bar':
		if ( ! empty( $args[1] ) ) {
			define( 'OFFPRINT_INBOX', $args[1] );
		}
		require_once ABSPATH . WPINC . '/class-wp-admin-bar.php';
		$bar = new WP_Admin_Bar();
		Offprint\Admin_Bar::admin_bar_menu( $bar );
		$node = $bar->get_node( 'offprint' );
		if ( ! $node ) {
			echo "no node\n";
			break;
		}
		preg_match( '#<span class="offprint-label"[^>]*>(.*?)</span>#s', $node->title, $label );
		preg_match( '/\boffprint-(live|busy|failed|idle)\b/', $node->meta['class'] ?? '', $tone );
		echo 'title: ', $text( $label[1] ?? '' ), "\n", 'tone: ', $tone[1] ?? '', "\n", 'raw: ', $node->title, "\n";
		if ( preg_match( '#<span class="offprint-count"[^>]*>(.*?)</span>#s', $node->title, $count ) ) {
			echo 'count: ', $text( $count[1] ), "\n";
		}
		foreach ( $bar->get_nodes() as $child ) {
			if ( 'offprint' === $child->parent ) {
				$kind = 'offprint-now' === $child->id ? 'button' : ( 'offprint-collect' === $child->id ? 'collect' : ( 0 === strpos( $child->id, 'offprint-comments-' ) ? 'comments' : 'line' ) );
				echo $kind, ': ', $text( $child->title ), "\n", 'raw: ', $child->title, "\n";
			}
		}
		break;

	case 'request':
		define( 'OFFPRINT_INBOX', $args[1] );
		Offprint\Request::request( $args[2] );
		echo "done\n";
		break;

	case 'auth':
		$user    = get_user_by( 'login', $args[1] );
		$expires = time() + 3600;
		$token   = WP_Session_Tokens::get_instance( $user->ID )->create( $expires );
		// wp-admin wants the auth cookie (the secure one: the test's requests say they came over HTTPS);
		// nonces are made for the session in the logged-in cookie.
		$logged_in                 = wp_generate_auth_cookie( $user->ID, $expires, 'logged_in', $token );
		$_COOKIE[ LOGGED_IN_COOKIE ] = $logged_in;
		wp_set_current_user( $user->ID );
		echo 'Cookie: ', SECURE_AUTH_COOKIE, '=', wp_generate_auth_cookie( $user->ID, $expires, 'secure_auth', $token ),
			'; ', LOGGED_IN_COOKIE, '=', $logged_in, "\n",
			wp_create_nonce( 'offprint_request' ), "\n",
			wp_create_nonce( 'offprint_status' ), "\n",
			wp_create_nonce( 'wp_rest' ), "\n",
			wp_create_nonce( 'offprint_collect' ), "\n";
		break;
}
