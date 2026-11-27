# Offprint

For coding agents working in this repo. `README.md` says what Offprint is and what is built (briefly: the steps, the
reference and the security table are in `docs/`); this says how to work on it.

New to the project? Read `docs/orientation.md` before your first change: what the tool is for, how a publish and the
export work, where a new feature goes, what is decided but not built, and what has gone wrong before. This file is
the rules; that one is why they are the rules.

## Layout

```
bin/offprint                  the one entry point (see `bin/offprint help`); runs the script of the same job
bin/new                       makes a new site folder outside every site and repo: site.json (addresses and ports no other
                              site on the Mac uses), .gitignore, the first commit
bin/publish                   export, check, back up (the database dump, encrypted with age to site.json's backup
                              recipients, as backup/db.sql.age), commit, push, then the adapter's deploy, and wait for
                              the live site
bin/backup                    offprint backup verify (the committed backup opens with the owner's key, and is a whole
                              dump) and restore (the local database replaced from it or from a dump file, the one
                              before kept encrypted in var/before-restore/)
bin/collect                   offprint collect: fetches what a site's pigeonhole holds into the spool (lib/pigeonhole.sh),
                              and takes what waits there (comments, each encrypted in a visitor's browser) into
                              WordPress: opened with the daily key, checked, sorted, handed over, held; --fetch-only
                              (what the agent runs) fetches and opens nothing; the spool is under OFFPRINT_HOME,
                              never in the site folder
bin/pigeonhole                offprint pigeonhole keys (the daily key and the pull key, made in the login Keychain),
                              print-server (what the owner runs on the web server and on the store's machine: printed,
                              never run) and doctor (the whole path, with a test submission)
bin/publish-agent             what launchd runs when WordPress asks for a publish; takes var/inbox/publish-request;
                              on every start it also fetches comments (bin/collect --fetch-only), and it takes
                              var/inbox/collect-request (WordPress's "Check for comments") and runs bin/collect
bin/check-live-page.php       for the publish's look at the live site: a live page runs the scripts the published page
                              runs, and no others
bin/check-site                the export checks; bin/check-site-addresses.php does the link, image, form and feed checks,
                              bin/check-site-pigeonhole.php the comment-form ones (a page's block is site.json's, the
                              two scripts are the tool's own)
bin/setup-wp                  makes a site's local WordPress (certificate, containers, install, options); on a WordPress it
                              installs, deletes the untouched Sample Page; on any run, commits the tool's own plugin/
                              (never the copy WordPress can write) when HEAD doesn't have it
bin/wp                        WP-CLI inside the site's container
lib/config.php                validates site.json (its backup, pigeonhole and adapter blocks too), prints KEY<TAB>value
                              lines or errors (exit 2)
lib/pigeonhole.php            one opened submission checked (exact size, keys, types, lengths, its time), and sorted
                              (hold or spam); no WordPress function, and a reason never repeats what was sent
lib/pigeonhole.sh             a site's pigeonhole on the Mac: its folders and lock, and the fetch (ssh through the web
                              server to the store, both host keys pinned, the pull key from the Keychain to a run's
                              own ssh-agent on a pipe; each file checked against its name before it is kept)
lib/pigeonhole-keys.php       makes the pull key (Ed25519, in OpenSSH's format, on a pipe), splits what age-keygen
                              prints, and makes a test submission with its proof of work
lib/site.sh                   finds the site folder, loads config into SITE_* and ADAPTER_* variables, defines dc();
                              offprint_plugin_list, the tool's plugin/ as a commit holds it (setup-wp commits it, and a
                              publish refuses a commit whose plugin isn't exactly it)
lib/adapter.sh                the host adapter contract (its header): loads the site's adapter and runs each of its
                              functions in a shell of its own; the default confirm; offprint_secret_get/set/delete
adapters/none/                the adapter for a site with no host: a publish commits and pushes, and ends "saved"
adapters/cloudflare-workers/  adapter.sh (a publish uploads site/ with wrangler 4.166.0), setup.sh (offprint adapter
                              setup and doctor), package.json and package-lock.json (wrangler, pinned)
os/darwin/host-setup.sh       the privileged step: lo0, /etc/hosts, LaunchDaemons (host-lib.sh is its shared code)
os/darwin/host-undo.sh        reverses it for one site
os/darwin/hosts-block.sh      reads and writes the marked block of a hosts file
os/darwin/install-agent       the user's launchd agent that runs bin/publish-agent
os/darwin/secret              a named secret of a site's in the login Keychain (get, set, delete)
plugin/                       the WordPress plugin: offprint.php, offprint/{admin-bar.css,admin-bar.js,src/*.php};
                              src/Import.php is wp offprint import-submission, which makes a held comment of one
                              checked submission; src/Pigeonhole.php is the comment form on an exported page;
                              src/Comments_View.php is what the admin bar says of comments (counts and times);
                              offprint/pigeonhole.js and pigeonhole-loader.js are the scripts that page loads, built
                              and committed (never edited by hand)
pigeonhole/browser/           the sources of those two scripts (src/), the two packages they are built with, pinned
                              (package.json, package-lock.json), and build.sh, which writes them into plugin/offprint/
pigeonhole/server/store.js    a site's pigeonhole, for a machine of the owner's that only the site's web server reaches:
                              takes a POST to one path, checks it (exact size, an age file's start, the proof of
                              work, the limits), and keeps the ciphertext under its hash; node, no dependencies
pigeonhole/server/pull.js     the one command the Mac's key may run on the store's machine: list, get NAME, delete NAME
pigeonhole/server/setup.sh    the body of the script that sets a site's store up on its machine (a user, the systemd
                              unit, the key's one line); offprint pigeonhole print-server store prints it, with the
                              site's values and store.js and pull.js in it, for the owner to run as root
templates/                    compose.yaml, Caddyfile, wordpress/Dockerfile, site.gitignore (for a site's repo)
docs/how-it-fits-together.md  the diagrams of what lives where and of a publish (README.md embeds the second), and a
                              publish step by step
docs/getting-started.md       for someone new to the tool: what they need, then one step per command to a first publish
docs/reference.md             site.json, the backup and restore, every command (its help block must match `offprint
                              help`), the hosts, the privileged step, sitemap plugins, the tests
docs/security.md              the table of what could go wrong and what stops it
docs/orientation.md           the picture for an agent new to the project: read it before a first change
tests/                        every suite (tests/php, tests/fixtures, *.test.sh, *.test.js, e2e.sh, compat-seo.sh);
                              tests/collect-real.sh runs offprint collect with the real age (not in CI);
                              tests/pigeonhole-server.test.js tests the store, tests/pigeonhole-pull.test.js its pull
                              command; tests/fetch.test.sh the fetch and tests/pigeonhole.test.sh offprint pigeonhole,
                              with the stand-ins of tests/fixtures/pigeonhole-standins.sh (ssh, ssh-agent, ssh-add,
                              the Keychain, age-keygen, osascript); tests/rehearsal.sh runs all of comments with the
                              real programs, in Docker (tests/rehearsal/: a web server and a store on a private
                              network; and the throwaway WordPress), not in CI;
                              tests/pigeonhole-browser.test.js tests the page's scripts, and holds the built ones'
                              hashes; tests/pigeonhole-real.sh builds them again from a clean install and opens what
                              they encrypt with the real age (not in CI);
                              tests/fixtures/adapters/workflow is an adapter outside the tool, for tests/publish.test.sh;
                              tests/fixtures/age-standin is the stand-in age every suite that publishes puts first on
                              the PATH, and tests/backup-real.sh runs the real age the same ways (not in CI);
                              tests/e2e-setup.sh is the throwaway WordPress (compose project offprint-e2e) that e2e.sh and
                              compat-seo.sh (an SEO plugin's sitemaps, by its wordpress.org slug) both source
.github/workflows/ci.yml      CI
```

