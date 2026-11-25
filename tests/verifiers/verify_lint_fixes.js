#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const oracle = process.argv[3];
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-fix-'));
const file = path.join(dir, 'test.js');
const flags = ['-D', 'eqeqeq', '-D', 'no-debugger', '-A', 'no-empty'];
let checks = 0;
let comparisons = 0;

function lint(engine, modes, filename = file) {
  const args = engine === binary ? ['lint', '--format=json'] : ['-A', 'all', '--format', 'json'];
  const result = spawnSync(engine, [...args, ...flags, ...modes, filename], { cwd: dir, encoding: 'utf8' });
  assert.ok([0, 1].includes(result.status), result.stderr || result.stdout || String(result.error));
  if (engine === binary) return JSON.parse(result.stderr)[0].messages;
  return JSON.parse(result.stdout).diagnostics;
}

function check(source, expected, modes, compare = false) {
  fs.writeFileSync(file, source);
  const messages = lint(binary, modes);
  assert.equal(fs.readFileSync(file, 'utf8'), expected, modes.join(' ') + '\n' + source);
  assert.ok(messages.every(d => !d.fatal), JSON.stringify(messages));
  const before = fs.statSync(file, { bigint: true });
  assert.deepEqual(lint(binary, modes), messages);
  const after = fs.statSync(file, { bigint: true });
  assert.equal(after.ino, before.ino);
  assert.equal(after.mtimeNs, before.mtimeNs);
  checks++;
  if (compare && oracle) {
    fs.writeFileSync(file, source);
    const reference = lint(oracle, modes);
    assert.equal(fs.readFileSync(file, 'utf8'), expected, 'oxlint ' + modes.join(' ') + '\n' + source);
    const keys = reference.map(d => [d.code.match(/\(([^)]+)\)/)[1], d.labels[0].span.line]);
    assert.deepEqual(keys.sort(), messages.map(d => [d.ruleId, d.line]).sort());
    comparisons++;
  }
  return messages;
}

