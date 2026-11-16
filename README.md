# release-switch

Zero-downtime deploys with release folders, for several PHP projects on one server.
One script (`deploy`) does the parts every project shares. Each project keeps its own steps in a
`deploy.conf` file in its repo.

## How it works

Each project has a base folder on the server:

```
<base>/
  releases/<UTC date>-<time>-<tag>-<short sha>/   one full copy of the code per deploy
  shared/                                         files that live across releases (.env, uploads, a database file)
  current -> releases/<name>                      the live release; the web server serves current/public
  deploy.log                                      one line per deploy and rollback, with the result
```

`deploy <project>`:

1. stops if deploys are frozen (see `freeze`);
2. takes a lock, so two deploys of one project never run at once. A lock left by a deploy that
   died (its process is gone) is removed, and so is a lock with no owner that is older than
   60 seconds (a deploy died while taking it). The removal is safe when two deploys race for it;
3. stops if the newest commit of the branch is already live, so no empty release pushes a good one
   out (`--force` builds it anyway);
4. clones the newest commit of the branch into `releases/.building-<stamp>`, renames it to its
   final name with a `.building` file in it, and writes its name to `RELEASE` in the release root.
   The build runs under the final name, as Laravel caches keep absolute paths; the `.building`
   file goes right before the switch. A commit under 5 minutes old with no release tag yet, in a repo
   that has release tags, waits up to `RELEASE_WAIT` seconds for its tag (see below);
5. links the project's `SHARED` paths from `shared/` into the release, and copies its
   `COPY_FROM_LIVE` paths (like `vendor`) from the live release, so the build only updates them;
6. runs the project's `preflight`, `build` and `verify` steps there;
7. switches `current` to the new release in one rename, then runs `PHP_RELOAD_CMD` and `after_switch`;
8. waits until `CHECK_URL` answers 200 with the new release name in the `X-App-Version` header.
   If it does not, it switches back and sets the new release aside as `releases/.failed-<name>`;
9. deletes all but the last `KEEP_RELEASES` releases, and any `.failed-*` folder. It always keeps
   the release that was live before this deploy, since requests may still run in it; that one can
   go on the next deploy.

If a step before the switch fails, the new folder is deleted and the old release stays live.
A deploy stopped by Ctrl-C, `kill` or a dropped SSH session (INT, TERM, HUP) cleans up the same
way and exits with 130, 143 or 129. A build killed hard (SIGKILL, OOM) keeps its `.building` mark:
it is never listed or rolled back to, and the next deploy or rollback removes it. Once `current` points at the new release, it is never deleted:
it stays live, and the log says at which stage the deploy stopped.
Migrations and other data changes are not undone by a switch back or a rollback.
Every deploy and rollback, and how it ended, goes to `deploy.log` (see `deploy <project> log`).
A deploy also lists the commits it ships, in its output, the log and the alert.

Release names are in UTC, so they sort the same all year. The tag (`v2026.11.21`) is left out when
the commit has none.

The release workflow tags a merge a few seconds after it lands, so a deploy right after a merge
checks `git ls-remote` every 5 seconds until the tag is there, and shows how long it has waited
(`Waiting for the release tag on abc1234 (25 s of 90)`). It waits only when the commit is under
5 minutes old and the repo already has `v*` tags; a repo without them never waits. If no tag comes
within `RELEASE_WAIT` seconds, or the commit is older, the deploy goes on without a tag and warns.
`deploy --no-wait` skips the wait once, `RELEASE_WAIT=0` turns it off. `--ref` and `--pr` never
wait: they deploy a commit picked by hand.

A `no-release` merge never gets a tag. git can't see pull request labels, so the release workflow
marks such a merge with a ref `refs/no-release/<merge sha>` (not a tag) and keeps only the newest
20 markers. When the commit has a marker, the deploy stops waiting at once and says
`no-release merge; deploying without a tag`. To get this in a project repo, copy the
`no-release-marker` job from this repo's `.github/workflows/release.yml` into the project's release
workflow. It needs `contents: write` and the default `GITHUB_TOKEN`, nothing else. Without the job,
a deploy after a `no-release` merge waits the full `RELEASE_WAIT`, as before.

