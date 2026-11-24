'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { setTimeout: delay } = require('node:timers/promises');
const vscode = require('vscode');

async function waitFor(read, description) {
  const deadline = Date.now() + 15000;
  do {
    const value = await read();
    if (value) return value;
    await delay(50);
  } while (Date.now() < deadline);
  throw new Error('Timed out waiting for ' + description);
}

function diagnostics(doc) {
  return vscode.languages.getDiagnostics(doc.uri).filter(item => item.source === 'kessel');
}

function hasDebugger(doc, severity) {
  return diagnostics(doc).find(item => item.code === 'L2001' && item.severity === severity);
}

function requestActions(doc, range, kind) {
  const version = doc.version;
  return waitFor(async () => {
    assert.equal(doc.version, version, 'Document changed before the code action request completed');
    try {
      return await vscode.commands.executeCommand('vscode.executeCodeActionProvider', doc.uri, range, kind);
    } catch (error) {
      // The workbench can cancel a provider request while diagnostics refresh.
      if (error.name !== 'Canceled') throw error;
    }
  }, kind + ' actions on document version ' + version);
}

async function replace(doc, text) {
  const edits = new vscode.WorkspaceEdit();
  edits.replace(doc.uri, new vscode.Range(doc.positionAt(0), doc.positionAt(doc.getText().length)), text);
  assert.equal(await vscode.workspace.applyEdit(edits), true);
}

async function testEdits(doc) {
  const original = fs.readFileSync(doc.uri.fsPath, 'utf8');
  const line = 'const view = <main title="🚀" />; debugger;';
  await replace(doc, line + '\n');
  const diagnostic = await waitFor(() => hasDebugger(doc, vscode.DiagnosticSeverity.Warning), 'unsaved TSX diagnostic')
    .catch(error => {
      console.error(vscode.languages.getDiagnostics(doc.uri).slice(0, 8).map(d => [d.source, d.code, d.message]));
      throw error;
    });
  assert.equal(diagnostic.range.start.character, line.indexOf('debugger'));
  assert.equal(doc.getText(diagnostic.range), 'debugger;');
  const config = vscode.workspace.getConfiguration('kessel');
  await config.update('rules', { 'no-debugger': 'error' }, vscode.ConfigurationTarget.Workspace);
  await waitFor(() => hasDebugger(doc, vscode.DiagnosticSeverity.Error), 'editor rule override');
  const actions = await requestActions(doc, diagnostic.range, 'source.fixAll.kessel');
  const fix = actions.find(action => action.kind?.value === 'source.fixAll.kessel');
  assert.ok(fix?.edit, 'Expected an editable Kessel code action');
  assert.equal(await vscode.workspace.applyEdit(fix.edit), true);
  await waitFor(() => diagnostics(doc).length === 0, 'cleared diagnostics');
  assert.ok(doc.getText().includes('title="🚀"'));
  assert.equal(doc.getText().includes('debugger'), false);
  assert.equal(fs.readFileSync(doc.uri.fsPath, 'utf8'), original);
  await config.update('rules', undefined, vscode.ConfigurationTarget.Workspace);
}

async function testOnSave(doc) {
  await vscode.workspace.getConfiguration('editor').update('codeActionsOnSave',
    { 'source.fixAll.kessel': 'explicit' }, vscode.ConfigurationTarget.Workspace);
  await replace(doc, 'const example: number = 1;\ndebugger;\n');
  await waitFor(() => hasDebugger(doc, vscode.DiagnosticSeverity.Warning), 'project rules after resetting override');
  await vscode.commands.executeCommand('workbench.action.files.save');
  await waitFor(() => !doc.isDirty && diagnostics(doc).length === 0, 'fix on explicit save');
  assert.equal(fs.readFileSync(doc.uri.fsPath, 'utf8'), 'const example: number = 1;\n\n');
}

async function testSelectedWarning(doc) {
  const text = '/*🚀*/ let item: number = 1; debugger; debugger;\n';
  const config = vscode.workspace.getConfiguration('kessel');
  await config.update('rules', { 'prefer-const': 'warn' }, vscode.ConfigurationTarget.Workspace);
  await replace(doc, text);
  const selected = await waitFor(() => diagnostics(doc).find(d => d.code === 'L4012'), 'binding warning');
  const actions = await requestActions(doc, selected.range, 'quickfix');
  const fix = actions.find(a => a.isPreferred && a.title === 'Replace `let` with `const`');
  assert.ok(fix?.edit, 'Expected a quick fix for the selected binding');
  const [edit] = fix.edit.get(doc.uri);
  assert.equal(doc.getText(edit.range), 'let');
  assert.equal(edit.newText, 'const');
  assert.equal(await vscode.workspace.applyEdit(fix.edit), true);
  assert.equal(doc.getText(), text.replace('let', 'const'));
  await waitFor(() => diagnostics(doc).length === 2 && diagnostics(doc).every(d => d.code === 'L2001'), 'two remaining debugger warnings');
  const second = diagnostics(doc)[1];
  const choices = await requestActions(doc, second.range, 'quickfix');
  const removal = choices.find(a => a.isPreferred && a.title === 'Remove `debugger;`');
  assert.ok(removal?.edit);
  assert.equal(await vscode.workspace.applyEdit(removal.edit), true);
  assert.equal(doc.getText(), '/*🚀*/ const item: number = 1; debugger; \n');
  await waitFor(() => diagnostics(doc).length === 1, 'remaining debugger warning');
  await config.update('rules', undefined, vscode.ConfigurationTarget.Workspace);
}

