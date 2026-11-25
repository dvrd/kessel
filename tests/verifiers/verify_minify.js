'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const { SourceMap } = require('node:module');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const binary = process.argv.slice(2).find(arg => !arg.startsWith('--')) || path.join(root, 'bin', 'kessel');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-minify-'));
const reference = process.argv.includes('--reference') && require('../../bench/node_modules/oxc-minify');
const sdk = process.argv.includes('--sdk') && require('../../npm/kessel');
if (reference) assert.equal(require('../../bench/node_modules/oxc-minify/package.json').version,
  require('../../OXC_ORACLE.json').oxc_minify_npm);

function emit(command, file, options = []) {
  return execFileSync(binary, [command, file, ...options], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}
function write(name, source) {
  const file = path.join(temp, name);
  fs.writeFileSync(file, source);
  return file;
}
function outcome(code) {
  const scope = {};
  vm.runInNewContext(code, scope, { timeout: 5000 });
  return JSON.stringify(scope.result);
}
function checkRuntime(name, source, referenceExpected = null) {
  const file = write(name, source);
  const expected = outcome(source);
  const output = emit('minify', file);
  assert.equal(outcome(output), expected, name);
  assert.ok(output.length <= emit('codegen', file, ['--minified']).length, name);
  if (reference) {
    const result = reference.minifySync(name, source, { module: false, mangle: false });
    assert.deepEqual(result.errors, []);
    assert.equal(outcome(result.code), referenceExpected ? referenceExpected(expected) : expected, name + ' Oxc');
  }
  return output;
}

// Compare the result type and value, including negative zero, infinities and NaN.
function verifyOperators() {
  const inputs = ['true', 'false', '0', '(-0)', '1', '(-3)', '1.5', '1e-320',
    '0xffffffff', '0x100000001', '1e308', '(0/0)', '(1/0)', '(-1/0)'];
  const ops = ['+', '-', '*', '/', '%', '**', '|', '^', '&', '<<', '>>', '>>>',
    '==', '!=', '===', '!==', '<', '<=', '>', '>='];
  const expressions = inputs.flatMap(left => inputs.flatMap(right => ops.map(op => '(' + left + op + right + ')')));
  expressions.push(...inputs.flatMap(input => ['+', '-', '!', '~'].map(op => op + input)));
  // Bound array literal length so both parsers can run within their resource limits.
  for (let start = 0; start < expressions.length; start += 250) {
    const slice = expressions.slice(start, start + 250);
    checkRuntime('operators-' + start + '.js',
      'globalThis.result=[' + slice.join(',') +
      '].map(x=>[typeof x,Object.is(x,-0)?"-0":String(x)]);', expected => {
        // Oxc 0.127.0 folds these three powers to 1. V8 returns NaN for each,
        // including on the Kessel output checked above.
        const values = JSON.parse(expected);
        for (const expression of ['(1**(0/0))', '(1**(1/0))', '(1**(-1/0))']) {
          const i = slice.indexOf(expression);
          if (i < 0) continue;
          assert.deepEqual(values[i], ['number', 'NaN']);
          values[i] = ['number', '1'];
        }
        return JSON.stringify(values);
      });
  }
  return expressions.length;
}

function verifyEffects() {
  const output = checkRuntime('effects.js', [
    '"use strict";',
    'let hits = 0; let log = []; const first = 7 * (8 + 1); const second = first + 2;',
    'function capture(x){log.push(x);return x;}',
    'const value={valueOf(){return capture(++hits);},get item(){return capture(8);}};',
    'function test(){let x = capture(2); let y = capture(x); switch(x){case 2:var a=capture(y);var b=capture(a);return b;default:return 0;}}',
    'const s=[test(),value+3,value.item*0,typeof (false), true ** 2, false.toString(),',
    '(-4+1).toString(),2-(5-9),hits+(2*0.129933)*hits,hits-(2*-0.129933),3n+5n, false && capture(77),1/(1-1),1/(0*-1)];',
    'try { 1n + 2 } catch(e){s.push(e.name)}',
    'globalThis.result=[first,second,s.map(String),log];',
  ].join('\n'));
  assert.match(output, /const first=63,second=/);
  assert.match(output, /"use strict";/);
  const boundaries = checkRuntime('boundaries.js', [
    'let a=1;{let a=2; let b=a+1; globalThis.result=[a,b];}',
    'if (false) var c=1; var d=2; outer: for(let e=3;e>2;e--){var f=e;var g=f;break outer;}',
    'switch(a){case 1: var h=g; case 2: var i=h; result.push(c,d,eType(),f,g,h,i);}',
    'function eType(){return typeof e}',
  ].join('\n'));
  assert.match(boundaries, /case 2:var i=/);
  const script = write('public.mts', 'export const a=true; const b=false; type Flag=true|false; declare const x:true; declare const y:false;');
  assert.match(emit('minify', script), /type Flag = true \| false;/);
}

function verifyNames() {
  const source = [
    'const a = 10; globalThis.b = 2;',
    'function work(longParameter, {externalKey: longDefault = 3}, ...restValues) {',
    '  let runningTotal = a + b + longParameter; const captured = () => runningTotal;',
    '  { let runningTotal = longDefault; restValues.push(runningTotal); }',
    '  for (let iteration = 0; iteration < 2; iteration++) restValues.push(() => iteration);',
    '  const holder = {longParameter}; ({longParameter = 8} = holder);',
    '  const {longParameter: fromProperty, ...remainingProperties} = holder;',
    '  let assignedFunction; assignedFunction = () => 4; const inferredClass = class {};',
    '  const {fallback = function(){}} = {};',
    '  try { throw fromProperty } catch (errorValue) { var errorValue = 5; restValues.push(errorValue); }',
    '  return [captured(), restValues.map(v => typeof v === "function" ? v() : v), holder,',
    '    remainingProperties, assignedFunction.name, inferredClass.name, fallback.name];',
    '}',
    'function defaults(longParameter = 7, read = () => longParameter) { var longParameter; longParameter++; return [longParameter,read()]; }',
    'function aliases(longArgument) {arguments[0]++; return longArgument;}',
    'function direct(longVisible) {return (()=>eval("longVisible"))();}',
    'function dynamic(target, longVisible) {with(target){longVisible++;}return [target.longVisible,longVisible];}',
    'function proto(__proto__) { const o={__proto__}; return [Object.keys(o),Object.getPrototypeOf(o)===Object.prototype]; }',
    'globalThis.result=[work(4,{},0),defaults(),aliases(7),direct(6),dynamic({longVisible:3},11),proto(2)];',
  ].join('\n');
  const file = write('names.js', source);
  const expected = outcome(source);
  for (const args of [[], ['--no-compress'], ['--no-mangle'], ['--no-compress', '--no-mangle']]) {
    assert.equal(outcome(emit('minify', file, args)), expected, args.join(' '));
  }
  const mangled = emit('minify', file, ['--no-compress']);
  assert.doesNotMatch(mangled, /runningTotal|restValues|iteration/);
  assert.match(mangled, /assignedFunction/);
  assert.match(mangled, /longVisible/);
  assert.ok(mangled.length < emit('codegen', file, ['--minified']).length);
  const siblings = write('siblings.js',
    'function one(longFirst){return longFirst;}function two(longSecond){return longSecond;}');
  assert.equal(emit('minify', siblings), 'function one(e){return e}function two(e){return e}');

  // Overlapping function parameters exhaust all one-character aliases and force
  // multi-character names. The original global names reserve the same spellings.
  const params = Array.from({ length: 140 }, (_, i) => 'parameter' + i);
  const many = 'const a=1,_a=2; function sum(' + params + '){return a+_a+' + params.join('+') +
    ';} globalThis.result=sum(' + params.map((_, i) => i) + ');';
  assert.equal(outcome(emit('minify', write('many.js', many))), outcome(many));
}

// Aliases are shared between unrelated scopes and ordered by use count. Each
// program observes every binding it declares, so a captured reference or a
// merged binding changes the result. Function and class names stay unless
// --mangle-names is given, which may only change the `name` values.
function verifyNameSlots() {
  const cases = {
    'default-later.js': [
      '(function(){ function bindNode(q){return 1}',
      '  function createBinder(){ function bindEach(nodes, bindFunction = bindNode){ return bindFunction(nodes); }',
      '    function bindNode(node){ return 2 } return bindEach(0); }',
      '  globalThis.result=[createBinder(), bindNode(1)]; })();'],
    'parameter-body.js': [
      'function init(first = 1, second = () => first){ var third; var fourth = 4; return [third, fourth, second(), first]; }',
      'function shadow(outerValue){ return function(innerValue = outerValue){ var outerValue; return [innerValue, outerValue]; }(); }',
      'globalThis.result=[init(), init(7), shadow(3)];'],
    'catch-var.js': [
      'function recover(){ var before = 1; try { throw 2 } catch (problem) { var problem = 5; var inside = problem; }',
      '  try { throw 3 } catch (failure) { var later = failure; } try { throw 4 } catch ({message = 9}) { later += message; }',
      '  return [before, typeof problem, inside, later]; }',
      'globalThis.result=recover();'],
    'annex-b.js': [
      'function blocks(flag){ var seen = typeof hoisted; { function hoisted(){ return 1 } }',
      '  if (flag) { function chosen(){ return 2 } } return [seen, hoisted(), typeof chosen]; }',
      'function strictBlocks(){ "use strict"; { function scoped(){ return 3 } var kept = scoped(); } return [kept, typeof scoped]; }',
      'globalThis.result=[blocks(true), blocks(false), strictBlocks()];'],
    'self-names.js': [
      'function outer(){ var factorial = function inner(count){ return count < 2 ? 1 : count * inner(count - 1); };',
      '  var Shape = class Figure { static make(){ return new Figure(); } who(){ return Figure === Shape; } };',
      '  class Local { again(){ return Local; } } var copy = Local; Local = null;',
      '  return [factorial(5), Shape.make().who(), new copy().again()]; }',
      'globalThis.result=outer();'],
    'hoisted-var.js': [
      'function hoist(list){ { let blockOnly = list.length; { var total = blockOnly; } }',
      '  for (var index = 0; index < list.length; index++) { let item = list[index]; var last = () => item + total; }',
      '  switch (total) { case 2: let picked = last(); var out = picked; } return [total, index, last(), out]; }',
      'globalThis.result=hoist([4,5]);'],
    'shadow-reads.js': [
      'function layers(value){ const read = () => value; { const value = 2; var mid = () => value + read(); }',
      '  return function(value){ return [value, mid(), read(), (function(){ var value = 8; return value; })()]; }(3); }',
      'function labels(){ label: for (var label = 0; label < 3; label++) { continue label; } return label; }',
      'globalThis.result=[layers(1), labels()];'],
    'shorthand.js': [
      'function pack(alphaValue, betaValue){ const gammaValue = alphaValue + betaValue;',
      '  const {alphaValue: renamedValue = 6, missingValue = gammaValue} = {alphaValue};',
      '  return {alphaValue, betaValue, gammaValue, renamedValue, missingValue}; }',
      'globalThis.result=pack(1, 2);'],
    'name-values.js': [
      'function report(){ function declared(){} var assigned = function(){}; var arrow = () => 1; class Kind {}',
      '  var later; later = function(){}; var {picked = class {}} = {}; var expression = function own(){};',
      '  return [declared.name, assigned.name, arrow.name, Kind.name, later.name, picked.name, expression.name]; }',
      'globalThis.result=report();'],
  };
  for (const [name, lines] of Object.entries(cases)) {
    const source = lines.join('\n');
    const file = write(name, source);
    const expected = outcome(source);
    for (const passes of [[], ['--no-compress'], ['--mangle-names'], ['--no-compress', '--mangle-names']]) {
      const output = emit('minify', file, passes);
      const actual = outcome(output);
      if (name === 'name-values.js' && passes.includes('--mangle-names')) {
        assert.equal(JSON.parse(actual).length, 7);
        assert.doesNotMatch(output, /declared|assigned|Kind|later|own/);
      } else {
        assert.equal(actual, expected, name + ' ' + passes.join(' '));
      }
      if (sdk) {
        const result = sdk.minifySync(file, source, { compress: !passes.includes('--no-compress'),
          mangleNames: passes.includes('--mangle-names') });
        assert.deepEqual(result, { code: output, map: null, errors: [] }, name);
      }
    }
  }
  const kept = emit('minify', write('kept.js', cases['name-values.js'].join('\n')));
  for (const name of ['declared', 'assigned', 'arrow', 'Kind', 'later', 'picked', 'own']) assert.ok(kept.includes(name), name);
  // Oxc 0.127.0 resolves a default-parameter reference to a later function
  // declaration against the outer scope, so its own mangler changes this result.
  if (reference) {
    const source = cases['default-later.js'].join('\n');
    const result = reference.minifySync('default-later.js', source, { compress: false });
    assert.equal(outcome(source), '[2,1]');
    assert.equal(outcome(result.code), '[1,1]');
  }
  // Unrelated functions share aliases, and the most used binding gets the shortest one.
  const shared = emit('minify', write('shared.js', 'function one(first){return function(second){return second+second+second+first;};}' +
    'function two(third,fourth){return fourth*fourth*fourth*fourth+third;}'), ['--no-compress']);
  assert.equal(shared, 'function one(t){return function(e){return e+e+e+t;};}function two(t,e){return e*e*e*e+t;}');
  assert.equal(emit('codegen', write('shared.js', 'if(a){b()}else{c()}'), ['--minified']), 'if(a){b();}else {c();}');
  // Many bindings in one scope use every two-character alias before a third character.
  const locals = Array.from({ length: 400 }, (_, i) => 'localValue' + i);
  const wide = 'function wide(){var ' + locals.map((name, i) => name + '=' + i).join(',') + ';return ' + locals.join('+') + ';}globalThis.result=wide();';
  const small = emit('minify', write('wide.js', wide), ['--no-compress']);
  assert.equal(outcome(small), outcome(wide));
  assert.ok(Math.max(...small.slice(0, small.indexOf(';return')).match(/[A-Za-z_$][\w$]*(?==)/g).map(name => name.length)) <= 2);
}

// Every compression rewrite must keep evaluation order, branch selection,
// completion values and binding scopes. Each case logs the calls it makes and
// runs under every pass combination.
const compressionCases = {
  'guards.js': `
    const log = []; const t = (name, value) => { log.push(name); return value; };
    function guards(a, b) {
      if (t('a', a)) { t('x', 1); } if (!t('a2', a)) { t('y', 2); }
      if (t('a3', a)) { t('p'); t('q'); } else { t('r'); }
      if (a = t('assign', b)) { b = t('assigned', 5); } if (a ?? t('nullish', b)) { b ||= 2; }
      if (a) { var arrow = () => 1; } if (a || b) a && t('mixed1'); if (a && b) a || t('mixed2');
      if (a) { if (b) t('nested'); } else t('nested-else');
      if (a) { for (;;) { if (b) break; else break; } } else t('loop-else');
      if (a) (() => t('iife'))(); if ('length' in log) t('in'); if (this.ready) this.go();
      if (a) ; if (b) ; else t('empty-then'); if (a) t('empty-else'); else ;
      return [a, b, typeof arrow];
    }
    const self = { ready: true, go() { t('go'); } };
    globalThis.result = [[0, 0], [0, 3], [null, 1], [1, 0], [2, 2], [undefined, undefined]]
      .map(args => [guards.apply(self, args), log.splice(0)]);`,
  'returns.js': `
    const log = []; const t = (name, value) => { log.push(name); return value; };
    function returns(a, b) {
      if (t('r1', a)) return t('v1', 1);
      if (t('r2', b)) { return t('v2', 2); } else { t('side'); }
      if (a === b) return; if (a === null) return undefined;
      return t('v3', 3);
    }
    function chain(n) { if (n === 0) return 'zero'; if (n === 1) return 'one'; if (n === 2) { return 'two'; } return 'many'; }
    function thrower(a) { try { if (a) throw new Error('yes'); else throw new TypeError('no'); }
      catch (e) { return e.constructor.name + e.message; } finally { t('finally'); } }
    function flatten(a) { if (a) { return 1; } else { let scoped = 2; var hoisted = scoped; return scoped + typeof late; var late; } }
    function flattenVar(a) { if (a) { return typeof kept; } else { var kept = 3; } return kept; }
    function loop(list) { const out = []; outer: for (const row of list) { for (const item of row) {
      if (item < 0) { continue outer; } else if (item > 8) { break outer; } else { out.push(item); } } out.push('row'); } return out; }
    function trailing(a) { t('before'); if (a) { t('inner'); return; } t('after'); return; }
    function long(n) { ${Array.from({ length: 80 }, (_, i) => 'if (n === ' + i + ') return "v' + i + '";').join(' ')} return 'none'; }
    globalThis.result = [[0, 0], [1, 0], [0, 1], [0, null], [null, 2], [7, 7], [null, null]].map(args => [returns(...args), log.splice(0)])
      .concat([[0, 1, 2, 3].map(chain), thrower(1), thrower(0), flatten(1), flatten(0), flattenVar(1), flattenVar(0),
        loop([[1, 2], [3, -1, 4], [5, 9, 6], [7]]), trailing(1), trailing(0), log.splice(0), long(0), long(41), long(79), long(80)]);`,
  'sequences.js': `
    const log = []; const t = (name, value) => { log.push(name); return value; };
    const obj = { get g() { log.push('get'); return 1; }, set s(v) { log.push('set ' + v); } };
    function sequences(a) {
      t('s1'); t('s2'); obj.g; obj.s = 3;
      if (t('s3', a) === 1) return t('s4', 4);
      t('s5'); switch (t('s6', a)) { case 0: t('c0'); t('c0b'); break; default: t('cd'); t('cd2'); }
      t('s7'); if (a === 2) { t('s8'); throw (t('s9'), 'thrown'); } t('s10'); throw new Error('end');
    }
    function strict() { "use strict"; t('d1'); t('d2'); return this === undefined; }
    function sloppy() { t('n1'); "use strict"; t('n2'); return this === undefined; }
    function prologue() { "one"; "use strict"; "three"; t('p1'); return this === undefined; }
    function* generator(a) { if (yield 1) { yield 2; } else { yield 3; } if (a) yield 4; t('g1'); t('g2'); return 5; }
    const run = a => { try { return sequences(a); } catch (e) { return String(e.message || e); } };
    const g = generator(1);
    globalThis.result = [run(0), run(1), run(2), strict(), sloppy(), prologue(), log.splice(0),
      [g.next(), g.next(0), g.next(), g.next(), g.next()]];`,
  'undefined.js': `
    function undef(u) { var x = undefined, y = [undefined, void 0, typeof undefined, undefined === u, u == undefined, undefined + 1];
      function inner(undefined) { return undefined; } var o = { undefined, plain: undefined };
      var holder = { undefined: 9 }; var call; try { undefined(); } catch (e) { call = e.constructor.name; }
      return [x, y, inner(5), (function () { var undefined = 3; return undefined; })(), o.undefined, 'plain' in o,
        holder.undefined, call, (() => { return undefined; })(), ((a = undefined) => a)(), [undefined][0] === void 0]; }
    function ret(a) { if (a) return undefined; return void 0; }
    function heritage() { try { class Sub extends undefined {} } catch (e) { return e.constructor.name; } }
    function loopInit(o) { const r = []; for (var f = function () { return "a" in o; }, g = () => ("b" in o), i = 0; i < 1; i++) r.push(f(), g(), undefined ** 2, 2 ** undefined); return r; }
    globalThis.result = [undef(), undef(null), undef(1), ret(1), ret(0), typeof undefined, undefined === void 0, String(undefined),
      heritage(), loopInit({ a: 1 }), loopInit({}).map(String)];`,
  'undefined-eval.js': `
    function shadow(code) { eval(code); return [undefined, typeof undefined]; }
    function scoped(o) { with (o) { return [undefined, typeof undefined]; } }
    globalThis.result = [shadow('var undefined = 7'), shadow(''), scoped({ undefined: 4 }), scoped({})];`,
  'operators.js': `
    function types(a, b) { return [typeof a === 'string', 'number' !== typeof a, typeof a === typeof b, typeof a !== 'undefined',
      typeof a == 'object', a === 'string', typeof missing === 'undefined']; }
    const o = { key: 1, 'two words': 2, if: 3, 0: 4, method() { return this === o; }, a: { b: 5 }, 'é': 6, $_9: 7 };
    function members() { const out = [o["key"], o["two words"], o["if"], o["0"], o?.["key"], o["method"](), (o["a"]["b"] = 8, o.a.b),
      o["é"], o["$_9"], delete o["key"], "key" in o, o["a"]?.["b"], o[""], [o][0]["if"]]; return out; }
    class Box { constructor() { this["value"] = 1; } ["get"]() { return this["value"]; } static ["make"]() { return new Box(); } }
    function factory() { return { Klass: function (v) { this.v = v; } }; }
    function news() { function N() { this.n = 1; } N.prototype.m = function () { return 2; };
      return [new (factory().Klass)(1).v, new N().m(), new N().n, typeof new N, new (factory()["Klass"])(3).v]; }
    globalThis.result = [types('s', 't'), types(1, {}), types(undefined, null), members(), Box.make().get(), news()];`,
  'arrows.js': `
    const log = []; const t = (name, value) => { log.push(name); return value; };
    const object = () => { return { a: 1 }; }, pair = () => { return (t('first'), 2); }, none = () => { return; };
    const one = (a) => { return a; }, two = (a, b) => { t('two'); return a + b; }, rest = (...a) => { return a.length; };
    const fallback = (a = 4) => { return a; }, destructured = ({ a }) => { return a; }, nested = (a) => (b) => { return a + b; };
    const strictArrow = () => { "use strict"; return (function () { return this; })(); };
    const asyncArrow = async (a) => { return a; }, asyncNone = async () => { return 1; };
    function context() { return [(() => { return this.v; })(), (() => { return arguments[0]; })(7)]; }
    const conditional = (a) => { if (a) { return 'yes'; } else { return 'no'; } };
    const effect = (a) => { if (a) t('effect'); };
    globalThis.result = [object(), pair(), none(), one(1), two(1, 2), rest(1, 2, 3), fallback(), destructured({ a: 5 }), nested(1)(2),
      strictArrow() === undefined, asyncArrow.constructor.name, asyncNone.constructor.name, context.call({ v: 6 }, 8),
      conditional(1), conditional(0), effect(1), effect(0), one.length, fallback.length, log];`,
  'blocks.js': `
    const r = [];
    function lexical(a, b) {
      if (a) { let z = 1; r.push(typeof z); } r.push(typeof z);
      if (a) { function q() { return 1; } } r.push(typeof q);
      if (a) { class K {} r.push(typeof K); } r.push(typeof K);
      if (a) { const c = 2; r.push(c); } else { const c = 3; r.push(c); }
      if (a) { if (b) r.push('ab'); } else r.push('not a');
      if (a) { while (b) { if (b) { r.push('w'); break; } } } else r.push('else w');
      if (a) { for (var i = 0; i < 2; i++) if (b) r.push(i); } else { r.push('else for'); }
      if (a) { label: if (b) r.push('labeled'); } else r.push('else label');
      if (a) { with ({ w: 1 }) if (b) r.push(w); } else r.push('else with');
      try { if (a) { r.push(early); } let early = 1; } catch (e) { r.push(e.name); }
      for (var k in { x: 1 }) { r.push(k); } for (const v of [1]) { r.push(v); } do { r.push('do'); } while (false);
      var n = 2; while (n--) { r.push(n); } for (;;) { break; } empty: ; if (a) ; for (var m = 0; m < 1; m++) ;
      switch (a) { case 1: r.push('one'); default: ; }
    }
    lexical(0, 0); lexical(0, 1); lexical(1, 0); lexical(1, 1);
    globalThis.result = r;`,
  // At the top level a guard keeps its statement form, so an inner \`if\` must keep the braces that hold off the \`else\`.
  'dangling.js': `
    var r = [];
    for (const [a, b] of [[0, 0], [0, 1], [1, 0], [1, 1]]) {
      if (a) { if (b) r.push('ab'); } else r.push('not a');
      if (a) { for (; b;) if (b) { r.push('for'); break; } } else r.push('else for');
      if (a) { inner: if (b) r.push('label'); } else r.push('else label');
      if (a) { if (b) r.push('both'); else r.push('only a'); }
      if (a) { if (b) r.push('x'); else if (!b) r.push('y'); } else r.push('z');
      if (a) if (b) r.push('kept'); else ; else r.push('outer else');
      if (a) if (b) r.push('k2'); else { } else if (b) r.push('o2'); else ;
    }
    globalThis.result = r;`,
  'literals.js': `
    function numbers(a) { return [1000000, 0.5, 0xff, 1e21, 1.50, 25000, 0.00025, 123456789, 1.0, 100, 1000, 0.1 + 0.2, 1e-7, 0.000001, 1500000,
      255..toString(16), 0.5.toFixed(1), 0xffffffffffff, 1_000_000, 010, 010 + 1, 08, 0o10, 0b11, 5e-324, 1.7976931348623157e308, 0.30000000000000004,
      9007199254740993, 1e3, 12e4, .75, -0.5, a ? .5 : 1, a ? 0.5 : 1.0, 2 ** 53, 1 / 3, 0.1 * 3, 1e-10, 123e-20, 4.35, 0.000035, 1e100, 0.1e2, 100..toFixed(1),
      { 0.5: 1, 1000: 2 }, 1.0.toFixed(2), 3.0e0 - 1, 1000000 .valueOf(), 60 * 60 * 1000, -1e6, 1e6 - -1e6].map(String); }
    function strings(x) { return ['a' + 'b', x + 'a' + 'b', 'a' + "b", "it's" + " ok", 'q\\'' + '\\\\', x + ('a' + 'b'), 'a' + 'b' + x + 'c' + 'd', 1 + 'a' + 'b',
      x + 'a' + 'b' + 'c', 'a' + +'b', 1 + 2 + 'a' + 'b', x + 1 + 'a' + 'b', 'a' + 'b' + 1 + 2, x + \`t\` + 'a', 'é' + 'ü', '\\u00e9' + 'x', ('a', 'b') + 'c']; }
    function blocks(log) { { log.push(1); log.push(2); } { let q = 3; log.push(q); } { "use strict"; log.push(4); } { var v = 5; } {} { { log.push(v); } }
      if (log) { { log.push(6); } } { function inner() { return 7; } } log.push(typeof q, inner()); return log; }
    function directive() { { "use strict"; } return this === undefined; }
    function directive2() { "use strict"; { "x"; } return this === undefined; }
    globalThis.result = [numbers(0), numbers({ 5: 2 }), strings(1), strings({ toString() { return 'o'; }, valueOf() { return 2; } }), strings(null),
      blocks([]), directive(), directive2()];`,
  'constants.js': `
    const top = 1, [first, { second = 2 }] = [3, {}];
    function consts(list) { const fixed = 1; let moving = 2; const { a, ...others } = { a: 3, b: 4 }; const out = [];
      const reassigned = 5; try { reassigned = 6; } catch (e) { out.push(e.constructor.name); }
      const counted = 7; try { counted++; } catch (e) { out.push(e.constructor.name); }
      const [swapped] = [8]; try { [swapped] = [9]; } catch (e) { out.push(e.constructor.name); }
      const looped = 10; try { for (looped of [1]); } catch (e) { out.push(e.constructor.name); }
      try { out.push(early); } catch (e) { out.push(e.constructor.name); } const early = 11;
      for (const item of list) { out.push(() => item); } for (const key in { k: 1 }) out.push(key);
      for (const step = { n: 0 }; step.n < 2; step.n++) out.push(() => step.n);
      const inner = () => { const fixed = 12; return fixed + moving++; };
      return [fixed, moving, a, others, reassigned, counted, swapped, looped, inner(), out.map(v => typeof v === 'function' ? v() : v)]; }
    function evaluated(code) { const hidden = 1; const out = []; try { eval(code); } catch (e) { out.push(e.constructor.name); } return [hidden, out]; }
    globalThis.result = [top, first, second, consts([13, 14]), evaluated('hidden = 2'), evaluated('')];`,
  // Constant tests select a branch. Hoisted declarations in the dead branch,
  // the dead zone of a later `let`, and the receiver of a call all survive.
  'dead.js': `
    const log = []; const t = (name, value) => { log.push(name); return value; };
    const o = { m() { return this === o; } };
    function dead(a) {
      if ("production" !== "production") { t('never'); } if (false) { var hoisted = 1; } if (true) { t('then'); } else { t('else'); }
      if (0) t('zero'); else { let q = t('q', 1); log.push(q); } if (!1) { function inner() {} } if ('') t('empty'); else t('nonempty');
      if (null) t('null'); if (void 0) t('void'); if (1 === 1) t('same'); if ("a" == "b") t('differ'); else if (a) t('a'); else t('not a');
      var r = true ? t('r1') : t('r2'), s = false && t('s'), u = true || t('u'), w = false || t('w'), x = 0 ? t('x1') : t('x2');
      var called = [(true ? o.m : 0)(), (false || o.m)(), (true && o.m)(), (0, o.m)()].map(Boolean);
      var indirect = (true ? eval : 0)('typeof log'), direct = eval('typeof log');
      return [typeof hoisted, typeof inner, r, s, u, w, x, called, indirect, direct, log.splice(0)];
    }
    function after(a) { try { early; } catch (e) { log.push(e.constructor.name); }
      if (a) { return tail(); t('dead1'); var late = 1; function tail() { return typeof late + typeof never; } t('dead2'); }
      switch (a) { case 0: t('case'); break; t('dead3'); default: t('default'); }
      for (var i = 0; i < 2; i++) { if (i) continue; t('loop'); break; t('dead4'); }
      throw (t('thrown'), 'x'); t('dead5'); let early = 2; var never; }
    const run = a => { try { return after(a); } catch (e) { return [String(e), log.splice(0)]; } };
    globalThis.result = [dead(0), dead(1), run(0), run(1)];`,
  'spacing.js': `
    function spacing(a, x) { const o = { a }; let u = 1;
      const fns = [function () { return !a; }, function () { return -a; }, function () { return ~a; }, function () { return +a; }, function () { return ++u; }, function () { return --u; },
        function () { return [a]; }, function () { return { a }; }, function () { return "s" + a; }, function () { return \`t\${a}\`; }, function () { return /re/.test(a); },
        function () { return (a, x); }, function () { return -1; }, function () { return - -1; }, function () { return !0 ? -1 : 1; }, function () { return -0; },
        function () { return ~-1; }, function () { return true.toString(); }, function () { return -(-1) + x; }, function () { return !a.b; }, function () { return -x * 2; },
        function () { return typeof a; }, function () { return void a; }, function () { return 'q'.length; }, function () { return 1 + 2; }, function () { return -(1 + 2); },
        function () { return o.a; }, function () { return (o).a; }, function () { return [1, 2][1]; }, function () { return {}.x; }, function () { return 0.5 + .25; }];
      const picks = [];
      for (const v of ['x', -1, !a, 3, 1, 'default']) { switch (v) { case "x": picks.push(1); break; case -1: picks.push(2); break;
        case !a: picks.push(3); break; case 1 + 2: picks.push(4); break; case [1][0]: picks.push(5); break; default: picks.push(6); } }
      var { p, q = 2 } = { p: 1 }, [s] = [3]; let [l] = [4]; const { c } = { c: 5 };
      return [fns.map(f => { const v = f(); return Object.is(v, -0) ? '-0' : v; }), picks, p, q, s, l, c];
    }
    globalThis.result = [spacing(1, 2), spacing(0, -3), spacing('re', 0)];`,
};

function verifyCompression() {
  const passes = [[], ['--no-mangle'], ['--no-compress'], ['--mangle-names']];
  for (const [name, source] of Object.entries(compressionCases)) {
    const file = write(name, source);
    const expected = outcome(source);
    for (const flags of passes) {
      const output = emit('minify', file, flags);
      assert.equal(outcome(output), expected, name + ' ' + flags.join(' '));
      if (sdk) {
        const result = sdk.minifySync(file, source, { compress: !flags.includes('--no-compress'),
          mangle: !flags.includes('--no-mangle'), mangleNames: flags.includes('--mangle-names') });
        assert.deepEqual(result, { code: output, map: null, errors: [] }, name);
      }
    }
    if (reference) {
      const result = reference.minifySync(name, source, { module: false });
      assert.deepEqual(result.errors, []);
      // Oxc 0.127.0 rewrites `undefined` even where eval or `with` rebinds it.
      let oracle = expected;
      if (name === 'undefined-eval.js') oracle = '[[null,"undefined"],[null,"undefined"],[null,"undefined"],[null,"undefined"]]';
      // It also drops the unused `class Sub extends undefined {}`, which throws a TypeError when evaluated.
      if (name === 'undefined.js') oracle = expected.replace('"undefined","TypeError",[true', '"undefined",null,[true');
      // It removes the read of `early` in its dead zone, and with it the ReferenceError.
      if (name === 'dead.js') oracle = expected.replace('["ReferenceError","case"', '["case"');
      assert.notEqual((name === 'undefined.js' || name === 'dead.js') && oracle, expected);
      assert.equal(outcome(result.code), oracle, name + ' Oxc');
    }
  }
  // The rewrites actually apply, and the hazards keep their original form.
  const small = name => emit('minify', write(name, compressionCases[name]), ['--no-mangle']);
  const guards = small('guards.js');
  for (const text of ["t('a',a)&&t('x',1)", "t('a2',a)||t('y',2)", "t('a3',a)?(t('p'),t('q')):t('r')", "a=t('assign',b))b=t('assigned',5)", 'this.ready&&this.go()']) {
    assert.ok(guards.includes(text), text);
  }
  const returns = small('returns.js');
  for (const text of ["return n===0?'zero':n===1?'one':n===2?'two':'many'}", 'let scoped=2', "throw a?new Error('yes'):new TypeError('no')"]) {
    assert.ok(returns.includes(text), text);
  }
  assert.ok(small('undefined.js').includes('var x=void 0,y=[void 0,void 0,typeof void 0,void 0===u,u==void 0,void 0+1]'));
  assert.ok(small('undefined.js').includes('function inner(undefined){return undefined}'));
  assert.doesNotMatch(small('undefined-eval.js'), /void 0/);
  const operators = small('operators.js');
  for (const text of ["typeof a=='string'", "'number'!=typeof a", 'typeof a==typeof b', "a==='string'", 'o.key', 'o["two words"]', 'o.if',
    'o["0"]', 'o?.key', 'o.method()', 'o["é"]', 'o.$_9', 'new (factory().Klass)(1).v', 'new (factory().Klass)(3).v']) {
    assert.ok(operators.includes(text), text);
  }
  const arrows = small('arrows.js');
  for (const text of ['object=()=>({a:1})', "pair=()=>(t('first'),2)", 'none=()=>{}', 'one=a=>a', 'nested=a=>b=>a+b', 'asyncArrow=async a=>a',
    'asyncNone=async()=>1', '"use strict";return', "conditional=a=>a?'yes':'no'", "effect=a=>{a&&t('effect')}"]) {
    assert.ok(arrows.includes(text), text);
  }
  const blocks = small('blocks.js');
  for (const text of ['{let z=1;', '{function q(){return 1}}', 'empty:;', 'for(var m=0;m<1;m++);', "r.push('one');default:}"]) {
    assert.ok(blocks.includes(text), text);
  }
  const dangling = small('dangling.js');
  for (const text of ["if(a){if(b)r.push('ab')}else r.push('not a')", "if(a){for(;b;)if(b){r.push('for');break}}else r.push('else for')",
    "if(a){inner:if(b)r.push('label')}else r.push('else label')", "if(a)b?r.push('both'):r.push('only a')"]) {
    assert.ok(dangling.includes(text), text);
  }
  const dead = small('dead.js');
  for (const text of ['if(!1)var hoisted=1;', "t('then');{let q=t('q',1);log.push(q)}", 'if(!1){function inner(){}}', "t('nonempty')", "r=t('r1'),s=!1,u=!0,w=t('w'),x=t('x2')",
    '(!0?o.m:0)()', '(!1||o.m)()', '(!0&&o.m)()', "(!0?eval:0)('typeof log')", 'return tail();var late=1;function tail()', "break;default:", 'let early=2;var never}']) {
    assert.ok(dead.includes(text), text);
  }
  assert.doesNotMatch(dead, /never'\)|'else'|'zero'|'empty'\)|'null'|'void'|'differ'|'r2'|'x1'|dead\d/);
  const constants = small('constants.js');
  for (const text of ['const top=1,[first,{second=2}]=[3,{}];', 'let fixed=1,moving=2,{a,...others}={a:3,b:4},out=[];const reassigned=5;',
    'const counted=7;', 'const[swapped]=[8];', 'const looped=10;', 'let early=11;', 'for(let item of list)', 'for(let key in {k:1})',
    'for(let step={n:0};', 'const hidden=1,out=[];']) {
    assert.ok(constants.includes(text), text);
  }
  // A module's top level is private to it. A script's top level is shared with other scripts.
  const scoped = 'const shared = 1; const other = 2; try { other = 3; } catch (e) {} { const inner = shared + other; globalThis.result = inner; }';
  assert.equal(emit('minify', write('scoped.mjs', scoped + ' export const sum = shared + other;'), ['--no-mangle']),
    'let shared=1;const other=2;try{other=3}catch(e){}{let inner=shared+other;globalThis.result=inner}export let sum=shared+other;');
  assert.ok(emit('minify', write('scoped.js', scoped), ['--no-mangle']).startsWith('const shared=1,other=2;'));
  assert.match(emit('minify', write('scoped.js', scoped), ['--no-mangle']), /\{let inner=shared\+other;/);
  const spacing = small('spacing.js');
  for (const text of ['return!a', 'return-a', 'return~a', 'return +a', 'return++u', 'return[a]', 'return{a}', 'return"s"+a', 'return`t${a}`',
    'return/re/.test(a)', 'return-1}', 'return 1}', 'return-0}', 'return 0}', 'return typeof a', 'return void a', "return'q'.length",
    'return true.toString()', 'return 1+x', 'return!a.b', 'return-x*2', 'return 3}', 'return -3}', 'return o.a', 'return{}.x',
    'case"x":', 'case-1:', 'case!a:', 'case 3:', 'case[1][0]:', 'var{p,q=2}=', 'let[l]=[4],{c}={c:5}']) {
    assert.ok(spacing.includes(text), text);
  }

  // Left-associative chains are as deep as they are long. The compressor walks
  // them with a list, and joining literals stays linear in the source size.
  // Node itself overflows on much longer chains; this length still exceeds the inline list.
  const terms = 1500;
  const chained = 'var x="s",o={n:0,get b(){this.n++;return this}},f=function(){f.n=(f.n||0)+1;return f};' +
    'globalThis.result=[(' + '"a"+'.repeat(terms) + '"z").length,(x+' + '"b"+'.repeat(terms) + '"z").length,' +
    '(' + '1+'.repeat(terms) + 'x).length,(' + 'x&&'.repeat(terms) + '7),o' + '.b'.repeat(terms) + '.n,o' + '["b"]'.repeat(terms) +
    '.n,f' + '()'.repeat(terms) + '.n,(' + 'undefined||'.repeat(terms) + '3)];';
  const chainFile = write('chains.js', chained);
  for (const flags of [[], ['--no-mangle']]) {
    const output = emit('minify', chainFile, flags);
    assert.equal(outcome(output), outcome(chained), 'chains ' + flags.join(' '));
    // Short literals join until the accumulated one is long; then joining stops to stay linear.
    assert.ok(output.length < chained.length);
    assert.ok(output.includes('"' + 'a'.repeat(30)) && output.split('"a"+').length < terms / 2);
  }
  // The value of a script's last statement is visible to eval and to the embedder.
  for (const script of ['var c = 0; if (c) 5;', 'var c = 0; if (!c) 5;', 'var c = 0; 7; if (c);', 'var c = 1; if (c) { 1; 2; } else 3;',
    'var c = 0; if (c) 1; else { 2; 3; }', 'var c = 0; 4; if (c) { 5; }', 'var c = 2; lab: { if (c) { 6; break lab; } 7; }',
    'var c = 3; while (c--) { if (c) { c; } else { 9; } }', '"use strict"; var c = 1; if (c) c;']) {
    const completion = code => JSON.stringify([vm.runInNewContext(code, {})]);
    assert.equal(completion(emit('minify', write('completion.js', script))), completion(script), script);
  }
}

// Random programs built from the statement and test forms that compression
// rewrites. Each function logs every operand it evaluates and runs with all
// eight input combinations, so a changed order or branch changes the result.
function verifyCompressionFuzz(count) {
  let state = 0x2545f491;
  const random = limit => { state ^= state << 13; state ^= state >>> 17; state ^= state << 5; return (state >>> 0) % limit; };
  const pick = (...choices) => choices[random(choices.length)];
  let serial = 0;
  const test = depth => {
    const leaf = () => pick('p("' + (serial++) + '",a)', 'p("' + (serial++) + '",b)', 'p("' + (serial++) + '",c)', 'v===undefined', 'typeof v==="undefined"',
      'p("' + (serial++) + '",a)', 'p("' + (serial++) + '",b)', 'true', 'false', '0', '"k"==="k"', '"k"!=="k"', 'null');
    if (depth <= 0) return leaf();
    switch (random(8)) {
      case 0: return '!' + test(depth - 1);
      case 1: return '(' + test(depth - 1) + '&&' + test(depth - 1) + ')';
      case 2: return '(' + test(depth - 1) + '||' + test(depth - 1) + ')';
      case 3: return '(' + test(depth - 1) + '??' + test(depth - 1) + ')';
      case 4: return '(v=' + test(depth - 1) + ')';
      case 5: return '(' + test(depth - 1) + '?' + test(depth - 1) + ':' + test(depth - 1) + ')';
      case 6: return '(' + test(depth - 1) + ',' + test(depth - 1) + ')';
      default: return leaf();
    }
  };
  const effect = () => pick('t("' + (serial++) + '")', 'v=t("' + (serial++) + '")', 't("' + (serial++) + '"),t("' + (serial++) + '")',
    'v||(v=' + test(1) + ')', test(1), 'o.g', 'o.s=' + (serial++), 'f=()=>{return ' + test(1) + '}');
  const body = depth => pick(() => statement(depth), () => '{' + statements(depth) + '}', () => '{' + statement(depth) + '}', () => '{}', () => ';')();
  const statement = depth => {
    if (depth <= 0) return pick(effect() + ';', 'return ' + test(1) + ';', 'return;', effect() + ';', 'var w=' + test(0) + ';');
    switch (random(13)) {
      case 0: case 1: return 'if(' + test(2) + ')' + body(depth - 1);
      case 2: case 3: return 'if(' + test(2) + ')' + body(depth - 1) + 'else ' + body(depth - 1);
      case 4: return '{' + statements(depth - 1) + '}';
      case 5: return 'for(let i=0;i<2;i++)' + body(depth - 1);
      case 6: return 'do ' + body(depth - 1) + 'while(t("' + (serial++) + '")&&0);';
      case 7: return 'try{' + statements(depth - 1) + 'if(' + test(1) + ')throw "x";}catch(e){' + statements(depth - 1) + '}';
      case 8: return 'switch(' + test(1) + '){case true:' + statements(depth - 1) + 'case false:' + statements(depth - 1) + 'break;default:' + statement(depth - 1) + '}';
      case 9: return 'if(' + test(1) + '){let z=' + test(0) + ';t(z);}';
      case 10: return 'if(' + test(1) + '){return ' + test(1) + ';}else{' + statements(depth - 1) + '}';
      case 11: {
        const label = 'L' + (serial++);
        return label + ':for(const k of [1,2]){if(' + test(1) + ')' +
          pick('continue ' + label + ';', 'break ' + label + ';', 'continue;', 'break;') + 'else ' + body(depth - 1) + '}';
      }
      default: return statement(0);
    }
  };
  const statements = depth => Array.from({ length: random(4) }, () => statement(depth)).join('');
  const functions = Array.from({ length: count }, (_, i) => 'function f' + i + '(a,b,c){var v,f;' + statements(3) + statements(3) + '}');
  let checked = 0;
  for (let start = 0; start < functions.length; start += 50) {
    const slice = functions.slice(start, start + 50);
    const source = 'var log=[];function t(n){log.push(n);return n}function p(n,x){log.push(n);return x}' +
      'var o={get g(){log.push("g");return 1},set s(x){log.push("s"+x)}};' + slice.join('\n') +
      '\nglobalThis.result=[' + slice.map((_, i) => 'f' + (start + i)) + '].map(fn=>{var out=[];' +
      'for(var a of [0,1])for(var b of [null,2])for(var c of [undefined,""]){var r;try{r=fn(a,b,c)}catch(e){r="threw "+e}' +
      'out.push([typeof r==="function"?"fn":r,log.splice(0)])}return out});';
    const file = write('fuzz-' + start + '.js', source);
    const expected = outcome(source);
    for (const flags of [[], ['--no-mangle'], ['--mangle-names']]) {
      const output = emit('minify', file, flags);
      assert.equal(outcome(output), expected, 'fuzz ' + start + ' ' + flags.join(' '));
      assert.ok(output.length < source.length);
    }
    checked += slice.length;
  }
  return checked;
}

function verifyJSXNames() {
  const factory = '({render:(kind,props,...children)=>[kind,props,...children]})';
  const body = [
    'function tree(factory, fragments, LongComponent, longNamespace, longLabel) {',
    '  return <><LongComponent label={longLabel}><longNamespace.Controls.Item data-test="yes" />',
    '    <widget-name /><lowercase /><this.Widget /><svg:path />',
    '    {((LongComponent) => <LongComponent />)("shadow")}</LongComponent></>;',
    '}',
    'globalThis.result=tree.call({Widget:"instance"},' + factory + ',{empty:"fragment"},"outer",{Controls:{Item:"member"}},"label");',
  ].join('\n');
  const directive = '/** @jsx factory.render */\n/** @jsxFrag fragments.empty */\n';
  const jsxOptions = ['--jsx-pragma=factory.render', '--jsx-pragma-frag=fragments.empty'];
  const expected = ['fragment', null, ['outer', {label:'label'}, ['member', {'data-test':'yes'}],
    ['widget-name', null], ['lowercase', null], ['instance', null], ['svg:path', null], ['shadow', null]]];
  for (const header of [true, false]) {
    const source = (header ? directive : '') + body;
    const file = write('tree.jsx', source);
    const flags = header ? [] : jsxOptions;
    for (const passes of [[], ['--no-compress'], ['--no-mangle'], ['--no-compress', '--no-mangle']]) {
      const output = emit('minify', file, [...flags, ...passes]);
      if (header) assert.ok(output.includes('@jsx factory.render') && output.includes('@jsxFrag fragments.empty'));
      assert.equal(output.includes('LongComponent'), passes.includes('--no-mangle'));
      assert.ok(output.includes('widget-name') && output.includes('lowercase') && output.includes('svg:path'));
      const optimized = write('optimized.jsx', output);
      const lowered = emit('transform', optimized, ['--jsx=classic', '--jsx-allow-namespaces', ...flags]);
      assert.deepEqual(JSON.parse(outcome(lowered)), expected);
      if (reference) {
        const oracle = require('../../bench/node_modules/oxc-transform');
        const jsx = { runtime: 'classic', throwIfNamespace: false };
        if (!header) Object.assign(jsx, {pragma:'factory.render', pragmaFrag:'fragments.empty'});
        const transformed = oracle.transformSync(file, output, { jsx });
        assert.deepEqual(transformed.errors, []);
        assert.deepEqual(JSON.parse(outcome(transformed.code)), expected);
      }
      if (sdk) {
        const result = sdk.minifySync(file, source, { compress: !passes.includes('--no-compress'),
          mangle: !passes.includes('--no-mangle'), jsx: header ? {} : {pragma:'factory.render', pragmaFrag:'fragments.empty'} });
        assert.deepEqual(result, { code: output, map: null, errors: [] });
      }
    }
  }

}

function verifyJSXTagMappings() {
  const collisions = '/** @jsx A */\n/** @jsxFrag B */\n' +
    'function show(LongView){return <><LongView></LongView></>;}globalThis.result=show("local");';
  const mapped = emit('minify', write('reserved.jsx', collisions), ['--sourcemap']);
  const [code, encoded] = mapped.split('//# sourceMappingURL=data:application/json;base64,');
  const match = code.match(/function show\(([^)]+)\)/);
  assert.ok(match && !['A', 'B', 'LongView'].includes(match[1]));
  assert.ok(code.includes('<' + match[1] + '></' + match[1] + '>'));
  const map = new SourceMap(JSON.parse(Buffer.from(encoded, 'base64')));
  const offset = (text, index) => {
    const lines = text.slice(0, index).split('\n');
    return [lines.length - 1, lines.at(-1).length];
  };
  for (const prefix of ['<', '</']) {
    const location = offset(code, code.indexOf(prefix + match[1] + '>') + prefix.length);
    const original = offset(collisions, collisions.indexOf(prefix + 'LongView>') + prefix.length);
    const entry = map.findEntry(...location);
    assert.deepEqual([entry.originalLine, entry.originalColumn], original);
  }
  const free = emit('transform', write('reserved-small.jsx', code), ['--jsx=classic']);
  assert.deepEqual(JSON.parse(outcome('const A=(kind,props,...kids)=>[kind,...kids], B="frag";' + free)), ['frag',['local']]);

}

function verifyJSXAliasCapacity() {
  const widgets = Array.from({ length: 96 }, (_, i) => 'LocalWidget' + i);
  const children = widgets.map(name => '<' + name + ' />').join('');
  const source = 'const React={Fragment:"fragment",createElement:(tag,props,...kids)=>[tag,...kids]};' +
    'function render(' + widgets.join(',') + '){return <>' + children + '</>;}' +
    'globalThis.result=render(' + widgets.map((_, i) => i).join(',') + ');';
  const file = write('many-widgets.jsx', source);
  const output = emit('minify', file);
  assert.doesNotMatch(output, /LocalWidget/);
  const expected = ['fragment', ...widgets.map((_, i) => [i])];
  assert.deepEqual(JSON.parse(outcome(emit('transform', write('many-small.jsx', output), ['--jsx=classic']))), expected);
}

function verifyJSXRuntimes() {
  const automatic = '/** @jsxRuntime automatic */\n/** @jsxImportSource fixture-ui */\n' +
    'function render(LongName){return <><LongName px={7}/></>;}globalThis.result=render("view");';
  const file = write('automatic.jsx', automatic);
  const optimized = emit('minify', file);
  assert.ok(optimized.includes('@jsxImportSource fixture-ui') && !optimized.includes('LongName'));
  const mock = 'const require=name=>{if(name!=="fixture-ui/jsx-runtime")throw Error(name);' +
    'return {Fragment:"fragment",jsx:(type,props)=>[type,props]};};';
  const expectedAuto = ['fragment', {children:['view', {px:7}]}];
  const small = write('automatic-small.jsx', optimized);
  assert.deepEqual(JSON.parse(outcome(mock + emit('transform', small, ['--jsx=automatic', '--source-type=script']))), expectedAuto);
  if (reference) {
    const oracle = require('../../bench/node_modules/oxc-transform');
    const lowered = oracle.transformSync(file, optimized, {sourceType:'script', jsx:{runtime:'automatic'}});
    assert.deepEqual(lowered.errors, []);
    assert.deepEqual(JSON.parse(outcome(mock + lowered.code)), expectedAuto);
  }

  const late = 'function show(React, LongView){return <LongView />;}\n/*! @jsx wrongFactory */\n' +
    'globalThis.result=show({createElement:tag=>tag},"default");';
  const retained = emit('minify', write('default.jsx', late));
  assert.ok(retained.includes('/*! @jsx wrongFactory */'));
  assert.ok(retained.indexOf('function show') < retained.indexOf('@jsx wrongFactory'));
  assert.equal(JSON.parse(outcome(emit('transform', write('default-small.jsx', retained), ['--jsx=classic']))), 'default');
  console.log('JSX components, member tags, intrinsic tags, source maps and implicit factory bindings passed.');
}

// Oxc and TypeScript recognize different comment forms. Each compiler should
// produce the same runtime result on the original and optimized input it sees.
function verifyJSXCompilerDirectives() {
  const oracle = require('../../bench/node_modules/oxc-transform');
  const ts = require('../../bench/node_modules/typescript');
  const body = 'function draw(React, Fábrica, Other, LongView){return <LongView />;}' +
    'globalThis.result=draw({createElement:v=>"React "+v},v=>"local "+v,v=>"other "+v,"component");';
  const lower = [
    (file, source) => oracle.transformSync(file, source, { jsx: { runtime: 'classic' } }).code,
    (file, source) => ts.transpileModule(source, { fileName: file, compilerOptions: { jsx: ts.JsxEmit.React, allowJs: true } }).outputText,
  ];
  for (const header of [
    '/** @jsx Fábrica */', '// @jsx Fábrica', '/** @JSX Fábrica */',
    '/** words*@jsx Fábrica */', '/** @jsx\u00a0Fábrica */', '/** @jsx\nFábrica */',
    '/** @jsx Fábrica */\n/** @jsx Other */', '/** `@jsx Other` */',
  ]) {
    const source = header + '\n' + body;
    const file = write('directives.jsx', source);
    const minified = emit('minify', file);
    assert.doesNotMatch(minified, /LongView/);
    for (const transform of lower) {
      assert.equal(outcome(transform(file, minified)), outcome(transform(file, source)), header);
    }
  }
  const typed = '/** @jsx Factory.render */\nfunction select<T>(Factory:any, Widget:any, data:T){return <Widget value={data} />;}globalThis.result=select({render:(tag:any,props:any)=>[tag,props.value]},"view",7);';
  const tsx = write('typed-pragma.tsx', typed);
  for (const transform of lower) {
    assert.equal(outcome(transform(tsx, emit('minify', tsx))), outcome(transform(tsx, typed)));
  }
}

function verifyTypedInitializers() {
  const ts = require('../../bench/node_modules/typescript');
  const source = [
    'declare const ambient = true; declare namespace N { const inside = false; }',
    'export const numeric = 1 + 2; export const flag = true as const;',
    'export const tuple = [true, -1] as const; export type Flag = true | false;',
    'export const sum = (x: number) => x + numeric; const first = 1; const second = first;',
  ].join('\n');
  function declarations(file) {
    const program = ts.createProgram([file], { declaration: true, emitDeclarationOnly: true, noLib: true });
    assert.deepEqual(program.getSyntacticDiagnostics().map(d => d.code), []);
    assert.deepEqual(program.getSemanticDiagnostics().map(d => d.code), []);
    let output = '';
    program.emit(undefined, (_, text) => { output += text; });
    assert.ok(output.includes('numeric: number'));
    return output;
  }
  for (const suffix of ['.ts', '.tsx']) {
    const file = write('typed' + suffix, source);
    const compressed = write('typed-small' + suffix, emit('minify', file));
    assert.equal(declarations(compressed), declarations(file));
  }
}

function verifyMappings() {
  const source = 'const icon="🌱";\nconst folded = 17 * 3;\nconst truth = false;\nglobalThis.result = [icon,folded,truth];';
  const output = emit('minify', write('mapped.mjs', source), ['--sourcemap']);
  const [code, encoded] = output.split('//# sourceMappingURL=data:application/json;base64,');
  const map = new SourceMap(JSON.parse(Buffer.from(encoded, 'base64')));
  for (const [generated, original] of [['folded=', 'folded ='], ['51', '17 *'], ['truth=', 'truth ='], ['!1', 'false'], ['globalThis', 'globalThis']]) {
    const lines = source.slice(0, source.indexOf(original)).split('\n');
    assert.ok(code.includes(generated), generated);
    const entry = map.findEntry(0, code.indexOf(generated));
    assert.equal(entry.originalLine, lines.length - 1, generated);
    assert.equal(entry.originalColumn, lines.at(-1).length, generated);
  }
  const named = '/* 🌱 */ function total(longInput){const longResult=longInput*7;return [longResult,{longInput},longInput]}';
  const mappedNames = emit('minify', write('mapped-names.js', named), ['--sourcemap']);
  const [short, encodedNames] = mappedNames.split('//# sourceMappingURL=data:application/json;base64,');
  const namesMap = new SourceMap(JSON.parse(Buffer.from(encodedNames, 'base64')));
  for (const [generated, source] of [['e)', 'longInput)'], ['t=', 'longResult='], ['e*', 'longInput*'],
    ['t,', 'longResult,'], ['e}', 'longInput}'], ['e]', 'longInput]']]) {
    assert.ok(short.includes(generated), generated);
    const entry = namesMap.findEntry(0, short.indexOf(generated));
    assert.equal(entry.originalLine, 0);
    assert.equal(entry.originalColumn, named.indexOf(source), generated);
  }
  const bad = spawnSync(binary, ['minify', write('bad.js', 'let = ;')], { encoding: 'utf8' });
  assert.notEqual(bad.status, 0);
  assert.equal(bad.stdout, '');
}

// Decode every segment of a version 3 source map with one source.
function decodeMappings(map) {
  const digits = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const segments = [];
  let line = 0, originalLine = 0, originalColumn = 0;
  for (const row of map.mappings.split(';')) {
    let column = 0;
    for (const segment of row.split(',').filter(Boolean)) {
      const fields = [];
      let value = 0, shift = 0;
      for (const char of segment) {
        const digit = digits.indexOf(char);
        assert.ok(digit >= 0);
        value += (digit & 31) << shift;
        if (digit & 32) { shift += 5; continue; }
        fields.push(value & 1 ? -(value >> 1) : value >> 1);
        value = shift = 0;
      }
      column += fields[0];
      if (fields.length >= 4) {
        assert.equal(fields[1], 0);
        originalLine += fields[2];
        originalColumn += fields[3];
        segments.push([line, column, originalLine, originalColumn]);
      }
    }
    line++;
  }
  return segments;
}

// Compression moves and merges statements. Every mapped position must still
// point at the token it was printed from: without renaming, an identifier in
// the output maps to the same identifier in the source.
function verifyCompressedMappings() {
  const word = /^[A-Za-z_$][\w$]*/;
  const sources = Object.entries(compressionCases).map(([name, source]) => [write(name, source), source]);
  for (const name of ['lodash.js', 'jquery.js', 'react.dev.js']) {
    const file = path.join(root, 'bench/real_world', name);
    if (fs.existsSync(file)) sources.push([file, fs.readFileSync(file, 'utf8')]);
  }
  let identifiers = 0;
  for (const [file, source] of sources) {
    const lines = source.split('\n');
    for (const flags of [['--no-mangle'], []]) {
      const [code, encoded] = emit('minify', file, ['--sourcemap', ...flags]).split('//# sourceMappingURL=data:application/json;base64,');
      assert.equal(code.trimEnd() + '\n', emit('minify', file, flags).trimEnd() + '\n', file);
      const map = JSON.parse(Buffer.from(encoded, 'base64'));
      const generated = code.split('\n');
      let previous = [-1, -1];
      for (const [line, column, originalLine, originalColumn] of decodeMappings(map)) {
        assert.ok(line > previous[0] || column >= previous[1], file + ' mappings are ordered');
        previous = [line, column];
        assert.ok(originalLine >= 0 && originalLine < lines.length && originalColumn >= 0 && originalColumn <= lines[originalLine].length, file);
        const printed = word.exec(generated[line].slice(column));
        const original = word.exec(lines[originalLine].slice(originalColumn));
        if (!printed || !original || flags.length === 0) continue;
        // `void 0` maps to the `undefined` it replaces.
        if (printed[0] === 'void' && original[0] === 'undefined') continue;
        if (printed[0] === 'let' && original[0] === 'const') continue;
        // A merged `return` or `throw` maps to the `if` statement it replaces.
        if ((printed[0] === 'return' || printed[0] === 'throw') && original[0] === 'if') continue;
        assert.equal(printed[0], original[0], file + ' ' + line + ':' + column + ' maps to ' + originalLine + ':' + originalColumn);
        identifiers++;
      }
    }
  }
  assert.ok(identifiers > 10000);
  return identifiers;
}

function verifySDKMappings() {
  for (const extension of ['js', 'mjs', 'cjs', 'jsx', 'ts', 'tsx']) {
    let source = '/* 🌱 */ function total(longInput){const value=2*3;return longInput+value}';
    if (extension === 'jsx' || extension === 'tsx') source += '\nconst view=<p>{total(4)}</p>;';
    if (extension === 'ts' || extension === 'tsx') source += '\nexport const typed: number=total(5);';
    const file = write('sdk.' + extension, source);
    for (const compress of [false, true]) {
      for (const mangle of [false, true]) {
        const flags = ['--sourcemap'];
        if (!compress) flags.push('--no-compress');
        if (!mangle) flags.push('--no-mangle');
        const [code, encoded] = emit('minify', file, flags).split('//# sourceMappingURL=data:application/json;base64,');
        const map = JSON.parse(Buffer.from(encoded, 'base64'));
        assert.deepEqual(sdk.minifySync(file, source, { compress, mangle, sourceMap: true }),
          { code, map, errors: [] }, extension + ' ' + flags.join(' '));
      }
    }
  }
}

function verifyJSXCorpus(verifier) {
  const { parseSync } = require('../../bench/node_modules/oxc-parser');
  const files = [];
  for (const [directory, name] of [
    ['tests/vendor/estree-conformance/tests/acorn-jsx/pass', file => file.endsWith('.jsx')],
    ['tests/vendor/babel/packages/babel-parser/test/fixtures/jsx', file => file === 'input.js'],
  ]) {
    const directories = [path.join(root, directory)];
    for (const dir of directories) {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const file = path.join(dir, entry.name);
        if (entry.isDirectory()) directories.push(file);
        else if (name(entry.name)) files.push(file);
      }
    }
  }
  const checkout = path.resolve(root, '../oxc');
  const tracked = execFileSync('git', ['-C', checkout, 'ls-files', '-z', '--', '*.jsx'], { encoding: 'utf8' });
  for (const relative of tracked.split('\0').filter(Boolean)) files.push(path.join(checkout, relative));
  const original = path.join(temp, 'upstream.jsx');
  const generated = path.join(temp, 'upstream-small.jsx');
  const compressed = path.join(temp, 'upstream-compressed.jsx');
  let checked = 0, invalid = 0, events = 0;
  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    // Babel's negative inputs include comma expressions in JSX containers.
    // Oxc reports these during its early-error pass.
    if (parseSync(original, source, { showSemanticErrors: true }).errors.length) { invalid++; continue; }
    fs.writeFileSync(original, source);
    const output = emit('minify', original);
    if (sdk) assert.deepEqual(sdk.minifySync(original, source), { code: output, map: null, errors: [] }, file);
    assert.deepEqual(parseSync(generated, output, { showSemanticErrors: true }).errors, [], file);
    // Renaming alone keeps every binding. So does renaming the compressed program.
    fs.writeFileSync(generated, emit('minify', original, ['--no-compress']));
    events += compareBindings(verifier, original, generated);
    fs.writeFileSync(compressed, emit('minify', original, ['--no-mangle']));
    fs.writeFileSync(generated, output);
    compareBindings(verifier, compressed, generated);
    checked++;
  }
  assert.ok(checked > 0 && events > 0);
  console.log('Oxc matched ' + events + ' declaration/reference events on ' + checked +
    ' upstream JSX fixtures. Its parser and early-error pass rejected ' + invalid + ' original inputs.');
}

