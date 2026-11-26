# Contributing

## Tests

`tests/run.sh` deploys a tiny PHP project (`tests/fixture/`) from a throwaway bare repo into a temp
folder and serves it with `php -S`. It covers:

- Mistakes in a project file, `init` (also `--dry-run`) and `check --setup` before the first deploy.
- Deploys, rollbacks (also to a named release, `rollback --dry-run` and past a new migration) and
  bad releases; `backup()`, `failed()`, `after_rollback()`, `health()` and `cache()`; the kept
  output of a failed step; copies from the live release; `CLEAR_PATHS` and `SHARED`, and that
  shared files survive.
- `status` and `status --all`, `diff`, `path`, `check`, the log and `self log`, the rails and
  `--version`, `--quiet`, `--ref`, the wait for a release tag, the no-release marker and
  `--no-wait`, skipped commits, `freeze`, `down` and `up`.
- Help: the full help, per-command help (`<command> --help`, `-h`, `help <command>`), typo hints,
  usage errors that show the help's usage line, and that the [Commands](../README.md#commands) block lists
  every command and every form of `deploy help <command>`.
- The lock: stale locks, locks with no owner and runs racing for a stale lock.
- Alerts (also for 2000 commits), a token in `REPO_URL`, `PHP_RELOAD_CMD`, the web OPcache reset,
  `STEP_TIMEOUT` and git timeouts, `DISK_LIMIT` and `MIN_FREE_MB`, signals and a closed output
  pipe, a missing live folder and a read-only base folder.
- Prune and `KEEP_RELEASES`, and the `prune` command.
- Staging slots: branches, pull requests, folders, URLs, `slots`, `stage`, `free`, `slots update`
  and `copy-from`, and the `staging` group in its own form and the old one.
- On a terminal: the questions before risky commands and the project menu.
- `deploy self`: update, log and the wait for its tag.

It needs bash, PHP 8.1+, git and curl. The terminal tests also need `script`; without it they are
skipped. A full run takes about 8 minutes on a recent Mac.

```bash
tests/run.sh
```

- `DEPLOY_TEST_PORT` sets the port of the test server (default `8098`). Give each run its own port
  when two run at once.
- `DEPLOY_TEST_KEEP=1` keeps the temp folder after the run, for a look after a failure.

There is no CI for now: run it and `shellcheck deploy tests/run.sh` before a pull request.

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
`refs/no-release/<merge sha>` marker (see [How a deploy runs](../README.md#how-a-deploy-runs)).
The version is `vYEAR.MONTH.COUNT` from the merge date in UTC: the first release of November 2026
is `v2026.11.1`, the next `v2026.11.2`. `deploy self` pulls the tags with the code, and
`deploy --version` shows the one in use. Run right after a merge, `deploy self` waits for the
merge's tag (or its no-release marker) the same way a deploy does, then shows the tag and its notes.

## Screenshots

The README pictures in `docs/images/` come from real runs of `deploy` against a test project named
`example`, built from `tests/fixture/` like the tests do. To make them again after a change to the
output:

```bash
docs/screenshots/make.sh
```

It runs each command in a terminal (`script`), then `docs/screenshots/render.mjs` draws the output
as SVG, in a light and a dark theme. Paths and URLs become `/home/example/...` and `example.com`. It
needs bash, PHP 8.1+, git, curl and Node 18+. `SCREENSHOT_PORT` sets the port of its web server
(default `8172`), and `SCREENSHOT_ANSI=<folder>` keeps the raw captures there.
