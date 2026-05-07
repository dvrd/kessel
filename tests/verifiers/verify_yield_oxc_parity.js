// verify_yield_oxc_parity.js — confirms OXC + kessel agree on every
// `yield` parse-flow-tied early error. Documents and pins the four
// slice-13e promotions (parser-side `report_error` for yield-as-
// label / yield-as-conditional-LHS / yield-as-binary-RHS / yield-as-
// unary-operand) by exercising both engines on representative source
// strings and asserting the accept/reject answers match.
//
// Run with: node tests/verifiers/verify_yield_oxc_parity.js
// Expects oxc-parser to be installed via npm (already a dev dep).
const oxc = require('oxc-parser');
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const cases = [
  { name: 'yield as label inside generator',                   src: 'function* g() { yield: ; }' },
  { name: 'yield ?: (left of conditional)',                    src: 'function* g() { yield ? a : b; }' },
  { name: 'yield || (left of logical)',                        src: 'function* g() { yield || x; }' },
  { name: 'yield == (left of equality)',                       src: 'function* g() { yield == x; }' },
  { name: 'paren-wrapped (yield)+1 (legal)',                   src: 'function* g() { (yield) + 1; }' },
  { name: 'x == yield (right of equality, paren needed)',      src: 'function* g() { x == yield; }' },
  { name: 'x == (yield) (right of equality, paren-wrapped)',   src: 'function* g() { x == (yield); }' },
  { name: 'void yield (unary operand)',                        src: 'function* g() { void yield; }' },
  { name: 'typeof yield (unary operand)',                      src: 'function* g() { typeof yield; }' },
  { name: 'void (yield) (unary operand, paren-wrapped)',       src: 'function* g() { void (yield); }' },
  { name: 'yield as identifier outside generator (legal)',     src: 'function f() { yield + 1; }' },
];

const tmp = path.join(__dirname, '_parity_tmp.js');
let mismatches = 0;
for (const c of cases) {
  fs.writeFileSync(tmp, c.src);
  let oxcRej = false;
  try {
    const r = oxc.parseSync('test.js', c.src);
    oxcRej = !!(r.errors && r.errors.length);
  } catch (e) { oxcRej = true; }
  const r = spawnSync('./bin/kessel', ['parse', tmp], { encoding: 'utf8' });
  const combined = (r.stdout || '') + '\n' + (r.stderr || '');
  // kessel emits "Parse errors (N):" on stdout (when N > 0) and "Parse errors: N" on stderr always.
  let kRej = false;
  let m = combined.match(/Parse errors:\s*(\d+)/);
  if (m) kRej = parseInt(m[1], 10) > 0;
  else {
    m = combined.match(/Parse errors\s*\((\d+)\)/);
    if (m) kRej = parseInt(m[1], 10) > 0;
  }
  const tag = (oxcRej === kRej) ? 'OK      ' : 'MISMATCH';
  if (oxcRej !== kRej) mismatches++;
  console.log(`${tag}  oxc=${oxcRej?'rej':'acc'}  kessel=${kRej?'rej':'acc'}  ${c.name}`);
}
fs.unlinkSync(tmp);
console.log('');
console.log(`Mismatches: ${mismatches} / ${cases.length}`);
process.exit(mismatches === 0 ? 0 : 1);
