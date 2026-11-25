#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const installed = process.argv.includes('--installed');
// `--server=<directory>` runs another copy of the server, such as the one
// unpacked from a VSIX, in place of the one in this checkout.
const serverOption = process.argv.find(argument => argument.startsWith('--server='));
const serverDirectory = path.resolve(serverOption ? serverOption.slice('--server='.length)
  : path.join(__dirname, '../../npm/kessel/lsp'));
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-lsp-'));
const uriFor = file => pathToFileURL(path.join(folder, file)).href;
const pos = (line, character) => ({ line, character });
const range = (line, start, end) => ({ start: pos(line, start), end: pos(line, end) });
const request = (id, method, params) => ({ jsonrpc: '2.0', id, method, params });
const notification = (method, params) => request(undefined, method, params);
const source = '/*💡*/\u2028debugger;\r\nlet x: number=1;';
const fixedText = '/*💡*/\u2028;\r\nconst x: number=1;';
const uri = uriFor('pkg/new folder/app.ts');

function frame(message) {
  const body = Buffer.from(typeof message === 'string' ? message : JSON.stringify(message));
  return Buffer.concat([Buffer.from('Content-Length: ' + body.length + '\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n'), body]);
}

async function* responses(stream) {
  let buffer = Buffer.alloc(0);
  for await (const chunk of stream) {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const boundary = buffer.indexOf('\r\n\r\n');
      if (boundary < 0) break;
      const header = buffer.subarray(0, boundary).toString('ascii');
      assert.match(header, /^Content-Length: \d+$/i);
      const length = Number(header.split(':')[1]);
      const end = boundary + 4 + length;
      if (end > buffer.length) break;
      yield JSON.parse(buffer.subarray(boundary + 4, end).toString('utf8'));
      buffer = buffer.subarray(end);
    }
  }
  assert.equal(buffer.length, 0);
}

function launch() {
  const unixBin = path.resolve('node_modules/.bin/kessel-language-server');
  const entry = path.join(serverDirectory, 'server.js');
  const windowsShim = installed && process.platform === 'win32';
  const command = windowsShim ? 'cmd.exe' : installed ? unixBin : process.execPath;
  const args = windowsShim ? ['/d', '/c', 'node_modules\\.bin\\kessel-language-server.cmd', '--stdio'] :
    installed ? ['--stdio'] : [entry, '--stdio'];
  const proc = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  const exit = once(proc, 'exit');
  const messages = responses(proc.stdout);
  let stderr = '';
  proc.stderr.setEncoding('utf8').on('data', text => { stderr += text; });
  const timeout = setTimeout(() => { proc.kill(); }, 20000);
  return {
    proc, exit, stop() { clearTimeout(timeout); if (proc.exitCode === null) proc.kill(); },
    send(...messages) { proc.stdin.write(Buffer.concat(messages.map(frame))); },
    async next(id, method) {
      const item = await messages.next();
      assert.equal(item.done, false, 'Language server exited. ' + stderr);
      assert.equal(item.value.jsonrpc, '2.0');
      assert.equal(item.value.id, id);
      assert.equal(item.value.method, method);
      return item.value;
    },
  };
}

function open(uri, text, languageId = 'typescript') {
  return notification('textDocument/didOpen', { textDocument: { uri, text, languageId, version: 1 } });
}
function change(uri, version, ...contentChanges) {
  return notification('textDocument/didChange', { textDocument: { uri, version }, contentChanges });
}
function actions(id, uri, kind, selection = range(0, 0, 0), diagnostics = []) {
  return request(id, 'textDocument/codeAction', {
    textDocument: { uri }, range: selection, context: { diagnostics, only: kind && [kind] },
  });
}

async function diagnostics(client, uri, version) {
  const { params } = await client.next(undefined, 'textDocument/publishDiagnostics');
  assert.equal(params.uri, uri);
  assert.equal(params.version, version);
  return params.diagnostics;
}

async function initialize(client, versioned) {
  client.send('broken json', request(1, 'textDocument/codeAction', {}));
  assert.equal((await client.next(null)).error.code, -32700);
  assert.equal((await client.next(1)).error.code, -32002);
  const message = frame(request(2, 'initialize', {
    workspaceFolders: [{ uri: uriFor('.'), name: 'Project 💡' }],
    capabilities: {
      workspace: { workspaceEdit: { documentChanges: versioned }, didChangeWatchedFiles: { dynamicRegistration: versioned } },
      textDocument: { publishDiagnostics: { relatedInformation: versioned }, codeAction: { codeActionLiteralSupport: { codeActionKind: { valueSet: ['source.fixAll'] } } } },
    },
  }));
  for (let i = 0; i < message.length; i += 7) client.proc.stdin.write(message.subarray(i, i + 7));
  const { capabilities } = (await client.next(2)).result;
  assert.equal(capabilities.positionEncoding, 'utf-16');
  assert.equal(capabilities.documentFormattingProvider, true);
  assert.equal(capabilities.documentRangeFormattingProvider, true);
  assert.equal(capabilities.textDocumentSync.change, 2);
  assert.deepEqual(capabilities.codeActionProvider.codeActionKinds, ['quickfix', 'source.fixAll.kessel']);
  client.send(notification('initialized', {}));
  if (versioned) {
    const registration = await client.next('kessel-config-watch', 'client/registerCapability');
    assert.equal(registration.params.registrations[0].method, 'workspace/didChangeWatchedFiles');
    client.send({ jsonrpc: '2.0', id: registration.id, result: null });
  }
  client.send(request(3, 'example/unsupported', {}));
  assert.equal((await client.next(3)).error.code, -32601);
}

