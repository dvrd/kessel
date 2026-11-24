'use strict';

// Mark each reported span with «…». Run the same sources through both CLIs
// so a diagnostic on the wrong getter or switch clause cannot count as a pass.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const oracle = process.argv[3];
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-lint-flow-'));
let compared = 0;
let checked = 0;

function verify(rule, cases, {option, extension = 'js', native = false, reference = true} = {}) {
  const filename = 'flow.' + extension;
  const expected = [];
  const source = cases.map((line, index) => {
    let column = 1;
    return line.split(/(«[^»]+»)/).map(part => {
      if (part.startsWith('«')) {
        part = part.slice(1, -1);
        expected.push([index + 1, column, part.length]);
      }
      column += part.length;
      return part;
    }).join('');
  }).join('\n');
  fs.writeFileSync(path.join(folder, filename), source);
  const configuration = native ? 'kessel.lint.json' : '.oxlintrc.json';
  const setting = option ? ['error', option] : 'error';
  fs.writeFileSync(path.join(folder, configuration), JSON.stringify({rules: {[rule]: setting}}));
  for (const engine of [binary, reference && oracle].filter(Boolean)) {
    const args = engine === binary ? ['lint', '--format=json'] : ['--format=json'];
    const result = spawnSync(engine, [...args, filename], {cwd: folder, encoding: 'utf8'});
    assert.ok([0,1].includes(result.status), result.stderr || String(result.error));
    let actual;
    if (engine === binary) {
      actual = JSON.parse(result.stderr || '[]').flatMap(f => f.messages).filter(m => m.ruleId === rule)
        .map(m => [m.line, m.column, m.endColumn - m.column]);
    } else {
      actual = JSON.parse(result.stdout).diagnostics.filter(d => d.code?.endsWith('(' + rule + ')')).map(d => {
        const {line, column, length} = d.labels[0].span;
        return [line, column, length];
      });
    }
    actual.sort((a,b) => a[0] - b[0] || a[1] - b[1]);
    assert.deepEqual(actual, expected, engine + ' ' + rule + ' ' + filename);
  }
  fs.unlinkSync(path.join(folder, configuration));
  checked += cases.length;
  if (oracle && reference) compared += cases.length;
}

const getters = [
  'class C0 { get x«(){}» }',
  'class C1 { static get [key]«(){ if (flag) return 1; }» }',
  'class C2 { get x(){ if (flag) return 1; else throw error; } }',
  'const c3 = { get x«(){ return; }», get y(){ return undefined; } };',
  'const c4 = { get x(){ throw error; } };',
  'const c5 = { get x«(){ function nested(){ return 1; } }» };',
  'const c6 = { get x(){ switch (key) { case 1: default: return 1; } } };',
  'const c7 = { get x«(){ for (const x of xs) return x; }» };',
  'const c8 = { get x(){ try { return read(); } catch { return 0; } } };',
  'const c9 = { get x«(){ try { return read(); } catch {} }» };',
  'const c10 = { get x(){ do { return 1; } while (maybe()); } };',
  'Object.defineProperty(target, "x", { get: «function getter(){}» });',
  'Reflect.defineProperty(target, "x", { get: «() => {}» });',
  'Object?.defineProperty(target, "x", { get«(){}» });',
  '(Object?.defineProperty)(target, "x", { get«(){ if (x) return 2; }» });',
  'Object.defineProperties(target, { x: { get: «function(){}» }, y: { get: () => 1 } });',
  'Object.create(proto, { x: { get«(){}» }, y: { set(v){} } });',
  'Object.defineProperty(target, "x", { get: () => value });',
  'const ordinary = { get(){}, set(v){} };',
  'const untouched = { get: function(){} };',
];

const unreachable = [
  'function f0(){ try { return read(); } catch { throw error; } «after();» }',
  'function f1(){ try { return read(); } catch {} after(); }',
  'function f2(){ try { work(); } finally { return; } «after();» }',
  'function f3(){ switch(x) { case 1: case 2: return 1; default: throw err; } «after();» }',
  'function f4(){ switch(x) { case 1: return 1; } after(); }',
  'function f5(){ switch(x) { default: return 1; case 2: if (x) break; throw err; } after(); }',
  'function f6(){ for (;;) { while (work()) { if (x) break; } } «after();» }',
  'function f7(){ while (true) { if (x) break; } after(); }',
  'function f8(){ label: { if (x) break label; return; } after(); }',
  'function f9(){ label: { if (x) return; throw error; } «after();» }',
  'function f10(){ if (x) return; after(); }',
  'function f11(){ for(const row of rows){ return row; } after(); }',
  'const arrow = () => { throw err; «after();» };',
  'function f13(){ switch(x){case 1: break; «after();»} }',
  'function f14(){ try { work(); } catch { throw err; «after();» } }',
  'function f15(){ try {} finally { return; «after();» } }',
  'function f16(){ return; ; var value; function nested(){} «first();» «second();» }',
];
const fallthrough = [
  'function s0(x){ switch(x){ case 1: try { return load(); } catch { throw err; } default: return 3; } }',
  'function s1(x){ switch(x){ case 1: try { load(); } finally { break; } default: load(); } }',
  'function s2(x){ switch(x){ case 1: try { return load(); } catch { work(); } «default: return 3;» } }',
  'function s3(x){ switch(x){ case 1: while(x){break;} «default: return 4;» } }',
];

