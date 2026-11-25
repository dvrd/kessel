'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

module.exports = function verifyRootDirs(binary, dir, ts, sdk) {
  function put(name, contents = '') {
    const filename = path.join(dir, name);
    fs.mkdirSync(path.dirname(filename), {recursive: true});
    fs.writeFileSync(filename, typeof contents === 'string' ? contents : JSON.stringify(contents));
    return filename;
  }
  put('project.json', {extends: './policy/base.json'});
  put('policy/base.json', {compilerOptions: {
    moduleResolution: 'bundler', rootDirs: ['../src', '${configDir}/generated', '../extra', '../src/nested'],
  }});
  put('clear.json', {extends: './project.json', compilerOptions: {rootDirs: []}});
  put('null.json', {extends: './project.json', compilerOptions: {rootDirs: null}});
  put('reverse.json', {extends: ['./project.json', './policy/order.json']});
  put('policy/order.json', {compilerOptions: {rootDirs: [path.join(dir, 'src'), '../extra', '../generated']}});
  put('configuration.json', {compilerOptions: {rootDirs: 'src'}});
  const names = ['src/main.ts', 'src/local.ts', 'generated/local.ts', 'generated/only.tsx',
    'extra/only.ts', 'generated/esm.mts', 'generated/cjs.d.cts', 'generated/icon.css.d.ts',
    'src/theme.css', 'generated/theme.d.css.ts', 'generated/view/index.tsx', 'src/view.ts',
    'generated/pkg/dist/api.d.ts', 'generated/nested-only.ts',
    'src/nested/main.ts', 'src2/main.ts', 'outside/main.ts', 'generated/only.js',
    'generated/folder/index.tsx', 'src/folder.ts', 'generated/relative/path.ts'];
  for (const name of names) put(name);
  put('generated/pkg/package.json', {types: './dist/api.d.ts'});
  const cases = [
    ['./local', 'src/local.ts'], ['./only', 'generated/only.tsx'], ['./only.js', 'generated/only.tsx'],
    ['./esm.mjs', 'generated/esm.mts'], ['./cjs.cjs', 'generated/cjs.d.cts'],
    ['./theme.css', 'generated/theme.d.css.ts'], ['./icon.css', 'generated/icon.css.d.ts'],
    ['./view', 'src/view.ts'], ['./folder/', 'generated/folder/index.tsx'],
    ['./pkg', 'generated/pkg/dist/api.d.ts'], ['./does-not-exist', null], ['only', null],
    ['./only', 'extra/only.ts', 'src/main.ts', 'reverse.json'],
    ['./only', null, 'src/main.ts', 'clear.json'], ['./only', null, 'src/main.ts', 'null.json'],
    ['./only', null, 'src2/main.ts'], ['./nested-only', 'generated/nested-only.ts', 'src/nested/main.ts'],
    ['../src/relative/path', 'generated/relative/path.ts', 'outside/main.ts'],
    [path.join(dir, 'src', 'esm.mjs'), 'generated/esm.mts'],
  ];
  const getOptions = filename => ts.parseJsonConfigFileContent(
    ts.readConfigFile(filename, ts.sys.readFile).config, ts.sys, path.dirname(filename)).options;
  for (const [request, expected, from = 'src/main.ts', configFile = 'project.json'] of cases) {
    const importer = path.join(dir, from), filename = path.join(dir, configFile);
    const wanted = expected && fs.realpathSync(path.join(dir, expected));
    if (ts) {
      const result = ts.resolveModuleName(request, importer, getOptions(filename), ts.sys).resolvedModule;
      assert.equal(result ? fs.realpathSync(result.resolvedFileName) : null, wanted, 'TypeScript ' + request);
    }
    for (const mode of ['import', 'require']) {
      const args = ['resolve', request, '--from', importer, '--tsconfig', filename];
      if (mode === 'require') args.push('--require');
      const result = spawnSync(binary, args, {encoding: 'utf8'});
      assert.equal(result.status, wanted ? 0 : 1, [request, filename, result.stdout, result.stderr].join(' '));
      if (wanted) assert.equal(fs.realpathSync(JSON.parse(result.stdout).path), wanted);
      if (sdk && wanted) assert.equal(fs.realpathSync(sdk.resolveModuleSync(request, importer, {tsconfig: filename, mode}).path), wanted);
      if (sdk && !wanted) assert.throws(() => sdk.resolveModuleSync(request, importer, {tsconfig: filename, mode}), {code: 'Not_Found'});
    }
  }
  const invalid = spawnSync(binary, ['resolve', './only', '--from', path.join(dir, 'src/main.ts'),
    '--tsconfig', path.join(dir, 'configuration.json')], {encoding: 'utf8'});
  assert.equal(invalid.status, 1);
  assert.match(invalid.stderr, /Invalid_TSConfig/);
  verifyWorkspaceOptions(binary, dir, sdk, put);
  if (ts) verifyUpstream(binary, dir, ts, sdk, put);
  console.log('TypeScript rootDirs passed ' + cases.length + ' cases in import and require mode.');
};

