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

// Modifier flags are bit masks in d, g, i, m, s, u, v, y order, like the tree's flags.
const modifiers = regexp('(?i-m:[a&&b])', 'v');
assert.equal(modifiers.status, 0, modifiers.stderr || String(modifiers.error));
const modified = JSON.parse(modifiers.stdout);
const modifierGroup = modified.nodes.find(node => node.group_kind === 'Modifiers');
assert.deepEqual(modifierGroup.modifiers, { add: 1 << 2, remove: 1 << 3 });
assert.equal(modified.nodes.find(node => node.kind === 'Character_Class').class_relation,
  'Intersection');
assert.deepEqual(group.modifiers, { add: 0, remove: 0 });
assert.equal(group.class_relation, 'Union');

// The builder is strict where the parser's validator is lenient.
const unknownScript = regexp(String.raw`\p{Script=NotAScript}`, 'u');
assert.equal(unknownScript.status, 1);
assert.match(unknownScript.stderr, /Invalid_Pattern at byte 0/);

const invalid = regexp('[a-z&&a]', 'v');
assert.equal(invalid.status, 1);
assert.match(invalid.stderr, /Invalid_Pattern/);
const flags = regexp('a', 'uv');
assert.equal(flags.status, 1);
assert.match(flags.stderr, /Invalid_Flags/);
console.log('Regexp CLI passed tree, UTF-8 span, modifier, and diagnostic checks');
