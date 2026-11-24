<?php
declare(strict_types=1);

namespace Offprint {
    /**
     * Stands in for WordPress's get_option, for Export_Mode only: PHP finds a function in the caller's namespace
     * before the global one, and nothing else under PHPUnit calls get_option.
     */
    function get_option(string $name, $default = false)
    {
        \ExportModeTest::$reads[] = $name;
        return \ExportModeTest::$options[$name] ?? $default;
    }
}

namespace {
    use PHPUnit\Framework\TestCase;
    use Offprint\Export_Mode;

    /** Export_Mode::is_active: the header decides first; only a request that sent one reads the option. */
    final class ExportModeTest extends TestCase
    {
        private const SECRET = 'sekrit0123456789abcdef0123456789abcdef01';

        /** @var string[] Every option read. */
        public static array $reads = [];
        /** @var array<string, mixed> */
        public static array $options = [];

        protected function setUp(): void
        {
            if (!defined('OFFPRINT_PUBLIC_ORIGIN')) {
                define('OFFPRINT_PUBLIC_ORIGIN', 'https://blog.example.com');
            }
            self::$reads = [];
            self::$options = ['offprint_secret' => self::SECRET];
            (new ReflectionProperty(Export_Mode::class, 'active'))->setValue(null, null);
            unset($_SERVER['HTTP_X_OFFPRINT_EXPORT']);
        }

        protected function tearDown(): void
        {
            unset($_SERVER['HTTP_X_OFFPRINT_EXPORT']);
            (new ReflectionProperty(Export_Mode::class, 'active'))->setValue(null, null);
        }

        public function test_without_the_header_it_is_off_and_reads_no_option(): void
        {
            $this->assertFalse(Export_Mode::is_active());
            $this->assertSame([], self::$reads);
        }

        public function test_with_an_empty_header_it_is_off_and_reads_no_option(): void
        {
            $_SERVER['HTTP_X_OFFPRINT_EXPORT'] = '';
            $this->assertFalse(Export_Mode::is_active());
            $this->assertSame([], self::$reads);
        }

        public function test_with_the_wrong_secret_it_is_off(): void
        {
            $_SERVER['HTTP_X_OFFPRINT_EXPORT'] = str_repeat('x', 40);
            $this->assertFalse(Export_Mode::is_active());
            $this->assertSame(['offprint_secret'], self::$reads);
        }

        public function test_with_the_secret_it_is_on_and_decided_once(): void
        {
            $_SERVER['HTTP_X_OFFPRINT_EXPORT'] = self::SECRET;
            $this->assertTrue(Export_Mode::is_active());
            $this->assertTrue(Export_Mode::is_active());
            $this->assertSame(['offprint_secret'], self::$reads);
        }

        public function test_a_short_or_missing_secret_is_off_even_when_the_header_matches_it(): void
        {
            self::$options = ['offprint_secret' => 'short'];
            $_SERVER['HTTP_X_OFFPRINT_EXPORT'] = 'short';
            $this->assertFalse(Export_Mode::is_active());
            (new ReflectionProperty(Export_Mode::class, 'active'))->setValue(null, null);
            self::$options = [];
            $_SERVER['HTTP_X_OFFPRINT_EXPORT'] = 'anything';
            $this->assertFalse(Export_Mode::is_active());
        }
    }
}
