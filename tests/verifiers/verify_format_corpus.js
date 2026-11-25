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

// The formatter may change how a program is spelled but never what it means.
// The comparison therefore ignores exactly the spellings that Prettier
// normalises: positions, literal text, redundant parentheses, stray empty
// statements, the order of regular expression flags and the quoting of
// property names.
const STATEMENT_LISTS = { Program: 'body', BlockStatement: 'body', StaticBlock: 'body', SwitchCase: 'consequent' };

function syntaxField(key, node) {
  if (key === 'start' || key === 'end') return undefined;
  // A string literal can change its delimiters. A tagged template can observe
  // the raw spelling of its elements, so keep those strings in the comparison.
  if (key === 'raw' && this.type === 'Literal') return undefined;
  if (typeof node === 'bigint') return String(node);
  // Comments keep their text, apart from the whitespace that Prettier
  // normalises: line endings, spaces at the end of a line comment, and the
  // indentation of a block comment whose lines all start with `*`, which is
  // re-indented with the code around it.
  if (node?.type === 'Line' && typeof node.value === 'string') {
    return { ...node, value: node.value.trimEnd() };
  }
  if (node?.type === 'Block' && typeof node.value === 'string') {
    const lines = node.value.replace(/\r\n?/g, '\n').split('\n');
    const aligned = lines.length > 1 && lines.slice(1).every((line, index) =>
      line.trimStart().startsWith('*') || (index === lines.length - 2 && line.trim() === ''));
    return { ...node, value: (aligned ? lines.map(line => line.trim()) : lines).join('\n') };
  }
  if (key === 'regex' && node && typeof node.flags === 'string') {
    return { ...node, flags: [...node.flags].sort().join('') };
  }
  // A `;` on its own in a statement list does nothing, and Prettier drops it.
  // An empty statement that is the body of a loop or branch stays compared.
  const list = node && STATEMENT_LISTS[node.type];
  if (list && node[list].some(statement => statement.type === 'EmptyStatement')) {
    return { ...node, [list]: node[list].filter(statement => statement.type !== 'EmptyStatement') };
  }
  // Quoted and unquoted property names can refer to the same key. Keep computed
  // keys, shorthand and methods distinct because they can change evaluation.
  if (node?.type !== 'Property' && node?.type !== 'ImportAttribute') return node;
  if (node.computed || node.shorthand || node.method) return node;
  if (node.key.type === 'Identifier') return { ...node, key: node.key.name };
  if (typeof node.key.value === 'string') return { ...node, key: node.key.value };
  // `{ "1": a }` and `{ 1: a }` name the same property.
  if (typeof node.key.value === 'number') return { ...node, key: String(node.key.value) };
  return node;
}

// Parentheses that only group are not part of the tree, so the parser is
// asked not to record them on either side. Everything else is compared
// exactly, so a change that regroups operands is a different tree. The
// self-test below proves that.
function syntaxDigest(filename, source) {
  const { program, comments, errors } = parseSync(filename, source, { preserveParens: false });
  assert.deepEqual(errors, [], filename);
  return checksum(JSON.stringify([program, comments], syntaxField));
}

// The comparison is only worth something if it fails when meaning changes.
// Each pair below differs in grouping, in a statement or in a comment and
// must produce different digests. Each allowed respelling must not.
function selfTest() {
  const different = [
    ['a - (b - c);', 'a - b - c;'],
    ['(a + b) * c;', 'a + b * c;'],
    ['a || (b && c);', '(a || b) && c;'],
    ['a || (b || c);', 'a || b || c;'],
    ['(a?.b).c;', 'a?.b.c;'],
    ['(a, b);', 'a; b;'],
    ['f((a, b));', 'f(a, b);'],
    ['a(); b();', 'a();'],
    ['if (a) ; else b();', 'if (a) b();'],
    ['for (;;) ;', 'for (;;) {}'],
    ['a(); // note', 'a();'],
    ['a(); // note', 'a(); // other'],
    ['/* one */ a();', '// one\na();'],
    ['/*\n * kept\n */ a();', '/*\n * changed\n */ a();'],
    ['/* a  b */ c();', '/* a b */ c();'],
    ['({ [a]: 1 });', '({ a: 1 });'],
    ['({ a() {} });', '({ a: function () {} });'],
    ['/a/g;', '/a/i;'],
    ['1;', '2;'],
    ['"a";', '"b";'],
    ['`a`;', '`a `;'],
  ];
  for (const [before, after] of different) {
    assert.notEqual(syntaxDigest('self.js', before), syntaxDigest('self.js', after), before + ' vs ' + after);
  }
  const same = [
    ['((a)) + (b);', 'a + b;'],
    ['a - (b * c);', 'a - b * c;'],
    ['a();;', 'a();'],
    ['/a/gi;', '/a/ig;'],
    ['({ "a": 1, "2": 3 });', '({ a: 1, 2: 3 });'],
    ["'a';", '"a";'],
    ['0XFF;', '0xff;'],
    ['a(); // note  ', 'a(); // note'],
    ['    /**\n       * Doc.\n       */\na();', '/**\n * Doc.\n */\na();'],
  ];
  for (const [before, after] of same) {
    assert.equal(syntaxDigest('self.js', before), syntaxDigest('self.js', after), before + ' vs ' + after);
  }
}

selfTest();
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
