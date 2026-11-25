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
  assert.match(typedCall, /identity\(\s*\/\* generic argument \*\/\s*42/);
  writeFileSync(output, typedCall);
  execFileSync(process.execPath, [output]);
  writeFileSync(ts, 'import.source(/* webpackMode: "lazy" */ "module.wasm");\n' +
    'import.defer(/* @vite-ignore */ "feature.js");');
  for (const flags of [[], ['--minified']]) {
    const phases = execFileSync(binary, ['codegen', ts, ...flags], { encoding: 'utf8' });
    assert.match(phases, /import\.source\(\s*\/\* webpackMode: "lazy" \*\//);
    assert.match(phases, /import\.defer\(\s*\/\* @vite-ignore \*\//);
  }
  checkExpressionAndTypeComments();
  checkRequiredGrouping();
  console.log('Comment checks passed for program, statement, class, object, call, constructor, and import boundaries');
  console.log('Comment checks passed for expression, pattern, type, member, switch and JSX positions');
} finally {
  rmSync(dir, { recursive: true, force: true });
}

// Positions inside expressions, patterns and types. For each case the pretty
// print must (a) keep every comment exactly once, (b) keep each comment in
// front of or behind the same node, as the `placed` patterns state, (c)
// reparse to the AST of the source with and without --preserve-parens, and
// (d) print to the same text when printed again. Minified output drops them.
function checkExpressionAndTypeComments() {
  const cases = [
    {
      name: 'array elements', ext: 'js',
      source: 'const list = [\n  // first\n  1, // one\n  /* two */ 2,\n  3 // last\n];\n' +
        'const inline = [1, /* b */ 2 /* c */];',
      placed: [/\[\n  \/\/ first\n  1, \/\/ one\n  \/\* two \*\/ 2,\n  3 \/\/ last\n\]/, /\[1, \/\* b \*\/ 2 \/\* c \*\/\]/],
    },
    {
      name: 'parameters', ext: 'ts',
      source: 'function f(/* first */ a: string, b /* after b */, // line\n  c = 1 /* last */) {}\n' +
        'const g = (/** @type {number} */ x, y /* tail */) => x;\n' +
        'class P { constructor(/* prop */ private readonly id: number) {} }',
      placed: [/\(\/\* first \*\/ a: string, b, \/\* after b \*\/ \/\/ line\n/, /c = 1 \/\* last \*\/\)/,
        /\(\/\*\* @type \{number\} \*\/ x, y \/\* tail \*\/\) =>/, /\(\/\* prop \*\/ private readonly id/],
    },
    {
      name: 'binary operands', ext: 'js',
      source: 'const total = first + // why first\n  second /* second */ * third;\n' +
        'const ok = a && /* both */ b || // either\n  c;',
      placed: [/first \+ \/\/ why first\n\s+second \* \/\* second \*\/ third/, /a && \/\* both \*\/ b \|\| \/\/ either\n\s+c;/],
    },
    {
      name: 'member chains', ext: 'js',
      source: 'promise\n  // first step\n  .then(a)\n  /* second step */\n  .catch(b);\nconst v = obj /* why */ .key[/* index */ 0 /* end */];',
      placed: [/promise \/\/ first step\n\s+\.then\(a\) \/\* second step \*\/ \.catch\(b\)/, /obj \/\* why \*\/ \.key\[\/\* index \*\/ 0 \/\* end \*\/\]/],
    },
    {
      name: 'conditional branches', ext: 'js',
      source: 'const pick = test // the test\n  ? yes /* chosen */\n  : /* fallback */ no;',
      placed: [/test \? \/\/ the test\n\s+yes : \/\* chosen \*\/ \/\* fallback \*\/ no;/],
    },
    {
      name: 'arrow bodies and returns', ext: 'js',
      source: 'const f = () => /* body */ 1;\nconst g = (a /* arg */) => (\n  // grouped body\n  a + 1\n);\n' +
        'function h() {\n  return ( // why\n    a && b\n  );\n}\nfunction* k() { yield ( // next\n  1); throw ( /* boom */ err); }',
      placed: [/=> \/\* body \*\/ 1/, /\(a \/\* arg \*\/\) => \/\/ grouped body\n\s+a \+ 1/,
        /\/\/ why\n  return a && b;/, /\/\/ next\n\s+yield 1;/, /throw \/\* boom \*\/ err;/],
    },
    {
      name: 'JSX', ext: 'jsx',
      source: 'const el = <div /* on tag */ id="a" // after attribute\n>\n  {/* child comment */}\n  text /* not a comment */\n' +
        '  {value /* in container */}\n</div /* closing */>;',
      placed: [/<div \/\* on tag \*\/ id="a" \/\/ after attribute\n\s*>/, /\{\/\* child comment \*\/\}/,
        /text \/\* not a comment \*\/\n/, /\{value \/\* in container \*\/\}/, /<\/div \/\* closing \*\/>/],
      count: { 'not a comment': 1 },
    },
    {
      name: 'type annotations', ext: 'ts',
      source: 'let a: /* annotated */ string = "";\ntype U = /* first */ | A // about A\n  | /* second */ B;\n' +
        'function f<T /* param */, /* next */ V>(x: Map</* key */ string, T /* value */>): /* result */ void {}\n' +
        'const tuple: [/* x */ number, string /* y */] = [1, ""];\nconst cast = value as /* cast */ unknown;',
      placed: [/let a: \/\* annotated \*\/ string/, /\/\* first \*\/ A \| \/\/ about A\n\s+\/\* second \*\/ B;/,
        /<T, \/\* param \*\/ \/\* next \*\/ V>/, /Map<\/\* key \*\/ string, T \/\* value \*\/>\): \/\* result \*\/ void/,
        /\[\/\* x \*\/ number, string \/\* y \*\/\]/, /as \/\* cast \*\/ unknown/],
    },
    {
      name: 'interface and type members', ext: 'ts',
      source: 'interface Shape {\n  /** The name. */\n  name: string; // trailing name\n  // leading area\n  area(): number;\n' +
        '  /* before last */ readonly id: number\n  // end of interface\n}\n' +
        'type Point = {\n  /** Horizontal. */\n  x: number;\n  y: number; /* vertical */\n};\ninterface Empty { /* nothing yet */ }',
      placed: [/\{\n  \/\*\* The name\. \*\/\n  name: string; \/\/ trailing name\n  \/\/ leading area\n  area\(\): number;\n/,
        /  \/\* before last \*\/ readonly id: number;\n  \/\/ end of interface\n\}/,
        /\{\n  \/\*\* Horizontal\. \*\/\n  x: number;\n  y: number; \/\* vertical \*\/\n\}/, /interface Empty \{\n  \/\* nothing yet \*\/\n\}/],
    },
    {
      name: 'enum members', ext: 'ts',
      source: 'enum Color {\n  /** Warm. */\n  Red = 1, // first\n  // cold\n  Blue,\n  /* last */ Green\n  // end\n}',
      placed: [/\{\n  \/\*\* Warm\. \*\/\n  Red = 1, \/\/ first\n  \/\/ cold\n  Blue,\n  \/\* last \*\/ Green,\n  \/\/ end\n\}/],
    },
    {
      name: 'switch cases', ext: 'js',
      source: 'switch (kind) {\n  // about one\n  case 1: // on one\n    run(); // ran\n    // falls through\n  // about two\n' +
        '  case /* inline */ 2:\n  default:\n    // nothing\n}',
      placed: [/\{\n  \/\/ about one\n  case 1: \/\/ on one\n    run\(\); \/\/ ran\n    \/\/ falls through\n  \/\/ about two\n  case \/\* inline \*\/ 2:\n  default:\n    \/\/ nothing\n\}/],
    },
    {
      name: 'import and export specifiers', ext: 'js',
      source: 'import { a, /* why b */ b, // after b\n  c /* last */ } from "m";\nexport { a /* exported */ };',
      placed: [/\{ a, \/\* why b \*\/ b, \/\/ after b\n\s+c \/\* last \*\/ \} from "m"/, /export \{ a \/\* exported \*\/ \};/],
    },
    {
      name: 'class members and properties', ext: 'js',
      source: 'class C {\n  @dec // after decorator\n  static /* modifier */ async run() {}\n  get /* getter */ size() { return 1; }\n' +
        '  [/* computed */ key /* end key */]() /* before body */ {}\n}\n' +
        'const o = { /* lead */ async /* named */ m() {}, [k /* in key */]: 1 /* value */ };',
      placed: [/@dec\n  \/\/ after decorator\n  static async \/\* modifier \*\/ run\(\)/, /get \/\* getter \*\/ size\(\)/,
        /\[\/\* computed \*\/ key \/\* end key \*\/\]\(\) \/\* before body \*\/ \{\}/,
        /\{ \/\* lead \*\/ async \/\* named \*\/ m\(\) \{\}, \[k \/\* in key \*\/\]: 1 \/\* value \*\/ \}/],
    },
    {
      name: 'statement heads and templates', ext: 'js',
      source: 'if (a && // first\n  b // second\n) { run(); } else /* otherwise */ { stop(); }\n' +
        'for (let i = 0 /* init */; i < n /* test */; i++ /* update */) {}\nwhile (more /* keep going */) step();\n' +
        'const text = `a ${/* inside */ value /* after */} b`;\nconst { x /* picked */, y: [/* first */ z] } = source;',
      placed: [/if \(a && \/\/ first\n\s+b \/\/ second\n\) \{/, /\} else \/\* otherwise \*\/ \{/,
        /i < n; \/\* test \*\/ i\+\+ \/\* update \*\/\)/, /while \(more \/\* keep going \*\/\)/,
        /\$\{\/\* inside \*\/ value \/\* after \*\/\}/, /\{ x, \/\* picked \*\/ y: \[\/\* first \*\/ z\] \}/],
    },
  ];
  const structure = (file, parens) => {
    const flags = ['parse', file, '--json', '--compact'].concat(parens ? ['--preserve-parens'] : []);
    const program = JSON.parse(execFileSync(binary, flags, { encoding: 'utf8', maxBuffer: 1 << 28 }));
    assert.deepEqual(program.errors ?? [], [], file);
    const dropped = new Set(['start', 'end', 'range', 'loc', 'raw', 'comments']);
    return { text: JSON.stringify(program, (key, value) => (dropped.has(key) ? undefined : value)), comments: program.comments ?? [] };
  };
  for (const { name, ext, source, placed, count = {} } of cases) {
    const original = join(dir, 'case.' + ext);
    const printed = join(dir, 'printed.' + ext);
    writeFileSync(original, source);
    for (const parens of [false, true]) {
      const flags = parens ? ['--preserve-parens'] : [];
      const output = execFileSync(binary, ['codegen', original, ...flags], { encoding: 'utf8' });
      const label = `${name}${parens ? ' (preserved parentheses)' : ''}:\n${output}`;
      writeFileSync(printed, output);
      const before = structure(original, parens), after = structure(printed, parens);
      assert.equal(after.text, before.text, 'AST changed for ' + label);
      assert.deepEqual(after.comments.map(c => c.value).sort(), before.comments.map(c => c.value).sort(),
        'comments changed for ' + label);
      for (const [text, times] of Object.entries(count)) assert.equal(output.split(text).length - 1, times, label);
      if (!parens) for (const pattern of placed) assert.match(output, pattern, label);
      assert.equal(execFileSync(binary, ['codegen', printed, ...flags], { encoding: 'utf8' }), output,
        'second print differs for ' + label);
    }
    const compact = execFileSync(binary, ['codegen', original, '--minified'], { encoding: 'utf8' });
    writeFileSync(printed, compact);
    assert.equal(structure(printed, false).text, structure(original, false).text, 'minified AST changed for ' + name);
    assert.deepEqual(structure(printed, false).comments, [], 'minified output keeps no ordinary comment: ' + name);
  }
}

// Without --preserve-parens the AST has no grouping nodes, so the printer has
// to restore the parentheses that carry meaning. Each line must print back
// unchanged and reparse to the same AST.
function checkRequiredGrouping() {
  const lines = [
    'new (a().b)();', 'new (a?.b)();', 'new (a()`x`)();', 'new (a.b().c.d)(1);', 'new (import("m"))();',
    '(a?.b).c;', '(a?.b)();', '(a?.b)`x`;', '(a?.())();', '("use strict");', 'x = (a ** b) ** c;',
  ];
  const source = join(dir, 'grouping.js');
  const printed = join(dir, 'grouping.out.js');
  writeFileSync(source, lines.join('\n') + '\n');
  const output = execFileSync(binary, ['codegen', source], { encoding: 'utf8' });
  assert.equal(output, lines.join('\n') + '\n');
  writeFileSync(printed, execFileSync(binary, ['codegen', source, '--minified'], { encoding: 'utf8' }));
  const tree = file => JSON.stringify(
    JSON.parse(execFileSync(binary, ['parse', file, '--json', '--compact'], { encoding: 'utf8' })),
    (key, value) => (['start', 'end', 'raw'].includes(key) ? undefined : value));
  assert.equal(tree(printed), tree(source), 'minified output changed the grouping');
  const typed = join(dir, 'grouping.ts');
  // Also spellings that must come back as written: a generic function type
  // as a type argument (`<<` would lex as a shift) and template type escapes.
  const typedLines = [
    'new (a()!)();', 'let x = true ? (async (a): b => a) : null;', 'type A = X< <T>() => T>;',
    'const c = f< <T>() => T>(1);', 'type T1 = `a\\tb\\r\\n${string}\\u0041`;',
    // `as` and `satisfies` are relational: grouping stays where it changes the tree.
    'const r = (a as T) < b;', 'const s = (a satisfies T) | b;', 'const t = a + (b as T);',
    'const u = a + b as T;', 'const v = -(a as T);', 'const w = a as any < b;', 'const y = a < b as T;',
  ];
  writeFileSync(typed, typedLines.join('\n') + '\n');
  assert.equal(execFileSync(binary, ['codegen', typed], { encoding: 'utf8' }), typedLines.join('\n') + '\n');
}
