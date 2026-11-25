# Orientation

For a coding agent new to Offprint, before its first change. `README.md` is for people who use the tool, and
`CLAUDE.md` is the rules you work under. This is the picture that makes those rules make sense: what the tool is,
how its parts fit, where a new feature goes, what is decided but not built, and what has gone wrong before.

Written on 24 November 2026. Where it and the code disagree, the code is right: fix this file in the same change.

## What Offprint is

Offprint lets someone keep WordPress as their editor while the public only ever sees plain files. WordPress runs in
Docker on the owner's Mac, at a local address. A publish crawls that WordPress from the inside, checks every file
that came out, commits the result in the site's own git repository, and uploads it to a host. Visitors reach the
uploaded files. Nothing they can reach runs PHP, has a database, or has a login page.

It is for technical people who run WordPress and are comfortable in a terminal. The bar the owner set for every
command and message is that a stranger succeeds unaided: a refusal says what is wrong and what to do next.

## Three places

Most confusion comes from mixing these up.

- **The tool** is this repository. It holds no site's content, ever.
- **A site** is its own folder and its own private git repository: `site.json` (data that describes it), `site/`
  (the static copy), `wp-content/`, `backup/db.sql`, and `var/` (status, log, the export in progress, an inbox;
  not committed). `offprint new` makes one. The tool is run from inside it.
- **The Mac** holds what is neither: the Docker containers (WordPress, MariaDB, Caddy), a loopback address and a
  hostname for each site, a launchd agent for each site, and the host's API token in the login Keychain.

`docs/how-it-fits-together.md` draws this.

## The one idea everything else follows from

**Everything inside the WordPress container is untrusted.** WordPress runs themes and plugins the owner did not
write, and it can write three folders of the site: `wp-content/`, `var/export` and `var/inbox`. So:

- What WordPress produced is never executed, sourced or followed by the tool. It is data to be checked.
- The checks that decide what gets published run on the Mac, outside the container (`bin/check-site`).
- Programs are never looked up on a `PATH` that reaches into the site folder (`lib/site.sh` cleans it first).
- A publish commits only what passed, and the plugin in that commit must be byte for byte the tool's own
  `plugin/`, so WordPress cannot alter the code that exports it and have that kept.
- A token never touches a file, a log or a command line.

When you are unsure whether a change is safe, ask: could a hostile plugin use this? Most of the rules in
`CLAUDE.md`, and most of the odd-looking code, are answers to that question. Each defence has a comment saying
what it stops and a test that fails without it. Read the comment before changing the code beside it.

## A publish, from start to finish

`bin/publish` is the spine. In order:

1. **Export.** It runs `wp offprint export` inside the container. The exporter (in `plugin/offprint/src/`) asks
   WordPress for every public page as a logged-out visitor, with a secret header. The plugin answers such a request
   in *export mode*: every address in the response is the public one, and nothing links to what a static site will
   not have. Each response is written once, exactly as it came, into the empty folder `var/export`.
2. **Check.** `bin/check-site` refuses the export if any file links to `wp-admin`, the login page, XML-RPC or the
   REST API, holds the local hostname, has a name the host treats specially, or breaks the host's size limits.
3. **Replace and back up.** `site/` is replaced by the export, and the database is dumped to `backup/db.sql`.
4. **Commit and push.** One commit, built in a private git index. The plugin in it is compared with the tool's.
5. **Deploy.** The site's host adapter uploads the commit's `site/` tree, copied out of git, not from disk.
6. **Confirm.** The publish asks the live site which publish it is serving (`offprint.json`), and reports "Live"
   only when it names this one.

A publish starts in one of two ways: the owner types `offprint publish`, or WordPress writes a request into
`var/inbox` when a post is saved and the launchd agent (`bin/publish-agent`) picks it up. The admin bar shows how
it went, from `var/status.json`.

## How the export finds everything

This is the part people ask about, and the part most likely to be extended.

- **It starts from WordPress's own list** (`Seeds.php`): the home page, the main feed, `robots.txt`, and every
  address WordPress's sitemap providers list.
- **It follows every reference in what it saves** (`Links.php`): links and sources in pages, `url()` and `@import`
  in stylesheets, `import` in JavaScript modules, `<loc>` in sitemaps, and the `Sitemap:` lines of `robots.txt`.
  That last one is how a plugin that replaces WordPress's sitemaps is handled, without the tool knowing any
  plugin's name.
- **`Rules.php` decides what may be fetched.** Never WordPress's own machinery, and never a page address with a
  query string.
- **Every address ends as a saved file, an error or a warning** (`Report.php`). An error fails the publish.

Its limits are real and should not be hidden: every publish crawls the whole site again; a page that is in no
sitemap and linked from nowhere is missed silently; a reference that exists only in JavaScript is not followed;
only the main feed is exported.

Two rules shape any change here. The exporter, the plugin and the checks **know no theme, block or plugin by
name**: solve the general case (a standard, a WordPress API) or do not solve it. And the exporter's classes are
split on purpose: `Exporter`, `Links`, `Rules`, `Paths`, `Output`, `Origin` and `Report` use no WordPress
functions and are unit-tested in milliseconds with a fake fetcher; `Export_Mode`, `Seeds::from_wordpress`,
`Fetch` and `Request` need a real WordPress and are covered only by `tests/e2e.sh`. Keep new logic on the first
side wherever you can.

## Where a new feature goes

