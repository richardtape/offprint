<?php
/**
 * Validates a site's site.json and prints it as KEY<TAB>value lines.
 *
 * Usage: php lib/config.php SITE_DIR
 *
 * Exit 0: the ten SITE_* lines on stdout (the keys lib/site.sh reads), then, for a site.json with a
 * "backup" block, SITE_BACKUP_RECIPIENTS and SITE_BACKUP_TO, then, for one with a "pigeonhole" block,
 * SITE_PIGEONHOLE_PATH and SITE_PIGEONHOLE_RECIPIENTS (and, when the block names its server, the seven
 * SITE_PIGEONHOLE_SERVER... , ..._JUMP... and SITE_PIGEONHOLE_STORE_PORT lines), then ADAPTER_NAME and one
 * ADAPTER_SET_<KEY> line per adapter setting, nothing on stderr.
 * Exit 2: nothing on stdout; one line per problem on stderr, each starting `site.json: "<field>"`.
 *
 * site.json is data. This is the only place it is parsed, and every value that leaves here has
 * matched a strict pattern (anchored with \A...\z, so a trailing newline never passes).
 */

ini_set('display_errors', 'stderr');

const MAX_BYTES = 65536;
const MAX_DEPTH = 8;
const HOST = '[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+';
const KNOWN = [
    'format', 'name', 'public_url', 'local_host', 'local_ip4', 'local_ip6',
    'tls_port', 'http_port', 'agent_label', 'daemon_prefix', 'adapter', 'backup', 'pigeonhole',
];
/** The top-level objects whose keys are named with their block ("adapter.name"), here and in every message. */
const BLOCKS = ['adapter', 'backup', 'pigeonhole'];
/** An age X25519 public key: age1 and 58 characters of the encoding's alphabet. Public, so it may be shown. */
const AGE_RECIPIENT = '/\Aage1[ac-hj-np-z02-9]{58}\z/D';
/**
 * A machine's ssh host key, as its public key file has it without the comment: an Ed25519 key, the only kind taken.
 * (The 51 bytes of such a key are always 68 characters, the first 25 the same for every one.)
 */
const SSH_HOST_KEY = '/\Assh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+\/]{43}\z/D';
/** The pigeonhole block's fields, and those of them that say where its server is (all four, or none). */
const PIGEONHOLE_FIELDS = ['path', 'recipients', 'server', 'server_host_key', 'server_port', 'jump', 'jump_host_key', 'jump_port', 'store_port'];
const PIGEONHOLE_SERVER_FIELDS = ['server', 'server_host_key', 'jump', 'jump_host_key'];
const ADAPTER_MAX_SETTINGS = 20;

function fail_usage(): never
{
    fwrite(STDERR, "usage: php config.php SITE_DIR\n");
    exit(2);
}

/** Printable form of an untrusted key for a message: no control characters, bounded length. */
function show(string $s): string
{
    $s = preg_replace('/[^\x20-\x7e]/', '?', $s) ?? '?';
    return strlen($s) > 40 ? substr($s, 0, 40) . '...' : $s;
}

/**
 * Finds a key used twice in one object, at any depth. PHP's json_decode silently keeps the last
 * one. The text has already decoded cleanly, so this only walks it: strings are skipped over
 * (honouring backslashes), and a string that starts where a key may start is decoded, so
 * "name" and "name" count as the same key.
 *
 * @return list<string> the duplicated keys
 */
