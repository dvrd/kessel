'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, rmSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { registryVersion, releaseBump, nextVersion } = require('../../scripts/next_release_version');

assert.equal(registryVersion({ status: 0, stdout: '"0.21.0"\n' }), '0.21.0');
assert.equal(registryVersion({ status: 1, stdout: '{"error":{"code":"E404"}}' }), '0.1.0');
for (const code of ['E401', 'E403', 'E429', 'E500', 'ENOTFOUND', 'ETIMEDOUT', 'ENOTCACHED']) {
  assert.throws(() => registryVersion({ status: 1, stdout: JSON.stringify({ error: { code } }) }), new RegExp(code));
}
for (const stdout of ['', 'not json', 'null', '""', '"1.2"', '"01.2.3"', '"0.21.0\u005cnversion=2"']) {
  assert.throws(() => registryVersion({ status: 0, stdout }));
}
assert.throws(() => registryVersion({ status: 1, stdout: '"0.21.0"' }));
assert.throws(() => registryVersion({ status: null, signal: 'SIGTERM', stdout: '{"error":{"code":"E404"}}' }));
assert.throws(() => registryVersion({ error: new Error('npm missing') }), /npm missing/);

const repo = mkdtempSync(path.join(os.tmpdir(), 'kessel-release-version-'));
try {
  const git = (...args) => execFileSync('git', ['-c', 'user.name=Kessel Test', '-c', 'user.email=test@example.invalid',
    '-c', 'commit.gpgSign=false', '-c', 'tag.gpgSign=false', ...args], { cwd: repo, stdio: 'pipe' });
  const commit = (...messages) => git('commit', '--allow-empty', ...messages.flatMap(message => ['-m', message]));
  git('init', '--quiet');
  commit('fix: initial parser fix');
  assert.equal(nextVersion('0.1.0', releaseBump(repo)), '0.1.1');
  commit('feat(parser): add syntax', 'Ordinary prose about a BREAKING CHANGE is documentation.');
  commit('fix: correct a token');
  assert.equal(nextVersion('0.21.0', releaseBump(repo)), '0.22.0');
  commit('refactor(parser)!: replace tree format');
  // Before 1.0.0 a breaking change raises the minor version, not the major.
  assert.equal(releaseBump(repo), 'major');
  assert.equal(nextVersion('0.21.0', releaseBump(repo)), '0.22.0');
  assert.equal(nextVersion('0.21.3', 'patch'), '0.21.4');
  // From 1.0.0 on, the usual rules apply.
  assert.equal(nextVersion('1.4.2', releaseBump(repo)), '2.0.0');
  git('tag', 'v1.0.0');
  commit('fix: preserve output', 'feat: this line describes an older feature');
  assert.equal(nextVersion('1.0.0', releaseBump(repo)), '1.0.1');
  commit('fix: remove an obsolete entry point', 'The new loader replaces it.\n\nBREAKING CHANGE: remove the old import');
  assert.equal(nextVersion('1.0.0', releaseBump(repo)), '2.0.0');
  git('tag', 'v2.0.0');
  commit('refactor: adjust the API', 'BREAKING-CHANGE: change the argument order');
  assert.equal(nextVersion('2.0.0', releaseBump(repo)), '3.0.0');
  console.log('Release version checks passed for npm responses, tagged history, commit subjects and breaking-change footers.');
} finally {
  rmSync(repo, { recursive: true, force: true });
}
