'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

const binary = join(__dirname, '../..', 'bin', 'kessel');
const dir = mkdtempSync(join(tmpdir(), 'kessel-codegen-comments-'));
const input = join(dir, 'input.mjs');
const output = join(dir, 'output.mjs');
const source = [
  '#!/usr/bin/env node',
  '/*! banner */',
  '// leading note',
  'const events = []; // trailing note',
  '/** entry point */',
  'function make(value) {',
  '  // function leading note',
  '  { /* inside an empty block */ }',
  '  events.push(value); // function trailing note',
  '  return value;',
  '}',
  'class Marker {',
  '  /** member docs */',
  '  field = class { /* empty class */ }; // field note',
  '  constructor(value) { events.push(value); } /* constructor note */',
  '  static {',
  '    // static setup',
  '    this.ready = 1; // static assignment',
  '  } // static tail',
  '  static { /* empty static block */ }',
  '  // end class',
  '}',
  'if (Marker.ready !== 1) throw new Error("static initializer");',
  'const api = { /* first property */',
  '  value: { /* empty object */ }, // value docs',
  '  method() { /* object method body */ return 1; },',
  '  ...{ second: 2 } /* before the separator */,',
  '  // last property',
  '  get total() { return this.second + this.method(); } // getter tail',
  '};',
  'if (api.total !== 3) throw new Error("object properties");',
  'function collect(...values) { return values; }',
  'class Pair { constructor(...values) { this.values = values; } }',
  'const args = collect(/* first argument */',
  '  new Pair(1 /* constructor argument */, 2), // after constructor',
  '  ...collect(3, /* between arguments */ 4),',
  '  collect?.( /* empty optional call */ ).length,',
  '  new Pair( /* empty constructor */ ).values.length // last argument',
  ');',
  'if (String(args[0].values) !== "1,2" || String(args.slice(1)) !== "3,4,0,0") throw Error("arguments");',
  'const loaded = await import(/* webpackChunkName: "example" */ /* webpack note */ // @vite-ignore',
  '  "data:text/javascript,export default 5;",',
  '  /* import options */ {} /* turbopackOptional: true */);',
  'if (loaded.default !== 5) throw Error("dynamic import");',
  '// @preserve retain this line',
  'const first = /*#__PURE__*/ /*between the annotation and the call*/ make("first");',
  'const second = /*@__PURE__*/ new Marker("second");',
  'const grouped = /*#__PURE__*/ (make("grouped"));',
  'const combined = /*#__PURE__*/ "" + make("third");',
  '/*#__NO_SIDE_EFFECTS__*/ export function value() { return 42; }',
  'const fn = /*@__NO_SIDE_EFFECTS__*/ () => 1;',
  'if (events.join(",") !== "first,second,grouped,third") throw new Error("call order");',
  'if (fn() !== 1 || value() !== 42) throw new Error("function output");',
  '/* @license trailing notice */',
  '/* end of file */',
  '//# sourceMappingURL=old/@license.map',
].join('\n');