| You are adding | It goes in | Remember |
|---|---|---|
| A command | `bin/NAME`, wired into `bin/offprint` and its help | Start `#!/bin/bash`, source `lib/site.sh` first; add it to the entry-point list in `tests/names.test.sh`; the README's help block must match `offprint help` |
| A host | `adapters/NAME/` | `lib/adapter.sh`'s header is the contract: which functions and variables an adapter may define, and what a publish does around them. `bin/` and `lib/` must never name a host |
| Something the export should find or skip | `plugin/offprint/src/` | Any change under `plugin/` means every existing site must replace its copy before it can publish again (the publish says how). Say so in the README when it matters |
| A new refusal | `bin/check-site` or `bin/publish` | A comment saying what it stops, a test that fails without it, and a message that says what to do |
| Anything that changes the Mac | `os/darwin/` | The tool never runs `sudo`. It prints the line and the owner runs it |
| A field in `site.json` | `lib/config.php` | It is the only parser; nothing is ever sourced or `eval`ed from it |

## How this codebase is tested, and why it looks the way it does

- **Stand-ins, not the real thing.** The shell suites put fake `docker`, `curl`, `node`, `npm`, `security`,
  `launchctl` and friends first on the `PATH`, and use seams (environment variables such as `OFFPRINT_HOSTS_FILE`)
  for files the tool would read. That is what lets them run anywhere, including CI, and never touch a real site.
- **Stand-ins drift.** Three real defects came from a stand-in that behaved more kindly than the real tool. When a
  real run surprises you, teach the stand-in the real behaviour first, watch the tests fail, then fix the code.
- **The suites are large and two are slow.** `publish` and `adapter` take ten minutes or more each. While building,
  run only what your change touches; run everything once at the end. Never edit a file while a suite that reads it
  is running.
- **Some cases only run on a Mac** and never in CI, and CI runs bash 5 where the Mac has bash 3.2. Both must pass.
- **Fixes regress.** Every fix made so far that was not looked at again had broken something nearby. After a fix,
  re-read the diff asking what it broke, and have it reviewed when it touches a defence or a token.
- **Counts never fall.** `CLAUDE.md` lists each suite's count; update it in the same change.

## What is decided but not built

The owner has read and answered three designs. The full texts are kept outside this public repository; ask the
owner for them before starting any of these. The decisions:

**`offprint doctor`, then `offprint setup`.** Doctor first: it only reads, and prints one `ok` or `problem` line
per check, each problem with the command that fixes it. Set-up is eight checked steps that can stop and be run
again; it does only what is not done. Decided: a missing program is named with its install command, never
installed; set-up *does* write the adapter block into `site.json`, after asking; the launchd agent is offered
last and doctor reports it when missing; set-up offers the first publish so a finished site shows every line ok.

**A version pin, `offprint upgrade`, and the plugin mounted read-only.** `site.json` will name an exact commit of
a clean Offprint checkout. A read-only copy of that commit is installed for each Mac (as wrangler is today), and
every command, the agent and the containers use that copy or refuse. The plugin is mounted into WordPress from it,
so no copy lives in the site. Decided: any commit may be pinned, not only tags; the mount is part of the same
work; restoring the database is a separate design. **This retires two defences that exist today** (set-up's plugin
commit, and the publish's plugin refusals): get the owner's explicit OK again when the work starts.

**An `ssh` adapter.** rsync the commit's `site/` into a new release folder on the server, then switch a `current`
link in one step. Decided: a key for that site only, tied on the server to a small Offprint script so a leaked key
gets no shell; set-up makes the key; set-up does the server's side itself over the owner's admin login, showing
each command and asking first, with an undo; the server's host key is pinned in `site.json` and never learnt
during a publish; Caddy is documented first.

Also deferred until something needs it: a WordPress filter that lets a site add its own starting addresses.

## Known gaps, as of 24 November 2026

Check each is still true before relying on it or fixing it.

- On Linux, a publish that inherits `allexport` through `SHELLOPTS` can fail part-way with every command refused
  ("Argument list too long"): `bin/publish` then exports its own variables, and Linux refuses to start a program
  when one environment string is over 128 KiB. The status is left at "checking" and the lock and temporary folders
  stay behind. It is what made one case in `tests/adapter.test.sh` fail on some CI runners. The fix is known
  (`set +a` at the top of `bin/publish`, with a test that no variable of the publish's own reaches a command) and
  was not yet made when this was written.
- One timing case in `tests/secret.test.sh` fails when the suite runs beside the two slow suites. Run it alone.
- With "discourage search engines" on, the exported `robots.txt` still names `wp-sitemap.xml`, which gives an
  extra warning.
- A sitemap in plain-text form is saved but not read for addresses.
- `bin/publish` says "GitHub" whatever host `origin` is on, and "Couldn't reach GitHub" when there is no `origin`.
- Two `offprint new` runs before the first site's host set-up pick the same address and ports. Host set-up
  refuses the clash; `new` says so.
- Never run for real: `offprint new`'s address prompt, the README's `gh repo create` line, and a publish started
  by the agent while the login Keychain is locked.
- Tried with Docker Desktop only. One SEO plugin measured (`tests/compat-seo.sh`; the README has the table).
- There is no release tag yet.

## Working with the owner

- **Decisions that are the owner's:** anything on a real account (the host, GitHub settings, the Keychain), any
  merge that changes what the tool promises, and removing or weakening a defence. Ask, with a recommendation.
- **Real runs are done together.** The agent prepares; the owner runs the step that touches something real, and
  pastes back what was printed. Give exact commands to copy, one step at a time, and say what each should print.
  If a file needs editing for a test, edit it yourself and say how it will be put back.
- **Keep builds short.** One implementer, tests first, only the suites the change touches while working, the full
  run once, one focused review. A small fix after that review is read by whoever is coordinating, not sent round
  again. Minor findings go on a list.
- **Say what is not verified.** A report that separates "ran and passed" from "read and looks right" from "not
  tried" is worth more than a confident one.
- **`main` is public and never rewritten.** Work on a branch, wait for CI, then fast-forward.
