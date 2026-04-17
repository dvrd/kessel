#!/usr/bin/env node
/**
 * Quick Benchmark: Kessel vs OXC (3 runs only)
 */

const fs = require('fs');
const { execSync } = require('child_process');
const oxc = require('oxc-parser');

const RUNS = 3;
const KESSEL_BIN = '../kessel_test';

const TEST_FILES = [
    { name: 'tiny', path: 'valid_tiny.js' },
    { name: 'small', path: 'valid_small.js' },
    { name: 'medium', path: 'valid_medium.js' },
    { name: 'realistic', path: 'valid_realistic.js' },
];

function benchmarkKessel(filePath) {
    const times = [];
    for (let i = 0; i < RUNS; i++) {
        const start = process.hrtime.bigint();
        try { execSync(`${KESSEL_BIN} parse "${filePath}" 2>/dev/null >/dev/null`); } catch (e) {}
        times.push(Number(process.hrtime.bigint() - start) / 1_000_000);
    }
    return times.reduce((a, b) => a + b, 0) / times.length;
}

function benchmarkOxc(filePath) {
    const source = fs.readFileSync(filePath, 'utf8');
    const times = [];
    for (let i = 0; i < RUNS; i++) {
        const start = process.hrtime.bigint();
        oxc.parseSync(filePath, source);
        times.push(Number(process.hrtime.bigint() - start) / 1_000_000);
    }
    return times.reduce((a, b) => a + b, 0) / times.length;
}

console.log('⚡ QUICK BENCHMARK: Kessel vs OXC');
console.log(`Runs per file: ${RUNS}`);
console.log('');
console.log('File       | Size    | Kessel     | OXC        | Ratio');
console.log('─'.repeat(60));

for (const test of TEST_FILES) {
    if (!fs.existsSync(test.path)) continue;
    
    const size = fs.statSync(test.path).size;
    process.stdout.write(`${test.name.padEnd(10)} │ ${(size/1024).toFixed(1).padStart(6)}KB │ `);
    
    const kesselMs = benchmarkKessel(test.path);
    const oxcMs = benchmarkOxc(test.path);
    const ratio = kesselMs / oxcMs;
    
    const kesselStr = kesselMs < 1 ? `${kesselMs.toFixed(2)}ms` : `${kesselMs.toFixed(1)}ms`;
    const oxcStr = oxcMs < 1 ? `${oxcMs.toFixed(2)}ms` : `${oxcMs.toFixed(1)}ms`;
    
    const ratioStr = ratio < 1 
        ? `🟢 ${(1/ratio).toFixed(1)}x faster` 
        : `🔴 ${ratio.toFixed(1)}x slower`;
    
    console.log(`${kesselStr.padStart(9)} │ ${oxcStr.padStart(9)} │ ${ratioStr}`);
}

console.log('');
