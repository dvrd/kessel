#!/usr/bin/env node
/**
 * Smoke test for the kessel npm package.
 */

'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { readFileSync } = require('node:fs');
const { createRequire } = require('node:module');
const { compileFunction } = require('node:vm');
const { parseSync, parseAsync } = require('./index');
const { lintSync } = require('./index');

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

// A default function declaration binds its name in the module. Parenthesized
// function and class expressions keep their names private after printing.
try {
  const { codegen } = require('./index');
  for (const [form, type] of [
    ['function named() { return named; }', 'FunctionDeclaration'],
    ['async function* named() { yield named; }', 'FunctionDeclaration'],
    ['function() {}', 'FunctionDeclaration'],
    ['(function named() {});', 'FunctionExpression'],
    ['(class Named {});', 'ClassExpression'],
    ['(function named() {}) || null;', 'LogicalExpression'],
  ]) {
    const source = 'export default ' + form;
    const outputs = [source];
    for (const minified of [false, true]) {
      const result = codegen(source, { filename: 'default.mjs', minified });
      assert.deepEqual(result.errors, []);
      outputs.push(result.code);
    }
    for (const output of outputs) {
      const { program, errors } = parseSync('default.mjs', output);
      assert.deepEqual(errors, []);
      assert.equal(program.body.length, 1);
      assert.equal(program.body[0].declaration.type, type, output);
    }
  }
  passed++;
} catch (error) { console.error('FAIL: default export declarations and expressions', error); failed++; }

// Every span in the SDK measures bytes in the original source, including
// names whose decoded spelling differs from their source token.
try {
  const text = [
    '/*🚀*/ import main, { "α-β" as café } from "./a";',
    'import * as ns from "./b";',
    'export { café as "public" };',
    'export { "a" as "b" } from "x";',
    'export * as "c-\\u0064" from "y";',
    'export default function /* run */ run() {',
    '  outer: while (true) { if (run) continue outer; break outer; }',
    '  return [import.meta, new.target, function self(){}, class Inner {}];',
    '}',
    'class Example { method() {} }',
  ].join('\n');
  const { program, errors } = parseSync('spans.mjs', text);
  assert.deepEqual(errors, []);
  const [named, namespace, local, remote, all, exported, declaration] = program.body;
  const fn = exported.declaration;
  const [loop, returned] = fn.body.body;
  const [condition, stop] = loop.body.body.body;
  const [meta, target, expression, cls] = returned.argument.elements;
  const check = (node, phrase, token = phrase) => {
    const at = text.indexOf(phrase) + phrase.lastIndexOf(token);
    assert.ok(text.includes(phrase) && phrase.includes(token));
    const start = Buffer.byteLength(text.slice(0, at));
    assert.deepEqual([node.start, node.end], [start, start + Buffer.byteLength(token)], phrase);
    if (node.type === 'Literal') {
      assert.equal(node.raw, token);
      assert.equal(node.value, JSON.parse(token));
    } else {
      assert.equal(node.type, 'Identifier');
      assert.equal(node.name, token);
    }
  };
  check(named.specifiers[0].local, 'main');
  check(named.specifiers[1].imported, '"α-β"');
  check(named.specifiers[1].local, 'as café', 'café');
  check(named.source, '"./a"');
  check(namespace.specifiers[0].local, 'as ns', 'ns');
  check(local.specifiers[0].local, '{ café', 'café');
  check(local.specifiers[0].exported, '"public"');
  check(remote.specifiers[0].local, '"a"');
  check(remote.specifiers[0].exported, '"b"');
  check(remote.source, '"x"');
  check(all.exported, '"c-\\u0064"');
  check(all.source, '"y"');
  check(fn.id, '*/ run()', 'run');
  check(loop.label, 'outer:', 'outer');
  check(condition.consequent.label, 'continue outer', 'outer');
  check(stop.label, 'break outer', 'outer');
  check(meta.meta, 'import.meta', 'import');
  check(meta.property, 'import.meta', 'meta');
  check(target.meta, 'new.target', 'new');
  check(target.property, 'new.target', 'target');
  check(expression.id, 'self');
  check(cls.id, 'Inner');
  check(declaration.id, 'Example');
  assert.equal(declaration.body.body[0].value.id, null);
  passed++;
} catch (error) { console.error('FAIL: AST child spans', error); failed++; }