function duplicate_keys(string $json): array
{
    $dups = [];
    $stack = [];            // one entry per open container: array of seen keys, or null for an array
    $expectKey = false;
    $topKey = null;         // the last key seen directly in the outermost object
    $blockAt = -1;          // stack index of a top-level block (BLOCKS: "adapter", "backup", "pigeonhole"), while inside it
    $block = '';            // and its name
    $len = strlen($json);
    for ($i = 0; $i < $len; $i++) {
        $c = $json[$i];
        if ($c === '"') {
            $j = $i + 1;
            while ($j < $len && $json[$j] !== '"') {
                $j += $json[$j] === '\\' ? 2 : 1;
            }
            if ($expectKey) {
                $key = json_decode(substr($json, $i, $j - $i + 1), false, 512);
                $top = count($stack) - 1;
                if (is_string($key) && $top >= 0 && $stack[$top] !== null) {
                    if (isset($stack[$top][$key])) {
                        // inside a block a key is named with its block, so "name" in the adapter's is not the site's
                        $dups[$top === $blockAt ? $block . '.' . $key : $key] = true;
                    }
                    $stack[$top][$key] = true;
                    if ($top === 0) {
                        $topKey = $key;
                    }
                }
                $expectKey = false;
            }
            $i = $j;
        } elseif ($c === '{') {
            if (count($stack) === 1 && in_array($topKey, BLOCKS, true)) {
                $blockAt = 1;
                $block = $topKey;
            }
            $stack[] = [];
            $expectKey = true;
        } elseif ($c === '[') {
            $stack[] = null;
            $expectKey = false;
        } elseif ($c === '}' || $c === ']') {
            array_pop($stack);
            if (count($stack) <= $blockAt) {
                $blockAt = -1;
            }
            $expectKey = false;
        } elseif ($c === ',') {
            $top = count($stack) - 1;
            $expectKey = $top >= 0 && $stack[$top] !== null;
        }
    }
    return array_map('strval', array_keys($dups));
}

/** Checks a lowercase hostname: pattern, at most 253 characters, labels at most 63. */
function valid_host(string $h): bool
{
    if (strlen($h) > 253 || preg_match('/\A' . HOST . '\z/D', $h) !== 1) {
        return false;
    }
    foreach (explode('.', $h) as $label) {
        if (strlen($label) > 63) {
            return false;
        }
    }
    return true;
}

/**
 * Whether this is one machine's address, written the one way it is written: IPv4 as four numbers with no leading
 * zeros, IPv6 in its canonical form, and never a name (a name is looked up when it is used, and the answer is whoever
 * answers), a zone, a port or a bracket.
 */
function valid_address(mixed $a): bool
{
    if (!is_string($a) || strlen($a) > 45 || preg_match('/\A[0-9a-f:.]+\z/D', $a) !== 1) {
        return false;
    }
    if (filter_var($a, FILTER_VALIDATE_IP) === false) {
        return false;
    }
    $packed = inet_pton($a);
    // (an IPv4 address written inside an IPv6 one is two ways to write one machine: not taken)
    return $packed !== false && inet_ntop($packed) === $a && !str_contains($a, '.') === (strlen($packed) === 16);
}

if ($argc !== 2 || !is_dir($argv[1])) {
    fail_usage();
}
$file = rtrim($argv[1], '/') . '/site.json';
$problems = [];
$die = function (string $msg): never {
    fwrite(STDERR, "site.json: \"(file)\" $msg\n");
    exit(2);
};

if (is_link($file)) {
    $die('is a symlink; refusing to read it.');
}
if (!file_exists($file)) {
    $die("is missing in $argv[1].");
}
if (!is_file($file)) {
    $die('is not a regular file.');
}
$fh = @fopen($file, 'rb');
$text = $fh === false ? false : stream_get_contents($fh, MAX_BYTES + 1);
if ($text === false) {
    $die('could not be read.');
}
if (strlen($text) > MAX_BYTES) {
    $die('is larger than 64 KB (65536 bytes); refusing to read it.');
}
if (strpos($text, "\0") !== false) {
    $die('contains a NUL byte.');
}
try {
    $data = json_decode($text, true, MAX_DEPTH, JSON_THROW_ON_ERROR);
} catch (JsonException $e) {
    $die('is not valid JSON (or nests too deeply): ' . $e->getMessage() . '.');
}
if (ltrim($text, " \t\r\n")[0] !== '{' || !is_array($data)) {
    $die('must be a JSON object.');
}

foreach (duplicate_keys($text) as $k) {
    $problems[] = 'site.json: "' . show($k) . '" appears more than once.';
}
foreach (array_keys($data) as $k) {
    if (!in_array((string) $k, KNOWN, true)) {
        $problems[] = 'site.json: "' . show((string) $k) . '" is not a known field.';
    }
}

