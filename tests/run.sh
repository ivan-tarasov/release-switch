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

cleanup() {
    # The workers are children of the server; they outlive it if only it is killed.
    if [ -n "$SERVER_PID" ]; then
        pkill -P "$SERVER_PID" 2>/dev/null || true
        kill "$SERVER_PID" 2>/dev/null || true
    fi

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

# Runs the engine for the test project, from a projects/ folder in the temp dir.
run() {
    env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 "$@"
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
PROJECTS_DIR="$WORK/empty" "$ROOT/deploy" --help | grep -q "^Usage: deploy" || fail "--help shows no usage"
if deploy fixture nope 2> /dev/null; then
    fail "an unknown command succeeded"
fi
deploy --help | grep -q "fixture" || fail "--help does not list the project"
deploy fixture help | grep -q "CHECK_WAIT .*(10)" || fail "an env var does not win over the project file"
check "--help works, lists projects and shows env overrides; an unknown command fails"

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
cat > "$WORK/router.php" <<EOF
<?php
chdir('$BASE/current/public');
require '$BASE/current/public/index.php';
EOF
PHP_CLI_SERVER_WORKERS=4 php -d realpath_cache_size=0 -S "127.0.0.1:$PORT" "$WORK/router.php" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!

step "First deploy, with the project left out"
deploy
first="$(live_release)"
[[ "$first" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{7,}$ ]] || fail "release name $first is not <date>-<time>-<sha>"
serves "$first" || fail "server does not show $first"
[ "$(cat "$BASE/shared/data/switched")" = "$first" ] || fail "after_switch did not run"
[ -L "$BASE/current/data" ] || fail "data/ is not linked from shared/"
check "live: $first; after_switch ran; data/ is shared"

sleep 1
step "Second deploy, of a new tagged commit"
commit "fixture v2"
git -C "$REPO" tag v2026.11.99 develop
deploy fixture
second="$(live_release)"
[[ "$second" =~ ^[0-9]{8}-[0-9]{6}-v2026\.11\.99-[0-9a-f]{7,}$ ]] || fail "release name $second has no tag"
serves "$second" || fail "server does not show $second"
[ "$(cat "$BASE/current/cache/origin")" = "$first" ] || fail "cache/ was not copied from $first"
[ ! -L "$BASE/current/cache" ] || fail "cache/ is a link, not a copy"
check "live: $second; cache/ copied from $first"

step "Rollback"
deploy fixture rollback
[ "$(live_release)" = "$first" ] || fail "rollback did not go back to $first"
serves "$first" || fail "server does not show $first after rollback"
[ -e "$BASE/releases/$second/.bad" ] || fail "rollback did not mark $second as bad"
check "rolled back to $first; $second is marked bad"

releases_before="$(release_count)"

sleep 1
step "Failing deploy: the build stops at its first error"
if FIXTURE_FAIL_BUILD=1 deploy fixture; then
    fail "deploy with a failing build succeeded"
fi
[ "$(live_release)" = "$first" ] || fail "current moved after a failed build"
[ "$(release_count)" = "$releases_before" ] || fail "the failed release folder was left behind"
check "$first is still live and the broken release is gone"

sleep 1
step "Failing deploy: preflight refuses a wrong .env"
sed -i.bak 's/production/staging/' "$BASE/shared/.env"
if deploy fixture 2> /dev/null; then
    fail "deploy with a wrong .env succeeded"
fi
mv "$BASE/shared/.env.bak" "$BASE/shared/.env"
[ "$(live_release)" = "$first" ] || fail "current moved after a failed preflight"
check "preflight stopped it"

sleep 1
step "Failing deploy: the check fails after the switch"
if CHECK_URL="http://127.0.0.1:$PORT/missing" deploy fixture 2> "$WORK/check.log"; then
    fail "deploy with a failing check succeeded"
fi
cat "$WORK/check.log" >&2
grep -q "answered 404" "$WORK/check.log" || fail "the failure does not show the 404"
[ "$(live_release)" = "$first" ] || fail "no automatic rollback to $first"
serves "$first" || fail "server does not show $first after the rollback"
[ "$(release_count)" = "$((releases_before + 1))" ] || fail "the failed release was not set aside"
check "rolled back to $first automatically; the failed release waits in .failed-*"

sleep 1
step "A failing after_switch only warns; the deploy deletes the failed release"
FIXTURE_FAIL_AFTER=1 deploy fixture > "$WORK/after.log"
grep -q "after_switch failed; carrying on" "$WORK/after.log" || fail "no warning for after_switch"
latest="$(live_release)"
serves "$latest" || fail "server does not show $latest"
[ "$(release_count)" = "$((releases_before + 1))" ] || fail "the failed release is still there"
check "live: $latest, failed release gone"

step "Status"
DISPLAY_TZ=America/Toronto deploy fixture status > "$WORK/status.log"
cat "$WORK/status.log"
grep -qE "^Live: +$latest$" "$WORK/status.log" || fail "status does not show the live release"
grep -qE "deployed 20[0-9-]+ [0-9:]+ E[SD]T$" "$WORK/status.log" || fail "status does not show the time in DISPLAY_TZ only"
grep -qE "^Rollback: +$first$" "$WORK/status.log" || fail "status does not skip the bad $second"
grep -qF "$second  (bad; rollback skips it)" "$WORK/status.log" || fail "status does not mark $second as bad"
grep -qF "* $latest  (live)" "$WORK/status.log" || fail "status does not mark the live release"
grep -q "Lock: *free" "$WORK/status.log" || fail "status does not show a free lock"
grep -q "answered 200, version $latest (matches live)" "$WORK/status.log" || fail "status does not check the site"
check "status shows the live release, the rollback target and the site"

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

step "Rollback to a named release"
if deploy fixture rollback v2026.11.99 2> "$WORK/ambiguous.log"; then
    fail "rollback to a part shared by two releases succeeded"
fi
grep -q "matches 2 releases" "$WORK/ambiguous.log" || fail "no message for a part shared by two releases"
if deploy fixture rollback nope 2> /dev/null; then
    fail "rollback to a missing release succeeded"
fi
deploy fixture rollback
[ "$(live_release)" = "$first" ] || fail "rollback did not skip the bad $second"
serves "$first" || fail "server does not show $first"
deploy fixture rollback "${second:0:15}"
[ "$(live_release)" = "$second" ] || fail "rollback by time did not go to $second"
serves "$second" || fail "server does not show $second after a rollback by time"
[ ! -e "$BASE/releases/$second/.bad" ] || fail "going to $second by name did not clear its bad mark"
[ ! -d "$BASE/.deploy.lock" ] || fail "rollback left the lock behind"
check "rollback skipped the bad $second; naming it went there and cleared the mark; unclear and missing names refused"

step "A second deploy waits for the lock"
mkdir "$BASE/.deploy.lock"
if deploy fixture 2> "$WORK/lock.log"; then
    fail "deploy ran while locked"
fi
grep -q "another deploy is running" "$WORK/lock.log" || fail "no lock message"
rmdir "$BASE/.deploy.lock"
check "locked deploy refused"

step "Shared files survive deploys"
[ "$(curl --silent "http://127.0.0.1:$PORT/")" = "kept across releases" ] || fail "the shared note is gone"
check "the note from before init is still served"

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

printf '\nAll deploy tests passed.\n'
