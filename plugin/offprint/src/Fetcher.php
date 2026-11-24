<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/** How the exporter asks for one address. Fetch is the real one; the tests use a fake. */
interface Fetcher
{
    /**
     * One GET of a public address in export mode: logged out, never following a redirect.
     *
     * @return array{status: int, type: string, location: string, encoding: string, body: resource}|string
     *         The response, or why there is none. `type` is the media type alone, in lower case;
     *         `location` and `encoding` are the Location and Content-Encoding headers, or ''; the
     *         body is readable from its start, and the caller closes it.
     */
    public function get(string $url): array|string;
}
