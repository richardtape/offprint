<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * Takes one comment that a visitor sent to the site's pigeonhole into WordPress, held for the owner.
 *
 * The Mac opens and checks a submission (lib/pigeonhole.php) before this is handed it, on a pipe. It is still a
 * stranger's text, and this is where it reaches a database, an admin screen and, once approved, the public site. So:
 * nothing is published by importing (every comment is held, or goes to the spam list); WordPress's own HTML filter is
 * on, and checked to be; a link keeps its address only when it is a whole http(s) one on another site (the exporter
 * follows every link to this site, so one to a page that is not there would fail every publish once the comment was
 * approved); and the same submission arriving twice is one comment. parse() and the answers use no WordPress function and are unit-tested; run() needs a
 * real WordPress (tests/e2e.sh).
 */
final class Import
{
    /** The comment meta that holds a submission's id, so that one pulled twice is imported once. */
    public const META = 'offprint_pigeonhole_id';
    /** What a comment's user-agent column says of one that came this way (WordPress shows it nowhere public). */
    public const AGENT = 'offprint-pigeonhole';
    /** One byte more than the longest the Mac sends (lib/pigeonhole.php: a line of 8192 bytes, and its line end): no more is read. */
    public const MAX_BYTES = 8194;
    /** What an address of this site's own becomes in a comment's words: see without_own_addresses(). */
    public const OWN_ADDRESS = '[a link to this site]';

    /** This site's own host names (its public one and its local one), while run() is at work: see foreign(). */
    private static array $own = array();

    /**
     * Whether an address a stranger gave may be a link on the public site: a whole http(s) address, written plainly
     * (a host name of letters, digits, dots and dashes, an optional port, then a path; no user name, no backslash,
     * nothing a browser and the exporter could read in two ways), on a host that is not one of this site's own.
     * The exporter fetches every link to this site and fails the publish when one answers 404, so a link here to
     * a page that is not there would stop every publish; it also means a comment can't point a reader at wp-admin.
     *
     * @param string[] $own this site's own host names
     */
    public static function foreign(string $url, array $own): bool
    {
        if (preg_match('#\Ahttps?://([a-z0-9.-]+)(?::[0-9]{1,5})?(?:[/?\#][^\s\\\\]*)?\z#Di', $url, $m) !== 1) {
            return false;
        }
        $host = rtrim(strtolower($m[1]), '.');
        if ($host === '') {
            return false;
        }
        foreach ($own as $mine) {
            if ($host === rtrim(strtolower((string) $mine), '.')) {
                return false;
            }
        }
        // Nor may it name one of this site's hosts anywhere else (its path, its query): the checks refuse the local
        // host name wherever it is in a published file.
        return self::without_own_addresses($url, $own) === $url;
    }

    /**
     * $text with every address of this site's own taken out of its words, each replaced by OWN_ADDRESS: a host name
     * of this site's (its dots written as dots or as one of their encodings, in any case), with a scheme before it
     * and a path after it when they are there. Two things would otherwise fail every publish once a comment was
     * approved. WordPress turns a bare address in a comment into a link when it shows it, and the exporter follows
     * every link to this site, failing on one that answers 404 (the checks refuse one to wp-admin). And the checks
     * refuse the local host name anywhere in a published file. The owner sees the replacement in the moderation queue,
     * and can put a real link back.
     *
     * @param string[] $own this site's own host names
     */
    public static function without_own_addresses(string $text, array $own): string
    {
        foreach ($own as $mine) {
            $mine = rtrim(strtolower((string) $mine), '.');
            if ($mine === '') {
                continue;
            }
            $host = implode('(?:\.|&\#0*46;|&\#x0*2e;|&period;|%2e)', array_map(static fn (string $label): string => preg_quote($label, '~'), explode('.', $mine)));
            $replaced = preg_replace('~(?:https?:)?(?://)?' . $host . '(?::[0-9]+)?(?:[/?\#][^\s<>"\']*)?~i', self::OWN_ADDRESS, $text);
            // (null: the pattern failed on this text, which is then not kept at all)
            $text = $replaced ?? self::OWN_ADDRESS;
        }
        return $text;
    }

