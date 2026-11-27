<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * Asking the Mac for a publish.
 *
 * WordPress asks by writing a request file into the inbox, a folder shared with the Mac (var/inbox
 * there, /var/www/publish-inbox here). A launchd agent on the Mac (bin/publish-agent, installed by
 * offprint install-agent) takes it and runs bin/publish. The inbox is the only part of var/ that WordPress
 * can write: bin/publish and launchd write var/ by path, so nothing WordPress makes may be there.
 *
 * It asks by itself when a post of a public type is published, changed while published, unpublished
 * or deleted, and when a term of a public taxonomy is edited or deleted. Anything else (menus, widgets,
 * templates, styles, options) waits for the "Publish Site" button (Admin_Bar).
 *
 * Off entirely in export mode. Needs WordPress, so tests/e2e.sh covers it.
 */
final class Request
{
    /** The inbox. A OFFPRINT_INBOX constant (in wp-config.php) overrides it. */
    public const INBOX = '/var/www/publish-inbox';
    public const FILE = 'publish-request';
    /** Asking the Mac to check for comments: the same folder, another name (bin/publish-agent takes both). */
    public const COLLECT_FILE = 'collect-request';
    /** When a request couldn't be written, and why, until one can. Not autoloaded. */
    private const FAILURE_OPTION = 'offprint_request_failure';

    /** @var string[] Why this request asks for a publish, each once. Written as the request ends. */
    private static array $reasons = [];

    public static function boot(): void
    {
        if (Export_Mode::is_active()) {
            return;
        }
        add_action('transition_post_status', [self::class, 'post_status_changed'], 10, 3);
        add_action('deleted_post', [self::class, 'post_deleted'], 10, 2);
        add_action('edited_term', [self::class, 'term_changed'], 10, 3);
        add_action('delete_term', [self::class, 'term_changed'], 10, 3);
    }

    /**
     * Asks the Mac for a publish: writes the request file, one line, "<UTC time> <reason>".
     * Never a PHP warning or a fatal error: when it can't, it remembers why, and the admin bar says so.
     *
     * @param string $reason Why, for var/publish.log: "button", "post 12", "term 3". Kept to [a-z0-9 _-].
     */
    public static function request(string $reason): void
    {
        $reason = substr(trim((string) preg_replace('/[^a-z0-9 _-]/', '', strtolower($reason))), 0, 100);
        $reason = $reason !== '' ? $reason : 'unknown';
        $inbox = self::inbox();
        $problem = self::problem();
        if ($problem === '') {
            $problem = self::write($inbox, gmdate('Y-m-d\TH:i:s\Z') . ' ' . $reason . "\n");
        }
        if ($problem !== '') {
            update_option(self::FAILURE_OPTION, ['at' => time(), 'reason' => $problem], false);
            return;
        }
        if (get_option(self::FAILURE_OPTION) !== false) {
            delete_option(self::FAILURE_OPTION);
        }
        /**
         * Fires when a publish has been asked for.
         *
         * @param string $reason Why, as the request file says it.
         */
        do_action('offprint_requested', $reason);
    }

    /**
     * Asks the Mac to check for comments (to open what it has fetched from the site's pigeonhole, and hand it to
     * WordPress, held): writes the collect request, one line, as request() writes its own. Returns '' when it is
     * written, or why it could not be. It asks for no publish, and nothing is remembered of a failure: the admin bar's
     * button is the only thing that asks, and whoever pressed it is told at once.
     */
    public static function collect(): string
    {
        $problem = self::problem();
        return $problem !== '' ? $problem : self::write(self::inbox(), gmdate('Y-m-d\TH:i:s\Z') . " button\n", self::COLLECT_FILE);
    }

    public static function inbox(): string
    {
        $inbox = defined('OFFPRINT_INBOX') ? OFFPRINT_INBOX : self::INBOX;
        return is_string($inbox) && $inbox !== '' ? untrailingslashit($inbox) : self::INBOX;
    }

    /** Why a request can't be written into the inbox now, or ''. */
    public static function problem(): string
    {
        $inbox = self::inbox();
        if (!is_dir($inbox)) {
            return "The folder WordPress asks the Mac through ($inbox) isn't there. Recreate the container (offprint compose up -d) to add it.";
        }
        if (!wp_is_writable($inbox)) {
            return "WordPress can't write to $inbox, the folder it asks the Mac through.";
        }
        return '';
    }

    /**
     * The last request that couldn't be written, if none has been written since.
     *
     * @return array{at: int, reason: string}|null
     */
    public static function last_failure(): ?array
    {
        $failure = get_option(self::FAILURE_OPTION);
        if (is_array($failure) && is_int($failure['at'] ?? null) && is_string($failure['reason'] ?? null)) {
            return ['at' => $failure['at'], 'reason' => $failure['reason']];
        }
        return null;
    }

    /** transition_post_status: into, out of, or within "publish", for a type the public can see. */
    public static function post_status_changed($new_status, $old_status, $post): void
    {
        if (('publish' === $new_status || 'publish' === $old_status) && self::is_public_post($post)) {
            self::request_at_shutdown('post ' . $post->ID);
        }
    }

    /** deleted_post: one deleted while it was published. (Trashing one is a status change.) */
    public static function post_deleted($post_id, $post = null): void
    {
        if ($post instanceof \WP_Post && 'publish' === $post->post_status && self::is_public_post($post)) {
            self::request_at_shutdown('post ' . $post->ID);
        }
    }

    /** edited_term, delete_term: a term of a taxonomy the public can see. */
    public static function term_changed($term_id, $tt_id = 0, $taxonomy = ''): void
    {
        if (is_string($taxonomy) && is_taxonomy_viewable($taxonomy)) {
            self::request_at_shutdown('term ' . (int) $term_id);
        }
    }

    /** shutdown: the one request for everything this request changed. */
    public static function request_queued(): void
    {
        if (self::$reasons === []) {
            return;
        }
        $more = count(self::$reasons) - 1;
        $reason = self::$reasons[0] . ($more > 0 ? " and $more more" : '');
        self::$reasons = [];
        self::request($reason);
    }

    private static function is_public_post($post): bool
    {
        if (!$post instanceof \WP_Post || (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE)) {
            return false;
        }
        return !wp_is_post_revision($post) && !wp_is_post_autosave($post) && is_post_type_viewable($post->post_type);
    }

    /** Several changes in one request (a bulk edit, say) ask once, as the request ends. */
    private static function request_at_shutdown(string $reason): void
    {
        if (self::$reasons === []) {
            add_action('shutdown', [self::class, 'request_queued']);
        }
        if (!in_array($reason, self::$reasons, true)) {
            self::$reasons[] = $reason;
        }
    }

    /** Writes beside the request file, then renames, so the Mac never reads half a line. '' or what went wrong. */
    private static function write(string $inbox, string $line, string $file = self::FILE): string
    {
        $temp = $inbox . '/.' . $file . '.' . bin2hex(random_bytes(6));
        // The Mac takes the request from this folder at any moment: a failure is reported, not warned about.
        if (@file_put_contents($temp, $line) !== strlen($line)) {
            @unlink($temp);
            return "WordPress couldn't write a file in $inbox, the folder it asks the Mac through.";
        }
        if (!@rename($temp, $inbox . '/' . $file)) {
            @unlink($temp);
            return "WordPress couldn't put the request file in place in $inbox.";
        }
        return '';
    }
}
