/**
 * Quick microbenchmark: spawn-per-call (parseSync) vs server-mode (parse).
 *
 * Run: node npm/kessel-parser/bench.js
 */

'use strict';

const { parseSync } = require('./index.js');
const { parse, shutdownAll } = require('./server.js');

const SOURCE = `
function fibonacci(n) {
  if (n < 2) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
}

const cache = new Map();
class Memoized {
  constructor(fn) { this.fn = fn; this.cache = new Map(); }
  call(n) {
    if (!this.cache.has(n)) this.cache.set(n, this.fn(n));
    return this.cache.get(n);
  }
}

const fib = new Memoized(fibonacci);
for (let i = 0; i < 10; i++) console.log(fib.call(i));

import { something } from './mod.js';
export const x = 42;
`.repeat(5);

const N = 50;

async function main() {
  // Warmup
  for (let i = 0; i < 3; i++) parseSync('bench.js', SOURCE);

  console.log(`Source: ${SOURCE.length} bytes, iterations: ${N}`);

  // parseSync — spawn per call
  {
    const start = process.hrtime.bigint();
    for (let i = 0; i < N; i++) parseSync('bench.js', SOURCE);
    const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
    console.log(`parseSync  (spawn/call):  ${elapsed.toFixed(1)} ms total, ${(elapsed / N).toFixed(2)} ms/call`);
  }

  // Warmup server
  await parse('bench.js', SOURCE);

  // parse — server pool
  {
    const start = process.hrtime.bigint();
    for (let i = 0; i < N; i++) await parse('bench.js', SOURCE);
    const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
    console.log(`parse      (server pool): ${elapsed.toFixed(1)} ms total, ${(elapsed / N).toFixed(2)} ms/call`);
  }

  shutdownAll();
}

main().catch((e) => { console.error(e); process.exit(1); });
