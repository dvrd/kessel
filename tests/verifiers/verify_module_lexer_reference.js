'use strict';

// Reference gate for the module lexer: compares `scanModuleSync` with
// es-module-lexer field by field over real-world sources, every script under
// bench/node_modules, the test262 and Babel module fixtures and inline cases
// taken from es-module-lexer's own documentation (see
// module_lexer_reference_corpus.js and module_lexer_reference_cases.js).
//
// Method. Each file is scanned by both lexers in-process. Kessel's UTF-8 byte
// offsets are converted to UTF-16 and its records are projected onto
// es-module-lexer's shape (see `project`, which is the compatibility
// definition). A file whose projection is identical counts as an exact
// match. Every other file is handed to an independent parser (oxc-parser,
// see `oracleParse`) which decides whether the source is valid and, when it
// is, what the true module records are. Each differing field must then fall
// into a named difference class (module_lexer_reference_classes.js) whose
// predicate holds, the strongest being "the oracle agrees with Kessel on
// every record of the file", and the file must be listed under exactly those
// classes in module_lexer_reference_allow.json. Unclassified differences,
// unlisted files and stale allow-list entries all fail the gate.
//
// The gate also checks the `format` hint against Node's own module-format
// detection (`nodeDetectsModule`) on the corpora that hold ordinary files.
//
// Usage: node verify_module_lexer_reference.js [--verbose] [--update-allow]
//        [--corpus name] [--report file.json] [--oracle-all]
// --oracle-all additionally checks Kessel against the oracle on every file
// the oracle accepts, not only on files where the two lexers differ.
// --update-allow rewrites the allow-list from what was observed; it still
// fails on unclassified differences, and the diff must be reviewed.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const lexer = require(path.join(root, 'bench/node_modules/es-module-lexer/dist/lexer.cjs'));
const oxc = require(path.join(root, 'bench/node_modules/oxc-parser'));
const { scanModuleSync } = require(path.join(root, 'npm/kessel/index.js'));
const {
  CLASSES, classify, classifyShared, oracleProblems,
} = require('./module_lexer_reference_classes.js');
const { collectCorpora } = require('./module_lexer_reference_corpus.js');

const allowPath = path.join(__dirname, 'module_lexer_reference_allow.json');
const args = process.argv.slice(2);
const verbose = args.includes('--verbose');
const updateAllow = args.includes('--update-allow');
const oracleAll = args.includes('--oracle-all');
const option = name => (args.includes(name) ? args[args.indexOf(name) + 1] : null);
const onlyCorpus = option('--corpus');
const reportPath = option('--report');

const IMPORT_FIELDS = ['n', 't', 's', 'e', 'ss', 'se', 'd', 'a'];
const EXPORT_FIELDS = ['n', 'ln', 's', 'e', 'ls', 'le'];
const IMPORT_TYPES = [
  'None', 'Static', 'Dynamic', 'Import_Meta', 'Static_Source_Phase',
  'Dynamic_Source_Phase', 'Static_Defer_Phase', 'Dynamic_Defer_Phase',
];

// Kessel reports UTF-8 byte offsets, es-module-lexer UTF-16 code units.
function utf16Offsets(source) {
  const byteLength = Buffer.byteLength(source, 'utf8');
  if (byteLength === source.length) return offset => offset;
  const table = new Uint32Array(byteLength + 1);
  let byte = 0;
  for (let index = 0; index < source.length; index++) {
    const unit = source.charCodeAt(index);
    let width = unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
    const paired = unit >= 0xd800 && unit < 0xdc00 && index + 1 < source.length &&
      (source.charCodeAt(index + 1) & 0xfc00) === 0xdc00;
    if (paired) width = 4;
    table.fill(index, byte, byte + width);
    byte += width;
    if (paired) index++;
  }
  assert.equal(byte, byteLength);
  table[byteLength] = source.length;
  return offset => table[offset];
}

