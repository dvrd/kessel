'use strict';

// Replay oxc-resolver's own test inputs through Kessel's SDK resolver and the
// pinned oxc-resolver binary, and require the same outcome for each.
//
// The inputs come from tests/verifiers/data/oxc_resolver_reference.json, which
// tests/runners/pack_resolver_reference.js packs from an oxc-resolver checkout:
// its fixture trees, the string literals of each Rust test file (replayed as
// requests from each of that suite's directories under each of its option
// sets), and its exports and imports field tables. No expected value is stored.
// The installed binary answers every case, so the gate cannot drift from it.
//
// Kessel is driven in require mode with explicitConditions, which is the
// configuration that corresponds to enhanced-resolve's model: extension and
// directory probing unless fullySpecified, and only the listed conditions.
// The binary always runs with builtinModules enabled, because Kessel always
// recognizes Node builtins.
//
// A difference passes only when a rule in DIFFERENCES claims it. Each rule
// names behavior where Kessel follows Node rather than enhanced-resolve, or an
// enhanced-resolve feature Kessel does not offer, and is reported with a count.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const repo = path.resolve(__dirname, '../..');
const packed = require('./data/oxc_resolver_reference.json');
const oxc = require(path.join(repo, 'bench/node_modules/oxc-resolver'));
const sdk = require(path.join(repo, 'npm/kessel'));
const suites = require('./module_resolver_reference_suites');

function materialize(root) {
  for (const [name, contents] of Object.entries(packed.files)) {
    const filename = path.join(root, name);
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    fs.writeFileSync(filename, Buffer.from(contents, 'base64'));
  }
  for (const [name, target] of Object.entries(packed.symlinks)) {
    const filename = path.join(root, name);
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    fs.symlinkSync(target, filename);
  }
}

// Translate enhanced-resolve options to the SDK's. A string result names an
// option Kessel does not offer, and the case is counted as unsupported.
function kesselOptions(options) {
  const result = { mode: 'require', explicitConditions: true, conditions: options.conditionNames || [] };
  for (const [key, value] of Object.entries(options)) {
    switch (key) {
      case 'conditionNames': break;
      case 'extensions': case 'mainFields': case 'mainFiles': case 'modules': case 'exportsFields':
      case 'importsFields': case 'extensionAlias': case 'roots': case 'restrictions':
      case 'fullySpecified': case 'preferRelative': case 'preferAbsolute': case 'resolveToContext':
        result[key] = value;
        break;
      case 'symlinks': result.preserveSymlinks = !value; break;
      case 'tsconfig':
        result.tsconfig = value.configFile;
        result.tsconfigReferences = value.references === 'auto';
        break;
      case 'aliasFields':
        if (JSON.stringify(value) !== '[["browser"]]' && JSON.stringify(value) !== '["browser"]') {
          return 'aliasFields other than browser';
        }
        result.browser = true;
        break;
      case 'alias': {
        const aliases = [];
        for (const [name, targets] of Object.entries(value)) {
          if (targets.length !== 1 || typeof targets[0] !== 'string') return 'alias with several targets or ignore';
          if (name.includes('*')) return 'alias with a wildcard';
          aliases.push({ name: name.replace(/\$$/, ''), target: targets[0], exact: name.endsWith('$') });
        }
        result.aliases = aliases;
        break;
      }
      case 'fallback': {
        const fallback = [];
        for (const [name, targets] of Object.entries(value)) {
          if (name.includes('*')) return 'fallback with a wildcard';
          for (const target of targets) {
            fallback.push({ name: name.replace(/\$$/, ''), target: target ?? false, exact: name.endsWith('$') });
          }
        }
        result.fallback = fallback;
        break;
      }
      default: return 'option ' + key;
    }
  }
  // enhanced-resolve reads only "main" unless told otherwise, also for browsers.
  if (result.browser && result.mainFields === undefined) result.mainFields = ['main'];
  return result;
}

