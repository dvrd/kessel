#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-lint-config-'));
const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const oracle = process.argv[3];
let checks = 0;
let comparisons = 0;
const debug = 'no-debugger:error:1';
const equal = 'eqeqeq:error:2';

function write(file, value) {
  const absolute = path.join(directory, file);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  fs.writeFileSync(absolute, typeof value === 'string' ? value : JSON.stringify(value));
}

function run(engine, cwd, args, globalSpans = false) {
  const isReference = engine === oracle;
  const prefix = isReference ? ['--format', 'json'] : ['lint', '--format=json'];
  const result = spawnSync(engine, [...prefix, ...args], {
    cwd: path.join(directory, cwd), encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
  });
  assert.ok([0, 1].includes(result.status), result.stderr || result.stdout || String(result.error));
  const diagnostic = (rule, severity, line, column, length) => {
    if (!globalSpans) return [[rule, severity, line].join(':')];
    assert.ok(rule, 'Unexpected parser error in global environment catalog');
    if (rule !== 'no-undef' && rule !== 'no-global-assign') return [];
    return [[rule, severity, line, column, length].join(':')];
  };
  if (isReference) {
    if (result.stdout.startsWith('No files found to lint.')) return [];
    assert.ok(result.stdout.trimStart().startsWith('{'), args.join(' ') + '\n' + result.stdout);
    return JSON.parse(result.stdout).diagnostics.flatMap(d => {
      const rule = d.code?.match(/\(([^)]+)\)/)?.[1] || 'unused-disable-directive';
      const { line, column, length } = d.labels[0].span;
      if (globalSpans) assert.ok(d.code, d.message);
      return diagnostic(rule, d.severity, line, column, length);
    }).sort();
  }
  if (!result.stderr) return [];
  return JSON.parse(result.stderr).flatMap(file => file.messages).flatMap(d =>
    diagnostic(d.ruleId, d.severity === 2 ? 'error' : 'warning', d.line, d.column, d.endColumn - d.column)
  ).sort();
}

function compareGlobalEnvironments(rules) {
  const data = fs.readFileSync(path.join(__dirname, '../../src/lint_environment_data.odin'), 'utf8');
  const catalog = data.split('\n[environments]\n')[1].split('\n');
  const environments = catalog[0].split(' ');
  const names = catalog.slice(2, -2).flatMap(row => row.split(' ').slice(2));
  assert.equal(environments.length, 43);
  assert.equal(new Set(names).size, 1600);
  write('catalog/refs.js', names.map(name => 'void ' + name + ';\n' + name + ' = 1;').join('\n'));
  for (const env of environments) {
    write('catalog/.oxlintrc.json', { rules, env: { [env]: true }, categories: { correctness: 'off' } });
    const actual = run(binary, 'catalog', ['refs.js'], true);
    const expected = run(oracle, 'catalog', ['refs.js'], true);
    assert.equal(actual.length, expected.length, env);
    for (let i = 0; i < expected.length; i++) assert.equal(actual[i], expected[i], env);
    checks++;
    comparisons++;
  }
}

function check(expected, file, flags = [], cwd = '.', reference = expected) {
  const args = [...flags, file];
  expected.sort();
  assert.deepEqual(run(binary, cwd, args), expected, cwd + ' ' + args.join(' '));
  checks++;
  if (oracle && reference) {
    assert.deepEqual(run(oracle, cwd, args), reference.sort(), 'oxlint ' + cwd + ' ' + args.join(' '));
    comparisons++;
  }
}

