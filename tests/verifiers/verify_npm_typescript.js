'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

const root = path.resolve(__dirname, '../..');
const bench = createRequire(path.join(root, 'bench/package.json'));
const oracle = bench('oxc-parser');
const library = path.dirname(bench.resolve('typescript'));
const binding = path.join(root, 'npm/kessel/index.js');
if (process.argv.includes('--preload-koffi')) createRequire(binding)('koffi').load(null);
const sdk = require(binding);

function byteOffsets(source) {
  const offsets = new Uint32Array(source.length + 1);
  let units = 0;
  let bytes = 0;
  for (const character of source) {
    units += character.length;
    bytes += Buffer.byteLength(character);
    offsets[units] = bytes;
  }
  return offsets;
}

// Oxc reports UTF-16 offsets. The SDK reports UTF-8 bytes and may omit
// optional null, false, and empty-list fields from its compact records.
function compareProgram(expected, actual, source, filename) {
  const offsets = byteOffsets(source);
  const pending = [[expected, actual, 'Program']];
  let nodes = 0;
  while (pending.length) {
    const [reference, result, location] = pending.pop();
    assert.equal(result?.type, reference.type, filename + ' ' + location);
    nodes++;
    for (const key of Object.keys(result)) {
      if (Object.hasOwn(reference, key)) continue;
      const extra = result[key];
      if (extra == null || extra === false || (Array.isArray(extra) && extra.length === 0)) continue;
      assert.fail(filename + ' unexpected ' + reference.type + '@' + reference.start + '.' + key);
    }
    for (const [key, value] of Object.entries(reference)) {
      const field = result[key];
      const label = filename + ' ' + reference.type + '@' + reference.start + '.' + key;
      if (Array.isArray(value)) {
        assert.equal(field?.length ?? 0, value.length, label);
        for (let i = 0; i < value.length; i++) {
          if (value[i]?.type) pending.push([value[i], field[i], label]);
          else assert.deepEqual(field[i], value[i], label);
        }
      } else if (value?.type) {
        pending.push([value, field, label]);
      } else if (key === 'start' || key === 'end') {
        assert.equal(field, offsets[value], label);
      } else if (field !== undefined || (value !== null && value !== false)) {
        assert.deepEqual(field, value, label);
      }
    }
  }
  return nodes;
}

async function verifyFile(filename, source) {
  const reference = oracle.parseSync(filename, source);
  const sync = sdk.parseSync(filename, source);
  const asyncResult = await sdk.parseAsync(filename, source);
  for (const result of [reference, sync, asyncResult]) assert.deepEqual(result.errors, [], filename);
  assert.deepEqual(asyncResult.program, sync.program, filename + ' async AST');
  return compareProgram(reference.program, sync.program, source, filename);
}

async function verify() {
  assert.equal(bench('typescript/package.json').version, '5.9.3');
  const files = fs.readdirSync(library).filter(name => /^lib(?:\..+)?\.d\.ts$/.test(name)).sort();
  assert.equal(files.length, 100, 'Every declaration library in the pinned TypeScript package');
  let nodes = 0;
  for (const file of files) {
    nodes += await verifyFile(file, fs.readFileSync(path.join(library, file), 'utf8'));
  }
  console.log('TypeScript standard library: ' + files.length + ' files, ' + nodes + ' AST nodes');
  const examples = [
    ['exports.ts', '/*🚀*/ export interface Item { id: number }\n' +
      'export type Name = string; export const café: Item = {id:1};'],
    ['imports.ts', "import { type Item, make } from 'items'; export {type Item, make};"],
    ['component.tsx', 'export const view = <View<string> />;'],
    ['empty.ts', '// 🚀\n'],
  ];
  for (const [filename, source] of examples) await verifyFile(filename, source);
  console.log('Sync and async ASTs match for all libraries and ' + examples.length + ' focused cases');
}

verify().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
