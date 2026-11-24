'use strict';

// Evidence from Node itself for the module lexer, in two parts.
//
// 1. Proofs. For each class of deliberate difference from es-module-lexer
//    that V8 can observe, a small module is compiled with
//    vm.SourceTextModule and V8's answer (module requests, attributes,
//    phases, namespace keys, dynamic import callbacks) is compared with both
//    lexers. Each proof asserts that Kessel matches V8 AND that
//    es-module-lexer still gives the differing answer, so the allow-list
//    cannot outlive the quirk it documents.
//
// 2. Corpus. Every corpus file V8 compiles as a module is checked: Kessel
//    must accept it, its static requests (specifier, attributes, phase) must
//    equal V8's `moduleRequests`, and when the module can be linked against
//    stubs its export names must equal the keys of V8's module namespace.
//
// vm.SourceTextModule needs --experimental-vm-modules, and `import defer`
// needs a V8 flag, so the script re-runs itself with them.

const FLAGS = ['--experimental-vm-modules', '--js-defer-import-eval', '--no-warnings'];
if (!process.execArgv.includes(FLAGS[0])) {
  const { spawnSync } = require('node:child_process');
  const child = spawnSync(process.execPath, [...FLAGS, __filename, ...process.argv.slice(2)],
    { stdio: 'inherit' });
  process.exit(child.status === null ? 1 : child.status);
}

const assert = require('node:assert/strict');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

const root = path.resolve(__dirname, '../..');
const lexer = require(path.join(root, 'bench/node_modules/es-module-lexer/dist/lexer.cjs'));
const oxc = require(path.join(root, 'bench/node_modules/oxc-parser'));
const { scanModuleSync } = require(path.join(root, 'npm/kessel/index.js'));
const { collectCorpora } = require('./module_lexer_reference_corpus.js');

const PHASES = { Evaluation: 'evaluation', Source: 'source', Defer: 'defer' };

// Kessel's static requests in V8's `moduleRequests` shape.
function kesselRequests(result) {
  return result.dependencies
    .filter(item => item.kind === 'Static' || item.kind === 'Reexport')
    .map(item => ({
      specifier: item.name,
      attributes: Object.fromEntries(item.attribute_entries.map(pair => [pair.key, pair.value])),
      phase: PHASES[item.phase],
    }));
}

function requestKey(request) {
  const attributes = Object.entries(request.attributes).sort();
  return JSON.stringify([request.specifier, attributes, request.phase]);
}

// V8 keeps one request per (specifier, attributes, phase); order is not
// compared because V8 orders requests by its own internal position rule.
function requestSet(requests) {
  return [...new Set(requests.map(requestKey))].sort();
}

function exportNames(result) {
  return [...new Set(result.exports.filter(item => !item.type_only).map(item => item.name))].sort();
}

async function namespaceKeys(module, linker) {
  await module.link(linker || (() => { throw new Error('unexpected import'); }));
  // ownKeys does not read the bindings, so nothing has to be evaluated.
  return Reflect.ownKeys(module.namespace).filter(key => typeof key === 'string').sort();
}

// ---------------------------------------------------------------------------
// Part 1: proofs.

const proofs = [];
const proof = (name, run) => proofs.push({ name, run });

proof('lexer-static-attributes: `with` after a line break, and an empty clause', async () => {
  const source = "import a from 'a'\nwith { type: 'json' };\nimport 'b' with {};";
  const v8 = new vm.SourceTextModule(source).moduleRequests;
  const ours = scanModuleSync(source);
  assert.deepEqual(requestSet(kesselRequests(ours)), requestSet(v8));
  assert.deepEqual(v8.map(item => ({ ...item.attributes })), [{ type: 'json' }, {}]);
  assert.deepEqual(ours.dependencies.map(item => item.attributes !== null), [true, true]);
  // es-module-lexer finds neither clause.
  assert.deepEqual(lexer.parse(source)[0].map(item => item.a), [-1, -1]);
});

proof('lexer-phase-keyword-binding: a binding named like the phase keyword', async () => {
  // [source, phase per V8, `t` per es-module-lexer]; 4 is the source phase.
  const cases = [
    ["import source source from 'a';", 'source', 4],
    ["import source from from 'b';", 'source', 1],
    ["import\n\u2028\u2029source\n\u2028\u2029c from 'c';", 'source', 1],
    ["import source d from 'd';", 'source', 4],
    ["import source from 'e';", 'evaluation', 1],
  ];
  for (const [source, phase, reference] of cases) {
    const [request] = new vm.SourceTextModule(source).moduleRequests;
    assert.equal(request.phase, phase, source);
    assert.equal(PHASES[scanModuleSync(source).dependencies[0].phase], phase, source);
    assert.equal(lexer.parse(source)[0][0].t, reference, source);
  }
});

