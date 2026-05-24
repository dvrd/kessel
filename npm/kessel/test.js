#!/usr/bin/env node
'use strict';
const log = (msg) => process.stderr.write('[CHK] ' + msg + '\n');
log('start');
const { parseSync } = require('./index');
log('after require');

const full = 'function bad() {\n  return "unterminated\n}';
log('full src len=' + full.length);

// Smallest first so the FIRST crash tells us the minimum trigger length.
const cases = [];
for (let n = 16; n <= 41; n++) {
  cases.push(['len ' + n, full.slice(0, n)]);
}

let passed = 0, failed = 0;
for (const [name, src] of cases) {
  log('CASE ' + name + ' ' + JSON.stringify(src));
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
