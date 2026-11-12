// Tags a merge into main and makes a GitHub release with generated notes. The Release workflow
// runs it; by hand:
//   MERGE_SHA=<sha> MERGED_AT=<ISO date> GITHUB_REPOSITORY=ivan-tarasov/release-switch node scripts/release-tag.mjs
// The version is vYEAR.MONTH.COUNT: year and month of the merge in UTC, COUNT is the release of
// that month, from 1.
import { execFileSync } from 'node:child_process';

const TAGS = 'v[0-9]*.[0-9]*.[0-9]*';

const parts = tag => tag.slice(1).split('.').map(Number);

export function compareVersions(a, b) {
    const [left, right] = [parts(a), parts(b)];
    for (let index = 0; index < 3; index += 1) {
        const difference = (left[index] ?? 0) - (right[index] ?? 0);
        if (difference !== 0) {
            return difference;
        }
    }

    return 0;
}

export function nextVersion(tags, date) {
    const prefix = `v${date.getUTCFullYear()}.${date.getUTCMonth() + 1}.`;
    const counts = tags
        .filter(tag => tag.startsWith(prefix))
        .map(tag => Number(tag.slice(prefix.length)))
        .filter(Number.isInteger);

    return `${prefix}${counts.length === 0 ? 1 : Math.max(...counts) + 1}`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const { MERGE_SHA: sha, MERGED_AT: mergedAt, GITHUB_REPOSITORY: repo } = process.env;
    if (!sha || !mergedAt || !repo) {
        console.error('MERGE_SHA, MERGED_AT and GITHUB_REPOSITORY are required.');
        process.exit(2);
    }

    const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
    const lines = output => output.split('\n').filter(Boolean);

    // A re-run of the same merge must not make a second tag.
    const own = lines(run('git', ['tag', '--points-at', sha, '--list', TAGS]));
    if (own.length > 0) {
        console.log(`${sha.slice(0, 7)} is already tagged ${own.join(', ')}.`);
        process.exit(0);
    }

    const tags = lines(run('git', ['tag', '--list', TAGS]));
    const tag = nextVersion(tags, new Date(mergedAt));
    const previous = [...tags].sort(compareVersions).at(-1);

    const args = ['release', 'create', tag, '--repo', repo, '--target', sha, '--title', tag, '--generate-notes'];
    if (previous) {
        args.push('--notes-start-tag', previous);
    }
    run('gh', args);
    console.log(`Released ${tag} on ${sha.slice(0, 7)}.`);
}
