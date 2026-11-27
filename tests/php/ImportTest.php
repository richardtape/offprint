<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Offprint\Import;

/**
 * The parts of the import that use no WordPress function: reading the one line the Mac sends, and the one line
 * answered. What needs a real WordPress (the filter, the held status, the same submission twice) is in tests/e2e.sh.
 */
final class ImportTest extends TestCase
{
    private static function line(array $over = [], array $fields = []): string
    {
        return json_encode($over + [
            'v' => 1, 'kind' => 'comment', 'id' => '0123456789abcdef0123456789abcdef', 'ts' => 1795000000, 'page' => '/hello/',
            'fields' => $fields + ['post_id' => 4, 'parent' => 0, 'author' => 'Ada', 'email' => 'ada@example.com', 'url' => '', 'content' => 'Hello.', 'hp' => '', 'elapsed' => 42],
        ]) . "\n";
    }

    public function testACheckedCommentIsRead(): void
    {
        $this->assertSame(
            ['id' => '0123456789abcdef0123456789abcdef', 'ts' => 1795000000, 'post_id' => 4, 'parent' => 0, 'author' => 'Ada', 'email' => 'ada@example.com', 'url' => '', 'content' => 'Hello.'],
            Import::parse(self::line())
        );
    }

    public static function notComments(): array
    {
        return [
            'junk' => ['junk'],
            'empty' => [''],
            'a list' => ['[1]'],
            'a canary' => [self::line(['kind' => 'canary'])],
            'another version' => [self::line(['v' => 2])],
            'a bad id' => [self::line(['id' => 'x'])],
            'an id with a line end inside the string' => [self::line(['id' => str_repeat('a', 31) . "\n"])],
            'a time that is text' => [self::line(['ts' => 'now'])],
            'fields that is text' => [self::line(['fields' => 'x'])],
            'a post that is text' => [self::line([], ['post_id' => '4'])],
            'a negative parent' => [self::line([], ['parent' => -1])],
            'a name that is a list' => [self::line([], ['author' => ['a']])],
            'text that is a number' => [self::line([], ['content' => 7])],
        ];
    }

    #[DataProvider('notComments')]
    public function testWhatIsNotACheckedCommentIsRefused(string $json): void
    {
        $this->assertSame('it is not a checked comment', Import::parse($json));
    }

    public function testTheLongestLineTheMacSendsIsRead(): void
    {
        $short = self::line([], ['content' => 'x']);
        $line = self::line([], ['content' => str_repeat('x', 8192 - (strlen($short) - 1) + 1)]);
        $this->assertSame(8193, strlen($line));   // 8192 bytes and the line end
        $this->assertIsArray(Import::parse($line));
    }

    public static function ownAddresses(): array
    {
        $x = Import::OWN_ADDRESS;
        return [
            'none' => ['Hello, see https://other.example.com/a and www.example.com.', 'Hello, see https://other.example.com/a and www.example.com.'],
            'a whole address' => ['see https://blog.example.com/not-there now', "see $x now"],
            'with a query' => ['see https://blog.example.com/?p=999#c now', "see $x now"],
            'http' => ['http://blog.example.com/wp-admin/', $x],
            'no scheme' => ['go to blog.example.com/wp-login.php please', "go to $x please"],
            'no scheme, two slashes' => ['//blog.example.com/x', $x],
            'the name alone' => ['I like blog.example.com a lot', "I like $x a lot"],
            'in capitals' => ['HTTPS://BLOG.EXAMPLE.COM/Not-There', $x],
            'with a port' => ['https://blog.example.com:8443/x y', "$x y"],
            'the local name' => ['its real home is mysite.local, I think', "its real home is $x, I think"],
            'the local name, its dot as an entity' => ['mysite&#46;local and mysite&#x2E;local and mysite&period;local and mysite%2elocal', "$x and $x and $x and $x"],
            'twice' => ['blog.example.com/a blog.example.com/b', "$x $x"],
            'inside a longer name' => ['sub.blog.example.com/x', "sub.$x"],
            'in markup' => ['<a href="https://other.example.com/">blog.example.com/x</a> <b>y</b>', '<a href="https://other.example.com/">' . $x . '</a> <b>y</b>'],
            'in an attribute, the tag is left whole' => ['<abbr title="mysite.local/x">a</abbr>', '<abbr title="' . $x . '">a</abbr>'],
        ];
    }

