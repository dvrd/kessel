'use strict';

// Bundler gate. Every directory under tests/bundle/ is a small multi-file
// project. For each one the verifier runs the original entry with Node (as
// real ESM or CommonJS) and then every bundle variant, and requires the
// observable behaviour to be identical: the order of everything logged during
// evaluation, the exported values, and any error thrown.
//
// fixture.json (all keys optional):
//   entry      entry file name (default: the first entry.* present)
//   formats    output formats to check (default: ["esm", "cjs", "iife"];
//              ESM-only features such as top-level await list ["esm"], and
//              fixtures that need Node's require() leave out "iife", which
//              runs in a bare realm)
//   args       extra bundler arguments
//   expected   name of a file holding the expected behaviour, for inputs
//              Node cannot run natively (JSX, bundler-style resolution)
//   error      the build must fail with a message containing this text
//   contains / excludes   strings the default esm bundle must / must not contain
//   in_place   write the bundles next to the sources, for fixtures whose
//              bundle must still find an external package at run time
//   sourcemap  also build with --sourcemap and require every MARK_* string in
//              the output to map back to the line of the original file that
//              contains it
//
// Usage: node verify_bundle.js [kessel-binary] [--only=<fixture>] [--reference=<esbuild module dir>]

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { SourceMap } = require('node:module');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const args = process.argv.slice(2);
const binary = path.resolve(args.find(arg => !arg.startsWith('--')) || path.join(root, 'bin', 'kessel'));
const only = (args.find(arg => arg.startsWith('--only=')) || '').slice('--only='.length);
const referenceDir = (args.find(arg => arg.startsWith('--reference=')) || '').slice('--reference='.length);
const reference = referenceDir ? require(path.resolve(referenceDir)) : null;
const fixturesDir = path.join(root, 'tests', 'bundle');
const harness = path.join(__dirname, 'bundle_harness.mjs');
const temp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-bundle-')));
const ENTRY_NAMES = ['entry.mjs', 'entry.js', 'entry.cjs', 'entry.ts', 'entry.mts', 'entry.tsx', 'entry.jsx'];

// `node_modules` is ignored by git, so fixtures keep packages in a
// `node_modules_` directory that becomes `node_modules` in the working copy.
function materialize(name) {
  const target = path.join(temp, name, 'src');
  fs.cpSync(path.join(fixturesDir, name), target, { recursive: true });
  const pending = [target];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
      if (!item.isDirectory()) continue;
      let child = path.join(directory, item.name);
      if (item.name === 'node_modules_') {
        fs.renameSync(child, path.join(directory, 'node_modules'));
        child = path.join(directory, 'node_modules');
      }
      pending.push(child);
    }
  }
  return target;
}

