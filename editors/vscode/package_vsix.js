'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createVSIX } = require('@vscode/vsce');

const root = path.resolve(__dirname, '../..');
const manifest = require('./package.json');
const target = process.platform + '-' + process.arch;
const output = path.join(root, 'bin', 'kessel-' + manifest.version + '-' + target + '.vsix');

function copyRuntime(stage) {
  const sdk = path.join(root, 'npm/kessel');
  const destination = path.join(stage, 'npm/kessel');
  const sdkManifest = require(path.join(sdk, 'package.json'));
  const sharedExtension = { darwin: 'dylib', linux: 'so', win32: 'dll' }[process.platform];
  if (!Object.hasOwn(sdkManifest.optionalDependencies, '@dvrdlibs/kessel-' + target)) {
    throw new Error('Unsupported native extension target ' + target);
  }
  fs.mkdirSync(destination, { recursive: true });
  for (const file of ['package.json', ...sdkManifest.files]) {
    fs.cpSync(path.join(sdk, file), path.join(destination, file), { recursive: true });
  }
  fs.mkdirSync(path.join(stage, 'bin'));
  const binary = 'libkessel.' + sharedExtension;
  fs.copyFileSync(path.join(root, 'bin', binary), path.join(stage, 'bin', binary));
}

function copyDependencies(stage) {
  const lock = require('./package-lock.json');
  for (const [name, entry] of Object.entries(lock.packages)) {
    if (!name || entry.dev) continue;
    const from = path.join(__dirname, name);
    if (entry.optional && !fs.existsSync(from)) continue;
    // Nested dependencies get their own lockfile entries, including optional native packages.
    fs.cpSync(from, path.join(stage, name), {
      recursive: true, filter: file => path.basename(file) !== 'node_modules',
    });
  }
}

async function packageExtension() {
  // Stage on the output filesystem so readers always see a complete archive.
  const stage = fs.realpathSync(fs.mkdtempSync(path.join(path.dirname(output), '.kessel-vsix-')));
  try {
    const { devDependencies, scripts, ...published } = manifest;
    fs.writeFileSync(path.join(stage, 'package.json'), JSON.stringify(published, null, 2));
    for (const file of ['extension.js', 'README.md']) {
      fs.copyFileSync(path.join(__dirname, file), path.join(stage, file));
    }
    fs.copyFileSync(path.join(root, 'LICENSE'), path.join(stage, 'LICENSE'));
    copyRuntime(stage);
    copyDependencies(stage);
    const archive = path.join(stage, path.basename(output));
    await createVSIX({ cwd: stage, packagePath: archive, target, useYarn: false });
    fs.renameSync(archive, output);
    console.log(output);
  } finally {
    fs.rmSync(stage, { recursive: true, force: true });
  }
}

if (require.main === module) {
  packageExtension().catch(error => { console.error(error); process.exitCode = 1; });
}

module.exports = { output };
