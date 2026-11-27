<?php
/**
 * The small jobs of a site's pigeonhole keys and of its test submission (a canary), for bin/pigeonhole and the
 * fetch (lib/pigeonhole.sh). Each reads and writes pipes only: a private key made or passed on here is never in a
 * file, an argument or a message, and its public half (which may be shown) leaves by another way, file descriptor 3.
 *
 *   php pigeonhole-keys.php pull-key     makes the ssh key the Mac fetches with (Ed25519). Standard output: the
 *                                        private key, as OpenSSH's own file would hold it, as one line of base64 (what
 *                                        the Keychain keeps: os/darwin/secret takes one printable line). Descriptor
 *                                        3: the public half, as one authorized_keys line would start.
 *   php pigeonhole-keys.php split-age    standard input: what age-keygen prints. Standard output: its private key
 *                                        line, and nothing else. Descriptor 3: the public key.
 *   php pigeonhole-keys.php decode       standard input: the one line pull-key printed. Standard output: the private
 *                                        key as ssh-add reads it. Nothing, and exit 1, for anything else.
 *   php pigeonhole-keys.php public       standard input: the one line pull-key printed. Standard output: that key's
 *                                        public half (an OpenSSH key file holds it unencrypted), and nothing else.
 *   php pigeonhole-keys.php canary       a test submission (kind "canary"), opened, as a page would pad it
 *   php pigeonhole-keys.php prove BITS   standard input: one encrypted submission. Standard output: what a page posts
 *                                        (a proof of work of BITS, then the submission). Descriptor 3: the name the
 *                                        store will keep it under.
 *
 * Why the ssh key is made here: ssh-keygen can only write a private key to a file. This writes OpenSSH's format
 * itself, from a key sodium makes, on a pipe (the real ssh-add takes it: tests/rehearsal.sh).
 */

require_once __DIR__ . '/pigeonhole.php';

const OFFPRINT_PIGEONHOLE_NONCE_BYTES = 8;
/** An encrypted submission's two sizes: to one recipient, and to two (pigeonhole/server/store.js holds the same). */
const OFFPRINT_PIGEONHOLE_CIPHERTEXT_BYTES = [8392, 8490];
const OFFPRINT_PIGEONHOLE_KEY_COMMENT = 'offprint-pigeonhole';

/** A string as ssh writes one: its length in four bytes, then its bytes. */
function offprint_pigeonhole_ssh_string(string $s): string
{
    return pack('N', strlen($s)) . $s;
}

/** The public half of an Ed25519 key (32 bytes), as the start of an authorized_keys line: "ssh-ed25519 BASE64". */
function offprint_pigeonhole_ssh_public(string $public): string
{
    return 'ssh-ed25519 ' . base64_encode(offprint_pigeonhole_ssh_string('ssh-ed25519') . offprint_pigeonhole_ssh_string($public));
}

/**
 * An Ed25519 key as an OpenSSH private key file holds it, with no passphrase. $secret is sodium's 64 bytes (the seed,
 * then the public half), $check any four bytes (the format writes them twice, to tell a wrong passphrase).
 */
function offprint_pigeonhole_ssh_private(string $public, string $secret, string $check): string
{
    if (strlen($public) !== 32 || strlen($secret) !== 64 || strlen($check) !== 4) {
        throw new InvalidArgumentException('not an Ed25519 key');
    }
    $str = 'offprint_pigeonhole_ssh_string';
    $blob = $str('ssh-ed25519') . $str($public);
    $private = $check . $check . $str('ssh-ed25519') . $str($public) . $str($secret) . $str(OFFPRINT_PIGEONHOLE_KEY_COMMENT);
    for ($i = 1; strlen($private) % 8 !== 0; $i++) {
        $private .= chr($i);
    }
    $file = "openssh-key-v1\0" . $str('none') . $str('none') . $str('') . pack('N', 1) . $str($blob) . $str($private);
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n" . chunk_split(base64_encode($file), 70, "\n") . "-----END OPENSSH PRIVATE KEY-----\n";
}

/** How many zero bits a hash starts with. */
function offprint_pigeonhole_zero_bits(string $hash): int
{
    $bits = 0;
    for ($i = 0, $n = strlen($hash); $i < $n; $i++) {
        $byte = ord($hash[$i]);
        if ($byte === 0) {
            $bits += 8;
            continue;
        }
        for ($mask = 0x80; ($byte & $mask) === 0; $mask >>= 1) {
            $bits++;
        }
        break;
    }
    return $bits;
}

/**
 * A proof of work of $bits for $ciphertext, as a page's script finds one (pigeonhole/browser/src/pow.js): eight
 * bytes such that sha256(sha256(ciphertext) || nonce) starts with that many zero bits.
 */
function offprint_pigeonhole_prove(string $ciphertext, int $bits): string
{
    $digest = hash('sha256', $ciphertext, true);
    for ($n = 0; ; $n++) {
        $nonce = pack('J', $n);
        if (offprint_pigeonhole_zero_bits(hash('sha256', $digest . $nonce, true)) >= $bits) {
            return $nonce;
        }
    }
}

