// Run with: node --test scripts/pr-check.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkPullRequest } from './pr-check.mjs';

const body = '## Description\nWhy.\n\n## Changes\n1. What.\n\n## Release note\nNone';

const person = {
    title: 'Update: `CI` – weekly dependency PRs',
    body,
    labels: [{ name: 'no-release' }],
    assignees: [{ login: 'ivan-tarasov' }],
    author: 'ivan-tarasov',
};

const dependabot = {
    title: 'Bump vite from 8.3.5 to 8.4.0',
    body: 'Bumps vite from 8.3.5 to 8.4.0.',
    labels: [{ name: 'release:patch' }],
    assignees: [{ login: 'ivan-tarasov' }],
    author: 'dependabot[bot]',
};

test('a pull request that follows the rules passes', () => {
    assert.deepEqual(checkPullRequest(person), []);
});

test('a person still needs the title and body format', () => {
    const errors = checkPullRequest({ ...person, title: 'Bump vite', body: '' });

    assert.equal(errors.length, 4);
    assert.match(errors[0], /title/);
});

test('a person with a bot-like title and body fails', () => {
    assert.notDeepEqual(checkPullRequest({ ...dependabot, author: 'ivan-tarasov' }), []);
});

test('Dependabot skips the title and body rules', () => {
    assert.deepEqual(checkPullRequest(dependabot), []);
    assert.deepEqual(checkPullRequest({ ...dependabot, author: 'app/dependabot' }), []);
});

test('Dependabot still needs exactly one release label', () => {
    assert.match(checkPullRequest({ ...dependabot, labels: [] })[0], /release label/);
    assert.match(
        checkPullRequest({ ...dependabot, labels: [{ name: 'release:patch' }, { name: 'no-release' }] })[0],
        /release label/,
    );
});

test('Dependabot still needs an assignee', () => {
    assert.deepEqual(checkPullRequest({ ...dependabot, assignees: [] }), ['Add an assignee.']);
});
