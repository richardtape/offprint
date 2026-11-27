// What a submission is before it is encrypted, and how it is sent after: no page and no encryption in here, so all of
// it runs in a test. The limits are lib/pigeonhole.php's: what this builds, that check accepts, and what a visitor
// typed that it would refuse is said to them here, before anything is sent, not lost after.
import { NONCE_BYTES, proveWork } from "./pow.js";

// Every submission is padded to exactly this many bytes before it is encrypted, so its size says nothing of it.
export const PLAIN_BYTES = 8192;
// In bytes of UTF-8, as lib/pigeonhole.php counts them.
export const LIMITS = { author: 245, email: 100, url: 200, content: 6000, hp: 200 };

const utf8 = (text) => new TextEncoder().encode(text);

// Half of a pair of surrogates (a character cut in two, by a paste or a cut) can't be written down as JSON that
// the Mac's check reads: each becomes the character that stands for one that could not be shown.
const whole = (text) => String(text ?? "").replace(/\p{Cs}/gu, "\u{FFFD}");

// One line of text as lib/pigeonhole.php takes it: no control character, no character that ends a line or turns the
// direction of the text around it (each becomes a space), and no space at either end.
export function oneLine(text) {
  return whole(text).replace(/[\p{Cc}\u{2028}\u{2029}\u{202A}-\u{202E}\u{2066}-\u{2069}]/gu, " ").trim();
}

// A comment's text as lib/pigeonhole.php takes it: line ends and tabs stay, every other control character goes.
export function manyLines(text) {
  return whole(text).replace(/[^\P{Cc}\n\r\t]/gu, "").trim();
}

// The path of the page a comment was sent from, when it is one the check takes (a slash, then anything but a second
// slash or a control character, 500 bytes at most); else the home page's.
export function pagePath(path) {
  const p = String(path ?? "");
  return /^\/(?!\/)[^\p{Cc}]*$/u.test(p) && utf8(p).length <= 500 ? p : "/";
}

// 32 hex digits, from 16 random bytes: a submission's id, by which one fetched twice is known to be one.
export function randomId(random = (bytes) => crypto.getRandomValues(bytes)) {
  return Array.from(random(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
}

// The fields of a comment from what the form holds (VALUES: a name to a string), cleaned, and what is wrong with
// them, if anything: "empty" (no text), or "long:FIELD" (FIELD is over its limit).
export function commentFields(values, elapsedSeconds) {
  const count = (v) => { const n = Number(v); return Number.isSafeInteger(n) && n >= 0 && n <= 2147483647 ? n : 0; };
  const fields = {
    post_id: count(values.comment_post_ID),
    parent: count(values.comment_parent),
    author: oneLine(values.author),
    email: oneLine(values.email),
    url: oneLine(values.url),
    content: manyLines(values.comment),
    hp: oneLine(oneLine(values.offprint_hp).slice(0, 50)),   // (cut, then made whole again: the cut may halve a character)
    elapsed: count(Math.floor(elapsedSeconds)),
  };
  let problem = "";
  if (fields.content === "") problem = "empty";
  for (const name of ["author", "email", "url", "content"]) {
    if (!problem && utf8(fields[name]).length > LIMITS[name]) problem = "long:" + name;
  }
  return { fields, problem };
}

// A submission: its version, its kind, an id, when it was sent (seconds), the page it was sent from, and its fields.
export function envelope(kind, fields, { now = Date.now(), id = randomId(), page = "/" } = {}) {
  return { v: 1, kind, id, ts: Math.floor(now / 1000), page: pagePath(page), fields };
}

// The submission as the bytes that are encrypted: its JSON, padded with spaces to exactly PLAIN_BYTES. Null when it
// is longer than that (a comment full of characters that take two bytes each to write down).
export function padded(submission) {
  const bytes = utf8(JSON.stringify(submission));
  if (bytes.length > PLAIN_BYTES) return null;
  const out = new Uint8Array(PLAIN_BYTES).fill(0x20);
  out.set(bytes);
  return out;
}

// What is posted: the proof of work's nonce, then the ciphertext. (HASH: see proveWork.)
export async function body(ciphertext, bits, hash = null) {
  const out = new Uint8Array(NONCE_BYTES + ciphertext.length);
  out.set(await proveWork(ciphertext, bits, hash), 0);
  out.set(ciphertext, NONCE_BYTES);
  return out;
}

// Posts BYTES to PATH on the page's own origin, and says whether it was taken (the pigeonhole answers 204 and nothing
// else). No content type and no header of its own, no cookie, no referrer: nothing but the bytes.
export async function send(path, bytes, fetcher = fetch) {
  const answer = await fetcher(path, { method: "POST", body: bytes, credentials: "omit", referrerPolicy: "no-referrer", cache: "no-store", redirect: "error" });
  return answer.status === 204;
}
