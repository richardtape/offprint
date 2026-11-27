#!/usr/bin/env node
// A site's pigeonhole: the store of comments a site's visitors sent, each encrypted in the visitor's browser to keys
// only the site's owner holds. It runs on a machine of the owner's that nothing on the internet can reach: the site's
// web server forwards one path to it, over a private network, and the owner's Mac fetches what it holds and deletes
// it. One site, one of these (its own user, port and folder), so one site's flood or key never touches another's.
//
// It does one thing. It takes a POST to one path, checks it, and keeps the ciphertext in a file named after its hash.
// It cannot list, serve or change what it holds: there is no route for any of that. It never starts a connection.
// It has no dependencies but node itself.
//
// What it checks, in this order, and what it answers (a bare status, never a word):
//   404  any path but the one it takes;  405  any method but POST there
//   411  no length given;  413  a length that is not exactly one a submission has. Every submission is padded to one
//        size before it is encrypted, so there are two lengths (one recipient, or two) and nothing else is read.
//   400  the web server did not say whose it is (see below)
//   429  too many from this sender in the last hour, or too many from everyone, or too many from this sender being
//        read at this moment
//   400  it does not start as an age file does
//   403  its proof of work is not one: sha256(sha256(ciphertext) || nonce) must start with BITS zero bits
//        (pigeonhole/browser/src/pow.js). The proof binds a nonce to these bytes and to nothing else, so it can be
//        made in advance and sent again: what stops a flood is the limits here and the quota, not the proof.
//   507  the store is full
//   500  it could not be kept (the disk, say); nothing of it is left behind, and it counts against its sender
//   204  kept, or held already (the same bytes sent again are one file: its name is their hash).
//
// Whose it is: the web server names the visitor's address in one header, and must (a request without one is not the
// web server's own forwarding, and is refused). It is used for the limits and nothing else, held in memory only,
// never written down, and forgotten within the hour. A sender is one IPv4 address, or one /64 of IPv6 (a visitor
// with IPv6 has the whole /64, so each of its addresses is the same sender). The same bytes sent again count against
// their sender, and not against everyone: one proof of work can't be spent 300 times to shut everyone else out.
// All it ever knows of a submission is its size, when it came, and that address.
//
// It says, on standard output, how many it kept and how many it refused and why, every few minutes when there is
// anything to say: never a body, an address, or a file's name.
//
// What it does not stop, and the web server must: someone who sends a body a byte at a time holds one of its places
// until the time allowed for a request is up. It allows little time, reads only so many at once from one sender, and
// keeps no more than a submission's size for each; the web server should hand it a request only once it has the
// whole of it.
//
// Settings, from the environment (the unit file sets them):
//   PIGEONHOLE_STORE        the folder it keeps submissions in (its own, mode 700)
//   PIGEONHOLE_LISTEN       the address and port it listens on, ADDRESS:PORT: the private network's own address,
//                           never every address of the machine
//   PIGEONHOLE_PATH         the one path it takes: a slash and one name (site.json's pigeonhole.path)
// and, each with its default:
//   PIGEONHOLE_BITS (18)  PIGEONHOLE_PER_ADDRESS (10 an hour)  PIGEONHOLE_PER_HOUR (300, from everyone)
//   PIGEONHOLE_QUOTA (5000 submissions held)  PIGEONHOLE_DAYS (30: older ones are removed)
//   PIGEONHOLE_CLIENT_HEADER (x-pigeonhole-client)
'use strict';

const http = require('node:http');
const nodeFs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const crypto = require('node:crypto');

const NONCE_BYTES = 8;
// A submission is 8192 bytes before it is encrypted. Encrypted with age, to one recipient or to two:
const CIPHERTEXT_BYTES = [8392, 8490];
const AGE_HEADER = Buffer.from('age-encryption.org/v1\n-> X25519 ');
const NAME = /^[0-9a-f]{64}\.age$/;
const INCOMING = /^\.incoming-/;
const HOUR = 3600 * 1000;