$str = function (string $f, string $pattern, string $what, ?string $default = null) use (&$problems, $data): ?string {
    if (!array_key_exists($f, $data)) {
        if ($default === null) {
            $problems[] = "site.json: \"$f\" is required.";
        }
        return $default;
    }
    $v = $data[$f];
    if (!is_string($v) || preg_match($pattern, $v) !== 1) {
        $problems[] = "site.json: \"$f\" must be $what.";
        return null;
    }
    return $v;
};

// format
if (!array_key_exists('format', $data)) {
    $problems[] = 'site.json: "format" is required.';
} elseif (!is_int($data['format']) || $data['format'] < 1) {
    $problems[] = 'site.json: "format" must be the integer 1.';
} elseif ($data['format'] > 1) {
    $problems[] = "site.json: \"format\" is {$data['format']}, newer than this Offprint understands (1); upgrade Offprint.";
}

// name
$name = $str('name', '/\A[a-z][a-z0-9-]{0,30}\z/D', 'lowercase letters, digits and dashes, starting with a letter, at most 31 characters');
if ($name === 'offprint-e2e') {
    $problems[] = 'site.json: "name" must not be offprint-e2e (that is the tests\' own compose project).';
    $name = null;
}

// public_url
$publicHost = null;
$url = $str('public_url', '/\Ahttps:\/\/' . HOST . '\z/D', 'https://hostname, lowercase, with no port, path or trailing slash');
if ($url !== null) {
    $publicHost = substr($url, 8);
    if (!valid_host($publicHost)) {
        $problems[] = 'site.json: "public_url" has a hostname over 253 characters or a label over 63.';
        $publicHost = null;
    }
}

// local_host
$localHost = $str('local_host', '/\A' . HOST . '\z/D', 'a lowercase hostname with at least one dot', 'wp.local');
if ($localHost !== null) {
    if (!valid_host($localHost)) {
        $problems[] = 'site.json: "local_host" has a hostname over 253 characters or a label over 63.';
        $localHost = null;
    } elseif ($localHost === $publicHost) {
        $problems[] = 'site.json: "local_host" must differ from the public host.';
        $localHost = null;
    }
}

// local_ip4
$ip4 = $str('local_ip4', '/\A127\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\z/D', 'a dotted 127.a.b.c address without leading zeros');
if ($ip4 !== null) {
    $bad = false;
    foreach (explode('.', $ip4) as $part) {
        $bad = $bad || (int) $part > 255;
    }
    if ($bad || $ip4 === '127.0.0.1') {
        $problems[] = 'site.json: "local_ip4" must be 127.a.b.c with each part 0-255, and not 127.0.0.1.';
        $ip4 = null;
    }
}

// local_ip6
$ip6 = $str('local_ip6', '/\Afd[0-9a-f]{2}(:[0-9a-f]{1,4}){0,6}::[0-9a-f]{1,4}\z/D', 'an fdXX:... unique-local IPv6 address in lowercase, like fd00::9');
if ($ip6 !== null && filter_var($ip6, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) === false) {
    $problems[] = 'site.json: "local_ip6" is not a valid IPv6 address.';
    $ip6 = null;
} elseif ($ip6 !== null && inet_ntop(inet_pton($ip6)) !== $ip6) {
    $problems[] = 'site.json: "local_ip6" must be written in canonical form; use ' . inet_ntop(inet_pton($ip6)) . " instead of $ip6.";
    $ip6 = null;
}

// ports
$ports = [];
foreach (['tls_port', 'http_port'] as $f) {
    if (!array_key_exists($f, $data)) {
        $problems[] = "site.json: \"$f\" is required.";
    } elseif (!is_int($data[$f]) || $data[$f] < 1024 || $data[$f] > 65535) {
        $problems[] = "site.json: \"$f\" must be a JSON integer from 1024 to 65535.";
    } else {
        $ports[$f] = $data[$f];
    }
}
if (count($ports) === 2 && $ports['tls_port'] === $ports['http_port']) {
    $problems[] = 'site.json: "http_port" must differ from "tls_port".';
}

