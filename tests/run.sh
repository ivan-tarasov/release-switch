#!/usr/bin/env bash
#
# End-to-end test for ./deploy. Deploys tests/fixture/ from a throwaway bare repo into a temp
# folder and serves it with `php -S`. Needs bash, PHP 8.1+, git and curl.
#
#   tests/run.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
PORT="${DEPLOY_TEST_PORT:-8098}"
BASE="$WORK/base"
OLD="$WORK/old"
REPO="$WORK/remote.git"
SERVER_PID=""
STALL_PID=""

cleanup() {
    # The workers are children of the server; they outlive it if only it is killed.
    if [ -n "$SERVER_PID" ]; then
        pkill -P "$SERVER_PID" 2>/dev/null || true
        kill "$SERVER_PID" 2>/dev/null || true
    fi

    [ -z "$STALL_PID" ] || kill "$STALL_PID" 2>/dev/null || true

    # DEPLOY_TEST_KEEP=1 keeps the temp folder for a look after a failure.
    if [ -z "${DEPLOY_TEST_KEEP:-}" ]; then
        rm -rf "$WORK"
    fi
}

trap cleanup EXIT

step() {
    printf '\n--- %s\n' "$*"
}

check() {
    printf 'ok: %s\n' "$*"
}

fail() {
    printf 'FAIL: %s (live: %s, served: %s)\n' "$*" "$(live_release)" "$(served_version)" >&2
    exit 1
}

live_release() {
    basename "$(readlink "$BASE/current" 2>/dev/null)" 2>/dev/null || true
}

served_version() {
    curl --silent --output /dev/null --dump-header - "http://127.0.0.1:$PORT/" \
        | sed -nE 's#^[Xx]-[Aa]pp-[Vv]ersion: *([^[:space:]]+).*#\1#p' | tail -n1
}

# The server can take a moment to notice a switched link, like PHP-FPM.
serves() {
    local tries=10

    until [ "$(served_version)" = "$1" ]; do
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] || return 1
        sleep 1
    done
}