    /**
     * One checked submission, as the Mac sent it, as the values a comment is made from; or why it is not one.
     * The Mac has checked all of this already. It is asked again here because this is the last place it can be.
     *
     * @param string[] $own this site's own host names (see foreign())
     * @return array{id:string,ts:int,post_id:int,parent:int,author:string,email:string,url:string,content:string}|string
     */
    public static function parse(string $json, array $own = array()): array|string
    {
        if (strlen($json) >= self::MAX_BYTES) {
            return 'it is longer than a submission';
        }
        $d = json_decode(rtrim($json, "\n"), true, 4);
        if (!is_array($d) || ($d['v'] ?? null) !== 1 || ($d['kind'] ?? null) !== 'comment') {
            return 'it is not a checked comment';
        }
        $f = $d['fields'] ?? null;
        if (!is_string($d['id'] ?? null) || preg_match('/\A[0-9a-f]{32}\z/D', $d['id']) !== 1 || !is_int($d['ts'] ?? null) || !is_array($f)) {
            return 'it is not a checked comment';
        }
        foreach (array('post_id', 'parent') as $key) {
            if (!is_int($f[$key] ?? null) || $f[$key] < 0) {
                return 'it is not a checked comment';
            }
        }
        foreach (array('author', 'email', 'url', 'content') as $key) {
            if (!is_string($f[$key] ?? null)) {
                return 'it is not a checked comment';
            }
        }
        return array(
            'id' => $d['id'],
            'ts' => $d['ts'],
            'post_id' => $f['post_id'],
            'parent' => $f['parent'],
            'author' => self::without_own_addresses($f['author'], $own),
            'email' => $f['email'],
            // The commenter's address becomes a link on their name: kept only when it may be one (foreign()).
            'url' => self::foreign($f['url'], $own) ? $f['url'] : '',
            'content' => $f['content'],
        );
    }

    /** The one line that says a comment was made: its number, and the list it is in. */
    public static function imported(int $comment, string $status): string
    {
        return "imported $comment $status";
    }

    /** The one line that says this submission is a comment already. */
    public static function already(int $comment): string
    {
        return "already $comment";
    }

    /** The one line that says why nothing was made: one of this class's own texts, or a code of WordPress's. */
    public static function refused(string $why): string
    {
        $why = preg_replace('/[^a-z0-9 ,:_-]/', '', strtolower($why)) ?? '';
        return 'refused ' . ($why === '' ? 'no reason was given' : substr($why, 0, 120));
    }

