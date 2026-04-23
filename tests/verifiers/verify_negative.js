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
const NEGATIVE_DIRS = [
  'tests/fixtures/negative',
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

// Run Kessel on `file` and decide whether it rejected the program.
//
// Rejection criterion (either suffices):
//   1. Exit code != 0 (crash, assertion, exit-with-status).
//   2. Stderr/stdout contains "Parse errors: N" with N >= 1.
//
// We deliberately accept BOTH signals. Some illegal programs trip the lexer
// and exit non-zero; others are caught by the parser and reported via
// "Parse errors: N". Either proves the parser isn't silently accepting.
function kesselRejects(abs) {
  const r = spawnSync(KESSEL, ['parse', abs], {
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
  const r = kesselRejects(fix.abs);
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
const newFixtures = [];

for (const fix of fixtures) {
  const prev = baseline[fix.rel];
  const now = current[fix.rel];
  if (prev === undefined) {
    newFixtures.push(fix.rel);
  } else if (prev === 'rejected' && now === 'accepted') {
    regressions.push(fix.rel);
  } else if (prev === 'accepted' && now === 'rejected') {
    improvements.push(fix.rel);
  }
}
// Stale baseline entries (fixture removed).
const removed = Object.keys(baseline).filter(k => !(k in current));

console.log('');
if (newFixtures.length)  console.log(`NEW fixtures (not in baseline): ${newFixtures.length}`);
for (const f of newFixtures) console.log(`    ${f} (currently ${current[f]})`);
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
if (improvements.length > 0 || newFixtures.length > 0) {
  console.log('\nOK (with improvements/new) — run with --update to relock.');
}
if (regressions.length === 0 && improvements.length === 0 && newFixtures.length === 0) {
  console.log('\nOK — matches baseline exactly.');
}
process.exit(0);
