<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

require_once __DIR__ . '/../../lib/pigeonhole.php';

/**
 * lib/pigeonhole.php: the check of one opened submission, and the sorter. Both run on the Mac, before WordPress sees
 * anything, and use no WordPress function.
 */
final class PigeonholeTest extends TestCase
{
    private const NOW = 1795000000;

    /** A good comment's envelope, as an array, with any of its members replaced. */
    private static function envelope(array $over = [], array $fields = []): array
    {
        return $over + [
            'v' => 1,
            'kind' => 'comment',
            'id' => '0123456789abcdef0123456789abcdef',
            'ts' => self::NOW - 60,
            'page' => '/hello-comments/',
            'fields' => $fields + [
                'post_id' => 4,
                'parent' => 0,
                'author' => 'Ada',
                'email' => 'ada@example.com',
                'url' => '',
                'content' => "A comment.\nOn two lines, with <b>bold</b> and ünïcode.",
                'hp' => '',
                'elapsed' => 42,
            ],
        ];
    }

    /** What the browser sends: the JSON, padded with spaces to exactly 8192 bytes. */
    private static function padded(array|string $envelope): string
    {
        $json = is_string($envelope) ? $envelope : json_encode($envelope, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_LINE_TERMINATORS);
        return str_pad($json, 8192, ' ');
    }

    private static function check(array|string $envelope): array
    {
        return offprint_pigeonhole_check(self::padded($envelope), self::NOW);
    }

    public function testAGoodCommentPasses(): void
    {
        $r = self::check(self::envelope());
        $this->assertTrue($r['ok'], $r['why'] ?? '');
        $this->assertSame('comment', $r['kind']);
        $this->assertSame(self::envelope(), json_decode($r['json'], true));
    }

    public function testWhatPassesIsOneLineWithNoPadding(): void
    {
        $r = self::check(self::envelope());
        $this->assertStringNotContainsString("\n", $r['json']);
        $this->assertSame(rtrim($r['json']), $r['json']);
        $this->assertLessThan(8192, strlen($r['json']));
    }

    public function testWhatPassesHasItsKeysInOneOrderWhateverOrderWasSent(): void
    {
        $e = self::envelope();
        $shuffled = array_reverse($e, true);
        $shuffled['fields'] = array_reverse($e['fields'], true);
        $r = self::check($shuffled);
        $this->assertTrue($r['ok'], $r['why'] ?? '');
        $this->assertSame(offprint_pigeonhole_line($e), $r['json']);
        $this->assertStringStartsWith('{"v":1,"kind":"comment","id":"', $r['json']);
    }

    public function testACanaryPassesWithNoFields(): void
    {
        $r = self::check(json_encode(['v' => 1, 'kind' => 'canary', 'id' => str_repeat('a', 32), 'ts' => self::NOW, 'page' => '/', 'fields' => new stdClass()]));
        $this->assertTrue($r['ok'], $r['why'] ?? '');
        $this->assertSame('canary', $r['kind']);
    }

    public function testACanaryWithFieldsIsRefused(): void
    {
        $r = self::check(self::envelope(['kind' => 'canary']));
        $this->assertFalse($r['ok']);
    }

    public static function wrongSizes(): array
    {
        return [[0], [1], [8191], [8193], [16384]];
    }

    #[DataProvider('wrongSizes')]
    public function testOnlyTheExactSizeIsRead(int $bytes): void
    {
        $r = offprint_pigeonhole_check(str_pad('{}', $bytes, ' '), self::NOW);
        $this->assertFalse($r['ok']);
        $this->assertSame('it is not the size a submission has', $r['why']);
    }

    public static function notJson(): array
    {
        return [
            'junk' => ['junk'],
            'a list' => ['[1,2]'],
            'a string' => ['"x"'],
            'null' => ['null'],
            'two objects' => ['{}{}'],
            'padded with something else' => ['{}' . "\0"],
            'not UTF-8' => ['{"v":"' . "\xff" . '"}'],
            'nested too deeply' => ['{"v":1,"kind":"comment","fields":{"a":{"b":{"c":1}}}}'],
        ];
    }