async function edits(client, versioned) {
  client.send(open(uri, source));
  const original = await diagnostics(client, uri, 1);
  assert.deepEqual(original.map(d => [d.code, d.severity, d.range]), [
    ['L2001', 1, range(0, 7, 16)], ['L4012', 2, range(1, 4, 5)],
  ]);
  client.send(actions(4, uri, 'quickfix'), actions(5, uri, 'source.fixAll'));
  assert.deepEqual((await client.next(4)).result, []);
  const [action] = (await client.next(5)).result;
  assert.equal(action.kind, 'source.fixAll.kessel');
  let list;
  if (versioned) {
    const [edit] = action.edit.documentChanges;
    assert.deepEqual(edit.textDocument, { uri, version: 1 });
    list = edit.edits;
  } else list = action.edit.changes[uri];
  assert.deepEqual(list, [{ range: { start: pos(0, 0), end: pos(1, 16) }, newText: fixedText }]);
  client.send(change(uri, 2, { range: list[0].range, text: list[0].newText }));
  assert.deepEqual(await diagnostics(client, uri, 2), []);
  assert.equal(fs.existsSync(path.join(folder, 'pkg/new folder/app.ts')), false);
  client.send(change(uri, 1, { text: source }), actions(6, uri, 'source'));
  assert.deepEqual((await client.next(6)).result, []);
  client.send(change(uri, 3, { text: 'debugger;' }, { range: range(0, 4, 2), text: '' }), actions(7, uri, 'source'));
  assert.equal((await client.next(undefined, 'window/logMessage')).params.type, 1);
  assert.deepEqual((await client.next(7)).result, []);
  client.send(change(uri, 3, { range: range(0, 2, 4), rangeLength: 2, text: 'é' },
    { range: range(0, 6, 7), text: 'debugger;' }));
  assert.deepEqual((await diagnostics(client, uri, 3)).map(d => d.range), [range(0, 6, 15)]);
  client.send(change(uri, 4, { text: 'const = ;' }));
  assert.ok((await diagnostics(client, uri, 4)).some(d => d.severity === 1 && d.source === 'kessel'));
  client.send(notification('textDocument/didClose', { textDocument: { uri } }));
  assert.deepEqual(await diagnostics(client, uri, undefined), []);
}

async function workspaceFolders(client) {
  const ignored = uriFor('ignored/test.js');
  const root = { uri: uriFor('.'), name: 'Project' };
  const nested = { uri: uriFor('pkg'), name: 'Nested' };
  client.send(open(ignored, 'debugger;', 'javascript'));
  assert.deepEqual(await diagnostics(client, ignored, 1), []);
  client.send(notification('workspace/didChangeWorkspaceFolders', { event: { removed: [root], added: [nested] } }));
  assert.deepEqual((await diagnostics(client, ignored, 1)).map(d => d.code), ['L2001']);
  client.send(notification('workspace/didChangeWorkspaceFolders', { event: { removed: [nested], added: [root] } }));
  assert.deepEqual(await diagnostics(client, ignored, 1), []);
  client.send(notification('textDocument/didClose', { textDocument: { uri: ignored } }));
  assert.deepEqual(await diagnostics(client, ignored, undefined), []);
}

async function quickFixes(client, versioned) {
  const buffer = uriFor('pkg/new folder/selected.ts');
  const text = '/*🚀*/ let [a, b] = [1, 2];\r\ndebugger; debugger;';
  client.send(open(buffer, text));
  const initial = await diagnostics(client, buffer, 1);
  assert.equal(initial.length, 4);
  client.send(actions(20, buffer, 'quickfix', range(0, 11, 17)),
    actions(21, buffer, undefined, range(1, 11, 11)),
    actions(22, buffer, 'quickfix', range(0, 0, 0), initial));
  const [declaration] = (await client.next(20)).result;
  assert.equal(declaration.kind, 'quickfix');
  assert.equal(declaration.isPreferred, true);
  assert.equal(declaration.diagnostics.length, 2);
  const edits = action => versioned ? action.edit.documentChanges[0].edits : action.edit.changes[buffer];
  assert.deepEqual(edits(declaration), [{ range: range(0, 7, 10), newText: 'const' }]);
  const selected = (await client.next(21)).result;
  assert.deepEqual(selected.map(a => a.title), [
    'Remove `debugger;`', 'Disable no-debugger for this line', 'Disable no-debugger for this file',
  ]);
  assert.deepEqual(selected.map(a => a.isPreferred), [true, false, false]);
  assert.equal(selected[0].diagnostics[0].code, 'L2001');
  const [edit] = edits(selected[0]);
  assert.deepEqual(edit, { range: range(1, 10, 19), newText: '' });
  assert.deepEqual((await client.next(22)).result, []);
  if (versioned) assert.deepEqual(selected[0].edit.documentChanges[0].textDocument, { uri: buffer, version: 1 });
  client.send(change(buffer, 2, { range: edit.range, text: edit.newText }));
  assert.deepEqual((await diagnostics(client, buffer, 2)).map(d => d.code).sort(), ['L2001', 'L4012', 'L4012']);
  client.send(actions(23, buffer, 'quickfix', range(1, 11, 11), selected[0].diagnostics));
  assert.deepEqual((await client.next(23)).result, []);
  client.send(change(buffer, 3, { text: 'debugger; const invalid = ;' }));
  assert.ok((await diagnostics(client, buffer, 3)).length > 0);
  client.send(actions(24, buffer, 'quickfix', range(0, 0, 9)));
  assert.deepEqual((await client.next(24)).result, []);
  const suppressed = [
    '/* eslint-disable prefer-const */', 'let first = 1;', '/* oxlint-enable */',
    'let second = 2;', '/* oxlint-enable prefer-const */', 'let third = 3;',
  ].join('\n');
  client.send(change(buffer, 4, { text: suppressed }));
  assert.deepEqual((await diagnostics(client, buffer, 4)).map(d => d.range), [range(5, 4, 9)]);
  client.send(actions(25, buffer, 'quickfix', range(3, 4, 10)), actions(26, buffer, 'source.fixAll'));
  assert.deepEqual((await client.next(25)).result, []);
  const [fixAll] = (await client.next(26)).result;
  const allEdits = versioned ? fixAll.edit.documentChanges[0].edits : fixAll.edit.changes[buffer];
  assert.equal(allEdits[0].newText, suppressed.replace('let third', 'const third'));
  client.send(notification('textDocument/didClose', { textDocument: { uri: buffer } }));
  assert.deepEqual(await diagnostics(client, buffer, undefined), []);
}

