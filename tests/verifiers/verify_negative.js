#!/usr/bin/env node
// Parser-negative gate.
//
// For every .js under `tests/fixtures/negative/`:
//   Kessel MUST produce at least one parse error (exit code != 0 OR stderr
//   reports "Parse errors: N" with N >= 1).
//
// These fixtures all encode invalid syntax that a parser must reject.
// Accepting them silently is a parser-compliance regression.
//
// Early-error / semantic-invalid fixtures live in a separate surface.
//
// Baseline (tests/baselines/negative_baseline.json) captures which fixtures
// the current parser correctly rejects vs wrongly accepts. Any fixture that
// moves from "rejected" to "accepted" is a regression; moving from "accepted"
// to "rejected" is an improvement (run with --update to commit).
//
// Usage:
//   node tests/verifiers/verify_negative.js             # check vs baseline
//   node tests/verifiers/verify_negative.js --update    # relock baseline
//   node tests/verifiers/verify_negative.js --strict    # fail on ANY accepted
//                                                         negative fixture,
//                                                         regardless of baseline
//   node tests/verifiers/verify_negative.js --verbose   # per-fixture outcome
//
// Exit 0 on success (matches or improves baseline); 1 on regression or (in
// --strict mode) any accepted-but-shouldn't fixture.
//
// Why NOT just fail on any accepted negative fixture?
//   The baseline lets us merge this gate immediately without blocking on
//   parser fixes. QA surfaces the bugs (the baseline file lists them); a
//   follow-up PR fixes them and relocks. This is the same pattern used
//   by verify_spec_compliance.js and run_spec_fixtures.js.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/negative_baseline.json');

const UPDATE = process.argv.includes('--update');
const STRICT = process.argv.includes('--strict');
const VERBOSE = process.argv.includes('--verbose');

// Directories under tests/fixtures/ whose contents are ALL meant to be rejected.
// `negative/` covers parse-time rejections (syntax errors, unterminated
// strings, invalid tokens). `early_errors/` covers early-error rules
// (ECMA-262 §5.2 static semantics) where the grammar accepts the input
// but the spec requires a *static* error: `const` without initializer,
// duplicate lexical declarations, `eval`/`arguments` as binding targets
// in strict mode, reserved words used as bindings, etc.
//
// Both buckets are skipped by the positive-fixture runner
// (tests/runners/run_tests.sh), so this gate is where they get exercised.
// The baseline records the current accept/reject split per fixture so we
// can close errors incrementally without a repo-wide regression each time.
const NEGATIVE_DIRS = [
  'tests/fixtures/negative',
  'tests/fixtures/early_errors',
];

function listNegativeFixtures() {
  const out = [];
  for (const dir of NEGATIVE_DIRS) {
    const root = path.join(ROOT, dir);
    if (!fs.existsSync(root)) continue;

    const stack = [{ abs: root, rel: dir }];
    while (stack.length > 0) {
      const current = stack.pop();
      const entries = fs.readdirSync(current.abs, { withFileTypes: true })
        .sort((a, b) => a.name.localeCompare(b.name));
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i];
        const abs = path.join(current.abs, entry.name);
        const rel = path.join(current.rel, entry.name);
        if (entry.isDirectory()) {
          stack.push({ abs, rel });
          continue;
        }
        if (!entry.isFile()) continue;
        if (!/\.(js|mjs)$/.test(entry.name)) continue;
        out.push({ rel, abs });
      }
    }
  }
  return out;
}

// Some fixtures only trip an early error under a specific source-type.
// The module_context/ dir contains programs that are legal as ES modules
// but SyntaxErrors as classic scripts (top-level `import`/`export`,
// `import.meta`, top-level `await`). The verifier pins sourceType via
// `--source-type=script` so the parser can emit those diagnostics.
//
// Returning an extra-args array keeps this table-driven: if a future
// fixture needs `--lang=ts` or `--source-type=module`, add another entry
// here rather than sprinkling conditionals through the code.
function extraArgsFor(rel) {
  if (rel.startsWith('tests/fixtures/early_errors/module_context/')) {
    return ['--source-type=script'];
  }
  return [];
}

// Run Kessel on `file` and decide whether it rejected the program.
//
// Rejection criterion (either suffices):
//   1. Exit code != 0 (crash, assertion, exit-with-status).
//   2. Stderr/stdout contains "Parse errors: N" with N >= 1.
//
// We deliberately accept BOTH signals. Some illegal programs trip the lexer
// and exit non-zero; others are caught by the parser and reported via
// "Parse errors: N". Either proves the parser isn't silently accepting.
function kesselRejects(abs, rel) {
  const args = ['parse', abs, ...extraArgsFor(rel)];
  const r = spawnSync(KESSEL, args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: 10_000,
  });
  const combined = (r.stdout || '') + (r.stderr || '');
  if (r.status !== 0) return { rejected: true, reason: `exit=${r.status}` };
  const m = combined.match(/Parse errors\s*(?:\((\d+)\)|:\s*(\d+))/);
  if (m) {
    const n = parseInt(m[1] || m[2], 10);
    if (n >= 1) return { rejected: true, reason: `${n} parse error(s)` };
  }
  return { rejected: false, reason: 'parsed cleanly (SPEC VIOLATION)' };
}

