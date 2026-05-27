// Validate the sourcemap kessel emits by decoding it with the standard
// `source-map-js` consumer and checking that (gen_line, gen_col) queries
// map back to a source slice whose first non-whitespace prefix matches
// the corresponding generated line.
//
// The verifier writes its own inputs into /tmp so it does not depend on
// previous shell state. It runs two cases: a multi-statement single
// source line (regression check for column tracking when the codegen
// breaks a source line into several generated lines), and a multi-line
// source (regression check for source-line tracking).
const { SourceMapConsumer } = require('source-map-js');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const BIN = path.join(__dirname, '..', '..', 'bin', 'kessel');

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
  const srcPath = `/tmp/sm_input_${tc.name.replace(/\W+/g, '_')}.js`;
  fs.writeFileSync(srcPath, tc.src);

  const out = execFileSync(BIN, ['codegen', srcPath, '--sourcemap'], { encoding: 'utf8' });
  const outLines = out.split('\n');
  const sm = outLines.find(l => l.startsWith('//# sourceMappingURL='));
  if (!sm) {
    console.error(`[${tc.name}] no sourceMappingURL emitted`);
    process.exit(1);
  }
  const b64 = sm.split('base64,', 2)[1];
  const map = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));

  const consumer = new SourceMapConsumer(map);
  const src = tc.src.split('\n');
  const gen = out.split('\n');

  console.log(`\n=== ${tc.name} ===`);
  let pass = 0, fail = 0;
  for (let l = 0; l < gen.length - 2; l++) {
    const line = gen[l];
    if (!line.trim()) continue;
    if (line.startsWith('//# sourceMappingURL=')) continue;
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

console.log(`\nresult: ${totalPass} pass, ${totalFail} fail`);
process.exit(totalFail ? 1 : 0);
