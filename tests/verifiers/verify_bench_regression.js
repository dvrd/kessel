#!/usr/bin/env node
// Performance regression gate.
//
// Runs `bin/kessel microbench parse <file>` on a small curated set of real-
// world files, compares the min runtime (robust to jitter) against a committed
// baseline in tests/baselines/bench_baseline.json, and fails on:
//
//   * Per-file regression  > 10% slower than baseline (PER_FILE_TOLERANCE)
//   * Geo-mean regression  >  5% slower than baseline (GEOMEAN_TOLERANCE)
//
// Improvements (faster than baseline) are always reported but never fail.
// Run with `--update` to commit a new baseline after a deliberate perf change.
//
// Why a small curated set, not all 467 files?
//   Microbench time dominates wall-clock. 10 representative files \u00d7 30
//   iterations runs in ~60s; all 467 files would be 30+ minutes. The 10
//   files span size decades (snabbdom 4KB \u2192 typescript 10MB) and syntax
//   bucketing (JSX-heavy react, deeply-nested monaco, uniform lodash).
//
// Why min, not mean or median?
//   Min is the floor \u2014 machine could only be so fast, and noise can only
//   make runs SLOWER. Min minimises false alarms from a noisy CI host. If
//   min regresses, something real changed.
//
// Why geo-mean across files, not arithmetic mean?
//   File sizes span 4 orders of magnitude; an arithmetic mean over raw ns
//   would be dominated by typescript.js. Geo-mean of per-file ratios gives
//   each file equal weight.
//
// Usage:
//   node tests/verifiers/verify_bench_regression.js              # check vs baseline
//   node tests/verifiers/verify_bench_regression.js --update     # rewrite baseline
//   node tests/verifiers/verify_bench_regression.js --iterations 50
//   node tests/verifiers/verify_bench_regression.js --quick      # 3 files, 10 iters
//
// Exit 0 on pass; 1 on regression; 2 on setup error.

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/bench_baseline.json');

const args = process.argv.slice(2);
const UPDATE = args.includes('--update');
const QUICK  = args.includes('--quick');
const VERBOSE = args.includes('--verbose');
function arg(name, def) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
}
const ITERATIONS = parseInt(arg('--iterations', QUICK ? '10' : '30'), 10);

// Per-file and geo-mean regression thresholds. Expressed as RATIO (current /
// baseline); >1.0 = slower. Tuned so normal CI jitter (~5-7% on shared
// hosts) doesn't false-alarm, but a real 10-20% regression trips.
const PER_FILE_TOLERANCE = 1.10;  // 10% slower on any single file fails
const GEOMEAN_TOLERANCE  = 1.05;  //  5% slower across the whole set fails

// Curated file set \u2014 spans size decades and syntax categories. Pinned here
// (not in the baseline JSON) so a user can't accidentally shrink the set
// via --update. Adding a file requires editing this file; removing one too.
const FILES_FULL = [
  'bench/real_world/batch3/snabbdom.js',          // ~4 KB, minimal ES6
  'bench/real_world/batch2/preact.js',            //  ~8 KB, functional
  'bench/real_world/lodash.js',                   //  ~540 KB, uniform FP
  'bench/real_world/jquery.js',                   //  ~280 KB, legacy patterns
  'bench/real_world/d3.js',                       //  ~250 KB, chained calls
  'bench/real_world/react.dev.js',                //  ~90 KB, hooks-heavy
  'bench/real_world/react-dom.dev.js',            // ~1 MB, class-heavy
  'bench/real_world/antd.js',                     // ~6 MB, TS-ish real-world
  'bench/real_world/batch2/monaco.js',            // ~5 MB, deeply nested
  'bench/real_world/typescript.js',               // ~10 MB, largest file
];
const FILES_QUICK = [
  'bench/real_world/batch3/snabbdom.js',
  'bench/real_world/lodash.js',
  'bench/real_world/react-dom.dev.js',
];
const FILES = QUICK ? FILES_QUICK : FILES_FULL;

