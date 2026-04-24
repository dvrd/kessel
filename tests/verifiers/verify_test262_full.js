#!/usr/bin/env node
// Test262 full-corpus driver.
//
// Walks <test262>/test/**/*.js, parses each fixture's YAML front-matter
// (flags, negative.phase, features, includes), determines the correct
// parse modes (script / module / strict), invokes kessel, and aggregates
// pass / fail per top-level directory.
//
// The driver does NOT run the code — it's a parse-only gate. Test262
// entries whose negative.phase is "parse" or "early" are "must reject";
// everything else is "must accept syntactically". `resolution` / `runtime`
// negatives are treated as "must accept" for the syntax gate.
//
// Usage:
//   node tests/verifiers/verify_test262_full.js --test262-dir /path --binary bin/kessel
//
// Flags:
//   --test262-dir  <path>   Root of the test262 checkout.
//   --binary       <path>   Path to the kessel binary.
//   --timeout      <sec>    Per-invocation timeout (default 5).
//   --filter       <str>    Substring filter on relative path.
//   --json-out     <path>   Machine-readable summary output.
//   --verbose               Per-file logging.
//   --all-failures          Record every failure (not just the first 50) in
//                           the JSON summary, plus a per-subcategory
//                           (top-two-level) breakdown. Used for triage.

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const args = parseArgs(process.argv.slice(2));
if (!args.test262Dir || !args.binary) {
  console.error('Usage: verify_test262_full.js --test262-dir <path> --binary <path> [--filter s] [--timeout n] [--json-out p]');
  process.exit(2);
}

const TEST_ROOT = path.join(args.test262Dir, 'test');
const HARNESS_RE = /^(FIXTURE_LOCK|_fixture\.js$|support\/|harness\/)/;

