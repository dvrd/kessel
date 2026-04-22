#!/usr/bin/env node
// Differential fuzzer: generate random-but-parseable JS, parse with Kessel
// AND with a reference parser (OXC by default), diff the resulting ASTs.
//
// The goal is NOT exhaustive coverage (Test262 and the real-world suite do
// that) — it's quick discovery of corner cases where one parser accepts
// input the other doesn't, or where the two produce divergent shapes for
// otherwise-valid input. Any mismatch is saved to `tmp/fuzz_crashes/` for
// offline inspection.
//
// Deterministic given a seed so a single failure is reproducible on demand.
//
// Usage:
//   node tests/fuzz_diff.js                     # default: 200 cases, oxc
//   node tests/fuzz_diff.js --count 1000 --seed 42
//   node tests/fuzz_diff.js --parser acorn --count 100
//
// Exit 0 only if ALL generated cases match. Otherwise reports per-case
// divergence and exits 1.

'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const TMP_DIR = path.join(ROOT, 'tmp/fuzz');
const CRASH_DIR = path.join(ROOT, 'tmp/fuzz_crashes');
fs.mkdirSync(TMP_DIR, { recursive: true });
fs.mkdirSync(CRASH_DIR, { recursive: true });

const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
}
const COUNT  = parseInt(arg('--count', '200'), 10);
const SEED   = parseInt(arg('--seed', String(Date.now() & 0xffffffff)), 10);
const PARSER = arg('--parser', 'oxc');
const VERBOSE = args.includes('--verbose');

console.log(`fuzz_diff: count=${COUNT} seed=${SEED} parser=${PARSER}`);

