#!/usr/bin/env node
/**
 * MINIMAL repro for x86_64 segfault.
 * Calls parseSync exactly once with the known-bad source.
 */

'use strict';

const log = (msg) => process.stderr.write('[CHK] ' + msg + '\n');

log('start');
const { parseSync } = require('./index');
log('after require');

const src = 'function bad() {\n  return "unterminated\n}';
log('first call, src.len=' + src.length);
try {
  const { errors } = parseSync('demo.js', src);
  log('OK, errors=' + errors.length);
  console.log('kessel npm test: 1 passed, 0 failed');
  process.exit(0);
} catch (e) {
  log('threw: ' + e.message);
  console.log('kessel npm test: 0 passed, 1 failed');
  process.exit(1);
}
