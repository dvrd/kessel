#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const QUIET = process.argv.includes('--quiet');
const PIN_PATH = path.join(ROOT, 'OXC_ORACLE.json');
const OXC_DIR = path.resolve(ROOT, '../oxc');
const BENCH_PACKAGE = path.join(ROOT, 'bench/package.json');
const BENCH_LOCK = path.join(ROOT, 'bench/package-lock.json');

function fail(message) {
  console.error(message);
  process.exit(1);
}

function note(message) {
  if (!QUIET) console.log(message);
}

function runGit(args) {
  const result = spawnSync('git', ['-C', OXC_DIR, ...args], {
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0 || result.error) {
    const detail = result.error ? result.error.message : (result.stderr || result.stdout).trim();
    fail('verify_oxc_pin: git failed in ' + OXC_DIR + ': ' + detail);
  }
  return result.stdout.trim();
}

function assertCleanGit(args, dirtyMessage) {
  const result = spawnSync('git', ['-C', OXC_DIR, ...args], { encoding: 'utf8' });
  if (result.error) {
    fail('verify_oxc_pin: git failed in ' + OXC_DIR + ': ' + result.error.message);
  }
  if (result.status === 1) {
    fail(dirtyMessage);
  }
  if (result.status !== 0) {
    fail('verify_oxc_pin: git failed in ' + OXC_DIR + ': ' + (result.stderr || '').trim());
  }
}

if (!fs.existsSync(PIN_PATH)) {
  fail('verify_oxc_pin: missing ' + path.relative(ROOT, PIN_PATH));
}

const oracle = JSON.parse(fs.readFileSync(PIN_PATH, 'utf8'));
const expectedCommit = oracle.oxc_git_commit;
const expectedOxcParser = oracle.oxc_parser_npm;
if (!/^[0-9a-f]{40}$/.test(expectedCommit)) {
  fail('verify_oxc_pin: OXC_ORACLE.json must contain one full 40-character lowercase oxc_git_commit SHA');
}
if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(expectedOxcParser)) {
  fail('verify_oxc_pin: OXC_ORACLE.json must contain an exact oxc_parser_npm version');
}

if (!fs.existsSync(OXC_DIR)) {
  fail(
    'verify_oxc_pin: missing OXC checkout at ' + OXC_DIR + '\n' +
    'Clone it with:\n' +
    '  git clone https://github.com/oxc-project/oxc.git ' + OXC_DIR
  );
}

const actualCommit = runGit(['rev-parse', 'HEAD']);
if (actualCommit !== expectedCommit) {
  fail(
    'verify_oxc_pin: OXC checkout is not at the pinned commit\n' +
    '  expected: ' + expectedCommit + '\n' +
    '  actual:   ' + actualCommit + '\n' +
    'Fix with:\n' +
    '  git -C ' + OXC_DIR + ' fetch origin ' + expectedCommit + '\n' +
    '  git -C ' + OXC_DIR + ' checkout ' + expectedCommit
  );
}

assertCleanGit(
  ['diff', '--quiet'],
  'verify_oxc_pin: OXC checkout has unstaged tracked changes; commit or stash them before comparing'
);
assertCleanGit(
  ['diff', '--cached', '--quiet'],
  'verify_oxc_pin: OXC checkout has staged changes; commit or stash them before comparing'
);

if (fs.existsSync(BENCH_PACKAGE)) {
  const benchPackage = JSON.parse(fs.readFileSync(BENCH_PACKAGE, 'utf8'));
  const declaredOxcParser = benchPackage.dependencies && benchPackage.dependencies['oxc-parser'];
  if (!declaredOxcParser) {
    fail('verify_oxc_pin: bench/package.json must declare oxc-parser when present');
  }
  if (/^[\^~*]/.test(declaredOxcParser)) {
    fail('verify_oxc_pin: bench/package.json must pin oxc-parser exactly, got ' + declaredOxcParser);
  }
  if (declaredOxcParser !== expectedOxcParser) {
    fail(
      'verify_oxc_pin: bench/package.json does not match OXC_ORACLE.json\n' +
      '  oracle:       ' + expectedOxcParser + '\n' +
      '  package.json: ' + declaredOxcParser
    );
  }
}

if (fs.existsSync(BENCH_LOCK)) {
  const benchLock = JSON.parse(fs.readFileSync(BENCH_LOCK, 'utf8'));
  const rootLockedOxcParser =
    benchLock.packages &&
    benchLock.packages[''] &&
    benchLock.packages[''].dependencies &&
    benchLock.packages[''].dependencies['oxc-parser'];
  if (rootLockedOxcParser !== expectedOxcParser) {
    fail(
      'verify_oxc_pin: oxc-parser root lock declaration does not match OXC_ORACLE.json\n' +
      '  oracle:             ' + expectedOxcParser + '\n' +
      '  package-lock root:  ' + rootLockedOxcParser
    );
  }

  const lockedOxcParser =
    benchLock.packages &&
    benchLock.packages['node_modules/oxc-parser'] &&
    benchLock.packages['node_modules/oxc-parser'].version;
  if (!lockedOxcParser) {
    fail('verify_oxc_pin: bench/package-lock.json does not lock node_modules/oxc-parser');
  }
  if (lockedOxcParser !== expectedOxcParser) {
    fail(
      'verify_oxc_pin: oxc-parser lock does not match OXC_ORACLE.json\n' +
      '  oracle:            ' + expectedOxcParser + '\n' +
      '  package-lock node: ' + lockedOxcParser
    );
  }
}

note('verify_oxc_pin: ok ' + expectedCommit.slice(0, 8) + ' / oxc-parser ' + expectedOxcParser);
