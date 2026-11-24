'use strict';

// Compare Kessel's resolver with the running Node over every package installed
// under bench/node_modules. Each package contributes its entry point, each
// exports subpath (patterns are expanded over the files they can select), its
// manifest, and every JavaScript file as a deep subpath with and without the
// file extension. CommonJS requests use Module.createRequire(...).resolve.
// ES module requests use import.meta.resolve from a child process.
//
// import.meta.resolve deliberately swallows "not found" and "directory"
// failures and returns the unresolved URL, because the specification makes it
// infallible for well-formed URLs. The module loader itself still rejects such
// URLs when they are imported. The reference therefore treats a returned URL
// that does not name an existing file as the loader error it would raise, and
// likewise a node: URL that names no builtin, which fails when it is loaded.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createRequire, builtinModules } = require('node:module');
const { spawnSync } = require('node:child_process');

const repo = path.resolve(__dirname, '../..');
// bench/node_modules is the required corpus. The other installed trees widen
// the sample when their owners have run npm install.
const applications = ['bench', 'npm/kessel', 'editors/vscode'];
const sdk = require(path.join(repo, 'npm', 'kessel'));
const PATTERN_EXPANSION_MAX = 4096;

function listPackages(nodeModules, importer, found) {
  if (!fs.existsSync(nodeModules)) return;
  for (const entry of fs.readdirSync(nodeModules).sort()) {
    if (entry.startsWith('.')) continue;
    const directory = path.join(nodeModules, entry);
    if (!fs.statSync(directory).isDirectory()) continue;
    if (entry.startsWith('@')) {
      for (const scoped of fs.readdirSync(directory).sort()) {
        addPackage(path.join(directory, scoped), entry + '/' + scoped, importer, found);
      }
    } else {
      addPackage(directory, entry, importer, found);
    }
  }
}

function addPackage(directory, name, importer, found) {
  const manifestPath = path.join(directory, 'package.json');
  if (!fs.existsSync(manifestPath)) return;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  found.push({ directory, name, importer, manifest });
  // A nested dependency is only visible from inside its parent package.
  listPackages(path.join(directory, 'node_modules'), path.join(directory, 'package.json'), found);
}

function listFiles(directory, prefix, files) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === 'node_modules') continue;
    const relative = prefix === '' ? entry.name : prefix + '/' + entry.name;
    const absolute = path.join(directory, entry.name);
    if (fs.statSync(absolute).isDirectory()) listFiles(absolute, relative, files);
    else files.push(relative);
  }
  return files;
}

// Collect every "./…" string reachable from one exports target so a pattern
// key can be expanded over the files that any condition could select.
function targetStrings(target, strings) {
  if (typeof target === 'string') strings.push(target);
  else if (Array.isArray(target)) target.forEach(item => targetStrings(item, strings));
  else if (target && typeof target === 'object') {
    Object.values(target).forEach(item => targetStrings(item, strings));
  }
  return strings;
}

function expandPattern(key, target, files) {
  const requests = new Set();
  const star = key.indexOf('*');
  for (const candidate of targetStrings(target, [])) {
    const at = candidate.indexOf('*');
    if (at < 0 || !candidate.startsWith('./')) continue;
    const head = candidate.slice(2, at);
    const tail = candidate.slice(at + 1);
    for (const file of files) {
      if (!file.startsWith(head) || !file.endsWith(tail) || file.length < head.length + tail.length) continue;
      const capture = file.slice(head.length, file.length - tail.length);
      requests.add(key.slice(0, star) + capture + key.slice(star + 1));
      if (requests.size === PATTERN_EXPANSION_MAX) return requests;
    }
  }
  // One capture that matches no file checks the not-found path of the pattern.
  requests.add(key.slice(0, star) + 'kessel-missing-capture' + key.slice(star + 1));
  return requests;
}

