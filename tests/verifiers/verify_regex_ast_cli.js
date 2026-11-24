'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const executable = process.platform === 'win32' ? 'kessel.exe' : 'kessel';
const binary = path.resolve(__dirname, '../../bin', executable);

function regexp(pattern, flags) {
  return spawnSync(binary, ['regexp', pattern, '--flags', flags], { encoding: 'utf8' });
}

const pattern = String.raw`(?<name>π+)\k<name>`;
const result = regexp(pattern, 'u');
assert.equal(result.status, 0, result.stderr || String(result.error));
const tree = JSON.parse(result.stdout);
const bytes = Buffer.from(pattern);
const root = tree.nodes[tree.root];
const alternative = tree.nodes[root.first_child];
const group = tree.nodes[alternative.first_child];
const reference = tree.nodes[group.next_sibling];
assert.equal(root.kind, 'Pattern');
assert.equal(root.span.end, bytes.length);
assert.equal(tree.capture_count, 1);
assert.equal(group.group_kind, 'Named_Capture');
assert.equal(reference.kind, 'Named_Reference');
assert.equal(bytes.subarray(reference.name.start, reference.name.end).toString(), 'name');

const invalid = regexp('[a-z&&a]', 'v');
assert.equal(invalid.status, 1);
assert.match(invalid.stderr, /Invalid_Pattern/);
const flags = regexp('a', 'uv');
assert.equal(flags.status, 1);
assert.match(flags.stderr, /Invalid_Flags/);
console.log('Regexp CLI passed tree, UTF-8 span, and diagnostic checks');