release_count() {
    find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

# Waits until the clock second changes, so the next release gets a newer name than the last one.
next_second() {
    local now
    now="$(date +%s)"

    while [ "$(date +%s)" = "$now" ]; do
        sleep 0.05
    done
}

# Runs the engine for the test project, from a projects/ folder in the temp dir.
run() {
    # No wait for release tags unless a test asks for one.
    env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT="${RELEASE_WAIT:-0}" "$@"
}

deploy() {
    run "$ROOT/deploy" "$@"
}

# A new commit on develop of the bare repo.
commit() {
    local tmp="$WORK/commit"
    rm -rf "$tmp"
    git clone --quiet --branch develop "$REPO" "$tmp"
    printf '%s\n' "$1" > "$tmp/VERSION"
    git -C "$tmp" add VERSION
    git -C "$tmp" -c user.name=test -c user.email=test@example.com commit --quiet -m "$1"
    git -C "$tmp" push --quiet origin develop
}

if curl --silent --output /dev/null "http://127.0.0.1:$PORT/"; then
    printf 'FAIL: %s\n' "port $PORT is in use; set DEPLOY_TEST_PORT" >&2
    exit 1
fi

step "Building a bare repo from tests/fixture"
mkdir "$WORK/src"
cp -R "$ROOT/tests/fixture/." "$WORK/src/"
git -C "$WORK/src" init --quiet -b develop
git -C "$WORK/src" add -A
git -C "$WORK/src" -c user.name=test -c user.email=test@example.com commit --quiet -m "fixture"
git init --quiet --bare "$REPO"
git -C "$WORK/src" push --quiet "$REPO" develop

step "Preparing a live checkout, like a server before init"
git clone --quiet --branch develop "file://$REPO" "$OLD"
printf 'APP_ENV=production\n' > "$OLD/.env"
mkdir "$OLD/data"
printf 'kept across releases\n' > "$OLD/data/note.txt"

mkdir "$WORK/projects"
cat > "$WORK/projects/fixture.env" <<EOF
DEPLOY_BASE="$BASE"
CHECK_URL="http://127.0.0.1:$PORT/"
REPO_URL="file://$REPO"
CHECK_WAIT=999
EOF
cp "$ROOT/projects/example.env" "$WORK/projects/example.env"

step "Help, without a project file loaded"
PROJECTS_DIR="$WORK/empty" "$ROOT/deploy" --help | grep "^Usage: deploy" > /dev/null || fail "--help shows no usage"
if deploy fixture nope 2> /dev/null; then
    fail "an unknown command succeeded"
fi
deploy --help | grep "fixture" > /dev/null || fail "--help does not list the project"
deploy fixture help | grep "CHECK_WAIT .*(10)" > /dev/null || fail "an env var does not win over the project file"
check "--help works, lists projects and shows env overrides; an unknown command fails"

step "Per-command help and typo hints"
deploy rollback --help > "$WORK/help.log"
grep -q "^Usage: deploy \[project\] rollback \[name\] \[--yes\] \[--dry-run\]$" "$WORK/help.log" || fail "rollback --help shows no usage line"
grep -q "^Examples:$" "$WORK/help.log" || fail "rollback --help shows no examples"
! grep -q "^Settings" "$WORK/help.log" || fail "rollback --help shows the full usage"
[ ! -e "$BASE" ] || fail "rollback --help touched DEPLOY_BASE"
deploy fixture rollback -h | grep "^Usage: deploy \[project\] rollback" > /dev/null || fail "fixture rollback -h shows no rollback help"
deploy help down | grep "^Usage: deploy \[project\] down \[reason\] \[--yes\]$" > /dev/null || fail "help down shows no down help"
deploy fixture help copy-from | grep "^Usage: deploy <project>@sN copy-from" > /dev/null || fail "fixture help copy-from shows no copy-from help"
deploy fixture@s1 status --help | grep "^  status --all" > /dev/null || fail "a slot's status --help shows no status help"
PROJECTS_DIR="$WORK/empty" "$ROOT/deploy" stage -h | grep "^Usage: deploy \[project\] stage" > /dev/null \
    || fail "stage -h needs a project"
deploy help | grep "^Settings" > /dev/null || fail "help no longer shows the full usage"
set +e
deploy fixture rolback > /dev/null 2> "$WORK/typo.log"
code=$?
set -e
[ "$code" = 2 ] || fail "a typo exits with $code, not 2"
grep -q "Unknown command: rolback. Did you mean rollback?" "$WORK/typo.log" || fail "no hint for rolback"
grep -q "deploy help" "$WORK/typo.log" || fail "a typo does not point to deploy help"
[ "$(wc -l < "$WORK/typo.log" | tr -d ' ')" = 2 ] || fail "a typo prints more than the hint"
! deploy stauts 2> "$WORK/typo.log" || fail "stauts succeeded"
grep -q "Did you mean status?" "$WORK/typo.log" || fail "no hint for stauts without a project"
! deploy help rolback 2> "$WORK/typo.log" || fail "help rolback succeeded"
grep -q "Did you mean rollback?" "$WORK/typo.log" || fail "no hint for help rolback"
if deploy fixture xyzzy 2> "$WORK/typo.log"; then
    fail "an unknown command succeeded"
fi
grep -q "Unknown command: xyzzy.$" "$WORK/typo.log" || fail "a far typo got a hint"
check "<command> --help, -h and help <command> show one command, with or without a project; a typo gets one hint and exits 2"

step "init refuses a checkout with no deploy.conf"
mkdir "$WORK/no-conf"
if deploy fixture init "$WORK/no-conf" 2> "$WORK/no-conf.log"; then
    fail "init ran on a checkout with no deploy.conf"
fi
grep -q "^Try: add one to the repo, see README.md#deployconf$" "$WORK/no-conf.log" || fail "no hint for a missing deploy.conf"
check "init refused it and pointed to the README"

step "init --dry-run changes nothing"
deploy fixture init "$OLD" --dry-run
[ ! -L "$OLD/.env" ] || fail "dry run moved .env"
[ ! -e "$BASE/shared" ] || fail "dry run created shared/"
check "dry run left everything in place"

step "init"
deploy fixture init "$OLD"
[ -f "$BASE/shared/.env" ] && [ -L "$OLD/.env" ] || fail ".env not moved and linked back"
[ -f "$BASE/shared/data/note.txt" ] && [ -L "$OLD/data" ] || fail "data/ not moved and linked back"
check "shared/ holds .env and data/; the old checkout links to them"

# Serves whatever `current` points at. No realpath cache, so a switch shows on the next request.
# /hook stands in for an alert webhook: it keeps each request body in hook.log. A staging slot
# host (s1.localhost) gets that slot's folder, next to the base folder. /cached acts like
# LSCache: it keeps each request in cached.log and answers with an old version unless the
# request has an rs query or Cache-Control: no-cache. /stall hangs for 15 s once, when the
# stall file exists, then serves the site. A one-time OPcache reset file is logged in opcache.log
# and run from the web root; it answers 500 when opcache-fail exists, and waits 20 s first when
# opcache-stall exists. /hop redirects to /plain with the live version on the redirect only;
# /plain answers 200 with no version.
cat > "$WORK/router.php" <<EOF
<?php
if (\$_SERVER['REQUEST_URI'] === '/plain') {
    return;
}
if (parse_url(\$_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/hop') {
    header('X-App-Version: ' . trim((string) @file_get_contents('$BASE/current/RELEASE')));
    header('Location: /plain', true, 302);
    return;
}
if (parse_url(\$_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/stall') {
    if (@unlink('$WORK/stall')) {
        sleep(15);
    }
    \$_SERVER['REQUEST_URI'] = '/';
}
if (\$_SERVER['REQUEST_URI'] === '/hook') {
    file_put_contents('$WORK/hook.log', file_get_contents('php://input') . "\n", FILE_APPEND);
    return;
}
if (parse_url(\$_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/cached') {
    \$cacheControl = \$_SERVER['HTTP_CACHE_CONTROL'] ?? '-';
    \$line = \$_SERVER['REQUEST_URI'] . ' ' . \$cacheControl . ' ' . (\$_SERVER['HTTP_PRAGMA'] ?? '-');
    file_put_contents('$WORK/cached.log', \$line . "\n", FILE_APPEND);
    if (!isset(\$_GET['rs']) && \$cacheControl !== 'no-cache') {
        header('X-App-Version: old-cached-release');
        return;
    }
    \$_SERVER['REQUEST_URI'] = '/';
}
\$base = '$BASE';
if (preg_match('/^(s[0-9]+)\\./', \$_SERVER['HTTP_HOST'] ?? '', \$m)) {
    \$base = '$WORK/' . \$m[1];
}
\$path = parse_url(\$_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (preg_match('#^/rs-opcache-[0-9a-f]{32}\\.php\$#', \$path)) {
    file_put_contents('$WORK/opcache.log', \$path . "\n", FILE_APPEND);
    if (file_exists('$WORK/opcache-fail')) {
        http_response_code(500);
        return;
    }
    if (file_exists('$WORK/opcache-stall')) {
        sleep(20);
    }
    if (!is_file("\$base/current/public\$path")) {
        http_response_code(404);
        return;
    }
    require "\$base/current/public\$path";
    return;
}
chdir("\$base/current/public");
require "\$base/current/public/index.php";
EOF
PHP_CLI_SERVER_WORKERS=4 php -d realpath_cache_size=0 -S "127.0.0.1:$PORT" "$WORK/router.php" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!

step "First deploy, with the project left out"
deploy > "$WORK/first.log"
first="$(live_release)"
grep -q "Deployed ${first##*-}$" "$WORK/first.log" || fail "a first deploy does not show only its sha"
[[ "$first" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{7,}$ ]] || fail "release name $first is not <date>-<time>-<sha>"
serves "$first" || fail "server does not show $first"
[ "$(cat "$BASE/shared/data/switched")" = "$first" ] || fail "after_switch did not run"
[ -L "$BASE/current/data" ] || fail "data/ is not linked from shared/"
[ ! -e "$BASE/shared/data/failed" ] || fail "failed ran after a good deploy"
[ "$(cat "$BASE/shared/data/backups")" = "$first" ] || fail "backup did not run once in $first"
[ ! -e "$BASE/current/tests" ] && [ ! -e "$BASE/current/dev notes" ] || fail "CLEAR_PATHS are still in $first"
[ -f "$BASE/current/deploy.conf" ] && [ -d "$BASE/current/public" ] || fail "CLEAR_PATHS deleted more than its paths"
check "live: $first; backup ran before build; after_switch ran; data/ is shared; failed did not run; CLEAR_PATHS are gone"

next_second
step "Second deploy, of a new tagged commit"
commit "fixture v2"
git -C "$REPO" tag v2026.11.99 develop
deploy fixture > "$WORK/second.log"
second="$(live_release)"
[[ "$second" =~ ^[0-9]{8}-[0-9]{6}-v2026\.11\.99-[0-9a-f]{7,}$ ]] || fail "release name $second has no tag"
grep -q "Deployed ${first##*-} → v2026.11.99$" "$WORK/second.log" || fail "a tagged deploy does not show sha → tag"
serves "$second" || fail "server does not show $second"
[ "$(cat "$BASE/current/cache/origin")" = "$first" ] || fail "cache/ was not copied from $first"
[ ! -L "$BASE/current/cache" ] || fail "cache/ is a link, not a copy"
check "live: $second; cache/ copied from $first"

step "Rollback"
deploy fixture rollback > "$WORK/rollback.log"
[ "$(live_release)" = "$first" ] || fail "rollback did not go back to $first"
grep -q "Rolled back v2026.11.99 → ${first##*-} (data changes stay applied)$" "$WORK/rollback.log" \
    || fail "rollback does not show tag → sha"
serves "$first" || fail "server does not show $first after rollback"
[ -e "$BASE/releases/$second/.bad" ] || fail "rollback did not mark $second as bad"
[ "$(cat "$BASE/shared/data/rolled_back")" = "$first" ] || fail "after_rollback did not run in $first"
check "rolled back to $first; $second is marked bad; after_rollback ran"

step "A plain deploy skips the rolled-back commit; it logs nothing and changes nothing"
second_sha="$(git -C "$BASE/releases/$second" rev-parse HEAD)"
[ "$(cat "$BASE/.skip-commits")" = "$second_sha"$'\t'"was rolled back"$'\t'"$second" ] \
    || fail "rollback did not remember the commit of $second"
grep -q "^==> Plain deploys skip ${second_sha:0:7} " "$WORK/rollback.log" || fail "rollback does not say plain deploys skip the commit"
releases_now="$(release_count)"
log_now="$(sed -n '$=' "$BASE/deploy.log")"
deploy fixture > "$WORK/skip-bad.log" 2>&1 || fail "a plain deploy of a rolled-back commit failed"
[ "$(cat "$WORK/skip-bad.log")" = "==> ${second_sha:0:7} was rolled back; push a fix, or deploy fixture --force" ] \
    || fail "a plain deploy of a rolled-back commit does not print the one line: $(cat "$WORK/skip-bad.log")"
[ "$(live_release)" = "$first" ] || fail "a plain deploy of a rolled-back commit changed the live release"
[ "$(release_count)" = "$releases_now" ] || fail "a plain deploy of a rolled-back commit made a release"
[ "$(sed -n '$=' "$BASE/deploy.log")" = "$log_now" ] || fail "a plain deploy of a rolled-back commit wrote to deploy.log"
check "the rolled-back commit is remembered; a plain deploy prints one line, exits 0 and builds nothing"

releases_before="$(release_count)"

next_second
step "Failing deploy: the build stops at its first error"
if FIXTURE_FAIL_BUILD=1 deploy fixture --force; then
    fail "deploy with a failing build succeeded"
fi
[ "$(live_release)" = "$first" ] || fail "current moved after a failed build"
[ "$(release_count)" = "$releases_before" ] || fail "the failed release folder was left behind"
[ "$(sed -n '$=' "$BASE/shared/data/failed")" = 1 ] || fail "failed did not run once"
built_release="$(cat "$BASE/shared/data/failed")"
[ "$built_release" != "$first" ] && [ -n "$built_release" ] || fail "failed did not run in the new release"
[ "$(cat "$BASE/.skip-commits")" = "$second_sha"$'\t'"was rolled back"$'\t'"$second" ] \
    || fail "a failed build changed the remembered commits"
check "$first is still live and the broken release is gone; failed ran in it; no commit remembered"

next_second
step "A failing failed() only warns; the deploy still fails"
rm -f "$BASE/shared/data/failed"
if FIXTURE_FAIL_BUILD=1 FIXTURE_FAIL_FAILED=1 deploy fixture --force 2> "$WORK/failed.log"; then
    fail "deploy with a failing build and failed() succeeded"
fi
grep -q "failed failed; the deploy failed anyway" "$WORK/failed.log" || fail "no warning for a failing failed()"
grep -q "build failed" "$WORK/failed.log" || fail "a failing failed() hid the build error"
[ -e "$BASE/shared/data/failed" ] || fail "failed did not run"
[ "$(live_release)" = "$first" ] || fail "current moved after a failed build"
rm -f "$BASE/shared/data/failed"
check "the warning shows and the build error stays"

next_second
step "A failed step keeps its output, redacted, in <base>/deploy-failed.log; the error and status name it"
kept="$BASE/deploy-failed.log"
if FIXTURE_FAIL_BUILD=1 FIXTURE_BUILD_SAY="fetching https://user:s3cret@example.com/app.git" \
    deploy fixture --force > "$WORK/kept.out" 2> "$WORK/kept.err"; then
    fail "deploy with a failing build succeeded"
fi
cat "$kept"
[ "$(sed -n 1p "$kept")" = "Step: build" ] || fail "the kept output does not name the step"
sed -n 2p "$kept" | grep -qE "^Release: [0-9]{8}-" || fail "the kept output does not name the release"
sed -n 3p "$kept" | grep -qE "^Time: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$" || fail "the kept output has no time"
grep -qxF "build: npm run prod exited with 1" "$kept" || fail "the kept output misses the step's stderr"
grep -qxF "fetching https://***@example.com/app.git" "$kept" || fail "the kept output misses the step's stdout, redacted"
! grep -q "s3cret" "$kept" || fail "the kept output shows the password"
grep -q "^fetching https://" "$WORK/kept.out" || fail "the step's stdout did not stay on stdout"
grep -qxF "build: npm run prod exited with 1" "$WORK/kept.err" || fail "the step's stderr did not stay on stderr"
grep -qxF "deploy: build failed; its output is in $kept" "$WORK/kept.err" || fail "the error does not name the kept output"
deploy fixture status > "$WORK/kept-status.log"
grep -E "^Failed: +build at [0-9T:-]+Z; its output is in " "$WORK/kept-status.log" | grep -qF "$kept" \
    || fail "status does not point to the kept output: $(cat "$WORK/kept-status.log")"
check "the build output is kept with its step, release and time, the password hidden; the error and status name the file"

next_second
step "Failing deploy: a failing backup stops it before build"
if FIXTURE_FAIL_BACKUP=1 deploy fixture --force > "$WORK/backup.log" 2> "$WORK/backup-err.log"; then
    fail "deploy with a failing backup succeeded"
fi
grep -q "backup failed" "$WORK/backup-err.log" || fail "the failure does not show the backup error"
! grep -q "Running build" "$WORK/backup.log" || fail "build ran after a failing backup"
[ "$(live_release)" = "$first" ] || fail "current moved after a failed backup"
[ "$(release_count)" = "$releases_before" ] || fail "the failed release folder was left behind"
[ -e "$BASE/shared/data/failed" ] || fail "failed did not run after a failing backup"
rm -f "$BASE/shared/data/failed"
check "$first is still live; build did not run; failed ran"

next_second
step "Failing deploy: preflight refuses a wrong .env"
sed -i.bak 's/production/staging/' "$BASE/shared/.env"
if deploy fixture --force 2> /dev/null; then
    fail "deploy with a wrong .env succeeded"
fi
mv "$BASE/shared/.env.bak" "$BASE/shared/.env"
[ "$(live_release)" = "$first" ] || fail "current moved after a failed preflight"
check "preflight stopped it"

next_second
step "Failing deploy: the check fails after the switch"
if CHECK_URL="http://127.0.0.1:$PORT/missing" deploy fixture --force 2> "$WORK/check.log"; then
    fail "deploy with a failing check succeeded"
fi
cat "$WORK/check.log" >&2
grep -q "answered 404" "$WORK/check.log" || fail "the failure does not show the 404"
grep -q "^Try: open http://127.0.0.1:$PORT/missing: it answered 404 with version " "$WORK/check.log" \
    || fail "no hint for the failed check"
[ "$(live_release)" = "$first" ] || fail "no automatic rollback to $first"
serves "$first" || fail "server does not show $first after the rollback"
[ "$(release_count)" = "$((releases_before + 1))" ] || fail "the failed release was not set aside"
check "rolled back to $first automatically; the failed release waits in .failed-*"

step "A plain deploy skips a commit that failed its check; --quiet prints nothing; status shows it"
failed_release="$(find "$BASE/releases" -mindepth 1 -maxdepth 1 -name '.failed-*' | sed 's#.*/\.failed-##')"
[ "$(sed -n 1p "$BASE/.skip-commits")" = "$second_sha"$'\t'"failed its check"$'\t'"$failed_release" ] \
    || fail "the failed check did not remember the commit of $failed_release"
[ "$(sed -n '$=' "$BASE/.skip-commits")" = 1 ] || fail "the commit is remembered twice"
releases_now="$(release_count)"
log_now="$(sed -n '$=' "$BASE/deploy.log")"
deploy fixture > "$WORK/skip-check.log" 2>&1 || fail "a plain deploy of a commit that failed its check failed"
[ "$(cat "$WORK/skip-check.log")" = "==> ${second_sha:0:7} failed its check; push a fix, or deploy fixture --force" ] \
    || fail "a plain deploy of a commit that failed its check does not print the one line: $(cat "$WORK/skip-check.log")"
deploy fixture --quiet > "$WORK/quiet.out" 2> "$WORK/quiet.err" || fail "a quiet deploy of a commit that failed its check failed"
[ ! -s "$WORK/quiet.out" ] && [ ! -s "$WORK/quiet.err" ] || fail "a quiet deploy of a commit that failed its check printed something"
[ "$(live_release)" = "$first" ] || fail "a skipped deploy changed the live release"
[ "$(release_count)" = "$releases_now" ] || fail "a skipped deploy made a release"
[ "$(sed -n '$=' "$BASE/deploy.log")" = "$log_now" ] || fail "a skipped deploy wrote to deploy.log"
deploy fixture status > "$WORK/skip-status.log"
grep -qxF "Skips:     ${second_sha:0:7} failed its check ($failed_release); push a fix, or deploy fixture --force" \
    "$WORK/skip-status.log" || fail "status does not show the skipped commit"
deploy status --all | grep -qE "^fixture .*tip ${second_sha:0:7} failed its check" || fail "status --all does not note the skipped tip"
check "the failed commit is skipped with one line, silently with --quiet; status and status --all show it"

next_second
step "A failing after_switch only warns; the deploy deletes the failed release"
FIXTURE_FAIL_AFTER=1 deploy fixture --force > "$WORK/after.log"
grep -qF "after_switch failed; its output is in $BASE/deploy-failed.log; carrying on" "$WORK/after.log" \
    || fail "no warning for after_switch"
latest="$(live_release)"
serves "$latest" || fail "server does not show $latest"
[ "$(release_count)" = "$((releases_before + 1))" ] || fail "the failed release is still there"
[ ! -e "$BASE/.skip-commits" ] || fail "a good --force deploy of the skipped commit did not clear it"
check "live: $latest, failed release gone; the good --force deploy cleared the skipped commit"

step "Status"
DISPLAY_TZ=America/Toronto deploy fixture status > "$WORK/status.log"
cat "$WORK/status.log"
grep -qE "^Live: +$latest$" "$WORK/status.log" || fail "status does not show the live release"
grep -qE "deployed today at [0-9:]+ E[SD]T$" "$WORK/status.log" || fail "status does not show today's time in DISPLAY_TZ only"
grep -qE "^Rollback: +$first$" "$WORK/status.log" || fail "status does not skip the bad $second"
grep -qF "$second  (bad; rollback skips it)" "$WORK/status.log" || fail "status does not mark $second as bad"
grep -qF "* $latest  (live)" "$WORK/status.log" || fail "status does not mark the live release"
grep -q "Lock: *free" "$WORK/status.log" || fail "status does not show a free lock"
grep -q "answered 200, version $latest (matches live)" "$WORK/status.log" || fail "status does not check the site"
grep -q "^Pending: *none (live is the tip of develop)" "$WORK/status.log" || fail "status shows pending commits when live is the tip"
! grep -q "^Skips:" "$WORK/status.log" || fail "status shows a skipped commit after a good deploy"
! grep -q "^Failed:" "$WORK/status.log" || fail "status points to the kept step output after a good deploy"
[ "$(sed -n 1p "$BASE/deploy-failed.log")" = "Step: after_switch" ] || fail "the good deploy did not keep the after_switch output"
check "status shows the live release, the rollback target and the site"

step "Diff says so when nothing is pending"
deploy fixture diff > "$WORK/diff.log" || fail "diff failed with nothing pending"
cat "$WORK/diff.log"
[ "$(cat "$WORK/diff.log")" = "Nothing pending: $latest is the tip of develop" ] || fail "diff does not say that nothing is pending"
check "diff prints one line and exits with 0"

step "Status lists commits not deployed yet"
commit "fixture pending one"
commit "fixture pending two"
deploy fixture status > "$WORK/pending.log"
cat "$WORK/pending.log"
grep -q "^Pending: *2 commit(s) on develop, not deployed yet" "$WORK/pending.log" || fail "status does not count the pending commits"
grep -qE "^ +[0-9a-f]+ fixture pending two$" "$WORK/pending.log" || fail "status does not list the pending commits"
deploy status --all | grep -qE "^fixture +.*2 pending" || fail "status --all does not note the pending commits"
check "status lists 2 pending commits; status --all notes them"

step "Diff lists the files the next deploy would change"
log_lines="$(wc -l < "$BASE/deploy.log")"
deploy fixture diff > "$WORK/diff.log" || fail "diff failed with pending commits"
cat "$WORK/diff.log"
grep -qE "^Changes: +$latest \([0-9a-f]{7}\) to develop \([0-9a-f]{7}\)$" "$WORK/diff.log" || fail "diff does not name the two ends"
grep -q "^  M  VERSION$" "$WORK/diff.log" || fail "diff does not list the changed file"
grep -q "^1 file changed: 0 added, 1 changed, 0 deleted$" "$WORK/diff.log" || fail "diff shows no count line"
[ "$(deploy fixture diff --quiet)" = "$(cat "$WORK/diff.log")" ] || fail "diff --quiet does not print the file list"
[ "$(live_release)" = "$latest" ] || fail "diff changed the live release"
[ "$(wc -l < "$BASE/deploy.log")" = "$log_lines" ] || fail "diff wrote a log line"
[ ! -e "$BASE/.deploy.lock" ] || fail "diff left a lock"
# --ref: a branch, the live commit, and an older commit with other files.
live_sha="$(git -C "$BASE/current" rev-parse HEAD)"
deploy fixture diff --ref develop | grep "^  M  VERSION$" > /dev/null || fail "diff --ref develop does not list the changed file"
[ "$(deploy fixture diff --ref "$live_sha")" = "Nothing pending: $latest already runs $live_sha" ] \
    || fail "diff --ref of the live commit does not say that nothing is pending"
git -C "$WORK/commit" rm --quiet tests/smoke.txt
printf 'new\n' > "$WORK/commit/added.txt"
git -C "$WORK/commit" add added.txt
git -C "$WORK/commit" -c user.name=test -c user.email=test@example.com commit --quiet -m "diff branch"
git -C "$WORK/commit" push --quiet origin HEAD:refs/heads/diff-test
deploy fixture diff --ref=diff-test > "$WORK/diff.log" || fail "diff --ref of another branch failed"
cat "$WORK/diff.log"
grep -q "^  A  added.txt$" "$WORK/diff.log" || fail "diff --ref does not list an added file"
grep -q "^  D  tests/smoke.txt$" "$WORK/diff.log" || fail "diff --ref does not list a deleted file"
grep -q "^3 files changed: 1 added, 1 changed, 1 deleted$" "$WORK/diff.log" || fail "diff --ref counts the files wrong"
git -C "$REPO" update-ref -d refs/heads/diff-test
if deploy fixture diff --ref no-such-ref > /dev/null 2> "$WORK/diff.err"; then
    fail "diff --ref of an unknown ref succeeded"
fi
grep -q "no tag, branch or commit no-such-ref in the repo" "$WORK/diff.err" || fail "no message for an unknown --ref"
if deploy fixture diff --ref > /dev/null 2> "$WORK/diff.err"; then
    fail "diff --ref without a value succeeded"
fi
grep -q "usage: deploy \[project\] diff \[--ref <tag, branch or sha>\]" "$WORK/diff.err" || fail "no usage for diff --ref without a value"
# No live release yet: an error and a hint.
printf 'DEPLOY_BASE="%s"\nREPO_URL="file://%s"\n' "$WORK/nolive" "$REPO" > "$WORK/projects/nolive.env"
if deploy nolive diff > /dev/null 2> "$WORK/diff.err"; then
    fail "diff without a live release succeeded"
fi
grep -q "no live release to compare with" "$WORK/diff.err" || fail "no message for diff without a live release"
grep -q "^Try: deploy nolive status$" "$WORK/diff.err" || fail "no hint for diff without a live release"
rm -rf "$WORK/projects/nolive.env" "$WORK/nolive"
check "diff lists files with A, M and D, counts them, takes --ref, and fails with a hint when nothing is live"

step "Status of all projects"
deploy status --all > "$WORK/all.log"
cat "$WORK/all.log"
grep -qE "^fixture +$latest +.*200, matches live" "$WORK/all.log" || fail "status --all does not show the fixture row"
# A second project with its own settings: no base folder yet.
printf 'DEPLOY_BASE="%s"\nCHECK_URL="http://127.0.0.1:%s/"\n' "$WORK/other" "$PORT" > "$WORK/projects/other.env"
if deploy status --all > "$WORK/all.log"; then
    fail "status --all passed with a broken project"
fi
cat "$WORK/all.log"
grep -qE "^other +none +.*no base folder" "$WORK/all.log" || fail "status --all does not show the second project"
grep -qE "^fixture +$latest " "$WORK/all.log" || fail "the second project changed the fixture row"
[ ! -e "$WORK/other" ] || fail "status --all created a base folder"
rm "$WORK/projects/other.env"
check "status --all shows each project with its own settings, and fails when one is broken"

step "Deploy times: today, yesterday, older"
# Two more projects with a live release from yesterday and from 3 days ago, at noon in Toronto.
for age in 1 3; do
    # shellcheck disable=SC2016 # PHP code, not shell.
    stamp="$(php -r '$d = new DateTime("today 12:00", new DateTimeZone("America/Toronto"));
        $d->modify("-" . $argv[1] . " day");
        echo $d->format("Y-m-d"), " ", $d->setTimezone(new DateTimeZone("UTC"))->format("Ymd-His");' "$age")"
    day="${stamp%% *}"
    release="${stamp#* }-abc1234"
    mkdir -p "$WORK/age$age/releases/$release"
    ln -s "releases/$release" "$WORK/age$age/current"
    printf 'DEPLOY_BASE="%s"\nDISPLAY_TZ=America/Toronto\n' "$WORK/age$age" > "$WORK/projects/age$age.env"
done
DISPLAY_TZ=America/Toronto deploy status --all > "$WORK/times.log"
cat "$WORK/times.log"
grep -qE "^fixture +[^ ]+ +today at [0-9]{2}:[0-9]{2} E[SD]T " "$WORK/times.log" || fail "a deploy from today does not say today"
grep -qE "^age1 +[^ ]+ +yesterday at 12:00 E[SD]T " "$WORK/times.log" || fail "a deploy from yesterday does not say yesterday"
grep -qE "^age3 +[^ ]+ +$day 12:00 E[SD]T " "$WORK/times.log" || fail "an older deploy does not show its date"
rm "$WORK/projects/age1.env" "$WORK/projects/age3.env"
check "deploy times say today and yesterday, and show the date for older ones"

step "Path prints the live release and the base folder"
[ "$(deploy path fixture)" = "$BASE/releases/$(live_release)" ] || fail "path does not print the live release"
[ "$(deploy fixture path)" = "$BASE/releases/$(live_release)" ] || fail "path after the project differs"
[ "$(DEPLOY_RAILS=1 deploy path fixture --base)" = "$BASE" ] || fail "path --base does not print only the base folder"
mkdir -p "$WORK/empty-base"
printf 'DEPLOY_BASE="%s"\n' "$WORK/empty-base" > "$WORK/projects/empty.env"
if deploy path empty > "$WORK/path.out" 2> "$WORK/path.err"; then
    fail "path succeeded with no live release"
fi
[ ! -s "$WORK/path.out" ] || fail "path printed to stdout with no live release"
grep -q "has no live release" "$WORK/path.err" || fail "path does not say there is no live release"
rm "$WORK/projects/empty.env"
check "path prints the live release, --base the base folder; no live release fails"

step "Rollback to a named release"
if deploy fixture rollback v2026.11.99 2> "$WORK/ambiguous.log"; then
    fail "rollback to a part shared by two releases succeeded"
fi
grep -q "matches 2 releases" "$WORK/ambiguous.log" || fail "no message for a part shared by two releases"
if deploy fixture rollback nope 2> "$WORK/nope.log"; then
    fail "rollback to a missing release succeeded"
fi
grep -q "^Try: deploy fixture status (it lists the releases)$" "$WORK/nope.log" || fail "no hint for a missing release"
deploy fixture rollback
[ "$(live_release)" = "$first" ] || fail "rollback did not skip the bad $second"
serves "$first" || fail "server does not show $first"
FIXTURE_FAIL_ROLLBACK=1 deploy fixture rollback "${second:0:15}" 2> "$WORK/after-rollback.log" \
    || fail "a failing after_rollback failed the rollback"
grep -qF "after_rollback failed; its output is in $BASE/deploy-failed.log; the rollback stands" \
    "$WORK/after-rollback.log" || fail "no warning for after_rollback"
[ "$(cat "$BASE/shared/data/rolled_back")" = "$second" ] || fail "after_rollback did not run in $second"
[ "$(live_release)" = "$second" ] || fail "rollback by time did not go to $second"
serves "$second" || fail "server does not show $second after a rollback by time"
[ ! -e "$BASE/releases/$second/.bad" ] || fail "going to $second by name did not clear its bad mark"
[ ! -d "$BASE/.deploy.lock" ] || fail "rollback left the lock behind"
check "rollback skipped the bad $second; naming it went there and cleared the mark; a failing after_rollback only warned; unclear and missing names refused"

step "A new commit deploys as before and clears the skipped commit"
grep -q "^$second_sha"$'\t'"was rolled back"$'\t'"$latest$" "$BASE/.skip-commits" || fail "the plain rollback did not remember the commit"
commit "fixture after rollback"
deploy fixture > "$WORK/new-commit.log" || fail "a new commit after a rollback did not deploy"
grep -q "^==> Deployed " "$WORK/new-commit.log" || fail "a new commit after a rollback did not deploy"
[ "$(cat "$BASE/current/VERSION")" = "fixture after rollback" ] || fail "the new commit is not live"
[ ! -e "$BASE/.skip-commits" ] || fail "a good deploy of a new commit did not clear the skipped commit"
check "the new commit is live and nothing is skipped any more"

step "A second deploy waits for the lock"
mkdir "$BASE/.deploy.lock"
if deploy fixture 2> "$WORK/lock.log"; then
    fail "deploy ran while locked"
fi
grep -q "another deploy is running (no owner, [0-9]* s old)" "$WORK/lock.log" || fail "no lock message"
# Held by this test's shell, which is alive.
printf '%s %s deploy\n' "$$" "$(date +%s)" > "$BASE/.deploy.lock/owner"
if deploy fixture 2> "$WORK/lock.log"; then
    fail "deploy ran while a live process held the lock"
fi
grep -q "another deploy is running (PID $$, deploy, 0 min)" "$WORK/lock.log" || fail "the lock message does not name the owner"
grep -q "^Try: deploy fixture status, or wait for PID $$$" "$WORK/lock.log" || fail "no hint for a held lock"
deploy fixture status > "$WORK/lock-status.log"
grep -q "^Lock: *held (PID $$, deploy, 0 min)" "$WORK/lock-status.log" || fail "status does not show the lock owner"
code=0
deploy fixture > /dev/null 2>&1 || code=$?
for args in "" rollback down up cache; do
    quiet_code=0
    # cache needs a cache() step or OPCACHE_RESET_DIR to reach the lock.
    # shellcheck disable=SC2086 # Word splitting wanted: no args for a plain deploy.
    OPCACHE_RESET_DIR=public deploy fixture $args --quiet > "$WORK/quiet.out" 2> "$WORK/quiet.err" || quiet_code=$?
    [ "$quiet_code" = "$code" ] || fail "a quiet ${args:-deploy} on a held lock exited with $quiet_code, not $code"
    [ ! -s "$WORK/quiet.out" ] && [ ! -s "$WORK/quiet.err" ] || fail "a quiet ${args:-deploy} on a held lock printed something"
done
[ -d "$BASE/.deploy.lock" ] || fail "a refused run removed the held lock"
rm -rf "$BASE/.deploy.lock"
mkdir "$BASE/.deploy.lock"
if deploy fixture --quiet 2> "$WORK/lock.log"; then
    fail "a quiet deploy ran while a young lock with no owner was there"
fi
grep -q "another deploy is running (no owner, [0-9]* s old)" "$WORK/lock.log" || fail "a quiet deploy hides a lock with no owner"
check "locked deploy refused; the message and status name the owner; --quiet hides a live owner, not a missing one"

step "A lock whose process is gone is removed"
sh -c 'exit 0' &
dead=$!
wait "$dead"
printf '%s %s deploy\n' "$dead" "$(date +%s)" > "$BASE/.deploy.lock/owner"
deploy fixture status > "$WORK/lock-status.log"
grep -q "^Lock: *stale (PID $dead" "$WORK/lock-status.log" || fail "status does not show a stale lock"
deploy fixture > "$WORK/stale.log"
grep -q "Removing a stale lock: PID $dead is gone" "$WORK/stale.log" || fail "deploy did not remove the stale lock"
[ ! -d "$BASE/.deploy.lock" ] || fail "deploy left the lock behind"
fresh="$(live_release)"
serves "$fresh" || fail "server does not show $fresh"
mkdir "$BASE/.deploy.lock"
printf '%s %s deploy\n' "$dead" "$(date +%s)" > "$BASE/.deploy.lock/owner"
deploy fixture --quiet > "$WORK/quiet.out" 2> "$WORK/quiet.err" || fail "a quiet deploy past a stale lock failed"
[ ! -s "$WORK/quiet.out" ] || fail "a quiet deploy past a stale lock wrote to stdout"
grep -q "^deploy: Removing a stale lock: PID $dead is gone$" "$WORK/quiet.err" || fail "a quiet deploy hides the stale lock"
[ ! -d "$BASE/.deploy.lock" ] || fail "a quiet deploy left the stale lock behind"
check "deploy removed the stale lock and went live with $fresh; --quiet still names the stale lock"

step "A lock with no owner blocks for 60 s, then is removed"
mkdir "$BASE/.deploy.lock"
if deploy fixture 2> "$WORK/lock.log"; then
    fail "deploy ran while a young lock with no owner was there"
fi
grep -q "another deploy is running (no owner, [0-9]* s old)" "$WORK/lock.log" || fail "no message for a young lock with no owner"
# touch -t reads local time; UTC on both sides keeps it right.
TZ=UTC touch -t "$(php -r 'echo gmdate("YmdHi.s", time() - 120);')" "$BASE/.deploy.lock"
deploy fixture status > "$WORK/lock-status.log"
grep -q "^Lock: *stale (no owner, 1[0-9][0-9] s old" "$WORK/lock-status.log" || fail "status does not show a stale lock with no owner"
# The deploy takes the lock, then stops: nothing new is on develop.
deploy fixture > "$WORK/stale.log"
grep -q "Removing a stale lock: no owner, 1[0-9][0-9] s old" "$WORK/stale.log" || fail "deploy did not remove the lock with no owner"
grep -q "Nothing new on develop" "$WORK/stale.log" || fail "deploy did not run after removing the lock with no owner"
[ ! -d "$BASE/.deploy.lock" ] || fail "deploy left the lock behind"
check "a young lock with no owner blocks; an old one is removed with a message and the deploy runs"

step "Three runs racing on one stale lock: one holder at a time, and one always takes it"
# Each run: the engine without its last line (main "$@"), then acquire_lock. Random sleeps in
# lock_state (before and after the check) and say() widen the gaps between finding the lock stale
# and acting on it.
mkdir "$WORK/race"
sed '$d' "$ROOT/deploy" > "$WORK/race.sh"
cat >> "$WORK/race.sh" <<'EOF'
DEPLOY_BASE="$RACE" PHP_BIN=php
eval "real_$(declare -f lock_state)"
lock_state() {
    local state
    sleep "0.0$((RANDOM % 3))"
    state="$(real_lock_state "$@")"
    sleep "0.0$((RANDOM % 3))"
    printf '%s\n' "$state"
}
say() { sleep "0.0$((RANDOM % 3))"; }
touch "$RACE/ready.$1"
until [ -e "$RACE/go" ]; do :; done
sleep "0.0$((RANDOM % 2))"
acquire_lock deploy 2> "$RACE/err.$1"
mkdir "$RACE/inside" 2> /dev/null || touch "$RACE/both"
touch "$RACE/won"
sleep 0.05
rmdir "$RACE/inside" 2> /dev/null || true
rm -rf "$LOCK_DIR"
EOF
for round in $(seq 40); do
    rm -f "$WORK/race/ready."* "$WORK/race/err."* "$WORK/race/go" "$WORK/race/won"
    mkdir "$WORK/race/.deploy.lock"
    printf '%s %s deploy\n' "$dead" "$(date +%s)" > "$WORK/race/.deploy.lock/owner"
    racers=()
    for name in a b c; do
        RACE="$WORK/race" bash "$WORK/race.sh" "$name" &
        racers+=("$!")
    done
    until [ -e "$WORK/race/ready.a" ] && [ -e "$WORK/race/ready.b" ] && [ -e "$WORK/race/ready.c" ]; do :; done
    touch "$WORK/race/go"
    # Not a bare wait: the web server is a child too. The losers fail on the lock.
    for racer in "${racers[@]}"; do
        wait "$racer" || true
    done
    [ ! -e "$WORK/race/both" ] || fail "two runs held the lock at once in round $round"
    [ -e "$WORK/race/won" ] || fail "no run took the stale lock in round $round"
    [ ! -e "$WORK/race/.deploy.lock" ] || fail "the lock is left behind after round $round"
    [ ! -e "$WORK/race/.deploy.lock.break" ] || fail "the break folder is left behind after round $round"
    others="$(cat "$WORK/race/err."* | grep -v -e "another deploy is running" -e "^Try: deploy status" || true)"
    [ -z "$others" ] || fail "a losing run failed for another reason in round $round: $others"
done
check "40 rounds of three runs on one stale lock: one holder at a time, losers say another deploy runs"

step "A stale lock removal that stopped half way is reported"
mkdir "$BASE/.deploy.lock" "$BASE/.deploy.lock.break"
printf '%s %s deploy\n' "$dead" "$(date +%s)" > "$BASE/.deploy.lock/owner"
TZ=UTC touch -t "$(php -r 'echo gmdate("YmdHi.s", time() - 120);')" "$BASE/.deploy.lock.break"
if deploy fixture --quiet > "$WORK/break.log" 2>&1; then
    fail "deploy ran past a stuck stale lock removal"
fi
grep -q "a stale lock removal stopped half way; remove .*\.deploy\.lock\.break" "$WORK/break.log" || fail "deploy does not name the stuck break folder"
rm -rf "$BASE/.deploy.lock" "$BASE/.deploy.lock.break"
check "a break folder older than 60 s blocks with a message that names it"

step "A deploy with nothing new stops; --force builds anyway"
releases_now="$(release_count)"
backups_now="$(sed -n '$=' "$BASE/shared/data/backups")"
deploy fixture > "$WORK/skip.log"
cat "$WORK/skip.log"
grep -q "Nothing new on develop: $fresh already runs" "$WORK/skip.log" || fail "no message for a deploy with nothing new"
[ "$(release_count)" = "$releases_now" ] || fail "a deploy with nothing new made a release"
[ "$(live_release)" = "$fresh" ] || fail "a deploy with nothing new changed the live release"
[ "$(sed -n '$=' "$BASE/shared/data/backups")" = "$backups_now" ] || fail "backup ran on a deploy with nothing new"
next_second
deploy fixture --force > /dev/null
fresh="$(live_release)"
[ "$(release_count)" = "$((releases_now + 1))" ] || fail "--force did not build a release"
serves "$fresh" || fail "server does not show $fresh"
check "nothing new: no release, no backup; --force: live with $fresh"

next_second
step "--quiet prints nothing on success and the same errors on failure"
commit "fixture quiet"
git -C "$REPO" tag v2026.10.5 develop
deploy fixture --quiet > "$WORK/quiet.out" 2> "$WORK/quiet.err" || fail "a quiet deploy failed"
[ ! -s "$WORK/quiet.out" ] && [ ! -s "$WORK/quiet.err" ] || fail "a quiet deploy printed something"
[ "$(live_release)" != "$fresh" ] || fail "a quiet deploy did not switch"
fresh="$(live_release)"
serves "$fresh" || fail "server does not show $fresh after a quiet deploy"
deploy fixture -q > "$WORK/quiet.out" 2> "$WORK/quiet.err" || fail "a quiet deploy with nothing new failed"
[ ! -s "$WORK/quiet.out" ] && [ ! -s "$WORK/quiet.err" ] || fail "a quiet deploy with nothing new printed something"
[ "$(live_release)" = "$fresh" ] || fail "a quiet deploy with nothing new changed the live release"
next_second
if FIXTURE_FAIL_BUILD=1 deploy fixture --force > "$WORK/loud.out" 2> "$WORK/loud.err"; then
    fail "deploy with a failing build succeeded"
fi
next_second
if FIXTURE_FAIL_BUILD=1 deploy fixture --force --quiet > "$WORK/quiet.out" 2> "$WORK/quiet.err"; then
    fail "a quiet deploy with a failing build succeeded"
fi
[ ! -e "$BASE/.skip-commits" ] || fail "a failed build remembered its commit"
[ ! -s "$WORK/quiet.out" ] || fail "a quiet failed deploy wrote to stdout"
cmp -s "$WORK/loud.err" "$WORK/quiet.err" || fail "a quiet failed deploy shows other errors than a plain one"
grep -q "^build: npm run prod exited with 1$" "$WORK/quiet.err" || fail "a quiet failed deploy hides the step output"
grep -qxF "deploy: build failed; its output is in $BASE/deploy-failed.log" "$WORK/quiet.err" \
    || fail "a quiet failed deploy hides the error"
deploy fixture freeze "quiet test" > /dev/null
code=0
deploy fixture --force > /dev/null 2>&1 || code=$?
[ "$code" -ne 0 ] || fail "a deploy ran while frozen"
for args in "--force" "rollback"; do
    quiet_code=0
    # shellcheck disable=SC2086 # Word splitting wanted.
    deploy fixture $args -q > "$WORK/quiet.out" 2> "$WORK/quiet.err" || quiet_code=$?
    [ "$quiet_code" = "$code" ] || fail "a quiet frozen $args exited with $quiet_code, not $code"
    [ ! -s "$WORK/quiet.out" ] && [ ! -s "$WORK/quiet.err" ] || fail "a quiet frozen $args printed something"
done
deploy fixture unfreeze > /dev/null
[ "$(live_release)" = "$fresh" ] || fail "a failed quiet deploy changed the live release"
check "quiet: silent deploy, skip and freeze; a failure shows the step output, error and hint"

step "Freeze stops deploys and rollbacks until unfreeze"
deploy fixture freeze "moving hosts" > /dev/null
if deploy fixture --force 2> "$WORK/freeze.log"; then
    fail "deploy ran while frozen"
fi
grep -q "deploys are frozen since today at .*: moving hosts$" "$WORK/freeze.log" || fail "no freeze message for deploy"
grep -q "^Try: deploy fixture unfreeze$" "$WORK/freeze.log" || fail "no hint for a frozen deploy"
if deploy fixture rollback 2> /dev/null; then
    fail "rollback ran while frozen"
fi
[ "$(live_release)" = "$fresh" ] || fail "the live release changed while frozen"
deploy fixture status > "$WORK/freeze-status.log"
grep -q "^Frozen: *since today at .*: moving hosts$" "$WORK/freeze-status.log" || fail "status does not show the freeze"
deploy status --all > "$WORK/freeze-all.log" || true
grep -qE "^fixture .*frozen" "$WORK/freeze-all.log" || fail "status --all does not note the freeze"
deploy fixture unfreeze > /dev/null
[ ! -e "$BASE/.frozen" ] || fail "unfreeze left the freeze file"
deploy fixture > /dev/null || fail "deploy failed after unfreeze"
check "freeze refused deploy and rollback, showed in status; unfreeze allowed deploys again"

step "Deploy a chosen tag, commit or branch with --ref"
next_second
deploy fixture --ref v2026.11.99 > /dev/null
tagged="$(live_release)"
[[ "$tagged" =~ -v2026\.11\.99-[0-9a-f]{7,}$ ]] || fail "--ref v2026.11.99 deployed $tagged"
serves "$tagged" || fail "server does not show $tagged"
deploy fixture --ref v2026.11.99 > "$WORK/ref.log"
grep -q "$tagged already runs v2026.11.99" "$WORK/ref.log" || fail "--ref of the live commit did not stop"
[ "$(live_release)" = "$tagged" ] || fail "--ref of the live commit changed the live release"
next_second
older="$(git -C "$REPO" rev-parse --short develop~1)"
deploy fixture --ref "$older" > "$WORK/ref.log"
[[ "$(live_release)" == *"-$older" ]] || fail "--ref $older deployed $(live_release)"
grep -q "Deployed v2026.11.99 → $older$" "$WORK/ref.log" || fail "an untagged deploy does not show tag → sha"
if deploy fixture --ref nope 2> "$WORK/ref.log"; then
    fail "--ref of a missing ref succeeded"
fi
grep -q "no tag, branch or commit nope" "$WORK/ref.log" || fail "no message for a missing ref"
next_second
deploy --ref=develop > "$WORK/ref.log"
fresh="$(live_release)"
grep -q "^1 commit(s):$" "$WORK/ref.log" || fail "--ref=develop does not list the commit it ships"
[[ "$fresh" == *"-$(git -C "$REPO" rev-parse --short develop)" ]] || fail "--ref=develop deployed $fresh"
serves "$fresh" || fail "server does not show $fresh"
check "--ref deployed a tag, a commit and a branch; the live commit and a missing ref stopped"

step "Option values cannot be empty or start with a dash"
live="$(live_release)"
log_lines="$(wc -l < "$BASE/deploy.log")"
# Each line: the usage to expect, then the arguments after the project.
while read -r kind args; do
    case "$kind" in
        ref) usage="usage: deploy [project] [--ref <tag, branch or sha>] [--force] [--no-wait] [--yes]" ;;
        branch) usage="usage: deploy <project>@sN --branch <name>" ;;
        pr) usage="usage: deploy <project>@sN --pr <number>" ;;
        diff) usage="usage: deploy [project] diff [--ref <tag, branch or sha>]" ;;
    esac
    # shellcheck disable=SC2086 # The arguments are split on purpose.
    if deploy fixture $args > /dev/null 2> "$WORK/option.err"; then
        fail "deploy fixture $args succeeded"
    fi
    grep -qF "$usage" "$WORK/option.err" || fail "no usage for deploy fixture $args"
done <<'CASES'
ref --ref
ref --ref --force
ref --ref -x
ref --ref=
ref --ref=--force
ref --force --ref= --yes
branch --branch
branch --branch --force
branch --branch=
branch --branch=-x
pr --pr
pr --pr --force
pr --pr=
pr --pr=-7
diff diff --ref=
diff diff --ref=--quiet
diff diff --ref --quiet
CASES
[ "$(live_release)" = "$live" ] || fail "an option with no value changed the live release"
[ "$(wc -l < "$BASE/deploy.log")" = "$log_lines" ] || fail "an option with no value wrote a log line"
[ ! -e "$BASE/.deploy.lock" ] || fail "an option with no value left a lock"
check "--ref, --branch and --pr refused an empty value and a dash value in both forms, and changed nothing"

step "Shared files survive deploys"
[ "$(curl --silent "http://127.0.0.1:$PORT/")" = "kept across releases" ] || fail "the shared note is gone"
check "the note from before init is still served"

step "Rails on a terminal"
commit "fixture rails"
next_second
DEPLOY_RAILS=1 deploy fixture > "$WORK/rails.log"
cat "$WORK/rails.log"
fresh="$(live_release)"
grep -qE "^┌  release-switch [0-9a-fv.+]+ · fixture · deploy$" "$WORK/rails.log" || fail "no opening line with the version"
grep -q "^◆  Running build$" "$WORK/rails.log" || fail "steps are not on the rails"
grep -qE "^◇  Running build \([0-9]+s\)$" "$WORK/rails.log" || fail "the build step does not show its time"
grep -qE "^◇  Cloning .* \([0-9]+s\)$" "$WORK/rails.log" || fail "the clone does not show its time"
grep -qE "^◇  Checking http://127.0.0.1:$PORT/ \([0-9]+s\)$" "$WORK/rails.log" || fail "the site check does not show its time"
! grep -q $'\r' "$WORK/rails.log" || fail "the rails off a terminal have a spinner"
grep -qE "^│    [0-9a-f]+ fixture rails$" "$WORK/rails.log" || fail "the shipped commits are not on the rail"
grep -qE "^└  Done in [0-9]+s$" "$WORK/rails.log" || fail "no closing line"
if FIXTURE_FAIL_BUILD=1 DEPLOY_RAILS=1 deploy fixture --force > "$WORK/rails.log" 2> "$WORK/rails-err.log"; then
    fail "a deploy with a failing build succeeded"
fi
grep -qxF "■  build failed; its output is in $BASE/deploy-failed.log" "$WORK/rails-err.log" || fail "the failure is not marked"
grep -qxF "build: npm run prod exited with 1" "$BASE/deploy-failed.log" || fail "the rails did not keep the step output"
grep -qE "^└  Failed after [0-9]+s$" "$WORK/rails.log" || fail "no closing line for the failure"
DEPLOY_RAILS=1 deploy fixture status > "$WORK/rails.log"
grep -q "^│  Live: *$fresh$" "$WORK/rails.log" || fail "status is not on the rail"
deploy fixture status > "$WORK/rails.log"
grep -q "^Live: *$fresh$" "$WORK/rails.log" || fail "status has rails in a pipe"
deploy fixture --force > "$WORK/plain.log"
grep -q "^==> Running build$" "$WORK/plain.log" || fail "a plain deploy does not show the build step"
grep -q "^==> Checking http://127.0.0.1:$PORT/$" "$WORK/plain.log" || fail "a plain deploy does not show the site check"
! grep -qE $'[0-9]s\\)$|◆|\r' "$WORK/plain.log" || fail "a plain deploy shows times or a spinner"
[ "$(bash -c "$(sed -n '/^duration() {/,/^}/p' "$ROOT/deploy"); duration 38; echo; duration 72")" = $'38s\n1m 12s' ] \
    || fail "times do not read 38s and 1m 12s"
check "a deploy, a failed deploy and status on the rails with step times; plain lines in a pipe"

step "Down and up for maintenance"
deploy fixture down "database upgrade" > /dev/null
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$PORT/")" = 503 ] \
    || fail "down did not run the down() step"
deploy fixture status > "$WORK/down-status.log"
grep -q "^Down: *since today at .*: database upgrade$" "$WORK/down-status.log" || fail "status does not show down"
grep -q "(down for maintenance)$" "$WORK/down-status.log" || fail "status does not explain the 503"
deploy status --all > "$WORK/down-all.log" || true
grep -qE "^fixture .*503, down for maintenance .*down" "$WORK/down-all.log" || fail "status --all does not note down"
deploy fixture check > "$WORK/down-check.log" 2>&1 || fail "check failed while down"
grep -q "^ok    fixture: site: 503, down for maintenance$" "$WORK/down-check.log" || fail "check does not accept the 503"
grep -q "^ok    fixture: health: not checked, down for maintenance$" "$WORK/down-check.log" \
    || fail "check ran health() while down"
next_second
deploy fixture --force > "$WORK/down-deploy.log" 2>&1 || fail "deploy failed while down"
grep -q "not checking .*: the site is down for maintenance; check it with: deploy fixture up$" "$WORK/down-deploy.log" \
    || fail "deploy while down does not warn to run up"
fresh="$(live_release)"
deploy fixture up > /dev/null || fail "up failed"
[ ! -e "$BASE/.down" ] || fail "up left the down file"
serves "$fresh" || fail "server does not show $fresh after up"
deploy fixture log 3 > "$WORK/down-log.log"
grep -qE "down +[0-9-]+.*ok" "$WORK/down-log.log" || fail "the log has no down"
grep -qE "up +$fresh +ok" "$WORK/down-log.log" || fail "the log has no up"
check "down served a 503; status, check and deploy knew it; up brought $fresh back"

step "Check"
deploy fixture check > "$WORK/check-ok.log" 2> "$WORK/check-err.log" || fail "check failed on a healthy site"
cat "$WORK/check-ok.log"
grep -q "^ok    fixture: live: $fresh$" "$WORK/check-ok.log" || fail "check does not show the live release"
grep -q "^ok    fixture: shared: all present$" "$WORK/check-ok.log" || fail "check does not check shared links"
grep -q "^ok    fixture: site: 200, matches live$" "$WORK/check-ok.log" || fail "check does not check the site"
grep -q "^ok    fixture: health: queue is empty$" "$WORK/check-ok.log" || fail "check does not run health()"
[ ! -s "$WORK/check-err.log" ] || fail "check wrote to stderr on a healthy site"
mv "$BASE/shared/data" "$BASE/shared/data.moved"
if CHECK_URL="http://127.0.0.1:$PORT/missing" deploy fixture check > /dev/null 2> "$WORK/check-err.log"; then
    fail "check passed with a missing shared folder and a 404"
fi
mv "$BASE/shared/data.moved" "$BASE/shared/data"
cat "$WORK/check-err.log"
grep -q "^FAIL  fixture: shared: missing data$" "$WORK/check-err.log" || fail "check does not report the broken link"
grep -q "^FAIL  fixture: site: .* answered 404" "$WORK/check-err.log" || fail "check does not report the 404"
printf '%s %s deploy\n' "$$" "$(($(date +%s) - 45 * 60))" > "$WORK/owner"
mkdir "$BASE/.deploy.lock"
mv "$WORK/owner" "$BASE/.deploy.lock/owner"
if deploy fixture check > /dev/null 2> "$WORK/check-err.log"; then
    fail "check passed with a deploy running for 45 min"
fi
rm -rf "$BASE/.deploy.lock"
grep -q "^FAIL  fixture: lock: held for 45 min" "$WORK/check-err.log" || fail "check does not report a stuck deploy"
mkdir "$BASE/.deploy.lock"
TZ=UTC touch -t "$(php -r 'echo gmdate("YmdHi.s", time() - 120);')" "$BASE/.deploy.lock"
if deploy fixture check > /dev/null 2> "$WORK/check-err.log"; then
    fail "check passed with a stale lock with no owner"
fi
rm -rf "$BASE/.deploy.lock"
grep -q "^FAIL  fixture: lock: stale (no owner, 1[0-9][0-9] s old)" "$WORK/check-err.log" || fail "check does not report a lock with no owner"
if FIXTURE_UNHEALTHY=1 deploy fixture check > /dev/null 2> "$WORK/check-err.log"; then
    fail "check passed with a failing health()"
fi
grep -q "^FAIL  fixture: health: queue is stuck$" "$WORK/check-err.log" || fail "check does not report the health() problem"
deploy check --all > "$WORK/check-all.log"
grep -q "^ok    fixture: site: 200, matches live$" "$WORK/check-all.log" || fail "check --all does not check the fixture"
check "check passes on a healthy site; reports broken shared links, a bad site, a stuck deploy and a failing health() on stderr"
# A bad sleep time fails health() half way; the rest of it would still print "queue is empty".
if FIXTURE_HEALTH_SLEEP=x deploy check --all > /dev/null 2> "$WORK/check-all-err.log"; then
    fail "check --all passed with a health() that failed half way"
fi
grep -q "^FAIL  fixture: health: " "$WORK/check-all-err.log" || fail "check --all does not report the health() problem"
check "check --all stops health() at its first failing command, like check"
deploy fixture check --quiet > "$WORK/check-ok.log" 2> "$WORK/check-err.log" || fail "a quiet check failed on a healthy site"
[ ! -s "$WORK/check-ok.log" ] && [ ! -s "$WORK/check-err.log" ] || fail "a quiet check printed something on a healthy site"
deploy check --all -q > "$WORK/check-ok.log" 2> "$WORK/check-err.log" || fail "a quiet check --all failed"
[ ! -s "$WORK/check-ok.log" ] && [ ! -s "$WORK/check-err.log" ] || fail "a quiet check --all printed something"
if CHECK_URL="http://127.0.0.1:$PORT/missing" deploy fixture check -q > "$WORK/check-ok.log" 2> "$WORK/check-err.log"; then
    fail "a quiet check passed with a 404"
fi
[ ! -s "$WORK/check-ok.log" ] || fail "a quiet check printed ok lines"
grep -q "^FAIL  fixture: site: .* answered 404" "$WORK/check-err.log" || fail "a quiet check hides the 404"
check "a quiet check prints only problems"

step "Alerts"
export ALERTS="$WORK/alerts.log"
: > "$ALERTS"
# shellcheck disable=SC2016 # Expanded by the engine's sh -c, not here.
alert_cmd='printf "%s|%s\n" "$NOTIFY_EVENT" "$NOTIFY_TEXT" >> "$ALERTS"'
if FIXTURE_FAIL_BUILD=1 NOTIFY_URL="http://127.0.0.1:$PORT/hook" NOTIFY_CMD="$alert_cmd; exit 3" deploy fixture --force 2> "$WORK/notify.log"; then
    fail "a deploy with a failing build succeeded"
fi
grep -qxF "deploy: NOTIFY_CMD failed" "$WORK/notify.log" || fail "no warning for a failing NOTIFY_CMD"
cat "$ALERTS"
grep -qE "^deploy\|fixture: deploy [0-9-]+.*: failed: build \(build failed; its output is in [^)]*/deploy-failed\.log\)$" "$ALERTS" || fail "no alert for the failed build"
grep -qF '"text":"fixture: deploy ' "$WORK/hook.log" || fail "NOTIFY_URL got no JSON alert"
grep -qF '"event":"deploy"' "$WORK/hook.log" || fail "the JSON alert has no event"
FIXTURE_DETAILS="$WORK/details" NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null
grep -qx "FORCED=1" "$WORK/details" || fail "a --force deploy did not set DEPLOY_FORCED=1"
[ "$(wc -l < "$ALERTS" | tr -d ' ')" = 1 ] || fail "a successful deploy sent an alert without NOTIFY_ON=all"
NOTIFY_ON=all NOTIFY_URL="http://127.0.0.1:1/" NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null 2> "$WORK/notify.log" \
    || fail "an alert that cannot be sent failed the deploy"
grep -q "could not send the alert to NOTIFY_URL" "$WORK/notify.log" || fail "no warning for an alert that cannot be sent"
grep -qE "^deploy\|fixture: deploy [0-9-]+.*: ok \([0-9]+s\)$" "$ALERTS" || fail "NOTIFY_ON=all sent no alert for a good deploy"
# STEP_TIMEOUT also caps NOTIFY_CMD, so a slow one costs 1 s here.
STEP_TIMEOUT=1 NOTIFY_CMD="$alert_cmd; sleep 30" deploy fixture rollback > /dev/null 2> "$WORK/notify.log" \
    || fail "a slow NOTIFY_CMD failed the rollback"
grep -qE "^rollback\|fixture: rollback [0-9-]+.*: ok, from " "$ALERTS" || fail "no alert for a rollback"
grep -qxF "deploy: NOTIFY_CMD ran past 1 s" "$WORK/notify.log" || fail "no warning for a slow NOTIFY_CMD"
check "alerts for a failed build and a rollback; good deploys only with NOTIFY_ON=all; a dead webhook, a failing or a slow NOTIFY_CMD only warns"

step "A token in REPO_URL never shows in output, deploy.log or alerts"
secret_url="http://user:ghp_FAKE123@127.0.0.1:1/missing.git"
: > "$ALERTS"
for args in "--force" "--ref main"; do
    # shellcheck disable=SC2086 # Split on purpose.
    if REPO_URL="$secret_url" NOTIFY_CMD="$alert_cmd" deploy fixture $args > "$WORK/secret.out" 2> "$WORK/secret.err"; then
        fail "a deploy from a missing repo succeeded"
    fi
    grep -q "could not clone http://\*\*\*@127.0.0.1:1/missing.git" "$WORK/secret.err" || fail "no redacted clone error"
done
[ -s "$ALERTS" ] || fail "no alert for the failed clone"
if grep -F ghp_FAKE123 "$WORK/secret.out" "$WORK/secret.err" "$ALERTS" "$BASE/deploy.log"; then
    fail "the token shows in the output, the alert or deploy.log"
fi
REPO_URL="$secret_url" deploy fixture help > "$WORK/secret.out"
grep -q "REPO_URL .*(http://\*\*\*@127.0.0.1:1/missing.git)" "$WORK/secret.out" || fail "help does not show the redacted REPO_URL"
if grep -F ghp_FAKE123 "$WORK/secret.out"; then
    fail "help shows the token"
fi
REPO_URL="git@github.com:owner/repo.git" deploy fixture help | grep -qF "(git@github.com:owner/repo.git)" \
    || fail "help hides an SSH REPO_URL"
REPO_URL="ssh://git@github.com/owner/repo.git" deploy fixture help | grep -qF "(ssh://git@github.com/owner/repo.git)" \
    || fail "help hides an ssh:// REPO_URL"
check "a token in REPO_URL is redacted in errors, alerts, deploy.log and help; SSH URLs stay as they are"

step "A deploy lists the commits it ships, in the output, the log and the alert"
commit "fixture shipped one"
commit "fixture shipped two"
next_second
before="$(live_release)"
: > "$WORK/hook.log"
# shellcheck disable=SC2016 # Expanded by the engine's sh -c, not here.
details_cmd='printf "%s|%s|%s|%s\n" "$NOTIFY_STATUS" "$NOTIFY_RELEASE" "$NOTIFY_DURATION" "$DEPLOY_SHA" > "$NOTIFY_FILE"'
NOTIFY_ON=all NOTIFY_URL="http://127.0.0.1:$PORT/hook" NOTIFY_CMD="$alert_cmd; $details_cmd" NOTIFY_FILE="$WORK/notify-env" \
    FIXTURE_DETAILS="$WORK/details" deploy fixture > "$WORK/shipped.log"
cat "$WORK/shipped.log"
grep -q "^2 commit(s):$" "$WORK/shipped.log" || fail "deploy does not count the commits it ships"
grep -qE "^  [0-9a-f]+ fixture shipped two$" "$WORK/shipped.log" || fail "deploy does not list the commits it ships"
deploy fixture log 1 > "$WORK/shipped-log.log"
cat "$WORK/shipped-log.log"
grep -q "ok ([0-9]*s)  2 commit(s): fixture shipped two; fixture shipped one$" "$WORK/shipped-log.log" \
    || fail "the log does not list the commits"
grep -qE "^  [0-9a-f]+ fixture shipped one$" "$ALERTS" || fail "the alert does not list the commits"
check "the output, the log and the alert list both commits"

sha="$(git -C "$REPO" rev-parse develop)"
cat "$WORK/details"
printf 'SHA=%s\nREF=develop\nPREVIOUS=%s\nAUTHOR=test\nMESSAGE=fixture shipped two\nPERFORMER=%s\nFORCED=0\n' \
    "$sha" "$before" "${USER:-$(id -un)}" | diff - "$WORK/details" || fail "a step did not get the deploy details"
cat "$WORK/notify-env"
grep -qE "^ok\|$(live_release)\|[0-9]+\|$sha$" "$WORK/notify-env" || fail "NOTIFY_CMD did not get the deploy details"
cat "$WORK/hook.log"
# shellcheck disable=SC2016 # PHP code, not shell.
php -r '
    $a = json_decode(trim(file_get_contents($argv[1])), true);
    $want = ["event" => "deploy", "status" => "ok", "release" => $argv[2], "previous" => $argv[3], "sha" => $argv[4],
        "ref" => "develop"];
    foreach ($want as $key => $value) {
        if (($a[$key] ?? null) !== $value) {
            fwrite(STDERR, "$key is " . json_encode($a[$key] ?? null) . "\n");
            exit(1);
        }
    }
    exit(is_int($a["duration"]) && count($a["commits"]) === 2 && $a["commits"][0]["subject"] === "fixture shipped two"
        && $a["commits"][0]["sha"] === $argv[4] ? 0 : 1);
' "$WORK/hook.log" "$(live_release)" "$before" "$sha" || fail "the JSON alert lacks the deploy details"
check "steps, NOTIFY_CMD and the JSON alert get the deploy details and commits"

step "An alert for 2000 shipped commits arrives, and PHP gets only the lines it shows"
many="$WORK/many"
rm -rf "$many"
git clone --quiet --branch develop "$REPO" "$many"
# fast-import, as 2000 git commit runs take long.
awk -v parent="$(git -C "$many" rev-parse HEAD)" -v now="$(date +%s)" 'BEGIN {
    for (i = 1; i <= 2000; i++) {
        msg = "fixture many " i
        printf "commit refs/heads/develop\ncommitter test <test@example.com> %d +0000\ndata %d\n%s\n", now, length(msg) + 1, msg
        if (i == 1) printf "from %s\n", parent
        printf "\n"
    }
}' | git -C "$many" fast-import --quiet
git -C "$many" push --quiet origin develop
rm -rf "$many"
# Keeps the longest argument of each PHP run, then runs PHP.
cat > "$WORK/php-args" <<'SH'
#!/usr/bin/env bash
longest=0
for arg in "$@"; do
    [ "${#arg}" -le "$longest" ] || longest="${#arg}"
