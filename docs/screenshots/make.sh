#!/usr/bin/env bash
#
# Makes the README screenshots in docs/images/ from real runs of ./deploy. Builds a project named
# example from tests/fixture/ in a temp folder (like tests/run.sh), serves it with `php -S`, runs
# each command in a terminal (script(1)), then renders the output to SVG in a light and a dark
# theme with render.mjs. Needs bash, PHP 8.1+, git, curl and Node 18+. macOS script(1) flags.
#
#   docs/screenshots/make.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OUT="$ROOT/docs/images"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
PORT="${SCREENSHOT_PORT:-8172}"
SERVER_PID=""

# A home folder of its own, so the pictures show /home/example paths and no real ones.
FAKE_HOME="$WORK/home"
DOMAIN="$FAKE_HOME/domains/example.com"
REPO="$WORK/example.git"

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        pkill -P "$SERVER_PID" 2>/dev/null || true
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}

trap cleanup EXIT

if curl --silent --output /dev/null "http://127.0.0.1:$PORT/"; then
    printf 'port %s is in use; set SCREENSHOT_PORT\n' "$PORT" >&2
    exit 1
fi

# The engine at its newest release tag, cloned from a repo whose main is that tag, so the pictures
# show a clean version like v2026.11.59 and an engine with nothing newer to pull.
TAG="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*')"
git clone --quiet --bare "$ROOT" "$WORK/engine.git"
git -C "$WORK/engine.git" fetch --quiet --tags "$ROOT"
git -C "$WORK/engine.git" update-ref refs/heads/main "$TAG^{commit}"
git -C "$WORK/engine.git" symbolic-ref HEAD refs/heads/main
git clone --quiet "$WORK/engine.git" "$WORK/release-switch"

mkdir -p "$FAKE_HOME/bin" "$WORK/release-switch/projects"
printf '#!/bin/sh\necho "Composer version 2.8.0"\n' > "$FAKE_HOME/bin/composer"
chmod +x "$FAKE_HOME/bin/composer"

# Everything a command may print: no real user, host or path.
export HOME="$FAKE_HOME" USER=example LOGNAME=example TZ=UTC TERM=xterm-256color
export PATH="$FAKE_HOME/bin:$PATH"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=dev@example.com
export GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=dev@example.com
export RELEASE_WAIT=0 CHECK_WAIT=10
unset NO_COLOR DEPLOY_RAILS

ENGINE="$WORK/release-switch/deploy"

# A commit on a branch of the repo, with a release tag when $3 is set.
commit() {
    local branch="$1" message="$2" tag="${3:-}" tmp="$WORK/commit"
    rm -rf "$tmp"
    git clone --quiet "$REPO" "$tmp"
    git -C "$tmp" checkout --quiet -B "$branch" "origin/$branch" 2>/dev/null \
        || git -C "$tmp" checkout --quiet -b "$branch" origin/develop
    printf '%s\n' "$message" > "$tmp/VERSION"
    git -C "$tmp" commit --quiet -am "$message"
    git -C "$tmp" push --quiet origin "$branch"
    [ -z "$tag" ] || git -C "$tmp" push --quiet origin "HEAD:refs/tags/$tag"
}

# Runs ./deploy in a terminal 100 columns wide and keeps its output, escapes and all, in $1.ansi.
# Keys in $KEYS are typed after $KEYS_DELAY seconds, for the menu.
capture() {
    local name="$1"
    shift
    (
        [ -z "${KEYS:-}" ] || { sleep "${KEYS_DELAY:-5}"; printf '%s' "$KEYS"; sleep 1; }
    ) | script -q "$WORK/$name.raw" bash -c 'stty cols 100 rows 50; exec "$@"' bash "$ENGINE" "$@" \
        > /dev/null || true
    # The prompt line the command was typed on, then the output with local values made neutral.
    {
        printf '\033[2m$\033[0m deploy %s\n' "$*"
        sed -e "s#$FAKE_HOME#/home/example#g" \
            -e "s#http://s\([0-9]\)\.localhost:$PORT/#https://s\1.example.com/#g" \
            -e "s#http://127\.0\.0\.1:$PORT/#https://example.com/#g" \
            -e "s#file://$REPO#git@github.com:example/example.git#g" \
            -e 's/\x04//g; s/\^D\x08\x08//g' "$WORK/$name.raw"
    } > "$WORK/$name.ansi"
    if grep -E "$WORK|$PORT|/Users/|localhost" "$WORK/$name.ansi" >&2; then
        printf '%s: a local path or URL is left in the output\n' "$name" >&2
        exit 1
    fi
}

