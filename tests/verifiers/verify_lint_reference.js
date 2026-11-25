'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { oxlint_npm: version } = require('../../OXC_ORACLE.json');

const args = process.argv.slice(2);
const upstream = args.includes('--upstream');
const corpus = args.includes('--corpus');
const paths = args.filter(arg => arg !== '--upstream' && arg !== '--corpus');
assert.ok(paths.length <= 1 && !paths[0]?.startsWith('--'), 'Expected [oxlint executable] [--upstream] [--corpus]');
const oracle = paths[0] ? path.resolve(paths[0]) : 'oxlint';
const binary = path.join(__dirname, '../../bin', process.platform === 'win32' ? 'kessel.exe' : 'kessel');
assert.equal(execFileSync(oracle, ['--version'], { encoding: 'utf8' }).trim(), 'Version: ' + version);
for (const suite of ['config', 'fixes', 'bindings', 'flow', 'prefer_const', 'react_hooks']) {
  const verifier = path.join(__dirname, 'verify_lint_' + suite + '.js');
  execFileSync(process.execPath, [verifier, binary, oracle], { stdio: 'inherit' });
}
if (upstream) {
  const verifier = path.join(__dirname, 'compare_lint_hook_fixtures.js');
  execFileSync(process.execPath, [verifier, binary, oracle], { stdio: 'inherit' });
}
if (corpus) {
  const verifier = path.join(__dirname, 'compare_lint_flow_corpus.js');
  execFileSync(process.execPath, [verifier, binary, oracle], { stdio: 'inherit' });
}
// Every rule recorded in tests/lint/upstream_parity.json must reproduce its numbers.
if (upstream || corpus) {
  const verifier = path.join(__dirname, 'compare_lint_rule_fixtures.js');
  const flags = [...(corpus ? ['--corpus'] : []), ...(upstream ? [] : ['--no-fixtures'])];
  execFileSync(process.execPath, [verifier, binary, oracle, ...flags], { stdio: 'inherit' });
}
