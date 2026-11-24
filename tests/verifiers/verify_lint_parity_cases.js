'use strict';

// Checks, without oxlint, that every rule recorded in
// tests/lint/upstream_parity.json still reports the byte ranges that the
// pinned oxlint reported on a few of its own upstream `fail` fixtures.
//
// tests/lint/parity_cases.json is written by compare_lint_rule_fixtures.js
// --update, which only keeps cases on which both tools agreed. This verifier
// is the cheap regression gate. The full comparison stays in
// `task test:lint:reference -- --upstream`.

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const binary = path.resolve(process.argv[2] || path.join(root, 'bin/kessel'));
const cases = require('../lint/parity_cases.json');
const manifest = require('../lint/upstream_parity.json');
const categories = ['correctness', 'suspicious', 'pedantic', 'style', 'restriction', 'nursery', 'perf'];
const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-parity-cases-'));

// The CLI uses one-based byte columns. Handle every ECMAScript line terminator.
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

try {
  const expected = new Map();
  for (const [index, id] of Object.keys(cases).sort().entries()) {
    assert.ok(manifest.rules[id], id + ' has cases but no recorded agreement');
    const [plugin, name] = id.split('/');
    const directory = path.join(workspace, 'r' + index);
    fs.mkdirSync(directory);
    // Each rule gets its own config so no other rule can report on its cases.
    fs.writeFileSync(path.join(directory, '.oxlintrc.json'), JSON.stringify({
      plugins: plugin === 'eslint' ? [] : [plugin],
      categories: Object.fromEntries(categories.map(category => [category, 'off'])),
      rules: { [plugin === 'eslint' ? name : id]: 'warn' },
    }));
    for (const [position, item] of cases[id].entries()) {
      const file = path.join('r' + index, 'c' + position + '.' + item.extension);
      fs.writeFileSync(path.join(workspace, file), item.source);
      expected.set(file, { id, name, item });
    }
  }
  assert.ok(expected.size > 0, 'No parity cases recorded');
  const run = spawnSync(binary, ['lint', '--format=json', ...expected.keys()],
    { cwd: workspace, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const reports = JSON.parse(run.stderr);
  assert.equal(reports.length, expected.size);
  for (const report of reports) {
    const file = path.relative(workspace, path.resolve(workspace, report.filePath));
    const { id, name, item } = expected.get(file);
    const starts = lineStarts(Buffer.from(item.source));
    const actual = report.messages.filter(message => message.ruleId === name).map(message =>
      [starts[message.line - 1] + message.column - 1, starts[message.endLine - 1] + message.endColumn - 1]);
    const order = (a, b) => a[0] - b[0] || a[1] - b[1];
    assert.deepEqual(actual.sort(order), [...item.spans].sort(order), id + '\n' + item.source);
  }
  console.log(expected.size + ' oxlint-agreed diagnostic cases reproduced for ' + Object.keys(cases).length + ' rules.');
} finally {
  fs.rmSync(workspace, { recursive: true, force: true });
}
