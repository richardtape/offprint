<?php
declare(strict_types=1);

namespace Offprint;

// Loaded by WordPress, WP-CLI or PHPUnit; never requested on its own.
if (!defined('ABSPATH') && PHP_SAPI !== 'cli') {
    exit;
}

use RuntimeException;

/**
 * The folder an export writes into. It must start empty, and nothing in it is ever overwritten:
 * each file is written once, inside the folder, with its bytes exactly as they came.
 * No WordPress functions: this runs under plain PHPUnit.
 */
final class Output
{
    private string $root;
    /** @var array<string, string> Each file written => what it was written for. */
    private array $owners = [];

    /**
     * @param int $chunk Bytes copied at a time, so a large file is never in memory whole.
     * @throws RuntimeException If $dir is not a folder, is not empty, or cannot be made.
     */
    public function __construct(string $dir, private int $chunk = 1048576)
    {
        if (file_exists($dir) && !is_dir($dir)) {
            throw new RuntimeException("$dir is not a folder.");
        }
        if (is_dir($dir)) {
            $entries = scandir($dir);
            if ($entries === false) {
                throw new RuntimeException("$dir cannot be read.");
            }
            if (array_diff($entries, ['.', '..']) !== []) {
                throw new RuntimeException("$dir is not empty; an export starts from an empty folder.");
            }
        } elseif (!@mkdir($dir, 0777, true) && !is_dir($dir)) {
            throw new RuntimeException("$dir cannot be made.");
        }
        $root = realpath($dir);
        if ($root === false) {
            throw new RuntimeException("$dir cannot be resolved.");
        }
        $this->root = $root;
    }

    /**
     * Copies $body, from where it is to its end, into $file.
     *
     * @param string                $file    A path relative to the folder, as Paths::to_file gives.
     * @param resource              $body
     * @param string                $owner   What the file is for (an address), named if something else wants it.
     * @param array<string, string> $needles Label => text looked for while copying, in any case.
     * @return array{0: int, 1: string[]} The bytes written, and the labels of the needles found
     *                                    (in the order given).
     * @throws RuntimeException If the file cannot be written there. Nothing is overwritten.
     */
    public function write(string $file, $body, string $owner, array $needles): array
    {
        if (isset($this->owners[$file])) {
            throw new RuntimeException("$file is already written for {$this->owners[$file]}.");
        }
        if ($file === '' || $file[0] === '/' || str_contains($file, "\0") || in_array('..', explode('/', $file), true)) {
            throw new RuntimeException("$file would be outside the output folder.");
        }
        $path = $this->root . '/' . $file;
        $parent = dirname($path);
        // Paths already refuses "..", so this guards against a link inside the folder. It looks
        // before making anything, so no folder is ever made outside.
        $nearest = $parent;
        while (!file_exists($nearest) && !is_link($nearest)) {
            $nearest = dirname($nearest);
        }
        if (!$this->inside($nearest)) {
            throw new RuntimeException("$file would be outside the output folder.");
        }
        if (!is_dir($nearest)) {
            throw new RuntimeException("The folder for $file cannot be made: a file is in the way.");
        }
        if (!is_dir($parent) && !@mkdir($parent, 0777, true) && !is_dir($parent)) {
            throw new RuntimeException("The folder for $file cannot be made.");
        }
        if (!$this->inside($parent)) {
            throw new RuntimeException("$file would be outside the output folder.");
        }
        if (is_dir($path)) {
            throw new RuntimeException("$file is a folder already.");
        }
        // "x" fails if the file exists, which also catches two names for one file on a disk
        // that ignores case.
        $out = @fopen($path, 'xb');
        if ($out === false) {
            throw new RuntimeException(file_exists($path) ? "$file already exists." : "$file cannot be written.");
        }
        try {
            $result = $this->copy($body, $out, array_filter($needles, fn (string $n) => $n !== ''));
        } catch (RuntimeException $e) {
            fclose($out);
            unlink($path);
            throw new RuntimeException("$file could not be written in full.", 0, $e);
        }
        fclose($out);
        $this->owners[$file] = $owner;
        return $result;
    }

    /** Whether $path, with any links followed, is the folder or inside it. */
    private function inside(string $path): bool
    {
        $real = realpath($path);
        return $real !== false && ($real === $this->root || str_starts_with($real, $this->root . '/'));
    }

    /**
     * @param resource $from
     * @param resource $to
     * @param array<string, string> $needles
     * @return array{0: int, 1: string[]}
     */
    private function copy($from, $to, array $needles): array
    {
        $bytes = 0;
        $found = [];
        // The end of the last chunk is kept, so a needle split across two chunks is still found.
        $keep = max([0, ...array_map('strlen', $needles)]) - 1;
        $tail = '';
        while (!feof($from)) {
            $chunk = fread($from, $this->chunk);
            if ($chunk === false) {
                throw new RuntimeException('Read failed.');
            }
            if ($chunk === '') {
                break;
            }
            if (fwrite($to, $chunk) !== strlen($chunk)) {
                throw new RuntimeException('Write failed.');
            }
            $bytes += strlen($chunk);
            $window = $tail . $chunk;
            foreach ($needles as $label => $needle) {
                if (!isset($found[$label]) && stripos($window, $needle) !== false) {
                    $found[$label] = true;
                }
            }
            $tail = $keep > 0 ? substr($window, -$keep) : '';
        }
        return [$bytes, array_keys(array_intersect_key($needles, $found))];
    }
}
