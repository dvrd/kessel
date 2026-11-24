'use strict';

// Suites for verify_module_resolver_reference.js. Each suite mirrors one Rust
// test file of oxc-resolver: the option sets and starting directories are the
// ones that file constructs, and the requests are every string literal of the
// file. Replaying all literals from all directories under all option sets is
// a superset of the upstream assertions, and needs no hand-copied expectation.

const fs = require('node:fs');
const path = require('node:path');
const { builtinModules } = require('node:module');

// Files of the in-memory file system shared by upstream's alias and fallback tests.
const ALIAS_FILES = ['a/index.js', 'a/dir/index.js', 'recursive/index.js', 'recursive/dir/index.js',
  'recursive/dir/file', 'recursive/dir/dir/index.js', 'b/index.js', 'b/dir/index.js', 'c/index.js',
  'c/dir/index.js', 'd/index.js.js', 'd/dir/.empty', 'e/index.js', 'e/anotherDir/index.js', 'e/dir/file',
  'dashed-name'];
const FULLY_SPECIFIED_FILES = {
  'a/node_modules/package1/index.js': '', 'a/node_modules/package1/file.js': '',
  'a/node_modules/package2/package.json': '{"main":"a"}', 'a/node_modules/package2/a.js': '',
  'a/node_modules/package3/package.json': '{"main":"dir"}', 'a/node_modules/package3/dir/index.js': '',
  'a/node_modules/package4/package.json': '{"browser":{"./a.js":"./b"}}',
  'a/node_modules/package4/a.js': '', 'a/node_modules/package4/b.js': '',
  'a/abc.js': '', 'a/dir/index.js': '', 'a/index.js': '',
};

function write(root, files) {
  for (const [name, contents] of Object.entries(files)) {
    const filename = path.join(root, name);
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    fs.writeFileSync(filename, contents);
  }
}

// Upstream's in-memory tests use absolute paths below "/". Here the same
// tree lives below `base`, so absolute literals are moved there.
function rebase(base, value) {
  return value.startsWith('/') ? path.join(base, value) + (value.length > 1 && value.endsWith('/') ? '/' : '') : value;
}

function symlinkFixture(root) {
  const test = path.join(root, 'enhanced-resolve/test');
  const temp = path.join(test, 'temp');
  fs.mkdirSync(temp);
  fs.symlinkSync(path.join(root, 'enhanced-resolve/lib/index.js'), path.join(temp, 'index.js'));
  fs.symlinkSync(path.join(root, 'enhanced-resolve/lib'), path.join(temp, 'lib'));
  fs.symlinkSync(path.join(root, 'enhanced-resolve'), path.join(temp, 'this'));
  fs.symlinkSync(path.join(temp, 'this'), path.join(temp, 'that'));
  fs.symlinkSync('../../lib/index.js', path.join(temp, 'node.relative.js'));
  fs.symlinkSync('./node.relative.js', path.join(temp, 'node.relative.sym.js'));
  return temp;
}