function zeroBits(hash) {
  let bits = 0;
  for (const byte of hash) {
    if (byte === 0) { bits += 8; continue; }
    return bits + Math.clz32(byte) - 24;
  }
  return bits;
}
const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest();

// Whether NONCE is a proof of BITS for CIPHERTEXT.
function workOk(ciphertext, nonce, bits) {
  return nonce.length === NONCE_BYTES && zeroBits(sha256(Buffer.concat([sha256(ciphertext), nonce]))) >= bits;
}

// The sender an address stands for: the address itself for IPv4 (and for IPv4 written as IPv6, ::ffff:a.b.c.d), the
// first 64 bits for IPv6, written one way whatever way it came. Null when it is no address.
function sender(text) {
  if (typeof text !== 'string' || text.length > 45) return null;
  if (net.isIPv4(text)) return text;
  if (!net.isIPv6(text) || text.includes('%')) return null;   // (no zone: that is one machine's own word for a link)
  let head = text.toLowerCase();
  let tail = [];
  const dotted = /^(.*:)(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(head);
  if (dotted) {
    // the last 32 bits written as IPv4: two groups of four hex digits
    head = dotted[1] + ((Number(dotted[2]) << 8) | Number(dotted[3])).toString(16) + ':' + ((Number(dotted[4]) << 8) | Number(dotted[5])).toString(16);
  }
  const halves = head.split('::');
  const left = halves[0] === '' ? [] : halves[0].split(':');
  if (halves.length === 2) tail = halves[1] === '' ? [] : halves[1].split(':');
  const groups = halves.length === 2 ? [...left, ...Array(8 - left.length - tail.length).fill('0'), ...tail] : left;
  if (groups.length !== 8) return null;
  const n = groups.map((g) => parseInt(g, 16));
  if (n.some((g) => !Number.isInteger(g) || g < 0 || g > 0xffff)) return null;
  if (n.slice(0, 5).every((g) => g === 0) && n[5] === 0xffff) return `${n[6] >> 8}.${n[6] & 255}.${n[7] >> 8}.${n[7] & 255}`;
  return n.slice(0, 4).map((g) => g.toString(16)).join(':') + '::/64';
}

// How many of the times in LIST are within the last hour; the older ones are dropped from it.
function recent(list, now) {
  while (list.length && list[0] <= now - HOUR) list.shift();
  return list.length;
}

// The store, as an http server not yet listening. OPTIONS: dir, path, and the limits (see the top); now (a clock) and
// fs (the file system), which the tests replace, and say (where its counts go).
function createStore(options) {
  const o = {
    bits: 18, perAddress: 10, perHour: 300, quota: 5000, days: 30, clientHeader: 'x-pigeonhole-client',
    // how many requests of one sender's are read at once; how long a request may take (its headers, all of it), and how
    // often that is looked at (milliseconds). A real post is under 9 KB and arrives at once.
    atOnce: 4, headersWithin: 3000, allWithin: 4000, lookEvery: 1000,
    now: () => Date.now(), fs: nodeFs, say: (line) => process.stdout.write(line + '\n'), ...options,
  };
  const fs = o.fs;
  if (typeof o.dir !== 'string' || !path.isAbsolute(o.dir)) throw new Error('the store folder must be a whole path');
  if (typeof o.path !== 'string' || !/^\/[a-z0-9_-]{1,40}$/.test(o.path)) throw new Error('the path must be a slash and one name');
  for (const name of ['bits', 'perAddress', 'perHour', 'quota', 'days', 'atOnce']) {
    if (!Number.isSafeInteger(o[name]) || o[name] < 1) throw new Error(`${name} must be a whole number above 0`);
  }
  if (o.bits > 32) throw new Error('bits must be 32 at most');
  if (typeof o.clientHeader !== 'string' || !/^[a-z0-9-]{1,60}$/.test(o.clientHeader)) throw new Error('the client header must be a header\'s name, in small letters');
  fs.mkdirSync(o.dir, { recursive: true, mode: 0o700 });
  fs.chmodSync(o.dir, 0o700);
  // What a run that was stopped mid-write left half-written: never a submission, and removed before this one starts.
  for (const name of fs.readdirSync(o.dir)) {
    if (INCOMING.test(name)) { try { fs.unlinkSync(path.join(o.dir, name)); } catch { /* left: it is counted as nothing */ } }
  }

  const started = o.now();
  const everyone = [];               // when each submission of the last hour was kept
  const senders = new Map();         // sender => when each of its turns of the last hour was taken
  const reading = new Map();         // sender => how many of its requests are being read now
  const counts = {};                 // what happened since it last said: kept, again, and each refusal by its reason
  const count = (what) => { counts[what] = (counts[what] || 0) + 1; };
  let held = 0;                      // how many files the store holds, as of the last look
  let looked = -Infinity;

  // A sender that took no turn this hour is forgotten.
  function forget(now) {
    for (const [who, list] of senders) if (recent(list, now) === 0) senders.delete(who);
  }

  // A look at the folder, every ten seconds at most: how many it holds (the owner's fetch removes them, from
  // outside), and those older than DAYS removed. A file that is not a submission's is left, and not counted.
  function look(now) {
    if (now >= looked && now - looked < 10000) return;   // (a clock set back looks again at once)
    looked = now;
    let n = 0;
    for (const name of fs.readdirSync(o.dir)) {
      if (!NAME.test(name)) continue;
      const file = path.join(o.dir, name);
      let stat;
      try { stat = fs.lstatSync(file); } catch { continue; }
      if (!stat.isFile()) continue;
      // Nothing is removed for its age in this run's first ten minutes: a machine that starts with its clock wrong
      // (far ahead, before it has asked the time) must not take everything held for old.
      if (now - started >= 600000 && stat.mtimeMs <= now - o.days * 24 * HOUR) {
        try { fs.unlinkSync(file); count('expired'); } catch { n++; }
        continue;
      }
      n++;
    }
    held = n;
    forget(now);
  }

  // Keeps CIPHERTEXT under the name its bytes give it. False when it is held already. Written whole under another
  // name first, every byte of it, then given its own with a link, which fails when the name is taken: so a file is
  // never half there, and one that is there is never written over. Whatever happens, the other name is removed.
  function keep(ciphertext) {
    const name = sha256(ciphertext).toString('hex') + '.age';
    const final = path.join(o.dir, name);
    const temp = path.join(o.dir, `.incoming-${process.pid}-${crypto.randomBytes(8).toString('hex')}`);
    let fd = null;
    try {
      fd = fs.openSync(temp, 'wx', 0o600);
      let written = 0;
      while (written < ciphertext.length) {
        const n = fs.writeSync(fd, ciphertext, written, ciphertext.length - written);
        if (!(n > 0)) throw Object.assign(new Error('a short write'), { code: 'ESHORT' });
        written += n;
      }
      fs.fsyncSync(fd);
      fs.closeSync(fd);
      fd = null;
      try {
        fs.linkSync(temp, final);
      } catch (e) {
        if (e.code !== 'EEXIST') throw e;
        // Held already, if what holds the name is a whole submission of this size; anything else there (a link, a
        // folder, a file cut short) is not this submission, and saying "kept" would lose it.
        const there = fs.lstatSync(final);
        if (there.isFile() && there.size === ciphertext.length) return false;
        throw Object.assign(new Error('the name is taken by something else'), { code: 'ETAKEN' });
      }
      // the folder's own record of the new name, on disk, before the answer says kept
      try { const dir = fs.openSync(o.dir, 'r'); try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); } } catch { /* not every file system lets a folder be synced */ }
      return true;
    } finally {
      if (fd !== null) { try { fs.closeSync(fd); } catch { /* closed already */ } }
      try { fs.unlinkSync(temp); } catch { /* never made, or gone */ }
    }
  }

  // No request may hold a place for long. (node looks for ones that have only every so often, and by itself only every
  // half minute: so it is told how often, here, where the server is made.)
  const server = http.createServer({ headersTimeout: o.headersWithin, requestTimeout: o.allWithin, connectionsCheckingInterval: o.lookEvery, keepAliveTimeout: 1 }, (req, res) => {
    let who = null;        // the sender, once known, while its request is being read
    let answered = false;
    const done = () => {
      if (who === null) return;
      const n = (reading.get(who) || 1) - 1;
      if (n > 0) reading.set(who, n); else reading.delete(who);
      who = null;
    };
    // A bare status and nothing else: no body, no header that says what this is.
    const answer = (status, what) => {
      if (answered) return;
      answered = true;
      done();
      count(what);
      res.writeHead(status, { 'Content-Length': '0', Connection: 'close' });
      // what it did not read, it does not wait for: once the answer has gone, the connection goes
      res.end(() => { if (!req.complete) req.destroy(); });
    };
    req.on('error', () => {});
    res.on('error', () => {});
    req.on('close', done);   // a request that went away before its end gives its place back
    try {
      const now = o.now();
      if (req.url !== o.path) return answer(404, 'elsewhere');
      if (req.method !== 'POST') return answer(405, 'method');
      const declared = req.headers['content-length'];
      if (declared === undefined || req.headers['transfer-encoding'] !== undefined) return answer(411, 'no length');
      if (!/^[0-9]{1,6}$/.test(declared) || !CIPHERTEXT_BYTES.includes(Number(declared) - NONCE_BYTES)) return answer(413, 'size');
      const length = Number(declared);

      const from = sender(req.headers[o.clientHeader]);
      if (from === null) return answer(400, 'no address');
      look(now);
      const own = senders.get(from);
      if (own && recent(own, now) >= o.perAddress) return answer(429, 'address');
      if (recent(everyone, now) >= o.perHour) return answer(429, 'everyone');
      if ((reading.get(from) || 0) >= o.atOnce) return answer(429, 'at once');
      who = from;
      reading.set(from, (reading.get(from) || 0) + 1);
      // A turn taken by this sender: against its own hour, and (when something new was kept, or tried) everyone's.
      const turn = (at, everyoneToo) => {
        let list = senders.get(from);
        if (!list) { list = []; senders.set(from, list); }
        list.push(at);
        if (everyoneToo) everyone.push(at);
      };

      // Exactly a submission's size is kept of it, however it arrives.
      const body = Buffer.alloc(length);
      let got = 0;
      req.on('data', (chunk) => {
        if (got + chunk.length > length) { req.destroy(); return; }
        chunk.copy(body, got);
        got += chunk.length;
      });
      req.on('end', () => {
        if (answered) return;
        try {
          if (got !== length) return answer(400, 'cut short');
          const nonce = body.subarray(0, NONCE_BYTES);
          const ciphertext = body.subarray(NONCE_BYTES);
          if (!ciphertext.subarray(0, AGE_HEADER.length).equals(AGE_HEADER)) return answer(400, 'not age');
          if (!workOk(ciphertext, nonce, o.bits)) return answer(403, 'work');
          // again, now that the body is in: others may have been kept while it came
          const at = o.now();
          const mine = senders.get(from);
          if (mine && recent(mine, at) >= o.perAddress) return answer(429, 'address');
          if (recent(everyone, at) >= o.perHour) return answer(429, 'everyone');
          if (held >= o.quota) return answer(507, 'full');
          let fresh;
          try {
            fresh = keep(ciphertext);
          } catch (e) {
            // It could not be kept. That is a turn all the same, against the sender and against everyone: a disk
            // that is full must not be a way to try without end. Why is said by its code alone, never a path.
            turn(at, true);
            return answer(500, 'failed' + (e && typeof e.code === 'string' && /^[A-Z0-9_]{1,20}$/.test(e.code) ? ' ' + e.code : ''));
          }
          if (fresh) held++;
          // The same bytes again: a turn of the sender's, but not of everyone's (nothing new was kept, and one proof
          // of work sent from many addresses must not use up the hour for all).
          turn(at, fresh);
          return answer(204, fresh ? 'kept' : 'again');
        } catch {
          return answer(500, 'failed');
        }
      });
    } catch {
      return answer(500, 'failed');
    }
  });
  // A request that asks for something first (Expect: with anything but 100-continue) gets a bare answer too, not node's.
  server.on('checkExpectation', (req, res) => { count('expects'); res.writeHead(417, { 'Content-Length': '0', Connection: 'close' }); res.end(() => req.destroy()); });
  server.maxHeadersCount = 100;
  server.maxConnections = 200;

  // Senders are forgotten within the hour even when nobody else comes: looked at every ten minutes.
  const forgetting = setInterval(() => forget(o.now()), 600000);
  forgetting.unref();
  server.on('close', () => clearInterval(forgetting));

  // What happened since it last said, in one line; nothing when nothing did.
  server.report = () => {
    const names = Object.keys(counts).sort();
    if (!names.length) return;
    o.say('pigeonhole: ' + names.map((name) => `${name} ${counts[name]}`).join(', '));
    for (const name of names) delete counts[name];
  };
  server.held = () => held;
  server.forget = () => forget(o.now());
  server.remembered = () => senders.size;
  return server;
}

