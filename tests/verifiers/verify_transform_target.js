'use strict';

// Target lowering. The fixtures are plain JavaScript, so the log Node prints
// for the file as written is the specification. Every lowered output, for
// each target and both printers, must print the same log. With --reference
// the output is also parsed by acorn at the target's grammar level, and the
// pinned TypeScript and OXC transformers are run for comparison.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { SourceMap } = require('node:module');

const fixtures = path.resolve(__dirname, '../transform/target');
const plans = {
  'lowering.js': ['es2015', 'es2016', 'es2017', 'es2018', 'es2019', 'es2020', 'es2021', 'es2022', 'esnext'],
  'lowering-async.js': ['es2018', 'es2019', 'es2020', 'es2021', 'esnext'],
};

// Records a reference transformer gets wrong against the unlowered program.
const deviations = {
  // TypeScript 5.9.3 lowers `eval?.(x)` to a direct eval, which sees local bindings.
  typescript: [/^chain indirect eval /],
  // OXC 0.127.0 lowers `delete (a?.b)` to a delete of a value, which removes nothing.
  oxc: [/^delete chain grouped /],
};

function execute(directory, name, code) {
  const file = path.join(directory, name);
  fs.writeFileSync(file, code);
  const result = spawnSync(process.execPath, [file], { encoding: 'utf8' });
  assert.equal(result.status, 0, name + '\n' + result.stderr);
  return result.stdout;
}

function withoutLines(log, patterns) {
  return log.split('\n').filter(line => !patterns.some(pattern => pattern.test(line))).join('\n');
}

function checkDiagnostics(binary, temp) {
  const cases = [
    ['es2019', '(a?.b)();', /parenthesized optional chain/],
    ['es2019', '(a?.b)`x`;', /parenthesized optional chain/],
    ['es2019', '(a?.b)?.();', /parenthesized optional chain/],
    ['es2019', 'const big = 1n;', /BigInt/],
    ['es2019', 'import("x");', /dynamic import/],
    ['es2019', 'import.meta.url;', /import\.meta/],
    ['es2021', '/a/d;', /flag d/],
    ['es2024', '{ using handle = open(); }', /using declarations/],
    ['es2022', 'for (using handle of handles) {}', /using declarations/],
    ['es2022', 'async function f() { await using handle = open(); }', /using declarations/],
    ['es2021', 'await value;', /top-level await/],
    ['es2021', 'const f = () => { class C { static async m() { await 1; } } }; for (const x of [await 1]) {}', /top-level await/],
    ['es2020', 'const big = 1_000n;', /^$/],
    ['es2019', 'export * as all from "x";', /export \* as/],
    ['es2021', 'const a = 1; export { a as "quoted name" };', /string names/],
    ['es2021', 'import { "quoted name" as a } from "x";', /string names/],
    ['es2021', 'export * as "quoted name" from "x";', /string names/],
    ['es2021', 'import data from "./data.json" with { type: "json" };', /import attributes/],
    ['es2017', '/(?<year>\\d+)/;', /named groups/],
    ['es2017', '/\\p{L}/u;', /Unicode property/],
    ['es2017', 'const f = ([{ ...rest }]) => rest;', /object rest/],
    ['es2017', 'async function f() { for await (const x of a) {} }', /for await/],
    ['es2017', 'async function* f() {}', /async generators/],
    ['es2017', '/a/s;', /flag s/],
    ['es2016', 'async function f() {}', /async functions/],
    ['es2016', 'const f = async () => {};', /async functions/],
    ['es2016', 'class C { async method() {} }', /async functions/],
    ['es2016', 'const o = { async method() {} };', /async functions/],
    ['es2015', 'const Math = {}; a ** 2;', /binding named Math/],
    ['es2015', 'function f(a, ...[b]) {}', /rest parameter with a pattern/],
    ['es2015', 'const f = (...{ length }) => length;', /rest parameter with a pattern/],
    ['es2015', '[a] **= 2;', /./],
  ];
  const file = path.join(temp, 'target-diagnostic.js');
  for (const [target, source, pattern] of cases) {
    fs.writeFileSync(file, source);
    const result = spawnSync(binary, ['transform', file, '--target=' + target], { encoding: 'utf8' });
    if (String(pattern) === '/^$/') {
      // Accepted at this target, with the separator removed.
      assert.equal(result.status, 0, source);
      assert.doesNotMatch(result.stdout, /_/);
      continue;
    }
    assert.equal(result.status, 1, source);
    assert.equal(result.stdout, '', source);
    assert.match(result.stderr, pattern, source);
  }
  fs.writeFileSync(file, 'a ?? b;');
  const unknown = spawnSync(binary, ['transform', file, '--target=es5'], { encoding: 'utf8' });
  assert.equal(unknown.status, 1);
  assert.match(unknown.stderr, /expected a target/);
  // Without a target, and at a target that has the syntax, nothing changes.
  for (const flags of [[], ['--target=es2020'], ['--target=ESNext']]) {
    const kept = spawnSync(binary, ['transform', file, ...flags], { encoding: 'utf8' });
    assert.equal(kept.stdout.trim(), 'a ?? b;');
  }
  return cases.length;
}

