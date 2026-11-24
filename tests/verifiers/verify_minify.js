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
  assert.equal(emit('minify', siblings), 'function one(a){return a;}function two(a){return a;}');

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
  assert.equal(shared, 'function one(b){return function(a){return a+a+a+b;};}function two(b,a){return a*a*a*a+b;}');
  // Many bindings in one scope use every two-character alias before a third character.
  const locals = Array.from({ length: 400 }, (_, i) => 'localValue' + i);
  const wide = 'function wide(){var ' + locals.map((name, i) => name + '=' + i).join(',') + ';return ' + locals.join('+') + ';}globalThis.result=wide();';
  const small = emit('minify', write('wide.js', wide), ['--no-compress']);
  assert.equal(outcome(small), outcome(wide));
  assert.ok(Math.max(...small.slice(0, small.indexOf(';return')).match(/[A-Za-z_$][\w$]*(?==)/g).map(name => name.length)) <= 2);
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
  for (const [generated, source] of [['a)', 'longInput)'], ['b=', 'longResult='], ['a*', 'longInput*'],
    ['b,', 'longResult,'], ['a}', 'longInput}'], ['a]', 'longInput]']]) {
    assert.ok(short.includes(generated), generated);
    const entry = namesMap.findEntry(0, short.indexOf(generated));
    assert.equal(entry.originalLine, 0);
    assert.equal(entry.originalColumn, named.indexOf(source), generated);
  }
  const bad = spawnSync(binary, ['minify', write('bad.js', 'let = ;')], { encoding: 'utf8' });
  assert.notEqual(bad.status, 0);
  assert.equal(bad.stdout, '');
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
    fs.writeFileSync(generated, output);
    events += Number(execFileSync(verifier, [original, generated], { encoding: 'utf8' }).trim());
    checked++;
  }
  assert.ok(checked > 0 && events > 0);
  console.log('Oxc matched ' + events + ' declaration/reference events on ' + checked +
    ' upstream JSX fixtures. Its parser and early-error pass rejected ' + invalid + ' original inputs.');
}

function verifyCorpus() {
  const { parseSync } = require('../../bench/node_modules/oxc-parser');
  const { readChecksums, verifyCorpus } = require('./verify_real_world_inputs');
  const corpus = path.join(root, 'bench/real_world');
  verifyCorpus(corpus);
  const probes = {
    'lodash.js': '[_.map([2,3],x=>x*x), _.get({a:[7]},"a[0]"), _.uniq([1,2,1])]',
    'd3.js': '[d3.extent([9,-4,2]), d3.scaleLinear().domain([0,4]).range([10,30])(2)]',
    'react.dev.js': '[React.version, React.createElement("i",{id:2},"x").props, React.Children.count([1,"b"])]',
    'typescript.js': '[ts.version, ts.transpileModule("export const f=(x?:number)=>x ?? 3;",{compilerOptions:{target:ts.ScriptTarget.ES5}}).outputText]',
  };
  let compactBytes = 0, minifiedBytes = 0, checkedProbes = 0, bindings = 0;
  const checkBindings = process.argv.includes('--bindings');
  const verifier = path.join(root, 'bench/oxc_compare/target/release/examples',
    process.platform === 'win32' ? 'minify_bindings.exe' : 'minify_bindings');
  const generated = path.join(temp, 'generated.js');
  for (const relative of readChecksums().keys()) {
    const file = path.join(corpus, relative);
    const compact = emit('codegen', file, ['--minified']);
    const minified = emit('minify', file);
    if (sdk) {
      const result = sdk.minifySync(file, fs.readFileSync(file, 'utf8'));
      assert.deepEqual(result.errors, [], relative);
      assert.ok(result.code === minified, relative + ' SDK output differs from CLI');
    }
    const errors = parseSync(file, minified).errors.map(error => [error.message, error.labels]);
    assert.deepEqual(errors, [], relative);
    assert.ok(Buffer.byteLength(minified) <= Buffer.byteLength(compact), relative);
    if (checkBindings) {
      fs.writeFileSync(generated, minified);
      bindings += Number(execFileSync(verifier, [file, generated], { encoding: 'utf8' }).trim());
    }
    compactBytes += Buffer.byteLength(compact);
    minifiedBytes += Buffer.byteLength(minified);
    if (Object.hasOwn(probes, relative)) {
      const probe = '\n;globalThis.result=' + probes[relative] + ';';
      assert.equal(outcome(minified + probe), outcome(fs.readFileSync(file, 'utf8') + probe), relative);
      checkedProbes++;
    }
  }
  assert.equal(checkedProbes, Object.keys(probes).length);
  assert.ok(minifiedBytes < compactBytes);
  if (checkBindings) {
    assert.ok(bindings > 0);
    console.log('Oxc matched ' + bindings + ' declarations and references in source order.');
    verifyJSXCorpus(verifier);
  }
  console.log(readChecksums().size + ' real outputs reparsed, ' + checkedProbes +
    ' library API probes passed. Compact ' + compactBytes + ' bytes, minified ' + minifiedBytes + ' bytes.');
  if (sdk) console.log('CLI and SDK outputs matched on the full corpus and source maps matched on six file types.');
}

try {
  const operations = verifyOperators();
  verifyEffects();
  verifyNames();
  verifyNameSlots();
  verifyJSXNames();
  verifyJSXTagMappings();
  verifyJSXAliasCapacity();
  verifyJSXRuntimes();
  if (reference) {
    verifyJSXCompilerDirectives();
    verifyTypedInitializers();
  }
  verifyMappings();
  if (sdk) verifySDKMappings();
  if (process.argv.includes('--corpus')) verifyCorpus();
  console.log('Minifier passed ' + operations + ' numeric and boolean cases, evaluation-order, scope and source-map checks' +
    (reference ? ' with the pinned Oxc reference.' : '.'));
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
