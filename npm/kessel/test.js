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

// formatError helper renders a multi-line codeframe.
try {
  const { formatError } = require('./format');
  const src = 'function bad() {\n  return "unterminated\n}';
  const { errors } = parseSync('demo.js', src);
  if (errors.length === 0) throw new Error('expected at least one error');
  const out = formatError(errors[0], src);
  if (!out.includes('demo.js:') || !out.includes('^') || out.split('\n').length < 3) {
    console.error('FAIL: formatError output looks wrong:\n' + out);
    failed++;
  } else {
    passed++;
  }
} catch (err) { console.error('CRASH: formatError:', err.message); failed++; }

// Regression test for the x86_64 SIMD alignment bug. JS `Buffer.from(source)`
// hands the parser a buffer with no 16-byte alignment guarantee. Before the
// fix, the SIMD lexer's 16-byte load `(cast(^Vec16)&src[off])^` was lowered
// by LLVM to MOVAPS (aligned move) on x86_64. MOVAPS faults on misaligned
// addresses → SIGSEGV — silent on ARM64 because NEON tolerates unaligned
// loads natively. The fix routes every SIMD load through
// `intrinsics.unaligned_load`, forcing MOVDQU / MOVUPS. We exercise a few
// shapes at different lengths so the chance of the buffer happening to
// land at an aligned address is zero across runs.
const alignmentCases = [
  'function bad() {\n  return "untermi',                      // len 34 — gdb-confirmed minimum repro
  'function bad() {\n  return "unterminated\n}',              // len 41 — original repro from the field
  'function f() {\n  return "abc";\n}',                       // len 32 — terminated string in a multi-line fn
  'var a = 1;\n  var b = 2;\n  var c = 3;\n  var d = 4;\n',   // 16-space indents force the SIMD WS skipper
  'a;\n'.repeat(50),                                           // many short statements; long whitespace runs
];
for (const src of alignmentCases) {
  try {
    parseSync('align.js', src);
    passed++;
  } catch (e) {
    console.error(`CRASH: alignment src (len=${src.length}): ${e.message}`);
    failed++;
  }
}

console.log(`kessel npm test: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
