// JSX AST details checked against the pinned reference parsers.
//
// Goal: pin the consumer-visible JSX contract to references instead of to
// hand-written expectations.
//
//   * A mismatched closing tag is an error on oxc-parser's span.
//   * `{...xs}` children are JSXSpreadChild nodes with oxc-parser's spans.
//   * `{...}` without an operand is an error on oxc-parser's span.
//   * `raw` of JSXText and of string attributes equals oxc-parser's `raw`.
//   * `value` is entity-decoded and equals @babel/parser's `value`. The pinned
//     oxc-parser does NOT decode (its `value` equals `raw`); that is asserted
//     too, so a change in the pin shows up here instead of going unnoticed.
//   * Where Kessel deliberately differs from Babel the expected value is
//     spelled out per case (`kessel`), with the reason.
//
// Method: each case is one JSX source. It is parsed by `kessel parse --json`
// and by the reference parsers, and the same projection of each result is
// compared. Run with NODE_PATH=bench/node_modules.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { parseSync } = require('oxc-parser');
const babel = require('@babel/parser');

const BIN = process.env.KESSEL_BIN || path.join(__dirname, '..', '..', 'bin', 'kessel');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-jsx-ast-'));
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));

function kesselParse(source) {
  const file = path.join(scratch, 'case.jsx');
  fs.writeFileSync(file, source);
  const stdio = ['ignore', 'pipe', 'ignore'];
  return JSON.parse(execFileSync(BIN, ['parse', file, '--json'], { stdio }));
}

let failed = 0;
let total = 0;
function check(name, run) {
  total++;
  try { run(); } catch (error) { failed++; console.error(`FAIL: ${name}: ${error.message}`); }
}

const ERROR_CASES = [
  '<p></div>;',
  '<a.b></a.c>;',
  '<a:b></a:c>;',
  '<a></b.c>;',
  '<a>\n  <b></c>\n</a>;',
  '<a {...}/>;',
  '<a>{...}</a>;',
  '<a>{... }</a>;',
];
for (const source of ERROR_CASES) {
  check(`error span ${JSON.stringify(source)}`, () => {
    const kessel = kesselParse(source);
    const oxc = parseSync('case.jsx', source);
    assert.ok(oxc.errors.length >= 1, 'reference must reject the source');
    assert.ok((kessel.errors ?? []).length >= 1, 'must be rejected');
    // Kessel's JSON carries the start offset; the end is asserted on the
    // typed AST in tests/coverage/src/jsx_ast_test.odin.
    const label = oxc.errors[0].labels[0];
    assert.equal(kessel.errors[0].offset, label.start, 'error offset vs oxc-parser');
  });
}

// Collect [type, start, end, expression type] for every JSX child container.
function containers(node, out = []) {
  if (node === null || typeof node !== 'object') return out;
  if (Array.isArray(node)) { for (const item of node) containers(item, out); return out; }
  if (node.type === 'JSXSpreadChild' || node.type === 'JSXExpressionContainer') {
    out.push([node.type, node.start, node.end, node.expression.type]);
  }
  for (const key of Object.keys(node)) if (key !== 'loc') containers(node[key], out);
  return out;
}

const SPREAD_CASES = [
  '<a>{...xs}</a>;',
  '<a>text{...xs}{y}{}{...c ? l : r}</a>;',
  '<>{...xs}{...[1, 2]}</>;',
  '<a><b>{ ...xs }</b></a>;',
];
for (const source of SPREAD_CASES) {
  check(`spread child ${JSON.stringify(source)}`, () => {
    const kessel = kesselParse(source);
    assert.deepEqual(kessel.errors ?? [], []);
    const oxc = parseSync('case.jsx', source);
    assert.deepEqual(oxc.errors, []);
    assert.deepEqual(containers(kessel), containers(oxc.program));
    assert.ok(containers(kessel).some(item => item[0] === 'JSXSpreadChild'));
  });
}

// Collect [kind, value, raw] for every JSXText and string attribute value.
function strings(node, out = []) {
  if (node === null || typeof node !== 'object') return out;
  if (Array.isArray(node)) { for (const item of node) strings(item, out); return out; }
  if (node.type === 'JSXText') out.push(['text', node.value, node.raw ?? node.extra?.raw]);
  if (node.type === 'JSXAttribute' && node.value) {
    const value = node.value;
    if (value.type === 'Literal' || value.type === 'StringLiteral') {
      out.push(['attribute', value.value, value.raw ?? value.extra?.raw]);
    }
  }
  for (const key of Object.keys(node)) if (key !== 'loc') strings(node[key], out);
  return out;
}

// `body` is used both as an attribute value and as child text.
// `kessel`: expected value where Kessel differs from Babel on purpose.
const ENTITY_CASES = [
  { body: 'plain' },
  { body: '&amp;' },
  { body: '&lt;&gt;&quot;&apos;' },
  { body: '&nbsp;&copy;&hellip;&Aacute;&euro;' },
  { body: '&#65;&#8364;' },
  { body: '&#x41;&#x1F600;' },
  { body: '&amp;lt;' },
  { body: '&foo;' },
  { body: '&AMP;&Amp;' },
  { body: '&amp x &lt' },
  { body: '&#X41;' },
  { body: '&#;&#x;&;' },
  { body: '&&amp;;&amp&amp;' },
  { body: '&#0;' },
  // Babel raises "Invalid code point"; oxc-parser accepts the source, so it
  // must parse, and the reference stays literal as in oxc-transform.
  { body: '&#1114112;', kessel: '&#1114112;' },
  { body: '&#x110000;', kessel: '&#x110000;' },
  { body: '&#12345678901234567890;', kessel: '&#12345678901234567890;' },
  // Babel yields a lone surrogate. Kessel strings are UTF-8, which cannot
  // carry one, so the reference stays literal as in oxc-transform.
  { body: '&#xD800;', kessel: '&#xD800;' },
  // The decoder is shared with the JSX transform, which follows
  // oxc-transform in accepting a sign. Babel leaves these literal.
  { body: '&#+65;', kessel: 'A' },
];
for (const entity of ENTITY_CASES) {
  const source = `<a b="${entity.body}">${entity.body}</a>;`;
  check(`entities ${JSON.stringify(entity.body)}`, () => {
    const kessel = kesselParse(source);
    assert.deepEqual(kessel.errors ?? [], [], 'must parse without errors');
    const oxc = parseSync('case.jsx', source);
    assert.deepEqual(oxc.errors, [], 'reference must accept the source');
    const got = strings(kessel);
    const reference = strings(oxc.program);
    assert.equal(got.length, 2);
    assert.deepEqual(got.map(item => item[2]), reference.map(item => item[2]), 'raw');
    for (const item of reference) assert.equal(item[1], entity.body, 'oxc-parser is undecoded');
    let expected = entity.kessel;
    if (expected === undefined) {
      const decoded = strings(babel.parse(source, { plugins: ['jsx'] }).program);
      assert.equal(decoded[0][1], decoded[1][1]);
      expected = decoded[0][1];
    }
    for (const item of got) assert.equal(item[1], expected, `${item[0]} value`);
  });
}

if (failed > 0) {
  console.error(`verify_jsx_ast: ${failed} of ${total} cases failed`);
  process.exit(1);
}
console.log(`verify_jsx_ast: ${total} cases match the references`);
