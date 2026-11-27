#!/usr/bin/env node
// What the owner's Mac may do to a site's pigeonhole, and all it may do: see the names of what is held, take one, and
// remove one. It is the command the Mac's ssh key is tied to on the store's machine (command="..." in that user's
// authorized_keys, with "restrict": no shell, no forwarding, no terminal), so whatever the Mac's side asks for, sshd
// runs this, and what was asked for arrives as a word in the environment (SSH_ORIGINAL_COMMAND), never as a command
// line for a shell to read:
//   node pull.js STORE            STORE: the folder store.js keeps this site's submissions in
//   SSH_ORIGINAL_COMMAND=list             the names held, one a line, oldest first; at most 500 a time
//   SSH_ORIGINAL_COMMAND="get NAME"       that file's bytes, on standard output
//   SSH_ORIGINAL_COMMAND="delete NAME"    that file removed (one that is gone already is no error: the Mac removes a
//                                         file only once it holds it, and may be cut off before it hears the answer)
// NAME is 64 hex digits and ".age" (the sha256 of the file's bytes, as store.js names it) and nothing else: no path,
// no other file of the folder, nothing outside it. A name that is a link, a folder or larger than a submission can be
// is not listed, given or removed. Anything else asked for is refused (exit 2), with one fixed word of why.
//
// A stolen key gets what this gives: ciphertext, which only the owner's own key opens, and the removal of submissions
// not yet fetched. It gets no shell on this machine, and nothing else in it.
//
// Exit 0: done. 2: not one of the three, or no such folder. 3: get, and there is no such file (or it is not a
// submission's). 4: it could not be read or removed. It has no dependencies but node itself, and writes nothing down.
'use strict';

const nodeFs = require('node:fs');
const path = require('node:path');

const NAME = /^[0-9a-f]{64}\.age$/;
const MAX_BYTES = 16384;   // no submission is larger: store.js keeps two sizes, both under 9 KB
const MAX_LISTED = 500;

// pull(DIR, ASKED, OUT, ERR, fs): does what ASKED asks of the folder DIR; returns the exit status. OUT and ERR take
// what is written (a Buffer or a string).
function pull(dir, asked, out, err, fs = nodeFs) {
  const no = (status, why) => { err(why + '\n'); return status; };
  if (typeof dir !== 'string' || !path.isAbsolute(dir)) return no(2, 'no store');
  if (typeof asked !== 'string' || asked.length > 80) return no(2, 'refused');
  // One of three shapes, exactly: no second space, no line end, nothing before or after.
  const m = /^(list|get ([0-9a-f]{64}\.age)|delete ([0-9a-f]{64}\.age))$/.exec(asked);
  if (!m) return no(2, 'refused');

  // A submission's file, and nothing else: a plain file (never a link to one), no larger than one can be.
  const held = (name) => {
    let stat;
    try { stat = fs.lstatSync(path.join(dir, name)); } catch { return null; }
    return stat.isFile() && stat.size <= MAX_BYTES ? stat : null;
  };

  if (asked === 'list') {
    let names;
    try { names = fs.readdirSync(dir); } catch { return no(2, 'no store'); }
    const found = [];
    for (const name of names) {
      if (!NAME.test(name)) continue;
      const stat = held(name);
      if (stat) found.push([stat.mtimeMs, name]);
    }
    found.sort((a, b) => a[0] - b[0] || (a[1] < b[1] ? -1 : 1));
    out(found.slice(0, MAX_LISTED).map((f) => f[1] + '\n').join(''));
    return 0;
  }

  const name = m[2] || m[3];
  const file = path.join(dir, name);
  if (m[2]) {
    if (!held(name)) return no(3, 'gone');
    let fd = null;
    try {
      // (O_NOFOLLOW: a link put in the file's place since the look above is not followed)
      fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      const stat = fs.fstatSync(fd);
      if (!stat.isFile() || stat.size > MAX_BYTES) return no(3, 'gone');
      const bytes = Buffer.alloc(stat.size);
      let got = 0;
      while (got < bytes.length) {
        const n = fs.readSync(fd, bytes, got, bytes.length - got, got);
        if (!(n > 0)) return no(4, 'failed');
        got += n;
      }
      out(bytes);
      return 0;
    } catch (e) {
      return e && e.code === 'ENOENT' ? no(3, 'gone') : no(4, 'failed');
    } finally {
      if (fd !== null) { try { fs.closeSync(fd); } catch { /* closed already */ } }
    }
  }

  // delete: only a submission's own file; what is gone already was removed, which is what was asked.
  let stat;
  try { stat = fs.lstatSync(file); } catch (e) { return e && e.code === 'ENOENT' ? 0 : no(4, 'failed'); }
  if (!stat.isFile()) return no(4, 'failed');
  try { fs.unlinkSync(file); } catch (e) { return e && e.code === 'ENOENT' ? 0 : no(4, 'failed'); }
  return 0;
}

function main() {
  const chunks = [];
  const status = pull(process.argv.length === 3 ? process.argv[2] : null, process.env.SSH_ORIGINAL_COMMAND,
    (bytes) => chunks.push(Buffer.from(bytes)), (text) => process.stderr.write(text));
  // Written whole, and the status given only once it has gone: a get cut short must never look like a whole one.
  const all = Buffer.concat(chunks);
  if (!all.length) { process.exitCode = status; return; }
  process.stdout.write(all, () => { process.exitCode = status; });
  process.stdout.on('error', () => { process.exitCode = 4; });
}

if (require.main === module) main();
module.exports = { pull, MAX_BYTES, MAX_LISTED };
