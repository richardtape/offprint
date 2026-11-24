<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

use Throwable;

/** Where an export starts: the public addresses WordPress itself lists, and anything to say about them. */
final class Seeds
{
    /**
     * @param string[] $addresses Public addresses.
     * @param string[] $warnings
     * @param string[] $errors
     */
    public function __construct(
        public array $addresses = [],
        public array $warnings = [],
        public array $errors = []
    ) {
    }

    /**
     * Asks WordPress: the home page, the main feed, robots.txt, and every address the sitemap
     * providers list along with the sitemaps themselves. Needs WordPress, so it is covered by
     * tests/e2e.sh, not PHPUnit.
     */
    public static function from_wordpress(string $public_origin): self
    {
        $seeds = new self();
        // This process is not in export mode, so WordPress gives its local addresses.
        $home = (array) wp_parse_url(home_url());
        $local = ($home['scheme'] ?? '') . '://' . ($home['host'] ?? '') . (isset($home['port']) ? ':' . $home['port'] : '');
        $add = function (string $url) use ($seeds, $local, $public_origin): void {
            $seeds->addresses[] = Origin::rewrite($url, $local, $public_origin);
        };

        try {
            $add(home_url('/'));
            $add(get_feed_link());
            $add(home_url('/robots.txt'));
            $server = wp_sitemaps_get_server();
            if (!$server->sitemaps_enabled()) {
                // As "Discourage search engines" does.
                $seeds->warnings[] = 'Sitemaps are off, so only pages reachable by links from the home page, '
                    . 'the feed and the 404 page will be exported.';
                return $seeds;
            }
            $add((string) get_sitemap_url('index'));
            foreach (wp_get_sitemap_providers() as $provider) {
                foreach ($provider->get_sitemap_type_data() as $type) {
                    for ($page = 1; $page <= $type['pages']; $page++) {
                        foreach ($provider->get_url_list($page, $type['name']) as $entry) {
                            $add((string) $entry['loc']);
                        }
                    }
                }
            }
        } catch (Throwable $e) {
            $seeds->errors[] = 'WordPress could not list every starting address: ' . $e->getMessage();
        }
        return $seeds;
    }
}
