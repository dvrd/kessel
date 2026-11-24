'use strict';

// React Fast Refresh instrumentation. The fixture runs against recorders for
// $RefreshReg$ and $RefreshSig$ and a minimal "react" package, and prints what
// the runtime was told. Handle names and their order are an implementation
// detail, so the log lists registrations and per-handle call sequences in
// sorted order. Both Kessel printers must reproduce the recorded log; with
// --reference the pinned OXC transformer must produce the same one.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { SourceMap } = require('node:module');

const fixtures = path.resolve(__dirname, '../transform/refresh');

const preamble = `
const registrations = [];
const handles = [];
const describe = value => {
  // An arrow assigned to a registration handle is named after the handle.
  if (typeof value === 'function') return 'function ' + (value.name.replace(/^_c\\d*$/, '') || '(anonymous)');
  if (value && typeof value === 'object') return 'object {' + Object.keys(value).sort().join(',') + '}';
  return String(value);
};
globalThis.$RefreshReg$ = (type, id) => { registrations.push(id + ' <- ' + describe(type)); };
globalThis.$RefreshSig$ = () => {
  const calls = [];
  handles.push(calls);
  return function (type, key, force, getHooks) {
    if (arguments.length === 0) { calls.push('render'); return undefined; }
    const hooks = typeof getHooks === 'function' ? getHooks().map(describe).join(', ') : 'none';
    calls.push('sign ' + describe(type) + ' key=' + key + ' force=' + force + ' hooks=[' + hooks + ']');
    return type;
  };
};
process.on('exit', () => {
  console.log(registrations.sort().join('\\n'));
  console.log(handles.map(calls => calls.join('\\n  ')).sort().join('\\n'));
});
`;

const react = `
export const useState = initial => [typeof initial === 'function' ? initial() : initial, () => {}];
export const useReducer = (reducer, initial) => [initial, () => {}];
export const useRef = current => ({ current });
export const useEffect = () => {};
export const useCallback = callback => callback;
export const memo = component => ({ memo: component });
export const forwardRef = render => ({ forwardRef: render });
export class Component {}
export default { useState, useReducer, useRef, useEffect, useCallback, memo, forwardRef, Component };
`;
const runtime = 'export const jsx = (type, props) => ({ type, props });\nexport const jsxs = jsx;\n' +
  'export const Fragment = "fragment";\n';

function prepare(directory) {
  const packageRoot = path.join(directory, 'node_modules/react');
  fs.mkdirSync(packageRoot, { recursive: true });
  fs.writeFileSync(path.join(packageRoot, 'package.json'), JSON.stringify({
    name: 'react', type: 'module', exports: { '.': './index.js', './jsx-runtime': './jsx-runtime.js' },
  }));
  fs.writeFileSync(path.join(packageRoot, 'index.js'), react);
  fs.writeFileSync(path.join(packageRoot, 'jsx-runtime.js'), runtime);
  fs.writeFileSync(path.join(directory, 'preamble.mjs'), preamble);
  fs.copyFileSync(path.join(fixtures, 'hooks.mjs'), path.join(directory, 'hooks.mjs'));
}

function execute(directory, name, code) {
  const file = path.join(directory, name);
  fs.writeFileSync(file, code);
  const result = spawnSync(process.execPath, ['--import', path.join(directory, 'preamble.mjs'), file], { encoding: 'utf8' });
  assert.equal(result.status, 0, name + '\n' + result.stderr);
  return result.stdout;
}

const flags = ['--jsx=automatic', '--react-refresh'];