// Fixtures run concurrently, so child processes are asynchronous.
function execute(command, argv, options) {
  return new Promise(resolve => {
    const child = spawn(command, argv, { ...options, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 120000);
    child.on('error', error => { clearTimeout(timer); resolve({ status: null, signal: 'spawn', stdout, stderr: String(error) }); });
    child.on('close', (status, signal) => { clearTimeout(timer); resolve({ status, signal, stdout, stderr }); });
  });
}

async function run(kind, file, flags = []) {
  const result = await execute(process.execPath, [harness, kind, file, ...flags], {
    cwd: path.dirname(file), env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  assert.equal(result.signal, null, `${file}: harness killed by ${result.signal}`);
  // Paths differ between the fixture and the bundle; behaviour must not.
  return (result.stdout + result.stderr).replaceAll(path.dirname(file), '<dir>');
}

function bundle(source, entry, outfile, format, extra) {
  return execute(binary, ['bundle', entry, '--outfile', outfile, '--format', format, ...extra], { cwd: source });
}

function entryKind(source, entry) {
  if (/\.(mjs|mts)$/.test(entry)) return 'esm';
  if (/\.(cjs|cts)$/.test(entry)) return 'cjs';
  const manifest = path.join(source, 'package.json');
  if (fs.existsSync(manifest) && JSON.parse(fs.readFileSync(manifest, 'utf8')).type === 'module') return 'esm';
  // Node decides by syntax for an untyped .js/.ts file; so does the fixture author.
  return /^\s*(import|export)\b/m.test(fs.readFileSync(path.join(source, entry), 'utf8')) ? 'esm' : 'cjs';
}

// Every marker in the bundle must lead back to its own line in its own file.
function checkSourceMap(label, outfile) {
  const code = fs.readFileSync(outfile, 'utf8');
  const mapFile = outfile + '.map';
  assert.ok(code.trimEnd().endsWith('//# sourceMappingURL=' + path.basename(mapFile)), `${label}: no sourceMappingURL`);
  const payload = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
  payload.sources.forEach((source, index) => {
    const original = path.resolve(path.dirname(mapFile), source);
    assert.equal(payload.sourcesContent[index], fs.readFileSync(original, 'utf8'), `${label}: sourcesContent of ${source}`);
  });
  const map = new SourceMap(payload);
  const lines = code.split('\n');
  let markers = 0;
  lines.forEach((line, lineIndex) => {
    for (const match of line.matchAll(/MARK_[A-Z_]+/g)) {
      const entry = map.findEntry(lineIndex, match.index);
      assert.ok(entry && entry.originalSource, `${label}: ${match[0]} is unmapped`);
      const file = path.resolve(path.dirname(mapFile), entry.originalSource.replace(/^file:\/\//, ''));
      const originalLine = fs.readFileSync(file, 'utf8').split('\n')[entry.originalLine];
      assert.ok(originalLine.includes(match[0]),
        `${label}: ${match[0]} maps to ${path.basename(file)}:${entry.originalLine + 1} (${JSON.stringify(originalLine)})`);
      markers += 1;
    }
  });
  assert.ok(markers >= 5, `${label}: expected the markers to survive, found ${markers}`);
}

let checks = 0;
const failures = [];

async function checkFixture(name) {
  const source = materialize(name);
  const configFile = path.join(source, 'fixture.json');
  const config = fs.existsSync(configFile) ? JSON.parse(fs.readFileSync(configFile, 'utf8')) : {};
  const entry = config.entry || ENTRY_NAMES.find(candidate => fs.existsSync(path.join(source, candidate)));
  assert.ok(entry, `${name}: no entry file`);
  const extra = config.args || [];
  const out = config.in_place ? path.join(source, 'out') : path.join(temp, name, 'out');
  fs.mkdirSync(out, { recursive: true });

  if (config.error) {
    const result = await bundle(source, entry, path.join(out, 'error.mjs'), 'esm', extra);
    checks += 1;
    assert.equal(result.status, 1, `${name}: expected the build to fail\n${result.stderr}`);
    assert.ok(result.stderr.includes(config.error), `${name}: expected "${config.error}" in\n${result.stderr}`);
    assert.ok(!fs.existsSync(path.join(out, 'error.mjs')), `${name}: a failed build wrote output`);
    return;
  }

  const sourceKind = entryKind(source, entry);
  const expected = config.expected
    ? fs.readFileSync(path.join(source, config.expected), 'utf8')
    : await run(sourceKind, path.join(source, entry));
  assert.ok(/^(EXPORTS|THROWN) /m.test(expected), `${name}: the original produced no result\n${expected}`);

  const variants = [];
  for (const format of config.formats || ['esm', 'cjs', 'iife']) {
    variants.push({ format, flags: [] });
    variants.push({ format, flags: ['--no-tree-shaking'] });
    variants.push({ format, flags: ['--minify'] });
  }
  for (const variant of variants) {
    const label = `${name} [${variant.format}${variant.flags.length ? ' ' + variant.flags.join(' ') : ''}]`;
    const suffix = variant.flags.join('').replaceAll('-', '');
    const extension = { esm: 'mjs', cjs: 'cjs', iife: 'iife.js' }[variant.format];
    const outfile = path.join(out, `bundle${suffix}.${extension}`);
    const formatFlags = variant.format === 'iife' ? ['--global-name', 'bundleResult'] : [];
    const mapFlags = config.sourcemap ? ['--sourcemap'] : [];
    const built = await bundle(source, entry, outfile, variant.format, [...extra, ...formatFlags, ...mapFlags, ...variant.flags]);
    checks += 1;
    assert.equal(built.status, 0, `${label}: build failed\n${built.stderr}`);
    // An ESM bundle of a CommonJS entry exports module.exports as its default.
    let flags = variant.format === 'esm' && sourceKind === 'cjs' ? ['--default'] : [];
    if (variant.format === 'iife') flags = ['--global=bundleResult'];
    const actual = await run(variant.format, outfile, flags);
    // Minification renames function-local bindings, and V8 quotes the binding
    // name in a TDZ error. The error must still occur; its spelling may differ.
    const comparable = text => variant.flags.includes('--minify')
      ? text.replace(/Cannot access '[^']+' before initialization/g, "Cannot access '?' before initialization") : text;
    assert.equal(comparable(actual), comparable(expected), `${label}: behaviour differs from the original`);
    if (config.sourcemap) checkSourceMap(label, outfile);
    if (variant.format === 'esm' && variant.flags.length === 0) {
      const code = fs.readFileSync(outfile, 'utf8');
      for (const text of config.contains || []) assert.ok(code.includes(text), `${label}: missing ${JSON.stringify(text)}`);
      for (const text of config.excludes || []) assert.ok(!code.includes(text), `${label}: unexpected ${JSON.stringify(text)}`);
    }
  }
  if (reference && !config.expected) {
    const outfile = path.join(out, 'reference.mjs');
    reference.buildSync({ entryPoints: [path.join(source, entry)], bundle: true, format: 'esm', platform: 'node', outfile, logLevel: 'silent' });
    const actual = await run('esm', outfile, sourceKind === 'cjs' ? ['--default'] : []);
    console.log(`  reference ${actual === expected ? 'agrees with' : 'DIFFERS from'} Node on ${name}`);
  }
}

const names = fs.readdirSync(fixturesDir, { withFileTypes: true })
  .filter(item => item.isDirectory() && (!only || item.name === only)).map(item => item.name).sort();
assert.ok(names.length > 0, 'no bundle fixtures found');
// A small pool keeps the gate fast without starving the other work on the machine.
async function main() {
  const queue = [...names];
  const workers = Array.from({ length: Math.min(4, os.availableParallelism()) }, async () => {
    while (queue.length > 0) {
      const name = queue.shift();
      try {
        await checkFixture(name);
      } catch (error) {
        failures.push(name);
        console.error(`FAIL ${name}\n${error.message}\n`);
      }
    }
  });
  await Promise.all(workers);
  fs.rmSync(temp, { recursive: true, force: true });
  console.log(`bundle fixtures: ${names.length - failures.length}/${names.length} passed (${checks} bundle runs)`);
  if (failures.length > 0) process.exit(1);
}

main();
