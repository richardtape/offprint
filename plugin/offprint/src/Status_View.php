<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/**
 * What the admin bar says about publishing: a title, a colour for its dot, and the lines under it.
 *
 * Made from var/status.json (written by bin/publish on the Mac), its time, and the time of a waiting
 * request: one in the inbox (written by Request), or var/publish-waiting (one the Mac has taken but
 * not yet run). That file comes from outside WordPress, so every field is checked here before
 * anything is shown. The view is plain text: whoever prints it escapes it.
 *
 * Pure (no WordPress, no files, no clock), so PHPUnit covers it; Admin_Bar gathers the inputs.
 */
final class Status_View
{
    /** A publish that has said nothing for longer than this, or a request nobody took, may be stuck. */
    public const STUCK_AFTER = 15 * 60;
    /** A bigger status file is not one bin/publish wrote. */
    public const MAX_BYTES = 1024 * 1024;

    private const STATES = ['exporting', 'checking', 'pushing', 'deploying', 'live', 'unchanged', 'saved', 'failed'];
    private const MAX_TEXT = 500;
    private const MAX_WARNINGS = 50;
    private const MAX_LINE = 200;
    private const MAX_TITLE = 80;
    private const CHECK_AGENT = 'Check var/publish.log, and that the Mac\'s agent is installed (offprint install-agent).';
    /** A warning bin/publish starts with this needs doing by hand, even though the site is live. */
    private const ACTION = 'Action needed: ';

    /**
     * @param string   $title   What the node says.
     * @param string   $tone    The dot: live, busy, failed or idle.
     * @param string   $state   The status file's state, or '' if it has none we know.
     * @param bool     $running bin/publish says it is working.
     * @param bool     $pending A request is waiting that no publish has served yet.
     * @param bool     $stuck   Running or waiting, but nothing has moved for too long.
     * @param string[] $lines   The lines under the node.
     */
    private function __construct(
        public readonly string $title,
        public readonly string $tone,
        public readonly string $state,
        public readonly bool $running,
        public readonly bool $pending,
        public readonly bool $stuck,
        public readonly array $lines,
    ) {
    }

    /**
     * @param string|null           $raw          The status file's contents, or null if there is none.
     * @param int|null              $status_time  When the status file was last written (its mtime).
     * @param int|null              $request_time When a waiting request was last written or touched (the newest,
     *                                            if there are two), or null if none is waiting. The Mac removes
     *                                            what it takes, so one that exists has never been served.
     * @param int                   $now          The time now.
     * @param callable(int): string $format_time  A Unix time as the site shows times.
     * @param string                $problem      Why WordPress can't ask for a publish now, or ''.
     * @param int|null              $missed_at    When asking last failed, if it did and nothing has worked since,
     * @param string                $missed       and why.
     */
    public static function build(
        ?string $raw,
        ?int $status_time,
        ?int $request_time,
        int $now,
        callable $format_time,
        string $problem = '',
        ?int $missed_at = null,
        string $missed = '',
    ): self {
        $status = $raw === null ? null : self::parse($raw);
        $at = $status['at'] ?? $status_time;
        $running = $status !== null && $status['running'];
        $state = $status['state'] ?? '';
        $pending = $request_time !== null;
        $stuck = false;
        $warnings = array_map(static fn (string $w): string => self::shorten($w, self::MAX_LINE), $status['warnings'] ?? []);
        $message = $status['message'] ?? '';
        $lines = [];

        if ($running && $at !== null && $now - $at > self::STUCK_AFTER) {
            $title = 'Publish may be stuck';
            $tone = 'failed';
            $stuck = true;
            $lines = array_merge(['No progress since ' . $format_time($at) . '. ' . self::CHECK_AGENT], self::some([$message]), $warnings);
        } elseif ($running) {
            $title = "Publishing\u{2026}" . ($state !== '' ? " ($state)" : '');
            $tone = 'busy';
            $lines = array_merge(self::some([$message]), $warnings);
        } elseif ($pending && $now - $request_time > self::STUCK_AFTER) {
            $title = 'Publish may be stuck';
            $tone = 'failed';
            $stuck = true;
            $lines = ['Asked at ' . $format_time($request_time) . ', but the Mac hasn\'t started it. ' . self::CHECK_AGENT];
        } elseif ($pending) {
            $title = "Publish requested\u{2026}";
            $tone = 'busy';
            $lines = ['Asked at ' . $format_time($request_time) . '; waiting for the Mac to start it.'];
        } elseif ($raw !== null && $status === null) {
            $title = 'Publish status unknown';
            $tone = 'failed';
            $lines = ['var/status.json couldn\'t be read; the next publish will write it again.'];
        } elseif ($status === null) {
            $title = 'Not published yet';
            $tone = 'idle';
        } elseif ($state === 'live' || $state === 'unchanged' || $state === 'saved') {
            // An "Action needed: " warning (git's index left out of date, say) makes it red, and comes first.
            // "saved": committed and pushed, for a site with no host (site.json names no adapter); its message says so.
            $actions = array_values(array_filter($warnings, static fn (string $w): bool => str_starts_with($w, self::ACTION)));
            $others = array_values(array_filter($warnings, static fn (string $w): bool => !str_starts_with($w, self::ACTION)));
            $title = ['live' => 'Live', 'unchanged' => 'Live (no changes)', 'saved' => 'Saved'][$state]
                . ($actions !== [] ? ', but action needed' : '') . ($at !== null ? ' · ' . $format_time($at) : '');
            $tone = $actions !== [] ? 'failed' : 'live';
            $commit = $status['commit'] !== '' ? 'Commit ' . substr($status['commit'], 0, 7) : '';
            $lines = array_merge($actions, self::some([$state === 'saved' ? $message : $commit]), $others);
        } elseif ($state === 'failed') {
            $title = 'Publish failed';
            $tone = 'failed';
            $lines = array_merge(self::some([$message]), $warnings);
        } else {
            // A run that ended short of live on purpose: a dry run, or --no-push.
            $title = $message !== '' ? self::shorten($message, self::MAX_TITLE) : 'Publish status unknown';
            $tone = 'idle';
            $lines = array_merge($title !== $message ? self::some([$message]) : [], $warnings);
        }

        if ($problem !== '') {
            $title = "Can't ask for a publish";
            $tone = 'failed';
            array_unshift($lines, self::text($problem));
        } elseif ($missed_at !== null && !$pending && ($at === null || $at < $missed_at)) {
            // Asking failed, and no publish has started since (each one exports the whole site, so a
            // later one has the change in it too).
            $title = "Last request didn't reach the Mac";
            $tone = 'failed';
            array_unshift($lines, self::text('Asking at ' . $format_time($missed_at) . " didn't work: $missed Use Publish Site to ask again."));
        }
        return new self($title, $tone, $state, $running, $pending, $stuck, $lines);
    }

