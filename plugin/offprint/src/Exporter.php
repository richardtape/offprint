<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

use Closure;
use InvalidArgumentException;
use RuntimeException;
use SplQueue;
use Throwable;

/**
 * The crawl behind `wp offprint export`: fetches every public page, and every file those pages
 * use, from WordPress's own logged-out front end, and writes them into an empty folder.
 *
 * It works in public addresses throughout, because that is what export-mode pages contain; the
 * Fetcher turns each into a request. No WordPress functions: PHPUnit runs it with a fake Fetcher,
 * and tests/e2e.sh runs it against WordPress.
 */
final class Exporter
{
    private const MAX_REDIRECTS = 5;
    private const REDIRECTS = [301, 302, 303, 307, 308];
    private const JS_TYPES = [
        'text/javascript', 'application/javascript', 'application/x-javascript',
        'text/ecmascript', 'application/ecmascript',
    ];
    /** Feeds. Only the main one, at /feed/, is exported: every post in another is on the site already. */
    private const FEED_TYPES = ['application/rss+xml', 'application/atom+xml', 'application/rdf+xml'];
    /** The referrer named for an address WordPress itself gave. */
    private const SEED = 'WordPress';
    /** The referrer named for a sitemap the site's robots.txt names. */
    private const ROBOTS = 'robots.txt';
    /**
     * How much of robots.txt is read for its Sitemap: lines (it is saved whole). Search engines read about this much
     * and ignore the rest, so a line past it would do nothing on the live site either.
     */
    private const ROBOTS_BYTES = 512 * 1024;
    private const SITEMAPS_OFF = 'Sitemaps are off, so only pages reachable by links from the home page, '
        . 'the feed and the 404 page will be exported.';

    private string $public_origin;
    private string $public_host;
    /** @var array<string, string> What no written file may contain: label => text. */
    private array $forbidden;

    private Report $report;
    private Output $output;
    /** @var SplQueue<array{0: string, 1: string}> Addresses to fetch, each with the page that led to it. */
    private SplQueue $queue;
    /** @var array<string, true> The key() of every address queued so far. */
    private array $seen = [];
    /** @var array<string, true> The key() of every address with an outcome: saved, or named in an error or warning. */
    private array $accounted = [];
    /** @var array<int, array{0: string, 1: string, 2: string}> [address, the target it handed off to, referrer]. */
    private array $handoffs = [];
    /** @var array<string, array{0: string, 1: int}> Refused address => [first page using it, pages using it]. */
    private array $refused = [];
    /** @var array<string, array{0: string, 1: string, 2: int}> Form => [action, first page with it, pages with it]. */
    private array $forms = [];
    /** @var array<string, array{0: string, 1: int}> key() of an address the export may fetch => [first page linking to it, pages linking to it]. */
    private array $linked = [];
    /** @var array<string, string> key() => address, of each feed that was fetched and not exported (any but the main one). */
    private array $skipped_feeds = [];
    /**
     * @var array<string, string> key() of each address queued for robots.txt => the sitemap robots.txt names: the
     *      address itself, or the one whose redirect led here.
     */
    private array $robots = [];
    /** @var array<string, array{0: string, 1: string}> key() of an address in $robots that failed => [what, why]. */
    private array $robots_failed = [];
    /** Whether any address in $robots was saved. */
    private bool $robots_saved = false;
    private int $requests = 0;

    /**
     * @param string $local_host   The host WordPress really answers to (the site's local host).
     * @param string $secret       Export mode's secret. Neither may appear in a written file.
     * @param int    $max_requests The most requests one export makes.
     * @param string $accepted_post The address of the one form that works on the static site though nothing there
     *                              takes a form (a site's pigeonhole: its comment form, which can't post by itself,
     *                              method "dialog", and whose script sends what it holds), or none. That form gets
     *                              no warning; one that would post or get that address still does.
     */
    public function __construct(
        string $public_origin,
        private Fetcher $fetcher,
        string $local_host,
        string $secret,
        private int $max_requests = 20000,
        private string $accepted_post = ''
    ) {
        $this->public_origin = rtrim($public_origin, '/');
        $this->public_host = strtolower((string) parse_url($this->public_origin, PHP_URL_HOST));
        $this->forbidden = [$local_host => $local_host, 'the export secret' => $secret];
    }

