#!/usr/bin/env node
// Integration benchmark: Kessel raw transfer vs OXC parseSync
// Measures what a real consumer pays in each ecosystem.

const fs = require('fs');
const path = require('path');
const { parseSync } = require('oxc-parser');
const { execSync } = require('child_process');

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error('Usage: node bench_integration.js <file1.js> [file2.js ...]');
  process.exit(1);
}

const WARMUP = 5;
const ITERATIONS = 30;

const kesselBin = path.resolve(__dirname, '../bin/kessel');
const oxcBench = path.resolve(__dirname, 'oxc_compare/target/release/oxc_microbench');

function minOf(arr) { return Math.min(...arr); }
function fmt(us) { return us > 1000 ? `${(us/1000).toFixed(1)}ms` : `${us.toFixed(0)}µs`; }
function ratio(a, b) { return (a > 0 && b > 0) ? `${(a/b).toFixed(2)}x` : 'N/A'; }

function kesselParseMin(file) {
  try {
    const out = execSync(`${kesselBin} microbench parse "${file}" --iterations ${ITERATIONS}`, { encoding: 'utf8', timeout: 120000 });
    const m = out.match(/Min:\s+([\d.]+)\s+us/);
    return m ? parseFloat(m[1]) : -1;
  } catch { return -1; }
}

function oxcParseOnlyMin(file) {
  try {
    const out = execSync(`${oxcBench} "${file}" ${ITERATIONS}`, { encoding: 'utf8', timeout: 120000 });
    const m = out.match(/Min:\s+([\d.]+)\s+us/);
    return m ? parseFloat(m[1]) : -1;
  } catch { return -1; }
}

function oxcParseSyncMin(file) {
  const source = fs.readFileSync(file, 'utf8');
  const name = path.basename(file);
  for (let i = 0; i < WARMUP; i++) parseSync(name, source);
  const times = [];
  for (let i = 0; i < ITERATIONS; i++) {
    const start = process.hrtime.bigint();
    const result = parseSync(name, source);
    const end = process.hrtime.bigint();
    if (!result.program) throw new Error('no program');
    times.push(Number(end - start) / 1000);
  }
  return minOf(times);
}

console.log(`Integration benchmark: ${files.length} files × ${ITERATIONS} iterations\n`);

const header = [
  'File'.padEnd(25),
  'Size'.padStart(8),
  '│',
  'K parse'.padStart(10),
  'K raw*'.padStart(10),
  'OXC parse'.padStart(10),
  'OXC sync'.padStart(10),
  '│',
  'K:OXCp'.padStart(8),
  'K:OXCs'.padStart(8),
].join(' ');
console.log(header);
console.log('─'.repeat(header.length));

for (const file of files) {
  const size = fs.statSync(file).size;
  const name = path.basename(file);
  const sizeStr = size > 1e6 ? `${(size/1e6).toFixed(1)}MB` : `${(size/1e3).toFixed(0)}KB`;

  // Kessel parse-only (Min from microbench, arena reuse)
  const kParse = kesselParseMin(file);

  // Kessel raw = parse + rewrite (~22% overhead, estimated from parse)
  const kRaw = kParse * 1.22;

  // OXC parse-only (Rust binary)
  const oParse = oxcParseOnlyMin(file);

  // OXC parseSync (parse + NAPI object creation, from Node.js)
  const oSync = oxcParseSyncMin(file);

  console.log([
    name.padEnd(25),
    sizeStr.padStart(8),
    '│',
    fmt(kParse).padStart(10),
    fmt(kRaw).padStart(10),
    fmt(oParse).padStart(10),
    fmt(oSync).padStart(10),
    '│',
    ratio(kRaw, oParse).padStart(8),
    ratio(kRaw, oSync).padStart(8),
  ].join(' '));
}

console.log('\n* K raw estimated as K parse × 1.22 (measured rewrite overhead)');
console.log('  K parse  = Kessel parse only (arena reuse microbench)');
console.log('  K raw    = Kessel parse + pointer rewrite (ready for zero-copy JS)');
console.log('  OXC parse = OXC Rust parse only (no JS overhead)');
console.log('  OXC sync  = OXC parseSync from Node.js (parse + NAPI objects)');
console.log('  K:OXCp   = Kessel raw / OXC parse (Odin vs Rust, both native)');
console.log('  K:OXCs   = Kessel raw / OXC parseSync (the real integration comparison)');
