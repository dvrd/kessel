const { parseSync } = require('oxc-parser');
const fs = require('fs');

const code = 'const x = 1 + 2;';

// Parse and check output
const result = parseSync('test.js', code);
console.log('OXC parsed, program type:', result.program?.type || 'no type');
console.log('Has errors:', result.errors?.length || 0);

// Now benchmark with output verification
const start = process.hrtime.bigint();
for (let i = 0; i < 1000; i++) {
    const r = parseSync('test.js', code);
    if (!r.program) break; // Force use of result
}
const end = process.hrtime.bigint();

const totalMs = Number(end - start) / 1e6;
console.log(`1000 runs: ${totalMs.toFixed(2)}ms total, ${(totalMs/1000).toFixed(3)}ms avg`);
