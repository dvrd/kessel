'use strict';

const assert = require('node:assert/strict');
const cp = require('node:child_process');
const path = require('node:path');

// Preload this fixture in the verifier's child process so it receives known
// timings through its normal microbench interface. The CLI still chooses the
// run order, computes ratios and decides whether each benchmark passes.
if (require.main !== module) {
  const calls = new Map();
  cp.spawnSync = (binary, args) => {
    assert.equal(args[0], 'microbench');
    const file = path.basename(args[2]);
    const index = calls.get(file) || 0;
    calls.set(file, index + 1);
    const candidate = binary !== process.execPath;
    let us = 100;
    switch (process.env.KESSEL_BENCH_SCENARIO) {
      case 'jitter':
        if (index === 1 || index === 2) us = 118;
        break;
      case 'per-file':
        if (candidate && file === 'lodash.js') us = 112;
        break;
      case 'overall':
        if (candidate) us = 106;
        break;
      case 'zero':
        us = 0;
        break;
    }
    return { status: 0, stdout: 'Min: ' + us + ' us\n', stderr: '' };
  };
} else {
  const verifier = path.join(__dirname, 'verify_bench_regression.js');
  for (const [scenario, status, expected] of [
    ['steady', 0, 'geo-mean ratio: 1.000'],
    ['jitter', 0, 'geo-mean ratio: 1.000'],
    ['per-file', 1, 'REGRESSIONS: 1 file(s)'],
    ['overall', 1, 'GEO-MEAN REGRESSION:'],
    ['zero', 1, 'invalid minimum time'],
  ]) {
    const result = cp.spawnSync(process.execPath, ['--require', __filename, verifier, '--quick', '--reference', process.execPath], {
      env: { ...process.env, KESSEL_BENCH_SCENARIO: scenario },
      encoding: 'utf8',
    });
    if (result.error) throw result.error;
    assert.equal(result.status, status, scenario + '\n' + result.stdout + result.stderr);
    assert.ok((result.stdout + result.stderr).includes(expected), scenario + ' expected ' + expected);
  }
  console.log('Matched sampling passed timing jitter, per-file and overall regressions, and invalid timings.');
}