    #[DataProvider('notJson')]
    public function testWhatIsNotOneJsonObjectIsRefused(string $text): void
    {
        $r = self::check($text);
        $this->assertFalse($r['ok']);
    }

    public static function badEnvelopes(): array
    {
        $e = fn (array $over = [], array $fields = []) => self::envelope($over, $fields);
        $without = function (string $key) { $x = self::envelope(); unset($x[$key]); return $x; };
        $withoutField = function (string $key) { $x = self::envelope(); unset($x['fields'][$key]); return $x; };
        $cases = [
            'an extra key' => [$e() + ['extra' => 1], 'it has a key a submission does not have'],
            'an extra field' => [$e([], ['admin' => true]), 'it has a field a comment does not have'],
            'version 2' => [$e(['v' => 2]), 'its version is not 1'],
            'version as a string' => [$e(['v' => '1']), 'its version is not 1'],
            'an unknown kind' => [$e(['kind' => 'form']), 'its kind is not one this Offprint knows'],
            'a kind that is a number' => [$e(['kind' => 7]), 'its kind is not one this Offprint knows'],
            'a short id' => [$e(['id' => 'abc']), 'its id is not 32 hex digits'],
            'an id in capitals' => [$e(['id' => str_repeat('A', 32)]), 'its id is not 32 hex digits'],
            'an id with a line end' => [$e(['id' => str_repeat('a', 32) . "\n"]), 'its id is not 32 hex digits'],
            'a time as a string' => [$e(['ts' => (string) self::NOW]), 'its time is not a whole number'],
            'a time as a fraction' => [$e(['ts' => self::NOW + 0.5]), 'its time is not a whole number'],
            'a time 31 days ago' => [$e(['ts' => self::NOW - 31 * 86400]), 'it was sent more than 30 days ago'],
            'a page with no slash' => [$e(['page' => 'hello']), 'its page is not a path on the site'],
            'a page on another site' => [$e(['page' => 'https://www.example.com/']), 'its page is not a path on the site'],
            'a page starting with two slashes' => [$e(['page' => '//www.example.com/']), 'its page is not a path on the site'],
            'a page with a control character' => [$e(['page' => "/a\tb"]), 'its page is not a path on the site'],
            'a page that is too long' => [$e(['page' => '/' . str_repeat('a', 500)]), 'its page is not a path on the site'],
            'fields that is a list' => [$e(['fields' => [1]]), 'its fields are not an object'],
            'fields that is a string' => [$e(['fields' => 'x']), 'its fields are not an object'],
            'a post id of 0' => [$e([], ['post_id' => 0]), 'its post is not a whole number above 0'],
            'a post id as a string' => [$e([], ['post_id' => '4']), 'its post is not a whole number above 0'],
            'a post id too large' => [$e([], ['post_id' => 2147483648]), 'its post is not a whole number above 0'],
            'a negative parent' => [$e([], ['parent' => -1]), 'its parent is not a whole number'],
            'a parent as a string' => [$e([], ['parent' => '0']), 'its parent is not a whole number'],
            'a name that is a list' => [$e([], ['author' => ['a']]), 'its name is not text'],
            'a name that is too long' => [$e([], ['author' => str_repeat('a', 246)]), 'its name is too long'],
            'a name with a line end' => [$e([], ['author' => "Ada\nLovelace"]), 'its name has a control character'],
            'a name with a NUL' => [$e([], ['author' => "Ada\0"]), 'its name has a control character'],
            'an email that is too long' => [$e([], ['email' => str_repeat('a', 101)]), 'its email address is too long'],
            'an email with a line end' => [$e([], ['email' => "a@example.com\r\nBcc: b@example.com"]), 'its email address has a control character'],
            'an address that is too long' => [$e([], ['url' => 'https://www.example.com/' . str_repeat('a', 200)]), 'its web address is too long'],
            'an address with a tab' => [$e([], ['url' => "https://www.example.com/\t"]), 'its web address has a control character'],
            'empty text' => [$e([], ['content' => '']), 'its text is empty'],
            'text of spaces only' => [$e([], ['content' => " \n\t "]), 'its text is empty'],
            'text that is too long' => [$e([], ['content' => str_repeat('a', 6001)]), 'its text is too long'],
            'text with a NUL' => [$e([], ['content' => "a\0b"]), 'its text has a control character'],
            'text with an escape character' => [$e([], ['content' => "a\x1bb"]), 'its text has a control character'],
            'text with a C1 control' => [$e([], ['content' => "a\u{0085}b"]), 'its text has a control character'],
            'text that is a number' => [$e([], ['content' => 7]), 'its text is not text'],
            'a hidden field that is too long' => [$e([], ['hp' => str_repeat('a', 201)]), 'its hidden field is too long'],
            'a hidden field that is a list' => [$e([], ['hp' => []]), 'its hidden field is not text'],
            'a negative time taken' => [$e([], ['elapsed' => -1]), 'its time taken is not a whole number'],
            'a time taken as a string' => [$e([], ['elapsed' => '42']), 'its time taken is not a whole number'],
        ];
        foreach (['v', 'kind', 'id', 'ts', 'page', 'fields'] as $key) {
            $cases["no $key"] = [$without($key), 'it lacks a key a submission has'];
        }
        foreach (['post_id', 'parent', 'author', 'email', 'url', 'content', 'hp', 'elapsed'] as $key) {
            $cases["no field $key"] = [$withoutField($key), 'it lacks a field a comment has'];
        }
        return $cases;
    }

