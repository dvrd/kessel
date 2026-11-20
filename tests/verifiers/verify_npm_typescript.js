'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { createRequire } = require('node:module');

const root = path.resolve(__dirname, '../..');
const bench = createRequire(path.join(root, 'bench/package.json'));
const oracle = bench('oxc-parser');
const library = path.dirname(bench.resolve('typescript'));
const binding = path.join(root, 'npm/kessel/index.js');
const preloadKoffi = process.argv.includes('--preload-koffi');
if (preloadKoffi) createRequire(binding)('koffi').load(null);
const sdk = require(binding);
const checkCli = process.argv.includes('--cli') && !preloadKoffi;
const binary = path.join(root, 'bin', process.platform === 'win32' ? 'kessel.exe' : 'kessel');

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

// Oxc and the CLI report UTF-16 offsets. The SDK reports UTF-8 bytes.
function compareProgram(expected, actual, filename, offsets) {
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
      // The CLI also spells out the modifier on abstract class members.
      if (!offsets && key === 'abstract' && extra === true &&
          ['TSAbstractMethodDefinition', 'TSAbstractPropertyDefinition', 'TSAbstractAccessorProperty'].includes(reference.type)) continue;
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
        assert.equal(field, offsets ? offsets[value] : value, label);
      } else if (field !== undefined || (value !== null && value !== false)) {
        assert.deepEqual(field, value, label);
      }
    }
  }
  return nodes;
}

async function verifyFile(filename, source, preserveParens, cliPath) {
  const options = preserveParens === undefined ? undefined : { preserveParens };
  const reference = oracle.parseSync(filename, source, options);
  const sync = sdk.parseSync(filename, source, options);
  const asyncResult = await sdk.parseAsync(filename, source, options);
  for (const result of [reference, sync, asyncResult]) assert.deepEqual(result.errors, [], filename);
  assert.deepEqual(asyncResult.program, sync.program, filename + ' async AST');
  const nodes = compareProgram(reference.program, sync.program, filename + ' SDK', byteOffsets(source));
  if (checkCli) {
    const args = ['parse', '--json', '--compact'];
    if (preserveParens) args.push('--preserve-parens');
    const json = execFileSync(binary, [...args, cliPath], {encoding: 'utf8', maxBuffer: 128 * 1024 * 1024});
    const { comments = [], ...program } = JSON.parse(json);
    assert.deepEqual(comments, reference.comments, filename + ' CLI comments');
    compareProgram(reference.program, program, filename + ' CLI');
  }
  return nodes;
}

async function verify(directory) {
  assert.equal(bench('typescript/package.json').version, '5.9.3');
  const files = fs.readdirSync(library).filter(name => /^lib(?:\..+)?\.d\.ts$/.test(name)).sort();
  assert.equal(files.length, 100, 'Every declaration library in the pinned TypeScript package');
  let nodes = 0;
  for (const file of files) {
    const absolute = path.join(library, file);
    nodes += await verifyFile(file, fs.readFileSync(absolute, 'utf8'), undefined, absolute);
  }
  console.log('TypeScript standard library: ' + files.length + ' files, ' + nodes + ' AST nodes');
  const examples = [
    ['exports.ts', '/*🚀*/ export interface Item { id: number }\n' +
      'export type Name = string; export const café: Item = {id:1};'],
    ['imports.ts', "import { type Item, make } from 'items'; export {type Item, make}; " +
      "export type Imported = import('items').Box<number>;"],
    ['component.tsx', 'export const view = <View<string> />;'],
    ['class-index.ts', '/*🚀*/ type Entry = string; export class Table { readonly [key:string]: Entry; ' +
      'static [readonly:symbol]: number; key = "value"; }'],
    ['empty.ts', '// 🚀\n'],
  ];
  for (const [filename, source] of examples) {
    const file = path.join(directory, filename);
    if (checkCli) fs.writeFileSync(file, source);
    await verifyFile(filename, source, undefined, file);
  }
  const components = ['001_generic_component.js', '002_hooks_refs_as_casts.js'];
  for (const file of components) {
    const source = fs.readFileSync(path.join(root, 'tests/fixtures/spec/tsx', file), 'utf8');
    const filename = file.replace(/\.js$/, '.tsx');
    const tsxFile = path.join(directory, filename);
    if (checkCli) fs.writeFileSync(tsxFile, source);
    await verifyFile(filename, source, false, tsxFile);
    await verifyFile(filename, source, true, tsxFile);
  }
  console.log((checkCli ? 'CLI and both SDK APIs' : 'Both SDK APIs') + ' match Oxc for all libraries, ' + examples.length + ' focused files and both TSX components in both parentheses modes');
}

const directory = checkCli ? fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-typed-')) : '';
verify(directory).finally(() => {
  if (checkCli) fs.rmSync(directory, {recursive: true, force: true});
}).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
