<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * The page's side of comments on a static site, in export mode: a post that takes comments shows WordPress's own
 * comment form, with the one path of the site's own origin a comment is posted to (the site's pigeonhole), the public
 * keys it is encrypted to, and the small script that does it. The form itself can't post: its method is "dialog",
 * which a browser does nothing with outside a dialog. Only the script sends, and only what it has encrypted; a visitor
 * whose browser never ran it sends nothing, least of all their name, address and words in the clear. Only for a site whose site.json has a "pigeonhole" block: the
 * compose file hands its path and keys to WordPress as two constants, and without them export mode closes every
 * post's comments as it always has.
 *
 * WordPress can ignore or alter anything printed here. What makes the published page right is bin/check-site, on the
 * Mac: it refuses a page whose path or keys are not exactly site.json's, and a script that is not the tool's own.
 * settings_from() and block() use no WordPress function and are unit-tested; the hooks need a real WordPress
 * (tests/e2e.sh). All of them are core's own: no theme, block or plugin is named.
 */
final class Pigeonhole
{
    /** The id of the JSON block a page carries. The loader and bin/check-site-pigeonhole.php find it by this. */
    public const BLOCK_ID = 'offprint-pigeonhole';
    /**
     * How many zero bits a submission's proof of work must start with (pigeonhole/browser/src/pow.js): a fraction of
     * a second in a visitor's browser. bin/check-site-pigeonhole.php holds the same number.
     */
    public const BITS = 18;
    /** The name of the field no person sees or fills in: the Mac's sorter calls a comment that fills it spam. */
    public const HIDDEN_FIELD = 'offprint_hp';
    /** The attribute that marks the comment form: the loader finds it by this, and bin/check-site checks the form that has it. */
    public const FORM_MARK = 'data-offprint-pigeonhole';

    /** @var bool A comment form is being printed, and held back until it has been made unable to post. */
    private static bool $holding = false;

    /** @var array{path: string, recipients: string[]}|null|false The settings, read once (false: not yet). */
    private static array|null|false $settings = false;

    /**
     * The settings two values make, held to lib/config.php's own patterns again (they came through the environment):
     * a path of one name, and one or two age public keys with a space between. Null when either is anything else,
     * and for a site with no pigeonhole (both empty).
     *
     * @return array{path: string, recipients: string[]}|null
     */
    public static function settings_from(string $path, string $recipients): ?array
    {
        if (preg_match('/\A\/[a-z0-9_-]{1,40}\z/D', $path) !== 1) {
            return null;
        }
        if (preg_match('/\Aage1[ac-hj-np-z02-9]{58}( age1[ac-hj-np-z02-9]{58})?\z/D', $recipients) !== 1) {
            return null;
        }
        $keys = explode(' ', $recipients);
        if (count(array_unique($keys)) !== count($keys)) {
            return null;
        }
        return array('path' => $path, 'recipients' => $keys);
    }

    /**
     * This site's settings, from the two constants the compose file defines; null for a site with no pigeonhole.
     *
     * @return array{path: string, recipients: string[]}|null
     */
    public static function settings(): ?array
    {
        if (self::$settings === false) {
            self::$settings = (defined('OFFPRINT_PIGEONHOLE_PATH') && defined('OFFPRINT_PIGEONHOLE_RECIPIENTS'))
                ? self::settings_from((string) OFFPRINT_PIGEONHOLE_PATH, (string) OFFPRINT_PIGEONHOLE_RECIPIENTS)
                : null;
        }
        return self::$settings;
    }

    /**
     * The block a page with a comment form carries: where comments go, to whose keys, and the proof of work asked.
     * JSON, in a script element that no browser runs. Exactly these three keys, in this order: bin/check-site
     * compares what a page carries with site.json's.
     *
     * @param array{path: string, recipients: string[]} $settings
     */
    public static function block(array $settings): string
    {
        $json = json_encode(
            array('path' => $settings['path'], 'recipients' => array_values($settings['recipients']), 'bits' => self::BITS),
            JSON_UNESCAPED_SLASHES | JSON_HEX_TAG | JSON_HEX_AMP | JSON_THROW_ON_ERROR
        );
        return '<script type="application/json" id="' . self::BLOCK_ID . '">' . $json . '</script>';
    }

    /** The public address a form may post to (the exporter then says nothing of a form that does). */
    public static function accepted_post(string $public_origin): string
    {
        $settings = self::settings();
        return $settings === null ? '' : rtrim($public_origin, '/') . $settings['path'];
    }

    /**
     * Whether this export shows comment forms: the site has a pigeonhole, and takes comments from anyone. (A site
     * that takes them from its registered users only would show a link to the login page in place of the form, and
     * nobody is ever logged in to a static site.)
     */
    public static function takes_comments(): bool
    {
        return self::settings() !== null && !get_option('comment_registration');
    }

