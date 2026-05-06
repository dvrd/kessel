#!/usr/bin/env node
// Test262 subset verifier.
//
// Why this exists:
//   `tests/runners/run_test262.sh` tells us "66/66 pass" but it only inspects
//   exit codes, so it silently conflates three different things:
//     1. a positive test that parsed cleanly (correct),
//     2. a negative test that Kessel rejected (correct),
//     3. a negative test that Kessel accepted (SPEC VIOLATION).
//   This verifier reads `tests/test262_manifest.json` and each file's Test262
//   front-matter, then classifies per-file outcomes and reports pass rate by
//   grammar category. A flat "66/66" becomes a per-category signal that tells
//   us which grammar surfaces are actually covered.
//
// Classification per fixture:
//   - expected outcome is derived from the Test262 front-matter:
//     - a `negative:` block with `phase: parse` or `phase: early` means the
//       parser MUST reject the program,
//     - anything else (including `phase: resolution`/`runtime`, or no
//       `negative:` block at all) means the parser MUST accept the program.
//   - rejection is detected via the same two signals used by
//     `verify_negative.js`: non-zero exit OR a `Parse errors: N` line with
//     N >= 1.
//   - verdict:
//     - pass              — the expected outcome was observed,
//     - known_fail        — the expected outcome was NOT observed, but the
//                           fixture is listed in
//                           `tests/baselines/test262_known_failures.txt`,
//     - unexpected_fail   — the expected outcome was NOT observed and the
//                           fixture is NOT in the known-failures list.
//
// Baseline format (`tests/baselines/test262_subset_baseline.json`):
//   { "<category>/<file.js>": "pass" | "known_fail" | "unexpected_fail", ... }
//   We track per-file state rather than only per-category counts so regressions
//   are reported with the specific file that moved. Per-category counts are
//   derived on the fly for the human-facing summary.
//
// Usage:
//   node tests/verifiers/verify_test262_subset.js             # check vs baseline
//   node tests/verifiers/verify_test262_subset.js --update    # relock baseline
//   node tests/verifiers/verify_test262_subset.js --strict    # fail on any
//                                                             # known_fail or
//                                                             # unexpected_fail
//   node tests/verifiers/verify_test262_subset.js --verbose   # per-file outcome
//   node tests/verifiers/verify_test262_subset.js --category lexical   # filter
//
// Exit 0 on match/improvement; 1 on regression (per-file or per-category);
// 2 on environment/setup errors (missing binary, missing manifest, etc).

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const SUBSET_DIR = path.join(ROOT, 'tests/test262');
const MANIFEST_PATH = path.join(ROOT, 'tests/test262_manifest.json');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/test262_subset_baseline.json');
const KNOWN_FAILURES_PATH = path.join(
  ROOT,
  'tests/baselines/test262_known_failures.txt',
);

const UPDATE = process.argv.includes('--update');
const STRICT = process.argv.includes('--strict');
const VERBOSE = process.argv.includes('--verbose');

// Optional category filter: `--category lexical` or `--category=lexical`.
// Filtering only changes which fixtures get executed and reported; baseline
// checks are still applied to the filtered set against the same baseline file.
function readCategoryFilter() {
  for (let i = 2; i < process.argv.length; i++) {
    const arg = process.argv[i];
    if (arg === '--category' && i + 1 < process.argv.length) {
      return process.argv[i + 1];
    }
    if (arg.startsWith('--category=')) {
      return arg.slice('--category='.length);
    }
  }
  return null;
}

const CATEGORY_FILTER = readCategoryFilter();

function die(code, msg) {
  console.error(msg);
  process.exit(code);
}

