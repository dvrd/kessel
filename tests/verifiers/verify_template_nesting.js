'use strict';

// Template-literal nesting gate.
//
// Goal: kessel must agree with the JavaScript engine running this script
// (V8, via `new vm.Script`) on whether deeply nested template literals and
// interpolations holding many open braces are valid programs.
//
// Background: the lexer used to track `${ }` interpolations in `[8]u8`, so
// nesting depth 9 and 256 simultaneously open `{` were mis-lexed and valid
// code was rejected. It now tracks any depth up to a documented cap
// (TEMPLATE_DEPTH_MAX in src/lexer.odin) and reports K1016 beyond it.
//
// Method: generate each program, ask V8 whether it compiles, run
// `kessel parse` on the same bytes, and compare the two decisions. The only
// permitted disagreement is above the cap, where kessel must reject with
// exactly one K1016 diagnostic (a resource limit, not a syntax rule).
//
// Usage: node verify_template_nesting.js [path/to/kessel]

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const TEMPLATE_DEPTH_MAX = 256; // keep in sync with src/lexer.odin

// `depth` template literals, each inside the interpolation of the previous.
function nested(depth, innermost = '0') {
  let source = innermost;
  for (let level = 0; level < depth; level += 1) source = '`a${' + source + '}b`';
  return `var x = ${source};\n`;
}

// One interpolation with `count` object-literal braces open at once.
function braces(count) {
  return 'var x = `a${' + '{a:'.repeat(count) + '1' + '}'.repeat(count) + '}b`;\n';
}

// Speculative parses (arrow-function parameter lists that turn out to be, or
// not to be, arrows) inside deep nesting: the parser snapshots and restores
// the lexer here, which must preserve the interpolation state exactly.
const speculation =
  '[((a = `${`${ {b: {c: 1}}.b.c }`}`, d) => a)(), (1, `${`${ {b: 1}.b }`}`), ' +
  'async (e = `${ {f: `${1}`}.f }`) => e]';

const cases = [
  ['nesting depth 8', nested(8)],
  ['nesting depth 9', nested(9)],
  ['nesting depth 30', nested(30)],
  ['nesting depth 64', nested(64)],
  ['nesting depth 255', nested(TEMPLATE_DEPTH_MAX - 1)],
  ['nesting depth 256 (at the cap)', nested(TEMPLATE_DEPTH_MAX)],
  ['open braces 255', braces(255)],
  ['open braces 256', braces(256)],
  ['open braces 300', braces(300)],
  ['open braces 1000', braces(1000)],
  ['speculation at depth 12', nested(12, speculation)],
  ['unterminated interpolation', 'var x = `a${`b${1}`;\n'],
  ['stray closing brace', 'var x = `a${1}}`}`;\n'],
  ['nesting depth 257 (over the cap)', nested(TEMPLATE_DEPTH_MAX + 1), 'over-cap'],
  ['nesting depth 2000 (over the cap)', nested(2000), 'over-cap'],
];

function engineAccepts(source) {
  try {
    new vm.Script(source);
    return true;
  } catch (error) {
    assert.equal(error.name, 'SyntaxError', `unexpected engine failure: ${error}`);
    return false;
  }
}

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-template-'));
try {
  for (const [name, source, kind] of cases) {
    const file = path.join(directory, 'case.js');
    fs.writeFileSync(file, source);
    // 1000 open braces are 1000 nested object literals, which is deeper than
    // the parser's default nesting limit of 512. This gate is about the lexer's
    // brace counters, so lift the parser limit out of the way.
    const result = spawnSync(binary, ['parse', '--max-depth=4096', file], {
      encoding: 'utf8', env: { ...process.env, KESSEL_COLOR: '0', NO_COLOR: '1' },
    });
    assert.equal(result.signal, null, `${name}: kessel died with ${result.signal}`);
    assert.ok(result.status === 0 || result.status === 1, `${name}: exit ${result.status}`);
    const kesselAccepts = result.status === 0;
    const engine = engineAccepts(source);
    if (kind === 'over-cap') {
      assert.equal(engine, true, `${name}: the engine is expected to accept`);
      assert.equal(kesselAccepts, false, `${name}: kessel must refuse above the cap`);
      const codes = result.stderr.match(/K\d{4}/g) || [];
      assert.deepEqual(codes, ['K1016'], `${name}: expected only K1016, got ${codes}`);
    } else {
      assert.equal(kesselAccepts, engine,
        `${name}: engine ${engine ? 'accepts' : 'rejects'}, kessel ` +
        `${kesselAccepts ? 'accepts' : 'rejects'}\n${result.stderr.slice(0, 400)}`);
    }
    console.log(`ok - ${name}: engine=${engine ? 'accept' : 'reject'} ` +
      `kessel=${kesselAccepts ? 'accept' : 'reject'}`);
  }
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
console.log(`template nesting: ${cases.length} cases agree with ${process.version}`);
