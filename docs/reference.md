# Reference

Everything about Offprint in detail: `site.json`, the database backup and restoring it, every command, the hosts, the
one privileged step, sitemap plugins and the tests. New here? Start with [getting-started.md](getting-started.md).

Run `offprint` from inside a site folder, or set `OFFPRINT_SITE` to it. A site folder holds `site.json`, `site/` (the
static copy), `wp-content/`, `backup/` (the database dump, encrypted), `var/` (status, log, export and inbox; not
committed) and `local/certs/` (the local TLS certificate; not committed).

## site.json

`site.json` is data. `lib/config.php` is the only code that parses it. It must be a JSON object of at most 64 KB, not a
symlink, with no repeated key and no key that is not in the table. Every problem is reported at once, one line each,
starting `site.json: "<field>"`.

| Field | Required | Rule | Default |
| --- | --- | --- | --- |
| `format` | yes | The integer 1. A higher number is refused as newer than this Offprint. | none |
| `name` | yes | Lowercase letters, digits and dashes, starting with a letter, at most 31 characters. Not `offprint-e2e`. It is the Docker compose project name. | none |
| `public_url` | yes | `https://` and a lowercase hostname: no port, path or trailing slash. | none |
| `local_host` | no | A lowercase hostname with at least one dot, different from the public host. | `wp.local` |
| `local_ip4` | yes | `127.a.b.c`, each part 0-255, no leading zeros, not `127.0.0.1`. | none |
| `local_ip6` | yes | A unique-local `fdXX:...` address with `::` before its last group, lowercase, in canonical form, like `fd00::9`. | none |
| `tls_port` | yes | A JSON integer, 1024 to 65535. | none |
| `http_port` | yes | A JSON integer, 1024 to 65535, different from `tls_port`. | none |
| `agent_label` | no | Letters, digits, dots and dashes, starting with a letter or digit, at most 100 characters. | `local.offprint.NAME.publish` |
| `daemon_prefix` | no | The same rule as `agent_label`. | `local.offprint.NAME` |
| `backup` | no, but a publish refuses without it | Who the database backup is encrypted to: an object, `{"recipients": ["age1…"]}`, with one or two age public keys (each `age1` and 58 more characters), not the same one twice. Its only other key is `"to"`, where the backup is sent: `"repo"` (the site's own repository) is the one place there is. | none |
| `pigeonhole` | no | Comments (see [Comments](#comments-pigeonhole-what-is-built)): an object, `{"path": "/_pigeonhole", "recipients": ["age1…"]}`. `path` is a slash and one name of 1 to 40 lowercase letters, digits, dashes and underscores; `recipients` is one or two age public keys, not the same one twice. Where its server is, for the fetch, is four more members, all or none: `server` (the store's address on the private network) and `server_host_key`, `jump` (the web server's own address, never the site's public name) and `jump_host_key`. An address is IPv4, or IPv6 in its shortest lowercase form, never a name; a host key is that machine's Ed25519 ssh host key, as `ssh-ed25519`, a space and its 68 characters. Optional with them: `server_port` and `jump_port` (ssh's, 22) and `store_port` (the store's own, 8788; 1024 or above). | none |
| `adapter` | no | The site's host adapter: an object, `{"name": "NAME", ...}`. NAME is lowercase letters, digits and dashes, starting with a letter, at most 41 characters: an adapter in the tool's `adapters/`, or else in the site folder's own `adapters/`, committed. Its other keys are the adapter's settings, at most 20, each named with lowercase letters, digits and underscores, starting with a letter, at most 41 characters, and each a string of 1 to 200 letters, digits and `. _ : / @ + = -`, or an integer from 0 to 2147483647; the adapter checks them itself. | `{"name": "none"}` |

A hostname is at most 253 characters, each label at most 63. An example:

```json
{
  "format": 1,
  "name": "example",
  "public_url": "https://www.example.com",
  "local_host": "mysite.local",
  "local_ip4": "127.0.0.9",
  "local_ip6": "fd00::9",
  "tls_port": 4999,
  "http_port": 4998,
  "backup": {"recipients": ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"]}
}
```

## The database backup

Every publish dumps the site's database and commits it, so the site's repository is a backup of the whole WordPress:
posts, drafts, settings and comments are nowhere else but on your Mac. The dump holds drafts, password hashes and
email addresses, so it is committed only encrypted, as `backup/db.sql.age`, with [age](https://age-encryption.org) to
the public keys in `site.json`. A publish needs no secret for this, and Offprint never stores the private key: the
backup is for the day the Mac is lost, and a key kept only on that Mac would be lost with it.

To set it up:

1. `brew install age`.
2. Run `age-keygen`. It prints a private key (a line starting `AGE-SECRET-KEY-`) and its public key (`age1…`). Save
   the private key in your password manager. Do not keep it in a file in the site folder, and do not commit it.
3. Add the public key to `site.json`, and commit it:

   ```json
   "backup": {"recipients": ["age1…"]}
   ```

   A second public key in the list is a spare: the backup then opens with either private key. Whoever loses every
   private key has lost the backup; nothing can open it then.
4. After a publish, `offprint backup verify` asks for the private key (it is not shown as you paste it, and is not
   stored), and says whether the backup in the last commit opens with it and is a whole dump. Run it once now, and
   again whenever you change the keys: it is how you find out a backup is no use before the day you need it.

A publish refuses, before exporting anything, when `site.json` has no `backup` block or there is no `age` on the PATH.
When the database has not changed since the last publish, and nor have the recipients, the committed backup is kept
as it is (age's output differs every time, so encrypting again would make a commit of every publish).

**A site made before the backup was encrypted** must be given a `backup` block before its next publish. That publish
takes the readable `backup/db.sql` out of the commit and the folder, and warns once that earlier commits still hold
it: a publish never rewrites history, so whether to remove it from the repository's past is yours to decide.

**Restoring.** In the site folder, with its WordPress running, `offprint backup restore` replaces the local
WordPress's whole database with the backup in the last commit. Its users and passwords become the backup's.

1. It asks you to type the site's name (`--yes` skips the question), then for the private key, which is not shown.
2. It reads the backup through once, and goes no further unless it opens with your key and is a whole dump.
3. The database as it is now is dumped and kept, encrypted to the keys in `site.json`, as a new file in
   `var/before-restore/`. If that can't be done, nothing is replaced.
4. The database is replaced, and WordPress's own address is set to the site's local one.

It ends with one `ok:` line, or one `problem:` line saying what to do. If the import itself fails, the database is
left empty, and the line gives the exact command that puts the last one back:
`offprint backup restore --from var/before-restore/DATE-TIME.sql.age`. Each restore keeps a new copy, and never
writes over or removes an earlier one: delete old ones yourself when you no longer want them. (An empty database is
not kept.) A restore never runs beside a publish; one that is killed outright can leave `var/publish.lock` behind,
and a publish takes a lock over once it is 30 minutes old and its process is gone. If the
site's publish agent is installed, a publish that WordPress asks for runs straight after one, on the restored
database, and the command says so.

On a new Mac: clone the site's repository, run `offprint host-setup` and `offprint setup-wp` (which makes an empty
WordPress), then `offprint backup restore`. To restore an earlier commit's backup, write it to a file outside the site
folder first (`git show COMMIT:backup/db.sql.age > FILE`) and name it with `--from FILE`.

## Bringing an existing WordPress's database into a site

`offprint backup restore --from FILE` takes a dump file in place of the site's own backup: a readable `.sql` dump, or
an age file encrypted to your key. That is how the database of a WordPress that lived somewhere else comes into a new
Offprint site:

1. Make the site as in [Getting started](getting-started.md), up to `offprint setup-wp`, and give it its backup key.
2. Export the other WordPress's database to a file (`mariadb-dump`, `mysqldump`, `wp db export`, or its host's export),
   and keep that file outside the site folder's `wp-content/` and `var/`.
3. `offprint backup restore --from FILE`. A dump must end as `mariadb-dump`'s and `mysqldump`'s do
   (`-- Dump completed`); for a whole export from a tool that ends another way, add `--unchecked`.
4. It sets WordPress's own address to the site's local one, and when the dump came from another address it says so
   and prints the command that changes the addresses inside posts:
   `offprint wp search-replace 'OLD' 'https://LOCAL' --skip-columns=guid`. It does not run it: look first.
5. Copy the other WordPress's uploads, themes and plugins into `wp-content/` yourself; a restore replaces the
   database only. A dump whose tables have another prefix than `wp_` is imported but can't be read; the command
   says so, with the way back.

`wp-content/` (uploads, themes, plugins) is committed as it is, not encrypted.

## Commands

`offprint help` prints this list:

```
usage: offprint COMMAND [ARGS...]
  offprint new NAME [--public-url URL]       make a new site folder, NAME, here: its site.json (with addresses and
                                             ports no other site set up on this Mac uses) and .gitignore, committed
  offprint publish [--dry-run] [--no-push]   export the site, check it, commit it with a backup, push it, and have
                                             its host adapter make it live
  offprint agent                             what launchd runs when WordPress asks for a publish
  offprint wp ARGS...                        WP-CLI in the site's WordPress (offprint wp option get home)
  offprint compose ARGS...                   docker compose for the site (offprint compose up -d)
  offprint setup-wp                          make the site's local WordPress
  offprint install-agent [--force] [--remove | --print]
                                             the launchd agent that publishes when WordPress asks (yours, not root's)
  offprint host-setup [--print] [--adopt]    give the site its addresses, name and ports 443/80 on this Mac (as root:
                                             it prints the sudo line to run; --print shows every change, as you;
                                             --adopt: the same site, moved to a new folder, takes its set-up over)
  offprint host-undo [--print]               take this site's host set-up away again, and nothing else
  offprint check DIR                         run the export checks on DIR, as a publish runs them (the site's hosts,
                                             and its adapter's file names and limits)
  offprint backup verify                     check that the committed database backup opens with your key (asks
                                             for the key; it is never stored) and is a whole dump
  offprint backup restore [--from FILE] [--unchecked] [--yes]
                                             replace the local database with the committed backup's (or a dump
                                             file's), keeping an encrypted copy of the one it replaces
  offprint collect [--no-fetch | --fetch-only [--notify]]
                                             fetch what the site's pigeonhole holds, and take it into WordPress,
                                             held for moderation (--fetch-only: fetch, and open nothing; needs a
                                             pigeonhole block in site.json)
  offprint pigeonhole keys                   make the site's two comment keys in the login Keychain (the daily key
                                             and the pull key), and print their public halves
  offprint pigeonhole print-server web | store WEB_ADDRESS
                                             print what you do on the web server, or the script you run on the
                                             store's machine (Offprint runs neither)
  offprint pigeonhole doctor                 check the whole path a comment travels, with a test submission: one ok
                                             or problem line each (exit 0 only when all are ok)
  offprint adapter setup [--yes]             set up on this Mac what the site's host adapter needs (each step says
                                             what it will do, and asks first; --yes: yes to each)
  offprint adapter doctor                    check what the site's host adapter needs, and the live site: one ok or
                                             problem line each, changing nothing (exit 0 only when all are ok)
  offprint help                              this list
```

### `new`: what it picks

`offprint new NAME` asks for one thing, the public address (`--public-url URL` answers it without a prompt): the
address the site will be served at. Every link in the published copy points there, so settle it first: WordPress takes
it when its container is made (`setup-wp`). To publish to Cloudflare Workers, that is the Worker's address: its
`workers.dev` address, say, `https://my-site.SUBDOMAIN.workers.dev`, with your account's `workers.dev` subdomain,
which Cloudflare's dashboard shows.

The name is the site's Docker compose project name, so it is refused when Docker has a project of that name, or a
volume called `NAME_db` or `NAME_wordpress` (when Docker can't be asked, it says so and goes on: `setup-wp` asks again
before it starts anything).

It picks the rest so that no site whose host set-up is done has them: `local_host` is `NAME.local` (refused when
`/etc/hosts` names it already); `local_ip4` is `127.0.0.N`, the lowest N from 2 that is neither on `lo0` nor in
`/etc/hosts` and whose two ports nothing listens on; `local_ip6` is `fdXX:XXXX:XXXX::N`, a unique-local prefix of 40
random bits made for this site, and the same N; and the ports are `4000 + 100 × N + 43` (`tls_port`) and `+ 80`
(`http_port`). It reads no other site's folder: a site made with `new` whose `host-setup` hasn't run yet is not on
`lo0`, in `/etc/hosts` or listening, so the next `new` can pick the same values. Run `host-setup` for each site before
you make the next. When `lo0`, `/etc/hosts` or the ports can't be read, it says so and goes on. `host-setup` checks
every value again and refuses a clash; then change `local_ip4`, the last group of `local_ip6` and the two ports in
`site.json` by hand (to another N's, say), and run it again. Without a git identity (`git config user.name` and
`user.email`) the two files are left uncommitted, and it says the two commands that commit them. It ends by saying
what it wrote and what is left:

```
$ offprint new mysite --public-url https://www.example.com
Made mysite: a git repository on main, holding site.json and .gitignore, committed as "A new site".
In its site.json:
  name        mysite
  public_url  https://www.example.com
  local_host  mysite.local
  local_ip4   127.0.0.2
  local_ip6   fd12:3456:789a::2
  tls_port    4243
  http_port   4280
Next, in this order:
  cd mysite
  offprint host-setup          (prints the sudo line to run)
  offprint setup-wp
  offprint publish --dry-run
Before the first publish (a dry run too), give the site a backup key:
  age-keygen                 # prints a private key (AGE-SECRET-KEY-…) and its public key (age1…)
  # keep the private key in your password manager, not on this Mac alone
  # then add to site.json:  "backup": {"recipients": ["age1…"]}
Run offprint host-setup for this site before making another: until then its address and ports are not yet taken on this Mac.
To publish to a host, add an adapter block to site.json: see the README.
```

### `new`: what it refuses

`new` runs outside every site folder, and makes nothing outside the folder it runs in. It refuses, in one line and
before anything is made (exit 2): a name `site.json` would refuse, `offprint-e2e`, or one ending in a dash (`NAME.local`
couldn't be a host name); a `./NAME` that is there already, of any kind; a folder inside a site folder or a git
repository; no `git` or `php` on the PATH; a name Docker has a compose project or volume of, or that `/etc/hosts`
names as `NAME.local`; no public address (with stdin not a terminal, `--public-url` is needed: this one prints the
usage line, then its one line). It makes the folder under a private name beside `./NAME` (`.NAME.new.XXXXXX`), checks
`site.json` with `lib/config.php` (a public address it refuses: its line, exit 2), commits, and only then renames it;
on a failure (exit 1) or Ctrl-C it removes it, so it leaves a whole site folder or nothing. It commits only with an
identity git has been given (`user.name` and `user.email`), never one git would guess from this Mac's user and host
names.

### `setup-wp`

`setup-wp` needs `mkcert` (with `mkcert -install` done) and Docker. It asks for an admin user name, email address and
password, or reads `WP_ADMIN_USER`, `WP_ADMIN_EMAIL` and `WP_ADMIN_PASSWORD`. The password is never stored. On a
WordPress it has just installed (WP-CLI said "Success:"; never one it found installed), it deletes post 2 when that is
WordPress's untouched Sample Page (a page with the slug `sample-page`, its `post_modified` its `post_date`). On any
run, when HEAD doesn't have the plugin yet, it commits exactly `wp-content/mu-plugins/offprint.php` and
`wp-content/mu-plugins/offprint` as "Offprint's plugin" when the site folder is the top of its git repository, nothing
is staged and git has an identity; else it says what to do. What it commits is the tool's own `plugin/`, byte for
byte, never the copy in `wp-content/`, which WordPress can write: when the copy then differs from the commit (a file
WordPress changed or added there), it says so, naming the paths, and a publish refuses until the copy matches. A
plugin in HEAD that isn't this Offprint's (an older one) is left as it is, and it says the command that would replace
it (a publish refuses until it is replaced, and says the same command). Every command that runs Docker compose
(`setup-wp`, `compose`, `wp`, `publish`) first asks Docker about the compose project of the site's `name`, and refuses to go on (exit 2, naming what it found) if a container of that
project was made from another folder, or if a volume of that project, or a volume called `NAME_db` or `NAME_wordpress`
(the names compose would mount) however it was made, lacks either label Offprint gives its own: `offprint=1` and
`com.docker.compose.project=NAME`.
When Docker isn't running, `setup-wp`, `wp` and `compose` (but for `compose ps`) say so and stop; `publish` fails with
"WordPress isn't running".

It copies the plugin into `wp-content/mu-plugins/`. The Sample Page goes because it links to `/wp-admin/`, a link the
checks refuse; the plugin is committed because a publish refuses while the plugin copy has uncommitted changes. Those
are the two traps of a first publish, and it says each in a line.

WordPress ships with a plugin or two, which its container puts into `wp-content/plugins/`: set-up names any that
appeared, with the command that deletes them, since a publish commits whatever is there. And it removes the publish
request that installing WordPress itself made, so nothing is published until you say. It ends with
"Done: https://mysite.local/  (admin: https://mysite.local/wp-admin/)".

### `publish`

Without `--no-push`, a publish needs the site repo on `main` and an `origin` it can reach: it asks `origin` about `main`
before it exports anything, and with none it stops ("Couldn't reach GitHub to check main; see var/publish.log"). With
one it commits and pushes, then has the site's host adapter make the commit live, and asks the live site until it
serves this publish (for `cloudflare-workers`, 60 seconds at most); with no host set up it ends once it has pushed.
`--no-push` stops after the commit, on any branch.

### Changing `public_url` later

If you change `public_url` after `setup-wp`, commit `site.json` and run `offprint compose up -d`: WordPress takes the
address when its container is made, and this makes the container again with the new one. Until then a publish would
link every page to the old address; `offprint adapter doctor` says when the two differ.

### The launchd agent

`offprint install-agent`, run as you (not with `sudo`), installs the launchd agent. From then on, publishing a post
or page in wp-admin, changing, unpublishing or deleting a published one, or editing or deleting a category or tag,
asks the agent to run `offprint publish`; anything else (menus, widgets, themes, settings) waits for the Publish
Site button in the admin bar, which also shows how each publish went. The agent's PATH is Homebrew's folders and
the system's, and `docker`, `git` and `php` must be on it (`INSTALL_AGENT_PATH` gives it another); Docker must be
running when it publishes. `offprint install-agent --print` shows the agent's plist and changes nothing; `--remove`
takes the agent away.

### Upgrading Offprint

A site uses whichever Offprint you run, and keeps the copy of the plugin that `setup-wp` committed until you replace
it. A publish commits no plugin but the one of the Offprint you run, so after an upgrade that changes the plugin it
refuses until you do, and says the command. Pinning a site to an exact Offprint version is not built.

## Comments (Pigeonhole): what is built

Pigeonhole is how a static Offprint site takes comments. A visitor's browser encrypts a comment to keys only you
hold and posts it to one path of the site's own address; your web server passes it to a store on a private network,
which nothing on the internet can reach; your Mac fetches it over ssh, and, when you ask, opens it and hands it to
WordPress, where it waits in the moderation queue. An approved comment shows at the next publish.

**Every part is built, and the whole has been run with the real programs in Docker
(`tests/rehearsal.sh`: Caddy, sshd, the store, the fetch, a real WordPress). It has not yet run on a real server.**
It needs a web server of your own in front of the site (one that can pass a path on) and a second, small machine on
a private network with it; a host that only takes files can't take comments, and neither built-in adapter says it
can. Nothing here is "end-to-end encrypted": a comment is encrypted in the visitor's browser to a key only the
site's owner holds, by a script the site's own web server sends them.

### What you set up, in order

1. **The keys.** `offprint pigeonhole keys` makes two in the login Keychain, each only if it isn't there, and
   prints the public half of each. The *daily key* opens comments (an age key; `age-keygen` makes it, straight into
   the Keychain). The *pull key* fetches (an ssh key for this site alone). Neither is ever shown or written to a
   file. Make a second age key somewhere else, the *recovery key*, and keep it off this Mac: a comment encrypted
   to the daily key alone is lost with this Mac.
2. **`site.json`.** The `pigeonhole` block: `path`, `recipients` (the daily key's public half, then the recovery
   key's), and the four server members (`server`, `server_host_key`, `jump`, `jump_host_key`). Each host key is the
   first two words of that machine's `/etc/ssh/ssh_host_ed25519_key.pub`; they are pinned in `site.json`, and a
   machine that shows another key is never spoken to.
3. **The store's machine.** `offprint pigeonhole print-server store WEB_ADDRESS` prints a script (WEB_ADDRESS is
   the web server's address on the private network). Read it, then run it as root on the store's machine (Debian
   12 or Ubuntu 24.04: node 18 or newer, from the system's packages). It makes a user for this site
   (`ph-NAME`), the store as a systemd unit shut in to its own folder and to speaking with the web server alone, and
   the one thing the pull key may do there, and only from the web server's address (list, fetch and remove this
   site's submissions: no shell). It ends by
   printing the firewall lines, which are yours to run: only the web server may reach that machine.
4. **The web server.** `offprint pigeonhole print-server web` prints the lines for the site's Caddy block (`POST` to
   exactly the path is passed to the store, with the whole request taken first and the visitor's address set by
   Caddy itself) and the commands for the user the Mac's ssh passes through (`pigeonhole-jump`, whose key may only
   open a connection on to the store's ssh: its key's line says so, and a rule for that user in
   `/etc/ssh/sshd_config.d/` forbids what a key's line can't). The last of those commands reloads sshd only when
   `sshd -t` found its whole configuration right; when it says sshd was not reloaded, remove the file it names. If
   a proxy stands in front of Caddy, read the note printed above the Caddy lines: the limit on each visitor holds
   only when Caddy reads the visitor's address from what the proxy itself set (`trusted_proxies` with
   `client_ip_headers`, or `trusted_proxies_strict`).
5. **The adapter.** The site's own adapter says its host passes the path on: `ADAPTER_PIGEONHOLE=1`
   ([A site's own adapter](#a-sites-own-adapter)). A publish refuses a site with the block until it does.
6. **`offprint compose up -d`** (WordPress takes the path and keys when its container is made), then
   **`offprint pigeonhole doctor`**: one `ok:` or `problem:` line for each step of the path, ending with a test
   submission posted through the public site, fetched back, and opened. Then publish.

Offprint runs none of steps 3 and 4, never runs `sudo`, and never touches a server.

### Day to day

- **Fetching** happens by itself: the site's agent (`offprint install-agent`) fetches when it wakes, about every
  five minutes, and opens nothing. A server that doesn't answer is cut off after a minute. A fetch reads the pull key and never the daily key. When it brings anything,
  one macOS notification says how many wait, and nothing else.
- **Opening** happens when you ask: "Check for comments" in WordPress's admin bar, or `offprint collect` (which
  fetches first; `--no-fetch` opens only what is here already). The admin bar says how many wait, when the last
  fetch was and whether it worked, and how the last check went.
- **Moderating** is WordPress's own comments screen. Approving a comment publishes nothing: it shows at the next
  publish, for whatever reason that runs.

`offprint collect`, for each file in the site's spool: checks the file is what was sent (its name is the hash of
its bytes), opens it with the daily key, checks that what it holds is a comment and nothing else, sorts it (held, or
spam when a hidden field was filled in or it was sent within 3 seconds), and hands it to WordPress. It ends with
one `ok:` or `problem:` line. The import holds every comment, whatever WordPress's settings would allow; filters
its HTML; keeps a link's address only when it is a whole `http(s)` one to another site, and replaces an address of
this site's own in the comment's words with "[a link to this site]" (a link to a page of yours that isn't there
would fail every publish; put a real link back when you moderate, if you want it); makes a link of a bare address
in the comment's words, as WordPress would when showing it, under the same rule (the static page links nothing
more in such a comment, so an address you add to one when moderating is a link only if you write it as one; an
email address stays as words); takes the same comment arriving
twice as one; and sends no email about it. It runs with the site's plugins and theme loaded, so a post of a type one
of them registers takes comments like any other; a plugin of yours that acts on new comments (one that sends them
to a spam service, say) is handed these too.

The spool is `~/Library/Application Support/Offprint/pigeonhole/NAME/spool/` (`OFFPRINT_HOME` moves
`~/Library/Application Support/Offprint`), never in the site folder. Beside it, `done/` holds what WordPress took
(emptied of files over 30 days old) and `rejected/` what was refused, each with a `.why` file saying why in one line.
Nothing is ever dropped. A comment WordPress doesn't answer for stays in the spool and the run goes on to the next;
after two such in a row the run stops, and the next run tries again.

### The parts

**The page.** For a site with the block, a post with comments open shows WordPress's own comment form, with a block
naming the path and the keys, and a loader of under 1 KB. The form cannot post by itself (its method is `dialog`,
which a browser does nothing with): only the script sends, and only what it has encrypted, so a visitor whose
browser never ran the script sends nothing. A post with comments closed, and every other page, is as before. A
site that takes comments from its registered users only shows no form. The first time a visitor touches the form,
the loader fetches the script that does the work (about 52 KB compressed). On Post Comment it pads the comment to
one fixed size, encrypts it in the browser to your keys, does a short proof of work, and posts it to `path` on the
site's own origin. Nothing readable leaves the page, and the visitor is told whether it was sent, or what to put
right first. Reply links stay on the page: WordPress's own reply script moves the form under the comment. Avatars
are off. `bin/check-site` refuses the export when a page's block is not exactly `site.json`'s path and keys; when
the comment form is not exactly as printed (once, with the block, unable to post); when anything else on a page
would send to the path, however its address is written; or when either script is not byte for byte the tool's own.

**The store** (`pigeonhole/server/store.js`: one small node program, no dependencies). It takes a `POST` to the one
path and nothing else. It refuses anything that is not exactly the size a submission has, does not start as an age
file does, or carries no proof of work; it lets one sender (an IPv4 address, or a /64 of IPv6) send 10 an hour and
everyone 300; and it keeps each submission once, whole or not at all, in a file named after its hash. It cannot
list or give back what it holds, and it writes down no address. `pigeonhole/server/pull.js` is the one command the
Mac's key may run beside it: the names held, one file's bytes, one file removed.

**The fetch.** The Mac's ssh goes to the web server, which lets the pull key open one connection, on to the store's
ssh, where the same key may run the pull command and nothing else. Nothing of your own ssh set-up is used (not
`~/.ssh/config`, your keys or your agent): the run has a config and a `known_hosts` of its own, holding the two
pinned host keys, and an `ssh-agent` of its own, into which the pull key goes from the Keychain on a pipe, and
which is killed when the run ends. Each file is kept only when its bytes hash to its name, and removed from the
store only once the Mac holds it: a run cut short leaves a comment in both places, never in neither.

**After "Live".** Whoever can change a page or a script between your host and a visitor (the host itself, or a
proxy in front of it) could swap the keys or the script, or add a script that reads a comment as it is typed, and
read every comment from then on. A publish can't stop that. Once the live site serves the publish, it fetches one
page that has a comment form, and the two scripts, as any visitor would; gives them the check an export gets; and
compares the scripts the live page runs with those of the page it published. Anything wrong (an error or a far
larger answer for one of the three included) is an "Action needed:" warning, and the admin bar turns red; the
publish stays live, since the files published are right. It is a tripwire, not a proof: it looks at one page, its
request can be told from a visitor's, and it does not read the bytes of the page's other script files. A proxy
that adds a script of its own to your pages (an analytics beacon, say) will set it off, rightly: that script can
read what is typed there.

### Not built, and not yet tried

- Not built: a command that replaces the daily key (add the new one beside the old by hand: `age` tries each);
  a second site on one store's machine (the server is laid out for it: an instance a site); a trained spam filter;
  a daily test submission; avatars served from the site; forms other than comments.
- Not yet tried on a real server: the systemd unit and its limits (written by the printed script; read by
  `systemd-analyze verify` in the rehearsal, never started there), the firewall lines, and a proxy in front of the
  web server.
- The notification is shown by macOS's `osascript`, so macOS says it is from Script Editor.

## Publishing to Cloudflare Workers

The `cloudflare-workers` adapter uploads `site/`, exactly as committed, to a Cloudflare Worker's static assets, from
your Mac, with wrangler 4.166.0. The publish writes `offprint.json` into `site/`, naming the publish, and then asks
`PUBLIC_URL/offprint.json` until it names it. Its two settings, both required: `worker`, the Worker's name (1 to 63
lowercase letters, digits and dashes, starting and ending with a letter or digit), and `account_id`, the Cloudflare
account's id (32 lowercase hex digits).

A publish downloads and installs nothing: `offprint adapter setup` puts what it needs on the Mac first. Each step says
what it will do and asks first (`--yes` answers yes to each), and nothing is made on Cloudflare:

1. node, 22.12.0 or newer: the `node` first on your PATH. Its full path is recorded, since the launchd agent that
   publishes doesn't have your shell's PATH.
2. wrangler 4.166.0, installed with `npm ci --ignore-scripts` from the lockfile in `adapters/cloudflare-workers/`, by
   the npm beside that node, with none of your own npm settings, in a new folder that takes its place only once it is
   whole.
3. a Cloudflare API token, made at https://dash.cloudflare.com/profile/api-tokens (Create Token, then Create Custom
   Token) with the permission Account → Workers Scripts → Edit for that account. Set-up asks Cloudflare for the
   account's list of Workers with it, and only then keeps it in your login Keychain, never in a file. Cloudflare's
   answer shows it knows the token and the token can see the account; not that it may upload (it answers so for a
   token without the Workers permission too), which only a publish shows, so set-up says just that. A token Cloudflare
   doesn't know (HTTP 401: mistyped, cut short when copied, deleted or rolled) is told apart from one it refuses for
   the account (403: most often a wrong `account_id`, else a token for another account) and an account it doesn't find
   (404: `account_id`). A value in the Keychain that can't be read (one stored some other way) is replaced by the one
   you paste.

