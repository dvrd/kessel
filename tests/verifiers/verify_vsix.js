#!/usr/bin/env node
'use strict';

// Checks the packaged editor extension without starting an editor: the VSIX
// must carry the language server, SDK and native library that are in this
// checkout, declare the lint settings the server reads, and its packaged
// server must pass the stdio protocol suite using only packaged files.
// `task test:vscode` covers the same package inside VS Code itself.

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const manifest = require(path.join(root, 'editors/vscode/package.json'));
const target = process.platform + '-' + process.arch;
const archive = path.join(root, 'bin', 'kessel-' + manifest.version + '-' + target + '.vsix');
const library = 'libkessel.' + { darwin: 'dylib', linux: 'so', win32: 'dll' }[process.platform];

function digest(file) {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

// A VSIX is a zip archive. bsdtar (macOS, Windows) reads zip; elsewhere unzip does.
function extract(destination) {
  const commands = [['unzip', ['-q', archive, '-d', destination]], ['tar', ['-xf', archive, '-C', destination]]];
  for (const [command, args] of commands) {
    const result = spawnSync(command, args, { stdio: 'ignore' });
    if (result.status === 0) return;
  }
  throw new Error('Could not extract ' + archive + ' with unzip or tar');
}

function packagedFiles(directory) {
  return fs.readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile())
    .map(entry => path.relative(directory, path.join(entry.parentPath ?? entry.path, entry.name)));
}

function checkContents(extension) {
  const sdk = path.join(root, 'npm/kessel');
  const sdkManifest = require(path.join(sdk, 'package.json'));
  const expected = new Map([['extension.js', path.join(root, 'editors/vscode/extension.js')]]);
  for (const entry of ['package.json', ...sdkManifest.files]) {
    const source = path.join(sdk, entry);
    const files = fs.statSync(source).isDirectory() ? packagedFiles(source).map(file => path.join(entry, file)) : [entry];
    for (const file of files) expected.set(path.join('npm/kessel', file), path.join(sdk, file));
  }
  expected.set(path.join('bin', library), path.join(root, 'bin', library));
  assert.ok(expected.has(path.join('npm/kessel/lsp/server.js')), 'The SDK package must list the language server');
  for (const [packaged, source] of expected) {
    const file = path.join(extension, packaged);
    assert.ok(fs.existsSync(file), 'VSIX is missing ' + packaged);
    assert.equal(digest(file), digest(source), packaged + ' differs from this checkout; rebuild the VSIX');
  }
  for (const dependency of Object.keys(manifest.dependencies)) {
    assert.ok(fs.existsSync(path.join(extension, 'node_modules', dependency, 'package.json')),
      'VSIX is missing the ' + dependency + ' dependency');
  }
  return expected.size;
}

function checkSettings(extension) {
  const packaged = JSON.parse(fs.readFileSync(path.join(extension, 'package.json'), 'utf8'));
  assert.equal(packaged.main, './extension.js');
  assert.equal(packaged.devDependencies, undefined);
  const settings = packaged.contributes.configuration.properties;
  assert.deepEqual(Object.keys(settings).sort(), ['kessel.categories', 'kessel.plugins',
    'kessel.reportUnusedDisableDirectives', 'kessel.rules']);
  const categories = ['correctness', 'suspicious', 'pedantic', 'perf', 'style', 'restriction', 'nursery'];
  assert.deepEqual(Object.keys(settings['kessel.categories'].properties), categories);
  assert.deepEqual(settings['kessel.plugins'].items.enum, ['typescript', 'unicorn', 'oxc', 'react']);
  assert.equal(settings['kessel.plugins'].default, null);
  // The client must send every declared setting and watch each for changes.
  const client = fs.readFileSync(path.join(extension, 'extension.js'), 'utf8');
  for (const name of Object.keys(settings)) {
    const key = name.slice('kessel.'.length);
    assert.ok(client.includes("'" + name + "'"), 'extension.js does not synchronize ' + name);
    assert.ok(client.includes("config.get('" + key + "')"), 'extension.js does not send ' + key);
  }
  return Object.keys(settings).length;
}

function main() {
  assert.ok(fs.existsSync(archive), 'Run `task build:vscode` to create ' + archive);
  const stage = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-vsix-')));
  try {
    extract(stage);
    const extension = path.join(stage, 'extension');
    const files = checkContents(extension);
    const settings = checkSettings(extension);
    // The packaged server resolves the SDK, Koffi and the native library
    // relative to itself, so nothing here can come from the checkout.
    const server = path.join(extension, 'npm/kessel/lsp');
    const suite = spawnSync(process.execPath, [path.join(__dirname, 'verify_lsp.js'), '--server=' + server],
      { encoding: 'utf8' });
    assert.equal(suite.status, 0, suite.stdout + suite.stderr);
    console.log('VSIX for ' + target + ' carries ' + files + ' current server, SDK and native files and ' +
      settings + ' settings; its packaged server passed the stdio protocol suite.');
  } finally {
    fs.rmSync(stage, { recursive: true, force: true, maxRetries: 5 });
  }
}

main();