## Rules

- The repo never contains a site's content, uploads or database dump. A site is its own folder and repo.
- Everything in the WordPress container is untrusted. It can write `wp-content/`, `var/export` and `var/inbox`.
  Offprint never executes, sources or follows anything it writes by a lookup of its own. Every entry point starts
  `#!/bin/bash`, sources `lib/site.sh` before anything is looked up on the PATH (found by builtins from its own path;
  before it, only `bin/offprint`, run through a link, runs `readlink` by its absolute path, and `host-setup.sh` and
  `host-undo.sh` source `hosts-block.sh`, which only defines functions, then `host-lib.sh`, which sources it first)
  and runs the tool's other scripts as `/bin/bash SCRIPT`; `lib/site.sh` then leaves out of the PATH every empty or
  relative entry, every entry in the site folder, every `~` entry when `HOME` isn't an absolute path or has a colon,
  and every entry that leads to a folder with a colon in its name (each saying so), and every entry that can't be
  entered (silently; its header), and keeps the rest, and `TMPDIR`, as the folders they are on disk then (`cd -P`), not
  as their text. The rest of the PATH (absolute entries outside the site folder) is the owner's to keep clean
  (`docs/security.md`).
  Every defence in `bin/publish` and `bin/check-site` has a test and a comment saying why. Do not weaken, skip or make
  one optional; if a change needs that, stop and ask.
