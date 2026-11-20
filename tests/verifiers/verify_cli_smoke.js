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
function checkClassIndexSignatures(file) {
  const source = 'export class Table { readonly [key: string]: number; static [id: symbol]: string; field = 1; }';
  fs.writeFileSync(file, source);
  const json = spawnSync(binary, ['parse', file, '--json'], {encoding: 'utf8'});
  assert.equal(json.status, 0, json.stderr);
  const members = JSON.parse(json.stdout).body[0].declaration.body.body;
  assert.deepEqual(members.map(m => m.type), ['TSIndexSignature', 'TSIndexSignature', 'PropertyDefinition']);
  assert.deepEqual(members.slice(0, 2).map(m =>
    [m.parameters[0].name, m.parameters[0].typeAnnotation.typeAnnotation.type,
      m.typeAnnotation.typeAnnotation.type, m.readonly, m.static]), [
    ['key', 'TSStringKeyword', 'TSNumberKeyword', true, false],
    ['id', 'TSSymbolKeyword', 'TSStringKeyword', false, true],
  ]);
  const result = spawnSync(binary, ['strip-types', file], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), 'export class Table {\n  field = 1;\n}');
}

function parseBinary(file, source, expectedVersion) {
  fs.writeFileSync(file, source);
  const result = spawnSync(binary, ['parse', '--binary', file]);
  assert.equal(result.status, 0, String(result.stderr || result.error));
  assert.equal(result.stdout.readUInt32LE(4), expectedVersion, file);
  const ast = decode(result.stdout, source);
  assert.deepEqual(ast.errors, []);
  return ast.program.body;
}

const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-cli-ast-'));
try {
  const file = path.join(folder, 'input.ts');
  checkClassIndexSignatures(file);
  const jsFile = path.join(folder, 'input.js');
  const plain = 'export default function() {}';
  const [jsDefault] = parseBinary(jsFile, plain, 4);
  assert.equal(Object.hasOwn(jsDefault, 'exportKind'), false);
  const [jsNamed] = parseBinary(jsFile, 'function f() {}', 6);
  assert.equal(jsNamed.id.name, 'f');
  const [tsDefault] = parseBinary(file, plain, 8);
  assert.equal(tsDefault.exportKind, 'value');

  const field = 'export default class { declare x; }';
  const typed = 'export default class { declare x: number; } function after() {}';
  for (const source of [field, typed, 'function f() {}\n' + field, field + '\nfunction f() {}']) {
    const body = parseBinary(file, source, 8);
    const exported = body.find(node => node.type === 'ExportDefaultDeclaration');
    assert.equal(exported.exportKind, 'value');
    assert.equal(exported.declaration.id, null);
    const member = exported.declaration.body.body[0];
    assert.equal(member.declare, true);
    if (source === typed) assert.equal(member.typeAnnotation.typeAnnotation.type, 'TSNumberKeyword');
    if (source !== field) {
      const {id} = body.find(node => node.type === 'FunctionDeclaration');
      assert.equal(source.slice(id.start, id.end), source === typed ? 'after' : 'f');
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