    /**
     * The status file's fields, each checked; null if it is not a status file at all.
     *
     * @return array{state: string, running: bool, at: ?int, commit: string, message: string, warnings: string[]}|null
     */
    public static function parse(string $raw): ?array
    {
        if (strlen($raw) > self::MAX_BYTES) {
            return null;
        }
        try {
            // It is two levels deep; anything much deeper is not ours.
            $json = json_decode($raw, true, 8, JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE);
        } catch (\JsonException) {
            return null;
        }
        if (!is_array($json) || $json === [] || array_is_list($json)) {
            return null;
        }
        $state = $json['state'] ?? null;
        $commit = $json['commit'] ?? null;
        return [
            'state' => is_string($state) && in_array($state, self::STATES, true) ? $state : '',
            'running' => ($json['running'] ?? null) === true,
            'at' => self::utc_time($json['at'] ?? null),
            'commit' => is_string($commit) && preg_match('/^[0-9a-f]{7,40}$/D', $commit) ? $commit : '',
            'message' => self::text($json['message'] ?? null),
            'warnings' => self::warnings($json['warnings'] ?? null),
        ];
    }

    public function poll(): bool
    {
        return $this->running || $this->pending;
    }

    /** @return array{title: string, tone: string, state: string, running: bool, pending: bool, stuck: bool, poll: bool, lines: string[]} */
    public function to_array(): array
    {
        return [
            'title' => $this->title,
            'tone' => $this->tone,
            'state' => $this->state,
            'running' => $this->running,
            'pending' => $this->pending,
            'stuck' => $this->stuck,
            'poll' => $this->poll(),
            'lines' => $this->lines,
        ];
    }

    /** "2027-01-15T08:00:00Z" as a Unix time; null for anything else. */
    private static function utc_time(mixed $value): ?int
    {
        if (!is_string($value) || !preg_match('/^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/D', $value, $m)) {
            return null;
        }
        [, $year, $month, $day, $hour, $minute, $second] = array_map('intval', $m);
        if (!checkdate($month, $day, $year) || $hour > 23 || $minute > 59 || $second > 59) {
            return null;
        }
        return gmmktime($hour, $minute, $second, $month, $day, $year);
    }

    /**
     * At most 50 warnings. bin/publish writes 50 and then "and N more"; that line is kept, and
     * anything past it is counted again.
     *
     * @return string[]
     */
    private static function warnings(mixed $value): array
    {
        if (!is_array($value) || !array_is_list($value)) {
            return [];
        }
        $kept = [];
        foreach (array_slice($value, 0, self::MAX_WARNINGS) as $warning) {
            $text = self::text($warning);
            if ($text !== '') {
                $kept[] = $text;
            }
        }
        $rest = array_slice($value, self::MAX_WARNINGS);
        if (count($rest) === 1 && is_string($rest[0]) && preg_match('/^and \d+ more$/D', $rest[0])) {
            $kept[] = $rest[0];
        } elseif ($rest !== []) {
            $kept[] = 'and ' . count($rest) . ' more';
        }
        return $kept;
    }

    /** A string field as one line of at most 500 characters; '' for anything that isn't a string. */
    private static function text(mixed $value): string
    {
        if (!is_string($value)) {
            return '';
        }
        // Control characters could start a line of their own; direction overrides could reorder one.
        $value = (string) preg_replace('/[\x00-\x1F\x7F\x{202A}-\x{202E}\x{2066}-\x{2069}]/u', '', $value);
        return mb_substr(trim($value), 0, self::MAX_TEXT);
    }

    private static function shorten(string $text, int $max): string
    {
        return mb_strlen($text) > $max ? mb_substr($text, 0, $max - 1) . "\u{2026}" : $text;
    }

    /**
     * @param string[] $lines
     * @return string[] The ones that aren't empty.
     */
    private static function some(array $lines): array
    {
        return array_values(array_filter($lines, static fn (string $line): bool => $line !== ''));
    }
}
