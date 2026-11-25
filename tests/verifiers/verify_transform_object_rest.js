'use strict';

// Lowering of object spread and object rest. object-rest.js is plain
// JavaScript: the log Node prints for it as written is the specification,
// and every lowered output must print the same log. With --reference each
// output is parsed by acorn at its target's grammar level, and TypeScript
// 5.9.3 and OXC 0.127.0 lower the same source; the records each of them
// prints differently are named, and the comparison fails if the set changes.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const fixture = path.resolve(__dirname, '../transform/target/object-rest.js');
const TARGETS = ['es2015', 'es2016', 'es2017'];

// Both references print a loop whose body redeclares a name bound by its
// head as two declarations in one block, which does not parse. TypeScript
// also prints a for-in head with two bindings. Those lines are left out.
const reference_source = {
  typescript: source => source.split('\n').filter(line => !/"loop shadow"|"loop in"/.test(line)).join('\n'),
  oxc: source => source.split('\n').filter(line => !/"loop shadow"/.test(line)).join('\n'),
};
const deviations = {
  // Rest and spread through assignment, which calls a setter and treats a
  // `__proto__` key as the prototype; rest of null does not throw.
  typescript: ['assignment null', 'rest null', 'rest proto key', 'spread proto key', 'spread setter not called'],
  // A `__proto__` key becomes the prototype of the rest object; the object
  // is evaluated ahead of an earlier declarator; `var` in a loop head.
  oxc: ['loop var', 'rest proto key', 'rest several'],
};

// Stand-ins for the @oxc-project/runtime helpers, after @babel/runtime.
const oxc_runtime = {
  defineProperty: 'export default function (e, r, t) { return r in e ? Object.defineProperty(e, r, { value: t, enumerable: true, configurable: true, writable: true }) : e[r] = t, e; }',
  objectSpread2: 'import defineProperty from "./defineProperty.js"; function ownKeys(e, r) { var t = Object.keys(e); if (Object.getOwnPropertySymbols) { var o = Object.getOwnPropertySymbols(e); r && (o = o.filter(function (r) { return Object.getOwnPropertyDescriptor(e, r).enumerable; })), t.push.apply(t, o); } return t; } export default function (e) { for (var r = 1; r < arguments.length; r++) { var t = null != arguments[r] ? arguments[r] : {}; r % 2 ? ownKeys(Object(t), !0).forEach(function (r) { defineProperty(e, r, t[r]); }) : Object.defineProperties(e, Object.getOwnPropertyDescriptors(t)); } return e; }',
  objectWithoutPropertiesLoose: 'export default function (r, e) { if (null == r) return {}; var t = {}; for (var n in r) if ({}.hasOwnProperty.call(r, n)) { if (-1 !== e.indexOf(n)) continue; t[n] = r[n]; } return t; }',
  objectWithoutProperties: 'import loose from "./objectWithoutPropertiesLoose.js"; export default function (e, t) { if (null == e) return {}; var o, r, i = loose(e, t); if (Object.getOwnPropertySymbols) { var n = Object.getOwnPropertySymbols(e); for (r = 0; r < n.length; r++) o = n[r], -1 === t.indexOf(o) && {}.propertyIsEnumerable.call(e, o) && (i[o] = e[o]); } return i; }',
  objectDestructuringEmpty: 'export default function (t) { if (null == t) throw new TypeError("Cannot destructure " + t); }',
  extends: 'export default function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }',
  toPropertyKey: 'export default function (t) { return typeof t === "symbol" ? t : String(t); }',
};

function execute(directory, name, code) {
  const file = path.join(directory, name);
  fs.writeFileSync(file, code);
  const result = spawnSync(process.execPath, [file], { encoding: 'utf8' });
  assert.equal(result.status, 0, name + '\n' + result.stderr.slice(0, 2000));
  return result.stdout;
}

function differing(expected, actual) {
  const records = log => new Map(log.split('\n').filter(line => line.includes(' = '))
    .map(line => [line.slice(0, line.indexOf(' = ')), line.slice(line.indexOf(' = ') + 3)]));
  const produced = records(actual);
  return [...records(expected)].filter(([label, value]) => produced.get(label) !== value).map(([label]) => label).sort();
}

