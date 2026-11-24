import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WASI } from 'node:wasi';
import { createParser } from '../../bin/playground/parser.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const cli = path.join(root, 'bin', process.platform === 'win32' ? 'kessel.exe' : 'kessel');
const module = await WebAssembly.compile(fs.readFileSync(path.join(root, 'bin/playground/kessel.wasm')));
const parser = createParser(module);
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-wasm-'));
const fixture = file => fs.readFileSync(path.join(root, 'tests', file), 'utf8');

function compare(language, source, semanticErrors) {
  const filename = path.join(directory, 'input.' + language);
  fs.writeFileSync(filename, source);
  const args = ['parse', filename, '--json', '--compact', '--range', '--loc'];
  if (semanticErrors) args.push('--show-semantic-errors');
  const result = spawnSync(cli, args, {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
  if (result.error) throw result.error;
  assert.ok(result.stdout, result.stderr);
  const expected = JSON.parse(result.stdout);
  assert.deepEqual(parser.parse(source, {language, semanticErrors}), expected);
}

function checkReusedMemory() {
  const wasi = new WASI({version: 'preview1', args: [], env: {}, preopens: {}, returnOnExit: true});
  const instance = new WebAssembly.Instance(module, {wasi_snapshot_preview1: wasi.wasiImport});
  wasi.start(instance);
  const api = instance.exports;
  const source = new TextEncoder().encode('/*' + 'é'.repeat(12000) + '*/ const answer = 42;');
  new Uint8Array(api.memory.buffer, api.input_address(), source.length).set(source);
  // Unicode requires a per-byte coordinate table. Repeated identical inputs
  // must reuse the space for that table, the parser arena and the JSON result.
  function parseAndFormat() {
    assert.ok(api.parse_source(source.length, 0, 0) > 0);
    assert.ok(api.format_source(source.length, 0, 80, 2, 0, 0, 1, 1, 0) > 0);
  }
  for (let i = 0; i < 8; i++) parseAndFormat();
  const warmed = api.memory.buffer.byteLength;
  for (let i = 0; i < 96; i++) parseAndFormat();
  assert.equal(api.memory.buffer.byteLength, warmed);
}

try {
  const cases = [
    ['js', fixture('fixtures/basic/001_const.js')],
    ['js', fixture('fixtures/spec/unicode/006_mixed_script.js')],
    ['js', fixture('coverage/misc/pass/kessel-default-function-followed-by-expression.mjs')],
    ['js', '#!/usr/bin/env node\r\n/* 🚀 */ const café = "é";\r\n'],
    ['jsx', 'const el = <p lang="es">🌎</p>;'],
    ['ts', fixture('fixtures/spec/typescript/099_ts_forms_audit.ts')],
    ['tsx', 'type Props = { n: number }; const el = (p: Props) => <b>{p.n}</b>;'],
    ['js', 'break;'],
    ['tsx', 'const el = <div>;'],
    ['js', ''],
  ];
  for (const [language, source] of cases) {
    for (const semanticErrors of [false, true]) compare(language, source, semanticErrors);
  }

  // Include syntactically valid inputs on either side of the UTF-8 byte limit.
  const exact = '/*' + 'é'.repeat((parser.inputLimit - 4) / 2) + '*/';
  assert.equal(Buffer.byteLength(exact), parser.inputLimit);
  assert.equal(parser.parse(exact).errors, undefined);
  assert.throws(() => parser.parse(exact + ' '), RangeError);
  assert.throws(() => parser.parse(' '.repeat(parser.inputLimit + 1)), RangeError);
  assert.throws(() => parser.parse('x', {language: 'css'}), TypeError);
  assert.throws(() => parser.parse('x', {semanticErrors: 1}), TypeError);
  assert.throws(() => parser.parse(42), TypeError);
  const formatting = [...JSON.parse(fixture('format/modules.json')), ...JSON.parse(fixture('format/data.json'))];
  for (const {name, source, options, expected} of formatting) {
    const settings = {language: 'ts', ...options};
    assert.equal(parser.format(source, settings), expected, name);
    assert.equal(parser.format(expected, settings), expected, name);
  }
  assert.equal(parser.format("import'x';", {endOfLine:'crlf'}), 'import "x";\r\n');
  assert.equal(parser.format(exact), exact);
  assert.equal(parser.format(''), '');
  assert.throws(() => parser.format(exact + ' '), RangeError);
  assert.throws(() => parser.format('x', {tabWidth:17}), RangeError);
  assert.throws(() => parser.format('x', {printWidth:0}), RangeError);
  assert.throws(() => parser.format('x', {endOfLine:'bad'}), TypeError);
  assert.throws(() => parser.format('x', {useTabs:1}), TypeError);
  assert.throws(() => parser.format('const 🚀 = ;'), error =>
    error instanceof SyntaxError && error.code === 'Invalid_Syntax' && Number.isInteger(error.offset));
  assert.equal(parser.format("export*from'./🚀';", {singleQuote:true}), "export * from './🚀';\n");

  const next = createParser(module);
  const first = parser.parse('const original = "🚀";');
  next.parse('const fromOtherInstance = true;');
  for (let i = 0; i < 50; i++) parser.parse('/* é */ const subsequent = true;');
  assert.equal(first.body[0].declarations[0].id.name, 'original');
  assert.equal(first.body[0].declarations[0].init.value, '🚀');
  checkReusedMemory();
  console.log('WASM matched native ASTs and diagnostics in ' + cases.length * 2 +
    ' comparisons and passed ' + formatting.length + ' formatter fixtures, UTF-8 limits, isolation and repeated calls.');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}
