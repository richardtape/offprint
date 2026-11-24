<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

use DOMDocument;
use DOMElement;
use DOMProcessingInstruction;
use DOMXPath;

/** Finds the URLs a page, stylesheet, script or sitemap refers to. Returns absolute, de-duplicated URLs. */
final class Links
{
    private const SRC_TAGS = ['script', 'img', 'video', 'audio', 'source', 'track', 'embed', 'iframe'];
    private const HREF_TAGS = ['a', 'link', 'area'];
    private const SITEMAP_NS = 'http://www.sitemaps.org/schemas/sitemap/0.9';

    public static function from_html(string $html, string $base_url): array
    {
        $doc = self::load($html);
        if ($doc === null) {
            return [];
        }
        $base = self::base_of($doc, $base_url);

        $refs = [];
        foreach ((new DOMXPath($doc))->query('//*') as $el) {
            /** @var DOMElement $el */
            $tag = strtolower($el->localName);

            if (in_array($tag, self::HREF_TAGS, true) && $el->hasAttribute('href')) {
                $refs[] = $el->getAttribute('href');
            }
            if (in_array($tag, self::SRC_TAGS, true) && $el->hasAttribute('src')) {
                $refs[] = $el->getAttribute('src');
            }
            if ($tag === 'video' && $el->hasAttribute('poster')) {
                $refs[] = $el->getAttribute('poster');
            }
            if (($tag === 'img' || $tag === 'source') && $el->hasAttribute('srcset')) {
                array_push($refs, ...self::srcset($el->getAttribute('srcset')));
            }
            if ($el->hasAttribute('style')) {
                array_push($refs, ...self::css_refs($el->getAttribute('style')));
            }
            if ($tag === 'style') {
                array_push($refs, ...self::css_refs($el->textContent));
            }
            if ($tag === 'script' && strtolower(trim($el->getAttribute('type'))) === 'importmap') {
                $map = json_decode($el->textContent, true);
                if (is_array($map)) {
                    // Only "imports" and each scope's map hold addresses; "integrity" holds hashes.
                    $maps = [$map['imports'] ?? []];
                    foreach (is_array($map['scopes'] ?? null) ? $map['scopes'] : [] as $scope) {
                        $maps[] = $scope;
                    }
                    foreach ($maps as $entries) {
                        foreach (is_array($entries) ? $entries : [] as $address) {
                            if (is_string($address)) {
                                $refs[] = $address;
                            }
                        }
                    }
                }
            }
        }

        return self::absolute($refs, $base);
    }

    public static function from_css(string $css, string $base_url): array
    {
        return self::absolute(self::css_refs($css), $base_url);
    }

    public static function from_module(string $js, string $base_url): array
    {
        preg_match_all(
            '~(?:\bfrom|\bimport\s*\(?)\s*(["\'])([^"\'\r\n]+)\1~',
            $js,
            $m
        );
        $refs = [];
        foreach ($m[2] as $spec) {
            // Bare names ("@wordpress/interactivity") come from the import map.
            if (preg_match('~^(?:\./|\.\./|/|https?://)~i', $spec)) {
                $refs[] = $spec;
            }
        }
        return self::absolute($refs, $base_url);
    }

    /**
     * A sitemap's or sitemap index's <loc> addresses, and its xml-stylesheet. Anything else
     * (the stylesheet itself, a feed, broken XML) gives none.
     */
    public static function from_sitemap(string $xml, string $base_url): array
    {
        if (trim($xml) === '') {
            return [];
        }
        $doc = new DOMDocument();
        $previous = libxml_use_internal_errors(true);
        try {
            $loaded = $doc->loadXML($xml, LIBXML_NONET);
        } finally {
            libxml_clear_errors();
            libxml_use_internal_errors($previous);
        }
        if (!$loaded) {
            return [];
        }

        $refs = [];
        foreach ($doc->childNodes as $node) {
            if ($node instanceof DOMProcessingInstruction && $node->target === 'xml-stylesheet'
                && preg_match('~\bhref\s*=\s*(["\'])(.*?)\1~s', $node->data, $m)) {
                // A processing instruction's pseudo-attributes are not parsed, so decode them here.
                $refs[] = html_entity_decode($m[2], ENT_QUOTES | ENT_XML1, 'UTF-8');
            }
        }
        foreach ($doc->getElementsByTagNameNS(self::SITEMAP_NS, 'loc') as $loc) {
            $refs[] = $loc->textContent;
        }
        return self::absolute($refs, $base_url);
    }

    /**
     * Each form on the page: where it sends (resolved; the page itself when there is no action)
     * and how (get or post; an unknown method is get, as in a browser).
     *
     * @return array<int, array{action: string, method: string}>
     */
    public static function forms(string $html, string $base_url): array
    {
        $doc = self::load($html);
        if ($doc === null) {
            return [];
        }
        $base = self::base_of($doc, $base_url);
        $page = (string) preg_replace('~#.*$~s', '', $base);

        $forms = [];
        foreach ($doc->getElementsByTagName('form') as $form) {
            $action = trim($form->getAttribute('action'));
            $method = strtolower(trim($form->getAttribute('method')));
            $forms[] = [
                'action' => ($action === '' || $action[0] === '#') ? $page : (self::resolve($action, $base) ?? $action),
                'method' => in_array($method, ['post', 'dialog'], true) ? $method : 'get',
            ];
        }
        return $forms;
    }