    public function run(string $out_dir, Seeds $seeds): Report
    {
        $this->report = new Report();
        $this->queue = new SplQueue();
        $this->seen = $this->accounted = $this->handoffs = $this->refused = $this->forms = $this->linked = $this->skipped_feeds = [];
        $this->robots = $this->robots_failed = [];
        $this->robots_saved = false;
        $this->requests = 0;
        foreach ($seeds->warnings as $warning) {
            $this->report->warning($warning);
        }
        foreach ($seeds->errors as $error) {
            $this->report->error($error);
        }
        try {
            $this->output = new Output($out_dir);
        } catch (RuntimeException $e) {
            $this->report->error($e->getMessage());
            return $this->report;
        }

        try {
            $this->export_404_page();
        } catch (Throwable $e) {
            $this->report->error("The 404 page could not be exported: {$e->getMessage()}");
        }
        foreach ($seeds->addresses as $url) {
            if (Rules::should_fetch($url, $this->public_origin)) {
                $this->enqueue($url, self::SEED);
            } else {
                $this->report->error("WordPress gave $url as a starting address, but the export may not fetch it.");
            }
        }
        while (!$this->queue->isEmpty()) {
            if ($this->requests >= $this->max_requests) {
                $this->report->error(sprintf(
                    'Stopped at %d requests, the most one export makes, with %d addresses still to fetch.',
                    $this->max_requests,
                    count($this->queue)
                ));
                break;
            }
            [$url, $from] = $this->queue->dequeue();
            try {
                $this->export($url, $from);
            } catch (Throwable $e) {
                $this->fail($url, $url, "could not be exported: {$e->getMessage()}", $from);
            }
        }

        if ($this->queue->isEmpty()) {
            // A hand-off whose target never gave a page (a slash loop, say) would otherwise lose it silently.
            foreach ($this->handoffs as [$url, $target, $from]) {
                if (isset($this->skipped_feeds[self::key($target)])) {
                    $this->skipped_feeds[self::key($url)] = $url; // "/about/feed" to "/about/feed/": the same feed.
                } elseif (!isset($this->accounted[self::key($target)])) {
                    $this->report_failure($url, $url, "redirects to $target, which gave no page to save", $from);
                }
            }
        }
        // A stale Sitemap: line must not stop a publish, so a sitemap only robots.txt names is a warning; but a page
        // linking to it too has a broken link, which is an error, whichever of the two was read first.
        foreach ($this->robots_failed as $key => [$what, $why]) {
            if (isset($this->linked[$key])) {
                $this->report->error("$what $why (linked from {$this->linked[$key][0]}).");
                continue;
            }
            $named = $this->robots[$key];
            $it = match (true) {
                $what === $named => 'it',
                str_starts_with($what, "$named (") => 'it' . substr($what, strlen($named)), // "(redirected to ...)"
                default => $what,
            };
            $this->report->warning("robots.txt names the sitemap $named, which could not be exported: $it $why");
        }
        if ($seeds->sitemaps_off && !$this->robots_saved) {
            // First, where it always was: it says what the rest of the report is missing.
            array_unshift($this->report->warnings, self::SITEMAPS_OFF);
        }
        foreach ($this->forms as [$action, $page, $pages]) {
            $this->report->warning(sprintf(
                "a form posting to %s is on %d %s, first seen on %s; it won't work on the static site",
                $action, $pages, $pages === 1 ? 'page' : 'pages', $page
            ));
        }
        // A feed not exported is like a refused address: a page linking to it gets the same warning, and so does
        // robots.txt naming it as a sitemap.
        foreach ($this->skipped_feeds as $key => $address) {
            if (isset($this->linked[$key])) {
                $this->refused[$address] ??= $this->linked[$key];
            } elseif (isset($this->robots[$key])) {
                $this->refused[$address] ??= [self::ROBOTS, 1];
            }
        }
        foreach ($this->refused as $address => [$page, $pages]) {
            $this->report->warning("$page links to $address, which is not exported" . ($pages > 1 ? " ($pages pages in all)." : '.'));
        }
        return $this->report;
    }

    /** An address that doesn't exist: its body becomes 404.html, and its links are followed. */
    private function export_404_page(): void
    {
        $url = $this->public_origin . '/offprint-404-probe-' . bin2hex(random_bytes(8)) . '/';
        $this->seen[self::key($url)] = true;
        $response = $this->fetch($url);
        if (is_string($response)) {
            $this->report->error("The 404 page could not be fetched: $response.");
        } elseif ($response['status'] !== 404) {
            fclose($response['body']);
            $to = $response['location'] === '' ? '' : " (to {$response['location']})";
            $this->report->error("$url answered {$response['status']}$to, not 404, so there is no 404 page.");
        } else {
            $this->save('404.html', $response, $url, 'the 404 page', true);
        }
    }

