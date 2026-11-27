# Getting started

From nothing to a local WordPress with a checked, committed static copy of it. Steps 7 and 8 then put that copy on the
web, and let WordPress ask for a publish by itself. Each step is one command and what you should see. The detail
behind every step is in [reference.md](reference.md).

## Before you start

On your Mac (Offprint runs on macOS only):

- [ ] git, with `user.name` and `user.email` set
- [ ] php 8.1 or newer (`brew install php`; the tool's own PHP tests need 8.3)
- [ ] Docker with Compose, running (Docker Desktop is what Offprint has been used with; other set-ups are untried)
- [ ] mkcert (`brew install mkcert`), with `mkcert -install` run once
- [ ] age (`brew install age`), which encrypts the database backup
- [ ] an administrator account, for the one `sudo` step

To publish to the web, also:

- [ ] a private GitHub repository for the site, and GitHub's `gh`, signed in (`gh auth login`), so that a publish can
      check the repository is private (without `gh` it only warns)
- [ ] for Cloudflare Workers: a Cloudflare account, and node 22.12.0 or newer, with its npm

## The steps

1. **Get Offprint.** In a folder that is not inside any site:

   ```sh
   git clone https://github.com/richardtape/offprint.git
   ```

   `offprint` below is `bin/offprint` in that copy. Run it by its path, or put a link to it in a folder on your PATH
   (it follows the link to find the rest of the tool).

2. **Make a site folder.** Settle the public address first: every link in the published copy points there.

   ```sh
   offprint new mysite --public-url https://www.example.com
   cd mysite
   ```

   You should see "Made mysite: a git repository on main, holding site.json and .gitignore", the addresses and ports
   it picked, and the commands that are left. Every later step runs in this folder.
   ([What it picks, and what it refuses](reference.md#new-what-it-picks).)

3. **Set up the Mac for it.** This is the one step that runs as root, and you run it yourself.

   ```sh
   offprint host-setup --print     # shows every change, and changes nothing
   offprint host-setup             # prints the sudo line: run that line
   ```

   Do this before you make another site: until then, this site's address and ports are not taken on the Mac.
   ([What it changes](reference.md#the-one-privileged-step).)

4. **Make the local WordPress.**

   ```sh
   offprint setup-wp
   ```

   It asks for an admin user name, email address and password. You should see a line for each thing it tidies (the
   Sample Page deleted, the plugin committed as "Offprint's plugin", any plugins WordPress's image added and the
   command that deletes them), ending with
   "Done: https://mysite.local/  (admin: https://mysite.local/wp-admin/)".

5. **Give the site a backup key.** A publish refuses without one.

   ```sh
   age-keygen
   ```

   It prints a private key (`AGE-SECRET-KEY-…`) and its public key (`age1…`). Keep the private key in your password
   manager, not on this Mac alone. Add the public one to `site.json`, and commit `site.json`:

   ```json
   "backup": {"recipients": ["age1…"]}
   ```

   ([The database backup](reference.md#the-database-backup).)

6. **Publish, locally.**

   ```sh
   offprint publish --dry-run      # exports and checks the site, changing nothing else
   offprint publish --no-push      # commits it
   ```

   You now have the static copy in `site/`, committed with `wp-content/` and the encrypted backup. If a check refuses,
   it names the page and says what to do.

7. **Publish to the web.** Give the site an `origin` it can push to: a private repository, as a publish refuses a
   public one.

   ```sh
   gh repo create mysite --private --source=. --remote=origin
   offprint publish
   ```

   With no host set up, it ends "[saved] Committed and pushed ...". To publish to Cloudflare Workers, add an `adapter`
   block to `site.json` naming the Worker (the one `public_url` is the address of; a publish makes it if there is none
   of that name) and your account's id, and commit it:

   ```json
   "adapter": {"name": "cloudflare-workers", "worker": "my-site", "account_id": "0123456789abcdef0123456789abcdef"}
   ```

   ```sh
   offprint adapter setup          # asks before each step; you paste the API token at its prompt
   offprint adapter doctor         # one ok or problem line for each check
   offprint publish
   ```

   Until the first publish, doctor's lines about `offprint.json` and `/feed/` are problems: a publish writes both.
   The publish ends "The site is live at ..." (a first publish to a new Worker takes about 20 seconds), or with
   Cloudflare's reason and what to do. ([Publishing to Cloudflare Workers](reference.md#publishing-to-cloudflare-workers);
   for another host, [a site's own adapter](reference.md#a-sites-own-adapter).)

8. **Let WordPress ask for a publish.**

   ```sh
   offprint install-agent          # as you, not with sudo
   ```

   From then on, publishing or changing a post or page in wp-admin publishes the site. Anything else (menus, widgets,
   themes, settings) waits for the Publish Site button in the admin bar, which also shows how each publish went.
   ([The launchd agent](reference.md#the-launchd-agent).)

## Next

- `offprint backup verify`, once, after your first publish: it is how you find out a backup is no use before the day
  you need it.
- Moving an existing WordPress in: [Bringing an existing WordPress's database into a site](reference.md#bringing-an-existing-wordpresss-database-into-a-site).
- `offprint help` lists every command.
