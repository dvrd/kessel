// JSX AST details checked against the pinned reference parsers.
//
// Goal: pin the consumer-visible JSX contract to references instead of to
// hand-written expectations.
//
//   * A mismatched closing tag is an error on oxc-parser's span.
//   * `{...xs}` children are JSXSpreadChild nodes with oxc-parser's spans.
//   * `{...}` without an operand is an error on oxc-parser's span.
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

if (failed > 0) {
  console.error(`verify_jsx_ast: ${failed} of ${total} cases failed`);
  process.exit(1);
}
console.log(`verify_jsx_ast: ${total} cases match the references`);