done
printf '%s\n' "$longest" >> "$PHP_ARGS_LOG"
exec php "$@"
SH
chmod +x "$WORK/php-args"
: > "$WORK/php-args.log"
: > "$WORK/hook.log"
: > "$ALERTS"
NOTIFY_ON=all NOTIFY_URL="http://127.0.0.1:$PORT/hook" NOTIFY_CMD="$alert_cmd" PHP_BIN="$WORK/php-args" \
    PHP_ARGS_LOG="$WORK/php-args.log" deploy fixture > /dev/null || fail "a deploy of 2000 commits failed"
cat "$ALERTS"
grep -q "^2000 commit(s):$" "$ALERTS" || fail "the alert text does not count the 2000 commits"
grep -q "^  \.\.\. and 1990 more$" "$ALERTS" || fail "the alert text does not say how many more"
grep -qE "^  [0-9a-f]{7} fixture many 2000$" "$ALERTS" || fail "the alert does not list the newest commit"
longest="$(sort -n "$WORK/php-args.log" | tail -n1)"
[ "${longest:-0}" -gt 0 ] && [ "$longest" -lt 8000 ] || fail "PHP got an argument of $longest characters"
# shellcheck disable=SC2016 # PHP code, not shell.
php -r '
    $a = json_decode(trim(file_get_contents($argv[1])), true);
    exit(count($a["commits"]) === 20 && $a["commits"][0]["subject"] === "fixture many 2000"
        && $a["commits"][19]["subject"] === "fixture many 1981" ? 0 : 1);
' "$WORK/hook.log" || fail "the JSON alert does not have the first 20 commits"
check "the alert for 2000 commits arrives with the same first lines; PHP gets $longest characters at most"

step "Check alerts only when the result changes"
: > "$ALERTS"
: > "$WORK/hook.log"
for _ in 1 2; do
    if CHECK_URL="http://127.0.0.1:$PORT/missing" NOTIFY_URL="http://127.0.0.1:$PORT/hook" NOTIFY_CMD="$alert_cmd" \
        deploy fixture check > /dev/null 2>&1; then
        fail "check passed with a 404"
    fi
done
grep -qF "\"status\":\"problem\",\"release\":\"$(live_release)\",\"previous\":\"\",\"sha\":\"\"" "$WORK/hook.log" \
    || fail "the check alert has no status, or deploy details"
cat "$ALERTS"
[ "$(grep -c "^check|fixture: check failed: site: .* answered 404" "$ALERTS")" = 1 ] || fail "check did not alert once for the 404"
NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null || fail "check failed on a healthy site"
grep -q "^check|fixture: check ok again$" "$ALERTS" || fail "no alert when the check is ok again"
[ ! -e "$BASE/.check-failed" ] || fail "check kept the failure state after it was ok"
NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null
[ "$(wc -l < "$ALERTS" | tr -d ' ')" = 2 ] || fail "a healthy check sent another alert"
check "one alert for a failing check, one when it is ok again, none while nothing changes"

step "Check skips the site and health() while a deploy runs"
: > "$ALERTS"
if CHECK_URL="http://127.0.0.1:$PORT/missing" NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null 2>&1; then
    fail "check passed with a 404"
fi
[ -f "$BASE/.check-failed" ] || fail "a failed check left no alert state"
cp "$BASE/.check-failed" "$WORK/check-failed.before"
mkdir "$BASE/.deploy.lock"
# Held by this test's shell, which is alive.
printf '%s %s deploy\n' "$$" "$(date +%s)" > "$BASE/.deploy.lock/owner"
CHECK_URL="http://127.0.0.1:$PORT/missing" FIXTURE_UNHEALTHY=1 NOTIFY_CMD="$alert_cmd" deploy fixture check \
    > "$WORK/busy-check.log" 2>&1 || fail "check failed while a deploy runs"
cat "$WORK/busy-check.log"
grep -q "^ok    fixture: site and health: not checked, a deploy is running (PID $$, deploy, 0 min)$" \
    "$WORK/busy-check.log" || fail "check does not say a deploy is running"
grep -qE "fixture: (site|health):" "$WORK/busy-check.log" && fail "check ran the site or health() while a deploy runs"
grep -q "^ok    fixture: disk: " "$WORK/busy-check.log" || fail "check skipped the disk while a deploy runs"
CHECK_URL="http://127.0.0.1:$PORT/missing" deploy fixture check --quiet > "$WORK/quiet.out" 2> "$WORK/quiet.err" \
    || fail "a quiet check failed while a deploy runs"
[ ! -s "$WORK/quiet.out" ] && [ ! -s "$WORK/quiet.err" ] || fail "a quiet check printed something while a deploy runs"
[ "$(wc -l < "$ALERTS" | tr -d ' ')" = 1 ] || fail "check alerted while a deploy runs"
cmp -s "$BASE/.check-failed" "$WORK/check-failed.before" || fail "check changed the alert state while a deploy runs"
deploy status --all > "$WORK/busy-all.log" || fail "status --all failed while a deploy runs"
grep -qE "^fixture .*not checked, a deploy is running" "$WORK/busy-all.log" || fail "status --all does not say a deploy is running"
if DISK_LIMIT=1K NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null 2> "$WORK/busy-disk.log"; then
    fail "check passed over DISK_LIMIT while a deploy runs"
fi
grep -q "^FAIL  fixture: disk: " "$WORK/busy-disk.log" || fail "check hid a disk problem while a deploy runs"
printf '%s %s deploy\n' "$dead" "$(date +%s)" > "$BASE/.deploy.lock/owner"
if CHECK_URL="http://127.0.0.1:$PORT/missing" deploy fixture check > "$WORK/stale-check.log" 2>&1; then
    fail "check passed with a 404 and a stale lock"
fi
grep -q "^FAIL  fixture: site: .* answered 404" "$WORK/stale-check.log" || fail "a stale lock skipped the site check"
grep -q "^ok    fixture: lock: stale (PID $dead" "$WORK/stale-check.log" || fail "check does not report the stale lock"
rm -rf "$BASE/.deploy.lock"
NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null || fail "check failed once the deploy was done"
grep -q "^check|fixture: check ok again$" "$ALERTS" || fail "no alert when the check is ok again after the deploy"
check "a live deploy lock skips the site and health(), keeps the alert state; disk still fails; a stale lock does not skip"

step "An unwritable deploy.log never stops the alert or the cleanup"
# A folder in its place: appends fail, as on a full or read-only disk.
mv "$BASE/deploy.log" "$WORK/deploy.log.kept"
mkdir "$BASE/deploy.log"
: > "$ALERTS"
if FIXTURE_FAIL_BUILD=1 NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null 2> "$WORK/nolog.log"; then
    fail "a deploy with a failing build succeeded"
fi
cat "$WORK/nolog.log"
grep -qE "^deploy\|fixture: deploy [0-9-]+.*: failed: build \(build failed; its output is in [^)]*/deploy-failed\.log\)$" "$ALERTS" \
    || fail "no alert for the failed build with an unwritable deploy.log"
[ ! -e "$BASE/.deploy.lock" ] || fail "the lock stayed after a failed deploy with an unwritable deploy.log"
[ "$(grep -c "could not write to $BASE/deploy.log" "$WORK/nolog.log")" = 1 ] \
    || fail "no single warning for the unwritable deploy.log"
NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null 2> "$WORK/nolog.log" \
    || fail "an unwritable deploy.log failed a good deploy"
serves "$(live_release)" || fail "the site does not serve the release deployed with an unwritable deploy.log"
[ "$(wc -l < "$ALERTS" | tr -d ' ')" = 1 ] || fail "a good deploy with an unwritable deploy.log sent an alert"
rmdir "$BASE/deploy.log"
mv "$WORK/deploy.log.kept" "$BASE/deploy.log"
check "with an unwritable deploy.log, a failed deploy still alerts and frees the lock, and a good deploy passes"

step "Check alerts when the base folder is missing"
sed "s#^DEPLOY_BASE=.*#DEPLOY_BASE=\"$WORK/gone\"#" "$WORK/projects/fixture.env" > "$WORK/projects/gone.env"
: > "$ALERTS"
for _ in 1 2; do
    if NOTIFY_CMD="$alert_cmd" deploy gone check > /dev/null 2> "$WORK/gone.log"; then
        fail "check passed with no base folder"
    fi
done
cat "$WORK/gone.log"
cat "$ALERTS"
grep -q "^FAIL  gone: no base folder: $WORK/gone$" "$WORK/gone.log" || fail "check does not report the missing base folder"
[ "$(grep -c "^check|gone: check failed: no base folder: $WORK/gone$" "$ALERTS")" = 1 ] \
    || fail "check did not alert once for the missing base folder"
[ ! -e "$WORK/gone" ] || fail "check created the base folder"
if NOTIFY_CMD="$alert_cmd" deploy check --all > "$WORK/gone-all.log" 2>&1; then
    fail "check --all passed with a missing base folder"
fi
grep -q "^ok    fixture: site: 200, matches live$" "$WORK/gone-all.log" || fail "check --all stopped at the missing base folder"
[ "$(wc -l < "$ALERTS" | tr -d ' ')" = 1 ] || fail "check --all alerted again for the missing base folder"
ln -s "$BASE" "$WORK/gone"
NOTIFY_CMD="$alert_cmd" deploy gone check > /dev/null || fail "check failed once the base folder came back"
grep -q "^check|gone: check ok again$" "$ALERTS" || fail "no alert when the base folder came back"
[ ! -e "$WORK/projects/.gone.check-failed" ] || fail "check kept the missing base state after it was ok"
rm "$WORK/gone" "$WORK/projects/gone.env"
check "a missing base folder alerts once, is not created, does not stop check --all, and alerts ok when back"

step "Disk space: check, status and deploy"
used_kb="$(du -sk "$BASE" | awk '{ print $1 }')"
free_mb="$(df -Pk "$BASE" | awk 'NR == 2 { print int($4 / 1024) }')"
DISK_LIMIT="$((used_kb * 10 + 1024))K" deploy fixture check > "$WORK/disk.log" || fail "check failed under a big DISK_LIMIT"
grep -qE "^ok    fixture: disk: [0-9.]+[KMGT] used of [0-9.]+[KMGT], [0-9.]+[KMGT] free$" "$WORK/disk.log" \
    || fail "check does not show the disk line with the limit"
: > "$ALERTS"
if DISK_LIMIT=1K NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null 2> "$WORK/disk.log"; then
    fail "check passed over a tiny DISK_LIMIT"
fi
cat "$WORK/disk.log"
grep -qE "^FAIL  fixture: disk: [0-9.]+[KMGT] used of 1K, [0-9.]+[KMGT] free; over DISK_LIMIT \(1K\)$" "$WORK/disk.log" \
    || fail "check does not report the size over DISK_LIMIT"
grep -q "^check|fixture: check failed: disk: " "$ALERTS" || fail "no alert for the disk over DISK_LIMIT"
NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null || fail "check failed with no DISK_LIMIT"
grep -q "^check|fixture: check ok again$" "$ALERTS" || fail "no alert when the disk is ok again"
if DISK_LIMIT=2GB deploy fixture check > /dev/null 2> "$WORK/disk.log"; then
    fail "DISK_LIMIT=2GB was not refused"
fi
grep -q "DISK_LIMIT must be a size like 2G, 500M or 1.5G, or plain bytes, not '2GB'" "$WORK/disk.log" \
    || fail "no message for DISK_LIMIT=2GB"
deploy fixture status > "$WORK/disk.log"
grep -qE "^Disk: +[0-9.]+[KMGT] used, [0-9.]+[KMGT] free$" "$WORK/disk.log" || fail "status does not show the Disk line"
if MIN_FREE_MB="$((free_mb + 1000000))" deploy fixture check > /dev/null 2> "$WORK/disk.log"; then
    fail "check passed under a huge MIN_FREE_MB"
fi
grep -q "^FAIL  fixture: disk: .*; under MIN_FREE_MB ($((free_mb + 1000000))M free)$" "$WORK/disk.log" \
    || fail "check does not report free space under MIN_FREE_MB"
before="$(live_release)"
count="$(release_count)"
if MIN_FREE_MB="$((free_mb + 1000000))" deploy fixture --force > "$WORK/disk.out" 2> "$WORK/disk.log"; then
    fail "a deploy passed under a huge MIN_FREE_MB"
fi
cat "$WORK/disk.log"
grep -q "under MIN_FREE_MB ($((free_mb + 1000000))M); free some space before deploying" "$WORK/disk.log" \
    || fail "no clear message for too little free space"
grep -q "^Try: deploy fixture prune (removes failed and old releases)$" "$WORK/disk.log" \
    || fail "the free space error does not name prune"
grep -q "Cloning" "$WORK/disk.out" && fail "a deploy with too little free space started to clone"
[ "$(live_release)" = "$before" ] || fail "a deploy with too little free space changed the live release"
[ "$(release_count)" = "$count" ] || fail "a deploy with too little free space made a release"
[ ! -d "$BASE/.deploy.lock" ] || fail "a deploy with too little free space left the lock behind"
DISK_LIMIT=1K deploy fixture --force > /dev/null 2> "$WORK/disk.log" || fail "a deploy over DISK_LIMIT failed"
grep -q "over DISK_LIMIT (1K)" "$WORK/disk.log" || fail "a deploy over DISK_LIMIT did not warn"
check "check passes under DISK_LIMIT and fails over it with an alert; status shows the disk; too little free space stops check and deploy"

step "A release that cannot be removed only warns; the deploy is ok"
oldest="$(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -exec basename {} \; | sort | head -n1)"
kept="$(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | wc -l | tr -d ' ')"
[ "$oldest" != "$(live_release)" ] && [ "$kept" -ge 2 ] || fail "no old release to prune"
# A read-only folder with a file in it, as one made by the web server user.
mkdir -p "$BASE/releases/$oldest/stuck" "$BASE/releases/.failed-stuck/stuck"
touch "$BASE/releases/$oldest/stuck/file" "$BASE/releases/.failed-stuck/stuck/file"
chmod 555 "$BASE/releases/$oldest/stuck" "$BASE/releases/.failed-stuck/stuck"
: > "$ALERTS"
rm -f "$BASE/shared/data/failed"
status=0
KEEP_RELEASES="$kept" NOTIFY_CMD="$alert_cmd" deploy fixture --force \
    > /dev/null 2> "$WORK/stuck.log" || status=$?
chmod 755 "$BASE/releases/$oldest/stuck" "$BASE/releases/.failed-stuck/stuck"
cat "$WORK/stuck.log"
[ "$status" -eq 0 ] || fail "a release that cannot be removed failed the deploy (exit $status)"
grep -q "could not remove $BASE/releases/$oldest; " "$WORK/stuck.log" || fail "no warning that names the old release"
grep -q "could not remove $BASE/releases/.failed-stuck; " "$WORK/stuck.log" || fail "no warning that names the failed release"
[ -d "$BASE/releases/$oldest" ] || fail "the old release that cannot be removed is gone"
tail -n1 "$BASE/deploy.log" | grep -qE "	deploy	[^	]+	ok	" || fail "the deploy is not logged ok"
[ ! -s "$ALERTS" ] || fail "a deploy with a release that cannot be removed sent an alert"
[ ! -e "$BASE/shared/data/failed" ] || fail "the failed step ran"
rm -rf "$BASE/releases/$oldest" "$BASE/releases/.failed-stuck"
check "an old or failed release that cannot be removed gives a warning; the deploy is logged ok, exits 0, no alert"

step "A base folder that cannot be written gives its own error"
chmod 555 "$BASE"
status=0
deploy fixture --force > /dev/null 2> "$WORK/readonly.log" || status=$?
chmod 755 "$BASE"
cat "$WORK/readonly.log"
[ "$status" -ne 0 ] || fail "a deploy into a read-only base folder passed"
grep -q "cannot write to $BASE (disk full, quota or permissions)" "$WORK/readonly.log" \
    || fail "no clear message for a base folder that cannot be written"
grep -q "Try: df -h $BASE; ls -ld $BASE" "$WORK/readonly.log" || fail "no hint for a base folder that cannot be written"
grep -q "another deploy" "$WORK/readonly.log" && fail "a read-only base folder is reported as another deploy"
[ ! -e "$BASE/.deploy.lock" ] || fail "a lock was left behind"
check "a read-only base folder says it cannot be written, with a hint, and not that another deploy runs"

