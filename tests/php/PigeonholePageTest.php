<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Offprint\Pigeonhole;

/**
 * The parts of the page's side of comments that use no WordPress function: reading the two values the compose file
 * hands WordPress, and the block a page carries. The hooks need a real WordPress (tests/e2e.sh).
 */
final class PigeonholePageTest extends TestCase
{
    private const Q = 'age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';
    private const P = 'age1pppppppppppppppppppppppppppppppppppppppppppppppppppppppppp';

    public function testAPathAndOneOrTwoKeysAreSettings(): void
    {
        $this->assertSame(['path' => '/_pigeonhole', 'recipients' => [self::Q]], Pigeonhole::settings_from('/_pigeonhole', self::Q));
        $this->assertSame(['path' => '/drop-box_2', 'recipients' => [self::Q, self::P]], Pigeonhole::settings_from('/drop-box_2', self::Q . ' ' . self::P));
    }

    public static function notSettings(): array
    {
        $q = self::Q;
        $p = self::P;
        return [
            'a site with no pigeonhole' => ['', ''],
            'a path and no keys' => ['/_pigeonhole', ''],
            'keys and no path' => ['', $q],
            'a path with no slash' => ['_pigeonhole', $q],
            'a path of two names' => ['/a/b', $q],
            'a path with a query' => ['/a?b', $q],
            'a path with a quote' => ["/a'", $q],
            'a path with a line end' => ["/a\n", $q],
            'a path on another site' => ['//www.example.com', $q],
            'a path in capitals' => ['/Drop', $q],
            'a path that is too long' => ['/' . str_repeat('a', 41), $q],
            'three keys' => ['/_pigeonhole', "$q $p age1" . str_repeat('z', 58)],
            'a key that is too short' => ['/_pigeonhole', 'age1short'],
            'a private key' => ['/_pigeonhole', 'AGE-SECRET-KEY-1' . str_repeat('Q', 58)],
            'two keys with two spaces between' => ['/_pigeonhole', "$q  $p"],
            'two keys with a comma between' => ['/_pigeonhole', "$q,$p"],
            'a key with a line end' => ['/_pigeonhole', "$q\n"],
            'a key with markup after it' => ['/_pigeonhole', "$q</script>"],
            'the same key twice' => ['/_pigeonhole', "$q $q"],
        ];
    }

    #[DataProvider('notSettings')]
    public function testAnythingElseIsNoSettings(string $path, string $recipients): void
    {
        $this->assertNull(Pigeonhole::settings_from($path, $recipients));
    }

    public function testTheBlockIsJsonInAScriptNoBrowserRuns(): void
    {
        $block = Pigeonhole::block(['path' => '/_pigeonhole', 'recipients' => [self::Q, self::P]]);
        $this->assertSame(
            '<script type="application/json" id="offprint-pigeonhole">{"path":"/_pigeonhole","recipients":["' . self::Q . '","' . self::P . '"],"bits":18}</script>',
            $block
        );
    }

    public function testTheBlockHoldsExactlyThreeKeys(): void
    {
        $block = Pigeonhole::block(['path' => '/_pigeonhole', 'recipients' => [self::Q]]);
        $json = substr($block, strpos($block, '>') + 1, -strlen('</script>'));
        $this->assertSame(['path' => '/_pigeonhole', 'recipients' => [self::Q], 'bits' => Pigeonhole::BITS], json_decode($json, true));
    }
}
