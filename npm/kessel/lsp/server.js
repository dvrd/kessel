#!/usr/bin/env node
'use strict';

const path = require('node:path');
const { fileURLToPath } = require('node:url');
const { lintSync } = require('../index');
const { DocumentText } = require('./document');
const { formatDocument } = require('./format');
const { readFrames, writeMessage } = require('./transport');

const languages = new Map(Object.entries({
  javascript: 'js', javascriptreact: 'jsx', typescript: 'ts', typescriptreact: 'tsx',
}));
const fixKind = 'source.fixAll.kessel';
const watchRequest = 'kessel-config-watch';
const send = message => writeMessage(process.stdout, message);
const notify = (method, params) => send({ method, params });

function filePath(uri) {
  try { return fileURLToPath(uri); } catch { return undefined; }
}

function workspaceFor(roots, filename) {
  for (const root of roots) {
    const relative = path.relative(root, filename);
    if (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep)) return root;
  }
}

function comparePosition(a, b) {
  return a.line - b.line || a.character - b.character;
}

function overlaps(diagnostic, selection) {
  if (comparePosition(selection.start, selection.end) === 0) {
    return comparePosition(diagnostic.start, selection.start) <= 0 && comparePosition(selection.start, diagnostic.end) <= 0;
  }
  return comparePosition(diagnostic.start, selection.end) < 0 && comparePosition(selection.start, diagnostic.end) < 0;
}

function workspaceEdit(doc, edits, versioned) {
  return versioned
    ? { documentChanges: [{ textDocument: { uri: doc.uri, version: doc.version }, edits }] }
    : { changes: { [doc.uri]: edits } };
}

function fileHeader(content) {
  const { text } = content;
  const newline = /\r\n|[\r\n\u2028\u2029]/.exec(text);
  let offset = text.charCodeAt(0) === 0xfeff ? 1 : 0;
  if (text.startsWith('#!') && newline) offset = newline.index + newline[0].length;
  const start = content.position(offset);
  return { range: { start, end: start }, newline: newline?.[0] ?? '\n' };
}

function diagnosticEdit(content, edit) {
  return { range: { start: content.bytePosition(edit.start), end: content.bytePosition(edit.end) }, newText: edit.text };
}

function quickFixes(doc, selection, versioned) {
  const fixes = new Map(), suggestions = new Map(), suppressions = new Map();
  function add(group, title, change, diagnostic) {
    const key = JSON.stringify(change);
    if (group.has(key)) { group.get(key).diagnostics.push(diagnostic); return; }
    const edit = workspaceEdit(doc, [change], versioned);
    group.set(key, { title, kind: 'quickfix', isPreferred: group === fixes, diagnostics: [diagnostic], edit });
  }
  for (const { diagnostic, fix, suggestion, suppression } of doc.fixes) {
    if (!overlaps(diagnostic.range, selection)) continue;
    if (suggestion) add(suggestions, suggestion.title, diagnosticEdit(doc.content, suggestion), diagnostic);
    if (suppression) {
      const { rule, line } = suppression;
      if (line) add(suppressions, 'Disable ' + rule + ' for this line', diagnosticEdit(doc.content, line), diagnostic);
      const header = doc.header ??= fileHeader(doc.content);
      const change = { range: header.range, newText: '/* oxlint-disable ' + rule + ' */' + header.newline };
      add(suppressions, 'Disable ' + rule + ' for this file', change, diagnostic);
    }
    if (!fix) continue;
    const change = diagnosticEdit(doc.content, fix);
    const { range } = change;
    const previous = doc.content.text.slice(doc.content.offset(range.start), doc.content.offset(range.end));
    let title = 'Fix ' + diagnostic.code;
    if (previous.length <= 40 && !/[\r\n\u2028\u2029]/.test(previous)) {
      title = fix.text ? 'Replace `' + previous + '` with `' + fix.text + '`' : 'Remove `' + previous + '`';
    }
    add(fixes, title, change, diagnostic);
  }
  return [...fixes.values(), ...suggestions.values(), ...suppressions.values()];
}

class Server {
  documents = new Map();
  roots = new Set();
  settings = {};
  state = 'starting';

