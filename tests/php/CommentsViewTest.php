<?php
declare(strict_types=1);

use Offprint\Comments_View;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

require_once __DIR__ . '/../../plugin/offprint/src/Comments_View.php';

/**
 * What the admin bar says about comments (plugin/offprint/src/Comments_View.php), from the two small files the Mac
 * writes after a fetch and after a collection. Both come from outside WordPress, so each field is checked.
 */
final class CommentsViewTest extends TestCase
{
    private const NOW = 1795000000;

    private static function fetch(array $over = []): string
    {
        return json_encode($over + ['fetched_at' => self::NOW - 120, 'ok' => true, 'fetched' => 2, 'damaged' => 0, 'left' => 0, 'waiting' => 3, 'reason' => '']);
    }

    private static function collection(array $over = []): string
    {
        return json_encode($over + ['collected_at' => self::NOW - 3600, 'imported' => 2, 'spam' => 1, 'already' => 0, 'canaries' => 0, 'rejected' => 0, 'damaged' => 0, 'failed' => 0, 'waiting' => 0]);
    }

    private static function view(?string $fetch, ?string $collection, ?int $asked = null): Comments_View
    {
        return Comments_View::build($fetch, $collection, $asked, self::NOW, static fn (int $t): string => 'T' . ($t - self::NOW));
    }

    public function test_a_site_that_has_fetched_nothing_yet(): void
    {
        $v = self::view(null, null);
        $this->assertSame(0, $v->count);
        $this->assertFalse($v->pending);
        $this->assertSame([
            'Comments: none waiting to be checked.',
            'Nothing has been fetched yet. The Mac\'s agent fetches every five minutes (offprint install-agent).',
        ], $v->lines);
    }

    public function test_some_are_fetched_and_wait(): void
    {
        $v = self::view(self::fetch(), self::collection());
        $this->assertSame(3, $v->count);
        $this->assertSame([
            'Comments: 3 have arrived on the Mac and wait to be checked.',
            'Last fetched at T-120.',
            'Last checked at T-3600: 2 are in the moderation queue; 1 went to spam.',
        ], $v->lines);
        $this->assertSame(['count' => 3, 'pending' => false, 'stuck' => false, 'lines' => $v->lines], $v->to_array());
    }

    public function test_one_waits(): void
    {
        $this->assertSame('Comments: 1 has arrived on the Mac and waits to be checked.', self::view(self::fetch(['waiting' => 1]), null)->lines[0]);
    }

    public function test_the_count_is_the_newer_files(): void
    {
        // a collection after the fetch emptied the spool
        $v = self::view(self::fetch(['fetched_at' => self::NOW - 600, 'waiting' => 3]), self::collection(['collected_at' => self::NOW - 60, 'waiting' => 0]));
        $this->assertSame(0, $v->count);
        // one that left two behind
        $v = self::view(self::fetch(['fetched_at' => self::NOW - 600, 'waiting' => 3]), self::collection(['collected_at' => self::NOW - 60, 'waiting' => 2, 'failed' => 2]));
        $this->assertSame(2, $v->count);
        $this->assertStringContainsString('2 couldn\'t be taken (offprint collect, on the Mac, says why)', $v->lines[2]);
        // a collection, and no fetch at all (a site whose spool is filled some other way)
        $this->assertSame(4, self::view(null, self::collection(['waiting' => 4]))->count);
    }

    public function test_a_collection_that_brought_nothing_new(): void
    {
        $v = self::view(self::fetch(['waiting' => 0]), self::collection(['imported' => 0, 'spam' => 0, 'canaries' => 2]));
        $this->assertSame('Last checked at T-3600: nothing new.', $v->lines[2]);
    }

    public function test_every_count_of_a_collection_is_said(): void
    {
        $v = self::view(null, self::collection(['imported' => 1, 'spam' => 2, 'already' => 3, 'rejected' => 1, 'damaged' => 1, 'failed' => 0]));
        $this->assertSame('Last checked at T-3600: 1 is in the moderation queue; 2 went to spam; 3 were here already; 1 was refused and is kept on the Mac; 1 couldn\'t be taken (offprint collect, on the Mac, says why).', $v->lines[2]);
    }