// Project Kessel's records onto es-module-lexer's observable shape. This is
// the compatibility definition: every es-module-lexer field is derived from
// Kessel output alone, never from the source text.
function project(result, source) {
  const at = utf16Offsets(source);
  const imports = [];
  let importEquals = 0;
  for (const item of result.dependencies) {
    if (item.kind === 'Import_Equals') { importEquals++; continue; }
    const meta = item.kind === 'Import_Meta';
    const span = meta ? item.statement : item.request;
    imports.push({
      n: item.name === null ? undefined : item.name,
      t: IMPORT_TYPES.indexOf(item.import_type),
      s: at(span.start),
      e: at(span.end),
      ss: at(item.statement.start),
      se: at(item.clause_end),
      d: meta ? -2 : item.arguments_start === null ? -1 : at(item.arguments_start),
      a: item.attributes === null ? -1 : at(item.attributes.start),
    });
  }
  const exports = result.exports.map(item => {
    const quote = item.name_is_string ? 1 : 0;
    const localQuote = item.local_is_string ? 1 : 0;
    const local = item.local_span;
    return {
      n: item.name,
      ln: item.local_name === null ? undefined : item.local_name,
      s: at(item.span.start) - quote,
      e: at(item.span.end) + quote,
      ls: local === null ? -1 : at(local.start) - localQuote,
      le: local === null ? -1 : at(local.end) + localQuote,
    };
  });
  return {
    imports, exports, facade: result.facade, hasModuleSyntax: result.has_module_syntax,
    importEquals, format: result.format, attributes: result.dependencies
      .filter(item => item.kind !== 'Import_Equals')
      .map(item => item.attribute_entries.map(pair => [pair.key, pair.value])),
  };
}

function reference(source) {
  const [imports, exports, facade, hasModuleSyntax] = lexer.parse(source);
  return {
    imports: imports.map(item => Object.fromEntries(IMPORT_FIELDS.map(key => [key, item[key]]))),
    exports: exports.map(item => Object.fromEntries(EXPORT_FIELDS.map(key => [key, item[key]]))),
    facade, hasModuleSyntax,
  };
}

function attempt(run) {
  try { return { value: run() }; } catch (error) { return { error }; }
}