function packageRequests(pkg) {
  const requests = new Set([pkg.name, pkg.name + '/package.json', pkg.name + '/']);
  const files = listFiles(pkg.directory, '', []);
  const exportsField = pkg.manifest.exports;
  if (exportsField && typeof exportsField === 'object' && !Array.isArray(exportsField)) {
    for (const [key, target] of Object.entries(exportsField)) {
      if (!key.startsWith('.')) continue;
      const subpaths = key.includes('*') ? expandPattern(key, target, files) : [key];
      for (const subpath of subpaths) requests.add(pkg.name + subpath.slice(1));
    }
  }
  for (const file of files) {
    if (!/\.(c|m)?js$|\.json$|\.node$/.test(file)) continue;
    requests.add(pkg.name + '/' + file);
    requests.add(pkg.name + '/' + file.replace(/\.[^./]+$/, ''));
    requests.add(pkg.name + '/' + path.posix.dirname(file));
  }
  return Array.from(requests);
}

// Focused packages for behavior the installed corpus does not exercise. Most
// rows pin a point where Node and enhanced-resolve disagree, so that Kessel's
// documented differences from oxc-resolver are checked against Node itself.
const SYNTHETIC_FILES = {
  'app/package.json': JSON.stringify({ name: 'app', exports: { '.': './main.js', './self': './a.js' },
    imports: { '#http': 'node:http', '#fs': 'fs', '#local': './a.js', '#dep': 'dep', '#dep/*': 'dep/lib/*.js',
      '#bare': './lib/x', '#folder/': './lib/', '#/slash': './a.js', '#null': null,
      '#choice': [{ unknown: './missing.js' }, './a.js'] } }),
  'app/main.js': '', 'app/a.js': '', 'app/a b.js': '', 'app/lib/x.js': '', 'app/lib/index.js': '',
  'app/dirOrFile.js': '', 'app/dirOrFile/index.js': '', 'app/nested/deep/entry.js': '',
  'app/node_modules/dep/package.json': JSON.stringify({ name: 'dep', main: './lib/main.js' }),
  'app/node_modules/dep/lib/main.js': '', 'app/node_modules/dep/lib/x.js': '',
  'app/node_modules/dep/dir/index.js': '', 'app/node_modules/dep/dir.js': '',
  'app/node_modules/folder/package.json': JSON.stringify({ exports: { './dist/': './lib/', './x': './lib/x',
    './dir': './lib', './null/*': null, './p/*': './lib/*.js', './p/internal/*': null } }),
  'app/node_modules/folder/lib/x.js': '', 'app/node_modules/folder/lib/index.js': '',
  'app/node_modules/folder/lib/internal/y.js': '',
  'app/node_modules/sync/package.json': JSON.stringify({ exports: { 'module-sync': './s.js', default: './d.js' } }),
  'app/node_modules/sync/s.js': '', 'app/node_modules/sync/d.js': '',
  'app/node_modules/addons/package.json': JSON.stringify({ exports: { 'node-addons': './a.js', default: './d.js' } }),
  'app/node_modules/addons/a.js': '', 'app/node_modules/addons/d.js': '',
  'app/node_modules/dual/package.json': JSON.stringify({ exports: {
    '.': { import: './esm.mjs', require: './cjs.cjs' }, './deep': { node: { import: './esm.mjs', default: './cjs.cjs' } },
    './array': ['not-relative', './cjs.cjs'], './browser': { browser: './b.js', default: './cjs.cjs' } } }),
  'app/node_modules/dual/esm.mjs': '', 'app/node_modules/dual/cjs.cjs': '', 'app/node_modules/dual/b.js': '',
  'app/node_modules/@scope/pkg/package.json': JSON.stringify({ name: '@scope/pkg' }),
  'app/node_modules/@scope/pkg/index.js': '', 'app/node_modules/@scope/pkg/sub/file.js': '',
  'app/node_modules/file.js': '',
  'bare/nested/entry.js': '', 'bare/a.js': '',
};
const SYNTHETIC_REQUESTS = ['app', 'app/self', 'app/a.js', '#http', '#fs', '#local', '#dep', '#dep/x', '#bare',
  '#folder/x.js', '#/slash', '#null', '#choice', '#missing', '#', '#/', './a.js', './a', './a.js?query',
  './a.js#fragment', './a%20b.js', './a b.js', './a%2Fb.js', './dirOrFile', './dirOrFile/', './lib', './lib/',
  '.', './', '..', '../app/a.js', 'dep', 'dep/', 'dep/lib/x', 'dep/lib/x.js', 'dep/dir', 'dep/dir/', 'dep/dir.js',
  'dep/missing', 'folder/dist/x.js', 'folder/x', 'folder/dir', 'folder/null/a', 'folder/p/x', 'folder/p/internal/y',
  'folder/lib/x.js', 'sync', 'addons', 'dual', 'dual/deep', 'dual/array', 'dual/browser', '@scope/pkg',
  '@scope/pkg/sub/file', '@scope/pkg/sub/file.js', '@scope', '@scope/', 'file', 'file.js', 'missing',
  'missing/../file.js', 'missing/../../a.js', 'missing/../dep/lib/x.js',
  'dep/lib/x.js?query', 'dep/lib/x.js#fragment', 'dep/lib/%78.js', 'dep?query', 'folder/x?query', './a.js%3Fquery',
  './%61.js', './a%2', './a%zz.js', './lib%2Fx.js', './lib%5cx.js', 'node:fs', 'fs', 'node:nope', 'node:',
  'fs/promises', 'node:test', 'test', 'sys', ...builtinModules];