function checkDiagnostics(binary, temp) {
  const cases = [
    ['const { a: { ...inner } } = o;', /nested object rest/],
    ['const [{ ...inner }] = o;', /nested object rest/],
    ['function f([{ ...inner }]) {}', /nested object rest/],
    ['[{ ...inner }] = o;', /nested object rest/],
    ['({ a: { ...inner } } = o);', /nested object rest/],
    ['for ([{ ...inner }] of o) {}', /nested object rest/],
    ['const { [key()]: a, ...rest } = o;', /computed key/],
    ['({ [key()]: a, ...rest } = o);', /computed key/],
    ['function f({ a, ...rest }, later = a) {}', /before one with an initializer/],
    ['function f({ a, ...rest }) { function rest() {} return rest; }', /function in the body redeclares/],
    ['const f = ({ a: { b }, ...rest }) => { function b() {} };', /function in the body redeclares/],
    ['async function f() { ({ a = await 1, ...rest } = o); }', /await or yield/],
    ['const made = { ...o, get value() { return 1; } };', /accessor after an object spread/],
    ['const made = { ...o, __proto__: base };', /__proto__ after an object spread/],
  ];
  const file = path.join(temp, 'rest-diagnostic.js');
  for (const [source, pattern] of cases) {
    fs.writeFileSync(file, source);
    const result = spawnSync(binary, ['transform', file, '--target=es2017'], { encoding: 'utf8' });
    assert.equal(result.status, 1, source);
    assert.equal(result.stdout, '', source);
    assert.match(result.stderr, pattern, source);
  }
  // Before any spread these are part of the literal and need no lowering.
  fs.writeFileSync(file, 'const made = { __proto__: base, get value() { return 1; }, ...o };');
  assert.equal(spawnSync(binary, ['transform', file, '--target=es2017']).status, 0);
  fs.writeFileSync(file, 'const { a, ...rest } = { ...o };');
  const kept = spawnSync(binary, ['transform', file, '--target=es2018', '--minified'], { encoding: 'utf8' });
  assert.equal(kept.stdout.trim(), 'const {a,...rest}={...o};');
  return cases.length;
}

module.exports = function verifyObjectRest(binary, temp, run, oracle) {
  const directory = fs.mkdtempSync(path.join(temp, 'object-rest-'));
  const source = fs.readFileSync(fixture, 'utf8');
  const expected = execute(directory, 'native.mjs', source);
  let outputs = 0;
  for (const target of TARGETS) {
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', fixture, '--target=' + target, ...flags]);
      assert.equal(execute(directory, 'kessel.mjs', code), expected, ['object-rest.js', target, ...flags].join(' '));
      outputs += 1;
      if (!oracle) continue;
      const acorn = require('../../bench/node_modules/acorn');
      acorn.parse(code, { ecmaVersion: Number(target.slice(2)), sourceType: 'module' });
    }
  }
  if (oracle) {
    const helpers = path.join(directory, 'node_modules/@oxc-project/runtime/helpers');
    fs.mkdirSync(helpers, { recursive: true });
    fs.writeFileSync(path.join(helpers, '../package.json'), JSON.stringify({
      name: '@oxc-project/runtime', type: 'module', exports: { './helpers/*': './helpers/*.js' },
    }));
    for (const [name, code] of Object.entries(oxc_runtime)) fs.writeFileSync(path.join(helpers, name + '.js'), code);
    const ts = require('../../bench/node_modules/typescript');
    for (const target of ['es2015', 'es2017']) {
      const for_typescript = reference_source.typescript(source);
      const compiled = ts.transpileModule(for_typescript, { fileName: 'object-rest.js',
        compilerOptions: { target, module: 'ESNext', allowJs: true } });
      assert.deepEqual(differing(execute(directory, 'native.mjs', for_typescript),
        execute(directory, 'typescript.mjs', compiled.outputText)), deviations.typescript, 'TypeScript ' + target);
      const for_oxc = reference_source.oxc(source);
      const reference = oracle.transformSync('object-rest.js', for_oxc, { target });
      assert.deepEqual(reference.errors, []);
      assert.deepEqual(differing(execute(directory, 'native.mjs', for_oxc),
        execute(directory, 'oxc.mjs', reference.code)), deviations.oxc, 'OXC ' + target);
    }
  }
  const diagnostics = checkDiagnostics(binary, temp);
  const compared = oracle ? ` acorn accepted each at its target level. TypeScript and OXC agreed except on ` +
    `${deviations.typescript.length} and ${deviations.oxc.length} named records.` : '';
  console.log(`Object rest and spread matched unlowered execution in ${outputs} outputs, with ` +
    `${diagnostics} diagnostics.${compared}`);
};