try {
  const input = 'let x; debugger; let y;\nvoid (1 == 2);\nvoid (a != b);\n';
  const safe = input.replace('debugger;', '').replace('1 ==', '1 ===');
  const dangerous = safe.replace('a !=', 'a !==');
  for (const [modes, expected] of [
    [[], input], [['--fix'], safe], [['--fix-suggestions'], input], [['--fix-dangerously'], dangerous],
    [['--fix', '--fix-suggestions'], safe], [['--fix', '--fix-dangerously'], dangerous],
    [['--fix-suggestions', '--fix-dangerously'], input],
    [['--fix-suggestions', '--fix-dangerously', '--fix'], dangerous],
  ]) check(input, expected, modes, true);

  for (const body of ['if (flag) debugger', 'for (;;) debugger', 'while (flag) debugger']) {
    check(body, body.replace('debugger', '{}'), ['--fix'], true);
  }
  for (const body of ['do debugger; while (flag);', 'label: debugger;', 'with (obj) debugger;']) {
    check(body, body.replace('debugger;', '{}'), ['--fix']);
  }
  check('if (x) debugger; else debugger;', 'if (x) {} else {}', ['--fix']);
  check('if (x) debugger /* retain */ ; else go();', 'if (x)  /* retain */ ; else go();', ['--fix']);
  check('void ((1) /* == */ == (2));', 'void ((1) /* == */ === (2));', ['--fix']);
  check('void (x == null);', 'void (x == null);', ['--fix'], true);
  check('void (typeof x == "string");', 'void (typeof x === "string");', ['--fix'], true);
  const coercion = 'typeof 0 == { valueOf() { return "number"; } }';
  assert.equal(vm.runInNewContext(coercion), true);
  check(coercion, coercion, ['--fix']);
  check(coercion, coercion.replace('==', '==='), ['--fix-dangerously']);
  const terms = ['null', 'undefined', 'true', '0', '1n', '"0"', '/x/', 'typeof 0',
    'Symbol.for("x")', '({ valueOf() { return "number"; } })', '[]', 'Object(0)'];
  const source = 'let results = [];\n' + terms.flatMap(left => terms.flatMap(right =>
    ['==', '!='].map(op => 'results.push(' + left + ' ' + op + ' ' + right + ');'))).join('\n') + '\nresults.join(",")';
  fs.writeFileSync(file, source);
  lint(binary, ['--fix']);
  const revised = fs.readFileSync(file, 'utf8');
  assert.notEqual(revised, source);
  assert.equal(vm.runInNewContext(revised), vm.runInNewContext(source));
  checks++;
  const guarded = '// eslint-disable-next-line eqeqeq\nvoid (1 == 2);';
  check(guarded, guarded, ['--fix-dangerously'], true);
  const broken = 'debugger; const bad = ;';
  fs.writeFileSync(file, broken);
  assert.ok(lint(binary, ['--fix-dangerously']).some(d => d.fatal));
  assert.equal(fs.readFileSync(file, 'utf8'), broken);
  checks++;

  for (const source of [
    'let x = 1\ndebugger;\n(function(){})()\nx',
    'let x = 1\n// end;\ndebugger;\n(function(){})()\nx',
    'function mode() { debugger; "use strict"; return this === undefined; } mode()',
  ]) {
    const expected = source.replace('debugger;', ';');
    check(source, expected, ['--fix']);
    assert.equal(vm.runInNewContext(expected), vm.runInNewContext(source));
  }
  const suggestions = ['--report-unused-disable-directives', '--fix-suggestions'];
  for (const eol of ['\n', '\r\n', '\r', '\u2028', '\u2029']) {
    const directive = '  // eslint-disable-next-line no-debugger';
    check([directive, 'void 0;', ''].join(eol), 'void 0;' + eol, suggestions);
    check('let f = () => { return/* eslint-disable' + eol + ' eqeqeq */42; };',
      'let f = () => { return' + eol + '42; };', suggestions);
  }
  check('let/* eslint-disable eqeqeq */π = 1;', 'let π = 1;', suggestions);
  check('// eslint-disable-next-line eqeqeq, no-void, no-debugger -- retain\ndebugger;',
    '// eslint-disable-next-line no-debugger -- retain\ndebugger;', suggestions);
  check('// eslint-disable-next-line no-debugger, eqeqeq, no-void -- retain\ndebugger;',
    '// eslint-disable-next-line no-debugger -- retain\ndebugger;', suggestions);
  check('// eslint-disable-next-line eqeqeq\nvoid 0;', '// eslint-disable-next-line eqeqeq\nvoid 0;',
    ['--report-unused-disable-directives', '--fix']);
  check('debugger /* eslint-disable eqeqeq */ ;', '  ;', [...suggestions, '--fix']);
  check('debugger;', '', ['--fix'], true);

  const consoleRule = ['-D', 'no-console', '-A', 'no-empty-function'];
  const removeLogs = [...consoleRule, '--fix-suggestions'];
  const removeLogValues = [...removeLogs, '--fix-dangerously'];
  check('console.log(1);', 'console.log(1);', [...consoleRule, '--fix'], true);
  check('function log() { console.warn(1); }', 'function log() {  }', removeLogs, true);
  check('if (ready) console.log(1); else go();', 'if (ready) {} else go();', removeLogs, true);
  check('function f(console) { console.log(); } console.warn();',
    'function f(console) { console.log(); } ', removeLogs);
  check('console.log(/* retain this note */ 2);', 'console.log(/* retain this note */ 2);', removeLogs);
  check('// oxlint-disable-next-line no-console\nconsole.log();\nconsole.warn();',
    '// oxlint-disable-next-line no-console\nconsole.log();\n', removeLogs, true);
  check('function f() { console.log(); "use strict"; return this; }',
    'function f() { ; "use strict"; return this; }', removeLogs);
  check('let f = () => console.log();', 'let f = () => {};', removeLogs, true);
  check('let f = () => ((console.log()));', 'let f = () => {};', removeLogs, true);
  check('let f = () => (/* note */ console.log());', 'let f = () => (/* note */ (void 0));', removeLogs);
  check('const value = console?.warn(3);', 'const value = console?.warn(3);', removeLogs);
  check('const value = console?.warn(3);', 'const value = (void 0);', removeLogValues);
  check('consume(console.warn(), console.error);', 'consume((void 0), console.error);', removeLogValues);
  check('console.log = fn; console.warn.call(ctx);',
    'console.log = fn; console.warn.call(ctx);', removeLogValues);

  if (process.platform !== 'win32') {
    fs.writeFileSync(file, 'debugger;');
    fs.chmodSync(file, 0o751);
    const link = path.join(dir, 'linked.js');
    fs.symlinkSync('test.js', link);
    assert.deepEqual(lint(binary, ['--fix'], link), []);
    assert.ok(fs.lstatSync(link).isSymbolicLink());
    assert.equal(fs.readFileSync(file, 'utf8'), '');
    assert.equal(fs.statSync(file).mode & 0o777, 0o751);
    checks++;
    fs.writeFileSync(file, 'debugger;');
    const alias = path.join(dir, 'hard.js');
    fs.linkSync(file, alias);
    const refused = spawnSync(binary, ['lint', '--fix', file], { cwd: dir, encoding: 'utf8' });
    assert.equal(refused.status, 2, refused.stderr);
    assert.match(refused.stderr, /hard links/);
    assert.equal(fs.statSync(file).ino, fs.statSync(alias).ino);
    assert.equal(fs.readFileSync(alias, 'utf8'), 'debugger;');
    checks++;
  }
  assert.ok(fs.readdirSync(dir).every(name => !name.startsWith('.kessel-fix-')));
  console.log(checks + ' lint fix checks passed, ' + comparisons + ' compared with oxlint.');
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
