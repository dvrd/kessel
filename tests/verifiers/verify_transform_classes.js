'use strict';

// Lowering of the ES2022 class features and of `accessor` fields.
//
// classes.js is plain JavaScript: the log Node prints for it as written is
// the specification, and every lowered output must print the same log.
// accessors.ts cannot run as written, so its recorded log is the reference.
// With --reference each output is parsed by acorn at its target's grammar
// level, and TypeScript 5.9.3 and OXC 0.127.0 lower the same sources. Both
// get some records wrong against the unlowered program; those records are
// named below and the comparison fails if the set changes.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { SourceMap } = require('node:module');

const fixtures = path.resolve(__dirname, '../transform/target');
const decorators = path.resolve(__dirname, '../transform/decorators');
const TARGETS = ['es2015', 'es2016', 'es2017', 'es2018', 'es2019', 'es2020', 'es2021'];

// TypeScript stops with an internal error on a private name in an optional
// chain and emits `super` outside a method for a private method that uses
// it, so its copy of the source has those lines removed or rewritten.
const reference_source = {
  typescript: source => source.split('\n')
    .filter(line => !/\?\.#|private optional|methods optional|#missingSafe/.test(line)).join('\n')
    .replace(' via " + super.greet(); }', ' via " + "parent"; }'),
  oxc: source => source.split('\n')
    .filter(line => !/\?\.#|private optional|methods optional|#missingSafe/.test(line)).join('\n'),
};

// Records each reference prints differently from the unlowered program.
const deviations = {
  // Field keys converted once per instance; functions in fields named "value";
  // initializers that read constructor parameters; `super()` outside the top
  // level of a constructor; a second initialization of one object; a static
  // field without a value; a private method named after its helper; private
  // state shared between evaluations of one class; a private name as the
  // target of a for-in or for-of loop.
  typescript: ['derived arrow', 'derived expression', 'derived plain', 'expression isolation', 'fields names',
    'fields scope', 'loop isolation', 'methods run', 'names', 'return override twice', 'statics keys',
    'targets loops'],
  // Field keys converted once per instance; unnamed functions and classes in
  // fields and bindings; a private method named `_describe`; private state
  // shared between evaluations of one class.
  oxc: ['expression isolation', 'fields names', 'loop isolation', 'methods run', 'names'],
};

// The OXC output imports helpers from @oxc-project/runtime, which is not
// installed. These follow the @babel/runtime definitions it is derived from.
const oxc_runtime = {
  defineProperty: 'export default function (e, r, t) { return r in e ? Object.defineProperty(e, r, { value: t, enumerable: true, configurable: true, writable: true }) : e[r] = t, e; }',
  assertClassBrand: 'export default function (e, t, n) { if ("function" == typeof e ? e === t : e.has(t)) return arguments.length < 3 ? t : n; throw new TypeError("Private element is not present on this object"); }',
  checkPrivateRedeclaration: 'export default function (e, t) { if (t.has(e)) throw new TypeError("Cannot initialize the same private elements twice on an object"); }',
  classPrivateFieldInitSpec: 'import check from "./checkPrivateRedeclaration.js"; export default function (e, t, a) { check(e, t), t.set(e, a); }',
  classPrivateMethodInitSpec: 'import check from "./checkPrivateRedeclaration.js"; export default function (e, a) { check(e, a), a.add(e); }',
  classPrivateFieldGet2: 'import assert from "./assertClassBrand.js"; export default function (s, a) { return s.get(assert(s, a)); }',
  classPrivateFieldSet2: 'import assert from "./assertClassBrand.js"; export default function (s, a, r) { return s.set(assert(s, a), r), r; }',
  checkInRHS: 'export default function (e) { if (Object(e) !== e) throw TypeError("right-hand side of \'in\' should be an object"); return e; }',
  readOnlyError: 'export default function (r) { throw new TypeError(\'"\' + r + \'" is read-only\'); }',
  writeOnlyError: 'export default function (r) { throw new TypeError(\'"\' + r + \'" is write-only\'); }',
  toSetter: 'export default function (t, e, n) { e || (e = []); var r = e.length++; return Object.defineProperty({}, "_", { set: function (o) { e[r] = o, t.apply(n, e); } }); }',
  superPropGet: 'export default function (t, o, e, r) { var p = Reflect.get(Object.getPrototypeOf(1 & r ? t.prototype : t), o, e); return 2 & r && "function" == typeof p ? function (t) { return p.apply(e, t); } : p; }',
};

function install_oxc_runtime(directory) {
  const helpers = path.join(directory, 'node_modules/@oxc-project/runtime/helpers');
  fs.mkdirSync(helpers, { recursive: true });
  fs.writeFileSync(path.join(helpers, '../package.json'), JSON.stringify({
    name: '@oxc-project/runtime', type: 'module', exports: { './helpers/*': './helpers/*.js' },
  }));
  for (const [name, code] of Object.entries(oxc_runtime)) fs.writeFileSync(path.join(helpers, name + '.js'), code);
}

function execute(directory, name, code) {
  const file = path.join(directory, name);
  fs.writeFileSync(file, code);
  const result = spawnSync(process.execPath, [file], { encoding: 'utf8' });
  assert.equal(result.status, 0, name + '\n' + result.stderr.slice(0, 2000));
  return result.stdout;
}

// `label = value` records of a log, by label.
function records(log) {
  const found = new Map();
  for (const line of log.split('\n')) {
    const split = line.indexOf(' = ');
    if (split > 0) found.set(line.slice(0, split), line.slice(split + 3));
  }
  return found;
}

function differing(expected, actual) {
  const labels = [];
  for (const [label, value] of records(expected)) {
    if (records(actual).get(label) !== value) labels.push(label);
  }
  return labels.sort();
}

function checkClasses(binary, directory, run, oracle) {
  const file = path.join(fixtures, 'classes.js');
  const source = fs.readFileSync(file, 'utf8');
  const expected = execute(directory, 'native.mjs', source);
  assert.ok(records(expected).size > 40);
  let outputs = 0;
  for (const target of TARGETS) {
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', file, '--target=' + target, ...flags]);
      assert.equal(execute(directory, 'kessel.mjs', code), expected, ['classes.js', target, ...flags].join(' '));
      outputs += 1;
      if (!oracle) continue;
      const acorn = require('../../bench/node_modules/acorn');
      acorn.parse(code, { ecmaVersion: Number(target.slice(2)), sourceType: 'module' });
    }
  }
  if (!oracle) return outputs;
  const ts = require('../../bench/node_modules/typescript');
  install_oxc_runtime(directory);
  for (const target of ['es2015', 'es2021']) {
    const for_typescript = reference_source.typescript(source);
    const compiled = ts.transpileModule(for_typescript, { fileName: 'classes.js',
      compilerOptions: { target, module: 'ESNext', allowJs: true, useDefineForClassFields: true } });
    assert.deepEqual(differing(execute(directory, 'native.mjs', for_typescript),
      execute(directory, 'typescript.mjs', compiled.outputText)), deviations.typescript, 'TypeScript ' + target);
    const for_oxc = reference_source.oxc(source);
    const reference = oracle.transformSync('classes.js', for_oxc, { target });
    assert.deepEqual(reference.errors, []);
    assert.deepEqual(differing(execute(directory, 'native.mjs', for_oxc),
      execute(directory, 'oxc.mjs', reference.code)), deviations.oxc, 'OXC ' + target);
  }
  return outputs;
}

function checkAccessors(binary, directory, run, oracle) {
  const file = path.join(fixtures, 'accessors.ts');
  const expected = fs.readFileSync(file.replace(/\.ts$/, '.log'), 'utf8');
  for (const target of ['esnext', 'es2022', 'es2021', 'es2018']) {
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', file, '--decorators=legacy', '--target=' + target, ...flags]);
      assert.doesNotMatch(code, /\baccessor\s+[\w"[]/);
      assert.equal(execute(directory, 'kessel.mjs', code), expected, ['accessors.ts', target, ...flags].join(' '));
    }
  }
  if (!oracle) return;
  // TypeScript's output for a static accessor reads a binding it never
  // assigns, and it names a function after the storage field.
  const source = fs.readFileSync(file, 'utf8').split('\n')
    .filter(line => !/class Shared|"static|static foreign/.test(line)).join('\n');
  const ts = require('../../bench/node_modules/typescript');
  const compiled = ts.transpileModule(source, { fileName: 'accessors.ts',
    compilerOptions: { target: 'ES2022', module: 'ESNext', experimentalDecorators: true } });
  const produced = execute(directory, 'typescript.mjs', compiled.outputText);
  const shared = [...records(produced).keys()];
  assert.equal(shared.length, 8);
  const wrong = shared.filter(label => records(produced).get(label) !== records(expected).get(label));
  assert.deepEqual(wrong, ['values']);
}

// The decorator fixtures use fields and static members, so they exercise
// decorators applied to a class that was also lowered.
function checkDecorated(binary, directory, run) {
  for (const [name, flags] of [['legacy', ['--decorators=legacy']],
    ['metadata', ['--decorators=legacy', '--emit-decorator-metadata']]]) {
    const expected = fs.readFileSync(path.join(decorators, name + '.log'), 'utf8');
    for (const mode of [[], ['--minified']]) {
      const code = run(binary, ['transform', path.join(decorators, name + '.ts'), ...flags, '--target=es2021', ...mode]);
      assert.doesNotMatch(code, /static\s*\{/);
      assert.equal(execute(directory, 'kessel.mjs', code), expected, name + ' es2021');
    }
  }
}

// TypeScript-only shapes and the assignment mode, whose results differ from
// the unlowered class by design and are stated here.
function checkModes(binary, directory, run) {
  const file = path.join(directory, 'modes.ts');
  fs.writeFileSync(file, 'const log: string[] = [];\n' +
    'class Base { set value(next: number) { log.push("setter " + next); } }\n' +
    'class Fields extends Base { value = 1; bare: number; declare hidden: number; sure!: string;\n' +
    '  constructor(public first: string, readonly second = first + "!") { super(); log.push(Object.keys(this).join()); } }\n' +
    'new Fields("a");\n' +
    'class Plain { own = 1; constructor(private kept: number) { log.push(Object.keys(this).join()); } }\n' +
    'new Plain(2);\nconsole.log(log.join("\\n"));\n');
  const expected = {
    define: 'value,bare,sure,first,second\nown,kept\n',
    assign: 'setter 1\nfirst,second\nown,kept\n',
  };
  for (const [mode, log] of Object.entries(expected)) {
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', file, '--target=es2021', '--class-fields=' + mode, ...flags]);
      assert.equal(execute(directory, 'modes.mjs', code), log, mode);
    }
  }
  assert.equal(spawnSync(binary, ['transform', file, '--class-fields=other']).status, 1);
  // An anonymous default export keeps its name and its static part.
  fs.writeFileSync(path.join(directory, 'anonymous.js'), 'export default class { static mark = 1; #x = 2; read() { return this.#x; } }');
  fs.writeFileSync(path.join(directory, 'anonymous.mjs'),
    run(binary, ['transform', path.join(directory, 'anonymous.js'), '--target=es2015']));
  assert.equal(execute(directory, 'importer.mjs', 'import C from "./anonymous.mjs";\n' +
    'console.log([C.name, C.mark, new C().read(), Object.keys(C).join()].join("|"));'), 'default|1|2|mark\n');
}

function checkDiagnostics(binary, temp) {
  const cases = [
    ['class C { #tag() {} run() { return this.#tag`x`; } }', /template tag/],
    ['class C { x = new.target; }', /new\.target/],
    ['async function f(p) { return class extends (await p) { #x = 1; }; }', /await or yield/],
    ['const WeakMap = Map; class C { #x = 1; }', /WeakMap or WeakSet/],
    ['class C { accessor [key()] = 1; }', /accessor field/],
    ['class C { accessor #x = 1; }', /accessor field/],
  ];
  const file = path.join(temp, 'class-diagnostic.js');
  for (const [source, pattern] of cases) {
    fs.writeFileSync(file, source);
    const result = spawnSync(binary, ['transform', file, '--target=es2021'], { encoding: 'utf8' });
    assert.equal(result.status, 1, source);
    assert.equal(result.stdout, '', source);
    assert.match(result.stderr, pattern, source);
  }
  // At a target that has the features, the class is printed as written.
  fs.writeFileSync(file, 'class C { #x = 1; static y = 2; static { C.z = 3; } }');
  const kept = spawnSync(binary, ['transform', file, '--target=es2022', '--minified'], { encoding: 'utf8' });
  assert.equal(kept.stdout.trim(), 'class C{#x=1;static y=2;static {C.z=3;}}');
  return cases.length;
}

// Initializers moved into the constructor still map to where they were written.
function checkSourceMap(binary, temp, run) {
  const file = path.join(temp, 'class-map.js');
  const source = 'class Mapped extends Base {\n  first = alpha();\n  #second = beta;\n  static third = gamma();\n' +
    '  read() { return this.#second; }\n}\n';
  fs.writeFileSync(file, source);
  for (const flags of [[], ['--minified']]) {
    const generated = run(binary, ['transform', file, '--target=es2015', '--sourcemap', ...flags]);
    const [code, base64] = generated.split('//# sourceMappingURL=data:application/json;base64,');
    const map = new SourceMap(JSON.parse(Buffer.from(base64.trim(), 'base64').toString()));
    const probes = [[code.indexOf('alpha()'), 2, 10], [code.indexOf('beta'), 3, 12], [code.indexOf('gamma()'), 4, 17]];
    for (const [offset, line, column] of probes) {
      assert.ok(offset >= 0);
      const prefix = code.slice(0, offset).split('\n');
      const entry = map.findEntry(prefix.length - 1, prefix.at(-1).length);
      assert.deepEqual([entry.originalLine + 1, entry.originalColumn], [line, column], code.slice(offset, offset + 12));
    }
  }
}

module.exports = function verifyClasses(binary, temp, run, oracle) {
  const directory = fs.mkdtempSync(path.join(temp, 'classes-'));
  const outputs = checkClasses(binary, directory, run, oracle);
  checkAccessors(binary, directory, run, oracle);
  checkDecorated(binary, directory, run);
  checkModes(binary, directory, run);
  const diagnostics = checkDiagnostics(binary, temp);
  checkSourceMap(binary, temp, run);
  const compared = oracle ? ` acorn accepted each at its target level. TypeScript and OXC agreed except on ` +
    `${deviations.typescript.length} and ${deviations.oxc.length} named records.` : '';
  console.log(`Class lowering matched unlowered execution in ${outputs} outputs; accessor fields, decorated ` +
    `classes, both field modes, ${diagnostics} diagnostics and source-map probes passed.${compared}`);
};
