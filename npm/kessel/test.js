#!/usr/bin/env node
/**
 * Smoke test for the kessel npm package.
 */

'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { createRequire } = require('node:module');
const { compileFunction } = require('node:vm');
const { parseSync, parseAsync } = require('./index');
const { lintSync, scanModuleSync, parseRegExpSync, resolveModuleSync, formatSync, transformSync, minifySync } = require('./index');

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
  const ambient = Buffer.from(
    'VFNFSwcAAAAHAAAAqAAAAAAAAAAAAAAAAAAAAAAdAAAAAAAAAAEAAABKAAAAAB0AAAD9ZQQB' +
    'AAAAAQA/BwAAAB0AAAABAQAAAEATAAAAHAAAAGQTAAAAHAAAAAIAAAADAwAAAAQAAAAEBQAA' +
    'AAACBgAAAAAAAAABBwAAAGQUAAAAHAAAAAgAAAABBwAAAGQWAAAAHAAAAAkAAAAAAAD+AAAA' +
    'AAAAAAAA+AAAgAYAAAD+AACABwAAAAUBAIAKAAAADwEAgAQAAAATAAAAAQAAABMBAIAIAAAA' +
    'GwEAgAoAAAAlAQCADgAAADMBAIAQAAAAQwEAgA8AAABtb2R1bGVkZWNsYXJlSWRlbnRpZmll' +
    'cm5hbWVvcHRpb25hbGRlY29yYXRvcnN0eXBlQW5ub3RhdGlvblRTVHlwZUFubm90YXRpb25U' +
    'U051bWJlcktleXdvcmQ=', 'base64');
  const exported = decode(ambient, 'export declare let v: number;').program.body[0];
  assert.equal(exported.exportKind, 'type');
  assert.equal(exported.declaration.declare, true);
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

// JavaScript requires parentheses wherever ?? meets && or ||, on either side.
try {
  const { codegen } = require('./index');
  const source = `function evaluate(a, b, c) {
    return [(a && b) ?? c, (a || b) ?? c, a ?? (b && c), a ?? (b || c),
      (a ?? b) && c, (a ?? b) || c, a && (b ?? c), a || (b ?? c)];
  }`;
  const evaluator = code => compileFunction(code + '\nreturn evaluate;')();
  const original = evaluator(source);
  for (const minified of [false, true]) {
    const printed = codegen(source, { filename: 'coalesce.js', minified });
    assert.deepEqual(printed.errors, []);
    const evaluate = evaluator(printed.code);
    for (const a of [null, false, 'a']) {
      for (const b of [undefined, 0, 'b']) assert.deepEqual(evaluate(a, b, 'c'), original(a, b, 'c'));
    }
  }
  passed++;
} catch (error) { console.error('FAIL: coalescing and boolean operators:', error.message); failed++; }

// Parentheses distinguish the membership operator in a loop initializer from a for-in header.
try {
  const { codegen } = require('./index');
  const source = `function check(obj) {
    let seen = 0;
    for (var exists = ('x' in obj), visit = true; visit; visit = false) seen += exists;
    for (seen += ('x' in obj) ? 2 : 0; false;) {}
    for (let get = () => ('x' in obj); get();) { seen += 4; break; }
    return seen;
  }`;
  for (const minified of [false, true]) {
    const result = codegen(source, { filename: 'for-init.js', minified });
    assert.deepEqual(result.errors, []);
    const check = compileFunction(result.code + '\nreturn check;')();
    assert.equal(check({ x: true }), 7);
    assert.equal(check({}), 0);
  }
  passed++;
} catch (error) { console.error('FAIL: in within for initializers:', error.message); failed++; }

// Codegen preserves legal comments and optimizer annotations through the binding.
try {
  const { codegen } = require('./index');
  const result = codegen('/*! notice */\nconst x = /*@__PURE__*/ make();', { minified: true });
  assert.deepEqual(result.errors, []);
  assert.equal(result.code, '/*! notice */const x=/*#__PURE__*/make();');
  passed++;
} catch (error) { console.error('FAIL: codegen comments:', error.message); failed++; }

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