    #[DataProvider('badEnvelopes')]
    public function testABadEnvelopeIsRefusedWithItsReason(array $envelope, string $why): void
    {
        $r = self::check($envelope);
        $this->assertFalse($r['ok']);
        $this->assertSame($why, $r['why']);
    }

    public function testAReasonNeverRepeatsWhatWasSent(): void
    {
        $marker = 'MARKER-ZX81';
        foreach (self::badEnvelopes() as [$envelope]) {
            $envelope['fields'] = is_array($envelope['fields'] ?? null) ? $envelope['fields'] : [];
            $text = str_replace('Ada', $marker, json_encode($envelope, JSON_UNESCAPED_UNICODE));
            $r = offprint_pigeonhole_check(self::padded($text), self::NOW);
            $this->assertStringNotContainsString($marker, json_encode($r));
        }
        $r = self::check('{"' . $marker . '":1}');
        $this->assertFalse($r['ok']);
        $this->assertStringNotContainsString($marker, $r['why']);
    }

    public function testAKeyGivenTwiceIsRefused(): void
    {
        // PHP keeps the last of two; what was checked must be what a stricter reader would have read.
        $json = json_encode(self::envelope());
        $twice = '{"kind":"canary",' . substr($json, 1);
        $r = self::check($twice);
        $this->assertFalse($r['ok']);
        $this->assertSame('it names a key twice', $r['why']);
    }

    public function testACommentFromAClockThatRunsAheadIsDatedNowNotRefused(): void
    {
        // The visitor was told it was sent. It is not dated in the future, and not lost.
        foreach ([self::NOW + 301, self::NOW + 86400, 2147483647] as $ts) {
            $r = self::check(self::envelope(['ts' => $ts]));
            $this->assertTrue($r['ok'], $r['why'] ?? '');
            $this->assertSame(self::NOW, json_decode($r['json'], true)['ts']);
        }
        // within the five minutes two clocks may differ by, its own time is kept
        $r = self::check(self::envelope(['ts' => self::NOW + 300]));
        $this->assertSame(self::NOW + 300, json_decode($r['json'], true)['ts']);
    }

    public function testTheEdgesOfTheTimeWindowPass(): void
    {
        $this->assertTrue(self::check(self::envelope(['ts' => self::NOW - 30 * 86400]))['ok']);
        $this->assertTrue(self::check(self::envelope(['ts' => self::NOW + 300]))['ok']);
    }