function readManifest() {
  if (!fs.existsSync(MANIFEST_PATH)) {
    die(2, `Error: manifest not found at ${MANIFEST_PATH}`);
  }
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
  } catch (err) {
    die(2, `Error: failed to parse ${MANIFEST_PATH}: ${err.message}`);
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    die(2, `Error: manifest ${MANIFEST_PATH} must be a top-level object`);
  }
  for (const [category, files] of Object.entries(raw)) {
    if (!Array.isArray(files)) {
      die(2, `Error: manifest category "${category}" must be an array of filenames`);
    }
    for (const file of files) {
      if (typeof file !== 'string') {
        die(2, `Error: manifest category "${category}" has a non-string entry`);
      }
    }
  }
  return raw;
}

function readKnownFailures() {
  // Each non-comment line is a bare filename (no path). Comments use `#`.
  if (!fs.existsSync(KNOWN_FAILURES_PATH)) return new Set();
  const out = new Set();
  const lines = fs.readFileSync(KNOWN_FAILURES_PATH, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const hash = trimmed.indexOf('#');
    const entry = hash === -1 ? trimmed : trimmed.slice(0, hash).trim();
    if (entry) out.add(entry);
  }
  return out;
}

// Extract the Test262 front-matter block `/*--- ... ---*/` if present.
// Returns the inner text (without the `---` markers) or null when absent.
function extractFrontMatter(source) {
  const m = source.match(/\/\*---([\s\S]*?)---\*\//);
  return m ? m[1] : null;
}

// Decide whether the fixture's front-matter declares a parse-time negative
// test. A `negative:` block with `phase: parse` or `phase: early` means the
// parser MUST reject. Any other `phase:` (`resolution`, `runtime`) means the
// failure happens after parsing, so the parser MUST still accept the program.
// No `negative:` block at all means it's a positive test.
function expectsReject(frontMatter) {
  if (!frontMatter) return false;
  const lines = frontMatter.split(/\r?\n/);
  let inNegative = false;
  let negativeIndent = -1;
  let phase = null;

  for (const raw of lines) {
    // Strip trailing whitespace; keep leading whitespace to track indentation.
    const line = raw.replace(/\s+$/u, '');
    if (line.length === 0) continue;

    const indent = line.length - line.trimStart().length;
    const body = line.trimStart();

    if (!inNegative) {
      if (body === 'negative:' || body.startsWith('negative:')) {
        inNegative = true;
        negativeIndent = indent;
      }
      continue;
    }

    // We are inside a `negative:` block. The block ends when a line at the
    // same or shallower indentation appears (a sibling key).
    if (indent <= negativeIndent) {
      inNegative = false;
      // Re-check this line as a top-level key.
      if (body === 'negative:' || body.startsWith('negative:')) {
        inNegative = true;
        negativeIndent = indent;
      }
      continue;
    }

    const phaseMatch = body.match(/^phase:\s*(\S+)/);
    if (phaseMatch) {
      phase = phaseMatch[1].trim();
    }
  }

  if (!inNegative && phase === null) {
    // `negative:` block was never seen, or seen with no phase.
    // If the block existed at all, default phase is absent → treat as
    // positive. Only explicit parse/early phases count as expects_reject.
    return false;
  }
  if (phase === 'parse' || phase === 'early') return true;
  return false;
}

// Same rejection criterion used in `verify_negative.js`: exit != 0 OR a
// `Parse errors: N` marker with N >= 1. Keeping this consistent means the two
// gates agree on what "rejected" means.
//
// `--show-semantic-errors` opts into pass 3 (the semantic checker in
// src/checker.odin). Test262 fixtures with `phase: parse` cover Early
// Errors that ECMA-262 considers part of parsing but that kessel (like
// OXC) implements in a separate post-parse walk. Without the flag,
// `kessel parse` stays parser-only and matches OXC's parseSync API.
function runKessel(abs) {
  const r = spawnSync(KESSEL, ['parse', abs, '--show-semantic-errors'], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: 10_000,
  });
  const combined = (r.stdout || '') + (r.stderr || '');
  if (r.status === null) {
    return { rejected: true, reason: 'timeout or signal' };
  }
  if (r.status !== 0) {
    return { rejected: true, reason: `exit=${r.status}` };
  }
  const m = combined.match(/Parse errors\s*(?:\((\d+)\)|:\s*(\d+))/);
  if (m) {
    const n = parseInt(m[1] || m[2], 10);
    if (n >= 1) return { rejected: true, reason: `${n} parse error(s)` };
  }
  return { rejected: false, reason: 'parsed cleanly' };
}

