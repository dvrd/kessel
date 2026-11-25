'use strict';

// Async functions below ES2017. The fixtures are plain JavaScript, so the log
// Node prints for a file as written is the specification: every lowered
// output, at each target and from both printers, must print the same log.
// async.js is a module (strict code); async-sloppy.cjs is a script, where
// `this` defaults to the global object and `arguments` is tied to parameters.
//
// With --reference each output is also parsed by acorn at the grammar level
// of its target, and TypeScript and OXC lower the same fixtures. Where a
// reference cannot run a part of a fixture, or runs it differently from the
// program as written, the part is named below with the reason.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const fixtures = path.resolve(__dirname, '../transform/target');
const plans = [
  { name: 'async.js', extension: 'mjs', targets: ['es2015', 'es2016', 'es2017', 'esnext'] },
  { name: 'async-sloppy.cjs', extension: 'cjs', targets: ['es2015', 'es2016', 'es2017', 'esnext'] },
];

// Fixture lines a reference is run without, by the tag that ends the line.
const withheld = {
  typescript: {
    // TypeScript 5.9.3 leaves `await` in the computed key of a class method
    // inside the generator, which is a syntax error.
    key: 'await in a computed method key is not rewritten',
    // `{ arguments }` in an async arrow keeps reading the generator's own arguments.
    shorthand: 'shorthand arguments is not captured',
    // `new.target` in an async arrow reads that of the generator, undefined.
    target: 'new.target in an async arrow is not captured',
    // `__awaiter(this, ...)` reads `this` when the arrow is called, which
    // throws in a derived constructor before super() even if the arrow never uses it.
    early: 'an async arrow reads this before super()',
    // Parameters stay on the outer function, so `var a` in the body is a new binding.
    var: 'a body var no longer shares the parameter binding',
    // Not about async: a lowered private method is a plain function named _Hidden_hidden.
    private: 'private methods are lowered to named functions',
  },
  oxc: {
    // OXC 0.127.0 leaves `super.count++` inside the generator, a syntax error.
    update: 'an update of a super property is not rewritten',
    // new.target in an async arrow reads that of the generator, undefined.
    target: 'new.target in an async arrow is not captured',
    // These need helpers of @oxc-project/runtime that are not installed.
    field: 'needs the defineProperty runtime helper',
    private: 'needs the private method runtime helpers',
  },
};

// Records a reference prints differently from the program as written.
const deviations = {
  // In a script, TypeScript 5.9.3 leaves a "use strict" directive inside the
  // generator, so the outer function still defaults `this` to the global
  // object; a parameter named `arguments` stays outside the generator, which
  // has its own; and plain parameters are not forwarded, so code given to
  // eval sees an empty `arguments`.
  typescript: [/^strict directive /, /^parameter named arguments /, /^eval in a function /],
  // OXC turns an async arrow into an ordinary function, which has a prototype
  // and can be constructed, and does not name a function-valued property.
  // In a script its outer wrapper is sloppy even when the body has a "use strict"
  // directive, so `this` defaults to the global object.
  oxc: [/^arrow( default| rest| property)?: name /, /^function property: name /, /^strict directive /],
};

function execute(directory, name, code) {
  const file = path.join(directory, name);
  fs.writeFileSync(file, code);
  const result = spawnSync(process.execPath, [file], { encoding: 'utf8' });
  assert.equal(result.status, 0, name + '\n' + result.stderr + result.stdout.slice(-400));
  return result.stdout;
}

function withoutTags(source, tags) {
  return source.split('\n').filter(line => !tags.some(tag => line.endsWith('// [' + tag + ']'))).join('\n');
}

function withoutRecords(log, patterns) {
  return log.split('\n').filter(line => !patterns.some(pattern => pattern.test(line))).join('\n');
}

// OXC imports its helpers from @oxc-project/runtime, which the pinned bench
// packages do not include. The three it needs here are supplied from
// tests/verifiers/data/oxc_runtime_standin, written after the Babel helpers
// of the same names; a difference seen through them is checked by hand
// before it is blamed on OXC.
function installRuntime(directory) {
  const helpers = path.join(directory, 'node_modules/@oxc-project/runtime/helpers');
  fs.mkdirSync(helpers, { recursive: true });
  const standin = path.resolve(__dirname, 'data/oxc_runtime_standin');
  for (const name of fs.readdirSync(standin)) fs.copyFileSync(path.join(standin, name), path.join(helpers, name));
  fs.writeFileSync(path.join(helpers, '../package.json'),
    JSON.stringify({ name: '@oxc-project/runtime', type: 'module', exports: { './helpers/*': './helpers/*.js' } }));
}

function checkReferences(directory, plan, source, oracle) {
  const ts = require('../../bench/node_modules/typescript');
  const script = plan.extension === 'cjs';
  let compared = 0;
  for (const target of ['es2015', 'es2016']) {
    const lowered = {
      // A script stays sloppy only when TypeScript is told not to treat it as a module.
      typescript: text => ts.transpileModule(text, { fileName: plan.name, compilerOptions: script ?
        { target, module: 'CommonJS', moduleDetection: 'legacy', alwaysStrict: false, allowJs: true } :
        { target, module: 'ESNext', allowJs: true } }).outputText,
      oxc: text => {
        const result = oracle.transformSync(script ? 'fixture.cjs' : 'fixture.js', text,
          { target, sourceType: script ? 'script' : 'module' });
        assert.deepEqual(result.errors, []);
        return result.code;
      },
    };
    for (const [reference, lower] of Object.entries(lowered)) {
      const text = withoutTags(source, Object.keys(withheld[reference]));
      const expected = execute(directory, 'reduced.' + plan.extension, text);
      const actual = execute(directory, reference + '.' + plan.extension, lower(text));
      assert.equal(withoutRecords(actual, deviations[reference]), withoutRecords(expected, deviations[reference]),
        [plan.name, reference, target].join(' '));
      compared += 1;
    }
  }
  return compared;
}