step "Deploy history"
DISPLAY_TZ=America/Toronto deploy fixture log 50 > "$WORK/history.log"
cat "$WORK/history.log"
[ "$(grep -cE ' deploy +.* ok \(' "$WORK/history.log")" -ge 3 ] || fail "the log misses successful deploys"
grep -q "failed: build" "$WORK/history.log" || fail "the log misses the failed build"
grep -q "failed: preflight" "$WORK/history.log" || fail "the log misses the failed preflight"
grep -q "failed: check, switched back to $first" "$WORK/history.log" || fail "the log misses the failed check"
grep -qE "rollback +$first +ok, from $latest" "$WORK/history.log" || fail "the log misses a rollback"
grep -q "E[SD]T " "$WORK/history.log" || fail "the log does not use DISPLAY_TZ"
[ "$(deploy fixture log 2 | wc -l | tr -d ' ')" = 2 ] || fail "log 2 does not show 2 lines"
check "the log shows deploys, failures and rollbacks"

step "PHP_RELOAD_CMD runs after the switch; a failing one only warns"
next_second
PHP_RELOAD_CMD="readlink \"$BASE/current\" > \"$WORK/reload.txt\"; exit 3" deploy fixture --force > "$WORK/reload.log" \
    || fail "a failing PHP_RELOAD_CMD failed the deploy"
reloaded="$(live_release)"
[ "$(cat "$WORK/reload.txt")" = "releases/$reloaded" ] || fail "PHP_RELOAD_CMD did not run after the switch"
grep -q "PHP_RELOAD_CMD failed; carrying on" "$WORK/reload.log" || fail "no warning for a failing PHP_RELOAD_CMD"
serves "$reloaded" || fail "server does not show $reloaded"
check "PHP_RELOAD_CMD ran with $reloaded linked; its failure only warned"

step "A hangup or TERM during PHP_RELOAD_CMD keeps the new release live"
for signal in HUP:129 TERM:143; do
    next_second
    code=0
    # shellcheck disable=SC2016 # Expanded by the engine's sh -c, not here: $PPID is the deploy.
    PHP_RELOAD_CMD='kill -'"${signal%:*}"' $PPID' deploy fixture --force > /dev/null 2> "$WORK/signal.log" || code=$?
    [ "$code" = "${signal#*:}" ] || fail "${signal%:*} exited with $code, not ${signal#*:}"
    hung="$(live_release)"
    [ "$hung" != "$reloaded" ] || fail "${signal%:*} came before the switch"
    [ -f "$BASE/releases/$hung/RELEASE" ] || fail "${signal%:*} deleted the live release $hung"
    if grep -q "failed before the switch" "$WORK/signal.log"; then
        fail "${signal%:*} says it failed before the switch"
    fi
    deploy fixture log 1 > "$WORK/signal-log.log"
    [ -n "$(sed -nE "/deploy +$hung +failed: switch /p" "$WORK/signal-log.log")" ] \
        || fail "the log does not say ${signal%:*} stopped $hung at the switch"
    [ ! -d "$BASE/.deploy.lock" ] || fail "${signal%:*} left the lock behind"
    serves "$hung" || fail "server does not show $hung after ${signal%:*}"
done
check "a signal after the switch left $hung live and in place, logged failed: switch and freed the lock"

step "A plain rollback works when the live release folder is missing"
rm -rf "${BASE:?}/releases/$hung"
deploy fixture rollback > "$WORK/missing.log" 2>&1 || fail "rollback failed with the live folder missing"
cat "$WORK/missing.log"
back="$(live_release)"
[ "$back" != "$hung" ] && [ -d "$BASE/releases/$back" ] || fail "rollback did not switch to a release on disk"
grep -q "the folder of $hung was missing" "$WORK/missing.log" || fail "rollback does not say the live folder was missing"
grep -q "Checking http" "$WORK/missing.log" || fail "rollback did not run the site check"
serves "$back" || fail "server does not show $back"
deploy fixture log 1 > "$WORK/missing-log.log"
[ -n "$(sed -nE "/rollback +$back +ok, from $hung /p" "$WORK/missing-log.log")" ] || fail "the log does not say the rollback was ok"
check "rolled back from the missing $hung to $back, checked the site and logged ok"

step "A step past STEP_TIMEOUT fails the deploy, stops all it started and frees the lock"
before="$(live_release)"
next_second
rm -f "$WORK/slow.pid" "$WORK/slow.pid.sleep"
started="$(date +%s)"
if STEP_TIMEOUT=2 FIXTURE_SLOW_BUILD="$WORK/slow.pid" deploy fixture --force > /dev/null 2> "$WORK/timeout.log"; then
    fail "a build past STEP_TIMEOUT succeeded"
fi
cat "$WORK/timeout.log"
[ $(($(date +%s) - started)) -lt 15 ] || fail "the timeout took $(($(date +%s) - started)) s"
grep -q "build ran past STEP_TIMEOUT (2 s)" "$WORK/timeout.log" || fail "no clear message for the timeout"
grep -q "failed before the switch; $before is still live" "$WORK/timeout.log" || fail "no word that $before is still live"
[ "$(live_release)" = "$before" ] || fail "a timed out build changed the live release"
[ ! -d "$BASE/.deploy.lock" ] || fail "a timed out build left the lock behind"
[ -s "$WORK/slow.pid.sleep" ] || fail "the slow build did not start its sleep"
if kill -0 "$(cat "$WORK/slow.pid")" 2>/dev/null || kill -0 "$(cat "$WORK/slow.pid.sleep")" 2>/dev/null; then
    fail "the timed out build or its sleep still runs"
fi
if STEP_TIMEOUT=1 FIXTURE_SLOW_BUILD="$WORK/slow.pid" DEPLOY_RAILS=1 deploy fixture --force > /dev/null 2> "$WORK/timeout.log"; then
    fail "a build past STEP_TIMEOUT succeeded on the rails"
fi
grep -qxF "■  build ran past STEP_TIMEOUT (1 s); its output is in $BASE/deploy-failed.log" "$WORK/timeout.log" \
    || fail "the timeout is not marked on the rails"
kill -0 "$(cat "$WORK/slow.pid.sleep")" 2>/dev/null && fail "the timed out build on the rails left its sleep"
STEP_TIMEOUT=0 FIXTURE_BUILD_SLEEP=2 deploy fixture --force > /dev/null || fail "STEP_TIMEOUT=0 stopped a build"
[ "$(live_release)" != "$before" ] || fail "the deploy with STEP_TIMEOUT=0 did not switch"
if STEP_TIMEOUT=10m deploy fixture --force > /dev/null 2> "$WORK/timeout.log"; then
    fail "STEP_TIMEOUT=10m was not refused"
fi
grep -q "STEP_TIMEOUT must be a whole number of seconds, not '10m'" "$WORK/timeout.log" || fail "no message for STEP_TIMEOUT=10m"
if STEP_TIMEOUT=1 FIXTURE_HEALTH_SLEEP=5 DEPLOY_RAILS=1 deploy fixture check > "$WORK/timeout.log" 2>&1; then
    fail "check passed with a health() past STEP_TIMEOUT"
fi
grep -q "health: ran past STEP_TIMEOUT (1 s)$" "$WORK/timeout.log" || fail "check does not report the slow health()"
check "a slow build failed after STEP_TIMEOUT with its sleep stopped, also on the rails; 0 is no limit; a bad value and a slow health() are reported"

step "A TERM during a step stops the step and its watchdog"
next_second
rm -f "$WORK/slow.pid" "$WORK/slow.pid.sleep"
# A STEP_TIMEOUT tied to this run's port, so pgrep finds only this run's watchdog.
watchdog=$((90000 + PORT))
env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT=0 STEP_TIMEOUT="$watchdog" FIXTURE_SLOW_BUILD="$WORK/slow.pid" \
    "$ROOT/deploy" fixture --force > /dev/null 2>&1 &
pid=$!
tries=40
until [ -s "$WORK/slow.pid.sleep" ]; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || fail "the slow build did not start"
    sleep 0.5
done
kill -TERM "$pid"
code=0
wait "$pid" || code=$?
[ "$code" = 143 ] || fail "TERM during a step exited with $code, not 143"
kill -0 "$(cat "$WORK/slow.pid.sleep")" 2>/dev/null && fail "TERM left the step's sleep running"
pgrep -f "^sleep $watchdog\$" > /dev/null && fail "TERM left the watchdog running"
[ ! -d "$BASE/.deploy.lock" ] || fail "TERM during a step left the lock behind"
STEP_TIMEOUT="$watchdog" deploy fixture --force > /dev/null || fail "a deploy with STEP_TIMEOUT=$watchdog failed"
pgrep -f "^sleep $watchdog\$" > /dev/null && fail "a good deploy left a watchdog running"
check "TERM stopped the step and its watchdog and freed the lock; a good deploy leaves no watchdog"

step "A deploy whose output pipe closes during the build still finishes and cleans up"
next_second
: > "$ALERTS"
log_lines="$(wc -l < "$BASE/deploy.log")"
before="$(live_release)"
code=0
# The reader leaves as the build starts, so every later write of the deploy finds a closed pipe.
FIXTURE_BUILD_SLEEP=2 NOTIFY_ON=all NOTIFY_CMD="$alert_cmd" deploy fixture --force 2> "$WORK/pipe.err" \
    | sed '/Running build/q' > /dev/null || code=$?
cat "$WORK/pipe.err"
[ "$code" = 0 ] || fail "the deploy with a closed output pipe exited with $code"
[ ! -e "$BASE/.deploy.lock" ] || fail "the deploy with a closed output pipe left the lock behind"
[ "$(live_release)" != "$before" ] || fail "the deploy with a closed output pipe did not switch"
[ "$(wc -l < "$BASE/deploy.log")" -eq $((log_lines + 1)) ] || fail "the deploy with a closed output pipe wrote no log line"
[ "$(tail -n1 "$BASE/deploy.log" | cut -f2-4)" = "deploy	$(live_release)	ok" ] \
    || fail "the log line of the deploy with a closed output pipe is not ok: $(tail -n1 "$BASE/deploy.log")"
grep -qE "^deploy\|fixture: deploy $(live_release): ok \([0-9]+s\)$" "$ALERTS" || fail "the deploy with a closed output pipe sent no alert"
! grep -q "Broken pipe" "$WORK/pipe.err" || fail "the deploy with a closed output pipe printed a write error"
check "the lock is free, the log says ok and the alert went out"

step "A failing build with a closed output pipe still runs the failed step, logs and alerts"
next_second
: > "$ALERTS"
rm -f "$WORK/slow.pid" "$WORK/slow.pid.sleep" "$WORK/pipe.code" "$BASE/shared/data/failed"
log_lines="$(wc -l < "$BASE/deploy.log")"
before="$(live_release)"
{
    code=0
    FIXTURE_SLOW_BUILD="$WORK/slow.pid" NOTIFY_CMD="$alert_cmd" deploy fixture --force || code=$?
    printf '%s\n' "$code" > "$WORK/pipe.code"
} 2>&1 | sed '/Running build/q' > /dev/null &
reader=$!
tries=40
until [ -s "$WORK/slow.pid.sleep" ]; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || fail "the slow build did not start"
    sleep 0.5
done
# The reader is gone before the build fails: stopping its sleep fails the build.
tries=40
while kill -0 "$reader" 2>/dev/null; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || fail "the reader of the deploy output did not leave"
    sleep 0.5
done
kill "$(cat "$WORK/slow.pid.sleep")"
tries=40
until [ -s "$WORK/pipe.code" ]; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || fail "the deploy with a failing build and a closed output pipe did not end"
    sleep 0.5
done
[ "$(cat "$WORK/pipe.code")" = 1 ] || fail "the failing build with a closed output pipe exited with $(cat "$WORK/pipe.code"), not 1"
[ ! -e "$BASE/.deploy.lock" ] || fail "the failing build with a closed output pipe left the lock behind"
[ "$(live_release)" = "$before" ] || fail "the failing build with a closed output pipe changed the live release"
[ -s "$BASE/shared/data/failed" ] || fail "the failed step did not run with a closed output pipe"
[ "$(wc -l < "$BASE/deploy.log")" -eq $((log_lines + 1)) ] || fail "the failing build with a closed output pipe wrote no log line"
[ "$(tail -n1 "$BASE/deploy.log" | cut -f2,4)" = "deploy	failed: build" ] \
    || fail "the log does not say failed: build: $(tail -n1 "$BASE/deploy.log")"
grep -qE "^deploy\|fixture: deploy [0-9-]+.*: failed: build \(build failed; its output is in [^)]*/deploy-failed\.log\)$" "$ALERTS" \
    || fail "the failing build with a closed output pipe sent no alert"
check "the failed step ran, the log says failed: build, the alert went out and the lock is free"

step "A status or diff stopped during the history clone leaves no temp folder"
commit "fixture stopped clone"
mkdir "$WORK/slowgit" "$WORK/tmp"
# A git whose clone stays until the test lets it go, so the TERM arrives during the clone.
cat > "$WORK/slowgit/git" <<EOF
#!/bin/sh
[ "\$1" = clone ] || exec "$(command -v git)" "\$@"
"$(command -v git)" "\$@"
status=\$?
touch "$WORK/slowgit/cloned"
tries=100
until [ -e "$WORK/slowgit/go" ] || [ "\$tries" -eq 0 ]; do
    tries=\$((tries - 1))
    sleep 0.1
done
exit "\$status"
EOF
chmod +x "$WORK/slowgit/git"
for command in status diff; do
    rm -f "$WORK/slowgit/cloned" "$WORK/slowgit/go"
    env PATH="$WORK/slowgit:$PATH" TMPDIR="$WORK/tmp" PROJECTS_DIR="$WORK/projects" "$ROOT/deploy" fixture "$command" \
        > /dev/null 2>&1 &
    pid=$!
    tries=40
    until [ -e "$WORK/slowgit/cloned" ]; do
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] || fail "$command did not start its history clone"
        sleep 0.5
    done
    [ -n "$(find "$WORK/tmp" -name repo)" ] || fail "the history clone of $command is not in TMPDIR, so the test proves nothing"
    kill -TERM "$pid"
    touch "$WORK/slowgit/go"
    code=0
    wait "$pid" || code=$?
    [ "$code" = 143 ] || fail "TERM during the history clone of $command exited with $code, not 143"
    [ -z "$(ls -A "$WORK/tmp")" ] || fail "a stopped $command left a temp folder: $(ls -A "$WORK/tmp")"
done
TMPDIR="$WORK/tmp" deploy fixture diff > /dev/null || fail "diff failed with its own TMPDIR"
TMPDIR="$WORK/tmp" deploy fixture check > /dev/null || fail "check failed with its own TMPDIR"
[ -z "$(ls -A "$WORK/tmp")" ] || fail "diff or check left a temp folder: $(ls -A "$WORK/tmp")"
next_second
deploy fixture > /dev/null || fail "the deploy after the stopped status failed"
check "a TERM during the clone of status and diff, and a full diff and check, leave TMPDIR empty"

step "A slow PHP_RELOAD_CMD only warns"
next_second
started="$(date +%s)"
STEP_TIMEOUT=3 PHP_RELOAD_CMD="sleep 20" deploy fixture --force > /dev/null 2> "$WORK/reload.log" \
    || fail "a slow PHP_RELOAD_CMD failed the deploy"
[ $(($(date +%s) - started)) -lt 15 ] || fail "the slow PHP_RELOAD_CMD held the deploy for $(($(date +%s) - started)) s"
grep -q "PHP_RELOAD_CMD ran past 3 s; carrying on" "$WORK/reload.log" || fail "no warning for a slow PHP_RELOAD_CMD"
serves "$(live_release)" || fail "server does not show $(live_release)"
check "the slow PHP_RELOAD_CMD was stopped and the deploy went on"

# No rs-opcache file in any release, and none in the web root.
no_opcache_files() {
    [ -z "$(find "$BASE/releases" -name 'rs-opcache-*')" ]
}

step "OPCACHE_RESET_DIR resets OPcache through a one-time URL, on deploy and rollback"
next_second
rm -f "$WORK/opcache.log"
deploy fixture --force > /dev/null || fail "a deploy without OPCACHE_RESET_DIR failed"
[ ! -e "$WORK/opcache.log" ] || fail "an OPcache reset ran with OPCACHE_RESET_DIR off"
next_second
OPCACHE_RESET_DIR=public deploy fixture --force > "$WORK/opcache.out" 2>&1 || fail "a deploy with OPCACHE_RESET_DIR failed"
[ "$(wc -l < "$WORK/opcache.log" | tr -d ' ')" = 1 ] || fail "the deploy did not call the OPcache reset once"
grep -qE '^/rs-opcache-[0-9a-f]{32}[.]php$' "$WORK/opcache.log" || fail "the OPcache reset URL has no random name"
grep -qE "Reset OPcache|No OPcache in the web server's PHP" "$WORK/opcache.out" || fail "the OPcache reset did not run"
no_opcache_files || fail "the OPcache reset file was left behind"
reset="$(live_release)"
OPCACHE_RESET_DIR=public deploy fixture rollback > "$WORK/opcache.out" 2>&1 || fail "a rollback with OPCACHE_RESET_DIR failed"
[ "$(wc -l < "$WORK/opcache.log" | tr -d ' ')" = 2 ] || fail "the rollback did not call the OPcache reset"
[ "$(sort -u "$WORK/opcache.log" | wc -l | tr -d ' ')" = 2 ] || fail "the OPcache reset URL was used twice"
no_opcache_files || fail "the rollback left the OPcache reset file behind"
[ "$(live_release)" != "$reset" ] || fail "the rollback did not switch"
check "one request to a random rs-opcache URL per switch, the file gone after; none when off"

step "A failing, slow or misplaced OPcache reset only warns"
next_second
touch "$WORK/opcache-fail"
OPCACHE_RESET_DIR=public deploy fixture --force > /dev/null 2> "$WORK/opcache.out" \
    || fail "a failing OPcache reset failed the deploy"
rm -f "$WORK/opcache-fail"
grep -qE "OPcache reset at http://127[.]0[.]0[.]1:$PORT/rs-opcache-[0-9a-f]{32}[.]php answered 500; carrying on" "$WORK/opcache.out" \
    || fail "no warning for a failing OPcache reset"
no_opcache_files || fail "a failing OPcache reset left the file behind"
next_second
touch "$WORK/opcache-stall"
started="$(date +%s)"
STEP_TIMEOUT=3 OPCACHE_RESET_DIR=public deploy fixture --force > /dev/null 2> "$WORK/opcache.out" \
    || fail "a slow OPcache reset failed the deploy"
rm -f "$WORK/opcache-stall"
[ $(($(date +%s) - started)) -lt 15 ] || fail "the slow OPcache reset held the deploy for $(($(date +%s) - started)) s"
grep -q "ran past 3 s; carrying on" "$WORK/opcache.out" || fail "no warning for a slow OPcache reset"
no_opcache_files || fail "a slow OPcache reset left the file behind"
next_second
OPCACHE_RESET_DIR=web deploy fixture --force > /dev/null 2> "$WORK/opcache.out" \
    || fail "a missing OPCACHE_RESET_DIR folder failed the deploy"
grep -q "the release has no web folder; OPcache not reset, carrying on" "$WORK/opcache.out" \
    || fail "no warning for a missing OPCACHE_RESET_DIR folder"
no_opcache_files || fail "a missing OPCACHE_RESET_DIR folder left a file behind"
if OPCACHE_RESET_DIR=../public deploy fixture --force > /dev/null 2> "$WORK/opcache.out"; then
    fail "OPCACHE_RESET_DIR=../public was not refused"
fi
grep -q "OPCACHE_RESET_DIR must be a folder inside the release" "$WORK/opcache.out" || fail "no message for OPCACHE_RESET_DIR=../public"
serves "$(live_release)" || fail "server does not show $(live_release)"
check "a 500, a timeout and a missing folder only warned and left no file; a path out of the release is refused"

step "cache runs cache() in the live release, then resets OPcache"
live="$(live_release)"
rm -f "$WORK/opcache.log" "$BASE/shared/data/cache_cleared"
OPCACHE_RESET_DIR=public deploy fixture cache > "$WORK/cache.log" 2>&1 || { cat "$WORK/cache.log"; fail "cache failed"; }
[ "$(cat "$BASE/shared/data/cache_cleared")" = "$live" ] || fail "cache did not run cache() in $live"
[ "$(wc -l < "$WORK/opcache.log" | tr -d ' ')" = 1 ] || fail "cache did not call the OPcache reset once"
no_opcache_files || fail "cache left the OPcache reset file behind"
grep -q "Cleared the cache of $live" "$WORK/cache.log" || fail "cache does not say it cleared the cache"
! grep -q "\[y/N\]" "$WORK/cache.log" || fail "cache asked in a pipe"
[ ! -e "$BASE/.deploy.lock" ] || fail "cache left the lock"
deploy fixture log 1 > "$WORK/cache.log"
grep -qE "cache +$live +ok" "$WORK/cache.log" || fail "the log has no cache line"
rm -f "$WORK/opcache.log" "$BASE/shared/data/cache_cleared"
FIXTURE_NO_CACHE=1 OPCACHE_RESET_DIR=public deploy fixture cache > /dev/null || fail "cache with only OPCACHE_RESET_DIR failed"
[ "$(wc -l < "$WORK/opcache.log" | tr -d ' ')" = 1 ] || fail "cache with only OPCACHE_RESET_DIR did not reset OPcache"
[ ! -e "$BASE/shared/data/cache_cleared" ] || fail "cache ran a cache() step that FIXTURE_NO_CACHE left out"
if FIXTURE_NO_CACHE=1 deploy fixture cache > /dev/null 2> "$WORK/cache.err"; then
    fail "cache with no cache() and no OPCACHE_RESET_DIR succeeded"
fi
grep -q "nothing to clear: deploy.conf of $live has no cache() step and OPCACHE_RESET_DIR is not set" "$WORK/cache.err" \
    || fail "no message for cache with nothing to clear"
grep -q "^Try: define cache() in deploy.conf, or set OPCACHE_RESET_DIR in " "$WORK/cache.err" \
    || fail "no hint for cache with nothing to clear"
[ ! -e "$BASE/.deploy.lock" ] || fail "a refused cache left the lock"
if STEP_TIMEOUT=1 FIXTURE_CACHE_SLEEP=5 deploy fixture cache > /dev/null 2> "$WORK/cache.err"; then
    fail "a cache() step past STEP_TIMEOUT succeeded"
fi
grep -q "cache ran past STEP_TIMEOUT (1 s)" "$WORK/cache.err" || { cat "$WORK/cache.err"; fail "no timeout message for cache()"; }
serves "$live" || fail "server does not show $live after cache"
check "cache ran cache() and the OPcache reset, logged it, failed with a hint when neither is set, and kept STEP_TIMEOUT"

step "A rollback past a new migration warns; it never blocks"
next_second
deploy fixture --force > /dev/null || fail "a deploy before the migrations test failed"
older="$(live_release)"
next_second
deploy fixture --force > /dev/null || fail "a deploy before the migrations test failed"
newer="$(live_release)"
mkdir -p "$BASE/releases/$older/database/migrations" "$BASE/releases/$newer/database/migrations"
touch "$BASE/releases/$older/database/migrations/2026_01_01_000000_create_users.php" \
    "$BASE/releases/$newer/database/migrations/2026_01_01_000000_create_users.php" \
    "$BASE/releases/$newer/database/migrations/2026_11_17_000000_add_notes.php"
deploy fixture rollback "$older" > /dev/null 2> "$WORK/migrations.out" || fail "a rollback past a migration failed"
grep -q "the target lacks 1 migration; data is not reverted" "$WORK/migrations.out" || fail "no warning for a missing migration"
grep -q "^  2026_11_17_000000_add_notes[.]php$" "$WORK/migrations.out" || fail "the warning does not name the missing migration"
! grep -q "create_users" "$WORK/migrations.out" || fail "the warning names a migration the target has"
[ "$(live_release)" = "$older" ] || fail "the rollback past a migration did not switch"
deploy fixture rollback "$newer" > /dev/null 2> "$WORK/migrations.out" || fail "a rollback to $newer failed"
! grep -q "lacks" "$WORK/migrations.out" || fail "a warning when the target lacks no migration"
MIGRATIONS_DIR='' deploy fixture rollback "$older" > /dev/null 2> "$WORK/migrations.out" || fail "a rollback with MIGRATIONS_DIR off failed"
! grep -q "lacks" "$WORK/migrations.out" || fail "a warning with MIGRATIONS_DIR off"
if MIGRATIONS_DIR=../db deploy fixture rollback "$newer" > /dev/null 2> "$WORK/migrations.out"; then
    fail "MIGRATIONS_DIR=../db was not refused"
fi
grep -q "MIGRATIONS_DIR must stay inside the release" "$WORK/migrations.out" || fail "no message for MIGRATIONS_DIR=../db"
deploy fixture rollback "$newer" > /dev/null 2>&1 || fail "a rollback back to $newer failed"
serves "$newer" || fail "server does not show $newer"
check "the warning named the missing file; none when nothing is missing or MIGRATIONS_DIR is empty; ../ is refused"

step "rollback --dry-run shows the plan and changes nothing"
bad_before="$(ls "$BASE"/releases/*/.bad 2>/dev/null || true)"
log_before="$(cat "$BASE/deploy.log")"
rolled_before="$(cat "$BASE/shared/data/rolled_back" 2>/dev/null || true)"
deploy fixture rollback --dry-run > "$WORK/dry-run.out" 2> "$WORK/dry-run.err" || fail "rollback --dry-run failed"
grep -q "Would roll back fixture: [^ ]* → [^ ]*$" "$WORK/dry-run.out" \
    || fail "rollback --dry-run shows no version line"
grep -q "^==> Live: *$newer$" "$WORK/dry-run.out" || fail "rollback --dry-run does not show the live release"
grep -q "^==> Target: *$older$" "$WORK/dry-run.out" || fail "rollback --dry-run does not show the target"
grep -q "Would mark $newer as bad" "$WORK/dry-run.out" || fail "rollback --dry-run does not show the bad mark"
grep -q "Would run after_rollback of $older" "$WORK/dry-run.out" || fail "rollback --dry-run does not show after_rollback"
grep -q "the target lacks 1 migration" "$WORK/dry-run.err" || fail "rollback --dry-run does not show the migration warning"
deploy fixture rollback "$older" --dry-run > "$WORK/dry-run.out" 2>/dev/null || fail "a named rollback --dry-run failed"
grep -q "$newer would not be marked bad" "$WORK/dry-run.out" || fail "a named rollback --dry-run shows a bad mark"
[ "$(live_release)" = "$newer" ] || fail "rollback --dry-run switched"
[ "$(ls "$BASE"/releases/*/.bad 2>/dev/null || true)" = "$bad_before" ] || fail "rollback --dry-run changed the bad marks"
[ "$(cat "$BASE/deploy.log")" = "$log_before" ] || fail "rollback --dry-run wrote to deploy.log"
[ "$(cat "$BASE/shared/data/rolled_back" 2>/dev/null || true)" = "$rolled_before" ] || fail "rollback --dry-run ran after_rollback"
[ ! -e "$BASE/.deploy.lock" ] || fail "rollback --dry-run left the lock"
if deploy fixture rollback --dry-run nope 2> "$WORK/dry-run.err"; then
    fail "rollback --dry-run with an unknown name passed"
fi
grep -q "no release matches 'nope'" "$WORK/dry-run.err" || fail "rollback --dry-run with an unknown name shows another error"
deploy fixture freeze "dry run" > /dev/null
if deploy fixture rollback --dry-run 2> "$WORK/dry-run.err"; then
    fail "rollback --dry-run passed while frozen"
fi
deploy fixture unfreeze > /dev/null
grep -q "frozen" "$WORK/dry-run.err" || fail "rollback --dry-run while frozen shows another error"
[ "$(live_release)" = "$newer" ] || fail "a failed rollback --dry-run switched"
check "dry-run showed live, target, mark, after_rollback and the migration warning; nothing changed; errors match a real rollback"

step "The site check gets past a cache"
next_second
rm -f "$WORK/cached.log"
CHECK_URL="http://127.0.0.1:$PORT/cached" deploy fixture --force > "$WORK/cached.out" 2>&1 \
    || fail "a deploy behind a cache failed"
cached="$(live_release)"
cat "$WORK/cached.log"
grep -q "^/cached?rs=$cached-[0-9]* no-cache no-cache$" "$WORK/cached.log" \
    || fail "the check did not send rs=$cached and the no-cache headers"
next_second
url="http://127.0.0.1:$PORT/cached?lang=en#top"
CHECK_URL="$url" deploy fixture --force > "$WORK/cached.out" 2>&1 || fail "a deploy to a URL with a query failed"
cached="$(live_release)"
grep -q "^/cached?lang=en&rs=$cached-[0-9]* no-cache no-cache$" "$WORK/cached.log" \
    || fail "the check did not add rs=$cached after the query"
