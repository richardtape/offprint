<?php
/**
 * A submission to a site's pigeonhole (a comment a visitor's browser encrypted), once it has been opened on the Mac:
 * checked, and sorted. Both happen here, outside the WordPress container, before WordPress is handed anything.
 *
 * Usage: php lib/pigeonhole.php check    the opened submission on stdin. Exit 0: the submission as one line of JSON on
 *                                        stdout. Exit 1: nothing on stdout, and why on stderr, in one line.
 *        php lib/pigeonhole.php sort     a checked submission (check's line) on stdin. Exit 0: "hold", or "spam", a
 *                                        tab and why, on stdout. Exit 2: it was not a checked submission.
 *
 * What is opened is whatever a stranger sent, so nothing in it is trusted: it must be exactly the size a submission
 * has, one JSON object with exactly the keys of its kind, each of its type and within its length, with no control
 * character, sent neither long ago nor in the future (a comment is dated from it), and no longer written out than it
 * was sent (so that what reads the line next, with the same limit, never meets one it can't take). A reason is one of the fixed
 * texts below and never repeats anything that was sent: reasons go to a terminal and to a file beside the kept
 * submission. No WordPress function is used, so this is unit-tested (tests/php/PigeonholeTest.php).
 */

declare(strict_types=1);

/** The size of every opened submission: the browser pads its JSON with spaces to exactly this many bytes. */
const OFFPRINT_PIGEONHOLE_PLAIN_BYTES = 8192;
/** A submission older than this is refused: its sender has long stopped waiting, and its date would mislead. */
const OFFPRINT_PIGEONHOLE_MAX_AGE = 30 * 86400;
/** How far ahead of this Mac's clock a sender's may be. A comment is dated from it, so it must not be post-dated. */
const OFFPRINT_PIGEONHOLE_MAX_AHEAD = 300;
/** Under this many seconds between the form being touched and its sending, the sorter says spam. */
const OFFPRINT_PIGEONHOLE_MIN_SECONDS = 3;
const OFFPRINT_PIGEONHOLE_MAX_INT = 2147483647;

/**
 * The opened bytes of one submission, checked.
 *
 * @return array{ok:true,kind:string,json:string}|array{ok:false,why:string}
 */
