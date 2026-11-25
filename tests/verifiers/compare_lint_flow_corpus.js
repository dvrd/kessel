'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { readChecksums, checksum } = require('./verify_real_world_inputs');

const root = path.resolve(__dirname, '../..');
const corpus = path.resolve(root, process.env.KESSEL_REAL_WORLD_ROOT || 'bench/real_world');
const [binary, oracle] = process.argv.slice(2);
const rules = ['getter-return', 'no-unreachable', 'no-fallthrough'];
const fixtures = [...readChecksums()];
const totals = Object.fromEntries(rules.map(name => [name, { matched: 0, kesselOnly: 0, oxlintOnly: 0, identicalFiles: 0 }]));
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-flow-corpus-'));

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

function lint(executable, args, files, output) {
  const run = spawnSync(executable, [...args, ...files], { cwd: folder, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  assert.ok([0, 1].includes(run.status), String(run.error || run.signal || run.stderr));
  return JSON.parse(run[output]);
}

function compareBatch(batch) {
  const records = new Map();
  for (const [index, [relative, digest]] of batch.entries()) {
    const bytes = fs.readFileSync(path.join(corpus, relative));
    assert.equal(checksum(bytes), digest, relative);
    // Isolate the tools from vendor ignores and configs while preserving the source language.
    const name = 'input-' + index + path.extname(relative);
    fs.writeFileSync(path.join(folder, name), bytes);
    records.set(name, { relative, starts: lineStarts(bytes), spans: new Map() });
  }
  const names = [...records.keys()];
  const reference = lint(oracle, ['--format=json', '--threads=1', '--no-ignore'], names, 'stdout');
  assert.equal(reference.number_of_files, names.length);
  for (const diagnostic of reference.diagnostics) {
    const rule = rules.find(name => diagnostic.code?.endsWith('(' + name + ')'));
    assert.ok(rule, 'Unexpected oxlint diagnostic: ' + diagnostic.message);
    const record = records.get(path.basename(diagnostic.filename));
    const { offset, length } = diagnostic.labels[0].span;
    const span = [rule, offset, offset + length].join('/');
    record.spans.set(span, (record.spans.get(span) || 0) + 1);
  }
  const reports = lint(binary, ['lint', '--format=json'], names, 'stderr');
  assert.deepEqual(reports.map(row => path.basename(row.filePath)).sort(), names.sort());
  for (const report of reports) {
    const record = records.get(path.basename(report.filePath));
    const different = new Set();
    for (const diagnostic of report.messages) {
      assert.ok(!diagnostic.fatal, record.relative + ': ' + diagnostic.message);
      const rule = diagnostic.ruleId;
      if (!rules.includes(rule)) continue;
      const start = record.starts[diagnostic.line - 1] + diagnostic.column - 1;
      const end = record.starts[diagnostic.endLine - 1] + diagnostic.endColumn - 1;
      assert.ok(Number.isSafeInteger(start) && Number.isSafeInteger(end) && end >= start, record.relative);
      const span = [rule, start, end].join('/');
      const remaining = record.spans.get(span) || 0;
      if (remaining > 0) {
        totals[rule].matched++;
        record.spans.set(span, remaining - 1);
      } else {
        totals[rule].kesselOnly++;
        different.add(rule);
      }
    }
    for (const [span, count] of record.spans) {
      if (!count) continue;
      const rule = span.split('/')[0];
      totals[rule].oxlintOnly += count;
      different.add(rule);
    }
    for (const rule of rules) if (!different.has(rule)) totals[rule].identicalFiles++;
  }
}

try {
  fs.writeFileSync(path.join(folder, '.oxlintrc.json'), JSON.stringify({
    plugins: [], categories: { correctness: 'off', suspicious: 'off', pedantic: 'off', style: 'off',
      restriction: 'off', nursery: 'off', perf: 'off' }, rules: Object.fromEntries(rules.map(name => [name, 'warn'])),
  }));
  // Keep parser memory and subprocess output bounded for large vendor bundles.
  const batchSize = 8;
  for (let first = 0; first < fixtures.length; first += batchSize) compareBatch(fixtures.slice(first, first + batchSize));
  console.log('Primary diagnostic ranges across ' + fixtures.length + ' pinned real-world files');
  console.table(totals);
} finally {
  fs.rmSync(folder, { recursive: true, force: true });
}
