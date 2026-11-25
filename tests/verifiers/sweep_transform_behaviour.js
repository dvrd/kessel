'use strict';

// Behavioural sweep over the pinned real-world corpus; not part of any gate.
//
//     node tests/verifiers/sweep_transform_behaviour.js bin/kessel --target=es2015
//
// Every file that Node can load as a CommonJS module is loaded twice in a
// fresh process: as written, and as lowered with the given flags. The lowered
// code is compiled under the original file name, so its relative requires
// resolve as before and nothing is written into the corpus. The two loads
// must describe the same module: the same export names, types, function
// names and arities, prototype members and primitive values, two levels
// deep, or the same error. Files that are refused, do not load as written, or
// describe themselves differently on every load are counted and skipped. Prints one JSON summary and exits
// non-zero when a lowered file loads differently from its original.

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const [, , binary, ...flags] = process.argv;
const root = path.resolve(__dirname, '../../bench/real_world');

const probe = `
const Module = require('node:module');
const fs = require('node:fs');
const [file, lowered] = process.argv.slice(1);
// The RegExp constructor reports the last match made anywhere, which here is
// a match against printed source text.
const legacy = /^(\\$[&'+_\\d\`]|lastMatch|lastParen|leftContext|rightContext|input)$/;
function describe(value, depth) {
  const type = typeof value;
  if (value === null || (type !== 'object' && type !== 'function')) {
    return type === 'number' || type === 'boolean' || type === 'string' ? type + ':' + String(value).slice(0, 80) : type;
  }
  let text = type === 'function' ? 'function ' + value.name + '/' + value.length : Array.isArray(value) ? 'array' : 'object';
  if (depth === 0) return text;
  const names = Object.getOwnPropertyNames(value).filter(name => !/^(caller|callee|arguments)$/.test(name) && !legacy.test(name)).sort();
  const parts = [];
  for (const name of names.slice(0, 200)) {
    let member;
    try { member = describe(value[name], depth - 1); } catch (error) { member = 'throws ' + error.constructor.name; }
    parts.push(name + '=' + member);
  }
  return text + '{' + parts.join(',') + '}';
}
let outcome;
try {
  const loaded = new Module(file, null);
  loaded.filename = file;
  loaded.paths = Module._nodeModulePaths(require('node:path').dirname(file));
  loaded._compile(fs.readFileSync(lowered || file, 'utf8'), file);
  outcome = describe(loaded.exports, 3);
} catch (error) {
  outcome = 'throws ' + (error && error.constructor ? error.constructor.name : typeof error) + ': ' + String(error && error.message).slice(0, 120);
}
process.stdout.write(outcome);
`;

function load(file, lowered) {
  const args = ['-e', probe, file];
  if (lowered) args.push(lowered);
  const result = spawnSync(process.execPath, args, { encoding: 'utf8', timeout: 30000, maxBuffer: 1 << 28 });
  return result.status === 0 ? result.stdout : 'process failed: ' + (result.signal || result.status) + ' ' + result.stderr.slice(0, 200);
}

const files = [];
(function walk(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(full); else if (full.endsWith('.js')) files.push(full);
  }
})(root);

const temp = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'kessel-behaviour-'));
const summary = { files: files.length, same: 0, changed: 0, refused: 0, unloadable: 0, unstable: 0, different: 0 };
for (const file of files) {
  const original = load(file);
  // A module that describes itself differently on a second load, through a
  // clock or a random identifier, cannot be compared this way.
  if (load(file) !== original) { summary.unstable += 1; continue; }
  // A syntax error as written means the file is an ES module or needs a browser.
  if (/^throws SyntaxError|^process failed/.test(original)) { summary.unloadable += 1; continue; }
  const transformed = spawnSync(binary, ['transform', file, ...flags], { encoding: 'utf8', maxBuffer: 1 << 28 });
  if (transformed.status !== 0) { summary.refused += 1; continue; }
  const output = path.join(temp, 'lowered.js');
  fs.writeFileSync(output, transformed.stdout);
  const lowered = load(file, output);
  if (lowered === original) {
    summary.same += 1;
    if (/__kessel_/.test(transformed.stdout)) summary.changed += 1;
  } else {
    summary.different += 1;
    let at = 0;
    while (at < original.length && original[at] === lowered[at]) at += 1;
    console.log('DIFFERENT', path.relative(root, file), JSON.stringify(original.slice(Math.max(0, at - 60), at + 60)),
      JSON.stringify(lowered.slice(Math.max(0, at - 60), at + 60)));
  }
}
fs.rmSync(temp, { recursive: true, force: true });
console.log(JSON.stringify(summary));
process.exitCode = summary.different ? 1 : 0;