// A binding that is only declared stands for a global, which may be an
// accessor, so it is read once. That holds inside namespaces as well.
function checkAmbient(binary, temp, run) {
  const file = path.join(temp, 'target-ambient.ts');
  fs.writeFileSync(file, 'declare const outer: any;\nconst local: any = {};\n' +
    'namespace N { declare const inner: any; export const a = inner?.x; export const b = local?.x; }\n' +
    'declare namespace Lib { const value: any; }\nexport const c = [outer ?? 1, Lib.value ?? 2];\n');
  const code = run(binary, ['transform', file, '--target=es2015']);
  assert.match(code, /= inner\) === null/);
  assert.match(code, /= outer\) !== null/);
  assert.match(code, /local === null \|\| local === void 0 \? void 0 : local\.x/);
  // With --lower-using the declaration is lowered and no longer refused.
  fs.writeFileSync(file, 'export function f(open: () => Disposable) { using handle = open(); return handle ?? 1; }');
  assert.doesNotMatch(run(binary, ['transform', file, '--target=es2019', '--lower-using']), /\busing\b|\?\?/);
}

// Each operand of a lowered expression still maps to where it was written.
function checkSourceMap(binary, temp, run) {
  const file = path.join(temp, 'target-map.ts');
  const source = 'declare const alpha: any, beta: any, gamma: any, delta: any;\n' +
    'export const first = alpha() ?? beta;\n' +
    'export const second = gamma?.inner.call(delta);\n' +
    'alpha.slot ||= beta;\n';
  fs.writeFileSync(file, source);
  for (const flags of [[], ['--minified']]) {
    const generated = run(binary, ['transform', file, '--target=es2015', '--sourcemap', ...flags]);
    const [code, base64] = generated.split('//# sourceMappingURL=data:application/json;base64,');
    const map = new SourceMap(JSON.parse(Buffer.from(base64.trim(), 'base64').toString()));
    const probes = [[code.indexOf('alpha()'), 2, 21], [code.indexOf('beta'), 2, 32],
      [code.indexOf('gamma'), 3, 22], [code.indexOf('delta'), 3, 40], [code.lastIndexOf('beta'), 4, 15]];
    for (const [offset, line, column] of probes) {
      assert.ok(offset >= 0);
      const prefix = code.slice(0, offset).split('\n');
      const entry = map.findEntry(prefix.length - 1, prefix.at(-1).length);
      assert.deepEqual([entry.originalLine + 1, entry.originalColumn], [line, column], code.slice(offset, offset + 12));
    }
  }
}

module.exports = function verifyTarget(binary, temp, run, oracle) {
  const directory = fs.mkdtempSync(path.join(temp, 'target-'));
  let outputs = 0;
  let parsed = 0;
  let references = 0;
  for (const [name, targets] of Object.entries(plans)) {
    const file = path.join(fixtures, name);
    const source = fs.readFileSync(file, 'utf8');
    const expected = execute(directory, 'native.mjs', source);
    assert.ok(expected.split('\n').length > 5, name);
    for (const target of targets) {
      for (const flags of [[], ['--minified']]) {
        const code = run(binary, ['transform', file, '--target=' + target, ...flags]);
        assert.equal(execute(directory, 'kessel.mjs', code), expected, [name, target, ...flags].join(' '));
        outputs += 1;
        if (!oracle || target === 'esnext') continue;
        // The output may not use anything the target's grammar lacks.
        const acorn = require('../../bench/node_modules/acorn');
        acorn.parse(code, { ecmaVersion: Number(target.slice(2)), sourceType: 'module' });
        parsed += 1;
      }
      if (!oracle || target === 'esnext') continue;
      const ts = require('../../bench/node_modules/typescript');
      const compiled = ts.transpileModule(source, { fileName: name, compilerOptions: { target, module: 'ESNext', allowJs: true } });
      assert.equal(withoutLines(execute(directory, 'typescript.mjs', compiled.outputText), deviations.typescript),
        withoutLines(expected, deviations.typescript), name + ' TypeScript ' + target);
      const reference = oracle.transformSync(name, source, { target });
      assert.deepEqual(reference.errors, []);
      assert.equal(withoutLines(execute(directory, 'oxc.mjs', reference.code), deviations.oxc),
        withoutLines(expected, deviations.oxc), name + ' OXC ' + target);
      references += 1;
    }
  }
  // OXC 0.127.0 prints this without the parentheses, which is a syntax error,
  // so it stays out of the shared fixture.
  const grouped = path.join(temp, 'target-await-power.js');
  fs.writeFileSync(grouped, 'const run = async () => (await 3) ** 2 + (-(await 2)) ** 2;\nrun().then(console.log);');
  for (const target of ['es2018', 'esnext']) {
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', grouped, '--target=' + target, ...flags]);
      assert.equal(execute(directory, 'kessel.mjs', code).trim(), '13');
    }
  }
  const diagnostics = checkDiagnostics(binary, temp);
  checkSourceMap(binary, temp, run);
  checkAmbient(binary, temp, run);
  const compared = oracle ? ` acorn accepted ${parsed} outputs at their target level; TypeScript and OXC ` +
    `reproduced the logs at ${references} fixture targets apart from one documented record each.` : '';
  console.log(`Target lowering matched unlowered execution in ${outputs} outputs, with ${diagnostics} target checks ` +
    `and source-map probes.${compared}`);
};