async function testUntitled() {
  const doc = await vscode.workspace.openTextDocument({ language: 'javascriptreact', content: 'debugger;\nconst a=<a/>;' });
  await vscode.window.showTextDocument(doc);
  await waitFor(() => hasDebugger(doc, vscode.DiagnosticSeverity.Error), 'untitled JSX diagnostic');
  await vscode.languages.setTextDocumentLanguage(doc, 'plaintext');
  await waitFor(() => diagnostics(doc).length === 0, 'cleared diagnostics after language change');
}

async function testFormatting(doc) {
  const config = vscode.workspace.getConfiguration('editor', { uri: doc.uri, languageId: doc.languageId });
  const previous = config.inspect('defaultFormatter').workspaceLanguageValue;
  const saved = fs.readFileSync(doc.uri.fsPath, 'utf8');
  const body = 'const x=<div title="🚀"/>;\n';
  try {
    await config.update('defaultFormatter', 'dvrd.kessel', vscode.ConfigurationTarget.Workspace, true);
    await replace(doc, "import{type A,B}from'./types';\n" + body);
    await vscode.commands.executeCommand('editor.action.formatDocument');
    const expected = 'import { type A, B } from "./types";\n' + body;
    await waitFor(() => doc.getText() === expected, 'Kessel module formatting in the unsaved buffer');
    const version = doc.version;
    await vscode.commands.executeCommand('editor.action.formatDocument');
    assert.equal(doc.version, version);
    assert.equal(fs.readFileSync(doc.uri.fsPath, 'utf8'), saved);
  } finally {
    await config.update('defaultFormatter', previous, vscode.ConfigurationTarget.Workspace, true);
  }
}

async function testSuppressions(doc) {
  const original = fs.readFileSync(doc.uri.fsPath, 'utf8');
  const source = 'const v = <C\n  title={a == b}\n>\n  {/*🚀*/ x == y}<b/>\n</C>;\ndebugger;\n';
  const config = vscode.workspace.getConfiguration('kessel');
  await config.update('rules', { eqeqeq: 'warn' }, vscode.ConfigurationTarget.Workspace);
  await replace(doc, source);
  const warnings = () => diagnostics(doc).filter(d => d.code === 'L1003');
  await waitFor(() => warnings().length === 2, 'JSX attribute and child warnings');
  async function applySuppression(diagnostic, scope) {
    const actions = await requestActions(doc, diagnostic.range, 'quickfix');
    const choice = actions.find(a => a.title === 'Disable eqeqeq for this ' + scope);
    assert.ok(choice?.edit);
    assert.ok(!choice.isPreferred);
    assert.equal(await vscode.workspace.applyEdit(choice.edit), true);
  }
  await applySuppression(warnings()[1], 'line');
  await waitFor(() => warnings().length === 1 && warnings()[0].range.start.line === 1, 'only the attribute warning');
  assert.equal(doc.getText(), source.replace('x == y}', 'x == y /* oxlint-disable-line eqeqeq */}'));
  await applySuppression(warnings()[0], 'file');
  await waitFor(() => warnings().length === 0 && hasDebugger(doc, vscode.DiagnosticSeverity.Warning), 'file rule suppression');
  assert.ok(doc.getText().startsWith('/* oxlint-disable eqeqeq */\n'));
  assert.equal(fs.readFileSync(doc.uri.fsPath, 'utf8'), original);
  await config.update('rules', undefined, vscode.ConfigurationTarget.Workspace);
}

exports.run = async function run() {
  const folder = vscode.workspace.workspaceFolders[0].uri;
  const doc = await vscode.workspace.openTextDocument(vscode.Uri.joinPath(folder, 'component.tsx'));
  await vscode.window.showTextDocument(doc);
  const extension = vscode.extensions.getExtension('dvrd.kessel');
  await waitFor(() => extension?.isActive, 'automatic Kessel activation');
  await testEdits(doc);
  await testSelectedWarning(doc);
  await testSuppressions(doc);
  await testFormatting(doc);
  await testOnSave(doc);
  await testUntitled();
  console.log('Installed Kessel VSIX passed activation, unsaved diagnostics, settings, safe fixes, module formatting, fix on save and untitled JSX in VS Code ' + vscode.version);
};