function fixtureSuites(root, literals) {
  const f = path.join(root, 'enhanced-resolve/test/fixtures');
  const tsconfig = path.join(root, 'tsconfig');
  const css = { regex: '\\.(sass|scss|css)$' };
  const temp = symlinkFixture(root);
  const memory = path.join(root, 'memory');
  write(path.join(memory, 'alias'), Object.fromEntries(ALIAS_FILES.map(name => [name, ''])));
  write(path.join(memory, 'full'), FULLY_SPECIFIED_FILES);
  const aliasRoot = path.join(memory, 'alias');
  const full = path.join(memory, 'full');
  const fallback = {
    aliasA: ['a'], b$: ['a/index.js'], c$: [rebase(aliasRoot, '/a/index.js')],
    multiAlias: ['b', 'c', 'd', 'e', 'a'], recursive: ['recursive/dir'],
    [rebase(aliasRoot, '/d/dir')]: [rebase(aliasRoot, '/c/dir')],
    [rebase(aliasRoot, '/d/index.js.js')]: [rebase(aliasRoot, '/c/index.js')],
    ignored: [null], 'node:path': [null],
  };
  const fullAlias = { alias1: [rebase(full, '/a/abc')], alias2: [rebase(full, '/a')] };
  const references = configFile => ({ tsconfig: { configFile, references: 'auto' } });
  const projects = path.join(tsconfig, 'cases/project-references');
  return [
    { suite: 'resolve', sets: [{}], dirs: [f, path.join(f, 'node_modules/complexm'),
      path.join(f, 'multiple-modules'), path.join(f, 'browser-module/node_modules')],
      extra: [path.join(f, 'main1.js'), path.join(f, 'node_modules/m2'), path.join(f, 'node_modules/m2') + '/'] },
    { suite: 'resolve', literals: 'resolve', sets: [
      { extensions: ['.js', '.jsx', '.ts', '.tsx'], modules: ['src/a', 'src/b', 'src/common', 'node_modules'] },
    ], dirs: [path.join(f, 'issue-238/src/common')] },
    { suite: 'resolve', literals: 'resolve', sets: [{ preferRelative: true }, { resolveToContext: true }], dirs: [f] },
    { suite: 'resolve', literals: 'resolve', sets: [{}, { mainFiles: [] }], dirs: [path.join(root, 'dot/foo')] },
    { suite: 'resolve', literals: 'resolve', sets: [{}], dirs: [
      path.join(root, 'abnormal-relative-with-node_modules/foo/bar/baz'),
      path.join(root, 'abnormal-relative-without-node_modules/foo/bar/baz')] },
    { suite: 'roots', sets: [
      { extensions: ['.js'], alias: { foo: ['/fixtures'] }, roots: [path.dirname(f), f] },
      { extensions: ['.js'], alias: { foo: ['/fixtures'] }, roots: [path.dirname(f), f], preferAbsolute: true },
      { roots: [path.dirname(f), f], resolveToContext: true },
      { roots: [f] },
      { roots: [path.join(root, 'misc/dir-with-index')] },
    ], dirs: [f, path.join(root, 'misc/dir-with-index')],
      extra: ['/', path.join(f, 'b.js'), path.join(f, 'roots-fall-through/index.js')] },
    { suite: 'full_specified', base: full, sets: [
      { alias: fullAlias, aliasFields: [['browser']], fullySpecified: true },
      { alias: fullAlias, aliasFields: [['browser']], fullySpecified: true, resolveToContext: true },
      { fullySpecified: true }, { fullySpecified: true, resolveToContext: true },
    ], dirs: [path.join(full, 'a')] },
    { suite: 'fallback', base: aliasRoot, sets: [{ fallback, modules: [aliasRoot] }], dirs: [aliasRoot] },
    { suite: 'alias', base: aliasRoot, sets: [
      // Upstream's table as written needs several targets per name.
      { alias: { ...fallback, multiAlias: ['b', 'c', 'd', 'e', 'a'] }, modules: [aliasRoot] },
      // The single-target entries of that table.
      { alias: { aliasA: ['a'], b$: ['a/index.js'], c$: [rebase(aliasRoot, '/a/index.js')],
        recursive: ['recursive/dir'], '#': [rebase(aliasRoot, '/c/dir')], '@': [rebase(aliasRoot, '/c/dir')],
        '@scope/package-name/file$': [rebase(aliasRoot, '/c/dir')] }, modules: [aliasRoot] },
    ], dirs: [aliasRoot] },
    { suite: 'alias', literals: 'alias', sets: [
      { alias: { '@app': [path.join(f, 'alias')] } }, { alias: { '@': [path.join(f, 'foo')] } },
      { alias: { m1: [path.join(f, 'node_modules/m2')] } }, { alias: { '#': [path.join(f, '#')] } },
      { alias: { multi: [path.join(f, 'nonexistent'), path.join(f, 'foo')] } },
    ], dirs: [f] },
    { suite: 'restrictions', sets: [
      { extensions: ['.js'], restrictions: [css] },
      { extensions: ['.js', '.css'], mainFiles: ['index'], restrictions: [css] },
      { extensions: ['.js'], restrictions: [{ path: path.join(f, 'restrictions') }] },
      { extensions: ['.js', '.css'], mainFields: ['main', 'style'], restrictions: [css] },
      { extensions: ['.js'], mainFields: ['main', 'module', 'style'], restrictions: [css] },
      { extensions: ['.js', '.css'], mainFiles: ['index'], restrictions: [{ regex: '\\.(css)$' }, { regex: '[^s]$' }] },
      { extensionAlias: { '.js': ['.ts', '.js'], '.mjs': ['.mts', '.mjs'] }, restrictions: [{ regex: '\\.js$' }] },
      { mainFields: ['module', 'main'], restrictions: [{ regex: '\\.css$' }] },
      { aliasFields: [['browser']], restrictions: [{ regex: 'lib/[a-z]+\\.js$' }] },
    ], dirs: [path.join(f, 'restrictions'), path.join(f, 'browser-module'), path.join(f, 'extension-alias')] },
    { suite: 'symlink', sets: [{}, { symlinks: false }], dirs: [temp, path.join(temp, 'lib'),
      path.join(temp, 'this'), path.join(temp, 'this/lib'), path.join(temp, 'this/test'),
      path.join(temp, 'that'), path.join(temp, 'that/lib'), path.join(temp, 'that/test')] },
    { suite: 'simple', sets: [{}], dirs: [path.join(root, 'enhanced-resolve/test'), root, f,
      path.join(f, 'node_modules/dash'), path.join(f, 'node_modules/dash-name'), path.join(root, 'invalid')] },
    { suite: 'extensions', sets: [
      { extensions: ['.ts', '.js'] }, { extensions: ['.ts', '', '.js'] },
      { extensions: ['.a.b.c', '.d.ts', '.ts', '.js'], extensionAlias: { '.ts': ['.ts', '.d.ts'] } },
      { extensions: ['.jsx', '.tsx', '.js', '.ts'] },
    ], dirs: [path.join(f, 'extensions')] },
    { suite: 'main_field', sets: [{ mainFields: ['style'] }, { mainFields: ['module', 'main'] },
      { mainFields: ['module', 'main'], extensionAlias: { '.js': ['.ts', '.js'] } },
    ], dirs: [path.join(f, 'restrictions'), path.join(root, 'invalid')] },
    { suite: 'scoped_packages', sets: [{ aliasFields: [['browser']] }, {}], dirs: [path.join(f, 'scoped')] },
    { suite: 'missing', sets: [{}], dirs: [f] },
    { suite: 'incorrect_description_file', sets: [{}], dirs: [path.join(f, 'incorrect-package/pack1'),
      path.join(f, 'incorrect-package/pack2')] },
    { suite: 'builtins', sets: [{}, { conditionNames: ['node'] }], dirs: [root, path.join(f, 'builtins')],
      extra: builtinModules.flatMap(name => [name, 'node:' + name.replace(/^node:/, '')]) },
    { suite: 'browser_field', sets: [
      { aliasFields: [['browser']] }, { aliasFields: [['browser']], mainFields: ['browser'] },
      { aliasFields: [['browser'], ['innerBrowser1'], ['innerBrowser2'], []] },
      { aliasFields: [['innerBrowser1', 'field', 'browser']] }, { aliasFields: [['innerBrowser2', 'browser']] },
    ], dirs: [path.join(f, 'browser-module'), path.join(f, 'browser-module/lib')] },
    { suite: 'extension_alias', sets: [
      { extensions: ['.js'], mainFiles: ['index.js'], extensionAlias: { '.js': ['.ts', '.js'], '.mjs': ['.mts'] } },
      { extensionAlias: { '.js': ['.ts', '.d.ts'] } },
      { extensions: ['.js'], mainFiles: ['index'], extensionAlias: { '.js': [] } },
    ], dirs: [path.join(f, 'extension-alias')] },
    { suite: 'exports_field', sets: [
      { extensions: ['.js'], fullySpecified: true, conditionNames: ['webpack'] },
      { aliasFields: [['browser']], conditionNames: ['webpack'], extensions: ['.js'] },
      { aliasFields: [['browser']], extensions: ['.js'], conditionNames: ['node'] },
      { extensions: ['.js'], conditionNames: ['webpack'] },
      { aliasFields: [['browser']], exportsFields: [['exports']], extensions: ['.js'] },
      { aliasFields: [['browser']], exportsFields: [['ex'], ['exports_field', 'exports']], extensions: ['.js'] },
      { exportsFields: [['broken']], extensions: ['.js'] },
      { exportsFields: [['exportsField', 'exports']], extensions: ['.js'] },
      { exportsFields: [['ex']], extensions: ['.js'] },
      { extensions: ['.js'], extensionAlias: { '.js': ['.ts', '.js'] }, fullySpecified: true,
        conditionNames: ['webpack', 'default'] },
      { extensions: ['.js'], extensionAlias: { '.js': ['.foo', '.baz', '.baz', '.ts', '.js'] },
        fullySpecified: true, conditionNames: ['webpack', 'default'] },
      { extensions: ['.js'], extensionAlias: { '.js': ['.ts'] }, fullySpecified: true,
        conditionNames: ['webpack', 'default'] },
    ], dirs: [f, path.join(f, 'exports-field'), path.join(f, 'exports-field2'), path.join(f, 'exports-field3'),
      path.join(f, 'exports-field-error'), path.join(f, 'imports-exports-wildcard'),
      path.join(f, 'exports-field-and-extension-alias')] },
    { suite: 'imports_field', sets: [
      { extensions: ['.js'], mainFiles: ['index'], conditionNames: ['webpack'] },
      { extensions: ['.js'], mainFiles: ['index.js'], importsFields: [['imports']], conditionNames: ['webpack'] },
      { importsFields: [['other', 'imports']] },
    ], dirs: [path.join(f, 'imports-field'), path.join(f, 'imports-exports-wildcard/node_modules/m')] },
    { suite: 'tsconfig_project_references', sets: [
      references(path.join(projects, 'app')), references(path.join(projects, 'app/tsconfig.nopaths.json')),
      { tsconfig: { configFile: path.join(projects, 'app') } },
      { tsconfig: { configFile: path.join(projects, 'app/tsconfig.nopaths.json') } },
      { extensions: ['.ts', '.tsx'], ...references(path.join(projects, 'extends')) },
    ], dirs: [path.join(projects, 'app'), path.join(projects, 'project-a'), path.join(projects, 'project-b/src'),
      path.join(projects, 'project-b/src/aliased'), path.join(projects, 'project-c'),
      path.join(projects, 'extends/src/src'), path.join(tsconfig, 'cases/paths-template-variable'),
      path.join(tsconfig, 'cases/paths-template-variable/src')] },
  ];
}

