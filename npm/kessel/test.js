#!/usr/bin/env node
/**
 * Smoke test for the kessel npm package.
 */

'use strict';
const { parseSync, parseAsync } = require('./index');

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

// Regression test for token-aware error spans (binary format v3).
// Before v3 every error had start === end (single-byte caret). Now
// errors reported via the parser's primary report_error path carry the
// full extent of the offending token, so renderers can underline
// `[start, end)` instead of dropping a single caret. Lexer-side and
// some legacy parser report_error_at call sites still emit single-point
// reports (start === end); both shapes are valid and the test accepts
// either as long as `end >= start` for every error.
try {
  const { errors } = parseSync('span.js', 'const x = ;');
  if (errors.length === 0) throw new Error('expected at least one error');
  let sawSpan = false;
  for (const e of errors) {
    if (typeof e.start !== 'number' || typeof e.end !== 'number' || e.end < e.start) {
      throw new Error('error has invalid span shape: ' + JSON.stringify(e));
    }
    if (e.end > e.start) sawSpan = true;
  }
  if (!sawSpan) {
    console.error('FAIL: token-aware spans: expected at least one error with end > start');
    failed++;
  } else {
    passed++;
  }
} catch (err) { console.error('CRASH: token-aware spans:', err.message); failed++; }

// Regression test for UTF-8-correct line/column derivation. Previously
// computeLineStarts walked source.charCodeAt(i), which is a UTF-16 code-
// unit index — mismatched against the parser's UTF-8 byte offsets the
// moment any non-BMP character (4-byte UTF-8 / 2-unit UTF-16 surrogate)
// appeared before an error site. The fix scans Buffer.from(source) so
// every offset is consistently in UTF-8 bytes.
try {
  // 😀 = U+1F600, 4 UTF-8 bytes / 2 UTF-16 code units.
  // The trailing `*/` is an unterminated regex / divide — we just need
  // a parser error AFTER the non-BMP run on line 2.
  const src = 'const e = "😀😀😀";\nconst x = ;';
  const { errors } = parseSync('emoji.js', src);
  if (errors.length === 0) throw new Error('expected at least one error');
  // The first error should be on line 2 (after the LF that follows the
  // emoji-laden line). Pre-fix, the LF's table entry was off by 3 (one
  // per emoji), placing the error in column-N of line 1 instead.
  const e0 = errors[0];
  if (e0.line !== 2) {
    console.error('FAIL: UTF-8 line/column: expected line 2, got', e0.line, e0);
    failed++;
  } else {
    passed++;
  }
} catch (err) { console.error('CRASH: utf8 line/col:', err.message); failed++; }

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

// parseAsync regression tests. Wrapped in an async IIFE so the existing
// synchronous tests above keep their straightforward control flow; the
// final tally + exit code waits for the IIFE to settle.
(async () => {
  // 1) Single-call correctness — parseAsync must return the same AST
  //    shape and the same number of errors as parseSync for the same
  //    input. Same FFI, just dispatched onto a libuv worker thread.
  try {
    const src = 'function f(a, b) { return a + b; }';
    const sync = parseSync('p.js', src);
    const asyn = await parseAsync('p.js', src);
    if (sync.program.body[0].type !== asyn.program.body[0].type) {
      console.error('FAIL: parseAsync produced different top-level type than parseSync');
      failed++;
    } else if (sync.errors.length !== asyn.errors.length) {
      console.error('FAIL: parseAsync produced different error count:', sync.errors.length, 'vs', asyn.errors.length);
      failed++;
    } else {
      passed++;
    }
  } catch (e) { console.error('CRASH: parseAsync correctness:', e.message); failed++; }

  // 2) Concurrent fan-out — 20 simultaneous parses across libuv's worker
  //    pool. Verifies the handle-based FFI (no thread-local state) lets
  //    multiple parses run in flight without crossing each other's buffers.
  try {
    const N = 20;
    const tasks = Array.from({ length: N }, (_, i) =>
      parseAsync('p' + i + '.ts', 'const v' + i + ': number = ' + i + ';')
    );
    const all = await Promise.all(tasks);
    const ok = all.length === N
            && all.every((r, i) => r.program.body[0].type === 'VariableDeclaration'
                                && r.errors.length === 0);
    if (!ok) {
      console.error('FAIL: parseAsync concurrent fan-out got bad results');
      failed++;
    } else {
      passed++;
    }
  } catch (e) { console.error('CRASH: parseAsync concurrent:', e.message); failed++; }

  // 3) Error path — invalid input surfaces the same errors as parseSync.
  try {
    const src = 'const x = ;';
    const { errors } = await parseAsync('bad.js', src);
    if (errors.length === 0) {
      console.error('FAIL: parseAsync invalid input produced 0 errors');
      failed++;
    } else if (errors[0].filename !== 'bad.js' || errors[0].line < 1) {
      console.error('FAIL: parseAsync errors not enriched:', errors[0]);
      failed++;
    } else {
      passed++;
    }
  } catch (e) { console.error('CRASH: parseAsync errors:', e.message); failed++; }

  // 4) Event loop responsiveness — the parse must not block setImmediate
  //    callbacks. We schedule a tick before kicking off a parseAsync and
  //    expect the tick to fire before the parse resolves (since the parse
  //    runs on a worker, the main-thread tick queue drains immediately).
  try {
    let tickFiredFirst = false;
    let parseResolved = false;
    const tick = new Promise((res) => setImmediate(() => {
      if (!parseResolved) tickFiredFirst = true;
      res();
    }));
    // A wide flat program — many top-level statements rather than a deep
    // expression tree, so we don't trip the binary reader's MAX_DEPTH guard
    // while still giving the parse enough work to matter.
    const bigSrc = 'var a = 1;\n'.repeat(20000);
    const parse = parseAsync('p.js', bigSrc).then(() => {
      parseResolved = true;
    });
    await Promise.all([tick, parse]);
    if (!tickFiredFirst) {
      console.error('FAIL: parseAsync blocked the event loop (setImmediate ran after parse resolved)');
      failed++;
    } else {
      passed++;
    }
  } catch (e) { console.error('CRASH: parseAsync event-loop:', e.message); failed++; }

  console.log(`kessel npm test: ${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
})();
