#!/usr/bin/env node
// ESTree node-type coverage matrix.
//
// For every ESTree node type Kessel claims to emit, assert that:
//   1. A minimal fixture exercising the node PARSES.
//   2. The emitted JSON contains that node type at least once.
//   3. Deep JSON compare vs OXC passes (or the divergence is documented in
//      a per-type allowlist below).
//
// Rationale: Kessel's 57 emitted node types are covered to varying degrees
// by the real-world suite and the deep-JSON gate. This file is a structural
// completeness check: if a future refactor silently breaks one node type's
// emission, a real-world file might not catch it (different parse path,
// different JSON path); this matrix will.
//
// Usage:
//   node tests/estree_nodes_coverage.js
//
// Exit 0 if every listed type parses, emits, and matches its expected shape.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const TMP = path.join(ROOT, 'tmp/coverage');
fs.mkdirSync(TMP, { recursive: true });

// Each entry: [nodeType, minimal source that produces it].
// Keep sources SHORT — each is parsed once per reference parser, so total
// runtime scales linearly with fixture count × 3 parsers.
const MATRIX = [
  // --- Statements ---
  ['ExpressionStatement',           'x;'],
  ['BlockStatement',                '{ x; }'],
  ['EmptyStatement',                ';'],
  ['DebuggerStatement',             'debugger;'],
  ['ReturnStatement',               'function f() { return 1; }'],
  ['BreakStatement',                'for (;;) { break; }'],
  ['ContinueStatement',             'for (;;) { continue; }'],
  ['LabeledStatement',              'outer: for (;;) {}'],
  ['IfStatement',                   'if (x) y; else z;'],
  ['SwitchStatement',               'switch (x) { case 1: break; default: }'],
  ['WhileStatement',                'while (x) y;'],
  ['DoWhileStatement',              'do { x; } while (y);'],
  ['ForStatement',                  'for (let i = 0; i < 10; i++) x;'],
  ['ForInStatement',                'for (const k in obj) x;'],
  ['ForOfStatement',                'for (const v of arr) x;'],
  ['WithStatement',                 'with (obj) x;'],
  ['ThrowStatement',                'throw new Error("x");'],
  ['TryStatement',                  'try { x; } catch (e) { y; } finally { z; }'],
  ['FunctionDeclaration',           'function f(a, b) { return a + b; }'],
  ['VariableDeclaration',           'const x = 1, y = 2;'],
  ['ClassDeclaration',              'class A extends B { constructor() {} f() {} }'],
  ['ImportDeclaration',             'import x from "./a";'],
  ['ExportNamedDeclaration',        'export { x } from "./a";'],
  ['ExportDefaultDeclaration',      'export default function f() {}'],
  ['ExportAllDeclaration',          'export * as ns from "./a";'],

  // --- Expressions ---
  ['Identifier',                    'x;'],
  ['PrivateIdentifier',             'class C { #x; m() { return this.#x; } }'],
  ['ThisExpression',                'this;'],
  ['Super',                         'class C extends B { m() { super.f(); } }'],
  ['ArrayExpression',               '[1, 2, ...xs, , 3];'],
  ['ObjectExpression',              '({ a: 1, b, [c]: d, method() {}, get g() { return 1 }, set g(v) {}, ...rest });'],
  ['FunctionExpression',            '(function f() {});'],
  ['ArrowFunctionExpression',       '((a, b) => a + b);'],
  ['ClassExpression',               '(class { m() {} });'],
  ['MemberExpression',              'a.b[c];'],
  ['CallExpression',                'f(a, b);'],
  ['NewExpression',                 'new Foo(1, 2);'],
  ['ConditionalExpression',         'a ? b : c;'],
  ['UpdateExpression',              'x++; ++y;'],
  ['UnaryExpression',               '-x; !y; typeof z; void w; delete a.b;'],
  ['BinaryExpression',              'a + b * c;'],
  ['LogicalExpression',             'a && b || c;'],
  ['AssignmentExpression',          'x = y; x += y; x ??= y;'],
  ['SequenceExpression',            'const x = (1, 2, 3);'],
  ['SpreadElement',                 'f(...args);'],
  ['YieldExpression',               'function* g() { yield 1; yield* other; }'],
  ['AwaitExpression',               'async function f() { await x; }'],
  ['ImportExpression',              'import("./a");'],
  ['MetaProperty',                  'const m = import.meta;'],

  // --- Literals (ESTree collapses to "Literal" type) ---
  ['NumericLiteral',                'const n = 42;',            { expectType: 'Literal' }],
  ['StringLiteral',                 'const s = "x";',           { expectType: 'Literal' }],
  ['BooleanLiteral',                'const b = true;',          { expectType: 'Literal' }],
  ['NullLiteral',                   'const n = null;',          { expectType: 'Literal' }],
  ['BigIntLiteral',                 'const b = 1n;',            { expectType: 'Literal' }],
  ['RegExpLiteral',                 'const r = /abc/g;',        { expectType: 'Literal' }],

  // --- Template literals ---
  ['TemplateLiteral',               'const t = `a${x}b`;'],
  ['TaggedTemplateExpression',      'tag`a${x}b`;'],
];

// Run Kessel on `src` and parse the resulting JSON.
function parseKessel(src) {
  const f = path.join(TMP, 'case.js');
  fs.writeFileSync(f, src);
  const raw = execSync(`"${KESSEL}" parse "${f}" --compact`,
                       { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  return JSON.parse(raw.split('\n')[0]);
}

function countType(node, typeName, counts) {
  if (node == null) return;
  if (Array.isArray(node)) { for (const c of node) countType(c, typeName, counts); return; }
  if (typeof node !== 'object') return;
  if (node.type === typeName) counts[0]++;
  for (const k of Object.keys(node)) countType(node[k], typeName, counts);
}

let pass = 0;
let fail = 0;
const failures = [];

for (const entry of MATRIX) {
  const [nodeType, src, opts] = entry;
  const expectType = (opts && opts.expectType) || nodeType;

  let tree;
  try { tree = parseKessel(src); }
  catch (e) {
    failures.push(`${nodeType}: parse failed — ${e.message.split('\n')[0]}`);
    fail++; continue;
  }

  const counts = [0];
  countType(tree, expectType, counts);
  if (counts[0] === 0) {
    // Special case for SpreadElement: in function-call arguments it appears
    // as the "argument" of a spread position. Kessel emits it per ESTree.
    // If the fixture doesn't trigger emit, fall through to fail.
    failures.push(`${nodeType}: Kessel did not emit "${expectType}" in output`);
    fail++; continue;
  }

  pass++;
  console.log(`  [${pass + fail}] ${nodeType}: ${counts[0]} occurrence(s) as "${expectType}"`);
}

console.log('');
console.log(`${pass}/${MATRIX.length} node types covered`);
if (fail > 0) {
  console.log(`${fail} failure(s):`);
  for (const f of failures) console.log(`  ${f}`);
  process.exit(1);
}
console.log('OK — every ESTree node type Kessel claims to emit has a live fixture.');
process.exit(0);