function invalid(config, reason) {
  const result = spawnSync(binary, ['lint', '-c', config, 'main.js'], { cwd: directory, encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.match(result.stderr, reason);
  checks++;
}

try {
  const body = 'debugger;\nif (left == right) run();\n';
  for (const file of ['main.js', 'sub/deep/app.js', 'inherited/app.js', 'lib/tests/case.js', 'other/test.js', 'ignored/skip.js']) write(file, body);
  write('.oxlintrc.json', {
    rules: { 'no-debugger': 'off', eqeqeq: 'error' },
    overrides: [{ files: ['lib/tests/*.js'], rules: { 'no-debugger': 'warn' } }],
    ignorePatterns: ['ignored/*'],
  });
  write('sub/.oxlintrc.json', { rules: { 'no-debugger': 'error' } });
  write('inherited/.oxlintrc.json', { extends: ['../.oxlintrc.json'], rules: { 'no-debugger': 'error' } });

  check([equal], 'main.js');
  check([debug], 'sub/deep/app.js');
  check([debug], 'app.js', [], 'sub/deep');
  check([debug, equal], 'inherited/app.js');
  check([equal], 'other/test.js');
  check(['no-debugger:warning:1', equal], 'lib/tests/case.js');
  // Kessel promises that explicit CLI levels take priority over per-file overrides.
  const oxlintOverride = ['no-debugger:warning:1', equal];
  check([equal], 'lib/tests/case.js', ['-A', 'no-debugger'], '.', oxlintOverride);
  check([debug, equal], 'lib/tests/case.js', ['-D', 'no-debugger'], '.', oxlintOverride);
  check([equal], 'sub/deep/app.js', ['--disable-nested-config']);
  check([equal], 'sub/deep/app.js', ['-c', '.oxlintrc.json']);
  check([], 'ignored/skip.js');

  const named = [
    '/* eslint-disable no-debugger */', 'debugger;', '/* oxlint-enable */', 'debugger;',
    '/* oxlint-enable no-debugger */', 'debugger;',
  ].join('\n');
  const blanket = [
    '/* oxlint-disable */', 'debugger;', '/* eslint-enable no-debugger */', 'debugger;',
    '/* eslint-enable */', 'debugger;',
  ].join('\n');
  for (const [name, source] of [['named', named], ['blanket', blanket]]) {
    write('sub/' + name + '.js', source);
    check(['no-debugger:error:6'], 'sub/' + name + '.js');
  }
  write('sub/overlap.js', [
    '/* oxlint-disable no-debugger */', '/* eslint-disable */', 'debugger;',
    '/* oxlint-enable */', 'debugger;', '/* eslint-enable no-debugger */', 'debugger;',
  ].join('\n'));
  check(['no-debugger:error:7'], 'sub/overlap.js');

  // A qualified name closes only its own range, even though both spellings suppress the rule.
  write('sub/qualified.js', [
    '/* oxlint-disable eslint/no-debugger */', '/* oxlint-disable no-debugger */',
    '/* eslint-enable no-debugger */', 'debugger;', '/* oxlint-enable eslint/no-debugger */', 'debugger;',
  ].join('\n'));
  check(['no-debugger:error:6'], 'sub/qualified.js');
  write('sub/repeat.js', [
    '/* oxlint-disable no-debugger */', '/* oxlint-disable no-debugger */', 'debugger;',
    '/* oxlint-enable no-debugger */', 'debugger;',
  ].join('\n'));
  check(['no-debugger:error:5'], 'sub/repeat.js', ['--report-unused-disable-directives']);
  write('sub/overlap-used.js', [
    '/* oxlint-disable no-debugger */', '/* oxlint-disable */', 'debugger;',
    '/* oxlint-enable */', '/* oxlint-enable no-debugger */',
  ].join('\n'));
  check([], 'sub/overlap-used.js', ['--report-unused-disable-directives']);

  if (process.platform !== 'win32') {
    write('shared/settings.json', {rules:{'no-debugger':'error'}});
    for (const [project, config] of [['native','kessel.lint.json'], ['oxlint','.oxlintrc.json']]) {
      write('shared/' + project + '/source.js', named);
      fs.symlinkSync('../settings.json', path.join(directory, 'shared', project, config));
    }
    const files = ['shared/native/source.js','shared/oxlint/source.js'];
    const expected = ['no-debugger:error:4','no-debugger:error:6','no-debugger:error:6'];
    assert.deepEqual(run(binary, '.', files), expected);
    assert.deepEqual(run(binary, '.', files.reverse()), expected);
    checks += 2;
  }

  write('configs/first.json', { rules: { 'no-debugger': 'warn' } });
  write('configs/second.json', { rules: { 'no-debugger': 'error' } });
  write('configs/child.json', { extends: ['first.json', 'second.json'], rules: {eqeqeq: 'off'} });
  check([debug], 'main.js', ['-c', 'configs/child.json']);
  write('configs/child.json', { extends: ['second.json', 'first.json'] });
  check(['no-debugger:warning:1'], 'main.js', ['-c', 'configs/child.json']);
  write('configs/a.json', {extends: ['./first.json'], rules: { eqeqeq: 'error' }});
  write('configs/b.json', {extends: ['./first.json'], rules: { 'no-debugger': 'error' }});
  write('configs/child.json', {extends: ['a.json','b.json']});
  check([equal, debug], 'main.js', ['-c', 'configs/child.json']);
  write('configs/levels.json', { rules: { 'no-debugger': [0], eqeqeq: 1 } });
  check(['eqeqeq:warning:2'], 'main.js', ['-c', 'configs/levels.json']);
  write('configs/levels.json', { rules: { 'no-debugger': 'allow', eqeqeq: ['deny'] } });
  check([equal], 'main.js', ['-c', 'configs/levels.json']);
  write('kessel.lint.json', { rules: {eqeqeq: 'off','no-debugger':'error'} });
  check([debug], 'main.js', [], '.', false);
  check([equal], 'main.js', ['-c','.oxlintrc.json']);
  check(['no-debugger:error:4','no-debugger:error:6'], 'sub/named.js', ['-c','kessel.lint.json'], '.', false);
  check(['no-debugger:error:4','no-debugger:error:6'], 'sub/blanket.js', ['-c','kessel.lint.json'], '.', false);
  check(['no-debugger:error:6'], 'sub/named.js', ['-c','sub/.oxlintrc.json']);
  check(['no-debugger:error:6'], 'sub/blanket.js', ['-c','sub/.oxlintrc.json']);

  write('kessel.lint.json', { options: {reportUnusedDisableDirectives:'warn'} });
  write('sub/deep/clean.js', '// oxlint-disable no-debugger\n');
  check(['unused-disable-directive:warning:1'], 'sub/deep/clean.js', [], '.', false);
  write('sub/.oxlintrc.json', { options:{reportUnusedDisableDirectives:'off'} });
  const rootOnly = spawnSync(binary, ['lint','sub/deep/clean.js'], {cwd:directory,encoding:'utf8'});
  assert.equal(rootOnly.status, 2);
  assert.match(rootOnly.stderr, /root lint config/);
  checks++;

  // Multi-file consumers parse stderr once, including when a file has a syntax error.
  const escaped = process.platform === 'win32' ? 'δ escaped.js' : 'δ "escaped".js';
  write(escaped, 'debugger;');
  write('syntax.js', 'const = 1;');
  write('clean.js', 'export const ready = true;');
  const report = (...args) => {
    const result = spawnSync(binary, ['lint', '--format=json', '-c', 'configs/second.json', ...args],
      {cwd:directory, encoding:'utf8'});
    return {status:result.status, files:JSON.parse(result.stderr)};
  };
  const mixed = report(escaped, 'clean.js', 'syntax.js');
  assert.equal(mixed.status, 1);
  assert.deepEqual(mixed.files.map(f => f.filePath), [escaped,'clean.js','syntax.js']);
  assert.equal(mixed.files[0].messages[0].ruleId, 'no-debugger');
  assert.deepEqual(mixed.files[1].messages, []);
  assert.deepEqual(mixed.files[2].messages.map(d => [d.ruleId, d.fatal, d.line, d.column]), [[null,true,1,7]]);
  const threshold = report('--warn','no-debugger','--max-warnings','0',escaped);
  assert.equal(threshold.status, 1);
  assert.equal(threshold.files[0].messages[0].severity, 1);
  const quiet = report('--warn','no-debugger','--quiet',escaped);
  assert.equal(quiet.status, 0);
  assert.deepEqual(quiet.files[0].messages, []);
  checks += 3;

  const comparisonsSource = [
    'void (a == b);', 'void (a != null);', 'void (a === null);',
    'void (typeof a == "string");', 'void (1 == 2);', 'void (1 == "1");',
  ].join('\n');
  write('comparisons.js', comparisonsSource);
  for (const [setting, lines] of [
    [['error','smart'], [1,6]],
    [['error','always',{null:'ignore'}], [1,4,5,6]],
    [['error','always',{null:'never'}], [1,3,4,5,6]],
  ]) {
    write('configs/equality.json', {rules:{eqeqeq:setting}});
    check(lines.map(line => 'eqeqeq:error:' + line), 'comparisons.js', ['-c','configs/equality.json']);
  }
  write('configs/equality.json', {rules:{eqeqeq:['error','smart']}});
  check(['eqeqeq:warning:1','eqeqeq:warning:6'], 'comparisons.js', ['-c','configs/equality.json','-W','eqeqeq']);
  write('configs/invalid-equality.json', {rules:{eqeqeq:['error','always',{null:'bad'}]}});
  invalid('configs/invalid-equality.json', /invalid lint settings/);

  write('console.tsx', [
    'console.log(1);', 'console.warn(2);', "console['lo\\x67']();",
    'const view = <View log={console.info} />;', 'console[method]();', 'console?.error?.();',
    'console.log = report;', 'const saved = console;', 'console[`warn`]();',
    '// oxlint-disable-next-line no-console', 'console.log();',
    'export namespace A.B { export enum N { Count = console.count() } }',
    '@console.trace class Example { @console.info method() {} }',
  ].join('\n'));
  for (const [setting, lines] of [
    ['error', [1, 2, 3, 4, 6, 7, 9, 12, 13, 13]],
    [['error', { allow: ['log', 'warn'] }], [4, 6, 12, 13, 13]],
    [['error', { allow: ['error', 'trace', 'info', 'count'] }], [1, 2, 3, 7, 9]],
  ]) {
    write('configs/console.json', {
      categories: { correctness: 'off' },
      rules: { 'no-console': setting, 'no-empty-function': 'off', 'no-namespace': 'off' },
    });
    check(lines.map(line => 'no-console:error:' + line), 'console.tsx', ['-c','configs/console.json']);
  }
  for (const options of [{ allow: 'warn' }, { allow: [1] }, { methods: [] }]) {
    write('configs/invalid.json', {rules:{'no-console':['error',options]}});
    invalid('configs/invalid.json', /invalid lint settings/);
  }

  const globalRules = { 'no-undef': 'error', 'no-global-assign': 'error' };
  if (oracle) compareGlobalEnvironments(globalRules);
  const undef = n => 'no-undef:error:' + n;
  const readonly = n => 'no-global-assign:error:' + n;
  write('globals/app.js', [
    'void injected;', 'injected = 1;', 'mutable++;', 'void console;',
    'function local(injected) { injected = 2; return injected; }',
    'function args() { return (() => arguments[0])(); }',
    'void (() => arguments[0]);', 'void missing;', 'void typeof undeclared;', 'local(1); args();',
  ].join('\n'));
  for (const [read, writeAccess] of [['readonly','writable'], ['readable','writeable'], [false,true]]) {
    write('globals/.oxlintrc.json', { rules: globalRules, globals: { injected: read, mutable: writeAccess, console: 'off' } });
    check([readonly(2), undef(4), undef(7), undef(8)], 'globals/app.js');
  }

  write('env/base.js', 'void document;\nvoid process;\nvoid it;\nlocation = null;\nwindow = null;\nPromise = null;\n');
  for (const [env, expected] of [
    [{}, [undef(1),undef(2),undef(3),undef(4),undef(5),readonly(6)]],
    [{ browser: true }, [undef(2),undef(3),readonly(5),readonly(6)]],
    [{ node: true, jest: true }, [undef(1),undef(4),undef(5),readonly(6)]],
    [{ browser: true, worker: true, node: true, jest: true }, [readonly(5),readonly(6)]],
    [{ worker: true, browser: false }, [undef(1),undef(2),undef(3),readonly(4),undef(5),readonly(6)]],
  ]) {
    write('env/.oxlintrc.json', { rules: globalRules, env });
    check(expected, 'env/base.js');
  }
  const layerSource = 'void baseName;\nchildName++;\nvoid window;\nvoid process;\n';
  for (const file of ['layer.js','layer.test.js','layer.web.test.js']) write('env/' + file, layerSource);
  write('env/parent.json', { globals: { baseName: 'readonly', childName: 'readonly' }, env: { node: true } });
  write('env/.oxlintrc.json', {
    extends: ['./parent.json'], rules: globalRules, globals: { childName: 'writable' },
    overrides: [
      { files: ['*.test.js'], globals: { childName: 'readonly' }, env: { browser: true, node: false } },
      { files: ['*.web.test.js'], globals: { baseName: 'off' }, env: { node: true } },
    ],
  });
  check([undef(1),undef(3),undef(4)], 'env/layer.js');
  check([undef(1),readonly(2),undef(4)], 'env/layer.test.js');
  check([undef(1),readonly(2)], 'env/layer.web.test.js');
  const layers = ['env/layer.web.test.js', 'env/layer.js', 'env/layer.test.js'];
  const combined = [undef(1),readonly(2),undef(1),undef(3),undef(4),undef(1),readonly(2),undef(4)].sort();
  for (const files of [layers, [...layers].reverse()]) {
    assert.deepEqual(run(binary, '.', files), combined);
    checks++;
  }
  write('env/kessel.lint.json', { extends: ['./parent.json'], rules: globalRules, globals: { childName: true } });
  check([undef(3)], 'env/layer.js', [], '.', false);
  write('env/off.js', 'void Promise;\nPromise = 1;\n');
  for (const file of ['kessel.lint.json', '.oxlintrc.json']) {
    write('env/' + file, { rules: globalRules, globals: { Promise: 'off' }, env: { builtin: false } });
  }
  check([undef(1), undef(2)], 'env/off.js', [], '.', false);
  check([], 'env/off.js', ['-c', 'env/.oxlintrc.json']);
  for (const key of ['env','globals']) {
    for (const setting of [[], null, { name: 1 }]) {
      for (const fields of [{ [key]: setting }, { overrides: [{ files: ['*.js'], [key]: setting }] }]) {
        write('configs/invalid.json', fields);
        invalid('configs/invalid.json', /invalid lint settings/);
      }
    }
  }

  // Categories, in the config and on the command line, select the same rules
  // and severities as oxlint. Each line of the source trips one rule of one
  // category: correctness, pedantic, restriction, suspicious.
  write('categories/app.js', 'debugger;\nif (value === value) run();\nvar legacy = 1; run(legacy);\nnew Thing();\n');
  const cat = { debug: 'no-debugger', self: 'no-self-compare', legacy: 'no-var', created: 'no-new' };
  const at = (rule, severity) => rule + ':' + severity + ':' + (Object.values(cat).indexOf(rule) + 1);
  const categoryCheck = (categories, flags, expected) => {
    write('categories/.oxlintrc.json', { categories });
    check(expected, 'app.js', flags, 'categories');
  };
  categoryCheck({ correctness: 'warn' }, [], [at(cat.debug, 'warning')]);
  categoryCheck({ correctness: 'error', pedantic: 'warn' }, [], [at(cat.debug, 'error'), at(cat.self, 'warning')]);
  categoryCheck({ correctness: 'off', restriction: 'warn', suspicious: 'error' }, [],
    [at(cat.legacy, 'warning'), at(cat.created, 'error')]);
  categoryCheck({ correctness: 'warn' }, ['-D', 'pedantic'], [at(cat.debug, 'warning'), at(cat.self, 'error')]);
  categoryCheck({ correctness: 'warn' }, ['-A', 'all', '-D', 'no-debugger'], [at(cat.debug, 'error')]);
  categoryCheck({ correctness: 'warn' }, ['-W', 'restriction', '-A', 'no-var'], [at(cat.debug, 'warning')]);
  categoryCheck({ correctness: 'warn' }, ['--allow', 'correctness', '--deny', 'suspicious'], [at(cat.created, 'error')]);

  write('configs/invalid.json', {extends:'./missing.json'});
  invalid('configs/invalid.json', /missing\.json/);
  write('configs/invalid.json', {extends:'./other.json'});
  write('configs/other.json', {extends:'./invalid.json'});
  invalid('configs/invalid.json', /cyclic lint config/);
  write('configs/invalid.json', {extends:[123]});
  invalid('configs/invalid.json', /expected lint config path/);
  for (const options of [{destructuring:'some'}, {ignoreReadBeforeAssign:1}, {unknown:true}]) {
    write('configs/invalid.json', {rules:{'prefer-const':['error',options]}});
    invalid('configs/invalid.json', /invalid lint settings/);
  }
  console.log(checks + ' lint configuration checks passed' + (oracle ? ', including ' + comparisons + ' oxlint comparisons.' : '.'));
} finally {
  fs.rmSync(directory, {recursive:true,force:true});
}