// Frozen output from the older native emitter keeps archived ASTs readable.
try {
  const { decode } = require('./binary-reader');
  const source = 'import {a as b} from "q"; export default function f(){L: while(1) break L; return import.meta;}';
  const bytes = Buffer.from(
  'VFNFSwQAAAAMAAAAzQAAAAAAAAAAAAAAAAAAAABfAAAAAAAAAAIAAABGAAAAABkAAAABAAAA' +
  'RwgAAAAOAAAAAQAAAAIAAAADAAAASxoAAABfAAAAPikAAABfAAAABAQAAAAAAAAAAAArNQAA' +
  'AF8AAAACAAAAMTYAAABKAAAABQAAADU5AAAASgAAAAM/AAAAQAAAAAAAAAAAAPA/BgAAAC9C' +
  'AAAASgAAAAQFAAAALksAAABeAAAA/SZSAAAAXQAAAAcAAAAIAAAAAAAAABUBAIAGAAAACAAA' +
  'AAEAAAANAAAAAQAAABYAAAABAAAAMgAAAAEAAAA2AAAAAQAAAD8AAAABAAAAGwEAgAYAAABZ' +
  'AAAABAAAAG1vZHVsZWltcG9ydA==', 'base64');
  // Without diagnostics the v3 and v4 layouts are identical.
  for (const version of [3, 4]) {
    const buffer = Buffer.from(bytes);
    buffer.writeUInt32LE(version, 4);
    const { program, errors } = decode(buffer, source);
    assert.deepEqual(errors, []);
    const [im, ex] = program.body;
    assert.deepEqual(im.specifiers[0].local, { type: 'Identifier', name: 'b', start: 8, end: 14 });
    assert.equal(im.source.value, 'q');
    assert.equal(ex.declaration.id.name, 'f');
    assert.equal(ex.declaration.body.body[0].body.body.label.name, 'L');
    assert.equal(ex.declaration.body.body[1].argument.property.name, 'meta');
  }
  const fields = Buffer.from(
  'VFNFSwUAAAAFAAAAYwAAAAAAAAAAAAAAAAAAAAAeAAAAAAAAAAEAAABBAAAAAB4AAAAEAQAA' +
  'AP4VCAAAAB4AAAABAAAAFwoAAAAcAAAAAAL9ARIAAAATAAAAAgAAAP4AAAAAewAAgAYAAAAG' +
  'AAAAAQAAABIAAAABAAAAc2NyaXB0', 'base64');
  const cls = decode(fields, 'class C { declare x: number; }').program.body[0];
  assert.equal(cls.id.name, 'C');
  assert.equal(cls.body.body[0].declare, true);
  passed++;
} catch (error) { console.error('FAIL: archived binary ASTs', error); failed++; }

// Class fields keep their identity even when initialized with a function.
try {
  const source = 'class Example { field = function() {}; method() {} get\n *iterate() {} }';
  const { program, errors } = parseSync('fields.js', source);
  assert.deepEqual(errors, []);
  const members = program.body[0].body.body;
  assert.deepEqual(members.map(member => [member.type, member.key.name]), [
    ['PropertyDefinition', 'field'],
    ['MethodDefinition', 'method'],
    ['PropertyDefinition', 'get'],
    ['MethodDefinition', 'iterate'],
  ]);
  assert.equal(members[0].value.type, 'FunctionExpression');
  assert.equal(members[3].value.generator, true);
  passed++;
} catch (error) { console.error('FAIL: class fields:', error.message); failed++; }

// A declared field and a runtime field named "declare" have different effects.
try {
  const source = 'class C { declare x: number; declare static y: number; declare = 9; static z; }';
  const { codegen } = require('./index');
  const outputs = [source];
  for (const minified of [false, true]) {
    const result = codegen(source, { filename: 'fields.ts', minified });
    assert.deepEqual(result.errors, []);
    outputs.push(result.code);
  }
  for (const output of outputs) {
    const { program, errors } = parseSync('fields.ts', output);
    assert.deepEqual(errors, []);
    const members = program.body[0].body.body;
    assert.deepEqual(members.map(member => [member.key.name, member.static, member.declare]), [
      ['x', false, true], ['y', true, true], ['declare', false, undefined], ['z', true, undefined],
    ]);
  }
  passed++;
} catch (error) { console.error('FAIL: declared fields:', error.message); failed++; }

// A TS or JSX left operand still starts the surrounding binary expression.
try {
  for (const [filename, operand] of [['spans.ts', 'value!'], ['spans.tsx', '<Icon />']]) {
    const expression = operand + ' === expected';
    const source = 'const before = 0; const equal = ' + expression + ';';
    const { program, errors } = parseSync(filename, source);
    assert.deepEqual(errors, []);
    const { start, end } = program.body[1].declarations[0].init;
    assert.equal(source.slice(start, end), expression);
  }
  passed++;
} catch (error) { console.error('FAIL: TS and JSX expression spans:', error.message); failed++; }

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

