// Run with: node --test scripts/release-tag.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { compareVersions, nextVersion } from './release-tag.mjs';

const november = new Date('2026-11-24T12:00:00Z');

test('the first release of a month is COUNT 1', () => {
    assert.equal(nextVersion([], november), 'v2026.11.1');
    assert.equal(nextVersion(['v2026.10.1', 'v2026.10.7'], november), 'v2026.11.1');
});

test('the next release of a month counts up from the highest', () => {
    assert.equal(nextVersion(['v2026.11.1', 'v2026.11.10', 'v2026.11.9'], november), 'v2026.11.11');
});

test('a new month starts again at 1', () => {
    assert.equal(nextVersion(['v2026.11.46'], new Date('2026-12-01T00:00:00Z')), 'v2026.12.1');
    assert.equal(nextVersion(['v2026.12.3'], new Date('2027-01-01T00:00:00Z')), 'v2027.1.1');
});

test('the month comes from the UTC date', () => {
    assert.equal(nextVersion(['v2026.11.46'], new Date('2026-11-30T23:30:00-05:00')), 'v2026.12.1');
});

test('January tags do not count for November', () => {
    assert.equal(nextVersion(['v2026.1.5', 'v2026.1.12'], november), 'v2026.11.1');
    assert.equal(nextVersion(['v2026.11.2', 'v2026.1.15'], new Date('2026-01-31T12:00:00Z')), 'v2026.1.16');
});

test('tags that are not versions are ignored', () => {
    assert.equal(nextVersion(['v2026.11.x', 'v2026.11.', 'v2026.11.2-rc', 'v2026.11.1.5', 'latest'], november), 'v2026.11.1');
    assert.equal(nextVersion(['v2026.11.3', 'v2026.11.beta'], november), 'v2026.11.4');
});

test('versions compare by number, not by text', () => {
    assert.ok(compareVersions('v2026.11.1', 'v2026.1.9') > 0);
    assert.ok(compareVersions('v2026.1.9', 'v2026.11.1') < 0);
    assert.ok(compareVersions('v2026.11.10', 'v2026.11.9') > 0);
    assert.ok(compareVersions('v2027.1.1', 'v2026.12.40') > 0);
    assert.equal(compareVersions('v2026.11.3', 'v2026.11.3'), 0);
});

test('sorting picks the newest version as the last one', () => {
    const tags = ['v2026.11.2', 'v2026.1.15', 'v2026.11.10', 'v2025.12.4', 'v2026.2.1'];

    assert.deepEqual([...tags].sort(compareVersions), ['v2025.12.4', 'v2026.1.15', 'v2026.2.1', 'v2026.11.2', 'v2026.11.10']);
});