// -----------------------------------------------------------------------------
// Sanity
// -----------------------------------------------------------------------------
if (!fs.existsSync(KESSEL)) {
  console.error('bench_regression: missing ' + KESSEL + ' \u2014 run `task build` first');
  process.exit(2);
}
for (const rel of FILES) {
  const abs = path.join(ROOT, rel);
  if (!fs.existsSync(abs)) {
    console.error('bench_regression: missing corpus file ' + abs);
    process.exit(2);
  }
}

// -----------------------------------------------------------------------------
// Run the microbench. Output format (from src/main.odin): one line with
//   Min: <float> us
// among several summary lines. We only read Min for noise-resistance.
// -----------------------------------------------------------------------------
function measureMinUs(absPath) {
  const r = spawnSync(KESSEL, ['microbench', 'parse', absPath, '--iterations', String(ITERATIONS), '--ast-only'], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: 120_000,
  });
  if (r.status !== 0 || r.error) {
    throw new Error('kessel microbench failed on ' + absPath + ': ' +
                    (r.error ? r.error.message : 'exit ' + r.status) +
                    '\n' + (r.stderr || '').slice(0, 500));
  }
  // First line matching "Min:" is the number we want; spaces-then-unit.
  const lines = (r.stdout + r.stderr).split(/\r?\n/);
  for (const line of lines) {
    const m = line.match(/^\s*Min:\s*([0-9]+(?:\.[0-9]+)?)/);
    if (m) return parseFloat(m[1]);
  }
  throw new Error('kessel microbench produced no "Min:" line on ' + absPath +
                  '\nstdout tail: ' + r.stdout.slice(-500));
}

// -----------------------------------------------------------------------------
// Measure. Warm up with one throw-away run per file so the first
// measurement isn't biased by cold caches / filesystem noise.
// -----------------------------------------------------------------------------
console.log('bench_regression: iterations=' + ITERATIONS + ' files=' + FILES.length +
            (UPDATE ? ' mode=update' : ' mode=check') +
            (QUICK ? ' (quick)' : ''));

const measurements = {};  // rel -> min_us
for (const rel of FILES) {
  const abs = path.join(ROOT, rel);
  // Warmup \u2014 discard.
  try { measureMinUs(abs); } catch (e) { /* ignore \u2014 real pass below will surface it */ }
  const t = measureMinUs(abs);
  measurements[rel] = t;
  if (VERBOSE) console.log('  measured ' + rel + ': ' + t.toFixed(2) + ' us');
}

// -----------------------------------------------------------------------------
// Update mode \u2014 write baseline and exit.
// -----------------------------------------------------------------------------
if (UPDATE) {
  const baseline = {
    iterations: ITERATIONS,
    quick: QUICK,
    // Include a node+os hint so a human reviewing a baseline diff in PR can
    // tell if someone re-baselined on a different machine (which voids the
    // comparison entirely). This is informational; we don't gate on it.
    machine_hint: {
      node: process.versions.node,
      platform: process.platform,
      arch: process.arch,
      cpus: require('os').cpus().length,
    },
    files: measurements,
  };
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(baseline, null, 2) + '\n');
  console.log('baseline updated: ' + FILES.length + ' file(s) in ' + BASELINE_PATH);
  for (const rel of FILES) {
    console.log('  ' + rel.padEnd(45) + ' ' + measurements[rel].toFixed(2).padStart(10) + ' us');
  }
  process.exit(0);
}

