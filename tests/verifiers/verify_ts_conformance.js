#!/usr/bin/env node
// TypeScript conformance gate.
//
// Walks the curated TS/TSX/D.TS corpus and parses each file with Kessel,
// expecting **zero parse errors** on syntactically-valid fixtures. Any
// fixture that drifts from "passes" to "errors" between runs is a
// regression.
//
// Corpus = three sources, in order of cost:
//   1. tests/fixtures/spec/typescript/*.js   (tiny curated TS fixtures —
//      all .js extension, parsed with --lang=ts).
//   2. bench/real_world_ts/**/*.{ts,tsx,d.ts} (vendored real-world TS;
//      see tests/fixtures/ts_conformance_corpus.json for the manifest).
//   3. bench/node_modules/**/*.d.ts          (transitively-vendored real
//      TS declaration files from acorn / babel / oxc-parser).
//
// Invoked from the Taskfile via `task test:ts:conformance`. Baseline lives
// at `tests/baselines/ts_conformance_baseline.json`.
//
// Baseline shape (mirrors negative_baseline.json):
//   {
//     "files": {
//       "<rel-path>": { "status": "pass" | "fail", "errors": <int>,
//                       "timeout_ms": <int|null> }
//     }
//   }
//
// A baseline-locked failure is acceptable; a NEW failure (status flipped
// from pass→fail OR a new fail in a previously-unseen file) is a
// regression. Use `--update` to relock after deliberate parser changes.
//
// Usage:
//   node tests/verifiers/verify_ts_conformance.js              # check
//   node tests/verifiers/verify_ts_conformance.js --update     # relock
//   node tests/verifiers/verify_ts_conformance.js --strict     # any fail
//   node tests/verifiers/verify_ts_conformance.js --verbose    # per-file

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const BIN = process.env.KESSEL_BIN || path.join(ROOT, 'bin/kessel');
const BASELINE = path.join(ROOT, 'tests/baselines/ts_conformance_baseline.json');

const args = {
  update:  process.argv.includes('--update'),
  strict:  process.argv.includes('--strict'),
  verbose: process.argv.includes('--verbose'),
};

// Per-file timeout. Generous because TS files can be large and the parser
// has quadratic-time pockets we're still chasing. A timeout is a recorded
// failure mode — it doesn't crash the gate.
const TIMEOUT_MS = parseInt(process.env.KESSEL_TS_TIMEOUT_MS || '15000', 10);

if (!fs.existsSync(BIN)) {
  console.error(`Error: kessel binary not found at ${BIN}`);
  console.error(`Run 'task build' first or set KESSEL_BIN=...`);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Corpus discovery
// ---------------------------------------------------------------------------

function walkDir(dir, exts) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  const stk = [dir];
  while (stk.length > 0) {
    const cur = stk.pop();
    for (const name of fs.readdirSync(cur)) {
      const abs = path.join(cur, name);
      const st = fs.statSync(abs);
      if (st.isDirectory()) {
        stk.push(abs);
      } else if (st.isFile()) {
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

  // 1. Curated TS fixtures (all .js, parsed with --lang=ts).
  const tsFixtureDir = path.join(ROOT, 'tests/fixtures/spec/typescript');
  for (const abs of walkDir(tsFixtureDir, ['.js'])) {
    fixtures.push({ abs, rel: path.relative(ROOT, abs), lang: 'ts' });
  }

  // 2. Real-world vendored TS (manifest opt-in to keep the gate predictable).
  const corpusManifestPath = path.join(ROOT, 'tests/fixtures/ts_conformance_corpus.json');
  if (fs.existsSync(corpusManifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(corpusManifestPath, 'utf8'));
    for (const entry of manifest.files || []) {
      const abs = path.resolve(ROOT, entry.path);
      if (!fs.existsSync(abs)) {
        console.error(`warn: missing corpus file ${entry.path}`);
        continue;
      }
      fixtures.push({
        abs,
        rel:  entry.path,
        lang: entry.lang || langFromExt(abs) || 'ts',
        skip: entry.skip || false,
        skip_reason: entry.skip_reason || '',
      });
    }
  }

  // De-dup by abs path (manifest may overlap with auto-discovery).
  const seen = new Set();
  return fixtures.filter(f => {
    if (seen.has(f.abs)) return false;
    seen.add(f.abs);
    return true;
  });
}

function langFromExt(abs) {
  const lower = abs.toLowerCase();
  if (lower.endsWith('.tsx')) return 'tsx';
  if (lower.endsWith('.d.ts') || lower.endsWith('.ts') ||
      lower.endsWith('.mts') || lower.endsWith('.cts')) return 'ts';
  return null;
}

// ---------------------------------------------------------------------------
// Per-file parse
// ---------------------------------------------------------------------------

function parseOne(fixture) {
  // Use single-file mode (no --quiet, no extra positional). The single-file
  // mode emits the AST to stdout AND a `Parse errors: N` line to stderr.
  // We discard stdout below; stderr is what we grep. NEVER use --quiet here:
  // that activates parse-many mode which discards per-file --lang.
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
  // Crash = exit status that's not 0 (success) or 1 (parse errors).
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

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const fixtures = discoverCorpus();
console.error(`ts_conformance: discovered ${fixtures.length} fixture(s)`);

const results = {};
let passCt = 0, failCt = 0, skipCt = 0;
for (const fix of fixtures) {
  if (fix.skip) {
    results[fix.rel] = { status: 'skip', errors: 0, timeout_ms: null,
                         skip_reason: fix.skip_reason };
    skipCt++;
    if (args.verbose) {
      console.error(`  SKIP ${fix.rel} — ${fix.skip_reason}`);
    }
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

// ---------------------------------------------------------------------------
// Baseline diff
// ---------------------------------------------------------------------------

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

// Compare results against baseline. Regressions = pass→fail or new failures.
const regressions = [];
const improvements = [];
const newFiles = [];
const knownFails = [];

for (const rel of Object.keys(results)) {
  const cur = results[rel];
  const prev = baseline.files && baseline.files[rel];
  if (!prev) {
    if (cur.status === 'fail') {
      newFiles.push({ rel, cur });
    }
    continue;
  }
  if (prev.status === 'pass' && cur.status === 'fail') {
    regressions.push({ rel, prev, cur });
  } else if (prev.status === 'fail' && cur.status === 'pass') {
    improvements.push({ rel, prev, cur });
  } else if (cur.status === 'fail') {
    knownFails.push({ rel, cur });
  }
}

console.error('');
console.error(`ts_conformance summary:`);
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
    console.error(`  ${it.rel} — was ${it.prev.errors} errors, now passes`);
  }
  if (improvements.length > 20) console.error(`  ... +${improvements.length - 20} more`);
}

if (args.strict && (failCt > 0)) {
  console.error('');
  console.error(`STRICT mode: ${failCt} failure(s) (regressions OR known-fails) — failing.`);
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
