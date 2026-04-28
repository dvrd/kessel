#!/usr/bin/env node
// JSX conformance gate.
//
// Walks the curated JSX/TSX corpus and parses each file with Kessel,
// expecting **zero parse errors** on syntactically-valid fixtures. Same
// shape as verify_ts_conformance.js — see that file for the rationale,
// baseline format, and regression-classification rules.
//
// Corpus = two sources:
//   1. tests/fixtures/spec/jsx/*.js          (curated JSX fixtures —
//      .js extension, parsed with --lang=jsx).
//   2. tests/fixtures/jsx_conformance_corpus.json (manifest of vendored
//      real-world JSX/TSX files; opt-in to keep the gate predictable).
//
// Baseline lives at `tests/baselines/jsx_conformance_baseline.json`.

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const BIN = process.env.KESSEL_BIN || path.join(ROOT, 'bin/kessel');
const BASELINE = path.join(ROOT, 'tests/baselines/jsx_conformance_baseline.json');

const args = {
  update:  process.argv.includes('--update'),
  strict:  process.argv.includes('--strict'),
  verbose: process.argv.includes('--verbose'),
};

const TIMEOUT_MS = parseInt(process.env.KESSEL_JSX_TIMEOUT_MS || '15000', 10);

if (!fs.existsSync(BIN)) {
  console.error(`Error: kessel binary not found at ${BIN}`);
  console.error(`Run 'task build' first or set KESSEL_BIN=...`);
  process.exit(2);
}

function walkDir(dir, exts) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  const stk = [dir];
  while (stk.length > 0) {
    const cur = stk.pop();
    for (const name of fs.readdirSync(cur)) {
      const abs = path.join(cur, name);
      const st = fs.statSync(abs);
      if (st.isDirectory()) stk.push(abs);
      else if (st.isFile()) {
        const lower = name.toLowerCase();
        for (const ext of exts) {
          if (lower.endsWith(ext)) { out.push(abs); break; }
        }
      }
    }
  }
  return out;
}

function discoverCorpus() {
  const fixtures = [];
  const jsxDir = path.join(ROOT, 'tests/fixtures/spec/jsx');
  for (const abs of walkDir(jsxDir, ['.js'])) {
    fixtures.push({ abs, rel: path.relative(ROOT, abs), lang: 'jsx' });
  }
  // Ambiguity fixtures stress JSX vs TS-generic disambiguation; include them
  // so the JSX-mode parse path is covered in this gate too.
  const ambDir = path.join(ROOT, 'tests/fixtures/spec/ambiguity');
  for (const abs of walkDir(ambDir, ['.js'])) {
    // Per-fixture --lang is encoded in the file's golden-test-runner config.
    // For the conformance gate we just want to verify JSX-mode parsing
    // doesn't crash on these adversarial cases.
    fixtures.push({ abs, rel: path.relative(ROOT, abs), lang: 'tsx' });
  }
  const corpusManifest = path.join(ROOT, 'tests/fixtures/jsx_conformance_corpus.json');
  if (fs.existsSync(corpusManifest)) {
    const manifest = JSON.parse(fs.readFileSync(corpusManifest, 'utf8'));
    for (const entry of manifest.files || []) {
      const abs = path.resolve(ROOT, entry.path);
      if (!fs.existsSync(abs)) {
        console.error(`warn: missing corpus file ${entry.path}`);
        continue;
      }
      fixtures.push({
        abs,
        rel:  entry.path,
        lang: entry.lang || 'jsx',
        skip: entry.skip || false,
        skip_reason: entry.skip_reason || '',
      });
    }
  }
  const seen = new Set();
  return fixtures.filter(f => seen.has(f.abs) ? false : (seen.add(f.abs), true));
}

function parseOne(fixture) {
  // Single-file mode only. Don't pass --quiet — that triggers parse-many
  // which discards per-file --lang. See verify_ts_conformance.js for the
  // equivalent rationale.
  const cli = ['parse', fixture.abs, `--lang=${fixture.lang}`];
  const t0 = Date.now();
  const r = spawnSync(BIN, cli, {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
    timeout: TIMEOUT_MS,
  });
  const elapsed = Date.now() - t0;
  const out = `${r.stdout || ''}${r.stderr || ''}`;
  if (r.error && r.error.code === 'ETIMEDOUT') {
    return { status: 'fail', errors: -1, timeout_ms: elapsed, reason: 'timeout' };
  }
  if (r.status !== 0 && r.status !== 1 && r.status !== null) {
    return { status: 'fail', errors: -1, timeout_ms: null, reason: `crash exit=${r.status}` };
  }
  const m = out.match(/(?:Errors|Parse errors):\s*(\d+)/);
  const errs = m ? parseInt(m[1], 10) : 0;
  if (errs > 0) {
    return { status: 'fail', errors: errs, timeout_ms: null, reason: 'parse-errors' };
  }
  return { status: 'pass', errors: 0, timeout_ms: null };
}