// Finally overrides pending transfers, including labelled jumps. Some versions
// of oxlint conservatively report a reachable path for these JavaScript cases.
const overrides = [
  'function g0(){ exit: { try { break exit; } finally { return 1; } } «after();» }',
  'function g1(){ exit: { try { return 1; } finally { break exit; } } after(); }',
  'function g2(){ exit: { try { break exit; } finally { if (x) return 1; } } after(); }',
  'function g3(){ a: for(;;){ b: for(;;){ break a; } } after(); }',
  'function g4(){ a: b: do { continue a; } while(false); after(); }',
  'function g5(){ a: while(true){ try { break a; } finally { continue a; } } «after();» }',
  'function g6(){ a: for(;;){ try { continue a; } finally { if (x) break a; } } after(); }',
  'function g7(){ a: { b: { try { break b; } finally { break a; } } «return;» } after(); }',
];

// All loops in these functions run once. Execute every combination of the
// three inputs to establish whether the final call is reachable in JavaScript.
function finallyCases() {
  const cases = [];
  const actions = flag => [
    '', 'return 1;', 'throw 1;', 'break outer;', 'continue outer;',
    'if (' + flag + ') return 2;', 'if (' + flag + ') break outer; else throw 1;',
  ];
  for (const attempt of actions('p')) {
    for (const recovery of actions('q')) {
      for (const cleanup of actions('r')) {
        const body = 'outer: do { try {' + attempt + '} catch {' + recovery + '} finally {' + cleanup + '} } while(false); ';
        const run = new Function('p', 'q', 'r', 'arrived', body + 'arrived();');
        let reached = false;
        for (let mask = 0; mask < 8; mask++) {
          try { run(mask & 1, mask & 2, mask & 4, () => { reached = true; }); }
          catch (error) { assert.equal(error, 1); }
        }
        const probe = reached ? 'arrived();' : '«arrived();»';
        cases.push('function path' + cases.length + '(p,q,r,arrived){ ' + body + probe + ' }');
      }
    }
  }
  return cases;
}

try {
  verify('getter-return', getters);
  verify('getter-return', [
    'const o0 = { get x(){ return; } };',
    'const o1 = { get x«(){ if (x) return; }» };',
    'const o2 = { get x«(){}» };',
    'Object.defineProperty(target, "x", { get(){ if(x) return; return 3; } });',
  ], {option: {allowImplicit: true}});
  verify('getter-return', ['class T { get value(): number {} }'], {extension: 'ts'});
  verify('getter-return', ['class T { get value«(): number {}» }'], {extension: 'ts', native: true, reference: false});
  verify('getter-return', [
    'function local(Object){ Object.defineProperty(foo, "x", { get(){} }); }',
    'Object.create({get(){}}, {});',
    'Object.defineProperty(...targetAndKey, "other", {get(){}});',
  ], {reference: false});
  verify('no-unreachable', unreachable);
  verify('no-unreachable', overrides, {reference: false});
  verify('no-fallthrough', fallthrough);
  verify('no-fallthrough', [
    'switch(x){case 1: work(); /* FaLlS ThRoUgH */ case 2: break; }',
    'switch(x){case 1: {work(); /* fallthrough */} /* another note */ case 2: break; }',
    'switch(x){case 1: work(); /* fallthrough */ /* another note */ «default: break;» }',
    'switch(x){case 1: work("/* fallthrough */"); «case 2: break;» }',
    'switch(x){case 1: {work(); /* fallthrough */} more(); «case 2: break;» }',
    'switch(x){case 1: work(); /* eslint-disable-next-line no-fallthrough */ case 2: break; }',
  ]);
  verify('no-fallthrough', [
    'switch(x){case 1: work(); /* ExPlIcIt  123 */ default: break; }',
    'switch(x){case 1: work(); /* falls through */ «default: break;» }',
  ], {option: {commentPattern: 'explicit\\s+\\d+'}});
  verify('no-fallthrough', [
    'switch(x){case 1: break;« /* falls through */ »case 2: work(); /* falls through */ default: break; }',
  ], {option: {reportUnusedFallthroughComment: true}});
  verify('no-unreachable', finallyCases(), {reference: false});
  console.log(checked + ' control-flow cases passed, ' + compared + ' compared with oxlint.');
} finally {
  fs.rmSync(folder, {recursive: true, force: true});
}