// Node cannot report a defer-phase request (its moduleRequests getter throws
// "Invalid phase value: 2"), so only the default-binding case is provable:
// `defer` followed by `from` is an ordinary binding, not a phase.
proof('`import defer from` binds a default named defer', async () => {
  const source = "import defer from 'a';";
  const [request] = new vm.SourceTextModule(source).moduleRequests;
  assert.equal(request.phase, 'evaluation');
  assert.equal(scanModuleSync(source).dependencies[0].phase, 'Evaluation');
});

proof('lexer-export-declaration-names: declarators and destructuring', async () => {
  const source = 'export var a = 1, b = 2;\n' +
    'export const { c: d, e: [f, ...g], ...h } = { c: 3, e: [4] }, i = 5;';
  const keys = await namespaceKeys(new vm.SourceTextModule(source));
  assert.deepEqual(keys, ['a', 'b', 'd', 'f', 'g', 'h', 'i']);
  assert.deepEqual(exportNames(scanModuleSync(source)), keys);
  assert.deepEqual(lexer.parse(source)[1].map(item => item.n), ['a', 'c']);
});

proof('lexer-escaped-export-name: the namespace key is the decoded name', async () => {
  const source = 'const x = 1;\nexport { x as \\u03bc };';
  const keys = await namespaceKeys(new vm.SourceTextModule(source));
  assert.deepEqual(keys, ['μ']);
  assert.deepEqual(exportNames(scanModuleSync(source)), keys);
  assert.deepEqual(lexer.parse(source)[1].map(item => item.n), ['\\u03bc']);
});

proof('lexer-export-local-name: `export default class extends` is anonymous', async () => {
  const source = 'class Base {}\nexport default class extends Base {}';
  const module = new vm.SourceTextModule(source);
  await module.link(() => {});
  await module.evaluate();
  // An anonymous default export is named "default"; a class named `extends`
  // cannot exist.
  assert.equal(module.namespace.default.name, 'default');
  assert.equal(scanModuleSync(source).exports[0].local_name, null);
  assert.equal(lexer.parse(source)[1][0].ln, 'extends');
});

proof('lexer-facade-expression-statement: a literal import() runs in the module', async () => {
  const source = "import('side-effect');";
  const requested = [];
  const module = new vm.SourceTextModule(source, {
    importModuleDynamically: specifier => {
      requested.push(specifier);
      return new vm.SyntheticModule([], () => {});
    },
  });
  await module.link(() => {});
  await module.evaluate();
  assert.deepEqual(requested, ['side-effect']);
  assert.equal(scanModuleSync(source).facade, false);
  assert.equal(lexer.parse(source)[2], true);
});

proof('lexer-dynamic-options: a trailing comma adds no options argument', async () => {
  const source = "import('a',);\nimport('b', { with: { type: 'json' } },);";
  const seen = [];
  const module = new vm.SourceTextModule(source, {
    importModuleDynamically: (specifier, referrer, attributes) => {
      seen.push([specifier, { ...attributes }]);
      return new vm.SyntheticModule([], () => {});
    },
  });
  await module.link(() => {});
  await module.evaluate();
  assert.deepEqual(seen, [['a', {}], ['b', { type: 'json' }]]);
  const ours = scanModuleSync(source).dependencies;
  assert.equal(ours[0].attributes, null);
  assert.deepEqual(ours[1].attribute_entries.map(pair => [pair.key, pair.value]),
    [['type', 'json']]);
  // es-module-lexer points `a` at the `)` of the first call.
  assert.equal(source[lexer.parse(source)[0][0].a], ')');
});

proof('import.meta inside import(): Node evaluates the operand', async () => {
  const source = 'import(import.meta.url);';
  const requested = [];
  const module = new vm.SourceTextModule(source, {
    initializeImportMeta: meta => { meta.url = 'proof:meta'; },
    importModuleDynamically: specifier => {
      requested.push(specifier);
      return new vm.SyntheticModule([], () => {});
    },
  });
  await module.link(() => {});
  await module.evaluate();
  assert.deepEqual(requested, ['proof:meta']);
  const [call] = scanModuleSync(source).dependencies;
  assert.equal(source.slice(call.request.start, call.request.end), 'import.meta.url');
});

proof('regex after a block: V8 sees no import in the literal', async () => {
  const source = "function a() {} /import('x')/.test('');\nif (a) {} /import('y')/.test('');";
  const requested = [];
  const module = new vm.SourceTextModule(source, {
    importModuleDynamically: specifier => { requested.push(specifier); },
  });
  await module.link(() => {});
  await module.evaluate();
  assert.deepEqual(requested, []);
  assert.deepEqual(scanModuleSync(source).dependencies, []);
});