## Commands

```
deploy [project] [command]

Staging (see [Staging](#staging)):
  staging [project]                 List the slots. Without a project: the only one with slots
  staging <project>@sN              The slot's status
  staging <project> checkout <branch> | --pr <number>
                                    Deploy to the slot on that branch, else a free one, else
                                    one whose branch is gone; print its URL
  staging <project>@sN checkout <branch> | --pr <number>
                                    Make this slot follow it and deploy it
  staging <project>@sN update       Deploy the newest commit of the slot's branch
  staging <project> update          Redeploy every slot with new commits (for cron)
  staging <project>@sN free         Forget the slot's branch, deploy DEPLOY_BRANCH
  staging <project>@sN copy-from <project> [--yes] [path ...]
                                    Copy production's SHARED data into the slot
  staging <project>@sN status | log | path | rollback | down | up

Commands:
  deploy [--force]  Build the newest commit and switch to it (the default). Stops if that commit
                    is already live, unless --force. On a terminal --force asks first
  deploy --no-wait  Do not wait for the release tag of a new commit
  deploy --ref <ref>
                    Deploy a tag, branch or commit instead, e.g. --ref v2026.11.18, to go back
                    to a release that rollback no longer keeps. Stops if it is already live.
                    Never waits for a release tag
  deploy --branch <name>
                    On a staging slot only: follow that branch from now on and deploy it
                    (see [Staging](#staging))
  deploy --pr <number>
                    On a staging slot only: follow the head of that pull request from now on
                    and deploy it (see [Staging](#staging))
  freeze [reason]   Refuse deploys and rollbacks until unfreeze, e.g. during a hosting move.
                    status, status --all and check show it
  unfreeze          Allow deploys again
  down [reason]     Run the down() step of the live release, e.g. to show a maintenance page
                    during a risky data change. Until up, deploys and rollbacks do not check
                    the site, check accepts a 503 and skips health(), and status shows it.
                    On a terminal it asks first
  up                Run the up() step, then check that the site serves the live release again
  status            The live release, the rollback target, the commits not deployed yet, all
                    releases, the lock, the disk and the site
  status --all      One line per project: live release, deploy time, site check, lock, pending
                    commits and failed releases. A last line shows the engine: its version, and
                    whether the repo has newer ones (run `deploy self`) or it has local changes.
                    Exits with 1 if any site does not serve its live release, so it can run from
                    cron as a simple monitor. Pending commits come from
                    the repo: a quick check, plus a commits-only clone when there are any.
                    Production only: staging slots are not listed
  rollback [name]   Go to the previous good release, and mark the live one bad, so the next
                    rollback skips it. With a name, go to that release instead (a full name, or
                    any part only one release has: date and time, sha, tag); this marks nothing,
                    and clears the mark if that release had one. On a terminal it asks first
  check             A quick health check that changes nothing: the live release, its shared
                    links, the project's health() step, the site, the disk (size of the base
                    folder past DISK_LIMIT, or free space under MIN_FREE_MB), and a lock held
                    for 30 min or more, or with no owner for 60 s. Problems go to stderr
                    and it exits with 1, so `deploy <project> check > /dev/null` in cron mails
                    only problems
  check --all       The same for every project, production only
  log [count]       The last deploys and rollbacks, with results, times and the commits each
                    deploy shipped (20 by default)
  path [--base]     Print the full path of the live release, and nothing else, to copy or use
                    in `cd "$(deploy path <project>)"`. --base prints DEPLOY_BASE instead.
                    Fails if there is no live release. Also works as `deploy path <project>`
  slots             One line per staging slot: its branch (PR #N, or `free (develop)`; `(gone)`
                    when the repo no longer has it), live commit, deploy time and URL
  slots update      Redeploy each slot whose branch has new commits, free slots from
                    `DEPLOY_BRANCH`; skip a slot whose branch is gone. For cron (see
                    [Staging](#staging))
  stage <branch>    Deploy a branch to the slot that already follows it, else to the first free
                    slot, else to one whose branch is gone, and print its URL last. Also
                    `stage --pr <number>`
  free              On a staging slot only: forget its branch, so `stage` can use the slot,
                    and deploy the newest `DEPLOY_BRANCH` to it
  copy-from <project> [--yes] [path ...]
                    On a staging slot only: copy production's `SHARED` data into the slot,
                    every path but `.env`, or only the named ones. Asks first; `--yes` skips
                    the question (see [Staging](#staging))
  init <checkout>   Move the SHARED paths of an existing checkout into shared/
                    and link them back (add --dry-run to only show what it would do)
  self-update       Update the engine itself: a fast-forward git pull of its own folder. Shows
                    the old and new versions, then each new release with its GitHub notes (or
                    its commits when `gh` cannot read them) and the commits not released yet.
                    Stops if the folder has local changes. Short form: self
  self log [count]  The engine's last commits (10 by default) with times, and any not pulled yet
  help [command]    Commands and the settings in effect, or the help of one command
  --version         The engine's version: its newest release tag, like v2026.11.1, with "+N" when
                    it is N commits past it
```

