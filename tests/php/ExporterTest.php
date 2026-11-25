<?php
declare(strict_types=1);

use PHPUnit\Framework\TestCase;
use Offprint\Exporter;
use Offprint\Fetcher;
use Offprint\Report;
use Offprint\Seeds;

/** Stands in for WordPress: answers each public address from a table. Unknown ones are a 404. */
final class FakeFetcher implements Fetcher
{
    /** @var array<string, array<string, mixed>|Throwable> */
    public array $routes = [];
    /** @var string[] Every address asked for, in order. */
    public array $asked = [];
    /** @var array<string, mixed> What any address not in the table gets, the 404 probe included. */
    public array $missing = ['status' => 404, 'body' => '<html><body>Nothing here</body></html>'];

    public function get(string $url): array|string
    {
        $this->asked[] = $url;
        $route = $this->routes[$url] ?? $this->missing;
        if ($route instanceof Throwable) {
            throw $route;
        }
        if (isset($route['error'])) {
            return $route['error'];
        }
        $route += ['status' => 200, 'type' => 'text/html', 'location' => '', 'encoding' => '', 'body' => ''];
        $body = fopen('php://memory', 'w+b');
        fwrite($body, $route['body']);
        rewind($body);
        return [
            'status' => $route['status'],
            'type' => $route['type'],
            'location' => $route['location'],
            'encoding' => $route['encoding'],
            'body' => $body,
        ];
    }
}

final class ExporterTest extends TestCase
{
    private const O = 'https://blog.example.com';
    private const SECRET = 'sekrit0123456789abcdef0123456789abcdef01';

    private string $out;
    private FakeFetcher $fetcher;

    protected function setUp(): void
    {
        $this->out = sys_get_temp_dir() . '/exporter-test-' . bin2hex(random_bytes(6));
        $this->fetcher = new FakeFetcher();
    }

