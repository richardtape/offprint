// The proof of work a submission carries: an 8-byte nonce such that sha256(sha256(ciphertext) || nonce) starts with
// BITS zero bits. It is bound to the ciphertext, so one proof buys one submission, and whoever checks it needs no
// state and no second route. It costs a visitor a fraction of a second, once, and a flood a great deal.
export const NONCE_BYTES = 8;

const sha256 = async (bytes) => new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));

// How many zero bits a hash starts with.
export function zeroBits(hash) {
  let bits = 0;
  for (const byte of hash) {
    if (byte === 0) { bits += 8; continue; }
    return bits + Math.clz32(byte) - 24;
  }
  return bits;
}

// Whether NONCE is a proof of BITS for CIPHERTEXT.
export async function workOk(ciphertext, nonce, bits) {
  if (nonce.length !== NONCE_BYTES) return false;
  const input = new Uint8Array(32 + NONCE_BYTES);
  input.set(await sha256(ciphertext), 0);
  input.set(nonce, 32);
  return zeroBits(await sha256(input)) >= bits;
}

// A nonce that is a proof of BITS for CIPHERTEXT: the first found, counting up. HASH, when given, is a SHA-256 that
// answers at once (bytes in, bytes out): the browser's own answers through a promise, and a quarter of a million
// promises take seconds where the hashing takes a fraction of one. With it, the page is given a moment to breathe
// every so many tries, so it never seems stuck.
export async function proveWork(ciphertext, bits, hash = null) {
  const input = new Uint8Array(32 + NONCE_BYTES);
  input.set(await sha256(ciphertext), 0);
  const view = new DataView(input.buffer);
  for (let n = 0; ; n++) {
    view.setUint32(32, Math.floor(n / 2 ** 32));
    view.setUint32(36, n >>> 0);
    if (hash) {
      if (zeroBits(hash(input)) >= bits) return input.slice(32);
      if (n % 20000 === 19999) await new Promise((go) => setTimeout(go));
    } else if (zeroBits(await sha256(input)) >= bits) return input.slice(32);
  }
}
