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

The repos are private. A GitHub deploy key (read-only, under the repo's **Settings → Deploy keys**)
works for one repo only, so give each repo its own key and host name in `~/.ssh/config`:

```text
Host github-release-switch
    HostName github.com
    IdentityFile ~/.ssh/release_switch_deploy
    IdentitiesOnly yes

Host github-<project>
    HostName github.com
    IdentityFile ~/.ssh/<project>_deploy
    IdentitiesOnly yes
```

Then use that host name in clone URLs and in each project's `REPO_URL`
(`git@github-<project>:owner/repo.git`).

```bash
git clone git@github-release-switch:ivan-tarasov/release-switch.git ~/release-switch
cp ~/release-switch/projects/example.env ~/release-switch/projects/<project>.env
```

Edit the new file (see Settings), then add an alias to your shell profile:

```bash
alias deploy="$HOME/release-switch/deploy"
```

Update the engine with `git -C ~/release-switch pull`. Files in `projects/` other than
`example.env` are not tracked, so a pull never touches them.

### Moving a project from a plain checkout

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