`project` is the name of a file in `projects/` (`projects/tarasov.env` is `tarasov`).
It can be left out when there is only one. A staging slot is `<project>@sN`, like `tarasov@s1`,
and takes the same commands: `deploy tarasov@s1 status`, `deploy path tarasov@s1`.

`deploy <command> --help`, `deploy <command> -h` and `deploy help <command>` show the help of one
command: its usage, options and examples. A project in front works too: `deploy tarasov rollback --help`.
A mistyped command prints one line with the closest command, like
`Unknown command: rolback. Did you mean rollback?`, and exits with 2. The same goes for the
`staging` subcommands: `deploy staging checkout --help`, and
`Unknown staging command: chekout. Did you mean checkout?`.

### Questions before risky commands

`rollback`, `down` and `deploy --force` change the live site, so on a terminal they first show what
will happen and ask `y/N`: `rollback` shows the live release and the one it goes to, `down` the
reason and that the site will show its maintenance page, `deploy --force` the commit it builds. Only
`y` goes on; `n` or an empty answer does nothing and exits with 0. `--yes` (or `-y`) skips the
question. Without a terminal (cron, pipes, `slots update`, `stage`) they never ask and run as before.
`copy-from` asks the same way.

## Setup on a server

The repos are private. A GitHub deploy key works for one repo only, so each repo gets its own key,
named `<repo>_deploy`, and its own host name in `~/.ssh/config`.