    private static function load(string $html): ?DOMDocument
    {
        if (trim($html) === '') {
            return null;
        }
        $doc = new DOMDocument();
        $previous = libxml_use_internal_errors(true);
        try {
            // The prefix makes libxml read the bytes as UTF-8.
            $doc->loadHTML('<?xml encoding="UTF-8">' . $html, LIBXML_NOERROR | LIBXML_NOWARNING | LIBXML_NONET);
        } finally {
            libxml_clear_errors();
            libxml_use_internal_errors($previous);
        }
        return $doc;
    }

    /** url(...) and @import "..." in CSS, in order. */
    private static function css_refs(string $css): array
    {
        $css = preg_replace('~/\*.*?\*/~s', '', $css) ?? $css;
        preg_match_all(
            '~url\(\s*(?:"([^"]*)"|\'([^\']*)\'|([^)\s"\']*))\s*\)|@import\s+(?:"([^"]*)"|\'([^\']*)\')~i',
            $css,
            $m,
            PREG_SET_ORDER
        );
        $refs = [];
        foreach ($m as $set) {
            for ($i = 1; $i <= 5; $i++) {
                if (isset($set[$i]) && $set[$i] !== '') {
                    $refs[] = $set[$i];
                    break;
                }
            }
        }
        return $refs;
    }

    /** The URLs in a srcset value; a comma inside a URL is kept. */
    private static function srcset(string $value): array
    {
        $urls = [];
        $len = strlen($value);
        $i = 0;
        while ($i < $len) {
            while ($i < $len && (ctype_space($value[$i]) || $value[$i] === ',')) {
                $i++;
            }
            $start = $i;
            while ($i < $len && !ctype_space($value[$i])) {
                $i++;
            }
            $url = substr($value, $start, $i - $start);
            if ($url === '') {
                break;
            }
            if (str_ends_with($url, ',')) {
                $url = rtrim($url, ',');
            } else {
                while ($i < $len && $value[$i] !== ',') {
                    $i++;
                }
            }
            if ($url !== '') {
                $urls[] = $url;
            }
        }
        return $urls;
    }

    private static function absolute(array $refs, string $base): array
    {
        $out = [];
        foreach ($refs as $ref) {
            $url = self::resolve($ref, $base);
            if ($url !== null) {
                $out[$url] = true;
            }
        }
        return array_keys($out);
    }

    /** The page's <base href> if it has one, else the address it came from. */
    private static function base_of(DOMDocument $doc, string $base_url): string
    {
        foreach ($doc->getElementsByTagName('base') as $el) {
            $href = trim($el->getAttribute('href'));
            if ($href !== '') {
                return self::resolve($href, $base_url) ?? $base_url;
            }
        }
        return $base_url;
    }

    /**
     * Resolves a reference against a base (RFC 3986), without its fragment.
     * Null for a fragment alone, or unless the result is http(s).
     */
    public static function resolve(string $ref, string $base): ?string
    {
        $ref = trim($ref);
        if ($ref === '' || $ref[0] === '#') {
            return null;
        }
        $ref = preg_replace('~#.*$~s', '', $ref);
        $b = parse_url($base);
        if (!isset($b['scheme'], $b['host'])) {
            return null;
        }
        $authority = $b['host'] . (isset($b['port']) ? ':' . $b['port'] : '');

        if (preg_match('~^([a-z][a-z0-9+.\-]*):~i', $ref, $s)) {
            $scheme = strtolower($s[1]);
            if ($scheme !== 'http' && $scheme !== 'https') {
                return null;
            }
            if (!preg_match('~^[a-z]+://[^/?#]+~i', $ref)) {
                return null;
            }
            return self::dedot($ref);
        }
        if (str_starts_with($ref, '//')) {
            return self::dedot($b['scheme'] . ':' . $ref);
        }

        $prefix = $b['scheme'] . '://' . $authority;
        $base_path = $b['path'] ?? '/';
        if ($ref[0] === '/') {
            return self::dedot($prefix . $ref);
        }
        if ($ref[0] === '?') {
            return $prefix . $base_path . $ref;
        }
        $dir = substr($base_path, 0, (int) strrpos($base_path, '/') + 1);
        return self::dedot($prefix . $dir . $ref);
    }

    private static function dedot(string $url): string
    {
        preg_match('~^([a-z]+://[^/?#]+)([^?#]*)(.*)$~is', $url, $m);
        $out = [];
        $segments = explode('/', $m[2]);
        $last = count($segments) - 1;
        foreach ($segments as $i => $seg) {
            if ($seg === '..') {
                if (count($out) > 1) {
                    array_pop($out);
                }
                if ($i === $last) {
                    $out[] = '';
                }
            } elseif ($seg === '.') {
                if ($i === $last) {
                    $out[] = '';
                }
            } else {
                $out[] = $seg;
            }
        }
        $path = implode('/', $out);
        if ($path === '' || $path[0] !== '/') {
            $path = '/' . $path;
        }
        return $m[1] . $path . $m[3];
    }
}
