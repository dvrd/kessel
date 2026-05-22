#!/usr/bin/env node
/**
 * Cross-parser npm benchmark.
 *
 * Measures parseSync throughput from the Node.js side —
 * what a real consumer (ESLint, bundler, LSP) would experience.
 *
 * Parsers tested:
 *   - kessel  (CLI shim — spawns process per call)
 *   - oxc-parser     (native NAPI binding)
 *   - acorn          (pure JS)
 *   - @babel/parser  (pure JS)
 *
 * Usage:
 *   node bench/npm_bench.js [--iterations N]
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const oxc = require('oxc-parser');
const acorn = require('acorn');
const babel = require('@babel/parser');
const kessel = require('../npm');

const KESSEL_BIN = path.resolve(__dirname, '../bin/kessel');

const args = process.argv.slice(2);
const ITERATIONS = parseInt(args.find((_, i, a) => a[i - 1] === '--iterations') || '20', 10);

const FILES = [
  'real_world/lodash.js',
  'real_world/jquery.js',
  'real_world/d3.js',
  'real_world/react-dom.dev.js',
  'real_world/antd.js',
  'real_world/batch2/monaco.js',
  'real_world/typescript.js',
];

function benchSync(parseFn, source, iterations) {
  // Warmup
  try { for (let i = 0; i < 2; i++) parseFn(source); } catch { return null; }

  const times = [];
  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    try { parseFn(source); } catch { return null; }
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  return times[0]; // min
}

// Measure kessel CLI shim overhead separately since it's so slow
// we don't want to run it N times on large files
function benchKesselCli(source, iterations) {
  const iters = Math.min(iterations, 5); // cap at 5 for CLI
  const parseFn = (s) => kessel.parseSync('test.js', s);
  parseFn(source); // warmup
  const times = [];
  for (let i = 0; i < iters; i++) {
    const start = performance.now();
    parseFn(source);
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  return times[0];
}

// Measure what kessel's raw speed would look like if we had a NAPI binding:
// parse time = kessel microbench min + JSON.parse overhead
function benchKesselNative(absPath, source, iterations) {
  // Get raw parse time from kessel microbench
  const r = spawnSync(KESSEL_BIN, [
    'microbench', 'parse', absPath, '--iterations', String(Math.max(iterations, 20)), '--ast-only'
  ], { encoding: 'utf8', timeout: 120000 });
  const minLine = (r.stdout || '').split('\n').find(l => l.includes('Min:'));
  const parseUs = parseFloat(minLine.split(/\s+/)[1]);

  // Get JSON output size to estimate JSON.parse cost
  const r2 = spawnSync(KESSEL_BIN, ['parse', absPath, '--compact'], {
    encoding: 'utf8', maxBuffer: 200 * 1024 * 1024, timeout: 30000
  });
  const jsonStr = (r2.stdout || '').split('\n')[0];
  const jsonBytes = Buffer.byteLength(jsonStr, 'utf8');

  // Measure JSON.parse cost
  let jpMin = Infinity;
  for (let i = 0; i < Math.min(iterations, 10); i++) {
    const start = performance.now();
    JSON.parse(jsonStr);
    const t = performance.now() - start;
    if (t < jpMin) jpMin = t;
  }

  return {
    parseMs: parseUs / 1000,
    jsonParseMs: jpMin,
    totalMs: parseUs / 1000 + jpMin,
    jsonKB: jsonBytes / 1024,
  };
}

console.log(`Cross-parser npm benchmark (${ITERATIONS} iterations, min)\n`);

const W = 28;
console.log(
  'File'.padEnd(W) +
  'kessel*'.padStart(11) +
  'oxc'.padStart(11) +
  'acorn'.padStart(11) +
  'babel'.padStart(11) +
  'kessel-cli'.padStart(12) +
  '  kessel breakdown'
);
console.log('-'.repeat(W + 56 + 20));

for (const rel of FILES) {
  const absPath = path.resolve(__dirname, rel);
  if (!fs.existsSync(absPath)) { console.log(`${rel}: MISSING`); continue; }
  const source = fs.readFileSync(absPath, 'utf8');
  const sizeKB = (source.length / 1024).toFixed(0);

  // OXC NAPI
  const oxcMs = benchSync(
    (s) => oxc.parseSync('test.js', s, { sourceType: 'module' }),
    source, ITERATIONS
  );

  // Acorn
  const acornMs = benchSync(
    (s) => acorn.parse(s, { ecmaVersion: 2025, sourceType: 'module' }),
    source, ITERATIONS
  );

  // Babel
  const babelMs = benchSync(
    (s) => babel.parse(s, { sourceType: 'module', plugins: ['typescript'] }),
    source, ITERATIONS
  );

  // Kessel CLI shim
  const kesselCliMs = benchKesselCli(source, ITERATIONS);

  // Kessel "native" estimate (parse + JSON.parse, no IPC)
  const kn = benchKesselNative(absPath, source, ITERATIONS);

  const label = `${path.basename(rel)} (${sizeKB}KB)`;
  console.log(
    label.padEnd(W) +
    (kn.totalMs.toFixed(1) + 'ms').padStart(11) +
    (oxcMs != null ? oxcMs.toFixed(1) + 'ms' : 'FAIL').padStart(11) +
    (acornMs != null ? acornMs.toFixed(1) + 'ms' : 'FAIL').padStart(11) +
    (babelMs != null ? babelMs.toFixed(1) + 'ms' : 'FAIL').padStart(11) +
    (kesselCliMs.toFixed(0) + 'ms').padStart(12) +
    `  (parse ${kn.parseMs.toFixed(1)}ms + JSON.parse ${kn.jsonParseMs.toFixed(1)}ms, ${kn.jsonKB.toFixed(0)}KB)`
  );
}

console.log(`
* kessel = parse time + JSON.parse time (simulates a native NAPI binding)
  kessel-cli = current npm shim (process spawn per call)
  oxc = native NAPI binding (Rust → V8 objects, zero IPC)
  acorn/babel = pure JavaScript`);
