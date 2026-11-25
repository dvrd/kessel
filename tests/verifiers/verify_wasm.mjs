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

let comparedTrees = 0;
function compare(language, source, semanticErrors) {
  comparedTrees++;
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

// Run the CLI on a copy of the input inside the scratch directory, where no
// project configuration can reach it.
function runCli(command, name, source, flags = []) {
  const filename = path.join(directory, name);
  fs.writeFileSync(filename, source);
  const result = spawnSync(cli, [command, filename, ...flags], {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
  if (result.error) throw result.error;
  assert.equal(result.signal, null, command + ' ' + name);
  return result;
}

// A tool that prints code must print the CLI's bytes, and must report an
// error exactly when the CLI exits with one.
function compareGenerated(command, name, source, flags, produced) {
  const native = runCli(command, name, source, flags);
  const label = [command, name, ...flags].join(' ');
  if (native.status === 0) {
    assert.deepEqual(produced.errors, [], label);
    assert.equal(produced.code, native.stdout, label);
    return true;
  }
  assert.ok(produced.errors.length > 0, label + ' fails natively: ' + native.stderr);
  const report = native.stdout + native.stderr;
  for (const error of produced.errors) assert.ok(report.includes(error.message), label + ': ' + error.message);
  return false;
}

// The CLI's ESLint-style report names rules without their plugin and counts
// lines and columns in UTF-8 bytes, as the binding's positions do. It goes to
// standard error when a diagnostic is an error, and gives a parser
// diagnostic the position where it starts but no extent.
function compareLint(name, language, source, flags = [], rules = undefined) {
  const native = runCli('lint', name, source, ['--format=json', ...flags]);
  const [{messages}] = JSON.parse(native.stdout || native.stderr);
  const {diagnostics} = parser.lint(source, {language, rules});
  const comparable = diagnostics.map(d => ({
    ruleId: d.rule ? d.rule.slice(d.rule.lastIndexOf('/') + 1) : null,
    severity: d.severity === 'error' ? 2 : 1, message: d.message, line: d.line, column: d.column,
    endLine: d.rule ? d.endLine : d.line, endColumn: d.rule ? d.endColumn : d.column,
  }));
  assert.deepEqual(comparable, messages.map(({ruleId, severity, message, line, column, endLine, endColumn}) =>
    ({ruleId: ruleId ?? null, severity, message, line, column, endLine, endColumn})), 'lint ' + name);
  return diagnostics.length;
}

function listFiles(folder, pattern) {
  return fs.readdirSync(path.join(root, folder), {recursive: true})
    .filter(name => pattern.test(name)).sort().map(name => path.join(folder, name));
}

// Every pinned real-world file that fits the input limit goes through lint,
// transform (unchanged target and ES2015) and minify, and must come out as
// the native CLI prints it. Larger files must be refused with the size error.
function compareCorpus() {
  const counts = {files: 0, oversized: 0, diagnostics: 0, lowered: 0, refused: 0};
  for (const file of listFiles('bench/real_world', /\.m?js$/)) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    if (Buffer.byteLength(source) > parser.inputLimit) {
      for (const tool of ['lint', 'transform', 'minify', 'declaration']) {
        assert.throws(() => parser[tool](source, {language: 'js'}), RangeError, tool + ' ' + file);
      }
      counts.oversized++;
      continue;
    }
    const name = 'corpus' + path.extname(file);
    counts.files++;
    counts.diagnostics += compareLint(name, 'js', source);
    compareGenerated('transform', name, source, [], parser.transform(source, {language: 'js'}));
    const lowered = compareGenerated('transform', name, source, ['--target=es2015'],
      parser.transform(source, {language: 'js', target: 'es2015'}));
    counts[lowered ? 'lowered' : 'refused']++;
    compareGenerated('minify', name, source, [], parser.minify(source, {language: 'js'}));
  }
  return counts;
}

// The pinned corpus is JavaScript. Typed and JSX fixtures cover what the
// transformer and the declaration emitter exist for.
function compareTypedFixtures() {
  // The spec fixtures are named .js whatever they contain; their folder
  // gives the language. The others carry it in their extension.
  const folders = [
    ['tests/fixtures/spec/typescript', /\.(js|ts)$/, 'ts'], ['tests/fixtures/spec/tsx', /\.js$/, 'tsx'],
    ['tests/fixtures/spec/jsx', /\.js$/, 'jsx'], ['tests/strip-types/pass', /\.ts$/, undefined],
    ['tests/transform', /\.tsx?$/, undefined],
  ];
  const inputs = folders.flatMap(([folder, pattern, language]) =>
    listFiles(folder, pattern).map(file => [file, language ?? path.extname(file).slice(1)]));
  const counts = {files: 0, declarations: 0};
  for (const [file, language] of inputs) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const name = 'typed.' + language;
    counts.files++;
    compareLint(name, language, source);
    for (const flags of [[], ['--target=es2017'], ['--jsx=automatic'], ['--jsx=classic', '--target=es2015']]) {
      const options = {language};
      for (const flag of flags) {
        const [key, value] = flag.slice(2).split('=');
        options[key] = value;
      }
      compareGenerated('transform', name, source, flags, parser.transform(source, options));
    }
    compareGenerated('minify', name, source, [], parser.minify(source, {language}));
    if (language === 'jsx') continue;
    if (compareGenerated('dts', name, source, [], parser.declaration(source, {language}))) counts.declarations++;
  }
  return counts;
}

function checkTools() {
  // Regexp literals with exactly one of the `u` and `v` flags are judged by
  // the regexp grammar, which needs scratch memory: this target once stopped
  // on its first such literal.
  const patterns = ['/(?<n>a)\\k<n>/u', '/[\\p{L}--\\p{Lu}]/v', '/\\p{Nope}/u', '/(?<a>.)(?<a>.)/u', '/a{2,1}/u',
    '/(/u', '/(?<=a)+/u', '/' + '(?:a|[b-d]\\d)'.repeat(2000) + '/v'];
  for (const pattern of patterns) {
    for (const semanticErrors of [false, true]) compare('js', 'x = ' + pattern + ';', semanticErrors);
  }
  assert.equal(compareLint('regexp.js', 'js', 'x = /[\\u{1F680}-\\u{1F600}]/u; y = /a  b/u; z = /[]\\x00/u;'), 4);

  const unicode = '/*🚀é*/ debugger;\r\n/*a*/\u2028 debugger;\rif (a == b) { x = {then() {}}; }\n';
  assert.equal(compareLint('unicode.js', 'js', unicode), 3);
  const rules = {'unicorn/no-thenable': 'error', eqeqeq: ['warn', 'always'], 'no-debugger': 'off', 'no-empty-function': 0};
  const flags = ['--rule', 'unicorn/no-thenable:error', '--rule', 'eqeqeq:warn', '--rule', 'no-debugger:off',
    '--rule', 'no-empty-function:off'];
  assert.equal(compareLint('unicode.js', 'js', unicode, flags, rules), 2);
  assert.deepEqual(parser.lint(unicode, {rules}).diagnostics.map(d => [d.code, d.rule, d.severity, d.start, d.end]),
    [['L1003', 'eqeqeq', 'warning', 47, 49], ['L6006', 'unicorn/no-thenable', 'error', 60, 64]]);
  const broken = parser.lint('const 🚀 = ;');
  assert.ok(broken.diagnostics.length > 0);
  assert.ok(broken.diagnostics.every(d => /^K\d{4}$/.test(d.code) && d.rule === undefined && d.line === 1));
  assert.throws(() => parser.lint('x', {rules: {'no-debugger': 'loud'}}), TypeError);
  assert.throws(() => parser.lint('x', {rules: []}), TypeError);
  assert.throws(() => parser.lint('x', {rules: {['a'.repeat(parser.optionsLimit)]: 'off'}}), RangeError);

  const component = 'type Props = { name?: string };\nexport const Greeting = ({ name }: Props) => ' +
    '<b title="🚀">{name ?? "you"}</b>;\nexport class Counter { count = 0; static #made = 0; }\n';
  for (const flags of [['--jsx=automatic'], ['--jsx=classic', '--target=es2015'], ['--jsx=automatic', '--target=es2020']]) {
    const options = {language: 'tsx'};
    for (const flag of flags) options[flag.slice(2).split('=')[0]] = flag.split('=')[1];
    assert.ok(compareGenerated('transform', 'component.tsx', component, flags, parser.transform(component, options)));
  }
  assert.match(parser.transform(component, {language: 'tsx', jsx: 'automatic', target: 'es2015'}).code,
    /react\/jsx-runtime[^]*name !== null && name !== void 0 \? name : "you"/);
  assert.doesNotMatch(parser.transform(component, {language: 'tsx'}).code, /Props|: string/);
  const failed = parser.transform('/*é*/ const = ;');
  assert.equal(failed.code, '');
  assert.deepEqual([failed.errors[0].start, failed.errors[0].line, failed.errors[0].column], [13, 1, 14]);
  assert.throws(() => parser.transform('x', {target: 'es5'}), TypeError);
  assert.throws(() => parser.transform('x', {jsx: 'react'}), TypeError);
  assert.throws(() => parser.transform('x', {minified: 1}), TypeError);

  const library = 'export function total(firstValue, secondValue) { const sum = firstValue + secondValue; ' +
    'if (false) { unreachable(); } return sum * 2 ** 10; }\n';
  assert.ok(compareGenerated('minify', 'library.mjs', library, [], parser.minify(library)));
  assert.ok(compareGenerated('minify', 'library.mjs', library, ['--no-mangle'], parser.minify(library, {mangle: false})));
  assert.ok(compareGenerated('minify', 'library.mjs', library, ['--no-compress'], parser.minify(library, {compress: false})));
  assert.ok(compareGenerated('minify', 'library.mjs', library, ['--mangle-names'], parser.minify(library, {mangleNames: true})));
  assert.ok(parser.minify(library).code.length < library.length / 2);
  assert.doesNotMatch(parser.minify(library).code, /unreachable|firstValue/);
  assert.throws(() => parser.minify('x', {mangle: 'all'}), TypeError);

  const model = 'export interface Point { x: number; y: number }\n' +
    'export function scale(point: Point, by: number): Point { return { x: point.x * by, y: point.y * by }; }\n' +
    'export const origin: Point = { x: 0, y: 0 };\nconst hidden = 1;\n';
  assert.ok(compareGenerated('dts', 'model.ts', model, [], parser.declaration(model)));
  assert.match(parser.declaration(model).code, /export declare function scale\(point: Point, by: number\): Point;/);
  assert.doesNotMatch(parser.declaration(model).code, /hidden/);
  const inferred = parser.declaration('/*é*/ export function untyped(a: number) { return a; }\n');
  assert.deepEqual(inferred.errors.map(e => [e.code, e.line]), [['TS9007', 1]]);
  assert.equal(parser.declaration('export const a = 1;', {language: 'js'}).errors[0].code, 'Unsupported_Input');
}

function checkReusedMemory() {
  const wasi = new WASI({version: 'preview1', args: [], env: {}, preopens: {}, returnOnExit: true});
  const instance = new WebAssembly.Instance(module, {wasi_snapshot_preview1: wasi.wasiImport, env: {pow: Math.pow}});
  wasi.start(instance);
  const api = instance.exports;
  const source = new TextEncoder().encode('/*' + 'é'.repeat(12000) + '*/ const answer = 42;');
  new Uint8Array(api.memory.buffer, api.input_address(), source.length).set(source);
  // Unicode requires a per-byte coordinate table. Repeated identical inputs
  // must reuse the space for that table, the parser arena and the JSON result.
  function parseAndFormat() {
    assert.ok(api.parse_source(source.length, 0, 0) > 0);
    assert.ok(api.format_source(source.length, 0, 80, 2, 0, 0, 1, 1, 0) > 0);
    assert.ok(api.lint_source(source.length, 0, 0) > 0);
    assert.ok(api.transform_source(source.length, 0, 0) > 0);
    assert.ok(api.minify_source(source.length, 0, 0) > 0);
    assert.ok(api.declaration_source(source.length, 2) > 0);
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
  checkTools();
  const typed = compareTypedFixtures();
  const corpus = compareCorpus();
  console.log('WASM matched native ASTs and diagnostics in ' + comparedTrees +
    ' comparisons and passed ' + formatting.length + ' formatter fixtures, UTF-8 limits, isolation and repeated calls.');
  console.log('WASM lint, transform and minify matched the CLI on ' + corpus.files + ' pinned files (' +
    corpus.diagnostics + ' lint diagnostics, ' + corpus.lowered + ' lowered to ES2015 and ' + corpus.refused +
    ' refused alike) and refused ' + corpus.oversized + ' oversized files; ' + typed.files +
    ' typed and JSX fixtures matched in lint, transform and minify, ' + typed.declarations +
    ' of them with a declaration file.');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}