grep -qF "Checking $url" "$WORK/cached.out" || fail "the output does not show the plain CHECK_URL"
! grep -q "rs=" "$WORK/cached.out" || fail "the output shows the rs query"
CHECK_URL="$url" deploy fixture check > /dev/null || fail "check failed behind a cache"
CHECK_URL="$url" deploy fixture status > "$WORK/cached.out" || fail "status failed behind a cache"
grep -qF "Site:      http://127.0.0.1:$PORT/cached?lang=en#top answered 200, version $cached (matches live)" \
    "$WORK/cached.out" || fail "status does not match live behind a cache"
grep -q "^/cached?lang=en&rs=[0-9]* no-cache no-cache$" "$WORK/cached.log" || fail "check and status send no rs time"
check "the check sends rs=<release> and no-cache, after any query; output shows the plain URL; check and status pass"

step "One stuck check request still leaves time to retry"
next_second
touch "$WORK/stall"
started=$(date +%s)
CHECK_URL="http://127.0.0.1:$PORT/stall" deploy fixture --force > "$WORK/stall.out" 2>&1 \
    || { cat "$WORK/stall.out"; fail "a deploy with one stuck check request failed"; }
took=$(($(date +%s) - started))
[ ! -e "$WORK/stall" ] || fail "the check never hit the stuck request"
[ "$took" -lt 15 ] || fail "the deploy waited ${took} s on a stuck request"
check "the stuck request was cut at CHECK_WAIT / 3 and the retry passed (${took} s)"

step "The version comes from the last answer, not a redirect"
CHECK_URL="http://127.0.0.1:$PORT/hop" deploy fixture status > "$WORK/hop.out" || fail "status failed behind a redirect"
grep -qF "/hop answered 200, version none" "$WORK/hop.out" || { cat "$WORK/hop.out"; fail "status took the version of a redirect hop"; }
check "a version sent only on a redirect hop is not taken"

step "A git remote that never answers fails fast"
# A TCP port that takes connections and never says a word, like a stalled network.
# shellcheck disable=SC2016 # PHP code, not shell.
php -r '$s = stream_socket_server("tcp://127.0.0.1:0");
    file_put_contents($argv[1], parse_url("tcp://" . stream_socket_get_name($s, false), PHP_URL_PORT));
    $held = [];
    while ($c = @stream_socket_accept($s, -1)) { $held[] = $c; }' "$WORK/stall.port" &
STALL_PID=$!
tries=20
until [ -s "$WORK/stall.port" ]; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || fail "the silent port did not open"
    sleep 0.5
done
stall="$(cat "$WORK/stall.port")"
before="$(live_release)"
started="$(date +%s)"
if REPO_URL="http://127.0.0.1:$stall/repo.git" GIT_HTTP_LOW_SPEED_TIME=2 deploy fixture --force > /dev/null 2>&1; then
    fail "a deploy from a silent HTTP remote succeeded"
fi
[ $(($(date +%s) - started)) -lt 20 ] || fail "the silent HTTP remote held the deploy for $(($(date +%s) - started)) s"
# The user's own SSH command: logged, then run, with its ConnectTimeout before the engine's.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec ssh "$@"\n' "$WORK/ssh.log" > "$WORK/ssh"
chmod +x "$WORK/ssh"
started="$(date +%s)"
if REPO_URL="ssh://git@127.0.0.1:$stall/repo.git" GIT_SSH_COMMAND="$WORK/ssh -o ConnectTimeout=2" \
    deploy fixture --force > /dev/null 2>&1; then
    fail "a deploy from a silent SSH remote succeeded"
fi
[ $(($(date +%s) - started)) -lt 20 ] || fail "the silent SSH remote held the deploy for $(($(date +%s) - started)) s"
grep -q -- "^-o ConnectTimeout=2 -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 " \
    "$WORK/ssh.log" || fail "the SSH command lost its own options or got no time limits: $(head -n1 "$WORK/ssh.log")"
[ "$(live_release)" = "$before" ] || fail "a silent remote changed the live release"
[ ! -d "$BASE/.deploy.lock" ] || fail "a silent remote left the lock behind"
kill "$STALL_PID" 2>/dev/null || true
wait "$STALL_PID" 2>/dev/null || true
STALL_PID=""
check "silent HTTP and SSH remotes failed in seconds; the SSH command kept its options"

# Starts a deploy with a slow build, waits until the build runs, then kills it with SIGKILL, like
# CloudLinux limits or the OOM killer. Sets KILLED to the half-built release left behind.
kill_build() {
    local pid sub tries=40

    rm -f "$WORK/slow.pid"
    env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT=0 FIXTURE_SLOW_BUILD="$WORK/slow.pid" \
        "$ROOT/deploy" fixture --force > "$WORK/killed.log" 2>&1 &
    pid=$!
    until [ -s "$WORK/slow.pid" ]; do
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] || fail "the slow build did not start"
        sleep 0.5
    done
    sub="$(cat "$WORK/slow.pid")"
    kill -9 "$pid"
    # The build step runs in a subshell, which a real SIGKILL of the whole job takes down too.
    pkill -9 -P "$sub" 2>/dev/null || true
    kill -9 "$sub" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    KILLED="$(find "$BASE/releases" -mindepth 2 -maxdepth 2 -name .building -exec dirname {} \; | sed 's#.*/##')"
    [ -n "$KILLED" ] || fail "a killed build left no release with .building in it"
}

step "A build killed with SIGKILL is never listed, and the next rollback or deploy removes it"
before="$(live_release)"
next_second
kill_build
[ "$(live_release)" = "$before" ] || fail "a killed build changed the live release"
deploy fixture status > "$WORK/killed-status.log" 2>&1 || true
if grep -qF "$KILLED" "$WORK/killed-status.log"; then
    fail "status lists the killed build $KILLED"
fi
if deploy fixture rollback "$KILLED" > "$WORK/killed-rollback.log" 2>&1; then
    fail "rollback switched to the killed build $KILLED"
fi
grep -q "no release matches '$KILLED'" "$WORK/killed-rollback.log" || fail "rollback to $KILLED gave no clear error"
grep -q "Removing unfinished build $KILLED" "$WORK/killed-rollback.log" || fail "rollback did not remove $KILLED"
[ ! -e "$BASE/releases/$KILLED" ] || fail "rollback left the killed build $KILLED"
[ "$(live_release)" = "$before" ] || fail "rollback to a killed build changed the live release"
check "the killed build $KILLED was not listed, rollback refused it and removed it"

next_second
kill_build
mkdir "$BASE/releases/.building-20260101-000000"
next_second
deploy fixture --force > "$WORK/after-kill.log" 2>&1 || fail "the deploy after a killed build failed"
grep -q "Removing unfinished build $KILLED" "$WORK/after-kill.log" || fail "the deploy did not say it removed $KILLED"
grep -q "Removing unfinished build .building-20260101-000000" "$WORK/after-kill.log" \
    || fail "the deploy did not remove a leftover clone"
[ ! -e "$BASE/releases/$KILLED" ] && [ ! -e "$BASE/releases/.building-20260101-000000" ] \
    || fail "the deploy left an unfinished build behind"
after="$(live_release)"
[ "$after" != "$before" ] && [ "$after" != "$KILLED" ] || fail "the deploy after a killed build did not switch"
[ "$(cat "$BASE/releases/$after/RELEASE")" = "$after" ] || fail "RELEASE of $after does not hold its name"
[ "$(cat "$BASE/releases/$after/built_path")" = "$BASE/releases/$after" ] \
    || fail "the build of $after ran in $(cat "$BASE/releases/$after/built_path"), not under its final name"
[ ! -e "$BASE/releases/$after/.building" ] || fail "$after still has .building after the switch"
serves "$after" || fail "server does not show $after"
check "the next deploy removed the leftovers and built $after under its final name"

step "KEEP_RELEASES below 2 or not a number, and CHECK_WAIT not a number, are refused"
releases_now="$(release_count)"
if KEEP_RELEASES=1 deploy fixture --force > /dev/null 2> "$WORK/keep.log"; then
    fail "KEEP_RELEASES=1 was not refused"
fi
[ -n "$(sed -n '/KEEP_RELEASES must be 2 or more: the live release and one to roll back to/p' "$WORK/keep.log")" ] \
    || fail "no reason given for refusing KEEP_RELEASES=1"
if KEEP_RELEASES=two deploy fixture --force > /dev/null 2> "$WORK/keep.log"; then
    fail "KEEP_RELEASES=two was not refused"
fi
[ -n "$(sed -n "/KEEP_RELEASES must be a whole number, not 'two'/p" "$WORK/keep.log")" ] \
    || fail "no message for KEEP_RELEASES=two"
if run env CHECK_WAIT=1m "$ROOT/deploy" fixture --force > /dev/null 2> "$WORK/keep.log"; then
    fail "CHECK_WAIT=1m was not refused"
fi
[ -n "$(sed -n "/CHECK_WAIT must be a whole number of seconds, not '1m'/p" "$WORK/keep.log")" ] \
    || fail "no message for CHECK_WAIT=1m"
[ "$(release_count)" = "$releases_now" ] || fail "a refused setting still built a release"
check "bad KEEP_RELEASES and CHECK_WAIT stop the deploy before a clone"

step "A deploy.conf that takes an engine function or variable fails before any step"
before="$(live_release)"
releases_now="$(release_count)"
for clash in "prune() { :; }" "KEEP_RELEASES=3"; do
    tmp="$WORK/clash"
    rm -rf "$tmp"
    git clone --quiet --branch develop "$REPO" "$tmp"
    git -C "$tmp" checkout --quiet -B clash
    # A helper of its own and top-level reads of engine variables are fine.
    # shellcheck disable=SC2016 # Code for deploy.conf.
    printf '%s\n' 'own_helper() { :; }' 'seen="$PHP_BIN $DEPLOY_BASE"' "$clash" >> "$tmp/deploy.conf"
    git -C "$tmp" -c user.name=test -c user.email=test@example.com commit --quiet -am "clash: $clash"
    git -C "$tmp" push --quiet --force origin clash
    next_second
    if deploy fixture --ref clash > "$WORK/clash.log" 2>&1; then
        fail "a deploy.conf with $clash deployed"
    fi
    name="${clash%% *}"
    name="${name%%=*}"
    grep -q "deploy.conf uses names of the engine: $name; rename them" "$WORK/clash.log" \
        || fail "no clear message for $clash"
    if grep -q "Running preflight" "$WORK/clash.log"; then
        fail "a step ran with $clash in deploy.conf"
    fi
    [ "$(live_release)" = "$before" ] || fail "a deploy.conf with $clash changed the live release"
    [ "$(release_count)" = "$releases_now" ] || fail "a deploy.conf with $clash left its release behind"
    [ ! -d "$BASE/.deploy.lock" ] || fail "a deploy.conf with $clash left the lock behind"
done
serves "$before" || fail "server does not show $before"
check "a deploy.conf with prune() or KEEP_RELEASES failed before any step; $before is still live, the lock is free"

step "Prune keeps the release that was just live"
next_second
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r1="$(live_release)"
next_second
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r2="$(live_release)"
KEEP_RELEASES=2 deploy fixture rollback > /dev/null
[ "$(live_release)" = "$r1" ] || fail "rollback did not go back to $r1"
next_second
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r3="$(live_release)"
[ -d "$BASE/releases/$r1" ] || fail "prune deleted $r1, live before $r3"
[ -d "$BASE/releases/$r2" ] && [ "$(release_count)" = 3 ] || fail "prune did not keep $r1, $r2 and $r3"
next_second
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r4="$(live_release)"
[ "$(release_count)" = 2 ] && [ -d "$BASE/releases/$r3" ] && [ -d "$BASE/releases/$r4" ] \
    || fail "prune did not keep only $r3 and $r4"
serves "$r4" || fail "server does not show $r4"
check "prune kept $r1 after a rollback, then kept the newest 2 and deleted the oldest"

step "prune removes failed, unfinished and old releases without a deploy"
# Two old releases, a failed one and a leftover clone, 1 MB each; r3 marked bad, so the rollback
# target of r4 is the newer old one.
old_a="20200101-000000-aaaaaaa"
old_b="20200102-000000-bbbbbbb"
for name in "$old_a" "$old_b" .failed-20200103-000000-ccccccc .building-20200104-000000; do
    mkdir -p "$BASE/releases/$name"
    dd if=/dev/zero of="$BASE/releases/$name/blob" bs=1024 count=1024 2> /dev/null
done
touch "$BASE/releases/$r3/.bad"
logged="$(wc -l < "$BASE/deploy.log" | tr -d ' ')"
count="$(release_count)"
KEEP_RELEASES=2 deploy fixture prune --dry-run > "$WORK/prune.log" || fail "prune --dry-run failed"
cat "$WORK/prune.log"
for line in "$old_a \([0-9.]+[KMG], old\)" "[.]failed-20200103-000000-ccccccc \([0-9.]+[KMG], failed\)" \
    "[.]building-20200104-000000 \([0-9.]+[KMG], unfinished\)"; do
    grep -qE "^==> Would remove $line$" "$WORK/prune.log" || fail "prune --dry-run does not list $line"
done
grep -qE "^==> Would free [0-9.]+M in 3 folders; nothing changed$" "$WORK/prune.log" || fail "prune --dry-run shows no total"
! grep -qE "$old_b|$r3|$r4" "$WORK/prune.log" || fail "prune --dry-run lists the rollback target, a kept or the live release"
[ "$(release_count)" = "$count" ] || fail "prune --dry-run removed a folder"
[ "$(wc -l < "$BASE/deploy.log" | tr -d ' ')" = "$logged" ] || fail "prune --dry-run wrote a log line"
KEEP_RELEASES=2 deploy fixture prune --yes > "$WORK/prune.log" || fail "prune --yes failed"
cat "$WORK/prune.log"
[ ! -e "$BASE/releases/$old_a" ] && [ ! -e "$BASE/releases/.failed-20200103-000000-ccccccc" ] \
    && [ ! -e "$BASE/releases/.building-20200104-000000" ] || fail "prune left a failed, unfinished or old folder"
[ -d "$BASE/releases/$old_b" ] || fail "prune removed $old_b, the rollback target"
[ -d "$BASE/releases/$r3" ] && [ "$(live_release)" = "$r4" ] || fail "prune removed a kept or the live release"
grep -qE "^==> Freed [0-9.]+M in 3 folders$" "$WORK/prune.log" || fail "prune does not say what it freed"
[ "$(wc -l < "$BASE/deploy.log" | tr -d ' ')" = "$((logged + 1))" ] || fail "prune did not write one log line"
tail -n1 "$BASE/deploy.log" | grep -qE "	prune	$r4	ok	" || fail "the prune log line does not name $r4"
[ ! -d "$BASE/.deploy.lock" ] || fail "prune left the lock behind"
KEEP_RELEASES=2 deploy fixture prune --yes > "$WORK/prune.log" || fail "prune with nothing to remove failed"
[ "$(cat "$WORK/prune.log")" = "==> Nothing to prune in $BASE/releases (keeping 2)" ] \
    || { cat "$WORK/prune.log"; fail "prune with nothing to remove did not print one line"; }
[ "$(wc -l < "$BASE/deploy.log" | tr -d ' ')" = "$((logged + 1))" ] || fail "prune with nothing to remove wrote a log line"
rm -f "$BASE/releases/$r3/.bad"
deploy fixture prune --keep 2 --yes > /dev/null || fail "prune --keep 2 failed"
[ "$(release_count)" = 2 ] && [ -d "$BASE/releases/$r3" ] && [ "$(live_release)" = "$r4" ] \
    || fail "prune --keep 2 did not keep only $r3 and $r4"
for args in "--keep 1" "--keep x" "--keep" "--keep=-3" "--nope"; do
    # shellcheck disable=SC2086 # Word splitting wanted.
    if deploy fixture prune $args --yes > /dev/null 2> "$WORK/prune.err"; then
        fail "prune $args was not refused"
    fi
    grep -q "usage: deploy \[project\] prune \[--keep <n>\] \[--dry-run\] \[--yes\]" "$WORK/prune.err" \
        || { cat "$WORK/prune.err"; fail "prune $args gave no usage"; }
done
mkdir "$BASE/releases/.failed-locked" "$BASE/.deploy.lock"
printf '%s %s deploy\n' "$$" "$(date +%s)" > "$BASE/.deploy.lock/owner"
if deploy fixture prune --yes > /dev/null 2> "$WORK/prune.err"; then
    fail "prune ran while a live process held the lock"
fi
grep -q "another deploy is running (PID $$, deploy" "$WORK/prune.err" || fail "a locked prune does not name the owner"
code=0
deploy fixture prune --yes --quiet > "$WORK/quiet.out" 2> "$WORK/quiet.err" || code=$?
[ "$code" = 1 ] && [ ! -s "$WORK/quiet.out" ] && [ ! -s "$WORK/quiet.err" ] || fail "a quiet prune on a held lock was not silent with exit 1"
[ -d "$BASE/releases/.failed-locked" ] || fail "a locked prune removed a folder"
rm -rf "$BASE/.deploy.lock"
deploy fixture prune --quiet > "$WORK/quiet.out" 2>&1 || fail "a quiet prune failed"
[ ! -s "$WORK/quiet.out" ] || fail "a quiet prune printed something"
[ ! -e "$BASE/releases/.failed-locked" ] || fail "a quiet prune without a terminal did not remove the failed folder"
deploy help prune | grep "^Usage: deploy \[project\] prune \[--keep <n>\] \[--dry-run\] \[--yes\]$" > /dev/null \
    || fail "help prune shows no usage line"
deploy --help | grep "^  prune \[--keep <n>\]" > /dev/null || fail "the full help does not list prune"
! deploy fixture prnue 2> "$WORK/typo.log" || fail "prnue succeeded"
grep -q "Did you mean prune?" "$WORK/typo.log" || fail "no hint for prnue"
check "prune --dry-run listed failed, unfinished and old folders with sizes and changed nothing; prune removed them, kept $old_b (the rollback target), $r3 and $r4, logged one line; nothing to remove printed one line; --keep 2 kept two; bad --keep refused; a held lock refused, quiet with --quiet; help and typo hint"

step "A new untagged commit waits for its release tag"
# Run a command once the deploy logs that it waits for the release tag on $1.
# A fixed sleep loses the race on a busy machine.
when_waiting() {
    local short="$1" tries=60
    shift
    until grep -q "Waiting for the release tag on $short" "$WORK/wait.log" 2>/dev/null; do
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] || break
        sleep 0.5
    done
    "$@"
}
commit "fixture wait killed"
waiting="$(git -C "$REPO" rev-parse --short develop)"
releases_now="$(release_count)"
env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT=30 RELEASE_POLL=1 "$ROOT/deploy" fixture \
    > "$WORK/wait.log" 2>&1 &
pid=$!
tries=20
until grep -q "Waiting for the release tag on $waiting" "$WORK/wait.log"; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || fail "deploy did not wait for the release tag"
    sleep 0.5
done
kill -TERM "$pid"
code=0
wait "$pid" || code=$?
[ "$code" = 143 ] || fail "a TERM during the wait exited with $code, not 143"
[ ! -d "$BASE/.deploy.lock" ] || fail "a TERM during the wait left the lock behind"
[ "$(release_count)" = "$releases_now" ] || fail "a TERM during the wait left the release folder behind"
check "a TERM during the wait freed the lock and removed the clone"

next_second
RELEASE_WAIT=30 RELEASE_POLL=1 deploy fixture --no-wait > "$WORK/wait.log" 2>&1
if grep -q "Waiting for the release tag" "$WORK/wait.log"; then
    fail "--no-wait waited for the release tag"
fi
grep -q "no release tag on $waiting; deploying without one" "$WORK/wait.log" || fail "--no-wait gave no warning"
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-$waiting$ ]] || fail "--no-wait deployed $(live_release)"
check "--no-wait deployed $waiting without a tag and warned"

next_second
commit "fixture wait timeout"
waiting="$(git -C "$REPO" rev-parse --short develop)"
RELEASE_WAIT=2 RELEASE_POLL=1 deploy fixture > "$WORK/wait.log" 2>&1
grep -q "Waiting for the release tag on $waiting (0 s of 2)" "$WORK/wait.log" || fail "deploy did not wait for the release tag"
grep -q "Waiting for the release tag on $waiting (2 s of 2)" "$WORK/wait.log" || fail "the wait line shows no elapsed seconds"
grep -q "no release tag on $waiting after 2 s; deploying without one" "$WORK/wait.log" || fail "no warning after the wait"
grep -q "^Try: deploy fixture --no-wait, or RELEASE_WAIT=0 if the repo does not tag every merge$" "$WORK/wait.log" \
    || fail "no hint after the wait"
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-$waiting$ ]] || fail "the deploy after the wait deployed $(live_release)"
check "the wait ran out after 2 s; $waiting deployed without a tag"

next_second
commit "fixture wait tagged"
waiting="$(git -C "$REPO" rev-parse --short develop)"
: > "$WORK/wait.log"
when_waiting "$waiting" git -C "$REPO" tag v2026.11.100 develop &
RELEASE_WAIT=60 RELEASE_POLL=1 deploy fixture > "$WORK/wait.log" 2>&1
wait $!
grep -q "Waiting for the release tag on $waiting" "$WORK/wait.log" || fail "deploy did not wait for the release tag"
if grep -q "no release tag" "$WORK/wait.log"; then
    fail "a warning although the tag came"
fi
[[ "$(live_release)" =~ -v2026\.11\.100-[0-9a-f]{7,}$ ]] || fail "the tag pushed during the wait is not in $(live_release)"
serves "$(live_release)" || fail "server does not show $(live_release)"
check "the tag pushed during the wait is in $(live_release)"

next_second
commit "fixture two tags"
git -C "$REPO" tag v2026.11.1000 develop
git -C "$REPO" tag v2026.11.10000 develop
deploy fixture > /dev/null
[[ "$(live_release)" =~ -v2026\.11\.10000-[0-9a-f]{7,}$ ]] || fail "a commit with two tags did not get the higher one"
deploy fixture rollback v2026.11.100 > /dev/null 2> "$WORK/exact.err" \
    || { cat "$WORK/exact.err"; fail "rollback v2026.11.100 failed next to v2026.11.10000"; }
[[ "$(live_release)" =~ -v2026\.11\.100-[0-9a-f]{7,}$ ]] || fail "rollback v2026.11.100 did not go to its release"
serves "$(live_release)" || fail "server does not show $(live_release)"
check "a commit with two tags got the higher one; rollback v2026.11.100 picked the exact tag over v2026.11.10000"

next_second
commit "fixture no-release marker"
waiting="$(git -C "$REPO" rev-parse --short develop)"
git -C "$REPO" update-ref "refs/no-release/$(git -C "$REPO" rev-parse develop)" develop
started="$(date +%s)"
RELEASE_WAIT=60 RELEASE_POLL=1 deploy fixture > "$WORK/wait.log" 2>&1
[ "$(($(date +%s) - started))" -lt 20 ] || fail "a commit with a no-release marker waited for a tag"
grep -q "no-release merge; deploying without a tag" "$WORK/wait.log" || fail "no line for the no-release marker"
if grep -q "release tag" "$WORK/wait.log"; then
    fail "a commit with a no-release marker waited or warned"
fi
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-$waiting$ ]] || fail "the no-release commit deployed $(live_release)"
check "a commit with a no-release marker deployed $waiting at once"

next_second
commit "fixture no-release marker during the wait"
waiting="$(git -C "$REPO" rev-parse --short develop)"
: > "$WORK/wait.log"
when_waiting "$waiting" git -C "$REPO" update-ref "refs/no-release/$(git -C "$REPO" rev-parse develop)" develop &
started="$(date +%s)"
RELEASE_WAIT=60 RELEASE_POLL=1 deploy fixture > "$WORK/wait.log" 2>&1
wait $!
[ "$(($(date +%s) - started))" -lt 30 ] || fail "the wait went on after the no-release marker came"
grep -q "Waiting for the release tag on $waiting" "$WORK/wait.log" || fail "deploy did not wait for the release tag"
grep -q "no-release merge; deploying without a tag" "$WORK/wait.log" || fail "no line for the no-release marker"
if grep -q "no release tag" "$WORK/wait.log"; then
    fail "a warning although the no-release marker came"
fi
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-$waiting$ ]] || fail "the no-release commit deployed $(live_release)"
check "the no-release marker pushed during the wait stopped it; $waiting deployed"

next_second
git init --quiet --bare "$WORK/notags.git"
commit "fixture no tags"
git -C "$REPO" push --quiet "$WORK/notags.git" develop
RELEASE_WAIT=30 RELEASE_POLL=1 REPO_URL="file://$WORK/notags.git" deploy fixture > "$WORK/wait.log" 2>&1
if grep -q "release tag" "$WORK/wait.log"; then
    fail "a repo without release tags waited or warned"
fi
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{7,}$ ]] || fail "a repo without release tags deployed $(live_release)"
if RELEASE_WAIT=soon deploy fixture --force > /dev/null 2> "$WORK/wait.log"; then
    fail "RELEASE_WAIT=soon was not refused"
fi
grep -q "RELEASE_WAIT must be a whole number of seconds, not 'soon'" "$WORK/wait.log" || fail "no message for RELEASE_WAIT=soon"
check "a repo without release tags did not wait; a bad RELEASE_WAIT is refused"

next_second
commit "fixture ref no wait"
waiting="$(git -C "$REPO" rev-parse --short develop)"
started="$(date +%s)"
RELEASE_WAIT=60 RELEASE_POLL=1 deploy fixture --ref "$(git -C "$REPO" rev-parse develop)" > "$WORK/wait.log" 2>&1
[ "$(($(date +%s) - started))" -lt 20 ] || fail "--ref to a new untagged commit waited for a tag"
if grep -q "Waiting for the release tag" "$WORK/wait.log"; then
    fail "--ref waited for the release tag"
fi
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-$waiting$ ]] || fail "--ref deployed $(live_release)"
check "--ref to a new untagged commit deployed $waiting without waiting"

step "Staging slots: a branch each, in their own folder and URL"
SLOT="$WORK/s1"
cat >> "$WORK/projects/fixture.env" <<EOF
STAGING_SERVERS=2
STAGING_URL="http://{slot}.localhost:$PORT/"
EOF
prod="$(live_release)"
prod_log="$(wc -l < "$BASE/deploy.log")"
slot_live() {
    basename "$(readlink "$SLOT/current" 2>/dev/null)" 2>/dev/null || true
}
# A slot with no branch deploys develop; this one has no shared files yet.
if deploy fixture@s1 > "$WORK/slot.err" 2>&1; then
    fail "a slot without its shared files deployed develop"
fi
grep -q "Cloning develop" "$WORK/slot.err" || fail "a slot with no branch did not try develop"
grep -q "shared/.env is missing" "$WORK/slot.err" || fail "no message for the slot's missing shared files"
[ ! -e "$SLOT/BRANCH" ] || fail "a plain deploy of a free slot stored a branch"
if deploy fixture@s1 --branch nope 2> "$WORK/slot.err"; then
    fail "a branch missing from the repo deployed"
fi
grep -q "no branch nope in the repo" "$WORK/slot.err" || fail "no message for a missing branch"
[ ! -e "$SLOT/BRANCH" ] || fail "a missing branch was stored"
git clone --quiet --branch develop "$REPO" "$WORK/feature"
git -C "$WORK/feature" checkout --quiet -b feature/x
printf 'feature one\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "feature one"
git -C "$WORK/feature" push --quiet origin feature/x
if deploy fixture@s1 --branch feature/x 2> "$WORK/slot.err"; then
    fail "a slot without its shared files deployed"
