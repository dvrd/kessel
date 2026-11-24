'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runTests, runVSCodeCommand } = require('@vscode/test-electron');
const { output } = require('../package_vsix');

async function main() {
  const stage = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-editor-')));
  const folder = path.join(stage, 'workspace');
  const extensions = path.join(stage, 'extensions');
  const profile = ['--extensions-dir=' + extensions, '--user-data-dir=' + path.join(stage, 'profile')];
  const editor = {
    version: process.argv[2] || require('../package.json').engines.vscode.slice(1),
    cachePath: path.resolve(__dirname, '../../../bin/vscode-test'),
  };
  try {
    fs.mkdirSync(folder);
    fs.writeFileSync(path.join(folder, 'kessel.lint.json'), JSON.stringify({
      rules: { 'no-debugger': 'warn', 'prefer-const': 'off' }, ignorePatterns: ['ignored/*'],
    }));
    fs.writeFileSync(path.join(folder, 'component.tsx'), 'export const saved = true;\n');
    const result = await runVSCodeCommand([...profile, '--install-extension', output], editor);
    console.log(result.stdout.trim());
    const installed = fs.readdirSync(extensions, { withFileTypes: true }).filter(entry =>
      entry.isDirectory() && entry.name.startsWith('dvrd.kessel-'));
    assert.equal(installed.length, 1, 'Expected an installed Kessel VSIX');
    const extension = path.join(extensions, installed[0].name);
    await runTests({
      ...editor,
      extensionDevelopmentPath: extension,
      extensionTestsPath: path.join(__dirname, 'suite.js'),
      launchArgs: [...profile, '--disable-updates', '--disable-telemetry', folder],
    });
  } catch (error) {
    const logs = path.join(stage, 'profile/logs');
    if (fs.existsSync(logs)) {
      for (const relative of fs.readdirSync(logs, { recursive: true })) {
        if (/kessel.*\.log$/i.test(path.basename(relative))) {
          const lines = fs.readFileSync(path.join(logs, relative), 'utf8').split('\n');
          console.error(lines.filter(line => /error|exited|crashed/i.test(line) && !line.includes('0x')).slice(-12).join('\n'));
        }
      }
    }
    throw error;
  } finally {
    fs.rmSync(stage, { recursive: true, force: true, maxRetries: 5 });
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
