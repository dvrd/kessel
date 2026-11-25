'use strict';

const assert = require('node:assert/strict');
const child = require('node:child_process');
const path = require('node:path');

function checkGate(fault, expectedStatus, expectedMessage) {
  const gate = path.join(__dirname, 'verify_codegen.js');
  const run = child.spawnSync(process.execPath, ['--require', __filename, gate, '--corpus-limit', '1'], {
    env: { ...process.env, KESSEL_CODEGEN_TEST_FAULT: fault },
    encoding: 'utf8',
  });
  if (run.error) throw run.error;
  assert.equal(run.status, expectedStatus, fault + '\n' + run.stderr + run.stdout);
  assert.match(run.stderr + run.stdout, expectedMessage, fault);
}

if (require.main === module) {
  checkGate('none', 0, /1 pass, 0 skip/);
  checkGate('diagnostic', 0, /0 pass, 1 skip/);
  checkGate('missing', 1, /Parser invocation failed.*missing test executable/);
  checkGate('status', 1, /Parser invocation failed.*nonzero test exit/);
  checkGate('truncated', 1, /Parser invocation failed/);
  checkGate('invalid_shape', 1, /Expected an ESTree Program/);
  checkGate('invalid_diagnostics', 1, /Expected an ESTree Program/);
  checkGate('bad_reparse', 1, /Parser invocation failed.*\.regen/);
  checkGate('missing_printer', 1, /missing test executable/);
  console.log('Printer gate distinguished source diagnostics from parser, printer and JSON failures.');
} else {
  // Preload into the real verifier. Faults replace only its Kessel subprocess,
  // so fixture selection, skip accounting and the exit status run normally.
  const fault = process.env.KESSEL_CODEGEN_TEST_FAULT;
  const exec = child.execFileSync;
  child.execFileSync = (command, args, options) => {
    const missing = () => Object.assign(new Error('missing test executable'), { code: 'ENOENT' });
    if (args[0] === 'codegen' && fault === 'missing_printer') throw missing();
    if (args[0] === 'parse') {
      if (fault === 'missing') throw missing();
      if (fault === 'status') throw Object.assign(new Error('nonzero test exit'), { status: 1 });
      if (fault === 'truncated' || (fault === 'bad_reparse' && args[1].includes('.regen'))) return Buffer.from('{');
      if (fault === 'invalid_shape') return Buffer.from('{}');
      if (fault === 'invalid_diagnostics') return Buffer.from('{"type":"Program","body":[],"errors":"error"}');
      if (fault === 'diagnostic') return Buffer.from('{"type":"Program","body":[],"errors":[{"message":"Expected token"}]}');
    }
    return exec(command, args, options);
  };
}