fi
grep -q "shared/.env is missing (run init, or create it)" "$WORK/slot.err" || fail "no message for missing shared files"
# The fixture's preflight wants APP_ENV=production.
mkdir -p "$SLOT/shared/data"
printf 'APP_ENV=production\n' > "$SLOT/shared/.env"
printf 'slot one\n' > "$SLOT/shared/data/note.txt"
DEPLOY_RAILS=1 deploy fixture@s1 --branch feature/x > "$WORK/slot.log"
cat "$WORK/slot.log"
grep -q "release-switch .* · fixture@s1 · deploy" "$WORK/slot.log" || fail "the rails header does not name the slot"
[ "$(cat "$SLOT/BRANCH")" = feature/x ] || fail "the slot did not store its branch"
[ "$(cat "$SLOT/current/VERSION")" = "feature one" ] || fail "the slot does not run feature/x"
[ "$(cat "$SLOT/current/slot")" = "s1 s1.localhost" ] || fail "DEPLOY_SLOT and DEPLOY_HOST did not reach the build"
[ "$(curl --silent "http://s1.localhost:$PORT/")" = "slot one" ] || fail "the slot URL does not serve the slot"
first_slot="$(slot_live)"
grep -q $'\tdeploy@s1\t'"$first_slot"$'\tok\t' "$SLOT/deploy.log" || fail "deploy.log does not name the slot"
[ "$(deploy path fixture@s1)" = "$SLOT/releases/$first_slot" ] || fail "path does not print the slot's release"
check "fixture@s1 runs feature/x from $SLOT at s1.localhost; steps see the slot and its host"

step "A plain slot deploy follows the stored branch"
printf 'feature two\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "feature two"
git -C "$WORK/feature" push --quiet origin feature/x
# On a fast machine both slot releases can land in one second; rollback --dry-run below needs them apart.
next_second
deploy fixture@s1 > /dev/null
[ "$(cat "$SLOT/current/VERSION")" = "feature two" ] || fail "a plain slot deploy did not follow feature/x"
[ "$(slot_live)" != "$first_slot" ] || fail "a plain slot deploy built nothing new"
deploy fixture@s1 > "$WORK/slot.log"
grep -q "Nothing new on feature/x" "$WORK/slot.log" || fail "a slot deploy with nothing new built again"
deploy fixture@s1 rollback --dry-run > "$WORK/slot.log" || fail "a slot rollback --dry-run failed"
grep -q "^==> Target: *$first_slot$" "$WORK/slot.log" || fail "a slot rollback --dry-run shows the wrong target"
[ "$(slot_live)" != "$first_slot" ] || fail "a slot rollback --dry-run switched"
check "a plain deploy of fixture@s1 deployed the newest feature/x, then stopped with nothing new; rollback --dry-run changed nothing"

step "A slot remembers its own rolled-back commit"
slot_two="$(slot_live)"
slot_sha="$(git -C "$SLOT/releases/$slot_two" rev-parse HEAD)"
prod_skip="$(cat "$BASE/.skip-commits" 2>/dev/null || true)"
deploy fixture@s1 rollback > /dev/null
[ "$(slot_live)" = "$first_slot" ] || fail "the slot rollback did not go back to $first_slot"
grep -q "^$slot_sha"$'\t'"was rolled back"$'\t'"$slot_two$" "$SLOT/.skip-commits" || fail "the slot rollback did not remember its commit"
[ "$(cat "$BASE/.skip-commits" 2>/dev/null || true)" = "$prod_skip" ] || fail "the slot rollback changed the production skipped commits"
deploy fixture@s1 > "$WORK/slot.log"
grep -q "${slot_sha:0:7} was rolled back; push a fix, or deploy fixture@s1 --force" "$WORK/slot.log" \
    || fail "a plain slot deploy did not skip the rolled-back commit: $(cat "$WORK/slot.log")"
[ "$(slot_live)" = "$first_slot" ] || fail "a skipped slot deploy switched"
slot_skip="$(cat "$SLOT/.skip-commits")"
deploy fixture@s1 --ref "$(git -C "$SLOT/releases/$first_slot" rev-parse HEAD)" --force > /dev/null
[ "$(slot_live)" != "$first_slot" ] && [ "$(cat "$SLOT/current/VERSION")" = "feature one" ] \
    || fail "a --ref --force slot deploy did not build the older commit"
[ "$(cat "$SLOT/.skip-commits")" = "$slot_skip" ] || fail "a good --ref deploy changed the skipped commits"
deploy fixture@s1 > "$WORK/slot.log"
grep -q "${slot_sha:0:7} was rolled back; push a fix, or deploy fixture@s1 --force" "$WORK/slot.log" \
    || fail "a plain slot deploy after a --ref deploy did not skip the rolled-back commit: $(cat "$WORK/slot.log")"
next_second
prod_kept="$(cat "$BASE/deploy-failed.log" 2>/dev/null || true)"
if FIXTURE_FAIL_BUILD=1 deploy fixture@s1 --force > /dev/null 2> "$WORK/slot.err"; then
    fail "a slot deploy with a failing build succeeded"
fi
grep -qxF "deploy: build failed; its output is in $SLOT/deploy-failed.log" "$WORK/slot.err" \
    || fail "the slot error does not name its kept output"
grep -qxF "build: npm run prod exited with 1" "$SLOT/deploy-failed.log" || fail "the slot did not keep the step output"
[ "$(cat "$BASE/deploy-failed.log" 2>/dev/null || true)" = "$prod_kept" ] || fail "a slot failure changed the production kept output"
deploy fixture@s1 status | grep "^Failed: .*$SLOT/deploy-failed.log$" > /dev/null || fail "the slot status does not point to its kept output"
deploy fixture@s1 --force > /dev/null
[ "$(cat "$SLOT/current/VERSION")" = "feature two" ] || fail "--force did not build the slot's skipped commit"
! deploy fixture@s1 status | grep "^Failed:" > /dev/null || fail "the slot status points to the kept output after a good deploy"
[ ! -e "$SLOT/.skip-commits" ] || fail "a good slot deploy did not clear its skipped commit"
check "the slot keeps its own skipped commit in its own folder; a good --ref deploy keeps it; --force builds it and clears it"

step "Slots are listed, refused when wrong, and leave production alone"
deploy fixture slots > "$WORK/slots.log"
cat "$WORK/slots.log"
grep -qE "^s1 +feature/x +[0-9a-f]{7,} +today at [0-9:]+ [A-Z]+ +http://s1\.localhost:$PORT/$" "$WORK/slots.log" \
    || fail "slots does not show s1"
grep -qE "^s2 +free +- +- +http://s2\.localhost:$PORT/$" "$WORK/slots.log" || fail "slots does not show s2 as free"
STAGING_URL='' CHECK_URL="https://user:pass@example.com:8443/app" deploy fixture@s2 help \
    | grep -qF "(https://***@s2.example.com:8443/app)" || fail "the slot URL is not sN. before the host"
for bad in fixture@s3 fixture@x fixture@s0; do
    if deploy "$bad" status > /dev/null 2>&1; then
        fail "$bad was not refused"
    fi
done
deploy fixture@s3 status 2> "$WORK/slot.err" || true
grep -q "fixture has no s3; its slots are s1 to s2" "$WORK/slot.err" || fail "no message for s3"
if STAGING_SERVERS=two deploy fixture status > /dev/null 2> "$WORK/slot.err"; then
    fail "STAGING_SERVERS=two was not refused"
fi
grep -q "STAGING_SERVERS must be a whole number, not 'two'" "$WORK/slot.err" || fail "no message for STAGING_SERVERS=two"
if STAGING_SERVERS=0 deploy fixture@s1 status > /dev/null 2> "$WORK/slot.err"; then
    fail "a slot of a project without slots was not refused"
fi
grep -q "fixture has no staging slots" "$WORK/slot.err" || fail "no message for a project without slots"
if deploy fixture --branch feature/x > /dev/null 2> "$WORK/slot.err"; then
    fail "--branch on production was not refused"
fi
grep -qF -- "--branch is for staging slots" "$WORK/slot.err" || fail "no message for --branch on production"
[ "$(live_release)" = "$prod" ] || fail "slot deploys changed the production release"
serves "$prod" || fail "production does not serve $prod"
[ "$(wc -l < "$BASE/deploy.log")" = "$prod_log" ] || fail "slot deploys wrote to the production deploy.log"
[ ! -e "$BASE/BRANCH" ] || fail "production got a BRANCH file"
[ "$(cat "$BASE/current/slot")" = " 127.0.0.1" ] || fail "production steps do not see an empty DEPLOY_SLOT and its host"
check "slots lists s1 and a free s2; bad slots and values are refused; production is unchanged"

step "A slot folder belongs to one project"
[ "$(cat "$SLOT/OWNER")" = fixture ] || fail "the first slot deploy did not mark the slot folder"
# An old slot, made before the mark, keeps working and gets it on its next deploy.
rm "$SLOT/OWNER"
deploy fixture@s1 > /dev/null || fail "a slot without a mark did not deploy"
[ "$(cat "$SLOT/OWNER")" = fixture ] || fail "a slot without a mark did not get one"
# A second project whose production folder is a sibling of fixture's gets the same slot folders.
mkdir "$WORK/second"
printf 'DEPLOY_BASE="%s"\nREPO_URL="file://%s"\nSTAGING_SERVERS=2\n' "$WORK/second" "$REPO" > "$WORK/projects/second.env"
slot_files() {
    find "$SLOT" -exec ls -ld {} + | sed -E 's/^([^ ]+ +){5}//'
}
before="$(slot_files)"
for args in "" "--branch feature/x" "rollback --yes" "down" "up" "log" "prune --yes" "status" \
    "copy-from second --yes" "free"; do
    # shellcheck disable=SC2086 # Split on purpose.
    if deploy second@s1 $args > /dev/null 2> "$WORK/owner.err"; then
        fail "second@s1 ${args:-deploy} used fixture's slot"
    fi
    grep -q "$SLOT belongs to fixture, not second" "$WORK/owner.err" \
        || fail "second@s1 ${args:-deploy} does not name both projects: $(cat "$WORK/owner.err")"
done
if deploy second stage feature/x > /dev/null 2> "$WORK/owner.err"; then
    fail "second stage used fixture's slot"
fi
grep -q "belongs to fixture, not second" "$WORK/owner.err" || fail "second stage does not name both projects"
grep -q "give fixture and second each a parent folder of its own" "$WORK/owner.err" || fail "no hint for a shared slot"
[ "$(slot_files)" = "$before" ] || fail "a refused slot command changed the slot folder"
if deploy second check > "$WORK/owner.log" 2>&1; then
    fail "check passed with shared slot folders"
fi
grep -q "^FAIL  second: slots: shared with fixture in $WORK; give each project a parent folder of its own$" "$WORK/owner.log" \
    || fail "check does not report the shared slots: $(cat "$WORK/owner.log")"
rm -rf "$WORK/projects/second.env" "$WORK/second"
check "slots get an owner mark, old slots get it on the next deploy, another project's slot commands are refused, check reports the clash"

step "A current folder that is not a link is refused"
# Like a web panel making the document root of a new subdomain.
mkdir -p "$WORK/s2/current/public"
printf 'panel log\n' > "$WORK/s2/current/error_log"
if deploy fixture@s2 --branch feature/x 2> "$WORK/slot.err"; then
    fail "a deploy over a current folder succeeded"
fi
grep -q "s2/current is a folder, not a link; move it away" "$WORK/slot.err" || fail "no message for a current folder"
[ "$(find "$WORK/s2/current" -mindepth 1 | wc -l | tr -d ' ')" = 2 ] || fail "the deploy changed the current folder"
[ ! -e "$WORK/s2/BRANCH" ] || fail "the refused deploy stored a branch"
rm -rf "$WORK/s2/current"
check "a deploy into a base whose current is a folder stops and changes nothing"

step "A slot deploys the head of a pull request"
SLOT2="$WORK/s2"
mkdir -p "$SLOT2/shared/data"
printf 'APP_ENV=production\n' > "$SLOT2/shared/.env"
printf 'slot two\n' > "$SLOT2/shared/data/note.txt"
slot2_live() {
    basename "$(readlink "$SLOT2/current" 2>/dev/null)" 2>/dev/null || true
}
# Like GitHub: the PR head is only under refs/pull, on no branch.
git -C "$WORK/feature" checkout --quiet -b pr-seven develop
printf 'pr one\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "pr one"
git -C "$WORK/feature" push --quiet origin HEAD:refs/heads/pr-tmp
git -C "$REPO" update-ref refs/pull/7/head refs/heads/pr-tmp
git -C "$REPO" update-ref -d refs/heads/pr-tmp
if deploy fixture@s2 --pr 99 2> "$WORK/slot.err"; then
    fail "a missing pull request deployed"
fi
grep -q "no pull request #99 in the repo" "$WORK/slot.err" || fail "no message for a missing pull request"
if deploy fixture@s2 --pr seven 2> "$WORK/slot.err"; then
    fail "--pr seven deployed"
fi
grep -qF -- "--pr takes a pull request number, not 'seven'" "$WORK/slot.err" || fail "no message for --pr seven"
if deploy fixture@s2 --pr 7 --branch feature/x 2> "$WORK/slot.err"; then
    fail "--pr with --branch deployed"
fi
grep -q "use --branch or --pr, not both" "$WORK/slot.err" || fail "no message for --pr with --branch"
if deploy fixture@s2 --pr 7 --ref develop 2> "$WORK/slot.err"; then
    fail "--pr with --ref deployed"
fi
grep -q "use --pr or --ref, not both" "$WORK/slot.err" || fail "no message for --pr with --ref"
if deploy fixture --pr 7 > /dev/null 2> "$WORK/slot.err"; then
    fail "--pr on production was not refused"
fi
grep -qF -- "--pr is for staging slots" "$WORK/slot.err" || fail "no message for --pr on production"
[ ! -e "$SLOT2/BRANCH" ] || fail "a refused --pr stored a branch"
FIXTURE_DETAILS="$WORK/details" deploy fixture@s2 --pr 7 > "$WORK/slot.log"
cat "$WORK/slot.log"
grep -qx "REF=pr/7" "$WORK/details" || fail "a PR slot deploy did not set DEPLOY_REF=pr/7"
[ "$(cat "$SLOT2/BRANCH")" = pr/7 ] || fail "the slot did not store pr/7"
[ "$(cat "$SLOT2/current/VERSION")" = "pr one" ] || fail "the slot does not run the PR head"
[[ "$(slot2_live)" =~ ^[0-9]{8}-[0-9]{6}-pr7-[0-9a-f]{7,}$ ]] || fail "the release name $(slot2_live) has no pr7"
first_pr="$(slot2_live)"
check "fixture@s2 --pr 7 deployed $first_pr"

printf 'pr two\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "pr two"
git -C "$WORK/feature" push --quiet origin HEAD:refs/heads/pr-tmp
git -C "$REPO" update-ref refs/pull/7/head refs/heads/pr-tmp
git -C "$REPO" update-ref -d refs/heads/pr-tmp
deploy fixture@s2 status > "$WORK/slot.log"
grep -q "Pending:   1 commit(s) on PR #7, not deployed yet" "$WORK/slot.log" || fail "status does not count the new PR commit"
deploy fixture@s2 > "$WORK/slot.log"
[ "$(cat "$SLOT2/current/VERSION")" = "pr two" ] || fail "a plain deploy did not pick up the new PR commit"
[ "$(slot2_live)" != "$first_pr" ] || fail "a plain deploy of the PR slot built nothing new"
grep -q "pr two" "$WORK/slot.log" || fail "the deploy does not list the new PR commit"
deploy fixture@s2 > "$WORK/slot.log"
grep -q "Nothing new on PR #7" "$WORK/slot.log" || fail "a PR slot with nothing new built again"
deploy fixture slots > "$WORK/slots.log"
cat "$WORK/slots.log"
grep -qE "^s2 +PR #7 +[0-9a-f]{7,} +today at " "$WORK/slots.log" || fail "slots does not show PR #7"
check "a plain deploy picked up the new PR commit, then stopped; status and slots show PR #7"

step "stage reuses the slot on the branch, picks a free one, and fails when all are busy"
deploy fixture stage feature/x > "$WORK/stage.log"
[ "$(tail -n1 "$WORK/stage.log")" = "http://s1.localhost:$PORT/" ] || fail "stage feature/x did not end with the s1 URL"
grep -q "Nothing new on feature/x" "$WORK/stage.log" || fail "stage feature/x did not reuse s1"
[ "$(deploy fixture stage --pr 7 | tail -n1)" = "http://s2.localhost:$PORT/" ] || fail "stage --pr 7 did not reuse s2"
git -C "$WORK/feature" checkout --quiet -b feature/y develop
printf 'feature y\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "feature y"
git -C "$WORK/feature" push --quiet origin feature/y
if deploy fixture stage feature/y > /dev/null 2> "$WORK/stage.err"; then
    fail "stage deployed with all slots busy"
fi
cat "$WORK/stage.err"
grep -qE "^s2 +PR #7 " "$WORK/stage.err" || fail "a busy stage does not show the slots"
grep -q "all 2 slots are busy; free one first: deploy fixture@sN free" "$WORK/stage.err" || fail "no hint to free a slot"
if deploy fixture@s1 stage feature/y > /dev/null 2> "$WORK/stage.err"; then
    fail "stage on a slot name was not refused"
fi
grep -q "stage works on the whole project, not one slot" "$WORK/stage.err" || fail "no message for stage on a slot"
if STAGING_SERVERS=0 deploy fixture stage feature/y > /dev/null 2> "$WORK/stage.err"; then
    fail "stage without slots was not refused"
fi
grep -q "fixture has no staging slots" "$WORK/stage.err" || fail "no message for stage without slots"
for args in "fixture stage --pr" "fixture stage --pr --force" "fixture stage --pr=" "fixture stage --pr=-7" \
    "staging fixture@s2 checkout --pr --force" "staging fixture@s2 checkout --pr="; do
    # shellcheck disable=SC2086 # The arguments are split on purpose.
    if deploy $args > /dev/null 2> "$WORK/stage.err"; then
        fail "deploy $args succeeded"
    fi
    grep -q " | --pr <number>" "$WORK/stage.err" || fail "no usage for deploy $args"
done

develop_sha="$(git -C "$REPO" rev-parse develop)"
deploy fixture@s2 free > "$WORK/stage.log"
cat "$WORK/stage.log"
grep -q "fixture@s2 is free now (it followed PR #7); deploying develop" "$WORK/stage.log" || fail "free does not say what it did"
[ ! -e "$SLOT2/BRANCH" ] || fail "free kept the BRANCH file"
[ "$(git -C "$SLOT2/current" rev-parse HEAD)" = "$develop_sha" ] || fail "free did not deploy the newest develop"
[ "$(cat "$SLOT2/current/VERSION")" = "$(git -C "$REPO" show develop:VERSION)" ] || fail "s2 does not run develop"
grep -q $'\tfree@s2\t' "$SLOT2/deploy.log" || fail "free is not in the slot's deploy.log"
[ ! -e "$SLOT2/.deploy.lock" ] || fail "free left the lock behind"
deploy fixture@s2 free > "$WORK/stage.log"
grep -q "fixture@s2 is already free; deploying develop" "$WORK/stage.log" || fail "freeing a free slot does not say so"
grep -q "Nothing new on develop" "$WORK/stage.log" || fail "freeing a free slot on the newest develop built again"
deploy fixture slots > "$WORK/slots.log"
grep -qE "^s2 +free \(develop\) +${develop_sha:0:7}[0-9a-f]* +today at " "$WORK/slots.log" \
    || fail "slots does not show s2 as free (develop) with its live commit"
deploy fixture stage feature/y > "$WORK/stage.log"
[ "$(tail -n1 "$WORK/stage.log")" = "http://s2.localhost:$PORT/" ] || fail "stage feature/y did not pick the free s2"
[ "$(cat "$SLOT2/current/VERSION")" = "feature y" ] || fail "s2 does not run feature/y"
deploy fixture slots | grep -qE "^s2 +feature/y " || fail "slots does not show s2 on feature/y"
check "stage reused s1 and s2, failed while both were busy; free put s2 on develop, and stage took it"

step "slots update redeploys moved branches, skips gone ones, and goes on after a failure"
s1_before="$(slot_live)"
printf 'feature y two\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "feature y two"
git -C "$WORK/feature" push --quiet origin feature/y
deploy fixture slots update > "$WORK/update.log"
cat "$WORK/update.log"
[ "$(slot_live)" = "$s1_before" ] || fail "slots update rebuilt an unchanged s1"
[ "$(cat "$SLOT2/current/VERSION")" = "feature y two" ] || fail "slots update did not redeploy s2"
grep -qE "^s1 +feature/x +unchanged$" "$WORK/update.log" || fail "the summary does not show s1 unchanged"
grep -qE "^s2 +feature/y +updated, [0-9a-f]{7,} to [0-9a-f]{7,}$" "$WORK/update.log" || fail "the summary does not show s2 updated"
if grep -q '◇' "$WORK/update.log"; then
    fail "slots update drew rails without a terminal"
fi

# s1 moves but cannot deploy; s2's branch is deleted.
git -C "$WORK/feature" checkout --quiet feature/x
printf 'feature three\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "feature three"
git -C "$WORK/feature" push --quiet origin feature/x
git -C "$WORK/feature" push --quiet origin --delete feature/y
mv "$SLOT/shared/.env" "$WORK/s1.env"
deploy fixture slots > "$WORK/slots.log"
cat "$WORK/slots.log"
grep -qE "^s2 +feature/y \(gone\) +[0-9a-f]{7,} " "$WORK/slots.log" || fail "slots does not mark the deleted feature/y"
grep -qE "^s1 +feature/x +[0-9a-f]{7,} " "$WORK/slots.log" || fail "slots marks feature/x"
REPO_URL="file://$WORK/nope.git" deploy fixture slots | grep -qE "^s2 +feature/y +[0-9a-f]{7,} " \
    || fail "slots marks a branch gone when the repo cannot be read"
printf 'pr/8\n' > "$SLOT2/BRANCH"
deploy fixture slots | grep -qE "^s2 +PR #8 \(gone\) " || fail "slots does not mark a missing PR"
printf 'feature/y\n' > "$SLOT2/BRANCH"
if deploy fixture slots update > "$WORK/update.log" 2>&1; then
    fail "slots update succeeded with a failing slot"
fi
cat "$WORK/update.log"
mv "$WORK/s1.env" "$SLOT/shared/.env"
grep -qE "^s1 +feature/x +failed$" "$WORK/update.log" || fail "the summary does not show s1 failed"
grep -qE "^s2 +feature/y +branch gone$" "$WORK/update.log" || fail "the summary does not show s2 branch gone"
grep -q "1 slot(s) failed to update" "$WORK/update.log" || fail "no message for the failed slot"
[ "$(slot_live)" = "$s1_before" ] || fail "the failed s1 changed its release"
[ "$(cat "$SLOT2/BRANCH")" = feature/y ] || fail "slots update freed s2"
[ ! -e "$SLOT/.deploy.lock" ] && [ ! -e "$SLOT2/.deploy.lock" ] || fail "slots update left a lock behind"
deploy fixture slots update > "$WORK/update.log"
grep -qE "^s1 +feature/x +updated, " "$WORK/update.log" || fail "s1 did not update once fixed"
grep -qE "^s2 +feature/y +branch gone$" "$WORK/update.log" || fail "a gone branch failed slots update"
check "slots update redeployed only moved branches, skipped and kept the gone feature/y, and went on past a failing s1"

step "stage reuses a slot whose branch is gone when none is free"
git -C "$WORK/feature" checkout --quiet -b feature/z develop
printf 'feature z\n' > "$WORK/feature/VERSION"
git -C "$WORK/feature" -c user.name=test -c user.email=test@example.com commit --quiet -am "feature z"
git -C "$WORK/feature" push --quiet origin feature/z
deploy fixture stage feature/z > "$WORK/stage.log"
cat "$WORK/stage.log"
grep -q "fixture@s2 follows feature/y, which is gone from the repo, so it takes feature/z" "$WORK/stage.log" \
    || fail "stage does not say which gone branch it replaces"
[ "$(tail -n1 "$WORK/stage.log")" = "http://s2.localhost:$PORT/" ] || fail "stage feature/z did not take s2"
[ "$(cat "$SLOT2/current/VERSION")" = "feature z" ] || fail "s2 does not run feature/z"
deploy fixture@s2 free > /dev/null
[ ! -e "$SLOT2/BRANCH" ] || fail "free kept the BRANCH file"
before="$(git -C "$SLOT2/current" rev-parse --short HEAD)"
commit "develop for free slots"
deploy fixture slots update > "$WORK/update.log"
cat "$WORK/update.log"
[ "$(cat "$SLOT2/current/VERSION")" = "develop for free slots" ] || fail "slots update did not move the free s2"
grep -qE "^s2 +free \(develop\) +updated, ${before}[0-9a-f]* to [0-9a-f]{7,}$" "$WORK/update.log" \
    || fail "the summary does not show the free s2 updated"
deploy fixture slots update > "$WORK/update.log"
grep -qE "^s2 +free \(develop\) +unchanged$" "$WORK/update.log" || fail "slots update rebuilt an unchanged free s2"
commit "develop again"
deploy fixture@s2 > /dev/null
[ "$(cat "$SLOT2/current/VERSION")" = "develop again" ] || fail "a plain deploy did not move the free s2"
[ ! -e "$SLOT2/BRANCH" ] || fail "a plain deploy of the free s2 stored a branch"
# A new s3, never deployed: slots update gives it its first release once it has its shared files.
if STAGING_SERVERS=3 deploy fixture slots update > "$WORK/update.log" 2>&1; then
    fail "slots update succeeded with an s3 that has no shared files"
fi
grep -qE "^s3 +free \(develop\) +failed$" "$WORK/update.log" || fail "the summary does not show the new s3 failed"
mkdir -p "$WORK/s3/shared/data"
printf 'APP_ENV=production\n' > "$WORK/s3/shared/.env"
printf 'slot three\n' > "$WORK/s3/shared/data/note.txt"
STAGING_SERVERS=3 deploy fixture slots update > "$WORK/update.log"
cat "$WORK/update.log"
grep -qE "^s3 +free \(develop\) +deployed, [0-9a-f]{7,}$" "$WORK/update.log" || fail "the summary does not show s3 deployed"
[ "$(cat "$WORK/s3/current/VERSION")" = "develop again" ] || fail "slots update did not deploy develop to the new s3"
[ ! -e "$WORK/s3/BRANCH" ] || fail "slots update stored a branch for the new s3"
rm -rf "$WORK/s3"
check "stage took s2 from the gone feature/y; slots update and a plain deploy keep the free s2 on the newest develop; slots update deployed a new s3"

step "stage takes each slot under its lock, so two runs never pick the same one"
deploy fixture@s1 free > /dev/null
# Like another stage that took s1 a moment ago.
sleep 60 &
holder=$!
mkdir "$SLOT/.deploy.lock"
printf '%s %s stage\n' "$holder" "$(date +%s)" > "$SLOT/.deploy.lock/owner"
deploy fixture stage feature/z > "$WORK/stage.log"
[ "$(tail -n1 "$WORK/stage.log")" = "http://s2.localhost:$PORT/" ] || fail "stage took the locked s1"
[ ! -e "$SLOT/BRANCH" ] || fail "stage wrote BRANCH of the locked s1"
[ ! -e "$SLOT2/.deploy.lock" ] || fail "stage left the lock of s2 behind"
if deploy fixture stage feature/x > /dev/null 2> "$WORK/stage.err"; then
    fail "stage deployed with the only free slot locked"
fi
grep -q "all 2 slots are busy" "$WORK/stage.err" || fail "no busy message with the free slot locked"
mv "$SLOT/.deploy.lock" "$SLOT2/.deploy.lock"
if deploy fixture stage feature/z > /dev/null 2> "$WORK/stage.err"; then
    fail "stage deployed to a slot another run holds"
fi
grep -q "fixture@s2 follows feature/z, but another run holds its lock" "$WORK/stage.err" \
    || fail "no message for a locked slot on the same branch"
kill "$holder" 2>/dev/null || true
rm -rf "$SLOT2/.deploy.lock"
check "stage skipped a locked free slot, failed with no slot left, and refused a locked slot on its branch"

step "staging runs the same slot commands as the old forms"
# s1 is free on develop, s2 follows feature/z.
deploy fixture slots > "$WORK/slots.log"
deploy staging fixture > "$WORK/staging.log"
diff "$WORK/slots.log" "$WORK/staging.log" || fail "staging fixture does not list the slots like slots"
deploy staging > "$WORK/staging.log"
diff "$WORK/slots.log" "$WORK/staging.log" || fail "staging without a project does not use the only project with slots"
deploy staging fixture checkout feature/z > "$WORK/staging.log"
grep -q "Nothing new on feature/z" "$WORK/staging.log" || fail "staging checkout did not reuse s2"
[ "$(tail -n1 "$WORK/staging.log")" = "http://s2.localhost:$PORT/" ] || fail "staging checkout feature/z did not end with the s2 URL"
deploy staging checkout feature/x > "$WORK/staging.log"
[ "$(tail -n1 "$WORK/staging.log")" = "http://s1.localhost:$PORT/" ] || fail "staging checkout feature/x did not pick the free s1"
[ "$(cat "$SLOT/BRANCH")" = feature/x ] || fail "staging checkout did not store feature/x for s1"
deploy staging fixture@s1 checkout feature/x > "$WORK/staging.log"
grep -q "Nothing new on feature/x" "$WORK/staging.log" || fail "staging fixture@s1 checkout feature/x did not act like --branch"
deploy staging fixture@s2 checkout --pr 7 > /dev/null
[ "$(cat "$SLOT2/BRANCH")" = pr/7 ] || fail "staging fixture@s2 checkout --pr 7 did not store pr/7"
[ "$(cat "$SLOT2/current/VERSION")" = "pr two" ] || fail "staging fixture@s2 checkout --pr 7 did not deploy the PR head"
deploy staging fixture@s2 update > "$WORK/staging.log"
grep -q "Nothing new on PR #7" "$WORK/staging.log" || fail "staging fixture@s2 update did not act like a plain deploy"
deploy staging fixture update > "$WORK/staging.log"
grep -qE "^s1 +feature/x +unchanged$" "$WORK/staging.log" || fail "staging fixture update did not act like slots update on s1"
grep -qE "^s2 +PR #7 +unchanged$" "$WORK/staging.log" || fail "staging fixture update did not act like slots update on s2"
deploy staging fixture@s2 free > "$WORK/staging.log"
grep -q "fixture@s2 is free now (it followed PR #7); deploying develop" "$WORK/staging.log" || fail "staging free did not free s2"
[ ! -e "$SLOT2/BRANCH" ] || fail "staging free kept the BRANCH file"
deploy staging fixture@s1 copy-from fixture --yes > "$WORK/staging.log"
grep -q "Copied into fixture@s1: data" "$WORK/staging.log" || fail "staging copy-from did not copy"
rm -f "$SLOT/shared/data/cache_cleared"
deploy staging fixture@s1 cache > /dev/null || fail "staging fixture@s1 cache failed"
[ "$(cat "$SLOT/shared/data/cache_cleared")" = "$(slot_live)" ] \
    || fail "staging cache did not run cache() in the slot's live release"
[ ! -e "$BASE/shared/data/cache_cleared" ] || fail "staging cache ran cache() in production"
rm -f "$SLOT/shared/data/cache_cleared"
deploy fixture@s1 cache > /dev/null || fail "fixture@s1 cache failed"
[ -e "$SLOT/shared/data/cache_cleared" ] || fail "fixture@s1 cache did not run cache()"
[ "$(deploy staging fixture@s1 path)" = "$(deploy path fixture@s1)" ] || fail "staging path does not print the slot's release"
deploy fixture@s1 status | grep -v -e deployed -e "^Disk:" > "$WORK/status.log"
deploy staging fixture@s1 | grep -v -e deployed -e "^Disk:" > "$WORK/staging.log"
diff "$WORK/status.log" "$WORK/staging.log" || fail "staging fixture@s1 does not show the slot's status"
deploy staging fixture@s1 status | grep -v -e deployed -e "^Disk:" > "$WORK/staging.log"
diff "$WORK/status.log" "$WORK/staging.log" || fail "staging fixture@s1 status does not show the slot's status"
deploy fixture@s1 diff > "$WORK/status.log" || fail "fixture@s1 diff failed"
grep -q "^Nothing pending: $(slot_live) is the tip of " "$WORK/status.log" || fail "fixture@s1 diff does not compare the slot"
[ "$(deploy staging fixture@s1 diff)" = "$(cat "$WORK/status.log")" ] || fail "staging fixture@s1 diff does not match fixture@s1 diff"
if deploy staging fixture free > /dev/null 2> "$WORK/staging.err"; then
    fail "staging free without a slot was not refused"
fi
grep -q "free works on one slot: deploy staging fixture@sN free" "$WORK/staging.err" || fail "no message for staging free without a slot"
if STAGING_SERVERS=0 deploy staging fixture > /dev/null 2> "$WORK/staging.err"; then
    fail "staging of a project without slots was not refused"
fi
grep -q "fixture has no staging slots (set STAGING_SERVERS" "$WORK/staging.err" || fail "no STAGING_SERVERS hint for staging"
check "each staging form did what its old form does; free without a slot and a project without slots were refused"

step "staging help and typo hints"
deploy staging --help > "$WORK/help.log"
grep -q "^Usage: deploy staging \[project\]$" "$WORK/help.log" || fail "staging --help shows no usage line"
grep -q "^  staging <project>@sN checkout <branch> | --pr <number>" "$WORK/help.log" || fail "staging --help does not list checkout"
deploy staging fixture@s1 checkout --help | grep "^Usage: deploy staging <project> checkout <branch> | --pr <number>$" > /dev/null \
    || fail "staging checkout --help shows no usage line"
deploy help staging update | grep "^Usage: deploy staging <project>@sN update" > /dev/null || fail "help staging update shows no usage line"
deploy --help | sed -n '/^Staging:$/,/^Commands:$/p' | grep "^  staging <project>@sN free" > /dev/null \
    || fail "the full help does not list staging first"
code=0
deploy staging fixture chekout feature/x > /dev/null 2> "$WORK/typo.log" || code=$?
[ "$code" = 2 ] || fail "a staging typo exited with $code, not 2"
grep -q "Unknown staging command: chekout. Did you mean checkout?" "$WORK/typo.log" || fail "no hint for chekout"
code=0
deploy stagign > /dev/null 2> "$WORK/typo.log" || code=$?
[ "$code" = 2 ] || fail "a typo of staging exited with $code, not 2"
grep -q "Did you mean staging?" "$WORK/typo.log" || fail "no hint for stagign"
check "staging --help, <sub> --help and help staging <sub> show the staging help; the full help lists it first; typos get a hint and exit 2"

step "copy-from copies production data into a slot, never .env"
printf 'APP_ENV=production\n# slot s1 only\n' > "$SLOT/shared/.env"
printf 'slot data\n' > "$SLOT/shared/data/note.txt"
printf 'slot only\n' > "$SLOT/shared/data/slot-only.txt"
slot_data_kept() {
    [ "$(cat "$SLOT/shared/data/note.txt")" = "slot data" ] && [ -f "$SLOT/shared/data/slot-only.txt" ]
}
if deploy fixture copy-from fixture --yes > /dev/null 2> "$WORK/copy.err"; then
    fail "copy-from into production was not refused"
fi
grep -q "copy-from copies into a staging slot, never into production" "$WORK/copy.err" || fail "no message for production as the target"
if deploy fixture@s1 copy-from other --yes > /dev/null 2> "$WORK/copy.err"; then
    fail "copy-from another project was not refused"
fi
grep -q "copies from production of the same project only" "$WORK/copy.err" || fail "no message for another project"
if deploy fixture@s1 copy-from fixture@s2 --yes > /dev/null 2> "$WORK/copy.err"; then
    fail "copy-from a slot was not refused"
fi
grep -q "copies from production only, not from a slot" "$WORK/copy.err" || fail "no message for a slot as the source"
if deploy fixture@s1 copy-from fixture .env --yes > /dev/null 2> "$WORK/copy.err"; then
    fail "copy-from .env was not refused"
fi
grep -q "copy-from never copies .env" "$WORK/copy.err" || fail "no message for .env"
if deploy fixture@s1 copy-from fixture nope --yes > /dev/null 2> "$WORK/copy.err"; then
    fail "copy-from a path not in SHARED was not refused"
fi
grep -q "nope is not in SHARED (.env data)" "$WORK/copy.err" || fail "no message for a path not in SHARED"
if deploy fixture@s1 copy-from fixture < /dev/null > /dev/null 2> "$WORK/copy.err"; then
    fail "copy-from without a terminal or --yes copied"
fi
grep -q "not a terminal, so copy-from cannot ask; add --yes" "$WORK/copy.err" || fail "no message for a pipe without --yes"
mkdir "$SLOT/.deploy.lock"
printf '%s %s deploy\n' "$$" "$(date +%s)" > "$SLOT/.deploy.lock/owner"
if deploy fixture@s1 copy-from fixture --yes > /dev/null 2> "$WORK/copy.err"; then
    fail "copy-from ran while the slot was locked"
fi
grep -q "another deploy is running (PID $$" "$WORK/copy.err" || fail "no lock message for copy-from"
rm -rf "$SLOT/.deploy.lock"
slot_data_kept || fail "a refused copy-from changed the slot's data"
deploy fixture@s1 copy-from fixture --yes > "$WORK/copy.log"
cat "$WORK/copy.log"
grep -q "SHARED from the slot's live release" "$WORK/copy.log" || fail "copy-from does not say where SHARED comes from"
grep -qE "^ +[0-9.]+[A-Z]?  data$" "$WORK/copy.log" || fail "copy-from does not list data with its size"
grep -q "Copied into fixture@s1: data" "$WORK/copy.log" || fail "copy-from does not say what it copied"
diff -r "$BASE/shared/data" "$SLOT/shared/data" > /dev/null || fail "the slot's data is not production's"
[ ! -e "$SLOT/shared/data/slot-only.txt" ] || fail "the slot's old data/ was merged, not replaced"
[ "$(cat "$SLOT/shared/.env")" = $'APP_ENV=production\n# slot s1 only' ] || fail "copy-from changed the slot's .env"
[ -z "$(find "$SLOT/shared" -maxdepth 1 \( -name '*.copy-from.*' -o -name '*.old.*' \))" ] \
    || fail "copy-from left a temp copy behind"
[ ! -e "$SLOT/.deploy.lock" ] || fail "copy-from left the lock behind"
grep -q $'\tcopy-from@s1\t'"$(slot_live)"$'\tok, from fixture: data\t' "$SLOT/deploy.log" || fail "copy-from is not in the slot's deploy.log"
mv "$BASE/shared/data" "$WORK/prod-data"
printf 'slot data\n' > "$SLOT/shared/data/note.txt"
deploy fixture@s1 copy-from fixture data --yes > "$WORK/copy.log" 2>&1
mv "$WORK/prod-data" "$BASE/shared/data"
grep -q "data is missing in fixture; the slot keeps its own" "$WORK/copy.log" || fail "no warning for a missing source path"
[ "$(cat "$SLOT/shared/data/note.txt")" = "slot data" ] || fail "a missing source path changed the slot's data"
check "copy-from replaced the slot's data/ with production's, kept its .env, logged it, and refused production, other sources, .env, unknown paths, a pipe and a held lock"

step "copy-from asks on a terminal"
# Types keys $2 into the terminal once text $1 shows in log $LOG one more time than in the pairs
# before it, for each pair; waits 30 seconds at most for each text. Stops once the command has
# ended (file $LOG.done), and after the last pair waits for that, 120 seconds at most.
expect_feed() {
    local log="$1" i j seen text keys tries
    shift
    trap '' PIPE

    for ((i = 1; i < $#; i += 2)); do
        text="${!i}"
        j=$((i + 1))
        keys="${!j}"
        seen=1
        for ((j = 1; j < i; j += 2)); do
            [ "${!j}" != "$text" ] || seen=$((seen + 1))
        done
        tries=0
        while [ "$({ grep -oF -- "$text" "$log" || true; } | wc -l)" -lt "$seen" ] && [ "$tries" -lt 300 ]; do
            [ ! -e "$log.done" ] || return 0
            sleep 0.1
            tries=$((tries + 1))
        done
        sleep 0.3
        printf '%s' "$keys" 2> /dev/null
    done
    tries=0
    while [ ! -e "$log.done" ] && [ "$tries" -lt 1200 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    true
}
# Runs the command after -- on a terminal made by script, into log $1; the pairs before -- go to
# expect_feed. The terminal stays open until the command ends.
on_terminal_expect() {
    local log="$1" pairs=()
    shift
    while [ "$1" != -- ]; do
        pairs+=("$1")
        shift
    done
    shift
    : > "$log"
    rm -f "$log.done"
    # shellcheck disable=SC2016 # Expanded by the inner bash.
    set -- bash -c '"$@"; code=$?; : > "$0"; exit "$code"' "$log.done" "$@"

    # shellcheck disable=SC2094 # The feeder waits for what the run writes to the log.
    if script --version > /dev/null 2>&1; then
        expect_feed "$log" ${pairs[@]+"${pairs[@]}"} | script -qec "$(printf '%q ' "$@")" /dev/null >> "$log" 2>&1
    else
        expect_feed "$log" ${pairs[@]+"${pairs[@]}"} | script -q /dev/null "$@" >> "$log" 2>&1
    fi
}
if command -v script > /dev/null; then
    on_terminal_expect "$WORK/copy.log" "[y/N]" $'n\n' \
        -- env PROJECTS_DIR="$WORK/projects" DEPLOY_RAILS=0 "$ROOT/deploy" fixture@s1 copy-from fixture
    cat "$WORK/copy.log"
    grep -q "Copy these into fixture@s1? Its files are replaced \[y/N\]" "$WORK/copy.log" || fail "copy-from does not ask on a terminal"
    grep -q "Nothing copied" "$WORK/copy.log" || fail "copy-from does not stop on n"
    [ "$(cat "$SLOT/shared/data/note.txt")" = "slot data" ] || fail "copy-from copied after n"
    on_terminal_expect "$WORK/copy.log" "[y/N]" $'y\n' \
        -- env PROJECTS_DIR="$WORK/projects" DEPLOY_RAILS=0 "$ROOT/deploy" fixture@s1 copy-from fixture
    grep -q "Copied into fixture@s1: data" "$WORK/copy.log" || fail "copy-from does not copy on y"
    diff -r "$BASE/shared/data" "$SLOT/shared/data" > /dev/null || fail "copy-from on y did not copy data/"
    check "copy-from asked on a terminal: n copied nothing, y copied data/"
else
    check "skipped: no script command to make a terminal"
fi

step "rollback, down, cache, prune and deploy --force ask on a terminal"
# Runs the engine on a terminal into ask.log, typing answer $1 at a [y/N] question; fails with the
# log when it fails.
ask_run() {
    local answer="$1"
    shift

    on_terminal_expect "$WORK/ask.log" "[y/N]" "$answer"$'\n' \
        -- env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT=0 DEPLOY_RAILS=0 "$ROOT/deploy" "$@" \
        || { cat "$WORK/ask.log"; fail "deploy $* failed on a terminal"; }
}
deploy fixture down "pipe" > "$WORK/ask.log" 2>&1
! grep -q "\[y/N\]" "$WORK/ask.log" || fail "down asked in a pipe"
deploy fixture up > /dev/null
if command -v script > /dev/null; then
    live="$(live_release)"
    count="$(release_count)"
    ask_run n fixture rollback
    grep -q "Rollback of fixture: live $live → " "$WORK/ask.log" || fail "rollback does not show live and target"
    grep -q "Roll back? \[y/N\]" "$WORK/ask.log" || fail "rollback does not ask on a terminal"
    grep -q "Nothing done" "$WORK/ask.log" || fail "rollback does not stop on n"
    [ "$(live_release)" = "$live" ] || fail "rollback rolled back after n"
    [ ! -e "$BASE/.deploy.lock" ] || fail "rollback left the lock after n"
    ask_run y fixture rollback
    [ "$(live_release)" != "$live" ] || fail "rollback did not roll back on y"
    ask_run "" fixture rollback "$live" --yes
    ! grep -q "\[y/N\]" "$WORK/ask.log" || fail "rollback --yes asked"
    [ "$(live_release)" = "$live" ] || fail "rollback --yes did not go back to $live"
    serves "$live" || fail "server does not show $live after rollback --yes"

    ask_run "" fixture down "terminal test"
    grep -q "Taking fixture down: terminal test" "$WORK/ask.log" || fail "down does not show the reason"
    grep -q "maintenance page until: deploy fixture up" "$WORK/ask.log" || fail "down does not say the site shows maintenance"
    grep -q "Nothing done" "$WORK/ask.log" || fail "down does not stop on an empty answer"
    [ ! -e "$BASE/.down" ] || fail "down went down after an empty answer"
    ask_run y fixture down "terminal test"
    [ -e "$BASE/.down" ] || fail "down did not go down on y"
    deploy fixture up > /dev/null
    ask_run "" fixture down --yes
    ! grep -q "\[y/N\]" "$WORK/ask.log" || fail "down --yes asked"
    [ -e "$BASE/.down" ] || fail "down --yes did not go down"
    [ "$(sed -n 2p "$BASE/.down")" = "" ] || fail "down --yes took --yes as the reason"
    deploy fixture up > /dev/null

    rm -f "$BASE/shared/data/cache_cleared" "$SLOT/shared/data/cache_cleared"
    ask_run n fixture cache
    grep -q "Clearing the cache of fixture, live release $live" "$WORK/ask.log" || fail "cache does not show the release"
    grep -q "Clear the cache? \[y/N\]" "$WORK/ask.log" || fail "cache does not ask on a terminal"
    [ ! -e "$BASE/shared/data/cache_cleared" ] || fail "cache ran cache() after n"
    ask_run "" fixture cache --yes
    ! grep -q "\[y/N\]" "$WORK/ask.log" || fail "cache --yes asked"
    [ -e "$BASE/shared/data/cache_cleared" ] || fail "cache --yes did not run cache()"
    ask_run "" fixture@s1 cache
    ! grep -q "\[y/N\]" "$WORK/ask.log" || fail "cache asked on a slot"
    [ -e "$SLOT/shared/data/cache_cleared" ] || fail "cache on a slot did not run cache()"

    mkdir "$BASE/releases/.failed-ask" "$SLOT/releases/.failed-ask"
    ask_run n fixture prune
    grep -q "Pruning fixture, live release $live, keeping 5:" "$WORK/ask.log" || fail "prune does not show the live release"
    grep -qE "^==>   [.]failed-ask \([0-9.]+K, failed\)" "$WORK/ask.log" || fail "prune does not list the folder it removes"
    grep -q "Remove these folders? \[y/N\]" "$WORK/ask.log" || fail "prune does not ask on a terminal"
    [ -d "$BASE/releases/.failed-ask" ] || fail "prune removed a folder after n"
    ask_run "" fixture@s1 prune
    ! grep -q "\[y/N\]" "$WORK/ask.log" || fail "prune asked on a slot"
    [ ! -e "$SLOT/releases/.failed-ask" ] || fail "prune on a slot did not remove the failed folder"
    ask_run y fixture prune
    [ ! -e "$BASE/releases/.failed-ask" ] || fail "prune did not remove the failed folder on y"

    ask_run n fixture --force
    grep -qE -- "--force (rebuilds [0-9a-f]+, which $live already runs|deploys [0-9a-f]+): " "$WORK/ask.log" \
        || fail "deploy --force does not show the commit it rebuilds"
    grep -q "Nothing done" "$WORK/ask.log" || fail "deploy --force does not stop on n"
    [ "$(live_release)" = "$live" ] && [ "$(release_count)" = "$count" ] || fail "deploy --force built after n"
    [ -z "$(find "$BASE/releases" -maxdepth 1 -name '.building-*')" ] || fail "deploy --force left a .building folder after n"
    next_second
    ask_run y fixture --force
    ! grep -q "Nothing done" "$WORK/ask.log" || fail "deploy --force stopped on y"
    [ "$(live_release)" != "$live" ] || fail "deploy --force did not build on y"
    serves "$(live_release)" || fail "server does not show $(live_release) after deploy --force on y"
    live="$(live_release)"
    next_second
    ask_run "" fixture --force --yes
    ! grep -q "\[y/N\]" "$WORK/ask.log" || fail "deploy --force --yes asked"
    [ "$(live_release)" != "$live" ] || fail "deploy --force --yes did not deploy"

    # On the rails, a failing site check draws the spinner, then its time.
    live="$(live_release)"
    next_second
    on_terminal_expect "$WORK/spin.log" -- env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=3 RELEASE_WAIT=0 NO_COLOR=1 \
        CHECK_URL="http://127.0.0.1:$PORT/missing" "$ROOT/deploy" fixture --force --yes || true
    grep -qE "◒  Checking http://127.0.0.1:$PORT/missing · [0-9]+s of 3s" "$WORK/spin.log" \
        || { cat "$WORK/spin.log"; fail "the site check shows no spinner on a terminal"; }
    grep -qE "◇  Checking http://127.0.0.1:$PORT/missing \([0-9]+s\)" "$WORK/spin.log" \
        || { cat "$WORK/spin.log"; fail "the site check does not end with its time"; }
    [ "$(live_release)" = "$live" ] || fail "the failed check on a terminal left a new release live"
    serves "$live" || fail "server does not show $live after the failed check on a terminal"
    # Later tests expect no failed release.
    rm -rf "$BASE"/releases/.failed-*
    check "on a terminal rollback, down, cache, prune and deploy --force showed what they do and asked: n or empty did nothing, y went on (deploy --force built), --yes and a slot did not ask; a pipe was not asked"
else
    check "skipped: no script command to make a terminal"
fi

step "A bare deploy on a terminal shows the project menu"
# The menu row of project $1, from the engine's own function.
menu_row() {
    run bash -c '. "$1"; menu_load "$2" && menu_row' _ "$ROOT/deploy" "$1"
}
row="$(menu_row fixture)"
[[ "$row" == $'0\tfixture\tfixture\t'*$'\tup to date\tsite ok\t-' ]] || fail "up-to-date menu row: $row"
deploy fixture freeze "menu test" > /dev/null
row="$(menu_row fixture)"
[[ "$row" == *$'\tup to date\tsite ok\tfrozen' ]] || fail "frozen menu row: $row"
deploy fixture unfreeze > /dev/null
commit "fixture menu"
row="$(menu_row fixture)"
[[ "$row" == $'1\tfixture\tfixture\t'*$'\t1 commit, no tag yet\tsite ok\t-' ]] || fail "untagged menu row: $row"
git -C "$REPO" tag v2026.11.20000 develop
row="$(menu_row fixture)"
[[ "$row" == $'1\tfixture\tfixture\t'*$' → v2026.11.20000\t1 commit\tsite ok\t-' ]] || fail "tagged menu row: $row"
cp "$WORK/projects/fixture.env" "$WORK/projects/other.env"
! deploy < /dev/null > /dev/null 2> "$WORK/menu.log" || fail "a bare deploy in a pipe with two projects succeeded"
grep -q "name a project (fixture other)" "$WORK/menu.log" || fail "a bare deploy in a pipe does not ask for a project"
rm "$WORK/projects/other.env"
if command -v script > /dev/null; then
    live="$(live_release)"
    # j moves to the second row, r reads the rows again, q quits.
    on_terminal_expect "$WORK/menu.log" "Pick a project" jr "Pick a project" q \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=xterm NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the menu failed on q"; }
    grep -q "Pick a project" "$WORK/menu.log" || fail "a bare deploy on a terminal shows no menu"
    grep -qE "↑↓/1-[0-9] pick · Enter open · r refresh · q quit" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "the menu shows no key bar"; }
    [ "$(grep -cE "Checking [0-9]+ projects" "$WORK/menu.log")" -eq 2 ] || { cat "$WORK/menu.log"; fail "r did not read the rows again"; }
    tr -d '\r' < "$WORK/menu.log" | sed $'s/\033\\[[0-9?;]*[A-Za-z]//g' | grep -E "❯ " > "$WORK/menu.rows" || true
    [[ "$(sed -n '$p' "$WORK/menu.rows")" =~ ❯\ 2\  ]] \
        || { cat "$WORK/menu.rows"; fail "the cursor left the second row after r"; }
    [ "$(live_release)" = "$live" ] || fail "q in the menu deployed"

    # ↓ past the last row stops on Quit, and Enter there quits.
    on_terminal_expect "$WORK/menu.log" "Pick a project" $'jjjjjjjjj\n' \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=xterm NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the menu failed on the Quit row"; }
    tr -d '\r' < "$WORK/menu.log" | sed $'s/\033\\[[0-9?;]*[A-Za-z]//g' | grep -E "❯ " > "$WORK/menu.rows" || true
    [[ "$(sed -n '$p' "$WORK/menu.rows")" =~ ❯\ +Quit$ ]] || { cat "$WORK/menu.rows"; fail "the cursor did not reach the Quit row"; }
    ! grep -q "Enter run" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "Enter on Quit opened an action list"; }
    [ "$(live_release)" = "$live" ] || fail "the Quit row deployed"

    # The Recheck projects row, right above Quit, reads the rows again like r. Arrows pressed while
    # the rows are read never show as text.
    on_terminal_expect "$WORK/menu.log" "Pick a project" r "Checking" $'\033[B\033[B\033[B\033[B' \
        "Pick a project" $'jjjjjjjjk\n' "Pick a project" q \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=xterm NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the menu failed on the Recheck projects row"; }
    tr -d '\r' < "$WORK/menu.log" | sed $'s/\033\\[[0-9?;]*[A-Za-z]//g' > "$WORK/menu.plain"
    [ "$(grep -cE "Checking [0-9]+ projects" "$WORK/menu.plain")" -eq 3 ] \
        || { cat "$WORK/menu.plain"; fail "the Recheck projects row did not read the rows again"; }
    grep -qE "❯ +Recheck projects$" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "the cursor did not reach Recheck projects"; }
    ! grep -qF "[B" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "arrow keys showed as text"; }

    # The production list: a deploy that works, Enter goes back to the list with fresh facts, b to
    # the project list with fresh rows.
    next_second
    on_terminal_expect "$WORK/menu.log" "r to refresh, q to quit" $'1\n' "b to go back, q to quit" $'1\n' "[y/N]" $'y\n' "Press Enter to go back" $'\n' \
        "b to go back, q to quit" $'b\n' "r to refresh, q to quit" $'q\n' \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT=0 TERM=dumb NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the numbered menu failed"; }
    grep -q "r to refresh, q to quit" "$WORK/menu.log" || fail "TERM=dumb shows no numbered list"
    grep -q "fixture — production · .* → v2026.11.20000" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "the production list has no title"; }
    for label in "1  Deploy new release (1 commit)" "2  Status" "3  Check site" "4  Log" "5  Rollback…" \
        "6  Clear cache" "7  Prune releases" "8  Freeze…" "9  Down…"; do
        grep -qF "$label" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the production list has no $label"; }
    done
    grep -q "fixture menu" "$WORK/menu.log" || fail "the menu does not show the pending commits"
    grep -q "Deploy fixture (production) .* → v2026.11.20000? \[y/N\]" "$WORK/menu.log" \
        || fail "the menu does not ask before the deploy"
    [[ "$(live_release)" == *-v2026.11.20000-* ]] || { cat "$WORK/menu.log"; fail "the menu did not deploy on y"; }
    grep -q "deploy fixture finished" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the menu does not show the deploy ended"; }
    grep -q "Press Enter to go back" "$WORK/menu.log" || fail "the menu does not wait for Enter after the deploy"
    [ "$(grep -c "b to go back, q to quit" "$WORK/menu.log")" -eq 2 ] \
        || { cat "$WORK/menu.log"; fail "the action list did not come back after the deploy"; }
    grep -qF "1  Redeploy (up to date)" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the action list after the deploy has old facts"; }
    [ "$(grep -c "r to refresh, q to quit" "$WORK/menu.log")" -eq 2 ] \
        || { cat "$WORK/menu.log"; fail "b did not go back to the project list"; }
    grep -qE "1  fixture +v2026\.11\.20000 +up to date" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "the list after the deploy has old rows"; }

    # A failed deploy keeps the menu; a frozen project shows Unfreeze, and it unfreezes.
    deploy fixture freeze "menu fail" > /dev/null
    on_terminal_expect "$WORK/menu.log" "r to refresh, q to quit" $'1\n' "b to go back, q to quit" $'1\n' "Press Enter to go back" $'\n' "b to go back, q to quit" $'8\n' "Press Enter to go back" $'\n' \
        "b to go back, q to quit" $'b\n' "r to refresh, q to quit" $'q\n' \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=dumb NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the menu failed after a failed deploy"; }
    grep -q "deploy fixture --force failed with exit code 1" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "the menu does not show the deploy failed"; }
    grep -qF "8  Unfreeze" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "a frozen project shows no Unfreeze"; }
    grep -q "deploy fixture unfreeze finished" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "Unfreeze did not run"; }
    [ ! -e "$BASE/.frozen" ] || fail "Unfreeze in the menu left the project frozen"
    [ "$(grep -cF "8  Freeze…" "$WORK/menu.log")" -eq 1 ] || { cat "$WORK/menu.log"; fail "the list after Unfreeze shows no Freeze"; }
    deploy fixture unfreeze > /dev/null 2>&1 || true

    # Keys pressed between a pick and its question are dropped, so they do not answer it: Clear
    # cache with a stray ↓↓ and Enter still asks and runs on y.
    on_terminal_expect "$WORK/menu.log" "Pick a project" $'1\n' "fixture — production" $'6\n\033[B\033[B\n' \
        "[y/N]" $'y\n' "Press Enter to go back" $'\n' "fixture — production" q \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=xterm NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the menu failed on Clear cache"; }
    grep -q "deploy fixture cache finished" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "Clear cache did not run"; }
    ! grep -q "Nothing done" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "a stray key answered the cache question"; }

    # s1 follows feature/x; s2 and the new s3 are free.
    cp "$WORK/projects/fixture.env" "$WORK/fixture.env"
    printf 'STAGING_SERVERS=3\n' >> "$WORK/projects/fixture.env"
    [ ! -e "$SLOT/BRANCH" ] || mv "$SLOT/BRANCH" "$WORK/s1.branch"
    [ ! -e "$SLOT2/BRANCH" ] || mv "$SLOT2/BRANCH" "$WORK/s2.branch"
    printf 'feature/x\n' > "$SLOT/BRANCH"
    # The engine list: 2 runs its log, then q quits.
    on_terminal_expect "$WORK/menu.log" "Pick a project" $'4\n' "release-switch — engine" $'2\n' "Press Enter to go back" $'\n' \
        "release-switch — engine" q \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=xterm NO_COLOR=1 DEPLOY_RAILS=0 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the tree menu failed"; }
    tr -d '\r' < "$WORK/menu.log" | sed $'s/\033\\[[0-9?;]*[A-Za-z]//g' > "$WORK/menu.plain"
    grep -E "^ +(❯ )?[0-9 ] " "$WORK/menu.plain" > "$WORK/menu.rows"
    grep -qE "^ +❯ 1  fixture " "$WORK/menu.rows" || { cat "$WORK/menu.rows"; fail "fixture is not the first row"; }
    [[ "$(sed -n 2p "$WORK/menu.rows")" =~ ^\ +2\ \ ├\ s1\ +feature/x\  ]] \
        || { cat "$WORK/menu.rows"; fail "s1 is not under fixture"; }
    [[ "$(sed -n 3p "$WORK/menu.rows")" =~ ^\ +3\ \ └\ s2,\ s3\ +free\ *$ ]] \
        || { cat "$WORK/menu.rows"; fail "the free s2 and s3 are not one numbered leaf"; }
    [[ "$(sed -n 4p "$WORK/menu.rows")" =~ ^\ +4\ \ release-switch\  ]] \
        || { cat "$WORK/menu.rows"; fail "the engine is not number 4"; }
    [[ "$(sed -n 5p "$WORK/menu.rows")" =~ ^\ +Recheck\ projects$ ]] \
        || { cat "$WORK/menu.rows"; fail "Recheck projects is not above Quit"; }
    [[ "$(sed -n 6p "$WORK/menu.rows")" =~ ^\ +Quit$ ]] || { cat "$WORK/menu.rows"; fail "Quit is not the last row"; }
    grep -q "release-switch — engine" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "key 4 did not open the engine list"; }
    grep -qE "1  Update engine" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "the engine list has no Update engine"; }
    grep -qE "❯ 2  Log" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "the engine list has no Log"; }
    grep -qE "\s+Back$" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "the engine list has no Back row"; }
    grep -q "↑↓/1-2 pick · Enter run · b back · q quit" "$WORK/menu.plain" \
        || { cat "$WORK/menu.plain"; fail "the engine list shows no key bar"; }
    grep -q "deploy self log finished" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "Log in the engine list did not run"; }

    # The slot list: an up-to-date Update is a --force deploy that asks, n does nothing; Status runs.
    on_terminal_expect "$WORK/menu.log" "r to refresh, q to quit" $'2\n' "b to go back, q to quit" $'1\n' "[y/N]" $'n\n' "Press Enter to go back" $'\n' "b to go back, q to quit" $'6\n' "Press Enter to go back" $'\n' \
        "b to go back, q to quit" $'b\n' "r to refresh, q to quit" $'q\n' \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=dumb NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the numbered slot list failed"; }
    grep -q "fixture s1 — staging · feature/x" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the slot list has no title"; }
    for label in "1  Update (up to date)" "2  Checkout branch or PR…" "3  Clear cache" "4  Prune releases" \
        "5  Copy data from production…" "6  Status" "7  Log" "8  Rollback…" "9  Down…" "10  Go to current folder" "11  Free slot"; do
        grep -qF "$label" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the slot list has no $label"; }
    done
    grep -q "Build it? \[y/N\]" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "Update on an up-to-date slot did not ask"; }
    grep -q "deploy fixture@s1 --force finished" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "Update on an up-to-date slot did not run deploy --force"; }
    grep -qE "deploy fixture@s1 status (finished|failed)" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "Status in the slot list did not run"; }

    # The free leaf asks for a branch: empty does nothing, a name runs staging checkout.
    on_terminal_expect "$WORK/menu.log" "r to refresh, q to quit" $'3\n' "Branch, or #N" $'\n' "r to refresh, q to quit" $'3\n' "Branch, or #N" $'no-such-branch\n' \
        "Press Enter to go back" $'\n' "r to refresh, q to quit" $'q\n' \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=dumb NO_COLOR=1 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the free leaf failed"; }
    grep -q "Check out into s2 of fixture" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the free leaf has no title"; }
    grep -q "Branch, or #N for a pull request:" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the free leaf does not ask for a branch"; }
    grep -q "Nothing done" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "an empty branch did something"; }
    grep -q "deploy staging fixture checkout no-such-branch failed" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "the free leaf did not run staging checkout"; }
    # Go to current folder: a shell (a fake SHELL that saves its folder) starts in the live release,
    # and any exit comes back to the menu. Production uses the arrow-key list, the slot exits non-zero.
    cat > "$WORK/shell.sh" <<'EOF'
