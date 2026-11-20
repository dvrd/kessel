'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { decode } = require('../../npm/kessel/binary-reader');

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
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-cli-ast-'));
try {
  const file = path.join(folder, 'input.ts');
  const field = 'export default class { declare x: number; }';
  for (const [source, version] of [
    ['export default function() {}', 4], [field, 5],
    ['function f() {}\n' + field, 6], [field + '\nfunction f() {}', 6],
  ]) {
    fs.writeFileSync(file, source);
    const result = spawnSync(binary, ['parse', '--binary', file]);
    assert.equal(result.status, 0, String(result.stderr || result.error));
    assert.equal(result.stdout.readUInt32LE(4), version);
    const ast = decode(result.stdout, source);
    assert.deepEqual(ast.errors, []);
    if (version >= 5) {
      const cls = ast.program.body.find(node => node.type === 'ExportDefaultDeclaration').declaration;
      assert.equal(cls.id, null);
      assert.equal(cls.body.body[0].declare, true);
    }
    if (version === 6) {
      const id = ast.program.body.find(node => node.type === 'FunctionDeclaration').id;
      assert.equal(source.slice(id.start, id.end), 'f');
    }
  }

  for (const [mode, suffix] of [[[], '.json'], [['--raw'], '.bin']]) {
    const output = path.join(folder, 'nested', suffix.slice(1));
    const args = ['parse', ...mode, '--workers', '2', '--out-dir', output];
    const parse = (...files) => spawnSync(binary, [...args, ...files], { encoding: 'utf8' });
    const target = path.join(output, path.basename(file) + suffix);
    const other = path.join(output, path.basename(fixture) + suffix);

    const success = parse(file, fixture);
    assert.equal(success.status, 0, success.stderr);
    assert.ok(fs.statSync(target).size > 0);
    assert.ok(fs.statSync(other).size > 0);

    fs.unlinkSync(target);
    fs.mkdirSync(target);
    const failedWrite = parse(file, fixture);
    assert.equal(failedWrite.status, 1);
    assert.ok(failedWrite.stderr.includes(target), failedWrite.stderr);
    assert.match(failedWrite.stdout, /Files: 1\b/);
    assert.ok(fs.statSync(other).size > 0);

    const missing = path.join(folder, 'missing.js');
    const failedRead = parse(missing, fixture);
    assert.equal(failedRead.status, 1);
    assert.ok(failedRead.stderr.includes(missing), failedRead.stderr);
    assert.match(failedRead.stdout, /Files: 1\b/);
  }

  const blocked = spawnSync(binary, ['parse', file, fixture, '--out-dir', file], { encoding: 'utf8' });
  assert.equal(blocked.status, 1);
  assert.ok(blocked.stderr.includes(file), blocked.stderr);
  const singleRaw = spawnSync(binary, ['parse', file, '--raw', '--out-dir', file], { encoding: 'utf8' });
  assert.equal(singleRaw.status, 1);
  assert.ok(singleRaw.stderr.includes(file), singleRaw.stderr);
} finally { fs.rmSync(folder, { recursive: true, force: true }); }
console.log('CLI parsed the smoke fixture on ' + process.platform + '-' + process.arch);
