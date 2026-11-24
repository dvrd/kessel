#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-directives-'));
const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
let executions = 0;

function lint(source, ...flags) {
  const file = path.join(directory, 'sample.tsx');
  fs.writeFileSync(file, source);
  const result = spawnSync(binary, ['lint', '--format=json', ...flags, file], { cwd: directory, encoding: 'utf8' });
  const messages = result.stderr ? JSON.parse(result.stderr)[0].messages : [];
  assert.equal(result.status, messages.length ? 1 : 0, result.stderr);
  executions++;
  return messages.map(({ ruleId, line, column, severity }) => [ruleId, line, column, severity]);
}

const debuggerAt = (line, column = 1) => ['no-debugger', line, column, 2];
const unusedAt = (line, column = 1, severity = 1) => ['unused-disable-directive', line, column, severity];
try {
  for (const prefix of ['eslint', 'oxlint']) {
    const source = [
      'debugger;',
      '/* ' + prefix + '-disable no-debugger */ debugger;',
      '/* ' + prefix + '-disable eqeqeq */ debugger; x == 3;',
      '/* ' + prefix + '-enable no-debugger */ debugger; x == 3;',
      '/* ' + prefix + '-enable */',
      'x == 3;',
    ].join('\n');
    assert.deepEqual(lint(source, '--deny', 'eqeqeq'), [debuggerAt(1), debuggerAt(4, 33), ['eqeqeq', 6, 3, 2]]);
    assert.deepEqual(lint('const v = <div>// ' + prefix + '-disable</div>;\ndebugger;'), [debuggerAt(2)]);
    assert.deepEqual(lint('const t = `text ${(() => {\n// ' + prefix + '-disable-next-line\ndebugger;\n})()}`;\ndebugger;'), [debuggerAt(5)]);
    assert.deepEqual(lint('debugger; /* ' + prefix + '-disable */ debugger; /* ' + prefix + '-enable */ debugger;'), [debuggerAt(1), debuggerAt(1, 62)]);
    assert.deepEqual(lint('// ' + prefix + '-disablex\ndebugger;'), [debuggerAt(2)]);
    assert.deepEqual(lint('// ' + prefix + '-disable-next-line eslint/no-debugger -- reason\ndebugger;\ndebugger;'), [debuggerAt(3)]);
    assert.deepEqual(lint('// ' + prefix + '-disable -- generated code\ndebugger;\n/* ' + prefix + '-enable */ debugger;'), [debuggerAt(3, 21)]);
  }
  const checks = ['--report-unused-disable-directives'];
  assert.deepEqual(lint('/* eslint-disable */\n// oxlint-enable no-debugger\ndebugger;'), [debuggerAt(3)]);
  assert.deepEqual(lint('// oxlint-disable-next-line no-debugger, no-console\ndebugger;', ...checks), [unusedAt(1, 42)]);
  assert.deepEqual(lint('// oxlint-disable-next-line\nlet x = 1;', ...checks), [unusedAt(1)]);
  assert.deepEqual(lint('// oxlint-enable no-debugger', ...checks), [unusedAt(1)]);
  assert.deepEqual(lint('// eslint-disable\ndebugger;\n// eslint-enable', ...checks), []);
  assert.deepEqual(lint('/* eslint-disable-next-line\n   no-debugger */\ndebugger;\ndebugger;'), [debuggerAt(4)]);
  for (const newline of ['\n', '\r\n', '\r', '\u2028', '\u2029']) {
    const source = ['/* 🔍 */', '// oxlint-disable-next-line', 'debugger;', 'debugger;'].join(newline);
    assert.deepEqual(lint(source), [debuggerAt(4)]);
  }
  assert.deepEqual(lint('\n'.repeat(1200) + '// oxlint-disable-next-line\ndebugger;\ndebugger;'), [debuggerAt(1203)]);
  assert.deepEqual(lint('// oxlint-disable\n', '--report-unused-disable-directives-severity=error'), [unusedAt(1, 1, 2)]);
  fs.writeFileSync(path.join(directory, '.oxlintrc.json'), '{}');
  for (const newline of ['\n', '\r\n']) {
    const next = 'debugger; /* eslint-disable-next-line no-debugger */ debugger;';
    assert.deepEqual(lint([next, 'debugger;', 'debugger;'].join(newline), ...checks), [debuggerAt(1), debuggerAt(3)]);
    const current = 'debugger; /* eslint-disable-line no-debugger */ debugger;';
    assert.deepEqual(lint(current, ...checks), [debuggerAt(1, current.lastIndexOf('debugger;') + 1)]);
    const both = '/* eslint-disable-next-line no-debugger */ debugger; /* eslint-disable-line no-debugger */';
    assert.deepEqual(lint(both + newline + 'debugger;', ...checks), []);
  }
  assert.deepEqual(lint('// oxlint-enable', ...checks), [unusedAt(1, 3)]);
  assert.deepEqual(lint('/* eslint-enable */', ...checks), [unusedAt(1, 3)]);
  assert.deepEqual(lint('/* eslint-enable no-debugger, eqeqeq */', ...checks), [unusedAt(1, 18), unusedAt(1, 31)]);
  assert.deepEqual(lint('/* eslint-disable no-debugger */\ndebugger;\n/* eslint-enable no-debugger, eqeqeq */', ...checks), [unusedAt(3, 31)]);
  fs.writeFileSync(path.join(directory, 'kessel.lint.json'), JSON.stringify({options:{reportUnusedDisableDirectives:'error'}}));
  assert.deepEqual(lint('// oxlint-disable\n'), [unusedAt(1, 1, 2)]);
  assert.deepEqual(lint('// oxlint-disable\n', '--report-unused-disable-directives-severity', 'off'), []);
  console.log(executions + ' lint directive checks passed.');
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
