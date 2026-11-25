// Validate the sourcemap kessel emits by decoding it with the standard
// `source-map-js` consumer and checking that (gen_line, gen_col) queries
// map back to a source slice whose first non-whitespace prefix matches
// the corresponding generated line.
//
// Use exact positions to check Unicode line breaks, UTF-16 columns, and
// dense source buffers in both output modes.
const { SourceMapConsumer } = require('source-map-js');
const { execFileSync } = require('child_process');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const BIN = path.join(__dirname, '..', '..', 'bin', 'kessel');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-sourcemap-'));
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));

function codegenWithMap(srcPath, source, options = []) {
  fs.writeFileSync(srcPath, source);
  const output = execFileSync(BIN, ['codegen', srcPath, '--sourcemap', ...options], { encoding: 'utf8' });
  const mapStart = output.lastIndexOf('//# sourceMappingURL=');
  assert.ok(mapStart >= 0, 'expected an inline source map');
  const encoded = output.slice(mapStart).split('base64,', 2)[1];
  const consumer = new SourceMapConsumer(JSON.parse(Buffer.from(encoded, 'base64').toString('utf8')));
  return { code: output.slice(0, mapStart), consumer };
}


const CASES = [
  {
    name: 'single-line multi-statement',
    src: 'const x = 1; function foo() { return x; }\n',
    minPass: 3,
  },
  {
    name: 'multi-line',
    src:
      'const a = 1;\n' +
      'function bar(y) {\n' +
      '  return y + a;\n' +
      '}\n' +
      'class C {\n' +
      '  m() { return 42; }\n' +
      '}\n',
    minPass: 4,
  },
];

let totalPass = 0;
let totalFail = 0;

for (const tc of CASES) {
  const srcPath = path.join(scratch, tc.name.replace(/\W+/g, '_') + '.js');
  const { code, consumer } = codegenWithMap(srcPath, tc.src);
  const src = tc.src.split('\n');
  const gen = code.split('\n');

  console.log(`\n=== ${tc.name} ===`);
  let pass = 0, fail = 0;
  for (let l = 0; l < gen.length; l++) {
    const line = gen[l];
    if (!line.trim()) continue;
    const col = line.search(/\S/);
    const pos = consumer.originalPositionFor({ line: l + 1, column: col });
    if (pos.line == null) {
      console.log(`  gen L${l+1}C${col}  ->  (unmapped)        gen=${JSON.stringify(line.slice(0,40))}`);
      continue;
    }
    const srcLine = src[pos.line - 1];
    // Compare the source slice starting at the mapped column, not the
    // whole source line — multi-statement source lines (common in
    // minified or hand-packed input) would otherwise look like
    // mismatches even when the mapping is correct.
    const srcSlice = srcLine != null ? srcLine.slice(pos.column).trim() : '';
    const genPrefix = line.trim().slice(0, 6);
    const ok = srcSlice.startsWith(genPrefix);
    console.log(
      `  gen L${l+1}C${col}  ->  src L${pos.line}C${pos.column}  ` +
      `[${ok ? 'OK' : '??'}]  gen=${JSON.stringify(line.slice(0,40))}  src=${JSON.stringify(srcLine ? srcLine.slice(0,40) : null)}`,
    );
    if (ok) pass++; else fail++;
  }
  console.log(`  case result: ${pass} pass, ${fail} fail (min required ${tc.minPass})`);
  if (pass < tc.minPass) {
    console.error(`[${tc.name}] only ${pass} OK mappings, expected at least ${tc.minPass}`);
    fail++;
  }
  totalPass += pass;
  totalFail += fail;
}

function positionOf(source, marker) {
  const offset = source.indexOf(marker);
  assert.ok(offset >= 0, 'expected to find ' + marker);
  const lines = source.slice(0, offset).split(/\r\n|[\r\n\u2028\u2029]/u);
  return { line: lines.length, column: lines.at(-1).length };
}