    public function testALineIsNeverLongerThanWhatWasSent(): void
    {
        // U+2028 is three bytes as sent; written out escaped it would be six, and the line longer than a submission:
        // the sorter and the import, which read no more than one, would then fail on it every time.
        $e = self::envelope([], ['content' => str_repeat("\u{2028}", 1500) . 'x']);
        $r = self::check($e);
        $this->assertTrue($r['ok'], $r['why'] ?? '');
        $this->assertLessThanOrEqual(8192, strlen($r['json']));
        $this->assertSame($e['fields']['content'], json_decode($r['json'], true)['fields']['content']);
        $e['ts'] = time() - 5;
        [$code, $out] = self::command('sort', offprint_pigeonhole_line($e) . "\n");
        $this->assertSame([0, "hold\n"], [$code, $out]);
    }

    public function testASubmissionFullOfCharactersThatNeedEscapingPassesTheCheckAndTheSorter(): void
    {
        // Each quotation mark is two bytes in JSON, as sent and as written out: close to the size a submission has.
        $e = self::envelope(['ts' => time() - 5], ['content' => str_repeat('"', 3900)]);
        $line = offprint_pigeonhole_line($e);
        $this->assertGreaterThan(8000, strlen($line));
        $this->assertLessThanOrEqual(8192, strlen($line));
        [$code, $out] = self::command('check', str_pad($line, 8192, ' '));
        $this->assertSame([0, $line . "\n"], [$code, $out]);
        [$code, $out] = self::command('sort', $line . "\n");
        $this->assertSame([0, "hold\n"], [$code, $out]);
    }

    public function testALineLongerThanASubmissionIsRefusedHoweverItCameToBe(): void
    {
        // Nothing that passes the checks above is known to write out longer than it was sent. Should something, it is
        // refused here, with a reason, and never handed on to a reader that would fail on it every time.
        $r = offprint_pigeonhole_passed(self::envelope([], ['content' => str_repeat('x', 9000)]));
        $this->assertSame(['ok' => false, 'why' => 'it is longer written out than a submission may be'], $r);
        $this->assertTrue(offprint_pigeonhole_passed(self::envelope())['ok']);
    }

    public static function oneLineOnly(): array
    {
        return [
            'a line separator' => ["\u{2028}"], 'a paragraph separator' => ["\u{2029}"],
            'a right-to-left override' => ["\u{202E}"], 'a left-to-right embedding' => ["\u{202A}"],
            'an isolate' => ["\u{2066}"], 'a pop isolate' => ["\u{2069}"],
        ];
    }

    #[DataProvider('oneLineOnly')]
    public function testANameMayNotEndALineOrTurnTheTextAround(string $char): void
    {
        $r = self::check(self::envelope([], ['author' => "Ada$char" . 'nimda']));
        $this->assertFalse($r['ok']);
        $this->assertSame('its name has a control character', $r['why']);
        $r = self::check(self::envelope([], ['url' => "https://www.example.com/$char"]));
        $this->assertSame('its web address has a control character', $r['why'] ?? '');
    }

    public function testANameMayHaveTheJoinersSomeScriptsNeed(): void
    {
        $r = self::check(self::envelope([], ['author' => "می\u{200C}خواهم"]));
        $this->assertTrue($r['ok'], $r['why'] ?? '');
    }

    public function testTextMayHaveLineEndsAndTabs(): void
    {
        $r = self::check(self::envelope([], ['content' => "one\r\ntwo\n\tthree"]));
        $this->assertTrue($r['ok'], $r['why'] ?? '');
    }

    public function testTheLongestOfEachFieldPasses(): void
    {
        $r = self::check(self::envelope([], [
            'author' => str_repeat('a', 245), 'email' => str_repeat('a', 100), 'url' => str_repeat('a', 200),
            'content' => str_repeat('a', 6000), 'hp' => str_repeat('a', 200), 'post_id' => 2147483647, 'parent' => 2147483647,
        ]));
        $this->assertTrue($r['ok'], $r['why'] ?? '');
    }

