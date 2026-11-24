<?php
declare(strict_types=1);

use PHPUnit\Framework\TestCase;
use Offprint\Links;

final class LinksTest extends TestCase
{
    private const B = 'https://blog.example.com/dir/page/';

    private function has(array $found, string ...$urls): void
    {
        foreach ($urls as $u) {
            $this->assertContains($u, $found);
        }
    }

    public function test_html_elements(): void
    {
        $html = '<html><head><link rel="stylesheet" href="/s.css?ver=1"><link rel="modulepreload" href="m.js">
<script src="/a.js"></script>
<script type="importmap">{"imports":{"x":"/imp/x.js","y":"https://blog.example.com/imp/y.js"}}</script>
<style>body{background:url(/bg.png)} @import "/st.css";</style></head>
<body><a href="../up/">u</a><img src="i.jpg" srcset="a.jpg 1x, b.jpg 2x">
<picture><source srcset="/p1.webp 100w, /p2.webp 200w"><source src="/s.mp4"></picture>
<video src="v.mp4" poster="/poster.jpg"></video><audio src="/au.mp3"></audio>
<div style="background:url(\'/inline.png\')"></div></body></html>';
        $f = Links::from_html($html, self::B);
        $this->has($f,
            'https://blog.example.com/s.css?ver=1',
            'https://blog.example.com/dir/page/m.js',
            'https://blog.example.com/a.js',
            'https://blog.example.com/imp/x.js',
            'https://blog.example.com/imp/y.js',
            'https://blog.example.com/bg.png',
            'https://blog.example.com/st.css',
            'https://blog.example.com/dir/up/',
            'https://blog.example.com/dir/page/i.jpg',
            'https://blog.example.com/dir/page/a.jpg',
            'https://blog.example.com/dir/page/b.jpg',
            'https://blog.example.com/p1.webp',
            'https://blog.example.com/p2.webp',
            'https://blog.example.com/s.mp4',
            'https://blog.example.com/dir/page/v.mp4',
            'https://blog.example.com/poster.jpg',
            'https://blog.example.com/au.mp3',
            'https://blog.example.com/inline.png',
        );
    }

    public function test_srcset_with_encoded_name_and_w_descriptors(): void
    {
        $f = Links::from_html('<img srcset="a.jpg 1x, b%20c.jpg 2x, d.jpg 300w">', self::B);
        $this->assertSame([
            'https://blog.example.com/dir/page/a.jpg',
            'https://blog.example.com/dir/page/b%20c.jpg',
            'https://blog.example.com/dir/page/d.jpg',
        ], $f);
    }

    public function test_skips_non_http_and_fragments_and_dedupes(): void
    {
        $html = '<a href="#top">1</a><a href="mailto:a@b.c">2</a><a href="tel:123">3</a>
<a href="javascript:void(0)">4</a><img src="data:image/png;base64,AAAA">
<a href="/x/#one">5</a><a href="/x/#two">6</a><a href="https://example.com/o">7</a>';
        $this->assertSame([
            'https://blog.example.com/x/',
            'https://example.com/o',
        ], Links::from_html($html, self::B));
    }

    public function test_base_href_is_respected(): void
    {
        $html = '<head><base href="https://blog.example.com/other/"></head><a href="z/">z</a>';
        $this->assertSame(['https://blog.example.com/other/z/'], Links::from_html($html, self::B));
    }

    public function test_malformed_html5_and_utf8(): void
    {
        $html = '<!DOCTYPE html><main><nav><a href="/café/ñ/">é</a><p>unclosed <a href=/x>y<section></div><a href="/日本/">語';
        $f = Links::from_html($html, self::B);
        $this->assertSame([
            'https://blog.example.com/café/ñ/',
            'https://blog.example.com/x',
            'https://blog.example.com/日本/',
        ], $f);
        $this->assertSame([], Links::from_html('', self::B));
    }

    public function test_css(): void
    {
        $css = '@font-face{src:url(a.woff2)} .x{background:url("b.png")} .y{background:url(\'c.svg\')}
@import "d.css"; @import url(e.css); .z{background:url(data:image/png;base64,AAAA)}';
        $this->assertSame([
            'https://blog.example.com/dir/page/a.woff2',
            'https://blog.example.com/dir/page/b.png',
            'https://blog.example.com/dir/page/c.svg',
            'https://blog.example.com/dir/page/d.css',
            'https://blog.example.com/dir/page/e.css',
        ], Links::from_css($css, self::B));
    }

    public function test_module(): void
    {
        $js = 'import x from "./a.js"; const m = import("./b.js"); export * from \'../c.js\';
import y from "@wordpress/interactivity"; import {q} from "./d.js";';
        $this->assertSame([
            'https://blog.example.com/dir/page/a.js',
            'https://blog.example.com/dir/page/b.js',
            'https://blog.example.com/dir/c.js',
            'https://blog.example.com/dir/page/d.js',
        ], Links::from_module($js, self::B));
    }

