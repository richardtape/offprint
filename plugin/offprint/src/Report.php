<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

/** What an export did: what it wrote, what will not work statically, and what failed. */
final class Report
{
    public int $files = 0;
    public int $bytes = 0;
    /** @var string[] Things that will not work on the static site. They don't fail the export. */
    public array $warnings = [];
    /** @var string[] Each one fails the export. */
    public array $errors = [];

    public function warning(string $message): void
    {
        $this->warnings[] = self::one_line($message);
    }

    public function error(string $message): void
    {
        $this->errors[] = self::one_line($message);
    }

    public function ok(): bool
    {
        return $this->errors === [];
    }

    public function summary(): string
    {
        return sprintf('Exported %d files, %d bytes.', $this->files, $this->bytes);
    }

    /** Messages name addresses from pages, so a crafted one must not start a line of its own. */
    private static function one_line(string $message): string
    {
        return (string) preg_replace('/[\x00-\x1F\x7F]/', '', $message);
    }
}
