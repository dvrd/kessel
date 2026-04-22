#!/usr/bin/env node
// Known-crash gate.
//
// Three fixtures crash the parser today (SIGTRAP / exit 133). They were
// previously buried under `KNOWN FAIL (exit 133)` output in `task test:unit`,
// which made them indistinguishable from an ordinary parse-error fixture.
// A crashing parser is a denial-of-service surface for any downstream tool,
// so we surface them explicitly here:
//
//   * A pinned fixture that STOPS crashing is an IMPROVEMENT (prints a
//     hint and exit 0; maintainer should remove it from KNOWN list).
//   * A pinned fixture that still crashes passes the gate (no regression).
//   * A NEW crash (any fixture outside the KNOWN list that now crashes) is
//     a regression \u2014 exit 1.
//
// This gate is narrow on purpose: it walks tests/fixtures/ only (not the
// 467-file real-world corpus \u2014 that's test:real's job, and
// test:fuzz:invalid covers random-byte crashes). Its one job is to keep
// the 3 pinned fixtures visible.
//
// Crash criterion: exit code > 1 OR signal-terminated. A parse error
// (exit 1, stderr reports "Parse errors: N") is NOT a crash.
//
// Usage:
//   node tests/verifiers/verify_crashes_known.js
//   node tests/verifiers/verify_crashes_known.js --verbose
//
// Exit 0 on success; 1 on a new crash.

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const FIXTURES_DIR = path.join(ROOT, 'tests/fixtures');

const VERBOSE = process.argv.includes('--verbose');

// Pinned list of fixtures that are known to crash today. Path is RELATIVE
// to tests/fixtures/. Each entry must be justified with a short WHY \u2014 a
// future maintainer should be able to read this list and know what to fix.
//
// Removing an entry here means "the parser no longer crashes on this input".
// The gate enforces that removal is sticky: if you remove an entry and the
// parser regresses, the gate catches it.
const KNOWN_CRASHES = [
  {
    path: 'spec/jsx/005_nested_element.js',
    why: 'JSXElement as an attribute value (<Foo bar={<Baz />} />). ' +
         'The JSX attribute-value parser recurses into an unhandled case.',
  },
  {
    path: 'spec/typescript/007_type_assertion.js',
    why: 'TS angle-bracket type assertion <Type>expr. The lexer enters ' +
         'JSX mode on `<` and cannot unwind when the `>` closes a type.',
  },
  {
    path: 'spec/unicode/002_escape_in_identifier.js',
    why: 'ECMA-262 \u00a712.7: `\\\\u0061bc` must lex as identifier `abc`. ' +
         'The lexer has no identifier-escape path.',
  },
];

if (!fs.existsSync(KESSEL)) {
  console.error('verify_crashes_known: missing ' + KESSEL + ' \u2014 run `task build` first');
  process.exit(2);
}

// Decide: is this run a crash? We look at three signals:
//   1. spawnSync returned a signal (SIGTRAP, SIGSEGV, SIGABRT, SIGBUS)
//   2. spawnSync returned an exit status > 1 (134, 133, 139, 138, 137...)
//   3. spawnSync timed out (error.code === 'ETIMEDOUT')
//
// Exit 0 (parsed OK) and exit 1 (parse errors reported) are both NOT crashes.
function isCrash(r) {
  if (r.error && r.error.code === 'ETIMEDOUT') return { reason: 'timeout' };
  if (r.signal) return { reason: 'signal:' + r.signal };
  if (typeof r.status === 'number' && r.status > 1) return { reason: 'exit=' + r.status };
  return null;
}

function run(abs) {
  return spawnSync(KESSEL, ['parse', abs], {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    timeout: 10_000,
  });
}

// -----------------------------------------------------------------------------
// 1. Confirm every KNOWN crasher still crashes (improvement reporter).
// -----------------------------------------------------------------------------
const improvements = [];
const stillCrashing = [];
for (const k of KNOWN_CRASHES) {
  const abs = path.join(FIXTURES_DIR, k.path);
  if (!fs.existsSync(abs)) {
    console.error('verify_crashes_known: pinned fixture missing: ' + abs);
    process.exit(2);
  }
  const r = run(abs);
  const crash = isCrash(r);
  if (crash) {
    stillCrashing.push({ ...k, reason: crash.reason });
    if (VERBOSE) console.log('  PINNED: ' + k.path + '  ' + crash.reason);
  } else {
    improvements.push(k);
  }
}

// -----------------------------------------------------------------------------
// 2. Walk every other fixture; anything that crashes is a NEW crash.
// -----------------------------------------------------------------------------
function listFixtures() {
  const out = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && /\.(js|mjs)$/.test(entry.name)) out.push(full);
    }
  }
  walk(FIXTURES_DIR);
  return out.sort();
}

const knownSet = new Set(KNOWN_CRASHES.map(k => path.join(FIXTURES_DIR, k.path)));
const newCrashes = [];
const fixtures = listFixtures();
for (const abs of fixtures) {
  if (knownSet.has(abs)) continue;
  const r = run(abs);
  const crash = isCrash(r);
  if (crash) {
    newCrashes.push({ path: path.relative(FIXTURES_DIR, abs), reason: crash.reason });
  }
}

// -----------------------------------------------------------------------------
// Report.
// -----------------------------------------------------------------------------
console.log('verify_crashes_known: walked ' + fixtures.length + ' fixtures');
console.log('  pinned:        ' + KNOWN_CRASHES.length);
console.log('  still crashing: ' + stillCrashing.length);
console.log('  improvements:  ' + improvements.length);
console.log('  new crashes:   ' + newCrashes.length);

if (improvements.length > 0) {
  console.log('\nIMPROVEMENTS: the following pinned fixtures no longer crash:');
  for (const k of improvements) {
    console.log('  \u2022 ' + k.path);
    console.log('    was: ' + k.why);
  }
  console.log('\n  Remove them from KNOWN_CRASHES in tests/verifiers/verify_crashes_known.js');
  console.log('  to lock in the fix. (No exit yet \u2014 an improvement alone does not fail.)');
}

if (newCrashes.length > 0) {
  console.log('\nREGRESSIONS: the following fixtures now crash (not in KNOWN list):');
  for (const c of newCrashes) {
    console.log('  \u2022 ' + c.path + '  ' + c.reason);
  }
  console.log('\n  Either fix the crash, or \u2014 if the crash is a known parser bug with a');
  console.log('  short-term cost/benefit that justifies tracking \u2014 add to KNOWN_CRASHES');
  console.log('  with a WHY explanation.');
  process.exit(1);
}

console.log('\nOK.');
process.exit(0);
