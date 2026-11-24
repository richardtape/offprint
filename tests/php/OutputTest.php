<?php
declare(strict_types=1);

use PHPUnit\Framework\TestCase;
use Offprint\Output;

final class OutputTest extends TestCase
{
    private const NEEDLES = ['wp.local' => 'wp.local', 'the secret' => 's3cr3t-value'];

    private string $tmp;

    protected function setUp(): void
    {
        $this->tmp = sys_get_temp_dir() . '/output-test-' . bin2hex(random_bytes(6));
        mkdir($this->tmp);
    }

    protected function tearDown(): void
    {
        $files = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($this->tmp, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($files as $file) {
            $file->isDir() && !$file->isLink() ? rmdir($file->getPathname()) : unlink($file->getPathname());
        }
        rmdir($this->tmp);
    }

    /** @return resource */
    private static function stream(string $bytes)
    {
        $s = fopen('php://memory', 'w+b');
        fwrite($s, $bytes);
        rewind($s);
        return $s;
    }

    private function refused(callable $act, string $message): void
    {
        try {
            $act();
        } catch (RuntimeException $e) {
            $this->assertStringContainsString($message, $e->getMessage());
            return;
        }
        $this->fail("Expected a refusal containing \"$message\"");
    }

    public function test_makes_a_missing_folder_and_accepts_an_empty_one(): void
    {
        new Output("$this->tmp/a/b");
        $this->assertDirectoryExists("$this->tmp/a/b");
        new Output("$this->tmp/a/b");
        $this->addToAssertionCount(1);
    }

    public function test_refuses_a_folder_that_is_not_empty_or_not_a_folder(): void
    {
        touch("$this->tmp/.hidden");
        $this->refused(fn () => new Output($this->tmp), 'is not empty');
        $this->refused(fn () => new Output("$this->tmp/.hidden"), 'is not a folder');
    }

    public function test_writes_the_bytes_exactly_into_new_folders(): void
    {
        $out = new Output("$this->tmp/out");
        $bytes = "PNG\0\r\n\x1a\n" . random_bytes(3000);
        [$written, $found] = $out->write('a/b/c.png', self::stream($bytes), 'https://x/c.png', self::NEEDLES);
        $this->assertSame(strlen($bytes), $written);
        $this->assertSame([], $found);
        $this->assertSame($bytes, file_get_contents("$this->tmp/out/a/b/c.png"));
    }

    public function test_finds_each_needle_in_any_case_and_across_chunks(): void
    {
        $out = new Output("$this->tmp/out", 4);
        $this->assertSame(['wp.local'], $out->write('one.html', self::stream('abcWP.Local!'), 'one', self::NEEDLES)[1]);
        $this->assertSame(['wp.local'], $out->write('two.html', self::stream('wp.local'), 'two', self::NEEDLES)[1]);
        $this->assertSame([], $out->write('three.html', self::stream('wp.loca l'), 'three', self::NEEDLES)[1]);
        $this->assertSame(
            ['wp.local', 'the secret'], // In the order given, not the order found.
            $out->write('four.html', self::stream('x s3cr3t-Value y wp.local'), 'four', self::NEEDLES)[1]
        );
        $this->assertSame([], $out->write('five.html', self::stream('anything'), 'five', ['empty' => ''])[1]);
    }

    public function test_never_overwrites(): void
    {
        $out = new Output("$this->tmp/out");
        $out->write('a/index.html', self::stream('first'), 'https://x/a/', self::NEEDLES);
        $this->refused(
            fn () => $out->write('a/index.html', self::stream('second'), 'https://x/a', self::NEEDLES),
            'already written for https://x/a/'
        );
        // Another name for the same file (a case-insensitive disk) is caught by the disk itself.
        touch("$this->tmp/out/b.html");
        $this->refused(fn () => $out->write('b.html', self::stream('x'), 'https://x/b.html', self::NEEDLES), 'already exists');
        $this->assertSame('first', file_get_contents("$this->tmp/out/a/index.html"));
    }

    public function test_a_file_and_a_folder_cannot_share_a_name(): void
    {
        $out = new Output("$this->tmp/out");
        $out->write('a/index.html', self::stream('x'), 'https://x/a/', self::NEEDLES);
        $this->refused(fn () => $out->write('a', self::stream('x'), 'https://x/a', self::NEEDLES), 'is a folder');
        $out->write('f.jpg', self::stream('x'), 'https://x/f.jpg', self::NEEDLES);
        $this->refused(fn () => $out->write('f.jpg/index.html', self::stream('x'), 'https://x/f.jpg/', self::NEEDLES), 'a file is in the way');
    }

    public function test_stays_inside_the_folder(): void
    {
        $out = new Output("$this->tmp/out");
        $this->refused(fn () => $out->write('../escape.txt', self::stream('x'), 'e', self::NEEDLES), 'outside');
        $this->refused(fn () => $out->write('a/../../escape.txt', self::stream('x'), 'e', self::NEEDLES), 'outside');
        mkdir("$this->tmp/elsewhere");
        symlink("$this->tmp/elsewhere", "$this->tmp/out/link");
        $this->refused(fn () => $out->write('link/x.txt', self::stream('x'), 'e', self::NEEDLES), 'outside');
        // Deeper: the folder outside must not be made before the check.
        $this->refused(fn () => $out->write('link/a/x.txt', self::stream('x'), 'e', self::NEEDLES), 'outside');
        $this->assertFileDoesNotExist("$this->tmp/escape.txt");
        $this->assertFileDoesNotExist("$this->tmp/elsewhere/x.txt");
        $this->assertDirectoryDoesNotExist("$this->tmp/elsewhere/a");
    }
}