#!/bin/sh
pwd -P > "$SHELL_PWD"
exit "${SHELL_CODE:-0}"
EOF
    chmod +x "$WORK/shell.sh"
    : > "$WORK/shell.pwd"
    on_terminal_expect "$WORK/menu.log" "Pick a project" $'1\n' "fixture — production" $'9j\n' "fixture — production" q \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=xterm NO_COLOR=1 SHELL="$WORK/shell.sh" \
        SHELL_PWD="$WORK/shell.pwd" "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the menu failed on Go to current folder"; }
    grep -qF "10  Go to current folder" "$WORK/menu.log" || { cat "$WORK/menu.log"; fail "the production list has no Go to current folder"; }
    grep -qF "$(cd "$BASE/current" && pwd -P) · type exit to return to the menu" "$WORK/menu.log" \
        || { cat "$WORK/menu.log"; fail "Go to current folder does not name the folder"; }
    [ "$(cat "$WORK/shell.pwd")" = "$(cd "$BASE/current" && pwd -P)" ] \
        || { cat "$WORK/menu.log"; fail "the shell did not start in the live release"; }
    [ "$(grep -c "fixture — production" "$WORK/menu.log")" -eq 2 ] \
        || { cat "$WORK/menu.log"; fail "the action list did not come back after the shell"; }
    ! grep -qE "[0-9]  Go to current folder$" "$WORK/menu.plain" || { cat "$WORK/menu.plain"; fail "the engine list has Go to current folder"; }
    : > "$WORK/shell.pwd"
    on_terminal_expect "$WORK/menu.log" "r to refresh, q to quit" $'2\n' "b to go back, q to quit" $'10\n' \
        "b to go back, q to quit" $'b\n' "r to refresh, q to quit" $'q\n' \
        -- env GIT_PAGER=cat PROJECTS_DIR="$WORK/projects" TERM=dumb NO_COLOR=1 SHELL="$WORK/shell.sh" \
        SHELL_PWD="$WORK/shell.pwd" SHELL_CODE=3 "$ROOT/deploy" \
        || { cat "$WORK/menu.log"; fail "the slot list failed on Go to current folder"; }
    [ "$(cat "$WORK/shell.pwd")" = "$(cd "$SLOT/current" && pwd -P)" ] \
        || { cat "$WORK/menu.log"; fail "the shell did not start in the slot's live release"; }
    [ "$(grep -c "b to go back, q to quit" "$WORK/menu.log")" -eq 2 ] \
        || { cat "$WORK/menu.log"; fail "the slot list did not come back after a shell that failed"; }
    # No row without a live release or with current not a link; current gone at the pick fails.
    slot_actions() {
        # shellcheck disable=SC2016 # Expanded by the inner bash.
        run bash -c '. "$1"; M_TARGET=(fixture@s1); M_PENDING=(-); M_VERSION=(-); M_SHIP=(0); M_PROBLEMS=("")
            menu_actions 0; printf "%s\n" "${A_LABEL[@]}"; menu_shell 0 2>&1' _ "$ROOT/deploy"
    }
    mv "$SLOT/current" "$WORK/s1.current"
    slot_actions > "$WORK/actions.log"
    ! grep -q "Go to current folder" "$WORK/actions.log" || fail "a slot without current shows Go to current folder"
    grep -q "fixture s1 (staging) has no live release (current is gone)" "$WORK/actions.log" \
        || { cat "$WORK/actions.log"; fail "Go to current folder without current does not fail"; }
    mkdir "$SLOT/current"
    slot_actions > "$WORK/actions.log"
    ! grep -q "Go to current folder" "$WORK/actions.log" || fail "a slot whose current is not a link shows Go to current folder"
    rmdir "$SLOT/current"
    mv "$WORK/s1.current" "$SLOT/current"
    rm -f "$SLOT/BRANCH" "$SLOT2/BRANCH"
    [ ! -e "$WORK/s1.branch" ] || mv "$WORK/s1.branch" "$SLOT/BRANCH"
    [ ! -e "$WORK/s2.branch" ] || mv "$WORK/s2.branch" "$SLOT2/BRANCH"
    mv "$WORK/fixture.env" "$WORK/projects/fixture.env"
    check "the menu row shows up to date, frozen, untagged and tagged commits; a pipe still needs a project; the key bar shows, r read the rows again on the same row, q and the Quit row did nothing, Recheck projects read the rows again and arrows never showed as text; the production list deployed fixture and came back with fresh facts, also after a failed deploy, and Unfreeze showed and ran on a frozen project; stray keys before the cache question were dropped; slots hang under fixture with free ones in one numbered leaf; the engine list ran its log; the slot list names the slot, its up-to-date Update asked before --force, and Status ran; the free leaf asked for a branch and ran staging checkout; Go to current folder showed on production and a live slot only, its shell started in the live release and the list came back after any exit, and current gone at the pick failed"