// "#fs" from the three importers inside the app package scope.
const BUILTIN_IMPORTS_EXPECTED = 3;

function syntheticCases(scratch) {
  for (const [name, contents] of Object.entries(SYNTHETIC_FILES)) {
    const filename = path.join(scratch, name);
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    fs.writeFileSync(filename, contents);
  }
  // An importer reached through a directory link resolves from its real directory.
  fs.symlinkSync(path.join(scratch, 'app/nested'), path.join(scratch, 'app/linked'));
  const importers = ['app/main.js', 'app/nested/deep/entry.js', 'app/linked/deep/entry.js',
    'app/node_modules/dep/lib/main.js', 'bare/nested/entry.js'];
  const cases = [];
  for (const importer of importers) {
    for (const request of SYNTHETIC_REQUESTS) cases.push([request, path.join(scratch, importer)]);
    cases.push(['../../a.js', path.join(scratch, importer)], ['../..', path.join(scratch, importer)]);
  }
  return cases;
}

function nodeRequire(request, importer) {
  try {
    const resolved = createRequire(importer).resolve(request);
    if (!path.isAbsolute(resolved)) return { kind: 'builtin', path: resolved };
    return { kind: 'file', path: resolved };
  } catch (error) {
    return { kind: 'error', code: error.code };
  }
}

const IMPORT_HELPER = `
import fs from 'node:fs';
import { isBuiltin } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
const cases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const results = cases.map(([request, importer]) => {
  try {
    const url = import.meta.resolve(request, pathToFileURL(importer).href);
    if (url.startsWith('node:') && !isBuiltin(url)) return { kind: 'error', code: 'ERR_UNKNOWN_BUILTIN_MODULE' };
    if (!url.startsWith('file:')) return { kind: 'builtin', path: url };
    const filename = fileURLToPath(url);
    const stat = fs.statSync(filename, { throwIfNoEntry: false });
    if (!stat) return { kind: 'error', code: 'ERR_MODULE_NOT_FOUND' };
    if (stat.isDirectory()) return { kind: 'error', code: 'ERR_UNSUPPORTED_DIR_IMPORT' };
    return { kind: 'file', path: fs.realpathSync(filename) };
  } catch (error) {
    return { kind: 'error', code: error.code };
  }
});
fs.writeFileSync(process.argv[3], JSON.stringify(results));
`;

