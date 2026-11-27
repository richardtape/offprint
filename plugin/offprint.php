<?php
/**
 * Plugin Name: Offprint
 * Description: Makes WordPress answer the exporter, and only the exporter, with the public address; asks the Mac to publish, and shows how it went in the admin bar.
 * License: GPL-2.0-or-later
 *
 * This is the only file directly in mu-plugins/; WordPress loads nothing from sub-folders.
 */

declare(strict_types=1);

// Loaded by WordPress (or WP-CLI); never requested on its own.
if ( ! defined( 'ABSPATH' ) && PHP_SAPI !== 'cli' ) {
	exit;
}

$offprint_files = array(
	'Origin', 'Paths', 'Rules', 'Links', 'Pigeonhole', 'Export_Mode',
	'Report', 'Output', 'Fetcher', 'Fetch', 'Seeds', 'Exporter', 'Import', 'Command',
	'Status_View', 'Comments_View', 'Request', 'Admin_Bar',
);
$offprint_ok    = true;
foreach ( $offprint_files as $offprint_name ) {
	if ( ! is_file( __DIR__ . "/offprint/src/$offprint_name.php" ) ) {
		$offprint_ok = false;
	}
}

if ( $offprint_ok ) {
	foreach ( $offprint_files as $offprint_name ) {
		require_once __DIR__ . "/offprint/src/$offprint_name.php";
	}
	Offprint\Export_Mode::boot();
	Offprint\Request::boot();
	Offprint\Admin_Bar::boot();
	if ( defined( 'WP_CLI' ) && WP_CLI ) {
		WP_CLI::add_command( 'offprint', Offprint\Command::class );
	}
} elseif ( isset( $_SERVER['HTTP_X_OFFPRINT_EXPORT'] ) ) {
	// Fail closed: an export request must never be answered without export mode.
	// Normal requests carry no such header and keep working.
	http_response_code( 503 );
	header( 'Content-Type: text/plain' );
	echo 'Offprint is incomplete.';
	exit;
}
unset( $offprint_files, $offprint_ok, $offprint_name );