const exactCases = [
  {
    name: 'line-terminators',
    source: 'const before=0;\r\nconst afterPair=1;\rconst afterReturn=2;\u2028' +
      'const t=' + '\x60first\u2029second\x60' + '; const x="🗻"; const finish=1;',
    markers: ['const before', 'const afterPair', 'const afterReturn', 'const t', 'const x', 'const finish'],
  },
  {
    name: 'dense-lines',
    source: ';\n'.repeat(400) + 'const finish=1;',
    markers: ['const finish'],
  },
  {
    name: 'nested-expressions',
    source: 'const result =\r\n  outer(\n    "é🗻",\n    inner(40 +\n      62));',
    markers: ['outer(', '"é🗻"', 'inner(', '40', '62'],
  },
  {
    name: 'preserved-comments',
    source: '/*! banner */\n// leading note\nconst result =\r\n  /*#__PURE__*/ call("é🗻");',
    markers: ['const result', 'call(', '"é🗻"'],
  },
  {
    name: 'class-member-comments',
    source: 'class C {\n  // café 🪐\n  field = 12; /* field tail */\n  static {\n    // setup\n    this.ready = 23;\n  }\n  // method docs\n  method() {}\n}',
    markers: ['field', '12', 'static', 'this', '23', 'method()'],
  },
  {
    name: 'object-property-comments',
    source: 'const api = {\n /* first property */ key: 31,\n // next property\n read() { return 37; }\n};',
    markers: ['key', '31', 'read()', '37'],
  },
  {
    name: 'call-argument-comments',
    source: 'const result = outer(/* 🪐 */ 41, new Pair(// nested\r\n  43));',
    markers: ['outer(', '41', 'Pair(', '43'],
  },
  {
    name: 'typescript-operator-boundaries',
    extension: '.ts',
    source: 'const less = value <\n  <number>23;\nconst equal = value! ===\n  37;',
    markers: ['<number>', '23', '37'],
  },
  {
    name: 'jsx-comparison',
    extension: '.tsx',
    source: 'const result = value <\n  <Icon />;',
    markers: ['<Icon'],
  },
  // Names a debugger resolves: bindings, parameters, destructured names,
  // function and class names, and member names.
  {
    name: 'binding-and-member-names',
    source: 'function outer(first, { second }, [third]) {\n  const local = first.member.deep;\n' +
      '  class Inner {}\n  try {} catch (problem) {}\n  return local?.optional;\n}',
    markers: ['outer', 'first', 'second', 'third', 'local', 'member', 'deep', 'Inner', 'problem', 'optional'],
  },
  // Comments inside expressions, patterns and types move the tokens around
  // them in pretty output and vanish in minified output. Neither may shift
  // a mapping onto the comment or onto the wrong token.
  {
    name: 'array-element-comments',
    source: 'const list = [\n  // first\n  11, // one\n  /* two */ 22,\n  33 // last\n];',
    markers: ['11', '22', '33'],
  },
  {
    name: 'parameter-and-operand-comments',
    source: 'function f(/* a */ alpha, beta /* b */) {\n  return alpha + // why\n    beta.size /* op */ * 3;\n}',
    markers: ['alpha', 'beta', 'size', '3'],
  },
  {
    name: 'switch-case-comments',
    source: 'switch (kind) {\n  // about one\n  case 41: // on one\n    run(); // ran\n  /* about two */\n  default:\n    stop();\n}',
    markers: ['kind', '41', 'run()', 'stop()'],
  },
  {
    name: 'member-chain-comments',
    source: 'promise\n  // first step\n  .then(handle)\n  /* second step */ .catch(report);',
    markers: ['promise', 'then', 'handle', 'catch', 'report'],
  },
  {
    name: 'conditional-and-arrow-comments',
    source: 'const pick = test // the test\n  ? yes /* chosen */\n  : no;\n' +
      'const g = (item /* arg */) => (\n  // grouped\n  item + 1\n);',
    markers: ['test', 'yes', 'no', 'item', '1'],
  },
  {
    name: 'hoisted-return-comment',
    source: 'function h() {\n  return ( // why\n    left && right\n  );\n}',
    markers: ['return', 'left', 'right'],
  },
  {
    name: 'jsx-comments',
    extension: '.jsx',
    source: 'const el = <div /* on tag */ id="a">\n  {/* child */}\n  {value /* held */}\n</div>;',
    markers: ['<div', '"a"', 'value'],
  },
  {
    name: 'type-member-comments',
    extension: '.ts',
    source: 'interface Shape {\n  /** The name. */\n  name: string; // trailing\n  area(): number;\n}\n' +
      'const shape: /* typed */ Shape = make(/* arg */ 7);',
    markers: ['interface', 'name:', 'area(', 'shape', 'make(', '7'],
  },
];

for (const { name, source, markers, extension = '.js' } of exactCases) {
  for (const options of [[], ['--minified']]) {
    const srcPath = path.join(scratch, name + extension);
    const { code, consumer } = codegenWithMap(srcPath, source, options);
    for (const marker of markers) {
      const original = consumer.originalPositionFor(positionOf(code, marker));
      assert.deepEqual({ line: original.line, column: original.column }, positionOf(source, marker),
        [name, ...options, marker].join(' '));
      totalPass++;
    }
  }
}

console.log(`\nresult: ${totalPass} pass, ${totalFail} fail`);
process.exit(totalFail ? 1 : 0);