    // ---- the sorter ----

    private static function sort(array $fields = []): array
    {
        return offprint_pigeonhole_sort(self::envelope([], $fields));
    }

    public function testAnOrdinaryCommentIsHeld(): void
    {
        $this->assertSame(['hold', ''], self::sort());
    }

    public function testAFilledHiddenFieldIsSpam(): void
    {
        $this->assertSame(['spam', 'the hidden field was filled in'], self::sort(['hp' => 'https://www.example.com']));
    }

    public function testACommentSentAtOnceIsSpam(): void
    {
        $this->assertSame(['spam', 'it was sent within 3 seconds of the form being touched'], self::sort(['elapsed' => 2]));
        $this->assertSame(['hold', ''], self::sort(['elapsed' => 3]));
    }

    public function testACanaryIsHeld(): void
    {
        $this->assertSame(['hold', ''], offprint_pigeonhole_sort(['v' => 1, 'kind' => 'canary', 'id' => str_repeat('a', 32), 'ts' => self::NOW, 'page' => '/', 'fields' => []]));
    }

    public function testASortersReasonNeverRepeatsWhatWasSent(): void
    {
        [, $why] = self::sort(['hp' => 'MARKER-ZX81']);
        $this->assertStringNotContainsString('MARKER-ZX81', $why);
    }

    // ---- as a command ----

    /** @return array{0:int,1:string,2:string} */
    private static function command(string $verb, string $stdin): array
    {
        $p = proc_open([PHP_BINARY, __DIR__ . '/../../lib/pigeonhole.php', $verb], [['pipe', 'r'], ['pipe', 'w'], ['pipe', 'w']], $pipes);
        @fwrite($pipes[0], $stdin);   // the command may stop reading before all of it is written
        fclose($pipes[0]);
        $out = stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        return [proc_close($p), $out, $err];
    }

    public function testTheCheckCommandPrintsTheSubmissionOrItsReason(): void
    {
        $e = self::envelope(['ts' => time() - 5]);
        [$code, $out, $err] = self::command('check', self::padded($e));
        $this->assertSame(0, $code, $err);
        $this->assertEquals($e, json_decode(rtrim($out, "\n"), true));
        $this->assertSame("\n", substr($out, -1));
        $this->assertSame('', $err);

        [$code, $out, $err] = self::command('check', self::padded(self::envelope(['ts' => time() - 5, 'kind' => 'form'])));
        $this->assertSame(1, $code);
        $this->assertSame('', $out);
        $this->assertSame("its kind is not one this Offprint knows\n", $err);
    }

    public function testTheCheckCommandReadsNoMoreThanASubmission(): void
    {
        [$code, $out, $err] = self::command('check', str_repeat(' ', 5000000));
        $this->assertSame(1, $code);
        $this->assertSame('', $out);
        $this->assertSame("it is not the size a submission has\n", $err);
    }

    public function testTheSortCommandPrintsHoldOrSpam(): void
    {
        [$code, $out] = self::command('sort', offprint_pigeonhole_line(self::envelope(['ts' => time() - 5])) . "\n");
        $this->assertSame([0, "hold\n"], [$code, $out]);
        [$code, $out] = self::command('sort', offprint_pigeonhole_line(self::envelope(['ts' => time() - 5], ['hp' => 'x'])) . "\n");
        $this->assertSame([0, "spam\tthe hidden field was filled in\n"], [$code, $out]);
    }

    public function testTheSortCommandFailsOnWhatWasNotChecked(): void
    {
        [$code, $out] = self::command('sort', "junk\n");
        $this->assertSame(2, $code);
        $this->assertSame('', $out);
    }

    public function testAnUnknownVerbIsAUsageMistake(): void
    {
        [$code, $out, $err] = self::command('explode', '');
        $this->assertSame(2, $code);
        $this->assertSame('', $out);
        $this->assertStringContainsString('usage:', $err);
    }
}
