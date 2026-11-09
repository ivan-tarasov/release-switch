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
```

`deploy <project>`:

1. takes a lock, so two deploys of one project never run at once;
2. clones the newest commit of the branch into a new release folder, and writes its name to
   `RELEASE` in the release root;
3. links the project's `SHARED` paths from `shared/` into the release;
4. runs the project's `preflight`, `build` and `verify` steps there;
5. switches `current` to the new release in one rename, then runs `after_switch` and `PHP_RELOAD_CMD`;
6. waits until `CHECK_URL` answers 200 with the new release name in the `X-App-Version` header.
   If it does not, it switches back and sets the new release aside as `releases/.failed-<name>`;
7. deletes all but the last `KEEP_RELEASES` releases, and any `.failed-*` folder.

If a step before the switch fails, the new folder is deleted and the old release stays live.
Migrations and other data changes are not undone by a switch back or a rollback.

Release names are in UTC, so they sort the same all year. The tag (`v2026.11.21`) is left out when
the commit has none.

## Commands

```
deploy [project] [command]

  deploy            Build the newest commit and switch to it (the default)
  status            The live release, the rollback target, all releases, the lock and the site
  rollback [name]   Go to the previous release, or to the named one
                    (a full name, or any part only one release has: date and time, sha, tag)
  init <checkout>   Move the SHARED paths of an existing checkout into shared/
                    and link them back (add --dry-run to only show what it would do)
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

To update the script: `git -C ~/release-switch pull`. Files in `projects/` other than
`example.env` are not tracked, so a pull never touches them.

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
| `DISPLAY_TZ` | none | Extra time zone for `status` times, e.g. `America/Toronto` |

## deploy.conf

A bash file in the project's repo root. The engine reads it from the release it is building, so the
steps change together with the code. Every step runs in the release folder, with `set -e`.

```bash
# Paths under the release that live in shared/ instead.
SHARED=(.env storage database/database.sqlite)

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
```

The steps can use `DEPLOY_BASE`, `RELEASE_DIR`, `RELEASE_NAME`, `PHP_BIN` and `COMPOSER_BIN`.

The project must send the release name as a header, so the check knows the new code is live:

```php
header('X-App-Version: ' . trim((string) @file_get_contents(__DIR__ . '/../RELEASE')));
```

## Tests

`tests/run.sh` deploys a tiny PHP project (`tests/fixture/`) in a temp folder with `php -S`: init,
deploys, rollbacks, failing builds and checks, `status`, the lock, and that shared files survive.
It needs bash, PHP 8.1+, git and curl. CI runs it and `shellcheck` on every push.