// One package per row of upstream's exports table. The row's expected files
// exist, so a resolver that maps the request elsewhere finds nothing.
function* fieldCases(root, packed) {
  const tables = path.join(root, 'tables');
  for (const [index, row] of packed.exportsCases.entries()) {
    const name = 'exports-row-' + index;
    const directory = path.join(tables, 'node_modules', name);
    write(directory, { 'package.json': JSON.stringify({ name, exports: row.exports }) });
    for (const file of row.expect || []) write(directory, { [file]: '' });
    const request = row.request === '.' ? name : name + row.request.slice(1);
    yield { suite: 'exports_field_table', options: { conditionNames: row.conditions }, directory: tables, request };
  }
  for (const [index, row] of packed.importsCases.entries()) {
    const directory = path.join(tables, 'imports-row-' + index);
    write(directory, { 'package.json': JSON.stringify({ name: 'imports-row-' + index, imports: row.imports }) });
    for (const file of row.expect || []) {
      if (file.startsWith('./')) write(directory, { [file]: '' });
      else write(path.join(directory, 'node_modules'), { [file]: '' });
    }
    yield { suite: 'imports_field_table', options: { conditionNames: row.conditions }, directory, request: row.request };
  }
}

function configDirectories(directory, found) {
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  if (entries.some(entry => entry.name === 'tsconfig.json')) found.push(directory);
  for (const entry of entries) {
    if (entry.isDirectory() && entry.name !== 'node_modules') configDirectories(path.join(directory, entry.name), found);
  }
  return found;
}