- The exporter, the plugin and the checks know no theme, block or plugin by name. `bin/publish`, `bin/check-site`,
  `bin/check-site-addresses.php` and `lib/` name no host, comments included: what a host needs is in its adapter
  (`tests/names.test.sh` checks).
- Adapter code is the tool's own (`adapters/NAME`) or the owner's committed code (`SITE/adapters/NAME`, every file
  tracked and unchanged); nothing from a folder WordPress can write is ever sourced. `lib/adapter.sh`'s header is the
  contract.
- A token is never written to a file, a log, `var/status.json`, a process's argument or test output, nor traced by
  `set -x`. It travels on a pipe or in the environment of the one process that needs it; output that could hold it goes
  through a filter that hides its value. The database backup's private key is such a token, and is not Offprint's to
  keep at all: a publish encrypts to public keys only, and `offprint backup verify` and `restore` hold the key the owner
  types in one shell variable, for the pipes to `age` (two in a restore: the whole-first read, then the import).
  A site's pigeonhole daily key is such a token too, kept in the login Keychain: `offprint collect` holds it in one
  shell variable for the pipe to `age`. So is its pull key (an ssh key, kept there as one line), and more strictly:
  it goes from the Keychain's helper (`os/darwin/secret`, which holds it as it holds any secret) down a pipe to
  `ssh-add`, into an `ssh-agent` started for that run and killed when it ends; in `lib/pigeonhole.sh`, `bin/collect`
  and `bin/pigeonhole` it is never in a variable at all. `offprint pigeonhole keys` makes both on pipes into the
  Keychain and shows only
  their public halves. And an opened comment is treated the same way: it exists on pipes and in one shell variable,
  never in a file, an argument, a log or `var/`.
- A comment is a stranger's text. It reaches WordPress only through `wp offprint import-submission`, which holds
  every comment, turns WordPress's HTML filter on (and refuses without it), keeps a link's address only when it is a
  whole one to another site, and replaces an address of the site's own in a comment's words (the exporter follows
  every link to the site, and the checks refuse the local host name anywhere: either would fail every publish once
  the comment was approved). A bare address in a comment's words is made a link at import, by WordPress's own
  `make_clickable`, and held to that same rule; export mode then links nothing more in a comment the import made
  (`Export_Mode::link_addresses`). So no list of the ways a host name can be written is kept, and none is to be
  added: what WordPress would link is linked once, and looked at. What WordPress answers to an import is data: one
  line of three shapes, or no answer. One submission that can't be taken never holds up those behind it.
- The store (`pigeonhole/server/store.js`) knows nothing of a submission but its size, when it came and the address
  the web server named: it has one route, cannot list or give back what it holds, never starts a connection, and
  writes down no address, name or body. It has no dependency but node. Keep it so. A submission is kept whole or
  not at all, and never called kept when it wasn't; a request the web server didn't name an address for is refused.