try {
  writeFileSync(input, source);
  for (const flags of [[], ['--minified']]) {
    const generated = execFileSync(binary, ['codegen', input, '--preserve-parens', ...flags], {
      encoding: 'utf8',
    });
    assert.ok(generated.startsWith('#!/usr/bin/env node\n/*! banner */'));
    assert.match(generated, /\/\/ @preserve retain this line\n/);
    assert.match(generated, /\/\* @license trailing notice \*\//);
    assert.doesNotMatch(generated, /sourceMappingURL/);
    assert.match(generated, /\/\*#__PURE__\*\/\s*make\("first"\)/);
    assert.match(generated, /\/\*#__PURE__\*\/\s*new Marker\("second"\)/);
    assert.match(generated, /\/\*#__PURE__\*\/\s*\(make\("grouped"\)\)/);
    assert.equal([...generated.matchAll(/\/\*#__PURE__\*\//g)].length, 3);
    assert.match(generated, /\/\*#__NO_SIDE_EFFECTS__\*\/\s*export function value/);
    assert.match(generated, /\/\*#__NO_SIDE_EFFECTS__\*\/\s*\(\)\s*=>/);
    if (flags.length === 0) {
      assert.match(generated, /\/\/ leading note\nconst events = \[\]; \/\/ trailing note\n/);
      assert.match(generated, /\/\*\* entry point \*\/\nfunction make/);
      assert.match(generated, /function make\(value\) \{\n  \/\/ function leading note\n/);
      assert.match(generated, /  \{\n    \/\* inside an empty block \*\/\n  \}/);
      assert.match(generated, /events\.push\(value\); \/\/ function trailing note\n  return value;/);
      assert.match(generated, /\/\* end of file \*\/\n$/);
    } else {
      assert.doesNotMatch(generated, /leading note|trailing note|inside an empty block|entry point|end of file/);
    }
    const ordinaryComments = [
      'member docs', 'empty class', 'field note', 'constructor note', 'static setup',
      'static assignment', 'static tail', 'empty static block', 'end class', 'first property',
      'empty object', 'value docs', 'object method body', 'before the separator', 'last property', 'getter tail',
      'first argument', 'constructor argument', 'after constructor', 'between arguments',
      'empty optional call', 'empty constructor', 'last argument',
      'import options', 'webpack note',
    ];
    for (const note of ordinaryComments) {
      assert.equal(generated.split(note).length - 1, flags.length ? 0 : 1, note);
    }
    for (const hint of ['webpackChunkName', '@vite-ignore', 'turbopackOptional']) {
      assert.equal(generated.split(hint).length - 1, 1, hint);
    }
    if (!flags.length) {
      assert.match(generated, /class Marker \{\n  \/\*\* member docs \*\/\n  field/);
      assert.match(generated, /\}; \/\/ field note\n  constructor/);
      assert.match(generated, /\} \/\* constructor note \*\/\n  static \{\n    \/\/ static setup/);
      assert.match(generated, /this\.ready = 1; \/\/ static assignment\n  \} \/\/ static tail/);
      assert.match(generated, /\/\/ end class\n\}/);
    }
    writeFileSync(output, generated);
    execFileSync(process.execPath, [output]);
    const printedAgain = execFileSync(binary, ['codegen', output, '--preserve-parens', ...flags], {
      encoding: 'utf8',
    });
    assert.equal(printedAgain, generated);
  }

  const ts = join(dir, 'input.ts');
  writeFileSync(ts, '/*! banner */\nconst result: string = /*#__PURE__*/ String(1);');
  const stripped = execFileSync(binary, ['strip-types', ts, '--minified'], { encoding: 'utf8' });
  assert.match(stripped, /^\/\*! banner \*\/const result=\/\*#__PURE__\*\/String\(1\);/);
  writeFileSync(ts, [
    'abstract class Counter {',
    '  // before signature',
    '  abstract next(): number; // after signature',
    '  value = 2 // after field',
    '}',
    'if (new Counter().value !== 2) throw new Error("class field");',
  ].join('\n'));
  const strippedClass = execFileSync(binary, ['strip-types', ts], { encoding: 'utf8' });
  assert.doesNotMatch(strippedClass, /next\(/);
  assert.match(strippedClass, /\/\/ before signature\n  \/\/ after signature\n  value = 2; \/\/ after field/);
  writeFileSync(output, strippedClass);
  execFileSync(process.execPath, [output]);
  writeFileSync(ts, 'const identity = <T>(x: T) => x;\nconst v = identity<number>(/* generic argument */ 42);');
  const typedCall = execFileSync(binary, ['strip-types', ts], { encoding: 'utf8' });
  assert.match(typedCall, /identity\(\n\s*\/\* generic argument \*\/\n\s*42/);
  writeFileSync(output, typedCall);
  execFileSync(process.execPath, [output]);
  writeFileSync(ts, 'import.source(/* webpackMode: "lazy" */ "module.wasm");\n' +
    'import.defer(/* @vite-ignore */ "feature.js");');
  for (const flags of [[], ['--minified']]) {
    const phases = execFileSync(binary, ['codegen', ts, ...flags], { encoding: 'utf8' });
    assert.match(phases, /import\.source\(\s*\/\* webpackMode: "lazy" \*\//);
    assert.match(phases, /import\.defer\(\s*\/\* @vite-ignore \*\//);
  }
  console.log('Comment checks passed for program, statement, class, object, call, constructor, and import boundaries');
} finally {
  rmSync(dir, { recursive: true, force: true });
}
