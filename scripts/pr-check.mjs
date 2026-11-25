// Checks a pull request against the repo rules: title, one release label, an assignee and the body
// sections. Dependabot pull requests skip the title and body rules. The PR rules workflow runs it on
// every pull request into main; run it by hand with:
//   PR=<N> GITHUB_REPOSITORY=ivan-tarasov/release-switch node scripts/pr-check.mjs
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const RELEASE_LABELS = ['release:major', 'release:minor', 'release:patch', 'no-release'];

const TITLE = /^(?:Fix|Update|Feature|Design): `[^`]+` – \S/;

// The workflow passes `dependabot[bot]`; `gh pr view` reports `app/dependabot`.
const BOTS = ['dependabot[bot]', 'app/dependabot'];

// The text under a "## Name" heading, up to the next "## " heading, or null when there is none.
export function section(body, name) {
    const lines = (body ?? '').replace(/\r\n/g, '\n').split('\n');
    const start = lines.findIndex(line => line.trim().toLowerCase() === `## ${name.toLowerCase()}`);
    if (start === -1) {
        return null;
    }
    const rest = lines.slice(start + 1);
    const end = rest.findIndex(line => /^##\s/.test(line));

    return (end === -1 ? rest : rest.slice(0, end)).join('\n').trim();
}

export function countSentences(text) {
    return text.split(/(?<=[.!?])\s+/).filter(part => /[\p{L}\p{N}]/u.test(part)).length;
}

export function checkPullRequest({ title, body, labels = [], assignees = [], author }) {
    const errors = [];
    const isBot = BOTS.includes(author);

    if (!isBot && !TITLE.test(title ?? '')) {
        errors.push('The title must look like "Fix: `Component` – short phrase". Kinds: Fix, Update, Feature, Design.');
    }

    const release = labels.map(label => label.name).filter(name => RELEASE_LABELS.includes(name));
    if (release.length !== 1) {
        errors.push(`Add exactly one release label: ${RELEASE_LABELS.join(', ')}. Found ${release.length === 0 ? 'none' : release.join(', ')}.`);
    }

    if (assignees.length === 0) {
        errors.push('Add an assignee.');
    }

    if (isBot) {
        return errors;
    }

    if (!section(body, 'Description')) {
        errors.push('Add a "## Description" section.');
    }

    const note = section(body, 'Release note');
    if (!note) {
        errors.push('Add a "## Release note" section: 1–3 sentences, or "None".');
    } else if (!/^none\.?$/i.test(note)) {
        const count = countSentences(note);
        if (count === 0) {
            errors.push('The Release note has no sentence. Write 1–3 sentences, or "None".');
        } else if (count > 3) {
            errors.push(`The Release note has ${count} sentences. Keep it to 1–3, or write "None".`);
        }
    }

    if (!section(body, 'Changes')) {
        errors.push('Add a "## Changes" section.');
    }

    return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const { PR, GITHUB_REPOSITORY: repo, GITHUB_ACTIONS, AUTHOR } = process.env;
    if (!PR || !repo) {
        console.error('PR and GITHUB_REPOSITORY are required.');
        process.exit(2);
    }

    const read = () => {
        const pullRequest = JSON.parse(execFileSync(
            'gh',
            ['pr', 'view', PR, '--repo', repo, '--json', 'title,body,labels,assignees,author'],
            { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
        ));

        return { ...pullRequest, author: AUTHOR || pullRequest.author?.login };
    };

    // `gh pr create` adds labels and assignees a moment after the PR opens, so the workflow reads again.
    let errors = checkPullRequest(read());
    for (let attempt = 1; GITHUB_ACTIONS && errors.length > 0 && attempt < 3; attempt += 1) {
        console.log(`Not ready yet, reading again in 5s (${attempt} of 2).`);
        execFileSync('sleep', ['5']);
        errors = checkPullRequest(read());
    }

    for (const error of errors) {
        console.log(GITHUB_ACTIONS ? `::error::${error}` : `✗ ${error}`);
    }
    if (errors.length > 0) {
        process.exit(1);
    }
    console.log('The pull request follows the repo rules.');
}