    /** Fetches one address, following redirects within the site, and saves what it gets. */
    private function export(string $url, string $from): void
    {
        $current = $url;
        for ($hops = 0; ; $hops++) {
            $response = $this->fetch($current);
            if (is_string($response)) {
                $this->fail($url, $current, "could not be fetched: $response", $from);
                return;
            }
            if (!in_array($response['status'], self::REDIRECTS, true)) {
                break;
            }
            fclose($response['body']);
            $target = Links::resolve($response['location'], $current);
            if ($target === null || !Rules::should_fetch($target, $this->public_origin)) {
                $this->fail($url, $current, "redirects to {$response['location']}, which is not exported", $from);
                return;
            }
            if (self::key($target) === self::key($current) && parse_url($target, PHP_URL_QUERY) === parse_url($current, PHP_URL_QUERY)) {
                $this->fail($url, $current, 'redirects to itself', $from);
                return;
            }
            if (Paths::is_folder((string) parse_url($url, PHP_URL_PATH)) && !Paths::is_folder((string) parse_url($target, PHP_URL_PATH))) {
                // An attachment page that sends you to the image, say. The image is exported; the page can't be.
                $this->report->warning("$url redirects to the file $target; links to it will not work on the static site (first seen on $from)");
                $this->accounted[self::key($url)] = true;
                $this->enqueue_after($url, $target, $from);
                return;
            }
            if ($hops === 0 && self::key($target) !== self::key($url) && self::same_file($url, $target)) {
                // "/about" to "/about/": just another link to that page. Checked at the end.
                $this->handoffs[] = [$url, $target, $from];
                $this->enqueue_after($url, $target, $from);
                return;
            }
            if ($hops === self::MAX_REDIRECTS) {
                $this->fail($url, $url, 'redirects more than ' . self::MAX_REDIRECTS . ' times', $from);
                return;
            }
            $current = $target;
        }

        $what = $current === $url ? $url : "$url (redirected to $current)";
        if ($response['status'] !== 200) {
            fclose($response['body']);
            $this->fail($url, $what, "answered {$response['status']}", $from);
            return;
        }
        if (in_array($response['type'], self::FEED_TYPES, true) && (string) parse_url($url, PHP_URL_PATH) !== '/feed/') {
            // A tag's, a category's or a post's comments feed. Not an error; a page linking here is warned about at the end.
            fclose($response['body']);
            $this->skipped_feeds[self::key($url)] = $url;
            $this->accounted[self::key($url)] = true;
            return;
        }
        try {
            // Written where it was asked for, so the address that linked here works.
            $file = Paths::to_file((string) parse_url($url, PHP_URL_PATH), $response['type']);
        } catch (InvalidArgumentException $e) {
            fclose($response['body']);
            $this->fail($url, $what, "cannot be saved: {$e->getMessage()}", $from);
            return;
        }
        // A body from another address is that page's, and is read when that page itself is fetched. The site's own
        // robots.txt (that path exactly, whatever its type) is read for its Sitemap: lines, as what is saved there.
        $read = self::key($current) === self::key($url);
        $robots = (string) parse_url($url, PHP_URL_PATH) === '/robots.txt';
        if ($this->save($file, $response, $current, $url, $read, $robots) && isset($this->robots[self::key($url)])) {
            $this->robots_saved = true;
        }
        $this->accounted[self::key($url)] = true;
        if (!$read) {
            $this->enqueue_after($url, $current, $from);
        }
    }

    /** One request, counted. A compressed body can't be read or rewritten, so it is refused. */
    private function fetch(string $url): array|string
    {
        $this->requests++;
        $response = $this->fetcher->get($url);
        if (is_array($response) && $response['encoding'] !== '' && strtolower($response['encoding']) !== 'identity') {
            fclose($response['body']);
            return "it came back compressed (Content-Encoding: {$response['encoding']}), which the export cannot read";
        }
        return $response;
    }

    /**
     * Writes a response's body at $file and, if $read, follows what it refers to; if $robots, the sitemaps it names.
     *
     * @param array{status: int, type: string, location: string, encoding: string, body: resource} $response
     * @param string $base The address the body came from, for its relative links.
     * @param string $page The page as the report names it, and the referrer of its links.
     * @return bool Whether it was written.
     */
    private function save(string $file, array $response, string $base, string $page, bool $read, bool $robots = false): bool
    {
        $body = $response['body'];
        try {
            [$bytes, $found] = $this->output->write($file, $body, $page, $this->forbidden);
        } catch (RuntimeException $e) {
            fclose($body);
            $this->report->error("$page cannot be saved: {$e->getMessage()}");
            return false;
        }
        $this->report->files++;
        $this->report->bytes += $bytes;
        foreach ($found as $what) {
            // The backstop: export mode should have rewritten it, or the content names it as text.
            $this->report->error("$page contains $what, which must never be published.");
        }

        $type = $response['type'];
        $html = $type === 'text/html' || $type === 'application/xhtml+xml';
        $extract = match (true) {
            !$read => null,
            $html => Links::from_html(...),
            $type === 'text/css' => Links::from_css(...),
            in_array($type, self::JS_TYPES, true) => Links::from_module(...),
            // Sitemaps. Feeds (rss+xml, atom+xml) are not read: every post in them is listed already.
            $type === 'application/xml', $type === 'text/xml' => Links::from_sitemap(...),
            default => null,
        };
        if ($extract instanceof Closure) {
            rewind($body);
            $text = (string) stream_get_contents($body);
            if ($html) {
                $this->note_forms(Links::forms($text, $base), $page);
            }
            foreach ($extract($text, $base) as $link) {
                $this->consider($link, $page);
            }
        }
        if ($robots) {
            rewind($body);
            $text = (string) stream_get_contents($body, self::ROBOTS_BYTES + 1);
            if (strlen($text) > self::ROBOTS_BYTES) {
                // Nor is a line the limit cuts through read: its address would be cut short.
                $text = substr($text, 0, max((int) strrpos($text, "\n"), (int) strrpos($text, "\r")));
            }
            foreach (Links::from_robots($text, $base) as $address) {
                $this->consider_sitemap($address);
            }
        }
        fclose($body);
        return true;
    }