node's path and wrangler go in `~/Library/Application Support/Offprint/cloudflare-workers/` (`OFFPRINT_HOME` moves
`~/Library/Application Support/Offprint` elsewhere). An `OFFPRINT_HOME` set in your shell when you run set-up is not
in the launchd agent's plist (`offprint install-agent` gives it only `PATH` and the site folder), so a publish from
wp-admin looks in the default folder, finds nothing there, and fails saying to run set-up: for a site the agent
publishes, leave `OFFPRINT_HOME` unset. Run set-up again at any time: what is already right is kept, and nothing is
asked about it. Ctrl-C stops it, leaving nothing half-installed and no token stored.

A publish reads the token from your login Keychain only to upload, after the push. When the Keychain is locked, the
deploy fails, saying so ("the login Keychain is locked, so the Cloudflare token couldn't be read; unlock it, then
publish again"), and nothing is uploaded. A publish started by the launchd agent while the login Keychain is locked
has been tested with stand-ins only, not on a real locked Keychain.

`offprint adapter doctor` changes nothing. It prints one line, `ok` or `problem`, for each of: wrangler 4.166.0
installed; the node recorded runs; Cloudflare knows the token in the Keychain and it can see the account (whether it
may upload, a publish shows); WordPress's container was made with site.json's `public_url` (as Docker records it); the
live site's `offprint.json` names the publish of the site repo's last commit; `/feed/` answers as RSS; and a page that
isn't there answers 404. A `problem` line ends with what to do. It exits 0 only when every line is `ok`.

When Cloudflare refuses an upload, the publish fails with the line after wrangler's `[ERROR]` marker and Cloudflare's
own reason under it (looked for only in that marker's own block, up to the next marker or wrangler's `Getting User
settings...` line), and, for the two a real run gave, what to do: "No access to the specified service." (the token
lacks Account → Workers Scripts → Edit for the account) and "Authentication error [code: 10000]" (`account_id` isn't
an account the token belongs to, or the token lacks the permission; `offprint adapter doctor` tells which). It fits in
the status's 300 bytes: when it doesn't, the API path in wrangler's line goes first, then what to do (all of it, never
a part), then the end of wrangler's line. What wrangler prints is in `var/publish.log`, with the token's value hidden,
and without the lines that name accounts (names and ids) or the owner that wrangler prints when Cloudflare refuses the
token: one line per stream says something was left out.

