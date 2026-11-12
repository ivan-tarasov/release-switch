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
   died (its process is gone) is removed;
3. stops if the newest commit of the branch is already live, so no empty release pushes a good one
   out (`--force` builds it anyway);
4. clones the newest commit of the branch into a new release folder, and writes its name to
   `RELEASE` in the release root;
5. links the project's `SHARED` paths from `shared/` into the release, and copies its
   `COPY_FROM_LIVE` paths (like `vendor`) from the live release, so the build only updates them;
6. runs the project's `preflight`, `build` and `verify` steps there;
7. switches `current` to the new release in one rename, then runs `after_switch` and `PHP_RELOAD_CMD`;
8. waits until `CHECK_URL` answers 200 with the new release name in the `X-App-Version` header.
   If it does not, it switches back and sets the new release aside as `releases/.failed-<name>`;
9. deletes all but the last `KEEP_RELEASES` releases, and any `.failed-*` folder.

If a step before the switch fails, the new folder is deleted and the old release stays live.
Migrations and other data changes are not undone by a switch back or a rollback.
Every deploy and rollback, and how it ended, goes to `deploy.log` (see `deploy <project> log`).
A deploy also lists the commits it ships, in its output, the log and the alert.

Release names are in UTC, so they sort the same all year. The tag (`v2026.11.21`) is left out when
the commit has none.

## Commands

```
deploy [project] [command]

  deploy [--force]  Build the newest commit and switch to it (the default). Stops if that commit
                    is already live, unless --force
  deploy --ref <ref>
                    Deploy a tag, branch or commit instead, e.g. --ref v2026.11.18, to go back
                    to a release that rollback no longer keeps. Stops if it is already live
  freeze [reason]   Refuse deploys and rollbacks until unfreeze, e.g. during a hosting move.
                    status, status --all and check show it
  unfreeze          Allow deploys again
  status            The live release, the rollback target, the commits not deployed yet, all
                    releases, the lock and the site
  status --all      One line per project: live release, deploy time, site check, lock, pending
                    commits and failed releases. A last line shows the engine: its commit, and
                    whether the repo has newer ones (run `deploy self`) or it has local changes.
                    Exits with 1 if any site does not serve its live release, so it can run from
                    cron as a simple monitor. Pending commits come from
                    the repo: a quick check, plus a commits-only clone when there are any
  rollback [name]   Go to the previous good release, and mark the live one bad, so the next
                    rollback skips it. With a name, go to that release instead (a full name, or
                    any part only one release has: date and time, sha, tag); this marks nothing,
                    and clears the mark if that release had one
  check             A quick health check that changes nothing: the live release, its shared
                    links, the project's health() step, the site, and a lock held for 30 min
                    or more. Problems go to stderr
                    and it exits with 1, so `deploy <project> check > /dev/null` in cron mails
                    only problems
  check --all       The same for every project
  log [count]       The last deploys and rollbacks, with results, times and the commits each
                    deploy shipped (20 by default)
  init <checkout>   Move the SHARED paths of an existing checkout into shared/
                    and link them back (add --dry-run to only show what it would do)
  self-update       Update the engine itself: a fast-forward git pull of its own folder, then
                    the new commits. Stops if the folder has local changes. Short form: self
  self log [count]  The engine's last commits (10 by default) with times, and any not pulled yet
  help              Commands and the settings in effect
```

`project` is the name of a file in `projects/` (`projects/tarasov.ca.env` is `tarasov.ca`).
It can be left out when there is only one.

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
| `KEEP_RELEASES` | `5` | Releases to keep |
| `CHECK_WAIT` | `150` | Seconds to wait for `CHECK_URL`. PHP's realpath cache can keep serving the old release for up to 120 s |
| `CHECK_VERSION` | `1` | `0` to only wait for a 200, for a project that cannot send `X-App-Version` yet |
| `PHP_BIN` | `php` | PHP binary, for the project's steps |
| `COMPOSER_BIN` | `composer` | Composer command, e.g. `php ~/composer.phar` |
| `PHP_RELOAD_CMD` | none | Run after each switch to reset OPcache, e.g. `touch ~/tmp/restart.txt` |
| `DISPLAY_TZ` | UTC | Time zone for deploy times in `status` and `log`, e.g. `America/Toronto`. `status` says "today at" and "yesterday at" for recent deploys. Release names stay in UTC |
| `NOTIFY_URL` | none | Webhook for alerts. Gets a POST with JSON: `text`, `project`, `event` |
| `NOTIFY_CMD` | none | Command for alerts, run with `sh -c`. The text is in `$NOTIFY_TEXT`, the event in `$NOTIFY_EVENT` |
| `NOTIFY_ON` | problems | `problems`, or `all` to also send successful deploys |

### Alerts

With `NOTIFY_URL` or `NOTIFY_CMD` set, the engine sends an alert when a deploy or rollback fails,
when a rollback runs, and when the result of `check` changes (once when it fails, once when it is
ok again, so a cron check does not repeat itself). An alert that cannot be sent only warns.

`NOTIFY_URL` suits Slack-style incoming webhooks, which show the `text` field. `NOTIFY_CMD` covers
anything else, like local mail:

```bash
NOTIFY_CMD='printf "%s\n" "$NOTIFY_TEXT" | mail -s "deploy alert" you@example.com'
```

For alerts on a down site, run `check` from cron. The alerts do the telling, so cron mail is off:

```cron
*/5 * * * * $HOME/release-switch/deploy check --all > /dev/null 2>&1
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
```

The steps can use `DEPLOY_BASE`, `RELEASE_DIR`, `RELEASE_NAME`, `PHP_BIN` and `COMPOSER_BIN`.

The project must send the release name as a header, so the check knows the new code is live:

```php
header('X-App-Version: ' . trim((string) @file_get_contents(__DIR__ . '/../RELEASE')));
```

## Tests

`tests/run.sh` deploys a tiny PHP project (`tests/fixture/`) in a temp folder with `php -S`: init,
deploys, rollbacks and bad releases, copies from the live release, failing builds and checks, `status`
with pending commits, `check`, alerts, `self-update`, skipped deploys, `freeze`, `--ref`, shipped commits, `self log`, `health()`, the log, the lock and stale locks, and that
shared files survive.
It needs bash, PHP 8.1+, git and curl. There is no CI for now: run it and
`shellcheck deploy tests/run.sh` before a pull request.
