'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-resolver-cli-'));
const executable = process.platform === 'win32' ? 'kessel.exe' : 'kessel';
const binary = path.resolve(__dirname, '../../bin', executable);
const importer = path.join(root, 'src', 'main.ts');
const config = path.join(root, 'tsconfig.json');

function fixture(name, contents = '') {
  const filename = path.join(root, name);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, contents);
  return filename;
}

function resolveModule(specifier, ...options) {
  return spawnSync(binary, ['resolve', specifier, '--from', importer, ...options], { encoding: 'utf8' });
}

function expectPath(specifier, filename, ...options) {
  const result = resolveModule(specifier, ...options);
  assert.equal(result.status, 0, result.stderr || String(result.error));
  const value = JSON.parse(result.stdout);
  assert.equal(value.kind, 'file');
  assert.equal(fs.realpathSync(value.path), fs.realpathSync(filename));
}

try {
  fixture('src/main.ts');
  const basename = process.platform === 'win32' ? 'with space' : 'with "quotes"';
  const source = fixture('src/' + basename + '.ts');
  fixture('tsconfig.json', JSON.stringify({ compilerOptions: { paths: { alias: ['./src/' + basename] } } }));
  const main = fixture('node_modules/pkg/index.js');
  const moduleEntry = fixture('node_modules/pkg/module.js');
  const browser = fixture('node_modules/pkg/browser.js');
  fixture('node_modules/pkg/package.json', JSON.stringify({
    main: './index.js', module: './module.js', browser: './browser.js', '': './module.js',
  }));
  const conditional = fixture('node_modules/condition/feature.js');
  fixture('node_modules/condition/package.json', JSON.stringify({ exports: { feature: './feature.js' } }));
  expectPath('alias', source, '--tsconfig', config);
  expectPath('pkg', main, '--require');
  expectPath('pkg', moduleEntry, '--main-field', 'module', '--main-field', 'main');
  expectPath('pkg', browser, '--main-field', 'browser', '--main-field', 'module');
  const fallback = fixture('node_modules/pkg/fallback.js');
  expectPath('pkg', fallback, '--main-field', 'module', '--no-main-fields', '--main-file', 'fallback');
  expectPath('pkg', fallback, '--browser', '--no-main-fields', '--main-file', 'fallback');
  expectPath('pkg', moduleEntry, '--no-main-fields', '--main-field', 'module');
  expectPath('pkg', moduleEntry, '--main-field', '');
  expectPath('condition', conditional, '--condition', 'feature');
  const mapped = fixture('node_modules/mapped/source.js');
  const mappedIndex = fixture('node_modules/mapped/index.js');
  fixture('node_modules/mapped/package.json', JSON.stringify({
    exports: { '.': './index.js' },
    meta: { 'public.api': { './*': './*.js', '.': { browser: './index.js', default: './source.js' } } },
  }));
  const customExports = ['--exports-fields', '["missing",["meta","public.api"],"exports"]'];
  expectPath('mapped', mapped, ...customExports);
  expectPath('mapped', mappedIndex, '--browser', ...customExports);
  expectPath('mapped/source', mapped, ...customExports);
  expectPath('mapped/source.js', mapped, '--exports-fields', '[]');
  assert.match(resolveModule('mapped/source', '--exports-fields', '["exports",["meta","public.api"]]').stderr,
    /Package_Path_Not_Exported/);
  for (const invalid of ['"exports"', '[2]', '[[null]]', '[', '["exports",]', '[["tool",]]']) {
    assert.equal(resolveModule('mapped', '--exports-fields', invalid).status, 2);
  }
  const rawPackage = 'node_modules/raw/package.json';
  fixture('node_modules/raw/a.js');
  const last = fixture('node_modules/raw/last.js');
  for (const manifest of [
    '{"exports":"./a.js","exports":"./last.js"}',
    '{"exports":{".":"./a.js",".":"./last.js"}}',
    '{"exports":{"require":"./a.js","default":"./a.js","require":"./last.js"}}',
    '{"exp\\u006frts":".\\/last.js","unused":"\\\\u12g4"}',
  ]) {
    fixture(rawPackage, manifest);
    expectPath('raw', last, '--require');
  }
  for (const malformed of [
    '{"exports":{".":"./a.js",}}', '{"exports":["./a.js",]}',
    '{"exports":"./a.js","unused":01}', '{"exports":"./a.js","unused":1e}',
    '{"exports":"./a.js","unused":"\\u12g4"}', '{"\\u12g4":"field"}',
    '{"exports":"./a.js"}\0junk', '{"exports":"./a.js"} extra',
  ]) {
    fixture(rawPackage, malformed);
    const result = resolveModule('raw');
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Invalid_Package_Config/);
  }
  const vendorEntry = fixture('vendor/pkg/index.js');
  const localEntry = fixture('src/local/pkg/index.js');
  const subpath = fixture('src/local/pkg/detail.js');
  const shared = fixture('vendor/@team/shared/entry.js');
  fixture('vendor/@team/shared/package.json', JSON.stringify({ exports: './entry.js' }));
  const vendor = ['--module-dir', 'vendor'];
  const local = ['--module-dir', 'local'];
  fixture('vendor/pkg.js');
  expectPath('pkg', vendorEntry, ...vendor, ...local);
  expectPath('pkg', vendorEntry, '--require', ...vendor);
  expectPath('pkg', localEntry, ...local, ...vendor);
  expectPath('pkg/detail.js', subpath, ...vendor, ...local);
  expectPath('@team/shared', shared, '--module-dir', path.join(root, 'vendor'));
  assert.equal(resolveModule('@team/shared/private', ...vendor).status, 1);
  assert.equal(resolveModule('pkg', '--no-module-dirs').status, 1);
  expectPath('pkg', main, ...vendor, '--no-module-dirs', '--module-dir', 'node_modules');
  expectPath('./main.ts', importer, '--no-module-dirs');
  fixture('vendor/shadowed/package.json', JSON.stringify({ exports: './missing.js' }));
  fixture('src/local/shadowed/index.js');
  assert.equal(resolveModule('shadowed', ...vendor, ...local).status, 1);
  const direct = fixture('src/direct.js');
  expectPath('direct', direct, '--module-dir', '.');
  expectPath('direct', direct, '--module-dir', '');
  fixture('package.json', JSON.stringify({
    name: 'app', exports: './src/main.ts',
    tools: { public: './src/direct.js', private: { '#next': null, '#absent': './missing.js' } },
    next: { '#next': 'mapped', '#absent': './src/direct.js' },
    imports: { '#shared': '@team/shared', '#loose': 'loose', '#part': 'pkg/detail', '#exact': 'pkg/detail.js' },
  }));
  expectPath('app', importer, '--no-module-dirs');
  expectPath('app', direct, '--exports-fields', '[["tools","public"]]', '--no-module-dirs');
  const customImports = ['--imports-fields', '[["tools","private"],"next"]'];
  expectPath('#next', mapped, ...customImports, ...customExports);
  fixture('src/nested/package.json', '{}');
  const nestedImporter = fixture('src/nested/main.js');
  const privateImport = spawnSync(binary, ['resolve', '#next', '--from', nestedImporter, ...customImports],
    { encoding: 'utf8' });
  assert.equal(privateImport.status, 1);
  assert.match(privateImport.stderr, /Package_Import_Not_Defined/);
  assert.match(resolveModule('#absent', ...customImports).stderr, /Not_Found/);
  assert.match(resolveModule('#next', '--imports-fields', '[]').stderr, /Package_Import_Not_Defined/);
  expectPath('#shared', shared, ...vendor);
  const detail = fixture('vendor/pkg/detail.js');
  const loose = fixture('vendor/loose.js');
  expectPath('loose', loose, ...vendor);
  expectPath('#exact', detail, '--require', ...vendor);
  assert.equal(resolveModule('#part', '--require', ...vendor).status, 1);
  assert.equal(resolveModule('#loose', '--require', ...vendor).status, 1);
  const unownedImporter = fixture('src/node_modules/unowned/main.js');
  for (const request of ['app', '#shared']) {
    const result = spawnSync(binary, ['resolve', request, '--from', unownedImporter, ...vendor]);
    assert.equal(result.status, 1, request);
  }
  const typed = fixture('src/choice.ts');
  const script = fixture('src/choice.js');
  const suffixOrder = ['--require', '--extension', '.ts', '--extension', '.js'];
  expectPath('./choice', typed, ...suffixOrder);
  expectPath('./choice', script, '--require', '--extension', '.js', '--extension', '.ts');
  assert.equal(resolveModule('./choice', '--extension', '.ts').status, 1);
  const exactFile = fixture('src/choice');
  expectPath('./choice', exactFile, ...suffixOrder);
  expectPath('./choice', typed, '--require', '--extension', '.ts', '--extension', '');
  expectPath('./choice', exactFile, '--require', '--no-extensions');
  const start = fixture('src/folder/start.ts');
  const index = fixture('src/folder/index.js');
  expectPath('./folder', start, ...suffixOrder, '--main-file', 'start', '--main-file', 'index');
  expectPath('./folder', index, ...suffixOrder, '--main-file', 'missing', '--main-file', 'index');
  assert.equal(resolveModule('./folder', ...suffixOrder, '--no-main-files').status, 1);
  assert.equal(resolveModule('./folder', '--require', '--no-extensions').status, 1);
  const jsEntry = fixture('src/alias-entry.js');
  const tsEntry = fixture('src/alias-entry.ts');
  const replacement = ['--extension-alias', '.js=.ts,.js'];
  expectPath('./alias-entry.js', tsEntry, ...replacement);
  expectPath('./alias-entry.js', jsEntry, '--require', '--extension-alias', 'js=.js,.ts');
  expectPath('./alias-entry', jsEntry, '--require', ...replacement);
  const onlyJS = fixture('src/only-js.js');
  assert.match(resolveModule('./only-js.js', '--extension-alias', '.js=.ts').stderr, /Extension_Alias_Not_Found/);
  assert.match(resolveModule('./only-js.js', '--extension-alias', '.js').stderr, /Extension_Alias_Not_Found/);
  expectPath('./only-js.js', onlyJS, ...replacement);
  expectPath('./choice.js', exactFile, '--extension-alias', '.js=');
  fixture('node_modules/alias-exports/package.json', '{"exports":"./entry.js","imports":{"#entry":"./entry.js"}}');
  const exportedTS = fixture('node_modules/alias-exports/entry.ts');
  expectPath('alias-exports', exportedTS, ...replacement);
  const internal = spawnSync(binary, ['resolve', '#entry', '--from', exportedTS, ...replacement], { encoding: 'utf8' });
  assert.equal(internal.status, 0, internal.stderr);
  assert.equal(JSON.parse(internal.stdout).path, fs.realpathSync(exportedTS));
  const explicitMain = fixture('node_modules/alias-main/entry.ts');
  fixture('node_modules/alias-main/package.json', '{"main":"entry.js"}');
  expectPath('alias-main', explicitMain, ...replacement);
  fixture('node_modules/alias-browser/package.json', '{"main":"entry.js","browser":{"./entry.ts":"./browser.ts"}}');
  fixture('node_modules/alias-browser/entry.ts');
  const browserEntry = fixture('node_modules/alias-browser/browser.ts');
  expectPath('alias-browser', browserEntry, '--browser', ...replacement);
  assert.equal(resolveModule('./alias-entry.js', '--extension-alias', '=.ts').status, 2);
  const legacy = fixture('node_modules/legacy/lib/start.ts');
  fixture('node_modules/legacy/package.json', '{"main":"./lib"}');
  expectPath('legacy', legacy, '--extension', '.ts', '--main-file', 'start');
  fixture('node_modules/strict/package.json', '{"exports":"./exported"}');
  fixture('node_modules/strict/exported.ts');
  assert.match(resolveModule('strict', ...suffixOrder).stderr, /Not_Found/);
  expectPath('shortcut', source, '--alias', 'shortcut=alias', '--tsconfig', config);
  expectPath('forward/index.js', main, '--alias', 'forward=pkg');
  const exact = resolveModule('forward/index.js', '--alias', 'forward$=pkg');
  assert.equal(exact.status, 1);
  const cycle = resolveModule('one', '--alias', 'one=two', '--alias', 'two=one');
  assert.equal(cycle.status, 1);
  assert.match(cycle.stderr, /Invalid_Alias/);
  if (process.platform !== 'win32') {
    const linkImporter = path.join(root, 'linked.ts');
    fs.symlinkSync(importer, linkImporter);
    const canonical = spawnSync(binary, ['resolve', './' + basename + '.ts', '--from', linkImporter], { encoding: 'utf8' });
    assert.equal(canonical.status, 0, canonical.stderr);
    assert.equal(fs.realpathSync(JSON.parse(canonical.stdout).path), fs.realpathSync(source));
    const preserved = spawnSync(binary, ['resolve', './' + basename + '.ts', '--from', linkImporter, '--preserve-symlinks'], { encoding: 'utf8' });
    assert.equal(preserved.status, 1);
    assert.match(preserved.stderr, /Not_Found/);
  }
  fixture('package.json', JSON.stringify({
    browser: { 'node:fs': false, 'server-only': './src/client.js', './src/server.js': './src/client.js', './src/virtual.js': './src/client.js', './src/folder/start.ts': './src/client.js', cycleA: 'cycleB', cycleB: 'cycleA' },
  }));
  const client = fixture('src/client.js');
  fixture('src/server.js');
  expectPath('pkg', browser, '--browser');
  expectPath('server-only', client, '--browser');
  expectPath('./server.js', client, '--browser');
  expectPath('./server', client, '--browser', '--require');
  expectPath('./virtual', client, '--browser', '--require');
  expectPath('./folder', client, '--browser', ...suffixOrder, '--main-file', 'start');
  const browserMain = fixture('node_modules/browser-mapped/client.js');
  fixture('node_modules/browser-mapped/package.json', JSON.stringify({
    main: './server.js', browser: { './server.js': './client.js' },
  }));
  expectPath('browser-mapped', browserMain, '--browser');
  const browserCondition = fixture('node_modules/browser-condition/browser.js');
  const nodeCondition = fixture('node_modules/browser-condition/node.js');
  fixture('node_modules/browser-condition/package.json', JSON.stringify({
    exports: { node: './node.js', browser: './browser.js' },
  }));
  expectPath('browser-condition', browserCondition, '--browser');
  expectPath('browser-condition', nodeCondition);
  const ignored = resolveModule('node:fs', '--browser');
  assert.equal(ignored.status, 0, ignored.stderr);
  assert.deepEqual(JSON.parse(ignored.stdout), { kind: 'ignored', path: '' });
  const browserCycle = resolveModule('cycleA', '--browser');
  assert.equal(browserCycle.status, 1);
  assert.match(browserCycle.stderr, /Browser_Mapping_Cycle/);
  const builtin = resolveModule('node:fs');
  assert.equal(builtin.status, 0, builtin.stderr);
  assert.deepEqual(JSON.parse(builtin.stdout), { kind: 'builtin', path: 'node:fs' });
  const missing = resolveModule('./no-file.js');
  assert.equal(missing.status, 1);
  assert.equal(missing.stdout, '');
  assert.match(missing.stderr, /Not_Found/);
  const usage = spawnSync(binary, ['resolve', 'pkg'], { encoding: 'utf8' });
  assert.equal(usage.status, 2);
  assert.match(usage.stderr, /--from/);
  console.log('Resolver CLI passed file, package, builtin, and error cases');
  const ts = process.argv.includes('--reference') ? require('../../bench/node_modules/typescript') : null;
  const sdk = process.argv.includes('--reference') ? require('../../npm/kessel') : null;
  require('./verify_module_root_dirs')(binary, path.join(root, 'virtual-workspace'), ts, sdk);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
