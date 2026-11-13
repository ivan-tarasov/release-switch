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
# /hook stands in for an alert webhook: it keeps each request body in hook.log.
cat > "$WORK/router.php" <<EOF
<?php
if (\$_SERVER['REQUEST_URI'] === '/hook') {
    file_put_contents('$WORK/hook.log', file_get_contents('php://input') . "\n", FILE_APPEND);
    return;
}
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
grep -qE "deployed today at [0-9:]+ E[SD]T$" "$WORK/status.log" || fail "status does not show today's time in DISPLAY_TZ only"
grep -qE "^Rollback: +$first$" "$WORK/status.log" || fail "status does not skip the bad $second"
grep -qF "$second  (bad; rollback skips it)" "$WORK/status.log" || fail "status does not mark $second as bad"
grep -qF "* $latest  (live)" "$WORK/status.log" || fail "status does not mark the live release"
grep -q "Lock: *free" "$WORK/status.log" || fail "status does not show a free lock"
grep -q "answered 200, version $latest (matches live)" "$WORK/status.log" || fail "status does not check the site"
grep -q "^Pending: *none (live is the tip of develop)" "$WORK/status.log" || fail "status shows pending commits when live is the tip"
check "status shows the live release, the rollback target and the site"

step "Status lists commits not deployed yet"
commit "fixture pending one"
commit "fixture pending two"
deploy fixture status > "$WORK/pending.log"
cat "$WORK/pending.log"
grep -q "^Pending: *2 commit(s) on develop, not deployed yet" "$WORK/pending.log" || fail "status does not count the pending commits"
grep -qE "^ +[0-9a-f]+ fixture pending two$" "$WORK/pending.log" || fail "status does not list the pending commits"
deploy status --all | grep -qE "^fixture +.*2 pending" || fail "status --all does not note the pending commits"
check "status lists 2 pending commits; status --all notes them"

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
grep -q "another deploy is running (no owner, [0-9]* s old)" "$WORK/lock.log" || fail "no lock message"
# Held by this test's shell, which is alive.
printf '%s %s deploy\n' "$$" "$(date +%s)" > "$BASE/.deploy.lock/owner"
if deploy fixture 2> "$WORK/lock.log"; then
    fail "deploy ran while a live process held the lock"
fi
grep -q "another deploy is running (PID $$, deploy, 0 min)" "$WORK/lock.log" || fail "the lock message does not name the owner"
deploy fixture status > "$WORK/lock-status.log"
grep -q "^Lock: *held (PID $$, deploy, 0 min)" "$WORK/lock-status.log" || fail "status does not show the lock owner"
check "locked deploy refused; the message and status name the owner"

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
check "deploy removed the stale lock and went live with $fresh"

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

step "Two runs racing on one stale lock never both hold it"
# Each run: the engine without its last line (main "$@"), then acquire_lock. A slow say() widens
# the gap between finding the lock stale and removing it.
mkdir "$WORK/race"
sed '$d' "$ROOT/deploy" > "$WORK/race.sh"
cat >> "$WORK/race.sh" <<'EOF'
DEPLOY_BASE="$RACE" PHP_BIN=php
say() { sleep "0.0$((RANDOM % 3))"; }
touch "$RACE/ready.$1"
until [ -e "$RACE/go" ]; do :; done
acquire_lock deploy 2> /dev/null
mkdir "$RACE/inside" 2> /dev/null || touch "$RACE/both"
touch "$RACE/won"
sleep 0.05
rmdir "$RACE/inside" 2> /dev/null || true
rm -rf "$LOCK_DIR"
EOF
for round in $(seq 50); do
    rm -f "$WORK/race/ready."* "$WORK/race/go" "$WORK/race/won"
    mkdir "$WORK/race/.deploy.lock"
    printf '%s %s deploy\n' "$dead" "$(date +%s)" > "$WORK/race/.deploy.lock/owner"
    RACE="$WORK/race" bash "$WORK/race.sh" a &
    racer_a=$!
    RACE="$WORK/race" bash "$WORK/race.sh" b &
    racer_b=$!
    until [ -e "$WORK/race/ready.a" ] && [ -e "$WORK/race/ready.b" ]; do :; done
    touch "$WORK/race/go"
    # Not a bare wait: the web server is a child too. One run fails on the lock.
    wait "$racer_a" || true
    wait "$racer_b" || true
    [ ! -e "$WORK/race/both" ] || fail "two runs held the lock at once in round $round"
    [ -e "$WORK/race/won" ] || fail "no run took the stale lock in round $round"
    [ ! -e "$WORK/race/.deploy.lock" ] || fail "the lock is left behind after round $round"