/** A test submission, opened, as a page would pad it: it travels the whole path and is dropped when it is opened. */
function offprint_pigeonhole_canary(int $now): string
{
    $line = offprint_pigeonhole_line(['v' => 1, 'kind' => 'canary', 'id' => bin2hex(random_bytes(16)), 'ts' => $now, 'page' => '/', 'fields' => []]);
    return str_pad($line, OFFPRINT_PIGEONHOLE_PLAIN_BYTES, ' ');
}

// ---- as a command (not when a test has loaded this file for its functions) ------------------------------------------
if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    ini_set('display_errors', 'stderr');
    $verb = $argv[1] ?? '';
    // The public half's way out. Opened before anything is made: with nowhere for it to go, nothing is.
    $aside = static function (): mixed {
        $fd = @fopen('php://fd/3', 'w');
        if ($fd === false) {
            fwrite(STDERR, "descriptor 3 isn't open\n");
            exit(2);
        }
        return $fd;
    };
    if ($verb === 'pull-key' && $argc === 2) {
        $fd = $aside();
        $pair = sodium_crypto_sign_keypair();
        $secret = sodium_crypto_sign_secretkey($pair);
        $public = sodium_crypto_sign_publickey($pair);
        $text = offprint_pigeonhole_ssh_private($public, $secret, random_bytes(4));
        $line = base64_encode($text);
        echo $line, "\n";
        fwrite($fd, offprint_pigeonhole_ssh_public($public) . "\n");
        sodium_memzero($secret);
        sodium_memzero($pair);
        sodium_memzero($text);
        sodium_memzero($line);
        exit(0);
    }
    if ($verb === 'split-age' && $argc === 2) {
        $fd = $aside();
        $text = stream_get_contents(STDIN, 4096);
        $text = $text === false ? '' : $text;
        // What age-keygen prints, and nothing looser: a public key in a comment line, then the private one.
        if (preg_match('/^# public key: (age1[ac-hj-np-z02-9]{58})$/m', $text, $pub) !== 1
            || preg_match('/^(AGE-SECRET-KEY-1[A-Z0-9]{58})$/m', $text, $key) !== 1
            || substr_count($text, 'AGE-SECRET-KEY-') !== 1) {
            fwrite(STDERR, "not what age-keygen prints\n");
            exit(1);
        }
        echo $key[1], "\n";
        fwrite($fd, $pub[1] . "\n");
        exit(0);
    }
    if ($verb === 'decode' && $argc === 2) {
        $line = stream_get_contents(STDIN, 2048);
        $text = base64_decode(rtrim($line === false ? '' : $line, "\n"), true);
        if (!is_string($text)
            || preg_match('/\A-----BEGIN OPENSSH PRIVATE KEY-----\n([A-Za-z0-9+\/=]{1,70}\n){1,12}-----END OPENSSH PRIVATE KEY-----\n\z/D', $text) !== 1) {
            exit(1);
        }
        echo $text;
        exit(0);
    }
    if ($verb === 'public' && $argc === 2) {
        $line = stream_get_contents(STDIN, 2048);
        $text = base64_decode(rtrim($line === false ? '' : $line, "\n"), true);
        if (!is_string($text)
            || preg_match('/\A-----BEGIN OPENSSH PRIVATE KEY-----\n((?:[A-Za-z0-9+\/=]{1,70}\n){1,12})-----END OPENSSH PRIVATE KEY-----\n\z/D', $text, $m) !== 1) {
            exit(1);
        }
        $file = base64_decode(str_replace("\n", '', $m[1]), true);
        // the start of the file, as offprint_pigeonhole_ssh_private writes it, up to the public half's 51 bytes
        $head = "openssh-key-v1\0" . offprint_pigeonhole_ssh_string('none') . offprint_pigeonhole_ssh_string('none')
            . offprint_pigeonhole_ssh_string('') . pack('N', 1) . pack('N', 51) . offprint_pigeonhole_ssh_string('ssh-ed25519') . pack('N', 32);
        if (!is_string($file) || strlen($file) < strlen($head) + 32 || substr($file, 0, strlen($head)) !== $head) {
            exit(1);
        }
        echo offprint_pigeonhole_ssh_public(substr($file, strlen($head), 32)), "\n";
        exit(0);
    }
    if ($verb === 'canary' && $argc === 2) {
        echo offprint_pigeonhole_canary(time());
        exit(0);
    }
    if ($verb === 'prove' && $argc === 3 && preg_match('/\A([1-9]|[12][0-9]|3[0-2])\z/D', $argv[2]) === 1) {
        $fd = $aside();
        $ciphertext = stream_get_contents(STDIN, max(OFFPRINT_PIGEONHOLE_CIPHERTEXT_BYTES) + 1);
        if (!is_string($ciphertext) || !in_array(strlen($ciphertext), OFFPRINT_PIGEONHOLE_CIPHERTEXT_BYTES, true)) {
            fwrite(STDERR, "not an encrypted submission's size\n");
            exit(1);
        }
        echo offprint_pigeonhole_prove($ciphertext, (int) $argv[2]), $ciphertext;
        fwrite($fd, hash('sha256', $ciphertext) . ".age\n");
        exit(0);
    }
    fwrite(STDERR, "usage: php pigeonhole-keys.php pull-key | split-age | decode | public | canary | prove BITS\n");
    exit(2);
}
