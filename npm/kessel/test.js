#!/usr/bin/env node
'use strict';
const log = (msg) => process.stderr.write('[CHK] ' + msg + '\n');
log('start');
const { parseSync } = require('./index');
log('after require');

// Run JUST the previously-crashing len=34 prefix as the very first call.
const src = 'function bad() {\n  return "untermi';
log('first call src.len=' + src.length + ' ' + JSON.stringify(src));
try {
  const { errors } = parseSync('demo.js', src);
  log('OK errors=' + errors.length);
  console.log('kessel npm test: 1 passed, 0 failed');
  process.exit(0);
} catch (e) {
  log('threw: ' + e.message);
  console.log('kessel npm test: 0 passed, 1 failed');
  process.exit(1);
}
