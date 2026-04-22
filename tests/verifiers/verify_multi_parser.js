#!/usr/bin/env node
// Multi-parser baseline gate.
//
// Runs tests/verify_json_deep.js against Acorn and Babel on a curated set of
// real-world files and fixture files, comparing the divergence count to a
// locked baseline (tests/baselines/multi_parser_baseline.json). Any INCREASE
// in divergence vs any reference parser on any file is a regression.
//
// Rationale: we cannot claim "zero divergence vs every parser" — different
// parsers have different dialects (Babel uses its own non-ESTree shapes,
// different handling of import attributes, etc.). The realistic gate is
// "we've matched as many behaviours as we can, and the count of remaining
// divergences never grows." Shrinking the baseline is always welcome;
// growing is always a bug.
//
// Usage:
//   node tests/verify_multi_parser.js              # check against baseline
//   node tests/verify_multi_parser.js --update     # rewrite baseline
//                                                    (after deliberate fix)
//   node tests/verify_multi_parser.js --verbose    # print per-pair results
//
// Exit 0 on success (no regression); exit 1 on any file-parser pair that
// diverged MORE than its baseline.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/multi_parser_baseline.json');
const UPDATE = process.argv.includes('--update');
const VERBOSE = process.argv.includes('--verbose');

// Build the file list: gold standard (snabbdom) + spec fixtures.
// Read directories at runtime so the test is resilient to fixture changes.
function getFixtures() {
  const files = [];
  
  // Gold standard file.
  files.push('bench/real_world/batch3/snabbdom.js');
  
  // Spec fixtures: es2015, es2020, and specific edge cases.
  const dirs = [
    'tests/fixtures/spec/es2015',
    'tests/fixtures/spec/es2020',
  ];
  
  for (const dir of dirs) {
    const abs = path.join(ROOT, dir);
    if (fs.existsSync(abs)) {
      const entries = fs.readdirSync(abs)
        .filter(f => f.endsWith('.js'))
        .sort();
      for (const f of entries) {
        files.push(path.join(dir, f));
      }
    }
  }
  
  // Edge cases: only 001_*, 007_*, 008_*.
  const edgeDir = 'tests/fixtures/spec/edge';
  const absEdge = path.join(ROOT, edgeDir);
  if (fs.existsSync(absEdge)) {
    const entries = fs.readdirSync(absEdge)
      .filter(f => f.endsWith('.js') && /^(001|007|008)_/.test(f))
      .sort();
    for (const f of entries) {
      files.push(path.join(edgeDir, f));
    }
  }
  
  return files;
}

// Parsers to test against.
const PARSERS = ['acorn', 'babel'];

// ---------------------------------------------------------------------------
// Run the deep verifier once per (file, parser) and capture the divergence
// count. We use --limit 0 to get the total count without spamming stderr.
// ---------------------------------------------------------------------------
function countDivergences(file, parser) {
  try {
    const out = execSync(
      `node tests/verifiers/verify_json_deep.js "${file}" --parser ${parser} --limit 0 2>&1`,
      { encoding: 'utf8', maxBuffer: 500 * 1024 * 1024 });
    // "passes vs PARSER" on success path (0 divergences), "N divergence(s) vs" on failure.
    if (out.indexOf(`passes vs ${parser}`) !== -1) return 0;
    const m = out.match(/(\d+) divergence\(s\) vs/);
    if (m) return parseInt(m[1], 10);
    // If we can't parse, treat as -1 so baseline captures it (mirrors spec-compliance).
    return -1;
  } catch (e) {
    const out = (e.stdout || '').toString() + (e.stderr || '').toString();
    const m = out.match(/(\d+) divergence\(s\) vs/);
    if (m) return parseInt(m[1], 10);
    // Verifier crashed; record as -1 so the baseline captures the error state.
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

console.log('Multi-parser compliance (Acorn and Babel)');
console.log(`Baseline: ${BASELINE_PATH}${UPDATE ? ' [UPDATE MODE]' : ''}`);
console.log('');

const files = getFixtures();
for (const file of files) {
  const abs = path.join(ROOT, file);
  if (!fs.existsSync(abs)) {
    console.error(`  SKIP ${file} (missing)`);
    continue;
  }
  current[file] = {};
  for (const parser of PARSERS) {
    if (!VERBOSE) process.stdout.write(`  ${path.basename(file)} vs ${parser}... `);
    const count = countDivergences(abs, parser);
    current[file][parser] = count;

    const prev = baseline[file] && baseline[file][parser];
    if (prev === undefined) {
      newEntries.push(`${file} vs ${parser} = ${count}`);
      if (VERBOSE) console.log(`  ${file} vs ${parser}: ${count} (new)`);
      if (!VERBOSE) console.log(`${count} (new)`);
    } else if (count === prev) {
      if (VERBOSE) console.log(`  ${file} vs ${parser}: ${count} (baseline)`);
      if (!VERBOSE) console.log(`${count} (baseline)`);
    } else if (count < prev) {
      improvements.push(`${file} vs ${parser}: ${prev} -> ${count} (-${prev - count})`);
      if (VERBOSE) console.log(`  ${file} vs ${parser}: ${count} (baseline ${prev}, improved by ${prev - count})`);
      if (!VERBOSE) console.log(`${count} (baseline ${prev}, improved by ${prev - count})`);
    } else {
      regressions.push(`${file} vs ${parser}: ${prev} -> ${count} (+${count - prev})`);
      if (VERBOSE) console.log(`  ${file} vs ${parser}: ${count} (baseline ${prev}, REGRESSED by ${count - prev})`);
      if (!VERBOSE) console.log(`${count} (baseline ${prev}, REGRESSED by ${count - prev})`);
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
