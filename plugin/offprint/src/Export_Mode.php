<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * Changes how WordPress answers a request that carries the exporter's secret header:
 * every address in the response is the public one, nothing links to what the static site
 * won't have, and the request is never logged in. A request without the header is untouched.
 *
 * Needs WordPress, so unlike the other classes here it is covered by tests/e2e.sh, not PHPUnit.
 */
final class Export_Mode
{
    public const HEADER = 'X-Offprint-Export';
    private const OPTION = 'offprint_secret';

    /** @var bool|null Decided once per request, so the request is all in or all out. */
    private static ?bool $active = null;
    /** @var string The public origin, e.g. https://www.example.com */
    private static string $public = '';
    /** @var string[] The origins WordPress is really served from (home and siteurl). */
    private static array $local = array();

    /** The shared secret. Made on first call and kept out of the autoloaded options. */
    public static function secret(): string
    {
        $secret = get_option(self::OPTION);
        if (is_string($secret) && strlen($secret) >= 40) {
            return $secret;
        }
        $secret = bin2hex(random_bytes(20));
        update_option(self::OPTION, $secret, false);
        return $secret;
    }

    public static function is_active(): bool
    {
        if (self::$active === null) {
            $sent = $_SERVER['HTTP_X_OFFPRINT_EXPORT'] ?? '';
            // The header first: an ordinary request (no header) never reads the option. Without a
            // public origin there is nothing to export to, so stay off. A missing secret also means
            // off: only secret() makes one, never a request carrying the header.
            if (!defined('OFFPRINT_PUBLIC_ORIGIN') || !is_string($sent) || $sent === '') {
                self::$active = false;
            } else {
                $secret = get_option(self::OPTION);
                self::$active = is_string($secret) && strlen($secret) >= 40 && hash_equals($secret, $sent);
            }
        }
        return self::$active;
    }

    public static function boot(): void
    {
        if (!self::is_active()) {
            return;
        }
        self::$public = rtrim((string) OFFPRINT_PUBLIC_ORIGIN, '/');
        // Read before the filters below exist, so these are the real addresses.
        foreach (array('home', 'siteurl') as $name) {
            $origin = self::origin_of((string) get_option($name));
            if ($origin !== '' && $origin !== self::$public && !in_array($origin, self::$local, true)) {
                self::$local[] = $origin;
            }
        }

        add_filter('option_home', array(self::class, 'public_origin_of_url'));
        add_filter('option_siteurl', array(self::class, 'public_origin_of_url'));
        add_filter('determine_current_user', '__return_zero', PHP_INT_MAX);
        add_filter('redirect_canonical', array(self::class, 'keep_redirect_local'), 10, 2);
        add_filter('wp_redirect', array(self::class, 'rewrite_location'));
        add_filter('wp_headers', array(self::class, 'drop_pingback_header'));
        add_filter('robots_txt', array(self::class, 'robots'));
        add_filter('the_generator', '__return_empty_string');
        add_filter('wp_speculation_rules_configuration', '__return_null');
        add_filter('pre_http_request', array(self::class, 'refuse_public_host'), 10, 3);
        add_filter('emoji_svg_url', '__return_false');
        // A static page cannot take a comment, so show no form and no comments feed link. But for a site with a
        // pigeonhole (Pigeonhole.php): there each post's own setting decides, and its form posts to the pigeonhole.
        $comments = Pigeonhole::takes_comments();
        if ($comments) {
            Pigeonhole::boot_export();
        } else {
            add_filter('comments_open', '__return_false', PHP_INT_MAX);
        }
        add_filter('pings_open', '__return_false', PHP_INT_MAX);
        add_filter('feed_links_show_comments_feed', '__return_false');
        add_filter('bloginfo_rss', array(self::class, 'feed_home_slash'), 10, 2);

        // Late, so these also catch what themes and blocks add. (Kept where comments are taken: WordPress's
        // comment-reply script is what moves the form under the comment a visitor replies to.)
        if (!$comments) {
            add_action('wp_enqueue_scripts', array(self::class, 'drop_comment_reply'), PHP_INT_MAX);
            add_action('wp_print_scripts', array(self::class, 'drop_comment_reply'), 0);
            add_action('wp_print_footer_scripts', array(self::class, 'drop_comment_reply'), 0);
        }
        add_action('init', array(self::class, 'remove_head_links'), PHP_INT_MAX);

        // The local WordPress must not call the live site, or hold the cron lock the owner shares.
        if (!defined('DISABLE_WP_CRON')) {
            define('DISABLE_WP_CRON', true);
        }
        remove_action('init', 'wp_cron');

        ob_start(array(self::class, 'rewrite_output'));
    }

    /** option_home / option_siteurl: the same URL on the public origin. */
    public static function public_origin_of_url($value)
    {
        if (!is_string($value)) {
            return $value;
        }
        $path = (string) parse_url($value, PHP_URL_PATH);
        return self::$public . rtrim($path, '/');
    }