// labels
$labelPattern = '/\A[A-Za-z0-9][A-Za-z0-9.-]{0,99}\z/D';
$labelWhat = 'letters, digits, dots and dashes, starting with a letter or digit, at most 100 characters';
$label = $str('agent_label', $labelPattern, $labelWhat, $name === null ? '-' : "local.offprint.$name.publish");
$prefix = $str('daemon_prefix', $labelPattern, $labelWhat, $name === null ? '-' : "local.offprint.$name");

// adapter: { "name": NAME, ...settings }; absent means the name "none" and no settings
$adapterName = 'none';
$adapterSettings = [];
if (array_key_exists('adapter', $data)) {
    $raw = json_decode($text, false, MAX_DEPTH);   // objects stay objects, so {} and [] differ
    $a = $data['adapter'];
    if (!is_object($raw->adapter ?? null) || !is_array($a)) {
        $problems[] = 'site.json: "adapter" must be an object with a "name" and optional settings.';
    } else {
        if (!array_key_exists('name', $a)) {
            $problems[] = 'site.json: "adapter.name" is required.';
        } elseif (!is_string($a['name']) || preg_match('/\A[a-z][a-z0-9-]{0,40}\z/D', $a['name']) !== 1) {
            $problems[] = 'site.json: "adapter.name" must be lowercase letters, digits and dashes, starting with a letter, at most 41 characters.';
        } else {
            $adapterName = $a['name'];
        }
        if (count($a) - 1 > ADAPTER_MAX_SETTINGS) {
            $problems[] = 'site.json: "adapter" has more than ' . ADAPTER_MAX_SETTINGS . ' settings.';
        } else {
            foreach ($a as $k => $v) {
                $k = (string) $k;
                if ($k === 'name') {
                    continue;
                }
                $shown = 'adapter.' . show($k);
                if (preg_match('/\A[a-z][a-z0-9_]{0,40}\z/D', $k) !== 1) {
                    $problems[] = "site.json: \"$shown\" is not a valid setting name (lowercase letters, digits and underscores, starting with a letter, at most 41 characters).";
                } elseif (is_int($v) && $v >= 0 && $v <= 2147483647) {
                    $adapterSettings['ADAPTER_SET_' . strtoupper($k)] = (string) $v;
                } elseif (is_string($v) && preg_match('/\A[A-Za-z0-9._:\/@+=-]{1,200}\z/D', $v) === 1) {
                    $adapterSettings['ADAPTER_SET_' . strtoupper($k)] = $v;
                } else {
                    $problems[] = "site.json: \"$shown\" must be a string of 1 to 200 letters, digits and . _ : / @ + = -, or an integer from 0 to 2147483647.";
                }
            }
        }
    }
}

// backup: { "recipients": [one or two age public keys], "to": "repo" }: who the database backup is encrypted to, and
// where it is sent ("repo", the site's own repository, is the only place yet, and what a missing "to" means). Absent
// means no backup lines at all: a publish refuses then, saying how to add one. A value that is not a public key is
// never repeated in the message: it may be the private key, pasted by mistake.
$backupRecipients = null;
$backupTo = 'repo';
if (array_key_exists('backup', $data)) {
    $raw = $raw ?? json_decode($text, false, MAX_DEPTH);   // objects stay objects, so {} and [] differ
    $b = $data['backup'];
    if (!is_object($raw->backup ?? null) || !is_array($b)) {
        $problems[] = 'site.json: "backup" must be an object with "recipients".';
    } else {
        foreach (array_keys($b) as $k) {
            if (!in_array((string) $k, ['recipients', 'to'], true)) {
                $problems[] = 'site.json: "backup.' . show((string) $k) . '" is not a known field.';
            }
        }
        $r = $b['recipients'] ?? null;
        if (!is_array($r) || !is_array($raw->backup->recipients ?? null) || count($r) < 1 || count($r) > 2) {
            $problems[] = 'site.json: "backup.recipients" must be a list of one or two age public keys.';
        } else {
            $keys = [];
            foreach ($r as $v) {
                if (!is_string($v) || preg_match(AGE_RECIPIENT, $v) !== 1) {
                    $keys = null;
                    break;
                }
                $keys[] = $v;
            }
            if ($keys === null) {
                $problems[] = 'site.json: "backup.recipients" must be a list of one or two age public keys (each age1 and 58 more characters).';
            } elseif (count(array_unique($keys)) !== count($keys)) {
                $problems[] = 'site.json: "backup.recipients" names the same key twice.';
            } else {
                $backupRecipients = implode(' ', $keys);
            }
        }
        if (array_key_exists('to', $b) && $b['to'] !== 'repo') {
            $problems[] = 'site.json: "backup.to" must be "repo".';
        }
    }
}

