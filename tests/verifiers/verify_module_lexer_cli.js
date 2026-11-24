'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-module-lexer-cli-'));
const executable = process.platform === 'win32' ? 'kessel.exe' : 'kessel';
const binary = path.resolve(__dirname, '../../bin', executable);

try {
  const file = path.join(dir, 'module.js');
  const source = Buffer.from([
    "/* π */ import label from 'π';",
    'export { label as primary };',
    "export const [first, { value: nested }] = input, total = 2;",
    "export { default as external } from './other.js';",
    "const later = import('./lazy.js');",
  ].join('\n'));
  fs.writeFileSync(file, source);
  const result = spawnSync(binary, ['module-lex', file], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || String(result.error));
  const value = JSON.parse(result.stdout);
  assert.equal(value.has_module_syntax, true);
  assert.deepEqual(value.dependencies.map(entry => [entry.kind, entry.name]), [
    ['Static', 'π'],
    ['Reexport', './other.js'],
    ['Dynamic', './lazy.js'],
  ]);
  const span = value.dependencies[0].request;
  assert.equal(source.subarray(span.start, span.end).toString(), 'π');
  assert.deepEqual(value.exports.map(entry => [entry.name, entry.local_name]), [
    ['primary', 'label'],
    ['first', 'first'],
    ['nested', 'nested'],
    ['total', 'total'],
    ['external', null],
  ]);
  const local = value.exports[0].local_span;
  assert.equal(source.subarray(local.start, local.end).toString(), 'label');

  // The bundler reads these records: the original fields must stay first and
  // unchanged, with the es-module-lexer equivalents appended after them.
  assert.deepEqual(Object.keys(value), [
    'dependencies', 'exports', 'has_module_syntax', 'facade', 'has_commonjs_syntax', 'format',
  ]);
  assert.deepEqual(Object.keys(value.dependencies[0]), [
    'kind', 'phase', 'statement', 'request', 'attributes', 'type_only', 'name',
    'import_type', 'clause_end', 'arguments_start', 'attribute_entries',
  ]);
  assert.deepEqual(Object.keys(value.exports[0]), [
    'name', 'span', 'local_name', 'local_span', 'type_only', 'name_is_string', 'local_is_string',
  ]);
  const [declared, , called] = value.dependencies;
  const slice = (start, end) => source.subarray(start, end).toString();
  assert.equal(declared.import_type, 'Static');
  assert.equal(slice(declared.statement.start, declared.statement.end), "import label from 'π';");
  assert.equal(slice(declared.statement.start, declared.clause_end), "import label from 'π'");
  assert.equal(declared.arguments_start, null);
  assert.equal(called.import_type, 'Dynamic');
  assert.equal(slice(called.arguments_start, called.clause_end), "('./lazy.js')");
  assert.deepEqual([value.facade, value.has_commonjs_syntax, value.format], [false, false, 'ESM']);

  function scan(source) {
    fs.writeFileSync(file, source);
    const result = spawnSync(binary, ['module-lex', file], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  }
  const reserved = scan('const value = 1; export { value as null, value as true, value as false, value as type, value as interface, value as enum };');
  assert.deepEqual(reserved.exports.map(entry => entry.name), ['null', 'true', 'false', 'type', 'interface', 'enum']);
  const ambiguous = scan(String.raw`if (ok) {} else /[0-9](?:\s|\/)/.test(text);
    do /import('hidden')/.test(text); while (ok);
    const ratio = object.else / import('else-divisor') / total;
    const called = object.if(ok) / import('call-divisor') / total;
    const guarded = object?.if(ok) / import('optional-divisor') / total;
    import('visible');`);
  assert.deepEqual(ambiguous.dependencies.map(entry => entry.name), ['else-divisor', 'call-divisor', 'optional-divisor', 'visible']);
  const attributed = scan("import data from './data.json'\nwith { type: 'json' };\n" +
    "export { data as 'string name' };");
  assert.deepEqual(attributed.dependencies[0].attribute_entries.map(pair => [pair.key, pair.value]),
    [['type', 'json']]);
  assert.equal(attributed.exports[0].name_is_string, true);
  assert.equal(attributed.facade, true);
  const commonjs = scan("module.exports = require('./dependency.js');");
  assert.deepEqual([commonjs.has_module_syntax, commonjs.has_commonjs_syntax, commonjs.format],
    [false, true, 'CJS']);
  assert.equal(scan('compute();').format, 'Unknown');
  fs.writeFileSync(file, "import('missing closing parenthesis'");
  const invalid = spawnSync(binary, ['module-lex', file], { encoding: 'utf8' });
  assert.equal(invalid.status, 1);
  assert.match(invalid.stderr, /Invalid_Syntax/);
  console.log('Module lexer CLI passed UTF-8 span, import, export, reference field, and error cases');
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
