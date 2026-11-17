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
grep -q "^Usage: deploy \[project\] rollback \[name\] \[--yes\]$" "$WORK/help.log" || fail "rollback --help shows no usage line"
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
# opcache-stall exists.
cat > "$WORK/router.php" <<EOF
<?php
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
    others="$(cat "$WORK/race/err."* | grep -v "another deploy is running" || true)"
    [ -z "$others" ] || fail "a losing run failed for another reason in round $round: $others"
done
check "40 rounds of three runs on one stale lock: one holder at a time, losers say another deploy runs"

step "A stale lock removal that stopped half way is reported"
mkdir "$BASE/.deploy.lock" "$BASE/.deploy.lock.break"
printf '%s %s deploy\n' "$dead" "$(date +%s)" > "$BASE/.deploy.lock/owner"
TZ=UTC touch -t "$(php -r 'echo gmdate("YmdHi.s", time() - 120);')" "$BASE/.deploy.lock.break"
if deploy fixture > "$WORK/break.log" 2>&1; then
    fail "deploy ran past a stuck stale lock removal"
fi
grep -q "a stale lock removal stopped half way; remove .*\.deploy\.lock\.break" "$WORK/break.log" || fail "deploy does not name the stuck break folder"
rm -rf "$BASE/.deploy.lock" "$BASE/.deploy.lock.break"
check "a break folder older than 60 s blocks with a message that names it"

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
FIXTURE_DETAILS="$WORK/details" NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null
grep -qx "FORCED=1" "$WORK/details" || fail "a --force deploy did not set DEPLOY_FORCED=1"
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

step "An unwritable deploy.log never stops the alert or the cleanup"
# A folder in its place: appends fail, as on a full or read-only disk.
mv "$BASE/deploy.log" "$WORK/deploy.log.kept"
mkdir "$BASE/deploy.log"
: > "$ALERTS"
if FIXTURE_FAIL_BUILD=1 NOTIFY_CMD="$alert_cmd" deploy fixture --force > /dev/null 2> "$WORK/nolog.log"; then
    fail "a deploy with a failing build succeeded"
fi
cat "$WORK/nolog.log"
grep -qE "^deploy\|fixture: deploy [0-9-]+.*: failed: build \(build failed\)$" "$ALERTS" \
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
grep -q "Cloning" "$WORK/disk.out" && fail "a deploy with too little free space started to clone"
[ "$(live_release)" = "$before" ] || fail "a deploy with too little free space changed the live release"
[ "$(release_count)" = "$count" ] || fail "a deploy with too little free space made a release"
[ ! -d "$BASE/.deploy.lock" ] || fail "a deploy with too little free space left the lock behind"
DISK_LIMIT=1K deploy fixture --force > /dev/null 2> "$WORK/disk.log" || fail "a deploy over DISK_LIMIT failed"
grep -q "over DISK_LIMIT (1K)" "$WORK/disk.log" || fail "a deploy over DISK_LIMIT did not warn"
check "check passes under DISK_LIMIT and fails over it with an alert; status shows the disk; too little free space stops check and deploy"

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

step "A step past STEP_TIMEOUT fails the deploy, stops all it started and frees the lock"
before="$(live_release)"
sleep 1
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
grep -q "^■  build ran past STEP_TIMEOUT (1 s)$" "$WORK/timeout.log" || fail "the timeout is not marked on the rails"
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
sleep 1
rm -f "$WORK/slow.pid" "$WORK/slow.pid.sleep"
# An odd STEP_TIMEOUT, so the watchdog's sleep is easy to find.
env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT=0 STEP_TIMEOUT=97 FIXTURE_SLOW_BUILD="$WORK/slow.pid" \
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
pgrep -f "sleep 97" > /dev/null && fail "TERM left the watchdog running"
[ ! -d "$BASE/.deploy.lock" ] || fail "TERM during a step left the lock behind"
STEP_TIMEOUT=97 deploy fixture --force > /dev/null || fail "a deploy with STEP_TIMEOUT=97 failed"
pgrep -f "sleep 97" > /dev/null && fail "a good deploy left a watchdog running"
check "TERM stopped the step and its watchdog and freed the lock; a good deploy leaves no watchdog"

step "A slow PHP_RELOAD_CMD only warns"
sleep 1
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
sleep 1
rm -f "$WORK/opcache.log"
deploy fixture --force > /dev/null || fail "a deploy without OPCACHE_RESET_DIR failed"
[ ! -e "$WORK/opcache.log" ] || fail "an OPcache reset ran with OPCACHE_RESET_DIR off"
sleep 1
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
sleep 1
touch "$WORK/opcache-fail"
OPCACHE_RESET_DIR=public deploy fixture --force > /dev/null 2> "$WORK/opcache.out" \
    || fail "a failing OPcache reset failed the deploy"
rm -f "$WORK/opcache-fail"
grep -qE "OPcache reset at http://127[.]0[.]0[.]1:$PORT/rs-opcache-[0-9a-f]{32}[.]php answered 500; carrying on" "$WORK/opcache.out" \
    || fail "no warning for a failing OPcache reset"
