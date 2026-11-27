<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * The "Publish Site" node in the admin bar: how publishing is going, and a button to ask for one.
 *
 * It reads var/status.json, which bin/publish writes on the Mac, through a read-only mount of var/
 * (/var/www/publish), and sees a waiting request either in the inbox (see Request) or as
 * var/publish-waiting, one the Mac has taken but not run yet. What it says is decided by Status_View;
 * this is the WordPress glue: the node, its style and script (admin-bar.css and admin-bar.js beside
 * src/, printed inline), the button's admin-post action, and the admin-ajax action the script polls.
 *
 * For a site that takes comments (its two pigeonhole constants are set), and a user who may moderate them, the node
 * also says how many comments the Mac has fetched and not yet opened, when, and how the last check went
 * (Comments_View, from var/pigeonhole-fetch.json and var/pigeonhole.json: counts and times, never a comment's
 * words), and has a second button, "Check for comments", which asks the Mac to open them (Request::collect). Nothing
 * is opened until someone asks (the owner's decision, 26 November 2026), and pressing it publishes nothing.
 *
 * Off entirely in export mode. Needs WordPress, so tests/e2e.sh covers it.
 */
final class Admin_Bar
{
    /** Where status.json is: var/, read-only. A OFFPRINT_DIR constant (in wp-config.php) overrides it. */
    public const DIR = '/var/www/publish';
    public const STATUS_FILE = 'status.json';
    /** A request the Mac has taken but not yet run (it is waiting for another publish to finish). */
    public const WAITING_FILE = 'publish-waiting';
    /** What the Mac wrote after its last fetch from the pigeonhole, and after its last collection. */
    public const FETCH_FILE = 'pigeonhole-fetch.json';
    public const COLLECTION_FILE = 'pigeonhole.json';
    /** A "check for comments" request the Mac has taken but not yet run. */
    public const COLLECT_WAITING_FILE = 'collect-waiting';

    private const NODE = 'offprint';
    private const HANDLE = 'offprint-admin-bar';
    /** The button's admin-post action, and its nonce action. */
    private const ASK = 'offprint_request';
    /**
     * The button's nonce field. Not _wpnonce: the admin bar comes before the screen's own forms, and
     * a second id="_wpnonce" there would be the one a screen's script finds.
     */
    private const NONCE_FIELD = 'offprint_nonce';
    /** The admin-ajax action the script polls, and its nonce action. */
    private const STATUS = 'offprint_status';
    private const CAPABILITY = 'publish_posts';
    /** The "Check for comments" button's admin-post action, and its nonce action; and who may press it. */
    private const COLLECT = 'offprint_collect';
    private const COMMENTS_CAPABILITY = 'moderate_comments';
    private const POLL_MS = 5000;
    /** How often the script looks once a publish seems stuck. */
    private const SLOW_POLL_MS = 60000;
    /** JSON that can sit in a script element, or be read as HTML, and mean nothing more than its text. */
    private const JSON_FLAGS = JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT;

    private static ?Status_View $view = null;
    private static Comments_View|null|false $comments = false;

    public static function boot(): void
    {
        if (Export_Mode::is_active()) {
            return;
        }
        add_action('admin_bar_menu', [self::class, 'admin_bar_menu'], 100);
        add_action('wp_enqueue_scripts', [self::class, 'enqueue']);
        add_action('admin_enqueue_scripts', [self::class, 'enqueue']);
        add_action('admin_post_' . self::ASK, [self::class, 'handle_button']);
        add_action('admin_post_' . self::COLLECT, [self::class, 'handle_collect']);
        add_action('wp_ajax_' . self::STATUS, [self::class, 'handle_status']);
    }

    /** admin_bar_menu: the node, the lines under it, and the button, for those who can publish. */
    public static function admin_bar_menu($bar): void
    {
        if (!$bar instanceof \WP_Admin_Bar || !current_user_can(self::CAPABILITY)) {
            return;
        }
        $view = self::view();
        $comments = self::comments();
        $bar->add_node([
            'id' => self::NODE,
            'title' => '<span class="offprint-dot" aria-hidden="true"></span>'
                . '<span class="screen-reader-text">Publish Site: </span>'
                . '<span class="offprint-label" aria-live="polite">' . esc_html($view->title) . '</span>'
                // how many comments wait to be checked, beside the title; empty when none do
                . ($comments !== null ? '<span class="offprint-count" aria-live="polite">' . esc_html(self::count_text($comments->count)) . '</span>' : ''),
            'href' => false,
            'meta' => ['class' => 'offprint-' . $view->tone, 'tabindex' => 0],
        ]);
        foreach ($view->lines as $i => $line) {
            $bar->add_node([
                'parent' => self::NODE,
                'id' => self::NODE . '-line-' . $i,
                'title' => esc_html($line),
                'href' => false,
                'meta' => ['class' => 'offprint-line'],
            ]);
        }
        // A form, not a link: asking for a publish changes something, so it is a POST with a nonce.
        $bar->add_node([
            'parent' => self::NODE,
            'id' => self::NODE . '-now',
            'title' => '<form method="post" action="' . esc_url(admin_url('admin-post.php')) . '">'
                . '<input type="hidden" name="action" value="' . esc_attr(self::ASK) . '">'
                . wp_nonce_field(self::ASK, self::NONCE_FIELD, true, false)
                . '<button type="submit" class="offprint-button">Publish Site</button>'
                . '</form>',
            'href' => false,
        ]);
        if ($comments === null) {
            return;
        }
        foreach ($comments->lines as $i => $line) {
            $bar->add_node([
                'parent' => self::NODE,
                'id' => self::NODE . '-comments-' . $i,
                'title' => esc_html($line),
                'href' => false,
                'meta' => ['class' => 'offprint-comments-line'],
            ]);
        }
        // Opening what was fetched changes something (comments arrive in the moderation queue): a POST, with a nonce.
        $bar->add_node([
            'parent' => self::NODE,
            'id' => self::NODE . '-collect',
            'title' => '<form method="post" action="' . esc_url(admin_url('admin-post.php')) . '">'
                . '<input type="hidden" name="action" value="' . esc_attr(self::COLLECT) . '">'
                . wp_nonce_field(self::COLLECT, self::NONCE_FIELD, true, false)
                . '<button type="submit" class="offprint-button">Check for comments</button>'
                . '</form>',
            'href' => false,
        ]);
    }

    /** wp_enqueue_scripts, admin_enqueue_scripts: the node's style, and the script that keeps it current. */
    public static function enqueue(): void
    {
        if (!is_admin_bar_showing() || !current_user_can(self::CAPABILITY)) {
            return;
        }
        $css = self::asset('admin-bar.css');
        if ($css !== '') {
            wp_register_style(self::HANDLE, false, [], null);
            wp_add_inline_style(self::HANDLE, $css);
            wp_enqueue_style(self::HANDLE);
        }
        $js = self::asset('admin-bar.js');
        if ($js !== '') {
            $config = [
                'url' => admin_url('admin-ajax.php'),
                'action' => self::STATUS,
                'nonce' => wp_create_nonce(self::STATUS),
                'interval' => self::POLL_MS,
                'slow' => self::SLOW_POLL_MS,
                'poll' => self::view()->poll() || (self::comments()?->pending ?? false),
            ];
            wp_register_script(self::HANDLE, false, [], null, ['in_footer' => true]);
            wp_add_inline_script(self::HANDLE, 'window.offprintAdminBar = ' . wp_json_encode($config, self::JSON_FLAGS) . ';', 'before');
            wp_add_inline_script(self::HANDLE, $js);
            wp_enqueue_script(self::HANDLE);
        }
    }

    /** admin-post.php?action=offprint_request: the Publish Site button. */
    public static function handle_button(): void
    {
        check_admin_referer(self::ASK, self::NONCE_FIELD);
        if (!current_user_can(self::CAPABILITY)) {
            wp_die('Sorry, you are not allowed to publish the site.', '', ['response' => 403]);
        }
        Request::request('button');
        wp_safe_redirect(wp_get_referer() ?: admin_url());
        exit;
    }

    /**
     * admin-post.php?action=offprint_collect: the Check for comments button. It asks the Mac to open what it has
     * fetched; it asks for no publish.
     */
    public static function handle_collect(): void
    {
        check_admin_referer(self::COLLECT, self::NONCE_FIELD);
        if (!current_user_can(self::CAPABILITY) || !current_user_can(self::COMMENTS_CAPABILITY) || Pigeonhole::settings() === null) {
            wp_die('Sorry, you are not allowed to check for comments.', '', ['response' => 403]);
        }
        $problem = Request::collect();
        if ($problem !== '') {
            wp_die(esc_html($problem), '', ['response' => 500, 'back_link' => true]);
        }
        wp_safe_redirect(wp_get_referer() ?: admin_url());
        exit;
    }

    /** admin-ajax.php?action=offprint_status: what the admin bar shows, for its script. */
    public static function handle_status(): void
    {
        check_ajax_referer(self::STATUS, 'nonce');
        if (!current_user_can(self::CAPABILITY)) {
            wp_send_json_error(null, 403, self::JSON_FLAGS);
        }
        $answer = self::view()->to_array();
        $comments = self::comments();
        if ($comments !== null) {
            // The script goes on asking while either a publish or a check for comments is under way.
            $answer['comments'] = $comments->to_array() + ['label' => self::count_text($comments->count)];
            $answer['poll'] = $answer['poll'] || $comments->pending;
            $answer['stuck'] = $answer['stuck'] || ($comments->stuck && !$answer['running'] && !$answer['pending']);
        }
        wp_send_json_success($answer, null, self::JSON_FLAGS);
    }

    /** What stands beside the node's title: " · 3 comments to check", or nothing when none wait. */
    private static function count_text(int $count): string
    {
        return $count === 0 ? '' : " \u{00b7} $count " . ($count === 1 ? 'comment' : 'comments') . ' to check';
    }

    /**
     * What the admin bar says about comments now; null for a site that takes none, and for a user who may not
     * moderate them. Read once per request.
     */
    private static function comments(): ?Comments_View
    {
        if (self::$comments === false) {
            self::$comments = null;
            if (Pigeonhole::settings() !== null && current_user_can(self::COMMENTS_CAPABILITY)) {
                $dir = self::dir();
                $waiting = array_filter([
                    self::modified(Request::inbox() . '/' . Request::COLLECT_FILE),
                    self::modified($dir . '/' . self::COLLECT_WAITING_FILE),
                ], 'is_int');
                self::$comments = Comments_View::build(
                    fetch: self::small($dir . '/' . self::FETCH_FILE),
                    collection: self::small($dir . '/' . self::COLLECTION_FILE),
                    request_time: $waiting !== [] ? max($waiting) : null,
                    now: time(),
                    format_time: self::format_time(...),
                );
            }
        }
        return self::$comments;
    }

    /** var/, as WordPress sees it. */
    private static function dir(): string
    {
        $dir = defined('OFFPRINT_DIR') ? OFFPRINT_DIR : self::DIR;
        return is_string($dir) && $dir !== '' ? untrailingslashit($dir) : self::DIR;
    }

    /** One of the two small files the Mac writes about comments, cut one byte past the most it may hold; null if there is none. */
    private static function small(string $file): ?string
    {
        if (!is_file($file)) {
            return null;
        }
        $raw = @file_get_contents($file, false, null, 0, Comments_View::MAX_BYTES + 1);
        return is_string($raw) ? $raw : '';
    }

    /** What the admin bar shows now. Read once per request, so the node and its script agree. */
    private static function view(): Status_View
    {
        if (self::$view === null) {
            $dir = self::dir();
            $status = $dir . '/' . self::STATUS_FILE;
            $raw = self::read($status);
            // A request waits in the inbox until the Mac takes it, and as publish-waiting until it runs.
            $waiting = array_filter([
                self::modified(Request::inbox() . '/' . Request::FILE),
                self::modified($dir . '/' . self::WAITING_FILE),
            ], 'is_int');
            $failure = Request::last_failure();
            self::$view = Status_View::build(
                raw: $raw,
                status_time: $raw === null ? null : self::modified($status),
                request_time: $waiting !== [] ? max($waiting) : null,
                now: time(),
                format_time: self::format_time(...),
                problem: Request::problem(),
                missed_at: $failure['at'] ?? null,
                missed: $failure['reason'] ?? '',
            );
        }
        return self::$view;
    }

    /** The file's contents, cut one byte past the most a status file may hold; null if there is none. */
    private static function read(string $file): ?string
    {
        if (!is_file($file)) {
            return null;
        }
        // bin/publish replaces the file by renaming, so it is never half written; it may still vanish.
        $raw = @file_get_contents($file, false, null, 0, Status_View::MAX_BYTES + 1);
        return is_string($raw) ? $raw : '';
    }

    private static function modified(string $file): ?int
    {
        if (!is_file($file)) {
            return null;
        }
        $time = @filemtime($file); // The Mac removes these files when it takes or serves a request.
        return is_int($time) ? $time : null;
    }

    /** A Unix time as the site shows times: the time alone if it is today, or the date and the time. */
    private static function format_time(int $time): string
    {
        $today = wp_date('Y-m-d') === wp_date('Y-m-d', $time);
        $format = (string) get_option('time_format');
        return (string) wp_date($today ? $format : get_option('date_format') . ' ' . $format, $time);
    }

    /** A file beside src/ (admin-bar.css, admin-bar.js), to print inline; '' if it is missing. */
    private static function asset(string $name): string
    {
        $file = dirname(__DIR__) . '/' . $name;
        $text = is_file($file) ? file_get_contents($file) : false;
        return is_string($text) ? $text : '';
    }
}
