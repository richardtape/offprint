<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

use WP_CLI;

/**
 * Builds the static site from this WordPress, and takes a visitor's comment into it.
 */
final class Command
{
    /** Where the exporter reaches WordPress: the web server in this same container. */
    private const FETCH_BASE = 'http://127.0.0.1';

    /**
     * Exports every public page, and every file those pages use, into an empty folder.
     *
     * Prints a line for each warning (something that will not work on a static site), then for each error, then what it wrote, all on standard output. Exits with 1 if there was any error.
     *
     * ## OPTIONS
     *
     * [--out=<dir>]
     * : The folder to write into. It must be empty, or not exist yet.
     * ---
     * default: /var/www/export
     * ---
     *
     * ## EXAMPLES
     *
     *     wp offprint export --out=/var/www/export
     *
     * @param string[]              $args
     * @param array<string, string> $assoc_args
     */
    public function export(array $args, array $assoc_args): void
    {
        if (!defined('OFFPRINT_PUBLIC_ORIGIN')) {
            WP_CLI::error('OFFPRINT_PUBLIC_ORIGIN is not defined, so there is no public address to export for.');
        }
        $public = rtrim((string) OFFPRINT_PUBLIC_ORIGIN, '/');
        // This process is not in export mode, so home is the local address WordPress answers to.
        $home = (array) wp_parse_url(home_url());
        $local_host = (string) ($home['host'] ?? '');
        $host_header = $local_host . (isset($home['port']) ? ':' . $home['port'] : '');
        $secret = Export_Mode::secret();

        $exporter = new Exporter($public, new Fetch(self::FETCH_BASE, $host_header, $secret), $local_host, $secret);
        $report = $exporter->run($assoc_args['out'], Seeds::from_wordpress($public));

        // One stream, in this order, so a caller reading through `docker compose exec` sees it so.
        foreach ($report->warnings as $warning) {
            WP_CLI::line("Warning: $warning");
        }
        foreach ($report->errors as $error) {
            WP_CLI::line("Error: $error");
        }
        WP_CLI::line($report->summary());
        WP_CLI::halt($report->ok() ? 0 : 1);
    }

    /**
     * Takes one comment sent to the site's pigeonhole into WordPress, held for moderation.
     *
     * Reads one checked submission, a line of JSON, on standard input (offprint collect sends it). Prints one line: "imported ID hold", "imported ID spam", "already ID" (this submission is a comment already) or "refused" and why. Nothing is ever published by this.
     *
     * ## OPTIONS
     *
     * [--sorted=<word>]
     * : Which list it goes to: hold (the moderation queue) or spam.
     * ---
     * default: hold
     * ---
     *
     * ## EXAMPLES
     *
     *     wp offprint import-submission --sorted=hold < submission.json
     *
     * @subcommand import-submission
     *
     * @param string[]              $args
     * @param array<string, string> $assoc_args
     */
    public function import_submission(array $args, array $assoc_args): void
    {
        $json = stream_get_contents(STDIN, Import::MAX_BYTES);
        WP_CLI::line(Import::run($json === false ? '' : $json, (string) ($assoc_args['sorted'] ?? 'hold')));
    }
}