function classify(fixture, knownFailures) {
  const source = fs.readFileSync(fixture.abs, 'utf8');
  const fm = extractFrontMatter(source);
  const expectReject = expectsReject(fm);
  const run = runKessel(fixture.abs);
  const correct = expectReject ? run.rejected : !run.rejected;

  if (correct) {
    return {
      status: 'pass',
      reason: expectReject
        ? `negative test correctly rejected (${run.reason})`
        : `positive test parsed cleanly`,
      expectReject,
    };
  }

  // Wrong outcome. Was it pre-declared as a known failure?
  if (knownFailures.has(fixture.name)) {
    return {
      status: 'known_fail',
      reason: expectReject
        ? 'negative test wrongly accepted (known bug)'
        : 'positive test wrongly rejected (known bug)',
      expectReject,
    };
  }
  return {
    status: 'unexpected_fail',
    reason: expectReject
      ? `negative test wrongly accepted (${run.reason})`
      : `positive test wrongly rejected (${run.reason})`,
    expectReject,
  };
}

function summarize(current, manifest) {
  // Per-category {pass, known_fail, unexpected_fail, total}, plus overall.
  const byCategory = {};
  for (const category of Object.keys(manifest)) {
    byCategory[category] = { pass: 0, known_fail: 0, unexpected_fail: 0, total: 0 };
  }
  const overall = { pass: 0, known_fail: 0, unexpected_fail: 0, total: 0 };

  for (const [key, status] of Object.entries(current)) {
    const slash = key.indexOf('/');
    if (slash === -1) continue;
    const category = key.slice(0, slash);
    if (!byCategory[category]) {
      byCategory[category] = { pass: 0, known_fail: 0, unexpected_fail: 0, total: 0 };
    }
    byCategory[category][status]++;
    byCategory[category].total++;
    overall[status]++;
    overall.total++;
  }
  return { byCategory, overall };
}

function percent(pass, total) {
  // A total of 0 means the category has no files (or --category filtered it
  // out). Reporting `0%` in that case is misleading — `n/a` says "nothing to
  // measure here" without inflating the look of failure.
  if (total === 0) return 'n/a';
  return `${Math.round((pass * 1000) / total) / 10}%`;
}

function printReport(current, manifest) {
  const { byCategory, overall } = summarize(current, manifest);
  const categories = Object.keys(manifest);
  const pad = Math.max(...categories.map((c) => c.length), 'overall'.length);

  console.log('');
  console.log('Test262 subset status by category:');
  for (const category of categories) {
    const c = byCategory[category] || { pass: 0, known_fail: 0, unexpected_fail: 0, total: 0 };
    const rate = percent(c.pass, c.total);
    console.log(
      `  ${category.padEnd(pad)}  pass=${c.pass}/${c.total}  known_fail=${c.known_fail}  unexpected_fail=${c.unexpected_fail}  rate=${rate}`,
    );
  }
  console.log('');
  console.log(
    `  ${'overall'.padEnd(pad)}  pass=${overall.pass}/${overall.total}  known_fail=${overall.known_fail}  unexpected_fail=${overall.unexpected_fail}  rate=${percent(overall.pass, overall.total)}`,
  );
  return { byCategory, overall };
}