Every Offprint command has left out of its PATH, before anything is looked up on it, each `.`, empty or relative entry,
each entry in the site folder, each that leads to a folder with a colon in its name, and each that can't be entered, and
kept the rest as the folders they lead to then (the table in [security.md](security.md)). As a second layer, set-up, doctor and a
publish never run a node, npm or wrangler, nor hand the token (or Cloudflare's answer) to a curl or php, that is in the
site folder or leads there by a link; and set-up and doctor ignore the PATH's empty and relative entries when they look
those up. The Keychain helper (`os/darwin/secret`), which holds the token, is run with `/bin/bash` and runs
`/usr/bin/security`, never a bash or a security the PATH finds. Every other command Offprint runs is the one the rest of
the PATH finds first: a program in an absolute entry outside the site folder runs as you, so keep those folders yours.

## A site's own adapter

A site whose host is neither of the two built in can bring its own adapter: a folder `adapters/NAME/` in the site
folder, with `adapter.sh` in it, committed whole, and `"adapter": {"name": "NAME"}` in `site.json`. The header of
`lib/adapter.sh` is the contract: which variables and functions an adapter may define, and what a publish does around
them. An adapter that defines nothing but how to ask the live site which publish it serves is enough for a host that
deploys by itself when the site's repository is pushed: `tests/fixtures/adapters/workflow/adapter.sh` is one, for a
deploy workflow that writes `build.json`, naming the commit, at the root of the live site. The publish then pushes,
and waits until the live site names the commit it pushed. An adapter whose host is a web server of yours that forwards
the pigeonhole's path sets `ADAPTER_PIGEONHOLE=1`; without it a publish refuses a site with a `pigeonhole` block.
Once such a site is live, the publish also asks the live site for one page with a comment form and for the two
scripts, and warns loudly when they are not what it published ([Comments](#comments-pigeonhole-what-is-built)).

## The one privileged step

`offprint host-setup`, with `offprint host-undo`, which reverses it, is the only thing in Offprint that runs as root,
and you run it by hand: it does not call `sudo`, it prints the line to run. `offprint host-setup --print` runs as you,
changes nothing, and lists every change and any clash. The set-up has four parts, all this site's: `local_ip4` and
`local_ip6` on `lo0`; both again at every boot (the LaunchDaemon `PREFIX.loopback`, PREFIX being `daemon_prefix`);
`local_host` as both addresses in a marked block of `/etc/hosts`, copied once to `/etc/hosts.before-offprint` first;
and ports 443 and 80 on both addresses relayed to the site's Caddy (`PREFIX.https`, `PREFIX.http`). It refuses,
naming the clash, before changing anything when an address, the host name, a port or a LaunchDaemon is already in use
by something else. Everything it writes carries a stamp, the sha256 of the site folder's physical path, and one
without this folder's stamp is never changed or removed. For a site moved to a new folder, `host-setup --adopt`
re-stamps that site's own set-up and nothing else; running it says that the old folder is gone and this is the same
site. `offprint host-undo` (also with `--print`) takes this site's set-up away again, and nothing else;
`/etc/hosts.before-offprint` is never removed.

## Plugins that replace WordPress's sitemaps

The export starts from the home page, the main feed, `robots.txt` and the sitemaps, and follows every link from there:
a page that nothing links to is exported only because a sitemap lists it. A plugin that serves sitemaps of its own (an
SEO plugin, say) turns WordPress's off, so the exporter also reads the `Sitemap:` lines of the site's own `robots.txt`
(its first 512 KB) and exports each sitemap on the site that they name, with the sitemaps and pages it lists. One that
can't be exported (a line left from an old set-up, a 404) is a warning, "robots.txt names the sitemap ..., which could
not be exported: ...", not an error, unless a page links to it too; a sitemap or page it lists that fails is an error,
as for WordPress's own. Only when WordPress's sitemaps are off and no sitemap `robots.txt` names was exported does the
export warn "Sitemaps are off, so only pages reachable by links from the home page, the feed and the 404 page will be
exported." That is what "Discourage search engines" gives: it turns WordPress's sitemaps off, and the exported
`robots.txt` still names `/wp-sitemap.xml`, so that line gets its warning too.

| Plugin | Version | Tested | Result |
| --- | --- | --- | --- |
| Yoast SEO (`wordpress-seo`) | 28.9 | 24 November 2026 | 6 ok, 0 FAIL |

`bash tests/compat-seo.sh SLUG` tests another, by its wordpress.org slug. On a throwaway WordPress, as `tests/e2e.sh`
makes, with a few posts, a category, a tag and a page that nothing links to, it installs and activates the plugin,
exports, and checks one line each: the export has no errors; it has every sitemap on the site that its `robots.txt`
names; it has every published post, page, category, tag and author archive WordPress has; the page nothing links to is
there, and no other page links to it (the control); no file holds the local hostname; and `bin/check-site` passes on
it. Its last line is the table's row. It needs Docker and the network (the plugin comes from wordpress.org).

## Tests

| Suite | Command | Needs Docker | In CI |
| --- | --- | --- | --- |
| PHP (exporter, plugin) | `composer install && vendor/bin/phpunit` | no | yes |
| JavaScript (admin bar) | `node --test tests/*.test.js` | no | yes |
| `bin/check-site` | `bash tests/check-site.test.sh` | no | yes |
| `offprint new` | `bash tests/new.test.sh` | no (stand-in `docker`, `ifconfig` and `lsof`) | yes |
| `bin/publish`, `bin/offprint` | `bash tests/publish.test.sh` | no (stand-in `docker`) | yes |
| Host adapters, `offprint adapter setup` and `doctor` | `bash tests/adapter.test.sh` | no (stand-in `docker`, `node`, `npm`, `curl` and `security`) | yes |
| `os/darwin/secret` (the Keychain) | `bash tests/secret.test.sh` | no (a stand-in `security`) | yes |
| `bin/publish-agent`, `install-agent` | `bash tests/agent.test.sh` | no | yes |
| `hosts-block.sh` | `bash tests/hosts-block.test.sh` | no | yes |
| `host-setup`, `host-undo` | `bash tests/host.test.sh` | no (a pretend machine) | yes |
| `site.json` loader | `bash tests/config.test.sh` | no | yes |
| `offprint backup verify` and `restore` | `bash tests/backup.test.sh` | no (stand-in `age` and `docker`) | yes |
| `offprint collect` | `bash tests/collect.test.sh` | no (stand-in `age`, `docker` and `security`) | yes |
| The fetch (comments) | `bash tests/fetch.test.sh` | no (stand-in `ssh`, `ssh-agent`, `ssh-add`, `security` and `docker`) | yes |
| `offprint pigeonhole` | `bash tests/pigeonhole.test.sh` | no (the same stand-ins, and `age-keygen` and `curl`) | yes |
| The page's scripts (comments) | `node --test tests/pigeonhole-browser.test.js` | no | yes |
| The store (comments) | `node --test tests/pigeonhole-server.test.js` | no | yes |
| The store's pull command | `node --test tests/pigeonhole-pull.test.js` | no | yes |
| Names that must not be in the tool | `bash tests/names.test.sh` | no | yes |
| End to end | `bash tests/e2e.sh` | yes | no |
| A plugin that replaces WordPress's sitemaps | `bash tests/compat-seo.sh SLUG` | yes, and the network | no |
| The backup, with the real `age` | `bash tests/backup-real.sh` | no (but `age`, installed) | no |
| A restore, with the real tools | `bash tests/restore-real.sh` | yes, and `age` and `mkcert` | no |
| `offprint collect`, with the real `age` | `bash tests/collect-real.sh` | no (but `age`, installed) | no |
| The page's scripts, built again and opened with the real `age` | `bash tests/pigeonhole-real.sh` | no (but `age`, `npm` and the network) | no |
| Comments, whole, with the real programs | `bash tests/rehearsal.sh` | yes, and `age`, `node` and the network | no |
| A running site | `bash tests/site.test.sh SITE_DIR` | yes (a set-up site) | no |

The first nineteen need only bash, git, PHP, Perl and Node. The suites that publish use a stand-in `age`
(`tests/fixtures/age-standin`); `tests/backup-real.sh` runs the real one the same ways, and is run on the Mac before a
change to the backup is merged. `tests/restore-real.sh` makes a real, throwaway site folder (`offprint new`,
`offprint setup-wp`, a publish with `--no-push`) in the compose project `offprint-restore-real`, restores into it
three ways, and removes it; it never runs the host set-up or `sudo`. `tests/e2e.sh` builds a throwaway WordPress in the compose
project `offprint-e2e` and removes it afterwards; `tests/compat-seo.sh` builds the same one (`tests/e2e-setup.sh` is
their shared set-up), so the two never run at the same time: each refuses to start while that project exists.
`tests/site.test.sh` reads a real, running site and changes nothing.