no_opcache_files || fail "a failing OPcache reset left the file behind"
sleep 1
touch "$WORK/opcache-stall"
started="$(date +%s)"
STEP_TIMEOUT=3 OPCACHE_RESET_DIR=public deploy fixture --force > /dev/null 2> "$WORK/opcache.out" \
    || fail "a slow OPcache reset failed the deploy"
rm -f "$WORK/opcache-stall"
[ $(($(date +%s) - started)) -lt 15 ] || fail "the slow OPcache reset held the deploy for $(($(date +%s) - started)) s"
grep -q "ran past 3 s; carrying on" "$WORK/opcache.out" || fail "no warning for a slow OPcache reset"
no_opcache_files || fail "a slow OPcache reset left the file behind"
sleep 1
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

step "The site check gets past a cache"
sleep 1
rm -f "$WORK/cached.log"
CHECK_URL="http://127.0.0.1:$PORT/cached" deploy fixture --force > "$WORK/cached.out" 2>&1 \
    || fail "a deploy behind a cache failed"
cached="$(live_release)"
cat "$WORK/cached.log"
grep -q "^/cached?rs=$cached-[0-9]* no-cache no-cache$" "$WORK/cached.log" \
    || fail "the check did not send rs=$cached and the no-cache headers"
sleep 1
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
sleep 1
touch "$WORK/stall"
started=$(date +%s)
CHECK_URL="http://127.0.0.1:$PORT/stall" deploy fixture --force > "$WORK/stall.out" 2>&1 \
    || { cat "$WORK/stall.out"; fail "a deploy with one stuck check request failed"; }
took=$(($(date +%s) - started))
[ ! -e "$WORK/stall" ] || fail "the check never hit the stuck request"
[ "$took" -lt 15 ] || fail "the deploy waited ${took} s on a stuck request"
check "the stuck request was cut at CHECK_WAIT / 3 and the retry passed (${took} s)"

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
sleep 1
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

sleep 1
kill_build
mkdir "$BASE/releases/.building-20260101-000000"
sleep 1
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
    sleep 1
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

step "A new untagged commit waits for its release tag"
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

sleep 1
RELEASE_WAIT=30 RELEASE_POLL=1 deploy fixture --no-wait > "$WORK/wait.log" 2>&1
if grep -q "Waiting for the release tag" "$WORK/wait.log"; then
    fail "--no-wait waited for the release tag"
fi
grep -q "no release tag on $waiting; deploying without one" "$WORK/wait.log" || fail "--no-wait gave no warning"
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-$waiting$ ]] || fail "--no-wait deployed $(live_release)"
check "--no-wait deployed $waiting without a tag and warned"

sleep 1
commit "fixture wait timeout"
waiting="$(git -C "$REPO" rev-parse --short develop)"
RELEASE_WAIT=2 RELEASE_POLL=1 deploy fixture > "$WORK/wait.log" 2>&1
grep -q "Waiting for the release tag on $waiting (0 s of 2)" "$WORK/wait.log" || fail "deploy did not wait for the release tag"
grep -q "Waiting for the release tag on $waiting (2 s of 2)" "$WORK/wait.log" || fail "the wait line shows no elapsed seconds"
grep -q "no release tag on $waiting after 2 s; deploying without one" "$WORK/wait.log" || fail "no warning after the wait"
[[ "$(live_release)" =~ ^[0-9]{8}-[0-9]{6}-$waiting$ ]] || fail "the deploy after the wait deployed $(live_release)"
check "the wait ran out after 2 s; $waiting deployed without a tag"

sleep 1
commit "fixture wait tagged"
(
    sleep 2
    git -C "$REPO" tag v2026.11.100 develop
) &
RELEASE_WAIT=30 RELEASE_POLL=1 deploy fixture > "$WORK/wait.log" 2>&1
wait $!
grep -q "Waiting for the release tag on" "$WORK/wait.log" || fail "deploy did not wait for the release tag"
if grep -q "no release tag" "$WORK/wait.log"; then
    fail "a warning although the tag came"
fi
[[ "$(live_release)" =~ -v2026\.11\.100-[0-9a-f]{7,}$ ]] || fail "the tag pushed during the wait is not in $(live_release)"
serves "$(live_release)" || fail "server does not show $(live_release)"
check "the tag pushed during the wait is in $(live_release)"

sleep 1
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

sleep 1
commit "fixture no-release marker during the wait"
waiting="$(git -C "$REPO" rev-parse --short develop)"
(
    sleep 2
    git -C "$REPO" update-ref "refs/no-release/$(git -C "$REPO" rev-parse develop)" develop
) &
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

sleep 1
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

