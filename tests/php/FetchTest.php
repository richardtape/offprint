<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Offprint\Fetch;

/** Fetch::target: the request only ever goes to the web server in the container, at a path on it. */
final class FetchTest extends TestCase
{
    private const BASE = 'http://127.0.0.1';

    public static function targets(): array
    {
        return [
            ['https://blog.example.com/about/', 'http://127.0.0.1/about/'],
            ['https://blog.example.com/x.css?ver=6.9', 'http://127.0.0.1/x.css?ver=6.9'],
            ['https://blog.example.com', 'http://127.0.0.1/'],
            ['https://blog.example.com/a b/caf' . "\u{e9}", 'http://127.0.0.1/a%20b/caf%C3%A9'],
            ['https://blog.example.com//evil.example/x', 'http://127.0.0.1//evil.example/x'],
            ['https://blog.example.com/@evil.example/', 'http://127.0.0.1/@evil.example/'],
        ];
    }

    #[DataProvider('targets')]
    public function test_a_public_address_becomes_a_path_on_the_local_server(string $url, string $target): void
    {
        $this->assertSame($target, Fetch::target(self::BASE, $url));
        $this->assertSame($target, Fetch::target(self::BASE . '/', $url));
    }

    public static function refused(): array
    {
        return array_map(fn ($u) => [$u], [
            '/about/', 'about/', 'blog.example.com/about/', '//', 'http:///x', '', 'mailto:a@b.c', 'https:', '?x=1',
        ]);
    }

    #[DataProvider('refused')]
    public function test_an_address_without_a_host_or_a_path_from_the_root_is_refused(string $url): void
    {
        $this->assertNull(Fetch::target(self::BASE, $url));
    }

    public function test_get_says_why_it_refused(): void
    {
        $fetch = new Fetch(self::BASE, 'wp.local', str_repeat('a', 40));
        $this->assertSame('it is not an address with a host and a path from the root', $fetch->get('/about/'));
    }
}
