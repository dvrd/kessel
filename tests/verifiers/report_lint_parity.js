'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const pin = require('../../OXC_ORACLE.json').oxlint_npm;
const baseline = path.join(root, 'tests/baselines/oxlint_rules.json');
const executable = process.platform === 'win32' ? 'kessel.exe' : 'kessel';

function run(binary, args) {
  const result = spawnSync(binary, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr || String(result.error || result.status));
  return result.stdout;
}

function refresh(oxlint) {
  const version = run(oxlint, ['--version']).trim();
  assert.equal(version, 'Version: ' + pin);
  const catalogue = JSON.parse(run(oxlint, ['--rules', '--format', 'json']));
  const rules = catalogue.map(rule => ({
    id: rule.scope + '/' + rule.value,
    category: rule.category,
    typeAware: rule.type_aware,
    fix: rule.fix,
    default: rule.default,
  }));
  rules.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  assert.ok(rules.length > 0);
  assert.equal(new Set(rules.map(rule => rule.id)).size, rules.length);
  const rows = rules.map(rule => '    ' + JSON.stringify(rule)).join(',\n');
  fs.writeFileSync(baseline, '{\n  "version": ' + JSON.stringify(pin) +
    ',\n  "rules": [\n' + rows + '\n  ]\n}\n');
  console.log('Recorded ' + rules.length + ' rules from oxlint ' + pin);
}

function inventory(kessel) {
  const reference = JSON.parse(fs.readFileSync(baseline, 'utf8'));
  assert.equal(reference.version, pin);
  const registered = JSON.parse(run(kessel, ['lint', '--list-rules']));
  const names = new Set(registered.map(rule => rule.name));
  assert.ok(registered.length > 0);
  assert.equal(names.size, registered.length, 'duplicate Kessel rule names');
  assert.equal(new Set(registered.map(rule => rule.code)).size, registered.length, 'duplicate Kessel rule codes');

  const referenceByName = new Map();
  const plugins = Object.create(null);
  const missing = [];
  for (const rule of reference.rules) {
    const slash = rule.id.indexOf('/');
    assert.ok(slash > 0 && slash < rule.id.length - 1, 'invalid reference rule ID');
    const plugin = rule.id.slice(0, slash);
    const name = rule.id.slice(slash + 1);
    const ids = referenceByName.get(name) || [];
    ids.push(rule.id);
    referenceByName.set(name, ids);
    const totals = plugins[plugin] ??= { rules: 0, sameName: 0, missing: 0 };
    totals.rules++;
    if (names.has(name)) {
      totals.sameName++;
    } else {
      totals.missing++;
      missing.push(rule.id);
    }
  }
  const candidates = registered.map(rule => ({
    ...rule,
    referenceCandidates: referenceByName.get(rule.name) || [],
  }));
  return { oxlintVersion: pin, referenceRules: reference.rules.length, plugins, candidates, missing };
}

const [mode, ...args] = process.argv.slice(2);
if (mode === '--refresh') {
  assert.equal(args.length, 1, 'Pass the path to the pinned oxlint executable');
  refresh(args[0]);
} else {
  assert.ok(mode === undefined || mode === '--json', 'Expected --json or --refresh <oxlint>');
  const result = inventory(process.env.KESSEL_INVENTORY_BINARY || path.join(root, 'bin', executable));
  if (mode === '--json') {
    console.log(JSON.stringify(result, null, 2));
  } else {
    const matched = result.candidates.filter(rule => rule.referenceCandidates.length > 0).length;
    const ambiguous = result.candidates.filter(rule => rule.referenceCandidates.length > 1).length;
    console.log(`oxlint ${pin}: ${result.referenceRules} rules in ${Object.keys(result.plugins).length} plugins`);
    console.log(`Kessel: ${result.candidates.length} rules, ${matched} with a same-name reference, ${ambiguous} ambiguous`);
    console.table(result.plugins);
    // A shared name says nothing about behavior. The recorded comparisons do.
    const recorded = Object.values(require('../lint/upstream_parity.json').rules);
    const complete = recorded.filter(rule => rule.fixtures > 0 && rule.matched === rule.fixtures).length;
    console.log(`Upstream fixtures: ${recorded.length} rules compared with oxlint ${pin}, ` +
      `${complete} agree on every compared fixture (task test:lint:reference -- --upstream)`);
  }
}
