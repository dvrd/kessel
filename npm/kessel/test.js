#!/usr/bin/env node
/**
 * Smoke test for the kessel npm package.
 *
 * DEBUG VERSION — prints checkpoints to stderr so we can locate
 * where the v0.4.0 x86_64 segfault occurs in CI. stderr is
 * unbuffered, so any output up to the crash will be flushed.
 */

'use strict';

const log = (msg) => process.stderr.write('[CHK] ' + msg + '\n');

log('start');
const { parseSync } = require('./index');
log('after require index');

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

let ti = 0;
for (const [source, expectedType] of tests) {
  log('basic test #' + ti + ': ' + JSON.stringify(source).slice(0, 40));
  ti++;
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
log('after basic tests');

// TypeScript
log('ts test');
try {
  const { program } = parseSync('test.ts', 'const x: number = 1;');
  if (program.body[0]?.type === 'VariableDeclaration') passed++;
  else { console.error('FAIL: TS parse'); failed++; }
} catch (e) { console.error('CRASH: TS', e.message); failed++; }

// JSX explicit
log('jsx test');
try {
  const { program } = parseSync('test.jsx', 'const el = <div className="a">hi</div>;');
  if (program.body[0]?.type === 'VariableDeclaration') passed++;
  else { console.error('FAIL: JSX parse'); failed++; }
} catch (e) { console.error('CRASH: JSX', e.message); failed++; }

// Valid input must yield zero errors.
log('clean errors test');
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
let bi = 0;
for (const [name, src] of badCases) {
  log('bad case #' + bi + ' (' + name + ') pre-parse');
  bi++;
  try {
    const { errors } = parseSync('bad.js', src);
    log('  parsed, errors=' + errors.length);
    if (errors.length === 0) {
      console.error(`FAIL: invalid input ('${name}') produced 0 errors`);
      failed++;
      continue;
    }
    const e0 = errors[0];
    log('  e0=' + JSON.stringify(e0).slice(0, 120));
    const required = ['message', 'filename', 'start', 'end', 'line', 'column'];
    const missing = required.filter(k => e0[k] === undefined);
    if (missing.length > 0) {
      console.error(`FAIL: error missing fields ${missing.join(',')} for '${name}':`, e0);
      failed++;
      continue;
    }
    if (e0.filename !== 'bad.js') {
      console.error(`FAIL: filename not echoed for '${name}':`, e0.filename);
      failed++;
      continue;
    }
    if (e0.line < 1 || e0.column < 1) {
      console.error(`FAIL: line/column must be 1-based for '${name}':`, e0);
      failed++;
      continue;
    }
    passed++;
  } catch (err) {
    console.error(`CRASH: '${name}':`, err.message);
    failed++;
  }
}

// BISECT: parse small variants to find which trigger the x86_64 crash.
const variants = [
  ['v1 short multi-line all good',         'a;\nb;'],
  ['v2 multi-line valid',                  'function f() {\n  return 1;\n}'],
  ['v3 single-line unterminated',          'function f() { return "abc'],
  ['v4 multi-line, term string on line 2', 'function f() {\n  return "abc";\n}'],
  ['v5 multi-line, unterm string EOL',     'function f() { return "abc\n}'],
  ['v6 ORIGINAL multi-line unterm string', 'function bad() {\n  return "unterminated\n}'],
];
let vi = 0;
for (const [name, src] of variants) {
  log('variant #' + vi + ' ' + name + ' (len=' + src.length + ')');
  vi++;
  try {
    const { errors } = parseSync('demo.js', src);
    log('  parsed, errors=' + errors.length);
    passed++;
  } catch (e) {
    log('  threw: ' + e.message);
    failed++;
  }
}

// formatError helper renders a multi-line codeframe.
log('formatError test pre-parse');
try {
  const { formatError } = require('./format');
  log('  required ./format');
  const src = 'function bad() {\n  return "unterminated\n}';
  const { errors } = parseSync('demo.js', src);
  log('  parsed, errors=' + errors.length);
  if (errors.length === 0) throw new Error('expected at least one error');
  const out = formatError(errors[0], src);
  log('  formatted, len=' + out.length);
  if (!out.includes('demo.js:') || !out.includes('^') || out.split('\n').length < 3) {
    console.error('FAIL: formatError output looks wrong:\n' + out);
    failed++;
  } else {
    passed++;
  }
} catch (err) { console.error('CRASH: formatError:', err.message); failed++; }

log('end of script');
console.log(`kessel npm test: ${passed} passed, ${failed} failed`);
log('after final console.log');
process.exit(failed > 0 ? 1 : 0);