// Mulberry32 PRNG — deterministic, fast, sufficient for coverage generation.
function makePrng(seed) {
  let s = (seed >>> 0) || 1;
  return function () {
    s |= 0; s = (s + 0x6D2B79F5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const IDENTS = ['a', 'b', 'c', 'x', 'y', 'z', 'foo', 'bar', '_n'];
const LITERALS_NUM = ['0', '1', '42', '0xFF', '0b11', '0o77', '3.14', '1e10', '1_000', '0xFF_FF'];
const LITERALS_STR = ['""', '"hi"', '"\\n"', '"\\xff"', '"\\u{1F600}"', "'x'"];
const BIN_OPS = ['+', '-', '*', '/', '%', '**', '==', '===', '!=', '!==', '<', '<=', '>', '>=', '&&', '||', '??'];
const UN_OPS = ['!', '-', '+', '~', 'typeof ', 'void ', 'delete '];

function choose(rng, arr) { return arr[Math.floor(rng() * arr.length)]; }

function genExpr(rng, depth) {
  if (depth <= 0 || rng() < 0.3) {
    if (rng() < 0.5) return choose(rng, IDENTS);
    if (rng() < 0.5) return choose(rng, LITERALS_NUM);
    return choose(rng, LITERALS_STR);
  }
  const kind = Math.floor(rng() * 9);
  switch (kind) {
    case 0: return '(' + genExpr(rng, depth - 1) + ' ' + choose(rng, BIN_OPS) + ' ' + genExpr(rng, depth - 1) + ')';
    case 1: return choose(rng, UN_OPS) + genExpr(rng, depth - 1);
    case 2: return genExpr(rng, depth - 1) + ' ? ' + genExpr(rng, depth - 1) + ' : ' + genExpr(rng, depth - 1);
    case 3: return '[' + genArgs(rng, depth - 1, 0, 4).join(', ') + ']';
    case 4: {
      const keys = [];
      const n = Math.floor(rng() * 4);
      for (let i = 0; i < n; i++) keys.push(choose(rng, IDENTS) + ': ' + genExpr(rng, depth - 1));
      return '({' + keys.join(', ') + '})';
    }
    case 5: return choose(rng, IDENTS) + '(' + genArgs(rng, depth - 1, 0, 3).join(', ') + ')';
    case 6: return 'new ' + choose(rng, IDENTS) + '(' + genArgs(rng, depth - 1, 0, 2).join(', ') + ')';
    case 7: return genExpr(rng, depth - 1) + '.' + choose(rng, IDENTS);
    case 8: return '(' + genParams(rng) + ') => ' + genExpr(rng, depth - 1);
  }
  return choose(rng, IDENTS);
}

function genArgs(rng, depth, minN, maxN) {
  const n = minN + Math.floor(rng() * (maxN - minN + 1));
  const out = [];
  for (let i = 0; i < n; i++) out.push(genExpr(rng, depth));
  return out;
}

function genParams(rng) {
  const n = Math.floor(rng() * 3);
  const out = [];
  for (let i = 0; i < n; i++) out.push(choose(rng, IDENTS));
  return out.join(', ');
}

function genStmt(rng, depth) {
  const kind = Math.floor(rng() * 8);
  switch (kind) {
    case 0: return choose(rng, ['const', 'let', 'var']) + ' ' + choose(rng, IDENTS) + ' = ' + genExpr(rng, depth) + ';';
    case 1: return genExpr(rng, depth) + ';';
    case 2: return 'if (' + genExpr(rng, depth) + ') { ' + genStmt(rng, depth - 1) + ' }';
    case 3: return 'for (let ' + choose(rng, IDENTS) + ' = 0; ' + genExpr(rng, depth) + '; ' + choose(rng, IDENTS) + '++) { ' + genStmt(rng, depth - 1) + ' }';
    case 4: return 'while (' + genExpr(rng, depth) + ') { ' + genStmt(rng, depth - 1) + ' }';
    case 5: return 'function ' + choose(rng, IDENTS) + '(' + genParams(rng) + ') { return ' + genExpr(rng, depth) + '; }';
    case 6: return 'try { ' + genStmt(rng, depth - 1) + ' } catch (e) { ' + genStmt(rng, depth - 1) + ' }';
    case 7: return 'return ' + genExpr(rng, depth) + ';';
  }
  return choose(rng, IDENTS) + ';';
}

function genProgram(rng) {
  const n = 1 + Math.floor(rng() * 8);
  const stmts = [];
  for (let i = 0; i < n; i++) stmts.push(genStmt(rng, 2 + Math.floor(rng() * 3)));
  return stmts.join('\n');
}

// -----------------------------------------------------------------------------
// Drive the verifier. Re-use tests/verify_json_deep.js by shelling out so we
// inherit its compare-and-report logic without duplicating it.
// -----------------------------------------------------------------------------

let passed = 0;
let failed = 0;
const rng = makePrng(SEED);

for (let i = 0; i < COUNT; i++) {
  const src = genProgram(rng);
  const h = crypto.createHash('sha1').update(src).digest('hex').slice(0, 8);
  const srcPath = path.join(TMP_DIR, 'case_' + h + '.js');
  fs.writeFileSync(srcPath, src);

  let ok = false;
  let stdout = '';
  let stderr = '';
  try {
    stdout = execSync('node tests/verifiers/verify_json_deep.js "' + srcPath + '" --parser ' + PARSER + ' --limit 3',
      { encoding: 'utf8', maxBuffer: 20 * 1024 * 1024 });
    ok = stdout.indexOf('passes vs ' + PARSER) !== -1;
  } catch (e) {
    stdout = (e.stdout || '').toString();
    stderr = (e.stderr || '').toString();
    ok = false;
  }

  if (ok) {
    passed++;
    if (VERBOSE) console.log('  [' + i + '] ok (' + h + ')');
  } else {
    failed++;
    const crashPath = path.join(CRASH_DIR, 'case_' + h + '.js');
    fs.writeFileSync(crashPath, src);
    const firstFails = (stdout + '\n' + stderr).split('\n').filter(l => l.indexOf('FAIL') !== -1).slice(0, 2);
    console.log('  [' + i + '] FAIL (' + h + ') — saved to ' + crashPath);
    for (const f of firstFails) console.log('    ' + f);
  }
}

console.log('\nfuzz_diff: ' + passed + '/' + COUNT + ' passed, ' + failed + ' failures');
console.log('seed=' + SEED + ' (reproduce with --seed ' + SEED + ')');
console.log('crashes in ' + CRASH_DIR);
process.exit(failed > 0 ? 1 : 0);
