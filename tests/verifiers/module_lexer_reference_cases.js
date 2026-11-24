'use strict';

// Inline sources for verify_module_lexer_reference.js.
//
// The `readme-*` cases are the examples printed in es-module-lexer's README
// and type documentation (bench/node_modules/es-module-lexer). Its unit
// suite is not shipped in the npm package, so the `suite-*` cases restate
// the scenarios that suite is known to cover (regex versus division,
// comments, templates, `import` used as a member or method name, dynamic
// import shapes, import.meta, export forms, string names, escapes). They are
// reconstructions, not verbatim copies; every one is checked live against
// the installed es-module-lexer, so a wrong reconstruction can only lose
// coverage, never hide a mismatch.

const raw = String.raw;

const readme = [
  ['readme-usage', 'export var p = 5'],
  ['readme-tour', raw`
    import { name } from 'modထ';
    import json from './json.json' assert { type: 'json' }
    export var p = 5;
    export function q () {

    };
    export { x as 'external name' } from 'external';

    // Comments provided to demonstrate edge cases
    import /*comment!*/ (  'asdf', { assert: { type: 'json' }});
    import /*comment!*/.meta.asdf;

    // Source phase imports:
    import source mod from './mod.wasm';
    import.source('./mod.wasm');
  `],
  ['readme-facade', `
  export * from 'external';
  import * as ns from 'external2';
  export { a as b } from 'external3';
  export { ns };
`],
  ['readme-esm-detection', '\n  export {}\n'],
  ['readme-esm-detection-dynamic', "\n  import('./foo.js')\n"],
  ['readme-limitation-declarators', "export var a = 'asdf', q = z;"],
  ['readme-limitation-destructuring', 'export var { a: b } = asdf;'],
  ['types-escape-static', raw`import './ab.js'`],
  ['types-dynamic-literal', 'import("./ab.js")'],
  ['types-dynamic-computed', 'import("./" + "ab.js")'],
  ['types-static', "import { a } from 'asdf'"],
  ['types-export-default', 'export default []'],
  ['types-export-const', 'export const asdf = 42'],
  ['types-export-rename', 'const asdf = 42;\nexport { asdf as a }'],
  ['types-export-number-name', "export { 42 as asdf } from 'x'"],
];