- The fetch trusts neither server. Both ssh host keys are pinned in `site.json` and never learnt; a run uses a config,
  a `known_hosts` and an agent of its own, and nothing of the owner's ssh set-up. What the store answers is data: a
  name is matched before it is used, no more of a file is read than a submission can be, a file is kept only when its
  bytes hash to its name, and it is removed from the store only once the Mac holds it. Neither server can keep the
  Mac waiting or fill its disk: each ssh has a deadline, a fetch has one, and what ssh says of a failure is capped.
  The scheduled fetch never reads the daily key and opens nothing: opening is asked for (the owner's decision). What
  a server said is never shown or logged as it is: the tool says why in its own fixed words, which name no address
  (the agent's log is in `var/`, which WordPress reads), and the far command's own failure is never read as ssh's.
- The tool never touches a server and never runs `sudo`. What a server needs is printed (`offprint pigeonhole
  print-server`) for the owner to read and run. On each server the pull key's line is root's, and gives no shell: on
  the web server, one onward connection to the store's ssh and no listening port or socket (the key's line, and an
  sshd rule for that user); on the store, `pull.js` and nothing else, and only from the web server's address. Keep
  it so: `tests/rehearsal.sh` asks the real sshd for each thing the key must not get. The printed commands are
  pasted with no `set -e`: sshd is reloaded only on the line that asked `sshd -t` first, and never by a signal (an
  sshd told to re-read a configuration it can't read exits, and the owner is locked out).
- What the Mac tells WordPress about comments (`var/pigeonhole.json`, `var/pigeonhole-fetch.json`), the agent's log
  and the notification hold counts, times and one fixed word: never a word of a comment, a name or an address.
- A publish looks at the live site after "Live" (`check_live_comments`): one page with a comment form and the two
  scripts, fetched as a visitor would; given the export's own check; and the page's script elements compared with
  the published page's (`bin/check-live-page.php`). A live site that answers any of the three with an error, or far
  too much, is treated as changed, not as unreachable. It warns ("Action needed:") and undoes nothing. It is a
  defence like the rest: a test and a comment saying why. It is a tripwire, not a proof (one page, a request that
  can be told from a visitor's, no other script file's bytes): never describe it as more.
- The two scripts a page with a comment form loads are built from `pigeonhole/browser/` and committed in
  `plugin/offprint/`; a site is published with the committed ones, and `bin/check-site` refuses an export whose copies
  differ. Never edit them by hand. After any change to `pigeonhole/browser/`: run `build.sh` there, read what changed,
  put the new hashes in `tests/pigeonhole-browser.test.js`, and run `tests/pigeonhole-real.sh` on the Mac. What a page
  carries (where a comment is posted, to whose keys) is WordPress's to print and `bin/check-site`'s to compare with
  `site.json`; those comparisons are defences like the rest. So is this: the comment form never posts by itself
  (its method is `dialog`), and nothing else on a page may send to the pigeonhole's path. A visitor whose browser
  didn't run the script must send nothing.
  Each of these has a test and a comment saying why, as the publish's defences have.
- The database dump is never committed, or left in `backup/`, readable: a publish refuses a site with no `backup` block
  or no `age`, and the readable dump in `var/` is removed on every exit.
- A `TMPDIR` that is the site folder or inside it, or can't be entered, is refused before any temporary file is made
  (`lib/site.sh`), and a private folder is never made there (`offprint_private_dir`).
- `site.json` is parsed by `lib/config.php`, never sourced or `eval`ed. A name read from it must have matched a strict
  pattern first. No site's name, address or port goes in the tool's code (`tests/names.test.sh` checks).
- Scripts run under macOS `/bin/bash` 3.2 and on Linux: no associative arrays, no `mapfile`, no empty-array expansion
  under `set -u`.
- Tests first. Test counts must never fall. Plain examples only: `example.com`, `mysite.local`, `127.0.0.9`, the Worker
  `my-site`, the account id `0123456789abcdef0123456789abcdef`.
- Built: the adapters `none` and `cloudflare-workers` (`offprint adapter setup` and `doctor` set it up and check it);
  `offprint new` (a site folder only: it runs no set-up); the encrypted database backup, `offprint backup verify` and
  `offprint backup restore`; and Pigeonhole, comments on a static site: the Mac's side (`site.json`'s `pigeonhole`
  block, the fetch, `offprint collect`, the import, `offprint pigeonhole keys`, `print-server` and `doctor`, the
  agent's and the admin bar's parts), the page's side (the form on an exported page, the two scripts, the checks of
  both, the look at the live site after "Live") and the server's (`pigeonhole/server/`: the store, its pull command
  and its set-up script). It has run whole only in Docker (`tests/rehearsal.sh`), never on a real server: say so
  wherever it is described. A publish refuses a site with a `pigeonhole` block unless its adapter sets
  `ADAPTER_PIGEONHOLE=1`, and no adapter of the tool's does. Not built: any place to send the backup but the site's
  repository; the `ssh` adapter; a top-level `setup`, `doctor` or `upgrade`. Do not describe those as if they were.