else
    check "skipped: no script command to make a terminal"
fi

step "self-update pulls the engine"
# A throwaway copy of the engine, so the test never pulls this checkout.
mkdir "$WORK/engine-src"
cp "$ROOT/deploy" "$WORK/engine-src/deploy"
git -C "$WORK/engine-src" init --quiet -b main
git -C "$WORK/engine-src" add deploy
git -C "$WORK/engine-src" -c user.name=test -c user.email=test@example.com commit --quiet -m "engine"
git init --quiet --bare "$WORK/engine.git"
git -C "$WORK/engine-src" tag v2026.11.1
git -C "$WORK/engine-src" push --quiet --tags "$WORK/engine.git" main
git clone --quiet --branch main "file://$WORK/engine.git" "$WORK/engine"
[ "$("$WORK/engine/deploy" --version)" = v2026.11.1 ] || fail "--version does not show the release tag"
"$WORK/engine/deploy" self-update > "$WORK/self.log"
grep -q "Already up to date (v2026.11.1)" "$WORK/self.log" || fail "self-update does not say it is up to date"
printf '# newer\n' >> "$WORK/engine-src/deploy"
git -C "$WORK/engine-src" -c user.name=test -c user.email=test@example.com commit --quiet -am "Newer engine"
git -C "$WORK/engine-src" tag v2026.11.2
printf '# untagged\n' >> "$WORK/engine-src/deploy"
git -C "$WORK/engine-src" -c user.name=test -c user.email=test@example.com commit --quiet -am "Untagged engine"
git -C "$WORK/engine-src" push --quiet --tags "$WORK/engine.git" main
RELEASE_WAIT=60 "$WORK/engine/deploy" self --no-wait > "$WORK/self.log"
cat "$WORK/self.log"
if grep -q "Waiting for the release tag" "$WORK/self.log"; then
    fail "self --no-wait waited for the release tag"
fi
grep -q "Updated v2026.11.1 → v2026.11.2+1$" "$WORK/self.log" || fail "self does not show both versions"
# No gh for a file:// repo, so each tag lists its commits.
sed -n '/^v2026.11.2$/,/^Not released yet$/p' "$WORK/self.log" | grep -E "^    [0-9a-f]+ Newer engine$" > /dev/null \
    || fail "self does not list the new tag with its commits"
sed -n '/^Not released yet$/,$p' "$WORK/self.log" | grep -E "^    [0-9a-f]+ Untagged engine$" > /dev/null \
    || fail "self does not list the commits past the tag"
tail -n1 "$WORK/engine/deploy" | grep -q "^# untagged$" || fail "self did not update the engine"
[ "$("$WORK/engine/deploy" --version)" = v2026.11.2+1 ] || fail "--version does not count commits past the tag"
printf '# local change\n' >> "$WORK/engine/deploy"
printf '# newest\n' >> "$WORK/engine-src/deploy"
git -C "$WORK/engine-src" -c user.name=test -c user.email=test@example.com commit --quiet -am "Newest engine"
git -C "$WORK/engine-src" push --quiet "$WORK/engine.git" main
if "$WORK/engine/deploy" self-update > /dev/null 2> "$WORK/self.log"; then
    fail "self-update ran over a local change"
fi
grep -q "could not update $WORK/engine; it has local changes$" "$WORK/self.log" \
    || fail "no local changes cause when self-update cannot pull"
grep -q "^Try: git -C $WORK/engine status$" "$WORK/self.log" || fail "no hint for local changes in the engine"
check "self-update shows both versions, lists new tags and commits, says when it is up to date, and stops on local changes; --version follows the tags"

step "status --all shows the engine"
PROJECTS_DIR="$WORK/projects" "$WORK/engine/deploy" status --all > "$WORK/engine-row.log"
cat "$WORK/engine-row.log"
grep -qE "^release-switch +v2026\.11\.2\+1 +today at .* +- +1 new, run deploy self, local changes$" "$WORK/engine-row.log" \
    || fail "status --all does not show the engine behind and changed"
git -C "$WORK/engine" checkout --quiet -- deploy
"$WORK/engine/deploy" self --no-wait > /dev/null
PROJECTS_DIR="$WORK/projects" "$WORK/engine/deploy" status --all > "$WORK/engine-row.log"
grep -qE "^release-switch +v2026\.11\.2\+2 +today at .* +- +up to date$" "$WORK/engine-row.log" \
    || fail "status --all does not show the engine up to date"
check "status --all shows the engine's version and whether it is behind or changed"

step "self log shows the engine's commits, and the ones not pulled yet"
printf '# unpulled\n' >> "$WORK/engine-src/deploy"
git -C "$WORK/engine-src" -c user.name=test -c user.email=test@example.com commit --quiet -am "Unpulled engine"
git -C "$WORK/engine-src" push --quiet "$WORK/engine.git" main
DISPLAY_TZ=America/Toronto PROJECTS_DIR="$WORK/projects" "$WORK/engine/deploy" self log 2 > "$WORK/self-log.log"
cat "$WORK/self-log.log"
sed -n '/^Not pulled yet/,/^$/p' "$WORK/self-log.log" | grep -qE "^  [0-9a-f]+  20[0-9-]+ [0-9:]+ E[SD]T  Unpulled engine$" \
    || fail "self log does not show the commit not pulled yet"
sed -n '/^Installed in/,$p' "$WORK/self-log.log" | grep -qE "^  [0-9a-f]+  .*  Newest engine$" \
    || fail "self log does not show the installed commits"
[ "$(sed -n '/^Installed in/,$p' "$WORK/self-log.log" | grep -c '^  ')" = 2 ] || fail "self log 2 does not show 2 commits"
if "$WORK/engine/deploy" self nope 2> "$WORK/self-log.log"; then
    fail "an unknown self command succeeded"
fi
grep -q "unknown command: deploy self nope" "$WORK/self-log.log" || fail "no message for an unknown self command"
git -C "$WORK/engine" -c user.name=test -c user.email=test@example.com commit --quiet --allow-empty -m "Local engine"
if "$WORK/engine/deploy" self-update > /dev/null 2> "$WORK/self.log"; then
    fail "self-update ran over a local commit"
fi
grep -q "could not update $WORK/engine; it has local commits the remote lacks$" "$WORK/self.log" \
    || fail "no local commits cause when self-update cannot pull"
grep -q "^Try: git -C $WORK/engine log @{u}..$" "$WORK/self.log" || fail "no hint for local commits in the engine"
if grep -q "local changes" "$WORK/self.log"; then
    fail "self-update names local changes for a local commit"
fi
git -C "$WORK/engine" reset --quiet --hard HEAD~1
check "self log lists installed and unpulled commits; an unknown self command fails; a local commit stops self"

step "self waits for the release tag of a new engine commit"
waiting="$(git -C "$WORK/engine.git" rev-parse --short main)"
: > "$WORK/wait.log"
when_waiting "$waiting" git -C "$WORK/engine.git" tag v2026.11.3 main &
RELEASE_WAIT=60 RELEASE_POLL=1 "$WORK/engine/deploy" self > "$WORK/wait.log" 2>&1
wait $!
cat "$WORK/wait.log"
grep -q "Waiting for the release tag on $waiting" "$WORK/wait.log" || fail "self did not wait for the release tag"
grep -q "Updated v2026.11.2+2 → v2026.11.3$" "$WORK/wait.log" || fail "self does not show the tag that came during the wait"
sed -n '/^v2026.11.3$/,$p' "$WORK/wait.log" | grep -E "^    [0-9a-f]+ Unpulled engine$" > /dev/null \
    || fail "self does not list the notes of the tag that came during the wait"
if grep -q "Not released yet" "$WORK/wait.log"; then
    fail "self lists the tagged commit as not released"
fi
printf '# no release\n' >> "$WORK/engine-src/deploy"
git -C "$WORK/engine-src" -c user.name=test -c user.email=test@example.com commit --quiet -am "No-release engine"
git -C "$WORK/engine-src" push --quiet "$WORK/engine.git" main
git -C "$WORK/engine.git" update-ref "refs/no-release/$(git -C "$WORK/engine.git" rev-parse main)" main
RELEASE_WAIT=60 RELEASE_POLL=1 "$WORK/engine/deploy" self > "$WORK/wait.log" 2>&1
if grep -q "Waiting for the release tag" "$WORK/wait.log"; then
    fail "self waited for a commit with a no-release marker"
fi
grep -q "no-release merge" "$WORK/wait.log" || fail "self does not name the no-release merge"
git init --quiet --bare "$WORK/engine-notags.git"
git -C "$WORK/engine-src" push --quiet "$WORK/engine-notags.git" main
git clone --quiet --no-tags --branch main "file://$WORK/engine-notags.git" "$WORK/engine-notags"
printf '# no tags\n' >> "$WORK/engine-src/deploy"
git -C "$WORK/engine-src" -c user.name=test -c user.email=test@example.com commit --quiet -am "Engine without tags"
git -C "$WORK/engine-src" push --quiet "$WORK/engine-notags.git" main
RELEASE_WAIT=60 RELEASE_POLL=1 "$WORK/engine-notags/deploy" self > "$WORK/wait.log" 2>&1
if grep -q "Waiting for the release tag" "$WORK/wait.log"; then
    fail "self waited in an engine repo without tags"
fi
grep -qE "^.*[0-9a-f]+ Engine without tags$" "$WORK/wait.log" || fail "self without tags did not update"
check "self waits for the tag and shows it with its notes; a no-release marker and a repo without tags do not wait"

step "SHARED paths with spaces work; a leading / or .. is refused"
SPACES="$WORK/spaces-old"
git clone --quiet --branch develop "file://$REPO" "$SPACES"
sed -i.bak 's/^SHARED=(.env data)$/SHARED=(.env data "user files")/' "$SPACES/deploy.conf"
rm "$SPACES/deploy.conf.bak"
grep -q '"user files"' "$SPACES/deploy.conf" || fail "the spaces fixture has no path with a space"
git -C "$SPACES" -c user.name=test -c user.email=test@example.com commit --quiet -am "spaces"
git -C "$SPACES" push --quiet origin develop:spaces
printf 'APP_ENV=production\n' > "$SPACES/.env"
mkdir -p "$SPACES/data" "$SPACES/user files"
printf 'upload\n' > "$SPACES/user files/a.txt"
cat > "$WORK/projects/spaces.env" <<EOF
DEPLOY_BASE="$WORK/spaces"
CHECK_URL="http://127.0.0.1:$PORT/"
CHECK_VERSION=0
REPO_URL="file://$REPO"
DEPLOY_BRANCH=spaces
EOF
deploy spaces init "$SPACES" --dry-run > "$WORK/spaces.log" 2>&1 \
    || { cat "$WORK/spaces.log"; fail "init --dry-run failed on a path with a space"; }
grep -qF "Would move $SPACES/user files to" "$WORK/spaces.log" || fail "init --dry-run split a path with a space"
deploy spaces init "$SPACES" > /dev/null || fail "init failed on a path with a space"
[ -f "$WORK/spaces/shared/user files/a.txt" ] || fail "init did not move the path with a space"
deploy spaces > "$WORK/spaces.log" 2>&1 || { cat "$WORK/spaces.log"; fail "a deploy with a SHARED path with a space failed"; }
[ "$(cat "$WORK/spaces/current/user files/a.txt")" = upload ] || fail "the path with a space is not linked"
for bad in '../outside' '/etc' 'data/../../outside'; do
    git -C "$SPACES" checkout --quiet -- deploy.conf
    sed -i.bak "s#^SHARED=.*#SHARED=(.env '$bad')#" "$SPACES/deploy.conf"
    rm "$SPACES/deploy.conf.bak"
    git -C "$SPACES" -c user.name=test -c user.email=test@example.com commit --quiet -am "bad $bad"
    git -C "$SPACES" push --quiet origin HEAD:spaces
    live="$(readlink "$WORK/spaces/current")"
    if deploy spaces > /dev/null 2> "$WORK/spaces.err"; then
        fail "a deploy with SHARED path $bad succeeded"
    fi
    grep -qF "SHARED path '$bad' must stay inside the release: no leading / and no .." "$WORK/spaces.err" \
        || { cat "$WORK/spaces.err"; fail "no message for SHARED path $bad"; }
    [ "$(readlink "$WORK/spaces/current")" = "$live" ] || fail "a refused SHARED path $bad changed the live release"
done
check "init and deploy handle a SHARED path with a space; ../outside, /etc and data/../../outside are refused"

step "CLEAR_PATHS refuses deploy.conf, .git, a leading /, . and .. before deleting anything"
for bad in 'deploy.conf' '.git' '.git/hooks' '/etc' '../outside' 'tests/../deploy.conf' '.' ''; do
    sed -i.bak -e 's#^SHARED=.*#SHARED=(.env data "user files")#' \
        -e "s#^CLEAR_PATHS=.*#CLEAR_PATHS=(tests '$bad')#" "$SPACES/deploy.conf"
    rm "$SPACES/deploy.conf.bak"
    git -C "$SPACES" -c user.name=test -c user.email=test@example.com commit --quiet -am "clear $bad"
    git -C "$SPACES" push --quiet origin HEAD:spaces
    live="$(readlink "$WORK/spaces/current")"
    if deploy spaces > /dev/null 2> "$WORK/clear.err"; then
        fail "a deploy with CLEAR_PATHS path '$bad' succeeded"
    fi
    grep -qF "CLEAR_PATHS path '$bad'" "$WORK/clear.err" \
        || { cat "$WORK/clear.err"; fail "no message for CLEAR_PATHS path '$bad'"; }
    [ "$(readlink "$WORK/spaces/current")" = "$live" ] || fail "a refused CLEAR_PATHS path '$bad' changed the live release"
    [ -f "$WORK/spaces/current/deploy.conf" ] || fail "a refused CLEAR_PATHS path '$bad' deleted the live deploy.conf"
done
check "deploy.conf, .git, .git/hooks, /etc, ../outside, tests/../deploy.conf, . and an empty path are refused; the live release stays"

step "Usage errors fail with their one-line message"
# A project with no REPO_URL, for the first deploy, then with one fake release, for rollback.
printf 'DEPLOY_BASE="%s"\nCHECK_URL="http://127.0.0.1:%s/"\n' "$WORK/lone" "$PORT" > "$WORK/projects/lone.env"
printf 'not a folder\n' > "$WORK/a-file"
prod="$(live_release)"
# Runs the engine with the words after the message; fails unless it exits non-zero with that line.
usage_error() {
    local message="$1" code=0
    shift
    "$@" > /dev/null 2> "$WORK/usage.err" || code=$?
    [ "$code" -ne 0 ] || fail "$* succeeded"
    grep -qxF "deploy: $message" "$WORK/usage.err" || { cat "$WORK/usage.err"; fail "no message for $*: $message"; }
}
usage_error "unknown option for deploy: --bogus" deploy fixture --force --bogus
usage_error "unknown option for deploy: --bogus" deploy fixture deploy --bogus
usage_error "use --branch or --ref, not both" deploy fixture@s1 --branch feature/x --ref develop
usage_error "pr/3 is how a slot stores a pull request; use --pr 3" deploy fixture@s1 --branch pr/3
usage_error "set REPO_URL for the first deploy" deploy lone
usage_error "$prod is already live" deploy fixture rollback "$prod"
mkdir -p "$WORK/lone/releases/20260101-000000-abc1234"
ln -sfn "$WORK/lone/releases/20260101-000000-abc1234" "$WORK/lone/current"
usage_error "no good release older than 20260101-000000-abc1234" deploy lone rollback
MIN_FREE_MB=lots usage_error "MIN_FREE_MB must be a whole number of megabytes, not 'lots'" deploy fixture status
usage_error "'sx' is not a staging slot; use fixture@s1, fixture@s2, ..." deploy fixture@sx status
STAGING_URL='' CHECK_URL=localhost/app \
    usage_error "cannot find the host in CHECK_URL; set STAGING_URL with {slot}" deploy fixture@s1 status
usage_error "usage: deploy [project] log [count]" deploy fixture log ten
usage_error "usage: deploy self log [count]" deploy self log ten
usage_error "unknown command: deploy self bogus (try: deploy self, deploy self log [count])" deploy self bogus
usage_error "unknown command: deploy fixture slots bogus (try: slots, slots update)" deploy fixture slots bogus
usage_error "self works on the engine, not on a project: deploy self" deploy fixture self
usage_error "$WORK/a-file is not a folder" deploy fixture init "$WORK/a-file"
[ "$(live_release)" = "$prod" ] || fail "a usage error changed the live release"
[ "$(readlink "$WORK/lone/current")" = "$WORK/lone/releases/20260101-000000-abc1234" ] || fail "a refused rollback switched"
rm -rf "$WORK/projects/lone.env" "$WORK/lone" "$WORK/a-file"
check "each usage error exits non-zero with its message and changes nothing"

step "Slot commands run for real, in the old and the staging forms"
prod="$(live_release)"
prod_log="$(wc -l < "$BASE/deploy.log")"
slot_code() {
    curl --silent --output /dev/null --write-out '%{http_code}' "http://$1.localhost:$PORT/"
}
deploy fixture@s1 --branch=feature/x -y > /dev/null || fail "a slot deploy with --branch=feature/x -y failed"
[ "$(cat "$SLOT/BRANCH")" = feature/x ] || fail "--branch=feature/x did not store the branch"
[ "$(cat "$SLOT/current/VERSION")" = "$(git -C "$REPO" show feature/x:VERSION)" ] || fail "s1 does not run the tip of feature/x"
deploy fixture@s2 --pr=7 -y > /dev/null || fail "a slot deploy with --pr=7 -y failed"
[ "$(cat "$SLOT2/BRANCH")" = pr/7 ] || fail "--pr=7 did not store pr/7"
[ "$(cat "$SLOT2/current/VERSION")" = "$(git -C "$REPO" show refs/pull/7/head:VERSION)" ] || fail "s2 does not run the PR head"
deploy fixture@s1 down "slot work" > "$WORK/slot.log"
grep -qxF "==> The site is down for maintenance: slot work" "$WORK/slot.log" || fail "slot down did not say it is down"
[ "$(slot_code s1)" = 503 ] || fail "slot down did not serve a 503"
[ ! -e "$BASE/.down" ] || fail "slot down took production down"
serves "$prod" || fail "production does not serve $prod while s1 is down"
deploy fixture@s1 up > /dev/null
[ "$(slot_code s1)" = 200 ] || fail "slot up did not bring s1 back"
deploy staging fixture@s1 down "staging work" > /dev/null
[ "$(slot_code s1)" = 503 ] || fail "staging down did not serve a 503"
deploy staging fixture@s1 up > "$WORK/slot.log"
grep -qxF "==> The site is up again" "$WORK/slot.log" || fail "staging up did not say it is up"
[ "$(slot_code s1)" = 200 ] || fail "staging up did not bring s1 back"
s1_live="$(slot_live)"
deploy staging fixture@s1 rollback > /dev/null || fail "staging rollback failed"
s1_back="$(slot_live)"
[ "$s1_back" != "$s1_live" ] || fail "staging rollback did not switch s1"
deploy fixture@s1 rollback "$s1_live" > /dev/null || fail "a named slot rollback failed"
[ "$(slot_live)" = "$s1_live" ] || fail "a named slot rollback did not go back to $s1_live"
deploy fixture@s1 log 2 > "$WORK/slot.log"
cat "$WORK/slot.log"
grep -qE "rollback@s1 +$s1_back +ok" "$WORK/slot.log" || fail "slot log does not show the staging rollback"
grep -qE "rollback@s1 +$s1_live +ok" "$WORK/slot.log" || fail "slot log does not show the named rollback"
[ "$(deploy staging fixture@s1 log 2)" = "$(cat "$WORK/slot.log")" ] || fail "staging log does not match the slot log"
[ "$(deploy fixture@s1 staging log 2)" = "$(cat "$WORK/slot.log")" ] || fail "fixture@s1 staging log does not match the slot log"
[ "$(deploy fixture staging)" = "$(deploy fixture slots)" ] || fail "fixture staging does not list the slots"
[ "$(live_release)" = "$prod" ] || fail "slot commands changed the production release"
[ "$(wc -l < "$BASE/deploy.log")" = "$prod_log" ] || fail "slot commands wrote to the production deploy.log"
check "--branch=, --pr= and -y deployed slots; down, up, rollback and log worked on s1 in both forms; production is unchanged"

printf '\nAll deploy tests passed.\n'