async function suppressions(client, versioned) {
  const uri = uriFor('suppress/component.tsx');
  const source = [
    '#!/usr/bin/env node', '// oxlint-disable-next-line no-debugger', 'debugger;',
    'const v = <C', '  title={a == b}', '>', '  {/*🚀*/ x == y}<b/>', '</C>;',
    'debugger;', '',
  ].join('\r\n');
  client.send(open(uri, source, 'typescriptreact'));
  const original = await diagnostics(client, uri, 1);
  assert.deepEqual(original.map(d => [d.code, d.range.start.line]), [['L1003', 4], ['L1003', 6], ['L2001', 8]]);
  const edits = action => versioned ? action.edit.documentChanges[0].edits : action.edit.changes[uri];
  client.send(actions(40, uri, 'quickfix', original[1].range));
  const variants = (await client.next(40)).result;
  const [lineEdit] = edits(variants.find(a => a.title === 'Disable eqeqeq for this line'));
  assert.deepEqual(lineEdit, { range: range(6, 16, 16), newText: ' /* oxlint-disable-line eqeqeq */' });
  client.send(change(uri, 2, { range: lineEdit.range, text: lineEdit.newText }));
  const remaining = await diagnostics(client, uri, 2);
  assert.deepEqual(remaining.map(d => d.code), ['L1003', 'L2001']);
  client.send(actions(41, uri, 'quickfix', remaining[0].range));
  const [fileEdit] = edits((await client.next(41)).result.find(a => a.title === 'Disable eqeqeq for this file'));
  assert.deepEqual(fileEdit, { range: range(1, 0, 0), newText: '/* oxlint-disable eqeqeq */\r\n' });
  client.send(change(uri, 3, { range: fileEdit.range, text: fileEdit.newText }));
  assert.deepEqual((await diagnostics(client, uri, 3)).map(d => d.code), ['L2001']);
  client.send(change(uri, 4, { text: '\uFEFFdebugger;\u2028debugger;' }));
  const separated = await diagnostics(client, uri, 4);
  client.send(actions(42, uri, 'quickfix', separated[0].range));
  const choices = (await client.next(42)).result;
  const [bom] = edits(choices.find(a => a.title.endsWith('this file')));
  assert.deepEqual(bom, { range: range(0, 1, 1), newText: '/* oxlint-disable no-debugger */\u2028' });
  const [first] = edits(choices.find(a => a.title.endsWith('this line')));
  client.send(change(uri, 5, { range: first.range, text: first.newText }));
  assert.equal((await diagnostics(client, uri, 5)).length, 1);
  const logging = '/*💡*/ console.warn(); console.log(); ((console) => console.log())(local);';
  client.send(change(uri, 6, { text: logging }));
  const loggingDiagnostics = await diagnostics(client, uri, 6);
  assert.equal(loggingDiagnostics.length, 1);
  const [consoleDiagnostic] = loggingDiagnostics;
  const start = logging.indexOf('console.log');
  assert.equal(consoleDiagnostic.code, 'L4037');
  assert.deepEqual(consoleDiagnostic.range, range(0, start, start + 'console.log'.length));
  client.send(actions(43, uri, 'source.fixAll'));
  assert.deepEqual((await client.next(43)).result, []);
  client.send(actions(44, uri, 'quickfix', consoleDiagnostic.range));
  const [ignore] = edits((await client.next(44)).result.find(action => action.title === 'Disable no-console for this line'));
  client.send(change(uri, 7, { range: ignore.range, text: ignore.newText }));
  assert.deepEqual(await diagnostics(client, uri, 7), []);
  client.send(notification('textDocument/didClose', { textDocument: { uri } }));
  assert.deepEqual(await diagnostics(client, uri, undefined), []);
}

async function globalSettings(client) {
  const configName = 'globals/.oxlintrc.json';
  const buffer = uriFor('globals/unsaved.js');
  const configure = (env, access) => fs.writeFileSync(path.join(folder, configName), JSON.stringify({
    rules: { 'no-undef': 'warn', 'no-global-assign': 'error' }, env, globals: { injected: access },
  }));
  configure({ node: true }, 'readonly');
  client.send(open(buffer, '/*💡*/ injected = 1;\nvoid document;', 'javascript'));
  const published = await diagnostics(client, buffer, 1);
  assert.deepEqual(published.map(d => [d.code, d.severity, d.range]).sort(), [
    ['L2006', 2, range(1, 5, 13)], ['L2047', 1, range(0, 7, 15)],
  ]);
  configure({ browser: true }, 'writable');
  client.send(notification('workspace/didChangeWatchedFiles', { changes: [{ uri: uriFor(configName), type: 2 }] }));
  assert.deepEqual(await diagnostics(client, buffer, 1), []);
  assert.equal(fs.existsSync(path.join(folder, 'globals/unsaved.js')), false);
  client.send(notification('textDocument/didClose', { textDocument: { uri: buffer } }));
  assert.deepEqual(await diagnostics(client, buffer, undefined), []);
}