function reference(options, directory, request) {
  let result;
  try {
    result = new oxc.ResolverFactory({ ...options, builtinModules: true }).sync(directory, request);
  } catch (error) {
    return { kind: 'error', message: 'threw ' + error.message };
  }
  if (result.builtin) return { kind: 'builtin', path: result.builtin.resolved };
  if (result.error) {
    if (result.error.startsWith('Path is ignored')) return { kind: 'ignored' };
    return { kind: 'error', message: result.error };
  }
  return { kind: 'file', path: result.path };
}

function kessel(options, directory, request) {
  try {
    const result = sdk.resolveModuleSync(request, path.join(directory, 'kessel-reference-importer.js'), options);
    if (result.kind === 'ignored') return { kind: 'ignored' };
    return { kind: result.kind, path: result.path };
  } catch (error) {
    return { kind: 'error', message: error.code || error.message };
  }
}

function same(expected, actual) {
  if (expected.kind !== actual.kind) return false;
  if (expected.kind === 'file') return expected.path === actual.path;
  if (expected.kind === 'builtin') return expected.path.replace(/^node:/, '') === actual.path.replace(/^node:/, '');
  return true;
}

function classify(test, expected, actual) {
  const rerun = options => reference(options, test.directory, test.request);
  for (const rule of suites.DIFFERENCES) {
    if (rule.applies(test, expected, actual, rerun)) return rule;
  }
  return null;
}

function main() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-resolver-reference-')));
  const verbose = process.argv.includes('--verbose');
  const only = process.argv.find(argument => argument.startsWith('--suite='));
  const totals = new Map();
  const claimed = new Map();
  const unsupported = new Map();
  const failures = [];
  try {
    materialize(root);
    for (const test of suites.cases(root, packed)) {
      if (only && test.suite !== only.slice(8)) continue;
      const tally = totals.get(test.suite) || { compared: 0, same: 0, different: 0, unsupported: 0 };
      totals.set(test.suite, tally);
      const options = kesselOptions(test.options);
      if (typeof options === 'string') {
        tally.unsupported += 1;
        unsupported.set(options, (unsupported.get(options) || 0) + 1);
        continue;
      }
      const expected = reference(test.options, test.directory, test.request);
      const actual = kessel(options, test.directory, test.request);
      tally.compared += 1;
      if (same(expected, actual)) {
        tally.same += 1;
        continue;
      }
      const rule = classify(test, expected, actual);
      if (rule) {
        tally.different += 1;
        claimed.set(rule.name, (claimed.get(rule.name) || 0) + 1);
        if (verbose) console.log(`[${rule.name}] ${test.suite} ${test.request}`);
        continue;
      }
      failures.push({ suite: test.suite, options: test.options, directory: test.directory.replace(root, ''),
        request: test.request, oxc: expected, kessel: actual });
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }

  let compared = 0;
  let matched = 0;
  for (const [suite, tally] of totals) {
    compared += tally.compared;
    matched += tally.same;
    console.log(`  ${suite}: ${tally.same}/${tally.compared} identical, ${tally.different} documented ` +
      `differences, ${tally.unsupported} unsupported`);
  }
  for (const [name, count] of claimed) console.log(`  difference: ${name}: ${count}`);
  for (const [name, count] of unsupported) console.log(`  unsupported: ${name}: ${count}`);
  for (const failure of failures.slice(0, process.env.KESSEL_REFERENCE_FAILURES_MAX || 60)) console.error(JSON.stringify(failure).replaceAll(fs.realpathSync(os.tmpdir()), ''));
  console.log(`oxc-resolver ${packed.source.version} reference: ${matched}/${compared} identical, ` +
    `${failures.length} unexplained`);
  assert.equal(require(path.join(repo, 'bench/node_modules/oxc-resolver/package.json')).version,
    packed.source.version, 'the packed inputs and the installed oxc-resolver must be the same release');
  assert.equal(failures.length, 0, `${failures.length} resolutions differ from oxc-resolver without a documented reason`);
  if (only) return;
  for (const rule of suites.DIFFERENCES) {
    assert.equal(claimed.get(rule.name) || 0, rule.expected, `the documented difference "${rule.name}" changed size`);
  }
  for (const [name, count] of Object.entries(suites.UNSUPPORTED)) {
    assert.equal(unsupported.get(name) || 0, count, `the unsupported case count for "${name}" changed`);
  }
}

main();
