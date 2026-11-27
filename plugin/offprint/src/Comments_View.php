<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * What the admin bar says about comments, for a site that takes them: how many the Mac has fetched and not yet
 * opened, when it last fetched and whether that worked, and how the last collection went.
 *
 * Made from two small files the Mac writes in var/ (bin/collect: var/pigeonhole-fetch.json after a fetch,
 * var/pigeonhole.json after a collection) and the time of a waiting "check for comments" request. Those files hold
 * counts, times and one fixed word, never anything a visitor wrote, and every field is checked here all the same:
 * a number must be a number in range, the word one of those this class knows. The view is plain text: whoever prints
 * it escapes it.
 *
 * Pure (no WordPress, no files, no clock), so PHPUnit covers it; Admin_Bar gathers the inputs.
 */
final class Comments_View
{
    /** A request nobody took for longer than this may be stuck. */
    public const STUCK_AFTER = 15 * 60;
    /** A bigger file is not one bin/collect wrote. */
    public const MAX_BYTES = 4096;
    private const MAX_COUNT = 1000000;
    private const CHECK_AGENT = 'Check var/publish.log, and that the Mac\'s agent is installed (offprint install-agent).';
    /** Why a fetch failed: bin/collect's one word for it, and this class's words. Any other word gets the last line. */
    private const REASONS = [
        'unreachable' => 'the pigeonhole\'s server couldn\'t be reached',
        'locked' => 'the Mac\'s login Keychain was locked',
        'no-key' => 'the Mac has no pull key for this site',
        'bad-key' => 'the Mac\'s pull key for this site couldn\'t be used',
        'keychain' => 'the Mac\'s login Keychain couldn\'t be read',
        'jump-host-key' => 'the web server showed an ssh host key that isn\'t the one in site.json',
        'store-host-key' => 'the pigeonhole\'s server showed an ssh host key that isn\'t the one in site.json',
        'jump-refused' => 'the web server refused the Mac\'s key',
        'store-refused' => 'the pigeonhole\'s server refused the Mac\'s key',
        'jump-forward' => 'the web server wouldn\'t pass the Mac on to the pigeonhole\'s server',
        'not-a-list' => 'the pigeonhole\'s server didn\'t answer as it should',
        'store-answer' => 'the pigeonhole\'s server didn\'t answer as it should',
        'slow' => 'the pigeonhole\'s server took too long to answer',
        '' => 'some submissions couldn\'t be fetched, or weren\'t what their names say',
    ];

    /**
     * @param int      $count   How many are fetched and not yet opened.
     * @param bool     $pending A "check for comments" request is waiting.
     * @param bool     $stuck   It has waited too long.
     * @param string[] $lines   The lines under the node.
     */
    private function __construct(
        public readonly int $count,
        public readonly bool $pending,
        public readonly bool $stuck,
        public readonly array $lines,
    ) {
    }

