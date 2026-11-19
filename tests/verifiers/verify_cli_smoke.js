'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

assert.equal(process.argv.length, 3, 'Usage: node tests/verifiers/verify_cli_smoke.js <binary>');
const binary = path.resolve(process.argv[2]);
const fixture = path.resolve(__dirname, '../fixtures/basic/001_const.js');
const parsed = spawnSync(binary, ['parse', fixture, '--json', '--compact'], { encoding: 'utf8' });
assert.equal(parsed.status, 0, parsed.stderr || String(parsed.error));
const program = JSON.parse(parsed.stdout);
assert.equal(program.type, 'Program');
assert.equal(program.body[0].kind, 'const');
assert.equal(program.body[0].declarations[0].id.name, 'x');
assert.equal(program.body[0].declarations[0].init.value, 1);
console.log('CLI parsed the smoke fixture on ' + process.platform + '-' + process.arch);