1. Make a key for this repo and print it:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/release_switch_deploy -N "" -C "release-switch"
   cat ~/.ssh/release_switch_deploy.pub
   ```

   Add it in GitHub under this repo's **Settings → Deploy keys**, with write access off.

2. Give the key a host name, at the end of `~/.ssh/config`:

   ```text
   Host github-release-switch
       HostName github.com
       IdentityFile ~/.ssh/release_switch_deploy
       IdentitiesOnly yes
   ```

   Check it:

   ```bash
   git ls-remote git@github-release-switch:ivan-tarasov/release-switch.git HEAD
   ```

3. Install the script:

   ```bash
   git clone git@github-release-switch:ivan-tarasov/release-switch.git ~/release-switch
   ```

4. Add the alias to `~/.bashrc`, then `source ~/.bashrc`:

   ```bash
   alias deploy="$HOME/release-switch/deploy"
   ```

   Keep the settings in the project files, not in the shell profile: an env var wins over every
   project file, so a `PHP_BIN` there would apply to all projects.

5. Add each project (see below), then check with `deploy --help` and `deploy <project> status`.

To update the script: `deploy self-update` (or `git -C ~/release-switch pull`). Files in
`projects/` other than `example.env` are not tracked, so a pull never touches them.

### Adding a project

1. Give the server read access to the project's repo, as in steps 1 and 2 above: a key
   `~/.ssh/<repo>_deploy`, added under that repo's **Deploy keys**, and a `Host github-<repo>`
   entry. Check it with `git ls-remote git@github-<repo>:owner/<repo>.git HEAD`.
2. Add a `deploy.conf` to the project's repo (see [deploy.conf](#deployconf)), and make the project
   send the `X-App-Version` header, or set `CHECK_VERSION=0` for now.
3. Write the project file:

   ```bash
   cp ~/release-switch/projects/example.env ~/release-switch/projects/<project>.env
   ```

   Set `DEPLOY_BASE`, `CHECK_URL` and `REPO_URL` (`git@github-<repo>:owner/<repo>.git`), plus
   `PHP_BIN` and `COMPOSER_BIN` if the default `php` is not the one the project needs.
   See [Settings](#settings).

If the base folder already has `releases/`, `shared/` and `current` (from an older copy of this
script), that is all: run `deploy <project>`. Otherwise, move the project in first:

#### Moving a project from a plain checkout

1. Make sure the project's repo has a `deploy.conf` on the deploy branch.
2. `deploy <project> init <checkout> --dry-run`, then without `--dry-run`. This moves the `SHARED`
   paths into `<base>/shared/` and links them back, so the old checkout keeps working.
3. `deploy <project>` builds the first release.
4. Point the web root at `<base>/current/public` (or replace it with a link to it), and point cron
   at `<base>/current`.

## Settings

Set in `projects/<project>.env` (plain `KEY=value` lines, read by bash) or as env vars, which win.

| Setting | Default | What it is |
| --- | --- | --- |
| `DEPLOY_BASE` | (required) | The project's base folder |
| `CHECK_URL` | (required) | A page that must answer 200 with the new version after the switch |
| `REPO_URL` | origin of `current` | Repo to clone |
| `DEPLOY_BRANCH` | `develop` | Branch to deploy |
| `KEEP_RELEASES` | `5` | Releases to keep. At least `2`: the live release and one to roll back to |
| `CHECK_WAIT` | `150` | Seconds to wait for `CHECK_URL`. PHP's realpath cache can keep serving the old release for up to 120 s |
| `RELEASE_WAIT` | `90` | Seconds to wait for the release tag of a commit under 5 minutes old. `0` to never wait |
| `CHECK_VERSION` | `1` | `0` to only wait for a 200, for a project that cannot send `X-App-Version` yet |
| `PHP_BIN` | `php` | PHP binary, for the project's steps |
| `COMPOSER_BIN` | `composer` | Composer command, e.g. `php ~/composer.phar` |
| `PHP_RELOAD_CMD` | none | Run after each switch to reset OPcache, e.g. `touch ~/tmp/restart.txt`. Stopped after 60 s with a warning |
| `STEP_TIMEOUT` | `600` | Seconds a `deploy.conf` step (including `health()`, `down()` and `up()`) may run. A step that runs longer is stopped with all it started, and fails like any failed step. `0` for no limit |
| `DISK_LIMIT` | none | Largest size of the base folder, like `2G`, `500M`, `1.5G` or plain bytes. `check` fails when the folder is bigger; a deploy only warns, as prune may bring it back down. On cPanel the account quota can differ from `df`, so set it yourself |
| `MIN_FREE_MB` | `500` | Free space in MB the disk of the base folder must have. `check` fails under it, and `deploy` and `copy-from` stop before they write anything. `0` to turn it off |
| `DISPLAY_TZ` | UTC | Time zone for deploy times in `status` and `log`, e.g. `America/Toronto`. `status` says "today at" and "yesterday at" for recent deploys. Release names stay in UTC |
| `NOTIFY_URL` | none | Webhook for alerts. Gets a POST with JSON (see [Alerts](#alerts)) |
| `NOTIFY_CMD` | none | Command for alerts, run with `sh -c`. The text is in `$NOTIFY_TEXT`, the event in `$NOTIFY_EVENT` (see [Alerts](#alerts)). Stopped after 30 s with a warning |
| `NOTIFY_ON` | problems | `problems`, or `all` to also send successful deploys |
| `STAGING_SERVERS` | `0` | Number of staging slots, `s1` to `sN` (see [Staging](#staging)) |
| `STAGING_URL` | `sN.` before the host of `CHECK_URL` | Slot URL, with `{slot}` for `s1`, `s2`, ... e.g. `https://user:pass@{slot}.example.com/` |

