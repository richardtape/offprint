<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/** Rewrites one origin to another in a response body, in every form WordPress writes it. */
final class Origin
{
    /** The host is whole unless a longer host name or a port continues it. */
    private const END = '(?![A-Za-z0-9_\-]|\.[A-Za-z0-9]|:\d|%3[Aa]\d)';

    public static function rewrite(string $body, string $from, string $to): string
    {
        $f = parse_url($from);
        $t = parse_url($to);
        if (!isset($f['scheme'], $f['host'], $t['scheme'], $t['host'])) {
            return $body;
        }
        $from_host = $f['host'] . (isset($f['port']) ? ':' . $f['port'] : '');
        $to_host = $t['host'] . (isset($t['port']) ? ':' . $t['port'] : '');

        $schemes = [$f['scheme']];
        if ($f['scheme'] === 'https') {
            $schemes[] = 'http';
        }

        // Each form is [text-for-a-url => text-for-a-url] encoded as plain, JSON, URL (two cases).
        $encoders = [
            fn (string $s) => $s,
            fn (string $s) => str_replace('/', '\\/', $s),
            fn (string $s) => str_replace([':', '/'], ['%3A', '%2F'], $s),
            fn (string $s) => str_replace([':', '/'], ['%3a', '%2f'], $s),
        ];

        // Full URLs first, so the protocol-relative pass never sees a leftover scheme.
        foreach ($encoders as $encode) {
            foreach ($schemes as $scheme) {
                $body = self::swap($body, $encode("$scheme://$from_host"), $encode($t['scheme'] . "://$to_host"), '');
            }
        }
        foreach ($encoders as $encode) {
            $body = self::swap(
                $body,
                $encode("//$from_host"),
                $encode("//$to_host"),
                '(?<![:\w])(?<!%3A)(?<!%3a)'
            );
        }
        return $body;
    }

    private static function swap(string $body, string $needle, string $replacement, string $before): string
    {
        $out = preg_replace(
            '~' . $before . preg_quote($needle, '~') . self::END . '~',
            addcslashes($replacement, '\\$'),
            $body
        );
        return $out ?? $body;
    }
}
