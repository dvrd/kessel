const koffi = require('koffi');
const path = require('path');

const libPath = path.join(__dirname, 'kessel_lib.dylib');
const lib = koffi.load(libPath);

// Define functions
const kessel_count = lib.func('size_t kessel_count(const char *source, size_t len)');
const kessel_version = lib.func('const char *kessel_version()');

// Wrapper
function parse(source) {
  const start = process.hrtime.bigint();
  const result = kessel_count(source, source.length);
  const end = process.hrtime.bigint();
  const timeMs = Number(end - start) / 1e6;
  
  return {
    result,
    timeMs
  };
}

module.exports = { parse, version: kessel_version };

// Test
if (require.main === module) {
  console.log('Kessel version:', kessel_version());
  
  const testCode = 'const x = 1 + 2;';
  
  console.log('\n=== Kessel via FFI ===');
  for (let i = 1; i <= 5; i++) {
    const r = parse(testCode);
    console.log(`Run ${i}: ${r.timeMs.toFixed(2)}ms`);
  }
  
  // Compare with OXC
  console.log('\n=== OXC via Node.js ===');
  const { parseSync } = require('oxc-parser');
  const fs = require('fs');
  fs.writeFileSync('/tmp/test.js', testCode);
  const code = fs.readFileSync('/tmp/test.js', 'utf8');
  
  for (let i = 1; i <= 5; i++) {
    const start = process.hrtime.bigint();
    parseSync('/tmp/test.js', code);
    const end = process.hrtime.bigint();
    const ms = Number(end - start) / 1e6;
    console.log(`Run ${i}: ${ms.toFixed(2)}ms`);
  }
}
