#!/usr/bin/env node
// Run every fixture under tests/spec_fixtures/ through Kessel and compare
// the emitted ESTree against OXC's parseSync output. Each category
// (es2015..es2025, edge) gets a per-directory pass rate; the overall rate
// is locked via tests/spec_fixtures_baseline.json so any regression trips
// the gate.
//
// This is distinct from tests/verify_spec_compliance.js (real-world files)
// because the fixtures are hand-authored, minimal, and category-tagged so
// a regression points directly at a feature bucket (e.g. "es2020 optional
// chaining regressed by 2").
//
// Usage:
//   node tests/run_spec_fixtures.js             # check against baseline
//   node tests/run_spec_fixtures.js --update    # relock baseline
//   node tests/run_spec_fixtures.js --verbose   # show per-fixture outcome
//
// Exit 0 if every category matches/improves its baseline; exit 1 on any
// regression.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const FIX_ROOT = path.join(ROOT, 'tests/fixtures/spec');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/spec_fixtures_baseline.json');

const UPDATE = process.argv.includes('--update');
const VERBOSE = process.argv.includes('--verbose');

// Enumerate (category, fixture) pairs.
// Walk the tree recursively so any future nested fixture families under a
// category are picked up automatically without another runner edit.
function listFixtures() {
  const out = [];
  for (const cat of fs.readdirSync(FIX_ROOT).sort()) {
    const catDir = path.join(FIX_ROOT, cat);
    if (!fs.statSync(catDir).isDirectory()) continue;
    listFixtures_inCategory(catDir, cat, out);
  }
  return out;
}

function listFixtures_inCategory(dir, category, out) {
  for (const entry of fs.readdirSync(dir).sort()) {
    const file = path.join(dir, entry);
    const stat = fs.statSync(file);
    if (stat.isDirectory()) {
      listFixtures_inCategory(file, category, out);
      continue;
    }
    if (!entry.endsWith('.js')) continue;
    const rel = path.relative(FIX_ROOT, file);
    out.push({ category, file, rel });
  }
}

// Fixtures live under .js paths but some exercise JSX or TS grammar. Pick
// the right --lang flag from the category so Kessel parses them in the
// correct grammar mode (otherwise e.g. spec/typescript/007_type_assertion
// fails with "unexpected <" because JS mode rejects `<Type>expr`).
//
// `spec/interactions/` is a deliberately mixed-dialect bucket; dialect is
// chosen per file via filename markers so that each fixture can sit in its
// natural interaction bucket instead of being split across dialect dirs:
//   `_jsx_` -> JSX, `_ts_` -> TS. Everything else in the bucket is JS.
function langFlag(file) {
  if (file.includes('/spec/jsx/'))        return ' --lang=jsx';
  if (file.includes('/spec/typescript/')) return ' --lang=ts';
  if (file.includes('/spec/ambiguity/'))  return ' --lang=tsx';
  if (file.includes('/spec/interactions/')) {
    if (/_jsx_/.test(file)) return ' --lang=jsx';
    if (/_ts_/.test(file))  return ' --lang=ts';
    return '';
  }
  return '';
}

// Run one fixture and return {ok, reason?}.
function check(fix) {
  // Kessel must parse without error.
  let kExit = 0, kStdout = '', kStderr = '';
  try {
    kStdout = execSync(`"${KESSEL}" parse${langFlag(fix.file)} "${fix.file}" --compact 2>&1`,
      { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  } catch (e) {
    kExit = e.status || 1;
    kStdout = (e.stdout || '').toString();
    kStderr = (e.stderr || '').toString();
  }
  if (kExit !== 0) return { ok: false, reason: `kessel exit=${kExit}` };
  if (kStdout.indexOf('Parse errors (') !== -1) {
    const m = kStdout.match(/Parse errors \((\d+)\)/);
    return { ok: false, reason: `${m ? m[1] : '?'} parse errors` };
  }

  // Deep compare vs OXC (the most permissive, closest-to-spec reference
  // of the three in our harness). Any divergence fails this fixture \u2014 these
  // fixtures are MINIMAL and SHOULD match OXC cleanly. Divergences on real
  // files are tolerated via tests/verify_spec_compliance.js baselines;
  // fixtures are the clean ones.
  try {
    execSync(`node tests/verifiers/verify_json_deep.js "${fix.file}" --parser oxc --limit 0`,
      { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, stdio: 'pipe' });
    return { ok: true };
  } catch (e) {
    const out = (e.stdout || '').toString();
    const m = out.match(/(\d+) divergence\(s\) vs/);
    return { ok: false, reason: m ? `${m[1]} divergence(s) vs oxc` : 'verifier error' };
  }
}

const fixtures = listFixtures();
const perCategory = {};
const failures = [];
let pass = 0;

for (const fix of fixtures) {
  perCategory[fix.category] ||= { pass: 0, fail: 0 };
  const r = check(fix);
  if (r.ok) {
    perCategory[fix.category].pass++;
    pass++;
    if (VERBOSE) console.log(`  OK   ${fix.rel}`);
  } else {
    perCategory[fix.category].fail++;
    failures.push({ rel: fix.rel, reason: r.reason });
    if (VERBOSE) console.log(`  FAIL ${fix.rel} \u2014 ${r.reason}`);
  }
}

// -----------------------------------------------------------------------------
// Report vs baseline.
// -----------------------------------------------------------------------------
const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : {};

const current = {};
for (const [cat, c] of Object.entries(perCategory)) {
  current[cat] = { pass: c.pass, fail: c.fail, total: c.pass + c.fail };
}

console.log('');
console.log('Category pass rates:');
let regressions = 0;
let improvements = 0;
for (const cat of Object.keys(current).sort()) {
  const c = current[cat];
  const b = baseline[cat];
  const pct = Math.round((c.pass / c.total) * 100);
  if (!b) {
    console.log(`  ${cat}: ${c.pass}/${c.total} (${pct}%) (new)`);
  } else if (c.pass > b.pass) {
    improvements++;
    console.log(`  ${cat}: ${c.pass}/${c.total} (${pct}%) (baseline ${b.pass}, improved by ${c.pass - b.pass})`);
  } else if (c.pass < b.pass) {
    regressions++;
    console.log(`  ${cat}: ${c.pass}/${c.total} (${pct}%) (baseline ${b.pass}, REGRESSED by ${b.pass - c.pass})`);
  } else {
    console.log(`  ${cat}: ${c.pass}/${c.total} (${pct}%) (baseline)`);
  }
}

console.log('');
console.log(`Overall: ${pass}/${fixtures.length} fixtures pass`);
if (failures.length > 0 && VERBOSE) {
  console.log('Failures:');
  for (const f of failures) console.log(`  ${f.rel} \u2014 ${f.reason}`);
}

if (UPDATE) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`Baseline updated: ${BASELINE_PATH}`);
  process.exit(0);
}

if (regressions > 0) {
  console.log(`REGRESSIONS in ${regressions} categor(ies)`);
  if (!VERBOSE) console.log('  Re-run with --verbose to see per-fixture failures.');
  process.exit(1);
}
if (improvements > 0) {
  console.log(`${improvements} categor(ies) improved. Re-run with --update to lock.`);
}
process.exit(0);