    /** @param array<int, array{action: string, method: string}> $forms */
    private function note_forms(array $forms, string $page): void
    {
        $here = [];
        foreach ($forms as ['action' => $action, 'method' => $method]) {
            if ($method === 'dialog' && $this->accepted_post !== '' && $action === $this->accepted_post) {
                continue;   // it works on the static site: its script sends what it holds
            }
            $here["$method $action"] = $action;
        }
        foreach ($here as $form => $action) {
            $this->forms[$form] ??= [$action, $page, 0];
            $this->forms[$form][2]++;
        }
    }

    /** Queues a link the export may fetch, and notes a same-site one it may not. */
    private function consider(string $link, string $page): void
    {
        if (Rules::should_fetch($link, $this->public_origin)) {
            $key = self::key($link);
            $this->linked[$key] ??= [$page, 0];
            $this->linked[$key][1]++;
            $this->enqueue($link, $page);
        } else {
            $this->refuse($link, $page);
        }
    }

    /**
     * A sitemap robots.txt names, judged as a page's link is: queued if the export may fetch it, which is remembered
     * when this is what queued it (one WordPress gave, or a page linked to first, is theirs); else noted if it is on
     * this site. Not counted as a page's link: robots.txt is not a page.
     */
    private function consider_sitemap(string $address): void
    {
        if (!Rules::should_fetch($address, $this->public_origin)) {
            $this->refuse($address, self::ROBOTS);
        } elseif ($this->enqueue($address, self::ROBOTS)) {
            $this->robots[self::key($address)] = $address;
        }
    }

    /** Notes a same-site address the export may not fetch. Another site's is left to the visitor's browser. */
    private function refuse(string $link, string $page): void
    {
        if (strtolower((string) parse_url($link, PHP_URL_HOST)) === $this->public_host) {
            $this->refused[$link] ??= [$page, 0];
            $this->refused[$link][1]++;
        }
    }

    /** Whether it was queued now: false when it had been already. */
    private function enqueue(string $url, string $from): bool
    {
        $key = self::key($url);
        if (isset($this->seen[$key])) {
            return false;
        }
        $this->seen[$key] = true;
        $this->queue->enqueue([$url, $from]);
        return true;
    }

    /** Queues where $url led ($target), which, if it queues it, stands for the sitemap robots.txt named as $url did. */
    private function enqueue_after(string $url, string $target, string $from): void
    {
        if ($this->enqueue($target, $from) && isset($this->robots[self::key($url)])) {
            $this->robots[self::key($target)] = $this->robots[self::key($url)];
        }
    }

    /** $url has an outcome, a failure: see report_failure(). */
    private function fail(string $url, string $what, string $why, string $from): void
    {
        $this->accounted[self::key($url)] = true;
        $this->report_failure($url, $what, $why, $from);
    }

    /**
     * "$what $why (linked from $from)." as an error; for a sitemap robots.txt named, kept for the end of run(), which
     * decides. $what is the address the report names: $url, or where its redirects led.
     */
    private function report_failure(string $url, string $what, string $why, string $from): void
    {
        $key = self::key($url);
        if (isset($this->robots[$key])) {
            $this->robots_failed[$key] = [$what, $why];
        } else {
            $this->report->error("$what $why (linked from $from).");
        }
    }

    /** Addresses with the same key are fetched once: the query string (?ver=) doesn't count. */
    private static function key(string $url): string
    {
        $p = parse_url($url);
        return strtolower($p['host'] ?? '') . rawurldecode($p['path'] ?? '/');
    }

    /** Whether two addresses are saved as the same file, as with and without a trailing slash. */
    private static function same_file(string $a, string $b): bool
    {
        try {
            return Paths::to_file((string) parse_url($a, PHP_URL_PATH), 'text/html')
                === Paths::to_file((string) parse_url($b, PHP_URL_PATH), 'text/html');
        } catch (InvalidArgumentException) {
            return false;
        }
    }
}
