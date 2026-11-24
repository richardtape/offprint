<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Offprint\Rules;

final class RulesTest extends TestCase
{
    private const O = 'https://blog.example.com';

    public static function allowed(): array
    {
        $o = self::O;
        return array_map(fn ($u) => [$u], [
            "$o/", "$o/about/", "$o/page/2/", "$o/feed/",
            "$o/wp-includes/css/x.css?ver=6.9", "$o/wp-content/uploads/a.jpg",
            "$o/wp-sitemap.xml", "$o/comments/", "$o/2026/11/comments/", "$o/about/#frag",
            // WordPress's own names inside a slug, or deeper than the first segment, are a post, a tag or a file.
            "$o/wp-admin-tips/", "$o/wp-json-explained/", "$o/tag/wp-admin/", "$o/tag/wp-json/", "$o/tag/xmlrpc-php/",
            "$o/blog/wp-login.php", "$o/2026/11/wp-cron.php", "$o/tag/wp-admin/page/2/",
            // Feeds are decided by what the server sends (see Exporter): /tag/feed/ is the archive of a tag named
            // "feed", and by its path alone it can't be told from /tag/x/feed/, a feed.
            "$o/tag/feed/", "$o/tag/feed/page/2/", "$o/tag/x/feed/", "$o/about/feed/", "$o/comments/feed/",
            "$o/category/x/feed/atom/",
            // index.php's name deeper down, or wp-json after a first segment that isn't index.php.
            "$o/tag/index.php/wp-json/", "$o/about/index.php", "$o/index.php/about/",
        ]);
    }

    public static function refused(): array
    {
        $o = self::O;
        return array_map(fn ($u) => [$u], [
            "$o/wp-admin/", "$o/wp-admin", "$o/WP-Admin/edit.php", "$o/wp-login.php", "$o/wp-json/wp/v2/posts", "$o/wp-json",
            "$o/xmlrpc.php", "$o/wp-cron.php", "$o/wp-comments-post.php", "$o/wp-trackback.php",
            "$o/wp-signup.php", "$o/wp-activate.php", "$o/wp-login.php/x",
            // The same reached another way: the REST API behind index.php, dot segments, doubled or encoded slashes.
            "$o/index.php/wp-json/wp/v2/posts", "$o/x/../wp-admin/", "$o/%2e%2e/wp-admin/", "$o//wp-admin/", "$o/%77p-admin/",
            // WordPress matches what follows /index.php/ against its rule ^index.php/wp-json, whose dot is any
            // character: so wp-json anywhere after a leading index.php, and index.php spelled with any dot.
            "$o/index.php/index.php/wp-json/wp/v2/posts", "$o/index.php/indexXphp/wp-json/", "$o/INDEX.PHP/wp-json/",
            "$o/index.php/tag/x/wp-json/", "$o/indexXphp/wp-json/wp/v2/posts", "$o/index.php/index.php/wp-admin/",
            "$o/index.php/index.php/wp-login.php",
            // More of WordPress's entry points at the root.
            "$o/wp-mail.php", "$o/wp-links-opml.php", "$o/index.php/wp-mail.php",
            "$o/?s=x", "$o/?p=12", "$o/about/?replytocom=3",
            "$o/x.css?ver=1&b=2", "$o/x.css?b=2", "$o/about/?ver=6.9",
            "https://example.com/", "https://blog.example.com.evil.test/",
            "http://blog.example.com/", "mailto:a@b.c", "data:image/png;base64,AAAA", "#top", "",
        ]);
    }

    #[DataProvider('allowed')]
    public function test_fetches(string $url): void
    {
        $this->assertTrue(Rules::should_fetch($url, self::O));
    }

    #[DataProvider('refused')]
    public function test_refuses(string $url): void
    {
        $this->assertFalse(Rules::should_fetch($url, self::O));
    }
}
