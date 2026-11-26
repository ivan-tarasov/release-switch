# Troubleshooting

Errors print as `deploy: <message>` in a pipe or cron, or after `■` on a terminal. Many end with a
`Try:` line that says what to do next. Warnings look the same, but the run goes on. Below,
`example` is the project, and `<base>` its `DEPLOY_BASE`.

## Another deploy is running

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

## Deploys are frozen

```
deploy: deploys are frozen since <time>: <reason>
Try: deploy example unfreeze
```

Someone ran `deploy example freeze`. Deploys and rollbacks stop until `deploy example unfreeze`.
Ask why first: the reason is in the message and in `status`. With `--quiet` the refusal prints
nothing (the exit code stays 1), so cron stays quiet during a freeze.

## The site is down for maintenance

```
deploy: not checking https://example.com/: the site is down for maintenance; check it with: deploy example up
```

A warning, not an error. Someone ran `deploy example down`, so the deploy or rollback cannot see
the new version behind the maintenance page and does not check it. Run `deploy example up` when the
work is done; it checks the site then. If `up` says
`up ran, but the site does not serve <release>`, see
[The check failed after the switch](#the-check-failed-after-the-switch).

## No deploy.conf

```
deploy: develop has no deploy.conf
Try: add one to the repo, see README.md#deployconf
```

The deployed branch has no `deploy.conf` in the repo root. Add one with at least a `build()` step
(see [deploy.conf](../README.md#deployconf)); without that step the deploy stops with
`deploy.conf has no build step`. `init` says
`<checkout> has no deploy.conf; update it to a commit that has one`: pull the checkout first.

## A step failed or ran too long

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

## The check failed after the switch

```
deploy: the check failed; <old release> is live (data changes stay applied)
Try: open https://example.com/: it answered 500 with version none, not v2026.11.4-abc1234
```

After the switch, `CHECK_URL` did not answer 200 with the new release in `X-App-Version` within
`CHECK_WAIT` seconds. The deploy switched back to the old release on its own and set the new one
aside as `releases/.failed-<name>`. Migrations that ran stay applied. Open the URL from the hint:

- a 500 or no answer: read the app's log in the failed release;
- a 200 with an old or no version: the app does not send `X-App-Version` from its `RELEASE` file
  (set `CHECK_VERSION=0` until it does), or a cache serves an old page (see [OPcache](../README.md#opcache));
- it is just slow to start: raise `CHECK_WAIT`.

A rollback that cannot see its target says `<release> is linked, but the site does not serve it yet`
with the same hint. The rollback stands; check the site.

## A deploy says a commit failed its check

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

## Cannot clone or fetch the repo

```
deploy: could not clone git@github-example:owner/example.git
Try: git ls-remote git@github-example:owner/example.git, and check REPO_URL, the SSH key or host alias, and the network
```

The server cannot read the repo. Run the `git ls-remote` from the hint. If it fails, check
`REPO_URL` in `projects/example.env`, the deploy key and the `Host` entry in `~/.ssh/config` (see
[Adding a project](../README.md#adding-a-project)). A staging slot says
`could not fetch PR #N from <repo>` for the same cause. A wrong name says
`no branch <name> in the repo` or `no tag, branch or commit <ref> in the repo`.

## Unknown release in rollback

```
deploy: no release matches 'abc1234'
Try: deploy example status (it lists the releases)
```

No kept release has that text in its name. Pick one from `status`. A release that `KEEP_RELEASES`
no longer keeps can come back with `deploy example --ref <tag or sha>`. Other rollback errors:

- `'2026' matches 3 releases; use more of the name`: add more of the name, like the time or sha;
- `no good release older than <release>`: there is no older release, or all are marked bad; name one;
- `<release> is already live`: nothing to do.

## deploy self cannot update

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

## No release tag

```
deploy: no release tag on abc1234 after 90 s; deploying without one
Try: deploy example --no-wait, or RELEASE_WAIT=0 if the repo does not tag every merge
```

A warning: the deploy goes on, and the release name has no tag. The release workflow did not tag
the merge within `RELEASE_WAIT` seconds. Check the workflow run in GitHub. If the repo does not tag
every merge, use `deploy example --no-wait`, set `RELEASE_WAIT=0`, or add the no-release marker job
(see [How a deploy runs](../README.md#how-a-deploy-runs)). `no release tag on abc1234; deploying without one` means the
commit is over 5 minutes old, so the deploy did not wait.

Three merges close together can leave the middle one without a tag. The release workflow runs one
at a time and keeps only one run waiting, so the third merge's run cancels the second one's. Rerun
the cancelled run in GitHub Actions: it tags the merge with the next free version.

## Nothing to clear

```
deploy: nothing to clear: deploy.conf of <release> has no cache() step and OPCACHE_RESET_DIR is not set
Try: define cache() in deploy.conf, or set OPCACHE_RESET_DIR in <engine folder>/projects/example.env
```

`cache` has nothing to run. Add a `cache()` step to `deploy.conf` (it runs in the live release
after the next deploy), or set `OPCACHE_RESET_DIR` (see [OPcache](../README.md#opcache)).

## Disk space

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

## The base folder cannot be written

```
deploy: cannot write to <base> (disk full, quota or permissions)
Try: df -h <base>; ls -ld <base>
```

The lock folder could not be made, and no other run holds it. Free space, raise the quota, or give
the deploy user write access to `<base>`.

## An old release cannot be removed

```
deploy: could not remove <base>/releases/<release>; some files in it cannot be deleted, remove it by hand
```

A warning: the new release is live and the deploy is logged `ok`. A file in the old release
belongs to another user (often the web server) or sits in a read-only folder. Remove the folder as
a user who can, for example with the hosting panel's file manager.
