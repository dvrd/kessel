'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const pin = require('../../OXC_ORACLE.json');
const binary = path.resolve(process.argv[2]);
const oracle = process.argv[3]?.includes(path.sep) ? path.resolve(process.argv[3]) : process.argv[3] || 'oxlint';
const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-hook-reference-'));

// The pinned fixtures are Rust string literals in two vectors. Fail on an
// unfamiliar entry so a change in the test format cannot silently skip cases.
function stringsInVector(source, label, options) {
  const start = 'let ' + label + ' = vec![';
  let index = source.indexOf(start);
  assert.notEqual(index, -1);
  index += start.length;
  const cases = [];
  const token = /(?:\s+|,|[()]|\/\/[^\n]*|r(#{0,16})"|"|None|Some\(serde_json::json!\((\[[\s\S]*?\])\)\)|\];)/y;
  for (;;) {
    token.lastIndex = index;
    const match = token.exec(source);
    assert.ok(match, 'Unexpected Rust fixture syntax at ' + source.slice(index, index + 60));
    index = token.lastIndex;
    if (match[0] === '];') {
      if (options) assert.equal(options.length, cases.length);
      return cases;
    }
    if (match[0] === '(' || match[0] === ')') assert.ok(label === 'fix' || options);
    if (match[0] === 'None' || match[2]) {
      assert.ok(options && options.length + 1 === cases.length, 'Expected an option after each fixture');
      options.push(match[2] ? JSON.parse(match[2]) : null);
      continue;
    }
    if (match[1] !== undefined) {
      const delimiter = '"' + match[1];
      const end = source.indexOf(delimiter, index);
      assert.notEqual(end, -1);
      cases.push(source.slice(index, end));
      index = end + delimiter.length;
    } else if (match[0] === '"') {
      const quoted = /((?:[^"\\]|\\.)*)"/sy;
      quoted.lastIndex = index;
      const value = quoted.exec(source);
      assert.ok(value);
      cases.push(value[1].replace(/\\(.)/gs, (_, code) => {
        assert.ok(['"', '\\', 'n', 'r', 't'].includes(code), 'Unsupported Rust escape ' + code);
        return ({ n: '\n', r: '\r', t: '\t' })[code] ?? code;
      }));
      index = quoted.lastIndex;
    }
  }
}

// A linked worktree shares the main checkout's sibling Oxc clone.
function oxcRepository() {
  if (process.env.KESSEL_OXC_REPO) return path.resolve(process.env.KESSEL_OXC_REPO);
  const common = execFileSync('git', ['-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
    { encoding: 'utf8' }).trim();
  return path.join(path.dirname(common), '../oxc');
}

function lint(engine, args, files) {
  const run = spawnSync(engine, [...args, ...files], { cwd: workspace, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  assert.ok([0, 1].includes(run.status), String(run.error || run.stderr || run.stdout));
  return JSON.parse(engine === binary ? run.stderr : run.stdout);
}

// The first fixture has one redundant property that oxlint reports twice. In
// the second, only a callback-local variable shadows the listed dependency.
const differences = new Map([
  ['4bb726f1d4926bdfc80ae9ae581e1ede3e19a94189b208f0a1d7734a0c7ab108',
    { actual: [[145,162],[156,161]], expected: [[145,162],[145,162],[156,161]] }],
  ['d83728f92839f13dc1345b87855a22ac9a1b300b8e0ce932231b592714af7c34',
    { actual: [[161,169],[162,168]], expected: [[162,168]] }],
]);

function compare(rule, fixtureCount) {
  const hasOptions = rule === 'getter-return' || rule === 'no-fallthrough';
  const react = rule === 'rules-of-hooks' || rule === 'exhaustive-deps';
  const category = react ? 'react' : 'eslint';
  const qualified = react ? 'react/' + rule : rule;
  const filename = rule.replaceAll('-', '_') + '.rs';
  const source = execFileSync('git', ['-C', oxcRepository(), 'show',
    pin.oxc_git_commit + ':crates/oxc_linter/src/rules/' + category + '/' + filename], { encoding: 'utf8' });
  const passOptions = hasOptions ? [] : undefined;
  const failOptions = hasOptions ? [] : undefined;
  const inputs = [...stringsInVector(source, 'pass', passOptions), ...stringsInVector(source, 'fail', failOptions)];
  const options = hasOptions ? [...passOptions, ...failOptions] : [];
  assert.equal(inputs.length, fixtureCount, 'Review coverage when updating the Oxc fixture pin');
  const files = inputs.map((input, i) => {
    let extension = react ? '.tsx' : '.js';
    if (rule === 'no-fallthrough') extension = '.jsx';
    // The switch on authType returns from the top level. Both CLIs accept the
    // original source as CommonJS, where the module wrapper permits return.
    if (rule === 'no-unreachable' && input.trimStart().startsWith('switch (authType)')) extension = '.cjs';
    const file = rule + '-' + i + extension;
    fs.writeFileSync(path.join(workspace, file), input);
    return file;
  });
  fs.writeFileSync(path.join(workspace, '.oxlintrc.json'), JSON.stringify({
    plugins: react ? ['react'] : [], categories: { correctness: 'off' }, rules: { [qualified]: 'warn' },
    overrides: options.flatMap((settings, i) => settings
      ? [{files: [files[i]], rules: {[qualified]: ['warn', ...settings]}}] : []),
  }));
  const spans = new Map(files.map(file => [file, []]));
  for (const d of lint(oracle, ['--format=json'], files).diagnostics) {
    if (!d.code?.endsWith('(' + rule + ')')) continue;
    const primary = rule === 'exhaustive-deps' && /has (a missing dependency|missing dependencies):/.test(d.message)
      ? d.labels.at(-1) : d.labels[0];
    const { offset, length } = primary.span;
    spans.get(path.basename(d.filename)).push([offset, offset + length]);
  }
  const reports = lint(binary, ['lint', '--format=json'], files);
  assert.equal(reports.length, inputs.length);
  const byFile = new Map(reports.map(report => [path.basename(report.filePath), report.messages]));
  const order = (a, b) => a[0] - b[0] || a[1] - b[1];
  let matched = 0;
  for (const [i, file] of files.entries()) {
    const lines = [0];
    for (const [offset, byte] of Buffer.from(inputs[i]).entries()) if (byte === 10) lines.push(offset + 1);
    const messages = byFile.get(file);
    assert.ok(messages.every(d => !d.fatal), file + ': fixture failed to parse');
    const actual = messages.filter(d => d.ruleId === rule).map(d =>
      [lines[d.line - 1] + d.column - 1, lines[d.endLine - 1] + d.endColumn - 1]).sort(order);
    const expected = spans.get(file).sort(order);
    if (JSON.stringify(actual) === JSON.stringify(expected)) { matched++; continue; }
    const digest = createHash('sha256').update(inputs[i]).digest('hex');
    assert.equal(rule, 'exhaustive-deps', file + '\n' + inputs[i]);
    assert.deepEqual({ actual, expected }, differences.get(digest), file + '\n' + inputs[i]);
  }
  console.log(rule + ' matched primary diagnostic spans on ' + matched + '/' + files.length + ' upstream fixtures.');
  if (rule === 'exhaustive-deps') compareFixes(source);
}

// Compare full trees so formatting can differ while expressions, properties,
// callback bodies and the order of existing dependencies must agree.
function compareFixes(source) {
  const fixtures = stringsInVector(source, 'fix');
  assert.equal(fixtures.length, 32);
  const captures = new Set(['const useHook = x => useCallback(() => x)',
    'const useHook = x => useCallback(() => { return x; })']);
  function ast(file) {
    const output = execFileSync(binary, ['parse', file, '--json'], { cwd: workspace, encoding: 'utf8' });
    return JSON.parse(output, (key, value) => key === 'start' || key === 'end' ? undefined : value);
  }
  let matched = 0;
  for (let i = 0; i < fixtures.length; i += 2) {
    const [input, expected] = fixtures.slice(i, i + 2);
    const write = (file, contents) => fs.writeFileSync(path.join(workspace, file), contents);
    write('expected.tsx', expected);
    const reference = ast('expected.tsx');
    for (const engine of [oracle, binary]) {
      write('edit.tsx', input);
      const command = engine === binary ? ['lint'] : [];
      lint(engine, [...command, '--fix', '--fix-suggestions', '--fix-dangerously', '--format=json'], ['edit.tsx']);
      if (engine === binary && captures.has(input)) {
        // The reference's empty list would retain the first render's x.
        write('expected.tsx', expected.replace(', [])', ', [x])'));
        assert.deepEqual(ast('edit.tsx'), ast('expected.tsx'), input);
      } else {
        assert.deepEqual(ast('edit.tsx'), reference, input);
        if (engine === binary) matched++;
      }
    }
  }
  console.log('Hook fixes matched the pinned AST on ' + matched + '/16 fixtures. Two omitted lists also track the captured parameter.');
}

try {
  assert.equal(execFileSync(oracle, ['--version'], { encoding: 'utf8' }).trim(), 'Version: ' + pin.oxlint_npm);
  compare('getter-return', 85);
  compare('no-unreachable', 63);
  compare('no-fallthrough', 86);
  compare('rules-of-hooks', 127);
  compare('exhaustive-deps', 314);
} finally {
  fs.rmSync(workspace, { recursive: true, force: true });
}
