<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Offprint\Origin;

final class OriginTest extends TestCase
{
    public static function cases(): array
    {
        return [
            ['<a href="https://wp.local/about/">', '<a href="https://blog.example.com/about/">'],
            ['{"u":"https:\/\/wp.local\/a"}', '{"u":"https:\/\/blog.example.com\/a"}'],
            ['?u=https%3A%2F%2Fwp.local%2Fa', '?u=https%3A%2F%2Fblog.example.com%2Fa'],
            ['?u=https%3a%2f%2fwp.local%2fa', '?u=https%3a%2f%2fblog.example.com%2fa'],
            ['src="//wp.local/a.js"', 'src="//blog.example.com/a.js"'],
            ['http://wp.local/a', 'https://blog.example.com/a'],
            ['https://wp.localhost/a', 'https://wp.localhost/a'],
            ['https://wp.local.example.com/', 'https://wp.local.example.com/'],
            ['//wp.localhost/a', '//wp.localhost/a'],
            ['https://wp.local', 'https://blog.example.com'],
            ["'https://wp.local'", "'https://blog.example.com'"],
            ['url(https://wp.local)', 'url(https://blog.example.com)'],
            ['<b>https://wp.local<', '<b>https://blog.example.com<'],
            ["a https://wp.local\nb", "a https://blog.example.com\nb"],
            ['"https://wp.local"', '"https://blog.example.com"'],
            ['https://wp.local\\n', 'https://blog.example.com\\n'],
            ['https%3A%2F%2Fwp.local%2F', 'https%3A%2F%2Fblog.example.com%2F'],
            ['https://wp.local-x.com/', 'https://wp.local-x.com/'],
            ['https://wp.local:8443/a', 'https://wp.local:8443/a'],
            ['{&quot;u&quot;:&quot;https:\/\/wp.local&quot;}', '{&quot;u&quot;:&quot;https:\/\/blog.example.com&quot;}'],
            ['https://wp.local,', 'https://blog.example.com,'],
            ['https://wp.local;', 'https://blog.example.com;'],
            ['https://wp.local.', 'https://blog.example.com.'],
            ['https://wp.local. Next', 'https://blog.example.com. Next'],
            ['https://wp.local&amp;x=1', 'https://blog.example.com&amp;x=1'],
            ['[https://wp.local]', '[https://blog.example.com]'],
            ['{https://wp.local}', '{https://blog.example.com}'],
            ['https://wp.local|x', 'https://blog.example.com|x'],
            ['&#039;https://wp.local&#039;', '&#039;https://blog.example.com&#039;'],
            ['https%3A%2F%2Fwp.local%3A8443%2F', 'https%3A%2F%2Fwp.local%3A8443%2F'],
            ['https://wp.local_x.com/', 'https://wp.local_x.com/'],
            ['no origin here',
 'no origin here'],
        ];
    }

    #[DataProvider('cases')]
    public function test_rewrite(string $in, string $out): void
    {
        $this->assertSame($out, Origin::rewrite($in, 'https://wp.local', 'https://blog.example.com'));
    }
}
