<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Offprint\Status_View;

final class StatusViewTest extends TestCase
{
    private const NOW = 1_800_000_000;
    private const AT = '2027-01-15T08:00:00Z'; // NOW

    /** The status file as bin/publish writes it, with some fields replaced. */
    private static function written(array $fields): string
    {
        return (string) json_encode($fields + [
            'state' => 'live',
            'running' => false,
            'at' => gmdate('Y-m-d\TH:i:s\Z', self::NOW - 60),
            'commit' => str_repeat('a1b2c3d4e5', 4),
            'message' => 'The site is live at a1b2c3d',
            'warnings' => [],
        ]);
    }

    /** Builds a view; times are shown as "@<unix time>" so a test can see which time was used. */
    private static function view(
        ?string $raw,
        ?int $status_time = null,
        ?int $request_time = null,
        string $problem = '',
        ?int $missed_at = null,
        string $missed = ''
    ): Status_View {
        return Status_View::build(
            raw: $raw,
            status_time: $raw === null ? null : ($status_time ?? self::NOW - 60),
            request_time: $request_time,
            now: self::NOW,
            format_time: static fn (int $time): string => "@$time",
            problem: $problem,
            missed_at: $missed_at,
            missed: $missed,
        );
    }

    public function test_no_status_and_no_request(): void
    {
        $view = self::view(null);
        $this->assertSame('Not published yet', $view->title);
        $this->assertSame('idle', $view->tone);
        $this->assertSame([], $view->lines);
        $this->assertFalse($view->poll());
    }

    public static function running_states(): array
    {
        return [['exporting'], ['checking'], ['pushing'], ['deploying']];
    }

    #[DataProvider('running_states')]
    public function test_running_is_publishing_with_the_state_as_detail(string $state): void
    {
        $view = self::view(self::written(['state' => $state, 'running' => true, 'message' => 'Working on it']));
        $this->assertSame("Publishing\u{2026} ($state)", $view->title);
        $this->assertSame('busy', $view->tone);
        $this->assertSame($state, $view->state);
        $this->assertTrue($view->running);
        $this->assertTrue($view->poll());
        $this->assertFalse($view->stuck);
        $this->assertSame(['Working on it'], $view->lines);
    }

    public function test_running_decides_not_the_state_name(): void
    {
        // A dry run ends in "checking" with running false: that is a result, not progress.
        $view = self::view(self::written([
            'state' => 'checking',
            'running' => false,
            'message' => 'Dry run: the export is in var/export and passed the checks.',
        ]));
        $this->assertSame('Dry run: the export is in var/export and passed the checks.', $view->title);
        $this->assertSame('idle', $view->tone);
        $this->assertFalse($view->poll());
        $this->assertSame([], $view->lines);

        $view = self::view(self::written(['state' => 'checking', 'message' => 'Committed, not pushed (--no-push).']));
        $this->assertSame('Committed, not pushed (--no-push).', $view->title);
    }

    public function test_a_long_final_message_is_shortened_in_the_title_and_given_whole_below(): void
    {
        $message = str_repeat('word ', 40);
        $view = self::view(self::written(['state' => 'checking', 'message' => $message]));
        $this->assertSame(80, mb_strlen($view->title));
        $this->assertStringEndsWith("\u{2026}", $view->title);
        $this->assertSame([trim($message)], $view->lines);
    }

    public function test_live_shows_when_and_the_commit(): void
    {
        $view = self::view(self::written(['at' => self::AT, 'warnings' => ['Warning: one', 'Warning: two']]));
        $this->assertSame('Live · @' . strtotime(self::AT), $view->title);
        $this->assertSame('live', $view->tone);
        $this->assertSame(['Commit a1b2c3d', 'Warning: one', 'Warning: two'], $view->lines);
        $this->assertFalse($view->poll());
    }

    public function test_unchanged_is_live_with_no_changes(): void
    {
        $view = self::view(self::written(['state' => 'unchanged', 'at' => self::AT]));
        $this->assertSame('Live (no changes) · @' . strtotime(self::AT), $view->title);
        $this->assertSame('live', $view->tone);
        $this->assertSame(['Commit a1b2c3d'], $view->lines);
    }

    public function test_saved_is_committed_and_pushed_for_a_site_with_no_host(): void
    {
        $message = 'Committed and pushed a1b2c3d; this site has no host set up (site.json "adapter").';
        $view = self::view(self::written(['state' => 'saved', 'at' => self::AT, 'message' => $message, 'warnings' => ['Warning: one']]));
        $this->assertSame('Saved · @' . strtotime(self::AT), $view->title);
        $this->assertSame('live', $view->tone, 'the tone of a publish that has nothing new');
        $this->assertSame('saved', $view->state);
        $this->assertSame([$message, 'Warning: one'], $view->lines, 'the message, then each warning');
        $this->assertFalse($view->running);
        $this->assertFalse($view->poll(), 'it is finished');
    }

