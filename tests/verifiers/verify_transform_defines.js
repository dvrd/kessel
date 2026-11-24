'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { SourceMap } = require('node:module');

module.exports = function verifyDefines(binary, temp, run, oracle) {
  function check(name, source, define, expected, { reference = true, jsx = false } = {}) {
    const file = path.join(temp, name);
    fs.writeFileSync(file, source);
    const interpreter = ['--input-type=' + (name.endsWith('.cjs') ? 'commonjs' : 'module')];
    const args = Object.entries(define).flatMap(([name, value]) => ['--define', name + '=' + value]);
    if (jsx) args.push('--jsx=classic');
    for (const mode of [[], ['--minified']]) {
      const generated = run(binary, ['transform', file, ...args, ...mode]);
      assert.deepEqual(JSON.parse(run(process.execPath, interpreter, generated)), expected, name);
    }
    if (oracle && reference) {
      const result = oracle.transformSync(file, source, { define, jsx: { runtime: 'classic' } });
      assert.deepEqual(result.errors, []);
      assert.deepEqual(JSON.parse(run(process.execPath, interpreter, result.code)), expected, name);
    }
  }

  verifyRuntime(check);

  const source = 'export const values = ["🎉", FIRST, SECOND, tail];';
  const file = path.join(temp, 'mapped.mjs');
  fs.writeFileSync(file, source);
  for (const mode of [[], ['--minified']]) {
    const generated = run(binary, ['transform', file, '--define=FIRST=21', '--define=SECOND={x:"🎉"}', '--sourcemap', ...mode]);
    const [code, base64] = generated.split('//# sourceMappingURL=data:application/json;base64,');
    const map = new SourceMap(JSON.parse(Buffer.from(base64.trim(), 'base64')));
    for (const [start, spelling] of [['(21)', 'FIRST'], ['({', 'SECOND'], ['tail', 'tail']]) {
      const offset = code.indexOf(start);
      assert.ok(offset >= 0);
      const lines = code.slice(0, offset).split('\n');
      const entry = map.findEntry(lines.length-1, lines.at(-1).length);
      assert.deepEqual([entry.originalLine, entry.originalColumn], [0, source.indexOf(spelling)]);
    }
  }
  for (const invalid of ['bad..name=1', 'foo.*=1', 'A=if', 'A=2);(3', 'A=']) {
    const result = spawnSync(binary, ['transform', file, '--define', invalid], {encoding:'utf8'});
    assert.ok(result.status > 0);
    assert.match(result.stderr, /define/i);
    assert.equal(result.stdout, '');
  }
  fs.writeFileSync(file, 'export function f() { return FLAG; }');
  const invalidContext = spawnSync(binary, ['transform', file, '--define', 'FLAG=await 3'], {encoding:'utf8'});
  assert.equal(invalidContext.status, 1);
  assert.match(invalidContext.stderr, /define replacement.*await/);
  assert.equal(invalidContext.stdout, '');
  console.log('Global defines passed scope, runtime, write-target, configuration and source-map checks in both printers.');
};

function verifyRuntime(check) {
  check('globals.ts', [
    'declare const FLAG: number;',
    'const p = {FLAG, ["fixed"]: process?.env["MODE"]};',
    'function outer(process) { const f = () => FLAG; var FLAG = 4; return [f(), process.env.MODE]; }',
    'const pair = () => [VALUE, VALUE]; const [a,b] = pair(); a.x++;',
    'console.log(JSON.stringify([2 * FLAG, p, outer({env:{MODE:"local"}}), a.x, b.x, a === b]));',
  ].join('\n'), { FLAG: '1 + 2', 'process.env.MODE': '"prod"', VALUE: '{x:1}' },
  [6, {FLAG: 3, fixed: 'prod'}, [4, 'local'], 2, 1, false]);

  check('meta.mjs', [
    'console.log(JSON.stringify([import.meta.env.MODE, import.meta.env.UNKNOWN,',
    'import.meta.env.UNKNOWN.length, import.meta.build]));',
  ].join('\n'), {'import.meta.env.*': '"any"', 'import.meta.env.MODE': '"prod"', 'import.meta.build': '7'},
  ['prod', 'any', 3, 7]);
  check('computed.mjs', 'console.log(JSON.stringify(import.meta["env"].MODE));',
    {'import.meta.env.MODE': '"prod"'}, 'prod', {reference: false});

  check('this.mjs', [
    'const arrow = () => this.name;',
    'function ordinary() { return (() => this.name)(); }',
    'class Local { [this.name]() { return 5; } name = 9; value = this.name; static { this.nameSeen = this.name; } }',
    'console.log(JSON.stringify([arrow(), ordinary.call({name:"own"}), new Local().field(), new Local().value, Local.nameSeen]));',
  ].join('\n'), {'this.name': '"field"'}, ['field', 'own', 5, 9, 'Local'], {reference: false});

  check('writes.mjs', [
    'const target = {x:0}, obj = {keep:1};',
    'ALIAS = 2; ALIAS++; for (ALIAS of [5]) {}',
    '({ALIAS} = {ALIAS:7});',
    'const data = {__proto__}; delete obj.keep;',
    'console.log(JSON.stringify([target.x, Object.hasOwn(data, "__proto__"), data.__proto__, obj.keep]));',
  ].join('\n'), { ALIAS: 'target.x', ['__proto__']: '23', 'obj.keep': '42'}, [7, true, 23, null], {reference: false});

  check('protected.cjs', [
    'globalThis.FLAG = 80; function dynamic() { eval("var FLAG = 6"); return FLAG; }',
    'let inside; with ({FLAG:4}) { inside = FLAG; }',
    'function args() { return arguments[0]; }',
    'console.log(JSON.stringify([FLAG, dynamic(), inside, args(9), typeof MISSING, typeof FLAG]));',
  ].join('\n'), { FLAG: '3', 'typeof MISSING': '"custom"', arguments: '[]'}, [3, 6, 4, 9, 'custom', 'number'], {reference: false});

  check('jsx.tsx', [
    'declare const LABEL: string; const h = (tag, props, value) => [tag,value];',
    'console.log(JSON.stringify(<span>{LABEL}</span>));',
  ].join('\n'), {'React.createElement': 'h', LABEL: '"ready"'}, ['span','ready'], {jsx: true});

  check('values.mjs', [
    'globalThis.STEP = 5; globalThis.KEEP = 0;',
    'KEEP = 7; const make = () => [SUM, ORDER, RAW];',
    'console.log(JSON.stringify([globalThis.KEEP, ...make()]));',
  ].join('\n'), {KEEP: 'false', SUM: '1 + 2 // comment', ORDER: '0, 8', RAW: 'STEP', STEP: '100'}, [7, 3, 8, 5]);
  check('delete.mjs', 'globalThis.BOX = {x:1}; delete BOX.x; console.log(JSON.stringify([BOX.x, globalThis.BOX.x]));',
    {'BOX.x': 'globalThis.result'}, [null, 1], {reference: false});
  check('delete-alias.mjs', 'globalThis.BOX = {x:1}; delete BOX.x; console.log(JSON.stringify(Object.keys(BOX)));',
    {'BOX.x': 'alias'}, [], {reference: false});

  check('await.mjs', 'console.log(JSON.stringify(FLAG));', {FLAG: 'await Promise.resolve(3)'}, 3, {reference: false});
}
