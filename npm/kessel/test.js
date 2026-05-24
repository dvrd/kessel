#!/usr/bin/env node
'use strict';
const log = (msg) => process.stderr.write('[CHK] ' + msg + '\n');
log('start');
const { parseSync } = require('./index');
log('after require');

// Try increasing-prefix versions of the failing source to find the
// minimal trigger. Each in a fresh require() context would be cleaner
// but parseSync between calls clears lib_last_result so this is fine.
const full = 'function bad() {\n  return "unterminated\n}';
log('full src len=' + full.length);

// Reverse-truncate: keep the last N chars
const cases = [
  ['full',              full],
  ['no-trailing-}',     full.slice(0, 40)],
  ['no-trailing-\\n}',  full.slice(0, 39)],
  ['truncated to 30',   full.slice(0, 30)],
  ['truncated to 26',   full.slice(0, 26)],  // 'function bad() {\n  return '
  ['truncated to 16',   full.slice(0, 16)],  // 'function bad() {'
  ['truncated to 17',   full.slice(0, 17)],  // 'function bad() {\n'
  ['truncated to 18',   full.slice(0, 18)],  // 'function bad() {\n '
  ['truncated to 20',   full.slice(0, 20)],  // 'function bad() {\n  r'
];

let passed = 0, failed = 0;
for (const [name, src] of cases) {
  log('CASE ' + name + ' (len=' + src.length + ') ' + JSON.stringify(src));
  try {
    const { errors } = parseSync('demo.js', src);
    log('  OK errors=' + errors.length);
    passed++;
  } catch (e) {
    log('  threw: ' + e.message);
    failed++;
  }
}
console.log('kessel npm test: ' + passed + ' passed, ' + failed + ' failed');
process.exit(failed > 0 ? 1 : 0);
