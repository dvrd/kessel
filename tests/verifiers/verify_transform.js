'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { SourceMap } = require('node:module');

const root = path.resolve(__dirname, '../..');
const binary = process.argv.slice(2).find(arg => arg !== '--reference') ||
  path.join(root, 'bin', process.platform === 'win32' ? 'kessel.exe' : 'kessel');
const fixtures = path.join(root, 'tests/transform');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-transform-'));

function run(command, args, input) {
  const result = spawnSync(command, args, { input, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.stdout || String(result.error));
  return result.stdout;
}

function checkReference() {
  const oracle = require('../../bench/node_modules/oxc-transform');
  const version = require('../../bench/node_modules/oxc-transform/package.json').version;
  assert.equal(version, require('../../OXC_ORACLE.json').oxc_transform_npm);
  const options = { jsx: { runtime: 'classic' } };
  for (const name of ['classic.tsx', 'classic-pragma.tsx']) {
    const source = fs.readFileSync(path.join(fixtures, name), 'utf8');
    const result = oracle.transformSync(name, source, options);
    assert.deepEqual(result.errors, []);
    run(process.execPath, ['--input-type=module'], result.code);
  }
  const samples = [
    ' ', '\t', '\n', '\r', '\r\n', '\u2028', '\u2029', '  left\nright  ',
    ' a\r\n \t \r\n b ', 'x\u2028y\u2029z', '&nbsp;\n&nbsp;', ' &lt; &amp; &gt; ',
    '&cent;&apos;&euro;&Omega;&hearts;', '&#0;&#x21;&#128578;', '&#x110000; &#xd800;',
    '&unknown; &AMP; &amp', 'stray & before &copy;', '&amp;copy;', 'a\tb', '&#+41; &#x+41;',
  ];
  const source = 'const React = { createElement: (...args) => args };\n' +
    'console.log(JSON.stringify([' + samples.map(text => '<i>' + text + '</i>').join(',') + ']));';
  const file = path.join(temp, 'text.jsx');
  fs.writeFileSync(file, source);
  const reference = oracle.transformSync(file, source, options);
  assert.deepEqual(reference.errors, []);
  const expected = run(process.execPath, ['--input-type=module'], reference.code);
  for (const flags of [[], ['--minified']]) {
    const code = run(binary, ['transform', file, '--jsx=classic', ...flags]);
    assert.equal(run(process.execPath, ['--input-type=module'], code), expected);
  }
  console.log(`OXC ${version} passed both shared runtime fixtures and matched ${samples.length} text cases in both output modes.`);
}

try {
  for (const name of fs.readdirSync(fixtures).filter(name => name.endsWith('.tsx'))) {
    for (const flags of [[], ['--minified']]) {
      const generated = run(binary, ['transform', path.join(fixtures, name), '--jsx=classic', ...flags]);
      run(process.execPath, ['--input-type=module'], generated);
    }
  }

  const probe = path.join(temp, 'probe.tsx');
  const source = 'const value: unknown =\n  <One>\n    <Two name="value">text</Two>\n  </One>;\n';
  fs.writeFileSync(probe, source);
  for (const flags of [[], ['--minified']]) {
    const generated = run(binary, ['transform', probe, '--jsx=classic', '--jsx-pragma=app.create', '--sourcemap', ...flags]);
    assert.match(generated, /[#@]__PURE__/);
    const [code, base64] = generated.split('//# sourceMappingURL=data:application/json;base64,');
    const payload = JSON.parse(Buffer.from(base64.trim(), 'base64').toString());
    assert.deepEqual(payload.sourcesContent, [source]);
    const map = new SourceMap(payload);
    const calls = [...code.matchAll(/app\.create/g)];
    assert.equal(calls.length, 2);
    const probes = [[calls[0].index, 1, 2], [calls[1].index, 2, 4],
      [code.indexOf('"name"'), 2, 9], [code.indexOf('"value"'), 2, 14], [code.indexOf('"text"'), 2, 22]];
    for (const [offset, sourceLine, sourceColumn] of probes) {
      assert.ok(offset >= 0);
      const prefix = code.slice(0, offset).split('\n');
      const entry = map.findEntry(prefix.length - 1, prefix.at(-1).length);
      assert.deepEqual([entry.originalLine, entry.originalColumn], [sourceLine, sourceColumn]);
    }
    const preserve = run(binary, ['transform', probe, ...flags]);
    assert.match(preserve, /<One>/);
    assert.doesNotMatch(preserve, /unknown/);
  }

  fs.writeFileSync(probe, 'export default <svg:path xml:lang="en" />;');
  const bad = spawnSync(binary, ['transform', probe, '--jsx=classic'], { encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.equal(bad.stdout, '');
  assert.match(bad.stderr, /namespace tags/);
  const allowed = run(binary, ['transform', probe, '--jsx=classic', '--jsx-allow-namespaces', '--jsx-no-pure']);
  assert.match(allowed, /createElement\("svg:path", \{ "xml:lang": "en" \}\)/);
  assert.doesNotMatch(allowed, /__PURE__/);
  fs.writeFileSync(probe, 'const h = (tag, props) => props; const p = <tag __proto__={{ x: 1 }} />;\n' +
    'if (!Object.hasOwn(p, "__proto__") || p.x !== undefined) throw Error("JSX attribute lost");');
  run(process.execPath, ['--input-type=module'], run(binary, ['transform', probe, '--jsx=classic', '--jsx-pragma=h']));
  const invalid = spawnSync(binary, ['transform', probe, '--jsx-pragma=a..b'], { encoding: 'utf8' });
  assert.equal(invalid.status, 2);
  fs.writeFileSync(probe, 'export const value = <C key />;');
  const key = spawnSync(binary, ['transform', probe, '--jsx=classic'], { encoding: 'utf8' });
  assert.equal(key.status, 1);
  assert.match(key.stderr, /key requires a value/);
  console.log('Classic JSX runtime, pragmas, namespace bindings, diagnostics, and source maps passed.');
  const oracle = process.argv.includes('--reference') ? require('../../bench/node_modules/oxc-transform') : undefined;
  const modulePragma = path.join(temp, 'module-pragma.tsx');
  const pragmaSource = '/** @jsx import.meta.h @jsxFrag import.meta.fragment */\n' +
    'import.meta.h = function(tag, props, ...children) { if (this !== import.meta) throw Error("receiver"); return [tag, ...children]; };\n' +
    'import.meta.fragment = "frag"; console.log(JSON.stringify(<><span/></>));';
  fs.writeFileSync(modulePragma, pragmaSource);
  for (const flags of [[], ['--minified']]) {
    const result = run(binary, ['transform', modulePragma, '--jsx=classic', ...flags]);
    assert.equal(run(process.execPath, ['--input-type=module'], result).trim(), '["frag",["span"]]');
  }
  if (oracle) {
    const reference = oracle.transformSync(modulePragma, pragmaSource, { jsx: { runtime: 'classic' } });
    assert.deepEqual(reference.errors, []);
    assert.equal(run(process.execPath, ['--input-type=module'], reference.code).trim(), '["frag",["span"]]');
  }
  for (const invalid of ['import', 'import.metaX', 'import.other', 'import.meta..prop']) {
    assert.equal(spawnSync(binary, ['transform', modulePragma, '--jsx-pragma=' + invalid]).status, 2);
  }
  require('./verify_transform_automatic')(binary, temp, run, oracle);
  require('./verify_transform_defines')(binary, temp, run, oracle);
  require('./verify_transform_enums')(binary, temp, run, oracle);
  require('./verify_transform_resources')(binary, temp, run, oracle);
  require('./verify_transform_decorators')(binary, temp, run, oracle);
  if (process.argv.includes('--reference')) checkReference();
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
