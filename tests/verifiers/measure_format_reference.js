'use strict';

// Measures how much of the real-world corpus `formatSync` prints exactly as
// the pinned Prettier does, at three levels:
//
//   * whole files that are byte-identical;
//   * top-level statements whose text is identical;
//   * statement snippets: every top-level statement and a fixed sample of
//     nested ones, cut from their files and formatted on their own.
//
// A snippet that Kessel formats differently from Prettier is a bug, so any
// such snippet fails the run. A snippet that Kessel leaves as written is only
// counted: unsupported syntax is meant to keep its text.
//
// With --typescript the snippets come instead from a fixed sample of the
// vendored TypeScript compiler cases and from any TypeScript sources under
// bench/node_modules, and the whole-file levels are skipped: those files are
// conformance cases, many of them invalid on purpose.
//
// Prettier is loaded from KESSEL_PRETTIER or from bench/node_modules. Its
// output is cached per source under the system temp directory, because
// formatting the large bundles takes minutes.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createRequire } = require('node:module');
const { formatSync } = require('../../npm/kessel');
const { prettier_npm } = require('../../OXC_ORACLE.json');

const root = path.resolve(__dirname, '../..');
const bench = createRequire(path.join(root, 'bench/package.json'));
const prettier = process.env.KESSEL_PRETTIER ? require(process.env.KESSEL_PRETTIER) : bench('prettier');
const { parseSync } = bench('oxc-parser');
const babel = bench('@babel/parser');
const corpus = path.resolve(root, process.env.KESSEL_REAL_WORLD_ROOT || 'bench/real_world');
const cacheRoot = path.join(os.tmpdir(), 'kessel-prettier-' + prettier.version);
const typescript = process.argv.includes('--typescript');
const NESTED_SAMPLE_PER_FILE = typescript ? 12 : 60;
const TYPESCRIPT_CASES = path.join(root, 'tests/vendor/typescript/tests/cases/compiler');
const TYPESCRIPT_CASE_COUNT = 1500;
const SNIPPET_BYTES_MAX = 6000;

const digest = text => crypto.createHash('md5').update(text).digest('hex');

async function reference(source, options) {
  const file = path.join(cacheRoot, digest(JSON.stringify(options) + source));
  if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, 'utf8'));
  let output = null;
  try { output = await prettier.format(source, options); } catch { /* Prettier rejects it. */ }
  fs.writeFileSync(file, JSON.stringify(output));
  return output;
}

function listFiles(directory, pattern = /\.m?js$/, found = []) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) listFiles(full, pattern, found);
    else if (pattern.test(entry.name)) found.push(full);
  }
  return found.sort();
}

function topLevelTexts(file, source) {
  const { program } = parseSync(file, source);
  return program.body.filter(node => node.type !== 'EmptyStatement')
    .map(node => source.slice(node.start, node.end));
}

// A fixed linear congruential sequence keeps the nested sample the same on
// every run.
function sampler() {
  let seed = 12345;
  return () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
}

function collectSnippets(source, random, snippets) {
  let ast;
  try {
    ast = babel.parse(source, { sourceType: 'unambiguous', allowReturnOutsideFunction: true,
      plugins: typescript ? ['typescript'] : [] });
  } catch { return; }
  const top = [], nested = [];
  (function visit(node, parentIsProgram) {
    if (!node || typeof node.type !== 'string') return;
    const isStatement = /Statement$|Declaration$/.test(node.type) &&
      node.type !== 'EmptyStatement' && node.type !== 'BlockStatement';
    if (isStatement) (parentIsProgram ? top : nested).push(node);
    for (const key in node) {
      if (key === 'loc' || key.endsWith('Comments')) continue;
      const value = node[key];
      if (Array.isArray(value)) value.forEach(child => visit(child, node.type === 'Program'));
      else if (value && typeof value === 'object') visit(value, node.type === 'Program');
    }
  })(ast.program, false);
  for (let i = nested.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [nested[i], nested[j]] = [nested[j], nested[i]];
  }
  const chosen = [...top.slice(0, NESTED_SAMPLE_PER_FILE * 2), ...nested.slice(0, NESTED_SAMPLE_PER_FILE)];
  for (const node of chosen) {
    const text = source.slice(node.start, node.end);
    if (text.length <= SNIPPET_BYTES_MAX) snippets.add(text);
  }
}

async function main() {
  assert.equal(prettier.version, prettier_npm, 'the reference must be the pinned Prettier');
  fs.mkdirSync(cacheRoot, { recursive: true });
  const totals = { files: 0, filesIdentical: 0, statements: 0, statementsIdentical: 0 };
  const snippets = new Set();
  const random = sampler();
  let files = typescript ? [] : listFiles(corpus);
  if (typescript) {
    const cases = listFiles(TYPESCRIPT_CASES, /\.ts$/).slice(0, TYPESCRIPT_CASE_COUNT);
    const installed = listFiles(path.join(root, 'bench/node_modules'), /(?<!\.d)\.ts$/);
    for (const file of [...cases, ...installed]) {
      collectSnippets(fs.readFileSync(file, 'utf8'), random, snippets);
    }
    console.log(`TypeScript sources: ${cases.length} compiler cases, ${installed.length} files under bench/node_modules`);
  }
  for (const file of files) {
    const name = path.relative(corpus, file);
    const source = fs.readFileSync(file, 'utf8');
    collectSnippets(source, random, snippets);
    const expected = await reference(source, { filepath: name });
    if (expected === null) continue;
    const actual = formatSync(name, source);
    totals.files++;
    if (actual === expected) totals.filesIdentical++;
    const ours = topLevelTexts(name, actual), theirs = topLevelTexts(name, expected);
    assert.equal(ours.length, theirs.length, name + ' has a different number of statements');
    totals.statements += ours.length;
    totals.statementsIdentical += ours.filter((text, index) => text === theirs[index]).length;
  }
  const snippet = { identical: 0, preserved: 0, different: 0, unparsed: 0 };
  const failures = [];
  for (const text of snippets) {
    // Prettier's layout of a generic arrow function depends on the file name,
    // so the reference formats under the name that Kessel is given.
    const expected = await reference(text, typescript
      ? { parser: 'typescript', filepath: 'snippet.ts' } : { parser: 'babel' });
    let actual;
    try { actual = formatSync(typescript ? 'snippet.ts' : 'snippet.js', text); } catch { actual = null; }
    // Out of its function a statement may not parse on its own.
    if (expected === null || actual === null) { snippet.unparsed++; continue; }
    if (actual === expected) snippet.identical++;
    else if (actual === text) snippet.preserved++;
    else { snippet.different++; failures.push(text); }
  }
  const percent = (part, whole) => (100 * part / whole).toFixed(2) + '%';
  const compared = snippet.identical + snippet.preserved + snippet.different;
  console.log(`Prettier ${prettier.version} reference on ${files.length} files:`);
  if (!typescript) {
    console.log(`  identical files: ${totals.filesIdentical}/${totals.files} (${percent(totals.filesIdentical, totals.files)})`);
    console.log(`  identical top-level statements: ${totals.statementsIdentical}/${totals.statements} (${percent(totals.statementsIdentical, totals.statements)})`);
  }
  console.log(`  identical statement snippets: ${snippet.identical}/${compared} (${percent(snippet.identical, compared)}), ` +
    `${snippet.preserved} left as written, ${snippet.different} formatted differently, ${snippet.unparsed} not parsed alone`);
  for (const text of failures.slice(0, 5)) console.error('formatted differently from Prettier:\n' + text + '\n');
  assert.equal(snippet.different, 0, 'a formatted statement must match Prettier');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
