import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

const binary = process.argv[2];
const directory = mkdtempSync(path.join(tmpdir(), 'kessel-module-scope-'));
const checkThis = 'if (this !== undefined) throw new Error("expected module scope");';
const erased = [
  'import type { X } from "./missing.js";',
  'import type X = require("./missing.cjs");',
  'export import type X = require("./missing.cjs");',
  'export type * from "./missing.js";',
  'export type { X } from "./missing.js";',
  'export default interface X {}',
  'export declare enum X { A }',
  'export namespace X { export type T = number; }',
  'export declare function X(): void;',
];

function strip(name, source, flags) {
  const filename = path.join(directory, name);
  writeFileSync(filename, source);
  return execFileSync(binary, ['strip-types', filename, ...flags], { encoding: 'utf8' });
}

async function evaluateModule(js) {
  // The script parser checks that the output itself identifies as a module.
  // Importing also catches malformed export declarations and missing dependencies.
  assert.throws(() => new vm.Script(js), SyntaxError);
  return import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'));
}

try {
  writeFileSync(path.join(directory, 'local.cjs'), 'module.exports = { value: 7 };');
  for (const flags of [[], ['--minified']]) {
    for (const name of ['api.d.ts', 'api.d.mts', 'api.d.cts']) {
      assert.equal(strip(name, 'export const tag: string; export class Widget {}', flags), '');
    }
    for (const declaration of erased) {
      const js = strip('entry.ts', declaration + '\n' + checkThis, flags);
      assert.deepEqual(Object.keys(await evaluateModule(js)), [], declaration);
    }
    await evaluateModule(strip('entry.mts', checkThis, flags));
    await evaluateModule(strip('entry.ts', checkThis, [...flags, '--source-type=module']));

    const overload = 'export default function f(x: number): number;\n' +
      'export default function f(x: number) { return x + 1; }';
    const live = strip('entry.ts', erased[0] + '\n' + overload, flags);
    assert.equal((await evaluateModule(live)).default(9), 10);
    assert.doesNotMatch(live, /export\s*\{\s*\}/);

    const aliases = '"use strict";\n' +
      'const __kessel_create_require_1 = 0, __kessel_require_2 = 0;\n' +
      'import first = require("./local.cjs");\n' +
      'export import second = require("./local.cjs");\n' +
      'if (first !== second || first.value !== 7) throw new Error("module require");';
    for (const name of ['entry.mts', 'entry.ts']) {
      const js = strip(name, aliases, flags);
      assert.ok(js.trimStart().startsWith('"use strict";'));
      const output = path.join(directory, name + flags.length + '.mjs');
      writeFileSync(output, js);
      assert.equal((await import(pathToFileURL(output))).second.value, 7);
    }
    // An .mts file can establish ESM solely through its extension.
    const onlyRequire = strip('entry.mts', 'import x = require("./local.cjs");\n' +
      'if (x.value !== 7 || this !== undefined) throw new Error("implicit ESM");', flags);
    const implicit = path.join(directory, 'implicit' + flags.length + '.mjs');
    writeFileSync(implicit, onlyRequire);
    await import(pathToFileURL(implicit));

    for (const [i, statement] of [
      'const result = await Promise.resolve(x.value); if (result !== 7) throw Error();',
      'for await (const value of [x.value]) { if (value !== 7) throw Error(); }',
    ].entries()) {
      const js = strip('entry.ts', erased[0] + '\nimport x = require("./local.cjs");\n' + statement, flags);
      const out = path.join(directory, 'await' + i + flags.length + '.mjs');
      writeFileSync(out, js);
      await import(pathToFileURL(out));
    }

    const script = 'namespace X { export const value = 2; }\nX.value;';
    assert.equal(new vm.Script(strip('entry.ts', script, flags)).runInNewContext(), 2);
    const commonJS = 'const value: number = 3; export = value;';
    for (const [name, source] of [
      ['entry.ts', erased[0] + '\n' + commonJS],
      ['entry.cts', erased[0] + '\nmodule.exports = 3;'],
      ['entry.ts', erased[0] + '\nimport x = require("x"); module.exports = x;'],
    ]) {
      const context = { module: { exports: {} }, require: () => 3 };
      new vm.Script(strip(name, source, flags)).runInNewContext(context);
      assert.equal(context.module.exports, 3);
    }
  }
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log('ES module scope, surviving exports, scripts and CommonJS passed in both output modes');
