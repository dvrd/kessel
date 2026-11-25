'use strict';

const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

async function activate(context) {
  const languages = ['javascript', 'javascriptreact', 'typescript', 'typescriptreact'];
  const documentSelector = languages.flatMap(language => [
    { scheme: 'file', language },
    { scheme: 'untitled', language },
  ]);
  const server = { module: context.asAbsolutePath('npm/kessel/lsp/server.js'), transport: TransportKind.stdio };
  client = new LanguageClient('kessel', 'Kessel', server, {
    documentSelector,
    initializationOptions() {
      const config = vscode.workspace.getConfiguration('kessel');
      return {
        rules: config.get('rules'),
        categories: config.get('categories'),
        plugins: config.get('plugins') ?? undefined,
        reportUnusedDisableDirectives: config.get('reportUnusedDisableDirectives') ?? undefined,
      };
    },
    synchronize: {
      configurationSection: [
        'kessel.rules', 'kessel.categories', 'kessel.plugins',
        'kessel.reportUnusedDisableDirectives',
      ],
    },
  });
  await client.start();
}

async function deactivate() {
  if (client) await client.stop();
}

module.exports = { activate, deactivate };