proof('lexer-no-typescript: type-only exports are the ones Node erases', async () => {
  const source = 'export type A = number;\nexport interface B { c: A }\n' +
    'export const d: A = 1;\nexport { type A as E, d as f };';
  const keys = await namespaceKeys(new vm.SourceTextModule(stripTypeScriptTypes(source)));
  assert.deepEqual(keys, ['d', 'f']);
  const ours = scanModuleSync(source);
  assert.deepEqual(exportNames(ours), keys);
  assert.deepEqual(ours.exports.filter(item => item.type_only).map(item => item.name),
    ['A', 'B', 'E']);
});

// ---------------------------------------------------------------------------
// Part 2: corpus.

// Stub modules for linking: each exports the names the module imports from
// it, taken from the oracle parser (not from Kessel, which is under test).
function stubLinker(source) {
  const parsed = oxc.parseSync('input.js', source, { sourceType: 'module', lang: 'js' });
  if (parsed.errors.length !== 0) return null;
  const names = new Map();
  const want = (specifier, name) => {
    if (!names.has(specifier)) names.set(specifier, new Set(['default']));
    if (name) names.get(specifier).add(name);
  };
  for (const node of parsed.program.body) {
    // `export *` makes the namespace depend on the stub; such modules are
    // only checked for requests.
    if (node.type === 'ExportAllDeclaration' && node.exported === null) return null;
    if (node.phase) return null;
    if (!node.source || !/^(Import|Export)/.test(node.type)) continue;
    want(node.source.value, null);
    for (const specifier of node.specifiers || []) {
      const imported = specifier.imported || specifier.local;
      if (specifier.type === 'ImportSpecifier' || specifier.type === 'ExportSpecifier') {
        want(node.source.value, imported.type === 'Literal' ? imported.value : imported.name);
      }
    }
  }
  return specifier => new vm.SyntheticModule([...(names.get(specifier) || ['default'])], () => {});
}

async function checkFile(entry, stats) {
  const source = entry.read();
  let module;
  try { module = new vm.SourceTextModule(source); } catch { stats.v8Rejects++; return null; }
  stats.modules++;
  let ours;
  try { ours = scanModuleSync(source); } catch (error) { return `Kessel rejects: ${error.code}`; }
  const requests = module.moduleRequests;
  stats.requests += requests.length;
  const expected = requestSet(requests);
  const actual = requestSet(kesselRequests(ours));
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    return `requests differ: kessel=${actual.join(' ')} v8=${expected.join(' ')}`;
  }
  if (module.hasTopLevelAwait()) {
    stats.topLevelAwait++;
    if (!ours.has_module_syntax) stats.topLevelAwaitOnly++;
  }
  const linker = stubLinker(source);
  if (linker === null) { stats.namespaceSkipped++; return null; }
  let keys;
  try { keys = await namespaceKeys(module, linker); } catch { stats.namespaceSkipped++; return null; }
  stats.namespaces++;
  stats.exports += keys.length;
  const names = exportNames(ours);
  if (JSON.stringify(names) !== JSON.stringify(keys)) {
    return `exports differ: kessel=${names.join(',')} v8=${keys.join(',')}`;
  }
  return null;
}

async function run() {
  await lexer.init;
  const failures = [];
  for (const item of proofs) {
    try { await item.run(); } catch (error) { failures.push(`proof ${item.name}: ${error.message}`); }
  }
  console.log(`proofs: ${proofs.length - failures.length} of ${proofs.length} hold`);
  const only = process.argv.includes('--corpus')
    ? process.argv[process.argv.indexOf('--corpus') + 1] : null;
  for (const [name, entries] of Object.entries(collectCorpora(root, only))) {
    const stats = {
      modules: 0, v8Rejects: 0, requests: 0, namespaces: 0, namespaceSkipped: 0, exports: 0,
      topLevelAwait: 0, topLevelAwaitOnly: 0,
    };
    for (const entry of entries) {
      const problem = await checkFile(entry, stats);
      if (problem !== null) failures.push(`${name}/${entry.key}: ${problem}`);
    }
    console.log(`${name}: ${entries.length} files, ${stats.modules} compile as modules in V8 ` +
      `(${stats.v8Rejects} do not); ${stats.requests} module requests compared; ` +
      `${stats.namespaces} namespaces linked (${stats.exports} export names compared, ` +
      `${stats.namespaceSkipped} not linkable); top-level await in ${stats.topLevelAwait}, ` +
      `of which ${stats.topLevelAwaitOnly} have no other module syntax`);
  }
  if (failures.length !== 0) {
    console.error(failures.slice(0, 40).join('\n'));
    console.error(`\nModule lexer Node gate FAILED: ${failures.length} problem(s)`);
    process.exit(1);
  }
  console.log('Module lexer Node gate passed');
}

run().catch(error => {
  console.error(error);
  process.exit(1);
});
