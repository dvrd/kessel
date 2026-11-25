'use strict';

// Pack the oxc-resolver test inputs that the resolver reference gate replays.
//
//   node tests/runners/pack_resolver_reference.js <oxc-resolver checkout>
//
// The checkout must be at the tag of the oxc-resolver package pinned in
// bench/package.json. The output holds three kinds of input, all copied from
// upstream without expected results, because the gate asks the installed
// oxc-resolver binary for those:
//   - the fixture trees (enhanced-resolve's fixtures and oxc-resolver's own),
//   - the string literals of each Rust test file, replayed as requests,
//   - the exports and imports field tables, as manifest values and requests.

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const checkout = process.argv[2];
if (!checkout) {
  console.error('Usage: node tests/runners/pack_resolver_reference.js <oxc-resolver checkout>');
  process.exit(2);
}
const output = path.resolve(__dirname, '../verifiers/data/oxc_resolver_reference.json');
const TREES = ['abnormal-relative-with-node_modules', 'abnormal-relative-without-node_modules',
  'dot', 'enhanced-resolve', 'invalid', 'misc', 'nested-symlink', 'prefer-file-over-dir', 'tsconfig'];
const SUITES = ['alias', 'browser_field', 'builtins', 'exports_field', 'extension_alias', 'extensions',
  'fallback', 'full_specified', 'imports_field', 'incorrect_description_file', 'main_field', 'missing',
  'resolve', 'restrictions', 'roots', 'scoped_packages', 'simple', 'symlink', 'tsconfig_extends',
  'tsconfig_paths', 'tsconfig_project_references', 'tsconfig_root_dirs'];

function packTree(directory, relative, files, symlinks) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    const name = relative + '/' + entry.name;
    if (entry.isSymbolicLink()) symlinks[name] = fs.readlinkSync(absolute);
    else if (entry.isDirectory()) packTree(absolute, name, files, symlinks);
    else files[name] = fs.readFileSync(absolute).toString('base64');
  }
}

// Return the index just past the bracket that closes the one at `open`.
function closing(text, open) {
  const pairs = { '(': ')', '[': ']', '{': '}' };
  const stack = [];
  for (let index = open; index < text.length; index += 1) {
    const char = text[index];
    if (char === '"') {
      for (index += 1; text[index] !== '"'; index += 1) if (text[index] === '\\') index += 1;
    } else if (pairs[char]) {
      stack.push(pairs[char]);
    } else if (char === stack[stack.length - 1]) {
      stack.pop();
      if (stack.length === 0) return index + 1;
    }
  }
  throw new Error('unbalanced bracket at ' + open);
}

// Rust and JSON string escapes agree except for the NUL shorthand.
// A raw string (r"...") holds no escapes and is taken verbatim.
function rustString(body) {
  try {
    return JSON.parse('"' + body.replace(/\\(.)/g, (escape, char) => (char === '0' ? '\\u0000' : escape)) + '"');
  } catch {
    return body;
  }
}

function stringList(text) {
  return Array.from(text.matchAll(/"((?:[^"\\]|\\.)*)"/g), match => rustString(match[1]));
}

// Each upstream row is `TestCase { name, expect, <field>: <field>(&json!(...)), request, condition_names }`.
function fieldCases(text, field) {
  // Upstream keeps disabled rows and notes as whole-line comments.
  const source = text.replace(/^\s*\/\/.*$/gm, '');
  const cases = [];
  for (let at = source.indexOf('TestCase {', source.indexOf('fn test_cases')); at >= 0;
    at = source.indexOf('TestCase {', at + 1)) {
    const end = closing(source, source.indexOf('{', at));
    const body = source.slice(at, end);
    const jsonAt = body.indexOf('json!(');
    const jsonEnd = closing(body, jsonAt + 5);
    const manifest = JSON.parse(body.slice(jsonAt + 6, jsonEnd - 1).replace(/,(\s*[}\]])/g, '$1'));
    const rest = body.slice(0, jsonAt) + body.slice(jsonEnd);
    const expect = /expect:\s*None/.test(rest) ? null
      : stringList(rest.slice(rest.indexOf('expect:'), closing(rest, rest.indexOf('[', rest.indexOf('expect:')))));
    const conditionsAt = rest.indexOf('condition_names:');
    cases.push({
      name: JSON.parse(/name:\s*("(?:[^"\\]|\\.)*")/.exec(rest)[1]),
      request: JSON.parse(/request:\s*("(?:[^"\\]|\\.)*")/.exec(rest)[1]),
      conditions: stringList(rest.slice(conditionsAt, closing(rest, rest.indexOf('[', conditionsAt)))),
      expect,
      [field]: manifest,
    });
  }
  return cases;
}

function main() {
  const files = {};
  const symlinks = {};
  for (const tree of TREES) packTree(path.join(checkout, 'fixtures', tree), tree, files, symlinks);
  const literals = {};
  for (const suite of SUITES) {
    const source = fs.readFileSync(path.join(checkout, 'src/tests', suite + '.rs'), 'utf8');
    const tables = source.indexOf('fn test_cases');
    const prose = tables < 0 ? source : source.slice(0, tables);
    // Literals with spaces are test descriptions, not requests.
    literals[suite] = Array.from(new Set(stringList(prose).filter(text => text !== '' && !/\s/.test(text)))).sort();
  }
  const read = name => fs.readFileSync(path.join(checkout, 'src/tests', name), 'utf8');
  const packed = {
    source: {
      repository: 'https://github.com/oxc-project/oxc-resolver',
      version: JSON.parse(fs.readFileSync(path.join(checkout, 'package.json'), 'utf8')).version,
      commit: execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
      license: 'MIT, Copyright (c) 2024-present VoidZero Inc. & Contributors, Copyright (c) 2023 Boshen',
    },
    files, symlinks, literals,
    exportsCases: fieldCases(read('exports_field.rs'), 'exports'),
    importsCases: fieldCases(read('imports_field.rs'), 'imports'),
  };
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, JSON.stringify(packed) + '\n');
  console.log(`Packed ${Object.keys(files).length} files, ${Object.keys(symlinks).length} links, ` +
    `${packed.exportsCases.length} exports rows, ${packed.importsCases.length} imports rows`);
}

main();
