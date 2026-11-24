<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Offprint\Paths;

final class PathsTest extends TestCase
{
    public static function mappings(): array
    {
        return [
            ['/', 'text/html', 'index.html'],
            ['/about/', 'text/html; charset=UTF-8', 'about/index.html'],
            ['/about', 'text/html', 'about/index.html'],
            ['/feed/', 'application/rss+xml', 'feed/index.xml'],
            ['/comments/feed/', 'application/atom+xml', 'comments/feed/index.xml'],
            ['/x/', 'text/xml', 'x/index.xml'],
            ['/x', 'application/xml', 'x/index.xml'],
            ['/wp-sitemap.xml', 'application/xml', 'wp-sitemap.xml'],
            ['/wp-content/themes/x/style.css', 'text/css', 'wp-content/themes/x/style.css'],
            ['/caf%C3%A9/', 'text/html', 'café/index.html'],
            ['/wp-content/uploads/my%20photo.jpg', 'image/jpeg', 'wp-content/uploads/my photo.jpg'],
            ['/2026/11/hello-world/', 'text/html', '2026/11/hello-world/index.html'],
            ['/a.b/', 'text/html', 'a.b/index.html'],
        ];
    }

    #[DataProvider('mappings')]
    public function test_maps(string $path, string $type, string $expected): void
    {
        $this->assertSame($expected, Paths::to_file($path, $type));
    }

    public static function bad(): array
    {
        return [
            ['/../etc/passwd'],
            ['/a/%2e%2e/b'],
            ["/a\0b"],
            ['/a/%00b'],
        ];
    }

    #[DataProvider('bad')]
    public function test_rejects(string $path): void
    {
        $this->expectException(InvalidArgumentException::class);
        Paths::to_file($path, 'text/html');
    }

    public static function folders(): array
    {
        return [
            ['/', true], ['', true], ['/about/', true], ['/about', true], ['/a.b/', true], ['/a/./', true],
            ['/x.png', false], ['/wp-content/uploads/my%20photo.jpg', false], ['/wp-sitemap.xml', false],
        ];
    }

    #[DataProvider('folders')]
    public function test_is_folder(string $path, bool $folder): void
    {
        $this->assertSame($folder, Paths::is_folder($path));
    }
}