async function reactHooks(client, relatedInformation) {
  const uri = uriFor('react/view.tsx');
  const call = 'useEffect(()=>refresh(p.user.id), [])';
  const source = 'function View(p){ /*🪴*/ if(p.ready) ' + call + '; }';
  client.send(open(uri, source, 'typescriptreact'));
  const start = source.indexOf('useEffect');
  const reported = await diagnostics(client, uri, 1);
  const property = source.indexOf('p.user');
  const list = source.indexOf('[]');
  assert.deepEqual(reported.map(d => [d.code, d.severity, d.range]), [
    ['L4107', 2, range(0, start, start + call.length)],
    ['L4108', 2, range(0, list, list + 2)],
  ]);
  assert.match(reported[1].message, /p\.user\.id/);
  assert.deepEqual(reported[1].relatedInformation, relatedInformation ? [{
    location: { uri, range: range(0, property, property + 'p.user'.length) },
    message: 'useEffect uses `p.user.id` here',
  }] : undefined);
  client.send(actions(50, uri, 'quickfix', reported[1].range), actions(51, uri, 'source.fixAll'));
  const offered = (await client.next(50)).result;
  const suggestion = offered.find(action => action.title === 'Add missing Hook dependencies');
  assert.ok(suggestion);
  assert.equal(suggestion.isPreferred, false);
  assert.deepEqual(suggestion.diagnostics, [reported[1]]);
  const edits = relatedInformation ? suggestion.edit.documentChanges[0].edits : suggestion.edit.changes[uri];
  if (relatedInformation) assert.equal(suggestion.edit.documentChanges[0].textDocument.version, 1);
  assert.deepEqual(edits, [{ range: range(0, list + 1, list + 2), newText: 'p.user.id]' }]);
  assert.deepEqual((await client.next(51)).result, []);
  const covered = source.replace('[]', '[p.user.id]');
  client.send(change(uri, 2, { range: edits[0].range, text: edits[0].newText }));
  assert.deepEqual((await diagnostics(client, uri, 2)).map(d => d.code), ['L4107']);
  client.send(change(uri, 3, { text: covered.replace('if(p.ready) ', '') }));
  assert.deepEqual(await diagnostics(client, uri, 3), []);
  client.send(notification('textDocument/didClose', { textDocument: { uri } }));
  assert.deepEqual(await diagnostics(client, uri, undefined), []);
}

async function controlFlow(client) {
  const uri = uriFor('flow/unsaved.js');
  const getter = '(){ if (ready) return 1; }';
  const first = '/*🌱*/ const model = { get value' + getter + ' };';
  const second = 'function run(){ try { return work(); } finally { cleanup(); } after(); }';
  client.send(open(uri, first + '\r\n' + second, 'javascript'));
  const reported = (await diagnostics(client, uri, 1)).filter(d => ['L2044', 'L2046'].includes(d.code));
  const start = first.indexOf(getter);
  assert.deepEqual(reported.map(d => [d.code, d.range]), [
    ['L2046', range(0, start, start + getter.length)],
    ['L2044', range(1, second.indexOf('after();'), second.indexOf('after();') + 8)],
  ]);
  const repaired = 'const model = { get value(){ if (ready) return; return 2; } };\r\n' +
    'function run(){ try { if (ready) return work(); } finally { cleanup(); } after(); }';
  client.send(change(uri, 2, { text: repaired }));
  assert.deepEqual(await diagnostics(client, uri, 2), []);
  const loop = 'const value = { get x() { while (ready)';
  client.send(change(uri, 3, { text: loop }));
  assert.ok((await diagnostics(client, uri, 3)).some(d => /^K\d+$/.test(d.code)));
  client.send(change(uri, 4, { text: loop + ' { return 1; } return 0; } };' }));
  assert.deepEqual(await diagnostics(client, uri, 4), []);
  const before = '/*🌱*/ switch (x) {case 1: work();';
  const annotation = ' /* carry on */ ';
  const after = 'case 2: break;}';
  client.send(change(uri, 5, { text: before + after }));
  const missing = (await diagnostics(client, uri, 5)).filter(d => d.code === 'L2045');
  assert.deepEqual(missing.map(d => d.range), [range(0, before.length, before.length + after.length - 1)]);
  client.send(change(uri, 6, { range: range(0, before.length, before.length), text: annotation }));
  assert.deepEqual(await diagnostics(client, uri, 6), []);
  const exiting = before.replace('work();', 'break;');
  client.send(change(uri, 7, { text: exiting + annotation + after }));
  const unused = (await diagnostics(client, uri, 7)).filter(d => d.code === 'L2045');
  assert.deepEqual(unused.map(d => d.range), [range(0, exiting.length, exiting.length + annotation.length)]);
  client.send(notification('textDocument/didClose', { textDocument: { uri } }));
  assert.deepEqual(await diagnostics(client, uri, undefined), []);
}