// A mismatched closing tag is reported on the closing tag's name.
try {
  const errors = parseSync('mismatch.jsx', '<p></div>;').errors;
  if (errors.length >= 1 && errors[0].code === 'K3063' &&
      errors[0].start === 5 && errors[0].end === 8) passed++;
  else { console.error('FAIL: JSX closing tag span', JSON.stringify(errors)); failed++; }
} catch (e) { console.error('CRASH: JSX closing tag span', e.message); failed++; }

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

  try {
    const source = 'import * as π from "lib";\nReflect.set(π,"x",1);\nconst value=1; value++;\nfunction g(π){ π.x=1; }';
    const { diagnostics } = lintSync('writes.mjs', source);
    const bytes = Buffer.from(source);
    const writes = diagnostics.map(d => [d.code, d.line, d.column, bytes.subarray(d.start, d.end).toString()]);
    assert.deepEqual(writes.sort(), [['L2048', 2, 13, 'π'], ['L2055', 3, 16, 'value']]);
    const block = lintSync('strict.mjs', '{ function f() {} f++; } f++;');
    assert.deepEqual(block.diagnostics.filter(d => d.code === 'L2050').map(d => d.start), [18]);
    passed++;
  } catch (e) { console.error('FAIL: lintSync binding writes and module scope', e); failed++; }

  try {
    const source = 'function View(p){ /*🪴*/ if(p.ready) useEffect(refresh); }';
    const span = Buffer.byteLength(source.slice(0, source.indexOf('useEffect')));
    const hooks = options => lintSync('view.tsx', source, options).diagnostics
      .filter(d => d.code === 'L4107').map(d => [d.severity, d.start, d.end]);
    assert.deepEqual(hooks({}), []);
    for (const rule of ['rules-of-hooks', 'react/rules-of-hooks', 'react-hooks/rules-of-hooks']) {
      assert.deepEqual(hooks({ rules: { [rule]: 'warn' } }), [['warning', span, span + 'useEffect(refresh)'.length]]);
    }
    passed++;
  } catch (e) { console.error('FAIL: React Hook placement on unsaved TSX', e); failed++; }

  try {
    const source = 'function View(p){ /*🪴*/ useMemo(()=>p.user?.id, []); }';
    const start = Buffer.byteLength(source.slice(0, source.indexOf('[]')));
    for (const rule of ['exhaustive-deps', 'react/exhaustive-deps', 'react-hooks/exhaustive-deps']) {
      const options = { rules: { [rule]: ['warn', { additionalHooks: 'RemoteMemo$' }] } };
      for (const hook of ['useMemo', 'RemoteMemo']) {
        const input = source.replace('useMemo', hook);
        const offset = start + hook.length - 'useMemo'.length;
        const notes = lintSync('view.tsx', input, options).diagnostics.filter(d => d.code === 'L4108');
        assert.deepEqual(notes.map(d => [d.start, d.end, d.message]), [
          [offset, offset + 2, "React Hook " + hook + " has a missing dependency: 'p.user.id'"],
        ]);
      }
    }
    const rules = { 'exhaustive-deps': 'warn' };
    const choices = lintSync('view.tsx', source, { rules, includeFixes: true, includeSuggestions: true });
    const diagnostic = choices.diagnostics.find(d => d.code === 'L4108');
    assert.equal(choices.output, undefined);
    assert.equal(diagnostic.fix, undefined);
    assert.deepEqual(diagnostic.suggestion, {
      start: start + 1, end: start + 2, text: 'p.user?.id]', title: 'Add missing Hook dependencies',
    });
    const mixed = 'function View(p,q){ return useMemo(()=>p, [q]); }';
    const suggestions = lintSync('view.tsx', mixed, { rules, includeSuggestions: true }).diagnostics
      .filter(d => d.code === 'L4108').map(d => [d.message, d.suggestion.title]);
    assert.equal(suggestions.length, 2);
    assert.deepEqual(Object.fromEntries(suggestions), {
      "React Hook useMemo has a missing dependency: 'p'": 'Add missing Hook dependencies',
      'React Hook useMemo has unnecessary dependency: q': 'Remove `q` from Hook dependencies',
    });
    for (const flags of [{ fix: true }, { fixSuggestions: true }, { fixDangerously: true }]) {
      assert.equal(lintSync('view.tsx', source, { rules, ...flags }).output, undefined);
    }
    const edit = { rules, fixSuggestions: true, fixDangerously: true };
    const fixed = lintSync('view.tsx', source, edit);
    assert.equal(fixed.output, source.replace('[]', '[p.user?.id]'));
    assert.ok(fixed.diagnostics.every(d => d.code !== 'L4108'));
    assert.equal(lintSync('view.tsx', fixed.output, edit).output, undefined);
    const memo = 'function View(p){return useCallback(()=>p.user?.id)}';
    const memoFix = lintSync('view.tsx', memo, edit);
    assert.equal(memoFix.output, memo.replace('id)', 'id, [p.user?.id])'));
    let cached;
    const useCallback = (fn, deps) => {
      if (!cached || !Object.is(cached.value, deps[0])) cached = { value: deps[0], fn };
      return cached.fn;
    };
    const render = compileFunction(memoFix.output + '; return View;', ['useCallback'])(useCallback);
    assert.deepEqual([render({ user: null })(), render({ user: { id: 7 } })()], [undefined, 7]);
    const alias = 'function View(p){ useEffect(()=>{const {name: alias}=p; log(alias)}, [p.name]); }';
    assert.deepEqual(lintSync('view.tsx', alias, { rules }).diagnostics.filter(d => d.code === 'L4108'), []);
    const cleanup = 'function View(){const ref=useRef();useEffect(()=>{let node;node=ref.current;return ()=>{node=ref.current;node.close()}},[])}';
    const warnings = lintSync('view.tsx', cleanup, { rules }).diagnostics.filter(d => d.code === 'L4108');
    assert.deepEqual(warnings.map(d => [d.start, d.end]), [[cleanup.lastIndexOf('ref.current'), cleanup.lastIndexOf('ref.current') + 'ref.current'.length]]);
    const suppressed = 'function View(p){ useEffect(()=>{\n send(p);\n // eslint-disable-next-line react-hooks/exhaustive-deps\n }, []); }';
    assert.deepEqual(lintSync('view.tsx', suppressed, { rules }).diagnostics.filter(d => d.code === 'L4108'), []);
    assert.deepEqual(lintSync('view.tsx', source).diagnostics.filter(d => d.code === 'L4108'), []);
    const malformed = { rules: { 'exhaustive-deps': ['warn', { additionalHooks: '(' }] } };
    assert.equal(lintSync('view.tsx', source, malformed).diagnostics.filter(d => d.code === 'L4108').length, 1);
    assert.throws(() => lintSync('view.tsx', source, { rules: { 'exhaustive-deps': ['warn', { additionalHooks: 2 }] } }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: React Hook dependencies and additionalHooks', e); failed++; }

  try {
    const source = '/* π */ const obj = { get x(){ return; }, get y(){ if (ready) return 1; } };';
    const range = text => {
      const start = Buffer.byteLength(source.slice(0, source.indexOf(text)));
      return [start, start + Buffer.byteLength(text)];
    };
    const diagnosticRanges = allowImplicit => lintSync('getters.js', source, {
      rules: { 'getter-return': ['warn', { allowImplicit }] },
    }).diagnostics.filter(d => d.code === 'L2046').map(d => [d.start, d.end]);
    const partial = range('(){ if (ready) return 1; }');
    assert.deepEqual(diagnosticRanges(false), [range('(){ return; }'), partial]);
    assert.deepEqual(diagnosticRanges(true), [partial]);
    for (const option of [{ allowImplicit: 1 }, { unknown: true }, null]) {
      assert.throws(() => lintSync('input.js', '', { rules: { 'getter-return': ['warn', option] } }), TypeError);
    }
    passed++;
  } catch (e) { console.error('FAIL: getter control flow and byte ranges', e); failed++; }

  try {
    const source = '/* 🍂 */ switch (x) { case 1: break; /* break omitted */ case 2: run(); /* BREAK OMITTED */ default: break; }';
    const options = { commentPattern: 'break\\s+omitted', reportUnusedFallthroughComment: true };
    const rules = { 'no-fallthrough': ['warn', options] };
    const bytes = Buffer.from(source);
    const expected = [[bytes.indexOf(' /* break omitted */'), bytes.indexOf('case 2:'), 'warning']];
    for (const mode of [{}, { includeFixes: true }, { fix: true }]) {
      const reports = lintSync('switch.js', source, { rules, ...mode }).diagnostics.filter(d => d.code === 'L2045');
      assert.deepEqual(reports.map(d => [d.start, d.end, d.severity]), expected);
    }
    const spaced = 'switch(x){case 1:\r\n\r\ncase 2: break;}';
    for (const allowEmptyCase of [false, true]) {
      const result = lintSync('switch.js', spaced, { rules: { 'no-fallthrough': ['error', { allowEmptyCase }] } });
      assert.equal(result.diagnostics.filter(d => d.code === 'L2045').length, allowEmptyCase ? 0 : 1);
    }
    for (const option of [{ commentPattern: 1 }, { allowEmptyCase: 'yes' }, { unknown: true }]) {
      assert.throws(() => lintSync('switch.js', source, { rules: { 'no-fallthrough': ['warn', option] } }), TypeError);
    }
    for (const mode of [{}, { includeFixes: true }, { fix: true }]) {
      assert.throws(() => lintSync('switch.js', source, { ...mode, rules: { 'no-fallthrough': ['warn', { commentPattern: '(' }] } }));
    }
    passed++;
  } catch (e) { console.error('FAIL: switch fallthrough comments, options and byte ranges', e); failed++; }

  try {
    const source = 'let π: number=1; let [x,y]=[1,2]; x++;';
    const rules = { 'prefer-const': ['warn', { destructuring: 'all', ignoreReadBeforeAssign: true }] };
    const { diagnostics } = lintSync('const.ts', source, { rules });
    assert.deepEqual(diagnostics.filter(d => d.code === 'L4012').map(d => [d.severity,d.start,d.end]), [['warning',4,6]]);
    assert.deepEqual(lintSync('const.ts', source, { rules, fix: true }),
      { output: source.replace('let π', 'const π'), diagnostics: [] });
    const early = 'function read(){ return x; } let x=2;';
    assert.deepEqual(lintSync('const.js', early, { rules, fix: true }), { diagnostics: [] });
    for (const options of [{ destructuring: 'one' }, { ignoreReadBeforeAssign: 1 }, { unknown: true }, null]) {
      assert.throws(() => lintSync('const.js', '', { rules: { 'prefer-const': ['error', options] } }), TypeError);
    }
    passed++;
  } catch (e) { console.error('FAIL: prefer-const settings, byte spans and safe edits', e); failed++; }

  try {
    const source = [
      '// 🍃', 'console.warn(); console.log();', 'function write(console) { console.log(); }',
      'console[`lo\\x67`](); console[name](); console?.trace?.();',
      'const view = <Tag fn={console.error} />;', "console['__proto__'] = custom;",
      '// oxlint-disable-next-line no-console', 'console.log();',
    ].join('\n');
    const bytes = Buffer.from(source);
    const settings = { rules: { 'no-console': ['error', { allow: ['warn', 'trace', '__proto__'] }] } };
    const messages = result => result.diagnostics.filter(d => d.code === 'L4037')
      .map(d => [d.severity, bytes.subarray(d.start, d.end).toString()]);
    assert.deepEqual(messages(lintSync('app.tsx', source)), []);
    assert.deepEqual(messages(lintSync('app.tsx', source, settings)),
      [['error', 'console.log'], ['error', 'console[`lo\\x67`'], ['error', 'console.error']]);
    assert.deepEqual(messages(lintSync('app.tsx', source, { ...settings, includeSuppressions: true })),
      messages(lintSync('app.tsx', source, settings)));
    const logs = 'function write(console) { console.log(); } console.warn(); console.log();';
    assert.deepEqual(lintSync('app.js', logs, { ...settings, fixSuggestions: true }), {
      diagnostics: [], output: 'function write(console) { console.log(); } console.warn(); ',
    });
    const typed = "import type { console } from './types'; (console as Console).log();";
    const typedDiagnostics = lintSync('app.ts', typed, settings).diagnostics.filter(d => d.code === 'L4037');
    assert.deepEqual(typedDiagnostics.map(d => typed.slice(d.start, d.end)), ['(console as Console).log']);
    assert.equal(lintSync('app.ts', typed.replace('import type', 'import'), settings)
      .diagnostics.filter(d => d.code === 'L4037').length, 0);
    for (const option of [null, { allow: 'warn' }, { allow: [42] }, { allowed: [] }]) {
      assert.throws(() => lintSync('app.js', '', { rules: { 'no-console': ['warn', option] } }), TypeError);
    }
    passed++;
  } catch (e) { console.error('FAIL: no-console binding resolution, allowlist and byte spans', e); failed++; }

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

  try {
    for (const newline of ['\n', '\r\n', '\r', '\u2028', '\u2029']) {
      const source = ['/* 🔍 */', '// oxlint-disable-next-line no-console, no-debugger -- test',
        'debugger;', 'debugger;'].join(newline);
      const { diagnostics } = lintSync('directives.js', source, { reportUnusedDisableDirectives: 'error' });
      assert.deepEqual(diagnostics.map(d => [d.code, d.line, d.column, d.severity]), [
        ['L2001', 4, 1, 'error'], ['L9001', 2, 29, 'error'],
      ]);
      assert.equal(Buffer.from(source).subarray(diagnostics[1].start, diagnostics[1].end).toString(), 'no-console');
    }
    assert.deepEqual(lintSync('empty.js', '// oxlint-disable', { reportUnusedDisableDirectives: 'off' }).diagnostics, []);
    assert.throws(() => lintSync('empty.js', '', { reportUnusedDisableDirectives: true }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: lint directive locations and reporting', e); failed++; }

  try {
    const rules = { eqeqeq: ['error', 'always'], 'no-empty': 'off' };
    const source = 'if (π == β) debugger;';
    const safe = lintSync('source.ts', source, { fix: true, rules });
    assert.equal(safe.output, 'if (π == β) {}');
    assert.deepEqual(safe.diagnostics.map(d => [d.code, d.start, d.end]), [['L1003',7,9]]);
    assert.deepEqual(lintSync('source.ts', source, { fixDangerously: true, rules }),
      { diagnostics: [], output: 'if (π === β) {}' });
    assert.deepEqual(lintSync('input.js', 'debugger;', { fix: true }), { diagnostics: [], output: '' });
    assert.deepEqual(lintSync('input.js', '', { fix: true }), { diagnostics: [] });
    const unused = '// oxlint-disable-next-line eqeqeq\nvoid 0;';
    assert.deepEqual(lintSync('input.js', unused, { fixSuggestions: true, reportUnusedDisableDirectives: 'warn' }),
      { diagnostics: [], output: 'void 0;' });
    const broken = lintSync('input.js', 'debugger; const x = /(/;', { fix: true });
    assert.equal(broken.output, undefined);
    assert.ok(broken.diagnostics.some(d => d.code === 'K1012'));
    assert.throws(() => lintSync('input.js', '', { fix: 'all' }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: lint autofix outputs and locations', e); failed++; }

  try {
    const source = '/*🚀*/ let value = 1; debugger; void (a == b || typeof a == "string");';
    const rules = { 'prefer-const': 'warn', eqeqeq: 'warn' };
    const text = Buffer.from(source);
    const expected = [['debugger;', 'debugger;', ''], ['==', undefined, undefined],
      ['==', '==', '==='], ['value', 'let', 'const']];
    for (const workspaceRoot of [undefined, __dirname]) {
      const options = { includeFixes: true, rules, workspaceRoot };
      const results = lintSync('unsaved.js', source, options);
      assert.equal(results.output, undefined);
      assert.deepEqual(results.diagnostics.map(d => [
        text.toString('utf8', d.start, d.end), d.fix && text.toString('utf8', d.fix.start, d.fix.end), d.fix?.text,
      ]), expected);
      const plain = lintSync('unsaved.js', source, { rules, workspaceRoot });
      assert.deepEqual(results.diagnostics.map(({ fix, ...diagnostic }) => diagnostic), plain.diagnostics);
      assert.ok(plain.diagnostics.every(d => !Object.hasOwn(d, 'fix')));
      const invalid = lintSync('bad.js', 'debugger; const value = ;', options);
      assert.ok(invalid.diagnostics.every(d => !Object.hasOwn(d, 'fix')));
      assert.deepEqual(lintSync('off.js', '// oxlint-disable-next-line no-debugger\ndebugger;', options).diagnostics, []);
    }
    assert.throws(() => lintSync('input.js', '', { includeFixes: 'all' }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: individual safe lint edits', e); failed++; }

  try {
    const options = { includeSuppressions: true, rules: { eqeqeq: 'warn', 'no-debugger': 'warn' } };
    const cases = [
      ['view.tsx', 'const v = <C\n  title={a == b}\n>\n  {/*🚀*/ x == y}<b/>\n</C>;', 2],
      ['view.tsx', 'const v = <C title="line\nnext" nested={<B value={a == b}/>} />;', 1],
      ['view.js', 'const v = `raw\n${a == b}\nend`; // trailing', 1],
      ['line.js', '// oxlint-disable-next-line no-debugger\r\ndebugger; void (x == y); // keep', 1],
      ['line.js', 'void ((left)\n==\n(right));', 1],
    ];
    for (const [filename, source, count] of cases) {
      const lint = text => lintSync(filename, text, options).diagnostics;
      const initial = lint(source);
      assert.equal(initial.length, count);
      const tree = text => JSON.stringify(parseSync(filename, text).program,
        (key, value) => key === 'start' || key === 'end' ? undefined : value);
      for (const diagnostic of initial) {
        assert.equal(diagnostic.suppression.rule, 'eqeqeq');
        const { start, end, text } = diagnostic.suppression.line;
        assert.equal(start, end);
        const bytes = Buffer.from(source);
        const changed = bytes.toString('utf8', 0, start) + text + bytes.toString('utf8', end);
        assert.equal(tree(changed), tree(source));
        assert.deepEqual(lint(changed).map(d => d.line), initial.filter(d => d.line !== diagnostic.line).map(d => d.line));
      }
    }
    assert.ok(lintSync('bad.js', 'debugger; const x = ;', options).diagnostics.every(d => !d.suppression));
    const unused = lintSync('off.js', '/* oxlint-disable eqeqeq */', { ...options, reportUnusedDisableDirectives: 'warn' });
    assert.equal(unused.diagnostics[0].code, 'L9001');
    assert.equal(unused.diagnostics[0].suppression, undefined);
    const caught = 'let error;\ntry {\n  use(error);\n}\ncatch (error) {\n  use(error);\n}';
    const shadowOptions = { includeSuppressions: true, rules: { 'no-shadow': 'warn' } };
    const [shadow] = lintSync('caught.js', caught, shadowOptions).diagnostics;
    assert.equal(shadow.suppression.rule, 'no-shadow');
    const line = shadow.suppression.line;
    assert.equal(caught.slice(0, line.start).split('\n').length, 5);
    assert.deepEqual(lintSync('caught.js', caught.slice(0, line.start) + line.text + caught.slice(line.end), shadowOptions).diagnostics, []);
    const casesSource = 'switch (x) {\ncase 1: work();\n\ndefault:\n  break;\n}';
    const casesOptions = { includeSuppressions: true, rules: { 'no-fallthrough': 'warn' } };
    const fallthrough = lintSync('switch.js', casesSource, casesOptions).diagnostics.find(d => d.code === 'L2045');
    const caseEdit = fallthrough.suppression.line;
    assert.equal(casesSource.slice(0, caseEdit.start).split('\n').length, 4);
    const switched = casesSource.slice(0, caseEdit.start) + caseEdit.text + casesSource.slice(caseEdit.end);
    assert.ok(!lintSync('switch.js', switched, casesOptions).diagnostics.some(d => d.code === 'L2045'));
    assert.throws(() => lintSync('input.js', '', { includeSuppressions: 1 }), TypeError);
    passed++;
  } catch (error) { console.error('FAIL: lint suppression edits', error); failed++; }

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
    const workspaceRoot = mkdtempSync(join(tmpdir(), 'kessel-lint-project-'));
    try {
      const source = [
        '/* oxlint-disable prefer-const */', 'let first = 1;',
        '/* eslint-enable */', 'let second = 2;',
        '/* oxlint-enable prefer-const */', 'let third = 3;',
      ].join('\n');
      const options = { workspaceRoot, rules: { 'prefer-const': 'warn' }, includeFixes: true };
      writeFileSync(join(workspaceRoot, '.oxlintrc.json'), '{}');
      const lint = () => lintSync('unsaved.js', source, options).diagnostics;
      assert.deepEqual(lint().map(d => [d.line, d.fix.start, d.fix.text]), [[6, source.indexOf('let third'), 'const']]);
      assert.equal(lintSync('unsaved.js', source, {...options, fix: true}).output, source.replace('let third', 'const third'));
      writeFileSync(join(workspaceRoot, 'kessel.lint.json'), '{}');
      assert.deepEqual(lint().map(d => d.line), [4, 6]);
      assert.deepEqual(lintSync('unsaved.js', source, { rules: options.rules }).diagnostics.map(d => d.line), [4, 6]);
    } finally { rmSync(workspaceRoot, { recursive: true, force: true }); }
    passed++;
  } catch (e) { console.error('FAIL: project suppression ranges in diagnostics and fixes', e); failed++; }

  try {
    const workspaceRoot = mkdtempSync(join(tmpdir(), 'kessel-global-settings-'));
    try {
      writeFileSync(join(workspaceRoot, '.oxlintrc.json'), JSON.stringify({
        env: { node: true }, globals: { injected: 'readonly' },
        rules: { 'no-undef': 'error', 'no-global-assign': 'error' },
      }));
      const source = '/*💡*/ injected = process.pid;\nvoid document;\nfunction f(injected) { return ++injected; } f(1);';
      const { diagnostics } = lintSync('unsaved.js', source, { workspaceRoot });
      const spans = diagnostics.map(d => [d.code, d.start, Buffer.from(source).subarray(d.start, d.end).toString()]).sort();
      assert.deepEqual(spans, [['L2006', Buffer.byteLength(source.split('document')[0]), 'document'], ['L2047', 9, 'injected']]);
      assert.equal(existsSync(join(workspaceRoot, 'unsaved.js')), false);
    } finally { rmSync(workspaceRoot, { recursive: true, force: true }); }
    passed++;
  } catch (error) { console.error('FAIL: project globals on an unsaved buffer', error); failed++; }

  try {
    const source = 'void ((π) /* != */ != (β));\nvoid ((x) // ==\n == (y));\n' +
      'void (null === x);\nvoid (typeof x == "string");\nvoid (1 == 2);\nvoid (1n == 2);';
    const operators = rules => lintSync('equality.js', source, {rules}).diagnostics
      .filter(d => d.code === 'L1003').map(d => [d.line, d.column, Buffer.from(source).subarray(d.start, d.end).toString()]);
    assert.deepEqual(operators({eqeqeq:['error','smart']}), [[1,21,'!='],[3,2,'=='],[7,10,'==']]);
    assert.deepEqual(operators({eqeqeq:['warn','always',{null:'never'}]}).filter(x => x[0] === 4), [[4,12,'===']]);
    assert.equal(operators({eqeqeq:'allow'}).length, 0);
    assert.throws(() => lintSync('bad.js', '', {rules:{eqeqeq:['error','sometimes']}}), TypeError);
    assert.throws(() => lintSync('bad.js', '', {rules:{eqeqeq:['error','always',{null:'bad'}]}}), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: equality rule settings and operator spans', e); failed++; }

  try {
    const source = "/* π */ export const [primary, { property: nested }] = data;" +
      " export {primary as alias}; const lazy = import('./other.js');";
    const scan = scanModuleSync(source);
    assert.equal(scan.has_module_syntax, true);
    assert.deepEqual(scan.exports.map(item => [item.name, item.local_name]), [
      ['primary', 'primary'], ['nested', 'nested'], ['alias', 'primary'],
    ]);
    assert.equal(scan.dependencies[0].name, './other.js');
    const span = scan.exports[0].span;
    assert.equal(Buffer.from(source).subarray(span.start, span.end).toString(), 'primary');
    assert.deepEqual(scanModuleSync('').dependencies, []);
    assert.throws(() => scanModuleSync("import('incomplete'"), { name: 'SyntaxError', code: 'Invalid_Syntax' });
    passed++;
  } catch (e) { console.error('FAIL: scanModuleSync:', e.message); failed++; }

  try {
    const regex = parseRegExpSync('(?<group>π+)', 'u');
    assert.equal(regex.capture_count, 1);
    const alt = regex.nodes[regex.nodes[regex.root].first_child];
    assert.equal(regex.nodes[alt.first_child].group_kind, 'Named_Capture');
    assert.equal(parseRegExpSync('').capture_count, 0);
    assert.throws(() => parseRegExpSync('a', 'uv'), {
      name: 'SyntaxError', code: 'Invalid_Flags', offset: 1,
    });
    passed++;
  } catch (e) { console.error('FAIL: parseRegExpSync:', e.message); failed++; }

  try {
    const source = 'const typed: number = 12; globalThis.value = <><span>{typed}</span></>;';
    const jsx = { runtime: 'classic', pragma: 'ui.make', pragmaFrag: 'ui.fragment', pure: false };
    const result = transformSync('entry.tsx', source, { jsx, sourceMap: true, minified: true });
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.map.sourcesContent, [source]);
    assert.doesNotMatch(result.code, /__PURE__/);
    const state = {};
    new Function('globalThis', 'ui', result.code)(state, { make: (...args) => args, fragment: 'fragment' });
    assert.deepEqual(state.value, ['fragment', null, ['span', null, 12]]);
    assert.match(transformSync('entry.tsx', source).code, /<span>/);
    const bad = transformSync('bad.jsx', '<svg:path />', { jsx: 'classic' });
    assert.equal(bad.code, '');
    assert.deepEqual([bad.errors[0].start, bad.errors[0].end], [1, 9]);
    assert.ok(transformSync('invalid.tsx', 'const =').errors.length);
    assert.deepEqual(transformSync('lib.d.ts', 'export declare const value: number;'), { code: '', map: null, errors: [] });
    assert.throws(() => transformSync('bad.jsx', '', { jsx: { runtime: 'other' } }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: transformSync:', e.message); failed++; }

  try {
    const source = 'function render(factory, fragment, LongWidget){return <><LongWidget></LongWidget></>;}';
    const jsx = { pragma: 'factory.make', pragmaFrag: 'fragment' };
    const result = minifySync('unsaved.jsx', source, { jsx, sourceMap: true });
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.map.sourcesContent, [source]);
    assert.doesNotMatch(result.code, /LongWidget/);
    assert.match(result.code, /render\(factory,fragment,/);
    const lowered = transformSync('unsaved.jsx', result.code, { jsx: { runtime: 'classic', ...jsx } });
    assert.deepEqual(lowered.errors, []);
    const render = compileFunction(lowered.code + ';return render;')();
    assert.deepEqual(render({ make: (tag, props, ...children) => [tag, ...children] }, 'frag', 'view'), ['frag', ['view']]);
    assert.throws(() => minifySync('f.jsx', source, { jsx: { pragma: 'a..b' } }), /pragma binding/);
    assert.throws(() => minifySync('f.jsx', source, { jsx: { pragmaFrag: false } }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: minifySync JSX:', e.message); failed++; }

  try {
    const source = '#!/usr/bin/env node\nfunction sum(longInput){return longInput + 6 * 7;}';
    for (const compress of [false, true]) for (const mangle of [false, true]) {
      const result = minifySync('unsaved.js', source, { compress, mangle, sourceMap: true });
      assert.deepEqual(result.errors, []);
      assert.ok(result.code.startsWith('#!/usr/bin/env node\n'));
      assert.equal(result.code.includes('6*7'), !compress);
      assert.equal(result.code.includes('longInput'), !mangle);
      assert.deepEqual(result.map.sourcesContent, [source]);
      assert.equal(compileFunction(result.code.slice(result.code.indexOf('\n')) + ';return sum(2);')(), 44);
    }
    assert.deepEqual(minifySync('empty.js', ''), { code: '', map: null, errors: [] });
    const bad = '/*🌱*/ x += ;';
    const invalid = minifySync('buffer.js', bad, { sourceMap: true });
    assert.equal(invalid.code, '');
    assert.equal(invalid.map, null);
    assert.deepEqual(invalid.errors, [{ start: Buffer.byteLength(bad) - 1, end: Buffer.byteLength(bad), message: 'Expected expression after assignment operator' }]);
    assert.throws(() => minifySync('a.js', null), TypeError);
    assert.throws(() => minifySync('a.js', '', { mangle: 1 }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: minifySync:', e.message); failed++; }

  try {
    const source = 'globalThis.node = <section key={2}>Hello</section>;';
    const importSource = 'custom/"quoted"';
    const jsx = { runtime: 'automatic', importSource };
    const result = transformSync('entry.tsx', source, { jsx, sourceMap: true });
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.map.sourcesContent, [source]);
    const state = {};
    new Function('require', 'globalThis', result.code)(specifier => {
      assert.equal(specifier, importSource + '/jsx-runtime');
      return { jsx: (tag, props, key) => ({ tag, props, key }) };
    }, state);
    assert.deepEqual(state.node, { tag: 'section', props: { children: 'Hello' }, key: 2 });
    const esm = transformSync('entry.tsx', 'export const item = <i/>;', { jsx: 'automatic' });
    assert.deepEqual(esm.errors, []);
    assert.match(esm.code, /import \{jsx as \w+\} from "react\/jsx-runtime"/);
    assert.throws(() => transformSync('entry.jsx', source, { jsx: { ...jsx, importSource: '' } }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: transformSync automatic JSX:', e.message); failed++; }

  try {
    const source = 'const name = "🎉";\nglobalThis.node = <p key={name} />;';
    const filename = 'nested/view.tsx';
    for (const runtime of ['classic', 'automatic']) {
      const result = transformSync(filename, source, { jsx: { runtime, development: true } });
      assert.deepEqual(result.errors, []);
      const state = {};
      new Function('globalThis', 'React', 'require', result.code)(state, {
        createElement: (tag, props) => props.__source,
      }, specifier => {
        assert.equal(specifier, 'react/jsx-dev-runtime');
        return { jsxDEV: (tag, props, key, multiple, location) => location };
      });
      assert.deepEqual(state.node, { fileName: filename, lineNumber: 2, columnNumber: 19 });
    }
    assert.throws(() => transformSync(filename, source, { jsx: { runtime: 'automatic', development: 'yes' } }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: transformSync development JSX:', e.message); failed++; }

  try {
    const source = 'const enum Size { A = 3, B = A << 2 }; globalThis.value = Size["B"];';
    const typescript = { optimizeConstEnums: true };
    const result = transformSync('size.ts', source, { typescript, sourceMap: true });
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.map.sourcesContent, [source]);
    assert.doesNotMatch(result.code, /var Size/);
    const state = {};
    new Function('globalThis', result.code)(state);
    assert.equal(state.value, 12);
    assert.match(transformSync('size.ts', source).code, /var Size/);
    assert.throws(() => transformSync('size.ts', source, { typescript: { optimizeConstEnums: 1 } }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: transformSync const enums:', e.message); failed++; }

  try {
    const source = 'function execute(events) { using r = { [Symbol.dispose || Symbol.for("Symbol.dispose")]() { events.push(this.id); }, id: 3 }; events.push(1); }';
    const result = transformSync('resources.cjs', source, { explicitResourceManagement: true, sourceMap: true });
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.map.sourcesContent, [source]);
    const events = [];
    new Function('events', result.code + ';execute(events);')(events);
    assert.deepEqual(events, [1, 3]);
    assert.match(transformSync('resources.cjs', source).code, /using r/);
    assert.throws(() => transformSync('resources.cjs', source, { explicitResourceManagement: 1 }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: transformSync resource lifetimes:', e.message); failed++; }

  try {
    const source = 'declare const MODE: string; globalThis.value = [MODE, (MODE => MODE)("local")];';
    const result = transformSync('options.ts', source, { define: {MODE: '"prod"'}, sourceMap: true });
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.map.sourcesContent, [source]);
    const state = {};
    new Function('globalThis', result.code)(state);
    assert.deepEqual(state.value, ['prod', 'local']);
    for (const define of [null, [], {MODE: 2}]) {
      assert.throws(() => transformSync('options.js', '', {define}), TypeError);
    }
    for (const define of [{'a+b': '1'}, {a: '2); (3'}]) {
      const result = transformSync('options.js', '', {define});
      assert.equal(result.code, '');
      assert.equal(result.errors.length, 1);
      assert.match(result.errors[0].message, /define/);
    }
    passed++;
  } catch (e) { console.error('FAIL: transformSync global defines:', e.message); failed++; }

  const resolverDir = mkdtempSync(join(tmpdir(), 'kessel-npm-resolve-'));
  try {
    const importer = join(resolverDir, 'index.ts');
    const target = join(resolverDir, 'internal.ts');
    const config = join(resolverDir, 'tsconfig.json');
    writeFileSync(importer, '');
    writeFileSync(target, '');
    writeFileSync(config, JSON.stringify({ compilerOptions: { paths: { alias: ['./internal'] } } }));
    writeFileSync(join(resolverDir, 'package.json'), JSON.stringify({ browser: { fs: false } }));
    const result = resolveModuleSync('entry', importer, {
      tsconfig: config, aliases: [{name: 'entry', target: 'alias', exact: true}],
    });
    assert.equal(result.kind, 'file');
    assert.equal(realpathSync(result.path), realpathSync(target));
    assert.equal(resolveModuleSync('./internal.js', importer, { extensionAlias: { '.js': ['.ts', '.js'] } }).path, realpathSync(target));
    assert.throws(() => resolveModuleSync('./internal.ts', importer, { extensionAlias: { '.ts': [] } }), { code: 'Extension_Alias_Not_Found' });
    for (const extensionAlias of [null, [], { '.js': false }, { '.js': [1] }]) {
      assert.throws(() => resolveModuleSync('./internal.js', importer, { extensionAlias }), TypeError);
    }
    mkdirSync(join(resolverDir, 'generated'));
    const generated = join(resolverDir, 'generated', 'view.d.css.ts');
    writeFileSync(generated, 'export {};');
    const virtual = join(resolverDir, 'virtual.json');
    writeFileSync(virtual, JSON.stringify({compilerOptions: {rootDirs: ['.', './generated']}}));
    assert.equal(resolveModuleSync('./view.css', importer, {tsconfig: virtual}).path, realpathSync(generated));
    const lookup = { mode: 'require', extensions: ['.ts'], mainFiles: ['internal'] };
    assert.equal(realpathSync(resolveModuleSync('.', importer, lookup).path), realpathSync(target));
    assert.throws(() => resolveModuleSync('.', importer, { ...lookup, mainFiles: [] }), { code: 'Not_Found' });
    writeFileSync(join(resolverDir, 'script.js'), '');
    assert.throws(() => resolveModuleSync('./script', importer, { ...lookup, extensions: [] }), { code: 'Not_Found' });
    assert.equal(realpathSync(resolveModuleSync('./internal.ts', importer, { extensions: [] }).path), realpathSync(target));
    for (const modules of [resolverDir, [resolverDir], '.', [''], ['missing', '.']]) {
      assert.equal(resolveModuleSync('internal.ts', importer, { modules }).path, realpathSync(target));
    }
    assert.throws(() => resolveModuleSync('internal.ts', importer, { modules: [] }), { code: 'Not_Found' });
    assert.deepEqual(resolveModuleSync('node:fs', importer, { modules: [] }), { kind: 'builtin', path: 'node:fs' });
    for (const modules of [null, [false], ['bad\0root']]) {
      assert.throws(() => resolveModuleSync('internal.ts', importer, { modules }), TypeError);
    }
    assert.throws(() => resolveModuleSync('.', importer, { mainFiles: [''] }), TypeError);
    assert.throws(() => resolveModuleSync('.', importer, { extensions: [null] }), TypeError);
    assert.deepEqual(resolveModuleSync('node:fs', importer), { kind: 'builtin', path: 'node:fs' });
    assert.deepEqual(resolveModuleSync('fs', importer, { browser: true }), { kind: 'ignored', path: '' });
    assert.throws(() => resolveModuleSync('./absent.js', importer), { code: 'Not_Found' });
    assert.throws(() => resolveModuleSync('fs', importer, { conditions: [1] }), TypeError);
    writeFileSync(join(resolverDir, 'package.json'), JSON.stringify({
      name: 'app', main: 'internal.ts', custom: 'script.js',
      toolkit: { entries: { '.': './internal.ts' }, aliases: { '#self': 'app' } },
    }));
    const manifestFields = { exportsFields: [['toolkit', 'entries']], importsFields: ['missing', ['toolkit', 'aliases']] };
    assert.equal(resolveModuleSync('#self', importer, manifestFields).path, realpathSync(target));
    assert.throws(() => resolveModuleSync('#self', importer, { importsFields: [] }), { code: 'Package_Import_Not_Defined' });
    for (const key of ['exportsFields', 'importsFields']) {
      for (const value of [null, 'field', [3], [['ok', false]], Array(1)]) {
        assert.throws(() => resolveModuleSync('app', importer, { [key]: value }), TypeError);
      }
    }
    const fallback = realpathSync(join(resolverDir, 'script.js'));
    assert.equal(resolveModuleSync('.', importer, { mode: 'require', mainFields: 'custom' }).path, fallback);
    assert.equal(resolveModuleSync('.', importer, { mode: 'require', mainFields: [], mainFiles: ['script'] }).path, fallback);
    passed++;
  } catch (e) { console.error('FAIL: resolveModuleSync:', e.message); failed++; }
  finally { rmSync(resolverDir, { recursive: true, force: true }); }

  try {
    const source = "import {type A,B as B}from'pkg';";
    const options = { printWidth: 12, tabWidth: 3, singleQuote: true, trailingComma: 'none' };
    const sample = formatSync('module.ts', source, options);
    for (const [endOfLine, newline] of [['lf', '\n'], ['crlf', '\r\n'], ['cr', '\r']]) {
      assert.equal(formatSync('module.ts', source, {...options, endOfLine}), sample.replaceAll('\n', newline));
    }
    assert.equal(formatSync('module.ts', source + '\r\n', {...options, endOfLine:'auto'}), sample.replaceAll('\n', '\r\n'));
    assert.throws(() => formatSync('module.ts', source, {endOfLine:'invalid'}), TypeError);
    assert.equal(sample, "import {\n   type A,\n   B as B\n} from 'pkg';\n");
    assert.equal(formatSync('module.ts', sample, options), sample);
    const data = 'export const config={name:"web",ports:[80,443]} as const;';
    const expectedData = "export const config = {\n  name: 'web',\n  ports: [80, 443],\n} as const;\n";
    const dataOptions = {printWidth: 26, singleQuote: true, endOfLine: 'crlf'};
    assert.equal(formatSync('config.ts', data, dataOptions), expectedData.replaceAll('\n', '\r\n'));
    assert.equal(formatSync('config.ts', expectedData, {printWidth: 26, singleQuote: true}), expectedData);
    assert.equal(formatSync('empty.js', ''), '');
    assert.throws(() => formatSync('broken.mjs', "import 'm'; import {"), error =>
      error instanceof SyntaxError && error.code === 'Invalid_Syntax' && Number.isInteger(error.offset));
    assert.throws(() => formatSync('module.ts', source, { printWidth: 0 }), RangeError);
    assert.throws(() => formatSync('module.ts', source, { bracketSpacing: null }), TypeError);
    passed++;
  } catch (e) { console.error('FAIL: formatSync:', e.message); failed++; }

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
    assert.equal(secondModule.exports.parseRegExpSync('π').nodes[1].kind, 'Pattern');
    assert.equal(scanModuleSync('export const a = 1;').exports[0].name, 'a');
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