const fixtures = listNegativeFixtures();
if (fixtures.length === 0) {
  console.error('No negative fixtures found in:');
  for (const d of NEGATIVE_DIRS) console.error('  ' + d);
  process.exit(2);
}

// Measure current state: {fixture -> 'rejected'|'accepted'}.
const current = {};
for (const fix of fixtures) {
  const r = kesselRejects(fix.abs, fix.rel);
  current[fix.rel] = r.rejected ? 'rejected' : 'accepted';
  if (VERBOSE) {
    const mark = r.rejected ? 'OK  ' : 'FAIL';
    console.log(`  ${mark} ${fix.rel} — ${r.reason}`);
  }
}

const tally = { rejected: 0, accepted: 0 };
for (const v of Object.values(current)) tally[v]++;

console.log('');
console.log(`Negative fixtures: ${fixtures.length} total`);
console.log(`  rejected (parser caught the error):          ${tally.rejected}`);
console.log(`  accepted (parser missed the error — BUG):    ${tally.accepted}`);

// --strict mode: any accepted-but-shouldn't fails immediately.
if (STRICT) {
  if (tally.accepted > 0) {
    console.log('');
    console.log('STRICT mode — accepted fixtures are failures:');
    for (const [k, v] of Object.entries(current)) {
      if (v === 'accepted') console.log(`  FAIL ${k}`);
    }
    process.exit(1);
  }
  console.log('STRICT mode OK — every negative fixture was rejected.');
  process.exit(0);
}

// Baseline mode: compare current to locked baseline.
const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : null;

if (UPDATE || baseline === null) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`\nBaseline ${baseline === null ? 'created' : 'updated'}: ${BASELINE_PATH}`);
  if (tally.accepted > 0) {
    console.log(`NOTE — ${tally.accepted} fixture(s) are baselined as "accepted"; these are known parser bugs.`);
  }
  process.exit(0);
}

// Compare.
const regressions = [];
const improvements = [];
const newAccepted = [];
const newRejected = [];

for (const fix of fixtures) {
  const prev = baseline[fix.rel];
  const now = current[fix.rel];
  if (prev === undefined) {
    if (now === 'accepted') newAccepted.push(fix.rel);
    else newRejected.push(fix.rel);
  } else if (prev === 'rejected' && now === 'accepted') {
    regressions.push(fix.rel);
  } else if (prev === 'accepted' && now === 'rejected') {
    improvements.push(fix.rel);
  }
}
// Stale baseline entries (fixture removed).
const removed = Object.keys(baseline).filter(k => !(k in current));

// Ratchet: once the baseline is 100% clean, stay 100% clean. Any new
// fixture that is 'accepted' under the current parser is a gate failure
// even though it wasn't in the baseline yet — you can't cover up the
// regression by adding the fixture without also fixing it. To land a
// fixture that the parser can't handle yet, either fix the parser first
// or relax the baseline with --update (and document the known gap).
const baselineIsClean = Object.values(baseline).every(v => v === 'rejected');

console.log('');
if (newRejected.length) console.log(`NEW fixtures (rejected): ${newRejected.length}`);
for (const f of newRejected) console.log(`    ${f}`);
if (newAccepted.length) console.log(`NEW fixtures (accepted — parser bug): ${newAccepted.length}`);
for (const f of newAccepted) console.log(`    ${f}`);
if (improvements.length) console.log(`IMPROVEMENTS: ${improvements.length}`);
for (const f of improvements) console.log(`    ${f}: accepted -> rejected`);
if (regressions.length)  console.log(`REGRESSIONS: ${regressions.length}`);
for (const f of regressions) console.log(`    ${f}: rejected -> accepted (SPEC VIOLATION)`);
if (removed.length)      console.log(`REMOVED from fixtures: ${removed.length}`);
for (const f of removed) console.log(`    ${f}`);

if (regressions.length > 0) {
  console.log('\nFAIL — run with --update after confirming the regressions are intentional.');
  process.exit(1);
}
if (baselineIsClean && newAccepted.length > 0) {
  console.log('\nFAIL — baseline is 100% clean; new fixtures must also be rejected.');
  console.log('Either fix the parser first, or run with --update if this is an intentional known-gap.');
  process.exit(1);
}
if (improvements.length > 0 || newRejected.length > 0 || newAccepted.length > 0) {
  console.log('\nOK (with improvements/new) — run with --update to relock.');
}
if (regressions.length === 0 && improvements.length === 0 && newRejected.length === 0 && newAccepted.length === 0) {
  console.log('\nOK — matches baseline exactly.');
}
process.exit(0);