// Upstream's tsconfig tests build one resolver per fixture directory. Every
// directory holding a tsconfig.json is replayed the same way, from itself and
// from its src directory, with the three option sets those tests use.
function tsconfigSuites(root, literals) {
  const requests = Array.from(new Set(['tsconfig_paths', 'tsconfig_extends', 'tsconfig_root_dirs']
    .flatMap(suite => literals[suite])));
  return configDirectories(path.join(root, 'tsconfig'), []).map(directory => {
    const tsconfig = { configFile: path.join(directory, 'tsconfig.json'), references: 'auto' };
    const source = path.join(directory, 'src');
    return { suite: 'tsconfig', requests, dirs: fs.existsSync(source) ? [directory, source] : [directory], sets: [
      { tsconfig }, { tsconfig, extensions: ['.ts', '.js'] },
      { tsconfig, extensionAlias: { '.js': ['.js', '.ts', '.tsx'] } },
    ] };
  });
}

function* cases(root, packed) {
  for (const group of tsconfigSuites(root, packed.literals)) {
    for (const options of group.sets) {
      for (const directory of group.dirs) {
        for (const request of group.requests) yield { suite: group.suite, options, directory, request };
      }
    }
  }
  for (const group of fixtureSuites(root, packed.literals)) {
    const base = group.base;
    const literals = packed.literals[group.literals || group.suite].concat(group.extra || []);
    const requests = Array.from(new Set(literals.map(text => (base ? rebase(base, text) : text))));
    for (const options of group.sets) {
      for (const directory of group.dirs) {
        for (const request of requests) yield { suite: group.suite, options, directory, request };
      }
    }
  }
  yield* fieldCases(root, packed);
}

