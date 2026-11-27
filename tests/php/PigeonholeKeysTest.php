<?php
declare(strict_types=1);

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

require_once __DIR__ . '/../../lib/pigeonhole-keys.php';

/**
 * lib/pigeonhole-keys.php: the ssh key the Mac fetches with (made here, written in OpenSSH's own format, on a pipe),
 * the split of what age-keygen prints, and a test submission with its proof of work. As functions, and as the
 * commands bin/pigeonhole runs: a private key leaves on standard output only, its public half on descriptor 3.
 * (That the real ssh-add takes the key is tests/rehearsal.sh's to show.)
 */
final class PigeonholeKeysTest extends TestCase
{
    private const SCRIPT = __DIR__ . '/../../lib/pigeonhole-keys.php';

    /** Runs the command: [exit status, standard output, descriptor 3, standard error]. */
    private static function command(array $args, string $stdin = '', bool $three = true): array
    {
        $spec = [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
        if ($three) {
            $spec[3] = ['pipe', 'w'];
        }
        $p = proc_open(array_merge([PHP_BINARY, self::SCRIPT], $args), $spec, $pipes);
        fwrite($pipes[0], $stdin);
        fclose($pipes[0]);
        $out = stream_get_contents($pipes[1]);
        $aside = $three ? stream_get_contents($pipes[3]) : '';
        $err = stream_get_contents($pipes[2]);
        return [proc_close($p), $out, $aside, $err];
    }

    /** One length-prefixed string off the front of $bytes. */
    private static function take(string &$bytes): string
    {
        $n = unpack('N', substr($bytes, 0, 4))[1];
        $s = substr($bytes, 4, $n);
        $bytes = substr($bytes, 4 + $n);
        return $s;
    }

    public function test_the_public_half_is_written_as_ssh_writes_one(): void
    {
        $line = offprint_pigeonhole_ssh_public(str_repeat("\x07", 32));
        $this->assertMatchesRegularExpression('/\Assh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+\/]{43}\z/D', $line);
        $blob = base64_decode(substr($line, 12), true);
        $this->assertSame('ssh-ed25519', self::take($blob));
        $this->assertSame(str_repeat("\x07", 32), self::take($blob));
        $this->assertSame('', $blob);
    }

    public function test_the_private_key_file_is_openssh_format_with_no_passphrase(): void
    {
        $pair = sodium_crypto_sign_seed_keypair(str_repeat("\x01", 32));
        $public = sodium_crypto_sign_publickey($pair);
        $secret = sodium_crypto_sign_secretkey($pair);
        $text = offprint_pigeonhole_ssh_private($public, $secret, 'abcd');
        $this->assertMatchesRegularExpression('/\A-----BEGIN OPENSSH PRIVATE KEY-----\n([A-Za-z0-9+\/=]{1,70}\n)+-----END OPENSSH PRIVATE KEY-----\n\z/D', $text);
        $lines = explode("\n", trim($text));
        $file = base64_decode(implode('', array_slice($lines, 1, -1)), true);
        $this->assertSame("openssh-key-v1\0", substr($file, 0, 15));
        $file = substr($file, 15);
        $this->assertSame('none', self::take($file));   // cipher
        $this->assertSame('none', self::take($file));   // kdf
        $this->assertSame('', self::take($file));       // kdf options
        $this->assertSame(1, unpack('N', $file)[1]);    // one key
        $file = substr($file, 4);
        $blob = self::take($file);
        $this->assertSame(base64_decode(substr(offprint_pigeonhole_ssh_public($public), 12)), $blob);
        $private = self::take($file);
        $this->assertSame('', $file);
        $this->assertSame(0, strlen($private) % 8);
        $this->assertSame('abcdabcd', substr($private, 0, 8));
        $private = substr($private, 8);
        $this->assertSame('ssh-ed25519', self::take($private));
        $this->assertSame($public, self::take($private));
        $this->assertSame($secret, self::take($private));
        $this->assertSame('offprint-pigeonhole', self::take($private));
        $this->assertSame(substr("\x01\x02\x03\x04\x05\x06\x07", 0, strlen($private)), $private);
    }

    public function test_a_key_of_the_wrong_size_is_refused(): void
    {
        $this->expectException(InvalidArgumentException::class);
        offprint_pigeonhole_ssh_private(str_repeat('a', 32), str_repeat('b', 32), 'abcd');
    }

    public static function zero_bit_cases(): array
    {
        return [["\xff", 0], ["\x80\x00", 0], ["\x7f", 1], ["\x01", 7], ["\x00\x80", 8], ["\x00\x00\x3f", 18], ["\x00\x00", 16], ['', 0]];
    }

    #[DataProvider('zero_bit_cases')]
    public function test_zero_bits_are_counted_from_the_front(string $hash, int $bits): void
    {
        $this->assertSame($bits, offprint_pigeonhole_zero_bits($hash));
    }

    public function test_a_proof_of_work_is_one_the_store_takes(): void
    {
        $ciphertext = random_bytes(8392);
        $nonce = offprint_pigeonhole_prove($ciphertext, 12);
        $this->assertSame(8, strlen($nonce));
        // as pigeonhole/server/store.js checks it
        $hash = hash('sha256', hash('sha256', $ciphertext, true) . $nonce, true);
        $this->assertSame("\x00", $hash[0]);
        $this->assertSame(0, ord($hash[1]) & 0xf0);
        $this->assertNotSame($nonce, offprint_pigeonhole_prove(random_bytes(8392), 12) . 'x');
    }

    public function test_a_canary_is_a_submission_the_check_passes_as_a_canary(): void
    {
        $now = 1795000000;
        $plain = offprint_pigeonhole_canary($now);
        $this->assertSame(8192, strlen($plain));
        $r = offprint_pigeonhole_check($plain, $now + 30);
        $this->assertTrue($r['ok']);
        $this->assertSame('canary', $r['kind']);
        $this->assertStringStartsWith('{"v":1,"kind":"canary",', $r['json']);
        $this->assertNotSame($plain, offprint_pigeonhole_canary($now));
    }

    public function test_pull_key_prints_one_line_the_keychain_can_hold_and_the_public_half_aside(): void
    {
        [$code, $out, $aside, $err] = self::command(['pull-key']);
        $this->assertSame(0, $code);
        $this->assertSame('', $err);
        $this->assertMatchesRegularExpression('/\A[A-Za-z0-9+\/=]{100,1024}\n\z/D', $out);
        $this->assertMatchesRegularExpression('/\Assh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+\/]{43}\n\z/D', $aside);
        $text = base64_decode(trim($out), true);
        $this->assertStringStartsWith("-----BEGIN OPENSSH PRIVATE KEY-----\n", $text);
        // nothing of the private key goes the public half's way
        $this->assertStringNotContainsString('PRIVATE', $aside);
        // a new key every time
        $this->assertNotSame($out, self::command(['pull-key'])[1]);
        // and decode gives ssh-add the file itself, whose public half is the one printed aside
        [$code, $file, , $err] = self::command(['decode'], $out);
        $this->assertSame([0, $text, ''], [$code, $file, $err]);
        $lines = explode("\n", trim($file));
        $this->assertStringContainsString(base64_decode(substr(trim($aside), 12)), base64_decode(implode('', array_slice($lines, 1, -1))));
        // public: the stored line's public half again, and nothing of the private one
        [$code, $again, , $err] = self::command(['public'], $out, false);
        $this->assertSame([0, $aside, ''], [$code, $again, $err]);
    }

    public static function not_a_stored_key(): array
    {
        $good = base64_encode("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n");
        return [
            'nothing' => [''],
            'not base64' => ["!!!!\n"],
            'base64 of something else' => [base64_encode("hello\n") . "\n"],
            'an RSA key' => [base64_encode("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n") . "\n"],
            'a key with words after it' => [base64_encode("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\nmore\n") . "\n"],
            'two lines' => [$good . "\n" . $good . "\n"],
            'the key itself, not its line' => ["-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"],
        ];
    }

    #[DataProvider('not_a_stored_key')]
    public function test_decode_gives_nothing_for_anything_but_a_stored_key(string $stdin): void
    {
        [$code, $out, , $err] = self::command(['decode'], $stdin, false);
        $this->assertSame([1, '', ''], [$code, $out, $err]);
    }

    #[DataProvider('not_a_stored_key')]
    public function test_public_gives_nothing_for_anything_but_a_stored_key(string $stdin): void
    {
        [$code, $out, , $err] = self::command(['public'], $stdin, false);
        $this->assertSame([1, '', ''], [$code, $out, $err]);
    }

    public function test_split_age_sends_the_private_line_one_way_and_the_public_key_the_other(): void
    {
        $public = 'age1' . str_repeat('q', 58);
        $private = 'AGE-SECRET-KEY-1' . str_repeat('Q', 58);
        [$code, $out, $aside, $err] = self::command(['split-age'], "# created: 2026-11-27T10:00:00Z\n# public key: $public\n$private\n");
        $this->assertSame([0, "$private\n", "$public\n", ''], [$code, $out, $aside, $err]);
    }

    public static function not_age_keygen(): array
    {
        $public = 'age1' . str_repeat('q', 58);
        $private = 'AGE-SECRET-KEY-1' . str_repeat('Q', 58);
        return [
            'nothing' => [''],
            'no public line' => ["$private\n"],
            'no private line' => ["# public key: $public\n"],
            'two private keys' => ["# public key: $public\n$private\n$private\n"],
            'a short private key' => ["# public key: $public\nAGE-SECRET-KEY-1QQQ\n"],
            'a private key where the public one goes' => ["# public key: $private\n$private\n"],
        ];
    }

    #[DataProvider('not_age_keygen')]
    public function test_split_age_refuses_what_age_keygen_does_not_print(string $stdin): void
    {
        [$code, $out, $aside, $err] = self::command(['split-age'], $stdin);
        $this->assertSame([1, '', ''], [$code, $out, $aside]);
        $this->assertStringNotContainsString('AGE-SECRET-KEY', $err);
    }

    public function test_prove_prints_what_a_page_posts_and_the_name_it_will_be_kept_under(): void
    {
        $ciphertext = random_bytes(8490);
        [$code, $out, $aside, $err] = self::command(['prove', '10'], $ciphertext);
        $this->assertSame([0, ''], [$code, $err]);
        $this->assertSame(8498, strlen($out));
        $this->assertSame($ciphertext, substr($out, 8));
        $this->assertSame(hash('sha256', $ciphertext) . ".age\n", $aside);
        $this->assertGreaterThanOrEqual(10, offprint_pigeonhole_zero_bits(hash('sha256', hash('sha256', $ciphertext, true) . substr($out, 0, 8), true)));
    }

    public function test_prove_refuses_what_is_not_a_submissions_size_and_a_bad_number_of_bits(): void
    {
        $this->assertSame([1, ''], array_slice(self::command(['prove', '10'], random_bytes(8391)), 0, 2));
        $this->assertSame([1, ''], array_slice(self::command(['prove', '10'], random_bytes(8491)), 0, 2));
        $this->assertSame([1, ''], array_slice(self::command(['prove', '10'], ''), 0, 2));
        foreach (['0', '33', '-1', 'x', '18 '] as $bits) {
            $this->assertSame(2, self::command(['prove', $bits], random_bytes(8392))[0], $bits);
        }
        $this->assertSame(2, self::command(['nonsense'])[0]);
        $this->assertSame(2, self::command([])[0]);
    }
}
