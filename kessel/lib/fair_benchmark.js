const koffi = require('koffi');
const fs = require('fs');
const { parseSync } = require('oxc-parser');

// Load Kessel lib
const libPath = require('path').join(__dirname, 'kessel_lib.dylib');
const lib = koffi.load(libPath);
const kessel_lex = lib.func('size_t kessel_lex_count(uint8_t *data, size_t len)');

// Test file
const testCode = `
const utils = {
  add: (a, b) => a + b,
  mul: (a, b) => a * b,
};

class Calculator {
  constructor() { this.history = []; }
  calc(op, a, b) {
    const r = utils[op](a, b);
    this.history.push({ op, a, b, r });
    return r;
  }
  getHistory() { return this.history; }
}

const arr = [1, 2, 3, 4, 5].map(x => x * 2).filter(n => n > 4);
const obj = { arr, calc: new Calculator() };
export { utils, Calculator };
`;

fs.writeFileSync('/tmp/bench.js', testCode);
const code = fs.readFileSync('/tmp/bench.js', 'utf8');
const size = code.length;

console.log(`File size: ${size} bytes`);
console.log('');

// Create buffer for Kessel
const buffer = Buffer.from(code, 'utf8');

// Benchmark OXC (full parser)
console.log('=== OXC (Full Parser via Node.js) ===');
for (let i = 1; i <= 10; i++) {
  const start = process.hrtime.bigint();
  parseSync('/tmp/bench.js', code);
  const end = process.hrtime.bigint();
  const ms = Number(end - start) / 1e6;
  console.log(`Run ${i}: ${ms.toFixed(2)}ms`);
}

// Benchmark Kessel FFI (simple lexer)
console.log('');
console.log('=== Kessel (Simple Lexer via FFI) ===');
for (let i = 1; i <= 10; i++) {
  const start = process.hrtime.bigint();
  kessel_lex(buffer, buffer.length);
  const end = process.hrtime.bigint();
  const ms = Number(end - start) / 1e6;
  console.log(`Run ${i}: ${ms.toFixed(2)}ms`);
}

console.log('');
console.log('Note: Kessel FFI here is only doing lexing, not full parsing');
console.log('Full Kessel parser benchmark should use native binary');

fs.unlinkSync('/tmp/bench.js');