    public function test_saved_with_an_action_needed_is_not_a_clean_save(): void
    {
        $action = 'Action needed: this folder\'s git index is out of date: run `git reset -q -- site wp-content backup` before committing anything here.';
        $view = self::view(self::written(['state' => 'saved', 'at' => self::AT, 'message' => 'Committed and pushed a1b2c3d, but …', 'warnings' => ['Warning: one', $action]]));
        $this->assertSame('Saved, but action needed · @' . strtotime(self::AT), $view->title);
        $this->assertSame('failed', $view->tone);
        $this->assertSame([$action, 'Committed and pushed a1b2c3d, but …', 'Warning: one'], $view->lines, 'the action comes first');
    }

    public function test_live_with_an_action_needed_is_not_a_clean_live(): void
    {
        $action = 'Action needed: this folder\'s git index is out of date: run `git reset -q -- site wp-content backup` before committing anything here.';
        foreach (['live' => 'Live', 'unchanged' => 'Live (no changes)'] as $state => $live) {
            $view = self::view(self::written(['state' => $state, 'at' => self::AT, 'warnings' => ['Warning: one', $action]]));
            $this->assertSame("$live, but action needed · @" . strtotime(self::AT), $view->title);
            $this->assertSame('failed', $view->tone);
            $this->assertSame([$action, 'Commit a1b2c3d', 'Warning: one'], $view->lines, 'the action comes first');
        }
    }

    public function test_live_without_a_valid_time_uses_when_the_file_was_written(): void
    {
        $view = self::view(self::written(['at' => 'yesterday']), status_time: 1_700_000_000);
        $this->assertSame('Live · @1700000000', $view->title);
    }

    public function test_failed_shows_the_message_then_each_warning(): void
    {
        $view = self::view(self::written([
            'state' => 'failed',
            'commit' => '',
            'message' => 'The export failed the checks',
            'warnings' => ['Warning: a form', 'Warning: a link'],
        ]));
        $this->assertSame('Publish failed', $view->title);
        $this->assertSame('failed', $view->tone);
        $this->assertSame(['The export failed the checks', 'Warning: a form', 'Warning: a link'], $view->lines);
        $this->assertFalse($view->poll());
    }

    public function test_a_publish_that_has_said_nothing_for_more_than_15_minutes_may_be_stuck(): void
    {
        $at = static fn (int $ago): string => gmdate('Y-m-d\TH:i:s\Z', self::NOW - $ago);
        $view = self::view(self::written(['state' => 'exporting', 'running' => true, 'at' => $at(900)]));
        $this->assertSame("Publishing\u{2026} (exporting)", $view->title, 'exactly 15 minutes is not yet stuck');

        $view = self::view(self::written([
            'state' => 'exporting',
            'running' => true,
            'at' => $at(901),
            'message' => 'Exporting the site from WordPress',
        ]));
        $this->assertSame('Publish may be stuck', $view->title);
        $this->assertSame('failed', $view->tone);
        $this->assertStringContainsString('var/publish.log', $view->lines[0]);
        $this->assertStringContainsString('(offprint install-agent)', $view->lines[0]);
        $this->assertStringContainsString('@' . (self::NOW - 901), $view->lines[0]);
        $this->assertSame('Exporting the site from WordPress', $view->lines[1]);
        $this->assertTrue($view->poll(), 'it keeps checking, in case the Mac gets going');
        $this->assertTrue($view->stuck, 'but slowly');
    }

    public function test_a_running_status_without_a_valid_time_is_judged_by_the_file_time(): void
    {
        $view = self::view(self::written(['state' => 'pushing', 'running' => true, 'at' => 12]), status_time: self::NOW - 1000);
        $this->assertSame('Publish may be stuck', $view->title);
    }

    public function test_a_request_newer_than_the_status_is_waiting(): void
    {
        $view = self::view(self::written([]), status_time: self::NOW - 60, request_time: self::NOW - 5);
        $this->assertSame("Publish requested\u{2026}", $view->title);
        $this->assertSame('busy', $view->tone);
        $this->assertTrue($view->pending);
        $this->assertTrue($view->poll());
        $this->assertStringContainsString('@' . (self::NOW - 5), $view->lines[0]);

        $same = self::view(self::written([]), status_time: self::NOW - 60, request_time: self::NOW - 60);
        $this->assertSame("Publish requested\u{2026}", $same->title, 'written in the same second still counts');

        $first = self::view(null, request_time: self::NOW - 5);
        $this->assertSame("Publish requested\u{2026}", $first->title, 'the very first request');
    }