// Rich parse options are threaded through kessel_parse_binary_v2.
try {
  const fast = parseSync('dup.js', 'let x; let x;');
  const checked = parseSync('dup.js', 'let x; let x;', { mode: 'parse' });
  if (fast.errors.length !== 0) {
    console.error('FAIL: default npm mode should preserve fast ast-only behaviour');
    failed++;
  } else if (checked.errors.length === 0) {
    console.error('FAIL: mode=parse did not enable parser duplicate-binding checks');
    failed++;
  } else {
    passed++;
  }
} catch (e) { console.error('CRASH: mode=parse option:', e.message); failed++; }

try {
  const auto = parseSync('module-ish.js', 'import x from "y";');
  const script = parseSync('module-ish.js', 'import x from "y";', {
    sourceType: 'script',
    mode: 'parse',
  });
  if (auto.errors.length !== 0) {
    console.error('FAIL: default sourceType should allow module auto-detection');
    failed++;
  } else if (script.errors.length === 0) {
    console.error('FAIL: sourceType=script did not reject import declaration');
    failed++;
  } else {
    passed++;
  }
} catch (e) { console.error('CRASH: sourceType option:', e.message); failed++; }

try {
  const { program } = parseSync('paren.js', '(x);', { preserveParens: true });
  const expr = program.body[0]?.expression;
  if (expr?.type !== 'ParenthesizedExpression') {
    console.error('FAIL: preserveParens did not emit ParenthesizedExpression:', expr && expr.type);
    failed++;
  } else {
    passed++;
  }
} catch (e) { console.error('CRASH: preserveParens option:', e.message); failed++; }

try {
  const { errors } = parseSync('inline.ts', 'if (x) {}', {
    lang: 'ts',
    sourceIsDts: true,
    mode: 'parse',
  });
  if (errors.length === 0) {
    console.error('FAIL: sourceIsDts=true did not apply declaration-file restrictions');
    failed++;
  } else {
    passed++;
  }
} catch (e) { console.error('CRASH: sourceIsDts option:', e.message); failed++; }