function offprint_pigeonhole_check(string $plain, int $now): array
{
    $no = fn (string $why): array => ['ok' => false, 'why' => $why];
    if (strlen($plain) !== OFFPRINT_PIGEONHOLE_PLAIN_BYTES) {
        return $no('it is not the size a submission has');
    }
    $text = rtrim($plain, ' ');
    try {
        // depth 4: the object, its fields, and one level more, so that a field that is a list is refused as that field
        $d = json_decode($text, true, 4, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
        $raw = json_decode($text, false, 4, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
    } catch (JsonException) {
        return $no('it is not JSON');
    }
    if (!is_array($d) || !is_object($raw)) {
        return $no('it is not a JSON object');
    }
    // PHP keeps the last of a key given twice. What is checked here must be what any other reader would read.
    if (offprint_pigeonhole_has_duplicate_key($text)) {
        return $no('it names a key twice');
    }
    $keys = ['v', 'kind', 'id', 'ts', 'page', 'fields'];
    if (array_diff(array_map('strval', array_keys($d)), $keys) !== []) {
        return $no('it has a key a submission does not have');
    }
    if (array_diff($keys, array_map('strval', array_keys($d))) !== []) {
        return $no('it lacks a key a submission has');
    }
    if ($d['v'] !== 1) {
        return $no('its version is not 1');
    }
    if ($d['kind'] !== 'comment' && $d['kind'] !== 'canary') {
        return $no('its kind is not one this Offprint knows');
    }
    if (!is_string($d['id']) || preg_match('/\A[0-9a-f]{32}\z/D', $d['id']) !== 1) {
        return $no('its id is not 32 hex digits');
    }
    if (!is_int($d['ts'])) {
        return $no('its time is not a whole number');
    }
    if ($d['ts'] < $now - OFFPRINT_PIGEONHOLE_MAX_AGE) {
        return $no('it was sent more than 30 days ago');
    }
    if ($d['ts'] > $now + OFFPRINT_PIGEONHOLE_MAX_AHEAD) {
        return $no('its time is in the future');
    }
    // one slash, then anything printable: a path of the site's own, never another origin (//host) or a whole address
    if (!is_string($d['page']) || strlen($d['page']) > 500 || preg_match('/\A\/(?!\/)[^\p{Cc}]*\z/Du', $d['page']) !== 1) {
        return $no('its page is not a path on the site');
    }
    if (!is_object($raw->fields ?? null) || !is_array($d['fields'])) {
        return $no('its fields are not an object');
    }
    $f = $d['fields'];
    if ($d['kind'] === 'canary') {
        if ($f !== []) {
            return $no('it has a field a canary does not have');
        }
        return offprint_pigeonhole_passed($d);
    }
    $names = ['post_id', 'parent', 'author', 'email', 'url', 'content', 'hp', 'elapsed'];
    if (array_diff(array_map('strval', array_keys($f)), $names) !== []) {
        return $no('it has a field a comment does not have');
    }
    if (array_diff($names, array_map('strval', array_keys($f))) !== []) {
        return $no('it lacks a field a comment has');
    }
    if (!is_int($f['post_id']) || $f['post_id'] < 1 || $f['post_id'] > OFFPRINT_PIGEONHOLE_MAX_INT) {
        return $no('its post is not a whole number above 0');
    }
    if (!is_int($f['parent']) || $f['parent'] < 0 || $f['parent'] > OFFPRINT_PIGEONHOLE_MAX_INT) {
        return $no('its parent is not a whole number');
    }
    // one line each: name, bytes at most (WordPress's own columns and limits are no larger). No control character,
    // and none of the characters that end a line or turn the direction of the text around it (a name that reads as
    // another in an admin screen).
    foreach ([['author', 'name', 245], ['email', 'email address', 100], ['url', 'web address', 200], ['hp', 'hidden field', 200]] as [$key, $what, $max]) {
        if (!is_string($f[$key])) {
            return $no("its $what is not text");
        }
        if (strlen($f[$key]) > $max) {
            return $no("its $what is too long");
        }
        if (preg_match('/[\p{Cc}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u', $f[$key]) !== 0) {
            return $no("its $what has a control character");
        }
    }
    if (!is_string($f['content'])) {
        return $no('its text is not text');
    }
    if (strlen($f['content']) > 6000) {
        return $no('its text is too long');
    }
    if (preg_match('/[^\P{Cc}\n\r\t]/u', $f['content']) !== 0) {
        return $no('its text has a control character');
    }
    if (trim($f['content']) === '') {
        return $no('its text is empty');
    }
    if (!is_int($f['elapsed']) || $f['elapsed'] < 0 || $f['elapsed'] > OFFPRINT_PIGEONHOLE_MAX_INT) {
        return $no('its time taken is not a whole number');
    }
    return offprint_pigeonhole_passed($d);
}

/**
 * A submission that passed every check, as check's answer; unless its one line would be longer than what was sent.
 * The sorter and the import read a line with the same limit as this reads a submission, so a line that outgrew it
 * would pass here and fail there, every time: one such file would then stop every collection after it.
 *
 * @return array{ok:true,kind:string,json:string}|array{ok:false,why:string}
 */
function offprint_pigeonhole_passed(array $d): array
{
    $json = offprint_pigeonhole_line($d);
    if (strlen($json) > OFFPRINT_PIGEONHOLE_PLAIN_BYTES) {
        return ['ok' => false, 'why' => 'it is longer written out than a submission may be'];
    }
    return ['ok' => true, 'kind' => $d['kind'], 'json' => $json];
}

/** A checked submission as one line of JSON: no line end inside it (JSON escapes them), nothing after it. */
function offprint_pigeonhole_line(array $d): string
{
    // The keys in one order, whatever order they were sent in: what reads the line can tell its kind from its start.
    $fields = [];
    foreach (['post_id', 'parent', 'author', 'email', 'url', 'content', 'hp', 'elapsed'] as $key) {
        if (array_key_exists($key, $d['fields'])) {
            $fields[$key] = $d['fields'][$key];
        }
    }
    $out = ['v' => $d['v'], 'kind' => $d['kind'], 'id' => $d['id'], 'ts' => $d['ts'], 'page' => $d['page'], 'fields' => $fields === [] ? new stdClass() : $fields];
    // (LINE_TERMINATORS: without it U+2028 and U+2029 are written as six bytes each for the three they were sent as.)
    return json_encode($out, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_LINE_TERMINATORS | JSON_THROW_ON_ERROR);
}

/**
 * Whether any object in this JSON text (which has already decoded cleanly) names a key twice. Strings are skipped
 * over, honouring backslashes; a string where a key may start is decoded, so "a" and "a" are the same key.
 */
function offprint_pigeonhole_has_duplicate_key(string $json): bool
{
    $stack = [];            // one entry per open container: the keys seen, or null for a list
    $expectKey = false;
    $len = strlen($json);
    for ($i = 0; $i < $len; $i++) {
        $c = $json[$i];
        if ($c === '"') {
            $j = $i + 1;
            while ($j < $len && $json[$j] !== '"') {
                $j += $json[$j] === '\\' ? 2 : 1;
            }
            $top = count($stack) - 1;
            if ($expectKey && $top >= 0 && $stack[$top] !== null) {
                $key = json_decode(substr($json, $i, $j - $i + 1));
                if (is_string($key)) {
                    if (isset($stack[$top]['k' . $key])) {
                        return true;
                    }
                    $stack[$top]['k' . $key] = true;
                }
                $expectKey = false;
            }
            $i = $j;
        } elseif ($c === '{') {
            $stack[] = [];
            $expectKey = true;
        } elseif ($c === '[') {
            $stack[] = null;
            $expectKey = false;
        } elseif ($c === '}' || $c === ']') {
            array_pop($stack);
            $expectKey = false;
        } elseif ($c === ',') {
            $top = count($stack) - 1;
            $expectKey = $top >= 0 && $stack[$top] !== null;
        }
    }
    return false;
}

/**
 * Sorts a checked submission: held for the owner, or straight to WordPress's spam list. Either way the owner sees it;
 * nothing is dropped here, and nothing is sent anywhere to decide. One contract (a checked submission in; "hold" or
 * "spam", and why, out), so another sorter can take this one's place.
 *
 * @return array{0:'hold'|'spam',1:string}
 */
function offprint_pigeonhole_sort(array $d): array
{
    if (($d['kind'] ?? '') !== 'comment') {
        return ['hold', ''];
    }
    $f = $d['fields'];
    // A field no person sees or fills in: only a program that fills in every field does.
    if ($f['hp'] !== '') {
        return ['spam', 'the hidden field was filled in'];
    }
    // The seconds between the form first being touched and its sending: a person takes longer to write anything.
    if ($f['elapsed'] < OFFPRINT_PIGEONHOLE_MIN_SECONDS) {
        return ['spam', 'it was sent within ' . OFFPRINT_PIGEONHOLE_MIN_SECONDS . ' seconds of the form being touched'];
    }
    return ['hold', ''];
}

// ---- as a command (not when a test has loaded this file for its functions) ------------------------------------------
if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    ini_set('display_errors', 'stderr');
    $verb = $argc === 2 ? $argv[1] : '';
    if ($verb === 'check') {
        // one byte more than a submission, and no more: its size is decided before any of it is looked at
        $plain = stream_get_contents(STDIN, OFFPRINT_PIGEONHOLE_PLAIN_BYTES + 1);
        $r = offprint_pigeonhole_check($plain === false ? '' : $plain, time());
        if (!$r['ok']) {
            fwrite(STDERR, $r['why'] . "\n");
            exit(1);
        }
        echo $r['json'], "\n";
        exit(0);
    }
    if ($verb === 'sort') {
        $line = stream_get_contents(STDIN, OFFPRINT_PIGEONHOLE_PLAIN_BYTES + 1);
        $line = $line === false ? '' : rtrim($line, "\n");
        // what check printed, checked again as it was: nothing else is sorted
        $r = offprint_pigeonhole_check(str_pad($line, OFFPRINT_PIGEONHOLE_PLAIN_BYTES, ' '), time());
        if (!$r['ok'] || $r['json'] !== $line) {
            fwrite(STDERR, "not a checked submission\n");
            exit(2);
        }
        [$verdict, $why] = offprint_pigeonhole_sort(json_decode($line, true));
        echo $verdict, $why === '' ? '' : "\t$why", "\n";
        exit(0);
    }
    fwrite(STDERR, "usage: php pigeonhole.php check | sort\n");
    exit(2);
}