    /**
     * @param string|null           $fetch        var/pigeonhole-fetch.json's contents, or null if there is none.
     * @param string|null           $collection   var/pigeonhole.json's contents, or null if there is none.
     * @param int|null              $request_time When a waiting request was last written or touched, or null.
     * @param int                   $now          The time now.
     * @param callable(int): string $format_time  A Unix time as the site shows times.
     */
    public static function build(?string $fetch, ?string $collection, ?int $request_time, int $now, callable $format_time): self
    {
        $f = $fetch === null ? null : self::numbers($fetch, ['fetched_at', 'fetched', 'damaged', 'left', 'waiting'], $now);
        $c = $collection === null ? null : self::numbers($collection, ['collected_at', 'imported', 'spam', 'already', 'canaries', 'rejected', 'damaged', 'failed', 'waiting'], $now);
        $ok = $f !== null && self::flag($fetch) === true;
        $reason = $f !== null ? self::reason((string) $fetch) : null;

        // How many wait: what the newer of the two files counted in the spool.
        $count = 0;
        if ($f !== null && ($c === null || $f['fetched_at'] >= $c['collected_at'])) {
            $count = $f['waiting'];
        } elseif ($c !== null) {
            $count = $c['waiting'];
        }

        $lines = [];
        $pending = $request_time !== null;
        $stuck = $pending && $now - $request_time > self::STUCK_AFTER;
        if ($stuck) {
            $lines[] = 'Comments: asked to check at ' . $format_time($request_time) . ', but the Mac hasn\'t started. ' . self::CHECK_AGENT;
        } elseif ($pending) {
            $lines[] = "Comments: checking\u{2026}";
        }
        $lines[] = $count === 0
            ? 'Comments: none waiting to be checked.'
            : 'Comments: ' . self::plural($count, 'has', 'have') . ' arrived on the Mac and ' . ($count === 1 ? 'waits' : 'wait') . ' to be checked.';
        if ($fetch !== null && $f === null) {
            $lines[] = 'The Mac\'s note of its last fetch (var/pigeonhole-fetch.json) couldn\'t be read; the next fetch writes it again.';
        } elseif ($f === null) {
            $lines[] = 'Nothing has been fetched yet. The Mac\'s agent fetches every five minutes (offprint install-agent).';
        } elseif ($ok) {
            $lines[] = 'Last fetched at ' . $format_time($f['fetched_at']) . '.';
        } else {
            $why = self::REASONS[$reason ?? ''] ?? 'something went wrong on the Mac';
            $lines[] = 'The last fetch, at ' . $format_time($f['fetched_at']) . ", failed: $why. On the Mac: offprint pigeonhole doctor.";
        }
        if ($c !== null) {
            $parts = [];
            foreach ([
                'imported' => ['is in the moderation queue', 'are in the moderation queue'],
                'spam' => ['went to spam', 'went to spam'],
                'already' => ['was here already', 'were here already'],
                'rejected' => ['was refused and is kept on the Mac', 'were refused and are kept on the Mac'],
            ] as $key => [$one, $many]) {
                if ($c[$key] > 0) {
                    $parts[] = self::plural($c[$key], $one, $many);
                }
            }
            $left = $c['damaged'] + $c['failed'];
            if ($left > 0) {
                $parts[] = self::plural($left, 'couldn\'t be taken (offprint collect, on the Mac, says why)', 'couldn\'t be taken (offprint collect, on the Mac, says why)');
            }
            $lines[] = 'Last checked at ' . $format_time($c['collected_at']) . ': ' . ($parts === [] ? 'nothing new' : implode('; ', $parts)) . '.';
        }
        return new self($count, $pending, $stuck, $lines);
    }

    /** @return array{count: int, pending: bool, stuck: bool, lines: string[]} */
    public function to_array(): array
    {
        return ['count' => $this->count, 'pending' => $this->pending, 'stuck' => $this->stuck, 'lines' => $this->lines];
    }

    /**
     * The named whole numbers of a small JSON object, each from 0 to a million (a time: from 1, and not after
     * tomorrow); null when the text is not such an object or lacks one of them.
     *
     * @param string[] $names
     * @return array<string, int>|null
     */
    private static function numbers(string $raw, array $names, int $now): ?array
    {
        $json = self::decode($raw);
        if ($json === null) {
            return null;
        }
        $out = [];
        foreach ($names as $name) {
            $v = $json[$name] ?? null;
            $time = str_ends_with($name, '_at');
            if (!is_int($v) || $v < ($time ? 1 : 0) || $v > ($time ? $now + 86400 : self::MAX_COUNT)) {
                return null;
            }
            $out[$name] = $v;
        }
        return $out;
    }

    private static function flag(?string $raw): ?bool
    {
        $json = $raw === null ? null : self::decode($raw);
        return is_bool($json['ok'] ?? null) ? $json['ok'] : null;
    }

    /** The fetch's one word, when it is one this class knows; else a word that is in no list. */
    private static function reason(string $raw): string
    {
        $json = self::decode($raw);
        $word = $json['reason'] ?? null;
        return is_string($word) && array_key_exists($word, self::REASONS) ? $word : 'unknown';
    }

    /** @return array<string, mixed>|null */
    private static function decode(string $raw): ?array
    {
        if (strlen($raw) > self::MAX_BYTES) {
            return null;
        }
        try {
            $json = json_decode($raw, true, 3, JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            return null;
        }
        return is_array($json) && $json !== [] && !array_is_list($json) ? $json : null;
    }

    private static function plural(int $n, string $one, string $many): string
    {
        return $n === 1 ? "1 $one" : "$n $many";
    }
}