    protected function tearDown(): void
    {
        if (!is_dir($this->out)) {
            return;
        }
        $files = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($this->out, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($files as $file) {
            $file->isDir() ? rmdir($file->getPathname()) : unlink($file->getPathname());
        }
        rmdir($this->out);
    }

    private static function page(string $body, string $type = 'text/html'): array
    {
        return ['body' => $body, 'type' => $type];
    }

    private static function redirect(string $location, int $status = 301): array
    {
        return ['status' => $status, 'location' => $location];
    }

    /** @param array<string, array|Throwable> $routes Paths (with any query) => response. */
    private function export(array $routes, array $seeds = ['/'], int $max_requests = 20000, bool $sitemaps_off = false): Report
    {
        foreach ($routes as $path => $route) {
            $this->fetcher->routes[self::O . $path] = $route;
        }
        $exporter = new Exporter(self::O, $this->fetcher, 'wp.local', self::SECRET, $max_requests);
        return $exporter->run($this->out, new Seeds(array_map(fn ($p) => self::O . $p, $seeds), [], [], $sitemaps_off));
    }

    private const SITEMAPS_OFF = 'Sitemaps are off, so only pages reachable by links from the home page, the feed and the 404 page will be exported.';

    private static function robots(string $text, string $type = 'text/plain'): array
    {
        return ['body' => $text, 'type' => $type];
    }

    /** A sitemap index of these paths, as a plugin writes one: an xml-stylesheet first, written protocol-relative. */
    private static function sitemap_index(string ...$paths): string
    {
        return '<?xml version="1.0" encoding="UTF-8"?><?xml-stylesheet type="text/xsl" href="//blog.example.com/main-sitemap.xsl"?>'
            . '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
            . implode('', array_map(fn ($p) => '<sitemap><loc>' . self::O . "$p</loc></sitemap>", $paths)) . '</sitemapindex>';
    }

    private static function urlset(string ...$paths): string
    {
        return '<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
            . implode('', array_map(fn ($p) => '<url><loc>' . self::O . "$p</loc></url>", $paths)) . '</urlset>';
    }

    private function asked_for(string $path): bool
    {
        return in_array(self::O . $path, $this->fetcher->asked, true);
    }

    public function test_a_sitemap_index_robots_txt_names_is_read_and_so_are_the_sitemaps_and_pages_it_lists(): void
    {
        $report = $this->export([
            '/' => self::page('Home, linking to nothing'),
            '/robots.txt' => self::robots("User-agent: *\nDisallow:\n\nSitemap: " . self::O . "/sitemap_index.xml\n"),
            '/sitemap_index.xml' => self::page(self::sitemap_index('/post-sitemap.xml', '/page-sitemap.xml'), 'text/xml'),
            '/main-sitemap.xsl' => self::page('<xsl:stylesheet version="1.0"/>', 'text/xsl'),
            '/post-sitemap.xml' => self::page(self::urlset('/a-post/', '/another-post/'), 'application/xml'),
            '/page-sitemap.xml' => self::page(self::urlset('/a-page/'), 'text/xml'),
            '/a-post/' => self::page('A post'),
            '/another-post/' => self::page('Another post'),
            '/a-page/' => self::page('A page'),
        ], ['/', '/robots.txt'], sitemaps_off: true);
        $this->assertSame([], $report->errors);
        $this->assertSame([], $report->warnings); // A sitemap robots.txt names was saved: no "Sitemaps are off".
        foreach (['robots.txt', 'sitemap_index.xml', 'main-sitemap.xsl', 'post-sitemap.xml', 'page-sitemap.xml',
            'a-post/index.html', 'another-post/index.html', 'a-page/index.html'] as $file) {
            $this->assertFileExists("$this->out/$file");
        }
        $this->assertSame(10, $report->files); // Those, the home page and 404.html: each once.
    }

    public function test_the_real_robots_txt_whose_wordpress_sitemap_redirects_to_the_plugins_ends_with_a_file_at_both(): void
    {
        $robots = "User-agent: *\nAllow: /\n\nSitemap: " . self::O . "/wp-sitemap.xml\n\n# START YOAST BLOCK\n"
            . "# ---------------------------\nUser-agent: *\nDisallow:\n\nSitemap: " . self::O . "/sitemap_index.xml\n"
            . "# ---------------------------\n# END YOAST BLOCK";
        $index = self::sitemap_index('/post-sitemap.xml');
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots($robots),
            '/wp-sitemap.xml' => self::redirect(self::O . '/sitemap_index.xml'),
            '/sitemap_index.xml' => self::page($index, 'text/xml'),
            '/main-sitemap.xsl' => self::page('<xsl:stylesheet version="1.0"/>', 'text/xml'),
            '/post-sitemap.xml' => self::page(self::urlset('/hello/'), 'text/xml'),
            '/hello/' => self::page('Hello'),
        ], ['/', '/robots.txt'], sitemaps_off: true);
        $this->assertSame([], $report->errors);
        $this->assertSame([], $report->warnings);
        $this->assertSame($index, file_get_contents("$this->out/wp-sitemap.xml"));
        $this->assertSame($index, file_get_contents("$this->out/sitemap_index.xml"));
        $this->assertSame('Hello', file_get_contents("$this->out/hello/index.html"));
        $this->assertSame(1, count(array_keys($this->fetcher->asked, self::O . '/post-sitemap.xml', true)));
    }

    public function test_a_sitemap_address_robots_txt_names_that_redirects_to_one_it_does_not_name_is_followed(): void
    {
        $index = self::sitemap_index('/post-sitemap.xml');
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots('Sitemap: ' . self::O . '/wp-sitemap.xml'),
            '/wp-sitemap.xml' => self::redirect(self::O . '/sitemap_index.xml'),
            '/sitemap_index.xml' => self::page($index, 'text/xml'),
            '/main-sitemap.xsl' => self::page('<xsl:stylesheet version="1.0"/>', 'text/xsl'),
            '/post-sitemap.xml' => self::page(self::urlset('/hello/'), 'text/xml'),
            '/hello/' => self::page('Hello'),
        ], ['/', '/robots.txt'], sitemaps_off: true);
        $this->assertSame([], $report->errors);
        $this->assertSame([], $report->warnings);
        $this->assertSame($index, file_get_contents("$this->out/wp-sitemap.xml"));
        $this->assertSame($index, file_get_contents("$this->out/sitemap_index.xml"));
        $this->assertSame('Hello', file_get_contents("$this->out/hello/index.html"));
    }

    public function test_a_stale_sitemap_line_in_robots_txt_is_a_warning_and_the_export_goes_on(): void
    {
        $robots = "Sitemap: /gone.xml\nSitemap: /away.xml\nSitemap: /loop.xml\nSitemap: /zipped.xml\nSitemap: /moved\n"
            . "Sitemap: /sitemap.xml\n";
        $report = $this->export([
            '/' => self::page('<a href="/a/">a</a>'),
            '/a/' => self::page('A'),
            '/robots.txt' => self::robots($robots),
            '/away.xml' => self::redirect('https://example.com/sitemap.xml'),
            '/loop.xml' => self::redirect(self::O . '/loop-2.xml'),
            '/loop-2.xml' => self::redirect(self::O . '/loop.xml'),
            '/zipped.xml' => ['body' => "\x1f\x8b", 'type' => 'application/xml', 'encoding' => 'gzip'],
            '/moved' => self::redirect(self::O . '/moved/'),
            '/sitemap.xml' => self::page(self::urlset('/b/'), 'text/xml'),
            '/b/' => self::page('B'),
        ], ['/', '/robots.txt']);
        $this->assertSame([], $report->errors);
        $named = 'robots.txt names the sitemap ' . self::O;
        $this->assertSame([
            "$named/away.xml, which could not be exported: it redirects to https://example.com/sitemap.xml, which is not exported",
            "$named/gone.xml, which could not be exported: it answered 404",
            "$named/loop.xml, which could not be exported: it redirects more than 5 times",
            "$named/moved, which could not be exported: " . self::O . '/moved/ answered 404',
            "$named/zipped.xml, which could not be exported: it could not be fetched: it came back compressed (Content-Encoding: gzip), which the export cannot read",
        ], self::sorted($report->warnings));
        foreach (['index.html', 'a/index.html', 'robots.txt', 'sitemap.xml', 'b/index.html', '404.html'] as $file) {
            $this->assertFileExists("$this->out/$file");
        }
        $this->assertNotContains('https://example.com/sitemap.xml', $this->fetcher->asked);
    }

    public function test_what_a_sitemap_robots_txt_names_lists_is_an_error_when_it_fails_as_for_wordpress_own(): void
    {
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots('Sitemap: /sitemap_index.xml'),
            '/sitemap_index.xml' => self::page(self::sitemap_index('/post-sitemap.xml', '/page-sitemap.xml'), 'text/xml'),
            '/main-sitemap.xsl' => self::page('<xsl:stylesheet version="1.0"/>', 'text/xsl'),
            '/page-sitemap.xml' => self::page(self::urlset('/gone/'), 'text/xml'),
        ], ['/', '/robots.txt']);
        $this->assertSame([
            self::O . '/gone/ answered 404 (linked from ' . self::O . '/page-sitemap.xml).',
            self::O . '/post-sitemap.xml answered 404 (linked from ' . self::O . '/sitemap_index.xml).',
        ], self::sorted($report->errors));
        $this->assertSame([], $report->warnings);
    }

    public function test_sitemaps_off_and_no_sitemap_named_by_robots_txt_saved_is_the_warning_as_before_once(): void
    {
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots("User-agent: *\nDisallow: /\n"),
        ], ['/', '/robots.txt'], sitemaps_off: true);
        $this->assertSame([], $report->errors);
        $this->assertSame([self::SITEMAPS_OFF], $report->warnings);
    }

    public function test_sitemaps_off_and_a_stale_sitemap_line_is_both_warnings_the_sitemaps_one_first(): void
    {
        // As with "Discourage search engines": WordPress's own sitemap is off, and robots.txt still names it.
        $forms = implode('', array_map(fn ($i) => "<form action=\"/f$i/\"></form>", range(1, 3)));
        $report = $this->export([
            '/' => self::page($forms),
            '/robots.txt' => self::robots("User-agent: *\nAllow: /\n\nSitemap: " . self::O . "/wp-sitemap.xml\n"),
        ], ['/', '/robots.txt'], sitemaps_off: true);
        $this->assertSame([], $report->errors);
        $this->assertSame(self::SITEMAPS_OFF, $report->warnings[0]);
        $this->assertSame(1, count(array_keys($report->warnings, self::SITEMAPS_OFF, true)));
        $this->assertContains(
            'robots.txt names the sitemap ' . self::O . '/wp-sitemap.xml, which could not be exported: it answered 404',
            $report->warnings
        );
        $this->assertCount(5, $report->warnings); // And the three forms.
    }

    public function test_sitemaps_on_is_never_the_sitemaps_off_warning(): void
    {
        $report = $this->export(['/' => self::page('Home'), '/robots.txt' => self::robots('')], ['/', '/robots.txt']);
        $this->assertSame([], $report->warnings);
    }

    public function test_a_sitemap_on_another_host_is_left_alone(): void
    {
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots("Sitemap: https://example.com/sitemap.xml\nSitemap: https://cdn.blog.example.com/s.xml\n"),
        ], ['/', '/robots.txt']);
        $this->assertSame([], $report->errors);
        $this->assertSame([], $report->warnings);
        foreach ($this->fetcher->asked as $url) {
            $this->assertStringStartsWith(self::O . '/', $url);
        }
        $this->assertCount(3, $this->fetcher->asked); // The 404 probe, the home page and robots.txt.
    }

    public function test_a_same_site_sitemap_the_rules_refuse_is_the_not_exported_warning_naming_robots_txt(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/?sitemap=1">a page links to it too</a>'),
            '/robots.txt' => self::robots("Sitemap: /?sitemap=1\nSitemap: /wp-json/sitemap.xml\nSitemap: http://blog.example.com/s.xml\n"),
        ], ['/', '/robots.txt']);
        $this->assertSame([], $report->errors);
        $this->assertSame([
            self::O . '/ links to ' . self::O . '/?sitemap=1, which is not exported (2 pages in all).',
            'robots.txt links to http://blog.example.com/s.xml, which is not exported.',
            'robots.txt links to ' . self::O . '/wp-json/sitemap.xml, which is not exported.',
        ], self::sorted($report->warnings));
        $this->assertFalse($this->asked_for('/?sitemap=1'));
        $this->assertFalse($this->asked_for('/wp-json/sitemap.xml'));
        $this->assertNotContains('http://blog.example.com/s.xml', $this->fetcher->asked);
    }

    public function test_a_feed_robots_txt_names_as_a_sitemap_is_the_not_exported_warning_if_it_is_not_the_main_one(): void
    {
        $rss = '<?xml version="1.0"?><rss><channel><link>' . self::O . '/</link></channel></rss>';
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots("Sitemap: /feed/\nSitemap: /tag/x/feed/\n"),
            '/feed/' => self::page($rss, 'application/rss+xml'),
            '/tag/x/feed/' => self::page($rss, 'application/rss+xml'),
        ], ['/', '/robots.txt'], sitemaps_off: true);
        $this->assertSame([], $report->errors);
        // The main feed was saved, so a sitemap robots.txt names was: no "Sitemaps are off".
        $this->assertSame(['robots.txt links to ' . self::O . '/tag/x/feed/, which is not exported.'], $report->warnings);
        $this->assertFileExists("$this->out/feed/index.xml");
        $this->assertDirectoryDoesNotExist("$this->out/tag");
    }

    public function test_a_failing_sitemap_a_page_also_links_to_is_an_error_naming_that_page(): void
    {
        // robots.txt queues it before /deep/ is read; the page's broken link still fails the export, as it did.
        $report = $this->export([
            '/' => self::page('<a href="/deep/">deep</a>'),
            '/deep/' => self::page('<a href="/gone.xml">the sitemap</a>'),
            '/robots.txt' => self::robots('Sitemap: /gone.xml'),
        ], ['/', '/robots.txt']);
        $this->assertSame([self::O . '/gone.xml answered 404 (linked from ' . self::O . '/deep/).'], $report->errors);
        $this->assertSame([], $report->warnings);
    }

    public function test_a_sitemap_wordpress_lists_is_still_an_error_when_robots_txt_names_it_too(): void
    {
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots('Sitemap: ' . self::O . '/wp-sitemap.xml'),
        ], ['/', '/robots.txt', '/wp-sitemap.xml']);
        $this->assertSame([self::O . '/wp-sitemap.xml answered 404 (linked from WordPress).'], $report->errors);
        $this->assertSame([], $report->warnings);
    }

    public function test_a_sitemap_robots_txt_names_that_holds_the_local_host_is_still_an_error(): void
    {
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots('Sitemap: /s.xml'),
            '/s.xml' => self::page('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://wp.local/x/</loc></url></urlset>', 'text/xml'),
        ], ['/', '/robots.txt']);
        $this->assertSame([self::O . '/s.xml contains wp.local, which must never be published.'], $report->errors);
    }

    public function test_robots_txt_is_read_whatever_its_content_type(): void
    {
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots('Sitemap: /s.xml', 'application/octet-stream'),
            '/s.xml' => self::page(self::urlset('/p/'), 'text/xml'),
            '/p/' => self::page('P'),
        ], ['/', '/robots.txt']);
        $this->assertSame([], $report->errors);
        $this->assertFileExists("$this->out/p/index.html");
    }

    public function test_a_robots_txt_anywhere_but_the_root_is_not_read(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/sub/robots.txt">r</a><a href="/robots.txt/">r</a>'),
            '/sub/robots.txt' => self::robots('Sitemap: /from-sub.xml'),
            '/robots.txt/' => self::page('Sitemap: /from-folder.xml'),
        ]);
        $this->assertSame([], $report->errors);
        $this->assertFileExists("$this->out/sub/robots.txt");
        $this->assertFalse($this->asked_for('/from-sub.xml'));
        $this->assertFalse($this->asked_for('/from-folder.xml'));
    }

    public function test_a_600_kb_robots_txt_is_saved_whole_and_read_for_its_first_512_kb(): void
    {
        $limit = 512 * 1024;
        $head = "Sitemap: /early.xml\n";
        // One long comment, so the next line starts 13 bytes before the limit ("Sitemap: /str" is before it).
        $text = $head . '#' . str_repeat('x', $limit - 13 - strlen($head) - 2) . "\n"
            . "Sitemap: /straddle.xml\n" . str_repeat("#\n", 50000) . "Sitemap: /late.xml\n";
        $this->assertGreaterThan(600 * 1024, strlen($text));
        $report = $this->export([
            '/' => self::page('Home'),
            '/robots.txt' => self::robots($text),
            '/early.xml' => self::page(self::urlset('/p/'), 'text/xml'),
            '/p/' => self::page('P'),
        ], ['/', '/robots.txt']);
        $this->assertSame([], $report->errors);
        $this->assertSame(strlen($text), filesize("$this->out/robots.txt"));
        $this->assertTrue($this->asked_for('/early.xml'));
        $this->assertFileExists("$this->out/p/index.html");
        $this->assertSame([], array_values(array_filter($this->fetcher->asked, fn ($u) => str_contains($u, '/str') || str_contains($u, '/late'))));
    }

    private function assertErrorContains(Report $report, string $needle): void
    {
        foreach ($report->errors as $error) {
            if (str_contains($error, $needle)) {
                $this->addToAssertionCount(1);
                return;
            }
        }
        $this->fail("No error contains \"$needle\". Errors:\n" . implode("\n", $report->errors));
    }

    public function test_the_whole_site_is_followed_and_written(): void
    {
        $font = "wOF2\0\x01binary";
        $png = "\x89PNG\r\n\x1a\n\0";
        $this->fetcher->missing['body'] = '<html><img src="/i.png">Nothing here</html>';
        $report = $this->export([
            '/' => self::page('<link rel="stylesheet" href="/s.css?ver=1"><a href="/a/">a</a><img src="/i.png">'
                . '<a href="https://example.com/">away</a><a href="/wp-admin/">admin</a><a href="#top">top</a>'),
            '/s.css?ver=1' => self::page('body{background:url(f.woff2)}', 'text/css'),
            '/f.woff2' => self::page($font, 'font/woff2'),
            '/a/' => self::page('<a href="/?x=1">q</a><a href="/wp-admin/">admin</a><form action="/search/" method="post"></form>'),
            '/i.png' => self::page($png, 'image/png'),
        ]);

        $this->assertSame([], $report->errors);
        $this->assertSame(6, $report->files);
        $written = [
            'index.html', 'a/index.html', 's.css', 'f.woff2', 'i.png', '404.html',
        ];
        $bytes = 0;
        foreach ($written as $file) {
            $this->assertFileExists("$this->out/$file");
            $bytes += filesize("$this->out/$file");
        }
        $this->assertSame($bytes, $report->bytes);
        $this->assertSame($font, file_get_contents("$this->out/f.woff2"));
        $this->assertSame($png, file_get_contents("$this->out/i.png"));
        $this->assertStringContainsString('Nothing here', (string) file_get_contents("$this->out/404.html"));
        $this->assertSame([
            'a form posting to ' . self::O . '/search/ is on 1 page, first seen on ' . self::O . "/a/; it won't work on the static site",
            self::O . '/ links to ' . self::O . '/wp-admin/, which is not exported (2 pages in all).',
            self::O . '/a/ links to ' . self::O . '/?x=1, which is not exported.',
        ], self::sorted($report->warnings));
        $this->assertNotContains('https://example.com/', $this->fetcher->asked);
        $this->assertNotContains(self::O . '/wp-admin/', $this->fetcher->asked);
        $this->assertSame(1, count(array_filter($this->fetcher->asked, fn ($u) => str_contains($u, 's.css'))));
    }

    private static function sorted(array $lines): array
    {
        sort($lines);
        return $lines;
    }

    public function test_forms_are_one_warning_per_form_however_many_pages(): void
    {
        $search = '<form role="search" action="/"><input name="s"></form>';
        $report = $this->export([
            '/' => self::page("<a href=\"/a/\">a</a><a href=\"/b/\">b</a>$search"),
            '/a/' => self::page("$search$search"),
            '/b/' => self::page("$search<form method=\"POST\"></form>"),
        ]);
        $this->assertSame([
            'a form posting to ' . self::O . '/ is on 3 pages, first seen on ' . self::O . "/; it won't work on the static site",
            'a form posting to ' . self::O . '/b/ is on 1 page, first seen on ' . self::O . "/b/; it won't work on the static site",
        ], $report->warnings);
    }

    public function test_a_redirect_to_the_same_file_is_another_link_to_it(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/about">about</a>'),
            '/about' => self::redirect(self::O . '/about/'),
            '/about/' => self::page('About'),
        ]);
        $this->assertSame([], $report->errors);
        $this->assertSame('About', file_get_contents("$this->out/about/index.html"));
    }

    public function test_a_redirect_to_itself_is_an_error(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/x/">x</a>'),
            '/x/' => self::redirect(self::O . '/x/'),
        ]);
        $this->assertErrorContains($report, self::O . '/x/ redirects to itself (linked from ' . self::O . '/)');
        $this->assertDirectoryDoesNotExist("$this->out/x");
    }

    public function test_a_slash_loop_is_an_error_not_a_lost_page(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/a">a</a>'),
            '/a' => self::redirect(self::O . '/a/'),
            '/a/' => self::redirect(self::O . '/a'),
        ]);
        $this->assertErrorContains($report, self::O . '/a redirects to ' . self::O . '/a/, which gave no page to save (linked from ' . self::O . '/)');
        $this->assertDirectoryDoesNotExist("$this->out/a");
    }

    public function test_a_redirect_that_only_drops_the_query_is_followed(): void
    {
        $report = $this->export([
            '/' => self::page('<script src="/x.js?ver=1"></script>'),
            '/x.js?ver=1' => self::redirect(self::O . '/x.js'),
            '/x.js' => self::page('console.log(1)', 'text/javascript'),
        ]);
        $this->assertSame([], $report->errors);
        $this->assertSame('console.log(1)', file_get_contents("$this->out/x.js"));
    }

    public function test_a_followed_redirect_saves_the_page_at_both_addresses_and_counts_its_forms_once(): void
    {
        $after = '<p>Moved</p><form action="/s/"></form>';
        $report = $this->export([
            '/' => self::page('<a href="/before/">old</a>'),
            '/before/' => self::redirect(self::O . '/after/'),
            '/after/' => self::page($after),
        ]);
        $this->assertSame([], $report->errors);
        $this->assertSame($after, file_get_contents("$this->out/before/index.html"));
        $this->assertSame($after, file_get_contents("$this->out/after/index.html"));
        $this->assertSame(
            ['a form posting to ' . self::O . '/s/ is on 1 page, first seen on ' . self::O . "/after/; it won't work on the static site"],
            $report->warnings
        );
    }

    public function test_a_relative_location_is_resolved_against_the_address_asked_for(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/dir/old/">old</a>'),
            '/dir/old/' => self::redirect('../new/', 302),
            '/dir/new/' => self::page('New'),
        ]);
        $this->assertSame([], $report->errors);
        $this->assertSame('New', file_get_contents("$this->out/dir/old/index.html"));
        $this->assertContains(self::O . '/dir/new/', $this->fetcher->asked);
    }

    public function test_redirect_loops_and_long_chains_stop_after_five_hops(): void
    {
        $routes = ['/' => self::page('<a href="/r0/">chain</a><a href="/l1/">loop</a>')];
        for ($i = 0; $i < 8; $i++) {
            $routes["/r$i/"] = self::redirect(self::O . '/r' . ($i + 1) . '/');
        }
        $routes['/l1/'] = self::redirect(self::O . '/l2/');
        $routes['/l2/'] = self::redirect(self::O . '/l1/');
        $report = $this->export($routes);
        $this->assertErrorContains($report, self::O . '/r0/ redirects more than 5 times (linked from ' . self::O . '/)');
        $this->assertErrorContains($report, self::O . '/l1/ redirects more than 5 times (linked from ' . self::O . '/)');
        $this->assertLessThan(20, count($this->fetcher->asked));
    }

    public function test_a_redirect_to_a_refused_address_or_another_site_is_an_error(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/go/">go</a><a href="/away/">away</a>'),
            '/go/' => self::redirect(self::O . '/wp-login.php?redirect_to=x'),
            '/away/' => self::redirect('https://example.com/'),
        ]);
        $this->assertErrorContains($report, self::O . '/go/ redirects to ' . self::O . '/wp-login.php?redirect_to=x, which is not exported (linked from ' . self::O . '/)');
        $this->assertErrorContains($report, self::O . '/away/ redirects to https://example.com/, which is not exported (linked from ' . self::O . '/)');
        $this->assertNotContains('https://example.com/', $this->fetcher->asked);
    }

    public function test_a_folder_that_redirects_to_a_file_is_a_warning_and_the_file_is_exported(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/photo/">attachment page</a>'),
            '/photo/' => self::redirect(self::O . '/wp-content/uploads/p.png'),
            '/wp-content/uploads/p.png' => self::page('PNG', 'image/png'),
        ]);
        $this->assertSame([], $report->errors);
        $this->assertSame([
            self::O . '/photo/ redirects to the file ' . self::O . '/wp-content/uploads/p.png; links to it will not work'
                . ' on the static site (first seen on ' . self::O . '/)',
        ], $report->warnings);
        $this->assertSame('PNG', file_get_contents("$this->out/wp-content/uploads/p.png"));
        $this->assertDirectoryDoesNotExist("$this->out/photo");
    }

    public function test_an_address_with_no_file_name_is_an_error(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/data/">data</a>'),
            '/data/' => self::page('{}', 'application/json'),
        ]);
        $this->assertErrorContains($report, self::O . '/data/ cannot be saved: No file name for a folder with content type "application/json" (linked from ' . self::O . '/)');
    }

    public function test_a_failed_fetch_is_an_error_and_the_crawl_goes_on(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/slow/">slow</a><a href="/boom/">boom</a><a href="/ok/">ok</a>'),
            '/slow/' => ['error' => 'Operation timed out after 30000 milliseconds'],
            '/boom/' => new RuntimeException('Something broke'),
            '/ok/' => self::page('OK'),
        ]);
        $this->assertErrorContains($report, self::O . '/slow/ could not be fetched: Operation timed out after 30000 milliseconds (linked from ' . self::O . '/)');
        $this->assertErrorContains($report, self::O . '/boom/ could not be exported: Something broke (linked from ' . self::O . '/)');
        $this->assertSame('OK', file_get_contents("$this->out/ok/index.html"));
    }

    public function test_a_compressed_response_is_an_error(): void
    {
        $report = $this->export([
            '/' => self::page('<link rel="stylesheet" href="/z.css">'),
            '/z.css' => ['body' => "\x1f\x8b", 'type' => 'text/css', 'encoding' => 'gzip'],
        ]);
        $this->assertErrorContains($report, self::O . '/z.css could not be fetched: it came back compressed (Content-Encoding: gzip)');
        $this->assertFileDoesNotExist("$this->out/z.css");
    }

    public function test_anything_but_200_is_an_error_naming_the_page_that_linked_to_it(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/gone/">gone</a>'),
            '/gone/' => ['status' => 500, 'body' => 'oops'],
        ]);
        $this->assertSame([self::O . '/gone/ answered 500 (linked from ' . self::O . '/).'], $report->errors);
    }

    public function test_the_request_ceiling_stops_the_crawl_with_an_error(): void
    {
        $links = implode('', array_map(fn ($i) => "<a href=\"/$i/\">$i</a>", range(1, 9)));
        $report = $this->export(['/' => self::page($links)], ['/'], 4);
        $this->assertErrorContains($report, 'Stopped at 4 requests');
        $this->assertCount(4, $this->fetcher->asked);
    }

    public function test_two_addresses_for_one_file_is_an_error(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/x/">one</a><a href="/x">two</a>'),
            '/x/' => self::page('one'),
            '/x' => self::page('two'),
        ]);
        $this->assertErrorContains($report, 'x/index.html is already written for ' . self::O . '/x/');
        $this->assertSame('one', file_get_contents("$this->out/x/index.html"));
    }

    public function test_a_body_with_the_local_host_or_the_secret_is_an_error_that_never_prints_the_secret(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/a/">a</a><a href="/b/">b</a>'),
            '/a/' => self::page('Served from WP.LOCAL'),
            '/b/' => self::page('header was ' . self::SECRET),
        ]);
        $this->assertErrorContains($report, self::O . '/a/ contains wp.local, which must never be published.');
        $this->assertErrorContains($report, self::O . '/b/ contains the export secret, which must never be published.');
        $this->assertStringNotContainsString(self::SECRET, implode("\n", $report->errors));
    }

    public function test_the_404_page_must_be_a_404(): void
    {
        $this->fetcher->missing = ['status' => 200, 'body' => 'Everything exists'];
        $report = $this->export(['/' => self::page('Home')]);
        $this->assertErrorContains($report, 'answered 200, not 404, so there is no 404 page.');
        $this->assertFileDoesNotExist("$this->out/404.html");
    }

    public function test_a_site_that_redirects_everything_says_so(): void
    {
        // A "force HTTPS" plugin that sends every request to itself.
        $this->fetcher->missing = ['status' => 301, 'location' => self::O . '/elsewhere/'];
        $report = $this->export(['/' => self::redirect(self::O . '/')]);
        $this->assertErrorContains($report, 'answered 301 (to ' . self::O . '/elsewhere/), not 404, so there is no 404 page.');
        $this->assertErrorContains($report, self::O . '/ redirects to itself (linked from WordPress).');
        $this->assertSame(0, $report->files);
    }

    public function test_seeds_pass_on_their_notes_and_a_refused_seed_is_an_error(): void
    {
        $exporter = new Exporter(self::O, $this->fetcher, 'wp.local', self::SECRET);
        $report = $exporter->run($this->out, new Seeds(
            [self::O . '/?p=1', self::O . '/'],
            ['Sitemaps are off.'],
            ['WordPress broke.']
        ));
        $this->assertContains('Sitemaps are off.', $report->warnings);
        $this->assertContains('WordPress broke.', $report->errors);
        $this->assertErrorContains($report, 'WordPress gave ' . self::O . '/?p=1 as a starting address, but the export may not fetch it.');
    }

    public function test_slugs_with_wordpress_names_are_exported_and_its_own_addresses_are_not(): void
    {
        $report = $this->export([
            '/' => self::page('<a href="/wp-admin-tips/">a</a><a href="/wp-json-explained/">b</a><a href="/tag/wp-admin/">c</a>'
                . '<a href="/tag/wp-json/">d</a><a href="/blog/wp-login.php">e</a><a href="/wp-admin/">f</a><a href="/wp-json/wp/v2/posts">g</a>'),
            '/wp-admin-tips/' => self::page('Tips'),
            '/wp-json-explained/' => self::page('Explained'),
            '/tag/wp-admin/' => self::page('Tag wp-admin'),
            '/tag/wp-json/' => self::page('Tag wp-json'),
            '/blog/wp-login.php' => self::page('A file', 'text/plain'),
        ]);
        $this->assertSame([], $report->errors);
        foreach (['wp-admin-tips/index.html', 'wp-json-explained/index.html', 'tag/wp-admin/index.html', 'tag/wp-json/index.html', 'blog/wp-login.php'] as $file) {
            $this->assertFileExists("$this->out/$file");
        }
        $this->assertSame([
            self::O . '/ links to ' . self::O . '/wp-admin/, which is not exported.',
            self::O . '/ links to ' . self::O . '/wp-json/wp/v2/posts, which is not exported.',
        ], self::sorted($report->warnings));
        $this->assertNotContains(self::O . '/wp-admin/', $this->fetcher->asked);
        $this->assertNotContains(self::O . '/wp-json/wp/v2/posts', $this->fetcher->asked);
    }

    public function test_only_the_main_feed_is_exported_and_another_feed_is_not_an_error(): void
    {
        $rss = '<?xml version="1.0"?><rss><channel><link>' . self::O . '/</link></channel></rss>';
        $report = $this->export([
            '/' => self::page('<a href="/tag/feed/">tag "feed"</a><a href="/tag/x/feed/">x</a><a href="/feed/">feed</a>'
                . '<a href="/a/">a</a>'),
            '/a/' => self::page('<a href="/tag/x/feed/">x</a><a href="/about/feed">comments</a>'),
            '/tag/feed/' => self::page('Posts tagged feed'),
            '/tag/x/feed/' => self::page($rss, 'application/rss+xml'),
            '/about/feed' => self::redirect(self::O . '/about/feed/'),
            '/about/feed/' => self::page($rss, 'application/atom+xml'),
            '/feed/' => self::page($rss, 'application/rss+xml'),
        ]);
        $this->assertSame([], $report->errors);
        $this->assertSame('Posts tagged feed', file_get_contents("$this->out/tag/feed/index.html"));
        $this->assertSame($rss, file_get_contents("$this->out/feed/index.xml"));
        $this->assertDirectoryDoesNotExist("$this->out/tag/x");
        $this->assertDirectoryDoesNotExist("$this->out/about");
        $this->assertSame([
            self::O . '/ links to ' . self::O . '/tag/x/feed/, which is not exported (2 pages in all).',
            self::O . '/a/ links to ' . self::O . '/about/feed, which is not exported.',
        ], self::sorted($report->warnings));
    }

    public function test_a_feed_no_page_links_to_is_skipped_without_a_word(): void
    {
        $report = $this->export([
            '/' => self::page('Home'),
            '/tag/x/feed/' => self::page('<rss/>', 'application/rdf+xml'),
        ], ['/', '/tag/x/feed/']);
        $this->assertSame([], $report->errors);
        $this->assertSame([], $report->warnings);
        $this->assertDirectoryDoesNotExist("$this->out/tag");
    }

    public function test_it_refuses_a_folder_that_is_not_empty_and_fetches_nothing(): void
    {
        mkdir($this->out);
        touch("$this->out/left-over.html");
        $report = $this->export(['/' => self::page('Home')]);
        $this->assertErrorContains($report, 'is not empty');
        $this->assertSame([], $this->fetcher->asked);
    }
}
