'use strict';

// Legacy decorator lowering. Each fixture prints a log of decorator
// evaluation and application. Both Kessel printers must reproduce the
// recorded log; with --reference the pinned TypeScript and OXC transformers
// are run on the same source and must agree with it as well.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { SourceMap } = require('node:module');

const fixtures = path.resolve(__dirname, '../transform/decorators');

// Records on which a reference transformer is known to differ from Kessel.
// They are excluded from that comparison only; every other record must match.
const deviations = {
  'legacy.ts': {
    // TypeScript 5.9.3 leaves a shorthand property that names a decorated class
    // bound to the class before decoration. OXC and Kessel rename it.
    typescript: [/^self nested /],
    oxc: [],
  },
  'metadata.ts': {
    // Only the type checker can expand an alias.
    typescript: [/\.alias design:type /],
    // OXC 0.127.0 records Array for a rest parameter, Object for a union of one
    // class and for an enum member type, and ignores the setter of a decorated
    // getter. Kessel follows TypeScript on all of these.
    oxc: [/\.(member|textMember|sameClass|sameImport|paired) design:/, /\.(plain|restGeneric) design:paramtypes /],
  },
};

// The OXC output imports its helpers from @oxc-project/runtime, which the
// benchmark dependencies do not install. These are the tslib definitions.
const oxcRuntime = {
  decorate: `export default function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
  }`,
  decorateParam: 'export default function (index, decorator) { return function (target, key) { decorator(target, key, index); }; }',
  decorateMetadata: `export default function (k, v) {
    if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v);
  }`,
};

function installOxcRuntime(directory) {
  const helpers = path.join(directory, 'node_modules/@oxc-project/runtime/helpers');
  fs.mkdirSync(helpers, { recursive: true });
  fs.writeFileSync(path.join(helpers, '../package.json'), JSON.stringify({
    name: '@oxc-project/runtime', type: 'module', exports: { './helpers/*': './helpers/*.js' },
  }));
  for (const [name, code] of Object.entries(oxcRuntime)) fs.writeFileSync(path.join(helpers, name + '.js'), code);
}

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
    ['class C { @d #hidden = 1; }', /private member/],
    ['class C { @d accessor value = 1; }', /accessor field/],
    ['const C = @d class {};', /class expression/],
    ['const C = class { @d method() {} };', /class expression/],
    ['class C { @d get value() { return 1; } @d set value(next) {} }', /both accessors/],
    ['class C { @d declare [name()]: number; }', /constant key/],
    ['const Reflect = {}; @d class C {}', /shadows a global/],
  ];
  const file = path.join(temp, 'decorator-diagnostic.ts');
  for (const [source, pattern] of cases) {
    fs.writeFileSync(file, 'declare const d: any; declare function name(): string;\n' + source);
    const result = spawnSync(binary, ['transform', file, '--decorators=legacy'], { encoding: 'utf8' });
    assert.equal(result.status, 1, source);
    assert.equal(result.stdout, '', source);
    assert.match(result.stderr, pattern, source);
  }
  fs.writeFileSync(file, '@d class C {}');
  assert.equal(spawnSync(binary, ['transform', file, '--decorators=other']).status, 1);
  // Without the option the syntax is preserved for a later tool.
  const preserved = spawnSync(binary, ['transform', file], { encoding: 'utf8' });
  assert.match(preserved.stdout, /@d\s+class C/);
  return cases.length;
}

// Three export shapes share one importer, which reads their live bindings.
function checkExports(binary, temp, run) {
  const directory = fs.mkdtempSync(path.join(temp, 'decorator-exports-'));
  const prelude = 'const seen: string[] = (globalThis as any).seen ??= [];\n' +
    'function mark(label: string) { return (target: any, key?: string): any => { seen.push(label + ":" + (key ?? target.name)); }; }\n' +
    'function swap(target: any): any { return class Swapped extends target { static swapped = true; }; }\n';
  const modules = {
    'named.ts': '@swap export class Named { static self = Named; @mark("named") method() { return Named; } }\n' +
      'export class Plain { @mark("plain") method() {} }',
    'default-named.ts': '@swap export default class Chosen { @mark("chosen") method() { return Chosen; } }',
    'default-anonymous.ts': '@mark("anonymous-class") export default class { @mark("anonymous") method() {} }',
    'default-members.ts': 'export default class { @mark("members") static method() {} }',
  };
  const importer = 'import { Named, Plain } from "./named.mjs";\nimport Chosen from "./default-named.mjs";\n' +
    'import Anonymous from "./default-anonymous.mjs";\nimport Members from "./default-members.mjs";\n' +
    'console.log(JSON.stringify([globalThis.seen, Named.name, Named.swapped, Named.self !== Named, new Named().method() === Named,\n' +
    '  Plain.name, Chosen.name, new Chosen().method() === Chosen, Anonymous.name, Members.name]));';
  const expected = JSON.stringify([
    ['named:method', 'plain:method', 'chosen:method', 'anonymous:method', 'anonymous-class:default', 'members:method'],
    'Swapped', true, true, true, 'Plain', 'Swapped', true, 'default', 'default',
  ]);
  for (const flags of [[], ['--minified']]) {
    for (const [name, source] of Object.entries(modules)) {
      const file = path.join(directory, name);
      fs.writeFileSync(file, prelude + source);
      fs.writeFileSync(file.replace(/\.ts$/, '.mjs'), run(binary, ['transform', file, '--decorators=legacy', ...flags]));
    }
    assert.equal(execute(directory, 'importer.mjs', importer).trim(), expected);
  }
}