function main() {
  if (!fs.existsSync(KESSEL)) {
    die(2, `Error: kessel binary not found at ${KESSEL}`);
  }
  if (!fs.existsSync(SUBSET_DIR)) {
    die(2, `Error: subset directory not found at ${SUBSET_DIR}`);
  }

  const manifest = readManifest();
  const knownFailures = readKnownFailures();

  // Sanity: every file listed in the manifest must exist on disk. This is a
  // hard error because the manifest is the source of truth for what we claim
  // to cover; a stale entry silently shrinks coverage.
  const manifestFiles = new Set();
  const missing = [];
  for (const [category, files] of Object.entries(manifest)) {
    for (const name of files) {
      manifestFiles.add(name);
      if (!fs.existsSync(path.join(SUBSET_DIR, name))) {
        missing.push(`${category}/${name}`);
      }
    }
  }
  if (missing.length > 0) {
    console.error('Error: manifest references files that are missing on disk:');
    for (const m of missing) console.error(`  ${m}`);
    process.exit(2);
  }

  // Sanity: flag files on disk that the manifest doesn't know about. These
  // don't block the gate — they just get reported so the manifest can be
  // updated. Subset intent lives in the manifest, not the directory.
  const diskFiles = fs.readdirSync(SUBSET_DIR)
    .filter((name) => name.endsWith('.js'))
    .sort();
  const orphans = diskFiles.filter((name) => !manifestFiles.has(name));
  if (orphans.length > 0) {
    console.log('NOTE — files on disk not listed in manifest:');
    for (const o of orphans) console.log(`  tests/test262/${o}`);
  }

  // Sanity: stale known-failure entries (file removed or renamed).
  const staleKnown = [...knownFailures].filter((name) => !manifestFiles.has(name));
  if (staleKnown.length > 0) {
    console.log('NOTE — known-failure entries for files no longer in the manifest:');
    for (const s of staleKnown) console.log(`  ${s}`);
  }

  // Classify each fixture under each category. Keyed by `<category>/<file>`
  // so the baseline is category-aware.
  const current = {};
  const categories = CATEGORY_FILTER
    ? [CATEGORY_FILTER]
    : Object.keys(manifest);
  if (CATEGORY_FILTER && !manifest[CATEGORY_FILTER]) {
    die(2, `Error: --category "${CATEGORY_FILTER}" is not in the manifest`);
  }

  for (const category of categories) {
    for (const name of manifest[category]) {
      const fixture = {
        name,
        abs: path.join(SUBSET_DIR, name),
        category,
      };
      const verdict = classify(fixture, knownFailures);
      const key = `${category}/${name}`;
      current[key] = verdict.status;
      if (VERBOSE) {
        const mark = verdict.status === 'pass' ? 'OK   '
          : verdict.status === 'known_fail' ? 'KNOWN'
          : 'FAIL ';
        console.log(`  ${mark} ${key} — ${verdict.reason}`);
      }
    }
  }

  const { byCategory, overall } = printReport(current, manifest);

  // --strict mode: every fixture must pass outright.
  if (STRICT) {
    if (overall.known_fail > 0 || overall.unexpected_fail > 0) {
      console.log('');
      console.log('STRICT mode — every Test262 subset fixture must pass.');
      for (const [k, v] of Object.entries(current)) {
        if (v !== 'pass') console.log(`  ${v.toUpperCase()}: ${k}`);
      }
      process.exit(1);
    }
    console.log('\nSTRICT mode OK — every fixture passed.');
    process.exit(0);
  }

  // Baseline mode: compare per-file AND per-category snapshots.
  const hasBaseline = fs.existsSync(BASELINE_PATH);
  const baseline = hasBaseline
    ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
    : null;

  if (UPDATE || !hasBaseline) {
    const snapshot = {
      per_file: current,
      by_category: byCategory,
      overall,
    };
    fs.writeFileSync(BASELINE_PATH, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`\nBaseline ${hasBaseline ? 'updated' : 'created'}: ${BASELINE_PATH}`);
    if (overall.known_fail > 0) {
      console.log(`NOTE — ${overall.known_fail} fixture(s) baselined as known_fail; these are tracked bugs.`);
    }
    if (overall.unexpected_fail > 0) {
      console.log(`NOTE — ${overall.unexpected_fail} fixture(s) baselined as unexpected_fail; consider moving them to ${path.relative(ROOT, KNOWN_FAILURES_PATH)}.`);
    }
    process.exit(0);
  }

  // Older baselines may have lived as a flat per-file map. Accept both shapes.
  const prevPerFile = baseline.per_file || baseline;
  const prevByCategory = baseline.by_category || null;

  const regressions = [];
  const improvements = [];
  const newFixtures = [];
  for (const [key, now] of Object.entries(current)) {
    const prev = prevPerFile[key];
    if (prev === undefined) {
      newFixtures.push(`${key} (${now})`);
      continue;
    }
    if (prev === now) continue;
    if (prev === 'pass' && now !== 'pass') {
      regressions.push(`${key}: pass -> ${now}`);
      continue;
    }
    if (now === 'pass') {
      improvements.push(`${key}: ${prev} -> pass`);
      continue;
    }
    if (prev === 'known_fail' && now === 'unexpected_fail') {
      regressions.push(`${key}: known_fail -> unexpected_fail`);
      continue;
    }
    if (prev === 'unexpected_fail' && now === 'known_fail') {
      improvements.push(`${key}: unexpected_fail -> known_fail (added to known-failures)`);
      continue;
    }
  }

  // Removed: present in baseline, absent now. When --category filters the run,
  // don't flag files outside the filter as removed.
  const removed = Object.keys(prevPerFile)
    .filter((k) => !(k in current))
    .filter((k) => !CATEGORY_FILTER || k.startsWith(`${CATEGORY_FILTER}/`));

  // Per-category count regressions. This catches cases where a swap keeps the
  // per-file count of regressions+improvements balanced but still drops a
  // category's pass count (e.g. one fixture fixed, two fixtures broken across
  // different statuses).
  const categoryRegressions = [];
  if (prevByCategory) {
    for (const category of Object.keys(byCategory)) {
      if (CATEGORY_FILTER && category !== CATEGORY_FILTER) continue;
      const prev = prevByCategory[category];
      const now = byCategory[category];
      if (!prev) continue;
      if (now.pass < prev.pass) {
        categoryRegressions.push(
          `${category}: pass ${prev.pass} -> ${now.pass} (total ${prev.total} -> ${now.total})`,
        );
      }
    }
    if (!CATEGORY_FILTER) {
      const prevOverall = baseline.overall;
      if (prevOverall && overall.pass < prevOverall.pass) {
        categoryRegressions.push(
          `overall: pass ${prevOverall.pass} -> ${overall.pass} (total ${prevOverall.total} -> ${overall.total})`,
        );
      }
    }
  }

  console.log('');
  if (newFixtures.length > 0) {
    console.log(`NEW fixtures (not in baseline): ${newFixtures.length}`);
    for (const n of newFixtures) console.log(`    ${n}`);
  }
  if (removed.length > 0) {
    console.log(`REMOVED from subset: ${removed.length}`);
    for (const r of removed) console.log(`    ${r}`);
  }
  if (improvements.length > 0) {
    console.log(`IMPROVEMENTS: ${improvements.length}`);
    for (const i of improvements) console.log(`    ${i}`);
  }
  if (regressions.length > 0) {
    console.log(`REGRESSIONS (per-file): ${regressions.length}`);
    for (const r of regressions) console.log(`    ${r}`);
  }
  if (categoryRegressions.length > 0) {
    console.log(`REGRESSIONS (per-category totals): ${categoryRegressions.length}`);
    for (const r of categoryRegressions) console.log(`    ${r}`);
  }

  if (regressions.length > 0 || categoryRegressions.length > 0) {
    console.log('\nFAIL — run with --update after confirming the regressions are intentional.');
    process.exit(1);
  }
  if (improvements.length > 0 || newFixtures.length > 0 || removed.length > 0) {
    console.log('\nOK (with improvements/new/removed) — run with --update to relock.');
    process.exit(0);
  }
  console.log('\nOK — matches baseline exactly.');
  process.exit(0);
}

main();
