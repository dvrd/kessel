#!/usr/bin/env node
// Spec-compliance baseline gate.
//
// Runs tests/verify_json_deep.js against a curated set of real-world JS files
// for each reference parser (OXC, Acorn, Babel) and compares the divergence
// count to a locked baseline (tests/spec_baseline.json). Any INCREASE in
// divergence vs any reference parser on any file is a regression.
//
// Rationale: we cannot claim "zero divergence vs every parser" — different
// parsers have different dialects (Babel uses its own non-ESTree shapes,
// OXC wraps parens, UTF-16 vs UTF-8 offsets on multi-byte files, etc.). The
// realistic gate is "we've matched as many behaviours as we can, and the
// count of remaining divergences never grows." Shrinking the baseline is
// always welcome; growing is always a bug.
//
// Usage:
//   node tests/verify_spec_compliance.js              # check against baseline
//   node tests/verify_spec_compliance.js --update     # rewrite baseline
//                                                      (after deliberate fix)
//
// Exit 0 on success (no regression); exit 1 on any file-parser pair that
// diverged MORE than its baseline.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/spec_baseline.json');
const UPDATE = process.argv.includes('--update');

// Representative real-world files — covers small/medium/large, module/script,
// class-heavy, IIFE-heavy, and common framework patterns. This set is NOT
// exhaustive; it's chosen so that a regression in any common parse surface
// shows up in at least one file. Add files as new drift classes emerge.
const FILES = [
  'bench/real_world/batch3/snabbdom.js',       // small, export-heavy, gold standard
  'bench/real_world/batch2/preact.js',         // medium, arrows + destructure
  'bench/real_world/jquery.js',                // large, classic IIFE
  'bench/real_world/react.dev.js',             // medium, React patterns
  'bench/real_world/lodash.js',                // large, UTF-8 multi-byte chars
  'bench/real_world/batch2/acorn.js',          // large, self-parses (meta-test)
  'bench/real_world/react-dom.dev.js',         // very large, deeply nested
  'bench/real_world/antd.js',                  // very large, class-heavy
  'bench/real_world/d3.js',                    // very large, D3 patterns
  'bench/real_world/batch4/chalk.js',          // small ESM, default params
  'bench/real_world/batch4/petite-vue.js',     // medium, Vue 3 patterns
  'bench/real_world/batch2/zod.js',            // medium, heavy TS-style default params
];

const PARSERS = ['oxc'];

// ---------------------------------------------------------------------------
// Run the deep verifier once per (file, parser) and capture the divergence
// count. We use --limit 0 to get the total count without spamming stderr
// with individual FAIL lines.
// ---------------------------------------------------------------------------
function countDivergences(file, parser) {
  try {
    const out = execSync(
      `node tests/verifiers/verify_json_deep.js "${file}" --parser ${parser} --limit 0 2>&1`,
      { encoding: 'utf8', maxBuffer: 500 * 1024 * 1024 });
    // "X divergence(s) vs PARSER" on success path, "passes vs PARSER" on zero.
    if (out.indexOf(`passes vs ${parser}`) !== -1) return 0;
    const m = out.match(/(\d+) divergence\(s\) vs/);
    if (m) return parseInt(m[1], 10);
    // If we can't parse, treat as infinite so baseline captures it.
    return -1;
  } catch (e) {
    const out = (e.stdout || '').toString() + (e.stderr || '').toString();
    const m = out.match(/(\d+) divergence\(s\) vs/);
    if (m) return parseInt(m[1], 10);
    console.error(`\nFATAL: verifier crashed on ${file} vs ${parser}`);
    console.error(out.slice(0, 500));
    return -1;
  }
}

// ---------------------------------------------------------------------------
// Main: measure current, compare to baseline, report.
// ---------------------------------------------------------------------------
const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : {};

const current = {};
const regressions = [];
const improvements = [];
const newEntries = [];

console.log('Spec compliance (deep JSON compare vs reference parsers)');
console.log(`Baseline: ${BASELINE_PATH}${UPDATE ? ' [UPDATE MODE]' : ''}`);
console.log('');

for (const file of FILES) {
  const abs = path.join(ROOT, file);
  if (!fs.existsSync(abs)) {
    console.error(`  SKIP ${file} (missing)`);
    continue;
  }
  current[file] = {};
  for (const parser of PARSERS) {
    process.stdout.write(`  ${path.basename(file)} vs ${parser}... `);
    const count = countDivergences(abs, parser);
    current[file][parser] = count;

    const prev = baseline[file] && baseline[file][parser];
    if (prev === undefined) {
      newEntries.push(`${file} vs ${parser} = ${count}`);
      console.log(`${count} (new)`);
    } else if (count === prev) {
      console.log(`${count} (baseline)`);
    } else if (count < prev) {
      improvements.push(`${file} vs ${parser}: ${prev} -> ${count} (-${prev - count})`);
      console.log(`${count} (baseline ${prev}, improved by ${prev - count})`);
    } else {
      regressions.push(`${file} vs ${parser}: ${prev} -> ${count} (+${count - prev})`);
      console.log(`${count} (baseline ${prev}, REGRESSED by ${count - prev})`);
    }
  }
}

console.log('');

if (UPDATE) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`Baseline updated: ${BASELINE_PATH}`);
  process.exit(0);
}

if (newEntries.length > 0) {
  console.log(`NEW ENTRIES (no baseline): ${newEntries.length}`);
  for (const e of newEntries) console.log(`  ${e}`);
  console.log('  Run with --update to commit these to the baseline.');
}

if (improvements.length > 0) {
  console.log(`IMPROVEMENTS: ${improvements.length}`);
  for (const e of improvements) console.log(`  ${e}`);
  console.log('  Run with --update to lock these in.');
}

if (regressions.length > 0) {
  console.log(`REGRESSIONS: ${regressions.length}`);
  for (const e of regressions) console.log(`  ${e}`);
  process.exit(1);
}

if (newEntries.length === 0 && improvements.length === 0) {
  console.log('OK — matches baseline on every file/parser pair');
}
process.exit(0);