printf 'Building the example project\n'
mkdir -p "$WORK/src"
cp -R "$ROOT/tests/fixture/." "$WORK/src/"
git -C "$WORK/src" init --quiet -b develop
git -C "$WORK/src" add -A
git -C "$WORK/src" commit --quiet -m "First release"
git init --quiet --bare "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/develop
git -C "$WORK/src" push --quiet "$REPO" develop
git -C "$WORK/src" push --quiet "$REPO" "develop:refs/tags/v2026.11.4"

for folder in www s1 s2 s3; do
    mkdir -p "$DOMAIN/$folder/shared/data"
    printf 'APP_ENV=production\n' > "$DOMAIN/$folder/shared/.env"
    printf 'hello\n' > "$DOMAIN/$folder/shared/data/note.txt"
done

cat > "$WORK/release-switch/projects/example.env" <<EOF
DEPLOY_BASE="$DOMAIN/www"
CHECK_URL="http://127.0.0.1:$PORT/"
REPO_URL="file://$REPO"
COMPOSER_BIN=composer
STAGING_SERVERS=3
STAGING_URL="http://{slot}.localhost:$PORT/"
NOTIFY_CMD='printf "%s\\n" "\$NOTIFY_TEXT" >> "$WORK/alerts.log"'
EOF

# Serves production, or a slot for an sN. host, from its current/public.
cat > "$WORK/router.php" <<EOF
<?php
\$base = '$DOMAIN/www';
if (preg_match('/^(s[0-9]+)\\./', \$_SERVER['HTTP_HOST'] ?? '', \$m)) {
    \$base = '$DOMAIN/' . \$m[1];
}
// Before the first release, like a hosting placeholder page.
if (!is_dir("\$base/current/public")) {
    echo 'coming soon';
    return;
}
chdir("\$base/current/public");
require "\$base/current/public/index.php";
EOF
php -d realpath_cache_size=0 -S "127.0.0.1:$PORT" "$WORK/router.php" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 1

printf 'Capturing check --setup\n'
capture setup example check --setup

printf 'Deploying the first release and the slots\n'
"$ENGINE" example > /dev/null
commit feature/search "Search by city"
"$ENGINE" example@s1 --branch feature/search > /dev/null
commit fix/login "Fix the login redirect"
git -C "$WORK/commit" push --quiet origin "HEAD:refs/pull/51/head"
"$ENGINE" example@s2 --pr 51 > /dev/null

printf 'Capturing a deploy\n'
commit develop "Add the price filter"
commit develop "Faster search page" v2026.11.5
sleep 1
capture deploy example

printf 'Capturing slots\n'
capture slots example slots

printf 'Capturing the menu\n'
commit develop "Show prices in CAD"
commit develop "Cache the city list" v2026.11.6
commit feature/search "Search by airport"
KEYS=q capture menu

# SCREENSHOT_ANSI=<folder> keeps the raw captures there, for a look.
[ -z "${SCREENSHOT_ANSI:-}" ] || cp "$WORK"/*.ansi "$SCREENSHOT_ANSI/"

printf 'Rendering\n'
mkdir -p "$OUT"
for name in menu deploy setup slots; do
    node "$ROOT/docs/screenshots/render.mjs" "$WORK/$name.ansi" "$OUT/$name"
done
ls -l "$OUT"