    public function test_a_request_waits_whatever_the_times_say(): void
    {
        // The Mac removes what it takes, so a request that still exists has never been served, even
        // when a publish started by hand has finished since it was written.
        $view = self::view(self::written([]), status_time: self::NOW - 60, request_time: self::NOW - 600);
        $this->assertSame("Publish requested\u{2026}", $view->title);
        $this->assertTrue($view->pending);
        $this->assertTrue($view->poll());
        $this->assertFalse($view->stuck);
    }

    public function test_no_request_is_not_waiting(): void
    {
        $view = self::view(self::written([]));
        $this->assertStringStartsWith('Live', $view->title);
        $this->assertFalse($view->pending);
        $this->assertFalse($view->poll());
    }

    public function test_a_request_nobody_takes_for_more_than_15_minutes_may_be_stuck(): void
    {
        $view = self::view(null, request_time: self::NOW - 901);
        $this->assertSame('Publish may be stuck', $view->title);
        $this->assertTrue($view->stuck);
        $this->assertStringContainsString('var/publish.log', $view->lines[0]);
        $this->assertStringContainsString('(offprint install-agent)', $view->lines[0]);
        $this->assertTrue($view->poll());
    }

    public function test_running_wins_over_a_waiting_request(): void
    {
        $view = self::view(
            self::written(['state' => 'deploying', 'running' => true, 'at' => gmdate('Y-m-d\TH:i:s\Z', self::NOW - 10)]),
            status_time: self::NOW - 10,
            request_time: self::NOW - 2
        );
        $this->assertSame("Publishing\u{2026} (deploying)", $view->title);
        $this->assertTrue($view->poll());
    }

    public function test_a_problem_asking_comes_first(): void
    {
        $view = self::view(self::written(['state' => 'failed', 'message' => 'Old failure']), problem: 'The folder is missing.');
        $this->assertSame("Can't ask for a publish", $view->title);
        $this->assertSame('failed', $view->tone);
        $this->assertSame(['The folder is missing.', 'Old failure'], $view->lines);
    }

    public function test_a_request_that_did_not_reach_the_mac(): void
    {
        $view = self::view(
            self::written(['at' => gmdate('Y-m-d\TH:i:s\Z', self::NOW - 600)]),
            missed_at: self::NOW - 60,
            missed: 'The disk is full.'
        );
        $this->assertSame("Last request didn't reach the Mac", $view->title);
        $this->assertSame('failed', $view->tone);
        $this->assertStringContainsString('@' . (self::NOW - 60), $view->lines[0]);
        $this->assertStringContainsString('The disk is full.', $view->lines[0]);
        $this->assertStringContainsString('Publish Site', $view->lines[0]);
        $this->assertSame('Commit a1b2c3d', $view->lines[1], 'the status follows');
    }

    public function test_a_publish_since_then_covers_a_missed_request(): void
    {
        // Every publish exports the whole site, so one that started later has the change too.
        $view = self::view(
            self::written(['at' => gmdate('Y-m-d\TH:i:s\Z', self::NOW - 10)]),
            missed_at: self::NOW - 60,
            missed: 'The disk is full.'
        );
        $this->assertStringStartsWith('Live', $view->title);
        $this->assertSame(['Commit a1b2c3d'], $view->lines);
    }

    public function test_what_now_comes_before_a_missed_request(): void
    {
        $cant = self::view(null, problem: 'The inbox is missing.', missed_at: self::NOW - 60, missed: 'Earlier.');
        $this->assertSame("Can't ask for a publish", $cant->title);
        $this->assertSame(['The inbox is missing.'], $cant->lines);

        $asked = self::view(null, request_time: self::NOW - 5, missed_at: self::NOW - 60, missed: 'Earlier.');
        $this->assertSame("Publish requested\u{2026}", $asked->title);
    }

    public static function unreadable(): array
    {
        return [
            'empty' => [''],
            'not JSON' => ['not json'],
            'cut off' => ['{"state":"live","running":'],
            'a list' => ['["live"]'],
            'a string' => ['"live"'],
            'an empty object' => ['{}'],
            'too deep' => [str_repeat('[', 100) . str_repeat(']', 100)],
            'too big' => ['{"message":"' . str_repeat('x', Status_View::MAX_BYTES) . '"}'],
        ];
    }

    #[DataProvider('unreadable')]
    public function test_an_unreadable_status_says_so(string $raw): void
    {
        $this->assertNull(Status_View::parse($raw));
        $view = self::view($raw);
        $this->assertSame('Publish status unknown', $view->title);
        $this->assertSame('failed', $view->tone);
        $this->assertStringContainsString('var/status.json', $view->lines[0]);
        $this->assertFalse($view->poll());
    }