function main() {
  const env = process.env;
  const stop = (message) => { console.error('pigeonhole: ' + message); process.exit(2); };
  const number = (name, fallback) => (env[name] === undefined || env[name] === '' ? fallback : /^[0-9]{1,9}$/.test(env[name]) ? Number(env[name]) : NaN);
  const listen = /^(\[[0-9a-fA-F:.]+\]|[0-9.]+):([0-9]{1,5})$/.exec(env.PIGEONHOLE_LISTEN || '');
  const host = listen ? listen[1].replace(/^\[|\]$/g, '') : '';
  const port = listen ? Number(listen[2]) : 0;
  if (!listen || !net.isIP(host) || port < 1 || port > 65535) stop('PIGEONHOLE_LISTEN must be an address and a port, ADDRESS:PORT (an IPv6 address in square brackets)');
  // Every address of the machine would include its public one, if it has one: the private network's own is named.
  if (/^(0\.0\.0\.0|[0:]+)$/.test(host)) stop('PIGEONHOLE_LISTEN must name the private network\'s own address, not every address of the machine');
  let server;
  try {
    server = createStore({
      dir: env.PIGEONHOLE_STORE, path: env.PIGEONHOLE_PATH,
      bits: number('PIGEONHOLE_BITS', 18), perAddress: number('PIGEONHOLE_PER_ADDRESS', 10), perHour: number('PIGEONHOLE_PER_HOUR', 300),
      quota: number('PIGEONHOLE_QUOTA', 5000), days: number('PIGEONHOLE_DAYS', 30),
      clientHeader: (env.PIGEONHOLE_CLIENT_HEADER || 'x-pigeonhole-client').toLowerCase(),
    });
  } catch (e) {
    stop(e.message + ' (PIGEONHOLE_STORE, PIGEONHOLE_PATH and the limits: see the top of this file)');
  }
  process.stdout.on('error', () => {});   // a log that went away must not end the store
  server.on('error', (e) => { console.error('pigeonhole: ' + (e.code || 'it could not listen')); process.exit(1); });
  server.listen(port, host, () => {
    console.log(`pigeonhole: taking ${env.PIGEONHOLE_PATH} on ${env.PIGEONHOLE_LISTEN}`);
  });
  setInterval(server.report, 5 * 60 * 1000).unref();
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { server.report(); server.close(() => process.exit(0)); server.closeAllConnections(); });
}

if (require.main === module) main();
module.exports = { createStore, workOk, zeroBits, sender, NONCE_BYTES, CIPHERTEXT_BYTES };