// parseAsync regression tests. Wrapped in an async IIFE so the existing
// synchronous tests above keep their straightforward control flow; the
// final tally + exit code waits for the IIFE to settle.
(async () => {
  try {
    const cases = [
      ['if (x) { return 1; } else if (y) log();', 0],
      ['if (x) log(); else if (y) return 2; else log();', 0],
      ['if (x) { return 1; } else log();', 1],
      ['if (x) return 1; else if (y) { return 2; } else log();', 1],
      ['if (x) { if (y) return 1; else return 2; } else { log(); }', 2],
      ['while (x) if (y) return 1; else log();', 0],
    ];
    for (const [body, count] of cases) {
      const source = 'function f(x, y) { ' + body + ' }';
      const { diagnostics } = lintSync('else.js', source, { rules: { 'no-else-return': 'warn' } });
      const warnings = diagnostics.filter(d => d.code === 'L4053');
      assert.equal(warnings.length, count, body);
      for (const d of warnings) assert.equal(source.slice(d.start, d.end).trim(), 'else');
    }
    passed++;
  } catch (error) { console.error('FAIL: no-else-return alternatives', error); failed++; }

  try {
    const source = '/*🚀e\u0301*/\r\nconst café = <View title="東京">hé🚀</View>;\n' +
      'const text = "\\uFEFFvalue";';
    for (const parse of [parseSync, parseAsync]) {
      const { program, errors } = await parse('unicode.tsx', source);
      assert.deepEqual(errors, []);
      const { id, init } = program.body[0].declarations[0];
      assert.equal(id.name, 'café');
      assert.equal(id.start, Buffer.byteLength(source.slice(0, source.indexOf('café'))));
      assert.equal(id.end - id.start, Buffer.byteLength('café'));
      assert.equal(init.openingElement.name.name, 'View');
      assert.equal(init.closingElement.name.name, 'View');
      const [attribute] = init.openingElement.attributes;
      assert.equal(attribute.name.name, 'title');
      assert.equal(attribute.value.value, '東京');
      assert.equal(attribute.value.raw, '"東京"');
      assert.equal(init.children[0].value, 'hé🚀');
      assert.equal(program.body[1].declarations[0].init.value, '\uFEFFvalue');
    }
    passed++;
  } catch (error) { console.error('FAIL: Unicode AST strings:', error); failed++; }

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

  // -- lintSync (pass 4) ----------------------------------------------------
  try {
    const d = lintSync('l.js', 'function f(){ debugger; }');
    if (d.diagnostics.length === 1 && d.diagnostics[0].code === 'L2001' &&
        d.diagnostics[0].severity === 'error' && d.diagnostics[0].line === 1) {
      passed++;
    } else {
      console.error('FAIL: lintSync no-debugger', JSON.stringify(d.diagnostics));
      failed++;
    }
  } catch (e) { console.error('CRASH: lintSync no-debugger:', e.message); failed++; }

  try {
    const d = lintSync('clean.js', 'const x = 1;\nconsole.log(x);\n');
    if (d.diagnostics.length === 0) { passed++; }
    else { console.error('FAIL: lintSync clean', JSON.stringify(d.diagnostics)); failed++; }
  } catch (e) { console.error('CRASH: lintSync clean:', e.message); failed++; }

  try {
    const d = lintSync('dupe.js', 'const o = { a: 1, a: 2 };');
    if (d.diagnostics.some((x) => x.code === 'L2002')) { passed++; }
    else { console.error('FAIL: lintSync no-dupe-keys', JSON.stringify(d.diagnostics)); failed++; }
  } catch (e) { console.error('CRASH: lintSync no-dupe-keys:', e.message); failed++; }

  try {
    const d = lintSync('perr.js', 'const x = ;');
    if (d.diagnostics.length >= 1 && d.diagnostics[0].code[0] === 'K') { passed++; }
    else { console.error('FAIL: lintSync parse error', JSON.stringify(d.diagnostics)); failed++; }
  } catch (e) { console.error('CRASH: lintSync parse error:', e.message); failed++; }

  // rules override: enable a default-off rule (eqeqeq) via opts.rules.
  try {
    const d = lintSync('eq.js', 'if (a == b) {}', { rules: { 'eqeqeq': 'error' } });
    if (d.diagnostics.some((x) => x.code === 'L1003' && x.severity === 'error')) { passed++; }
    else { console.error('FAIL: lintSync rules eqeqeq:error', JSON.stringify(d.diagnostics)); failed++; }
  } catch (e) { console.error('CRASH: lintSync rules eqeqeq:', e.message); failed++; }

  // rules override: disable a default-on rule (no-debugger) via opts.rules.
  try {
    const d = lintSync('dbg.js', 'function f(){ debugger; }', { rules: { 'no-debugger': 'off' } });
    if (!d.diagnostics.some((x) => x.code === 'L2001')) { passed++; }
    else { console.error('FAIL: lintSync rules no-debugger:off', JSON.stringify(d.diagnostics)); failed++; }
  } catch (e) { console.error('CRASH: lintSync rules no-debugger:off:', e.message); failed++; }

  // Evaluate a second copy of the binding with the same Koffi installation.
  // Both copies must be able to register and use their own FFI structures.
  try {
    const filename = require.resolve('./index');
    const secondModule = { exports: {} };
    const loadBinding = compileFunction(
      readFileSync(filename, 'utf8'),
      ['require', 'module', '__dirname'],
      { filename },
    );
    loadBinding(createRequire(filename), secondModule, __dirname);
    const source = 'const value: number = 1;';
    const { program, errors } = await secondModule.exports.parseAsync('coexist.ts', source);
    assert.deepEqual(errors, []);
    assert.equal(program.body[0].type, 'VariableDeclaration');
    const generated = secondModule.exports.codegen(source, { filename: 'coexist.ts' });
    assert.deepEqual(generated.errors, []);
    assert.ok(generated.code.includes('value'));
    const linted = secondModule.exports.lintSync('coexist.js', 'debugger;');
    assert.ok(linted.diagnostics.some(diagnostic => diagnostic.code === 'L2001'));
    assert.deepEqual(parseSync('coexist.ts', source).errors, []);
    passed++;
  } catch (e) { console.error('FAIL: multiple Kessel bindings:', e.message); failed++; }

  // A child process turns a foreign stack overflow into a failed smoke test
  // and tests the path where another package loaded Koffi first.
  for (const preload of [false, true]) {
    try {
      const script = `
        const assert = require('node:assert/strict');
        const koffi = require('koffi');
        if (${preload}) koffi.load(null);
        const {parseAsync, parseSync} = require('./index');
        const source = 'const nested = ' + '['.repeat(64) + '1' + ']'.repeat(64) + ';';
        const expected = parseSync('nested.js', source);
        assert.deepEqual(expected.errors, []);
        Promise.all([parseAsync('nested.js', source), parseAsync('nested.js', source)])
          .then(results => results.forEach(result => assert.deepEqual(result, expected)))
          .catch(error => { console.error(error); process.exitCode = 1; });
      `;
      const result = spawnSync(process.execPath, ['-e', script], {
        cwd: __dirname, encoding: 'utf8', timeout: 15000,
      });
      assert.equal(result.status, 0, result.stderr || String(result.error || result.signal));
      passed++;
    } catch (e) { console.error('FAIL: async native stack, preloaded=' + preload, e.message); failed++; }
  }

  console.log(`kessel npm test: ${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
})();