sleep 1
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
deploy fixture@s1 > /dev/null
[ "$(cat "$SLOT/current/VERSION")" = "feature two" ] || fail "a plain slot deploy did not follow feature/x"
[ "$(slot_live)" != "$first_slot" ] || fail "a plain slot deploy built nothing new"
deploy fixture@s1 > "$WORK/slot.log"
grep -q "Nothing new on feature/x" "$WORK/slot.log" || fail "a slot deploy with nothing new built again"
check "a plain deploy of fixture@s1 deployed the newest feature/x, then stopped with nothing new"

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
[ "$(deploy staging fixture@s1 path)" = "$(deploy path fixture@s1)" ] || fail "staging path does not print the slot's release"
deploy fixture@s1 status | grep -v deployed > "$WORK/status.log"
deploy staging fixture@s1 | grep -v deployed > "$WORK/staging.log"
diff "$WORK/status.log" "$WORK/staging.log" || fail "staging fixture@s1 does not show the slot's status"
deploy staging fixture@s1 status | grep -v deployed > "$WORK/staging.log"
diff "$WORK/status.log" "$WORK/staging.log" || fail "staging fixture@s1 status does not show the slot's status"
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
grep -qE "^  [0-9.]+[A-Z]?  data$" "$WORK/copy.log" || fail "copy-from does not list data with its size"
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
# Runs the engine on a terminal made by script; the answer comes once the prompt is up.
on_terminal() {
    local answer="$1"
    shift

    if script --version > /dev/null 2>&1; then
        { sleep 2; printf '%s\n' "$answer"; sleep 2; } | script -qec "$(printf '%q ' "$@")" /dev/null
    else
        { sleep 2; printf '%s\n' "$answer"; sleep 2; } | script -q /dev/null "$@"
    fi
}
if command -v script > /dev/null; then
    on_terminal n env PROJECTS_DIR="$WORK/projects" DEPLOY_RAILS=0 "$ROOT/deploy" fixture@s1 copy-from fixture > "$WORK/copy.log" 2>&1
    cat "$WORK/copy.log"
    grep -q "Copy these into fixture@s1? Its files are replaced \[y/N\]" "$WORK/copy.log" || fail "copy-from does not ask on a terminal"
    grep -q "Nothing copied" "$WORK/copy.log" || fail "copy-from does not stop on n"
    [ "$(cat "$SLOT/shared/data/note.txt")" = "slot data" ] || fail "copy-from copied after n"
    on_terminal y env PROJECTS_DIR="$WORK/projects" DEPLOY_RAILS=0 "$ROOT/deploy" fixture@s1 copy-from fixture > "$WORK/copy.log" 2>&1
    grep -q "Copied into fixture@s1: data" "$WORK/copy.log" || fail "copy-from does not copy on y"
    diff -r "$BASE/shared/data" "$SLOT/shared/data" > /dev/null || fail "copy-from on y did not copy data/"
    check "copy-from asked on a terminal: n copied nothing, y copied data/"
else
    check "skipped: no script command to make a terminal"
fi

step "rollback, down and deploy --force ask on a terminal"
# Like on_terminal, but holds the terminal open for $1 seconds after the answer, so a deploy can
# build. A run that ends before the answer, as with --yes, is fine.
on_terminal_hold() {
    local hold="$1" answer="$2"
    shift 2

    if script --version > /dev/null 2>&1; then
        { trap '' PIPE; sleep 2; printf '%s\n' "$answer" 2> /dev/null; sleep "$hold"; true; } \
            | script -qec "$(printf '%q ' "$@")" /dev/null
    else
        { trap '' PIPE; sleep 2; printf '%s\n' "$answer" 2> /dev/null; sleep "$hold"; true; } | script -q /dev/null "$@"
    fi
}
# Runs the engine on a terminal with answer $1, into ask.log; fails with the log when it fails.
ask_run() {
    local answer="$1"
    shift

    on_terminal_hold 10 "$answer" env PROJECTS_DIR="$WORK/projects" CHECK_WAIT=10 RELEASE_WAIT=0 DEPLOY_RAILS=0 \
        "$ROOT/deploy" "$@" > "$WORK/ask.log" 2>&1 || { cat "$WORK/ask.log"; fail "deploy $* failed on a terminal"; }
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

    ask_run n fixture --force
    grep -qE -- "--force (rebuilds [0-9a-f]+, which $live already runs|deploys [0-9a-f]+): " "$WORK/ask.log" \
        || fail "deploy --force does not show the commit it rebuilds"
    grep -q "Nothing done" "$WORK/ask.log" || fail "deploy --force does not stop on n"
    [ "$(live_release)" = "$live" ] && [ "$(release_count)" = "$count" ] || fail "deploy --force built after n"
    [ -z "$(find "$BASE/releases" -maxdepth 1 -name '.building-*')" ] || fail "deploy --force left a .building folder after n"
    ask_run "" fixture --force --yes
    ! grep -q "\[y/N\]" "$WORK/ask.log" || fail "deploy --force --yes asked"
    [ "$(live_release)" != "$live" ] || fail "deploy --force --yes did not deploy"
    check "on a terminal rollback, down and deploy --force showed what they do and asked: n or empty did nothing, y went on, --yes did not ask; a pipe was not asked"
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