    public static function remove_head_links(): void
    {
        remove_action('wp_head', 'rest_output_link_wp_head');
        remove_action('template_redirect', 'rest_output_link_header', 11);
        remove_action('wp_head', 'wp_oembed_add_discovery_links');
        remove_action('wp_head', 'rsd_link');
        remove_action('wp_head', 'wlwmanifest_link');
        remove_action('wp_head', 'wp_shortlink_wp_head', 10);
        remove_action('template_redirect', 'wp_shortlink_header', 11);
        remove_action('wp_head', 'print_emoji_detection_script', 7);
        remove_action('wp_head', 'print_emoji_styles');
        remove_action('wp_print_styles', 'print_emoji_styles');
        remove_action('wp_head', 'wp_generator');
        // Keeps the main feed link (feed_links), drops the comment and archive feeds.
        remove_action('wp_head', 'feed_links_extra', 3);
    }

    public static function drop_comment_reply(): void
    {
        wp_dequeue_script('comment-reply');
        wp_deregister_script('comment-reply');
    }

    /** pre_http_request: no outbound request from export mode may go to the public host. */
    public static function refuse_public_host($pre, $args = array(), $url = '')
    {
        $host = parse_url((string) $url, PHP_URL_HOST);
        if (is_string($host) && strcasecmp($host, (string) parse_url(self::$public, PHP_URL_HOST)) === 0) {
            return new \WP_Error('offprint_blocked', 'Export mode does not call the public site.');
        }
        return $pre;
    }

    public static function drop_pingback_header($headers)
    {
        if (is_array($headers)) {
            unset($headers['X-Pingback']);
        }
        return $headers;
    }

    /** The feed's channel link is the home page: give it the slash the static site's page has. */
    public static function feed_home_slash($value, $show = '')
    {
        return ($show === 'url' && is_string($value)) ? trailingslashit($value) : $value;
    }

    public static function robots(): string
    {
        return "User-agent: *\nAllow: /\n\nSitemap: " . self::$public . "/wp-sitemap.xml\n";
    }

    /**
     * WordPress's canonical redirect would send every request to the public origin, because
     * the request arrives at the local host. Treat the public origin as the local one when comparing;
     * a real redirect (a missing trailing slash, say) is kept and rewritten on the way out.
     */
    public static function keep_redirect_local($redirect, $requested)
    {
        if (!is_string($redirect) || !is_string($requested)) {
            return $redirect;
        }
        $same = self::to_public($redirect) === self::to_public($requested);
        return $same ? false : $redirect;
    }

    public static function rewrite_location($location)
    {
        return is_string($location) ? self::to_public($location) : $location;
    }

    /**
     * The output buffer callback: every response type, including empty ones and redirects.
     *
     * @param int $phase PHP_OUTPUT_HANDLER_* flags. Without FINAL, something is flushing early.
     */
    public static function rewrite_output(string $body, int $phase = PHP_OUTPUT_HANDLER_FINAL): string
    {
        foreach (headers_list() as $line) {
            if (stripos($line, 'Content-Encoding:') === 0) {
                return $body; // Already compressed: the bytes are not ours to read.
            }
        }
        // If something flushed early the headers have gone, but the rest of the body is still ours.
        $headers_open = !headers_sent();
        if ($headers_open) {
            self::rewrite_headers(array('Location', 'Link'));
        }
        $fixed = self::to_public($body);
        // A length set earlier (a file served through PHP) is stale once the body changed. On an
        // early flush the headers go now, before the rest of the body is seen, so drop it anyway.
        $early = ($phase & PHP_OUTPUT_HANDLER_FINAL) === 0;
        if ($headers_open && ($fixed !== $body || $early)) {
            header_remove('Content-Length');
        }
        return $fixed;
    }

    /** Rewrites the named response headers, keeping repeated ones (Link often is). */
    private static function rewrite_headers(array $names): void
    {
        foreach ($names as $name) {
            $values = array();
            foreach (headers_list() as $line) {
                if (stripos($line, $name . ':') === 0) {
                    $values[] = $line;
                }
            }
            $fixed = array_map(array(self::class, 'to_public'), $values);
            if ($fixed === $values) {
                continue;
            }
            header_remove($name);
            foreach ($fixed as $line) {
                header($line, false);
            }
        }
    }

    private static function to_public(string $text): string
    {
        foreach (self::$local as $origin) {
            $text = Origin::rewrite($text, $origin, self::$public);
        }
        return $text;
    }

    private static function origin_of(string $url): string
    {
        $p = parse_url($url);
        if (!is_array($p) || !isset($p['scheme'], $p['host'])) {
            return '';
        }
        return $p['scheme'] . '://' . $p['host'] . (isset($p['port']) ? ':' . $p['port'] : '');
    }
}