const suite = [
  ['suite-empty', ''],
  ['suite-whitespace-and-comments', '  \n// only a comment\n/* block */\n'],
  ['suite-hashbang', "#!/usr/bin/env node\nimport 'a';\n"],
  ['suite-import-forms', `
import a from 'a';
import * as b from "b";
import { c } from 'c';
import d, { e as f } from 'd';
import g, * as h from 'g';
import {} from 'i';
import 'j';
import{k}from'k';
import l,{m}from"l";
`],
  ['suite-export-forms', `
export function a () {}
export function* b () {}
export async function c () {}
export async function* d () {}
export class E {}
export var f = 1;
export let g = 2;
export const h = 3;
export { i };
export { j as k, l as default };
export * from 'm';
export * as n from 'n';
export { o } from 'o';
export { default } from 'p';
export { default as q } from 'q';
var i, j, l;
`],
  ['suite-string-names', `
const x = 1;
export { x as "external name", x as 'single', x as "\\u{1F310}" };
export { "a b" as c, 'd' as "e f" } from 'm';
export * as "all of it" from 'n';
import { "a b" as local } from 'm';
`],
  ['suite-escaped-specifiers', raw`
import 'a\x62\0';
import "tab\there";
import 'line\
continued';
import("\u{1F600}");
import('quote\'s');
`],
  ['suite-dynamic-shapes', `
import('a');
import ( 'b' );
import(\n  'c'\n);
import(/* c */ 'd' /* d */);
import('e', { with: { type: 'json' } });
import('f', options);
import(g);
import(h + i);
import(\`template\`);
import(\`template-\${j}\`);
import('k').then(m => m.default);
await import('l');
const m = () => import('m');
import(import('n'));
import(o, p);
`],
  ['suite-dynamic-in-expressions', `
const a = { b: import('b'), c: [import('c')] };
if (import('d')) import('e'); else import('f');
x ? import('g') : import('h');
f(import('i'), import('j'));
`],
  ['suite-import-meta', `
import.meta;
import.meta.url;
console.log(import.meta.url, import . meta, import\n.\nmeta);
const { url } = import.meta;
new URL('.', import.meta.url);
`],
  ['suite-phases', `
import source a from 'a';
import defer * as b from 'b';
import source from 'c';
import defer from 'd';
import source, { e } from 'e';
import.source('f');
import.defer('g');
import . source ( 'h' );
`],
  ['suite-attributes', `
import a from 'a' with { type: 'json' };
import b from 'b' assert { type: 'json' };
import c from 'c' with { type: 'css', "quoted": 'v' };
export { d } from 'd' with { type: 'json' };
export * from 'e' with { type: 'json' };
import 'f' with { type: 'css' };
import('g', { with: { type: 'json' } });
`],
  ['suite-import-as-member-and-method', `
a.import('x');
a?.import('y');
a.import.meta;
class C { import () {} static import () {} async import () {} *import () {} }
const o = { import () {}, import: 1, export: 2 };
o.export;
x.export.y;
function f () { return this.import('z'); }
`],
  ['suite-export-as-member', 'a.export = 1;\nb.export.c();\nconst d = { export: 1 };\n'],
  ['suite-keywords-in-strings-and-comments', `
const a = "import 'a'";
const b = 'export default 1';
const c = \`import('c') \${"export { d }"} import.meta\`;
// import 'e'
/* export { f } */
`],
  ['suite-regex-versus-division', `
a = b / c / d;
e = (f) / g / h;
i = [j] / k / l;
m = n++ / o / p;
q = /import('regex')/.test(r);
s = t ? /import('t')/ : /export { u }/;
v = { w: /import('w')/ };
x = [/import('x')/, /['"]/];
if (y) /import('y')/.exec(z);
while (aa) /bb/.test(cc);
for (;;) /import('dd')/.test(ee);
function ff () { return /import('ff')/; }
gg = () => /import('gg')/;
hh = 1 / 2 / import('real');
ii = typeof /import('ii')/;
jj = jj.kk / ll / mm;
nn = /[/]import('nn')/;
oo = /\\/import('oo')/;
`],
  ['suite-regex-after-brace-and-paren', `
function a () {} /import('a')/.test(b);
if (c) {} /import('c')/.test(d);
e = {} / f / g;
h = (i) / j / import('real');
`],
  ['suite-templates', `
const a = \`\${import('a')}\`;
const b = \`a \${ \`b \${import('b')} c\` } d\`;
const c = \`}\${'{'}\`;
const d = tag\`import('d')\`;
const e = \`\\\`import('e')\\\`\`;
`],
  ['suite-comments-everywhere', `
import /* a */ b /* c */ from /* d */ 'e' /* f */;
import /* g */ ( /* h */ 'i' /* j */ );
export /* k */ { /* l */ m /* n */ as /* o */ p /* q */ };
export /* r */ default /* s */ 1;
export /* t */ * /* u */ from /* v */ 'w';
var m;
`],
  ['suite-asi', "import a from 'a'\nimport b from 'b'\nexport { a }\nexport default b\n"],
  ['suite-nested-blocks', `
{ { import('a'); } }
function f () { if (x) { for (;;) { import('b'); } } }
label: { import('c'); }
`],
  ['suite-class-bodies', `
export class A { static x = import('a'); #p = 1; m () { return import('b'); } }
export class B extends (import('c'), Object) {}
`],
  ['suite-object-shorthand', "const o = { a, b () {}, get c () { return 1; }, [import('d')]: 1 };"],
  ['suite-arrow-bodies',
    "const a = () => import('a');\nconst b = async () => { await import('b'); };"],
  ['suite-label-like', 'a: for (;;) break a;\nexport { a };\nvar a;'],
  ['suite-unicode-source',
    "/* π */ import 'π';\nexport const λ = '😀';\nimport('é');\nexport { λ as μ };"],
  ['suite-facade-true', "import 'a';\nimport b from 'b';\nexport * from 'c';\nexport { b };\n;"],
  ['suite-facade-false-statement', "import 'a';\nconsole.log(1);"],
  ['suite-facade-false-declaration', "import 'a';\nexport const b = 1;"],
  ['suite-module-syntax-import-meta', 'import.meta.url;'],
  ['suite-module-syntax-none', "require('a'); module.exports = 1;"],
  ['suite-invalid-unterminated-string', "import 'a"],
  ['suite-invalid-unterminated-template', 'const a = `abc'],
  ['suite-invalid-unbalanced-brace', "function f () { import('a');"],
  ['suite-invalid-unbalanced-paren', "f(import('a');"],
  ['suite-invalid-import-no-specifier', 'import a from;'],
  ['suite-invalid-extra-close', "import('a'));"],
];

