<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * The real Fetcher: asks the web server in this container for a public address, in export mode.
 *
 * PHP's curl rather than the WordPress HTTP API: the request must carry exactly these headers, go
 * to the loopback address, and pass through no plugin's HTTP filters. Needs a web server, so it
 * is covered by tests/e2e.sh, not PHPUnit.
 */
final class Fetch implements Fetcher
{
    private const TIMEOUT = 30; // Seconds, per request.

    /** @var string[] */
    private array $headers;

    /**
     * @param string $fetch_base  Where WordPress answers, e.g. http://127.0.0.1
     * @param string $host_header The host WordPress answers to, e.g. mysite.test
     * @param string $secret      Export_Mode's secret, which turns export mode on for the request.
     */
    public function __construct(private string $fetch_base, string $host_header, string $secret)
    {
        $this->fetch_base = rtrim($fetch_base, '/');
        $this->headers = [
            'Host: ' . $host_header,
            'X-Forwarded-Proto: https',
            Export_Mode::HEADER . ': ' . $secret,
        ];
    }

    /**
     * Where the request for a public address goes: its path and query on $fetch_base, and nowhere else. Null for an
     * address with no host, or a path that doesn't start at the root (it would run on into $fetch_base's host).
     */
    public static function target(string $fetch_base, string $url): ?string
    {
        $p = parse_url($url);
        if (!is_array($p) || !isset($p['scheme'], $p['host']) || $p['host'] === '') {
            return null;
        }
        $path = $p['path'] ?? '/';
        if ($path === '' || $path[0] !== '/') {
            return null;
        }
        $base = rtrim($fetch_base, '/');
        $target = $base . $path . (isset($p['query']) ? '?' . $p['query'] : '');
        // A page may write spaces or UTF-8 into an address unencoded; curl needs them encoded.
        $target = (string) preg_replace_callback('~[^\x21-\x7e]~', fn (array $m) => rawurlencode($m[0]), $target);
        return str_starts_with($target, $base . '/') ? $target : null;
    }

    /** A Content-Type header's media type alone, in lower case: "text/xml; charset=UTF-8" is text/xml. */
    public static function media_type(string $content_type): string
    {
        return strtolower(trim(explode(';', $content_type)[0]));
    }

    public function get(string $url): array|string
    {
        $target = self::target($this->fetch_base, $url);
        if ($target === null) {
            return 'it is not an address with a host and a path from the root';
        }

        $body = tmpfile(); // So a large file is never held in memory.
        if ($body === false) {
            return 'no temporary file';
        }
        $curl = curl_init($target);
        if ($curl === false) {
            fclose($body);
            return 'curl could not start';
        }
        $found = ['location' => '', 'content-encoding' => ''];
        curl_setopt_array($curl, [
            CURLOPT_HTTPHEADER => $this->headers, // No cookies, and no Accept-Encoding.
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_PROXY => '', // An http_proxy in the environment must not see the secret.
            CURLOPT_TIMEOUT => self::TIMEOUT,
            CURLOPT_FILE => $body,
            CURLOPT_HEADERFUNCTION => function ($handle, string $line) use (&$found): int {
                $parts = explode(':', $line, 2);
                $name = strtolower(trim($parts[0]));
                if (count($parts) === 2 && isset($found[$name])) {
                    $found[$name] = trim($parts[1]);
                }
                return strlen($line);
            },
        ]);
        if (curl_exec($curl) === false) {
            fclose($body);
            return curl_error($curl);
        }
        $type = (string) curl_getinfo($curl, CURLINFO_CONTENT_TYPE);
        rewind($body);
        return [
            'status' => (int) curl_getinfo($curl, CURLINFO_RESPONSE_CODE),
            'type' => self::media_type($type),
            'location' => $found['location'],
            'encoding' => $found['content-encoding'],
            'body' => $body,
        ];
    }
}