    /**
     * Makes the comment. $sorted is the Mac's sorter's word: "hold" or "spam".
     *
     * @return string one line: imported, already or refused (the three functions above)
     */
    public static function run(string $json, string $sorted): string
    {
        if ($sorted !== 'hold' && $sorted !== 'spam') {
            return self::refused('it was sorted as neither hold nor spam');
        }
        // This site's own host names: the public one (the compose file's constant) and the one WordPress answers to here.
        self::$own = array();
        foreach (array(defined('OFFPRINT_PUBLIC_ORIGIN') ? (string) OFFPRINT_PUBLIC_ORIGIN : '', home_url(), site_url()) as $address) {
            $host = wp_parse_url($address, PHP_URL_HOST);
            if (is_string($host) && $host !== '') {
                self::$own[] = $host;
            }
        }
        $s = self::parse($json, self::$own);
        if (is_string($s)) {
            return self::refused($s);
        }
        // As no user: a logged-in user's comment skips the HTML filter and moderation.
        wp_set_current_user(0);

        // The same submission pulled twice (a crash between its download and its removal) is one comment.
        $again = get_comments(array('meta_key' => self::META, 'meta_value' => $s['id'], 'status' => 'any', 'fields' => 'ids', 'number' => 1));
        if ($again) {
            return self::already((int) $again[0]);
        }
        $post = get_post($s['post_id']);
        if (!$post || $post->post_status !== 'publish' || $post->post_password !== '' || !is_post_type_viewable($post->post_type) || !comments_open($post)) {
            return self::refused('no such public post, or its comments are closed');
        }
        if ($s['parent'] !== 0) {
            // A reply is to a comment a visitor can see: approved, and on this post.
            $parent = get_comment($s['parent']);
            if (!$parent || $parent->comment_approved !== '1' || (int) $parent->comment_post_ID !== (int) $post->ID) {
                return self::refused('its parent is not an approved comment on that post');
            }
        }
        if (get_option('comment_registration')) {
            return self::refused('this site takes comments from its registered users only');
        }
        // (trimmed: WordPress trims a name before it stores it, so one of spaces is no name)
        if (get_option('require_name_email') && (trim($s['author']) === '' || trim($s['email']) === '')) {
            return self::refused('this site asks for a name and an email address');
        }
        if ($s['email'] !== '' && !is_email($s['email'])) {
            return self::refused('its email address is not one');
        }

        // Everything is held: what WordPress's own settings would publish at once is held instead, and what the Mac
        // sorted as spam goes to the spam list. (What WordPress itself calls spam or trash stays so.)
        add_filter('pre_comment_approved', static function ($approved) use ($sorted) {
            if ($sorted === 'spam') {
                return 'spam';
            }
            return (1 === $approved || '1' === $approved) ? 0 : $approved;
        }, PHP_INT_MAX);
        // WordPress's flood check asks whether this address or email commented in the last seconds, by the clock at
        // import. Every import has the same (empty) address, so a batch would refuse all but its first.
        add_filter('wp_is_comment_flood', '__return_false', PHP_INT_MAX);
        // No email about it: it would put a stranger's name, address and text into mail.
        add_filter('notify_moderator', '__return_false', PHP_INT_MAX);
        add_filter('notify_post_author', '__return_false', PHP_INT_MAX);
        // Under WP-CLI, WordPress's HTML filter for comments is off, even as no user: without this a <script> in a
        // comment reaches the admin screen and, approved, the public page. Turn it on, and refuse to go on without it.
        kses_init_filters();
        if (has_filter('pre_comment_content', 'wp_filter_kses') === false) {
            return self::refused('wordpress html filter for comments could not be turned on');
        }
        // After that filter, which turns href="javascript:x" into the relative link href="x": the exporter would
        // follow it to a page that is not there, and one approved comment would stop every publish. A link in a
        // comment keeps its address only when it may be one (foreign()).
        add_filter('pre_comment_content', array(self::class, 'whole_links_only'), PHP_INT_MAX);

        $data = array(
            'comment_post_ID' => (int) $post->ID,
            'comment_parent' => $s['parent'],
            'comment_author' => $s['author'],
            'comment_author_email' => $s['email'],
            'comment_author_url' => $s['url'],
            'comment_content' => $s['content'],
            'comment_type' => 'comment',
            'comment_author_IP' => '',
            'comment_agent' => self::AGENT,
            'user_id' => 0,
            // When the visitor sent it, not when the Mac got round to importing it.
            'comment_date_gmt' => gmdate('Y-m-d H:i:s', $s['ts']),
            'comment_date' => get_date_from_gmt(gmdate('Y-m-d H:i:s', $s['ts'])),
        );
        $lengths = wp_check_comment_data_max_lengths($data);
        if (is_wp_error($lengths)) {
            return self::refused($lengths->get_error_code());
        }
        // What will be stored, asked for first: a comment that is nothing once filtered is not made.
        $stored = wp_unslash((string) apply_filters('pre_comment_content', wp_slash($s['content'])));
        if (trim(wp_strip_all_tags($stored)) === '') {
            return self::refused('nothing is left of its text once filtered');
        }
        $id = wp_new_comment(wp_slash($data), true);
        if (is_wp_error($id)) {
            return self::refused($id->get_error_code());
        }
        if (!$id) {
            return self::refused('wordpress made no comment');
        }
        add_comment_meta((int) $id, self::META, $s['id'], true);
        $made = get_comment((int) $id);
        $status = $made ? (string) $made->comment_approved : '';
        if ($status === '1') {
            // Never published by importing, whatever a plugin did to the filter above.
            wp_set_comment_status((int) $id, 'hold');
            $status = '0';
        }
        return self::imported((int) $id, $status === '0' ? 'hold' : ($status === 'spam' ? 'spam' : 'trash'));
    }

    /**
     * A filter on a comment's text (slashed, as WordPress passes it): every address in a tag (a link's href, a
     * quotation's cite) stays only when it may be a link (foreign()); the words stay either way, but for an address
     * of this site's own among them (without_own_addresses()).
     */
    public static function whole_links_only($content)
    {
        $html = new \WP_HTML_Tag_Processor(wp_unslash((string) $content));
        while ($html->next_tag()) {
            foreach (array('href', 'cite', 'src') as $name) {
                $value = $html->get_attribute($name);
                if ($value !== null && (!is_string($value) || !self::foreign($value, self::$own))) {
                    $html->remove_attribute($name);
                }
            }
        }
        return wp_slash(self::without_own_addresses($html->get_updated_html(), self::$own));
    }
}