// A module has one default export, so each form is its own case.
const defaults = [
  'export default function () {}', 'export default function name () {}',
  'export default async function () {}', 'export default async function named () {}',
  'export default function* gen () {}', 'export default class {}',
  'export default class Named {}', 'export default class extends Base {}',
  'export default 5', 'export default (a, b) => a + b', 'export default { a: 1 }',
  'export default [1, 2]', 'export default async () => {}', 'export default a',
].map((source, index) => [`suite-export-default-${index}`, source]);

// One construct per case, so a mismatch names its cause.
const edges = [
  "var a, c, d;\nexport { a as b, c as default, d as 'e' };",
  "import * as ns from 'x';\nexport { ns as default };",
  "export * as default from 'x';",
  "export { default as default } from 'x';",
  "export { default } from 'x';\nexport { a as 'b', } from 'y';",
  "import 'a\\\"b';\nimport \"c\\'d\";\nimport 'e\\\\';",
  "import x from 'y'// trailing comment\nexport { x }",
  "export var a\n, b;",
  "export let\nx = 1;",
  "export const a = 1, b = function () { return { c: 1 }; }, d = 2;",
  "export const a = [1, 2], b = { c: [3] }, d = (4, 5), e = `${6}`;",
  "export const a = b ? c : d, e = f;",
  "export const a = (b, c) => b, d = async e => e;",
  "export function /* c */ f /* d */ () {}",
  "export class A{}export class B{}export function c(){}export var d",
  "import{a}from'a';import*as b from'b';export{a,b}",
  "export default(function () {})",
  "export default{ a: 1 }",
  "export default[1]",
  "export default'str'",
  "export default class{}",
  "export default function*(){}",
  "export default async function f () {}\nawait f();",
  "import.meta // comment",
  "import.meta?.url;\nimport.meta\n.url;\nimport.meta[key];",
  "import(`a)${b}`);\nimport('c' /* ) */);\nimport(`${import('d')}`);",
  "import('a').then(() => import('b'));",
  "class A { import = 1; static import () {} get import () { return 1; } set import (v) {} }",
  "const o = { import: import('a'), export: 1, get import () { return 1; } };",
  "label: import('x');",
  "import a, * as b from 'c';\nimport { default as d, e as f, } from 'g';",
  "a = b\n/c/g.test(d);\nimport('real');",
  "x = y / /re'/.source.length;\nimport('real');",
  "a++ / 2 / import('real');",
  "({}) / 2 / import('real');",
  "function* g () { yield /import('g')/; }",
  "x = typeof /import('a')/, void /import('b')/;",
  "await /import('a')/.test(b);\nimport('real');",
  "async function f () { return await /import('a')/.test(b); }",
  "x = a.yield / b / import('real');",
  "x = /[/'\"]/;\ny = /\\//;\nimport('real');",
  "x = a /* c */ / b / import('real');",
  "x = a // c\n/ b / import('real');",
  "switch (a) { case /import('x')/.test(b): break; default: import('real'); }",
  "do /import('x')/.test(a); while (b) /import('y')/.test(c);",
  "if (a) /import('x')/.test(b); else /import('y')/.test(c);",
  "x = () => {}\nimport('real');",
  "try {} catch {} finally {} /import('x')/.test(a);",
  "x = { a: {} } / 2 / import('real');",
  "`${a}` / 2 / import('real');",
  "x = a ? b : c / d / import('real');",
  "export {};\nexport {} from 'a';\nimport {} from 'b';",
  "'use strict';\nimport 'a';",
  "import 'a' with { 'type': 'json', b: \"c\" };",
  "import a from 'a' /* c */ with /* d */ { type: 'json' } /* e */;",
  "export { a } from 'a' with { type: 'json' }\nexport { b } from 'b'",
  "import('a', { with: { type: 'json' }, });\nimport('b', { 'with': { type: 'css' } });",
  "import.source('a', b);\nimport.defer(c);",
  "const source = 1, defer = 2;\nimport source from 'a';",
  "import defer, { a } from 'b';\nimport source, * as c from 'd';",
  "import type from 'a';\nimport { type } from 'b';",
  "async function f () { await import('a'); for await (const x of import('b')) {} }",
  "new (import('a').constructor)();\nnew import.meta.constructor();",
  "export const { a = import('b'), [import('c')]: d } = e;",
  "import\n'a';\nexport\n*\nfrom\n'b';\nexport\n{\nc\n}\n;var c;",
].map((source, index) => [`edge-${index}`, source]);

module.exports = [...readme, ...suite, ...defaults, ...edges]
  .map(([name, source]) => ({ name, source }));
