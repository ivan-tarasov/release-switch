# release-switch

Zero-downtime deploys with release folders, for several PHP projects on one server.
One script (`deploy`) does the parts every project shares. Each project keeps its own steps in a
`deploy.conf` file in its repo.

If something fails, see [Troubleshooting](#troubleshooting).

## Quick start

Once the server can read the project's repo (see [Setup on a server](#setup-on-a-server)):

1. Install the engine and add the `deploy` alias:

   ```bash
   git clone git@github-release-switch:ivan-tarasov/release-switch.git ~/release-switch
   echo 'alias deploy="$HOME/release-switch/deploy"' >> ~/.bashrc && source ~/.bashrc
   ```

2. Add the project file and set `DEPLOY_BASE`, `CHECK_URL` and `REPO_URL` in it. Add a
   `deploy.conf` with at least a `build()` step to the project's repo (see [deploy.conf](#deployconf)).

   ```bash
   cp ~/release-switch/projects/example.env ~/release-switch/projects/<project>.env
   ```

3. Move the existing checkout in, then deploy:

   ```bash
   deploy <project> init <checkout> --dry-run
   deploy <project> init <checkout>
   deploy <project>
   ```

   A project with no checkout yet skips `init`; create its `SHARED` paths in `<base>/shared/` first.

Then `deploy <project> status` shows the live release, and a bare `deploy` on a terminal opens a menu
of every project (see [Project menu](#project-menu)). To deploy from cron and get mail only on
problems:

```cron
*/10 * * * * $HOME/release-switch/deploy <project> --quiet
```

## How it works

Each project has a base folder on the server:

```
<base>/
  releases/<UTC date>-<time>-<tag>-<short sha>/   one full copy of the code per deploy
  shared/                                         files that live across releases (.env, uploads, a database file)
  current -> releases/<name>                      the live release; the web server serves current/public
  deploy.log                                      one line per deploy and rollback, with the result
  deploy-failed.log                               the output of the last step that failed
  .skip-commits                                   commits a plain deploy skips (see step 3 below)
```

`deploy <project>`:

1. stops if deploys are frozen (see `freeze`);
2. takes a lock, so two deploys of one project never run at once. A lock left by a deploy that
   died (its process is gone) is removed, and so is a lock with no owner that is older than
   60 seconds (a deploy died while taking it). The removal is safe when two deploys race for it;
3. stops if the newest commit of the branch is already live, so no empty release pushes a good one
   out (`--force` builds it anyway). It also stops, with exit 0, if that commit failed its site
   check (the deploy switched back) or was rolled back by a plain `rollback`, so cron does not
   break the site again every run. `--force` and `--ref` build it anyway; a good deploy of the
   branch tip (plain or `--force`, not `--ref`) clears the list in `.skip-commits`. A failure before the switch (a build or `verify`
   step) adds nothing: the site never went down, and a retry may pass;
4. clones the newest commit of the branch into `releases/.building-<stamp>`, renames it to its
   final name with a `.building` file in it, and writes its name to `RELEASE` in the release root.
   The build runs under the final name, as Laravel caches keep absolute paths; the `.building`
   file goes right before the switch. A commit under 5 minutes old with no release tag yet, in a repo
   that has release tags, waits up to `RELEASE_WAIT` seconds for its tag (see below);
5. deletes the project's `CLEAR_PATHS` (like `tests`) from the release, links its `SHARED` paths
   from `shared/` into the release, and copies its `COPY_FROM_LIVE` paths (like `vendor`) from the
   live release, so the build only updates them;
6. runs the project's `preflight`, `backup`, `build` and `verify` steps there;
7. switches `current` to the new release in one rename, then runs `PHP_RELOAD_CMD`, the web OPcache reset (see
   [OPcache](#opcache)) and `after_switch`;
8. waits until `CHECK_URL` answers 200 with the new release name in the `X-App-Version` header.
   If it does not, it switches back and sets the new release aside as `releases/.failed-<name>`;
9. deletes all but the last `KEEP_RELEASES` releases, and any `.failed-*` folder. It always keeps
   the release that was live before this deploy, since requests may still run in it; that one can
   go on the next deploy. It also keeps the rollback target. `deploy <project> prune` does the
   same without a deploy.

If a step before the switch fails, the new folder is deleted and the old release stays live.
When a deploy fails after `deploy.conf` was loaded, its `failed()` step runs once (see
[deploy.conf](#deployconf)).
A deploy stopped by Ctrl-C, `kill` or a dropped SSH session (INT, TERM, HUP) cleans up the same
way and exits with 130, 143 or 129. A deploy whose output goes away (`deploy | head`, an SSH
connection with no terminal that drops) keeps going without it: it finishes, or fails with the same
cleanup, log line and alert. A build killed hard (SIGKILL, OOM) keeps its `.building` mark:
it is never listed or rolled back to, and the next deploy or rollback removes it. Once `current` points at the new release, it is never deleted:
it stays live, and the log says at which stage the deploy stopped.
Migrations and other data changes are not undone by a switch back or a rollback. A rollback warns
when the target lacks files the live release has in `MIGRATIONS_DIR`.
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

Options:
  --quiet, -q       Print only warnings and errors, for cron (see [Quiet runs](#quiet-runs-for-cron))

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
  staging <project>@sN status | diff | log | path | rollback | down | up | cache | prune

Commands:
  deploy [--force]  Build the newest commit and switch to it (the default). Stops if that commit
                    is already live, failed its site check or was rolled back, unless --force.
                    On a terminal --force asks first
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
  cache             Run the cache() step of the live release, then reset OPcache when
                    OPCACHE_RESET_DIR is set. Fails with a hint when neither is set. Takes the
                    lock and writes a log line. On a terminal in production it asks first;
                    on a staging slot it does not ask
  prune [--keep <n>] [--dry-run] [--yes]
                    Free disk space without a deploy: remove `.failed-*` folders, builds a
                    killed deploy left, and releases past `KEEP_RELEASES` (or past the newest
                    n with `--keep`, 2 or more). Never the live release or the rollback target
                    (the one `rollback` would pick). Takes the lock and writes a log line. On a
                    terminal in production it lists the folders with their sizes and asks
                    first; on a staging slot it does not ask. `--dry-run` lists them with a
                    total and changes nothing: no lock, no log line. Prints one line when
                    there is nothing to remove
  status            The live release, the rollback target, the commits not deployed yet, all
                    releases, a commit plain deploys skip, the last failed step since the
                    last good deploy, the lock, the disk and the site
  status --all      One line per project: live release, deploy time, site check, lock, pending
                    commits, a branch tip that plain deploys skip, and failed releases. The
                    menu shows the same note. A last line shows the engine: its version, and
                    whether the repo has newer ones (run `deploy self`) or it has local changes.
                    Exits with 1 if any site does not serve its live release, so it can run from
                    cron as a simple monitor. Pending commits come from
                    the repo: a quick check, plus a commits-only clone when there are any.
                    Production only: staging slots are not listed
  diff [--ref <ref>]
                    The files the next deploy would change: the live release against the newest
                    commit of DEPLOY_BRANCH, or against a tag, branch or commit. One line per
                    file (A added, M changed, D deleted), then a count. Says so when nothing is
                    pending. Changes nothing: no lock, no log line. A renamed file shows as a
                    D and an A, and there are no line counts: both would need the file contents,
                    and diff fetches only the file names
  rollback [name]   Go to the previous good release, and mark the live one bad, so the next
                    rollback skips it, and so a plain deploy skips its commit until a new
                    commit or --force. With a name, go to that release instead (a full name, or
                    any part only one release has: date and time, sha, tag); this marks nothing,
                    and clears the mark if that release had one. On a terminal it asks first.
                    `--dry-run` (before or after the name) shows the live release, the target,
                    the bad mark it would set or clear, the migration warning and whether
                    `after_rollback()` would run, then stops. It changes nothing: no switch,
                    mark, lock, log line or alert. Errors are the same as for a real rollback
  check             A quick health check that changes nothing: the live release, its shared
                    links, the project's health() step, the site, the disk (size of the base
                    folder past DISK_LIMIT, or free space under MIN_FREE_MB), and a lock held
                    for 30 min or more, or with no owner for 60 s. Problems go to stderr
                    and it exits with 1, so `deploy <project> check --quiet` in cron mails
                    only problems. While a deploy or rollback runs, it skips the site and
                    health() (they may lag the switch for a moment) and says so
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
                    Stops if the folder has local changes. Short form: self. A new commit waits
                    for its release tag like a deploy, with `RELEASE_WAIT` from the environment
                    (no project file here, default 90); `--no-wait` skips it
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

Common errors end with one more line that says what to do next, like
`Try: deploy <project> status, or wait for PID 4242` for a held lock, or
`Try: deploy <project> unfreeze` for a frozen project. The same goes for a missing `deploy.conf`,
a failed site check (the URL and the version it got), a failed clone and an unknown release. Alerts
carry the error only. See [Troubleshooting](#troubleshooting) for each one.

### Questions before risky commands

`rollback`, `down`, `cache`, `prune` and `deploy --force` change the live site or its releases, so on a terminal they first show what
will happen and ask `y/N`: `rollback` shows the live release and the one it goes to, `down` the
reason and that the site will show its maintenance page, `cache` the live release, `prune` the folders it removes and their sizes, `deploy --force`
the commit it builds. `cache` and `prune` on a staging slot do not ask. Only
`y` goes on; `n` or an empty answer does nothing and exits with 0. `--yes` (or `-y`) skips the
question. Without a terminal (cron, pipes, `slots update`, `stage`) they never ask and run as before.
`copy-from` asks the same way.

### Quiet runs for cron

`--quiet` (or `-q`) prints only warnings and errors, with their `Try:` hint, so cron mails only
problems. It works with any command, wherever it is on the line. A quiet run shows no `==>` lines,
no rails, no step times and no `ok` lines from `check`; a skipped deploy (nothing new, or a commit
that failed its check or was rolled back) prints nothing. The output of `deploy.conf` steps shows only when a step fails, and is kept in
`<base>/deploy-failed.log` (see [A step failed or ran too long](#a-step-failed-or-ran-too-long)). A problem the run carries
on past (a failing `after_switch` or `PHP_RELOAD_CMD`), and the removal of a stale lock, become
warnings. On a terminal, questions still show; without one it never asks. The bare `deploy` menu
ignores `--quiet`.

Two refusals print nothing with `--quiet`, so cron does not mail every 10 minutes during a planned
freeze or a long manual deploy: a frozen project (deploy, rollback), and a lock held by another run
that is still alive (deploy, rollback, `down`, `up`, `cache`, `prune`, `free`, `copy-from`). The exit code
stays 1. Both still show in `status` and `check`. A stale lock, a lock with no owner, a stale lock
removal that stopped half way and a base folder that cannot be written still print: they need a
person.

`check` (and `status --all`) skips the site and `health()` while a live deploy or rollback holds the
lock, as the site may still serve the old release for a moment. It prints one `ok` line instead, sends
no alert and keeps the last alert state. The disk and the rest still run. A stale lock, or a lock
held for 30 min or more, does not skip them.

```cron
*/10 * * * * $HOME/release-switch/deploy example --quiet
0 4 * * *    $HOME/release-switch/deploy self --quiet
```

A commit whose site check failed, or that a plain `rollback` left, is not built again by the next
cron run: the deploy that failed already sent its alert, and building it again would only break the
site again. Cron deploys again once a new commit lands on the branch (see
[A deploy says a commit failed its check](#a-deploy-says-a-commit-failed-its-check)). A build or
`verify` failure does not count: the site never went down, so the next run tries again.

### Project menu

A bare `deploy` on a terminal shows a menu instead of deploying. It reads every project, its staging
slots and the engine at the same time, then lists what is waiting to ship. Each project's slots hang
under it as a tree:

```
┌  release-switch v2026.11.32
│
◇  Checking 5 projects…
◆  Pick a project
│  ❯ 1  tarasov.ca      v2026.11.4 → v2026.11.5    3 commits       site ok
│    2  ├ s1            develop                    up to date      site ok
│    3  └ s2            PR #51                     2 commits       site ok
│    4  other           v2026.11.2                 up to date      site ok
│    5  ├ s1            feature/search             1 commit        site ok
│    6  └ s2, s3        free
│    7  release-switch  v2026.11.33 → v2026.11.34  run deploy self
│       Recheck projects
│       Quit
│
│  ↑↓/1-7 pick · Enter open · r refresh · q quit
```

Enter opens the action list of the picked row:

```
◆  tarasov.ca — production · v2026.11.4 → v2026.11.5
│  ❯ 1  Deploy new release (3 commits)
│    2  Status
│    3  Check site
│    4  Log
│    5  Rollback…
│    6  Clear cache
│    7  Prune releases
│    8  Freeze…
│    9  Down…
│       Back
│
│  ↑↓/1-9 pick · Enter run · b back · q quit
```

`live → new` means the branch tip has a newer release tag; `N commits, no tag yet` means it has
none, and the deploy waits for the tag as usual. Problems (frozen, down, lock held, failed releases,
a site that does not serve the live release) show in red at the end of the row. Production names are
bold. A slot row shows the branch it follows, or `PR #N`. Free slots share one dim leaf. Projects with
something to ship come first, each with its slots right under it; up-to-date rows are dimmed. The dim
`Recheck projects` and `Quit` rows are last.

Pick with the arrow keys, `j`/`k` or a number, then Enter. Each row opens its own action list:

- Production: Deploy new release (or Redeploy when up to date), Status, Check site, Log, Rollback…,
  Clear cache, Prune releases, Freeze… or Unfreeze, Down… or Up.
- Staging slot: Update (or a redeploy when up to date), Checkout branch or PR…, Clear cache, Prune
  releases, Copy data from production…, Status, Log, Rollback…, Down… or Up, Free slot.
- Free slot leaf: no list; it asks for a branch, or `#N` for a pull request, and runs
  `deploy staging <project> checkout …`, which uses the first free slot.
- Engine: Update engine (`deploy self`), Log (`deploy self log`).

Unfreeze shows only on a frozen project, Up only on a site that is down. Deploy and Update show the
pending commits and ask `Deploy <project> (production) <live> → <new>? [y/N]` first. Rollback… shows
`rollback --dry-run`, then asks. Freeze… and Down… ask for an optional reason. Each action runs the
matching command (`deploy <project> status`, `deploy <project>@sN cache`, …) as a child process, with
its own questions. When it ends, the menu shows whether it worked or failed and waits for Enter, then
shows the same action list with fresh facts. A failed run keeps the menu open. Ctrl-C during a run
stops that run and comes back to the menu; Ctrl-C in a list quits. After `deploy self` the new engine
opens its own menu.

`b`, ←, Esc or the dim `Back` row go back to the project list, which reads the rows again when an
action ran and puts the cursor back on the same row. `r` or the `Recheck projects` row reads the rows again. `q`, Ctrl-D, the
`Quit` row or Esc in the project list quit with exit code 0. With `TERM=dumb` both lists are
numbered: `Pick 1–N, r to refresh, q to quit:` and `Pick 1–N, b to go back, q to quit:`.
While the arrow-key menu is on screen, keys never echo as text, and keys pressed before a question
(the menu's own or an action's) are dropped, so a stray arrow or Enter never answers it.
Without a terminal (cron, pipes) a bare `deploy` works as before: it deploys the only project, or
fails with `name a project (…)` when there are several.

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
| `PHP_RELOAD_CMD` | none | Run after each switch to reset OPcache, e.g. `touch ~/.lsphp_restart.txt` (see [OPcache](#opcache)). Stopped after 60 s with a warning |
| `OPCACHE_RESET_DIR` | none | Web root inside a release, like `public`. Turns on the OPcache reset through the web after each switch (see [OPcache](#opcache)) |
| `STEP_TIMEOUT` | `600` | Seconds a `deploy.conf` step (including `health()`, `down()`, `up()` and `cache()`) may run. A step that runs longer is stopped with all it started, and fails like any failed step. `0` for no limit |
| `DISK_LIMIT` | none | Largest size of the base folder, like `2G`, `500M`, `1.5G` or plain bytes. `check` fails when the folder is bigger; a deploy only warns, as prune may bring it back down. On cPanel the account quota can differ from `df`, so set it yourself |
| `MIN_FREE_MB` | `500` | Free space in MB the disk of the base folder must have. `check` fails under it, and `deploy` and `copy-from` stop before they write anything. `0` to turn it off |
| `MIGRATIONS_DIR` | `database/migrations` | Migrations folder inside a release. Before a rollback switches, it warns when the target lacks files the live release has there, as data is not reverted. A hint only: it never stops the rollback. Empty to turn it off |
| `DISPLAY_TZ` | UTC | Time zone for deploy times in `status` and `log`, e.g. `America/Toronto`. `status` says "today at" and "yesterday at" for recent deploys. Release names stay in UTC |
| `NOTIFY_URL` | none | Webhook for alerts. Gets a POST with JSON (see [Alerts](#alerts)) |
| `NOTIFY_CMD` | none | Command for alerts, run with `sh -c`. The text is in `$NOTIFY_TEXT`, the event in `$NOTIFY_EVENT` (see [Alerts](#alerts)). Stopped after 30 s with a warning |
| `NOTIFY_ON` | problems | `problems`, or `all` to also send successful deploys |
| `STAGING_SERVERS` | `0` | Number of staging slots, `s1` to `sN` (see [Staging](#staging)) |
| `STAGING_URL` | `sN.` before the host of `CHECK_URL` | Slot URL, with `{slot}` for `s1`, `s2`, ... e.g. `https://user:pass@{slot}.example.com/` |

### OPcache

PHP's OPcache can keep serving old code after `current` is switched. There are two ways to clear it.
Use one or both.

`PHP_RELOAD_CMD` runs a shell command after each switch. Common values on shared hosts:

| Host | `PHP_RELOAD_CMD` |
| --- | --- |
| LiteSpeed (LSAPI) | `touch ~/.lsphp_restart.txt` |
| CloudLinux mod_lsapi | `touch ~/mod_lsapi_reset_me` |

`OPCACHE_RESET_DIR` resets OPcache through the web server, whose PHP a shell command cannot reach.
Set it to the web root inside a release, like `public` or `public/site`. After each switch (deploy,
rollback, or a failed check that switches back), the engine writes a PHP file with a random name
(`rs-opcache-<32 hex>.php`) into that folder, calls it once at the scheme, host and port of
`CHECK_URL`, and deletes it whatever happens. The file runs `opcache_reset()` when PHP has it, and
deletes itself too. A staging slot calls its own slot URL. A missing folder, an answer other than
200, or no answer within 60 s (or `STEP_TIMEOUT`, when smaller) only warns, and the deploy goes on.
`deploy <project> cache` runs the same reset on demand, after the project's `cache()` step.

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
deploy staging example@s1 diff | log | path | rollback | down | up | cache
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
*/5 * * * * $HOME/release-switch/deploy staging example update --quiet
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
# Paths under the release that live in shared/ instead. Quote one with a space; a leading / or ..
# is refused.
SHARED=(.env storage database/database.sqlite)

# Optional. Paths copied from the live release before the build, so Composer only installs what
# changed. A copy, never a link, so the build cannot touch the live site. Paths the repo tracks are
# skipped.
COPY_FROM_LIVE=(vendor)

# Optional. Paths deleted from each new release right after the clone, before anything else, so
# releases do not carry files only CI needs. A missing path is skipped. Quote one with a space.
# A leading /, . or .. is refused, and so are deploy.conf and .git: the engine reads both from
# releases later (the release's commit for status, rollback and the next deploy).
CLEAR_PATHS=(tests .github)

# Optional. Stop before building, e.g. when .env points at the wrong host.
preflight() {
    grep -q '^APP_URL=https://example.com' .env
}

# Optional. Runs right before build (where migrations run), e.g. a database dump, so a bad
# migration can be undone by hand. A failure stops the deploy before build; the old release stays
# live. This dump reads the database from Laravel's .env (values without quotes) and keeps the
# last 5.
backup() {
    local dir="$DEPLOY_BASE/shared/backups" db user host password
    db="$(sed -n 's/^DB_DATABASE=//p' .env)"
    user="$(sed -n 's/^DB_USERNAME=//p' .env)"
    host="$(sed -n 's/^DB_HOST=//p' .env)"
    password="$(sed -n 's/^DB_PASSWORD=//p' .env)"
    mkdir -p "$dir"
    MYSQL_PWD="$password" mysqldump --single-transaction --quick --no-tablespaces \
        -h "$host" -u "$user" "$db" | gzip > "$dir/.$RELEASE_NAME.sql.gz"
    mv "$dir/.$RELEASE_NAME.sql.gz" "$dir/$RELEASE_NAME.sql.gz"
    ls -1t "$dir"/*.sql.gz | tail -n +6 | xargs rm -f
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

# Optional. Runs once when a deploy fails after deploy.conf was loaded: in the new release while
# it is on disk (the build or a step failed, or it is the only release), else in the live release
# (the check failed and the deploy switched back). Not on success, and not when the deploy stopped
# earlier (lock, freeze, clone). A failure is only a warning; the deploy still fails.
failed() {
    "$PHP_BIN" artisan up
}

# Optional. Runs in the target release after a rollback switches to it, before the site check.
# A failure is only a warning; the rollback stands.
after_rollback() {
    "$PHP_BIN" artisan cache:clear
    "$PHP_BIN" artisan queue:restart
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

# Optional. Run by `cache` in the live release, then OPcache is reset when OPCACHE_RESET_DIR is set.
cache() {
    "$PHP_BIN" artisan cache:clear
}
```

`backup()` runs on every deploy that builds a release, and on staging slots too, since each slot
has its own database; skip it there with `[ -z "$DEPLOY_SLOT" ] || return 0`. It does not run when
a deploy has nothing new or stops before the build. On shared hosting, mind the disk quota: each
dump counts, so keep few. `--single-transaction` dumps InnoDB tables without locking them, but
MyISAM tables stay locked for the whole dump. A big dump also needs to fit in `STEP_TIMEOUT`.
To undo a migration, roll back and load the dump of the release that ran it:
`gunzip < shared/backups/<release>.sql.gz | mysql <database>`.

Names of the engine are reserved. `deploy.conf` may read engine variables, but a function with the
name of an engine function (`fail`, `say`, `prune`, ...) or a top-level change to an engine
variable (`KEEP_RELEASES`, `DEPLOY_BASE`, ...) stops the deploy before any step, with the names
to change. `SHARED`, `COPY_FROM_LIVE` and `CLEAR_PATHS` are the only engine variables it sets.

The steps can use `DEPLOY_BASE`, `RELEASE_DIR`, `RELEASE_NAME`, `PHP_BIN`, `COMPOSER_BIN`,
`DEPLOY_SLOT` and `DEPLOY_HOST`, and these details of the run (also in `NOTIFY_CMD`). They are empty
when unknown:

| Variable | deploy | rollback | down, up, cache | check |
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
Each check request stops after `CHECK_WAIT / 3` seconds (at least 1, at most 10), so one stuck
request still leaves time to retry.

### Output

In a terminal, each command runs on rails, like this:

```
┌  release-switch v2026.11.1 · tarasov · deploy
│
◆  Cloning develop
◇  Cloning develop (2s)
◆  Running build
│  (the step's own output)
◇  Running build (38s)
◇  Checking https://example.com/ (1s)
◇  Deployed v2026.11.3 → v2026.11.4
│
└  Done in 42s
```

Each step and stage shows its time when it ends (`1m 12s` from a minute on). On a terminal, the wait
for `CHECK_URL` shows a spinner with the time waited out of `CHECK_WAIT` on one line. A failure is marked with `■` on stderr and ends with `└  Failed after Ns`. In a pipe or cron, the
output stays plain (`==> ...` lines, errors as `deploy: ...`), so scripts and mail stay clean.
`DEPLOY_RAILS=1` forces the rails, `DEPLOY_RAILS=0` turns them off. `NO_COLOR` turns off colors.

## Troubleshooting

Errors print as `deploy: <message>` in a pipe or cron, or after `■` on a terminal. Many end with a
`Try:` line that says what to do next. Warnings look the same, but the run goes on. Below,
`example` is the project, and `<base>` its `DEPLOY_BASE`.

### Another deploy is running

```
deploy: another deploy is running (PID 4242, deploy, 3 min); remove <base>/.deploy.lock if it is not
Try: deploy example status, or wait for PID 4242
```

A project runs one deploy, rollback, `down`, `up` or `cache` at a time; the message names the
other run. Wait for it to end. A lock whose process is gone is removed on its own, so remove
`<base>/.deploy.lock` by hand only when that process is not running (`ps -p 4242`). `check` warns about a lock held for 30 min or more:
`lock: held for 30 min (...); a deploy may be stuck`. With `--quiet` the refusal prints nothing,
as cron would mail it every run; a lock with no owner still prints.

If a run died while it removed a stale lock, you get
`a stale lock removal stopped half way; remove <base>/.deploy.lock.break and <base>/.deploy.lock if no deploy is running`.
Do what it says once no deploy runs.

Two runs that start at the same moment can race for the lock. The one that loses says
`lost the lock to another deploy while taking it` with `Try: deploy example status`. Check
what the other run does, then run again.

### Deploys are frozen

```
deploy: deploys are frozen since <time>: <reason>
Try: deploy example unfreeze
```

Someone ran `deploy example freeze`. Deploys and rollbacks stop until `deploy example unfreeze`.
Ask why first: the reason is in the message and in `status`. With `--quiet` the refusal prints
nothing (the exit code stays 1), so cron stays quiet during a freeze.

### The site is down for maintenance

```
deploy: not checking https://example.com/: the site is down for maintenance; check it with: deploy example up
```

A warning, not an error. Someone ran `deploy example down`, so the deploy or rollback cannot see
the new version behind the maintenance page and does not check it. Run `deploy example up` when the
work is done; it checks the site then. If `up` says
`up ran, but the site does not serve <release>`, see
[The check failed after the switch](#the-check-failed-after-the-switch).

### No deploy.conf

```
deploy: develop has no deploy.conf
Try: add one to the repo, see README.md#deployconf
```

The deployed branch has no `deploy.conf` in the repo root. Add one with at least a `build()` step
(see [deploy.conf](#deployconf)); without that step the deploy stops with
`deploy.conf has no build step`. `init` says
`<checkout> has no deploy.conf; update it to a commit that has one`: pull the checkout first.

### A step failed or ran too long

```
deploy: build failed; its output is in <base>/deploy-failed.log
deploy: build ran past STEP_TIMEOUT (600 s); its output is in <base>/deploy-failed.log
```

A `deploy.conf` step (`preflight`, `backup`, `build`, `verify`) exited with an error, or ran
longer than `STEP_TIMEOUT` and was stopped with all it started. The step's own output is above the
error, and is also kept in `<base>/deploy-failed.log`, so the error of a cron run (a composer or
migration error) can be read later. The file starts with the step, the release and the time (UTC).
Each failed step overwrites it; it keeps the last 100 KB, and URLs in it hide their user and
password. `status` shows `Failed: build at <time>; its output is in <base>/deploy-failed.log` until
the next good deploy. A slot keeps its own file in its folder. The `failed` step never overwrites
it. Nothing was switched: the new folder is deleted and the old release stays live. Fix the step,
or raise `STEP_TIMEOUT` in `projects/example.env` if the step is slow but fine (`0` turns the limit
off). `check` reports a slow `health()` step as `health: ran past STEP_TIMEOUT (600 s)`.

### The check failed after the switch

```
deploy: the check failed; <old release> is live (data changes stay applied)
Try: open https://example.com/: it answered 500 with version none, not v2026.11.4-abc1234
```

After the switch, `CHECK_URL` did not answer 200 with the new release in `X-App-Version` within
`CHECK_WAIT` seconds. The deploy switched back to the old release on its own and set the new one
aside as `releases/.failed-<name>`. Migrations that ran stay applied. Open the URL from the hint:

- a 500 or no answer: read the app's log in the failed release;
- a 200 with an old or no version: the app does not send `X-App-Version` from its `RELEASE` file
  (set `CHECK_VERSION=0` until it does), or a cache serves an old page (see [OPcache](#opcache));
- it is just slow to start: raise `CHECK_WAIT`.

A rollback that cannot see its target says `<release> is linked, but the site does not serve it yet`
with the same hint. The rollback stands; check the site.

### A deploy says a commit failed its check

```
==> abc1234 failed its check; push a fix, or deploy example --force
==> abc1234 was rolled back; push a fix, or deploy example --force
```

A plain `deploy` (no `--force`, no `--ref`) found that the newest commit of the branch broke the
site before: its site check failed and the deploy switched back, or a plain `rollback` left it.
It builds nothing and exits with 0, like "Nothing new", so cron does not break the site every run;
with `--quiet` it prints nothing. `status` shows it on a `Skips:` line, and `status --all` and the
menu note `tip abc1234 failed its check`. Push a fix: a new commit deploys as usual. To build the
same commit again (say the cause was outside the code and is fixed), run
`deploy example --force`, or `--ref <sha>`. A good deploy of the branch tip (plain or `--force`)
clears the list. A good `--ref` deploy, say back to an older tag, leaves it, as the tip may still be
broken. Failures
before the switch (`build`, `verify`) are not remembered, so a flaky network only costs a retry.
The list lives in `<base>/.skip-commits`, one line per commit (full sha, reason, release), newest
first, up to 10; a staging slot has its own in its own base folder.

### Cannot clone or fetch the repo

```
deploy: could not clone git@github-example:owner/example.git
Try: git ls-remote git@github-example:owner/example.git, and check REPO_URL, the SSH key or host alias, and the network
```

The server cannot read the repo. Run the `git ls-remote` from the hint. If it fails, check
`REPO_URL` in `projects/example.env`, the deploy key and the `Host` entry in `~/.ssh/config` (see
[Adding a project](#adding-a-project)). A staging slot says
`could not fetch PR #N from <repo>` for the same cause. A wrong name says
`no branch <name> in the repo` or `no tag, branch or commit <ref> in the repo`.

### Unknown release in rollback

```
deploy: no release matches 'abc1234'
Try: deploy example status (it lists the releases)
```

No kept release has that text in its name. Pick one from `status`. A release that `KEEP_RELEASES`
no longer keeps can come back with `deploy example --ref <tag or sha>`. Other rollback errors:

- `'2026' matches 3 releases; use more of the name`: add more of the name, like the time or sha;
- `no good release older than <release>`: there is no older release, or all are marked bad; name one;
- `<release> is already live`: nothing to do.

### deploy self cannot update

```
deploy: could not update <engine folder>; it has local changes
Try: git -C <engine folder> status
```

```
deploy: could not update <engine folder>; it has local commits the remote lacks
Try: git -C <engine folder> log @{u}..
```

`deploy self` only does a fast-forward `git pull`. It stops when the engine folder has local
changes or its branch has commits the remote lacks, and says which. Run the command from the
hint, undo or move the changes or commits, and run `deploy self` again. Project files in
`projects/` are not tracked, so they never block it. The last line of `deploy status --all`
also says when the engine has local changes.

### No release tag

```
deploy: no release tag on abc1234 after 90 s; deploying without one
Try: deploy example --no-wait, or RELEASE_WAIT=0 if the repo does not tag every merge
```

A warning: the deploy goes on, and the release name has no tag. The release workflow did not tag
the merge within `RELEASE_WAIT` seconds. Check the workflow run in GitHub. If the repo does not tag
every merge, use `deploy example --no-wait`, set `RELEASE_WAIT=0`, or add the no-release marker job
(see [How it works](#how-it-works)). `no release tag on abc1234; deploying without one` means the
commit is over 5 minutes old, so the deploy did not wait.

### Nothing to clear

```
deploy: nothing to clear: deploy.conf of <release> has no cache() step and OPCACHE_RESET_DIR is not set
Try: define cache() in deploy.conf, or set OPCACHE_RESET_DIR in <engine folder>/projects/example.env
```

`cache` has nothing to run. Add a `cache()` step to `deploy.conf` (it runs in the live release
after the next deploy), or set `OPCACHE_RESET_DIR` (see [OPcache](#opcache)).

### Disk space

```
deploy: only 312.0M free on the disk of <base>, under MIN_FREE_MB (500M); free some space before deploying
Try: deploy example prune (removes failed and old releases)
deploy: disk: 2.3G used of 2.0G, 40.1G free, over DISK_LIMIT (2G); prune after the deploy may help
```

The first is an error: the deploy stops before it writes anything when free space is under
`MIN_FREE_MB`. Run `deploy example prune --dry-run` to see what `prune` would free, then
`deploy example prune` to remove failed releases, unfinished builds and releases past
`KEEP_RELEASES` (`--keep 2` keeps the fewest). If that is
not enough, free space elsewhere, or lower `MIN_FREE_MB` (`0` turns it off). The second is a warning: the
base folder is bigger than `DISK_LIMIT`. The deploy goes on and deletes old releases at the end,
which may bring it back down; if not, lower `KEEP_RELEASES` or clean `shared/`. `check` fails on
both, as `disk: ...; over DISK_LIMIT (2G)` or `disk: ...; under MIN_FREE_MB (500M free)`.

### The base folder cannot be written

```
deploy: cannot write to <base> (disk full, quota or permissions)
Try: df -h <base>; ls -ld <base>
```

The lock folder could not be made, and no other run holds it. Free space, raise the quota, or give
the deploy user write access to `<base>`.

### An old release cannot be removed

```
deploy: could not remove <base>/releases/<release>; some files in it cannot be deleted, remove it by hand
```

A warning: the new release is live and the deploy is logged `ok`. A file in the old release
belongs to another user (often the web server) or sits in a read-only folder. Remove the folder as
a user who can, for example with the hosting panel's file manager.

## Tests

`tests/run.sh` deploys a tiny PHP project (`tests/fixture/`) in a temp folder with `php -S`: init,
deploys, rollbacks and bad releases, `backup()`, `failed()` and `after_rollback()`, copies from the live release, failing builds and checks, `status`
with pending commits, the rails and `--version`, `check`, alerts, `self-update`, skipped deploys, `freeze`, `down` and `up`, `cache`, `--ref`, the wait for a release tag, the no-release marker and `--no-wait`, `--quiet` (with quiet refusals on a freeze or a held lock), shipped commits, `self log`, `health()`, `check` during a deploy, the log, the lock, stale locks, locks with no owner and two runs racing for a stale lock,
`PHP_RELOAD_CMD`, the web OPcache reset, `STEP_TIMEOUT` and git timeouts, `DISK_LIMIT` and `MIN_FREE_MB`, a signal after the switch, a closed output pipe, a rollback with the live folder missing, a read-only base folder, alerts for 2000 commits, prune and
`KEEP_RELEASES` with a release that cannot be removed, the `prune` command (dry run, `--keep`, the lock), staging slots with their branch, folder, URL and `slots` list, `stage`, `free`, `slots update` and `copy-from`, and that shared
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
`deploy --version` shows the one in use. Run right after a merge, `deploy self` waits for the
merge's tag (or its no-release marker) the same way a deploy does, then shows the tag and its notes.