  initialize(params) {
    this.literalActions = Boolean(params.capabilities?.textDocument?.codeAction?.codeActionLiteralSupport);
    this.relatedDiagnostics = params.capabilities?.textDocument?.publishDiagnostics?.relatedInformation === true;
    this.versionedEdits = params.capabilities?.workspace?.workspaceEdit?.documentChanges === true;
    this.registerWatchers = params.capabilities?.workspace?.didChangeWatchedFiles?.dynamicRegistration === true;
    this.settings = params.initializationOptions || {};
    const folders = params.workspaceFolders ?? [{ uri: params.rootUri }];
    for (const folder of folders) {
      const root = filePath(folder.uri);
      if (root) this.roots.add(root);
    }
    this.state = 'running';
    return {
      capabilities: {
        positionEncoding: 'utf-16',
        textDocumentSync: { openClose: true, change: 2, save: { includeText: false } },
        documentFormattingProvider: true,
        ...(this.literalActions && { codeActionProvider: { codeActionKinds: ['quickfix', fixKind] } }),
        workspace: { workspaceFolders: { supported: true, changeNotifications: true } },
      },
      serverInfo: { name: 'Kessel' },
    };
  }

  lint(doc, fix) {
    const filename = filePath(doc.uri);
    const roots = [...this.roots].sort((a, b) => b.length - a.length);
    return lintSync(filename ?? 'untitled.' + doc.lang, doc.content.text, {
      lang: doc.lang, workspaceRoot: filename && workspaceFor(roots, filename),
      rules: this.settings.rules, reportUnusedDisableDirectives: this.settings.reportUnusedDisableDirectives,
      fix, includeFixes: !fix && this.literalActions, includeSuggestions: !fix && this.literalActions,
      includeSuppressions: !fix && this.literalActions,
    });
  }

  async publish(doc) {
    const diagnostics = [];
    doc.fixes = [];
    try {
      for (const d of this.lint(doc, false).diagnostics) {
        const diagnostic = {
          range: { start: doc.content.bytePosition(d.start), end: doc.content.bytePosition(d.end) },
          severity: d.severity === 'warning' ? 2 : 1, code: d.code || undefined, message: d.message, source: 'kessel',
        };
        if (this.relatedDiagnostics && d.related?.length) {
          diagnostic.relatedInformation = d.related.map(note => ({
            location: { uri: doc.uri, range: { start: doc.content.bytePosition(note.start), end: doc.content.bytePosition(note.end) } },
            message: note.message,
          }));
        }
        diagnostics.push(diagnostic);
        if (d.fix || d.suggestion || d.suppression) {
          doc.fixes.push({ diagnostic, fix: d.fix, suggestion: d.suggestion, suppression: d.suppression });
        }
      }
    } catch (error) {
      await notify('window/logMessage', { type: 1, message: error.message });
    }
    await notify('textDocument/publishDiagnostics', { uri: doc.uri, version: doc.version, diagnostics });
  }

  async refresh() {
    for (const doc of this.documents.values()) await this.publish(doc);
  }

  actions(doc, range, context) {
    if (!doc || !this.literalActions) return [];
    const wants = kind => !context.only || context.only.some(base => base === kind || kind.startsWith(base + '.'));
    const actions = wants('quickfix') ? quickFixes(doc, range, this.versionedEdits) : [];
    if (!context.only || !wants(fixKind)) return actions;
    const { output } = this.lint(doc, true);
    if (typeof output === 'string' && output !== doc.content.text) {
      const whole = { start: { line: 0, character: 0 }, end: doc.content.position(doc.content.text.length) };
      const edit = workspaceEdit(doc, [{ range: whole, newText: output }], this.versionedEdits);
      actions.push({ title: 'Apply all safe Kessel fixes', kind: fixKind, edit });
    }
    return actions;
  }

