<?php
declare(strict_types=1);

use PHPUnit\Framework\TestCase;
use Offprint\Report;

final class ReportTest extends TestCase
{
    public function test_summary_and_ok(): void
    {
        $report = new Report();
        $report->files = 3;
        $report->bytes = 1024;
        $report->warnings[] = 'a warning';
        $this->assertSame('Exported 3 files, 1024 bytes.', $report->summary());
        $this->assertTrue($report->ok());
        $report->errors[] = 'an error';
        $this->assertFalse($report->ok());
    }

    public function test_a_crafted_address_cannot_forge_a_line(): void
    {
        $report = new Report();
        $report->warning("https://x/a\nError: forged\r\x1b[31m\x7f/ links to it");
        $report->error("https://x/\0b\tc/ answered 404");
        $this->assertSame(['https://x/aError: forged[31m/ links to it'], $report->warnings);
        $this->assertSame(['https://x/bc/ answered 404'], $report->errors);
        $this->assertFalse($report->ok());
    }
}