// Discover every .js under test/ (skip harness/, staging/ tests we don't
// care about for syntax gating, and _FIXTURE files).
function discover(dir, rel = '') {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name.startsWith('.')) continue;
    const abs = path.join(dir, entry.name);
    const relNext = rel ? `${rel}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      if (entry.name === 'intl402') continue;                 // ICU-dependent
      out.push(...discover(abs, relNext));
      continue;
    }
    if (!entry.name.endsWith('.js')) continue;
    if (entry.name.endsWith('_FIXTURE.js')) continue;
    if (HARNESS_RE.test(relNext)) continue;
    if (args.filter && !relNext.includes(args.filter)) continue;
    out.push({ abs, rel: relNext });
  }
  return out;
}

// Test262 fixtures use a YAML-style comment block:
//   /*---
//   flags: [onlyStrict, module]
//   negative:
//     phase: parse
//     type: SyntaxError
//   ---*/
function parseFrontmatter(source) {
  const start = source.indexOf('/*---');
  if (start < 0) return {};
  const end = source.indexOf('---*/', start);
  if (end < 0) return {};
  const block = source.slice(start + 5, end);
  const meta = { flags: [], features: [], negative: null };
  const flagsMatch = block.match(/flags:\s*\[([^\]]*)\]/);
  if (flagsMatch) {
    meta.flags = flagsMatch[1].split(',').map(s => s.trim()).filter(Boolean);
  }
  const featuresMatch = block.match(/features:\s*\[([^\]]*)\]/);
  if (featuresMatch) {
    meta.features = featuresMatch[1].split(',').map(s => s.trim()).filter(Boolean);
  }
  const negMatch = block.match(/negative:\s*[\n\r]+\s+phase:\s*(\w+)\s*[\n\r]+\s+type:\s*(\w+)/);
  if (negMatch) {
    meta.negative = { phase: negMatch[1], type: negMatch[2] };
  } else if (/negative:/.test(block)) {
    // Fallback for single-line form
    const shortMatch = block.match(/phase:\s*(\w+)/);
    const typeMatch  = block.match(/type:\s*(\w+)/);
    if (shortMatch) meta.negative = { phase: shortMatch[1], type: typeMatch ? typeMatch[1] : 'SyntaxError' };
  }
  return meta;
}

function run(fixture, meta) {
  const mode = meta.flags.includes('module') ? 'module' :
               meta.flags.includes('raw')    ? 'script' :
                                               'script';
  const argsList = ['parse', fixture.abs, `--source-type=${mode}`];
  // Test262 `flags: [onlyStrict]` means the fixture must be parsed as
  // strict-mode code, without the fixture itself containing a
  // "use strict" directive. Wire this through the parser's
  // --force-strict flag so strict-only early errors (LegacyOctalEscape,
  // for-in initializer, eval/arguments binding, …) fire on this corpus.
  if (meta.flags.includes('onlyStrict')) {
    argsList.push('--force-strict');
  }
  const r = spawnSync(args.binary, argsList, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: args.timeout * 1000,
  });
  const combined = `${r.stdout || ''}${r.stderr || ''}`;
  const parseErrsMatch = combined.match(/Parse errors:\s*(\d+)/);
  const parseErrs = parseErrsMatch ? parseInt(parseErrsMatch[1], 10) : 0;
  const crashed = r.status !== 0 && r.status !== 1;
  return {
    exit: r.status,
    parseErrs,
    crashed,
    timeout: r.error && r.error.code === 'ETIMEDOUT',
  };
}

function classify(fixture, meta, result) {
  if (result.timeout) return 'timeout';
  if (result.crashed) return 'crash';
  const isParseNeg = meta.negative && (meta.negative.phase === 'parse' || meta.negative.phase === 'early');
  if (isParseNeg) {
    return result.parseErrs > 0 ? 'pass' : 'accepted-should-reject';
  }
  return result.parseErrs === 0 ? 'pass' : 'rejected-should-accept';
}

// ---------------------------------------------------------------------------

const fixtures = discover(TEST_ROOT);
console.error(`Discovered ${fixtures.length} fixtures under ${TEST_ROOT}`);

const counts = {
  pass: 0,
  'accepted-should-reject': 0,
  'rejected-should-accept': 0,
  crash: 0,
  timeout: 0,
};
const perDir = new Map();
const perSubdir = new Map();
const failures = [];
const failureCap = args.allFailures ? Infinity : 50;

for (const fixture of fixtures) {
  const source = fs.readFileSync(fixture.abs, 'utf8');
  const meta = parseFrontmatter(source);
  const res = run(fixture, meta);
  const verdict = classify(fixture, meta, res);
  counts[verdict]++;
  const parts = fixture.rel.split('/');
  const dir = parts[0];
  const subdir = parts.slice(0, 2).join('/');
  const dc = perDir.get(dir) || { pass: 0, fail: 0, crash: 0, timeout: 0 };
  if (verdict === 'pass') dc.pass++;
  else if (verdict === 'crash') dc.crash++;
  else if (verdict === 'timeout') dc.timeout++;
  else dc.fail++;
  perDir.set(dir, dc);
  if (verdict !== 'pass') {
    const sc = perSubdir.get(subdir) || { pass: 0, fail: 0, crash: 0, timeout: 0,
                                          'accepted-should-reject': 0,
                                          'rejected-should-accept': 0 };
    sc.fail++;
    if (verdict === 'crash') sc.crash++;
    else if (verdict === 'timeout') sc.timeout++;
    else sc[verdict]++;
    perSubdir.set(subdir, sc);
    if (failures.length < failureCap) {
      failures.push({ file: fixture.rel, verdict });
    }
  }
  if (args.verbose && verdict !== 'pass') {
    console.error(`  ${verdict.padEnd(22)} ${fixture.rel}`);
  }
}

// ---------------------------------------------------------------------------

const total = fixtures.length;
const sumOK  = counts.pass;
const rate   = total > 0 ? ((sumOK / total) * 100).toFixed(2) : '0.00';

console.log('');
console.log('Test262 full-corpus results:');
console.log(`  total:                    ${total}`);
console.log(`  pass:                     ${counts.pass}`);
console.log(`  accepted-should-reject:   ${counts['accepted-should-reject']}`);
console.log(`  rejected-should-accept:   ${counts['rejected-should-accept']}`);
console.log(`  crash:                    ${counts.crash}`);
console.log(`  timeout:                  ${counts.timeout}`);
console.log(`  pass rate:                ${rate}%`);
console.log('');
console.log('Per top-level directory:');
const sortedDirs = [...perDir.keys()].sort();
for (const d of sortedDirs) {
  const c = perDir.get(d);
  const t = c.pass + c.fail + c.crash + c.timeout;
  const r2 = t > 0 ? ((c.pass / t) * 100).toFixed(1) : '0.0';
  console.log(`  ${d.padEnd(22)} ${c.pass}/${t}   (${r2}%)   fail=${c.fail} crash=${c.crash} timeout=${c.timeout}`);
}

if (args.jsonOut) {
  const payload = {
    total, counts,
    perDir: Object.fromEntries(perDir),
    perSubdir: Object.fromEntries(
      [...perSubdir.entries()].sort((a, b) => b[1].fail - a[1].fail)),
    sample_failures: args.allFailures ? failures.slice(0, 50) : failures,
    all_failures: args.allFailures ? failures : undefined,
    rate: parseFloat(rate),
    generated_at: new Date().toISOString(),
  };
  fs.writeFileSync(args.jsonOut, JSON.stringify(payload, null, 2));
  console.error(`Wrote JSON summary to ${args.jsonOut}`);
}

// Exit non-zero on crashes only; fail/mismatch is expected on first run.
// The baseline gate (verify_test262_baseline.js) will decide what's a
// regression.
process.exit(counts.crash > 0 ? 1 : 0);

// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const out = { timeout: 5, verbose: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--test262-dir') out.test262Dir = argv[++i];
    else if (a === '--binary') out.binary = argv[++i];
    else if (a === '--timeout') out.timeout = parseInt(argv[++i], 10);
    else if (a === '--filter') out.filter = argv[++i];
    else if (a === '--json-out') out.jsonOut = argv[++i];
    else if (a === '--verbose') out.verbose = true;
    else if (a === '--all-failures') out.allFailures = true;
  }
  return out;
}