  async documentEvent(method, params) {
    const reference = params.textDocument;
    const doc = this.documents.get(reference.uri);
    switch (method) {
      case 'textDocument/didOpen': {
        const lang = languages.get(reference.languageId);
        if (!lang || typeof reference.text !== 'string' || !Number.isInteger(reference.version)) return;
        const opened = { uri: reference.uri, lang, version: reference.version, content: new DocumentText(reference.text) };
        this.documents.set(opened.uri, opened);
        return this.publish(opened);
      }
      case 'textDocument/didChange': {
        if (!doc || !Number.isInteger(reference.version) || reference.version <= doc.version) return;
        let content = doc.content;
        for (const change of params.contentChanges) content = content.change(change);
        doc.content = content;
        doc.header = undefined;
        doc.version = reference.version;
        return this.publish(doc);
      }
      case 'textDocument/didClose':
        if (!this.documents.delete(reference.uri)) return;
        return notify('textDocument/publishDiagnostics', { uri: reference.uri, diagnostics: [] });
      case 'textDocument/didSave':
        if (doc) return this.publish(doc);
        if (filePath(reference.uri)?.endsWith('.json')) return this.refresh();
    }
  }

  async handle(message) {
    if (message?.jsonrpc === '2.0' && message.method === undefined && ('result' in message || 'error' in message)) {
      if (message.id === watchRequest && message.error) {
        return notify('window/logMessage', { type: 2, message: 'Client declined lint config file watching' });
      }
      return;
    }
    if (message?.jsonrpc !== '2.0' || typeof message.method !== 'string' ||
        ('id' in message && !['number', 'string'].includes(typeof message.id))) {
      return send({ id: null, error: { code: -32600, message: 'Invalid request' } });
    }
    const { id, method, params = {} } = message;
    const fail = (code, reason) => id === undefined ? undefined : send({ id, error: { code, message: reason } });
    if (method === 'exit' && id === undefined) {
      process.exitCode = this.state === 'shutdown' ? 0 : 1;
      this.state = 'exited';
      return;
    }
    if (this.state === 'starting' && method !== 'initialize') return fail(-32002, 'Server is awaiting initialize');
    if (this.state === 'shutdown') return fail(-32600, 'Server has shut down');
    try {
      if (method === 'initialize') {
        if (id === undefined || this.state !== 'starting') return fail(-32600, 'Invalid initialize request');
        return send({ id, result: this.initialize(params) });
      }
      if (method === 'shutdown' && id !== undefined) {
        this.state = 'shutdown';
        return send({ id, result: null });
      }
      if (method === 'textDocument/codeAction' && id !== undefined) {
        return send({ id, result: this.actions(this.documents.get(params.textDocument.uri), params.range, params.context) });
      }
      if (method === 'textDocument/formatting' && id !== undefined) {
        const uri = params.textDocument.uri;
        return send({ id, result: formatDocument(this.documents.get(uri), filePath(uri), params.options) });
      }
      if (id !== undefined) return fail(-32601, 'Unknown method ' + method);
      if (method === 'initialized' && this.registerWatchers) {
        this.registerWatchers = false;
        return send({ id: watchRequest, method: 'client/registerCapability', params: { registrations: [{
          id: watchRequest, method: 'workspace/didChangeWatchedFiles', registerOptions: {
            watchers: [{ globPattern: '**/kessel.lint.json' }, { globPattern: '**/.oxlintrc.json' }],
          },
        }] } });
      }
      if (method.startsWith('textDocument/')) return await this.documentEvent(method, params);
      if (method === 'workspace/didChangeWorkspaceFolders') {
        for (const folder of params.event.removed) this.roots.delete(filePath(folder.uri));
        for (const folder of params.event.added) {
          const root = filePath(folder.uri);
          if (root) this.roots.add(root);
        }
        return await this.refresh();
      }
      if (method === 'workspace/didChangeConfiguration') {
        this.settings = params.settings?.kessel || {};
        return await this.refresh();
      }
      if (method === 'workspace/didChangeWatchedFiles') return await this.refresh();
    } catch (error) {
      if (id !== undefined) return fail(error.code === 'Invalid_Config' ? -32603 : -32602, error.message);
      return notify('window/logMessage', { type: 1, message: error.message });
    }
  }
}

async function main() {
  const server = new Server();
  for await (const frame of readFrames(process.stdin)) {
    let message;
    try { message = JSON.parse(frame); } catch {
      await send({ id: null, error: { code: -32700, message: 'Invalid JSON' } });
      continue;
    }
    await server.handle(message);
    if (server.state === 'exited') return;
  }
  process.exitCode = 1;
}

main().catch(error => {
  process.stderr.write('Kessel language server: ' + error.message + '\n');
  process.exitCode = 1;
});