done
check "50 rounds of two runs on one stale lock: one holder at a time"

step "A deploy with nothing new stops; --force builds anyway"
releases_now="$(release_count)"
deploy fixture > "$WORK/skip.log"
cat "$WORK/skip.log"
grep -q "Nothing new on develop: $fresh already runs" "$WORK/skip.log" || fail "no message for a deploy with nothing new"
[ "$(release_count)" = "$releases_now" ] || fail "a deploy with nothing new made a release"
[ "$(live_release)" = "$fresh" ] || fail "a deploy with nothing new changed the live release"
sleep 1
deploy fixture --force > /dev/null
fresh="$(live_release)"
[ "$(release_count)" = "$((releases_now + 1))" ] || fail "--force did not build a release"
serves "$fresh" || fail "server does not show $fresh"
check "nothing new: no release; --force: live with $fresh"

step "Freeze stops deploys and rollbacks until unfreeze"
deploy fixture freeze "moving hosts" > /dev/null
if deploy fixture --force 2> "$WORK/freeze.log"; then
    fail "deploy ran while frozen"
fi
grep -q "deploys are frozen since today at .*: moving hosts (run: deploy fixture unfreeze)" "$WORK/freeze.log" \
    || fail "no freeze message for deploy"
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
sleep 1
deploy fixture --ref v2026.11.99 > /dev/null
tagged="$(live_release)"
[[ "$tagged" =~ -v2026\.11\.99-[0-9a-f]{7,}$ ]] || fail "--ref v2026.11.99 deployed $tagged"
serves "$tagged" || fail "server does not show $tagged"
deploy fixture --ref v2026.11.99 > "$WORK/ref.log"
grep -q "$tagged already runs v2026.11.99" "$WORK/ref.log" || fail "--ref of the live commit did not stop"
[ "$(live_release)" = "$tagged" ] || fail "--ref of the live commit changed the live release"
sleep 1
older="$(git -C "$REPO" rev-parse --short develop~1)"
deploy fixture --ref "$older" > /dev/null
[[ "$(live_release)" == *"-$older" ]] || fail "--ref $older deployed $(live_release)"
if deploy fixture --ref nope 2> "$WORK/ref.log"; then
    fail "--ref of a missing ref succeeded"
fi
grep -q "no tag, branch or commit nope" "$WORK/ref.log" || fail "no message for a missing ref"
sleep 1
deploy --ref=develop > "$WORK/ref.log"
fresh="$(live_release)"
grep -q "^1 commit(s):$" "$WORK/ref.log" || fail "--ref=develop does not list the commit it ships"
[[ "$fresh" == *"-$(git -C "$REPO" rev-parse --short develop)" ]] || fail "--ref=develop deployed $fresh"
serves "$fresh" || fail "server does not show $fresh"
check "--ref deployed a tag, a commit and a branch; the live commit and a missing ref stopped"