async function projects(client) {
  const ignored = uriFor('ignored/test.js');
  const outside = uriFor('new/app.js');
  const virtual = 'untitled:Component';
  client.send(open(ignored, 'debugger;', 'javascript'), open(outside, 'debugger;', 'javascript'),
    open(virtual, 'const c: number=1; const e=<main/>;', 'typescriptreact'));
  assert.deepEqual(await diagnostics(client, ignored, 1), []);
  assert.deepEqual(await diagnostics(client, outside, 1), []);
  assert.deepEqual(await diagnostics(client, virtual, 1), []);
  fs.writeFileSync(path.join(folder, 'kessel.lint.json'), '{ broken config');
  client.send(notification('textDocument/didSave', { textDocument: { uri: outside } }));
  assert.match((await client.next(undefined, 'window/logMessage')).params.message, /config/i);
  assert.deepEqual(await diagnostics(client, outside, 1), []);
  fs.writeFileSync(path.join(folder, 'kessel.lint.json'), JSON.stringify({
    ignorePatterns: ['ignored/*'], rules: { 'no-debugger': 'warn' },
  }));
  client.send(notification('workspace/didChangeWatchedFiles', { changes: [{ uri: uriFor('kessel.lint.json'), type: 2 }] }));
  assert.deepEqual(await diagnostics(client, ignored, 1), []);
  assert.deepEqual((await diagnostics(client, outside, 1)).map(d => d.severity), [2]);
  assert.deepEqual(await diagnostics(client, virtual, 1), []);
  client.send(notification('workspace/didChangeConfiguration', { settings: { kessel: { rules: { 'no-debugger': 'off' } } } }));
  for (const file of [ignored, outside, virtual]) assert.deepEqual(await diagnostics(client, file, 1), []);
}

async function formatting(client) {
  const file = uriFor('format.tsx');
  const untouched = 'const el=<div title="🚀"/>;';
  const source = untouched + '\r\n' + "import{type A,B}from'./model'" + '\r\n' + untouched.replace('el=', 'other=') + '\r\n';
  const options = { tabSize: 4, insertSpaces: true };
  const requestFormat = (uri, settings = options) => request(70, 'textDocument/formatting', {
    textDocument: { uri }, options: settings,
  });
  client.send(open(file, source, 'typescriptreact'), requestFormat(file));
  await diagnostics(client, file, 1);
  const [edit] = (await client.next(70)).result;
  assert.deepEqual(edit, { range: { start: pos(1, 0), end: pos(2, 0) },
    newText: 'import { type A, B } from "./model";\r\n' });
  client.send(change(file, 2, { range: edit.range, text: edit.newText }), requestFormat(file));
  await diagnostics(client, file, 2);
  assert.deepEqual((await client.next(70)).result, []);
  assert.equal(fs.existsSync(path.join(folder, 'format.tsx')), false);

  const config = "export default {ports:[80,443],name:'dev'};";
  client.send(change(file, 3, {text: config}), requestFormat(file));
  await diagnostics(client, file, 3);
  const [dataEdit] = (await client.next(70)).result;
  assert.deepEqual(dataEdit.range, range(0, 0, config.length));
  assert.equal(dataEdit.newText, 'export default { ports: [80, 443], name: "dev" };\n');
  client.send(change(file, 4, {range: dataEdit.range, text: dataEdit.newText}), requestFormat(file));
  await diagnostics(client, file, 4);
  assert.deepEqual((await client.next(70)).result, []);

  const scratch = 'untitled:module';
  const name = 'identifier'.repeat(4);
  const names = [name + 'A', name + 'B'];
  const declaration = 'import type{' + names.join(',') + '}from"pkg";';
  client.send(open(scratch, declaration, 'typescript'), requestFormat(scratch, { tabSize: 4, insertSpaces: false }));
  await diagnostics(client, scratch, 1);
  const [wrapped] = (await client.next(70)).result;
  assert.deepEqual(wrapped.range, range(0, 0, declaration.length));
  assert.equal(wrapped.newText, 'import type {\n\t' + names.join(',\n\t') + ',\n} from "pkg";\n');
  // A `css` template keeps its text: Prettier would format its contents as
  // CSS, which the formatter does not do, so the statement is left alone.
  const tagged = 'const text = css`first\nsecond\r\nlast`;\r\n';
  client.send(change(scratch, 2, {text: tagged + declaration}), requestFormat(scratch, {tabSize:4, insertSpaces:false}));
  await diagnostics(client, scratch, 2);
  const [mixed] = (await client.next(70)).result;
  assert.deepEqual(mixed.range, range(3, 0, declaration.length));
  assert.equal(mixed.newText, wrapped.newText.replaceAll('\n', '\r\n'));
  client.send(change(scratch, 3, {text: 'import {'}), requestFormat(scratch));
  assert.ok((await diagnostics(client, scratch, 3)).length > 0);
  assert.deepEqual((await client.next(70)).result, []);
  client.send(requestFormat(uriFor('never-opened.ts')));
  assert.deepEqual((await client.next(70)).result, []);
}

