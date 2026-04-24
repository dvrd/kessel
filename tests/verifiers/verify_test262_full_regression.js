#!/usr/bin/env node
// Compare a fresh Test262 full-corpus run against the baseline and
// flag regressions.
//
// Baseline: tests/baselines/test262_full_baseline.json (snapshot of the
// last blessed run). Today's run: tmp/test262_full_run.json (written by
// `task test:test262:full:json`).
//
// Regression criteria (any of):
//   • Today's `pass` count is lower than baseline.
//   • Today's `crash` count is higher than baseline.
//   • Any perDir pass count is lower than baseline.
//
// Improvements (today > baseline on pass) are reported but don't fail
// the gate. Run with `--update` to relock the baseline.

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const BASELINE = path.join(ROOT, 'tests/baselines/test262_full_baseline.json');
const FRESH    = path.join(ROOT, 'tmp/test262_full_run.json');
const UPDATE   = process.argv.includes('--update');

if (!fs.existsSync(FRESH)) {
  console.error(`Fresh run not found at ${FRESH}`);
  console.error(`Run \`task test:test262:full:json\` first.`);
  process.exit(2);
}

const fresh = JSON.parse(fs.readFileSync(FRESH, 'utf8'));

if (UPDATE || !fs.existsSync(BASELINE)) {
  fs.writeFileSync(BASELINE, JSON.stringify(fresh, null, 2));
  console.log(`Baseline written to ${BASELINE}`);
  console.log(`  pass: ${fresh.counts.pass}/${fresh.total}  rate: ${fresh.rate}%`);
  process.exit(0);
}

const baseline = JSON.parse(fs.readFileSync(BASELINE, 'utf8'));

const regressions = [];
const improvements = [];

if (fresh.counts.pass < baseline.counts.pass) {
  regressions.push(`overall pass count dropped: ${baseline.counts.pass} → ${fresh.counts.pass}`);
}
if (fresh.counts.pass > baseline.counts.pass) {
  improvements.push(`overall pass count grew: ${baseline.counts.pass} → ${fresh.counts.pass}`);
}
if (fresh.counts.crash > baseline.counts.crash) {
  regressions.push(`crash count grew: ${baseline.counts.crash} → ${fresh.counts.crash}`);
}

for (const dir of Object.keys(baseline.perDir)) {
  const b = baseline.perDir[dir];
  const f = fresh.perDir[dir] || { pass: 0, fail: 0, crash: 0, timeout: 0 };
  if (f.pass < b.pass) {
    regressions.push(`${dir}: pass dropped ${b.pass} → ${f.pass}`);
  } else if (f.pass > b.pass) {
    improvements.push(`${dir}: pass grew ${b.pass} → ${f.pass}`);
  }
  if (f.crash > b.crash) {
    regressions.push(`${dir}: crash grew ${b.crash} → ${f.crash}`);
  }
}

console.log(`Test262 baseline compare:`);
console.log(`  baseline pass: ${baseline.counts.pass}/${baseline.total}  rate: ${baseline.rate}%`);
console.log(`  fresh    pass: ${fresh.counts.pass}/${fresh.total}        rate: ${fresh.rate}%`);
console.log('');

if (improvements.length > 0) {
  console.log('Improvements (re-run with --update to relock):');
  for (const m of improvements) console.log(`  + ${m}`);
  console.log('');
}

if (regressions.length > 0) {
  console.log('Regressions:');
  for (const m of regressions) console.log(`  - ${m}`);
  console.log('');
  process.exit(1);
}

console.log('OK — no regressions against Test262 baseline.');
