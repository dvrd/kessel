'use strict';

// Measures diagnostic-range agreement between `kessel lint` and the pinned
// oxlint executable, one rule at a time.
//
// Fixture mode extracts the `pass` and `fail` vectors from the rule's Rust
// source at the pinned Oxc commit, lints every case with both tools and
// compares the multiset of primary diagnostic byte ranges per case. Corpus
// mode (--corpus) enables the same rules over the pinned real-world files.
//
// A rule that Kessel does not implement trivially agrees on every `pass`
// case, so the report keeps `fail` agreement separate. That number is the
// one that shows whether a rule is implemented.
//
// Columns: `fixtures` cases compared, `skipped` cases the scanner or the
// oxlint configuration could not express, `rejected` cases the oxlint parser
// refuses (no rule ran, so nothing to compare), `asJs` cases compared under a
// .js name because oxlint rejects them as TypeScript, `parseErrors` compared
// cases on which Kessel reported a fatal diagnostic.
//
// Usage:
//   node compare_lint_rule_fixtures.js <kessel> <oxlint> [flags] [plugin/rule ...]
// Without rule names the rules recorded in tests/lint/upstream_parity.json
// are compared and must reproduce the recorded numbers.
//   --corpus    also compare the 467 pinned real-world files. Set
//               KESSEL_ORACLE_CORPUS_CACHE to a file to reuse oxlint's results.
//   --update    rewrite the recorded numbers instead of asserting them
//   --verbose   print every differing case

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const pin = require('../../OXC_ORACLE.json');
const manifestPath = path.join(root, 'tests/lint/upstream_parity.json');
// A few agreed `fail` cases per rule, kept so `task test:lint` can check the
// ranges without oxlint or the Oxc checkout (verify_lint_parity_cases.js).
const casesPath = path.join(root, 'tests/lint/parity_cases.json');
const CASES_PER_RULE = 3;
const CASE_SOURCE_MAX = 160;
const agreedCases = {};

const flags = new Set(process.argv.slice(2).filter(arg => arg.startsWith('--')));
const positional = process.argv.slice(2).filter(arg => !arg.startsWith('--'));
const knownFlags = ['--corpus', '--update', '--verbose', '--oracle-only', '--no-fixtures'];
for (const flag of flags) assert.ok(knownFlags.includes(flag), 'Unknown flag ' + flag);
assert.ok(positional.length >= 2, 'Expected <kessel> <oxlint> [flags] [plugin/rule ...]');
const binary = path.resolve(positional[0]);
const oracle = positional[1].includes(path.sep) ? path.resolve(positional[1]) : positional[1];
const requested = positional.slice(2);
const verbose = flags.has('--verbose');