## Tests

```sh
composer install && vendor/bin/phpunit      # 546 tests
node --test tests/*.test.js                 # 78 tests
bash tests/check-site.test.sh               # 504
bash tests/new.test.sh                      # 381
bash tests/publish.test.sh                  # 1439 (slow: several minutes)
bash tests/adapter.test.sh                  # 2281 (slow: several minutes)
bash tests/secret.test.sh                   # 335
bash tests/agent.test.sh                    # 357
bash tests/hosts-block.test.sh              # 4
bash tests/host.test.sh                     # 780
bash tests/config.test.sh                   # 431
bash tests/names.test.sh                    # 9
bash tests/backup.test.sh                   # 273
bash tests/collect.test.sh                  # 366
bash tests/fetch.test.sh                    # 377
bash tests/pigeonhole.test.sh               # 407
bash tests/e2e.sh                           # 456; needs Docker; not in CI
bash tests/compat-seo.sh wordpress-seo      # 6; needs Docker and the network; not in CI; never beside e2e.sh
bash tests/backup-real.sh                   # 15; needs the real age (brew install age); not in CI
bash tests/restore-real.sh                  # 31; needs Docker, mkcert and the real age; not in CI
bash tests/collect-real.sh                  # 20; needs the real age; not in CI
bash tests/pigeonhole-real.sh               # 16; needs node, npm, the real age and the network; not in CI
bash tests/rehearsal.sh                     # 123; needs Docker, node, the real age and ssh, and the network; not in CI;
                                            # never beside e2e.sh or compat-seo.sh
bash tests/site.test.sh SITE_DIR            # needs a real, running site; not in CI
```