// pigeonhole: { "path": "/NAME", "recipients": [one or two age public keys] }: the one path of the public site that
// comments are posted to, and the keys they are encrypted to in the visitor's browser. Absent means no pigeonhole
// lines, and nothing about comments anywhere. The path is one name, so it can't reach into another folder of the
// site, hold a query or be another origin. As for the backup, a value that is not a public key is never repeated in
// the message; here the keys are also printed into the public pages, so a private one must never pass.
// Where its server is, for the Mac's fetch, is four more fields, all or none: "server" (the store's address on the
// private network) and "server_host_key", "jump" (the web server's own address, through which the store is reached:
// never the site's public name, which may be a proxy's that carries no ssh) and "jump_host_key". Each host key is the
// machine's own ssh key, pinned here: a fetch never learns one. And three optional ports: "server_port" and
// "jump_port" (ssh's, 22 unless given) and "store_port" (the one the store listens on for the web server, 8788).
// Without the four, comments can be collected from the spool but nothing fetches into it.
$pigeonholePath = null;
$pigeonholeRecipients = null;
$pigeonholeServer = null;
if (array_key_exists('pigeonhole', $data)) {
    $raw = $raw ?? json_decode($text, false, MAX_DEPTH);   // objects stay objects, so {} and [] differ
    $p = $data['pigeonhole'];
    if (!is_object($raw->pigeonhole ?? null) || !is_array($p)) {
        $problems[] = 'site.json: "pigeonhole" must be an object with "path" and "recipients".';
    } else {
        foreach (array_keys($p) as $k) {
            if (!in_array((string) $k, PIGEONHOLE_FIELDS, true)) {
                $problems[] = 'site.json: "pigeonhole.' . show((string) $k) . '" is not a known field.';
            }
        }
        if (!array_key_exists('path', $p)) {
            $problems[] = 'site.json: "pigeonhole.path" is required.';
        } elseif (!is_string($p['path']) || preg_match('/\A\/[a-z0-9_-]{1,40}\z/D', $p['path']) !== 1) {
            $problems[] = 'site.json: "pigeonhole.path" must be a slash and one name of 1 to 40 lowercase letters, digits, dashes and underscores, like /_pigeonhole.';
        } else {
            $pigeonholePath = $p['path'];
        }
        $r = $p['recipients'] ?? null;
        if (!is_array($r) || !is_array($raw->pigeonhole->recipients ?? null) || count($r) < 1 || count($r) > 2) {
            $problems[] = 'site.json: "pigeonhole.recipients" must be a list of one or two age public keys.';
        } else {
            $keys = [];
            foreach ($r as $v) {
                if (!is_string($v) || preg_match(AGE_RECIPIENT, $v) !== 1) {
                    $keys = null;
                    break;
                }
                $keys[] = $v;
            }
            if ($keys === null) {
                $problems[] = 'site.json: "pigeonhole.recipients" must be a list of one or two age public keys (each age1 and 58 more characters).';
            } elseif (count(array_unique($keys)) !== count($keys)) {
                $problems[] = 'site.json: "pigeonhole.recipients" names the same key twice.';
            } else {
                $pigeonholeRecipients = implode(' ', $keys);
            }
        }
        $named = array_values(array_filter(PIGEONHOLE_SERVER_FIELDS, static fn (string $f): bool => array_key_exists($f, $p)));
        $phPorts = ['server_port' => 22, 'jump_port' => 22, 'store_port' => 8788];
        $good = true;
        foreach ($phPorts as $f => $default) {
            if (!array_key_exists($f, $p)) {
                continue;
            }
            $least = $f === 'store_port' ? 1024 : 1;
            if (!is_int($p[$f]) || $p[$f] < $least || $p[$f] > 65535) {
                $problems[] = "site.json: \"pigeonhole.$f\" must be a JSON integer from $least to 65535.";
                $good = false;
            } elseif ($named === []) {
                $problems[] = "site.json: \"pigeonhole.$f\" is given, but the block names no server (\"server\", \"server_host_key\", \"jump\" and \"jump_host_key\").";
                $good = false;
            } else {
                $phPorts[$f] = $p[$f];
            }
        }
        if ($named !== []) {
            foreach (PIGEONHOLE_SERVER_FIELDS as $f) {
                if (!array_key_exists($f, $p)) {
                    $problems[] = "site.json: \"pigeonhole.$f\" is required when the block names its server (\"server\", \"server_host_key\", \"jump\" and \"jump_host_key\" go together).";
                    $good = false;
                } elseif (str_ends_with($f, '_host_key')) {
                    // (never repeated: a private key pasted here by mistake must not reach a message)
                    if (!is_string($p[$f]) || preg_match(SSH_HOST_KEY, $p[$f]) !== 1) {
                        $problems[] = "site.json: \"pigeonhole.$f\" must be that machine's Ed25519 host key, as ssh-ed25519, a space and its 68 characters, with nothing after them.";
                        $good = false;
                    }
                } elseif (!valid_address($p[$f])) {
                    $problems[] = "site.json: \"pigeonhole.$f\" must be an address (IPv4 like 10.0.0.5, or IPv6 in its shortest lowercase form), not a name.";
                    $good = false;
                }
            }
            if ($good && $p['server'] === $p['jump'] && $phPorts['server_port'] === $phPorts['jump_port']) {
                $problems[] = 'site.json: "pigeonhole.jump" must be another machine than "pigeonhole.server": the store is reached through the web server.';
                $good = false;
            }
            if ($good) {
                $pigeonholeServer = [
                    'SITE_PIGEONHOLE_SERVER' => $p['server'],
                    'SITE_PIGEONHOLE_SERVER_PORT' => $phPorts['server_port'],
                    'SITE_PIGEONHOLE_SERVER_HOST_KEY' => $p['server_host_key'],
                    'SITE_PIGEONHOLE_JUMP' => $p['jump'],
                    'SITE_PIGEONHOLE_JUMP_PORT' => $phPorts['jump_port'],
                    'SITE_PIGEONHOLE_JUMP_HOST_KEY' => $p['jump_host_key'],
                    'SITE_PIGEONHOLE_STORE_PORT' => $phPorts['store_port'],
                ];
            }
        }
    }
}

