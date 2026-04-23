#!/usr/bin/env node
// Ambiguity surface verifier.
//
// This gate separates JS/TS/JSX boundary cases from the rest of the spec
// fixtures because these files are useful in two different ways:
//   1. their pretty-printed Kessel output is a stable golden fixture,
//   2. their deep compare against OXC tells us which ambiguity edges are still
//      product gaps.
//
// The known-failure list is intentional documentation, not a skip list.
// Every fixture is still exercised; the list only explains the current status.
//
// Usage:
//   node tests/verifiers/verify_ambiguity.js            # check against baseline
//   node tests/verifiers/verify_ambiguity.js --update   # relock baseline
//   node tests/verifiers/verify_ambiguity.js --strict    # fail on any non-pass
//   node tests/verifiers/verify_ambiguity.js --verbose   # per-fixture status

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const FIXTURE_DIR = path.join(ROOT, 'tests/fixtures/spec/ambiguity');
const EXPECTED_DIR = path.join(ROOT, 'tests/expected/spec/ambiguity');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/ambiguity_baseline.json');
const KNOWN_FAILURES_PATH = path.join(
  ROOT,
  'tests/baselines/ambiguity_known_failures.txt',
);

const UPDATE = process.argv.includes('--update');
const STRICT = process.argv.includes('--strict');
const VERBOSE = process.argv.includes('--verbose');

const LANG_BY_FIXTURE = {
  '001_ts_assertion_vs_jsx_simple.js': 'ts',
  '002_ts_assertion_vs_jsx_paren.js': 'ts',
  '003_generic_call_vs_relational.js': 'ts',
  '004_generic_arrow_vs_relational.js': 'ts',
  '005_jsx_attribute_nested_element.js': 'jsx',
  '006_jsx_expression_nested_generic_like.js': 'jsx',
  '007_type_arguments_call_chain.js': 'ts',
  '008_less_than_binary_not_generic.js': 'js',
  '009_jsx_fragment_vs_type_context.js': 'jsx',
  '010_import_type_vs_import_call.js': 'ts',
};

function listFixtures() {
  return fs.readdirSync(FIXTURE_DIR)
    .filter((name) => name.endsWith('.js'))
    .sort()
    .map((name) => ({
      name,
      rel: path.join('tests/fixtures/spec/ambiguity', name),
      abs: path.join(FIXTURE_DIR, name),
    }));
}

function readKnownFailures() {
  if (!fs.existsSync(KNOWN_FAILURES_PATH)) {
    return new Set();
  }

  const out = new Set();
  const lines = fs.readFileSync(KNOWN_FAILURES_PATH, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const hash = trimmed.indexOf('#');
    const entry = hash === -1 ? trimmed : trimmed.slice(0, hash).trim();
    if (!entry) continue;
    if (entry.startsWith('tests/fixtures/')) {
      out.add(entry);
      continue;
    }
    out.add(path.join('tests/fixtures', entry));
  }
  return out;
}

function stripStatistics(text) {
  const marker = text.indexOf('--- Statistics ---');
  if (marker === -1) return text.trimEnd();
  return text.slice(0, marker).trimEnd();
}

function normalizeFixtureOutput(text) {
  return stripStatistics(text).replace(/\s+$/u, '');
}

function fixtureLanguage(rel) {
  const name = path.basename(rel);
  return LANG_BY_FIXTURE[name] || 'js';
}

function parseFixture(fixture) {
  const lang = fixtureLanguage(fixture.rel);
  const args = ['parse'];
  if (lang === 'ts') args.push('--lang=ts');
  if (lang === 'jsx') args.push('--lang=jsx');
  args.push(fixture.abs);

  const result = spawnSync(KESSEL, args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: 10_000,
  });
  const combined = `${result.stdout || ''}${result.stderr || ''}`;
  const output = normalizeFixtureOutput(combined);
  const parseErrors = combined.match(/Parse errors\s*(?:\((\d+)\)|:\s*(\d+))/);
  const errorCount = parseErrors ? parseInt(parseErrors[1] || parseErrors[2], 10) : 0;
  return {
    lang,
    output,
    status: result.status,
    crashed: result.status !== 0,
    parseErrors: errorCount,
  };
}

function compareExpected(fixture, output) {
  const expectedPath = path.join(EXPECTED_DIR, `${path.basename(fixture.rel, '.js')}.txt`);
  if (!fs.existsSync(expectedPath)) {
    return { ok: false, reason: 'missing expected file', expectedPath };
  }

  const expected = normalizeFixtureOutput(fs.readFileSync(expectedPath, 'utf8'));
  if (output !== expected) {
    return { ok: false, reason: 'output mismatch', expectedPath };
  }
  return { ok: true, expectedPath };
}