function checkSourceMap(binary, temp, run) {
  const file = path.join(temp, 'decorator-map.ts');
  const source = 'declare const first: any, second: any, third: any;\n@first\nclass Mapped {\n' +
    '  @second\n  method(@third value: number) {}\n}\n';
  fs.writeFileSync(file, source);
  for (const flags of [[], ['--minified']]) {
    const generated = run(binary, ['transform', file, '--decorators=legacy', '--sourcemap', ...flags]);
    const [code, base64] = generated.split('//# sourceMappingURL=data:application/json;base64,');
    const map = new SourceMap(JSON.parse(Buffer.from(base64.trim(), 'base64').toString()));
    const probes = [[code.lastIndexOf('first'), 1, 1], [code.lastIndexOf('second'), 3, 3],
      [code.lastIndexOf('third'), 4, 10], [code.indexOf('class Mapped'), 1, 0]];
    for (const [offset, line, column] of probes) {
      assert.ok(offset >= 0);
      const prefix = code.slice(0, offset).split('\n');
      const entry = map.findEntry(prefix.length - 1, prefix.at(-1).length);
      assert.deepEqual([entry.originalLine, entry.originalColumn], [line, column], code.slice(offset, offset + 12));
    }
  }
}

// Below ES2022 there are no static blocks to publish the alias from, and no
// static initializers that could need it early.
function checkOlderTarget(binary, temp, run) {
  const directory = fs.mkdtempSync(path.join(temp, 'decorator-target-'));
  const file = path.join(directory, 'older.ts');
  fs.writeFileSync(file, 'function swap(target: any): any { const next = class extends target {}; ' +
    '(next as any).swapped = true; return next; }\n' +
    '@swap class Self { make(): Self { return new Self(); } static create(): Self { return new Self(); }\n' +
    '  @(((t: any, k: string, d: PropertyDescriptor) => { d.enumerable = true; }) as any) seen?(): number { return this?.constructor.name.length ?? 0; } }\n' +
    'console.log([(Self as any).swapped, new Self().make() instanceof Self, Self.create() instanceof Self,\n' +
    '  Object.keys(Object.getPrototypeOf(Self.prototype)).join(), new Self().seen!()].join());');
  for (const target of ['es2015', 'es2021', 'es2022']) {
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', file, '--decorators=legacy', '--target=' + target, ...flags]);
      assert.equal(/static\s*\{/.test(code), target === 'es2022', target);
      assert.equal(execute(directory, 'older.mjs', code).trim(), 'true,true,true,seen,4');
    }
  }
}

module.exports = function verifyDecorators(binary, temp, run, oracle) {
  const directory = fs.mkdtempSync(path.join(temp, 'decorators-'));
  let references = 0;
  let excluded = 0;
  const names = fs.readdirSync(fixtures).filter(name => name.endsWith('.ts'));
  for (const name of names) {
    const file = path.join(fixtures, name);
    const expected = fs.readFileSync(file.replace(/\.ts$/, '.log'), 'utf8');
    const options = JSON.parse(fs.readFileSync(file.replace(/\.ts$/, '.json'), 'utf8'));
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', file, ...options.kessel, ...flags]);
      assert.equal(execute(directory, 'kessel.mjs', code), expected, name + ' ' + flags.join(' '));
    }
    if (!oracle) continue;
    const source = fs.readFileSync(file, 'utf8');
    const ts = require('../../bench/node_modules/typescript');
    const compiled = ts.transpileModule(source, { fileName: name, compilerOptions: {
      target: 'ES2022', module: 'ESNext', verbatimModuleSyntax: true, ...options.typescript } });
    const known = deviations[name];
    assert.equal(withoutLines(execute(directory, 'typescript.mjs', compiled.outputText), known.typescript),
      withoutLines(expected, known.typescript), name + ' TypeScript');
    installOxcRuntime(directory);
    const reference = oracle.transformSync(name, source, options.oxc);
    assert.deepEqual(reference.errors, []);
    // OXC 0.127.0 decorates members in source order. TypeScript, which defines
    // this dialect, finishes the instance members before the static ones, so
    // the OXC log is compared as an unordered set of records.
    const records = log => withoutLines(log, known.oxc).split('\n').sort();
    assert.deepEqual(records(execute(directory, 'oxc.mjs', reference.code)), records(expected), name + ' OXC');
    excluded += expected.split('\n').length * 2 - withoutLines(expected, known.typescript).split('\n').length -
      withoutLines(expected, known.oxc).split('\n').length;
    references += 1;
  }
  const diagnostics = checkDiagnostics(binary, temp);
  checkExports(binary, temp, run);
  checkSourceMap(binary, temp, run);
  checkOlderTarget(binary, temp, run);
  const compared = oracle ? ` TypeScript matched ${references} in order and OXC as record sets, ` +
    `apart from ${excluded} documented records.` : '';
  console.log(`Legacy decorators passed ${names.length} runtime fixtures in both output modes, ` +
    `${diagnostics} diagnostics, four export shapes and source-map probes.${compared}`);
};
