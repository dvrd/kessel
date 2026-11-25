#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const vm = require('node:vm');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const oracle = process.argv[3];
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-bindings-'));
let comparisons = 0;

// Mark only the byte span where the selected rule should report. Other rules
// can also apply to the same valid program and have independent diagnostics.
const cases = [
  ['no-undef', 'mjs', 'void limit; export default function limit() { return limit; } void limit;'],
  ['no-undef', 'mjs', 'export default (function inner() { return inner; }); void «inner»;'],
  ['no-undef', 'mjs', 'export default async function* limit() { yield limit; } void limit;'],
  ['no-func-assign', 'mjs', 'export default function limit() { «limit» = other; } «limit» = 1;'],
  ['no-import-assign', 'mjs', 'import {x as π} from "lib"; [«π»] = data; function f(π) { π++; }'],
  ['no-import-assign', 'mjs', 'import value from "lib"; value.field = 0; Object.assign(value, {}); for («value» of list) {}'],
  ['no-import-assign', 'mjs', 'import * as ns from "lib"; «ns[key]»++; delete «ns?.field»; ns.field.nested = 0;'],
  ['no-import-assign', 'mjs', 'import * as ns from "lib"; [«ns.field» = 1] = data; ({key: «ns.item»} = data);'],
  ['no-import-assign', 'mjs', 'import * as ns from "lib"; Object.assign(«ns», {}); Reflect["set"](«ns», "key", 1);'],
  ['no-import-assign', 'mjs', 'import * as ns from "lib"; (Object?.defineProperty)(«ns», key, descriptor);'],
  ['no-import-assign', 'mjs', 'import * as ns from "lib"; function f(Reflect) { Reflect.set(ns, key, 1); } Object.assign({}, ns);'],
  ['no-import-assign', 'mjs', 'import * as ns from "lib"; { let ns = {}; ns.x = 1; Object.assign(ns, {}); }'],
  ['no-import-assign', 'ts', 'import type D from "a"; import { type X, value as Y } from "b"; D=1; X=2; «Y»=3;'],
  ['no-import-assign', 'ts', 'import * as ns from "lib"; «(ns satisfies object).x»=1;', false],
  ['no-import-assign', 'mjs', 'import {value} from "pkg"; // eslint-disable-next-line no-import-assign\nvalue++;\n«value»--;'],
  ['no-func-assign', 'mjs', '«f»++; function f(){}; ({ a: «f» = b } = obj); function g(f) { f = 0; }'],
  ['no-func-assign', 'cjs', 'let f; { function f() {} «f»=1; } f=2;'],
  ['no-func-assign', 'cjs', '{ function f() {} «f»++; } «f»=2;'],
  ['no-func-assign', 'cjs', '"use strict"; { function f() {} «f»++; } f=2;'],
  ['no-func-assign', 'mjs', '{ function f() {} «f»++; } f=2;'],
  ['no-func-assign', 'cjs', 'function g(f) { {function f(){} «f»++;} f=2; }'],
  ['no-func-assign', 'mjs', 'const other = function self() { «self»=0; };'],
  ['no-func-assign', 'cjs', 'var f; function f() {} «f» ||= other;'],
  ['no-class-assign', 'mjs', 'let C = class Named { static { «Named»++; } }; C = next;'],
  ['no-class-assign', 'mjs', 'class C { change(C) { C++; } } for («C» in data) {}'],
  ['no-ex-assign', 'mjs', 'try { run(); } catch ({reason}) { (() => { [«reason»] = msg; })(); { let reason; reason++; } }'],
  ['no-const-assign', 'mjs', 'const {key: [v]} = obj; function f(){ «v»++; } { let v; v=2; }'],
  ['no-const-assign', 'mjs', 'function f() { using item = acquire(); «item» ||= other; item.key = 2; }'],
  ['no-const-assign', 'mjs', 'const list=[]; for(const entry of list) { doSomething(entry); }'],
  ['no-const-assign', 'ts', 'const X=1; { type X=number; «X»=2; }'],
  ['no-const-assign', 'ts', 'const x=1; («x» satisfies number) = 3;'],
  ['no-global-assign', 'mjs', 'function f(Object) { Object=1; } {let Math; Math++;} [«Infinity»] = data;'],
  ['no-global-assign', 'mjs', 'const obj={}; obj.String=1; Object.freeze(obj); «String»++;'],
  ['no-param-reassign', 'jsx', 'function f(p){return <Box fn={() => { «p»++; }}/>;}'],
  ['no-param-reassign', 'cjs', 'function g(f=0){var f; «f»=2;}'],
  ['no-param-reassign', 'mjs', 'function g(p){ return function p(){ p=1; }; }'],
  ['no-param-reassign', 'mjs', 'function f(p = (v = 1)) { let v; v++; «p» += v; }'],
  ['no-undef', 'jsx', 'typeof missing; typeof «missing».key; <«View» v={«absent»} />; <«lib».View/>;'],
  ['no-undef', 'mjs', 'function f(x=«inner»){ const inner=1; return x+inner; } f();', 'parameter environment'],
  ['no-undef', 'ts', 'const v: T = ambient; v;', false],
  ['no-unused-vars', 'mjs', 'export function f() { let «write»; write=1; let «updated»=0; updated++; let kept=1; return kept++; }'],
  ['no-unused-vars', 'jsx', 'export function f(){ function Item(){return null;} return <Item/>; }'],
  ['no-unused-vars', 'mjs', 'export function f(){ const factory = function inner() {}; return factory; }'],
  ['no-shadow', 'mjs', 'const v = 0; function f(«v») { return v; } f(v);', false],
  ['no-shadow', 'mjs', 'function f(x=1){var x; x++;}', false],
];