// The formatter rewrites statements anywhere in a file. Each run of changed
// lines must arrive as its own edit bounded by whole lines, so untouched
// lines keep their text and selections, and a range request must return only
// the runs that touch the selected lines.
async function generalFormatting(client) {
  const file = uriFor('general.js');
  const text = ['/*🚀*/ const kept = 1;', 'function  add( a,b ){return a+b}', 'const alsoKept = "é";',
    'class A{m(){ if(a){b()}else{c()} }}', 'export const done = true;', ''].join('\r\n');
  const options = { tabSize: 4, insertSpaces: true };
  const target = { textDocument: { uri: file }, options };
  const whole = id => request(id, 'textDocument/formatting', target);
  const partial = (id, selection) => request(id, 'textDocument/rangeFormatting', { ...target, range: selection });
  const lines = (first, limit) => ({ start: pos(first, 0), end: pos(limit, 0) });
  const functionEdit = { range: lines(1, 2), newText: 'function add(a, b) {\r\n    return a + b;\r\n}\r\n' };
  const classEdit = { range: lines(3, 4), newText: ['class A {', '    m() {', '        if (a) {',
    '            b();', '        } else {', '            c();', '        }', '    }', '}', ''].join('\r\n') };

  client.send(open(file, text, 'javascript'), whole(80), partial(81, range(3, 5, 9)), partial(82, lines(0, 1)),
    partial(83, lines(1, 2)), partial(84, lines(0, 9)), partial(85, range(2, 4, 4)),
    partial(86, { start: pos(3, 0), end: pos(1, 0) }));
  await diagnostics(client, file, 1);
  assert.deepEqual((await client.next(80)).result, [functionEdit, classEdit]);
  assert.deepEqual((await client.next(81)).result, [classEdit]);
  assert.deepEqual((await client.next(82)).result, []);
  assert.deepEqual((await client.next(83)).result, [functionEdit]);
  assert.deepEqual((await client.next(84)).result, [functionEdit, classEdit]);
  assert.deepEqual((await client.next(85)).result, []);
  assert.equal((await client.next(86)).error.code, -32602);

  // Applying one edit leaves the other one valid and still reported.
  client.send(change(file, 2, { range: classEdit.range, text: classEdit.newText }), whole(87));
  await diagnostics(client, file, 2);
  assert.deepEqual((await client.next(87)).result, [functionEdit]);
  client.send(change(file, 3, { range: functionEdit.range, text: functionEdit.newText }), whole(88),
    partial(89, lines(0, 20)));
  await diagnostics(client, file, 3);
  assert.deepEqual((await client.next(88)).result, []);
  assert.deepEqual((await client.next(89)).result, []);

  // A last line without a terminator ends at its final UTF-16 unit.
  const single = '/*🚀*/ const  spaced=1';
  client.send(change(file, 4, { text: single }), whole(90), partial(91, range(0, 0, 0)));
  await diagnostics(client, file, 4);
  const last = { range: range(0, 0, single.length), newText: '/*🚀*/ const spaced = 1;\n' };
  assert.deepEqual((await client.next(90)).result, [last]);
  assert.deepEqual((await client.next(91)).result, [last]);

  // Text that does not parse is never edited, whole or in part.
  client.send(change(file, 5, { text: 'function  add( a,b ){return a+b}\nlet = ;\n' }), whole(92),
    partial(93, range(0, 0, 3)), partial(94, range(0, 0, 3)));
  assert.ok((await diagnostics(client, file, 5)).length > 0);
  assert.deepEqual((await client.next(92)).result, []);
  assert.deepEqual((await client.next(93)).result, []);
  client.send(notification('textDocument/didClose', { textDocument: { uri: file } }));
  assert.deepEqual((await client.next(94)).result, []);
  assert.deepEqual(await diagnostics(client, file, undefined), []);
  client.send(partial(95, range(0, 0, 3)));
  assert.deepEqual((await client.next(95)).result, []);
}

// A range edit is only safe when the lines it leaves alone still mean the
// same. The server checks that by formatting the mixture; a formatter whose
// result depends on the neighbouring lines must make it return nothing.
function rangeFormattingGuard() {
  const { DocumentText } = require(path.join(serverDirectory, 'document.js'));
  const { formatRange } = require(path.join(serverDirectory, 'format.js'));
  const doc = { lang: 'js', content: new DocumentText('a\nkeep\nb\n') };
  const options = { tabSize: 2, insertSpaces: true };
  const upper = (label, text) => text.replace(/^[ab]$/gm, letter => letter.toUpperCase());
  const selection = range(0, 0, 1);
  assert.deepEqual(formatRange(doc, 'file.js', selection, options, upper),
    [{ range: { start: pos(0, 0), end: pos(1, 0) }, newText: 'A\n' }]);
  // This one only rewrites `b` while the first line is still `a`.
  const dependent = (label, text) => text.startsWith('a\n') ? upper(label, text) : text.replace(/^a$/m, 'A');
  assert.deepEqual(formatRange(doc, 'file.js', selection, options, dependent), []);
  assert.deepEqual(formatRange(doc, 'file.js', { start: pos(0, 0), end: pos(3, 0) }, options, dependent).length, 2);
}

// Limits the parser enforces instead of overflowing: each is one diagnostic
// with a UTF-16 range, and such a buffer is neither formatted nor fixed.
async function parserLimits(client) {
  const buffer = uriFor('limits.js');
  const prefix = '/*🚀*/ x = ';
  const depth = 600;
  client.send(open(buffer, prefix + '['.repeat(depth) + ']'.repeat(depth), 'javascript'),
    request(96, 'textDocument/formatting', { textDocument: { uri: buffer }, options: { tabSize: 2, insertSpaces: true } }),
    actions(97, buffer, 'source.fixAll.kessel'));
  // The default limit is 512 levels. The assignment and the expression each
  // take one, so the 511th bracket is the first one refused.
  const refused = prefix.length + 510;
  const nesting = await diagnostics(client, buffer, 1);
  assert.deepEqual(nesting.map(d => [d.code, d.severity, d.range]), [['K2081', 1, range(0, refused, refused + 1)]]);
  assert.match(nesting[0].message, /nesting depth/i);
  assert.deepEqual((await client.next(96)).result, []);
  assert.deepEqual((await client.next(97)).result, []);

  const levels = 300;
  client.send(change(buffer, 2, { text: prefix + '`${'.repeat(levels) + '0' + '}`'.repeat(levels) }));
  const templates = await diagnostics(client, buffer, 2);
  const opening = prefix.length + 3 * 256 + 1;
  assert.deepEqual(templates.map(d => [d.code, d.severity, d.range]), [['K1016', 1, range(0, opening, opening + 2)]]);

  // LSP text is a JSON string, so it cannot carry ill-formed UTF-8 (K1017).
  // A lone surrogate is the closest case: it is checked as U+FFFD and the
  // columns after it still count UTF-16 units.
  client.send(change(buffer, 3, { text: '/*\ud83d*/ x += ;' }));
  assert.deepEqual((await diagnostics(client, buffer, 3)).map(d => [d.code, d.range]), [['K2020', range(0, 11, 12)]]);
  client.send(change(buffer, 4, { text: prefix + '[[1]];' }));
  assert.deepEqual(await diagnostics(client, buffer, 4), []);
  client.send(notification('textDocument/didClose', { textDocument: { uri: buffer } }));
  assert.deepEqual(await diagnostics(client, buffer, undefined), []);
}