function compareDeep(fixture) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ambiguity-'));
  const ext = fixtureLanguage(fixture.rel) === 'jsx' ? '.jsx'
    : fixtureLanguage(fixture.rel) === 'ts' ? '.ts'
    : '.js';
  const tempPath = path.join(tempDir, `${path.basename(fixture.rel, '.js')}${ext}`);
  fs.copyFileSync(fixture.abs, tempPath);

  try {
    const output = execSync(
      `node tests/verifiers/verify_json_deep.js "${tempPath}" --parser oxc --limit 1`,
      { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 },
    );
    return { ok: true, output };
  } catch (error) {
    return {
      ok: false,
      output: `${error.stdout || ''}${error.stderr || ''}`,
      status: error.status || 1,
    };
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function classifyFixture(fixture, knownFailures) {
  const parsed = parseFixture(fixture);
  const expectedCheck = compareExpected(fixture, parsed.output);
  const deepCheck = parsed.status === 0 && parsed.parseErrors === 0
    ? compareDeep(fixture)
    : { ok: false, output: '', status: parsed.status || 1 };

  const isKnownFailure = knownFailures.has(fixture.rel);
  const expectedMissing = !expectedCheck.ok;
  const deepPass = deepCheck.ok;
  const parseFailed = parsed.crashed || parsed.parseErrors > 0;

  if (expectedCheck.ok && deepPass && !parseFailed) {
    return {
      status: 'pass',
      reason: 'expected output matches and deep compare passes',
      lang: parsed.lang,
    };
  }

  if (isKnownFailure) {
    if (parseFailed) {
      return {
        status: 'known_fail',
        reason: parsed.crashed ? 'parser crashed' : `${parsed.parseErrors} parse error(s)`,
        lang: parsed.lang,
      };
    }
    if (!deepPass) {
      return {
        status: 'known_fail',
        reason: 'deep compare diverges from OXC',
        lang: parsed.lang,
      };
    }
    if (expectedMissing) {
      return {
        status: 'known_fail',
        reason: 'missing expected output for a known failing case',
        lang: parsed.lang,
      };
    }
  }

  if (parseFailed) {
    return {
      status: 'unexpected_fail',
      reason: parsed.crashed ? 'parser crashed' : `${parsed.parseErrors} parse error(s)`,
      lang: parsed.lang,
    };
  }
  if (!expectedCheck.ok) {
    return {
      status: 'unexpected_fail',
      reason: expectedCheck.reason,
      lang: parsed.lang,
    };
  }
  if (!deepPass) {
    return {
      status: 'unexpected_fail',
      reason: 'deep compare diverges from OXC',
      lang: parsed.lang,
    };
  }

  return {
    status: 'unexpected_fail',
    reason: 'unclassified failure',
    lang: parsed.lang,
  };
}

const fixtures = listFixtures();
if (fixtures.length === 0) {
  console.error(`No ambiguity fixtures found in ${FIXTURE_DIR}`);
  process.exit(2);
}

const knownFailures = readKnownFailures();
const current = {};
const counts = { pass: 0, known_fail: 0, unexpected_fail: 0 };

for (const fixture of fixtures) {
  const verdict = classifyFixture(fixture, knownFailures);
  current[fixture.rel] = verdict.status;
  counts[verdict.status]++;
  if (VERBOSE) {
    const mark = verdict.status === 'pass' ? 'OK  '
      : verdict.status === 'known_fail' ? 'KNOWN'
      : 'FAIL';
    console.log(`  ${mark} ${fixture.rel} — ${verdict.reason}`);
  }
}

console.log('');
console.log('Ambiguity fixture status:');
console.log(`  pass:           ${counts.pass}`);
console.log(`  known_fail:     ${counts.known_fail}`);
console.log(`  unexpected_fail: ${counts.unexpected_fail}`);

const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : null;

if (UPDATE || baseline === null) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`\nBaseline ${baseline === null ? 'created' : 'updated'}: ${BASELINE_PATH}`);
  process.exit(0);
}

if (STRICT) {
  if (counts.known_fail > 0 || counts.unexpected_fail > 0) {
    console.log('\nSTRICT mode: every ambiguity fixture must pass.');
    process.exit(1);
  }
  console.log('\nSTRICT mode OK — every ambiguity fixture passed.');
  process.exit(0);
}

const regressions = [];
const improvements = [];
const newFixtures = [];
for (const fixture of fixtures) {
  const prev = baseline[fixture.rel];
  const now = current[fixture.rel];
  if (prev === undefined) {
    newFixtures.push(fixture.rel);
    continue;
  }
  if (prev === now) continue;
  if (prev === 'pass' && now !== 'pass') {
    regressions.push(`${fixture.rel}: pass -> ${now}`);
    continue;
  }
  if (prev !== 'pass' && now === 'pass') {
    improvements.push(`${fixture.rel}: ${prev} -> pass`);
    continue;
  }
  regressions.push(`${fixture.rel}: ${prev} -> ${now}`);
}

const removed = Object.keys(baseline).filter((name) => !current[name]);
console.log('');
if (newFixtures.length > 0) {
  console.log(`NEW fixtures: ${newFixtures.length}`);
  for (const name of newFixtures) console.log(`  ${name}`);
}
if (removed.length > 0) {
  console.log(`REMOVED fixtures: ${removed.length}`);
  for (const name of removed) console.log(`  ${name}`);
}
if (improvements.length > 0) {
  console.log(`IMPROVEMENTS: ${improvements.length}`);
  for (const entry of improvements) console.log(`  ${entry}`);
}
if (regressions.length > 0) {
  console.log(`REGRESSIONS: ${regressions.length}`);
  for (const entry of regressions) console.log(`  ${entry}`);
  process.exit(1);
}

if (newFixtures.length > 0 || removed.length > 0 || improvements.length > 0) {
  console.log('\nOK (with changes) — run with --update to relock.');
} else {
  console.log('\nOK — matches baseline exactly.');
}
process.exit(0);