// Mangling only renames, so Oxc's semantic analyzer must see the same
// declarations, scopes and references before and after it. Compression
// removes blocks and whole statements, so it is checked by running the code.
function compareBindings(verifier, before, after) {
  return Number(execFileSync(verifier, [before, after], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim());
}

// Oxc 0.127.0 resolves `bindFunction = bind` in typescript.js to an outer
// `bind` instead of the function declared later in the same scope (see
// default-later.js above). Renaming functions exposes that one reference.
function compareNamedBindings(verifier, relative, before, after) {
  try {
    return compareBindings(verifier, before, after);
  } catch (error) {
    const offset = /Original byte (\d+): Reference/.exec(String(error.stderr));
    assert.ok(relative === 'typescript.js' && offset, relative + ': ' + error.stderr);
    const text = fs.readFileSync(before).subarray(Number(offset[1]) - 13, Number(offset[1]) + 4).toString();
    assert.equal(text, 'bindFunction=bind', relative);
    return 0;
  }
}

function verifyCorpus() {
  const { parseSync } = require('../../bench/node_modules/oxc-parser');
  const { fingerprint, loosen, threw } = require('./minify_fingerprint');
  const { readChecksums, verifyCorpus } = require('./verify_real_world_inputs');
  const corpus = path.join(root, 'bench/real_world');
  verifyCorpus(corpus);
  const probes = {
    'lodash.js': '[_.map([2,3],x=>x*x), _.get({a:[7]},"a[0]"), _.uniq([1,2,1])]',
    'd3.js': '[d3.extent([9,-4,2]), d3.scaleLinear().domain([0,4]).range([10,30])(2)]',
    'react.dev.js': '[React.version, React.createElement("i",{id:2},"x").props, React.Children.count([1,"b"])]',
    'typescript.js': '[ts.version, ts.transpileModule("export const f=(x?:number)=>x ?? 3;",{compilerOptions:{target:ts.ScriptTarget.ES5}}).outputText]',
  };
  const modes = { full: [], renamed: ['--no-compress'], compressed: ['--no-mangle'], named: ['--mangle-names'] };
  // What each output may differ in from its source when both are run.
  const loose = { compressed: {}, full: { messages: true }, named: { names: true, messages: true } };
  let compactBytes = 0, minifiedBytes = 0, namedBytes = 0, checkedProbes = 0, bindings = 0, compressedBindings = 0;
  let executed = 0, calls = 0, described = 0, modules = 0, unstable = 0, failedToLoad = 0;
  const checkBindings = process.argv.includes('--bindings');
  const verifier = path.join(root, 'bench/oxc_compare/target/release/examples',
    process.platform === 'win32' ? 'minify_bindings.exe' : 'minify_bindings');
  for (const relative of readChecksums().keys()) {
    const file = path.join(corpus, relative);
    const source = fs.readFileSync(file, 'utf8');
    const compact = emit('codegen', file, ['--minified']);
    const outputs = {}, files = {};
    for (const [mode, flags] of Object.entries(modes)) {
      outputs[mode] = emit('minify', file, flags);
      const errors = parseSync(file, outputs[mode]).errors.map(error => [error.message, error.labels]);
      assert.deepEqual(errors, [], relative + ' ' + mode);
      files[mode] = path.join(temp, mode + path.extname(file));
      fs.writeFileSync(files[mode], outputs[mode]);
    }
    if (sdk) {
      const result = sdk.minifySync(file, source);
      assert.deepEqual(result.errors, [], relative);
      assert.ok(result.code === outputs.full, relative + ' SDK output differs from CLI');
    }
    assert.ok(Buffer.byteLength(outputs.full) <= Buffer.byteLength(compact), relative);
    if (checkBindings) {
      bindings += compareBindings(verifier, file, files.renamed);
      compressedBindings += compareBindings(verifier, files.compressed, files.full);
      compareNamedBindings(verifier, relative, files.compressed, files.named);
    }
    compactBytes += Buffer.byteLength(compact);
    minifiedBytes += Buffer.byteLength(outputs.full);
    namedBytes += Buffer.byteLength(outputs.named);
    if (Object.hasOwn(probes, relative)) {
      const probe = '\n;globalThis.result=' + probes[relative] + ';';
      for (const mode of Object.keys(modes)) assert.equal(outcome(outputs[mode] + probe), outcome(source + probe), relative + ' ' + mode);
      checkedProbes++;
    }
    // A module cannot be evaluated as a script.
    if (relative.endsWith('.mjs') || /^\s*(import|export)\s/m.test(source)) { modules++; continue; }
    // Konva tests whether its own source still spells a parameter `param`.
    const hide = relative === 'batch2/konva.js';
    const shown = (code, withCalls) => {
      const text = fingerprint(code, withCalls);
      return hide ? text.split('\n').filter(line => !line.includes('.isUnminified[')).join('\n') : text;
    };
    // Some libraries read the clock or random numbers in ways the sandbox does not pin.
    // stacktrace-js returns the line and column of its own frames, which any reprint moves.
    let withCalls = relative !== 'batch4/stacktrace-js.js';
    let expected = shown(source, withCalls);
    if (!withCalls || expected !== shown(source, true)) {
      withCalls = false;
      expected = shown(source, false);
      unstable++;
    }
    for (const [mode, options] of Object.entries(loose)) {
      const actual = shown(outputs[mode], withCalls);
      // cash-dom's serialize() writes the `name` of each element. With the stand-in
      // those elements are its own functions, whose names --mangle-names changes.
      const named = relative === 'batch4/cash-dom.js' && mode === 'named';
      const compared = text => {
        const loose = loosen(text, options);
        return named ? loose.split('\n').filter(line => !line.includes('.fn.serialize(#')).join('\n') : loose;
      };
      assert.ok(compared(actual) === compared(expected), relative + ' behaves differently after minify ' + modes[mode].join(' '));
    }
    executed++;
    if (threw(expected)) failedToLoad++;
    calls += (expected.match(/\(#\d\) /g) || []).length;
    described += (expected.match(/\(#\d\)/g) || []).length;
  }
  assert.equal(checkedProbes, Object.keys(probes).length);
  assert.ok(minifiedBytes < compactBytes);
  // The pinned corpus yields about 275,000 lines describing what the calls returned.
  assert.ok(executed > 300 && described > 100000);
  if (checkBindings) {
    assert.ok(bindings > 0 && compressedBindings > 0);
    console.log('Oxc matched ' + bindings + ' declarations and references in source order after renaming, and ' +
      compressedBindings + ' between the compressed program and its renamed form.');
    verifyJSXCorpus(verifier);
  }
  console.log(executed + ' scripts left the same globals and exports and returned the same results from ' + calls +
    ' exported-function calls under compression, renaming and --mangle-names (' + modules + ' modules not executed, ' +
    unstable + ' scripts compared without calls, ' + failedToLoad + ' scripts still throw while loading).');
  console.log(readChecksums().size + ' real outputs reparsed in four pass combinations, ' + checkedProbes +
    ' library API probes passed. Compact ' + compactBytes + ' bytes, minified ' + minifiedBytes +
    ' bytes, with --mangle-names ' + namedBytes + ' bytes.');
  if (sdk) console.log('CLI and SDK outputs matched on the full corpus and source maps matched on six file types.');
}

try {
  const operations = verifyOperators();
  verifyEffects();
  verifyNames();
  verifyNameSlots();
  verifyCompression();
  const fuzzed = verifyCompressionFuzz(600);
  verifyJSXNames();
  verifyJSXTagMappings();
  verifyJSXAliasCapacity();
  verifyJSXRuntimes();
  if (reference) {
    verifyJSXCompilerDirectives();
    verifyTypedInitializers();
  }
  verifyMappings();
  const mapped = verifyCompressedMappings();
  if (sdk) verifySDKMappings();
  if (process.argv.includes('--corpus')) verifyCorpus();
  console.log(mapped + ' identifiers in compressed output map to the same identifier in the source.');
  console.log(Object.keys(compressionCases).length + ' compression programs and ' + fuzzed + ' generated functions matched Node under every pass combination.');
  console.log('Minifier passed ' + operations + ' numeric and boolean cases, evaluation-order, scope and source-map checks' +
    (reference ? ' with the pinned Oxc reference.' : '.'));
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