step "Shared files survive deploys"
[ "$(curl --silent "http://127.0.0.1:$PORT/")" = "kept across releases" ] || fail "the shared note is gone"
check "the note from before init is still served"

step "Rails on a terminal"
commit "fixture rails"
sleep 1
DEPLOY_RAILS=1 deploy fixture > "$WORK/rails.log"
cat "$WORK/rails.log"
fresh="$(live_release)"
grep -qE "^┌  release-switch [0-9a-fv.+]+ · fixture · deploy$" "$WORK/rails.log" || fail "no opening line with the version"
grep -q "^◇  Running build$" "$WORK/rails.log" || fail "steps are not on the rails"
grep -qE "^│    [0-9a-f]+ fixture rails$" "$WORK/rails.log" || fail "the shipped commits are not on the rail"
grep -qE "^└  Done in [0-9]+s$" "$WORK/rails.log" || fail "no closing line"
if FIXTURE_FAIL_BUILD=1 DEPLOY_RAILS=1 deploy fixture --force > "$WORK/rails.log" 2> "$WORK/rails-err.log"; then
    fail "a deploy with a failing build succeeded"
fi
grep -q "^■  build failed$" "$WORK/rails-err.log" || fail "the failure is not marked"
grep -qE "^└  Failed after [0-9]+s$" "$WORK/rails.log" || fail "no closing line for the failure"
DEPLOY_RAILS=1 deploy fixture status > "$WORK/rails.log"
grep -q "^│  Live: *$fresh$" "$WORK/rails.log" || fail "status is not on the rail"
deploy fixture status > "$WORK/rails.log"
grep -q "^Live: *$fresh$" "$WORK/rails.log" || fail "status has rails in a pipe"
check "a deploy, a failed deploy and status on the rails; plain lines in a pipe"

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
sleep 1
deploy fixture --force > "$WORK/down-deploy.log" || fail "deploy failed while down"
grep -q "Not checking .*: the site is down for maintenance" "$WORK/down-deploy.log" || fail "deploy checked the site while down"
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

step "Alerts"
export ALERTS="$WORK/alerts.log"
: > "$ALERTS"
# shellcheck disable=SC2016 # Expanded by the engine's sh -c, not here.
alert_cmd='printf "%s|%s\n" "$NOTIFY_EVENT" "$NOTIFY_TEXT" >> "$ALERTS"'
if FIXTURE_FAIL_BUILD=1 NOTIFY_URL="http://127.0.0.1:$PORT/hook" NOTIFY_CMD="$alert_cmd" deploy fixture --force 2> /dev/null; then
    fail "a deploy with a failing build succeeded"
fi
cat "$ALERTS"
grep -qE "^deploy\|fixture: deploy [0-9-]+.*: failed: build \(build failed\)$" "$ALERTS" || fail "no alert for the failed build"
grep -qF '"text":"fixture: deploy ' "$WORK/hook.log" || fail "NOTIFY_URL got no JSON alert"
grep -qF '"event":"deploy"' "$WORK/hook.log" || fail "the JSON alert has no event"
NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null
[ "$(wc -l < "$ALERTS" | tr -d ' ')" = 1 ] || fail "a successful deploy sent an alert without NOTIFY_ON=all"
NOTIFY_ON=all NOTIFY_URL="http://127.0.0.1:1/" NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null 2> "$WORK/notify.log" \
    || fail "an alert that cannot be sent failed the deploy"
grep -q "could not send the alert to NOTIFY_URL" "$WORK/notify.log" || fail "no warning for an alert that cannot be sent"
grep -qE "^deploy\|fixture: deploy [0-9-]+.*: ok \([0-9]+s\)$" "$ALERTS" || fail "NOTIFY_ON=all sent no alert for a good deploy"
NOTIFY_CMD="$alert_cmd" deploy fixture rollback > /dev/null
grep -qE "^rollback\|fixture: rollback [0-9-]+.*: ok, from " "$ALERTS" || fail "no alert for a rollback"
check "alerts for a failed build and a rollback; good deploys only with NOTIFY_ON=all; a dead webhook only warns"

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
sleep 1
NOTIFY_ON=all NOTIFY_CMD="$alert_cmd" deploy fixture > "$WORK/shipped.log"
cat "$WORK/shipped.log"
grep -q "^2 commit(s):$" "$WORK/shipped.log" || fail "deploy does not count the commits it ships"
grep -qE "^  [0-9a-f]+ fixture shipped two$" "$WORK/shipped.log" || fail "deploy does not list the commits it ships"
deploy fixture log 1 > "$WORK/shipped-log.log"
cat "$WORK/shipped-log.log"
grep -q "ok ([0-9]*s)  2 commit(s): fixture shipped two; fixture shipped one$" "$WORK/shipped-log.log" \
    || fail "the log does not list the commits"
grep -qE "^  [0-9a-f]+ fixture shipped one$" "$ALERTS" || fail "the alert does not list the commits"
check "the output, the log and the alert list both commits"

step "Check alerts only when the result changes"
: > "$ALERTS"
for _ in 1 2; do
    if CHECK_URL="http://127.0.0.1:$PORT/missing" NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null 2>&1; then
        fail "check passed with a 404"
    fi
done
cat "$ALERTS"
[ "$(grep -c "^check|fixture: check failed: site: .* answered 404" "$ALERTS")" = 1 ] || fail "check did not alert once for the 404"
NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null || fail "check failed on a healthy site"
grep -q "^check|fixture: check ok again$" "$ALERTS" || fail "no alert when the check is ok again"
[ ! -e "$BASE/.check-failed" ] || fail "check kept the failure state after it was ok"
NOTIFY_CMD="$alert_cmd" deploy fixture check > /dev/null
[ "$(wc -l < "$ALERTS" | tr -d ' ')" = 2 ] || fail "a healthy check sent another alert"
check "one alert for a failing check, one when it is ok again, none while nothing changes"

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
sleep 1
PHP_RELOAD_CMD="readlink \"$BASE/current\" > \"$WORK/reload.txt\"; exit 3" deploy fixture --force > "$WORK/reload.log" \
    || fail "a failing PHP_RELOAD_CMD failed the deploy"
reloaded="$(live_release)"
[ "$(cat "$WORK/reload.txt")" = "releases/$reloaded" ] || fail "PHP_RELOAD_CMD did not run after the switch"
grep -q "PHP_RELOAD_CMD failed; carrying on" "$WORK/reload.log" || fail "no warning for a failing PHP_RELOAD_CMD"
serves "$reloaded" || fail "server does not show $reloaded"
check "PHP_RELOAD_CMD ran with $reloaded linked; its failure only warned"

step "A hangup or TERM during PHP_RELOAD_CMD keeps the new release live"
for signal in HUP:129 TERM:143; do
    sleep 1
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

step "Prune keeps the release that was just live"
sleep 1
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r1="$(live_release)"
sleep 1
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r2="$(live_release)"
KEEP_RELEASES=2 deploy fixture rollback > /dev/null
[ "$(live_release)" = "$r1" ] || fail "rollback did not go back to $r1"
sleep 1
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r3="$(live_release)"
[ -d "$BASE/releases/$r1" ] || fail "prune deleted $r1, live before $r3"
[ -d "$BASE/releases/$r2" ] && [ "$(release_count)" = 3 ] || fail "prune did not keep $r1, $r2 and $r3"
sleep 1
KEEP_RELEASES=2 deploy fixture --force > /dev/null
r4="$(live_release)"
[ "$(release_count)" = 2 ] && [ -d "$BASE/releases/$r3" ] && [ -d "$BASE/releases/$r4" ] \
    || fail "prune did not keep only $r3 and $r4"
serves "$r4" || fail "server does not show $r4"
check "prune kept $r1 after a rollback, then kept the newest 2 and deleted the oldest"

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
"$WORK/engine/deploy" self > "$WORK/self.log"
cat "$WORK/self.log"
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
grep -q "could not update" "$WORK/self.log" || fail "no message when self-update cannot pull"
check "self-update shows both versions, lists new tags and commits, says when it is up to date, and stops on local changes; --version follows the tags"

step "status --all shows the engine"
PROJECTS_DIR="$WORK/projects" "$WORK/engine/deploy" status --all > "$WORK/engine-row.log"
cat "$WORK/engine-row.log"
grep -qE "^release-switch +v2026\.11\.2\+1 +today at .* +- +1 new, run deploy self, local changes$" "$WORK/engine-row.log" \
    || fail "status --all does not show the engine behind and changed"
git -C "$WORK/engine" checkout --quiet -- deploy
"$WORK/engine/deploy" self > /dev/null
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
check "self log lists installed and unpulled commits; an unknown self command fails"

printf '\nAll deploy tests passed.\n'
