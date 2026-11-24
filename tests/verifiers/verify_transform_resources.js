'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { SourceMap } = require('node:module');

module.exports = function verifyResources(binary, temp, run, oracle) {
  const fixture = path.join(__dirname, '../transform/resources/scopes.mjs');
  const source = fs.readFileSync(fixture, 'utf8');
  const expected = 'resource lifetimes passed\n';
  const strictFile = path.join(temp, 'strict.cjs');
  fs.writeFileSync(strictFile, 'const run = () => { "use strict"; using r = null; try { missingBinding = 1; } catch (err) { return err.name; } }; if (run() !== "ReferenceError") throw Error("lost directive");');
  const shadowFile = path.join(temp, 'shadow.mjs');
  fs.writeFileSync(shadowFile, [
    'const symbol = (await import("node:vm")).runInNewContext("Symbol");',
    'const log = [];',
    '{ using r = { [symbol.dispose || symbol.for("Symbol.dispose")]() { log.push(1); } }; }',
    'const globalThis = 0, Symbol = 0;',
    'if (log.join() !== "1") throw Error("lost intrinsic");',
  ].join('\n'));
  const executable = path.join(temp, 'output.cjs');
  const fixtures = path.dirname(fixture);
  for (const name of ['observer.mjs', 'importer.mjs', 'unwind-importer.mjs']) {
    fs.copyFileSync(path.join(fixtures, name), path.join(temp, name));
  }
  for (const mode of [[], ['--minified']]) {
    run(process.execPath, ['--input-type=module'], run(binary, ['transform', shadowFile, '--lower-using', ...mode]));
    const code = run(binary, ['transform', fixture, '--lower-using', ...mode]);
    assert.doesNotMatch(code, /\busing\s+(first|second|item|once|held|sync|last|later)\b/);
    assert.equal(run(process.execPath, ['--input-type=module'], code), expected);
    for (const [name, importer, expected] of [
      ['module.mjs', 'importer.mjs', 'module lifetimes passed'],
      ['unwind.mjs', 'unwind-importer.mjs', 'module unwinding passed']
    ]) {
      const original = path.join(fixtures, name);
      const code = run(binary, ['transform', original, '--lower-using', ...mode]);
      if (name === 'module.mjs') assert.match(code, /^"use client";/);
      fs.writeFileSync(path.join(temp, name), code);
      assert.equal(run(process.execPath, [path.join(temp, importer)]).trim(), expected);
    }
    fs.writeFileSync(executable, run(binary, ['transform', strictFile, '--lower-using', ...mode]));
    run(process.execPath, [executable]);
  }
  const entry = path.join(fixtures, 'module.mjs');
  const original = fs.readFileSync(entry, 'utf8');
  for (const mode of [[], ['--minified']]) {
    const [code, encoded] = run(binary, ['transform', entry, '--lower-using', '--sourcemap', ...mode])
      .split('//# sourceMappingURL=data:application/json;base64,');
    const payload = JSON.parse(Buffer.from(encoded.trim(), 'base64'));
    const map = new SourceMap(payload);
    assert.deepEqual(payload.sourcesContent, [original]);
    for (const [name, declaration, sourceToken] of [
      ['early', 'export let early', 'export let early'],
      ['one', 'export const one', 'export const [one'],
      ['fallback', 'export const fallback', 'value: fallback'],
      ['Example', 'export let Example', 'export class Example']
    ]) {
      const gen = code.indexOf(declaration);
      const src = original.indexOf(sourceToken);
      assert.ok(gen >= 0 && src >= 0);
      const before = code.slice(0, gen + declaration.lastIndexOf(name)).split('\n');
      const location = original.slice(0, src + sourceToken.lastIndexOf(name)).split('\n');
      const entry = map.findEntry(before.length - 1, before.at(-1).length);
      assert.deepEqual([entry.originalLine, entry.originalColumn], [location.length - 1, location.at(-1).length], name);
    }
  }
  if (oracle) {
    const result = oracle.transformSync(fixture, source, { target: 'es2022', helpers: { mode: 'External' } });
    assert.deepEqual(result.errors, []);
    assert.match(result.code, /babelHelpers\.usingCtx\(\)/);
  }
  console.log('Resource registration, unwinding, sync and async disposal, and loop lifetimes passed in both output modes.');
};