function manifestNear(filename) {
  for (let directory = path.dirname(filename); directory !== path.dirname(directory); directory = path.dirname(directory)) {
    const manifest = path.join(directory, 'package.json');
    if (fs.existsSync(manifest)) return fs.readFileSync(manifest, 'utf8');
  }
  return '';
}

const isBare = request => !/^(\.{1,2}(\/|$)|\/|#)/.test(request);

// Every rule states which side Kessel follows and where that is checked, and
// pins how many cases it claims, so a rule cannot quietly absorb a regression.
// "Node gate" refers to the synthetic rows of verify_module_resolver_node.js,
// which compare the same behavior with the running Node on every run.
const DIFFERENCES = [
  {
    // enhanced-resolve splits "?query" and "#fragment" off a request, resolves
    // the rest, and appends them to the result, also when a package map or a
    // browser field target carries them. Kessel returns filenames only. In
    // require mode the characters are part of the filename, as in Node's
    // CommonJS loader. In import mode the ES module rules apply (Node gate:
    // "./a.js?query"). NUL-escaped "#" is enhanced-resolve syntax.
    name: 'query and fragment are not carried through resolution',
    expected: 189,
    applies: (test, oxc, kessel) => kessel.kind === 'error' && oxc.kind === 'file' && !fs.existsSync(oxc.path) &&
      /[?#]/.test(oxc.path),
  },
  {
    // Node: ERR_UNKNOWN_BUILTIN_MODULE (Node gate: "node:nope", "node:").
    // oxc-resolver accepts any request that starts with "node:".
    name: 'an unknown node: name is not a builtin',
    expected: 12,
    applies: (test, oxc, kessel) => test.request.startsWith('node:') && oxc.kind === 'builtin' &&
      kessel.kind === 'error' && !require('node:module').isBuiltin(test.request),
  },
  {
    // Node: a package map target must not be a URL, so "#http": "node:http"
    // is ERR_INVALID_PACKAGE_TARGET (Node gate: "#http"). "#fs": "fs" works.
    name: 'an imports target cannot be a node: URL',
    expected: 1,
    applies: (test, oxc, kessel) => test.request.startsWith('#') && oxc.kind === 'builtin' &&
      kessel.message === 'Invalid_Package_Target',
  },
  {
    // Node removed "./dir/": "./lib/" folder mappings in v17
    // (Node gate: "folder/dist/x.js", "#folder/x.js"). enhanced-resolve keeps them.
    name: 'package maps have no folder mappings',
    expected: 83,
    applies: (test, oxc, kessel) => oxc.kind === 'file' &&
      /^Package_(Path_Not_Exported|Import_Not_Defined)$/.test(kessel.message) &&
      /"[^"]*\/"\s*:/.test(manifestNear(test.request.startsWith('#') ?
        path.join(test.directory, 'x') : oxc.path.replace(/[?#].*$/, ''))),
  },
  {
    // Node: a package map target names its file exactly (Node gate: "folder/x",
    // "#bare"). enhanced-resolve probes extensions and directory entries on the
    // target unless fullySpecified, in which case it agrees with Kessel. The
    // rule holds only when that rerun of the reference agrees.
    name: 'package map targets are exact filenames',
    expected: 6,
    applies: (test, oxc, kessel, rerun) => oxc.kind === 'file' && kessel.message === 'Not_Found' &&
      (isBare(test.request) || test.request.startsWith('#')) &&
      rerun({ ...test.options, fullySpecified: true }).kind === 'error',
  },
  {
    // Node: a target that names a directory is an error in both loaders
    // (Node gate: "folder/dir"). enhanced-resolve loads the directory's index,
    // which upstream's own test calls a non-compliant export.
    name: 'a package map target cannot be a directory',
    expected: 1,
    applies: (test, oxc, kessel) => {
      if (oxc.kind !== 'file' || kessel.message !== 'Not_Found' || !isBare(test.request)) return false;
      const target = path.dirname(oxc.path);
      for (let directory = path.dirname(target); directory !== path.dirname(directory);
        directory = path.dirname(directory)) {
        const manifest = path.join(directory, 'package.json');
        if (!fs.existsSync(manifest)) continue;
        return fs.readFileSync(manifest, 'utf8').includes(JSON.stringify('./' + path.relative(directory, target)));
      }
      return false;
    },
  },
  {
    // Node's CommonJS loader joins a request onto each existing node_modules
    // directory without requiring the package directory, so "pkg/../x" can
    // name a file beside a missing package (Node gate: "missing/../file.js").
    name: 'CommonJS joins a subpath onto node_modules without the package',
    expected: 4,
    applies: (test, oxc, kessel) => kessel.kind === 'file' && oxc.kind === 'error' && isBare(test.request) &&
      /\/\.\.(\/|$)/.test(test.request),
  },
  {
    // "/" as a context: oxc-resolver trims it to an empty path and fails,
    // enhanced-resolve 5.24.5 answers with the importing directory, Kessel
    // with the filesystem root that the request names.
    name: 'the filesystem root is a valid context',
    expected: 2,
    applies: (test, oxc, kessel) => test.request === '/' && test.options.resolveToContext === true &&
      kessel.kind === 'file' && kessel.path === '/',
  },
  {
    // enhanced-resolve 5.24.5 admits every file below a restriction path:
    // create.sync({ restrictions: [dir] }) resolves "pck1" in the restrictions
    // fixture to node_modules/pck1/index.js. oxc-resolver's port admits only
    // the path itself, so nothing inside the directory resolves.
    name: 'a restriction path admits the files below it',
    expected: 2,
    applies: (test, oxc, kessel) => oxc.kind === 'error' && kessel.kind === 'file' &&
      (test.options.restrictions || []).some(entry => entry.path && kessel.path.startsWith(entry.path + path.sep)),
  },
  {
    // Node resolves from the real directory of the importing file unless
    // --preserve-symlinks is given (Node gate: importers below app/linked).
    // oxc-resolver joins ".." onto the directory as spelled.
    name: 'a relative request starts from the real importing directory',
    expected: 10,
    applies: (test, oxc, kessel) => test.options.symlinks !== false && test.request.startsWith('..') &&
      fs.realpathSync(test.directory) !== test.directory,
  },
  {
    // Node: a request that starts with "#" is a package import, never a path
    // (Node gate: "#/../a.js"). oxc-resolver normalizes "#/../x" to "./x".
    name: 'a # request is a package import, not a path',
    expected: 32,
    applies: (test, oxc, kessel) => test.request.startsWith('#') && oxc.kind === 'file' &&
      kessel.message === 'Package_Import_Not_Defined' && test.request.includes('/../'),
  },
  {
    // A request that tsconfig paths, baseUrl or rootDirs map is looked up the
    // way TypeScript looks it up: ".ts", ".tsx" and ".d.ts" are tried, and a
    // ".js" request finds its ".ts" source. test:resolve:reference compares
    // that with TypeScript itself. oxc-resolver tries only the configured
    // extensions. The rule holds only when the reference, rerun with
    // TypeScript's extensions configured, agrees with Kessel.
    name: 'tsconfig mappings use TypeScript extension lookup',
    expected: 86,
    applies: (test, oxc, kessel, rerun) => {
      if (!test.options.tsconfig || kessel.kind !== 'file' || oxc.kind !== 'error') return false;
      const typed = rerun({ ...test.options, extensions: ['.ts', '.tsx', '.d.ts', '.js', '.jsx', '.json'],
        extensionAlias: { '.js': ['.ts', '.tsx', '.d.ts', '.js'] } });
      return typed.kind === 'file' && typed.path === kessel.path;
    },
  },
  {
    // TypeScript follows "extends": "pkg" through the package's "tsconfig"
    // manifest field (getParsedCommandLineOfConfigFile on the "field" fixture
    // yields its paths). oxc-resolver does not read that field.
    name: 'extends reads the tsconfig field of a package',
    expected: 9,
    applies: (test, oxc, kessel) => kessel.kind === 'file' && oxc.kind === 'error' &&
      oxc.message.startsWith('Tsconfig not found'),
  },
  {
    // TypeScript reports "File not found" (diagnostic 6053) for an "extends"
    // entry that names a directory. oxc-resolver loads the directory's
    // tsconfig.json. The rule asks the installed TypeScript.
    name: 'extends cannot name a directory',
    expected: 14,
    applies: (test, oxc, kessel) => {
      if (!test.options.tsconfig || kessel.message !== 'TSConfig_Not_Found' || oxc.kind !== 'file') return false;
      const ts = require('../../bench/node_modules/typescript');
      const host = { ...ts.sys, onUnRecoverableConfigFileDiagnostic() {} };
      const parsed = ts.getParsedCommandLineOfConfigFile(test.options.tsconfig.configFile, {}, host);
      return parsed.errors.some(error => error.code === 6053);
    },
  },
  {
    // TypeScript resolves a file of a referenced project with that project's
    // options alone. oxc-resolver falls back to the referencing project's
    // baseUrl when the owner's paths do not match.
    name: 'a referenced project does not borrow the referencing baseUrl',
    expected: 10,
    applies: (test, oxc, kessel) => {
      const config = test.options.tsconfig;
      if (!config || config.references !== 'auto' || kessel.kind !== 'error' || oxc.kind !== 'file') return false;
      const owner = config.configFile.endsWith('.json') ? path.dirname(config.configFile) : config.configFile;
      return !test.directory.startsWith(owner) && oxc.path.startsWith(owner + path.sep);
    },
  },
];

// Upstream option sets that Kessel's options cannot express. They are counted,
// not compared: aliases there take several targets, an ignore marker or a
// wildcard, and alias fields other than "browser" name nested manifest paths.
const UNSUPPORTED = {
  'alias with several targets or ignore': 224,
  'aliasFields other than browser': 270,
};

module.exports = { cases, DIFFERENCES, UNSUPPORTED };