// -----------------------------------------------------------------------------
// Check mode \u2014 compare against baseline.
// -----------------------------------------------------------------------------
if (!fs.existsSync(BASELINE_PATH)) {
  console.error('bench_regression: no baseline at ' + BASELINE_PATH +
                '. Run `node tests/verifiers/verify_bench_regression.js --update` first.');
  process.exit(2);
}
const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
if (baseline.iterations !== ITERATIONS) {
  console.error('bench_regression: iterations mismatch: baseline=' + baseline.iterations +
                ' current=' + ITERATIONS + '. Either run with --iterations ' +
                baseline.iterations + ' or recapture with --update.');
  process.exit(2);
}
if (baseline.quick !== QUICK) {
  console.error('bench_regression: quick-mode mismatch: baseline quick=' + baseline.quick +
                ' current quick=' + QUICK + '. They measure different file sets.');
  process.exit(2);
}

// Per-file comparison.
const ratios = [];
const regressions = [];
const improvements = [];
let widthName = 0;
for (const rel of FILES) widthName = Math.max(widthName, rel.length);

console.log('\n' + 'File'.padEnd(widthName) + '   baseline(us)    current(us)   ratio     verdict');
console.log('-'.repeat(widthName + 50));
for (const rel of FILES) {
  const cur = measurements[rel];
  const base = (baseline.files || {})[rel];
  if (base == null) {
    console.error('bench_regression: file ' + rel + ' missing from baseline. Run --update.');
    process.exit(2);
  }
  const ratio = cur / base;
  ratios.push(ratio);

  let verdict;
  if (ratio >= PER_FILE_TOLERANCE) {
    verdict = 'REGRESSION (>' + Math.round((PER_FILE_TOLERANCE - 1) * 100) + '%)';
    regressions.push({ rel, base, cur, ratio });
  } else if (ratio <= 1 / PER_FILE_TOLERANCE) {
    verdict = 'improvement';
    improvements.push({ rel, base, cur, ratio });
  } else {
    verdict = 'ok';
  }
  console.log(rel.padEnd(widthName) + '  ' +
              base.toFixed(2).padStart(10) + '     ' +
              cur.toFixed(2).padStart(10) + '   ' +
              ratio.toFixed(3).padStart(6) + '    ' +
              verdict);
}

// Geometric mean of ratios.
const logSum = ratios.reduce((a, r) => a + Math.log(r), 0);
const geoMean = Math.exp(logSum / ratios.length);

console.log('-'.repeat(widthName + 50));
console.log('geo-mean ratio: ' + geoMean.toFixed(3) +
            ' (tolerance ' + GEOMEAN_TOLERANCE.toFixed(3) + ')');
if (improvements.length > 0) {
  console.log('\nIMPROVEMENTS: ' + improvements.length + ' file(s) faster by >' +
              Math.round((PER_FILE_TOLERANCE - 1) * 100) + '%:');
  for (const r of improvements) {
    console.log('  ' + r.rel + ': ' + r.base.toFixed(1) + ' \u2192 ' + r.cur.toFixed(1) +
                ' us (' + (1/r.ratio).toFixed(2) + 'x faster)');
  }
  console.log('  Run with --update to lock these wins in.');
}

let failed = false;
if (regressions.length > 0) {
  console.log('\nREGRESSIONS: ' + regressions.length + ' file(s) slower by >' +
              Math.round((PER_FILE_TOLERANCE - 1) * 100) + '%:');
  for (const r of regressions) {
    console.log('  ' + r.rel + ': ' + r.base.toFixed(1) + ' \u2192 ' + r.cur.toFixed(1) +
                ' us (' + ((r.ratio - 1) * 100).toFixed(1) + '% slower)');
  }
  failed = true;
}
if (geoMean > GEOMEAN_TOLERANCE) {
  console.log('\nGEO-MEAN REGRESSION: ' + ((geoMean - 1) * 100).toFixed(1) +
              '% slower overall (tolerance ' +
              Math.round((GEOMEAN_TOLERANCE - 1) * 100) + '%)');
  failed = true;
}

if (failed) {
  console.log('\nFAILED. If this regression is intentional (e.g. a correctness fix\n' +
              'that trades off some speed), document the rationale and run with\n' +
              '--update to lock the new floor.');
  process.exit(1);
}
console.log('\nOK.');
process.exit(0);