// A linked worktree shares the main checkout's sibling Oxc clone.
function oxcRepository() {
  if (process.env.KESSEL_OXC_REPO) return path.resolve(process.env.KESSEL_OXC_REPO);
  const common = execFileSync('git', ['-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
    { encoding: 'utf8' }).trim();
  return path.join(path.dirname(common), '../oxc');
}
const oxc = oxcRepository();

class Unsupported extends Error {}

// ---------------------------------------------------------------------------
// Rust fixture extraction. The scanner understands only the literal forms the
// fixture vectors use. Anything else marks that one case as skipped, and the
// skipped count is part of the recorded numbers.
// ---------------------------------------------------------------------------

function skipTrivia(source, index) {
  for (;;) {
    while (index < source.length && /\s/.test(source[index])) index++;
    if (source.startsWith('//', index)) {
      const end = source.indexOf('\n', index);
      index = end === -1 ? source.length : end;
    } else if (source.startsWith('/*', index)) {
      const end = source.indexOf('*/', index);
      assert.notEqual(end, -1);
      index = end + 2;
    } else {
      return index;
    }
  }
}

// Returns the end of a string literal starting at `index`, or -1.
function stringEnd(source, index) {
  const raw = /r(#*)"/y;
  raw.lastIndex = index;
  const match = raw.exec(source);
  if (match) {
    const end = source.indexOf('"' + match[1], raw.lastIndex);
    assert.notEqual(end, -1);
    return end + 1 + match[1].length;
  }
  if (source[index] !== '"') return -1;
  for (let i = index + 1; i < source.length; i++) {
    if (source[i] === '\\') i++;
    else if (source[i] === '"') return i + 1;
  }
  assert.fail('Unterminated Rust string');
}

function unescapeRust(body) {
  let out = '';
  for (let i = 0; i < body.length; i++) {
    if (body[i] !== '\\') { out += body[i]; continue; }
    const code = body[++i];
    if (code === 'n') out += '\n';
    else if (code === 'r') out += '\r';
    else if (code === 't') out += '\t';
    else if (code === '0') out += '\0';
    else if (code === '\\' || code === '"' || code === "'") out += code;
    else if (code === 'x') { out += String.fromCharCode(parseInt(body.slice(i + 1, i + 3), 16)); i += 2; }
    else if (code === 'u') {
      const end = body.indexOf('}', i);
      out += String.fromCodePoint(parseInt(body.slice(i + 2, end), 16));
      i = end;
    } else if (code === '\n' || code === '\r') {
      // A trailing backslash joins lines and drops the next line's indentation.
      while (i + 1 < body.length && /\s/.test(body[i + 1])) i++;
    } else {
      throw new Unsupported('Rust escape \\' + code);
    }
  }
  return out;
}

function stringValue(source, start, end) {
  const literal = source.slice(start, end);
  if (literal[0] === 'r') {
    const hashes = literal.indexOf('"') - 1;
    return literal.slice(hashes + 2, literal.length - hashes - 1);
  }
  return unescapeRust(literal.slice(1, -1));
}

// Returns the index after the bracket that closes the one before `index`.
function balancedEnd(source, index) {
  let depth = 1;
  while (index < source.length) {
    index = skipTrivia(source, index);
    const end = stringEnd(source, index);
    if (end !== -1) { index = end; continue; }
    const char = source[index++];
    if ('([{'.includes(char)) depth++;
    else if (')]}'.includes(char) && --depth === 0) return index;
  }
  assert.fail('Unbalanced Rust fixture');
}

function jsonMacro(text) {
  // Drop comments and trailing commas, which json! accepts and JSON does not.
  let out = '';
  for (let i = 0; i < text.length;) {
    const end = stringEnd(text, i);
    if (end !== -1 && text[i] === '"') { out += text.slice(i, end); i = end; continue; }
    if (text.startsWith('//', i)) { i = text.indexOf('\n', i); if (i === -1) break; continue; }
    out += text[i++];
  }
  out = out.replace(/,(\s*[\]}])/g, '$1');
  try { return JSON.parse(out); } catch { throw new Unsupported('json! contents'); }
}

function parseValue(source, index, helpers) {
  index = skipTrivia(source, index);
  const end = stringEnd(source, index);
  if (end !== -1) {
    let next = end;
    const suffix = /\s*\.(to_string|to_owned|into)\(\)/y;
    suffix.lastIndex = next;
    if (suffix.exec(source)) next = suffix.lastIndex;
    return { value: stringValue(source, index, end), end: next };
  }
  if (source[index] === '(') {
    const items = [];
    index++;
    for (;;) {
      index = skipTrivia(source, index);
      if (source[index] === ')') return { value: items, end: index + 1 };
      const item = parseValue(source, index, helpers);
      items.push(item.value);
      index = skipTrivia(source, item.end);
      if (source[index] === ',') index++;
    }
  }
  const word = /[A-Za-z_][A-Za-z_0-9:]*!?/y;
  word.lastIndex = index;
  const match = word.exec(source);
  if (!match) throw new Unsupported('fixture syntax ' + JSON.stringify(source.slice(index, index + 30)));
  const name = match[0];
  index = word.lastIndex;
  if (name === 'None') return { value: null, end: index };
  if (source[index] !== '(') throw new Unsupported('fixture value ' + name);
  const close = balancedEnd(source, index + 1);
  const inner = source.slice(index + 1, close - 1);
  if (name === 'Some') return { value: parseValue(inner, 0, helpers).value, end: close };
  if (name === 'json!' || name === 'serde_json::json!') return { value: jsonMacro(inner), end: close };
  if (name === 'PathBuf::from') return { value: parseValue(inner, 0, helpers).value, end: close };
  if (inner.trim() === '' && helpers.has(name)) return { value: helpers.get(name)(), end: close };
  throw new Unsupported('fixture call ' + name);
}

