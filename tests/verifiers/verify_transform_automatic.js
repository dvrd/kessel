'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { SourceMap } = require('node:module');

module.exports = function checkAutomatic(binary, temp, run, oracle) {
  const pkg = path.join(temp, 'node_modules/layout');
  fs.mkdirSync(pkg, { recursive: true });
  fs.writeFileSync(path.join(pkg, 'package.json'), JSON.stringify({
    name: 'layout', exports: {
      '.': './index.cjs', './jsx-runtime': './jsx-runtime.cjs', './jsx-dev-runtime': './jsx-dev-runtime.cjs',
    },
  }));
  fs.writeFileSync(path.join(pkg, 'jsx-runtime.cjs'), `
    (globalThis.loads ||= []).push("runtime");
    exports.Fragment = "Fragment";
    exports.jsx = (tag, props, key) => ({ helper: "jsx", tag, props, key });
    exports.jsxs = (tag, props, key) => ({ helper: "jsxs", tag, props, key });
  `);
  fs.writeFileSync(path.join(pkg, 'index.cjs'), `
    (globalThis.loads ||= []).push("root");
    exports.createElement = (tag, props, ...children) => globalThis.recordClassic ? globalThis.recordClassic(tag, props) : ({
      helper: "createElement", tag, props: { ...props, children: children[0] }, key: props.key,
    });
  `);
  fs.writeFileSync(path.join(pkg, 'jsx-dev-runtime.cjs'), `
    exports.Fragment = "fragment";
    exports.jsxDEV = function (tag, props, key, multiple, source, self) {
      return globalThis.recordDev(tag, key, multiple, source, arguments.length === 6, self);
    };
  `);
  fs.writeFileSync(path.join(temp, 'before.cjs'), '(globalThis.loads ||= []).push("before");');
  fs.writeFileSync(path.join(temp, 'after.cjs'), '(globalThis.loads ||= []).push("after");');
  const fixture = fs.readFileSync(path.join(__dirname, '../transform/automatic/elements.tsx'), 'utf8');
  const input = path.join(temp, 'automatic.tsx');
  for (const esm of [false, true]) {
    const prelude = '"use client";\n' + (esm ? 'import "./before.cjs";\n' : '');
    const source = prelude + fixture + (esm ? '\nimport "./after.cjs"; export {};\n' : '');
    fs.writeFileSync(input, source);
    const output = path.join(temp, esm ? 'runtime.mjs' : 'runtime.cjs');
    function execute(code) {
      fs.writeFileSync(output, code);
      return run(process.execPath, [output]);
    }
    let expected;
    if (oracle) {
      const result = oracle.transformSync(input, source, { sourceType: 'unambiguous', jsx: { runtime: 'automatic', importSource: 'layout' } });
      assert.deepEqual(result.errors, []);
      expected = execute(result.code);
    }
    for (const flags of [[], ['--minified']]) {
      const generated = run(binary, ['transform', input, '--jsx=automatic', '--jsx-import-source=layout', '--sourcemap', ...flags]);
      assert.ok(generated.startsWith('"use client";'));
      const actual = execute(generated);
      if (oracle) assert.equal(actual, expected);
      assert.deepEqual(JSON.parse(actual)[0], esm ? ['before', 'runtime', 'root', 'after'] : ['root', 'runtime']);
      const [code, encoded] = generated.split('//# sourceMappingURL=data:application/json;base64,');
      const map = new SourceMap(JSON.parse(Buffer.from(encoded.trim(), 'base64')));
      const marker = '"title"';
      const position = code.indexOf(marker);
      assert.ok(position > 0);
      const lines = code.slice(0, position).split('\n');
      const entry = map.findEntry(lines.length - 1, lines.at(-1).length);
      const original = source.slice(0, source.indexOf('title={')).split('\n');
      assert.deepEqual([entry.originalLine, entry.originalColumn], [original.length - 1, original.at(-1).length]);
    }
  }
  fs.writeFileSync(input, '/** @jsxImportSource layout */\n/** @jsxRuntime automatic */\nconst x = <i/>;');
  assert.match(run(binary, ['transform', input, '--jsx=classic']), /require\("layout\/jsx-runtime"\)/);
  fs.writeFileSync(input, '/** @jsxRuntime classic */\nconst x = <i/>;');
  assert.match(run(binary, ['transform', input, '--jsx=automatic']), /React\.createElement\(/);
  fs.writeFileSync(input, 'import type { T } from "types"; export declare const a: T;');
  assert.doesNotMatch(run(binary, ['transform', input, '--jsx=automatic']), /jsx-runtime/);
  for (const prelude of ['"use client";', 'import "./before.cjs";']) {
    fs.writeFileSync(input, prelude + ' // trailing\n// @ts-expect-error\nconst x = <i/>;');
    const code = run(binary, ['transform', input, '--jsx=automatic']);
    assert.ok(code.indexOf('// trailing') < code.indexOf('jsx-runtime'));
    assert.match(code, /jsx-runtime[^\n]*\n\/\/ @ts-expect-error\nconst x/);
  }
  fs.writeFileSync(input, '// @ts-check\n/** docs for x */\nconst x = <i/>;');
  const header = run(binary, ['transform', input, '--jsx=automatic']);
  assert.match(header, /^\/\/ @ts-check\n[^\n]*jsx-runtime[^\n]*\n\/\*\* docs for x \*\/\nconst x/);
  console.log('Automatic JSX passed in scripts and modules, including runtime import order, keys, children, and mappings.');
  checkDevelopment(binary, temp, run, oracle);
};

function checkDevelopment(binary, temp, run, oracle) {
  const input = path.join(temp, 'development.tsx');
  const fixture = fs.readFileSync(path.join(__dirname, '../transform/development/elements.tsx'), 'utf8');
  for (const esm of [false, true]) {
    const source = '"use client";\r\n/* location */\u2028' + fixture + (esm ? '\nexport {};\n' : '');
    fs.writeFileSync(input, source);
    const output = path.join(temp, esm ? 'development.mjs' : 'development.cjs');
    function execute(code) {
      fs.writeFileSync(output, code);
      return JSON.parse(run(process.execPath, [output]));
    }
    for (const runtime of ['classic', 'automatic']) {
      const automatic = runtime === 'automatic';
      let expected;
      if (oracle) {
        const jsx = { runtime, development: true };
        if (automatic) jsx.importSource = 'layout';
        const result = oracle.transformSync(input, source, { sourceType: 'unambiguous', jsx });
        assert.deepEqual(result.errors, []);
        expected = execute(result.code);
      }
      for (const flags of [[], ['--minified']]) {
        const code = run(binary, ['transform', input, '--jsx=' + runtime, '--jsx-development', '--jsx-import-source=layout', ...flags]);
        assert.ok(code.startsWith('"use client";'));
        const records = execute(code);
        if (oracle) assert.deepEqual(records, expected);
        const byTag = new Map(records.map(record => [record[0], record]));
        assert.deepEqual([...byTag.keys()], [
          'unicode', 'one', 'two', 'fragment', 'fallback', 'parameter', 'arrow', 'before', 'own', 'after', 'block', 'field', 'method',
        ]);
        for (const [tag, , , location] of records) {
          if (tag === 'fragment') { assert.equal(location, null); continue; }
          const lines = source.slice(0, source.indexOf('<' + tag)).split(/\r\n|[\n\r\u2028\u2029]/);
          assert.deepEqual(location, { fileName: input, lineNumber: lines.length, columnNumber: lines.at(-1).length + 1 });
        }
        for (const tag of ['parameter', 'arrow', 'before', 'after']) assert.equal(byTag.get(tag)[4], false);
        for (const tag of ['own', 'method', 'field', 'block']) assert.equal(byTag.get(tag)[4], true);
        assert.equal(byTag.get('own')[5], 'function');
        assert.equal(byTag.get('method')[5], 'instance');
        assert.equal(byTag.get('field')[5], 'field');
        assert.equal(byTag.get('fragment')[2], automatic ? true : null);
        assert.equal(byTag.get('fallback')[1], 'last');
      }
    }
  }
  console.log('Development JSX passed in both runtimes and module formats, including source positions and constructor receivers.');
}