function verifyWorkspaceOptions(binary, dir, sdk, put) {
  const importer = path.join(dir, 'src/main.ts'), config = path.join(dir, 'project.json');
  put('package.json', {browser: {'./generated/virtual.ts': false}});
  const ignored = spawnSync(binary, ['resolve', './virtual', '--from', importer, '--tsconfig', config, '--browser'], {encoding: 'utf8'});
  assert.equal(ignored.status, 0, ignored.stderr);
  assert.deepEqual(JSON.parse(ignored.stdout), {kind: 'ignored', path: ''});
  if (sdk) assert.deepEqual(sdk.resolveModuleSync('./virtual', importer, {tsconfig: config, browser: true}),
    {kind: 'ignored', path: ''});
  put('extra/virtual.web.ts');
  const alias = spawnSync(binary, ['resolve', './virtual.js', '--from', importer, '--tsconfig', config,
    '--extension-alias', '.js=.web.ts'], {encoding: 'utf8'});
  assert.equal(alias.status, 0, alias.stderr);
  assert.equal(JSON.parse(alias.stdout).path, fs.realpathSync(path.join(dir, 'extra/virtual.web.ts')));
  const linked = dir + '-linked';
  fs.symlinkSync(dir, linked, 'junction');
  for (const preserveSymlinks of [true, false]) {
    const from = path.join(linked, 'src/main.ts'), tsconfig = path.join(linked, 'project.json');
    const wanted = path.join(linked, 'generated/only.tsx');
    const args = ['resolve', './only', '--from', from, '--tsconfig', tsconfig];
    if (preserveSymlinks) args.push('--preserve-symlinks');
    const result = spawnSync(binary, args, {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    const expected = preserveSymlinks ? wanted : fs.realpathSync(wanted);
    assert.equal(JSON.parse(result.stdout).path, expected);
    if (sdk) assert.equal(sdk.resolveModuleSync('./only', from, {tsconfig, preserveSymlinks}).path, expected);
  }
}

// Preserve the compiler fixtures' directory structure when moving their virtual
// Windows drive into the temporary workspace. Resolve each relative import in
// both directions between the physical and generated source trees.
function verifyUpstream(binary, dir, ts, sdk, put) {
  const compiler = path.resolve(__dirname, '../vendor/typescript/tests/cases/compiler');
  let relative = 0, bare = 0;
  for (const family of [6, 7]) {
    for (const mode of ['node', 'classic']) {
      const name = 'pathMappingBasedModuleResolution' + family + '_' + mode;
      const source = fs.readFileSync(path.join(compiler, name + '.ts'), 'utf8');
      const files = source.split(/^\/\/ @filename: c:\/(.+)\r?$/gm);
      const inputs = [];
      let config;
      for (let i = 1; i < files.length; i += 2) {
        const content = files[i+1].replaceAll('c:/', path.join(dir, name).split(path.sep).join('/') + '/');
        const file = put(path.join(name, files[i].trim()), content);
        if (file.endsWith('tsconfig.json')) config = file;
        else inputs.push([file, content]);
      }
      const parsed = ts.parseJsonConfigFileContent(ts.readConfigFile(config, ts.sys.readFile).config,
        ts.sys, path.dirname(config));
      parsed.options.moduleResolution = mode === 'node' ? ts.ModuleResolutionKind.Node10 : ts.ModuleResolutionKind.Classic;
      for (const [importer, contents] of inputs) {
        for (const {fileName} of ts.preProcessFile(contents).importedFiles) {
          const expected = ts.resolveModuleName(fileName, importer, parsed.options, ts.sys).resolvedModule;
          assert.ok(expected, name + ' ' + fileName);
          const wanted = fs.realpathSync(expected.resolvedFileName);
          const args = ['resolve', fileName, '--from', importer, '--tsconfig', config];
          const options = {tsconfig: config};
          if (fileName.startsWith('.')) {
            relative++;
          } else {
            // Bare imports retain the caller's package lookup policy. These
            // fixtures ask for declarations in Node10 or classic ancestor roots.
            bare++;
            options.mode = 'require';
            options.extensions = ['.ts', '.tsx', '.d.ts', '.js', '.jsx'];
            args.push('--require', ...options.extensions.flatMap(ext => ['--extension', ext]));
            if (mode === 'classic') {
              options.modules = ['.'];
              args.push('--module-dir', '.');
            }
          }
          const result = spawnSync(binary, args, {encoding: 'utf8'});
          assert.equal(result.status, 0, result.stderr);
          assert.equal(fs.realpathSync(JSON.parse(result.stdout).path), wanted);
          assert.equal(fs.realpathSync(sdk.resolveModuleSync(fileName, importer, options).path), wanted);
        }
      }
    }
  }
  assert.deepEqual([relative, bare], [8, 6]);
  console.log('The CLI and SDK matched eight relative and six bare imports from the four upstream rootDirs fixtures.');
}