// Rules from plugins: an .oxlintrc.json selects them by category and plugin
// for a buffer that was never saved, diagnostics name them with their plugin,
// the disable actions write that name, and the editor's own `categories` and
// `plugins` settings replace the project's selection.
async function pluginRules(client, versioned) {
  const buffer = uriFor('plugins/unsaved.ts');
  const lines = ['const é = { then() { return 1; } };', 'namespace N { export const y = 1; }',
    'const self = this;', 'x = x;', 'let count = 0; use(count);'];
  const text = lines.join('\n');
  const summary = found => found.map(d => [d.code, d.data.rule, d.severity, d.range]);
  // `shift` is 1 once the file directive occupies the first line.
  const thenable = ['L6006', 'unicorn/no-thenable', 1, range(0, 12, 16)];
  const namespace = ['L3004', 'typescript/no-namespace', 2, range(1, 0, lines[1].length)];
  const thisAlias = (severity, shift) => ['L3016', 'typescript/no-this-alias', severity, range(2 + shift, 6, 10)];
  const selfAssign = (severity, shift) => ['L2012', 'no-self-assign', severity, range(3 + shift, 4, 5)];
  const preferConst = shift => ['L4012', 'prefer-const', 2, range(4 + shift, 4, 9)];
  client.send(open(buffer, text));
  const original = await diagnostics(client, buffer, 1);
  // `typescript/no-this-alias` is a correctness rule too, but the project
  // lists only the unicorn plugin.
  assert.deepEqual(summary(original), [thenable, namespace, selfAssign(1, 0), preferConst(0)]);
  assert.equal(fs.existsSync(path.join(folder, 'plugins/unsaved.ts')), false);

  const edits = action => versioned ? action.edit.documentChanges[0].edits : action.edit.changes[buffer];
  client.send(actions(98, buffer, 'quickfix', original[0].range));
  const offered = (await client.next(98)).result;
  assert.deepEqual(offered.map(action => action.title),
    ['Disable unicorn/no-thenable for this line', 'Disable unicorn/no-thenable for this file']);
  const [lineEdit] = edits(offered[0]);
  const lineDirective = ' /* oxlint-disable-line unicorn/no-thenable */';
  assert.deepEqual(lineEdit, { range: range(0, lines[0].length, lines[0].length), newText: lineDirective });
  client.send(change(buffer, 2, { range: lineEdit.range, text: lineEdit.newText }));
  const afterLine = await diagnostics(client, buffer, 2);
  assert.deepEqual(summary(afterLine), [namespace, selfAssign(1, 0), preferConst(0)]);
  client.send(actions(99, buffer, 'quickfix', afterLine[0].range));
  const fileAction = (await client.next(99)).result.find(action => action.title.endsWith('this file'));
  assert.equal(fileAction.title, 'Disable typescript/no-namespace for this file');
  const [fileEdit] = edits(fileAction);
  const fileDirective = '/* oxlint-disable typescript/no-namespace */\n';
  assert.deepEqual(fileEdit, { range: range(0, 0, 0), newText: fileDirective });
  client.send(change(buffer, 3, { range: fileEdit.range, text: fileEdit.newText }));
  assert.deepEqual(summary(await diagnostics(client, buffer, 3)), [selfAssign(1, 1), preferConst(1)]);

  // Fix-all applies the one safe fix and keeps the directives and every
  // diagnostic that has no fix.
  client.send(actions(100, buffer, 'source.fixAll.kessel'));
  const [fixAll] = (await client.next(100)).result;
  assert.equal(fixAll.kind, 'source.fixAll.kessel');
  const [rewrite] = edits(fixAll);
  assert.equal(rewrite.newText, fileDirective + [lines[0] + lineDirective, ...lines.slice(1, 4),
    lines[4].replace('let', 'const')].join('\n'));
  client.send(change(buffer, 4, { text: rewrite.newText }), actions(101, buffer, 'source.fixAll.kessel'));
  assert.deepEqual(summary(await diagnostics(client, buffer, 4)), [selfAssign(1, 1)]);
  assert.deepEqual((await client.next(101)).result, []);

  // A file outside every project takes the editor's selection as its config.
  const scratch = 'untitled:plugins';
  client.send(open(scratch, 'x = { then() { return 1; } }; x = x;', 'javascript'));
  assert.deepEqual((await diagnostics(client, scratch, 1)).map(d => d.code), ['L2012']);

  // A configuration change republishes every open document, oldest first;
  // the two opened here are the newest.
  async function republished(uri, version) {
    for (;;) {
      const { params } = await client.next(undefined, 'textDocument/publishDiagnostics');
      if (params.uri !== uri) continue;
      assert.equal(params.version, version);
      return params.diagnostics;
    }
  }
  const configure = kessel => client.send(notification('workspace/didChangeConfiguration', { settings: { kessel } }));
  configure({ plugins: ['typescript'], categories: { correctness: 'warn' }, rules: null });
  assert.deepEqual(summary(await republished(buffer, 4)), [thisAlias(2, 1), selfAssign(2, 1)]);
  assert.deepEqual((await republished(scratch, 1)).map(d => [d.code, d.severity]), [['L2012', 2]]);
  configure({ plugins: ['unicorn'], categories: { correctness: 'error' } });
  assert.deepEqual(summary(await republished(buffer, 4)), [selfAssign(1, 1)]);
  assert.deepEqual(summary(await republished(scratch, 1)),
    [['L6006', 'unicorn/no-thenable', 1, range(0, 6, 10)], ['L2012', 'no-self-assign', 1, range(0, 34, 35)]]);
  // Unset settings arrive as null and an empty object, and select nothing.
  configure({ plugins: null, categories: {} });
  assert.deepEqual(summary(await republished(buffer, 4)), [selfAssign(1, 1)]);
  assert.deepEqual((await republished(scratch, 1)).map(d => d.code), ['L2012']);
  // An unknown category is reported for each document, whose diagnostics are
  // withdrawn until the setting is corrected.
  configure({ categories: { imaginary: 'warn' } });
  for (let uri; uri !== scratch;) {
    const logged = (await client.next(undefined, 'window/logMessage')).params;
    assert.deepEqual([logged.type, logged.message], [1, 'Unknown lint category imaginary']);
    const { params } = await client.next(undefined, 'textDocument/publishDiagnostics');
    assert.deepEqual(params.diagnostics, []);
    uri = params.uri;
  }
  configure({});
  await republished(buffer, 4);
  await republished(scratch, 1);
  for (const uri of [buffer, scratch]) {
    client.send(notification('textDocument/didClose', { textDocument: { uri } }));
    assert.deepEqual(await diagnostics(client, uri, undefined), []);
  }
}

