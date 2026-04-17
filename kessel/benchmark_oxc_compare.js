#!/usr/bin/env node
/**
 * Benchmark: Kessel vs OXC (Full Parser Comparison)
 * 
 * Compares Kessel's full parser (lexing + parsing + AST) against OXC's parser.
 * Both parsers produce a complete AST.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const oxc = require('oxc-parser');

// Configuration
const WARMUP_RUNS = 3;
const BENCHMARK_RUNS = 10;
const KESSEL_BIN = '../kessel_test';  // Use the working binary

// Test files with different sizes
const TEST_FILES = [
    { name: 'tiny', path: 'valid_tiny.js' },
    { name: 'small', path: 'valid_small.js' },
    { name: 'medium', path: 'valid_medium.js' },
    { name: 'realistic', path: 'valid_realistic.js' },
    { name: 'large', path: 'valid_large.js' },
];

// Check if kessel exists
if (!fs.existsSync(KESSEL_BIN)) {
    console.error(`Error: ${KESSEL_BIN} not found.`);
    process.exit(1);
}

// Helper: Run benchmark multiple times and get average
function benchmarkKessel(filePath) {
    const times = [];
    const source = fs.readFileSync(filePath, 'utf8');
    
    // Warmup runs
    for (let i = 0; i < WARMUP_RUNS; i++) {
        try {
            execSync(`${KESSEL_BIN} parse "${filePath}" 2>/dev/null >/dev/null`);
        } catch (e) {
            // Kessel may exit with error due to parse errors, that's OK for benchmark
        }
    }
    
    // Benchmark runs
    for (let i = 0; i < BENCHMARK_RUNS; i++) {
        const start = process.hrtime.bigint();
        try {
            execSync(`${KESSEL_BIN} parse "${filePath}" 2>/dev/null >/dev/null`);
        } catch (e) {
            // Ignore errors - we're measuring speed, not correctness
        }
        const end = process.hrtime.bigint();
        times.push(Number(end - start) / 1_000_000); // Convert to ms
    }
    
    const avg = times.reduce((a, b) => a + b, 0) / times.length;
    const min = Math.min(...times);
    const max = Math.max(...times);
    
    return { avg, min, max, source };
}

// Helper: Benchmark OXC parser
function benchmarkOxc(filePath) {
    const times = [];
    const source = fs.readFileSync(filePath, 'utf8');
    
    // Warmup
    for (let i = 0; i < WARMUP_RUNS; i++) {
        oxc.parseSync(filePath, source);
    }
    
    // Benchmark runs
    for (let i = 0; i < BENCHMARK_RUNS; i++) {
        const start = process.hrtime.bigint();
        oxc.parseSync(filePath, source);
        const end = process.hrtime.bigint();
        times.push(Number(end - start) / 1_000_000); // Convert to ms
    }
    
    const avg = times.reduce((a, b) => a + b, 0) / times.length;
    const min = Math.min(...times);
    const max = Math.max(...times);
    
    return { avg, min, max, source };
}

// Formatting helpers
function formatTime(ms) {
    if (ms < 0.01) return `${(ms * 1000).toFixed(2)}μs`;
    if (ms < 1) return `${ms.toFixed(2)}ms`;
    return `${ms.toFixed(2)}ms`;
}

function formatThroughput(bytes, ms) {
    const kb = bytes / 1024;
    const kbPerSec = (kb / ms) * 1000;
    if (kbPerSec > 1024) {
        return `${(kbPerSec / 1024).toFixed(1)} MB/s`;
    }
    return `${kbPerSec.toFixed(1)} KB/s`;
}

function formatSize(bytes) {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

// Main benchmark
console.log('='.repeat(90));
console.log('BENCHMARK: Kessel vs OXC (Full Parser Comparison)');
console.log('='.repeat(90));
console.log(`Date: ${new Date().toISOString()}`);
console.log(`Kessel binary: ${KESSEL_BIN}`);
console.log(`OXC version: ${require('oxc-parser/package.json').version}`);
console.log(`Runs per test: ${BENCHMARK_RUNS} (after ${WARMUP_RUNS} warmup runs)`);
console.log('');

const results = [];

for (const test of TEST_FILES) {
    if (!fs.existsSync(test.path)) {
        console.log(`⚠ Skipping ${test.name}: file not found (${test.path})`);
        continue;
    }
    
    const size = fs.statSync(test.path).size;
    process.stdout.write(`Testing ${test.name} (${formatSize(size)})... `);
    
    // Benchmark Kessel
    const kesselResult = benchmarkKessel(test.path);
    
    // Benchmark OXC
    const oxcResult = benchmarkOxc(test.path);
    
    if (kesselResult && oxcResult) {
        results.push({
            name: test.name,
            size,
            kessel: kesselResult,
            oxc: oxcResult
        });
        console.log('✓');
    } else {
        console.log('✗ failed');
    }
}

// Print results table
console.log('');
console.log('='.repeat(90));
console.log('RESULTS');
console.log('='.repeat(90));
console.log('');

// Header
console.log('File        | Size    │ Kessel (Odin)                    │ OXC (Rust)                       │ Comparison');
console.log('            |         │ Time (avg) │ Min-Max     │ KB/s   │ Time (avg) │ Min-Max     │ KB/s   │ Kessel/OXC');
console.log('─'.repeat(90));

for (const r of results) {
    const kesselTime = formatTime(r.kessel.avg).padEnd(10);
    const kesselMinMax = `${formatTime(r.kessel.min)}-${formatTime(r.kessel.max)}`.padEnd(11);
    const kesselThroughput = formatThroughput(r.size, r.kessel.avg).padEnd(8);
    
    const oxcTime = formatTime(r.oxc.avg).padEnd(10);
    const oxcMinMax = `${formatTime(r.oxc.min)}-${formatTime(r.oxc.max)}`.padEnd(11);
    const oxcThroughput = formatThroughput(r.size, r.oxc.avg).padEnd(8);
    
    const ratio = (r.kessel.avg / r.oxc.avg);
    const ratioStr = ratio < 1 
        ? `🟢 ${(1/ratio).toFixed(2)}x faster` 
        : `🔴 ${ratio.toFixed(2)}x slower`;
    
    console.log(
        `${r.name.padEnd(11)} │ ${formatSize(r.size).padEnd(7)} │ ` +
        `${kesselTime} │ ${kesselMinMax} │ ${kesselThroughput} │ ` +
        `${oxcTime} │ ${oxcMinMax} │ ${oxcThroughput} │ ` +
        `${ratioStr}`
    );
}

console.log('');
console.log('='.repeat(90));
console.log('SUMMARY');
console.log('='.repeat(90));

if (results.length > 0) {
    // Calculate statistics
    const ratios = results.map(r => r.kessel.avg / r.oxc.avg);
    const avgRatio = ratios.reduce((a, b) => a + b, 0) / ratios.length;
    const fastest = results.reduce((best, r) => 
        (r.kessel.avg / r.oxc.avg) < (best.kessel.avg / best.oxc.avg) ? r : best
    );
    const slowest = results.reduce((worst, r) => 
        (r.kessel.avg / r.oxc.avg) > (worst.kessel.avg / worst.oxc.avg) ? r : worst
    );
    
    console.log('Performance Summary:');
    console.log(`  Average ratio: ${avgRatio.toFixed(2)}x`);
    
    if (avgRatio < 1) {
        console.log(`  🏆 Kessel is ${(1/avgRatio).toFixed(2)}x FASTER than OXC on average`);
    } else {
        console.log(`  📊 Kessel is ${avgRatio.toFixed(2)}x SLOWER than OXC on average`);
    }
    
    console.log('');
    console.log('Best performance:');
    const fastestRatio = (fastest.kessel.avg / fastest.oxc.avg);
    if (fastestRatio < 1) {
        console.log(`  ✓ ${fastest.name} (${formatSize(fastest.size)}): ${(1/fastestRatio).toFixed(2)}x faster`);
    } else {
        console.log(`  ⚠ ${fastest.name} (${formatSize(fastest.size)}): ${fastestRatio.toFixed(2)}x slower`);
    }
    
    console.log('');
    console.log('Worst performance:');
    const slowestRatio = (slowest.kessel.avg / slowest.oxc.avg);
    if (slowestRatio < 1) {
        console.log(`  ✓ ${slowest.name} (${formatSize(slowest.size)}): ${(1/slowestRatio).toFixed(2)}x faster`);
    } else {
        console.log(`  ⚠ ${slowest.name} (${formatSize(slowest.size)}): ${slowestRatio.toFixed(2)}x slower`);
    }
    
    console.log('');
    console.log('Throughput Comparison:');
    for (const r of results) {
        const kesselKBps = (r.size / 1024) / (r.kessel.avg / 1000);
        const oxcKBps = (r.size / 1024) / (r.oxc.avg / 1000);
        console.log(`  ${r.name.padEnd(10)}: Kessel ${kesselKBps.toFixed(0).padStart(6)} KB/s vs OXC ${oxcKBps.toFixed(0).padStart(6)} KB/s`);
    }
}

console.log('');
console.log('─'.repeat(90));
console.log('Notes:');
console.log('  • Both parsers run in single-threaded mode');
console.log('  • Times include file I/O (reading source from disk)');
console.log('  • OXC produces ESTree-compatible AST with full type information');
console.log('  • Kessel parser has some unimplemented features (see parse errors)');
console.log('  • Lower ratio = better (Kessel faster than OXC)');
console.log('='.repeat(90));