function checkDiagnostics(binary, temp) {
  const cases = [
    ['es2016', 'js', 'async function* f() {}', /async generators/],
    ['es2016', 'js', 'async function f() { for await (const x of y) {} }', /for await/],
    ['es2016', 'js', 'await 1;', /top-level await/],
    ['es2016', 'js', 'const f = async () => arguments;', /arguments outside a function/],
    ['es2016', 'js', 'class A extends B { constructor() { const f = async () => super(); f(); } }', /super call/],
    ['es2016', 'js', 'const o = { async m() { return eval("super.x"); } };', /direct eval/],
    ['es2016', 'js', 'function f() { return async () => eval("arguments"); }', /direct eval/],
    ['es2016', 'js', 'const o = { async m() { delete super.x; } };', /delete of a super property/],
    ['es2016', 'js', 'const o = { async m() { return super.tag`x`; } };', /template tag/],
    ['es2016', 'js', 'const Promise = 1; async function f() {}', /shadows a global/],
    ['es2016', 'cjs', 'if (x) { async function f() {} }', /block of sloppy code/],
    ['es2016', 'cjs', 'switch (x) { case 1: async function f() {} }', /block of sloppy code/],
    ['es2016', 'js', 'async function f() { await using a = open(); }', /using declarations/],
  ];
  for (const [target, extension, source, pattern] of cases) {
    const file = path.join(temp, 'async-diagnostic.' + extension);
    fs.writeFileSync(file, source);
    const result = spawnSync(binary, ['transform', file, '--target=' + target], { encoding: 'utf8' });
    assert.equal(result.status, 1, source);
    assert.equal(result.stdout, '', source);
    assert.match(result.stderr, pattern, source);
  }
  const file = path.join(temp, 'async-accepted.cjs');
  const accepted = [
    // Strict code scopes every function declaration to its block.
    ['"use strict"; if (x) { async function f() {} }', []],
    ['function g() { async function f() {} }', []],
    // eval in an ordinary async function sees the generator's own arguments, a copy.
    ['async function f() { return eval("arguments.length"); }', []],
    ['async function f() { await using a = open(); }', ['--lower-using', /await using cannot be lowered below ES2017/]],
  ];
  for (const [source, [flag, pattern]] of accepted) {
    fs.writeFileSync(file, source);
    const result = spawnSync(binary, ['transform', file, '--target=es2015', ...(flag ? [flag] : [])], { encoding: 'utf8' });
    if (pattern) assert.match(result.stderr, pattern, source);
    else assert.equal(result.status, 0, source + result.stderr);
  }
  // At a target that has async functions nothing is rewritten.
  fs.writeFileSync(file, 'async function f() { await 1; }');
  const kept = spawnSync(binary, ['transform', file, '--target=es2017'], { encoding: 'utf8' });
  assert.match(kept.stdout, /async function f\(\) \{\s*await 1;\s*\}/);
  return cases.length + accepted.length + 1;
}

module.exports = function verifyAsync(binary, temp, run, oracle) {
  const directory = fs.mkdtempSync(path.join(temp, 'async-'));
  if (oracle) installRuntime(directory);
  let outputs = 0;
  let parsed = 0;
  let references = 0;
  let records = 0;
  for (const plan of plans) {
    const file = path.join(fixtures, plan.name);
    const source = fs.readFileSync(file, 'utf8');
    const expected = execute(directory, 'native.' + plan.extension, source);
    records += expected.trim().split('\n').length;
    assert.ok(expected.split('\n').length > 10, plan.name);
    assert.doesNotMatch(expected, /^FAILED/m);
    for (const target of plan.targets) {
      for (const flags of [[], ['--minified']]) {
        const code = run(binary, ['transform', file, '--target=' + target, ...flags]);
        assert.equal(execute(directory, 'kessel.' + plan.extension, code), expected, [plan.name, target, ...flags].join(' '));
        outputs += 1;
        const lowers = target === 'es2015' || target === 'es2016';
        assert.equal(/\basync\b|\bawait\b/.test(code.replace(/"[^"\n]*"/g, '""').replace(/\/\/.*$/gm, '')), !lowers, target);
        if (!oracle || target === 'esnext') continue;
        const acorn = require('../../bench/node_modules/acorn');
        acorn.parse(code, { ecmaVersion: Number(target.slice(2)), sourceType: plan.extension === 'cjs' ? 'script' : 'module' });
        parsed += 1;
      }
    }
    if (oracle) references += checkReferences(directory, plan, source, oracle);
  }
  const diagnostics = checkDiagnostics(binary, temp);
  const compared = oracle ? ` acorn accepted ${parsed} outputs at their target level; TypeScript and OXC reproduced the logs in ` +
    `${references} runs, without the fixture lines and records named in the verifier.` : '';
  console.log(`Async lowering matched unlowered execution in ${outputs} outputs of ${records} records, with ${diagnostics} ` +
    `diagnostic checks.${compared}`);
};