    public function test_every_field_is_type_checked(): void
    {
        $parsed = Status_View::parse((string) json_encode([
            'state' => ['live'],
            'running' => 'true',
            'at' => 1_800_000_000,
            'commit' => '<b>bold</b>',
            'message' => ['a' => 1],
            'warnings' => 'not a list',
        ]));
        $this->assertSame(
            ['state' => '', 'running' => false, 'at' => null, 'commit' => '', 'message' => '', 'warnings' => []],
            $parsed
        );

        $view = self::view((string) json_encode(['state' => 'mystery', 'running' => true]));
        $this->assertSame("Publishing\u{2026}", $view->title, 'an unknown state is not shown');
        $this->assertSame('', $view->state);

        $view = self::view((string) json_encode(['state' => 'live', 'warnings' => ['ok', 3, null, ['x'], 'also ok']]));
        $this->assertSame(['ok', 'also ok'], $view->lines, 'warnings that are not strings are dropped');
    }

    public function test_times_and_commits_must_be_exact(): void
    {
        foreach (['2027-02-30T00:00:00Z', '2027-01-15T24:00:00Z', '2027-01-15 08:00:00Z', '2027-01-15T08:00:00+00:00'] as $bad) {
            $this->assertNull(Status_View::parse(self::written(['at' => $bad]))['at'], $bad);
        }
        $this->assertSame(strtotime(self::AT), Status_View::parse(self::written(['at' => self::AT]))['at']);
        foreach (['abc12', 'A1B2C3D', str_repeat('a', 41), "a1b2c3d\n"] as $bad) {
            $this->assertSame('', Status_View::parse(self::written(['commit' => $bad]))['commit'], $bad);
        }
    }

    public function test_strings_are_capped_and_kept_to_one_line(): void
    {
        $parsed = Status_View::parse(self::written([
            'message' => str_repeat('m', 600),
            'warnings' => ["line one\nError: forged\r\x1b[31m\x7f end", "right\u{202E}to left"],
        ]));
        $this->assertSame(500, mb_strlen($parsed['message']));
        $this->assertSame(['line oneError: forged[31m end', 'rightto left'], $parsed['warnings']);
    }

    public function test_warnings_shown_are_cut_to_200_characters(): void
    {
        $view = self::view(self::written(['warnings' => [str_repeat('w', 300)]]));
        $this->assertSame(200, mb_strlen($view->lines[1]));
        $this->assertSame(str_repeat('w', 199) . "\u{2026}", $view->lines[1]);
    }

    public function test_at_most_50_warnings_and_a_count_of_the_rest(): void
    {
        $sixty = array_map(static fn (int $i): string => "w$i", range(1, 60));
        $parsed = Status_View::parse(self::written(['warnings' => $sixty]));
        $this->assertCount(51, $parsed['warnings']);
        $this->assertSame('w50', $parsed['warnings'][49]);
        $this->assertSame('and 10 more', $parsed['warnings'][50]);

        // bin/publish already writes 50 and its own count: that count is kept.
        $written = array_merge(array_slice($sixty, 0, 50), ['and 10 more']);
        $this->assertSame($written, Status_View::parse(self::written(['warnings' => $written]))['warnings']);

        // Anything past that is counted again.
        $more = array_merge(array_slice($sixty, 0, 51), ['and 10 more']);
        $this->assertSame('and 2 more', Status_View::parse(self::written(['warnings' => $more]))['warnings'][50]);
    }

    public function test_bad_utf8_does_not_make_it_unreadable(): void
    {
        $parsed = Status_View::parse('{"state":"failed","message":"caf' . "\xE9" . '"}');
        $this->assertNotNull($parsed);
        $this->assertSame("caf\u{FFFD}", $parsed['message']);
    }

    public function test_html_is_left_as_text_for_whoever_prints_it_to_escape(): void
    {
        $view = self::view(self::written(['state' => 'failed', 'message' => '<script>alert(1)</script>']));
        $this->assertSame(['<script>alert(1)</script>'], $view->lines);
    }

    public function test_to_array_is_what_the_admin_bar_script_reads(): void
    {
        $view = self::view(self::written(['state' => 'checking', 'running' => true, 'message' => 'Checking the export']));
        $this->assertSame([
            'title' => "Publishing\u{2026} (checking)",
            'tone' => 'busy',
            'state' => 'checking',
            'running' => true,
            'pending' => false,
            'stuck' => false,
            'poll' => true,
            'lines' => ['Checking the export'],
        ], $view->to_array());
    }
}