function checkOptions(binary, temp, run) {
  const file = path.join(temp, 'refresh-options.jsx');
  const source = 'import { useState } from "react";\nimport { useOther } from "./other";\n' +
    'export function View() { const [open, setOpen] = useState(false); useOther(open); return null; }\n';
  fs.writeFileSync(file, source);
  const plain = run(binary, ['transform', file]);
  assert.doesNotMatch(plain, /\$Refresh/);
  const full = run(binary, ['transform', file, '--react-refresh', '--refresh-full-signatures',
    '--refresh-reg=import.meta.hot.register', '--refresh-sig=window.signature']);
  assert.match(full, /= window\.signature\(\)/);
  assert.match(full, /import\.meta\.hot\.register\(_c, "View"\)/);
  assert.match(full, /"useState\{\[open, setOpen\]\(false\)\}\\\\nuseOther\{\}", false, function\s*\(\) \{\s*return \[useOther\];?\s*\}/);
  // A reset comment anywhere in the file forces every signature to remount.
  fs.writeFileSync(file, '// @refresh reset\n' + source);
  assert.match(run(binary, ['transform', file, '--react-refresh', '--refresh-full-signatures']), /\\\\nuseOther\{\}", true, function/);
  // Generated names avoid bindings the file already has.
  fs.writeFileSync(file, 'const _s = 1, _c = 2, _s2 = 3;\n' + source + 'console.log(_s, _c, _s2);');
  const renamed = run(binary, ['transform', file, '--react-refresh']);
  assert.match(renamed, /const _s = 1, _c = 2, _s2 = 3;/);
  assert.match(renamed, /\$RefreshReg\$\(_c2, "View"\)/);
  assert.match(renamed, /_s3 = \$RefreshSig\$\(\)/);
  // A method cannot be wrapped without turning it into a function-valued
  // property, so its Hook calls go unreported. OXC 0.127.0 rewrites the method.
  fs.writeFileSync(file, 'import { useOther } from "./other";\n' +
    'export const table = { Cell() { return useOther(); }, get value() { return useOther(); } };\n' +
    'export class View { render() { return useOther(); } static make() { return useOther(); } }\n');
  assert.doesNotMatch(run(binary, ['transform', file, '--react-refresh']), /\$Refresh/);
  for (const invalid of ['--refresh-reg=a..b', '--refresh-sig=']) {
    assert.equal(spawnSync(binary, ['transform', file, '--react-refresh', invalid]).status, 2, invalid);
  }
}

// In minified input an identifier can start exactly where a function ends.
// The handle placed there must not pick up that identifier's namespace prefix.
function checkAdjacentIdentifier(binary, directory, run) {
  const file = path.join(directory, 'adjacent.ts');
  fs.writeFileSync(file, 'import {useCustom} from "./hooks.mjs";const out:string[]=[];' +
    'namespace N{export const go=()=>out.push("go");export function Comp(){useCustom(1);return 1}go()}' +
    'function App(){useCustom(2)}N.go();App();N.Comp();console.log(out.join())\n');
  for (const mode of [[], ['--minified']]) {
    const code = run(binary, ['transform', file, '--react-refresh', ...mode]);
    assert.match(execute(directory, 'adjacent.mjs', code), /^go,go\n/);
  }
}

// Instrumentation statements map near the function they describe.
function checkSourceMap(binary, temp, run) {
  const file = path.join(temp, 'refresh-map.jsx');
  const source = 'import { useThing } from "x";\nfunction First() {\n  return useThing(1);\n}\n' +
    'const Second = () => useThing(2);\n';
  fs.writeFileSync(file, source);
  for (const mode of [[], ['--minified']]) {
    const generated = run(binary, ['transform', file, '--react-refresh', '--sourcemap', ...mode]);
    const [code, base64] = generated.split('//# sourceMappingURL=data:application/json;base64,');
    const map = new SourceMap(JSON.parse(Buffer.from(base64.trim(), 'base64').toString()));
    const probes = [[code.indexOf('useThing(1)'), 3, 9], [code.indexOf('useThing(2)'), 5, 21],
      [code.indexOf('function First'), 2, 0]];
    for (const [offset, line, column] of probes) {
      assert.ok(offset >= 0);
      const prefix = code.slice(0, offset).split('\n');
      const entry = map.findEntry(prefix.length - 1, prefix.at(-1).length);
      assert.deepEqual([entry.originalLine + 1, entry.originalColumn], [line, column], code.slice(offset, offset + 12));
    }
  }
}

module.exports = function verifyRefresh(binary, temp, run, oracle) {
  const directory = fs.mkdtempSync(path.join(temp, 'refresh-'));
  prepare(directory);
  const file = path.join(fixtures, 'components.tsx');
  const expected = fs.readFileSync(path.join(fixtures, 'components.log'), 'utf8');
  for (const mode of [[], ['--minified']]) {
    const code = run(binary, ['transform', file, ...flags, ...mode]);
    assert.equal(execute(directory, 'kessel.mjs', code), expected, 'components.tsx ' + mode.join(' '));
  }
  let compared = '';
  if (oracle) {
    const source = fs.readFileSync(file, 'utf8');
    const reference = oracle.transformSync('components.tsx', source, { jsx: { runtime: 'automatic', refresh: true } });
    assert.deepEqual(reference.errors, []);
    assert.equal(execute(directory, 'oxc.mjs', reference.code), expected, 'components.tsx OXC');
    compared = ' OXC 0.127.0 told the runtime the same.';
  }
  checkAdjacentIdentifier(binary, directory, run);
  checkOptions(binary, temp, run);
  checkSourceMap(binary, temp, run);
  const records = expected.trim().split('\n').length;
  console.log(`React Refresh reproduced ${records} runtime records in both output modes, with option, ` +
    `naming and source-map checks.${compared}`);
};