// Field-level differences between two projections, as {path, kessel, lexer}.
function differences(kessel, expected) {
  const out = [];
  const list = (kind, fields) => {
    const ours = kessel[kind];
    const theirs = expected[kind];
    if (ours.length !== theirs.length) {
      out.push({ path: `${kind}.length`, kessel: ours.length, lexer: theirs.length });
      return;
    }
    for (let index = 0; index < ours.length; index++) {
      for (const field of fields) {
        if (ours[index][field] === theirs[index][field]) continue;
        out.push({
          path: `${kind}[${index}].${field}`, kind, index, field,
          kessel: ours[index][field], lexer: theirs[index][field],
        });
      }
    }
  };
  list('imports', IMPORT_FIELDS);
  list('exports', EXPORT_FIELDS);
  for (const field of ['facade', 'hasModuleSyntax']) {
    if (kessel[field] !== expected[field]) {
      out.push({ path: field, field, kessel: kessel[field], lexer: expected[field] });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Oracle: oxc-parser's ESTree AST reduced to module records.

// Goals tried in order. JSX is a superset of JS for these sources; the
// TypeScript goals let the oracle judge the `export type`/`interface`
// fixtures that Kessel scans on purpose and es-module-lexer cannot.
const ORACLE_GOALS = [
  { sourceType: 'module', lang: 'jsx' }, { sourceType: 'script', lang: 'jsx' },
  { sourceType: 'module', lang: 'ts' }, { sourceType: 'module', lang: 'tsx' },
];

// A duplicate export name is an early error, but the grammar and therefore
// the module records are well defined, so such a source is still compared.
const RECORD_NEUTRAL_ERROR = /^Duplicated export '/;

function oracleParse(source) {
  for (const goal of ORACLE_GOALS) {
    const parsed = attempt(() => oxc.parseSync('input', source, goal));
    if (parsed.error) continue;
    if (!parsed.value.errors.every(error => RECORD_NEUTRAL_ERROR.test(error.message))) continue;
    const records = oracleRecords(parsed.value.program);
    // oxc-parser leaves "import/export only at the top level" to its semantic
    // pass, so that early error is enforced here.
    if (records.misplaced) continue;
    return { valid: true, goal, records };
  }
  return { valid: false };
}

function oracleName(node) {
  return node.type === 'Literal' ? node.value : node.name;
}

function oraclePattern(pattern, out) {
  // Iterative walk: binding patterns nest arbitrarily deep.
  const stack = [pattern];
  while (stack.length !== 0) {
    const node = stack.pop();
    if (node === null) continue;
    switch (node.type) {
      case 'Identifier': out.push(node); break;
      case 'ObjectPattern':
        for (const property of [...node.properties].reverse()) {
          stack.push(property.type === 'RestElement' ? property.argument : property.value);
        }
        break;
      case 'ArrayPattern': stack.push(...[...node.elements].reverse()); break;
      case 'AssignmentPattern': stack.push(node.left); break;
      case 'RestElement': stack.push(node.argument); break;
      default: throw new Error(`oracle: unexpected pattern ${node.type}`);
    }
  }
}

function oracleExportDeclaration(node, exports) {
  if (node.type === 'ExportDefaultDeclaration') {
    const named = /^(Function|Class)Declaration$/.test(node.declaration.type) &&
      node.declaration.id !== null;
    const decorated = (node.declaration.decorators || []).length !== 0;
    exports.push({ n: 'default', ln: named ? node.declaration.id.name : undefined, decorated });
    return;
  }
  if (node.type === 'ExportAllDeclaration') {
    if (node.exported !== null) exports.push({ n: oracleName(node.exported), ln: undefined });
    return;
  }
  for (const specifier of node.specifiers) {
    const local = node.source === null ? oracleName(specifier.local) : undefined;
    exports.push({ n: oracleName(specifier.exported), ln: local });
  }
  if (node.declaration === null) return;
  const names = [];
  const variable = node.declaration.type === 'VariableDeclaration';
  if (variable) {
    for (const declarator of node.declaration.declarations) oraclePattern(declarator.id, names);
  } else {
    names.push(node.declaration.id);
  }
  const decorated = (node.declaration.decorators || []).length !== 0;
  for (const id of names) {
    exports.push({ n: oracleName(id), ln: oracleName(id), variable, decorated });
  }
}

function oracleStatic(node) {
  const phase = node.phase === 'source' ? 4 : node.phase === 'defer' ? 6 : 1;
  return {
    t: phase, n: node.source.value, s: node.source.start + 1, e: node.source.end - 1,
    ss: node.start, attributes: (node.attributes || node.withClause?.attributes || [])
      .map(pair => [oracleName(pair.key), pair.value.value]),
  };
}

function oracleRecords(program) {
  const imports = [];
  const exports = [];
  let moduleSyntax = false;
  // Export declarations are only module-level at the top of the program; a
  // TypeScript namespace body may nest further `export`s that are not.
  for (const node of program.body) {
    if (/^Export(Named|All|Default)Declaration$/.test(node.type)) {
      moduleSyntax = true;
      oracleExportDeclaration(node, exports);
      if (node.source) imports.push(oracleStatic(node));
    }
    // TypeScript's own module markers; Kessel scans TypeScript sources too.
    if (node.type === 'TSImportEqualsDeclaration' || node.type === 'TSExportAssignment') {
      moduleSyntax = true;
    }
  }
  // Explicit stack instead of recursion; children are pushed in source order
  // and the import list is sorted by position afterwards.
  const topLevel = new Set(program.body);
  let misplaced = false;
  const stack = [program];
  while (stack.length !== 0) {
    const node = stack.pop();
    // A TypeScript namespace or ambient module body scopes its own
    // declarations; they are not records of this module.
    if (node.type === 'TSModuleDeclaration') continue;
    if (/^(Import|Export(Named|All|Default))Declaration$/.test(node.type)) {
      if (!topLevel.has(node)) misplaced = true;
    }
    if (node.type === 'ImportDeclaration') {
      moduleSyntax = true;
      imports.push(oracleStatic(node));
      continue;
    }
    if (node.type === 'ImportExpression') {
      const literal = node.source.type === 'Literal' && typeof node.source.value === 'string';
      imports.push({
        t: node.phase === 'source' ? 5 : node.phase === 'defer' ? 7 : 2,
        n: literal ? node.source.value : undefined,
        s: node.source.start, e: node.source.end, ss: node.start, se: node.end,
        a: node.options ? node.options.start : -1,
      });
    }
    if (node.type === 'MetaProperty' && node.meta.name === 'import') {
      moduleSyntax = true;
      const { start, end } = node;
      imports.push({ t: 3, n: undefined, s: start, e: end, ss: start, se: end });
    }
    for (const key of Object.keys(node)) {
      const child = node[key];
      if (Array.isArray(child)) {
        for (const item of child) if (item && typeof item.type === 'string') stack.push(item);
      } else if (child && typeof child.type === 'string') {
        stack.push(child);
      }
    }
  }
  imports.sort((left, right) => left.ss - right.ss);
  // Kessel's facade definition, evaluated on the AST.
  const facade = program.body.every(node => node.type === 'ImportDeclaration' ||
    node.type === 'ExportAllDeclaration' || node.type === 'EmptyStatement' ||
    (node.type === 'ExportNamedDeclaration' && node.declaration === null));
  return { imports, exports, moduleSyntax, facade, misplaced };
}

// ---------------------------------------------------------------------------
// Node's own module-format detection, reproduced with the same primitive the
// CommonJS loader uses: compile as a CommonJS function and look for the
// errors that only module syntax produces (lib/internal/modules/helpers).
const ESM_ERRORS = [
  'Cannot use import statement outside a module',
  "Unexpected token 'export'",
  "Cannot use 'import.meta' outside a module",
];
// Errors that only the CommonJS wrapper causes. Node retries such a source
// inside an async function and treats it as ESM when that compiles, or when
// the retry then fails on module syntax (node_contextify.cc ShouldRetryAsESM).
const CJS_ONLY_ERRORS = [
  "Identifier '__filename' has already been declared",
  "Identifier '__dirname' has already been declared",
  "Identifier 'require' has already been declared",
  "Identifier 'module' has already been declared",
  "Identifier 'exports' has already been declared",
  'await is only valid in async functions and the top level bodies of modules',
];
const CJS_PARAMETERS = ['exports', 'require', 'module', '__filename', '__dirname'];

function nodeDetectsModule(source) {
  const compiled = attempt(() => vm.compileFunction(source, CJS_PARAMETERS));
  if (!compiled.error) return { format: 'cjs' };
  const message = compiled.error.message;
  if (ESM_ERRORS.includes(message)) return { format: 'esm' };
  if (CJS_ONLY_ERRORS.includes(message)) {
    const retried = attempt(() => vm.compileFunction(`(async function() {${source}})()`, []));
    if (!retried.error) return { format: 'esm-by-retry', message };
    if (ESM_ERRORS.includes(retried.error.message)) return { format: 'esm' };
  }
  return { format: 'error', message };
}

// ---------------------------------------------------------------------------

function compareFile(entry, stats) {
  const source = entry.read();
  const ours = attempt(() => project(scanModuleSync(source), source));
  const theirs = attempt(() => reference(source));
  stats.files++;
  if (ours.error && ours.error.code !== 'Invalid_Syntax') throw ours.error;
  const context = { key: entry.key, source, kessel: ours.value, lexer: theirs.value };
  let diffs = [];
  if (ours.error && theirs.error) {
    // Agreement, unless the source is valid: then `classify` refuses it.
    stats.bothReject++;
    if (!oracleParse(source).valid) return null;
    diffs = [{ path: 'reject', field: 'bothReject' }];
  } else if (ours.error) {
    stats.kesselRejects++;
    diffs = [{ path: 'reject', field: 'kesselRejects' }];
  } else if (theirs.error) {
    stats.lexerRejects++;
    diffs = [{ path: 'reject', field: 'lexerRejects', message: theirs.error.message }];
  } else {
    countFields(ours.value, theirs.value, stats);
    diffs = differences(ours.value, theirs.value);
    if (diffs.length === 0) {
      stats.exact++;
      return oracleAll ? checkOracle(entry, context, stats) : null;
    }
  }
  context.oracle = oracleParse(source);
  const classes = new Set();
  const unclassified = [];
  for (const diff of diffs) {
    const id = classify(diff, context);
    if (id === null) unclassified.push(diff); else classes.add(id);
  }
  if (classes.size === 0 && unclassified.length === 0) return null;
  return { key: entry.key, classes: [...classes].sort(), unclassified, diffs, context };
}

// --oracle-all: an exact match with es-module-lexer must also be right.
function checkOracle(entry, context, stats) {
  const oracle = oracleParse(context.source);
  if (!oracle.valid) { stats.oracle.skipped++; return null; }
  stats.oracle.checked++;
  const problems = oracleProblems(context.kessel, oracle.records);
  if (problems.length === 0) { stats.oracle.agree++; return null; }
  context.problems = problems;
  context.oracle = oracle;
  const id = classifyShared(context);
  if (id !== null) return { key: entry.key, classes: [id], unclassified: [], diffs: [], context };
  return { key: entry.key, classes: [], unclassified: [{ path: 'oracle' }], diffs: [], context };
}

function countFields(ours, theirs, stats) {
  for (const [kind, fields] of [['imports', IMPORT_FIELDS], ['exports', EXPORT_FIELDS]]) {
    const count = Math.min(ours[kind].length, theirs[kind].length);
    stats[kind].compared += count;
    stats[kind].lexerTotal += theirs[kind].length;
    stats[kind].kesselTotal += ours[kind].length;
    for (let index = 0; index < count; index++) {
      let whole = true;
      for (const field of fields) {
        if (ours[kind][index][field] === theirs[kind][index][field]) stats[kind].fields[field]++;
        else whole = false;
      }
      if (whole) stats[kind].exact++;
    }
  }
  stats.moduleFields.compared++;
  if (ours.facade === theirs.facade) stats.moduleFields.facade++;
  if (ours.hasModuleSyntax === theirs.hasModuleSyntax) stats.moduleFields.hasModuleSyntax++;
}

function newStats() {
  const list = fields => ({
    compared: 0, exact: 0, lexerTotal: 0, kesselTotal: 0,
    fields: Object.fromEntries(fields.map(field => [field, 0])),
  });
  return {
    files: 0, exact: 0, bothReject: 0, kesselRejects: 0, lexerRejects: 0, differing: 0,
    imports: list(IMPORT_FIELDS), exports: list(EXPORT_FIELDS),
    moduleFields: { compared: 0, facade: 0, hasModuleSyntax: 0 },
    oracle: { checked: 0, agree: 0, skipped: 0 },
    classes: {}, format: {
      files: 0, agree: 0, esm: 0, cjs: 0, unknown: 0, nodeRejects: 0, retryOnly: 0, differ: [],
    },
  };
}

// The format hint must agree with Node on every file Node can compile:
// ESM exactly when Node's detection says ESM, never ESM otherwise. Node's
// second-chance detection (top-level await, or a redeclared CommonJS wrapper
// variable, in a file without import/export) is outside the hint's
// definition; such files are counted, and must not be reported as ESM.
function compareFormat(entry, stats) {
  const source = entry.read();
  const scanned = attempt(() => scanModuleSync(source));
  if (scanned.error) return;
  const node = nodeDetectsModule(source);
  const format = scanned.value.format;
  stats.format.files++;
  stats.format[format.toLowerCase()]++;
  if (node.format === 'error') { stats.format.nodeRejects++; return; }
  if (node.format === 'esm-by-retry') {
    stats.format.retryOnly++;
    assert.notEqual(format, 'ESM', entry.key);
    return;
  }
  const agrees = (node.format === 'esm') === (format === 'ESM');
  if (agrees) stats.format.agree++;
  else stats.format.differ.push({ key: entry.key, kessel: format, node: node.format });
  if (format === 'CJS') assert.equal(scanned.value.has_commonjs_syntax, true);
  if (format === 'ESM') assert.equal(scanned.value.has_module_syntax, true);
}

function describe(result) {
  const lines = [`  ${result.key}  [${result.classes.join(', ')}]`];
  for (const diff of result.unclassified.slice(0, 6)) {
    lines.push(`    UNCLASSIFIED ${diff.path}: kessel=${JSON.stringify(diff.kessel)} ` +
      `lexer=${JSON.stringify(diff.lexer)} ${diff.message || ''}`);
  }
  for (const problem of (result.context.problems || []).slice(0, 6)) {
    lines.push(`    ORACLE DISAGREES ${problem}`);
  }
  return lines.join('\n');
}

function run() {
  const corpora = collectCorpora(root, onlyCorpus);
  const allow = JSON.parse(fs.readFileSync(allowPath, 'utf8'));
  const nextAllow = {};
  const failures = [];
  const report = {};
  for (const [name, entries] of Object.entries(corpora)) {
    const stats = newStats();
    const listed = allow[name] || {};
    nextAllow[name] = {};
    for (const entry of entries) {
      const result = compareFile(entry, stats);
      if (name !== 'test262' && name !== 'babel') compareFormat(entry, stats);
      if (result === null) continue;
      stats.differing++;
      for (const id of result.classes) stats.classes[id] = (stats.classes[id] || 0) + 1;
      nextAllow[name][entry.key] = result.classes;
      const expected = listed[entry.key];
      const same = expected && expected.join() === result.classes.join();
      if (result.unclassified.length !== 0) failures.push(`unclassified:\n${describe(result)}`);
      else if (!same) failures.push(`not allow-listed as observed:\n${describe(result)}`);
      if (verbose) console.log(describe(result));
    }
    for (const key of Object.keys(listed)) {
      // `shared-*` entries are only observable with --oracle-all.
      const oracleOnly = listed[key].every(id => id.startsWith('shared-'));
      if (oracleOnly && !oracleAll) { nextAllow[name][key] = listed[key]; continue; }
      if (!(key in nextAllow[name])) failures.push(`stale allow-list entry: ${name}/${key}`);
    }
    for (const item of stats.format.differ) {
      failures.push(`format differs from Node: ${name}/${item.key} ` +
        `kessel=${item.kessel} node=${item.node}`);
    }
    report[name] = stats;
    printStats(name, stats);
  }
  if (reportPath) fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  if (updateAllow) {
    fs.writeFileSync(allowPath, formatAllow(nextAllow));
    console.log(`rewrote ${path.relative(root, allowPath)}; review the diff`);
  }
  const blocking = updateAllow
    ? failures.filter(text => text.startsWith('unclassified') || text.startsWith('format'))
    : failures;
  if (blocking.length !== 0) {
    console.error(blocking.slice(0, 40).join('\n'));
    console.error(`\nModule lexer reference gate FAILED: ${blocking.length} problem(s)`);
    process.exit(1);
  }
  console.log('Module lexer reference gate passed');
}

// One file per line keeps allow-list diffs reviewable.
function formatAllow(allow) {
  const corpora = Object.entries(allow).map(([name, files]) => {
    const lines = Object.entries(files)
      .map(([key, classes]) => `  ${JSON.stringify(key)}: ${JSON.stringify(classes)}`);
    return `${JSON.stringify(name)}: {\n${lines.join(',\n')}${lines.length ? '\n' : ''}}`;
  });
  return `{\n${corpora.join(',\n')}\n}\n`;
}

function printStats(name, stats) {
  const fields = kind => Object.entries(stats[kind].fields)
    .map(([field, count]) => `${field} ${count}`).join(', ');
  console.log(`${name}: ${stats.files} files, ${stats.exact} exact, ` +
    `${stats.differing} differing (all classified), rejects: both ${stats.bothReject}, ` +
    `kessel-only ${stats.kesselRejects}, es-module-lexer-only ${stats.lexerRejects}`);
  for (const kind of ['imports', 'exports']) {
    const list = stats[kind];
    console.log(`  ${kind}: ${list.compared} compared (es-module-lexer ${list.lexerTotal}, ` +
      `kessel ${list.kesselTotal}), ${list.exact} exact; per field: ${fields(kind)}`);
  }
  const moduleFields = stats.moduleFields;
  console.log(`  module: ${moduleFields.compared} compared, facade ${moduleFields.facade}, ` +
    `hasModuleSyntax ${moduleFields.hasModuleSyntax}`);
  if (stats.format.files !== 0) {
    const format = stats.format;
    console.log(`  format vs Node: ${format.files} files (ESM ${format.esm}, CJS ${format.cjs}, ` +
      `Unknown ${format.unknown}); ${format.agree} agree with Node, ${format.nodeRejects} ` +
      `Node cannot compile, ${format.retryOnly} ESM only by Node's top-level-await retry`);
  }
  if (oracleAll) {
    const oracle = stats.oracle;
    console.log(`  oracle on exact matches: ${oracle.checked} checked, ${oracle.agree} agree, ` +
      `${oracle.skipped} not parseable by the oracle`);
  }
  for (const [id, count] of Object.entries(stats.classes).sort()) {
    assert.ok(CLASSES[id], `unknown class ${id}`);
    console.log(`  class ${id}: ${count} file(s)`);
  }
}

lexer.init.then(run).catch(error => {
  console.error(error);
  process.exit(1);
});