// Zero-argument helpers return an option value shared by several cases.
function helperFunctions(source) {
  const helpers = new Map();
  const pattern = /fn ([a-z_0-9]+)\(\) -> Option<(?:serde_json::)?Value> \{/g;
  for (let match; (match = pattern.exec(source));) {
    const start = pattern.lastIndex;
    const body = source.slice(start, balancedEnd(source, start) - 1);
    helpers.set(match[1], () => parseValue(body, 0, helpers).value);
  }
  return helpers;
}

function vectorCases(source, label, helpers) {
  const pattern = new RegExp('let (?:mut )?' + label + '(?:: [^=]+)? =\\s*vec!\\[', 'g');
  const match = pattern.exec(source);
  if (!match) return null;
  const cases = [];
  let skipped = 0;
  let index = pattern.lastIndex;
  for (;;) {
    index = skipTrivia(source, index);
    if (source[index] === ']') return { cases, skipped };
    // Find the end of this element first so an unsupported form skips one case.
    let end = index;
    for (;;) {
      end = skipTrivia(source, end);
      const text = stringEnd(source, end);
      if (text !== -1) { end = text; continue; }
      if (source[end] === ',' || source[end] === ']') break;
      end = '([{'.includes(source[end]) ? balancedEnd(source, end + 1) : end + 1;
    }
    try {
      const parsed = parseValue(source.slice(index, end), 0, helpers);
      assert.equal(skipTrivia(source.slice(index, end), parsed.end), end - index);
      cases.push(testCase(parsed.value));
    } catch (error) {
      if (!(error instanceof Unsupported)) throw error;
      skipped++;
    }
    index = source[end] === ',' ? end + 1 : end;
  }
}

function testCase(value) {
  const tuple = Array.isArray(value) ? value : [value];
  const [source, options = null, settings = null, file = null] = tuple;
  if (typeof source !== 'string' || tuple.length > 4) throw new Unsupported('case shape');
  if (file !== null && typeof file !== 'string') throw new Unsupported('case path');
  if (settings !== null && (typeof settings !== 'object' || Array.isArray(settings))) throw new Unsupported('settings');
  return { source, options: options === null ? [] : Array.isArray(options) ? options : [options], settings, file };
}

function ruleFixtures(id) {
  const [plugin, name] = id.split('/');
  const file = 'crates/oxc_linter/src/rules/' + plugin.replaceAll('-', '_') + '/' + name.replaceAll('-', '_');
  let source;
  for (const candidate of [file + '.rs', file + '/mod.rs']) {
    const shown = spawnSync('git', ['-C', oxc, 'show', pin.oxc_git_commit + ':' + candidate],
      { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    if (shown.status === 0) { source = shown.stdout; break; }
  }
  assert.ok(source, 'No pinned Oxc source for ' + id);
  const helpers = helperFunctions(source);
  const pass = vectorCases(source, 'pass', helpers);
  const fail = vectorCases(source, 'fail', helpers);
  // Some rules keep their cases in a tests directory this scanner does not read.
  if (!pass || !fail) return null;
  const extension = /\.change_rule_path_extension\("([a-z.]+)"\)/.exec(source)?.[1] ?? 'tsx';
  const rulePath = /\.change_rule_path\("([^"]+)"\)/.exec(source)?.[1] ?? null;
  const cases = [...pass.cases.map(item => ({ ...item, kind: 'pass' })), ...fail.cases.map(item => ({ ...item, kind: 'fail' }))];
  for (const item of cases) item.file ??= rulePath;
  return { plugin, name, extension, cases, skipped: pass.skipped + fail.skipped };
}

// ---------------------------------------------------------------------------
// Linting and comparison.
// ---------------------------------------------------------------------------

// The CLI uses one-based byte columns. Oxlint's primary label is an absolute
// byte offset. Handle all ECMAScript line terminators, including CRLF as one.
function lineStarts(bytes) {
  const starts = [0];
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === 13) {
      if (bytes[i + 1] === 10) i++;
    } else if (bytes[i] === 0xe2 && bytes[i + 1] === 0x80 && [0xa8, 0xa9].includes(bytes[i + 2])) {
      i += 2;
    } else if (bytes[i] !== 10) {
      continue;
    }
    starts.push(i + 1);
  }
  return starts;
}

const offCategories = { correctness: 'off', suspicious: 'off', pedantic: 'off', style: 'off',
  restriction: 'off', nursery: 'off', perf: 'off' };

function qualified(plugin, name) { return plugin === 'eslint' ? name : plugin + '/' + name; }