    public static function failures(): array
    {
        return [
            ['unreachable', 'the pigeonhole\'s server couldn\'t be reached'],
            ['locked', 'the Mac\'s login Keychain was locked'],
            ['no-key', 'the Mac has no pull key for this site'],
            ['bad-key', 'the Mac\'s pull key for this site couldn\'t be used'],
            ['jump-host-key', 'the web server showed an ssh host key that isn\'t the one in site.json'],
            ['store-host-key', 'the pigeonhole\'s server showed an ssh host key that isn\'t the one in site.json'],
            ['jump-refused', 'the web server refused the Mac\'s key'],
            ['store-refused', 'the pigeonhole\'s server refused the Mac\'s key'],
            ['jump-forward', 'the web server wouldn\'t pass the Mac on to the pigeonhole\'s server'],
            ['not-a-list', 'the pigeonhole\'s server didn\'t answer as it should'],
            ['store-answer', 'the pigeonhole\'s server didn\'t answer as it should'],
            ['slow', 'the pigeonhole\'s server took too long to answer'],
            ['', 'some submissions couldn\'t be fetched, or weren\'t what their names say'],
            ['setup', 'something went wrong on the Mac'],
            ['a-word-nobody-knows', 'something went wrong on the Mac'],
            ['<script>alert(1)</script>', 'something went wrong on the Mac'],
        ];
    }

    #[DataProvider('failures')]
    public function test_a_fetch_that_failed_says_why_in_this_classs_own_words(string $reason, string $words): void
    {
        $v = self::view(self::fetch(['ok' => false, 'reason' => $reason, 'waiting' => 1]), null);
        $this->assertSame("The last fetch, at T-120, failed: $words. On the Mac: offprint pigeonhole doctor.", $v->lines[1]);
        $this->assertSame(1, $v->count, 'what waits is still counted');
        $this->assertStringNotContainsString('<', implode('', $v->lines));
    }

    public function test_a_waiting_request_shows_as_checking_and_then_as_stuck(): void
    {
        $v = self::view(self::fetch(), null, self::NOW - 30);
        $this->assertTrue($v->pending);
        $this->assertFalse($v->stuck);
        $this->assertSame("Comments: checking\u{2026}", $v->lines[0]);
        $v = self::view(self::fetch(), null, self::NOW - 16 * 60);
        $this->assertTrue($v->stuck);
        $this->assertSame('Comments: asked to check at T-960, but the Mac hasn\'t started. Check var/publish.log, and that the Mac\'s agent is installed (offprint install-agent).', $v->lines[0]);
    }

    public static function not_a_fetch_file(): array
    {
        $good = json_decode(self::fetch(), true);
        return [
            'empty' => [''],
            'not JSON' => ['{nope'],
            'a list' => ['[1,2]'],
            'a string' => ['"3"'],
            'a count that is a string' => [json_encode(['waiting' => '3'] + $good)],
            'a count that is text' => [json_encode(['waiting' => '<b>3</b>'] + $good)],
            'a negative count' => [json_encode(['waiting' => -1] + $good)],
            'a count past a million' => [json_encode(['waiting' => 1000001] + $good)],
            'a count that is a fraction' => [json_encode(['waiting' => 1.5] + $good)],
            'no count' => [json_encode(array_diff_key($good, ['waiting' => 1]))],
            'no time' => [json_encode(array_diff_key($good, ['fetched_at' => 1]))],
            'a time of nought' => [json_encode(['fetched_at' => 0] + $good)],
            'a time far ahead' => [json_encode(['fetched_at' => self::NOW + 2 * 86400] + $good)],
            'too deep' => ['{"waiting":{"a":{"b":{"c":1}}}}'],
            'too long' => [json_encode(['pad' => str_repeat('x', 5000)] + $good)],
        ];
    }

    #[DataProvider('not_a_fetch_file')]
    public function test_a_fetch_file_that_is_not_one_is_not_believed(string $raw): void
    {
        $v = self::view($raw, null);
        $this->assertSame(0, $v->count);
        $this->assertSame('The Mac\'s note of its last fetch (var/pigeonhole-fetch.json) couldn\'t be read; the next fetch writes it again.', $v->lines[1]);
        $this->assertCount(2, $v->lines);
    }

    public function test_a_collection_file_that_is_not_one_is_left_out(): void
    {
        $v = self::view(self::fetch(), '{"collected_at":"yesterday"}');
        $this->assertSame(3, $v->count);
        $this->assertCount(2, $v->lines);
        $v = self::view(null, json_encode(['imported' => '<img src=x>'] + json_decode(self::collection(), true)));
        $this->assertSame(0, $v->count);
        $this->assertStringNotContainsString('<', implode('', $v->lines));
    }

    public function test_ok_must_be_true_itself(): void
    {
        foreach ([1, 'true', null, 'yes'] as $ok) {
            $v = self::view(self::fetch(['ok' => $ok]), null);
            $this->assertStringStartsWith('The last fetch, at T-120, failed', $v->lines[1], var_export($ok, true));
        }
    }
}
