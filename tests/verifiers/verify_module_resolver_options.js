'use strict';

// Check the enhanced-resolve style options of `kessel resolve` against fixed
// expectations on a small tree. The SDK spelling of the same options is
// compared with oxc-resolver by verify_module_resolver_reference.js.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-resolver-options-')));
const executable = process.platform === 'win32' ? 'kessel.exe' : 'kessel';
const binary = path.resolve(__dirname, '../../bin', executable);
const importer = path.join(root, 'app/src/main.js');

function fixture(name, contents = '') {
  const filename = path.join(root, name);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, contents);
  return filename;
}

function resolve(specifier, ...options) {
  const result = spawnSync(binary, ['resolve', specifier, '--from', importer, ...options], { encoding: 'utf8' });
  if (result.status !== 0) return result.stderr.trim();
  const value = JSON.parse(result.stdout);
  return value.kind === 'file' ? value.path : value.kind;
}

try {
  fixture('app/src/main.js');
  const sibling = fixture('app/src/sibling.js');
  const asset = fixture('public/assets/logo.js');
  const style = fixture('app/node_modules/themed/index.css');
  const script = fixture('app/node_modules/themed/index.js');
  const shim = fixture('app/shims/buffer.js');
  fixture('app/node_modules/dual/package.json', JSON.stringify({
    exports: { node: './node.js', worker: './worker.js', default: './default.js' },
  }));
  const nodeEntry = fixture('app/node_modules/dual/node.js');
  const workerEntry = fixture('app/node_modules/dual/worker.js');
  const defaultEntry = fixture('app/node_modules/dual/default.js');

  // roots: a server-relative request is looked up below each root first.
  assert.match(resolve('/assets/logo.js', '--require'), /Not_Found/);
  assert.equal(resolve('/assets/logo.js', '--require', '--root', path.join(root, 'public')), asset);
  assert.equal(resolve('/assets/logo', '--require', '--root', path.join(root, 'app'), '--root', path.join(root, 'public')), asset);
  assert.equal(resolve(asset, '--require', '--root', path.join(root, 'public'), '--prefer-absolute'), asset);
  assert.equal(resolve('/assets', '--root', path.join(root, 'public'), '--resolve-to-context'), path.dirname(asset));

  // preferRelative: a bare request names a sibling before a package.
  assert.match(resolve('sibling.js', '--require'), /Not_Found/);
  assert.equal(resolve('sibling.js', '--require', '--prefer-relative'), sibling);
  assert.equal(resolve('themed', '--require', '--prefer-relative'), script);

  // fullySpecified: overrides the default of either mode.
  assert.equal(resolve('./sibling', '--require'), sibling);
  assert.match(resolve('./sibling', '--require', '--fully-specified'), /Not_Found/);
  assert.match(resolve('./sibling'), /Not_Found/);
  assert.equal(resolve('./sibling', '--no-fully-specified'), sibling);
  assert.equal(resolve('themed', '--require', '--fully-specified'), script);

  // fallback: consulted only after ordinary resolution failed, in order.
  assert.equal(resolve('themed', '--require', '--fallback', 'themed=' + shim), script);
  assert.match(resolve('buffer/extra', '--require'), /Not_Found/);
  assert.equal(resolve('absent', '--require', '--fallback', 'absent=' + path.join(root, 'nowhere'),
    '--fallback', 'absent=' + shim), shim);
  assert.equal(resolve('absent/buffer', '--require', '--fallback', 'absent=' + path.dirname(shim)), shim);
  assert.match(resolve('absent/buffer', '--require', '--fallback', 'absent$=' + path.dirname(shim)), /Not_Found/);
  assert.equal(resolve('absent', '--require', '--fallback-ignore', 'absent'), 'ignored');
  assert.equal(resolve('absent', '--fallback', 'absent=./sibling'), sibling);

  // restrictions: a candidate outside them does not exist for the lookup.
  assert.equal(resolve('themed', '--require', '--extension', '.js', '--extension', '.css'), script);
  assert.equal(resolve('themed', '--require', '--extension', '.js', '--extension', '.css',
    '--restriction-regex', '\\.css$'), style);
  assert.equal(resolve('themed', '--require', '--restriction', path.join(root, 'app')), script);
  assert.match(resolve('themed', '--require', '--restriction', path.join(root, 'public')), /Not_Found/);
  assert.match(resolve('themed', '--require', '--restriction', 'relative'), /Invalid_Restriction/);
  assert.match(resolve('themed', '--require', '--restriction-regex', '('), /Invalid_Restriction/);

  // explicitConditions: only the listed conditions and "default" apply.
  assert.equal(resolve('dual'), nodeEntry);
  assert.equal(resolve('dual', '--explicit-conditions'), defaultEntry);
  assert.equal(resolve('dual', '--explicit-conditions', '--condition', 'worker'), workerEntry);

  // resolveToContext: the answer is a directory.
  assert.equal(resolve('themed', '--resolve-to-context'), path.dirname(script));
  assert.equal(resolve('.', '--resolve-to-context'), path.dirname(importer));
  assert.match(resolve('./main.js', '--resolve-to-context'), /Not_Found/);

  // tsconfig references: the project that owns the importer supplies paths.
  fixture('tsconfig.json', JSON.stringify({
    compilerOptions: { paths: { '@lib/*': ['./public/assets/*'] } }, references: [{ path: './app' }],
  }));
  fixture('app/tsconfig.json', JSON.stringify({ compilerOptions: { paths: { '@lib/*': ['./src/*'] } } }));
  const config = path.join(root, 'tsconfig.json');
  assert.equal(resolve('@lib/logo.js', '--tsconfig', config), asset);
  assert.match(resolve('@lib/sibling.js', '--tsconfig', config), /Not_Found|Invalid_Specifier/);
  assert.equal(resolve('@lib/sibling.js', '--tsconfig', config, '--tsconfig-references'), sibling);
  assert.equal(resolve('@lib/logo.js', '--tsconfig', root), asset);
  console.log('Resolver CLI passed roots, fallback, restriction, context, condition and reference options');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
