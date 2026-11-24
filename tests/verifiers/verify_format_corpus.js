'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');
const { readChecksums, checksum } = require('./verify_real_world_inputs');
const { formatSync } = require('../../npm/kessel');
const { oxc_parser_npm } = require('../../OXC_ORACLE.json');

const root = path.resolve(__dirname, '../..');
const bench = createRequire(path.join(root, 'bench/package.json'));
const { parseSync } = bench('oxc-parser');
const corpus = path.resolve(root, process.env.KESSEL_REAL_WORLD_ROOT || 'bench/real_world');

// Quoted and unquoted property names can refer to the same key. Keep computed
// keys, shorthand and methods distinct because they can change evaluation.
function syntaxField(key, node) {
  if (key === 'start' || key === 'end') return undefined;
  // A string literal can change its delimiters. A tagged template can observe
  // the raw spelling of its elements, so keep those strings in the comparison.
  if (key === 'raw' && this.type === 'Literal') return undefined;
  if (typeof node === 'bigint') return String(node);
  if (node?.type !== 'Property' && node?.type !== 'ImportAttribute') return node;
  if (node.computed || node.shorthand || node.method) return node;
  if (node.key.type === 'Identifier') return { ...node, key: node.key.name };
  if (typeof node.key.value === 'string') return { ...node, key: node.key.value };
  return node;
}

function syntaxDigest(filename, source) {
  const { program, comments, errors } = parseSync(filename, source, { preserveParens: true });
  assert.deepEqual(errors, [], filename);
  return checksum(JSON.stringify([program, comments], syntaxField));
}

assert.equal(bench('oxc-parser/package.json').version, oxc_parser_npm);
const files = readChecksums();
let changed = 0;
for (const filename of files.keys()) {
  const source = readFileSync(path.join(corpus, filename), 'utf8');
  const output = formatSync(filename, source);
  if (output === source) continue;
  assert.ok(formatSync(filename, output) === output, filename + ' changed on its second formatting pass');
  assert.equal(syntaxDigest(filename, source), syntaxDigest(filename, output), filename + ' changed syntax or comments');
  changed++;
}
console.log(`Formatter checked ${files.size} files. All ${changed} changed files retained their syntax and comments and formatted identically twice.`);