async function missingAssignment(client) {
  const buffer = uriFor('unsaved-assignment.js');
  const text = '/*🌱*/ let value=0; value += ;';
  const column = text.lastIndexOf(';'); // JavaScript string indices are UTF-16 units.
  client.send(open(buffer, text, 'javascript'));
  const reported = (await diagnostics(client, buffer, 1)).filter(d => d.code === 'K2020');
  assert.deepEqual(reported.map(d => d.range), [range(0, column, column + 1)]);
  client.send(change(buffer, 2, { range: range(0, column, column), text: '1' }));
  assert.deepEqual(await diagnostics(client, buffer, 2), []);
  client.send(notification('textDocument/didClose', { textDocument: { uri: buffer } }));
  assert.deepEqual(await diagnostics(client, buffer, undefined), []);
}

async function close(client) {
  client.send(request(8, 'shutdown'), request(9, 'example/unsupported'), notification('exit'));
  assert.equal((await client.next(8)).result, null);
  assert.equal((await client.next(9)).error.code, -32600);
  assert.deepEqual(await client.exit, [0, null]);
}

async function main() {
  fs.mkdirSync(path.join(folder, 'flow'));
  fs.writeFileSync(path.join(folder, 'flow/.oxlintrc.json'), JSON.stringify({
    categories: { correctness: 'off' }, rules: { 'getter-return': ['warn', { allowImplicit: true }], 'no-unreachable': 'error',
      'no-fallthrough': ['warn', { commentPattern: '^carry on$', reportUnusedFallthroughComment: true }] },
  }));
  fs.mkdirSync(path.join(folder, 'globals'));
  fs.mkdirSync(path.join(folder, 'react'));
  fs.writeFileSync(path.join(folder, 'react/.oxlintrc.json'), JSON.stringify({
    plugins: ['react'], rules: { 'react/rules-of-hooks': 'warn' },
  }));
  fs.mkdirSync(path.join(folder, 'plugins'));
  fs.writeFileSync(path.join(folder, 'plugins/.oxlintrc.json'), JSON.stringify({
    plugins: ['unicorn'], categories: { correctness: 'error' },
    rules: { 'typescript/no-namespace': 'warn', 'prefer-const': 'warn' },
  }));
  fs.mkdirSync(path.join(folder, 'suppress'));
  fs.writeFileSync(path.join(folder, 'suppress/.oxlintrc.json'), JSON.stringify({
    rules: { eqeqeq: 'error', 'no-debugger': 'warn', 'no-console': ['error', { allow: ['warn'] }] },
  }));
  fs.mkdirSync(path.join(folder, 'pkg'));
  fs.writeFileSync(path.join(folder, 'pkg/.oxlintrc.json'), JSON.stringify({
    extends: '../kessel.lint.json', overrides: [{ files: ['new folder/*.ts'], rules: { 'no-debugger': 'error' } }],
  }));
  for (const versioned of [true, false]) {
    fs.writeFileSync(path.join(folder, 'kessel.lint.json'), JSON.stringify({
      ignorePatterns: ['ignored/*'], rules: { 'no-debugger': 'off', 'prefer-const': 'warn' },
    }));
    const client = launch();
    try {
      await initialize(client, versioned);
      await edits(client, versioned);
      await quickFixes(client, versioned);
      await suppressions(client, versioned);
      await globalSettings(client);
      await reactHooks(client, versioned);
      await controlFlow(client);
      await workspaceFolders(client);
      await projects(client);
      await formatting(client);
      await generalFormatting(client);
      await parserLimits(client);
      await pluginRules(client, versioned);
      await missingAssignment(client);
      await close(client);
    } finally { client.stop(); }
  }
  if (!installed) rangeFormattingGuard();
  const premature = launch();
  try {
    premature.send(notification('exit'));
    assert.deepEqual(await premature.exit, [1, null]);
  } finally { premature.stop(); }
  console.log('Language server passed stdio, UTF-16 edits, workspace lint, plugin rules, safe fixes, ' +
    'whole and range formatting, parser limits and lifecycle checks.');
}
main().catch(error => { console.error(error); process.exitCode = 1; })
  .finally(() => fs.rmSync(folder, { recursive: true, force: true }));