function nodeImportAll(cases, scratch) {
  const helper = path.join(scratch, 'resolve.mjs');
  const input = path.join(scratch, 'cases.json');
  const output = path.join(scratch, 'results.json');
  fs.writeFileSync(helper, IMPORT_HELPER);
  fs.writeFileSync(input, JSON.stringify(cases));
  const child = spawnSync(process.execPath,
    ['--experimental-import-meta-resolve', '--no-warnings', helper, input, output],
    { encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr || String(child.error));
  return JSON.parse(fs.readFileSync(output, 'utf8'));
}

function kessel(request, importer, mode) {
  try {
    const result = sdk.resolveModuleSync(request, importer, { mode });
    return result.kind === 'file' ? { kind: 'file', path: result.path } : result;
  } catch (error) {
    return { kind: 'error', code: error.code };
  }
}

// On a case-insensitive volume Node keeps the request's spelling of the final
// component ("pkg/handlers" yields handlers.js for a file stored as
// Handlers.js), so two spellings load one file as two modules. Kessel reports
// the stored spelling, which gives a bundler one identity per file. Such pairs
// are counted separately and must name the same file.
//
// One deliberate difference: an imports entry that names a builtin
// ("#fs": "fs"). Node's ES module loader resolves it to node:fs. Node's
// CommonJS loader resolves the same entry to the node:fs URL and then fails
// to convert that URL to a filename (ERR_INVALID_URL_SCHEME), so the entry
// cannot be required at all. Kessel reports the builtin in both modes.
function compare(expected, actual, mode) {
  if (mode === 'require' && expected.code === 'ERR_INVALID_URL_SCHEME' && actual.kind === 'builtin') {
    return 'builtin through imports';
  }
  if (expected.kind !== actual.kind) return 'different';
  if (expected.kind !== 'file' || expected.path === actual.path) return 'same';
  if (expected.path.toLowerCase() !== actual.path.toLowerCase()) return 'different';
  if (fs.realpathSync.native(expected.path) !== actual.path) return 'different';
  return 'same file, stored spelling';
}

function main() {
  const packages = [];
  for (const application of applications) {
    const directory = path.join(repo, application);
    listPackages(path.join(directory, 'node_modules'), path.join(directory, 'package.json'), packages);
    if (application === 'bench') {
      assert.ok(packages.length > 0, 'bench/node_modules holds no packages; run npm install in bench');
    }
  }
  const cases = [];
  for (const pkg of packages) {
    for (const request of packageRequests(pkg)) cases.push([request, pkg.importer]);
  }
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-resolver-node-')));
  const installed = cases.length;
  const totals = { require: [0, 0], import: [0, 0], 'synthetic require': [0, 0], 'synthetic import': [0, 0],
    'require of an imports entry naming a builtin, which Node cannot load': [0, BUILTIN_IMPORTS_EXPECTED] };
  const mismatches = [];
  const respelled = [];
  try {
    cases.push(...syntheticCases(scratch));
    const imported = nodeImportAll(cases, scratch);
    compareAll(cases, imported, installed, totals, mismatches, respelled);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
  report(packages, totals, mismatches, respelled);
}

function compareAll(cases, imported, installed, totals, mismatches, respelled) {
  cases.forEach(([request, importer], index) => {
    const references = { require: nodeRequire(request, importer), import: imported[index] };
    for (const mode of ['require', 'import']) {
      const actual = kessel(request, importer, mode);
      const tally = totals[index < installed ? mode : 'synthetic ' + mode];
      tally[1] += 1;
      const outcome = compare(references[mode], actual, mode);
      if (outcome === 'same') tally[0] += 1;
      else if (outcome === 'different') {
        mismatches.push({ mode, request, importer, node: references[mode], kessel: actual });
      } else if (outcome === 'builtin through imports') {
        totals['require of an imports entry naming a builtin, which Node cannot load'][0] += 1;
      } else {
        respelled.push(`${mode} ${request}: ${path.basename(references[mode].path)} is stored as ` +
          path.basename(actual.path));
      }
    }
  });
}

function report(packages, totals, mismatches, respelled) {
  for (const mismatch of mismatches.slice(0, 80)) console.error(JSON.stringify(mismatch));
  const counts = Object.entries(totals).map(([name, [same, all]]) => `${name} ${same}/${all}`).join(', ');
  console.log(`Node ${process.version} resolver reference: ${packages.length} installed packages, ${counts} ` +
    `identical, ${respelled.length} same file under its stored spelling`);
  for (const line of respelled) console.log('  ' + line);
  assert.equal(mismatches.length, 0, `${mismatches.length} resolutions differ from Node`);
  const builtin = totals['require of an imports entry naming a builtin, which Node cannot load'];
  assert.equal(builtin[0], builtin[1], 'the documented builtin-through-imports difference changed');
}

main();
