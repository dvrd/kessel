#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const oracle = process.argv[3];
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-prefer-const-'));
const file = path.join(directory, 'fixture.ts');
const all = { destructuring: 'all' };
const ignoreEarly = { ignoreReadBeforeAssign: true };
// « » mark diagnostic spans. ~let marks exactly the keyword that may be fixed.
const cases = [
  ['~let «a» = 1; console.log(a);'],
  ['let a; let b = 0; b++; const c = 2; var d = 3;'],
  ['~let /* keep */ «π»: number = 1;'],
  [String.raw`export ~let «\u{3C0}»: number = 2;`],
  ['~let {a: [«b», ...«rest»], «k» = 1} = value;'],
  ['let [«a», b] = value; b++;'],
  ['let [a, b] = value; b++;', all],
  ['let «fixed» = 1, mutable = 1; mutable++;'],
  ['let mutable = 1, «fixed» = 1; mutable++;', {}, false],
  ['~let «one» = 1, «two» = 2;'],
  ['let «first» = 1, «later»; later = 2;'],
  ['let «delayed»; delayed = 1;'],
  ['let «delayed»; (delayed as number)=1; let «other»; (other!)=2;'],
  ['let «early»; print(early); early = 1;'],
  ['let early; print(early); early = 1;', ignoreEarly],
  ['function f(){return early;} let early = 1;', ignoreEarly],
  ['function f(){return early;} ~let «early» = 1;'],
  ['let shared; if (ready) shared=1;'],
  ['if (ready) { let «local»; local = 1; }'],
  ['let a; for (;a=next();) {} let b; while (b=next()) {}'],
  ['for (let i=0, n=4; i<n; i++) {}'],
  ['for (let found; (found=next()); ) {}'],
  ['for (~let «x» of items) { consume(x); } for (let y in obj) { y=1; }'],
  ['for (~let [«x», «y»] of rows) { use(x,y); }'],
  ['for (const key in obj) { let «v»; ({v}=next()); }'],
  ['let outer; { outer = 2; } function inner(){ let «x»; x = 1; }'],
  ['let a; take([a = 2]); let b; ready && (b = 2);'],
  ['let a; a+=1; let b; b ||= 1; let c; c++;'],
  ['let x; let «y»; [x, obj.value] = data; ({y}=data);'],
  ['let «a», b; ({a,b}=obj); b=0;'],
  ['let a,b; ({a,b}=obj); b=0;', all],
  ['function f(p){ let x; [p,x]=obj; }'],
  ['function f(...p){ let «x»; [p,x]=obj; }'],
  ['function f(n=0,...p){ let «x»; [p,x]=obj; }'],
  ['function f(...p){ let x; [p,x]=obj; function inner(){p=2;} }'],
  ['let x=0; (() => { x=4; })();'],
  ['let x=0; class Box { static { x++; } }'],
  ['~let «x» = {a:1}; x.a = 2;'],
  ['~let «x» = () => { ~let «y» = 1; return y; };', {}, false],
  ['// eslint-disable-next-line prefer-const\nlet ignored = 1;\n~let «kept» = 2;'],
  ['let «x»=1; function update(){ eval("x=2"); } update();', {}, false],
  ['function f(){ let «x»=0; eval("x=4"); } function g(){ ~let «v»=1; return v; }', {}, false],
  ['export declare let count: number;'],
  ['export ~let «count»: number = 0;'],
];

function parse(marked) {
  const clean = marked.replaceAll('~let', 'let');
  const spans = [];
  let source = '', end = 0;
  for (const m of clean.matchAll(/«([^»]+)»/g)) {
    source += clean.slice(end, m.index);
    const lines = source.split('\n');
    spans.push([lines.length, Buffer.byteLength(lines.at(-1)) + 1, Buffer.byteLength(m[1])]);
    source += m[1];
    end = m.index + m[0].length;
  }
  return { source: source + clean.slice(end), spans, fixed: marked.replaceAll('~let', 'const').replace(/[«»]/g, '') };
}

function run(engine, fix) {
  const isKessel = engine === binary;
  const args = isKessel ? ['lint', '--format=json'] : ['--format=json'];
  const result = spawnSync(engine, [...args, '-c', 'config.json', ...(fix ? ['--fix'] : []), 'fixture.ts'],
    { cwd: directory, encoding: 'utf8' });
  assert.ok([0, 1].includes(result.status), result.stderr || String(result.error));
  if (isKessel) {
    const messages = JSON.parse(result.stderr)[0].messages;
    assert.ok(messages.every(m => !m.fatal), JSON.stringify(messages));
    return messages.filter(m => m.ruleId === 'prefer-const').map(m => [m.line, m.column, m.endColumn - m.column]).sort();
  }
  return JSON.parse(result.stdout).diagnostics.filter(d => d.code === 'eslint(prefer-const)').map(d => {
    const { line, column, length } = d.labels[0].span;
    return [line, column, length];
  }).sort();
}

try {
  for (const [marked, options = {}, compareFix = true] of cases) {
    const { source, spans, fixed } = parse(marked);
    fs.writeFileSync(path.join(directory, 'config.json'), JSON.stringify({ rules: { 'prefer-const': ['error', options] } }));
    for (const engine of [binary, oracle].filter(Boolean)) {
      fs.writeFileSync(file, source);
      assert.deepEqual(run(engine, false), spans.sort(), engine + '\n' + source);
      if (engine === oracle && !compareFix) continue;
      const remaining = run(engine, true);
      assert.equal(fs.readFileSync(file, 'utf8'), fixed, engine + '\n' + source);
      if (engine === binary) assert.deepEqual(run(engine, false), remaining);
    }
  }
  fs.writeFileSync(path.join(directory, 'config.json'), '{"rules":{"prefer-const":"error"}}');
  for (const source of ['let a=1,b=3; a++; a+b;', 'let x=2; function g(){eval("x=4");} g(); x;',
    'let a=[1,2]; let sum=0; for(let x of a){sum+=x;} sum;']) {
    fs.writeFileSync(file, source);
    run(binary, true);
    assert.equal(vm.runInNewContext(fs.readFileSync(file, 'utf8')), vm.runInNewContext(source));
  }
  console.log(cases.length + ' prefer-const fixtures and three runtime checks passed' +
    (oracle ? ' against pinned oxlint diagnostics.' : '.'));
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