### Alerts

With `NOTIFY_URL` or `NOTIFY_CMD` set, the engine sends an alert when a deploy or rollback fails,
when a rollback runs, and when the result of `check` changes (once when it fails, once when it is
ok again, so a cron check does not repeat itself). An alert that cannot be sent only warns.
The alert goes out even when `deploy.log` cannot be written (a full or read-only disk). A missing
base folder is a `check` problem too; `check` never makes the folder, and keeps its state in
`projects/.<project>.check-failed` until the folder is back.

URLs in output, `deploy.log` and alerts hide their user and password: `https://user:token@host`
shows as `https://***@host`. SSH URLs like `git@github.com:owner/repo.git` stay as they are.

`NOTIFY_URL` suits Slack-style incoming webhooks, which show the `text` field. `NOTIFY_CMD` covers
anything else, like local mail:

```bash
NOTIFY_CMD='printf "%s\n" "$NOTIFY_TEXT" | mail -s "deploy alert" you@example.com'
```

`NOTIFY_URL` gets JSON like this. `status` is `ok`, `failed`, `rolled back` (a rollback, or a deploy
whose check failed and switched back) or `problem` (a failed `check`). `commits` lists up to 20
commits the deploy ships, newest first, with full shas, and is empty when unknown. `check` alerts
only fill `project`, `event`, `status`, `release` (the live one) and `duration`.

```json
{
  "text": "shop: deploy 20261114-101500-v1.4.0-a1b2c3d: ok (42s)\n2 commit(s):\n  a1b2c3d Fix the cart\n  e4f5a6b Add coupons",
  "project": "shop",
  "event": "deploy",
  "status": "ok",
  "release": "20261114-101500-v1.4.0-a1b2c3d",
  "previous": "20261113-170200-v1.3.9-9f8e7d6",
  "sha": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
  "ref": "main",
  "duration": 42,
  "commits": [
    {"sha": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", "subject": "Fix the cart"},
    {"sha": "e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3", "subject": "Add coupons"}
  ]
}
```