    /** Export mode's hooks, for an export that shows comment forms. */
    public static function boot_export(): void
    {
        add_filter('comment_form_defaults', array(self::class, 'form_posts_to_the_path'), PHP_INT_MAX);
        add_filter('comment_form_default_fields', array(self::class, 'no_cookie_field'), PHP_INT_MAX);
        add_action('comment_form', array(self::class, 'print_in_form'), PHP_INT_MAX);
        add_action('comment_form_before', array(self::class, 'hold_form'), PHP_INT_MIN);
        add_action('comment_form_after', array(self::class, 'print_form'), PHP_INT_MAX);
        add_filter('comment_reply_link', array(self::class, 'link_to_the_form'), PHP_INT_MAX);
        add_filter('cancel_comment_reply_link', array(self::class, 'link_to_the_form'), PHP_INT_MAX);
        // No avatars: each one has every reader's browser ask another site for an image named after a hash of a
        // commenter's email address.
        add_filter('pre_option_show_avatars', array(self::class, 'zero'), PHP_INT_MAX);
        add_action('wp_footer', array(self::class, 'print_block'), PHP_INT_MAX);
    }

    public static function zero(): string
    {
        return '0';
    }

    /** comment_form_before: what WordPress prints of the form from here is held back (see print_form). */
    public static function hold_form(): void
    {
        if (!self::$holding) {
            self::$holding = ob_start();
        }
    }

    /**
     * comment_form_after: the form, printed now, made unable to post by itself. WordPress writes it as a form that
     * posts (method="post", which no filter of its own changes). Left so, a visitor whose browser did not run the
     * script (scripts off, the script not loaded, a press before it had) would post their name, their email address
     * and their words, readable, to the web server and whatever stands before it. So the form whose address is the
     * path gets the method "dialog", and the mark the loader finds it by. bin/check-site refuses a page whose form
     * is anything else.
     */
    public static function print_form(): void
    {
        if (!self::$holding) {
            return;
        }
        self::$holding = false;
        $html = (string) ob_get_clean();
        $settings = self::settings();
        if ($settings !== null) {
            $tags = new \WP_HTML_Tag_Processor($html);
            while ($tags->next_tag('form')) {
                if ($tags->get_attribute('action') === $settings['path']) {
                    $tags->set_attribute('method', 'dialog');
                    $tags->set_attribute(self::FORM_MARK, '1');
                    break;
                }
            }
            $html = $tags->get_updated_html();
        }
        echo $html;
    }

    /**
     * comment_form_defaults: the form's address is the pigeonhole's path. Nothing is ever posted there by the form
     * (see print_form): it is how print_form, the exporter and bin/check-site know the form for the tool's own.
     */
    public static function form_posts_to_the_path($defaults)
    {
        $settings = self::settings();
        if (is_array($defaults) && $settings !== null) {
            $defaults['action'] = $settings['path'];
        }
        return $defaults;
    }

    /** comment_form_default_fields: no "save my name" box, which works by a cookie no static page sets. */
    public static function no_cookie_field($fields)
    {
        if (is_array($fields)) {
            unset($fields['cookies']);
        }
        return $fields;
    }

    /**
     * comment_form (inside the form, at its end): the field no person sees, and a line for a reader without scripts,
     * for whom the form does nothing.
     */
    public static function print_in_form(): void
    {
        echo '<p style="position:absolute;left:-9999px;width:1px;height:1px;overflow:hidden" aria-hidden="true">'
            . '<label>Leave this field empty <input type="text" name="' . self::HIDDEN_FIELD . '" value="" tabindex="-1" autocomplete="off"></label></p>';
        echo '<noscript><p>Comments on this site need JavaScript: a comment is encrypted in your browser before it is sent. Without it, this form sends nothing.</p></noscript>';
    }

    /**
     * comment_reply_link and cancel_comment_reply_link: the link's address becomes #respond. WordPress's own
     * comment-reply script, which export mode keeps for such an export, moves the form under the comment; the
     * address it would otherwise carry (?replytocom=) is a page no static site has.
     */
    public static function link_to_the_form($link)
    {
        if (!is_string($link) || $link === '') {
            return $link;
        }
        $html = new \WP_HTML_Tag_Processor($link);
        while ($html->next_tag('a')) {
            $html->set_attribute('href', '#respond');
        }
        return $html->get_updated_html();
    }

    /** wp_footer: the block and the loader, on a page that shows an open comment form, and nowhere else. */
    public static function print_block(): void
    {
        $settings = self::settings();
        if ($settings === null || !is_singular() || !comments_open(get_queried_object_id())) {
            return;
        }
        echo self::block($settings), "\n";
        echo '<script type="module" src="' . esc_url(WPMU_PLUGIN_URL . '/offprint/pigeonhole-loader.js') . '"></script>', "\n";
    }
}