const fixtures = discoverCorpus();
console.error(`jsx_conformance: discovered ${fixtures.length} fixture(s)`);

const results = {};
let passCt = 0, failCt = 0, skipCt = 0;
for (const fix of fixtures) {
  if (fix.skip) {
    results[fix.rel] = { status: 'skip', errors: 0, timeout_ms: null,
                         skip_reason: fix.skip_reason };
    skipCt++;
    continue;
  }
  const r = parseOne(fix);
  results[fix.rel] = r;
  if (r.status === 'pass') {
    passCt++;
    if (args.verbose) console.error(`  pass ${fix.rel}`);
  } else {
    failCt++;
    if (args.verbose) {
      const reason = r.reason || `errors=${r.errors}`;
      console.error(`  FAIL ${fix.rel} — ${reason}`);
    }
  }
}

const baseline = fs.existsSync(BASELINE)
  ? JSON.parse(fs.readFileSync(BASELINE, 'utf8'))
  : { files: {} };

if (args.update) {
  const out = {
    generated_at: new Date().toISOString(),
    summary:      { total: fixtures.length, pass: passCt, fail: failCt, skip: skipCt },
    files:        results,
  };
  fs.mkdirSync(path.dirname(BASELINE), { recursive: true });
  fs.writeFileSync(BASELINE, JSON.stringify(out, null, 2) + '\n');
  console.error(`baseline updated: ${BASELINE}`);
  console.error(`  pass=${passCt} fail=${failCt} skip=${skipCt} total=${fixtures.length}`);
  process.exit(0);
}

const regressions = [], improvements = [], newFiles = [], knownFails = [];
for (const rel of Object.keys(results)) {
  const cur = results[rel];
  const prev = baseline.files && baseline.files[rel];
  if (!prev) {
    if (cur.status === 'fail') newFiles.push({ rel, cur });
    continue;
  }
  if (prev.status === 'pass' && cur.status === 'fail') regressions.push({ rel, prev, cur });
  else if (prev.status === 'fail' && cur.status === 'pass') improvements.push({ rel, prev, cur });
  else if (cur.status === 'fail') knownFails.push({ rel, cur });
}

console.error('');
console.error(`jsx_conformance summary:`);
console.error(`  total:        ${fixtures.length}`);
console.error(`  pass:         ${passCt}`);
console.error(`  fail:         ${failCt}`);
console.error(`  skip:         ${skipCt}`);
console.error(`  regressions:  ${regressions.length}`);
console.error(`  improvements: ${improvements.length}`);
console.error(`  new failures: ${newFiles.length}`);

if (improvements.length > 0) {
  console.error('');
  console.error(`improvements (run with --update to lock these wins in):`);
  for (const it of improvements.slice(0, 20)) {
    console.error(`  ${it.rel}`);
  }
}

if (args.strict && failCt > 0) {
  console.error('');
  console.error(`STRICT mode: ${failCt} failure(s) — failing.`);
  process.exit(1);
}

if (regressions.length > 0 || newFiles.length > 0) {
  console.error('');
  if (regressions.length > 0) {
    console.error(`REGRESSIONS:`);
    for (const it of regressions) {
      const reason = it.cur.reason || `errors=${it.cur.errors}`;
      console.error(`  ${it.rel} — ${reason}`);
    }
  }
  if (newFiles.length > 0) {
    console.error(`NEW FAILURES (file not in baseline):`);
    for (const it of newFiles) {
      const reason = it.cur.reason || `errors=${it.cur.errors}`;
      console.error(`  ${it.rel} — ${reason}`);
    }
  }
  console.error('');
  console.error(`If these are intentional, run --update to relock the baseline.`);
  process.exit(1);
}

console.error('');
console.error(`OK — no regressions; ${knownFails.length} baseline-known failure(s).`);
process.exit(0);
