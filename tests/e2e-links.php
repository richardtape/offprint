<?php
/**
 * For tests/e2e.sh: every same-site address that an exported page or stylesheet uses must have a
 * file in the export, as a browser would need it. It reads the folder with its own small parser,
 * not the exporter's classes, so a gap in those shows up here.
 *
 *   php -- EXPORT_DIR PUBLIC_ORIGIN < tests/e2e-links.php
 *
 * Looks at href, src and srcset in every .html file, the import map's addresses, and url() and
 * @import in .css files and in pages' inline styles. Prints "missing <file> -> <address>" for
 * each address with no file, then "checked <n>". Exits 1 if anything is missing.
 */
declare(strict_types=1);

[, $dir, $origin] = $argv;
$dir = rtrim($dir, '/');
$origin = rtrim($origin, '/');
$host = (string) parse_url($origin, PHP_URL_HOST);

/** The absolute http(s) address $ref means on the page at $base, or null. */
function resolve(string $ref, string $base): ?string
{
    $ref = trim((string) preg_replace('~#.*$~s', '', $ref));
    if ($ref === '') {
        return null;
    }
    if (preg_match('~^[a-z][a-z0-9+.-]*:~i', $ref)) {
        return preg_match('~^https?://~i', $ref) ? $ref : null;
    }
    $b = parse_url($base);
    $site = $b['scheme'] . '://' . $b['host'];
    $base_path = $b['path'] ?? '/';
    if (str_starts_with($ref, '//')) {
        return $b['scheme'] . ':' . $ref;
    }
    if ($ref[0] === '?') {
        return $site . $base_path . $ref;
    }
    $path = $ref[0] === '/' ? $ref : substr($base_path, 0, (int) strrpos($base_path, '/') + 1) . $ref;
    $out = [];
    foreach (explode('/', (string) parse_url($path, PHP_URL_PATH)) as $segment) {
        if ($segment === '..') {
            if (count($out) > 1) {
                array_pop($out);
            }
        } elseif ($segment !== '.') {
            $out[] = $segment;
        }
    }
    return $site . implode('/', $out);
}

/** @return string[] The addresses as written in an HTML page. */
function html_refs(string $html): array
{
    $refs = [];
    preg_match_all('~\s(href|src|srcset)\s*=\s*(["\'])(.*?)\2~is', $html, $m, PREG_SET_ORDER);
    foreach ($m as [, $name, , $value]) {
        $value = html_entity_decode($value, ENT_QUOTES | ENT_HTML5);
        if (strtolower($name) !== 'srcset') {
            $refs[] = $value;
            continue;
        }
        foreach (explode(',', $value) as $candidate) {
            $refs[] = preg_split('~\s+~', trim($candidate))[0];
        }
    }
    preg_match_all('~<script[^>]*type=["\']importmap["\'][^>]*>(.*?)</script>~is', $html, $maps);
    foreach ($maps[1] as $json) {
        foreach ((array) (json_decode($json, true)['imports'] ?? []) as $address) {
            $refs[] = (string) $address;
        }
    }
    return array_merge($refs, css_refs(html_entity_decode($html, ENT_QUOTES | ENT_HTML5)));
}

/** @return string[] The url() and @import "…" addresses in CSS. */
function css_refs(string $css): array
{
    $css = (string) preg_replace('~/\*.*?\*/~s', '', $css);
    preg_match_all('~url\(\s*(["\']?)([^"\')]*)\1\s*\)~i', $css, $m);
    preg_match_all('~@import\s+(["\'])(.*?)\1~i', $css, $imports);
    return array_merge($m[2], $imports[2]);
}

$checked = 0;
$missing = [];
$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
foreach ($files as $file) {
    $ext = strtolower($file->getExtension());
    if ($ext !== 'html' && $ext !== 'css') {
        continue;
    }
    $rel = substr($file->getPathname(), strlen($dir));
    $page = $origin . preg_replace('~(?<=/)index\.html$~', '', $rel);
    $text = (string) file_get_contents($file->getPathname());

    foreach ($ext === 'html' ? html_refs($text) : css_refs($text) as $ref) {
        $url = resolve($ref, $page);
        if ($url === null || strcasecmp((string) parse_url($url, PHP_URL_HOST), $host) !== 0) {
            continue;
        }
        $checked++;
        $path = rawurldecode((string) parse_url($url, PHP_URL_PATH));
        $folder = $path === '' || str_ends_with($path, '/') || pathinfo($path, PATHINFO_EXTENSION) === '';
        $candidates = $folder ? [rtrim($path, '/') . '/index.html', rtrim($path, '/') . '/index.xml'] : [$path];
        if (!array_filter($candidates, fn ($candidate) => is_file($dir . $candidate))) {
            $missing["missing $rel -> $url"] = true;
        }
    }
}

foreach (array_keys($missing) as $line) {
    echo $line, "\n";
}
echo "checked $checked\n";
exit($missing ? 1 : 0);