if ($problems !== []) {
    fwrite(STDERR, implode("\n", $problems) . "\n");
    exit(2);
}

$out = [
    'SITE_NAME' => $name,
    'SITE_PUBLIC_URL' => $url,
    'SITE_PUBLIC_HOST' => $publicHost,
    'SITE_LOCAL_HOST' => $localHost,
    'SITE_IP4' => $ip4,
    'SITE_IP6' => $ip6,
    'SITE_TLS_PORT' => $ports['tls_port'],
    'SITE_HTTP_PORT' => $ports['http_port'],
    'SITE_AGENT_LABEL' => $label,
    'SITE_DAEMON_PREFIX' => $prefix,
];
foreach ($out as $k => $v) {
    echo $k, "\t", $v, "\n";
}
if ($backupRecipients !== null) {
    echo "SITE_BACKUP_RECIPIENTS\t", $backupRecipients, "\n";
    echo "SITE_BACKUP_TO\t", $backupTo, "\n";
}
if ($pigeonholePath !== null && $pigeonholeRecipients !== null) {
    echo "SITE_PIGEONHOLE_PATH\t", $pigeonholePath, "\n";
    echo "SITE_PIGEONHOLE_RECIPIENTS\t", $pigeonholeRecipients, "\n";
    foreach ($pigeonholeServer ?? [] as $k => $v) {
        echo $k, "\t", $v, "\n";
    }
}
echo "ADAPTER_NAME\t", $adapterName, "\n";
foreach ($adapterSettings as $k => $v) {
    echo $k, "\t", $v, "\n";
}