function unpack(marked) {
  let source = '';
  let at = 0;
  const spans = [];
  for (const marker of marked.matchAll(/«([^»]+)»/g)) {
    source += marked.slice(at, marker.index);
    const lines = source.split('\n');
    const col = Buffer.byteLength(lines[lines.length-1]) + 1;
    spans.push([lines.length, col, Buffer.byteLength(marker[1])]);
    source += marker[1];
    at = marker.index + marker[0].length;
  }
  return { source: source + marked.slice(at), spans };
}

function run(engine, rule, file) {
  const args = engine === binary ? ['lint', '--format=json'] : ['--format=json', '-A', 'all'];
  const result = spawnSync(engine, [...args, '-D', rule, file], { cwd: directory, encoding: 'utf8' });
  assert.ok([0, 1].includes(result.status), result.stderr || result.stdout || String(result.error));
  if (engine === binary) {
    const messages = JSON.parse(result.stderr)[0].messages;
    assert.ok(!messages.some(m => m.fatal), JSON.stringify(messages));
    return messages.filter(m => m.ruleId === rule).map(m => [m.line, m.column, m.endColumn - m.column]).sort();
  }
  const messages = JSON.parse(result.stdout).diagnostics;
  assert.ok(messages.every(m => m.code?.includes('(')), JSON.stringify(messages));
  return messages.filter(m => m.code.endsWith('(' + rule + ')')).map(m => {
    const label = m.labels.find(l => l.label?.includes('re-assigned')) ||
      (rule === 'no-unused-vars' ? m.labels[0] : m.labels.at(-1));
    return [label.span.line, label.span.column, label.span.length];
  }).sort();
}

try {
  for (const [rule, ext, marked, compare = true] of cases) {
    const { source, spans } = unpack(marked);
    const file = 'fixture.' + ext;
    fs.writeFileSync(path.join(directory, file), source);
    assert.deepEqual(run(binary, rule, file), spans.sort(), rule + '\n' + marked);
    if (compare === 'parameter environment') {
      assert.throws(() => vm.runInNewContext(source), error => error.name === 'ReferenceError');
      if (oracle) assert.deepEqual(run(oracle, rule, file), []);
    } else if (compare && oracle) {
      assert.deepEqual(run(oracle, rule, file), spans.sort(), 'oxlint ' + rule + '\n' + marked);
      comparisons++;
    }
  }
  console.log(cases.length + ' binding lint cases passed, ' + comparisons + ' compared with oxlint.');
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