    public function test_forms(): void
    {
        $this->assertSame(
            [['action' => 'https://blog.example.com/', 'method' => 'get']],
            Links::forms('<form action="/"><input></form><p>', self::B)
        );
        $this->assertSame([], Links::forms('<p>none</p>', self::B));
        $this->assertSame([], Links::forms('', self::B));
        $this->assertSame([
            ['action' => self::B, 'method' => 'get'],                                       // no action: the page itself
            ['action' => self::B, 'method' => 'post'],                                      // empty action
            ['action' => self::B, 'method' => 'get'],                                       // a fragment
            ['action' => 'https://blog.example.com/dir/page/go/', 'method' => 'post'],  // relative, method in capitals
            ['action' => 'https://blog.example.com/wp-login.php', 'method' => 'get'],   // an unknown method is GET
            ['action' => 'mailto:a@b.c', 'method' => 'post'],                               // not http: kept as written
        ], Links::forms(
            '<form></form><form action="" method="post"></form><form action="#x"></form>'
            . '<form action="go/" method="POST"></form><form action="/wp-login.php" method="put"></form>'
            . '<form action="mailto:a@b.c" method="post"></form>',
            self::B
        ));
    }

    public function test_forms_respect_the_base_href(): void
    {
        $this->assertSame(
            [['action' => 'https://blog.example.com/other/s/', 'method' => 'get']],
            Links::forms('<head><base href="/other/"></head><form action="s/"></form>', self::B)
        );
    }

    public function test_resolve(): void
    {
        $this->assertSame('https://blog.example.com/dir/new/', Links::resolve('../new/', self::B));
        $this->assertSame('https://blog.example.com/x/', Links::resolve('/x/#frag', self::B));
        $this->assertSame('https://example.com/', Links::resolve('https://example.com/', self::B));
        $this->assertNull(Links::resolve('mailto:a@b.c', self::B));
        $this->assertNull(Links::resolve('#top', self::B));
    }

    public function test_importmap_only_imports_and_scopes(): void
    {
        $html = '<script type="importmap">{"imports":{"a":"/i/a.js"},"scopes":{"/s/":{"b":"/s/b.js"}},'
            . '"integrity":{"/i/a.js":"sha384-abc"},"other":{"c":"/o/c.js"}}</script>';
        $this->assertSame([
            'https://blog.example.com/i/a.js',
            'https://blog.example.com/s/b.js',
        ], Links::from_html($html, self::B));
    }

    public function test_css_comments_are_ignored(): void
    {
        $css = '/* url(old.png) @import "old.css"; */ a{background:url(new.png)} /* multi
line url(x.png) */';
        $this->assertSame(['https://blog.example.com/dir/page/new.png'], Links::from_css($css, self::B));
    }

    public function test_sitemap_index_locs_and_stylesheet(): void
    {
        $xml = '<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="https://blog.example.com/wp-sitemap-index.xsl" ?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<sitemap><loc>https://blog.example.com/wp-sitemap-posts-post-1.xml</loc></sitemap>
<sitemap><loc>
  /wp-sitemap-users-1.xml
</loc></sitemap></sitemapindex>';
        $this->assertSame([
            'https://blog.example.com/wp-sitemap-index.xsl',
            'https://blog.example.com/wp-sitemap-posts-post-1.xml',
            'https://blog.example.com/wp-sitemap-users-1.xml',
        ], Links::from_sitemap($xml, 'https://blog.example.com/wp-sitemap.xml'));
    }

    public function test_sitemap_urlset_entities_and_single_quoted_stylesheet(): void
    {
        $xml = "<?xml version=\"1.0\"?><?xml-stylesheet href='/s.xsl?a=1&amp;b=2' type='text/xsl'?>"
            . '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
            . '<url><loc>https://blog.example.com/a/?x=1&amp;y=2</loc><lastmod>2026-11-20</lastmod></url>'
            . '<url><loc>https://blog.example.com/caf%C3%A9/</loc></url></urlset>';
        $this->assertSame([
            'https://blog.example.com/s.xsl?a=1&b=2',
            'https://blog.example.com/a/?x=1&y=2',
            'https://blog.example.com/caf%C3%A9/',
        ], Links::from_sitemap($xml, 'https://blog.example.com/wp-sitemap-posts-post-1.xml'));
    }

    public function test_sitemap_reads_nothing_from_what_is_not_a_sitemap(): void
    {
        $base = 'https://blog.example.com/wp-sitemap.xsl';
        // The sitemap stylesheet names sitemap:loc in XPath only, not as an element.
        $xsl = '<?xml version="1.0"?><xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"'
            . ' xmlns:sitemap="http://www.sitemaps.org/schemas/sitemap/0.9"><xsl:template match="/">'
            . '<a href="{sitemap:loc}"><xsl:value-of select="sitemap:loc"/></a></xsl:template></xsl:stylesheet>';
        $this->assertSame([], Links::from_sitemap($xsl, $base));
        $this->assertSame([], Links::from_sitemap('<loc>https://blog.example.com/no-namespace/</loc>', $base));
        $this->assertSame([], Links::from_sitemap('<urlset><unclosed>', $base));
        $this->assertSame([], Links::from_sitemap('', $base));
    }
}
