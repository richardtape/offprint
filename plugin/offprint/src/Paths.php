<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

use InvalidArgumentException;

/**
 * Maps a URL path to the file it is saved as, relative to the output folder.
 * No WordPress functions: this runs under plain PHPUnit.
 */
final class Paths
{
    /**
     * Throws InvalidArgumentException only when the decoded path has a ".." segment or a NUL byte,
     * or is a folder whose content type is neither HTML nor XML.
     *
     * @param string $url_path     The path only (no query string), as in a URL.
     * @param string $content_type The response Content-Type header value.
     * @throws InvalidArgumentException If the path could escape the output folder.
     */
    public static function to_file(string $url_path, string $content_type): string
    {
        $decoded = rawurldecode($url_path);
        if (str_contains($decoded, "\0")) {
            throw new InvalidArgumentException('Path contains a NUL byte');
        }

        $segments = [];
        foreach (preg_split('#[/\\\\]#', $decoded) as $segment) {
            if ($segment === '..') {
                throw new InvalidArgumentException('Path contains a ".." segment');
            }
            if ($segment === '' || $segment === '.') {
                continue;
            }
            $segments[] = $segment;
        }

        if (!self::is_folder($url_path)) {
            return implode('/', $segments);
        }

        $type = strtolower(trim(explode(';', $content_type)[0]));
        if ($type === 'text/html' || $type === 'application/xhtml+xml') {
            $index = 'index.html';
        } elseif ($type === 'application/xml' || $type === 'text/xml' || str_ends_with($type, '+xml')) {
            $index = 'index.xml';
        } else {
            throw new InvalidArgumentException("No file name for a folder with content type \"$type\"");
        }

        $segments[] = $index;
        return implode('/', $segments);
    }

    /** Whether a URL path is a folder: a trailing slash, or no extension on its last segment. */
    public static function is_folder(string $url_path): bool
    {
        $decoded = rawurldecode($url_path);
        $segments = array_filter(preg_split('#[/\\\\]#', $decoded), fn ($s) => $s !== '' && $s !== '.');
        return $segments === []
            || str_ends_with($decoded, '/')
            || pathinfo((string) end($segments), PATHINFO_EXTENSION) === '';
    }
}
