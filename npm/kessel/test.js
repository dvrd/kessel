#!/usr/bin/env node
/**
 * Smoke test for the kessel npm package.
 */

'use strict';
const { parseSync } = require('./index');

const tests = [
  ['const x = 1;', 'VariableDeclaration'],
  ['function add(a, b) { return a + b; }', 'FunctionDeclaration'],
  ['class Foo {}', 'ClassDeclaration'],
  ['import { x } from "y";', 'ImportDeclaration'],
  ['export default 42;', 'ExportDefaultDeclaration'],
  ['const el = <div/>;', 'VariableDeclaration'],  // JSX (lang auto-detect won't help for .js)
];

let passed = 0;
let failed = 0;

for (const [source, expectedType] of tests) {
  try {
    const { program, errors } = parseSync('test.js', source);
    const actualType = program.body[0]?.type;
    if (actualType === expectedType) {
      passed++;
    } else {
      console.error(`FAIL: "${source}" → ${actualType} (expected ${expectedType})`);
      failed++;
    }
  } catch (e) {
    console.error(`CRASH: "${source}" → ${e.message}`);
    failed++;
  }
}

// TypeScript
try {
  const { program } = parseSync('test.ts', 'const x: number = 1;');
  if (program.body[0]?.type === 'VariableDeclaration') passed++;
  else { console.error('FAIL: TS parse'); failed++; }
} catch (e) { console.error('CRASH: TS', e.message); failed++; }

// JSX explicit
try {
  const { program } = parseSync('test.jsx', 'const el = <div className="a">hi</div>;');
  if (program.body[0]?.type === 'VariableDeclaration') passed++;
  else { console.error('FAIL: JSX parse'); failed++; }
} catch (e) { console.error('CRASH: JSX', e.message); failed++; }

// Valid input must yield zero errors.
try {
  const { errors } = parseSync('clean.js', 'const x = 1;');
  if (errors.length === 0) passed++;
  else { console.error('FAIL: clean input produced errors:', errors); failed++; }
} catch (e) { console.error('CRASH: clean errors check', e.message); failed++; }

// Invalid input must yield non-empty errors[] with the documented shape
// { message, start, end }. Regression test for the bug where the FFI
// binary buffer didn't carry parser errors at all — every invalid input
// silently returned errors: [].
const badCases = [
  ['malformed assign',    'const = }'],
  ['unterminated string', 'const x = "hello'],
  ['missing paren in if', 'if (true'],
];
for (const [name, src] of badCases) {
  try {
    const { errors } = parseSync('bad.js', src);
    if (errors.length === 0) {
      console.error(`FAIL: invalid input ('${name}') produced 0 errors`);
      failed++;
      continue;
    }
    const e0 = errors[0];
    if (typeof e0.message !== 'string' || typeof e0.start !== 'number' || typeof e0.end !== 'number') {
      console.error(`FAIL: error shape wrong for '${name}':`, e0);
      failed++;
      continue;
    }
    passed++;
  } catch (err) {
    console.error(`CRASH: '${name}':`, err.message);
    failed++;
  }
}

console.log(`kessel npm test: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