    #[DataProvider('ownAddresses')]
    public function testAnAddressOfThisSitesOwnIsTakenOutOfTheWords(string $given, string $kept): void
    {
        $this->assertSame($kept, Import::without_own_addresses($given, ['blog.example.com', 'mysite.local']));
    }

    public function testWithNoHostOfItsOwnNothingIsTakenOut(): void
    {
        $this->assertSame('blog.example.com', Import::without_own_addresses('blog.example.com', []));
        $this->assertSame('blog.example.com', Import::without_own_addresses('blog.example.com', ['', '.']));
    }

    public function testACommentersNameLosesAnAddressOfThisSitesOwn(): void
    {
        $this->assertSame(Import::OWN_ADDRESS, Import::parse(self::line([], ['author' => 'mysite.local']), ['blog.example.com', 'mysite.local'])['author']);
    }

    public function testNoMoreThanASubmissionIsRead(): void
    {
        $this->assertSame('it is longer than a submission', Import::parse(str_repeat(' ', Import::MAX_BYTES)));
    }

    public static function addresses(): array
    {
        return [
            ['https://www.example.com/', 'https://www.example.com/'],
            ['http://www.example.com/a?b=c', 'http://www.example.com/a?b=c'],
            ['HTTPS://www.example.com/', 'HTTPS://www.example.com/'],
            ['https://www.example.com:8443/a', 'https://www.example.com:8443/a'],
            ['https://www.example.com', 'https://www.example.com'],
            ['https://www.example.com?a=b', 'https://www.example.com?a=b'],
            ['', ''],
            ['javascript:alert(1)', ''],
            // this site's own hosts, however written: the exporter would follow the link
            ['https://blog.example.com/not-there', ''],
            ['http://blog.example.com/', ''],
            ['https://BLOG.example.COM/not-there', ''],
            ['https://blog.example.com./not-there', ''],
            ['https://blog.example.com:443/not-there', ''],
            ['https://mysite.local/wp-admin/', ''],
            // another site's address that names one of this site's hosts further in: the checks refuse the local name anywhere
            ['https://other.example.com/?mysite.local', ''],
            ['https://other.example.com/blog.example.com/x', ''],
            ['https://other.example.com/mysite%2Elocal', ''],
            // an address two programs could read in two ways is no address
            ['https://www.example.com@blog.example.com/', ''],
            ['https://blog.example.com\\@www.example.com/', ''],
            ['https://www.example.com/a\\b', ''],
            ['https://user:pass@www.example.com/', ''],
            ['https://[::1]/', ''],
            ['https://www.exämple.com/', ''],
            ['https://www.example.com:99999999/', ''],
            ['https://./', ''],
            ['www.example.com', ''],
            ['/wp-admin/', ''],
            ['//www.example.com/', ''],
            ['data:text/html,x', ''],
            ['https://www.example.com/ onclick=x', ''],
            [' https://www.example.com/', ''],
            ['https://', ''],
        ];
    }

    #[DataProvider('addresses')]
    public function testAWebAddressIsKeptOnlyWhenItIsAWholeOne(string $given, string $kept): void
    {
        $this->assertSame($kept, Import::parse(self::line([], ['url' => $given]), ['blog.example.com', 'mysite.local'])['url']);
        $this->assertSame($kept !== '', Import::foreign($given, ['blog.example.com', 'mysite.local']));
    }

    public function testTheAnswersAreOneLineEach(): void
    {
        $this->assertSame('imported 12 hold', Import::imported(12, 'hold'));
        $this->assertSame('already 12', Import::already(12));
        $this->assertSame('refused no such public post, or its comments are closed', Import::refused('no such public post, or its comments are closed'));
    }

    public function testARefusalNeverCarriesAnythingButPlainWords(): void
    {
        // WordPress's own error codes pass through here, and a plugin can make one say anything.
        $this->assertSame('refused comment_duplicate', Import::refused('comment_duplicate'));
        $this->assertSame('refused scriptalert1scriptnext line', Import::refused("<script>alert(1)</script>\nnext line"));
        $this->assertSame('refused no reason was given', Import::refused("\n"));
        $this->assertSame(128, strlen(Import::refused(str_repeat('a', 500))));
    }
}
