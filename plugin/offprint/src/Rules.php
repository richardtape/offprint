<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * Decides whether the crawler may fetch a URL.
 *
 * WordPress's own addresses are refused only as the first segment of the path, where WordPress has them, so a post
 * at /wp-admin-tips/ or a tag at /tag/wp-json/ is exported. Feeds are not decided here: /tag/feed/ (the archive of a
 * tag named "feed") can't be told from /tag/x/feed/ (a feed) by the path, so the Exporter goes by what the server sends.
 */
final class Rules
{
    private const REFUSED_FIRST_SEGMENTS = [
        'wp-admin', 'wp-login.php', 'wp-json', 'xmlrpc.php', 'wp-cron.php',
        'wp-comments-post.php', 'wp-trackback.php', 'wp-signup.php', 'wp-activate.php',
        'wp-mail.php', 'wp-links-opml.php',
    ];

    /**
     * Whether a (lowercase) segment is index.php as WordPress's rewrite rules see it: they are regular expressions
     * with the dot unescaped (^index.php/wp-json/), so any character stands for the dot.
     */
    private static function is_index(string $segment): bool
    {
        return preg_match('/^index.php$/', $segment) === 1;
    }

    public static function should_fetch(string $url, string $origin): bool
    {
        $u = parse_url($url);
        $o = parse_url($origin);
        if ($u === false || $o === false || !isset($u['scheme'], $u['host'], $o['scheme'], $o['host'])) {
            return false;
        }
        if (isset($u['user']) || isset($u['pass'])) {
            return false;
        }
        if (strtolower($u['scheme']) !== strtolower($o['scheme'])
            || strtolower($u['host']) !== strtolower($o['host'])
            || ($u['port'] ?? null) !== ($o['port'] ?? null)) {
            return false;
        }

        $path = rawurldecode($u['path'] ?? '/');
        if ($path === '' || str_contains($path, "\0")) {
            $path = '/';
        }
        // The segments as the web server sees them: empty ones dropped, and "." and ".." resolved.
        $segments = [];
        foreach (explode('/', strtolower($path)) as $segment) {
            if ($segment === '..') {
                array_pop($segments);
            } elseif ($segment !== '' && $segment !== '.') {
                $segments[] = $segment;
            }
        }

        // Behind a leading index.php, WordPress reads the rest as the address and matches it against its rules, so
        // /index.php/wp-json/, /index.php/index.php/wp-json/ and /index.php/indexXphp/wp-json/ are all the REST API:
        // refuse wp-json anywhere after it, and judge the first segment after every leading index.php.
        $indexed = false;
        while ($segments !== [] && self::is_index($segments[0])) {
            array_shift($segments);
            $indexed = true;
        }
        if ($indexed && in_array('wp-json', $segments, true)) {
            return false;
        }
        $first = $segments[0] ?? '';
        if (in_array($first, self::REFUSED_FIRST_SEGMENTS, true)) {
            return false;
        }

        if (isset($u['query']) && $u['query'] !== '') {
            $last = $segments ? end($segments) : '';
            if (str_ends_with($path, '/') || pathinfo($last, PATHINFO_EXTENSION) === '') {
                return false;
            }
            parse_str($u['query'], $params);
            if (array_keys($params) !== ['ver']) {
                return false;
            }
        }

        return true;
    }
}