The shell suites print one `ok` or `FAIL` line per case; the counts above are the `ok` lines on macOS. On Linux (CI)
they differ: `check-site`, `publish`, `adapter`, `agent` and `host` print fewer, since the cases that need the Mac
(`plutil`, or a disk that takes two letter cases for one name) are skipped there, with a `skip` line; `config` prints
more, since some of its cases run again under a second bash. All but the last eight are hermetic and run in CI.
`tests/adapter.test.sh` (the adapter contract, both adapters, `offprint adapter setup` and `doctor`) and
`tests/secret.test.sh` (`os/darwin/secret`) are the adapters' suites; `tests/new.test.sh` is `offprint new`'s (its
setup-wp half, the Sample Page and the plugin commit, is in `tests/publish.test.sh`, with setup-wp's other cases). CI
runs three jobs side by side: the publish suite, the adapter suite, and everything else.

The cases that run only on the Mac (the Unicode case-fold refusals, the case-variant `TMPDIR` and site-folder cases,
the `plutil` and `install-agent` cases) are never run in CI. So run `check-site`, `adapter`, `publish`, `agent` and
`host` on the Mac before any merge.

## Safety on a Mac that has real sites

- Never run `os/darwin/host-setup.sh` or `host-undo.sh` for real or with sudo. Only `--print`, or under all five test
  seams (`OFFPRINT_HOSTS_FILE`, `OFFPRINT_DAEMON_DIR`, `OFFPRINT_IFCONFIG`, `OFFPRINT_LAUNCHCTL`, `OFFPRINT_LSOF`).
- Never run `install-agent` except with `--print`, or with a stand-in `launchctl` and a throwaway `HOME`.
- Never run `bin/new` (`offprint new`) outside a throwaway folder you remove. It only reads `/etc/hosts`, `lo0` and
  `lsof`, but asks the real Docker: in a test, `OFFPRINT_HOSTS_FILE`, `OFFPRINT_IFCONFIG` and `OFFPRINT_LSOF` are set and
  a stand-in `docker` is first on the PATH.
- Never let a test reach the real Keychain, the real Cloudflare account or a real site. Anything that runs
  `os/darwin/secret` (`offprint_secret_*`, a publish or set-up of `cloudflare-workers`, `offprint adapter doctor`) runs
  with `OFFPRINT_SECURITY` naming a stand-in `security`; `OFFPRINT_HOME` (where set-up installs wrangler) points inside
  the suite's temp folder, never `~/Library/Application Support/Offprint`; `node`, `npm` and `curl` are stand-ins first
  on the `PATH`. Never run the real `npm ci`, wrangler or `security` from a test.
- Never run the real `security` command in any form that can write (add, delete, set, `-i`, a keychain's settings),
  outside a step the owner attends; experiments use a stand-in only (one such experiment once left stray items in a login Keychain).
- `tests/e2e.sh` and `tests/compat-seo.sh` use the compose project `offprint-e2e` (`tests/e2e-setup.sh`) and remove
  it; they share it, so never run both at once (each refuses to start while it exists). Never point a test at a real
  site's compose project, folder, address or port.
- `tests/site.test.sh` needs a real site and is not in CI.
- No test runs the real `age` but `tests/backup-real.sh`, which makes its keys in shell variables only and touches no
  site. Every other suite that reaches a publish or `offprint backup verify` has `tests/fixtures/age-standin` first on
  the `PATH`. Run `tests/backup-real.sh` on the Mac before merging any change to the backup.
- `tests/pigeonhole-real.sh` is the one test that runs the real `npm ci` (with `--ignore-scripts`, from the lock file
  in `pigeonhole/browser/`, into a temporary folder): it needs the network and is never run in CI. Run it on the Mac
  before merging any change to `pigeonhole/browser/` or to the two built scripts.
- `tests/collect.test.sh` runs `offprint collect` with a stand-in `age`, `docker` and `security` (`OFFPRINT_SECURITY`),
  and `OFFPRINT_HOME` inside its temp folder. `tests/collect-real.sh` runs the real `age` with keys of its own, in
  shell variables only, and the same stand-ins for the rest: run it on the Mac before merging any change to
  `bin/collect`. Never run `offprint collect` for a real site outside a step the owner attends: it reads the login
  Keychain and writes to that site's WordPress.
- `tests/fetch.test.sh` and `tests/pigeonhole.test.sh` run the fetch and `offprint pigeonhole` with stand-in `ssh`,
  `ssh-agent`, `ssh-add`, `age-keygen`, `curl` and `osascript`, and a stand-in Keychain (`OFFPRINT_SECURITY`):
  `tests/fixtures/pigeonhole-standins.sh`. No hermetic suite runs the real `ssh` or reaches a network. Never run
  `offprint pigeonhole keys` for a real site outside a step the owner attends (it writes to the login Keychain), nor
  `offprint pigeonhole doctor` or a fetch (`offprint collect`, the agent) against real servers: they read the
  Keychain, speak to the owner's servers and post to the live site. `print-server` only reads and prints; what it
  prints is the owner's to run on a server, never an agent's.
- `tests/rehearsal.sh` is the one test that runs the real `ssh`, `ssh-agent` and `ssh-add`: against two containers of
  its own (compose project `offprint-rehearsal`, on a private network, the web server's two ports on 127.0.0.1
  only), with keys it makes for the run, a stand-in Keychain, a `HOME` of its own (nothing of the owner's ssh is
  read) and a stand-in `osascript`. It also uses the throwaway WordPress (`offprint-e2e`), so never beside
  `tests/e2e.sh` or `tests/compat-seo.sh`; it refuses to start while either project has anything, and removes both.
  Run it on the Mac before merging any change to the fetch, the keys, `pigeonhole/server/`, what `print-server`
  prints, the agent's part in comments, or the import.
- `offprint backup restore` replaces a WordPress's whole database. Run it only against a stand-in `docker`
  (`tests/backup.test.sh`), or against the throwaway site `tests/restore-real.sh` makes (compose project
  `offprint-restore-real`, in a temporary folder, removed on exit; it refuses to start while that project exists).
  Never run it for a real site outside a step the owner attends.
- A push runs CI, on any branch. Wait for it to go green (`gh run watch`).
- The repo is public. `main` is never rewritten or force-pushed: its commits must stay reachable.