function run(executable, args, cwd, output) {
  const result = spawnSync(executable, args, { cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  try { return JSON.parse(result[output]); } catch { return null; }
}

const ARGUMENT_BATCH = 1500;

// Lints `files` (paths relative to `cwd`) with both tools. Every directory may
// carry its own .oxlintrc.json, which both tools discover per file. `names`
// maps a file to the rule names whose diagnostics count for it. Returns null
// when either tool produced no report, for instance on a rejected config.
function lintBoth(cwd, files, names) {
  const spans = { kessel: new Map(), oxlint: new Map(), fatal: new Set(), rejected: new Set() };
  for (const file of files) { spans.kessel.set(file, []); spans.oxlint.set(file, []); }
  for (let first = 0; first < files.length; first += ARGUMENT_BATCH) {
    const batch = files.slice(first, first + ARGUMENT_BATCH);
    const reference = run(oracle, ['--format=json', '--no-ignore', '--threads=1', ...batch], cwd, 'stdout');
    // The CLI rejects some option shapes that the upstream test harness accepts.
    if (!reference) return null;
    for (const diagnostic of reference.diagnostics) {
      const file = path.relative(cwd, path.resolve(cwd, diagnostic.filename));
      const name = /\(([^()]+)\)$/.exec(diagnostic.code || '')?.[1];
      // A diagnostic without a rule code is a parse or early error. Oxlint runs
      // no rules on that file, so it cannot show what the rule would report.
      // TypeScript early errors carry a `TS(nnnn)` code and stop linting the same way.
      const early = !diagnostic.code || /^TS\(\d+\)$/.test(diagnostic.code);
      if (early && diagnostic.severity === 'error') spans.rejected.add(file);
      if (!names(file).has(name) || diagnostic.labels.length === 0) continue;
      const { offset, length } = primaryLabel(name, diagnostic.labels).span;
      spans.oxlint.get(file).push([name, offset, offset + length]);
    }
    const reports = run(binary, ['lint', '--format=json', ...batch], cwd, 'stderr');
    if (!reports) return null;
    for (const report of reports) {
      const file = path.relative(cwd, path.resolve(cwd, report.filePath));
      const starts = lineStarts(fs.readFileSync(path.join(cwd, file)));
      for (const diagnostic of report.messages) {
        if (diagnostic.fatal) spans.fatal.add(file);
        if (!names(file).has(diagnostic.ruleId)) continue;
        spans.kessel.get(file).push([diagnostic.ruleId, starts[diagnostic.line - 1] + diagnostic.column - 1,
          starts[diagnostic.endLine - 1] + diagnostic.endColumn - 1]);
      }
    }
  }
  return spans;
}

// These rules label the declaration first and the offending write last.
// Kessel reports the write, which is where the fix goes.
const LAST_LABEL_RULES = new Set(['no-class-assign', 'no-const-assign']);
const primaryLabel = (name, labels) => LAST_LABEL_RULES.has(name) ? labels.at(-1) : labels[0];

const order = (a, b) => a[1] - b[1] || a[2] - b[2];
const emptyResult = () => ({ fixtures: 0, skipped: 0, matched: 0, failTotal: 0, failMatched: 0, parseErrors: 0,
  rejected: 0, asJs: 0 });

// One directory per distinct (rule, options, settings) so each gets its own config.
function planGroups(ids, workspace, results) {
  const groups = [];
  for (const id of ids) {
    const fixtures = ruleFixtures(id);
    results[id] = emptyResult();
    if (!fixtures) continue;
    const { plugin, name, extension, cases, skipped } = fixtures;
    results[id].skipped = skipped;
    const byConfig = new Map();
    for (const [index, item] of cases.entries()) {
      const key = JSON.stringify([item.options, item.settings]);
      if (!byConfig.has(key)) byConfig.set(key, []);
      byConfig.get(key).push({ ...item, index });
    }
    for (const members of byConfig.values()) groups.push({ id, plugin, name, extension, members });
  }
  return groups;
}

function writeGroup(workspace, group, directory, extension) {
  const cwd = path.join(workspace, directory);
  fs.mkdirSync(cwd, { recursive: true });
  const { plugin, name, members } = group;
  fs.writeFileSync(path.join(cwd, '.oxlintrc.json'), JSON.stringify({
    ...(members[0].settings || {}), plugins: plugin === 'eslint' ? [] : [plugin], categories: offCategories,
    rules: { [qualified(plugin, name)]: ['warn', ...members[0].options] },
  }));
  return members.map(item => {
    const file = path.join(directory, item.file ? path.join('c' + item.index, item.file) : 'c' + item.index + '.' + extension);
    fs.mkdirSync(path.dirname(path.join(workspace, file)), { recursive: true });
    fs.writeFileSync(path.join(workspace, file), item.source);
    return file;
  });
}

// Lints a set of groups in one invocation per tool. If that fails, each group
// runs alone so one unusable configuration only loses its own cases.
function runGroups(workspace, groups, label, asJs, results) {
  const planned = groups.map((group, index) => {
    const directory = label + '-' + index;
    return { group, files: writeGroup(workspace, group, directory, asJs ? 'js' : group.extension) };
  });
  const owner = new Map();
  for (const entry of planned) for (const file of entry.files) owner.set(file, new Set([entry.group.name]));
  const names = file => owner.get(file) || new Set();
  let spans = lintBoth(workspace, planned.flatMap(entry => entry.files), names);
  const rejected = [];
  for (const { group, files } of planned) {
    const result = results[group.id];
    const local = spans || lintBoth(workspace, files, names);
    if (!local) { result.skipped += group.members.length; continue; }
    const retry = [];
    for (const [position, item] of group.members.entries()) {
      const file = files[position];
      if (local.rejected.has(file)) { retry.push(item); continue; }
      const actual = local.kessel.get(file).sort(order);
      const expected = local.oxlint.get(file).sort(order);
      const same = JSON.stringify(actual) === JSON.stringify(expected);
      result.fixtures++;
      if (asJs) result.asJs++;
      if (local.fatal.has(file)) {
        result.parseErrors++;
        if (verbose) console.log('--- ' + group.id + ' ' + item.kind + ' #' + item.index + ' Kessel fatal diagnostic\n' + item.source);
      }
      if (item.kind === 'fail') { result.failTotal++; if (same) result.failMatched++; }
      if (same) {
        result.matched++;
        const plain = !item.file && !item.settings && item.options.length === 0;
        const kept = agreedCases[group.id] ??= [];
        if (item.kind === 'fail' && plain && expected.length > 0 && kept.length < CASES_PER_RULE &&
            item.source.length <= CASE_SOURCE_MAX) {
          kept.push({ source: item.source, extension: asJs ? 'js' : group.extension,
            spans: expected.map(span => span.slice(1)) });
        }
        continue;
      }
      if (verbose) {
        console.log('--- ' + group.id + ' ' + item.kind + ' #' + item.index +
          (item.options.length ? ' ' + JSON.stringify(item.options) : ''));
        console.log(item.source);
        console.log('kessel ' + JSON.stringify(actual.map(span => span.slice(1))) +
          ' oxlint ' + JSON.stringify(expected.map(span => span.slice(1))));
      }
    }
    if (retry.length) rejected.push({ ...group, members: retry });
  }
  return rejected;
}

function compareFixtures(ids, workspace) {
  const results = {};
  const rejected = runGroups(workspace, planGroups(ids, workspace, results), 'g', false, results);
  // Plain JavaScript that only TypeScript mode rejects (duplicate members,
  // `with`) can still be compared when both tools read it as JavaScript.
  const retry = [];
  const final = [];
  for (const group of rejected) {
    const plain = group.members.filter(item => !item.file && group.extension !== 'js');
    const kept = group.members.filter(item => !plain.includes(item));
    if (plain.length) retry.push({ ...group, members: plain });
    if (kept.length) final.push({ ...group, members: kept });
  }
  final.push(...runGroups(workspace, retry, 'js', true, results));
  for (const group of final) {
    results[group.id].rejected += group.members.length;
    if (verbose) for (const item of group.members) console.log('--- ' + group.id + ' ' + item.kind + ' #' + item.index + ' rejected by the oxlint parser');
  }
  return results;
}

// Lints the pinned real-world files with one tool and returns, per file, the
// list of [rule, start, end] it reported for the given rules.
function corpusSpans(tool, ids, workspace) {
  const { readChecksums, checksum } = require('./verify_real_world_inputs');
  const corpus = path.resolve(root, process.env.KESSEL_REAL_WORLD_ROOT || 'bench/real_world');
  const fixtures = [...readChecksums()];
  const names = new Set(ids.map(id => id.split('/')[1]));
  assert.equal(names.size, ids.length, 'Corpus mode needs unique rule names');
  const cwd = path.join(workspace, 'corpus-' + tool);
  fs.mkdirSync(cwd);
  const plugins = [...new Set(ids.map(id => id.split('/')[0]).filter(plugin => plugin !== 'eslint'))];
  fs.writeFileSync(path.join(cwd, '.oxlintrc.json'), JSON.stringify({ plugins, categories: offCategories,
    rules: Object.fromEntries(ids.map(id => [qualified(...id.split('/')), 'warn'])) }));
  const result = {};
  // Keep parser memory and subprocess output bounded for large vendor bundles.
  const batchSize = 8;
  for (let first = 0; first < fixtures.length; first += batchSize) {
    const batch = fixtures.slice(first, first + batchSize);
    const files = batch.map(([relative, digest], index) => {
      const bytes = fs.readFileSync(path.join(corpus, relative));
      assert.equal(checksum(bytes), digest, relative);
      // Isolate the tools from vendor ignores and configs while preserving the source language.
      const file = 'input-' + (first + index) + path.extname(relative);
      fs.writeFileSync(path.join(cwd, file), bytes);
      return file;
    });
    for (const [relative] of batch) result[relative] = [];
    const at = file => batch[files.indexOf(path.basename(file))][0];
    if (tool === 'oxlint') {
      const report = run(oracle, ['--format=json', '--no-ignore', '--threads=4', ...files], cwd, 'stdout');
      assert.ok(report, 'oxlint produced no report for the corpus configuration');
      assert.equal(report.number_of_files, files.length);
      for (const diagnostic of report.diagnostics) {
        const name = /\(([^()]+)\)$/.exec(diagnostic.code || '')?.[1];
        assert.ok(diagnostic.code && !/^TS\(\d+\)$/.test(diagnostic.code),
          at(diagnostic.filename) + ': oxlint could not parse the file');
        if (!names.has(name) || diagnostic.labels.length === 0) continue;
        const { offset, length } = primaryLabel(name, diagnostic.labels).span;
        result[at(diagnostic.filename)].push([name, offset, offset + length]);
      }
    } else {
      const reports = run(binary, ['lint', '--format=json', ...files], cwd, 'stderr');
      assert.ok(reports, 'Kessel produced no report for the corpus configuration');
      assert.equal(reports.length, files.length);
      for (const report of reports) {
        const starts = lineStarts(fs.readFileSync(path.join(cwd, path.basename(report.filePath))));
        for (const diagnostic of report.messages) {
          assert.ok(!diagnostic.fatal, at(report.filePath) + ': Kessel reported a fatal diagnostic');
          if (!names.has(diagnostic.ruleId)) continue;
          result[at(report.filePath)].push([diagnostic.ruleId, starts[diagnostic.line - 1] + diagnostic.column - 1,
            starts[diagnostic.endLine - 1] + diagnostic.endColumn - 1]);
        }
      }
    }
    for (const file of files) fs.rmSync(path.join(cwd, file));
  }
  return result;
}

// The oracle's corpus diagnostics depend only on the pinned oxlint and the
// pinned files, so KESSEL_ORACLE_CORPUS_CACHE may name a file that keeps them
// between runs. A cache must contain every requested rule.
function oracleCorpus(ids, workspace) {
  const cache = process.env.KESSEL_ORACLE_CORPUS_CACHE;
  if (cache && fs.existsSync(cache)) {
    const stored = JSON.parse(fs.readFileSync(cache, 'utf8'));
    assert.equal(stored.oxlint, pin.oxlint_npm);
    for (const id of ids) assert.ok(stored.rules.includes(id), 'The oracle cache lacks ' + id);
    return stored.files;
  }
  const files = corpusSpans('oxlint', ids, workspace);
  if (cache) fs.writeFileSync(cache, JSON.stringify({ oxlint: pin.oxlint_npm, rules: ids, files }));
  return files;
}

function compareCorpus(ids, workspace) {
  const names = new Map(ids.map(id => [id.split('/')[1], id]));
  const totals = Object.fromEntries(ids.map(id => [id, { matched: 0, kesselOnly: 0, oxlintOnly: 0 }]));
  const expected = oracleCorpus(ids, workspace);
  if (flags.has('--oracle-only')) return totals;
  const actual = corpusSpans('kessel', ids, workspace);
  for (const relative of Object.keys(actual)) {
    const remaining = new Map();
    for (const span of expected[relative]) {
      if (names.has(span[0])) remaining.set(span.join('/'), (remaining.get(span.join('/')) || 0) + 1);
    }
    for (const span of actual[relative]) {
      const count = remaining.get(span.join('/')) || 0;
      const total = totals[names.get(span[0])];
      if (count > 0) { total.matched++; remaining.set(span.join('/'), count - 1); continue; }
      total.kesselOnly++;
      if (verbose) console.log('kessel only ' + relative + ' ' + span.join('/'));
    }
    for (const [span, count] of remaining) {
      totals[names.get(span.split('/')[0])].oxlintOnly += count;
      if (verbose && count) console.log('oxlint only ' + relative + ' ' + span);
    }
  }
  return totals;
}

const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-rule-reference-'));
try {
  assert.equal(execFileSync(oracle, ['--version'], { encoding: 'utf8' }).trim(), 'Version: ' + pin.oxlint_npm);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  assert.equal(manifest.oxlint, pin.oxlint_npm);
  assert.equal(manifest.oxc, pin.oxc_git_commit);
  const ids = requested.length ? requested : Object.keys(manifest.rules);
  // --no-fixtures and --oracle-only exist to fill the oracle corpus cache.
  const measured = flags.has('--no-fixtures') ? Object.fromEntries(ids.map(id => [id, emptyResult()]))
    : compareFixtures(ids, workspace);
  if (flags.has('--corpus')) {
    // Without explicit names, only rules with recorded corpus numbers take part.
    const corpusIds = requested.length ? ids : ids.filter(id => manifest.rules[id].corpus);
    const totals = compareCorpus(corpusIds, workspace);
    for (const id of corpusIds) measured[id].corpus = totals[id];
  }
  console.table(Object.fromEntries(ids.map(id => {
    const { corpus, ...row } = measured[id];
    return [id, corpus ? { ...row, corpusMatched: corpus.matched, kesselOnly: corpus.kesselOnly,
      oxlintOnly: corpus.oxlintOnly } : row];
  })));
  if (flags.has('--update')) {
    for (const id of ids) {
      // Without fixtures only the corpus numbers were measured.
      manifest.rules[id] = flags.has('--no-fixtures') ? { ...manifest.rules[id], corpus: measured[id].corpus }
        : { ...manifest.rules[id], ...measured[id] };
    }
    const sorted = Object.keys(manifest.rules).sort();
    const rows = sorted.map(id => '    ' + JSON.stringify(id) + ': ' + JSON.stringify(manifest.rules[id])).join(',\n');
    // `notes` explains, per rule, a difference from oxlint that Kessel keeps on purpose.
    const notes = Object.keys(manifest.notes || {}).sort().map(id =>
      '    ' + JSON.stringify(id) + ': ' + JSON.stringify(manifest.notes[id])).join(',\n');
    fs.writeFileSync(manifestPath, '{\n  "oxlint": ' + JSON.stringify(manifest.oxlint) + ',\n  "oxc": ' +
      JSON.stringify(manifest.oxc) + ',\n  "notes": {\n' + notes + '\n  },\n  "rules": {\n' + rows + '\n  }\n}\n');
    if (!flags.has('--no-fixtures')) {
      const cases = fs.existsSync(casesPath) ? JSON.parse(fs.readFileSync(casesPath, 'utf8')) : {};
      for (const id of ids) {
        if (agreedCases[id]?.length) cases[id] = agreedCases[id]; else delete cases[id];
      }
      const lines = Object.keys(cases).sort().map(id => '  ' + JSON.stringify(id) + ': [\n' +
        cases[id].map(item => '    ' + JSON.stringify(item)).join(',\n') + '\n  ]');
      fs.writeFileSync(casesPath, '{\n' + lines.join(',\n') + '\n}\n');
    }
  } else if (requested.length === 0) {
    // Recorded rules are a regression gate: agreement may only change with --update.
    for (const id of ids) {
      const { corpus: recordedCorpus, ...recorded } = manifest.rules[id];
      const { corpus, ...actual } = measured[id];
      if (!flags.has('--no-fixtures')) assert.deepEqual(actual, recorded, id + ' fixture agreement changed');
      if (corpus) assert.deepEqual(corpus, recordedCorpus, id + ' corpus agreement changed');
    }
    console.log('All ' + ids.length + ' recorded rules reproduced their agreement numbers.');
  }
} finally {
  fs.rmSync(workspace, { recursive: true, force: true });
}