`NOTIFY_CMD` gets `NOTIFY_EVENT`, `NOTIFY_TEXT`, `NOTIFY_PROJECT`, `NOTIFY_STATUS`, `NOTIFY_RELEASE`
and `NOTIFY_DURATION` (seconds), plus the `DEPLOY_*` variables in [deploy.conf](#deployconf).

For alerts on a down site, run `check` from cron. The alerts do the telling, so cron mail is off:

```cron
*/5 * * * * $HOME/release-switch/deploy check --all > /dev/null 2>&1
```

## Staging

A project can have staging slots: small copies of the site next to production, each running a
branch you pick. `STAGING_SERVERS=2` in the project file gives `s1` and `s2`.

Each slot is a full deployment of its own, in the domain folder next to production. With
`DEPLOY_BASE="$HOME/domains/example.com/www"`, slot `s1` lives in `$HOME/domains/example.com/s1`,
with its own `releases/`, `shared/`, `current`, `deploy.log` and lock. A slot keeps 2 releases,
does not wait for release tags and sends no alerts. Its URL is `sN.` before the host of
`CHECK_URL` (`https://example.com/` gives `https://s1.example.com/`); set `STAGING_URL` with
`{slot}` for anything else.

To set up a slot:

1. In cPanel, add the subdomain `s1.example.com` with the document root
   `domains/example.com/s1/current/public`.
2. Make the slot's shared files: every `SHARED` path of `deploy.conf` must exist in
   `$HOME/domains/example.com/s1/shared/`, as for a first production deploy. Production's `.env`
   is never copied. Give the slot its own `shared/.env`, with its own `APP_URL`
   (`https://s1.example.com`), `APP_ENV=staging`, its own database, and mail to the log
   (`MAIL_MAILER=log`).
3. Deploy a branch to it: `deploy staging example@s1 checkout feature/login`. The slot stores the
   branch in `s1/BRANCH` and deploys it. Or deploy it with no branch,
   `deploy staging example@s1 update`: a free slot runs production's `DEPLOY_BRANCH`.

All slot work goes through `deploy staging <project>[@sN] <command>`:

```
deploy staging example                              list the slots
deploy staging example checkout feature/login       pick a slot for the branch, print its URL
deploy staging example checkout --pr 281            the same for a pull request
deploy staging example@s1 checkout feature/login    this slot, that branch
deploy staging example@s1 checkout --pr 281         this slot, that pull request
deploy staging example@s1 update                    the newest commit of the slot's branch
deploy staging example update                       every slot with new commits
deploy staging example@s1 free                      forget the branch, back on DEPLOY_BRANCH
deploy staging example@s1 copy-from example         production data in
deploy staging example@s1                           the slot's status
deploy staging example@s1 log | path | rollback | down | up
```

With one project with slots, the project can be left out: `deploy staging`,
`deploy staging checkout feature/login`. The older forms still work the same: `deploy example slots`,
`deploy example stage <branch>`, `deploy example@s1 --branch <name>` or `--pr <number>`, a plain
`deploy example@s1`, `deploy example slots update`, and `deploy example@s1 <command>` for any other
command (`check` and `freeze` too).

From then on, `deploy staging example@s1 update` deploys the newest commit of that branch, and
stops when it is already live. `checkout` again switches the slot to another branch.
`deploy staging example` lists the slots, with `free (develop)` for a free slot (`DEPLOY_BRANCH` is
`develop`), or `free` and `-` for one never deployed. `--branch` on production is refused:
production deploys `DEPLOY_BRANCH`.

To test a pull request before merge, deploy its head: `deploy staging example@s1 checkout --pr 281`.
It uses plain git (`refs/pull/281/head` from `REPO_URL`), no GitHub token. The slot stores `pr/281`
in `s1/BRANCH`, so `deploy staging example@s1 update` fetches the PR head again and picks up new
commits on the PR. The
release name has `pr281` in place of a tag (`20261114-101500-pr281-abc1234`), and the slot list shows
`PR #281`. `--pr` is refused on production, and together with `--branch` or `--ref`. Neither
`--pr` nor `--ref` waits for a release tag.

### Sharing the slots

`deploy staging example checkout feature/login` picks a slot for you: the one that already follows
`feature/login`, else the first free one (no `BRANCH` file). It deploys the branch there, as
`deploy staging example@sN checkout feature/login` would, and prints the slot's URL as the last
line. `deploy staging example checkout --pr 281` does the same for a pull request. With no free slot, it takes the
first slot whose branch is gone from the repo, and says which branch it replaces. When all slots
are busy, it fails and shows the slot list. It takes each slot under the slot's lock, so two
`checkout` runs at once never pick the same slot.

`deploy staging example@s1 free` forgets the slot's branch, so `checkout` can use it again, and
deploys the newest commit of `DEPLOY_BRANCH` to it, so a free slot always runs something current.
The slot stays free (no `BRANCH` file), and `deploy staging example@s1 update` keeps it on the
newest `DEPLOY_BRANCH`. It takes the slot's lock, so it never runs during a deploy of the slot.

The slot list marks a branch the repo no longer has (deleted after the merge) as `feature/x (gone)` or
`PR #7 (gone)`, from one `git ls-remote` for all slots. When the repo cannot be read, it marks
nothing.

`deploy staging example update` redeploys each slot whose branch or PR head has new commits, and each
free slot whose `DEPLOY_BRANCH` has; a slot with nothing new is left as it is. A free slot never
deployed gets its first release, so give each slot its shared files before adding it to
`STAGING_SERVERS`. A slot whose branch is gone is skipped and keeps its branch until `free` or
`checkout` reuses it; that is not a failure. A failing slot does not stop the others, but the run
exits with 1. It ends with one line per slot: `updated`, `deployed`, `unchanged`, `branch gone` or
`failed`. Run it from cron to keep the slots up to date:

```cron
*/5 * * * * $HOME/release-switch/deploy staging example update > /dev/null
```

### Copying production data

`deploy staging example@s1 copy-from example` copies production's data into the slot: each `SHARED` path
from production's `shared/` into the slot's `shared/`, except `.env` (and any `*.env` or `.env.*`),
so the slot keeps its own settings. Name paths to copy only those:
`deploy staging example@s1 copy-from example database/database.sqlite`. Each must be in `SHARED`, and
`.env` is always refused. `SHARED` comes from the slot's live `deploy.conf`, or production's when
the slot has no live release yet; the output says which.

It lists what it will copy, with sizes, and asks `y/N` first. `--yes` skips the question; without a
terminal (a pipe or cron) `--yes` is required. It copies from production of the same project only,
never from another project or a slot, and never into production. Production's files are only read.
It holds the slot's lock for the whole copy. Each path is copied to a temp name next to it and then
renamed into place, so a failed copy never leaves half a file; a path missing in production keeps
the slot's own, with a warning. The slot's `deploy.log` gets a `copy-from` line.

A SQLite file is a safe copy only while production is idle: a write during the copy can leave the
copy broken. For MySQL or Postgres this copies files only (like `storage/`), not the database.

The steps of `deploy.conf` see `DEPLOY_SLOT` (`s1`, empty in production) and `DEPLOY_HOST` (the
host of the check URL, like `s1.example.com`), e.g. to skip a step on staging:

```bash
after_switch() {
    [ -z "$DEPLOY_SLOT" ] || return 0
    "$PHP_BIN" artisan queue:restart
}
```

## deploy.conf

A bash file in the project's repo root. The engine reads it from the release it is building, so the
steps change together with the code. Every step runs in the release folder, with `set -e`.

```bash
# Paths under the release that live in shared/ instead.
SHARED=(.env storage database/database.sqlite)

# Optional. Paths copied from the live release before the build, so Composer only installs what
# changed. A copy, never a link, so the build cannot touch the live site. Paths the repo tracks are
# skipped.
COPY_FROM_LIVE=(vendor)

# Optional. Stop before building, e.g. when .env points at the wrong host.
preflight() {
    grep -q '^APP_URL=https://example.com' .env
}

# Required.
build() {
    read -ra composer <<< "$COMPOSER_BIN"
    "${composer[@]}" install --no-dev --optimize-autoloader --no-interaction
    "$PHP_BIN" artisan migrate --force
}

# Optional. Must fail if the release cannot run.
verify() {
    "$PHP_BIN" artisan about > /dev/null
}

# Optional. Runs in the new release right after the switch. A failure is only a warning.
after_switch() {
    "$PHP_BIN" artisan cache:forget sitemap.xml
}

# Optional. Run by `check` (and so by the cron check) in the live release. A non-zero exit is a
# problem, and an alert if alerts are on. The last line it prints shows in the check.
health() {
    "$PHP_BIN" artisan db:show > /dev/null 2>&1 || {
        echo "the database does not answer"
        return 1
    }
    echo "database ok"
}

# Optional. Run by `down` and `up` in the live release. $DOWN_REASON holds the reason for down.
# The flag must live in shared/ (Laravel keeps it in storage/), so a deploy while down stays down.
down() {
    "$PHP_BIN" artisan down --retry=60
}

up() {
    "$PHP_BIN" artisan up
}
```

The steps can use `DEPLOY_BASE`, `RELEASE_DIR`, `RELEASE_NAME`, `PHP_BIN`, `COMPOSER_BIN`,
`DEPLOY_SLOT` and `DEPLOY_HOST`, and these details of the run (also in `NOTIFY_CMD`). They are empty
when unknown:

| Variable | deploy | rollback | down, up | check |
|---|---|---|---|---|
| `DEPLOY_SHA` | full sha of the new release | sha of the target release | sha of the live release | empty |
| `DEPLOY_REF` | the branch, `pr/<N>`, or the `--ref` value | empty | empty | empty |
| `DEPLOY_PREVIOUS_RELEASE` | release live before (empty on the first deploy) | release live before | empty | empty |
| `DEPLOY_AUTHOR` | author name of the commit | author of the target's commit | author of the live commit | empty |
| `DEPLOY_MESSAGE` | subject of the commit | subject of the target's commit | subject of the live commit | empty |
| `DEPLOY_PERFORMER` | user who ran it | user who ran it | user who ran it | user who ran it |
| `DEPLOY_FORCED` | `1` with `--force`, else `0` | `0` | `0` | `0` |

Their input is empty, so a command that asks a question gets no
answer instead of waiting. Each step has `STEP_TIMEOUT` seconds.

Git calls to the repo fail fast on a dead network: no password prompt, a 10 s SSH connect timeout,
and a stop when the transfer stalls for 30 s. Your own `GIT_SSH_COMMAND` or `core.sshCommand` keeps
its options, and `GIT_HTTP_LOW_SPEED_LIMIT`/`GIT_HTTP_LOW_SPEED_TIME` win when set.

The project must send the release name as a header, so the check knows the new code is live:

```php
header('X-App-Version: ' . trim((string) @file_get_contents(__DIR__ . '/../RELEASE')));
```

So a page cache (like LiteSpeed LSCache) does not answer with the old version, each request to
`CHECK_URL` adds an `rs=<release or time>` query and sends `Cache-Control: no-cache` and
`Pragma: no-cache`. A CDN that ignores query strings needs a rule to bypass its cache when `rs` is set.

### Output

In a terminal, each command runs on rails, like this:

```
┌  release-switch v2026.11.1 · tarasov · deploy
│
◇  Cloning develop
◇  Running build
│  (the step's own output)
◇  Deployed 20261112-195410-v2026.11.4-55fc7c8
│
└  Done in 42s
```

A failure is marked with `■` on stderr and ends with `└  Failed after Ns`. In a pipe or cron, the
output stays plain (`==> ...` lines, errors as `deploy: ...`), so scripts and mail stay clean.
`DEPLOY_RAILS=1` forces the rails, `DEPLOY_RAILS=0` turns them off. `NO_COLOR` turns off colors.

## Tests

`tests/run.sh` deploys a tiny PHP project (`tests/fixture/`) in a temp folder with `php -S`: init,
deploys, rollbacks and bad releases, copies from the live release, failing builds and checks, `status`
with pending commits, the rails and `--version`, `check`, alerts, `self-update`, skipped deploys, `freeze`, `down` and `up`, `--ref`, the wait for a release tag, the no-release marker and `--no-wait`, shipped commits, `self log`, `health()`, the log, the lock, stale locks, locks with no owner and two runs racing for a stale lock,
`PHP_RELOAD_CMD`, `STEP_TIMEOUT` and git timeouts, `DISK_LIMIT` and `MIN_FREE_MB`, a signal after the switch, a rollback with the live folder missing, prune and
`KEEP_RELEASES`, staging slots with their branch, folder, URL and `slots` list, `stage`, `free`, `slots update` and `copy-from`, and that shared
files survive.
It needs bash, PHP 8.1+, git and curl. There is no CI for now: run it and
`shellcheck deploy tests/run.sh` before a pull request.

## Pull requests and releases

Open pull requests into `main`, as drafts until they are ready.

Every pull request needs:

- **Title:** `Fix:`, `Update:`, `Feature:` or `Design:`, then `` `Component` – short phrase `` (en dash).
  Example: ``Feature: `Deploy` – down and up for maintenance mode``.
- **One release label:** `release:major`, `release:minor` (new functionality),
  `release:patch` (fix or internal change; the default) or `no-release` (docs, CI, chores).
- **An assignee.**
- **Body:** `## Description`, `## Changes` and `## Release note` (1–3 sentences, or `None`).

The PR rules workflow checks this once a pull request is ready. It is not a required check. To check
by hand:

```bash
PR=<N> GITHUB_REPOSITORY=ivan-tarasov/release-switch node scripts/pr-check.mjs
```

When a pull request merges into `main`, the Release workflow tags the merge commit and makes a
GitHub release with generated notes. A `no-release` pull request gets no tag, only a
`refs/no-release/<merge sha>` marker (see above).
The version is `vYEAR.MONTH.COUNT` from the merge date in UTC: the first release of November 2026
is `v2026.11.1`, the next `v2026.11.2`. `deploy self` pulls the tags with the code, and
`deploy --version` shows the one in use.
